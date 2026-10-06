"""開發索引：唯讀 Git／文件／API 宣告索引與檔案檢視。

提供 API 宣告定位（純文字掃描 Swift，非 AST）、Markdown 文件內容、近期 Git
改動與鎖定套件；不推測語意。所有 HTTP 回應皆由 :func:`route` 產生，供本機
伺服器轉接；頁面資產（HTML／CSS／JS）由 :mod:`changelog.assets` 載入。

用途：快速查閱 API（名稱／簽名／`///` 註釋／file:line）、瀏覽文件、追蹤近期
改動與鎖定版本，全部在本機服務端完成。
"""

import html
import json
import re
import subprocess
from pathlib import Path
from urllib.parse import parse_qs, urlencode

from . import assets

# 專案根目錄（Tools/changelog/devindex.py → 往上兩層）。
ROOT = Path(__file__).resolve().parents[2]
# 可選的功能清單（存在才啟用「功能與接入」分頁）。
CATALOG = ROOT / "Docs" / "development" / "features.json"


def roots():
    """索引來源；目前只有本 repo（如需外部 checkout 再擴充）。"""
    return {"haishinkit": ROOT}


def git(root, *args):
    """固定參數呼叫 Git；不透過 shell，失敗明確回報。"""
    result = subprocess.run(["git", "-C", str(root), *args], capture_output=True,
                            encoding="utf-8", errors="replace", timeout=30)
    if result.returncode:
        raise ValueError("無法讀取 Git 資訊：" + result.stderr[:200])
    return result.stdout


def files(root):
    """只索引版本控管或未忽略的 Swift／Markdown，略過隱藏設定與產物。"""
    paths = git(root, "ls-files", "--cached", "--others", "--exclude-standard", "-z").split("\0")
    return sorted({p for p in paths if p and Path(p).suffix in (".swift", ".md")
                   and not any(part.startswith(".") for part in Path(p).parts)})


def safe_file(repo, name):
    """檔案檢視僅允許索引內檔案，並阻擋路徑穿越及連到根目錄外的 symlink。"""
    root = roots().get(repo)
    if root is None or name not in files(root):
        raise ValueError("檔案不在索引範圍")
    path = (root / name).resolve()
    if not path.is_relative_to(root.resolve()) or not path.is_file() or path.stat().st_size > 2_000_000:
        raise ValueError("檔案不可讀取或超過 2 MB")
    return path


def link(repo, path, line=1):
    """檔案內某行的站內連結（以 hash 指向行號，不需重載）。"""
    return "/development/file?" + urlencode({"repo": repo, "path": path}) + "#L" + str(line)


def validate():
    """驗證功能清單（若存在）：穩定 ID、必要欄位與檔案連結。"""
    if not CATALOG.exists():
        return []
    catalog = json.loads(CATALOG.read_text(encoding="utf-8"))
    seen = set()
    for feature in catalog:
        for field in ("id", "name", "summary", "files", "docs"):
            if not feature.get(field):
                raise ValueError("功能缺少欄位：" + field)
        if feature["id"] in seen:
            raise ValueError("重複功能 ID")
        seen.add(feature["id"])
        for name in feature["files"] + feature["docs"]:
            safe_file("haishinkit", name)
    return catalog


# 宣告掃描用的詞彙（純文字比對，非 Swift AST）。
_ACCESS = r"(?:public|private|internal|fileprivate|open|package)"
_MODIFIERS = (r"(?:public|private|internal|fileprivate|open|package|final|static|class|"
              r"nonisolated|override|mutating|convenience|required|dynamic|lazy|weak|unowned|indirect)")

# 函式／型別／擴充等一定會收錄。
_DECL_RE = re.compile(
    r"^\s*(?:" + _MODIFIERS + r"\s+)*(?:" + _ACCESS + r"\s+)?"
    r"(func|struct|class|enum|protocol|actor|extension|typealias|init|subscript)\b")
# 屬性只在本行具存取修飾詞時收錄，避免把函式內的區域 var/let 當成 API。
_PROP_RE = re.compile(
    r"^\s*(?:" + _MODIFIERS + r"\s+)*" + _ACCESS + r"\s*"
    r"(?:\([^)]*\)\s*)?"  # 例如 private(set)
    r"(var|let)\b")
_NAME_RE = re.compile(
    r"\b(?:func|struct|class|enum|protocol|actor|extension|typealias|var|let)\s+"
    r"([A-Za-z_][A-Za-z0-9_.]*)")
_KIND_OF_KEYWORD = {
    "func": "func", "struct": "struct", "class": "class", "enum": "enum",
    "protocol": "protocol", "actor": "actor", "extension": "extension",
    "typealias": "typealias", "init": "init", "subscript": "subscript",
    "var": "property", "let": "property",
}


def _decl_keyword(line):
    """行首是否為宣告；回傳關鍵字（func／struct／var…）或 None。"""
    match = _DECL_RE.match(line) or _PROP_RE.match(line)
    return match.group(1) if match else None


