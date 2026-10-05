import Foundation
import Testing

@testable import HaishinKit

/// `MixClockAdvance` 的決策驗證：main 驅動時鐘、main 靜默/從未輸出時由其他軌
/// 接手推進，以及「只有 main 明確落後才推進」的防重複混音守則。
///
/// 對應非 Apple 平台的獨立驗證腳本 `.cortexkit/verify-mixer-clock.swift`。
@Suite("MixClockAdvance：混音時鐘推進決策")
struct MixClockAdvanceTests {
    @Test("main 軌本身永遠推進時鐘")
    func mainTrackAlwaysAdvances() {
        #expect(MixClockAdvance.shouldAdvance(
            track: 0, mainTrack: 0, mainLastOutputPosition: nil, position: 0))
        #expect(MixClockAdvance.shouldAdvance(
            track: 0, mainTrack: 0, mainLastOutputPosition: 9999, position: 0))
    }

    @Test("main 從未輸出 → 其他軌接手推進（不 stall）")
    func advancesWhenMainNeverProduced() {
        #expect(MixClockAdvance.shouldAdvance(
            track: 1, mainTrack: 0, mainLastOutputPosition: nil, position: 1024))
    }

    @Test("main 落後 → 其他軌推進（app 靜默、mic 接手）")
    func advancesWhenMainLags() {
        #expect(MixClockAdvance.shouldAdvance(
            track: 1, mainTrack: 0, mainLastOutputPosition: 1024, position: 2048))
    }

    @Test("main 同位置或領先 → 不推進（避免重複混音 / mic 被 align 丟棄）")
    func doesNotAdvanceWhenMainCurrentOrAhead() {
        #expect(!MixClockAdvance.shouldAdvance(
            track: 1, mainTrack: 0, mainLastOutputPosition: 1024, position: 1024))
        #expect(!MixClockAdvance.shouldAdvance(
            track: 1, mainTrack: 0, mainLastOutputPosition: 2048, position: 1024))
    }
}
