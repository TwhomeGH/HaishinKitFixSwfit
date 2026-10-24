import Foundation
import Testing
@testable import RTMPHaishinKit

struct RTMPMediaTimingDiagnosticsTests {
    @Test func rejectedFirstAttemptDoesNotBecomeFirstAccepted() throws {
        var value = RTMPMediaTimingDiagnostics()
        value.record(pts: 101, dts: 100, generatedDTS: 0, compositionSeconds: 1,
                     preferredDuration: nil, accepted: false, uptime: 200)
        value.record(pts: 102, dts: 101, generatedDTS: 1, compositionSeconds: 1,
                     preferredDuration: nil, accepted: true, uptime: 201)
        #expect(value.attempts == 2)
        #expect(value.rejected == 1)
        #expect(value.accepted == 1)
        #expect(value.firstAttempt?.sequence == 1)
        #expect(value.firstAccepted?.sequence == 2)
        #expect(value.lastAttempt?.sourcePTSSeconds == 102)
        #expect(value.lastAttempt?.generatedPTSSeconds == 2)
        #expect(value.lastAttempt?.generatedDTSSeconds == 1)
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(RTMPMediaTimingDiagnostics.self, from: data)
        #expect(decoded.firstAccepted == value.firstAccepted)
    }

    @Test func invalidMediaTimesRemainUnknown() throws {
        var value = RTMPMediaTimingDiagnostics()
        value.record(pts: .nan, dts: .infinity, generatedDTS: 0,
                     compositionSeconds: 0, preferredDuration: nil, accepted: true, uptime: 1)
        #expect(value.lastAttempt?.sourcePTSSeconds == nil)
        #expect(value.lastAttempt?.sourceDTSSeconds == nil)
        _ = try JSONEncoder().encode(value)
    }

    @Test func publishingResetAndLegacyJSONDoNotInventTiming() throws {
        var tracker = RTMPEncodingTracker()
        tracker.recordTiming(video: false, pts: 100, dts: nil,
                             generatedDTS: 0, preferredDuration: 2048.0 / 48000, accepted: true)
        #expect(tracker.snapshot(isPublishing: true).audioTiming?.firstAccepted?.preferredDurationSeconds == 2048.0 / 48000)
        tracker.reset(generation: 2)
        let reset = tracker.snapshot(isPublishing: false)
        #expect(reset.audioTiming == nil)
        #expect(reset.videoTiming == nil)
        // nil 欄位會被省略，代表舊版快照的欄位形狀。
        let data = try JSONEncoder().encode(reset)
        let decoded = try JSONDecoder().decode(RTMPEncodingDiagnostics.self, from: data)
        #expect(decoded.audioTiming == nil)
    }
}
