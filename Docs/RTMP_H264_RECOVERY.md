# RTMP／H.264 解碼邊界恢復

## 問題與修正範圍

log-42 回放切回直播時，非 IDR 影格先於直播 SPS/PPS 出現；僅補回正確參數集即可消除大量語法解碼錯誤。這支持參數集銜接問題，但不能單憑最終回放定位為推流端或轉播服務的錯誤。

本次修補底層已確認的設計缺口：已編碼封包丟失後仍繼續輸出、舊發布工作跨重連、未確認真正輸出的關鍵幀，以及忽略 VT 非同步失敗。保留既有中文註釋與正常收播排空行為。

## 不變式

1. **先參數集，再關鍵幀，再依賴影格。** 新發布、編碼管線重啟、格式改變時等待 sync sample；尚未等到時不送 P 幀。每個 sync sample 前都重送 sequence header，格式相同也重送。週期性重送使用 type-1／零 delta，避免改動媒體時間軸。
2. **丟失已編碼資料就是失去連續性。** stream 與 connection 的有界輸出佇列，遇到滿載或 consumer 結束會整批作廢，而非只丟該訊息。socket 容量保護也改成關閉傳輸。利用既有斷線重連流程恢復；若應用停用自動重連，會保持斷線，由應用決定重試。
3. **舊工作不能進新連線／新編碼器。** publish task、stream 輸出與 connection 輸出有世代檢查；跨 actor hop 後在 connection 再次驗證。原始影格仍在原本輸入工作編碼，OutgoingStream 在同一把 codec 鎖內驗證輸入世代，避免占用 RTMP actor 或發生檢查後才重啟的競態。
4. **要求關鍵幀不代表已成功。** 每個 VT session 使用獨立、有鎖的輸出狀態。只有合法、ready、sync 的 callback 被 continuation 接受後，才確認成功；丟幀或拒收會繼續要求關鍵幀。非同步錯誤擋住後續輸出，下一次 append 透過既有錯誤路徑重建 session。
5. **正常停止與故障分開。** 正常拆除等待已接受尾幀排空；故障直接取消／作廢佇列，不能排完損壞 GOP 後繼續。等待排空後須再驗證世代，避免舊 teardown 清掉新 consumer。

## 維護位置

- `VideoEncoderOutputState`：VT 執行緒與 codec 呼叫端共享的狀態。callback 不取得 OutgoingStream 鎖，避免鎖順序反轉。
- `RTMPOutputQueue`：有界佇列、世代與故障失效；`finish()` 只用於正常排空，`invalidate()` 用於故障／汰換。
- `RTMPStream`：發布工作隔離、首幀門檻、sequence header 及正常拆除。
- `RTMPConnection`／`RTMPSocket`：丟失編碼訊息後關閉當下傳輸；恢復工作攜帶舊世代時不能誤關新連線。
- `OutgoingStream`：原始輸入世代與編碼呼叫在同鎖內檢查，stop/start 不與舊輸入穿插。

## 診斷

- `Output continuity lost; closing transport`：包含 stream／connection 失去訊息的原因。
- `OOM guard: closing transport to preserve media continuity`：socket 容量保護觸發。
- `VideoCodec asynchronous encode failure`：VT 非同步錯誤碼。
- `Video decode boundary queued`：新發布恢復點的世代與 PTS。queued 只表示已入本機輸出佇列，不代表伺服器已確認收到。
- `video sequence header queued`：debug 級別的參數集大小與首個 header 標記。

## 驗證與限制

可在有 Swift 6 的 Windows／macOS 執行：

```text
python .github/scripts/test-rtmp-recovery-core.py
```

腳本用原始檔建立無外部依賴的臨時 Swift package，測試 header／IDR 丟失、舊世代拒收、consumer 終止、正常尾幀排空、非同步失敗、未確認／丟棄的 keyframe、舊 VT callback 及併發作廢。

仍需 macOS/iOS 編譯與實機驗證：以網路中斷、輸出壅塞及編碼 session 重建重現，核對首個 wire sequence header + IDR、RTMP 重新發布與 Twitch／轉播服務切換結果。Windows 核心測試與語法解析不代表 Apple SDK 型別檢查或真實網路整合已通過。

無法保證下游服務不會自行在 GOP 中途切回；本次保證的是推流端的失敗恢復邊界，並增加週期性參數集以提供下游新的恢復機會。
