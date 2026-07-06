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

    /// Creates a new instance.
    public init(mamimumVideoBitrate: Int) {
        self.mamimumVideoBitRate = mamimumVideoBitrate
    }

    @available(iOS 26.0, tvOS 26.0, macOS 26.0, *)
    private func deriveVBV(_ settings: inout VideoCodecSettings) {
        guard settings.bitRateMode == .variable else { return }
        settings.vbvMaxBitRate = settings.bitRate * 12 / 10
    }

    public func adjustBitrate(_ event: NetworkMonitorEvent, stream: some StreamConvertible) async {
        switch event {
        case .status:
            var videoSettings = await stream.videoSettings
            if videoSettings.bitRate == mamimumVideoBitRate {
                insufficientBWCounts = 0
                return
            }
            if Self.statusCountsThreshold <= sufficientBWCounts {
                let incremental = mamimumVideoBitRate / 5
                videoSettings.bitRate = min(videoSettings.bitRate + incremental, mamimumVideoBitRate)
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
            if 0 < report.currentBytesOutPerSecond {
                let bitRate = Int(report.currentBytesOutPerSecond * 8)
                videoSettings.bitRate = max(bitRate - audioSettings.bitRate, mamimumVideoBitRate / 5)
            } else {
                videoSettings.bitRate = max(videoSettings.bitRate / 2, mamimumVideoBitRate / 10)
            }
            insufficientBWCounts = Self.insufficientBWCooldown
            if #available(iOS 26.0, tvOS 26.0, macOS 26.0, *) {
                deriveVBV(&videoSettings)
            }
            try? await stream.setVideoSettings(videoSettings)
        case .reset:
            var videoSettings = await stream.videoSettings
            insufficientBWCounts = 0
            sufficientBWCounts = 0
            videoSettings.bitRate = mamimumVideoBitRate
            videoSettings.frameInterval = 0.0
            if #available(iOS 26.0, tvOS 26.0, macOS 26.0, *) {
                deriveVBV(&videoSettings)
            }
            try? await stream.setVideoSettings(videoSettings)
        }
    }
}
