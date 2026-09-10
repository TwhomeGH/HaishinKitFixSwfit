import Foundation
import Testing

@testable import HaishinKit

@Suite("ADTSHeader：解析") struct ADTSHeaderTests {
    @Test("以位元組初始化 ADTSHeader") func bytes() {
        let data = Data([255, 241, 77, 128, 112, 127, 252, 1])
        _ = ADTSHeader(data: data)
    }
}
