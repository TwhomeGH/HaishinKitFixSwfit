import AVFoundation

#if os(iOS)
final class AudioRouteManager {
    enum Mode {
        case streaming
        case voiceChat
    }

    private let engine = AVAudioEngine()
    private weak var mixer: MediaMixer?
    private var isActive = false
    private let lockQueue = DispatchQueue(label: "com.haishinkit.HaishinKit.AudioRouteManager.lock")

    var mode: Mode = .streaming

    init(mixer: MediaMixer) {
        self.mixer = mixer
    }

    func activate() throws {
        try lockQueue.sync {
            guard !isActive else { return }
            isActive = true
        }

        // 在 App Extension (Broadcast Extension) 中無法設定 AVAudioSession category
        if (Bundle.main.bundlePath as NSString).pathExtension == "appex" {
            isActive = false
            return
        }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.mixWithOthers, .allowBluetooth, .allowBluetoothA2DP])
        try session.setActive(true)
        
        stopEngine()
        
        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, time in
            guard let self = self, let mixer = self.mixer else { return }
            Task { [weak mixer] in
                await mixer.append(buffer, when: time)
            }
        }
        try engine.start()
    }

    func deactivate() {
        lockQueue.sync {
            guard isActive else { return }
            isActive = false
        }
        stopEngine()
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
    }

    private func stopEngine() {
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
    }
}
#endif
