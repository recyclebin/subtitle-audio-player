import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_langdetect/flutter_langdetect.dart' as langdetect;
import 'package:record/record.dart';

import '../models/assessment_result.dart';

enum AssessmentMode { afterSubtitle, karaoke }

/// 从 WAV 中提取原始 PCM 数据，兼容非标准 RIFF 头部。
/// 返回 null 表示文件不是有效 WAV/PCM。
Uint8List? _extractPcmFromWav(Uint8List bytes) {
  if (bytes.length < 44) return null;
  final data = ByteData.sublistView(bytes);

  // 校验 RIFF 头部
  if (data.getUint8(0) != 0x52 || // R
      data.getUint8(1) != 0x49 || // I
      data.getUint8(2) != 0x46 || // F
      data.getUint8(3) != 0x46 || // F
      data.getUint8(8) != 0x57 || // W
      data.getUint8(9) != 0x41 || // A
      data.getUint8(10) != 0x56 || // V
      data.getUint8(11) != 0x45) {
    // E
    return null;
  }

  // 遍历 chunk 找到 "data" 块
  var offset = 12;
  while (offset + 8 <= bytes.length) {
    final chunkId = String.fromCharCodes(bytes.sublist(offset, offset + 4));
    final chunkSize = data.getUint32(offset + 4, Endian.little);
    if (chunkId == 'data') {
      final dataStart = offset + 8;
      final dataEnd = (dataStart + chunkSize).clamp(0, bytes.length);
      return bytes.sublist(dataStart, dataEnd);
    }
    offset += 8 + chunkSize;
  }
  return null;
}

/// 根据原始 16-bit 单声道 PCM 数据构建最小 44 字节 WAV 头部。
/// 确保无论录音设备生成何种头部格式，Azure 都能正确解析。
Uint8List _buildMinimalWav(Uint8List pcm) {
  final dataSize = pcm.length;
  final fileSize = 36 + dataSize; // RIFF size = fileSize - 8
  final header = ByteData(44);
  // RIFF
  header.setUint8(0, 0x52); // R
  header.setUint8(1, 0x49); // I
  header.setUint8(2, 0x46); // F
  header.setUint8(3, 0x46); // F
  header.setUint32(4, fileSize, Endian.little);
  // WAVE
  header.setUint8(8, 0x57); // W
  header.setUint8(9, 0x41); // A
  header.setUint8(10, 0x56); // V
  header.setUint8(11, 0x45); // E
  // fmt
  header.setUint8(12, 0x66); // f
  header.setUint8(13, 0x6D); // m
  header.setUint8(14, 0x74); // t
  header.setUint8(15, 0x20); // (space)
  header.setUint32(16, 16, Endian.little); // chunk size
  header.setUint16(20, 1, Endian.little); // PCM
  header.setUint16(22, 1, Endian.little); // mono
  header.setUint32(24, 16000, Endian.little); // sample rate
  header.setUint32(28, 32000, Endian.little); // byte rate
  header.setUint16(32, 2, Endian.little); // block align
  header.setUint16(34, 16, Endian.little); // bits per sample
  // data
  header.setUint8(36, 0x64); // d
  header.setUint8(37, 0x61); // a
  header.setUint8(38, 0x74); // t
  header.setUint8(39, 0x61); // a
  header.setUint32(40, dataSize, Endian.little);

  return Uint8List(44 + pcm.length)
    ..setAll(0, header.buffer.asUint8List())
    ..setAll(44, pcm);
}

class PronunciationService {
  static const _minAudioFileSize = 1600; // ~0.1s of 16kHz mono WAV

  final String subscriptionKey;
  final String region;
  AudioRecorder? __recorder;
  AudioRecorder get _recorder => __recorder ??= AudioRecorder();

  PronunciationService({
    required this.subscriptionKey,
    required this.region,
  });

  String get _baseUrl =>
      'https://$region.stt.speech.microsoft.com/speech/recognition/conversation/cognitiveservices/v1';

  String buildAssessmentConfig({
    required String referenceText,
    required String language,
  }) {
    final json = jsonEncode({
      'ReferenceText': referenceText,
      'GradingSystem': 'HundredMark',
      'Granularity': 'Phoneme',
      'Dimension': 'Comprehensive',
      'EnableMiscue': true,
      'PhonemeAlphabet': 'IPA',
    });
    return base64Encode(utf8.encode(json));
  }

  static bool _initialized = false;

  /// 初始化 n-gram 语种检测模型（55 种语言）。
  /// 在 main() 中调用一次即可，重复调用自动跳过。
  static Future<void> initLanguageDetector() async {
    if (_initialized) return;
    await langdetect.initLangDetect();
    _initialized = true;
  }

  /// 检测文本语种，返回 Azure 所需的 BCP-47 代码。
  ///
  /// 两层策略：
  /// 1. Unicode 区间预检：CJK / 泰文等字符集明确的语言直接返回，无需统计模型；
  /// 2. N-gram 统计模型：拉丁字母系语言（英/法/西/葡等）由 flutter_langdetect 判定。
  static String detectLanguage(String text) {
    if (text.isEmpty) return 'en-US';

    // Fast Unicode pre-check for scripts unambiguous by character range
    for (final code in text.runes) {
      if (_inRange(code, 0x4E00, 0x9FFF) || _inRange(code, 0x3400, 0x4DBF)) return 'zh-CN';
      if (_inRange(code, 0x3040, 0x309F) || _inRange(code, 0x30A0, 0x30FF)) return 'ja-JP';
      if (_inRange(code, 0xAC00, 0xD7AF)) return 'ko-KR';
      if (_inRange(code, 0x0E00, 0x0E7F)) return 'th-TH';
    }

    // 拉丁字母系语言：交给 n-gram 统计模型
    try {
      final iso = langdetect.detect(text);
      return _isoToBcp47(iso);
    } catch (_) {
      return 'en-US';
    }
  }

