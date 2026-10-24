# 影音時間戳對齊策略

## 本次修正

RTMPStream 不再用最近影音輸出的 PTS 差估計影片補償，也不再把落後音訊重標到最近影片的位置。這些值不是配對樣本，可能反映排程與處理耗時，不代表來源時鐘差。

影片保留編碼器 DTS 與既有 composition time；音訊保留來源 when，既有 preferredDelta 節奏修正仍存在。因此 observeOnly 指跨軌對齊策略，不表示整條管線完全不修改時間。

## 日誌

publish timeline schema=2 新增 alignment=observeOnly、origins=perTrackFirstSample、sourceStartOffset（影片第一筆 DTS 減音訊第一筆來源時間，秒）。尚未收到任一軌時為 unknown。相容欄位 videoCompensation、audioResyncs 固定為零。

generatedAVOffset 是最近輸出的兩軌累計位置差，不能直接當作口型差；sourceStartOffset 也可能包含編碼重排及來源時鐘差，不能直接當作修正量。

## 已知限制與後續

- 影音目前仍各自以第一筆樣本歸零；本次沒有引入共同時間原點，也沒有宣稱已修正固定起始偏移。
- 共同原點需先核對來源時鐘，設計首包等待上限、單軌發布、後加入軌道與重連策略，不能依回呼先後決定偏移。
- 尚需跨階段保留原始影格時間及重複畫面標記，以定位內容變舊的階段。
- 本次不證明階梯式內容延遲的根因；需比對未轉碼接收樣本與來源燒錄時鐘。

## 驗證

新增跨軌交付順序與影片停頓測試，檢查各軌生成時間不受另一軌交付順序影響。此為時間戳單元測試，不替代 RTMPStream 整合測試或實機驗收。

Apple CI 與實機仍需驗證不同時開始、靜態畫面、音訊處理延遲、長停頓恢復及重連後的影音內容同步。

## 同幀編碼與 RTMP 入列診斷（2026.10.25）

- 影片事件快照 `VideoPipelineEventsSnapshot.firstEncoderTiming`／`lastEncoderTiming`：記錄同一次 VT 提交的輸入 PTS、回呼 PTS／DTS、提交與完成的程序單調時間。`session` 是實際編碼狀態識別，重建／作廢會清空；無效 DTS 保持 nil。成功回呼不保證後續 continuation 或 RTMP 接受。
- `RTMPStream.encodingDiagnostics()` 的 `videoTiming`／`audioTiming`：保存首筆嘗試、首筆成功入列與最新嘗試，各筆包含來源 PTS／DTS、產生的 RTMP DTS／PTS、入列結果及單調觀測時間。`sequence` 是各軌入列嘗試序號，不是跨階段影格 ID。
- `preferredDurationSeconds` 是整個音訊 buffer 交給時間戳演算法的長度，可能包含多個 packet 或使用後備值，不能當作實測 PCM 長度。
- `publish media timing` 延用每 10 次 status 的節奏輸出；編碼時間加入既有影片事件摘要，不逐幀寫日誌。所有觀測固定大小，不持有媒體緩衝區。
- 嘗試數只涵蓋成功建立訊息後呼叫 doOutput 的媒體，不包含 sequence header、格式失敗、keyframe 抑制或尚未 publishing 的輸出。成功入列不代表網路送達。
- 新增欄位為 optional，舊版 JSON 缺欄位仍可解碼。發布重置清空 RTMP 時間觀測，VT session 重建清空編碼觀測。

先比較同幀輸入／輸出 PTS 與編碼耗時，再看同筆來源／RTMP 時間與入列結果。這些觀測不能跨軌拿最新值直接判定口型差，也尚未建立擷取 → Mixer → VT → RTMP 的完整影格 ID 關聯。音訊重採樣前後逐批追蹤與實測封包長度仍待補強。本次不變更時間戳演算法。
