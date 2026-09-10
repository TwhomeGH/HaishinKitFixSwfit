import AVFoundation
import Testing

@testable import HaishinKit

@Suite final class AudioStereoDownmixTests {
    private func makeRightOnlyBuffer(_ format: AVAudioFormat, frames: Int, rightValue: Int16) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        let channels = Int(format.channelCount)
        let samples = buffer.int16ChannelData![0]
        for i in 0..<frames {
            samples[i * channels] = 0
            samples[i * channels + 1] = rightValue
        }
        return buffer
    }

    /// stereo(Int16 interleaved) → mono：`downmix = true` 且未設 `channelMap` 時，
    /// 右聲道的能量必須保留（L+R 平均），不能只取左聲道而變無聲。
    ///
    /// 這正是 `AudioMixerTrack` 下混分支的假設。若 Apple 的預設 `channelMap` 會蓋掉
    /// `downmix`，這個測試會失敗 → 代表需要改成顯式設定（channelMap 非 optional，
    /// 不能用 nil 清除）。
    @Test func stereoToMonoKeepsRightChannel() throws {
        let inFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 44100, channels: 2, interleaved: true)!
        let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 44100, channels: 1, interleaved: true)!
        let converter = try #require(AVAudioConverter(from: inFormat, to: outFormat))
        converter.downmix = true
        // 刻意不設 channelMap（與 AudioMixerTrack 的下混分支一致）。

        let input = makeRightOnlyBuffer(inFormat, frames: 1024, rightValue: 16384)
        let output = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: 1024)!
        // convert(to:from:) 是 throwing、回傳 Void；轉換失敗會 throw 讓測試失敗。
        try converter.convert(to: output, from: input)

        let rms = AudioMixerByMultiTrack.channelRMS(output)
        // 右聲道 0.5：只取左聲道 → 0；L+R 平均 → 0.25。
        #expect((rms.first ?? 0) > 0.05)
    }

    /// `channelRMS` 能分辨左右聲道（AHealth 診斷項正確性）。
    @Test func channelRMSDetectsPerChannel() {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 2, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
        buffer.frameLength = 1024
        for i in 0..<1024 {
            buffer.floatChannelData![0][i] = 0.5
            buffer.floatChannelData![1][i] = 0.0
        }
        let rms = AudioMixerByMultiTrack.channelRMS(buffer)
        #expect(rms.count == 2)
        #expect(abs(rms[0] - 0.5) < 0.01)
        #expect(rms[1] < 0.01)
    }
}
