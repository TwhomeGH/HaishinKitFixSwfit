import Foundation
import HaishinKit
import Network

final actor RTMPSocket {
    static let defaultWindowSizeC = Int(UInt16.max)
    static let maxQueueBytesOut = 15 * 1024 * 1024
    private static let sendChunkSize = 64 * 1024

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
    private var sendBuffer = Data()
    private var sendOffset = 0
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

    private func scheduleReconnect(after delay: TimeInterval = 2.0) {
        Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            do {
                
                try await connect(RTMPURL, port: RTMPPort)

            } catch {
                onLog?(.init(level: .error, message: "Reconnect failed", detail: "\(error)"))
                scheduleReconnect(after: min(delay * 2, 30)) // 指數退避
            }
        }
    }


    var RTMPURL:String = "example.com"
    var RTMPPort:Int = 1935

    func connect(_ name: String, port: Int) async throws {
        guard !connected else {
            throw Error.invalidState
        }
        sendBuffer.removeAll()
        sendOffset = 0
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

        if sendBuffer.count + data.count > Self.maxQueueBytesOut {
            let excess = (sendBuffer.count + data.count) - Self.maxQueueBytesOut
            let dropSize = min(sendBuffer.count, excess)
            sendBuffer.removeFirst(dropSize)
            onLog?(.init(level: .warn, message: "Backpressure: dropped oldest", detail: "dropSize=\(dropSize)"))
        }

        sendBuffer.append(data)
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
        sendOffset = 0
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
            onLog?(.init(level: .info, message: "Socket ready \(RTMPURL):\(RTMPPort)", detail: "totalBytesIn=\(totalBytesIn) totalBytesOut=\(totalBytesOut) buffer=\(sendBuffer.count)"))
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

            scheduleReconnect(after: 2.0) // 嘗試重新連線
        case .cancelled:
            logger.info("Connection cancelled.")
            onLog?(.init(level: .info, message: "Socket cancelled"))
            close(NWError.posix(.ECONNABORTED))

            scheduleReconnect(after: 2.0)


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
            sendBuffer.removeAll()
            sendOffset = 0
            return
        }
        let available = sendBuffer.count - sendOffset
        let chunkSize = min(Self.sendChunkSize, available)
        let chunk = sendBuffer.subdata(in: sendOffset..<sendOffset + chunkSize)
        sendOffset += chunkSize
        isSending = true
        connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            Task { await self.didSendChunk(chunkSize, error: error) }
        })
    }

    private func didSendChunk(_ size: Int, error: NWError?) {
        totalBytesOut += size
        if sendOffset >= sendBuffer.count / 2 {
            sendBuffer.removeSubrange(0..<sendOffset)
            sendOffset = 0
        }
        isSending = false
        if sendOffset < sendBuffer.count {
            sendNextChunk()
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
        return .init(queueBytesOut: sendBuffer.count, totalBytesIn: totalBytesIn, totalBytesOut: totalBytesOut)
    }
}
