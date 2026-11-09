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


PREFERRED_DEVICE_PREFIXES = (
    "iPhone 17", "iPhone 16", "iPhone 15", "iPhone 14", "iPhone 13", "iPhone SE")


def choose_device(devices, runtimes, requested="27.0"):
    """優先常見 iPhone 機型；回傳名稱、device type 與明確 runtime，無匹配即失敗。"""
    choices = []
    for runtime in runtimes:
        if not runtime.get("isAvailable") or ".iOS-" not in runtime["identifier"]:
            continue
        if runtime["version"] != requested and runtime["identifier"] != requested:
            continue
        version = tuple(int(part) for part in runtime["version"].split("."))
        for device in devices.get(runtime["identifier"], []):
            name = device.get("name", "")
            if not device.get("isAvailable") or not name.startswith("iPhone") or not device.get("deviceTypeIdentifier"):
                continue
            rank = next((i for i, prefix in enumerate(PREFERRED_DEVICE_PREFIXES) if name.startswith(prefix)),
                        len(PREFERRED_DEVICE_PREFIXES))
            choices.append((rank, name, device["deviceTypeIdentifier"], runtime["identifier"], version))
    if not choices:
        raise RuntimeError("找不到指定 runtime 的可用 iPhone 模擬器")
    _, name, device_type, runtime, _ = min(choices, key=lambda item: (item[0], item[1], item[3]))
    return name, device_type, runtime


def retryable(text):
    """只重試明確的 runner 連線前卡住；已有測試 issue／失敗或編譯錯誤則不重試。"""
    result = parse(text)
    return ("The test runner hung before establishing connection." in text
            and not any(result[key] for key in ("errors", "other_errors", "tests_failed", "suites_failed", "issues"))
            and not ("Test Case" in text and " failed" in text))


def test_failure_reported(text):
    """測試本身失敗（斷言／Swift Testing）不是 runner 啟動失敗。"""
    if "test runner hung before establishing connection" in text:
        return False
    result = parse(text)
    return bool(result["tests_failed"]
                or result["issues"]
                or result["testing_failed"]
                or "** TEST FAILED **" in text
                or ("Test Case '" in text and " failed" in text))


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


class StageFailure(RuntimeError):
    """保留原始失敗階段與退出碼，避免逾時 124 被泛化成 1。"""
    def __init__(self, stage, code):
        self.stage = stage
        self.code = code
        super().__init__(f"stage={stage} exit={code}")


def stage_run(command, timeout, log):
    """保存每階段耗時與退出碼；中繼資料獨立保存，不污染 simctl JSON。"""
    started = time.monotonic()
    try:
        code = run(command, timeout, log)
    except (OSError, subprocess.SubprocessError) as error:
        code = 1
        with log.open("a", encoding="utf-8") as output:
            output.write(f"\n[Runner infrastructure] {error}\n")
    result = {"stage": log.stem, "exit": code,
              "elapsedSeconds": round(time.monotonic() - started, 3), "limitSeconds": timeout}
    log.with_name(log.name + ".status.json").write_text(json.dumps(result), encoding="utf-8")
    print(f"[CI stage] {result}", flush=True)
    return code


