import AVFoundation
import Foundation
import Testing

@testable import HaishinKit

@Suite struct AudioMixerByMultiTrackTests {
    final class AudioEchoRouteObserverSpy: AudioEchoRouteObserving {
        var hasEchoPath: Bool
        private(set) var isStarted = false
        private(set) var isStopped = false
        private var handler: ((Bool) -> Void)?

        init(hasEchoPath: Bool = true) {
            self.hasEchoPath = hasEchoPath
        }

        func start(_ handler: @escaping (Bool) -> Void) {
            isStarted = true
            self.handler = handler
        }

        func stop() {
            isStopped = true
        }

        func update(hasEchoPath: Bool) {
            self.hasEchoPath = hasEchoPath
            handler?(hasEchoPath)
        }
    }

    final class Result: AudioMixerDelegate {
        var outputs: [AVAudioPCMBuffer] = []
        var error: AudioMixerError?

        func audioMixer(_ audioMixer: some AudioMixer, track: UInt8, didInput buffer: AVAudioPCMBuffer, when: AVAudioTime) {
        }

        func audioMixer(_ audioMixer: some AudioMixer, didOutput audioFormat: AVAudioFormat) {
        }

        func audioMixer(_ audioMixer: some AudioMixer, didOutput audioBuffer: AVAudioPCMBuffer, when: AVAudioTime) {
            outputs.append(audioBuffer)
        }

        func audioMixer(_ audioMixer: some AudioMixer, errorOccurred error: AudioMixerError) {
            self.error = error
        }
    }

    @Test func keep44100() {
        let result = Result()
        let mixer = AudioMixerByMultiTrack()
        mixer.delegate = result
        mixer.settings = .init(
            sampleRate: 44100, channels: 1
        )
        mixer.append(0, buffer: CMAudioSampleBufferFactory.makeSinWave(48000, numSamples: 1024, channels: 1)!)
        mixer.append(0, buffer: CMAudioSampleBufferFactory.makeSinWave(48000, numSamples: 1024, channels: 1)!)
        #expect(mixer.outputFormat?.sampleRate == 44100)
        mixer.append(0, buffer: CMAudioSampleBufferFactory.makeSinWave(44100, numSamples: 1024, channels: 1)!)
        #expect(mixer.outputFormat?.sampleRate == 44100)
        #expect(result.outputs.count == 2)
    }

    @Test func test44100to48000() {
        let mixer = AudioMixerByMultiTrack()
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

    @Test func test48000_2ch() {
        let result = Result()
        let mixer = AudioMixerByMultiTrack()
        mixer.delegate = result
        mixer.settings = .init(
            sampleRate: 48000, channels: 2
        )
        mixer.append(1, buffer: CMAudioSampleBufferFactory.makeSinWave(48000, numSamples: 1024, channels: 2)!)
        mixer.append(0, buffer: CMAudioSampleBufferFactory.makeSinWave(48000, numSamples: 1024, channels: 2)!)
        #expect(mixer.outputFormat?.channelCount == 2)
        #expect(mixer.outputFormat?.sampleRate == 48000)
        mixer.append(1, buffer: CMAudioSampleBufferFactory.makeSinWave(48000, numSamples: 1024, channels: 2)!)
        mixer.append(0, buffer: CMAudioSampleBufferFactory.makeSinWave(48000, numSamples: 1024, channels: 2)!)
        // #expect(result.outputs.count == 2)
        // #expect(result.error == nil)
    }

    @Test func inputFormats() {
        let mixer = AudioMixerByMultiTrack()
        mixer.settings = .init(
            sampleRate: 44100, channels: 1
        )
        mixer.append(0, buffer: CMAudioSampleBufferFactory.makeSinWave(48000, numSamples: 1024, channels: 1)!)
        mixer.append(1, buffer: CMAudioSampleBufferFactory.makeSinWave(44100, numSamples: 1024, channels: 1)!)
        let inputFormats = mixer.inputFormats
        #expect(inputFormats[0]?.sampleRate == 48000)
        #expect(inputFormats[1]?.sampleRate == 44100)
    }

    @Test func startsRouteObserverWhenAudioNodesAreReady() async throws {
        let observer = AudioEchoRouteObserverSpy()
        let mixer = AudioMixerByMultiTrack(routeObserver: observer)
        mixer.settings = .init(
            sampleRate: 44100, channels: 1
        )
        mixer.append(0, buffer: CMAudioSampleBufferFactory.makeSinWave(44100, numSamples: 1024, channels: 1)!)

        for _ in 0..<50 where !observer.isStarted {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(observer.isStarted)
    }
}
