# 開發指南

## 開發環境設定

### 必要條件

- Xcode 15.0+
- Swift 5.9+
- iOS 15.0+ / macOS 12.0+ / tvOS 15.0+ / visionOS 1.0+
- 實體裝置（用於相機/麥克風測試）

### 專案設定

```bash
git clone https://github.com/shogo4405/HaishinKit.swift.git
cd HaishinKit.swift
open Package.swift
```

### Xcode Workspace

使用 `Package.swift` 開啟即可，Swift Package Manager 會自動解析依賴。

## 專案結構

```
HaishinKit.swift/
├── HaishinKit/          # 核心框架
│   ├── Sources/
│   │   ├── Codec/       # 編解碼器
│   │   ├── Extension/   # 擴充方法
│   │   ├── ISO/         # ISO 格式處理
│   │   ├── Mixer/       # MediaMixer
│   │   ├── Network/     # 網路層
│   │   ├── Screen/      # 螢幕捕捉
│   │   ├── Session/     # Session 管理
│   │   ├── Stream/      # 串流抽象
│   │   ├── Util/        # 工具
│   │   └── View/        # UI 元件
│   └── Tests/
├── RTMPHaishinKit/      # RTMP 協定
│   └── Sources/
│       ├── AMF/         # AMF 序列化
│       ├── Codec/       # RTMP 編解碼
│       ├── Extension/   # URL 擴充
│       └── RTMP/        # 核心 RTMP 實作
├── SRTHaishinKit/       # SRT 協定
├── RTCHaishinKit/       # WebRTC
├── MoQTHaishinKit/      # Media over QUIC
└── Examples/            # 範例應用
```

## 開發規範

### 程式碼風格

- 遵循 Swift API Design Guidelines
- 使用 4 個空格縮排
- 使用 `// MARK: -` 組織程式碼
- Actor 優先於鎖
- 避免強循環引用

### 命名慣例

| 項目 | 慣例 | 範例 |
|------|------|------|
| 類型 | PascalCase | `RTMPConnection` |
| 屬性 | camelCase | `connected` |
| 列舉 | PascalCase | `HowToPublish` |
| 協定 | PascalCase | `StreamSession` |
| 泛型參數 | PascalCase | `T` |

### 非同步程式碼

```swift
// ✅ 正確：使用 actor 保護狀態
public actor RTMPConnection {
    private var connected = false
    
    func connect() async throws {
        // ...
    }
}

// ✅ 正確：使用 AsyncStream
var status: AsyncStream<RTMPStatus> {
    AsyncStream { continuation in
        statusContinuation = continuation
    }
}
```

### 錯誤處理

```swift
// ✅ 正確：定義明確的錯誤類型
enum Error: Swift.Error {
    case invalidState
    case connectionTimedOut
    case requestFailed(response: RTMPResponse)
}

// ✅ 正確：使用 throwing 函數
func connect(_ command: String) async throws -> RTMPResponse {
    guard !connected else {
        throw Error.invalidState
    }
    // ...
}
```

## 新增通訊協定

要新增一個通訊協定支援：

1. 建立新的模組（如 `XYZHaishinKit`）
2. 實作 `StreamSession` 協定
3. 實作 `StreamSessionFactory` 協定
4. 在應用啟動時註冊 Factory

```swift
public struct XYZSessionFactory: StreamSessionFactory {
    public let supportedProtocols: Set<String> = ["xyz"]
    
    public func make(_ uri: URL, mode: StreamSessionMode, configuration: (any StreamSessionConfiguration)?) -> any StreamSession {
        return XYZSession(uri: uri, mode: mode, configuration: configuration)
    }
}

// 註冊
await StreamSessionBuilderFactory.shared.register(XYZSessionFactory())
```

## 建置與測試

### 建置

```bash
# 建置所有目標
swift build

# 建置特定模組
swift build --target RTMPHaishinKit
```

### 測試

```bash
# 執行所有測試
swift test

# 執行特定模組測試
swift test --filter RTMPConnectionTests
```

詳見 [TESTING.md](TESTING.md)。

## 提交 PR

1. Fork 儲存庫
2. 建立功能分支
3. 撰寫測試
4. 確保所有測試通過
5. 提交 PR 並附上詳細說明

## 持續整合

專案使用 GitHub Actions 進行 CI：

- **test.yml**: 單元測試
- **lint.yml**: SwiftLint 檢查
- **build.yml**: 各平台建置驗證