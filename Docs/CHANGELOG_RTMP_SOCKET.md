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

## 完整設計缺陷說明

詳見 [RTMP_SOCKET_DESIGN.md](RTMP_SOCKET_DESIGN.md)
