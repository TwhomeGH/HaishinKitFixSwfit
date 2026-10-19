# 實際編碼輸出診斷

使用 ``RTMPStream/encodingDiagnostics()`` 取得 ``RTMPEncodingDiagnostics``。讀取不會取走媒體，也不會進行解碼；建議每 5 秒讀一次。

```swift
let snapshot = await stream.encodingDiagnostics()
```

## 觀測位置與生命週期

RTMPStream 在 publishing 且輸出佇列開啟時，從實際壓縮樣本建立格式快照，位置在 RTMP 封裝、keyframe 篩選與網路傳送之前。這不是成功送達量，也不能證明伺服器解碼成功。外部直接 append 的壓縮樣本也屬此觀測範圍。

同一格式只解析一次，後續僅更新累計量與最近輸出時間。只保留小型格式描述，不保存 CMSampleBuffer 或 AVAudioCompressedBuffer。

- session 是 RTMPStream 實例 ID；generation 隨發布工作建立與停止遞增。
- 重連、重新發布與既有管線重建經發布工作生命週期清空快照。舊發布 task 先被 generation 檢查拒絕。
- 格式 revision 計算本發布世代中觀測到的格式變更，不是底層硬體 encoder session ID。設定調整尚未反映到輸出時，顯示的仍是最後實測格式。
- 格式變更時間和最近輸出時間不同；持續輸出相同格式只更新後者。時間是觀測的 Date，不是樣本 PTS。
- 未觀測到壓縮樣本時格式與時間為 nil；空音訊 buffer 不計入。

## 格式與數量

影片包含 codec FourCC、寬高、可選色彩附件與 Full Range 標記。H.264 有 avcC 時額外提供六位十六進位 profile／compatibility／level 識別碼；其他格式不套用此解析。沒有附件不推定 BT.709、Full Range 或 Video Range。

音訊包含 ASBD codec、Hz、聲道數與每封包 sample frames。framesPerPacket 為 0 表示格式可變或未指定，不猜為 AAC 1024。

累計 videoFrames／audioPackets 分別計算影片樣本與音訊 packet；videoBytes／audioBytes 不含 RTMP 標頭。計算碼率需使用相同 session／generation 的相鄰快照與實際間隔，不使用目標 bitrate。

## 相關型別

- ``RTMPEncodingDiagnostics``
- ``RTMPEncodedVideoFormat``
- ``RTMPEncodedAudioFormat``
