import Foundation

/// 唯讀診斷資料；容量只涵蓋佇列持有的資料，不代表程序記憶體。
public struct VideoQueueSnapshot: Codable, Sendable {
    /// 此佇列實例的識別碼；更換佇列後改變，不能跨 ID 計算速率。
    public let id: UUID
    /// 取樣時的單調時鐘秒數（systemUptime），不是 Unix 日期時間。
    public let sampledAt: TimeInterval
    /// offer() 嘗試送入的累計影格數，包含因關閉或過大而拒收的影格。
    public let received: Int
    /// 已交付消費端的累計影格數，不代表處理或編碼成功。
    public let consumed: Int
    /// 目前佇列持有的影格數，不含已交付消費端的影格。
    public let queued: Int
    /// 目前佇列持有資料的位元組估計量，不是程序記憶體。
    public let bytes: Int
    /// 目前允許佇列持有的位元組上限。
    public let byteLimit: Int
    /// 此佇列實例曾持有的最高位元組量。
    public let peakBytes: Int
    /// 設定的影格最大停留時間，單位為秒；不是觀測最大耗時。
    public let maxAge: TimeInterval
    /// 額外設定的影格數上限；nil 表示未設定，仍受位元組及停留時間限制。
    public let manualFrameLimit: Int?
    /// 目前最舊影格已等待的秒數；空佇列為 0。
    public let oldestAge: TimeInterval
    /// 已交付影格曾觀測到的最長佇列等待秒數，不包含後續 GPU／編碼耗時。
    public let maxWait: TimeInterval
    /// 為符合容量或手動影格上限而淘汰的累計影格數。
    public let capacityDrops: Int
    /// 因停留時間超限而淘汰的累計影格數。
    public let expiredDrops: Int
    /// 單張資料超過 byteLimit 而拒收的累計影格數。
    public let oversizedDrops: Int
    /// 佇列關閉後仍送入而拒收的累計影格數。
    public let closedDrops: Int
    /// 關閉佇列時清除的累計待處理影格數。
    public let shutdownDrops: Int
    /// 距上次 offer() 的秒數；尚未收到輸入時為 nil，並非 0。
    public let inputIdle: TimeInterval?
    /// 距上次交付影格的秒數；尚未交付時為 nil。
    public let outputIdle: TimeInterval?
    /// 佇列是否已關閉，不再接收新影格。
    public let closed: Bool

    /// 不同佇列或非遞增時間沒有可比較的速率。
    public func rates(since previous: Self?) -> VideoQueueRates? {
        guard let previous, id == previous.id, sampledAt > previous.sampledAt,
              received >= previous.received, consumed >= previous.consumed else { return nil }
        let elapsed = sampledAt - previous.sampledAt
        return VideoQueueRates(inputFPS: Double(received - previous.received) / elapsed,
                               outputFPS: Double(consumed - previous.consumed) / elapsed)
    }

    /// 供日誌使用的文字摘要；Age／Wait 轉成毫秒，Idle 保持秒，缺少 Idle 時以 -1 表示。
    public var summary: String {
        "in=\(received) out=\(consumed) queued=\(queued) bytes=\(bytes)/\(byteLimit) peakBytes=\(peakBytes) maxAgeMs=\(maxAge * 1000) oldestMs=\(oldestAge * 1000) maxWaitMs=\(maxWait * 1000) capacityDrop=\(capacityDrops) expiredDrop=\(expiredDrops) oversizedDrop=\(oversizedDrops) closedDrop=\(closedDrops) shutdownDrop=\(shutdownDrops) inputIdle=\(inputIdle ?? -1) outputIdle=\(outputIdle ?? -1) closed=\(closed)"
    }
}

/// 同一佇列兩次快照的區間速率，單位為影格／秒。
public struct VideoQueueRates: Codable, Sendable {
    /// 兩次快照之間每秒輸入嘗試的影格數，包含拒收影格。
    public let inputFPS: Double
    /// 兩次快照之間每秒交付消費端的影格數，不是編碼 FPS。
    public let outputFPS: Double
}

/// 單一佇列階段的可用狀態、世代與資料。
public struct VideoQueueStageSnapshot: Codable, Sendable {
    /// 此次取樣的資料可用狀態，不是影片播放或網路健康狀態。
    public enum Availability: String, Codable, Sendable {
        /// 已取得本階段佇列資料；仍需檢查 queue.closed、等待時間及丟棄計數。
        case available
        /// 本階段沒有可提供的佇列資料，例如尚未建立；不可解讀為空佇列或零負載。
        case unavailable
        /// 無法立即取得擁有者鎖，為避免阻塞而略過本次取樣；不表示死鎖或永久不可用。
        case ownerLockBusy
    }
    /// 是否能取得本階段資料；鎖忙與尚未建立不能視為零負載。
    public let availability: Availability
    /// 擁有者的佇列世代；nil 表示未取得。速率比較仍以 queue.id 為準。
    public let generation: UInt64?
    /// 擁有者尚無佇列時略過的累計影格數，不包含在 queue 的丟棄計數中；nil 表示未取得。
    public let missingDrops: Int?
    /// 本階段的佇列快照；nil 表示目前沒有可讀取的佇列資料。
    public let queue: VideoQueueSnapshot?

    /// 組合呼叫端已取得的診斷資料；不會觸發擷取、編碼或網路傳送。
    public init(availability: Availability, generation: UInt64? = nil,
                missingDrops: Int? = nil, queue: VideoQueueSnapshot? = nil) {
        self.availability = availability
        self.generation = generation
        self.missingDrops = missingDrops
        self.queue = queue
    }

