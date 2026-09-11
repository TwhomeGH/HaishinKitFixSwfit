import AVFoundation
import CoreMedia
import Foundation
import Testing

@testable import HaishinKit

/// `StreamVideoAdaptiveBitRateStrategy` 的行為驗證：降速有界、只降不升、
/// 回升逐格且能回到 max（回歸 CHANGES #53 的「降速後永久釘死」）。
@Suite("StreamVideoAdaptiveBitRateStrategy：ABR 恢復與降速")
struct StreamBitRateStrategyTests {
    private static let maximumBitRate = 5_500_000
    private static let audioBitRate = 128_000
    private static let minimumBitRate = maximumBitRate / 5
    private static let incremental = maximumBitRate / 5

    private static func report(bytesOutPerSecond: Int) -> NetworkMonitorReport {
        NetworkMonitorReport(
            totalBytesIn: 0,
            totalBytesOut: 0,
            currentQueueBytesOut: 0,
            currentBytesInPerSecond: 0,
            currentBytesOutPerSecond: bytesOutPerSecond
        )
    }

    private static func makeStream(bitRate: Int = maximumBitRate) -> MockStream {
        MockStream(
            videoSettings: VideoCodecSettings(bitRate: bitRate),
            audioSettings: AudioCodecSettings(bitRate: audioBitRate)
        )
    }

    private static func makeStrategy() -> StreamVideoAdaptiveBitRateStrategy {
        StreamVideoAdaptiveBitRateStrategy(mamimumVideoBitrate: maximumBitRate)
    }

    /// 實測 ~1.2 Mbps：derived 會落到地板，但單次事件只能降 25%。
    private static func congestedReport() -> NetworkMonitorReport {
        report(bytesOutPerSecond: 150_000)
    }

    @Test("壅塞降速受 25% 上界約束，不會一步打到地板")
    func congestionDecreaseIsBounded() async {
        let strategy = Self.makeStrategy()
        let stream = Self.makeStream()

        await strategy.adjustBitrate(.publishInsufficientBWOccured(report: Self.congestedReport()), stream: stream)

        let bitRate = await stream.videoSettings.bitRate
        #expect(bitRate == Self.maximumBitRate * 75 / 100)
        #expect(Self.minimumBitRate <= bitRate)
    }

    @Test("壅塞絕不調高目標（即使實測吞吐高於目標）")
    func congestionNeverRaises() async {
        let strategy = Self.makeStrategy()
        let stream = Self.makeStream(bitRate: Self.minimumBitRate)

        await strategy.adjustBitrate(.publishInsufficientBWOccured(report: Self.report(bytesOutPerSecond: 5_000_000 / 8)), stream: stream)

        let bitRate = await stream.videoSettings.bitRate
        #expect(bitRate <= Self.minimumBitRate)
    }

    @Test("持續壅塞逐格降到地板，且任何時候都不低於地板")
    func sustainedCongestionReachesFloor() async {
        let strategy = Self.makeStrategy()
        let stream = Self.makeStream()

        for _ in 0..<20 {
            await strategy.adjustBitrate(.publishInsufficientBWOccured(report: Self.congestedReport()), stream: stream)
            // 清掉 insufficientBWCooldown（3 個 .status），但不夠觸發回升（門檻 5）。
            for _ in 0..<3 {
                await strategy.adjustBitrate(.status(report: Self.congestedReport()), stream: stream)
            }
            let bitRate = await stream.videoSettings.bitRate
            #expect(Self.minimumBitRate <= bitRate)
        }

        let bitRate = await stream.videoSettings.bitRate
        #expect(bitRate == Self.minimumBitRate)
    }

    @Test("回升一次只爬一格，不直接彈回 max")
    func recoveryClimbsOneStepAtATime() async {
        let strategy = Self.makeStrategy()
        let stream = Self.makeStream()

        await strategy.adjustBitrate(.publishInsufficientBWOccured(report: Self.congestedReport()), stream: stream)
        let afterDrop = await stream.videoSettings.bitRate
        #expect(afterDrop == Self.maximumBitRate * 75 / 100)

        var climbed: Int?
        for _ in 0..<20 {
            await strategy.adjustBitrate(.status(report: Self.congestedReport()), stream: stream)
            let current = await stream.videoSettings.bitRate
            if current != afterDrop {
                climbed = current
                break
            }
        }

        #expect(climbed == afterDrop + Self.incremental)
        #expect(climbed != Self.maximumBitRate)
    }

