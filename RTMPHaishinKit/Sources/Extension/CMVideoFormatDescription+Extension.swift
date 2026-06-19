import CoreImage
import CoreMedia
import VideoToolbox

extension CMVideoFormatDescription {
    var configurationBox: Data? {
        if let atoms = CMFormatDescriptionGetExtension(self, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? NSDictionary {
            switch mediaSubType {
            case .h264:
                if let avcC = atoms["avcC"] as? Data {
                    return avcC
                }
            case .hevc:
                if let hvcC = atoms["hvcC"] as? Data {
                    return hvcC
                }
            default:
                return nil
            }
        }
        return makeConfigurationBoxFromParameterSets()
    }

    private func makeConfigurationBoxFromParameterSets() -> Data? {
        switch mediaSubType {
        case .h264:
            return makeAVCConfigurationBox()
        case .hevc:
            return makeHEVCConfigurationBox()
        default:
            return nil
        }
    }

    private func makeAVCConfigurationBox() -> Data? {
        var totalCount: Int = 0
        var nalUnitHeaderLength: Int32 = 0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(self, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &totalCount, nalUnitHeaderLengthOut: &nalUnitHeaderLength) == noErr,
              totalCount > 0 else {
            return nil
        }
        var parameterSets: [(data: [UInt8], isSPS: Bool)] = []
        for i in 0..<totalCount {
            var ptr: UnsafePointer<UInt8>?
            var size: Int = 0
            guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(self, parameterSetIndex: i, parameterSetPointerOut: &ptr, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr,
                  let ptr, size > 0 else {
                return nil
            }
            let data = Array(UnsafeBufferPointer(start: ptr, count: size))
            let nalType = data[0] & 0x1F
            parameterSets.append((data, nalType == 7))
        }
        var record = AVCDecoderConfigurationRecord()
        record.configurationVersion = 1
        if let firstSPS = parameterSets.first(where: { $0.isSPS })?.data, firstSPS.count >= 4 {
            record.avcProfileIndication = firstSPS[1]
            record.profileCompatibility = firstSPS[2]
            record.avcLevelIndication = firstSPS[3]
        }
        record.lengthSizeMinusOneWithReserved = UInt8(nalUnitHeaderLength - 1) & 0x03 | 0xFC
        record.sequenceParameterSets = parameterSets.filter { $0.isSPS }.map { $0.data }
        record.numOfSequenceParameterSetsWithReserved = UInt8(record.sequenceParameterSets.count) & 0x1F | AVCDecoderConfigurationRecord.reserveNumOfSequenceParameterSets
        record.pictureParameterSets = parameterSets.filter { !$0.isSPS }.map { $0.data }
        return record.data
    }

    private func makeHEVCConfigurationBox() -> Data? {
        nil
    }

    func makeDecodeConfigurtionRecord() -> (any DecoderConfigurationRecord)? {
        guard let configurationBox else {
            return nil
        }
        switch mediaSubType {
        case .h264:
            return AVCDecoderConfigurationRecord(data: configurationBox)
        case .hevc:
            return HEVCDecoderConfigurationRecord(data: configurationBox)
        default:
            return nil
        }
    }
}
