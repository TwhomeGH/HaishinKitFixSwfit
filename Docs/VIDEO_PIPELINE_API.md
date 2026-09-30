# 影像管線診斷 API 使用說明

## 入口與用途

`RTMPStream.videoPipelineSnapshot() -> VideoPipelineSnapshot` 是 RTMP 推流的統一唯讀入口，包含原始影像佇列、編碼事件、RTMP 出站事件及背壓計數。此方法為 `public nonisolated`，不需要 `await`，不等待 RTMP／Mixer actor；內部仍會短暫取得統計鎖，並非完全無鎖。

僅使用 Mixer 時，可呼叫 `MediaMixer.videoPipelineSnapshot() -> VideoMixerSnapshot`。舊的文字方法 `videoPipelineDiagnostics()` 仍保留，但新介面應使用結構化資料。

```swift
import Foundation
import HaishinKit
import RTMPHaishinKit

// stream 為既有的 RTMPStream。
var previous: VideoPipelineSnapshot? = nil // 跨取樣保存於宿主的採集器
let snapshot = stream.videoPipelineSnapshot()
let data = try JSONEncoder().encode(snapshot)
let restored = try JSONDecoder().decode(VideoPipelineSnapshot.self, from: data)

// 各讀取端自行保存前次快照；讀取不會重設底層統計。
let rates = snapshot.encoderInput.queue?.rates(since: previous?.encoderInput.queue)
let inputFPS: Double? = rates?.inputFPS
let outputFPS: Double? = rates?.outputFPS
let callbackIdle = snapshot.encoder?.idle(for: .encoderCallback)
previous = snapshot
```

範例中的 `previous` 型別為 `VideoPipelineSnapshot?`，首次設為 `nil`，每次計算後再以本次快照替換。JSON 可包進既有 Socket 訊息；主 App 必須新增解碼／顯示接線，本 API 不會自動傳送到主 App。

建議由宿主的固定計時器每 5 秒取樣，即使沒有收到影格也繼續採集；同一時間只允許一個採集工作，UI 保留固定長度歷史。RTMP 內建日誌在推流開始及之後每 5 秒採集，停止時記錄最後快照。

## 頂層回傳欄位

目前 `schemaVersion = 2`。型別均遵循 `Codable`、`Sendable`。新增的 `encoder`／`output` 是可選欄位，舊版 JSON 缺少時可解碼為 `nil`。

| 欄位 | 型別 | 意義 |
| --- | --- | --- |
| schemaVersion | Int | JSON 格式版本 |
| sampledAt | Double | 單調時鐘秒數 |
| mixer | VideoMixerSnapshot? | Mixer 輸入／輸出；尚無影格回呼或 Mixer 已釋放時可能為 nil |
| encoderInput | VideoQueueStageSnapshot | 編碼前的原始影像佇列 |
| bridgeReceived | Int | 橋接層收到的影格累計數 |
| pressureDrops | Int | 橋接層因網路背壓捨棄的影格累計數 |
| lastPTS | Double? | 最後橋接影格的有效非負 PTS；無資料時 nil |
| encoder | VideoPipelineEventsSnapshot? | 編碼器事件 |
| output | VideoPipelineEventsSnapshot? | RTMP 出站事件 |

`VideoMixerSnapshot` 的 `input`、`output` 均為 `VideoQueueStageSnapshot`。

## 佇列階段與佇列內容

| 階段欄位 | 型別 | 意義 |
| --- | --- | --- |
| availability | String enum | available、unavailable、ownerLockBusy |
| generation | UInt64? | 該階段佇列世代；鎖忙碌時可能未知 |
| missingDrops | Int? | 在尚無佇列時送入的累計影格數 |
| queue | VideoQueueSnapshot? | 未建立或鎖忙碌時為 nil |

`available` 表示能讀到快照，不代表佇列正在工作；應另查 `closed`。

| 佇列欄位 | 型別／單位 | 意義 |
| --- | --- | --- |
| id | UUID | 每個佇列實例的唯一識別 |
| sampledAt | Double／秒 | 該佇列實際取樣時間 |
| received / consumed | Int | 送入／交給消費端的累計幀數 |
| queued | Int／幀 | 目前保留的影格數 |
| bytes / byteLimit / peakBytes | Int／位元組 | 目前用量／預算／歷史峰值 |
| maxAge | Double／秒 | 最長允許停留時間 |
| manualFrameLimit | Int?／幀 | 手動額外幀數上限，nil 為自動 |
| oldestAge | Double／秒 | 最舊保留影格的年齡，空佇列為 0 |
| maxWait | Double／秒 | 已取出影格的歷史最長等待時間 |
| capacityDrops | Int | 容量或手動幀數限制淘汰數 |
| expiredDrops | Int | 逾時淘汰數 |
| oversizedDrops | Int | 單幀超過預算的拒收數 |
| closedDrops | Int | 關閉後送入的拒收數 |
| shutdownDrops | Int | finish 時釋放的待處理幀數 |
| inputIdle / outputIdle | Double?／秒 | 距離最後輸入／交付的時間；從未發生則 nil |
| closed | Bool | 佇列是否已關閉 |

`rates(since:) -> VideoQueueRates?` 回傳 `inputFPS`、`outputFPS`（Double）。不同 UUID、沒有前次快照、時間未遞增或計數倒退時回傳 nil。不要把 nil 顯示成 0 FPS。

快照不裁減逾時影格，保留停滯證據；因此 `oldestAge` 可以超過 `maxAge`。`maxWait` 是歷史峰值，不代表目前卡住。佇列 bytes 不等於擴展程序常駐記憶體，更不能直接加總成程序用量。

