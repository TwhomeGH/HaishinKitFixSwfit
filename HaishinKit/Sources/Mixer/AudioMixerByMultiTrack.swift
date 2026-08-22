import AVFoundation
import CoreAudio
import Foundation

final class AudioMixerByMultiTrack: AudioMixer {
    private static let defaultSampleTime: AVAudioFramePosition = 0

    // 專用 serial queue：所有音訊處理（append→convert→mix→AudioUnitRender）
    // 都排到這裡執行，MediaMixer actor 的 append 立即返回。convert 迴圈與
    // AudioUnitRender 不再佔用 MediaMixer actor，video 與 audio 在 actor 上
    // 互不阻塞（治本：消除「audio convert 霸佔 actor → video 卡頓」的耦合）。
    private let queue = DispatchQueue(label: "com.haishinkit.HaishinKit.AudioMixerByMultiTrack")

    weak var delegate: (any AudioMixerDelegate)?

    // settings 可能被 MediaMixer actor 讀寫，用 lock 保護；內部處理統一走
    // _settings（queue 上），對外 getter/setter 用 lock。
    private let lock = NSLock()
    private var _settings = AudioMixerSettings.default
    var settings: AudioMixerSettings {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _settings
        }
        set {
            lock.lock()
            let oldValue = _settings
            _settings = newValue
            lock.unlock()
            queue.async { [weak self] in
                self?.applySettings(newValue, previous: oldValue)
            }
        }
    }
    var inputFormats: [UInt8: AVAudioFormat] {
        lock.lock()
        defer { lock.unlock() }
        return tracks.compactMapValues { $0.inputFormat }
    }

    /// 套用新的 mixer settings（必須在 queue 上執行，因為會重建 outputFormat）。
    private func applySettings(_ newValue: AudioMixerSettings, previous: AudioMixerSettings) {
        if newValue.isEchoCancellationEnabled != previous.isEchoCancellationEnabled
            || newValue.echoCancellationReferenceTrack != previous.echoCancellationReferenceTrack {
            echoCancelers.forEach { $0.reset() }
        }
        if let inSourceFormat, newValue.invalidateOutputFormat(previous) {
            outputFormat = newValue.makeOutputFormat(inSourceFormat)
        }
        for (id, trackSettings) in newValue.tracks {
            tracks[id]?.settings = trackSettings
            try? mixerNode?.update(volume: trackSettings.volume, bus: id, scope: .input)
        }
    }

    private(set) var outputFormat: AVAudioFormat? {
        didSet {
            guard let outputFormat, outputFormat != oldValue else {
                return
            }
            for id in tracks.keys {
                buffers[id] = .init(outputFormat)
                tracks[id] = .init(id: id, outputFormat: outputFormat)
                tracks[id]?.delegate = self
            }
            echoCancelers = (0..<Int(outputFormat.channelCount)).map { _ in AudioEchoCanceler() }
            echoScratchBuffer = .init(pcmFormat: outputFormat, frameCapacity: kAudioMixerTrack_frameCapacity)
        }
    }
    private var inSourceFormat: CMFormatDescription? {
        didSet {
            guard inSourceFormat != oldValue else {
                return
            }
            outputFormat = _settings.makeOutputFormat(inSourceFormat)
        }
    }
    private var tracks: [UInt8: AudioMixerTrack<AudioMixerByMultiTrack>] = [:] {
        didSet {
            tryToSetupAudioNodes()
        }
    }
    private var anchor: AVAudioTime?
    private var buffers: [UInt8: AudioRingBuffer] = [:] {
        didSet {
            if logger.isEnabledFor(level: .trace) {
                logger.trace(buffers)
            }
        }
    }
    private var mixerNode: MixerNode?
    private var sampleTime: AVAudioFramePosition = AudioMixerByMultiTrack.defaultSampleTime
    private var outputNode: OutputNode?
    // 各軌最近一次輸出的「幀結束位置」（when.sampleTime + frameLength）。
    // 用於 main 軌靜默時由其他軌推進混音時間軸。
    private var lastOutputPosition: [UInt8: Int64] = [:]
    // 物理回音消除（NLMS AEC）：以 echoCancellationReferenceTrack（App 軌）為
    // reference、main track（mic）為 target，混音前對 mic 幀相消（喇叭外放被
    // mic 收音造成的雙重重疊）。每 channel 一個 canceler；僅在 serial queue 上使用。
    private var echoCancelers: [AudioEchoCanceler] = []
    private var echoScratchBuffer: AVAudioPCMBuffer?

    private let inputRenderCallback: AURenderCallback = { (inRefCon: UnsafeMutableRawPointer, _: UnsafeMutablePointer<AudioUnitRenderActionFlags>, _: UnsafePointer<AudioTimeStamp>, inBusNumber: UInt32, inNumberFrames: UInt32, ioData: UnsafeMutablePointer<AudioBufferList>?) in
        let audioMixer = Unmanaged<AudioMixerByMultiTrack>.fromOpaque(inRefCon).takeUnretainedValue()
        let status = audioMixer.render(UInt8(inBusNumber), inNumberFrames: inNumberFrames, ioData: ioData)
        guard status == noErr else {
            audioMixer.delegate?.audioMixer(audioMixer, errorOccurred: .unableToProvideInputData)
            return noErr
        }
        return status
    }

    deinit {
        if let mixerNode = mixerNode {
            AudioOutputUnitStop(mixerNode.audioUnit)
        }
        if let outputNode = outputNode {
            AudioOutputUnitStop(outputNode.audioUnit)
        }
    }

    func append(_ track: UInt8, buffer: CMSampleBuffer) {
        queue.async { [weak self] in
            guard let self else { return }
            if self._settings.mainTrack == track {
                self.inSourceFormat = buffer.formatDescription
            }
            self.track(for: track)?.append(buffer)
        }
    }

    func append(_ track: UInt8, buffer: AVAudioPCMBuffer, when: AVAudioTime) {
        queue.async { [weak self] in
            guard let self else { return }
            if self._settings.mainTrack == track {
                self.inSourceFormat = buffer.format.formatDescription
            }
            self.track(for: track)?.append(buffer, when: when)
        }
    }

    private func tryToSetupAudioNodes() {
        do {
            try setupAudioNodes()
        } catch {
            logger.error(error)
            delegate?.audioMixer(self, errorOccurred: .failedToMix(error: error))
        }
    }

    private func setupAudioNodes() throws {
        if let mixerNode {
            AudioOutputUnitStop(mixerNode.audioUnit)
        }
        if let outputNode {
            AudioOutputUnitStop(outputNode.audioUnit)
        }
        mixerNode = nil
        outputNode = nil
        guard let outputFormat else {
            return
        }
        sampleTime = Self.defaultSampleTime
        lastOutputPosition.removeAll()
        let mixerNode = try MixerNode(format: outputFormat)
        try mixerNode.update(busCount: tracks.count, scope: .input)
        let busCount = try mixerNode.busCount(scope: .input)
        for index in 0..<busCount {
            try mixerNode.enable(bus: UInt8(index), scope: .input, isEnabled: false)
        }
        for (bus, track) in tracks {
            try mixerNode.enable(bus: bus, scope: .input, isEnabled: true)
            try mixerNode.update(format: outputFormat, bus: bus, scope: .input)
            var callbackStruct = AURenderCallbackStruct(inputProc: inputRenderCallback,
                                                        inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
            try mixerNode.update(inputCallback: &callbackStruct, bus: bus)
            try mixerNode.update(volume: track.settings.volume, bus: bus, scope: .input)
        }
        try mixerNode.update(format: outputFormat, bus: 0, scope: .output)
        try mixerNode.update(volume: 1, bus: 0, scope: .output)
        let outputNode = try OutputNode(format: outputFormat)
        try outputNode.update(format: outputFormat, bus: 0, scope: .input)
        try outputNode.update(format: outputFormat, bus: 0, scope: .output)
        try mixerNode.connect(to: outputNode)
        try mixerNode.initializeAudioUnit()
        try outputNode.initializeAudioUnit()
        self.mixerNode = mixerNode
        self.outputNode = outputNode
        if logger.isEnabledFor(level: .info) {
            logger.info("mixerAudioUnit: \(mixerNode)")
        }
    }

    private func render(_ track: UInt8, inNumberFrames: UInt32, ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
        guard let buffer = buffers[track] else {
            return noErr
        }
        // 跨軌對齊（ReplayKit .audioApp / .audioMic）：兩軌的 `when.sampleTime`
        // 都是來源端 PTS 派生、共用同一來源時鐘，混音時非 main track 要以 main
        // track 的 sampleTime 對齊；否則「先到先混」會把兩軌的起始相位差與
        // 積壓以錯誤的相對位置混入 → 回音/撕裂。main track 是時鐘本身，不可
        // 對齊（對齊它會吃掉其內部來源 gap 的 silence 推進）。
        if track != _settings.mainTrack {
            buffer.align(to: sampleTime)
        }
        if buffer.counts == 0 {
            guard let bufferList = UnsafeMutableAudioBufferListPointer(ioData) else {
                return noErr
            }
            for i in 0..<bufferList.count {
                memset(bufferList[i].mData, 0, Int(bufferList[i].mDataByteSize))
            }
            return noErr
        }
        return buffer.render(inNumberFrames, ioData: ioData)
    }

    private func mix(numberOfFrames: AVAudioFrameCount) {
        guard let outputNode else {
            return
        }
        do {
            let buffer = try outputNode.render(numberOfFrames: numberOfFrames, sampleTime: sampleTime)
            let time = AVAudioTime(sampleTime: sampleTime, atRate: outputNode.format.sampleRate)
            if let anchor, let when = time.extrapolateTime(fromAnchor: anchor) {
                delegate?.audioMixer(self, didOutput: buffer.muted(settings.isMuted), when: when)
                sampleTime += Int64(numberOfFrames)
            }
        } catch {
            delegate?.audioMixer(self, errorOccurred: .failedToMix(error: error))
        }
    }

    private func track(for id: UInt8) -> AudioMixerTrack<AudioMixerByMultiTrack>? {
        if let track = tracks[id] {
            return track
        }
        guard let outputFormat else {
            return nil
        }
        let track = AudioMixerTrack<AudioMixerByMultiTrack>(id: id, outputFormat: outputFormat)
        track.delegate = self
        if let trackSettings = _settings.tracks[id] {
            track.settings = trackSettings
        }
        tracks[id] = track
        buffers[id] = .init(outputFormat)
        return track
    }
}

