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

The app has three Dart source files:

**`lib/main.dart`** — The entire UI and playback coordination layer. `TingjianAppState` owns all application state: subtitle list, current index, play mode flags (`isRandomPlay`, `isLoopSingle`, `isDelaySubtitleDisplay`), playback speed, and the subtitle delay timer. It drives the `MyAudioHandler` and reacts to position updates via `positionStream`.

**`lib/background_audio_task.dart`** — `MyAudioHandler` extends `BaseAudioHandler` from `audio_service`. It wraps `just_audio`'s `AudioPlayer` and bridges it to the Android media notification. Key design points:
- `isPlaying` in the handler reflects *user intent* (not actual audio output). `realPause()` pauses audio without clearing `isPlaying`, so the delay timer can auto-advance after the subtitle reveal period ends.
- Known platform inconsistency during the play interval: iOS lock-screen / Control Center renders a grayed-out, non-clickable play icon, while Android shows an active pause button. iOS Now Playing infers play/pause state from observed AVAudioSession output (not just `MPNowPlayingPlaybackState`), so calling `_audioPlayer.pause()` flips the icon to play; combined with us only registering `MediaControl.pause` (no `playCommand`), it appears disabled. Accepted as a minor UX tradeoff rather than introducing a `setVolume(0)` workaround.
- `updateIsPlaying(true)` is called **before** `await _audioPlayer.play()` because just_audio's `play()` is a long-lived Future that only resolves when audio stops — not when it starts.
- On `setAudioSource`, a brief `playing: true` emission to `playbackState` is immediately followed by `_updateMediaControls()` to force Android's foreground service to start (so the notification appears without requiring the user to press play).
- Callbacks (`onSkipToNext`, `onSkipToPrevious`, `cancelTimer`, `updatePlayingStateCallback`) are set by the widget after `AudioService.init()` and cleared in `dispose()`.

**`lib/subtitle_parser.dart`** — Parses `.srt` files with auto charset detection (`flutter_charset_detector`). Handles missing sequence numbers, missing blank-line separators, both `,` and `.` as millisecond separators, and HTML tags/entities in subtitle text.

## Subtitle Delay Feature

When `isDelaySubtitleDisplay` is on, each subtitle segment plays hidden. When the audio position reaches the subtitle's `endTime`, `onSubtitleEnd()` calls `realPause()` (audio pauses, `isPlaying` stays `true`), reveals the subtitle in both the UI (`shouldShowSubtitle = true`) and the notification (`updateDisplaySubtitle`), then starts a countdown timer. When the timer fires, `playNextSubtitle()` is called. The notification mirrors this: subtitle text is cleared at segment start and set when revealed.

## Notification

`androidStopForegroundOnPause: false` keeps the notification visible when paused. The notification / iOS lock-screen / Control Center main line is `MediaItem.title` (set to the current subtitle text when revealed, otherwise the filename); the secondary line is `MediaItem.artist` (filename when subtitle is shown, null otherwise). `displayTitle` / `displaySubtitle` are intentionally avoided because they are Android-only — iOS's MPNowPlayingInfoCenter ignores them. The handler keeps `_filename` separately because `title` is overwritten on each subtitle change. Only the play/pause button appears in compact view (`androidCompactActionIndices: [0]`); prev/next are in the expanded view.

## Race Condition Guards

- `_playGeneration` — incremented at the start of every `playAudioFromSubtitle` call. Async continuations check `gen != _playGeneration` to discard stale play chains.
- `_timerGeneration` — incremented on every `cancelSubtitleTimer` call. Timer callbacks compare against this to suppress stale firings.
- `_isSubtitleEndCalled` — prevents the position stream (which fires at high frequency) from triggering `onSubtitleEnd` multiple times for the same subtitle.
