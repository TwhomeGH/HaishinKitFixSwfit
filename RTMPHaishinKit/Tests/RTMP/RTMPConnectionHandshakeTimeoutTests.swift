import Foundation
import Network
import Testing

@testable import RTMPHaishinKit

/// 本機 TCP 整合測試：先證明進入指定握手階段，再檢查逾時。
/// 序列執行避免同套件的網路／日誌工作互相擠壓；不依賴固定日誌等待時間。
@Suite("RTMPConnection：握手分階段逾時", .serialized)
struct RTMPConnectionHandshakeTimeoutTests {
    private final class Evidence: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        private var startedAt: ContinuousClock.Instant?
        func add(_ text: String) {
            lock.lock(); defer { lock.unlock() }
            lines.append(text)
        }
        func enteredStage(_ stage: String) {
            lock.lock(); defer { lock.unlock() }
            startedAt = ContinuousClock().now
            lines.append(stage)
        }
        func snapshot() -> (text: String, start: ContinuousClock.Instant?) {
            lock.lock(); defer { lock.unlock() }
            return (lines.joined(separator: "\n"), startedAt)
        }
    }

    /// 所有 listener／connection 狀態只在 queue 存取，cleanup 解除回呼並取消連線。
    private final class Server: @unchecked Sendable {
        let listener: NWListener
        let evidence = Evidence()
        private let queue = DispatchQueue(label: "test.rtmp.handshake.server")
        private var connections: [NWConnection] = []
        private var readyPort: UInt16?
        private var failure: NWError?
        private let sendS0S1: Bool

        init(sendS0S1: Bool) throws {
            self.sendS0S1 = sendS0S1
            listener = try NWListener(using: .tcp, on: .any)
        }

        func start() async throws -> UInt16 {
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready: self.readyPort = self.listener.port?.rawValue
                case .failed(let error): self.failure = error
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                self.connections.append(connection)
                connection.stateUpdateHandler = { [weak self, weak connection] state in
                    guard let self, let connection else { return }
                    if case .ready = state { self.receiveC0C1(connection) }
                    if case .failed(let error) = state { self.evidence.add("server failed: \(error)") }
                }
                connection.start(queue: self.queue)
            }
            listener.start(queue: queue)
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(5))
            do {
                while clock.now < deadline {
                    let state = queue.sync { (readyPort, failure) }
                    if let error = state.1 { throw error }
                    if let port = state.0 { return port }
                    try await Task.sleep(for: .milliseconds(10))
                }
                throw NWError.posix(.ETIMEDOUT)
            } catch {
                stop()
                throw error
            }
        }

        private func receiveC0C1(_ connection: NWConnection) {
            connection.receive(minimumIncompleteLength: 1537, maximumLength: 1537) { [weak self] data, _, _, error in
                guard let self else { return }
                guard error == nil, let data, data.count == 1537, data.first == 3 else {
                    self.evidence.add("invalid C0C1 bytes=\(data?.count ?? 0) error=\(String(describing: error))")
                    return
                }
                guard self.sendS0S1 else {
                    self.evidence.enteredStage("received C0C1")
                    return
                }
                var response = Data([3])
                response.append(Data(repeating: 0, count: 1536))
                connection.send(content: response, completion: .contentProcessed { [weak self] error in
                    if let error { self?.evidence.add("S0S1 send failed: \(error)") }
                })
                connection.receive(minimumIncompleteLength: 1536, maximumLength: 1536) { [weak self] data, _, _, error in
                    guard error == nil, data?.count == 1536 else {
                        self?.evidence.add("invalid C2 bytes=\(data?.count ?? 0) error=\(String(describing: error))")
                        return
                    }
                    self?.evidence.enteredStage("received C2")
                    // 刻意不傳 S2，使客戶端只可能停在 waiting S2。
                }
            }
        }

        func stop() {
            queue.sync {
                listener.stateUpdateHandler = nil
                listener.newConnectionHandler = nil
                listener.cancel()
                for connection in connections {
                    connection.stateUpdateHandler = nil
                    connection.cancel()
                }
                connections.removeAll()
            }
        }
    }

    private func verifyTimeout(sendS0S1: Bool, stage: String) async throws {
        let server = try Server(sendS0S1: sendS0S1)
        let port = try await server.start()
        defer { server.stop() }
        let logs = Evidence()
        // connect 回應逾時拉開距離，保留 CI 排程餘裕但仍能辨別錯用整體逾時。
        let connection = RTMPConnection(timeout: 30, handshakeTimeout: 2, minimumLogLevel: .error)
        await connection.setOnLog { logs.add("\($0.message) \($0.detail ?? "")") }
        var thrown: (any Error)?
        do { _ = try await connection.connect("rtmp://127.0.0.1:\(port)/app/inst") }
        catch { thrown = error }
        let completedAt = ContinuousClock().now
        try? await connection.close()

        // 等待實際目標事件，最多兩秒；未到指定階段時直接留下原始錯誤與伺服器證據。
        let deadline = ContinuousClock().now.advanced(by: .seconds(2))
        while !logs.snapshot().text.contains("stage=\(stage)"), ContinuousClock().now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let serverState = server.evidence.snapshot()
        let detail = "error=\(String(describing: thrown))\nserver:\n\(serverState.text)\nclient:\n\(logs.snapshot().text)"
        let entered = try #require(serverState.start, "未進入預期握手階段；\(detail)")
        let typed = try #require(thrown as? RTMPConnection.Error, "非 RTMP 握手錯誤；\(detail)")
        if case .requestTimedOut = typed {} else { Issue.record("預期 requestTimedOut；\(detail)") }
        let elapsed = entered.duration(to: completedAt)
        #expect(elapsed >= .seconds(1) && elapsed < .seconds(12), "階段耗時 \(elapsed)；\(detail)")
        #expect(logs.snapshot().text.contains("stage=\(stage)"), "\(detail)")
    }

    @Test("等不到 S0S1：握手逾時並標明 waiting S0S1")
    func timesOutWaitingForS0S1() async throws {
        try await verifyTimeout(sendS0S1: false, stage: "waiting S0S1")
    }

    @Test("已收到 C2 但不回 S2：握手逾時並標明 waiting S2")
    func timesOutWaitingForS2() async throws {
        try await verifyTimeout(sendS0S1: true, stage: "waiting S2")
    }
}
