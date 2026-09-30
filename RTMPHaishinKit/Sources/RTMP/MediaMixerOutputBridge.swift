import AVFAudio
import CoreMedia
import Foundation
import HaishinKit

/// Direct bridge from MediaMixer callback to pipeline AsyncStream.
/// No DispatchQueue — yields synchronously on the caller's thread.
/// AsyncStream.Continuation.yield() is thread-safe, so this is safe from
/// any actor context. Burst protection is handled by downstream
/// AsyncStream buffering policy (.bufferingNewest).
final class MediaMixerOutputBridge: @unchecked Sendable {
    private let lock = NSLock()
    private weak var sourceMixer: MediaMixer?
    private var videoReceived = 0
    private var pressureDropped = 0
    private var lastVideoPTS: Double = -1

    func recordVideo(_ mixer: MediaMixer, dropped: Bool, pts: Double) {
        lock.lock()
        defer { lock.unlock() }
        sourceMixer = mixer
        videoReceived += 1
        if dropped { pressureDropped += 1 }
        lastVideoPTS = pts
    }

    func snapshot(encoderInput: VideoQueueStageSnapshot, encoder: VideoPipelineEventsSnapshot, output: VideoPipelineEventsSnapshot) -> VideoPipelineSnapshot {
        lock.lock()
        let mixer = sourceMixer
        let received = videoReceived
        let dropped = pressureDropped
        let pts = lastVideoPTS
        lock.unlock()
        return VideoPipelineSnapshot(sampledAt: ProcessInfo.processInfo.systemUptime,
            mixer: mixer?.videoPipelineSnapshot(), encoderInput: encoderInput,
            bridgeReceived: received, pressureDrops: dropped,
            lastPTS: pts.isFinite && pts >= 0 ? pts : nil, encoder: encoder, output: output)
    }

    private var audioContinuation: AsyncStream<(AVAudioPCMBuffer, AVAudioTime)>.Continuation?
    private var videoContinuation: AsyncStream<CMSampleBuffer>.Continuation?

    func setAudioContinuation(_ c: AsyncStream<(AVAudioPCMBuffer, AVAudioTime)>.Continuation?) {
        lock.lock()
        defer { lock.unlock() }
        audioContinuation = c
    }

    func setVideoContinuation(_ c: AsyncStream<CMSampleBuffer>.Continuation?) {
        lock.lock()
        defer { lock.unlock() }
        videoContinuation = c
    }

    func yieldVideo(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }
        videoContinuation?.yield(sampleBuffer)
    }

    func yieldAudio(_ buffer: AVAudioPCMBuffer, when: AVAudioTime) {
        lock.lock()
        defer { lock.unlock() }
        audioContinuation?.yield((buffer, when))
    }

    func finish() {
        lock.lock()
        defer { lock.unlock() }
        videoContinuation?.finish()
        videoContinuation = nil
        audioContinuation?.finish()
        audioContinuation = nil
    }
}
