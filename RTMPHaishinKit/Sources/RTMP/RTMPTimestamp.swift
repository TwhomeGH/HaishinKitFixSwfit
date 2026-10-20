import AVFoundation
import CoreMedia
import Foundation

protocol RTMPTimeConvertible {
    var seconds: TimeInterval { get }
}

private let kRTMPTimestamp_defaultTimeInterval: TimeInterval = 0

/// 舊呼叫策略的 delta 上限（ms）；影片使用 preserveForwardGaps，不套用此截限。
private let kRTMPTimestamp_maxDelta: TimeInterval = 2000
private let kRTMPTimestamp_preferredDeltaDriftTolerance: TimeInterval = 80
private let kRTMPTimestamp_preferredDeltaMaxCorrection: TimeInterval = 5
private let kRTMPTimestamp_preferredDeltaCorrectionRatio: TimeInterval = 0.1
private let kRTMPTimestamp_preferredDeltaJumpThreshold: TimeInterval = 500

/// 單軌時間戳診斷；僅保存固定大小的統計，不持有媒體樣本。
/// generated 指已產生的 RTMP delta 累計，不代表入列、socket 完成或伺服器確認。
struct RTMPTimestampDiagnostics {
    private(set) var firstSourceSeconds: Double?
    private(set) var lastSourceSeconds: Double?
    private(set) var sourceRegressions = 0
    private(set) var sourceGaps = 0
    private(set) var clampCount = 0
    private(set) var correctionCount = 0
    private(set) var lastDiscontinuitySeconds: Double?
    private(set) var maxSourceGapSeconds: Double = 0
    private(set) var lastRetimingSeconds: Double = 0
    private(set) var lastEffectiveSeconds: Double = 0
    private(set) var lastSourceStepSeconds: Double = 0
    private(set) var lastGeneratedDeltaSeconds: Double = 0
    private(set) var generatedSeconds: Double = 0

    /// 記錄呼叫端原始時間與修正後時間；不參與時間戳決策。
    /// - Parameters:
    ///   source: 呼叫端未補償的來源秒數。
    ///   effective: 實際交給時間戳演算法的秒數。
    ///   delta: 本次產生的 RTMP delta（秒）。
    ///   generated: RTMP delta 累計秒數。
    ///   clamped: 是否以舊 delta 取代異常跳變。
    ///   corrected: 是否套用 preferredDelta 的漂移修正或跳轉。
    mutating func record(source: Double, effective: Double, delta: Double,
                         generated: Double, clamped: Bool, corrected: Bool) {
        if let previous = lastSourceSeconds {
            let step = source - previous
            lastSourceStepSeconds = step
            maxSourceGapSeconds = max(maxSourceGapSeconds, step)
            if step < 0 {
                sourceRegressions += 1
                lastDiscontinuitySeconds = source
            }
            if step > 2 {
                sourceGaps += 1
                lastDiscontinuitySeconds = source
            }
        } else {
            firstSourceSeconds = source
        }
        lastSourceSeconds = source
        lastRetimingSeconds = effective - source
        lastEffectiveSeconds = effective
        lastGeneratedDeltaSeconds = delta
        generatedSeconds = generated
        if clamped { clampCount += 1 }
        if corrected { correctionCount += 1 }
    }

    /// 原始來源經過時間減去產生的 RTMP 時間；正值表示輸出時間較短。
    var sourceMinusGeneratedSeconds: Double? {
        guard let firstSourceSeconds, let lastSourceSeconds else { return nil }
        return lastSourceSeconds - firstSourceSeconds - generatedSeconds
    }

    /// 供既有低頻診斷日誌使用；未收到樣本的欄位明確顯示 unknown。
    var logDescription: String {
        func number(_ value: Double?) -> String {
            value.map { String(format: "%.6f", $0) } ?? "unknown"
        }
        return "sourceStart=\(number(firstSourceSeconds)) sourceLast=\(number(lastSourceSeconds)) effective=\(number(lastSourceSeconds == nil ? nil : lastEffectiveSeconds)) generated=\(number(generatedSeconds)) sourceMinusGenerated=\(number(sourceMinusGeneratedSeconds)) retime=\(number(lastRetimingSeconds)) sourceStep=\(number(lastSourceStepSeconds)) generatedDelta=\(number(lastGeneratedDeltaSeconds)) regress=\(sourceRegressions) gapsOver2s=\(sourceGaps) maxGap=\(number(maxSourceGapSeconds)) clamps=\(clampCount) corrections=\(correctionCount) lastDiscontinuity=\(number(lastDiscontinuitySeconds))"
    }
}

