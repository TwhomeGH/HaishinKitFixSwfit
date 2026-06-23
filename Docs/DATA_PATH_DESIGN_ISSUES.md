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

## 6. 總結

### 問題嚴重性

| # | 問題 | 嚴重性 | 影響範圍 | 類別 |
|---|------|--------|----------|------|
| 0 | S2 封包檢測公式錯誤 | 🔴 致命 | **所有 RTMP 連線** | 協定層 |
| 1 | VideoCodec.outputStream computed property | 🔴 高 | 所有 H.264/HEVC 串流 | 資料路徑 |
| 2 | publish() 順序 race condition | 🔴 高 | 所有 publish 串流 | 資料路徑 |
| 3 | 重連後無法 auto-republish | 🔴 高 | 啟用自動重連的場景 | 生命週期 |
| 4 | AudioCodec/VideoCodec 不一致 | 🟡 中 | 維護性與擴展性 | 架構 |

### 修復狀態

| # | 修復 | 檔案 |
|---|------|------|
| 0 | ✅ `inputBuffer.count - 1 - sigSize` → `inputBuffer.count` | `RTMPHandshake.swift` |
| 1 | ✅ cached stored + startRunning 預先初始化 | `VideoCodec.swift` |
| 2 | ✅ 在 startRunning 前預先讀取 stream | `RTMPStream.swift` |
| 3 | ✅ lastPublishName + resumePublishing() | `RTMPStream.swift`, `RTMPConnection.swift` |
| 4 | ⏳ 待統一至 @AsyncStreamedFlow | `VideoCodec.swift` |

### 建議測試項目

1. 模擬 encoder 輸出與 consumer task 啟動之間的競爭條件
2. 斷線重連後驗證 format packet（AVC sequence header）正確送出
3. 長時間串流測試，確認無 frame 因 continuation nil 而丟棄
4. 驗證 handshake S2 檢測：C0C1 → S0S1S2 → C2 → connect command 完整流程
