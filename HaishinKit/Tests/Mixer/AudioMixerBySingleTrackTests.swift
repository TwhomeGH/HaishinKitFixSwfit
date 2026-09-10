import AVFoundation
import Foundation
import Testing

@testable import HaishinKit

@Suite("AudioMixerBySingleTrack：單軌混音") struct AudioMixerBySingleTrackTests {
    final class Result: AudioMixerDelegate {
        var outputs: [AVAudioPCMBuffer] = []

        func audioMixer(_ audioMixer: some AudioMixer, track: UInt8, didInput buffer: AVAudioPCMBuffer, when: AVAudioTime) {
        }

        func audioMixer(_ audioMixer: some AudioMixer, didOutput audioFormat: AVAudioFormat) {
        }

        func audioMixer(_ audioMixer: some AudioMixer, didOutput audioBuffer: AVAudioPCMBuffer, when: AVAudioTime) {
            outputs.append(audioBuffer)
        }

        func audioMixer(_ audioMixer: some AudioMixer, errorOccurred error: AudioMixerError) {
        }
    }

    @Test("維持 44100Hz 單聲道") func keep44100_1ch() {
        let mixer = AudioMixerBySingleTrack()
        mixer.settings = .init(
            sampleRate: 44100, channels: 1
        )
        mixer.append(0, buffer: CMAudioSampleBufferFactory.makeSinWave(48000, numSamples: 1024, channels: 1)!)
        #expect(mixer.outputFormat?.sampleRate == 44100)
        mixer.append(0, buffer: CMAudioSampleBufferFactory.makeSinWave(44100, numSamples: 1024, channels: 1)!)
        #expect(mixer.outputFormat?.sampleRate == 44100)
    }

    @Test("44100 切換至 48000Hz 單聲道") func test44100to48000_1ch() {
        let mixer = AudioMixerBySingleTrack()
        mixer.settings = .init(
            sampleRate: 44100, channels: 1
        )
        mixer.append(0, buffer: CMAudioSampleBufferFactory.makeSinWave(48000, numSamples: 1024, channels: 1)!)
        #expect(mixer.outputFormat?.sampleRate == 44100)
        mixer.settings = .init(
            sampleRate: 48000, channels: 1
        )
        mixer.append(0, buffer: CMAudioSampleBufferFactory.makeSinWave(44100, numSamples: 1024, channels: 1)!)
        #expect(mixer.outputFormat?.sampleRate == 48000)
    }

    @Test("44100 至 48000Hz：4 聲道轉 2 聲道") func test44100to48000_4ch_2ch() {
        let result = Result()
        let mixer = AudioMixerBySingleTrack()
        mixer.delegate = result
        mixer.settings = .init(
            sampleRate: 44100, channels: 0
        )
        mixer.append(0, buffer: CMAudioSampleBufferFactory.makeSinWave(48000, numSamples: 1024, channels: 4)!)
        #expect(mixer.outputFormat?.channelCount == 2)
        #expect(mixer.outputFormat?.sampleRate == 44100)
        mixer.settings = .init(
            sampleRate: 48000, channels: 0
        )
        mixer.append(0, buffer: CMAudioSampleBufferFactory.makeSinWave(44100, numSamples: 1024, channels: 4)!)
        mixer.append(0, buffer: CMAudioSampleBufferFactory.makeSinWave(44100, numSamples: 1024, channels: 4)!)
        #expect(mixer.outputFormat?.channelCount == 2)
        #expect(mixer.outputFormat?.sampleRate == 48000)
        #expect(result.outputs.count == 2)
    }

    @Test("44100 至 48000Hz：4 聲道") func test44100to48000_4ch() {
        let result = Result()
        let mixer = AudioMixerBySingleTrack()
        mixer.delegate = result
        mixer.settings = .init(
            sampleRate: 44100, channels: 0
        )
        mixer.settings.maximumNumberOfChannels = 4
        mixer.append(0, buffer: CMAudioSampleBufferFactory.makeSinWave(48000, numSamples: 1024, channels: 4)!)
        #expect(mixer.outputFormat?.channelCount == 4)
        #expect(mixer.outputFormat?.sampleRate == 44100)
        mixer.settings = .init(
            sampleRate: 48000, channels: 0
        )
        mixer.settings.maximumNumberOfChannels = 4
        mixer.append(0, buffer: CMAudioSampleBufferFactory.makeSinWave(44100, numSamples: 1024, channels: 4)!)
        mixer.append(0, buffer: CMAudioSampleBufferFactory.makeSinWave(44100, numSamples: 1024, channels: 4)!)
        #expect(mixer.outputFormat?.channelCount == 4)
        #expect(mixer.outputFormat?.sampleRate == 48000)
        #expect(result.outputs.count == 2)
    }

    @Test("16000 / 44100Hz 直通") func passthrough16000_48000() {
        let mixer = AudioMixerBySingleTrack()
        mixer.settings = .init(
            sampleRate: 0, channels: 1
        )
        mixer.append(0, buffer: CMAudioSampleBufferFactory.makeSinWave(16000, numSamples: 1024, channels: 1)!)
        #expect(mixer.outputFormat?.sampleRate == 16000)
        mixer.append(0, buffer: CMAudioSampleBufferFactory.makeSinWave(44100, numSamples: 1024, channels: 1)!)
        #expect(mixer.outputFormat?.sampleRate == 44100)
    }

    @Test("輸入格式回報") func inputFormats() {
        let mixer = AudioMixerBySingleTrack()
        mixer.settings = .init(
            sampleRate: 44100, channels: 1
        )
        mixer.append(0, buffer: CMAudioSampleBufferFactory.makeSinWave(48000, numSamples: 1024, channels: 1)!)
        let inputFormats = mixer.inputFormats
        #expect(inputFormats[0]?.sampleRate == 48000)
    }
}
