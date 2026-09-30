import Foundation

/// 固定事件集合，避免逐幀累積紀錄造成記憶體成長。
public enum VideoPipelineEvent: String, Codable, Sendable, CaseIterable {
    case encoderSubmitted, encoderCallback, encoderDelivered, encoderKeyFrame
    case encoderDropped, encoderFailure, encoderRecovery, encoderFiltered, encoderUnavailable
    case encoderSessionChanged, encoderKeyFrameSuppressed, encoderYieldRejected
    case publishStarted, publishStopped, encodedReceived, outputUnavailable
    case keyFrameSuppressed, messageCreationFailed, videoQueued, videoQueueRejected
    case connectionVideoAccepted, connectionVideoRejected
}

public struct VideoPipelineEventValue: Codable, Sendable {
    public let count: UInt64
    public let lastAt: TimeInterval
}

/// 同一 tracker 的累計事件；缺少某個 key 表示從未觀察到該事件。
public struct VideoPipelineEventsSnapshot: Codable, Sendable {
    public let id: UUID
    public let sampledAt: TimeInterval
    public let events: [String: VideoPipelineEventValue]
    public let lastErrorCode: Int32?
    public func idle(for event: VideoPipelineEvent) -> TimeInterval? {
        events[event.rawValue].map { max(0, sampledAt - $0.lastAt) }
    }
    public var summary: String {
        events.keys.sorted().map { key in
            let value = events[key]!
            return "\(key)=\(value.count) idle=\(max(0, sampledAt - value.lastAt))"
        }.joined(separator: " ") + " lastError=\(lastErrorCode.map(String.init) ?? "none")"
    }
}

package final class VideoPipelineEventTracker: @unchecked Sendable {
    private let lock = NSLock()
    private let id = UUID()
    private let clock: @Sendable () -> TimeInterval
    private var events: [String: VideoPipelineEventValue] = [:]
    private var lastErrorCode: Int32?
    package init(clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.clock = clock
    }
    package func record(_ event: VideoPipelineEvent, errorCode: Int32? = nil) {
        lock.lock(); defer { lock.unlock() }
        let key = event.rawValue
        events[key] = VideoPipelineEventValue(count: (events[key]?.count ?? 0) &+ 1, lastAt: clock())
        if let errorCode { lastErrorCode = errorCode }
    }
    package func snapshot() -> VideoPipelineEventsSnapshot {
        lock.lock(); defer { lock.unlock() }
        return VideoPipelineEventsSnapshot(id: id, sampledAt: clock(), events: events, lastErrorCode: lastErrorCode)
    }
}
