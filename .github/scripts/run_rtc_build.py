#!/usr/bin/env python3
"""Build RTCHaishinKit with a bounded timeout and one retry.

SwiftPM may stall while downloading the large binaryTarget artifacts. The
workflow previously sat in that state until the 45-minute job timeout, so this
wrapper keeps a bad network attempt to ten minutes and retries once.
"""

from __future__ import annotations

import os
import signal
import subprocess
import sys
import time

ATTEMPTS = 2
TIMEOUT_SECONDS = 10 * 60


def run_once() -> int:
    process = subprocess.Popen(
        ["swift", "build", "--target", "RTCHaishinKit"],
        start_new_session=True,
    )
    try:
        return process.wait(timeout=TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired:
        print(
            f"[rtc-build] timed out after {TIMEOUT_SECONDS}s; killing process group",
            flush=True,
        )
        try:
            killpg = getattr(os, "killpg", None)
            sigkill = getattr(signal, "SIGKILL", signal.SIGTERM)
            if killpg is not None:
                killpg(process.pid, sigkill)
            else:
                process.kill()
        except ProcessLookupError:
            pass
        process.wait()
        return 124


def main() -> int:
    last_status = 124
    for attempt in range(1, ATTEMPTS + 1):
        print(f"[rtc-build] attempt {attempt}/{ATTEMPTS}", flush=True)
        last_status = run_once()
        if last_status == 0:
            return 0
        if attempt < ATTEMPTS:
            time.sleep(10)
    return last_status


if __name__ == "__main__":
    sys.exit(main())
