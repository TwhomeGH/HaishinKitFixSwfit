// Standalone verification of AudioRingBuffer.align(to:) logic
// (pure integer mirror of AudioRingBuffer.swift — no AVFoundation needed)
import Foundation

final class RB {
    var head = 0
    var tail = 0
    var skip = 0
    var sampleTime: Int64 = 0
    let capacity: Int
    private(set) var data: [Int16] // sample values for content verification

    init(capacity: Int) {
        self.capacity = capacity
        self.data = [Int16](repeating: 0, count: capacity)
    }

    func counts() -> Int {
        if tail <= head { return head - tail + skip }
        return capacity - tail + head + skip
    }
    func frontier() -> Int64 { sampleTime - Int64(counts()) }

    // mirror append(_ audioPCMBuffer:when:) — frames of constant fill value
    func append(sampleTime when: Int64, frames: Int, fill: Int16) {
        if sampleTime == 0 { sampleTime = when }
        let gap = max(when - sampleTime, 0)
        skip += Int(gap)
        sampleTime += gap
        var offset = 0
        while offset < frames {
            let n = min(frames - offset, capacity - head)
            guard n > 0 else { return } // full: drop remainder
            for i in 0..<n { data[head + i] = fill }
            head = (head + n) % capacity
            sampleTime += Int64(n)
            offset += n
        }
    }

    // mirror render() — returns the values emitted for `n` frames (skip = 0-fill)
    func render(_ n: Int) -> [Int16] {
        var out: [Int16] = []
        out.reserveCapacity(n)
        var remain = n
        if skip > 0 {
            let s = min(skip, remain)
            out.append(contentsOf: [Int16](repeating: 0, count: s))
            skip -= s
            remain -= s
        }
        while remain > 0 {
            guard head != tail else { out.append(contentsOf: [Int16](repeating: 0, count: remain)); remain = 0; break }
            let num = min(remain, capacity - tail)
            out.append(contentsOf: data[tail..<tail + num])
            tail = (tail + num) % capacity
            remain -= num
        }
        return out
    }

    // mirror align(to:)
    func align(to position: Int64) -> (dropped: Int64, inserted: Int64) {
        let current = sampleTime - Int64(counts())
        if current < position {
            let stale = position - current
            var toDrop = min(stale, Int64(counts()))
            let skipToDrop = min(Int64(skip), toDrop)
            skip -= Int(skipToDrop)
            toDrop -= skipToDrop
            while 0 < toDrop {
                let n = min(Int(toDrop), capacity - tail)
                tail = (tail + n) % capacity
                toDrop -= Int64(n)
            }
            return (stale, 0)
        } else if position < current {
            let lead = current - position
            skip += Int(lead)
            return (0, lead)
        }
        return (0, 0)
    }
}

var failures = 0
func expect(_ cond: Bool, _ name: String) {
    if cond { print("  ✓ \(name)") } else { failures += 1; print("  ✗ \(name)") }
}

print("== Scenario 1: app leads (data at 1024), align to 0 -> silence then data ==")
do {
    let rb = RB(capacity: 3 * 1024)
    rb.append(sampleTime: 1024, frames: 1024, fill: 7)
    let a = rb.align(to: 0)
    expect(a.inserted == 1024, "inserted 1024 silence, frontier=\(rb.frontier())")
    expect(rb.frontier() == 0, "frontier aligned to 0")
    expect(rb.counts() == 2048, "counts = 1024 silence + 1024 data")
    let first = rb.render(1024)
    expect(first.allSatisfy { $0 == 0 }, "first 1024 are silence")
    let second = rb.render(1024)
    expect(second.allSatisfy { $0 == 7 }, "next 1024 are the data")
}

print("== Scenario 2: app behind (data 0..2048), align to 1024 -> stale dropped ==")
do {
    let rb = RB(capacity: 3 * 1024)
    rb.append(sampleTime: 0, frames: 1024, fill: 3)
    rb.append(sampleTime: 1024, frames: 1024, fill: 9)
    let a = rb.align(to: 1024)
    expect(a.dropped == 1024, "dropped 1024 stale, frontier=\(rb.frontier())")
    expect(rb.frontier() == 1024, "frontier aligned to 1024")
    expect(rb.counts() == 1024, "counts = 1024")
    let out = rb.render(1024)
    expect(out.allSatisfy { $0 == 9 }, "remaining data is the second frame")
    expect(rb.counts() == 0, "buffer drained")
}

print("== Scenario 3: align past end -> buffer emptied ==")
do {
    let rb = RB(capacity: 3 * 1024)
    rb.append(sampleTime: 0, frames: 1024, fill: 3)
    rb.append(sampleTime: 1024, frames: 1024, fill: 9)
    rb.align(to: 4096)
    expect(rb.counts() == 0, "buffer emptied")
}

