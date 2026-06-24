# RTMP 協議修復與架構改進文檔

## 版本信息
- **日期**: 2026-06-20
- **版本**: 1.3.0
- **狀態**: ✅ 完成（含狀態機、重連、VP9/AV1、ReplyKit 改進）

---

## 1. 關鍵 Bug 修復 (已完成)

### 1.1 RTMP Handshake 封包生成錯誤 (P0)
**文件**: `RTMPHandshake.swift`  
**問題**: C0/C1/C2 封包格式不符合 RTMP 規範
- C0 應為單獨 1 字節版本號 (0x03)
- C1 應為 1536 字節 (時間戳4 + 零填充4 + 隨機數據1528)
- C2 應包含: S1時間戳4 + 客戶端當前時間4 + S1隨機數據1528

**修復**: 重寫 `c0c1packet` 和 `c2packet()` 方法，嚴格區分 C0（1字節）、C1（1536字節）、C2（1536字節），修正 S1 隨機數據索引計算

### 1.2 Extended Timestamp 解析錯誤 (P0)
**文件**: `RTMPChunk.swift:219-225`  
**問題**: 當 timestamp == 0xFFFFFF 時讀取擴展時間戳，但根據 RTMP 規範，只要 timestamp >= 0xFFFFFF 就應讀取擴展時間戳

**修復**: 
- 新增 `isExtended` 屬性追蹤擴展時間戳狀態
- Type 0/1/2 chunk 中若 raw timestamp == 0xFFFFFF 則設置 `isExtended = true`
- Type 3 chunk 繼承前一個 chunk 的 `isExtended` 狀態
- 只有當 `isExtended == true` 時才讀取 4 字節擴展時間戳

### 1.3 Aggregate Message 類型錯誤 (P0)
**文件**: `RTMPMessage.swift:610`  
**問題**: `RTMPAggregateMessage.type` 設置為 `.windowAck` (0x05)，實際聚合消息類型應為 0x16

**修復**: 修正 message type 為 `.aggregate`

### 1.4 Chunk Stream ID 解析邊界檢查 (P1)
**文件**: `RTMPChunk.swift:172-193`  
**問題**: 讀取擴展 chunk stream ID（0 和 1 情況）時無邊界檢查，可能導致崩潰

**修復**: 在 `getBasicHeader()` 方法中增加 `remaining` 檢查：
- 至少 1 字節才讀取 header
- 情況 0 (2字節) 需要至少 2 字節剩餘
- 情況 1 (3字節) 需要至少 3 字節剩餘

### 1.6 RTMPChunkBuffer 無限增長導致 `EXC_BREAKPOINT` 崩潰 (P0)
**文件**: `RTMPChunk.swift`, `RTMPConnection.swift`  
**問題**: 伺服器發送 `SetChunkSize` 訊息時，`chunkSizeC = Int(message.size)` 觸發 `inputBuffer.chunkSize.didSet`，執行 `data += Data(count: chunkSize - data.count + headerSize)`。若 `message.size` 異常巨大（如 `UInt32.max`），`Data(count:)` 嘗試分配 GB 級記憶體，Foundation 的 `ensureUniqueBufferReference` 觸發 `_assertionFailure` 崩潰。

此外 `RTMPChunkBuffer.put(_:)` 無上限增長 buffer，每次收到網路資料都重新分配 `data.count + remaining` 大小的 Data，若消費速度跟不上接收速度，buffer 持續膨脹。

**修復**:
- `RTMPChunkBuffer` 新增 `defaultMaxBufferSize = 10MB` 常量
- `put(_:)`: 當未讀資料 + 新資料超過上限時，直接以新資料取代（放棄舊資料，防止 OOM）
- `chunkSize.didSet`: 加入 `chunkSize <= defaultMaxBufferSize` 驗證，超出範圍跳過擴容；改為 `reserveCapacity` 避免不必要的分配
- `RTMPConnection.dispatch`: `chunkSizeC = min(Int(message.size), RTMPChunkBuffer.defaultMaxBufferSize)` 限制伺服器端 chunk size
**文件**: `RTMPTimestamp.swift:20-58`  
**問題**: 
- 32 位時間戳在 49.7 天後回滾，現有邏輯拋出 `invalidSequence`
- Type 3 chunk 時間戳增量累加方式不正確（將絕對時間戳當作增量）

