# 泛型特化遞迴 (ExpressibleByIntegerLiteral)

## 問題

`ExpressibleByIntegerLiteral.init(data: Data)` 使用 `data.withUnsafeBytes { $0.pointee }` 
來讀取整數值，但這個 closure 回傳型別是 `Self`（例如 `UInt32`），導致 Swift compiler 
產生 `Data.withUnsafeBytes<UInt32>` 的泛型特化版本。

在特定情況下，這個 compiler 產生的特化函數會形成**無限遞迴**，造成 stack overflow。

### 影響範圍

所有透過 `UIntX(data: Data[...])` 路徑讀取整數的地方：

| 檔案 | 使用模式 |
|------|----------|
| `HaishinKit/Sources/Util/ByteArray.swift` | `UInt32(data: data[pos-4..<pos]).bigEndian` |
| `RTMPHaishinKit/Sources/Util/ByteArray.swift` | 同上 |
| `SRTHaishinKit/Sources/TS/ByteArray.swift` | 同上 |
| `RTMPHaishinKit/Sources/RTMP/RTMPChunk.swift` | 直接呼叫 |
| `RTMPHaishinKit/Sources/RTMP/RTMPMessage.swift` | 直接呼叫 |
| `RTCHaishinKit/Sources/RTP/RTPPacket.swift` | 直接呼叫 |

### Crash 特徵

- 與 NWConnection 遞迴相同：`EXC_BAD_ACCESS / KERN_PROTECTION_FAILURE`
- depth 固定 ~11,162 frames（544KB stack / ~49 bytes per frame）
- 發生在 cooperative thread pool 上
- 啟動初期 socket 資料解析時觸發

## 修復方式

### 原本程式碼

```swift
// HaishinKit/Sources/Extension/ExpressibleByIntegerLiteral+Extension.swift
init(data: Data) {
    let diff: Int = MemoryLayout<Self>.size - data.count
    if 0 < diff {
        var buffer = Data(repeating: 0, count: diff)
        buffer.append(data)
        self = buffer.withUnsafeBytes { $0.baseAddress!.assumingMemoryBound(to: Self.self).pointee }
        return
    }
    self = data.withUnsafeBytes { $0.baseAddress!.assumingMemoryBound(to: Self.self).pointee }
    //                   ^^^^^^^^^^^^^^^  closure 回傳 Self → 產生 withUnsafeBytes<UInt32> 特化
}
```

### 修正後

```swift
init(data: Data) {
    let count = min(data.count, MemoryLayout<Self>.size)
    var result: Self = 0
    withUnsafeMutableBytes(of: &result) { dest in
        let src = data.withUnsafeBytes { $0 }  // ← 回傳 UnsafeRawBufferPointer，不是 Self
        guard let base = src.baseAddress else { return }
        dest.copyMemory(from: UnsafeRawBufferPointer(start: base, count: count))
    }
    self = result
}
```

關鍵差異：
- `data.withUnsafeBytes { $0 }` 回傳 `UnsafeRawBufferPointer`，**不是** `Self`
- compiler 不會產生 `withUnsafeBytes<UInt32>` 的特化
- 用 `withUnsafeMutableBytes(of: &result)` + `copyMemory` 複製 byte

## 受影響檔案

| 檔案 | 修改內容 |
|------|----------|
| `HaishinKit/Sources/Extension/ExpressibleByIntegerLiteral+Extension.swift` | `init(data:)` 改用 `copyMemory`，避免 `withUnsafeBytes<Self>` 特化 |
| `MoQTHaishinKit/Sources/Extension/ExpressibleByIntegerLiteral+Extension.swift` | 同上 |
