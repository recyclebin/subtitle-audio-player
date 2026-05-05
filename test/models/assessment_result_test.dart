import 'package:flutter_test/flutter_test.dart';
import 'package:tingjian/models/assessment_result.dart';

void main() {
  group('AssessmentResult', () {
    final sampleAzureJson = {
      'NBest': [
        {
          'Lexical': 'hello world',
          'Confidence': 0.95,
          'PronScore': 91.0,
          'AccuracyScore': 92.0,
          'FluencyScore': 88.0,
          'CompletenessScore': 95.0,
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
      expect(result.overallScore, 91.0);
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

    test('fromAzureResponse detects insertion words', () {
      final jsonWithInsertion = {
        'NBest': [
          {
            'Lexical': 'hello extra',
            'Words': [
              {
                'Word': 'hello',
                'AccuracyScore': 90.0,
                'ErrorType': null,
                'Phonemes': [],
              },
              {
                'Word': 'extra',
                'AccuracyScore': 0.0,
                'ErrorType': 'Insertion',
                'Phonemes': [],
              },
            ],
          }
        ]
      };

      final result = AssessmentResult.fromAzureResponse(
        jsonWithInsertion,
        'hello',
      );

      expect(result.words[1].isInsertion, true);
    });

    test('fromAzureResponse handles empty NBest gracefully', () {
      final result = AssessmentResult.fromAzureResponse(
        {'NBest': []},
        'hello',
      );

      expect(result.referenceText, 'hello');
      expect(result.recognizedText, '');
      expect(result.overallScore, 0);
      expect(result.words, isEmpty);
    });

    test('fromAzureResponse handles null NBest gracefully', () {
      final result = AssessmentResult.fromAzureResponse(
        {},
        'hello',
      );

      expect(result.referenceText, 'hello');
      expect(result.overallScore, 0);
      expect(result.words, isEmpty);
    });

    test('toJson and fromJson roundtrip preserves data', () {
      final original = const AssessmentResult(
        referenceText: 'test',
        recognizedText: 'test',
        overallScore: 85.0,
        words: [
          WordResult(
            word: 'test',
            accuracyScore: 85.0,
            isOmission: false,
            isInsertion: false,
            phonemes: [
              PhonemeResult(phoneme: 't', score: 90.0),
            ],
          ),
        ],
        language: 'en-US',
      );

      final json = original.toJson();
      final restored = AssessmentResult.fromJson(json);

      expect(restored.referenceText, original.referenceText);
      expect(restored.overallScore, original.overallScore);
      expect(restored.language, original.language);
      expect(restored.words.length, original.words.length);
      expect(restored.words[0].phonemes.length, 1);
    });
  });
}
