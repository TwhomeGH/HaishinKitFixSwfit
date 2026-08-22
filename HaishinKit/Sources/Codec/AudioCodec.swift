import AVFoundation

/// The AudioCodec translate audio data to another format.
/// - seealso: https://developer.apple.com/library/ios/technotes/tn2236/_index.html
final class AudioCodec {
    static let defaultFrameCapacity: UInt32 = 1024
    static let defaultInputBuffersCursor = 0

    // 專用 serial queue：所有 AudioCodec 處理（AAC 轉碼、converter 建立、
    // settings 套用、start/stop 重置）都排到這裡，呼叫端（RTMPStream actor /
    // IncomingStream）的 append 立即返回 — AAC 編碼不再與 video 爭搶 actor，
    // 消除「audio 延遲送達 → 落後 video」的 A/V 不同步來源。
    //
    // 刻意不用 `queue.sync` 做等待/排水：sync 是 blocking（Apple 官方文件明示
    // sync 會阻塞呼叫執行緒、main queue 上 sync 會 deadlock、blocking 會造成
    // thread 耗盡）。跨 run 的殘留 block 改由「enqueue 時 capture continuation」
    // +「stop 時以 async finish 排到 queue 尾巴」處理，全程非阻塞。
    private let queue = DispatchQueue(label: "com.haishinkit.HaishinKit.AudioCodec", qos: .userInitiated)
    // settings / isRunning 會被外部 actor 與 queue 同時讀寫，用 lock 保護；
    // 內部處理一律以 capture 的 newSettings / continuation 進行，只在 queue 上
    // 碰 converter 狀態（單執行緒 by construction）。
    private let lock = NSLock()
    private var _settings = AudioCodecSettings.default
    /// Specifies the audio compression properties.
    var settings: AudioCodecSettings {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _settings
        }
        set {
            lock.lock()
            let previous = _settings
            _settings = newValue
            lock.unlock()
            queue.async { [weak self] in
                self?.applySettings(newValue, previous: previous)
            }
        }
    }

    /// The output format of the converter. Queue-serialized so callers (and
    /// tests) observe a consistent value after pending appends have processed.
    /// This is the documented legitimate use of `sync` (read a computed result);
    /// it is only called off-queue. Internal code must read
    /// `audioConverter?.outputFormat` directly (never this property) to avoid a
    /// `queue.sync` deadlock from inside the queue.
    var outputFormat: AVAudioFormat? {
        queue.sync {
            audioConverter?.outputFormat
        }
    }

    var outputStream = AsyncStream<(AVAudioBuffer, AVAudioTime)> { _ in }
    // outputContinuation 只在呼叫端執行緒（actor）被 start/stop/append 讀寫，
    // queue 上永遠用 append 當下 capture 的 continuation，不直接讀此屬性。
    private var outputContinuation: AsyncStream<(AVAudioBuffer, AVAudioTime)>.Continuation?

    /// This instance is running to process(true) or not(false).
    private var _isRunning = false
    private(set) var isRunning: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _isRunning
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _isRunning = newValue
        }
    }
    private(set) var inputFormat: AVAudioFormat? {
        didSet {
            guard inputFormat != oldValue else {
                return
            }
            inputBuffers.removeAll()
            inputBuffersCursor = Self.defaultInputBuffersCursor
            outputBuffers.removeAll()
            audioConverter = makeAudioConverter()
            for _ in 0..<settings.format.inputBufferCounts {
                if let inputBuffer = makeInputBuffer() {
                    inputBuffers.append(inputBuffer)
                }
            }
        }
    }
    private var audioTime = AudioTime()
    private var ringBuffer: AudioRingBuffer?
    private var inputBuffers: [AVAudioBuffer] = []
    private var outputBuffers: [AVAudioBuffer] = []
    private var audioConverter: AVAudioConverter?
    private var inputBuffersCursor = AudioCodec.defaultInputBuffersCursor

    /// Applies a settings change on the dedicated queue. Converter state is only
    /// ever mutated here / inside `process` — single-threaded by construction.
    private func applySettings(_ newSettings: AudioCodecSettings, previous: AudioCodecSettings) {
        if newSettings.invalidateConverter(previous) {
            inputFormat = nil
        } else {
            newSettings.apply(audioConverter, oldValue: previous)
        }
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        // capture 當下 continuation：跨 stop→start 的殘留 block 只會把資料
        // yield 給舊（已 finish / 無 consumer）的 continuation，不會污染新 run。
        let continuation = outputContinuation
        queue.async { [weak self] in
            self?.process(sampleBuffer, continuation: continuation)
        }
    }

    private func process(_ sampleBuffer: CMSampleBuffer, continuation: AsyncStream<(AVAudioBuffer, AVAudioTime)>.Continuation?) {
        guard isRunning else {
            logger.debug("AudioCodec.append(CMSampleBuffer) dropped: encoder not running")
            return
        }
        switch settings.format {
        case .pcm:
            if let formatDescription = sampleBuffer.formatDescription, inputFormat?.formatDescription != formatDescription {
                inputFormat = AVAudioFormat(cmAudioFormatDescription: formatDescription)
            }
            var offset = 0
            var presentationTimeStamp = sampleBuffer.presentationTimeStamp
            for i in 0..<sampleBuffer.numSamples {
                guard let buffer = makeInputBuffer() as? AVAudioCompressedBuffer else {
                    continue
                }
                let sampleSize = CMSampleBufferGetSampleSize(sampleBuffer, at: i)
                let byteCount = sampleSize - ADTSHeader.size
                buffer.packetDescriptions?.pointee = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(byteCount))
                buffer.packetCount = 1
                buffer.byteLength = UInt32(byteCount)
                if let blockBuffer = sampleBuffer.dataBuffer {
                    CMBlockBufferCopyDataBytes(blockBuffer, atOffset: offset + ADTSHeader.size, dataLength: byteCount, destination: buffer.data)
                    process(buffer, when: presentationTimeStamp.makeAudioTime(), continuation: continuation)
                    presentationTimeStamp = CMTimeAdd(presentationTimeStamp, CMTime(value: CMTimeValue(1024), timescale: sampleBuffer.presentationTimeStamp.timescale))
                    offset += sampleSize
                }
            }
        default:
            // 編碼模式收到 CMSampleBuffer：編碼路徑預期 AVAudioPCMBuffer
            // （append(_:when:)），此輸入格式不符 — 不靜默丟棄，留下可視痕跡。
            logger.warn("AudioCodec.append(CMSampleBuffer) ignored: format=\(settings.format.audioDescription) expects AVAudioPCMBuffer input")
        }
    }

    func append(_ audioBuffer: AVAudioBuffer, when: AVAudioTime) {
        let continuation = outputContinuation
        queue.async { [weak self] in
            self?.process(audioBuffer, when: when, continuation: continuation)
        }
    }

    private func process(_ audioBuffer: AVAudioBuffer, when: AVAudioTime, continuation: AsyncStream<(AVAudioBuffer, AVAudioTime)>.Continuation?) {
        guard isRunning else {
            logger.debug("AudioCodec.append(AVAudioBuffer) dropped: encoder not running")
            return
        }
        inputFormat = audioBuffer.format
        guard let audioConverter else {
            logger.debug("AudioCodec.append(AVAudioBuffer) dropped: converter=\(audioConverter != nil)")
            return
        }
        var error: NSError?
        if let audioBuffer = audioBuffer as? AVAudioPCMBuffer {
            ringBuffer?.append(audioBuffer, when: when)
            if !audioTime.hasAnchor {
                audioTime.anchor(when.makeTime(), sampleRate: audioConverter.outputFormat.sampleRate)
            }
        }
        var outputStatus: AVAudioConverterOutputStatus = .endOfStream
        // 無界迴圈：動態 inputBlock 下正常每 append 轉一幀就 .noDataNow 結束。
        // 實測 audioFrames 完全跟上 input（43-45/s，44.1k/1024 即時節奏），
        // 不需要 convert 上限。積壓時一次消化全部才能追上延遲，避免丟幀。
        repeat {
            let outputBuffer = self.outputBuffer
            outputStatus = audioConverter.convert(to: outputBuffer, error: &error) { inNumberFrames, inputStatus in
                switch self.inputBuffer {
                case let inputBuffer as AVAudioCompressedBuffer:
                    inputBuffer.copy(audioBuffer)
                    inputStatus.pointee = .haveData
                    return inputBuffer
                case let inputBuffer as AVAudioPCMBuffer:
                    // 只提供「完整幀數」：ring buffer 累積夠 inNumberFrames 才
                    // render，不足回 .noDataNow（資料留待下次 append 累積）。
                    // ⚠️ 不可改為 min(inNumberFrames, 可用) 的部分幀餵入 —
                    // AAC 需要固定 1024 幀才產出一 packet，部分幀會讓
                    // converter 輸出錯位 → 電磁音/爆音。
                    if self.ringBuffer?.isDataAvailable(inNumberFrames) == true {
                        inputBuffer.frameLength = inNumberFrames
                        _ = self.ringBuffer?.render(inNumberFrames, ioData: inputBuffer.mutableAudioBufferList)
                        inputStatus.pointee = .haveData
                        return inputBuffer
                    } else {
                        inputStatus.pointee = .noDataNow
                        return nil
                    }
                default:
                    inputStatus.pointee = .noDataNow
                    return nil
                }
            }
            switch outputStatus {
            case .haveData:
                if audioTime.hasAnchor {
                    audioTime.advanced(AVAudioFramePosition(audioConverter.outputFormat.streamDescription.pointee.mFramesPerPacket))
                    continuation?.yield((outputBuffer, audioTime.realTimeAt))
                } else {
                    continuation?.yield((outputBuffer, audioTime.realTimeAt))
                }
                inputBuffersCursor += 1
                if inputBuffersCursor == inputBuffers.count {
                    inputBuffersCursor = Self.defaultInputBuffersCursor
                }
            default:
                releaseOutputBuffer(outputBuffer)
            }
        } while(outputStatus == .haveData && settings.format != .pcm)
    }

    private func makeInputBuffer() -> AVAudioBuffer? {
        guard let inputFormat else {
            return nil
        }
        switch inputFormat.formatDescription.mediaSubType {
        case .linearPCM:
            let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: Self.defaultFrameCapacity)
            buffer?.frameLength = Self.defaultFrameCapacity
            return buffer
        default:
            return AVAudioCompressedBuffer(format: inputFormat, packetCapacity: 1, maximumPacketSize: 1024)
        }
    }

    private func makeAudioConverter() -> AVAudioConverter? {
        guard
            let inputFormat,
            let outputFormat = settings.format.makeOutputAudioFormat(inputFormat, sampleRate: settings.sampleRate, channelMap: settings.channelMap) else {
            return nil
        }
        let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        settings.apply(converter, oldValue: nil)
        if inputFormat.formatDescription.mediaSubType == .linearPCM {
            ringBuffer = AudioRingBuffer(inputFormat)
        }
        if audioConverter?.outputFormat.sampleRate != outputFormat.sampleRate {
            audioTime.reset()
        }
        if logger.isEnabledFor(level: .info) {
            logger.info("audio: format=\(settings.format.audioDescription) input=\(inputFormat) output=\(outputFormat)")
        }
        return converter
    }
}

