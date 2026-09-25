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
    /// backlog. This noise floor avoids reacting to small packet bursts; it
    /// does not assert that small queues are latency-free on very slow links.
    package static let defaultMinimumCongestionQueueBytes: Int = 128 * 1024

    public private(set) var isRunning = false
    private var timer: Task<Void, Never>? {
        didSet {
            oldValue?.cancel()
        }
    }
    private var previousSampleTime = ProcessInfo.processInfo.systemUptime
    private var currentBytesInPerSecond = 0
    private var currentBytesOutPerSecond = 0
    private var previousTotalBytesIn = 0
    private var previousTotalBytesOut = 0
    /// EMA smoothing factor for per-second throughput samples. A single 1s
    /// window can read as a burst when the socket drains its backlog after a
    /// stall; smoothing keeps downstream consumers (stats, bitrate strategy)
    /// seeing smoothed traffic rather than the momentary drain rate. Neither
    /// sample measures unused link capacity.
    private static let emaSmoothing: Double = 0.3
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
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - previousSampleTime
        previousSampleTime = now
        return evaluate(report, elapsed: elapsed)
    }

    /// Deterministic sampling entry point shared by the timer and regression tests.
    /// Throughput is observed traffic, not a measurement of link capacity.
    func evaluate(_ report: NetworkTransportReport, elapsed: TimeInterval) -> NetworkMonitorEvent {
        let totalBytesIn = report.totalBytesIn
        let totalBytesOut = report.totalBytesOut
        let queueBytesOut = report.queueBytesOut
        let interval = max(elapsed, 0.001)
        let rawBytesIn = Int(Double(max(0, totalBytesIn - previousTotalBytesIn)) / interval)
        let rawBytesOut = Int(Double(max(0, totalBytesOut - previousTotalBytesOut)) / interval)
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
        let eventReport = NetworkMonitorReport(
            totalBytesIn: totalBytesIn,
            totalBytesOut: totalBytesOut,
            currentQueueBytesOut: queueBytesOut,
            currentBytesInPerSecond: currentBytesInPerSecond,
            currentBytesOutPerSecond: currentBytesOutPerSecond
        )
        // Require BOTH an absolute queue floor and sustained backlog. Growth
        // alone (e.g. 130 -> 140 -> 150 KiB on a fast link) is not congestion.
        // Use the faster of the fresh sample and EMA for detection: after an
        // idle source resumes, a stale low EMA must not exaggerate backlog.
        // The strategy still receives the smoothed sample for bounded cuts.
        let drainRate = max(rawBytesOut, currentBytesOutPerSecond, 1)
        let queueBacklogSeconds = Double(queueBytesOut) / Double(drainRate)
        if minimumCongestionQueueBytes <= queueBytesOut, maxQueueBacklogSeconds <= queueBacklogSeconds {
            previousQueueHighCounts += 1
            if 2 <= previousQueueHighCounts {
                previousQueueHighCounts = 0
                logger.info("ABR congestion queue=\(queueBytesOut) rawBps=\(rawBytesOut) emaBps=\(currentBytesOutPerSecond) backlog=\(queueBacklogSeconds)")
                return .publishInsufficientBWOccured(report: eventReport)
            }
        } else {
            previousQueueHighCounts = 0
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
        previousSampleTime = ProcessInfo.processInfo.systemUptime
        previousQueueHighCounts = 0
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