def _collect_signature(lines, start):
    """從 start 行往下收集到括號收合，回傳 (簽名, 下一行索引)，用於呈現多行簽名。"""
    parts = []
    depth = 0
    for index in range(start, min(start + 30, len(lines))):
        line = lines[index]
        parts.append(line.strip())
        depth += line.count("(") - line.count(")") + line.count("[") - line.count("]")
        if depth <= 0:
            return " ".join(part for part in parts if part), index + 1
    return " ".join(part for part in parts if part), min(start + 30, len(lines))


def _symbol_name(keyword, signature):
    """從簽名取出可讀名稱（init／subscript 直接回關鍵字）。"""
    if keyword in ("init", "subscript"):
        return keyword
    match = _NAME_RE.search(signature)
    return match.group(1) if match else ""


def scan_symbols(text, repo, name):
    """掃描相鄰 /// 文件註釋與宣告，回傳符號清單（含種類、名稱、多行簽名）。

    註釋與宣告之間允許屬性（@…）與條件編譯（#…）行；其餘非空行視為中斷註釋。
    """
    lines = text.splitlines()
    symbols = []
    doc = []
    index = 0
    while index < len(lines):
        stripped = lines[index].strip()
        if stripped.startswith("///"):
            doc.append(stripped[3:].strip())
            index += 1
            continue
        keyword = _decl_keyword(stripped)
        if keyword:
            signature, following = _collect_signature(lines, index)
            body = signature.split("{", 1)[0].strip()
            if keyword in ("var", "let", "typealias"):
                body = body.split("=", 1)[0].strip()
            symbols.append({
                "name": _symbol_name(keyword, body) or body, "signature": body,
                "kind": _KIND_OF_KEYWORD[keyword], "repo": repo, "file": name,
                "line": index + 1, "comment": "\n".join(doc).strip(),
                "url": link(repo, name, index + 1),
            })
            doc = []
            index = following
            continue
        if stripped and not stripped.startswith(("@", "#", "//")):
            doc = []
        index += 1
    return symbols


def _locked_packages():
    """Package.resolved 的鎖定套件（v1 為 object.pins，v2/v3 為頂層 pins）。"""
    try:
        lock = json.loads((ROOT / "Package.resolved").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return []
    pins = lock.get("pins") or lock.get("object", {}).get("pins", [])
    return [{"identity": p.get("identity"), "revision": (p.get("state") or {}).get("revision")}
            for p in pins]


def snapshot():
    """即時取得版本、近期提交、符號與文件；不把 Git 修改檔案推測成新增功能。"""
    data = {"features": validate(), "repos": [], "symbols": [], "documents": []}
    for repo, root in roots().items():
        data["repos"].append({
            "name": repo,
            "head": git(root, "rev-parse", "HEAD").strip(),
            "changes": git(root, "status", "--short"),
            "commits": git(root, "log", "-20", "--date=iso-strict", "--format=%h %ad %s", "--name-only"),
        })
        for name in files(root):
            try:
                path = (root / name).resolve()
                if not path.is_relative_to(root.resolve()) or path.stat().st_size > 2_000_000:
                    continue
                text = path.read_text(encoding="utf-8", errors="replace")
            except (ValueError, OSError):
                continue
            if name.endswith(".md"):
                data["documents"].append({"name": name, "repo": repo, "url": link(repo, name),
                                          "text": text[:100000]})
                continue
            data["symbols"].extend(scan_symbols(text, repo, name))
    data["lockedPackages"] = _locked_packages()
    return data


def _file_page(repo, name, line):
    """組出檔案檢視頁（含行號、目標行與語法上色用的 .code 容器）。"""
    source = safe_file(repo, name).read_text(encoding="utf-8", errors="replace")
    content = "".join(
        '<span class="ln" id="L%d"><a class="no" href="#L%d">%5d</a>'
        '<span class="code">%s</span></span>' % (i, i, i, html.escape(text))
        for i, text in enumerate(source.splitlines(), 1)
    )
    return assets.render(
        "file.html",
        title=html.escape(name), repo=html.escape(repo), path=html.escape(name),
        line=str(line), content=content)


def route(path, query):
    """回傳 (HTTP 狀態, 內容, MIME)，由本機伺服器提供服務。"""
    try:
        if path in ("/development", "/development/"):
            return 200, assets.read("dev.html"), "text/html; charset=utf-8"
        if path == "/development/data":
            return 200, json.dumps(snapshot(), ensure_ascii=False), "application/json; charset=utf-8"
        if path == "/development/file":
            values = parse_qs(query)
            repo = values.get("repo", ["haishinkit"])[0]
            name = values.get("path", [""])[0]
            line_arg = values.get("line", [""])[0]
            line = int(line_arg) if line_arg.isdigit() else 0
            return 200, _file_page(repo, name, line), "text/html; charset=utf-8"
    except (ValueError, OSError, subprocess.TimeoutExpired) as error:
        return 400, json.dumps({"error": str(error)}, ensure_ascii=False), "application/json; charset=utf-8"
    return 404, "找不到頁面", "text/plain; charset=utf-8"


if __name__ == "__main__":
    print("開發索引驗證通過：", len(validate()), "項功能清單")
