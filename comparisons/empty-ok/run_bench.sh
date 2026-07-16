#!/usr/bin/env bash
# empty-ok multi-peer harness (baseline scaffolding).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

PORT="${PORT:-18080}"
BENCH_C="${BENCH_C:-100}"
BENCH_N="${BENCH_N:-50000}"
BENCH_Z="${BENCH_Z:-10s}"
SERVERS="${SERVERS:-ntex drogon asio laytan proactr}"
SKIP_HEAVY="${SKIP_HEAVY:-1}"
LOGDIR="${LOGDIR:-/tmp/proactr-empty-ok}"
mkdir -p "$LOGDIR"

have() { command -v "$1" >/dev/null 2>&1; }

bench_url() {
  local name="$1"
  local url="http://127.0.0.1:${PORT}/"
  echo "--- bench $name → $url (c=$BENCH_C) ---"
  if have oha; then
    oha -n "$BENCH_N" -c "$BENCH_C" --no-tui "$url" | tee "$LOGDIR/${name}.oha.txt"
  elif have wrk; then
    wrk -t4 -c "$BENCH_C" -d "$BENCH_Z" "$url" | tee "$LOGDIR/${name}.wrk.txt"
  else
    echo "install oha or wrk" >&2
    return 1
  fi
}

wait_port() {
  local i
  for i in $(seq 1 50); do
    if have nc; then
      nc -z 127.0.0.1 "$PORT" 2>/dev/null && return 0
    else
      (echo >/dev/tcp/127.0.0.1/"$PORT") 2>/dev/null && return 0
    fi
    sleep 0.1
  done
  return 1
}

kill_port() {
  if have lsof; then
    lsof -tiTCP:"$PORT" -sTCP:LISTEN | xargs -r kill 2>/dev/null || true
  fi
  sleep 0.2
}

run_peer() {
  local name="$1"
  shift
  kill_port
  echo "==> starting $name: $*"
  "$@" >"$LOGDIR/${name}.server.log" 2>&1 &
  local pid=$!
  if ! wait_port; then
    echo "FAIL: $name did not bind :$PORT" | tee "$LOGDIR/${name}.fail.txt"
    kill "$pid" 2>/dev/null || true
    return 1
  fi
  bench_url "$name" || true
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  kill_port
}

echo "ROOT=$ROOT PORT=$PORT SERVERS=$SERVERS logs=$LOGDIR"

for s in $SERVERS; do
  case "$s" in
    ntex)
      if [[ -x ntex/target/release/ntex-empty-ok ]]; then
        run_peer ntex env PORT="$PORT" ./ntex/target/release/ntex-empty-ok
      elif [[ -f ntex/Cargo.toml ]]; then
        (cd ntex && cargo build --release)
        run_peer ntex env PORT="$PORT" ./ntex/target/release/ntex-empty-ok
      else
        echo "skip ntex (no crate)"
      fi
      ;;
    compio)
      if [[ -f compio/Cargo.toml ]]; then
        (cd compio && cargo build --release)
        run_peer compio env PORT="$PORT" ./compio/target/release/compio-empty-ok
      else
        echo "skip compio"
      fi
      ;;
    drogon)
      if [[ -x drogon/build/drogon_empty_ok ]]; then
        run_peer drogon env PORT="$PORT" ./drogon/build/drogon_empty_ok
      else
        echo "skip drogon (build comparisons/empty-ok/drogon first)"
      fi
      ;;
    asio)
      if [[ -x asio/asio_empty_ok ]]; then
        run_peer asio env PORT="$PORT" ./asio/asio_empty_ok
      else
        echo "skip asio (build comparisons/empty-ok/asio first)"
      fi
      ;;
    laytan)
      if [[ -x laytan/server.bin ]]; then
        run_peer laytan env PORT="$PORT" ./laytan/server.bin
      else
        echo "skip laytan (odin build comparisons/empty-ok/laytan once vendor exists)"
      fi
      ;;
    proactr)
      if [[ -x proactr/server.bin ]]; then
        run_peer proactr env PORT="$PORT" ./proactr/server.bin
      else
        echo "skip proactr (host scaffold — not live yet)"
      fi
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