def main():
    """建立、啟動、測試與清理本次專用模擬器，保留各次嘗試資料。"""
    parser = argparse.ArgumentParser()
    parser.add_argument("target")
    parser.add_argument("output", type=Path)
    parser.add_argument("--runtime", default=os.environ.get("IOS_TEST_RUNTIME", "27.0"))
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
        device_label = "unselected"
        failed_stage = None
        service_ok = False
        test_log = folder / "test.log"
        try:
            for kind in ("devices", "runtimes"):
                code = stage_run(["xcrun", "simctl", "list", kind, "--json"], 60, folder / f"{kind}.json")
                if code:
                    raise StageFailure(f"list-{kind}", code)
            devices = json.loads((folder / "devices.json").read_text())["devices"]
            runtimes = json.loads((folder / "runtimes.json").read_text())["runtimes"]
            device_name, device_type, runtime = choose_device(devices, runtimes, args.runtime)
            name = f"ci-{args.target}-{uuid.uuid4().hex[:8]}"
            udid = subprocess.check_output(["xcrun", "simctl", "create", name, device_type, runtime], text=True, timeout=90).strip()
            device_label = f"{device_name} ({device_type}) @ {runtime}"
            (folder / "destination.txt").write_text(
                f"name={device_name}\ntype={device_type}\nruntime={runtime}\nUDID={udid}\n", encoding="utf-8")
            print(f"Attempt {attempt}: device={device_name} type={device_type} runtime={runtime} UDID={udid}", flush=True)
            code = stage_run(["xcrun", "simctl", "boot", udid], 120, folder / "boot.log")
            if code:
                raise StageFailure("boot", code)
            for boot_try in (1, 2):
                log_name = "bootstatus.log" if boot_try == 1 else "bootstatus-retry.log"
                code = stage_run(["xcrun", "simctl", "bootstatus", udid, "-b"], 300, folder / log_name)
                if code == 0:
                    break
                if boot_try == 1 and code == 124:
                    print("[CI stage] bootstatus timed out; retrying the same simulator once", flush=True)
                    continue
                raise StageFailure("bootstatus", code)
            common = ["-scheme", "HaishinKit-Package", "-derivedDataPath", str(derived_data),
                      "-destination", f"platform=iOS Simulator,id={udid}",
                      "-destination-timeout", "60", "-parallel-testing-enabled", "NO",
                      f"-only-testing:{args.target}"]
            stage = "build-for-testing"
            if not built:
                print("[CI stage] build-for-testing: limit=1500s", flush=True)
                status = stage_run(["xcodebuild", stage, *common, "-resultBundlePath",
                              str(folder / "Build.xcresult")], 1500, folder / "build.log")
                built = status == 0
            if built:
                stage = "test-without-building"
                print("[CI stage] test-without-building: limit=660s", flush=True)
                status = stage_run(["xcodebuild", stage, *common, "-resultBundlePath",
                              str(folder / "Tests.xcresult")], 660, test_log)
            else:
                test_log.write_text("[CI stage] tests not started: build failed\n", encoding="utf-8")
            if status:
                text = test_log.read_text(encoding="utf-8", errors="replace")
                # xcodebuild 的測試斷言失敗也會回 65；只有沒有測試結果、
                # 真正卡在 runner／逾時才標成 infrastructure。build-for-testing
                # 的非逾時失敗是編譯錯誤，交給 compile summary，不誤標 runner。
                test_failed = stage == "test-without-building" and test_failure_reported(text)
                build_failed = stage == "build-for-testing" and status != 124
                if not (test_failed or build_failed):
                    with test_log.open("a", encoding="utf-8") as output:
                        output.write(f"[Runner infrastructure] stage={stage} exit={status}\n")

        except (RuntimeError, subprocess.SubprocessError, OSError, ValueError, KeyError) as error:
            status = error.code if isinstance(error, StageFailure) else 1
            failed_stage = error.stage if isinstance(error, StageFailure) else "setup"
            with test_log.open("a", encoding="utf-8") as output:
                output.write(f"[Runner infrastructure] {error}\n")
        finally:
            # 查詢本身也可能卡住；服務無回應就不繼續送清理或重試命令。
            service_ok = False
            for _ in range(2):
                if stage_run(["xcrun", "simctl", "list", "devices", "--json"],
                             60, folder / "devices-after.json") == 0:
                    service_ok = True
                    break
                time.sleep(10)
            if udid and service_ok:
                shutdown = stage_run(["xcrun", "simctl", "shutdown", udid], 60, folder / "shutdown.log")
                if shutdown == 124:
                    service_ok = False
                else:
                    service_ok = stage_run(["xcrun", "simctl", "delete", udid], 60, folder / "delete.log") == 0
            if udid and not service_ok:
                with test_log.open("a", encoding="utf-8") as output:
                    output.write(f"[Runner infrastructure] service unavailable or cleanup failed; no retry; retained UDID={udid}\n")

        text = test_log.read_text(encoding="utf-8", errors="replace")
        build_log = folder / "build.log"
        if build_log.exists():
            text = build_log.read_text(encoding="utf-8", errors="replace") + "\n" + text
        if failed_stage:
            for filename in ("boot.log", "bootstatus.log", "devices-after.json"):
                log = folder / filename
                if log.exists():
                    tail = log.read_text(encoding="utf-8", errors="replace").splitlines()[-40:]
                    text += f"\n[CI diagnostic] {filename}\n" + ("\n".join(tail) or "(no output)") + "\n"
        final_log.write_text(text, encoding="utf-8")
        print(text, flush=True)
        attempts.append(f"- Attempt {attempt}: device={device_label}; exit={status}; stage={failed_stage or stage}; serviceResponsive={service_ok}; artifacts: attempt-{attempt}/")
        (args.output / "attempts.md").write_text("\n".join(attempts) + "\n", encoding="utf-8")
        if status == 0 or attempt == 2 or not service_ok or not (failed_stage in ("boot", "bootstatus") or retryable(text) or (status == 124 and built)):
            break
        print("::warning::模擬器／XCTest runner 啟動故障，保留首次資料並以新模擬器重試一次", flush=True)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as output:
            output.write("\n### iOS 模擬器測試嘗試\n\n" + "\n".join(attempts) + "\n")
    return status


if __name__ == "__main__":
    sys.exit(main())




