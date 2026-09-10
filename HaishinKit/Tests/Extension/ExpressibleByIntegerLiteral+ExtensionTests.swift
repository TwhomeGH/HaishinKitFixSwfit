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
