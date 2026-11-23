import Foundation
import Testing
@testable import HaishinKit

/// 編碼壓力快照的純狀態測試；不建立 VT session，也不依賴 AVFoundation。
struct VideoEncoderPressureSnapshotTests {
    /// 建立 60fps 目標的預設輸入，再由個別案例覆寫。
    private func snapshot(
        _ configure: (inout VideoEncoderPressureSnapshot.Input) -> Void = { _ in }
    ) -> VideoEncoderPressureSnapshot {
        var input = VideoEncoderPressureSnapshot.Input()
        input.hasData = true
        input.expectedFrameRate = 60
        configure(&input)
        return VideoEncoderPressureSnapshot(input: input)
    }

    @Test func normalWhenCountsMatchAndNoBacklog() {
        var input = VideoEncoderPressureSnapshot.Input()
        input.hasData = true
        input.expectedFrameRate = 60
        input.submitted = 100
        input.callbacks = 100
        input.delivered = 100
        input.pendingFrames = 0
        input.queued = 0
        input.lastElapsedMilliseconds = 10
        let value = VideoEncoderPressureSnapshot(input: input)
        #expect(value.state == .normal)
        #expect(value.highWatermark == 5)
        #expect(value.isBehind == false)
        #expect(value.shouldPauseRepeats == false)
        #expect(value.outstandingSubmissions == 0)
        #expect(value.undeliveredCallbacks == 0)
    }

    @Test func detectsVideoToolboxBacklogAboveHighWatermark() {
        let value = snapshot { $0.pendingFrames = 6 }
        #expect(value.state == .vtBacklog)
        #expect(value.isBehind)
        #expect(value.highWatermark == 5)
    }

    @Test func detectsEncoderInputQueueBacklog() {
        #expect(snapshot { $0.queued = 2 }.state == .queueBacklog)
        #expect(snapshot { $0.oldestAgeSeconds = 0.2 }.state == .queueBacklog)
        // 單張短暫停留不算積壓。
        #expect(snapshot { $0.queued = 1; $0.oldestAgeSeconds = 0.05 }.state == .normal)
    }

    @Test func detectsSlowCallbackRelativeToFrameRate() {
        #expect(snapshot { $0.lastElapsedMilliseconds = 60 }.state == .callbackSlow)
        #expect(snapshot { $0.lastElapsedMilliseconds = 40 }.state == .normal)
    }

    @Test func detectsDroppingAndAdaptiveThrottle() {
        #expect(snapshot { $0.recentDrop = true }.state == .dropping)
        #expect(snapshot { $0.recentFailure = true }.state == .dropping)
        #expect(snapshot { $0.recentYieldRejected = true }.state == .dropping)
        #expect(snapshot { $0.recentPTSReset = true }.state == .dropping)
        #expect(snapshot { $0.recentAdaptiveThrottle = true }.state == .throttling)
    }

    @Test func unavailableWithoutEncoderData() {
        var input = VideoEncoderPressureSnapshot.Input()
        input.expectedFrameRate = 60
        let value = VideoEncoderPressureSnapshot(input: input)
        #expect(value.state == .unavailable)
        #expect(value.isBehind == false)
        #expect(value.shouldPauseRepeats == false)
    }

    @Test func respectsConfiguredMaximumFrameDelay() {
        var input = VideoEncoderPressureSnapshot.Input()
        input.hasData = true
        input.expectedFrameRate = 60
        input.maxFrameDelayCount = 10
        input.pendingFrames = 8
        let value = VideoEncoderPressureSnapshot(input: input)
        #expect(value.highWatermark == 10)
        #expect(value.state == .normal)
    }

    @Test func exposesCumulativeCountersAndClampsNegativeDifferences() {
        var input = VideoEncoderPressureSnapshot.Input()
        input.hasData = true
        input.submitted = 10
        input.callbacks = 7
        input.delivered = 5
        let value = VideoEncoderPressureSnapshot(input: input)
        #expect(value.outstandingSubmissions == 3)
        #expect(value.undeliveredCallbacks == 2)
        #expect(value.summary.contains("submitted=10"))
        #expect(value.summary.contains("outstanding=3"))

        var regressed = VideoEncoderPressureSnapshot.Input()
        regressed.hasData = true
        regressed.submitted = 1
        regressed.callbacks = 3
        regressed.delivered = 5
        let clamped = VideoEncoderPressureSnapshot(input: regressed)
        #expect(clamped.outstandingSubmissions == 0)
        #expect(clamped.undeliveredCallbacks == 0)
    }
}
