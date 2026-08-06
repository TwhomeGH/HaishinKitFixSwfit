import AVFoundation
import CoreFoundation
import VideoToolbox
#if canImport(UIKit)
import UIKit
#endif

final class VideoCodec {
    static let frameInterval: Double = 0.0

    var onLog: (@Sendable (String) -> Void)?
    var settings: VideoCodecSettings = .default {
        didSet {
            let invalidateSession = settings.invalidateSession(oldValue)
            if invalidateSession {
                self.invalidateSession = invalidateSession
            } else {
                settings.apply(self, rhs: oldValue)
            }
        }
    }
    var passthrough = true
    var outputStream = AsyncStream<CMSampleBuffer> { _ in }
    var frameInterval = VideoCodec.frameInterval
    private var outputContinuation: AsyncStream<CMSampleBuffer>.Continuation?
    private var startedAt: CMTime = .zero
    private var invalidateSession = true
    private var lastKeyFramePresentationTimeStamp: CMTime?
    private var presentationTimeStamp: CMTime = .zero
    private(set) var isRunning = false
    private(set) var inputFormat: CMFormatDescription? {
        didSet {
            guard inputFormat != oldValue else {
                return
            }
            invalidateSession = true
            outputFormat = nil
        }
    }
    private(set) var session: (any VTSessionConvertible)? {
        didSet {
            oldValue?.invalidate()
            lastKeyFramePresentationTimeStamp = nil
            invalidateSession = false
        }
    }
    private(set) var outputFormat: CMFormatDescription?
    /// Accumulates pending-frame log entries; fires on every 60th frame (~1Hz at 60fps).
    private var pendingFramesLogCounter: Int = 0
    /// Adaptive throttle drop ratio: accept every `dropRatio`-th raw frame (1 = all).
    private var dropRatio: Int = 1
    /// Frame counter for the every-Nth-frame gate.
    private var frameCounter: Int = 0
    /// Last throttle adjustment time, minimum 500ms between steps.
    private var lastThrottleTime: Date = .distantPast

    private func resetSessionState(reason: @autoclosure () -> String, clearInputFormat: Bool) {
        logger.info("VideoCodec reset session:", reason())
        session = nil
        invalidateSession = true
        if clearInputFormat {
            inputFormat = nil
        }
        outputFormat = nil
        lastKeyFramePresentationTimeStamp = nil
        presentationTimeStamp = .zero
        dropRatio = 1
        frameCounter = 0
        lastThrottleTime = .distantPast
    }

    /// Adaptive frame throttle: pre-encode drop-ratio gate. Only engages when VT is
    /// *sustained* overloaded (numberOfPendingFrames > highThreshold), raising the
    /// drop ratio one step at a time (60→30→20→15fps at 60fps input), and recovers
    /// below a lower hysteresis threshold. PTS of accepted frames is untouched —
    /// output cadence stays uniform. Never writes frameInterval.
    private func updateAdaptiveDropRatio() {
        guard settings.adaptiveFrameThrottle else {
            dropRatio = 1
            lastThrottleTime = .distantPast
            return
        }
        let now = Date()
        guard 0.5 < now.timeIntervalSince(lastThrottleTime) else {
            return
        }
        let pending = (session?.copyProperty(kVTCompressionPropertyKey_NumberOfPendingFrames) as? NSNumber)?.intValue ?? 0
        let highThreshold: Int
        if let maxDelay = settings.maxFrameDelayCount, 0 < maxDelay {
            highThreshold = maxDelay
        } else {
            highThreshold = max(2, Int(ceil((settings.expectedFrameRate ?? 60.0) / 12.0)))
        }
        let lowThreshold = max(1, highThreshold / 2)
        let maxDropRatio = max(2, Int(ceil((settings.expectedFrameRate ?? 60.0) / 15.0)))
        if highThreshold < pending {
            dropRatio = min(dropRatio + 1, maxDropRatio)
            lastThrottleTime = now
        } else if pending < lowThreshold, 1 < dropRatio {
            dropRatio -= 1
            lastThrottleTime = now
        }
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        guard isRunning else {
            logger.debug("VideoCodec.append dropped: encoder not running")
            return
        }
        do {
            inputFormat = sampleBuffer.formatDescription
            if invalidateSession {
                logger.info("VideoCodec creating new session")
                if sampleBuffer.formatDescription?.isCompressed == true {
                    session = try VTSessionMode.decompression.makeSession(self)
                } else {
                    session = try VTSessionMode.compression.makeSession(self)
                }
                onLog?("session created: \(session != nil)")
            }
            let continuation = outputContinuation
            guard let session, let continuation else {
                onLog?("append dropped: session=\(session != nil) continuation=\(continuation != nil)")
                return
            }
            if sampleBuffer.formatDescription?.isCompressed == true {
                try session.convert(sampleBuffer, forceKeyFrame: false, continuation: continuation)
            } else {
                if useFrame(sampleBuffer.presentationTimeStamp) {
                    let forceKeyFrame = shouldForceKeyFrame(sampleBuffer.presentationTimeStamp)
                    let dropped = try session.convert(sampleBuffer, forceKeyFrame: forceKeyFrame, continuation: continuation)
                    if dropped {
                        logger.debug("VideoCodec frame dropped by VT", sampleBuffer.presentationTimeStamp)
                    }
                    updateAdaptiveDropRatio()
                    if forceKeyFrame {
                        lastKeyFramePresentationTimeStamp = sampleBuffer.presentationTimeStamp
                    }
                    presentationTimeStamp = sampleBuffer.presentationTimeStamp
                } else {
                    logger.debug("VideoCodec frame filtered by useFrame", sampleBuffer.presentationTimeStamp)
                }
            }
        } catch {
            logger.warn("VideoCodec.encode error: \(error)")
            resetSessionState(reason: "encode error \(error)", clearInputFormat: true)
            // Progressive backoff: after VT failure, halve the accepted-frame rate
            // by doubling the drop ratio (capped at the 15fps floor ratio).
            // This prevents rapid session-recreate loops when GPU is saturated.
            if settings.adaptiveFrameThrottle {
                let maxDropRatio = max(2, Int(ceil((settings.expectedFrameRate ?? 60.0) / 15.0)))
                dropRatio = min(dropRatio * 2, maxDropRatio)
                lastThrottleTime = Date()
            }
        }
        if let pending = session?.copyProperty(kVTCompressionPropertyKey_NumberOfPendingFrames) as? NSNumber {
            pendingFramesLogCounter += 1
            if pendingFramesLogCounter >= 60 {
                pendingFramesLogCounter = 0
                onLog?("[60FPS Debug] pending frames = \(pending)")
            }
        }
    }

