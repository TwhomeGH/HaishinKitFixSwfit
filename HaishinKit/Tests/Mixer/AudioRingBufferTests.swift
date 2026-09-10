import AVFoundation
import Foundation
import Testing

@testable import HaishinKit

@Suite("AudioRingBuffer：append / render / align") struct AudioRingBufferTests {
    @Test("單聲道：append 920 樣本") func monoAppendSampleBuffer_920() throws {
        try appendSampleBuffer(920, channels: 1)
    }

    @Test("單聲道：append 1024 樣本") func monoAppendSampleBuffer_1024() throws {
        try appendSampleBuffer(1024, channels: 1)
    }

    @Test("單聲道：溢位後保留容量") func monoAppendSampleBuffer_overrun() throws {
        let numSamples = 1024 * 4
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 44100,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: 0xc,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        let format = AVAudioFormat(streamDescription: &asbd)
        let buffer = AudioRingBuffer(format!, bufferCounts: 3) // 1024 * 3
        guard
            let readBuffer = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(streamDescription: &asbd)!, frameCapacity: AVAudioFrameCount(1024)),
            let sinWave = CMAudioSampleBufferFactory.makeSinWave(44100, numSamples: numSamples, channels: 1) else {
            return
        }
        buffer?.append(sinWave)
        #expect(buffer?.counts == 1024 * 3)
        #expect(buffer?.isDataAvailable(1024) == true)
        #expect(buffer?.render(UInt32(1024), ioData: readBuffer.mutableAudioBufferList) == noErr)
        #expect(buffer?.isDataAvailable(1024) == true)
        #expect(buffer?.render(UInt32(1024), ioData: readBuffer.mutableAudioBufferList) == noErr)
        #expect(buffer?.isDataAvailable(1024) == true)
        #expect(buffer?.render(UInt32(1024), ioData: readBuffer.mutableAudioBufferList) == noErr)
        #expect(buffer?.isDataAvailable(1024) == false)
        #expect(buffer?.render(UInt32(1024), ioData: readBuffer.mutableAudioBufferList) != noErr)
    }

    @Test("雙聲道：append 920 樣本") func stereoAppendSampleBuffer_920() throws {
        try appendSampleBuffer(920, channels: 2)
    }

    @Test("雙聲道：append 1024 樣本") func stereoAppendSampleBuffer_1024() throws {
        try appendSampleBuffer(1024, channels: 2)
    }

    @Test("PCM 溢位：保留最新樣本") func appendAudioPCMBuffer_overrunKeepsNewestSamples() throws {
        let format = makeInt16Format()
        let ring = try #require(AudioRingBuffer(format, bufferCounts: 3))
        for index in 0..<4 {
            let (pcm, when) = makeInt16Buffer(format, sampleTime: AVAudioFramePosition(index * 1024), fill: Int16(index + 1))
            ring.append(pcm, when: when)
        }

        #expect(ring.counts == 1024 * 3)
        let read = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        for expected in [Int16(2), Int16(3), Int16(4)] {
            read.int16ChannelData?[0].update(repeating: 0, count: 1024)
            #expect(ring.render(1024, ioData: read.mutableAudioBufferList) == noErr)
            #expect(readInt16(read).allSatisfy { $0 == expected })
        }
        #expect(ring.counts == 0)
    }

    // MARK: align(to:)

    @Test("align：超前補靜音") func alignAheadInsertsSilence() throws {
        // 資料落在 position 1024，對齊到 0 → 前方先輸出 silence 再輸出資料。
        let format = makeInt16Format()
        let ring = try #require(AudioRingBuffer(format, bufferCounts: 3))
        let (pcm, when) = makeInt16Buffer(format, sampleTime: 1024, fill: 7)
        ring.append(pcm, when: when)
        ring.align(to: 0)
        let read = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        #expect(ring.render(1024, ioData: read.mutableAudioBufferList) == noErr)
        #expect(readInt16(read).allSatisfy { $0 == 0 })
        read.int16ChannelData?[0].update(repeating: 0, count: 1024)
        #expect(ring.render(1024, ioData: read.mutableAudioBufferList) == noErr)
        #expect(readInt16(read).allSatisfy { $0 == 7 })
    }

    @Test("align：落後丟過期樣本") func alignBehindDropsStaleData() throws {
        // 兩幀落在 [0,1024) 與 [1024,2048)，對齊到 1024 → 過期的第一幀被丟棄。
        let format = makeInt16Format()
        let ring = try #require(AudioRingBuffer(format, bufferCounts: 3))
        let (first, when0) = makeInt16Buffer(format, sampleTime: 0, fill: 3)
        let (second, when1) = makeInt16Buffer(format, sampleTime: 1024, fill: 9)
        ring.append(first, when: when0)
        ring.append(second, when: when1)
        ring.align(to: 1024)
        let read = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        #expect(ring.render(1024, ioData: read.mutableAudioBufferList) == noErr)
        #expect(readInt16(read).allSatisfy { $0 == 9 })
        #expect(ring.counts == 0)
    }

    @Test("align：超出範圍清空緩衝") func alignPastEndEmptiesBuffer() throws {
        let format = makeInt16Format()
        let ring = try #require(AudioRingBuffer(format, bufferCounts: 3))
        let (first, when0) = makeInt16Buffer(format, sampleTime: 0, fill: 3)
        let (second, when1) = makeInt16Buffer(format, sampleTime: 1024, fill: 9)
        ring.append(first, when: when0)
        ring.append(second, when: when1)
        ring.align(to: 4096)
        #expect(ring.counts == 0)
        let read = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        #expect(ring.render(1024, ioData: read.mutableAudioBufferList) != noErr)
    }

    @Test("align：調整開頭靜音") func alignAdjustsLeadingSilence() throws {
        // 先對齊補 1024 silence，再把對齊點推進到 512 → 前方 silence 縮減為 512。
        let format = makeInt16Format()
        let ring = try #require(AudioRingBuffer(format, bufferCounts: 3))
        let (pcm, when) = makeInt16Buffer(format, sampleTime: 1024, fill: 7)
        ring.append(pcm, when: when)
        ring.align(to: 0)
        #expect(ring.counts == 2048) // 1024 silence + 1024 data
        ring.align(to: 512)
        #expect(ring.counts == 1536) // 512 silence + 1024 data
        let read = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        #expect(ring.render(512, ioData: read.mutableAudioBufferList) == noErr)
        #expect(readInt16(read, count: 512).allSatisfy { $0 == 0 })
    }

    private func makeInt16Format() -> AVAudioFormat {
        .init(commonFormat: .pcmFormatInt16, sampleRate: 44100, channels: 1, interleaved: true)!
    }

    private func makeInt16Buffer(_ format: AVAudioFormat, sampleTime: AVAudioFramePosition, fill: Int16) -> (AVAudioPCMBuffer, AVAudioTime) {
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
        pcm.frameLength = 1024
        pcm.int16ChannelData?[0].update(repeating: fill, count: 1024)
        return (pcm, AVAudioTime(sampleTime: sampleTime, atRate: format.sampleRate))
    }

    private func readInt16(_ buffer: AVAudioPCMBuffer, count: Int = 1024) -> [Int16] {
        guard let channel = buffer.int16ChannelData else {
            return []
        }
        return [Int16](UnsafeBufferPointer(start: channel[0], count: count))
    }

    private func appendSampleBuffer(_ numSamples: Int, channels: UInt32) throws {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 44100,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: 0xc,
            mBytesPerPacket: 2 * channels,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2 * channels,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        let format = AVAudioFormat(streamDescription: &asbd)
        let buffer = AudioRingBuffer(format!, bufferCounts: 3)
        guard
            let readBuffer = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(streamDescription: &asbd)!, frameCapacity: AVAudioFrameCount(numSamples)),
            let sinWave = CMAudioSampleBufferFactory.makeSinWave(44100, numSamples: numSamples, channels: channels) else {
            return
        }
        let bufferList = UnsafeMutableAudioBufferListPointer(readBuffer.mutableAudioBufferList)
        readBuffer.frameLength = AVAudioFrameCount(numSamples)
        for _ in 0..<30 {
            buffer?.append(sinWave)
            readBuffer.int16ChannelData?[0].update(repeating: 0, count: numSamples)
            #expect(buffer?.render(UInt32(numSamples), ioData: readBuffer.mutableAudioBufferList) == noErr)
            #expect(try sinWave.dataBuffer?.dataBytes().bytes == Data(bytes: bufferList[0].mData!, count: numSamples * Int(channels) * 2).bytes)
        }
    }
}
