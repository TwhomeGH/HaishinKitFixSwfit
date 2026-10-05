// Verify the RTMP video composition-time invariant against the REAL source.
//
// Compile together with RTMPVideoCompositionTime.swift:
//   swiftc RTMPHaishinKit/Sources/RTMP/RTMPVideoCompositionTime.swift \
//          .cortexkit/verify-cts.swift -o .cortexkit/verify-cts.exe
//
// Reproduces the pre-fix behavior (negative CTS when A/V compensation is
// applied) and asserts the current implementation never returns a negative
// composition time, returns 0 for non-reordered (no B-frame) streams, and does
// not self-cancel the A/V compensation.
//
// Uses @main (not top-level statements): top-level code is only legal in a file
// literally named main.swift, so a multi-file compile with the real source
// would otherwise fail with "statements are not allowed at the top level".
import Foundation

let compensation: TimeInterval = 0.135  // measured +135ms A/V offset
let ctsOffset: TimeInterval = 0.066

var failures = 0
func check(_ name: String, _ cond: Bool, _ detail: String) {
    print("\(cond ? "PASS" : "FAIL")  \(name)  \(detail)")
    if !cond { failures += 1 }
}

// The old (buggy) else-branch measured an uncompensated PTS against a
// compensated wire DTS: CTS = PTS - (PTS + comp) = -comp.
func oldBuggyCTS(pts: TimeInterval, wireDTS: TimeInterval) -> Int32 {
    Int32((pts - wireDTS) * 1000)
}

@main
struct VerifyCTS {
    static func main() {
        for pts in stride(from: 0.0, through: 1.0, by: 0.02) {
            let wireDTS = pts + compensation  // RTMPTimestamp.update(frameTime) with comp
            let expected = pts + compensation  // wirePTS == wireDTS for no reordering

            // Pre-fix reproduction.
            let old = oldBuggyCTS(pts: pts, wireDTS: wireDTS)
            check("old buggy CTS < 0 @\(Int(pts*1000))ms", old < 0, "cts=\(old)")

            // Current implementation, no reordering (decodeTimeStamp invalid).
            let cts = RTMPVideoCompositionTime.offset(
                hasValidDecodeTimeStamp: false,
                presentationTime: pts,
                decodeTime: wireDTS,
                ctsOffset: ctsOffset)
            check("new CTS == 0 @\(Int(pts*1000))ms", cts == 0, "cts=\(cts)")

            let wirePTS = wireDTS + Double(cts) / 1000
            check("new wire PTS == sourcePTS + comp @\(Int(pts*1000))ms",
                  abs(wirePTS - expected) < 1e-9, "wirePTS=\(wirePTS)")
        }

        // Reordered (B-frame) path: PTS − DTS + ctsOffset, clamped >= 0.
        check("B-frame positive", RTMPVideoCompositionTime.offset(
            hasValidDecodeTimeStamp: true, presentationTime: 0.100, decodeTime: 0.066,
            ctsOffset: ctsOffset) == 100, "expect 100")
        check("B-frame clamp", RTMPVideoCompositionTime.offset(
            hasValidDecodeTimeStamp: true, presentationTime: 0.033, decodeTime: 0.100,
            ctsOffset: 0) == 0, "expect 0")

        print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURES")
        exit(failures == 0 ? 0 : 1)
    }
}
