# RTMP Socket 底層設計缺陷分析

## 概述

本文檔詳細分析 `RTMPSocket` 及其相關層（`RTMPConnection`、`RTMPStream`）中的關鍵設計缺陷，這些缺陷會導致首次推流失敗、效能異常、記憶體洩漏及網路連線不穩定。

---

## 缺陷一：接收緩衝區過小（`windowSizeC = 255`）

**檔案位置：** `RTMPHaishinKit/Sources/RTMP/RTMPSocket.swift:6`

**原始碼：**
```swift
static let defaultWindowSizeC = Int(UInt8.max)  // = 255
```

**問題：**
`windowSizeC` 用作 `NWConnection.receive(maximumLength:)` 的參數，限制每次 read 最大讀取 255 bytes。對於 RTMP 串流：
- 一個 H.264 keyframe 可能 50~200KB → 需要 **200~800 次 read 調用**
- 每次 read 涉及 actor hop → `withCheckedThrowingContinuation` → NWConnection callback → resume → chunk 解析
- 極高 CPU 開銷，低吞吐量

**修正：**
改為 `Int(UInt16.max)` = 65535，提升約 256 倍。

---

## 缺陷二：Output Task 首次錯誤即永久死亡 → 無界記憶體洩漏

**檔案位置：** `RTMPHaishinKit/Sources/RTMP/RTMPSocket.swift:150-156`

**原始碼：**
```swift
Task {
    for await data in stream where connected {
        try await send(data)   // 一旦拋錯，Task 直接終止，無人消費 stream
        ...
    }
}
```

**問題：**
- `try await send(data)` 拋出錯誤時，Task 直接終止
- `outputs` 的 `AsyncStream` 是 **unbounded**，且 continuation 仍然存活
- 後續所有 `send()` 呼叫 yield 的資料**永遠堆積在記憶體中** → 無界成長直到 OOM
- `queueBytesOut` 再也無法扣減，網路監控報告錯誤

**修正：**
- 加入 `do-catch`，錯誤時呼叫 `close()` 清理資源
- 用 `guard connected else { break }` 取代 `where connected` filter
- 確保錯誤時 `outputs` continuation 被 finish

---

## 缺陷三：Viability 下降立即關閉連線

**檔案位置：** `RTMPHaishinKit/Sources/RTMP/RTMPSocket.swift:178-183`

**原始碼：**
```swift
if viability == false {
    close()
}
```

**問題：**
`NWConnection` 在網路切換（WiFi→5G、暫時斷線）時會先觸發 `viability=false`，但之後可能自動恢復。**立即關閉** 斷送了 NWConnection 框架的內建恢復能力。這也是首次推流遇到短暫網路抖動就永久失敗的原因之一。

**修正：**
- 移除 `close()` 呼叫，僅記錄日誌
- 讓 `NWConnection` 的 state machine 處理恢復（`.failed` / `.cancelled` 才真正關閉）

---

## 缺陷四：`recv()` AsyncStream 在正常退出時未 finish Continuation

**檔案位置：** `RTMPHaishinKit/Sources/RTMP/RTMPSocket.swift:114-128`

**原始碼：**
```swift
while connected {
    let data = try await recv()
    ...
}
// while 退出後 continuation 未 finish
```

**問題：**
當 `connected` 在兩次 `recv()` 迭代之間被設為 `false`，`while` 迴圈退出，但 AsyncStream continuation 未被 finish。`RTMPConnection` 的 `for await data in await socket.recv()` 會**永久掛起**，導致連線無法正常關閉。

**修正：**
- 加入 `defer { continuation.finish() }` 確保無論如何都會 finish

---

## 缺陷五：`recv()` Task 正常路徑不 Finish Continuation

與缺陷四同源。正常退出 `while` 時 catch 不走，continuation 永遠 open。導致 `RTMPConnection.listen()` for-await 無法退出。

---

## 缺陷六：Lazy Stream 導致 `createStream()` 從未被調用

**檔案位置：** `RTMPHaishinKit/Sources/RTMP/RTMPSession.swift:30-37`, `RTMPConnection.swift:365-368`

