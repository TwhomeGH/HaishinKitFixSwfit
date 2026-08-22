import Foundation

/// A minimal NLMS (normalized least mean squares) acoustic echo canceller.
///
/// 用途：ReplayKit 雙軌（.audioApp / .audioMic）混音時，App 聲音從喇叭外放會被
/// mic 收音，混音後與 App 原聲雙重重疊（**物理回音**）。AEC 以 App 軌為 reference、
/// mic 軌為 target：估計 mic 收到的回音 `ŷ[n] = Σ w[k]·ref[n-k]`，相減後輸出乾淨
/// 的人聲，再以 NLMS 規則逐幀自適應 w 追蹤喇叭→mic 的聲學路徑（含聲學延遲）。
///
/// 與處理層回音的區別：
/// - **處理層相位差回音**：來源 PTS 一致但混音「先到先混」造成時間偏移 —— 由
///   `AudioRingBuffer.align(to:)` 解決，與本類無關。
/// - **物理回音（本類處理）**：喇叭外放被 mic 收音，同一段聲音出現兩次 ——
///   線性 NLMS 模型做**衰減**（非消除），雙講（人聲+音樂同時）時凍結更新避免發散。
///
/// 執行緒：僅在 `AudioMixerByMultiTrack` 的 serial queue 上使用，非執行緒安全。
final class AudioEchoCanceler {
    /// 喇叭→mic 聲學路徑的 tap 數。1024 @48k ≈ 21ms，涵蓋手持裝置的聲學延遲
    /// （幾 ms）+ mic 擷取延遲。過長會收斂變慢，過短涵蓋不了延遲就無效。
    static let defaultFilterLength = 1024

    private let filterLength: Int
    private var filter: [Float]
    /// 連續的 reference 樣本（依位置），`reference[0]` 對應 `referenceBase` 位置。
    private var reference: [Float] = []
    private var referenceBase: Int64 = 0
    private let maxReferenceLength: Int

    private let updateStep: Float = 0.2
    private let regularization: Float = 1e-4
    /// 雙講偵測：micPower > ratio × refPower → 判定有人聲，凍結更新。
    private let doubleTalkRatio: Float = 2.0
    private let referencePowerFloor: Float = 1e-6

    /// 最近一幀的能量（除錯用）。
    private(set) var lastTargetPower: Float = 0
    private(set) var lastReferencePower: Float = 0

    init(filterLength: Int = AudioEchoCanceler.defaultFilterLength, maxFrameSize: Int = 1024) {
        self.filterLength = filterLength
        self.filter = [Float](repeating: 0, count: filterLength)
        self.maxReferenceLength = filterLength + maxFrameSize
    }

    func reset() {
        filter = [Float](repeating: 0, count: filterLength)
        reference = []
        referenceBase = 0
        lastTargetPower = 0
        lastReferencePower = 0
    }

    /// 推送 reference（App 軌）樣本，必須依位置連續（`AudioMixerTrack` 的
    /// `when.sampleTime` 逐幀 +frameLength，兩軌共用同一來源時鐘，天然連續）。
    func pushReference(_ samples: [Float], at position: Int64) {
        guard !samples.isEmpty else {
            return
        }
        let expected = referenceBase + Int64(reference.count)
        if reference.isEmpty {
            referenceBase = position
        } else if position != expected {
            // 理論上不會發生；若發生代表參考訊號不連續，重設基準讓過濾器重收斂。
            reference = []
            referenceBase = position
        }
        reference.append(contentsOf: samples)
        if reference.count > maxReferenceLength {
            let excess = reference.count - maxReferenceLength
            reference.removeFirst(excess)
            referenceBase += Int64(excess)
        }
    }

    /// 對 target（mic）幀做回音消除，輸出乾淨的人聲（與輸入同長度）。
    /// 雙講/無參考時仍做相消但不更新濾波器，避免發散。
    func process(_ samples: [Float], at position: Int64) -> [Float] {
        let frame = samples.count
        var output = [Float](repeating: 0, count: frame)
        guard !reference.isEmpty, frame > 0 else {
            return samples
        }
        var micPower: Float = 0
        for s in samples {
            micPower += s * s
        }
        micPower /= Float(frame)
        // 參考能量粗估（stride 抽樣節省遍歷）。
        var refPower: Float = 0
        let sampleStride = max(1, filterLength / 64)
        for n in 0..<frame {
            let micPos = position + Int64(n)
            for k in stride(from: 0, to: filterLength, by: sampleStride) {
                let idx = (micPos - Int64(k)) - referenceBase
                guard idx >= 0 && idx < Int64(reference.count) else { continue }
                let x = reference[Int(idx)]
                refPower += x * x
            }
        }
        refPower = refPower * Float(sampleStride) / Float(frame)
        let isDoubleTalk = micPower > doubleTalkRatio * refPower
        let shouldUpdate = !isDoubleTalk && refPower >= referencePowerFloor

        for n in 0..<frame {
            let micPos = position + Int64(n)
            var estimate: Float = 0
            var norm: Float = 0
            for k in 0..<filterLength {
                let idx = (micPos - Int64(k)) - referenceBase
                guard idx >= 0 && idx < Int64(reference.count) else { continue }
                let x = reference[Int(idx)]
                estimate += filter[k] * x
                norm += x * x
            }
            let residual = samples[n] - estimate
            output[n] = residual
            if shouldUpdate {
                let step = updateStep * residual / (norm + regularization * Float(filterLength))
                for k in 0..<filterLength {
                    let idx = (micPos - Int64(k)) - referenceBase
                    guard idx >= 0 && idx < Int64(reference.count) else { continue }
                    filter[k] += step * reference[Int(idx)]
                }
            }
        }
        lastTargetPower = micPower
        lastReferencePower = refPower
        return output
    }
}
