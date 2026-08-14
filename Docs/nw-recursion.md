# NWConnection 遞迴 receive 模式

## 問題

`NWConnection.receive` 的 completion handler 內部直接呼叫 `self.receive(...)` 會造成潛在的 stack overflow。

### 危險模式

```swift
// ❌ 危險：callback 內直接同步遞迴
private func receive() {
    connection.receive(...) { data, _, _, _ in
        // ... 處理 data ...
        self.receive() // ← 如果 callback 同步觸發，stack 一直增長
    }
}
```

`NWConnection` 在資料已緩衝的情況下**可能同步呼叫 completion handler**，此時 `self.receive()` 等同於在當前 stack frame 上遞迴。當大量資料湧入（例如初始化階段的 batch 訊息）時，stack 在數毫秒內就會用盡，導致 `EXC_BAD_ACCESS / KERN_PROTECTION_FAILURE`。

### 影響範圍

- **ReplyKIT (擴展端)** — `SocketClient.receive()` 原本使用此模式
- **liveAPP (主 App)** — `SocketServer.receive(from:)` 原本使用此模式  
- **HaishinKitFixSwfit `MoQTSocket`** — `receive(on:continuation:)` 原本使用此模式

### ByteArray 泛型特化遞迴

另一個相關的遞迴問題發生在 Swift compiler 對 `ExpressibleByIntegerLiteral.init(data:)` 的泛型特化：

```
readUInt32()
  → UInt32(data: Data[...]) 
    → ExpressibleByIntegerLiteral.init(data: Data)  ← 泛型
      → Data.withUnsafeBytes<UInt32>                ← compiler 特化
        → ❌ 無限遞迴 (compiler bug?)
```

所有 `ByteArray.readUInt*()`/`readInt*()` 方法都經過此路徑。將 BigEndian 讀取改為直接 byte arithmetic 即可繞過。

### Crash 特徵

- Exception: `EXC_BAD_ACCESS / KERN_PROTECTION_FAILURE`
- Faulting thread 在 `com.apple.root.user-initiated-qos.cooperative` 佇列
- Stack depth 固定約 11,162 frames（544KB stack / ~49 bytes per frame）
- 發生在啟動初期 socket 大量資料交換時

## 修復方式

### 1. receive loop → async/await（第一次修正，2026）

```swift
// ✅ 安全：每次 iteration 經過 suspension point
private func runReceiveLoop() async {
    while !Task.isCancelled {
        let data = await withCheckedContinuation { continuation in
            connection.receive(...) { content, _, _, _ in
                continuation.resume(returning: content)
            }
        }
        guard let data else { break }
        process(data)
    }
}
```

**優點：** 每個 iteration 都有 suspension point，沒有同步遞迴，stack 有界。

**代價（後來才暴露）：**
- 每個 iteration 建立一個 `withCheckedThrowingContinuation`。
- **continuation 洩漏：** 若 `connection` 在 resume 前變成 `nil`（`close()` 與 receive 競態），`connection?.receive` 被靜默跳過，continuation 永遠不 resume → `recv()` 永久掛起，strict concurrency 下還會有 "leaked continuation" runtime trap。
- **取消困難：** `Task.cancel()` 無法 resume 一個 pending 的 `withCheckedContinuation`；只有 NWConnection 的 callback 才能。receive 的取消與 close 的 teardown 依賴 callback 恰好在 forceCancel 後觸發，脆弱。
- 與 send 側（`sendNextChunk → didSendChunk` 的 callback 遞迴）不對稱，receive 側是唯一的異類。

### 2. `withUnsafeBytes<UInt32>` 遞迴 → 直接 byte shift

```swift
// ❌ 危險：走 ExpressibleByIntegerLiteral
return UInt32(data: data[pos-4..<pos]).bigEndian

// ✅ 安全：直接 byte arithmetic  
let result = UInt32(data[pos]) << 24
           | UInt32(data[pos+1]) << 16
           | UInt32(data[pos+2]) << 8
           | UInt32(data[pos+3])
```

