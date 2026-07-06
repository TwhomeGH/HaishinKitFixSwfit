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
    private var sendBuffer = Data()
    private var isSending = false
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
        sendBuffer.removeAll()
        isSending = false
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
        sendBuffer.append(data)
        queueBytesOut += data.count
        onLog?(.init(level: .trace, message: "Socket enqueue", detail: "size=\(data.count) buffer=\(sendBuffer.count) queueBytesOut=\(queueBytesOut)"))
        if !isSending {
            flushSendBuffer()
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
        isSending = false
        sendBuffer.removeAll()
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

    private func flushSendBuffer() {
        let data = sendBuffer
        guard !data.isEmpty else { return }
        sendBuffer.removeAll(keepingCapacity: true)
        isSending = true
        guard let connection else {
            isSending = false
            queueBytesOut = max(0, queueBytesOut - data.count)
            return
        }
        connection.send(content: data, completion: .contentProcessed { error in
            Task { await self.didSend(data, error: error) }
        })
    }

    private func didSend(_ data: Data, error: Error?) {
        totalBytesOut += data.count
        queueBytesOut = max(0, queueBytesOut - data.count)
        onLog?(.init(level: .trace, message: "Socket sent", detail: "size=\(data.count) totalOut=\(totalBytesOut)"))
        isSending = false
        if !sendBuffer.isEmpty {
            flushSendBuffer()
        }
        if let error {
            logger.error("Failed to send data:", error)
            close(error as? NWError)
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
