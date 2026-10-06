"""本機開發索引工具（模組化）。

* :mod:`changelog.devindex` — 唯讀 Git／文件／API 宣告索引與檔案檢視
* :mod:`changelog.assets`   — 網頁資產（HTML／CSS／JS）載入

用法：

* ``python Tools/dev_index.py``           啟動開發索引（獨立伺服器）。
* ``python Tools/change_log.py``          變更歷史 GUI，同時在 ``/development``
  提供開發索引（同一台伺服器）。
"""

__all__ = ["assets", "devindex"]
