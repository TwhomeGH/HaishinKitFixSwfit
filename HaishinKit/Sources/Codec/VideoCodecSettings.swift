import Foundation
import VideoToolbox

/// Constraints on the video codec compression settings.
public struct VideoCodecSettings: Codable, Sendable {
    /// The number of frame rate for 30fps.
    public static let frameInterval30 = (1 / 30) - 0.001
    /// The number of frame rate for 10fps.
    public static let frameInterval10 = (1 / 10) - 0.001
    /// The number of frame rate for 5fps.
    public static let frameInterval05 = (1 / 05) - 0.001
    /// The number of frame rate for 1fps.
    public static let frameInterval01 = (1 / 01) - 0.001

    /// The defulat value.
    public static let `default` = VideoCodecSettings()

    /// A bitRate mode that affectes how to encode the video source.
    public struct BitRateMode: Sendable, CustomStringConvertible, Codable, Hashable, Equatable {
        public static func == (lhs: VideoCodecSettings.BitRateMode, rhs: VideoCodecSettings.BitRateMode) -> Bool {
            lhs.key == rhs.key
        }

        /// The average bit rate.
        public static let average = BitRateMode(key: .averageBitRate)

        /// The constant bit rate.
        @available(iOS 16.0, tvOS 16.0, macOS 13.0, *)
        public static let constant = BitRateMode(key: .constantBitRate)

        /// The variable bit rate.
        /// - seealso: [kVTCompressionPropertyKey_VariableBitRate](https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_variablebitrate)
        public static let variable = BitRateMode(key: .variableBitRate)

        /// The quality-based encoding (0.0 to 1.0).
        /// - seealso: [kVTCompressionPropertyKey_Quality](https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_quality)
        @available(iOS 8.0, tvOS 10.2, macOS 10.8, *)
        public static let quality = BitRateMode(key: .quality)

        let key: VTSessionOptionKey

        public var description: String {
            key.CFString as String
        }

        public func hash(into hasher: inout Hasher) {
            return hasher.combine(description)
        }
    }

    /**
     * The scaling mode.
     * - seealso: https://developer.apple.com/documentation/videotoolbox/kvtpixeltransferpropertykey_scalingmode
     * - seealso: https://developer.apple.com/documentation/videotoolbox/vtpixeltransfersession/pixel_transfer_properties/scaling_mode_constants
     */
    public enum ScalingMode: String, Codable, Sendable {
        /// kVTScalingMode_Normal
        case normal = "Normal"
        /// kVTScalingMode_Letterbox
        case letterbox = "Letterbox"
        /// kVTScalingMode_CropSourceToCleanAperture
        case cropSourceToCleanAperture = "CropSourceToCleanAperture"
        /// kVTScalingMode_Trim
        case trim = "Trim"
    }

    /// The type of the VideoCodec supports format.
    package enum Format: Codable, Sendable, CaseIterable {
        case h264
        case hevc

        #if os(macOS)
        var encoderID: NSString {
            switch self {
            case .h264:
                #if arch(arm64)
                return NSString(string: "com.apple.videotoolbox.videoencoder.ave.avc")
                #else
                return NSString(string: "com.apple.videotoolbox.videoencoder.h264.gva")
                #endif
            case .hevc:
                return NSString(string: "com.apple.videotoolbox.videoencoder.ave.hevc")
            }
        }
        #endif

        var codecType: UInt32 {
            switch self {
            case .h264:
                return kCMVideoCodecType_H264
            case .hevc:
                return kCMVideoCodecType_HEVC
            }
        }
    }

    /// Specifies the video size of encoding video.
    public var videoSize: CGSize
    /// Specifies the bitrate.
    public var bitRate: Int
    /// Specifies the H264 profileLevel.
    public var profileLevel: String {
        didSet {
            if profileLevel.contains("HEVC") {
                format = .hevc
            } else {
                format = .h264
            }
        }
    }
    /// Specifies the scalingMode.
    public var scalingMode: ScalingMode
    /// Specifies the bitRateMode.
    public var bitRateMode: BitRateMode
    /// Specifies the keyframeInterval.
    public var maxKeyFrameIntervalDuration: Int32
    /// Specifies the allowFrameRecording.
    public var allowFrameReordering: Bool? // swiftlint:disable:this discouraged_optional_boolean
    /// Specifies the dataRateLimits
    public var dataRateLimits: [Double]?
    /// Specifies the low-latency opretaion for an encoder.
    public var isLowLatencyRateControlEnabled: Bool
    /// Specifies the hardware accelerated encoder is enabled(TRUE), or not(FALSE) for macOS.
    public var isHardwareAcceleratedEnabled: Bool
    /// Specifies the video frame interval.
    public var frameInterval: Double = 0.0
    /// Specifies the expected frame rate for an encoder. It may optimize power consumption.
    public var expectedFrameRate: Double?

