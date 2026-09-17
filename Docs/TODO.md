# TODO / 計畫

本文件記錄**已規劃但尚未實作**的工作。實作完成後，請把結果移到 `CHANGES.md` 並在此移除該項。

---

## P1. RTMP 握手分階段逾時

**狀態**：規劃中
**相關**：CHANGES #56a（整體 connect timeout）、#57b（keepalive 純型別化）
**檔案**：`RTMPHaishinKit/Sources/RTMP/RTMPConnection.swift`

**背景**：CHANGES #56a 已為整個 connect（TCP → 握手 → connect command 回應）加上單一
`timeout`（預設 15s）計時器，這解決了「卡住不失敗」的問題。但整體逾時無法區分卡在哪一
階段，對診斷與調參不夠精確。

**工作**：

1. 為握手各階段加上獨立逾時：TCP 連線（已有 `RTMPSocket.timeout`）、等待 S0S1、
   等待 S2、等待 connect `_result`。任一階段逾時 → `close()` → 走既有重連路徑。
2. 逾時錯誤訊息帶上階段名稱（`always: true`），讓遠端 log 一眼看出卡在哪。
3. 測試：在 `RTMPConnectionTests` 以不可用 / 半開端點驗證各階段逾時時間與錯誤內容
   （需能注入較短的 `timeout` 以免測試過慢）。
