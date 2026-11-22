import Foundation

/// 音視訊在 mixer 入口的配對與內容年齡診斷；只觀測，不修改任何時間戳。
///
/// 配對以**到達時間**（同一程序的單調時鐘）為準：只有 `arrival` 相差在
/// `pairingWindow` 內的音訊／影片樣本才視為同一時間窗，避免用「最新音訊 vs 最新影片」
/// 捏造 offset。
///
/// - `handedOffset`：兩軌實際交給 mixer 的 PTS 差（video − audio）。
/// - `contentOffset`：優先用 `VideoFrameTrace.sourcePTS`（加工前來源時間）計算；
///   沒有來源時間時退化成 `handedOffset`，並在摘要標示 `captureTime=missing`。
/// - `ageSkew`：`videoAge − audioAge`，正值代表影片內容比音訊舊（聲音早、畫面晚）。
///
/// 要偵測「PTS 看起來正常、內容卻落後」的延遲，上游必須把真正的抓幀時間放進
/// `VideoFrameTrace.sourcePTS`。若 PTS 是在編碼時才產生，`videoAge` 會接近 0，
/// 這個審計無法從時間戳看出內容延遲——那正是 `captureTime=missing` 的訊號。
struct AVContentSyncAudit {
    enum Kind: String {
        case video
        case audio
    }

    struct Stats: Equatable {
        let count: Int
        let mean: Double
        let minValue: Double
        let maxValue: Double
        let slopePerMinute: Double?

        var description: String {
            "count=\(count) mean=\(Self.format(mean)) min=\(Self.format(minValue)) max=\(Self.format(maxValue)) slopePerMin=\(slopePerMinute.map(Self.format) ?? "unknown")"
        }

        private static func format(_ value: Double) -> String {
            String(format: "%.4f", value)
        }
    }

    static let defaultPairingWindow: TimeInterval = 0.05
    static let defaultMaxPendingAge: TimeInterval = 1.0
    static let maxPairs: Int = 600
    static let maxPending: Int = 32
    /// `contentOffset` / `ageSkew` 超過此值時立即回報一次（其後共用 30 秒節流）。
    static let contentLagWarnSeconds: Double = 1.0

    let pairingWindow: TimeInterval
    private(set) var videoSamples: UInt64 = 0
    private(set) var audioSamples: UInt64 = 0
    private(set) var paired: UInt64 = 0
    private(set) var unpairedVideo: UInt64 = 0
    private(set) var unpairedAudio: UInt64 = 0
    private(set) var videoCaptureTimeSamples: UInt64 = 0
    private(set) var lastHandedOffset: Double?
    private(set) var lastContentOffset: Double?
    private(set) var lastVideoAge: Double?
    private(set) var lastAudioAge: Double?
    private(set) var lastAgeSkew: Double?

    private struct Sample {
        let handedPTS: Double
        let capturePTS: Double?
        let arrival: Double
    }

    private struct Pair {
        let time: Double
        let handedOffset: Double
        let contentOffset: Double
        let videoAge: Double
        let audioAge: Double
        let ageSkew: Double
    }

    private var videoPending: [Sample] = []
    private var audioPending: [Sample] = []
    private var pairs: [Pair] = []
    private var lastReport: Double?
    private var lastLagReport: Double?

    init(pairingWindow: TimeInterval = AVContentSyncAudit.defaultPairingWindow) {
        self.pairingWindow = pairingWindow.isFinite ? max(0, pairingWindow) : Self.defaultPairingWindow
    }

    /// 觀測一筆入口樣本。
    /// - Parameters:
    ///   - kind: 影片或音訊。
    ///   - handedPTS: 實際交給 mixer 的 PTS（秒）。
    ///   - capturePTS: 加工前來源時間；只有影片的 `VideoFrameTrace.sourcePTS` 會提供。
    ///   - arrival: 同一程序的單調到達時間（秒）。
    /// - Returns: 需要輸出日誌時的摘要；其餘回傳 nil。
    mutating func observe(kind: Kind, handedPTS: Double, capturePTS: Double?, arrival: Double) -> String? {
        guard handedPTS.isFinite, arrival.isFinite else {
            return nil
        }
        let sample = Sample(
            handedPTS: handedPTS,
            capturePTS: capturePTS.flatMap { $0.isFinite ? $0 : nil },
            arrival: arrival
        )

        switch kind {
        case .video:
            videoSamples &+= 1
            if sample.capturePTS != nil {
                videoCaptureTimeSamples &+= 1
            }
            expireVideo(now: arrival)
            if let index = bestAudioIndex(for: arrival) {
                record(video: sample, audio: audioPending.remove(at: index))
            } else {
                appendVideo(sample)
            }
        case .audio:
            audioSamples &+= 1
            expireAudio(now: arrival)
            if let index = bestVideoIndex(for: arrival) {
                record(video: videoPending.remove(at: index), audio: sample)
            } else {
                appendAudio(sample)
            }
        }

        guard paired > 0 else {
            return nil
        }
        if let lastPair = pairs.last, abs(lastPair.contentOffset) >= Self.contentLagWarnSeconds
            || abs(lastPair.ageSkew) >= Self.contentLagWarnSeconds {
            if lastLagReport == nil || arrival - (lastLagReport ?? arrival) >= 30 {
                lastLagReport = arrival
                lastReport = arrival
                return "event=contentLag " + summary
            }
        }
        if lastReport == nil || arrival - (lastReport ?? arrival) >= 30 {
            lastReport = arrival
            return summary
        }
        return nil
    }

