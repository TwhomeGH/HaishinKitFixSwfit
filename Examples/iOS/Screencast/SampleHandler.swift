import HaishinKit
@preconcurrency import Logboard
import MediaPlayer
import ReplayKit
import RTCHaishinKit
import RTMPHaishinKit
import SRTHaishinKit
import VideoToolbox

nonisolated let logger = LBLogger.with("com.haishinkit.Screencast")

final class SampleHandler: RPBroadcastSampleHandler, @unchecked Sendable {
    private var slider: UISlider?
    private var session: StreamSession?
    private var mixer = MediaMixer(captureSessionMode: .manual, multiTrackAudioMixingEnabled: true)
    private var needVideoConfiguration = true
    private var isAppendingVideo = false

    override init() {
        Task {
            await StreamSessionBuilderFactory.shared.register(RTMPSessionFactory())
            await StreamSessionBuilderFactory.shared.register(SRTSessionFactory())
            await StreamSessionBuilderFactory.shared.register(HTTPSessionFactory())

            await SRTLogger.shared.setLevel(.debug)
            await RTCLogger.shared.setLevel(.info)
        }
    }

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        LBLogger.with(kHaishinKitIdentifier).level = .trace
        LBLogger.with(kRTMPHaishinKitIdentifier).level = .trace
        LBLogger.with(kSRTHaishinKitIdentifier).level = .trace
        LBLogger.with(kRTCHaishinKitIdentifier).level = .trace
        // mixer.audioMixerSettings.tracks[1] = .default
        Task {
            do {
                session = try await StreamSessionBuilderFactory.shared.make(Preference.default.makeURL()).build()
                // ReplayKit is sensitive to memory, so we limit the queue to a maximum of five items.
            var videoSetting = await mixer.videoMixerSettings
            videoSetting.mode = .passthrough
            await session?.stream.setVideoInputBufferCounts(5)
            await mixer.setVideoMixerSettings(videoSetting)
            // 物理回音消除：喇叭外放被 mic 收音時，以 app 軌為 reference、另一軌
            // （mic）為 target，在混音前對 mic 做 NLMS 回音消除，避免與 App 原聲
            // 雙重重疊。此 app 的接線：.audioApp → track 1、.audioMic → track 0。
            // reference 必填（指向 app 軌）；target 自動取「非 reference 的軌」。
            var audioMixerSettings = await mixer.audioMixerSettings
            audioMixerSettings.isEchoCancellationEnabled = true
            audioMixerSettings.echoCancellationReferenceTrack = 1
            await mixer.setAudioMixerSettings(audioMixerSettings)
            await mixer.startRunning()
                if let session {
                    await mixer.addOutput(session.stream)
                    try? await session.connect {
                    }
                }
            } catch {
                logger.error(error)
            }
        }
        // The volume of the audioApp can be obtained even when muted. A hack to synchronize with the volume.
        DispatchQueue.main.async {
            let volumeView = MPVolumeView(frame: CGRect.zero)
            if let slider = volumeView.subviews.compactMap({ $0 as? UISlider }).first {
                self.slider = slider
            }
        }
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        switch sampleBufferType {
        case .video:
            guard !isAppendingVideo else { return }
            isAppendingVideo = true
            Task {
                defer { isAppendingVideo = false }
                if needVideoConfiguration, let dimensions = sampleBuffer.formatDescription?.dimensions {
                    var videoSettings = await session?.stream.videoSettings
                    videoSettings?.videoSize = .init(
                        width: CGFloat(dimensions.width),
                        height: CGFloat(dimensions.height)
                    )
                    videoSettings?.profileLevel = kVTProfileLevel_H264_Baseline_AutoLevel as String
                    if let videoSettings {
                        try? await session?.stream.setVideoSettings(videoSettings)
                    }
                    needVideoConfiguration = false
                }
                await mixer.append(sampleBuffer)
            }
        case .audioMic:
            // 不可用 guard 丟音訊幀來節流：actor 忙碌時靜默丟幀會讓 mic/app
            // 非相關性掉幀，混音出現 silence 缺口（撕裂）。audio append 在
            // AudioMixerByMultiTrack 自己的 serial queue 上處理，actor hop 很
            // 輕量，排隊 append（保留 PTS 位置）比丟幀正確。
            guard sampleBuffer.dataReadiness == .ready else { return }
            Task {
                await mixer.append(sampleBuffer, track: 0)
            }
        case .audioApp:
            Task { @MainActor in
                if let volume = slider?.value {
                    var audioMixerSettings = await mixer.audioMixerSettings
                    audioMixerSettings.tracks[1] = .default
                    audioMixerSettings.tracks[1]?.volume = volume * 0.5
                    await mixer.setAudioMixerSettings(audioMixerSettings)
                }
            }
            guard sampleBuffer.dataReadiness == .ready else { return }
            Task {
                await mixer.append(sampleBuffer, track: 1)
            }
        @unknown default:
            break
        }
    }
}
