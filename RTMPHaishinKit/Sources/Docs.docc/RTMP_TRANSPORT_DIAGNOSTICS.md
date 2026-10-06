# RTMP 傳送診斷

入口：`await RTMPConnection.transportDiagnostics()`，回傳可選 `RTMPTransportDiagnostics`。沒有 socket 時回傳 nil。建議每秒取樣，generation 改變時重新建立差值基準。

- queuedBytes：待完成位元組，包含正在送的批次。
- completedBytes／completedBatches：無錯誤的本機完成位元組／批次。
- failedBatchBytes／failedBatches：收到錯誤的批次大小／次數，不能判定其中多少位元組曾傳出。
- lastCompletionMilliseconds：最近一次回呼耗時，尚無回呼時 nil。
- acknowledgedBytes：目前 nil；尚未接入伺服器 ACK。

修正後 totalBytesOut 不再計入失敗批次；錯誤先停止，不繼續提交下一批。舊連線完成回呼透過世代隔離，避免重連後消耗新佇列。

本 API 尚未提供影音分類、RTMP chunk 數、耗時分位數或伺服器解碼證據。主 App 診斷頁尚待接入；本地 checkout 修改不會自動更新 App 的 Package.resolved。

## DocC

`.github/workflows/docc.yml` 以現有 swift-docc-plugin 分別產生 HaishinKit／RTMPHaishinKit 文件，zip artifact 與 GitHub Pages 共用同一站台

附 revision.txt。倉庫 Pages 需選用 GitHub Actions。使用者已於 2026-10-06 確認已部署的 DocC 網站與 RTMPTransportDiagnostics 頁有效；不代表 RTMP 傳送行為已完成實機驗證。

### DocC 建置證據

每次執行另上傳 `docc-diagnostics-<sha>-<runId>-<attempt>`，保留 14 天。內容包含 revision.txt、Package.swift、UTC 時間／CI 執行資訊、prepare.log 與各模組建置日誌。

checkout 原有鎖定檔另存 checkout-Package.resolved；建置結束後的鎖定檔保存為 Package.resolved。解析尚未產生檔案時，以 package-resolution-status.txt 明確標示。

建置失敗仍嘗試保存與上傳診斷；遭強制終止或 runner 中斷時不保證收尾執行。所有管線使用 bash 的 pipefail，tee 不會掩蓋建置失敗。文件站台 artifact 與 Pages 僅在前置步驟成功後執行，診斷檔不加入公開站台。

新版首頁顯示 checkout 與模組入口，中文化範圍見 [API 文件中文化與首頁維護](https://github.com/TwhomeGH/HaishinKitFixSwfit/blob/main/Docs/DOCUMENTATION_CHINESE.md)。
