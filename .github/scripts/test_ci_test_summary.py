import unittest
from ci_test_summary import parse, render_markdown

class SummaryTests(unittest.TestCase):
    def test_preserves_issue_and_separates_run_and_xctest(self):
        text = '''✘ Test "S0S1" recorded an issue at TimeoutTests.swift:143:27: Expectation failed
↳ 未進入預期握手階段
error=connectionTimedOut
server:
client: TCP connecting
✘ Test "S0S1" failed after 15 seconds with 1 issue.
✔ Test "S2" passed after 2 seconds.
✘ Test run with 2 tests failed after 17 seconds with 1 issue.
Executed 0 tests, with 0 failures in 0 seconds
'''
        result = parse(text)
        self.assertEqual(result["tests_failed"], ['"S0S1"'])
        self.assertEqual(result["tests_passed"], ['"S2"'])
        self.assertEqual(result["verdict"], "failed")
        self.assertIn("error=connectionTimedOut", result["issues"][0])
        page = render_markdown(result)
        self.assertIn("不含 Swift Testing", page)
        self.assertIn("❌ 失敗", page)

    def test_run_failure_without_individual_result_is_not_success(self):
        result = parse("✘ Test run with 1 test failed after 1 second.")
        self.assertEqual(result["tests_failed"], [])
        self.assertIn("❌ 失敗", render_markdown(result))

if __name__ == "__main__":
    unittest.main()
