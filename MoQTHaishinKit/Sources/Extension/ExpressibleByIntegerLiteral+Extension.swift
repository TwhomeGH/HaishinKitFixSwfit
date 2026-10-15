import Foundation

extension ExpressibleByIntegerLiteral {
    var data: Data {
        return withUnsafePointer(to: self) { value in
            return Data(bytes: UnsafeRawPointer(value), count: MemoryLayout<Self>.size)
        }
    }

    init(data: Data) {
        let count = min(data.count, MemoryLayout<Self>.size)
        var result: Self = 0
        withUnsafeMutableBytes(of: &result) { dest in
            // Data（尤其 inline 小資料）的指標只在閉包期間有效，不可帶出後再複製。
            data.withUnsafeBytes { src in
                guard let base = src.baseAddress else { return }
                dest.copyMemory(from: UnsafeRawBufferPointer(start: base, count: count))
            }
        }
        self = result
    }

    init(data: Slice<Data>) {
        self.init(data: Data(data))
    }
}
