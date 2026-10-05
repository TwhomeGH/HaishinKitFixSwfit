import Foundation
import Testing

@testable import RTMPHaishinKit

/// `RTMPHandshake` 的行為驗證：C0C1 / S0S1 / C2 形狀，以及最關鍵的
/// 「S2 之後同段抵達的位元組必須被 `takeTrailing()` 完整保留」。
///
/// 同一組案例也有非 Apple 平台的獨立驗證腳本 `.cortexkit/verify-handshake.swift`。
/// 這條回歸曾造成重連失敗：S2 與伺服器的 SetChunkSize / connect `_result` 同段
/// 抵達時，後者被靜默丟棄，`connect` 永不 resolve。
@Suite("RTMPHandshake：握手解析與 S2 後資料保留")
struct RTMPHandshakeTests {
    private static let s1Timestamp: UInt32 = 0x11223344

    private static func makeS0S1(version: UInt8 = 3, timestamp: UInt32 = s1Timestamp, fill: UInt8 = 0xAB) -> Data {
        var data = Data()
        data.append(version)
        var ts = timestamp.bigEndian
        data.append(Data(bytes: &ts, count: 4))
        data.append(Data(count: 4))
        data.append(Data(repeating: fill, count: RTMPHandshake.sigSize - 8))
        return data
    }

    private static func makeS2(fill: UInt8 = 0xCD) -> Data {
        Data(repeating: fill, count: RTMPHandshake.sigSize)
    }

    private static func bigEndianUInt32(_ data: Data) -> UInt32 {
        UInt32(data[0]) << 24 | UInt32(data[1]) << 16 | UInt32(data[2]) << 8 | UInt32(data[3])
    }

    @Test("C0C1 為 1537 bytes，C0 版本為 3")
    func c0c1Shape() {
        let handshake = RTMPHandshake()
        let c0c1 = handshake.c0c1packet
        #expect(c0c1.count == 1 + RTMPHandshake.sigSize)
        #expect(c0c1[0] == RTMPHandshake.protocolVersion)
    }

    @Test("S0S1 解析出 S0 版本，C2 回帶 S1 timestamp")
    func parsesS0S1AndEchoesInC2() {
        let handshake = RTMPHandshake()
        handshake.put(Self.makeS0S1())

        #expect(handshake.hasS0S1Packet)
        #expect(!handshake.hasS2Packet)
        #expect(handshake.s0Version == 3)
        let c2 = handshake.c2packet()
        #expect(c2.count == RTMPHandshake.sigSize)
        #expect(Self.bigEndianUInt32(c2) == Self.s1Timestamp)
        #expect(handshake.takeTrailing().isEmpty)
    }

    @Test("S0S1 + S2 同段、S2 後無資料：trailing 為空")
    func handshakeExactlyAtBoundary() {
        let handshake = RTMPHandshake()
        handshake.put(Self.makeS0S1() + Self.makeS2())
        #expect(handshake.hasS2Packet)
        #expect(handshake.takeTrailing().isEmpty)
    }

    @Test("回歸：S0S1 + S2 + trailing 同一段時，S2 之後的資料不可遺失")
    func preservesTrailingInSameRead() {
        let handshake = RTMPHandshake()
        let trailing = Data([0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x14, 0x00, 0x00, 0x00])
        handshake.put(Self.makeS0S1() + Self.makeS2() + trailing)

        #expect(handshake.hasS2Packet)
        #expect(handshake.takeTrailing() == trailing)
    }

    @Test("S0S1 單獨到達，第二次讀到 S2 + trailing 仍保留")
    func preservesTrailingAcrossReads() {
        let handshake = RTMPHandshake()
        handshake.put(Self.makeS0S1())
        #expect(!handshake.hasS2Packet)

        let trailing = Data([0xDE, 0xAD, 0xBE, 0xEF])
        handshake.put(Self.makeS2() + trailing)
        #expect(handshake.hasS2Packet)
        #expect(handshake.takeTrailing() == trailing)
    }

    @Test("逐 byte 餵入：剛好第 3073 byte 才完成握手，trailing 仍保留")
    func byteByByteFeed() {
        let handshake = RTMPHandshake()
        let bytes = Self.makeS0S1() + Self.makeS2() + Data([0x01, 0x02, 0x03])
        var firstFullIndex = -1
        for (index, byte) in bytes.enumerated() {
            handshake.put(Data([byte]))
            if handshake.hasS2Packet && firstFullIndex < 0 {
                firstFullIndex = index
            }
        }
        #expect(firstFullIndex == RTMPHandshake.handshakeSize - 1)
        #expect(handshake.takeTrailing() == Data([0x01, 0x02, 0x03]))
    }

    @Test("takeTrailing 只回傳一次")
    func takeTrailingIsOneShot() {
        let handshake = RTMPHandshake()
        handshake.put(Self.makeS0S1() + Self.makeS2() + Data([0xAA]))
        #expect(handshake.takeTrailing() == Data([0xAA]))
        #expect(handshake.takeTrailing().isEmpty)
    }

    @Test("clear 清空狀態，重新握手不會殘留舊 trailing")
    func clearResets() {
        let handshake = RTMPHandshake()
        handshake.put(Self.makeS0S1() + Self.makeS2() + Data([0xAA]))
        handshake.clear()
        #expect(!handshake.hasS0S1Packet && !handshake.hasS2Packet)

        handshake.put(Self.makeS0S1())
        #expect(handshake.hasS0S1Packet)
        #expect(handshake.takeTrailing().isEmpty)
    }

    @Test("不支援的 S0 版本可被觀察到")
    func surfacesUnsupportedS0Version() {
        let handshake = RTMPHandshake()
        handshake.put(Self.makeS0S1(version: 2))
        #expect(handshake.s0Version == 2)
        #expect(handshake.hasS0S1Packet)
    }
}
