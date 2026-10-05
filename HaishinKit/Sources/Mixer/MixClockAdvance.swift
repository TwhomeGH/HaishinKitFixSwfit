import Foundation

/// 純決策：某一軌輸出時，是否應由它推進混音時間軸。
///
/// `AudioMixerByMultiTrack` 的混音時鐘由 main track 驅動；當 main 靜默（例如
/// ReplayKit 情境 app 軌完全沒在播放）時，必須由其他軌接手推進，否則時間軸
/// 停滯、mic 音訊不再輸出。另一方面，只有 main「明確落後」才讓其他軌推進，
/// 否則同一區塊兩軌都會觸發 → 重複混音，且先到者的內容會被 align 當成過期丟棄。
///
/// 抽成純函式（僅 Foundation）以便單元測試與非 Apple 平台驗證
/// (`.cortexkit/verify-mixer-clock.swift`)；實際混音渲染需要 AVFoundation，
/// 由 macOS 的 `AudioMixerByMultiTrackTests` 覆蓋。
enum MixClockAdvance {
    /// - Parameters:
    ///   - track: 剛輸出、正考慮是否推進時鐘的軌。
    ///   - mainTrack: 設定中的混音主軌。
    ///   - mainLastOutputPosition: main 軌最近一次輸出的「幀結束位置」；nil 表示
    ///     main 從未輸出過。
    ///   - position: 目前這幀的起始位置（`when.sampleTime`）。
    /// - Returns: 是否應由這幀推進混音時間軸。
    static func shouldAdvance(
        track: UInt8,
        mainTrack: UInt8,
        mainLastOutputPosition: Int64?,
        position: Int64
    ) -> Bool {
        // main 軌本身永遠驅動時鐘。
        if track == mainTrack {
            return true
        }
        guard let mainLastOutputPosition else {
            // main 從未輸出過 → 由其他軌推進，避免時間軸從不啟動。
            return true
        }
        // 只有 main 明確落後才由其他軌推進；相同位置或領先 → 不推進（避免重複混音）。
        return mainLastOutputPosition < position
    }
}
