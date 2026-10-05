// Verification of RTMPHandshake (RTMPHaishinKit/Sources/RTMP/RTMPHandshake.swift)
// on non-Apple platforms. Compiled together with the real source file so the
// shipped parser is what gets exercised:
//
//   swiftc RTMPHaishinKit/Sources/RTMP/RTMPHandshake.swift \
//          .cortexkit/verify-handshake.swift -o .cortexkit/verify-handshake.exe
//
// Covers: C0C1 shape, S0S1 parsing, C2 echo, and — most importantly — that
// bytes trailing S2 in the SAME TCP read are preserved by takeTrailing()
// (the regression that silently dropped SetChunkSize / connect `_result` and
// hung reconnects).
import Foundation

var failures = 0
func expect(_ cond: Bool, _ name: String) {
    if cond {
        print("  ok   \(name)")
    } else {
        failures += 1
        print("  FAIL \(name)")
    }
}

func makeS0S1(version: UInt8 = 3, timestamp: UInt32 = 0x11223344, fill: UInt8 = 0xAB) -> Data {
    var data = Data()
    data.append(version)
    var ts = timestamp.bigEndian
    data.append(Data(bytes: &ts, count: 4))
    data.append(Data(count: 4))
    data.append(Data(repeating: fill, count: RTMPHandshake.sigSize - 8))
    return data
}

func makeS2(fill: UInt8 = 0xCD) -> Data {
    Data(repeating: fill, count: RTMPHandshake.sigSize)
}

func bigEndianUInt32(_ data: Data) -> UInt32 {
    UInt32(data[0]) << 24 | UInt32(data[1]) << 16 | UInt32(data[2]) << 8 | UInt32(data[3])
}

@main
struct VerifyHandshake {
    static func main() {
        // 1. C0C1 shape.
        do {
            let h = RTMPHandshake()
            let c0c1 = h.c0c1packet
            expect(c0c1.count == 1 + RTMPHandshake.sigSize, "c0c1 size = 1537")
            expect(c0c1[0] == RTMPHandshake.protocolVersion, "C0 protocol version = 3")
        }

        // 2. S0S1 parse + C2 echo; no trailing until S2.
        do {
            let h = RTMPHandshake()
            let ts: UInt32 = 0x11223344
            h.put(makeS0S1(timestamp: ts))
            expect(h.hasS0S1Packet, "hasS0S1 after 1537")
            expect(!h.hasS2Packet, "not full handshake after S0S1")
            expect(h.s0Version == 3, "s0Version = 3")
            let c2 = h.c2packet()
            expect(c2.count == RTMPHandshake.sigSize, "c2 size = 1536")
            expect(bigEndianUInt32(c2) == ts, "c2 echoes S1 timestamp")
            expect(h.takeTrailing().isEmpty, "no trailing before S2")
        }

        // 3. S0S1 + S2 in one read, nothing after.
        do {
            let h = RTMPHandshake()
            h.put(makeS0S1() + makeS2())
            expect(h.hasS2Packet, "full handshake from one read")
            expect(h.takeTrailing().isEmpty, "no trailing when the read ends at S2")
        }

        // 4. REGRESSION: S0S1 + S2 + trailing in ONE read must not lose trailing.
        do {
            let h = RTMPHandshake()
            let trailing = Data([0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x14, 0x00, 0x00, 0x00])
            h.put(makeS0S1() + makeS2() + trailing)
            expect(h.hasS2Packet, "full handshake with trailing")
            expect(h.takeTrailing() == trailing, "trailing after S2 preserved (regression)")
        }

        // 5. S0S1 separate, then S2 + trailing in one read.
        do {
            let h = RTMPHandshake()
            h.put(makeS0S1())
            expect(!h.hasS2Packet, "waiting for S2 across reads")
            let trailing = Data([0xDE, 0xAD, 0xBE, 0xEF])
            h.put(makeS2() + trailing)
            expect(h.hasS2Packet, "full handshake after second read")
            expect(h.takeTrailing() == trailing, "trailing preserved across reads")
        }

        // 6. Byte-by-byte feed: full only exactly at the last handshake byte.
        do {
            let h = RTMPHandshake()
            let bytes = makeS0S1() + makeS2() + Data([0x01, 0x02, 0x03])
            var firstFullIndex = -1
            for (i, byte) in bytes.enumerated() {
                h.put(Data([byte]))
                if h.hasS2Packet && firstFullIndex < 0 {
                    firstFullIndex = i
                }
            }
            expect(firstFullIndex == RTMPHandshake.handshakeSize - 1, "full handshake exactly at byte 3073")
            expect(h.takeTrailing() == Data([0x01, 0x02, 0x03]), "trailing preserved byte-by-byte")
        }

        // 7. takeTrailing is one-shot.
        do {
            let h = RTMPHandshake()
            h.put(makeS0S1() + makeS2() + Data([0xAA]))
            expect(h.takeTrailing() == Data([0xAA]), "first take returns trailing")
            expect(h.takeTrailing().isEmpty, "second take is empty")
        }

        // 8. clear resets, and a new handshake works with no stale trailing.
        do {
            let h = RTMPHandshake()
            h.put(makeS0S1() + makeS2() + Data([0xAA]))
            h.clear()
            expect(!h.hasS0S1Packet && !h.hasS2Packet, "clear resets buffers")
            h.put(makeS0S1())
            expect(h.hasS0S1Packet, "usable after clear")
            expect(h.takeTrailing().isEmpty, "no stale trailing after clear")
        }

        // 9. An unsupported S0 version is observable before proceeding.
        do {
            let h = RTMPHandshake()
            h.put(makeS0S1(version: 2))
            expect(h.s0Version == 2, "s0Version surfaces unsupported value")
            expect(h.hasS0S1Packet, "S0S1 present even for old version")
        }

        print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
        exit(failures == 0 ? 0 : 1)
    }
}
