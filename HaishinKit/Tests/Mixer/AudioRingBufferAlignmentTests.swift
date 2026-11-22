import Testing

@testable import HaishinKit

/// `AudioRingBufferAlignment.decide` 的純決策驗證：死區、丟棄上限、
/// pending silence 先消耗，以及補靜音。實際 buffer mutation 由 Apple CI 覆蓋。
///
/// 對應非 Apple 平台的獨立驗證腳本 `.cortexkit/verify-align.swift`。
@Suite("AudioRingBufferAlignment：跨軌對齊決策")
struct AudioRingBufferAlignmentTests {
    @Test("死區內不調整")
    func deadband() {
        #expect(AudioRingBufferAlignment.decide(
            behind: 0, available: 1024, pendingSilence: 0, deadband: 256) == .none)
        #expect(AudioRingBufferAlignment.decide(
            behind: 256, available: 1024, pendingSilence: 0, deadband: 256) == .none)
        #expect(AudioRingBufferAlignment.decide(
            behind: -256, available: 1024, pendingSilence: 0, deadband: 256) == .none)
    }

    @Test("播放頭在前方 → 丟棄，上限為可用樣本")
    func dropCappedByAvailable() {
        #expect(AudioRingBufferAlignment.decide(
            behind: 4096, available: 2048, pendingSilence: 0, deadband: 256)
            == .drop(total: 2048, fromSkip: 0, fromStored: 2048))
    }

    @Test("先消耗 pending silence，再丟實際樣本")
    func dropConsumesSilenceFirst() {
        #expect(AudioRingBufferAlignment.decide(
            behind: 800, available: 1000, pendingSilence: 600, deadband: 256)
            == .drop(total: 800, fromSkip: 600, fromStored: 200))
    }

    @Test("播放頭在後方 → 補靜音")
    func insertSilence() {
        #expect(AudioRingBufferAlignment.decide(
            behind: -512, available: 1000, pendingSilence: 0, deadband: 256)
            == .insertSilence(samples: 512))
    }

    @Test("無可用樣本仍回報丟棄決策，由呼叫端計數")
    func noAvailableSamples() {
        #expect(AudioRingBufferAlignment.decide(
            behind: 100, available: 0, pendingSilence: 0, deadband: 256)
            == .drop(total: 0, fromSkip: 0, fromStored: 0))
    }
}
