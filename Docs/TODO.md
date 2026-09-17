# TODO / 計畫

本文件記錄**已規劃但尚未實作**的工作。實作完成後，請把結果移到 `CHANGES.md` 並在此移除該項。

---

## P1. keepalive ping 狀態機：抽成可單元測試的純型別 + 測試

**狀態**：核心已實作（CHANGES #56b：`RTMPConnection` 內的 1s-tick keepalive loop +
ping/pong + fallback）。剩下的是**可測試性**與**握手階段**的細化。

**剩餘工作**：

1. 把 keepalive 邏輯從 `RTMPConnection` 抽成純型別 `RTMPKeepAlive`（輸入
   `onTick(now:)` / `onPong` / `onInboundBytes` / `onApplicationBytes`，輸出
   `Decision { none, probe(value), declareDead }`），讓狀態機可在無 socket 下單元測試。
2. 測試案例：active 不送 probe、idle 達門檻送 probe、probe 後收 pong → alive、
   probe 逾時無 inbound → declareDead、連續 `maxUnansweredPings` 無 pong → 停用
   dead 判定、reset 後狀態歸零。
3. 補：握手階段（C0C1→S0S1→C2→S2）各自逾時（目前 CHANGES #56a 只做整體 connect
   timeout）。

---

## P2. `OutgoingStream` 執行緒安全（data race）

**狀態**：規劃中
**檔案**：`HaishinKit/Sources/Stream/OutgoingStream.swift`（必要時
`HaishinKit/Sources/Codec/VideoCodec.swift`）

**問題**：`OutgoingStream` 是 `@unchecked Sendable` 且**完全沒有鎖**。可變狀態
（`videoInputBufferCounts` / `videoInputBufferCountsOverridden` /
`observedVideoBytesPerFrame` / `_videoInputStream` / `videoInputContinuation` /
`videoInputFormat` / `audioInputFormat`）同時被：

- 擷取 / mixer 執行緒：`append(_:)`（寫 `observedVideoBytesPerFrame`、
  `videoInputFormat`、`audioInputFormat`，並 `yield`）。
- stream actor：`videoSettings` setter、`setVideoInputBufferCounts`、
  `prepareVideoInputStream`、`startRunning` / `stopRunning`。

具體風險：`_videoInputStream` 的 check-then-act 惰性建立若被兩處同時呼叫 → 建出兩條
stream、其中一個 continuation 變孤兒；`observedVideoBytesPerFrame` 跨執行緒讀寫。
另外 `VideoCodec.settings` 也沒有鎖（對比 `AudioCodec` 有 NSLock），其 didSet 會直接
apply VT session option。

**方向**：以單一鎖（或 `NSRecursiveLock`，注意 `videoInputContinuation` 的 didSet 會
在 `AsyncStream` init 的 closure 內被觸發，需避免非遞迴鎖自我死鎖）保護上述狀態；
`videoInputStream` 建立改為 double-checked locking。需在 Apple 端跑
`OutgoingStream` / `AudioRingBuffer` 相關測試 + Thread Sanitizer 驗證。