extension AudioMixerByMultiTrack: AudioMixerTrackDelegate {
    // MARK: AudioMixerTrackDelegate
    func track(_ track: AudioMixerTrack<AudioMixerByMultiTrack>, didOutput audioPCMBuffer: AVAudioPCMBuffer, when: AVAudioTime) {
        delegate?.audioMixer(self, track: track.id, didInput: audioPCMBuffer, when: when)
        let settings = _settings
        var bufferToAppend = audioPCMBuffer
        if settings.isEchoCancellationEnabled, let echo = resolveEchoTracks(settings) {
            if track.id == echo.reference {
                // reference（App 軌）：逐 channel 餵入回音參考歷史。
                let channelCount = min(Int(audioPCMBuffer.format.channelCount), echoCancelers.count)
                for ch in 0..<channelCount {
                    echoCancelers[ch].pushReference(extractChannel(audioPCMBuffer, channel: ch), at: when.sampleTime)
                }
            } else if track.id == echo.target {
                // target（mic 軌）：先做回音消除再進混音 buffer。
                if let canceled = makeEchoCanceledBuffer(audioPCMBuffer, when: when) {
                    bufferToAppend = canceled
                }
            }
        }
        buffers[track.id]?.append(bufferToAppend, when: when)
        lastOutputPosition[track.id] = when.sampleTime + Int64(audioPCMBuffer.frameLength)
        if settings.mainTrack == track.id {
            // main 軌：正常驅動混音時間軸。
            advanceMix(to: when, numberOfFrames: audioPCMBuffer.frameLength)
        } else if let mainLastOutput = lastOutputPosition[settings.mainTrack] {
            // main 軌落後（靜默）超過此幀位置 → 由其他軌推進，避免時間軸停滯
            // （例如 app 根本沒有在播放聲音，main=app 時 mic 仍要持續輸出）。
            // 只有 main 明確落後才推進，避免搶先觸發造成 mic 內容被 align 丟棄。
            if mainLastOutput < when.sampleTime {
                advanceMix(to: when, numberOfFrames: audioPCMBuffer.frameLength)
            }
        } else {
            // main 軌從未輸出（例如 app 完全沒有播放過）→ 由其他軌推進。
            advanceMix(to: when, numberOfFrames: audioPCMBuffer.frameLength)
        }
    }

