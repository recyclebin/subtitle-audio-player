# 听见 (tingjian)

字幕音频播放器，专为听力精听训练设计。Android / iOS 双端支持。

## 主要功能

- 加载本地音频（mp3 / m4a / aac / flac / wav）+ SRT 字幕，单次选择即可
- 按字幕条目逐句导航：上一句 / 下一句 / 单句循环 / 随机播放
- **播放间隔**：每句播完自动暂停 0.5–5 秒（步进 0.5）后跳下一句；可选「播放间隔显示字幕」——开启时仅在间隔时显示字幕，关闭时全程显示，专为精听训练设计
- 变速播放（0.5x / 0.75x / 1x / 1.25x / 1.5x / 1.75x / 2x）
- **AI 发音评估**：基于 Azure Speech SDK 逐词评分，支持音素级 IPA 标注。跟读模式（双击录音按钮进入）自动连续评估并跳下一句；手动模式单次录音评估。支持中文（普通话）、日本語、한국어、ไทย、English、Français、Español、Português 及自动语种检测
- **评估历史**：按文件分组保存历次评估记录，均分汇总一目了然，支持一键清空
- 系统媒体控件：Android 通知栏、iOS 锁屏 / 控制中心 Now Playing（播放、上一句、下一句、当前字幕显示）
- 自动恢复上次会话（音频、字幕、当前位置、所有设置，含 Azure 凭据）

## 开发

```bash
# 调试运行（自动选已连接设备 / 模拟器）
flutter run

# 构建发布版
flutter build apk --release   # Android
flutter build ipa --release   # iOS（需 macOS + Xcode + 开发者签名）

# 静态检查
flutter analyze

# 跑测试
flutter test
```

## 发音评估配置

发音评估需要 Azure Speech Services 订阅。在 Azure Portal 创建「语音服务」资源后获取**密钥**和**区域**，在 app 中的「更多 → Azure 设置」填入即可。未配置时录音按钮置灰不可用。

支持语种：中文（普通话）、日本語、한국어、ไทย、English、Français、Español、Português。加载字幕文件时自动检测语种，也可在语言选择器中手动指定。

> 仅 `en-US`（美式英语）支持音素级 IPA 音标标注，其他语种展示逐音素得分圆圈。

更多代码层细节见 `CLAUDE.md`。
