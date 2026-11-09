import Foundation
import Testing

@testable import HaishinKit

@Suite("VideoEncoderHealth：VT 診斷摘要")
struct VideoEncoderHealthTests {
    @Test func droppedFramesAreReportedAsVTDrop() {
        let tracker = VideoPipelineEventTracker()
        tracker.record(.encoderSubmitted)
        tracker.record(.encoderDropped)
        let health = VideoEncoderHealth(events: tracker.snapshot(), pendingFrames: 3)

        #expect(health.state == .vtDrop)
        #expect(health.submitted == 1)
        #expect(health.dropped == 1)
        #expect(health.pendingFrames == 3)
        #expect(health.summary.contains("state=vtDrop"))
    }

    @Test func rejectedOutputIsNotReportedAsVTDrop() {
        let tracker = VideoPipelineEventTracker()
        tracker.record(.encoderYieldRejected)
        let health = VideoEncoderHealth(events: tracker.snapshot(), pendingFrames: nil)

        #expect(health.state == .outputRejected)
        #expect(health.yieldRejected == 1)
        #expect(health.dropped == 0)
    }

    @Test func noRecentEventsIsHealthy() {
        let tracker = VideoPipelineEventTracker()
        let health = VideoEncoderHealth(events: tracker.snapshot(), pendingFrames: nil)

        #expect(health.state == .healthy)
        #expect(health.pendingFrames == nil)
    }
}
