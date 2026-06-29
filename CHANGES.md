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