## 編碼與出站事件

`VideoPipelineEventsSnapshot` 包含：

- `id: UUID`：統計器識別；更換串流／編碼器物件時變更。
- `sampledAt: Double`：單調時鐘秒數。
- `events: [String: VideoPipelineEventValue]`：固定事件集合，僅包含已發生事件。每筆含 `count: UInt64` 及 `lastAt: Double`。
- `lastErrorCode: Int32?`：最後觀察到的 VT 失敗碼，保留歷史值，恢復成功不會清除。
- `idle(for:) -> Double?`：距離指定事件最後發生的秒數；從未發生回傳 nil。

### encoder 事件名稱

| 名稱 | 記錄時機 |
| --- | --- |
| encoderSubmitted | 呼叫 VTCompressionSessionEncodeFrame 前；不表示請求成功 |
| encoderCallback | 目前有效 session 收到 VT 回呼；包含失敗回呼 |
| encoderDelivered | 合法編碼影格被輸出 continuation 接受 |
| encoderKeyFrame | 關鍵幀被輸出 continuation 接受 |
| encoderDropped | 有效 session 的 VT 丟幀或回呼樣本無效／未就緒 |
| encoderFailure | 有效 session 記錄 VT 同步或非同步失敗碼 |
| encoderRecovery | append 捕捉錯誤，進入 session 重建流程；包含建立 session 失敗 |
| encoderFiltered | useFrame 節流／篩選未接受影格 |
| encoderUnavailable | 編碼器未運行，或 session／continuation 不可用 |
| encoderSessionChanged | session 屬性變更，包含重建、清除 |
| encoderKeyFrameSuppressed | 等待關鍵幀期間擋下非關鍵幀 |
| encoderYieldRejected | 輸出 continuation 未接受影格 |

事件是觀察次數，不一定等同唯一影格數：同步丟幀與回呼丟幀可能指向同一幀；失敗與重建也可以來自同一事件。不可把所有事件相加當成丟幀總數。舊 session 作廢後的回呼不加入有效回呼／交付計數。

### output 事件名稱

| 名稱 | 記錄時機 |
| --- | --- |
| publishStarted / publishStopped | 推流工作開始／停止 |
| encodedReceived | RTMP append 收到壓縮影像 |
| outputUnavailable | 非推流狀態或出站佇列已關閉 |
| keyFrameSuppressed | RTMP 層等待關鍵幀而擋下非關鍵幀 |
| messageCreationFailed | 無法建立 RTMP 影像訊息 |
| videoQueued / videoQueueRejected | 影像訊息加入串流出站佇列成功／失敗 |
| connectionVideoAccepted / connectionVideoRejected | 視訊 chunk 訊息交給連線出站佇列成功／失敗；包含 sequence header，不等同影格數 |

連線入列成功不代表 socket 寫入完成、伺服器收到或解碼成功。世代失效時的舊 consumer 會退出，不一定再留下 accepted／rejected 事件，因此兩端差值不能直接當成排隊數。

事件、橋接層計數涵蓋所屬物件生命週期，跨推流重新開始持續累計；佇列計數則以各自 UUID 為範圍。主 App 若要顯示每次推流的增量，需保存開始時快照；不可假設 publishStarted 後所有欄位歸零。

## JSON 範例

以下為格式示意，UUID 與數值均為範例；可選 nil 欄位由 JSONEncoder 省略。

```json
{
  "schemaVersion": 2,
  "sampledAt": 120,
  "encoderInput": {"availability": "unavailable", "generation": 0, "missingDrops": 0},
  "bridgeReceived": 0,
  "pressureDrops": 0,
  "encoder": {
    "id": "00000000-0000-0000-0000-000000000001",
    "sampledAt": 120,
    "events": {}
  },
  "output": {
    "id": "00000000-0000-0000-0000-000000000002",
    "sampledAt": 120,
    "events": {"publishStarted": {"count": 1, "lastAt": 119}}
  }
}
```

## 接入與判讀

1. 更新至包含本 API 的底層版本。主 App 目前尚未自動更新套件鎖定版本。
2. 必要日誌轉送要保留 `event.always`：

   ```swift
   await connection.setOnLog { event in
       guard event.always || detailedLoggingEnabled else { return }
       // 將 event.message 與 event.detail 交給既有日誌處理器。
   }
   ```

3. 分析頁顯示各階段速率、等待時間及「距上次回呼／交付」；資料缺失標成未知。不要只用前段 FPS 顯示整體 healthy。
4. 原始輸入持續但 encoderCallback 不前進：查 VT 提交／回呼；callback 前進但 delivered 不動：查失敗與關鍵幀／yield 拒收；delivered 前進但 encodedReceived 不動：查編碼輸出 consumer；videoQueued 前進但 connectionVideoAccepted 不動：查出站 consumer／連線。
5. 沒有輸入時，不應僅因 outputIdle 增加就報消費端故障。停止推流、背景暫停與資料未更新應分開呈現。

時間是單調時鐘，不是日期。UI 必須使用自己的接收時間判斷資料是否過期，不要跨程序直接相減。各階段是依序取樣，並非同一瞬間的原子快照。

內建日誌需要 RTMP／connection actor 可執行才會送出；actor 卡住時可能停止日誌。宿主定時呼叫 nonisolated 入口仍可觀察資料，但仍須依自己的傳送途徑交付。此版本不提供網路送達或伺服器解碼確認，也不自動根據診斷重啟編碼器。
