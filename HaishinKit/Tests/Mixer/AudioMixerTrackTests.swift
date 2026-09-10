import AVFoundation
import Foundation
import Testing

@testable import HaishinKit

@Suite("AudioMixerTrack：重取樣") final class AudioMixerTrackTests {
    @Test("維持 16000Hz 輸出") func keep16000() {
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
        let track = AudioMixerTrack<AudioMixerTrackTests>(id: 0, outputFormat: format)
        track.delegate = self
        track.append(CMAudioSampleBufferFactory.makeSinWave(48000, numSamples: 1024, channels: 1)!)
        #expect(track.outputFormat.sampleRate == 16000)
        track.append(CMAudioSampleBufferFactory.makeSinWave(44100, numSamples: 1024, channels: 1)!)
        #expect(track.outputFormat.sampleRate == 16000)
    }

    @Test("維持 44100Hz 輸出") func keep44100() {
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 44100, channels: 1, interleaved: true)!
        let resampler = AudioMixerTrack<AudioMixerTrackTests>(id: 0, outputFormat: format)
        resampler.delegate = self
        resampler.append(CMAudioSampleBufferFactory.makeSinWave(48000, numSamples: 1024, channels: 1)!)
        #expect(resampler.outputFormat.sampleRate == 44100)
        resampler.append(CMAudioSampleBufferFactory.makeSinWave(44100, numSamples: 1024, channels: 1)!)
        #expect(resampler.outputFormat.sampleRate == 44100)
        resampler.append(CMAudioSampleBufferFactory.makeSinWave(44100, numSamples: 1024, channels: 1)!)
        #expect(resampler.outputFormat.sampleRate == 44100)
        resampler.append(CMAudioSampleBufferFactory.makeSinWave(16000, numSamples: 1024 * 20, channels: 1)!)
        #expect(resampler.outputFormat.sampleRate == 44100)
    }

    @Test("維持 48000Hz 輸出") func keep48000() {
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48000, channels: 1, interleaved: true)!
        let track = AudioMixerTrack<AudioMixerTrackTests>(id: 0, outputFormat: format)
        track.delegate = self
        track.append(CMAudioSampleBufferFactory.makeSinWave(48000, numSamples: 1024, channels: 1)!)
        track.append(CMAudioSampleBufferFactory.makeSinWave(44100, numSamples: 1024 * 2, channels: 1)!)
    }

    @Test("44000 / 48000Hz 直通") func passthrough48000_44100() {
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 44000, channels: 1, interleaved: true)!
        let resampler = AudioMixerTrack<AudioMixerTrackTests>(id: 0, outputFormat: format)
        resampler.delegate = self
        resampler.append(CMAudioSampleBufferFactory.makeSinWave(44000, numSamples: 1024, channels: 1)!)
        resampler.append(CMAudioSampleBufferFactory.makeSinWave(48000, numSamples: 1024, channels: 1)!)
    }

    @Test("16000 / 44100Hz 直通") func passthrough16000_48000() {
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48000, channels: 1, interleaved: true)!
        let track = AudioMixerTrack<AudioMixerTrackTests>(id: 0, outputFormat: format)
        track.delegate = self
        track.append(CMAudioSampleBufferFactory.makeSinWave(16000, numSamples: 1024, channels: 1)!)
        #expect(track.outputFormat.sampleRate == 48000)
        track.append(CMAudioSampleBufferFactory.makeSinWave(44100, numSamples: 1024, channels: 1)!)
    }
}

extension AudioMixerTrackTests: AudioMixerTrackDelegate {
    func track(_ track: HaishinKit.AudioMixerTrack<AudioMixerTrackTests>, didOutput audioPCMBuffer: AVAudioPCMBuffer, when: AVAudioTime) {
    }

    func track(_ track: HaishinKit.AudioMixerTrack<AudioMixerTrackTests>, errorOccurred error: HaishinKit.AudioMixerError) {
    }
}
