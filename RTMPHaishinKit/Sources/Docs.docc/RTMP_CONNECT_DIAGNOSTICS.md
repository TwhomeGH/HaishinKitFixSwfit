# connect 失敗診斷

新診斷統一以 `Connect diagnostic:` 開頭，直接經過 `RTMPConnection.onLog`，always=true，不受 framework minimumLogLevel 限制。應用端必須先安裝 setOnLog

並確保自己的轉送端不再丟棄 info / always 事件。framework 無法確認上游伺服器實際收到日誌。

每次連線至多 192 筆一般診斷；超時另列摘要及最多 16 個 chunk stream 狀態。不記錄完整封包、連線 URL、command object、arguments 或推流金鑰。

- begin：本輪 generation，以及舊 inputBuffer 尚未消費的 bytes。
- command queued：connect transactionId、payloadBytes、acceptedBytes；僅表示本機入列，不是伺服器收到。
- S2 trailing：握手尾端轉交 chunk parser 的 bytes。
- receive：本輪握手後收包量、緩衝區與 chunk size。
- chunk / message：訊息種類、stream id、組裝進度及完成派送。
- chunk size：伺服器宣布及本機採用的 chunk size。
- underflow：需要更多資料；單次出現屬正常 TCP 分段。
- message decode failed or unsupported：已收滿但不能建立訊息。AMF 失敗另含 stage、offset、remaining，沒有原始內容。
- command decoded：已知命令名稱、transactionId、是否有 responder；未知名稱顯示 other。
- timeout / pending chunk：累計收包、完成訊息數、剩餘資料及組裝狀態。

下一輪請保留首次 TCP connecting 之前到首次 timeout 之後的完整日誌，以及後續重試。若 command queued 的 acceptedBytes 正常、receive 有資料

卻沒有 command decoded，可沿 chunk / AMF 診斷定位；若有 command decoded 但 responder=false，查 transactionId 或等待者生命週期。

## createStream 與發布啟動

`createStream` 及正式 publish 前會開啟 30 秒診斷視窗，仍共用本次連線的 192 筆上限，不記錄命令參數或金鑰。

- command queued：增加安全命令名稱、交易編號與本機接受的 payload 位元組數。
- command timeout：命令逾時輸出累計接收、已解析訊息、未消費緩衝區與待回覆交易。
- transport：命令逾時時取得 socket 的待送、完成、失敗批次統計；完成不代表伺服器確認。
- chunk size wire：直接取完整控制訊息的四個原始 payload 位元組；不是重新編碼的 size。

整數讀取已修正 Data 指標逸出有效閉包的問題。chunk size 為零或超出本實作 10 MiB 上限時明確關閉，不再截斷後沿用不同的分塊規則；長度不是四位元組也會關閉。

log-56 已證實 connect 成功、createStream 三次逾時；上述指標讀取缺陷是確定的程式問題，但是否為該次 Restream 逾時的唯一原因仍需實機重測。
