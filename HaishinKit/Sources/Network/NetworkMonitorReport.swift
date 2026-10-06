import Foundation

/// 網路監控的累計量、即時佇列大小與傳輸速率。
public struct NetworkMonitorReport: Sendable {
    /// 傳輸層回報的累計接收位元組數。
    public let totalBytesIn: Int
    /// 傳輸層回報的累計送出位元組數，不代表對端已解碼。
    public let totalBytesOut: Int
    /// 目前待送佇列的位元組數（bytes），不是每秒速率。
    public let currentQueueBytesOut: Int
    /// 最近取樣區間估算的接收速率（bytes/s）。
    public let currentBytesInPerSecond: Int
    /// 最近取樣區間估算的送出速率（bytes/s）。
    public let currentBytesOutPerSecond: Int
}
