import HaishinKit

// MARK: - E-RTMP Audio FourCC (Enhanced RTMP)
enum RTMPAudioFourCC: UInt32, CustomStringConvertible {
    case ac3 = 0x61632D33 // ac-3
    case eac3 = 0x65632D33  // ec-3
    case opus = 0x4F707573 // Opus
    case mp3 = 0x2E6D7033 // .mp3
    case flac = 0x664C6143 // fLaC
    case aac = 0x6D703461 // mp4a
    case unknown = 0x00000000

    var description: String {
        switch self {
        case .ac3:
            return "ac-3"
        case .eac3:
            return "ec-3"
        case .opus:
            return "Opus"
        case .mp3:
            return ".mp3"
        case .flac:
            return "fLaC"
        case .aac:
            return "mp4a"
        case .unknown:
            return "unknown"
        }
    }

    var isSupported: Bool {
        switch self {
        case .opus:
            return true
        default:
            return false
        }
    }

    init(bytes: [UInt8]) {
        guard bytes.count >= 4 else {
            self = .unknown
            return
        }
        let value = UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
        self = RTMPAudioFourCC(rawValue: value) ?? .unknown
    }
}

// MARK: - E-RTMP Audio Packet Types
enum RTMPAudioPacketType: UInt8 {
    case sequenceStart = 0
    case codedFrames = 1
    case sequenceEnd = 2
    case multiChannelConfig = 4
    case multiTrack = 5
    case modEx = 7
}

// MARK: - E-RTMP Audio ModEx
enum RTMPAudioPacketModExType: Int {
    case timestampOffsetNano = 0
}

// MARK: - E-RTMP Multi-Track
enum RTMPAVMultiTrackType: Int {
    case oneTrack = 0
    case manyTracks = 1
    case manyTracksManyCOdecs = 2
}

// MARK: - E-RTMP Audio Channel Order
enum RTMPAudioChannelOrder: Int {
    case unspecified = 0
    case native = 1
    case custom = 2
}

// MARK: - E-RTMP Video FourCC
enum RTMPVideoFourCC: UInt32, CustomStringConvertible {
    case av1 = 0x61763031 // av01
    case vp9 = 0x76703039 // vp09
    case hevc = 0x68766331 // hvc1
    case unknown = 0x00000000

    var description: String {
        switch self {
        case .av1:
            return "av01"
        case .vp9:
            return "vp09"
        case .hevc:
            return "hvc1"
        case .unknown:
            return "unknown"
        }
    }

    var isSupported: Bool {
        switch self {
        case .hevc, .vp9, .av1:
            return true
        default:
            return false
        }
    }

    init(bytes: [UInt8]) {
        guard bytes.count >= 4 else {
            self = .unknown
            return
        }
        let value = UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
        self = RTMPVideoFourCC(rawValue: value) ?? .unknown
    }
}

// MARK: - E-RTMP Video Packet Types
enum RTMPVideoPacketType: UInt8 {
    case sequenceStart = 0
    case codedFrames = 1
    case sequenceEnd = 2
    case codedFramesX = 3
    case metadata = 4
    case mpeg2TSSequenceStart = 5
}

// MARK: - E-RTMP Codec Negotiation
enum EnhancedRTMPCapability {
    static let supportsEnhancedRTMP = 0x01
    static let supportsMultitrack = 0x02
    static let supportsModEx = 0x04
    static let supportsTimestampNanoOffset = 0x08
}

// MARK: - Codec ID Mapping
extension AudioCodecSettings.Format {
    var codecid: Int {
        switch self {
        case .aac:
            return Int(RTMPAudioCodec.aac.rawValue)
        case .opus:
            return Int(RTMPAudioFourCC.opus.rawValue)
        case .pcm:
            return Int(RTMPAudioCodec.pcm.rawValue)
        }
    }

    var enhancedAudioType: RTMPAudioFourCC? {
        switch self {
        case .opus:
            return .opus
        default:
            return nil
        }
    }
}

extension VideoCodecSettings.Format {
    var codecid: Int {
        switch self {
        case .h264:
            return Int(RTMPVideoCodec.avc.rawValue)
        case .hevc:
            return Int(RTMPVideoFourCC.hevc.rawValue)
        case .vp9:
            return Int(RTMPVideoFourCC.vp9.rawValue)
        case .av1:
            return Int(RTMPVideoFourCC.av1.rawValue)
        }
    }

    var enhancedVideoType: RTMPVideoFourCC? {
        switch self {
        case .hevc:
            return .hevc
        case .vp9:
            return .vp9
        case .av1:
            return .av1
        default:
            return nil
        }
    }
}
