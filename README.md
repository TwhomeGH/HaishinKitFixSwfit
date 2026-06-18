# HaishinKitFixSwfit — Maintained Fork

[![GitHub license](https://img.shields.io/badge/License-BSD%203--Clause-blue.svg)](LICENSE.md)

This is a **maintained fork** of [HaishinKit/HaishinKit.swift](https://github.com/HaishinKit/HaishinKit.swift) with the following fixes and enhancements:

## 🔧 Fixes over upstream

- **VBR availability**: `kVTCompressionPropertyKey_VariableBitRate` now available from iOS 13+ (upstream incorrectly limited to iOS 26+)
- **New bitrate control modes**: Added `.quality` mode, VBV parameters (`vbvMaxBitRate`, `vbvBufferDuration`, `vbvInitialDelayPercentage`), `estimatedAverageBytesPerFrame`
- **Adaptive BitRate strategy rework**: Faster recovery (5s instead of 15s), zero-byte handling now also reduces bitrate, cooldown mechanism to prevent thrashing
- **NetworkMonitor queue detection**: Added absolute queue size threshold (512KB) — detects sustained congestion even when queue stops growing
- See [CHANGES.md](CHANGES.md) for full details.

## 💖 Sponsors
Do you need additional support? Technical support on Issues and Discussions is provided only to contributors and academic researchers of HaishinKit. By becoming a sponsor, I can provide the support you need.

Sponsor: [$50 per month](https://github.com/sponsors/shogo4405): Technical support via GitHub Issues/Discussions with priority response.

## 🎨 Features
- **Protocols** ✨Publish and playback feature are available [RTMP](RTMPHaishinKit/Sources/Docs.docc/index.md), [SRT](SRTHaishinKit/Sources/Docs.docc/index.md) and [WHEP/WHIP(alpha)](RTCHaishinKit/Sources/Docs.docc/index.md).
- **Multi Camera access** ✨[Support multitasking camera access.](https://developer.apple.com/documentation/avkit/accessing-the-camera-while-multitasking-on-ipad)
- **Multi Streaming** ✨Allowing live streaming to separate services. Views also support this, enabling the verification of raw video data.
- **Strict Concurrency** ✨Supports Swift's Strict Concurrency compliance.
- **Screen Capture** ✨Supports ReplayKit(iOS) and ScreenCaptureKit(macOS) api.
- **Video mixing** ✨Possible to display any text or bitmap on a video during broadcasting or viewing. This allows for various applications such as watermarking and time display.
  |Publish|Playback|
  |:---:|:---:|
  |<img width="961" alt="" src="https://github.com/user-attachments/assets/aaf6c06f-d2de-43c1-a435-90907f370977">|<img width="849" alt="" src="https://github.com/user-attachments/assets/0a07b418-aa56-41cb-8e6d-e12596b25ae8">|

## 🌏 Requirements

### Development
|Version|Xcode|Swift|
|:----:|:----:|:----:|
|2.2.0+|26.0+|6.0+|
|2.1.0+|16.4+|6.0+|

### OS
|iOS|tvOS|Mac Catalyst|macOS|visionOS|watchOS|
|:-:|:-:|:-:|:-:|:-:|:-:|
|15.0+|15.0+|15.0+|12.0+|1.0+|-|

- SRTHaishinKit is not avaliable for Mac Catalyst. 

## 📖 Getting Started

> [!IMPORTANT]
> There are several issues that occur when connected to Xcode. Please also refer to [this document](https://github.com/HaishinKit/HaishinKit.swift/blob/main/HaishinKit/Sources/Docs.docc/known-issue.md).

### 🔧 Examples
- Reference implementation app for live streaming `publish` and `playback`.
- If an issue occurs, please check whether it also happens in the examples app.

#### Usage

You can verify by changing the URL of the following file.
https://github.com/HaishinKit/HaishinKit.swift/blob/abf1883d25d0ba29e1d1d67ea9e3a3b5be61a196/Examples/Preference.swift#L1-L7

#### Download
```sh
git clone https://github.com/HaishinKit/HaishinKit.swift.git
cd HaishinKit.swift
open Examples/Examples.xcodeproj
```

### 🔧 Installation
#### Using Swift Package Manager
```sh
https://github.com/HaishinKit/HaishinKit.swift
```

### 🔧 Prerequisites

#### AVAudioSession
Make sure you setup and activate your AVAudioSession iOS.

```swift
import AVFoundation

let session = AVAudioSession.sharedInstance()
do {
    try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
    try session.setActive(true)
} catch {
    print(error)
}
```

### 🔧 Cocoa Keys
Please make sure to contains `Info.plist` the following values when accessing the camera or microphone.
```xml
<key>NSCameraUsageDescription</key>
<string>your usage description here</string>
<key>NSMicrophoneUsageDescription</key>
<string>your usage description here</string>
```

## 📃 Documentation
- [API Documentation](https://docs.haishinkit.com/swift/latest/documentation/)
- [Migration Guide](https://github.com/HaishinKit/HaishinKit.swift/wiki#-migration-guide)

## 🌏 Related projects
Project name    |Notes       |License
----------------|------------|--------------
[HaishinKit for Android.](https://github.com/HaishinKit/HaishinKit.kt)|Camera and Microphone streaming library via RTMP for Android.|[BSD 3-Clause "New" or "Revised" License](https://github.com/HaishinKit/HaishinKit.kt/blob/master/LICENSE.md)
[HaishinKit for Flutter.](https://github.com/HaishinKit/HaishinKit.dart)|Camera and Microphone streaming library via RTMP for Flutter.|[BSD 3-Clause "New" or "Revised" License](https://github.com/HaishinKit/HaishinKit.dart/blob/master/LICENSE.md)

## 📜 License
BSD-3-Clause
