import Foundation
import Testing

@testable import RTMPHaishinKit

/// `RTMPKeepAlive` 的行為驗證：idle 探測節奏、pong / inbound 存活、pong 死線、
/// 以及「server 不理 ping」的 fallback（永不誤殺）。對應 CHANGES #56b。
/// 同一組案例也有非 Apple 平台的獨立驗證腳本 `.cortexkit/verify-keepalive.swift`。
@Suite("RTMPKeepAlive：閒置探測與死線判定")
struct RTMPKeepAliveTests {
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

    @Test("pong-capable peer 停止回應 → declareDead")
    func declaresDeadAfterPongStops() {
        var keepAlive = Self.make()
        keepAlive.reset(now: Self.t0)
        _ = keepAlive.tick(now: Self.t0.addingTimeInterval(20), inboundBytes: 0)
        keepAlive.onPong()
        _ = keepAlive.tick(now: Self.t0.addingTimeInterval(40), inboundBytes: 0)
        #expect(keepAlive.tick(now: Self.t0.addingTimeInterval(45), inboundBytes: 0) == .declareDead)
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
