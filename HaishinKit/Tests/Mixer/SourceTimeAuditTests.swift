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
}
