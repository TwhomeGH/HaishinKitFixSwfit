import Foundation
import Network
import Testing

@testable import RTMPHaishinKit

/// 一次性 resume 防護：listener 狀態回呼與 backstop 可能同時觸發，
/// 以鎖保證 continuation 只被 resume 一次。
private final class OneShotResume: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UInt16, any Error>?

    init(_ continuation: CheckedContinuation<UInt16, any Error>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<UInt16, any Error>) {
        lock.lock(); defer { lock.unlock() }
        guard let c = continuation else { return }
        continuation = nil
        c.resume(with: result)
    }
}

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
        private var waitingError: NWError?
        private let sendS0S1: Bool

        init(sendS0S1: Bool) throws {
            self.sendS0S1 = sendS0S1
            listener = try NWListener(using: .tcp, on: .any)
        }

        func start() async throws -> UInt16 {
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                self.connections.append(connection)
                connection.stateUpdateHandler = { [weak self, weak connection] state in
                    guard let self, let connection else { return }
                    if case .ready = state {
                        self.evidence.add("server ready")
                        // S0S1 情境刻意保持沉默，也不要求 server 端消費 C0C1。
                        if self.sendS0S1 { self.receiveC0C1(connection) }
                    }
                    if case .failed(let error) = state { self.evidence.add("server failed: \(error)") }
                }
                connection.start(queue: self.queue)
            }
            // 事件驅動：ready 立即回傳（不猜固定秒數）；失敗回報真實 NWError。
            // 不再用「固定 deadline + 輪詢」決定成敗——那會把排程延遲誤判為失敗，
            // 且逾時只丟合成的 ETIMEDOUT，看不到真正原因。backstop 僅為避免無限等待，
            // 且優先回報實際的 waiting 原因。
            do {
                return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, any Error>) in
                    let oneShot = OneShotResume(continuation)
                    listener.stateUpdateHandler = { [weak self] state in
                        guard let self else { return }
                        switch state {
                        case .ready:
                            guard let port = self.listener.port?.rawValue else {
                                oneShot.resume(.failure(NWError.posix(.EINVAL)))
                                return
                            }
                            self.readyPort = port
                            oneShot.resume(.success(port))
                        case .failed(let error):
                            self.failure = error
                            oneShot.resume(.failure(error))
                        case .waiting(let error):
                            self.waitingError = error
                        default:
                            break
                        }
                    }
                    listener.start(queue: queue)
                    Task { [weak self] in
                        try? await Task.sleep(for: .seconds(30))
                        guard let self else { return }
                        oneShot.resume(.failure(self.waitingError ?? NWError.posix(.ETIMEDOUT)))
                    }
                }
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
        await connection.setOnLog { event in
            logs.add("\(event.message) \(event.detail ?? "")")
            // 沉默 peer 的逾時由 client 計時；不能要求 peer 的 receive callback 先執行。
            if !sendS0S1, event.message == "TCP connected, sending C0C1" {
                logs.enteredStage("client entered S0S1 handshake")
            }
        }
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
        let stageStart = sendS0S1 ? serverState.start : logs.snapshot().start
        let entered = try #require(stageStart, "未進入預期握手階段；\(detail)")
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