    /// Specifies the maximum bitrate for VBV buffer compliance (iOS 26.0+).
    public var vbvMaxBitRate: Int?

    /// Specifies the VBV buffer duration in seconds (iOS 26.0+).
    public var vbvBufferDuration: Double?

    /// Specifies the initial buffer delay percentage for VBV (iOS 26.0+).
    public var vbvInitialDelayPercentage: Double?

    /// An estimate of the expected size in bytes of a single encoded frame (iOS 17.0+).
    public var estimatedAverageBytesPerFrame: Int?

    /// The desired compression quality (0.0 to 1.0). Used when bitRateMode is .quality.
    public var quality: Float?

    package var format: Format = .h264

    /// Creates a new VideoCodecSettings instance.
    public init(
        videoSize: CGSize = .init(width: 854, height: 480),
        bitRate: Int = 640 * 1000,
        profileLevel: String = kVTProfileLevel_H264_Baseline_3_1 as String,
        scalingMode: ScalingMode = .trim,
        bitRateMode: BitRateMode = .average,
        maxKeyFrameIntervalDuration: Int32 = 2,
        // swiftlint:disable discouraged_optional_boolean
        allowFrameReordering: Bool? = nil,
        // swiftlint:enable discouraged_optional_boolean
        dataRateLimits: [Double]? = [0.0, 0.0],
        isLowLatencyRateControlEnabled: Bool = false,
        isHardwareAcceleratedEnabled: Bool = true,
        expectedFrameRate: Double? = nil,
        quality: Float? = nil
    ) {
        self.videoSize = videoSize
        self.bitRate = bitRate
        self.profileLevel = profileLevel
        self.scalingMode = scalingMode
        self.bitRateMode = bitRateMode
        self.maxKeyFrameIntervalDuration = maxKeyFrameIntervalDuration
        self.allowFrameReordering = allowFrameReordering
        self.dataRateLimits = dataRateLimits
        self.isLowLatencyRateControlEnabled = isLowLatencyRateControlEnabled
        self.isHardwareAcceleratedEnabled = isHardwareAcceleratedEnabled
        self.expectedFrameRate = expectedFrameRate
        self.quality = quality
        if profileLevel.contains("HEVC") {
            self.format = .hevc
        }
    }

    func invalidateSession(_ rhs: VideoCodecSettings) -> Bool {
        return !(videoSize == rhs.videoSize &&
                    scalingMode == rhs.scalingMode &&
                    allowFrameReordering == rhs.allowFrameReordering &&
                    bitRateMode == rhs.bitRateMode &&
                    profileLevel == rhs.profileLevel &&
                    dataRateLimits == rhs.dataRateLimits &&
                    isLowLatencyRateControlEnabled == rhs.isLowLatencyRateControlEnabled &&
                    isHardwareAcceleratedEnabled == rhs.isHardwareAcceleratedEnabled
        )
    }

