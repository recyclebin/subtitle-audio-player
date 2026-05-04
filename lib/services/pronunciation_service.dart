import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:record/record.dart';

import '../models/assessment_result.dart';

enum AssessmentMode { afterSubtitle, karaoke }

class PronunciationService {
  static const _minAudioFileSize = 1600; // ~0.1s of 16kHz mono WAV

  final String subscriptionKey;
  final String region;
  final AudioRecorder _recorder;

  PronunciationService({
    required this.subscriptionKey,
    required this.region,
  }) : _recorder = AudioRecorder();

  String get _baseUrl =>
      'https://$region.stt.speech.microsoft.com/speech/recognition/conversation/cognitiveservices/v1';

  String buildAssessmentConfig({
    required String referenceText,
    required String language,
  }) {
    return jsonEncode({
      'ReferenceText': referenceText,
      'GradingSystem': 'FivePoint',
      'Granularity': 'Phoneme',
    });
  }

  String detectLanguage(String text) {
    if (text.isEmpty) return 'en-US';
    final first = text.runes.first;
    if (_inRange(first, 0x4E00, 0x9FFF) || _inRange(first, 0x3400, 0x4DBF)) {
      return 'zh-CN';
    }
    if (_inRange(first, 0x3040, 0x309F) || _inRange(first, 0x30A0, 0x30FF)) {
      return 'ja-JP';
    }
    if (_inRange(first, 0xAC00, 0xD7AF)) return 'ko-KR';
    return 'en-US';
  }

  bool _inRange(int code, int low, int high) => code >= low && code <= high;

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
      final bytes = await file.readAsBytes();

      debugPrint('PronunciationService: calling Azure API (${bytes.length} bytes)');
      final response = await http
          .post(
            Uri.parse('$_baseUrl?language=$lang'),
            headers: {
              'Ocp-Apim-Subscription-Key': subscriptionKey,
              'Content-Type': 'audio/wav; codecs=audio/pcm; samplerate=16000',
              'Pronunciation-Assessment':
                  buildAssessmentConfig(referenceText: referenceText, language: lang),
            },
            body: bytes,
          )
          .timeout(const Duration(seconds: 15));

      debugPrint('PronunciationService: HTTP ${response.statusCode}');

      if (response.statusCode != 200) {
        throw AssessmentException('评估失败，请检查网络 (${response.statusCode})');
      }

      final json = jsonDecode(response.body) as Map<String, dynamic>;

      if (json['RecognitionStatus'] == 'NoMatch') {
        throw const AssessmentException('未识别到语音，请重试');
      }

      return AssessmentResult.fromAzureResponse(json, referenceText);
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
