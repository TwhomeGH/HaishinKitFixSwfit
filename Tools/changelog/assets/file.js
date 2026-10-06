/* 檔案檢視：行號、行跳轉、目標行高亮；Swift 上色；Markdown 預設排版檢視（可切回原始碼）。 */
(function () {
  const src = document.getElementById("src");
  if (!src) return;
  const rendered = document.getElementById("rendered");
  const modeBtn = document.getElementById("mode");
  const jump = document.getElementById("jump");
  const isMarkdown = /\.(md|markdown)$/i.test(src.dataset.path || "");

  // 1) 原始碼逐行上色（Markdown 也用於「原始碼」模式）。
  const state = { block: false };
  src.querySelectorAll(".code").forEach((el) => {
    el.innerHTML = isMarkdown ? HL.markdownLine(el.textContent) : HL.swift(el.textContent, state);
  });

  const lines = src.querySelectorAll(".ln");
  const total = lines.length;
  const initial = parseInt(src.dataset.line || "0", 10);

  function highlight(line) {
    if (!(line >= 1 && line <= total)) return;
    src.querySelectorAll(".ln.hit").forEach((el) => el.classList.remove("hit"));
    const el = document.getElementById("L" + line);
    if (el) { el.classList.add("hit"); el.scrollIntoView({ block: "center" }); }
  }
  function fromHash() {
    const m = (location.hash || "").match(/^#L(\d+)$/);
    return m ? parseInt(m[1], 10) : initial;
  }
  function go(line, push) {
    if (!(line >= 1 && line <= total)) return;
    if (push) history.replaceState(null, "", "#L" + line);
    highlight(line);
  }

  src.addEventListener("click", (e) => {
    const a = e.target.closest ? e.target.closest("a.no") : null;
    const href = a && a.getAttribute("href");
    if (href && href.indexOf("#L") === 0) { e.preventDefault(); go(parseInt(href.slice(2), 10), true); }
  });

  if (jump) {
    jump.max = total;
    jump.addEventListener("keydown", (e) => {
      if (e.key === "Enter") { e.preventDefault(); go(parseInt(jump.value, 10), true); }
    });
  }

  document.getElementById("copy")?.addEventListener("click", async (e) => {
    const path = src.dataset.path || "";
    try { await navigator.clipboard.writeText(path); e.currentTarget.textContent = "已複製"; }
    catch { e.currentTarget.textContent = path; }
    setTimeout(() => { e.currentTarget.textContent = "複製路徑"; }, 1500);
  });

  document.getElementById("back")?.addEventListener("click", (e) => {
    if (history.length > 1) { e.preventDefault(); history.back(); }
  });

  window.addEventListener("hashchange", () => { if (!src.hidden) highlight(fromHash()); });

  // 2) Markdown：排版檢視（預設）＋可切回原始碼。
  function resolveHref(href) {
    if (/^[a-z][a-z0-9+.-]*:/i.test(href) || href.startsWith("#") || href.startsWith("/")) return href;
    const repo = src.dataset.repo || "app";
    const [clean, ...rest] = href.split("#");
    const base = (src.dataset.path || "").split("/").slice(0, -1);
    for (const seg of clean.split("/")) {
      if (seg === "" || seg === ".") continue;
      if (seg === "..") { base.pop(); continue; }
      base.push(seg);
    }
    const anchor = rest.length ? "#" + rest.join("#") : "";
    return "/development/file?" + new URLSearchParams({ repo, path: base.join("/") }).toString() + anchor;
  }

  function setMode(mode) {
    const renderedMode = mode === "rendered";
    src.hidden = renderedMode;
    if (rendered) rendered.hidden = !renderedMode;
    if (jump) jump.hidden = renderedMode;
    if (modeBtn) modeBtn.textContent = renderedMode ? "原始碼" : "排版";
  }

  if (isMarkdown && rendered && modeBtn) {
    const raw = Array.from(src.querySelectorAll(".code")).map((el) => el.textContent).join("\n");
    rendered.innerHTML = window.renderMarkdown(raw, resolveHref);
    // 文件內的 #L 行號連結：切回原始碼模式再跳行（就地，不重載）。
    rendered.addEventListener("click", (e) => {
      const a = e.target.closest ? e.target.closest("a") : null;
      const href = a && a.getAttribute("href");
      if (href && href.startsWith("#L")) { e.preventDefault(); setMode("source"); go(parseInt(href.slice(2), 10), true); }
    });
    modeBtn.hidden = false;
    let mode = "rendered";
    setMode(mode);
    modeBtn.addEventListener("click", () => { mode = mode === "rendered" ? "source" : "rendered"; setMode(mode); });
  } else {
    highlight(fromHash());
  }
})();
