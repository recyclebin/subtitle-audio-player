import 'dart:math' show max;

import 'package:flutter/material.dart';

import 'mic_button.dart';

/// 1.0 → "1"；0.75 → "0.75"。
String formatStep(double s) {
  return s == s.roundToDouble() ? '${s.toInt()}' : '$s';
}

/// 底部抽屉外壳
class SheetShell extends StatelessWidget {
  final BuildContext sheetContext;
  final bool isDark;
  final String title;
  final Widget child;

  const SheetShell({
    super.key,
    required this.sheetContext,
    required this.isDark,
    required this.title,
    required this.child,
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
        bottom: MediaQuery.of(sheetContext).padding.bottom + 28,
        left: 24,
        right: 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
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
            title,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color:
                  isDark ? const Color(0xFFD4D4FF) : const Color(0xFF1E0A3C),
            ),
          ),
          const SizedBox(height: 28),
          child,
        ],
      ),
    );
  }
}

/// 抽屉里的 +/- 调节按钮
class DelayBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final bool isDark;

  const DelayBtn({
    super.key,
    required this.icon,
    required this.onTap,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final bgColor = isDark
        ? Colors.white.withValues(alpha: 0.08)
        : const Color(0xFF2E1065).withValues(alpha: 0.06);
    return Material(
      color: bgColor,
      shape: const CircleBorder(),
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: SizedBox(
          width: 44,
          height: 44,
          child: Icon(icon, size: 22, color: const Color(0xFFA855F7)),
        ),
      ),
    );
  }
}

/// 速度调节抽屉
class SpeedSheet extends StatelessWidget {
  final String label;
  final bool isDark;
  final VoidCallback onDecrease;
  final VoidCallback onIncrease;

  const SpeedSheet({
    super.key,
    required this.label,
    required this.isDark,
    required this.onDecrease,
    required this.onIncrease,
  });

  @override
  Widget build(BuildContext context) {
    return SheetShell(
      sheetContext: context,
      isDark: isDark,
      title: '播放速度',
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          DelayBtn(icon: Icons.remove, onTap: onDecrease, isDark: isDark),
          SizedBox(
            width: 100,
            child: Text(
              '${label}x',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 32,
                fontWeight: FontWeight.w600,
                color: Color(0xFFA855F7),
              ),
            ),
          ),
          DelayBtn(icon: Icons.add, onTap: onIncrease, isDark: isDark),
        ],
      ),
    );
  }
}

/// 播放间隔 + 字幕延迟开关抽屉
class DelaySheet extends StatelessWidget {
  final String label;
  final bool isDark;
  final bool isDelayEnabled;
  final VoidCallback onDecrease;
  final VoidCallback onIncrease;
  final ValueChanged<bool> onDelayToggle;

  const DelaySheet({
    super.key,
    required this.label,
    required this.isDark,
    required this.isDelayEnabled,
    required this.onDecrease,
    required this.onIncrease,
    required this.onDelayToggle,
  });

