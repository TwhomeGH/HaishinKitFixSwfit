import Testing
@testable import RTMPHaishinKit

struct RTMPDrainWaitersTests {
    private actor Harness {
        private var waiters = RTMPDrainWaiters()
        private var finished = false
        func wait() async {
            guard !finished else { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        var count: Int { waiters.count }
        func finish() { finished = true; waiters.finish() }
    }

    @Test func concurrentDrainsAllResumeAndRepeatedFinishIsSafe() async throws {
        let harness = Harness()
        let first = Task { await harness.wait() }
        let second = Task { await harness.wait() }
        // 限時等待註冊；即使斷言失敗也先釋放所有等待者，避免測試自己洩漏。
        for _ in 0..<200 {
            if await harness.count == 2 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(await harness.count == 2)
        await harness.finish()
        await harness.finish()
        await first.value
        await second.value
        #expect(await harness.count == 0)
    }
}
