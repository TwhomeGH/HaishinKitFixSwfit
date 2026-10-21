#!/usr/bin/env python3
"""以獨立模擬器執行 iOS 測試；僅對 runner 連線前卡住重試一次。"""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
import uuid

from ci_test_summary import parse


def choose_device(devices, runtimes):
    """回傳可用 iPhone 的裝置類型與對應最新可用 iOS runtime，無匹配即失敗。"""
    choices = []
    for runtime in runtimes:
        if not runtime.get("isAvailable") or ".iOS-" not in runtime["identifier"]:
            continue
        version = tuple(int(part) for part in runtime["version"].split("."))
        for device in devices.get(runtime["identifier"], []):
            if device.get("isAvailable") and device["name"].startswith("iPhone") and device.get("deviceTypeIdentifier"):
                choices.append((version, runtime["identifier"], device["deviceTypeIdentifier"]))
    if not choices:
        raise RuntimeError("找不到具可用 runtime 的 iPhone 模擬器")
    _, runtime, device_type = max(choices)
    return device_type, runtime


def retryable(text):
    """只重試明確的 runner 連線前卡住；已有測試 issue／失敗或編譯錯誤則不重試。"""
    result = parse(text)
    return ("The test runner hung before establishing connection." in text
            and not any(result[key] for key in ("errors", "other_errors", "tests_failed", "suites_failed", "issues"))
            and not ("Test Case" in text and " failed" in text))


def run(command, timeout, log):
    """有界執行並保存完整輸出；逾時終止該命令程序群，不影響其他 job。"""
    with log.open("w", encoding="utf-8") as output:
        process = subprocess.Popen(command, stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            deadline = time.monotonic() + timeout
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise subprocess.TimeoutExpired(command, timeout)
                try:
                    return process.wait(timeout=min(30, remaining))
                except subprocess.TimeoutExpired:
                    print(f"[CI progress] {log.name}: running; log bytes={log.stat().st_size}", flush=True)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            output.write("\n[Runner infrastructure] command timed out\n")
            return 124


def main():
    """建立、啟動、測試與清理本次專用模擬器，保留各次嘗試資料。"""
    parser = argparse.ArgumentParser()
    parser.add_argument("target")
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    final_log = args.output / "ios-tests.log"
    attempts = []
    # 建置產物放在 artifact 目錄之外；重試只重跑測試，不重編整套 SDK。
    derived_data = args.output.resolve().parent / f"ios-derived-{uuid.uuid4().hex}"
    built = False
    status = 1
    for attempt in (1, 2):
        folder = args.output / f"attempt-{attempt}"
        folder.mkdir(parents=True, exist_ok=True)
        udid = None
        test_log = folder / "test.log"
        try:
            for kind in ("devices", "runtimes"):
                code = run(["xcrun", "simctl", "list", kind, "--json"], 30, folder / f"{kind}.json")
                if code:
                    raise RuntimeError(f"simctl list {kind} failed: {code}")
            devices = json.loads((folder / "devices.json").read_text())["devices"]
            runtimes = json.loads((folder / "runtimes.json").read_text())["runtimes"]
            device_type, runtime = choose_device(devices, runtimes)
            name = f"ci-{args.target}-{uuid.uuid4().hex[:8]}"
            udid = subprocess.check_output(["xcrun", "simctl", "create", name, device_type, runtime], text=True, timeout=30).strip()
            (folder / "destination.txt").write_text(f"UDID={udid}\nruntime={runtime}\n", encoding="utf-8")
            print(f"Attempt {attempt}: {runtime}, UDID={udid}", flush=True)
            if run(["xcrun", "simctl", "boot", udid], 60, folder / "boot.log"):
                raise RuntimeError("simulator boot failed")
            if run(["xcrun", "simctl", "bootstatus", udid, "-b"], 180, folder / "bootstatus.log"):
                raise RuntimeError("simulator bootstatus failed or timed out")
            common = ["-scheme", "HaishinKit-Package", "-derivedDataPath", str(derived_data),
                      "-destination", f"platform=iOS Simulator,id={udid}",
                      "-destination-timeout", "60", "-parallel-testing-enabled", "NO",
                      f"-only-testing:{args.target}"]
            stage = "build-for-testing"
            if not built:
                print("[CI stage] build-for-testing: limit=1500s", flush=True)
                status = run(["xcodebuild", stage, *common, "-resultBundlePath",
                              str(folder / "Build.xcresult")], 1500, folder / "build.log")
                built = status == 0
            if built:
                stage = "test-without-building"
                print("[CI stage] test-without-building: limit=660s", flush=True)
                status = run(["xcodebuild", stage, *common, "-resultBundlePath",
                              str(folder / "Tests.xcresult")], 660, test_log)
            else:
                test_log.write_text("[CI stage] tests not started: build failed\n", encoding="utf-8")
            if status:
                with test_log.open("a", encoding="utf-8") as output:
                    output.write(f"[Runner infrastructure] stage={stage} exit={status}\n")

        except (RuntimeError, subprocess.SubprocessError, OSError, ValueError, KeyError) as error:
            status = 1
            with test_log.open("a", encoding="utf-8") as output:
                output.write(f"[Runner infrastructure] {error}\n")
        finally:
            run(["xcrun", "simctl", "list", "devices", "--json"], 30, folder / "devices-after.json")
            if udid:
                run(["xcrun", "simctl", "shutdown", udid], 30, folder / "shutdown.log")
                run(["xcrun", "simctl", "delete", udid], 30, folder / "delete.log")
        text = test_log.read_text(encoding="utf-8", errors="replace")
        build_log = folder / "build.log"
        if build_log.exists():
            text = build_log.read_text(encoding="utf-8", errors="replace") + "\n" + text
        final_log.write_text(text, encoding="utf-8")
        print(text, flush=True)
        attempts.append(f"- Attempt {attempt}: exit={status}; artifacts: attempt-{attempt}/")
        (args.output / "attempts.md").write_text("\n".join(attempts) + "\n", encoding="utf-8")
        if status == 0 or attempt == 2 or not retryable(text):
            break
        print("::warning::XCTest runner 啟動故障，保留首次資料並以新模擬器重試一次", flush=True)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as output:
            output.write("\n### iOS 模擬器測試嘗試\n\n" + "\n".join(attempts) + "\n")
    return status


if __name__ == "__main__":
    sys.exit(main())
