# RTMP Socket 修正記錄

## 最新

### 27. AAC/Opus compressed audio timestamp 改用 packet media duration（2026-08）

- **檔案：** `RTMPHaishinKit/Sources/RTMP/RTMPStream.swift`、`RTMPHaishinKit/Sources/RTMP/RTMPTimestamp.swift`、`RTMPHaishinKit/Tests/RTMP/RTMPTimestampTests.swift`
- **診斷：** SRS 推流診斷頁確認 AAC payload 本身合規（sequence header `AF 00 12 10`、raw frame `AF 01`），但 FLV audio tag timestamp 間距出現 `20ms` 與 `36/37ms` 交錯。44.1k AAC 每個 1024-sample packet 的 media duration 應約 `23.22ms`，因此問題不是 AAC frame bytes，而是 wire timestamp cadence 被上游 callback / resample 排程抖動污染。
- **修正：**
  - `RTMPTimestamp.update` 新增 `preferredDelta`，可讓呼叫端指定「媒體包本身代表的時間長度」。
  - `RTMPStream` compressed audio append 改用 `AVAudioCompressedBuffer.packetDuration` 作為 audio RTMP delta：優先讀 packet description 的 `mVariableFramesInPacket`，無資料時 fallback 到 ASBD `mFramesPerPacket`；AAC 類格式若 ASBD 仍為 0，固定 fallback 到 `1024 / sampleRate`。
  - `preferredDelta` 路徑的 `updatedAt` / `cumulativeTime` 改為累加實際送出的整數 RTMP ms，避免內部時間軸與 wire timestamp 分裂。
  - 保留既有 audio A/V resync 守衛：小抖動一律忽略，但若 source time 真的落後超過約 500ms，仍允許一次大跳追到 video 附近。
  - 新增測試覆蓋 source time `20/37/20ms` 抖動時，44.1k AAC packet 仍輸出約 `23/23/23/23/24ms` 的 RTMP delta。
- **效果：** 不改 AAC payload、不改 sequence header，只讓 FLV/RTMP audio timestamp 依壓縮音訊的實際 media duration 單調平滑前進。診斷頁的 audio 間距應由 `20/36/37ms` 改為接近 `23/23/23/23/24ms`，降低播放器把合法 AAC 誤排程成斷續音訊的機率。

### 26. Audio A/V resync 守衛 + wire 層偏移監測（2026-08）

- **檔案：** `RTMPHaishinKit/Sources/RTMP/RTMPStream.swift`、`RTMPHaishinKit/Sources/RTMP/RTMPTimestamp.swift`
- **背景：** 長推流出現「音訊 bytes 正常送出（44/s）但 player 靜音」，疑似 audio wire 時間軸落後 video 過多 → player 棄音。
- **修正：**
  - `RTMPTimestamp.update(_:source:allowJump:)` 新增 `allowJump`（僅音訊 resync 用）：允許一次向前大跳讓落後音訊時間軸直接跳進同步範圍；倒退 clamp 保持不變、video 路徑不傳 `allowJump`（行為不變）。
  - `RTMPStream` compressed audio append 加入 resync 守衛：audio 落後 video playhead > 0.5s 時，把音訊時間戳 clamp 到 video 附近並 `allowJump` — 落後區間內容被跳過（丟棄舊資料），時間軸重新對齊。健康時（偏移 < 0.5s）完全不觸發，零副作用。觸發會 `warn` log（每 60 次）。
  - `publish throughput` log 新增 `avOffset`（video - audio wire 位置，正=音訊落後）：固定常數=健康，持續增大=兩時鐘漂移。
- **注意：** 此為**安全網**，非主嫌疑。音訊編碼管線本身（44 packets/s、每包 ~2ms）不可能自行落後；若 `avOffset` 恆定小值，問題應在格式（HE-AAC，檢查 `audio: AAC sequence header type=`）或**送達延遲**（app 端 DSP / socket 壅塞使音訊帶舊時間戳晚到 → player 視為 stale 丟棄）。

