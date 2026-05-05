import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tingjian/models/assessment_result.dart';
import 'package:tingjian/widgets/pronunciation_score_card.dart';

void main() {
  AssessmentResult makeResult({
    double score = 85.0,
    List<WordResult>? words,
    double? accuracyScore,
    double? fluencyScore,
    double? completenessScore,
  }) {
    return AssessmentResult(
      referenceText: 'hello world',
      recognizedText: 'hello world',
      overallScore: score,
      accuracyScore: accuracyScore,
      fluencyScore: fluencyScore,
      completenessScore: completenessScore,
      words: words ??
          [
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
  }

  testWidgets('shows overall score', (tester) async {
    final result = makeResult(score: 85.0);

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
    final result = makeResult();

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
    expect(find.text('w'), findsNothing);

    // Tap word chip to expand
    await tester.tap(find.text('world'));
    await tester.pump();

    // Now phoneme should be visible
    expect(find.text('w'), findsOneWidget);
  });

  testWidgets('close button calls onClose', (tester) async {
    var closed = false;
    final result = makeResult();

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

  testWidgets('renders sub-score chips when values are provided', (tester) async {
    final result = makeResult(
      accuracyScore: 86.0,
      fluencyScore: 78.0,
      completenessScore: 90.0,
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

    expect(find.text('准确'), findsOneWidget);
    expect(find.text('86'), findsOneWidget);
    expect(find.text('流利'), findsOneWidget);
    expect(find.text('78'), findsOneWidget);
    expect(find.text('完整'), findsOneWidget);
    expect(find.text('90'), findsOneWidget);
  });

  testWidgets('hides sub-score chips when values are null', (tester) async {
    final result = makeResult();

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

    expect(find.text('准确'), findsNothing);
    expect(find.text('流利'), findsNothing);
    expect(find.text('完整'), findsNothing);
  });

  testWidgets('renders only the non-null sub-score chips', (tester) async {
    final result = makeResult(
      accuracyScore: 86.0,
      completenessScore: 90.0,
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

    expect(find.text('准确'), findsOneWidget);
    expect(find.text('86'), findsOneWidget);
    expect(find.text('完整'), findsOneWidget);
    expect(find.text('90'), findsOneWidget);
    expect(find.text('流利'), findsNothing);
  });

  testWidgets('exposes merged a11y label for sub-score chip', (tester) async {
    final result = makeResult(accuracyScore: 86.0);

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

    expect(find.bySemanticsLabel('准确 86'), findsOneWidget);
  });
}
