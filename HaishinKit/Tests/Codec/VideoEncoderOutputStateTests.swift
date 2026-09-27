import Foundation
import Testing
@testable import HaishinKit

/// 驗證 VideoEncoderOutputState 的核心不變式：
/// 「請求 keyframe ≠ keyframe 成功；失敗 / 丟幀要退回等 keyframe；
///   舊 session 的 callback 不得污染新 session」。
@Suite struct VideoEncoderOutputStateTests {
    /// 要求 keyframe 後，要等到「被接受的 keyframe」才解除等待；
    /// 期間非 keyframe 一律不交付。
    @Test func requestIsNotConfirmation() {
        let state = VideoEncoderOutputState()
        #expect(state.shouldForceKeyFrame(at: 1, interval: 2))
        #expect(state.shouldForceKeyFrame(at: 1.1, interval: 2))
        var delivered = 0
        state.deliver(isKeyFrame: false, seconds: 1.1) { delivered += 1; return true }
        #expect(delivered == 0)
        state.deliver(isKeyFrame: true, seconds: 1.2) { delivered += 1; return true }
        #expect(delivered == 1)
        #expect(!state.shouldForceKeyFrame(at: 2, interval: 2))
        #expect(state.shouldForceKeyFrame(at: 3.2, interval: 2))
    }

    /// yield 失敗（佇列滿）或之後 dropped() 都必須重新等 keyframe，
    /// 且等待期間 P 幀不得被放行。
    @Test func droppedKeyframeMustBeRetried() {
        let state = VideoEncoderOutputState()
        state.deliver(isKeyFrame: true, seconds: 1) { false }
        #expect(state.shouldForceKeyFrame(at: 1.01, interval: 2))
        state.deliver(isKeyFrame: true, seconds: 1.02) { true }
        state.dropped()
        var admitted = false
        state.deliver(isKeyFrame: false, seconds: 1.03) { admitted = true; return true }
        #expect(!admitted)
        #expect(state.shouldForceKeyFrame(at: 1.04, interval: 2))
    }

    /// 非同步 encode 失敗後，連 keyframe 都不放行；失敗碼在 owner 換 session
    /// 前持續存在（takeFailure 不清除）。
    @Test func asynchronousFailureBlocksEvenAKeyframe() {
        let state = VideoEncoderOutputState()
        #expect(state.recordFailure(-12911))
        #expect(!state.recordFailure(-12911))
        #expect(state.takeFailure() == -12911)
        var admitted = false
        state.deliver(isKeyFrame: true, seconds: 2) { admitted = true; return true }
        #expect(!admitted)
        #expect(state.takeFailure() == -12911)
    }

    /// 已 invalidate 的舊 state：deliver / recordFailure 全部無效，
    /// 新 state 從頭要求 keyframe。
    @Test func lateOldSessionCallbacksCannotConfirmNewSession() {
        let old = VideoEncoderOutputState()
        old.invalidate()
        let current = VideoEncoderOutputState()
        var delivered = 0
        old.deliver(isKeyFrame: true, seconds: 10) { delivered += 1; return true }
        #expect(!old.recordFailure(-1))
        #expect(delivered == 0)
        #expect(old.takeFailure() == nil)
        #expect(current.shouldForceKeyFrame(at: 10, interval: 2))
        current.deliver(isKeyFrame: true, seconds: 11) { delivered += 1; return true }
        #expect(delivered == 1)
    }

    /// interval == 0（停用週期 keyframe）時，開場仍必須先要一顆 keyframe；
    /// 成功後才不再週期性要求。
    @Test func startupStillRequiresSyncWhenPeriodicKeyframesDisabled() {
        let state = VideoEncoderOutputState()
        #expect(state.shouldForceKeyFrame(at: 1, interval: 0))
        state.deliver(isKeyFrame: true, seconds: 1) { true }
        #expect(!state.shouldForceKeyFrame(at: 100, interval: 0))
    }

    /// 100 個並行 callback 中夾一次 invalidate（模擬 VT callback 與 session
    /// 替換競態）：不得 crash，且 invalidate 後所有交付都被擋下。
    @Test func invalidationIsSafeAgainstConcurrentCallbacks() async {
        let state = VideoEncoderOutputState()
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    state.deliver(isKeyFrame: true, seconds: Double(i)) { true }
                    if i == 50 { state.invalidate() }
                }
            }
        }
        var admitted = false
        state.deliver(isKeyFrame: true, seconds: 200) { admitted = true; return true }
        #expect(!admitted)
    }
}
