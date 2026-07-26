#!/usr/bin/env bash
# empty-ok multi-peer harness — fair worker count across peers.
# WORKERS is passed to every peer that honors it (proactr, laytan, ntex, drogon).
# asio/compio remain single accept-loop baselines (same as TFB).
set -euo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:${HOME}/.cargo/bin:${HOME}/go/bin:/usr/local/bin:${PATH}"

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

PORT="${PORT:-18080}"
WORKERS="${WORKERS:-8}"
BENCH_C="${BENCH_C:-100}"
BENCH_N="${BENCH_N:-50000}"
BENCH_Z="${BENCH_Z:-10s}"
WARMUP_Z="${WARMUP_Z:-2s}"
SERVERS="${SERVERS:-ntex drogon asio laytan proactr}"
SKIP_HEAVY="${SKIP_HEAVY:-1}"
LOGDIR="${LOGDIR:-/tmp/proactr-empty-ok}"
mkdir -p "$LOGDIR"

export PORT WORKERS

have() { command -v "$1" >/dev/null 2>&1; }

if ! have oha && ! have bombardier && ! have wrk; then
  echo "Need oha, bombardier, or wrk on PATH" >&2
  exit 1
fi

bench_url() {
  local name="$1"
  local url="http://127.0.0.1:${PORT}/"
  echo "--- bench $name → $url (c=$BENCH_C workers=$WORKERS) ---"
  if have bombardier; then
    if [[ -n "${WARMUP_Z}" && "${WARMUP_Z}" != "0" ]]; then
      bombardier -c "$BENCH_C" -d "$WARMUP_Z" "$url" >/dev/null 2>&1 || true
    fi
    bombardier -c "$BENCH_C" -d "$BENCH_Z" --latencies "$url" | tee "$LOGDIR/${name}.bombardier.txt"
  elif have oha; then
    oha -n "$BENCH_N" -c "$BENCH_C" --no-tui "$url" | tee "$LOGDIR/${name}.oha.txt"
  else
    wrk -t4 -c "$BENCH_C" -d "$BENCH_Z" "$url" | tee "$LOGDIR/${name}.wrk.txt"
  fi
}

wait_port() {
  local i
  for i in $(seq 1 80); do
    if have nc; then
      nc -z 127.0.0.1 "$PORT" 2>/dev/null && return 0
    elif have curl; then
      curl -sf -o /dev/null "http://127.0.0.1:${PORT}/" 2>/dev/null && return 0
    else
      (echo >/dev/tcp/127.0.0.1/"$PORT") 2>/dev/null && return 0
    fi
    sleep 0.1
  done
  return 1
}

kill_port() {
  if have fuser; then
    fuser -k "${PORT}/tcp" 2>/dev/null || true
  elif have lsof; then
    lsof -tiTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | xargs -r kill 2>/dev/null || true
  fi
  sleep 0.2
}

run_peer() {
  local name="$1"
  shift
  kill_port
  echo "==> starting $name (WORKERS=$WORKERS): $*"
  env PORT="$PORT" WORKERS="$WORKERS" "$@" >"$LOGDIR/${name}.server.log" 2>&1 &
  local pid=$!
  if ! wait_port; then
    echo "FAIL: $name did not bind :$PORT" | tee "$LOGDIR/${name}.fail.txt"
    head -20 "$LOGDIR/${name}.server.log" 2>/dev/null || true
    kill "$pid" 2>/dev/null || true
    return 1
  fi
  head -3 "$LOGDIR/${name}.server.log" 2>/dev/null || true
  bench_url "$name" || true
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  kill_port
}

build_proactr() {
  echo "==> build proactr empty-ok"
  odin build "$DIR/proactr" -out:"$DIR/proactr/server.bin" -o:speed
}

build_laytan() {
  echo "==> build laytan empty-ok"
  odin build "$DIR/laytan" -out:"$DIR/laytan/server.bin" -o:speed \
    -collection:laytan="$ROOT/vendor/laytan"
}

echo "ROOT=$ROOT PORT=$PORT WORKERS=$WORKERS SERVERS=$SERVERS logs=$LOGDIR"

for s in $SERVERS; do
  case "$s" in
    ntex)
      if [[ -f ntex/Cargo.toml ]]; then
        (cd ntex && cargo build --release)
        run_peer ntex ./ntex/target/release/ntex-empty-ok
      else
        echo "skip ntex (no crate)"
      fi
      ;;
    compio)
      if [[ -f compio/Cargo.toml ]]; then
        (cd compio && cargo build --release)
        # Single accept-loop baseline — WORKERS env ignored by peer.
        run_peer compio ./compio/target/release/compio-empty-ok
      else
        echo "skip compio"
      fi
      ;;
    drogon)
      if [[ -x drogon/build/drogon_empty_ok ]]; then
        run_peer drogon ./drogon/build/drogon_empty_ok
      elif [[ -f drogon/CMakeLists.txt ]]; then
        echo "skip drogon (build comparisons/empty-ok/drogon first)"
      else
        echo "skip drogon"
      fi
      ;;
    asio)
      if [[ -x asio/asio_empty_ok ]]; then
        # Single-thread io_context baseline — WORKERS env ignored by peer.
        run_peer asio ./asio/asio_empty_ok
      else
        echo "skip asio (build comparisons/empty-ok/asio first)"
      fi
      ;;
    laytan)
      build_laytan
      run_peer laytan ./laytan/server.bin
      ;;
    proactr)
      build_proactr
      run_peer proactr ./proactr/server.bin
      ;;
    seastar)
      if [[ "$SKIP_HEAVY" == "1" ]]; then echo "skip seastar (SKIP_HEAVY=1)"; continue; fi
      echo "seastar peer: build not automated yet"
      ;;
    envoy)
      if [[ "$SKIP_HEAVY" == "1" ]]; then echo "skip envoy (SKIP_HEAVY=1)"; continue; fi
      echo "envoy peer: config under envoy/ — not automated yet"
      ;;
    *)
      echo "unknown server: $s" >&2
      ;;
  esac
done

echo "Done. Logs in $LOGDIR"
