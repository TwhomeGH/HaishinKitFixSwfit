import Foundation

/// 網路監控事件。
public enum NetworkMonitorEvent: Sendable {
    /// 更新網路統計。
    case status(report: NetworkMonitorReport)
    /// 偵測到推流頻寬不足。
    case publishInsufficientBWOccured(report: NetworkMonitorReport)
    /// 重設統計狀態。
    case reset
}
