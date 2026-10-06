import Foundation

/// RTMPStream 的接收統計與串流資源資訊。
public struct RTMPStreamInfo: Sendable {
    /// 此串流累計接收的位元組數。
    public internal(set) var byteCount = 0
    /// 串流的資源名稱。
    public internal(set) var resourceName: String?
    /// 最近一次 update() 與前次更新之間的接收位元組差值；每秒更新時才等於 bytes/s。
    public internal(set) var currentBytesPerSecond = 0
    private var previousByteCount = 0

    /// 以累計接收量計算本次更新的差值，並推進取樣基準。
    mutating func update() {
        currentBytesPerSecond = byteCount - previousByteCount
        previousByteCount = byteCount
    }

    /// 清除接收量與差值基準，保留資源名稱。
    mutating func clear() {
        byteCount = 0
        currentBytesPerSecond = 0
        previousByteCount = 0
    }
}

extension RTMPStreamInfo: CustomDebugStringConvertible {
    // MARK: CustomDebugStringConvertible
    public var debugDescription: String {
        Mirror(reflecting: self).debugDescription
    }
}
