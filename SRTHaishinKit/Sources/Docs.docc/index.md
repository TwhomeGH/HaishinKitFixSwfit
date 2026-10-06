# ``SRTHaishinKit``

本模組支援 SRT 協定。

## 🔍 Overview

SRTHaishinKit 是以 Swift 實作的 SRT 協定堆疊。內部使用由 [libsrt](https://github.com/Haivision/srt) 建置並轉為 xcframework 的函式庫。

## 🎨 功能

- 發布（Publish）
  - 支援 H264、HEVC 與 AAC。
- 播放（Playback）
  - 支援 H264、HEVC 與 AAC。
- SRT 模式
  - [x] caller
  - [x] listener
  - [x] rendezvous

## 📓 使用方式

### 日誌（Logging）

- 包裝 `srt_setloglevel` 的 Swift 方法。

```swift
await SRTLogger.shared.setLevel(.debug)
```

### 發布

```swift
let mixer = MediaMixer()
let connection = SRTConnection()
let stream = SRTStream(connection: connection)
let hkView = MTHKView(frame: view.bounds)

Task {
  do {
    try await mixer.attachAudio(AVCaptureDevice.default(for: .audio))
  } catch {
    print(error)
  }

  do {
    try await mixer.attachVideo(AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back))
  } catch {
    print(error)
  }

  await mixer.addOutput(stream)
}

Task { MainActor in
  await stream.addOutput(hkView)
  // add ViewController#view
  view.addSubview(hkView)
}

Task {
  do {
    try await connection.connect("srt://host:port")
    await stream.publish()
  } catch {
    print(error)
  }
}
```

### 播放

```swift
let connection = SRTConnection()
let stream = SRTStream(connection: connection)
let hkView = MTHKView(frame: view.bounds)
let audioPlayer = AudioPlayer(AVAudioEngine())

Task { MainActor in
  await stream.addOutput(hkView)
  // add ViewController#view
  view.addSubview(hkView)
}

Task {
  // requires attachAudioPlayer
  await stream.attachAudioPlayer(audioPlayer)

  do {
    try await connection.connect("srt://host:port")
    await stream.play()
  } catch {
    print(error)
  }
}
```

### 指定 socket 選項

- HaishinKit 端預設沿用 libsrt 的設定。
  - 支援狀況請見[這段程式碼](https://github.com/shogo4405/HaishinKit.swift/blob/main/SRTHaishinKit/Sources/SRT/SRTSocketOption.swift)。
- 多數 SRT 選項可用連接 URL 的查詢參數指定，如下：

```swift
try await connection.connect("srt://host:port?key=value")
```

### Session

```swift
import SRTHaishinKit

await StreamSessionBuilderFactory.shared.register(SRTSessionFactory())
```

## 🔧 測試

### 以 ffplay 作為 SRT 服務，發布給 HaishinKit

```sh
ffplay -i 'srt://${YOUR_IP_ADDRESS}?mode=listener'
```

### 以 ffmpeg 作為 SRT 服務，讓 HaishinKit 播放

```sh
ffmpeg -stream_loop -1 -re -i input.mp4 -c copy -f mpegts 'srt://0.0.0.0:9998?mode=listener'
```

## 📜 授權

### SRTHaishinKit

- SRTHaishinKit 採 BSD-3-Clause 授權。

### libsrt.xcframework

- libsrt.xcframework 採 MPLv2.0 授權。
- 這是將 [Haivision/srt](https://github.com/Haivision/srt) 建置為 xcframework 的產物。
