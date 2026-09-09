#if os(iOS) || os(tvOS) || targetEnvironment(macCatalyst)
import AVFoundation
import Foundation

final class PlatformAudioEchoRouteObserver: AudioEchoRouteObserving {
    private var observer: (any NSObjectProtocol)?

    var hasEchoPath: Bool {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        guard !outputs.isEmpty else {
            return true
        }
        for output in outputs {
            switch output.portType {
            case .builtInReceiver, .headphones, .headsetMic, .bluetoothHFP, .bluetoothA2DP:
                return false
            default:
                continue
            }
        }
        return true
    }

    func start(_ handler: @escaping (Bool) -> Void) {
        guard observer == nil else {
            return
        }
        observer = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else {
                return
            }
            handler(self.hasEchoPath)
        }
    }

    func stop() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
    }

    deinit {
        stop()
    }
}
#endif
