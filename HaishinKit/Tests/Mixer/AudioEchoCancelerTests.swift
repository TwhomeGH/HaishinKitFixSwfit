import Foundation
import Testing

@testable import HaishinKit

/// `AudioEchoCanceler`（NLMS AEC）的行為驗證：回音衰減收斂、雙講保留人聲、
/// 雙講後不發散，以及 gate 臨界時不製造樣本不連續（爆音）。
///
/// 同一組案例也有非 Apple 平台的獨立驗證腳本 `.cortexkit/verify-aec.swift`。
/// `AudioEchoCanceler` 只依賴 Foundation，因此本就是可單元測試的純 DSP。
@Suite("AudioEchoCanceler：回音衰減 / 雙講 / 不連續")
struct AudioEchoCancelerTests {
    private static let sampleCount = 48000   // 1s @48k
    private static let frameSize = 1024
    private static let delay = 50            // 聲學延遲（samples）
    private static let echoGain: Float = 0.5

    /// 固定 seed 的 PRNG，讓合成訊號可重現。
    private struct LCG {
        var state: UInt64 = 12345
        mutating func next() -> Float {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(state >> 33) / Float(1 << 31) - 1.0
        }
    }

    /// 合成 app reference（正弦 + 雜訊，模擬音樂）與 mic target（人聲 + 延遲回音）。
    private static func makeSignals(voiceGain: Float = 0.8) -> (app: [Float], mic: [Float]) {
        var lcg = LCG()
        var app = [Float](repeating: 0, count: sampleCount)
        var phase: Float = 0
        for i in 0..<sampleCount {
            phase += 0.02
            app[i] = sin(phase) * 0.3 + lcg.next() * 0.1
        }
        var voice = [Float](repeating: 0, count: sampleCount)
        for i in 20000..<24000 {
            voice[i] = sin(Float(i - 20000) * 0.3) * voiceGain
        }
        var mic = voice
        for i in delay..<sampleCount {
            mic[i] += app[i - delay] * echoGain
        }
        return (app, mic)
    }

    private static func runAEC(app: [Float], mic: [Float]) -> [Float] {
        let aec = AudioEchoCanceler()
        var out = [Float](repeating: 0, count: sampleCount)
        for start in stride(from: 0, to: sampleCount, by: frameSize) {
            let end = min(start + frameSize, sampleCount)
            aec.pushReference(Array(app[start..<end]), at: Int64(start))
            out.replaceSubrange(start..<end, with: aec.process(Array(mic[start..<end]), at: Int64(start)))
        }
        return out
    }

    private static func power(_ samples: ArraySlice<Float>) -> Float {
        var p: Float = 0
        for s in samples { p += s * s }
        return p / Float(max(samples.count, 1))
    }

    /// 計算不連續（爆音）數：|x[i+1]-x[i]| > 8× 局部微分 RMS。
    private static func discontinuityCount(_ samples: [Float]) -> Int {
        let n = samples.count
        guard n > 200 else { return 0 }
        var diff = [Float](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) { diff[i] = abs(samples[i + 1] - samples[i]) }
        let win = 2400
        var localRms = [Float](repeating: 0, count: n - 1)
        var acc: Double = 0
        for i in 0..<(n - 1) {
            let d = Double(diff[i]) * Double(diff[i])
            if i < win {
                acc += d
            } else {
                acc += d - Double(diff[i - win]) * Double(diff[i - win])
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

    @Test("收斂後回音衰減 >12dB、雙講保留人聲、且雙講後不發散")
    func convergesPreservesVoiceAndDoesNotDiverge() {
        let (app, mic) = Self.makeSignals()
        let out = Self.runAEC(app: app, mic: mic)

        // 28..44k：已收斂、無人聲的區段。
        let originalEcho = Self.power(mic[28000..<44000])
        let residual = Self.power(out[28000..<44000])
        let reductionDB = 10 * log10(originalEcho / max(residual, 1e-12))
        #expect(reductionDB > 12, "echo reduced >12dB (got \(reductionDB)dB)")

        // 雙講：人聲區輸出仍遠高於安靜區。
        let voiceOut = Self.power(out[21000..<23000])
        let quietOut = Self.power(out[30000..<32000])
        #expect(voiceOut > quietOut * 10, "voice preserved through double-talk (ratio \(voiceOut / max(quietOut, 1e-12)))")

        // 雙講後濾波器不發散：人聲後的殘差不得暴增。
        let beforeVoice = Self.power(out[3000..<16000])
        #expect(residual < beforeVoice * 3 || residual < 1e-4, "filter did not diverge after double-talk")
    }

    @Test("雙講能量 ≈ 回音能量（gate 臨界）時不製造不連續")
    func doesNotIntroduceDiscontinuitiesAtGateBoundary() {
        // 人聲音量調到與回音同級（echo ≈ 0.15），位於 double-talk gate (2.0×) 邊界——
        // 最容易讓濾波器追人聲；AEC 不應新增明顯的不連續。
        let (app, _) = Self.makeSignals()
        let (_, mic2) = Self.makeSignals(voiceGain: 0.12)
        let out = Self.runAEC(app: app, mic: mic2)

        let inputDiscontinuities = Self.discontinuityCount(mic2)
        let outputDiscontinuities = Self.discontinuityCount(out)
        #expect(outputDiscontinuities <= inputDiscontinuities + 3,
                "AEC introduces no new discontinuities (out \(outputDiscontinuities) vs in \(inputDiscontinuities))")
    }

    @Test("沒有 reference 時原樣輸出")
    func passesThroughWithoutReference() {
        let aec = AudioEchoCanceler()
        let input: [Float] = [0.1, -0.2, 0.3, -0.4]
        #expect(aec.process(input, at: 0) == input)
    }

    @Test("pushReference 位置不連續時重設基準，之後仍可運作")
    func resetsOnDiscontinuousReference() {
        let aec = AudioEchoCanceler(filterLength: 8, maxFrameSize: 4)
        aec.pushReference([1, 0, 0, 0], at: 0)
        aec.pushReference([1, 0, 0, 0], at: 100) // gap → 重設 base
        let out = aec.process([0.5, 0.5, 0.5, 0.5], at: 100)
        #expect(out.count == 4)
    }

    @Test("reset 清空濾波器與能量狀態")
    func resetClearsState() {
        let aec = AudioEchoCanceler(filterLength: 8, maxFrameSize: 4)
        aec.pushReference([1, 0, 0, 0], at: 0)
        _ = aec.process([1, 0, 0, 0], at: 0)
        #expect(aec.lastTargetPower > 0)

        aec.reset()
        #expect(aec.lastTargetPower == 0 && aec.lastReferencePower == 0)
        // reference 已清空 → 原樣輸出，不會有殘留的相消。
        #expect(aec.process([0.5, 0.5, 0.5, 0.5], at: 0) == [0.5, 0.5, 0.5, 0.5])
    }
}
