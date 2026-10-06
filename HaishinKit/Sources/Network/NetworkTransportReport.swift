import Foundation

/// 傳輸層提供的位元組統計快照，供 NetworkMonitor 計算差值。
package struct NetworkTransportReport: Sendable {
    /// 目前待送佇列的位元組數（bytes），不是每秒速率。
    package let queueBytesOut: Int
    /// 傳輸層累計接收位元組數（bytes）。
    package let totalBytesIn: Int
    /// 傳輸層累計送出位元組數（bytes）；RTMP 只計本機無錯誤完成的傳送。
    package let totalBytesOut: Int

    /// 建立統計快照。
    package init(queueBytesOut: Int, totalBytesIn: Int, totalBytesOut: Int) {
        self.queueBytesOut = queueBytesOut
        self.totalBytesIn = totalBytesIn
        self.totalBytesOut = totalBytesOut
    }
}
