// Verification of the mix-clock advance logic in AudioMixerByMultiTrack:
// - main-track-driven, with a "main silent → other track advances" fallback.
// - must NOT drop the mic content when both tracks produce (app-first ordering).
import Foundation

final class RB {
    var head = 0, tail = 0, skip = 0
    var sampleTime: Int64 = 0
    let capacity: Int
    var data: [Int16]

    init(capacity: Int) { self.capacity = capacity; self.data = [Int16](repeating: 0, count: capacity) }
    func counts() -> Int { tail <= head ? head - tail + skip : capacity - tail + head + skip }
    func frontier() -> Int64 { sampleTime - Int64(counts()) }

    func append(sampleTime when: Int64, frames: Int, fill: Int16) {
        if sampleTime == 0 { sampleTime = when }
        let gap = max(when - sampleTime, 0)
        skip += Int(gap); sampleTime += gap
        var offset = 0
        while offset < frames {
            let n = min(frames - offset, capacity - head)
            guard n > 0 else { return }
            for i in 0..<n { data[head + i] = fill }
            head = (head + n) % capacity; sampleTime += Int64(n); offset += n
        }
    }

    func render(_ n: Int) -> [Int16] {
        var out: [Int16] = []; out.reserveCapacity(n); var remain = n
        if skip > 0 { let s = min(skip, remain); out.append(contentsOf: [Int16](repeating: 0, count: s)); skip -= s; remain -= s }
        while remain > 0 {
            guard head != tail else { out.append(contentsOf: [Int16](repeating: 0, count: remain)); remain = 0; break }
            let num = min(remain, capacity - tail)
            out.append(contentsOf: data[tail..<tail + num]); tail = (tail + num) % capacity; remain -= num
        }
        return out
    }

    func align(to position: Int64) {
        let current = sampleTime - Int64(counts())
        if current < position {
            var toDrop = min(position - current, Int64(counts()))
            let skipToDrop = min(Int64(skip), toDrop); skip -= Int(skipToDrop); toDrop -= skipToDrop
            while 0 < toDrop { let n = min(Int(toDrop), capacity - tail); tail = (tail + n) % capacity; toDrop -= Int64(n) }
        } else if position < current {
            skip += Int(current - position)
        }
    }
}

var failures = 0
func expect(_ cond: Bool, _ name: String) {
    if cond { print("  ✓ \(name)") } else { failures += 1; print("  ✗ \(name)") }
}

// mixer model
final class MixerSim {
    let appBuffer = RB(capacity: 24 * 1024)
    let micBuffer = RB(capacity: 24 * 1024)
    let mainTrack: UInt8
    let appTrack: UInt8
    let micTrack: UInt8
    var sampleTime: Int64 = 0
    var lastOutput: [UInt8: Int64] = [:]
    // 記錄每個 block 各自軌的輸出 fill（-1 = 沒輸出到資料）
    var blockLog: [(app: Int, mic: Int)] = []

    init(mainTrack: UInt8, appTrack: UInt8, micTrack: UInt8) {
        self.mainTrack = mainTrack; self.appTrack = appTrack; self.micTrack = micTrack
    }

    func trackOutput(track: UInt8, position: Int64, fill: Int16) {
        let buffer = track == micTrack ? micBuffer : appBuffer
        buffer.append(sampleTime: position, frames: 1024, fill: fill)
        lastOutput[track] = position + 1024
        if track == mainTrack {
            advanceMix(to: position)
        } else if let mainLast = lastOutput[mainTrack] {
            if mainLast < position { advanceMix(to: position) }
        } else {
            advanceMix(to: position)
        }
    }

    func advanceMix(to position: Int64) {
        let end = position + 1024
        if sampleTime == 0 { sampleTime = position }
        guard end > sampleTime else { return }
        while sampleTime < end {
            let frames = min(1024, Int(end - sampleTime))
            mix(numberOfFrames: frames)
        }
    }

