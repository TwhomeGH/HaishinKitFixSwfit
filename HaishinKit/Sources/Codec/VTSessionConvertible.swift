import CoreMedia
import Foundation
import VideoToolbox

enum VTSessionError: Swift.Error {
    case failedToCreate(status: OSStatus)
    case failedToPrepare(status: OSStatus)
    case failedToConvert(status: OSStatus)
}

protocol VTSessionConvertible {
    func setOption(_ option: VTSessionOption) -> OSStatus
    func setOptions(_ options: Set<VTSessionOption>) -> OSStatus
    /// Encode a frame. Returns true if VT dropped the frame.
    @discardableResult
    func convert(
        _ sampleBuffer: CMSampleBuffer,
        forceKeyFrame: Bool,
        continuation: AsyncStream<CMSampleBuffer>.Continuation?
    ) throws -> Bool
    func invalidate()
    /// Read a property from the VT session (e.g., numberOfPendingFrames).
    func copyProperty(_ key: CFString) -> Any?
}

extension VTSessionConvertible where Self: VTSession {
    func setOption(_ option: VTSessionOption) -> OSStatus {
        return VTSessionSetProperty(self, key: option.key.CFString, value: option.value)
    }

    func setOptions(_ options: Set<VTSessionOption>) -> OSStatus {
        var properties: [AnyHashable: AnyObject] = [:]
        for option in options {
            properties[option.key.CFString] = option.value
        }
        return VTSessionSetProperties(self, propertyDictionary: properties as CFDictionary)
    }

    func copyProperty(_ key: CFString) -> Any? {
        var value: CFTypeRef?
        let status = VTSessionCopyProperty(self, key: key, allocator: kCFAllocatorDefault, valueOut: &value)
        guard status == noErr else { return nil }
        return value
    }
}
