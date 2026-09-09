#!/usr/bin/env bash
set -euo pipefail

log_file="${1:?log file is required}"
output_file="${2:?output markdown file is required}"
annotation_title="${3:-Swift Tests}"

: > "${output_file}"

if [ ! -s "${log_file}" ]; then
  {
    echo "#### Failure diagnostics"
    echo
    echo "- No xcodebuild log was found."
  } >> "${output_file}"
  echo "::error title=${annotation_title}::No xcodebuild log was found"
  exit 0
fi

failed_tests="$(
  grep -n -E "✘ Test .* failed after|✘ Suite .* failed after|✘ Test run with .* failed after" "${log_file}" || true
)"
issues="$(
  grep -n -E "✘ Test .* recorded an issue at|Expectation failed:|Fatal error|Caught error:" "${log_file}" || true
)"
compiler_errors="$(
  grep -n -E "^error:|^fatal error:|^/.+:[0-9]+:[0-9]+: error:|No such module|cannot find|Testing failed:|\\*\\* TEST FAILED \\*\\*" "${log_file}" || true
)"

{
  echo "#### Failure diagnostics"
  echo
  if [ -n "${failed_tests}" ]; then
    echo "##### Failed tests and suites"
    echo
    echo '```text'
    echo "${failed_tests}" | head -n 120
    echo '```'
    echo
  fi
  if [ -n "${issues}" ]; then
    echo "##### Recorded issues"
    echo
    echo '```text'
    echo "${issues}" | head -n 120
    echo '```'
    echo
  fi
  if [ -n "${compiler_errors}" ]; then
    echo "##### Compiler and xcodebuild errors"
    echo
    echo '```text'
    echo "${compiler_errors}" | head -n 120
    echo '```'
    echo
  fi
  if [ -z "${failed_tests}${issues}${compiler_errors}" ]; then
    echo "- No focused failure lines matched. Check the full artifact log."
  fi
} >> "${output_file}"

printf '%s\n%s\n%s\n' "${failed_tests}" "${issues}" "${compiler_errors}" |
  sed '/^[[:space:]]*$/d' |
  head -n 40 |
  while IFS= read -r line; do
    message="${line//'%'/'%25'}"
    message="${message//$'\r'/'%0D'}"
    message="${message//$'\n'/'%0A'}"
    echo "::error title=${annotation_title}::${message}"
  done
