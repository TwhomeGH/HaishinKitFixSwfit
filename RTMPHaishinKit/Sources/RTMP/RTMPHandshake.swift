import Foundation

/// RTMP 簡易握手（plain RTMP）解析器。
///
/// 流程：client 送 C0C1（1 + 1536 bytes）→ server 回 S0S1（1 + 1536）→
/// client 回 C2（1536）→ server 回 S2（1536）。握手總長固定為
/// `handshakeSize` = 1 + 1536 + 1536 = 3073 bytes。
///
/// **核心不變式**：`inputBuffer` 保存自連線開始收到的所有位元組，直到呼叫端
/// 明確消費。握手本身不帶給上層；握手「之後」的位元組（也就是 S2 結尾之後的
/// RTMP chunk 串流）只能透過 `takeTrailing()` 取出。消費只發生在
/// `takeTrailing()`，`c2packet()` 不再有移除副作用。
///
/// 這個型別刻意只依賴 Foundation，方便在非 Apple 平台單獨用 swiftc 驗證，
/// 對應 `.cortexkit/verify-handshake.swift` 與 `RTMPHandshakeTests`。
///
/// 歷史教訓：舊版在 `c2packet()` 內用 `removeSubrange` 移除 S0+S1，而 S2 只用
/// 「buffered 數量」判斷、從不移除，於是**任何與 S2 同一段 TCP read 抵達的
/// 後續位元組都會被靜默丟棄**（S2 之後緊接的 SetChunkSize / WindowAckSize /
/// connect `_result` 全失），導致重連時 connect 永不 resolve。
final class RTMPHandshake {
    static let sigSize: Int = 1536
    static let protocolVersion: UInt8 = 3
    /// S0(1) + S1(1536) + S2(1536)
    static let handshakeSize: Int = 1 + sigSize + sigSize

    var timestamp: TimeInterval = 0

    /// 已收到 S0+S1（1 + 1536），可以送出 C2。
    var hasS0S1Packet: Bool {
        1 + RTMPHandshake.sigSize <= inputBuffer.count
    }

    /// 已收到完整握手 S0+S1+S2（3073），可以送出 connect 並取用後續位元組。
    var hasS2Packet: Bool {
        RTMPHandshake.handshakeSize <= inputBuffer.count
    }

    private(set) var s0Version: UInt8 = 0
    private var inputBuffer: Data = .init()
    private var s1RandomData: Data = .init()
    private var s1Timestamp: UInt32 = 0
    private var didTakeTrailing = false

    // C0 (1 byte) + C1 (1536 bytes) = 1537 bytes
    var c0c1packet: Data {
        var packet = Data()
        packet.reserveCapacity(1 + RTMPHandshake.sigSize)

        // C0: Protocol version (1 byte)
        packet.append(RTMPHandshake.protocolVersion)

        // C1: 1536 bytes
        let c1Timestamp = UInt32(truncatingIfNeeded: Int64(timestamp * 1000)).bigEndian
        packet.append(contentsOf: withUnsafeBytes(of: c1Timestamp) { Data($0) })
        packet.append(Data(count: 4)) // Zero padding
        for _ in 0..<RTMPHandshake.sigSize - 8 {
            packet.append(UInt8.random(in: 0...UInt8.max))
        }

        return packet
    }

    // C2: 1536 bytes (S1 timestamp + client current time + S1 random data)
    //
    // 注意：這裡**不再**移除 S0+S1。消費 S0+S1+S2 只由 `takeTrailing()` 負責，
    // 讓「握手邊界」只有一個權威位置，避免同段資料被誤丟。
    func c2packet() -> Data {
        var packet = Data()
        packet.reserveCapacity(RTMPHandshake.sigSize)

        // S1 timestamp (4 bytes, big endian)
        var ts = s1Timestamp.bigEndian
        packet.append(Data(bytes: &ts, count: MemoryLayout<UInt32>.size))

        // Client current timestamp (4 bytes, big endian)
        var ct = UInt32(truncatingIfNeeded: Int64(Date().timeIntervalSince1970 * 1000)).bigEndian
        packet.append(Data(bytes: &ct, count: MemoryLayout<UInt32>.size))

        // S1 random data (1528 bytes)
        if !s1RandomData.isEmpty {
            packet.append(s1RandomData)
        }

        return packet
    }

    func put(_ data: Data) {
        inputBuffer.append(data)

        // Parse S0/S1 when we have enough data
        if hasS0S1Packet && s1RandomData.isEmpty {
            parseS0S1()
        }
    }

    /// 回傳並移除「握手之後」的 RTMP 位元組（S2 結尾之後的全部資料）。
    ///
    /// 呼叫端在 `hasS2Packet` 為真、且已送出 connect 之後呼叫，並必須把回傳值
    /// 交給 RTMP chunk parser；否則與 S2 同段抵達的資料會遺失。
    /// 只有第一次呼叫會回傳資料，之後回傳空（避免重複消費）。
    func takeTrailing() -> Data {
        guard !didTakeTrailing, RTMPHandshake.handshakeSize <= inputBuffer.count else {
            return .init()
        }
        didTakeTrailing = true
        guard inputBuffer.count > RTMPHandshake.handshakeSize else {
            inputBuffer.removeAll(keepingCapacity: false)
            return .init()
        }
        let trailing = Data(inputBuffer[RTMPHandshake.handshakeSize...])
        inputBuffer.removeAll(keepingCapacity: false)
        return trailing
    }

    private func parseS0S1() {
        guard inputBuffer.count >= 1 + RTMPHandshake.sigSize else { return }

        s0Version = inputBuffer[0]
        // S1: starts at index 1
        let s1Start = 1
        // S1 timestamp: 4 bytes at offset 1
        s1Timestamp = UInt32(inputBuffer[s1Start]) << 24 | UInt32(inputBuffer[s1Start + 1]) << 16 | UInt32(inputBuffer[s1Start + 2]) << 8 | UInt32(inputBuffer[s1Start + 3])
        // S1 random data: 1528 bytes starting at offset 9 (1 + 4 + 4)
        let randomStart = s1Start + 8
        s1RandomData = inputBuffer[randomStart..<randomStart + RTMPHandshake.sigSize - 8]
    }

    func clear() {
        inputBuffer = .init()
        s1RandomData = .init()
        s1Timestamp = 0
        s0Version = 0
        didTakeTrailing = false
        timestamp = Date().timeIntervalSince1970
    }
}
