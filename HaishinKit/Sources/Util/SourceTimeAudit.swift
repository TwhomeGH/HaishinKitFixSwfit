import Foundation

/// 單一媒體／軌道的入口時間診斷；由 MediaMixer actor 隔離，不修正或拒收樣本。
struct SourceTimeAudit {
    private(set) var received: UInt64 = 0
    private(set) var invalid: UInt64 = 0
    private(set) var consecutive: UInt64 = 0
    private(set) var longestRun: UInt64 = 0
    private(set) var recoveries: UInt64 = 0
    private(set) var lastValidPTS: Double?
    private var firstBad: String?
    private var lastBad: String?
    private var lastArrival = 0.0
    private var lastReport: Double?

    /// 獨立保存入口到達的單調時間。reason 為 nil 才是有效來源時間。
    /// - Returns: 首次異常立即回報，其後最多每 30 秒一則；正常入口也有低頻摘要。
    mutating func observe(pts: Double, reason: String?, detail: String, now: Double) -> String? {
        received &+= 1
        lastArrival = now
        let bad = reason != nil || !pts.isFinite
        if bad {
            invalid &+= 1
            consecutive &+= 1
            longestRun = max(longestRun, consecutive)
            let event = "reason=\(reason ?? "nonFinite") arrivalUptime=\(now) \(detail)"
            if firstBad == nil { firstBad = event }
            lastBad = event
        } else {
            if consecutive > 0 { recoveries &+= 1 }
            consecutive = 0
            lastValidPTS = pts
        }
        if lastReport == nil || (bad && invalid == 1) || now - (lastReport ?? now) >= 30 {
            lastReport = now
            return summary
        }
        return nil
    }

    /// 停止時可直接取摘要，確保節流期間的恢復或尾端異常不遺失。
    var summary: String {
        "received=\(received) invalid=\(invalid) consecutiveInvalid=\(consecutive) longestInvalidRun=\(longestRun) recoveries=\(recoveries) lastValidPTS=\(lastValidPTS.map(String.init(describing:)) ?? "unknown") lastArrivalUptime=\(lastArrival) firstBad{\(firstBad ?? "none")} lastBad{\(lastBad ?? "none")} action=forwardedUnchanged timestampFallback=none downstreamAcceptance=unknown clockComparison=unverified"
    }
}
