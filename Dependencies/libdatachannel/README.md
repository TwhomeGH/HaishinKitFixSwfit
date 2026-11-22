# libdatachannel

目前使用 v0.24.0，由 RTCHaishinKit 引用。版本及證據見 [manifest.json](./manifest.json)。
來源 tag 是公開建置腳本指定的版本，不是發布 ZIP 已完成可重現建置的證明。

## 升級前需核對

- 原始碼及子依賴 commit、OpenSSL 實際版本、建置參數與工具鏈。
- Apple 平台架構、最低系統版本、符號及與其他套件同時連結的相容性。
- 連線、傳輸、重連、多實例停止釋放與長時間資源觀察。
- 授權及來源交付要求；保存產物 checksum 和驗證紀錄。

完整缺口見 [二進位依賴盤點](../../Docs/BINARY_DEPENDENCY_AUDIT.md)。
目前沒有套用本地 patch；尚未升級或 fork 上游原始碼。
