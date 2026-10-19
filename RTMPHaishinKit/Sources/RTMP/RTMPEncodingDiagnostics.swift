import AVFoundation
import Foundation

/// 實際壓縮影片樣本的格式；未提供的色彩附件保持 nil，不以編碼設定補值。
public struct RTMPEncodedVideoFormat: Codable, Sendable, Equatable {
    /// CMFormatDescription 的 codec FourCC，例如 avc1 或 hvc1。
    public let codec: String
    /// H.264 avcC 的 profile／compatibility／level 六位十六進位識別碼；其他格式為 nil。
    public let avcConfiguration: String?
    /// 壓縮樣本描述的編碼寬度，單位 pixels。
    public let width: Int32
    /// 壓縮樣本描述的編碼高度，單位 pixels。
    public let height: Int32
    /// 色彩原色附件，缺漏為 nil。
    public let colorPrimaries: String?
    /// 轉移函數附件，缺漏為 nil。
    public let transferFunction: String?
    /// YCbCr 矩陣附件，缺漏為 nil。
    public let yCbCrMatrix: String?
    /// 格式描述明確提供的全範圍標記；nil 不等於 false。
    public let fullRange: Bool?
}

/// 實際壓縮音訊 buffer 的格式，不是 Mixer PCM 或目標設定。
public struct RTMPEncodedAudioFormat: Codable, Sendable, Equatable {
    /// ASBD format ID 的 FourCC，例如 aac（尾端空白保留）。
    public let codec: String
    /// 格式的取樣率，單位 Hz。
    public let sampleRate: Double
    /// 編碼輸出的聲道數。
    public let channels: UInt32
    /// 每封包 sample frames；格式宣告為 0 時表示可變或未指定。
    public let framesPerPacket: UInt32
}

/// 單一 RTMPStream 的壓縮輸出觀測；不代表封包已入列、送達或被伺服器解碼。
public struct RTMPEncodingDiagnostics: Codable, Sendable {
    /// Stream 實例識別，不包含串流名稱或金鑰。
    public let session: UUID
    /// 發布工作世代；停止、重新發布及管線重建後改變。
    public var generation: UInt64
    /// 快照讀取時是否處於 publishing。
    public var isPublishing = false
    /// 最近一次觀測到的影片格式；本世代尚無壓縮樣本時為 nil。
    public var video: RTMPEncodedVideoFormat?
    /// 最近一次觀測到的音訊格式；本世代尚無壓縮樣本時為 nil。
    public var audio: RTMPEncodedAudioFormat?
    /// 影片格式變更次數；不是硬體編碼器 session ID。
    public var videoFormatRevision: UInt64 = 0
    /// 音訊格式變更次數；不是硬體編碼器 session ID。
    public var audioFormatRevision: UInt64 = 0
    /// 影片格式首次出現或變更的觀測時間。
    public var videoFormatChangedAt: Date?
    /// 音訊格式首次出現或變更的觀測時間。
    public var audioFormatChangedAt: Date?
    /// 最近壓縮影片輸出的觀測時間；不是媒體 PTS。
    public var lastVideoOutputAt: Date?
    /// 最近壓縮音訊輸出的觀測時間；不是媒體 PTS。
    public var lastAudioOutputAt: Date?
    /// 本世代壓縮影片樣本累計。
    public var videoFrames: UInt64 = 0
    /// 本世代壓縮音訊 packet 累計，不是 buffer 或 RTMP chunk 數。
    public var audioPackets: UInt64 = 0
    /// 本世代壓縮影片 payload bytes，不含 RTMP 標頭。
    public var videoBytes: UInt64 = 0
    /// 本世代壓縮音訊 payload bytes，不含 RTMP 標頭。
    public var audioBytes: UInt64 = 0
}

/// 僅由 RTMPStream actor 存取；保留小型格式描述，不保存媒體 buffer。
struct RTMPEncodingTracker {
    private var value = RTMPEncodingDiagnostics(session: UUID(), generation: 0)
    private var videoDescription: CMFormatDescription?
    private var audioDescription: AVAudioFormat?

    /// 切換發布世代時清空格式、時間及計數，避免前次結果冒充新輸出。
    mutating func reset(generation: UInt64) {
        value = RTMPEncodingDiagnostics(session: value.session, generation: generation)
        videoDescription = nil
        audioDescription = nil
    }

    /// 回傳值型別快照，不暴露 CoreMedia／AVFoundation 物件。
    func snapshot(isPublishing: Bool) -> RTMPEncodingDiagnostics {
        var result = value
        result.isPublishing = isPublishing
        return result
    }

    /// 只接收已壓縮影片；同一格式只解析一次附件，原始像素樣本不計入。
    mutating func record(video sample: CMSampleBuffer, now: Date = Date()) {
        guard let format = sample.formatDescription,
              CMFormatDescriptionGetMediaType(format) == kCMMediaType_Video,
              sample.imageBuffer == nil, CMSampleBufferGetTotalSampleSize(sample) > 0 else { return }
        if videoDescription != format {
            videoDescription = format
            let dimensions = CMVideoFormatDescriptionGetDimensions(format)
            func text(_ key: CFString) -> String? {
                CMFormatDescriptionGetExtension(format, extensionKey: key).map { String(describing: $0) }
            }
            let atoms = CMFormatDescriptionGetExtension(format,
                extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any]
            let avc = atoms?["avcC"] as? Data
            let configuration: String?
            if CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_H264,
               let avc, avc.count >= 4, avc[avc.startIndex] == 1 {
                configuration = avc.dropFirst().prefix(3).map { String(format: "%02X", $0) }.joined()
            } else {
                configuration = nil
            }
            value.video = RTMPEncodedVideoFormat(
                codec: Self.fourCC(CMFormatDescriptionGetMediaSubType(format)), avcConfiguration: configuration,
                width: dimensions.width, height: dimensions.height,
                colorPrimaries: text(kCMFormatDescriptionExtension_ColorPrimaries),
                transferFunction: text(kCMFormatDescriptionExtension_TransferFunction),
                yCbCrMatrix: text(kCMFormatDescriptionExtension_YCbCrMatrix),
                fullRange: (CMFormatDescriptionGetExtension(format,
                    extensionKey: kCMFormatDescriptionExtension_FullRangeVideo) as? NSNumber)?.boolValue)
            value.videoFormatRevision &+= 1
            value.videoFormatChangedAt = now
        }
        value.videoFrames &+= UInt64(CMSampleBufferGetNumSamples(sample))
        value.videoBytes &+= UInt64(CMSampleBufferGetTotalSampleSize(sample))
        value.lastVideoOutputAt = now
    }

    /// 只計入實際含資料的壓縮 buffer；PCM 與空 buffer 不代表編碼成功。
    mutating func record(audio buffer: AVAudioCompressedBuffer, now: Date = Date()) {
        guard buffer.packetCount > 0, buffer.byteLength > 0 else { return }
        if audioDescription != buffer.format {
            audioDescription = buffer.format
            let format = buffer.format.streamDescription.pointee
            value.audio = RTMPEncodedAudioFormat(codec: Self.fourCC(format.mFormatID),
                sampleRate: format.mSampleRate, channels: format.mChannelsPerFrame,
                framesPerPacket: format.mFramesPerPacket)
            value.audioFormatRevision &+= 1
            value.audioFormatChangedAt = now
        }
        value.audioPackets &+= UInt64(buffer.packetCount)
        value.audioBytes &+= UInt64(buffer.byteLength)
        value.lastAudioOutputAt = now
    }

    private static func fourCC(_ value: UInt32) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) }, encoding: .ascii) ?? String(value)
    }
}
