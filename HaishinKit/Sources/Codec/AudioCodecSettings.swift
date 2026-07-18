import AVFAudio
import Foundation

/// Constraints on the audio codec compression settings.
public struct AudioCodecSettings: Codable, Sendable {
    /// The default value.
    public static let `default` = AudioCodecSettings()
    /// The default bitRate. The value is 64,000 bps.
    public static let defaultBitRate = 64 * 1000
    /// Maximum number of channels supported by the system
    public static let maximumNumberOfChannels: UInt32 = 8

    /// The type of the AudioCodec supports format.
    public enum Format: String, Codable, Sendable, CaseIterable {
        /// The AAC format.
        case aac
        /// The HE-AAC v1 format (AAC LC + SBR).
        case heAac
        /// The HE-AAC v2 format (AAC LC + SBR + Parametric Stereo).
        case heAacV2
        /// The OPUS format.
        case opus
        /// The PCM format.
        case pcm

        var formatID: AudioFormatID {
            switch self {
            case .aac:
                return kAudioFormatMPEG4AAC
            case .heAac:
                return kAudioFormatMPEG4AAC_HE
            case .heAacV2:
                return kAudioFormatMPEG4AAC_HE_V2
            case .opus:
                return kAudioFormatOpus
            case .pcm:
                return kAudioFormatLinearPCM
            }
        }

        var formatFlags: UInt32 {
            switch self {
            case .aac:
                return UInt32(MPEG4ObjectID.AAC_LC.rawValue)
            case .heAac:
                return UInt32(MPEG4ObjectID.AAC_SBR.rawValue)
            case .heAacV2:
                return UInt32(AudioSpecificConfig.AudioObjectType.aacPs.rawValue)
            case .opus:
                return 0
            case .pcm:
                return kAudioFormatFlagIsNonInterleaved
                    | kAudioFormatFlagIsPacked
                    | kAudioFormatFlagIsFloat
            }
        }

        var packetSize: UInt32 {
            switch self {
            case .aac:
                return 1
            case .heAac, .heAacV2:
                return 1
            case .opus:
                return 1
            case .pcm:
                return 1024
            }
        }

        var bitsPerChannel: UInt32 {
            switch self {
            case .aac, .heAac, .heAacV2, .opus:
                return 0
            case .pcm:
                return 32
            }
        }

        var bytesPerPacket: UInt32 {
            switch self {
            case .aac, .heAac, .heAacV2, .opus:
                return 0
            case .pcm:
                return (bitsPerChannel / 8)
            }
        }

        var bytesPerFrame: UInt32 {
            switch self {
            case .aac, .heAac, .heAacV2, .opus:
                return 0
            case .pcm:
                return (bitsPerChannel / 8)
            }
        }

        var inputBufferCounts: Int {
            switch self {
            case .aac, .heAac, .heAacV2, .opus:
                return 6
            case .pcm:
                return 1
            }
        }

        var outputBufferCounts: Int {
            switch self {
            case .aac, .heAac, .heAacV2, .opus:
                return 1
            case .pcm:
                return 24
            }
        }

        var supportedSampleRate: [Float64]? {
            switch self {
            case .opus:
                return [8000.0, 12000.0, 16000.0, 24000.0, 48000.0]
            default:
                return nil
            }
        }

        /// Checks whether this audio format is supported on the current device.
        var isDeviceSupported: Bool {
            switch self {
            case .heAacV2:
                return AudioCodecSettings.isAacFormatSupported(kAudioFormatMPEG4AAC_HE_V2)
            case .heAac:
                return AudioCodecSettings.isAacFormatSupported(kAudioFormatMPEG4AAC_HE)
            case .aac, .opus, .pcm:
                return true
            }
        }

        /// Human-readable description including the audio object type.
        public var audioDescription: String {
            switch self {
            case .aac:
                return "AAC LC"
            case .heAac:
                return "HE-AAC v1 (AAC+SBR)"
            case .heAacV2:
                return "HE-AAC v2 (AAC+SBR+PS)"
            case .opus:
                return "Opus"
            case .pcm:
                return "PCM"
            }
        }

        package func makeSampleRate(_ input: Float64, output: Float64) -> Float64 {
            let sampleRate = output == 0 ? input : output
            guard let supportedSampleRate else {
                return sampleRate
            }
            return supportedSampleRate.sorted { pow($0 - sampleRate, 2) < pow($1 - sampleRate, 2) }.first ?? sampleRate
        }

        func makeFramesPerPacket(_ sampleRate: Double) -> UInt32 {
            switch self {
            case .aac, .heAac, .heAacV2:
                return 1024
            case .opus:
                // https://www.rfc-editor.org/rfc/rfc6716#section-2.1.4
                let frameDurationSec = 0.02
                return UInt32(sampleRate * frameDurationSec)
            case .pcm:
                return 1
            }
        }

