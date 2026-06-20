# Stream Session Management

## Overview

StreamSession management in HaishinKit.swift provides a unified interface for handling different streaming protocols (RTMP, SRT, WebRTC, MoQ). The session lifecycle is managed through the factory pattern.

## Architecture

```
┌─────────────────────────────────────┐
│      StreamSessionBuilderFactory    │
│  Factory registration and creation  │
├─────────────────────────────────────┤
│      StreamSessionBuilder           │
│  URL parsing and configuration      │
├─────────────────────────────────────┤
│      StreamSession                  │
│  Protocol-specific implementation   │
└─────────────────────────────────────┘
```

## Factory Pattern

### StreamSessionBuilderFactory

The shared factory manages protocol-specific session factories:

```swift
// Register factories
await StreamSessionBuilderFactory.shared.register(RTMPSessionFactory())
await StreamSessionBuilderFactory.shared.register(SRTSessionFactory())
await StreamSessionBuilderFactory.shared.register(RTCHaishinKit.RTCSessionFactory())
await StreamSessionBuilderFactory.shared.register(MoQTHaishinKit.MoQSessionFactory())
```

### StreamSessionBuilder

The builder creates sessions with:
- URL parsing
- Mode selection (publish/playback)
- Configuration parameters

```swift
let session = try await StreamSessionBuilderFactory.shared
    .make(URL(string: "rtmp://server/live/streamKey")!)
    .setMode(.publish)
    .build()
```

## RTMP Session Implementation

### RTMPSession

The RTMP-specific session implementation:

```swift
actor RTMPSession: StreamSession {
    private let uri: RTMPURL
    private let mode: StreamSessionMode
    private lazy var connection: RTMPConnection = {
        switch mode {
        case .publish:
            return RTMPConnection()
        case .playback:
            return RTMPConnection(flashVer: "MAC 9,0,124,2")
        }
    }()
    private lazy var _stream: RTMPStream = {
        switch mode {
        case .publish:
            return RTMPStream(connection: connection, fcPublishName: uri.streamName)
        case .playback:
            return RTMPStream(connection: connection)
        }
    }()
}
```

## Session Lifecycle

### Connect Flow

```swift
func connect(_ disconnected: @Sendable @escaping () -> Void) async throws {
    // 1. Connect to RTMP server
    _ = try await connection.connect(uri.command)
    
    // 2. Create stream (if needed)
    _ = try await _stream.createStream()
    
    // 3. Publish/Play stream
    switch mode {
    case .publish:
        _ = try await _stream.publish(uri.streamName)
    case .playback:
        _ = try await _stream.play(uri.streamName)
    }
    
    // 4. Monitor connection status
    disconnctedTask = Task {
        for await event in await connection.status {
            // Handle disconnect events
        }
    }
}
```

## Stream State Management

### StreamSessionReadyState

```swift
public enum StreamSessionReadyState: String, CaseIterable {
    case closed      = "closed"
    case connecting  = "connecting"
    case open        = "open"
    case closing     = "closing"
}
```

### AsyncStreamed Property

The ready state is managed as an async stream:

```swift
@AsyncStreamed(.closed)
private(set) var readyState: AsyncStream<StreamSessionReadyState>
```

## Error Handling

### Common RTMP Errors

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

## Configuration Parameters

### StreamSessionConfiguration

```swift
public protocol StreamSessionConfiguration {
    var maxRetryCount: Int { get }
    var timeout: Int { get }
    var chunkSize: Int { get }
    var qualityOfService: DispatchQoS { get }
}
```

## Code References

- StreamSessionBuilderFactory.swift: Factory management
- StreamSessionBuilder.swift: Session builder 
- RTMPSession.swift: RTMP session implementation
- RTMPStream.swift: Stream management
- RTMPConnection.swift: Connection handling