    /// 產生易讀摘要；有可比較的前次佇列快照時附上區間速率。
    /// - Parameter previous: 同一觀察來源的前次快照；不同 queue.id 不計算速率。
    /// - Returns: 日誌文字，格式不適合作為穩定的機器解析接口；UI 應直接讀欄位。
    public func summary(since previous: Self? = nil) -> String {
        let rates = queue?.rates(since: previous?.queue)
        let rateText = rates.map { String(format: "inFPS=%.1f outFPS=%.1f ", $0.inputFPS, $0.outputFPS) } ?? "rates=unavailable "
        return "state=\(availability.rawValue) generation=\(generation.map(String.init) ?? "unavailable") missingDrop=\(missingDrops.map(String.init) ?? "unavailable") " + rateText + (queue?.summary ?? "queue=unavailable")
    }
}

/// Mixer 的影像輸入與輸出階段；兩者依序取樣。
public struct VideoMixerSnapshot: Codable, Sendable {
    /// Mixer 影像輸入階段的佇列快照。
    public let input: VideoQueueStageSnapshot
    /// Mixer 影像輸出階段的佇列快照。
    public let output: VideoQueueStageSnapshot
    /// 組合呼叫端已取得的診斷資料；不會觸發擷取、編碼或網路傳送。
    public init(input: VideoQueueStageSnapshot, output: VideoQueueStageSnapshot) {
        self.input = input; self.output = output
    }
}

/// 影片從 Mixer、編碼輸入到 RTMP 本機輸出階段的唯讀診斷彙總。
///
/// 由 RTMPHaishinKit 的 RTMPStream.videoPipelineSnapshot() 取得；
/// MediaMixer.videoPipelineSnapshot() 則只回傳 VideoMixerSnapshot。
/// 各階段依序取樣，不保證跨階段的原子一致性，不能用單次計數差直接推論丟幀。
/// 時間採單調時鐘；累計量的生命週期依佇列／事件 tracker／橋接器而不同。
/// 請以 queue.id、事件 id 與上游串流實例分別判斷是否可比較。
public struct VideoPipelineSnapshot: Codable, Sendable {
    /// 快照資料結構版本，目前為 2；不是套件版本或連線世代。
    public let schemaVersion: Int
    /// 彙總快照的單調時鐘秒數；各子快照另有自己的取樣時間。
    public let sampledAt: TimeInterval
    /// 來源 Mixer 的輸入／輸出佇列；尚無來源或來源已釋放時可能為 nil。
    public let mixer: VideoMixerSnapshot?
    /// 原始影格送入編碼器之前的佇列階段。
    public let encoderInput: VideoQueueStageSnapshot
    /// 此串流橋接器觀察到的 Mixer 影像回呼累計數，包含 pressureDrops。
    /// 不是來源擷取 FPS，也不等於已送入編碼器的數量。
    public let bridgeReceived: Int
    /// 橋接器在編碼前因背壓而略過的累計影格數；是 bridgeReceived 的子集。
    public let pressureDrops: Int
    /// 橋接器最近觀察到的影像 PTS，單位為秒，包含因背壓略過的影格。
    /// 尚無有效且非負的 PTS 時為 nil；與 sampledAt 不可直接相減。
    public let lastPTS: Double?
    /// VideoToolbox 編碼提交、回呼、交付、丟棄與錯誤的事件快照；nil 表示未提供。
    public let encoder: VideoPipelineEventsSnapshot?
    /// RTMPStream 的編碼接收、訊息建立、輸出入列與連線接受事件。
    /// 只表示本機管線進度，不代表 socket 成功送出或伺服器確認；nil 表示未提供。
    public let output: VideoPipelineEventsSnapshot?

    /// 組合呼叫端已取得的診斷資料；不會觸發擷取、編碼或網路傳送。
    public init(sampledAt: TimeInterval, mixer: VideoMixerSnapshot?, encoderInput: VideoQueueStageSnapshot,
                bridgeReceived: Int, pressureDrops: Int, lastPTS: Double?,
                encoder: VideoPipelineEventsSnapshot? = nil, output: VideoPipelineEventsSnapshot? = nil) {
        schemaVersion = 2
        self.encoder = encoder; self.output = output
        self.sampledAt = sampledAt; self.mixer = mixer; self.encoderInput = encoderInput
        self.bridgeReceived = bridgeReceived; self.pressureDrops = pressureDrops
        self.lastPTS = lastPTS
    }

    /// 產生易讀摘要；有可比較的前次佇列快照時附上區間速率。
    /// - Parameter previous: 同一觀察來源的前次快照；不同 queue.id 不計算速率。
    /// - Returns: 日誌文字，格式不適合作為穩定的機器解析接口；UI 應直接讀欄位。
    public func summary(since previous: Self? = nil) -> String {
        "schema=\(schemaVersion) encoder{\(encoder?.summary ?? "unavailable")} output{\(output?.summary ?? "unavailable")} encoderInput{\(encoderInput.summary(since: previous?.encoderInput))} bridge{received=\(bridgeReceived) pressureDrop=\(pressureDrops) lastPTS=\(lastPTS ?? -1)} mixer{input{\(mixer?.input.summary(since: previous?.mixer?.input) ?? "unavailable")} output{\(mixer?.output.summary(since: previous?.mixer?.output) ?? "unavailable")}}"
    }
}
