# 日誌架構與遠端日誌

HaishinKit 的日誌系統分兩層，app 可不下 Xcode 就把 framework 內部日誌送到伺服器。

## 兩層日誌

| 層 | 物件 | 輸出 |
|----|------|------|
| **module logger** | `logger`（`HaishinKit/Sources/Util/Constants.swift`，`HaishinKitLogger`） | mixer/codec/util 的內部日誌（音訊軌來源格式、AEC、resync、stall、channelMap 等），同時寫 os_log |
| **RTMP connection** | `RTMPConnection.log()` → `onLog` | RTMP 層（socket、publish、throughput、timestamp）與被轉送進來的 module logger 日誌 |

## 多 handler 並存（CHANGES #39）

`HaishinKitLogger` 支援多個 handler：

- **`onLog`**：主插槽（單一）。`RTMPConnection` 在 `init` 與 `performConnect` 時接管它，
  把 module logger 輸出轉送到 `connection.log()`（經 `await` hop 到 actor）；
  `close()`/`deinit` 解除。
- **`addLogHandler` / `removeLogHandler`**：額外 handler 列表（thread-safe），
  與主插槽並存、互不覆蓋。

## 使用方式

**主要（夠用）：`connection.setOnLog`**——connect 後 framework 內部所有
`logger.*` 輸出都會被轉送進來：

```swift
await connection.setOnLog { event in
    // 送你的伺服器（sendlog）
    sendlog(message: "[\(event.level)] \(event.message) \(event.detail ?? "")")
}
```

connect 後會先收到一條 `HaishinKit.logger forwarding to onLog is active` 確認入口。

**額外（有需要才用）：`logger.addLogHandler`**——不依賴 connection 時序，直接
收 module logger 日誌（例如 mixer 比 connection 早啟動、要收啟動期的 track 格式
日誌時），與 connection 轉送並存：

```swift
HaishinKit.logger.addLogHandler { level, message in
    sendlog(message: "[HK][\(level)] \(message)")
}
```

### 移除 handler（`removeLogHandler`）

`removeLogHandler` 用**閉包身分（`===`）**比對，所以必須保留**同一個 closure 實例**——
不能重新寫一遍（那會是不同實體）：

```swift
// 先保留實例
let handler: @Sendable (LogLevel, String) -> Void = { level, message in
    sendlog(message: "[HK][\(level)] \(message)")
}
HaishinKit.logger.addLogHandler(handler)

// 之後用同一個實例移除
HaishinKit.logger.removeLogHandler(handler)
```

若沒保留實例，只能清空重建：把 `logger.onLog` 設回 `nil` 只會影響主插槽，
`extraHandlers` 需靠實例移除（或直接不移除——多一個 handler 僅多一次呼叫，無害）。

## 注意事項

- **`minimumLogLevel`**（RTMPConnection，預設過濾 trace/debug）照常生效；module
  logger 的 `minimumLevel` 預設 `.trace`。
- **`HaishinKit.logger` 需顯式命名**：RTMPHaishinKit module 有自己的 `logger` 全域
  （category "RTMP"）會 shadow HaishinKit 的，裸 `logger` 解析到錯誤的那個。
- **`logger` 是 `var`**：`HaishinKitLogger` 是 struct，`let` binding 無法改 `onLog`。
- 在 RTMP module 用 `LogLevel` 需 `import HaishinKit`。
