import Foundation

/// Pure keepalive state machine for the RTMP client.
///
/// Deliberately free of AVFoundation / Network so it can be unit-tested (and
/// compiled standalone on non-Apple platforms). `RTMPConnection` drives it from
/// its 1s tick and from received pongs, and acts on the returned `Decision`.
///
/// Purpose: an idle TCP flow can be reaped by NAT / carrier gateways at ~60s,
/// and a half-open link (radio drop) never errors `NWConnection`. Sending a
/// User Control PingRequest every `interval` seconds keeps the path warm and,
/// once the peer answers with a PongResponse, gives a positive liveness signal
/// that detects a dead link even when the app has nothing to publish.
///
/// A peer that never answers pings is never declared dead: after
/// `maxUnansweredProbes` consecutive unanswered probes, pong-based death
/// detection is disabled and probes keep being sent (NAT keepalive only).
struct RTMPKeepAlive {
    enum Decision: Equatable {
        case none
        /// Send a User Control PingRequest carrying this value.
        case probe(Int32)
        /// The link is dead: close the socket and let the reconnect path run.
        case declareDead
        /// The peer never answered `maxUnansweredProbes` consecutive probes;
        /// pong-based death detection is now disabled.
        case disablePongDetection
    }

    let interval: TimeInterval
    let pongTimeout: TimeInterval
    let maxUnansweredProbes: Int

    /// Monotonically increasing probe value (wraps).
    private(set) var value: Int32 = 0
    private(set) var unansweredProbes = 0
    /// nil = unknown (no pong yet), true = peer answers pings (a probe timeout
    /// is a real death signal), false = peer does not answer (kill disabled).
    private(set) var pongSupported: Bool?

    private var lastProbeSentAt: Date = .distantPast
    private var pendingProbeSentAt: Date?
    /// Inbound byte count when the pending probe was sent. Any advance proves
    /// the link is alive even if the peer never sends a PongResponse.
    private var bytesInAtProbe = 0

    init(interval: TimeInterval = 20, pongTimeout: TimeInterval = 5, maxUnansweredProbes: Int = 3) {
        self.interval = interval
        self.pongTimeout = pongTimeout
        self.maxUnansweredProbes = maxUnansweredProbes
    }

    /// Resets for a fresh connection. `lastProbeSentAt = now` means the first
    /// probe is sent one `interval` after connect.
    mutating func reset(now: Date) {
        value = 0
        unansweredProbes = 0
        pongSupported = nil
        lastProbeSentAt = now
        pendingProbeSentAt = nil
        bytesInAtProbe = 0
    }

    /// A PongResponse (or any proof the peer answered) arrived.
    mutating func onPong() {
        pongSupported = true
        unansweredProbes = 0
        pendingProbeSentAt = nil
    }

    /// Called once per tick with the current time and the latest inbound byte
    /// count (from the network monitor).
    mutating func tick(now: Date, inboundBytes: Int) -> Decision {
        if let sentAt = pendingProbeSentAt {
            guard now.timeIntervalSince(sentAt) >= pongTimeout else {
                return .none
            }
            pendingProbeSentAt = nil
            if inboundBytes != bytesInAtProbe {
                // Any inbound since the probe proves the link is alive; a
                // specific pong is not required.
                unansweredProbes = 0
            } else if pongSupported == true {
                return .declareDead
            } else if pongSupported != false {
                // Still probing whether the peer answers at all.
                unansweredProbes += 1
                if maxUnansweredProbes <= unansweredProbes {
                    pongSupported = false
                    return .disablePongDetection
                }
            }
            // pongSupported == false: death detection already disabled; fall
            // through so the next probe cadence is evaluated (no repeat events).
        }
        guard now.timeIntervalSince(lastProbeSentAt) >= interval else {
            return .none
        }
        lastProbeSentAt = now
        pendingProbeSentAt = now
        bytesInAtProbe = inboundBytes
        value = value &+ 1
        return .probe(value)
    }
}
