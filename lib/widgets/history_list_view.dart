import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;

import '../models/assessment_result.dart';
import '../services/assessment_history_service.dart';
import 'pronunciation_score_card.dart' show scoreColor, languageName;

class HistoryListView extends StatelessWidget {
  final Map<String, FileGroup> fileGroups;
  final bool isDark;
  final void Function(AssessmentResult) onViewResult;
  final VoidCallback? onClear;

  const HistoryListView({
    super.key,
    required this.fileGroups,
    required this.isDark,
    required this.onViewResult,
    this.onClear,
  });

  Future<void> _confirmClear(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空历史'),
        content: const Text('确认删除所有评估历史记录？此操作不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除全部',
                style: TextStyle(color: Color(0xFFEF4444))),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      onClear?.call();
      if (context.mounted) Navigator.of(context).pop();
    }
  }

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
        actions: [
          if (entries.isNotEmpty && onClear != null)
            IconButton(
              icon: Icon(
                Icons.delete_outline_rounded,
                size: 20,
                color: isDark
                    ? Colors.white.withValues(alpha: 0.55)
                    : const Color(0xFF2E1065).withValues(alpha: 0.55),
              ),
              onPressed: () => _confirmClear(context),
            ),
        ],
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
                color: scoreColor(group.averageScore).withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                '均分 ${group.averageScore.round()}',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: scoreColor(group.averageScore),
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
            subtitle: Text(
              languageName(r.result.language),
              style: TextStyle(
                fontSize: 11,
                color: isDark
                    ? Colors.white.withValues(alpha: 0.35)
                    : const Color(0xFF2E1065).withValues(alpha: 0.35),
              ),
            ),
            trailing: Text(
              '${r.result.overallScore.round()}分',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: scoreColor(r.result.overallScore),
              ),
            ),
            onTap: () => onViewResult(r.result),
          );
        }).toList(),
      ),
    );
  }
}
