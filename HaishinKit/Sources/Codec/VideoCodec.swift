import AVFoundation
import CoreFoundation
import VideoToolbox
#if canImport(UIKit)
import UIKit
#endif

final class VideoCodec {
    static let frameInterval: Double = 0.0

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
    var outputStream: AsyncStream<CMSampleBuffer>
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
    /// Tracks consecutive clears before restoring 60fps (need ~30 for ~1s stability).
    private var pendingFramesResetCount: Int = 0
    /// When temporal compression is off and throttle activated, 10s cooldown
    /// prevents rapid 60↔30fps oscillation.
    private var throttleCooldownUntil: Date?
    /// Fallback throttle signal: timestamps from last 10 encode attempts.
    /// Used when `numberOfPendingFrames` is not supported by the device.
    private var encodeTimestamps: [Date] = []
    /// Input frame timestamps for computing proportional throttle.
    private var inputTimestamps: [Date] = []

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
        pendingFramesResetCount = 0
        encodeTimestamps.removeAll(keepingCapacity: true)
        inputTimestamps.removeAll(keepingCapacity: true)
    }

    /// Sets frameInterval to skip proportionally: encode at `fraction` of input rate.
    /// fraction=0.5 means encode half the input frames (30fps at 60fps input).
    /// Only throttles when input rate is above `minInputFps` to avoid double-reduction
    /// when the system has already lowered the capture rate.
    private func setProportionalThrottle(fraction: Double = 0.5, minInputFps: Double = 45.0) {
        let now = Date()
        inputTimestamps.append(now)
        if inputTimestamps.count > 10 {
            inputTimestamps.removeFirst()
        }
        guard inputTimestamps.count >= 10 else {
            frameInterval = 1.0 / minInputFps
            return
        }
        let interval = now.timeIntervalSince(inputTimestamps.first!)
        let inputFps = Double(inputTimestamps.count) / interval
        guard inputFps > minInputFps else {
            // Input already reduced by system; don't compound the throttle.
            return
        }
        let targetFps = inputFps * fraction
        frameInterval = 1.0 / max(15.0, targetFps)
    }

    private func checkFrameRate() {
        // Only trigger initial throttle (60→30) when running at full rate.
        // If already throttled (frameInterval > 0), avoid self-reinforcing loop
        // where limited encode rate (<25fps) keeps re-triggering.
        guard frameInterval == VideoCodec.frameInterval else { return }
        let now = Date()
        encodeTimestamps.append(now)
        if encodeTimestamps.count > 10 {
            encodeTimestamps.removeFirst()
        }
        if encodeTimestamps.count >= 10 {
            let interval = now.timeIntervalSince(encodeTimestamps.first!)
            let fps = 10.0 / interval
            if fps < 25 && settings.adaptiveFrameThrottle {
                setProportionalThrottle(fraction: 0.5)
                applyCavlcIfNeeded()
                if !settings.allowTemporalCompression {
                    throttleCooldownUntil = now.addingTimeInterval(10)
                }
            }
        }
    }

    private func applyCavlcIfNeeded() {
        guard settings.h264EntropyMode != "cavlc" else { return }
        var s = settings
        s.h264EntropyMode = "cavlc"
        settings = s
    }

    private func updateAdaptiveFrameInterval() {
        guard settings.adaptiveFrameThrottle else {
            frameInterval = VideoCodec.frameInterval
            pendingFramesResetCount = 0
            throttleCooldownUntil = nil
            return
        }
        let pending = (session?.copyProperty(kVTCompressionPropertyKey_NumberOfPendingFrames) as? NSNumber)?.intValue ?? 0
        let threshold = settings.maxFrameDelayCount ?? 5
        if pending > threshold {
            guard frameInterval == VideoCodec.frameInterval else {
                // 已降速中，不再累加，避免 60→30→15 鏈式衰退
                return
            }
            setProportionalThrottle(fraction: 0.5)
            pendingFramesResetCount = 0
            applyCavlcIfNeeded()
            throttleCooldownUntil = Date().addingTimeInterval(10)
        } else if pending <= threshold && frameInterval > VideoCodec.frameInterval {
            // numberOfPendingFrames returned 0 or is unsupported.
            // Use encode rate as fallback signal.
            checkFrameRate()
            if frameInterval > VideoCodec.frameInterval {
                // Throttle is active, check for recovery
                if throttleCooldownUntil == nil || Date() >= throttleCooldownUntil! {
                    pendingFramesResetCount += 1
                    if pendingFramesResetCount >= 30 {
                        throttleCooldownUntil = nil
                        frameInterval = VideoCodec.frameInterval
                    }
                } else {
                    pendingFramesResetCount = 0
                }
            }
        } else {
            pendingFramesResetCount = 0
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
                if sampleBuffer.formatDescription?.isCompressed == true {
                    session = try VTSessionMode.decompression.makeSession(self)
                } else {
                    session = try VTSessionMode.compression.makeSession(self)
                }
            }
            let continuation = outputContinuation
            guard let session, let continuation else {
                logger.debug("VideoCodec.append dropped: session=\(session != nil) continuation=\(continuation != nil)")
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
                }
            }
        } catch {
            logger.warn("VideoCodec.encode error: \(error)")
            resetSessionState(reason: "encode error \(error)", clearInputFormat: true)
            // Progressive backoff: after VT failure, reduce load immediately.
            // If already throttled, go lower; otherwise start at 15fps.
            // This prevents rapid session-recreate loops when GPU is saturated.
            if settings.adaptiveFrameThrottle {
                let currentMinFps = frameInterval > 0 ? (1.0 / frameInterval) : 60.0
                let newFps = max(8.0, currentMinFps / 2.0)
                frameInterval = 1.0 / newFps
                if !settings.allowTemporalCompression {
                    throttleCooldownUntil = Date().addingTimeInterval(15)
                }
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
        guard Self.frameInterval < frameInterval else {
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

    #if os(iOS) || os(tvOS) || os(visionOS)
    @objc
    private func applicationWillEnterForeground(_ notification: Notification) {
        resetSessionState(reason: "application will enter foreground", clearInputFormat: true)
    }

    @objc
    private func didAudioSessionInterruption(_ notification: Notification) {
        guard
            let userInfo: [AnyHashable: Any] = notification.userInfo,
            let value: NSNumber = userInfo[AVAudioSessionInterruptionTypeKey] as? NSNumber,
            let type = AVAudioSession.InterruptionType(rawValue: value.uintValue) else {
            return
        }
        switch type {
        case .ended:
            resetSessionState(reason: "audio session interruption ended", clearInputFormat: true)
        default:
            break
        }
    }
    #endif
}

extension VideoCodec: Runner {
    // MARK: Running
    func startRunning() {
        guard !isRunning else {
            return
        }
        #if os(iOS) || os(tvOS) || os(visionOS)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.didAudioSessionInterruption),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.applicationWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
        #endif
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
        #if os(iOS) || os(tvOS) || os(visionOS)
        NotificationCenter.default.removeObserver(self, name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: UIApplication.willEnterForegroundNotification, object: nil)
        #endif
    }
}
