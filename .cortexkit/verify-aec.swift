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

    // 計算不連續（爆音）數：|x[i+1]-x[i]| > 8× 局部微分 RMS 即為不連續。
    static func discontinuityCount(_ samples: [Float]) -> Int {
        let n = samples.count
        guard n > 200 else { return 0 }
        var diff = [Float](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) { diff[i] = abs(samples[i + 1] - samples[i]) }
        // 預先算每個位置的局部微分 RMS（滑動和，O(n)）
        let win = 2400
        var localRms = [Float](repeating: 0, count: n - 1)
        var acc: Double = 0
        for i in 0..<(n - 1) {
            let d = diff[i]
            let d2 = Double(d * d)
            if i < win {
                acc += d2
            } else {
                acc += d2 - Double(diff[i - win] * diff[i - win])
            }
            localRms[i] = Float((acc / Double(min(i + 1, win))).squareRoot())
        }
        var count = 0
        var i = 1
        while i < n - 1 {
            if diff[i] > 8 * localRms[i] {
                count += 1
                i += 150
            }
            i += 1
        }
        return count
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

        print("== 不連續性：人聲能量 ≈ 回音能量（gate 臨界）==")
        do {
            // 人聲音量調到與回音同級（echo = 0.5×0.3 = 0.15，voice ≈ 0.12），
            // 位於 double-talk gate (2.0 ratio) 的邊界——最容易讓濾波器追人聲。
            var voice2: [Float] = [Float](repeating: 0, count: sampleCount)
            for i in 20000..<24000 { voice2[i] = sin(Float(i - 20000) * 0.3) * 0.12 }
            var mic2: [Float] = voice2
            for i in delay..<sampleCount { mic2[i] += app[i - delay] * echoGain }
            let aec2 = AudioEchoCanceler()
            var out2 = [Float](repeating: 0, count: sampleCount)
            for start in stride(from: 0, to: sampleCount, by: frameSize) {
                let end = min(start + frameSize, sampleCount)
                aec2.pushReference(Array(app[start..<end]), at: Int64(start))
                out2.replaceSubrange(start..<end, with: aec2.process(Array(mic2[start..<end]), at: Int64(start)))
            }
            let inputDis = discontinuityCount(mic2)
            let outputDis = discontinuityCount(out2)
            print("    input discontinuities=\(inputDis) AEC output=\(outputDis)")
            // AEC 不應新增明顯的不連續（允許少許誤差；input 本身也可能有）
            expect(outputDis <= inputDis + 3, "AEC does not introduce discontinuities (output \(outputDis) vs input \(inputDis))")
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
