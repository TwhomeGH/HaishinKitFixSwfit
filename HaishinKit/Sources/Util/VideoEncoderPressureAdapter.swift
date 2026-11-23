import Foundation

extension VideoEncoderPressureSnapshot {
    /// 把既有的事件、佇列與 timing 快照轉成壓力輸入。
    ///
    /// 只讀取呼叫端已取得的資料，不觸發編碼、不等待鎖；`recent` 的視窗固定為
    /// 5 秒，與 `VideoEncoderHealth` 的近期判定一致。
    static func input(events: VideoPipelineEventsSnapshot?,
                      encoderInput: VideoQueueStageSnapshot?,
                      pendingFrames: Int?,
                      expectedFrameRate: Double?,
                      maxFrameDelayCount: Int?) -> Input {
        let counts = events?.events ?? [:]
        func count(_ event: VideoPipelineEvent) -> UInt64 {
            counts[event.rawValue]?.count ?? 0
        }
        func recent(_ event: VideoPipelineEvent, window: TimeInterval = 5) -> Bool {
            guard let idle = events?.idle(for: event) else { return false }
            return idle <= window
        }

        let queue = encoderInput?.queue
        let lastTiming = events?.lastEncoderTiming
        let lastFilter = events?.filteredFrames?.last
        let adaptiveRecent: Bool = {
            guard lastFilter?.reason == .adaptiveThrottle,
                  let sampledAt = events?.sampledAt,
                  let uptime = lastFilter?.uptimeSeconds else { return false }
            return sampledAt - uptime <= 5
        }()

        var input = Input()
        // 只有在真的觀察到編碼事件、佇列或 pending 時才建立壓力資料；
        // 空的事件追蹤器（尚未送出任何影格）不是「零壓力」。
        input.hasData = (events?.events.isEmpty == false) || queue != nil || pendingFrames != nil
        input.sampledAt = events?.sampledAt ?? 0
        input.submitted = count(.encoderSubmitted)
        input.callbacks = count(.encoderCallback)
        input.delivered = count(.encoderDelivered)
        input.dropped = count(.encoderDropped)
        input.filtered = count(.encoderFiltered)
        input.failures = count(.encoderFailure)
        input.sessionChanges = count(.encoderSessionChanged)
        input.pendingFrames = pendingFrames
        input.queued = queue?.queued
        input.oldestAgeSeconds = queue?.oldestAge
        input.maxWaitSeconds = queue?.maxWait
        input.lastElapsedMilliseconds = lastTiming?.elapsedMilliseconds
        input.lastHandoffWaitSeconds = lastTiming?.handoffWaitSeconds
        input.lastReceivedToEncoderSeconds = lastTiming?.receivedToEncoderSeconds
        input.recentDrop = recent(.encoderDropped)
        input.recentFailure = recent(.encoderFailure)
        input.recentYieldRejected = recent(.encoderYieldRejected)
        input.recentPTSReset = recent(.encoderPTSReset)
        input.recentAdaptiveThrottle = adaptiveRecent
        input.recentUnavailable = recent(.encoderUnavailable)
        input.expectedFrameRate = expectedFrameRate
        input.maxFrameDelayCount = maxFrameDelayCount
        return input
    }
}
