import Foundation
import HaishinKit

final class RTMPHandshake {
    static let sigSize: Int = 1536
    static let protocolVersion: UInt8 = 3

    var timestamp: TimeInterval = 0

    // S0 (1 byte) + S1 (1536 bytes) = 1537 bytes
    var hasS0S1Packet: Bool {
        1 + RTMPHandshake.sigSize <= inputBuffer.count
    }

    // S2 (1536 bytes)
    var hasS2Packet: Bool {
        RTMPHandshake.sigSize <= inputBuffer.count - 1 - RTMPHandshake.sigSize
    }

    private var inputBuffer: Data = .init()
    private var s1RandomData: Data = .init()
    private var s1Timestamp: UInt32 = 0

    // C0 (1 byte) + C1 (1536 bytes) = 1537 bytes
    var c0c1packet: Data {
        var packet = Data()
        packet.reserveCapacity(1 + RTMPHandshake.sigSize)

        // C0: Protocol version (1 byte)
        packet.append(RTMPHandshake.protocolVersion)

        // C1: 1536 bytes
        let c1Timestamp = UInt32(timestamp).bigEndian
        packet.append(contentsOf: withUnsafeBytes(of: c1Timestamp) { Data($0) })
        packet.append(Data(count: 4)) // Zero padding
        for _ in 0..<RTMPHandshake.sigSize - 8 {
            packet.append(UInt8.random(in: 0...UInt8.max))
        }

        return packet
    }

    // C2: 1536 bytes (S1 timestamp + client current time + S1 random data)
    func c2packet() -> Data {
        defer {
            // Remove S0 + S1 from buffer
            if inputBuffer.count >= 1 + RTMPHandshake.sigSize {
                inputBuffer.removeSubrange(0...RTMPHandshake.sigSize)
            }
        }

        var packet = Data()
        packet.reserveCapacity(RTMPHandshake.sigSize)

        // S1 timestamp (4 bytes, big endian)
        packet.append(contentsOf: withUnsafeBytes(of: s1Timestamp.bigEndian) { Data($0) })

        // Client current timestamp (4 bytes, big endian)
        let clientTime = UInt32(Date().timeIntervalSince1970 * 1000).bigEndian
        packet.append(contentsOf: withUnsafeBytes(of: clientTime) { Data($0) })

        // S1 random data (1528 bytes)
        packet.append(s1RandomData)

        return packet
    }

    func put(_ data: Data) {
        inputBuffer.append(data)

        // Parse S0/S1 when we have enough data
        if hasS0S1Packet && s1RandomData.isEmpty {
            parseS0S1()
        }
    }

    private func parseS0S1() {
        guard inputBuffer.count >= 1 + RTMPHandshake.sigSize else { return }

        // S0: protocol version (1 byte) - at index 0
        // S1: starts at index 1
        let s1Start = 1
        // S1 timestamp: 4 bytes at offset 1
        s1Timestamp = UInt32(bigEndian: inputBuffer[s1Start..<s1Start + 4].withUnsafeBytes { $0.load(as: UInt32.self) })
        // S1 random data: 1528 bytes starting at offset 9 (1 + 4 + 4)
        let randomStart = s1Start + 8
        s1RandomData = inputBuffer[randomStart..<randomStart + RTMPHandshake.sigSize - 8]
    }

    func clear() {
        inputBuffer = .init()
        s1RandomData = .init()
        s1Timestamp = 0
        timestamp = Date().timeIntervalSince1970
    }
}

extension Data {
    func withUnsafeBytes<T>(_ body: (UnsafeRawBufferPointer) throws -> T) rethrows -> T {
        try self.withUnsafeBytes { buffer in
            try body(buffer)
        }
    }
}