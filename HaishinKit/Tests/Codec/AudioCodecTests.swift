import AVFoundation
import Foundation
import Testing

@testable import HaishinKit

@Suite("AudioCodec：AAC 編碼輸出格式") struct AudioCodecTests {
    @Test("AAC 44100Hz：步長 1024") func aac_44100hz_step_1024() {
        let encoder = HaishinKit.AudioCodec()
        encoder.startRunning()
        for _ in 0..<10 {
            if let sampleBuffer = AVAudioPCMBufferFactory.makeSinWave(44100, numSamples: 1024) {
                encoder.append(sampleBuffer, when: .init())
            }
        }
        #expect(encoder.outputFormat?.sampleRate == 44100)
    }

    @Test("AAC 48000Hz：步長 1024") func aac_48000hz_step_1024() {
        let encoder = HaishinKit.AudioCodec()
        encoder.startRunning()
        for _ in 0..<10 {
            if let sampleBuffer = AVAudioPCMBufferFactory.makeSinWave(48000.0, numSamples: 1024) {
                encoder.append(sampleBuffer, when: .init())
            }
        }
        #expect(encoder.outputFormat?.sampleRate == 48000)
    }

    @Test("AAC 24000Hz：步長 1024") func aac_24000hz_step_1024() {
        let encoder = HaishinKit.AudioCodec()
        encoder.startRunning()
        for _ in 0..<10 {
            if let sampleBuffer = AVAudioPCMBufferFactory.makeSinWave(24000.0, numSamples: 1024) {
                encoder.append(sampleBuffer, when: .init())
            }
        }
        #expect(encoder.outputFormat?.sampleRate == 24000)
    }

    @Test("AAC 16000Hz：步長 1024") func aac_16000hz_step_1024() {
        let encoder = HaishinKit.AudioCodec()
        encoder.startRunning()
        for _ in 0..<10 {
            if let sampleBuffer = AVAudioPCMBufferFactory.makeSinWave(16000.0, numSamples: 1024) {
                encoder.append(sampleBuffer, when: .init())
            }
        }
        #expect(encoder.outputFormat?.sampleRate == 16000)
    }

    @Test("AAC 8000Hz：步長 256") func aac_8000hz_step_256() {
        let encoder = HaishinKit.AudioCodec()
        encoder.startRunning()
        for _ in 0..<10 {
            if let sampleBuffer = AVAudioPCMBufferFactory.makeSinWave(8000.0, numSamples: 256) {
                encoder.append(sampleBuffer, when: .init())
            }
        }
        #expect(encoder.outputFormat?.sampleRate == 8000)
    }

    @Test("AAC 8000Hz：步長 960") func aac_8000hz_step_960() {
        let encoder = HaishinKit.AudioCodec()
        encoder.startRunning()
        for _ in 0..<10 {
            if let sampleBuffer = AVAudioPCMBufferFactory.makeSinWave(8000.0, numSamples: 960) {
                encoder.append(sampleBuffer, when: .init())
            }
        }
        #expect(encoder.outputFormat?.sampleRate == 8000)
    }

    @Test("AAC 44100Hz：步長 1224") func aac_44100hz_step_1224() {
        let encoder = HaishinKit.AudioCodec()
        encoder.startRunning()
        for _ in 0..<10 {
            if let sampleBuffer = AVAudioPCMBufferFactory.makeSinWave(44100.0, numSamples: 1224) {
                encoder.append(sampleBuffer, when: .init())
            }
        }
    }

    @Test("AAC：單聲道轉雙聲道") func aac_1_channel_to_2_channel() {
        let encoder = HaishinKit.AudioCodec()
        encoder.settings = .init(downmix: false, channelMap: [0, 0])
        encoder.startRunning()
        for _ in 0..<10 {
            if let sampleBuffer = AVAudioPCMBufferFactory.makeSinWave(44100.0, numSamples: 1024) {
                encoder.append(sampleBuffer, when: .init())
            }
        }
        #expect(encoder.outputFormat?.channelCount == 2)
    }

    @Test("AAC 44100Hz：不規則步長") func aac_44100_any_steps() {
        let numSamples: [Int] = [1024, 1024, 1028, 1024, 1028, 1028, 962, 962, 960, 2237, 2236]
        let encoder = HaishinKit.AudioCodec()
        encoder.startRunning()
        for numSample in numSamples {
            if let sampleBuffer = AVAudioPCMBufferFactory.makeSinWave(44100.0, numSamples: numSample) {
                encoder.append(sampleBuffer, when: .init())
            }
        }
        #expect(encoder.outputFormat?.sampleRate == 44100)
    }

    @Test("AAC：三聲道不崩潰") func test3Channel_withoutCrash() {
        let encoder = HaishinKit.AudioCodec()
        encoder.startRunning()
        if let sampleBuffer = CMAudioSampleBufferFactory.makeSilence(44100, numSamples: 256, channels: 3) {
            encoder.append(sampleBuffer)
        }
    }
}
