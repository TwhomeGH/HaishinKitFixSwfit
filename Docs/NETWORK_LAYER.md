# Network Layer

## Overview

The network layer in HaishinKit.swift handles TCP/IP connections and protocol transport using Apple's Network framework (NWConnection). It provides:

- Secure socket connections (TLS/SSL)
- Real-time data transmission 
- Network monitoring and reporting
- Connection state management
- Buffer management

## Architecture

```
┌─────────────────────────────────────┐
│      RTMPSocket                     │
│  NWConnection wrapper              │
├─────────────────────────────────────┤
│      NetworkTransportReporter       │
│  Transport monitoring              │
├─────────────────────────────────────┤
│      NetworkMonitor                 │
│  Connection event monitoring       │
└─────────────────────────────────────┘
```

## RTMPSocket

### Core Functionality

```swift
final actor RTMPSocket {
    // Connect to host/port using NWConnection
    func connect(_ name: String, port: Int) async throws
    
    // Send data chunks
    func send(_ data: Data)
    
    // Receive data stream
    func recv() -> AsyncStream<Data>
    
    // Close connection
    func close(_ error: NWError? = nil)
}
```

### TLS Configuration

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

### Security Levels

| Level | Description |
|-------|-------------|
| `none` | Plain TCP connection |
| `negotiatedSSL` | TLS negotiation |
| `ssLv2` | SSL version 2 |
| `ssLv3` | SSL version 3 |
| `tlSv1` | TLS version 1 |

## NetworkMonitor

### Event Types

```swift
public enum NetworkMonitorEvent {
    case status(NetworkTransportReport)
    case publishInsufficientBWOccured(NetworkTransportReport)
    case reset
}
```

### Monitoring Features

- Bandwidth reporting
- Connection status monitoring
- Buffer management
- Network viability checks

## NetworkTransportReporter

### Transport Reporting

```swift
func makeNetworkMonitor() async -> NetworkMonitor
func makeNetworkTransportReport() -> NetworkTransportReport
```

### Report Structure

```swift
public struct NetworkTransportReport {
    public let queueBytesOut: Int
    public let totalBytesIn: Int
    public let totalBytesOut: Int
}
```

## Connection State Management

### NWConnection States

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

## Buffer Management

### Chunk Buffering

```swift
final class RTMPChunkBuffer {
    var chunkSize: Int
    var payload: Data
    var remaining: Int
    var hasRemaining: Bool
    var position: Int
}
```

### Chunk Types

| Type | Header Size | Description |
|------|-------------|-------------|
| 0 | 11 bytes | Full header (timestamp, length, type, stream ID) |
| 1 | 7 bytes | Timestamp + length + type |
| 2 | 3 bytes | Timestamp only |
| 3 | 0 bytes | No header (continuation from previous chunk) |

## Code References

- RTMPSocket.swift: Network socket implementation
- NetworkMonitor.swift: Connection monitoring
- NetworkTransportReporter.swift: Transport reporting
- RTMPChunkBuffer.swift: Chunk buffer management
- RTMPChunk.swift: Chunking mechanism