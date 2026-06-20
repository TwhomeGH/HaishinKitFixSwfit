# 測試指南

## 測試架構

HaishinKit.swift 使用 Swift Testing 框架進行單元測試。

## 測試目錄結構

```
各模組/
├── Tests/
│   ├── RTMP/
│   │   ├── RTMPConnectionTests.swift
│   │   ├── RTMPChunkBufferTests.swift
│   │   ├── RTMPURLTests.swift
│   │   ├── RTMPTimestampTests.swift
│   │   ├── RTMPStatusTests.swift
│   │   └── RTMPVideoFourCCTests.swift
│   └── ...
└── Sources/
```

## 執行測試

### 命令列

```bash
# 執行所有測試
swift test

# 執行特定測試類別
swift test --filter RTMPConnectionTests

# 執行特定測試方法
swift test --filter "RTMPConnectionTests/testReleaseWhenClose"

# 顯示詳細輸出
swift test -v
```

### Xcode

使用 `Cmd+U` 或在測試導覽面板中執行。

## 撰寫測試

### 基本測試結構

```swift
import Testing

@testable import RTMPHaishinKit

@Suite struct RTMPConnectionTests {
    @Test func releaseWhenClose() async throws {
        weak var weakConnection: RTMPConnection?
        _ = try? await {
            let connection = RTMPConnection()
            _ = try await connection.connect("rtmp://localhost:19350/live")
            try await connection.close()
            weakConnection = connection
        }()
        #expect(weakConnection == nil)
    }
}
```

### 測試 HTTP 伺服器

部分測試需要一個 RTMP 模擬伺服器。建議使用：

- [rtmp-server](https://github.com/shogo4405/rtmp-server) - Node.js RTMP 伺服器（測試用）
- 本地測試端點：`rtmp://localhost:19350/live`

## 測試覆蓋範圍

### 單元測試重點

| 領域 | 測試項目 |
|------|----------|
| 連線 | 連線/斷線、逾時、重連 |
| Handshake | C0/C1/S0/S1/C2/S2 封包格式 |
| Chunk | 基本標頭、類型 0/1/2/3 |
| Buffer | put/get、溢位、邊界條件 |
| URL | 解析、stream name、command |
| 狀態 | Code/Level/Description 解析 |

## 整合測試

目前整合測試需要實際的 RTMP 伺服器。測試涵蓋：

- 完整連線流程
- 發布串流
- 播放串流
- 斷線重連

## 持續整合

GitHub Actions 設定在 `.github/workflows/`：

```yaml
# test.yml
name: Test
on: [push, pull_request]
jobs:
  test:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4
      - run: swift test
```

## 疑難排解

### 測試逾時

如果測試逾時，檢查：
1. 是否需要實際的 RTMP 伺服器
2. `defaultTimeout` 設定是否足夠
3. 網路連線是否正常

### 測試失敗

常見原因：
1. 協定變更未更新測試
2. 非同步競態條件
3. 模擬器限制（如相機/麥克風）