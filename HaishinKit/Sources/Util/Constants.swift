import OSLog

public let kHaishinKitIdentifier = "com.haishinkit.HaishinKit"

enum LogLevel: Comparable {
    case trace, debug, info, warn, error
}

public struct HaishinKitLogger {
    let osLog: OSLog
    var minimumLevel: LogLevel = .trace

    func isEnabledFor(level: LogLevel) -> Bool {
        return level >= minimumLevel
    }

    func trace(_ items: Any...) {
        os_log(.debug, log: osLog, "%{public}@", items.map(String.init(describing:)).joined(separator: " "))
    }
    func debug(_ items: Any...) {
        os_log(.debug, log: osLog, "%{public}@", items.map(String.init(describing:)).joined(separator: " "))
    }
    func info(_ items: Any...) {
        os_log(.info, log: osLog, "%{public}@", items.map(String.init(describing:)).joined(separator: " "))
    }
    func warn(_ items: Any...) {
        os_log(.info, log: osLog, "⚠️ %{public}@", items.map(String.init(describing:)).joined(separator: " "))
    }
    func error(_ items: Any...) {
        os_log(.error, log: osLog, "%{public}@", items.map(String.init(describing:)).joined(separator: " "))
    }
}

nonisolated(unsafe) let logger = HaishinKitLogger(osLog: OSLog(subsystem: kHaishinKitIdentifier, category: "HaishinKit"))
