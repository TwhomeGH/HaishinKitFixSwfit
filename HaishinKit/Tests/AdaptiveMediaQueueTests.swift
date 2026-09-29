import Foundation
import Testing
@testable import HaishinKit

private final class QueueTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 0
    func now() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return time }
    func advance(_ amount: TimeInterval) { lock.lock(); time += amount; lock.unlock() }
}

@Suite struct AdaptiveMediaQueueTests {
    @Test func sixtyFPSDoesNotRequireSixtyQueuedFrames() async {
        let clock = QueueTestClock()
        let queue = AdaptiveMediaQueue<Int>(maxBytes: 1, clock: { clock.now() })
        var iterator = queue.stream().makeAsyncIterator()
        for frame in 0..<120 {
            queue.offer(frame, bytes: 1)
            #expect(await iterator.next() == frame)
            clock.advance(1.0 / 60)
        }
        #expect(queue.diagnostics().contains("capacityDrop=0"))
        queue.finish()
    }

    @Test func moreThanThirtySmallFramesFitWithinBudget() async {
        let clock = QueueTestClock()
        let queue = AdaptiveMediaQueue<Int>(maxBytes: 64, clock: { clock.now() })
        var iterator = queue.stream().makeAsyncIterator()
        for frame in 0..<60 { queue.offer(frame, bytes: 1) }
        for frame in 0..<60 { #expect(await iterator.next() == frame) }
        queue.finish()
    }

    @Test func bytePressureKeepsNewestFrames() async {
        let queue = AdaptiveMediaQueue<Int>(maxBytes: 10, maxAge: 10)
        var iterator = queue.stream().makeAsyncIterator()
        queue.offer(1, bytes: 6)
        queue.offer(2, bytes: 6)
        #expect(await iterator.next() == 2)
        #expect(queue.diagnostics().contains("capacityDrop=1"))
        queue.finish()
    }

    @Test func liveResizeTrimsWithoutReplacingConsumer() async {
        let queue = AdaptiveMediaQueue<Int>(maxBytes: 12, maxAge: 10)
        var iterator = queue.stream().makeAsyncIterator()
        for frame in 1...3 { queue.offer(frame, bytes: 4) }
        queue.update(maxBytes: 4, maxAge: 10)
        #expect(await iterator.next() == 3)
        queue.update(maxBytes: 8, maxAge: 10)
        queue.offer(4, bytes: 4)
        queue.offer(5, bytes: 4)
        #expect(await iterator.next() == 4)
        #expect(await iterator.next() == 5)
        queue.finish()
    }

    @Test func staleFramesAreNotDelivered() async {
        let clock = QueueTestClock()
        let queue = AdaptiveMediaQueue<Int>(maxBytes: 10, clock: { clock.now() })
        var iterator = queue.stream().makeAsyncIterator()
        queue.offer(1, bytes: 1)
        clock.advance(0.2)
        queue.offer(2, bytes: 1)
        #expect(await iterator.next() == 2)
        #expect(queue.diagnostics().contains("expiredDrop=1"))
        queue.finish()
    }

    @Test func oversizedFrameIsExplicitlyRejected() async {
        let queue = AdaptiveMediaQueue<Int>(maxBytes: 2)
        queue.offer(1, bytes: 3)
        #expect(queue.diagnostics().contains("oversizedDrop=1"))
        queue.finish()
        var iterator = queue.stream().makeAsyncIterator()
        #expect(await iterator.next() == nil)
    }

    @Test func finishReleasesWaitingConsumer() async {
        let queue = AdaptiveMediaQueue<Int>(maxBytes: 10)
        let reader = Task {
            var iterator = queue.stream().makeAsyncIterator()
            return await iterator.next()
        }
        queue.finish()
        #expect(await reader.value == nil)
        queue.offer(1, bytes: 1)
        #expect(queue.diagnostics().contains("closedDrop=1"))
    }

    @Test func cancellationClosesWaitingConsumer() async {
        let queue = AdaptiveMediaQueue<Int>(maxBytes: 10)
        let reader = Task {
            var iterator = queue.stream().makeAsyncIterator()
            return await iterator.next()
        }
        reader.cancel()
        #expect(await reader.value == nil)
    }

    @Test func restartingFlowIsolatesOldReader() async {
        let flow = AdaptiveMediaFlow<Int>(maxBytes: 10)
        var old = flow.stream().makeAsyncIterator()
        var fresh = flow.stream().makeAsyncIterator()
        #expect(await old.next() == nil)
        flow.offer(2, bytes: 1)
        #expect(await fresh.next() == 2)
        flow.finish()
    }

    @Test func manualCountStillRespectsByteBudget() async {
        let queue = AdaptiveMediaQueue<Int>(maxBytes: 4, maxAge: 10, maxFrames: 100)
        var iterator = queue.stream().makeAsyncIterator()
        queue.offer(1, bytes: 4)
        queue.offer(2, bytes: 4)
        #expect(await iterator.next() == 2)
        queue.finish()
    }

    @Test func lateCancellationCannotCloseNewFlow() async {
        let flow = AdaptiveMediaFlow<Int>(maxBytes: 10)
        let oldStream = flow.stream()
        let oldReader = Task {
            var iterator = oldStream.makeAsyncIterator()
            return await iterator.next()
        }
        var fresh = flow.stream().makeAsyncIterator()
        oldReader.cancel()
        _ = await oldReader.value
        flow.offer(42, bytes: 1)
        #expect(await fresh.next() == 42)
        flow.finish()
    }

    @Test func concurrentProducersStayWithinBudget() async {
        let queue = AdaptiveMediaQueue<Int>(maxBytes: 16, maxAge: 100)
        await withTaskGroup(of: Void.self) { group in
            for producer in 0..<4 {
                group.addTask {
                    for frame in 0..<100 { queue.offer(producer * 100 + frame, bytes: 1) }
                }
            }
        }
        let stats = queue.diagnostics()
        #expect(stats.contains("in=400 "))
        #expect(stats.contains("bytes=16/16"))
        #expect(stats.contains("capacityDrop=384"))
        queue.finish()
        #expect(queue.diagnostics().contains("shutdownDrop=16"))
    }
    @Test func snapshotReadersDoNotInterfere() throws {
        let clock = QueueTestClock()
        let queue = AdaptiveMediaQueue<Int>(maxBytes: 100, clock: { clock.now() })
        let baseline = queue.snapshot()
        queue.offer(1, bytes: 4)
        clock.advance(1)
        let first = queue.snapshot()
        _ = queue.diagnostics()
        let second = queue.snapshot()
        #expect(first.rates(since: baseline)?.inputFPS == 1)
        #expect(second.rates(since: baseline)?.inputFPS == 1)
        #expect(second.queued == 1)
        #expect(second.expiredDrops == 0)
        #expect(second.oldestAge == 1)
        let decoded = try JSONDecoder().decode(VideoQueueSnapshot.self, from: JSONEncoder().encode(second))
        #expect(decoded.id == second.id)
        #expect(decoded.bytes == 4)
        queue.finish()
    }

    @Test func snapshotRatesRejectDifferentQueuesAndEqualTime() {
        let first = AdaptiveMediaQueue<Int>(maxBytes: 1).snapshot()
        let second = AdaptiveMediaQueue<Int>(maxBytes: 1).snapshot()
        #expect(second.rates(since: first) == nil)
        #expect(first.rates(since: first) == nil)
        let flow = AdaptiveMediaFlow<Int>()
        #expect(flow.snapshot().availability == .unavailable)
        _ = flow.stream()
        let old = flow.snapshot()
        _ = flow.stream()
        let new = flow.snapshot()
        #expect(new.generation != old.generation)
        #expect(new.queue?.rates(since: old.queue) == nil)
        flow.finish()
    }

    @Test func pipelineSnapshotRoundTrips() throws {
        let pipeline = VideoPipelineSnapshot(sampledAt: 1, mixer: nil,
            encoderInput: VideoQueueStageSnapshot(availability: .ownerLockBusy),
            bridgeReceived: 10, pressureDrops: 2, lastPTS: nil)
        let decoded = try JSONDecoder().decode(VideoPipelineSnapshot.self, from: JSONEncoder().encode(pipeline))
        #expect(decoded.schemaVersion == 1)
        #expect(decoded.encoderInput.availability == .ownerLockBusy)
        #expect(decoded.mixer == nil)
        #expect(decoded.lastPTS == nil)
        #expect(decoded.pressureDrops == 2)
    }
}
