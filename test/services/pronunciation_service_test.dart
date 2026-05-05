import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tingjian/services/pronunciation_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('PronunciationService', () {
    late PronunciationService service;

    setUpAll(() async {
      await PronunciationService.initLanguageDetector();
    });

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
        expect(PronunciationService.detectLanguage('the weather is beautiful today and I would like to go for a walk'), 'en-US');
      });

      test('returns zh-CN for Chinese text', () {
        expect(PronunciationService.detectLanguage('你好世界'), 'zh-CN');
      });

      test('returns ja-JP for Japanese text', () {
        expect(PronunciationService.detectLanguage('こんにちは'), 'ja-JP');
      });

      test('returns ko-KR for Korean text', () {
        expect(PronunciationService.detectLanguage('안녕하세요'), 'ko-KR');
      });

      test('returns en-US for empty string', () {
        expect(PronunciationService.detectLanguage(''), 'en-US');
      });

      test('returns en-US for digits', () {
        expect(PronunciationService.detectLanguage('123'), 'en-US');
      });

      test('returns es-ES for Spanish text', () {
        expect(PronunciationService.detectLanguage('Buenos días, cómo estás hoy hace muy buen tiempo para pasear'), 'es-ES');
      });

      test('returns pt-PT for Portuguese text', () {
        expect(PronunciationService.detectLanguage('Bom dia, como você está hoje o tempo está muito bom para passear'), 'pt-PT');
      });

      test('returns fr-FR for French text', () {
        expect(PronunciationService.detectLanguage('Bonjour, comment allez-vous aujourd\'hui il fait très beau pour se promener'), 'fr-FR');
      });

      test('returns en-US for plain English text', () {
        expect(PronunciationService.detectLanguage('hello world how are you doing today'), 'en-US');
      });
    });
  });
}
