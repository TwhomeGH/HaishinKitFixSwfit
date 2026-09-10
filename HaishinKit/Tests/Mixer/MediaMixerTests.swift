import AVFoundation
import Foundation
import Testing

@testable import HaishinKit

@Suite("MediaMixer：設定與生命週期", .disabled(if: TestEnvironment.isCI))
struct MediaMixerTests {
    @Test("視訊設定與錯誤") func videoConfiguration() async throws {
        let mixer = MediaMixer()
        await #expect(throws: (MediaMixer.Error).self) {
            try await mixer.configuration(video: 0) { _ in }
        }
        guard let videoDevice = AVCaptureDevice.default(for: .video) else {
            return
        }
        try await mixer.attachVideo(videoDevice, track: 0) { unit in
            #expect(throws: (any Error).self) {
                try unit.setFrameRate(60)
            }
        }
        try await mixer.configuration(video: 0) { _ in }
    }

    @Test("釋放後弱引用為 nil") func release() async {
        weak var weakMixer: MediaMixer?
        _ = await {
            let mixer = MediaMixer(captureSessionMode: .manual)
            await mixer.startRunning()
            try? await Task.sleep(nanoseconds: 1)
            await mixer.stopRunning()
            try? await Task.sleep(nanoseconds: 1)
            weakMixer = mixer
        }()
        #expect(weakMixer == nil)
    }

    @Test("多重模式：釋放後為 nil") func release_with_multimode() async {
        weak var weakMixer: MediaMixer?
        _ = await {
            let mixer = MediaMixer(captureSessionMode: .multi)
            await mixer.startRunning()
            try? await Task.sleep(nanoseconds: 1)
            await mixer.stopRunning()
            try? await Task.sleep(nanoseconds: 1)
            weakMixer = mixer
        }()
        #expect(weakMixer == nil)
    }

    @Test("設定並讀取幀率") func currentFrameRate() async throws {
        let mixer = MediaMixer()
        try await mixer.setFrameRate(60)
        #expect(await mixer.frameRate == 60)
    }
}
