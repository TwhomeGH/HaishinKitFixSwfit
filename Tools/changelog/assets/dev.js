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
      out += `<article class="card"><h2>${esc(r.name)}</h2><div class="meta">HEAD：${esc(r.head)}</div>` +
        `<h3>未提交變更（含未追蹤檔案）</h3><pre class="blob">${esc(r.changes || "工作區乾淨")}</pre>` +
        `<h3>最近 20 筆提交與檔案</h3><pre class="blob">${esc(r.commits)}</pre></article>`;
    }
  }
  if (rows.length > 250) out += '<p class="muted">目前顯示前 250 筆，請縮小搜尋範圍。</p>';
  $("#results").innerHTML = out || '<p class="empty">沒有符合的資料。</p>';
}

async function load() {
  $("#message").textContent = "正在讀取…";
  try {
    const response = await fetch("/development/data");
    const result = await response.json();
    if (!response.ok) throw Error(result.error);
    data = result;
    const repos = [...new Set((data.symbols.concat(data.documents)).map((r) => r.repo))].sort();
    const sel = $("#repo");
    sel.innerHTML = '<option value="">全部來源</option>' +
      repos.map((r) => `<option value="${esc(r)}">${esc(r)}</option>`).join("");
    render();
  } catch (e) {
    $("#message").textContent = "讀取失敗：" + e.message;
  }
}

for (const [key, title] of Object.entries(LABELS)) {
  const b = document.createElement("button");
  b.textContent = title; b.dataset.key = key;
  b.onclick = () => { tab = key; render(); };
  $("#tabs").append(b);
}
$("#search").oninput = render;
$("#repo").onchange = render;
$("#reload").onclick = load;
load();
