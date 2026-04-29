import 'package:shared_preferences/shared_preferences.dart';

class SettingsData {
  final String? lastAudioFilePath;
  final String? lastSubtitleFilePath;
  final bool isLoopSingle;
  final bool isRandomPlay;
  final bool isDelaySubtitleDisplay;
  final double playInterval;
  final int currentSubtitleIndex;
  final double playbackSpeed;
  final List<int> playedSubtitlesIndices;

  const SettingsData({
    this.lastAudioFilePath,
    this.lastSubtitleFilePath,
    this.isLoopSingle = false,
    this.isRandomPlay = false,
    this.isDelaySubtitleDisplay = false,
    this.playInterval = 1.5,
    this.currentSubtitleIndex = 0,
    this.playbackSpeed = 1.0,
    this.playedSubtitlesIndices = const [],
  });
}

class SettingsService {
  static Future<SettingsData> load() async {
    final prefs = await SharedPreferences.getInstance();
    return SettingsData(
      lastAudioFilePath: prefs.getString('lastAudioFilePath'),
      lastSubtitleFilePath: prefs.getString('lastSubtitleFilePath'),
      isLoopSingle: prefs.getBool('loopSingle') ?? false,
      isRandomPlay: prefs.getBool('randomPlay') ?? false,
      isDelaySubtitleDisplay: prefs.getBool('delaySubtitleDisplay') ?? false,
      playInterval: quantizeInterval(prefs.getDouble('playInterval') ?? 1.5),
      currentSubtitleIndex: prefs.getInt('currentSubtitleIndex') ?? 0,
      playbackSpeed: quantizeSpeed(prefs.getDouble('playbackSpeed') ?? 1.0),
      playedSubtitlesIndices: (prefs.getStringList('playedSubtitlesIndices') ?? [])
          .map((i) => int.tryParse(i))
          .whereType<int>()
          .toList(),
    );
  }

  static Future<void> save(SettingsData s) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (s.lastAudioFilePath != null && s.lastAudioFilePath!.isNotEmpty) {
        await prefs.setString('lastAudioFilePath', s.lastAudioFilePath!);
      } else {
        await prefs.remove('lastAudioFilePath');
      }
      if (s.lastSubtitleFilePath != null && s.lastSubtitleFilePath!.isNotEmpty) {
        await prefs.setString('lastSubtitleFilePath', s.lastSubtitleFilePath!);
      } else {
        await prefs.remove('lastSubtitleFilePath');
      }
      await prefs.setBool('loopSingle', s.isLoopSingle);
      await prefs.setBool('randomPlay', s.isRandomPlay);
      await prefs.setBool('delaySubtitleDisplay', s.isDelaySubtitleDisplay);
      await prefs.setInt('currentSubtitleIndex', s.currentSubtitleIndex);
      await prefs.setDouble('playInterval', s.playInterval);
      await prefs.setDouble('playbackSpeed', s.playbackSpeed);
      await prefs.setStringList('playedSubtitlesIndices',
          s.playedSubtitlesIndices.map((i) => i.toString()).toList());
    } catch (e) {
      // saveSettings 在多处被无 await 调用；静默吞掉写入失败
    }
  }

  static Future<void> clearFilePaths() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('lastAudioFilePath');
      await prefs.remove('lastSubtitleFilePath');
    } catch (_) {}
  }

  static double quantizeSpeed(double s) {
    final clamped = s.clamp(0.5, 2.0);
    return (clamped * 4).round() / 4;
  }

  static double quantizeInterval(double v) {
    final clamped = v.clamp(0.5, 5.0);
    return (clamped * 2).round() / 2;
  }

}
