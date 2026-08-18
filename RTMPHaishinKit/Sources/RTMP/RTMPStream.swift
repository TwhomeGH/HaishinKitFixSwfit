@preconcurrency import AVFAudio
import AVFoundation
import Combine
import HaishinKit
import VideoToolbox

#if canImport(UIKit)
import UIKit
typealias View = UIView
#endif

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
typealias View = NSView
#endif

private struct RTMPOutputItem: Sendable {
    let type: RTMPChunkType
    let chunkStreamId: RTMPChunkStreamId
    let message: any RTMPMessage
}

/// An object that provides the interface to control a one-way channel over an RTMPConnection.
public actor RTMPStream {
    /// The error domain code.
    public enum Error: Swift.Error {
        /// An invalid internal stare.
        case invalidState
        /// The requested operation timed out.
        case requestTimedOut
        /// A request fails.
        case requestFailed(response: RTMPResponse)
        /// An unsupported codec.
        case unsupportedCodec
    }

    /// NetStatusEvent#info.code for NetStream
    /// - seealso: https://help.adobe.com/en_US/air/reference/html/flash/events/NetStatusEvent.html#NET_STATUS
    public enum Code: String {
        case bufferEmpty               = "NetStream.Buffer.Empty"
        case bufferFlush               = "NetStream.Buffer.Flush"
        case bufferFull                = "NetStream.Buffer.Full"
        case connectClosed             = "NetStream.Connect.Closed"
        case connectFailed             = "NetStream.Connect.Failed"
        case connectRejected           = "NetStream.Connect.Rejected"
        case connectSuccess            = "NetStream.Connect.Success"
        case drmUpdateNeeded           = "NetStream.DRM.UpdateNeeded"
        case failed                    = "NetStream.Failed"
        case multicastStreamReset      = "NetStream.MulticastStream.Reset"
        case pauseNotify               = "NetStream.Pause.Notify"
        case playFailed                = "NetStream.Play.Failed"
        case playFileStructureInvalid  = "NetStream.Play.FileStructureInvalid"
        case playInsufficientBW        = "NetStream.Play.InsufficientBW"
        case playNoSupportedTrackFound = "NetStream.Play.NoSupportedTrackFound"
        case playReset                 = "NetStream.Play.Reset"
        case playStart                 = "NetStream.Play.Start"
        case playStop                  = "NetStream.Play.Stop"
        case playStreamNotFound        = "NetStream.Play.StreamNotFound"
        case playTransition            = "NetStream.Play.Transition"
        case playUnpublishNotify       = "NetStream.Play.UnpublishNotify"
        case publishBadName            = "NetStream.Publish.BadName"
        case publishIdle               = "NetStream.Publish.Idle"
        case publishStart              = "NetStream.Publish.Start"
        case recordAlreadyExists       = "NetStream.Record.AlreadyExists"
        case recordFailed              = "NetStream.Record.Failed"
        case recordNoAccess            = "NetStream.Record.NoAccess"
        case recordStart               = "NetStream.Record.Start"
        case recordStop                = "NetStream.Record.Stop"
        case recordDiskQuotaExceeded   = "NetStream.Record.DiskQuotaExceeded"
        case secondScreenStart         = "NetStream.SecondScreen.Start"
        case secondScreenStop          = "NetStream.SecondScreen.Stop"
        case seekFailed                = "NetStream.Seek.Failed"
        case seekInvalidTime           = "NetStream.Seek.InvalidTime"
        case seekNotify                = "NetStream.Seek.Notify"
        case stepNotify                = "NetStream.Step.Notify"
        case unpauseNotify             = "NetStream.Unpause.Notify"
        case unpublishSuccess          = "NetStream.Unpublish.Success"
        case videoDimensionChange      = "NetStream.Video.DimensionChange"

        public var level: String {
            switch self {
            case .bufferEmpty:
                return "status"
            case .bufferFlush:
                return "status"
            case .bufferFull:
                return "status"
            case .connectClosed:
                return "status"
            case .connectFailed:
                return "error"
            case .connectRejected:
                return "error"
            case .connectSuccess:
                return "status"
            case .drmUpdateNeeded:
                return "status"
            case .failed:
                return "error"
            case .multicastStreamReset:
                return "status"
            case .pauseNotify:
                return "status"
            case .playFailed:
                return "error"
            case .playFileStructureInvalid:
                return "error"
            case .playInsufficientBW:
                return "warning"
            case .playNoSupportedTrackFound:
                return "status"
            case .playReset:
                return "status"
            case .playStart:
                return "status"
            case .playStop:
                return "status"
            case .playStreamNotFound:
                return "error"
            case .playTransition:
                return "status"
            case .playUnpublishNotify:
                return "status"
            case .publishBadName:
                return "error"
            case .publishIdle:
                return "status"
            case .publishStart:
                return "status"
            case .recordAlreadyExists:
                return "status"
            case .recordFailed:
                return "error"
            case .recordNoAccess:
                return "error"
            case .recordStart:
                return "status"
            case .recordStop:
                return "status"
            case .recordDiskQuotaExceeded:
                return "error"
            case .secondScreenStart:
                return "status"
            case .secondScreenStop:
                return "status"
            case .seekFailed:
                return "error"
            case .seekInvalidTime:
                return "error"
            case .seekNotify:
                return "status"
            case .stepNotify:
                return "status"
            case .unpauseNotify:
                return "status"
            case .unpublishSuccess:
                return "status"
            case .videoDimensionChange:
                return "status"
            }
        }

        func status(_ description: String) -> RTMPStatus {
            return .init(code: rawValue, level: level, description: description)
        }
    }

    /// The type of publish options.
    public enum HowToPublish: String, Sendable {
        /// Publish with server-side recording.
        case record
        /// Publish with server-side recording which is to append file if exists.
        case append
        /// Publish with server-side recording which is to append and ajust time file if exists.
        case appendWithGap
        /// Publish.
        case live
    }

    static let defaultID: UInt32 = 0
    static let supportedAudioCodecs: [AudioCodecSettings.Format] = [.aac, .opus]
    static let supportedVideoCodecs: [VideoCodecSettings.Format] = VideoCodecSettings.Format.allCases

    /// The RTMPStream metadata.
    public private(set) var metadata: AMFArray = .init(count: 0)
    /// The RTMPStreamInfo object whose properties contain data.
    public private(set) var info = RTMPStreamInfo()
    /// The object encoding (AMF). Framework supports AMF0 only.
    public private(set) var objectEncoding = RTMPConnection.defaultObjectEncoding
    /// The boolean value that indicates audio samples allow access or not.
    public private(set) var audioSampleAccess: Bool {
        get { inflowLock.withLock { _audioSampleAccess } }
        set { inflowLock.withLock { _audioSampleAccess = newValue } }
    }
    /// The boolean value that indicates video samples allow access or not.
    public private(set) var videoSampleAccess: Bool {
        get { inflowLock.withLock { _videoSampleAccess } }
        set { inflowLock.withLock { _videoSampleAccess = newValue } }
    }
    /// The number of video frames per seconds.
    @Published public private(set) var currentFPS: UInt16 = 0
    /// The ready state of stream.
    @Published public private(set) var readyState: StreamReadyState = .idle
    /// The stream of events you receive RTMP status events from a service.
    public var status: AsyncStream<RTMPStatus> {
        AsyncStream { continuation in
            statusContinuation = continuation
        }
    }
    /// The stream's name used for FMLE-compatible sequences.
    public private(set) var fcPublishName: String?

    public private(set) var videoTrackId: UInt8? = UInt8.max
    public private(set) var audioTrackId: UInt8? = UInt8.max

    private var isPaused = false
    private var startedAt = Date() {
        didSet {
            dataTimestamps.removeAll()
        }
    }
    private var lastPublishName: String?
    private var lastPublishType: HowToPublish = .live
    nonisolated(unsafe) package var outputs: [any StreamOutput] = []
    private var frameCount: UInt16 = 0
    private var videoStallCount: Int = 0
    private var videoSourceStallCount: Int = 0
    private var audioStallCount: Int = 0
    /// A/V resync 門檻：audio wire 時間落後 video playhead 超過此值時，把 audio
    /// 時間戳 clamp 到 video 附近並讓時間軸一次跳進（落後區間內容被跳過），
    /// 避免 player 因長期 A/V 偏移而棄音/靜音。健康時偏移 < 門檻不觸發。
    static let maxAudioBehindVideoSeconds: TimeInterval = 0.5
    private var audioResyncCount = 0
    private let inflowLock = NSLock()
    /// Congestion signal owned by RTMPConnection. Read from the nonisolated
    /// mixer path to drop raw frames *before* encoding when the network can't
    /// keep up (dropping encoded RTMP messages would break the GOP / A/V sync).
    nonisolated(unsafe) weak var backpressureSignal: SocketBackpressure?
    private nonisolated(unsafe) var _videoInputFrames: Int = 0
    private nonisolated(unsafe) var _audioInputFrames: Int = 0
    private nonisolated(unsafe) var _audioSampleAccess = true
    private nonisolated(unsafe) var _videoSampleAccess = true

    private var videoInputFrames: Int {
        get { inflowLock.withLock { _videoInputFrames } }
        set { inflowLock.withLock { _videoInputFrames = newValue } }
    }
    /// PTS（秒）of the latest raw video frame received. The authoritative
    /// liveness signal: for variable-frame-rate sources (ReplyKIT screen
    /// capture) frame COUNT legitimately drops when the picture is static,
    /// but the PTS of every delivered frame still advances — a stalled
    /// pipeline is one whose input PTS no longer moves, not one that sends
    /// few frames.
    private nonisolated(unsafe) var _lastVideoInputPTSSeconds: Double = -1
    private var lastVideoInputPTSSeconds: Double {
        get { inflowLock.withLock { _lastVideoInputPTSSeconds } }
        set { inflowLock.withLock { _lastVideoInputPTSSeconds = newValue } }
    }
    /// PTS snapshot from the previous status interval (for PTS-advance checks).
    private var lastStatusVideoInputPTSSeconds: Double = -1
    /// Wire-cumulative PTS (seconds) of the last encoded frame sent, snapshotted
    /// at the previous status interval.
    private var lastStatusVideoOutputPTSSeconds: Double = -1
    private var audioInputFrames: Int {
        get { inflowLock.withLock { _audioInputFrames } }
        set { inflowLock.withLock { _audioInputFrames = newValue } }
    }
    private var audioSentFrames: Int = 0
    private var audioSentBytes: Int = 0
    private var videoSentBytes: Int = 0
    private var lastStatusTime = Date.distantPast
    private var audioBuffer: AVAudioCompressedBuffer?
    private var howToPublish: RTMPStream.HowToPublish = .live
    private var continuation: CheckedContinuation<RTMPResponse, any Swift.Error>? {
        didSet {
            if continuation == nil {
                expectedResponse = nil
            }
        }
    }
    private var dataTimestamps: [String: Date] = .init()
    private var audioTimestamp: RTMPTimestamp<AVAudioTime> = .init()
    private var videoTimestamp: RTMPTimestamp<CMTime> = .init()
    private var requestTimeout = RTMPConnection.defaultRequestTimeout
    private var expectedResponse: Code?
    package var bitRateStrategy: (any StreamBitRateStrategy)?
    private var statusContinuation: AsyncStream<RTMPStatus>.Continuation?
    private var outputContinuation: AsyncStream<RTMPOutputItem>.Continuation?
    private var publishTask: Task<Void, Never>?
    nonisolated private let mixerOutputBridge = MediaMixerOutputBridge()
    private(set) var id: UInt32 = RTMPStream.defaultID
    package lazy var incoming = IncomingStream(self)
    nonisolated package let outgoing = OutgoingStream()
    private weak var connection: RTMPConnection?

    private var audioFormat: AVAudioFormat? {
        didSet {
            guard audioFormat != oldValue else {
                return
            }
            switch readyState {
            case .publishing:
                // A type-0 header must ride the real wire-cumulative position
                // (not 0): at 0 the server's clock resets backward mid-stream
                // and ffmpeg clamps DTS (non-monotonous + bitrate spike). A
                // type-1 header is a delta of 0 — the header itself adds no
                // time to the wire timeline.
                let timestamp = oldValue == nil ? UInt32(audioTimestamp.cumulativeTime * 1000) : 0
                guard let message = RTMPAudioMessage(streamId: id, timestamp: timestamp, formatDescription: audioFormat?.formatDescription) else {
                    return
                }
                doOutput(oldValue == nil ? .zero : .one, chunkStreamId: .audio, message: message)
            case .playing:
                if let audioFormat {
                    audioBuffer = AVAudioCompressedBuffer(format: audioFormat, packetCapacity: 1, maximumPacketSize: 1024 * Int(audioFormat.channelCount))
                } else {
                    audioBuffer = nil
                }
            default:
                break
            }
        }
    }

    private var videoFormat: CMFormatDescription? {
        didSet {
            guard videoFormat != oldValue else {
                return
            }
            switch readyState {
            case .publishing:
                // Same rule as the audio sequence header: type-0 carries the
                // real wire-cumulative position, type-1 is a zero delta.
                let timestamp = oldValue == nil ? UInt32(videoTimestamp.cumulativeTime * 1000) : 0
                guard let message = RTMPVideoMessage(streamId: id, timestamp: timestamp, formatDescription: videoFormat) else {
                    Task { await connection?.log(.warn, "video: sequence header creation failed") }
                    return
                }
                Task { await connection?.log(.debug, "video: sequence header sent, size=\(message.payload.count) first=0x\(String(format: "%02x", message.payload[0]))") }
                doOutput(oldValue == nil ? .zero : .one, chunkStreamId: .video, message: message)
            default:
                break
            }
        }
    }

    /// Creates a new stream.
    public init(connection: RTMPConnection, fcPublishName: String? = nil) {
        self.connection = connection
        self.fcPublishName = fcPublishName
        self.requestTimeout = connection.requestTimeout
        Task {
            await self.startOutputConsumer()
            await connection.addStream(self)
        }
    }

    deinit {
        publishTask?.cancel()
        outputContinuation?.finish()
        mixerOutputBridge.finish()
        outputs.removeAll()
    }

    /// Plays a live stream from a server.
    public func play(_ arguments: (any Sendable)?...) async throws -> RTMPResponse {
        guard let name = arguments.first as? String else {
            switch readyState {
            case .playing:
                info.resourceName = nil
                return try await close()
            default:
                throw Error.invalidState
            }
        }
        do {
            if outputContinuation == nil {
                startOutputConsumer()
            }
            await connection?.addStream(self)
            if id == RTMPStream.defaultID {
                try await createStream()
            }
            audioFormat = nil
            videoFormat = nil
            let response = try await withCheckedThrowingContinuation { continuation in
                readyState = .play
                expectedResponse = Code.playStart
                self.continuation?.resume(throwing: Error.invalidState)
                self.continuation = continuation
                Task {
                    await incoming.startRunning()
                    try? await Task.sleep(nanoseconds: requestTimeout * 1_000_000)
                    self.continuation.map {
                        $0.resume(throwing: Error.requestTimedOut)
                    }
                    self.continuation = nil
                }
                doOutput(.zero, chunkStreamId: .command, message: RTMPCommandMessage(
                    streamId: id,
                    transactionId: 0,
                    objectEncoding: objectEncoding,
                    commandName: "play",
                    commandObject: nil,
                    arguments: arguments
                ))
            }
            startedAt = .init()
            readyState = .playing
            info.resourceName = name
            return response
        } catch {
            Task { await incoming.stopRunning() }
            outgoing.stopRunning()
            readyState = .idle
            throw error
        }
    }

    /// Seeks the keyframe.
    public func seek(_ offset: Double) async throws {
        guard readyState == .playing else {
            throw Error.invalidState
        }
        doOutput(.zero, chunkStreamId: .command, message: RTMPCommandMessage(
            streamId: id,
            transactionId: 0,
            objectEncoding: objectEncoding,
            commandName: "seek",
            commandObject: nil,
            arguments: [offset]
        ))
    }

    /// Sends streaming audio, vidoe and data message from client.
    public func publish(_ name: String?, type: RTMPStream.HowToPublish = .live) async throws -> RTMPResponse {
        guard let name else {
            switch readyState {
            case .publishing:
                return try await close()
            default:
                throw Error.invalidState
            }
        }
        do {
            if outputContinuation == nil {
                await connection?.log(.debug, "publish: initializing outputConsumer")
                startOutputConsumer()
            }
            await connection?.addStream(self)
            if id == RTMPStream.defaultID {
                await connection?.log(.debug, "publish: creating stream")
                try await createStream()
                await connection?.log(.debug, "publish: stream created id=\(id)")
            }
            audioFormat = nil
            videoFormat = nil
            info.resourceName = name
            howToPublish = type
            lastPublishName = name
            lastPublishType = type
            startedAt = .init()
            metadata = makeMetadata()
            outgoing.startRunning()
            readyState = .publishing
        try? send("@setDataFrame", arguments: "onMetaData", metadata)
            let response = try await withCheckedThrowingContinuation { continuation in
                expectedResponse = Code.publishStart
                self.continuation?.resume(throwing: Error.invalidState)
                self.continuation = continuation
                Task {
                    try? await Task.sleep(nanoseconds: requestTimeout * 1_000_000)
                    self.continuation.map {
                        $0.resume(throwing: Error.requestTimedOut)
                    }
                    self.continuation = nil
                }
                doOutput(.zero, chunkStreamId: .command, message: RTMPCommandMessage(
                    streamId: id,
                    transactionId: 0,
                    objectEncoding: objectEncoding,
                    commandName: "publish",
                    commandObject: nil,
                    arguments: [name, type.rawValue]
                ))
                Task { await connection?.log(.debug, "publish: command sent, waiting for response") }
            }
            await connection?.log(.debug, "publish: response received, starting publish tasks")
            startPublishTasks()
            return response
        } catch {
            await connection?.log(.error, "publish: failed with \(error)")
            logger.warn("Publish response error (stream continues):", error)
            throw error
        }
    }

    /// Stops playing or publishing and makes available other uses.
    public func close() async throws -> RTMPResponse {
        guard readyState == .playing || readyState == .publishing else {
            throw Error.invalidState
        }
        lastPublishName = nil
        stopPublishTasks()
        outgoing.stopRunning()
        return try await withCheckedThrowingContinuation { continutation in
            self.continuation?.resume(throwing: Error.invalidState)
            self.continuation = continutation
            switch readyState {
            case .playing:
                expectedResponse = Code.playStop
            case .publishing:
                expectedResponse = Code.unpublishSuccess
            default:
                break
            }
            Task {
                await incoming.stopRunning()
                try? await Task.sleep(nanoseconds: requestTimeout * 1_000_000)
                self.continuation.map {
                    $0.resume(throwing: Error.requestTimedOut)
                }
                self.continuation = nil
            }
            doOutput(.zero, chunkStreamId: .command, message: RTMPCommandMessage(
                streamId: id,
                transactionId: 0,
                objectEncoding: objectEncoding,
                commandName: "closeStream",
                commandObject: nil,
                arguments: []
            ))
            readyState = .idle
        }
    }

    /// Sends a message on a published stream to all subscribing clients.
    ///
    /// ```
    /// // To add a metadata to a live stream sent to an RTMP Service.
    /// stream.send("@setDataFrame", "onMetaData", metaData)
    /// // To clear a metadata that has already been set in the stream.
    /// stream.send("@clearDataFrame", "onMetaData");
    /// ```
    ///
    /// - Parameters:
    ///   - handlerName: The message to send.
    ///   - arguments: Optional arguments.
    ///   - isResetTimestamp: A workaround option for sending timestamps as 0 in some services.
    public func send(_ handlerName: String, arguments: (any Sendable)?..., isResetTimestamp: Bool = false) throws {
        guard readyState == .publishing else {
            throw Error.invalidState
        }
        if isResetTimestamp {
            dataTimestamps[handlerName] = nil
        }
        let dataWasSent = dataTimestamps[handlerName] == nil ? false : true
        let timestmap: UInt32 = dataWasSent ? UInt32((dataTimestamps[handlerName]?.timeIntervalSinceNow ?? 0) * -1000) : UInt32(startedAt.timeIntervalSinceNow * -1000)
        doOutput(
            dataWasSent ? RTMPChunkType.one : RTMPChunkType.zero,
            chunkStreamId: .data,
            message: RTMPDataMessage(
                streamId: id,
                objectEncoding: objectEncoding,
                timestamp: timestmap,
                handlerName: handlerName,
                arguments: arguments
            )
        )
        dataTimestamps[handlerName] = .init()
    }

    /// Incoming audio plays on a stream or not.
    public func receiveAudio(_ receiveAudio: Bool) async throws {
        guard readyState == .playing else {
            throw Error.invalidState
        }
        doOutput(.zero, chunkStreamId: .command, message: RTMPCommandMessage(
            streamId: id,
            transactionId: 0,
            objectEncoding: objectEncoding,
            commandName: "receiveAudio",
            commandObject: nil,
            arguments: [receiveAudio]
        ))
    }

    /// Incoming video plays on a stream or not.
    public func receiveVideo(_ receiveVideo: Bool) async throws {
        guard readyState == .playing else {
            throw Error.invalidState
        }
        doOutput(.zero, chunkStreamId: .command, message: RTMPCommandMessage(
            streamId: id,
            transactionId: 0,
            objectEncoding: objectEncoding,
            commandName: "receiveVideo",
            commandObject: nil,
            arguments: [receiveVideo]
        ))
    }

    /// Pauses playback a  stream or not.
    public func pause(_ paused: Bool) async throws -> RTMPResponse {
        guard readyState == .playing else {
            throw Error.invalidState
        }
        let response = try await withCheckedThrowingContinuation { continuation in
            expectedResponse = isPaused ? Code.pauseNotify : Code.unpauseNotify
            self.continuation?.resume(throwing: Error.invalidState)
            self.continuation = continuation
            Task {
                try? await Task.sleep(nanoseconds: requestTimeout * 1_000_000)
                self.continuation.map {
                    $0.resume(throwing: Error.requestTimedOut)
                }
                self.continuation = nil
            }
            doOutput(.zero, chunkStreamId: .command, message: RTMPCommandMessage(
                streamId: id,
                transactionId: 0,
                objectEncoding: objectEncoding,
                commandName: "pause",
                commandObject: nil,
                arguments: [paused, floor(startedAt.timeIntervalSinceNow * -1000)]
            ))
        }
        isPaused = paused
        return response
    }

    /// Pauses or resumes playback of a stream.
    public func togglePause() async throws -> RTMPResponse {
        try await pause(!isPaused)
    }

    func doOutput(_ type: RTMPChunkType, chunkStreamId: RTMPChunkStreamId, message: some RTMPMessage) {
        guard connection != nil else {
            logger.warn("doOutput dropped: connection is nil")
            return
        }
        let result = outputContinuation?.yield(RTMPOutputItem(type: type, chunkStreamId: chunkStreamId, message: message))
        if case .terminated = result {
            Task { await connection?.log(.warn, "doOutput dropped: outputContinuation terminated (\(chunkStreamId))") }
        } else if case .dropped = result {
            Task { await connection?.log(.warn, "doOutput dropped: outputContinuation buffer full (\(chunkStreamId))") }
        }
    }

    func dispatch(_ message: some RTMPMessage, type: RTMPChunkType) {
        info.byteCount += message.payload.count
        switch message {
        case let message as RTMPCommandMessage:
            let response = RTMPResponse(message)
            switch message.commandName {
            case "onStatus":
                switch response.status?.level {
                case "status":
                    // During playback, only NetStream.Play.Start is awaited, as it follows the next sequence.
                    // 1. NetStream.Play.Rest
                    // 2. NetStream.Play.Start
                    if let code = response.status?.code, expectedResponse?.rawValue == code {
                        continuation?.resume(returning: response)
                        continuation = nil
                    }
                default:
                    continuation?.resume(throwing: Error.requestFailed(response: response))
                    continuation = nil
                }
                _ = response.status.map {
                    statusContinuation?.yield($0)
                }
            default:
                logger.info(message)
            }
        case let message as RTMPAudioMessage:
            append(message, type: type)
        case let message as RTMPVideoMessage:
            append(message, type: type)
        case let message as RTMPDataMessage:
            switch message.handlerName {
            case "onMetaData":
                metadata = message.arguments[0] as? AMFArray ?? .init(count: 0)
            case "|RtmpSampleAccess":
                audioSampleAccess = message.arguments[0] as? Bool ?? true
                videoSampleAccess = message.arguments[1] as? Bool ?? true
            default:
                break
            }
        case let message as RTMPUserControlMessage:
            switch message.event {
            case .bufferEmpty:
                statusContinuation?.yield(Code.bufferEmpty.status(""))
            case .bufferFull:
                statusContinuation?.yield(Code.bufferFull.status(""))
            default:
                break
            }
        default:
            break
        }
    }

    private static let createStreamMaxRetries = 3
    private static let createStreamRetryDelayNanos: UInt64 = 500_000_000

    func createStream(retryCount: Int = RTMPStream.createStreamMaxRetries) async throws {
        guard id == RTMPStream.defaultID else {
            return
        }
        if let fcPublishName {
            do {
                try await connection?.sendCommand("releaseStream", arguments: fcPublishName)
                try await connection?.sendCommand("FCPublish", arguments: fcPublishName)
            } catch {
                await connection?.log(.error, "createStream: FMLE preamble failed", detail: "\(error)")
            }
        }
        var lastError: Swift.Error = Error.invalidState
        for attempt in 1...retryCount {
            do {
                let response = try await connection?.call("createStream")
                guard let first = response?.arguments.first as? Double else {
                    await connection?.log(.error, "createStream: missing stream id (attempt \(attempt)/\(retryCount))", detail: "arguments=\(response?.arguments.count ?? 0)")
                    lastError = RTMPConnection.Error.requestTimedOut
                    continue
                }
                id = UInt32(first)
                await connection?.log(.info, "createStream: stream id", detail: "\(id)")
                readyState = .idle
                return
            } catch {
                lastError = error
                await connection?.log(.error, "createStream: failed (attempt \(attempt)/\(retryCount))", detail: "\(error)")
                if attempt < retryCount {
                    try? await Task.sleep(nanoseconds: RTMPStream.createStreamRetryDelayNanos)
                }
            }
        }
        throw lastError
    }

    func deleteStream() async {
        // 不要求 fcPublishName：重連 teardown 時也要停止管線，
        // 且不能清除 lastPublishName（resumePublishing 需要它）。
        stopPublishTasks()
        outgoing.stopRunning()
        if let fcPublishName, readyState == .publishing {
            async let _ = try? connection?.call("FCUnpublish", arguments: fcPublishName)
            async let _ = try? connection?.call("deleteStream", arguments: id)
        }
    }

    private func append(_ message: RTMPAudioMessage, type: RTMPChunkType) {
        audioTimestamp.update(message, chunkType: type)
        guard message.codec.isSupported else {
            return
        }
        switch message.payload[1] {
        case RTMPAACPacketType.seq.rawValue:
            audioFormat = message.makeAudioFormat()
        case RTMPAACPacketType.raw.rawValue:
            if audioFormat == nil {
                audioFormat = message.makeAudioFormat()
            }
            if let audioBuffer {
                message.copyMemory(audioBuffer)
                Task { await incoming.append(audioBuffer, when: audioTimestamp.value) }
            }
        default:
            break
        }
    }

    private func append(_ message: RTMPVideoMessage, type: RTMPChunkType) {
        videoTimestamp.update(message, chunkType: type)
        guard RTMPTagType.video.headerSize <= message.payload.count && message.isSupported else {
            return
        }
        if message.isExHeader {
            // IsExHeader for Enhancing RTMP, FLV
            switch message.packetType {
            case RTMPVideoPacketType.sequenceStart.rawValue:
                videoFormat = message.makeFormatDescription()
            case RTMPVideoPacketType.codedFrames.rawValue:
                Task { await incoming.append(message, presentationTimeStamp: videoTimestamp.value, formatDesciption: videoFormat) }
            case RTMPVideoPacketType.codedFramesX.rawValue:
                Task { await incoming.append(message, presentationTimeStamp: videoTimestamp.value, formatDesciption: videoFormat) }
            default:
                break
            }
        } else {
            switch message.packetType {
            case RTMPAVCPacketType.seq.rawValue:
                videoFormat = message.makeFormatDescription()
            case RTMPAVCPacketType.nal.rawValue:
                Task { await incoming.append(message, presentationTimeStamp: videoTimestamp.value, formatDesciption: videoFormat) }
            default:
                break
            }
        }
    }

    private func startPublishTasks() {
        publishTask?.cancel()

        let (audioStream, audioContinuation) = AsyncStream.makeStream(of: (AVAudioPCMBuffer, AVAudioTime).self)
        mixerOutputBridge.setAudioContinuation(audioContinuation)
        outgoing.setVideoCodecLogHandler { [weak self] message in
            Task { await self?.connection?.log(.info, "VideoCodec: \(message)") }
        }
        Task { await connection?.log(.info, "startPublishTasks: bridge continuations set") }

        let videoOutput = outgoing.videoOutputStream
        let audioOutput = outgoing.audioOutputStream
        let videoInput = outgoing.prepareVideoInputStream()

        publishTask = Task { [weak self] in
            guard let self else { return }
            await connection?.log(.info, "startPublishTasks: task started")
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await (buffer, when) in audioStream {
                        await self.append(buffer, when: when)
                    }
                }
                group.addTask {
                    for await (buffer, when) in audioOutput {
                        await self.append(buffer, when: when)
                    }
                }
                group.addTask {
                    for await sampleBuffer in videoOutput {
                        await self.append(sampleBuffer)
                    }
                }
                group.addTask {
                    for await video in videoInput {
                        await self.outgoing.append(video: video)
                    }
                }
            }
            await connection?.log(.info, "startPublishTasks: task ended")
        }
    }

    private func stopPublishTasks() {
        publishTask?.cancel()
        publishTask = nil
        mixerOutputBridge.finish()
    }

    private func startOutputConsumer() {
        let (stream, continuation) = AsyncStream.makeStream(of: RTMPOutputItem.self)
        outputContinuation = continuation
        Task { [weak self] in
            for await item in stream {
                guard let self else { return }
                let conn = await self.connection
                guard let conn else { continue }
                // 斷線/重連期間跳過，避免無謂的 actor hop 與 log 刷屏。
                guard await conn.connected else { continue }
                let length = await conn.doOutput(item.type, chunkStreamId: item.chunkStreamId, message: item.message)
                await self.appendByteCount(length)
            }
        }
    }

    private func appendByteCount(_ length: Int) {
        info.byteCount += length
    }

    /// Creates flv metadata for a stream.
    private func makeMetadata() -> AMFArray {
        // https://github.com/shogo4405/HaishinKit.swift/issues/1410
        var metadata: AMFObject = ["duration": 0]
        if outgoing.videoInputFormat != nil {
            metadata["width"] = outgoing.videoSettings.videoSize.width
            metadata["height"] = outgoing.videoSettings.videoSize.height
            metadata["videocodecid"] = outgoing.videoSettings.format.codecid
            metadata["videodatarate"] = outgoing.videoSettings.bitRate / 1000
            if let expectedFrameRate = outgoing.videoSettings.expectedFrameRate {
                metadata["framerate"] = expectedFrameRate
            }
        }
        metadata["audiocodecid"] = outgoing.audioSettings.format.codecid
        metadata["audiodatarate"] = outgoing.audioSettings.bitRate / 1000
        if let audioFormat = outgoing.audioInputFormat?.audioStreamBasicDescription {
            metadata["audiosamplerate"] = outgoing.audioSettings.format.makeSampleRate(
                audioFormat.mSampleRate,
                output: outgoing.audioSettings.sampleRate
            )
        }
        return AMFArray(metadata)
    }
}

