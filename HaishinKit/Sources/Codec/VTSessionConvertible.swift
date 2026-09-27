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
    /// 編碼一顆 frame；回傳 true 表示 VT 同步丟棄了它。
    /// `outputState` 在 VT 非同步 callback 內回報「實際輸出是否為 keyframe /
    /// 是否失敗」，是壓縮路徑用來判斷 keyframe 是否真的成功的依據。
    /// 解壓縮路徑（VTDecompressionSession）用不到，會忽略此參數。
    @discardableResult
    func convert(
        _ sampleBuffer: CMSampleBuffer,
        forceKeyFrame: Bool,
        continuation: AsyncStream<CMSampleBuffer>.Continuation?,
        outputState: VideoEncoderOutputState
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
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            VTSessionCopyProperty(self, key: key, allocator: kCFAllocatorDefault,
                                  valueOut: UnsafeMutableRawPointer(ptr))
        }
        guard status == noErr else { return nil }
        return value
    }
}
