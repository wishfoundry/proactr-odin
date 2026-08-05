#!/usr/bin/env bash
# Fortunes peer matrix with explicit fairness modes (not silent proactr advantage).
#
# Modes:
#   FAIR=app   — all peers use their natural paths; LABEL as app-tier (DB work differs)
#   FAIR=shared — proactr FORTUNES_SYNC_SHARED=1 (ntex-like mutex); still not identical SQL
#
# Does NOT claim pure framework RPS. Meta always says app_work_unequal.
set -euo pipefail
export PATH="$HOME/.cargo/bin:/usr/local/bin:$PATH"
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

export FAIR="${FAIR:-app}"
export SERVERS="${SERVERS:-proactr-mat ntex drogon}"
export TESTS="${TESTS:-plaintext fortunes}"
export WORKERS="${WORKERS:-8}"
export BENCH_C="${BENCH_C:-100}"
export BENCH_Z="${BENCH_Z:-15s}"
export WARMUP_Z="${WARMUP_Z:-3s}"
export DATABASE_PATH="${DATABASE_PATH:-/tmp/proactr-tfb.sqlite}"
export LOGDIR="${LOGDIR:-/tmp/proactr-fortunes-fair}"
export FORCE_REBUILD="${FORCE_REBUILD:-1}"
export REQUIRE_URING="${REQUIRE_URING:-0}"

if [[ "$FAIR" == "shared" ]]; then
  export FORTUNES_SYNC_SHARED=1
else
  export FORTUNES_SYNC_SHARED=0
fi

mkdir -p "$LOGDIR"
{
  echo "# fortunes fair meta"
  echo "FAIR=$FAIR FORTUNES_SYNC_SHARED=$FORTUNES_SYNC_SHARED"
  echo "WARNING: fortunes is APP-TIER — SQLite paths differ by peer (see PROFILE_MATRIX / CRITIC)"
  echo "  proactr: prepared SELECT ORDER BY, per-worker or shared conn"
  echo "  ntex: prepare-per-request, app sort, shared mutex"
  echo "  drogon: open/close per request unless fixed"
  echo "workers=$WORKERS c=$BENCH_C z=$BENCH_Z"
  date -u +%Y-%m-%dT%H:%M:%SZ
} | tee "$LOGDIR/meta.txt"

[[ -f "$DATABASE_PATH" ]] || DATABASE_PATH="$DATABASE_PATH" ./schema/prepare.sh

exec ./run_bench.sh
