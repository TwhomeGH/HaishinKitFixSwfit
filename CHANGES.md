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

---

## 11. 底層設計問題修復

### 11.1 `maxKeyFrameIntervalDuration` 無法動態更新

**檔案**: `Sources/Codec/VideoCodecSettings.swift`

`invalidateSession()` 原本把 `maxKeyFrameIntervalDuration` 列為需要重建 session 的條件之一，但 `apply()` 卻沒有對應的動態更新邏輯。

後果：
- 改 `maxKeyFrameIntervalDuration` 會觸發 `invalidateSession` → 砍掉整個 VTCompressionSession 重建
- 重建期間 encoder 無法處理 frame，造成短暫斷流
- 如果 encoder 沒收到 frame 就不會觸發 rebuild，改值永遠不生效

修法：
- 從 `invalidateSession()` 中移除 `maxKeyFrameIntervalDuration`
- 在 `apply()` 中加入 `VTSessionSetProperty` 直接對執行中的 session 下指令（VideoToolbox 支援 runtime 更改此屬性）

### 11.2 `videoInputBufferCounts` 預設 unbounded + computed property 設計缺陷

**檔案**: `Sources/Stream/OutgoingStream.swift`

```swift
// ❌ computed property，每次 access 都 new 一個 AsyncStream
package var videoInputStream: AsyncStream<CMSampleBuffer> {
    if 0 < videoInputBufferCounts {
        return AsyncStream(..., bufferingPolicy: .bufferingNewest(videoInputBufferCounts)) { ... }
    } else {
        return AsyncStream { ... }  // unbounded!
    }
}
```

三個問題：

1. **預設值 `-1` 進入 unbounded 分支** — encoder 跟不上時 frame 無限累積在 AsyncStream buffer，記憶體暴漲、latency 無限增加
2. **computed property 每次 access 建立新 Stream** — 雖然 `videoInputContinuation.didSet` 會 `oldValue?.finish()`，但如果 reconnect 時有 race condition，中間的 frame 全部遺失
3. **`setVideoInputBufferCounts` 只能在 publish 前生效** — publish 時 `for await` 只 access `videoInputStream` 一次建立 AsyncStream，之後再改 count 不影響已存在的 stream

修法：
- 預設值改為 `5`，使用 `.bufferingNewest(5)`，避免 unbounded 累積
- `setVideoInputBufferCounts` 仍應在 publish 前呼叫

### 11.3 `CMVideoFormatDescription.configurationBox` 無 fallback

**檔案**: `Sources/Extension/CMVideoFormatDescription+Extension.swift`（兩個 module 各有一個）

原本實作只從 `kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms` extension dictionary 撈 `avcC`/`hvcC`：
- 如果 format description 沒有此 extension → 回 nil
- 如果 format description 是 H.264/H.265 但不包含 atoms → 回 nil

後果：`RTMPVideoMessage(streamId:timestamp:formatDescription:)` 在 `didSet` 中因 `configurationBox` 為 nil 而回傳 nil，sequence header **從未送出**。RTMP receiver 收不到 AVCDecoderConfigurationRecord，無法解碼任何視訊幀，表現為全黑畫面或串流 0x0。

修法：
- 原本的 extension atoms 查詢保留為優先路徑
- 撈不到時啟用 fallback：`CMVideoFormatDescriptionGetH264ParameterSetAtIndex` 直接取出 SPS/PPS NAL units
- 手動組合 `AVCDecoderConfigurationRecord`，透過其 `data` getter 產生正確的 avcC box
- HEVC 路徑暫回 nil（待補）

### 11.4 `makeFormatDescription()` 陣列越界 crash

**檔案**: 
- `Sources/Codec/AVCDecoderConfigurationRecord.swift:46`
- `Sources/Codec/HEVCDecoderConfigurationRecord.swift:35`

```swift
// ❌ pictureParameterSets / sequenceParameterSets 為空時直接 crash
return pictureParameterSets[0].withUnsafeBytes { ... }
```

當 `init(data:)` 收到空或格式錯誤的二進位資料時，`sequenceParameterSets`、`pictureParameterSets`、或 `array[.vps/sps/pps]` 保持空陣列。`makeFormatDescription()` 直接 index `[0]` 導致 Swift bounds check SIGTRAP。

修法：在索引前 `guard !array.isEmpty`。

### 11.5 隱患觀察：Pipeline 跨多層 AsyncStream，每層獨立 buffer

完整視訊路徑 chain：

