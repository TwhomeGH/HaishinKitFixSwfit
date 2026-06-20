# RTMP Socket 修正記錄

## 修正內容

### 1. 接收緩衝區過小

- **檔案：** `RTMPHaishinKit/Sources/RTMP/RTMPSocket.swift`
- **行號：** `:6`
- **修改：** `defaultWindowSizeC` 從 `Int(UInt8.max)`（255）改為 `Int(UInt16.max)`（65535）
- **效果：** 每次 read 調用最大讀取量提升 256 倍，大幅降低 CPU 開銷

### 2. Output Task 錯誤處理

- **檔案：** `RTMPHaishinKit/Sources/RTMP/RTMPSocket.swift`
- **行號：** `:150-162`
- **修改：** output Task 加入 `do-catch` 錯誤處理、`guard connected else { break }` 取代 `where connected` filter
- **效果：** send 錯誤時不再導致 Task 永久死亡 + 無界記憶體洩漏

### 3. Viability 不立即關閉

- **檔案：** `RTMPHaishinKit/Sources/RTMP/RTMPSocket.swift`
- **行號：** `:184-186`
- **修改：** 移除 `viabilityDidChange` 中的 `close()` 呼叫
- **效果：** 短暫網路抖動時讓 NWConnection 有機會自動恢復

### 4. recv() Continuation 確保 finish

- **檔案：** `RTMPHaishinKit/Sources/RTMP/RTMPSocket.swift`
- **行號：** `:114-128`
- **修改：** 加入 `defer { continuation.finish() }`
- **效果：** 防止正常退出 while 迴圈時 caller 永久 hang

### 5. recv() 錯誤時跳出無限迴圈

- **檔案：** `RTMPHaishinKit/Sources/RTMP/RTMPSocket.swift`
- **行號：** `:124-127`
- **修改：** catch 區塊加入 `connected = false`
- **效果：** 伺服器優雅斷線時不再無限拋 `endOfStream`，CPU 不再吃滿

### 6. close() 時清理所有 Pending Operations

- **檔案：** `RTMPHaishinKit/Sources/RTMP/RTMPConnection.swift`
- **行號：** `:433-437`
- **修改：** 遍歷 `operations` 字典 resume 所有等待中的 continuation，不再只清理 connect transaction
- **效果：** 關閉連線時所有呼叫者都會收到錯誤，不再永久 hang

### 7. Connect 失敗時清理 Output Continuation

- **檔案：** `RTMPHaishinKit/Sources/RTMP/RTMPConnection.swift`
- **行號：** `:371-372`
- **修改：** socket connect 失敗的 catch 區塊加入 `outputContinuation?.finish()` + `nil`
- **效果：** connect 失敗時 output Task 不再變成 zombie

### 8. 三層 AsyncStream 加入 Backpressure

- **檔案：** `RTMPSocket.swift:151`、`RTMPConnection.swift:456`、`RTMPStream.swift:740`
- **修改：** 三層 output stream 全部改用 `.bufferingOldest(256/128)` 取代 `.unbounded`
- **效果：** 高碼率推流時不再無界成長導致 OOM

### 9. Weak Reference Data Loss

- **檔案：** `RTMPHaishinKit/Sources/RTMP/RTMPStream.swift`
- **行號：** `:567-574`
- **修改：** `doOutput()` 改用 `guard let connection` 強捕獲 + closure 內 `[connection]` 顯式強引用
- **效果：** connection dealloc 時不再靜默丟失資料

### 10. Shared Continuation 覆寫保護

- **檔案：** `RTMPHaishinKit/Sources/RTMP/RTMPStream.swift`
- **行號：** `:317`、`:379`、`:437`、`:540`
- **修改：** `play()`、`publish()`、`close()`、`pause()` 設定新 continuation 前先 resume 舊的
- **效果：** 前一個未完成的 operation 正確收到 cancellation 錯誤，不再遺漏

### 11. publish() 的 Untracked Tasks

- **檔案：** `RTMPHaishinKit/Sources/RTMP/RTMPStream.swift`
- **行號：** `:230`、`:406-420`、`:718-727`、`:735-736`
- **修改：** 新增 `tasks: [Task<Void, Never>]` 陣列儲存所有 fire-and-forget Task，`stopMixerInputConsumers()` 時 cancel 並清空
- **效果：** deinit 時不再有洩漏的 Task 持續佔用資源

### 12. Handshake C1 Timestamp + C2 Epoch 修正

- **檔案：** `RTMPHaishinKit/Sources/RTMP/RTMPHandshake.swift`
- **行號：** `:11`、`:48`
- **修改：** `clear()` 中設定 `timestamp = Date().timeIntervalSince1970` 讓 C1 寫入真實時間；`hasS0S1Packet` off-by-one 修正為 `<=`
- **效果：** 符合 RTMP 規範，C2 計算正確的 delta，2038 年不再 overflow

## 完整設計缺陷說明

詳見 [RTMP_SOCKET_DESIGN.md](RTMP_SOCKET_DESIGN.md)
