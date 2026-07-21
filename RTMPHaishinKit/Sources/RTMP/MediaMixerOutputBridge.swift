import AVFAudio
import CoreMedia
import Foundation

final class MediaMixerOutputBridge: @unchecked Sendable {
    private var audioContinuation: AsyncStream<(AVAudioPCMBuffer, AVAudioTime)>.Continuation?
    private var videoContinuation: AsyncStream<CMSampleBuffer>.Continuation?

    func setAudioContinuation(_ c: AsyncStream<(AVAudioPCMBuffer, AVAudioTime)>.Continuation?) {
        audioContinuation = c
    }

    func setVideoContinuation(_ c: AsyncStream<CMSampleBuffer>.Continuation?) {
        videoContinuation = c
    }

    func yieldVideo(_ sampleBuffer: CMSampleBuffer) {
        videoContinuation?.yield(sampleBuffer)
    }

    func yieldAudio(_ buffer: AVAudioPCMBuffer, when: AVAudioTime) {
        audioContinuation?.yield((buffer, when))
    }

    func finish() {
        audioContinuation?.finish()
        audioContinuation = nil
        videoContinuation?.finish()
        videoContinuation = nil
    }
}