    /// 推進混音時間軸到指定幀的位置，以區塊渲染（各軌由 align 對齊到正確位置）。
    /// 正常情形一幀一個區塊；長時間靜默後恢復會一次補齊（多為 silence，可接受）。
    private func advanceMix(to when: AVAudioTime, numberOfFrames: AVAudioFrameCount) {
        guard let outputNode else {
            return
        }
        let position = when.sampleTime
        let endPosition = position + Int64(numberOfFrames)
        if sampleTime == Self.defaultSampleTime {
            sampleTime = position
            anchor = when
        }
        guard endPosition > sampleTime else {
            return  // 此幀位置已被其他軌渲染過，避免重複混音。
        }
        while sampleTime < endPosition {
            let frames = AVAudioFrameCount(min(Int64(kAudioMixerTrack_frameCapacity), endPosition - sampleTime))
            mix(numberOfFrames: frames)
        }
    }

    /// 解析 AEC 的 (reference, target) 對：
    /// - reference：`echoCancellationReferenceTrack` 必須**顯式設定**（非
    ///   `UInt8.max`）並指向 app 音訊軌；未設定 → nil（AEC 停用）。不能自動
    ///   推導——兩軌的編號是呼叫端自訂的，自動猜測可能把 mic 誤當 reference。
    /// - target：兩軌情境下取「唯一非 reference 的軌」（mic）。**與 mainTrack
    ///   無關**——mainTrack 可能是 app 軌（混音時鐘），但 AEC target 永遠是
    ///   喇叭收音的那一軌。非兩軌（無法唯一判定）→ nil。
    private func resolveEchoTracks(_ settings: AudioMixerSettings) -> (reference: UInt8, target: UInt8)? {
        guard settings.echoCancellationReferenceTrack != UInt8.max else {
            return nil
        }
        let reference = settings.echoCancellationReferenceTrack
        let targets = tracks.keys.filter { $0 != reference }
        guard targets.count == 1, let target = targets.first else {
            return nil
        }
        return (reference, target)
    }

