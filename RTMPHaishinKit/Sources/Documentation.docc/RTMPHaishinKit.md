# ``RTMPHaishinKit``

RTMP 連線、串流發布與傳送診斷 API。

## Overview

文件由當次 checkout 產生；API 存在不代表上游 App 已接入。請核對 App 鎖定 revision。

## Topics

### 連線與傳送診斷

- ``RTMPConnection``
- ``RTMPTransportDiagnostics``
- ``RTMPLogEvent``
- ``RTMPLogLevel``

### 串流狀態與回應

- ``RTMPStatus``
- ``RTMPResponse``
- ``RTMPStreamInfo``

## 使用傳送診斷

```swift
if let snapshot = await connection.transportDiagnostics() {
    print(snapshot.completedBytes, snapshot.failedBatchBytes)
}
```

建議每秒取樣。queuedBytes 包含正在送的批次，completedBytes 只計無錯誤完成；failedBatchBytes 是失敗批次大小，不代表所有 bytes 都未傳出。

批次數不等於 RTMP chunk 數；acknowledgedBytes 目前為 nil。

本 API 尚未涵蓋影音分類、chunk 數與伺服器 ACK；不能推論遠端已收到或成功解碼。
