# Codec Configuration

## Overview

Codec configuration in HaishinKit.swift provides flexible settings for both video and audio encoding. The framework supports multiple codecs with various quality levels and bitrates.

## Video Codecs

### Supported Formats

| Format | Description |
|--------|-------------|
| H.264 | Advanced Video Coding (AVC) |
| H.265 | High Efficiency Video Coding (HEVC) |
| VP9 | Google's video codec |
| AV1 | Alliance for Open Media codec |

### VideoCodecSettings

```swift
public struct VideoCodecSettings {
    public var format: Format
    public var videoSize: CGSize
    public var expectedFrameRate: Float64?
    public var bitRate: Int
    public var bitRateMode: BitRateMode
    public var isLowLatencyRateControlEnabled: Bool
}
```

### Format Enum

```swift
public enum Format: String, CaseIterable {
    case h264 = "h264"
    case hevc = "hevc"
    case vp9 = "vp9"
    case av1 = "av1"
}
```

## Audio Codecs

### Supported Formats

| Format | Description |
|--------|-------------|
| AAC | Advanced Audio Coding |
| Opus | Internet audio codec |
| PCM | Pulse Code Modulation |

### AudioCodecSettings

```swift
public struct AudioCodecSettings {
    public var format: Format
    public var sampleRate: Double
    public var bitRate: Int
    public var isLowLatencyRateControlEnabled: Bool
}
```

### Format Enum

```swift
public enum Format: String, CaseIterable {
    case aac = "aac"
    case opus = "opus"
    case pcm = "pcm"
}
```

## Bitrate Control Modes

### BitRateMode

```swift
public enum BitRateMode: String {
    case average = "average"
    case constant = "constant"
    case variable = "variable"
}
```

## Configuration Parameters

### Video Settings

| Parameter | Default | Description |
|----------|---------|-------------|
| `videoSize` | 1280x720 | Resolution |
| `expectedFrameRate` | 30.0 | Target FPS |
| `bitRate` | 2000000 | Bitrate (bps) |
| `bitRateMode` | average | Control mode |
| `isLowLatencyRateControlEnabled` | false | Low latency |

### Audio Settings

| Parameter | Default | Description |
|----------|---------|-------------|
| `sampleRate` | 44100.0 | Audio sample rate |
| `bitRate` | 128000 | Bitrate (bps) |
| `isLowLatencyRateControlEnabled` | false | Low latency |

## Codec Specific Settings

### H.264 Configuration

```swift
// Uses VideoToolbox with H.264 encoder
// Supports baseline, main, high profiles
```

### H.265 Configuration

```swift
// Uses VideoToolbox with HEVC encoder
// Supports various HEVC profiles
```

### AAC Configuration

```swift
// Uses AudioToolbox with AAC encoder
// Supports various AAC profiles
```

### Opus Configuration

```swift
// Uses AudioToolbox with Opus encoder
// Supports low-delay, high-quality modes
```

## Code References

- VideoCodecSettings.swift: Video codec settings
- AudioCodecSettings.swift: Audio codec settings  
- Codec.swift: Codec base implementations
- VideoToolboxCodec.swift: Hardware video encoding
- AudioToolboxCodec.swift: Hardware audio encoding