  /// 将 flutter_langdetect 返回的 ISO 639-1 代码映射为 Azure 所需的 BCP-47 语种标签。
  static String _isoToBcp47(String iso) => switch (iso) {
        'en' => 'en-US',
        'fr' => 'fr-FR',
        'es' => 'es-ES',
        'pt' => 'pt-PT',
        'zh-cn' => 'zh-CN',
        'zh-tw' => 'zh-CN',
        'ja' => 'ja-JP',
        'ko' => 'ko-KR',
        'th' => 'th-TH',
        _ => 'en-US',
      };

  static bool _inRange(int code, int low, int high) => code >= low && code <= high;

  Future<bool> checkPermission() async => await _recorder.hasPermission();

  Future<void> startRecording() async {
    debugPrint('PronunciationService: starting recording');
    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.wav,
        sampleRate: 16000,
        numChannels: 1,
      ),
      path: '${Directory.systemTemp.path}/assessment_recording.wav',
    );
  }

  Future<AssessmentResult> stopAndAssess(
    String referenceText, {
    String? language,
  }) async {
    final filePath = await _recorder.stop();
    if (filePath == null) {
      throw const AssessmentException('录音失败：未获取到音频文件');
    }

    final file = File(filePath);
    if (!await file.exists()) {
      throw const AssessmentException('录音失败：音频文件不存在');
    }

    final fileSize = await file.length();
    if (fileSize < _minAudioFileSize) {
      await file.delete();
      throw const AssessmentException('录音太短，请重试');
    }

    final lang = language ?? detectLanguage(referenceText);

    try {
      final wavBytes = await file.readAsBytes();

      debugPrint('PronunciationService: WAV size: ${wavBytes.length} bytes');

      // Parse WAV to extract raw PCM (handles non-standard headers)
      final pcmBytes = _extractPcmFromWav(wavBytes);
      if (pcmBytes == null || pcmBytes.isEmpty) {
        throw const AssessmentException('录音格式错误，请重试');
      }
      debugPrint('PronunciationService: PCM size: ${pcmBytes.length} bytes, '
          'WAV overhead: ${wavBytes.length - pcmBytes.length} bytes');

      // Rebuild a clean minimal WAV so Azure always gets a well-formed RIFF
      final cleanWav = _buildMinimalWav(pcmBytes);
      debugPrint('PronunciationService: Clean WAV size: ${cleanWav.length} bytes');

      debugPrint('PronunciationService: calling Azure API');
      final urlString = '$_baseUrl?language=$lang&format=detailed';
      final assessmentConfig =
          buildAssessmentConfig(referenceText: referenceText, language: lang);
      debugPrint('PronunciationService: URL: $urlString');
      debugPrint('PronunciationService: Assessment config: $assessmentConfig');
      debugPrint('PronunciationService: Key prefix: ${subscriptionKey.substring(0, 8)}...');

      final uri = Uri.parse(urlString);
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 15);
      try {
        final req = await client.postUrl(uri);
        req.headers.set('Ocp-Apim-Subscription-Key', subscriptionKey);
        req.headers.set('Content-Type', 'audio/wav; codecs=audio/pcm; samplerate=16000');
        req.headers.set('Pronunciation-Assessment', assessmentConfig);
        req.headers.set('Accept', 'application/json');
        req.contentLength = cleanWav.length;
        req.add(cleanWav);
        final resp = await req.close().timeout(const Duration(seconds: 15));

        final statusCode = resp.statusCode;
        final body = await resp.transform(utf8.decoder).join();
        debugPrint('PronunciationService: HTTP $statusCode');
        debugPrint('PronunciationService: Response body: $body');

        if (statusCode != 200) {
          throw AssessmentException('评估失败 ($statusCode): $body');
        }

        final json = jsonDecode(body) as Map<String, dynamic>;

        if (json['RecognitionStatus'] == 'NoMatch') {
          throw const AssessmentException('未识别到语音，请重试');
        }

        // 调试：打印 NBest 中所有 key，确认 ProsodyScore 是否存在
        final nbestList = json['NBest'] as List?;
        if (nbestList != null && nbestList.isNotEmpty) {
          final nbest = nbestList.first as Map<String, dynamic>;
          debugPrint('PronunciationService: NBest keys: ${nbest.keys.toList()}');
        }

        return AssessmentResult.fromAzureResponse(json, referenceText, language: lang);
      } finally {
        client.close();
      }
    } on SocketException catch (e) {
      throw AssessmentException('网络连接失败 (${e.message})');
    } on TimeoutException {
      throw const AssessmentException('请求超时，请检查网络');
    } on HttpException catch (e) {
      throw AssessmentException('服务器错误 (${e.message})');
    } on FormatException {
      throw const AssessmentException('评估失败，服务器返回异常数据');
    } finally {
      if (await file.exists()) {
        await file.delete();
      }
    }
  }

  void dispose() {
    _recorder.dispose();
  }
}

class AssessmentException implements Exception {
  final String message;
  const AssessmentException(this.message);

  @override
  String toString() => message;
}
