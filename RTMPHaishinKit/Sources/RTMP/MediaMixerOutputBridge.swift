import AVFAudio
import CoreMedia
import Foundation

/// Direct bridge from MediaMixer callback to pipeline AsyncStream.
/// No DispatchQueue — yields synchronously on the caller's thread.
/// AsyncStream.Continuation.yield() is thread-safe, so this is safe from
/// any actor context. Burst protection is handled by downstream
/// AsyncStream buffering policy (.bufferingNewest).
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
        videoContinuation?.finish()
        videoContinuation = nil
        audioContinuation?.finish()
        audioContinuation = nil
    }
}
