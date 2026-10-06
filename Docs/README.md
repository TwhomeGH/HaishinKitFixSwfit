# HaishinKit.swift 文件

## 概述

HaishinKit.swift 是一套完整的即時串流框架，支援 iOS、macOS、tvOS 與 visionOS。提供多種串流通訊協定支援，包括 RTMP、SRT、WebRTC 與 MoQ（Media over QUIC）。

### 主要功能

- **多通訊協定支援**：RTMP/RTMPS、SRT、WebRTC、MoQ
- **即時影音編碼**：H.264、H.265 (HEVC)、VP9、AV1、AAC、Opus
- **自適應位元率**：依據網路狀況動態調整位元率
- **媒體混合**：多軌影音混合與特效
- **螢幕擷取**：內建螢幕錄製與廣播
- **硬體加速**：VideoToolbox 編解碼

### 支援平台

| 平台 | 最低版本 |
| ------ | ---------- |
| iOS | 15.0+ |
| macOS | 12.0+ |
| tvOS | 15.0+ |
| visionOS | 1.0+ |

### 架構

```text
┌─────────────────────────────────────────────────────────────┐
│                      應用層                                   │
├─────────────────────────────────────────────────────────────┤
│  StreamSession (RTMP/SRT/WebRTC/MoQ)                        │
├─────────────────────────────────────────────────────────────┤
│  MediaMixer → 影音編碼 (VideoToolbox)                        │
├─────────────────────────────────────────────────────────────┤
│  網路層 (NWConnection / Network.framework)                   │
├─────────────────────────────────────────────────────────────┤
│  通訊協定實作 (RTMP Chunking / SRT / WebRTC)                │
└─────────────────────────────────────────────────────────────┘
```

## 模組結構

| 模組 | 說明 |
| ------ | ------ |
| `HaishinKit` | 核心框架：MediaMixer、Codec、Network、Session、Stream |
| `RTMPHaishinKit` | RTMP/RTMPS 通訊協定實作 |
| `SRTHaishinKit` | SRT（Secure Reliable Transport）通訊協定 |
| `RTCHaishinKit` | WebRTC 實作 |
| `MoQTHaishinKit` | Media over QUIC（MoQ）通訊協定 |
| `Examples` | iOS/macOS/tvOS/visionOS 範例應用 |

## 快速開始

### 安裝

**Swift Package Manager：**

```swift
.package(url: "https://github.com/TwhomeGH/HaishinKitFixSwfit.git", branch: "main")
```

或在 Xcode 中：**File → Add Package Dependencies...** → 輸入 `https://github.com/TwhomeGH/HaishinKitFixSwfit.git`

### 基本 RTMP 發布

```swift
import HaishinKit
import RTMPHaishinKit

// 註冊 RTMP factory
await StreamSessionBuilderFactory.shared.register(RTMPSessionFactory())

// 建立 Session
let session = try await StreamSessionBuilderFactory.shared
    .make(URL(string: "rtmp://your-server/live/streamKey")!)
    .setMode(.publish)
    .build()

// 設定視訊編碼
var videoSettings = await session.stream.videoSettings
videoSettings.bitRate = 2_000_000  // 2 Mbps
videoSettings.videoSize = CGSize(width: 1280, height: 720)
try await session.stream.setVideoSettings(videoSettings)

// 開始串流
try await session.connect {
    print("已斷線")
}

// 發布串流
try await session.stream.publish("streamKey")
```

## 文件索引

| 文件 | 說明 |
| ------ | ------ |
| [架構](../HaishinKit/Sources/Docs.docc/ARCHITECTURE.md) | 系統架構與資料流（已移入 DocC） |
| [RTMP 通訊協定](../RTMPHaishinKit/Sources/Docs.docc/RTMP_PROTOCOL.md) | RTMP 實作細節（已移入 DocC） |
| [Composition Time 與 A/V 補償](../RTMPHaishinKit/Sources/Docs.docc/RTMP_COMPOSITION_TIME.md) | CTS（PTS−DTS）在 A/V 偏移補償下的正確性與負 CTS 缺陷（已移入 DocC） |
| [Media Mixer](../HaishinKit/Sources/Docs.docc/MEDIA_MIXER.md) | 影音混合與特效（已移入 DocC） |
| [多軌音訊對齊](../HaishinKit/Sources/Docs.docc/AUDIO_MULTITRACK_ALIGNMENT.md) | ReplayKit 多軌混音跨軌對齊 + NLMS 物理回音消除（已移入 DocC） |
| [音訊管線診斷](../HaishinKit/Sources/Docs.docc/AUDIO_PIPELINE_DIAGNOSTICS.md) | `MediaMixer.audioPipelineDiagnostics()`：align / skip / underrun 累計計數，供 host telemetry（已移入 DocC） |
| [錄影轉送](../HaishinKit/Sources/Docs.docc/RECORDING_FORWARDING.md) | ReplayKit extension 錄影轉送設計：`StreamRecorderSink` + `CMSampleBufferCodec`（B+C 已實作，A/橋待接）（已移入 DocC） |
| [RTMP 恢復生命週期](../RTMPHaishinKit/Sources/Docs.docc/RTMP_RECOVERY_LIFECYCLE.md) | ReplayKit pause/resume、編碼重啟 API、RTMP publish pipeline recovery（已移入 DocC） |
| [多平台邊界設計](../HaishinKit/Sources/Docs.docc/PLATFORM_BOUNDARIES.md) | protocol/facade 分離 iOS、macOS、visionOS 等平台專屬 API 的規範（已移入 DocC） |
| [Session 管理](../HaishinKit/Sources/Docs.docc/SESSION_MANAGEMENT.md) | StreamSession 生命週期（已移入 DocC） |
| [編解碼器設定](../HaishinKit/Sources/Docs.docc/CODEC_CONFIGURATION.md) | 影音編碼設定（已移入 DocC） |
| [網路層](../HaishinKit/Sources/Docs.docc/NETWORK_LAYER.md) | 網路傳輸與監控（已移入 DocC） |
| [開發指南](../HaishinKit/Sources/Docs.docc/DEVELOPMENT_GUIDE.md) | 貢獻與開發環境設定（已移入 DocC） |
| [測試](../HaishinKit/Sources/Docs.docc/TESTING.md) | 測試結構與執行（已移入 DocC） |
| [故障排除](../HaishinKit/Sources/Docs.docc/TROUBLESHOOTING.md) | 常見問題與解決方案（已移入 DocC） |
| [日誌架構](../HaishinKit/Sources/Docs.docc/LOGGING.md) | 遠端日誌：logger 多 handler 並存 + connection.onLog 轉送（已移入 DocC） |
| [TODO / 計畫](TODO.md) | 已規劃未實作項目（目前：RTMP 握手分階段逾時） |

## 相依性

### 系統框架

- `AVFoundation` - 媒體擷取與編碼
- `VideoToolbox` - 硬體視訊編解碼
- `AudioToolbox` - 音訊處理
- `Network` - NWConnection TCP/UDP
- `CoreMedia` - 媒體時間與格式
- `Combine` - 響應式程式設計

### Swift Package 相依性

```swift
// Package.swift
dependencies: [
    // 無外部依賴 - 僅使用 Apple 框架
]
```

## 授權

BSD 3-Clause 授權條款 - 詳見 [LICENSE](../LICENSE.md)