**問題流程：**
1. `RTMPSession.connect()` 先調用 `connection.connect(command)`
2. `RTMPConnection.connect()` 連線成功後遍歷 `streams` 陣列呼叫 `createStream()`
3. 但此時 `RTMPSession._stream` 是 **lazy property**，尚未初始化，不在 `streams` 陣列中
4. `_stream.publish()` 才觸發 lazy init
5. `RTMPStream.init()` 的 Task 依賴 `connection.connected` 的時間差

**結果：**
Stream ID 保持為 `0`，publish 指令使用錯誤的 stream ID，伺服器拒絕或 `NetStream.Publish.Start` 永遠不回，導致 publish 卡住超時。

---

## 缺陷七：三層 AsyncStream 無背壓

**資料路徑：**
```
RTMPStream.outputContinuation (closure)
  → RTMPConnection.outputContinuation ([Data])
    → RTMPSocket.outputs (Data)
      → NWConnection.send()
```

每層都是 unbounded AsyncStream，沒有任何背壓。編碼器生產速度快於網路發送時，資料在緩衝區無限堆積，高碼率長時間推流可能 OOM。

---

## 缺陷八：Weak Connection Reference 可能丟失資料

**檔案位置：** `RTMPHaishinKit/Sources/RTMP/RTMPStream.swift:562-566`

```swift
func doOutput(...) {
    let connection = connection  // weak ref
    outputContinuation?.yield {
        await connection?.doOutput(...) ?? 0  // 若 connection 已釋放，資料靜默丟失
    }
}
```

`RTMPConnection` 可能在 closure 執行前被 dealloc，導致資料消失。

---

## 缺陷九：`connected` 狀態後停止解析 RTMP 回包

**檔案位置：** `RTMPHaishinKit/Sources/RTMP/RTMPConnection.swift:658`

### 問題流程

1. TCP、RTMP handshake、`connect` command 都成功。
2. server 回 `NetConnection.Connect.Success` 的 `_result txn=1`。
3. `RTMPConnection.dispatch()` 將狀態由 `.handshakeDone` 改成 `.connected`。
4. 後續 `createStream` command 正常送出，例如 log 出現：

```text
[RTMP] debug Command sent cmd=createStream txn=2
```

5. 但 `listen(_:)` 原本只在 `.handshakeDone` case 解析 RTMP chunk。狀態變成 `.connected` 後，socket 收到的資料落入 `default: break`，沒有進入 `inputBuffer.put(data)`，也不會 dispatch `_result txn=2`。
6. caller 最後只看到 timeout：

```text
[RTMP] error Command timeout cmd=createStream txn=2
[RTMP] error createStream: failed requestTimedOut
[RTMP] error publish: stream id is 0 after createStream
```

### 影響

- NetConnection 已成功，但 NetStream 永遠無法取得 stream id。
- ReplyKit / Broadcast Extension 前段仍持續產生音視訊 frame，看起來 MediaMixer 正常，但 RTMP 內部 publish 管線沒有建立。
- 伺服器即使回了 `createStream` 的 `_result`，client 端也會忽略，造成誤判為伺服器未回應。

### 修正

讓 `listen(_:)` 在 `.connected` 狀態下也持續解析 RTMP chunk：

```swift
case .handshakeDone, .connected:
    inputBuffer.put(data)
    ...
```

修正後，預期 log 順序為：

```text
[RTMP] debug Command sent cmd=createStream txn=2
[RTMP] info Response: _result txn=2
[RTMP] info createStream: stream id 1
```

---

## 缺陷十：RTMP chunk 逐片 enqueue/send 造成 socket 層高頻發送

**檔案位置：** `RTMPHaishinKit/Sources/RTMP/RTMPSocket.swift`

### 問題流程

`RTMPConnection.doOutput()` 會把一個 RTMP message 切成多個 chunk，再透過 `[Data]` 送到 socket 層。原本 `RTMPSocket.send(_ chunks:)` 對每個 chunk 都呼叫一次 `outputs.yield(data)`，output task 再對每個 chunk 執行一次 `NWConnection.send`。

對大型 video frame，尤其是 keyframe，這會造成：

