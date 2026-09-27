/// 有界的編碼輸出佇列，附帶「世代（generation）」防護。
///
/// 核心規則：**遺失一則訊息（佇列滿 / consumer 終止）= 整個 epoch 作廢**，
/// 而不是只丟那一則。因為 RTMP 後續封包可能依賴前一則（type-1 header 依賴
/// type-0、P 幀依賴前一個 keyframe / 參考幀），只丟一則會讓下游解出壞畫面。
/// 作廢會 `advanceGeneration()`，讓所有帶舊 generation 的待送訊息
/// （仍在 actor hop 途中的 stale item）被拒絕。
///
/// generation 同時隔離「舊連線 / 舊 consumer」：新連線的 generation 不同，
/// 舊的恢復流程（invalidateOutput）就無法誤關新連線。
///
/// 併發：只由其擁有的 stream / connection actor 存取，故 struct 本身為 Sendable。
struct RTMPOutputQueue<Element: Sendable>: Sendable {
    /// 每作廢一次 +1；同時代表「目前 epoch」的身分。
    private(set) var generation: UInt64 = 0
    private var continuation: AsyncStream<Element>.Continuation?
    var isOpen: Bool { continuation != nil }

    /// 開始新的 epoch：先作廢舊的，再建新 stream，回傳給 consumer 迭代。
    mutating func start(capacity: Int = 256) -> AsyncStream<Element> {
        invalidate()
        let (stream, continuation) = AsyncStream.makeStream(
            of: Element.self, bufferingPolicy: .bufferingOldest(capacity)
        )
        self.continuation = continuation
        return stream
    }

    /// 只推進 generation、不 finish 舊 continuation：讓 shutdown 指令
    /// （FCUnpublish / deleteStream）仍能在舊 transport 上排空，但新的媒體訊息
    /// （帶舊 generation）會被拒絕。
    mutating func advanceGeneration() { generation &+= 1 }

    /// 作廢整個 epoch：generation+1、finish 佇列、清掉 continuation。
    mutating func invalidate() {
        advanceGeneration()
        finish()
    }

    /// 正常停止：禁止新資料入列，但保留世代，讓 consumer 排完已接受的尾幀。
    /// 故障時不可使用這個方法單獨恢復；必須 invalidate，拒絕殘留依賴封包。
    mutating func finish() {
        continuation?.finish()
        continuation = nil
    }

    /// 嘗試入列。generation 不符（stale）或佇列已關 → false。
    /// `yield` 回傳 dropped / terminated（佇列滿或 consumer 已結束）→ 立即
    /// `invalidate()` 整個 epoch 並回 false；呼叫端據此關閉 transport。
    mutating func enqueue(_ item: Element, expectedGeneration: UInt64? = nil) -> Bool {
        if let expectedGeneration, expectedGeneration != generation { return false }
        guard let continuation else { return false }
        switch continuation.yield(item) {
        case .enqueued:
            return true
        case .dropped, .terminated:
            invalidate()
            return false
        @unknown default:
            invalidate()
            return false
        }
    }
}
