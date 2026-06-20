import AVFoundation
import CoreMedia
import Foundation

protocol RTMPTimeConvertible {
    var seconds: TimeInterval { get }
}

private let kRTMPTimestamp_defaultTimeInterval: TimeInterval = 0

struct RTMPTimestamp<T: RTMPTimeConvertible> {
    enum Error: Swift.Error {
        case invalidSequence
    }

    private var startedAt = kRTMPTimestamp_defaultTimeInterval
    private var updatedAt = kRTMPTimestamp_defaultTimeInterval
    private var timedeltaFraction: TimeInterval = kRTMPTimestamp_defaultTimeInterval
    private var lastRawTimestamp: UInt32 = 0
    private var rolloverCount: UInt64 = 0
    private var lastDelta: TimeInterval = 0

    mutating func update(_ value: T) throws -> UInt32 {
        guard updatedAt < value.seconds else {
            throw Error.invalidSequence
        }
        if startedAt == 0 {
            startedAt = value.seconds
            updatedAt = value.seconds
            return 0
        }
        var timedelta = (value.seconds - updatedAt) * 1000
        timedeltaFraction += timedelta.truncatingRemainder(dividingBy: 1)
        if 1 <= timedeltaFraction {
            timedeltaFraction -= 1
            timedelta += 1
        }
        updatedAt = value.seconds
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
