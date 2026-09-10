import Accelerate
import AVFoundation
import CoreAudio
import CoreMedia
import Foundation

final class AudioRingBuffer: @unchecked Sendable {
    // 容量 24×1024 = 24576 samples ≈ 557ms @44.1k（原 16×1024≈371ms）。
    // 調大吸收更多 producer 節奏抖動，減少 PTS gap 造成的 skip 補 silence
    //（斷續的聽覺來源）。直播延遲本就 ~1s，多 186ms 可忽略。
    private static let bufferCounts: UInt32 = 24
    private static let numSamples: UInt32 = 1024
    private static let maxCapacity: Int = Int(AudioRingBuffer.numSamples * AudioRingBuffer.bufferCounts)

    var counts: Int {
        lock()
        defer { unlock() }
        return calculateCounts()
    }

    private func calculateCounts() -> Int {
        storedSamples + skip
    }

    private var head = 0
    private var tail = 0
    private var skip = 0
    private var storedSamples = 0
    // 累計診斷計數（AHealth 用）：由呼叫端取樣後自行算 delta。
    private var alignDropped = 0
    private var alignInserted = 0
    private var overflowDropped = 0
    private var skipInserted = 0
    private var alignFireCount = 0
    private var lastAlignDiff = 0
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

    // MARK: 診斷計數（累計）

