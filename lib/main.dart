import 'dart:async';
import 'dart:io';
import 'dart:math' show Random, max;

import 'package:audio_service/audio_service.dart';
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
      title: '字幕音频播放器',
      theme: ThemeData(
        visualDensity: VisualDensity.adaptivePlatformDensity,
      ),
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        visualDensity: VisualDensity.adaptivePlatformDensity,
      ),
      themeMode: ThemeMode.system,
      home: const SubtitleAudioPlayer(),
    );
  }
}

String _formatDuration(Duration d) {
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '${d.inHours > 0 ? '${d.inHours}:' : ''}$m:$s';
}

class SubtitleAudioPlayer extends StatefulWidget {
  const SubtitleAudioPlayer({super.key});

  @override
  SubtitleAudioPlayerState createState() => SubtitleAudioPlayerState();
}

class SubtitleAudioPlayerState extends State<SubtitleAudioPlayer>
    with WidgetsBindingObserver {
  late final MyAudioHandler _audioHandler;
  StreamSubscription<Duration>? _positionSubscription;
  List<Subtitle> subtitles = [];
  int currentSubtitleIndex = 0;
  bool isFileLoaded = false;
  bool isRandomPlay = false;
  bool isLoopSingle = false;
  bool isPlaying = false;
  bool isDelaySubtitleDisplay = false;
  // 防止字幕结束回调在同一条字幕内重复触发（position stream 高频推送）
  bool _isSubtitleEndCalled = false;
  // 每次导航递增；stale 的异步 seek/play 完成后检测到不匹配则放弃
  int _playGeneration = 0;
  final _random = Random();
  bool shouldShowSubtitle = false;
  int subtitlePauseDuration = 3;
  String? audioFilePath;
  String? subtitleFilePath;
  // 随机模式下的播放历史，用于"上一句"回溯；上限 1000 条防止内存增长
  List<int> playedSubtitlesIndices = [];
  Timer? _subtitleDelayTimer;
  int _timerGeneration = 0;
  Timer? _saveSettingsDebounce;
  static const double _subtitleFontSize = 30.0;
  bool _isInitialized = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initAudioService();
  }

  Future<void> _initAudioService() async {
    _audioHandler = await AudioService.init(
      builder: () => MyAudioHandler(),
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.example.subtitle_audio_player',
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
    _audioHandler.cancelTimer = cancelSubtitleTimer;
    _audioHandler.updatePlayingStateCallback = _updatePlayingState;
    if (mounted) setState(() => _isInitialized = true);
    loadSettings();
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
    setState(() {
      isPlaying = playing;
    });
  }

  void checkSubtitleEnd(Duration position) {
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
    if (isDelaySubtitleDisplay) {
      // 用 realPause 而非 pause：realPause 不改变 isPlaying，
      // 使计时器到期后能通过 isPlaying 判断用户意图决定是否继续播放
      if (!isPlaying) return;
      await _audioHandler.realPause();
      if (!mounted) return;
      setState(() {
        shouldShowSubtitle = true;
      });
      _audioHandler.updateDisplaySubtitle(subtitles[currentSubtitleIndex].text);
      _subtitleDelayTimer?.cancel();
      final timerGen = ++_timerGeneration;
      _subtitleDelayTimer = Timer(Duration(seconds: subtitlePauseDuration), () {
        if (mounted && isPlaying && timerGen == _timerGeneration) {
          playNextSubtitle();
        }
      });
    } else {
      if (mounted && isPlaying) playNextSubtitle();
    }
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
    int? savedSubtitlePauseDuration = prefs.getInt('subtitlePauseDuration');
    int? savedCurrentSubtitleIndex = prefs.getInt('currentSubtitleIndex');
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
        if (savedSubtitlePauseDuration != null) {
          subtitlePauseDuration = savedSubtitlePauseDuration.clamp(1, 60);
        }
        if (savedCurrentSubtitleIndex != null) {
          currentSubtitleIndex = savedCurrentSubtitleIndex;
        }
        if (savedPlayedSubtitlesIndices != null) {
          playedSubtitlesIndices = savedPlayedSubtitlesIndices
              .map((i) => int.tryParse(i))
              .whereType<int>()
              .toList();
        }
      });
    }

    if (lastAudioFilePath != null &&
        lastAudioFilePath.isNotEmpty &&
        lastSubtitleFilePath != null &&
        lastSubtitleFilePath.isNotEmpty) {
      if (await File(lastAudioFilePath).exists() &&
          await File(lastSubtitleFilePath).exists()) {
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
            setState(() {
              currentSubtitleIndex = safeIndex;
              audioFilePath = lastAudioFilePath;
              subtitleFilePath = lastSubtitleFilePath;
              isFileLoaded = true;
            });
            // 将修正后的索引写回 prefs，避免每次冷启动都重复 clamp
            if (safeIndex != rawIndex) saveSettings();
          }
        } catch (e) {
          debugPrint('Failed to restore last session: $e');
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
    await prefs.setInt('subtitlePauseDuration', subtitlePauseDuration);
    await prefs.setStringList('playedSubtitlesIndices',
        playedSubtitlesIndices.map((i) => i.toString()).toList());
  }

  Future<void> setFileAudioSources(String filePath) async {
    final item = MediaItem(id: filePath, title: path.basename(filePath));
    await _audioHandler.setAudioSource(
      AudioSource.uri(Uri.file(filePath), tag: item),
      item,
    );
  }

  Future<void> pickAudioFileAndFindSubtitle() async {
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

    // 保存当前状态，用于取消时回滚
    final prevSubtitles = subtitles;
    final prevAudioPath = audioFilePath;
    final prevPlayedIndices = List<int>.from(playedSubtitlesIndices);

    try {
      subtitles = await parseSrtFile(newSubtitleFilePath);
      if (subtitles.isEmpty) throw Exception('字幕文件为空');
      await setFileAudioSources(newAudioFilePath);

      // 时长合理性检查：字幕最后时间戳不应远超音频时长
      final audioDur = _audioHandler.audioDuration;
      if (audioDur != null && subtitles.isNotEmpty) {
        final lastSrt = subtitles.last.endTime;
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
            // 取消：恢复旧音频源，避免 handler 与 UI 状态不一致
            subtitles = prevSubtitles;
            playedSubtitlesIndices = prevPlayedIndices;
            if (prevAudioPath != null) {
              await setFileAudioSources(prevAudioPath);
              if (subtitles.isNotEmpty) {
                await _audioHandler.seek(
                    subtitles[currentSubtitleIndex].startTime);
              }
            } else {
              await _audioHandler.stop();
            }
            return;
          }
        }
      }

      if (mounted) {
        setState(() {
          isFileLoaded = true;
          shouldShowSubtitle = !isDelaySubtitleDisplay;
          audioFilePath = newAudioFilePath;
          subtitleFilePath = newSubtitleFilePath;
          playedSubtitlesIndices = [];
          currentSubtitleIndex =
              isRandomPlay ? _random.nextInt(subtitles.length) : 0;
        });
        playAudioFromSubtitle(subtitles[currentSubtitleIndex]);
        saveSettings();
      }
    } catch (e) {
      debugPrint('无法加载文件: $e');
      if (!mounted) return;
      await showDialog(
        context: context,
        builder: (BuildContext context) {
          return AlertDialog(
            title: const Text("加载文件失败"),
            content: Text("加载音频或字幕文件时出错：$e"),
            actions: [
              TextButton(
                child: const Text("确定"),
                onPressed: () => Navigator.of(context).pop(),
              )
            ],
          );
        },
      );
      if (mounted) {
        setState(() {
          subtitleFilePath = null;
          audioFilePath = null;
          isFileLoaded = false;
          shouldShowSubtitle = false;
        });
        await _audioHandler.stop();
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // dispose() 是同步的，saveSettings() 无法 await；didChangeAppLifecycleState
    // 已在 paused/inactive 时保存，此处仅作兜底，快速退出时写入不保证完成。
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

  Future<void> playAudioFromSubtitle(Subtitle subtitle) async {
    _isSubtitleEndCalled = false;
    cancelSubtitleTimer();
    final gen = ++_playGeneration;
    if (_audioHandler.isAudioSourceSet) {
      await _audioHandler.seek(subtitle.startTime);
      if (gen != _playGeneration || !_audioHandler.isAudioSourceSet) return;
      _audioHandler.updateDisplaySubtitle(isDelaySubtitleDisplay ? '' : subtitle.text);
      if (!mounted) return;
      setState(() {
        shouldShowSubtitle = !isDelaySubtitleDisplay;
      });
      await _audioHandler.play();
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
    // stop() 后 position 归零但 isAudioSourceSet 仍为 true；isPlaying が false かつ
    // position が zero なら stopped 状態と見なし 2秒ルールを適用しない
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

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isDark
              ? [const Color(0xFF0A0A1A), const Color(0xFF1A0A2E)]
              : [const Color(0xFF818CF8), const Color(0xFFC084FC)],
        ),
      ),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: isDark
              ? Colors.white.withValues(alpha: 0.04)
              : Colors.white.withValues(alpha: 0.62),
          elevation: 0,
          scrolledUnderElevation: 0,
          surfaceTintColor: Colors.transparent,
          centerTitle: true,
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(1),
            child: Container(
              height: 1,
              color: isDark
                  ? Colors.white.withValues(alpha: 0.06)
                  : const Color(0xFF6D28D9).withValues(alpha: 0.10),
            ),
          ),
          title: Text(
            '字幕音频播放器',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: isDark ? const Color(0xFFD4D4FF) : const Color(0xFF1E0A3C),
            ),
          ),
        ),
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              // 字幕区固定60%，控制区占40%
              final subtitleHeight = constraints.maxHeight * 0.6;
              final controlsHeight = constraints.maxHeight * 0.4;

              return Column(
                children: [
                  // 文件名（位于字幕区上方）
                  if (fileName != null)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 20, vertical: 6),
                      child: Text(
                        fileName,
                        style: TextStyle(
                          fontSize: 13,
                          color: isDark
                              ? Colors.white.withValues(alpha: 0.50)
                              : Colors.white.withValues(alpha: 0.85),
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),

                  // 字幕展示区 - 占据60%高度，圆角卡片样式
                  Container(
                    width: double.infinity,
                    height: max(0, subtitleHeight - (fileName != null ? 40 : 0)),
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Container(
                      decoration: BoxDecoration(
                        color: isDark
                            ? Colors.white.withValues(alpha: 0.06)
                            : Colors.white.withValues(alpha: 0.88),
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(
                          color: isDark
                              ? Colors.white.withValues(alpha: 0.10)
                              : Colors.white,
                          width: 1,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: isDark
                                ? Colors.black.withValues(alpha: 0.40)
                                : const Color(0xFF6D28D9)
                                    .withValues(alpha: 0.18),
                            blurRadius: 24,
                            offset: const Offset(0, 6),
                          ),
                        ],
                      ),
                      child: Center(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            shouldShowSubtitle ? currentSubtitle : '',
                            style: TextStyle(
                              fontSize: _subtitleFontSize,
                              height: 1.8,
                              fontWeight:
                                  isDark ? FontWeight.w300 : FontWeight.w400,
                              color: shouldShowSubtitle
                                  ? (isDark
                                      ? Colors.white.withValues(alpha: 0.88)
                                      : const Color(0xFF2E1065))
                                  : (isDark
                                      ? Colors.white.withValues(alpha: 0.15)
                                      : const Color(0xFF2E1065)
                                          .withValues(alpha: 0.20)),
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                    ),
                  ),

                  // 字幕进度（位于字幕区和控制区之间）
                  if (subtitles.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Text(
                        '${currentSubtitleIndex + 1} / ${subtitles.length}',
                        style: TextStyle(
                          fontSize: 12,
                          color: isDark
                              ? Colors.white.withValues(alpha: 0.25)
                              : Colors.white.withValues(alpha: 0.65),
                        ),
                      ),
                    ),

                  // 控制区 - 占据40%高度，包含播放控制和延迟设置
                  SizedBox(
                    height: controlsHeight - (subtitles.isNotEmpty ? 32 : 0),
                    child: Column(
                      children: [
                        // 播放控制区：播放/暂停、上一句、下一句
                        Expanded(
                          child: Container(
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

                        // 字幕延迟控制：开关 + 延迟时间调节（- N + 秒）
                        Container(
                          margin: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 4),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 10),
                          decoration: BoxDecoration(
                            color: isDark
                                ? Colors.white.withValues(alpha: 0.05)
                                : Colors.white.withValues(alpha: 0.75),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: isDark
                                  ? Colors.white.withValues(alpha: 0.08)
                                  : Colors.white.withValues(alpha: 0.90),
                              width: 1,
                            ),
                            boxShadow: isDark
                                ? []
                                : [
                                    BoxShadow(
                                      color: const Color(0xFF6D28D9)
                                          .withValues(alpha: 0.10),
                                      blurRadius: 8,
                                      offset: const Offset(0, 2),
                                    ),
                                  ],
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Switch(
                                value: isDelaySubtitleDisplay,
                                activeThumbColor: const Color(0xFFA855F7),
                                onChanged: (v) {
                                  setState(() {
                                    isDelaySubtitleDisplay = v;
                                    // 关闭延迟时若字幕尚未显示，立即显示
                                    if (!v) shouldShowSubtitle = true;
                                  });
                                  if (!v) cancelSubtitleTimer();
                                  saveSettings();
                                },
                              ),
                              const SizedBox(width: 12),
                              Text(
                                '字幕延迟',
                                style: TextStyle(
                                  fontSize: 16,
                                  color: isDark
                                      ? Colors.white.withValues(alpha: 0.55)
                                      : const Color(0xFF6D28D9)
                                          .withValues(alpha: 0.70),
                                ),
                              ),
                              const SizedBox(width: 10),
                              _buildDelayBtn(Icons.remove, () {
                                if (subtitlePauseDuration > 1) {
                                  setState(() => subtitlePauseDuration--);
                                  saveSettings();
                                }
                              }, isDark),
                              Container(
                                width: 36,
                                alignment: Alignment.center,
                                child: Text(
                                  '$subtitlePauseDuration',
                                  style: const TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.w600,
                                    color: Color(0xFFA855F7),
                                  ),
                                ),
                              ),
                              _buildDelayBtn(Icons.add, () {
                                if (subtitlePauseDuration >= 60) return;
                                setState(() => subtitlePauseDuration++);
                                saveSettings();
                              }, isDark),
                              const SizedBox(width: 6),
                              Text(
                                '秒',
                                style: TextStyle(
                                  fontSize: 16,
                                  color: isDark
                                      ? Colors.white.withValues(alpha: 0.55)
                                      : const Color(0xFF6D28D9)
                                          .withValues(alpha: 0.70),
                                ),
                              ),
                            ],
                          ),
                        ),

                        // 底部快捷操作：随机播放、单曲循环、打开文件
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 20, vertical: 8),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                            children: [
                              _buildBottomBtn(
                                Icons.shuffle_rounded,
                                isRandomPlay,
                                () {
                                  setState(() {
                                    if (!isRandomPlay) {
                                      playedSubtitlesIndices.clear();
                                    }
                                    isRandomPlay = !isRandomPlay;
                                  });
                                  saveSettings();
                                },
                                isDark,
                              ),
                              _buildBottomBtn(
                                Icons.repeat_one_rounded,
                                isLoopSingle,
                                () {
                                  setState(() => isLoopSingle = !isLoopSingle);
                                  saveSettings();
                                },
                                isDark,
                              ),
                              _buildBottomBtn(
                                Icons.folder_open_rounded,
                                false,
                                pickAudioFileAndFindSubtitle,
                                isDark,
                              ),
                            ],
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

  Widget _buildDelayBtn(IconData icon, VoidCallback onTap, bool isDark) {
    const radius = BorderRadius.all(Radius.circular(10));
    final bgColor = isDark
        ? const Color(0xFFA855F7).withValues(alpha: 0.15)
        : Colors.white.withValues(alpha: 0.75);
    final borderColor = isDark
        ? const Color(0xFFA855F7).withValues(alpha: 0.30)
        : const Color(0xFFA855F7).withValues(alpha: 0.40);
    return Material(
      color: bgColor,
      borderRadius: radius,
      child: InkWell(
        onTap: onTap,
        borderRadius: radius,
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            borderRadius: radius,
            border: Border.all(color: borderColor, width: 1),
          ),
          child: Icon(icon, size: 20, color: const Color(0xFFA855F7)),
        ),
      ),
    );
  }

  Widget _buildBottomBtn(
      IconData icon, bool isActive, VoidCallback onTap, bool isDark) {
    const radius = BorderRadius.all(Radius.circular(12));
    final bgColor = isActive
        ? const Color(0xFFA855F7).withValues(alpha: 0.18)
        : (isDark
            ? Colors.white.withValues(alpha: 0.05)
            : Colors.white.withValues(alpha: 0.75));
    return Container(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: isDark
            ? []
            : [
                BoxShadow(
                  color: const Color(0xFF6D28D9).withValues(alpha: 0.10),
                  blurRadius: 6,
                  offset: const Offset(0, 2),
                ),
              ],
      ),
      child: Material(
        color: bgColor,
        borderRadius: radius,
        child: InkWell(
          onTap: onTap,
          borderRadius: radius,
          child: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              borderRadius: radius,
              border: Border.all(
                color: isActive
                    ? const Color(0xFFA855F7).withValues(alpha: 0.40)
                    : (isDark
                        ? Colors.white.withValues(alpha: 0.08)
                        : Colors.white.withValues(alpha: 0.90)),
                width: 1,
              ),
            ),
            child: Icon(
              icon,
              size: 20,
              color: isActive
                  ? const Color(0xFFA855F7)
                  : (isDark
                      ? Colors.white.withValues(alpha: 0.40)
                      : const Color(0xFF6D28D9).withValues(alpha: 0.45)),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPlayBtn(IconData icon, VoidCallback? onTap, bool isDark,
      {bool isPrimary = false}) {
    final enabled = onTap != null;
    if (isPrimary) {
      return Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        // boxShadow 必须放在外层 Container 而非 Ink，因为 Ink 不支持 boxShadow
        child: Container(
          width: 96,
          height: 96,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            boxShadow: enabled
                ? [
                    BoxShadow(
                      color: const Color(0xFFA855F7)
                          .withValues(alpha: isDark ? 0.55 : 0.40),
                      blurRadius: isDark ? 24 : 16,
                      spreadRadius: 2,
                      offset: Offset.zero,
                    ),
                  ]
                : [],
          ),
          child: Ink(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: enabled
                  ? const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [Color(0xFFA855F7), Color(0xFF6366F1)],
                    )
                  : null,
              color: enabled ? null : Colors.white.withValues(alpha: 0.12),
            ),
            child: InkWell(
              onTap: onTap,
              customBorder: const CircleBorder(),
              child: Icon(
                icon,
                size: 48,
                color: enabled
                    ? Colors.white
                    : Colors.white.withValues(alpha: 0.25),
              ),
            ),
          ),
        ),
      );
    }
    final secondaryBg = isDark
        ? Colors.white.withValues(alpha: 0.07)
        : Colors.white.withValues(alpha: 0.75);
    return Material(
      color: Colors.transparent,
      shape: const CircleBorder(),
      child: Container(
        width: 80,
        height: 80,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          boxShadow: isDark
              ? []
              : [
                  BoxShadow(
                    color: const Color(0xFF6D28D9).withValues(alpha: 0.15),
                    blurRadius: 10,
                    offset: const Offset(0, 2),
                  ),
                ],
        ),
        child: Ink(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: secondaryBg,
            border: Border.all(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.10)
                  : Colors.white.withValues(alpha: 0.90),
              width: 1,
            ),
          ),
          child: InkWell(
            onTap: onTap,
            customBorder: const CircleBorder(),
            child: Icon(
              icon,
              size: 36,
              color: enabled
                  ? (isDark
                      ? Colors.white.withValues(alpha: 0.55)
                      : const Color(0xFF6D28D9).withValues(alpha: 0.55))
                  : (isDark
                      ? Colors.white.withValues(alpha: 0.20)
                      : const Color(0xFF6D28D9).withValues(alpha: 0.20)),
            ),
          ),
        ),
      ),
    );
  }
}
