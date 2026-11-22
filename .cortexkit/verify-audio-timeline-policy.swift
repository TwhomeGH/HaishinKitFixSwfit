// Verification of AudioTimelinePolicy (HaishinKit/Sources/Mixer/AudioTimelinePolicy.swift)
// on non-Apple platforms. Compiled together with the REAL source (Foundation-only):
//
//   swiftc HaishinKit/Sources/Mixer/AudioTimelinePolicy.swift \
//          .cortexkit/verify-audio-timeline-policy.swift -o .cortexkit/verify-audio-timeline-policy.exe
//
// The three layers (anchor, ring buffers, mix clock) now share this policy, so the
// classification and second/sample conversion can be verified anywhere. The actual
// mixer render still needs AVFoundation and is covered by HaishinKitTests on Apple CI.
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
struct VerifyAudioTimelinePolicy {
    static func main() {
        // 前向：補零範圍內 vs 超過 → 重建。
        expect(AudioTimelinePolicy.classify(0) == .continuous, "delta 0 -> continuous")
        expect(AudioTimelinePolicy.classify(0.1) == .zeroFillForward, "0.1s -> zero fill")
        expect(AudioTimelinePolicy.classify(0.25) == .zeroFillForward, "0.25s boundary -> zero fill")
        expect(AudioTimelinePolicy.classify(0.251) == .rebaseForward, "0.251s -> rebase")
        expect(AudioTimelinePolicy.classify(3) == .rebaseForward, "3s -> rebase")

        // 倒退：抖動 vs 全面重設（0.25–1.0s 不再部分重設）。
        expect(AudioTimelinePolicy.classify(-0.3) == .jitterBackward, "-0.3s -> jitter")
        expect(AudioTimelinePolicy.classify(-1.0) == .jitterBackward, "-1.0s boundary -> jitter")
        expect(AudioTimelinePolicy.classify(-1.001) == .resyncBackward, "-1.001s -> resync")
        expect(AudioTimelinePolicy.classify(-5) == .resyncBackward, "-5s -> resync")

        // 秒 → 樣本數必須隨取樣率改變，修正原本寫死 48,000 samples 的偏差。
        expect(AudioTimelinePolicy.samples(forSeconds: 1, rate: 44_100) == 44_100, "1s @44.1k")
        expect(AudioTimelinePolicy.samples(forSeconds: 1, rate: 48_000) == 48_000, "1s @48k")
        expect(AudioTimelinePolicy.samples(forSeconds: 1, rate: 16_000) == 16_000, "1s @16k")
        expect(AudioTimelinePolicy.samples(forSeconds: 0.25, rate: 48_000) == 12_000, "0.25s @48k")

        // 無效參數回 0；呼叫端不得把 0 當成達標而重設。
        expect(AudioTimelinePolicy.samples(forSeconds: 1, rate: 0) == 0, "rate 0 -> 0")
        expect(AudioTimelinePolicy.samples(forSeconds: .infinity, rate: 48_000) == 0, "infinite seconds -> 0")
        expect(AudioTimelinePolicy.classify(.nan) == .continuous, "NaN delta -> continuous")

        print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
        exit(failures == 0 ? 0 : 1)
    }
}
