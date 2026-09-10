# 錄影轉送（Recording Forwarding）— 設計與待接計畫

> 狀態：**HaishinKit 端 API 草案已實作（B + C）；A（tap）與 ReplyKit 橋尚未接**。
> 本文記錄設計與後續步驟，留待要接上時實作。

## 背景 / 問題

`StreamRecorder` 用 `AVAssetWriter` 把混合後的樣本寫成本地 mp4/mov。預設存到
`$documentDirectory`。問題出在 **ReplayKit broadcast extension**：

1. **只有 extension 拿得到 sample buffer**（螢幕擷取在 extension 內），主 App 拿不到。
2. extension 的 container **對使用者與主 App 都不可見**（尤其側載 build，沒有
   `group.nuclear.liveAPP` App Group container；判定見 ReplyKit
   `RPConfig.isSideload = containerURL(...) == nil`）。

所以「在 extension 錄影、存到使用者看得到的位置」一定要**把資料送回主 App**。

## 兩層設計

### Tier 1 — 有 App Group（正常 build）

`StreamRecorder.startRecording(_ url:)` 本來就吃 URL，直接指向 App Group container：

```swift
let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.nuclear.liveAPP")!
try await recorder.startRecording(dir.appendingPathComponent("rec.mp4"))
```

主 App 讀同一個 container → 存到 Files/相簿。**不需要橋。**

### Tier 2 — 側載（無 App Group）

extension 錄到自己的 container（主 App 讀不到）→ 由一個**橋**把資料持續送給主 App，
主 App 寫到 `Documents/Recordings/`（與 log.txt 同層、Files 可見）。

**是「持續 append」不是「停止才搬檔」**：錄影本質是樣本串流。extension 每收到一個
（編碼後）sample buffer 就送一筆；主 App 邊收邊寫。

## HaishinKit 端 API（已實作草案）

### C. `StreamRecorderSink` — sink 抽象

`HaishinKit/Sources/Stream/StreamRecorderSink.swift`

```swift
public protocol StreamRecorderSink: Sendable {
    func write(_ sampleBuffer: CMSampleBuffer) async   // 依序、不並發
    func finish() async
}
```

`StreamRecorder` 新增 sink 模式（`HaishinKit/Sources/Stream/StreamRecorder.swift`）：

```swift
public func startRecording(to sink: any StreamRecorderSink) async throws
public func stopRecordingToSink() async throws
```

- sink 模式**不走 AVAssetWriter**，把每個 sample 轉給 sink；檔案模式完全不變。
- extension 的 sink = 送 E-Socket；主 App 的 sink = 餵 `StreamRecorder` 寫檔。

### B. `CMSampleBufferCodec` — 序列化

`HaishinKit/Sources/Extension/CMSampleBufferCodec.swift`

```swift
public enum CMSampleBufferCodec {
    public static let version: UInt8 = 1
    public static func encode(_ sampleBuffer: CMSampleBuffer) -> Data?
    public static func decode(_ data: Data) -> CMSampleBuffer?
}
```

Wire 格式（全 big-endian、開頭版本 byte，可演進）：

```
version:u8
mediaType:u8            // 0=video, 1=audio, 2=other
pts: i64 value, i32 timescale, i32 flags
duration: i64 value, i32 timescale, i32 flags
isSync:u8
sampleCount:u32
formatDescription:
  video: codec:u32(FourCC), width:u32, height:u32, atomCount:u32,
         [keyLen:u32, key, valLen:u32, val]*   // avcC / hvcC …
  audio: sampleRate:u64(bitPattern), formatID:u32, formatFlags:u32,
         bytesPerPacket:u32, framesPerPacket:u32, bytesPerFrame:u32,
         channelsPerFrame:u32, bitsPerChannel:u32, cookieLen:u32, cookie
dataLen:u32
data
```

**不帶任意 attachments**（只保留 `NotSync` 旗標）；HDR/rotation 等 metadata 未帶。

## 待接（A）與 ReplyKit 橋

### A. Tap 點（尚未決定）

- **編碼後**：`RTMPStream` 是 `StreamConvertible`，用 `StreamOutput` tap H.264/AAC
  樣本 → 資料小、直接可寫 MP4（**建議**）。
- **原始混合**：`MediaMixerOutput` → PCM/raw video，資料大。

### ReplyKit 橋（尚未實作）

1. **二進位分幀**：E-Socket 目前是 JSON；影片是二進位 → 新增
   `recordingStart` / `recordingSample` / `recordingEnd`（長度前綴），不要 base64。
2. **主 App 落檔**：收到 sample → `CMSampleBufferCodec.decode` →
   `StreamRecorder`（檔案模式）append 到 `Documents/Recordings/`。
3. **失敗處理**：斷線續傳、分塊 ack、逾時重送、extension 被砍後的殘檔（可用
   `StreamRecorder.setMovieFragmentInterval` 讓主 App 的檔可續）。

## 開放問題

- sink 模式的 consumer loop 目前直接 `await sink.write`，慢 sink（socket）會佔住
  `StreamRecorder` actor。需要時改成獨立 queue/緩衝。
- codec 的格式描述重建尚未真機驗證（只有 parse 過）；需 CI round-trip 測試 + 真機。
- 續傳/ack 第一版先不做，求能通。

## 後續步驟

1. 補 `CMSampleBufferCodec` round-trip 單元測試（CI）。
2. 決定 A（編碼後 vs 原始）。
3. 實作 ReplyKit 端二進位分幀 + 主 App 落檔。
4. 補續傳/失敗處理。

## 相關檔案

- `HaishinKit/Sources/Stream/StreamRecorder.swift`
- `HaishinKit/Sources/Stream/StreamRecorderSink.swift`
- `HaishinKit/Sources/Extension/CMSampleBufferCodec.swift`
- ReplyKit：`ReplyKIT/Event.swift`（`isSideload`）、`ReplyKIT/Socket.swift`（E-Socket）
