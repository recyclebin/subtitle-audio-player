import 'dart:async';
import 'dart:io';
import 'dart:math' show Random, max;

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';

import 'background_audio_task.dart';
import 'subtitle_parser.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '听见',
      theme: ThemeData(
        visualDensity: VisualDensity.adaptivePlatformDensity,
      ),
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        visualDensity: VisualDensity.adaptivePlatformDensity,
      ),
      themeMode: ThemeMode.system,
      home: const TingjianApp(),
    );
  }
}

String _formatDuration(Duration d) {
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '${d.inHours > 0 ? '${d.inHours}:' : ''}$m:$s';
}

class TingjianApp extends StatefulWidget {
  const TingjianApp({super.key});

  @override
  TingjianAppState createState() => TingjianAppState();
}

class TingjianAppState extends State<TingjianApp>
    with WidgetsBindingObserver {
  late final MyAudioHandler _audioHandler;
  StreamSubscription<Duration>? _positionSubscription;
  List<Subtitle> subtitles = [];
  int currentSubtitleIndex = 0;
  bool isFileLoaded = false;
  bool isRandomPlay = false;
  bool isLoopSingle = false;
  bool isPlaying = false;
  // ON：播放时隐藏字幕，仅在播放间隔时显示；OFF：播放与间隔时均显示字幕。
  bool isDelaySubtitleDisplay = false;
  // 防止字幕结束回调在同一条字幕内重复触发（position stream 高频推送）
  bool _isSubtitleEndCalled = false;
  // 每次导航递增；过期的异步 seek/play 完成后检测到不匹配则放弃
  int _playGeneration = 0;
  final _random = Random();
  // ON 模式下默认 false（隐藏），字幕结束后由 onSubtitleEnd 置为 true（显示）；
  // OFF 模式下始终为 true。
  bool shouldShowSubtitle = false;
  // 每条字幕播放结束后强制暂停的时长，单位秒。范围 [0.5, 5.0]，步进 0.5；
  // 0.5 在二进制下精确，量化无浮点漂移。
  double playInterval = 1.5;
  // 0.5-2.0 之间，步长 0.25。所有取值都是 0.25 的整数倍，二进制下精确无漂移。
  double playbackSpeed = 1.0;
  String? audioFilePath;
  String? subtitleFilePath;
  // 随机模式下的播放历史，用于"上一句"回溯；上限 1000 条防止内存增长
  List<int> playedSubtitlesIndices = [];
  Timer? _subtitleDelayTimer;
  // 每次取消计时器时递增，计时器回调比对此值防止过期触发
  int _timerGeneration = 0;
  Timer? _saveSettingsDebounce;
  static const double _subtitleFontSize = 30.0;
  // AudioService.init() 完成前为 false，dispose 时用于判断是否需要清理 handler
  bool _isInitialized = false;
  // 防止用户在文件加载期间重复点击文件夹按钮导致并发竞争
  bool _isPicking = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initAudioService();
  }

  Future<void> _initAudioService() async {
    // iOS 必需：把 AVAudioSession 类别设为 .playback（speech 预设包含此项）。
    // audio_service 0.18+ 不再自动配置音频会话，缺这步则 iOS 默认 ambient
    // 类别，锁屏 / 控制中心不会显示 Now Playing 控件，且 app 退后台后音频
    // 会被系统静音。Android 上此调用为无操作。
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.speech());

    _audioHandler = await AudioService.init(
      builder: () => MyAudioHandler(),
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.yao.tingjian',
        androidNotificationChannelName: 'Audio Playback',
        // 保持前台服务运行，防止暂停后通知消失
        androidStopForegroundOnPause: false,
      ),
    );
    _setupPositionListener();
    _audioHandler.onSkipToNext = () async {
      playNextSubtitle(ignoreLoopSingle: true);
    };
    _audioHandler.onSkipToPrevious = () async {
      playPreviousSubtitle();
    };
    // 将 widget 侧的回调注入 handler，使通知栏按钮能驱动字幕导航和计时器管理
    _audioHandler.cancelTimer = cancelSubtitleTimer;
    _audioHandler.updatePlayingStateCallback = _updatePlayingState;
    // 用 _isPicking=true 包裹恢复过程：不仅播放按钮的 picker 回退入口被阻塞，
    // 底部 folder_open 按钮调用 pickAudioFileAndFindSubtitle 时也会被
    // _isPicking 早返回，避免任何 picker 入口与 loadSettings 内的
    // setFileAudioSources 竞争。
    // try/finally 保证即使 loadSettings 抛异常也能开放 UI，
    // 否则 _isInitialized 会永久卡在 false 导致界面无法操作。
    _isPicking = true;
    try {
      await loadSettings();
    } catch (e) {
      debugPrint('恢复设置失败: $e');
    } finally {
      _isPicking = false;
      if (mounted) setState(() => _isInitialized = true);
    }
  }

  void _setupPositionListener() {
    _positionSubscription = _audioHandler.positionStream.listen((position) {
      checkSubtitleEnd(position);
    });
  }

  void _updatePlayingState(bool playing) {
    // 从非播放状态恢复时，允许当前位置的字幕结束事件重新触发。
    // 不在暂停时重置：暂停期间 position stream 仍会推送到字幕结束点，
    // 若在暂停时重置则会误触发 onSubtitleEnd，导致 isPlaying=false 时
    // 延迟计时器到期后无法推进，且 _isSubtitleEndCalled 变 true 永久压制后续触发。
    if (playing && !isPlaying) _isSubtitleEndCalled = false;
    // 用户暂停（应用内或通知栏）时让任何挂起的播放链失效。
    // 延迟暂停期间，timer 刚触发的 playAudioFromSubtitle 可能已经过 seek，
    // 此时若用户点暂停，pause 完成后 await seek resolve，gen 检查仍会通过，
    // _audioHandler.play() 接着把音频重新放出来——表现为"点暂停后图标仍是
    // 暂停但音频继续播放"。beginInterval 不调 updateIsPlaying，不会走到这里，
    // 所以正常的字幕间隔→自动续播链不受影响。
    if (!playing) ++_playGeneration;
    setState(() {
      isPlaying = playing;
    });
  }

  void checkSubtitleEnd(Duration position) {
    if (!isPlaying) return;
    if (subtitles.isNotEmpty &&
        currentSubtitleIndex >= 0 &&
        currentSubtitleIndex < subtitles.length) {
      final subtitleEndTime = subtitles[currentSubtitleIndex].endTime;
      if (position < subtitleEndTime) {
        // 位置回退到当前字幕范围内（seek或直接play），重置标志允许再次触发
        _isSubtitleEndCalled = false;
      } else if (!_isSubtitleEndCalled) {
        _isSubtitleEndCalled = true;
        onSubtitleEnd();
      }
    }
  }

  Future<void> onSubtitleEnd() async {
    // 用 beginInterval 而非 pause：beginInterval 不改变 isPlaying，
    // 使计时器到期后能通过 isPlaying 判断用户意图决定是否继续播放。
    if (!isPlaying) return;
    final endTime = subtitles[currentSubtitleIndex].endTime;
    final intervalMs = (playInterval * 1000).round();
    final dur = _audioHandler.audioDuration;
    // 默认走软静音（setVolume(0)）；末句距文件尾不足 intervalMs 时退回真暂停，
    // 否则音频在 timer fire 前先撞到 ProcessingState.completed，notification
    // 会闪一下"已结束"。极少数情况下 duration 还没解出来 (null)，保守走 hard。
    final hasRoom = dur != null &&
        (dur - endTime).inMilliseconds >= intervalMs;
    await _audioHandler.beginInterval(hardPause: !hasRoom);
    if (!mounted) return;
    // beginInterval 让出执行权期间用户可能按了播放：handler.play() 会把
    // _isDelayPaused 清回 false。此时若继续往下走会调度新 timer，
    // 在用户想听当前句的时候把音频跳到下一句。
    if (!_audioHandler.isDelayPaused) return;
    if (isDelaySubtitleDisplay) {
      // 播放期间字幕被隐藏，间隔开始时揭示
      setState(() {
        shouldShowSubtitle = true;
      });
      _audioHandler.updateDisplaySubtitle(subtitles[currentSubtitleIndex].text);
    }
    _subtitleDelayTimer?.cancel();
    final timerGen = ++_timerGeneration;
    _subtitleDelayTimer = Timer(Duration(milliseconds: intervalMs), () {
      if (mounted && isPlaying && timerGen == _timerGeneration) {
        playNextSubtitle();
      }
    });
    // _isSubtitleEndCalled 不在此处重置，而是延迟到 playAudioFromSubtitle 开头重置，
    // 防止 seek 完成前 position stream 仍停留在旧位置时再次触发 onSubtitleEnd
  }

  void cancelSubtitleTimer() {
    ++_timerGeneration;
    _subtitleDelayTimer?.cancel();
    _subtitleDelayTimer = null;
  }

  Future<void> loadSettings() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    String? lastAudioFilePath = prefs.getString('lastAudioFilePath');
    String? lastSubtitleFilePath = prefs.getString('lastSubtitleFilePath');
    bool? loopSingle = prefs.getBool('loopSingle');
    bool? randomPlay = prefs.getBool('randomPlay');
    bool? delaySubtitleDisplay = prefs.getBool('delaySubtitleDisplay');
    double? savedPlayInterval = prefs.getDouble('playInterval');
    int? savedCurrentSubtitleIndex = prefs.getInt('currentSubtitleIndex');
    double? savedPlaybackSpeed = prefs.getDouble('playbackSpeed');
    List<String>? savedPlayedSubtitlesIndices =
        prefs.getStringList('playedSubtitlesIndices');

    if (mounted) {
      setState(() {
        if (loopSingle != null) isLoopSingle = loopSingle;
        if (randomPlay != null) isRandomPlay = randomPlay;
        if (delaySubtitleDisplay != null) {
          isDelaySubtitleDisplay = delaySubtitleDisplay;
          shouldShowSubtitle = !isDelaySubtitleDisplay;
        }
        if (savedPlayInterval != null) {
          playInterval = _quantizeInterval(savedPlayInterval);
        }
        if (savedCurrentSubtitleIndex != null) {
          currentSubtitleIndex = savedCurrentSubtitleIndex;
        }
        if (savedPlaybackSpeed != null) {
          // 量化到 0.25 的倍数，防止外部写入或旧版本残留奇怪小数
          playbackSpeed = _quantizeSpeed(savedPlaybackSpeed);
        }
        if (savedPlayedSubtitlesIndices != null) {
          playedSubtitlesIndices = savedPlayedSubtitlesIndices
              .map((i) => int.tryParse(i))
              .whereType<int>()
              .toList();
        }
      });
    }
    // 把恢复的速度同步到 handler；无音频源时 handler 只记录值，
    // 等 setFileAudioSources 加载完会自动应用。
    await _audioHandler.setSpeed(playbackSpeed);

    if (lastAudioFilePath != null &&
        lastAudioFilePath.isNotEmpty &&
        lastSubtitleFilePath != null &&
        lastSubtitleFilePath.isNotEmpty) {
      final audioExists = await File(lastAudioFilePath).exists();
      final subtitleExists = await File(lastSubtitleFilePath).exists();
      if (!audioExists || !subtitleExists) {
        // 文件已被删除/移动：清掉残留键，下次冷启动直接显示「请选择文件」，
        // 避免每次启动都白白做一次 File.exists 检查。
        await prefs.remove('lastAudioFilePath');
        await prefs.remove('lastSubtitleFilePath');
      } else {
        try {
          subtitles = await parseSrtFile(lastSubtitleFilePath);
          if (subtitles.isEmpty) throw Exception('字幕文件为空');
          // 历史索引可能来自更长的文件，过滤掉超出当前字幕列表的条目
          playedSubtitlesIndices = playedSubtitlesIndices
              .where((i) => i >= 0 && i < subtitles.length)
              .toList();
          // 上次退出时的索引可能超出新文件范围，clamp 保证安全
          final rawIndex = currentSubtitleIndex;
          final safeIndex = rawIndex.clamp(0, subtitles.length - 1);
          await setFileAudioSources(lastAudioFilePath);
          await _audioHandler.seek(subtitles[safeIndex].startTime);
          if (mounted) {
            _audioHandler.updateDisplaySubtitle(isDelaySubtitleDisplay ? '' : subtitles[safeIndex].text);
            // currentSubtitleIndex 在 setState 之前显式赋值，
            // 使 saveSettings() 读取时不依赖闭包执行顺序
            currentSubtitleIndex = safeIndex;
            setState(() {
              audioFilePath = lastAudioFilePath;
              subtitleFilePath = lastSubtitleFilePath;
              isFileLoaded = true;
            });
            // 将修正后的索引写回 prefs，避免每次冷启动都重复 clamp
            if (safeIndex != rawIndex) saveSettings();
          }
        } catch (e) {
          debugPrint('恢复上次会话失败: $e');
          subtitles = [];
          if (mounted) {
            setState(() {
              isFileLoaded = false;
              currentSubtitleIndex = 0;
            });
          }
        }
      }
    }
  }

  Future<void> saveSettings() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    if (audioFilePath != null && audioFilePath!.isNotEmpty) {
      await prefs.setString('lastAudioFilePath', audioFilePath!);
    } else {
      await prefs.remove('lastAudioFilePath');
    }
    if (subtitleFilePath != null && subtitleFilePath!.isNotEmpty) {
      await prefs.setString('lastSubtitleFilePath', subtitleFilePath!);
    } else {
      await prefs.remove('lastSubtitleFilePath');
    }
    await prefs.setBool('loopSingle', isLoopSingle);
    await prefs.setBool('randomPlay', isRandomPlay);
    await prefs.setBool('delaySubtitleDisplay', isDelaySubtitleDisplay);
    await prefs.setInt('currentSubtitleIndex', currentSubtitleIndex);
    await prefs.setDouble('playInterval', playInterval);
    await prefs.setDouble('playbackSpeed', playbackSpeed);
    await prefs.setStringList('playedSubtitlesIndices',
        playedSubtitlesIndices.map((i) => i.toString()).toList());
  }

  /// 量化到 0.25 的倍数并 clamp 到 [0.5, 2.0]。
  /// 0.25 在二进制下精确，量化后的值不会有浮点漂移。
  double _quantizeSpeed(double s) {
    final clamped = s.clamp(0.5, 2.0);
    return (clamped * 4).round() / 4;
  }

  /// 1.0 → "1"；0.75 → "0.75"。给整数去掉 ".0" 让 UI 更紧凑。
  /// 速度（0.25 步进）和播放间隔（0.5 步进）都用它，故名 step 而非 speed。
  String _formatStep(double s) {
    return s == s.roundToDouble() ? '${s.toInt()}' : '$s';
  }

  /// 量化到 0.5 的倍数并 clamp 到 [0.5, 5.0]。
  double _quantizeInterval(double v) {
    final clamped = v.clamp(0.5, 5.0);
    return (clamped * 2).round() / 2;
  }

  void _setPlaybackSpeed(double s) {
    final next = _quantizeSpeed(s);
    if (next == playbackSpeed) return;
    setState(() => playbackSpeed = next);
    _audioHandler.setSpeed(next);
    saveSettings();
  }

  Future<void> setFileAudioSources(String filePath) async {
    final item = MediaItem(id: filePath, title: path.basename(filePath));
    await _audioHandler.setAudioSource(
      AudioSource.uri(Uri.file(filePath), tag: item),
      item,
    );
  }

  Future<void> pickAudioFileAndFindSubtitle() async {
    if (_isPicking) return;
    _isPicking = true;
    try {
      await _pickAudioFileAndFindSubtitleImpl();
    } finally {
      _isPicking = false;
    }
  }

  Future<void> _pickAudioFileAndFindSubtitleImpl() async {
    // 一次选择音频 + 字幕，allowMultiple: true 避免两次弹窗
    FilePickerResult? result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['mp3', 'm4a', 'aac', 'flac', 'wav', 'srt'],
      allowMultiple: true,
    );

    if (result == null) return; // 用户取消

    final audioExtensions = {'mp3', 'm4a', 'aac', 'flac', 'wav'};
    final audioFiles = result.files
        .where((f) =>
            f.path != null &&
            audioExtensions.contains(f.extension?.toLowerCase()))
        .toList();
    final srtFiles = result.files
        .where((f) => f.path != null && f.extension?.toLowerCase() == 'srt')
        .toList();

    if (audioFiles.length != 1 || srtFiles.length != 1) {
      if (!mounted) return;
      await showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('请选择一个音频和一个字幕'),
          content: const Text(
              '需要选中恰好一个音频文件（mp3/m4a/aac/flac/wav）和一个字幕文件（srt），不多不少。'),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('确定')),
          ],
        ),
      );
      return;
    }

    final String newAudioFilePath = audioFiles.first.path!;
    final String newSubtitleFilePath = srtFiles.first.path!;

    // 保存当前会话快照：仅在音频源已切换后失败/取消时用于恢复，
    // 不再用于"回滚字段"——字段直到提交阶段才会被修改。
    final prevAudioPath = audioFilePath;
    final prevSubtitles = subtitles;
    final prevIndex = currentSubtitleIndex;

    // 1. 先解析字幕到局部变量；解析失败时不动任何状态，旧会话原样保留。
    final List<Subtitle> parsedSubtitles;
    try {
      parsedSubtitles = await parseSrtFile(newSubtitleFilePath);
      if (parsedSubtitles.isEmpty) throw Exception('字幕文件为空');
    } catch (e) {
      debugPrint('解析字幕文件失败: $e');
      if (!mounted) return;
      await _showLoadErrorDialog(e);
      return;
    }

    // 2. 切换音频源；失败时尝试恢复上次音频源，不 wipe 字段。
    try {
      await setFileAudioSources(newAudioFilePath);
    } catch (e) {
      debugPrint('加载音频文件失败: $e');
      await _restorePrevAudio(prevAudioPath, prevSubtitles, prevIndex);
      if (!mounted) return;
      await _showLoadErrorDialog(e);
      return;
    }

    // 3. 时长合理性检查：字幕最后时间戳不应远超音频时长
    final audioDur = _audioHandler.audioDuration;
    if (audioDur != null) {
      final lastSrt = parsedSubtitles.last.endTime;
      if (lastSrt > audioDur * 1.1) {
        if (!mounted) return;
        final proceed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('文件可能不匹配'),
            content: Text(
                '字幕最后时间戳 ${_formatDuration(lastSrt)} 远超音频时长 ${_formatDuration(audioDur)}，确认继续？'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('取消')),
              TextButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('继续')),
            ],
          ),
        );
        if (proceed != true) {
          await _restorePrevAudio(prevAudioPath, prevSubtitles, prevIndex);
          return;
        }
      }
    }

    // 4. 提交：所有可能失败的步骤都已成功，开始更新字段。
    if (!mounted) return;
    setState(() {
      subtitles = parsedSubtitles;
      isFileLoaded = true;
      shouldShowSubtitle = !isDelaySubtitleDisplay;
      audioFilePath = newAudioFilePath;
      subtitleFilePath = newSubtitleFilePath;
      playedSubtitlesIndices = [];
      currentSubtitleIndex =
          isRandomPlay ? _random.nextInt(parsedSubtitles.length) : 0;
    });
    playAudioFromSubtitle(subtitles[currentSubtitleIndex]);
    saveSettings();
  }

  /// 取消/失败时恢复上次音频源；prevAudioPath 为 null 时停止播放。
  /// 任何步骤异常均吞掉，避免在错误处理路径里再次抛出。
  Future<void> _restorePrevAudio(String? prevAudioPath,
      List<Subtitle> prevSubtitles, int prevIndex) async {
    try {
      if (prevAudioPath != null) {
        await setFileAudioSources(prevAudioPath);
        if (prevSubtitles.isNotEmpty &&
            prevIndex >= 0 &&
            prevIndex < prevSubtitles.length) {
          await _audioHandler.seek(prevSubtitles[prevIndex].startTime);
        }
      } else {
        await _audioHandler.stop();
      }
    } catch (e) {
      debugPrint('恢复上次音频源失败: $e');
    }
  }

  Future<void> _showLoadErrorDialog(Object error) async {
    if (!mounted) return;
    await showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text("加载文件失败"),
          content: Text("加载音频或字幕文件时出错：$error"),
          actions: [
            TextButton(
              child: const Text("确定"),
              onPressed: () => Navigator.of(context).pop(),
            )
          ],
        );
      },
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // dispose() 是同步的，saveSettings() 无法 await；didChangeAppLifecycleState
    // 已在 paused 时保存，此处仅作兜底，快速退出时写入不保证完成。
    saveSettings(); // ignore: unawaited_futures
    _saveSettingsDebounce?.cancel();
    _subtitleDelayTimer?.cancel();
    _positionSubscription?.cancel();
    if (_isInitialized) {
      // handler 生命周期独立于 widget，清空回调防止 widget 销毁后仍被调用
      _audioHandler.updatePlayingStateCallback = null;
      _audioHandler.onSkipToNext = null;
      _audioHandler.onSkipToPrevious = null;
      _audioHandler.cancelTimer = null;
      _audioHandler.dispose();
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      saveSettings();
    }
  }

  // seek 到指定字幕起点并播放；同步更新通知栏字幕文字和界面显示状态。
  // _playGeneration 在每次调用时递增，用于取消过期的异步链。
  Future<void> playAudioFromSubtitle(Subtitle subtitle) async {
    _isSubtitleEndCalled = false;
    cancelSubtitleTimer();
    final gen = ++_playGeneration;
    if (_audioHandler.isAudioSourceSet) {
      // 必须在 await seek 之前更新字幕显示状态：调用方（如 playNextSubtitle）
      // 已先 setState 改了 currentSubtitleIndex，若隐藏放在 seek 之后，
      // seek 让出执行权时 Flutter 会先用"新索引 + 旧 shouldShowSubtitle=true"
      // 渲染一帧，造成新字幕闪现。同步合并到同一帧即可消除闪烁。
      _audioHandler.updateDisplaySubtitle(isDelaySubtitleDisplay ? '' : subtitle.text);
      if (mounted) {
        setState(() {
          shouldShowSubtitle = !isDelaySubtitleDisplay;
        });
      }
      await _audioHandler.seek(subtitle.startTime);
      if (gen != _playGeneration || !_audioHandler.isAudioSourceSet) return;
      await _audioHandler.play();
      // play() 是长生命周期 Future，resolve 时可能已开始新导航；
      // 此处之后不应有依赖当前字幕状态的代码
      if (gen != _playGeneration) return;
    }
  }

  /// 防抖版 saveSettings：快速连续导航时合并写入，120ms 内无新调用才实际保存。
  void _debouncedSave() {
    _saveSettingsDebounce?.cancel();
    _saveSettingsDebounce = Timer(const Duration(milliseconds: 120), saveSettings);
  }

  /// 从 [0, subtitles.length) 中随机取一个不等于 [exclude] 的索引。
  /// 当只有一条字幕时返回 0（无法避免重复）。
  int _randomIndexExcluding(int exclude) {
    if (subtitles.length <= 1) return 0;
    int idx;
    do {
      idx = _random.nextInt(subtitles.length);
    } while (idx == exclude);
    return idx;
  }

  void playNextSubtitle({bool ignoreLoopSingle = false}) {
    if (subtitles.isEmpty) return;
    if (isLoopSingle && !ignoreLoopSingle) {
      playAudioFromSubtitle(subtitles[currentSubtitleIndex]);
    } else {
      if (isRandomPlay) {
        setState(() {
          // 先把当前索引存入历史，再跳随机，确保"上一句"能正确回溯
          playedSubtitlesIndices.add(currentSubtitleIndex);
          if (playedSubtitlesIndices.length > 1000) {
            playedSubtitlesIndices.removeAt(0);
          }
          currentSubtitleIndex = _randomIndexExcluding(currentSubtitleIndex);
        });
      } else {
        setState(() {
          currentSubtitleIndex =
              currentSubtitleIndex < subtitles.length - 1 ? currentSubtitleIndex + 1 : 0;
        });
      }
      _debouncedSave();
      playAudioFromSubtitle(subtitles[currentSubtitleIndex]);
    }
  }

  void playPreviousSubtitle() {
    if (subtitles.isEmpty || !_audioHandler.isAudioSourceSet) return;
    final current = subtitles[currentSubtitleIndex];
    // stop() 后 position 归零但 isAudioSourceSet 仍为 true；
    // isPlaying 为 false 且 position 为零则视为已停止状态，不应用 2 秒重播规则
    final pos = _audioHandler.position;
    final isStopped = !isPlaying && pos == Duration.zero;
    // 延迟暂停时 pos 停在字幕结束处，不代表用户已听完，视为未播放
    final playedMs = (isStopped || _audioHandler.isDelayPaused)
        ? 0
        : (pos - current.startTime).inMilliseconds.clamp(0, 999999);
    if (playedMs > 2000) {
      // 当前句已播放超过2秒：重播当前句
      playAudioFromSubtitle(current);
      return;
    }
    if (isRandomPlay) {
      setState(() {
        currentSubtitleIndex = playedSubtitlesIndices.isNotEmpty
            ? playedSubtitlesIndices.removeLast()
            : _randomIndexExcluding(currentSubtitleIndex);
      });
    } else {
      setState(() {
        currentSubtitleIndex =
            currentSubtitleIndex == 0 ? subtitles.length - 1 : currentSubtitleIndex - 1;
      });
    }
    _debouncedSave();
    playAudioFromSubtitle(subtitles[currentSubtitleIndex]);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final currentSubtitle =
        (subtitles.isNotEmpty && currentSubtitleIndex < subtitles.length)
            ? subtitles[currentSubtitleIndex].text
            : '';
    final fileName = audioFilePath != null
        ? path.basenameWithoutExtension(audioFilePath!)
        : null;

    // 背景：深色基底 + 顶部柔和紫色光晕。RadialGradient 一次完成，
    // 比"两层 LinearGradient + 阴影"轻得多，也更接近 Apple Music 的触感。
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
          // 取消底部分割线：纯净背景下细线显多余
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
              // 字幕是主视觉，占 70%；控制压缩到 30%。
              // 设置（速度、延迟）放进底部抽屉，不再占首屏纵向空间。
              final subtitleHeight = constraints.maxHeight * 0.7;
              final controlsHeight = constraints.maxHeight * 0.3;

              return Column(
                children: [
                  // 文件名：极克制的小字，让字幕成为唯一焦点
                  if (fileName != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                      child: Text(
                        fileName,
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

                  // 字幕展示区 - 占据 70% 高度
                  // 去掉重阴影和白边框；用轻微背景色把卡片从背景中"浮"出来即可
                  Container(
                    width: double.infinity,
                    height: max(0, subtitleHeight - (fileName != null ? 36 : 0)),
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
                              fontSize: _subtitleFontSize,
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

                  // 字幕进度：极小、低对比，不抢戏
                  if (subtitles.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Text(
                        '${currentSubtitleIndex + 1} / ${subtitles.length}',
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

                  // 控制区 - 占据30%：上半播放按钮，下半统一图标行
                  SizedBox(
                    height: controlsHeight - (subtitles.isNotEmpty ? 24 : 0),
                    child: Column(
                      children: [
                        // 播放控制区：播放/暂停、上一句、下一句
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 40),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                              children: [
                                _buildPlayBtn(
                                  isPlaying
                                      ? Icons.pause_rounded
                                      : Icons.play_arrow_rounded,
                                  (_isInitialized && isFileLoaded)
                                      ? () async {
                                          if (isPlaying) {
                                            await _audioHandler.pause();
                                          } else {
                                            await _audioHandler.play();
                                          }
                                        }
                                      : (_isInitialized
                                          ? pickAudioFileAndFindSubtitle
                                          : null),
                                  isDark,
                                  isPrimary: true,
                                ),
                                _buildPlayBtn(
                                  Icons.skip_previous_rounded,
                                  (_isInitialized && isFileLoaded)
                                      ? playPreviousSubtitle
                                      : null,
                                  isDark,
                                ),
                                _buildPlayBtn(
                                  Icons.skip_next_rounded,
                                  (_isInitialized && isFileLoaded)
                                      ? () => playNextSubtitle(
                                          ignoreLoopSingle: true)
                                      : null,
                                  isDark,
                                ),
                              ],
                            ),
                          ),
                        ),

                        // 统一图标行：速度 / 延迟 / 随机 / 循环 / 文件
                        // 极轻的卡片背景，无阴影无边框，让图标自己说话
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                          child: Container(
                            decoration: BoxDecoration(
                              color: isDark
                                  ? Colors.white.withValues(alpha: 0.04)
                                  : Colors.white.withValues(alpha: 0.50),
                              borderRadius: BorderRadius.circular(22),
                            ),
                            child: Row(
                              children: [
                                _buildActionItem(
                                  icon: Icons.speed_rounded,
                                  label: '${_formatStep(playbackSpeed)}x',
                                  isActive: playbackSpeed != 1.0,
                                  onTap: _isInitialized ? _showSpeedSheet : null,
                                  isDark: isDark,
                                ),
                                _buildActionItem(
                                  icon: Icons.timer_outlined,
                                  label: '${_formatStep(playInterval)}s',
                                  isActive: isDelaySubtitleDisplay,
                                  onTap: _isInitialized ? _showDelaySheet : null,
                                  isDark: isDark,
                                ),
                                _buildActionItem(
                                  icon: Icons.shuffle_rounded,
                                  label: '随机',
                                  isActive: isRandomPlay,
                                  onTap: _isInitialized
                                      ? () {
                                          setState(() {
                                            // 进、出随机模式都清空历史：
                                            // 残留历史会让下次开启随机时
                                            // 「上一句」回溯到上一会话的索引，体感意外。
                                            playedSubtitlesIndices.clear();
                                            isRandomPlay = !isRandomPlay;
                                          });
                                          saveSettings();
                                        }
                                      : null,
                                  isDark: isDark,
                                ),
                                _buildActionItem(
                                  icon: Icons.repeat_one_rounded,
                                  label: '循环',
                                  isActive: isLoopSingle,
                                  onTap: _isInitialized
                                      ? () {
                                          setState(() =>
                                              isLoopSingle = !isLoopSingle);
                                          saveSettings();
                                        }
                                      : null,
                                  isDark: isDark,
                                ),
                                _buildActionItem(
                                  icon: Icons.folder_open_rounded,
                                  label: '文件',
                                  isActive: false,
                                  onTap: _isInitialized
                                      ? pickAudioFileAndFindSubtitle
                                      : null,
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

  /// 抽屉里的 +/- 调节按钮：圆形扁平，紫色填充弱化版。
  Widget _buildDelayBtn(IconData icon, VoidCallback onTap, bool isDark) {
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
          child: Icon(
            icon,
            size: 22,
            color: const Color(0xFFA855F7),
          ),
        ),
      ),
    );
  }

  /// 统一图标行的单个条目：图标 + 小字标签，等分占据父容器宽度。
  /// 平时用中性灰，紫色仅在 isActive=true 时出现，
  /// 让"打开了什么"在视觉上一眼可辨。
  Widget _buildActionItem({
    required IconData icon,
    required String label,
    required bool isActive,
    required VoidCallback? onTap,
    required bool isDark,
  }) {
    const activeColor = Color(0xFFA855F7);
    final inactiveColor = isDark
        ? Colors.white.withValues(alpha: 0.62)
        : const Color(0xFF1E0A3C).withValues(alpha: 0.62);
    final disabledColor = isDark
        ? Colors.white.withValues(alpha: 0.20)
        : const Color(0xFF1E0A3C).withValues(alpha: 0.22);
    final color = onTap == null
        ? disabledColor
        : (isActive ? activeColor : inactiveColor);
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

  /// 底部抽屉外壳：drag handle + title + child。
  /// dark 模式用深紫，light 模式用纯白；圆角顶部，安全区底部内边距。
  Widget _buildSheetShell(
      BuildContext sheetContext, bool isDark, String title, Widget child) {
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
              color: isDark
                  ? const Color(0xFFD4D4FF)
                  : const Color(0xFF1E0A3C),
            ),
          ),
          const SizedBox(height: 28),
          child,
        ],
      ),
    );
  }

  void _showSpeedSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        final isDark = Theme.of(sheetContext).brightness == Brightness.dark;
        // StatefulBuilder：父 setState 不会重建抽屉内部，
        // 用 setSheetState 在调整后立刻刷新抽屉内显示的数值。
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return _buildSheetShell(
              sheetContext,
              isDark,
              '播放速度',
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _buildDelayBtn(Icons.remove, () {
                    _setPlaybackSpeed(playbackSpeed - 0.25);
                    setSheetState(() {});
                  }, isDark),
                  SizedBox(
                    width: 100,
                    child: Text(
                      '${_formatStep(playbackSpeed)}x',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 32,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFFA855F7),
                      ),
                    ),
                  ),
                  _buildDelayBtn(Icons.add, () {
                    _setPlaybackSpeed(playbackSpeed + 0.25);
                    setSheetState(() {});
                  }, isDark),
                ],
              ),
            );
          },
        );
      },
    );
  }

  void _showDelaySheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        final isDark = Theme.of(sheetContext).brightness == Brightness.dark;
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return _buildSheetShell(
              sheetContext,
              isDark,
              '播放间隔',
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _buildDelayBtn(Icons.remove, () {
                        final next = _quantizeInterval(playInterval - 0.5);
                        if (next != playInterval) {
                          setState(() => playInterval = next);
                          saveSettings();
                          setSheetState(() {});
                        }
                      }, isDark),
                      SizedBox(
                        width: 100,
                        child: Text(
                          '${_formatStep(playInterval)}s',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 32,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFFA855F7),
                          ),
                        ),
                      ),
                      _buildDelayBtn(Icons.add, () {
                        final next = _quantizeInterval(playInterval + 0.5);
                        if (next != playInterval) {
                          setState(() => playInterval = next);
                          saveSettings();
                          setSheetState(() {});
                        }
                      }, isDark),
                    ],
                  ),
                  const SizedBox(height: 24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Switch(
                        value: isDelaySubtitleDisplay,
                        activeThumbColor: const Color(0xFFA855F7),
                        onChanged: (v) {
                          setState(() {
                            isDelaySubtitleDisplay = v;
                            // 关闭"仅间隔显示"时立刻补回字幕，避免界面/通知栏卡在空白
                            if (!v) {
                              shouldShowSubtitle = true;
                              if (subtitles.isNotEmpty &&
                                  currentSubtitleIndex < subtitles.length) {
                                _audioHandler.updateDisplaySubtitle(
                                    subtitles[currentSubtitleIndex].text);
                              }
                            }
                          });
                          saveSettings();
                          setSheetState(() {});
                        },
                      ),
                      const SizedBox(width: 12),
                      Text(
                        '播放间隔显示字幕',
                        style: TextStyle(
                          fontSize: 16,
                          color: isDark
                              ? Colors.white.withValues(alpha: 0.70)
                              : const Color(0xFF2E1065)
                                  .withValues(alpha: 0.75),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  /// 主播放按钮：80px 实心紫色圆，无发光阴影，按下水波。
  /// 副按钮（上一句/下一句）：纯图标，无背景，靠水波反馈。
  Widget _buildPlayBtn(IconData icon, VoidCallback? onTap, bool isDark,
      {bool isPrimary = false}) {
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
