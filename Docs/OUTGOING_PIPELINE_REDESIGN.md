# RTMP 輸出管線重構：高效能 TaskGroup 架構

> **日期**: 2026-06-26 | **涉及模組**: RTMPHaishinKit

---

## 目錄

1. [舊架構問題](#1-舊架構問題)
2. [新架構設計](#2-新架構設計)
3. [RTMPConnection 狀態機修復](#3-rtmpconnection-狀態機修復)
4. [每幀成本對比](#4-每幀成本對比)
5. [診斷日誌](#5-診斷日誌)
6. [總結](#6-總結)

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
                for await video in self.outgoing.videoInputStream {
                    self.outgoing.append(video: video)
                }
            }
        }
    }
}
```

`stopPublishTasks()` 單一呼叫即終止所有子任務：

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

## 3. RTMPConnection 狀態機修復

### 3.1 遺漏的狀態轉換

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

### 3.2 TCP 連線失敗後狀態卡住

TCP `socket.connect()` 失敗時，state 留在 `.connecting` 但 `connected = false`。下次 `connect()` 因 `.connecting → .connecting` 不合法而失敗。

**修復**：失敗時設 `state = .error`。

### 3.3 無限重連迴圈

`performConnect()` 每次成功都把 `reconnectAttempts` 歸零，導致重連永遠不會達到上限（max=5），形成無限迴圈。

**修復**：移除 `performConnect` 內的 reset，保留 `connect()` 的初始重置。

---

## 4. 每幀成本對比

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

## 5. 診斷日誌

所有診斷訊息透過 `connection.onLog` 通道輸出，可在無 Xcode 環境下側載檢查：

| 日誌訊息 | 意義 |
|----------|------|
| `mixer->stream: video pts=X` | MediaMixer → RTMPStream 收到未壓縮幀 |
| `outgoing->rtmp: video pts=X size=Y` | 壓縮幀走新路徑，零 actor hop 送入輸出 |
| `outgoing->rtmp: audio size=Y` | 同上，音訊 |
| `append(video): sending pts=X size=Y` | 壓縮幀走舊路徑（passthrough / 外部呼叫） |
| `append(audio): sending size=Y` | 同上 |
| `doOutput dropped: connection is nil` | connection 被釋放，輸出被丟棄 |
| `append(video): RTMPVideoMessage creation failed` | RTMP 封裝失敗 |

---

## 6. 總結

### 變更檔案

| 檔案 | 變更類型 | 說明 |
|------|---------|------|
| `RTMPStream.swift` | 重構 | TaskGroup + RTMPOutgoingState 取代碎片化 Task |
| `RTMPConnection.swift` | 修復 | 狀態機 + TCP 錯誤 + 重連計數器 |

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
