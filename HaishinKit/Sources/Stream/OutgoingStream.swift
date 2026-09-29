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
        set { withLock { _maxVideoBufferBytes = max(0, newValue); updateVideoQueueLimitsLocked() } }
    }

    private var _maxVideoBufferDuration: TimeInterval = 0.1
    package var maxVideoBufferDuration: TimeInterval {
        get { withLock { _maxVideoBufferDuration } }
        set { withLock {
            _maxVideoBufferDuration = newValue.isFinite ? max(0, newValue) : 0.1
            updateVideoQueueLimitsLocked()
        } }
    }

    private var videoQueue: AdaptiveMediaQueue<CMSampleBuffer>?
    private var videoQueueMissingDrops = 0
    private var videoQueueGeneration: UInt64 = 0

    private func updateVideoQueueLimitsLocked() {
        videoQueue?.update(maxBytes: _maxVideoBufferBytes, maxAge: _maxVideoBufferDuration,
                           maxFrames: _videoInputBufferCountsOverridden ? _videoInputBufferCounts : nil)
    }

    package func videoQueueSnapshot() -> VideoQueueStageSnapshot {
        guard lock.try() else { return VideoQueueStageSnapshot(availability: .ownerLockBusy) }
        defer { lock.unlock() }
        return VideoQueueStageSnapshot(availability: videoQueue == nil ? .unavailable : .available,
            generation: videoQueueGeneration, missingDrops: videoQueueMissingDrops,
            queue: videoQueue?.snapshot())
    }

    package func videoQueueDiagnostics() -> String { videoQueueSnapshot().summary() }

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
                // Diagnostic estimate only. The live queue accounts actual bytes per frame.
                if !_videoInputBufferCountsOverridden, videoCodec.settings.videoSize != oldSize {
                    _videoInputBufferCounts = computeVideoInputBufferCountsLocked(for: videoCodec.settings.videoSize)
                }
            }
        }
    }

    private var _videoInputBufferCounts = 1
    /// Specifies the video buffering count. Auto-computed from video resolution
    /// and `maxVideoBufferBytes` unless manually set via `setVideoInputBufferCounts()`.
    /// In auto mode this is an estimate of how many raw frames fit the byte
    /// budget, not the live queue's capacity (RTMP bounds its queue by bytes via
    /// `maxVideoBufferBytes` / `maxVideoBufferDuration`). It is intentionally NOT
    /// clamped: oversized frames estimate to 0, tiny frames estimate high.
    /// Consumers that need a valid buffering capacity must clamp it themselves
    /// (see `SRTStream`).
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
            updateVideoQueueLimitsLocked()
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

    /// 供 RTMP 取得成對的輸入 stream 與世代；兩者必須在同一次鎖內取得，
    /// 避免中途 stop/start 後把舊 stream 誤綁到新編碼器。
    package func prepareVideoInputStreamWithGeneration() -> (AsyncStream<CMSampleBuffer>, UInt64) {
        withLock {
            videoInputGeneration &+= 1
            videoQueue?.finish()
            videoQueue = nil
            _videoInputStream = nil
            return (prepareVideoInputStream(), videoInputGeneration)
        }
    }

    /// 停止 publish 工作時先封住舊輸入，無須等待 Task cancellation 傳播。
    package func invalidateVideoInputGeneration() {
        withLock {
            videoInputGeneration &+= 1
            videoQueue?.finish()
            videoQueue = nil
            _videoInputStream = nil
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
        let queue = AdaptiveMediaQueue<CMSampleBuffer>(
            maxBytes: _maxVideoBufferBytes, maxAge: _maxVideoBufferDuration,
            maxFrames: _videoInputBufferCountsOverridden ? _videoInputBufferCounts : nil
        )
        videoQueueGeneration &+= 1
        videoQueue = queue
        let stream = queue.stream()
        _videoInputStream = stream
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
        return max(0, _maxVideoBufferBytes / bytesPerFrame)
    }

    private let audioCodec = AudioCodec()
    private let videoCodec = VideoCodec()
    private var _videoInputStream: AsyncStream<CMSampleBuffer>?
    /// 原始影格消費工作的世代，由同一把 codec 鎖保護。
    /// 舊工作即使在 cancel 後才醒來，也不得餵資料給已重啟的編碼器。
    private var videoInputGeneration: UInt64 = 0

    package func setVideoCodecLogHandler(_ handler: @Sendable @escaping (String) -> Void) {
        withLock { videoCodec.onLog = handler }
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
            let queue = withLock { () -> AdaptiveMediaQueue<CMSampleBuffer>? in
                if videoQueue == nil { videoQueueMissingDrops += 1 }
                return videoQueue
            }
            let size = sampleBuffer.imageBuffer.map { CVPixelBufferGetDataSize($0) } ?? CMSampleBufferGetTotalSampleSize(sampleBuffer)
            queue?.offer(sampleBuffer, bytes: size)
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
    package func append(video sampleBuffer: CMSampleBuffer, generation: UInt64? = nil) {
        withLock {
            // 驗證與 encode 必須同鎖，不能在鎖外先比對再餵給新 session。
            // 讓編碼維持在原本工作執行緒，不占用 RTMP actor 處理控制訊息的時間。
            if let generation, generation != videoInputGeneration { return }
            videoCodec.append(sampleBuffer)
        }
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
            videoInputGeneration &+= 1
            videoCodec.stopRunning()
            audioCodec.stopRunning()
            videoQueue?.finish()
            videoQueue = nil
            _videoInputStream = nil
        }
    }
}
