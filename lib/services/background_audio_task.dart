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
  // beginInterval() 暂停音频时不会改变此值，使延迟计时器能正确判断是否自动推进。
  bool isPlaying = false;
  // 字幕延迟模式下音频播放到字幕结束点后由 beginInterval() 置为 true，
  // 用于区分"延迟暂停"与用户手动暂停，影响通知栏播放状态的显示。
  bool _isDelayPaused = false;
  // 用户期望的播放速度。just_audio 在切换音频源后可能重置 speed，
  // 需要在 setAudioSource 中重新应用这个值。
  double _desiredSpeed = 1.0;
  // 当前音频文件名。MediaItem.title 在字幕显示时会被覆写为字幕文本，
  // 这里单独保留文件名供 updateDisplaySubtitle 复原"无字幕"态使用。
  String? _filename;
  // 录音/评估期间锁定通知栏按钮，防止用户通过通知栏操作干扰评估流程。
  bool _controlsLocked = false;

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

  void setControlsLocked(bool locked) {
    if (_controlsLocked == locked) return;
    _controlsLocked = locked;
    _updateMediaControls();
  }

  void _updateMediaControls() {
    // playing 跟随 isPlaying（用户意图）而非"音频是否真在输出"：字幕延迟期间
    // 音频虽暂停，但用户认知仍在播放，需保持通知栏暂停按钮与主界面一致。
    // 若用 isPlaying && !_isDelayPaused，Android 会按 STATE_PAUSED 渲染，
    // 强制把 MediaControl.pause 图标换成播放图标。
    // 录音/评估期间只保留播放/暂停（不提供上下句），防止用户从通知栏扰乱状态。
    final controls = <MediaControl>[
      isPlaying ? MediaControl.pause : MediaControl.play,
      if (!_controlsLocked) ...[
        MediaControl.skipToPrevious,
        MediaControl.skipToNext,
      ],
    ];
    playbackState.add(playbackState.value.copyWith(
      controls: controls,
      systemActions: const {},
      // 紧凑视图只显示播放/暂停，为通知标题（字幕文字）留出横向空间；
      // 上一句/下一句在展开视图中仍可见。
      androidCompactActionIndices: const [0],
      playing: isPlaying,
      // buffering 全部映射成 ready：本地文件切下一句时
      // _audioPlayer.seek() 会让 just_audio 走 ready → buffering → ready，
      // Samsung One UI 的 MediaStyle 在 buffering 期间会把 action 按钮
      // 重渲染成空白（短暂消失再回来），视觉上就是"切下一句前按钮闪一下"。
      // 本地文件 seek 引发的 buffering 是几十毫秒的瞬态，对用户没意义，
      // 直接 squash 成 ready 让通知保持稳定。
      // 代价：将来若接网络流，真正的缓冲也不再显示 spinner——
      // 当前 app 只读本地文件，可接受。
      processingState: {
        ProcessingState.idle: AudioProcessingState.idle,
        ProcessingState.loading: AudioProcessingState.loading,
        ProcessingState.buffering: AudioProcessingState.ready,
        ProcessingState.ready: AudioProcessingState.ready,
        ProcessingState.completed: AudioProcessingState.completed,
      }[_audioPlayer.processingState] ?? AudioProcessingState.idle,
      updatePosition: _audioPlayer.position,
      bufferedPosition: _audioPlayer.bufferedPosition,
      // 延迟暂停期间不下报 speed:0：iOS 锁屏 / 控制中心会把 playing:true+speed:0
      // 渲染成灰掉的不可点播放按钮，与 Android 上的"暂停可点"行为不一致。
      // 代价：Android 大尺寸通知栏 / Auto 在 0.5–5s 间隔内进度条会前进一点点。
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

  // 更新通知栏 / 锁屏 / 控制中心的字幕文字。
  // 用 title/artist（双端通用：Android 通知栏渲染、iOS MPNowPlayingInfoCenter
  // 都读这两个字段），不用 displayTitle/displaySubtitle（Android-only，iOS 不读）。
  // text 非空：title=字幕、artist=文件名；text 为空：title=文件名、artist=null。
  void updateDisplaySubtitle(String text) {
    final item = mediaItem.value;
    final filename = _filename;
    if (item == null || filename == null) return;
    // 用 MediaItem 构造而非 copyWith：copyWith 把 null 视为"保持原值"，
    // 没法把 artist 清回 null。
    mediaItem.add(MediaItem(
      id: item.id,
      title: text.isNotEmpty ? text : filename,
      artist: text.isNotEmpty ? filename : null,
      duration: item.duration,
    ));
  }

  Future<void> setAudioSource(AudioSource source, [MediaItem? item]) async {
    if (item != null) {
      _filename = item.title;
      mediaItem.add(item);
    }
    // 切换音频源时清掉延迟暂停标志，否则上一句 2 秒规则会把新音频
    // 的已播时长误判为 0（main.dart playPreviousSubtitle）。
    _isDelayPaused = false;
    // 顺序：先换源，再恢复音量。
    // 反过来的话，旧源若仍在播放（间隔静音期换文件），setVolume(1)
    // 会先把旧 drift 位置爆一下再卸载。换源后新源未播放，volume=1 安全。
    await _audioPlayer.setAudioSource(source);
    await _audioPlayer.setVolume(1.0);
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
    if (_controlsLocked || _audioPlayer.audioSource == null) return;
    cancelTimer?.call();
    _isDelayPaused = false;
    // 退出间隔静音期：如果是从 beginInterval 的 setVolume(0) 状态进入这里，
    // 必须先把音量恢复，否则音频继续静音播放。无论是否处于间隔，幂等安全。
    await _audioPlayer.setVolume(1.0);
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
    // 顺序：先 _audioPlayer.pause()，再 setVolume(1)。
    // 反过来的话，间隔静音期被外部 pause 打断时，setVolume(1) 会让
    // drift 位置（下一句中段）的音频在 _audioPlayer.pause() 真正停下来前
    // 全音量爆一下。停了再恢复音量，下一次 play() 仍能从 1.0 起播。
    await _audioPlayer.pause();
    await _audioPlayer.setVolume(1.0);
    updateIsPlaying(false);
  }

  /// 字幕间隔期入口：默认走"软静音"路径（`setVolume(0)`），音频继续播放但不出声。
  /// 这样外部组件（系统 MediaSession、蓝牙耳机、focus 仲裁等）观察到的
  /// 是"音频持续输出"，不会触发"无声 → 自动 pause / focus 转移"那类启发式，
  /// 也顺带把 iOS 锁屏 / 控制中心的"灰掉的播放按钮"问题解掉
  /// （audio session 输出未中断 → Now Playing 不会推断成 Paused）。
  ///
  /// `hardPause: true` 退回真暂停（旧 `realPause` 行为），用于"末句到文件尾
  /// 距离不足 intervalMs"这种没有静音余量可走的情形——再不停就要撞 completed。
  ///
  /// `_isDelayPaused = true` 跟之前语义一致：标记我们处于间隔窗口，
  /// 让 `playPreviousSubtitle` 的 2 秒规则能识别这种"已听完但 position 越过 endTime"
  /// 的状态、`_updatePlayingState` 不在间隔期被错误地清 generation 等。
  Future<void> beginInterval({bool hardPause = false}) async {
    _isDelayPaused = true;
    if (hardPause) {
      await _audioPlayer.pause();
    } else {
      // setVolume(0)：position 仍前进、playerState 仍 playing，
      // _playerStateSub 不会被触发推一次重复 playbackState，避免抖动。
      await _audioPlayer.setVolume(0);
    }
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
    // 同 pause()：先 stop 让音频停下，再恢复音量，避免间隔静音期 stop 时爆音。
    await _audioPlayer.stop();
    await _audioPlayer.setVolume(1.0);
    updateIsPlaying(false);
  }

  @override
  Future<void> seek(Duration position) async {
    // 顺序至关重要——先 seek 再 setVolume(1)。
    // 间隔期音频飘到 endTime+intervalMs，这位置经常落在下一句的中段。
    // 如果反过来（先 setVolume 再 seek），seek 命令真正生效前的几毫秒里，
    // 音频会以原 drift 位置（下一句中段）全音量出声——典型表现是
    // "下一句开头被爆出一截杂音"。
    // 先 seek 让 buffering 接住静默期、落到新 startTime 后再开音量，
    // 代价是新句子开头可能被吃掉极少数 ms（不可闻，远好于爆音）。
    try {
      await _audioPlayer.seek(position);
    } finally {
      // seek 失败（音频源已释放、文件被删等）也必须恢复音量，
      // 否则间隔静音期的 volume=0 会让后续所有播放永久静音。
      await _audioPlayer.setVolume(1.0);
    }
  }

  @override
  Future<void> skipToNext() async {
    if (_controlsLocked) return;
    await onSkipToNext?.call();
  }

  @override
  Future<void> skipToPrevious() async {
    if (_controlsLocked) return;
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
