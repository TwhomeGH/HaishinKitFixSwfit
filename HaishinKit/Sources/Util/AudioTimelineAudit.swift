import Foundation

/// 音軌來源跨度與已輸出 PCM 時長的數值稽核；不修改時間，不代表感知同步。
/// 由 mixer serial queue 擁有，格式／anchor 改變時另開世代，避免跨時鐘比較。
struct AudioTimelineAudit {
    private(set) var generation: UInt64 = 0
    private(set) var reason = "initial"
    private(set) var firstPTS: Double?
    private(set) var sourceEnd: Double?
    private(set) var inputSeconds = 0.0
    private(set) var outputSeconds = 0.0
    private var lastReport: Double?
    private var history: [String] = []

    /// 保留重設前摘要，最多 8 筆；不清除報告節流時鐘，避免重建風暴刷日誌。
    mutating func reset(reason: String) {
        if firstPTS != nil { remember(summary) }
        generation &+= 1
        self.reason = reason
        firstPTS = nil
        sourceEnd = nil
        inputSeconds = 0
        outputSeconds = 0
    }

    /// 輸入時長按實際樣本數／來源取樣率計算，不假設每包固定 1024。
    mutating func input(pts: Double, frames: Int, rate: Double) {
        guard pts.isFinite, frames > 0, rate.isFinite, rate > 0 else { return }
        if firstPTS == nil { firstPTS = pts }
        sourceEnd = pts + Double(frames) / rate
        inputSeconds += Double(frames) / rate
    }

    /// 輸出時長按轉換器實際交付樣本數計算；不可用要求數或編碼封包數代替。
    mutating func output(frames: Int, rate: Double) {
        guard frames > 0, rate.isFinite, rate > 0 else { return }
        outputSeconds += Double(frames) / rate
    }

    /// 來源時間跨度減去內容時長；正值可能含來源缺口，不直接等於音訊延遲。
    var sourceMinusInput: Double? {
        guard let firstPTS, let sourceEnd else { return nil }
        return sourceEnd - firstPTS - inputSeconds
    }

    var summary: String {
        "generation=\(generation) reset=\(reason) sourceMinusInputSeconds=\(sourceMinusInput.map(String.init(describing:)) ?? "unknown") inputSeconds=\(inputSeconds) outputSeconds=\(outputSeconds) inputMinusOutputSeconds=\(inputSeconds - outputSeconds) contentSync=notMeasured"
    }

    /// 每 30 秒最多一次，附最近 8 次採樣或重設前狀態。靜止時不自行啟動 timer。
    mutating func report(now: Double) -> String? {
        guard now.isFinite else { return nil }
        guard let lastReport else { self.lastReport = now; return nil }
        guard now - lastReport >= 30 else { return nil }
        self.lastReport = now
        let result = summary + " previous{" + history.joined(separator: " | ") + "}"
        remember(summary)
        return result
    }

    private mutating func remember(_ value: String) {
        history.append(value)
        if history.count > 8 { history.removeFirst(history.count - 8) }
    }
}
