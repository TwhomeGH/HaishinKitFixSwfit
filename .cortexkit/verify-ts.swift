// Verify RTMPTimestamp.update preferredDelta behavior (pure math, mirrors RTMPTimestamp.swift)
import Foundation

struct Ts {
    var startedAt: Double = 0
    var updatedAt: Double = 0
    var timedeltaFraction: Double = 0
    var lastNormalDelta: Double = 0
    var cumulative: Double = 0
    let kMaxDelta: Double = 2000

    mutating func update(_ seconds: Double, allowJump: Bool = false, preferredDelta: Double? = nil) -> UInt32 {
        if startedAt == 0 {
            startedAt = seconds
            updatedAt = seconds
            lastNormalDelta = 0
            return 0
        }
        let sourceTimedelta = (seconds - updatedAt) * 1000
        var timedelta = sourceTimedelta
        let usesPreferred = preferredDelta != nil
        if let preferredDelta {
            let preferredTimedelta = preferredDelta * 1000
            if allowJump && preferredTimedelta + 500 < sourceTimedelta {
                timedelta = sourceTimedelta
            } else {
                timedelta = preferredTimedelta
            }
        }
        if timedelta < 0 {
            timedelta = lastNormalDelta
        } else if timedelta > kMaxDelta, !allowJump {
            timedelta = lastNormalDelta
        }
        timedeltaFraction += timedelta.truncatingRemainder(dividingBy: 1)
        if 1 <= timedeltaFraction {
            timedeltaFraction -= 1
            timedelta += 1
        }
        let wire = TimeInterval(UInt32(timedelta))
        if usesPreferred {
            updatedAt += wire / 1000
        } else {
            updatedAt = seconds
        }
        cumulative += wire / 1000
        lastNormalDelta = wire
        return UInt32(wire)
    }
}

// Scenario 1: preferredDelta = 21.33ms (AAC 1024 @ 48k), source jittery 20/37 cadence.
// Expected: wire must stay 21/21/22 regardless of source jitter.
var t = Ts()
var source: Double = 0
let wire1 = (0..<30).map { i -> UInt32 in
    // source cadence mimics observed: 20,20,37 repeating
    let cadence = [0.020, 0.020, 0.037][i % 3]
    source += cadence
    return t.update(source, allowJump: true, preferredDelta: 0.0213333)
}
print("preferredDelta path wire deltas:", wire1.map { "\($0)" }.joined(separator: ","))
let expected1: [UInt32] = [0,21,21,22,21,21,22,21,21,22,21,21,22]
let ok1 = Array(wire1.prefix(13)) == expected1
print("  matches 21/21/22:", ok1)

// Scenario 2: preferredDelta nil (old build / packetDuration nil) -> wire follows SOURCE.
var t2 = Ts()
var source2: Double = 0
let wire2 = (0..<30).map { i -> UInt32 in
    let cadence = [0.020, 0.020, 0.037][i % 3]
    source2 += cadence
    return t2.update(source2, allowJump: true, preferredDelta: nil)
}
print("source-time path wire deltas:", wire2.map { "\($0)" }.joined(separator: ","))
print("  observed-20/37 signature:", Array(wire2.prefix(7)) == [0,20,20,37,20,20,37])
print("  mean wire (source path):", Double(wire2.dropFirst().reduce(0){$0+Int($1)}) / Double(wire2.count-1), "ms/pkt")

exit(ok1 ? 0 : 1)