  @override
  Widget build(BuildContext context) {
    return SheetShell(
      sheetContext: context,
      isDark: isDark,
      title: '播放间隔',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              DelayBtn(icon: Icons.remove, onTap: onDecrease, isDark: isDark),
              SizedBox(
                width: 100,
                child: Text(
                  '${label}s',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFFA855F7),
                  ),
                ),
              ),
              DelayBtn(icon: Icons.add, onTap: onIncrease, isDark: isDark),
            ],
          ),
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Switch(
                value: isDelayEnabled,
                activeThumbColor: const Color(0xFFA855F7),
                onChanged: onDelayToggle,
              ),
              const SizedBox(width: 12),
              Text(
                '播放间隔显示字幕',
                style: TextStyle(
                  fontSize: 16,
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.70)
                      : const Color(0xFF2E1065).withValues(alpha: 0.75),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 底部图标行条目
class ActionItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isActive;
  final VoidCallback? onTap;
  final bool isDark;

  const ActionItem({
    super.key,
    required this.icon,
    required this.label,
    required this.isActive,
    required this.onTap,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    const activeColor = Color(0xFFA855F7);
    final inactiveColor = isDark
        ? Colors.white.withValues(alpha: 0.62)
        : const Color(0xFF1E0A3C).withValues(alpha: 0.62);
    final disabledColor = isDark
        ? Colors.white.withValues(alpha: 0.20)
        : const Color(0xFF1E0A3C).withValues(alpha: 0.22);
    final color =
        onTap == null ? disabledColor : (isActive ? activeColor : inactiveColor);
    return Expanded(
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(18),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 22, color: color),
                const SizedBox(height: 4),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 0.2,
                    color: color,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 播放控制按钮（主按钮 80px 实心紫色圆，副按钮纯图标）
class PlayBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final bool isDark;
  final bool isPrimary;

  const PlayBtn({
    super.key,
    required this.icon,
    required this.onTap,
    required this.isDark,
    this.isPrimary = false,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    if (isPrimary) {
      const activeColor = Color(0xFFA855F7);
      final disabledBg = isDark
          ? Colors.white.withValues(alpha: 0.08)
          : const Color(0xFF2E1065).withValues(alpha: 0.10);
      return Material(
        color: enabled ? activeColor : disabledBg,
        shape: const CircleBorder(),
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: SizedBox(
            width: 80,
            height: 80,
            child: Icon(
              icon,
              size: 40,
              color: enabled
                  ? Colors.white
                  : (isDark
                      ? Colors.white.withValues(alpha: 0.30)
                      : const Color(0xFF2E1065).withValues(alpha: 0.30)),
            ),
          ),
        ),
      );
    }
    final iconColor = enabled
        ? (isDark
            ? Colors.white.withValues(alpha: 0.85)
            : const Color(0xFF2E1065).withValues(alpha: 0.85))
        : (isDark
            ? Colors.white.withValues(alpha: 0.20)
            : const Color(0xFF2E1065).withValues(alpha: 0.25));
    return Material(
      color: Colors.transparent,
      shape: const CircleBorder(),
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: SizedBox(
          width: 64,
          height: 64,
          child: Icon(icon, size: 36, color: iconColor),
        ),
      ),
    );
  }
}

/// 主播放界面：字幕卡片 + 播放控制 + 设置图标行
class PlayerScreen extends StatelessWidget {
  final bool isDark;
  final String? fileName;
  final String currentSubtitle;
  final bool shouldShowSubtitle;
  final bool hasSubtitles;
  final int subtitleIndex;
  final int subtitleCount;
  final bool isPlaying;
  final bool isFileLoaded;
  final bool isInitialized;

  final VoidCallback? onPlayPause;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  final String speedLabel;
  final bool isSpeedActive;
  final VoidCallback? onSpeedTap;

  final String intervalLabel;
  final bool isIntervalActive;
  final VoidCallback? onIntervalTap;

  final bool isRandomActive;
  final VoidCallback? onRandomTap;

  final bool isLoopActive;
  final VoidCallback? onLoopTap;

  final VoidCallback? onMoreTap;

  final bool isFollowReadMode;
  final bool isRecording;
  /// 录音结束到评估结果展示期间锁定播放按钮，防止状态错乱。
  final bool isAssessing;
  final VoidCallback? onToggleFollowRead;
  final VoidCallback? onStartRecording;
  final VoidCallback? onStopRecording;

  const PlayerScreen({
    super.key,
    required this.isDark,
    this.fileName,
    required this.currentSubtitle,
    required this.shouldShowSubtitle,
    required this.hasSubtitles,
    required this.subtitleIndex,
    required this.subtitleCount,
    required this.isPlaying,
    required this.isFileLoaded,
    required this.isInitialized,
    this.onPlayPause,
    this.onPrevious,
    this.onNext,
    required this.speedLabel,
    required this.isSpeedActive,
    this.onSpeedTap,
    required this.intervalLabel,
    required this.isIntervalActive,
    this.onIntervalTap,
    required this.isRandomActive,
    this.onRandomTap,
    required this.isLoopActive,
    this.onLoopTap,
    this.onMoreTap,
    this.isFollowReadMode = false,
    this.isRecording = false,
    this.isAssessing = false,
    this.onToggleFollowRead,
    this.onStartRecording,
    this.onStopRecording,
  });

  @override
  Widget build(BuildContext context) {
    final bgBase = isDark ? const Color(0xFF0B0B14) : const Color(0xFFF6F4FB);
    final bgGlow = isDark
        ? const Color(0xFFA855F7).withValues(alpha: 0.22)
        : const Color(0xFFA855F7).withValues(alpha: 0.10);
    return Container(
      decoration: BoxDecoration(
        gradient: RadialGradient(
          center: const Alignment(0, -1.1),
          radius: 1.3,
          colors: [bgGlow, bgBase],
          stops: const [0.0, 0.55],
        ),
      ),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          surfaceTintColor: Colors.transparent,
          centerTitle: true,
          title: Text(
            '听见',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              letterSpacing: 2.0,
              color: isDark
                  ? Colors.white.withValues(alpha: 0.55)
                  : const Color(0xFF2E1065).withValues(alpha: 0.55),
            ),
          ),
        ),
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final subtitleHeight = constraints.maxHeight * 0.7;
              final controlsHeight = constraints.maxHeight * 0.3;

              return Column(
                children: [
                  if (fileName != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                      child: Text(
                        fileName!,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          letterSpacing: 0.2,
                          color: isDark
                              ? Colors.white.withValues(alpha: 0.40)
                              : const Color(0xFF2E1065)
                                  .withValues(alpha: 0.50),
                        ),
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  // 字幕展示区
                  Container(
                    width: double.infinity,
                    height:
                        max(0, subtitleHeight - (fileName != null ? 36 : 0)),
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Container(
                      decoration: BoxDecoration(
                        color: isDark
                            ? Colors.white.withValues(alpha: 0.035)
                            : Colors.white.withValues(alpha: 0.55),
                        borderRadius: BorderRadius.circular(28),
                      ),
                      child: Center(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 28, vertical: 28),
                          child: Text(
                            shouldShowSubtitle ? currentSubtitle : '',
                            style: TextStyle(
                              fontSize: 30,
                              height: 1.85,
                              fontWeight: FontWeight.w300,
                              letterSpacing: 0.3,
                              color: shouldShowSubtitle
                                  ? (isDark
                                      ? Colors.white.withValues(alpha: 0.92)
                                      : const Color(0xFF1E0A3C))
                                  : (isDark
                                      ? Colors.white.withValues(alpha: 0.08)
                                      : const Color(0xFF1E0A3C)
                                          .withValues(alpha: 0.10)),
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                    ),
                  ),
                  // 字幕进度
                  if (hasSubtitles)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Text(
                        '${subtitleIndex + 1} / $subtitleCount',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                          letterSpacing: 0.5,
                          color: isDark
                              ? Colors.white.withValues(alpha: 0.30)
                              : const Color(0xFF2E1065)
                                  .withValues(alpha: 0.40),
                        ),
                      ),
                    ),
                  // 控制区
                  SizedBox(
                    height: controlsHeight - (hasSubtitles ? 24 : 0),
                    child: Column(
                      children: [
                        Expanded(
                          child: Padding(
                            padding:
                                const EdgeInsets.symmetric(horizontal: 40),
                            child: Row(
                              mainAxisAlignment:
                                  MainAxisAlignment.spaceEvenly,
                              children: [
                                Padding(
                                  padding: const EdgeInsets.only(right: 14),
                                  child: MicButton(
                                    isDark: isDark,
                                    enabled: isInitialized &&
                                        isFileLoaded &&
                                        onStartRecording != null,
                                    isFollowReadMode: isFollowReadMode,
                                    isRecording: isRecording,
                                    onStartRecording: onStartRecording,
                                    onStopRecording: onStopRecording,
                                    onToggleFollowRead: onToggleFollowRead,
                                  ),
                                ),
                                PlayBtn(
                                  icon: isPlaying
                                      ? Icons.pause_rounded
                                      : Icons.play_arrow_rounded,
                                  onTap: (isRecording || isAssessing) ? null : onPlayPause,
                                  isDark: isDark,
                                  isPrimary: true,
                                ),
                                PlayBtn(
                                  icon: Icons.skip_previous_rounded,
                                  onTap: (isRecording || isAssessing) ? null : onPrevious,
                                  isDark: isDark,
                                ),
                                PlayBtn(
                                  icon: Icons.skip_next_rounded,
                                  onTap: (isRecording || isAssessing) ? null : onNext,
                                  isDark: isDark,
                                ),
                              ],
                            ),
                          ),
                        ),
                        // 图标行
                        Padding(
                          padding:
                              const EdgeInsets.fromLTRB(16, 0, 16, 8),
                          child: Container(
                            decoration: BoxDecoration(
                              color: isDark
                                  ? Colors.white.withValues(alpha: 0.04)
                                  : Colors.white.withValues(alpha: 0.50),
                              borderRadius: BorderRadius.circular(22),
                            ),
                            child: Row(
                              children: [
                                ActionItem(
                                  icon: Icons.speed_rounded,
                                  label: '${speedLabel}x',
                                  isActive: isSpeedActive,
                                  onTap: onSpeedTap,
                                  isDark: isDark,
                                ),
                                ActionItem(
                                  icon: Icons.timer_outlined,
                                  label: '${intervalLabel}s',
                                  isActive: isIntervalActive,
                                  onTap: onIntervalTap,
                                  isDark: isDark,
                                ),
                                ActionItem(
                                  icon: Icons.shuffle_rounded,
                                  label: '随机',
                                  isActive: isRandomActive,
                                  onTap: onRandomTap,
                                  isDark: isDark,
                                ),
                                ActionItem(
                                  icon: Icons.repeat_one_rounded,
                                  label: '循环',
                                  isActive: isLoopActive,
                                  onTap: onLoopTap,
                                  isDark: isDark,
                                ),
                                ActionItem(
                                  icon: Icons.more_horiz_rounded,
                                  label: '更多',
                                  isActive: false,
                                  onTap: onMoreTap,
                                  isDark: isDark,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
