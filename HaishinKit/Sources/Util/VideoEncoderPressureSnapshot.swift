import Foundation

/// VideoToolbox 編碼壓力的唯讀快照。
///
/// 這個型別只回答「我們送了多少、VT 回了多少、目前哪裡積壓」，
/// 不修改編碼設定、不丟棄影格，也不代表網路已送出。
/// `submitted`、`callbacks`、`delivered` 都是事件追蹤器建立以來的累計值；
/// 跨越編碼器 session 重建後，差值可能被舊 session 的未回呼影格放大，
/// 因此 `outstandingSubmissions` 只能當作趨勢，不是精確的即時佇列深度。
/// 即時積壓請看 `pendingFrames`、`queued` 與 `oldestAgeSeconds`。
public struct VideoEncoderPressureSnapshot: Codable, Sendable {
    /// 壓力分類。優先序由高到低：`dropping`、`vtBacklog`、`queueBacklog`、
    /// `callbackSlow`、`throttling`、`normal`。
    public enum State: String, Codable, Sendable {
        /// 沒有可用的編碼器或佇列資料，不能解讀為零壓力。
        case unavailable
        /// 沒有觀察到積壓、丟幀或明顯的編碼延遲。
        case normal
        /// 編碼前的原始影格佇列正在堆積。
        case queueBacklog
        /// VideoToolbox 的 `NumberOfPendingFrames` 超過高水位。
        case vtBacklog
        /// 最近一筆編碼回呼的耗時超過目前幀率的合理上限。
        case callbackSlow
        /// App 的 adaptive frame throttle 最近正在降幀，代表 VT 先前已落後。
        case throttling
        /// 最近發生 VT 丟幀、失敗、下游拒收或 PTS 重置。
        case dropping
    }

    /// 建立快照所需的純量輸入；由 `VideoEncoderPressureAdapter` 從既有事件、
    /// 佇列與 timing 快照轉換，測試與非 Apple harness 可直接建構。
    struct Input: Sendable {
        /// 是否有任何編碼器或佇列資料；false 時狀態為 `unavailable`。
        var hasData = false
        /// 取樣的單調時鐘秒數。
        var sampledAt: TimeInterval = 0
        /// 送入 VT 的累計影格數。
        var submitted: UInt64 = 0
        /// VT 回呼的累計次數，可能包含失敗或丟幀。
        var callbacks: UInt64 = 0
        /// 編碼結果被下游 continuation 接受的累計次數。
        var delivered: UInt64 = 0
        /// VT 回報丟幀的累計次數。
        var dropped: UInt64 = 0
        /// `useFrame` 過濾的累計影格數；不代表編碼器壓力。
        var filtered: UInt64 = 0
        /// 編碼失敗的累計次數。
        var failures: UInt64 = 0
        /// 編碼器 session 重建的累計次數。
        var sessionChanges: UInt64 = 0
        /// VT 目前的 pending frames；nil 表示未提供。
        var pendingFrames: Int?
        /// 編碼前原始影格佇列目前的影格數；nil 表示未提供。
        var queued: Int?
        /// 編碼前佇列最舊影格已等待的秒數。
        var oldestAgeSeconds: Double?
        /// 編碼前佇列已交付影格曾觀測到的最長等待秒數。
        var maxWaitSeconds: Double?
        /// 最近一筆成功回呼的提交到完成耗時，單位毫秒。
        var lastElapsedMilliseconds: Double?
        /// 最近一筆從 mixer 交付到編碼前 queue 的等待秒數。
        var lastHandoffWaitSeconds: Double?
        /// 最近一筆從 mixer 收到到送入 VT 的等待秒數。
        var lastReceivedToEncoderSeconds: Double?
        /// 最近 5 秒內是否發生 VT 丟幀。
        var recentDrop = false
        /// 最近 5 秒內是否發生編碼失敗。
        var recentFailure = false
        /// 最近 5 秒內是否發生下游拒收。
        var recentYieldRejected = false
        /// 最近 5 秒內是否發生 PTS 重置。
        var recentPTSReset = false
        /// 最近一次被過濾的影格是否為 adaptive throttle。
        var recentAdaptiveThrottle = false
        /// 最近是否觀察到編碼器不可用。
        var recentUnavailable = false
        /// 編碼器目標幀率；只用於計算合理的高水位與耗時上限。
        var expectedFrameRate: Double?
        /// 使用者設定的最大延遲幀數；有值時優先作為 pending 高水位。
        var maxFrameDelayCount: Int?
    }

