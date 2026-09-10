import Foundation
import Testing

@testable import HaishinKit

@Suite("SwiftCore：Data 整數轉換") struct SwiftCoreExtensionTests {
    @Test("Int32：Data 往返轉換") func int32() {
        #expect(Int32.min == Int32(data: Int32.min.data))
        #expect(Int32.max == Int32(data: Int32.max.data))
    }
}
