import AVFoundation

/// A destination for the encoded sample buffers a recording produces.
///
/// Normally a recording is written to a local file (`StreamRecorder` +
/// `AVAssetWriter`). When the process that owns the samples cannot write a file
/// the host app can see — notably a ReplayKit broadcast extension, whose
/// container is invisible to the host app and to the user — the samples are
/// forwarded to a sink instead and the host app rebuilds the recording.
///
/// The recorder yields sample buffers **in order** and never concurrently, so an
/// implementation only needs to accept serial calls (it may hop to its own queue
/// internally).
///
/// ```swift
/// // Extension side: forward every encoded sample to the host app.
/// final class SocketRecordingSink: StreamRecorderSink {
///     func write(_ sampleBuffer: CMSampleBuffer) async { /* frame + send */ }
///     func finish() async { /* flush */ }
/// }
///
/// let recorder = StreamRecorder()
/// try await recorder.startRecording(to: SocketRecordingSink())
/// ```
public protocol StreamRecorderSink: Sendable {
    /// Called for each encoded sample buffer, in order.
    func write(_ sampleBuffer: CMSampleBuffer) async
    /// Called once when recording stops so the sink can flush.
    func finish() async
}
