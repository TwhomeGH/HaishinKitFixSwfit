# 非 Apple 平台的驗證 harness

這裡的 `verify-*.swift` **不是** SwiftPM 的 test target，也不會被 `swift test`
發現或執行。每個檔案都是獨立的 `@main` 可執行檔：用 `swiftc` 把「真實的
Foundation-only 原始碼 ＋ 斷言」編成一支程式，靠 exit code 判定成敗。

存在的原因是 `HaishinKitTests` 依賴 AVFoundation／CoreMedia，在 Windows／Linux
上連 target 都建不起來；這些 harness 讓同一組純邏輯也能在非 Apple 平台驗證。

它們是 `HaishinKit/Tests` 裡 Swift Testing 測試的**孿生體**：

- 每個 harness 都必須有對應的 Swift Testing 測試。
- 修改純邏輯時，兩邊都要更新。
- 只有 `verify-align.swift` 是例外：它是 `AudioRingBuffer.align(to:)` 的純整數
  鏡射（真實檔案需要 AVFoundation），必須手動保持同步。

## 執行

本機與 CI 共用同一個入口：

```bash
python3 .github/scripts/run_verify_harnesses.py
python3 .github/scripts/run_verify_harnesses.py --list
python3 .github/scripts/run_verify_harnesses.py --only keepalive --verbose
```

CI 的 `verify-foundation` job（Ubuntu ＋ `swift:6.0` 容器）會執行同一個指令。
新增 harness 時，必須把它加進 `run_verify_harnesses.py` 的 `HARNESSES`；未被列出
的 `verify-*.swift` 會讓 runner 直接失敗，避免孤兒腳本默默停止被執行。

## 清單

| harness | 真實原始碼 |
| --- | --- |
| `verify-mixer-clock` | `HaishinKit/Sources/Mixer/MixClockAdvance.swift` |
| `verify-audio-timeline-policy` | `HaishinKit/Sources/Mixer/AudioTimelinePolicy.swift` |
| `verify-source-time-interval` | `HaishinKit/Sources/Util/SourceTimeAudit.swift` |
| `verify-video-frame-filter` | `HaishinKit/Sources/Util/VideoFrameFilterState.swift` |
| `verify-handshake` | `RTMPHaishinKit/Sources/RTMP/RTMPHandshake.swift` |
| `verify-keepalive` | `RTMPHaishinKit/Sources/RTMP/RTMPKeepAlive.swift` |
| `verify-cts` | `RTMPHaishinKit/Sources/RTMP/RTMPVideoCompositionTime.swift` |
| `verify-aec` | `HaishinKit/Sources/Mixer/AudioEchoCanceler.swift` |
| `verify-align` | 純整數鏡射 `AudioRingBuffer.align(to:)` |
