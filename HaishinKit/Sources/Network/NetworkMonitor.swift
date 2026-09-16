import Foundation

/// An objec thatt provides the RTMPConnection, SRTConnection's monitoring events.
package final actor NetworkMonitor {
    /// The error domain codes.
    public enum Error: Swift.Error {
        /// An invalid internal stare.
        case invalidState
    }

    /// An asynchronous sequence for network monitoring  event.
    public var event: AsyncStream<NetworkMonitorEvent> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }

    /// The default backlog duration (in seconds) that triggers insufficient
    /// bandwidth. Normalizing the queue against the measured drain rate makes
    /// "congestion" mean the same added latency at every bitrate, instead of an
    /// absolute byte count (512 KB is ~0.75 s at 5.5 Mbps but ~4 s at 1 Mbps).
    package static let defaultMaxQueueBacklogSeconds: Double = 0.75

    /// Absolute floor (bytes) for the send queue to count as congestion. The
    /// backlog-seconds threshold is normalized by the *measured* drain rate,
    /// which collapses on a static / VFR source that legitimately produces
    /// little (e.g. audio-only ~16 KB/s): 0.75 s then equals ~12 KB, so a
    /// single keyframe or one coalesced send chunk reads as seconds of
    /// backlog. A queue below this floor cannot add meaningful latency — it is
    /// at most ~one send round trip — so it must never trigger a bitrate cut.
    package static let defaultMinimumCongestionQueueBytes: Int = 128 * 1024

    public private(set) var isRunning = false
    private var timer: Task<Void, Never>? {
        didSet {
            oldValue?.cancel()
        }
    }
    private var measureInterval = 3
    private var currentBytesInPerSecond = 0
    private var currentBytesOutPerSecond = 0
    private var previousTotalBytesIn = 0
    private var previousTotalBytesOut = 0
    /// EMA smoothing factor for per-second throughput samples. A single 1s
    /// window can read as a burst when the socket drains its backlog after a
    /// stall; smoothing keeps downstream consumers (stats, bitrate strategy)
    /// seeing sustainable throughput rather than the momentary drain rate.
    private static let emaSmoothing: Double = 0.3
    private var previousQueueBytesOut: [Int] = []
    private var previousQueueHighCounts: Int = 0
    private var continuation: AsyncStream<NetworkMonitorEvent>.Continuation? {
        didSet {
            oldValue?.finish()
        }
    }
    private weak var reporter: (any NetworkTransportReporter)?
    package var maxQueueBacklogSeconds: Double
    package var minimumCongestionQueueBytes: Int

    /// Creates a new instance.
    package init(
        _ reporter: some NetworkTransportReporter,
        maxQueueBacklogSeconds: Double = NetworkMonitor.defaultMaxQueueBacklogSeconds,
        minimumCongestionQueueBytes: Int = NetworkMonitor.defaultMinimumCongestionQueueBytes
    ) {
        self.reporter = reporter
        self.maxQueueBacklogSeconds = maxQueueBacklogSeconds
        self.minimumCongestionQueueBytes = minimumCongestionQueueBytes
    }

    private func collect() async throws -> NetworkMonitorEvent {
        guard let report = await reporter?.makeNetworkTransportReport() else {
            throw Error.invalidState
        }
        let totalBytesIn = report.totalBytesIn
        let totalBytesOut = report.totalBytesOut
        let queueBytesOut = report.queueBytesOut
        let rawBytesIn = totalBytesIn - previousTotalBytesIn
        let rawBytesOut = totalBytesOut - previousTotalBytesOut
        previousTotalBytesIn = totalBytesIn
        previousTotalBytesOut = totalBytesOut
        // EMA-smooth the throughput samples so a single burst window (e.g. the
        // socket draining a multi-MB backlog in one second after a stall) does
        // not get reported as sustainable bandwidth. Seed with the first raw
        // sample; afterwards blend with the previous estimate.
        if 0 < currentBytesInPerSecond {
            currentBytesInPerSecond = Int(Double(rawBytesIn) * Self.emaSmoothing + Double(currentBytesInPerSecond) * (1 - Self.emaSmoothing))
        } else {
            currentBytesInPerSecond = rawBytesIn
        }
        if 0 < currentBytesOutPerSecond {
            currentBytesOutPerSecond = Int(Double(rawBytesOut) * Self.emaSmoothing + Double(currentBytesOutPerSecond) * (1 - Self.emaSmoothing))
        } else {
            currentBytesOutPerSecond = rawBytesOut
        }
        previousQueueBytesOut.append(queueBytesOut)
        let eventReport = NetworkMonitorReport(
            totalBytesIn: totalBytesIn,
            totalBytesOut: totalBytesOut,
            currentQueueBytesOut: queueBytesOut,
            currentBytesInPerSecond: currentBytesInPerSecond,
            currentBytesOutPerSecond: currentBytesOutPerSecond
        )
        // Backlog-duration threshold: the queue is congested when it holds more
        // than `maxQueueBacklogSeconds` worth of data at the measured drain
        // rate. This is bitrate-invariant (same added latency at every rate) and
        // naturally ignores transient VBR bursts, which drain too fast to build
        // a meaningful backlog. If the queue stays high for 2 consecutive
        // intervals, trigger insufficient BW.
        //
        // The queue must ALSO clear an absolute floor. The denominator is the
        // measured drain rate, which on a static / VFR source collapses toward
        // audio-only; normalizing a tiny queue by that small denominator would
        // otherwise read as a multi-second backlog and cut bitrate on a healthy
        // link. A queue below the floor is at most ~one send round trip, so it
        // cannot add meaningful latency.
        let congestedQueue = minimumCongestionQueueBytes <= queueBytesOut
        let queueBacklogSeconds = Double(queueBytesOut) / Double(max(currentBytesOutPerSecond, 1))
        if congestedQueue, maxQueueBacklogSeconds <= queueBacklogSeconds {
            previousQueueHighCounts += 1
            if 2 <= previousQueueHighCounts {
                previousQueueHighCounts = 0
                previousQueueBytesOut.removeAll()
                return .publishInsufficientBWOccured(report: eventReport)
            }
        } else {
            previousQueueHighCounts = 0
        }
        if measureInterval <= previousQueueBytesOut.count {
            defer {
                previousQueueBytesOut.removeFirst()
            }
            // The legacy monotonic-growth heuristic must respect the same floor:
            // a queue that is merely growing from zero is not congestion.
            if congestedQueue {
                var total = 0
                for i in 0..<previousQueueBytesOut.count - 1 where previousQueueBytesOut[i] < previousQueueBytesOut[i + 1] {
                    total += 1
                }
                if measureInterval - 1 <= total {
                    return .publishInsufficientBWOccured(report: eventReport)
                }
            }
        }
        return .status(report: eventReport)
    }
}

extension NetworkMonitor: AsyncRunner {
    // MARK: AsyncRunner
    package func startRunning() {
        guard !isRunning else {
            return
        }
        isRunning = true
        timer = Task {
            let timer = AsyncStream {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            for await _ in timer {
                do {
                    let event = try await collect()
                    continuation?.yield(event)
                } catch {
                    continuation?.finish()
                }
            }
        }
    }

    package func stopRunning() {
        guard isRunning else {
            return
        }
        isRunning = false
        timer = nil
        continuation = nil
    }
}
