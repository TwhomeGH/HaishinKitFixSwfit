/* 極簡 Markdown 渲染（零依賴）：標題、清單（含巢狀）、表格、程式碼區塊、引言與 GitHub 提示框。
   提供 window.renderMarkdown(text, resolveHref)；resolveHref 可把相對連結改寫成站內連結。 */
(function () {
  const esc = (s) => window.HL.esc(s);

  const ALERTS = {
    note: { label: "注意", icon: "\u2139\uFE0F" },
    tip: { label: "提示", icon: "\uD83D\uDCA1" },
    important: { label: "重要", icon: "\u2757" },
    warning: { label: "警告", icon: "\u26A0\uFE0F" },
    caution: { label: "小心", icon: "\uD83D\uDD25" },
  };

  let resolve = (href) => href;

  /* 行內語法：程式碼、粗體、斜體、刪除線、圖片、連結。 */
  function inline(text) {
    let s = esc(text);
    s = s.replace(/!\[([^\]]*)\]\(([^)\s]+)\)/g, '<img alt="$1" src="$2" loading="lazy">');
    s = s.replace(/\[([^\]]+)\]\(([^)\s]+)[^)]*\)/g,
      (_m, label, href) => `<a href="${esc(resolve(href))}">${label}</a>`);
    s = s.replace(/`([^`]+)`/g, "<code>$1</code>");
    s = s.replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>");
    s = s.replace(/(^|[^*])\*([^*\s][^*]*)\*/g, "$1<em>$2</em>");
    s = s.replace(/~~([^~]+)~~/g, "<del>$1</del>");
    return s;
  }

  function splitRow(line) {
    return line.trim().replace(/^\||\|$/g, "").split("|").map((c) => c.trim());
  }
  function table(header, rows) {
    const head = "<tr>" + header.map((c) => `<th>${inline(c)}</th>`).join("") + "</tr>";
    const body = rows.map((r) => "<tr>" + r.map((c) => `<td>${inline(c)}</td>`).join("") + "</tr>").join("");
    return `<table><thead>${head}</thead><tbody>${body}</tbody></table>`;
  }

  /* 以縮排把清單項目組成樹，再遞迴輸出巢狀 ul/ol。 */
  function listHtml(items) {
    const root = { ordered: items[0].ordered, text: "", children: [] };
    const stack = [root];
    for (const it of items) {
      while (stack.length > 1 && it.indent <= stack[stack.length - 1].indent) stack.pop();
      const node = { ordered: it.ordered, text: it.text, indent: it.indent, children: [] };
      stack[stack.length - 1].children.push(node);
      stack.push(node);
    }
    const emit = (node) => {
      const tag = node.ordered ? "ol" : "ul";
      return `<${tag}>` + node.children.map((c) =>
        `<li>${inline(c.text)}${c.children.length ? emit(c) : ""}</li>`).join("") + `</${tag}>`;
    };
    return emit(root);
  }

  /* 引言；若首行為 [!TYPE] 則輸出提示框，其餘內容照 markdown 渲染。 */
  function quote(lines) {
    const alert = lines[0] && lines[0].match(/^\s*\[!(\w+)\]\s*(.*)$/);
    if (alert && ALERTS[alert[1].toLowerCase()]) {
      const meta = ALERTS[alert[1].toLowerCase()];
      const title = alert[2].trim() || meta.label;
      const body = render(lines.slice(1).join("\n"));
      return `<div class="alert alert-${alert[1].toLowerCase()}">` +
        `<p class="alert-title"><span class="alert-icon">${meta.icon}</span>${inline(title)}</p>${body}</div>`;
    }
    return `<blockquote>${render(lines.join("\n"))}</blockquote>`;
  }

  const isBlockStart = (line, next) => {
    if (!line.trim()) return true;
    if (/^\s{0,3}(#{1,6}\s|```|>)/.test(line)) return true;
    if (/^\s{0,3}([-*_])(\s*\1){2,}\s*$/.test(line)) return true;
    if (/^(\s*)([-*+]|\d+[.)])\s+/.test(line)) return true;
    if (line.includes("|") && next && /^\s*\|?[\s:|-]+\|[\s:|-]*$/.test(next)) return true;
    return false;
  };

  function render(text) {
    const lines = String(text).replace(/\r\n?/g, "\n").split("\n");
    const out = [];
    let i = 0;
    while (i < lines.length) {
      const line = lines[i];

      const fence = line.match(/^\s*```(\S+)?\s*$/);
      if (fence) {
        const lang = fence[1] || "";
        const buf = [];
        i++;
        while (i < lines.length && !/^\s*```\s*$/.test(lines[i])) { buf.push(lines[i]); i++; }
        i++;
        out.push(`<pre class="code"><code>${window.HL.block(buf.join("\n"), lang)}</code></pre>`);
        continue;
      }

      const heading = line.match(/^\s{0,3}(#{1,6})\s+(.*?)\s*#*\s*$/);
      if (heading) { const l = heading[1].length; out.push(`<h${l}>${inline(heading[2])}</h${l}>`); i++; continue; }

      if (/^\s{0,3}([-*_])(\s*\1){2,}\s*$/.test(line)) { out.push("<hr>"); i++; continue; }

      if (line.includes("|") && i + 1 < lines.length && /^\s*\|?[\s:|-]+\|[\s:|-]*$/.test(lines[i + 1])) {
        const header = splitRow(line);
        i += 2;
        const rows = [];
        while (i < lines.length && lines[i].includes("|") && lines[i].trim()) { rows.push(splitRow(lines[i])); i++; }
        out.push(table(header, rows));
        continue;
      }

      if (/^\s{0,3}>/.test(line)) {
        const buf = [];
        while (i < lines.length && /^\s{0,3}>/.test(lines[i])) { buf.push(lines[i].replace(/^\s{0,3}>\s?/, "")); i++; }
        out.push(quote(buf));
        continue;
      }

      const item = line.match(/^(\s*)([-*+]|\d+[.)])\s+(.*)$/);
      if (item) {
        const items = [];
        while (i < lines.length) {
          const m = lines[i].match(/^(\s*)([-*+]|\d+[.)])\s+(.*)$/);
          if (!m) break;
          items.push({ indent: m[1].replace(/\t/g, "  ").length, ordered: /\d/.test(m[2]), text: m[3] });
          i++;
        }
        out.push(listHtml(items));
        continue;
      }

      if (!line.trim()) { i++; continue; }

      const para = [line];
      i++;
      while (i < lines.length && !isBlockStart(lines[i], lines[i + 1])) { para.push(lines[i]); i++; }
      out.push(`<p>${inline(para.join(" "))}</p>`);
    }
    return out.join("\n");
  }

  window.renderMarkdown = (text, resolveHref) => {
    resolve = typeof resolveHref === "function" ? resolveHref : (href) => href;
    return render(text);
  };
})();
