# 音訊管線診斷（AudioPipelineDiagnostics）

提供 host 端（如 ReplyKit AHealth）取樣音訊混音管線的內部計數，用來定位
**「幀數正常、但內容被丟掉」的 content-level 斷音**。一般的 input/output FPS
看不出這種問題，因為被丟的是 1024-sample 封包內部的樣本。

## 公開 API

```swift
public struct AudioPipelineDiagnostics: Sendable {
    public struct Track: Sendable {
        public let trackId: UInt8
        public let outputFrames: Int
        public let resampleNoDataCount: Int
        public let alignDroppedSamples: Int
        public let alignInsertedSamples: Int
        public let overflowDroppedSamples: Int
        public let skipInsertedSamples: Int
        public let ringBufferCounts: Int
        public let alignFireCount: Int
        public let lastAlignDiff: Int
    }
    public let tracks: [Track]
    public let mixerOutputFrames: Int
    public let outputChannels: Int
    public let outputChannelRMS: [Float]
    public let advanceSkippedBlocks: Int
    public let advanceSkippedFrames: Int
    public let clockSwitchCount: Int
    public static let empty: AudioPipelineDiagnostics
}

extension MediaMixer {
    /// `MediaMixer` 是 actor，呼叫端需 `await`。
    public func audioPipelineDiagnostics() -> AudioPipelineDiagnostics
}
```

呼叫：

```swift
let diag = await mediaMixer.audioPipelineDiagnostics()
```

## 計數語意

除 `ringBufferCounts` 是瞬時值外，其餘皆為**累計值**，呼叫端自行取樣後算 delta
（samples/s 或次/s）。

| 欄位 | 意義 |
| ------ | ------ |
| `outputFrames` | 該軌經 resample 後送到混音器的幀數 |
| `resampleNoDataCount` | `resample()` 某次 append **完全沒產出**（ring buffer 來不及提供完整輸入塊，underrun） |
| `alignDroppedSamples` | 跨軌 `align()` 丟棄的樣本（非 main track 超前播放頭，判定為過期） |
| `alignInsertedSamples` | `align()` 補的靜音樣本（非 main track 落後播放頭） |
| `overflowDroppedSamples` | ring buffer 溢位丟棄的樣本（producer 超出 consumer） |
| `skipInsertedSamples` | PTS gap 補的 0 樣本 |
| `gapZeroFillCount` | 前向缺口 ≤ 0.25s、補零的次數 |
| `gapRebaseCount` | 前向缺口 > 0.25s、重建時間軸的次數 |
| `gapJitterCount` | 來源 PTS 倒退在 1s 內、視為抖動而保留時間軸的緩衝數 |
| `gapFullResetCount` | 來源 PTS 倒退 > 1s、清空緩衝並重建的次數 |
| `advanceSkippedBlocks` | `advanceMix` 因播放頭已在前方而略過的區塊數（先前靜默丟棄） |
| `advanceSkippedFrames` | 上述略過區塊的樣本數 |
| `clockSwitchCount` | 混音時鐘擁有權切換次數（main 停止／恢復） |
| `ringBufferCounts` | 目前 ring buffer 內樣本數（**瞬時值**） |
| `alignFireCount` | `align()` **實際動手**的次數（丟或補）。用來分辨「一次性 anchor 校正」與「每幀持續校正」 |
| `lastAlignDiff` | 最近一次 `align()` 看到的偏差 `position - current`（input 樣本；正 = 本軌落後） |
| `mixerOutputFrames` | 混音器成功產出的輸出區塊數 |
| `outputChannels` | 混音輸出聲道數（1 = mono、2 = stereo） |
| `outputChannelRMS` | 最近一次混音輸出的 per-channel RMS（index = 聲道，瞬時值） |

## 判讀

| 觀察 | 意義 |
| ------ | ------ |
| `alignFireCount` 幾乎每秒都增加（delta ≥ 1/s） | `align()` 每幀都在對非 main track 硬丟/硬補 → content-level 斷音典型訊號 |
| `lastAlignDiff` 持續在死區外 | 兩軌時間軸持續錯開，不是一次性 anchor 差 |
| `alignDroppedSamples` 持續增加 | 真實音訊被丟 |
| `alignInsertedSamples` 持續增加 | 持續插入靜音（聽覺缺口） |
| `resampleNoDataCount` 增加 | ring buffer underrun |
| `overflowDroppedSamples` 增加 | producer 超出 buffer 容量，樣本被丟 |
| `outputChannelRMS` 某聲道 ≈ 0 但來源該聲道有聲 | 該聲道在聲道映射 / 下混時被丟掉（例：stereo→mono 只取左聲道） |
| `gapJitterCount` 持續增加但 `gapFullResetCount` 不變 | 來源時鐘持續小幅倒退；時間軸被保留，但內容可能重複 |
| `advanceSkippedBlocks` 增加 | 播放頭領先來源；代表 anchor／消費軸曾錯位（修正後應接近 0） |
| `clockSwitchCount` 增加 | main 軌停止／恢復導致混音時鐘換手，輸出時間原點改變 |

## 設計

- `AudioMixerByMultiTrack` 在 mixer 專用 serial queue 上重建快照
  （`refreshDiagnosticsCache()`，於每個 append 與 `mix()` 後），存進 `NSLock`
  保護的 `diagnosticsCache`。
- `audioPipelineDiagnostics()` 只上鎖讀快取，**不 `queue.sync`**，因此不會阻塞
  `MediaMixer` actor。
- `align()` 死區（`alignDeadband = 256` samples ≈ 5.8ms @44.1k）內的偏差不會讓
  `alignFireCount` 增加，但仍會更新 `lastAlignDiff`（可觀察目前偏差量）。

## 時間軸不連續策略

`AudioTimelinePolicy`（`HaishinKit/Sources/Mixer/AudioTimelinePolicy.swift`）是三層共用的唯一門檻：

| 分類 | 條件 | 動作 |
| ------ | ------ | ------ |
| `zeroFillForward` | 0 < Δ ≤ 0.25s | ring buffer 補零，anchor 保留 |
| `rebaseForward` | Δ > 0.25s | 重建 ring buffer 與 anchor |
| `jitterBackward` | −1.0s ≤ Δ < 0 | 視為抖動，保留時間軸（不部分重設） |
| `resyncBackward` | Δ < −1.0s | 全面重設 anchor、ring buffer 與 mix clock |

門檻以秒表示，換算樣本時使用實際取樣率（先前寫死 48,000 samples：44.1k 實際是 1.09s、16k 是 3s）。
非 Apple 平台的驗證：`.cortexkit/verify-audio-timeline-policy.swift`。

## 相關

- `HaishinKit/Sources/Docs.docc/AUDIO_MULTITRACK_ALIGNMENT.md`（跨軌對齊、死區、AEC）
- `HaishinKit/Sources/Docs.docc/MEDIA_MIXER.md`（DocC）
- ReplyKit `Docs/av-pipeline.md`（AHealth telemetry）