### 25. RTMPConnection.close() 等待 output consumer flush 後才關 socket（2026-08）

- **檔案：** `RTMPHaishinKit/Sources/RTMP/RTMPConnection.swift`
- **問題（stop 訊號切斷 / 掉幀）：** `close()` 的順序是 `outputContinuation?.finish()` → `socket?.drain()` → `socket?.close()`。`FCUnpublish`/`deleteStream`（`deleteStream()` 用 `async let` 送出）與尾幀只被 yield 進 `outputContinuation`（AsyncStream），實際 `socket.send` 在非結構化 consumer Task（`startOutputConsumer`）非同步執行。若 `drain()` 檢查時 consumer 尚未把資料 push 進 sendQueue → sendQueue 空 → drain 立即返回 → `socket.close()` 清掉緩衝 → consumer 醒來 `socket.send` 回報 "not connected" → **最終 RTMP 指令與尾幀被丟棄**。
- **修正：** 把 consumer Task 存為 `outputConsumerTask`，`close()` 在 `finish()` 後 **`await outputConsumerTask?.value`**（consumer 消化完所有緩衝並送進 socket send queue），再 `drain()`（等 sendQueue 上 wire）+ `socket?.close()`。
- **為什麼不用 `Task.detached`：** 問題是 `close()` 沒 `await` consumer，不是耦合度；detached 反而無法被追蹤/等待。
- **stream 層不需另修：** stream 的 outputContinuation 是 FIFO，`close()`/`deleteStream()` await 伺服器 response 表示先前幀已送達 wire，stream 層緩衝自然清空；缺口只在 connection 層。

### 24. AudioCodec 遷移到專用 serial queue（消除 A/V 不同步）（2026-08）

- **檔案：** `HaishinKit/Sources/Codec/AudioCodec.swift`
- **問題：** AAC 編碼（`AudioCodec.append`，含無界 drain 迴圈）同步跑在 `RTMPStream` actor 內，與 video append / socket send / backpressure update 爭搶 actor。video 早已解耦（`videoInputStream` → 獨立 task → 硬體 VT），audio 沒有 → actor 忙碌時音訊延遲送達 → 落後 video（A/V 不同步）。
- **修正：**
  - `AudioCodec` 內部掛 serial DispatchQueue（`.userInitiated`），所有處理（AAC 轉碼、converter 建立、settings 套用、start/stop 重置）統一 dispatch 到 queue；呼叫端 `append` 立即返回。
  - `settings` 以 NSLock 保護（外部 actor 讀寫 + queue 內部處理），setter 同步更新值並 `queue.async` 套用到 converter — 保證下一次 append 前已生效。
  - `outputFormat` 改 `queue.sync`（官方允許的「讀取計算結果」用法，只在 off-queue 呼叫；內部一律直接讀 `audioConverter`，避免 queue 內 `sync` 死鎖）。
  - **全程非阻塞，不用 `queue.sync` 做排水**：`append` 在 enqueue 當下 capture continuation；`stopRunning` 把舊 continuation 以 `queue.async` 排到 queue 尾巴 finish — 排在所有 pending block 之後（它們看到 `isRunning=false` 會跳過），等同排水效果但無 sync 死鎖/thread 阻塞風險（Apple 官方文件明示 sync 是 blocking、main queue sync 會 deadlock）。
  - `startRunning` 的 stream 建立保持同步（consumer 需要立刻讀 `outputStream`），狀態重置走 queue。
  - 單執行緒保證由 queue 提供：converter / ringBuffer / buffers / audioTime 只在 queue 上被碰觸；`settings` / `isRunning` 以 NSLock 保護。
