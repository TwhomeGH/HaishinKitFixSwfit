import Foundation

/// 被 `VideoCodec.useFrame` 略過的原因；只在原始（未壓縮）影格路徑產生。
public enum VideoFrameFilterReason: String, Codable, Sendable, CaseIterable {
    /// 影格時間早於本次啟動基準。
    case beforeStart
    /// PTS 未大於最後一次被接受的影格（重複或倒退）。
    case nonMonotonic
    /// `adaptiveFrameThrottle` 的 dropRatio 未選中此影格。
    case adaptiveThrottle
    /// `frameInterval` 幀率上限未達。
    case frameInterval
}

/// 單次被過濾影格的數值快照；不持有畫面。
public struct VideoFrameFilterSample: Codable, Sendable {
    public let reason: VideoFrameFilterReason
    /// 被過濾影格的 PTS 秒數；無效時為 nil。
    public let presentationTimeSeconds: Double?
    /// 最後一次被接受影格的 PTS 秒數；尚未接受任何影格時為 nil。
    public let lastAcceptedPresentationTimeSeconds: Double?
    /// 兩者差；負值代表 PTS 倒退。無法計算時為 nil。
    public let deltaSeconds: Double?
    /// 過濾時的單調時鐘秒數。
    public let uptimeSeconds: TimeInterval

    public init(reason: VideoFrameFilterReason, presentationTimeSeconds: Double?,
                lastAcceptedPresentationTimeSeconds: Double?, deltaSeconds: Double?,
                uptimeSeconds: TimeInterval) {
        self.reason = reason
        self.presentationTimeSeconds = presentationTimeSeconds
        self.lastAcceptedPresentationTimeSeconds = lastAcceptedPresentationTimeSeconds
        self.deltaSeconds = deltaSeconds
        self.uptimeSeconds = uptimeSeconds
    }

    var summary: String {
        "reason=\(reason.rawValue) pts=\(presentationTimeSeconds.map(String.init(describing:)) ?? "unknown") lastAccepted=\(lastAcceptedPresentationTimeSeconds.map(String.init(describing:)) ?? "unknown") delta=\(deltaSeconds.map(String.init(describing:)) ?? "unknown") uptime=\(uptimeSeconds)"
    }
}

/// 被過濾影格的累計狀態；理由只有固定幾種，不隨影格成長。
public struct VideoFrameFilterSnapshot: Codable, Sendable {
    /// 最近一次被過濾的影格；從未過濾時為 nil。
    public let last: VideoFrameFilterSample?
    /// 各理由的累計次數；key 是 `VideoFrameFilterReason.rawValue`。
    public let reasonCounts: [String: UInt64]
    /// 目前連續被過濾的影格數；接受一筆後歸零。
    public let consecutive: UInt64
    /// 本次追蹤期間最長的連續過濾影格數。
    public let maxConsecutive: UInt64

    public init(last: VideoFrameFilterSample?, reasonCounts: [String: UInt64],
                consecutive: UInt64, maxConsecutive: UInt64) {
        self.last = last
        self.reasonCounts = reasonCounts
        self.consecutive = consecutive
        self.maxConsecutive = maxConsecutive
    }

    var summary: String {
        let reasons = reasonCounts.keys.sorted().map { "\($0)=\(reasonCounts[$0]!)" }.joined(separator: " ")
        return "consecutive=\(consecutive) maxConsecutive=\(maxConsecutive) reasons{\(reasons)} last{\(last?.summary ?? "none")}"
    }
}

/// 純狀態機：過濾時累加，接受時把連續計數歸零；可在非 Apple 平台驗證。
struct VideoFrameFilterState {
    private(set) var last: VideoFrameFilterSample?
    private(set) var reasonCounts: [String: UInt64] = [:]
    private(set) var consecutive: UInt64 = 0
    private(set) var maxConsecutive: UInt64 = 0

    mutating func filtered(reason: VideoFrameFilterReason, presentationTime: Double,
                           lastAcceptedPresentationTime: Double?, uptime: TimeInterval) {
        let pts = presentationTime.isFinite ? presentationTime : nil
        let accepted = lastAcceptedPresentationTime.flatMap { $0.isFinite ? $0 : nil }
        let delta: Double? = if let pts, let accepted { pts - accepted } else { nil }
        last = VideoFrameFilterSample(
            reason: reason,
            presentationTimeSeconds: pts,
            lastAcceptedPresentationTimeSeconds: accepted,
            deltaSeconds: delta,
            uptimeSeconds: uptime)
        reasonCounts[reason.rawValue, default: 0] &+= 1
        consecutive &+= 1
        maxConsecutive = max(maxConsecutive, consecutive)
    }

    mutating func accepted() {
        consecutive = 0
    }

    var snapshot: VideoFrameFilterSnapshot {
        VideoFrameFilterSnapshot(last: last, reasonCounts: reasonCounts,
                                 consecutive: consecutive, maxConsecutive: maxConsecutive)
    }
}
