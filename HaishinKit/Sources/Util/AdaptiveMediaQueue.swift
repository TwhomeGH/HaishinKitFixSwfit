import Foundation

/// Single-consumer raw-media queue. Limits cover retained queue storage, not codec/GPU memory.
package final class AdaptiveMediaQueue<Element: Sendable>: @unchecked Sendable {
    private struct Entry {
        let value: Element
        let bytes: Int
        let time: TimeInterval
    }

    private let lock = NSLock()
    private let clock: @Sendable () -> TimeInterval
    private var entries: [Entry] = []
    private var bytes = 0
    private var byteLimit: Int
    private var ageLimit: TimeInterval
    private var frameLimit: Int?
    private var closed = false
    private var waiter: CheckedContinuation<Element?, Never>?
    private var received = 0
    private var consumed = 0
    private var capacityDrops = 0
    private var expiredDrops = 0
    private var oversizedDrops = 0
    private var closedDrops = 0
    private var shutdownDrops = 0
    private var highWaterBytes = 0
    private var lastInput: TimeInterval?
    private var lastOutput: TimeInterval?
    private var maxWait: TimeInterval = 0
    private let diagnosticID = UUID()

    package init(maxBytes: Int, maxAge: TimeInterval = 0.1, maxFrames: Int? = nil,
                 clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        byteLimit = max(0, maxBytes)
        ageLimit = maxAge.isFinite ? max(0, maxAge) : 0.1
        frameLimit = maxFrames.map { max(1, $0) }
        self.clock = clock
    }

    package func stream() -> AsyncStream<Element> {
        AsyncStream(unfolding: { await self.next() }, onCancel: { self.finish() })
    }

    package func update(maxBytes: Int, maxAge: TimeInterval = 0.1, maxFrames: Int? = nil) {
        lock.lock()
        defer { lock.unlock() }
        byteLimit = max(0, maxBytes)
        ageLimit = maxAge.isFinite ? max(0, maxAge) : 0.1
        frameLimit = maxFrames.map { max(1, $0) }
        trim(now: clock())
    }

    package func offer(_ value: Element, bytes size: Int) {
        let size = max(1, size)
        lock.lock()
        received += 1
        let now = clock()
        lastInput = now
        guard !closed else {
            closedDrops += 1
            lock.unlock()
            return
        }
        trim(now: now)
        guard size <= byteLimit else {
            oversizedDrops += 1
            lock.unlock()
            return
        }
        if let waiting = waiter {
            waiter = nil
            consumed += 1
            lastOutput = now
            lock.unlock()
            waiting.resume(returning: value)
            return
        }
        // Evict before adding, so retained bytes never exceed the configured budget.
        while !entries.isEmpty && (bytes > byteLimit - size ||
              frameLimit.map { entries.count >= $0 } == true) {
            bytes -= entries.removeFirst().bytes
            capacityDrops += 1
        }
        entries.append(Entry(value: value, bytes: size, time: now))
        bytes += size
        highWaterBytes = max(highWaterBytes, bytes)
        lock.unlock()
    }

    private func next() async -> Element? {
        await withCheckedContinuation { continuation in
            lock.lock()
            let now = clock()
            trim(now: now)
            if !entries.isEmpty {
                let entry = entries.removeFirst()
                bytes -= entry.bytes
                consumed += 1
                lastOutput = now
                maxWait = max(maxWait, now - entry.time)
                lock.unlock()
                continuation.resume(returning: entry.value)
            } else if closed {
                lock.unlock()
                continuation.resume(returning: nil)
            } else {
                // One iterator owns each queue. Do not silently overwrite a waiting reader.
                precondition(waiter == nil, "AdaptiveMediaQueue requires a single consumer")
                waiter = continuation
                lock.unlock()
            }
        }
    }

    private func trim(now: TimeInterval) {
        while let first = entries.first, now - first.time > ageLimit {
            bytes -= entries.removeFirst().bytes
            expiredDrops += 1
        }
        while !entries.isEmpty && (bytes > byteLimit ||
              frameLimit.map { entries.count > $0 } == true) {
            bytes -= entries.removeFirst().bytes
            capacityDrops += 1
        }
    }

    package func finish() {
        lock.lock()
        closed = true
        shutdownDrops += entries.count
        entries.removeAll()
        bytes = 0
        let waiting = waiter
        waiter = nil
        lock.unlock()
        waiting?.resume(returning: nil)
    }

    package func snapshot() -> VideoQueueSnapshot {
        lock.lock()
        defer { lock.unlock() }
        let now = clock()
        return VideoQueueSnapshot(id: diagnosticID, sampledAt: now, received: received,
            consumed: consumed, queued: entries.count, bytes: bytes, byteLimit: byteLimit,
            peakBytes: highWaterBytes, maxAge: ageLimit, manualFrameLimit: frameLimit,
            oldestAge: entries.first.map { max(0, now - $0.time) } ?? 0, maxWait: maxWait,
            capacityDrops: capacityDrops, expiredDrops: expiredDrops, oversizedDrops: oversizedDrops,
            closedDrops: closedDrops, shutdownDrops: shutdownDrops,
            inputIdle: lastInput.map { max(0, now - $0) },
            outputIdle: lastOutput.map { max(0, now - $0) }, closed: closed)
    }

    package func diagnostics() -> String { snapshot().summary }
}
