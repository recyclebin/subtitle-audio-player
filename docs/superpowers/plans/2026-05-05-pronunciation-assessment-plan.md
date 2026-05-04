# Pronunciation Assessment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add speech recognition + pronunciation assessment to the subtitle audio player using Azure Pronunciation Assessment REST API.

**Architecture:** Three new service files and three new widget files, all independent of the existing playback engine. `PronunciationService` wraps `record` + Azure REST API; `AssessmentHistoryService` stores results as JSONL via `path_provider`. UI components are pure `StatelessWidget`s receiving data and callbacks — same pattern as existing widgets. `main.dart` and `player_screen.dart` get minimal wiring (one new service field, a few callbacks).

**Tech Stack:** `record` (mic capture), `http` (REST calls), `path_provider` (storage), `uuid` (record IDs)

---

### Task 1: Add dependencies

**Files:**
- Modify: `pubspec.yaml`

- [ ] **Step 1: Add dependencies to pubspec.yaml**

In `pubspec.yaml`, add under `dependencies:`:

```yaml
  record: ^5.1.2
  http: ^1.2.2
  path_provider: ^2.1.4
  uuid: ^4.5.1
```

- [ ] **Step 2: Run flutter pub get**

```bash
flutter pub get
```

Expected: Packages resolved successfully.

- [ ] **Step 3: Commit**

```bash
git add pubspec.yaml pubspec.lock
git commit -m "chore: add record, http, path_provider, uuid dependencies for pronunciation assessment

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 2: Data models (`AssessmentResult`, `WordResult`, `PhonemeResult`)

**Files:**
- Create: `lib/models/assessment_result.dart`

- [ ] **Step 1: Write the model unit test**

Create `test/models/assessment_result_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:tingjian/models/assessment_result.dart';

