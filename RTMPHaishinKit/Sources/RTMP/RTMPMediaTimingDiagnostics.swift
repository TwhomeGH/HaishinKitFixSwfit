import Foundation

/// 同一筆壓縮媒體在 RTMP 訊息邊界的時間；全部以秒表示。
/// 來源時間保留原時鐘，RTMP 時間則是本發布世代的累計位置，兩者不可直接當作延遲相減。
public struct RTMPMediaTimingSample: Codable, Sendable, Equatable {
    /// 此軌本世代的訊息入列嘗試序號，從 1 開始；不包含 sequence header。
    public let sequence: UInt64
    /// 壓縮樣本的原始 PTS；無效值為 nil。
    public let sourcePTSSeconds: Double?
    /// 壓縮樣本原始 DTS；音訊或無有效 DTS 時為 nil，不用 PTS 冒充。
    public let sourceDTSSeconds: Double?
    /// 時間戳演算法已產生的累計 RTMP DTS，尚不保證入列成功。
    public let generatedDTSSeconds: Double?
    /// generated DTS 加實際訊息 composition time；音訊等於 generated DTS。
    public let generatedPTSSeconds: Double?
    /// 此 buffer 交給音訊時間戳演算法的 duration；可能含多個 packet 或使用後備值。
    public let preferredDurationSeconds: Double?
    /// 觀測所在程序的單調時間，供同程序事件對照；不可跨程序或重啟比較。
    public let observedUptimeSeconds: Double
    /// 本機 RTMP 訊息佇列是否接受；不代表 socket 完成或伺服器確認。
    public let accepted: Bool
}

/// 單軌入列邊界的固定大小觀測；沒有保留媒體 buffer，也不累積逐幀歷史。
public struct RTMPMediaTimingDiagnostics: Codable, Sendable {
    /// 成功建立媒體訊息後的入列嘗試數，不包含較早的格式錯誤或 keyframe 抑制。
    public private(set) var attempts: UInt64 = 0
    /// 本機訊息佇列接受數。
    public private(set) var accepted: UInt64 = 0
    /// 本機訊息佇列拒絕數。
    public private(set) var rejected: UInt64 = 0
    /// 本世代首筆入列嘗試；即使失敗也保留。
    public private(set) var firstAttempt: RTMPMediaTimingSample?
    /// 本世代首筆成功入列媒體；尚無成功入列時為 nil。
    public private(set) var firstAccepted: RTMPMediaTimingSample?
    /// 最新嘗試，包含其來源時間與結果；不是跨軌配對樣本。
    public private(set) var lastAttempt: RTMPMediaTimingSample?

    /// 在 RTMPStream actor 內記錄同一次 doOutput 的時間與結果。
    /// 非有限時間轉為 nil，避免 JSON 編碼失敗；不參與時間戳或佇列決策。
    mutating func record(pts: Double, dts: Double?, generatedDTS: Double,
                         compositionSeconds: Double, preferredDuration: Double?,
                         accepted: Bool, uptime: Double = ProcessInfo.processInfo.systemUptime) {
        func finite(_ value: Double?) -> Double? {
            guard let value, value.isFinite else { return nil }
            return value
        }
        attempts &+= 1
        let sample = RTMPMediaTimingSample(sequence: attempts,
            sourcePTSSeconds: finite(pts), sourceDTSSeconds: finite(dts),
            generatedDTSSeconds: finite(generatedDTS),
            generatedPTSSeconds: finite(generatedDTS + compositionSeconds),
            preferredDurationSeconds: finite(preferredDuration),
            observedUptimeSeconds: uptime, accepted: accepted)
        if firstAttempt == nil { firstAttempt = sample }
        if accepted {
            self.accepted &+= 1
            if firstAccepted == nil { firstAccepted = sample }
        } else {
            rejected &+= 1
        }
        lastAttempt = sample
    }

    /// 供低頻日誌使用；first 與 last 各自是一筆完整觀測，不能推定內容同步。
    var logDescription: String {
        func describe(_ sample: RTMPMediaTimingSample?) -> String {
            guard let sample else { return "unknown" }
            func number(_ value: Double?) -> String {
                value.map { String(format: "%.6f", $0) } ?? "unknown"
            }
            return "seq=\(sample.sequence),pts=\(number(sample.sourcePTSSeconds)),dts=\(number(sample.sourceDTSSeconds)),rtmpDTS=\(number(sample.generatedDTSSeconds)),rtmpPTS=\(number(sample.generatedPTSSeconds)),duration=\(number(sample.preferredDurationSeconds)),uptime=\(number(sample.observedUptimeSeconds)),accepted=\(sample.accepted)"
        }
        return "attempts=\(attempts) accepted=\(accepted) rejected=\(rejected) firstAttempt{\(describe(firstAttempt))} firstAccepted{\(describe(firstAccepted))} last{\(describe(lastAttempt))}"
    }
}
