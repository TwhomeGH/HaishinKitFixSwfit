import Foundation

protocol AudioEchoRouteObserving: AnyObject {
    var hasEchoPath: Bool { get }

    func start(_ handler: @escaping (Bool) -> Void)
    func stop()
}
