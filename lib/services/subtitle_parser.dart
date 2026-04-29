import 'package:flutter_charset_detector/flutter_charset_detector.dart';
import 'dart:io';
import 'dart:typed_data';

class Subtitle {
  final Duration startTime;
  final Duration endTime;
  final String text;

  Subtitle(
      {required this.startTime, required this.endTime, required this.text});
}

// 顶层 RegExp 常量：每行解析时复用，避免在循环里反复构造。
final _htmlTagPattern = RegExp(r'<[^>]*>');
final _seqLinePattern = RegExp(r'^\d+$');
final _leadingDigitsPattern = RegExp(r'^\d+');

String _removeHtmlTags(String text) {
  return text.replaceAll(_htmlTagPattern, '');
}

String _decodeHtmlEntities(String text) {
  return text
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&apos;', "'")
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&nbsp;', ' ');
}

Future<List<Subtitle>> parseSrtFile(String filePath) async {
  File file = File(filePath);
  Uint8List fileBytes = await file.readAsBytes();

  List<Subtitle> subtitles = [];
  Duration start = Duration.zero;
  Duration end = Duration.zero;
  StringBuffer textBuffer = StringBuffer();
  bool newSubtitleLine = false;

  // 自动检测编码（支持 UTF-8、GBK 等），避免中文乱码
  DecodingResult result = await CharsetDetector.autoDecode(fileBytes);
  String fileContent = result.string;
  // 部分编码器会在 BOM 前后留下 null 字节
  fileContent = fileContent.replaceAll('\x00', '');

  List<String> lines = fileContent.split('\n');

  for (var line in lines) {
    line = line.trim();

    if (line.isEmpty && newSubtitleLine) {
      // 与时间戳行分支保持一致：要求文本非空才提交，避免空字幕混入列表
      if (textBuffer.isNotEmpty && end > start) {
        final text = textBuffer.toString().trim();
        if (text.isNotEmpty) {
          subtitles.add(Subtitle(startTime: start, endTime: end, text: text));
        }
      }
      textBuffer.clear();
      newSubtitleLine = false;
    } else if (_seqLinePattern.hasMatch(line)) {
      // 行号行，标记下一行起始；先于 --> 检查，防止纯数字误判
      newSubtitleLine = true;
    } else if (line.contains('-->')) {
      // 时间戳行：无论 newSubtitleLine 是否为 true 都解析并更新 start/end。
      // 后续文本会正常缓冲，下一个空行或 EOF 时正常 flush。
      // 若序号行缺失，块仍会被输出（宽容解析），而非静默丢弃。
      var timestamps = line.split(' --> ');
      if (timestamps.length < 2) continue;
      try {
        // 先解析到临时变量，避免解析失败时污染 start/end
        final newStart = _parseDuration(timestamps[0].trim());
        final newEnd = _parseDuration(timestamps[1].trim());
        // 缺少空行分隔符时 textBuffer 可能还有上一个有效块的内容，先 flush
        if (textBuffer.isNotEmpty && end > start) {
          final text = textBuffer.toString().trim();
          if (text.isNotEmpty) {
            subtitles.add(
                Subtitle(startTime: start, endTime: end, text: text));
          }
          textBuffer.clear();
        }
        start = newStart;
        end = newEnd;
      } on FormatException {
        // 时间戳解析失败：start/end 未被污染，丢弃当前块
        newSubtitleLine = false;
        textBuffer.clear();
        continue;
      }
    } else if (line.isNotEmpty) {
      textBuffer.writeln(_decodeHtmlEntities(_removeHtmlTags(line)));
    }
  }

  // 文件末尾可能没有空行，手动收尾；end <= start 说明时间戳从未被正确解析，跳过
  if (textBuffer.isNotEmpty && end > start) {
    final text = textBuffer.toString().trim();
    if (text.isNotEmpty) {
      subtitles.add(Subtitle(startTime: start, endTime: end, text: text));
    }
  }

  return subtitles;
}

Duration _parseDuration(String timestamp) {
  var parts = timestamp.split(':');
  if (parts.length < 3) {
    throw FormatException('字幕时间戳格式错误：$timestamp');
  }
  final hours = int.tryParse(parts[0]);
  final minutes = int.tryParse(parts[1]);
  if (hours == null || minutes == null) {
    throw FormatException('字幕时间戳格式错误：$timestamp');
  }
  var secondsPart = parts[2];
  // 标准 SRT 用 ',' 分隔毫秒，部分工具输出 '.'；两者均无时 indexOf 返回 -1，
  // sepIndex < 0 分支按无毫秒处理。
  final sepIndex = secondsPart.contains(',')
      ? secondsPart.indexOf(',')
      : secondsPart.indexOf('.');
  final seconds = int.tryParse(
      sepIndex >= 0 ? secondsPart.substring(0, sepIndex) : secondsPart);
  if (seconds == null) throw FormatException('字幕时间戳格式错误：$timestamp');
  // SRT 标准为 3 位毫秒；非标准短值右补零到 3 位再截断，避免时序偏差
  final int milliseconds;
  if (sepIndex >= 0) {
    // 取分隔符后的纯数字前缀，忽略非标准 SRT 中可能附加的位置标记（如 " align:left"）
    final msRaw = _leadingDigitsPattern.stringMatch(secondsPart.substring(sepIndex + 1)) ?? '';
    if (msRaw.isEmpty) throw FormatException('字幕时间戳格式错误：$timestamp');
    final msNormalized = msRaw.padRight(3, '0').substring(0, 3);
    milliseconds = int.tryParse(msNormalized) ??
        (throw FormatException('字幕时间戳格式错误：$timestamp'));
  } else {
    milliseconds = 0;
  }

  return Duration(
      hours: hours,
      minutes: minutes,
      seconds: seconds,
      milliseconds: milliseconds);
}
