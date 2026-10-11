/* 開發索引：功能／API 宣告／文件／近期改動。資料來自 /development/data。 */
const $ = (s) => document.querySelector(s);
let data = null, tab = "features";

const LABELS = {
  features: "功能與接入",
  symbols: "API 宣告",
  documents: "文件",
  repos: "近期改動／版本",
};

function esc(s) {
  return String(s ?? "").replace(/[&<>"']/g, (c) => (
    { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]
  ));
}

/* 行內 markdown（用於註釋、摘要）：跳脫後套用 code/bold/link。 */
function mdInline(s) {
  s = esc(s);
  s = s.replace(/`([^`]+)`/g, "<code>$1</code>");
  s = s.replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>");
  s = s.replace(/\[([^\]]+)\]\(([^)]+)\)/g, '<a href="$2" target="_blank" rel="noopener">$1</a>');
  return s;
}

/* 把相鄰 /// 註釋字串轉成簡單段落／條列。 */
function mdDoc(text) {
  if (!text) return "";
  const lines = text.split("\n");
  let out = "", list = [];
  const flush = () => { if (list.length) { out += "<ul>" + list.map((x) => "<li>" + mdInline(x) + "</li>").join("") + "</ul>"; list = []; } };
  for (const l of lines) {
    const m = l.match(/^\s*[-*]\s+(.*)$/);
    if (m) { list.push(m[1]); continue; }
    flush();
    if (l.trim()) out += "<p>" + mdInline(l) + "</p>";
  }
  flush();
  return out;
}

function kindOf(name) {
  const m = name.match(/\b(func|struct|class|enum|protocol|actor)\b/);
  return m ? m[1] : "decl";
}

function links(items) {
  return items.map((p) => `<a href="/development/file?repo=app&path=${encodeURIComponent(p)}">${esc(p)}</a>`).join("");
}

/* ── 近期改動：提交卡片與 lazy 差異 ── */

function commitCard(repo, c) {
  const files = (c.files || []).map((f) =>
    `<a class="cfile" href="#" data-repo="${esc(repo)}" data-hash="${esc(c.hash)}" data-path="${esc(f)}">${esc(f)}</a>`
  ).join("");
  const when = (c.date || "").slice(0, 16).replace("T", " ");
  return `<div class="commit" data-repo="${esc(repo)}" data-hash="${esc(c.hash)}">` +
    `<button class="commit-head" type="button"><span class="commit-top"><code class="hash">${esc(c.hash)}</code>` +
    `<span class="when">${esc(when)}</span></span>` +
    `<span class="subject">${esc(c.subject)}</span></button>` +
    `<div class="commit-files">${files || '<span class="muted">（無檔案變更）</span>'}</div>` +
    `<div class="diff" hidden></div></div>`;
}

function diffLineClass(l) {
  if (l.startsWith("@@")) return "d-hunk";
  if (l.startsWith("+++") || l.startsWith("---") || l.startsWith("diff --git")) return "d-file";
  if (l.startsWith("+")) return "d-add";
  if (l.startsWith("-")) return "d-del";
  if (/^(index |new file|deleted file|similarity|rename |old mode|new mode|Binary files)/.test(l) ||
      l.startsWith("\\ No newline")) return "d-meta";
  if (l.startsWith(" ")) return "d-ctx";
  return "d-plain";
}

function renderDiff(j) {
  if (j.empty) return '<p class="muted">沒有差異。</p>';
  const hl = window.HL;
  const swift = hl ? hl.swift : (t) => esc(t);
  const esc2 = hl ? hl.esc : esc;
  const state = { block: false };
  const body = j.diff.split("\n").map((l) => {
    const cls = diffLineClass(l);
    if (cls === "d-file") state.block = false;
    if (cls === "d-add" || cls === "d-del" || cls === "d-ctx") {
      const mark = l[0] || " ";
      return `<span class="dline ${cls}"><span class="dmark">${esc2(mark)}</span>${swift(l.slice(1), state)}</span>`;
    }
    return `<span class="dline ${cls}"><span class="dmark"> </span>${esc2(l)}</span>`;
  }).join("");
  return '<pre class="dpre">' + body + "</pre>" +
    (j.truncated ? '<p class="muted">（差異過大，僅顯示前段）</p>' : "");
}

const diffCache = new Map();
async function loadDiff(box, params) {
  const qs = params.toString();
  if (diffCache.has(qs)) { box.innerHTML = diffCache.get(qs); box.hidden = false; return; }
  box.hidden = false;
  box.innerHTML = '<p class="muted">讀取差異…</p>';
  try {
    const res = await fetch("/development/diff?" + qs);
    const j = await res.json();
    if (!res.ok) throw Error(j.error || res.statusText);
    const html = renderDiff(j);
    diffCache.set(qs, html);
    box.innerHTML = html;
  } catch (e) {
    box.innerHTML = '<p class="empty">讀取失敗：' + esc(e.message) + "</p>";
  }
}

function render() {
  if (!data) return;
  document.querySelectorAll("#tabs button").forEach((b) =>
    b.setAttribute("aria-pressed", b.dataset.key === tab));
  const q = $("#search").value.toLowerCase();
  const repo = $("#repo").value;
  const match = (r) => JSON.stringify(r).toLowerCase().includes(q) &&
    (!repo || r.repo === repo || (r.id && tab === "features"));

  const rows = (data[tab] || []).filter(match);
  $("#message").textContent = `${rows.length} 筆結果 · 搜尋可輸入功能、路徑或 API 名稱`;

  let out = "";
  if (tab === "repos") {
    const deps = (data.lockedPackages || []).map((p) =>
      `<code>${esc(p.identity)}</code><code>${esc((p.revision || "").slice(0, 12))}</code>`).join("");
    out += '<article class="card"><h2>鎖定套件</h2><div class="deps">' + (deps || "<code>（無）</code><code></code>") + "</div>" +
      "<p class=muted>checkout 與鎖定版本需分別確認；此處不是已安裝 App 的 BuildInfo。</p></article>";
  }
  for (const r of rows.slice(0, 250)) {
    if (tab === "features") {
      out += `<article class="card"><h2>${esc(r.name)}</h2><div class="meta">${esc(r.id)}</div>` +
        `<p>${mdInline(r.summary)}</p><dl>` +
        [["ReplayKit", r.replaykit], ["ScreenCaptureKit", r.screencapturekit], ["前端／使用入口", r.ui], ["驗證狀態", r.verification]]
          .map(([k, v]) => `<dt>${esc(k)}</dt><dd>${esc(v)}</dd>`).join("") +
        `</dl><h3>程式與文件</h3><div class="files">${links(r.files)}${links(r.docs)}</div></article>`;
    } else if (tab === "symbols") {
      out += `<article class="card"><h2><a href="${esc(r.url)}">${esc(r.name)}</a></h2>` +
        `<div class="meta"><span class="kind">${esc(r.kind || kindOf(r.name))}</span>${esc(r.repo)} · ${esc(r.file)}:${r.line}</div>` +
        (r.signature ? `<pre class="sig">${esc(r.signature)}</pre>` : "") +
        `<div class="doc">${r.comment ? mdDoc(r.comment) : '<p class="muted">尚無相鄰 /// 文件註釋</p>'}</div></article>`;
    } else if (tab === "documents") {
      out += `<article class="card"><h2><a href="${esc(r.url)}">${esc(r.name)}</a></h2>` +
        `<div class="meta">${esc(r.repo)}</div><div class="preview">${esc(r.text.slice(0, 260))}${r.text.length > 260 ? " …" : ""}</div></article>`;
    } else {
      const list = (r.commits || []).map((c) => commitCard(r.name, c)).join("");
      out += `<article class="card"><h2>${esc(r.name)}</h2><div class="meta">HEAD：${esc(r.head)}</div>` +
        `<h3>未提交變更（含未追蹤檔案）</h3><pre class="blob">${esc(r.changes || "工作區乾淨")}</pre>` +
        `<div class="wt-wrap"><button class="wt-btn" type="button" data-repo="${esc(r.name)}">檢視工作區差異</button>` +
        `<div class="diff" hidden></div></div>` +
        `<h3>最近 20 筆提交與檔案</h3><div class="commits">${list}</div></article>`;
    }
  }
  if (rows.length > 250) out += '<p class="muted">目前顯示前 250 筆，請縮小搜尋範圍。</p>';
  $("#results").innerHTML = out || '<p class="empty">沒有符合的資料。</p>';
}

async function load() {
  $("#message").textContent = "正在讀取…";
  diffCache.clear();
  try {
    const response = await fetch("/development/data");
    const result = await response.json();
    if (!response.ok) throw Error(result.error);
    data = result;
    if (tab === "features" && !(data.features && data.features.length)) tab = "symbols";
    buildTabs();
    const repos = [...new Set((data.symbols.concat(data.documents)).map((r) => r.repo))].sort();
    const sel = $("#repo");
    sel.innerHTML = '<option value="">全部來源</option>' +
      repos.map((r) => `<option value="${esc(r)}">${esc(r)}</option>`).join("");
    render();
  } catch (e) {
    $("#message").textContent = "讀取失敗：" + e.message;
  }
}

function buildTabs() {
  const nav = $("#tabs");
  nav.innerHTML = "";
  for (const [key, title] of Object.entries(LABELS)) {
    if (key === "features" && !(data.features && data.features.length)) continue;
    const b = document.createElement("button");
    b.textContent = title; b.dataset.key = key;
    b.onclick = () => { tab = key; render(); };
    nav.append(b);
  }
}
$("#search").oninput = render;
$("#repo").onchange = render;
$("#reload").onclick = load;

/* 事件委派：提交標題、檔名、工作區差異鈕（#results 每次 render 會重建）。 */
$("#results").addEventListener("click", (e) => {
  const file = e.target.closest("a.cfile");
  if (file) {
    e.preventDefault();
    loadDiff(file.closest(".commit").querySelector(".diff"),
      new URLSearchParams({ repo: file.dataset.repo, hash: file.dataset.hash, path: file.dataset.path }));
    return;
  }
  const head = e.target.closest(".commit-head");
  if (head) {
    const box = head.parentElement.querySelector(".diff");
    if (!box.hidden && box.innerHTML) { box.hidden = true; return; }
    loadDiff(box, new URLSearchParams({ repo: head.parentElement.dataset.repo, hash: head.parentElement.dataset.hash }));
    return;
  }
  const wt = e.target.closest(".wt-btn");
  if (wt) loadDiff(wt.parentElement.querySelector(".diff"), new URLSearchParams({ repo: wt.dataset.repo, worktree: "1" }));
});

load();
