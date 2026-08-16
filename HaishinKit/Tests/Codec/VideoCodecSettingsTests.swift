import Foundation
import Testing
import VideoToolbox

@testable import HaishinKit

@Suite struct VideoCodecSettingsTests {
    @Test func keyFrameIntervalOptions_unknownFrameRate() {
        // 無 frameInterval / expectedFrameRate / measuredFrameRate → 不再用 30fps
        // 猜測幀數約束，退回純 duration（VFR 正確機制）。
        let settings = VideoCodecSettings(maxKeyFrameIntervalDuration: 2)
        let options = settings.makeKeyFrameIntervalOptions()

        #expect(options.number(for: .maxKeyFrameIntervalDuration)?.int32Value == 2)
        #expect(options.value(for: .maxKeyFrameInterval) == nil)
    }

    @Test func keyFrameIntervalOptions_measuredFrameRate() {
        // sample buffer 實測幀率作為幀數約束基準。
        let settings = VideoCodecSettings(maxKeyFrameIntervalDuration: 2)
        let options = settings.makeKeyFrameIntervalOptions(measuredFrameRate: 45)

        #expect(options.number(for: .maxKeyFrameIntervalDuration)?.int32Value == 2)
        #expect(options.number(for: .maxKeyFrameInterval)?.int32Value == 90)
    }

    @Test func keyFrameIntervalOptions_expectedFrameRate() {
        let settings = VideoCodecSettings(maxKeyFrameIntervalDuration: 2, expectedFrameRate: 23)
        let options = settings.makeKeyFrameIntervalOptions()

        #expect(options.number(for: .maxKeyFrameIntervalDuration)?.int32Value == 2)
        #expect(options.number(for: .maxKeyFrameInterval)?.int32Value == 46)
    }

    @Test func keyFrameIntervalOptions_frameInterval() {
        var settings = VideoCodecSettings(maxKeyFrameIntervalDuration: 2)
        settings.frameInterval = VideoCodecSettings.frameInterval10
        let options = settings.makeKeyFrameIntervalOptions()

        #expect(options.number(for: .maxKeyFrameIntervalDuration)?.int32Value == 2)
        #expect(options.number(for: .maxKeyFrameInterval)?.int32Value == 21)
    }

    @Test func keyFrameIntervalOptions_highExpectedFrameRate() {
        let settings = VideoCodecSettings(maxKeyFrameIntervalDuration: 2, expectedFrameRate: 60)
        let options = settings.makeKeyFrameIntervalOptions()

        #expect(options.number(for: .maxKeyFrameIntervalDuration)?.int32Value == 2)
        #expect(options.number(for: .maxKeyFrameInterval)?.int32Value == 120)
    }

    @Test func keyFrameIntervalOptions_disabledFrameCount() {
        let settings = VideoCodecSettings(maxKeyFrameIntervalDuration: 0)
        let options = settings.makeKeyFrameIntervalOptions()

        #expect(options.number(for: .maxKeyFrameIntervalDuration)?.int32Value == 0)
        #expect(options.value(for: .maxKeyFrameInterval) == nil)
    }

    @Test func makeOptions_measuredFrameRateAsExpectedFrameRateHint() {
        // 來源幀率未知時，用測量值當 VT expectedFrameRate hint（官方：bitrate 須與 frame rate 一致）。
        let settings = VideoCodecSettings(maxKeyFrameIntervalDuration: 2)
        let options = settings.makeOptions(measuredFrameRate: 45)

        #expect(options.value(for: .expectedFrameRate) as? Double == 45)
    }
}

private extension Set where Element == VTSessionOption {
    func number(for key: VTSessionOptionKey) -> NSNumber? {
        value(for: key) as? NSNumber
    }

    func value(for key: VTSessionOptionKey) -> AnyObject? {
        first { $0.key == key }?.value
    }
}
