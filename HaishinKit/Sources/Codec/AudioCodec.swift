import AVFoundation

/// The AudioCodec translate audio data to another format.
/// - seealso: https://developer.apple.com/library/ios/technotes/tn2236/_index.html
final class AudioCodec {
    static let defaultFrameCapacity: UInt32 = 1024
    static let defaultInputBuffersCursor = 0

    var settings: AudioCodecSettings = .default {
        didSet {
            if settings.invalidateConverter(oldValue) {
                inputFormat = nil
            } else {
                settings.apply(audioConverter, oldValue: oldValue)
            }
        }
    }

    var outputFormat: AVAudioFormat? {
        return audioConverter?.outputFormat
    }

    var outputStream = AsyncStream<(AVAudioBuffer, AVAudioTime)> { _ in }
    private var outputContinuation: AsyncStream<(AVAudioBuffer, AVAudioTime)>.Continuation?

    /// This instance is running to process(true) or not(false).
    private(set) var isRunning = false
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

    func append(_ sampleBuffer: CMSampleBuffer) {
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
                    append(buffer, when: presentationTimeStamp.makeAudioTime())
                    presentationTimeStamp = CMTimeAdd(presentationTimeStamp, CMTime(value: CMTimeValue(1024), timescale: sampleBuffer.presentationTimeStamp.timescale))
                    offset += sampleSize
                }
            }
        default:
            break
        }
    }

    func append(_ audioBuffer: AVAudioBuffer, when: AVAudioTime) {
        inputFormat = audioBuffer.format
        guard let audioConverter, isRunning else {
            logger.debug("AudioCodec.append(AVAudioBuffer) dropped: converter=\(audioConverter != nil) running=\(isRunning)")
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
                    // 動態提供 ring buffer 現有全部幀數（min(請求, 可用)），
                    // 而非「不足請求量就 .noDataNow」。inputBlock 允許回傳
                    // 少於請求的幀數，converter 會消費後視需要再請求 — 
                    // outputBuffer.frameCapacity 不需對齊上游幀大小。
                    let available = self.ringBuffer?.counts ?? 0
                    guard available > 0 else {
                        inputStatus.pointee = .noDataNow
                        return nil
                    }
                    let frames = min(Int(inNumberFrames), available)
                    inputBuffer.frameLength = AVAudioFrameCount(frames)
                    _ = self.ringBuffer?.render(AVAudioFrameCount(frames), ioData: inputBuffer.mutableAudioBufferList)
                    inputStatus.pointee = .haveData
                    return inputBuffer
                default:
                    inputStatus.pointee = .noDataNow
                    return nil
                }
            }
            switch outputStatus {
            case .haveData:
                if audioTime.hasAnchor {
                    audioTime.advanced(AVAudioFramePosition(audioConverter.outputFormat.streamDescription.pointee.mFramesPerPacket))
                    outputContinuation?.yield((outputBuffer, audioTime.at))
                } else {
                    outputContinuation?.yield((outputBuffer, audioTime.at))
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
        if self.outputFormat?.sampleRate != outputFormat.sampleRate {
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
        let (stream, continuation) = AsyncStream.makeStream(of: (AVAudioBuffer, AVAudioTime).self)
        outputStream = stream
        outputContinuation = continuation
        audioTime.reset()
        ringBuffer?.reset()
        audioConverter?.reset()
        isRunning = true
    }

    func stopRunning() {
        guard isRunning else {
            return
        }
        isRunning = false
        outputContinuation?.finish()
        outputContinuation = nil
    }
}
