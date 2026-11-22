import Foundation

/// 單一媒體／軌道的入口時間診斷；由 MediaMixer actor 隔離，不修正或拒收樣本。
///
/// 除了 CMTime 有效性，也記錄「有效 PTS 之間」的間隔與到達時間漂移，
/// 用來回答「幀與幀的間隔在哪裡變了」——這是 wire 端 `RTMPTimestamp`
/// 看不到的上游階段。
struct SourceTimeAudit {
    /// 間隔分桶門檻（秒）；兩個桶互斥：0.5–2s 與 ≥2s。
    static let gapHalfSecond: Double = 0.5
    static let gapTwoSeconds: Double = 2.0
    /// 來源 PTS 前進量與到達時間前進量相差超過此值時回報（秒）。
    static let driftThresholdSeconds: Double = 1.0

    private(set) var received: UInt64 = 0
    private(set) var invalid: UInt64 = 0
    private(set) var consecutive: UInt64 = 0
    private(set) var longestRun: UInt64 = 0
    private(set) var recoveries: UInt64 = 0
    private(set) var lastValidPTS: Double?
    /// 最近一次「有效 → 有效」的來源時間差。
    private(set) var lastDelta: Double?
    /// 同一區間的到達時間差（單調時鐘）。
    private(set) var lastArrivalDelta: Double?
    /// `lastDelta - lastArrivalDelta`；正值代表來源時間跑得比到達時間快。
    private(set) var lastDrift: Double?
    private(set) var maxAbsDrift: Double = 0
    /// 只統計正向且非重複的間隔，避免負值與 0 拉歪 min/max。
    private(set) var minDelta: Double?
    private(set) var maxDelta: Double?
    private(set) var negativeDeltas: UInt64 = 0
    private(set) var duplicateDeltas: UInt64 = 0
    /// 0.5 ≤ delta < 2.0 秒的次數。
    private(set) var gapsOverHalfSecond: UInt64 = 0
    /// delta ≥ 2.0 秒的次數。
    private(set) var gapsOverTwoSeconds: UInt64 = 0
    private var firstBad: String?
    private var lastBad: String?
    private var lastValidArrival: Double?
    private var lastArrival = 0.0
    private var lastReport: Double?
    private var lastAnomalyReport: Double?

    /// 獨立保存入口到達的單調時間。reason 為 nil 才是有效來源時間。
    /// - Returns: 首次異常立即回報，其後最多每 30 秒一則；正常入口也有低頻摘要。
    mutating func observe(pts: Double, reason: String?, detail: String, now: Double) -> String? {
        received &+= 1
        lastArrival = now
        let bad = reason != nil || !pts.isFinite
        var anomaly: String?
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
            anomaly = updateInterval(pts: pts, now: now)
            lastValidPTS = pts
            lastValidArrival = now
        }

        // 有效時間軸上的間隔／漂移異常：首次或距上次異常回報滿 30 秒才輸出。
        if let anomaly {
            let previousAnomaly = lastAnomalyReport
            if previousAnomaly == nil || now - (previousAnomaly ?? now) >= 30 {
                lastAnomalyReport = now
                lastReport = now
                return "event=\(anomaly) " + summary
            }
        }
        if lastReport == nil || (bad && invalid == 1) || now - (lastReport ?? now) >= 30 {
            lastReport = now
            return summary
        }
        return nil
    }

    /// 只在有效 PTS 之間計算；首筆沒有前一筆有效值，不產生間隔。
    /// - Returns: 需要立即回報的異常名稱；正常間隔回 nil。
    private mutating func updateInterval(pts: Double, now: Double) -> String? {
        guard let previousPTS = lastValidPTS, let previousArrival = lastValidArrival else {
            return nil
        }
        let delta = pts - previousPTS
        let arrivalDelta = now - previousArrival
        let drift = delta - arrivalDelta
        lastDelta = delta
        lastArrivalDelta = arrivalDelta
        lastDrift = drift
        maxAbsDrift = max(maxAbsDrift, abs(drift))

        if delta < 0 {
            negativeDeltas &+= 1
            return "negativeDelta"
        }
        if delta == 0 {
            duplicateDeltas &+= 1
            return "duplicateDelta"
        }
        minDelta = min(minDelta ?? delta, delta)
        maxDelta = max(maxDelta ?? delta, delta)
        if delta >= Self.gapTwoSeconds {
            gapsOverTwoSeconds &+= 1
            return "gapOver2s"
        }
        if delta >= Self.gapHalfSecond {
            gapsOverHalfSecond &+= 1
            return "gapOver500ms"
        }
        if abs(drift) >= Self.driftThresholdSeconds {
            return "arrivalDrift"
        }
        return nil
    }

    /// 停止時可直接取摘要，確保節流期間的恢復或尾端異常不遺失。
    var summary: String {
        "received=\(received) invalid=\(invalid) consecutiveInvalid=\(consecutive) longestInvalidRun=\(longestRun) recoveries=\(recoveries) lastValidPTS=\(lastValidPTS.map(String.init(describing:)) ?? "unknown") lastArrivalUptime=\(lastArrival) lastDelta=\(lastDelta.map(String.init(describing:)) ?? "unknown") lastArrivalDelta=\(lastArrivalDelta.map(String.init(describing:)) ?? "unknown") lastDrift=\(lastDrift.map(String.init(describing:)) ?? "unknown") maxAbsDrift=\(maxAbsDrift) minDelta=\(minDelta.map(String.init(describing:)) ?? "unknown") maxDelta=\(maxDelta.map(String.init(describing:)) ?? "unknown") negativeDeltas=\(negativeDeltas) duplicateDeltas=\(duplicateDeltas) gapsOverHalfSecond=\(gapsOverHalfSecond) gapsOverTwoSeconds=\(gapsOverTwoSeconds) firstBad{\(firstBad ?? "none")} lastBad{\(lastBad ?? "none")} action=forwardedUnchanged timestampFallback=none downstreamAcceptance=unknown clockComparison=unverified"
    }
}