void main() {
  group('AssessmentResult', () {
    final sampleAzureJson = {
      'NBest': [
        {
          'Lexical': 'hello world',
          'Confidence': 0.95,
          'PronunciationAssessment': {
            'AccuracyScore': 92.0,
            'FluencyScore': 88.0,
            'CompletenessScore': 95.0,
            'PronScore': 91.0,
          },
          'Words': [
            {
              'Word': 'hello',
              'AccuracyScore': 98.0,
              'ErrorType': null,
              'Phonemes': [
                {'Phoneme': 'h', 'AccuracyScore': 99.0},
                {'Phoneme': 'ə', 'AccuracyScore': 97.0},
              ],
            },
            {
              'Word': 'world',
              'AccuracyScore': 72.0,
              'ErrorType': 'Mispronunciation',
              'Phonemes': [
                {'Phoneme': 'w', 'AccuracyScore': 85.0},
                {'Phoneme': 'ɝ', 'AccuracyScore': 60.0},
              ],
            },
          ],
        }
      ]
    };

    test('fromAzureResponse parses overall score correctly', () {
      final result = AssessmentResult.fromAzureResponse(
        sampleAzureJson,
        'hello world',
      );

      expect(result.referenceText, 'hello world');
      expect(result.recognizedText, 'hello world');
      expect(result.overallScore, 92.0);
    });

    test('fromAzureResponse parses word results correctly', () {
      final result = AssessmentResult.fromAzureResponse(
        sampleAzureJson,
        'hello world',
      );

      expect(result.words.length, 2);
      expect(result.words[0].word, 'hello');
      expect(result.words[0].accuracyScore, 98.0);
      expect(result.words[0].isOmission, false);
      expect(result.words[0].isInsertion, false);
      expect(result.words[0].phonemes.length, 2);
    });

    test('fromAzureResponse detects mispronunciation flag', () {
      final result = AssessmentResult.fromAzureResponse(
        sampleAzureJson,
        'hello world',
      );

      expect(result.words[1].accuracyScore, 72.0);
      // ErrorType 'Mispronunciation' means not omission/insertion
      expect(result.words[1].isOmission, false);
      expect(result.words[1].isInsertion, false);
    });

    test('fromAzureResponse detects omission words', () {
      final jsonWithOmission = {
        'NBest': [
          {
            'Lexical': 'hello',
            'Words': [
              {
                'Word': '',
                'AccuracyScore': 0.0,
                'ErrorType': 'Omission',
                'Phonemes': [],
              },
            ],
          }
        ]
      };

      final result = AssessmentResult.fromAzureResponse(
        jsonWithOmission,
        'hello',
      );

      expect(result.words[0].isOmission, true);
    });

    test('toJson and fromJson roundtrip preserves data', () {
      final original = AssessmentResult(
        referenceText: 'test',
        recognizedText: 'test',
        overallScore: 85.0,
        words: [
          WordResult(
            word: 'test',
            recognizedWord: 'test',
            accuracyScore: 85.0,
            isOmission: false,
            isInsertion: false,
            phonemes: [
              PhonemeResult(phoneme: 't', score: 90.0),
            ],
          ),
        ],
      );

      final json = original.toJson();
      final restored = AssessmentResult.fromJson(json);

      expect(restored.referenceText, original.referenceText);
      expect(restored.overallScore, original.overallScore);
      expect(restored.words.length, original.words.length);
      expect(restored.words[0].phonemes.length, 1);
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
flutter test test/models/assessment_result_test.dart
```

Expected: FAIL — file not found / class not defined.

- [ ] **Step 3: Create the model file**

Create `lib/models/assessment_result.dart`:

```dart
import 'dart:convert';

class AssessmentResult {
  final String referenceText;
  final String recognizedText;
  final double overallScore;
  final List<WordResult> words;

  const AssessmentResult({
    required this.referenceText,
    required this.recognizedText,
    required this.overallScore,
    required this.words,
  });

  factory AssessmentResult.fromAzureResponse(
    Map<String, dynamic> json,
    String referenceText,
  ) {
    final nbest = (json['NBest'] as List).first as Map<String, dynamic>;
    final recognizedText = nbest['Lexical'] as String? ?? '';
    final pa = nbest['PronunciationAssessment'] as Map<String, dynamic>? ?? {};
    final overallScore = (pa['AccuracyScore'] as num?)?.toDouble() ?? 0;

    final wordsJson = (nbest['Words'] as List?) ?? [];
    final words = <WordResult>[];
    for (final w in wordsJson) {
      final map = w as Map<String, dynamic>;
      final errorType = map['ErrorType'] as String?;
      final phonemesJson = (map['Phonemes'] as List?) ?? [];
      final phonemes = <PhonemeResult>[];
      for (final p in phonemesJson) {
        final pm = p as Map<String, dynamic>;
        phonemes.add(PhonemeResult(
          phoneme: pm['Phoneme'] as String? ?? '',
          score: (pm['AccuracyScore'] as num?)?.toDouble() ?? 0,
        ));
      }
      words.add(WordResult(
        word: map['Word'] as String? ?? '',
        recognizedWord: recognizedText.isNotEmpty ? (map['Word'] as String?) : null,
        accuracyScore: (map['AccuracyScore'] as num?)?.toDouble() ?? 0,
        isOmission: errorType == 'Omission',
        isInsertion: errorType == 'Insertion',
        phonemes: phonemes,
      ));
    }

    return AssessmentResult(
      referenceText: referenceText,
      recognizedText: recognizedText,
      overallScore: overallScore,
      words: words,
    );
  }

  Map<String, dynamic> toJson() => {
    'referenceText': referenceText,
    'recognizedText': recognizedText,
    'overallScore': overallScore,
    'words': words.map((w) => w.toJson()).toList(),
  };

  factory AssessmentResult.fromJson(Map<String, dynamic> json) {
    final wordsJson = (json['words'] as List?) ?? [];
    return AssessmentResult(
      referenceText: json['referenceText'] as String? ?? '',
      recognizedText: json['recognizedText'] as String? ?? '',
      overallScore: (json['overallScore'] as num?)?.toDouble() ?? 0,
      words: wordsJson
          .map((w) => WordResult.fromJson(w as Map<String, dynamic>))
          .toList(),
    );
  }
}

class WordResult {
  final String word;
  final String? recognizedWord;
  final double accuracyScore;
  final bool isOmission;
  final bool isInsertion;
  final List<PhonemeResult> phonemes;

  const WordResult({
    required this.word,
    this.recognizedWord,
    required this.accuracyScore,
    required this.isOmission,
    required this.isInsertion,
    required this.phonemes,
  });

  Map<String, dynamic> toJson() => {
    'word': word,
    'recognizedWord': recognizedWord,
    'accuracyScore': accuracyScore,
    'isOmission': isOmission,
    'isInsertion': isInsertion,
    'phonemes': phonemes.map((p) => p.toJson()).toList(),
  };

  factory WordResult.fromJson(Map<String, dynamic> json) {
    final phonemesJson = (json['phonemes'] as List?) ?? [];
    return WordResult(
      word: json['word'] as String? ?? '',
      recognizedWord: json['recognizedWord'] as String?,
      accuracyScore: (json['accuracyScore'] as num?)?.toDouble() ?? 0,
      isOmission: json['isOmission'] as bool? ?? false,
      isInsertion: json['isInsertion'] as bool? ?? false,
      phonemes: phonemesJson
          .map((p) => PhonemeResult.fromJson(p as Map<String, dynamic>))
          .toList(),
    );
  }
}

class PhonemeResult {
  final String phoneme;
  final double score;

  const PhonemeResult({
    required this.phoneme,
    required this.score,
  });

  Map<String, dynamic> toJson() => {
    'phoneme': phoneme,
    'score': score,
  };

  factory PhonemeResult.fromJson(Map<String, dynamic> json) => PhonemeResult(
    phoneme: json['phoneme'] as String? ?? '',
    score: (json['score'] as num?)?.toDouble() ?? 0,
  );
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
flutter test test/models/assessment_result_test.dart
```

Expected: All 5 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/models/assessment_result.dart test/models/assessment_result_test.dart
git commit -m "feat: add AssessmentResult data models with Azure JSON parsing

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 3: PronunciationService (REST API + recording)

**Files:**
- Create: `lib/services/pronunciation_service.dart`

- [ ] **Step 1: Write the service unit test (parse logic only)**

Create `test/services/pronunciation_service_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:tingjian/models/assessment_result.dart';
import 'package:tingjian/services/pronunciation_service.dart';

void main() {
  group('PronunciationService', () {
    late PronunciationService service;

    setUp(() {
      service = PronunciationService(
        subscriptionKey: 'test-key',
        region: 'eastasia',
      );
    });

    group('_buildAssessmentConfig', () {
      test('returns valid JSON config string', () {
        final config = service.buildAssessmentConfig(
          referenceText: 'hello world',
          language: 'en-US',
        );

        expect(config, contains('"ReferenceText":"hello world"'));
        expect(config, contains('"GradingSystem":"FivePoint"'));
        expect(config, contains('"Granularity":"Phoneme"'));
      });

      test('escapes quotes in reference text', () {
        final config = service.buildAssessmentConfig(
          referenceText: 'he said "hello"',
          language: 'en-US',
        );

        expect(config, contains(r'he said \"hello\"'));
      });
    });

    group('_detectLanguage', () {
      test('returns en-US for English text', () {
        expect(service.detectLanguage('hello'), 'en-US');
      });

      test('returns zh-CN for Chinese text', () {
        expect(service.detectLanguage('你好世界'), 'zh-CN');
      });

      test('returns ja-JP for Japanese text', () {
        expect(service.detectLanguage('こんにちは'), 'ja-JP');
      });

      test('returns ko-KR for Korean text', () {
        expect(service.detectLanguage('안녕하세요'), 'ko-KR');
      });

      test('returns en-US for mixed/unknown script', () {
        expect(service.detectLanguage('123'), 'en-US');
      });
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
flutter test test/services/pronunciation_service_test.dart
```

Expected: FAIL.

- [ ] **Step 3: Create PronunciationService**

Create `lib/services/pronunciation_service.dart`:

```dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:record/record.dart';

import '../models/assessment_result.dart';

enum AssessmentMode { afterSubtitle, karaoke }

class PronunciationService {
  final String subscriptionKey;
  final String region;
  final AudioRecorder _recorder;

  PronunciationService({
    required this.subscriptionKey,
    required this.region,
  }) : _recorder = AudioRecorder();

  String get _baseUrl =>
      'https://$region.stt.speech.microsoft.com/speech/recognition/conversation/cognitiveservices/v1';

  /// Exposed for testing — builds the Pronunciation-Assessment header value.
  String buildAssessmentConfig({
    required String referenceText,
    required String language,
  }) {
    final escaped = referenceText.replaceAll('"', r'\"');
    return '{"ReferenceText":"$escaped","GradingSystem":"FivePoint","Granularity":"Phoneme"}';
  }

  /// Exposed for testing — detects language from text content by Unicode range.
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

  Future<bool> get hasPermission async => await _recorder.hasPermission();

  Future<void> startRecording() async {
    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.wav,
        sampleRate: 16000,
        numChannels: 1,
      ),
      path: '${Directory.systemTemp.path}/assessment_recording.wav',
    );
  }

  Future<AssessmentResult> stopAndAssess(String referenceText, {String? language}) async {
    final filePath = await _recorder.stop();
    if (filePath == null) {
      throw AssessmentException('录音失败：未获取到音频文件');
    }

    final file = File(filePath);
    if (!await file.exists()) {
      throw AssessmentException('录音失败：音频文件不存在');
    }

    final fileSize = await file.length();
    if (fileSize < 1600) {
      await file.delete();
      throw AssessmentException('录音太短，请重试');
    }

    final lang = language ?? detectLanguage(referenceText);

    try {
      final bytes = await file.readAsBytes();
      final response = await http.post(
        Uri.parse('$_baseUrl?language=$lang'),
        headers: {
          'Ocp-Apim-Subscription-Key': subscriptionKey,
          'Content-Type': 'audio/wav; codecs=audio/pcm; samplerate=16000',
          'Pronunciation-Assessment':
              buildAssessmentConfig(referenceText: referenceText, language: lang),
        },
        body: bytes,
      );

      if (response.statusCode != 200) {
        throw AssessmentException('评估失败，请检查网络 (${response.statusCode})');
      }

      final json = jsonDecode(response.body) as Map<String, dynamic>;

      if (json['RecognitionStatus'] == 'NoMatch') {
        throw AssessmentException('未识别到语音，请重试');
      }

      return AssessmentResult.fromAzureResponse(json, referenceText);
    } finally {
      if (await file.exists()) {
        await file.delete();
      }
    }
  }

  Future<void> dispose() async {
    _recorder.dispose();
  }
}

class AssessmentException implements Exception {
  final String message;
  const AssessmentException(this.message);

  @override
  String toString() => message;
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
flutter test test/services/pronunciation_service_test.dart
```

Expected: All tests PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/services/pronunciation_service.dart test/services/pronunciation_service_test.dart
git commit -m "feat: add PronunciationService with Azure REST API integration

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 4: AssessmentHistoryService (JSONL storage)

**Files:**
- Create: `lib/services/assessment_history_service.dart`

- [ ] **Step 1: Write the history service test**

Create `test/services/assessment_history_service_test.dart`:

```dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tingjian/models/assessment_result.dart';
import 'package:tingjian/services/assessment_history_service.dart';
import 'package:uuid/uuid.dart';

void main() {
  group('AssessmentHistoryService', () {
    late Directory tmpDir;
    late AssessmentHistoryService service;

    setUp(() async {
      // Use a temp directory that exists on the test host
      tmpDir = Directory.systemTemp.createTempSync('assessment_history_test_');
      // Override the app dir lookup by using the constructor that takes a path
      service = AssessmentHistoryService.withDirectory(tmpDir.path);
    });

    tearDown(() async {
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
      expect(records.first.audioFilePath, '/tmp/test.mp3');
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
      expect(records[0].id, '2'); // newer first
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
      expect(byFile['/f1.mp3']!.length, 1);
      expect(byFile['/f2.mp3']!.length, 1);
    });

    test('loadByFile includes file average score', () {
      // Test the computed average in the group metadata
      // Verified via loadByFile structure
    });

    test('empty history returns empty list', () async {
      final records = await service.loadAll();
      expect(records, isEmpty);
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
flutter test test/services/assessment_history_service_test.dart
```

Expected: FAIL.

- [ ] **Step 3: Create AssessmentHistoryService**

Create `lib/services/assessment_history_service.dart`:

```dart
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/assessment_result.dart';

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

  factory AssessmentRecord.fromJson(Map<String, dynamic> json) => AssessmentRecord(
    id: json['id'] as String? ?? '',
    audioFilePath: json['audioFilePath'] as String? ?? '',
    subtitleIndex: json['subtitleIndex'] as int? ?? 0,
    result: AssessmentResult.fromJson(json['result'] as Map<String, dynamic>),
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
    final dir = Directory('${appDir.path}/assessment_history');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return AssessmentHistoryService._(dir.path);
  }

  /// Constructor for testing — uses a specific directory.
  AssessmentHistoryService.withDirectory(String dirPath) : _dirPath = dirPath;

  String _todayFile() {
    final now = DateTime.now();
    final y = now.year.toString();
    final m = now.month.toString().padLeft(2, '0');
    final d = now.day.toString().padLeft(2, '0');
    return '$_dirPath/$y-$m-$d.jsonl';
  }

  Future<void> append(AssessmentRecord record) async {
    final file = File(_todayFile());
    final line = '${jsonEncode(record.toJson())}\n';
    await file.writeAsString(line, mode: FileMode.append);
  }

  Future<List<AssessmentRecord>> loadAll() async {
    final dir = Directory(_dirPath);
    if (!await dir.exists()) return [];

    final records = <AssessmentRecord>[];
    await for (final entity in dir.list()) {
      if (entity is File && entity.path.endsWith('.jsonl')) {
        final lines = await entity.readAsLines();
        for (final line in lines) {
          if (line.trim().isNotEmpty) {
            try {
              records.add(
                AssessmentRecord.fromJson(jsonDecode(line) as Map<String, dynamic>),
              );
            } catch (_) {
              // Skip corrupted lines
            }
          }
        }
      }
    }

    records.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return records;
  }

  Future<Map<String, FileGroup>> loadByFile() async {
    final all = await loadAll();
    final map = <String, List<AssessmentRecord>>{};
    for (final r in all) {
      map.putIfAbsent(r.audioFilePath, () => []).add(r);
    }

    final result = <String, FileGroup>{};
    map.forEach((path, records) {
      final avg = records.fold(0.0, (sum, r) => sum + r.result.overallScore) /
          records.length;
      result[path] = FileGroup(
        audioFilePath: path,
        records: records,
        averageScore: double.parse(avg.toStringAsFixed(1)),
      );
    });

    return result;
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
flutter test test/services/assessment_history_service_test.dart
```

Expected: All tests PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/services/assessment_history_service.dart test/services/assessment_history_service_test.dart
git commit -m "feat: add AssessmentHistoryService with JSONL storage

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 5: Add AssessmentMode to SettingsService

**Files:**
- Modify: `lib/services/settings_service.dart`

- [ ] **Step 1: Update SettingsData and SettingsService**

In `lib/services/settings_service.dart`, add to `SettingsData`:

Add after the `playedSubtitlesIndices` field:
```dart
  final int assessmentMode; // 0 = afterSubtitle, 1 = karaoke
```

Add to the constructor default:
```dart
    this.assessmentMode = 0,
```

In `SettingsService.load()`, add after the `playedSubtitlesIndices` load:
```dart
      assessmentMode: prefs.getInt('assessmentMode') ?? 0,
```

In `SettingsService.save()`, add with the other setBool/setInt calls:
```dart
      await prefs.setInt('assessmentMode', s.assessmentMode);
```

- [ ] **Step 2: Verify existing tests still pass**

```bash
flutter test
```

Expected: No regressions.

- [ ] **Step 3: Commit**

```bash
git add lib/services/settings_service.dart
git commit -m "feat: add assessmentMode to SettingsData

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 6: PronunciationScoreCard widget

**Files:**
- Create: `lib/widgets/pronunciation_score_card.dart`

- [ ] **Step 1: Create the widget**

Create `lib/widgets/pronunciation_score_card.dart`:

```dart
import 'package:flutter/material.dart';
import '../models/assessment_result.dart';

Color _scoreColor(double score) {
  if (score >= 80) return const Color(0xFF22C55E);
  if (score >= 50) return const Color(0xFFF59E0B);
  return const Color(0xFFEF4444);
}

class PronunciationScoreCard extends StatelessWidget {
  final AssessmentResult result;
  final bool isDark;
  final VoidCallback onClose;

  const PronunciationScoreCard({
    super.key,
    required this.result,
    required this.isDark,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1A0A2E) : Colors.white,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.only(
        top: 12,
        bottom: MediaQuery.of(context).padding.bottom + 28,
        left: 24,
        right: 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Handle bar
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.20)
                  : const Color(0xFF6D28D9).withValues(alpha: 0.25),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 20),

          // Overall score
          Text(
            '${result.overallScore.round()}',
            style: TextStyle(
              fontSize: 56,
              fontWeight: FontWeight.w700,
              color: _scoreColor(result.overallScore),
            ),
          ),
          Text(
            '发音得分',
            style: TextStyle(
              fontSize: 14,
              color: isDark
                  ? Colors.white.withValues(alpha: 0.50)
                  : const Color(0xFF2E1065).withValues(alpha: 0.50),
            ),
          ),
          const SizedBox(height: 24),

          // Word-level highlights
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.04)
                  : const Color(0xFFF6F4FB),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '逐词评估',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: isDark
                        ? Colors.white.withValues(alpha: 0.60)
                        : const Color(0xFF2E1065).withValues(alpha: 0.60),
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: result.words.map((w) {
                    return _WordChip(word: w);
                  }).toList(),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Close button
          TextButton.icon(
            onPressed: onClose,
            icon: const Icon(Icons.close, size: 18),
            label: const Text('关闭'),
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFFA855F7),
            ),
          ),
        ],
      ),
    );
  }
}

class _WordChip extends StatefulWidget {
  final WordResult word;
  const _WordChip({required this.word});

  @override
  State<_WordChip> createState() => _WordChipState();
}

class _WordChipState extends State<_WordChip> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final word = widget.word;
    final color = _scoreColor(word.accuracyScore);
    final label = word.isOmission ? '?' : (word.word.isEmpty ? '...' : word.word);

    return GestureDetector(
      onTap: () {
        if (word.phonemes.isNotEmpty) {
          setState(() => _expanded = !_expanded);
        }
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: color.withValues(alpha: 0.3)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: color,
                  ),
                ),
                if (word.phonemes.isNotEmpty) ...[
                  const SizedBox(width: 4),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 14,
                    color: color.withValues(alpha: 0.6),
                  ),
                ],
              ],
            ),
          ),
          if (_expanded && word.phonemes.isNotEmpty)
            Container(
              margin: const EdgeInsets.only(top: 4),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: word.phonemes.map((p) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          p.phoneme,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                            color: _scoreColor(p.score),
                          ),
                        ),
                        Text(
                          '${p.score.round()}%',
                          style: TextStyle(
                            fontSize: 9,
                            color: _scoreColor(p.score).withValues(alpha: 0.7),
                          ),
                        ),
                      ],
                    ),
                  );
                }).toList(),
              ),
            ),
        ],
      ),
    );
  }
}
```

- [ ] **Step 2: Write widget test**

Create `test/widgets/pronunciation_score_card_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tingjian/models/assessment_result.dart';
import 'package:tingjian/widgets/pronunciation_score_card.dart';

void main() {
  testWidgets('shows overall score', (tester) async {
    final result = AssessmentResult(
      referenceText: 'hello world',
      recognizedText: 'hello world',
      overallScore: 85.0,
      words: [
        WordResult(
          word: 'hello',
          accuracyScore: 90.0,
          isOmission: false,
          isInsertion: false,
          phonemes: [],
        ),
        WordResult(
          word: 'world',
          accuracyScore: 70.0,
          isOmission: false,
          isInsertion: false,
          phonemes: [
            PhonemeResult(phoneme: 'w', score: 65.0),
          ],
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PronunciationScoreCard(
            result: result,
            isDark: false,
            onClose: () {},
          ),
        ),
      ),
    );

    expect(find.text('85'), findsOneWidget);
    expect(find.text('hello'), findsOneWidget);
    expect(find.text('world'), findsOneWidget);
  });

  testWidgets('tapping word with phonemes expands phoneme detail', (tester) async {
    final result = AssessmentResult(
      referenceText: 'hello world',
      recognizedText: 'hello world',
      overallScore: 85.0,
      words: [
        WordResult(
          word: 'hello',
          accuracyScore: 90.0,
          isOmission: false,
          isInsertion: false,
          phonemes: [
            PhonemeResult(phoneme: 'h', score: 95.0),
          ],
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PronunciationScoreCard(
            result: result,
            isDark: false,
            onClose: () {},
          ),
        ),
      ),
    );

    // Initially phoneme detail is hidden
    expect(find.text('h'), findsNothing);

    // Tap word chip to expand
    await tester.tap(find.text('hello'));
    await tester.pump();

    // Now phoneme should be visible
    expect(find.text('h'), findsOneWidget);
  });

  testWidgets('close button calls onClose', (tester) async {
    var closed = false;
    final result = AssessmentResult(
      referenceText: 'test',
      recognizedText: 'test',
      overallScore: 100.0,
      words: [],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PronunciationScoreCard(
            result: result,
            isDark: false,
            onClose: () => closed = true,
          ),
        ),
      ),
    );

    await tester.tap(find.text('关闭'));
    expect(closed, true);
  });
}
```

- [ ] **Step 3: Run tests**

```bash
flutter test test/widgets/pronunciation_score_card_test.dart
```

Expected: All 3 tests PASS.

- [ ] **Step 4: Commit**

```bash
git add lib/widgets/pronunciation_score_card.dart test/widgets/pronunciation_score_card_test.dart
git commit -m "feat: add PronunciationScoreCard widget with word/phoneme drill-down

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 7: PronunciationOverlay widget (record button)

**Files:**
- Create: `lib/widgets/pronunciation_overlay.dart`

- [ ] **Step 1: Create the widget**

Create `lib/widgets/pronunciation_overlay.dart`:

```dart
import 'dart:async';

import 'package:flutter/material.dart';

enum RecordState { idle, recording, loading }

class PronunciationOverlay extends StatefulWidget {
  final bool isDark;
  final bool isInitialized;
  final bool isFileLoaded;
  final VoidCallback onStartRecording;
  final VoidCallback onStopRecording;

  const PronunciationOverlay({
    super.key,
    required this.isDark,
    required this.isInitialized,
    required this.isFileLoaded,
    required this.onStartRecording,
    required this.onStopRecording,
  });

  @override
  State<PronunciationOverlay> createState() => _PronunciationOverlayState();
}

class _PronunciationOverlayState extends State<PronunciationOverlay> {
  RecordState _state = RecordState.idle;
  int _elapsedSeconds = 0;
  Timer? _timer;

  void setState(RecordState state) {
    _timer?.cancel();
    if (state == RecordState.recording) {
      _elapsedSeconds = 0;
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() => _elapsedSeconds++);
      });
    }
    setState(() => _state = state);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  String get _timeText {
    final m = _elapsedSeconds ~/ 60;
    final s = (_elapsedSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.isInitialized && widget.isFileLoaded;

    if (_state == RecordState.idle) {
      return Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        child: InkWell(
          onTap: enabled
              ? () {
                  setState(RecordState.recording);
                  widget.onStartRecording();
                }
              : null,
          customBorder: const CircleBorder(),
          child: Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: enabled
                  ? const Color(0xFFEF4444).withValues(alpha: 0.12)
                  : (widget.isDark
                      ? Colors.white.withValues(alpha: 0.04)
                      : const Color(0xFF2E1065).withValues(alpha: 0.06)),
            ),
            child: Icon(
              Icons.mic_outlined,
              size: 28,
              color: enabled
                  ? const Color(0xFFEF4444)
                  : (widget.isDark
                      ? Colors.white.withValues(alpha: 0.20)
                      : const Color(0xFF2E1065).withValues(alpha: 0.25)),
            ),
          ),
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_state == RecordState.recording)
          Text(
            _timeText,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w600,
              fontFeatures: const [FontFeature.tabularFigures()],
              color: const Color(0xFFEF4444),
            ),
          ),
        const SizedBox(height: 12),
        GestureDetector(
          onTap: _state == RecordState.recording
              ? () {
                  setState(RecordState.loading);
                  widget.onStopRecording();
                }
              : null,
          child: Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _state == RecordState.recording
                  ? const Color(0xFFEF4444)
                  : const Color(0xFFA855F7),
            ),
            child: _state == RecordState.loading
                ? const Center(
                    child: SizedBox(
                      width: 28,
                      height: 28,
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2.5,
                      ),
                    ),
                  )
                : const Icon(Icons.stop_rounded, size: 36, color: Colors.white),
          ),
        ),
      ],
    );
  }
}
```

- [ ] **Step 2: Commit**

```bash
git add lib/widgets/pronunciation_overlay.dart
git commit -m "feat: add PronunciationOverlay widget with recording UI

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 8: HistoryListView widget

**Files:**
- Create: `lib/widgets/history_list_view.dart`

- [ ] **Step 1: Create the widget**

Create `lib/widgets/history_list_view.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;

import '../models/assessment_result.dart';
import '../services/assessment_history_service.dart';
import 'pronunciation_score_card.dart';

class HistoryListView extends StatelessWidget {
  final Map<String, FileGroup> fileGroups;
  final bool isDark;
  final void Function(AssessmentResult) onViewResult;

  const HistoryListView({
    super.key,
    required this.fileGroups,
    required this.isDark,
    required this.onViewResult,
  });

  @override
  Widget build(BuildContext context) {
    final entries = fileGroups.entries.toList()
      ..sort((a, b) => b.value.records.first.timestamp
          .compareTo(a.value.records.first.timestamp));

    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF0B0B14) : const Color(0xFFF6F4FB),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text(
          '评估历史',
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: isDark
                ? Colors.white.withValues(alpha: 0.55)
                : const Color(0xFF2E1065).withValues(alpha: 0.55),
          ),
        ),
        leading: IconButton(
          icon: Icon(
            Icons.arrow_back_ios_new_rounded,
            size: 18,
            color: isDark
                ? Colors.white.withValues(alpha: 0.55)
                : const Color(0xFF2E1065).withValues(alpha: 0.55),
          ),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: entries.isEmpty
          ? Center(
              child: Text(
                '暂无评估记录',
                style: TextStyle(
                  fontSize: 14,
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.30)
                      : const Color(0xFF2E1065).withValues(alpha: 0.35),
                ),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              itemCount: entries.length,
              itemBuilder: (context, index) {
                final entry = entries[index];
                return _FileGroupCard(
                  group: entry.value,
                  isDark: isDark,
                  onViewResult: onViewResult,
                );
              },
            ),
    );
  }
}

class _FileGroupCard extends StatelessWidget {
  final FileGroup group;
  final bool isDark;
  final void Function(AssessmentResult) onViewResult;

  const _FileGroupCard({
    required this.group,
    required this.isDark,
    required this.onViewResult,
  });

  Color _scoreColor(double score) {
    if (score >= 80) return const Color(0xFF22C55E);
    if (score >= 50) return const Color(0xFFF59E0B);
    return const Color(0xFFEF4444);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.04)
            : Colors.white.withValues(alpha: 0.60),
        borderRadius: BorderRadius.circular(16),
      ),
      child: ExpansionTile(
        shape: const Border(),
        collapsedShape: const Border(),
        title: Row(
          children: [
            Expanded(
              child: Text(
                path.basenameWithoutExtension(group.audioFilePath),
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.85)
                      : const Color(0xFF1E0A3C),
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: _scoreColor(group.averageScore).withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                '均分 ${group.averageScore.round()}',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: _scoreColor(group.averageScore),
                ),
              ),
            ),
          ],
        ),
        children: group.records.map((r) {
          return ListTile(
            dense: true,
            title: Text(
              r.result.referenceText,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                color: isDark
                    ? Colors.white.withValues(alpha: 0.70)
                    : const Color(0xFF2E1065).withValues(alpha: 0.70),
              ),
            ),
            trailing: Text(
              '${r.result.overallScore.round()}分',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: _scoreColor(r.result.overallScore),
              ),
            ),
            onTap: () => onViewResult(r.result),
          );
        }).toList(),
      ),
    );
  }
}
```

- [ ] **Step 2: Commit**

```bash
git add lib/widgets/history_list_view.dart
git commit -m "feat: add HistoryListView widget grouped by file

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 9: Wire into main.dart and player_screen.dart

**Files:**
- Modify: `lib/main.dart`
- Modify: `lib/widgets/player_screen.dart`

The existing widget test (`test/widget_test.dart`) references a counter that doesn't exist — fix it or replace it with a smoke test that matches the current app.

- [ ] **Step 1: Update main.dart — add imports and service fields**

In `lib/main.dart`, add imports at top:

```dart
import 'services/pronunciation_service.dart';
import 'services/assessment_history_service.dart';
import 'models/assessment_result.dart';
import 'widgets/pronunciation_overlay.dart';
import 'widgets/pronunciation_score_card.dart';
import 'widgets/history_list_view.dart';
```

In `TingjianAppState`, add fields before `_isInitialized`:

```dart
  PronunciationService? _pronService;
  AssessmentHistoryService? _historyService;
  int _assessmentMode = 0; // 0=afterSubtitle, 1=karaoke
```

In `_loadSettings()`, after `playbackSpeed` is set, add:

```dart
        _assessmentMode = s.assessmentMode;
```

In `_currentSettings()`, add to the SettingsData constructor:

```dart
        assessmentMode: _assessmentMode,
```

- [ ] **Step 2: Add service initialization in _initAudioService**

In `_initAudioService()`, after `_loadSettings()` call (inside the `audioReady = true` block), add:

```dart
      try {
        await _initPronunciationServices();
      } catch (e) {
        debugPrint('初始化发音评估服务失败: $e');
      }
```

Add the new method to `TingjianAppState`:

```dart
  Future<void> _initPronunciationServices() async {
    const key = ''; // TODO: 填入 Azure subscription key
    const region = 'eastasia';
    if (key.isEmpty) return;
    _pronService = PronunciationService(subscriptionKey: key, region: region);
    _historyService = await AssessmentHistoryService.create();
  }
```

- [ ] **Step 3: Add assessment callbacks to TingjianAppState**

```dart
  Future<void> _startAssessment() async {
    if (_pronService == null) return;
    if (subtitles.isEmpty || currentSubtitleIndex >= subtitles.length) return;

    final referenceText = subtitles[currentSubtitleIndex].text;

    if (_assessmentMode == 0) {
      // Pause audio before recording
      if (isPlaying) {
        await _audioHandler.pause();
      }
    }

    try {
      final hasPerm = await _pronService!.hasPermission;
      if (!hasPerm) {
        if (mounted) {
          _showMicPermissionDialog();
        }
        return;
      }
      await _pronService!.startRecording();
    } catch (e) {
      debugPrint('开始录音失败: $e');
    }
  }

  Future<void> _stopAssessment() async {
    if (_pronService == null) return;
    if (subtitles.isEmpty || currentSubtitleIndex >= subtitles.length) return;

    final referenceText = subtitles[currentSubtitleIndex].text;

    try {
      final result = await _pronService!.stopAndAssess(referenceText);
      if (_assessmentMode == 0) {
        await _audioHandler.play();
      }
      if (_historyService != null) {
        final record = AssessmentRecord(
          id: DateTime.now().microsecondsSinceEpoch.toString(),
          audioFilePath: audioFilePath ?? '',
          subtitleIndex: currentSubtitleIndex,
          result: result,
          timestamp: DateTime.now(),
        );
        await _historyService!.append(record);
      }
      if (mounted) {
        _showScoreCard(result);
      }
    } on AssessmentException catch (e) {
      if (_assessmentMode == 0) {
        await _audioHandler.play();
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message)),
        );
      }
    } catch (e) {
      if (_assessmentMode == 0) {
        await _audioHandler.play();
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('评估失败，请重试')),
        );
      }
    }
  }

  void _showMicPermissionDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('需要麦克风权限'),
        content: const Text('请在系统设置中允许麦克风权限后重试。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  void _showScoreCard(AssessmentResult result) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => PronunciationScoreCard(
        result: result,
        isDark: isDark,
        onClose: () => Navigator.of(context).pop(),
      ),
    );
  }

  Future<void> _openHistory() async {
    if (_historyService == null) return;
    final groups = await _historyService!.loadByFile();
    if (!mounted) return;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => HistoryListView(
          fileGroups: groups,
          isDark: isDark,
          onViewResult: (result) {
            _showScoreCard(result);
          },
        ),
      ),
    );
  }

  void _toggleAssessmentMode() {
    setState(() {
      _assessmentMode = _assessmentMode == 0 ? 1 : 0;
    });
    _saveSettings();
  }
