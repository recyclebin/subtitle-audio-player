import 'package:flutter/material.dart';

import '../models/assessment_result.dart';

Color scoreColor(double score) {
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
          Text(
            '${result.overallScore.round()}',
            style: TextStyle(
              fontSize: 56,
              fontWeight: FontWeight.w700,
              color: scoreColor(result.overallScore),
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
    final color = scoreColor(word.accuracyScore);
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
                            color: scoreColor(p.score),
                          ),
                        ),
                        Text(
                          '${p.score.round()}%',
                          style: TextStyle(
                            fontSize: 9,
                            color: scoreColor(p.score).withValues(alpha: 0.7),
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