- **注意：** 不改 timestamp 語意、不改 HE-AAC format。若剩餘 A/V 落差仍存在，再量 `ΔaudioPTS/Δwall` vs `ΔvideoPTS/Δwall` 確認是否為 timestamp 漂移（見 #23 思路），目前證據（`audioFrames=43~45/s`）指向送達延遲而非漂移。

### 23. Keyframe 幀數約束改以 sample buffer 實測幀率為基準（2026-08）

- **檔案：** `HaishinKit/Sources/Codec/VideoCodec.swift`、`HaishinKit/Sources/Codec/VideoCodecSettings.swift`、`HaishinKit/Sources/Codec/VTSessionMode.swift`、`HaishinKit/Tests/Codec/VideoCodecSettingsTests.swift`
- **問題：** `maxKeyFrameInterval`（幀數）在 `expectedFrameRate` 未設定時用 `30.0` 兜底 → 60 幀。VFR 螢幕擷取實際 41~49fps 下 60 幀 ≈ 1.2~1.5s，比 `MaxKeyFrameIntervalDuration = 2s` 先觸發 → 伺服器量到 ~1s keyframe interval。
- **修正：**
  - `VideoCodec` 以 raw frame PTS delta 做 EMA 測量真實幀率（`measuredFrameRate`），session 建立後一併 refresh 到 VT
  - 幀數基準優先序：`frameInterval` > `expectedFrameRate` > `measuredFrameRate` > **不設幀數約束**（不再猜 30fps；VFR 下只靠 duration 才是正確機制）
  - 來源幀率未知時，以測量值作為 VT `expectedFrameRate` hint（官方要求 bitrate 與 frame rate 一致，避免 VT 用 30fps 假設算每幀 bit budget）

### 22. 自訂 StreamBitRateStrategy 必須 forward 內建適應（2026-08）

- **檔案：** `HaishinKit/Sources/Stream/StreamBitRateStrategy.swift`、`Docs/RTMP_SOCKET_DESIGN.md`
- **背景：** 用戶自訂 `StreamBitRateStrategy`（例如只想要統計 log）時，用 protocol 實作直接取代了內建 `StreamVideoAdaptiveBitRateStrategy`。內建策略**預設並未啟動**（`RTMPStream.bitRateStrategy` 預設 `nil`，需自行實例化），一旦被自訂策略取代，`.publishInsufficientBWOccured`（壅塞降速）、`.status`（回復 ratchet 爬升）、`.reset`（恢復 `lastStableBitRate`）三個行為全部消失 → bitrate 永遠釘在設定值，壅塞時只剩 SocketBackpressure 丟 pre-encode raw frame（最高 90%）→ 畫面凍結、音訊正常、`isStalling` 抑制 stall detector → 永不恢復。
- **規範：** 自訂策略若**不打算自己處理壅塞適應**，必須用**組合（composition）**持有內建策略並 forward：
  ```swift
  final actor MyStrategy: StreamBitRateStrategy {
      private let inner = StreamVideoAdaptiveBitRateStrategy(mamimumVideobitrate: max)
      func adjustBitrate(_ event: NetworkMonitorEvent, stream: some StreamConvertible) async {
          await inner.adjustBitrate(event, stream: stream)  // 保留內建適應
          // 之後才做自己的統計/日誌（只讀 report，不碰 setVideoSettings）
      }
  }
  ```
- **禁止：** 直接 `setVideoSettings` 只做統計（會喪失壅塞降速）；`StreamVideoAdaptiveBitRateStrategy` 是 `final actor` 無法繼承，只能組合。

### 21. Stall Detection 改為 PTS 基準 + 恢復 ratchet 封頂（2026-08）

