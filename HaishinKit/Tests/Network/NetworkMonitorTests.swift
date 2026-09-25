import Foundation
import Testing

@testable import HaishinKit

@Suite("Network congestion evidence")
struct NetworkMonitorTests {
    private func isCongested(_ event: NetworkMonitorEvent) -> Bool {
        if case .publishInsufficientBWOccured = event { return true }
        return false
    }

    @Test("Growing queues that drain quickly are not congestion")
    func fastGrowingQueue() async {
        let reporter = MonitorReporter()
        let monitor = NetworkMonitor(reporter)
        for index in 1...6 {
            let event = await monitor.evaluate(.init(
                queueBytesOut: (120 + index * 10) * 1024,
                totalBytesIn: 0, totalBytesOut: index * 1024 * 1024
            ), elapsed: 1)
            #expect(!isCongested(event))
        }
    }

    @Test("Resuming after idle does not use stale low throughput as capacity")
    func idleThenBurst() async {
        let reporter = MonitorReporter()
        let monitor = NetworkMonitor(reporter)
        _ = await monitor.evaluate(.init(queueBytesOut: 0, totalBytesIn: 0, totalBytesOut: 16_000), elapsed: 1)
        for index in 1...2 {
            let event = await monitor.evaluate(.init(
                queueBytesOut: 512 * 1024, totalBytesIn: 0,
                totalBytesOut: 16_000 + index * 1024 * 1024
            ), elapsed: 1)
            #expect(!isCongested(event))
        }
    }

    @Test("Sustained backlog triggers, but one spike and tiny queues do not")
    func sustainedBacklog() async {
        let reporter = MonitorReporter()
        let monitor = NetworkMonitor(reporter)
        let queues = [256_000, 0, 256_000, 256_000, 16_000, 16_000]
        for (index, queue) in queues.enumerated() {
            let event = await monitor.evaluate(.init(
                queueBytesOut: queue, totalBytesIn: 0, totalBytesOut: (index + 1) * 64_000
            ), elapsed: 1)
            #expect(isCongested(event) == (index == 3))
        }
    }

    @Test("A stalled connection with queued data remains congestion")
    func stalledQueue() async {
        let reporter = MonitorReporter()
        let monitor = NetworkMonitor(reporter)
        for index in 0..<4 {
            let event = await monitor.evaluate(.init(
                queueBytesOut: 256_000, totalBytesIn: 0, totalBytesOut: 0
            ), elapsed: 1)
            #expect(isCongested(event) == (index % 2 == 1))
        }
    }

    @Test("Delayed sampling normalizes actual elapsed time")
    func elapsedTime() async {
        let reporter = MonitorReporter()
        let monitor = NetworkMonitor(reporter)
        let event = await monitor.evaluate(.init(
            queueBytesOut: 0, totalBytesIn: 60_000, totalBytesOut: 300_000
        ), elapsed: 3)
        guard case .status(let report) = event else {
            Issue.record("Unexpected congestion")
            return
        }
        #expect(report.currentBytesOutPerSecond == 100_000)
        #expect(report.currentBytesInPerSecond == 20_000)
    }
}

private actor MonitorReporter: NetworkTransportReporter {
    func makeNetworkMonitor() async -> NetworkMonitor { NetworkMonitor(self) }
    func makeNetworkTransportReport() async -> NetworkTransportReport {
        .init(queueBytesOut: 0, totalBytesIn: 0, totalBytesOut: 0)
    }
}