struct RTMPTimestamp<T: RTMPTimeConvertible> {
    private(set) var diagnostics = RTMPTimestampDiagnostics()
    private var startedAt = kRTMPTimestamp_defaultTimeInterval
    private(set) var updatedAt = kRTMPTimestamp_defaultTimeInterval
    private var timedeltaFraction: TimeInterval = kRTMPTimestamp_defaultTimeInterval
    private var lastRawTimestamp: UInt32 = 0
    private var rolloverCount: UInt64 = 0
    private var lastDelta: TimeInterval = 0
    // 上一次「正常」的 delta（ms），基準跳變時用它維持 wire 平滑。
    private var lastNormalDelta: TimeInterval = 0
    // Sum of every delta actually sent on the wire (seconds). Only ever moves
    // forward, so it stays valid across camera PTS base shifts ("invalid
    // sequence" resets) — that is what a sequence header must carry: the real
    // wire-cumulative position, not the camera-relative PTS and not 0.
    private(set) var cumulativeTime: TimeInterval = kRTMPTimestamp_defaultTimeInterval

    /// 產生 RTMP 毫秒差值。影片可保留真實向前間隔，避免缺幀期間被從時間軸刪除。
    /// - Parameters:
    ///   - value: 封裝使用的媒體時間，單位秒。
    ///   - source: 警告日誌的來源名稱。
    ///   - allowJump: 允許音訊節奏修正直接追上大幅向前漂移。
    ///   - preferredDelta: 壓縮音訊封包的標稱時長；nil 使用來源差值。
    ///   - originalSeconds: 補償前時間，僅供診斷。
    ///   - preserveForwardGaps: 保留有限且可表示的向前間隔；不把長間隔當作時鐘重設。
    /// - Returns: 本次毫秒差值；無法表示的時間回傳零並保留原基準，另記錄警告。
    mutating func update(_ value: T, source: String = "", allowJump: Bool = false, preferredDelta: TimeInterval? = nil, originalSeconds: TimeInterval? = nil, preserveForwardGaps: Bool = false) -> UInt32 {
        guard value.seconds.isFinite else {
            logger.warn("RTMPTimestamp invalid: \(source) non-finite source")
            return 0
        }
        if startedAt == 0 {
            startedAt = value.seconds
            updatedAt = value.seconds
            lastNormalDelta = 0
            diagnostics.record(source: originalSeconds ?? value.seconds, effective: value.seconds, delta: 0, generated: cumulativeTime, clamped: false, corrected: false)
            return 0
        }
        let sourceTimedelta = (value.seconds - updatedAt) * 1000
        if preserveForwardGaps && (!sourceTimedelta.isFinite || sourceTimedelta > Double(UInt32.max) - 1) {
            logger.warn("RTMPTimestamp invalid: \(source) delta outside RTMP range")
            return 0
        }
        var timedelta = sourceTimedelta
        var clamped = false
        var corrected = false
        // 基準跳變 clamp：RTMP type-1/type-2 的 timestamp 是「相對 delta 累積」
        // 而非絕對值，下游的絕對時間 = 所有 delta 的累積和。因此：
        //  - 倒退（delta < 0）：clamp 到 0（視為同刻），不重置基準
        //  - 向前大跳（delta > maxDelta，如 13000→15000 產生 2000 秒）：用
        //    上一次正常 delta 維持平滑，避免巨大 timestamp 跳變讓下游誤判為
        //    gap/seek → 畫面凍結、音訊中斷、AV 自動修正（斷流）
        // 影片指定 preserveForwardGaps，跳過向前截限以保留真實停頓；
        // 其他呼叫仍保留相容策略，診斷記錄來源與累計差距。
        // allowJump（僅音訊 A/V resync 用）：允許一次向前大跳，讓落後到 video
        // 之後的音訊時間軸直接跳進同步範圍，而非以 2000ms 上限慢慢追。
        let usesPreferredDelta = preferredDelta != nil
        if let preferredDelta {
            let preferredTimedelta = preferredDelta * 1000
            let drift = sourceTimedelta - preferredTimedelta
            // Compressed audio packets carry a stable media duration, but the
            // source PTS still carries real gap/drift information. Keep small
            // capture jitter off the wire, then gently correct sustained drift
            // so the RTMP timeline does not fork away from the original clock.
            if allowJump && kRTMPTimestamp_preferredDeltaJumpThreshold < drift {
                corrected = true
                timedelta = sourceTimedelta
            } else if kRTMPTimestamp_preferredDeltaDriftTolerance < abs(drift) {
                corrected = true
                let correction = max(
                    -kRTMPTimestamp_preferredDeltaMaxCorrection,
                    min(kRTMPTimestamp_preferredDeltaMaxCorrection, drift * kRTMPTimestamp_preferredDeltaCorrectionRatio)
                )
                timedelta = max(0, preferredTimedelta + correction)
            } else {
                timedelta = preferredTimedelta
            }
        }
        if timedelta < 0 {
            logger.warn("RTMPTimestamp jump: \(source) new=\(value.seconds) last=\(updatedAt) delta=\(timedelta)ms")
            clamped = true
            timedelta = lastNormalDelta
        } else if timedelta > kRTMPTimestamp_maxDelta, !allowJump, !preserveForwardGaps {
            logger.warn("RTMPTimestamp jump: \(source) new=\(value.seconds) last=\(updatedAt) delta=\(timedelta)ms")
            clamped = true
            timedelta = lastNormalDelta
        }
        timedeltaFraction += timedelta.truncatingRemainder(dividingBy: 1)
        if 1 <= timedeltaFraction {
            timedeltaFraction -= 1
            timedelta += 1
        }
        let wireTimedelta = TimeInterval(UInt32(timedelta))
        if usesPreferredDelta {
            updatedAt += wireTimedelta / 1000
        } else {
            updatedAt = value.seconds
        }
        cumulativeTime += wireTimedelta / 1000
        lastNormalDelta = wireTimedelta
        diagnostics.record(source: originalSeconds ?? value.seconds, effective: value.seconds, delta: wireTimedelta / 1000, generated: cumulativeTime, clamped: clamped, corrected: corrected)
        return UInt32(wireTimedelta)
    }