- **檔案：** `RTMPHaishinKit/Sources/RTMP/RTMPStream.swift`、`HaishinKit/Sources/Stream/StreamBitRateStrategy.swift`
- **問題：** 舊 stall detection 用 frame count 當健康信號。ReplyKIT 是螢幕擷取（VFR），畫面靜態時幀數合法降到接近 0 → 舊邏輯把「靜態」誤判為「video source stalled」，畫面一恢復就 `restartVideoPipeline()` 重建 encoder → sequence header 重送、時間戳重置，造成 fps 掉幀假象與 spike。
- **修正（PTS 基準）：**
  - 追蹤 `lastVideoInputPTSSeconds`（原始幀 PTS），以 `inputPTSAdvanced` / `outputPTSAdvanced` 判斷健康
  - 唯一真正的 encoder stall = `inputPTSAdvanced && !outputPTSAdvanced`（幀有進來但無編碼產出）才 restart
  - 「video source idle」（`!inputPTSAdvanced && audio 有流`）→ 只 log、不 restart（靜態畫面正常）
  - 移除「both audio/video silent」與「suspended gap」對 VFR 來源的誤觸 restart
- **修正（ratchet 封頂）：** `.status` 恢復爬升改為 `min(max, lastStableBitRate + max/5)`，且爬升路徑不再更新 `lastStableBitRate` — 避免振盪回 max 造成的 VBR 1.5× keyframe burst（15k+ spike）。

### 20. 位元率爆衝 + Receive 安全重構（2026-08）

- **檔案：** `HaishinKit/Sources/Network/NetworkMonitor.swift`、`HaishinKit/Sources/Stream/StreamBitRateStrategy.swift`、`RTMPHaishinKit/Sources/RTMP/RTMPConnection.swift`、`RTMPHaishinKit/Sources/RTMP/RTMPSocket.swift`、`MoQTHaishinKit/Sources/MoQTSocket.swift`
- **背景：** 1080p30 量測出現 max 15,965 Kbps（avg 6,556）、max 42.69 fps。根因是「socket 卡住 → 爆量補送」+「bitrate strategy 把 burst 吞吐讀回當目標」的複合。
- **位元率控制：**
  - `NetworkMonitor.currentBytesOutPerSecond` 改 EMA 平滑（α=0.3），單一 1s burst 窗口不再被當成可持續頻寬
  - `StreamBitRateStrategy` insufficientBW 路徑 `min(current, derived)` **只降不升**，堵住自我放大迴路
  - `.reset` 恢復 `lastStableBitRate` 而非直接彈到 max；移除對 `frameInterval` 的寫入
- **Receive 重構：**
  - `RTMPSocket`/`MoQTSocket` 的 `withCheckedThrowingContinuation` + Task loop 改為 **callback 遞迴 + actor hop**（`armNextReceive → didReceive → armNextReceive`）
  - 消除 continuation 洩漏（`connection` nil 時 `connection?.receive` 靜默跳過 → 永不 resume）
  - actor hop 中斷同步遞迴，stack 有界（不會重蹈 `nw-recursion.md` 的 stack overflow）
  - `MoQTSocket` 同時修掉 `incomingContinuation` didSet 呼叫已刪除 `receive(on:continuation:)` 的 compile error
- **Liveness watchdog：** `RTMPConnection` 連續 8s 無 bytes 進出且 stream 在 `.publishing` → force close socket → 觸發重連。修復半開 TCP / radio 失效永不重連的問題。

### 19. 移除 Socket 層自動重連 — 全權交由 RTMPConnection 處理

- **檔案：** `RTMPHaishinKit/Sources/RTMP/RTMPSocket.swift`
- **問題：** `RTMPSocket.scheduleReconnect()` 只重建 TCP，不重新 RTMP 握手（C0/C1→S0/S1→C2/S2），且 `recv()` AsyncStream 是 single-use，新連線無人讀取，形成孤兒連線。同時與 `RTMPConnection.startReconnection()` 競爭，當 `isReconnectEnabled = true` 時兩個機制同時跑。
- **修改：**
  - 移除 `scheduleReconnect()` 方法
  - 移除 `stateDidChange()` 中對 `scheduleReconnect()` 的呼叫
  - Socket 層 `.failed`/`.cancelled` 後只 clean up，由 `RTMPConnection` 的 `for await` loop exit 偵測中斷，透過 `startReconnection()` 重新建立新 socket + 完整握手 + stream 重建
