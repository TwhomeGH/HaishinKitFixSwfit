# TODO / 計畫

本文件記錄**已規劃但尚未實作**的工作。實作完成後，請把結果移到 `CHANGES.md` 並在此移除該項。

---

## P1. RTMP 客戶端 keepalive ping 狀態機（閒置連線的死線偵測）

**狀態**：規劃中
**相關**：CHANGES #55c、`Docs/CHANGELOG_RTMP_SOCKET.md` #18 / #20
**預計檔案**：`RTMPHaishinKit/Sources/RTMP/RTMPConnection.swift`、
`RTMPHaishinKit/Sources/RTMP/RTMPKeepAlive.swift`（新）、
`RTMPHaishinKit/Tests/RTMP/RTMPKeepAliveTests.swift`（新）

### 背景

CHANGES #55c 讓 liveness watchdog 只在「送佇列非空」時才把該區間計為 silent，因此不再
誤殺健康的閒置來源（純 video VFR 靜止 + 無持續音軌）。代價是：**來源閒置期間若連線
半開（half-open TCP / radio drop），watchdog 不會發現**，必須等來源恢復產出後才會在
~8s 內偵測到。

目前 RTMP 客戶端沒有任何 keepalive：只被動回應伺服器的 `PingRequest`
（`RTMPConnection.swift` 的 `RTMPUserControlMessage` → `pong`），從不主動探測。

### 目標

以**主動 ping/pong** 區分「來源閒置」與「連線死掉」，讓閒置期間也能偵測死線，且對
**不回應 client ping 的伺服器絕不誤殺**。

### 設計

#### 通訊協定

RTMP User Control（`RTMPMessage.swift` 的 `RTMPUserControlMessage`，event `0x06` =
PingRequest / `0x07` = PingResponse）。客戶端送 `PingRequest(value:)`；合規伺服器回
`PingResponse(value:)`（echo 同一個 value）。

#### 狀態機（抽成純型別以便單元測試）

新增 `RTMPKeepAlive`（lock 保護的 struct 或 actor），輸入事件：

- `onTick(now:)` — 每 1s（沿用 NetworkMonitor 節拍）
- `onInboundBytes()` — 任何 inbound 位元組
- `onApplicationBytes()` — **非探測**的 outbound 位元組（應用資料）
- `onPong(value:)` — 收到 PingResponse

輸出決策 `enum Decision { case none, probe(UInt32), declareDead }`：

1. **Active 判定**：若 `onApplicationBytes` 或 `onInboundBytes` 有更新 → `alive`，
   重置所有計時。
2. **Idle 探測**：連續 `keepAliveIdleProbeInterval`（預設 3s）無應用位元組 → 送
   `probe(seq)`，記錄 `lastProbeValue = seq`、`probeSentAt = now`；`seq` 遞增
   （UInt32 wrapping）。
3. **Pong 判定**：收到任何 `onPong` 或 `onInboundBytes` → `alive`。
4. **Dead 判定**：送出 probe 後 `keepAlivePongTimeout`（預設 5s）內**完全無 inbound**
   → `declareDead`。
5. **Fallback（關鍵）**：若連續 `maxUnansweredProbes`（預設 3）次 probe 都收不到
   pong，判定「本伺服器不回應 client ping」→ **永久停用** ping-based dead 判定，
   退回 #55c 的 queue-based 規則，只 log 一次 warning，之後不再宣告 dead。

#### 與 watchdog 的整合

- 目前 `checkLiveness` 以 `totalBytesIn` / `totalBytesOut` 的移動判定。**主動 ping 會
  讓 `totalBytesOut` 前進**（且半開連線下 `send` 的本地 completion 仍可能完成），
  因此探測期間必須改以 **inbound** 為存活依據，否則會自我欺騙。
- 具體：watchdog 的 `moved` 在「有未回應 probe 進行中」時只採計 `totalBytesIn`。
- `declareDead` → 沿用既有 `socket.close()` → recv loop 退出 → `startReconnection()`。

#### 重置點

- `performConnect` 成功、`close()`、socket `reset()` 時，keepalive 狀態歸零
  （`seq`、`probeSentAt`、`unanswered`、`alive`、`pingUnsupported`）。
- 收到伺服器主動 `PingRequest` 時照常回 `pong`，並視為 `onInboundBytes`。

### 可調參數（公開）

| 參數 | 預設 | 說明 |
|---|---|---|
| `isKeepAliveEnabled` | `true` | 總開關（可關閉回到 #55c 行為） |
| `keepAliveIdleProbeInterval` | 3s | 閒置多久開始探測 |
| `keepAlivePongTimeout` | 5s | probe 後多久無 inbound 判死 |
| `maxUnansweredProbes` | 3 | 幾次無 pong 後停用 ping 判定 |

### 風險 / 注意

- **不回應 ping 的伺服器**：靠 `maxUnansweredProbes` fallback，絕不因探測失敗而斷線。
- **Pong value 不符**：只要有任何 inbound 即視為存活；value 只用於配對診斷 log。
- **與伺服器 ping 混淆**：只配對自己送出的 `seq`，不影響既有 pong 回應邏輯。
- **額外流量**：每次 probe 約 16 bytes，閒置時每 3s 一次，可忽略。
- **範圍**：本計畫只涵蓋 RTMP；SRT 有原生 keepalive，MoQT 另議。

### 測試計畫

- 純狀態機單元測試（`RTMPKeepAliveTests`，不需 socket）：
  1. active 期間不送 probe
  2. idle 達門檻送 probe
  3. probe 後收 pong → alive，不再判死
  4. probe 後 timeout 無 inbound → `declareDead`
  5. 連續 `maxUnansweredProbes` 無 pong → 永久停用 dead 判定（fallback）
  6. reset 後狀態歸零
- 整合（Apple 端手動 / CI）：
  - 以不存在的 host 建半開連線，驗證閒置時 ~8s 內觸發重連。
  - 以正常伺服器驗證閒置 60s 不誤斷。

### 驗收

- 純 video VFR 靜止、無音軌：連線正常者**不**被斷；拔網線後 ~8s 內重連。
- 正常推流（有音軌）行為與 CHANGES #55 前一致（無額外斷線）。