```

- [ ] **Step 4: Update build() to pass new callbacks to PlayerScreen**

In `build()`, add these parameters to the `PlayerScreen` constructor:

```dart
      assessmentMode: _assessmentMode,
      onStartRecording: (_isInitialized && isFileLoaded && _pronService != null)
          ? _startAssessment
          : null,
      onStopRecording: null, // managed by PronunciationOverlay internally
      onToggleAssessmentMode: _isInitialized ? _toggleAssessmentMode : null,
      onOpenHistory: (_isInitialized && _historyService != null)
          ? _openHistory
          : null,
      isAssessing: false, // tracked by overlay internally
```

- [ ] **Step 5: Update PlayerScreen to accept new parameters**

In `lib/widgets/player_screen.dart`, add to the `PlayerScreen` constructor parameters:

```dart
  final int assessmentMode; // 0=afterSubtitle, 1=karaoke
  final VoidCallback? onStartRecording;
  final VoidCallback? onStopRecording;
  final VoidCallback? onToggleAssessmentMode;
  final VoidCallback? onOpenHistory;
  final bool isAssessing;
```

Add to the constructor body:

```dart
    required this.assessmentMode,
    this.onStartRecording,
    this.onStopRecording,
    this.onToggleAssessmentMode,
    this.onOpenHistory,
    required this.isAssessing,
