import HaishinKit
import libdatachannel

extension VideoCodecSettings.Format {
    var cValue: rtcCodec {
        switch self {
        case .h264:
            return RTC_CODEC_H264
        case .hevc:
            return RTC_CODEC_H265
        case .vp9, .av1:
            return RTC_CODEC_H265
        }
    }
}