    func apply(_ codec: VideoCodec, rhs: VideoCodecSettings) {
        if bitRate != rhs.bitRate {
            logger.info("bitRate change from ", rhs.bitRate, " to ", bitRate)
            let option = VTSessionOption(key: bitRateMode.key, value: NSNumber(value: bitRate))
            _ = codec.session?.setOption(option)
        }
        if frameInterval != rhs.frameInterval {
            codec.frameInterval = frameInterval
        }
        if expectedFrameRate != rhs.expectedFrameRate {
            let value = if let expectedFrameRate { expectedFrameRate } else { 0.0 }
            let option = VTSessionOption(key: .expectedFrameRate, value: value as CFNumber)
            _ = codec.session?.setOption(option)
        }
        if maxKeyFrameIntervalDuration != rhs.maxKeyFrameIntervalDuration {
            let option = VTSessionOption(key: .maxKeyFrameIntervalDuration, value: NSNumber(value: maxKeyFrameIntervalDuration))
            _ = codec.session?.setOption(option)
        }
        if #available(iOS 26.0, tvOS 26.0, macOS 26.0, *) {
            if vbvMaxBitRate != rhs.vbvMaxBitRate, let vbvMaxBitRate {
                let option = VTSessionOption(key: .vbvMaxBitRate, value: NSNumber(value: vbvMaxBitRate))
                _ = codec.session?.setOption(option)
            }
            if vbvBufferDuration != rhs.vbvBufferDuration, let vbvBufferDuration {
                let option = VTSessionOption(key: .vbvBufferDuration, value: NSNumber(value: vbvBufferDuration))
                _ = codec.session?.setOption(option)
            }
            if vbvInitialDelayPercentage != rhs.vbvInitialDelayPercentage, let vbvInitialDelayPercentage {
                let option = VTSessionOption(key: .vbvInitialDelayPercentage, value: NSNumber(value: vbvInitialDelayPercentage))
                _ = codec.session?.setOption(option)
            }
        }
        if #available(iOS 17.0, tvOS 17.0, macOS 14.0, *) {
            if estimatedAverageBytesPerFrame != rhs.estimatedAverageBytesPerFrame, let estimatedAverageBytesPerFrame {
                let option = VTSessionOption(key: .estimatedAverageBytesPerFrame, value: NSNumber(value: estimatedAverageBytesPerFrame))
                _ = codec.session?.setOption(option)
            }
        }
        if quality != rhs.quality, let quality {
            let option = VTSessionOption(key: .quality, value: NSNumber(value: quality))
            _ = codec.session?.setOption(option)
        }
    }

    // https://developer.apple.com/documentation/videotoolbox/encoding_video_for_live_streaming
    func makeOptions() -> Set<VTSessionOption> {
        let isBaseline = profileLevel.contains("Baseline")
        var options = Set<VTSessionOption>([
            .init(key: .realTime, value: kCFBooleanTrue),
            .init(key: .profileLevel, value: profileLevel as NSObject),
            .init(key: bitRateMode.key, value: NSNumber(value: bitRate)),
            .init(key: .maxKeyFrameIntervalDuration, value: NSNumber(value: maxKeyFrameIntervalDuration)),
            .init(key: .allowFrameReordering, value: (allowFrameReordering ?? !isBaseline) as NSObject),
            .init(key: .pixelTransferProperties, value: [
                "ScalingMode": scalingMode.rawValue
            ] as NSObject)
        ])
        if bitRateMode == .average {
            if let dataRateLimits, dataRateLimits.count == 2 {
                var limits = [Double](repeating: 0.0, count: 2)
                limits[0] = dataRateLimits[0] == 0 ? Double(bitRate) / 8 * 1.5 : dataRateLimits[0]
                limits[1] = dataRateLimits[1] == 0 ? Double(1.0) : dataRateLimits[1]
                options.insert(.init(key: .dataRateLimits, value: limits as NSArray))
            }
        }
        if bitRateMode == .quality, let quality {
            options.insert(.init(key: .quality, value: NSNumber(value: quality)))
        }
        if #available(iOS 26.0, tvOS 26.0, macOS 26.0, *) {
            if let vbvMaxBitRate {
                options.insert(.init(key: .vbvMaxBitRate, value: NSNumber(value: vbvMaxBitRate)))
            }
            if let vbvBufferDuration {
                options.insert(.init(key: .vbvBufferDuration, value: NSNumber(value: vbvBufferDuration)))
            }
            if let vbvInitialDelayPercentage {
                options.insert(.init(key: .vbvInitialDelayPercentage, value: NSNumber(value: vbvInitialDelayPercentage)))
            }
        }
        if #available(iOS 17.0, tvOS 17.0, macOS 14.0, *) {
            if let estimatedAverageBytesPerFrame {
                options.insert(.init(key: .estimatedAverageBytesPerFrame, value: NSNumber(value: estimatedAverageBytesPerFrame)))
            }
        }
        #if os(macOS)
        if isHardwareAcceleratedEnabled {
            options.insert(.init(key: .encoderID, value: format.encoderID))
            options.insert(.init(key: .enableHardwareAcceleratedVideoEncoder, value: kCFBooleanTrue))
            options.insert(.init(key: .requireHardwareAcceleratedVideoEncoder, value: kCFBooleanTrue))
        }
        #endif
        if !isBaseline && profileLevel.contains("H264") {
            options.insert(.init(key: .H264EntropyMode, value: kVTH264EntropyMode_CABAC))
        }
        return options
    }

    func makeEncoderSpecification() -> CFDictionary? {
        if isLowLatencyRateControlEnabled {
            return [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true as CFBoolean] as CFDictionary
        }
        return nil
    }
}