    /// 壓力分類。
    public let state: State
    /// 快照的單調時鐘秒數。
    public let sampledAt: TimeInterval
    /// 送入 VT 的累計影格數。
    public let submitted: UInt64
    /// VT 回呼的累計次數。
    public let callbacks: UInt64
    /// 編碼結果被下游接受的累計次數。
    public let delivered: UInt64
    /// VT 回報丟幀的累計次數。
    public let dropped: UInt64
    /// `useFrame` 過濾的累計影格數。
    public let filtered: UInt64
    /// 編碼失敗的累計次數。
    public let failures: UInt64
    /// 編碼器 session 重建的累計次數。
    public let sessionChanges: UInt64
    /// 已提交但尚未回呼的累計差值；跨 session 重建時可能被放大。
    public let outstandingSubmissions: Int64
    /// 已回呼但未被下游接受的累計差值。
    public let undeliveredCallbacks: Int64
    /// VT 目前的 pending frames；nil 表示未提供。
    public let pendingFrames: Int?
    /// 判定 `vtBacklog` 的 pending 高水位。
    public let highWatermark: Int
    /// 壓力解除的 pending 低水位；供 UI 或後續閘門做遲滯。
    public let lowWatermark: Int
    /// 編碼前原始影格佇列目前的影格數。
    public let queued: Int?
    /// 編碼前佇列最舊影格已等待的秒數。
    public let oldestAgeSeconds: Double?
    /// 編碼前佇列曾觀測到的最長等待秒數。
    public let maxWaitSeconds: Double?
    /// 最近一筆成功回呼的提交到完成耗時，單位毫秒。
    public let lastElapsedMilliseconds: Double?
    /// 最近一筆從 mixer 交付到編碼前 queue 的等待秒數。
    public let lastHandoffWaitSeconds: Double?
    /// 最近一筆從 mixer 收到到送入 VT 的等待秒數。
    public let lastReceivedToEncoderSeconds: Double?
    /// 是否處於任何一種壓力狀態。
    public let isBehind: Bool
    /// 補幀機制是否應在此刻暫停；與 `isBehind` 相同，保留語意名稱給呼叫端。
    public let shouldPauseRepeats: Bool

    /// 由純量輸入計算狀態；不讀取時鐘、不取得鎖。
    init(input: Input) {
        let expected = max(input.expectedFrameRate ?? 60, 1)
        let high = input.maxFrameDelayCount.flatMap { $0 > 0 ? $0 : nil }
            ?? max(2, Int(ceil(expected / 12)))
        let low = max(1, high / 2)
        // 單幀合理耗時的三倍；60fps 至少 50ms，30fps 100ms，10fps 300ms。
        let slowMilliseconds = max(50, 3 * 1000 / expected)
        let isDropping = input.recentDrop || input.recentFailure
            || input.recentYieldRejected || input.recentPTSReset
        let isVTBacklog = input.pendingFrames.map { $0 > high } ?? false
        let isQueueBacklog = (input.queued ?? 0) > 1
            || (input.oldestAgeSeconds ?? 0) > 0.1
        let isCallbackSlow = input.lastElapsedMilliseconds.map { $0 > slowMilliseconds } ?? false

        let state: State
        if !input.hasData || input.recentUnavailable {
            state = .unavailable
        } else if isDropping {
            state = .dropping
        } else if isVTBacklog {
            state = .vtBacklog
        } else if isQueueBacklog {
            state = .queueBacklog
        } else if isCallbackSlow {
            state = .callbackSlow
        } else if input.recentAdaptiveThrottle {
            state = .throttling
        } else {
            state = .normal
        }

        self.state = state
        sampledAt = input.sampledAt
        submitted = input.submitted
        callbacks = input.callbacks
        delivered = input.delivered
        dropped = input.dropped
        filtered = input.filtered
        failures = input.failures
        sessionChanges = input.sessionChanges
        outstandingSubmissions = max(0, Int64(input.submitted) - Int64(input.callbacks))
        undeliveredCallbacks = max(0, Int64(input.callbacks) - Int64(input.delivered))
        pendingFrames = input.pendingFrames
        highWatermark = high
        lowWatermark = low
        queued = input.queued
        oldestAgeSeconds = input.oldestAgeSeconds
        maxWaitSeconds = input.maxWaitSeconds
        lastElapsedMilliseconds = input.lastElapsedMilliseconds
        lastHandoffWaitSeconds = input.lastHandoffWaitSeconds
        lastReceivedToEncoderSeconds = input.lastReceivedToEncoderSeconds
        isBehind = state != .normal && state != .unavailable
        shouldPauseRepeats = isBehind
    }

    /// 供日誌與診斷使用的單行摘要；未知值以 `unknown` 表示。
    public var summary: String {
        func number(_ value: Int?) -> String { value.map(String.init) ?? "unknown" }
        func milliseconds(_ value: Double?) -> String {
            value.map { String(format: "%.1f", max(0, $0)) } ?? "unknown"
        }
        return "state=\(state.rawValue) submitted=\(submitted) callbacks=\(callbacks) delivered=\(delivered) dropped=\(dropped) filtered=\(filtered) failures=\(failures) sessions=\(sessionChanges) outstanding=\(outstandingSubmissions) undelivered=\(undeliveredCallbacks) pending=\(number(pendingFrames)) high=\(highWatermark) low=\(lowWatermark) queued=\(number(queued)) oldestMs=\(milliseconds(oldestAgeSeconds.map { $0 * 1000 })) maxWaitMs=\(milliseconds(maxWaitSeconds.map { $0 * 1000 })) elapsedMs=\(milliseconds(lastElapsedMilliseconds)) handoffMs=\(milliseconds(lastHandoffWaitSeconds.map { $0 * 1000 })) receivedToEncoderMs=\(milliseconds(lastReceivedToEncoderSeconds.map { $0 * 1000 }))"
    }
}
