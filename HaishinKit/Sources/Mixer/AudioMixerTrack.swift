import Accelerate
import AVFoundation

// 單次 AVAudioConverter.convert 的輸出幀數。**必須與上游輸入幀數對齊**
// （ReplayKit 每幀 1024 samples）：AVAudioConverter 的輸入 callback 請求
// inNumberFrames == outputBuffer frameCapacity，若調大於輸入幀數，ring buffer
// 每次只有一幀（1024），converter 拿不到足夠輸入 → 回 .noDataNow → resample
// 停擺 → 整條音訊管線無輸出（audioInputFrames=0）。維持 1024。
// internal：OutputNode（AudioNode.swift）的 render buffer 需要同步引用。
let kAudioMixerTrack_frameCapacity: AVAudioFrameCount = 1024

protocol AudioMixerTrackDelegate: AnyObject {
    func track(_ track: AudioMixerTrack<Self>, didOutput audioPCMBuffer: AVAudioPCMBuffer, when: AVAudioTime)
    func track(_ track: AudioMixerTrack<Self>, errorOccurred error: AudioMixerError)
}

final class AudioMixerTrack<T: AudioMixerTrackDelegate> {
    let id: UInt8
    let outputFormat: AVAudioFormat
    weak var delegate: T?
    var settings: AudioMixerTrackSettings = .init() {
        didSet {
            settings.apply(audioConverter, oldValue: oldValue)
        }
    }
    var inputFormat: AVAudioFormat? {
        return audioConverter?.inputFormat
    }
    private var inSourceFormat: CMFormatDescription? {
        didSet {
            guard inSourceFormat != oldValue else {
                return
            }
            setUp(inSourceFormat)
        }
    }
    private var audioTime = AudioTime()
    private var ringBuffer: AudioRingBuffer?
    private var inputBuffer: AVAudioPCMBuffer?
    private var outputBuffer: AVAudioPCMBuffer?
    private var audioConverter: AVAudioConverter? {
        didSet {
            guard let audioConverter else {
                return
            }
            audioConverter.downmix = settings.downmix
            if let channelMap = settings.validatedChannelMap(audioConverter) {
                audioConverter.channelMap = channelMap.map { NSNumber(value: $0) }
            } else {
                switch audioConverter.outputFormat.channelCount {
                case 1:
                    audioConverter.channelMap = [0]
                case 2:
                    audioConverter.channelMap = (audioConverter.inputFormat.channelCount == 1) ? [0, 0] : [0, 1]
                default:
                    break
                }
            }
            audioConverter.primeMethod = .normal
        }
    }

    init(id: UInt8, outputFormat: AVAudioFormat) {
        self.id = id
        self.outputFormat = outputFormat
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        inSourceFormat = sampleBuffer.formatDescription
        if !audioTime.hasAnchor {
            audioTime.anchor(sampleBuffer.presentationTimeStamp, sampleRate: outputFormat.sampleRate)
        }
        ringBuffer?.append(sampleBuffer)
        resample()
    }

    func append(_ audioBuffer: AVAudioPCMBuffer, when: AVAudioTime) {
        inSourceFormat = audioBuffer.format.formatDescription
        if !audioTime.hasAnchor {
            audioTime.anchor(when)
        }
        ringBuffer?.append(audioBuffer, when: when)
        resample()
    }

    @inline(__always)
    private func resample() {
        guard let outputBuffer, let inputBuffer, let ringBuffer else {
            return
        }
        // 限制每次 append 最多轉換 `maxRendersPerAppend` 幀輸出。
        // 原實作 `repeat { convert } while .haveData` 會在 ring buffer 積壓
        // 時一次轉完所有幀 — 同步霸佔呼叫它的 MediaMixer actor，阻塞 video
        // 與其他 audio track 的 append，造成整條管線節奏斷裂（音訊斷續）。
        // 積壓資料留在 ring buffer，由後續 append 逐幀消化，每幀輸出時間戳
        // 照樣推進，只把「一次暴衝」攤平成多次小步，不改變音訊內容。
        let maxRendersPerAppend = 4
        var rendered = 0
        var status: AVAudioConverterOutputStatus? = .endOfStream
        repeat {
            var error: NSError?
            status = audioConverter?.convert(to: outputBuffer, error: &error) { inNumberFrames, status in
                // 動態提供 ring buffer 現有全部幀數（min(請求, 可用)），
                // 而非「不足請求量就 .noDataNow」。AVAudioConverterInputBlock
                // 允許回傳少於請求的幀數（frameLength = 實際幀數），converter
                // 會消費這些幀並視需要再請求 — 因此 outputBuffer.frameCapacity
                // 不需對齊上游單幀大小，任何輸入幀數都能自動消化。
                let available = ringBuffer.counts
                guard available > 0 else {
                    status.pointee = .noDataNow
                    return nil
                }
                let frames = min(Int(inNumberFrames), available)
                _ = ringBuffer.render(AVAudioFrameCount(frames), ioData: inputBuffer.mutableAudioBufferList)
                inputBuffer.frameLength = AVAudioFrameCount(frames)
                status.pointee = .haveData
                return inputBuffer
            }
            switch status {
            case .haveData:
                delegate?.track(self, didOutput: outputBuffer.muted(settings.isMuted), when: audioTime.at)
                // 時間軸依實際輸出幀數推進（而非硬編碼 1024），完全配合
                // 上游送進來的幀大小自動配置。
                audioTime.advanced(AVAudioFramePosition(outputBuffer.frameLength))
                rendered += 1
            case .error:
                if let error {
                    delegate?.track(self, errorOccurred: .failedToConvert(error: error))
                }
            default:
                break
            }
        } while(status == .haveData && rendered < maxRendersPerAppend)
    }

    private func setUp(_ inSourceFormat: CMFormatDescription?) {
        guard let inputFormat = AVAudioUtil.makeAudioFormat(inSourceFormat) else {
            delegate?.track(self, errorOccurred: .failedToCreate(from: inputFormat, to: outputFormat))
            return
        }
        ringBuffer = .init(inputFormat)
        inputBuffer = .init(pcmFormat: inputFormat, frameCapacity: kAudioMixerTrack_frameCapacity * 4)
        outputBuffer = .init(pcmFormat: outputFormat, frameCapacity: kAudioMixerTrack_frameCapacity)
        if logger.isEnabledFor(level: .info) {
            logger.info("inputFormat:", inputFormat, ", outputFormat:", outputFormat)
        }
        audioTime.reset()
        audioConverter = .init(from: inputFormat, to: outputFormat)
    }
}