### 3. callback 遞迴 + actor hop（最終方案，2026-08）★

```swift
// ✅ 安全：callback 驅動，但每次 re-arm 都透過 actor hop 中斷同步遞迴
private func armNextReceive() {
    guard !isReceiveStopped, let connection else { return }
    connection.receive(...) { [weak self] content, _, _, error in
        guard let self else { return }
        Task { await self.didReceive(content: content, error: error) } // ← actor hop
    }
}

private func didReceive(content: Data?, error: NWError?) async {
    guard !isReceiveStopped else { return }
    if let error { isReceiveStopped = true; receiveContinuation?.finish(); return }
    if let content {
        totalBytesIn += content.count
        receiveContinuation?.yield(content)
    } else { isReceiveStopped = true; receiveContinuation?.finish(); return }
    guard connected else { receiveContinuation?.finish(); return }
    armNextReceive() // ← 在 actor 上重新 arm，非在 callback stack frame 內
}
```

**為什麼安全（不再 stack overflow）：**
- NWConnection 的 completion handler 在 `networkQueue` 上觸發後立即返回；實際處理（`didReceive`）透過 `Task { await ... }` hop 到 actor，**不在 completion handler 的 stack frame 內遞迴**。
- 每次 `armNextReceive` 都在一個新的 actor task 上執行，receive 之間有完整的 async boundary，stack 有界。
- 這保留了 callback 驅動（與 send 側對稱、每次恰好一個 outstanding receive），同時斷開了同步遞迴鏈。

**為什麼比 async/await loop 好：**
- **無 continuation 洩漏：** 完全沒有 `withCheckedThrowingContinuation`，receive 的生命週期由 `isReceiveStopped` flag + `receiveContinuation?.finish()` 決定，`close()` 是確定性 teardown。
- **取消即停止 re-arm：** `stopReceive()` 設 `isReceiveStopped = true`，下一次 callback 進來立即 `finish()` 並返回，不會再 arm。pending 的 receive 由 `connection = nil` 的 forceCancel 觸發 callback（帶 error）收尾。
- **與 send 側對稱：** 與 `sendNextChunk → didSendChunk → sendNextChunk` 完全一致的遞迴 callback 節奏。
- **每次恰好一個 outstanding receive：** 這是 NWConnection 期待的 contract，避免重複 arm。

**套用位置：** `RTMPHaishinKit/Sources/RTMP/RTMPSocket.swift`、`MoQTHaishinKit/Sources/MoQTSocket.swift`

## 受影響檔案

| 檔案 | 修改內容 |
|------|----------|
| `ReplyKIT/Socket.swift` | `receive()` → `runReceiveLoop()` async loop |
| `liveAPP/Socket.swift` | `receive(from:)` → `runReceiveLoop()` async loop |
| `MoQTHaishinKit/Sources/MoQTSocket.swift` | `receive(on:continuation:)` → `startReceiveLoop()` async loop（2026-08 再改為 callback 遞迴 + actor hop） |
| `RTMPHaishinKit/Sources/RTMP/RTMPSocket.swift` | 2026-08：async/await loop → callback 遞迴 + actor hop |
| `RTMPHaishinKit/Sources/Util/ByteArray.swift` | `UIntX(data:)` → direct byte arithmetic |
| `HaishinKit/Sources/Util/ByteArray.swift` | `UIntX(data:)` → direct byte arithmetic |

## 結論

- **同步遞迴**（方案 0）→ stack overflow，不可用。
- **async/await loop**（方案 1）→ stack 安全，但引入 continuation 洩漏與取消脆弱性。
- **callback 遞迴 + actor hop**（方案 3，最終）→ 同時得到 callback 驅動的正確性與有界 stack，是 NWConnection 的正確使用方式。
