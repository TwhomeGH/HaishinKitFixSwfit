import Foundation

/// 唯讀診斷資料；容量只涵蓋佇列持有的資料，不代表程序記憶體。
public struct VideoQueueSnapshot: Codable, Sendable {
    public let id: UUID
    public let sampledAt: TimeInterval
    public let received: Int
    public let consumed: Int
    public let queued: Int
    public let bytes: Int
    public let byteLimit: Int
    public let peakBytes: Int
    public let maxAge: TimeInterval
    public let manualFrameLimit: Int?
    public let oldestAge: TimeInterval
    public let maxWait: TimeInterval
    public let capacityDrops: Int
    public let expiredDrops: Int
    public let oversizedDrops: Int
    public let closedDrops: Int
    public let shutdownDrops: Int
    public let inputIdle: TimeInterval?
    public let outputIdle: TimeInterval?
    public let closed: Bool

    /// 不同佇列或非遞增時間沒有可比較的速率。
    public func rates(since previous: Self?) -> VideoQueueRates? {
        guard let previous, id == previous.id, sampledAt > previous.sampledAt,
              received >= previous.received, consumed >= previous.consumed else { return nil }
        let elapsed = sampledAt - previous.sampledAt
        return VideoQueueRates(inputFPS: Double(received - previous.received) / elapsed,
                               outputFPS: Double(consumed - previous.consumed) / elapsed)
    }

    public var summary: String {
        "in=\(received) out=\(consumed) queued=\(queued) bytes=\(bytes)/\(byteLimit) peakBytes=\(peakBytes) maxAgeMs=\(maxAge * 1000) oldestMs=\(oldestAge * 1000) maxWaitMs=\(maxWait * 1000) capacityDrop=\(capacityDrops) expiredDrop=\(expiredDrops) oversizedDrop=\(oversizedDrops) closedDrop=\(closedDrops) shutdownDrop=\(shutdownDrops) inputIdle=\(inputIdle ?? -1) outputIdle=\(outputIdle ?? -1) closed=\(closed)"
    }
}

public struct VideoQueueRates: Codable, Sendable {
    public let inputFPS: Double
    public let outputFPS: Double
}

public struct VideoQueueStageSnapshot: Codable, Sendable {
    public enum Availability: String, Codable, Sendable { case available, unavailable, ownerLockBusy }
    public let availability: Availability
    public let generation: UInt64?
    public let missingDrops: Int?
    public let queue: VideoQueueSnapshot?

    public init(availability: Availability, generation: UInt64? = nil,
                missingDrops: Int? = nil, queue: VideoQueueSnapshot? = nil) {
        self.availability = availability
        self.generation = generation
        self.missingDrops = missingDrops
        self.queue = queue
    }

    public func summary(since previous: Self? = nil) -> String {
        let rates = queue?.rates(since: previous?.queue)
        let rateText = rates.map { String(format: "inFPS=%.1f outFPS=%.1f ", $0.inputFPS, $0.outputFPS) } ?? "rates=unavailable "
        return "state=\(availability.rawValue) generation=\(generation.map(String.init) ?? "unavailable") missingDrop=\(missingDrops.map(String.init) ?? "unavailable") " + rateText + (queue?.summary ?? "queue=unavailable")
    }
}

public struct VideoMixerSnapshot: Codable, Sendable {
    public let input: VideoQueueStageSnapshot
    public let output: VideoQueueStageSnapshot
    public init(input: VideoQueueStageSnapshot, output: VideoQueueStageSnapshot) {
        self.input = input; self.output = output
    }
}

/// 各階段依序取樣，不保證跨階段的原子一致性。時間採用單調時鐘。
public struct VideoPipelineSnapshot: Codable, Sendable {
    public let schemaVersion: Int
    public let sampledAt: TimeInterval
    public let mixer: VideoMixerSnapshot?
    public let encoderInput: VideoQueueStageSnapshot
    public let bridgeReceived: Int
    public let pressureDrops: Int
    public let lastPTS: Double?

    public init(sampledAt: TimeInterval, mixer: VideoMixerSnapshot?, encoderInput: VideoQueueStageSnapshot,
                bridgeReceived: Int, pressureDrops: Int, lastPTS: Double?) {
        schemaVersion = 1
        self.sampledAt = sampledAt; self.mixer = mixer; self.encoderInput = encoderInput
        self.bridgeReceived = bridgeReceived; self.pressureDrops = pressureDrops
        self.lastPTS = lastPTS
    }

    public func summary(since previous: Self? = nil) -> String {
        "encoderInput{\(encoderInput.summary(since: previous?.encoderInput))} bridge{received=\(bridgeReceived) pressureDrop=\(pressureDrops) lastPTS=\(lastPTS ?? -1)} mixer{input{\(mixer?.input.summary(since: previous?.mixer?.input) ?? "unavailable")} output{\(mixer?.output.summary(since: previous?.mixer?.output) ?? "unavailable")}}"
    }
}
