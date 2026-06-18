import OSLog

/// The identifier for the HaishinKit RTMP integration.
public let kRTMPHaishinKitIdentifier = "com.haishinkit.RTMPHaishinKit"

nonisolated(unsafe) let logger = HaishinKitLogger(osLog: OSLog(subsystem: kRTMPHaishinKitIdentifier, category: "RTMP"))
