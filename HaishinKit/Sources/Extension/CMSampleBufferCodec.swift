import AVFoundation
import CoreMedia

/// Binary codec for moving an encoded `CMSampleBuffer` across a byte stream
/// (e.g. a TCP socket) while preserving its format description, timing and data.
///
/// Motivating case: a ReplayKit broadcast extension owns the sample buffers but
/// its container is invisible to the host app, so recordings must be forwarded as
/// bytes and rebuilt on the host side. This codec is the wire format for that.
///
/// Only the fields a recorder needs are carried: media type, presentation
/// timestamp/duration, sync flag, sample count, a compact format description
/// (video: codec + dimensions + codec atoms such as `avcC`/`hvcC`; audio: ASBD +
/// magic cookie) and the block data. It does **not** carry arbitrary attachments.
///
/// The format is little-endian-agnostic (all integers are written big-endian) and
/// starts with a version byte so it can evolve.
public enum CMSampleBufferCodec {
    /// Current wire format version.
    public static let version: UInt8 = 1

    // MARK: Encode

    /// Serializes `sampleBuffer` into the wire format.
    /// Returns nil when the buffer has no format description or no block data.
    public static func encode(_ sampleBuffer: CMSampleBuffer) -> Data? {
        guard let formatDescription = sampleBuffer.formatDescription else {
            return nil
        }
        guard let payload = blockData(of: sampleBuffer) else {
            return nil
        }

        var writer = ByteWriter()
        writer.writeUInt8(version)
        let mediaType = CMFormatDescriptionGetMediaType(formatDescription)
        writer.writeUInt8(mediaType == kCMMediaType_Video ? 0 : (mediaType == kCMMediaType_Audio ? 1 : 2))
        writer.writeTime(sampleBuffer.presentationTimeStamp)
        writer.writeTime(sampleBuffer.duration)
        writer.writeUInt8(isSync(sampleBuffer) ? 1 : 0)
        writer.writeUInt32(UInt32(truncatingIfNeeded: CMSampleBufferGetNumSamples(sampleBuffer)))

        writeFormatDescription(formatDescription, into: &writer)

        writer.writeUInt32(UInt32(payload.count))
        writer.writeBytes(payload)
        return writer.data
    }

    // MARK: Decode

    /// Rebuilds a `CMSampleBuffer` from `data` produced by ``encode(_:)``.
    public static func decode(_ data: Data) -> CMSampleBuffer? {
        var reader = ByteReader(data)
        guard reader.readUInt8() == version else {
            return nil
        }
        guard let mediaTypeByte = reader.readUInt8() else { return nil }
        guard let presentationTimeStamp = reader.readTime(),
              let duration = reader.readTime(),
              let syncByte = reader.readUInt8(),
              let sampleCount = reader.readUInt32() else { return nil }

        guard let formatDescription = readFormatDescription(&reader) else { return nil }
        guard let payloadLength = reader.readUInt32(), let payload = reader.readBytes(Int(payloadLength)) else {
            return nil
        }

        var timing = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: presentationTimeStamp,
            decodeTimeStamp: .invalid
        )
        guard let blockBuffer = makeBlockBuffer(payload) else { return nil }

        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: CMItemCount(sampleCount),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else { return nil }

