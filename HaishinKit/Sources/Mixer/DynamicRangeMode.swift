import AVFoundation
import CoreImage

/// 定義影片擷取與畫面合成使用的動態範圍。
///
/// - Note: HDR 模式目前**尚未支援即時串流**；只用於本機處理／錄製時，
///   仍需確認下游 encoder 與輸出格式支援 10-bit／HLG。
public enum DynamicRangeMode: Sendable {
    private static let colorSpaceITUR709 = CGColorSpace(name: CGColorSpace.itur_709)
    private static let colorSpaceITUR2100 = CGColorSpace(name: CGColorSpace.itur_2100_HLG)

    /// 標準動態範圍：8-bit YUV 420（VideoRange）＋ ITU-R BT.709。
    case sdr

    /// 高動態範圍：10-bit YUV 420（VideoRange）＋ ITU-R BT.2100 HLG。
    /// 輸出的 pixel buffer 會帶上 BT.2020 primaries／HLG transfer。
    case hdr

    var videoFormat: OSType {
        switch self {
        case .sdr:
            return kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        case .hdr:
            return kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        }
    }

    var colorSpace: CGColorSpace? {
        switch self {
        case .sdr:
            return DynamicRangeMode.colorSpaceITUR709
        case .hdr:
            return DynamicRangeMode.colorSpaceITUR2100
        }
    }

    private var contextOptions: [CIContextOption: Any]? {
        guard let colorSpace else {
            return nil
        }
        return [
            .workingFormat: CIFormat.RGBAh.rawValue,
            .workingColorSpace: colorSpace,
            .outputColorSpace: colorSpace
        ]
    }

    func attach(_ pixelBuffer: CVPixelBuffer) {
        switch self {
        case .sdr:
            break
        case .hdr:
            CVBufferSetAttachment(
                pixelBuffer,
                kCVImageBufferColorPrimariesKey,
                kCVImageBufferColorPrimaries_ITU_R_2020,
                .shouldPropagate
            )
            CVBufferSetAttachment(
                pixelBuffer,
                kCVImageBufferTransferFunctionKey,
                kCVImageBufferTransferFunction_ITU_R_2100_HLG,
                .shouldPropagate
            )
            CVBufferSetAttachment(
                pixelBuffer,
                kCVImageBufferYCbCrMatrixKey,
                kCVImageBufferYCbCrMatrix_ITU_R_2020,
                .shouldPropagate
            )
        }
    }

    func makeCIContext() -> CIContext {
        guard let device = MTLCreateSystemDefaultDevice() else {
            return CIContext(options: contextOptions)
        }
        return CIContext(mtlDevice: device, options: contextOptions)
    }

    func makePixelBufferAttributes(_ size: CGSize) -> CFDictionary {
        return [
            kCVPixelBufferPixelFormatTypeKey: NSNumber(value: videoFormat),
            kCVPixelBufferMetalCompatibilityKey: kCFBooleanTrue,
            kCVPixelBufferWidthKey: NSNumber(value: Int(size.width)),
            kCVPixelBufferHeightKey: NSNumber(value: Int(size.height))
        ] as CFDictionary
    }
}
