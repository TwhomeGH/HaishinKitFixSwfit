import Foundation

/// The enumeration defines the state a HKStream client is in.
public enum StreamReadyState: Int, Sendable, CustomStringConvertible {
    /// The stream is idling.
    case idle
    /// The stream has sent a request to play and is waiting for approval from the server.
    case play
    /// The stream is playing.
    case playing
    /// The streamhas sent a request to publish and is waiting for approval from the server.
    case publish
    /// The stream is publishing.
    case publishing

    public var description: String {
        switch self {
        case .idle:
            return "idle"
        case .play:
            return "play"
        case .playing:
            return "playing"
        case .publish:
            return "publish"
        case .publishing:
            return "publishing"
        }
    }
}
