import Foundation

/// 同一幀提交 VT 與成功回呼的時間對照；不表示已交付 RTMP 或畫面內容的新舊。
public struct VideoEncoderTimingSample: Codable, Sendable {
    /// 實際 VT 狀態實例識別；重建後改變，不等同發布世代或格式 revision。
    public let session: UUID
    /// 提交給 VT 的 PTS 秒數；不是螢幕原始擷取時間的保證。
    public let inputPTSSeconds: Double?
    /// VT 回呼壓縮樣本的 PTS 秒數。
    public let outputPTSSeconds: Double?
    /// VT 回呼壓縮樣本的 DTS 秒數；未提供時為 nil。
    public let outputDTSSeconds: Double?
    /// 呼叫 VT 編碼前的程序單調時間，單位秒。
    public let submittedUptimeSeconds: Double
    /// VT 成功回呼時的程序單調時間，單位秒。
    public let completedUptimeSeconds: Double
    /// 同一幀從提交到回呼的耗時，單位毫秒；包含 VT 內部等待。
    public var elapsedMilliseconds: Double {
        max(0, completedUptimeSeconds - submittedUptimeSeconds) * 1000
    }

    /// 建立純數值觀測；無效媒體時間轉為 nil，確保 JSON 可編碼。
    init(session: UUID, inputPTS: Double, outputPTS: Double, outputDTS: Double?,
         submitted: Double, completed: Double) {
        self.session = session
        inputPTSSeconds = inputPTS.isFinite ? inputPTS : nil
        outputPTSSeconds = outputPTS.isFinite ? outputPTS : nil
        outputDTSSeconds = outputDTS.flatMap { $0.isFinite ? $0 : nil }
        submittedUptimeSeconds = submitted
        completedUptimeSeconds = completed
    }

    /// 既有低頻事件摘要使用的同幀對照。
    var summary: String {
        "session=\(session) inputPTS=\(inputPTSSeconds.map(String.init(describing:)) ?? "unknown") outputPTS=\(outputPTSSeconds.map(String.init(describing:)) ?? "unknown") outputDTS=\(outputDTSSeconds.map(String.init(describing:)) ?? "unknown") submitted=\(submittedUptimeSeconds) completed=\(completedUptimeSeconds) elapsedMs=\(elapsedMilliseconds)"
    }
}
