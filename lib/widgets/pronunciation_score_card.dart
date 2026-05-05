import 'dart:async';

import 'package:flutter/material.dart';

import '../models/assessment_result.dart';

Color scoreColor(double score) {
  if (score >= 80) return const Color(0xFF22C55E);
  if (score >= 50) return const Color(0xFFF59E0B);
  return const Color(0xFFEF4444);
}

String languageName(String? code) => switch (code) {
      'zh-CN' => '中文（普通话）',
      'ja-JP' => '日本語',
      'ko-KR' => '한국어',
      'th-TH' => 'ไทย',
      'en-US' => 'English',
      'fr-FR' => 'Français',
      'es-ES' => 'Español',
      'pt-PT' => 'Português',
      _ => '自动检测',
    };

class PronunciationScoreCard extends StatefulWidget {
  final AssessmentResult result;
  final bool isDark;
  final int autoDismissSeconds;
  final VoidCallback onClose;

  const PronunciationScoreCard({
    super.key,
    required this.result,
    required this.isDark,
    this.autoDismissSeconds = 0,
    required this.onClose,
  });

  @override
  State<PronunciationScoreCard> createState() => _PronunciationScoreCardState();
}

class _PronunciationScoreCardState extends State<PronunciationScoreCard> {
  int _countdown = 0;
  Timer? _timer;
  /// 三态：null=未控制, true=全部展开, false=全部收起。
  /// 用户单独点击单词后变为 null，避免切换时覆盖用户操作。
  bool? _expandAll;

