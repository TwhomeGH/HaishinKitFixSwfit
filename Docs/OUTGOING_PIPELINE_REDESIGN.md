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
