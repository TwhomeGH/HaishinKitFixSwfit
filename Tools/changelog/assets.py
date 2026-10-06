"""網頁資產（HTML／CSS／JS）載入。

資產放在套件內的 ``changelog/assets/``，與 Python 邏輯分離，方便直接編輯
樣式與版面而不必動程式。``render`` 提供極簡的 ``{{key}}`` 佔位替換，足以
套用檔案檢視頁這種少量動態內容。
"""

from pathlib import Path

ASSETS = Path(__file__).resolve().parent / "assets"

_MIME = {
    ".html": "text/html; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".js": "application/javascript; charset=utf-8",
}


def path(name):
    """回傳資產檔的絕對路徑；僅允許 assets/ 底下的單層檔名（阻擋路徑穿越）。"""
    if not name or "/" in name or "\\" in name or name.startswith("."):
        raise ValueError("不允許的資產名稱")
    p = (ASSETS / name).resolve()
    if not p.is_relative_to(ASSETS.resolve()) or not p.is_file():
        raise ValueError("找不到資產")
    return p


def read(name):
    """讀取資產全文。"""
    return path(name).read_text(encoding="utf-8")


def mime(name):
    """依副檔名回傳 Content-Type。"""
    return _MIME.get(Path(name).suffix, "application/octet-stream")


def render(name, **subs):
    """讀取模板並以 ``{{key}}`` 佔位替換。"""
    text = read(name)
    for key, value in subs.items():
        text = text.replace("{{" + key + "}}", value)
    return text
