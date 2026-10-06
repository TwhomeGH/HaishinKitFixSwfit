#!/usr/bin/env python3
"""CHANGES.md 工具 — 本機網頁 GUI（主要）+ CLI（腳本化用）。

針對本 repo 的 CHANGES.md 格式：條目為 `## <編號>. <標題>`（新→舊），
內文為自由的 `### <編號><字母>. <小節標題>` 小節。

主要用法（雙擊 Tools/change_log.cmd，或直接執行）:
  python Tools/change_log.py                 # 啟動本機網頁 GUI（自動開瀏覽器）
  python Tools/change_log.py serve --port 8765 --no-browser

CLI:
  python Tools/change_log.py add "修正 xxx" [--file path] [--section 標題=內容]
  python Tools/change_log.py list [--grep 關鍵字] [--file Socket] [--number 61]
  python Tools/change_log.py show <編號|關鍵字>

資料檔: CHANGES.md（可用環境變數 CHANGELOG_FILE 覆寫，方便測試）。
零外部依賴；存檔後會（若有安裝）用 markdownlint 自動修 MD032 並回報 MD018。
"""
import os
import re
import sys
import json
import shutil
import tempfile
import argparse
import subprocess
import threading
import webbrowser
from pathlib import Path
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

if sys.platform == "win32":
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")

ROOT = Path(__file__).resolve().parents[1]
HISTORY = Path(os.environ.get("CHANGELOG_FILE") or (ROOT / "CHANGES.md"))
# 條目標題：`## 61. 修正 …`。數字後必須緊接空白，才不會把日期式標題
# （`## 2026.10.06 22:49 …`）誤判成編號 2026。
ENTRY_RE = re.compile(r"^##\s+(\d+)\.\s+(.*)$")
# 條目時間行（可選）：`**時間**：2026/10/05 12:52:11`
TIME_RE = re.compile(r"^\*\*時間\*\*[:：]\s*(\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2})\s*$", re.MULTILINE)


def now_stamp():
    return datetime.now().strftime("%Y/%m/%d %H:%M:%S")


# ─────────────────────────── 核心：解析 / 讀寫 ───────────────────────────

def read_history():
    if not HISTORY.exists():
        sys.exit("找不到 %s" % HISTORY)
    return HISTORY.read_text(encoding="utf-8")


def _heading_indices(lines):
    """真實（非註解、非程式碼圍籬內）的 '## ' 條目行索引。"""
    out, in_comment, fence = [], False, False
    for i, line in enumerate(lines):
        stripped = line.lstrip()
        if fence:
            if stripped.startswith("```"):
                fence = False
            continue
        if stripped.startswith("```"):
            fence = True
            continue
        if in_comment:
            if "-->" in line:
                in_comment = False
            continue
        if "<!--" in line:
            if "-->" not in line:
                in_comment = True
            continue
        if line.startswith("## "):
            out.append(i)
    return out


def parse_entries(text=None):
    """回傳 list[dict(number, title, raw, i)]，順序即檔案順序（新→舊）。"""
    text = read_history() if text is None else text
    lines = text.splitlines()
    heads = _heading_indices(lines)
    entries = []
    for pos, start in enumerate(heads):
        end = heads[pos + 1] if pos + 1 < len(heads) else len(lines)
        raw = "\n".join(lines[start:end]).rstrip()
        m = ENTRY_RE.match(lines[start].rstrip())
        tm = TIME_RE.search(raw)
        time_str = tm.group(1) if tm else ""
        if m:
            entries.append({"number": int(m.group(1)), "title": m.group(2).strip(),
                            "time": time_str, "raw": raw})
        else:
            entries.append({"number": None, "title": lines[start][3:].strip(),
                            "time": time_str, "raw": raw})
    for i, e in enumerate(entries):
        e["i"] = i
    return entries


def next_number(entries=None):
    entries = parse_entries() if entries is None else entries
    nums = [e["number"] for e in entries if e["number"]]
    return (max(nums) + 1) if nums else 1


def _letters(idx):
    """0→a, 1→b, …, 25→z, 26→aa…（>26 個小節的少見情形）。"""
    out = ""
    idx += 1
    while idx:
        idx, rem = divmod(idx - 1, 26)
        out = chr(ord("a") + rem) + out
    return out


