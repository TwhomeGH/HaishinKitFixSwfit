# 編解碼器設定

## 概述

HaishinKit.swift 的編解碼器設定提供彈性的視訊與音訊編碼選項。框架支援多種編解碼格式，具備各種品質等級與位元率。

## 視訊編解碼器

### 支援格式

| 格式 | 說明 |
|------|------|
| H.264 | 先進視訊編碼（AVC） |
| H.265 | 高效視訊編碼（HEVC） |
| VP9 | Google 視訊編碼 |
| AV1 | 開放媒體聯盟編碼 |

### VideoCodecSettings

```swift
public struct VideoCodecSettings {
    public var format: Format
    public var videoSize: CGSize
    public var expectedFrameRate: Float64?
    public var bitRate: Int
    public var bitRateMode: BitRateMode
    public var isLowLatencyRateControlEnabled: Bool
}
```

### Format 列舉

```swift
public enum Format: String, CaseIterable {
    case h264 = "h264"
    case hevc = "hevc"
    case vp9 = "vp9"
    case av1 = "av1"
}
```

## 音訊編解碼器

### 支援格式

| 格式 | 說明 |
|------|------|
| AAC | 先進音訊編碼 |
| Opus | 網際網路音訊編碼 |
| PCM | 脈衝編碼調變 |

### AudioCodecSettings

```swift
public struct AudioCodecSettings {
    public var format: Format
    public var sampleRate: Double
    public var bitRate: Int
    public var isLowLatencyRateControlEnabled: Bool
}
```

### Format 列舉

```swift
public enum Format: String, CaseIterable {
    case aac = "aac"
    case opus = "opus"
    case pcm = "pcm"
}
```

## 位元率控制模式

### BitRateMode

```swift
public enum BitRateMode: String {
    case average = "average"
    case constant = "constant"
    case variable = "variable"
}
```

## 設定參數

### 視訊設定

| 參數 | 預設值 | 說明 |
|------|--------|------|
| `videoSize` | 1280x720 | 解析度 |
| `expectedFrameRate` | 30.0 | 目標 FPS |
| `bitRate` | 2000000 | 位元率（bps） |
| `bitRateMode` | average | 控制模式 |
| `isLowLatencyRateControlEnabled` | false | 低延遲模式 |

### 設定生效與重啟

`setVideoSettings(_:)` 只代表更新 video 設定，不等於手動恢復或強制重建整條發送管線。
底層會依設定差異決定是否 invalidate encoder session；相同設定不會被當成 recovery。

若上層是在直播中更正解析度、profile、reordering、codec fallback 等需要新 encoder session
才可靠生效的配置，建議模式是：

```swift
var settings = await stream.videoSettings
settings.videoSize = CGSize(width: 1280, height: 720)
settings.profileLevel = kVTProfileLevel_H264_High_AutoLevel as String
try await stream.setVideoSettings(settings)

await stream.restartVideoEncoding(reason: "video settings updated")
```

bitrate 類調整通常可由現有 session 動態套用，不應高頻搭配 `restartVideoEncoding(reason:)`。
RTMP 發布時，`restartVideoEncoding(reason:)` 會重接 publish tasks 與 codec output stream；
完整 lifecycle 設計見 [RTMP 恢復生命週期](RTMP_RECOVERY_LIFECYCLE.md)。

### 音訊設定

| 參數 | 預設值 | 說明 |
|------|--------|------|
| `sampleRate` | 44100.0 | 音訊取樣率 |
| `bitRate` | 128000 | 位元率（bps） |
| `isLowLatencyRateControlEnabled` | false | 低延遲模式 |

### AAC 推薦策略

`AudioCodecSettings` 提供兩組 AAC 推薦值，語意不同：

| API | 取向 | 格式 | Bitrate | 適用情境 |
|-----|------|------|---------|----------|
| `bestAacFormat` / `bestAacBitrate` | 裝置支援與低碼率效率優先 | HE-AAC v2 → HE-AAC v1 → AAC LC | 48k / 72k / 128k | 明確想省頻寬、且下游確認支援 HE-AAC 的情境 |
| `recommendedRtmpFormat` / `recommendedRtmpBitrate` | RTMP/FLV 相容性優先 | AAC LC | 128k | RTMP 推流、回放錄檔、需要廣泛播放器相容的預設 |

RTMP/FLV 的保守預設建議：

```swift
var audioSettings = await stream.audioSettings
audioSettings.format = AudioCodecSettings.recommendedRtmpFormat
audioSettings.bitRate = AudioCodecSettings.recommendedRtmpBitrate
try await stream.setAudioSettings(audioSettings)
```

若只是調整 audio bitrate，通常可動態套用，不需要重啟 audio pipeline。若改的是
`format`、`channelMap` 或需要重建 converter 的配置，且目前正在發布，應在
`setAudioSettings(_:)` 後搭配：

```swift
await stream.restartAudioEncoding(reason: "audio settings updated")
```

## 編解碼器特定設定

### H.264 設定

```swift
// 使用 VideoToolbox H.264 編碼器
// 支援 baseline、main、high profiles
```

### H.265 設定

```swift
// 使用 VideoToolbox HEVC 編碼器
// 支援各種 HEVC profiles
```

### AAC 設定

```swift
// 使用 AudioToolbox AAC 編碼器
// 支援各種 AAC profiles
```

### Opus 設定

```swift
// 使用 AudioToolbox Opus 編碼器
// 支援低延遲、高品質模式
```

## 程式碼參考

- VideoCodecSettings.swift：視訊編碼設定
- AudioCodecSettings.swift：音訊編碼設定
- Codec.swift：編解碼器基礎實作
- VideoToolboxCodec.swift：硬體視訊編碼
- AudioToolboxCodec.swift：硬體音訊編碼
