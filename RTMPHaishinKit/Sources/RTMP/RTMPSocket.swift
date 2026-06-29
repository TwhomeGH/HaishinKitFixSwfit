import Foundation
import HaishinKit
import Network

final actor RTMPSocket {
    static let defaultWindowSizeC = Int(UInt16.max)
    /// Maximum bytes queued for send before backpressure kicks in.
    static let maxQueueBytesOut = 5 * 1024 * 1024 // 5 MB

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
    private(set) var queueBytesOut = 0
    private var totalBytesOut = 0
    private var parameters: NWParameters = .tcp
    private var connection: NWConnection? {
        didSet {
            oldValue?.viabilityUpdateHandler = nil
            oldValue?.stateUpdateHandler = nil
            oldValue?.forceCancel()
        }
    }
    private var outputs: AsyncStream<Data>.Continuation? {
        didSet {
            oldValue?.finish()
        }
    }
    private var qualityOfService: DispatchQoS = .userInitiated
    private var continuation: CheckedContinuation<Void, any Swift.Error>?
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

    func connect(_ name: String, port: Int) async throws {
        guard !connected else {
            throw Error.invalidState
        }
        totalBytesIn = 0
        totalBytesOut = 0
        queueBytesOut = 0
        do {
            let connection = NWConnection(to: NWEndpoint.hostPort(host: .init(name), port: .init(integerLiteral: NWEndpoint.Port.IntegerLiteralType(port))), using: parameters)
            self.connection = connection
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
        enqueue(data)
    }

    func send(_ iterator: AnyIterator<Data>) {
        var payload = Data()
        for data in iterator {
            payload.append(data)
        }
        enqueue(payload)
    }

    func send(_ chunks: [Data]) {
        guard !chunks.isEmpty else {
            return
        }
        guard 1 < chunks.count else {
            enqueue(chunks[0])
            return
        }
        let size = chunks.reduce(0) { $0 + $1.count }
        var payload = Data()
        payload.reserveCapacity(size)
        for data in chunks {
            payload.append(data)
        }
        enqueue(payload)
    }

    private func enqueue(_ data: Data) {
        guard !data.isEmpty else {
            return
        }
        guard connected else {
            onLog?(.init(level: .warn, message: "Send dropped: not connected", detail: "size=\(data.count)"))
            return
        }
        guard queueBytesOut + data.count <= Self.maxQueueBytesOut else {
            logger.warn("Backpressure: dropping send, queue full (\(queueBytesOut) bytes)")
            onLog?(.init(level: .warn, message: "Backpressure: send dropped", detail: "size=\(data.count) queueBytesOut=\(queueBytesOut) max=\(Self.maxQueueBytesOut)"))
            return
        }
        guard let outputs else {
            onLog?(.init(level: .warn, message: "Send dropped: output stream unavailable", detail: "size=\(data.count)"))
            return
        }
        queueBytesOut += data.count
        onLog?(.init(level: .trace, message: "Socket enqueue", detail: "size=\(data.count) queueBytesOut=\(queueBytesOut)"))
        switch outputs.yield(data) {
        case .enqueued(_):
            break
        case .dropped(let dropped):
            queueBytesOut = max(0, queueBytesOut - dropped.count)
            onLog?(.init(level: .warn, message: "Socket enqueue dropped", detail: "size=\(dropped.count) queueBytesOut=\(queueBytesOut)"))
        case .terminated:
            queueBytesOut = max(0, queueBytesOut - data.count)
            onLog?(.init(level: .warn, message: "Socket enqueue terminated", detail: "size=\(data.count)"))
        }
    }

    func recv() -> AsyncStream<Data> {
        AsyncStream<Data> { continuation in
            Task {
                defer { continuation.finish() }
                do {
                    while connected {
                        let data = try await recv()
                        onLog?(.init(level: .trace, message: "Socket recv", detail: "size=\(data.count) totalIn=\(totalBytesIn + data.count)"))
                        continuation.yield(data)
                        totalBytesIn += data.count
                    }
                } catch {
                    logger.error("recv error:", error)
                    onLog?(.init(level: .error, message: "recv error", detail: "\(error)"))
                }
            }
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
        onLog?(.init(level: .info, message: "Socket close", detail: "error=\(error.map{"\($0)"} ?? "nil") totalBytesIn=\(totalBytesIn) totalBytesOut=\(totalBytesOut)"))
        connected = false
        outputs = nil
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
            onLog?(.init(level: .info, message: "Socket ready", detail: "totalBytesIn=\(totalBytesIn) totalBytesOut=\(totalBytesOut) queueBytesOut=\(queueBytesOut)"))
            connected = true
            let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingOldest(256))
            Task {
                for await data in stream {
                    guard connected else { break }
                    do {
                        try await send(data)
                        totalBytesOut += data.count
                        queueBytesOut = max(0, queueBytesOut - data.count)
                    } catch {
                        logger.error("Failed to send data:", error)
                        close(error as? NWError)
                        break
                    }
                }
            }
            self.outputs = continuation
            self.continuation?.resume()
            self.continuation = nil
        case .waiting(let error):
            logger.warn("Connection waiting:", error)
            onLog?(.init(level: .warn, message: "Socket waiting", detail: "\(error)"))
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
        @unknown default:
            logger.error("Unknown connection state.")
        }
    }

    private func viabilityDidChange(to viability: Bool) {
        logger.info("Connection viability changed to ", viability)
    }

    private func send(_ data: Data) async throws {
        return try await withCheckedThrowingContinuation { continuation in
            guard let connection else {
                continuation.resume(throwing: Error.invalidState)
                return
            }
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume()
            })
        }
    }

    private func recv() async throws -> Data {
        return try await withCheckedThrowingContinuation { continuation in
            guard let connection else {
                continuation.resume(throwing: Error.invalidState)
                return
            }
            connection.receive(minimumIncompleteLength: 1, maximumLength: windowSizeC) { content, _, _, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if let content {
                    continuation.resume(returning: content)
                } else {
                    continuation.resume(throwing: Error.endOfStream)
                }
            }
        }
    }
}

extension RTMPSocket: NetworkTransportReporter {
    // MARK: NetworkTransportReporter
    func makeNetworkMonitor() async -> NetworkMonitor {
        return .init(self)
    }

    func makeNetworkTransportReport() -> NetworkTransportReport {
        return .init(queueBytesOut: queueBytesOut, totalBytesIn: totalBytesIn, totalBytesOut: totalBytesOut)
    }
}
