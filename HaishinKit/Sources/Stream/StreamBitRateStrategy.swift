import Foundation

/// A type with a network bitrate strategy representation.
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

    public let mamimumVideoBitRate: Int
    public let mamimumAudioBitRate: Int = 0
    private var sufficientBWCounts: Int = 0
    private var insufficientBWCounts: Int = 0
    /// The last stable bitrate the link sustained before a congestion event.
    /// `.reset` restores this instead of jumping straight to the maximum, so a
    /// reconnect right after a stall doesn't immediately burst a fresh
    /// encoder at the ceiling.
    private var lastStableBitRate: Int = 0

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
                lastStableBitRate = mamimumVideoBitRate
                return
            }
            if Self.statusCountsThreshold <= sufficientBWCounts {
                let incremental = mamimumVideoBitRate / 5
                videoSettings.bitRate = min(videoSettings.bitRate + incremental, mamimumVideoBitRate)
                if #available(iOS 26.0, tvOS 26.0, macOS 26.0, *) {
                    deriveVBV(&videoSettings)
                }
                try? await stream.setVideoSettings(videoSettings)
                lastStableBitRate = videoSettings.bitRate
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
            if 0 < report.currentBytesOutPerSecond {
                let measuredBitRate = Int(report.currentBytesOutPerSecond * 8)
                // NEVER raise the target here. `currentBytesOutPerSecond` is
                // the socket's measured drain rate, which during a
                // stall→recovery burst reflects the backlog flush — not
                // sustainable bandwidth. `min` caps the derived target at the
                // current value so a transient burst can't ratchet bitrate up.
                let derivedBitRate = max(measuredBitRate - audioSettings.bitRate, mamimumVideoBitRate / 5)
                videoSettings.bitRate = min(currentBitRate, derivedBitRate)
            } else {
                videoSettings.bitRate = max(videoSettings.bitRate / 2, mamimumVideoBitRate / 10)
            }
            insufficientBWCounts = Self.insufficientBWCooldown
            if #available(iOS 26.0, tvOS 26.0, macOS 26.0, *) {
                deriveVBV(&videoSettings)
            }
            try? await stream.setVideoSettings(videoSettings)
            // Remember the lowered (sustainable) rate so `.reset` on a
            // reconnect right after this stall restores this — not the
            // pre-stall maximum.
            lastStableBitRate = videoSettings.bitRate
        case .reset:
            var videoSettings = await stream.videoSettings
            insufficientBWCounts = 0
            sufficientBWCounts = 0
            // Restore the last stable rate instead of the configured maximum.
            // A reconnect often follows a stall; starting the fresh encoder at
            // the ceiling immediately produces a max-size keyframe burst.
            videoSettings.bitRate = 0 < lastStableBitRate ? lastStableBitRate : mamimumVideoBitRate
            if #available(iOS 26.0, tvOS 26.0, macOS 26.0, *) {
                deriveVBV(&videoSettings)
            }
            try? await stream.setVideoSettings(videoSettings)
        }
    }
}
