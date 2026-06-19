import Foundation
import VideoToolbox

extension VTCompressionSession {
    func prepareToEncodeFrames() -> OSStatus {
        VTCompressionSessionPrepareToEncodeFrames(self)
    }
}

extension VTCompressionSession: VTSessionConvertible {
    @inline(__always)
    func convert(
        _ sampleBuffer: CMSampleBuffer,
        forceKeyFrame: Bool,
        continuation: AsyncStream<CMSampleBuffer>.Continuation?
    ) throws {
        guard let imageBuffer = sampleBuffer.imageBuffer else {
            return
        }
        var flags: VTEncodeInfoFlags = []
        let frameProperties = forceKeyFrame ? [
            VTSessionOptionKey.forceKeyFrame.CFString: kCFBooleanTrue as Any
        ] as CFDictionary : nil
        let status = VTCompressionSessionEncodeFrame(
            self,
            imageBuffer: imageBuffer,
            presentationTimeStamp: sampleBuffer.presentationTimeStamp,
            duration: sampleBuffer.duration,
            frameProperties: frameProperties,
            infoFlagsOut: &flags,
            outputHandler: { _, _, sampleBuffer in
                if let sampleBuffer {
                    continuation?.yield(sampleBuffer)
                }
            }
        )
        if status != noErr {
            throw VTSessionError.failedToConvert(status: status)
        }
    }

    func invalidate() {
        VTCompressionSessionInvalidate(self)
    }
}
