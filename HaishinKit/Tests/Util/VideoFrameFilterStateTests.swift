import Foundation
import Testing

@testable import HaishinKit

/// `VideoFrameFilterState` 的純狀態驗證：理由計數、連續過濾長度、
/// 最後一筆的 PTS 差，以及接受影格後只歸零连续数、不抹掉歷史最大值。
///
/// 對應非 Apple 平台的獨立驗證腳本 `.cortexkit/verify-video-frame-filter.swift`。
@Suite("VideoFrameFilterState：useFrame 過濾原因")
struct VideoFrameFilterStateTests {
    @Test("理由分開累計，連續過濾與最大值同步成長")
    func reasonsAccumulate() {
        var state = VideoFrameFilterState()
        state.filtered(reason: .nonMonotonic, presentationTime: 9.9,
                       lastAcceptedPresentationTime: 10.0, uptime: 1.0)
        state.filtered(reason: .frameInterval, presentationTime: 10.01,
                       lastAcceptedPresentationTime: 10.0, uptime: 1.01)
        state.filtered(reason: .frameInterval, presentationTime: 10.02,
                       lastAcceptedPresentationTime: 10.0, uptime: 1.02)
        #expect(state.consecutive == 3)
        #expect(state.maxConsecutive == 3)
        #expect((state.reasonCounts["nonMonotonic"] ?? 0) == 1)
        #expect((state.reasonCounts["frameInterval"] ?? 0) == 2)
        #expect(abs((state.last?.deltaSeconds ?? 0) - 0.02) < 1e-9)
    }

    @Test("接受影格只歸零連續數，保留歷史最大連續過濾")
    func acceptedResetsConsecutiveOnly() {
        var state = VideoFrameFilterState()
        for index in 0..<3 {
            state.filtered(reason: .adaptiveThrottle, presentationTime: Double(index),
                           lastAcceptedPresentationTime: 0, uptime: Double(index))
        }
        state.accepted()
        #expect(state.consecutive == 0)
        #expect(state.maxConsecutive == 3)
        state.filtered(reason: .frameInterval, presentationTime: 4,
                       lastAcceptedPresentationTime: 3, uptime: 4)
        #expect(state.consecutive == 1)
        #expect(state.maxConsecutive == 3)
    }

    @Test("無效 PTS 與尚未接受影格時 delta 保持 unknown")
    func invalidPTSKeepsUnknown() {
        var state = VideoFrameFilterState()
        state.filtered(reason: .beforeStart, presentationTime: .nan,
                       lastAcceptedPresentationTime: nil, uptime: 1)
        #expect(state.last?.presentationTimeSeconds == nil)
        #expect(state.last?.lastAcceptedPresentationTimeSeconds == nil)
        #expect(state.last?.deltaSeconds == nil)
    }

    @Test("PTS 倒退保留負的 delta，供 nonMonotonic 判讀")
    func negativeDeltaPreserved() {
        var state = VideoFrameFilterState()
        state.filtered(reason: .nonMonotonic, presentationTime: 9.5,
                       lastAcceptedPresentationTime: 10.0, uptime: 1)
        #expect(abs((state.last?.deltaSeconds ?? 0) - (-0.5)) < 1e-9)
    }

    @Test("快照摘要包含理由計數與最後一筆")
    func snapshotSummary() {
        var state = VideoFrameFilterState()
        state.filtered(reason: .frameInterval, presentationTime: 1.0,
                       lastAcceptedPresentationTime: 0.9, uptime: 2)
        let text = state.snapshot.summary
        #expect(text.contains("reason=frameInterval"))
        #expect(text.contains("consecutive=1"))
        #expect(text.contains("maxConsecutive=1"))
    }
}
