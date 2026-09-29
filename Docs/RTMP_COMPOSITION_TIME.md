# RTMP Video Composition Time 與 A/V 偏移補償

## 背景

RTMP / FLV 的 video tag 除了 DTS（tag timestamp）外，還有一個 24-bit 帶號的
**Composition Time Offset（CTS）**，定義 `PTS = DTS + CTS`。CTS 是「解碼順序」到
「顯示順序」的延遲：

- 有 B-frame 時 CTS 可正可負（重排），所以欄位才做成帶號。
- **沒有 B-frame 時 CTS 必須是 0**（`has_b_frames == 0`，video 全為 IPPP）。

本框架輸出 H.264 時 `has_b_frames == 0`，因此 CTS 必須為 0；任何負值都是缺陷。

## 症狀

特定播放器設定下表現為「連線正常、中繼資料解得出來，但**完全沒有畫面**」：

- mpegts.js（`isLive + liveBufferLatencyChasing + enableStashBuffer:false`）會把
  `pts < dts` 的視訊樣本全部丟棄 → MSE 完全沒有 buffer、`readyState` 卡在
  `HAVE_METADATA`（1），連線仍活著。
- ffmpeg / VLC 可容忍，但會在 log 持續噴
  `Invalid timestamps stream=1, pts=..., dts=...`。

## 根因

`RTMPStream.append(_:)`（`RTMPHaishinKit/Sources/RTMP/RTMPStream.swift`）的
A/V 偏移自動補償只把補償量加進 **DTS 時間軸**，但 composition time 的
「無 decodeTimeStamp」分支卻拿**未補償**的 PTS 去減**已補償**的線上位址：

```swift
// frameTime 才是實際寫入 DTS 的值（含 avOffsetCompensation）
var frameTime = decodeTimeStamp                       // = PTS（無 B-frame）
if avOffsetCompensation != 0 { frameTime += comp }
let timedelta = videoTimestamp.update(frameTime, ...)  // updatedAt = frameTime

// 錯誤：CTS = PTS − (PTS + comp) = −comp
compositionTime = Int32((sampleBuffer.presentationTimeStamp.seconds - videoTimestamp.updatedAt) * 1000)
```

量到的 `avOffsetCompensation = +135ms` → 每個 video frame 的 CTS 都是 **−135ms**。

而且補償在此公式下**自我抵銷**：`wire PTS = wire DTS + CTS = (PTS+comp) + (−comp) = PTS`，
呈現時間根本沒被補到，只把 decode 時間軸往前推，還破壞了 CTS。

## 修正

把 CTS 收斂成一個純函式 `RTMPVideoCompositionTime.offset(...)`（保證 ≥ 0），
`RTMPStream.append` 與 `CMSampleBuffer.getCompositionTime` 都改用它（後者不再自己算）：

```swift
static func offset(hasValidDecodeTimeStamp: Bool,
                   presentationTime: TimeInterval,
                   decodeTime: TimeInterval,
                   ctsOffset: TimeInterval) -> Int32 {
    guard hasValidDecodeTimeStamp else { return 0 }   // 無重排 → PTS == DTS
    return max(0, Int32(((presentationTime - decodeTime) + ctsOffset) * 1000))
}
```

- 無 B-frame（`decodeTimeStamp` 無效）→ 0，符合規範，且與補償無關。
- 有 B-frame → 相對 `PTS−DTS`，clamp ≥ 0。
- A/V 補償只作用在 wire 的 DTS/PTS，不再混入 CTS；修正後補償才真正生效：
  `wire PTS = (sourcePTS + comp) + 0`，呈現時間前移。

## 驗證

- 單元測試 `RTMPHaishinKit/Tests/RTMP/RTMPVideoCompositionTimeTests.swift`
  （Swift Testing）：無重排恆為 0（含來源 PTS/DTS 分歧）、有重排 `PTS−DTS+offset`、
  負值 clamp 0、`resultIsNeverNegative` 掃描網格恆非負。
- `.cortexkit/verify-cts.swift` 搭配**真實原始碼**編譯執行：重現舊公式的 `−comp`，
  並驗證新函式恆為 `0` 且 `wire PTS = sourcePTS + comp`（補償真正生效）。全數 PASS。
- 實測（同一段 wire bytes，只改 CTS 三個位元組，同一播放設定）：

  | CTS | buffered | currentTime | readyState |
  | ----- | ---------- | ------------- | ------------ |
  | −135ms（修正前） | `null` | 0 | 1（無畫面） |
  | 0（修正後） | 2.118s | 1.79s | 2（可播） |

## 相關

- `RTMPHaishinKit/Sources/RTMP/RTMPTimestamp.swift`：wire 時間軸的 delta 累積與 clamp。
- `Docs/NETWORK_LAYER.md`：publish throughput 的 `avOffset` 監測。
