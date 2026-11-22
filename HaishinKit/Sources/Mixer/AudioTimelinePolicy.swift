import Foundation

/// 音訊時間軸不連續的單一策略。
///
/// 先前 anchor、兩個 ring buffer 與 mix clock 各自使用不同門檻，且
/// `timestampResetThreshold` 以樣本數寫死，導致同一事件在不同層得到不同結果
/// （部分重設）；基準一旦錯位，後續 gap 換算與 `align()` 都會沿用錯的基準。
/// 這裡把「秒」門檻集中在一處，各層只依分類動作。
enum AudioTimelinePolicy {
    /// 前向缺口 ≤ 此值：補零，保留 anchor 與時間軸。
    static let zeroFillMaxSeconds: TimeInterval = 0.25

    /// 倒退超過此值：全面重設（anchor、ring buffer 與 mix clock）。
    /// 倒退 ≤ 此值視為時鐘抖動：保留既有時間軸，不重設。
    static let resyncSeconds: TimeInterval = 1.0

    /// 來源時間差的分類；delta 為「本次 PTS − 上次 PTS」的秒數。
    enum Delta: Equatable {
        /// 無變化，或前向缺口在補零範圍內。
        case continuous
        /// 0 < delta ≤ `zeroFillMaxSeconds`：補零即可。
        case zeroFillForward
        /// delta > `zeroFillMaxSeconds`：重建時間軸。
        case rebaseForward
        /// −`resyncSeconds` ≤ delta < 0：視為抖動，保留時間軸。
        case jitterBackward
        /// delta < −`resyncSeconds`：全面重設。
        case resyncBackward
    }

    /// 依來源時間差分類；非有限值不視為不連續。
    static func classify(_ deltaSeconds: Double) -> Delta {
        guard deltaSeconds.isFinite else { return .continuous }
        if deltaSeconds > zeroFillMaxSeconds { return .rebaseForward }
        if deltaSeconds > 0 { return .zeroFillForward }
        if deltaSeconds < -resyncSeconds { return .resyncBackward }
        if deltaSeconds < 0 { return .jitterBackward }
        return .continuous
    }

    /// 秒 → 樣本數，使用實際取樣率；非有限或非正值的參數回 0，
    /// 呼叫端不得把 0 當成「已達門檻」而重設時間軸。
    static func samples(forSeconds seconds: TimeInterval, rate: Double) -> Int64 {
        guard seconds.isFinite, seconds > 0, rate.isFinite, rate > 0 else { return 0 }
        return Int64((seconds * rate).rounded())
    }
}
