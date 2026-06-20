# 網路層

## 概述

HaishinKit.swift 的網路層使用 Apple 的 Network 框架（NWConnection）處理 TCP/IP 連線與通訊協定傳輸。提供：

- 安全 Socket 連線（TLS/SSL）
- 即時資料傳輸
- 網路監控與回報
- 連線狀態管理
- 緩衝區管理

## 架構

```
┌─────────────────────────────────────┐
│      RTMPSocket                     │
│  NWConnection 包裝                  │
├─────────────────────────────────────┤
│      NetworkTransportReporter       │
│  傳輸監控                            │
├─────────────────────────────────────┤
│      NetworkMonitor                 │
│  連線事件監控                        │
└─────────────────────────────────────┘
```

## RTMPSocket

### 核心功能

```swift
final actor RTMPSocket {
    // 使用 NWConnection 連線到主機/連接埠
    func connect(_ name: String, port: Int) async throws
    
    // 發送資料
    func send(_ data: Data)
    
    // 接收資料串流
    func recv() -> AsyncStream<Data>
    
    // 關閉連線
    func close(_ error: NWError? = nil)
}
```

### TLS 設定

```swift
init(qualityOfService: DispatchQoS, securityLevel: StreamSocketSecurityLevel) {
    switch securityLevel {
    case .ssLv2, .ssLv3, .tlSv1, .negotiatedSSL:
        parameters = .tls
    default:
        parameters = .tcp
    }
}
```

### 安全等級

| 等級 | 說明 |
|------|------|
| `none` | 純 TCP 連線 |
| `negotiatedSSL` | TLS 協商 |
| `ssLv2` | SSL 版本 2 |
| `ssLv3` | SSL 版本 3 |
| `tlSv1` | TLS 版本 1 |

## NetworkMonitor

### 事件類型

```swift
public enum NetworkMonitorEvent {
    case status(NetworkTransportReport)
    case publishInsufficientBWOccured(NetworkTransportReport)
    case reset
}
```

### 監控功能

- 頻寬回報
- 連線狀態監控
- 緩衝區管理
- 網路可用性檢查

## NetworkTransportReporter

### 傳輸回報

```swift
func makeNetworkMonitor() async -> NetworkMonitor
func makeNetworkTransportReport() -> NetworkTransportReport
```

### 回報結構

```swift
public struct NetworkTransportReport {
    public let queueBytesOut: Int
    public let totalBytesIn: Int
    public let totalBytesOut: Int
}
```

## 連線狀態管理

### NWConnection 狀態

```swift
public enum NWConnection.State {
    case ready
    case waiting(NWError?)
    case setup
    case preparing
    case failed(NWError?)
    case cancelled
    @unknown default
}
```

## 緩衝區管理

### Chunk 緩衝

```swift
final class RTMPChunkBuffer {
    var chunkSize: Int
    var payload: Data
    var remaining: Int
    var hasRemaining: Bool
    var position: Int
}
```

### Chunk 類型

| 類型 | 標頭大小 | 說明 |
|------|----------|------|
| 0 | 11 bytes | 完整標頭（時間戳、長度、類型、串流 ID） |
| 1 | 7 bytes | 時間戳 + 長度 + 類型 |
| 2 | 3 bytes | 僅時間戳 |
| 3 | 0 bytes | 無標頭（承接前一個 Chunk） |

## 程式碼參考

- RTMPSocket.swift：網路 Socket 實作
- NetworkMonitor.swift：連線監控
- NetworkTransportReporter.swift：傳送回報
- RTMPChunkBuffer.swift：Chunk 緩衝管理
- RTMPChunk.swift：Chunk 分塊機制