    var alignDroppedSamples: Int { lock(); defer { unlock() }; return alignDropped }
    var alignInsertedSamples: Int { lock(); defer { unlock() }; return alignInserted }
    var overflowDroppedSamples: Int { lock(); defer { unlock() }; return overflowDropped }
    var skipInsertedSamples: Int { lock(); defer { unlock() }; return skipInserted }
    /// align 實際動手的次數（丟或補），用來判斷死區外是否仍在持續修正。
    var alignFireCountValue: Int { lock(); defer { unlock() }; return alignFireCount }
    /// 最近一次 align 看到的偏差（position - current，input 樣本單位；正=落後）。
    var lastAlignDiffValue: Int { lock(); defer { unlock() }; return lastAlignDiff }

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
        // PTS gap 直接以 0 樣本寫進尾端（正確位置），不再用 `skip` 搬到佇列
        // 最前面——否則已緩衝的樣本會被整體往後推（#4 修正）。
        let gap = max(Int(targetSampleTime - sampleTime), 0)
        if gap > 0 {
            appendZeros(gap)
            skipInserted += gap
        }
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
        let gap = max(Int(when.sampleTime - sampleTime), 0)
        if gap > 0 {
            appendZeros(gap)
            skipInserted += gap
        }
        appendInternal(inputBuffer)
        unlock()
    }

    func render(_ inNumberFrames: UInt32, ioData: UnsafeMutablePointer<AudioBufferList>?, offset: Int = 0) -> OSStatus {
        lock()
        defer { unlock() }
        return renderInternal(inNumberFrames, ioData: ioData, offset: offset)
    }

    /// 跨軌時間對齊（ReplayKit .audioApp / .audioMic 分軌交付，共用同一來源時鐘）。
    /// render 前以 main track 的 sampleTime 為基準，把本緩衝區的消耗前端對齊到
    /// `position`。兩軌的 `when.sampleTime` 都是來源端 PTS 派生（anchor 設在來源
    /// PTS 上、frame 間距由來源 PTS 推進），本質上落在同一條軸上 —— 這裡把「先到
    /// 先混」忽略掉的這個關係重新建立，來源 PTS 不再被丟棄：
    /// - 前端早於 `position` → 過期樣本（capture 時間早於目前混音位置）直接丟棄，
    ///   避免舊音訊以錯誤的相對位置混入，正是回音/梳狀濾波的來源。
    /// - 前端晚於 `position` → 前方補 silence，靜音到對齊點再開始輸出。
    /// 呼叫端（AudioMixerByMultiTrack.render）在 serial queue 上，本方法持鎖與
    /// append/render 互斥。mixer 的 `buffers[track]` 是以 outputFormat 建立的，
    /// 故 `position` 與本緩衝區的 `sampleTime` 同為 output 取樣率單位。
    func align(to position: Int64) {
        lock()
        defer { unlock() }
        let current = sampleTime - Int64(calculateCounts())
        // behind > 0：本軌緩衝區起點落後播放頭（要補靜音）；
        // behind < 0：超前（要丟 stale）。
        let behind = position - current
        lastAlignDiff = Int(behind)
        // Deadband：門檻內視為量測抖動，不修正，避免每幀微丟/微補造成細碎斷音。
        if behind > Self.alignDeadband {
            // behind > 0：播放頭在資料起點之後 → 本軌過期 → 丟棄 stale。
            // 先消耗 pending silence（skip），再消耗資料。
            var toDrop = behind
            let skipToDrop = min(Int64(skip), toDrop)
            skip -= Int(skipToDrop)
            toDrop -= skipToDrop
            while 0 < toDrop {
                let numSamples = min(Int(toDrop), Int(outputBuffer.frameCapacity) - tail)
                tail = (tail + numSamples) % Int(outputBuffer.frameCapacity)
                storedSamples -= numSamples
                alignDropped += numSamples
                toDrop -= Int64(numSamples)
            }
            alignFireCount += 1
            if Self.alignLogThreshold <= behind, logger.isEnabledFor(level: .trace) {
                logger.trace("AudioRingBuffer.align: dropped \(behind) stale samples to align at \(position)")
            }
        } else if behind < -Self.alignDeadband {
            // behind < 0：播放頭在資料起點之前 → 有空隙 → 補 silence。
            let lead = -behind
            skip += Int(lead)
            alignInserted += Int(lead)
            alignFireCount += 1
            if Self.alignLogThreshold <= lead, logger.isEnabledFor(level: .trace) {
                logger.trace("AudioRingBuffer.align: inserted \(lead) silence to align at \(position)")
            }
        }
    }

    /// align 僅在調整量 ≥ 此值（約 93ms @44.1k）時記錄 trace，
    /// 避免熱路徑上的 per-frame 日誌寫入。
    private static let alignLogThreshold: Int64 = 4096

    /// align 死區（樣本數，input 率）：|discrepancy| 在此門檻內視為量測抖動，
    /// 不修正，避免每幀微丟/微補造成細碎斷音。約 256 samples ≈ 5.8ms @44.1k。
    private static let alignDeadband: Int64 = 256

    private func renderInternal(_ inNumberFrames: UInt32, ioData: UnsafeMutablePointer<AudioBufferList>?, offset: Int = 0) -> OSStatus {
        guard Int(inNumberFrames) <= calculateCounts() else { return -1 }
        if 0 < skip {
            let numSamples = min(Int(inNumberFrames), skip)
            guard let bufferList = UnsafeMutableAudioBufferListPointer(ioData) else {
                return -1
            }
            zeroBuffer(bufferList, numSamples: numSamples, offset: offset)
            skip -= numSamples
            if 0 < inNumberFrames - UInt32(numSamples) {
                return renderInternal(inNumberFrames - UInt32(numSamples), ioData: ioData, offset: offset + numSamples)
            }
            return noErr
        }
        guard 0 < storedSamples else { return -1 }
        let numSamples = min(Int(inNumberFrames), Int(outputBuffer.frameCapacity) - tail, storedSamples)
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
        }
        storedSamples -= numSamples
        if 0 < inNumberFrames - UInt32(numSamples) {
            return renderInternal(inNumberFrames - UInt32(numSamples), ioData: ioData, offset: offset + numSamples)
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
        storedSamples = 0
        sampleTime = 0
        unlock()
    }

    @inline(__always)
    private func appendInternal(_ audioPCMBuffer: AVAudioPCMBuffer, offset: Int = 0) {
        let frameLength = Int(audioPCMBuffer.frameLength)
        guard offset < frameLength else { return }
        let capacity = Int(outputBuffer.frameCapacity)
        let effectiveOffset = max(offset, frameLength - capacity)
        sampleTime += Int64(effectiveOffset - offset)
        let numSamples = min(frameLength - effectiveOffset, capacity - head)
        guard numSamples > 0 else { return }
        discardStoredSamples(max(0, storedSamples + numSamples - capacity))
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
                  let src = audioPCMBuffer.int16ChannelData?[0].advanced(by: effectiveOffset * channelCount) else { return }
            memcpy(dst, src, copyBytes)
        } else {
            for i in 0..<channelCount {
                guard let dst = outputBuffer.int16ChannelData?[i].advanced(by: head),
                      let src = audioPCMBuffer.int16ChannelData?[i].advanced(by: effectiveOffset) else { continue }
                memcpy(dst, src, numSamples * bytesPerSample)
            }
        }
        head += numSamples
        storedSamples += numSamples
        sampleTime += Int64(numSamples)
        if head == capacity {
            head = 0
            let remaining = frameLength - effectiveOffset - numSamples
            if remaining > 0 {
                appendInternal(audioPCMBuffer, offset: effectiveOffset + numSamples)
            }
        }
    }

    /// 把 `count` 個 0 樣本寫進環形緩衝區尾端（PTS gap 的正確位置）並推進
    /// sampleTime。超過容量時只保留最後 capacity 個 0，前段直接推進時間軸。
    private func appendZeros(_ count: Int) {
        guard count > 0 else { return }
        let capacity = Int(outputBuffer.frameCapacity)
        if count > capacity {
            sampleTime += Int64(count - capacity)
        }
        var remaining = min(count, capacity)
        while remaining > 0 {
            let numSamples = min(remaining, capacity - head)
            zeroRingSamples(at: head, count: numSamples)
            head = (head + numSamples) % capacity
            storedSamples += numSamples
            sampleTime += Int64(numSamples)
            remaining -= numSamples
            discardStoredSamples(max(0, storedSamples - capacity))
        }
    }

    /// 把環形緩衝區 [offset, offset+count) 範圍的樣本清零。
    private func zeroRingSamples(at offset: Int, count: Int) {
        let channelCount = Int(inputFormat.channelCount)
        let bytesPerSample: Int
        switch inputFormat.commonFormat {
        case .pcmFormatInt16: bytesPerSample = 2
        case .pcmFormatInt32: bytesPerSample = 4
        case .pcmFormatFloat32: bytesPerSample = 4
        default: return
        }
        if inputFormat.isInterleaved {
            guard let dst = outputBuffer.int16ChannelData?[0] else { return }
            memset(dst.advanced(by: offset * channelCount), 0, count * channelCount * bytesPerSample)
        } else {
            for i in 0..<channelCount {
                guard let dst = outputBuffer.int16ChannelData?[i] else { continue }
                memset(dst.advanced(by: offset), 0, count * bytesPerSample)
            }
        }
    }

    private func discardStoredSamples(_ count: Int) {
        var remaining = min(count, storedSamples)
        let capacity = Int(outputBuffer.frameCapacity)
        while 0 < remaining {
            let numSamples = min(remaining, capacity - tail)
            tail = (tail + numSamples) % capacity
            storedSamples -= numSamples
            overflowDropped += numSamples
            remaining -= numSamples
        }
    }
}
