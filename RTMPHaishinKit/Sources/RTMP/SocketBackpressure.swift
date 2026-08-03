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
/// frame. All state transitions use hysteresis to avoid boundary chatter.
final class SocketBackpressure: @unchecked Sendable {
    // Thresholds (relative to RTMPSocket.maxQueueBytesOut = 2MB).
    // Level 1 — video throttle (drop ~1/2 raw frames) while the 1Hz bitrate
    //           adaptation catches up. Engages at the same 512KB the
    //           NetworkMonitor uses to trigger bitrate reduction.
    static let videoThrottleOn = 512 * 1024
    static let videoThrottleOff = 128 * 1024
    // Level 2 — video full stop: encoder pauses until the queue drains.
    static let videoStopOn = 1024 * 1024
    static let videoStopOff = 512 * 1024
    // Level 3 — audio full stop: production halts entirely.
    static let audioStopOn = 1280 * 1024
    static let audioStopOff = 1024 * 1024

    private let lock = NSLock()
    private var queueBytes = 0
    private var videoThrottleActive = false
    private var videoStopActive = false
    private var audioStopActive = false
    private var videoCounter = 0
    /// Dynamically computed OOM guard limit, scaled by video bitrate (see
    /// `updateVideoSettings`). Never below RTMPSocket.maxQueueBytesOut.
    private var computedOOMGuardLimit = RTMPSocket.maxQueueBytesOut

    /// Current pending send queue bytes (for diagnostics).
    var queueBytesCurrent: Int {
        lock.lock()
        defer { lock.unlock() }
        return queueBytes
    }

    /// Hard send-queue cap enforced by RTMPSocket. Sized to L3 + the largest
    /// plausible in-flight keyframe + margin, so a big keyframe still flowing
    /// when the throttle triggers is absorbed instead of shed by the guard.
    /// Normal operation never reaches it — the throttle thresholds stop
    /// production first.
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
        let computed = Self.audioStopOn + max(256 * 1024, keyframeBudget) + 256 * 1024
        computedOOMGuardLimit = min(8 * 1024 * 1024, computed)
        lock.unlock()
    }

    /// Video is being throttled or fully stopped.
    var isVideoThrottled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return videoThrottleActive || videoStopActive
    }

    /// Production is halted (video or audio full stop) — pipeline stall is
    /// deliberate, so the stall-detector must not restart the pipeline.
    var isStalling: Bool {
        lock.lock()
        defer { lock.unlock() }
        return videoStopActive || audioStopActive
    }

    /// Publish the socket's current pending-send queue size.
    func update(queueBytes: Int) {
        lock.lock()
        self.queueBytes = queueBytes
        if videoStopActive {
            if queueBytes < Self.videoStopOff {
                videoStopActive = false
                videoCounter = 0
            }
        } else if Self.videoStopOn <= queueBytes {
            videoStopActive = true
        }
        if audioStopActive {
            if queueBytes < Self.audioStopOff {
                audioStopActive = false
            }
        } else if Self.audioStopOn <= queueBytes {
            audioStopActive = true
        }
        if videoThrottleActive {
            if queueBytes < Self.videoThrottleOff {
                videoThrottleActive = false
                videoCounter = 0
            }
        } else if Self.videoThrottleOn <= queueBytes {
            videoThrottleActive = true
        }
        lock.unlock()
    }

    /// Reset all state (new connection / socket close).
    func reset() {
        lock.lock()
        queueBytes = 0
        videoThrottleActive = false
        videoStopActive = false
        audioStopActive = false
        videoCounter = 0
        lock.unlock()
    }

    /// Returns true when this incoming raw video frame should be skipped
    /// (dropped before encoding). Smooth ~50% fps cut during throttle, full
    /// stop during stall — never breaks the encoded GOP.
    func shouldDropVideoFrame() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if videoStopActive {
            return true
        }
        if videoThrottleActive {
            videoCounter += 1
            return videoCounter % 2 == 0
        }
        videoCounter = 0
        return false
    }

    /// Returns true when this incoming raw audio buffer should be skipped.
    /// Audio is small, so it only drops at the full-stop level — halting
    /// audio production entirely so the queue never reaches the OOM guard.
    func shouldDropAudioFrame() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return audioStopActive
    }
}
