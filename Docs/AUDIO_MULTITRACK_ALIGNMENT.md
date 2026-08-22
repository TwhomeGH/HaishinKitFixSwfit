# 多軌音訊跨軌對齊（ReplayKit .appAudio / .audioMic）

## 問題描述

使用 ReplayKit 廣播（`Examples/iOS/Screencast`）同時推流 `.appAudio`（App 聲音）與 `.audioMic`（麥克風）時，下游（FLV/播放器）出現：

- **回音**：同一段聲音以明顯的時間差出現兩次（slapback）
- **撕裂 / 電磁感**：混音輸出出現斷續、梳狀濾波（comb filter）的金屬感
- 偶發的 **silence 缺口**（斷音）

## 問題區別（三層）

這個現象容易被誤診為「編碼」或「傳輸」問題。必須區分三層：

### 1. 來源端時間戳是一致的 —— 問題在混音端「先到先混」

ReplayKit 把 mic 與 app 拆成**兩軌**，但兩軌共用**同一來源時鐘**（host-time PTS），
而且基本同時輸出。所以兩軌的 `when.sampleTime` 本質上落在**同一條輸出樣本軸**上：

- `AudioMixerTrack` 的 `AudioTime` anchor 設在來源 PTS 上（`AudioTime.anchor`）
- 每軌輸出幀的 `when` 由來源 PTS 派生、frame 間距由來源 PTS gap 化為 silence 幀推進
- 因此「時間戳應該一致」這個前提**是對的**，問題在於混音器把這個一致性丟掉了

修復前，`AudioMixerByMultiTrack` 的混音是**先到先混**：

- 混音時鐘只由 main track（mic）決定，非 main track（app）不參與時間軸
- 兩軌各自先進 `AudioRingBuffer`（純 FIFO），render 時依抵達順序消耗
- `AudioRingBuffer` 的 append 把 `when.sampleTime` 算完 gap 後就丟棄，**來源端 PTS 在 render 當下完全消失**

結果：兩軌的**起始相位差**（誰先開始、積壓多少）與**動態漂移**（累積/消耗不均）以錯誤的
相對位置混入輸出。當兩軌含**相關內容**（如 mic 收到喇叭外放、或兩軌同源）時，
這個 offset 就是你聽到的回音；offset 小時是梳狀濾波/撕裂。

### 2. 處理層回音 vs 物理回音

- **處理層回音**：由混音相位差造成。**本次修復可消除**。
- **物理回音（acoustic echo）**：App 聲音從喇叭外放、被 mic 收音。這是實體路徑，
  **任何 PTS 對齊都無法消除**——需要 AEC（acoustic echo cancellation）或改用耳機。

### 3. 消耗軸 vs 來源 PTS —— 為何不能用「frame 計數」對齊

掉幀（來源端或上游）後，`when.sampleTime` 的「消耗軸」仍與真實時間同步（掉幀的 gap
會化為 silence 幀推進），所以消耗軸本身是 PTS 派生的、可跨軌比較的。但**純 frame 計數
軸**在掉幀後會與來源 PTS 分叉——對齊必須以 PTS 派生的位置為基準，不能數幀數。

### 4. 與「壅塞掉幀」的關係（另一個獨立問題）

`SampleHandler` 原本有 `isAppendingAudioMic / isAppendingAudioApp` guard：MediaMixer
actor 忙碌時**靜默丟棄音訊幀**。mic 與 app 若**非相關性掉幀**，混音會出現 silence 缺口
（撕裂）。這是「用丟幀做節流」的問題，與混音對齊是兩個獨立來源，本次一併移除。

## 根因（修復前程式碼位置）

