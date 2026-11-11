import Foundation

/// 供上游應用程式採集的音訊管線健康快照，例如 ReplyKit 的 AHealth。
///
/// 計數器自音軌或 Mixer 建立後累計；呼叫端定期取差值計算速率。
/// 區塊計數以 buffers/s 表示，樣本計數以 samples/s 表示；兩者不能混用。
/// 目前佇列大小、就緒狀態與 RMS 是快照值，不是累計值。
public struct AudioPipelineDiagnostics: Sendable {
    /// AVAudioConverter 的呼叫與輸出狀態；用來區分正常等待與真正 underrun。
    public struct Converter: Sendable {
        public let convertCalls: Int
        public let haveDataCalls: Int
        public let noDataNowCalls: Int
        public let inputRanDryCalls: Int
        public let endOfStreamCalls: Int
        public let errorCalls: Int
        public let inputFramesRequested: Int
        public let inputFramesSupplied: Int
        public let outputFrames: Int
        public let zeroOutputCalls: Int
        public let inputBlockHaveDataCalls: Int
        public let inputBlockNoDataNowCalls: Int
        public let converterRebuilds: Int
        public let lastStatus: String
        public let lastError: String?
        public let inputFormat: String
        public let outputFormat: String

        public init(
            convertCalls: Int = 0,
            haveDataCalls: Int = 0,
            noDataNowCalls: Int = 0,
            inputRanDryCalls: Int = 0,
            endOfStreamCalls: Int = 0,
            errorCalls: Int = 0,
            inputFramesRequested: Int = 0,
            inputFramesSupplied: Int = 0,
            outputFrames: Int = 0,
            zeroOutputCalls: Int = 0,
            inputBlockHaveDataCalls: Int = 0,
            inputBlockNoDataNowCalls: Int = 0,
            converterRebuilds: Int = 0,
            lastStatus: String = "idle",
            lastError: String? = nil,
            inputFormat: String = "",
            outputFormat: String = ""
        ) {
            self.convertCalls = convertCalls
            self.haveDataCalls = haveDataCalls
            self.noDataNowCalls = noDataNowCalls
            self.inputRanDryCalls = inputRanDryCalls
            self.endOfStreamCalls = endOfStreamCalls
            self.errorCalls = errorCalls
            self.inputFramesRequested = inputFramesRequested
            self.inputFramesSupplied = inputFramesSupplied
            self.outputFrames = outputFrames
            self.zeroOutputCalls = zeroOutputCalls
            self.inputBlockHaveDataCalls = inputBlockHaveDataCalls
            self.inputBlockNoDataNowCalls = inputBlockNoDataNowCalls
            self.converterRebuilds = converterRebuilds
            self.lastStatus = lastStatus
            self.lastError = lastError
            self.inputFormat = inputFormat
            self.outputFormat = outputFormat
        }

        public static let empty = Converter()
    }

    /// 來源 PTS 缺口事件；只保留事件摘要，不攜帶 PCM。
    public struct GapEvent: Sendable {
        public let sequence: UInt64
        public let previousPTS: Double
        public let currentPTS: Double
        public let gapSamples: Int
        public let mode: String
        public let bufferedBefore: Int
        public let bufferedAfter: Int
        public let droppedSamples: Int

        public init(sequence: UInt64, previousPTS: Double, currentPTS: Double,
                    gapSamples: Int, mode: String, bufferedBefore: Int,
                    bufferedAfter: Int, droppedSamples: Int) {
            self.sequence = sequence
            self.previousPTS = previousPTS
            self.currentPTS = currentPTS
            self.gapSamples = gapSamples
            self.mode = mode
            self.bufferedBefore = bufferedBefore
            self.bufferedAfter = bufferedAfter
            self.droppedSamples = droppedSamples
        }
    }

