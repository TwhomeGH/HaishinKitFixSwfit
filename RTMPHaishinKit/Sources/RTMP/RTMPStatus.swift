import Foundation

/// RTMP 回報的狀態事件，保留協定事件代碼、等級與說明。
@dynamicMemberLookup
public struct RTMPStatus: Sendable {
    /// 協定事件代碼，例如 NetConnection.Connect.Success。
    public let code: String
    /// 事件等級，通常為 "status" 或 "error"。
    public let level: String
    /// 事件的文字說明。
    public let description: String

    private let data: AMFObject?

    init?(_ data: AMFObject?) {
        guard
            let data,
            let code = data["code"] as? String,
            let level = data["level"] as? String else {
            return nil
        }
        self.data = data
        self.code = code
        self.level = level
        self.description = (data["description"] as? String) ?? ""
    }

    init(code: String, level: String, description: String) {
        self.code = code
        self.level = level
        self.description = description
        self.data = nil
    }

    public subscript(dynamicMember key: String) -> String? {
        guard let value = data?[key] as? String else {
            return nil
        }
        return value
    }

    public subscript(dynamicMember key: String) -> Double? {
        guard let value = data?[key] as? Double else {
            return nil
        }
        return value
    }
}
