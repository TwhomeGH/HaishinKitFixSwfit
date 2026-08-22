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
            if logger.isEnabledFor(level: .info) {
                // 診斷：印出每軌來源格式（sampleRate/channels），確認 ReplayKit
                // mic/app 各是幾聲道，避免「輸出是 mono」到底是來源 mono 還是
                // 管線誤 downmix 的誤判。
                if let format = AVAudioUtil.makeAudioFormat(inSourceFormat) {
                    logger.info("audio track \(id) source format: \(format.sampleRate)Hz \(format.channelCount)ch interleaved=\(format.isInterleaved)")
                }
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
        // resample 在 AudioMixerByMultiTrack 的專用 serial queue 上執行
        //（方案 C：convert 不再佔用 MediaMixer actor）。無界迴圈只霸佔自己
        // 的 queue，不影響 video/actor；正常情況每 append 轉一幀就 .noDataNow
        // 結束，積壓時一次消化全部才能追上延遲、避免 ring buffer 滿掉幀。
        // 實測 audioInputFrames=audioFrames=43-45/s（44.1k/1024 即時節奏），
        // 完全吃得動，不需要任何渲染上限。
        var status: AVAudioConverterOutputStatus? = .endOfStream
        repeat {
            var error: NSError?
            status = audioConverter?.convert(to: outputBuffer, error: &error) { inNumberFrames, status in
                // 只提供「完整幀數」：ring buffer 累積夠 inNumberFrames 才
                // render，不足回 .noDataNow（資料留待下次 append 累積）。
                // ⚠️ 不可改為 min(inNumberFrames, 可用) 的部分幀餵入 —
                // 會讓 outputBuffer.frameLength 非 1024 對齊，下游
                // AudioMixerByMultiTrack.mix() → AudioUnitRender 用非對齊
                // 幀數拉取 AudioRingBuffer，造成樣本錯位 → 電磁音/爆音。
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
                audioTime.advanced(AVAudioFramePosition(outputBuffer.frameLength))
            case .error:
                if let error {
                    delegate?.track(self, errorOccurred: .failedToConvert(error: error))
                }
            default:
                break
            }
        } while(status == .haveData)
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
