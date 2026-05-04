import 'dart:async';

import 'package:flutter/material.dart';

class PronunciationOverlay extends StatefulWidget {
  final bool isDark;
  final bool isInitialized;
  final bool isFileLoaded;
  final VoidCallback onStartRecording;
  final Future<void> Function() onStopRecording;

  const PronunciationOverlay({
    super.key,
    required this.isDark,
    required this.isInitialized,
    required this.isFileLoaded,
    required this.onStartRecording,
    required this.onStopRecording,
  });

  @override
  State<PronunciationOverlay> createState() => _PronunciationOverlayState();
}

class _PronunciationOverlayState extends State<PronunciationOverlay> {
  bool _recording = false;
  bool _loading = false;
  int _elapsedSeconds = 0;
  Timer? _timer;

  void _startTimer() {
    _elapsedSeconds = 0;
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _elapsedSeconds++);
    });
  }

  String get _timeText {
    final m = _elapsedSeconds ~/ 60;
    final s = (_elapsedSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _handleStart() {
    setState(() {
      _recording = true;
      _loading = false;
    });
    _startTimer();
    widget.onStartRecording();
  }

  Future<void> _handleStop() async {
    setState(() {
      _recording = false;
      _loading = true;
    });
    _timer?.cancel();
    try {
      await widget.onStopRecording();
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.isInitialized && widget.isFileLoaded;

    if (!_recording && !_loading) {
      // IDLE state
      return Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        child: InkWell(
          onTap: enabled ? _handleStart : null,
          customBorder: const CircleBorder(),
          child: Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: enabled
                  ? const Color(0xFFEF4444).withValues(alpha: 0.12)
                  : (widget.isDark
                      ? Colors.white.withValues(alpha: 0.04)
                      : const Color(0xFF2E1065).withValues(alpha: 0.06)),
            ),
            child: Icon(
              Icons.mic_outlined,
              size: 28,
              color: enabled
                  ? const Color(0xFFEF4444)
                  : (widget.isDark
                      ? Colors.white.withValues(alpha: 0.20)
                      : const Color(0xFF2E1065).withValues(alpha: 0.25)),
            ),
          ),
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          _timeText,
          style: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w600,
            fontFeatures: [FontFeature.tabularFigures()],
            color: Color(0xFFEF4444),
          ),
        ),
        const SizedBox(height: 12),
        GestureDetector(
          onTap: _recording ? _handleStop : null,
          child: Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _recording
                  ? const Color(0xFFEF4444)
                  : const Color(0xFFA855F7),
            ),
            child: _loading
                ? const Center(
                    child: SizedBox(
                      width: 28,
                      height: 28,
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2.5,
                      ),
                    ),
                  )
                : const Icon(Icons.stop_rounded, size: 36, color: Colors.white),
          ),
        ),
      ],
    );
  }
}
