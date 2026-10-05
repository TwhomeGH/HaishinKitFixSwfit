import AVFoundation
import Foundation
@testable import RTMPHaishinKit
import Testing

@Suite struct RTMPTimestampTests {
    @Test func updateCMTime() throws {
        let times: [CMTime] = [
            CMTime(value: 286340171565869, timescale: 1000000000),
            CMTime(value: 286340204889958, timescale: 1000000000),
            CMTime(value: 286340238223357, timescale: 1000000000),
            CMTime(value: 286340271560111, timescale: 1000000000),
            CMTime(value: 286340304906325, timescale: 1000000000),
            CMTime(value: 286340338232723, timescale: 1000000000),
            CMTime(value: 286340338232723, timescale: 1000000000)
        ]
        var timestamp = RTMPTimestamp<CMTime>()
        #expect(timestamp.update(times[0]) == 0)
        #expect(timestamp.update(times[1]) == 33)
        #expect(timestamp.update(times[2]) == 33)
        #expect(timestamp.update(times[3]) == 33)
        #expect(timestamp.update(times[4]) == 34)
        #expect(timestamp.update(times[5]) == 33)
    }

    @Test func updateAVAudioTime() throws {
        let times: [AVAudioTime] = [
            .init(hostTime: 6901294874500, sampleTime: 13802589749, atRate: 48000),
            .init(hostTime: 6901295386500, sampleTime: 13802590773, atRate: 48000),
            .init(hostTime: 6901295898500, sampleTime: 13802591797, atRate: 48000),
            .init(hostTime: 6901296410500, sampleTime: 13802592821, atRate: 48000),
            .init(hostTime: 6901296922500, sampleTime: 13802593845, atRate: 48000),
            .init(hostTime: 6901297434500, sampleTime: 13802594869, atRate: 48000)
        ]
        var timestamp = RTMPTimestamp<AVAudioTime>()
        #expect(timestamp.update(times[0]) == 0)
        #expect(timestamp.update(times[1]) == 21)
        #expect(timestamp.update(times[2]) == 21)
        #expect(timestamp.update(times[3]) == 22)
        #expect(timestamp.update(times[4]) == 21)
        #expect(timestamp.update(times[5]) == 21)
    }

    @Test func updateAVAudioTimeWithPreferredDelta() throws {
        let times: [AVAudioTime] = [
            .init(hostTime: AVAudioTime.hostTime(forSeconds: 100.000)),
            .init(hostTime: AVAudioTime.hostTime(forSeconds: 100.020)),
            .init(hostTime: AVAudioTime.hostTime(forSeconds: 100.057)),
            .init(hostTime: AVAudioTime.hostTime(forSeconds: 100.077)),
            .init(hostTime: AVAudioTime.hostTime(forSeconds: 100.114)),
            .init(hostTime: AVAudioTime.hostTime(forSeconds: 100.134))
        ]
        let aacPacketDuration = 1024.0 / 44100.0
        var timestamp = RTMPTimestamp<AVAudioTime>()
        #expect(timestamp.update(times[0], preferredDelta: aacPacketDuration) == 0)
        #expect(timestamp.update(times[1], preferredDelta: aacPacketDuration) == 23)
        #expect(timestamp.update(times[2], preferredDelta: aacPacketDuration) == 23)
        #expect(timestamp.update(times[3], preferredDelta: aacPacketDuration) == 23)
        #expect(timestamp.update(times[4], preferredDelta: aacPacketDuration) == 23)
        #expect(timestamp.update(times[5], preferredDelta: aacPacketDuration) == 24)
        #expect(abs(timestamp.updatedAt - (100.0 + aacPacketDuration * 5)) < 0.001)
    }

    @Test func updateAVAudioTimeWithPreferredDeltaCorrectsLargeSourceDrift() throws {
        let packetDuration = 0.023
        var timestamp = RTMPTimestamp<AVAudioTime>()
        #expect(timestamp.update(.init(hostTime: AVAudioTime.hostTime(forSeconds: 100.000)), preferredDelta: packetDuration) == 0)
        #expect(timestamp.update(.init(hostTime: AVAudioTime.hostTime(forSeconds: 100.023)), preferredDelta: packetDuration) == 23)
        #expect(timestamp.update(.init(hostTime: AVAudioTime.hostTime(forSeconds: 100.223)), preferredDelta: packetDuration) == 28)
        #expect(abs(timestamp.updatedAt - 100.051) < 0.001)
    }

