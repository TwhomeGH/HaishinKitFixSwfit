import Foundation

/// RTMP 請求回應的狀態與參數。
public struct RTMPResponse: Sendable, CustomStringConvertible {
    public var description: String {
        if let status {
            return "\(status.code) \(status.level): \(status.description)"
        }
        return "no status"
    }
    /// 回應附帶的狀態；無可解析狀態時為 nil。
    public let status: RTMPStatus?
    /// 回應參數，順序沿用協定訊息。
    public let arguments: [(any Sendable)?]

    init(status: RTMPStatus?, arguments: [(any Sendable)?] = []) {
        self.status = status
        self.arguments = arguments
    }

    init(_ message: RTMPCommandMessage) {
        arguments = message.arguments
        status = arguments.isEmpty ? nil : .init(arguments.first as? AMFObject)
    }
}