extension AudioCodec: Codec {
    // MARK: Codec
    typealias Buffer = AVAudioBuffer

    var outputBuffer: AVAudioBuffer {
        guard let outputFormat = audioConverter?.outputFormat else {
            return .init()
        }
        if outputBuffers.isEmpty {
            for _ in 0..<settings.format.outputBufferCounts {
                outputBuffers.append(settings.format.makeAudioBuffer(outputFormat) ?? .init())
            }
        }
        return outputBuffers.removeFirst()
    }

    func releaseOutputBuffer(_ buffer: AVAudioBuffer) {
        outputBuffers.append(buffer)
    }

    private var inputBuffer: AVAudioBuffer {
        return inputBuffers[inputBuffersCursor]
    }
}

extension AudioCodec: Runner {
    // MARK: Running
    func startRunning() {
        guard !isRunning else {
            return
        }
        // Stream 必須同步建立：consumer 在 startRunning 後立刻讀 outputStream。
        let (stream, continuation) = AsyncStream.makeStream(of: (AVAudioBuffer, AVAudioTime).self)
        outputStream = stream
        outputContinuation = continuation
        isRunning = true
        queue.async { [weak self] in
            guard let self else {
                return
            }
            audioTime.reset()
            ringBuffer?.reset()
            audioConverter?.reset()
        }
    }

    func stopRunning() {
        guard isRunning else {
            return
        }
        isRunning = false
        // 舊 continuation 以 async 排到 queue 尾巴 finish：它在所有 pending
        // process block 之後執行（那些 block 看到 isRunning=false 會跳過），
        // 等同排水效果，但全程非阻塞、無 sync 死鎖風險。
        let old = outputContinuation
        outputContinuation = nil
        queue.async { [old] in
            old?.finish()
        }
    }
}