extension RTMPStream: _Stream {
    public func setAudioSettings(_ audioSettings: AudioCodecSettings) throws {
        guard Self.supportedAudioCodecs.contains(audioSettings.format) else {
            throw Error.unsupportedCodec
        }
        outgoing.audioSettings = audioSettings
    }

    public func setVideoSettings(_ videoSettings: VideoCodecSettings) throws {
        guard Self.supportedVideoCodecs.contains(videoSettings.format) else {
            throw Error.unsupportedCodec
        }
        outgoing.videoSettings = videoSettings
        // Scale the socket OOM guard to the current bitrate so a large keyframe
        // still in flight during a network stall is absorbed, not shed.
        backpressureSignal?.updateVideoSettings(bitRate: videoSettings.bitRate, maxKeyFrameInterval: videoSettings.maxKeyFrameIntervalDuration)
    }

    /// Ensures the current video codec is supported by the server.
    /// Falls back to H.264 if the server does not support HEVC/VP9/AV1.
    /// Returns true if no fallback was needed.
    @discardableResult
    public func ensureVideoCodecSupported(by connection: RTMPConnection) async -> Bool {
        let supportedCodecs = await connection.serverSupportedVideoCodecs
        guard !supportedCodecs.isEmpty else {
            return true
        }
        var settings = outgoing.videoSettings
        switch settings.format {
        case .hevc:
            guard !supportedCodecs.contains("hvc1") else {
                return true
            }
            settings.format = .h264
            settings.profileLevel = kVTProfileLevel_H264_High_AutoLevel as String
            await connection.log(.warn, "HEVC not supported by server, fallback to H.264")
        default:
            return true
        }
        try? await setVideoSettings(settings)
        return false
    }

