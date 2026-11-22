import Foundation
import Testing

@testable import HaishinKit

/// `AudioTimelinePolicy` 的門檻分類與換算：三層（anchor、ring buffer、
/// mix clock）必須得到一致結果，且門檻以秒表示、隨實際取樣率換算。
///
/// 對應非 Apple 平台的獨立驗證腳本 `.cortexkit/verify-audio-timeline-policy.swift`。
@Suite("AudioTimelinePolicy：音訊時間軸不連續門檻")
struct AudioTimelinePolicyTests {
    @Test("前向缺口在補零範圍內")
    func forwardWithinZeroFill() {
        #expect(AudioTimelinePolicy.classify(0) == .continuous)
        #expect(AudioTimelinePolicy.classify(0.1) == .zeroFillForward)
        #expect(AudioTimelinePolicy.classify(0.25) == .zeroFillForward)
    }

    @Test("前向缺口超過補零範圍 → 重建")
    func forwardBeyondZeroFill() {
        #expect(AudioTimelinePolicy.classify(0.251) == .rebaseForward)
        #expect(AudioTimelinePolicy.classify(3) == .rebaseForward)
    }

    @Test("小幅倒退視為抖動，保留時間軸")
    func backwardWithinResync() {
        #expect(AudioTimelinePolicy.classify(-0.001) == .jitterBackward)
        #expect(AudioTimelinePolicy.classify(-0.8) == .jitterBackward)
        #expect(AudioTimelinePolicy.classify(-1.0) == .jitterBackward)
    }

    @Test("大幅倒退 → 全面重設")
    func backwardBeyondResync() {
        #expect(AudioTimelinePolicy.classify(-1.001) == .resyncBackward)
        #expect(AudioTimelinePolicy.classify(-5) == .resyncBackward)
    }

    @Test("門檻以秒換算，不隨取樣率失真")
    func samplesScaleWithSampleRate() {
        #expect(AudioTimelinePolicy.samples(forSeconds: 1, rate: 44_100) == 44_100)
        #expect(AudioTimelinePolicy.samples(forSeconds: 1, rate: 48_000) == 48_000)
        #expect(AudioTimelinePolicy.samples(forSeconds: 1, rate: 16_000) == 16_000)
        #expect(AudioTimelinePolicy.samples(forSeconds: 0.25, rate: 48_000) == 12_000)
    }

    @Test("無效參數回 0，呼叫端不可據此重設")
    func invalidInputsReturnZero() {
        #expect(AudioTimelinePolicy.samples(forSeconds: 1, rate: 0) == 0)
        #expect(AudioTimelinePolicy.samples(forSeconds: 1, rate: .nan) == 0)
        #expect(AudioTimelinePolicy.samples(forSeconds: .infinity, rate: 48_000) == 0)
        #expect(AudioTimelinePolicy.classify(.nan) == .continuous)
    }
}
