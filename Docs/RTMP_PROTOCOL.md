# RTMP Protocol Implementation

## Overview

The RTMP (Real-Time Messaging Protocol) implementation in HaishinKit.swift provides support for both RTMP and RTMPS protocols. It handles the complete RTMP protocol stack including:

- TCP/IP connection establishment
- RTMP handshake (C0/C1/S0/S1/C2/S2)
- Chunking mechanism with different chunk types
- Message serialization/deserialization
- Authentication handling
- Stream management

## Protocol Stack

```
┌─────────────────────────────────────┐
│      Application Layer              │
│  RTMPCommandMessage, RTMPDataMessage│
├─────────────────────────────────────┤
│      Message Layer                  │
│  RTMPChunkMessageHeader             │
├─────────────────────────────────────┤
│      Chunking Layer                 │
│  RTMPChunkBuffer                    │
├─────────────────────────────────────┤
│      Transport Layer                │
│  RTMPSocket (NWConnection)          │
└─────────────────────────────────────┘
```

## Key Components

### RTMPConnection

The `RTMPConnection` class is the core of RTMP protocol implementation. It manages:

- TCP/IP connection with NWConnection
- RTMP handshake process
- Chunking buffer management
- Message parsing and dispatching
- Authentication handling via RTMPAuthenticator
- Network monitoring via NetworkMonitor

### RTMPHandshake

Handles the RTMP handshake process:
1. C0/C1 packet (version + timestamp + random bytes)
2. S0/S1 packet (version + timestamp + random bytes) 
3. C2 packet (S1 timestamp + current time + S1 random)
4. S2 packet (C1 timestamp + current time + C1 random)

### RTMPChunk

Implements the chunking mechanism:
- Chunk types: 0, 1, 2, 3
- Different header sizes for each type
- Message length, timestamp, stream ID handling
- Payload buffering and parsing

### RTMPMessage Types

The following message types are supported:

| Type | Description |
|------|-------------|
| 0x01 | Set Chunk Size |
| 0x02 | Abort Message |
| 0x03 | Acknowledgement |
| 0x04 | User Control |
| 0x05 | Window Acknowledgement Size |
| 0x06 | Set Peer Bandwidth |
| 0x08 | Audio Message |
| 0x09 | Video Message |
| 0x0F | AMF3 Data Message |
| 0x10 | AMF3 Shared Object |
| 0x11 | AMF3 Command Message |
| 0x12 | AMF0 Data Message |
| 0x13 | AMF0 Shared Object |
| 0x14 | AMF0 Command Message |
| 0x16 | Aggregate Message |

## Connection Flow

### 1. URL Parsing

The RTMP connection URL is parsed to extract:
- Host and port
- Scheme (rtmp/rtmps)
- App name from path components
- Query parameters

### 2. Handshake Process

```swift
// Step 1: Send C0+C1 packet
await socket.send(handshake.c0c1packet)

// Step 2: Receive S0+S1 packet
for await data in await socket.recv() {
    try await listen(data)
}

// Step 3: Send C2 packet  
await socket.send(handshake.c2packet())

// Step 4: Receive S2 packet
for await data in await socket.recv() {
    try await listen(data)
}
```

### 3. Connect Command

The connect command includes:
- `app`: Application name (parsed from URL path)
- `flashVer`: Flash version string
- `tcUrl`: URL without authentication info
- `swfUrl`: SWF URL if provided
- `pageUrl`: HTTP referer URL
- `objectEncoding`: AMF0 encoding
- `capabilities`: Connection capabilities
- `audioCodecs`: Supported audio codecs
- `videoCodecs`: Supported video codecs

### 4. Stream Creation

After successful connection:
1. Create stream via `createStream` command
2. Set chunk size and window acknowledgment
3. Publish stream with `publish` command

## Restream.io Specific Considerations

Restream.io typically uses:
- RTMPS protocol (`rtmps://live.restream.io/live/STREAM_KEY`)
- Stream key as the final path component
- No additional authentication in URL (uses stream key directly)

### URL Format Example

```
rtmps://live.restream.io/live/STREAM_KEY
```

Where:
- Host: `live.restream.io`
- Port: 443 (default for RTMPS)
- App: `live` 
- Stream name: `STREAM_KEY`

### Potential Issues

1. **App parameter construction**: The app name should be just "live", not "live/STREAM_KEY"
2. **Authentication handling**: Some restream servers might require authentication via URL credentials
3. **TLS configuration**: Ensure proper TLS certificate handling for restream.io domains
4. **Connection timeout**: Restream may have stricter connection timeouts

## Troubleshooting

### Common Error Codes

| Code | Description |
|------|-------------|
| `NetConnection.Connect.Failed` | Connection failed (network issues) |
| `NetConnection.Connect.Rejected` | Connection rejected (authentication required) |
| `NetStream.Publish.BadName` | Stream name invalid |
| `NetStream.Connect.Failed` | Stream connection failed |

### Debugging Tips

1. Check network connectivity to restream.io
2. Verify stream key format and validity 
3. Ensure TLS certificates are valid for restream.io domain
4. Monitor handshake process in logs
5. Validate chunk size and window settings

## Configuration Parameters

| Parameter | Default Value | Description |
|----------|---------------|-------------|
| `defaultTimeout` | 15 sec | Connection timeout |
| `defaultWindowSizeS` | 250000 | Window size |
| `defaultChunkSizeS` | 8192 | Chunk size |
| `defaultCapabilities` | 239 | Connection capabilities |
| `defaultFlashVer` | "FMLE/3.0 (compatible; FMSc/1.0)" | Flash version |

## Code References

- RTMPConnection.swift: Main connection logic
- RTMPHandshake.swift: Handshake implementation  
- RTMPChunk.swift: Chunking mechanism
- RTMPSocket.swift: Network transport
- RTMPAuthenticator.swift: Authentication handling