import OSLog

public let kSRTHaishinKitIdentifier = "com.haishinkit.SRTHaishinKit"
nonisolated(unsafe) let logger = HaishinKitLogger(osLog: OSLog(subsystem: kSRTHaishinKitIdentifier, category: "SRT"))
