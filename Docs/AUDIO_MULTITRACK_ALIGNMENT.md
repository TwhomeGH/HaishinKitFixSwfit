# 多軌音訊品質：跨軌對齊與物理回音消除（ReplayKit .appAudio / .audioMic）

本文件涵蓋 ReplayKit 雙軌混音的兩個獨立音訊問題與其修復：
**跨軌時間對齊**（處理層相位差回音）與 **NLMS 物理回音消除**（喇叭外放被 mic 收音）。
兩者互補：對齊是 AEC 正確工作的前提（reference 與 target 必須在同一時間軸上）。

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

- **處理層回音**：由混音相位差造成。**由本文件的跨軌對齊修復消除**。
- **物理回音（acoustic echo）**：App 聲音從喇叭外放、被 mic 收音。這是實體路徑，
  **任何 PTS 對齊都無法消除**。本專案另實作了簡易 NLMS AEC（見下方「物理回音消除」）
  做**衰減**；戴耳機則完全沒有此問題。

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

## 混音時鐘：main 靜默不停止

混音時間軸由 **main track** 的輸出驅動（`sampleTime`/anchor 由它錨定，其他軌 PTS
對齊到它）。若 main track 長時間靜默（例如 `mainTrack` 設為 app 軌、而 app 完全
沒有在播放聲音），時間軸會停滯 → 整個混音無輸出（mic 也沒聲音）。

**Fallback**：當 main track 落後（最近輸出位置早於其他軌的目前位置，或從未輸出）時，
其他軌的輸出會接手推進時間軸，**不會停滯**。

**注意**：fallback 解決「不停止」，但若 main=app 且 app 先於 mic 送達，app 觸發的
block 會在 mic 內容送達前就被渲染 → mic 內容被 `align` 當過期丟棄。因此：

- **ReplayKit 情境建議 `mainTrack` 指向 mic 軌**（mic 持續產生，驅動時鐘；app 內容
  先進 ring buffer 等待，被正確拉取）。這與 AEC 無關（AEC 的 reference/target 已
  脫離 mainTrack）。
- 驗證：`.cortexkit/verify-mixer-clock.swift` 4 情境全過（正規接線雙軌保留、
  main=app 且 app 從未播放時 mic 持續輸出、app 靜默→恢復、純 mic 串流）。

## 物理回音消除（簡易 NLMS AEC）

跨軌對齊解決「處理層」回音，但**喇叭外放被 mic 收音**的物理回音仍會讓同一段
聲音出現兩次。`AudioEchoCanceler` 以 App 軌為 reference、mic（main track）為
target，在混音前對 mic 幀做 NLMS（normalized least mean squares）自適應回音消除：

- 估計 mic 收到的回音 `ŷ[n] = Σ w[k]·ref[n-k]`，相減後輸出乾淨人聲
- w 逐幀自適應，追蹤喇叭→mic 聲學路徑（含延遲）；雙講（人聲+音樂同時）時
  `micPower > 2×refPower` 凍結更新避免發散
- 1024 tap @48k ≈ 21ms，涵蓋手持裝置聲學延遲 + mic 擷取延遲

**設定**（`AudioMixerSettings`，皆可選、向後相容 Codable）：

| 欄位 | 說明 |
|------|------|
| `isEchoCancellationEnabled` | 開啟 AEC（預設 false）。**路由感知**：耳機/聽筒/藍牙耳機時自動停用（無物理回音，省 CPU 零 artifacts），喇叭/外部輸出才啟用 |
| `echoCancellationReferenceTrack` | **必填**：指向你的 app 音訊軌（預設 `UInt8.max` = 未設定 → AEC 停用） |
| target（mic） | **自動推導**：兩軌情境下取「非 reference 的軌」，**與 mainTrack 無關** |

> **Track 編號是呼叫端自訂的**：`MediaMixer.append(_:track:)` 的參數沒有內建
> 0=mic/1=app 的意義。AEC 的 reference 必須**顯式**指向 app 軌：
> - 框架範例 `SampleHandler` 接線 `.audioApp`→track 1 → reference = 1
> - 你的 app 接線 app→track 0、mic→track 1 → reference = 0
>
> AEC target 不再綁定 mainTrack（舊設計的缺陷：mainTrack 若是 app 軌，會把 app
> 誤當消除目標、用 mic 當 reference，造成有害相減）。target 恆為「非 reference
> 的軌」，mainTrack 純粹是混音時鐘/格式來源。

**整合**：`AudioMixerByMultiTrack` 的 serial queue 上，每 channel 一個 canceler；
reference（App 軌）逐幀餵入、mic（main track）幀在進混音 buffer 前先消除。
`Examples/iOS/Screencast/SampleHandler.swift` 已啟用（reference = 1、mic = main 0）。

**限制**：線性模型只做**衰減**（實測合成 echo path 收斂後約 18dB），非完全消除；
雙講與喇叭音量劇變是弱點（靠凍結防發散）；換耳機可完全避免此問題。

**驗證**：`.cortexkit/verify-aec.swift`（編譯 `AudioEchoCanceler.swift` + harness，
純 Swift 無 AVFoundation），3 情境全過：收斂後回音衰減 >12dB、雙講人聲保留、雙講後
濾波器不發散。

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
- `HaishinKit/Sources/Mixer/AudioEchoCanceler.swift`（物理回音消除 NLMS AEC）
- `HaishinKit/Sources/Mixer/AudioMixerSettings.swift`（AEC 設定欄位）
- `HaishinKit/Tests/Mixer/AudioRingBufferTests.swift`
- `Examples/iOS/Screencast/SampleHandler.swift`
- `.cortexkit/verify-align.swift`（對齊驗證腳本）
- `.cortexkit/verify-aec.swift`（AEC 驗證腳本）
