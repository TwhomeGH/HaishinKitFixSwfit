# NWConnection 遞迴 receive 模式

## 問題

`NWConnection.receive` 的 completion handler 內部直接呼叫 `self.receive(...)` 會造成潛在的 stack overflow。

### 危險模式

```swift
// ❌ 危險：callback 內直接遞迴
private func receive() {
    connection.receive(...) { data, _, _, _ in
        // ... 處理 data ...
        self.receive() // ← 如果 callback 同步觸發，stack 一直增長
    }
}
```

`NWConnection` 在資料已緩衝的情況下**可能同步呼叫 completion handler**，此時 `self.receive()` 等同於在當前 stack frame 上遞迴。當大量資料湧入（例如初始化階段的 batch 訊息）時，stack 在數毫秒內就會用盡，導致 `EXC_BAD_ACCESS / KERN_PROTECTION_FAILURE`。

### 影響範圍

- **ReplyKIT (擴展端)** — `SocketClient.receive()` 原本使用此模式
- **liveAPP (主 App)** — `SocketServer.receive(from:)` 原本使用此模式  
- **HaishinKitFixSwfit `MoQTSocket`** — `receive(on:continuation:)` 原本使用此模式

### ByteArray 泛型特化遞迴

另一個相關的遞迴問題發生在 Swift compiler 對 `ExpressibleByIntegerLiteral.init(data:)` 的泛型特化：

```
readUInt32()
  → UInt32(data: Data[...]) 
    → ExpressibleByIntegerLiteral.init(data: Data)  ← 泛型
      → Data.withUnsafeBytes<UInt32>                ← compiler 特化
        → ❌ 無限遞迴 (compiler bug?)
```

所有 `ByteArray.readUInt*()`/`readInt*()` 方法都經過此路徑。將 BigEndian 讀取改為直接 byte arithmetic 即可繞過。

### Crash 特徵

- Exception: `EXC_BAD_ACCESS / KERN_PROTECTION_FAILURE`
- Faulting thread 在 `com.apple.root.user-initiated-qos.cooperative` 佇列
- Stack depth 固定約 11,162 frames（544KB stack / ~49 bytes per frame）
- 發生在啟動初期 socket 大量資料交換時

## 修復方式

### 1. receive loop → async/await

```swift
// ✅ 安全：每次 iteration 經過 suspension point
private func runReceiveLoop() async {
    while !Task.isCancelled {
        let data = await withCheckedContinuation { continuation in
            connection.receive(...) { content, _, _, _ in
                continuation.resume(returning: content)
            }
        }
        guard let data else { break }
        process(data)
    }
}
```

### 2. `withUnsafeBytes<UInt32>` 遞迴 → 直接 byte shift

```swift
// ❌ 危險：走 ExpressibleByIntegerLiteral
return UInt32(data: data[pos-4..<pos]).bigEndian

// ✅ 安全：直接 byte arithmetic  
let result = UInt32(data[pos]) << 24
           | UInt32(data[pos+1]) << 16
           | UInt32(data[pos+2]) << 8
           | UInt32(data[pos+3])
```

## 受影響檔案

| 檔案 | 修改內容 |
|------|----------|
| `ReplyKIT/Socket.swift` | `receive()` → `runReceiveLoop()` async loop |
| `liveAPP/Socket.swift` | `receive(from:)` → `runReceiveLoop()` async loop |
| `MoQTHaishinKit/Sources/MoQTSocket.swift` | `receive(on:continuation:)` → `startReceiveLoop()` async loop |
| `RTMPHaishinKit/Sources/Util/ByteArray.swift` | `UIntX(data:)` → direct byte arithmetic |
| `HaishinKit/Sources/Util/ByteArray.swift` | `UIntX(data:)` → direct byte arithmetic |
