import AVFoundation
import Foundation

/// An object that provides a stream ingest feature.
///
/// Thread-safety: `append(_:)` / `append(_:when:)` run on the capture / mixer
/// threads while `videoSettings` / `setVideoInputBufferCounts` /
/// `prepareVideoInputStream` run on the stream actor, so all mutable state
/// (buffer counts, observed frame size, input formats, the lazily created video
/// input stream) is guarded by `lock`. `NSRecursiveLock` is required because
/// the lazy `videoInputStream` getter installs the continuation from inside the
/// `AsyncStream` initializer and `videoSettings`' recompute reads state that
/// other locked accessors also read. The same lock serializes access to the
/// (otherwise unsynchronized) `VideoCodec` / `AudioCodec` instances.
package final class OutgoingStream: @unchecked Sendable {
    private let lock = NSRecursiveLock()

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private var _maxVideoBufferBytes = 15 * 1024 * 1024
    /// The maximum total bytes for the video input buffer (uncompressed frames).
    /// Used to compute a frame count that stays within this budget.
    /// Default 15 MB (~5 frames at 1080p, ~10 at 720p).
    package var maxVideoBufferBytes: Int {
        get { withLock { _maxVideoBufferBytes } }
        set { withLock { _maxVideoBufferBytes = newValue } }
    }

    private var _isRunning = false
    package private(set) var isRunning: Bool {
        get { withLock { _isRunning } }
        set { withLock { _isRunning = newValue } }
    }

    /// The asynchronous sequence for audio output.
    package var audioOutputStream: AsyncStream<(AVAudioBuffer, AVAudioTime)> {
        withLock { audioCodec.outputStream }
    }

    /// Specifies the audio compression properties.
    package var audioSettings: AudioCodecSettings {
        get { withLock { audioCodec.settings } }
        set { withLock { audioCodec.settings = newValue } }
    }

    private var _audioInputFormat: CMFormatDescription?
    /// The audio input format.
    package private(set) var audioInputFormat: CMFormatDescription? {
        get { withLock { _audioInputFormat } }
        set { withLock { _audioInputFormat = newValue } }
    }

    /// The asynchronous sequence for video output.
    package var videoOutputStream: AsyncStream<CMSampleBuffer> {
        withLock { videoCodec.outputStream }
    }

    /// Specifies the video compression properties.
    package var videoSettings: VideoCodecSettings {
        get { withLock { videoCodec.settings } }
        set {
            withLock {
                let oldSize = videoCodec.settings.videoSize
                videoCodec.settings = newValue
                // videoSize 變更時重新計算 buffer count（auto mode 下）。注意：
                // AsyncStream 的 bufferingPolicy 在建立時就固定（見 videoInputStream），
                // 因此這裡只影響「下一次」建立 videoInputStream 的計數；mid-stream 改
                // 解析度不會改動已存在 stream 的 buffer。
                if !_videoInputBufferCountsOverridden, videoCodec.settings.videoSize != oldSize {
                    _videoInputBufferCounts = computeVideoInputBufferCountsLocked(for: videoCodec.settings.videoSize)
                }
            }
        }
    }

    private var _videoInputBufferCounts = 1
    /// Specifies the video buffering count. Auto-computed from video resolution
    /// and `maxVideoBufferBytes` unless manually set via `setVideoInputBufferCounts()`.
    /// Every write site already clamps to `>= 1` (`computeVideoInputBufferCounts`
    /// and `setVideoInputBufferCounts`), so no observer clamp is needed here.
    package private(set) var videoInputBufferCounts: Int {
        get { withLock { _videoInputBufferCounts } }
        set { withLock { _videoInputBufferCounts = newValue } }
    }
    private var _videoInputBufferCountsOverridden = false
    /// Returns `true` when the user has explicitly set a custom `videoInputBufferCounts`.
    /// When `false`, the count is auto-computed from `maxVideoBufferBytes` and video resolution.
    package private(set) var videoInputBufferCountsOverridden: Bool {
        get { withLock { _videoInputBufferCountsOverridden } }
        set { withLock { _videoInputBufferCountsOverridden = newValue } }
    }

    /// Overrides the auto-computed buffer count. Call with `nil` to re-enable auto-compute.
    package func setVideoInputBufferCounts(_ count: Int?) {
        withLock {
            if let count {
                _videoInputBufferCounts = max(1, count)
                _videoInputBufferCountsOverridden = true
            } else {
                _videoInputBufferCountsOverridden = false
                // 立即以當前 videoSize 重新計算
                _videoInputBufferCounts = computeVideoInputBufferCountsLocked(for: videoCodec.settings.videoSize)
            }
        }
    }

    /// Prepares the video input stream for use. Auto-computes buffer count
    /// from video resolution unless the user has set a custom value.
    package func prepareVideoInputStream() -> AsyncStream<CMSampleBuffer> {
        withLock {
            if !_videoInputBufferCountsOverridden {
                _videoInputBufferCounts = computeVideoInputBufferCountsLocked(for: videoCodec.settings.videoSize)
            }
            return videoInputStreamLocked()
        }
    }

    /// The asynchronous sequence for video input buffer.
    package var videoInputStream: AsyncStream<CMSampleBuffer> {
        withLock { videoInputStreamLocked() }
    }

    private func videoInputStreamLocked() -> AsyncStream<CMSampleBuffer> {
        if let stream = _videoInputStream {
            return stream
        }
        let counts = _videoInputBufferCounts
        var captured: AsyncStream<CMSampleBuffer>.Continuation?
        let stream = AsyncStream(CMSampleBuffer.self, bufferingPolicy: .bufferingNewest(counts)) { continuation in
            captured = continuation
        }
        _videoInputStream = stream
        _videoInputContinuation = captured
        return stream
    }

    private var _videoInputFormat: CMFormatDescription?
    /// The video input format.
    package private(set) var videoInputFormat: CMFormatDescription? {
        get { withLock { _videoInputFormat } }
        set { withLock { _videoInputFormat = newValue } }
    }
    /// Actual bytes per frame observed from the latest sample buffer's pixel buffer.
    /// More accurate than assuming NV12 (1.5 bytes/pixel) from `videoSize` alone.
    private var _observedVideoBytesPerFrame = 0

    /// Returns the optimal frame count for the given video size.
    /// Prefers the actual observed bytes-per-frame; falls back to NV12 estimate.
    package func computeVideoInputBufferCounts(for size: CGSize) -> Int {
        withLock { computeVideoInputBufferCountsLocked(for: size) }
    }

    private func computeVideoInputBufferCountsLocked(for size: CGSize) -> Int {
        let bytesPerFrame: Int
        if 0 < _observedVideoBytesPerFrame {
            bytesPerFrame = _observedVideoBytesPerFrame
        } else {
            bytesPerFrame = Int(size.width * size.height * 1.5)
        }
        guard bytesPerFrame > 0 else { return 5 }
        return max(1, min(30, _maxVideoBufferBytes / bytesPerFrame))
    }

    private let audioCodec = AudioCodec()
    private let videoCodec = VideoCodec()
    private var _videoInputStream: AsyncStream<CMSampleBuffer>?

    package func setVideoCodecLogHandler(_ handler: @Sendable @escaping (String) -> Void) {
        withLock { videoCodec.onLog = handler }
    }
    private var _videoInputContinuation: AsyncStream<CMSampleBuffer>.Continuation? {
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
            withLock { _audioInputFormat = sampleBuffer.formatDescription }
            audioCodec.append(sampleBuffer)
        case .video:
            withLock {
                _videoInputFormat = sampleBuffer.formatDescription
                if let imageBuffer = sampleBuffer.imageBuffer {
                    _observedVideoBytesPerFrame = CVPixelBufferGetDataSize(imageBuffer)
                }
            }
            // Yield outside the lock: AsyncStream's yield is non-blocking but we
            // don't want to hold the lock across the consumer's wakeup.
            withLock { _videoInputContinuation }?.yield(sampleBuffer)
        default:
            break
        }
    }

    /// Appends a sample buffer for publish.
    package func append(_ audioBuffer: AVAudioBuffer, when: AVAudioTime) {
        withLock { _audioInputFormat = audioBuffer.format.formatDescription }
        audioCodec.append(audioBuffer, when: when)
    }

    /// Appends a video buffer.
    package func append(video sampleBuffer: CMSampleBuffer) {
        withLock { videoCodec.append(sampleBuffer) }
    }

    package func restartVideoCodec() {
        withLock {
            guard _isRunning else { return }
            videoCodec.stopRunning()
            videoCodec.startRunning()
        }
    }

    package func restartAudioCodec() {
        withLock {
            guard _isRunning else { return }
            audioCodec.stopRunning()
            audioCodec.startRunning()
        }
    }
}

extension OutgoingStream: Runner {
    // MARK: Runner
    package func startRunning() {
        withLock {
            guard !_isRunning else { return }
            videoCodec.startRunning()
            audioCodec.startRunning()
            _isRunning = true
        }
    }

    package func stopRunning() {
        withLock {
            guard _isRunning else { return }
            _isRunning = false
            videoCodec.stopRunning()
            audioCodec.stopRunning()
            _videoInputContinuation = nil
            _videoInputStream = nil
        }
    }
}
