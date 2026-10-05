# change_log.py — CHANGES.md 管理工具

零依賴的 Python 本機網頁 GUI + CLI，用來新增 / 編輯 / 刪除 / 檢索本 repo 的
`CHANGES.md`。資料檔就是 `CHANGES.md` 本身，最新條目在最上面。

## 需求

- Python 3.8+（`python` 或 `py`）
- 選用：`markdownlint`（存檔後自動檢查格式；未安裝則略過）

## 啟動 GUI

```bash
python Tools/change_log.py                 # 啟動並自動開瀏覽器
python Tools/change_log.py serve --port 8765 --no-browser
```

Windows 可直接雙擊 `Tools/change_log.cmd`。

## 條目格式

工具產生與解析的格式：

```markdown
## 63. 標題

**時間**：2026/10/05 12:52:11

**檔案**：

- `path/a.swift`
- `path/b.swift`

### 63a. 診斷
...

### 63b. 修正
...

### 63c. 驗證
...

---
```

- `## <編號>. <標題>`：編號由工具自動取現有最大值 +1。
- `**時間**：`：可選。新增時預設帶當前系統時間，清空則不附；舊條目若無此行
  不會被補上。
- 小節為自由增減，工具自動接 `a / b / c …`。

## GUI 功能

- 左側清單顯示 `#編號 · 時間`，可搜尋標題 / 內容。
- 檢視以 markdown 渲染，支援表格、程式碼區塊，以及 GitHub alerts：
  `> [!NOTE]` / `[!TIP]` / `[!IMPORTANT]` / `[!WARNING]` / `[!CAUTION]`。
- 新增：標題、時間、檔案（可用逗號 / 、 / 換行分隔，並提供 git 變更檔 chips）、
  自由小節。
- 編輯原始碼：直接改該條目的 markdown，`Ctrl/Cmd + S` 儲存。
- 刪除：點一次武裝、再點一次確認。
- 深 / 淺色主題；標題列顯示 `共 N 筆`（有搜尋時為 `搜尋 M / N 筆`）。
- 存檔後**非阻塞**執行 markdownlint：自動修 `MD032`、回報 `MD018`（顯示於標題列）。

## CLI

```bash
# 新增（時間預設當前；--time "" 可省略時間）
python Tools/change_log.py add "修正 RTMP 重連" \
  --file "RTMPHaishinKit/Sources/RTMP/RTMPConnection.swift" \
  --section "診斷=..." --section "修正=..." --section "驗證=..."

# 檢索
python Tools/change_log.py list --grep handshake
python Tools/change_log.py list --file Socket --number 61

# 顯示單筆完整內容（編號或關鍵字）
python Tools/change_log.py show 61
python Tools/change_log.py show packetDuration
```

`add` 選項：

- `--file` — 檔案，可用 `、` / `,` / 換行分隔多個；輸出為一行一檔（避免 MD013）
- `--time` — `YYYY/MM/DD HH:MM:SS`；預設當前時間，傳空字串則不附
- `--section` — `標題=內容`，可重複；順序對應 `a / b / c …`

`list` 選項：`--grep`、`--file`、`--number`。

## HTTP API（自動化用）

GUI 由本機 HTTP 服務提供（預設 `127.0.0.1:8710`）：

- `GET /api/entries?q=` — 條目清單（含編號 / 標題 / 時間）
- `GET /api/entry?i=` — 單筆（含 `raw`）
- `GET /api/meta` — 下一個編號、git 變更檔、當前時間
- `POST /api/add` — `{title, time, file, sections}`
- `POST /api/save` — `{i, raw}`
- `POST /api/delete` — `{i}`
- `POST /api/lint` — 執行 markdownlint，回 `{warnings: [...]}`

## 環境變數

- `CHANGELOG_FILE`：覆寫資料檔路徑（預設 `<repo>/CHANGES.md`），供測試或指向
  其他 changelog。

## 實作備註

- markdown 解析器具**圍籬與 HTML 註解感知**：不會把程式碼區塊內的 `#` 當成標題。
- 新條目插在第一個 `##` 條目標題之前，保留檔案開頭說明與 `---` 分隔。
- Windows：`.CMD` 需以完整路徑執行、子程序輸出強制 UTF-8 解碼（工具內部已處理）。
