import OSLog

public let kHaishinKitIdentifier = "com.haishinkit.HaishinKit"

/// Current HaishinKit revision. Updated by CI or manually.
public let kHaishinKitRevision = "3481fce"

public enum LogLevel: Comparable {
    case trace, debug, info, warn, error
}

public struct HaishinKitLogger {
    public let osLog: OSLog
    var minimumLevel: LogLevel = .trace
    public var onLog: (@Sendable (_ level: LogLevel, _ message: String) -> Void)?

    public init(osLog: OSLog) {
        self.osLog = osLog
    }

    public func isEnabledFor(level: LogLevel) -> Bool {
        return level >= minimumLevel
    }

    public func trace(_ items: Any...) {
        let message = items.map(String.init(describing:)).joined(separator: " ")
        os_log(.debug, log: osLog, "%{public}@", message)
        onLog?(.trace, message)
    }
    public func debug(_ items: Any...) {
        let message = items.map(String.init(describing:)).joined(separator: " ")
        os_log(.debug, log: osLog, "%{public}@", message)
        onLog?(.debug, message)
    }
    public func info(_ items: Any...) {
        let message = items.map(String.init(describing:)).joined(separator: " ")
        os_log(.info, log: osLog, "%{public}@", message)
        onLog?(.info, message)
    }
    public func warn(_ items: Any...) {
        let message = items.map(String.init(describing:)).joined(separator: " ")
        os_log(.info, log: osLog, "⚠️ %{public}@", message)
        onLog?(.warn, message)
    }
    public func error(_ items: Any...) {
        let message = items.map(String.init(describing:)).joined(separator: " ")
        os_log(.error, log: osLog, "%{public}@", message)
        onLog?(.error, message)
    }
}

nonisolated(unsafe) let logger = HaishinKitLogger(osLog: OSLog(subsystem: kHaishinKitIdentifier, category: "HaishinKit"))