def build_block(number, title, files="", sections=None, time_str=""):
    """組出這個 repo 風格的條目：`## n. 標題` + 時間 + 檔案 + 自由小節（自動接字母）。"""
    lines = ["## %d. %s" % (number, title), ""]
    if time_str:
        lines += ["**時間**：%s" % time_str, ""]
    if files:
        if isinstance(files, str):
            files = [f.strip() for f in re.split(r"[\n,、]", files) if f.strip()]
        if files:
            # 一行一檔，避免多檔串成一行造成 markdownlint MD013。
            lines.append("**檔案**：")
            lines.append("")
            lines += ["- `%s`" % f for f in files]
            lines.append("")
    used = 0
    for sec in (sections or []):
        label = (sec.get("label") or "").strip()
        body = (sec.get("body") or "").strip()
        if not label and not body:
            continue
        letter = _letters(used)
        used += 1
        heading = "### %d%s. %s" % (number, letter, label) if label else "### %d%s." % (number, letter)
        lines.append(heading)
        if body:
            lines += ["", body]
        lines.append("")
    while lines and lines[-1] == "":
        lines.pop()
    lines += ["", "---", ""]
    return "\n".join(lines)


def _write(lines):
    HISTORY.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")


def insert_block(block):
    lines = read_history().splitlines()
    heads = _heading_indices(lines)
    at = heads[0] if heads else len(lines)
    _write(lines[:at] + block.splitlines() + [""] + lines[at:])


def update_entry(i, raw):
    lines = read_history().splitlines()
    heads = _heading_indices(lines)
    if not (0 <= i < len(heads)):
        raise IndexError("編號超出範圍")
    start = heads[i]
    end = heads[i + 1] if i + 1 < len(heads) else len(lines)
    repl = raw.rstrip().splitlines()
    if i + 1 < len(heads):          # 後面還有下一筆 → 補回分隔空行
        repl.append("")
    _write(lines[:start] + repl + lines[end:])


def delete_entry(i):
    lines = read_history().splitlines()
    heads = _heading_indices(lines)
    if not (0 <= i < len(heads)):
        raise IndexError("編號超出範圍")
    start = heads[i]
    end = heads[i + 1] if i + 1 < len(heads) else len(lines)
    new = lines[:start] + lines[end:]
    out, blank = [], 0
    for l in new:
        blank = blank + 1 if l.strip() == "" else 0
        if blank <= 2:
            out.append(l)
    _write(out)


# ─────────────────────── markdownlint 整合（可選） ───────────────────────

def _run(cmd):
    try:
        # Windows 的 text=True 預設用 locale（如 cp950）解碼，會把 UTF-8 的
        # git / markdownlint 輸出打成例外；一律強制 utf-8 + replace。
        return subprocess.run(cmd, capture_output=True, text=True,
                              encoding="utf-8", errors="replace", timeout=30)
    except Exception:
        return None


def _cfg(enabled):
    fd, path = tempfile.mkstemp(prefix="mdlint_", suffix=".json")
    os.close(fd)
    p = Path(path)
    p.write_text(json.dumps({"default": False, enabled: True}), encoding="utf-8")
    return p


def lint_after_write():
    """回傳警示訊息 list。MD032 自動修（安全）；MD018 只回報（自動修會把散文變標題）。"""
    # 一定要用 which() 解析出的完整路徑：Windows 上 markdownlint 是 .CMD，
    # 直接以裸名 "markdownlint" 交給 CreateProcess 會找不到而不執行。
    exe = shutil.which("markdownlint")
    if exe is None:
        return []
    msgs = []
    try:
        cfg = _cfg("MD032")
        _run([exe, "--config", str(cfg), "--fix", str(HISTORY)])
        cfg.unlink(missing_ok=True)
        cfg = _cfg("MD018")
        r = _run([exe, "--config", str(cfg), str(HISTORY)])
        cfg.unlink(missing_ok=True)
        if r:
            for line in ((r.stdout or "") + "\n" + (r.stderr or "")).splitlines():
                if "MD018" in line:
                    msgs.append(line.strip())
    except Exception as ex:
        msgs.append("markdownlint 執行失敗: %s" % ex)
    return msgs


def git_changed_files():
    def g(args):
        try:
            return subprocess.run(["git", "-C", str(ROOT)] + args, capture_output=True,
                                  text=True, encoding="utf-8", errors="replace", timeout=5).stdout
        except Exception:
            return ""
    files = [f.strip() for f in (g(["diff", "--name-only"]) + "\n" + g(["ls-files", "--others", "--exclude-standard"])).splitlines() if f.strip()]
    return sorted(set(files))