    func mix(numberOfFrames: Int) {
        appBuffer.align(to: sampleTime)
        micBuffer.align(to: sampleTime)
        let a = appBuffer.render(numberOfFrames)
        let m = micBuffer.render(numberOfFrames)
        let appFill = a.first(where: { $0 != 0 }) ?? 0
        let micFill = m.first(where: { $0 != 0 }) ?? 0
        blockLog.append((app: Int(appFill), mic: Int(micFill)))
        sampleTime += Int64(numberOfFrames)
    }
}

print("== 情境 A：正規接線 main=mic=0、app=1，app 先到 ==")
do {
    let sim = MixerSim(mainTrack: 0, appTrack: 1, micTrack: 0)
    for block in 0..<6 {
        let p = Int64(block * 1024)
        sim.trackOutput(track: 1, position: p, fill: 5)   // app 先到
        sim.trackOutput(track: 0, position: p, fill: 9)   // mic 後到（main）
    }
    let blocks = sim.blockLog
    expect(blocks.count == 6, "rendered exactly 6 blocks (no double-mix), got \(blocks.count)")
    expect(blocks[1].mic == 9, "block 1 mic content included (not dropped)")
    expect(blocks[1].app == 5, "block 1 app content included")
    expect(blocks[2].mic == 9 && blocks[2].app == 5, "block 2 both included")
    expect(blocks[3].mic == 9 && blocks[3].app == 5, "block 3 both included")
    expect(blocks[4].mic == 9 && blocks[4].app == 5, "block 4 both included")
}

print("== 情境 B：使用者接線 main=app=0、mic=1，app 完全沒有在播放 ==")
do {
    let sim = MixerSim(mainTrack: 0, appTrack: 0, micTrack: 1)
    for block in 0..<6 {
        sim.trackOutput(track: 1, position: Int64(block * 1024), fill: 9)  // 只有 mic
    }
    let blocks = sim.blockLog
    expect(blocks.count == 6, "mix advanced via mic even though app(main) never produced (no stall), got \(blocks.count) blocks")
    expect(blocks.allSatisfy { $0.mic == 9 }, "mic content flows every block")
}

print("== 情境 C：正規接線 main=mic=0、app=1，app 播放→靜默→再播放 ==")
do {
    let sim = MixerSim(mainTrack: 0, appTrack: 1, micTrack: 0)
    var appFills: [Int: Int16] = [0: 5, 1: 5, 4: 6, 5: 6]  // blocks 2-3 app 靜默
    for block in 0..<6 {
        let p = Int64(block * 1024)
        if let f = appFills[block] { sim.trackOutput(track: 1, position: p, fill: f) }  // app 先到
        sim.trackOutput(track: 0, position: p, fill: 9)                                  // mic（main）驅動
    }
    let blocks = sim.blockLog
    expect(blocks.count == 6, "no stall across app silence, got \(blocks.count) blocks")
    // block 0 允許是 startup 邊緣（app 先到、mic 首幀未到）；之後 mic 必須全程在。
    expect(blocks[1...5].allSatisfy { $0.mic == 9 }, "mic flows in every steady-state block (never dropped)")
    expect(blocks[0].app == 5 && blocks[1].app == 5, "app content included while playing")
    expect(blocks[2].app == 0 && blocks[3].app == 0, "app silent blocks contribute silence")
    expect(blocks[4].app == 6 && blocks[5].app == 6, "app content resumes after silence")
}

print("== 情境 D：正規接線，app 靜默（mic 持續）==")
do {
    let sim = MixerSim(mainTrack: 0, appTrack: 1, micTrack: 0)
    for block in 0..<6 {
        sim.trackOutput(track: 0, position: Int64(block * 1024), fill: 9)  // 只有 mic（main）
    }
    let blocks = sim.blockLog
    expect(blocks.count == 6, "mic-only stream advances normally, got \(blocks.count)")
    expect(blocks.allSatisfy { $0.mic == 9 && $0.app == 0 }, "mic flows, app silence")
}

print("")
if failures == 0 { print("ALL MIX-CLOCK SCENARIOS PASSED") } else { print("\(failures) FAILURES"); exit(1) }
