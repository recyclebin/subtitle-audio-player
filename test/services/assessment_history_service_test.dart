import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

import 'package:tingjian/models/assessment_result.dart';
import 'package:tingjian/services/assessment_history_service.dart';

void main() {
  group('AssessmentHistoryService', () {
    late Directory tmpDir;
    late AssessmentHistoryService service;

    setUp(() {
      tmpDir = Directory.systemTemp.createTempSync('assessment_history_test_');
      service = AssessmentHistoryService.withDirectory(tmpDir.path);
    });

    tearDown(() {
      if (tmpDir.existsSync()) {
        tmpDir.deleteSync(recursive: true);
      }
    });

    AssessmentResult makeResult(double score) => AssessmentResult(
          referenceText: 'hello',
          recognizedText: 'hello',
          overallScore: score,
          words: [],
        );

    test('append writes a JSONL line', () async {
      final record = AssessmentRecord(
        id: const Uuid().v4(),
        audioFilePath: '/tmp/test.mp3',
        subtitleIndex: 0,
        result: makeResult(90.0),
        timestamp: DateTime(2025, 1, 1),
      );

      await service.append(record);
      final records = await service.loadAll();
      expect(records.length, 1);
      expect(records.first.id, record.id);
      expect(records.first.result.overallScore, 90.0);
    });

    test('loadAll returns records sorted by timestamp descending', () async {
      final r1 = AssessmentRecord(
        id: '1',
        audioFilePath: '/f.mp3',
        subtitleIndex: 0,
        result: makeResult(50.0),
        timestamp: DateTime(2025, 1, 1),
      );
      final r2 = AssessmentRecord(
        id: '2',
        audioFilePath: '/f.mp3',
        subtitleIndex: 1,
        result: makeResult(80.0),
        timestamp: DateTime(2025, 1, 2),
      );

      await service.append(r1);
      await service.append(r2);

      final records = await service.loadAll();
      expect(records.length, 2);
      expect(records[0].id, '2');
      expect(records[1].id, '1');
    });

    test('loadByFile groups by audio file path', () async {
      final r1 = AssessmentRecord(
        id: '1',
        audioFilePath: '/f1.mp3',
        subtitleIndex: 0,
        result: makeResult(50.0),
        timestamp: DateTime(2025, 1, 1),
      );
      final r2 = AssessmentRecord(
        id: '2',
        audioFilePath: '/f2.mp3',
        subtitleIndex: 0,
        result: makeResult(80.0),
        timestamp: DateTime(2025, 1, 2),
      );

      await service.append(r1);
      await service.append(r2);

      final byFile = await service.loadByFile();
      expect(byFile.keys.length, 2);
      expect(byFile['/f1.mp3']!.records.length, 1);
      expect(byFile['/f2.mp3']!.records.length, 1);
      expect(byFile['/f1.mp3']!.averageScore, 50.0);
    });

    test('empty history returns empty list', () async {
      final records = await service.loadAll();
      expect(records, isEmpty);
    });
  });
}
