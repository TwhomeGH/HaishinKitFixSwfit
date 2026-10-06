# API 文件中文化與首頁維護

## 範圍

採核心優先，不要求一次翻譯全專案。優先補完整公開 API 文件與本專案新增／修改的功能；時間戳、混音、佇列、重連、併發及記憶體管理的必要內部註釋也要清楚。其他內部註釋在修改該功能時處理。

API 名稱、協定常數與範例程式保留原文。DocC 的 Overview、Topics、Parameters、Returns 等結構標記沿用標準寫法。修正原註釋與實作不符之處時，應核對計數單位及時序，不只逐字翻譯。

## 已完成的第一批

- AudioPipelineDiagnostics：累計區塊／樣本數、緩衝、對齊、就緒與錯誤判讀。
- MediaMixerOutput：音軌選擇與影音回呼。
- NetworkTransportReport、NetworkMonitorReport、NetworkMonitorEvent：累計量、佇列大小、速率與頻寬事件。
- RTMPLogEvent：日誌欄位與 always 的使用限制。
- RTMPStreamInfo、RTMPStatus、RTMPResponse：接收統計、協定狀態與回應。

以上九份 Swift 檔只修改註釋，經比對確認可執行程式碼未變。RTMPConnection、RTMPStream、影音編碼設定與時間戳等其他核心接口仍列為後續批次，未宣稱全數中文化。

## 文件首頁

`Scripts/build_docc_home.py --site site` 使用 `Scripts/docc_home.html` 產生響應式首頁。先檢查兩個模組的 index.html 與 data/documentation 模組 JSON，再寫入首頁、build-info.json 與 revision.txt。沒有實際模組資料時建置失敗，避免發布無效導覽。

版本資訊包含實際 HEAD、Git ref、HEAD 上的標籤、已追蹤檔案是否修改、UTC 產生時間及 CI 執行連結。Git ref 只是補充資訊；完整 HEAD 才是版本依據。這不是使用者裝置上的 App BuildInfo，也不涵蓋未追蹤檔案。

## 驗證

使用者已於 2026-10-06 確認原版 DocC 網站與傳送診斷頁可瀏覽。新版首頁與中文註釋仍需下一次 workflow 部署驗收。

本機執行 `python Scripts/test_docc_home.py` 驗證版本資訊、HTML 跳脫與缺模組時停止產出。Apple SDK 的文件連結解析以 DocC workflow 為準。此次瀏覽器工具無法建立連線，尚未完成桌面／窄螢幕視覺驗收。


## 文件註釋關聯規則

`///` 寫在要說明的宣告之前，DocC 會在下一次建置時關聯到該符號。連續多個 enum case 應拆成各自宣告，才能分別附上觸發條件。

```swift
/// 最近一次完成回呼耗時（毫秒），沒有回呼時為 nil。
public let lastCompletionMilliseconds: Double?

/// 目前尚未公開伺服器 ACK 統計；nil 表示未知，不表示零。
public var acknowledgedBytes: Int? { nil }
```

Markdown 文章負責流程、跨型別對照與使用範例，屬性／case 定義以 Swift 註釋為單一來源。新增接口要同步記錄用途、單位、生命週期及 nil 意義。

影片診斷追加批次已補齊 VideoPipelineEvent 的 22 個 case、Availability 的 3 個 case，以及快照屬性說明。網站更新仍需重新建置並部署 DocC。
