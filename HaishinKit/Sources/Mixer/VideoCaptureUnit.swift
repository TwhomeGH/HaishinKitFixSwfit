import AVFoundation
import CoreImage

final class VideoCaptureUnit: CaptureUnit {
    enum Error: Swift.Error {
        case multiCamNotSupported
    }

    let lockQueue = DispatchQueue(label: "com.haishinkit.HaishinKit.VideoCaptureUnit.lock")

    private(set) var isSuspended = false

    var mixerSettings: VideoMixerSettings {
        get {
            return videoMixer.settings
        }
        set {
            videoMixer.settings = newValue
        }
    }

    var inputFormats: [UInt8: CMFormatDescription] {
        return videoMixer.inputFormats
    }

    #if os(iOS) || os(tvOS) || os(macOS)
    var isTorchEnabled = false {
        didSet {
            guard #available(tvOS 17.0, *) else {
                return
            }
            setTorchMode(isTorchEnabled ? .on : .off)
        }
    }
    #endif

    @available(tvOS 17.0, *)
    var hasDevice: Bool {
        !devices.lazy.filter { $0.value.device != nil }.isEmpty
    }

    #if os(iOS) || os(macOS)
    var videoOrientation: AVCaptureVideoOrientation = .portrait {
        didSet {
            guard videoOrientation != oldValue else {
                return
            }
            session.configuration { _ in
                for capture in devices.values {
                    capture.videoOrientation = videoOrientation
                }
            }
        }
    }
    #endif

    private let inputQueue: AdaptiveMediaFlow<(UInt8, CMSampleBuffer)>
    private let outputQueue: AdaptiveMediaFlow<CMSampleBuffer>
    var inputs: AsyncStream<(UInt8, CMSampleBuffer)> { inputQueue.stream() }
    var output: AsyncStream<CMSampleBuffer> { outputQueue.stream() }

    func setQueueLimits(totalBytes: Int, maxAge: TimeInterval) {
        // Independent branches share an explicit aggregate reservation.
        let perBranch = max(0, totalBytes) / 2
        inputQueue.update(maxBytes: perBranch, maxAge: maxAge)
        outputQueue.update(maxBytes: perBranch, maxAge: maxAge)
    }

    func queueDiagnostics() -> String {
        "input{\(inputQueue.diagnostics())} output{\(outputQueue.diagnostics())}"
    }

    /// 相機擷取端目前使用的動態範圍；只在 tvOS 17+ 會套用到 AVCaptureDevice format。
    private(set) var dynamicRangeMode: DynamicRangeMode = .sdr

    /// 設定相機動態範圍；相機不支援時把 VideoDeviceUnit 的錯誤原樣往上拋。
    /// iOS 目前沒有這條相機 format 路徑，因此會直接更新狀態、不拋錯。
    /// 只調整相機擷取端的 frame rate；沒有 camera device 時是 no-op。
    /// 不影響 offscreen display link，也不影響 encoder 的 expected frame rate。
    func setFrameRate(_ frameRate: Float64) throws {
        #if os(tvOS)
        if #available(tvOS 17.0, *) {
            for device in devices.values {
                try device.setFrameRate(frameRate)
            }
        }
        #endif
    }

    func setDynamicRangeMode(_ mode: DynamicRangeMode) throws {
        guard mode != dynamicRangeMode else { return }
        if #available(tvOS 17.0, *) {
            try session.configuration { _ in
                for capture in devices.values {
                    try capture.setDynamicRangeMode(mode)
                }
            }
        }
        dynamicRangeMode = mode
    }

    private lazy var videoMixer = {
        var videoMixer = VideoMixer<VideoCaptureUnit>()
        videoMixer.delegate = self
        return videoMixer
    }()

    #if os(tvOS)
    private var _devices: [UInt8: Any] = [:]
    @available(tvOS 17.0, *)
    var devices: [UInt8: VideoDeviceUnit] {
        get {
            _devices as! [UInt8: VideoDeviceUnit]
        }
        set {
            _devices = newValue
        }
    }
    #elseif os(iOS) || os(macOS) || os(visionOS)
    var devices: [UInt8: VideoDeviceUnit] = [:]
    #endif

    private let session: (any CaptureSessionConvertible)

    init(_ session: (some CaptureSessionConvertible),
         inputQueue: AdaptiveMediaFlow<(UInt8, CMSampleBuffer)> = AdaptiveMediaFlow(),
         outputQueue: AdaptiveMediaFlow<CMSampleBuffer> = AdaptiveMediaFlow()) {
        self.session = session
        self.inputQueue = inputQueue
        self.outputQueue = outputQueue
    }

    func append(_ track: UInt8, buffer: CMSampleBuffer) {
        videoMixer.append(track, sampleBuffer: buffer)
    }

    @available(tvOS 17.0, *)
    func attachVideo(_ track: UInt8, device: AVCaptureDevice?, configuration: VideoDeviceConfigurationBlock?) throws {
        try session.configuration { _ in
            session.detachCapture(devices[track])
            videoMixer.reset(track)
            devices[track] = nil
            if let device {
                if hasDevice && session.isMultiCamSessionEnabled == false {
                    throw Error.multiCamNotSupported
                }
                let capture = try VideoDeviceUnit(track, device: device)
                try capture.setDynamicRangeMode(dynamicRangeMode)
                #if os(iOS) || os(macOS)
                capture.videoOrientation = videoOrientation
                #endif
                capture.setSampleBufferDelegate(self)
                try? configuration?(capture)
                session.attachCapture(capture)
                capture.apply()
                devices[track] = capture
            }
        }
    }

    #if os(iOS) || os(tvOS) || os(macOS)
    @available(tvOS 17.0, *)
    func setTorchMode(_ torchMode: AVCaptureDevice.TorchMode) {
        for capture in devices.values {
            capture.setTorchMode(torchMode)
        }
    }
    #endif

    @available(tvOS 17.0, *)
    func makeDataOutput(_ track: UInt8) -> VideoCaptureUnitDataOutput {
        return .init(track: track, videoMixer: videoMixer)
    }

    @available(tvOS 17.0, *)
    func suspend() {
        guard !isSuspended else {
            return
        }
        for capture in devices.values {
            session.detachCapture(capture)
        }
        isSuspended = true
    }

    @available(tvOS 17.0, *)
    func resume() {
        guard isSuspended else {
            return
        }
        for capture in devices.values {
            session.attachCapture(capture)
        }
        isSuspended = false
    }

    func finish() {
        inputQueue.finish()
        outputQueue.finish()
    }
}

extension VideoCaptureUnit: VideoMixerDelegate {
    // MARK: VideoMixerDelegate
    func videoMixer(_ videoMixer: VideoMixer<VideoCaptureUnit>, track: UInt8, didInput sampleBuffer: CMSampleBuffer) {
        inputQueue.offer((track, sampleBuffer), bytes: sampleBuffer.imageBuffer.map { CVPixelBufferGetDataSize($0) } ?? CMSampleBufferGetTotalSampleSize(sampleBuffer))
    }

    func videoMixer(_ videoMixer: VideoMixer<VideoCaptureUnit>, didOutput sampleBuffer: CMSampleBuffer) {
        outputQueue.offer(sampleBuffer, bytes: sampleBuffer.imageBuffer.map { CVPixelBufferGetDataSize($0) } ?? CMSampleBufferGetTotalSampleSize(sampleBuffer))
    }
}
