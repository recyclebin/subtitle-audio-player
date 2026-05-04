import 'package:flutter_test/flutter_test.dart';
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

    group('buildAssessmentConfig', () {
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
    });
  });
}
