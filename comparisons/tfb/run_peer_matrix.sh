#!/usr/bin/env bash
# Peer matrix: proactr vs laytan (upstream odin-http) vs ntex vs drogon.
# Same routes, WORKERS, c, z, loadgen, host. Labels I/O backends in the summary.
#
# FAIR on size ladder (plaintext / s4k / s64k / s1m): fixed body sizes verified
# by run_bench.sh body-check. NOT fair on fortunes without reading the app notes
# below — do not ship fortunes RPS as "equal work."
#
# Usage (ranch-bastion recommended):
#   ./comparisons/tfb/schema/prepare.sh
#   SERVERS="proactr laytan ntex drogon" WORKERS=8 BENCH_C=100 BENCH_Z=15s \
#     ./comparisons/tfb/run_peer_matrix.sh | tee /tmp/peer-matrix.log
#
# Size-ladder only (I/O ceiling, fairest claim):
#   TESTS="plaintext s4k s64k s1m" ./comparisons/tfb/run_peer_matrix.sh
#
# See CRITIC.md for anti-cheat checklist.
set -euo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:${HOME}/.cargo/bin:${HOME}/go/bin:/usr/local/bin:${PATH}"

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
cd "$HERE"

export SERVERS="${SERVERS:-proactr laytan ntex drogon}"
# Default includes fortunes for visibility; interpret that column with APP NOTES.
export TESTS="${TESTS:-plaintext s4k s64k s1m fortunes}"
export WORKERS="${WORKERS:-8}"
export BENCH_C="${BENCH_C:-100}"
export BENCH_Z="${BENCH_Z:-15s}"
export WARMUP_Z="${WARMUP_Z:-3s}"
export DATABASE_PATH="${DATABASE_PATH:-/tmp/proactr-tfb.sqlite}"
export LOGDIR="${LOGDIR:-/tmp/proactr-peer-matrix}"
export REQUIRE_URING="${REQUIRE_URING:-0}"  # drogon is epoll; do not require uring-only matrix
export FORCE_REBUILD="${FORCE_REBUILD:-1}"
# Optional: FORTUNES_SYNC_SHARED=1 makes proactr sync use one conn+mutex (ntex-like
# concurrency model). Default proactr = per-I/O-worker SQLite (faster, unequal app).

mkdir -p "$LOGDIR"

backend_label() {
  case "$1" in
    proactr|proactr-sync) echo "proactr/io_uring (Linux) or kqueue façade · materialize wire (plan_optimize=off) · fortunes=sync per-worker SQLite unless FORTUNES_SYNC_SHARED=1" ;;
    proactr-async) echo "proactr/io_uring · materialize wire · fortunes=async DB pool (DB_WORKERS)" ;;
    laytan) echo "laytan/nbio→io_uring (Linux) · fortunes=501 skip" ;;
    ntex) echo "ntex/neon-uring · fortunes=shared Mutex+rusqlite (prepare-per-request, app sort)" ;;
    drogon) echo "drogon/epoll (trantor) · fortunes=open/prepare/close per request (app sort) — handicapped" ;;
    *) echo "unknown" ;;
  esac
}

echo "=== peer matrix ==="
echo "host=$(hostname) $(uname -s) $(uname -r)"
echo "SERVERS=$SERVERS"
echo "TESTS=$TESTS WORKERS=$WORKERS BENCH_C=$BENCH_C BENCH_Z=$BENCH_Z WARMUP_Z=$WARMUP_Z"
echo "LOGDIR=$LOGDIR DATABASE_PATH=$DATABASE_PATH"
echo "backends:"
for s in $SERVERS; do
  echo "  $s: $(backend_label "$s")"
done
echo ""
echo "==> FAIRNESS (read before claiming wins)"
echo "  SIZE LADDER: same paths, same byte lengths (13 / 4096 / 65536 / 1048576)."
echo "    proactr wire = materialize into resp_buf + one send (NOT kernel writev/sendfile)."
echo "    plan_optimize multi-send must never be labeled as writev in reports."
echo "  I/O BACKENDS: drogon=epoll; ntex/laytan/proactr=io_uring class on Linux."
echo "  FORTUNES: APP WORK DIFFERS — not a fair framework-only comparison:"
echo "    proactr: prepared SELECT … ORDER BY, stream HTML, per-worker conn (default)"
echo "    ntex:    SELECT *, app sort, shared mutex, prepare every request"
echo "    drogon:  open/close SQLite every request (worst); app sort"
echo "    laytan:  501 / skipped"
echo "    For ntex-like DB concurrency on proactr: FORTUNES_SYNC_SHARED=1"
echo "  LOADGEN: same host as servers → note contention; all peers share it."
echo ""

# Fresh builds so no stale binary cheats a peer.
if [[ "$FORCE_REBUILD" == "1" ]]; then
  echo "==> FORCE_REBUILD=1"
  for s in $SERVERS; do
    case "$s" in
      proactr|proactr-sync|proactr-async|proactr-mat|proactr-opt)
        (cd proactr && odin build . -out:tfb-proactr.bin -o:speed) || exit 1
        ;;
      laytan)
        (cd laytan && odin build . -out:tfb-laytan -o:speed \
          -collection:laytan="$ROOT/vendor/laytan") || exit 1
        ;;
      ntex)
        (cd ntex && cargo build --release) || exit 1
        ;;
      drogon)
        ./drogon/build.sh || exit 1
        ;;
    esac
  done
fi

if [[ ! -f "$DATABASE_PATH" ]]; then
  DATABASE_PATH="$DATABASE_PATH" ./schema/prepare.sh
fi

# Sanity: same payload sizes for size ladder (proactr peer uses fixed buffers).
echo "==> body size check notes (see WORKLOAD.md): plaintext=13 s4k=4096 s64k=65536 s1m=1048576"
echo "    run_bench.sh verifies Content body lengths after each peer starts"
echo ""

# Fairness banner for critic
{
  echo "# peer matrix meta"
  echo "workers=$WORKERS c=$BENCH_C z=$BENCH_Z warmup=$WARMUP_Z"
  echo "loadgen=$(command -v oha || command -v bombardier || command -v wrk)"
  echo "force_rebuild=$FORCE_REBUILD"
  echo "require_uring=$REQUIRE_URING"
  echo "fortunes_sync_shared=${FORTUNES_SYNC_SHARED:-0}"
  echo "proactr_wire=materialize (Default_Server_Opts.plan_optimize=false)"
  echo "drogon_io=epoll"
  echo "ntex_io=neon-uring"
  echo "laytan_io=nbio/io_uring"
  echo "fortunes_fair=no (app work differs; see run_peer_matrix.sh header)"
  date -u +%Y-%m-%dT%H:%M:%SZ
  for s in $SERVERS; do
    echo "backend $s: $(backend_label "$s")"
  done
} | tee "$LOGDIR/meta.txt"

exec ./run_bench.sh