    func track(_ track: AudioMixerTrack<AudioMixerByMultiTrack>, errorOccurred error: AudioMixerError) {
        delegate?.audioMixer(self, errorOccurred: error)
    }
}

extension AudioMixerByMultiTrack {
    // MARK: 物理回音消除 helper

    /// 以 echoCanceler 逐 channel 消除 mic 幀的回音，寫入 scratch buffer 回傳；
    /// 任一前置條件不滿足時回傳 nil（呼叫端退回原幀）。
    private func makeEchoCanceledBuffer(_ buffer: AVAudioPCMBuffer, when: AVAudioTime) -> AVAudioPCMBuffer? {
        guard let scratch = echoScratchBuffer, Int(buffer.frameLength) <= scratch.frameCapacity, !echoCancelers.isEmpty else {
            return nil
        }
        scratch.frameLength = buffer.frameLength
        let channelCount = min(Int(buffer.format.channelCount), echoCancelers.count)
        for ch in 0..<channelCount {
            let channel = extractChannel(buffer, channel: ch)
            let canceled = echoCancelers[ch].process(channel, at: when.sampleTime)
            writeChannel(scratch, channel: ch, samples: canceled)
        }
        return scratch
    }

    /// 抽取指定 channel 的樣本為 [Float]（處理 int16/float32 × interleaved/non-interleaved）。
    private func extractChannel(_ buffer: AVAudioPCMBuffer, channel: Int) -> [Float] {
        let frames = Int(buffer.frameLength)
        var result = [Float](repeating: 0, count: frames)
        guard frames > 0, 0 <= channel, channel < Int(buffer.format.channelCount) else {
            return result
        }
        let plane = buffer.format.isInterleaved ? 0 : channel
        let stride = buffer.format.isInterleaved ? Int(buffer.format.channelCount) : 1
        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            guard let data = buffer.floatChannelData?[plane] else { return result }
            for i in 0..<frames {
                result[i] = data[i * stride + (buffer.format.isInterleaved ? channel : 0)]
            }
        case .pcmFormatInt16:
            guard let data = buffer.int16ChannelData?[plane] else { return result }
            for i in 0..<frames {
                result[i] = Float(data[i * stride + (buffer.format.isInterleaved ? channel : 0)]) / 32768.0
            }
        default:
            break
        }
        return result
    }

    /// 把 [Float] 寫回指定 channel（與 extractChannel 對應的格式）。
    private func writeChannel(_ buffer: AVAudioPCMBuffer, channel: Int, samples: [Float]) {
        let frames = min(samples.count, Int(buffer.frameCapacity))
        guard frames > 0, 0 <= channel, channel < Int(buffer.format.channelCount) else {
            return
        }
        let plane = buffer.format.isInterleaved ? 0 : channel
        let stride = buffer.format.isInterleaved ? Int(buffer.format.channelCount) : 1
        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            guard let data = buffer.floatChannelData?[plane] else { return }
            for i in 0..<frames {
                data[i * stride + (buffer.format.isInterleaved ? channel : 0)] = samples[i]
            }
        case .pcmFormatInt16:
            guard let data = buffer.int16ChannelData?[plane] else { return }
            for i in 0..<frames {
                data[i * stride + (buffer.format.isInterleaved ? channel : 0)] = Int16(clamping: Int((samples[i] * 32767.0).rounded()))
            }
        default:
            break
        }
    }
}
