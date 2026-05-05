import 'dart:async';
import 'dart:io';
import 'dart:math' show Random;

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as path;

import 'services/background_audio_task.dart';
import 'services/subtitle_parser.dart';
import 'services/settings_service.dart';
import 'services/pronunciation_service.dart';
import 'services/assessment_history_service.dart';
import 'models/assessment_result.dart';
import 'widgets/pronunciation_score_card.dart';
import 'widgets/history_list_view.dart';
import 'widgets/player_screen.dart';

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
  bool isDelaySubtitleDisplay = false;
  bool _isSubtitleEndCalled = false;
  int _playGeneration = 0;
  final _random = Random();
  bool shouldShowSubtitle = false;
  double playInterval = 1.5;
  double playbackSpeed = 1.0;
  String? audioFilePath;
  String? subtitleFilePath;
  List<int> playedSubtitlesIndices = [];
  Timer? _subtitleDelayTimer;
  int _timerGeneration = 0;
  Timer? _saveSettingsDebounce;
  bool _isInitialized = false;
  PronunciationService? _pronService;
  AssessmentHistoryService? _historyService;
  int _assessmentMode = 0;
  String? _azureKey;
  String? _azureRegion;
  bool _isPicking = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initAudioService();
  }

  Future<void> _initAudioService() async {
    _isPicking = true;
    var audioReady = false;
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.speech());

      _audioHandler = await AudioService.init(
        builder: () => MyAudioHandler(),
        config: const AudioServiceConfig(
          androidNotificationChannelId: 'com.yao.tingjian',
          androidNotificationChannelName: 'Audio Playback',
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
      audioReady = true;
      try {
        await _loadSettings();
      } catch (e) {
        debugPrint('恢复设置失败: $e');
      }
      try {
        await _initPronunciationServices();
      } catch (e) {
        debugPrint('初始化发音评估服务失败: $e');
      }
    } catch (e) {
      debugPrint('初始化音频服务失败: $e');
    } finally {
      _isPicking = false;
      if (mounted && audioReady) setState(() => _isInitialized = true);
    }
  }

  void _setupPositionListener() {
    _positionSubscription = _audioHandler.positionStream.listen((position) {
      checkSubtitleEnd(position);
    });
  }

  void _updatePlayingState(bool playing) {
    if (playing && !isPlaying) _isSubtitleEndCalled = false;
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
        _isSubtitleEndCalled = false;
      } else if (!_isSubtitleEndCalled) {
        _isSubtitleEndCalled = true;
        onSubtitleEnd();
      }
    }
  }

  Future<void> onSubtitleEnd() async {
    if (!isPlaying) return;
    final endTime = subtitles[currentSubtitleIndex].endTime;
    final intervalMs = (playInterval * 1000).round();
    final dur = _audioHandler.audioDuration;
    final hasRoom = dur != null &&
        (dur - endTime).inMilliseconds >= intervalMs;
    await _audioHandler.beginInterval(hardPause: !hasRoom);
    if (!mounted) return;
    if (!_audioHandler.isDelayPaused) return;
    if (isDelaySubtitleDisplay) {
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
  }

  void cancelSubtitleTimer() {
    ++_timerGeneration;
    _subtitleDelayTimer?.cancel();
    _subtitleDelayTimer = null;
  }

  Future<void> _loadSettings() async {
    final s = await SettingsService.load();

    if (mounted) {
      setState(() {
        isLoopSingle = s.isLoopSingle;
        isRandomPlay = s.isRandomPlay;
        isDelaySubtitleDisplay = s.isDelaySubtitleDisplay;
        shouldShowSubtitle = !s.isDelaySubtitleDisplay;
        playInterval = s.playInterval;
        currentSubtitleIndex = s.currentSubtitleIndex;
        playbackSpeed = s.playbackSpeed;
        _assessmentMode = s.assessmentMode;
        _azureKey = s.azureSubscriptionKey;
        _azureRegion = s.azureRegion;
        playedSubtitlesIndices = s.playedSubtitlesIndices;
      });
    }
    await _audioHandler.setSpeed(playbackSpeed);

    if (s.lastAudioFilePath != null &&
        s.lastAudioFilePath!.isNotEmpty &&
        s.lastSubtitleFilePath != null &&
        s.lastSubtitleFilePath!.isNotEmpty) {
      final audioExists = await File(s.lastAudioFilePath!).exists();
      final subtitleExists = await File(s.lastSubtitleFilePath!).exists();
      if (!audioExists || !subtitleExists) {
        await SettingsService.clearFilePaths();
      } else {
        try {
          subtitles = await parseSrtFile(s.lastSubtitleFilePath!);
          if (subtitles.isEmpty) throw Exception('字幕文件为空');
          playedSubtitlesIndices = playedSubtitlesIndices
              .where((i) => i >= 0 && i < subtitles.length)
              .toList();
          final rawIndex = currentSubtitleIndex;
          final safeIndex = rawIndex.clamp(0, subtitles.length - 1);
          await setFileAudioSources(s.lastAudioFilePath!);
          await _audioHandler.seek(subtitles[safeIndex].startTime);
          if (mounted) {
            _audioHandler.updateDisplaySubtitle(
                isDelaySubtitleDisplay ? '' : subtitles[safeIndex].text);
            currentSubtitleIndex = safeIndex;
            setState(() {
              audioFilePath = s.lastAudioFilePath;
              subtitleFilePath = s.lastSubtitleFilePath;
              isFileLoaded = true;
            });
            if (safeIndex != rawIndex) _saveSettings();
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

  SettingsData _currentSettings() => SettingsData(
        lastAudioFilePath: audioFilePath,
        lastSubtitleFilePath: subtitleFilePath,
        isLoopSingle: isLoopSingle,
        isRandomPlay: isRandomPlay,
        isDelaySubtitleDisplay: isDelaySubtitleDisplay,
        playInterval: playInterval,
        currentSubtitleIndex: currentSubtitleIndex,
        playbackSpeed: playbackSpeed,
        playedSubtitlesIndices: playedSubtitlesIndices,
        assessmentMode: _assessmentMode,
        azureSubscriptionKey: _azureKey,
        azureRegion: _azureRegion,
      );

  Future<void> _saveSettings() async {
    await SettingsService.save(_currentSettings());
  }

  void _setPlaybackSpeed(double s) {
    final next = SettingsService.quantizeSpeed(s);
    if (next == playbackSpeed) return;
    setState(() => playbackSpeed = next);
    _audioHandler.setSpeed(next);
    _saveSettings();
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
    FilePickerResult? result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['mp3', 'm4a', 'aac', 'flac', 'wav', 'srt'],
      allowMultiple: true,
    );

    if (result == null) return;

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

    final prevAudioPath = audioFilePath;
    final prevSubtitles = subtitles;
    final prevIndex = currentSubtitleIndex;

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

    try {
      await setFileAudioSources(newAudioFilePath);
    } catch (e) {
      debugPrint('加载音频文件失败: $e');
      await _restorePrevAudio(prevAudioPath, prevSubtitles, prevIndex);
      if (!mounted) return;
      await _showLoadErrorDialog(e);
      return;
    }

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
    _saveSettings();
  }

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
    _saveSettingsDebounce?.cancel();
    _saveSettings();
    _subtitleDelayTimer?.cancel();
    _positionSubscription?.cancel();
    if (_isInitialized) {
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
      _saveSettings();
    }
  }

  Future<void> playAudioFromSubtitle(Subtitle subtitle) async {
    _isSubtitleEndCalled = false;
    cancelSubtitleTimer();
    final gen = ++_playGeneration;
    if (_audioHandler.isAudioSourceSet) {
      _audioHandler.updateDisplaySubtitle(
          isDelaySubtitleDisplay ? '' : subtitle.text);
      if (mounted) {
        setState(() {
          shouldShowSubtitle = !isDelaySubtitleDisplay;
        });
      }
      await _audioHandler.seek(subtitle.startTime);
      if (gen != _playGeneration || !_audioHandler.isAudioSourceSet) return;
      await _audioHandler.play();
      if (gen != _playGeneration) return;
    }
  }

  void _debouncedSave() {
    _saveSettingsDebounce?.cancel();
    _saveSettingsDebounce =
        Timer(const Duration(milliseconds: 120), _saveSettings);
  }

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
          playedSubtitlesIndices.add(currentSubtitleIndex);
          if (playedSubtitlesIndices.length > 1000) {
            playedSubtitlesIndices.removeAt(0);
          }
          currentSubtitleIndex = _randomIndexExcluding(currentSubtitleIndex);
        });
      } else {
        setState(() {
          currentSubtitleIndex = currentSubtitleIndex < subtitles.length - 1
              ? currentSubtitleIndex + 1
              : 0;
        });
      }
      _debouncedSave();
      playAudioFromSubtitle(subtitles[currentSubtitleIndex]);
    }
  }

  void playPreviousSubtitle() {
    if (subtitles.isEmpty || !_audioHandler.isAudioSourceSet) return;
    final current = subtitles[currentSubtitleIndex];
    final pos = _audioHandler.position;
    final isStopped = !isPlaying && pos == Duration.zero;
    final playedMs = (isStopped || _audioHandler.isDelayPaused)
        ? 0
        : (pos - current.startTime).inMilliseconds.clamp(0, 999999);
    if (playedMs > 2000) {
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
        currentSubtitleIndex = currentSubtitleIndex == 0
            ? subtitles.length - 1
            : currentSubtitleIndex - 1;
      });
    }
    _debouncedSave();
    playAudioFromSubtitle(subtitles[currentSubtitleIndex]);
  }

  void _showSpeedSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => StatefulBuilder(
        builder: (_, setSheetState) {
          final isDark =
              Theme.of(sheetContext).brightness == Brightness.dark;
          return SpeedSheet(
            label: formatStep(playbackSpeed),
            isDark: isDark,
            onDecrease: () {
              _setPlaybackSpeed(playbackSpeed - 0.25);
              setSheetState(() {});
            },
            onIncrease: () {
              _setPlaybackSpeed(playbackSpeed + 0.25);
              setSheetState(() {});
            },
          );
        },
      ),
    );
  }

  void _showDelaySheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => StatefulBuilder(
        builder: (_, setSheetState) {
          final isDark =
              Theme.of(sheetContext).brightness == Brightness.dark;
          return DelaySheet(
            label: formatStep(playInterval),
            isDark: isDark,
            isDelayEnabled: isDelaySubtitleDisplay,
            onDecrease: () {
              final next =
                  SettingsService.quantizeInterval(playInterval - 0.5);
              if (next != playInterval) {
                setState(() => playInterval = next);
                _saveSettings();
                setSheetState(() {});
              }
            },
            onIncrease: () {
              final next =
                  SettingsService.quantizeInterval(playInterval + 0.5);
              if (next != playInterval) {
                setState(() => playInterval = next);
                _saveSettings();
                setSheetState(() {});
              }
            },
            onDelayToggle: (v) {
              setState(() {
                isDelaySubtitleDisplay = v;
                if (!v) {
                  shouldShowSubtitle = true;
                  if (subtitles.isNotEmpty &&
                      currentSubtitleIndex < subtitles.length) {
                    _audioHandler.updateDisplaySubtitle(
                        subtitles[currentSubtitleIndex].text);
                  }
                }
              });
              _saveSettings();
              setSheetState(() {});
            },
          );
        },
      ),
    );
  }

  Future<void> _initPronunciationServices() async {
    await _tryInitPronunciationServices(
      key: _azureKey ?? '',
      region: _azureRegion ?? 'eastasia',
    );
  }

  Future<void> _tryInitPronunciationServices({
    required String key,
    required String region,
  }) async {
    if (key.isEmpty) return;
    _pronService?.dispose();
    _pronService = PronunciationService(subscriptionKey: key, region: region);
    _historyService ??= await AssessmentHistoryService.create();
  }

  Future<void> _startAssessment() async {
    if (_pronService == null) return;
    if (subtitles.isEmpty || currentSubtitleIndex >= subtitles.length) return;

    if (_assessmentMode == 0) {
      if (isPlaying) {
        await _audioHandler.pause();
      }
    }

    try {
      final hasPerm = await _pronService!.checkPermission();
      if (!hasPerm) {
        if (mounted) {
          _showMicPermissionDialog();
        }
        return;
      }
      await _pronService!.startRecording();
    } catch (e) {
      debugPrint('开始录音失败: $e');
    }
  }

  Future<void> _stopAssessment() async {
    if (_pronService == null) return;
    if (subtitles.isEmpty || currentSubtitleIndex >= subtitles.length) return;

    final referenceText = subtitles[currentSubtitleIndex].text;

    try {
      final result = await _pronService!.stopAndAssess(referenceText);
      if (_assessmentMode == 0) {
        await _audioHandler.play();
      }
      if (_historyService != null) {
        final record = AssessmentRecord(
          id: DateTime.now().microsecondsSinceEpoch.toString(),
          audioFilePath: audioFilePath ?? '',
          subtitleIndex: currentSubtitleIndex,
          result: result,
          timestamp: DateTime.now(),
        );
        await _historyService!.append(record);
      }
      if (mounted) {
        _showScoreCard(result);
      }
    } on AssessmentException catch (e) {
      if (_assessmentMode == 0) {
        await _audioHandler.play();
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message)),
        );
      }
    } catch (e) {
      if (_assessmentMode == 0) {
        await _audioHandler.play();
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('评估失败，请重试')),
        );
      }
    }
  }

  void _showMicPermissionDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('需要麦克风权限'),
        content: const Text('请在系统设置中允许麦克风权限后重试。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  void _showScoreCard(AssessmentResult result) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => PronunciationScoreCard(
        result: result,
        isDark: isDark,
        onClose: () => Navigator.of(context).pop(),
      ),
    );
  }

  Future<void> _openHistory() async {
    if (_historyService == null) return;
    final groups = await _historyService!.loadByFile();
    if (!mounted) return;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => HistoryListView(
          fileGroups: groups,
          isDark: isDark,
          onViewResult: (result) {
            _showScoreCard(result);
          },
        ),
      ),
    );
  }

  void _toggleAssessmentMode() {
    setState(() {
      _assessmentMode = _assessmentMode == 0 ? 1 : 0;
    });
    _saveSettings();
  }

  void _showAzureConfig() {
    final keyController = TextEditingController(text: _azureKey ?? '');
    final regionController = TextEditingController(text: _azureRegion ?? 'eastasia');

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Azure 语音服务配置'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: keyController,
              decoration: const InputDecoration(
                labelText: 'Subscription Key',
                hintText: '请输入 Azure 订阅密钥',
                border: OutlineInputBorder(),
              ),
              obscureText: true,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: regionController,
              decoration: const InputDecoration(
                labelText: 'Region',
                hintText: 'eastasia',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              final key = keyController.text.trim();
              final region = regionController.text.trim();
              if (key.isEmpty) return;
              _configureAzure(key: key, region: region);
              Navigator.of(ctx).pop();
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  void _configureAzure({required String key, required String region}) {
    _azureKey = key;
    _azureRegion = region;
    _saveSettings();
    _tryInitPronunciationServices(key: key, region: region);
    if (mounted) setState(() {});
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

    return PlayerScreen(
      isDark: isDark,
      fileName: fileName,
      currentSubtitle: currentSubtitle,
      shouldShowSubtitle: shouldShowSubtitle,
      hasSubtitles: subtitles.isNotEmpty,
      subtitleIndex: currentSubtitleIndex,
      subtitleCount: subtitles.length,
      isPlaying: isPlaying,
      isFileLoaded: isFileLoaded,
      isInitialized: _isInitialized,
      onPlayPause: (_isInitialized && isFileLoaded)
          ? () async {
              if (isPlaying) {
                await _audioHandler.pause();
              } else {
                await _audioHandler.play();
              }
            }
          : (_isInitialized ? pickAudioFileAndFindSubtitle : null),
      onPrevious:
          (_isInitialized && isFileLoaded) ? playPreviousSubtitle : null,
      onNext: (_isInitialized && isFileLoaded)
          ? () => playNextSubtitle(ignoreLoopSingle: true)
          : null,
      speedLabel: formatStep(playbackSpeed),
      isSpeedActive: playbackSpeed != 1.0,
      onSpeedTap: _isInitialized ? _showSpeedSheet : null,
      intervalLabel: formatStep(playInterval),
      isIntervalActive: isDelaySubtitleDisplay,
      onIntervalTap: _isInitialized ? _showDelaySheet : null,
      isRandomActive: isRandomPlay,
      onRandomTap: _isInitialized
          ? () {
              setState(() {
                playedSubtitlesIndices.clear();
                isRandomPlay = !isRandomPlay;
              });
              _saveSettings();
            }
          : null,
      isLoopActive: isLoopSingle,
      onLoopTap: _isInitialized
          ? () {
              setState(() => isLoopSingle = !isLoopSingle);
              _saveSettings();
            }
          : null,
      onFileTap: _isInitialized ? pickAudioFileAndFindSubtitle : null,
      assessmentMode: _assessmentMode,
      onStartRecording: (_isInitialized && isFileLoaded && _pronService != null)
          ? _startAssessment
          : null,
      onStopRecording: (_isInitialized && isFileLoaded && _pronService != null)
          ? _stopAssessment
          : null,
      onToggleAssessmentMode: _isInitialized ? _toggleAssessmentMode : null,
      onOpenHistory: (_isInitialized && _historyService != null)
          ? _openHistory
          : null,
      onConfigureAzure: _isInitialized ? _showAzureConfig : null,
    );
  }
}
