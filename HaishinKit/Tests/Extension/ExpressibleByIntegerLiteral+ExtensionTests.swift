import Foundation
import Testing

@testable import HaishinKit

@Suite("整數字面量：bigEndian 位元組") struct ExpressibleByIntegerLiteralTests {
    @Test("Int32：bigEndian 位元組") func int32() {
        #expect(Int32.min.bigEndian.data == Data([128, 0, 0, 0]))
        #expect(Int32(32).bigEndian.data == Data([0, 0, 0, 32]))
        #expect(Int32.max.bigEndian.data == Data([127, 255, 255, 255]))
    }

    @Test("UInt32：bigEndian 位元組") func uint32() {
        #expect(UInt32.min.bigEndian.data == Data([0, 0, 0, 0]))
        #expect(UInt32(32).bigEndian.data == Data([0, 0, 0, 32]))
        #expect(UInt32.max.bigEndian.data == Data([255, 255, 255, 255]))
    }

    @Test("Int64：bigEndian 位元組") func int64() {
        #expect(Int64.min.bigEndian.data == Data([128, 0, 0, 0, 0, 0, 0, 0]))
        #expect(Int64(32).bigEndian.data == Data([0, 0, 0, 0, 0, 0, 0, 32]))
        #expect(Int64.max.bigEndian.data == Data([127, 255, 255, 255, 255, 255, 255, 255]))
    }

    @Test("UInt64：bigEndian 位元組") func uint64() {
        #expect(UInt64.min.bigEndian.data == Data([0, 0, 0, 0, 0, 0, 0, 0]))
        #expect(UInt64(32).bigEndian.data == Data([0, 0, 0, 0, 0, 0, 0, 32]))
        #expect(UInt64.max.bigEndian.data == Data([255, 255, 255, 255, 255, 255, 255, 255]))
    }
}

@Suite("整數解碼：短 Data 與切片") struct IntegerDataDecodingTests {
    @Test func inlineAndSlicedDataRemainStable() {
        for _ in 0..<1000 {
            let bytes = Data([0, 0, 16, 0])
            #expect(UInt32(data: bytes).bigEndian == 4096)
            let padded = Data([255, 255, 0, 0, 32, 0, 255])
            #expect(UInt32(data: padded[2..<6]).bigEndian == 8192)
            #expect(UInt16(data: Data([0x12, 0x34])).bigEndian == 0x1234)
            #expect(UInt64(data: Data([0, 0, 0, 0, 0, 0, 0, 42])).bigEndian == 42)
            #expect(UInt32(data: Data()) == 0)
        }
    }
}
