import Foundation

/// `AudioRingBuffer.align(to:)` 的純決策：只算要丟多少、從哪裡丟，或補多少靜音。
///
/// 不持有 buffer、不修改狀態，因此可在非 Apple 平台用 `swiftc` 編譯真碼驗證
/// （見 `.cortexkit/verify-align.swift`），不必再維護一份鏡射實作。
enum AudioRingBufferAlignment {
    enum Decision: Equatable {
        case none
        /// 播放頭在資料起點之前：補這麼多靜音樣本。
        case insertSilence(samples: Int)
        /// 播放頭在資料起點之後：最多丟棄 `available` 個樣本。
        /// 先消耗 `fromSkip` 個尚未輸出的補零，再丟 `fromStored` 個實際樣本。
        case drop(total: Int, fromSkip: Int, fromStored: Int)
    }

    /// - Parameters:
    ///   - behind: `position - (sampleTime - available)`；正值代表播放頭在資料前方（要丟）。
    ///   - available: 目前可讀樣本數（stored samples + pending silence）。
    ///   - pendingSilence: 尚未輸出的補零樣本數。
    ///   - deadband: `abs(behind)` 在此值內視為量測抖動，不調整。
    /// - Returns: 純決策；呼叫端負責套用到 buffer 與計數。
    static func decide(behind: Int64, available: Int, pendingSilence: Int, deadband: Int64) -> Decision {
        if behind > deadband {
            let total = Int(min(behind, Int64(max(0, available))))
            let fromSkip = min(max(0, pendingSilence), total)
            return .drop(total: total, fromSkip: fromSkip, fromStored: total - fromSkip)
        }
        if behind < -deadband {
            return .insertSilence(samples: Int(-behind))
        }
        return .none
    }
}
