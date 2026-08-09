#!/usr/bin/env bash
# PR5 CI gate: pure O(window) pipe seal∥send + firehose detector.
#
# Pure seal∥send + firehose CI: Done (http/pipe.odin + http/pipe_test.odin).
# This is not an HTTPS e2e gate. Live HTTPS oneshot is serial SSL_write windowed
# CT send (not dual-CT seal∥send on wire) — see docs/TLS_H1.md / IMPLEMENTATION_STATUS.md.
#
# Usage (CI / local):
#   ./scripts/check_firehose_pipe.sh
#
# Companion: docs/IMPLEMENTATION_STATUS.md (PR5 scorecard).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

fail=0
say_fail() { echo "FAIL: $*" >&2; fail=1; }
say_ok() { echo "OK: $*"; }

PIPE_TEST="http/pipe_test.odin"
PIPE_SRC="http/pipe.odin"

if [[ ! -f "$PIPE_TEST" ]]; then
  say_fail "missing $PIPE_TEST"
  echo "check_firehose_pipe: FAILED" >&2
  exit 1
fi
if [[ ! -f "$PIPE_SRC" ]]; then
  say_fail "missing $PIPE_SRC"
  echo "check_firehose_pipe: FAILED" >&2
  exit 1
fi

# Prefer ripgrep; fall back to grep so CI without rg still works.
if command -v rg >/dev/null 2>&1; then
  search() {
    local path="$1" re="$2"
    rg -n -e "$re" "$path" 2>/dev/null
  }
else
  search() {
    local path="$1" re="$2"
    grep -n -E -e "$re" "$path" 2>/dev/null
  }
fi

# Required firehose / O(window) pure tests (odin has no per-test name filter;
# we assert presence then run the full http package suite).
REQUIRED_TESTS=(
  'test_firehose_fail_detector'
  'test_pipe_bulk_sim_4mib_windowed_no_firehose'
  'test_pipe_bulk_sim_deliberate_firehose'
)

for name in "${REQUIRED_TESTS[@]}"; do
  if search "$PIPE_TEST" "@\\(test\\)|${name}" >/dev/null && search "$PIPE_TEST" "${name}" >/dev/null; then
    say_ok "firehose test present: $name"
  else
    say_fail "firehose test missing in $PIPE_TEST: $name"
  fi
done

# Detector + peak mult must exist on the pipe pure path.
if search "$PIPE_SRC" 'firehose_fail' >/dev/null; then
  say_ok "firehose_fail helper in $PIPE_SRC"
else
  say_fail "firehose_fail missing in $PIPE_SRC"
fi
if search "$PIPE_SRC" 'FIREHOSE_PEAK_MULT' >/dev/null; then
  say_ok "FIREHOSE_PEAK_MULT in $PIPE_SRC"
else
  say_fail "FIREHOSE_PEAK_MULT missing in $PIPE_SRC"
fi

if [[ "$fail" -ne 0 ]]; then
  echo "check_firehose_pipe: FAILED (source gate)" >&2
  exit 1
fi

if ! command -v odin >/dev/null 2>&1; then
  say_fail "odin not on PATH"
  echo "check_firehose_pipe: FAILED" >&2
  exit 1
fi

# Full http package: includes firehose + seal∥send pure tests.
# ODIN_TEST_THREADS=1 keeps CI deterministic (matches IMPLEMENTATION_STATUS note).
echo "Running: odin test http -define:ODIN_TEST_THREADS=1 -o:none"
if odin test http -define:ODIN_TEST_THREADS=1 -o:none; then
  say_ok "odin test http (includes firehose / O(window) pipe)"
else
  say_fail "odin test http failed"
  echo "check_firehose_pipe: FAILED" >&2
  exit 1
fi

echo "check_firehose_pipe: OK (PR5 O(window) pipe / firehose gate)"
