import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';
import 'package:rxdart/rxdart.dart';

class MyAudioHandler extends BaseAudioHandler {
  final _audioPlayer = AudioPlayer();
  // BehaviorSubject：新订阅者立即收到最后一个值（初始为 Duration.zero），
  // 避免 _setupPositionListener 注册前的启动事件丢失。
  final BehaviorSubject<Duration> _positionSubject =
      BehaviorSubject<Duration>.seeded(Duration.zero);
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<PlayerState>? _playerStateSub;
  // 以下回调由 widget 在 AudioService.init() 完成后注入，dispose 时清空，
  // 防止 widget 销毁后仍被 handler 调用。
  void Function(bool)? updatePlayingStateCallback;
  Future<void> Function()? onSkipToNext;
  Future<void> Function()? onSkipToPrevious;
  void Function()? cancelTimer;
  // isPlaying 表示用户可见的播放意图，而非底层音频是否真正在输出声音。
  // realPause() 暂停音频时不会改变此值，使延迟计时器能正确判断是否自动推进。
  bool isPlaying = false;
  // 字幕延迟模式下音频播放到字幕结束点后由 realPause() 置为 true，
  // 用于区分"延迟暂停"与用户手动暂停，影响通知栏播放状态的显示。
  bool _isDelayPaused = false;
  // 用户期望的播放速度。just_audio 在切换音频源后可能重置 speed，
  // 需要在 setAudioSource 中重新应用这个值。
  double _desiredSpeed = 1.0;

  bool get isAudioSourceSet => _audioPlayer.audioSource != null;
  bool get isDelayPaused => _isDelayPaused;
  double get desiredSpeed => _desiredSpeed;
  Duration? get audioDuration => _audioPlayer.duration;

  // 同步更新 handler 内部状态、widget 回调和通知栏控件。
  void updateIsPlaying(bool playing) {
    isPlaying = playing;
    updatePlayingStateCallback?.call(playing);
    _updateMediaControls();
  }

  void _updateMediaControls() {
    // playing 跟随 isPlaying（用户意图）而非"音频是否真在输出"：字幕延迟期间
    // 音频虽暂停，但用户认知仍在播放，需保持通知栏暂停按钮与主界面一致。
    // 若用 isPlaying && !_isDelayPaused，Android 会按 STATE_PAUSED 渲染，
    // 强制把 MediaControl.pause 图标换成播放图标。
    playbackState.add(playbackState.value.copyWith(
      controls: [
        isPlaying ? MediaControl.pause : MediaControl.play,
        MediaControl.skipToPrevious,
        MediaControl.skipToNext,
      ],
      systemActions: const {},
      // 紧凑视图只显示播放/暂停，为通知标题（字幕文字）留出横向空间；
      // 上一句/下一句在展开视图中仍可见。
      androidCompactActionIndices: const [0],
      playing: isPlaying,
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
    _positionSub = _audioPlayer.positionStream.listen((position) {
      _positionSubject.add(position);
    });
    // 将 just_audio 的状态变化（buffering/completed 等）同步到 playbackState，
    // 使通知栏保持可见且 processingState 准确。
    // 不在此处调 updateIsPlaying——isPlaying 只由 play()/pause()/stop() 管理。
    _playerStateSub = _audioPlayer.playerStateStream.listen((_) {
      _updateMediaControls();
    });
  }

  // 更新通知栏字幕文字：text 非空时以字幕为主标题、文件名为副标题；
  // text 为空时两者均置 null，回退到 MediaItem.title（文件名）显示。
  void updateDisplaySubtitle(String text) {
    final item = mediaItem.value;
    if (item == null) return;
    mediaItem.add(item.copyWith(
      displayTitle: text.isNotEmpty ? text : null,
      displaySubtitle: text.isNotEmpty ? item.title : null,
    ));
  }

  Future<void> setAudioSource(AudioSource source, [MediaItem? item]) async {
    if (item != null) mediaItem.add(item);
    // 切换音频源时清掉延迟暂停标志，否则旧会话残留的 true 会让
    // _updateMediaControls() 算出的 effectivelyPlaying 与新音频源状态不符。
    _isDelayPaused = false;
    await _audioPlayer.setAudioSource(source);
    // 新音频源加载可能重置 just_audio 的 speed，重新应用记忆值。
    // 1.0 是默认值，省一次 platform 调用。
    if (_desiredSpeed != 1.0) {
      await _audioPlayer.setSpeed(_desiredSpeed);
    }
    // Android 前台服务（通知栏）只在 playing:true 时首次启动。
    // 此处短暂发射 playing:true 触发 startForeground()，
    // 随后 _updateMediaControls() 立即还原为实际暂停状态。
    // androidStopForegroundOnPause:false 确保通知在暂停后持续显示。
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
    // updateIsPlaying 必须在 await _audioPlayer.play() 之前调用。
    // just_audio 的 play() 是长生命周期 Future，仅在音频停止时才 resolve；
    // 若放在 await 之后，整个播放期间 isPlaying 将始终为 false。
    updateIsPlaying(true);
    try {
      await _audioPlayer.play();
    } catch (_) {
      // 底层播放器异常（音频焦点丢失、编解码错误等）时重置状态，
      // 避免 isPlaying 永久卡在 true。
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

  /// 字幕延迟模式专用暂停：音频静音但不改变 isPlaying，
  /// 使延迟计时器到期后能通过 isPlaying 判断是否自动播放下一句。
  /// 依赖 just_audio 的保证：调用 pause() 会令当前挂起的 play() Future resolve，
  /// 从而解除 MyAudioHandler.play() 中的 await 阻塞。
  Future<void> realPause() async {
    _isDelayPaused = true;
    await _audioPlayer.pause();
    _updateMediaControls();
  }

  /// 设置播放速度。无音频源时只记录值，避免 platform 端在未初始化时
  /// 抛错或挂起；下次 setAudioSource 加载完会自动应用。
  /// BaseAudioHandler 也定义了 setSpeed（系统侧可能调用），这里覆盖。
  @override
  Future<void> setSpeed(double speed) async {
    _desiredSpeed = speed;
    if (_audioPlayer.audioSource != null) {
      await _audioPlayer.setSpeed(speed);
    }
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

  // 非 @override——BaseAudioHandler 目前没有 dispose()。
  // 若未来版本的 audio_service 添加了该方法，需加上 @override 并调用 super.dispose()。
  void dispose() {
    // 先取消订阅，再关闭 subject，避免 _audioPlayer 在 dispose 期间仍推送事件
    // 导致 _positionSubject.add() 对已关闭的 BehaviorSubject 抛出异常。
    _positionSub?.cancel();
    _playerStateSub?.cancel();
    _positionSubject.close();
    _audioPlayer.dispose();
  }
}
