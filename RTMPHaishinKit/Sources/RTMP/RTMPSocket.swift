import Foundation
import HaishinKit
import Network

final actor RTMPSocket {
    static let defaultWindowSizeC = Int(UInt16.max)
    static let maxQueueBytesOut = 2 * 1024 * 1024
    private static let sendChunkSize = 128 * 1024

    enum Error: Swift.Error {
        case invalidState
        case endOfStream
        case connectionTimedOut
        case connectionNotEstablished(_ error: NWError?)
    }

    var onLog: (@Sendable (RTMPLogEvent) -> Void)?
    private var timeout: UInt64 = 15
    private var connected = false
    private var windowSizeC = RTMPSocket.defaultWindowSizeC
    private var securityLevel: StreamSocketSecurityLevel = .none
    private var totalBytesIn = 0
    private var totalBytesOut = 0
    private var parameters: NWParameters = .tcp
    private var connection: NWConnection? {
        didSet {
            oldValue?.viabilityUpdateHandler = nil
            oldValue?.stateUpdateHandler = nil
            oldValue?.forceCancel()
        }
    }
    /// Ring-buffer style pending-send queue: segmented deque with a head cursor.
    /// O(1) enqueue/dequeue, no Data compaction churn.
    private struct SendQueue {
        private var segments: [Data] = []
        private var headIndex = 0
        private var headOffset = 0

        var isEmpty: Bool {
            return headIndex >= segments.count
        }

        var totalBytes: Int {
            guard headIndex < segments.count else { return 0 }
            var total = 0
            for i in headIndex..<segments.count {
                total += segments[i].count
            }
            return total - headOffset
        }

        mutating func append(_ data: Data) {
            segments.append(data)
        }

        /// Returns up to `maxBytes` from the front without consuming.
        func peek(maxBytes: Int) -> Data {
            guard headIndex < segments.count else { return Data() }
            var result = Data()
            result.reserveCapacity(min(maxBytes, totalBytes))
            var remaining = maxBytes
            var i = headIndex
            var offset = headOffset
            while remaining > 0 && i < segments.count {
                let segment = segments[i]
                let available = segment.count - offset
                let take = min(available, remaining)
                result.append(segment.subdata(in: offset..<offset + take))
                remaining -= take
                if take == available {
                    i += 1
                    offset = 0
                } else {
                    offset += take
                }
            }
            return result
        }

        /// Advances the cursor past `bytes` after the send is confirmed.
        mutating func consume(_ bytes: Int) {
            var remaining = bytes
            while remaining > 0 && headIndex < segments.count {
                let segment = segments[headIndex]
                let available = segment.count - headOffset
                let take = min(available, remaining)
                headOffset += take
                remaining -= take
                if headOffset >= segment.count {
                    headIndex += 1
                    headOffset = 0
                }
            }
            // Compact consumed prefix to bound memory.
            if 16 < headIndex {
                segments.removeFirst(headIndex)
                headIndex = 0
                headOffset = 0
            }
        }

        mutating func removeAll() {
            segments.removeAll()
            headIndex = 0
            headOffset = 0
        }
    }

    private var sendQueue = SendQueue()
    private var isSending = false
    private var qualityOfService: DispatchQoS = .userInitiated
    private var continuation: CheckedContinuation<Void, any Swift.Error>?
    private var drainContinuation: CheckedContinuation<Void, Never>?
    private lazy var networkQueue = DispatchQueue(label: "com.haishinkit.HaishinKit.RTMPSocket.network", qos: qualityOfService)

    init() {
    }

    init(qualityOfService: DispatchQoS, securityLevel: StreamSocketSecurityLevel) {
        self.qualityOfService = qualityOfService
        switch securityLevel {
        case .ssLv2, .ssLv3, .tlSv1, .negotiatedSSL:
            parameters = .tls
        default:
            parameters = .tcp
        }
    }

    var RTMPURL: String = "example.com"
    var RTMPPort: Int = 1935

    func connect(_ name: String, port: Int) async throws {
        guard !connected else {
            throw Error.invalidState
        }
        sendQueue.removeAll()
        isSending = false
        totalBytesIn = 0
        totalBytesOut = 0
        do {
            let connection = NWConnection(to: NWEndpoint.hostPort(host: .init(name), port: .init(integerLiteral: NWEndpoint.Port.IntegerLiteralType(port))), using: parameters)
            self.connection = connection
            self.RTMPURL = name
            self.RTMPPort = port

            try await withCheckedThrowingContinuation { (checkedContinuation: CheckedContinuation<Void, Swift.Error>) in
                self.continuation = checkedContinuation
                Task {
                    try? await Task.sleep(nanoseconds: timeout * 1_000_000_000)
                    guard let continuation else {
                        return
                    }
                    continuation.resume(throwing: Error.connectionTimedOut)
                    self.continuation = nil
                    close()
                }
                connection.stateUpdateHandler = { state in
                    Task { await self.stateDidChange(to: state) }
                }
                connection.viabilityUpdateHandler = { viability in
                    Task { await self.viabilityDidChange(to: viability) }
                }
                connection.start(queue: networkQueue)
            }
        } catch {
            throw error
        }
    }

    func send(_ data: Data) {
        guard !data.isEmpty else {
            return
        }
        guard connected else {
            onLog?(.init(level: .warn, message: "Send dropped: not connected \(RTMPURL):\(RTMPPort)", detail: "size=\(data.count)"))
            return
        }

        // Backpressure: 佇列已滿時直接丟棄新進資料。
        // 不碰已排隊資料，避免破壞 in-flight 狀態（與 sendOffset 不變量）。
        if sendQueue.totalBytes + data.count > Self.maxQueueBytesOut {
            onLog?(.init(level: .warn, message: "Backpressure: dropped incoming", detail: "size=\(data.count)"))
            return
        }

        sendQueue.append(data)
        if !isSending {
            sendNextChunk()
        }
    }


    private func recvOnce() async throws -> Data {
        return try await withCheckedThrowingContinuation { continuation in
            connection?.receive(minimumIncompleteLength: 1, maximumLength: windowSizeC) { content, _, _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let content {
                    continuation.resume(returning: content)
                } else {
                    continuation.resume(throwing: Error.endOfStream)
                }
            }
        }
    }

    func recv() -> AsyncStream<Data> {
        AsyncStream { continuation in
            Task {
                while connected {
                    do {
                        let data = try await recvOnce()
                        totalBytesIn += data.count   // ← 補回統計
                        onLog?(.init(level: .trace,
                                    message: "Socket recv",
                                    detail: "size=\(data.count) totalIn=\(totalBytesIn)"))
                                    
                        continuation.yield(data)
                    } catch {
                        // 這裡就是所有 recv error 的集中點
                        logger.error("recv error:", error)
                        onLog?(.init(level: .error,
                                    message: "recv error",
                                    detail: "\(error)"))

                        continuation.finish()
                        break
                    }
                }
            }
        }
    }

    func drain() async {
        guard connected else { return }
        guard !sendQueue.isEmpty || isSending else { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            drainContinuation = c
        }
    }

    func close(_ error: NWError? = nil) {
        guard connection != nil else {
            return
        }
        if let continuation {
            continuation.resume(throwing: Error.connectionNotEstablished(error))
            self.continuation = nil
        }
        if let drainContinuation {
            drainContinuation.resume()
            self.drainContinuation = nil
        }
        
        onLog?(.init(level: .info, message: "Socket close", detail: "error=\(error.map{"\($0)"} ?? "nil") totalBytesIn=\(totalBytesIn) totalBytesOut=\(totalBytesOut)"))
        connected = false
        isSending = false
        sendQueue.removeAll()
        connection = nil
        continuation = nil
    }

    func setOnLog(_ handler: @Sendable @escaping (RTMPLogEvent) -> Void) {
        onLog = handler
    }

    private func stateDidChange(to state: NWConnection.State) {
        switch state {
        case .ready:
            logger.info("Connection is ready.")
            onLog?(.init(level: .info, message: "Socket ready \(RTMPURL):\(RTMPPort)", detail: "totalBytesIn=\(totalBytesIn) totalBytesOut=\(totalBytesOut) buffer=\(sendQueue.totalBytes)"))
            connected = true
            self.continuation?.resume()
            self.continuation = nil
        case .waiting(let error):
            logger.warn("Connection waiting:", error)
            onLog?(.init(level: .warn, message: "Socket waiting \(RTMPURL):\(RTMPPort)", detail: "\(error)"))
        case .setup:
            logger.debug("Connection is setting up.")
        case .preparing:
            logger.debug("Connection is preparing.")
        case .failed(let error):
            logger.warn("Connection failed:", error)
            onLog?(.init(level: .error, message: "Socket failed", detail: "\(error)"))
            close(error)
        case .cancelled:
            logger.info("Connection cancelled.")
            onLog?(.init(level: .info, message: "Socket cancelled"))
            close(NWError.posix(.ECONNABORTED))


        @unknown default:
            logger.error("Unknown connection state.")
        }
    }

    private func viabilityDidChange(to viability: Bool) {
        logger.info("Connection viability changed to ", viability)
        onLog?(.init(level: .info, message: "Socket viability changed", detail: "viability=\(viability)"))
    }

    private func sendNextChunk() {
        guard let connection else {
            isSending = false
            sendQueue.removeAll()
            return
        }
        let chunk = sendQueue.peek(maxBytes: Self.sendChunkSize)
        guard !chunk.isEmpty else {
            isSending = false
            return
        }
        isSending = true
        connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            Task { await self.didSendChunk(chunk.count, error: error) }
        })
    }

    private func didSendChunk(_ size: Int, error: NWError?) {
        totalBytesOut += size
        sendQueue.consume(size)
        isSending = false
        if !sendQueue.isEmpty {
            sendNextChunk()
        } else if let drainContinuation {
            drainContinuation.resume()
            self.drainContinuation = nil
        }
        if let error {
            logger.error("Failed to send data:", error)
            close(error)
        }
    }

}

extension RTMPSocket: NetworkTransportReporter {
    // MARK: NetworkTransportReporter
    func makeNetworkMonitor() async -> NetworkMonitor {
        return .init(self)
    }

    func makeNetworkTransportReport() -> NetworkTransportReport {
        return .init(queueBytesOut: sendQueue.totalBytes, totalBytesIn: totalBytesIn, totalBytesOut: totalBytesOut)
    }
}
