#!/usr/bin/env bash
# E0.5–E0.7 (+ README honesty): hard-fail example/docs dual-API bans.
# Plan A R4 Phase 0 — see docs/PHASE0_E0.md and docs/IMPLEMENTATION_STATUS.md.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

fail=0
say_fail() { echo "FAIL: $*" >&2; fail=1; }
say_ok() { echo "OK: $*"; }

# Prefer ripgrep; fall back to grep -R so CI without rg still enforces bans.
if command -v rg >/dev/null 2>&1; then
  search() {
    # usage: search <path> <regex>  — prints matches; exit 0 if any
    local path="$1" re="$2"
    rg -n --glob '*.odin' -e "$re" "$path" 2>/dev/null
  }
  search_any() {
    local path="$1" re="$2"
    rg -n -e "$re" "$path" 2>/dev/null
  }
  search_text_i() {
    local path="$1" re="$2"
    rg -n -i -e "$re" "$path" 2>/dev/null
  }
else
  search() {
    local path="$1" re="$2"
    grep -R -n -E --include='*.odin' -e "$re" "$path" 2>/dev/null
  }
  search_any() {
    local path="$1" re="$2"
    grep -n -E -e "$re" "$path" 2>/dev/null
  }
  search_text_i() {
    local path="$1" re="$2"
    grep -n -E -i -e "$re" "$path" 2>/dev/null
  }
fi

EXAMPLES_DIR="examples"
README="README.md"

# --- E0.5: no examples/ import of http/debug (or caps/proto introspection packages) ---
if [[ -d "$EXAMPLES_DIR" ]]; then
  if search "$EXAMPLES_DIR" 'import[[:space:]].*http/debug'; then
    say_fail "E0.5: examples/ must not import http/debug"
  else
    say_ok "E0.5 no http/debug import in examples/"
  fi

  if search "$EXAMPLES_DIR" 'Message_Proto|Conn_Proto|Conn_Caps|http\.debug'; then
    say_fail "E0.5: examples/ must not introspect caps/proto/debug"
  else
    say_ok "E0.5 no caps/proto introspection in examples/"
  fi

  # --- E0.7: no stream id / Response._sid in examples ---
  if search "$EXAMPLES_DIR" 'Response\._sid|_sid\b|stream_id|frame_id'; then
    say_fail "E0.7: examples/ must not mention Response._sid / stream ids"
  else
    say_ok "E0.7 no stream id / _sid in examples/"
  fi

  # --- E0.6: no body_set_pull / Host_Pull registration from app samples ---
  if search "$EXAMPLES_DIR" 'body_set_pull|Host_Pull|host_pull'; then
    say_fail "E0.6: examples/ must not register body_set_pull / Host_Pull"
  else
    say_ok "E0.6 no body_set_pull / Host_Pull in examples/"
  fi
else
  say_fail "examples/ directory missing"
fi

# --- README honesty: no bare "supports HTTP/2" / "HTTP/2 ready" product claim ---
if [[ -f "$README" ]]; then
  # Allow lines that clearly phase-gate or forbid the claim.
  bad_lines=""
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if echo "$line" | grep -Eiq 'phase|⏳|forbidden|not |until|before|only after'; then
      continue
    fi
    bad_lines+="$line"$'\n'
  done < <(search_text_i "$README" 'supports HTTP/2|HTTP/2 ready|HTTP/2 support' || true)

  if [[ -n "${bad_lines}" ]]; then
    printf '%s' "$bad_lines" >&2
    say_fail "README claims HTTP/2 product support without phase note"
  else
    say_ok "README has no unphased HTTP/2 product claim"
  fi
else
  say_fail "README.md missing"
fi

if [[ "$fail" -ne 0 ]]; then
  echo "check_e0_bans: FAILED" >&2
  exit 1
fi
echo "check_e0_bans: OK (E0.5–E0.7 + README honesty)"
