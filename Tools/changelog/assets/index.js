/* 變更歷史 GUI：清單／檢視／編輯／新增。深淺色由 theme.js 處理。 */
const $ = (s) => document.querySelector(s);
let sel = null;

function esc(s) {
  return String(s ?? "").replace(/[&<>"']/g, (c) => (
    { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]
  ));
}

/* 行內 markdown：code → strong → link。先跳脫 HTML 再套用。 */
function inline(s) {
  s = esc(s);
  s = s.replace(/`([^`]+)`/g, "<code>$1</code>");
  s = s.replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>");
  s = s.replace(/\[([^\]]+)\]\(([^)]+)\)/g, '<a href="$2" target="_blank" rel="noopener">$1</a>');
  return s;
}

/* 極簡 markdown → HTML：程式碼區塊、表格、標題、hr、引言/alert、清單、段落。 */
function mdToHtml(src) {
  const L = src.split("\n");
  let out = "", i = 0;
  const row = (l) => l.trim().replace(/^\||\|$/g, "").split("|").map((s) => s.trim());
  while (i < L.length) {
    const l = L[i];
    if (/^```/.test(l)) {
      const b = []; i++;
      while (i < L.length && !/^```/.test(L[i])) { b.push(L[i]); i++; }
      i++; out += '<pre class="code">' + esc(b.join("\n")) + "</pre>"; continue;
    }
    if (/^\s*\|/.test(l) && i + 1 < L.length && /^\s*\|[\s:|-]+\|/.test(L[i + 1])) {
      const h = row(l); i += 2; const rs = [];
      while (i < L.length && /^\s*\|/.test(L[i])) { rs.push(row(L[i])); i++; }
      out += "<table><thead><tr>" + h.map((c) => "<th>" + inline(c) + "</th>").join("") +
        "</tr></thead><tbody>" +
        rs.map((r) => "<tr>" + r.map((c) => "<td>" + inline(c) + "</td>").join("") + "</tr>").join("") +
        "</tbody></table>"; continue;
    }
    let m = l.match(/^(#{1,6})\s+(.*)$/);
    if (m) { const n = m[1].length; out += "<h" + n + ">" + inline(m[2]) + "</h" + n + ">"; i++; continue; }
    if (/^\s*---+\s*$/.test(l)) { out += "<hr>"; i++; continue; }
    if (/^\s*>\s?/.test(l)) {
      const b = [];
      while (i < L.length && /^\s*>\s?/.test(L[i])) { b.push(L[i].replace(/^\s*>\s?/, "")); i++; }
      const am = b.length ? b[0].match(/^\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\]\s*(.*)$/i) : null;
      if (am) {
        const t = am[1].toLowerCase();
        const body = b.slice(1); if (am[2].trim()) body.unshift(am[2]);
        const meta = { note: ["ℹ️", "Note"], tip: ["💡", "Tip"], important: ["📌", "Important"], warning: ["⚠️", "Warning"], caution: ["🛑", "Caution"] }[t];
        out += '<div class="alert alert-' + t + '"><div class="alert-title">' + meta[0] + " " + meta[1] + "</div>" + mdToHtml(body.join("\n")) + "</div>";
      } else {
        out += "<blockquote>" + inline(b.join(" ")) + "</blockquote>";
      }
      continue;
    }
    if (/^\s*[-*]\s+/.test(l)) {
      const b = [];
      while (i < L.length && /^\s*[-*]\s+/.test(L[i])) { b.push(L[i].replace(/^\s*[-*]\s+/, "")); i++; }
      out += "<ul>" + b.map((x) => "<li>" + inline(x) + "</li>").join("") + "</ul>"; continue;
    }
    if (/^\s*\d+\.\s+/.test(l)) {
      const b = [];
      while (i < L.length && /^\s*\d+\.\s+/.test(L[i])) { b.push(L[i].replace(/^\s*\d+\.\s+/, "")); i++; }
      out += "<ol>" + b.map((x) => "<li>" + inline(x) + "</li>").join("") + "</ol>"; continue;
    }
    if (/^\s*$/.test(l)) { i++; continue; }
    out += "<p>" + inline(l) + "</p>"; i++;
  }
  return out;
}

async function load() {
  const q = encodeURIComponent($("#q").value), t = encodeURIComponent($("#type").value);
  const r = await fetch("/api/entries?q=" + q + "&type=" + t);
  const items = await r.json();
  $("#list").innerHTML = items.length
    ? items.map((e) => `<div class="item${e.i === sel ? " sel" : ""}" data-i="${e.i}"><div class="d">${e.date ? esc(e.date + (e.time ? " " + e.time : "")) : "未標日期"}</div><div class="t">${esc(e.title)}</div></div>`).join("")
    : '<div class="empty">沒有符合的紀錄</div>';
  document.querySelectorAll(".item").forEach((el) => (el.onclick = () => show(+el.dataset.i)));
}

function renderView(e) {
  $("#detail").innerHTML =
    '<div class="toolbar"><button id="edit">編輯</button><button id="del">刪除</button></div>' +
    '<div id="content">' + mdToHtml(e.raw) + "</div>";
  $("#edit").onclick = () => renderEdit(e);
  let armed = false;
  $("#del").onclick = () => {
    if (!armed) {
      armed = true; $("#del").textContent = "確定刪除？"; $("#del").classList.add("danger");
      setTimeout(() => { armed = false; $("#del").textContent = "刪除"; $("#del").classList.remove("danger"); }, 3000);
      return;
    }
    fetch("/api/delete", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ i: e.i }) })
      .then(() => { sel = null; $("#detail").innerHTML = '<div class="empty">已刪除</div>'; load(); });
  };
}

function renderEdit(e) {
  $("#detail").innerHTML =
    '<div class="toolbar"><button id="save" class="primary">儲存</button><button id="cancel-edit">取消</button></div>' +
    '<textarea id="raw" spellcheck="false"></textarea>';
  const ta = $("#raw"); ta.value = e.raw;
  const autosize = () => { ta.style.height = "auto"; ta.style.height = Math.max(320, ta.scrollHeight + 6) + "px"; };
  ta.addEventListener("input", autosize); autosize(); ta.focus();
  ta.addEventListener("keydown", (ev) => { if ((ev.ctrlKey || ev.metaKey) && ev.key === "s") { ev.preventDefault(); $("#save").click(); } });
  $("#cancel-edit").onclick = () => renderView(e);
  $("#save").onclick = async () => {
    await fetch("/api/save", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ i: e.i, raw: ta.value }) });
    const ne = await (await fetch("/api/entry?i=" + e.i)).json(); ne.i = e.i;
    await load(); renderView(ne);
  };
}

async function show(i) {
  sel = i;
  const e = await (await fetch("/api/entry?i=" + i)).json(); e.i = i;
  document.querySelectorAll(".item").forEach((el) => el.classList.toggle("sel", +el.dataset.i === i));
  renderView(e);
}

$("#q").oninput = () => load();
$("#type").onchange = () => load();
$("#reload").onclick = () => load();

/* 相關文件：可動態新增/移除的 label + url 列。 */
function makeRefRow(label, url) {
  const d = document.createElement("div"); d.className = "ref-row";
  d.innerHTML = '<input class="ref-label" placeholder="顯示文字（可留空）"><input class="ref-url" placeholder="連結或路徑，Docs/… 或 https://…"><button type="button" class="ref-del" title="移除">✕</button>';
  d.querySelector(".ref-label").value = label || "";
  d.querySelector(".ref-url").value = url || "";
  d.querySelector(".ref-del").onclick = () => d.remove();
  return d;
}
function clearRefs() { const c = $("#refs"); c.innerHTML = ""; c.appendChild(makeRefRow()); }
function collectRefs() {
  return [...$("#refs").querySelectorAll(".ref-row")].map((r) => {
    const label = r.querySelector(".ref-label").value.trim();
    const url = r.querySelector(".ref-url").value.trim();
    if (!url) return label;
    return `[${label || url}](${url})`;
  }).filter(Boolean);
}
$("#add-ref").onclick = () => $("#refs").appendChild(makeRefRow());

$("#add").onclick = async () => {
  const now = new Date(), p = (n) => String(n).padStart(2, "0");
  $("#f-date").value = `${now.getFullYear()}.${p(now.getMonth() + 1)}.${p(now.getDate())}`;
  $("#f-time").value = `${p(now.getHours())}:${p(now.getMinutes())}`;
  ["f-title", "f-file", "f-problem", "f-cause", "f-changes"].forEach((id) => ($("#" + id).value = ""));
  clearRefs();
  const files = await (await fetch("/api/gitdiff")).json();
  $("#gitfiles").innerHTML = files.map((f) => `<option value="${f}">`).join("");
  $("#chips").innerHTML = files.slice(0, 12).map((f) => `<span class="chip">${esc(f)}</span>`).join("");
  document.querySelectorAll(".chip").forEach((c) => (c.onclick = () => ($("#f-file").value = c.textContent)));
  $("#form-err").textContent = ""; $("#modal").hidden = false; $("#f-title").focus();
};
$("#cancel").onclick = () => ($("#modal").hidden = true);
$("#submit").onclick = async () => {
  const title = $("#f-title").value.trim();
  if (!title) { $("#form-err").textContent = "請填標題"; $("#f-title").focus(); return; }
  $("#form-err").textContent = "";
  const body = {
    title, date: $("#f-date").value.trim(), time: $("#f-time").value.trim(), type: $("#f-type").value,
    file: $("#f-file").value.trim(),
    problem: $("#f-problem").value.trim(), root_cause: $("#f-cause").value.trim(),
    changes: $("#f-changes").value.split("\n").map((s) => s.replace(/^\s*[-*]\s*/, "").trim()).filter(Boolean),
    refs: collectRefs(),
  };
  await fetch("/api/add", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });
  $("#modal").hidden = true; await load(); show(0);
};

load();
