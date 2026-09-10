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
|------|------|
| `outputFrames` | 該軌經 resample 後送到混音器的幀數 |
| `resampleNoDataCount` | `resample()` 某次 append **完全沒產出**（ring buffer 來不及提供完整輸入塊，underrun） |
| `alignDroppedSamples` | 跨軌 `align()` 丟棄的樣本（非 main track 超前播放頭，判定為過期） |
| `alignInsertedSamples` | `align()` 補的靜音樣本（非 main track 落後播放頭） |
| `overflowDroppedSamples` | ring buffer 溢位丟棄的樣本（producer 超出 consumer） |
| `skipInsertedSamples` | PTS gap 補的 0 樣本 |
| `ringBufferCounts` | 目前 ring buffer 內樣本數（**瞬時值**） |
| `alignFireCount` | `align()` **實際動手**的次數（丟或補）。用來分辨「一次性 anchor 校正」與「每幀持續校正」 |
| `lastAlignDiff` | 最近一次 `align()` 看到的偏差 `position - current`（input 樣本；正 = 本軌落後） |
| `mixerOutputFrames` | 混音器成功產出的輸出區塊數 |

## 判讀

| 觀察 | 意義 |
|------|------|
| `alignFireCount` 幾乎每秒都增加（delta ≥ 1/s） | `align()` 每幀都在對非 main track 硬丟/硬補 → content-level 斷音典型訊號 |
| `lastAlignDiff` 持續在死區外 | 兩軌時間軸持續錯開，不是一次性 anchor 差 |
| `alignDroppedSamples` 持續增加 | 真實音訊被丟 |
| `alignInsertedSamples` 持續增加 | 持續插入靜音（聽覺缺口） |
| `resampleNoDataCount` 增加 | ring buffer underrun |
| `overflowDroppedSamples` 增加 | producer 超出 buffer 容量，樣本被丟 |

## 設計

- `AudioMixerByMultiTrack` 在 mixer 專用 serial queue 上重建快照
  （`refreshDiagnosticsCache()`，於每個 append 與 `mix()` 後），存進 `NSLock`
  保護的 `diagnosticsCache`。
- `audioPipelineDiagnostics()` 只上鎖讀快取，**不 `queue.sync`**，因此不會阻塞
  `MediaMixer` actor。
- `align()` 死區（`alignDeadband = 256` samples ≈ 5.8ms @44.1k）內的偏差不會讓
  `alignFireCount` 增加，但仍會更新 `lastAlignDiff`（可觀察目前偏差量）。

## 相關

- `Docs/AUDIO_MULTITRACK_ALIGNMENT.md`（跨軌對齊、死區、AEC）
- `Docs/MEDIA_MIXER.md`
- ReplyKit `Docs/av-pipeline.md`（AHealth telemetry）
