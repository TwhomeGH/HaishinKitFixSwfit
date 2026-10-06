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

### 線上 API 文件（DocC）

已發佈於 GitHub Pages；各篇可從對應模組頁的 Topics 進入：

- [HaishinKit](https://twhomegh.github.io/HaishinKitFixSwfit/HaishinKit/documentation/haishinkit/)：
  架構、Session 管理、網路層、日誌架構、故障排除、多平台邊界、開發指南、測試、MediaMixer、
  編解碼器設定、多軌音訊對齊、音訊管線診斷、錄影轉送、AudioHE-AAC、影片管線診斷、影像佇列診斷、
  ABR 壅塞設計。
- [RTMPHaishinKit](https://twhomegh.github.io/HaishinKitFixSwfit/RTMPHaishinKit/documentation/rtmphaishinkit/)：
  RTMP 協定、Composition Time 與 A/V 補償、恢復生命週期、傳送診斷、連線診斷、H.264 恢復。
- [SRTHaishinKit](https://twhomegh.github.io/HaishinKitFixSwfit/SRTHaishinKit/documentation/srthaishinkit/) ·
  [RTCHaishinKit](https://twhomegh.github.io/HaishinKitFixSwfit/RTCHaishinKit/documentation/rtchaishinkit/) ·
  [MoQTHaishinKit](https://twhomegh.github.io/HaishinKitFixSwfit/MoQTHaishinKit/documentation/moqthaishinkit/)

### 內部文件（Docs/）

| 文件 | 說明 |
| ------ | ------ |
| [TODO / 計畫](TODO.md) | 已規劃未實作項目 |
| [API 文件中文化與首頁維護](DOCUMENTATION_CHINESE.md) | 中文化範圍、首頁產生與驗證 |
| [資料路徑設計問題](DATA_PATH_DESIGN_ISSUES.md) | 資料路徑設計問題與影響 |
| [RTMP Socket 設計](RTMP_SOCKET_DESIGN.md) | RTMP Socket 底層設計缺陷分析 |
| [RTMP Socket 修正記錄](CHANGELOG_RTMP_SOCKET.md) | RTMP Socket 修正記錄 |
| [RTMP 修復與架構](RTMP_FIXES.md) | RTMP 協議修復與架構改進 |
| [輸出管線重構](OUTGOING_PIPELINE_REDESIGN.md) | RTMP 輸出管線重構：TaskGroup 架構 |
| [NWConnection 遞迴](nw-recursion.md) | NWConnection 遞迴 receive 模式 |
| [yield 鏈 stack overflow](yield-chain-stack-overflow.md) | AsyncStream yield() 同步鏈造成 stack overflow |
| [doOutput yield 鏈修復](dooutput-yield-chain-fix.md) | doOutput yield 鏈 stack overflow 修復與重構 |
| [泛型特化遞迴](generic-specialization-recursion.md) | 泛型特化遞迴（ExpressibleByIntegerLiteral） |

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
