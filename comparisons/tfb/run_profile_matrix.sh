#!/usr/bin/env bash
# Five-profile peer matrix (PROFILE_MATRIX.md).
# Peers: proactr-mat, proactr-opt, laytan, ntex, drogon
# Routes: tiny gen assembled blob file sse
set -euo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:${HOME}/.cargo/bin:${HOME}/go/bin:/usr/local/bin:${PATH}"

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

export SERVERS="${SERVERS:-proactr-mat proactr-opt laytan ntex drogon}"
export TESTS="${TESTS:-tiny gen assembled blob file sse}"
export WORKERS="${WORKERS:-8}"
export BENCH_C="${BENCH_C:-100}"
export BENCH_Z="${BENCH_Z:-15s}"
export WARMUP_Z="${WARMUP_Z:-3s}"
export DATABASE_PATH="${DATABASE_PATH:-/tmp/proactr-tfb.sqlite}"
export PLAN_FILE_PATH="${PLAN_FILE_PATH:-/tmp/proactr-profile-file-1m.bin}"
export LOGDIR="${LOGDIR:-/tmp/proactr-profile-matrix}"
export FORCE_REBUILD="${FORCE_REBUILD:-1}"
export REQUIRE_URING="${REQUIRE_URING:-0}"

mkdir -p "$LOGDIR"

# Ensure profile file (1 MiB pattern) exists before peers start.
python3 - "$PLAN_FILE_PATH" <<'PY'
import sys
path = sys.argv[1]
pat = b"0123456789abcdef0123456789ABCDEF0123456789abcdef0123456789ABCDEF"
need = 1024 * 1024
body = (pat * ((need // len(pat)) + 1))[:need]
try:
    with open(path, "rb") as f:
        if len(f.read()) == need:
            raise SystemExit(0)
except FileNotFoundError:
    pass
with open(path, "wb") as f:
    f.write(body)
print(f"wrote {path} ({need} bytes)")
PY

{
  echo "# profile matrix meta"
  echo "rules=PROFILE_MATRIX.md"
  echo "servers=$SERVERS"
  echo "tests=$TESTS workers=$WORKERS c=$BENCH_C z=$BENCH_Z"
  echo "file=$PLAN_FILE_PATH"
  echo "mechanisms:"
  echo "  proactr-mat: tiny/gen/blob/sse=materialize_copy(CL) assembled=preconcat_blob file=file_read_full"
  echo "  proactr-opt: assembled=multi_send (NOT kernel writev) file=file_chunked (NOT kernel sendfile) tiny/gen/sse=materialize"
  echo "  laytan/ntex/drogon: assembled=preconcat_blob file=file_read_full sse=sse_oneshot_CL"
  echo "  drogon_io=epoll; others=io_uring_class_on_linux"
  echo "  drogon_oha_size: Size/request often WRONG on large bodies; body re-check is source of truth; RPS kept only if post-load body OK"
  echo "  ranking_rule: do NOT rank multi_send vs preconcat as same mechanism; split columns in reports"
  echo "  force_rebuild=$FORCE_REBUILD"
  date -u +%Y-%m-%dT%H:%M:%SZ
} | tee "$LOGDIR/meta.txt"

echo "=== five-profile peer matrix ==="
cat "$LOGDIR/meta.txt"
echo ""

# FORCE_REBUILD must rebuild profile peers (proactr-mat/opt not only proactr-sync).
if [[ "$FORCE_REBUILD" == "1" ]]; then
  ROOT="$(cd "$HERE/../.." && pwd)"
  echo "==> FORCE_REBUILD=1 (profile matrix peers)"
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

exec ./run_bench.sh
