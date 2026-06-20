# RTMP 協議修復與架構改進文檔

## 版本信息
- **日期**: 2026-06-20
- **版本**: 1.1.0
- **狀態**: ✅ 完成

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

### 1.5 時間戳回滾與 Type 3 Chunk 增量計算 (P1)
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

## 3. 代碼變更清單

### 修改文件
| 文件 | 變更類型 | 說明 |
|------|----------|------|
| `RTMPHandshake.swift` | 重寫 | 修復 C0/C1/C2 封包格式 |
| `RTMPChunk.swift` | 修改 | 修復 extended timestamp + 邊界檢查 |
| `RTMPMessage.swift` | 修改 | 修復 aggregate type + 多軌道支援 |
| `RTMPTimestamp.swift` | 重寫 | 修復時間戳回滾 + Type 3 delta |
| `RTMPConnection.swift` | 重構 | 文件清理、移除重複屬性 |
| `RTMPSocket.swift` | 修改 | 發送背壓控制 |
| `RTMPEnhanced.swift` | 增強 | E-RTMP 編碼器協商、多軌道 |

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

## 5. 已知限制

1. **狀態機**: 協議狀態機檔案因位置錯置已移除，後續可考慮在 `RTMPConnection` 內部實現輕量級狀態機
2. **自動重連**: 尚未實現自動重連與指數退避
3. **VP9/AV1**: 基礎架構已就緒但解碼器支援依賴平台能力
4. **加密**: RTMPS 使用 Network framework 預設 TLS 配置，無自訂憑證驗證
