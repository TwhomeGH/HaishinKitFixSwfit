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

    public init(osLog: OSLog) {
        self.osLog = osLog
    }

    public func isEnabledFor(level: LogLevel) -> Bool {
        return level >= minimumLevel
    }

    public func trace(_ items: Any...) {
        os_log(.debug, log: osLog, "%{public}@", items.map(String.init(describing:)).joined(separator: " "))
    }
    public func debug(_ items: Any...) {
        os_log(.debug, log: osLog, "%{public}@", items.map(String.init(describing:)).joined(separator: " "))
    }
    public func info(_ items: Any...) {
        os_log(.info, log: osLog, "%{public}@", items.map(String.init(describing:)).joined(separator: " "))
    }
    public func warn(_ items: Any...) {
        os_log(.info, log: osLog, "⚠️ %{public}@", items.map(String.init(describing:)).joined(separator: " "))
    }
    public func error(_ items: Any...) {
        os_log(.error, log: osLog, "%{public}@", items.map(String.init(describing:)).joined(separator: " "))
    }
}

nonisolated(unsafe) let logger = HaishinKitLogger(osLog: OSLog(subsystem: kHaishinKitIdentifier, category: "HaishinKit"))