        if syncByte == 0 {
            markNotSync(sampleBuffer)
        }
        _ = mediaTypeByte
        return sampleBuffer
    }

    // MARK: Sample buffer helpers

    private static func blockData(of sampleBuffer: CMSampleBuffer) -> Data? {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return nil
        }
        let length = CMBlockBufferGetDataLength(dataBuffer)
        guard length > 0 else { return Data() }
        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(dataBuffer, atOffset: 0, dataLength: length, destination: base)
        }
        return status == noErr ? data : nil
    }

    private static func makeBlockBuffer(_ data: Data) -> CMBlockBuffer? {
        var blockBuffer: CMBlockBuffer?
        let status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: data.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: data.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let blockBuffer else { return nil }
        let copyStatus = data.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: data.count)
        }
        return copyStatus == kCMBlockBufferNoErr ? blockBuffer : nil
    }

    private static func isSync(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
              let first = attachments.first,
              let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool else {
            return true
        }
        return !notSync
    }

    private static func markNotSync(_ sampleBuffer: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) as? NSMutableArray,
              let first = attachments.firstObject as? NSMutableDictionary else {
            return
        }
        first[kCMSampleAttachmentKey_NotSync] = kCFBooleanTrue
    }

    // MARK: Format description

    private static func writeFormatDescription(_ formatDescription: CMFormatDescription, into writer: inout ByteWriter) {
        let mediaType = CMFormatDescriptionGetMediaType(formatDescription)
        if mediaType == kCMMediaType_Video {
            writer.writeUInt8(0)
            let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
            writer.writeUInt32(CMFormatDescriptionGetMediaSubType(formatDescription))
            writer.writeUInt32(UInt32(truncatingIfNeeded: dimensions.width))
            writer.writeUInt32(UInt32(truncatingIfNeeded: dimensions.height))
            let atomsRaw = (CMFormatDescriptionGetExtension(formatDescription, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any]) ?? [:]
            let atoms = atomsRaw.compactMapValues { $0 as? Data }
            writer.writeUInt32(UInt32(atoms.count))
            for (key, value) in atoms {
                let keyData = Data(key.utf8)
                writer.writeUInt32(UInt32(keyData.count))
                writer.writeBytes(keyData)
                writer.writeUInt32(UInt32(value.count))
                writer.writeBytes(value)
            }
        } else if mediaType == kCMMediaType_Audio {
            writer.writeUInt8(1)
            let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee ?? AudioStreamBasicDescription()
            writer.writeUInt64(asbd.mSampleRate.bitPattern)
            writer.writeUInt32(asbd.mFormatID)
            writer.writeUInt32(asbd.mFormatFlags)
            writer.writeUInt32(asbd.mBytesPerPacket)
            writer.writeUInt32(asbd.mFramesPerPacket)
            writer.writeUInt32(asbd.mBytesPerFrame)
            writer.writeUInt32(asbd.mChannelsPerFrame)
            writer.writeUInt32(asbd.mBitsPerChannel)
            var cookieSize = 0
            let cookie = CMAudioFormatDescriptionGetMagicCookie(formatDescription, sizeOut: &cookieSize)
            if let cookie, cookieSize > 0 {
                writer.writeUInt32(UInt32(cookieSize))
                writer.writeBytes(Data(bytes: cookie, count: cookieSize))
            } else {
                writer.writeUInt32(0)
            }
        } else {
            writer.writeUInt8(255)
        }
    }

    private static func readFormatDescription(_ reader: inout ByteReader) -> CMFormatDescription? {
        guard let kind = reader.readUInt8() else { return nil }
        switch kind {
        case 0:
            guard let codec = reader.readUInt32(),
                  let width = reader.readUInt32(),
                  let height = reader.readUInt32(),
                  let atomCount = reader.readUInt32() else { return nil }
            var atoms: [String: Data] = [:]
            for _ in 0..<atomCount {
                guard let keyLength = reader.readUInt32(), let keyData = reader.readBytes(Int(keyLength)),
                      let valueLength = reader.readUInt32(), let valueData = reader.readBytes(Int(valueLength)) else {
                    return nil
                }
                atoms[String(decoding: keyData, as: UTF8.self)] = valueData
            }
            let extensions: [CFString: Any] = [kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: atoms]
            var formatDescription: CMFormatDescription?
            let status = CMVideoFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                codecType: codec,
                width: Int32(truncatingIfNeeded: width),
                height: Int32(truncatingIfNeeded: height),
                extensions: extensions as CFDictionary,
                formatDescriptionOut: &formatDescription
            )
            return status == noErr ? formatDescription : nil
        case 1:
            guard let sampleRateBits = reader.readUInt64(),
                  let formatID = reader.readUInt32(),
                  let formatFlags = reader.readUInt32(),
                  let bytesPerPacket = reader.readUInt32(),
                  let framesPerPacket = reader.readUInt32(),
                  let bytesPerFrame = reader.readUInt32(),
                  let channelsPerFrame = reader.readUInt32(),
                  let bitsPerChannel = reader.readUInt32(),
                  let cookieLength = reader.readUInt32(),
                  let cookie = reader.readBytes(Int(cookieLength)) else { return nil }
            var asbd = AudioStreamBasicDescription(
                mSampleRate: Float64(bitPattern: sampleRateBits),
                mFormatID: formatID,
                mFormatFlags: formatFlags,
                mBytesPerPacket: bytesPerPacket,
                mFramesPerPacket: framesPerPacket,
                mBytesPerFrame: bytesPerFrame,
                mChannelsPerFrame: channelsPerFrame,
                mBitsPerChannel: bitsPerChannel,
                mReserved: 0
            )
            var formatDescription: CMFormatDescription?
            let status: OSStatus = cookie.isEmpty
                ? CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &formatDescription)
                : cookie.withUnsafeBytes { raw in
                    CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: cookie.count, magicCookie: raw.baseAddress, extensions: nil, formatDescriptionOut: &formatDescription)
                }
            return status == noErr ? formatDescription : nil
        default:
            return nil
        }
    }
}

