"""驗證 verify harness runner 的清單與孤兒檢查；不需要 Swift 工具鏈。"""
import unittest

import run_verify_harnesses


class VerifyHarnessManifestTests(unittest.TestCase):
    def test_all_sources_exist(self):
        for name, sources in run_verify_harnesses.HARNESSES.items():
            for source in sources:
                path = run_verify_harnesses.ROOT / source
                self.assertTrue(path.is_file(), f"{name}: missing {source}")

    def test_every_verify_script_is_listed(self):
        self.assertEqual(
            run_verify_harnesses.discover_harnesses(),
            run_verify_harnesses.listed_harnesses())

    def test_names_are_unique_non_empty(self):
        names = list(run_verify_harnesses.HARNESSES)
        self.assertTrue(names)
        self.assertEqual(len(names), len(set(names)))


if __name__ == "__main__":
    unittest.main()
