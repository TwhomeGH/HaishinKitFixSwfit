# ``RTMPHaishinKit``

本模組支援 RTMP 協定。

## 🔍 Overview

RTMPHaishinKit 是以 Swift 實作的 RTMP 協定堆疊。

## 🎨 功能

- [x] 相容 FMLE 的認證
- [x] 發布（Publish）
  - 支援 H264、HEVC、AAC 與 OPUS。
- [x] 播放（Playback）
  - 支援 H264、HEVC 與 AAC。
- [ ] Action Message Format
  - [x] AMF0
  - [ ] AMF3
- [x] SharedObject
- [x] RTMPS
  - [x] Native（RTMP over SSL/TLS）
- [x] [Enhanced RTMP](E-RTMP.md)

## 📓 使用方式

### 發布

```swift
let mixer = MediaMixer()
let connection = RTMPConnection()
let stream = RTMPStream(connection: connection)
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
    try await connection.connect("rtmp://localhost/appName/instanceName")
    try await stream.publish(streamName)
  } catch RTMPConnection.Error.requestFailed(let response) {
    print(response)
  } catch RTMPStream.Error.requestFailed(let response) {
    print(response)
  } catch {
    print(error)
  }
}
```

### 播放

```swift
let connection = RTMPConnection()
let stream = RTMPStream(connection: connection)
let audioPlayer = AudioPlayer(AVAudioEngine())

let hkView = MTHKView(frame: view.bounds)

Task { MainActor in
  await stream.addOutput(hkView)
}

Task {
  // requires attachAudioPlayer
  await stream.attachAudioPlayer(audioPlayer)

  do {
    try await connection.connect("rtmp://localhost/appName/instanceName")
    try await stream.play(streamName)
  } catch RTMPConnection.Error.requestFailed(let response) {
    print(response)
  } catch RTMPStream.Error.requestFailed(let response) {
    print(response)
  } catch {
    print(error)
  }
}
```

### 認證

支援相容 FME 的認證。其他服務可能使用各自專屬的認證方式，在那些情況下可能無法連線。

```swift
var connection = RTMPConnection()
connection.connect("rtmp://username:password@localhost/appName/instanceName")
```

## Topics

### 協定

- <doc:RTMP_PROTOCOL>

### 連線與傳送診斷

- ``RTMPConnection``
- ``RTMPTransportDiagnostics``
- ``RTMPLogEvent``
- ``RTMPLogLevel``

### 串流狀態與回應

- ``RTMPStatus``
- ``RTMPResponse``
- ``RTMPStreamInfo``

## 使用傳送診斷

```swift
if let snapshot = await connection.transportDiagnostics() {
    print(snapshot.completedBytes, snapshot.failedBatchBytes)
}
```

建議每秒取樣。queuedBytes 包含正在送的批次，completedBytes 只計無錯誤完成；failedBatchBytes 是失敗批次大小，不代表所有 bytes 都未傳出。

批次數不等於 RTMP chunk 數；acknowledgedBytes 目前為 nil。

本 API 尚未涵蓋影音分類、chunk 數與伺服器 ACK；不能推論遠端已收到或成功解碼。
