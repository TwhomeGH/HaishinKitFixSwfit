# ``HaishinKit``

影音處理、混音與串流核心 API。

## Overview

文件由當次 checkout 產生。接口存在不代表上游 App 已接入，請對照文件首頁的 revision 與 App 鎖定版本。

## Topics

### 影片管線診斷

- <doc:VideoPipelineDiagnostics>
- ``VideoPipelineSnapshot``
- ``VideoQueueSnapshot``
- ``VideoPipelineEventsSnapshot``

### 音訊與混音診斷

- ``AudioPipelineDiagnostics``
- ``MediaMixerOutput``

### 網路監控

- ``NetworkMonitorReport``
- ``NetworkMonitorEvent``

## 診斷資料判讀

累計量須取差值再計算速率。目前佇列大小是 bytes，網路速率是 bytes/s；音訊區塊數與 PCM 樣本數也須分開。Mixer 產出不等於編碼完成，傳輸層完成不等於伺服器已解碼。
