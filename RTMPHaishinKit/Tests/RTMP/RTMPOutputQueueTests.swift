import Testing
@testable import RTMPHaishinKit

/// 驗證 RTMPOutputQueue 的世代語義：一旦遺失一則（佇列滿 / consumer 終止），
/// 整個 epoch 作廢，後續依賴封包（SPS/PPS、IDR、P）全部拒收，直到 start() 重啟。
@Suite struct RTMPOutputQueueTests {
    /// 遺失 SPS/PPS 後：queue 關閉、世代改變、後續 IDR/P 全被拒；
    /// 舊 stream 也因世代不符而拿不到任何殘留項；start() 後才恢復。
    @Test func lostHeaderRejectsDependentFramesUntilRestart() async {
        var queue = RTMPOutputQueue<String>()
        let oldStream = queue.start(capacity: 1)
        let oldGeneration = queue.generation
        let enqueued1 = queue.enqueue("metadata")
        #expect(enqueued1)
        let enqueued2 = queue.enqueue("SPS/PPS")
        #expect(!enqueued2)
        #expect(!queue.isOpen)
        #expect(queue.generation != oldGeneration)
        let enqueued3 = queue.enqueue("IDR")
        #expect(!enqueued3)
        let enqueued4 = queue.enqueue("P")
        #expect(!enqueued4)
        // finish() 仍會保留已緩衝的資料。故障後 consumer 必須同時驗證世代，
        // 不能把這些殘留封包排入重連後的新 socket。
        var acceptedOld = [String]()
        for await item in oldStream where oldGeneration == queue.generation {
            acceptedOld.append(item)
        }
        #expect(acceptedOld.isEmpty)
        let newStream = queue.start(capacity: 2)
        let enqueued5 = queue.enqueue("stale P", expectedGeneration: oldGeneration)
        #expect(!enqueued5)
        let enqueued6 = queue.enqueue("SPS/PPS", expectedGeneration: queue.generation)
        #expect(enqueued6)
        let enqueued7 = queue.enqueue("IDR", expectedGeneration: queue.generation)
        #expect(enqueued7)
        queue.invalidate()
        var sent = [String]()
        for await item in newStream { sent.append(item) }
        #expect(sent == ["SPS/PPS", "IDR"])
    }

    /// 遺失 IDR 會連帶作廢已接受的 header：即使之後佇列有空位，
    /// 也不能讓後續 P 幀復活（GOP 已斷）。
    @Test func lostIdrInvalidatesOtherwiseAcceptedHeader() async {
        var queue = RTMPOutputQueue<String>()
        let stream = queue.start(capacity: 1)
        let enqueued8 = queue.enqueue("header")
        #expect(enqueued8)
        let enqueued9 = queue.enqueue("IDR")
        #expect(!enqueued9)
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == "header")
        // 即使排空後有空位，也不能重新開放已損失 IDR 的佇列。
        let enqueued10 = queue.enqueue("P")
        #expect(!enqueued10)
        #expect(await iterator.next() == nil)
    }

    /// stale 恢復流程帶舊世代入列會被拒絕，且不會關掉新連線的佇列。
    @Test func staleRecoveryCannotInvalidateNewConnection() async {
        var queue = RTMPOutputQueue<Int>()
        _ = queue.start()
        let failedGeneration = queue.generation
        let currentStream = queue.start()
        let enqueued11 = queue.enqueue(1, expectedGeneration: failedGeneration)
        #expect(!enqueued11)
        #expect(queue.isOpen)
        let enqueued12 = queue.enqueue(2, expectedGeneration: queue.generation)
        #expect(enqueued12)
        queue.invalidate()
        var sent = [Int]()
        for await item in currentStream { sent.append(item) }
        #expect(sent == [2])
    }

    /// advanceGeneration（shutdown）後：帶舊世代的媒體被拒，
    /// 但不帶世代的控制指令（deleteStream）仍可入列並排空。
    @Test func shutdownGenerationRejectsPendingMediaButAllowsControlDrain() async {
        var queue = RTMPOutputQueue<String>()
        let stream = queue.start()
        let publishingGeneration = queue.generation
        queue.advanceGeneration()
        let enqueued13 = queue.enqueue("old video", expectedGeneration: publishingGeneration)
        #expect(!enqueued13)
        let enqueued14 = queue.enqueue("deleteStream")
        #expect(enqueued14)
        queue.invalidate()
        var sent = [String]()
        for await item in stream { sent.append(item) }
        #expect(sent == ["deleteStream"])
    }

    /// consumer 被取消（terminated）後，再入列會失敗並使佇列關閉。
    @Test func terminatedConsumerInvalidatesOutput() async {
        var queue = RTMPOutputQueue<Int>()
        let stream = queue.start()
        let consumer = Task { for await _ in stream {} }
        consumer.cancel()
        await consumer.value
        let accepted = queue.enqueue(1)
        #expect(!accepted)
        #expect(!queue.isOpen)
    }

    /// 正常收播仍須送完已接受的尾幀，不能套用故障時直接作廢世代的策略。
    @Test func gracefulFinishDrainsAcceptedTailFrames() async {
        var queue = RTMPOutputQueue<String>()
        let stream = queue.start(capacity: 3)
        let generation = queue.generation
        let first = queue.enqueue("IDR")
        let tail = queue.enqueue("最後一幀")
        #expect(first && tail)
        queue.finish()
        #expect(queue.generation == generation)
        let late = queue.enqueue("停止後的新幀")
        #expect(!late)
        var sent = [String]()
        for await item in stream where queue.generation == generation { sent.append(item) }
        #expect(sent == ["IDR", "最後一幀"])
        queue.invalidate()
        #expect(queue.generation != generation)
    }

}
