# 資料路徑設計問題與影響

> **日期**: 2026-06-24 | **涉及版本**: 1.3.x

---

## 目錄

1. [VideoCodec.outputStream 為 Computed Property](#1-videocodecoutputstream-為-computed-property)
2. [publish() 初始化順序導致 Race Condition](#2-publish-初始化順序導致-race-condition)
3. [斷線重連後無法自動 Republish](#3-斷線重連後無法自動-republish)
4. [AudioCodec 與 VideoCodec 輸出管理不一致](#4-audiocodec-與-videocodec-輸出管理不一致)
5. [總結](#5-總結)

---

## 1. VideoCodec.outputStream 為 Computed Property

**檔案**: `HaishinKit/Sources/Codec/VideoCodec.swift:22-26`

### 原始程式碼

```swift
var outputStream: AsyncStream<CMSampleBuffer> {
    AsyncStream { continuation in
        self.continuation = continuation
    }
}
```

### 問題

`outputStream` 是 **Computed Property**，每次存取都建立一個全新的 `AsyncStream`，並用新的 `continuation` 覆蓋舊的 `self.continuation`：

- 舊的 `continuation` **不會被 finish**，造成該 stream 上的 consumer 永遠懸掛等待
- 新的 stream 與舊的 consumer 無關，資料永遠到達不了消費者

### 影響

| 情境 | 影響 |
|------|------|
| `videoOutputStream` 被多次存取 | 只有最後一次存取的 consumer 收到資料，其餘永久飢餓 |
| Encoder 在 consumer 啟動前產出 frame | `_outputContinuation == nil`，frame 靜默丟棄 |
| 重連後重新建立 consumer task | 需要重新存取 `outputStream`，新舊 stream 銜接不連續 |

### 關鍵資料流

```
VideoCodec.append(frame)
  → guard let continuation else { return }  ← continuation 可能為 nil！
  → session.convert(..., continuation: continuation)
    → VTCompressionSession 回呼 continuation?.yield(compressedFrame)
      → 只有當 consumer 已開始迭代 stream 時，continuation 才存在
```

### 修復方式

改為 cached stored property + `startRunning()` 時主動初始化：

```swift
private var _outputContinuation: AsyncStream<CMSampleBuffer>.Continuation?
private var _outputStream: AsyncStream<CMSampleBuffer>?
var outputStream: AsyncStream<CMSampleBuffer> {
    if let _outputStream { return _outputStream }
    let (s, c) = AsyncStream<CMSampleBuffer>.makeStream()
    _outputContinuation = c; _outputStream = s
    return s
}
```

---

## 2. publish() 初始化順序導致 Race Condition

**檔案**: `RTMPHaishinKit/Sources/RTMP/RTMPStream.swift:401-418`

### 原始順序

```
readyState = .publishing
send("@setDataFrame", ...)
outgoing.startRunning()              // Step 1: Encoder 啟動
stopMixerInputConsumers()
startMixerInputConsumers()           // Step 2: Mixer 開始餵資料
tasks.append(Task {
    for await video in outgoing.videoOutputStream {  // Step 3: 才設定 continuation
        append(video)
    }
})
```

### 問題

Step 1 到 Step 3 之間存在時間窗口（即使只有幾微秒）：

```
Encoder 啟動
    ↓
Mixer 餵入 frame → Encoder 產出 → continuation == nil → 丟棄！
    ↓
Consumer task 終於開始迭代 → continuation 設定完成
    ↓
後續 frame 正常傳送
```

### 影響

- **第一個關鍵幀（IDR）可能遺失**：H.264/HEVC 串流若第一個 IDR frame 丟失，客戶端要等到下一個 GOP 才能開始解碼
- **Audio 第一個 AAC header 可能遺失**：雖然 `audioFormat.didSet` 會在 frame 到達時自動送出 header，但如果 frame 本身在 continuation nil 時就被丟棄，header 也不會觸發
- **Debug 困難**：行為不穩定，依賴於任務排程器的 timing

### 修復方式

在 `outgoing.startRunning()` 之前預先初始化 output streams：

```swift
let videoOutput = outgoing.videoOutputStream  // 預先建立 stream + continuation
let audioOutput = outgoing.audioOutputStream
outgoing.startRunning()                        // 此時 continuation 已就緒
```

---

## 3. 斷線重連後無法自動 Republish

**檔案**: `RTMPHaishinKit/Sources/RTMP/RTMPStream.swift`, `RTMPConnection.swift:440-446`

### 問題

`RTMPConnection` 的自動重連機制在成功重連後只做：

```swift
for stream in streams {
    await stream.dispatch(.reset)     // id=0, readyState=.idle
    await stream.createStream()       // 取得新 stream ID
}
```

但 **沒有重新呼叫 `publish()`**。Stream 停留在 `.idle` 狀態，造成：

1. `audioFormat`/`videoFormat` 的 `didSet` 檢查 `readyState == .publishing` → **format packet 不送**
2. 雖然 `doOutput` 本身不檢查 `readyState`，但 stream ID 已重置為新值，資料可能送到錯誤的串流
3. Encoder 在 `stream.close()` 時已被 stop，若無重新 publish 就不會重啟

### 影響

| 情境 | 結果 |
|------|------|
| 斷線重連後未 republish | Stream 停留在 `.idle`，無資料推送 |
| 有資料混入（任務未清理） | 資料使用錯誤 stream ID，伺服器拒絕或錯誤路由 |
| 使用者手動呼叫 `connect()` | 但不會自動呼叫 `publish()`，需自行監聽重連事件 |

### 修復方式

1. 在 `RTMPStream` 儲存最後的 publish name 與 type
2. 在 `close()` 時清除（使用者主動停止）
3. 新增 `resumePublishing()` 方法，在重連成功後由 `RTMPConnection` 自動呼叫

```swift
// RTMPConnection
for stream in streams {
    await stream.dispatch(.reset)
    await stream.createStream()
    await stream.resumePublishing()    // 自動 re-publish
}
```

---

## 4. AudioCodec 與 VideoCodec 輸出管理不一致

**檔案**: `HaishinKit/Sources/Codec/AudioCodec.swift:23` vs `VideoCodec.swift:22-26`

### 問題

兩個 Codec 使用完全不同的機制管理輸出 stream：

| 面向 | AudioCodec | VideoCodec |
|------|-----------|------------|
| 屬性包裝 | `@AsyncStreamedFlow` property wrapper | 手動 computed property |
| Continuation 管理 | `didSet` 自動 finish 舊的 | 直接覆蓋，遺棄舊的 |
| Yield 方式 | `_outputStream.yield(value)` | 傳遞 `continuation` 給 session.convert |
| Finish | `_outputStream.finish()` | `continuation?.finish()` |

### 影響

- VideoCodec 缺少 `@AsyncStreamedFlow` 提供的 `didSet { oldValue?.finish() }`，導致舊 consumer 被遺棄時無法正常終止
- 不一致的維護模式增加未來改動出錯的風險

### 建議

將 VideoCodec 改為與 AudioCodec 一致的 `@AsyncStreamedFlow` 模式，或至少統一 continuation 生命週期管理。

---

## 5. S2 封包檢測公式錯誤

**檔案**: `RTMPHaishinKit/Sources/RTMP/RTMPHandshake.swift:16-18`

### 問題

`hasS2Packet` 的公式完全錯誤，導致 handshake **永遠卡在 S2 等待階段**，connect command 永遠不會送出。

### 原始公式

```swift
var hasS2Packet: Bool {
    RTMPHandshake.sigSize <= inputBuffer.count - 1 - RTMPHandshake.sigSize
    // = 1536 <= inputBuffer.count - 1537
}
```

`c2packet()` 被呼叫後會從 `inputBuffer` 移除 S0（1 byte）+ S1（1536 bytes）。移除後 `inputBuffer` 只剩下 S2 資料（最多 1536 bytes）。

代入公式：`1536 <= inputBuffer.count - 1537`
- 要成立需要 `inputBuffer.count >= 3073`
- 但此時 `inputBuffer.count` 最多只有 1536（僅 S2）
- **結果永遠為 false**

### 影響

```
Client recv() 收到 S0+S1+S2 (同一個 TCP packet)
  → listen(.versionSent): handshake.put(data) → hasS0S1Packet = true
  → parseS0S1() 讀取 S0+S1
  → c2packet() 傳送 C2，並從 inputBuffer 移除 S0+S1
  → state = .ackSent
  → listen(.ackSent): handshake.put(Data()) // 空資料
  → hasS2Packet = false（公式錯誤！）
  → 回傳，繼續等待更多資料
  → 伺服端已送出 S2，正在等待 connect command
  → ⛔ 雙方 Deadlock！
  → 3s 後客戶端 requestTimeout → Error.requestTimedOut
  → close() → 伺服端 30s 後 "expect connect app response : timeout 30000 ms"
```

### 關鍵錯誤鏈

| 環節 | 結果 |
|------|------|
| 握手成功（S0+S1+S2 已完整收到） | ✅ |
| S2 檢測公式 bug | ❌ `hasS2Packet` 永遠 false |
| Handshake 無法 transition 到 `.handshakeDone` | ❌ |
| "connect" command 永不發送 | ❌ |
| 伺服端等待 30s 後 timeout | ❌ |
| 客戶端等待 3s 後 timeout | ❌ |

### 修復

```swift
// ✅ 正確：只需檢查 buffer 中是否有完整 S2 (1536 bytes)
var hasS2Packet: Bool {
    RTMPHandshake.sigSize <= inputBuffer.count
}
```

---

---

## 6. E-RTMP 相容性設置

**檔案**: `RTMPHaishinKit/Sources/RTMP/RTMPConnection.swift:292-323`

### 問題

SRS 等部分 RTMP 伺服器不支援 E-RTMP（Enhanced RTMP）的擴充欄位，收到 `connect` command 中的 `fourCcList`、`capsEx`、`videoFourCcInfoMap`、`audioFourCcInfoMap` 等欄位時會直接拒絕連線。

SRS log 表現為 connect 成功後立即 `on_close`，無明確錯誤訊息。

### 使用方式

```swift
// 對不支援 E-RTMP 的伺服器（如 SRS），設為 false
let connection = RTMPConnection(
    useEnhancedRTMP: false,
    isReconnectEnabled: true
)
```

`useEnhancedRTMP: false` 等效於：

```swift
RTMPConnection(
    fourCcList: nil,
    videoFourCcInfoMap: nil,
    audioFourCcInfoMap: nil,
    capsEx: 0
)
```

### 效果

| 設定 | `fourCcList` | `videoFourCcInfoMap` | `audioFourCcInfoMap` | `capsEx` |
|------|-------------|---------------------|---------------------|---------|
| `true`（預設） | `["hvc1","opus"]` | `canDecode\|canEncode` | `canEncode` | `0x01` |
| `false` | `nil` | `nil` | `nil` | `0` |

### 何時需要關閉

- 使用 SRS、Nginx-RTMP 等傳統 RTMP 伺服器
- 伺服器回傳 `NetConnection.Connect.Failed` 但無詳細描述
- SRS log 看到 connect 後立即被 `on_close`

### 設計考量

`useEnhancedRTMP` 只影響**初始預設值**。若需要個別微調，仍可直接傳入 `fourCcList`/`capsEx` 等參數，它們的優先級高於 `useEnhancedRTMP`：

```swift
// 關閉 E-RTMP 但只開 HEVC 編碼器協商
RTMPConnection(
    useEnhancedRTMP: false,
    fourCcList: ["hvc1"]  // 明確傳入就會生效
)
```

### `capsEx: 0` 仍可能造成 SRS timeout

**檔案**: `RTMPHaishinKit/Sources/RTMP/RTMPConnection.swift:725`

即使 `useEnhancedRTMP: false` 將 `capsEx` 設為 `0`，但原本的程式碼**仍會**將 `capsEx: 0` 寫入 connect command 的 AMF Object：

```swift
commandObject["capsEx"] = capsEx  // capsEx = 0 時仍送出
```

部分 SRS 版本遇到不認識的 `capsEx` 欄位時，即使值為 `0`，仍可能導致：
1. AMF 解析異常 → SRS 無法辨識這個連線請求為有效的 connect command
2. SRS 進入 `identify_client` 等待更多資料 → 30 秒後 timeout
3. Client 端也因收不到 `_result`/`_error` 在 3 秒後 timeout

SRS log 表現為：
```
recv identify message : read basic header : timeout 30000 ms
```

#### 修復

```swift
// 只有當 capsEx > 0 時才送出，避免干擾不支援的伺服器
if 0 < capsEx {
    commandObject["capsEx"] = capsEx
}
```

#### 驗證方式

| 測試條件 | SRS log 結果 | 連線 |
|---------|-------------|------|
| E-RTMP 開啟 + `capsEx: 1`（修正前） | `connect app, tcUrl=...` + 立即 `on_close` | ❌ |
| E-RTMP 關閉 + `capsEx: 0` **仍送出**（修正前） | `timeout 30000 ms`，無 `connect app` log | ❌ |
| E-RTMP 關閉 + `capsEx` 不送出（修正後） | 待測試 | ❓ |
| E-RTMP 完全關閉 `useEnhancedRTMP: false`（修正後） | 待測試 | ❓ |

---

## 7. 診斷日誌接口

**新增檔案**: `RTMPHaishinKit/Sources/RTMP/RTMPLogEvent.swift`  
**修改檔案**: `RTMPConnection.swift`, `RTMPSocket.swift`

### 設計目標

讓 ReplyKit 可以**即時取得 HaishinKit 內部完整運行情況**，而不需要依賴 Xcode 主控台或 macOS Console.app。

### API


> [!TIP]
> setOnLog裡內部呼叫 如果使用到是全局共用件之類的
> 
> 不是限於class裡的東西 不需要捕獲self 

```swift
// event.level: .trace / .debug / .info / .warn / .error
// event.message: 簡短描述（如 "State: versionSent => ackSent"）
// event.detail: 詳細資料（如 "totalBytesIn=3461 totalBytesOut=3962"，可能為 nil）
// event.timestamp: 事件時間
// event.file / event.line: 原始碼位置

// 在 async 函式中：直接 await
await connection.setOnLog { [weak self] event in
    self?.send("[RTMP] \(event.level) \(event.message) \(event.detail ?? "")")
}

// 不在 async 上下文中：用 Task 包裹
Task {
    await connection.setOnLog { [weak self] event in
        self?.send("[RTMP] \(event.level) \(event.message) \(event.detail ?? "")")
    }
}
```

### 提供的診斷事件

| 位置 | 事件 | 時機 |
|------|------|------|
| `RTMPConnection.state.didSet` | `State: old => new` | 每次連線狀態轉換 |
| `performConnect` | `TCP connecting` | TCP 連線前 |
| | `TCP connect failed` | TCP 連線失敗 |
| | `TCP connected, sending C0C1` | TCP 連線成功 |
| | `S0S1 received, sending C2` | 收到伺服器握手回應 |
| | `S2 received, handshake done` | 握手完成 |
| | `Connect success` | 收到 `_result` |
| | `Connect failed` | 收到 `_error` |
| `close()` | `Close requested` | 連線關閉 |
| `RTMPSocket.stateDidChange` | `Socket ready` | NWConnection 就緒 |
| | `Socket waiting` | NWConnection 等待中 |
| | `Socket failed` | NWConnection 失敗 |
| | `Socket cancelled` | NWConnection 取消 |
| `send()` | `Socket send` | 每次發送資料 (含 size/queue) |
| | `Send dropped: not connected` | 未連線時嘗試發送 |
| | `Backpressure: ...` | 發送佇列滿 |
| `close()` | `Socket close` | Socket 關閉 (含 bytes in/out) |
| `recv()` | `recv error` | 接收錯誤 |

### 使用方式

```swift
let connection = RTMPConnection(useEnhancedRTMP: false)

await connection.setOnLog { event in
    // 透過 ReplyKit Socket 送回主 app 顯示
    await ReplyKitSocket.shared.send([
        "level": "\(event.level)",
        "message": event.message,
        "detail": event.detail ?? "",
        "time": event.timestamp.timeIntervalSince1970
    ])
}

connection.onReconnectStateChanged = { state in
    // 處理重連
}
```

### HaishinKit 版本識別

```swift
// 連線時自動輸出診斷 log：
// [RTMP] info HaishinKit revision rev=3481fce

// 可在任何地方讀取目前編譯的版本：
let rev = kHaishinKitRevision  // "3481fce"
```

CI 流程（`.github/workflows/build.yml`）會自動：
1. `xcodebuild -resolvePackageDependencies` 解析最新相依套件
2. 從 `Package.resolved` 提取 `revision` hash
3. 寫入 `Constants.swift` 的 `kHaishinKitRevision`
4. 建置時該常數即反映真實使用的 commit

---

## 8. Chunk Header 3-byte Big-Endian 讀取錯誤

**檔案**: `RTMPHaishinKit/Sources/RTMP/RTMPChunk.swift:212-230`

### 問題

`getMessageHeader()` 中使用 `UInt32(data: data[a..<b]).bigEndian` 來讀取 3-byte 的 big-endian 整數（時間戳與訊息長度），但這個公式在 **little-endian 架構（所有 Apple 裝置）上完全錯誤**。

### 數學分析

```
Wire 3 bytes (big-endian):  [0x00, 0x01, 0x90]  → 實際值 = 0x190 = 400

UInt32(data:) 在 LE 機器上：
  → bytes[0]=0x00, bytes[1]=0x01, bytes[2]=0x90, bytes[3]=0x00
  → LE numeric value = 0x00900100

.bigEndian (byte swap):
  → 0x00900100 → 0x00019000 = 102400 ❌ (256 倍！)
  
正確讀法：
  → UInt32(data[p]) << 16 | UInt32(data[p+1]) << 8 | UInt32(data[p+2])
  → 0x00 << 16 | 0x01 << 8 | 0x90 = 400 ✅
```

### 影響

| 欄位 | Wire 上為 3 bytes BE | 被誤讀為 | 實際應為 | 倍率 |
|------|---------------------|---------|---------|------|
| `messageLength` | `[0x00,0x00,0x50]` (= 80) | 20480 | 80 | 256x |
| `timestamp` | `[0x00,0x00,0x01]` (= 1ms) | 256 | 1 | 256x |

### 連鎖反應

```
SRS 回應 889 bytes（含 _result + 控制訊息）
  → Type0 chunk header 讀取 messageLength = 實際值 × 256
    → 例如 80 bytes → 讀成 20480 bytes
  → payload 被 allocate 20KB（但 buffer 只有 889 bytes）
  → put() 拷貝 128 bytes → 續傳 chunk 拷貝 128 bytes → ...
  → 幾次續傳後 bufferUnderflow（buffer 已讀完）
  → makeMessage() 永遠不回傳（position < payload.count）
  → _result 永遠不會被 dispatch
  → Connect 的 continuation 永不 resolved
  → 30 秒後 SRS timeout → 關連線
  → Client 收到 endOfStream → close() 回拋 Connect.Failed
```

### SRS 端與 Client 端 log 交叉比對

| SRS log | Client log | 意義 |
|---------|-----------|------|
| `simple handshake success` | `Socket recv size=3073` | 握手完成 |
| `connect app, tcUrl=...` | `State: ackSent => handshakeDone` | Connect command 送出 |
| `send_bytes=3962` (含回應) | `Socket recv size=16 + 873` | SRS 回應已收到 |
| **`timeout 30000 ms`** | `Chunk header type=0 streamId=3` → `streamId=64`... | Chunk 解析崩潰！ |
| | `endOfStream` → `Connect.Failed` | 30 秒後 timeout |

### 為什麼 `streamId=64` 和 `46` 會出現？

因為 messageLength 被放大 256 倍後，payload 永遠無法讀完。buffer 內的資料被當成 chunk header 來解析，AMF payload 的二進位資料被誤認為 chunk type/streamId，產生了 stream 64、46 等不存在的串流 ID。

### 修復

```swift
// ❌ 錯誤（3-byte BE on LE machine）
let rawTimestamp = UInt32(data: data[p..<p+3]).bigEndian
messageHeader.messageLength = Int(Int32(data: data[p+3..<p+6]).bigEndian)

// ✅ 正確
let rawTimestamp = UInt32(data[p]) << 16 | UInt32(data[p+1]) << 8 | UInt32(data[p+2])
messageHeader.messageLength = Int(Int32(data[p+3]) << 16 | Int32(data[p+4]) << 8 | Int32(data[p+5]))
```

### 受影響的讀取點

| 行號 | 欄位 | 位元組數 | Wire Endian | 修正前 |
|------|------|---------|------------|--------|
| 212, 220, 227 | timestamp | 3 | Big | ❌ `data[...].bigEndian` |
| 215, 223 | messageLength | 3 | Big | ❌ `data[...].bigEndian` |
| 239 | extended timestamp | 4 | Big | ✅ 4-byte 是對的 |
| 217 | messageStreamId | 4 | Little | ✅ 沒有 `.bigEndian` 正確 |

---

## 9. 總結

### 問題嚴重性

| # | 問題 | 嚴重性 | 影響範圍 | 類別 |
|---|------|--------|----------|------|
| 0 | S2 封包檢測公式錯誤 | 🔴 致命 | **所有 RTMP 連線** | 協定層 |
| 🔥 1 | **Chunk 3-byte BE 讀取錯誤** | 🔴 致命 | **所有 RTMP 連線** | 協定層 |
| 2 | VideoCodec.outputStream computed property | 🔴 高 | 所有 H.264/HEVC 串流 | 資料路徑 |
| 3 | publish() 順序 race condition | 🔴 高 | 所有 publish 串流 | 資料路徑 |
| 4 | 重連後無法 auto-republish | 🔴 高 | 啟用自動重連的場景 | 生命週期 |
| 5 | AudioCodec/VideoCodec 不一致 | 🟡 中 | 維護性與擴展性 | 架構 |
| 6 | E-RTMP 相容性（含 `capsEx: 0` bug） | 🟡 中 | 不支援 E-RTMP 的伺服器 | 相容性 |

### 修復狀態

| # | 修復 | 檔案 |
|---|------|------|
| 0 | ✅ `inputBuffer.count - 1 - sigSize` → `inputBuffer.count` | `RTMPHandshake.swift` |
| 🔥 1 | ✅ `UInt32(data:...).bigEndian` → 手動 shift | `RTMPChunk.swift` |
| 2 | ✅ cached stored + startRunning 預先初始化 | `VideoCodec.swift` |
| 3 | ✅ 在 startRunning 前預先讀取 stream | `RTMPStream.swift` |
| 4 | ✅ lastPublishName + resumePublishing() | `RTMPStream.swift`, `RTMPConnection.swift` |
| 5 | ⏳ 待統一至 @AsyncStreamedFlow | `VideoCodec.swift` |
| 6 | ✅ `useEnhancedRTMP` 開關 + `capsEx` 條件式送出 | `RTMPConnection.swift` |
| 7 | ✅ 診斷日誌 `RTMPLogEvent` + `onLog` | `RTMPLogEvent.swift`, `RTMPConnection.swift`, `RTMPSocket.swift` |

### 建議測試項目

1. 模擬 encoder 輸出與 consumer task 啟動之間的競爭條件
2. 斷線重連後驗證 format packet（AVC sequence header）正確送出
3. 長時間串流測試，確認無 frame 因 continuation nil 而丟棄
4. 驗證 handshake S2 檢測：C0C1 → S0S1S2 → C2 → connect command 完整流程
5. 分別測試 `useEnhancedRTMP: true/false` 連線 SRS/Nginx 伺服器
6. 啟用 `onLog` 回呼驗證完整連線生命週期事件鏈
