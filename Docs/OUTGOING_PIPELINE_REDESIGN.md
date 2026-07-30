# RTMP 輸出管線重構：高效能 TaskGroup 架構

> **日期**: 2026-06-26 | **涉及模組**: RTMPHaishinKit, HaishinKit

---

## 目錄

1. [舊架構問題](#1-舊架構問題)
2. [新架構設計](#2-新架構設計)
3. [壓縮管線修復](#3-壓縮管線修復)
4. [RTMPConnection 狀態機修復](#4-rtmpconnection-狀態機修復)
5. [幀率控制參數](#5-幀率控制參數)
6. [每幀成本對比](#6-每幀成本對比)
7. [診斷日誌](#7-診斷日誌)
8. [總結](#8-總結)

---

## 1. 舊架構問題

### 1.1 碎片化 Task 管理

舊設計使用 `[Task<Void, Never>]` 陣列管理所有非同步工作：

```swift
private var tasks: [Task<Void, Never>] = []

// publish() 內：
tasks.append(Task { for await audio in audioOutput { append(audio.0, when: audio.1) } })
tasks.append(Task { for await video in videoOutput { append(video) } })
tasks.append(Task { for await video in outgoing.videoInputStream { outgoing.append(video: video) } })
```

**問題**：

| 面向 | 影響 |
|------|------|
| 生命週期 | 每個 Task 獨立運行，無法集體取消或等待完成 |
| 重連競態 | `stopMixerInputConsumers()` 砍掉所有 Task 再重建，中間有空窗 |
| 防禦程式 | `close()` 裡有 `stopMixerInputConsumers()` + `startMixerInputConsumers()` 的無意義重啟 |

```
publish() 順序：
  outgoing.startRunning()
  stopMixerInputConsumers()   ← 砍掉全部舊 Task
  startMixerInputConsumers()  ← 重建 mixer 輸入 Task
  tasks.append(Task { ... })  ← 追加三個輸出 Task
  
  在 2 和 3/4 之間：encoder 產出的幀沒人消費 → 丟棄
```

### 1.2 雙重 Actor Hop — 高效能瓶頸

每個編碼幀從 encoder 輸出到 socket 發送，需要跨越 **兩個 actor**：

```
Encoder (VideoToolbox callback)
  ↓
videoOutputStream consumer Task
  ↓ await self.append(compressed)        ← RTMPStream actor hop
  ↓   RTMPVideoMessage 封裝
  ↓   doOutput() → outputContinuation closure
  ↓     await connection.doOutput(...)   ← RTMPConnection actor hop
  ↓       RTMP 分塊 → socket
```

120fps 場景下每幀 8.3ms，雙重 actor hop 的排程延遲成為瓶頸。

---

## 2. 新架構設計

### 2.1 核心原則

- **壓縮輸出路徑零 actor hop**：編碼器產出的幀直接封裝為 RTMP message，不經過 RTMPStream actor
- **TaskGroup 單一生命週期**：所有子任務在同一個 `withTaskGroup` 內，取消一次全部終止
- **最小鎖同步**：共享狀態（frameCount）用 `DispatchQueue.sync` 保護，timestamp 各自獨立無競爭

### 2.2 架構圖

```
MediaMixer ──→ mixer(_:didOutput:) ──→ mixerVideoContinuation
                                           │
                              TaskGroup sub-task (actor hop needed)
                                           │
                                    append(uncompressed)
                                           │
                                    outgoing.append() → encoder
                                           │
                              encoder output (videoOutputStream)
                                           │
                    ┌──────────────────────┴──────────────────────┐
                    │  TaskGroup sub-task (ZERO actor hop)        │
                    │  ┌──────────────────────────────────────┐   │
                    │  │ RTMPOutgoingState (DispatchQueue)    │   │
                    │  │  · timestamp 更新                   │   │
                    │  │  · frameCount 遞增                  │   │
                    │  │  · format change → sequence header  │   │
                    │  │  · RTMPVideoMessage 封裝            │   │
                    │  │  · → outputContinuation closure     │   │
                    │  └──────────────────────────────────────┘   │
                    └─────────────────────────────────────────────┘
                                           │
                              outputContinuation consumer
                                           │
                              RTMPConnection.doOutput (actor hop)
                                           │
                              socket.send
```

### 2.3 RTMPOutgoingState

`RTMPOutgoingState` 是 RTMPStream 的內部類別，擁有壓縮輸出所需的全部狀態，不依賴 actor：

```swift
private final class RTMPOutgoingState: @unchecked Sendable {
    private let frameCountQueue = DispatchQueue(label: "com.haishinkit.rtmpout.fc")

    var videoTimestamp = RTMPTimestamp<CMTime>()   // video 子任務獨佔，無競爭
    var audioTimestamp = RTMPTimestamp<AVAudioTime>() // audio 子任務獨佔，無競爭
    private var _frameCount: UInt16 = 0             // DispatchQueue 保護
    var videoFormat: CMFormatDescription?           // video 子任務獨佔
    var audioFormat: AVAudioFormat?                 // audio 子任務獨佔
}
```

### 2.4 startPublishTasks — TaskGroup 統一管理

```swift
private func startPublishTasks() {
    publishTask?.cancel()

    let state = RTMPOutgoingState()
    let streamId = id
    let outputCont = outputContinuation
    let conn = connection

    publishTask = Task { [weak self] in
        guard let self else { return }
        await withTaskGroup(of: Void.self) { group in
            // 1. mixer audio → encoder (actor hop, 低頻)
            group.addTask {
                for await (buffer, when) in audioStream {
                    await self.append(buffer, when: when)
                }
            }
            // 2. mixer video → encoder (actor hop, 低頻)
            group.addTask {
                for await sampleBuffer in videoStream {
                    await self.append(sampleBuffer)
                }
            }
            // 3. compressed audio → RTMP (零 actor hop)
            group.addTask {
                for await (buffer, when) in audioOutput {
                    guard let compressed = buffer as? AVAudioCompressedBuffer else { continue }
                    guard let td = try? state.audioTimestamp.update(when) else { continue }
                    guard let msg = RTMPAudioMessage(...) else { continue }
                    outputCont?.yield { [conn] in await conn?.doOutput(...) }
                }
            }
            // 4. compressed video → RTMP (零 actor hop)
            group.addTask {
                for await sampleBuffer in videoOutput {
                    guard let td = try? state.videoTimestamp.update(dts) else { continue }
                    state.incrementFrameCount()
                    // format change detection → sequence header
                    guard let msg = RTMPVideoMessage(...) else { continue }
                    outputCont?.yield { [conn] in await conn?.doOutput(...) }
                }
            }
            // 5. video encoder input feeder
            group.addTask {
                for await video in videoInput {
                    self.outgoing.append(video: video)
                }
            }
        }
    }
}
```

關鍵：`videoInput` 在 TaskGroup **之前**被捕獲，確保 `videoInputContinuation` 在 mixer 子任務可能產出第一幀前已就緒。

### 2.4 `stopPublishTasks()` — 單一終止點

```swift
private func stopPublishTasks() {
    publishTask?.cancel()
    publishTask = nil
    _outgoingState = nil
    mixerAudioContinuation?.finish()
    mixerAudioContinuation = nil
    mixerVideoContinuation?.finish()
    mixerVideoContinuation = nil
}
```

### 2.5 調用點

| 方法 | 行為 |
|------|------|
| `publish()` | `startPublishTasks()` 建立 TaskGroup |
| `close()` | `stopPublishTasks()` → `outgoing.stopRunning()` |
| `deleteStream()` | `stopPublishTasks()` → `outgoing.stopRunning()` |
| `dispatch(.reset)` | `stopPublishTasks()` |
| `init` | **不再啟動 mixer consumer**（延遲到 publish） |

---

## 3. 壓縮管線修復

### 3.1 `videoInputStream` computed property — 每次存取重建 stream

**檔案**: `HaishinKit/Sources/Stream/OutgoingStream.swift:49-53`

與 `VideoCodec.outputStream` 同款 bug：每次存取 `videoInputStream` 建立新 `AsyncStream` 並覆蓋 `videoInputContinuation`，`didSet` 會 finish 舊 continuation，正在迭代的 consumer 被強制終止。

```swift
// ❌ 舊
package var videoInputStream: AsyncStream<CMSampleBuffer> {
    return AsyncStream(...) { continuation in
        self.videoInputContinuation = continuation  // 每次覆蓋，舊的被 finish
    }
}

// ✅ 新：cache + stopRunning 清除
private var _videoInputStream: AsyncStream<CMSampleBuffer>?
package var videoInputStream: AsyncStream<CMSampleBuffer> {
    if let stream = _videoInputStream { return stream }
    let stream = AsyncStream(...) { continuation in
        self.videoInputContinuation = continuation
    }
    _videoInputStream = stream
    return stream
}
```

`stopRunning()` 同步清除 cache：

```swift
videoInputContinuation = nil
_videoInputStream = nil
```

### 3.2 `startPublishTasks` 內 TaskGroup 競態

`videoInputStream` 原本在 `group.addTask` closure 內才被存取，但 TaskGroup 子任務並行啟動——mixer 子任務可能在 input feeder 子任務觸發 `videoInputStream`（進而設定 `videoInputContinuation`）之前就已產出第一幀，導致 `videoInputContinuation` 為 nil，幀被丟棄。

**修復**：在 TaskGroup 外預先捕獲：

```swift
let videoInput = outgoing.videoInputStream  // ← 在 TaskGroup 之前，確保 continuation 已就緒

publishTask = Task { ... await withTaskGroup { group in
    group.addTask { for await video in videoInput { ... } }  // 用捕獲的，不再重新存取
}}
```

### 3.3 編碼器靜默丟幀 — 加入診斷 log

**檔案**: `VideoCodec.swift`, `AudioCodec.swift`

`VideoCodec.append()` 和 `AudioCodec.append()` 有兩類 guard 失敗會靜默丟幀，且完全無日誌：

| 位置 | guard | 意涵 |
|------|-------|------|
| `VideoCodec:58` | `isRunning` | 編碼器未啟動，幀被丟棄 |
| `VideoCodec:70` | `session, _outputContinuation` | VT session 未建成或輸出流未就緒 |
| `AudioCodec:52` | `isRunning` | 編碼器未啟動 |
| `AudioCodec:85` | `audioConverter, isRunning` | 轉換器未建成或未啟動 |

**修復**：全部加上 `logger.debug("... dropped: ...")`，可透過 `HaishinKitLogger.onLog` 回調橋接到外部日誌系統。

### 3.4 全域日誌橋接

**檔案**: `HaishinKit/Sources/Util/Constants.swift`

`HaishinKitLogger` 原本只寫 OSLog（僅 Xcode / Console.app 可見）。新增 `onLog` 回調，與 `RTMPConnection.onLog` 同模式：

```swift
public struct HaishinKitLogger {
    public var onLog: (@Sendable (_ level: LogLevel, _ message: String) -> Void)?
    
    public func debug(_ items: Any...) {
        let message = items.map(...).joined(separator: " ")
        os_log(.debug, log: osLog, "%{public}@", message)
        onLog?(.debug, message)  // ← 同步觸發外部回調
    }
}
```

ReplyKit 初始化時一處設定，兩條通道匯聚：

```swift
logger.onLog = { level, message in
    ReplyKitLogBridge.send(level: "\(level)", message: message)
}
```

---

## 4. RTMPConnection 狀態機修復

### 4.1 遺漏的狀態轉換

舊狀態機不允許從 `.disconnected` 或 `.error` 回到 `.connecting`，導致斷線後 `connect()` 永遠拋 `invalidState`：

```swift
// ❌ 舊：缺少 disconnection → 重連路徑
func canTransition(to newState: ConnectionState) -> Bool {
    switch (self, newState) {
    case (.uninitialized, .connecting),         // 只有 uninitialized 能連
         (.connecting, .versionSent),
         ...
         (.connected, .disconnected),
         (_, .disconnected),
         (_, .error):
        return true
    }
}
```

```swift
// ✅ 新：加入斷線/錯誤後重連
case (.disconnected, .connecting),
     (.error, .connecting),
```

### 4.2 TCP 連線失敗後狀態卡住

TCP `socket.connect()` 失敗時，state 留在 `.connecting` 但 `connected = false`。下次 `connect()` 因 `.connecting → .connecting` 不合法而失敗。

**修復**：失敗時設 `state = .error`。

### 4.3 無限重連迴圈

`performConnect()` 每次成功都把 `reconnectAttempts` 歸零，導致重連永遠不會達到上限（max=5），形成無限迴圈。

**修復**：移除 `performConnect` 內的 reset，保留 `connect()` 的初始重置。

---

## 5. 幀率控制參數

### 5.1 `frameInterval` — 送入編碼器前的本地幀率過濾

**檔案**: `VideoCodec.swift:107-118`, `VideoCodecSettings.swift:134`

| 項目 | 值 |
|------|-----|
| 預設 | `0.0` |
| 效果 | 0 = passthrough，所有幀不攔截 |
| 設定方式 | `videoSettings.frameInterval = VideoCodecSettings.frameInterval30` |
| 常用預設值 | `frameInterval30` (0.0323), `frameInterval10` (0.099), `frameInterval05` (0.199), `frameInterval01` (0.999) |

```swift
private func useFrame(_ pts: CMTime) -> Bool {
    guard startedAt <= pts else { return false }                    // 時鐘未到，丟
    guard self.presentationTimeStamp < pts else { return false }    // 時間倒退，丟
    guard Self.frameInterval < frameInterval else { return true }   // 0.0 < 0.0 = false → 全過
    return frameInterval <= pts.seconds - self.presentationTimeStamp.seconds  // 間距不夠，丟
}
```

`frameInterval = 0` 時第三個 guard 直接短路為 `true`，所有幀送入編碼器。只在顯式設定時才啟動過濾。

### 5.2 `maxKeyFrameIntervalDuration` — IDR 關鍵幀間隔

**檔案**: `VideoCodecSettings.swift:124`, `VideoCodec.swift:120-128`

| 項目 | 值 |
|------|-----|
| 預設 | `2` 秒 |
| 作用一 | VideoToolbox 編碼器參數：`kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration = 2` |
| 作用二 | HaishinKit 軟體補強：`shouldForceKeyFrame()` 在幀上打 `forceKeyFrame` flag |

```swift
private func shouldForceKeyFrame(_ pts: CMTime) -> Bool {
    let duration = settings.maxKeyFrameIntervalDuration
    guard 0 < duration else { return false }
    guard let lastKeyFramePresentationTimeStamp else { return true }  // 首幀必為 IDR
    return Double(duration) <= (pts - lastKeyFramePresentationTimeStamp).seconds
}
```

雙層保障：VideoToolbox 依 `maxKeyFrameIntervalDuration` 定時出 IDR；HaishinKit 另在 `convert()` 時傳 `forceKeyFrame` 做軟體兜底。

### 5.3 `expectedFrameRate` — 功耗提示與 KeyFrame 計算

| 項目 | 值 |
|------|-----|
| 預設 | `nil` |
| 效果 | 告知 VideoToolbox 預期幀率以優化功耗；用於計算 `maxKeyFrameInterval`（以幀數計） |
| 計算邏輯 | nil + `frameInterval = 0` → 預設以 30fps 計算，得出 `maxKeyFrameInterval = 60` 幀 |

### 5.4 三者關係

```
frameInterval          maxKeyFrameIntervalDuration      expectedFrameRate
(本地過濾)              (IDR 間隔秒數)                   (編碼器提示)
     │                        │                              │
     ▼                        ▼                              ▼
useFrame()              shouldForceKeyFrame()           VTSession.setOption
跳過太近的幀            打 forceKeyFrame flag           .expectedFrameRate
                              │
                              ▼
                    VTSession.setOption
                    .maxKeyFrameIntervalDuration
```

一般場景：只調 `maxKeyFrameIntervalDuration`（低延遲設 0.1~0.5s，省頻寬設 3~5s），`frameInterval` 和 `expectedFrameRate` 維持預設不動。

---

## 6. 每幀成本對比

### Actor Hop 次數

| 路徑 | 舊設計 | 新設計 |
|---|---|---|
| mixer → encoder (video) | 1 hop (RTMPStream) | 1 hop (RTMPStream) |
| mixer → encoder (audio) | 1 hop (RTMPStream) | 1 hop (RTMPStream) |
| **encoder → RTMP (video)** | **1 hop (RTMPStream)** | **0 hop** |
| **encoder → RTMP (audio)** | **1 hop (RTMPStream)** | **0 hop** |
| 分塊 → socket | 1 hop (RTMPConnection) | 1 hop (RTMPConnection) |

### 120fps 場景估算

以每幀 8.3ms 為例：

| 指標 | 舊設計 | 新設計 |
|------|--------|--------|
| RTMPStream actor hop/幀 | 2 (mixer + output) | 1 (mixer only) |
| 排程延遲/幀 | ~2-4µs × 2 | ~2-4µs × 1 |
| Task 生命週期 | 5 個獨立 Task | 1 個 TaskGroup（5 子任務） |
| 取消行為 | 各自 cancel | `cancel()` 一次全部終止 |
| 重連競態 | 有空窗 | 無空窗（TaskGroup 確保全部完成） |

---

## 7. 診斷日誌

所有診斷訊息走兩條通道：

| 通道 | 範圍 | 使用方式 |
|------|------|---------|
| `connection.onLog` | RTMPConnection, RTMPStream, RTMPSocket | `await connection.setOnLog { ... }` |
| `logger.onLog` | VideoCodec, AudioCodec, OutgoingStream | `logger.onLog = { level, msg in ... }` |

透過 `logger.onLog` 回調，ReplyKit 處設定後兩條通道匯聚到同一外部日誌系統。

### 核心診斷訊息

| 日誌訊息 | 來源 | 意義 |
|----------|------|------|
| `mixer->stream: video pts=X` | RTMPStream | MediaMixer → RTMPStream 收到未壓縮幀 |
| `outgoing->rtmp: video pts=X size=Y` | RTMPStream | 壓縮幀走新路徑，零 actor hop 送入輸出 |
| `outgoing->rtmp: audio size=Y` | RTMPStream | 同上，音訊 |
| `append(video): sending pts=X size=Y` | RTMPStream | 壓縮幀走舊路徑（passthrough / 外部呼叫） |
| `append(audio): sending size=Y` | RTMPStream | 同上 |
| `doOutput dropped: connection is nil` | RTMPStream | connection 被釋放，輸出被丟棄 |
| `append(video): RTMPVideoMessage creation failed` | RTMPStream | RTMP 封裝失敗 |
| `VideoCodec.append dropped: encoder not running` | VideoCodec | 編碼器未啟動 |
| `VideoCodec.append dropped: session=X continuation=Y` | VideoCodec | VT session 或輸出流未就緒 |
| `AudioCodec.append(CMSampleBuffer) dropped: encoder not running` | AudioCodec | 音訊編碼器未啟動 |
| `AudioCodec.append(AVAudioBuffer) dropped: converter=X running=Y` | AudioCodec | 音訊轉換器未建成或未啟動 |

---

## 8. 總結

### 變更檔案

| 檔案 | 變更類型 | 說明 |
|------|---------|------|
| `RTMPStream.swift` | 重構 | TaskGroup + RTMPOutgoingState + 診斷 log |
| `RTMPConnection.swift` | 修復 | 狀態機 ×3 |
| `OutgoingStream.swift` | 修復 | `videoInputStream` cache + `stopRunning` 清理 |
| `VideoCodec.swift` | 加強 | 靜默丟幀 → `logger.debug` |
| `AudioCodec.swift` | 加強 | 靜默丟幀 ×2 → `logger.debug` |
| `Constants.swift` | 新增 | `HaishinKitLogger.onLog` 回調 |

### 向後相容

- 公開 API（`append(_:)`, `doOutput`, `publish`, `close`）保持不變
- actor 的 `append(compressed)` 路徑保留，供 passthrough 與外部呼叫使用
- `_Stream` / `StreamConvertible` 協定不受影響

### 建議後續優化

| 優化方向 | 適用場景 | 複雜度 |
|----------|---------|--------|
| 移除 RTMPStream actor，改用 lock-based class | 進一步消除 mixer 路徑的 actor hop | 高（協定層需重構） |
| 將 RTMPConnection.doOutput 也移出 actor | 完全消除 actor hop | 中 |
| MPSC ring buffer 取代 AsyncStream | 120fps+ 4K | 高 |

---

## 9. 管線傳遞設計修正（2026-07 月）

### 9.1 Egress Drop Policy — 移除 AsyncStream bound

**檔案**: `RTMPConnection.swift:625`

`RTMPConnection.outputContinuation` 原本使用 `.bufferingOldest(512)`。當 socket 慢時此層會丟最舊 chunk data，可能破壞 RTMP 串流結構。同時下游 `RTMPSocket` 已有 `maxQueueBytesOut = 5MB` 作為背壓，AsyncStream 層的 bound 是多餘的。

**修正**: 改為 `.unbounded`，背壓完全交由 `RTMPSocket.maxQueueBytesOut` 管理，讓資料自然回流至 `NetworkMonitor` 佇列偵測機制。

### 9.2 MediaMixerOutputBridge — 消除 nonisolated(unsafe) 與每幀 Task{}

**檔案**: `RTMPHaishinKit/Sources/RTMP/MediaMixerOutputBridge.swift`（新增）

原本 `mixerAudioContinuation` / `mixerVideoContinuation` 標記為 `nonisolated(unsafe)`，且 mixer 回呼透過 `Task { continuation?.yield(...) }` 將 frame 送入 pipeline。

```
// 原始（每幀開 Task）
nonisolated func mixer(_:didOutput:) {
    let c = mixerVideoContinuation      // nonisolated(unsafe)
    Task { c?.yield(sampleBuffer) }      // ~80 Task/sec
}
```

**問題**:
1. `nonisolated(unsafe)` 繞過 compiler 隔離檢查
2. 每秒 80+ 次 Task 分配（30fps video + ~50fps audio PCM）

**修正**: 新增 `MediaMixerOutputBridge`（`@unchecked Sendable`），以 `nonisolated let` 在 actor 外持有 continuations，mixer 回呼直接呼叫 bridge：

```swift
// 現在（直接 DispatchQueue .async）
nonisolated func mixer(_:didOutput:) {
    mixerOutputBridge.yieldVideo(sampleBuffer)  // 無 Task
}
```

### 9.3 DispatchQueue Pacing — 消除 frame burst 撕裂

**檔案**: `MediaMixerOutputBridge.swift`

橋接器改為 `DispatchQueue.async` 序列化 yield：

```
// 直接 yield（前版）：MediaMixer 暴衝 30 幀 → buffer(5) 丟 25 幀 → 撕裂
// DispatchQueue（現在）：序列化 yield → 自然 pace → buffer 不溢滿
```

`DispatchQueue` 提供與 `Task{}` 同等的 pacing 效果，但無 Swift concurrency Task 每幀分配開銷。

### 9.4 Byte-based Buffer 控制 — 以記憶體預算自動計算幀數

**檔案**: `OutgoingStream.swift`, `StreamConvertible.swift`, `RTMPStream.swift`

原本 `videoInputBufferCounts = 5` 固定值，不考慮解析度與記憶體限制。新增 `maxVideoBufferBytes`（預設 15MB）與自動計算：

```swift
// 根據解析度自動計算
func computeVideoInputBufferCounts(for size: CGSize) -> Int {
    let bytesPerFrame = size.width * size.height * 1.5  // NV12
    return max(1, min(30, maxVideoBufferBytes / bytesPerFrame))
}
```

| 解析度 | 每幀大小 | 自動 buffer 幀數 |
|-------|---------|----------------|
| 1080p | ~3.0 MB | 5 |
| 720p | ~1.4 MB | 10 |
| 540p | ~0.8 MB | 18 |
| 360p | ~0.3 MB | 30 (上限) |

**API 變更**:
- `setVideoInputBufferCounts(Int)` 保留但傳 -1 可恢復自動模式
- 新增 `maxVideoBufferBytes` 屬性

### 9.5 Audio Pipeline Stall 檢測

**檔案**: `RTMPStream.swift`, `OutgoingStream.swift`

原本 Video 有 `restartVideoPipeline()` 但 Audio 完全沒有對應機制。

**新增**:
- `audioInputFrames` 計數器（PCM 送入 codec 時累加）
- `audioStallCount` 累計器
- 在 `NetworkMonitorEvent.status` 中檢測：`audioInputFrames > 0 && audioSentFrames == 0` 達 3 次連續 interval → 觸發 `restartAudioPipeline()`
- `OutgoingStream.restartAudioCodec()` + `RTMPStream.restartAudioPipeline()`

### 9.6 取消 video output unbounded

VideoCodec.outputStream 原本想改 `.bufferingNewest(60)` 但造成撕裂（post-encode 丟幀破壞 frame 連續性），已恢復為 `.unbounded`。正確的背壓點是 encoder input stream（`.bufferingNewest(videoInputBufferCounts)`），而非 output。

### 9.7 變更檔案總表

| 檔案 | 變更 |
|------|------|
| `MediaMixerOutputBridge.swift` | **新增**：bridge 層，DispatchQueue pacing |
| `RTMPConnection.swift` | 改 `.bufferingNewest(256)`（原本 unbounded 造成 latency 無限累積） |
| `RTMPStream.swift` | 改用 bridge、audio stall 檢測、status gap warn log |
| `OutgoingStream.swift` | byte-based buffer 控制、restartAudioCodec |
| `VideoCodec.swift` | 恢復 unbounded output stream |
| `VideoCodecSettings.swift` | 新增 `maxFrameDelayCount` 參數 |
| `StreamConvertible.swift` | 新增 maxVideoBufferBytes 屬性 |
| `RTMPSocket.swift` | 加入 weak self 避免 retain cycle |
| `RTMPMessage.swift` | 新增接受 compositionTime 的 initializer |
| `VTSessionConvertible.swift` | convert() 回傳 Bool 表示 frame drop |
| `VTCompressionSession+Extension.swift` | frame drop 回傳邏輯 |
| `VTDecompressionSession+Extension.swift` | 更新 protocol 實作 |

### 9.8 修正：B-frame CTO（Composition Time Offset）計算

**檔案**: `RTMPMessage.swift`, `RTMPStream.swift`

VideoToolbox 啟用 B-frame（`allowFrameReordering = true`）時會以 decode order（DTS 順序）輸出 frame，但 `CMSampleBuffer.decodeTimeStamp` 不一定有效。原有的 `getCompositionTime` 在 DTS invalid 時回傳 0，導致 RTMP player 無法正確 reorder frames → 撕裂。

**修正**: 移除 `videoDecodeOrder` 計數器。CTO 直接由 `videoTimestamp.updatedAt`（DTS）計算：

```swift
// CTO = PTS - DTS（DTS 來自 RTMPTimestamp.updatedAt，保證一致）
compositionTime = (pts.seconds - videoTimestamp.updatedAt) * 1000
```

原有 `videoDecodeOrder` 在 timestamp resync（PTS 非遞增）後會繼續累積，導致 CTO 偏差 → DTS drift → 伺服端 ffmpeg 報 `Invalid DTS: DTS > PTS`。直接使用 `updatedAt` 確保 DTS 永遠與 RTMP 訊息時間戳一致。

`RTMPVideoMessage` 新增接受外部 `compositionTime` 的 initializer，讓 `RTMPStream` 傳入正確的 CTO。

**效果**: `allowFrameReordering = true` 時 B-frame 也能正確計算 CTO，player 可正確 reorder frames → 無撕裂。

### 9.9 VT frame drop 偵測 + expectedFrameRate 參數

**檔案**: `VideoCodecSettings.swift`, `VTSessionConvertible.swift`, `VTCompressionSession+Extension.swift`, `VTDecompressionSession+Extension.swift`

- `expectedFrameRate` 加入 `makeOptions()`，確保 VT session 建立時就知道 target framerate，rate control 更準確
- `VTSessionConvertible.convert()` 回傳 `Bool` 表示 VT 是否丟棄了該 frame（檢查 `VTEncodeInfoFlags.frameDropped`）
- `VideoCodec.append` 在 VT 丟幀時輸出 `"VideoCodec frame dropped by VT"` debug log

**效果**: 可從 onLog 確認撕裂或 frame 丟失是否來自 VT 內部（因 encoder 塞車主動丟幀）。



### 9.10 RTMPTimestamp.syncToUpdatedAt 移除

移除 `syncToUpdatedAt` 方法。原本在 pipeline restart 時用於將 video timestamp 對齊 audio，但實際因下一幀 resync 立即覆寫而無效。副作用是 sync 將 `updatedAt` 跳到未來 → 接下來多幀 `delta=0` → ffmpeg 報 `Non-monotonous DTS`。A/V 各自 PTS 來自同一個系統時鐘，restart 後自然對齊。

**檔案**: `MediaMixerOutputBridge.swift`

橋接器改為 `DispatchQueue.async` 序列化 yield：

```
// 直接 yield（前版）：MediaMixer 暴衝 30 幀 → buffer(5) 丟 25 幀 → 撕裂
// DispatchQueue（現在）：序列化 yield → 自然 pace → buffer 不溢滿
```

### 9.11 Pipeline Restart — 完整重置 OutgoingStream 與 Timestamps

**檔案**: `RTMPStream.swift:1070-1113`, `VideoCodec.swift`, `AudioCodec.swift`

#### 9.11.1 問題

`restartVideoPipeline()` 原本只呼叫 `outgoing.restartVideoCodec()`，留下多項殘留狀態導致 pipeline 永遠無法恢復：

| 殘留狀態 | 影響 |
|----------|------|
| `_videoInputStream` 快取 | 跨 task 世代共享，舊 task 的 for-await loop 可能繼續競爭消費 |
| `videoInputContinuation` 未清除 | yield 到已 finish 或從屬於舊 task 的 stream |
| `audioCodec.outputStream` 從未被取代 | 音訊 pipeline 重啟後完全無輸出（audioSentFrames = 0） |
| `videoTimestamp`/`audioTimestamp` 未清除 | 若相機 PTS 因 capture session 重啟歸零，RTMP timestamp 跳回 0，audio 維持 ~120s，造成 A/V timeline 錯亂 → Twitch #1000 |

#### 9.11.2 修復

**`stopPublishTasks()` → `outgoing.stopRunning()` → `outgoing.startRunning()` 取代 `restartVideoCodec()` / `restartAudioCodec()`**：

```swift
private func restartVideoPipeline(reason: String) async {
    ...
    stopPublishTasks()                    // cancel old task, finish bridge
    outgoing.stopRunning()                // finish both codecs, clear _videoInputStream, videoInputContinuation
    outgoing.startRunning()               // create fresh codec sessions + output streams
    videoFormat = nil
    audioFormat = nil
    videoTimestamp.clear()                // reset RTMP timestamp trackers
    audioTimestamp.clear()                // both A/V start from clean timeline
    startPublishTasks()                   // new task, new bridge, fresh _videoInputStream
    ...
}
```

`outgoing.stopRunning()` 的完整清除鏈：

```
OutgoingStream.stopRunning()
  ├── videoCodec.stopRunning()
  │     ├── session = nil / invalidateSession = true
  │     ├── outputContinuation?.finish()
  │     ├── presentationTimeStamp = .zero
  │     └── startedAt = .zero
  ├── audioCodec.stopRunning()
  │     ├── outputContinuation?.finish()
  │     └── isRunning = false
  ├── videoInputContinuation = nil   // didSet 會 finish 舊值
  └── _videoInputStream = nil        // 下次 access 建立全新 stream
```

`videoTimestamp.clear()` 等效於建構子狀態，確保重啟後第一個 frame 的 RTMP timestamp 從 0 開始：

```swift
mutating func clear() {
    startedAt = kRTMPTimestamp_defaultTimeInterval  // 0
    updatedAt = 0
    timedeltaFraction = 0
    lastRawTimestamp = 0
    rolloverCount = 0
    lastDelta = 0
}
```

#### 9.11.3 效果

| 場景 | 修復前 | 修復後 |
|------|--------|--------|
| Pipeline restart 後 encoder 無輸出 | videoFrames=0 持續，stallCount 累積 → 無限重啟 | 新 task 獨佔全新 stream，正常輸出 |
| Audio 管線隨 video restart 一起停擺 | audioSentFrames=0 持續 | `startRunning()` 重新建立 audioCodec outputStream |
| Camera PTS reset 後 A/V timeline 錯亂 | video RTMP timestamp 跳回 0，audio 在 120s | 雙方一起從 0 開始，自然對齊 |

### 9.12 Adaptive Frame Throttle — 真實 Input FPS 追蹤

**檔案**: `VideoCodec.swift:77-127`

#### 9.12.1 問題

原本 `currentFps` 寫死 60fps baseline：

```swift
// ❌ 舊
let currentFps = frameInterval > 0 ? 1.0 / frameInterval : 60.0
```

若相機實際只有 30fps：
- baseline = 60 (錯誤)
- 降 15% → target = 51fps
- `frameInterval = 1/51 ≈ 0.0196`
- 但 `useFrame` 最多讓 30fps 通過 → throttle 完全沒作用

ProMotion 80fps 場景下：
- `expectedFrameRate = nil` 時 `useFrame` 全放行
- 80fps → VT 過載 → throttle 降 15% → 68fps → 仍然太高
- framerate 在 22~66fps 之間劇烈振盪
- bitrate 隨之暴漲暴跌（207~4078 Kbps）

#### 9.12.2 修復

加入真實 input frame interval 的 EMA（Exponential Moving Average）追蹤：

```swift
private var lastFrameTime: Date = .distantPast
private var smoothedFrameInterval: Double = 1.0 / 60.0

private func updateAdaptiveFrameInterval() {
    let now = Date()
    if lastFrameTime != .distantPast {
        let actualInterval = now.timeIntervalSince(lastFrameTime)
        smoothedFrameInterval = smoothedFrameInterval * 0.7 + actualInterval * 0.3
    }
    lastFrameTime = now

    ...

    // ✅ 新：用真實 smoothed interval 取代硬編碼 60
    let currentFps = frameInterval > 0 ? 1.0 / frameInterval : 1.0 / smoothedFrameInterval
    let targetFps = currentFps * 0.85
    frameInterval = 1.0 / max(15.0, targetFps)
}
```

| 相機 FPS | 舊 baseline | 舊 target | 新 baseline | 新 target (85%) |
|----------|------------|-----------|------------|----------------|
| 30 | 60 (錯) | 51 (無效) | 30 | 25.5 ✅ |
| 60 | 60 | 51 | 60 | 51 |
| 80 (ProMotion) | 60 (錯) | 51 (太弱) | 80 | 68 |

`stopRunning()` 與 `resetSessionState()` 中也重置 tracking 變數，防止 restart 後初始 interval 誤判。

#### 9.12.3 建議配置

```swift
// 最穩定的 1080p60 配置
videoSettings.expectedFrameRate = 60          // 安全上限，砍半 framerate
videoSettings.adaptiveFrameThrottle = true    // 安全網：VT 塞車時再降 15%
videoSettings.prioritizeEncodingSpeedOverQuality = true
```

`expectedFrameRate = 30` 的效果：
- `useFrame` 確保最多 30fps 送入 encoder（無論相機是 60/80/120fps）
- `adaptiveFrameThrottle` 從真實 30fps baseline 計算，降速有效
- VT 負載穩定 → bitrate 波動大幅減少

### 9.13 變更檔案總表

| 檔案 | 變更 |
|------|------|
| `RTMPStream.swift` | `restartVideoPipeline`/`restartAudioPipeline` 改為 `outgoing.stopRunning()`+`startRunning()`，加入 `videoTimestamp.clear()`/`audioTimestamp.clear()` |
| `VideoCodec.swift` | `updateAdaptiveFrameInterval` 加入 `lastFrameTime`/`smoothedFrameInterval` EMA 追蹤，`currentFps` 使用真實 input rate 而非硬編碼 60；`stopRunning()`/`resetSessionState()` 重置 tracking |