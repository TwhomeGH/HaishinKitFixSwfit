import AVFoundation
import Foundation
import Testing

@testable import HaishinKit

@Suite("AudioMixerByMultiTrack：多軌混音") struct AudioMixerByMultiTrackTests {
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

    func waitUntil(_ predicate: @escaping () -> Bool) async throws {
        for _ in 0..<50 {
            if predicate() {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @Test("維持 44100Hz 輸出") func keep44100() async throws {
        let result = Result()
        let mixer = AudioMixerByMultiTrack()
        mixer.delegate = result
        mixer.settings = .init(
            sampleRate: 44100, channels: 1
        )
        mixer.append(0, buffer: CMAudioSampleBufferFactory.makeSinWave(48000, numSamples: 1024, channels: 1)!)
        mixer.append(0, buffer: CMAudioSampleBufferFactory.makeSinWave(48000, numSamples: 1024, channels: 1)!)
        try await waitUntil { mixer.outputFormat?.sampleRate == 44100 }
        #expect(mixer.outputFormat?.sampleRate == 44100)
        mixer.append(0, buffer: CMAudioSampleBufferFactory.makeSinWave(44100, numSamples: 1024, channels: 1)!)
        try await waitUntil { !result.outputs.isEmpty }
        #expect(mixer.outputFormat?.sampleRate == 44100)
        #expect(!result.outputs.isEmpty)
    }

    @Test("44100 切換至 48000Hz") func test44100to48000() async throws {
        let mixer = AudioMixerByMultiTrack()
        mixer.settings = .init(
            sampleRate: 44100, channels: 1
        )
        mixer.append(0, buffer: CMAudioSampleBufferFactory.makeSinWave(48000, numSamples: 1024, channels: 1)!)
        try await waitUntil { mixer.outputFormat?.sampleRate == 44100 }
        #expect(mixer.outputFormat?.sampleRate == 44100)
        mixer.settings = .init(
            sampleRate: 48000, channels: 1
        )
        mixer.append(0, buffer: CMAudioSampleBufferFactory.makeSinWave(44100, numSamples: 1024, channels: 1)!)
        try await waitUntil { mixer.outputFormat?.sampleRate == 48000 }
        #expect(mixer.outputFormat?.sampleRate == 48000)
    }

    @Test("48000Hz 雙聲道輸出") func test48000_2ch() async throws {
        let result = Result()
        let mixer = AudioMixerByMultiTrack()
        mixer.delegate = result
        mixer.settings = .init(
            sampleRate: 48000, channels: 2
        )
        mixer.append(1, buffer: CMAudioSampleBufferFactory.makeSinWave(48000, numSamples: 1024, channels: 2)!)
        mixer.append(0, buffer: CMAudioSampleBufferFactory.makeSinWave(48000, numSamples: 1024, channels: 2)!)
        try await waitUntil { mixer.outputFormat?.channelCount == 2 && mixer.outputFormat?.sampleRate == 48000 }
        #expect(mixer.outputFormat?.channelCount == 2)
        #expect(mixer.outputFormat?.sampleRate == 48000)
        mixer.append(1, buffer: CMAudioSampleBufferFactory.makeSinWave(48000, numSamples: 1024, channels: 2)!)
        mixer.append(0, buffer: CMAudioSampleBufferFactory.makeSinWave(48000, numSamples: 1024, channels: 2)!)
        // #expect(result.outputs.count == 2)
        // #expect(result.error == nil)
    }

    @Test("各軌輸入格式") func inputFormats() async throws {
        let mixer = AudioMixerByMultiTrack()
        mixer.settings = .init(
            sampleRate: 44100, channels: 1
        )
        mixer.append(0, buffer: CMAudioSampleBufferFactory.makeSinWave(48000, numSamples: 1024, channels: 1)!)
        mixer.append(1, buffer: CMAudioSampleBufferFactory.makeSinWave(44100, numSamples: 1024, channels: 1)!)
        try await waitUntil {
            mixer.inputFormats[0]?.sampleRate == 48000 && mixer.inputFormats[1]?.sampleRate == 44100
        }
        let inputFormats = mixer.inputFormats
        #expect(inputFormats[0]?.sampleRate == 48000)
        #expect(inputFormats[1]?.sampleRate == 44100)
    }

    @Test("音訊節點就緒後啟動路由觀察") func startsRouteObserverWhenAudioNodesAreReady() async throws {
        let observer = AudioEchoRouteObserverSpy()
        let mixer = AudioMixerByMultiTrack(routeObserver: observer)
        mixer.settings = .init(
            sampleRate: 44100, channels: 1
        )
        mixer.append(0, buffer: CMAudioSampleBufferFactory.makeSinWave(44100, numSamples: 1024, channels: 1)!)

        try await waitUntil { observer.isStarted }
        #expect(observer.isStarted)
    }
}
