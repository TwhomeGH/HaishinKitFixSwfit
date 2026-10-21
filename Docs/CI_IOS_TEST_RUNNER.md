# iOS 測試 Runner 啟動與故障處理

RTMPHaishinKit 與 HaishinKit 的 iOS job 使用 `.github/scripts/run_ios_tests.py`，直接呼叫 xcodebuild，不經 fastlane。

## 流程

- 從 simctl JSON 選擇最新可用 iOS runtime 與相符 iPhone 裝置類型；沒有可用組合即報環境失敗。
- 每次嘗試建立專用模擬器，使用其 UDID 執行測試；boot 最多等待 60 秒，bootstatus 最多等待 180 秒。
- 關閉 Xcode 平行測試，避免為單一 job 另建多組測試裝置。先以 build-for-testing 建置（最多 1500 秒），成功才執行 test-without-building（每次最多 660 秒）。
- 重試沿用相同 DerivedData，不重新編譯。逾時保留日誌並終止該程序群。兩個 iOS job 上限為 65 分鐘，預留兩次測試、模擬器操作與 artifact 上傳時間。
- 僅在明確出現 `The test runner hung before establishing connection.`，且沒有編譯錯誤、測試失敗或 issue 時重試一次。boot 失敗及一般執行逾時不自動重試。
- 每次完成只 shutdown／delete 該次建立的 UDID，不清理其他 job 或既有模擬器。

## Artifact

既有上傳步驟保存整個測試輸出目錄。各次資料在 `attempt-1`／`attempt-2`，包含 build.log、Build.xcresult、test.log

Tests.xcresult（若 Xcode 有產生）、runtime／裝置清單、destination、boot 與清理紀錄。

`ios-tests.log` 為最後一次嘗試的建置與測試結果（重試不重建，首次建置日誌保留於 attempt-1）；`attempts.md` 與 GitHub 摘要保留所有嘗試的退出碼。重試成功不刪除首次故障證據。

命令執行期間輸出寫入檔案，每 30 秒顯示日誌大小；完成後回放完整內容到 Actions console。階段開始會顯示命令用途與時間限制，失敗摘要包含 stage 與 exit code。

摘要把 runner／環境失敗與編譯錯誤分開；未取得測試個案結果不再一律寫成 build failed。

## 驗證

本機 Python 測試涵蓋 runtime 選取、啟動錯誤分類、禁止重試斷言失敗、兩次結果保留、重試不重建、建置逾時不啟動測試及專用裝置清理。macOS simctl／Xcode 的實際執行仍需 CI 驗收。
