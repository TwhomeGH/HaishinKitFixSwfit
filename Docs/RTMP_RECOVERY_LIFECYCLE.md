# RTMP Recovery Lifecycle Design

本文說明 RTMP 發布管線在 ReplayKit / app lifecycle / 網路恢復後的重啟設計。
重點是區分「上層知道外部事件發生」與「底層知道如何安全重接發送管線」。

## 背景

ReplayKit broadcast extension 可能出現這種狀態：

- RTMP socket 仍連線
- audio 持續送出
- app socket 心跳正常
- video track 在回放檔中提前結束，後段變成 audio-only

這不是典型 RTMP 斷線。它更常見於 ReplayKit pause/resume、背景/前景切換、
VideoToolbox session 停滯、或上層 video source 停止餵入後沒有恢復。

## 責任邊界

### 上層負責

上層 app 或 broadcast extension 最清楚外部 lifecycle 事件，例如：

- `broadcastPaused()`
- `broadcastResumed()`
- app/socket 控制層要求恢復
- 自己的 video processor 進入 inactive

上層應該在這些事件發生時呼叫明確的 recovery API，而不是透過重套相同設定嘗試觸發副作用。

### 底層負責

底層 stream 最清楚內部 publish pipeline 的連接關係，例如：

- codec 是否需要 stop/start
- codec output `AsyncStream` 是否已被替換
- publish consumer 是否要重新建立
- timestamp / sequence header 狀態是否應保留
- 重啟是否正在進行
- 外部事件是否過於高頻

因此底層必須提供語意明確、可重複呼叫且有保護的 recovery API。

## Public Recovery API

`StreamConvertible` 提供：

```swift
func restartVideoEncoding(reason: String) async
func restartAudioEncoding(reason: String) async
```

用途：

- ReplayKit `broadcastResumed()` 後恢復 video encoding
- 上層偵測 video processor 從 inactive 恢復後重接發送管線
- 音訊 route/interruption 恢復後需要明確重啟 audio encoding

不要把這兩個 API 當作一般每幀健康檢查使用；它們是 lifecycle/recovery 入口。

## 為什麼不能用同值 `setVideoSettings`

這種寫法不是可靠 recovery：

```swift
let settings = await stream.videoSettings
try await stream.setVideoSettings(settings)
```

`VideoCodecSettings.invalidateSession(_:)` 只有在會影響 encoder session 的設定真的變更時，
才會讓 `VideoCodec` invalidate session。相同 settings 只會走 apply 路徑，通常不會重建
VideoToolbox session。

因此上層 log 若寫「Video encoder 已重建」，實際上可能沒有發生任何重建。

## 設定更新與管線重啟

`setVideoSettings(_:)` 的語意是更新 stream 持有的 video 設定。它不是通用的 pipeline
recovery API，也不保證「正在運行中的」VideoToolbox session 或 RTMP publish tasks 會立刻完整重接。

設定套用可分成兩類：

- 可動態套用的欄位，例如 bitrate 類設定，底層會嘗試套到現有 codec session。
- 需要新 encoder session 才可靠生效的欄位，例如解析度、profile、reordering、部分低延遲/硬體編碼選項。

如果上層的意圖是「更正配置，並確保目前正在發布的 video pipeline 使用新的 encoder session」，
應該先更新設定，再明確重啟 video encoding：

```swift
var settings = await rtmpStream.videoSettings
settings.videoSize = CGSize(width: 1280, height: 720)
settings.profileLevel = kVTProfileLevel_H264_High_AutoLevel as String
try await rtmpStream.setVideoSettings(settings)

await rtmpStream.restartVideoEncoding(
    reason: "video settings updated: size/profile changed"
)
```

這個模式適合：

- broadcast resume 後重新確認/修正輸出尺寸
- server codec capability fallback 後從 HEVC 改 H.264
- 使用者在直播中切換 profile、解析度、B-frame/reordering 類設定
- 偵測到上層配置曾套用但 video pipeline 沒有恢復

如果只是 bitrate 這類高頻調整，不應每次都呼叫 `restartVideoEncoding(reason:)`；讓
`setVideoSettings(_:)` 動態 apply 即可，避免不必要的 GOP/encoder churn。

音訊設定也遵守同一個原則。只調整 audio bitrate 時，讓現有 converter 動態 apply；
若更改 `format`、`channelMap` 或其他需要新 converter/output format 的配置，應先
`setAudioSettings(_:)`，再呼叫：

