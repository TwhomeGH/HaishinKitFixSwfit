// Verification of RTMPKeepAlive (RTMPHaishinKit/Sources/RTMP/RTMPKeepAlive.swift)
// on non-Apple platforms. Compiled together with the real source file so the
// shipped state machine is what gets exercised:
//
//   swiftc RTMPHaishinKit/Sources/RTMP/RTMPKeepAlive.swift \
//          .cortexkit/verify-keepalive.swift -o .cortexkit/verify-keepalive.exe
//
// Covers: idle probe cadence, pong liveness, inbound-only liveness,
// pong-based death, and the "server ignores pings" fallback.
import Foundation

var failures = 0
func expect(_ cond: Bool, _ name: String) {
    if cond {
        print("  ok   \(name)")
    } else {
        failures += 1
        print("  FAIL \(name)")
    }
}

@main
struct VerifyKeepAlive {
    static func main() {
        let t0 = Date(timeIntervalSinceReferenceDate: 0)

        // 1. No probe before the interval; first probe at the interval.
        do {
            var k = RTMPKeepAlive(interval: 20, pongTimeout: 5, maxUnansweredProbes: 3)
            k.reset(now: t0)
            expect(k.tick(now: t0.addingTimeInterval(19), inboundBytes: 0) == .none, "no probe before interval")
            expect(k.tick(now: t0.addingTimeInterval(20), inboundBytes: 0) == .probe(1), "probe(1) at interval")
        }

        // 2. Pong makes the link alive; a later probe is not a death.
        do {
            var k = RTMPKeepAlive(interval: 20, pongTimeout: 5, maxUnansweredProbes: 3)
            k.reset(now: t0)
            _ = k.tick(now: t0.addingTimeInterval(20), inboundBytes: 0) // probe(1)
            k.onPong()
            expect(k.pongSupported == true, "pong => supported")
            // Probe timed out but a pong arrived: never dead.
            expect(k.tick(now: t0.addingTimeInterval(26), inboundBytes: 0) == .none, "no death after pong")
            expect(k.tick(now: t0.addingTimeInterval(40), inboundBytes: 0) == .probe(2), "probe(2) next interval")
        }

        // 3. Pong-capable peer that stops answering => declareDead.
        do {
            var k = RTMPKeepAlive(interval: 20, pongTimeout: 5, maxUnansweredProbes: 3)
            k.reset(now: t0)
            _ = k.tick(now: t0.addingTimeInterval(20), inboundBytes: 0) // probe(1)
            k.onPong()
            _ = k.tick(now: t0.addingTimeInterval(40), inboundBytes: 0) // probe(2)
            // No inbound and no pong within pongTimeout => dead.
            expect(k.tick(now: t0.addingTimeInterval(45), inboundBytes: 0) == .declareDead, "declareDead on pong timeout")
        }

        // 4. Inbound-only liveness (no pong): a probe that sees inbound bytes is
        //    NOT dead, even though pongSupported is still nil.
        do {
            var k = RTMPKeepAlive(interval: 20, pongTimeout: 5, maxUnansweredProbes: 3)
            k.reset(now: t0)
            _ = k.tick(now: t0.addingTimeInterval(20), inboundBytes: 1000) // probe(1)
            expect(k.tick(now: t0.addingTimeInterval(25), inboundBytes: 2000) == .none, "inbound proves alive")
            expect(k.unansweredProbes == 0, "inbound resets unanswered")
        }

        // 5. Peer ignores pings: after maxUnansweredProbes, pong detection is
        //    disabled and the link is never declared dead (probes keep going).
        do {
            var k = RTMPKeepAlive(interval: 20, pongTimeout: 5, maxUnansweredProbes: 3)
            k.reset(now: t0)
            var t = t0
            func probe(_ k: inout RTMPKeepAlive) { t = t.addingTimeInterval(20); _ = k.tick(now: t, inboundBytes: 0) }
            func timeout(_ k: inout RTMPKeepAlive) -> RTMPKeepAlive.Decision { t = t.addingTimeInterval(5); return k.tick(now: t, inboundBytes: 0) }

            probe(&k); expect(timeout(&k) == .none, "1st unanswered => none")
            probe(&k); expect(timeout(&k) == .none, "2nd unanswered => none")
            probe(&k); expect(timeout(&k) == .disablePongDetection, "3rd unanswered => disable")
            expect(k.pongSupported == false, "pong detection disabled")
            // Further timeouts never declare dead.
            probe(&k); expect(timeout(&k) == .none, "after disable: no death")
            probe(&k); expect(timeout(&k) == .none, "after disable: still no death")
        }

        // 6. reset zeroes everything.
        do {
            var k = RTMPKeepAlive(interval: 20, pongTimeout: 5, maxUnansweredProbes: 3)
            k.reset(now: t0)
            _ = k.tick(now: t0.addingTimeInterval(20), inboundBytes: 0)
            k.onPong()
            k.reset(now: t0)
            expect(k.value == 0 && k.unansweredProbes == 0 && k.pongSupported == nil, "reset clears state")
            expect(k.tick(now: t0.addingTimeInterval(20), inboundBytes: 0) == .probe(1), "value restarts at 1")
        }

        print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
        exit(failures == 0 ? 0 : 1)
    }
}