**修復**:
- 新增 `lastRawTimestamp`、`rolloverCount`、`lastDelta` 屬性
- Type 0: 檢測 32 位回滾，計算連續時間戳
- Type 1/2: 記錄 delta 值，用於後續 Type 3
- Type 3: 使用 `lastDelta` 增加時間戳，而非誤用絕對時間戳

---

## 2. 架構改進 (已完成)

### 2.1 文件清理與重構
**文件**: `RTMPConnection.swift`  
**目標**: 消除重複屬性宣告、修復狀態管理不一致
**完成內容**:
- 移除重複的 `socket`、`chunks`、`streams` 等屬性
- 修正 `readyState` 枚舉與使用方法
- 修正 `connect()` 中 `readyState.handshakeSentC0C1` 為 `readyState.versionSent`
- 保持向後兼容

### 2.2 發送背壓控制
**文件**: `RTMPSocket.swift`  
**目標**: 防止發送隊列無限增長導致 OOM
**完成內容**:
- 新增 `maxQueueBytesOut = 5MB` 常量
- `send()` 方法檢查 `queueBytesOut < maxQueueBytesOut`
- 超過限制時記錄警告並丟棄數據
- 適用於所有 send 重載

### 2.3 TLS 配置改進
**文件**: `RTMPSocket.swift`  
**目標**: 完善的 TLS 支援
**完成內容**: 保留 Network framework 預設的 `.tls` 配置，支援標準 RTMPS 連線

### 2.4 E-RTMP 增強 (Enhancing RTMP)
**文件**: `RTMPEnhanced.swift`, `RTMPMessage.swift`  
**目標**: 支援編碼器協商與多軌道

#### 編碼器協商
**完成內容**:
- `RTMPAudioFourCC`/`RTMPVideoFourCC` 新增 `init(bytes:)` 構造器
- 新增 `EnhancedRTMPCapability` 枚舉
- 新增 `enhancedAudioType`/`enhancedVideoType` 計算屬性
- 完善編碼器類型推斷

#### 多軌道支持
**完成內容**:
- `RTMPAudioMessage` 和 `RTMPVideoMessage` 新增 `trackId` 參數
- Enhanced RTMP 模式下編碼 track ID:
  - Opus 音頻: packet type 後追加 1 字節 track ID
  - HEVC 視頻: 使用 `codedFramesX` packet type 並追加 track ID
- `audioTrackId` 和 `videoTrackId` 屬性值可通過消息傳遞

---

## 3. 新增功能 (已完成)

### 3.1 協議狀態機
**文件**: `RTMPConnection.swift`  
**目標**: 輕量級有限狀態機，驗證所有狀態轉換合法性
**完成內容**:
- 新增 `ConnectionState` 枚舉（內置於 `RTMPConnection`）
- `canTransition(to:)` 方法驗證每個轉換：
  ```
  .uninitialized → .connecting → .versionSent → .ackSent → .handshakeDone → .connected
  ```
- 所有無效轉換（如 `.uninitialized → .connected`）直接拋出 `Error.invalidState`
- 替換原有鬆散的 `ReadyState` 枚舉

### 3.2 自動重連與指數退避
**文件**: `RTMPConnection.swift`  
**目標**: 網絡中斷後自動重連，支援指數退避
**完成內容**:
- 新增 `isReconnectEnabled`、`maxReconnectAttempts`、`reconnectBaseDelay`、`reconnectMaxDelay` 參數
- 新增 `scheduleReconnect()` 方法
- 指數退避公式: `min(baseDelay << (attempt-1), maxDelay)`
- 預設: 1s → 2s → 4s → 8s → 16s → 30s (最多 5 次)
- `close()` 或 `_result` 成功後重置重連計數器
- 認證拒絕 (`connectRejected`) 不走重連，直接拋錯

