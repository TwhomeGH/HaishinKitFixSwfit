import Testing

@testable import HaishinKit

/// `AVContentSyncAudit` 的純配對／年齡驗證：配對以 arrival 為準，
/// `contentOffset` 優先用來源抓幀時間，因此能看見「handed PTS 正常、內容卻落後」。
///
/// 對應非 Apple 平台的獨立驗證腳本 `.cortexkit/verify-av-content-sync.swift`。
@Suite("AVContentSyncAudit：音視訊配對與內容年齡")
struct AVContentSyncAuditTests {
    @Test("arrival 窗口內配對，記錄 handed offset")
    func pairsWithinWindow() {
        var audit = AVContentSyncAudit(pairingWindow: 0.05)
        _ = audit.observe(kind: .video, handedPTS: 10, capturePTS: 10, arrival: 100)
        _ = audit.observe(kind: .audio, handedPTS: 10.02, capturePTS: nil, arrival: 100.01)

        #expect(audit.paired == 1)
        #expect(abs((audit.lastHandedOffset ?? .nan) - (-0.02)) < 1e-9)
        #expect(abs((audit.lastContentOffset ?? .nan) - (-0.02)) < 1e-9)
        #expect(abs((audit.lastAgeSkew ?? .nan) - 0.01) < 1e-9)
    }

    @Test("超出 arrival 窗口不配對，並在過期後計入 unpaired")
    func noPairOutsideWindow() {
        var audit = AVContentSyncAudit(pairingWindow: 0.05)
        _ = audit.observe(kind: .video, handedPTS: 10, capturePTS: 10, arrival: 100)
        _ = audit.observe(kind: .audio, handedPTS: 10, capturePTS: nil, arrival: 100.1)
        #expect(audit.paired == 0)

        _ = audit.observe(kind: .video, handedPTS: 12, capturePTS: 12, arrival: 102)
        #expect(audit.paired == 0)
        #expect(audit.unpairedVideo == 1)
    }

    @Test("來源抓幀時間可揭露 handed PTS 看不出的內容延遲")
    func contentLagFromCaptureTime() {
        var audit = AVContentSyncAudit(pairingWindow: 0.05)
        // 內容在 100s 抓到，直到 104s 才交給 mixer；handed PTS 卻是 104s。
        _ = audit.observe(kind: .video, handedPTS: 104, capturePTS: 100, arrival: 104)
        _ = audit.observe(kind: .audio, handedPTS: 104, capturePTS: nil, arrival: 104.01)

        #expect(abs((audit.lastHandedOffset ?? .nan)) < 1e-9)
        #expect(abs((audit.lastContentOffset ?? .nan) - (-4)) < 1e-9)
        #expect(abs((audit.lastVideoAge ?? .nan) - 4) < 1e-9)
        #expect(abs((audit.lastAgeSkew ?? .nan) - 3.99) < 1e-6)
    }

    @Test("contentOffset 斜率可看出內容延遲持續惡化")
    func contentOffsetSlope() {
        var audit = AVContentSyncAudit(pairingWindow: 0.05)
        for index in 0..<5 {
            let time = Double(index * 10)
            let offset = Double(index) * 0.01
            _ = audit.observe(kind: .video, handedPTS: time + offset, capturePTS: time + offset, arrival: time)
            _ = audit.observe(kind: .audio, handedPTS: time, capturePTS: nil, arrival: time + 0.01)
        }

        #expect(audit.paired == 5)
        let slope = audit.contentOffsetStats?.slopePerMinute ?? .nan
        #expect(abs(slope - 0.06) < 1e-6)
    }

    @Test("媒體 PTS 對齊但抓幀時間較舊：contentOffset 為 0，videoAge 仍揭露內容延遲")
    func hostTimeRevealsContentLagWhenMediaPTSAligns() {
        var audit = AVContentSyncAudit(pairingWindow: 0.05)
        // 內容在 100s 抓到，104s 才交給 mixer；媒體 PTS 已被標成 104s。
        _ = audit.observe(kind: .video, handedPTS: 104, capturePTS: 104,
                          captureHostTime: 100, captureTimeSource: .displayTime,
                          arrival: 104)
        _ = audit.observe(kind: .audio, handedPTS: 104, capturePTS: nil, arrival: 104.01)

        #expect(abs((audit.lastHandedOffset ?? .nan)) < 1e-9)
        #expect(abs((audit.lastContentOffset ?? .nan)) < 1e-9)
        #expect(abs((audit.lastVideoAge ?? .nan) - 4) < 1e-9)
        #expect(abs((audit.lastAgeSkew ?? .nan) - 3.99) < 1e-6)
        #expect(audit.videoHostTimeSamples == 1)
        #expect(audit.summary.contains("captureTime=hostTime"))
        #expect(audit.summary.contains("captureTimeSources{displayTime=1}"))
    }

    @Test("抓幀時間優先於 sourcePTS 計算 videoAge")
    func hostTimeTakesPrecedenceOverSourcePTS() {
        var audit = AVContentSyncAudit(pairingWindow: 0.05)
        _ = audit.observe(kind: .video, handedPTS: 104, capturePTS: 103,
                          captureHostTime: 100, captureTimeSource: .presentationTime,
                          arrival: 104)
        _ = audit.observe(kind: .audio, handedPTS: 104, capturePTS: nil, arrival: 104.01)

        #expect(abs((audit.lastContentOffset ?? .nan) - (-1)) < 1e-9)
        #expect(abs((audit.lastVideoAge ?? .nan) - 4) < 1e-9)
    }

    @Test("沒有來源抓幀時間時標示 captureTime=missing")
    func missingCaptureTime() {
        var audit = AVContentSyncAudit(pairingWindow: 0.05)
        _ = audit.observe(kind: .video, handedPTS: 10, capturePTS: nil, arrival: 100)
        _ = audit.observe(kind: .audio, handedPTS: 10, capturePTS: nil, arrival: 100.01)

        #expect(audit.videoCaptureTimeSamples == 0)
        #expect(audit.videoHostTimeSamples == 0)
        #expect(audit.summary.contains("captureTime=missing"))
    }

    @Test("有來源抓幀時間時標示 captureTime=sourcePTS")
    func providedCaptureTime() {
        var audit = AVContentSyncAudit(pairingWindow: 0.05)
        _ = audit.observe(kind: .video, handedPTS: 10, capturePTS: 9.996, arrival: 100)
        _ = audit.observe(kind: .audio, handedPTS: 10, capturePTS: nil, arrival: 100.01)

        #expect(audit.videoCaptureTimeSamples == 1)
        #expect(audit.summary.contains("captureTime=sourcePTS"))
    }
}
