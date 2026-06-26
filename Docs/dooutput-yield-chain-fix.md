# doOutput yield 鏈 stack overflow 修復與重構

## 問題

`RTMPStream.startOutputConsumer` 的 output pipeline 在 cooperative thread（544KB stack）上反覆觸發 `bug_type 309` crash。crash site 落在 `Data.InlineSlice.replaceSubrange`（chunk 編碼），但實際是 **cooperative thread 棧從未釋放** 造成 stack guard page 撞擊。

崩潰線索：

```
frame  0: Data.InlineSlice.replaceSubrange            ← crash site (chunk 編碼)
frame  1: Data._Representation.replaceSubrange
frame  2: RTMPDataF0V (AnyIterator<Data> closure)      ← putMessage 內
frame  3: RTMPVideoF0V                                 ← putMessage 內
frame  4: _ClosureBasedIterator.next()
frame  5: _IteratorBox.next()
frame  6: AnyIterator<Data> async thunk
frame  7: RTMPConnection.doOutput (entry_point)        ← connection.doOutput 入口
frame  8: RTMPAudioMessage async thunk                 ← doOutput closure
frame  9: Error.SendableRzs5NeverORs [RECUR x3]       ← 重入
frame 10: RTMPStream.startOutputConsumer closure
frame 11: Error.SendableRzs5NeverORs [RECUR x3]       ← 重入
```

## 根因：雙層 closure + 同步 yield 鏈

舊架構：

```
RTMPStream.append (actor, sync)
  └─ doOutput() → yield(@Sendable () async -> Int)     ← layer 1: yield closure
       └─ consumer: for-await output → await output()  ← cooperative thread, 同步
            └─ closure: await connection.doOutput(...)  ← 跨 actor boundary
                 └─ RTMPConnection.doOutput (actor)
                      ├─ Array(outputBuffer.putMessage(...))  ← chunk 編碼 (heavy, sync)
                      └─ outputContinuation.yield([Data])     ← layer 2: yield chunks
                           └─ consumer: socket.send(chunks)   ← 同步
```

核心問題：

1. **Closure 只是為了 defer actor boundary crossing**。`RTMPStream` 和 `RTMPConnection` 都是 actor，`doOutput` 無法直接 `await connection.doOutput()`，所以用 closure 包裝。這個 closure 本身沒做任何運算，純粹是間接層。

2. **`.bufferingOldest(128)`** 允許積壓 128 個 closure。當 consumer 追趕時，for-await 迴圈在**同一個 cooperative thread 棧**上連續執行所有 closure，每個 closure 內跑的 chunk 編碼（Data.replaceSubrange、Array allocation）持續疊棧。128 × ~5KB ≈ 640KB > 544KB stack limit。

3. **沒有棧隔離**。`mixer(_:didOutput:)` 路徑已用 `Task { yield() }` 打斷同步鏈，但 `doOutput` 路徑漏修。

## 修復

### 1. 去掉 closure 包裝 — 改用 concrete `Sendable` struct

```swift
// BEFORE
private typealias RTMPStreamOutput = @Sendable () async -> Int

// AFTER
private struct RTMPOutputItem: Sendable {
    let type: RTMPChunkType
    let chunkStreamId: RTMPChunkStreamId
    let message: any RTMPMessage
}
```

不再傳遞可執行的 closure，只傳遞純資料。consumer 端自行決定如何處理，不再需要解包黑盒子。

### 2. `doOutput` 簡化

```swift
// BEFORE: yield a closure that captures connection + message
outputContinuation?.yield { [connection] in
    await connection.doOutput(type: ..., chunkStreamId: ..., message: message)
}

// AFTER: yield plain data
outputContinuation?.yield(RTMPOutputItem(
    type: type, chunkStreamId: chunkStreamId, message: message
))
```

- 少了 closure capture context allocation
- 資料流透明，可 debug / 可 inspect
- `doOutput` 只需檢查 `connection != nil` 確保 pipeline 活著，不需要弱捕獲

### 3. consumer 用 `Task { }.value` 做棧隔離

```swift
// BEFORE: 所有 chunk 編碼在同一個任務棧上疊加
Task {
    for await output in stream {
        let length = await output()           // closure → chunk encoding, sync
        await appendByteCount(length)
    }
}

// AFTER: 每個 item 的 chunk 編碼跑在獨立 Task 棧上
Task { [weak self] in
    for await item in stream {
        guard let self else { return }
        let conn = await self.connection
        guard let conn else { continue }
        let length = await Task {             // ← 新棧，chunk 編碼在這裡
            await conn.doOutput(item.type, ...)
        }.value                               // ← outer suspend，棧釋放
        await self.appendByteCount(length)
    }
}
```

- `Task { await conn.doOutput(...) }.value`：child Task 建立 → outer suspend → child 在**獨立棧**執行 chunk 編碼 → child 完成 → outer resume（棧已清空）
- 每個 item 一個獨立棧 → 無論積壓多少，棧深恆定
- `[weak self]`：actor deinit 時 `outputContinuation.finish()` 會自然結束 stream，`guard let self` 只是安全網

### 4. buffer 策略調整

| 項目 | 舊值 | 新值 | 理由 |
|------|------|------|------|
| buffer 上限 | 128 | 64 | 記憶體減半 |
| 溢出策略 | `.bufferingOldest` | `.bufferingNewest` | 直播場景丟舊幀保新幀更合理 |

## 為什麼比之前更好

- **沒有 closure 間接層**：資料流從 producer → struct → consumer 一條線，不再 producer → closure → async closure → actor call。可讀性、可除錯性都提升。
- **不再依賴 `.bufferingOldest(N)` 做背壓**：舊設計靠 buffer 大小間接限制同步鏈長度（buffer 滿了 producer 阻塞）；新設計每個 item 獨立棧，buffer 只是緩衝區而非棧保護機制。
- **與 mixer 修復一致**：`mixer(_:didOutput:)` 用了 `Task { yield() }`，這裡用 `Task { doOutput() }.value` — 同樣的「用 Task 隔離棧」模式，全專案一致。
- **零效能回歸**：`any RTMPMessage` existential 的 boxing 開銷極小（closure capture context 也是 boxing）；64 個 pending item 的記憶體比 128 個 pending closure 更小。