- **效應：**
  - 不再有孤兒 TCP 連線
  - 重連必定走完整 RTMP 握手（C0C1→S0S1→C2→S2）
  - 無競態：socket 層不再插手重連邏輯

### 18. 修正 `recv()` 半開連線偵測缺口（2026-08）

- **檔案：** `RTMPHaishinKit/Sources/RTMP/RTMPConnection.swift`
- **問題：** 半開 TCP / radio 失效時，NWConnection 不 error，`recv()` 的 AsyncStream 永不結束 → `RTMPConnection` 靠 recv loop exit 偵測斷線的機制失效，永不重連，「socket 卡住」永久化。
- **修改：** `RTMPConnection` 新增 liveness watchdog（`checkLiveness`）：
  - 每次 `.status`（1s）比較 `totalBytesIn`/`totalBytesOut`
  - 曾有流量後連續 8s 兩者都凍結 → force `socket.close()` → recv loop 退出 → 走既有 `startReconnection()`
  - 只對 `.publishing` stream 生效（audio 永不 shed，正常推流 bytes-out 必持續前進；idle 連線不會誤殺）
- **效應：** 半開連線能在 ~8s 內被偵測並觸發重連，不再永久卡死。

### 17. 停止直播時 drain 避免 buffer 丟棄 + Frame Rate 自動上限

- **檔案：** `RTMPHaishinKit/Sources/RTMP/RTMPSocket.swift`, `RTMPConnection.swift`, `HaishinKit/Sources/Codec/VideoCodec.swift`
- **問題 A（stop drain）：** `RTMPConnection.close()` → `outputContinuation.finish()` → `socket.close()` 直接 `sendBuffer.removeAll()` + `forceCancel()`，未送出的 RTMP 指令（closeStream、FCUnpublish）可能永遠到不了伺服器。
- **修正 A：**
  - `RTMPSocket` 新增 `drain()` async 方法，用 continuation 等待 `sendBuffer` 清空且無 pending send 後才返回
  - `didSendChunk()` 在 buffer 完全送出後 resume drain continuation
  - `close()` 時也 resume drain continuation（避免 dangling）
  - `RTMPConnection.close()` 改為 `socket?.drain()` → `socket?.close()` 順序
- **問題 B（80fps）：** 預設 `frameInterval = 0` 且 `adaptiveFrameThrottle = false`，相機/DisplayLink 送 80fps 時 encoder 全收，軟體無 frame 過濾。
- **修正 B：**
  - `VideoCodec.useFrame()` 當 `frameInterval == 0` 但 `expectedFrameRate` 有設值時，自動用 `1.0 / expectedFrameRate` 作為隱式 frame cap
  - 不修改 `frameInterval` 本身，不影響 VT session 設定或現有 throttle 邏輯
- **效應：**
  - 停止直播時所有 RTMP 指令（closeStream、FCUnpublish、deleteStream）能確實送達伺服器
  - 設了 `expectedFrameRate = 60` 時，即使相機送 80fps 也會被軟體限在 60fps
  - 未設 `expectedFrameRate` 的行為完全不變（passthrough）

### 16. Send Pipeline 重設計：Chunked Send + 消除手動帳務

