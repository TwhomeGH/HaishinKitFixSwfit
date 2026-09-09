#if !(os(iOS) || os(tvOS) || targetEnvironment(macCatalyst))
import Foundation

final class PlatformAudioEchoRouteObserver: AudioEchoRouteObserving {
    var hasEchoPath: Bool {
        true
    }

    func start(_ handler: @escaping (Bool) -> Void) {
        handler(true)
    }

    func stop() {
    }
}
#endif
