import Foundation
import Network
import Testing

@testable import RTMPHaishinKit

/// 握手分階段逾時（P1）：TCP 接通但伺服器卡在某一階段時，必須在該階段的
/// `handshakeTimeout`（等 S0S1／等 S2）或 `timeout`（等 connect 回應）內失敗，
/// 且逾時訊息帶上階段名，方便遠端 log 判讀。
@Suite("RTMPConnection：握手分階段逾時")
struct RTMPConnectionHandshakeTimeoutTests {
    /// 執行緒安全的 log 收集器（onLog 為 @Sendable，可能來自其他執行緒）。
    private final class LogBox: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func add(_ line: String) {
            lock.lock(); lines.append(line); lock.unlock()
        }
        func joined() -> String {
            lock.lock(); defer { lock.unlock() }
            return lines.joined(separator: "\n")
        }
    }

    /// 保留 server 端已接受的連線。**必須保留**：`newConnectionHandler` 給的
    /// `NWConnection` 若無人持有會被釋放，TCP 連線隨之拆除，客戶端的
    /// `RTMPSocket.connect` 便永遠等不到 `.ready`，直到它自己的 15s 逾時。
    private final class ServerConnections: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [NWConnection] = []
        func retain(_ connection: NWConnection) {
            lock.lock(); items.append(connection); lock.unlock()
        }
        func cancelAll() {
            lock.lock(); items.forEach { $0.cancel() }; items.removeAll(); lock.unlock()
        }
    }

    private static func isRequestTimedOut(_ error: RTMPConnection.Error?) -> Bool {
        guard let error else { return false }
        if case .requestTimedOut = error { return true }
        return false
    }

    /// 接受 TCP 連線，並在連線 `.ready` 後呼叫 `respond`；回傳可用的 port 與連線持有盒。
    private func startListener(
        _ respond: @escaping @Sendable (NWConnection) -> Void
    ) async throws -> (listener: NWListener, port: UInt16, connections: ServerConnections) {
        let listener = try NWListener(using: .tcp, on: .any)
        let connections = ServerConnections()
        listener.newConnectionHandler = { connection in
            connections.retain(connection)
            connection.stateUpdateHandler = { state in
                if case .ready = state { respond(connection) }
            }
            connection.start(queue: .global())
        }
        listener.start(queue: .global())
        for _ in 0..<200 {
            if let port = listener.port { return (listener, port.rawValue, connections) }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        listener.cancel()
        throw NWError.posix(.ETIMEDOUT)
    }

    private func connectExpectingTimeout(
        port: UInt16,
        handshakeTimeout: Int,
        timeout: Int
    ) async throws -> (error: RTMPConnection.Error?, elapsed: Duration, logs: String) {
        let connection = RTMPConnection(timeout: timeout, handshakeTimeout: handshakeTimeout, minimumLogLevel: .error)
        let box = LogBox()
        await connection.setOnLog { event in
            box.add("\(event.message) \(event.detail ?? "")")
        }
        let clock = ContinuousClock()
        let start = clock.now
        var thrown: (any Error)?
        do {
            _ = try await connection.connect("rtmp://127.0.0.1:\(port)/app/inst")
            Issue.record("預期在握手階段逾時，但 connect 成功")
        } catch {
            thrown = error
        }
        let elapsed = start.duration(to: clock.now)
        try? await connection.close()
        // onLog 以非同步 Task 投遞，給它一點時間。
        try? await Task.sleep(nanoseconds: 300_000_000)
        let typed = thrown as? RTMPConnection.Error
        return (typed, elapsed, box.joined())
    }

    @Test("等不到 S0S1：以 handshakeTimeout 逾時，訊息帶 waiting S0S1")
    func timesOutWaitingForS0S1() async throws {
        // TCP 接受連線但完全不送資料 → 卡在等 S0S1。
        let server = try await startListener { _ in }
        defer {
            server.listener.cancel()
            server.connections.cancelAll()
        }

        // handshakeTimeout(1s) 應先於 timeout(5s) 觸發。
        let result = try await connectExpectingTimeout(port: server.port, handshakeTimeout: 1, timeout: 5)

        #expect(Self.isRequestTimedOut(result.error))
        #expect(result.elapsed < .seconds(4))
        #expect(result.logs.contains("stage=waiting S0S1"), "log: \(result.logs)")
    }

    @Test("等到 S0S1 但等不到 S2：逾時訊息帶 waiting S2")
    func timesOutWaitingForS2() async throws {
        // 送 S0 + S1（version 3 + 1536 bytes）後不再送 S2。
        let server = try await startListener { connection in
            var s0s1 = Data([0x03])
            s0s1.append(Data(repeating: 0x00, count: 1536))
            connection.send(content: s0s1, completion: .contentProcessed { _ in })
        }
        defer {
            server.listener.cancel()
            server.connections.cancelAll()
        }

        let result = try await connectExpectingTimeout(port: server.port, handshakeTimeout: 1, timeout: 5)

        #expect(Self.isRequestTimedOut(result.error))
        #expect(result.elapsed < .seconds(4))
        #expect(result.logs.contains("stage=waiting S2"), "log: \(result.logs)")
    }
}