        func makeAudioBuffer(_ format: AVAudioFormat) -> AVAudioBuffer? {
            let maxPacketSize: Int
            switch self {
            case .heAacV2:
                maxPacketSize = 4096 * Int(format.channelCount)
            case .heAac:
                maxPacketSize = 2048 * Int(format.channelCount)
            default:
                maxPacketSize = 1024 * Int(format.channelCount)
            }
            switch self {
            case .aac, .heAac, .heAacV2, .opus:
                return AVAudioCompressedBuffer(format: format, packetCapacity: 1, maximumPacketSize: maxPacketSize)
            case .pcm:
                return AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)
            }
        }

        func makeOutputAudioFormat(_ format: AVAudioFormat, sampleRate: Float64, channelMap: [Int]?) -> AVAudioFormat? {
            let channelCount: UInt32
            if let channelMap {
                channelCount = UInt32(channelMap.count)
            } else {
                channelCount = format.channelCount
            }
            let mSampleRate = makeSampleRate(format.sampleRate, output: sampleRate)
            let config = AudioSpecificConfig.ChannelConfiguration(channelCount: channelCount)
            var streamDescription = AudioStreamBasicDescription(
                mSampleRate: mSampleRate,
                mFormatID: formatID,
                mFormatFlags: formatFlags,
                mBytesPerPacket: bytesPerPacket,
                mFramesPerPacket: makeFramesPerPacket(mSampleRate),
                mBytesPerFrame: bytesPerFrame,
                mChannelsPerFrame: min(
                    config?.channelCount ?? format.channelCount,
                    AudioCodecSettings.maximumNumberOfChannels
                ),
                mBitsPerChannel: bitsPerChannel,
                mReserved: 0
            )
            return AVAudioFormat(
                streamDescription: &streamDescription,
                channelLayout: config?.audioChannelLayout
            )
        }
    }

    /// The preferred AAC formats in order of preference (best first).
    public static let preferredAacFormats: [Format] = [.heAacV2, .heAac, .aac]

    /// Returns the best AAC format supported by the current device.
    /// Falls back through heAacV2 → heAac → aac.
    public static var bestAacFormat: Format {
        for format in preferredAacFormats {
            if format.isDeviceSupported {
                return format
            }
        }
        return .aac
    }

    /// Checks whether a specific AAC format ID is supported on the current device.
    package static func isAacFormatSupported(_ formatID: AudioFormatID) -> Bool {
        var inDesc = AudioStreamBasicDescription(
            mSampleRate: 44100,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8,
            mFramesPerPacket: 1,
            mBytesPerFrame: 8,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var outDesc = AudioStreamBasicDescription(
            mSampleRate: 44100,
            mFormatID: formatID,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 1024,
            mBytesPerFrame: 0,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        let inputFormat = AVAudioFormat(streamDescription: &inDesc)
        let outputFormat = AVAudioFormat(streamDescription: &outDesc)
        guard let inputFormat, let outputFormat else {
            return false
        }
        return AVAudioConverter(from: inputFormat, to: outputFormat) != nil
    }

    /// Specifies the bitRate of audio output.
    public var bitRate: Int

    /// Specifies the mixes the channels or not.
    public var downmix: Bool

    /// Specifies the map of the output to input channels.
    public var channelMap: [Int]?

    /// Specifies the sampleRate of audio output. A value of 0 will be the same as the main track source.
    public let sampleRate: Float64

    /// Specifies the output format.
    public var format: AudioCodecSettings.Format = .aac

    /// Creates a new instance.
    public init(
        bitRate: Int = AudioCodecSettings.defaultBitRate,
        downmix: Bool = true,
        channelMap: [Int]? = nil,
        sampleRate: Float64 = 0,
        format: AudioCodecSettings.Format = .aac
    ) {
        self.bitRate = bitRate
        self.downmix = downmix
        self.channelMap = channelMap
        self.sampleRate = sampleRate
        self.format = format
    }

    func apply(_ converter: AVAudioConverter?, oldValue: AudioCodecSettings?) {
        guard let converter else {
            return
        }
        if bitRate != oldValue?.bitRate {
            let minAvailableBitRate = converter.applicableEncodeBitRates?.min(by: { a, b in
                return a.intValue < b.intValue
            })?.intValue ?? bitRate
            let maxAvailableBitRate = converter.applicableEncodeBitRates?.max(by: { a, b in
                return a.intValue < b.intValue
            })?.intValue ?? bitRate
            converter.bitRate = min(maxAvailableBitRate, max(minAvailableBitRate, bitRate))
        }

        if downmix != oldValue?.downmix {
            converter.downmix = downmix
        }

        if channelMap != oldValue?.channelMap, let newChannelMap = validatedChannelMap(converter) {
            converter.channelMap = newChannelMap
        }
    }

    func invalidateConverter(_ rhs: AudioCodecSettings) -> Bool {
        return !(format == rhs.format && channelMap == rhs.channelMap)
    }

    private func validatedChannelMap(_ converter: AVAudioConverter) -> [NSNumber]? {
        guard let channelMap, channelMap.count == converter.outputFormat.channelCount else {
            return nil
        }
        for inputChannel in channelMap where converter.inputFormat.channelCount <= inputChannel {
            return nil
        }
        return channelMap.map { NSNumber(value: $0) }
    }
}
