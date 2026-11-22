// Verification of VideoFrameFilterState (HaishinKit/Sources/Util/VideoFrameFilterState.swift)
// on non-Apple platforms. Compiled together with the REAL source (Foundation-only):
//
//   swiftc HaishinKit/Sources/Util/VideoFrameFilterState.swift \
//          .cortexkit/verify-video-frame-filter.swift -o .cortexkit/verify-video-frame-filter.exe
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
struct VerifyVideoFrameFilter {
    static func main() {
        // 1) 理由分開累計、連續過濾與最大值。
        var a = VideoFrameFilterState()
        a.filtered(reason: .nonMonotonic, presentationTime: 9.9,
                   lastAcceptedPresentationTime: 10.0, uptime: 1.0)
        a.filtered(reason: .frameInterval, presentationTime: 10.01,
                   lastAcceptedPresentationTime: 10.0, uptime: 1.01)
        a.filtered(reason: .frameInterval, presentationTime: 10.02,
                   lastAcceptedPresentationTime: 10.0, uptime: 1.02)
        expect(a.consecutive == 3, "consecutive 3")
        expect(a.maxConsecutive == 3, "maxConsecutive 3")
        expect((a.reasonCounts["nonMonotonic"] ?? 0) == 1, "nonMonotonic count")
        expect((a.reasonCounts["frameInterval"] ?? 0) == 2, "frameInterval count")
        expect(abs((a.last?.deltaSeconds ?? 0) - 0.02) < 1e-9, "last delta 0.02")

        // 2) 接受影格只歸零連續數，保留歷史最大值。
        a.accepted()
        expect(a.consecutive == 0, "accepted resets consecutive")
        expect(a.maxConsecutive == 3, "accepted keeps maxConsecutive")
        a.filtered(reason: .adaptiveThrottle, presentationTime: 11,
                   lastAcceptedPresentationTime: 10.5, uptime: 2)
        expect(a.consecutive == 1, "consecutive restarts at 1")

        // 3) 無效 PTS 與尚未接受影格時 delta 為 unknown。
        var b = VideoFrameFilterState()
        b.filtered(reason: .beforeStart, presentationTime: .nan,
                   lastAcceptedPresentationTime: nil, uptime: 1)
        expect(b.last?.presentationTimeSeconds == nil, "NaN PTS -> unknown")
        expect(b.last?.deltaSeconds == nil, "no accepted -> delta unknown")

        // 4) 倒退保留負 delta。
        var c = VideoFrameFilterState()
        c.filtered(reason: .nonMonotonic, presentationTime: 9.5,
                   lastAcceptedPresentationTime: 10.0, uptime: 1)
        expect(abs((c.last?.deltaSeconds ?? 0) - (-0.5)) < 1e-9, "negative delta preserved")

        // 5) 快照摘要。
        let text = a.snapshot.summary
        expect(text.contains("reasons{"), "summary has reason counts")
        expect(text.contains("last{reason="), "summary has last sample")

        print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
        exit(failures == 0 ? 0 : 1)
    }
}
