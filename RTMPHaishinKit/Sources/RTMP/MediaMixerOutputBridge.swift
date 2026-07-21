import AVFAudio
import CoreMedia
import Foundation

final class MediaMixerOutputBridge: @unchecked Sendable {
    private let videoQueue = DispatchQueue(label: "com.haishinkit.MediaMixerOutputBridge.video")
    private let audioQueue = DispatchQueue(label: "com.haishinkit.MediaMixerOutputBridge.audio")
    private var audioContinuation: AsyncStream<(AVAudioPCMBuffer, AVAudioTime)>.Continuation?
    private var videoContinuation: AsyncStream<CMSampleBuffer>.Continuation?

    func setAudioContinuation(_ c: AsyncStream<(AVAudioPCMBuffer, AVAudioTime)>.Continuation?) {
        audioContinuation = c
    }

    func setVideoContinuation(_ c: AsyncStream<CMSampleBuffer>.Continuation?) {
        videoContinuation = c
    }

    func yieldVideo(_ sampleBuffer: CMSampleBuffer) {
        videoQueue.async { [weak self] in
            self?.videoContinuation?.yield(sampleBuffer)
        }
    }

    func yieldAudio(_ buffer: AVAudioPCMBuffer, when: AVAudioTime) {
        audioQueue.async { [weak self] in
            self?.audioContinuation?.yield((buffer, when))
        }
    }

    func finish() {
        videoQueue.async { [weak self] in
            self?.videoContinuation?.finish()
            self?.videoContinuation = nil
        }
        audioQueue.async { [weak self] in
            self?.audioContinuation?.finish()
            self?.audioContinuation = nil
        }
    }
}
