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

    /// The default maximum queue bytes threshold for triggering insufficient bandwidth.
    package static let defaultMaxQueueBytesThreshold = 512 * 1024

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
    private var previousQueueBytesOut: [Int] = []
    private var previousQueueHighCounts: Int = 0
    private var continuation: AsyncStream<NetworkMonitorEvent>.Continuation? {
        didSet {
            oldValue?.finish()
        }
    }
    private weak var reporter: (any NetworkTransportReporter)?
    package var maxQueueBytesThreshold: Int

    /// Creates a new instance.
    package init(_ reporter: some NetworkTransportReporter, maxQueueBytesThreshold: Int = NetworkMonitor.defaultMaxQueueBytesThreshold) {
        self.reporter = reporter
        self.maxQueueBytesThreshold = maxQueueBytesThreshold
    }

    private func collect() async throws -> NetworkMonitorEvent {
        guard let report = await reporter?.makeNetworkTransportReport() else {
            throw Error.invalidState
        }
        let totalBytesIn = report.totalBytesIn
        let totalBytesOut = report.totalBytesOut
        let queueBytesOut = report.queueBytesOut
        currentBytesInPerSecond = totalBytesIn - previousTotalBytesIn
        currentBytesOutPerSecond = totalBytesOut - previousTotalBytesOut
        previousTotalBytesIn = totalBytesIn
        previousTotalBytesOut = totalBytesOut
        previousQueueBytesOut.append(queueBytesOut)
        let eventReport = NetworkMonitorReport(
            totalBytesIn: totalBytesIn,
            totalBytesOut: totalBytesOut,
            currentQueueBytesOut: queueBytesOut,
            currentBytesInPerSecond: currentBytesInPerSecond,
            currentBytesOutPerSecond: currentBytesOutPerSecond
        )
        // Absolute queue size threshold: if queue exceeds max for 2 consecutive intervals, trigger insufficient BW
        if maxQueueBytesThreshold <= queueBytesOut {
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
            var total = 0
            for i in 0..<previousQueueBytesOut.count - 1 where previousQueueBytesOut[i] < previousQueueBytesOut[i + 1] {
                total += 1
            }
            if measureInterval - 1 <= total {
                return .publishInsufficientBWOccured(report: eventReport)
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
