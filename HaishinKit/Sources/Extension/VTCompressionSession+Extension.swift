import Foundation
import VideoToolbox

extension VTCompressionSession {
    func prepareToEncodeFrames() -> OSStatus {
        VTCompressionSessionPrepareToEncodeFrames(self)
    }
}

extension VTCompressionSession: VTSessionConvertible {
    @inline(__always)
    @discardableResult
    func convert(
        _ sampleBuffer: CMSampleBuffer,
        forceKeyFrame: Bool,
        continuation: AsyncStream<CMSampleBuffer>.Continuation?,
        outputState: VideoEncoderOutputState
    ) throws -> Bool {
        guard let imageBuffer = sampleBuffer.imageBuffer else {
            return false
        }
        var flags: VTEncodeInfoFlags = []
        let frameProperties = forceKeyFrame ? [
            VTSessionOptionKey.forceKeyFrame.CFString: kCFBooleanTrue as Any
        ] as CFDictionary : nil
        outputState.submitted()
        let status = VTCompressionSessionEncodeFrame(
            self,
            imageBuffer: imageBuffer,
            presentationTimeStamp: sampleBuffer.presentationTimeStamp,
            duration: sampleBuffer.duration,
            frameProperties: frameProperties,
            infoFlagsOut: &flags,
            // VT 非同步 callback（跑在 VT 執行緒，可能晚於 session 替換才回來）。
            // 所有分支都先經過 outputState 把關，才決定是否 yield 給 consumer。
            outputHandler: { status, flags, sampleBuffer in
                outputState.callback()
                guard status == noErr else {
                    // encode 失敗：記錄後擋住後續幀，直到 owner 重建 session。
                    if outputState.recordFailure(status) {
                        logger.warn("VideoCodec asynchronous encode failure status=\(status)")
                    }
                    return
                }
                guard !flags.contains(.frameDropped), let sampleBuffer,
                      CMSampleBufferIsValid(sampleBuffer), CMSampleBufferDataIsReady(sampleBuffer) else {
                    // VT 丟棄或 sample buffer 不合法/未就緒：視為 GOP 斷點，
                    // 回到等 keyframe。
                    outputState.dropped()
                    return
                }
                // 交棒給 consumer。deliver 只在狀態允許（active、無失敗、
                // 若在等 keyframe 則必須是 keyframe）時才呼叫 yield；
                // yield 回傳 .enqueued 才算真正成功，否則視同丟棄。
                // 是否為 keyframe 由 sample buffer 的 sync 標記判定
                // （!isNotSync == 有 sync sample == IDR）。
                outputState.deliver(isKeyFrame: !sampleBuffer.isNotSync,
                                    seconds: sampleBuffer.presentationTimeStamp.seconds) {
                    guard let continuation else { return false }
                    if case .enqueued = continuation.yield(sampleBuffer) { return true }
                    return false
                }
            }
        )
        if status != noErr {
            outputState.recordFailure(status)
            throw VTSessionError.failedToConvert(status: status)
        }
        return flags.contains(.frameDropped)
    }

    func invalidate() {
        VTCompressionSessionInvalidate(self)
    }
}
