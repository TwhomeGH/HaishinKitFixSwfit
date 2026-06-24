# AsyncStream yield() 同步鏈造成 cooperative thread stack overflow (bug_type 309)

## 問題

ReplayKit extension（`ReplyKIT`）在 iOS 27 beta 上反覆出現 `bug_type: 309` crash：

```json
"bug_type":"309",
"exception":{"type":"EXC_BAD_ACCESS","signal":"SIGBUS","subtype":"KERN_PROTECTION_FAILURE"},
"faultingThread":4,
"queue":"com.apple.root.default-qos.cooperative",
"vmRegionInfo":"Stack 16dd04000-16dd8c000 [544K] ... ---> Stack Guard 16dd8c000-16dd90000 [16K]"
```

- **544KB** 是 iOS 非主線程預設 stack 大小（cooperative thread pool）
- crash 位址在 Stack Guard page，表示 thread 3 的 544KB stack 溢位撞到保護頁
- `completeTaskWithClosure(swift::AsyncContext*, swift::SwiftError*)` 在最底層 frame，上方 15 層全是 ReplyKIT 未符號化幀

## 根因

`AsyncStream.Continuation.yield()` 在 cooperative thread pool 上會**同步 resume** 正在等待的 `for-await` consumer。一連串的 yield 形成無法釋放的 stack 累積。

### 同步鏈全景

`processSampleBuffer` 以 30fps 影片 + ~100Hz 音訊 高頻率觸發 `Task`，每個 task 進入 `MediaMixer.append()` 後，在**同一個 cooperative thread** 上觸發多層 yield：

```
processSampleBuffer  →  Task  (cooperative thread)
  └─ await mixer.append(sampleBuffer)
       └─ MediaMixer.append()                          ← actor, await 進入
            └─ videoIO.append(track, buffer)
                 └─ VideoMixer.append()
                      ├─ delegate.videoMixer(didInput:)     ①②③  _inputs 鏈
                      │    └─ VideoCaptureUnit._inputs.yield((track, buffer))
                      │         └─ [同步 resume] MediaMixer for-await inputs
                      │              └─ output.mixer(self, didOutput:)  ← nonisolated!
                      │                   └─ RTMPStream.mixer(didOutput:)
                      │                        └─ mixerVideoContinuation.yield(sampleBuffer)
                      │                             └─ [同步 resume] RTMPStream for-await
                      │                                  └─ append → OutgoingStream → VideoCodec
                      │
                      └─ outputSampleBuffer(sampleBuffer)    ④⑤⑥  _output 鏈
                           └─ delegate.videoMixer(didOutput:)
                                └─ VideoCaptureUnit._output.yield(buffer)
                                     └─ [同步 resume] MediaMixer for-await output
                                          └─ output.mixer(self, didOutput:)  ← nonisolated!
                                               └─ RTMPStream.mixer(didOutput:)
                                                    └─ mixerVideoContinuation.yield(sampleBuffer)
                                                         └─ [同步 resume] RTMPStream for-await
                                                              └─ append → OutgoingStream → VideoCodec

總計: 30+ 層 frame 在同一個 cooperative thread stack 上 → 超過 544KB → 撞 Stack Guard page
```

### 核心機制

1. **`continuation.yield()` 同步 resume**：consumer 的 `for-await` 在同一個 cooperative thread 上被立即喚醒，stack 繼續往上疊
2. **`nonisolated func mixer()`**：`RTMPStream.mixer(_:didOutput:)` 宣告為 `nonisolated`，不經過 actor hop，直接在呼叫者線程上執行
3. **VideoMixer 雙 yield**：`append()` 內先觸發 `_inputs` 鏈（①②③），同一個 call 內再觸發 `_output` 鏈（④⑤⑥），stack 從未釋放
4. **音訊路徑同樣結構**：`AudioMixerByMultiTrack → AudioCaptureUnit.contination.yield() → resume MediaMixer for-await → output.mixer(didOutput:when:) → mixerAudioContinuation.yield() → resume RTMPStream`

## 修復

### 核心修復：打斷 yield 同步鏈

在 `mixer(_:didOutput:)` 中用 `Task { ... }` 包住 `yield()`，讓 consumer 在獨立棧執行：

```swift
// RTMPStream.swift:902 / SRTStream.swift:243
// BEFORE (yield 在同一個 cooperative thread 上同步 resume consumer)
nonisolated public func mixer(_ mixer: MediaMixer, didOutput sampleBuffer: CMSampleBuffer) {
    mixerVideoContinuation?.yield(sampleBuffer)
}

// AFTER (yield 在新 Task 的獨立棧中執行)
nonisolated public func mixer(_ mixer: MediaMixer, didOutput sampleBuffer: CMSampleBuffer) {
    let continuation = mixerVideoContinuation
    Task { continuation?.yield(sampleBuffer) }
}
```

#### 為什麼這樣修復有效

- `Task { ... }` 建立新的 unstructured task，擁有獨立的 stack frame
- `mixer()` 建立 Task 後**立即返回**，呼叫方的 stack 釋放
- Task 內的 `yield()` 在獨立環境中 resume consumer，不再累積在原 cooperative thread 上
- 每層 boundary 的 stack depth 被限制在 ~10 層（而不是原來的 30+ 層）

### 輔助修復：節流 Task 建立

`SampleHandler.processSampleBuffer` 新增 boolean gate，每個媒體類型最多同時只有一個 append Task：

```swift
// SampleHandler.swift
private var isAppendingVideo = false
private var isAppendingAudioMic = false
private var isAppendingAudioApp = false

override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
    switch sampleBufferType {
    case .video:
        guard !isAppendingVideo else { return }
        isAppendingVideo = true
        Task {
            defer { isAppendingVideo = false }
            // video config + append 合併在一個 Task 內
            await mixer.append(sampleBuffer)
        }
    // ...
    }
}
```

防止 Task 爆炸（原先 video 每幀 2 個 Task、audio 每幀 1 個，合計 ~160 tasks/sec）。

## 受影響檔案

| 檔案 | 修改內容 |
|------|----------|
| `RTMPHaishinKit/Sources/RTMP/RTMPStream.swift` | `mixer(_:didOutput:)` video/audio 兩方法：yield 包入 `Task { }` |
| `SRTHaishinKit/Sources/SRT/SRTStream.swift` | 同上 |
| `Examples/iOS/Screencast/SampleHandler.swift` | 新增 boolean gate 節流；video config + append 合併成單一 Task |

## 診斷方法

在 `.ips` crash report 中確認以下特徵：

1. `bug_type: "309"` — Apple stack overflow 類型
2. `queue: "com.apple.root.default-qos.cooperative"` — Swift concurrency 線程池
3. `vmRegionInfo` 顯示 `Stack Guard` 區段，鄰近 stack 為 `[544K]`
4. 最底層 frame 為 `completeTaskWithClosure` in `libswift_Concurrency.dylib`
5. 上方多層 frame 皆為 app binary（`imageIndex: 0`），未符號化

## 相關問題

- [NWConnection 遞迴 receive](./nw-recursion.md)：同樣是 callback 同步觸發造成 stack overflow
- [泛型特化遞迴](./generic-specialization-recursion.md)：compiler 特化造成的 stack overflow
- 三者 crash 特徵相同（EXC_BAD_ACCESS / KERN_PROTECTION_FAILURE），差別在於堆疊內容
