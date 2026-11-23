import CoreMedia
import Foundation

/// 上游交付與底層接收的同幀識別；只保存數值，不持有畫面。
/// session + sequence 由上游產生；不能用 PTS 當唯一識別，因為來源可能重複或倒退。
/// `sourcePTS` 是媒體時間軸上的 PTS；真正的抓幀／顯示時間另存於
/// `captureHostTime`，必須與 `handedUptime` 使用同一個 systemUptime 時鐘。
public struct VideoFrameTrace: Codable, Sendable {
    /// 上游擷取工作階段。
    public let session: String
    /// 該工作階段的來源影格序號。
    public let sequence: UInt64
    /// 加工前來源 PTS；無效時間為 nil。
    public let sourcePTS: Double?
    /// 真正的抓幀／顯示時間，單位為 systemUptime 秒數；nil 表示未提供。
    public let captureHostTime: Double?
    /// `captureHostTime` 的來源；沒有值時為 `.unknown`。
    public let captureTimeSource: VideoFrameCaptureTimeSource
    /// 上游實際交給 mixer 的 PTS。
    public let handedPTS: Double?
    /// 上游交付時的 systemUptime 秒數。
    public let handedUptime: Double
    /// 底層 mixer 收到時的 PTS；尚未接收為 nil。
    public private(set) var receivedPTS: Double?
    /// 底層 mixer 收到時的 systemUptime 秒數。
    public private(set) var receivedUptime: Double?

    /// 建立交付識別。uptime 必須使用同程序的單調時鐘，不能填牆鐘或來源 PTS。
    /// - Parameters:
    ///   - sourcePTS: 媒體時間軸上的來源 PTS，用於 A/V 配對。
    ///   - handedPTS: 實際交給 mixer 的媒體 PTS。
    ///   - captureHostTime: 真正的抓幀／顯示時間，必須與 `handedUptime` 同時鐘。
    ///   - captureTimeSource: 抓幀時間的來源；沒有時間時應為 `.unknown`。
    public init(session: String, sequence: UInt64, sourcePTS: Double, handedPTS: Double,
                handedUptime: Double = ProcessInfo.processInfo.systemUptime,
                captureHostTime: Double? = nil,
                captureTimeSource: VideoFrameCaptureTimeSource = .unknown) {
        self.session = session
        self.sequence = sequence
        self.sourcePTS = sourcePTS.isFinite ? sourcePTS : nil
        self.handedPTS = handedPTS.isFinite ? handedPTS : nil
        self.handedUptime = handedUptime
        let validHost = captureHostTime.flatMap { $0.isFinite ? $0 : nil }
        self.captureHostTime = validHost
        self.captureTimeSource = validHost == nil ? .unknown : captureTimeSource
    }

    private enum CodingKeys: String, CodingKey {
        case session, sequence, sourcePTS, captureHostTime, captureTimeSource
        case handedPTS, handedUptime, receivedPTS, receivedUptime
    }

    /// 舊 JSON 沒有抓幀時間欄位時解為未知，不讓新增欄位破壞既有診斷報告。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        session = try container.decode(String.self, forKey: .session)
        sequence = try container.decode(UInt64.self, forKey: .sequence)
        sourcePTS = try container.decodeIfPresent(Double.self, forKey: .sourcePTS)
        captureHostTime = try container.decodeIfPresent(Double.self, forKey: .captureHostTime)
        captureTimeSource = try container.decodeIfPresent(VideoFrameCaptureTimeSource.self, forKey: .captureTimeSource) ?? .unknown
        handedPTS = try container.decodeIfPresent(Double.self, forKey: .handedPTS)
        handedUptime = try container.decode(Double.self, forKey: .handedUptime)
        receivedPTS = try container.decodeIfPresent(Double.self, forKey: .receivedPTS)
        receivedUptime = try container.decodeIfPresent(Double.self, forKey: .receivedUptime)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(session, forKey: .session)
        try container.encode(sequence, forKey: .sequence)
        try container.encodeIfPresent(sourcePTS, forKey: .sourcePTS)
        try container.encodeIfPresent(captureHostTime, forKey: .captureHostTime)
        try container.encode(captureTimeSource, forKey: .captureTimeSource)
        try container.encodeIfPresent(handedPTS, forKey: .handedPTS)
        try container.encode(handedUptime, forKey: .handedUptime)
        try container.encodeIfPresent(receivedPTS, forKey: .receivedPTS)
        try container.encodeIfPresent(receivedUptime, forKey: .receivedUptime)
    }

    private static var key: CFString { "com.haishinkit.videoFrameTrace.v1" as CFString }

    /// 在 mixer 入口附加純數值附件；不得將同一 buffer 同時當成兩次不同交付使用。
    func attachReceived(to buffer: CMSampleBuffer) {
        var values: [String: Any] = ["session": session, "sequence": NSNumber(value: sequence),
                                     "handedUptime": handedUptime,
                                     "receivedUptime": ProcessInfo.processInfo.systemUptime]
        values["sourcePTS"] = sourcePTS
        values["handedPTS"] = handedPTS
        values["captureHostTime"] = captureHostTime
        values["captureTimeSource"] = captureTimeSource.rawValue
        let pts = buffer.presentationTimeStamp.seconds
        if pts.isFinite { values["receivedPTS"] = pts }
        // CoreMedia 的 attachment mode 是 UInt32 常數，不同於 CoreVideo 的 enum。
        CMSetAttachment(buffer, key: Self.key, value: values as CFDictionary,
                        attachmentMode: kCMAttachmentMode_ShouldPropagate)
    }

    /// 未提供追蹤時移除舊附件，避免 buffer 重用後誤套上一筆交付識別。
    static func clear(from buffer: CMSampleBuffer) {
        CMRemoveAttachment(buffer, key: key)
    }

    /// 只讀取同一 buffer 的附件；不以最新影格或相近 PTS 猜測配對。
    static func read(from buffer: CMSampleBuffer) -> Self? {
        guard let values = CMGetAttachment(buffer, key: key, attachmentModeOut: nil) as? [String: Any],
              let session = values["session"] as? String,
              let sequence = values["sequence"] as? NSNumber,
              let handed = values["handedUptime"] as? Double else { return nil }
        var trace = Self(session: session, sequence: sequence.uint64Value,
                         sourcePTS: values["sourcePTS"] as? Double ?? .nan,
                         handedPTS: values["handedPTS"] as? Double ?? .nan, handedUptime: handed,
                         captureHostTime: values["captureHostTime"] as? Double,
                         captureTimeSource: VideoFrameCaptureTimeSource(rawValue: values["captureTimeSource"] as? String ?? "") ?? .unknown)
        trace.receivedPTS = values["receivedPTS"] as? Double
        trace.receivedUptime = values["receivedUptime"] as? Double
        return trace
    }

    /// 日誌保留原值，讓交付、接收與編碼 PTS 可按同一識別核對。
    var summary: String {
        "sourceSession=\(session) frame=\(sequence) sourcePTS=\(sourcePTS.map(String.init(describing:)) ?? "unknown") captureHostTime=\(captureHostTime.map(String.init(describing:)) ?? "unknown") captureTimeSource=\(captureTimeSource.rawValue) handedPTS=\(handedPTS.map(String.init(describing:)) ?? "unknown") receivedPTS=\(receivedPTS.map(String.init(describing:)) ?? "unknown") handedUptime=\(handedUptime) receivedUptime=\(receivedUptime.map(String.init(describing:)) ?? "unknown")"
    }
}