    func makeImageBufferAttributes(_ mode: VTSessionMode) -> [NSString: AnyObject]? {
        switch mode {
        case .compression:
            var attributes: [NSString: AnyObject] = [:]
            if let inputFormat {
                // Specify the pixel format of the uncompressed video.
                let pixelFormat = CMFormatDescriptionGetMediaSubType(inputFormat)
                if !inputFormat.isCompressed {
                    attributes[kCVPixelBufferPixelFormatTypeKey] = NSNumber(value: pixelFormat)
                }
            }
            return attributes.isEmpty ? nil : attributes
        case .decompression:
            return [
                kCVPixelBufferIOSurfacePropertiesKey: NSDictionary(),
                kCVPixelBufferMetalCompatibilityKey: kCFBooleanTrue
            ]
        }
    }

    private func useFrame(_ presentationTimeStamp: CMTime) -> Bool {
        guard startedAt <= presentationTimeStamp else {
            return false
        }
        guard self.presentationTimeStamp < presentationTimeStamp else {
            return false
        }
        if 1 < dropRatio {
            frameCounter += 1
            return frameCounter % dropRatio == 0
        }
        // 以 sample buffer 實際 PTS 為準。只有 frameInterval > 0
        // （用戶手動設定）才過濾。expectedFrameRate 僅作為 VT 提示，不做幀率上限。
        guard 0 < frameInterval else {
            return true
        }
        return frameInterval <= presentationTimeStamp.seconds - self.presentationTimeStamp.seconds
    }

    private func shouldForceKeyFrame(_ presentationTimeStamp: CMTime) -> Bool {
        let duration = settings.effectiveMaxKeyFrameIntervalDuration
        guard 0 < duration else {
            return false
        }
        guard let lastKeyFramePresentationTimeStamp else {
            return true
        }
        return Double(duration) <= (presentationTimeStamp - lastKeyFramePresentationTimeStamp).seconds
    }

}


extension VideoCodec: Runner {
    // MARK: Running
    func startRunning() {
        guard !isRunning else {
            return
        }
        let (stream, continuation) = AsyncStream.makeStream(of: CMSampleBuffer.self)
        outputStream = stream
        outputContinuation = continuation
        startedAt = passthrough ? .zero : CMClockGetTime(CMClockGetHostTimeClock())
        isRunning = true
    }

    func stopRunning() {
        guard isRunning else {
            return
        }
        isRunning = false
        session = nil
        invalidateSession = true
        inputFormat = nil
        outputFormat = nil
        lastKeyFramePresentationTimeStamp = nil
        presentationTimeStamp = .zero
        outputContinuation?.finish()
        outputContinuation = nil
        startedAt = .zero
        dropRatio = 1
        frameCounter = 0
        lastThrottleTime = .distantPast
    }
}
