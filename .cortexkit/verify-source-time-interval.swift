// Verification of SourceTimeAudit interval metrics
// (HaishinKit/Sources/Util/SourceTimeAudit.swift, Foundation-only real source):
//
//   swiftc HaishinKit/Sources/Util/SourceTimeAudit.swift \
//          .cortexkit/verify-source-time-interval.swift -o .cortexkit/verify-source-time-interval.exe
import Foundation

var failures = 0
func expect(_ cond: Bool, _ name: String) {
    if cond {
        print("  ok   \(name)")
    } else {
        failures += 1
        print("  FAIL \(name)")
    }
}

@main
struct VerifySourceTimeInterval {
    static func main() {
        // 1) 間隔分桶：0.5–2s 與 ≥2s 互斥，min/max 只看正向間隔。
        var a = SourceTimeAudit()
        _ = a.observe(pts: 0, reason: nil, detail: "", now: 0)
        _ = a.observe(pts: 0.04, reason: nil, detail: "", now: 0.04)
        _ = a.observe(pts: 0.08, reason: nil, detail: "", now: 0.08)
        _ = a.observe(pts: 0.7, reason: nil, detail: "", now: 0.7)   // 0.62s
        _ = a.observe(pts: 3.7, reason: nil, detail: "", now: 3.7)   // 3.0s
        expect(a.gapsOverHalfSecond == 1, "0.62s -> 0.5-2s bucket")
        expect(a.gapsOverTwoSeconds == 1, "3.0s -> >=2s bucket")
        expect(a.minDelta == 0.04, "min delta")
        expect(a.maxDelta == 3.0, "max delta")

        // 2) 負向／重複分開計數，且不污染 min/max。
        var b = SourceTimeAudit()
        _ = b.observe(pts: 10, reason: nil, detail: "", now: 0)
        _ = b.observe(pts: 10.5, reason: nil, detail: "", now: 0.5)
        _ = b.observe(pts: 10.5, reason: nil, detail: "", now: 0.533)
        _ = b.observe(pts: 10.2, reason: nil, detail: "", now: 0.566)
        expect(b.duplicateDeltas == 1, "duplicate counted")
        expect(b.negativeDeltas == 1, "negative counted")
        expect(b.minDelta == 0.5 && b.maxDelta == 0.5, "duplicate/negative excluded from min/max")

        // 3) 來源前進量 vs 到達時間的漂移。
        var c = SourceTimeAudit()
        _ = c.observe(pts: 10, reason: nil, detail: "", now: 0)
        expect(c.observe(pts: 10.1, reason: nil, detail: "", now: 1.0) == nil, "drift 0.9 -> no report")
        let drift = c.observe(pts: 10.2, reason: nil, detail: "", now: 2.5)
        expect(drift?.contains("event=arrivalDrift") == true, "drift 1.4 -> report")
        expect(c.maxAbsDrift >= 1.4, "maxAbsDrift recorded")

        // 4) 首次異常立即回報，30 秒內不重複，但計數仍累加。
        var d = SourceTimeAudit()
        _ = d.observe(pts: 10, reason: nil, detail: "", now: 0)
        expect(d.observe(pts: 12.5, reason: nil, detail: "", now: 0.1)?
            .contains("event=gapOver2s") == true, "first gap reports immediately")
        expect(d.observe(pts: 15.0, reason: nil, detail: "", now: 0.2) == nil, "second gap throttled")
        expect(d.gapsOverTwoSeconds == 2, "gap count still increments")
        expect(d.observe(pts: 17.5, reason: nil, detail: "", now: 40)?
            .contains("event=gapOver2s") == true, "reports after 30s")

        // 5) 摘要保留新欄位與既有不推測標記。
        expect(a.summary.contains("lastDelta="), "summary has lastDelta")
        expect(a.summary.contains("gapsOverTwoSeconds="), "summary has gap bucket")
        expect(a.summary.contains("clockComparison=unverified"), "summary keeps unverified marker")

        print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
        exit(failures == 0 ? 0 : 1)
    }
}