    public func append(_ sampleBuffer: CMSampleBuffer) {
        switch sampleBuffer.formatDescription?.mediaType {
        case .video:
            if sampleBuffer.formatDescription?.isCompressed == true {
                let decodeTimeStamp = sampleBuffer.decodeTimeStamp.isValid ? sampleBuffer.decodeTimeStamp : sampleBuffer.presentationTimeStamp
                // Emit the sequence header (if the format changed) BEFORE the
                // timestamp advances, so a type-0 header carries the position of
                // the previous frame; the following type-1 frame then adds its
                // own delta once instead of double-counting it.
                videoFormat = sampleBuffer.formatDescription
                let timedelta = videoTimestamp.update(decodeTimeStamp, source: "video")
                frameCount += 1
                let compositionTime: Int32
                if sampleBuffer.decodeTimeStamp.isValid {
                    compositionTime = sampleBuffer.getCompositionTime(RTMPVideoMessage.ctsOffset)
                } else {
                    compositionTime = Int32((sampleBuffer.presentationTimeStamp.seconds - videoTimestamp.updatedAt) * 1000)
                }
                guard let message = RTMPVideoMessage(streamId: id, timestamp: timedelta, compositionTime: compositionTime, sampleBuffer: sampleBuffer) else {
                        Task { await connection?.log(.debug, "append(video): RTMPVideoMessage creation failed") }
                        return
                    }
                    videoSentBytes += message.payload.count
                    doOutput(.one, chunkStreamId: .video, message: message)
                } else {
                videoInputFrames += 1
                if sampleBuffer.formatDescription?.isCompressed == false {
                    lastVideoInputPTSSeconds = sampleBuffer.presentationTimeStamp.seconds
                }
                // Network congestion: skip the encoder feed (pre-encode drop),
                // keep the local preview.
                if backpressureSignal?.shouldDropVideoFrame() == true {
                    if sampleBuffer.formatDescription?.isCompressed == false {
                        outputs.forEach {
                            switch sampleBuffer.formatDescription?.mediaType {
                            case .audio:
                                if audioSampleAccess {
                                    $0.stream(self, didOutput: sampleBuffer)
                                }
                            case .video:
                                if videoSampleAccess || ($0 is View) {
                                    $0.stream(self, didOutput: sampleBuffer)
                                }
                            default:
                                $0.stream(self, didOutput: sampleBuffer)
                            }
                        }
                    }
                } else {
                    outgoing.append(sampleBuffer)
                    if sampleBuffer.formatDescription?.isCompressed == false {
                        outputs.forEach {
                            switch sampleBuffer.formatDescription?.mediaType {
                            case .audio:
                                if audioSampleAccess {
                                    $0.stream(self, didOutput: sampleBuffer)
                                }
                            case .video:
                                if videoSampleAccess || ($0 is View) {
                                    $0.stream(self, didOutput: sampleBuffer)
                                }
                            default:
                                $0.stream(self, didOutput: sampleBuffer)
                            }
                        }
                    }
                }
            }
        default:
            break
        }
    }

