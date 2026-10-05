import Foundation
@testable import RTMPHaishinKit
import Testing

/// Unit tests for the RTMP video composition-time invariant.
///
/// Regression: A/V offset compensation is applied to the wire DTS (and, through
/// `PTS = DTS + CTS`, to the wire PTS). Measuring an uncompensated PTS against a
/// compensated DTS produced `CTS == −compensation`, and a negative composition
/// time makes low-latency players drop every video sample (connection alive, no
/// picture). The composition time must therefore be measured on the DTS timeline
/// and never be negative.
@Suite struct RTMPVideoCompositionTimeTests {
    private let ctsOffset = 0.066

    @Test func noReorderingIsAlwaysZero() throws {
        // Without B-frames (decodeTimeStamp invalid) the source PTS and DTS
        // coincide on the wire, so the composition time is exactly 0 — no matter
        // how large or skewed the source timestamps are.
        let cases: [(TimeInterval, TimeInterval)] = [
            (0.000, 0.000),
            (0.100, 0.100),
            (1234.567, 1234.567),
            (-0.135, -0.135),
            // Even if the source timestamps diverge, no reordering => 0.
            (10.000, 0.000)
        ]
        for (pts, dts) in cases {
            let result = RTMPVideoCompositionTime.offset(
                hasValidDecodeTimeStamp: false,
                presentationTime: pts,
                decodeTime: dts,
                ctsOffset: ctsOffset)
            #expect(result == 0, "no-reorder pts=\(pts) dts=\(dts) => \(result)")
        }
    }

    @Test func reorderingProducesPresentationMinusDecode() throws {
        let result = RTMPVideoCompositionTime.offset(
            hasValidDecodeTimeStamp: true,
            presentationTime: 0.100,
            decodeTime: 0.066,
            ctsOffset: 0)
        #expect(result == 34)
    }

    @Test func reorderingAddsFixedCtsOffset() throws {
        let result = RTMPVideoCompositionTime.offset(
            hasValidDecodeTimeStamp: true,
            presentationTime: 0.100,
            decodeTime: 0.066,
            ctsOffset: ctsOffset)
        #expect(result == 100)
    }

    @Test func reorderingClampsNegativeOffsetToZero() throws {
        // PTS < DTS is not representable in FLV (SI24 must not be negative).
        let result = RTMPVideoCompositionTime.offset(
            hasValidDecodeTimeStamp: true,
            presentationTime: 0.033,
            decodeTime: 0.100,
            ctsOffset: 0)
        #expect(result == 0)
    }

    @Test func resultIsNeverNegative() throws {
        var presentationTime = -0.500
        while presentationTime <= 0.500 {
            var decodeTime = -0.500
            while decodeTime <= 0.500 {
                let result = RTMPVideoCompositionTime.offset(
                    hasValidDecodeTimeStamp: true,
                    presentationTime: presentationTime,
                    decodeTime: decodeTime,
                    ctsOffset: ctsOffset)
                #expect(result >= 0, "pts=\(presentationTime) dts=\(decodeTime) => \(result)")
                decodeTime += 0.017
            }
            presentationTime += 0.017
        }
    }

    @Test func avCompensationIsNotSelfCancelled() throws {
        // Mirrors `.cortexkit/verify-cts.swift`: with no reordering the wire DTS
        // already carries +compensation, so the wire PTS reconstructed from
        // `DTS + CTS` must stay shifted by compensation. The old buggy branch
        // returned `CTS == -compensation`, which cancelled the shift
        // (`wirePTS == sourcePTS`) — this guards against that regression.
        let compensation: TimeInterval = 0.135
        for sourcePTS in stride(from: 0.0, through: 1.0, by: 0.05) {
            let wireDTS = sourcePTS + compensation
            let cts = RTMPVideoCompositionTime.offset(
                hasValidDecodeTimeStamp: false,
                presentationTime: sourcePTS,
                decodeTime: wireDTS,
                ctsOffset: ctsOffset)
            let wirePTS = wireDTS + Double(cts) / 1000
            #expect(abs(wirePTS - (sourcePTS + compensation)) < 1e-9,
                    "sourcePTS=\(sourcePTS) wirePTS=\(wirePTS)")
        }
    }
}
