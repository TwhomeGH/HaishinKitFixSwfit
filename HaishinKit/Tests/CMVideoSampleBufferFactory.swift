import AVFoundation
import Foundation

enum CMVideoSampleBufferFactory {
    static func makeSampleBuffer(_ data: Data) -> CMSampleBuffer? {
        var blockBuffer: CMBlockBuffer?
        _ = data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: UnsafeMutableRawPointer(mutating: buffer.baseAddress),
                blockLength: data.count,
                blockAllocator: kCFAllocatorNull,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: data.count,
                flags: 0,
                blockBufferOut: &blockBuffer
            )
        }
        guard let blockBuffer else {
            return nil
        }
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: .invalid,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: nil,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: [data.count],
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr else {
            return nil
        }
        return sampleBuffer
    }

    /// 建立測試影格；預設維持未知 PTS，時間軸測試應明確傳入有效時間。
    /// - Parameters:
    ///   - width: 像素寬度。
    ///   - height: 像素高度。
    ///   - presentationTimeStamp: 來源 PTS；預設無效，不假造零起點。
    /// - Returns: 建立成功的影格，CoreMedia 建立失敗時為 nil。
    static func makeSampleBuffer(width: Int, height: Int,
                                 presentationTimeStamp: CMTime = .invalid) -> CMSampleBuffer? {
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
        guard let pixelBuffer else {
            return nil
        }
        var outputFormat: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &outputFormat
        )
        guard let outputFormat else {
            return nil
        }
        var timingInfo = CMSampleTimingInfo(duration: .invalid,
                                            presentationTimeStamp: presentationTimeStamp,
                                            decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: outputFormat,
            sampleTiming: &timingInfo,
            sampleBufferOut: &sampleBuffer
        ) == noErr else {
            return nil
        }
        return sampleBuffer
    }
}
