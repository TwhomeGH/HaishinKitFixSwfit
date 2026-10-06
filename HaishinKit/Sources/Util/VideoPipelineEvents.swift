import Foundation

/// 影片管線的固定診斷事件集合，對應編碼器與 RTMP 本機輸出階段。
///
/// 每個事件只累計次數與最後時間，避免逐幀保存紀錄造成記憶體成長。
/// 不同事件可能描述同一影格的不同階段，不能把全部 count 相加當作影格總數。
/// 枚舉 rawValue 是 events 字典使用的鍵，保留原始 API 名稱。
public enum VideoPipelineEvent: String, Codable, Sendable, CaseIterable {
    /// 影格進入 VideoToolbox 編碼提交階段；不代表回呼或編碼成功。
    case encoderSubmitted
    /// 仍有效的編碼工作階段收到 VideoToolbox 回呼，可能包含失敗或丟幀。
    case encoderCallback
    /// 編碼結果已被下游 continuation 接受；不代表 RTMP 入列或網路送出。
    case encoderDelivered
    /// 關鍵幀已被編碼器下游接受；只提出強制關鍵幀請求不會記錄此事件。
    case encoderKeyFrame
    /// VideoToolbox 回報丟幀，編碼輸出狀態回到等待關鍵幀。
    case encoderDropped
    /// 有效編碼工作階段記錄到失敗碼；最近錯誤另保存在 lastErrorCode。
    case encoderFailure
    /// VideoCodec 捕捉到轉換錯誤並進入重設／恢復處理；不代表恢復完成。
    case encoderRecovery
    /// 原始影格被 useFrame() 的影格選取策略略過，尚未提交編碼。
    case encoderFiltered
    /// 編碼器未運行，或目前缺少 session／continuation，無法處理輸入。
    case encoderUnavailable
    /// VideoCodec 的 session 屬性變更並重新建立輸出狀態；不保證新 session 已成功編碼。
    case encoderSessionChanged
    /// 編碼輸出端等待關鍵幀時，阻擋了非關鍵幀。
    case encoderKeyFrameSuppressed
    /// 編碼輸出 continuation 未接受結果，例如已終止或緩衝拒收；回到等待關鍵幀。
    case encoderYieldRejected
    /// 開始建立發布工作的輸入／輸出任務；不代表伺服器已確認發布。
    case publishStarted
    /// 停止既有發布任務並記錄收尾狀態；不代表遠端已收到全部待送資料。
    case publishStopped
    /// RTMPStream 接到壓縮影像樣本；後續仍可能被發布狀態或關鍵幀條件拒絕。
    case encodedReceived
    /// 接到編碼結果時未處於 publishing，或 RTMP 輸出佇列未開啟，因此略過結果。
    case outputUnavailable
    /// RTMP 輸出端等待關鍵幀時阻擋非關鍵幀，與編碼器端的同類事件分開計數。
    case keyFrameSuppressed
    /// 無法將編碼影像建立為 RTMP 影片訊息。
    case messageCreationFailed
    /// 影片訊息已被 RTMPStream 輸出佇列接受，尚非 socket 傳送完成。
    case videoQueued
    /// RTMPStream 輸出佇列拒絕影片訊息；需配合佇列與發布生命週期判讀。
    case videoQueueRejected
    /// 影片交給連線層後回傳正數接受位元組；不代表 socket 完成或對端確認。
    case connectionVideoAccepted
    /// 影片交給連線層後未取得正數接受位元組；不是伺服器拒絕的直接證據。
    case connectionVideoRejected
}

/// 單一事件的累計次數與最近觀察時間。
public struct VideoPipelineEventValue: Codable, Sendable {
    /// 此 tracker 自建立以來觀察到的事件次數。
    public let count: UInt64
    /// 最近事件的單調時鐘秒數，不是 Unix 時間。
    public let lastAt: TimeInterval
}

/// 同一 tracker 的累計事件；缺少某個 key 表示從未觀察到該事件。
public struct VideoPipelineEventsSnapshot: Codable, Sendable {
    /// 事件 tracker 的識別碼；不同 ID 的累計值不能直接相減。
    public let id: UUID
    /// 取樣時的單調時鐘秒數。
    public let sampledAt: TimeInterval
    /// 事件名稱對應累計值；缺少 key 表示未觀察到，不是取樣時間為零。
    public let events: [String: VideoPipelineEventValue]
    /// 最近記錄的錯誤碼；nil 表示未記錄。後續成功不會自動清除此歷史值。
    public let lastErrorCode: Int32?
    /// 距指定事件最後一次發生的秒數；從未觀察到時為 nil。
    public func idle(for event: VideoPipelineEvent) -> TimeInterval? {
        events[event.rawValue].map { max(0, sampledAt - $0.lastAt) }
    }
    /// 依名稱排序的日誌摘要；包含累計次數、閒置秒數及最近錯誤碼。
    public var summary: String {
        events.keys.sorted().map { key in
            let value = events[key]!
            return "\(key)=\(value.count) idle=\(max(0, sampledAt - value.lastAt))"
        }.joined(separator: " ") + " lastError=\(lastErrorCode.map(String.init) ?? "none")"
    }
}

package final class VideoPipelineEventTracker: @unchecked Sendable {
    private let lock = NSLock()
    private let id = UUID()
    private let clock: @Sendable () -> TimeInterval
    private var events: [String: VideoPipelineEventValue] = [:]
    private var lastErrorCode: Int32?
    package init(clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.clock = clock
    }
    package func record(_ event: VideoPipelineEvent, errorCode: Int32? = nil) {
        lock.lock(); defer { lock.unlock() }
        let key = event.rawValue
        events[key] = VideoPipelineEventValue(count: (events[key]?.count ?? 0) &+ 1, lastAt: clock())
        if let errorCode { lastErrorCode = errorCode }
    }
    package func snapshot() -> VideoPipelineEventsSnapshot {
        lock.lock(); defer { lock.unlock() }
        return VideoPipelineEventsSnapshot(id: id, sampledAt: clock(), events: events, lastErrorCode: lastErrorCode)
    }
}
