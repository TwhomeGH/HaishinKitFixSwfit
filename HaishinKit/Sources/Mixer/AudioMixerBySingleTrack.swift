import AVFoundation
import Foundation

final class AudioMixerBySingleTrack: AudioMixer {
    weak var delegate: (any AudioMixerDelegate)?
    var settings = AudioMixerSettings.default {
        didSet {
            if let trackSettings = settings.tracks[settings.mainTrack] {
                track?.settings = trackSettings
            }
        }
    }
    var inputFormats: [UInt8: AVAudioFormat] {
        var formats: [UInt8: AVAudioFormat] = .init()
        if let track = track, let inputFormat = track.inputFormat {
            formats[track.id] = inputFormat
        }
        return formats
    }
    private(set) var outputFormat: AVAudioFormat? {
        didSet {
            guard let outputFormat, outputFormat != oldValue else {
                return
            }
            let track = AudioMixerTrack<AudioMixerBySingleTrack>(id: settings.mainTrack, outputFormat: outputFormat)
            track.delegate = self
            self.track = track
        }
    }
    private var inSourceFormat: CMFormatDescription? {
        didSet {
            guard inSourceFormat != oldValue else {
                return
            }
            outputFormat = settings.makeOutputFormat(inSourceFormat)
        }
    }
    private var track: AudioMixerTrack<AudioMixerBySingleTrack>?

    func append(_ track: UInt8, buffer: CMSampleBuffer) {
        guard settings.mainTrack == track else {
            return
        }
        inSourceFormat = buffer.formatDescription
        self.track?.append(buffer)
    }

    func append(_ track: UInt8, buffer: AVAudioPCMBuffer, when: AVAudioTime) {
        guard settings.mainTrack == track else {
            return
        }
        inSourceFormat = buffer.format.formatDescription
        self.track?.append(buffer, when: when)
    }
}

extension AudioMixerBySingleTrack: AudioMixerTrackDelegate {
    // MARK: AudioMixerTrackDelegate
    func track(_ track: AudioMixerTrack<AudioMixerBySingleTrack>, didOutput buffer: AVAudioPCMBuffer, when: AVAudioTime) {
        delegate?.audioMixer(self, track: track.id, didInput: buffer, when: when)
        // 輸出 when 改真實時間（hostTime=現在）：消耗軸在系統卡住後會永久落後
        // 真實時間，導致 RTMPStream resync 反覆觸發、audio wire 永久錯位。
        let realTimeWhen = AVAudioTime(hostTime: mach_absolute_time(), sampleTime: when.sampleTime, atRate: when.sampleRate)
        delegate?.audioMixer(self, didOutput: buffer.muted(settings.isMuted), when: realTimeWhen)
    }

    func track(_ rtrack: AudioMixerTrack<AudioMixerBySingleTrack>, errorOccurred error: AudioMixerError) {
        delegate?.audioMixer(self, errorOccurred: error)
    }
}
