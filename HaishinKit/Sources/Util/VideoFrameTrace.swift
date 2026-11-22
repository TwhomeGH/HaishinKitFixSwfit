import CoreMedia
import Foundation

/// 上游交付與底層接收的同幀識別；只保存數值，不持有畫面。
/// session + sequence 由上游產生；不能用 PTS 當唯一識別，因為來源可能重複或倒退。
public struct VideoFrameTrace: Codable, Sendable {
    /// 上游擷取工作階段。
    public let session: String
    /// 該工作階段的來源影格序號。
    public let sequence: UInt64
    /// 加工前來源 PTS；無效時間為 nil。
    public let sourcePTS: Double?
    /// 上游實際交給 mixer 的 PTS。
    public let handedPTS: Double?
    /// 上游交付時的 systemUptime 秒數。
    public let handedUptime: Double
    /// 底層 mixer 收到時的 PTS；尚未接收為 nil。
    public private(set) var receivedPTS: Double?
    /// 底層 mixer 收到時的 systemUptime 秒數。
    public private(set) var receivedUptime: Double?

    /// 建立交付識別。uptime 必須使用同程序的單調時鐘，不能填牆鐘或來源 PTS。
    public init(session: String, sequence: UInt64, sourcePTS: Double, handedPTS: Double,
                handedUptime: Double = ProcessInfo.processInfo.systemUptime) {
        self.session = session
        self.sequence = sequence
        self.sourcePTS = sourcePTS.isFinite ? sourcePTS : nil
        self.handedPTS = handedPTS.isFinite ? handedPTS : nil
        self.handedUptime = handedUptime
    }

    private static var key: CFString { "com.haishinkit.videoFrameTrace.v1" as CFString }

    /// 在 mixer 入口附加純數值附件；不得將同一 buffer 同時當成兩次不同交付使用。
    func attachReceived(to buffer: CMSampleBuffer) {
        var values: [String: Any] = ["session": session, "sequence": NSNumber(value: sequence),
                                     "handedUptime": handedUptime,
                                     "receivedUptime": ProcessInfo.processInfo.systemUptime]
        values["sourcePTS"] = sourcePTS
        values["handedPTS"] = handedPTS
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
                         handedPTS: values["handedPTS"] as? Double ?? .nan, handedUptime: handed)
        trace.receivedPTS = values["receivedPTS"] as? Double
        trace.receivedUptime = values["receivedUptime"] as? Double
        return trace
    }

    /// 日誌保留原值，讓交付、接收與編碼 PTS 可按同一識別核對。
    var summary: String {
        "sourceSession=\(session) frame=\(sequence) sourcePTS=\(sourcePTS.map(String.init(describing:)) ?? "unknown") handedPTS=\(handedPTS.map(String.init(describing:)) ?? "unknown") receivedPTS=\(receivedPTS.map(String.init(describing:)) ?? "unknown") handedUptime=\(handedUptime) receivedUptime=\(receivedUptime.map(String.init(describing:)) ?? "unknown")"
    }
}
