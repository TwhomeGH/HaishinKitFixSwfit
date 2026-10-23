"""驗證模擬器選取與有限重試政策；不需要本機安裝 Xcode。"""
import unittest
import tempfile
import json
from pathlib import Path
from unittest.mock import patch
import run_ios_tests
from run_ios_tests import choose_device, retryable
from ci_test_summary import parse, render_markdown

HUNG = "Testing failed:\n xctest encountered an error (The test runner hung before establishing connection.)\n** TEST FAILED **"

class RunnerTests(unittest.TestCase):
    def test_only_runner_hang_is_retryable(self):
        self.assertTrue(retryable(HUNG))
        self.assertFalse(retryable("error: compile failed"))
        self.assertFalse(retryable("[Runner infrastructure] boot failed"))

    def test_assertion_failure_prevents_retry(self):
        self.assertFalse(retryable('✘ Test "example" failed after 1 second.\n' + HUNG))
        self.assertFalse(retryable('✘ Test "example" recorded an issue\n' + HUNG))
        self.assertFalse(retryable("Test Case '-[Example testOne]' failed (1 seconds).\n" + HUNG))
        self.assertFalse(retryable("/tmp/a.swift:1:2: error: bad type\n" + HUNG))

    def test_hang_has_separate_summary(self):
        result = parse(HUNG)
        self.assertEqual(len(result["runner_errors"]), 1)
        self.assertEqual(result["errors"], [])
        self.assertIn("Runner／環境失敗 | 1", render_markdown(result))
        self.assertIn("❌ 失敗", render_markdown(result))

    def test_retry_retains_attempts_and_uses_new_device(self):
        with tempfile.TemporaryDirectory() as directory:
            calls = []
            def fake_run(command, timeout, log):
                calls.append(command)
                if command[:4] == ["xcrun", "simctl", "list", "devices"]:
                    content = json.dumps({"devices": {"com.apple.iOS-27": [{"name": "iPhone", "isAvailable": True, "deviceTypeIdentifier": "phone"}]}})
                elif command[:4] == ["xcrun", "simctl", "list", "runtimes"]:
                    content = json.dumps({"runtimes": [{"identifier": "com.apple.iOS-27", "version": "27.0", "isAvailable": True}]})
                elif command[:2] == ["xcodebuild", "test-without-building"]:
                    content = HUNG if log.parent.name == "attempt-1" else "✔ Test example passed after 1 second."
                else:
                    content = "ok"
                log.write_text(content, encoding="utf-8")
                return 65 if content == HUNG else 0
            with patch.object(run_ios_tests, "run", side_effect=fake_run), \
                 patch.object(run_ios_tests.subprocess, "check_output", side_effect=["UUID-A", "UUID-B"]), \
                 patch("sys.argv", ["runner", "ExampleTests", directory]), \
                 patch.dict("os.environ", {}, clear=True), patch("builtins.print"):
                self.assertEqual(run_ios_tests.main(), 0)
            root = Path(directory)
            self.assertIn(HUNG, (root / "attempt-1/test.log").read_text(encoding="utf-8"))
            self.assertIn("passed", (root / "ios-tests.log").read_text(encoding="utf-8"))
            self.assertTrue((root / "attempt-2/destination.txt").exists())
            builds = [c for c in calls if c[:2] == ["xcodebuild", "build-for-testing"]]
            tests = [c for c in calls if c[:2] == ["xcodebuild", "test-without-building"]]
            self.assertEqual(len(builds), 1)
            self.assertEqual(len(tests), 2)
            self.assertEqual(builds[0][builds[0].index("-derivedDataPath") + 1],
                             tests[1][tests[1].index("-derivedDataPath") + 1])
            deleted = [c[-1] for c in calls if c[:3] == ["xcrun", "simctl", "delete"]]
            self.assertEqual(deleted, ["UUID-A", "UUID-B"])

    def test_build_timeout_does_not_start_or_retry_tests(self):
        with tempfile.TemporaryDirectory() as directory:
            commands = []
            def fake_run(command, timeout, log):
                commands.append(command)
                if command[:4] == ["xcrun", "simctl", "list", "devices"]:
                    content = json.dumps({"devices": {"com.apple.iOS-27": [{"name": "iPhone", "isAvailable": True, "deviceTypeIdentifier": "phone"}]}})
                elif command[:4] == ["xcrun", "simctl", "list", "runtimes"]:
                    content = json.dumps({"runtimes": [{"identifier": "com.apple.iOS-27", "version": "27.0", "isAvailable": True}]})
                else:
                    content = "** BUILD INTERRUPTED **" if command[0] == "xcodebuild" else "ok"
                log.write_text(content, encoding="utf-8")
                return 124 if command[0] == "xcodebuild" else 0
            with patch.object(run_ios_tests, "run", side_effect=fake_run), \
                 patch.object(run_ios_tests.subprocess, "check_output", return_value="UUID-A"), \
                 patch("sys.argv", ["runner", "ExampleTests", directory]), \
                 patch.dict("os.environ", {}, clear=True), patch("builtins.print"):
                self.assertEqual(run_ios_tests.main(), 124)
            text = (Path(directory) / "ios-tests.log").read_text(encoding="utf-8")
            self.assertIn("stage=build-for-testing exit=124", text)
            self.assertIn("tests not started", text)
            self.assertEqual(len([c for c in commands if c[0] == "xcodebuild"]), 1)
            self.assertFalse((Path(directory) / "attempt-2").exists())

    def test_boot_timeout_retries_only_when_service_responds(self):
        for responsive in (True, False):
            with self.subTest(responsive=responsive), tempfile.TemporaryDirectory() as directory:
                calls = []
                def fake_run(command, timeout, log):
                    calls.append(command)
                    code = 0
                    if command[:4] == ["xcrun", "simctl", "list", "devices"]:
                        content = json.dumps({"devices": {"com.apple.iOS-27": [{"name": "iPhone", "isAvailable": True, "deviceTypeIdentifier": "phone"}]}})
                        if log.name == "devices-after.json" and not responsive:
                            code = 124
                    elif command[:4] == ["xcrun", "simctl", "list", "runtimes"]:
                        content = json.dumps({"runtimes": [{"identifier": "com.apple.iOS-27", "version": "27.0", "isAvailable": True}]})
                    else:
                        content = "ok"
                    if log.name == "bootstatus.log" and log.parent.name == "attempt-1":
                        content = "waiting for simulator services"
                        code = 124
                    log.write_text(content, encoding="utf-8")
                    return code
                with patch.object(run_ios_tests, "run", side_effect=fake_run), \
                     patch.object(run_ios_tests.subprocess, "check_output", side_effect=["UUID-A", "UUID-B"]) as create, \
                     patch("sys.argv", ["runner", "ExampleTests", directory]), \
                     patch.dict("os.environ", {}, clear=True), patch("builtins.print"):
                    self.assertEqual(run_ios_tests.main(), 0 if responsive else 124)
                self.assertEqual(create.call_count, 2 if responsive else 1)
                root = Path(directory)
                metadata = json.loads((root / "attempt-1/bootstatus.log.status.json").read_text())
                self.assertEqual(metadata["exit"], 124)
                self.assertEqual(metadata["limitSeconds"], 180)
                if not responsive:
                    text = (root / "ios-tests.log").read_text()
                    self.assertIn("stage=bootstatus exit=124", text)
                    self.assertIn("waiting for simulator services", text)
                    self.assertFalse(any(c[2] in ("shutdown", "delete") for c in calls if c[0] == "xcrun"))

    def test_runtime_does_not_silently_upgrade(self):
        runtimes = [{"identifier": "com.apple.iOS-27-1", "version": "27.1", "isAvailable": True}]
        devices = {"com.apple.iOS-27-1": [{"name": "iPhone", "isAvailable": True, "deviceTypeIdentifier": "phone"}]}
        with self.assertRaises(RuntimeError):
            choose_device(devices, runtimes)
        self.assertEqual(choose_device(devices, runtimes, "27.1"), ("phone", "com.apple.iOS-27-1"))

    def test_selects_matching_available_runtime(self):
        runtimes = [{"identifier": "com.apple.iOS-27", "version": "27.0", "isAvailable": True},
                    {"identifier": "com.apple.iOS-28", "version": "28.0", "isAvailable": False}]
        devices = {"com.apple.iOS-27": [{"name": "iPhone 17", "isAvailable": True, "deviceTypeIdentifier": "phone"}]}
        self.assertEqual(choose_device(devices, runtimes), ("phone", "com.apple.iOS-27"))
        with self.assertRaises(RuntimeError):
            choose_device({}, runtimes)

if __name__ == "__main__":
    unittest.main()
