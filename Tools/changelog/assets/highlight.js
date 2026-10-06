/* 輕量語法上色（零依賴）：檔案檢視的逐行來源與 Markdown 程式碼區塊共用。 */
(function () {
  const esc = (s) => String(s).replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" }[c]));
  const span = (cls, text) => (cls ? `<span class="tok-${cls}">${esc(text)}</span>` : esc(text));

  const KEYWORDS = new Set(
    ("func var let class struct enum protocol extension init deinit subscript typealias associatedtype " +
      "import if else guard switch case default for while repeat return break continue throw throws rethrow " +
      "try catch defer do in where as is some any await async actor static self Self super nil true false " +
      "public private internal fileprivate open final override mutating nonmutating lazy weak unowned " +
      "indirect convenience required dynamic inout").split(/\s+/));

  /* Swift 逐字掃描：字串、註釋（含跨行）、數字、屬性/前置、關鍵字、型別與函式呼叫。 */
  function swift(line, state) {
    let out = "", i = 0;
    const n = line.length;
    while (i < n) {
      if (state.block) {
        const end = line.indexOf("*/", i);
        if (end === -1) { out += span("c", line.slice(i)); i = n; break; }
        out += span("c", line.slice(i, end + 2)); i = end + 2; state.block = false; continue;
      }
      const c = line[i];
      if (c === "/" && line[i + 1] === "/") { out += span("c", line.slice(i)); break; }
      if (c === "/" && line[i + 1] === "*") {
        const end = line.indexOf("*/", i + 2);
        if (end === -1) { out += span("c", line.slice(i)); state.block = true; break; }
        out += span("c", line.slice(i, end + 2)); i = end + 2; continue;
      }
      if (c === '"') {
        let j = i + 1;
        while (j < n) { if (line[j] === "\\") { j += 2; continue; } if (line[j] === '"') { j++; break; } j++; }
        out += span("s", line.slice(i, j)); i = j; continue;
      }
      if (c === "@" || c === "#") {
        const m = line.slice(i).match(/^[@#][A-Za-z_]\w*/);
        if (m) { out += span("a", m[0]); i += m[0].length; continue; }
      }
      if (/[0-9]/.test(c) && !/[A-Za-z0-9_]/.test(line[i - 1] || "")) {
        const m = line.slice(i).match(/^0[xX][0-9A-Fa-f_]+|^0[bB][01_]+|^\d[\d_.eExX]*/);
        out += span("n", m[0]); i += m[0].length; continue;
      }
      if (/[A-Za-z_]/.test(c)) {
        const m = line.slice(i).match(/^[A-Za-z_]\w*/)[0];
        const isCall = /^\s*\(/.test(line.slice(i + m.length));
        const cls = KEYWORDS.has(m) ? "k" : (/^[A-Z]/.test(m) ? "t" : (isCall ? "f" : ""));
        out += span(cls, m); i += m.length; continue;
      }
      const m = line.slice(i).match(/^[^\sA-Za-z0-9_@#"/]+|\s+/);
      if (m) { out += esc(m[0]); i += m[0].length; } else { out += esc(c); i += 1; }
    }
    return out;
  }

  /* Markdown 逐行上色（原始碼檢視用）：標題、引言、行內程式碼與連結。 */
  function markdownLine(line) {
    if (/^\s{0,3}#{1,6}\s/.test(line)) return span("k", line);
    if (/^\s{0,3}>\s?/.test(line)) return span("c", line);
    return esc(line)
      .replace(/`([^`]+)`/g, '<span class="tok-s">`$1`</span>')
      .replace(/\[([^\]]+)\]\(([^)]+)\)/g, '<span class="tok-t">$1</span>($2)');
  }

  /* 整段程式碼上色：Markdown 用逐行；其餘語言共用 Swift 掃描（近似）。 */
  function block(text, lang) {
    const language = (lang || "").toLowerCase();
    const lines = text.split("\n");
    if (language === "md" || language === "markdown") return lines.map(markdownLine).join("\n");
    const state = { block: false };
    return lines.map((line) => swift(line, state)).join("\n");
  }

  window.HL = { swift, markdownLine, block, esc };
})();
