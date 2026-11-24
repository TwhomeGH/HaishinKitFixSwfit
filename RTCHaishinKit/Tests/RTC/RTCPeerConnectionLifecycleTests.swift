import Foundation
import Testing

@testable import RTCHaishinKit

/// libdatachannel C API 的生命週期基線：不建立遠端連線，只驗證
/// 建立 → 註冊回呼 → 產生 offer → 關閉／釋放的順序在升級後仍成立。
///
/// 這一層需要 Apple 平台與 libdatachannel 二進位；純 Swift 的 RTP／SDP
/// 測試無法覆蓋 C 物件的建立與釋放，因此另外放在此檔案。
@Suite(.serialized) struct RTCPeerConnectionLifecycleTests {
    /// 建立 data channel 後應能產生非空的本地 offer。
    @Test func createsOfferWithDataChannelThenCloses() throws {
        let peerConnection = try RTCPeerConnection()
        defer { peerConnection.close() }

        let dataChannel = try peerConnection.createDataChannel("lifecycle")
        #expect(dataChannel.label == "lifecycle")

        let offer = try peerConnection.createOffer()
        #expect(offer.contains("v=0"))
        #expect(offer.contains("m="))
    }

    /// 所有 configuration 欄位都應能映射到 `rtcConfiguration` 並建立連線。
    @Test func appliesConfigurationFields() throws {
        let configuration = RTCConfiguration(
            iceServers: [],
            bindAddress: "127.0.0.1",
            isIceUdpMuxEnabled: true,
            isAutoNegotionEnabled: true,
            isForceMediaTransport: false,
            portRange: 50000..<50100,
            mtu: 1200,
            maxMesasgeSize: 65536
        )
        let peerConnection = try RTCPeerConnection(configuration)
        peerConnection.close()
    }

    /// 反覆建立、關閉與釋放，覆蓋 `close()` 與 `deinit` → `rtcDeletePeerConnection` 的路徑。
    @Test func repeatedCreateAndRelease() throws {
        for _ in 0..<32 {
            let peerConnection = try RTCPeerConnection()
            _ = try peerConnection.createDataChannel("stress")
            peerConnection.close()
        }
    }

    /// 記錄器應接受所有等級並可回復為關閉。
    @Test func loggerAcceptsAllLevels() async {
        let levels: [RTCLogger.Level] = [.none, .fatal, .error, .warning, .info, .debug, .verbose]
        for level in levels {
            await RTCLogger.shared.setLevel(level)
        }
        await RTCLogger.shared.setLevel(.none)
    }

    /// 編譯期回歸：`Level` 若不是 Sendable，跨模組送到 `RTCLogger` actor 會在
    /// Swift 6 觸發 sending data-race 診斷（CI 曾在 setLevel 迴圈遇到）。
    @Test func loggerLevelIsSendable() {
        func requireSendable<T: Sendable>(_ value: T) {}
        requireSendable(RTCLogger.Level.info)
    }
}
