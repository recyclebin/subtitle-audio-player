import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tingjian/models/assessment_result.dart';
import 'package:tingjian/widgets/pronunciation_score_card.dart';

void main() {
  AssessmentResult makeResult({double score = 85.0, List<WordResult>? words}) {
    return AssessmentResult(
      referenceText: 'hello world',
      recognizedText: 'hello world',
      overallScore: score,
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
}
