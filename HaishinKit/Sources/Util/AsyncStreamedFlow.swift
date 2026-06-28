import Foundation

@propertyWrapper
package struct AsyncStreamedFlow<T: Sendable> {
    package var wrappedValue: AsyncStream<T> {
        mutating get {
            let (stream, continuation) = AsyncStream.makeStream(of: T.self, bufferingPolicy: bufferingPolicy)
            self._continuation = continuation
            return stream
        }
        @available(*, unavailable)
        set { _ = newValue }
    }
    private let bufferingPolicy: AsyncStream<T>.Continuation.BufferingPolicy
    private var _continuation: AsyncStream<T>.Continuation? {
        didSet {
            oldValue?.finish()
        }
    }

    /// The current stream continuation. Used to feed values into the stream
    /// without creating a new one (unlike accessing `wrappedValue`).
    package var continuation: AsyncStream<T>.Continuation? {
        _continuation
    }

    package init(_ bufferingPolicy: AsyncStream<T>.Continuation.BufferingPolicy = .unbounded) {
        self.bufferingPolicy = bufferingPolicy
    }

    package func yield(_ value: T) {
        _continuation?.yield(value)
    }

    package mutating func finish() {
        _continuation = nil
    }
}
