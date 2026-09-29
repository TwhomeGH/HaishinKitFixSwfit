import Foundation

/// Owns one queue generation. A late cancellation can close only its original queue.
package final class AdaptiveMediaFlow<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: AdaptiveMediaQueue<Element>?
    private var maxBytes: Int
    private var maxAge: TimeInterval
    private var generation: UInt64 = 0
    private var missingDrops = 0

    package init(maxBytes: Int = 15 * 1024 * 1024, maxAge: TimeInterval = 0.1) {
        self.maxBytes = maxBytes
        self.maxAge = maxAge
    }

    package func stream() -> AsyncStream<Element> {
        lock.lock()
        defer { lock.unlock() }
        queue?.finish()
        let next = AdaptiveMediaQueue<Element>(maxBytes: maxBytes, maxAge: maxAge)
        queue = next
        generation &+= 1
        return next.stream()
    }

    package func offer(_ value: Element, bytes: Int) {
        lock.lock()
        let current = queue
        if current == nil { missingDrops += 1 }
        lock.unlock()
        current?.offer(value, bytes: bytes)
    }

    package func update(maxBytes: Int, maxAge: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        self.maxBytes = max(0, maxBytes)
        self.maxAge = maxAge
        queue?.update(maxBytes: self.maxBytes, maxAge: maxAge)
    }

    package func finish() {
        lock.lock()
        defer { lock.unlock() }
        queue?.finish()
    }

    package func snapshot() -> VideoQueueStageSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return VideoQueueStageSnapshot(availability: queue == nil ? .unavailable : .available,
            generation: generation, missingDrops: missingDrops, queue: queue?.snapshot())
    }

    package func diagnostics() -> String { snapshot().summary() }
}
