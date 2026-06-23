import Foundation

public enum RTMPLogLevel: Sendable {
    case trace
    case debug
    case info
    case warn
    case error
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
