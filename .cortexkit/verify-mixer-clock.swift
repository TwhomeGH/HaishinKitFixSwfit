// Verification of MixClockAdvance (HaishinKit/Sources/Mixer/MixClockAdvance.swift)
// on non-Apple platforms. Compiled together with the REAL source (Foundation-only):
//
//   swiftc HaishinKit/Sources/Mixer/MixClockAdvance.swift \
//          .cortexkit/verify-mixer-clock.swift -o .cortexkit/verify-mixer-clock.exe
//
// The mix-clock fallback (main silent → other track advances) is now a pure
// decision, so it can be verified anywhere. The end-to-end mixer render needs
// AVFoundation and is covered by AudioMixerByMultiTrackTests on macOS.
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
struct VerifyMixClock {
    static func main() {
        // main 軌永遠驅動時鐘（即使其「上次輸出」看起來領先）。
        expect(MixClockAdvance.shouldAdvance(
            track: 0, mainTrack: 0, mainLastOutputPosition: nil, position: 0),
            "main track always advances")
        expect(MixClockAdvance.shouldAdvance(
            track: 0, mainTrack: 0, mainLastOutputPosition: 9999, position: 0),
            "main track advances regardless of recorded position")

        // main 從未輸出 → 其他軌接手（ReplayKit app 完全沒播放）。
        expect(MixClockAdvance.shouldAdvance(
            track: 1, mainTrack: 0, mainLastOutputPosition: nil, position: 1024),
            "main never produced -> other track advances")

        // main 落後 → 其他軌接手（app 靜默、mic 持續）。
        expect(MixClockAdvance.shouldAdvance(
            track: 1, mainTrack: 0, mainLastOutputPosition: 1024, position: 2048),
            "main lagging -> other track advances")

        // main 同位置 → 不推進（同一 block 避免重複混音）。
        expect(!MixClockAdvance.shouldAdvance(
            track: 1, mainTrack: 0, mainLastOutputPosition: 1024, position: 1024),
            "main at same position -> no advance")

        // main 領先 → 不推進（避免先到者被 align 當過期丟棄）。
        expect(!MixClockAdvance.shouldAdvance(
            track: 1, mainTrack: 0, mainLastOutputPosition: 2048, position: 1024),
            "main ahead -> no advance")

        print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
        exit(failures == 0 ? 0 : 1)
    }
}
