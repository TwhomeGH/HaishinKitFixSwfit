import Foundation
import Testing
import VideoToolbox

@testable import HaishinKit

@Suite struct VideoCodecSettingsTests {
    @Test func keyFrameIntervalOptions_defaultFrameRate() {
        let settings = VideoCodecSettings(maxKeyFrameIntervalDuration: 2)
        let options = settings.makeKeyFrameIntervalOptions()

        #expect(options.number(for: .maxKeyFrameIntervalDuration)?.int32Value == 2)
        #expect(options.number(for: .maxKeyFrameInterval)?.int32Value == 60)
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

    @Test func keyFrameIntervalOptions_disabledFrameCount() {
        let settings = VideoCodecSettings(maxKeyFrameIntervalDuration: 0)
        let options = settings.makeKeyFrameIntervalOptions()

        #expect(options.number(for: .maxKeyFrameIntervalDuration)?.int32Value == 0)
        #expect(options.value(for: .maxKeyFrameInterval) == nil)
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
