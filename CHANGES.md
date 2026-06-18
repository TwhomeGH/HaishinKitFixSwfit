# HaishinKitFixSwfit — 改動說明

本文件記錄相較於上游 [HaishinKit/HaishinKit.swift](https://github.com/HaishinKit/HaishinKit.swift) 的所有修正與增強。

---

## 1. VBR (Variable BitRate) 支援版本修正

**檔案**: `Sources/Codec/VTSessionOptionKey.swift` `Sources/Codec/VideoCodecSettings.swift`

- `kVTCompressionPropertyKey_VariableBitRate` 的 `@available` 從 **iOS 26.0** 下修至 **iOS 13.0**
- 同步修正 `VideoCodecSettings.BitRateMode.variable` 的 availability

> 原因：VBR constant 在 iOS 13 實際上就已存在並可運作，Apple 直到 iOS 26 才正式公開文檔。

---

## 2. 新增 VBV (Video Buffering Verifier) 參數

**檔案**: `Sources/Codec/VTSessionOptionKey.swift` `Sources/Codec/VideoCodecSettings.swift`

新增以下 VideoToolbox 屬性支援：

| 屬性 | 對應 VT Key | iOS Availability |
|---|---|---|
| `vbvMaxBitRate` | `kVTCompressionPropertyKey_VBVMaxBitRate` | iOS 26.0+ |
| `vbvBufferDuration` | `kVTCompressionPropertyKey_VBVBufferDuration` | iOS 26.0+ |
| `vbvInitialDelayPercentage` | `kVTCompressionPropertyKey_VBVInitialDelayPercentage` | iOS 26.0+ |
| `estimatedAverageBytesPerFrame` | `kVTCompressionPropertyKey_EstimatedAverageBytesPerFrame` | iOS 17.0+ |

這些屬性在 `makeOptions()` 和 `apply()` 中都會正確寫入 VTCompressionSession。

---

## 3. 新增 Quality Mode 位元率控制

**檔案**: `Sources/Codec/VideoCodecSettings.swift`

- `BitRateMode` 新增 `.quality` 模式（iOS 8.0+）
- `VideoCodecSettings` 新增 `quality: Float?` 屬性（範圍 0.0 ~ 1.0）
- `.quality` 模式下會設 `kVTCompressionPropertyKey_Quality` 而非 bitrate-based 控制

---

## 4. Adaptive BitRate 策略重寫

**檔案**: `Sources/Stream/StreamBitRateStrategy.swift`

### 4.1 恢復速度加快

- `statusCountsThreshold` 從 **15** 降為 **5** → 只要 5 秒健康就開始回升
- 每次增量從 `mamimumVideoBitRate / 10` 改為 `/ 5` → 每次回升 **20%**

### 4.2 Zero-Byte 時也降 Bitrate

原本 bug：`currentBytesOutPerSecond == 0` 時只降 framerate 不降 bitrate
修正後：每次 zero-byte 事件將 bitrate **砍半**，同時逐步降低 framerate：
- 第 1 次：bitrate / 2 + frameInterval = 30fps
- 第 3 次：bitrate / 2 + frameInterval = ~10fps
- 第 5 次：bitrate / 2 + frameInterval = ~5fps

### 4.3 加入降速冷卻

- `insufficientBWCooldown = 3`：觸發 `publishInsufficientBWOccured` 後，至少要等 3 個 `.status` 事件才能再次降速
- 防止連續擁塞事件把 bitrate 反覆打到地板

### 4.4 Reset 時一併歸零 frameInterval

原本 `reset` 只恢復 bitrate 沒恢復 frameInterval，修正後一併歸零。

---

## 5. NetworkMonitor 佇列擁塞檢測強化

**檔案**: `Sources/Network/NetworkMonitor.swift`

### 5.1 新增絕對佇列大小閾值

- `maxQueueBytesThreshold`（預設 **512 KB**）：當 `queueBytesOut` 超過此值且持續 **2 次**採樣，觸發 `publishInsufficientBWOccured`
- 解決原廠只檢查「佇列是否連續遞增」的盲點：若佇列卡在超高水位但不再成長，原本永遠不會觸發擁塞

### 5.2 方向檢測放寬

原本只有 `total == measureInterval - 1`（即 3 次全部遞增）才觸發
修正改為 `measureInterval - 1 <= total`（2 次以上遞增即觸發），對波動更敏感

---

## 6. RTMPSocket 佇列統計安全

**檔案**: `Sources/Network/RTMPSocket.swift`（無修改，經審查確認安全）

`queueBytesOut` 有 `connected` flag 保護 + actor 隔離，`send()` 在 `.ready` 前不會被執行，統計正確。無需變更。

---

## 7. 移除 Logboard 外部依賴，改用 OSLog

**檔案**: `Package.swift` + 所有 `Constants.swift` + 移除 `import Logboard`

- 原因：Logboard (`shogo4405/Logboard`) 在 Windows 環境下 git checkout 會因檔案路徑包含 `:` 而失敗
- Logboard 內部使用全域 pthread_mutex 保護日誌寫入，高頻 logging 時有鎖競爭
- 每次 log 都會先 evaluate 參數字串拼接再決定是否輸出（無 lazy formatting）
- 改用 Apple 內建 `OSLog.Logger`，零鎖競爭、lazy formatting、支援 Instruments 過濾

---

## 改動檔案總覽

| 檔案 | 修改類型 |
|---|---|
| `Sources/Codec/VTSessionOptionKey.swift` | VBR availability 修正 + 新增 VBV/EstimatedBytes keys |
| `Sources/Codec/VideoCodecSettings.swift` | VBR/Quality availability + 新屬性 + makeOptions/apply 擴充 |
| `Sources/Stream/StreamBitRateStrategy.swift` | ABR 演算法重寫 |
| `Sources/Network/NetworkMonitor.swift` | 佇列擁塞檢測加入絕對閾值 |
| `Package.swift` + 各 module Constants.swift | Logboard → OSLog 遷移 |
