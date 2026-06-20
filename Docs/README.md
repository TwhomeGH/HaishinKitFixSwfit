# HaishinKit.swift Documentation

## Overview

HaishinKit.swift is a comprehensive live streaming framework for iOS, macOS, tvOS, and visionOS. It provides support for multiple streaming protocols including RTMP, SRT, WebRTC, and MoQ (Media over QUIC).

### Key Features

- **Multi-protocol Support**: RTMP/RTMPS, SRT, WebRTC, MoQ
- **Real-time Video/Audio Encoding**: H.264, H.265 (HEVC), VP9, AV1, AAC, Opus
- **Adaptive Bitrate Streaming**: Dynamic bitrate adjustment based on network conditions
- **Media Mixing**: Multi-track audio/video mixing with effects
- **Screen Capture**: Built-in screen recording and broadcasting
- **Hardware Acceleration**: VideoToolbox-based encoding/decoding

### Supported Platforms

| Platform | Minimum Version |
|----------|----------------|
| iOS      | 15.0+          |
| macOS    | 12.0+          |
| tvOS     | 15.0+          |
| visionOS | 1.0+           |

### Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      Application Layer                       │
├─────────────────────────────────────────────────────────────┤
│  StreamSession (RTMP/SRT/WebRTC/MoQ)                        │
├─────────────────────────────────────────────────────────────┤
│  MediaMixer → Video/Audio Encoding (VideoToolbox)           │
├─────────────────────────────────────────────────────────────┤
│  Network Layer (NWConnection / Network.framework)           │
├─────────────────────────────────────────────────────────────┤
│  Protocol Implementation (RTMP Chunking / SRT / WebRTC)     │
└─────────────────────────────────────────────────────────────┘
```

## Module Structure

| Module | Description |
|--------|-------------|
| `HaishinKit` | Core framework - MediaMixer, Codec, Network, Session, Stream |
| `RTMPHaishinKit` | RTMP/RTMPS protocol implementation |
| `SRTHaishinKit` | SRT (Secure Reliable Transport) protocol |
| `RTCHaishinKit` | WebRTC implementation |
| `MoQTHaishinKit` | Media over QUIC (MoQ) protocol |
| `Examples` | Sample applications for iOS/macOS/tvOS/visionOS |

## Quick Start

### Installation

### Swift Package Manager

```swift
.package(url: "https://github.com/TwhomeGH/HaishinKitFixSwfit.git", branch: "main")
```

Or in Xcode: **File → Add Package Dependencies...** → enter `https://github.com/TwhomeGH/HaishinKitFixSwfit.git`

### Basic RTMP Publishing

```swift
import HaishinKit
import RTMPHaishinKit

// Register RTMP factory
await StreamSessionBuilderFactory.shared.register(RTMPSessionFactory())

// Create session
let session = try await StreamSessionBuilderFactory.shared
    .make(URL(string: "rtmp://your-server/live/streamKey")!)
    .setMode(.publish)
    .build()

// Configure video settings
var videoSettings = await session.stream.videoSettings
videoSettings.bitRate = 2_000_000  // 2 Mbps
videoSettings.videoSize = CGSize(width: 1280, height: 720)
try await session.stream.setVideoSettings(videoSettings)

// Start streaming
try await session.connect {
    print("Disconnected")
}

// Publish stream
try await session.stream.publish("streamKey")
```

## Documentation Index

| Document | Description |
|----------|-------------|
| [Architecture](ARCHITECTURE.md) | System architecture and data flow |
| [RTMP Protocol](RTMP_PROTOCOL.md) | RTMP implementation details |
| [Media Mixer](MEDIA_MIXER.md) | Audio/Video mixing and effects |
| [Session Management](SESSION_MANAGEMENT.md) | StreamSession lifecycle |
| [Codec Configuration](CODEC_CONFIGURATION.md) | Video/Audio codec settings |
| [Network Layer](NETWORK_LAYER.md) | Network transport and monitoring |
| [Development Guide](DEVELOPMENT_GUIDE.md) | Contributing and development setup |
| [Testing](TESTING.md) | Test structure and running tests |
| [Troubleshooting](TROUBLESHOOTING.md) | Common issues and solutions |

## Dependencies

### System Frameworks

- `AVFoundation` - Media capture and encoding
- `VideoToolbox` - Hardware video encoding/decoding
- `AudioToolbox` - Audio processing
- `Network` - NWConnection for TCP/UDP
- `CoreMedia` - Media timing and formats
- `Combine` - Reactive programming

### Swift Package Dependencies

```swift
// Package.swift
dependencies: [
    // No external dependencies - uses only Apple frameworks
]
```

## License

MIT License - See [LICENSE](../LICENSE) for details.