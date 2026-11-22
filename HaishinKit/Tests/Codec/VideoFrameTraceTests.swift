import CoreMedia
import Foundation
import Testing
@testable import HaishinKit

@Suite("同幀交付追蹤")
struct VideoFrameTraceTests {
    @Test("上游交付與底層接收保留各自 PTS，不以最新樣本替代")
    func preservesHandoff() throws {
        let buffer = try #require(CMVideoSampleBufferFactory.makeSampleBuffer(width: 16, height: 16))
        #expect(VideoFrameTrace.read(from: buffer) == nil)
        let trace = VideoFrameTrace(session: "source", sequence: 42, sourcePTS: 10, handedPTS: 11)
        trace.attachReceived(to: buffer)
        let received = try #require(VideoFrameTrace.read(from: buffer))
        #expect(received.sequence == 42)
        #expect(received.sourcePTS == 10)
        #expect(received.handedPTS == 11)
        #expect(received.receivedPTS == buffer.presentationTimeStamp.seconds)
        let tracker = VideoPipelineEventTracker()
        let state = VideoEncoderOutputState(diagnostics: tracker)
        state.recordTiming(inputPTS: 12, outputPTS: 13, outputDTS: nil,
                           submitted: 1, completed: 2, trace: received)
        let result = try #require(tracker.snapshot().lastEncoderTiming)
        #expect(result.trace?.sequence == 42)
        #expect(result.inputPTSSeconds == 12)
        #expect(result.outputPTSSeconds == 13)
        state.invalidate()
        state.recordTiming(inputPTS: 14, outputPTS: 15, outputDTS: nil,
                           submitted: 2, completed: 3, trace: received)
        #expect(tracker.snapshot().lastEncoderTiming == nil)
        VideoFrameTrace.clear(from: buffer)
        #expect(VideoFrameTrace.read(from: buffer) == nil)
    }

    @Test("舊編碼摘要缺少 trace 時保持未知")
    func legacyDecoding() throws {
        let sample = VideoEncoderTimingSample(session: UUID(), inputPTS: 0, outputPTS: 0,
                                              outputDTS: nil, submitted: 1, completed: 2)
        let decoded = try JSONDecoder().decode(VideoEncoderTimingSample.self, from: JSONEncoder().encode(sample))
        #expect(decoded.trace == nil)
    }
}
