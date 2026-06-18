# HaishinKitFixSwfit — 修正版

[![GitHub license](https://img.shields.io/badge/License-BSD%203--Clause-blue.svg)](LICENSE.md)

[English](./README.md)

本專案是 [HaishinKit/HaishinKit.swift](https://github.com/HaishinKit/HaishinKit.swift) 的**改良版本**，修復了串流穩定性問題並增強了 bitrate 控制。

## 🔧 與上游的差異

- **VBR 支援版本修正**：`kVTCompressionPropertyKey_VariableBitRate` 從 iOS 13+ 即可使用（上游錯誤限制為 iOS 26+）
- **新增 bitrate 控制模式**：新增 `.quality` 模式、VBV 參數（`vbvMaxBitRate`、`vbvBufferDuration`、`vbvInitialDelayPercentage`）、`estimatedAverageBytesPerFrame`
- **Adaptive BitRate 演算法重寫**：恢復速度加快（5s→20% 而非 15s→10%）、zero-byte 時 bitrate 砍半、加入降速冷卻機制
- **NetworkMonitor 佇列偵測增強**：新增絕對佇列大小閾值（512KB）— 即使佇列不再成長也能偵測持續擁塞
- **移除 Logboard 外部依賴**：改用 Apple 內建 OSLog，消除 git checkout 在 Windows 上的路徑問題
- **RTMP User Control 截斷防 Crash**：收到少於 6 bytes 的 malformed 訊息不再 crash
- **WHEP playback 修復**（共用模組部分）：decode 錯誤 log、DisplayLink frameInterval 修正、MediaLink audio clock 修正

完整改動請見 [CHANGES.md](CHANGES.md)。

## 💬 社群與支援

有問題或建議？歡迎透過以下管道討論：

- **Discord 群組**：https://discord.gg/t8E7MnYeaC
- **Twitch 實況**：https://www.twitch.tv/coffeelatte0709

## 🌏 最低需求

| 版本 | Xcode | Swift |
|:----:|:----:|:----:|
| 2.2.0+ | 26.0+ | 6.0+ |

| iOS | tvOS | Mac Catalyst | macOS | visionOS |
|:-:|:-:|:-:|:-:|:-:|
| 15.0+ | 15.0+ | 15.0+ | 12.0+ | 1.0+ |

## 📖 安裝

### Swift Package Manager

```swift
.package(url: "https://github.com/TwhomeGH/HaishinKitFixSwfit.git", branch: "main")
```

或在 Xcode 中：**File → Add Package Dependencies...** → 輸入 `https://github.com/TwhomeGH/HaishinKitFixSwfit.git`

## 📃 文件

- [API 文件](https://docs.haishinkit.com/swift/latest/documentation/)
- [CHANGES.md](CHANGES.md) — 本 fork 所有改動記錄

## 📜 授權

BSD-3-Clause
