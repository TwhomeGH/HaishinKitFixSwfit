# Stream Session 管理

## 概述

HaishinKit.swift 的 StreamSession 管理提供統一的介面來處理不同的串流通訊協定（RTMP、SRT、WebRTC、MoQ）。Session 的生命週期透過 Factory 模式管理。

## 架構

```
┌─────────────────────────────────────┐
│      StreamSessionBuilderFactory    │
│  Factory 註冊與建立                  │
├─────────────────────────────────────┤
│      StreamSessionBuilder           │
│  URL 解析與設定                      │
├─────────────────────────────────────┤
│      StreamSession                  │
│  通訊協定特定實作                    │
└─────────────────────────────────────┘
```

## Factory 模式

### StreamSessionBuilderFactory

共用 Factory 管理各通訊協定的 Session Factory：

```swift
// 註冊 Factory
await StreamSessionBuilderFactory.shared.register(RTMPSessionFactory())
await StreamSessionBuilderFactory.shared.register(SRTSessionFactory())
await StreamSessionBuilderFactory.shared.register(RTCHaishinKit.RTCSessionFactory())
await StreamSessionBuilderFactory.shared.register(MoQTHaishinKit.MoQSessionFactory())
```

### StreamSessionBuilder

Builder 負責建立 Session：
- URL 解析
- 模式選擇（publish/playback）
- 設定參數

```swift
let session = try await StreamSessionBuilderFactory.shared
    .make(URL(string: "rtmp://server/live/streamKey")!)
    .setMode(.publish)
    .build()
```

## RTMP Session 實作

### RTMPSession

RTMP 特定的 Session 實作：

```swift
actor RTMPSession: StreamSession {
    private let uri: RTMPURL
    private let mode: StreamSessionMode
    private let connection: RTMPConnection
    private let _stream: RTMPStream
}
```

與舊版不同，`connection` 與 `_stream` 現在改為 **eager init**（立即初始化），避免 lazy init 導致的 createStream 競態條件。

## Session 生命週期

### 連線流程

```swift
func connect(_ disconnected: @Sendable @escaping () -> Void) async throws {
    // 1. 連線到 RTMP 伺服器
    _ = try await connection.connect(uri.command)
    
    // 2. 確保串流已建立
    try await _stream.createStream()
    
    // 3. 發布/播放串流
    switch mode {
    case .publish:
        _ = try await _stream.publish(uri.streamName)
    case .playback:
        _ = try await _stream.play(uri.streamName)
    }
    
    // 4. 監控連線狀態
    disconnctedTask = Task {
        for await event in await connection.status {
            // 處理斷線事件
        }
    }
}
```

## 串流狀態管理

### StreamSessionReadyState

```swift
public enum StreamSessionReadyState: String, CaseIterable {
    case closed      = "closed"
    case connecting  = "connecting"
    case open        = "open"
    case closing     = "closing"
}
```

### AsyncStreamed 屬性

readyState 以非同步串流管理：

```swift
@AsyncStreamed(.closed)
private(set) var readyState: AsyncStream<StreamSessionReadyState>
```

## 錯誤處理

### 常見 RTMP 錯誤

```swift
public enum Error: Swift.Error {
    case invalidState
    case unsupportedCommand(_ command: String)
    case connectionTimedOut
    case socketErrorOccurred(_ error: (any Swift.Error)?)
    case requestTimedOut
    case requestFailed(response: RTMPResponse)
}
```

## 設定參數

### StreamSessionConfiguration

```swift
public protocol StreamSessionConfiguration {
    var maxRetryCount: Int { get }
    var timeout: Int { get }
    var chunkSize: Int { get }
    var qualityOfService: DispatchQoS { get }
}
```

## 程式碼參考

- StreamSessionBuilderFactory.swift：Factory 管理
- StreamSessionBuilder.swift：Session Builder
- RTMPSession.swift：RTMP Session 實作
- RTMPStream.swift：串流管理
- RTMPConnection.swift：連線處理