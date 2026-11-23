// Verification of VideoEncoderPressureSnapshot
// (HaishinKit/Sources/Util/VideoEncoderPressureSnapshot.swift) on non-Apple
// platforms. Compiled together with the REAL Foundation-only source:
//
//   swiftc HaishinKit/Sources/Util/VideoEncoderPressureSnapshot.swift \
//          .cortexkit/verify-encoder-pressure.swift -o .cortexkit/verify-encoder-pressure.exe
import Foundation

var failures = 0
func expect(_ cond: Bool, _ name: String) {
    if cond {
        print("  ok   \(name)")
    } else {
        failures += 1
        print("  FAIL \(name)")
    }
}

@main
struct VerifyEncoderPressure {
    static func main() {
        // 1) 送交、回呼、交付一致且沒有積壓 → normal。
        var normal = VideoEncoderPressureSnapshot.Input()
        normal.hasData = true
        normal.expectedFrameRate = 60
        normal.submitted = 100
        normal.callbacks = 100
        normal.delivered = 100
        normal.pendingFrames = 0
        normal.queued = 0
        normal.lastElapsedMilliseconds = 10
        let a = VideoEncoderPressureSnapshot(input: normal)
        expect(a.state == .normal, "normal state")
        expect(a.highWatermark == 5, "60fps high watermark 5")
        expect(a.isBehind == false, "normal not behind")
        expect(a.outstandingSubmissions == 0, "no outstanding submissions")

        // 2) VT pending 超過高水位 → vtBacklog。
        var vt = VideoEncoderPressureSnapshot.Input()
        vt.hasData = true
        vt.expectedFrameRate = 60
        vt.pendingFrames = 6
        expect(VideoEncoderPressureSnapshot(input: vt).state == .vtBacklog, "vt backlog at 6")

        // 3) 使用者設定的 maxFrameDelayCount 優先。
        var delayed = VideoEncoderPressureSnapshot.Input()
        delayed.hasData = true
        delayed.expectedFrameRate = 60
        delayed.maxFrameDelayCount = 10
        delayed.pendingFrames = 8
        let b = VideoEncoderPressureSnapshot(input: delayed)
        expect(b.highWatermark == 10, "configured high watermark 10")
        expect(b.state == .normal, "pending 8 below configured 10")

        // 4) 編碼前佇列堆積或最舊影格過久 → queueBacklog。
        var queue = VideoEncoderPressureSnapshot.Input()
        queue.hasData = true
        queue.expectedFrameRate = 60
        queue.queued = 2
        expect(VideoEncoderPressureSnapshot(input: queue).state == .queueBacklog, "queue depth 2")
        var old = VideoEncoderPressureSnapshot.Input()
        old.hasData = true
        old.expectedFrameRate = 60
        old.oldestAgeSeconds = 0.2
        expect(VideoEncoderPressureSnapshot(input: old).state == .queueBacklog, "oldest 200ms")

        // 5) 單張短暫停留不算積壓。
        var single = VideoEncoderPressureSnapshot.Input()
        single.hasData = true
        single.expectedFrameRate = 60
        single.queued = 1
        single.oldestAgeSeconds = 0.05
        expect(VideoEncoderPressureSnapshot(input: single).state == .normal, "single short frame normal")

        // 6) 回呼耗時相對幀率判定。
        var slow = VideoEncoderPressureSnapshot.Input()
        slow.hasData = true
        slow.expectedFrameRate = 60
        slow.lastElapsedMilliseconds = 60
        expect(VideoEncoderPressureSnapshot(input: slow).state == .callbackSlow, "60ms callback slow at 60fps")
        slow.lastElapsedMilliseconds = 40
        expect(VideoEncoderPressureSnapshot(input: slow).state == .normal, "40ms callback normal at 60fps")

        // 7) 丟幀／失敗／下游拒收／PTS 重置。
        var dropping = VideoEncoderPressureSnapshot.Input()
        dropping.hasData = true
        dropping.expectedFrameRate = 60
        dropping.recentFailure = true
        expect(VideoEncoderPressureSnapshot(input: dropping).state == .dropping, "recent failure drops")

        // 8) adaptive throttle 代表 VT 先前已落後。
        var throttle = VideoEncoderPressureSnapshot.Input()
        throttle.hasData = true
        throttle.expectedFrameRate = 60
        throttle.recentAdaptiveThrottle = true
        expect(VideoEncoderPressureSnapshot(input: throttle).state == .throttling, "adaptive throttle")

        // 9) 沒有資料不能假裝零壓力。
        var empty = VideoEncoderPressureSnapshot.Input()
        empty.expectedFrameRate = 60
        let c = VideoEncoderPressureSnapshot(input: empty)
        expect(c.state == .unavailable, "no data unavailable")
        expect(c.shouldPauseRepeats == false, "unavailable does not pause")

        // 10) 累計差值與負值夾取。
        var counters = VideoEncoderPressureSnapshot.Input()
        counters.hasData = true
        counters.submitted = 10
        counters.callbacks = 7
        counters.delivered = 5
        let d = VideoEncoderPressureSnapshot(input: counters)
        expect(d.outstandingSubmissions == 3, "outstanding 3")
        expect(d.undeliveredCallbacks == 2, "undelivered 2")
        var regressed = VideoEncoderPressureSnapshot.Input()
        regressed.hasData = true
        regressed.submitted = 1
        regressed.callbacks = 3
        regressed.delivered = 5
        let e = VideoEncoderPressureSnapshot(input: regressed)
        expect(e.outstandingSubmissions == 0, "outstanding clamped")
        expect(e.undeliveredCallbacks == 0, "undelivered clamped")

        // 11) 摘要欄位。
        let text = a.summary
        expect(text.contains("state=normal"), "summary state")
        expect(text.contains("submitted=100"), "summary submitted")
        expect(text.contains("high=5"), "summary high watermark")

        print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
        exit(failures == 0 ? 0 : 1)
    }
}
