import Foundation

package extension ExpressibleByIntegerLiteral {
    var data: Data {
        return withUnsafePointer(to: self) { value in
            return Data(bytes: UnsafeRawPointer(value), count: MemoryLayout<Self>.size)
        }
    }

    init(data: Data) {
        let count = min(data.count, MemoryLayout<Self>.size)
        var result: Self = 0
        withUnsafeMutableBytes(of: &result) { dest in
            let src = data.withUnsafeBytes { $0 }
            guard let base = src.baseAddress else { return }
            dest.copyMemory(from: UnsafeRawBufferPointer(start: base, count: count))
        }
        self = result
    }

    init(data: Slice<Data>) {
        self.init(data: Data(data))
    }
}