    public func append(_ audioBuffer: AVAudioBuffer, when: AVAudioTime) {
        switch audioBuffer {
        case let audioBuffer as AVAudioCompressedBuffer:
            // Same ordering rule as video: emit the sequence header before the
            // timestamp advances so the type-0 header rides the wire position
            // of the previous frame.
            audioFormat = audioBuffer.format
            // A/V resync：音訊 capture 時間落後 video playhead 超過門檻時，把
            // 時間戳 clamp 到 video 附近並 allowJump 一次跳進同步範圍 — 落後
            // 區間的音訊內容被跳過（丟棄舊資料），player 重新對齊而非靜音。
            let resyncedWhen = resyncedAudioTime(original: when)
            let timedelta = audioTimestamp.update(resyncedWhen, source: "audio", allowJump: true)
            guard let message = RTMPAudioMessage(streamId: id, timestamp: timedelta, audioBuffer: audioBuffer) else {
                Task { await connection?.log(.debug, "append(audio): RTMPAudioMessage creation failed") }
                return
            }
            audioSentFrames += 1
            audioSentBytes += message.payload.count
            doOutput(.one, chunkStreamId: .audio, message: message)
        default:
            let isPCM = audioBuffer is AVAudioPCMBuffer
            // Network congestion (full stall): drop the raw buffer BEFORE the
            // audio encoder so no new compressed messages are produced.
            if backpressureSignal?.shouldDropAudioFrame() == true {
                if isPCM {
                    audioInputFrames += 1
                }
                return
            }
            outgoing.append(audioBuffer, when: when)
            if isPCM {
                audioInputFrames += 1
                if audioSampleAccess {
                    outputs.forEach { $0.stream(self, didOutput: audioBuffer, when: when) }
                }
            }
        }
    }

