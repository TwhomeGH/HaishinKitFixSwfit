import Foundation

/// 抓幀時間的來源。
///
/// 這個型別獨立於 CoreMedia，讓內容同步的純邏輯可在非 Apple 平台驗證；
/// `unknown` 表示沒有可用的抓幀時間，不能當成「同步正常」。
public enum VideoFrameCaptureTimeSource: String, Codable, Sendable, Hashable {
    /// ScreenCaptureKit `SCStreamFrameInfo.displayTime` 或等價的顯示時間。
    case displayTime
    /// 來源 sample buffer 的 presentation time；不保證是真正的抓幀時間。
    case presentationTime
    /// 只有交付時間，退化成 handed PTS；無法量到內容延遲。
    case handed
    /// 沒有提供抓幀時間。
    case unknown
}
