import Foundation

/// Computes the RTMP video composition time (wire `PTS − wire DTS`, in
/// milliseconds) that is written into the 24-bit SI24 field of an FLV video
/// tag. Kept as a pure function so the invariant is unit-testable without
/// VideoToolbox / CMSampleBuffer.
///
/// Invariant: the result is **never negative**.
///
/// - A stream with frame reordering (B-frames) exposes a valid decode
///   timestamp; the composition time is `PTS − DTS + ctsOffset`, clamped to 0.
/// - A stream without reordering (IPPP) has `PTS == DTS` on the wire, so the
///   composition time is exactly `0`.
///
/// A/V offset compensation shifts the wire DTS (and therefore, through the
/// `PTS = DTS + CTS` sum, the wire PTS) by the same amount. It must **never** be
/// folded into the composition time: measuring an uncompensated `PTS` against a
/// compensated `DTS` yields `−compensation`, and a negative composition time
/// makes strict low-latency players (e.g. mpegts.js with latency chasing) treat
/// every video sample as `pts < dts` and drop it, leaving the connection alive
/// but the picture blank.
enum RTMPVideoCompositionTime {
    /// - Parameters:
    ///   - hasValidDecodeTimeStamp: whether the sample buffer exposes a decode
    ///     timestamp, i.e. whether the encoder reorders frames.
    ///   - presentationTime: source presentation timestamp, in seconds.
    ///   - decodeTime: source decode timestamp, in seconds.
    ///   - ctsOffset: fixed offset added to reordered streams.
    /// - Returns: a non-negative composition time in milliseconds.
    static func offset(
        hasValidDecodeTimeStamp: Bool,
        presentationTime: TimeInterval,
        decodeTime: TimeInterval,
        ctsOffset: TimeInterval
    ) -> Int32 {
        guard hasValidDecodeTimeStamp else { return 0 }
        return max(0, Int32(((presentationTime - decodeTime) + ctsOffset) * 1000))
    }
}