    /// A/V resync helper：audio wire 時間落後 video playhead 超過
    /// `maxAudioBehindVideoSeconds` 時，把音訊時間戳 clamp 到 video 附近並回傳
    /// （由呼叫端以 `allowJump: true` 讓時間軸一次跳進）。健康時（偏移 < 門檻）
    /// 原樣回傳。若兩者時鐘基座不同導致常態誤差，此守衛會把音訊釘在 video
    /// 附近 — 這正是「丟棄落後舊資料」的等價行為，避免 player 長期棄音。
    private func resyncedAudioTime(original when: AVAudioTime) -> AVAudioTime {
        let videoPosition = videoTimestamp.updatedAt
        guard 0 <= videoPosition else {
            return when
        }
        let behind = videoPosition - when.seconds
        guard Self.maxAudioBehindVideoSeconds < behind else {
            return when
        }
        audioResyncCount += 1
        if audioResyncCount % 60 == 1 {
            Task { await connection?.log(.warn, "audio resync: audio behind video, clamping to playhead", detail: "behind=\(String(format: "%.3f", behind))s video=\(String(format: "%.3f", videoPosition)) audio=\(String(format: "%.3f", when.seconds)) count=\(audioResyncCount)") }
        }
        let clampedSeconds = videoPosition - Self.maxAudioBehindVideoSeconds
        return AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: clampedSeconds))
    }

    public func dispatch(_ event: NetworkMonitorEvent) async {
        switch event {
        case .reset:
            stopPublishTasks()
            outgoing.stopRunning()
            id = RTMPStream.defaultID
            readyState = .idle
            videoInputFrames = 0
            videoStallCount = 0
            videoSourceStallCount = 0
            audioInputFrames = 0
            audioStallCount = 0
            lastStatusVideoInputPTSSeconds = -1
            lastStatusVideoOutputPTSSeconds = -1
        case .status(let report):
            let now = Date()
            let interval = now.timeIntervalSince(lastStatusTime)
            lastStatusTime = now
            // PTS-based liveness: for variable-frame-rate sources (ReplyKIT
            // screen capture) frame COUNT legitimately drops when the picture
            // is static — 0 frames per second is NORMAL, not a stall. The
            // correct signal is whether the PTS of delivered frames advances.
            let inputPTS = lastVideoInputPTSSeconds
            let inputPTSAdvanced = 0 <= lastStatusVideoInputPTSSeconds && lastStatusVideoInputPTSSeconds < inputPTS
            let outputPTSAdvanced = lastStatusVideoOutputPTSSeconds < videoTimestamp.updatedAt
            lastStatusVideoInputPTSSeconds = inputPTS
            lastStatusVideoOutputPTSSeconds = videoTimestamp.updatedAt
            if interval > 1.5 {
                await connection?.log(.warn, "publish status gap", detail: "interval=\(interval) videoInputFrames=\(videoInputFrames) frameCount=\(frameCount) inputPTS=\(inputPTS)")
            }
            if audioSentFrames > 0 || audioInputFrames > 0 || videoSentBytes > 0 || videoInputFrames > 0 {
                // videoPTS / audioPTS = 各自「最後一幀」的原始 capture 時間（host time）。
                // 兩者不會逐幀相等：1) 取樣時刻不同（video/audio 幀交錯）2) 兩子系統
                // 時鐘基座可能有固定 offset。要看的是 avOffset 是否「固定」還是「增長」：
                // 固定 = 健康；持續增大 = 兩時鐘漂移（player 可能因此棄音/凍結畫面）。
                let videoPTS = videoTimestamp.updatedAt
                let audioPTS = audioTimestamp.updatedAt
                let avOffset = videoPTS - audioPTS
                await connection?.log(.debug, "publish throughput",
                    detail: "audioInputFrames=\(audioInputFrames) audioFrames=\(audioSentFrames) audioBytes=\(audioSentBytes) videoInputFrames=\(videoInputFrames) videoFrames=\(frameCount) videoBytes=\(videoSentBytes) videoPTS=\(String(format: "%.3f", videoPTS))s audioPTS=\(String(format: "%.3f", audioPTS))s avOffset=\(String(format: "%.3f", avOffset))s")
            }
            if videoInputFrames > Int(frameCount) * 2, videoInputFrames > 10 {
                await connection?.log(.warn, "publish frame loss",
                    detail: "videoInputFrames=\(videoInputFrames) >> videoFrames=\(frameCount) queueBytes=\(report.currentQueueBytesOut)")
            }
            var restartedVideoPipeline = false
            if backpressureSignal?.isStalling == true {
                // Network stall: encoder production is deliberately halted until
                // the socket queue drains. Reset the stall counters so the
                // detector doesn't mistake it for a broken pipeline and restart
                // (which would cause another visible freeze).
                videoSourceStallCount = 0
                videoStallCount = 0
                audioStallCount = 0
            } else if readyState == .publishing && !inputPTSAdvanced && audioInputFrames > 0 {
                // Video source produced no new PTS while audio kept flowing.
                // For a VFR source (static screen) this is normal and must NOT
                // restart the pipeline. Only log; the encoder keeps running so
                // the moment the source resumes, frames flow again without a
                // session rebuild.
                videoSourceStallCount += 1
                if videoSourceStallCount == 3 {
                    await connection?.log(.warn, "video source idle", detail: "no new PTS, audioInputFrames=\(audioInputFrames) (static screen is normal)")
                }
            } else if readyState == .publishing && inputPTSAdvanced {
                // Source resumed producing — no restart needed, just reset.
                videoSourceStallCount = 0
            } else if readyState != .publishing {
                videoSourceStallCount = 0
            }
            if !restartedVideoPipeline && readyState == .publishing && inputPTSAdvanced && !outputPTSAdvanced {
                // True encoder stall: input PTS advanced (frames are flowing
                // into the encoder) but no encoded output emerged. Restart.
                videoStallCount += 1
                if 2 == videoStallCount {
                    await connection?.log(.warn, "video stall detected, will restart pipeline", detail: "stallCount=\(videoStallCount) inputPTSAdvanced=\(inputPTSAdvanced) outputPTSAdvanced=\(outputPTSAdvanced)")
                }
                if 3 <= videoStallCount {
                    await restartVideoPipeline(reason: "encoded video stalled while input PTS is advancing")
                    // resets both audioStallCount and videoStallCount
                }
            } else if !restartedVideoPipeline, readyState == .publishing, audioInputFrames > 0, audioSentFrames == 0 {
                audioStallCount += 1
                if audioStallCount == 2 {
                    await connection?.log(.warn, "audio stall detected, will restart pipeline", detail: "stallCount=\(audioStallCount) audioInputFrames=\(audioInputFrames)")
                }
                if 3 <= audioStallCount {
                    await restartAudioPipeline(reason: "audio input active (\(audioInputFrames) frames) but no compressed output")
                }
            } else {
                videoStallCount = 0
                audioStallCount = 0
            }
            audioSentFrames = 0
            audioSentBytes = 0
            audioInputFrames = 0
            videoInputFrames = 0
            videoSentBytes = 0
        default:
            break
        }
        await bitRateStrategy?.adjustBitrate(event, stream: self)
        currentFPS = frameCount
        frameCount = 0
        info.update()
    }

    func resumePublishing() async {
        guard let name = lastPublishName else {
            return
        }
        guard readyState == .idle else {
            await connection?.log(.warn, "resumePublishing: skipped, readyState=\(readyState)")
            return
        }
        guard await connection?.connected == true else {
            await connection?.log(.warn, "resumePublishing: skipped, connection is down")
            return
        }
        do {
            try await publish(name, type: lastPublishType)
        } catch {
            await connection?.log(.error, "Auto-republish failed", detail: "\(error)")
        }
    }

    private func restartVideoPipeline(reason: String) async {
        guard await connection?.connected == true else {
            await connection?.log(.warn, "skip restartVideoPipeline: connection is down", detail: reason)
            videoStallCount = 0
            return
        }
        await connection?.log(.warn, "Restarting video pipeline", detail: reason)
        await connection?.log(.info, "restartVideoPipeline: stopping publish tasks")
        stopPublishTasks()
        await connection?.log(.info, "restartVideoPipeline: restart outgoing")
        outgoing.stopRunning()
        outgoing.startRunning()
        // 銝?蝵?videoFormat/audioFormat嚗 encoder session ?Ｗ?詨??澆???        // didSet 銝孛????銝?seq header ??timeline 銝葉?瑯?        await connection?.log(.info, "restartVideoPipeline: starting publish tasks")
        startPublishTasks()
        await connection?.log(.info, "restartVideoPipeline: done")
        videoStallCount = 0
        audioStallCount = 0
        videoSourceStallCount = 0
    }

    private func restartAudioPipeline(reason: String) async {
        guard await connection?.connected == true else {
            await connection?.log(.warn, "skip restartAudioPipeline: connection is down", detail: reason)
            audioStallCount = 0
            return
        }
        await connection?.log(.warn, "Restarting audio pipeline", detail: reason)
        stopPublishTasks()
        outgoing.stopRunning()
        outgoing.startRunning()
        startPublishTasks()
        audioStallCount = 0
        videoStallCount = 0
    }
}

