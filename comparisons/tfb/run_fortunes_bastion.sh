#!/usr/bin/env bash
# Bastion Fortunes matrix: proactr sync vs async vs ntex reference.
#
# Sync  — per-I/O-worker SQLite + stream HTML into body_reserve (default).
#         FORTUNES_SYNC_SHARED=1 for ntex-style single conn + mutex.
# Async — thread-pool offload, one SQLite conn per DB worker.
#
# Usage (ranch-bastion):
#   ./comparisons/tfb/schema/prepare.sh
#   ./comparisons/tfb/build_uring.sh
#   SERVERS="ntex proactr-sync proactr-async" ./comparisons/tfb/run_fortunes_bastion.sh
#
# Env (inherited by run_bench.sh):
#   WORKERS=8  BENCH_C=100  BENCH_Z=15s  DB_WORKERS  DATABASE_PATH
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

export SERVERS="${SERVERS:-ntex proactr-sync proactr-async}"
export TESTS="${TESTS:-plaintext fortunes}"
export WORKERS="${WORKERS:-8}"
export BENCH_C="${BENCH_C:-100}"
export BENCH_Z="${BENCH_Z:-15s}"
export WARMUP_Z="${WARMUP_Z:-3s}"
export REQUIRE_URING="${REQUIRE_URING:-1}"
export LOGDIR="${LOGDIR:-/tmp/proactr-fortunes-bastion}"
export DATABASE_PATH="${DATABASE_PATH:-/tmp/proactr-tfb.sqlite}"
# Async pool size (defaults to WORKERS if unset in peer start).
export DB_WORKERS="${DB_WORKERS:-$WORKERS}"

mkdir -p "$LOGDIR"

echo "==> Fortunes bastion matrix"
echo "    SERVERS=$SERVERS"
echo "    TESTS=$TESTS WORKERS=$WORKERS DB_WORKERS=$DB_WORKERS"
echo "    BENCH_C=$BENCH_C BENCH_Z=$BENCH_Z LOGDIR=$LOGDIR"
echo "    modes: proactr-sync=FORTUNES_MODE=sync  proactr-async=FORTUNES_MODE=async"

# Ensure proactr binary is fresh (modes share one binary).
(cd proactr && odin build . -out:tfb-proactr.bin -o:speed)

exec ./run_bench.sh
