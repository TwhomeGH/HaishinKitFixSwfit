# Media Mixer

## 概述

MediaMixer 是 HaishinKit.swift 的核心元件，負責管理來自多個來源的影音串流。提供：

- 多軌影音混合
- 硬體加速編解碼
- 即時特效處理
- 螢幕擷取功能
- 串流路由到不同輸出目標

## Audio Session 事件處理

MediaMixer 自動管理 `AVAudioSession` 事件，無需外部配置。

### 中斷事件（Interruption）

監聽 `AVAudioSession.interruptionNotification`：
- **Began**：`audioIO.suspend()` 卸除所有 AVCaptureDevice 音訊輸入，`session.startRunningIfNeeded()` 保持視訊運作
- **Ended + shouldResume**：`audioIO.resume()` 重新附接音訊輸入

### 路由變更（Route Change）

監聽 `AVAudioSession.routeChangeNotification`：

| 原因 | 動作 |
|------|------|
| `.oldDeviceUnavailable` | `audioIO.suspend()` + `audioIO.resume()` |
| `.newDeviceAvailable` | `audioIO.suspend()` + `audioIO.resume()` |
| `.routeConfigurationChange` | `audioIO.suspend()` + `audioIO.resume()` |
| 其他 | 忽略 |

路由變更發生時重新附接 capture 裝置，確保語音模式切換（`.default` ↔ `.voiceChat`）、耳機插拔、藍牙連接後音訊管線持續運作。

### 清理

`deinit` 自動取消所有 notification subscription tasks，防止 `MediaMixer` 釋放後遺留 dangling observer。

---

## 架構

```
┌─────────────────────────────────────┐
│      MediaMixer                     │
│  核心串流管理                        │
├─────────────────────────────────────┤
│      Audio Mixer                    │
│  音訊軌道管理                        │
├─────────────────────────────────────┤
│      Video Mixer                    │
│  視訊軌道管理                        │
├─────────────────────────────────────┤
│      Stream 輸出                    │
│  串流路由到目的地                    │
└─────────────────────────────────────┘
```

## 核心元件

### MediaMixer

主要的混合器類別管理：
- 多個視訊/音訊軌道
- 擷取 Session 設定
- 輸出路由
- 串流監控
- 特效處理

```swift
actor MediaMixer {
    private var videoMixerSettings: VideoMixerSettings
    private var audioMixerSettings: AudioMixerSettings
    private var outputs: [any StreamOutput]
    private var captureSessionMode: CaptureSessionMode
}
```

### VideoMixerSettings

控制視訊混合參數：
```swift
public struct VideoMixerSettings {
    public var mode: VideoMixerMode
    public var mainTrack: UInt8
    public var tracks: [VideoTrackSettings]
    public var effects: [any VideoEffect]
}
```

### AudioMixerSettings

控制音訊混合參數：
```swift
public struct AudioMixerSettings {
    public var tracks: [AudioTrackSettings]
    public var effects: [any AudioEffect]
}
```

## 串流管理

### StreamOutput

串流輸出可以是：
- RTMPStream（發布用）
- AVPlayer（播放用）
- View（顯示用）
- ScreenCapture（螢幕錄製用）

```swift
public protocol StreamOutput {
    func stream(_ stream: any StreamConvertible, didOutput sampleBuffer: CMSampleBuffer)
    func stream(_ stream: any StreamConvertible, didOutput buffer: AVAudioBuffer, when: AVAudioTime)
}
```

## 擷取來源

### 視訊擷取

```swift
func attachVideo(_ device: AVCaptureDevice?, track: UInt8) async throws
func setVideoOrientation(_ orientation: AVCaptureVideoOrientation) async throws
```

### 音訊擷取

```swift
func attachAudio(_ device: AVCaptureDevice?) async throws
```

## 特效處理

### 視訊特效

支援多種視訊特效：
- 濾鏡（模糊、銳化）
- 變換（旋轉、縮放）
- 疊加圖形
- 色彩校正

### 音訊特效

支援音訊特效：
- 濾波器（低通、高通）
- 音量控制
- 等化器
- 降噪

## 硬體加速

### VideoToolbox 整合

使用 VideoToolbox 進行：
- H.264/H.265 編碼
- VP9/AV1 解碼
- 硬體加速處理

### AudioToolbox 整合

使用 AudioToolbox 進行：
- AAC/Opus 編碼
- 音訊處理濾波器
- 即時音訊操作

## 程式碼參考

- MediaMixer.swift：主要混合器實作
- VideoMixerSettings.swift：視訊設定管理
- AudioMixerSettings.swift：音訊設定管理
- StreamOutput.swift：串流輸出協定
- CaptureSession.swift：擷取 Session 處理