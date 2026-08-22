// Standalone verification of AudioEchoCanceler (NLMS AEC).
// Compile with: swiftc HaishinKit/Sources/Mixer/AudioEchoCanceler.swift .cortexkit/verify-aec.swift
import Foundation

@main
struct VerifyAEC {
    static var failures = 0

    static func expect(_ cond: Bool, _ name: String) {
        if cond { print("  ✓ \(name)") } else { failures += 1; print("  ✗ \(name)") }
    }

    static func power(_ samples: ArraySlice<Float>) -> Float {
        var p: Float = 0
        for s in samples { p += s * s }
        return p / Float(max(samples.count, 1))
    }

    static func main() {
        let sampleCount = 48000          // 1 秒 @48k
        let frameSize = 1024
        let delay = 50                   // 聲學延遲（samples）
        let echoGain: Float = 0.5        // 喇叭→mic 路徑增益

        // 合成 app reference（正弦 + 雜訊，模擬音樂）
        var app: [Float] = [Float](repeating: 0, count: sampleCount)
        var phase: Float = 0
        var seed: UInt64 = 12345
        func nextRand() -> Float {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Float(seed >> 33) / Float(1 << 31) - 1.0
        }
        for i in 0..<sampleCount {
            phase += 0.02
            app[i] = sin(phase) * 0.3 + nextRand() * 0.1
        }

        // 人聲（只在 [20000, 24000) 出現，且音量高於 echo）
        var voice: [Float] = [Float](repeating: 0, count: sampleCount)
        for i in 20000..<24000 {
            voice[i] = sin(Float(i - 20000) * 0.3) * 0.8
        }

        // mic = voice + echo（app 延遲 delay 後 × echoGain）
        var mic: [Float] = voice
        for i in delay..<sampleCount {
            mic[i] += app[i - delay] * echoGain
        }

        func runAEC() -> [Float] {
            let aec = AudioEchoCanceler()
            var out = [Float](repeating: 0, count: sampleCount)
            for start in stride(from: 0, to: sampleCount, by: frameSize) {
                let end = min(start + frameSize, sampleCount)
                let ref = Array(app[start..<end])
                let m = Array(mic[start..<end])
                aec.pushReference(ref, at: Int64(start))
                let processed = aec.process(m, at: Int64(start))
                out.replaceSubrange(start..<end, with: processed)
            }
            return out
        }

        print("== AEC 收斂與回音衰減（無人聲區）==")
        do {
            let out = runAEC()
            let residual = power(out[28000..<44000])
            let originalEcho = power(mic[28000..<44000])
            let reductionDB = 10 * log10(originalEcho / max(residual, 1e-12))
            print("    originalEcho=\(String(format: "%.5f", originalEcho)) residual=\(String(format: "%.5f", residual)) reduction=\(String(format: "%.1f", reductionDB))dB")
            expect(reductionDB > 12, "echo reduced >12dB after convergence (got \(String(format: "%.1f", reductionDB))dB)")
        }

        print("== 人聲保留（雙講期間輸出仍有人聲）==")
        do {
            let out = runAEC()
            let voiceOut = power(out[21000..<23000])
            let quietOut = power(out[30000..<32000])
            print("    voice region=\(String(format: "%.4f", voiceOut)) quiet=\(String(format: "%.4f", quietOut))")
            expect(voiceOut > quietOut * 10, "voice preserved through double-talk (ratio \(voiceOut / max(quietOut, 1e-12)))")
        }

        print("== 雙講後濾波器不發散（人聲後回音衰減仍保持）==")
        do {
            let out = runAEC()
            let afterVoice = power(out[28000..<44000])
            let beforeVoice = power(out[3000..<16000])
            print("    before=\(String(format: "%.5f", beforeVoice)) afterVoice=\(String(format: "%.5f", afterVoice))")
            expect(afterVoice < beforeVoice * 3 || afterVoice < 1e-4, "filter did not diverge after double-talk")
        }

        print("")
        if failures == 0 {
            print("ALL AEC SCENARIOS PASSED")
        } else {
            print("\(failures) FAILURES")
            exit(1)
        }
    }
}
