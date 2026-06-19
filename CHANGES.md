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
| `Sources/Codec/VTDecompressionSession+Extension.swift` | decode 失敗 log（throttled） |
| `Sources/Screen/DisplayLinkChoreographer.swift` | macOS frameInterval=0 時 fallback |
| `Sources/Stream/MediaLink.swift` | audio clock 僅在 advancing 時使用 |
| `Sources/RTMP/RTMPMessage.swift` | truncated RTMP User Control 防 crash |

---

## 8. Port: 截斷 RTMP User Control 訊息防 Crash

**對應上游 PR**: [#1922](https://github.com/HaishinKit/HaishinKit.swift/pull/1922)

**檔案**: `Sources/RTMP/RTMPMessage.swift`

`RTMPUserControlMessage.init` 原本直接取 `header.payload[1]` 和 `payload[2..<count]` 不做長度檢查。收到少於 6 bytes（2-byte event + 4-byte value）的 malformed 訊息時，Swift bounds check 直接 SIGTRAP，crash 整個 process。

### 修法
- `Data(header.payload)` 先轉成 0-based copy（Data slice 保留 parent 的 indexing offset）
- `guard 6 <= payload.count` 長度不足直接回 `.unknown` / `0`
- 正常訊息行為不變

---

## 9. 修復 RTMP Chunk `.two` Header 寫入範圍錯誤

**檔案**: `Sources/RTMP/RTMPChunk.swift:305`

```swift
// ❌ ClosedRange — 4 bytes 範圍但只寫入 3 bytes，第 4 byte 保留舊資料
data.replaceSubrange(position...position + 3, with: message.timestamp.bigEndian.data[1...3])
// ✅ Half-open range — 精準 3 bytes
data.replaceSubrange(position..<position + 3, with: message.timestamp.bigEndian.data[1...3])
```

`.zero` 與 `.one` chunk type 正確使用 `..<` half-open range，唯獨 `.two` 誤用 `...` ClosedRange。第一個 `.two` chunk 送出後下一個 chunk 的 basic header 被污染，串流資料從該點開始損毀，造成部分 RTMP 伺服器斷流。

---

## 10. E-RTMP 參數改為不預設送出

**檔案**: `Sources/RTMP/RTMPConnection.swift:261-263`

```swift
// ❌ 預設送出 fourCcList / videoFourCcInfoMap / audioFourCcInfoMap
fourCcList: [String]? = RTMPConnection.supportedFourCcList,
// ✅ 改為 nil，只有明確傳入時才送
fourCcList: [String]? = nil,
```

建制 `RTMPConnection()` 時 `fourCcList` / `videoFourCcInfoMap` / `audioFourCcInfoMap` 預設值自非 nil 改為 `nil`，connect command 中只有非 nil 時才加入。避免不支援 Enhanced RTMP 的伺服器因收到未知欄位而拒絕連線。