extension RTMPStream: MediaMixerOutput {
    // MARK: MediaMixerOutput
    public func selectTrack(_ id: UInt8?, mediaType: CMFormatDescription.MediaType) {
        switch mediaType {
        case .audio:
            audioTrackId = id
        case .video:
            videoTrackId = id
        default:
            break
        }
    }

    nonisolated public func mixer(_ mixer: MediaMixer, didOutput sampleBuffer: CMSampleBuffer) {
        inflowLock.lock()
        _videoInputFrames += 1
        if sampleBuffer.formatDescription?.isCompressed == false {
            _lastVideoInputPTSSeconds = sampleBuffer.presentationTimeStamp.seconds
        }
        let outputs = self.outputs
        let sampleAccess = _videoSampleAccess
        // Only uncompressed (raw) frames can be shed pre-encode; compressed
        // frames are already encoded and dropping them would break the stream.
        let isUncompressed = sampleBuffer.formatDescription?.isCompressed == false
        let dropForBackpressure = isUncompressed && backpressureSignal?.shouldDropVideoFrame() == true
        inflowLock.unlock()
        // Network congestion: drop the raw frame BEFORE the encoder so the
        // encoded stream stays intact (only the frame rate dips temporarily).
        if !dropForBackpressure {
            outgoing.append(sampleBuffer)
        }
        if isUncompressed {
            for output in outputs {
                if sampleAccess || output is View {
                    output.stream(self, didOutput: sampleBuffer)
                }
            }
        }
    }

    nonisolated public func mixer(_ mixer: MediaMixer, didOutput buffer: AVAudioPCMBuffer, when: AVAudioTime) {
        mixerOutputBridge.yieldAudio(buffer, when: when)
    }
}
