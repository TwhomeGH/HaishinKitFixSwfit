// Verification of AVContentSyncAudit (HaishinKit/Sources/Mixer/AVContentSyncAudit.swift)
// on non-Apple platforms. Compiled together with the real source file:
//
//   swiftc HaishinKit/Sources/Mixer/AVContentSyncAudit.swift \
//          .cortexkit/verify-av-content-sync.swift -o .cortexkit/verify-av-content-sync.exe
//
// Covers: arrival-window pairing, handed/content offset separation, capture-time
// age detection, missing capture time, and the content-offset slope.
import Foundation

var failures = 0
func expect(_ condition: Bool, _ name: String) {
    if condition {
        print("  ok   \(name)")
    } else {
        failures += 1
        print("  FAIL \(name)")
    }
}

func close(_ value: Double?, _ expected: Double, _ tolerance: Double = 1e-9) -> Bool {
    guard let value else { return false }
    return abs(value - expected) <= tolerance
}

@main
struct VerifyAVContentSync {
    static func main() {
        // 1. Pair inside the arrival window.
        do {
            var audit = AVContentSyncAudit(pairingWindow: 0.05)
            _ = audit.observe(kind: .video, handedPTS: 10, capturePTS: 10, arrival: 100)
            _ = audit.observe(kind: .audio, handedPTS: 10.02, capturePTS: nil, arrival: 100.01)
            expect(audit.paired == 1, "paired within window")
            expect(close(audit.lastHandedOffset, -0.02), "handedOffset = videoPTS - audioPTS")
            expect(close(audit.lastAgeSkew, 0.01), "ageSkew uses arrival minus capture time")
        }

        // 2. No pairing outside the window; pending expires into unpaired.
        do {
            var audit = AVContentSyncAudit(pairingWindow: 0.05)
            _ = audit.observe(kind: .video, handedPTS: 10, capturePTS: 10, arrival: 100)
            _ = audit.observe(kind: .audio, handedPTS: 10, capturePTS: nil, arrival: 100.1)
            expect(audit.paired == 0, "no pair outside window")
            _ = audit.observe(kind: .video, handedPTS: 12, capturePTS: 12, arrival: 102)
            expect(audit.paired == 0, "still no pair")
            expect(audit.unpairedVideo == 1, "stale video counted as unpaired")
        }

        // 3. The key case: handed PTS look aligned, source capture time is 4s old.
        do {
            var audit = AVContentSyncAudit(pairingWindow: 0.05)
            _ = audit.observe(kind: .video, handedPTS: 104, capturePTS: 100, arrival: 104)
            _ = audit.observe(kind: .audio, handedPTS: 104, capturePTS: nil, arrival: 104.01)
            expect(close(audit.lastHandedOffset, 0), "handed PTS look aligned")
            expect(close(audit.lastContentOffset, -4), "contentOffset exposes 4s content lag")
            expect(close(audit.lastVideoAge, 4), "videoAge = arrival - capturePTS")
            expect(close(audit.lastAgeSkew, 3.99, 1e-6), "ageSkew = videoAge - audioAge")
            expect(audit.summary.contains("captureTime=sourcePTS"), "summary reports sourcePTS")
        }

        // 4. Missing capture time falls back to handed PTS and says so.
        do {
            var audit = AVContentSyncAudit(pairingWindow: 0.05)
            _ = audit.observe(kind: .video, handedPTS: 10, capturePTS: nil, arrival: 100)
            _ = audit.observe(kind: .audio, handedPTS: 10, capturePTS: nil, arrival: 100.01)
            expect(audit.videoCaptureTimeSamples == 0, "no capture-time samples")
            expect(audit.summary.contains("captureTime=missing"), "summary flags missing capture time")
        }

        // 5. Content-offset slope.
        do {
            var audit = AVContentSyncAudit(pairingWindow: 0.05)
            for index in 0..<5 {
                let time = Double(index * 10)
                let offset = Double(index) * 0.01
                _ = audit.observe(kind: .video, handedPTS: time + offset, capturePTS: time + offset, arrival: time)
                _ = audit.observe(kind: .audio, handedPTS: time, capturePTS: nil, arrival: time + 0.01)
            }
            expect(audit.paired == 5, "five pairs")
            expect(close(audit.contentOffsetStats?.slopePerMinute, 0.06, 1e-6), "slope = 0.06s per minute")
        }

        // 6. Out-of-order arrival: the closest sample wins, not the newest.
        do {
            var audit = AVContentSyncAudit(pairingWindow: 0.05)
            _ = audit.observe(kind: .audio, handedPTS: 100.0, capturePTS: nil, arrival: 100.0)
            _ = audit.observe(kind: .audio, handedPTS: 100.03, capturePTS: nil, arrival: 100.03)
            _ = audit.observe(kind: .video, handedPTS: 100.0, capturePTS: 100.0, arrival: 100.01)
            expect(audit.paired == 1, "paired once")
            expect(close(audit.lastHandedOffset, 0, 1e-9), "closest audio sample selected")
        }

        print("")
        if failures == 0 {
            print("ALL CONTENT-SYNC SCENARIOS PASSED")
        } else {
            print("\(failures) FAILURES")
            exit(1)
        }
    }
}
