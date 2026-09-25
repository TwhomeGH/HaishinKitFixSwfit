import Foundation

/// A type with a network bitrate strategy representation.
///
/// - Note: 自訂策略若**不打算自己處理壅塞適應**，必須以組合（composition）持有
///   `StreamVideoAdaptiveBitRateStrategy` 並在 `adjustBitrate` 中 `await inner.adjustBitrate(...)`
///   forward。直接取代會喪失 `.publishInsufficientBWOccured` 降速 / `.status` 回復爬升 /
///   `.reset` 復原三個行為（內建策略預設未啟動，需自行實例化）。詳見 Docs/CHANGELOG_RTMP_SOCKET.md #22。
public protocol StreamBitRateStrategy: Sendable {
    /// The mamimum video bitRate.
    var mamimumVideoBitRate: Int { get }
    /// The mamimum audio bitRate.
    var mamimumAudioBitRate: Int { get }

    /// Adjust a bitRate.
    func adjustBitrate(_ event: NetworkMonitorEvent, stream: some StreamConvertible) async
}

/// An actor provides an algorithm that focuses on video bitrate control.
public final actor StreamVideoAdaptiveBitRateStrategy: StreamBitRateStrategy {
    /// The status counts threshold for restoring the status
    public static let statusCountsThreshold: Int = 5
    /// The minimum cooldown interval between bitrate reductions (in status events).
    public static let insufficientBWCooldown: Int = 3
    /// The maximum percentage of the current target a single congestion event
    /// may remove. One event can cut at most this much; sustained congestion
    /// ratchets down over several events. Keeps a transient dip from
    /// collapsing the target straight to the floor.
    public static let maximumDecreasePercentage: Int = 25

    public let mamimumVideoBitRate: Int
    public let mamimumAudioBitRate: Int = 0
    private var sufficientBWCounts: Int = 0
    private var insufficientBWCounts: Int = 0
    /// The rate to hand a fresh encoder on `.reset` after a reconnect. Set to
    /// the lowered rate on congestion and advanced after healthy recovery,
    /// so reconnects use the latest proven rate; `0` means "use the max".
    private var restartBitRate: Int = 0
    /// The highest rate the link has held through a full healthy window. Caps
    /// the recovery climb at one step past this, so a post-congestion burst
    /// can't jump straight back to the max — while still letting the target
    /// walk back up as each step is proven. Advanced on every successful climb
    /// and dropped on congestion, so it never pins the stream low forever.
    private var provenCeiling: Int = 0

    /// Creates a new instance.
    public init(mamimumVideoBitrate: Int) {
        self.mamimumVideoBitRate = mamimumVideoBitrate
    }

    @available(iOS 26.0, tvOS 26.0, macOS 26.0, *)
    private func deriveVBV(_ settings: inout VideoCodecSettings) {
        guard settings.bitRateMode == .variable else { return }
        // VBV 硬上限跟著「當前目標」縮放（memory: VBR 需 1.2× 硬上限 +
        // 1.5× soft dataRateLimits）：目標被策略調低時，上限同步下修，
        // 這樣壅塞期間編碼器不會在上限處繼續爆衝。不要改成從 max 推導 —
        // 那會讓低目標失去約束，且 dataRateLimits 變動會觸發 session 重建。
        settings.vbvMaxBitRate = settings.bitRate * 12 / 10
        settings.vbvBufferDuration = settings.vbvBufferDuration ?? 1.0
    }

    public func adjustBitrate(_ event: NetworkMonitorEvent, stream: some StreamConvertible) async {
        // Read the current settings first, then decide synchronously. `stream`
        // is a different actor, so every `await` on it is a suspension point;
        // if the counter read-modify-write lived across those awaits, a second
        // event could re-enter this actor and double-apply one event (two 25%
        // cuts for a single congestion, or two climbs for one healthy window).
        // Keeping the entire decision inside `decide(...)` — which has no
        // `await` — makes it atomic.
        let currentVideo = await stream.videoSettings
        let currentAudio = await stream.audioSettings
        guard var videoSettings = decide(event, video: currentVideo, audio: currentAudio) else {
            return
        }
        if #available(iOS 26.0, tvOS 26.0, macOS 26.0, *) {
            deriveVBV(&videoSettings)
        }
        do {
            try await stream.setVideoSettings(videoSettings)
            logger.info("ABR apply event=\(event) target=\(currentVideo.bitRate)->\(videoSettings.bitRate) max=\(mamimumVideoBitRate)")
        } catch {
            logger.error("ABR apply failed target=\(videoSettings.bitRate) error=\(error)")
        }
    }

    /// Synchronous, actor-isolated decision. Performs every counter
    /// read-modify-write without a suspension point, so a reentrant
    /// `adjustBitrate` can never interleave and double-apply one event.
    /// Returns the settings to apply, or `nil` when the target is unchanged.
    private func decide(
        _ event: NetworkMonitorEvent,
        video currentVideo: VideoCodecSettings,
        audio audioSettings: AudioCodecSettings
    ) -> VideoCodecSettings? {
        switch event {
        case .status(let report):
            // A status can be the first unconfirmed congested sample. Do not
            // treat a substantial outstanding queue as proof of spare capacity.
            let backlog = Double(report.currentQueueBytesOut) / Double(max(report.currentBytesOutPerSecond, 1))
            if NetworkMonitor.defaultMinimumCongestionQueueBytes <= report.currentQueueBytesOut,
               NetworkMonitor.defaultMaxQueueBacklogSeconds <= backlog {
                if 0 < insufficientBWCounts {
                    insufficientBWCounts -= 1
                }
                return nil
            }
            if currentVideo.bitRate == mamimumVideoBitRate {
                insufficientBWCounts = 0
                provenCeiling = mamimumVideoBitRate
                restartBitRate = mamimumVideoBitRate
                return nil
            }
            var videoSettings = currentVideo
            if Self.statusCountsThreshold <= sufficientBWCounts {
                let incremental = mamimumVideoBitRate / 5
                // The rate that just held through a full healthy window is now
                // proven sustainable, so promote the ceiling before climbing.
                // This is what makes recovery gradual instead of pinned: each
                // held step raises the cap by one step, so the target can walk
                // all the way back to the max on a healthy link, but never
                // jumps there in a single burst.
                provenCeiling = max(provenCeiling, videoSettings.bitRate)
                restartBitRate = videoSettings.bitRate
                let ceiling = min(mamimumVideoBitRate, provenCeiling + incremental)
                videoSettings.bitRate = min(videoSettings.bitRate + incremental, ceiling)
                sufficientBWCounts = 0
                // Decrement cooldown when healthy
                if 0 < insufficientBWCounts {
                    insufficientBWCounts -= 1
                }
                return videoSettings
            }
            sufficientBWCounts += 1
            // Decrement cooldown when healthy
            if 0 < insufficientBWCounts {
                insufficientBWCounts -= 1
            }
            return nil
        case .publishInsufficientBWOccured(let report):
            guard insufficientBWCounts == 0 else {
                // Duplicate congestion notifications during cooldown must not
                // erase healthy samples accumulated since the last actual cut.
                return nil
            }
            sufficientBWCounts = 0
            var videoSettings = currentVideo
            let currentBitRate = videoSettings.bitRate
            let minimumBitRate = mamimumVideoBitRate / 5
            if 0 < report.currentBytesOutPerSecond {
                let measuredBitRate = Int(report.currentBytesOutPerSecond * 8)
                // NEVER raise the target here. `currentBytesOutPerSecond` is
                // the socket's measured drain rate, which during a
                // stall→recovery burst reflects the backlog flush — not
                // sustainable bandwidth. `min` caps the derived target at the
                // current value so a transient burst can't ratchet bitrate up.
                let derivedBitRate = max(measuredBitRate - audioSettings.bitRate, minimumBitRate)
                // Bounded multiplicative decrease (AIMD): one congestion event
                // may not cut more than `maximumDecreasePercentage` of the
                // current target, so a transient dip costs a single step
                // instead of collapsing straight to the floor. Sustained
                // congestion still ratchets all the way down over several
                // events.
                let decreaseFloor = currentBitRate * (100 - Self.maximumDecreasePercentage) / 100
                videoSettings.bitRate = max(min(currentBitRate, derivedBitRate), decreaseFloor)
            } else {
                // Zero bytes out is a hard stall; allow the standard halving.
                // `min` keeps the floor from ever raising a target the app
                // configured below it.
                videoSettings.bitRate = min(currentBitRate, max(currentBitRate / 2, minimumBitRate))
            }
            insufficientBWCounts = Self.insufficientBWCooldown
            // The pre-drop rate just proved unsustainable: lower the proven
            // ceiling to the new conservative target and remember it as the
            // safe rate for a post-reconnect `.reset`.
            restartBitRate = videoSettings.bitRate
            provenCeiling = videoSettings.bitRate
            return videoSettings
        case .reset:
            var videoSettings = currentVideo
            insufficientBWCounts = 0
            sufficientBWCounts = 0
            // Restore the last safe rate instead of the configured maximum.
            // A reconnect often follows a stall; starting the fresh encoder at
            // the ceiling immediately produces a max-size keyframe burst.
            let restoredBitRate = 0 < restartBitRate ? restartBitRate : mamimumVideoBitRate
            videoSettings.bitRate = restoredBitRate
            provenCeiling = restoredBitRate
            return videoSettings
        }
    }
}
