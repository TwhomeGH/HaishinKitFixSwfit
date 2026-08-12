import Accelerate
import AVFoundation

private let kAudioMixerTrack_frameCapacity: AVAudioFrameCount = 1024

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
                if inNumberFrames <= ringBuffer.counts {
                    _ = ringBuffer.render(inNumberFrames, ioData: inputBuffer.mutableAudioBufferList)
                    inputBuffer.frameLength = inNumberFrames
                    status.pointee = .haveData
                    return inputBuffer
                } else {
                    status.pointee = .noDataNow
                    return nil
                }
            }
            switch status {
            case .haveData:
                delegate?.track(self, didOutput: outputBuffer.muted(settings.isMuted), when: audioTime.at)
                audioTime.advanced(1024)
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
