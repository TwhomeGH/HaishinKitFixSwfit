import Foundation
import HaishinKit

/// RTMP 診斷事件的嚴重程度。
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

/// 透過 RTMPConnection.onLog 回傳的診斷事件。
public struct RTMPLogEvent: Sendable {
    /// 事件嚴重程度。
    public let level: RTMPLogLevel
    /// 事件摘要。
    public let message: String
    /// 額外診斷內容；未提供時為 nil。
    public let detail: String?
    /// true 時略過 RTMPConnection.minimumLogLevel，仍交付 onLog。
    /// 僅供低頻且重要的連線生命週期與故障事件，例如握手、重連和 socket 狀態。
    /// 因此最低等級設為 warn 仍可追查斷線；高頻逐 chunk／逐幀事件不應使用此旗標。
    public let always: Bool
    /// 建立事件時的時間。
    public let timestamp: Date
    /// 事件來源檔案。
    public let file: String
    /// 事件來源行號。
    public let line: Int

    /// 建立事件並記錄目前時間；always 僅適用重要低頻事件。
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
