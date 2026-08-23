import AVFoundation
import Foundation

/// Constraints on the audio mixier settings.
public struct AudioMixerSettings: Codable, Sendable {
    /// The default value.
    public static let `default` = AudioMixerSettings()
    /// Maximum sampleRate supported by the system
    public static let maximumSampleRate: Float64 = 48000.0

    #if os(macOS)
    static let commonFormat: AVAudioCommonFormat = .pcmFormatFloat32
    #else
    static let commonFormat: AVAudioCommonFormat = .pcmFormatInt16
    #endif

    /// Specifies the sampleRate of audio output. A value of 0 will be the same as the main track source.
    public let sampleRate: Float64

    /// Specifies the channels of audio output. A value of 0 will be the same as the main track source.
    /// - Warning: If you are using IOStreamRecorder, please set it to 1 or 2. Otherwise, the audio will not be saved in local recordings.
    public let channels: UInt32

    /// Specifies the muted that indicates whether the audio output is muted.
    public var isMuted: Bool

    /// Specifies the main track number.
    ///
    /// Track 編號是呼叫端自訂的（`MediaMixer.append(_:track:)` 的參數），框架
    /// 沒有「0=mic / 1=app」的內建意義。main track 的語意：
    ///
    /// - **混音時鐘**：main track 的輸出驅動混音時間軸（`sampleTime`/anchor 由它
    ///   錨定），其他軌（跨軌 PTS 對齊）以它為基準。
    /// - **輸出格式**：mixer 的 `outputFormat` 由 main track 的來源格式決定
    ///   （`sampleRate`/`channels` 為 0 時沿用 main track 的格式）。
    /// - **輸出觸發**：main track 的輸出觸發 `mix()`（把各軌混合送出）；若 main
    ///   track 靜默（如 app 完全沒有在播放聲音），其他軌的輸出會接手推進時間軸，
    ///   **不會停滯**。
    ///
    /// 慣例：ReplayKit 情境**建議設 mic 軌**（持續產生音訊最穩）。mainTrack 是
    /// app 軌也可以（app 靜默時由 mic 接手推進），但這與 AEC 無關——AEC 的
    /// reference/target 已完全脫離 mainTrack（見 `echoCancellationReferenceTrack`）。
    public var mainTrack: UInt8

    /// Specifies the track settings.
    public var tracks: [UInt8: AudioMixerTrackSettings]

    /// Enables a minimal NLMS acoustic echo cancellation for multi-track mixing.
    ///
    /// 用途：ReplayKit 雙軌混音時，App 聲音從喇叭外放會被 mic 收音，混音後與
    /// App 原聲雙重重疊（物理回音）。開啟後以 `echoCancellationReferenceTrack`
    /// 為 reference（App 軌）、**非 reference 的另一軌**為 target（mic），在
    /// 混音前對 mic 做回音消除。
    ///
    /// ⚠️ 開啟前請務必設定 `echoCancellationReferenceTrack`（指向你的 app 音訊軌）。
    public var isEchoCancellationEnabled: Bool

    /// The track number of the echo reference — the app-audio track whose sound
    /// leaks into the microphone through the speaker.
    ///
    /// Track 編號是呼叫端自訂的（`MediaMixer.append(_:track:)` 的參數），框架不
    /// 預設 0=mic/1=app，也無法自動猜測——**必須顯式設定**（預設 `UInt8.max`
    /// 表示未設定，此時 AEC 停用）。
    ///
    /// - 框架範例 `SampleHandler`：`.audioApp`→track 1，設 `1`。
    /// - 你的 app 若 app→track 0、mic→track 1，則設 `0`。
    ///
    /// AEC 的 target（mic）會自動取「非 reference 的另一軌」，**與 mainTrack 無關**；
    /// 因此 mainTrack 不需要為了 AEC 特別指向 mic。但若超過兩軌（target 無法唯一
    /// 判定）AEC 會 no-op。
    public var echoCancellationReferenceTrack: UInt8

    /// Specifies the maximum number of channels supported by the system
    /// - Description: The maximum number of channels to be used when the number of channels is 0 (not set). More than 2 channels are not supported by the service. It is defined to prevent audio issues since recording does not support more than 2 channels.
    public var maximumNumberOfChannels: UInt32 = 2

