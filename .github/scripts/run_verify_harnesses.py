#!/usr/bin/env python3
"""Compile and run the Foundation-only verification harnesses.

These ``.cortexkit/verify-*.swift`` files are the non-Apple-platform twins of the
Swift Testing suites. They are **not** SwiftPM test targets and are not run by
``swift test``: each is a standalone ``@main`` executable that compiles the real
Foundation-only source plus assertions, so the logic can be verified on
Windows/Linux where ``HaishinKitTests`` cannot build (it needs AVFoundation).

This runner is shared by local development and the ``verify-foundation`` CI job.
Add a new harness to ``HARNESSES``; unlisted ``verify-*.swift`` files fail the
run so an orphan script cannot silently stop being executed.
"""
from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

# repo root: .github/scripts/run_verify_harnesses.py -> parents[2]
ROOT = Path(__file__).resolve().parents[2]

# name -> [real source(s)..., harness]
HARNESSES: dict[str, list[str]] = {
    "mixer-clock": [
        "HaishinKit/Sources/Mixer/MixClockAdvance.swift",
        ".cortexkit/verify-mixer-clock.swift",
    ],
    "audio-timeline-policy": [
        "HaishinKit/Sources/Mixer/AudioTimelinePolicy.swift",
        ".cortexkit/verify-audio-timeline-policy.swift",
    ],
    "source-time-interval": [
        "HaishinKit/Sources/Util/SourceTimeAudit.swift",
        ".cortexkit/verify-source-time-interval.swift",
    ],
    "video-frame-filter": [
        "HaishinKit/Sources/Util/VideoFrameFilterState.swift",
        ".cortexkit/verify-video-frame-filter.swift",
    ],
    "av-content-sync": [
        "HaishinKit/Sources/Mixer/AVContentSyncAudit.swift",
        ".cortexkit/verify-av-content-sync.swift",
    ],
    "handshake": [
        "RTMPHaishinKit/Sources/RTMP/RTMPHandshake.swift",
        ".cortexkit/verify-handshake.swift",
    ],
    "keepalive": [
        "RTMPHaishinKit/Sources/RTMP/RTMPKeepAlive.swift",
        ".cortexkit/verify-keepalive.swift",
    ],
    "cts": [
        "RTMPHaishinKit/Sources/RTMP/RTMPVideoCompositionTime.swift",
        ".cortexkit/verify-cts.swift",
    ],
    "aec": [
        "HaishinKit/Sources/Mixer/AudioEchoCanceler.swift",
        ".cortexkit/verify-aec.swift",
    ],
    # Pure integer mirror of AudioRingBuffer.align(to:), which needs AVFoundation.
    "align": [
        "HaishinKit/Sources/Mixer/AudioRingBufferAlignment.swift",
        ".cortexkit/verify-align.swift",
    ],
}


def discover_harnesses() -> set[str]:
    """Return every verify-*.swift filename under .cortexkit."""
    return {path.name for path in (ROOT / ".cortexkit").glob("verify-*.swift")}


def listed_harnesses() -> set[str]:
    return {
        Path(source).name
        for sources in HARNESSES.values()
        for source in sources
        if Path(source).name.startswith("verify-")
    }


def run_one(swiftc: str, name: str, work: Path, verbose: bool) -> bool:
    sources = [ROOT / source for source in HARNESSES[name]]
    missing = [str(source) for source in sources if not source.is_file()]
    if missing:
        print(f"FAIL {name}: missing source(s): {', '.join(missing)}", file=sys.stderr)
        return False

    suffix = ".exe" if os.name == "nt" else ""
    executable = work / f"{name}{suffix}"
    command = [swiftc, "-O", *(str(source) for source in sources), "-o", str(executable)]
    print(f"== {name} ==")
    try:
        compiled = subprocess.run(command, capture_output=True, text=True,
                                  encoding="utf-8", errors="replace", timeout=300)
    except subprocess.TimeoutExpired:
        print(f"FAIL {name}: compile timed out", file=sys.stderr)
        return False
    if compiled.returncode != 0:
        print(f"FAIL {name}: compile exit {compiled.returncode}", file=sys.stderr)
        print(compiled.stdout, end="")
        print(compiled.stderr, end="", file=sys.stderr)
        return False

    try:
        result = subprocess.run([str(executable)], capture_output=True, text=True,
                                encoding="utf-8", errors="replace", timeout=300)
    except (OSError, subprocess.TimeoutExpired) as error:
        print(f"FAIL {name}: run failed: {error}", file=sys.stderr)
        return False
    if result.returncode != 0:
        print(f"FAIL {name}: exit {result.returncode}", file=sys.stderr)
        print(result.stdout, end="")
        print(result.stderr, end="", file=sys.stderr)
        return False
    if verbose:
        print(result.stdout, end="")
    print(f"PASS {name}")
    return True


def configure_stdio() -> None:
    """Keep harness output readable on Windows consoles (cp950 cannot encode ✓)."""
    for stream in (sys.stdout, sys.stderr):
        reconfigure = getattr(stream, "reconfigure", None)
        if reconfigure is not None:
            reconfigure(encoding="utf-8", errors="replace")


def main() -> int:
    configure_stdio()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--list", action="store_true", help="list harness names")
    parser.add_argument("--only", action="append", default=[],
                        metavar="NAME", help="run only this harness (repeatable)")
    parser.add_argument("--verbose", action="store_true", help="print each harness output")
    args = parser.parse_args()

    if args.list:
        for name in HARNESSES:
            print(name)
        return 0

    discovered = discover_harnesses()
    listed = listed_harnesses()
    orphans = sorted(discovered - listed)
    if orphans:
        print("unlisted verify scripts: " + ", ".join(orphans), file=sys.stderr)
        print("add them to HARNESSES in .github/scripts/run_verify_harnesses.py",
              file=sys.stderr)
        return 1
    stale = sorted(listed - discovered)
    if stale:
        print("listed but missing verify scripts: " + ", ".join(stale), file=sys.stderr)
        return 1

    swiftc = shutil.which("swiftc")
    if swiftc is None:
        print("swiftc not found on PATH", file=sys.stderr)
        return 1

    names = args.only or list(HARNESSES)
    unknown = [name for name in names if name not in HARNESSES]
    if unknown:
        print("unknown harness: " + ", ".join(unknown), file=sys.stderr)
        return 1

    failures: list[str] = []
    with tempfile.TemporaryDirectory(prefix="verify-harnesses-") as directory:
        work = Path(directory)
        for name in names:
            if not run_one(swiftc, name, work, args.verbose):
                failures.append(name)

    if failures:
        print(f"\n{len(failures)} harness(es) failed: " + ", ".join(failures), file=sys.stderr)
        return 1
    print(f"\nALL PASS ({len(names)} harness(es))")
    return 0


if __name__ == "__main__":
    sys.exit(main())
