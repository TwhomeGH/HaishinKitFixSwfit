import AVFoundation
import CoreMedia
import Foundation

protocol RTMPTimeConvertible {
    var seconds: TimeInterval { get }
}

private let kRTMPTimestamp_defaultTimeInterval: TimeInterval = 0

struct RTMPTimestamp<T: RTMPTimeConvertible> {
    /// 單一 delta 的上限（ms）。超過視為基準跳變（向前大跳），用上一次
    /// 正常 delta 取代，避免巨大 timestamp 上 wire 造成下游斷流。
    /// 2 秒涵蓋最低幀率（0.5fps idle），正常直播幀間距 < 100ms。
    private static let maxDelta: TimeInterval = 2000
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

    mutating func update(_ value: T, source: String = "") -> UInt32 {
        if startedAt == 0 {
            startedAt = value.seconds
            updatedAt = value.seconds
            lastNormalDelta = 0
            return 0
        }
        var timedelta = (value.seconds - updatedAt) * 1000
        // 基準跳變 clamp：RTMP type-1/type-2 的 timestamp 是「相對 delta 累積」
        // 而非絕對值，下游的絕對時間 = 所有 delta 的累積和。因此：
        //  - 倒退（delta < 0）：clamp 到 0（視為同刻），不重置基準
        //  - 向前大跳（delta > maxDelta，如 13000→15000 產生 2000 秒）：用
        //    上一次正常 delta 維持平滑，避免巨大 timestamp 跳變讓下游誤判為
        //    gap/seek → 畫面凍結、音訊中斷、AV 自動修正（斷流）
        // 這樣基準跳變時 wire 時間戳仍單調連續，下游完全察覺不到跳變。
        if timedelta < 0 || timedelta > Self.maxDelta {
            logger.warn("RTMPTimestamp jump: \(source) new=\(value.seconds) last=\(updatedAt) delta=\(timedelta)ms")
            timedelta = lastNormalDelta
        }
        timedeltaFraction += timedelta.truncatingRemainder(dividingBy: 1)
        if 1 <= timedeltaFraction {
            timedeltaFraction -= 1
            timedelta += 1
        }
        updatedAt = value.seconds
        cumulativeTime += timedelta / 1000
        lastNormalDelta = timedelta
        return UInt32(timedelta)
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
