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

## 影音時間軸排查

`publish timeline` 沿用 throughput 每 10 次 status 的節流（約 10 秒），schema=1，時間單位皆為秒。診斷為固定大小統計，不持有樣本、不逐封包寫日誌，亦不更改同步策略。

- `generation`：發布世代，跨重連請分開比較。
- `sourceStart`／`sourceLast`：進入 RTMP 封裝時未補償的時間；影片為編碼 DTS，音訊為編碼輸出 AVAudioTime，並非 ScreenCaptureKit 原始擷取時間。
- `effective`：套用影片補償或音訊 resync 後交給時間戳演算法的位置。
- `generated`：產生的 RTMP delta 累計，並非成功入列、socket 完成或伺服器確認。
- `sourceMinusGenerated`：來源經過時間減去 generated。正值表示產生的時間軸比來源短；持續增加或突然跳動應追查。
- `retime`：effective 減 sourceLast；可識別重標時間，不能代表音訊內容已被移除或重採樣。
- `sourceStep`／`generatedDelta`：最近來源間隔與產生 delta。`gapsOver2s`／`regress` 保存來源長間隔及回退次數，`maxGap`／`lastDiscontinuity` 保存最大間隔及最近事件來源時間。
- `clamps`：異常 delta 被舊 delta 替代的次數；`corrections`：preferredDelta 分支修正或跳轉次數。
- `generatedAVOffset`：影音各自累計時間相減。兩軌各自起點不同，必須搭配 sourceStart；不能直接視為口型偏移。
- `videoCompensation`／`audioResyncs`：目前影片補償與音訊重標累計次數。

舊 `publish throughput` 的 videoPTS／audioPTS 為演算法 updatedAt，保留以相容既有工具；它們不是原始 capture PTS，也不等於累計 RTMP 時間。靜態畫面更新稀疏時，avOffset 變大不代表內容不同步。尚未收到來源的欄位顯示 unknown。

下一次測試應同時保存 App 日誌、SRS 原始 FLV 與 Oryx／FFmpeg 完整參數及日誌，以來源事件對照；CFR 補幀不能恢復已錯配的聲音內容。本批尚未提供混音前後的逐軌對照，也未調整停止排空順序。