```
MediaMixer.append() → VideoCaptureUnit → VideoMixer
  → _output.yield()  (AsyncStream #1)
  → MediaMixer startRunning Task #2
  → RTMPStream.mixer(_:didOutput:) 
  → mixerVideoContinuation.yield() (AsyncStream #2)
  → RTMPStream consumer → append(sampleBuffer) 
  → outgoing.append(sampleBuffer)
  → videoInputContinuation.yield() (AsyncStream #3)
  → OutgoingStream consumer → append(video:)
  → VideoCodec.append() → VTCompressionSessionEncodeFrame
  → outputHandler yield() (AsyncStream #4)
  → outgoing.videoOutputStream consumer → append(video)
  → RTMPVideoMessage → doOutput()
```

**三層中間 AsyncStream**（`_output`、`mixerVideoContinuation`、`videoInputStream`）各自有獨立 buffering policy，encoder 端沒有背壓機制傳回 source。當 encoder 跟不上時，frame 堆在 `videoInputStream` 的 buffer 裡而非在 source 端丟棄，導致延遲持續增加。

短期內 `videoInputBufferCounts` 限制 buffer 大小（`.bufferingNewest` 丟棄最舊幀）已可控制，長期應考慮合併 Stream 層數或導入 actor-based backpressure。

---

## 12. 支援語音通話（Voice Chat）與直播共存

**新增檔案**: `Sources/Mixer/AudioRouteManager.swift`
**修改檔案**: `Sources/Mixer/MediaMixer.swift`

### 背景

當直播中需要同時進行語音通話（例如 LINE 通話或自建 VoIP）時，存在兩個衝突：

1. **AVAudioSession Category 衝突** — 串流 mic 需要 `.playAndRecord`，但預設會 duck 其他 app 音訊
2. **音源衝突** — ReplayKit 的 `.audioMic` 與 AVAudioEngine 的 mic tap 會產生雙重音訊

### 實作方式

#### `AudioRouteManager`（iOS 限定）

- **AVAudioSession** 設定為 `.playAndRecord` + `.voiceChat` mode + `.mixWithOthers` + `.allowBluetooth` + `.defaultToSpeaker` + `.allowAirPlay`
  - 保證 mic 可錄音
  - 不中斷背景音樂或其他 app 音訊
  - 通話聲音走揚聲器而非聽筒
- **AVAudioEngine** 啟動後在 `inputNode` 上安裝 tap
  - tap callback 定期提供 `AVAudioPCMBuffer`
  - 透過 `Task { await mixer.append(buffer, when:) }` 餵入現有 audio pipeline
  - 沿用原本的 `AudioCaptureUnit` → `AudioMixer` → `AudioCodec` → RTMP 路徑，不需改寫編碼邏輯

#### `MediaMixer.setVoiceChatEnabled(_:)`

```swift
// 啟用：語音通話 + 直播共存
try mixer.setVoiceChatEnabled(true)

// 停用：恢復純直播模式
mixer.setVoiceChatEnabled(false)
```

- 啟用時自動設定 AVAudioSession 並啟動 AVAudioEngine tap
- 停用時停止 engine、移除以 tap、恢復 AVAudioSession category 為 `.playback` + `.mixWithOthers`
- `stopRunning()` 時自動 deactivate，避免 resource leak

### 注意事項（App 層需處理）

1. **ReplayKit mic 雙重來源** — 啟用 voice chat 時，app 應關閉 `RPScreenRecorder.isMicrophoneEnabled = false`，只讓 ReplayKit 提供 `.audioApp`，mic 由 AVAudioEngine 負責
2. **通話音訊回放** — `voiceChat` mode 只處理 mic 上鏈，下鏈（聽對方的聲音）由 app 自行管理（e.g. `AVAudioEngine` mixer node 或 system audio unit）
3. **Bluetooth 相容** — `.allowBluetooth` 保證藍牙耳機的 mic 可用於通話

---

## 改動檔案總覽（追加）

| 檔案 | 修改類型 |
|---|---|
| `Sources/Codec/VideoCodecSettings.swift` | `maxKeyFrameIntervalDuration` 動態 apply；自 `invalidateSession()` 移除 |
| `Sources/Stream/OutgoingStream.swift` | `videoInputBufferCounts` 預設值 -1 → 5 |
| `Sources/Extension/CMVideoFormatDescription+Extension.swift`（RTMP） | `configurationBox` 加入 AVC fallback |
| `Sources/Codec/AVCDecoderConfigurationRecord.swift` | `makeFormatDescription()` 防陣列越界 |
| `Sources/Codec/HEVCDecoderConfigurationRecord.swift` | `makeFormatDescription()` 防陣列越界 |
| `Sources/Mixer/AudioRouteManager.swift` | **新增** — AVAudioSession + AVAudioEngine 管理 |
| `Sources/Mixer/MediaMixer.swift` | 新增 `setVoiceChatEnabled(_:)`、`audioRouteManager` 屬性 |