| 位置 | 問題 |
|------|------|
| `AudioRingBuffer.swift` `append` | 來源 PTS 只拿來算單軌 gap（skip），樣本進 buffer 後只剩 FIFO |
| `AudioMixerByMultiTrack.swift` `render` | render 直接順序消耗各軌 ring buffer，無跨軌時間對齊 |
| `AudioMixerByMultiTrack.swift` `track(_:didOutput:)` | 混音時鐘只由 main track 錨定（sampleTime/anchor 只設一次） |
| `SampleHandler.swift` | `isAppendingAudioMic/App` guard 在 actor 忙碌時靜默丟音訊幀 |

## 修復

### 1. `AudioRingBuffer.align(to:)`（新增）

以 main track 的 `sampleTime` 為基準，把本緩衝區的消耗前端對齊到 `position`：

```
對齊點（frontier）= sampleTime - counts   // 下一個將輸出的樣本位置，含 pending skip
```

- **frontier < position**（過期）→ 丟棄 `min(position - frontier, counts)` 個樣本
  （先吞 pending silence 再吞資料），讓過期內容不混進錯誤位置
- **frontier > position**（超前）→ 前方補 silence（`skip += frontier - position`），
  靜音到對齊點再開始輸出

對齊後 `render()` 會先排空 skip（silence）再輸出資料，語意一致。持鎖運算，避免
`os_unfair_lock` 重入；trace 日誌只在調整量 ≥ 4096 samples（約 93ms）時記錄，避免
熱路徑 per-frame 日誌寫入。

### 2. `AudioMixerByMultiTrack.render()`（非 main track 對齊）

```swift
if track != _settings.mainTrack {
    buffer.align(to: sampleTime)
}
```

main track 是時鐘本身，**不可對齊**（對齊它會吃掉其內部來源 gap 的 silence 推進）。

### 3. `SampleHandler`（移除音訊丟幀節流）

移除 `isAppendingAudioMic / isAppendingAudioApp` guard 與旗標，只保留
`dataReadiness == .ready` 檢查。audio append 在 `AudioMixerByMultiTrack` 自己的
serial queue 上處理，actor hop 極輕量；排隊 append（保留 PTS 位置）比丟幀正確。
`isAppendingVideo` 保留（視訊大幀對記憶體敏感，且視訊掉幀不明顯）。

## 驗證

- **獨立腳本** `.cortexkit/verify-align.swift`：純整數鏡像 `align` 數學，7 個情境全過
  （app 超前補 silence、app 落後丟過期、對齊點越界清空、leading silence 調整、
  兩軌交錯共用時鐘鎖定、重設後 re-align、main 停滯時 frontier 保持鎖定）。
  Windows 無 AVFoundation 無法編譯模組，故以獨立腳本驗證。
- **單元測試** `HaishinKit/Tests/Mixer/AudioRingBufferTests.swift`：新增 4 個
  `align` 測試（可在 macOS CI 執行）。

## 設計決策：連續式混音時鐘

混音時鐘維持「消耗軸」（main track 的 `when.sampleTime`，只隨 `mix()` 推進，來源
gap 化為 silence 幀）。這讓：

- 混音時間軸**連續、單調**，兩軌永遠鎖定在同一條軸上（main track 停滯時 app 的
  frontier 也鎖定在混音時鐘，恢復後無需調整）
- main track 長時間停滯時混音時間軸會落後真實時間（恢復後延遲持續，>0.5s 由
  `RTMPStream.resyncedAudioTime` clamp 補救）

**刻意不做**「hostTime 貼齊來源 PTS」的跳躍式時間軸：那會讓 main track 停滯期間
兩軌音訊全被當成過期丟棄。連續式在「保留 app 音訊」與「對齊」之間是正確的取捨。

## 相關檔案

- `HaishinKit/Sources/Mixer/AudioRingBuffer.swift`
- `HaishinKit/Sources/Mixer/AudioMixerByMultiTrack.swift`
- `HaishinKit/Tests/Mixer/AudioRingBufferTests.swift`
- `Examples/iOS/Screencast/SampleHandler.swift`
- `.cortexkit/verify-align.swift`（驗證腳本）
