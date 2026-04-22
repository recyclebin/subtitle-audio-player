import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';
import 'package:rxdart/rxdart.dart';

class MyAudioHandler extends BaseAudioHandler {
  final _audioPlayer = AudioPlayer();
  // BehaviorSubject：新订阅者立即收到最后一个值（初始为 Duration.zero），
  // 避免 _setupPositionListener 注册前的启动事件丢失。
  final BehaviorSubject<Duration> _positionSubject =
      BehaviorSubject<Duration>.seeded(Duration.zero);
  void Function(bool)? updatePlayingStateCallback;
  Future<void> Function()? onSkipToNext;
  Future<void> Function()? onSkipToPrevious;
  void Function()? cancelTimer;
  bool isPlaying = false;
  bool _isDelayPaused = false;

  bool get isAudioSourceSet => _audioPlayer.audioSource != null;
  bool get isDelayPaused => _isDelayPaused;
  Duration? get audioDuration => _audioPlayer.duration;

  void updateIsPlaying(bool playing) {
    isPlaying = playing;
    updatePlayingStateCallback?.call(playing);
    _updateMediaControls();
  }

  void _updateMediaControls() {
    final effectivelyPlaying = isPlaying && !_isDelayPaused;
    playbackState.add(playbackState.value.copyWith(
      controls: [
        // 按钮基于 isPlaying（用户可见播放意图），与主界面保持一致。
        // effectivelyPlaying 仅用于 playing 字段，告知 OS 当前实际音频状态。
        isPlaying ? MediaControl.pause : MediaControl.play,
        MediaControl.skipToPrevious,
        MediaControl.skipToNext,
      ],
      systemActions: const {},
      androidCompactActionIndices: const [0],
      playing: effectivelyPlaying,
      processingState: {
        ProcessingState.idle: AudioProcessingState.idle,
        ProcessingState.loading: AudioProcessingState.loading,
        ProcessingState.buffering: AudioProcessingState.buffering,
        ProcessingState.ready: AudioProcessingState.ready,
        ProcessingState.completed: AudioProcessingState.completed,
      }[_audioPlayer.processingState] ?? AudioProcessingState.idle,
      updatePosition: _audioPlayer.position,
      bufferedPosition: _audioPlayer.bufferedPosition,
      speed: _audioPlayer.speed,
    ));
  }

  MyAudioHandler() {
    _audioPlayer.positionStream.listen((position) {
      _positionSubject.add(position);
    });
    // 将 just_audio 的状态变化（buffering/completed 等）同步到 playbackState，
    // 使通知栏保持可见且 processingState 准确。
    // 不在此处调 updateIsPlaying——isPlaying 只由 play()/pause()/stop() 管理。
    _audioPlayer.playerStateStream.listen((_) {
      _updateMediaControls();
    });
  }

  void updateDisplaySubtitle(String text) {
    final item = mediaItem.value;
    if (item == null) return;
    mediaItem.add(item.copyWith(
      displayTitle: text.isNotEmpty ? text : null,
      // Show filename as secondary line in the expanded notification.
      displaySubtitle: text.isNotEmpty ? item.title : null,
    ));
  }

  Future<void> setAudioSource(AudioSource source, [MediaItem? item]) async {
    if (item != null) mediaItem.add(item);
    await _audioPlayer.setAudioSource(source);
    // Briefly emit playing:true to kick Android's foreground service into life so
    // the notification appears in paused state without the user pressing play.
    // _updateMediaControls() immediately resets to the real state; with
    // androidStopForegroundOnPause:false the notification stays visible after that.
    playbackState.add(playbackState.value.copyWith(
      controls: [
        MediaControl.pause,
        MediaControl.skipToPrevious,
        MediaControl.skipToNext,
      ],
      systemActions: const {},
      androidCompactActionIndices: const [0],
      playing: true,
      processingState: AudioProcessingState.ready,
      updatePosition: Duration.zero,
    ));
    _updateMediaControls();
  }

  Stream<Duration> get positionStream => _positionSubject.stream;
  Duration get position => _audioPlayer.position;

  @override
  Future<void> play() async {
    if (_audioPlayer.audioSource == null) return;
    cancelTimer?.call();
    _isDelayPaused = false;
    updateIsPlaying(true);
    try {
      await _audioPlayer.play();
    } catch (_) {
      updateIsPlaying(false);
    }
  }

  @override
  Future<void> pause() async {
    cancelTimer?.call();
    _isDelayPaused = false;
    await _audioPlayer.pause();
    updateIsPlaying(false);
  }

  /// Pauses audio mid-segment for subtitle reveal without changing user-visible
  /// play state. `isPlaying` stays true so the delay timer can auto-advance.
  /// Relies on just_audio's guarantee that calling pause() causes any pending
  /// play() future to resolve, which unblocks the await in MyAudioHandler.play().
  Future<void> realPause() async {
    _isDelayPaused = true;
    await _audioPlayer.pause();
    _updateMediaControls();
  }

  @override
  Future<void> stop() async {
    cancelTimer?.call();
    _isDelayPaused = false;
    await _audioPlayer.stop();
    updateIsPlaying(false);
  }

  @override
  Future<void> seek(Duration position) async =>
      await _audioPlayer.seek(position);

  @override
  Future<void> skipToNext() async {
    await onSkipToNext?.call();
  }

  @override
  Future<void> skipToPrevious() async {
    await onSkipToPrevious?.call();
  }

  // Not @override — BaseAudioHandler has no dispose(). If a future version of
  // audio_service adds one, add @override and call super.dispose() here.
  void dispose() {
    _positionSubject.close();
    _audioPlayer.dispose();
  }
}