print("== Scenario 4: leading silence adjusted ==")
do {
    let rb = RB(capacity: 3 * 1024)
    rb.append(sampleTime: 1024, frames: 1024, fill: 7)
    rb.align(to: 0)
    expect(rb.counts() == 2048, "1024 silence + 1024 data")
    rb.align(to: 512)
    expect(rb.counts() == 1536, "silence reduced to 512")
    let out = rb.render(512)
    expect(out.allSatisfy { $0 == 0 }, "512 silence emitted")
}

print("== Scenario 5: two-track interleaved (ReplayKit shared clock) ==")
// Main (mic) frames at 0,1024,...; app frames at 1024,2048,... (app starts 1 frame late).
// After the startup transient, app frontier must stay locked to the main clock.
do {
    let app = RB(capacity: 24 * 1024)
    var mainClock: Int64 = 0
    var firstBlockSilent = false
    var steadyLocked = true
    var blocks = 0
    // delivery order: app delivers one frame first, then mic/main starts
    app.append(sampleTime: 1024, frames: 1024, fill: 5)
    mainClock = 0
    var mainNext = 0
    for i in 0..<16 {
        // main produces frame [mainNext, mainNext+1024)
        let blockStart = mainClock
        // app may have delivered frames ahead of the current block
        if i == 0 {
            // app delivered only frame at 1024 so far
        } else {
            // app delivers its next frame aligned to the block
            app.append(sampleTime: Int64(blockStart) + 1024, frames: 1024, fill: 5)
        }
        let adj = app.align(to: blockStart)
        if i == 0 {
            expect(adj.inserted == 1024, "block 0: app silent for first frame (inserted 1024)")
            firstBlockSilent = true
        } else if adj.dropped != 0 || adj.inserted != 0 {
            steadyLocked = false
            print("    block \(i): unexpected adjust dropped=\(adj.dropped) inserted=\(adj.inserted)")
        }
        let emitted = app.render(1024)
        if i > 0 && emitted.contains(0) {
            steadyLocked = false
            print("    block \(i): app emitted silence in steady state")
        }
        mainClock += 1024
        mainNext += 1024
        blocks += 1
    }
    expect(firstBlockSilent, "startup transient handled by silence insertion")
    expect(steadyLocked, "app stays locked to main clock in steady state (no drops/silence)")
    _ = blocks
}

print("== Scenario 6: re-setup re-align (mix clock restarts at 8192) ==")
do {
    // app 在重設前累積了 [0, 4096) 的舊幀；mix clock 因 re-setup 重置後
    // 首個 main frame 落在 8192。align 要丟掉過期的舊幀並重新鎖定。
    let app = RB(capacity: 24 * 1024)
    for k in 0..<4 { app.append(sampleTime: Int64(k * 1024), frames: 1024, fill: Int16(1 + k)) }
    expect(app.frontier() == 0, "app frontier at 0 before re-align")
    let adj = app.align(to: 8192)
    expect(adj.dropped >= 4096, "stale pre-setup frames dropped (\(adj.dropped))")
    expect(app.counts() == 0, "buffer emptied after drop")
    // app 生產新幀於 8192（前方以 skip 覆蓋 [4096, 8192) 的間隙）
    app.append(sampleTime: 8192, frames: 1024, fill: 42)
    expect(app.counts() == 5120, "4096 gap silence + 1024 data")
    app.align(to: 8192) // 第二次 align 越過 gap silence
    expect(app.frontier() == 8192, "app frontier locked to restarted mix clock")
    let out = app.render(1024)
    expect(out.allSatisfy { $0 == 42 }, "fresh frame emitted at aligned position")
}

print("== Scenario 7: main stalls, app keeps producing (frontier stays locked) ==")
do {
    // main 停滯期間 app 持續生產：mix clock 凍結在 1024，app frontier 也鎖在
    // 1024（frontier 只隨 render 推進）。main 恢復後不需任何調整即可繼續對齊。
    let app = RB(capacity: 24 * 1024)
    var mainClock: Int64 = 0
    app.append(sampleTime: 0, frames: 1024, fill: 1)
    app.align(to: 0)
    let b0 = app.render(1024)
    expect(b0.allSatisfy { $0 == 1 }, "block 0 aligned")
    mainClock = 1024
    for k in 1...8 { app.append(sampleTime: Int64(k * 1024), frames: 1024, fill: Int16(10 + k)) }
    let adj = app.align(to: mainClock)
    expect(adj.dropped == 0 && adj.inserted == 0, "no adjustment needed (frontier locked)")
    let resumed = app.render(1024)
    expect(resumed.allSatisfy { $0 == 11 }, "app emits its frame for position [1024,2048)")
    expect(app.frontier() == 2048, "frontier advances with mix clock")
}

print("")
if failures == 0 {
    print("ALL ALIGN SCENARIOS PASSED")
} else {
    print("\(failures) FAILURES")
    exit(1)
}
