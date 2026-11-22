# 二進位依賴管理

這裡集中管理版本、來源證據、內含依賴、修補與驗收狀態。
**Package.swift 仍是實際建置入口；這些 manifest 是盤點資料，不會自動更換依賴。**

| 依賴 | 目前用途 | 管理資料 |
| --- | --- | --- |
| libdatachannel | WebRTC | [版本與缺口](./libdatachannel/README.md) |
| libsrt | SRT | [版本與缺口](./libsrt/README.md) |
| OpenSSL | 兩個發布包內含的加密函式庫 | [待釐清版本](./openssl/README.md) |

## 狀態規則

- schemaVersion=1；null 表示尚未確認，不代表不需要該依賴。
- integrity 通過只表示下載與預期 ZIP 相符；runtimeVerified、securityReview、reproducibleBuildVerified 分開記錄。
- source tag／子模組 commit 是公開原始碼證據，不能自動視為二進位產物來源證明。
- 升級時同步 Package.swift、對應 manifest、更新歷史與驗證結果；不得只改版本名稱或校驗碼。
- 不提交大型編譯產物、下載包或整份來源副本。需要長期修改時另建 fork，這裡記錄其固定 commit 與上游關係。
- 已知缺陷與驗收計畫見 [盤點報告](../Docs/BINARY_DEPENDENCY_AUDIT.md) 和 [TODO](../Docs/TODO.md)。

本次建立管理目錄，沒有升級、替換二進位、建立 fork 或新增下載流程。
