# 故障排除指南

## 常見問題

### RTMP 連線失敗

**問題**: 無法連線到 RTMP 伺服器。

**可能原因與解決方案**:

1. **URL 格式錯誤**
   - 確認 URL 格式正確：`rtmp://host:port/app/streamKey`
   - RTMPS 使用 `rtmps://` 前綴

2. **防火牆阻擋**
   - RTMP 預設連接埠：1935
   - RTMPS 預設連接埠：443
   - 確認防火牆允許這些連接埠

3. **TLS 問題**
   - RTMPS 需要正確的 TLS 憑證
   - 確認伺服器支援 TLS 1.2+

4. **Handshake 失敗**
   - 確認伺服器支援 RTMP 協定版本 3
   - 檢查 C0/C1/C2 封包格式

### 串流無法發布

**問題**: 連線成功但無法發布串流。

**可能原因與解決方案**:

1. **Stream ID 未建立**
   - 確認 `createStream()` 已在 publish 前完成
   - 檢查 `RTMPSession` 使用 eager init（我們的修復已解決此問題）

2. **串流名稱錯誤**
   - 確認 stream key 正確
   - 某些服務（如 Restream）使用 URL 路徑的最後一部分作為 stream key

3. **App 參數錯誤**
   - connect 指令中的 `app` 參數應只包含應用名稱
   - 例如：`rtmp://server/live/streamKey` → app = "live"

### Restream.io 特定問題

**問題**: 無法推流到 Restream.io。

**檢查事項**:

1. **URL 格式**
   ```
   rtmps://live.restream.io/live/STREAM_KEY
   ```
   - 使用 `rtmps://`（強制 TLS）
   - App 名稱固定為 `live`
   - Stream key 從 Restream 儀表板取得

2. **串流金鑰**
   - 在 Restream 儀表板中產生新的串流金鑰
   - 金鑰包含在路徑的最後一部分

3. **連線測試**
   ```
   rtmps://live.restream.io/live/YOUR_STREAM_KEY
   ```

4. **已知問題**
   - 先前版本有 `createStream` 競態條件（現已修復）
   - `RTMPSession` 的 `_stream` 改為 eager init
   - 確保套用最新修復

### 音訊無輸出（Audio pipeline 中斷）

**問題**: App 層有收到音訊（音量變化），但 RTMP throughput 顯示 `audioFrames=0 audioBytes=0`。

**常見原因**:

1. **語音模式切換 / 音訊路由變更**
   - 進入或離開 `.voiceChat` 模式、插拔耳機、藍牙連接時，iOS 音訊硬體重配置
   - `AVAudioConverter` 可能進入無效狀態，`convert()` 靜默回傳 `.noDataNow`
   - **自動恢復**：MediaMixer 監聽 `routeChangeNotification` 重新附接 capture；RTMPStream 的 audio stall 偵測 3 秒內重啟 codec
   - **手動恢復**：等待 3~5 秒，stall 偵測會自動修復

2. **AVAudioSession 中斷（電話、鬧鐘等）**
   - 系統中斷結束時若無 `shouldResume` 旗標，音訊 capture 不會自動恢復
   - 檢查 App 層是否有處理 `AVAudioSession.interruptionNotification`

3. **AudioCodec 未啟動**
   - 確認 `OutgoingStream` 已呼叫 `startRunning()`
   - 檢查 `isRunning` 狀態

**診斷方式**:
- 檢查 `onLog` 是否有 `audio stall detected` 或 `Restarting audio pipeline` 日誌
- 比對 `audioInputFrames`（PCM 輸入）與 `audioSentFrames`（壓縮輸出）是否一致

### HTTP-FLV 顯示 `1/1000` fps

**問題**: 拉取 HTTP-FLV 或查看 SRS/Oryx/播放器診斷時，fps 顯示為 `1/1000`，
但畫面實際播放節奏看起來不是每 1000 秒一幀。

**判斷方式**:
- 直接解析 FLV video tag timestamp delta；若主要為 `16/17/20/33ms`，代表實際
  video cadence 正常
- 搜尋 FLV payload 是否含 `onMetaData`、`framerate` 或 `@setDataFrame`
- 若沒有 metadata，`1/1000` 通常是下游把 FLV 的毫秒 timebase 當成 fps 資訊顯示，
  不是 RTMP video timestamp 被寫壞