- 單一 RTMP message 被拆成大量 socket send operation。
- actor hop、AsyncStream enqueue、NWConnection completion callback 數量放大。
- `queueBytesOut` 只用目前佇列大小判斷，沒有把即將加入的 `data.count` 算進去，可能超過上限才被發現。
- `AsyncStream.Continuation.yield` 若因 `.bufferingOldest` 丟資料或 stream 已終止，原本沒有修正 queue 統計。
- `totalBytesOut` 在 enqueue 與實際 send 完成時都累加，導致 throughput/佇列診斷數字失真。

### 影響

- 高碼率或 keyframe 期間 CPU 與 callback 壓力偏高。
- socket backpressure 指標可能漂移，導致誤判網路塞車或錯過真正壅塞。
- throughput log 可能被 double count 汙染，不利於判斷 RTMP 管線是否真的有送出資料。

### 修正

- `send(_ chunks:)` 先把同一個 RTMP message 的 chunks 合併成單一 `Data`，再 enqueue 一次。
- `send(_ iterator:)` 同樣合併後 enqueue，避免 iterator 逐片送出。
- 新增共用 `enqueue(_:)`：
  - 空資料直接忽略。
  - backpressure 改為檢查 `queueBytesOut + data.count <= maxQueueBytesOut`。
  - 依 `yield` 結果處理 `.enqueued`、`.dropped`、`.terminated`，同步修正 `queueBytesOut`。
  - `totalBytesOut` 只在 `NWConnection.send` 完成後累加。
- `recv()` 的 `minimumIncompleteLength` 由 `0` 改為 `1`，避免空 read 路徑帶來不必要迴圈。

### 後續可再優化

目前修正把 coalescing 放在 socket 層，已能大幅減少 `NWConnection.send` 次數。更進一步可以讓 `RTMPConnection.doOutput()` 直接產生單一 payload，避免先建立 `[Data]` 後再合併造成一次額外 copy。

---

## 總結

| 優先級 | 缺陷 | 影響 | 狀態 |
|--------|------|------|------|
| 🔥 Critical | `windowSizeC=255` 接收緩衝區過小 | 高 CPU、低吞吐、首次連接慢 | ✅ 已修 |
| 🔥 Critical | output Task 死亡不清理 | 推流一段時間後 OOM | ✅ 已修 |
| 🔴 High | viability 下降立即關閉 | 短暫抖動就斷連，無法恢復 | ✅ 已修 |
| 🔴 High | `recv()` continuation 未 finish | 連線無法正常關閉，hang | ✅ 已修 |
| 🔴 High | lazy stream createStream 遺漏 | 首次推流失敗 | ✅ 已修 |
| 🔴 High | connected 後停止解析 RTMP 回包 | createStream timeout、publish 管線無法建立 | ✅ 已修 |
| 🟡 Medium | 三層 AsyncStream 無背壓 | 高碼率記憶體爆炸 | ✅ 已修 |
| 🟡 Medium | RTMP chunks 逐片 socket send | 高 CPU、callback 放大、佇列統計漂移 | ✅ 已修 |
| 🟡 Medium | weak ref 資料丟失 | 推流資料不完整 | ✅ 已修 |

### 本次新增修正

| 優先級 | 缺陷 | 影響 |
|--------|------|------|
| 🔥 Critical | recv() 錯誤時無限迴圈 | 斷線後 CPU 100%，無法清理 |
| 🔥 Critical | close() 未清理所有 pending operations | 部分 caller 永久 hang |
| 🔴 High | connect 失敗 output continuation 未清理 | Task zombie |
| 🔴 High | shared continuation 覆寫 | 前一 operation 遺漏 |
| 🔴 High | publish() fire-and-forget Task | 資源洩漏 |
| 🟡 Medium | C1 timestamp=0 / C2 epoch time | 協定違規、2038 overflow |
| 🟡 Medium | hasS0S1Packet off-by-one | S0S1 單獨到時判斷不準 |

## 相關檔案

- [Changes.md](../Changes.md) - 變更記錄
- [Network Layer](NETWORK_LAYER.md) - 網路層文檔
- [RTMP Protocol](RTMP_PROTOCOL.md) - RTMP 協議實現
