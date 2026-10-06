# ``RTCHaishinKit``

本模組支援 WHIP/WHEP 協定。

## 🔍 Overview

RTCHaishinKit 是以 Swift 實作的 WHIP/WHEP 協定堆疊。內部使用由
[libdatachannel](https://github.com/paullouisageneau/libdatachannel) 建置並轉為 xcframework 的函式庫。

## 🎨 功能

- 發布（WHIP）
  - 支援 H264 與 OPUS。
- 播放（WHEP）
  - 支援 H264 與 OPUS。

## 📓 使用方式

### 日誌（Logging）

- 包裝 `rtcInitLogger` 的 Swift 方法。

```swift
await RTCLogger.shared.setLevel(.debug)
```

### Session

目前設計為搭配 Session API 使用。

```swift
import RTCHaishinKit

await StreamSessionBuilderFactory.shared.register(HTTPSessionFactory())
```
