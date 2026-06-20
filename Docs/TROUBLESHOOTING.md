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

**啟用詳細日誌**:

```swift
// 設定日誌等級
logger.info("Connection state:", state)
logger.warn("Connection waiting:", error)
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