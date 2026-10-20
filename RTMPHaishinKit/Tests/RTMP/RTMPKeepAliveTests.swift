import Foundation
import Testing

@testable import RTMPHaishinKit

/// `RTMPKeepAlive` 的行為驗證：idle 探測節奏、pong / inbound 存活、pong 死線、
/// 以及「server 不理 ping」的 fallback（永不誤殺）。對應 CHANGES #56b。
/// 同一組案例也有非 Apple 平台的獨立驗證腳本 `.cortexkit/verify-keepalive.swift`。
@Suite("RTMPKeepAlive：閒置探測與死線判定")
struct RTMPKeepAliveTests {
    /// 決策前保存快照，確保逾時清除 pending 後仍能解釋觸發依據。
    @Test func timeoutSnapshotPreservesProbeEvidence() {
        let start = Date(timeIntervalSince1970: 100)
        var heartbeat = RTMPKeepAlive()
        heartbeat.reset(now: start)
        _ = heartbeat.tick(now: start.addingTimeInterval(20), inboundBytes: 100)
        heartbeat.onPong()
        _ = heartbeat.tick(now: start.addingTimeInterval(40), inboundBytes: 200)
        let snapshot = heartbeat.diagnosticDescription(now: start.addingTimeInterval(45), inboundBytes: 200)
        let decision = heartbeat.tick(now: start.addingTimeInterval(45), inboundBytes: 200)
        #expect(snapshot.contains("pendingAgeSeconds=5.000"))
        #expect(snapshot.contains("pongSupported=true"))
        #expect(snapshot.contains("inboundAtProbe=200 inboundNow=200"))
        #expect(decision == .none)
        #expect(heartbeat.unansweredProbes == 1)
    }

    /// 探測間收到資料也應消除先前失敗；只有送出資料不參與此判定。
    @Test func inboundBetweenProbesClearsFailures() {
        var heartbeat = Self.make()
        heartbeat.reset(now: Self.t0)
        heartbeat.onPong()
        _ = heartbeat.tick(now: Self.t0.addingTimeInterval(20), inboundBytes: 0)
        _ = heartbeat.tick(now: Self.t0.addingTimeInterval(25), inboundBytes: 0)
        #expect(heartbeat.unansweredProbes == 1)
        _ = heartbeat.tick(now: Self.t0.addingTimeInterval(30), inboundBytes: 100)
        #expect(heartbeat.unansweredProbes == 0)
        _ = heartbeat.tick(now: Self.t0.addingTimeInterval(40), inboundBytes: 100)
        _ = heartbeat.tick(now: Self.t0.addingTimeInterval(44), inboundBytes: 200)
        let result = heartbeat.tick(now: Self.t0.addingTimeInterval(45), inboundBytes: 200)
        #expect(result == .none)
        #expect(heartbeat.unansweredProbes == 0)
    }

    private static let t0 = Date(timeIntervalSinceReferenceDate: 0)

    private static func make() -> RTMPKeepAlive {
        RTMPKeepAlive(interval: 20, pongTimeout: 5, maxUnansweredProbes: 3)
    }

    @Test("未達 interval 不送 probe，達 interval 送 probe(1)")
    func probesOnlyAfterInterval() {
        var keepAlive = Self.make()
        keepAlive.reset(now: Self.t0)
        #expect(keepAlive.tick(now: Self.t0.addingTimeInterval(19), inboundBytes: 0) == .none)
        #expect(keepAlive.tick(now: Self.t0.addingTimeInterval(20), inboundBytes: 0) == .probe(1))
    }

    @Test("收到 pong 後不判死，下一個 interval 再送 probe")
    func pongKeepsAlive() {
        var keepAlive = Self.make()
        keepAlive.reset(now: Self.t0)
        _ = keepAlive.tick(now: Self.t0.addingTimeInterval(20), inboundBytes: 0)
        keepAlive.onPong()
        #expect(keepAlive.pongSupported == true)
        #expect(keepAlive.tick(now: Self.t0.addingTimeInterval(26), inboundBytes: 0) == .none)
        #expect(keepAlive.tick(now: Self.t0.addingTimeInterval(40), inboundBytes: 0) == .probe(2))
    }

    @Test("曾回 pong 的對端連續三次無回應才判死")
    func declaresDeadAfterPongStops() {
        var keepAlive = Self.make()
        keepAlive.reset(now: Self.t0)
        _ = keepAlive.tick(now: Self.t0.addingTimeInterval(20), inboundBytes: 0)
        keepAlive.onPong()
        _ = keepAlive.tick(now: Self.t0.addingTimeInterval(40), inboundBytes: 0)
        let first = keepAlive.tick(now: Self.t0.addingTimeInterval(45), inboundBytes: 0)
        _ = keepAlive.tick(now: Self.t0.addingTimeInterval(60), inboundBytes: 0)
        let second = keepAlive.tick(now: Self.t0.addingTimeInterval(65), inboundBytes: 0)
        _ = keepAlive.tick(now: Self.t0.addingTimeInterval(80), inboundBytes: 0)
        let third = keepAlive.tick(now: Self.t0.addingTimeInterval(85), inboundBytes: 0)
        #expect(first == .none)
        #expect(second == .none)
        #expect(third == .declareDead)
    }

    @Test("只有 inbound（無 pong）也視為存活")
    func inboundProvesAlive() {
        var keepAlive = Self.make()
        keepAlive.reset(now: Self.t0)
        _ = keepAlive.tick(now: Self.t0.addingTimeInterval(20), inboundBytes: 1_000)
        #expect(keepAlive.tick(now: Self.t0.addingTimeInterval(25), inboundBytes: 2_000) == .none)
        #expect(keepAlive.unansweredProbes == 0)
    }

    @Test("連續 maxUnansweredProbes 無回應 → 停用 pong 死線，且不再誤殺")
    func disablesPongDetectionWhenPeerIgnoresPings() {
        var keepAlive = Self.make()
        keepAlive.reset(now: Self.t0)
        var now = Self.t0
        func probe() {
            now = now.addingTimeInterval(20)
            _ = keepAlive.tick(now: now, inboundBytes: 0)
        }
        func timeout() -> RTMPKeepAlive.Decision {
            now = now.addingTimeInterval(5)
            return keepAlive.tick(now: now, inboundBytes: 0)
        }

        probe(); #expect(timeout() == .none)
        probe(); #expect(timeout() == .none)
        probe(); #expect(timeout() == .disablePongDetection)
        #expect(keepAlive.pongSupported == false)
        probe(); #expect(timeout() == .none)
        probe(); #expect(timeout() == .none)
    }

    @Test("reset 清空狀態，value 從 1 重新開始")
    func resetClearsState() {
        var keepAlive = Self.make()
        keepAlive.reset(now: Self.t0)
        _ = keepAlive.tick(now: Self.t0.addingTimeInterval(20), inboundBytes: 0)
        keepAlive.onPong()
        keepAlive.reset(now: Self.t0)
        #expect(keepAlive.value == 0 && keepAlive.unansweredProbes == 0 && keepAlive.pongSupported == nil)
        #expect(keepAlive.tick(now: Self.t0.addingTimeInterval(20), inboundBytes: 0) == .probe(1))
    }
}
