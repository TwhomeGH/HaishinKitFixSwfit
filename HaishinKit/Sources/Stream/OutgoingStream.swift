import AVFoundation
import Foundation

/// An object that provides a stream ingest feature.
package final class OutgoingStream: @unchecked Sendable {
    /// The maximum total bytes for the video input buffer (uncompressed frames).
    /// Used to compute a frame count that stays within this budget.
    /// Default 15 MB (~5 frames at 1080p, ~10 at 720p).
    package var maxVideoBufferBytes = 15 * 1024 * 1024

    package private(set) var isRunning = false

    /// The asynchronous sequence for audio output.
    package var audioOutputStream: AsyncStream<(AVAudioBuffer, AVAudioTime)> {
        return audioCodec.outputStream
    }

    /// Specifies the audio compression properties.
    package var audioSettings: AudioCodecSettings {
        get {
            audioCodec.settings
        }
        set {
            audioCodec.settings = newValue
        }
    }

    /// The audio input format.
    package private(set) var audioInputFormat: CMFormatDescription?

    /// The asynchronous sequence for video output.
    package var videoOutputStream: AsyncStream<CMSampleBuffer> {
        return videoCodec.outputStream
    }

    /// Specifies the video compression properties.
    package var videoSettings: VideoCodecSettings {
        get {
            videoCodec.settings
        }
        set {
            let oldSize = videoCodec.settings.videoSize
            videoCodec.settings = newValue
            // videoSize 變更時自動重新計算 buffer count（auto mode 下）
            if !videoInputBufferCountsOverridden, videoCodec.settings.videoSize != oldSize {
                videoInputBufferCounts = computeVideoInputBufferCounts(for: videoCodec.settings.videoSize)
            }
        }
    }

    /// Specifies the video buffering count. Auto-computed from video resolution
    /// and `maxVideoBufferBytes` unless manually set via `setVideoInputBufferCounts()`.
    package private(set) var videoInputBufferCounts = 1 {
        didSet {
            videoInputBufferCounts = max(1, videoInputBufferCounts)
        }
    }
    /// Returns `true` when the user has explicitly set a custom `videoInputBufferCounts`.
    /// When `false`, the count is auto-computed from `maxVideoBufferBytes` and video resolution.
    package private(set) var videoInputBufferCountsOverridden = false

    /// Overrides the auto-computed buffer count. Call with `nil` to re-enable auto-compute.
    package func setVideoInputBufferCounts(_ count: Int?) {
        if let count {
            videoInputBufferCounts = max(1, count)
            videoInputBufferCountsOverridden = true
        } else {
            videoInputBufferCountsOverridden = false
            // 立即以當前 videoSize 重新計算
            videoInputBufferCounts = computeVideoInputBufferCounts(for: videoCodec.settings.videoSize)
        }
    }

    /// Prepares the video input stream for use. Auto-computes buffer count
    /// from video resolution unless the user has set a custom value.
    package func prepareVideoInputStream() -> AsyncStream<CMSampleBuffer> {
        if !videoInputBufferCountsOverridden {
            videoInputBufferCounts = computeVideoInputBufferCounts(for: videoCodec.settings.videoSize)
        }
        return videoInputStream
    }

    /// The asynchronous sequence for video input buffer.
    package var videoInputStream: AsyncStream<CMSampleBuffer> {
        if let stream = _videoInputStream {
            return stream
        }
        let stream = AsyncStream(CMSampleBuffer.self, bufferingPolicy: .bufferingNewest(videoInputBufferCounts)) { continuation in
            self.videoInputContinuation = continuation
        }
        _videoInputStream = stream
        return stream
    }

    /// The video input format.
    package private(set) var videoInputFormat: CMFormatDescription?

    /// Returns the optimal frame count for the given video size.
    package func computeVideoInputBufferCounts(for size: CGSize) -> Int {
        let bytesPerFrame = Int(size.width * size.height * 1.5)
        guard bytesPerFrame > 0 else { return 5 }
        return max(1, min(30, maxVideoBufferBytes / bytesPerFrame))
    }

    private var audioCodec = AudioCodec()
    private var videoCodec = VideoCodec()
    private var _videoInputStream: AsyncStream<CMSampleBuffer>?
    private var videoInputContinuation: AsyncStream<CMSampleBuffer>.Continuation? {
        didSet {
            oldValue?.finish()
        }
    }

    /// Create a new instance.
    package init() {
    }

    /// Appends a sample buffer for publish.
    package func append(_ sampleBuffer: CMSampleBuffer) {
        switch sampleBuffer.formatDescription?.mediaType {
        case .audio:
            audioInputFormat = sampleBuffer.formatDescription
            audioCodec.append(sampleBuffer)
        case .video:
            videoInputFormat = sampleBuffer.formatDescription
            videoInputContinuation?.yield(sampleBuffer)
        default:
            break
        }
    }

    /// Appends a sample buffer for publish.
    package func append(_ audioBuffer: AVAudioBuffer, when: AVAudioTime) {
        audioInputFormat = audioBuffer.format.formatDescription
        audioCodec.append(audioBuffer, when: when)
    }

    /// Appends a video buffer.
    package func append(video sampleBuffer: CMSampleBuffer) {
        videoCodec.append(sampleBuffer)
    }

    package func restartVideoCodec() {
        guard isRunning else {
            return
        }
        videoCodec.stopRunning()
        videoCodec.startRunning()
    }

    package func restartAudioCodec() {
        guard isRunning else {
            return
        }
        audioCodec.stopRunning()
        audioCodec.startRunning()
    }
}

extension OutgoingStream: Runner {
    // MARK: Runner
    package func startRunning() {
        guard !isRunning else {
            return
        }
        videoCodec.startRunning()
        audioCodec.startRunning()
        isRunning = true
    }

    package func stopRunning() {
        guard isRunning else {
            return
        }
        isRunning = false
        videoCodec.stopRunning()
        audioCodec.stopRunning()
        videoInputContinuation = nil
        _videoInputStream = nil
    }
}
