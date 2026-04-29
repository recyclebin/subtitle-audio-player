# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
# Run on Android device/emulator
flutter run

# Build release APK
flutter build apk --release

# Analyze (lint)
flutter analyze

# Run tests
flutter test

# Run a single test file
flutter test test/widget_test.dart
```

## Architecture

The app has five Dart source files across two subdirectories:

**`lib/main.dart`** — State management and playback coordination. `TingjianAppState` owns all application state: subtitle list, current index, play mode flags (`isRandomPlay`, `isLoopSingle`, `isDelaySubtitleDisplay`), playback speed, and the subtitle delay timer. It drives the `MyAudioHandler` and reacts to position updates via `positionStream`. The `build()` method assembles data and delegates to `PlayerScreen`.

**`lib/widgets/player_screen.dart`** — All UI. `PlayerScreen` (the main screen), `PlayBtn`, `ActionItem`, `SheetShell`, `DelayBtn`, `SpeedSheet`, `DelaySheet`, plus the `formatStep` utility. All widgets are `StatelessWidget`s that receive data and callbacks via constructor — no `setState`.

**`lib/services/settings_service.dart`** — `SettingsData` (pure data class for all persisted fields) and `SettingsService` (static `load`/`save`/`clearFilePaths`/`quantizeSpeed`/`quantizeInterval`). Encapsulates all `SharedPreferences` access.

**`lib/services/background_audio_task.dart`** — `MyAudioHandler` extends `BaseAudioHandler` from `audio_service`. It wraps `just_audio`'s `AudioPlayer` and bridges it to the Android media notification. Key design points:
- `isPlaying` in the handler reflects *user intent* (not actual audio output). `beginInterval()` enters the silent gap between subtitles via `setVolume(0)` (audio keeps streaming, just inaudible) without clearing `isPlaying`, so the delay timer can auto-advance after the reveal period ends.
- The interval uses `setVolume(0)` rather than truly pausing because real `pause()` causes a 2–3s gap of audible silence that some systems (Samsung MediaSession heuristics, Bluetooth auto-pause, audio focus arbitration, etc.) interpret as "playback should stop", and respond by sending an unsolicited `pause()` → `play()` cycle through the handler. Keeping audio playing inaudibly keeps the audio focus held continuously and avoids those interventions. It also resolves the prior iOS lock-screen "grayed-out play icon" issue since `AVAudioSession` output is never interrupted.
- Edge case: when the last subtitle's `endTime` is within `intervalMs` of the file `duration`, `beginInterval(hardPause: true)` is used — the soft path would let audio reach `ProcessingState.completed` mid-interval and flicker the notification.
- Volume is unconditionally restored to `1.0` whenever exiting the silent interval. Order matters and is **opposite of intuition**: `seek()`, `pause()`, `stop()`, `setAudioSource()` all do their `_audioPlayer` operation **first** and then `setVolume(1.0)`. The reason: during the interval the player position has drifted to `endTime + intervalMs`, which often lands in the middle of the next subtitle. If volume were restored before the seek/pause, the few ms before the audio op took effect would leak that drifted audio at full volume (audible "pop" at the start of the next subtitle). Doing the audio op first lets the buffering / paused window swallow the volume change. The trade-off is losing a tiny amount of new-position content at volume 0 (sub-perceptual). `play()` is the exception — it restores volume *before* `_audioPlayer.play()` because resuming from pause needs volume already at 1 when audio output starts.
- `updateIsPlaying(true)` is called **before** `await _audioPlayer.play()` because just_audio's `play()` is a long-lived Future that only resolves when audio stops — not when it starts.
- On `setAudioSource`, a brief `playing: true` emission to `playbackState` is immediately followed by `_updateMediaControls()` to force Android's foreground service to start (so the notification appears without requiring the user to press play).
- Callbacks (`onSkipToNext`, `onSkipToPrevious`, `cancelTimer`, `updatePlayingStateCallback`) are set by the widget after `AudioService.init()` and cleared in `dispose()`.

**`lib/services/subtitle_parser.dart`** — Parses `.srt` files with auto charset detection (`flutter_charset_detector`). Handles missing sequence numbers, missing blank-line separators, both `,` and `.` as millisecond separators, and HTML tags/entities in subtitle text.

## Subtitle Delay Feature

When `isDelaySubtitleDisplay` is on, each subtitle segment plays hidden. When the audio position reaches the subtitle's `endTime`, `onSubtitleEnd()` calls `beginInterval()` (volume goes to 0; audio keeps streaming silently; `isPlaying` stays `true`), reveals the subtitle in both the UI (`shouldShowSubtitle = true`) and the notification (`updateDisplaySubtitle`), then starts a countdown timer. When the timer fires, `playNextSubtitle()` is called and `seek()` (which restores volume) brings audio to the next subtitle's `startTime`. The notification mirrors this: subtitle text is cleared at segment start and set when revealed.

## Notification

`androidStopForegroundOnPause: false` keeps the notification visible when paused. The notification / iOS lock-screen / Control Center main line is `MediaItem.title` (set to the current subtitle text when revealed, otherwise the filename); the secondary line is `MediaItem.artist` (filename when subtitle is shown, null otherwise). `displayTitle` / `displaySubtitle` are intentionally avoided because they are Android-only — iOS's MPNowPlayingInfoCenter ignores them. The handler keeps `_filename` separately because `title` is overwritten on each subtitle change. Only the play/pause button appears in compact view (`androidCompactActionIndices: [0]`); prev/next are in the expanded view.

## Race Condition Guards

- `_playGeneration` — incremented at the start of every `playAudioFromSubtitle` call. Async continuations check `gen != _playGeneration` to discard stale play chains.
- `_timerGeneration` — incremented on every `cancelSubtitleTimer` call. Timer callbacks compare against this to suppress stale firings.
- `_isSubtitleEndCalled` — prevents the position stream (which fires at high frequency) from triggering `onSubtitleEnd` multiple times for the same subtitle.
