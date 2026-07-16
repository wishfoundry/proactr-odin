#!/usr/bin/env bash
# TFB plaintext/HTML harness — default peers are io_uring-backed on Linux.
set -euo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:${HOME}/.cargo/bin:${HOME}/go/bin:/usr/local/bin:${PATH}"

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

PORT="${PORT:-18080}"
WORKERS="${WORKERS:-1}"
BENCH_C="${BENCH_C:-64}"
BENCH_Z="${BENCH_Z:-15s}"
WARMUP_Z="${WARMUP_Z:-3s}"
DATABASE_PATH="${DATABASE_PATH:-/tmp/proactr-tfb.sqlite}"
# Default: io_uring class only. go/drogon are epoll-class (opt-in).
if [[ "$(uname -s)" == "Linux" ]]; then
  SERVERS="${SERVERS:-ntex ntex-compio compio laytan}"
else
  SERVERS="${SERVERS:-ntex}" # dev only (tokio on non-Linux)
fi
TESTS="${TESTS:-plaintext fortunes}"
LOGDIR="${LOGDIR:-/tmp/proactr-tfb-logs}"
REQUIRE_URING="${REQUIRE_URING:-}"
mkdir -p "$LOGDIR"

export DATABASE_PATH PORT WORKERS

have() { command -v "$1" >/dev/null 2>&1; }

if [[ "$(uname -s)" == "Linux" ]]; then
  if [[ "${REQUIRE_URING:-1}" == "1" ]]; then
    "$ROOT/scripts/check_io_uring.sh" | tee "$LOGDIR/io_uring_check.txt"
  fi
  IO_BACKEND=io_uring
else
  IO_BACKEND="not-linux (not an uring baseline)"
fi

if [[ ! -f "$DATABASE_PATH" ]]; then
  echo "Preparing DB at $DATABASE_PATH"
  DATABASE_PATH="$DATABASE_PATH" ./schema/prepare.sh
fi

if ! have oha && ! have bombardier && ! have wrk; then
  echo "Need oha (preferred), bombardier, or wrk on PATH" >&2
  exit 1
fi

kill_port() {
  if have lsof; then
    lsof -tiTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | xargs kill -9 2>/dev/null || true
  fi
  sleep 0.3
}

wait_up() {
  local i
  for i in $(seq 1 100); do
    code=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${PORT}/plaintext" 2>/dev/null || echo 000)
    if [[ "$code" == "200" ]]; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

path_for_test() {
  case "$1" in
    plaintext) echo /plaintext ;;
    fortunes) echo /fortunes ;;
    *) echo "/$1" ;;
  esac
}

run_load() {
  local name="$1"
  local test="$2"
  local url="http://127.0.0.1:${PORT}$(path_for_test "$test")"
  local out="$LOGDIR/${name}_${test}.txt"

  echo "  load $test → $url (c=$BENCH_C z=$BENCH_Z warmup=$WARMUP_Z)"

  if have oha; then
    oha -z "$WARMUP_Z" -c "$BENCH_C" --no-tui "$url" >/dev/null 2>&1 || true
    if oha --help 2>&1 | grep -q latency-correction; then
      oha -z "$BENCH_Z" -c "$BENCH_C" --latency-correction --no-tui "$url" | tee "$out"
    else
      oha -z "$BENCH_Z" -c "$BENCH_C" --no-tui "$url" | tee "$out"
    fi
  elif have bombardier; then
    bombardier -c "$BENCH_C" -d "$BENCH_Z" "$url" | tee "$out"
  else
    wrk -t4 -c "$BENCH_C" -d "$BENCH_Z" "$url" | tee "$out"
  fi
}

summarize_line() {
  local name="$1" test="$2" file="$3"
  local rps p50 p99 err
  rps="?"; p50="?"; p99="?"; err=""
  if [[ -f "$file" ]]; then
    rps=$(awk '/Requests\/sec/ {print $2; exit}' "$file" 2>/dev/null || true)
    [[ -z "$rps" ]] && rps=$(awk '/Reqs\/sec/ {print $2; exit}' "$file" 2>/dev/null || true)
    p50=$(awk '/50%/ {print $2; exit}' "$file" 2>/dev/null || true)
    p99=$(awk '/99%/ {print $2; exit}' "$file" 2>/dev/null || true)
    [[ -z "$p50" ]] && p50=$(awk '/Latency/ {print $2; exit}' "$file" 2>/dev/null || true)
    err=$(awk '/Non-2xx|5xx|Error/ {print; exit}' "$file" 2>/dev/null | head -c 48 || true)
  fi
  printf '%-12s %-10s %12s %10s %10s  %s\n' "$name" "$test" "${rps:-?}" "${p50:-?}" "${p99:-?}" "${err:-}"
}