    @Test func updateAVAudioTimeWithPreferredDeltaSlowsLargeNegativeSourceDrift() throws {
        let packetDuration = 0.023
        var timestamp = RTMPTimestamp<AVAudioTime>()
        #expect(timestamp.update(.init(hostTime: AVAudioTime.hostTime(forSeconds: 100.000)), preferredDelta: packetDuration) == 0)
        #expect(timestamp.update(.init(hostTime: AVAudioTime.hostTime(forSeconds: 100.023)), preferredDelta: packetDuration) == 23)
        #expect(timestamp.update(.init(hostTime: AVAudioTime.hostTime(forSeconds: 99.923)), preferredDelta: packetDuration) == 18)
        #expect(abs(timestamp.updatedAt - 100.041) < 0.001)
    }

    @Test func updateAVAudioTimePreferredDeltaKeeps48kAACCadence() throws {
        // AAC 1024 mono @48k → 21.333ms/pkt。來源以真實封包節奏前進時，preferredDelta
        // 路徑（updatedAt 以整數 wire 累加、非 snap 到來源）必須維持 21/21/22。
        //
        // 注意：不可用「持續偏離」的來源（例如 20/20/37、均值 ~26ms）期待全程 21/22——
        // 真碼對持續 drift 有刻意的慢速修正（tolerance 80ms、每包最多 +5ms），累積約
        // 20 包後就會往來源靠。jitter 抑制由 44100 的
        // updateAVAudioTimeWithPreferredDelta 覆蓋；本測試聚焦 48k cadence 本身。
        let packetDuration = 1024.0 / 48000.0
        var timestamp = RTMPTimestamp<AVAudioTime>()
        var wires: [UInt32] = []
        var source = 100.0
        for index in 0..<12 {
            if index > 0 { source += packetDuration }
            wires.append(timestamp.update(.init(hostTime: AVAudioTime.hostTime(forSeconds: source)), preferredDelta: packetDuration))
        }
        let deltas = Array(wires.dropFirst())
        #expect(deltas.allSatisfy { $0 == 21 || $0 == 22 }, "wire deltas must be 21/22 only, got \(deltas)")
        let mean = Double(deltas.reduce(0) { $0 + Int($1) }) / Double(deltas.count)
        #expect(abs(mean - 21.3333) < 0.2, "mean wire delta ~21.33ms, got \(mean)")
    }

    @Test func updateAVAudioTimeWithoutPreferredDeltaFollowsSourceCadence() throws {
        // packetDuration nil（如 sampleRate <= 0）時，wire 直接跟隨來源
        // 20/20/37ms 節奏——這是診斷用的來源簽名，與 preferredDelta 路徑成對。
        var timestamp = RTMPTimestamp<AVAudioTime>()
        var wires: [UInt32] = []
        var source = 100.0
        for index in 0..<7 {
            if index > 0 { source += [0.020, 0.020, 0.037][(index - 1) % 3] }
            wires.append(timestamp.update(.init(hostTime: AVAudioTime.hostTime(forSeconds: source))))
        }
        #expect(wires == [0, 20, 20, 37, 20, 20, 37])
    }

    @Test func updateAVAudioTimePreferredDeltaAllowJumpUsesSourceOnLargeDrift() throws {
        // allowJump（音訊 A/V resync 用）+ 來源大幅前跳 > jump threshold(500ms)：
        // 直接採用來源 delta 一次跳進同步範圍，而非被 drift 修正慢慢追。
        let packetDuration = 0.023
        var timestamp = RTMPTimestamp<AVAudioTime>()
        #expect(timestamp.update(.init(hostTime: AVAudioTime.hostTime(forSeconds: 100.000)), preferredDelta: packetDuration) == 0)
        // +600ms 前跳，drift 577ms > 500ms → jump 至來源 delta 600ms。
        #expect(timestamp.update(.init(hostTime: AVAudioTime.hostTime(forSeconds: 100.600)), allowJump: true, preferredDelta: packetDuration) == 600)
        #expect(abs(timestamp.updatedAt - 100.600) < 0.001)
    }
}
