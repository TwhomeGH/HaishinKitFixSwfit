import Foundation
import HaishinKit

public enum RTMPLogLevel: Sendable {
    case trace
    case debug
    case info
    case warn
    case error
}

extension RTMPLogLevel {
    package var severity: Int {
        switch self {
        case .trace: return 0
        case .debug: return 1
        case .info: return 2
        case .warn: return 3
        case .error: return 4
        }
    }
}

public struct RTMPLogEvent: Sendable {
    public let level: RTMPLogLevel
    public let message: String
    public let detail: String?
    /// When `true` the event bypasses `RTMPConnection.minimumLogLevel` and is
    /// always delivered to `onLog`. Reserved for low-volume connection
    /// lifecycle and fault events that are essential for remote diagnosis
    /// (connect / handshake / close / reconnect / watchdog / socket state), so
    /// a production app can keep `minimumLogLevel = .warn` without losing the
    /// disconnect story. High-frequency per-chunk/per-frame events stay gated.
    public let always: Bool
    public let timestamp: Date
    public let file: String
    public let line: Int

    public init(level: RTMPLogLevel, message: String, detail: String? = nil, always: Bool = false, file: String = #file, line: Int = #line) {
        self.level = level
        self.message = message
        self.detail = detail
        self.always = always
        self.timestamp = Date()
        self.file = file
        self.line = line
    }
}

extension LogLevel {
    var rtmpLevel: RTMPLogLevel {
        switch self {
        case .trace: return .trace
        case .debug: return .debug
        case .info: return .info
        case .warn: return .warn
        case .error: return .error
        }
    }
}