start_peer() {
  local name="$1"
  kill_port
  case "$name" in
    ntex)
      if [[ ! -x ntex/target/release/ntex-tfb ]]; then
        (cd ntex && cargo build --release) || return 1
      fi
      env DATABASE_PATH="$DATABASE_PATH" PORT="$PORT" WORKERS="$WORKERS" \
        ./ntex/target/release/ntex-tfb >"$LOGDIR/ntex.server.log" 2>&1 &
      ;;
    ntex-compio)
      if [[ ! -x ntex-compio/target/release/ntex-compio-tfb ]]; then
        (cd ntex-compio && cargo build --release) || return 1
      fi
      env DATABASE_PATH="$DATABASE_PATH" PORT="$PORT" WORKERS="$WORKERS" \
        ./ntex-compio/target/release/ntex-compio-tfb >"$LOGDIR/ntex-compio.server.log" 2>&1 &
      ;;
    compio)
      if [[ ! -x compio/target/release/compio-tfb ]]; then
        (cd compio && cargo build --release) || return 1
      fi
      env DATABASE_PATH="$DATABASE_PATH" PORT="$PORT" WORKERS="$WORKERS" \
        ./compio/target/release/compio-tfb >"$LOGDIR/compio.server.log" 2>&1 &
      ;;
    asio)
      if [[ ! -x asio/asio_tfb ]]; then
        ./asio/build.sh || return 1
      fi
      env DATABASE_PATH="$DATABASE_PATH" PORT="$PORT" WORKERS="$WORKERS" \
        ./asio/asio_tfb >"$LOGDIR/asio.server.log" 2>&1 &
      ;;
    laytan)
      if [[ ! -x laytan/tfb-laytan ]]; then
        (cd laytan && odin build . -out:tfb-laytan -o:speed \
          -collection:laytan="$ROOT/vendor/laytan") || return 1
      fi
      env PORT="$PORT" ./laytan/tfb-laytan >"$LOGDIR/laytan.server.log" 2>&1 &
      ;;
    proactr)
      echo "skip proactr (host not live)"
      return 1
      ;;
    go)
      echo "WARN: go net/http is epoll/kqueue — not io_uring"
      if [[ ! -x go/tfb-go ]]; then
        (cd go && go build -o tfb-go .) || return 1
      fi
      env DATABASE_PATH="$DATABASE_PATH" PORT="$PORT" WORKERS="$WORKERS" \
        ./go/tfb-go >"$LOGDIR/go.server.log" 2>&1 &
      ;;
    drogon)
      echo "WARN: drogon has no io_uring backend"
      if [[ ! -x drogon/build/drogon_tfb ]]; then
        echo "skip drogon (not built)"
        return 1
      fi
      env DATABASE_PATH="$DATABASE_PATH" PORT="$PORT" WORKERS="$WORKERS" \
        ./drogon/build/drogon_tfb >"$LOGDIR/drogon.server.log" 2>&1 &
      ;;
    *)
      echo "unknown peer $name" >&2
      return 1
      ;;
  esac
  local pid=$!
  if ! wait_up; then
    echo "FAIL start $name (see $LOGDIR/${name}.server.log)"
    kill "$pid" 2>/dev/null || true
    return 1
  fi
  echo "$pid"
}

echo "=== proactr-odin TFB baselines (io_uring class) ==="
echo "host=$(uname -s) $(uname -m)  kernel=$(uname -r 2>/dev/null || true)"
echo "IO_BACKEND=$IO_BACKEND  db=$DATABASE_PATH  port=$PORT  workers=$WORKERS"
echo "c=$BENCH_C duration=$BENCH_Z warmup=$WARMUP_Z"
echo "servers=$SERVERS tests=$TESTS"
echo "logs=$LOGDIR"
echo ""

SUMMARY="$LOGDIR/summary.txt"
{
  echo "IO_BACKEND=$IO_BACKEND"
  printf '%-12s %-10s %12s %10s %10s  %s\n' PEER TEST RPS p50 p99 notes
  printf '%-12s %-10s %12s %10s %10s  %s\n' ---- ---- --- --- --- -----
} | tee "$SUMMARY"

for srv in $SERVERS; do
  echo "==> peer $srv"
  pid=""
  if ! pid=$(start_peer "$srv"); then
    echo "  (skip $srv)"
    continue
  fi
  for t in $TESTS; do
    if [[ "$srv" == "laytan" && "$t" == "fortunes" ]]; then
      echo "  skip fortunes (laytan DB not linked; would 501)"
      printf '%-12s %-10s %12s %10s %10s  %s\n' "$srv" "$t" "n/a" "n/a" "n/a" "501-not-implemented" | tee -a "$SUMMARY"
      continue
    fi
    run_load "$srv" "$t" || true
    summarize_line "$srv" "$t" "$LOGDIR/${srv}_${t}.txt" | tee -a "$SUMMARY"
  done
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  kill_port
done

echo ""
echo "=== Summary ==="
cat "$SUMMARY"
echo ""
echo "Full logs: $LOGDIR"
echo "Uring peers: ntex(neon-uring) ntex-compio compio asio laytan proactr"
echo "Not uring (opt-in only): go drogon"
