# Pronunciation Assessment — Design Spec

## Overview

为播放器添加语音识别 + 发音评估功能。用户跟读字幕文本，App 录音并调用 Azure Pronunciation Assessment API，返回词级别和音素级别的发音得分，与原文比对展示。

## Decisions

| 维度 | 决定 |
|------|------|
| 引擎 | Azure Pronunciation Assessment |
| 评估粒度 | 词级（准确度 + 漏读/多读）+ 音素级（每个音素得分） |
| 语言 | 多语言（Azure 原生覆盖） |
| 触发模式 | 双模式：暂停后读 / 跟读 |
| 历史记录 | JSONL 本地存储，按文件/时间回顾 |
| 录音保留 | 评估完即丢弃 |

## New Files

```
lib/
  services/
    pronunciation_service.dart          # Azure SDK 封装，录音 + 评估 + 解析
    assessment_history_service.dart     # JSONL 历史记录读写
  models/
    assessment_result.dart              # AssessmentResult / WordResult / PhonemeResult
  widgets/
    pronunciation_overlay.dart          # 录音按钮 + 波形 + 倒计时
    pronunciation_score_card.dart       # 评估结果 BottomSheet（词级高亮 + 可展开音素）
    history_list_view.dart              # 历史回顾页面
```

## Modified Files

| 文件 | 改动 |
|------|------|
| `lib/main.dart` | 初始化 `PronunciationService`，传递至 UI |
| `lib/widgets/player_screen.dart` | 字幕区域加录音入口、快捷菜单加历史入口 |

## Data Models

```dart
class AssessmentResult {
  final String referenceText;
  final String recognizedText;
  final double overallScore;         // 0–100
  final List<WordResult> words;
}

class WordResult {
  final String word;
  final String? recognizedWord;
  final double accuracyScore;        // 0–100
  final bool isOmission;
  final bool isInsertion;
  final List<PhonemeResult> phonemes;
}

class PhonemeResult {
  final String phoneme;
  final double score;
}
```

## PronunciationService

- 封装 Azure Speech SDK：`SpeechConfig` + `PronunciationAssessmentConfig`
- `startAssessment(String referenceText, AssessmentMode mode)` → 根据 mode 决定是否 pause 音频 → 开麦克风录音
- `stopAssessment()` → 停止录音 → 推送 buffer 给 Azure → 解析 JSON 返回 `AssessmentResult`
- 解析 Azure 返回的 NBest JSON，提取 Word + Phoneme 评分子结构
- `dispose()` → 释放 SDK 资源

## AssessmentHistoryService

- 存储格式：JSONL（每行一条 `AssessmentRecord`），按天分文件
- `AssessmentRecord` 字段：`AssessmentResult` + 文件路径 + 时间戳 + 字幕索引
- 用 `path_provider` 获取 app data 目录，`dart:convert` 序列化
- 提供按文件分组、按时间倒序的查询接口

## UI Flow

```
录音入口（字幕区域旁按钮）
  → 点击 → 显示录音 UI（波形 + 倒计时）
  → 用户读完 / 手动停止
  → 恢复音频（如果是暂停模式）
  → Loading
  → BottomSheet 弹出：
      总体得分（大字）
      原文逐词高亮（绿 ≥80 / 黄 50–79 / 红 <50）
      [展开音素详情] 默认折叠
  → 关闭 → 结果写入 JSONL 历史

历史入口（ActionItem 行）
  → 新页面 HistoryListView
  → 按文件分组，按时间倒序
  → 点击条目可重新打开对应 ScoreCard
```

## Error Handling

- Azure API 调用失败 → 提示 "评估失败，请检查网络"
- 麦克风权限未授权 → 引导用户去设置开启
- 录音时间过短（<1s）→ 提示 "录音太短，请重试"
- 未检测到有效语音 → 提示 "未识别到语音，请重试"
