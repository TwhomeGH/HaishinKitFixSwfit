# Media Mixer

## Overview

The MediaMixer in HaishinKit.swift is a core component responsible for managing audio and video streams from multiple sources. It provides:

- Multi-track audio/video mixing
- Hardware-accelerated encoding/decoding
- Real-time effects processing
- Screen capture capabilities
- Stream routing to different outputs

## Architecture

```
┌─────────────────────────────────────┐
│      MediaMixer                     │
│  Core stream management             │
├─────────────────────────────────────┤
│      Audio Mixer                    │
│  Audio track management             │
├─────────────────────────────────────┤
│      Video Mixer                    │
│  Video track management             │
├─────────────────────────────────────┤
│      Stream Outputs                 │
│  Stream routing to destinations     │
└─────────────────────────────────────┘
```

## Key Components

### MediaMixer

The main mixer class manages:
- Multiple video/audio tracks 
- Capture session configuration
- Output routing
- Stream monitoring
- Effects processing

```swift
actor MediaMixer {
    private var videoMixerSettings: VideoMixerSettings
    private var audioMixerSettings: AudioMixerSettings
    private var outputs: [any StreamOutput]
    private var captureSessionMode: CaptureSessionMode
}
```

### VideoMixerSettings

Controls video mixing parameters:
```swift
public struct VideoMixerSettings {
    public var mode: VideoMixerMode
    public var mainTrack: UInt8
    public var tracks: [VideoTrackSettings]
    public var effects: [any VideoEffect]
}
```

### AudioMixerSettings

Controls audio mixing parameters:
```swift
public struct AudioMixerSettings {
    public var tracks: [AudioTrackSettings]
    public var effects: [any AudioEffect]
}
```

## Stream Management

### StreamOutput

Stream outputs can be:
- RTMPStream (for publishing)
- AVPlayer (for playback)
- View (for display)
- ScreenCapture (for screen recording)

```swift
public protocol StreamOutput {
    func stream(_ stream: any StreamConvertible, didOutput sampleBuffer: CMSampleBuffer)
    func stream(_ stream: any StreamConvertible, didOutput buffer: AVAudioBuffer, when: AVAudioTime)
}
```

## Capture Sources

### Video Capture

```swift
func attachVideo(_ device: AVCaptureDevice?, track: UInt8) async throws {
    // Attach camera or screen capture
}

func setVideoOrientation(_ orientation: AVCaptureVideoOrientation) async throws {
    // Set video orientation
}
```

### Audio Capture

```swift
func attachAudio(_ device: AVCaptureDevice?) async throws {
    // Attach microphone or system audio
}
```

## Effects Processing

### VideoEffects

Supports various video effects:
- Filters (blur, sharpen)
- Transformations (rotation, scaling)
- Overlay graphics
- Color correction

### AudioEffects

Supports audio effects:
- Filters (low-pass, high-pass)
- Volume control
- Equalization
- Noise reduction

## Hardware Acceleration

### VideoToolbox Integration

Uses VideoToolbox for:
- H.264/H.265 encoding
- VP9/AV1 decoding
- Hardware-accelerated processing

### AudioToolbox Integration

Uses AudioToolbox for:
- AAC/Opus encoding
- Audio processing filters
- Real-time audio manipulation

## Code References

- MediaMixer.swift: Main mixer implementation
- VideoMixerSettings.swift: Video settings management
- AudioMixerSettings.swift: Audio settings management
- StreamOutput.swift: Stream output protocol
- CaptureSession.swift: Capture session handling