    /// 單一音軌的重取樣與緩衝計數。
    public struct Track: Sendable {
        /// 呼叫端指定的音軌 ID；ReplyKit 慣例為 0 = App 音訊、1 = 麥克風。
        public let trackId: UInt8
        /// 重取樣後交付 Mixer 的音訊區塊累計數（didOutput 次數），不是 PCM 樣本數。
        public let outputFrames: Int
        /// 重取樣一次未產生輸出的累計次數，例如緩衝尚不足一個輸入區塊。
        /// 單次缺資料不代表永久故障，應與後續產出及 lastError 一起判讀。
        public let resampleNoDataCount: Int
        /// 跨軌 align() 為對齊 Mixer 時間軸而丟棄的過期樣本累計數。
        public let alignDroppedSamples: Int
        /// 跨軌 align() 為填補時間軸空隙而插入的靜音樣本累計數。
        public let alignInsertedSamples: Int
        /// 環形緩衝容量不足時丟棄的樣本累計數，常見於輸入速度超過消費速度。
        public let overflowDroppedSamples: Int
        /// append() 遇到 PTS 間隙時插入的靜音樣本累計數。
        public let skipInsertedSamples: Int
        /// 環形緩衝目前可讀取的樣本數。
        public let ringBufferCounts: Int
        /// align() 差距超出容許範圍而實際調整的累計次數。
        /// 可用於區分初次校正與持續逐幀校正。
        public let alignFireCount: Int
        /// 最近一次對齊差距，單位為輸入樣本：position - current。
        /// 正值表示本軌起點早於 Mixer 播放位置；負值表示起點較晚。
        public let lastAlignDiff: Int
        /// 此音軌 AVAudioConverter 的狀態與 frame 流量。
        public let converter: Converter
        /// 此音軌最近一次轉換輸出的各聲道 RMS；空陣列代表尚未取得。
        public let outputChannelRMS: [Float]
        /// 最近 8 筆來源 PTS 缺口；舊事件會被丟棄，避免無界成長。
        public let gapEvents: [GapEvent]
        /// 小缺口補零、大缺口重建時間軸的累計次數。
        public let gapZeroFillCount: Int
        public let gapRebaseCount: Int

        public init(
            trackId: UInt8,
            outputFrames: Int,
            resampleNoDataCount: Int,
            alignDroppedSamples: Int,
            alignInsertedSamples: Int,
            overflowDroppedSamples: Int,
            skipInsertedSamples: Int,
            ringBufferCounts: Int,
            alignFireCount: Int,
            lastAlignDiff: Int,
            converter: Converter = .empty,
            outputChannelRMS: [Float] = [],
            gapEvents: [GapEvent] = [],
            gapZeroFillCount: Int = 0,
            gapRebaseCount: Int = 0
        ) {
            self.trackId = trackId
            self.outputFrames = outputFrames
            self.resampleNoDataCount = resampleNoDataCount
            self.alignDroppedSamples = alignDroppedSamples
            self.alignInsertedSamples = alignInsertedSamples
            self.overflowDroppedSamples = overflowDroppedSamples
            self.skipInsertedSamples = skipInsertedSamples
            self.ringBufferCounts = ringBufferCounts
            self.alignFireCount = alignFireCount
            self.lastAlignDiff = lastAlignDiff
            self.converter = converter
            self.outputChannelRMS = outputChannelRMS
            self.gapEvents = gapEvents
            self.gapZeroFillCount = gapZeroFillCount
            self.gapRebaseCount = gapRebaseCount
        }
    }

    /// 各音軌的計數快照，依 trackId 排序。
    public let tracks: [Track]
    /// Mixer 已渲染的混音區塊累計數；不等於下游編碼或 RTMP 傳送成功數。
    public let mixerOutputFrames: Int
    /// Mixer 的 mixerNode 與 outputNode 是否已建立。
    /// false 表示目前尚未就緒；需搭配 lastError 區分尚未初始化與節點建立失敗。
    public let mixerReady: Bool
    /// 最近一次設定或渲染錯誤說明；沒有記錄時為 nil。
    /// 用於補足 AudioCaptureUnit 錯誤回呼未向外傳遞時的診斷資訊。
    public let lastError: String?
    /// 混音輸出格式的聲道數：1 為單聲道、2 為立體聲；未取得格式時可能為 0。
    public let outputChannels: Int
    /// 最近一次混音區塊各聲道的 RMS，陣列索引對應聲道。
    /// 可用單側測試訊號檢查下混或聲道遺失；非零值本身不能證明遠端播放正常。
    public let outputChannelRMS: [Float]

    public init(
        tracks: [Track],
        mixerOutputFrames: Int,
        mixerReady: Bool = false,
        lastError: String? = nil,
        outputChannels: Int = 0,
        outputChannelRMS: [Float] = []
    ) {
        self.tracks = tracks
        self.mixerOutputFrames = mixerOutputFrames
        self.mixerReady = mixerReady
        self.lastError = lastError
        self.outputChannels = outputChannels
        self.outputChannelRMS = outputChannelRMS
    }

    public static let empty = AudioPipelineDiagnostics(tracks: [], mixerOutputFrames: 0)
}
