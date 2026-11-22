import Testing
@testable import HaishinKit

@Suite("來源時間入口診斷")
struct SourceTimeAuditTests {
    @Test("首筆異常立即報告，持續異常限頻且記錄連續數")
    func invalidBurst() {
        var audit = SourceTimeAudit()
        #expect(audit.observe(pts: 10, reason: nil, detail: "", now: 0) != nil)
        #expect(audit.observe(pts: .nan, reason: "invalidCMTime", detail: "flags=0", now: 1) != nil)
        for i in 2...30 {
            #expect(audit.observe(pts: .nan, reason: "invalidCMTime", detail: "", now: Double(i)) == nil)
        }
        #expect(audit.observe(pts: .infinity, reason: "nonFinitePTS", detail: "", now: 31) != nil)
        #expect(audit.invalid == 31)
        #expect(audit.longestRun == 31)
        #expect(audit.lastValidPTS == 10)
    }

    @Test("恢復不把到達時間當 PTS，停止摘要保留恢復計數")
    func recovery() {
        var audit = SourceTimeAudit()
        _ = audit.observe(pts: .nan, reason: "invalidCMTime", detail: "", now: 100)
        #expect(audit.observe(pts: 0, reason: nil, detail: "", now: 101) == nil)
        #expect(audit.lastValidPTS == 0)
        #expect(audit.consecutive == 0)
        #expect(audit.recoveries == 1)
        #expect(audit.summary.contains("timestampFallback=none"))
        #expect(audit.summary.contains("recoveries=1"))
        #expect(audit.summary.contains("firstBad{reason=invalidCMTime"))
    }

    @Test("有效 PTS 的間隔分桶與 min/max")
    func intervalBuckets() {
        var audit = SourceTimeAudit()
        _ = audit.observe(pts: 0, reason: nil, detail: "", now: 0)
        _ = audit.observe(pts: 0.04, reason: nil, detail: "", now: 0.04)
        _ = audit.observe(pts: 0.08, reason: nil, detail: "", now: 0.08)
        _ = audit.observe(pts: 0.7, reason: nil, detail: "", now: 0.7)   // 0.62s → 0.5–2s
        _ = audit.observe(pts: 3.7, reason: nil, detail: "", now: 3.7)   // 3.0s → ≥2s
        #expect(audit.gapsOverHalfSecond == 1)
        #expect(audit.gapsOverTwoSeconds == 1)
        #expect(audit.minDelta == 0.04)
        #expect(audit.maxDelta == 3.0)
        #expect(audit.negativeDeltas == 0)
        #expect(audit.duplicateDeltas == 0)
    }

    @Test("負向與重複 PTS 分開計數，且不污染 min/max")
    func negativeAndDuplicate() {
        var audit = SourceTimeAudit()
        _ = audit.observe(pts: 10, reason: nil, detail: "", now: 0)
        _ = audit.observe(pts: 10.5, reason: nil, detail: "", now: 0.5)
        _ = audit.observe(pts: 10.5, reason: nil, detail: "", now: 0.533)
        _ = audit.observe(pts: 10.2, reason: nil, detail: "", now: 0.566)
        #expect(audit.duplicateDeltas == 1)
        #expect(audit.negativeDeltas == 1)
        #expect(audit.minDelta == 0.5)
        #expect(audit.maxDelta == 0.5)
    }

    @Test("來源前進量與到達時間差超過門檻才回報 arrivalDrift")
    func arrivalDrift() {
        var audit = SourceTimeAudit()
        _ = audit.observe(pts: 10, reason: nil, detail: "", now: 0)
        #expect(audit.observe(pts: 10.1, reason: nil, detail: "", now: 1.0) == nil)
        let report = audit.observe(pts: 10.2, reason: nil, detail: "", now: 2.5)
        #expect(report?.contains("event=arrivalDrift") == true)
        #expect(audit.maxAbsDrift >= 1.4)
    }

    @Test("間隔異常首次回報，30 秒內不重複")
    func anomalyThrottle() {
        var audit = SourceTimeAudit()
        _ = audit.observe(pts: 10, reason: nil, detail: "", now: 0)
        #expect(audit.observe(pts: 12.5, reason: nil, detail: "", now: 0.1)?
            .contains("event=gapOver2s") == true)
        #expect(audit.observe(pts: 15.0, reason: nil, detail: "", now: 0.2) == nil)
        #expect(audit.gapsOverTwoSeconds == 2)
        #expect(audit.observe(pts: 17.5, reason: nil, detail: "", now: 40)?
            .contains("event=gapOver2s") == true)
    }
}
