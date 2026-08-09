#!/usr/bin/env bash
# E0.4: same-handler clear-H1 sample gate.
#
# Designated sample: examples/empty_ok
#   - Zero protocol #if; no stream ids; no TLS/H2 listen branches.
#   - This *is* the clear-H1 App Contract sample until multi-protocol jobs land.
#
# CI one-liner (when a workflow is wired):
#   ./scripts/check_app_contract_sample.sh && ./scripts/check_e0_bans.sh
#
# Multi-protocol (TLS H1 / H2) listen jobs: not started — same handler sources stay
# unchanged; only listen opts grow later. See docs/IMPLEMENTATION_STATUS.md.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SAMPLE="examples/empty_ok"
MAIN="$SAMPLE/main.odin"
fail=0
say_fail() { echo "FAIL: $*" >&2; fail=1; }
say_ok() { echo "OK: $*"; }

if command -v rg >/dev/null 2>&1; then
  search() {
    local path="$1" re="$2"
    rg -n --glob '*.odin' -e "$re" "$path" 2>/dev/null
  }
else
  search() {
    local path="$1" re="$2"
    grep -R -n -E --include='*.odin' -e "$re" "$path" 2>/dev/null
  }
fi

if [[ ! -f "$MAIN" ]]; then
  say_fail "E0.4 sample missing: $MAIN (expected clear-H1 same-handler sample)"
  echo "check_app_contract_sample: FAILED" >&2
  exit 1
fi
say_ok "E0.4 designated clear-H1 sample: $SAMPLE"

# No protocol #if / OS-only branches that fork handler logic by TLS or H2
if search "$SAMPLE" '#\s*if\b.*(TLS|HTTPS|HTTP2|H2|SSL|ALPN)|when\s+.*(TLS|HTTPS|HTTP2|H2)'; then
  say_fail "E0.4: sample must have zero protocol #if / when TLS|H2 branches"
else
  say_ok "E0.4 no protocol #if in $SAMPLE"
fi

# No stream ids / sid in the sample
if search "$SAMPLE" 'Response\._sid|_sid\b|stream_id|frame_id'; then
  say_fail "E0.4: sample must not touch stream ids / _sid"
else
  say_ok "E0.4 no stream ids in $SAMPLE"
fi

# No debug / pull duals in the sample (overlaps E0.5–E0.6 for this tree)
if search "$SAMPLE" 'http/debug|body_set_pull|Host_Pull|Message_Proto|Conn_Proto'; then
  say_fail "E0.4: sample must not import debug or register Host_Pull / pull"
else
  say_ok "E0.4 no debug/pull duals in $SAMPLE"
fi

if [[ "$fail" -ne 0 ]]; then
  echo "check_app_contract_sample: FAILED" >&2
  exit 1
fi

cat <<'EOF'
check_app_contract_sample: OK

E0.4 status:
  clear-H1 sample = examples/empty_ok
  multi-protocol CI (TLS H1 / H2 same handler) = not started
  wire into CI: ./scripts/check_app_contract_sample.sh && ./scripts/check_e0_bans.sh
EOF