# ─────────────────────────────── CLI ───────────────────────────────

def cmd_add(args):
    sections = []
    for spec in args.section or []:
        label, _, body = spec.partition("=")
        sections.append({"label": label.strip(), "body": body.strip()})
    n = next_number()
    time_str = args.time if args.time is not None else now_stamp()
    insert_block(build_block(n, args.title, args.file, sections, time_str=time_str))
    for msg in lint_after_write():
        print("⚠ " + msg)
    print("已插入: ## %d. %s" % (n, args.title))


def _matches(e, args):
    hay = (e["title"] + "\n" + e["raw"]).lower()
    if args.grep and args.grep.lower() not in hay:
        return False
    if args.file and args.file.lower() not in e["raw"].lower():
        return False
    if args.number and e["number"] != args.number:
        return False
    return True


def cmd_list(args):
    entries = parse_entries()
    hits = [e for e in entries if _matches(e, args)]
    print("符合 %d / 共 %d 筆\n" % (len(hits), len(entries)))
    for e in hits:
        num = ("#%d" % e["number"]) if e["number"] else "--"
        stamp = (e.get("time") + "  ") if e.get("time") else ""
        print("%5s  %s%s" % (num, stamp, e["title"]))


def cmd_show(args):
    entries = parse_entries()
    target = None
    if args.query.isdigit():
        want = int(args.query)
        target = next((e for e in entries if e["number"] == want), None)
    if target is None:
        q = args.query.lower()
        target = next((e for e in entries if q in (e["title"] + "\n" + e["raw"]).lower()), None)
    if target is None:
        sys.exit("找不到符合的紀錄: %s" % args.query)
    print(target["raw"])


# ─────────────────────────── 網頁 GUI ───────────────────────────

