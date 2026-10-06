# 影片管線診斷

將每個診斷值對回實際的處理階段。

## 取得入口

使用 RTMPHaishinKit 時，呼叫串流的 `videoPipelineSnapshot()`；它是 nonisolated 同步方法，不必等待 RTMP actor。建議 UI 每秒取樣並保留前次結果，不逐幀產生日誌。

```swift
let current = stream.videoPipelineSnapshot()
let rates = current.encoderInput.queue?.rates(since: previous?.encoderInput.queue)
print(current.summary(since: previous))
previous = current
```

此範例中的 stream 是 RTMPStream，previous 為可選的 VideoPipelineSnapshot，初值 nil。若只持有 MediaMixer，其同名入口只回傳 ``VideoMixerSnapshot``。

## 階段對照

| 欄位 | 對應位置 | 不能據此推論 |
| --- | --- | --- |
| mixer.input／output | Mixer 的輸入與輸出佇列 | GPU 或編碼已完成 |
| bridgeReceived／pressureDrops | Mixer 回呼交接至 RTMPStream 的橋接器 | 所有收到影格都進入編碼器 |
| encoderInput | 原始影格等待編碼的佇列 | 編碼成功 |
| encoder | 編碼器提交、回呼與交付事件 | RTMP 已接受 |
| output | RTMP 訊息建立、入列及連線層接受事件 | socket 傳送完成或伺服器收到 |

`encoderSubmitted` 表示提交階段，`encoderCallback` 表示收到編碼回呼，`encoderDelivered` 表示編碼器向下游交付。`encodedReceived` 是 RTMPStream 接到編碼結果；`videoQueued` 是輸出佇列接受，`connectionVideoAccepted` 是連線層接受輸出。這些事件描述不同位置，不能全部當成「送出 FPS」。

socket 本機完成資訊需另外呼叫 RTMPConnection.transportDiagnostics()；其 completedBytes 也不代表遠端已解碼。

## 判讀限制

- ``VideoQueueSnapshot/received`` 包含輸入嘗試及拒收；consumed 是交付消費端。
- bytes／byteLimit 只涵蓋該佇列持有的估計資料量，不代表 App 記憶體。
- sampledAt、lastAt、Age、Wait、Idle 的原始單位是秒；文字摘要部分欄位轉成毫秒。
- lastPTS 是媒體時間，不能直接與取樣單調時間相減求延遲。
- 欄位為 nil、unavailable 或 ownerLockBusy 時顯示「未提供／本次未取得」，不要顯示成 0 或健康。
- 靜態畫面可能沒有新影格，單次 Idle 增加不代表卡住。應綜合來源是否持續輸入、PTS 是否前進、佇列等待及錯誤判斷。
- 子階段依序取樣，且生命週期不同；使用 queue.id／tracker id 判斷差值是否有效。橋接累計以串流實例為範圍，不能跨實例比較。

## 相關型別

- ``VideoPipelineEvent``
- ``VideoPipelineEventValue``
- ``VideoQueueStageSnapshot/Availability``
- ``VideoPipelineSnapshot``
- ``VideoMixerSnapshot``
- ``VideoQueueStageSnapshot``
- ``VideoQueueSnapshot``
- ``VideoQueueRates``
- ``VideoPipelineEventsSnapshot``
