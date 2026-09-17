import AVFoundation
import CoreMedia
import Foundation
import Testing

@testable import HaishinKit

/// `OutgoingStream` 的自動 buffer count 計算與執行緒安全（CHANGES #56d、#57）。
/// 併發案例請在 Apple 端搭配 Thread Sanitizer 執行以驗證鎖正確。
@Suite("OutgoingStream：buffer count 與執行緒安全")
struct OutgoingStreamTests {
    @Test("NV12 估算：1920x1080 → 5、1280x720 → 11，且夾在 [1, 30]")
    func autoCountFromResolution() {
        let stream = OutgoingStream()
        #expect(stream.computeVideoInputBufferCounts(for: CGSize(width: 1920, height: 1080)) == 5)
        #expect(stream.computeVideoInputBufferCounts(for: CGSize(width: 1280, height: 720)) == 11)
        #expect(stream.computeVideoInputBufferCounts(for: CGSize(width: 8, height: 8)) == 30)
        #expect(stream.computeVideoInputBufferCounts(for: CGSize(width: 100_000, height: 100_000)) == 1)
    }

    @Test("setVideoInputBufferCounts 覆寫 / 還原自動計算")
    func overrideAndRestore() {
        let stream = OutgoingStream()
        stream.setVideoInputBufferCounts(7)
        #expect(stream.videoInputBufferCounts == 7)
        #expect(stream.videoInputBufferCountsOverridden == true)

        // 覆寫後 videoSettings 變更不重算。
        var settings = VideoCodecSettings.default
        settings.videoSize = CGSize(width: 1920, height: 1080)
        stream.videoSettings = settings
        #expect(stream.videoInputBufferCounts == 7)

        // 還原：立即以當前 videoSize 重算。
        stream.setVideoInputBufferCounts(nil)
        #expect(stream.videoInputBufferCountsOverridden == false)
        #expect(stream.videoInputBufferCounts == 5)
    }

    @Test("prepareVideoInputStream 以當前 videoSize 自動計算")
    func prepareComputesFromVideoSize() {
        let stream = OutgoingStream()
        var settings = VideoCodecSettings.default
        settings.videoSize = CGSize(width: 1280, height: 720)
        stream.videoSettings = settings
        _ = stream.prepareVideoInputStream()
        #expect(stream.videoInputBufferCounts == 11)
    }

    @Test("append 影片幀後以實測 bytes/frame 重算")
    func observedBytesPerFrameUsed() throws {
        let stream = OutgoingStream()
        let sampleBuffer = try #require(CMVideoSampleBufferFactory.makeSampleBuffer(width: 1920, height: 1080))
        stream.append(sampleBuffer) // 32BGRA → 1920 * 1080 * 4 bytes
        #expect(stream.computeVideoInputBufferCounts(for: CGSize(width: 1920, height: 1080)) == 1)
    }

    @Test("併發存取（prepare / videoSettings / counts / append）不崩潰且狀態一致")
    func concurrentAccessIsSafe() async {
        let stream = OutgoingStream()
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<8 {
                group.addTask {
                    let video = CMVideoSampleBufferFactory.makeSampleBuffer(width: 640, height: 480)
                    for _ in 0..<200 {
                        _ = stream.prepareVideoInputStream()
                        _ = stream.videoInputBufferCounts
                        var settings = VideoCodecSettings.default
                        settings.videoSize = index.isMultiple(of: 2)
                            ? CGSize(width: 1920, height: 1080)
                            : CGSize(width: 1280, height: 720)
                        stream.videoSettings = settings
                        if let video {
                            stream.append(video)
                        }
                    }
                }
            }
        }
        #expect(1 <= stream.videoInputBufferCounts)
    }
}
