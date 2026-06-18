import OSLog

/// The identifier for the HaishinKit WebRTC integration.
public let kRTCHaishinKitIdentifier = "com.haishinkit.RTCHaishinKit"

nonisolated(unsafe) let logger = HaishinKitLogger(osLog: OSLog(subsystem: kRTCHaishinKitIdentifier, category: "RTC"))
