import Foundation

/// Audio pipeline health snapshot for host-side telemetry (e.g. ReplyKit AHealth).
///
/// All counters are **cumulative** since the track/mixer was created. The caller
/// is expected to sample periodically and compute deltas (samples/s). This keeps
/// the hot path free of logging/aggregation work.
public struct AudioPipelineDiagnostics: Sendable {
    /// Per-track counters.
    public struct Track: Sendable {
        /// Caller-defined track id (ReplyKit: 0 = app, 1 = mic).
        public let trackId: UInt8
        /// Number of resampled frames delivered to the mixer (`didOutput`).
        public let outputFrames: Int
        /// Number of times `resample()` produced no output because the ring
        /// buffer did not yet hold a full input block (underrun / `inputRanDry`).
        public let resampleNoDataCount: Int
        /// Samples dropped by cross-track `align()` because this (non-main)
        /// track was ahead of the mixer playhead — the prime content-dropout
        /// suspect for ReplayKit dual-track mixing.
        public let alignDroppedSamples: Int
        /// Silence samples inserted by `align()` because this track lagged the
        /// mixer playhead.
        public let alignInsertedSamples: Int
        /// Samples discarded because the ring buffer overflowed its capacity
        /// (producer outran the consumer).
        public let overflowDroppedSamples: Int
        /// Silence samples inserted by `append()` on a PTS gap.
        public let skipInsertedSamples: Int
        /// Current buffered sample count in the ring buffer.
        public let ringBufferCounts: Int
        /// Number of `align()` calls that actually changed state (outside the
        /// deadband). Lets the host tell "one-time anchor correction" from
        /// "continuous per-frame correction" (the content-dropout signature).
        public let alignFireCount: Int
        /// Last `align()` discrepancy in input samples (`position - current`;
        /// positive = this track lags the mixer playhead).
        public let lastAlignDiff: Int

        public init(
            trackId: UInt8,
            outputFrames: Int,
            resampleNoDataCount: Int,
            alignDroppedSamples: Int,
            alignInsertedSamples: Int,
            overflowDroppedSamples: Int,
            skipInsertedSamples: Int,
            ringBufferCounts: Int,
            alignFireCount: Int,
            lastAlignDiff: Int
        ) {
            self.trackId = trackId
            self.outputFrames = outputFrames
            self.resampleNoDataCount = resampleNoDataCount
            self.alignDroppedSamples = alignDroppedSamples
            self.alignInsertedSamples = alignInsertedSamples
            self.overflowDroppedSamples = overflowDroppedSamples
            self.skipInsertedSamples = skipInsertedSamples
            self.ringBufferCounts = ringBufferCounts
            self.alignFireCount = alignFireCount
            self.lastAlignDiff = lastAlignDiff
        }
    }

    /// Per-track counters, sorted by `trackId`.
    public let tracks: [Track]
    /// Number of mixed output blocks produced by the mixer.
    public let mixerOutputFrames: Int

    public init(tracks: [Track], mixerOutputFrames: Int) {
        self.tracks = tracks
        self.mixerOutputFrames = mixerOutputFrames
    }

    public static let empty = AudioPipelineDiagnostics(tracks: [], mixerOutputFrames: 0)
}
