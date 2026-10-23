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