    mutating func update(_ message: some RTMPMessage, chunkType: RTMPChunkType) {
        switch chunkType {
        case .zero:
            let rawTimestamp = message.timestamp
            if startedAt == 0 {
                startedAt = TimeInterval(rawTimestamp) / 1000
                updatedAt = TimeInterval(rawTimestamp) / 1000
                lastRawTimestamp = rawTimestamp
                lastDelta = 0
            } else {
                // Detect 32-bit unsigned rollover
                if rawTimestamp < lastRawTimestamp && (lastRawTimestamp - rawTimestamp) > 0x80000000 {
                    rolloverCount += 1
                } else if rawTimestamp > lastRawTimestamp && (rawTimestamp - lastRawTimestamp) > 0x80000000 {
                    // Prevent negative rollover if packets arrive slightly out of order near boundary
                    if rolloverCount > 0 {
                        rolloverCount -= 1
                    }
                }
                
                let continuousTimestamp = UInt64(rawTimestamp) + (rolloverCount << 32)
                let previousUpdatedAt = updatedAt
                updatedAt = TimeInterval(continuousTimestamp) / 1000
                
                // For Type 0, calculate the delta relative to the previous timestamp
                if updatedAt > previousUpdatedAt {
                    lastDelta = updatedAt - previousUpdatedAt
                } else {
                    lastDelta = 0
                }
                lastRawTimestamp = rawTimestamp
            }
        case .one, .two:
            lastDelta = TimeInterval(message.timestamp) / 1000
            updatedAt += lastDelta
        case .three:
            updatedAt += lastDelta
        }
    }

    mutating func clear() {
        diagnostics = RTMPTimestampDiagnostics()
        startedAt = kRTMPTimestamp_defaultTimeInterval
        updatedAt = kRTMPTimestamp_defaultTimeInterval
        timedeltaFraction = kRTMPTimestamp_defaultTimeInterval
        lastRawTimestamp = 0
        rolloverCount = 0
        lastDelta = 0
        lastNormalDelta = 0
        cumulativeTime = kRTMPTimestamp_defaultTimeInterval
    }
}

extension AVAudioTime: RTMPTimeConvertible {
    var seconds: TimeInterval {
        AVAudioTime.seconds(forHostTime: hostTime)
    }
}

extension RTMPTimestamp where T == AVAudioTime {
    var value: AVAudioTime {
        return AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: updatedAt))
    }
}

extension CMTime: RTMPTimeConvertible {
}

extension RTMPTimestamp where T == CMTime {
    var value: CMTime {
        return CMTime(seconds: updatedAt, preferredTimescale: 1000)
    }
}
