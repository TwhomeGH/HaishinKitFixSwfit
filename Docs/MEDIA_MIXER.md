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
- **Began**：記錄 `isAudioSessionInterrupted = true`，`audioIO.suspend()` 卸除所有 AVCaptureDevice 音訊輸入，`session.startRunningIfNeeded()` 保持視訊運作
- **Ended + shouldResume**：依中斷期間是否收到有效 route change 決定 `audioIO.resume()` 或 `audioIO.reset()`，再呼叫輸出端 `restartAudioEncoding(reason:)`
- **Ended without shouldResume**：不自動恢復音訊 capture，清除延後 reset 狀態，交由上層或後續 session 事件處理

### 路由變更（Route Change）

監聽 `AVAudioSession.routeChangeNotification`：

| 狀態 | 原因 | 動作 |
|------|------|------|
| 非 interruption 中 | `.oldDeviceUnavailable` | `audioIO.reset()` 後 `restartAudioEncoding(reason:)` |
| 非 interruption 中 | `.newDeviceAvailable` | `audioIO.reset()` 後 `restartAudioEncoding(reason:)` |
| 非 interruption 中 | `.routeConfigurationChange` | `audioIO.reset()` 後 `restartAudioEncoding(reason:)` |
| interruption 中 | 上述三種原因 | 延後 reset，等 interruption ended 且 `.shouldResume` 時處理 |
| 任意 | 其他原因 | 不重建管線 |

路由變更發生時會重新附接 capture 裝置，確保語音模式切換（`.default` ↔ `.voiceChat`）、耳機插拔、藍牙連接後音訊輸入側持續運作。`MediaMixer` 會先透過 `MediaMixerOutput.mixer(_:didReceiveAudioSessionEvent:)` 將 audio session 狀態送給輸出端；RTMPStream 會把這些事件寫入 RTMP connection `onLog`。完成輸入側恢復後，`MediaMixer` 再對已掛上的 `StreamConvertible` 輸出呼叫 `restartAudioEncoding(reason:)`，讓 RTMP 等輸出端用自己的 recovery API 重接 codec output stream 與 publish tasks。

這裡刻意區分兩層責任：

- `audioIO.reset()` / `audioIO.resume()`：恢復 capture 與 mixer 輸入側。
- `restartAudioEncoding(reason:)`：恢復 stream/output 的 audio encoder 與發布管線。

不要用單純 `audioIO.reset()` 取代輸出端 recovery；若 codec output `AsyncStream` 已更換或 publish consumer 需要重建，只重置 capture 層無法保證音訊恢復。

### 診斷資訊

Audio session event 與輸出端 recovery reason 會包含：

- `interrupted`
- `reason`
- `shouldResume`
- `category`
- `mode`
- `currentRoute`
- `previousRoute`

這些資訊用來確認當時系統回報的 session 狀態，避免把 `.shouldResume` 缺失、interruption 期間 route change、或非必要 route reason 誤判成同一種恢復流程。發布中的 RTMP 診斷透過 `MediaMixerOutput` audio session event callback 與 `restartAudioEncoding(reason:)` 送進 `RTMPConnection.onLog`。

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

## 多軌音訊跨軌對齊

`isMultiTrackAudioMixingEnabled` 模式（ReplayKit `.appAudio` / `.audioMic` 分軌）下，
兩軌混音必須以**來源端 PTS 派生**的位置對齊，否則「先到先混」會把兩軌的起始相位差
與積壓以錯誤的相對位置混入 → 回音/撕裂。實作於 `AudioRingBuffer.align(to:)` +
`AudioMixerByMultiTrack.render()`，詳細說明與問題區別見
[AUDIO_MULTITRACK_ALIGNMENT.md](AUDIO_MULTITRACK_ALIGNMENT.md)。