- **檔案：** `RTMPHaishinKit/Sources/RTMP/RTMPSocket.swift`
- **問題：** `queueBytesOut` 手動追蹤 buffer bytes，與 `sendBuffer` 雙重記帳，可能漂移或不同步。每次 `send()` 一次送出整個 buffer 可能讓 NWConnection 積壓數 MB。
- **修改：**
  - **消除 `queueBytesOut`** — 移除手動帳務，backpressure 直接讀 `sendBuffer.count` 作為單一事實源
  - **Chunked send** — 新增 64KB `sendChunkSize`，`sendNextChunk()` 每次只送一個 chunk 給 NWConnection，`didSendChunk()` callback 驅動下一段
  - `send()` 邏輯簡化：backpressure 用 `sendBuffer.count + data.count` 判斷 → drop 最舊資料 → append → 喚起 `sendNextChunk()`（如果 idle）
  - `connect()` 不再需要重置 `queueBytesOut`
  - `makeNetworkTransportReport()` 用 `sendBuffer.count` 回傳 `queueBytesOut` 值（維持 protocol 介面）
  - **Offset 游標取代 `removeFirst`** — `sendOffset` 追蹤已送位置，buffer 只在 offset 超過一半時才 compact，攤銷 O(1)，消除每個 chunk 的 memmove
- **效應：**
  - 永遠不會有帳務漂移問題
  - NWConnection 每次最多 pending 64KB，降低 kernel buffer 壓力
  - 自然 pacing：一個 chunk 送完 callback 才送下一段
  - 無 per-chunk buffer 位移開銷

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

### 13. Socket 發送合併與佇列統計修正

- **檔案：** `RTMPHaishinKit/Sources/RTMP/RTMPSocket.swift`
- **修改：**
  - `send(_ chunks:)` 與 `send(_ iterator:)` 改為先合併 payload，再 enqueue 一次
  - 新增共用 `enqueue(_:)`，統一處理 connected、backpressure、yield result
  - backpressure 改為檢查 `queueBytesOut + data.count`
  - `queueBytesOut` 在 `.dropped`、`.terminated` 與 send 完成後都會修正
  - `totalBytesOut` 只在 `NWConnection.send` 完成後累加
  - `recv()` 改為 `minimumIncompleteLength: 1`
- **效果：** 大幅降低大型 RTMP message/keyframe 造成的 `NWConnection.send` 次數，並避免 throughput 與 queue 指標失真

### 14. onMetaData 音訊中繼資料遺失

- **檔案：** `RTMPHaishinKit/Sources/RTMP/RTMPStream.swift`
- **行號：** `:842-849`
- **修改：** `makeMetadata()` 將 `audiocodecid` 和 `audiodatarate` 移到 `audioInputFormat` guard 之外，確保推流時永遠包含音訊位元率資訊
- **效果：** YouTube 不再顯示「音訊位元率 (0)」警告，因為 `onMetaData` 現在總是攜帶 `audiocodecid` 與 `audiodatarate`

### 15. Send Pipeline 最佳化：消除 chunk 逐筆複製與 `[Data]` 中間層

- **檔案：**
  - `RTMPHaishinKit/Sources/RTMP/RTMPChunk.swift` (`putMessage`)
  - `RTMPHaishinKit/Sources/RTMP/RTMPConnection.swift` (`doOutput`, `startOutputConsumer`)
  - `RTMPHaishinKit/Sources/RTMP/RTMPSocket.swift` (移除 `send(_ chunks:)`, `send(_ iterator:)`)
- **問題：** 每次 RTMP 訊息發送經歷：`putMessage` 逐 chunk `subdata` 複製 N 次 → `Array(iterator)` 收集為 `[Data]` → socket 再逐筆 merge 回單一 `Data`，產生大量重複配置。
- **修改：**
  - `putMessage` 改回傳單一 `Data`，所有 chunk 連續寫入同一個 buffer，只複製一次
  - `RTMPConnection` 的 output AsyncStream 型別從 `[Data]` 改為 `Data`
  - 移除 `RTMPSocket` 不再使用的 `send(_ chunks:)` 與 `send(_ iterator:)`
- **效果：** 每次 send 減少 N 次 chunk Data 配置 + 1 次 `[Data]` 陣列配置 + 1 次 socket merge 配置；大型 keyframe 效益最顯著

## 完整設計缺陷說明

詳見 [RTMP_SOCKET_DESIGN.md](RTMP_SOCKET_DESIGN.md)
