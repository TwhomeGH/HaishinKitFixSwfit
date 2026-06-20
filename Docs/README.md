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
|------|----------|
| iOS | 15.0+ |
| macOS | 12.0+ |
| tvOS | 15.0+ |
| visionOS | 1.0+ |

### 架構

```
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
|------|------|
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
dependencies: [
    .package(url: "https://github.com/shogo4405/HaishinKit.swift", from: "1.0.0")
]
```

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
|------|------|
| [架構](ARCHITECTURE.md) | 系統架構與資料流 |
| [RTMP 通訊協定](RTMP_PROTOCOL.md) | RTMP 實作細節 |
| [Media Mixer](MEDIA_MIXER.md) | 影音混合與特效 |
| [Session 管理](SESSION_MANAGEMENT.md) | StreamSession 生命週期 |
| [編解碼器設定](CODEC_CONFIGURATION.md) | 影音編碼設定 |
| [網路層](NETWORK_LAYER.md) | 網路傳輸與監控 |
| [開發指南](DEVELOPMENT_GUIDE.md) | 貢獻與開發環境設定 |
| [測試](TESTING.md) | 測試結構與執行 |
| [故障排除](TROUBLESHOOTING.md) | 常見問題與解決方案 |

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