    /// Creates a new instance of a settings.
    public init(
        sampleRate: Float64 = 0,
        channels: UInt32 = 0,
        isMuted: Bool = false,
        mainTrack: UInt8 = 0,
        tracks: [UInt8: AudioMixerTrackSettings] = .init(),
        isEchoCancellationEnabled: Bool = false,
        echoCancellationReferenceTrack: UInt8 = UInt8.max
    ) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.isMuted = isMuted
        self.mainTrack = mainTrack
        self.tracks = tracks
        self.isEchoCancellationEnabled = isEchoCancellationEnabled
        self.echoCancellationReferenceTrack = echoCancellationReferenceTrack
    }

    func invalidateOutputFormat(_ oldValue: Self) -> Bool {
        // mainTrack 變更也要重新推導：outputFormat 依「main track 的實際來源格式」
        // 決定（sampleRate/channels 為 0 時）。只比 sampleRate/channels 會在
        // mainTrack 從 app(44100) 切到 mic(48000) 時沿用舊格式。
        return mainTrack != oldValue.mainTrack
            || !(sampleRate == oldValue.sampleRate && channels == oldValue.channels)
    }

    func makeOutputFormat(_ formatDescription: CMFormatDescription?) -> AVAudioFormat? {
        guard let format = AVAudioUtil.makeAudioFormat(formatDescription) else {
            return nil
        }
        let sampleRate = min(sampleRate == 0 ? format.sampleRate : sampleRate, Self.maximumSampleRate)
        let channelCount = channels == 0 ? min(format.channelCount, maximumNumberOfChannels) : channels
        if let channelLayout = AVAudioUtil.makeChannelLayout(channelCount) {
            return .init(
                commonFormat: Self.commonFormat,
                sampleRate: sampleRate,
                interleaved: format.isInterleaved,
                channelLayout: channelLayout
            )
        }
        return .init(
            commonFormat: Self.commonFormat,
            sampleRate: sampleRate,
            channels: min(channelCount, 2),
            interleaved: format.isInterleaved
        )
    }
}

private enum AudioMixerSettingsCodingKeys: String, CodingKey {
    case sampleRate
    case channels
    case isMuted
    case mainTrack
    case tracks
    case maximumNumberOfChannels
    case isEchoCancellationEnabled
    case echoCancellationReferenceTrack
}

extension AudioMixerSettings {
    // 自訂 Codable：新欄位以 decodeIfPresent 提供預設值，
    // 舊版存檔（缺 AEC 欄位）仍可解碼。
    public nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AudioMixerSettingsCodingKeys.self)
        sampleRate = try container.decodeIfPresent(Float64.self, forKey: .sampleRate) ?? 0
        channels = try container.decodeIfPresent(UInt32.self, forKey: .channels) ?? 0
        isMuted = try container.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        mainTrack = try container.decodeIfPresent(UInt8.self, forKey: .mainTrack) ?? 0
        tracks = try container.decodeIfPresent([UInt8: AudioMixerTrackSettings].self, forKey: .tracks) ?? [:]
        maximumNumberOfChannels = try container.decodeIfPresent(UInt32.self, forKey: .maximumNumberOfChannels) ?? 2
        isEchoCancellationEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEchoCancellationEnabled) ?? false
        echoCancellationReferenceTrack = try container.decodeIfPresent(UInt8.self, forKey: .echoCancellationReferenceTrack) ?? UInt8.max
    }

    public nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AudioMixerSettingsCodingKeys.self)
        try container.encode(sampleRate, forKey: .sampleRate)
        try container.encode(channels, forKey: .channels)
        try container.encode(isMuted, forKey: .isMuted)
        try container.encode(mainTrack, forKey: .mainTrack)
        try container.encode(tracks, forKey: .tracks)
        try container.encode(maximumNumberOfChannels, forKey: .maximumNumberOfChannels)
        try container.encode(isEchoCancellationEnabled, forKey: .isEchoCancellationEnabled)
        try container.encode(echoCancellationReferenceTrack, forKey: .echoCancellationReferenceTrack)
    }
}
