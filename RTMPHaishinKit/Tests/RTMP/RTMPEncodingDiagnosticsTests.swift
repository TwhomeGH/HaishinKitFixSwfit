import AVFoundation
import Foundation
import Testing
@testable import RTMPHaishinKit

/// 用合成壓縮樣本驗證觀測契約，不啟動網路或硬體編碼器。
struct RTMPEncodingDiagnosticsTests {
    @Test func audioFormatAndOutputTimesAreIndependent() throws {
        var tracker = RTMPEncodingTracker()
        tracker.reset(generation: 7)
        let start = Date(timeIntervalSince1970: 100)
        let buffer = try audio(rate: 48000)
        tracker.record(audio: buffer, now: start)
        tracker.record(audio: buffer, now: start.addingTimeInterval(5))
        let snapshot = tracker.snapshot(isPublishing: true)
        #expect(snapshot.audio?.codec == "aac ")
        #expect(snapshot.audio?.sampleRate == 48000)
        #expect(snapshot.audio?.channels == 2)
        #expect(snapshot.audio?.framesPerPacket == 1024)
        #expect(snapshot.audioFormatRevision == 1)
        #expect(snapshot.audioFormatChangedAt == start)
        #expect(snapshot.lastAudioOutputAt == start.addingTimeInterval(5))
        #expect(snapshot.audioPackets == 4)
        #expect(snapshot.audioBytes == 16)
        tracker.record(audio: try audio(rate: 44100), now: start.addingTimeInterval(10))
        #expect(tracker.snapshot(isPublishing: true).audioFormatRevision == 2)
        #expect(tracker.snapshot(isPublishing: true).audio?.sampleRate == 44100)
    }

    @Test func generationResetAndEmptyBufferDoNotInventOutput() throws {
        var tracker = RTMPEncodingTracker()
        tracker.record(audio: try audio(rate: 48000))
        let identity = tracker.snapshot(isPublishing: true).session
        tracker.reset(generation: 2)
        let empty = try audio(rate: 48000)
        empty.packetCount = 0
        empty.byteLength = 0
        tracker.record(audio: empty)
        let result = tracker.snapshot(isPublishing: false)
        #expect(result.session == identity)
        #expect(result.generation == 2)
        #expect(result.audio == nil)
        #expect(result.video == nil)
        #expect(result.lastAudioOutputAt == nil)
        #expect(result.audioPackets == 0)
        #expect(!result.isPublishing)
        let decoded = try JSONDecoder().decode(RTMPEncodingDiagnostics.self, from: JSONEncoder().encode(result))
        #expect(decoded.generation == 2)
        #expect(decoded.audio == nil)
    }

    @Test func videoFormatChangesPreserveUnknownColor() throws {
        var tracker = RTMPEncodingTracker()
        let start = Date(timeIntervalSince1970: 100)
        let sample = try video(width: 1920)
        tracker.record(video: sample, now: start)
        tracker.record(video: sample, now: start.addingTimeInterval(5))
        let value = tracker.snapshot(isPublishing: true)
        #expect(value.video?.width == 1920)
        #expect(value.video?.height == 1080)
        #expect(value.video?.fullRange == nil)
        #expect(value.video?.colorPrimaries == nil)
        #expect(value.videoFormatRevision == 1)
        #expect(value.videoFormatChangedAt == start)
        #expect(value.lastVideoOutputAt == start.addingTimeInterval(5))
        #expect(value.videoFrames == 2)
        #expect(value.videoBytes == 8)
        tracker.record(video: try video(width: 1280))
        #expect(tracker.snapshot(isPublishing: true).videoFormatRevision == 2)
        #expect(tracker.snapshot(isPublishing: true).video?.width == 1280)
        tracker.reset(generation: 1)
        #expect(tracker.snapshot(isPublishing: true).video == nil)
    }

    @Test func idlePublicAPIHasNoInventedFormat() async {
        let stream = RTMPStream(connection: RTMPConnection())
        let value = await stream.encodingDiagnostics()
        #expect(!value.isPublishing)
        #expect(value.video == nil)
        #expect(value.audio == nil)
    }

    private func audio(rate: Double) throws -> AVAudioCompressedBuffer {
        var description = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 1024,
            mBytesPerFrame: 0, mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
        let format = try #require(AVAudioFormat(streamDescription: &description))
        let buffer = AVAudioCompressedBuffer(format: format, packetCapacity: 2, maximumPacketSize: 8)
        buffer.packetCount = 2
        buffer.byteLength = 8
        return buffer
    }

    /// JPEG 不需要 avcC／SPS，適合驗證通用格式追蹤；本測試不驗證編碼內容。
    private func video(width: Int32) throws -> CMSampleBuffer {
        var description: CMFormatDescription?
        let formatStatus = CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_JPEG, width: width, height: 1080,
            extensions: nil, formatDescriptionOut: &description)
        #expect(formatStatus == noErr)
        let format = try #require(description)
        var block: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
            memoryBlock: nil, blockLength: 4, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: 4, flags: 0, blockBufferOut: &block)
        #expect(blockStatus == noErr)
        let dataBlock = try #require(block)
        var sample: CMSampleBuffer?
        var size = 4
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 60),
            presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        let sampleStatus = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault,
            dataBuffer: dataBlock, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        #expect(sampleStatus == noErr)
        return try #require(sample)
    }
}