  @override
  void initState() {
    super.initState();
    _resetTimer();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _resetTimer() {
    _timer?.cancel();
    if (widget.autoDismissSeconds > 0) {
      setState(() => _countdown = widget.autoDismissSeconds);
      _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (!mounted) return;
        if (_countdown <= 1) {
          timer.cancel();
          widget.onClose();
        } else {
          setState(() => _countdown--);
        }
      });
    }
  }

  void _onUserInteraction() {
    if (widget.autoDismissSeconds > 0) {
      _resetTimer();
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomPadding = MediaQuery.of(context).padding.bottom + 28;
    return GestureDetector(
      onTap: _onUserInteraction,
      behavior: HitTestBehavior.translucent,
      child: Container(
        decoration: BoxDecoration(
          color: widget.isDark ? const Color(0xFF1A0A2E) : Colors.white,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: EdgeInsets.only(
          top: 12,
          bottom: bottomPadding,
          left: 24,
          right: 24,
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: widget.isDark
                        ? Colors.white.withValues(alpha: 0.20)
                        : const Color(0xFF6D28D9).withValues(alpha: 0.25),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 10),
                // 分数与标签水平排列，节省纵向空间
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '${widget.result.overallScore.round()}',
                      style: TextStyle(
                        fontSize: 48,
                        fontWeight: FontWeight.w700,
                        color: scoreColor(widget.result.overallScore),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '发音得分',
                          style: TextStyle(
                            fontSize: 13,
                            color: widget.isDark
                                ? Colors.white.withValues(alpha: 0.45)
                                : const Color(0xFF2E1065).withValues(alpha: 0.45),
                          ),
                        ),
                        const SizedBox(height: 2),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: widget.isDark
                                ? Colors.white.withValues(alpha: 0.06)
                                : const Color(0xFF2E1065).withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            languageName(widget.result.language),
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                              color: widget.isDark
                                  ? Colors.white.withValues(alpha: 0.45)
                                  : const Color(0xFF2E1065).withValues(alpha: 0.45),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                // 细项评分：准确度、流利度、完整度、韵律（如有）
                _SubScores(result: widget.result, isDark: widget.isDark),
                const SizedBox(height: 12),
                Expanded(
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: widget.isDark
                          ? Colors.white.withValues(alpha: 0.04)
                          : const Color(0xFFF6F4FB),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: ScrollbarTheme(
                        data: ScrollbarThemeData(
                          thumbVisibility: WidgetStateProperty.all(true),
                        ),
                        child: Scrollbar(
                        child: SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Row(
                              children: [
                                Text(
                                  '逐词评估',
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: widget.isDark
                                        ? Colors.white.withValues(alpha: 0.60)
                                        : const Color(0xFF2E1065).withValues(alpha: 0.60),
                                  ),
                                ),
                                const Spacer(),
                                Padding(
                                  padding: const EdgeInsets.only(right: 6),
                                  child: GestureDetector(
                                    onTap: () => setState(() {
                                      _expandAll = _expandAll == true ? false : true;
                                    }),
                                    child: Text(
                                      _expandAll == true ? '全部收起' : '全部展开',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: widget.isDark
                                            ? Colors.white.withValues(alpha: 0.40)
                                            : const Color(0xFF2E1065).withValues(alpha: 0.40),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: widget.result.words.map((w) {
                                return _WordChip(word: w, expandAll: _expandAll);
                              }).toList(),
                            ),
                        ],
                      ),
                    ),
                    ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                _countdown > 0
                    ? Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          TextButton.icon(
                            onPressed: widget.onClose,
                            icon: const Icon(Icons.close, size: 18),
                            label: Text('关闭 ($_countdown)'),
                            style: TextButton.styleFrom(
                              foregroundColor: const Color(0xFFA855F7),
                            ),
                          ),
                        ],
                      )
                    : TextButton.icon(
                        onPressed: widget.onClose,
                        icon: const Icon(Icons.close, size: 18),
                        label: const Text('关闭'),
                        style: TextButton.styleFrom(
                          foregroundColor: const Color(0xFFA855F7),
                        ),
                      ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _WordChip extends StatefulWidget {
  final WordResult word;
  final bool? expandAll;
  const _WordChip({required this.word, this.expandAll});

  @override
  State<_WordChip> createState() => _WordChipState();
}

class _WordChipState extends State<_WordChip> {
  bool _expanded = false;

  /// 父级「全部展开/收起」变化时，同步每个词的展开状态。
  @override
  void didUpdateWidget(covariant _WordChip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.expandAll != oldWidget.expandAll && widget.expandAll != null) {
      _expanded = widget.expandAll!;
    }
  }

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
              child: Wrap(
                spacing: 4,
                runSpacing: 2,
                children: word.phonemes.map((p) {
                  final hasName = p.phoneme.isNotEmpty;
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: hasName
                        ? Column(
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
                                  color: scoreColor(p.score)
                                      .withValues(alpha: 0.7),
                                ),
                              ),
                            ],
                          )
                        : Container(
                            width: 28,
                            height: 28,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: scoreColor(p.score).withValues(alpha: 0.15),
                              border: Border.all(
                                  color: scoreColor(p.score)
                                      .withValues(alpha: 0.3)),
                            ),
                            child: Text(
                              '${p.score.round()}',
                              style: TextStyle(
                                fontSize: 9,
                                fontWeight: FontWeight.w600,
                                color: scoreColor(p.score),
                              ),
                            ),
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

// 细项评分横排展示，节省纵向空间。
class _SubScores extends StatelessWidget {
  final AssessmentResult result;
  final bool isDark;

  const _SubScores({required this.result, required this.isDark});

  @override
  Widget build(BuildContext context) {
    final items = <_ScoreItem>[
      _ScoreItem('准确', result.accuracyScore),
      _ScoreItem('流利', result.fluencyScore),
      _ScoreItem('完整', result.completenessScore),
    ];

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 0; i < items.length; i++) ...[
          if (i > 0) const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.05)
                  : const Color(0xFF2E1065).withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  items[i].label,
                  style: TextStyle(
                    fontSize: 11,
                    color: isDark
                        ? Colors.white.withValues(alpha: 0.45)
                        : const Color(0xFF2E1065).withValues(alpha: 0.45),
                  ),
                ),
                const SizedBox(width: 4),
                Text(
                  '${items[i].score.round()}',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: scoreColor(items[i].score),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _ScoreItem {
  final String label;
  final double score;
  const _ScoreItem(this.label, this.score);
}