PAGE = r"""<!doctype html>
<html lang="zh-Hant"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>CHANGES.md</title>
<script>(function(){try{var t=localStorage.getItem('theme');if(t!=='dark'&&t!=='light')t=matchMedia('(prefers-color-scheme:dark)').matches?'dark':'light';document.documentElement.dataset.theme=t;}catch(e){}})();</script>
<style>
:root{color-scheme:light;--bg:#f4f5f7;--fg:#111827;--mut:#6b7280;--card:#fff;--field:#fff;--line:#e5e7eb;--line2:#eef0f3;--accent:#2563eb;--accent-fg:#fff;--code:#f3f4f6;--ring:rgba(37,99,235,.22);--hdr:rgba(244,245,247,.85);--shadow:0 12px 36px rgba(17,24,39,.13)}
:root[data-theme="dark"]{color-scheme:dark;--bg:#0e1013;--fg:#e6e8ec;--mut:#98a1ad;--card:#191c22;--field:#14171c;--line:#2b313a;--line2:#232830;--accent:#4f8cff;--accent-fg:#fff;--code:#20242c;--ring:rgba(79,140,255,.30);--hdr:rgba(14,16,19,.85);--shadow:0 18px 52px rgba(0,0,0,.6)}
*{box-sizing:border-box}
body{margin:0;font:15px/1.65 -apple-system,"Segoe UI","Microsoft JhengHei",sans-serif;background:var(--bg);color:var(--fg);display:flex;flex-direction:column;height:100vh;overflow:hidden;-webkit-font-smoothing:antialiased}
::-webkit-scrollbar{width:10px;height:10px}::-webkit-scrollbar-thumb{background:var(--line);border-radius:9px;border:2px solid var(--bg)}::-webkit-scrollbar-thumb:hover{background:var(--mut)}
header{display:flex;gap:8px;align-items:center;flex-wrap:wrap;row-gap:8px;padding:12px 16px;border-bottom:1px solid var(--line);position:sticky;top:0;background:var(--hdr);backdrop-filter:blur(10px);z-index:5}
header h1{font-size:16px;font-weight:700;margin:0 10px 0 0;white-space:nowrap}
header .num{font-size:11px;color:var(--mut);border:1px solid var(--line);border-radius:20px;padding:1px 8px}
input,select,textarea,button{font:inherit;color:var(--fg)}
input,select,textarea{padding:9px 11px;border:1px solid var(--line);border-radius:10px;background:var(--field);width:100%;transition:border-color .15s,box-shadow .15s}
input:hover,select:hover,textarea:hover{border-color:var(--mut)}
input:focus,select:focus,textarea:focus{outline:none;border-color:var(--accent);box-shadow:0 0 0 3px var(--ring)}
::placeholder{color:var(--mut);opacity:.8}
header input{width:auto}
input#q{flex:1;min-width:160px}
button{cursor:pointer;padding:9px 13px;border:1px solid var(--line);border-radius:10px;background:var(--card);transition:background .15s,border-color .15s,transform .05s}
button:hover{background:var(--line2)}button:active{transform:translateY(1px)}
button.primary{background:var(--accent);color:var(--accent-fg);border-color:var(--accent)}
button.primary:hover{filter:brightness(1.07);background:var(--accent)}
button.danger{background:#dc2626;color:#fff;border-color:#dc2626}
main{display:flex;flex:1;min-height:0}
aside{width:360px;min-width:220px;overflow:auto;border-right:1px solid var(--line)}
.item{padding:11px 16px;border-bottom:1px solid var(--line2);cursor:pointer;transition:background .12s}
.item:hover{background:var(--card)}.item.sel{background:var(--card);box-shadow:inset 3px 0 0 var(--accent)}
.item .d{font-size:12px;color:var(--mut);font-variant-numeric:tabular-nums}.item .t{font-weight:600;margin-top:2px}
section{flex:1;overflow:auto;padding:22px 28px}
section h1,section h2,section h3{margin:.6em 0 .4em;line-height:1.35}section h2{font-size:20px;border-bottom:1px solid var(--line);padding-bottom:.3em}
pre.code{background:var(--code);padding:12px 14px;border-radius:10px;overflow:auto;border:1px solid var(--line)}
code{background:var(--code);padding:1px 6px;border-radius:6px;font-size:.92em}
table{border-collapse:collapse;margin:.6em 0}th,td{border:1px solid var(--line);padding:7px 11px;text-align:left}
blockquote{margin:.6em 0;padding:.3em 1em;border-left:3px solid var(--line);color:var(--mut)}
.alert{border:1px solid;border-left-width:4px;border-radius:10px;padding:10px 14px;margin:.9em 0}
.alert-title{font-weight:700;font-size:13px;margin-bottom:5px;letter-spacing:.02em}
.alert :last-child{margin-bottom:0}
.alert-note{border-color:#3b82f6;background:rgba(59,130,246,.10)}.alert-note .alert-title{color:#2563eb}
.alert-tip{border-color:#10b981;background:rgba(16,185,129,.10)}.alert-tip .alert-title{color:#059669}
.alert-important{border-color:#a855f7;background:rgba(168,85,247,.10)}.alert-important .alert-title{color:#9333ea}
.alert-warning{border-color:#f59e0b;background:rgba(245,158,11,.13)}.alert-warning .alert-title{color:#d97706}
.alert-caution{border-color:#ef4444;background:rgba(239,68,68,.10)}.alert-caution .alert-title{color:#dc2626}
a{color:var(--accent);text-underline-offset:2px}hr{border:none;border-top:1px solid var(--line);margin:1em 0}
.toolbar{margin-bottom:12px;display:flex;gap:8px;flex-wrap:wrap;align-items:center}
#modal{position:fixed;inset:0;background:rgba(8,10,14,.55);backdrop-filter:blur(3px);display:flex;align-items:center;justify-content:center;z-index:10}
#modal[hidden]{display:none}
.dialog{background:var(--card);border:1px solid var(--line);border-radius:16px;box-shadow:var(--shadow);padding:20px 20px 0;width:min(760px,94vw);max-height:90vh;overflow:auto}
.dialog h2{margin:0 0 6px;font-size:18px}
.dialog label{display:block;font-size:13px;font-weight:600;color:var(--mut);margin:14px 0 5px}
.dialog textarea{min-height:70px;resize:vertical;line-height:1.55}
.sec{border:1px solid var(--line);border-radius:12px;padding:10px 12px;margin-top:10px;background:var(--bg)}
.sec .sec-head{display:flex;gap:8px;align-items:center}.sec .sec-head input{flex:1}
.sec .sec-head button{flex:none;padding:9px 12px}
.sec textarea{margin-top:8px}
#add-sec{margin-top:10px}
.foot{position:sticky;bottom:0;background:var(--card);border-top:1px solid var(--line);margin-top:18px;padding:12px 0 18px}
.right{display:flex;justify-content:flex-end;gap:8px}
.empty{color:var(--mut);padding:30px;text-align:center}
.chips{display:flex;flex-wrap:wrap;gap:6px;margin-top:8px}
.chip{font-size:12px;padding:3px 10px;border:1px solid var(--line);border-radius:20px;cursor:pointer;background:var(--bg);color:var(--mut);transition:border-color .15s,color .15s}
.chip:hover{border-color:var(--accent);color:var(--accent)}
#raw{width:100%;min-height:340px;font:13px/1.6 ui-monospace,Consolas,"Courier New",monospace;padding:14px;border:1px solid var(--line);border-radius:12px;background:var(--code);color:var(--fg);resize:vertical;white-space:pre;overflow:auto;tab-size:2}
#raw:focus{outline:none;border-color:var(--accent);box-shadow:0 0 0 3px var(--ring)}
.err{color:#ef4444;font-size:13px;min-height:1.2em;margin-top:8px}
.warn{color:#d97706;font-size:13px;min-height:1.2em;margin-top:8px}
#content{max-width:920px}
@media (max-width:640px){main{flex-direction:column}aside{width:auto;max-width:100%;max-height:42vh;border-right:none;border-bottom:1px solid var(--line)}section{padding:14px 16px}}
</style></head>
<body>
<header>
  <h1>CHANGES.md</h1>
  <span class="num" id="count"></span>
  <span id="lint" class="warn"></span>
  <input id="q" aria-label="搜尋標題或內容" placeholder="搜尋標題 / 內容…">
  <button id="reload" aria-label="重新載入" title="重新載入">↻</button>
  <button id="theme" aria-label="切換深淺色" title="切換深/淺色">🌙</button>
  <button id="add" class="primary">＋ 新增條目</button>
</header>
<main>
  <aside id="list"></aside>
  <section id="detail"><div class="empty">← 選擇一筆條目</div></section>
</main>

<div id="modal" hidden><div class="dialog">
  <h2>新增條目 <span class="num" id="next-num"></span></h2>
  <label for="f-title">標題</label><input id="f-title" placeholder="修正 RTMP 重連：…">
  <label for="f-time">時間（可留空；預設當前時間）</label><input id="f-time" placeholder="YYYY/MM/DD HH:MM:SS">
  <label for="f-file">檔案（可用逗號 / 、 / 換行分隔多個）</label>
  <input id="f-file" placeholder="RTMPHaishinKit/Sources/RTMP/RTMPConnection.swift" list="gitfiles">
  <datalist id="gitfiles"></datalist>
  <div class="chips" id="chips"></div>
  <label>小節（自由新增；編號 a/b/c… 自動接）</label>
  <div id="sections"></div>
  <button type="button" id="add-sec">＋ 新增小節</button>
  <div class="foot">
    <div id="form-err" class="err"></div>
    <div class="right"><button id="cancel">取消</button><button id="submit" class="primary">插入</button></div>
  </div>
</div></div>

<script>
const $=s=>document.querySelector(s);
let sel=null;
function setTheme(t){document.documentElement.dataset.theme=t;try{localStorage.setItem('theme',t);}catch(e){}
  $('#theme').textContent=t==='dark'?'☀️':'🌙';}
$('#theme').onclick=()=>setTheme(document.documentElement.dataset.theme==='dark'?'light':'dark');
setTheme(document.documentElement.dataset.theme||'light');
function esc(s){return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');}
function inline(s){
  s=s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
  s=s.replace(/`([^`]+)`/g,'<code>$1</code>');
  s=s.replace(/\*\*([^*]+)\*\*/g,'<strong>$1</strong>');
  s=s.replace(/\[([^\]]+)\]\(([^)]+)\)/g,'<a href="$2" target="_blank" rel="noopener">$1</a>');
  return s;
}
function mdToHtml(src){
  const L=src.split('\n'); let out='',i=0;
  const row=l=>l.trim().replace(/^\||\|$/g,'').split('|').map(s=>s.trim());
  while(i<L.length){
    let l=L[i];
    if(/^```/.test(l)){let b=[];i++;while(i<L.length&&!/^```/.test(L[i])){b.push(L[i]);i++;}i++;out+='<pre class="code">'+esc(b.join('\n'))+'</pre>';continue;}
    if(/^\s*\|/.test(l)&&i+1<L.length&&/^\s*\|[\s:|-]+\|/.test(L[i+1])){
      let h=row(l);i+=2;let rs=[];while(i<L.length&&/^\s*\|/.test(L[i])){rs.push(row(L[i]));i++;}
      out+='<table><thead><tr>'+h.map(c=>'<th>'+inline(c)+'</th>').join('')+'</tr></thead><tbody>'+
        rs.map(r=>'<tr>'+r.map(c=>'<td>'+inline(c)+'</td>').join('')+'</tr>').join('')+'</tbody></table>';continue;
    }
    let m=l.match(/^(#{1,6})\s+(.*)$/);
    if(m){let n=m[1].length;out+='<h'+n+'>'+inline(m[2])+'</h'+n+'>';i++;continue;}
    if(/^\s*---+\s*$/.test(l)){out+='<hr>';i++;continue;}
    if(/^\s*>\s?/.test(l)){
      let b=[];while(i<L.length&&/^\s*>\s?/.test(L[i])){b.push(L[i].replace(/^\s*>\s?/,''));i++;}
      const am=b.length?b[0].match(/^\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\]\s*(.*)$/i):null;
      if(am){
        const t=am[1].toLowerCase();
        let body=b.slice(1);if(am[2].trim())body.unshift(am[2]);
        const meta={note:['ℹ️','Note'],tip:['💡','Tip'],important:['📌','Important'],warning:['⚠️','Warning'],caution:['🛑','Caution']}[t];
        out+='<div class="alert alert-'+t+'"><div class="alert-title">'+meta[0]+' '+meta[1]+'</div>'+mdToHtml(body.join('\n'))+'</div>';
      }else{
        out+='<blockquote>'+inline(b.join(' '))+'</blockquote>';
      }
      continue;
    }
    if(/^\s*[-*]\s+/.test(l)){let b=[];while(i<L.length&&/^\s*[-*]\s+/.test(L[i])){b.push(L[i].replace(/^\s*[-*]\s+/,''));i++;}out+='<ul>'+b.map(x=>'<li>'+inline(x)+'</li>').join('')+'</ul>';continue;}
    if(/^\s*\d+\.\s+/.test(l)){let b=[];while(i<L.length&&/^\s*\d+\.\s+/.test(L[i])){b.push(L[i].replace(/^\s*\d+\.\s+/,''));i++;}out+='<ol>'+b.map(x=>'<li>'+inline(x)+'</li>').join('')+'</ol>';continue;}
    if(/^\s*$/.test(l)){i++;continue;}
    out+='<p>'+inline(l)+'</p>';i++;
  }
  return out;
}
async function load(){
  const qv=$('#q').value.trim();
  const q=encodeURIComponent(qv);
  const r=await fetch('/api/entries?q='+q);const items=await r.json();
  $('#count').textContent=(qv?('搜尋 '+items.entries.length+' / '+items.total):('共 '+items.total))+' 筆';
  $('#list').innerHTML = items.entries.length? items.entries.map(e=>
    `<div class="item${e.i===sel?' sel':''}" data-i="${e.i}"><div class="d">${e.number!=null?('#'+e.number):'—'}${e.time?(' · '+esc(e.time)):''}</div><div class="t">${esc(e.title)}</div></div>`).join('')
    : '<div class="empty">沒有符合的條目</div>';
  document.querySelectorAll('.item').forEach(el=>el.onclick=()=>show(+el.dataset.i));
}
function renderView(e){
  $('#detail').innerHTML=
    `<div class="toolbar"><button id="edit">編輯原始碼</button><button id="del">刪除</button></div>`+
    `<div id="content">`+mdToHtml(e.raw)+`</div>`;
  $('#edit').onclick=()=>renderEdit(e);
  const del=$('#del');let armed=false,timer=null;
  del.onclick=()=>{
    if(!armed){armed=true;del.textContent='確定刪除？';del.classList.add('danger');
      timer=setTimeout(()=>{armed=false;del.textContent='刪除';del.classList.remove('danger');},3000);return;}
    clearTimeout(timer);
    fetch('/api/delete',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({i:e.i})})
      .then(r=>r.json()).then(j=>{sel=null;$('#detail').innerHTML='<div class="empty">已刪除</div>';load();runLint();});
  };
}
let linting=false;
async function runLint(){
  if(linting)return;linting=true;
  const el=$('#lint');if(el)el.textContent='格式檢查中…';
  try{
    const j=await(await fetch('/api/lint',{method:'POST'})).json();
    if(el)el.textContent=(j.warnings&&j.warnings.length)?('⚠ '+j.warnings.join(' | ')):'';
  }catch(e){if(el)el.textContent='';}
  finally{linting=false;}
}
function renderEdit(e){
  $('#detail').innerHTML=
    `<div class="toolbar"><button id="save" class="primary">儲存</button><button id="cancel-edit">取消</button></div>`+
    `<textarea id="raw" spellcheck="false"></textarea>`;
  const ta=$('#raw');ta.value=e.raw;
  ta.style.height=Math.min(Math.max(340,ta.scrollHeight+6),window.innerHeight-160)+'px';
  ta.focus();
  ta.addEventListener('keydown',ev=>{if((ev.ctrlKey||ev.metaKey)&&ev.key==='s'){ev.preventDefault();$('#save').click();}});
  $('#cancel-edit').onclick=()=>renderView(e);
  $('#save').onclick=async()=>{
    const j=await(await fetch('/api/save',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({i:e.i,raw:ta.value})})).json();
    const ne=await(await fetch('/api/entry?i='+e.i)).json();ne.i=e.i;
    await load();renderView(ne);runLint();
  };
}
async function show(i){
  sel=i;
  const e=await(await fetch('/api/entry?i='+i)).json();e.i=i;
  document.querySelectorAll('.item').forEach(el=>el.classList.toggle('sel',+el.dataset.i===i));
  renderView(e);
}
$('#q').oninput=()=>load();
$('#reload').onclick=()=>load();
function makeSec(label,body){
  const d=document.createElement('div');d.className='sec';
  d.innerHTML='<div class="sec-head"><input class="sec-label" placeholder="小節標題，例如 診斷 / 修正 / 驗證"><button type="button" class="sec-del" title="移除">✕</button></div><textarea class="sec-body" placeholder="此小節的 markdown 內容（可留空）"></textarea>';
  d.querySelector('.sec-label').value=label||'';
  d.querySelector('.sec-body').value=body||'';
  d.querySelector('.sec-del').onclick=()=>d.remove();
  return d;
}
function clearSections(){const c=$('#sections');c.innerHTML='';c.appendChild(makeSec('診斷',''));c.appendChild(makeSec('修正',''));c.appendChild(makeSec('驗證',''));}
function collectSections(){return [...$('#sections').querySelectorAll('.sec')].map(s=>({label:s.querySelector('.sec-label').value.trim(),body:s.querySelector('.sec-body').value.trim()})).filter(s=>s.label||s.body);}
$('#add-sec').onclick=()=>$('#sections').appendChild(makeSec('',''));
$('#add').onclick=async()=>{
  ['f-title','f-file'].forEach(id=>$('#'+id).value='');
  clearSections();
  const info=await (await fetch('/api/meta')).json();
  $('#next-num').textContent='#'+info.next;
  $('#f-time').value=info.now;
  $('#gitfiles').innerHTML=info.files.map(f=>`<option value="${f}">`).join('');
  $('#chips').innerHTML=info.files.slice(0,12).map(f=>`<span class="chip">${esc(f)}</span>`).join('');
  document.querySelectorAll('.chip').forEach(c=>c.onclick=()=>$('#f-file').value=c.textContent);
  $('#form-err').textContent='';$('#modal').hidden=false;$('#f-title').focus();
};
$('#cancel').onclick=()=>$('#modal').hidden=true;
$('#submit').onclick=async()=>{
  const title=$('#f-title').value.trim();
  if(!title){$('#form-err').textContent='請填標題';$('#f-title').focus();return;}
  $('#form-err').textContent='';
  const body={title,time:$('#f-time').value.trim(),file:$('#f-file').value.trim(),sections:collectSections()};
  const j=await(await fetch('/api/add',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)})).json();
  $('#modal').hidden=true;await load();show(0);runLint();
};
load();
</script>
</body></html>
"""


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code, body, ctype="application/json; charset=utf-8"):
        data = body.encode("utf-8") if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        u = urlparse(self.path)
        if u.path == "/":
            return self._send(200, PAGE, "text/html; charset=utf-8")
        if u.path == "/favicon.ico":
            return self._send(204, b"")
        if u.path == "/api/entries":
            q = parse_qs(u.query).get("q", [""])[0].lower()
            entries = parse_entries()
            hits = []
            for e in entries:
                hay = (e["title"] + "\n" + e["raw"]).lower()
                if q and q not in hay:
                    continue
                hits.append({"i": e["i"], "number": e["number"], "title": e["title"],
                             "time": e.get("time", "")})
            return self._send(200, json.dumps({"total": len(entries), "entries": hits}, ensure_ascii=False))
        if u.path == "/api/entry":
            i = int(parse_qs(u.query).get("i", ["0"])[0])
            entries = parse_entries()
            if 0 <= i < len(entries):
                return self._send(200, json.dumps(entries[i], ensure_ascii=False))
            return self._send(404, "{}")
        if u.path == "/api/meta":
            return self._send(200, json.dumps(
                {"next": next_number(), "files": git_changed_files(), "now": now_stamp()},
                ensure_ascii=False))
        return self._send(404, "{}")

    def do_POST(self):
        u = urlparse(self.path)
        n = int(self.headers.get("Content-Length", "0"))
        try:
            body = json.loads(self.rfile.read(n) or b"{}")
        except Exception:
            body = {}
        try:
            if u.path == "/api/add":
                num = next_number()
                time_str = body["time"] if body.get("time") is not None else now_stamp()
                insert_block(build_block(num, body.get("title", "(無標題)"),
                                         body.get("file", ""), body.get("sections", []),
                                         time_str=time_str))
                return self._send(200, json.dumps({"ok": True, "number": num}, ensure_ascii=False))
            if u.path == "/api/save":
                update_entry(int(body["i"]), body["raw"])
                return self._send(200, json.dumps({"ok": True}, ensure_ascii=False))
            if u.path == "/api/delete":
                delete_entry(int(body["i"]))
                return self._send(200, json.dumps({"ok": True}, ensure_ascii=False))
            if u.path == "/api/lint":
                return self._send(200, json.dumps({"warnings": lint_after_write()}, ensure_ascii=False))
        except Exception as ex:
            return self._send(400, json.dumps({"ok": False, "error": str(ex)}, ensure_ascii=False))
        return self._send(404, "{}")


