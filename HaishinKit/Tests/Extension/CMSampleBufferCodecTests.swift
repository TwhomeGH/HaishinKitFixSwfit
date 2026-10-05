import CoreMedia
import Foundation
import Testing

@testable import HaishinKit

/// `CMSampleBufferCodec` 的 encode→decode 往返：**NotSync（非關鍵幀）標記必須保留**。
///
/// 回歸背景：Xcode 27 抓到 `markNotSync` 內的
/// `CMSampleBufferGetSampleAttachmentsArray(...) as? NSMutableArray` 永遠失敗，
/// 於是重建（decode）後的非關鍵幀全都沒有 NotSync 標記 → `isNotSync == false` →
/// 每個視訊幀都被下游當成關鍵幀（RTMP frame type / TS random access / 錄影 seek）。
@Suite("CMSampleBufferCodec：encode / decode 往返")
struct CMSampleBufferCodecTests {
    /// 造一顆「編碼後」的視訊 sample buffer：block-buffer 承載 payload，並帶 H.264
    /// format description（`CMSampleBufferCodec.encode` 需要 block data + format description）。
    private static func makeEncodedVideoSampleBuffer() throws -> CMSampleBuffer {
        let payload = Data([0x00, 0x00, 0x00, 0x01, 0x65, 0x88, 0x84, 0x00, 0x21, 0xFF, 0xEE, 0xDD])

        var formatDescription: CMVideoFormatDescription?
        let extensions: [CFString: Any] = [
            kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: [
                "avcC": Data([0x01, 0x64, 0x00, 0x1F, 0xFF])
            ]
        ]
        try #require(CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_H264,
            width: 16,
            height: 16,
            extensions: extensions as CFDictionary,
            formatDescriptionOut: &formatDescription
        ) == noErr)
        let format = try #require(formatDescription)

        var blockBuffer: CMBlockBuffer?
        try #require(CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: payload.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: payload.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == kCMBlockBufferNoErr)
        let block = try #require(blockBuffer)
        let copyStatus = payload.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: payload.count
            )
        }
        try #require(copyStatus == kCMBlockBufferNoErr)

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        try #require(CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: [payload.count],
            sampleBufferOut: &sampleBuffer
        ) == noErr)
        return try #require(sampleBuffer)
    }

    /// 以 CoreMedia（`CFBoolean`）標記非同步幀，模擬 VideoToolbox 的輸出。
    private static func setNotSync(_ sampleBuffer: CMSampleBuffer) {
        guard let array = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
              CFArrayGetCount(array) > 0,
              let raw = CFArrayGetValueAtIndex(array, 0) else {
            return
        }
        let attachments = unsafeBitCast(raw, to: CFMutableDictionary.self)
        CFDictionarySetValue(
            attachments,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
        )
    }

    /// 直接以 CoreMedia 讀取 NotSync 標記（不依賴任何其他 extension），
    /// 確保斷言檢驗的是 codec 真正寫入的 attachment。
    private static func hasNotSync(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let array = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
              let first = array.first else {
            return false
        }
        return (first[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false
    }

    @Test("同步幀在 encode→decode 後仍為同步")
    func syncRoundTrips() throws {
        let source = try Self.makeEncodedVideoSampleBuffer()
        #expect(!Self.hasNotSync(source))

        let data = try #require(CMSampleBufferCodec.encode(source))
        let decoded = try #require(CMSampleBufferCodec.decode(data))

        #expect(!Self.hasNotSync(decoded))
    }

    @Test("非同步幀的 NotSync 標記在 encode→decode 後保留（回歸）")
    func notSyncRoundTrips() throws {
        let source = try Self.makeEncodedVideoSampleBuffer()
        Self.setNotSync(source)
        #expect(Self.hasNotSync(source))

        let data = try #require(CMSampleBufferCodec.encode(source))
        let decoded = try #require(CMSampleBufferCodec.decode(data))

        #expect(Self.hasNotSync(decoded))
    }
}
