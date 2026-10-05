#if os(iOS) || os(tvOS) || targetEnvironment(macCatalyst)
import AVFoundation
import Foundation

final class PlatformAudioEchoRouteObserver: AudioEchoRouteObserving, @unchecked Sendable {
    /// NotificationCenter 的 observer closure 是 `@Sendable`，但 `handler` 不是
    /// Sendable 型別；用它包一層，避免 Swift 6 的 #SendableClosureCaptures 警告。
    private struct Box<Value>: @unchecked Sendable {
        let value: Value
    }

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
        let boxedHandler = Box(value: handler)
        observer = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else {
                return
            }
            boxedHandler.value(self.hasEchoPath)
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
