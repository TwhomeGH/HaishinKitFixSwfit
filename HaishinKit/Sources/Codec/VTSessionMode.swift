import Foundation
import VideoToolbox

enum VTSessionMode {
    case compression
    case decompression

    private func makeCompressionSession(_ videoCodec: VideoCodec, profileLevel: String) throws -> any VTSessionConvertible {
        var session: VTCompressionSession?
        var options = videoCodec.settings.makeOptions()
        options.update(with: .init(key: .profileLevel, value: profileLevel as NSObject))
        var status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(videoCodec.settings.videoSize.width),
            height: Int32(videoCodec.settings.videoSize.height),
            codecType: videoCodec.settings.format.codecType,
            encoderSpecification: videoCodec.settings.makeEncoderSpecification(),
            imageBufferAttributes: videoCodec.makeImageBufferAttributes(.compression) as CFDictionary?,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )
        guard status == noErr, let session else {
            throw VTSessionError.failedToCreate(status: status)
        }
        status = session.setOptions(options)
        guard status == noErr else {
            throw VTSessionError.failedToPrepare(status: status)
        }
        status = session.prepareToEncodeFrames()
        guard status == noErr else {
            throw VTSessionError.failedToPrepare(status: status)
        }
        if let expectedFrameRate = videoCodec.settings.expectedFrameRate {
            status = session.setOption(.init(key: .expectedFrameRate, value: expectedFrameRate as CFNumber))
        }
        videoCodec.frameInterval = videoCodec.settings.frameInterval
        if profileLevel != videoCodec.settings.profileLevel {
            logger.info("HEVC fallback: using profile", profileLevel, "instead of requested", videoCodec.settings.profileLevel)
        }
        return session
    }

    func makeSession(_ videoCodec: VideoCodec) throws -> any VTSessionConvertible {
        switch self {
        case .compression:
            let profilesToTry: [String]
            if videoCodec.settings.format == .hevc {
                profilesToTry = VideoCodecSettings.hevcFallbackChain(for: videoCodec.settings.profileLevel)
            } else {
                profilesToTry = [videoCodec.settings.profileLevel]
            }
            var lastError: Error?
            for profile in profilesToTry {
                do {
                    return try makeCompressionSession(videoCodec, profileLevel: profile)
                } catch {
                    lastError = error
                    logger.warn("VTCompressionSession failed with profile", profile, "error:", error)
                }
            }
            if let lastError {
                throw lastError
            }
            throw VTSessionError.failedToCreate(status: -1)
        case .decompression:
            guard let formatDescription = videoCodec.inputFormat else {
                throw VTSessionError.failedToCreate(status: kVTParameterErr)
            }
            var session: VTDecompressionSession?
            let status = VTDecompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                formatDescription: formatDescription,
                decoderSpecification: nil,
                imageBufferAttributes: videoCodec.makeImageBufferAttributes(.decompression) as CFDictionary?,
                outputCallback: nil,
                decompressionSessionOut: &session
            )
            guard let session, status == noErr else {
                throw VTSessionError.failedToCreate(status: status)
            }
            return session
        }
    }
}
