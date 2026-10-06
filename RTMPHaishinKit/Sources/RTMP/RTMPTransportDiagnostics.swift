import Foundation

/// 單一 socket 連線的累計傳送快照；不是 RTMP chunk 數，也不是伺服器解碼確認。
public struct RTMPTransportDiagnostics: Sendable {
    /// 連線世代；重新 connect 後計數歸零。關閉也會遞增以隔離舊回呼。
    public let generation: UInt64
    /// 本機待完成資料，包含目前傳送中的批次，單位 bytes。
    public let queuedBytes: Int
    /// Network.framework 無錯誤完成的 bytes；不代表對端已收到。
    public let completedBytes: Int
    /// 傳送失敗批次的完整大小；其中可能已有部分傳出，不能視為精確丟包量。
    public let failedBatchBytes: Int
    /// socket 成功完成批次數，並非 RTMP chunk 數。
    public let completedBatches: Int
    /// socket 失敗批次數。
    public let failedBatches: Int
    /// 最近一次完成回呼耗時（毫秒），沒有回呼時為 nil。
    public let lastCompletionMilliseconds: Double?
    /// 目前尚未公開伺服器 ACK 統計；nil 表示未知，不表示零。
    public var acknowledgedBytes: Int? { nil }
}
