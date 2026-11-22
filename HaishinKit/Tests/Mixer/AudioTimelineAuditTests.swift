import Testing
@testable import HaishinKit

@Suite("音軌來源時間與樣本稽核")
struct AudioTimelineAuditTests {
    @Test("來源缺口與樣本輸出分開計算")
    func gapIsNotInventedContent() throws {
        var audit = AudioTimelineAudit()
        audit.input(pts: 0, frames: 480, rate: 48000)
        audit.output(frames: 480, rate: 48000)
        audit.input(pts: 0.11, frames: 480, rate: 48000)
        #expect(abs(try #require(audit.sourceMinusInput) - 0.1) < 0.000001)
        #expect(audit.inputSeconds == 0.02)
        #expect(audit.outputSeconds == 0.01)
    }

    @Test("重建不跨世代累積且保留前段摘要")
    func resetPreservesEvidence() {
        var audit = AudioTimelineAudit()
        audit.input(pts: 100, frames: 480, rate: 48000)
        #expect(audit.report(now: 0) == nil)
        audit.reset(reason: "sourceRegression")
        #expect(audit.sourceMinusInput == nil)
        #expect(audit.outputSeconds == 0)
        #expect(audit.report(now: 1) == nil)
        #expect(audit.report(now: 30)?.contains("previous{generation=0") == true)
    }

    @Test("無效來源不冒充零時間且取樣率改變以秒比較")
    func invalidAndDifferentRates() throws {
        var audit = AudioTimelineAudit()
        audit.input(pts: .nan, frames: 1024, rate: 48000)
        #expect(audit.firstPTS == nil)
        audit.input(pts: 0, frames: 441, rate: 44100)
        audit.output(frames: 480, rate: 48000)
        #expect(abs(audit.inputSeconds - audit.outputSeconds) < 0.000001)
        #expect(abs(try #require(audit.sourceMinusInput)) < 0.000001)
    }
}
