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
    /// the lowered rate on congestion so a reconnect doesn't immediately burst
    /// a new encoder at the ceiling; `0` means "never congested, use the max".
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
        switch event {
        case .status:
            var videoSettings = await stream.videoSettings
            if videoSettings.bitRate == mamimumVideoBitRate {
                insufficientBWCounts = 0
                provenCeiling = mamimumVideoBitRate
                return
            }
            if Self.statusCountsThreshold <= sufficientBWCounts {
                let incremental = mamimumVideoBitRate / 5
                // The rate that just held through a full healthy window is now
                // proven sustainable, so promote the ceiling before climbing.
                // This is what makes recovery gradual instead of pinned: each
                // held step raises the cap by one step, so the target can walk
                // all the way back to the max on a healthy link, but never
                // jumps there in a single burst.
                provenCeiling = max(provenCeiling, videoSettings.bitRate)
                let ceiling = min(mamimumVideoBitRate, provenCeiling + incremental)
                videoSettings.bitRate = min(videoSettings.bitRate + incremental, ceiling)
                if #available(iOS 26.0, tvOS 26.0, macOS 26.0, *) {
                    deriveVBV(&videoSettings)
                }
                try? await stream.setVideoSettings(videoSettings)
                sufficientBWCounts = 0
            } else {
                sufficientBWCounts += 1
            }
            // Decrement cooldown when healthy
            if 0 < insufficientBWCounts {
                insufficientBWCounts -= 1
            }
        case .publishInsufficientBWOccured(let report):
            sufficientBWCounts = 0
            guard insufficientBWCounts == 0 else {
                return
            }
            var videoSettings = await stream.videoSettings
            let audioSettings = await stream.audioSettings
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
            if #available(iOS 26.0, tvOS 26.0, macOS 26.0, *) {
                deriveVBV(&videoSettings)
            }
            try? await stream.setVideoSettings(videoSettings)
            // The pre-drop rate just proved unsustainable: lower the proven
            // ceiling to the new conservative target and remember it as the
            // safe rate for a post-reconnect `.reset`.
            restartBitRate = videoSettings.bitRate
            provenCeiling = videoSettings.bitRate
        case .reset:
            var videoSettings = await stream.videoSettings
            insufficientBWCounts = 0
            sufficientBWCounts = 0
            // Restore the last safe rate instead of the configured maximum.
            // A reconnect often follows a stall; starting the fresh encoder at
            // the ceiling immediately produces a max-size keyframe burst.
            let restoredBitRate = 0 < restartBitRate ? restartBitRate : mamimumVideoBitRate
            videoSettings.bitRate = restoredBitRate
            provenCeiling = restoredBitRate
            if #available(iOS 26.0, tvOS 26.0, macOS 26.0, *) {
                deriveVBV(&videoSettings)
            }
            try? await stream.setVideoSettings(videoSettings)
        }
    }
}
