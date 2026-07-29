# HaishinKitFixSwfit — 改動說明

本文件記錄相較於上游 [HaishinKit/HaishinKit.swift](https://github.com/HaishinKit/HaishinKit.swift) 的所有修正與增強。

---

## 1. VBR (Variable BitRate) 支援修正與 Bug 修復

**檔案**: `Sources/Codec/VTSessionOptionKey.swift` `Sources/Codec/VideoCodecSettings.swift`

### Availability 修正
- `kVTCompressionPropertyKey_VariableBitRate` 的 `@available` 從 **iOS 26.0** 下修至 **iOS 13.0**
- 同步修正 `VideoCodecSettings.BitRateMode.variable` 的 availability

> 原因：VBR constant 在 iOS 13 實際上就已存在並可運作，Apple 直到 iOS 26 才正式公開文檔。

### Bug 修復：`VariableBitRate` 屬性值型別錯誤

**問題**：`makeOptions()` 與 `apply()` 將 `bitRate`（整數）直接傳入 `kVTCompressionPropertyKey_VariableBitRate`。但此屬性是 `CFBoolean` 開關（enable/disable），應傳入 `kCFBooleanTrue` 而非數值。

後果：
- `.variable` 模式下 `kVTCompressionPropertyKey_AverageBitRate` 從未被設定，encoder 沒有目標碼率
- 即使 VBV 參數正確，VBR 也無法正常運作

**修復**：
- `makeOptions()` 與 `apply()` 中，`.variable` 模式改以 `.averageBitRate` key 傳入 `bitRate` 數值（作為目標碼率）
- `.variable` 模式額外插入 `VariableBitRate = kCFBooleanTrue` 啟用 VBR

```swift
// ❌ 原本：VariableBitRate = NSNumber(bitRate) — 型別錯誤
.init(key: .variableBitRate, value: NSNumber(value: bitRate))

// ✅ 修正後：AverageBitRate = bitRate（目標碼率）+ VariableBitRate = true（啟用 VBR）
.init(key: .averageBitRate, value: NSNumber(value: bitRate))
// ... 並在 options 中加入：
options.insert(.init(key: .variableBitRate, value: kCFBooleanTrue))
```

**生效條件**：所有使用 `bitRateMode = .variable` 的情境。

### VBR 模式改進：自動套用資料率限制

**檔案**: `Sources/Codec/VideoCodecSettings.swift`

#### 改動

1. **`dataRateLimits` 延伸至 VBR 模式**（`makeOptions()` + `apply()`）
   - 原本 `.variable` 模式完全跳過 `dataRateLimits` 設定，encoder 無軟上限
   - 現在 `.variable` 與 `.average` 共用同一套 `dataRateLimits` 邏輯：
     - 自動值：`bitRate / 8 * 1.5` bytes/s，1 秒窗口（即 1.5× bitrate 軟上限）
     - 使用者可手動設定自訂值
   - 此保護在所有 iOS 版本上皆有效

2. **`vbvMaxBitRate` / `vbvBufferDuration` 自動計算**（`makeOptions()`）
   - VBR 模式下若使用者未指定，自動設 `vbvMaxBitRate = bitRate * 12/10`、`vbvBufferDuration = 1.0`
   - 集中於 iOS 26.0+ 的 `#available` 區塊內，與其他 VBV 參數一起管理

3. **`apply()` bitrate 變更路徑同步更新限制**
   - VBR bitrate 變更時重新計算 `dataRateLimits` 寫入 VT session
   - iOS 26.0+ 自動補上 `vbvMaxBitRate` / `vbvBufferDuration`（當使用者未自訂時）

#### 原因

VBR 模式下 encoder 為了畫質可瞬間暴衝遠超過 `bitRate`。若缺乏 `dataRateLimits`（軟上限），這些大 frame 會塞爆 RTMP output queue，觸發 `publishInsufficientBWOccured`，導致 bitrate 死亡螺旋。`dataRateLimits` 提供 1.5× 軟上限約束，在**所有 iOS 版本**上防止 encoder 暴衝。

#### 生效條件

- `bitRateMode == .variable`
- `dataRateLimits`：**所有 iOS 版本**
- `vbvMaxBitRate` / `vbvBufferDuration`：iOS 26.0+ / tvOS 26.0+ / macOS 26.0+

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
修正後：每次 zero-byte 事件將 bitrate **砍半**

### 4.3 加入降速冷卻

- `insufficientBWCooldown = 3`：觸發 `publishInsufficientBWOccured` 後，至少要等 3 個 `.status` 事件才能再次降速
- 防止連續擁塞事件把 bitrate 反覆打到地板

### 4.4 Reset 時一併歸零 frameInterval

原本 `reset` 只恢復 bitrate 沒恢復 frameInterval，修正後一併歸零。

### 4.5 移除 zeroBytesOutPerSecondCounts 與 frameInterval 干預

**問題**：`publishInsufficientBWOccured` 路徑中，`zeroBytesOutPerSecondCounts` 只增不減，用來逐步降低 frameInterval（30fps → 10fps → 5fps 鋸齒狀循環）。這會讓 encoder 的 frameInterval 突然跳變，導致輸出幀率不穩定、PTS 抖動，表現為畫面頓挫（PPT）。

**修正**：
- 移除 `zeroBytesOutPerSecondCounts` 屬性與所有引用
- 移除 `publishInsufficientBWOccured` 中對 `frameInterval` 的全部寫入
- 移除除法遞減 `Int(...) / (zeroBytesOutPerSecondCounts + 1)`，改為直接使用 raw throughput
- 策略現在只調整 `bitRate`，不干預 encoder 幀間隔

**效果**：
- 消除因 frameInterval 跳變造成的幀率抖動
- bitrate 計算不再受不準確的計數器干擾
- 單一關注點：ABR 只負責碼率，幀率控制回歸 encoder 自主決策

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
| `Sources/Codec/VTSessionMode.swift` | HEVC profile fallback 機制；`makeSession()` 重構 |
| `RTMPHaishinKit/Sources/Extension/CMVideoFormatDescription+Extension.swift` | `makeHEVCConfigurationBox()` 實作（iOS 13+ `parameterSets`） |
| `RTMPHaishinKit/Sources/Codec/HEVCDecoderConfigurationRecord.swift` | `data` getter 完整序列化修復 |
| `RTMPHaishinKit/Sources/RTMP/RTMPFoundation.swift` | 新增 `RTMPVideoCodec.hevc = 12` |
| `RTMPHaishinKit/Sources/RTMP/RTMPMessage.swift` | HEVC 改用 CodecID=12 Legacy 格式；`isSupported`/`makeFormatDescription` 相容修復 |
| `RTMPHaishinKit/Sources/RTMP/RTMPConnection.swift` | 新增 `serverSupportedVideoCodecs` 與 connect response 解析 |
| `RTMPHaishinKit/Sources/RTMP/RTMPStream.swift` | 新增 `ensureVideoCodecSupported(by:)`；追加 `import VideoToolbox` |
| `HaishinKit/Sources/Codec/VideoCodecSettings.swift` | 新增 `frameInterval60` 常數 |
| `HaishinKit/Sources/Codec/AudioCodecSettings.swift` | 新增 `.heAac`/`.heAacV2` 格式、`bestAacFormat`、`isDeviceSupported` |
| `HaishinKit/Sources/Codec/AudioCodec.swift` | 改進 audio format log |
| `HaishinKit/Sources/ISO/AudioSpecificConfig.swift` | 新增 `.aacPs = 29`、`AudioObjectType` 支援未知 rawValue |
| `RTMPHaishinKit/Sources/RTMP/RTMPEnhanced.swift` | `codecid` 延伸 `.heAac`/`.heAacV2` |
| `RTMPHaishinKit/Sources/RTMP/RTMPMessage.swift` | RTMPAudioMessage 新增 AAC type log |
| `Sources/Mixer/AudioRouteManager.swift` | **新增** — AVAudioSession + AVAudioEngine 管理 |
| `Sources/Mixer/MediaMixer.swift` | 新增 `setVoiceChatEnabled(_:)`、`audioRouteManager` 屬性 |

---

## 13. AudioRouteManager 修復與完善

**檔案**: `Sources/Mixer/AudioRouteManager.swift`

### 13.1 `String.hasExtension` 編譯錯誤誤修復

```swift
// ❌ String 無 hasExtension method
if Bundle.main.bundlePath.hasExtension("appex") { ... }

// ✅ 使用 NSString.pathExtension
if (Bundle.main.bundlePath as NSString).pathExtension == "appex" { ... }
```

### 13.2 AVAudioSession Category 選項衝突修復

`.voiceChat` mode 與 `[.defaultToSpeaker, .allowAirPlay]` 組合會導致錯誤。
修正為最小相容組合：`[.mixWithOthers, .allowBluetooth, .allowBluetoothA2DP]`

### 13.3 App Extension 崩潰防護

Extension (`.appex` bundle) 無法呼叫 `setCategory()` / `setActive()`，會直接 crash。
加入早期返回，Extension 模式下跳過所有 audio session 操作。

### 13.4 `deactivate()` 音頻會話正確清理

原本：直接改 category 再 `setActive(true)`，且 `try?` 吞錯
修正：
```swift
try? session.setActive(false, options: .notifyOthersOnDeactivation)  // 先停用、通知其他 app
try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])  // 改回播放類別
try? session.setActive(true)  // 重新啟用 app 自己的會話
```

### 13.5 `activate()` 重啟時清理舊狀態

重複啟用時會殘留舊 tap、engine running 狀態。開頭加入 `stopEngine()` 確保乾淨重啟。

---

## 14. 關鍵修復：AVAudioTime PTS 損壞導致音視頻不同步

**檔案**: `Sources/Mixer/AudioRouteManager.swift:43`

### 問題

```swift
// ❌ tap callback 的 time 已包含正確 sampleTime、sampleRate、hostTime
// 卻只取 hostTime 重建，導致 sampleTime=0, sampleRate=0
await mixer.append(buffer, when: AVAudioTime(hostTime: time.hostTime))
```

這導致 `AudioTime.anchor(_ time: AVAudioTime)` 初始化時：
- `sampleRate = 0`
- `sampleTime = 0`
- PTS 從 0 開始計算

而 video `CMSampleBuffer` 使用真實 `presentationTimeStamp`，兩者永遠對不上，表現為推流無聲、或音視頻嚴重不同步。

### 修復

```swift
// ✅ 直接傳遞完整的 time（已含 sampleTime、sampleRate、hostTime）
await mixer.append(buffer, when: time)
```

### 影響範圍

- 所有經由 `AudioRouteManager`（voice chat mic tap）輸入的音訊
- ReplayKit `.audioApp` / `.audioMic` 走 `CMSampleBuffer` 路徑**不受影響**
- 修復後 audio PTS 與 video PTS 同一時間基準，AV sync 正常

---

## 15. 關鍵修復：Keyframe Interval 底層約束不足

**檔案**:
- `HaishinKit/Sources/Codec/VideoCodecSettings.swift`
- `HaishinKit/Sources/Codec/VideoCodec.swift`
- `HaishinKit/Sources/Codec/VTSessionConvertible.swift`
- `HaishinKit/Sources/Extension/VTCompressionSession+Extension.swift`
- `HaishinKit/Sources/Extension/VTDecompressionSession+Extension.swift`
- `HaishinKit/Tests/Codec/VideoCodecSettingsTests.swift`

### 問題

原本只設定 `kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration`（秒數），部分 VideoToolbox encoder / 硬體路徑可能沒有穩定依照秒數產生 keyframe，導致實際 GOP 漂移，例如觀察到約 5 秒 keyframe interval。

### 修復

- 保留既有 `maxKeyFrameIntervalDuration` API 語意。
- 同步派生並設定 `kVTCompressionPropertyKey_MaxKeyFrameInterval`（幀數）。
- 建立 session 與動態更新 settings 時都會重新套用 keyframe interval options。
- 在 compression path 加入 `ForceKeyFrame` 支援。
- 第一幀與超過 `maxKeyFrameIntervalDuration` 時主動要求 keyframe，避免只依賴 encoder 自行排程。
- 新增測試覆蓋預設 30fps、指定 23fps、降幀 frameInterval、停用幀數限制等情境。

### 影響範圍

- H.264 / HEVC 透過 VideoToolbox compression 的輸出。
- ReplayKit、RTMP、SRT、RTC 等走未壓縮 video sample 再編碼的路徑。
- 對已壓縮 video passthrough 路徑不主動改寫 keyframe。

---

## 16. 性能修復：Video Input Buffer 改為有界佇列

**檔案**:
- `HaishinKit/Sources/Stream/OutgoingStream.swift`
- `HaishinKit/Sources/Stream/StreamConvertible.swift`
- `RTMPHaishinKit/Sources/RTMP/RTMPStream.swift`
- `SRTHaishinKit/Sources/SRT/SRTStream.swift`

### 問題

`setVideoInputBufferCounts(0)` 或負數時，`OutgoingStream.videoInputStream` 會退回無限制 `AsyncStream`。當 ReplayKit / camera 持續送 frame，但 encoder、actor 或網路輸出變慢時，video frame 可能在記憶體中持續堆積，造成延遲上升、記憶體壓力，嚴重時表現為卡死。

此外，RTMP / SRT 的 `MediaMixer -> Stream` video 中轉佇列原本也是 unbounded，壓力可能在進入 `OutgoingStream` 前就先累積。

### 修復

- `videoInputBufferCounts` 最小值 clamp 到 `1`。
- `OutgoingStream.videoInputStream` 永遠使用 `.bufferingNewest(videoInputBufferCounts)`。
- `StreamConvertible.setVideoInputBufferCounts(_:)` 同步 clamp，避免公開 API 傳入非法值。
- RTMP / SRT 的 mixer video 中轉 `AsyncStream` 改為 `.bufferingNewest(outgoing.videoInputBufferCounts)`。

### 行為變更

- 過載時會丟棄舊 video frame，保留最新 frame，以維持直播低延遲。
- 不再支援 video input unbounded queue。
- 音訊 queue 未在本次改動中改為 bounded，避免語音通話或直播音訊被主動丟 sample。


## 17. RTMP 底層 Socket缺陷/性能問題

[**改動說明 CHANGES**](./Docs/CHANGELOG_RTMP_SOCKET.md)

---

## 18. 移除無效的 AudioRouteManager / Voice Chat 功能

**檔案**:
- `Sources/Mixer/AudioRouteManager.swift` — 已刪除
- `Sources/Mixer/MediaMixer.swift` — 移除 `setVoiceChatEnabled()`, `audioRouteManager` 屬性與 `deactivate()` 呼叫

### 刪除內容
1. 整個 `AudioRouteManager` class（AVAudioEngine tap 擷取麥克風）
2. `MediaMixer.audioRouteManager` 延遲屬性
3. `MediaMixer.setVoiceChatEnabled()` 公開方法
4. `stopRunning()` 中的 `audioRouteManager.deactivate()` 呼叫

### 原因
`AudioRouteManager` 在 Broadcast Extension 中完全無效：
- AVAudioSession category 無法在 extension 設定，方法直接跳過無作用
- AVAudioEngine 無法在 extension 正常啟動 input tap
- 與 `RPScreenRecorder.isMicrophoneEnabled = false` 搭配會導致麥克風音訊完全靜音

### 替代方案
直接使用 ReplayKit 提供的 `.audioMic` / `.audioApp` buffer，透過 `AudioMixer` 混合兩軌，已由 `AudioProcessor` 實作。

---

## 19. VideoCaptureUnit AsyncStream 改為有界佇列

**檔案**: `Sources/Mixer/VideoCaptureUnit.swift`

### 改動
- `inputs` AsyncStream: `.unbounded` → `.bufferingNewest(30)`
- `output` AsyncStream: `.unbounded` → `.bufferingNewest(30)`

### 原因
原本的 unbounded 策略會讓 frame 在 consumer 慢的時候無限堆積，導致記憶體膨脹及關閉時暴衝 flush。改成保留最新 30 幀，自動丟棄舊幀，符合直播低延遲需求。

---

## 20. 修復 RTMP `createStream` 回應被忽略導致推流管線未建立

**檔案**:
- `RTMPHaishinKit/Sources/RTMP/RTMPConnection.swift`
- `Docs/RTMP_SOCKET_DESIGN.md`

### 問題

RTMP connect 成功後，`RTMPConnection` 會從 `.handshakeDone` 轉成 `.connected`。但 `listen(_:)` 原本只在 `.handshakeDone` 狀態解析收到的 RTMP chunks；進入 `.connected` 後，socket 收到的 server 回包會直接落入 `default: break`。

因此 `createStream` command 已送出並註冊 transaction：

```text
[RTMP] debug Command sent cmd=createStream txn=2
```

但 server 回來的 `_result txn=2` 不會被解析，最後 timeout：

```text
[RTMP] error Command timeout cmd=createStream txn=2
[RTMP] error createStream: failed requestTimedOut
[RTMP] error publish: stream id is 0 after createStream
```

### 修正

`listen(_:)` 改為在 `.handshakeDone` 與 `.connected` 狀態都持續解析 RTMP chunks：

```swift
case .handshakeDone, .connected:
```

### 效果

- `createStream` 的 `_result` 可正常 dispatch 到 pending operation。
- `RTMPStream` 能取得非 0 stream id。
- publish 管線可繼續送 metadata、sequence header、audio/video messages。

---

## 21. 修復推流中途 `videoFrame = 0` 的編碼輸出停滯

**檔案**:
- `RTMPHaishinKit/Sources/RTMP/RTMPStream.swift`
- `HaishinKit/Sources/Stream/OutgoingStream.swift`

### 問題

log 顯示 RTMP 連線與音訊仍持續工作，但 publish throughput 連續出現：

```text
videoFrames=0 videoBytes=0
```

同時前段仍有 `[VFrame]`、`[VideoProcessor] 送出MediaMixer`。這代表 ReplayKit 與 video processor 沒有停止，真正停住的是 video codec 到 RTMP 的 encoded video 輸出，不是 socket 斷線。

### 修正

- `RTMPStream` 新增 `videoInputFrames` 與 `videoStallCount`。
- status 週期中若正在 publishing、video input 有進來，但 encoded `videoFrames` 連續 3 次為 0，會重啟 video publish pipeline。
- `OutgoingStream` 新增 `restartVideoCodec()`，讓 RTMP 層可以停止並重新啟動 video codec。
- 重啟時會清除 `videoFormat`，讓後續 video sequence header 可重新送出。

### 效果

推流中途若 video encoder/output path 停住，系統可以自動復原，避免畫面永久黑掉但音訊仍繼續送出的狀態。

---

## 22. 改善 RTMP Socket 發送效能與佇列統計

**檔案**:
- `RTMPHaishinKit/Sources/RTMP/RTMPSocket.swift`
- `Docs/RTMP_SOCKET_DESIGN.md`
- `Docs/CHANGELOG_RTMP_SOCKET.md`

### 問題

RTMP message 會被切成多個 chunk。原本 socket 層逐 chunk enqueue，導致大型 video frame 或 keyframe 會放大成大量 `NWConnection.send` operation。

另外，佇列統計存在幾個問題：

- backpressure 只檢查目前 `queueBytesOut`，沒有檢查加入本次資料後是否超標。
- `AsyncStream.yield` 被 drop 或 terminated 時沒有回補 `queueBytesOut`。
- `totalBytesOut` 在 enqueue 與實際 send 完成時都累加，throughput 可能 double count。

### 修正

- `send(_ chunks:)` 與 `send(_ iterator:)` 先合併 payload，再 enqueue 一次。
- 新增共用 `enqueue(_:)`，集中處理 connected、backpressure、yield result 與 log。
- backpressure 改為 `queueBytesOut + data.count <= maxQueueBytesOut`。
- `totalBytesOut` 只在 `NWConnection.send` 完成後累加。
- `recv()` 改為 `minimumIncompleteLength: 1`，避免空 read 路徑。

### 效果

- 降低 keyframe 期間的 actor hop / AsyncStream enqueue / NWConnection callback 次數。
- queue 與 throughput log 更接近實際網路送出狀態。
- 高碼率推流時 socket 層負載更穩定。

---

## 15. createStream 重試與錯誤傳播機制

**檔案**: `Sources/RTMP/RTMPStream.swift`, `Sources/RTMP/RTMPConnection.swift`

### 問題

`createStream()` 存在三個設計缺陷：

1. **錯誤被吞掉**：catch 後僅 `logger.error()`，不回報給呼叫方。`publish()` 只能看到 `id == 0`，無法區分 timeout、server 回空值、或其他原因。
2. **無重試機制**：`requestTimeout` (3s) 一過就永久失敗。若 RTMP server 短暫無回應（實際發生於內網 server），即使 txn=1 connect 已成功，txn=2 createStream 仍可能 timeout，導致推流完全失敗。
3. **log 誤導**：失敗後仍打 `"publish: stream created id=0"`，但 stream 根本沒建立。

### 修正

- **`createStream()` 變為 `async throws`**：錯誤不再被吞掉，向上拋給 playback/publish/reconnect 處理。
- **內建重試邏輯**：預設重試 3 次，每次間隔 500ms。可透過 `retryCount` 參數調整。
- **每次失敗 via onLog**：`connection?.log(.error, ...)` 記錄嘗試次數與錯誤細節。
- **呼叫方清理**：`publish()` / `play()` 移除多餘的 `guard id != defaultID` 檢查，直接依賴 `createStream()` 拋錯。
- **重連路徑**：`RTMPConnection` 的 `startReconnection()` 中 `createStream()` 失敗會觸發整次重連重試（由既有 `do-catch` 捕獲）。

### 效果

- RTMP server 短暫無回應時不再直接失敗，給予 3 次機會（總計 ~4.5s）。
- 錯誤細節完整傳播至 `onLog`，便於診斷。
- 重連時 createStream 失敗不會跳過該 stream（由重連迴圈重試）。

---

## 23. StreamVideoAdaptiveBitRateStrategy 自動推導 VBV 約束

**檔案**: `Sources/Stream/StreamBitRateStrategy.swift`

### 改動

ABR 策略每次調整 `bitRate` 時，在 iOS 26.0+ 且 `bitRateMode == .variable` 的條件下，自動推導並設定 `vbvMaxBitRate`：

```swift
settings.vbvMaxBitRate = settings.bitRate * 12 / 10  // 允許 20% 瞬間超標
```

三個路徑（`.status` 回升、`.publishInsufficientBWOccured` 降速、`.reset` 復原）都會同步更新。

### 原因

VBR 模式下 encoder 在複雜場景可能瞬間噴出遠高於目標 `bitRate` 的碼率。若接收端 buffer 小，可能造成卡頓或丟幀。VBV 約束確保瞬間峰值不超過目標的 120%。

### 生效條件

- iOS 26.0+ / tvOS 26.0+ / macOS 26.0+
- `bitRateMode == .variable`
- 低於 iOS 26 的裝置改由 `dataRateLimits` 提供 1.5× 軟上限保護（所有版本皆支援）

---

## 24. 改進斷線後無法重連的防護與可觀測性

**檔案**: `Sources/Stream/StreamReadyState.swift`, `RTMPHaishinKit/Sources/RTMP/RTMPStream.swift`

### Video Stall 增加預警

`dispatch(.status)` 檢測到 `frameCount == 0` 持續 2 秒時先出 `.warn` 預警，第 3 秒才觸發 `restartVideoPipeline`：

```swift
if 2 == videoStallCount {
    await connection?.log(.warn, "video stall detected, will restart pipeline",
        detail: "stallCount=\(videoStallCount)")
}
```

### restartVideoPipeline 加入連線檢查

觸發前檢查 `connection?.connected == true`：
- 若 socket 已斷 → 跳過 restart（讓 reconnection 機制處理），出 `.warn` 說明原因
- 若 socket 正常 → 照常執行

### resumePublishing 加入連線與狀態檢查

原本 `resumePublishing` 只在 `readyState == .idle` 時靜默跳過，現在：
- `readyState != .idle` → `.warn` 記錄當前 state
- `connection?.connected == false` → `.warn` 記錄連線已斷
- `publish()` 失敗 → 透過 `connection?.log(.error, ...)` 輸出（原本只用 `logger.error`）

### StreamReadyState 加入 CustomStringConvertible

讓 `.warn` log 中印出 `idle` / `publishing` 等可讀字串，而非 raw integer。

### 效果

- 斷線後 `restartVideoPipeline` 不會再與 reconnection 互相干擾
- 管理者可在 onLog 收到 `.warn` / `.error` 訊息診斷斷線原因
- `resumePublishing` 失敗不再靜默吞錯

---

## 25. RTMPSocket 發送路徑重寫——消除雙層 AsyncStream + Write-Combining

**檔案**: `Sources/RTMP/RTMPSocket.swift`

### 原本問題

send 路徑存在兩層獨立的 AsyncStream：

```
RTMPConnection.startOutputConsumer
  → AsyncStream #1 (bufferingOldest 512) → consumer Task → socket.send(data)
    → RTMPSocket.enqueue 
      → AsyncStream #2 (bufferingOldest 256) → consumer Task → NWConnection.send
```

每個 RTMP chunk 經歷：
1. actor hop 進 `RTMPSocket`
2. `AsyncStream.yield()` 排入內部佇列
3. consumer Task 喚醒 (`for await`)
4. `withCheckedThrowingContinuation` 橋接
5. `NWConnection.send` 送出
6. callback 觸發 resume continuation

Keyframe 可拆成上百個 chunk → 上百次上述循環，actor hop、task context switch、continuation bridge 的累積開銷可觀。

### 修正

**移除 `RTMPSocket` 內部的 AsyncStream 與 consumer Task**，改用 Write-Combining buffer：

```swift
private var sendBuffer = Data()
private var isSending = false

func send(_ data: Data) {
    // ... backpressure / connected guards ...
    sendBuffer.append(data)
    queueBytesOut += data.count
    if !isSending {
        flushSendBuffer()
    }
}

private func flushSendBuffer() {
    let data = sendBuffer
    sendBuffer.removeAll(keepingCapacity: true)
    isSending = true
    connection.send(content: data, completion: .contentProcessed { error in
        Task { await self.didSend(data, error: error) }
    })
}

private func didSend(_ data: Data, error: Error?) {
    totalBytesOut += data.count
    queueBytesOut = max(0, queueBytesOut - data.count)
    isSending = false
    if !sendBuffer.isEmpty {
        flushSendBuffer()   // 發送期間累積的資料合併成下一包
    }
    if let error { close(error as? NWError) }
}
```

### 行為

- **Write-Combining**：`NWConnection.send` 還在進行時，後續到達的 chunk 自動累積在 `sendBuffer`。完成回呼檢查 buffer，非空則一次 flush 全部
- **零 latency 增加**：沒有定時器。空閒時 chunk 立刻 flush；高吞吐時自動批次
- **不再有 AsyncStream/yield/consumer Task 開銷**：資料從 RTMPConnection 的 output AsyncStream 直接進 buffer → `NWConnection.send`

### 效果

- 高碼率推流時 `NWConnection.send` 呼叫次數從 **chunk 數**降到 **並行 send 批次數**（通常減少 10~50 倍）
- 消除 consumer Task 的 `for await` context switch
- 消除 `withCheckedThrowingContinuation` per-chunk 橋接
- 低碼率 / 音訊 chunk 行為不變（立刻送出）

---

## 26. HEVC Profile 自動降階（Fallback）機制

**檔案**:
- `Sources/Codec/VideoCodecSettings.swift`
- `Sources/Codec/VTSessionMode.swift`

### 問題

HEVC 編碼需要硬體支援特定的 profile level：
- **Main** — A9+（iPhone 6s 以上）
- **Main10**（10-bit）— A12+（iPhone XS 以上）
- **Main42210**（4:2:2 10-bit）— A13+（iPhone 11 以上）

當 `profileLevel` 設為裝置不支援的 HEVC profile（例如在 A11 裝置上設 `Main10_AutoLevel`），`VTCompressionSession` 建立或 `VTSessionSetProperty` 會直接失敗。原先的錯誤被 `catch` 吞掉後只出 warn log，session 保持 nil，後續所有 video frame 都被丟棄 — 表現為 HEVC 完全無法工作。

### 修復

1. **`VideoCodecSettings.hevcProfileTiers`** — 定義 HEVC profile 由高至低的階層
2. **`VideoCodecSettings.hevcFallbackChain(for:)`** — 根據使用者請求的 profile 回傳降階鏈（例如 `Main42210` → `Main10` → `Main`）
3. **`VTSessionMode.makeSession()`** — HEVC 格式時依序嘗試降階鏈中的每個 profile，直到其中一個成功建立 session

```swift
// 使用者請求 Main10，A11 裝置不支援 → 自動降階至 Main
let chain = VideoCodecSettings.hevcFallbackChain(for: "HEVC_Main10_AutoLevel")
// → ["HEVC_Main10_AutoLevel", "HEVC_Main_AutoLevel"]
```

### 行為

- 成功降階時以 `logger.info` 記錄實際使用的 profile
- 所有 profile 都失敗則拋出最後一個錯誤
- H.264 路徑不受影響（維持原有行為）
- 不影響 `profileLevel` 屬性的值，僅在 session 建立時覆寫 VT option

---

## 27. E-RTMP HEVC 修復：HEVC Sequence Header 無法送出

**檔案**:
- `RTMPHaishinKit/Sources/Extension/CMVideoFormatDescription+Extension.swift`
- `RTMPHaishinKit/Sources/Codec/HEVCDecoderConfigurationRecord.swift`

### 問題：`makeHEVCConfigurationBox()` 為空 stub

HEVC Encoder 輸出 `CMSampleBuffer` 時，VT 的 format description **不一定**包含 `hvcC` extension atom。此時 `configurationBox` 走 fallback 路徑 `makeHEVCConfigurationBox()`，但該函數直接 `return nil`。

後果：
- `RTMPVideoMessage(streamId:timestamp:formatDescription:)` 因 `configurationBox` 為 nil → 建構子回傳 nil
- HEVC **sequence header 從未送出**
- receiver 收不到 `HEVCDecoderConfigurationRecord`，無法解碼任何 HEVC 幀
- 表現為全黑畫面或串流無效

### 問題：`HEVCDecoderConfigurationRecord.data` getter 不完整

寫入序列化時僅寫 `configurationVersion`（1 byte），其餘 20+ 個欄位以及 VPS/SPS/PPS NALU array 全部遺失。
影響：
- `makeHEVCConfigurationBox()` 即使正確建構 record，呼叫 `record.data` 回傳的資料也無法被 decoder 解析
- 任何重新序列化 HEVC config record 的情境（parse-then-write）都會產出損毀輸出

### 修復

**`HEVCDecoderConfigurationRecord.data`** — 完整實作 serialization，順序與欄位對應 ISO/IEC 14496-15 8.3.3.1.2：

```
configurationVersion          (1 byte)
general_profile_space/tier/idc (1 byte, packed)
general_profile_compatibility  (4 bytes)
general_constraint_indicator   (6 bytes: UI32 + UI16)
general_level_idc              (1 byte)
min_spatial_segmentation_idc   (2 bytes, lower 12 bits)
parallelismType                (1 byte, lower 2 bits)
chromaFormat                   (1 byte, lower 2 bits)
bitDepthLumaMinus8             (1 byte, lower 3 bits)
bitDepthChromaMinus8           (1 byte, lower 3 bits)
avgFrameRate                   (2 bytes)
constantFrameRate + temporal   (1 byte, packed)
numOfArrays                    (1 byte)
[
  nalUnitType | 0xC0           (1 byte)
  numNalus                      (2 bytes)
  [nalUnitLength + nalUnitData] (repeated per NALU)
] (repeated per array entry)
```

**`makeHEVCConfigurationBox()`** — 使用 `CMFormatDescription.parameterSets`（iOS 13+）提取 VPS/SPS/PPS，填入 `HEVCDecoderConfigurationRecord` 後回傳 `record.data`。

```swift
// 遍歷 parameterSets 中的每個 NAL unit data：
// 根據 HEVC NAL unit header 的 nal_unit_type 分類後填入 record.array
```

### 行為

- 優先路徑（format description 有 `hvcC` extension atom）不變
- Fallback 路徑現在正確產生 hvcC box
- 需要 iOS 13+（使用 `CMFormatDescription.parameterSets` 屬性，無版本疑慮）

### `RTMPVideoMessage` HEVC 封包格式修正

**問題**: HEVC 影片封包使用 E-RTMP v2 ExVideoHeader 格式（`0x80 | frameType<<4 | packetType` + FourCC `hvc1`），但 SRS 5.x / Oryx 5 只支援 CodecID=12 的 Legacy 擴展格式。

**症狀**: SRS 5 回 `drop unknown header video, bytes[0]=0xa1` — 因為 ExVideoHeader 的 bit 7 (isExHeader=1) 讓 legacy FrameType 檢查（預期 1-5）失敗。

**修復**: HEVC 改用 CodecID=12 的 Legacy 擴展格式（與 AVC 相同結構）：
```
Byte 0: FrameType(4) | CodecID(12 = 0x0C)
Byte 1: PacketType (0=seq, 1=nal)
Bytes 2-4: CompositionTime (SI24)
Data: hvcC box / HEVC NALUs
```

同時 `RTMPVideoMessage.isSupported` 與 `makeFormatDescription()` 增加 CodecID=12 的判斷路徑，確保接收端也能正確解析兩種格式。

### `frameInterval60` 新增

補上缺少的 60fps 對應常數：

```swift
public static let frameInterval60 = (1 / 60) - 0.001
```

---

## 28. Server Codec Capability 偵測與自動降級

**檔案**:
- `RTMPHaishinKit/Sources/RTMP/RTMPConnection.swift`
- `RTMPHaishinKit/Sources/RTMP/RTMPStream.swift`

### 問題

當 client 設定 HEVC 編碼推流時，若目標 server（如 Twitch）不支援 HEVC，會因為 server 無法解碼而導致連線異常或串流不可播放。原本 library 完全沒有檢查 server 端是否支援所選 codec。

### 修復

**`RTMPConnection.serverSupportedVideoCodecs`** — connect 回應自動解析 server 的 `videoFourCcInfoMap`：

```swift
// 儲存 server 宣告支援的 video codec FourCC 集合
public private(set) var serverSupportedVideoCodecs: Set<String> = []
```

`_result` 處理時從 AMF response 的 `videoFourCcInfoMap` 物件提取 key（如 `hvc1`、`av01`、`vp09`），僅保留 `canDecode` 旗標（value & 0x02 != 0）的 codec。

不支援時出 warn log：
```
[WARN] Server does NOT support HEVC/hvc1, will fallback to H.264
```

**`RTMPStream.ensureVideoCodecSupported(by:)`** — 提供流層自動降級方法：

```swift
@discardableResult
public func ensureVideoCodecSupported(by connection: RTMPConnection) async -> Bool
```

- 檢查 `connection.serverSupportedVideoCodecs` 是否包含 `hvc1`
- 若不包含且當前設定為 `.hevc` → 自動切換為 `.h264`，profile 設 `High_AutoLevel`
- 回傳 `false` 表示發生降級

### 使用方式

在 connect 成功後呼叫：

```swift
if let conn = rtmpConnection {
    let supported = await rtmpStream.ensureVideoCodecSupported(by: conn)
    if !supported {
        RPConfig.shared.state.videoCodec = "H264"
        await applyAllVideoSettings(width: width, height: height)
    }
}
```

---

## 29. HE-AAC v1/v2 支援與自動降級

**檔案**:
- `HaishinKit/Sources/Codec/AudioCodecSettings.swift`
- `HaishinKit/Sources/ISO/AudioSpecificConfig.swift`
- `HaishinKit/Sources/Codec/AudioCodec.swift`
- `RTMPHaishinKit/Sources/RTMP/RTMPEnhanced.swift`
- `RTMPHaishinKit/Sources/RTMP/RTMPMessage.swift`

### 新增格式

`AudioCodecSettings.Format` 新增兩種高效 AAC 格式：

| 格式 | CoreAudio FormatID | AudioObjectType | 說明 |
|---|---|---|---|
| `.aac` | `kAudioFormatMPEG4AAC` | 2 (AAC LC) | 標準 AAC |
| `.heAac` | `kAudioFormatMPEG4AAC_HE` | 5 (SBR) | HE-AAC v1 (AAC+SBR) |
| `.heAacV2` | `kAudioFormatMPEG4AAC_HE_V2` | 29 (PS) | HE-AAC v2 (AAC+SBR+PS) |

### Device 支援偵測（三層檢測）

`AudioCodecSettings.Format.isDeviceSupported` 依序嘗試三種方式檢查 HE-AAC 是否可用：

1. **iOS 17+** → `AVAudioApplication.shared.supportedAudioFormats`
2. **Fallback** → `AVAudioSession.sharedInstance().availableEncoders`
3. **最後防線** → `AudioConverterNew` 使用 **stereo (2ch) + 44.1kHz** 測試編碼器是否回應 `noErr`

```swift
package static func isAacFormatSupported(_ formatID: AudioFormatID) -> Bool {
    if #available(iOS 17.0, tvOS 17.0, macOS 14.0, watchOS 10.0, *) {
        return AVAudioApplication.shared.supportedAudioFormats.contains { $0.formatID == formatID }
    }
    if AVAudioSession.sharedInstance().availableEncoders.contains(where: { $0.formatID == formatID }) {
        return true
    }
    // AudioConverterNew with 2ch stereo test
    ...
}
```

> 原本用 mono (1ch) + `mFramesPerPacket: 1024` 測試，HE-AAC 需要 stereo 才能啟用，所以一直回 false。

### 自動降級鏈

`AudioCodecSettings.bestAacFormat` 依序嘗試 `heAacV2 → heAac → aac`，只回傳 device 真正支援的格式：

```swift
public static var bestAacFormat: Format {
    for format in preferredAacFormats {
        if format.isDeviceSupported { return format }
    }
    return .aac
}
```

### RTMP 相容性

HE-AAC v1/v2 在 RTMP 中使用與 AAC 相同的 CodecID (10)，差異僅在 AudioSpecificConfig 中的 `AudioObjectType`。接收端會自動根據 ASC 判斷實際格式。

### Log 輸出

- `AudioCodec` 建立 converter 時輸出 `audio: format=HE-AAC v2 (AAC+SBR+PS) input=... output=...`
- `RTMPAudioMessage` 送出 sequence header 時輸出 `audio: AAC sequence header type=29 freq=... ch=...`

---

## 30. VIDEO/AUDIO 管線傳遞設計修正

詳細設計與架構說明請見 [Docs/OUTGOING_PIPELINE_REDESIGN.md#9-管線傳遞設計修正2026-07-月](Docs/OUTGOING_PIPELINE_REDESIGN.md#9-管線傳遞設計修正2026-07-月)。

- 移除 `RTMPConnection.outputContinuation` bound → `.bufferingNewest(256)`（有限 latency）
- 新增 `MediaMixerOutputBridge` — 消除 `nonisolated(unsafe)` + 每幀 `Task{}`
- `DispatchQueue` pacing — 消除 frame burst 造成撕裂
- Byte-based buffer 控制 — `maxVideoBufferBytes` + 自動計算幀數
- Audio stall 檢測 — `restartAudioPipeline()` 對稱 video
- `setVideoInputBufferCounts(-1)` 支援自動模式
- `maxFrameDelayCount` — 限制 VT 內部 buffer，減少 live latency
- `adaptiveFrameThrottle` 改用雙重檢測：`numberOfPendingFrames`（支援時）+ encode 速率 fallback（實際編碼 < 25fps 時降頻），解決部分裝置 pending frames 不可靠問題
- `allowTemporalCompression` 可設 `false` — 防止 VT 因壓力主動丟幀
- `dataRateLimits` VBR 模式自動啟用（不再依賴使用者設定），防止 bitrate 暴衝
- A/V sync on restart — pipeline 重啟後同步 audio/video 時間戳，防止音畫不同步
- `RTMPTimestamp.invalidSequence` 不再 throw → resync 取代 silent drop，消除 DTS 空洞
- `VideoCodec` 錯誤自動 session recovery + progressive backoff（VT 失敗後逐步降 fps）
- `h264EntropyMode` — 可設 `"cavlc"` 降低 VT GPU 負載，throttle 觸發時自動切換
- 移除 `videoDecodeOrder` — CTO 改用 `videoTimestamp.updatedAt`（DTS），消除 DTS/PTS 反轉
- `checkFrameRate()` 自鎖修復 — throttled 時不再觸發降頻
- `MediaMixerOutputBridge.finish()` 同步化 — 避免 pipeline restart 時 DispatchQueue 非同步造成 continuation race → 12 秒卡死

## 31. adaptiveFrameThrottle 重新設計（漸進式 throttle）

**檔案：** `HaishinKit/Sources/Codec/VideoCodec.swift`

**問題：** 舊設計觸發時直接 60→30 腰斬，僅有兩種狀態；仰賴 `inputTimestamps`/`encodeTimestamps` 等 4 個追蹤變數；`applyCavlcIfNeeded()` 切換 CAVLC 後永不恢復，品質永久降級；`checkFrameRate()` 捆綁 encode 速率回退路徑過於間接。

**修改：**
- **移除** `setProportionalThrottle()`、`checkFrameRate()`、`applyCavlcIfNeeded()` 與相關 4 個狀態變數
- **新 `updateAdaptiveFrameInterval()`**：
  - 降速：`numberOfPendingFrames > threshold` 時每次 drop 15%（60→51→43→...），間隔至少 500ms，下限 15fps
  - 恢復：連續 30 次 clear check 後升 10%，接近 60fps 時完全歸零
  - 僅 `clearStreak` + `lastThrottleTime` 兩個狀態變數
- CAVLC 不再自動切換，留給用戶自行設定 `h264EntropyMode`
- Encoder error backoff 簡化（`clearStreak` 歸零 + fps 對半降）

**預設保持 `false`** — 實驗性功能，用戶可透過 `setReconnectEnabled` 或建構子啟用。

### `maxFrameDelayCount` 自動計算支援

**用途：** 控制 VT 編碼器內部佇列可暫存多少幀再開始丟幀。設越小則 live latency 越低（encoder 不會囤積太多未編碼幀），但 encoder 來不及處理時會直接丟幀。適合直播場景建議設 `2`，預設 `nil` 由 VT 自行決定。

**`nil` / `≤0` 自動計算：** 當 `maxFrameDelayCount` 未設定或設為 ≤0（含 `-1`）時，VT 端不設此屬性（使用 VT 預設），throttle threshold 改為自動推導：

```
threshold = ceil(expectedFrameRate / 12)
```

| expectedFrameRate | threshold | 等於多少 ms 緩衝 |
|---|---|---|
| 60 | 5 | ~83ms |
| 30 | 3 | ~100ms |
| 24 | 2 | ~83ms |
| nil（預設） | 5 | 同 60fps |

手動設正數（如 `2`）則 VT 和 throttle 都使用該值。

### 新增 VT 效能調節參數：`PrioritizeEncodingSpeedOverQuality` + `ReferenceBufferCount`

**檔案：** `HaishinKit/Sources/Codec/VTSessionOptionKey.swift`, `VideoCodecSettings.swift`

**用途：** 提供更細粒度的 GPU/CPU 與壓縮效率取捨控制，搭配 `h264EntropyMode` (CABAC/CAVLC) 使用。

**修改：**
- 新增 `prioritizeEncodingSpeedOverQuality: Bool`（預設 `false`）
  - 設 `true` 時 VT 採用更快編碼路徑（簡化 motion search），適合遊戲串流等 GPU 吃重場景
  - 代價：同視覺品質下 bitrate 略升
- 新增 `referenceBufferCount: Int?`（預設 `nil`）
  - 控制 VT 保留多少幀作為 motion compensation 參考
  - `nil` = VT 預設（約 4-5），設 `2`-`3` 可降 GPU/memory 頻寬
  - 代價：壓縮率略降

**兩項均在 `makeOptions()` 和 `apply()` 中生效，可在 runtime 動態切換不須重建 session。**

### 移除 VideoCodec 的 NotificationCenter observers + 簡化 stall detection

**檔案：** `HaishinKit/Sources/Codec/VideoCodec.swift`, `RTMPHaishinKit/Sources/RTMP/RTMPStream.swift`

**問題：**
- `VideoCodec` 註冊了 `AVAudioSession.interruptionNotification` 和 `UIApplication.willEnterForegroundNotification`，但這兩個事件不會讓 VT session 失效，handler 無故砍掉 session 造成自我干擾
- Audio/video stall detection 各自獨立計數，同時觸發時彼此 cancel 對方的 task，造成無窮 restart 循環（task 活不過一輪 status check）
- `VideoCodec` 沒有 `deinit`，observer 可能 crash dangling pointer

**修改：**
- **移除所有 `NotificationCenter` observer** — `VideoCodec` 不再自行監聽 foreground/interruption 事件
  - camera restart 後 `inputFormat.didSet` 已自動重建 session，無須手動介入
  - 移除 `didAudioSessionInterruption`、`applicationWillEnterForeground` handler 及對應的 add/remove
- **合併 audio/video stall detection** — 移除獨立的 `audioStallCount` 檢查，只保留 `videoStallCount` 統一判斷 pipeline 是否卡住
  - `restartVideoPipeline()` 重置 `audioStallCount` 和 `videoStallCount`
  - 避免同一 dispatch 中 video restart 後 audio restart 立刻 cancel 新 task
- **VideoCodec 診斷 log 改走 `onLog` callback** — 透過 `connection?.log()` 路徑輸出，會出現在 user 的 log 檔案中
  - `VideoCodec creating new session`、`pending frames = N` 等改由 `onLog` 傳遞
  - 新增 `setVideoCodecLogHandler()` 在 OutgoingStream 層級

---


- `RTMPHaishinKit/Sources/RTMP/MediaMixerOutputBridge.swift`（新增）
- `HaishinKit/Sources/Stream/OutgoingStream.swift`
- `HaishinKit/Sources/Stream/StreamConvertible.swift`
- `RTMPHaishinKit/Sources/RTMP/RTMPStream.swift`
- `RTMPHaishinKit/Sources/RTMP/RTMPConnection.swift`
- `RTMPHaishinKit/Sources/RTMP/RTMPSocket.swift`
- `HaishinKit/Sources/Codec/VideoCodec.swift`
- `HaishinKit/Sources/Codec/VideoCodecSettings.swift`
- `RTMPHaishinKit/Sources/RTMP/RTMPTimestamp.swift` — 移除 `syncToUpdatedAt`

