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
    /// Consecutive clear checks before recovering frame rate.
    private var clearStreak: Int = 0
    /// Consecutive high-pending checks before throttling down (avoid single-spike triggers).
    private var highPendingStreak: Int = 0
    /// Accumulates pending-frame log entries; fires on every 60th frame (~1Hz at 60fps).
    private var pendingFramesLogCounter: Int = 0
    /// Last throttle-down time, minimum 500ms between steps.
    private var lastThrottleTime: Date = .distantPast
    /// Tracks actual incoming frame interval for adaptive throttle baseline.
    private var lastFrameTime: Date = .distantPast
    private var smoothedFrameInterval: Double = 1.0 / 60.0

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
        clearStreak = 0
        highPendingStreak = 0
        lastThrottleTime = .distantPast
        lastFrameTime = .distantPast
        smoothedFrameInterval = 1.0 / 60.0
    }

    /// Adaptive frame throttle: only engages when VT is *sustained* overloaded
    /// (3 consecutive high-pending checks), reduces by 10% per step (min 20fps),
    /// and restores the baseline immediately after 5 consecutive clear checks.
    /// Design goal: barely interfere during normal operation.
    private func updateAdaptiveFrameInterval() {
        let now = Date()
        if lastFrameTime != .distantPast {
            let actualInterval = now.timeIntervalSince(lastFrameTime)
            // Exponential moving average with 0.3 alpha to smooth out jitter
            smoothedFrameInterval = smoothedFrameInterval * 0.7 + actualInterval * 0.3
        }
        lastFrameTime = now

        guard settings.adaptiveFrameThrottle else {
            frameInterval = VideoCodec.frameInterval
            clearStreak = 0
            highPendingStreak = 0
            lastThrottleTime = .distantPast
            lastFrameTime = .distantPast
            smoothedFrameInterval = 1.0 / 60.0
            return
        }
        let pending = (session?.copyProperty(kVTCompressionPropertyKey_NumberOfPendingFrames) as? NSNumber)?.intValue ?? 0
        let threshold: Int
        if let maxDelay = settings.maxFrameDelayCount, 0 < maxDelay {
            threshold = maxDelay
        } else {
            threshold = max(2, Int(ceil((settings.expectedFrameRate ?? 60.0) / 12.0)))
        }
        if pending > threshold {
            // Sustained overload: need 3 consecutive high checks before throttling.
            highPendingStreak += 1
            clearStreak = 0
            guard 3 <= highPendingStreak else { return }
            guard 0.5 < now.timeIntervalSince(lastThrottleTime) else { return }
            lastThrottleTime = now
            let currentFps = frameInterval > 0 ? 1.0 / frameInterval : 1.0 / smoothedFrameInterval
            let targetFps = currentFps * 0.90
            frameInterval = 1.0 / max(20.0, targetFps)
        } else {
            highPendingStreak = 0
            if frameInterval > VideoCodec.frameInterval {
                clearStreak += 1
                // Fast recovery: restore baseline after 5 consecutive clear checks (~170ms at 30fps).
                if 5 <= clearStreak {
                    frameInterval = VideoCodec.frameInterval
                    clearStreak = 0
                }
            } else {
                clearStreak = 0
            }
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
                    updateAdaptiveFrameInterval()
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
            // Progressive backoff: after VT failure, reduce load immediately.
            // If already throttled, go lower; otherwise start at 15fps.
            // This prevents rapid session-recreate loops when GPU is saturated.
            if settings.adaptiveFrameThrottle {
                clearStreak = 0
                let currentFps = frameInterval > 0 ? (1.0 / frameInterval) : 60.0
                let newFps = max(8.0, currentFps / 2.0)
                frameInterval = 1.0 / newFps
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
        // 以 sample buffer 實際 PTS 為準。只有 frameInterval > 0
        // （用戶手動設定或 adaptiveFrameThrottle 介入）才過濾。
        // expectedFrameRate 僅作為 VT 提示，不做幀率上限。
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
        lastFrameTime = .distantPast
        smoothedFrameInterval = 1.0 / 60.0
    }
}
