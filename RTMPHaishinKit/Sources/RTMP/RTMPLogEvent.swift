import Foundation

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
    public let timestamp: Date
    public let file: String
    public let line: Int

    public init(level: RTMPLogLevel, message: String, detail: String? = nil, file: String = #file, line: Int = #line) {
        self.level = level
        self.message = message
        self.detail = detail
        self.timestamp = Date()
        self.file = file
        self.line = line
    }
}