class _Server(ThreadingHTTPServer):
    # Windows 上 allow_reuse_address=1 會讓第二個實例搶綁同一埠；關掉，綁不到就換埠。
    allow_reuse_address = False


def serve(port=8710, open_browser=True):
    try:
        httpd = _Server(("127.0.0.1", port), Handler)
    except OSError:
        httpd = _Server(("127.0.0.1", 0), Handler)
    url = "http://127.0.0.1:%d/" % httpd.server_address[1]
    print("CHANGES.md GUI: %s" % url)
    print("（Ctrl+C 結束）")
    if open_browser:
        threading.Timer(0.4, lambda: webbrowser.open(url)).start()
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nbye")


def main():
    p = argparse.ArgumentParser(description="CHANGES.md：網頁 GUI + CLI")
    sub = p.add_subparsers(dest="cmd")

    sv = sub.add_parser("serve", help="啟動本機網頁 GUI")
    sv.add_argument("--port", type=int, default=8710)
    sv.add_argument("--no-browser", action="store_true")

    a = sub.add_parser("add", help="插入新條目（CLI）")
    a.add_argument("title")
    a.add_argument("--file", default="")
    a.add_argument("--time", default=None, help="時間 YYYY/MM/DD HH:MM:SS（預設當前；傳空字串則不附）")
    a.add_argument("--section", action="append", default=[], help="小節，格式 標題=內容（可重複）")

    l = sub.add_parser("list", help="檢索條目（CLI）")
    l.add_argument("--grep", default="")
    l.add_argument("--file", default="")
    l.add_argument("--number", type=int, default=0)

    s = sub.add_parser("show", help="顯示單筆完整內容（編號或關鍵字）")
    s.add_argument("query")

    args = p.parse_args()
    if args.cmd in (None, "serve"):
        serve(getattr(args, "port", 8710), not getattr(args, "no_browser", False))
    elif args.cmd == "add":
        cmd_add(args)
    elif args.cmd == "list":
        cmd_list(args)
    elif args.cmd == "show":
        cmd_show(args)


if __name__ == "__main__":
    main()
