/// 由 RTMPSocket actor 隔離存取。多個 close/drain 等待同一送出佇列時，
/// 每個等待者都必須完成；完成只表示等待結束，不保證資料送達。
struct RTMPDrainWaiters {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    var count: Int { continuations.count }

    mutating func append(_ continuation: CheckedContinuation<Void, Never>) {
        continuations.append(continuation)
    }

    /// 先移出再 resume，重複關閉不會二次喚醒，也不會覆蓋較早的等待者。
    mutating func finish() {
        let pending = continuations
        continuations.removeAll()
        for continuation in pending { continuation.resume() }
    }
}
