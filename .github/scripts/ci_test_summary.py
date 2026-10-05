#!/usr/bin/env python3
"""Summarize an xcodebuild / Swift Testing log for CI.

Zero-dependency. Extracts compile errors, warnings (grouped) and Swift Testing
results, then prints:

  * a colourised, collapsible console summary (GitHub Actions renders ANSI and
    the ``::group::`` / ``::error::`` workflow commands), and
  * optionally a Markdown summary written to ``$GITHUB_STEP_SUMMARY`` and/or a
    file.

Usage:
    python3 .github/scripts/ci_test_summary.py TestResults/tests.log \
        --markdown TestResults/summary.md --github-summary
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from collections import OrderedDict

# Make console output UTF-8 so emoji/box glyphs do not crash on non-UTF-8
# terminals (e.g. Windows cp950); CI is UTF-8 already.
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

# --- colour helpers ---------------------------------------------------------

_ANSI = {
    "reset": "\033[0m", "bold": "\033[1m", "dim": "\033[2m",
    "red": "\033[31m", "green": "\033[32m", "yellow": "\033[33m",
    "cyan": "\033[36m", "magenta": "\033[35m", "blue": "\033[34m",
}
_COLOR = sys.stdout.isatty() or bool(os.environ.get("GITHUB_ACTIONS"))


def col(text: str, *styles: str) -> str:
    if not _COLOR:
        return text
    return "".join(_ANSI.get(s, "") for s in styles) + text + _ANSI["reset"]


def console_group(title: str) -> None:
    print(f"::group::{title}")


def console_endgroup() -> None:
    print("::endgroup::")


# --- parsing ----------------------------------------------------------------

LOC_RE = re.compile(
    r"^(?P<path>.+?):(?P<line>\d+):(?P<col>\d+):\s+(?P<kind>error|warning):\s+(?P<msg>.+)$"
)
ANY_ERR_RE = re.compile(r"\berror:\s")
ANY_WARN_RE = re.compile(r"\bwarning:\s")

TEST_START = re.compile(r"◇\s+Test\s+(.+?)\s+started")
TEST_PASS = re.compile(r"[✔✓]\s+Test\s+(.+?)\s+passed")
TEST_FAIL = re.compile(r"[✘✗]\s+Test\s+(.+?)\s+failed")
SUITE_PASS = re.compile(r"✔\s+Suite\s+(.+?)\s+passed")
SUITE_FAIL = re.compile(r"✘\s+Suite\s+(.+?)\s+failed")
RUN_DONE = re.compile(r"Test run with \d+ tests?.*?(passed|failed)")
EXECUTED = re.compile(r"Executed \d+ tests?, with \d+ failures")
TESTING_FAILED = re.compile(r"^\s*(?:Testing failed:|The following build commands failed:)")


class Finding:
    __slots__ = ("path", "line", "msg")

    def __init__(self, path: str, line: str, msg: str) -> None:
        self.path, self.line, self.msg = path, line, msg


def parse(log_text: str):
    errors: list[Finding] = []
    other_errors: list[str] = []
    warnings: "OrderedDict[str, dict]" = OrderedDict()
    tests_passed: list[str] = []
    tests_failed: list[str] = []
    suites_failed: list[str] = []
    verdict: str | None = None
    exec_line: str | None = None
    testing_failed_block: list[str] = []

    lines = log_text.splitlines()
    in_failed_block = False
    for raw_line in lines:
        line = raw_line.rstrip()
        if TESTING_FAILED.match(line):
            in_failed_block = True
            testing_failed_block.append(line.strip())
            continue
        if in_failed_block:
            if "TEST FAILED" in line or "BUILD FAILED" in line or "ARCHIVE FAILED" in line:
                in_failed_block = False
                continue
            stripped = line.strip()
            looks_like_result = (
                not stripped
                or stripped[0] in "◇✔✘✗✓"
                or stripped.startswith(("Test run", "Executed"))
            )
            if looks_like_result:
                in_failed_block = False
                # fall through and parse this line normally
            else:
                testing_failed_block.append(line)
                continue

        m = LOC_RE.match(line)
        if m:
            if m.group("kind") == "error":
                errors.append(Finding(m.group("path"), m.group("line"), m.group("msg")))
            else:
                msg = m.group("msg").strip()
                entry = warnings.setdefault(msg, {"count": 0, "locs": []})
                entry["count"] += 1
                if len(entry["locs"]) < 5:
                    entry["locs"].append(f"{m.group('path')}:{m.group('line')}")
            continue

        if TEST_PASS.search(line):
            tests_passed.append(TEST_PASS.search(line).group(1))
            continue
        if TEST_FAIL.search(line):
            tests_failed.append(TEST_FAIL.search(line).group(1))
            continue
        if SUITE_FAIL.search(line):
            suites_failed.append(SUITE_FAIL.search(line).group(1))
            continue
        if RUN_DONE.search(line):
            verdict = RUN_DONE.search(line).group(1)
            continue
        if EXECUTED.search(line):
            exec_line = line.strip()
            continue

        if ANY_ERR_RE.search(line) and not line.lstrip().startswith("//"):
            other_errors.append(line.strip())
        elif ANY_WARN_RE.search(line) and not line.lstrip().startswith("//"):
            msg = line.split("warning:", 1)[1].strip()
            entry = warnings.setdefault(msg, {"count": 0, "locs": []})
            entry["count"] += 1

    return {
        "errors": errors,
        "other_errors": other_errors,
        "warnings": warnings,
        "tests_passed": tests_passed,
        "tests_failed": tests_failed,
        "suites_failed": suites_failed,
        "verdict": verdict,
        "exec_line": exec_line,
        "testing_failed": testing_failed_block,
    }


# --- rendering --------------------------------------------------------------

def warnings_total(warnings) -> int:
    return sum(w["count"] for w in warnings.values())


def print_console(result) -> None:
    errors = result["errors"]
    other_errors = result["other_errors"]
    warn_total = warnings_total(result["warnings"])
    failed = len(result["tests_failed"])
    passed = len(result["tests_passed"])

    head = col("CI 摘要", "bold")
    summary_line = f"\n{head}  ❌ errors={len(errors)+len(other_errors)}  ⚠️ warnings={warn_total}"
    if passed or failed:
        summary_line += f"  🧪 tests: {passed} passed / {failed} failed"
    print(summary_line + "\n")

    if errors or other_errors or result["testing_failed"]:
        console_group(col(f"❌ Errors ({len(errors)+len(other_errors)})", "red", "bold"))
        for f in errors:
            print(col(f"{f.path}:{f.line}: {f.msg}", "red"))
            print(f"::error file={f.path},line={f.line}::{f.msg}")
        for line in other_errors:
            print(col(line, "red"))
        for line in result["testing_failed"]:
            print(col(line, "red"))
        console_endgroup()

    if result["warnings"]:
        console_group(col(f"⚠️ Warnings ({warn_total} total, {len(result['warnings'])} unique)", "yellow", "bold"))
        for msg, entry in result["warnings"].items():
            locs = " ".join(entry["locs"]) if entry["locs"] else ""
            print(col(f"  {entry['count']}× {msg}", "yellow"))
            if locs:
                print(col(f"      {locs}", "dim"))
        console_endgroup()

    if result["tests_passed"] or result["tests_failed"]:
        console_group(col("🧪 Tests", "cyan", "bold"))
        for name in result["tests_failed"]:
            print(col(f"  ✘ {name}", "red", "bold"))
            print(f"::error::{name}")
        for name in result["tests_passed"]:
            print(col(f"  ✔ {name}", "green"))
        for name in result["suites_failed"]:
            print(col(f"  ✘ Suite {name}", "red"))
        console_endgroup()
    if result["exec_line"]:
        print(result["exec_line"])


def render_markdown(result) -> str:
    errors = result["errors"]
    other_errors = result["other_errors"]
    warn_total = warnings_total(result["warnings"])
    passed = len(result["tests_passed"])
    failed = len(result["tests_failed"])
    ok = not errors and not other_errors and failed == 0 and not result["testing_failed"]

    out = []
    out.append("# CI 測試摘要")
    out.append("")
    out.append("| 項目 | 數量 |")
    out.append("| --- | --- |")
    out.append(f"| 結果 | {'✅ 通過' if ok else '❌ 失敗'} |")
    out.append(f"| Compile errors | {len(errors) + len(other_errors)} |")
    out.append(f"| Warnings | {warn_total} ({len(result['warnings'])} unique) |")
    out.append(f"| Tests | {passed} passed / {failed} failed |")
    out.append("")

    if errors or other_errors or result["testing_failed"]:
        out.append("## ❌ Errors")
        out.append("")
        for f in errors:
            out.append(f"- `{f.path}:{f.line}` {f.msg}")
        for line in other_errors:
            out.append(f"- {line}")
        if result["testing_failed"]:
            out.append("")
            out.append("```")
            out.extend(result["testing_failed"])
            out.append("```")
        out.append("")

    if result["warnings"]:
        out.append("## ⚠️ Warnings")
        out.append("")
        out.append("| 次數 | 警告 | 位置 |")
        out.append("| --- | --- | --- |")
        for msg, entry in result["warnings"].items():
            locs = "<br>".join(entry["locs"]) if entry["locs"] else ""
            safe_msg = msg.replace("|", "\\|")
            out.append(f"| {entry['count']} | {safe_msg} | {locs} |")
        out.append("")

    out.append("## 🧪 Tests")
    out.append("")
    if result["tests_failed"]:
        out.append("**Failed:**")
        for name in result["tests_failed"]:
            out.append(f"- ❌ {name}")
        out.append("")
    if result["tests_passed"]:
        out.append(f"**Passed ({passed}):** " + ", ".join(result["tests_passed"]))
        out.append("")
    if not result["tests_passed"] and not result["tests_failed"]:
        out.append("_no test results (build failed before running)_")
        out.append("")
    if result["exec_line"]:
        out.append(result["exec_line"])
        out.append("")

    return "\n".join(out)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("log", help="xcodebuild log file")
    ap.add_argument("--markdown", default="", help="write markdown summary to this path")
    ap.add_argument("--github-summary", action="store_true",
                    help="append markdown summary to $GITHUB_STEP_SUMMARY")
    args = ap.parse_args()

    try:
        log_text = open(args.log, "r", encoding="utf-8", errors="replace").read()
    except OSError as exc:
        print(f"::warning::無法讀取 log {args.log}: {exc}")
        return 0

    result = parse(log_text)
    print_console(result)

    markdown = render_markdown(result)
    if args.markdown:
        with open(args.markdown, "w", encoding="utf-8") as fh:
            fh.write(markdown + "\n")
    if args.github_summary:
        summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
        if summary_path:
            with open(summary_path, "a", encoding="utf-8") as fh:
                fh.write(markdown + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
