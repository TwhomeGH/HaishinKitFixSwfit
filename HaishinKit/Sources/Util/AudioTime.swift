import AVFoundation
import Foundation

/// A helper class for interoperating between AVAudioTime and CMTime.
/// Conversion fails without hostTime on the AVAudioTime side, and cannot be saved with AVAssetWriter.
final class AudioTime {
    var at: AVAudioTime {
        let now = AVAudioTime(sampleTime: sampleTime, atRate: sampleRate)
        guard let anchorTime else {
            return now
        }
        return now.extrapolateTime(fromAnchor: anchorTime) ?? now
    }

    /// 真實時間版本的 `at`：hostTime 用目前 wall-clock（`mach_absolute_time`）。
    /// 消耗軸（`at`）在系統卡住/停滯後會永久落後真實時間，導致 RTMPStream 的
    /// resync 反覆觸發、audio wire 永久錯位；改用真實時間後，audio 時間基準與
    /// video（來源 PTS hostTime）一致，卡住恢復後自然回到正確位置。
    var realTimeAt: AVAudioTime {
        AVAudioTime(hostTime: mach_absolute_time(), sampleTime: sampleTime, atRate: sampleRate)
    }

    var hasAnchor: Bool {
        return anchorTime != nil
    }

    private var sampleRate: Double = 0.0
    private var anchorTime: AVAudioTime?
    private var sampleTime: AVAudioFramePosition = 0

    func advanced(_ count: AVAudioFramePosition) {
        sampleTime += count
    }

    func anchor(_ time: CMTime, sampleRate: Double) {
        guard anchorTime == nil else {
            return
        }
        self.sampleRate = sampleRate
        if time.timescale == Int32(sampleRate) {
            sampleTime = time.value
        } else {
            // ReplayKit .appAudio
            sampleTime = Int64(Double(time.value) * sampleRate / Double(time.timescale))
        }
        anchorTime = .init(hostTime: AVAudioTime.hostTime(forSeconds: time.seconds), sampleTime: sampleTime, atRate: sampleRate)
    }

    func anchor(_ time: AVAudioTime) {
        guard anchorTime == nil else {
            return
        }
        sampleRate = time.sampleRate
        sampleTime = time.sampleTime
        anchorTime = time
    }

    func reset() {
        sampleRate = 0.0
        sampleTime = 0
        anchorTime = nil
    }
}
