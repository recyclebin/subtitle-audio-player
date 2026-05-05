import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tingjian/services/pronunciation_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('PronunciationService', () {
    late PronunciationService service;

    setUp(() {
      service = PronunciationService(
        subscriptionKey: 'test-key',
        region: 'eastasia',
      );
    });

    group('buildAssessmentConfig', () {
      test('returns Base64-encoded JSON config', () {
        final config = service.buildAssessmentConfig(
          referenceText: 'hello world',
          language: 'en-US',
        );

        final json = utf8.decode(base64Decode(config));
        expect(json, contains('"ReferenceText":"hello world"'));
        expect(json, contains('"GradingSystem":"HundredMark"'));
        expect(json, contains('"Granularity":"Phoneme"'));
        expect(json, contains('"PhonemeAlphabet":"IPA"'));
      });

      test('Base64 decodes to valid JSON with escaped quotes', () {
        final config = service.buildAssessmentConfig(
          referenceText: 'he said "hello"',
          language: 'en-US',
        );

        final json = utf8.decode(base64Decode(config));
        final parsed = jsonDecode(json) as Map<String, dynamic>;
        expect(parsed['ReferenceText'], 'he said "hello"');
      });
    });

    group('detectLanguage', () {
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

      test('returns en-US for empty string', () {
        expect(service.detectLanguage(''), 'en-US');
      });

      test('returns en-US for digits', () {
        expect(service.detectLanguage('123'), 'en-US');
      });

      test('returns es-ES for Spanish text', () {
        expect(service.detectLanguage('¿Cómo estás?'), 'es-ES');
        expect(service.detectLanguage('mañana'), 'es-ES');
      });

      test('returns pt-PT for Portuguese text', () {
        expect(service.detectLanguage('não'), 'pt-PT');
        expect(service.detectLanguage('informações'), 'pt-PT');
      });

      test('returns fr-FR for French text', () {
        expect(service.detectLanguage('très bien'), 'fr-FR');
        expect(service.detectLanguage('naïf'), 'fr-FR');
      });

      test('returns en-US for plain Latin text without markers', () {
        expect(service.detectLanguage('hello world'), 'en-US');
        expect(service.detectLanguage('cafe'), 'en-US');
      });
    });
  });
}
