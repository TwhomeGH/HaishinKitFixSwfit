# HaishinKitFixSwfit — Fixed Version

[![GitHub license](https://img.shields.io/badge/License-BSD%203--Clause-blue.svg)](LICENSE.md)

[中文版](./README.zh.md)

This is an improved version of [HaishinKit/HaishinKit.swift](https://github.com/HaishinKit/HaishinKit.swift) with streaming stability fixes, enhanced bitrate control, and voice chat coexistence support.

## 🔧 Fixes over upstream

- **VBR availability**: `kVTCompressionPropertyKey_VariableBitRate` now available from iOS 13+ (upstream incorrectly limited to iOS 26+)
- **VBR data rate limits**: VBR mode now enforces `dataRateLimits` (1.5× soft cap) on all iOS versions + auto `vbvMaxBitRate` (1.2× hard cap) on iOS 26+, preventing encoder spikes from overwhelming the RTMP output queue
- **New bitrate control modes**: Added `.quality` mode, VBV parameters (`vbvMaxBitRate`, `vbvBufferDuration`, `vbvInitialDelayPercentage`), `estimatedAverageBytesPerFrame`
- **Adaptive BitRate strategy rework**: Faster recovery (5s instead of 15s), zero-byte now halves bitrate, cooldown mechanism to prevent thrashing
- **Egress pipeline fix**: Unified `.bufferingNewest` drop policy across RTMPStream → RTMPConnection → RTMPSocket to prevent stream corruption under backpressure
- **MediaMixerOutput bridge**: Eliminated `nonisolated(unsafe)` continuations and per-frame `Task{}` allocations (~80/s), replaced with direct `Sendable` bridge yielding
- **Bounded codec output**: `VideoCodec.outputStream` capped at 60 frames (`.bufferingNewest`) to prevent unbounded memory growth
- **Audio stall detection**: Added `restartAudioPipeline()` symmetric to existing `restartVideoPipeline()`, recovering from silent audio encoder stalls
- **NetworkMonitor queue detection**: Added absolute queue size threshold (512KB) — detects sustained congestion even when queue stops growing
- **Removed Logboard dependency**: Replaced with built-in OSLog to eliminate git checkout issues on Windows
- **RTMP User Control crash guard**: Malformed packets under 6 bytes no longer crash
- **WHEP playback fixes** (shared modules): decode failure logging, DisplayLink frameInterval=0 fallback, MediaLink audio clock guard
- **Voice chat coexistence** (iOS): New `AudioRouteManager` + `MediaMixer.setVoiceChatEnabled(_:)` enables mic capture for streaming while simultaneously running a voice call (VoIP). Uses `.playAndRecord` + `.voiceChat` mode + `.mixWithOthers` so background audio keeps playing. AVAudioEngine tap feeds mic into the existing encode pipeline without duplicating ReplayKit's `.audioMic`.

See [CHANGES.md](CHANGES.md) for full details.

## 💬 Community & Support

- **Discord**: https://discord.gg/t8E7MnYeaC
- **Twitch**: https://www.twitch.tv/coffeelatte0709

## 🌏 Requirements

| Version | Xcode | Swift |
|:----:|:----:|:----:|
| 2.2.0+ | 26.0+ | 6.0+ |

| iOS | tvOS | Mac Catalyst | macOS | visionOS |
|:-:|:-:|:-:|:-:|:-:|
| 15.0+ | 15.0+ | 15.0+ | 12.0+ | 1.0+ |

## 📖 Installation

### Swift Package Manager

```swift
.package(url: "https://github.com/TwhomeGH/HaishinKitFixSwfit.git", branch: "main")
```

Or in Xcode: **File → Add Package Dependencies...** → enter `https://github.com/TwhomeGH/HaishinKitFixSwfit.git`

## 📃 Documentation

- [API Documentation](https://docs.haishinkit.com/swift/latest/documentation/)
- [CHANGES.md](CHANGES.md) — full changelog of this fork

## 📜 License

BSD-3-Clause
