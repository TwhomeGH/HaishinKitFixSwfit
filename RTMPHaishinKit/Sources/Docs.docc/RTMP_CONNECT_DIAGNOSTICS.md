# connect 失敗診斷

新診斷統一以 `Connect diagnostic:` 開頭，直接經過 `RTMPConnection.onLog`，always=true，不受 framework minimumLogLevel 限制。應用端必須先安裝 setOnLog

並確保自己的轉送端不再丟棄 info / always 事件。framework 無法確認上游伺服器實際收到日誌。

每次連線至多 64 筆一般診斷；超時另列摘要及最多 16 個 chunk stream 狀態。不記錄完整封包、連線 URL、command object、arguments 或推流金鑰。

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

這輪只補診斷，不改動既有重連與解析行為，方便對照下一輪現場。