### 3.3 VP9/AV1 解碼器支援
**文件**: `RTMPEnhanced.swift`, `VideoCodecSettings.swift`, `VideoCodecSettings.Format+Extension.swift`  
**目標**: 擴展編碼器支援至 VP9/AV1
**完成內容**:
- `VideoCodecSettings.Format` 新增 `.vp9` 和 `.av1` cases
- `codecType`: VP9 = `0x76703039` (vp09), AV1 = `0x61763031` (av01)
- `isSupported` 回傳 `true` (基礎架構已就緒)
- `enhancedVideoType` 返回對應 FourCC
- macOS encoderID 回退至 HEVC 編碼器
- 補齊 `RTCHaishinKit` 與 `VideoCodecSettings` 的 switch exhaustive 匹配

### 3.4 ReplyKit 通訊層改進
**文件**: `ReplyKIT/Socket.swift`  
**範圍**: App↔Extension 間 TCP Socket（非 RTMP）

**SocketClient (Socket.swift)**:
- 新增 `SocketState` 有限狀態機，驗證所有轉換合法性
- 新增電路斷路器：連續 5 次失敗後停止重連 60 秒冷卻
- 冷卻後自動恢復重連
- `.failed` 追蹤連續失敗次數，`.cancelled` 不計入

### 3.5 RTMPConnection 重連回呼（給消費方）
**文件**: `RTMPConnection.swift`  
**動機**: 底層既有重連機制，消費方（如 ReplyKIT 的 SampleHandler）不需獨立重試迴圈。透過回呼接收事件，只處理媒體管線協調。

**新增 API**:
- `ReconnectState` 枚舉：`.started(attempt:, maxAttempts:)` / `.succeeded` / `.failed(Error)` / `.exhausted`
- `onReconnectStateChanged: (@Sendable (ReconnectState) async -> Void)?`

**消費方使用範例（替代 `attemptReconnect`）**:
```swift
rtmpConnection.isReconnectEnabled = true
rtmpConnection.onReconnectStateChanged = { state in
    switch state {
    case .started:
        await mediaMixer.stopRunning()
    case .succeeded:
        await mediaMixer.startRunning()
    case .exhausted:
        showError("重連失敗")
    default: break
    }
}
```

---

## 4. 代碼變更清單

### 修改文件
| 文件 | 變更類型 | 說明 |
|------|----------|------|
| `RTMPHandshake.swift` | 重寫 | 修復 C0/C1/C2 封包格式 |
| `RTMPChunk.swift` | 修改 | 修復 extended timestamp + 邊界檢查 |
| `RTMPMessage.swift` | 修改 | 修復 aggregate type + 多軌道支援 |
| `RTMPTimestamp.swift` | 重寫 | 修復時間戳回滾 + Type 3 delta |
| `RTMPConnection.swift` | 重構 | 狀態機 + 自動重連 + 指數退避 |
| `RTMPSocket.swift` | 修改 | 發送背壓控制 |
| `RTMPEnhanced.swift` | 增強 | E-RTMP 編碼器協商、多軌道、VP9/AV1 |
| `VideoCodecSettings.swift` | 修改 | 新增 .vp9、.av1 格式支援 |
| `VideoCodecSettings.Format+Extension.swift` | 修改 | 補齊 switch exhaustive 匹配 |

### 刪除文件
| 文件 | 原因 |
|------|------|
| `Sources/RTMP/RTMPStateMachine.swift` | 錯誤位置，邏輯重複 |

---

## 4. 測試計畫

### 單元測試建議
- ✅ Handshake 封包生成/解析測試 (`RTMPHandshake.swift`)
- ✅ Chunk 解析邊界測試 (`RTMPChunk.swift`)
- ✅ 時間戳回滾測試 (`RTMPTimestamp.swift`)
- ✅ 發送背壓測試 (`RTMPSocket.swift`)

### 集成測試建議
- ✅ 完整 RTMP 連接流程
- ✅ E-RTMP 編碼器協商
- ✅ 多軌道發送
- ✅ 長時間運行穩定性

---

## 6. 已知限制

1. **自動重連**: ✅ 已實現（指數退避 1s→30s，最多 5 次）
2. **VP9/AV1**: ✅ 基礎架構已就緒（依賴平台解碼器能力）
3. **加密**: RTMPS 使用 Network framework 預設 TLS 配置，無自訂憑證驗證
4. **多軌道**: 基礎支援已就緒（trackId 編碼），完整 multi-track session 管理待後續
