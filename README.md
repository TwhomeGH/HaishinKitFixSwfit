# HaishinKitFixSwfit — Fixed Version

[![GitHub license](https://img.shields.io/badge/License-BSD%203--Clause-blue.svg)](LICENSE.md)

[中文版](./README.zh.md)

This is an improved version of [HaishinKit/HaishinKit.swift](https://github.com/HaishinKit/HaishinKit.swift) with streaming stability fixes and enhanced bitrate control.

## 🔧 Fixes over upstream

- **VBR availability**: `kVTCompressionPropertyKey_VariableBitRate` now available from iOS 13+ (upstream incorrectly limited to iOS 26+)
- **New bitrate control modes**: Added `.quality` mode, VBV parameters (`vbvMaxBitRate`, `vbvBufferDuration`, `vbvInitialDelayPercentage`), `estimatedAverageBytesPerFrame`
- **Adaptive BitRate strategy rework**: Faster recovery (5s instead of 15s), zero-byte now halves bitrate, cooldown mechanism to prevent thrashing
- **NetworkMonitor queue detection**: Added absolute queue size threshold (512KB) — detects sustained congestion even when queue stops growing
- **Removed Logboard dependency**: Replaced with built-in OSLog to eliminate git checkout issues on Windows
- **RTMP User Control crash guard**: Malformed packets under 6 bytes no longer crash
- **WHEP playback fixes** (shared modules): decode failure logging, DisplayLink frameInterval=0 fallback, MediaLink audio clock guard

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
