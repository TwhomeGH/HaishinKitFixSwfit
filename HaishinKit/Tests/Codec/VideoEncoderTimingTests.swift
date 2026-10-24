import Foundation
import Testing
@testable import HaishinKit

struct VideoEncoderTimingTests {
    @Test func sameFrameTimingAndInvalidatedSession() throws {
        let diagnostics = VideoPipelineEventTracker()
        let old = VideoEncoderOutputState(diagnostics: diagnostics)
        old.recordTiming(inputPTS: 10, outputPTS: 12, outputDTS: 11, submitted: 100, completed: 100.5)
        let first = try #require(diagnostics.snapshot().firstEncoderTiming)
        #expect(first.inputPTSSeconds == 10)
        #expect(first.outputPTSSeconds == 12)
        #expect(first.elapsedMilliseconds == 500)
        old.invalidate()
        #expect(diagnostics.snapshot().lastEncoderTiming == nil)
        let current = VideoEncoderOutputState(diagnostics: diagnostics)
        current.recordTiming(inputPTS: 20, outputPTS: 20, outputDTS: nil, submitted: 200, completed: 201)
        old.recordTiming(inputPTS: 99, outputPTS: 99, outputDTS: nil, submitted: 300, completed: 301)
        old.invalidate()
        let last = try #require(diagnostics.snapshot().lastEncoderTiming)
        #expect(last.session != first.session)
        #expect(last.inputPTSSeconds == 20)
        #expect(last.outputDTSSeconds == nil)
        _ = try JSONEncoder().encode(diagnostics.snapshot())
    }
}