// MARK: - Byte IO

private struct ByteWriter {
    private(set) var data = Data()

    mutating func writeUInt8(_ value: UInt8) {
        data.append(value)
    }

    mutating func writeUInt32(_ value: UInt32) {
        var big = value.bigEndian
        withUnsafeBytes(of: &big) { data.append(contentsOf: $0) }
    }

    mutating func writeUInt64(_ value: UInt64) {
        var big = value.bigEndian
        withUnsafeBytes(of: &big) { data.append(contentsOf: $0) }
    }

    mutating func writeBytes(_ bytes: Data) {
        data.append(bytes)
    }

    mutating func writeTime(_ time: CMTime) {
        writeUInt64(UInt64(bitPattern: time.value))
        writeUInt32(UInt32(bitPattern: time.timescale))
        writeUInt32(time.flags.rawValue)
    }
}

private struct ByteReader {
    private let data: Data
    private var offset = 0

    init(_ data: Data) {
        self.data = data
    }

    mutating func readUInt8() -> UInt8? {
        guard offset + 1 <= data.count else { return nil }
        defer { offset += 1 }
        return data[data.startIndex + offset]
    }

    mutating func readUInt32() -> UInt32? {
        guard let value = readUInt64Width(4) else { return nil }
        return UInt32(truncatingIfNeeded: value)
    }

    mutating func readUInt64() -> UInt64? {
        readUInt64Width(8)
    }

    mutating func readBytes(_ count: Int) -> Data? {
        guard count >= 0, offset + count <= data.count else { return nil }
        defer { offset += count }
        let start = data.startIndex + offset
        return data[start..<start + count]
    }

    mutating func readTime() -> CMTime? {
        guard let value = readUInt64(), let timescale = readUInt32(), let flags = readUInt32() else {
            return nil
        }
        return CMTime(
            value: CMTimeValue(bitPattern: value),
            timescale: CMTimeScale(bitPattern: timescale),
            flags: CMTimeFlags(rawValue: flags),
            epoch: 0
        )
    }

    private mutating func readUInt64Width(_ width: Int) -> UInt64? {
        guard offset + width <= data.count else { return nil }
        var value: UInt64 = 0
        for _ in 0..<width {
            value = (value << 8) | UInt64(data[data.startIndex + offset])
            offset += 1
        }
        return value
    }
}