    var handedOffsetStats: Stats? { stats(\.handedOffset) }
    var contentOffsetStats: Stats? { stats(\.contentOffset) }
    var videoAgeStats: Stats? { stats(\.videoAge) }
    var audioAgeStats: Stats? { stats(\.audioAge) }
    var ageSkewStats: Stats? { stats(\.ageSkew) }

    var summary: String {
        "paired=\(paired) videoSamples=\(videoSamples) audioSamples=\(audioSamples) unpairedVideo=\(unpairedVideo) unpairedAudio=\(unpairedAudio) pairingWindow=\(String(format: "%.4f", pairingWindow)) captureTime=\(videoCaptureTimeSamples > 0 ? "sourcePTS" : "missing") handedOffset{\(handedOffsetStats?.description ?? "unknown")} contentOffset{\(contentOffsetStats?.description ?? "unknown")} videoAge{\(videoAgeStats?.description ?? "unknown")} audioAge{\(audioAgeStats?.description ?? "unknown")} ageSkew{\(ageSkewStats?.description ?? "unknown")} action=observeOnly timestampChanged=none clockComparison=unverified"
    }

    private func stats(_ keyPath: KeyPath<Pair, Double>) -> Stats? {
        guard !pairs.isEmpty else {
            return nil
        }
        let values = pairs.map { $0[keyPath: keyPath] }
        let mean = values.reduce(0, +) / Double(values.count)
        var slope: Double?
        if 1 < pairs.count {
            let xs = pairs.map { $0.time - pairs[0].time }
            let meanX = xs.reduce(0, +) / Double(xs.count)
            let numerator = zip(xs, values).reduce(0.0) { $0 + ($1.0 - meanX) * ($1.1 - mean) }
            let denominator = xs.reduce(0.0) { $0 + ($1 - meanX) * ($1 - meanX) }
            if 0 < denominator {
                slope = numerator / denominator * 60
            }
        }
        return Stats(
            count: values.count,
            mean: mean,
            minValue: values.min() ?? mean,
            maxValue: values.max() ?? mean,
            slopePerMinute: slope
        )
    }

    private mutating func record(video: Sample, audio: Sample) {
        let videoCapture = video.capturePTS ?? video.handedPTS
        let audioCapture = audio.capturePTS ?? audio.handedPTS
        let videoAge = video.arrival - videoCapture
        let audioAge = audio.arrival - audioCapture
        let pair = Pair(
            time: (video.arrival + audio.arrival) / 2,
            handedOffset: video.handedPTS - audio.handedPTS,
            contentOffset: videoCapture - audioCapture,
            videoAge: videoAge,
            audioAge: audioAge,
            ageSkew: videoAge - audioAge
        )
        pairs.append(pair)
        if Self.maxPairs < pairs.count {
            pairs.removeFirst(pairs.count - Self.maxPairs)
        }
        paired &+= 1
        lastHandedOffset = pair.handedOffset
        lastContentOffset = pair.contentOffset
        lastVideoAge = pair.videoAge
        lastAudioAge = pair.audioAge
        lastAgeSkew = pair.ageSkew
    }

    private func bestAudioIndex(for arrival: Double) -> Int? {
        bestIndex(in: audioPending, for: arrival)
    }

    private func bestVideoIndex(for arrival: Double) -> Int? {
        bestIndex(in: videoPending, for: arrival)
    }

    /// 選 arrival 最接近、且在 pairingWindow 內的樣本；不取「最新」以免配到不同內容。
    private func bestIndex(in samples: [Sample], for arrival: Double) -> Int? {
        var best: (index: Int, distance: Double)?
        for (index, sample) in samples.enumerated() {
            let distance = abs(sample.arrival - arrival)
            guard distance <= pairingWindow else {
                continue
            }
            if best == nil || distance < (best?.distance ?? .infinity) {
                best = (index, distance)
            }
        }
        return best?.index
    }

    private mutating func appendVideo(_ sample: Sample) {
        videoPending.append(sample)
        if Self.maxPending < videoPending.count {
            unpairedVideo &+= UInt64(videoPending.count - Self.maxPending)
            videoPending.removeFirst(videoPending.count - Self.maxPending)
        }
    }

    private mutating func appendAudio(_ sample: Sample) {
        audioPending.append(sample)
        if Self.maxPending < audioPending.count {
            unpairedAudio &+= UInt64(audioPending.count - Self.maxPending)
            audioPending.removeFirst(audioPending.count - Self.maxPending)
        }
    }

    private mutating func expireVideo(now: Double) {
        while let first = videoPending.first, Self.defaultMaxPendingAge < now - first.arrival {
            videoPending.removeFirst()
            unpairedVideo &+= 1
        }
    }

    private mutating func expireAudio(now: Double) {
        while let first = audioPending.first, Self.defaultMaxPendingAge < now - first.arrival {
            audioPending.removeFirst()
            unpairedAudio &+= 1
        }
    }
}
