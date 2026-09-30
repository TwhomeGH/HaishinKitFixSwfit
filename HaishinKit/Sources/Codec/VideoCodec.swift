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
    /// 追蹤此 VT session 的輸出狀態：等 keyframe / 非同步失敗 / 最後已確認的
    /// keyframe。`session` 一被替換就換成新的實例，避免舊 session 的 callback
    /// 回來時污染新 session（見 VideoEncoderOutputState）。
    let diagnostics = VideoPipelineEventTracker()
    private lazy var encoderOutputState = VideoEncoderOutputState(diagnostics: diagnostics)
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
            // 先作廢舊 state（舊 session 尚在途的 callback 立即被忽略），再 invalidate
            // 舊 session，最後換上全新的 state。順序不能顛倒：若先換新 state，舊
            // callback 可能在換的瞬間被新 state 放行。
            encoderOutputState.invalidate()
            oldValue?.invalidate()
            encoderOutputState = VideoEncoderOutputState(diagnostics: diagnostics)
            diagnostics.record(.encoderSessionChanged)
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
    /// Measured source cadence from raw-frame PTS deltas (EMA). Basis for the
    /// keyframe frame-count interval and the VT `expectedFrameRate` hint when
    /// the user has not declared one — never a hardcoded 30fps guess.
    private var lastRawFramePTSSeconds: Double?
    private var measuredFrameInterval: Double?
    var measuredFrameRate: Double? {
        measuredFrameInterval.map { 1.0 / $0 }
    }
    /// Last frame rate pushed into the VT session (refresh throttle).
    private var lastPushedFrameRate: Double?

    /// EMA of the real frame cadence from sample-buffer PTS deltas. Ignored
    /// frames (useFrame filter / drop ratio) don't advance the source clock —
    /// the source keeps delivering, so measure on every delivered raw frame.
    private func updateMeasuredFrameRate(_ presentationTimeStamp: CMTime) {
        let seconds = presentationTimeStamp.seconds
        guard seconds.isFinite, 0 < seconds else {
            return
        }
        if let last = lastRawFramePTSSeconds {
            let delta = seconds - last
            if delta.isFinite, 0 < delta {
                if let current = measuredFrameInterval {
                    measuredFrameInterval = current * 0.8 + delta * 0.2
                } else {
                    measuredFrameInterval = delta
                }
            }
        }
        lastRawFramePTSSeconds = seconds
    }

    /// Push the measured cadence into the VT session once it settles (session
    /// is created on the first frame, before any delta is measurable). Only
    /// when the user hasn't declared `expectedFrameRate`.
    private func refreshMeasuredRateOptions() {
        guard settings.expectedFrameRate == nil,
              let measuredFrameRate, measuredFrameRate.isFinite, 0 < measuredFrameRate,
              let session
        else {
            return
        }
        if let last = lastPushedFrameRate, abs(measuredFrameRate - last) / last <= 0.1 {
            return
        }
        lastPushedFrameRate = measuredFrameRate
        _ = session.setOption(.init(key: .expectedFrameRate, value: measuredFrameRate as CFNumber))
        for option in settings.makeKeyFrameIntervalOptions(measuredFrameRate: measuredFrameRate) {
            _ = session.setOption(option)
        }
    }

    private func resetSessionState(reason: @autoclosure () -> String, clearInputFormat: Bool) {
        logger.info("VideoCodec reset session:", reason())
        session = nil
        invalidateSession = true
        if clearInputFormat {
            inputFormat = nil
        }
        outputFormat = nil
        presentationTimeStamp = .zero
        dropRatio = 1
        frameCounter = 0
        lastThrottleTime = .distantPast
        lastRawFramePTSSeconds = nil
        measuredFrameInterval = nil
        lastPushedFrameRate = nil
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
            diagnostics.record(.encoderUnavailable)
            logger.debug("VideoCodec.append dropped: encoder not running")
            return
        }
        if sampleBuffer.formatDescription?.isCompressed == false {
            updateMeasuredFrameRate(sampleBuffer.presentationTimeStamp)
        }
        do {
            // 上一輪若 VT callback 回報非同步 encode 失敗，先在此把錯誤拋出，
            // 觸發下方 catch 的 session 重建（resetSessionState），而不是繼續餵
            // 一個已壞掉的 session。
            if let status = encoderOutputState.takeFailure() {
                throw VTSessionError.failedToConvert(status: status)
            }
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
                diagnostics.record(.encoderUnavailable)
                onLog?("append dropped: session=\(session != nil) continuation=\(continuation != nil)")
                return
            }
            if sampleBuffer.formatDescription?.isCompressed == true {
                try session.convert(sampleBuffer, forceKeyFrame: false, continuation: continuation, outputState: encoderOutputState)
            } else {
                if useFrame(sampleBuffer.presentationTimeStamp) {
                    // forceKeyFrame 由 state 決定：開場 / GOP 斷點後為 true，
                    // 之後依 interval 週期性要求。
                    let forceKeyFrame = shouldForceKeyFrame(sampleBuffer.presentationTimeStamp)
                    let dropped = try session.convert(sampleBuffer, forceKeyFrame: forceKeyFrame, continuation: continuation, outputState: encoderOutputState)
                    if dropped {
                        // VT 同步回報 frameDropped：同樣視為 GOP 斷點，回到等 keyframe。
                        encoderOutputState.dropped()
                        logger.debug("VideoCodec frame dropped by VT", sampleBuffer.presentationTimeStamp)
                    }
                    updateAdaptiveDropRatio()
                    presentationTimeStamp = sampleBuffer.presentationTimeStamp
                } else {
                    diagnostics.record(.encoderFiltered)
                    logger.debug("VideoCodec frame filtered by useFrame", sampleBuffer.presentationTimeStamp)
                }
            }
        } catch {
            diagnostics.record(.encoderRecovery)
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
        refreshMeasuredRateOptions()
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
        // 判斷交給 state：它記錄的是「最後一顆被確認的 keyframe」而非「最後一次
        // 要求 keyframe」。舊寫法（用 lastKeyFramePresentationTimeStamp）會把
        // 「已要求」誤當「已成功」，若該 keyframe 被 VT 丟棄就整段卡住。
        encoderOutputState.shouldForceKeyFrame(
            at: presentationTimeStamp.seconds,
            interval: Double(settings.effectiveMaxKeyFrameIntervalDuration)
        )
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
        presentationTimeStamp = .zero
        outputContinuation?.finish()
        outputContinuation = nil
        startedAt = .zero
        dropRatio = 1
        frameCounter = 0
        lastThrottleTime = .distantPast
        lastRawFramePTSSeconds = nil
        measuredFrameInterval = nil
        lastPushedFrameRate = nil
    }
}
