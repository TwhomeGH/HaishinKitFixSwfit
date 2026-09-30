import Foundation

/// VT 編碼器輸出狀態機，每個 VT session 一個實例。
///
/// 核心不變式：**「請求 keyframe」不等於「keyframe 成功」**。`forceKeyFrame`
/// 只是對 VT 下一個請求；真正的確認必須是 VT callback 交回一個合法 sync sample，
/// 且被 continuation 接受（yield == .enqueued）。因此：
/// - 在確認成功之前 `waitingForKeyFrame` 維持 true，任何 P 幀都不放行；
/// - encode 非同步失敗（status != noErr）或 VT 丟棄幀 → 回到等 keyframe；
/// - session 被替換或輸出佇列作廢 → `invalidate()`，避免舊 session 的 callback
///   （VT 可能在 session 已替換後才回來）污染新 session 或任何 consumer。
///
/// 併發：VT callback 跑在 VT 自己的執行緒，可能與 actor 上的讀取交錯，故所有狀態
/// 由 NSLock 保護；且**絕不在 VT callback 內取 OutgoingStream 的鎖**，避免死鎖。
final class VideoEncoderOutputState: @unchecked Sendable {
    private let lock = NSLock()
    private let diagnostics: VideoPipelineEventTracker
    init(diagnostics: VideoPipelineEventTracker = VideoPipelineEventTracker()) {
        self.diagnostics = diagnostics
    }
    func submitted() { diagnostics.record(.encoderSubmitted) }
    func callback() {
        lock.lock(); defer { lock.unlock() }
        if active { diagnostics.record(.encoderCallback) }
    }
    /// false = 此 state 已作廢（session 被替換 / 停止），之後所有 callback 直接忽略。
    private var active = true
    /// true = 正在等一個「已確認」的 keyframe；確認前不放行任何 P 幀。
    private var waitingForKeyFrame = true
    /// 最後一個確認成功（被 continuation 接受）的 keyframe PTS（秒）。
    private var lastKeyFrameSeconds: Double?
    /// encode 非同步失敗碼。一旦寫入就持續失敗，直到 owner 換掉 session 為止。
    private var failure: Int32?

    /// 作廢此 state：舊 session 的 callback 之後一律被忽略。
    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        active = false
    }

    /// VT callback 回報非同步 encode 失敗：標記失敗並回到等 keyframe。
    /// 只有仍有效的 session 首次失敗回 true，讓呼叫端記錄一次；舊回呼不誤報。
    @discardableResult
    func recordFailure(_ status: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard active else { return false }
        let firstFailure = failure == nil
        diagnostics.record(.encoderFailure, errorCode: status)
        failure = status
        waitingForKeyFrame = true
        return firstFailure
    }

    /// 取得失敗碼（不消費、不清除）。刻意保留失敗到 owner 換 session：在這次讀取
    /// 與 invalidate 之間仍可能有並行 callback 想被放行，失敗必須持續擋住它們。
    func takeFailure() -> Int32? {
        lock.lock()
        defer { lock.unlock() }
        return failure
    }

    /// VT 丟棄了這一幀：視為 GOP 斷點，回到等 keyframe。
    func dropped() {
        lock.lock()
        defer { lock.unlock() }
        guard active else { return }
        diagnostics.record(.encoderDropped)
        waitingForKeyFrame = true
    }

    /// 是否該對這顆 frame 下 `forceKeyFrame`。工作階段一開始（或 GOP 斷點後）
    /// 必為 true；之後只有距上次「已確認」keyframe 超過 `interval` 才再要求。
    /// `interval <= 0`（停用週期 keyframe）時仍會要求啟動時的第一顆。
    func shouldForceKeyFrame(at seconds: Double, interval: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard active else { return false }
        if waitingForKeyFrame { return true }
        guard interval > 0, let lastKeyFrameSeconds else { return false }
        return seconds - lastKeyFrameSeconds >= interval
    }

    /// 把一個 VT 輸出交給 consumer。只有當此 state 仍 active、沒有失敗、且
    /// （正在等 keyframe 時）這顆確實是 keyframe，才呼叫 `yield`。
    /// `yield` 回傳 false（continuation 已終止 / 緩衝滿）→ 視同丟棄，回到等
    /// keyframe。成功且為 keyframe 才更新 `lastKeyFrameSeconds` 並解除等待。
    func deliver(isKeyFrame: Bool, seconds: Double, yield: () -> Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard active, failure == nil else { return }
        guard !waitingForKeyFrame || isKeyFrame else {
            diagnostics.record(.encoderKeyFrameSuppressed)
            return
        }
        guard yield() else {
            diagnostics.record(.encoderYieldRejected)
            waitingForKeyFrame = true
            return
        }
        diagnostics.record(.encoderDelivered)
        if isKeyFrame {
            diagnostics.record(.encoderKeyFrame)
            lastKeyFrameSeconds = seconds
            waitingForKeyFrame = false
        }
    }
}
