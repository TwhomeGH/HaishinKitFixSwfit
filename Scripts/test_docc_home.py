"""首頁產生與版本資訊的回歸檢查。"""
import json
from pathlib import Path
import tempfile
import unittest
from build_docc_home import build, render, MODULES

INFO = dict(revision="a" * 40, repository="owner/repo", ref="main<script>", tags=[],
            dirty=False, builtAt="2026-10-06T00:00:00+00:00", runURL=None)

class HomeTests(unittest.TestCase):
    def test_escape_and_revision(self):
        page = render(INFO)
        self.assertIn("a" * 40, page)
        self.assertNotIn("main<script>", page)
        self.assertIn("main&lt;script&gt;", page)
        self.assertNotIn("@@", page)
        self.assertNotIn('href="None"', page)

    def test_missing_module_fails_without_home(self):
        with tempfile.TemporaryDirectory() as folder:
            site = Path(folder)
            with self.assertRaises(ValueError):
                build(site, INFO)
            self.assertFalse((site / "index.html").exists())

    def test_valid_site_and_metadata(self):
        with tempfile.TemporaryDirectory() as folder:
            site = Path(folder)
            for module, slug in MODULES.items():
                path = site / module / "data/documentation"
                path.mkdir(parents=True)
                (path / (slug + ".json")).write_text("{}")
                (site / module / "index.html").write_text("preview")
            build(site, INFO)
            self.assertEqual(json.loads((site / "build-info.json").read_text())["revision"], INFO["revision"])
            self.assertEqual((site / "revision.txt").read_text().strip(), INFO["revision"])

if __name__ == "__main__":
    unittest.main()
