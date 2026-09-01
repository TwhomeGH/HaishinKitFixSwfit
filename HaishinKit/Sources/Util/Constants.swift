import Foundation
import OSLog

public let kHaishinKitIdentifier = "com.haishinkit.HaishinKit"

/// Current HaishinKit revision. Updated by CI or manually.
public let kHaishinKitRevision = "3481fce"

public enum LogLevel: Comparable {
    case trace, debug, info, warn, error
}

public struct HaishinKitLogger {
    public typealias HandlerID = UUID

    public let osLog: OSLog
    var minimumLevel: LogLevel = .trace
    /// 主 handler（單一插槽）：RTMPConnection 用它把 logger 轉送到 connection.onLog。
    public var onLog: (@Sendable (_ level: LogLevel, _ message: String) -> Void)?
    /// 額外 handler 列表（多個並存，thread-safe）：app 可再掛自己的收日誌 handler，
    /// 不會蓋掉主 handler（connection 轉送）也不互相覆蓋。
    private var extraHandlers: [(id: HandlerID, handler: (@Sendable (_ level: LogLevel, _ message: String) -> Void))] = []
    private let handlerLock = NSLock()

    public init(osLog: OSLog) {
        self.osLog = osLog
    }

    public func isEnabledFor(level: LogLevel) -> Bool {
        return level >= minimumLevel
    }

    /// 掛一個額外 handler（與主 `onLog` 並存）。
    public mutating func addLogHandler(_ handler: @escaping @Sendable (_ level: LogLevel, _ message: String) -> Void) {
        _ = installLogHandler(handler)
    }

    /// 掛一個可移除的額外 handler，回傳 token 供精準解除。
    public mutating func installLogHandler(_ handler: @escaping @Sendable (_ level: LogLevel, _ message: String) -> Void) -> HandlerID {
        let id = HandlerID()
        handlerLock.lock()
        defer { handlerLock.unlock() }
        extraHandlers.append((id: id, handler: handler))
        return id
    }

    /// 移除先前掛的 handler（依閉包身分比對）。
    public mutating func removeLogHandler(_ handler: @escaping @Sendable (_ level: LogLevel, _ message: String) -> Void) {
        handlerLock.lock()
        defer { handlerLock.unlock() }
        extraHandlers.removeAll(where: { $0.handler as AnyObject === handler as AnyObject })
    }

    /// 以 token 移除先前掛上的 handler。
    public mutating func removeLogHandler(id: HandlerID) {
        handlerLock.lock()
        defer { handlerLock.unlock() }
        extraHandlers.removeAll(where: { $0.id == id })
    }

    private func emit(_ level: LogLevel, _ message: String) {
        onLog?(level, message)
        handlerLock.lock()
        let handlers = extraHandlers
        handlerLock.unlock()
        for entry in handlers {
            entry.handler(level, message)
        }
    }

    public func trace(_ items: Any...) {
        let message = items.map(String.init(describing:)).joined(separator: " ")
        os_log(.debug, log: osLog, "%{public}@", message)
        emit(.trace, message)
    }
    public func debug(_ items: Any...) {
        let message = items.map(String.init(describing:)).joined(separator: " ")
        os_log(.debug, log: osLog, "%{public}@", message)
        emit(.debug, message)
    }
    public func info(_ items: Any...) {
        let message = items.map(String.init(describing:)).joined(separator: " ")
        os_log(.info, log: osLog, "%{public}@", message)
        emit(.info, message)
    }
    public func warn(_ items: Any...) {
        let message = items.map(String.init(describing:)).joined(separator: " ")
        os_log(.info, log: osLog, "⚠️ %{public}@", message)
        emit(.warn, message)
    }
    public func error(_ items: Any...) {
        let message = items.map(String.init(describing:)).joined(separator: " ")
        os_log(.error, log: osLog, "%{public}@", message)
        emit(.error, message)
    }
}

nonisolated(unsafe) public var logger = HaishinKitLogger(osLog: OSLog(subsystem: kHaishinKitIdentifier, category: "HaishinKit"))