    @Test("回升不會永久釘死：健康足夠後回到 max")
    func recoveryReachesMaximum() async {
        let strategy = Self.makeStrategy()
        let stream = Self.makeStream()

        await strategy.adjustBitrate(.publishInsufficientBWOccured(report: Self.congestedReport()), stream: stream)
        for _ in 0..<40 {
            await strategy.adjustBitrate(.status(report: Self.report(bytesOutPerSecond: 1_000_000)), stream: stream)
        }

        let bitRate = await stream.videoSettings.bitRate
        #expect(bitRate == Self.maximumBitRate)
    }

    @Test("reset 回到降速後的安全值，而非 max")
    func resetRestoresSafeRate() async {
        let strategy = Self.makeStrategy()
        let stream = Self.makeStream()

        await strategy.adjustBitrate(.publishInsufficientBWOccured(report: Self.congestedReport()), stream: stream)
        let afterDrop = await stream.videoSettings.bitRate
        await strategy.adjustBitrate(.reset, stream: stream)

        let bitRate = await stream.videoSettings.bitRate
        #expect(bitRate == afterDrop)
        #expect(bitRate != Self.maximumBitRate)
    }

    @Test("零位元組硬停滯：允許標準砍半")
    func zeroBytesHalves() async {
        let strategy = Self.makeStrategy()
        let stream = Self.makeStream()

        await strategy.adjustBitrate(.publishInsufficientBWOccured(report: Self.report(bytesOutPerSecond: 0)), stream: stream)

        let bitRate = await stream.videoSettings.bitRate
        #expect(bitRate == Self.maximumBitRate / 2)
    }
}

/// 只實作 ABR 需要的讀寫（`videoSettings` / `audioSettings` / `setVideoSettings`），
/// 其餘 `StreamConvertible` 成員為 no-op stub。
private actor MockStream: StreamConvertible {
    var videoSettings: VideoCodecSettings
    var audioSettings: AudioCodecSettings

    init(videoSettings: VideoCodecSettings, audioSettings: AudioCodecSettings) {
        self.videoSettings = videoSettings
        self.audioSettings = audioSettings
    }

    // MARK: StreamConvertible
    var readyState: StreamReadyState { .publishing }
    var soundTransform: SoundTransform? { nil }
    var maxVideoBufferBytes: Int = 0

    func setBitRateStrategy(_ bitRateStrategy: (some StreamBitRateStrategy)?) {}
    func setAudioSettings(_ audioSettings: AudioCodecSettings) throws {
        self.audioSettings = audioSettings
    }
    func setVideoSettings(_ videoSettings: VideoCodecSettings) throws {
        self.videoSettings = videoSettings
    }
    func setSoundTransform(_ soundTransfrom: SoundTransform) async {}
    func setVideoInputBufferCounts(_ videoInputBufferCounts: Int) {}
    func append(_ sampleBuffer: CMSampleBuffer) {}
    func append(_ audioBuffer: AVAudioBuffer, when: AVAudioTime) {}
    func attachAudioPlayer(_ audioPlayer: AudioPlayer?) async {}
    func addOutput(_ obserber: some StreamOutput) {}
    func removeOutput(_ observer: some StreamOutput) {}
    func dispatch(_ event: NetworkMonitorEvent) async {}

    // MARK: MediaMixerOutput
    // `mixer(_:didOutput:)` 是 MediaMixerOutput 的同步需求（該 protocol 不繼承 Actor），
    // 因此必須 nonisolated；async 需求（selectTrack 等）則可維持 actor 隔離。
    var videoTrackId: UInt8? { nil }
    var audioTrackId: UInt8? { nil }
    nonisolated func mixer(_ mixer: MediaMixer, didOutput sampleBuffer: CMSampleBuffer) {}
    nonisolated func mixer(_ mixer: MediaMixer, didOutput buffer: AVAudioPCMBuffer, when: AVAudioTime) {}
    func selectTrack(_ id: UInt8?, mediaType: CMFormatDescription.MediaType) async {}
}
