# 听见 (tingjian)

字幕音频播放器，专为听力精听训练设计。

## 主要功能

- 加载本地音频（mp3 / m4a / aac / flac / wav）+ SRT 字幕，单次选择即可
- 按字幕条目逐句导航：上一句 / 下一句 / 单句循环 / 随机播放
- **字幕延迟显示**：播放时隐藏字幕，播完该条字幕的音频后再显示，给定 N 秒后自动跳下一句——专为精听训练设计
- 变速播放（0.5x / 0.75x / 1x / 1.25x / 1.5x / 1.75x / 2x）
- Android 通知栏 / 锁屏控制（播放、上一句、下一句）
- 自动恢复上次会话（音频、字幕、当前位置、所有设置）

## 开发

```bash
# 调试运行
flutter run

# 构建发布 APK
flutter build apk --release

# 静态检查
flutter analyze

# 跑测试
flutter test
```

更多代码层细节见 `CLAUDE.md`。
