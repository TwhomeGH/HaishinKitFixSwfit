#!/usr/bin/env python3
"""開發索引本機伺服器：API 宣告查閱、文件、近期改動與檔案檢視。

  python Tools/dev_index.py [--port 8711] [--no-browser]

開發索引頁面為 ``/``（等同 ``/development``）；檔案檢視為
``/development/file?repo=haishinkit&path=...``。變更歷史 GUI 為另一支工具
``Tools/change_log.py``（其伺服器亦在 ``/development`` 提供本索引）。
"""

import argparse
import sys
import threading
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

# 讓 Tools/ 下的 changelog 套件可被 import。
sys.path.insert(0, str(Path(__file__).resolve().parent))

from changelog import assets, devindex  # noqa: E402


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        """靜音：避免每個請求都印到終端機。"""
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
        if u.path.startswith("/assets/"):
            name = u.path[len("/assets/"):]
            try:
                return self._send(200, assets.read(name), assets.mime(name))
            except (ValueError, OSError):
                return self._send(404, b"", "text/plain; charset=utf-8")
        if u.path in ("/", "/development", "/development/"):
            return self._send(200, assets.read("dev.html"), "text/html; charset=utf-8")
        if u.path == "/favicon.ico":
            return self._send(204, b"")
        if u.path.startswith("/development"):
            return self._send(*devindex.route(u.path, u.query))
        return self._send(404, "找不到頁面", "text/plain; charset=utf-8")


class _Server(ThreadingHTTPServer):
    # Windows 上 allow_reuse_address=1 會讓第二個實例搶綁同一埠；關掉，綁不到就換埠。
    allow_reuse_address = False


def serve(port=8711, open_browser=True):
    try:
        httpd = _Server(("127.0.0.1", port), Handler)
    except OSError:
        httpd = _Server(("127.0.0.1", 0), Handler)
    url = "http://127.0.0.1:%d/" % httpd.server_address[1]
    print("開發索引: %s" % url)
    print("（Ctrl+C 結束）")
    if open_browser:
        threading.Timer(0.4, lambda: webbrowser.open(url)).start()
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nbye")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8711)
    parser.add_argument("--no-browser", action="store_true")
    args = parser.parse_args()
    serve(args.port, not args.no_browser)