**修復方向**:
- 確保 `onMetaData` 在 `NetStream.Publish.Start` 後送出，而不是在 `publish`
  command 前送出
- 第一筆 metadata timestamp 應為 `0`
- metadata 應包含 `framerate`；優先使用 `expectedFrameRate`，未設定時可由
  `frameInterval` 推算
- 若 publish 成功時 video format 尚未建立，第一個 encoded video frame 到達時要在
  video sequence header 前補送含 video 欄位的 metadata

### 記憶體問題

**問題**: 長時間串流後記憶體不斷增長。

**可能原因**:

1. **AsyncStream 無背壓**
   - 資料路徑：`RTMPStream → RTMPConnection → RTMPSocket`
   - 每層都是 unbounded AsyncStream
   - 編碼速度快於網路發送時會堆積資料

2. **Output Task 死亡**
   - 如果 output Task 因錯誤終止，後續資料會在緩衝區無界堆積
   - 修復：加入 `do-catch` 處理，確保錯誤時清理

**解決方案**:
- 降低編碼位元率
- 實作背壓機制
- 監控 `queueBytesOut` 報告

### 連線不穩定

**問題**: 短暫網路抖動就斷線。

**可能原因**:

1. **Viability 處理**
   - `NWConnection` 在 WiFi→5G 切換時會先觸發 viability=false
   - 舊版程式碼會立即關閉連線
   - 修復：移除 viability 的 `close()` 呼叫，讓 NWConnection 自動恢復

2. **接收緩衝區過小**
   - `windowSizeC` 原本設為 255（Int(UInt8.max)）
   - 每個 keyframe 需要 200-800 次 read 調用
   - 修復：改為 65535（Int(UInt16.max)）

### 除錯技巧

**診斷日誌 (onLog)**:

```swift
let connection = RTMPConnection(minimumLogLevel: .info)

// 生產環境：只收 info/warn/error（預設）
// connection.minimumLogLevel = .info

// 開發除錯：收所有日誌（含 trace/debug）
// let connection = RTMPConnection(minimumLogLevel: .trace)
```

`minimumLogLevel` 控制哪些等級的日誌會觸發 `onLog` 回呼：

| 設定值 | 觸發等級 | 用途 |
|--------|---------|------|
| `.trace` | trace, debug, info, warn, error | 完整診斷（含每筆 socket send/recv、每幀發送） |
| `.debug` | debug, info, warn, error | 一般除錯 |
| `.info`（預設） | info, warn, error | 生產環境 |
| `.warn` | warn, error | 僅警告 |
| `.error` | error | 僅錯誤 |

> [!NOTE]
> 即使設為 `.trace`，append 裡的 per-frame 日誌也不會逐幀觸發 `onLog` — 它改為累積計數，由 `NetworkMonitor` 週期彙總一條 `"publish throughput"` 事件，避免 hot path Task spawn 風暴。

**接收 onLog 事件**:

```swift
await connection.setOnLog { event in
    // event.level: .trace / .debug / .info / .warn / .error
    // event.message: 簡短描述
    // event.detail: 詳細資料（可能為 nil）
    print("[RTMP] \(event.level) \(event.message) \(event.detail ?? "")")
}
```

**檢查網路監控**:

```swift
// 監控串流量
for await event in await networkMonitor.event {
    switch event {
    case .status(let report):
        print("Bytes in: \(report.totalBytesIn)")
        print("Bytes out: \(report.totalBytesOut)")
        print("Queue: \(report.queueBytesOut)")
    default:
        break
    }
}
```

**常見錯誤碼**:

| 錯誤碼 | 等級 | 說明 |
|--------|------|------|
| `NetConnection.Connect.Success` | status | 連線成功 |
| `NetConnection.Connect.Failed` | error | 連線失敗 |
| `NetConnection.Connect.Rejected` | error | 連線被拒絕 |
| `NetConnection.Connect.Closed` | status | 連線關閉 |
| `NetStream.Publish.Start` | status | 發布開始 |
| `NetStream.Publish.BadName` | error | 串流名稱無效 |

## 版本相容性

| 平台 | 最低版本 | 注意事項 |
|------|----------|----------|
| iOS | 15.0+ | 需要實體裝置測試相機 |
| macOS | 12.0+ | 螢幕錄製需要權限 |
| tvOS | 15.0+ | 無相機支援 |
| visionOS | 1.0+ | 有限測試覆蓋 |
