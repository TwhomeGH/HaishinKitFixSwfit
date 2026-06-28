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
    @AsyncStreamedFlow
    var outputStream: AsyncStream<CMSampleBuffer>
    var frameInterval = VideoCodec.frameInterval
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
            let continuation = _outputStream.continuation
            guard let session, let continuation else {
                logger.debug("VideoCodec.append dropped: session=\(session != nil) continuation=\(continuation != nil)")
                return
            }
            if sampleBuffer.formatDescription?.isCompressed == true {
                try session.convert(sampleBuffer, forceKeyFrame: false, continuation: continuation)
            } else {
                if useFrame(sampleBuffer.presentationTimeStamp) {
                    let forceKeyFrame = shouldForceKeyFrame(sampleBuffer.presentationTimeStamp)
                    try session.convert(sampleBuffer, forceKeyFrame: forceKeyFrame, continuation: continuation)
                    if forceKeyFrame {
                        lastKeyFramePresentationTimeStamp = sampleBuffer.presentationTimeStamp
                    }
                    presentationTimeStamp = sampleBuffer.presentationTimeStamp
                }
            }
        } catch {
            logger.warn(error)
        }
    }

    func makeImageBufferAttributes(_ mode: VTSessionMode) -> [NSString: AnyObject]? {
        switch mode {
        case .compression:
            var attributes: [NSString: AnyObject] = [:]
            if let inputFormat {
                // Specify the pixel format of the uncompressed video.
                attributes[kCVPixelBufferPixelFormatTypeKey] = inputFormat.mediaType.rawValue as CFNumber
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
        let duration = settings.maxKeyFrameIntervalDuration
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
        invalidateSession = true
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
            invalidateSession = true
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
        _outputStream.finish()
        startedAt = .zero
        #if os(iOS) || os(tvOS) || os(visionOS)
        NotificationCenter.default.removeObserver(self, name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: UIApplication.willEnterForegroundNotification, object: nil)
        #endif
    }
}
