#!/usr/bin/env bash
# Colorize Swift Testing / xcodebuild per-test result lines for GitHub Actions.
#
# Swift Testing does not emit ANSI colors when stdout is not a TTY (i.e. in CI),
# so the `✔/✘` per-test lines show up uncolored. GitHub Actions *does* render
# ANSI, so we re-colorize the stream here. Green = passed, red = failed / issue;
# every other line passes through unchanged.
#
# Usage:
#   xcodebuild test ... 2>&1 | bash .github/scripts/colorize-test-log.sh | tee log
set -euo pipefail

awk '
  /passed after|✔/ { printf "\033[32m%s\033[0m\n", $0; next }
  /failed after|✘|recorded an issue|Expectation failed|Failing tests:/ { printf "\033[31m%s\033[0m\n", $0; next }
  { print }
'
