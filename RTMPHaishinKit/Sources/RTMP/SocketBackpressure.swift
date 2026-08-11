import Foundation

/// Non-isolated, lock-protected view of the socket's pending send queue.
///
/// The camera/audio intake path (nonisolated, runs on the mixer callback thread)
/// uses this to check network congestion *before* a raw frame reaches the
/// encoder — the only safe place to shed load without breaking the encoded
/// stream (dropping RTMP messages mid-stream corrupts the GOP / A/V sync).
///
/// The socket publishes `update(queueBytes:)` on every enqueue/dequeue; the
/// intake path asks `shouldDropVideoFrame()` / `shouldDropAudioFrame()` per
/// frame.
///
/// # Design (2026-08): continuous degradation, audio never shed
///
/// The previous three-level design (50% video throttle → 100% video stop →
/// 100% audio stop) caused visible freeze spikes: video production halted
/// entirely at 1MB and stayed dark until the queue drained, producing seconds
/// of frozen picture (and A/V desync that the player interprets as audio
/// stutter). With send coalescing in `RTMPSocket`, the queue only grows under
/// genuine congestion, so the signal is now a *continuous drop ratio*:
///
/// - Video drop ratio ramps smoothly 0% → ~90% as the queue fills, so the
///   stream degrades 60 → 30 → 15 → 6 fps instead of freezing to 0.
/// - Audio is never shed. It is tiny (~100 kbps) relative to video and is the
///   A/V sync anchor; dropping it saves almost nothing while breaking sync.
/// - The OOM guard remains the last line against runaway queues.
final class SocketBackpressure: @unchecked Sendable {
    // Continuous video drop-ratio ramp.
    // Below `videoDropStart` the link is healthy — no frames dropped.
    // Between start and `videoDropEnd` the ratio ramps linearly up to
    // `videoDropMax` (never 1.0: the encoder must keep producing so the
    // timeline advances and the stall detector stays quiet).
    static let videoDropStart = 256 * 1024
    static let videoDropEnd = 1536 * 1024
    static let videoDropMax = 0.9

    private let lock = NSLock()
    private var queueBytes = 0
    private var dropAccumulator = 0.0
    /// Dynamically computed OOM guard limit, scaled by video bitrate (see
    /// `updateVideoSettings`). Never below RTMPSocket.maxQueueBytesOut.
    private var computedOOMGuardLimit = RTMPSocket.maxQueueBytesOut

    /// Current pending send queue bytes (for diagnostics).
    var queueBytesCurrent: Int {
        lock.lock()
        defer { lock.unlock() }
        return queueBytes
    }

    /// Hard send-queue cap enforced by RTMPSocket. Sized to absorb the largest
    /// plausible in-flight keyframe + margin, so a big keyframe still flowing
    /// when the throttle triggers is absorbed instead of shed by the guard.
    /// Normal operation never reaches it — the ramp stops production first.
    var oomGuardLimit: Int {
        lock.lock()
        defer { lock.unlock() }
        return max(RTMPSocket.maxQueueBytesOut, computedOOMGuardLimit)
    }

    /// Feed the current video encoding parameters so the OOM guard can absorb
    /// the largest plausible keyframe. Call whenever videoSettings change
    /// (user config or bitrate adaptation).
    func updateVideoSettings(bitRate: Int, maxKeyFrameInterval: Int32) {
        lock.lock()
        let gopSeconds = Double(maxKeyFrameInterval > 0 ? maxKeyFrameInterval : 2)
        // Bytes in one full GOP; the I-frame typically carries ~35% of it.
        let gopBytes = Double(max(bitRate, 0)) / 8.0 * gopSeconds
        let keyframeBudget = Int(gopBytes * 0.35)
        let computed = Self.videoDropEnd + max(256 * 1024, keyframeBudget) + 256 * 1024
        computedOOMGuardLimit = min(8 * 1024 * 1024, computed)
        lock.unlock()
    }

    /// Video is being degraded (any non-zero drop ratio).
    var isVideoThrottled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return currentDropRatioLocked() > 0
    }

    /// Production is degraded enough that reduced output is deliberate — the
    /// stall-detector must not restart the pipeline over it.
    var isStalling: Bool {
        lock.lock()
        defer { lock.unlock() }
        return currentDropRatioLocked() >= 0.5
    }

    /// Publish the socket's current pending-send queue size.
    func update(queueBytes: Int) {
        lock.lock()
        self.queueBytes = queueBytes
        lock.unlock()
    }

    /// Reset all state (new connection / socket close).
    func reset() {
        lock.lock()
        queueBytes = 0
        dropAccumulator = 0
        lock.unlock()
    }

    /// Returns true when this incoming raw video frame should be skipped
    /// (dropped before encoding). The drop ratio ramps continuously with the
    /// queue fill: 0% on a healthy link, ~90% under heavy congestion. A
    /// Bresenham-style accumulator turns the float ratio into an exact
    /// long-run drop rate (ratio 0.9 → keep 1 of 10; 0.05 → keep 19 of 20)
    /// without the quantization jump a fixed counter would introduce at low
    /// ratios. The encoder always keeps producing (never 100%), so the
    /// timeline advances and A/V sync is preserved.
    func shouldDropVideoFrame() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let ratio = currentDropRatioLocked()
        guard ratio > 0 else {
            dropAccumulator = 0
            return false
        }
        dropAccumulator += ratio
        if dropAccumulator >= 1.0 {
            dropAccumulator -= 1.0
            return true
        }
        return false
    }

    /// Returns true when this incoming raw audio buffer should be skipped.
    /// Always false — audio is never shed. It is small (~100 kbps) and is the
    /// A/V sync anchor; dropping it saves negligible queue space while causing
    /// audible stutter via desync.
    func shouldDropAudioFrame() -> Bool {
        return false
    }

    /// Linear drop ratio in `videoDropStart..<videoDropEnd`, clamped to
    /// `videoDropMax`. Caller must hold `lock`.
    private func currentDropRatioLocked() -> Double {
        let span = Self.videoDropEnd - Self.videoDropStart
        guard span > 0, queueBytes > Self.videoDropStart else {
            return 0
        }
        let t = Double(min(queueBytes, Self.videoDropEnd) - Self.videoDropStart) / Double(span)
        return t * Self.videoDropMax
    }
}
