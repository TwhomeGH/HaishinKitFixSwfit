import AVFoundation

/// 接收 MediaMixer 影音輸出與音訊工作階段事件的協定。
public protocol MediaMixerOutput: AnyObject, Sendable {
    /// 要接收的影像音軌 ID；UInt8.max 表示混合輸出，nil 表示不接收。
    var videoTrackId: UInt8? { get async }
    /// 要接收的音訊音軌 ID；UInt8.max 表示混合輸出，nil 表示不接收。
    var audioTrackId: UInt8? { get async }
    /// 收到 Mixer 交付的影像樣本。
    func mixer(_ mixer: MediaMixer, didOutput sampleBuffer: CMSampleBuffer)
    /// 收到 Mixer 交付的 PCM 音訊及其時間資訊。
    func mixer(_ mixer: MediaMixer, didOutput buffer: AVAudioPCMBuffer, when: AVAudioTime)
    /// 收到音訊工作階段事件。
    func mixer(_ mixer: MediaMixer, didReceiveAudioSessionEvent message: String) async
    /// 依媒體種類選擇要接收的音軌。
    func selectTrack(_ id: UInt8?, mediaType: CMFormatDescription.MediaType) async
}

public extension MediaMixerOutput {
    func mixer(_ mixer: MediaMixer, didReceiveAudioSessionEvent message: String) async {
    }
}