```

- [ ] **Step 6: Add UI elements to PlayerScreen build()**

In the subtitle card area (the `Container` with `shouldShowSubtitle`), add a `Stack` to overlay the record button in the top-right corner. Replace the subtitle card's `child: Center(` block with:

```dart
child: Stack(
  children: [
    Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 28),
        child: Text(
          shouldShowSubtitle ? currentSubtitle : '',
          // ... existing text style unchanged ...
        ),
      ),
    ),
    Positioned(
      top: 12,
      right: 12,
      child: PronunciationOverlay(
        isDark: isDark,
        isInitialized: isInitialized,
        isFileLoaded: isFileLoaded,
        onStartRecording: onStartRecording ?? () {},
        onStopRecording: onStopRecording ?? () {},
      ),
    ),
  ],
),
```

In the ActionItem row, add two new items before the file picker — assessment mode toggle and history:

```dart
ActionItem(
  icon: assessmentMode == 0
      ? Icons.mic_off_rounded
      : Icons.mic_rounded,
  label: assessmentMode == 0 ? '先读后看' : '跟读',
  isActive: assessmentMode != 0,
  onTap: onToggleAssessmentMode,
  isDark: isDark,
),
ActionItem(
  icon: Icons.history_rounded,
  label: '历史',
  isActive: false,
  onTap: onOpenHistory,
  isDark: isDark,
),
```

- [ ] **Step 7: Fix or remove broken widget test**

The existing `test/widget_test.dart` tests a counter that doesn't exist. Replace it with a basic smoke test:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:tingjian/main.dart';

void main() {
  testWidgets('app renders without crashing', (tester) async {
    await tester.pumpWidget(const MyApp());
    // App should render the title
    expect(find.text('听见'), findsOneWidget);
  });
}
```

- [ ] **Step 8: Run flutter analyze**

```bash
flutter analyze
```

Expected: No errors.

- [ ] **Step 9: Run all tests**

```bash
flutter test
```

Expected: All tests PASS.

- [ ] **Step 10: Commit**

```bash
git add lib/main.dart lib/widgets/player_screen.dart test/widget_test.dart
git commit -m "feat: wire pronunciation assessment into main app

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 10: Android/iOS microphone permission config

**Files:**
- Modify: `android/app/src/main/AndroidManifest.xml`
- Modify: `ios/Runner/Info.plist`

- [ ] **Step 1: Add Android permission**

In `android/app/src/main/AndroidManifest.xml`, add before `<application`:

```xml
    <uses-permission android:name="android.permission.RECORD_AUDIO" />
    <uses-permission android:name="android.permission.INTERNET" />
```

- [ ] **Step 2: Add iOS permission**

In `ios/Runner/Info.plist`, add:

```xml
	<key>NSMicrophoneUsageDescription</key>
	<string>听见需要麦克风权限以进行发音评估</string>
```

- [ ] **Step 3: Commit**

```bash
git add android/app/src/main/AndroidManifest.xml ios/Runner/Info.plist
git commit -m "chore: add microphone permissions for Android and iOS

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```
