import 'package:flutter/material.dart';

class MicButton extends StatelessWidget {
  final bool isDark;
  final bool enabled;
  final bool isFollowReadMode;
  final bool isRecording;
  final VoidCallback? onStartRecording;
  final VoidCallback? onStopRecording;
  final VoidCallback? onToggleFollowRead;

  const MicButton({
    super.key,
    required this.isDark,
    required this.enabled,
    required this.isFollowReadMode,
    this.isRecording = false,
    this.onStartRecording,
    this.onStopRecording,
    this.onToggleFollowRead,
  });

  @override
  Widget build(BuildContext context) {
    final followRead = isFollowReadMode;

    if (isRecording) {
      return _buildRecording();
    }

    return _buildIdle(followRead);
  }

  Widget _buildIdle(bool followRead) {
    final iconColor = enabled
        ? (followRead
            ? const Color(0xFFA855F7)
            : (isDark
                ? Colors.white.withValues(alpha: 0.85)
                : const Color(0xFF2E1065).withValues(alpha: 0.85)))
        : (isDark
            ? Colors.white.withValues(alpha: 0.20)
            : const Color(0xFF2E1065).withValues(alpha: 0.25));

    final bgColor = followRead
        ? const Color(0xFFA855F7).withValues(alpha: 0.18)
        : (isDark
            ? Colors.white.withValues(alpha: 0.06)
            : const Color(0xFF2E1065).withValues(alpha: 0.06));

    return Material(
      color: bgColor,
      shape: CircleBorder(
        side: followRead
            ? BorderSide(
                color: const Color(0xFFA855F7).withValues(alpha: 0.5),
                width: 2,
              )
            : BorderSide.none,
      ),
      child: InkWell(
        onTap: enabled ? onStartRecording : null,
        onDoubleTap: onToggleFollowRead,
        customBorder: const CircleBorder(),
        child: SizedBox(
          width: 64,
          height: 64,
          child: Icon(
            followRead ? Icons.mic_rounded : Icons.mic_outlined,
            size: 28,
            color: iconColor,
          ),
        ),
      ),
    );
  }

  Widget _buildRecording() {
    return Material(
      color: const Color(0xFFEF4444),
      shape: const CircleBorder(),
      child: InkWell(
        onTap: onStopRecording,
        customBorder: const CircleBorder(),
        child: const SizedBox(
          width: 64,
          height: 64,
          child: Icon(Icons.stop_rounded, size: 32, color: Colors.white),
        ),
      ),
    );
  }
}
