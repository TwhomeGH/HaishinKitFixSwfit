# ``HaishinKit``

這是主要模組。

## 🔍 Overview

提供直播所需的攝影機與麥克風混音功能，也提供各模組共用的處理。

### 模組結構

| 模組 | 說明 |
| :- | :- |
| HaishinKit | 本模組。 |
| RTMPHaishinKit | 提供 RTMP 協定堆疊。 |
| SRTHaishinKit | 提供 SRT 協定堆疊。 |
| RTCHaishinKit | 提供 WebRTC WHEP/WHIP 協定堆疊。目前為 alpha。 |
| MoQTHaishinKit | 提供 MoQT 協定堆疊。目前為 alpha。 |

## 🎨 功能

提供下列功能：

- 直播混音（Live Mixing）
  - [影像混音](doc://HaishinKit/videomixing)
    - 將攝影機影像與靜態圖片視為單一的串流來源。
  - 音訊混音
    - 將多個麥克風音訊來源合併為單一的音訊串流來源。
- Session
  - 為 RTMP、SRT、WHEP、WHIP 等協定提供統一 API。

## 📖 使用方式

### 直播混音

```swift
let mixer = MediaMixer()

Task {
  do {
    // Attaches the microphone device.
    try await mixer.attachAudio(AVCaptureDevice.default(for: .audio))
  } catch {
    print(error)
  }

  do {
    // Attaches the camera device.
    try await mixer.attachVideo(AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back))
  } catch {
    print(error)
  }

  // Associates the stream object with the MediaMixer.
  await mixer.addOutput(stream)
  await mixer.startRunning()
}
```

### StreamSession API

提供以 RTMP 與 SRT 實作客戶端的統一 API，重試處理亦由 API 內部完成。

#### 前置準備

```swift
import HaishinKit
import RTMPHaishinKit
import SRTHaishinKit

Task {
  await StreamSessionBuilderFactory.shared.register(RTMPSessionFactory())
  await StreamSessionBuilderFactory.shared.register(SRTSessionFactory())
}
```

#### 建立 StreamSession

**RTMP**
請提供結合 streamName 的 RTMP 連線 URL。

```swift
let session = try await StreamSessionBuilderFactory.shared.make(URL(string: "rtmp://hostname/appName/stramName"))
  .setMode(.publish)
  .build()
```

**SRT**
請提供帶 stream 查詢參數的 SRT 連線 URL。

```swift
let session = try await StreamSessionBuilderFactory.shared.make(URL(string: "srt://hostname:448?stream=xxxxx"))
  .setMode(.playback)
  .build()
```

#### 連線

用於發布或播放。

```swift
try session.connect {
  print("on disconnected")
}
```

## Topics

### 指南

- <doc:ARCHITECTURE>
- <doc:CODEC_CONFIGURATION>
- <doc:MEDIA_MIXER>

### 影片管線診斷

- <doc:VideoPipelineDiagnostics>
- ``VideoPipelineSnapshot``
- ``VideoQueueSnapshot``
- ``VideoPipelineEventsSnapshot``

### 音訊與混音診斷

- ``AudioPipelineDiagnostics``
- ``MediaMixerOutput``

### 網路監控

- ``NetworkMonitorReport``
- ``NetworkMonitorEvent``

## 診斷資料判讀

累計量須取差值再計算速率。目前佇列大小是 bytes，網路速率是 bytes/s；音訊區塊數與 PCM 樣本數也須分開。Mixer 產出不等於編碼完成，傳輸層完成不等於伺服器已解碼。
