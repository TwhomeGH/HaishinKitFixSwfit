import Accelerate
import AVFoundation
import CoreAudio
import CoreMedia
import Foundation

final class AudioRingBuffer {
    private static let bufferCounts: UInt32 = 16
    private static let numSamples: UInt32 = 1024
    private static let maxCapacity: Int = Int(AudioRingBuffer.numSamples * AudioRingBuffer.bufferCounts)

    var counts: Int {
        lock()
        defer { unlock() }
        if tail <= head {
            return head - tail + skip
        }
        return Int(outputBuffer.frameCapacity) - tail + head + skip
    }

    private var head = 0
    private var tail = 0
    private var skip = 0
    private var sampleTime: AVAudioFramePosition = 0
    private var inputFormat: AVAudioFormat
    private var inputBuffer: AVAudioPCMBuffer
    private var outputBuffer: AVAudioPCMBuffer
    private var unfairLock = os_unfair_lock()

    init?(_ inputFormat: AVAudioFormat, bufferCounts: UInt32 = AudioRingBuffer.bufferCounts) {
        let capacity = min(Int(Self.numSamples * bufferCounts), AudioRingBuffer.maxCapacity)
        guard
            let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: Self.numSamples) else {
            return nil
        }
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(capacity)) else {
            return nil
        }
        self.inputFormat = inputFormat
        self.inputBuffer = inputBuffer
        self.outputBuffer = outputBuffer
    }

    private func lock() { os_unfair_lock_lock(&unfairLock) }
    private func unlock() { os_unfair_lock_unlock(&unfairLock) }

    func isDataAvailable(_ inNumberFrames: UInt32) -> Bool {
        return inNumberFrames <= counts
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else {
            return
        }
        let numSamples = Int(sampleBuffer.numSamples)
        guard numSamples <= AudioRingBuffer.maxCapacity else {
            skip += numSamples
            return
        }
        let targetSampleTime: CMTimeValue
        if sampleBuffer.presentationTimeStamp.timescale == Int32(inputBuffer.format.sampleRate) {
            targetSampleTime = sampleBuffer.presentationTimeStamp.value
        } else {
            targetSampleTime = Int64(Double(sampleBuffer.presentationTimeStamp.value) * inputBuffer.format.sampleRate / Double(sampleBuffer.presentationTimeStamp.timescale))
        }
        lock()
        if sampleTime == 0 {
            sampleTime = targetSampleTime
        }
        if inputBuffer.frameCapacity < AVAudioFrameCount(numSamples) {
            if let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(numSamples)) {
                self.inputBuffer = buffer
            }
        }
        inputBuffer.frameLength = AVAudioFrameCount(numSamples)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(numSamples),
            into: inputBuffer.mutableAudioBufferList
        )
        if status == noErr && kLinearPCMFormatFlagIsBigEndian == ((sampleBuffer.formatDescription?.audioStreamBasicDescription?.mFormatFlags ?? 0) & kLinearPCMFormatFlagIsBigEndian) {
            if inputFormat.isInterleaved {
                switch inputFormat.commonFormat {
                case .pcmFormatInt16:
                    let length = sampleBuffer.dataBuffer?.dataLength ?? 0
                    var image = vImage_Buffer(data: inputBuffer.mutableAudioBufferList[0].mBuffers.mData, height: 1, width: vImagePixelCount(length / 2), rowBytes: length)
                    vImageByteSwap_Planar16U(&image, &image, vImage_Flags(kvImageNoFlags))
                default:
                    break
                }
            }
        }
        skip = max(Int(targetSampleTime - sampleTime), 0)
        sampleTime += Int64(skip)
        appendInternal(inputBuffer)
        unlock()
    }

    func append(_ audioPCMBuffer: AVAudioPCMBuffer, when: AVAudioTime) {
        let numSamples = Int(audioPCMBuffer.frameLength)
        guard numSamples <= AudioRingBuffer.maxCapacity else { return }
        lock()
        if sampleTime == 0 {
            sampleTime = when.sampleTime
        }
        if inputBuffer.frameCapacity < audioPCMBuffer.frameCapacity {
            if let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: audioPCMBuffer.frameCapacity) {
                self.inputBuffer = buffer
            }
        }
        inputBuffer.frameLength = audioPCMBuffer.frameLength
        _ = inputBuffer.copy(audioPCMBuffer)
        skip = Int(max(when.sampleTime - sampleTime, 0))
        sampleTime += Int64(skip)
        appendInternal(inputBuffer)
        unlock()
    }

    func render(_ inNumberFrames: UInt32, ioData: UnsafeMutablePointer<AudioBufferList>?, offset: Int = 0) -> OSStatus {
        lock()
        defer { unlock() }
        return renderInternal(inNumberFrames, ioData: ioData, offset: offset)
    }

    private func renderInternal(_ inNumberFrames: UInt32, ioData: UnsafeMutablePointer<AudioBufferList>?, offset: Int = 0) -> OSStatus {
        if 0 < skip {
            let numSamples = min(Int(inNumberFrames), skip)
            guard let bufferList = UnsafeMutableAudioBufferListPointer(ioData) else {
                return -1
            }
            zeroBuffer(bufferList, numSamples: numSamples, offset: offset)
            skip -= numSamples
            if 0 < inNumberFrames - UInt32(numSamples) {
                return renderInternal(inNumberFrames - UInt32(numSamples), ioData: ioData, offset: numSamples)
            }
            return noErr
        }
        guard head != tail else { return -1 }
        let numSamples = min(Int(inNumberFrames), Int(outputBuffer.frameCapacity) - tail)
        guard numSamples > 0 else { return -1 }
        guard let bufferList = UnsafeMutableAudioBufferListPointer(ioData) else {
            return -1
        }
        let channelCount = Int(inputFormat.channelCount)
        let bytesPerSample: Int
        switch inputFormat.commonFormat {
        case .pcmFormatInt16: bytesPerSample = 2
        case .pcmFormatInt32: bytesPerSample = 4
        case .pcmFormatFloat32: bytesPerSample = 4
        default: return -1
        }
        let copyBytes = numSamples * channelCount * bytesPerSample
        if inputFormat.isInterleaved {
            guard let dst = bufferList[0].mData,
                  let src = outputBuffer.int16ChannelData?[0].advanced(by: tail * channelCount) else { return -1 }
            memcpy(dst.advanced(by: offset * channelCount * bytesPerSample), src, copyBytes)
        } else {
            for i in 0..<channelCount {
                guard let dst = bufferList[i].mData,
                      let src = outputBuffer.int16ChannelData?[i].advanced(by: tail) else { continue }
                memcpy(dst.advanced(by: offset * bytesPerSample), src, numSamples * bytesPerSample)
            }
        }
        tail += numSamples
        if tail == Int(outputBuffer.frameCapacity) {
            tail = 0
            if 0 < inNumberFrames - UInt32(numSamples) {
                return renderInternal(inNumberFrames - UInt32(numSamples), ioData: ioData, offset: numSamples)
            }
        }
        return noErr
    }

    private func zeroBuffer(_ bufferList: UnsafeMutableAudioBufferListPointer, numSamples: Int, offset: Int) {
        if inputFormat.isInterleaved {
            let channelCount = Int(inputFormat.channelCount)
            switch inputFormat.commonFormat {
            case .pcmFormatInt16:
                bufferList[0].mData?.assumingMemoryBound(to: Int16.self).advanced(by: offset * channelCount).update(repeating: 0, count: numSamples)
            case .pcmFormatInt32:
                bufferList[0].mData?.assumingMemoryBound(to: Int32.self).advanced(by: offset * channelCount).update(repeating: 0, count: numSamples)
            case .pcmFormatFloat32:
                bufferList[0].mData?.assumingMemoryBound(to: Float32.self).advanced(by: offset * channelCount).update(repeating: 0, count: numSamples)
            default:
                break
            }
        } else {
            for i in 0..<Int(inputFormat.channelCount) {
                switch inputFormat.commonFormat {
                case .pcmFormatInt16:
                    bufferList[i].mData?.assumingMemoryBound(to: Int16.self).advanced(by: offset).update(repeating: 0, count: numSamples)
                case .pcmFormatInt32:
                    bufferList[i].mData?.assumingMemoryBound(to: Int32.self).advanced(by: offset).update(repeating: 0, count: numSamples)
                case .pcmFormatFloat32:
                    bufferList[i].mData?.assumingMemoryBound(to: Float32.self).advanced(by: offset).update(repeating: 0, count: numSamples)
                default:
                    break
                }
            }
        }
    }

    func reset() {
        lock()
        head = 0
        tail = 0
        skip = 0
        sampleTime = 0
        unlock()
    }

    @inline(__always)
    private func appendInternal(_ audioPCMBuffer: AVAudioPCMBuffer, offset: Int = 0) {
        let frameLength = Int(audioPCMBuffer.frameLength)
        guard offset < frameLength else { return }
        let capacity = Int(outputBuffer.frameCapacity)
        let numSamples = min(frameLength - offset, capacity - head)
        guard numSamples > 0 else { return }
        let channelCount = Int(inputFormat.channelCount)
        let bytesPerSample: Int
        switch inputFormat.commonFormat {
        case .pcmFormatInt16: bytesPerSample = 2
        case .pcmFormatInt32: bytesPerSample = 4
        case .pcmFormatFloat32: bytesPerSample = 4
        default: return
        }
        let copyBytes = numSamples * channelCount * bytesPerSample
        if inputFormat.isInterleaved {
            guard let dst = outputBuffer.int16ChannelData?[0].advanced(by: head * channelCount),
                  let src = audioPCMBuffer.int16ChannelData?[0].advanced(by: offset * channelCount) else { return }
            memcpy(dst, src, copyBytes)
        } else {
            for i in 0..<channelCount {
                guard let dst = outputBuffer.int16ChannelData?[i].advanced(by: head),
                      let src = audioPCMBuffer.int16ChannelData?[i].advanced(by: offset) else { continue }
                memcpy(dst, src, numSamples * bytesPerSample)
            }
        }
        head += numSamples
        sampleTime += Int64(numSamples)
        if head == capacity {
            head = 0
            let remaining = frameLength - offset - numSamples
            if remaining > 0 {
                appendInternal(audioPCMBuffer, offset: offset + numSamples)
            }
        }
    }
}