```swift
await rtmpStream.restartAudioEncoding(reason: "audio settings updated")
```

RTMP/FLV 預設應使用相容性優先的 `AudioCodecSettings.recommendedRtmpFormat` 與
`AudioCodecSettings.recommendedRtmpBitrate`。`bestAacFormat` / `bestAacBitrate`
偏向裝置支援與低碼率效率，不等於 RTMP 最保守相容預設。

## RTMPStream 的保證

RTMP 不能只重啟 `VideoCodec`。原因是 codec stop/start 會替換 codec output stream；
如果 publish task 仍在聽舊 stream，新 encoder 即使產生輸出也不會送到 RTMP。

`RTMPStream.restartVideoEncoding(reason:)` 會：

1. 確認 stream 正在 `.publishing`
2. 對外部呼叫做 cooldown 節流
3. 進入 `restartVideoPipeline(reason:)`
4. 停止 publish tasks
5. 重啟 outgoing codecs
6. 重新建立 publish tasks，接到新的 codec output stream
7. 保留 `videoFormat` / `audioFormat`，避免同格式重啟時把 sequence header 用 timestamp 0 重送

這個流程讓上層不用知道 RTMP 內部 task/stream 連線細節。

## 防重入與防高頻

底層有兩層保護：

- `isRestartingPipelines`：避免 video/audio pipeline restart 同時重入
- public recovery cooldown：外部 `restartVideoEncoding` / `restartAudioEncoding` 3 秒內最多執行一次

cooldown 只放在 public API 入口。內部 stall detector 若根據實際 PTS/輸出健康狀態判定 encoder
真的卡住，仍可直接呼叫 private pipeline restart，不會被外部 cooldown 誤擋。

這樣可以同時處理兩種情境：

- 上層 lifecycle/socket event 抖動：被 public cooldown 吸收
- 真正 pipeline stall：底層健康檢查仍可恢復

## ReplayKit 上層建議

`broadcastPaused()` 不建議拆 RTMP 或 stop `MediaMixer`。它應只記錄 pause 狀態：

```swift
override func broadcastPaused() {
    isBroadcastPaused = true
    pausedAt = Date()
    sendlog(message: "broadcast paused")
}
```

`broadcastResumed()` 應視為明確 lifecycle 邊界，要求底層恢復 video pipeline：

```swift
override func broadcastResumed() {
    isBroadcastPaused = false

    guard isSessionReady, !isStopping else { return }

    let pauseDuration = pausedAt.map { Date().timeIntervalSince($0) } ?? 0
    pausedAt = nil

    Task(priority: .medium) { [weak self] in
        guard let self else { return }

        SocketClient.shared.connect()

        if !(await mediaMixer.isRunning) {
            await mediaMixer.startRunning()
        }

        await rtmpStream.restartVideoEncoding(
            reason: "broadcast resumed after \(String(format: "%.1f", pauseDuration))s"
        )

        if videoProcessor == nil || videoProcessor?.isActive != true {
            rebuildVideo()
        }
    }
}
```

## MediaMixer 注意事項

`MediaMixer.startRunning()` / `stopRunning()` 是 mixer lifecycle，不是 RTMP publish recovery API。

ReplayKit manual mode 下，source samples 是由上層 `processSampleBuffer` 主動 append 進 mixer。
若 pause/resume 只是 ReplayKit lifecycle 邊界，不應為了恢復 video encoder 而 stop mixer。

只有在確認 `mediaMixer.isRunning == false` 時，才在 resume path 呼叫 `startRunning()`。

若上層 video processor 已經完成處理但 `mediaMixer.isRunning == false`，應節流記錄診斷 log，
避免 video 被安靜丟棄：

```swift
guard await mediaMixer.isRunning else {
    sendlog("MediaMixer not running, dropping processed video")
    return
}
```

## 診斷 Log

建議觀察以下 log：

- `restartVideoEncoding throttled`
- `skip restartVideoPipeline: already restarting`
- `Restarting video pipeline`
- `restartVideoPipeline: done`
- `publish throughput ... videoInputFrames=... videoFrames=...`
- `video source idle`
- `video stall detected`
- 上層 `MediaMixer 未運行，丟棄 processed video`

若回放檔 audio 長於 video，且 RTMP throughput/心跳仍存在，優先檢查 ReplayKit video source、
video processor、`MediaMixer.isRunning` guard，以及 resume path 是否真的呼叫了
`restartVideoEncoding(reason:)`。
