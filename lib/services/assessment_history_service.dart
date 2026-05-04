import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:tingjian/models/assessment_result.dart';

class AssessmentRecord {
  final String id;
  final String audioFilePath;
  final int subtitleIndex;
  final AssessmentResult result;
  final DateTime timestamp;

  const AssessmentRecord({
    required this.id,
    required this.audioFilePath,
    required this.subtitleIndex,
    required this.result,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'audioFilePath': audioFilePath,
        'subtitleIndex': subtitleIndex,
        'result': result.toJson(),
        'timestamp': timestamp.toIso8601String(),
      };

  factory AssessmentRecord.fromJson(Map<String, dynamic> json) =>
      AssessmentRecord(
        id: json['id'] as String? ?? '',
        audioFilePath: json['audioFilePath'] as String? ?? '',
        subtitleIndex: json['subtitleIndex'] as int? ?? 0,
        result: AssessmentResult.fromJson(
            json['result'] as Map<String, dynamic>),
        timestamp: DateTime.parse(json['timestamp'] as String? ?? '2000-01-01'),
      );
}

class FileGroup {
  final String audioFilePath;
  final List<AssessmentRecord> records;
  final double averageScore;

  const FileGroup({
    required this.audioFilePath,
    required this.records,
    required this.averageScore,
  });
}

class AssessmentHistoryService {
  final String _dirPath;

  AssessmentHistoryService._(this._dirPath);

  static Future<AssessmentHistoryService> create() async {
    final appDir = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(appDir.path, 'assessment_history'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return AssessmentHistoryService._(dir.path);
  }

  /// Testing constructor — uses a specific directory.
  AssessmentHistoryService.withDirectory(String dirPath) : _dirPath = dirPath;

  String _todayFile() {
    final now = DateTime.now();
    final y = now.year.toString().padLeft(4, '0');
    final m = now.month.toString().padLeft(2, '0');
    final d = now.day.toString().padLeft(2, '0');
    return p.join(_dirPath, '$y-$m-$d.jsonl');
  }

  Future<void> append(AssessmentRecord record) async {
    final file = File(_todayFile());
    await file.parent.create(recursive: true);
    final line = jsonEncode(record.toJson());
    final sink = file.openWrite(mode: FileMode.append);
    sink.writeln(line);
    await sink.flush();
    await sink.close();
  }

  Future<List<AssessmentRecord>> loadAll() async {
    final dir = Directory(_dirPath);
    if (!await dir.exists()) {
      return [];
    }

    final records = <AssessmentRecord>[];
    await for (final entity in dir.list()) {
      if (entity is File && p.extension(entity.path) == '.jsonl') {
        final lines = await entity.readAsLines();
        for (final line in lines) {
          if (line.trim().isEmpty) continue;
          final json = jsonDecode(line) as Map<String, dynamic>;
          records.add(AssessmentRecord.fromJson(json));
        }
      }
    }

    records.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return records;
  }

  Future<Map<String, FileGroup>> loadByFile() async {
    final records = await loadAll();
    final grouped = <String, List<AssessmentRecord>>{};

    for (final record in records) {
      grouped.putIfAbsent(record.audioFilePath, () => []).add(record);
    }

    return grouped.map((path, recs) {
      final avg = recs.fold<double>(0, (sum, r) => sum + r.result.overallScore) /
          recs.length;
      return MapEntry(
        path,
        FileGroup(
          audioFilePath: path,
          records: recs,
          averageScore: avg,
        ),
      );
    });
  }
}
