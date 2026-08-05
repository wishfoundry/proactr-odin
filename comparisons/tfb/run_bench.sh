#!/usr/bin/env bash
# Full TFB harness: size ladder + fortunes across uring + epoll peers (+ optional envoy).
set -euo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:${HOME}/.cargo/bin:${HOME}/go/bin:/usr/local/bin:${PATH}"

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

PORT="${PORT:-18080}"
UPSTREAM_PORT="${UPSTREAM_PORT:-18081}"
WORKERS="${WORKERS:-8}"
BENCH_C="${BENCH_C:-100}"
BENCH_Z="${BENCH_Z:-15s}"
WARMUP_Z="${WARMUP_Z:-3s}"
DATABASE_PATH="${DATABASE_PATH:-/tmp/proactr-tfb.sqlite}"
# Full app-server matrix (uring + epoll). Envoy/seastar opt-in.
if [[ "$(uname -s)" == "Linux" ]]; then
  SERVERS="${SERVERS:-ntex ntex-compio compio asio laytan go drogon}"
else
  SERVERS="${SERVERS:-ntex go}"
fi
TESTS="${TESTS:-plaintext s4k s64k s1m s4m fortunes}"
LOGDIR="${LOGDIR:-/tmp/proactr-tfb-logs}"
REQUIRE_URING="${REQUIRE_URING:-0}"
mkdir -p "$LOGDIR"

export DATABASE_PATH PORT WORKERS

have() { command -v "$1" >/dev/null 2>&1; }

if [[ "$(uname -s)" == "Linux" && "${REQUIRE_URING}" == "1" ]]; then
  "$ROOT/scripts/check_io_uring.sh" | tee "$LOGDIR/io_uring_check.txt" || true
fi

if [[ ! -f "$DATABASE_PATH" ]]; then
  DATABASE_PATH="$DATABASE_PATH" ./schema/prepare.sh
fi

if ! have oha && ! have bombardier && ! have wrk; then
  echo "Need oha, bombardier, or wrk" >&2
  exit 1
fi

kill_port() {
  local p="${1:-$PORT}"
  if have lsof; then
    lsof -tiTCP:"$p" -sTCP:LISTEN 2>/dev/null | xargs -r kill -9 2>/dev/null || true
  fi
  sleep 0.25
}

wait_up() {
  local p="${1:-$PORT}"
  local i code
  for i in $(seq 1 120); do
    code=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${p}/plaintext" 2>/dev/null || echo 000)
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
    s4k) echo /s/4k ;;
    s64k) echo /s/64k ;;
    s1m) echo /s/1m ;;
    s4m) echo /s/4m ;;
    fortunes) echo /fortunes ;;
    *) echo "/$1" ;;
  esac
}

# Exact size-ladder body lengths (bytes). Fortunes is HTML (variable; only 200 + non-empty).
expected_body_len() {
  case "$1" in
    plaintext) echo 13 ;;
    s4k) echo 4096 ;;
    s64k) echo 65536 ;;
    s1m) echo 1048576 ;;
    s4m) echo 4194304 ;;
    *) echo "" ;;
  esac
}

# Fail closed if a peer returns wrong body size (prevents silent RPS inflation).
verify_peer_bodies() {
  local name="$1"
  local t path exp got code
  for t in $TESTS; do
    path="$(path_for_test "$t")"
    if [[ "$t" == "fortunes" ]]; then
      if [[ "$name" == "laytan" ]]; then
        continue
      fi
      code=$(curl -s -o /tmp/tfb_body_check.$$ -w "%{http_code}" "http://127.0.0.1:${PORT}${path}" || echo 000)
      got=$(wc -c </tmp/tfb_body_check.$$ 2>/dev/null | tr -d ' ' || echo 0)
      rm -f /tmp/tfb_body_check.$$
      if [[ "$code" != "200" || "${got:-0}" -lt 200 ]]; then
        echo "FAIL body-check $name $t: http=$code bytes=$got (need 200 and HTML)" >&2
        return 1
      fi
      continue
    fi
    exp="$(expected_body_len "$t")"
    [[ -z "$exp" ]] && continue
    code=$(curl -s -o /tmp/tfb_body_check.$$ -w "%{http_code}" "http://127.0.0.1:${PORT}${path}" || echo 000)
    got=$(wc -c </tmp/tfb_body_check.$$ 2>/dev/null | tr -d ' ' || echo 0)
    rm -f /tmp/tfb_body_check.$$
    if [[ "$code" != "200" || "$got" != "$exp" ]]; then
      echo "FAIL body-check $name $t: http=$code bytes=$got expected=$exp" >&2
      return 1
    fi
  done
  echo "  body-check ok ($name)"
  return 0
}

run_load() {
  local name="$1" test="$2"
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
    # Same warmup as oha so cold vs hot does not favor first peer only.
    bombardier -c "$BENCH_C" -d "$WARMUP_Z" "$url" >/dev/null 2>&1 || true
    bombardier -c "$BENCH_C" -d "$BENCH_Z" "$url" | tee "$out"
  else
    wrk -t2 -c "$BENCH_C" -d "$WARMUP_Z" "$url" >/dev/null 2>&1 || true
    wrk -t4 -c "$BENCH_C" -d "$BENCH_Z" "$url" | tee "$out"
  fi
}

rps_from() {
  awk '/Requests\/sec/ {print $2; exit} /Reqs\/sec/ {print $2; exit}' "$1" 2>/dev/null || echo "?"
}

lat_from() {
  awk '/Latency/ {print $2; exit}' "$1" 2>/dev/null || echo "?"
}

# oha "Size/request" (bytes). Unit is often $3 ("KiB"/"MiB") with numeric $2.
size_from() {
  awk '/Size\/request/ {
    n=$2; u=$3
    if (n ~ /KiB$/) { sub(/KiB$/,"",n); printf "%.0f", n*1024; exit }
    if (n ~ /MiB$/) { sub(/MiB$/,"",n); printf "%.0f", n*1024*1024; exit }
    if (u == "KiB") { printf "%.0f", n*1024; exit }
    if (u == "MiB") { printf "%.0f", n*1024*1024; exit }
    if (u == "GiB") { printf "%.0f", n*1024*1024*1024; exit }
    if (u == "B" || n ~ /B$/) { gsub(/B/,"",n); printf "%.0f", n; exit }
    printf "%.0f", n; exit
  }' "$1" 2>/dev/null || true
}

# After load: if size ladder and oha Size/request off by >10%, WARN (and mark ? in detail).
check_load_size() {
  local name="$1" test="$2" out="$3"
  local exp got
  exp="$(expected_body_len "$test")"
  [[ -z "$exp" || "$exp" == "0" ]] && return 0
  got="$(size_from "$out")"
  [[ -z "$got" || "$got" == "?" ]] && return 0
  # integer compare with 10% slack (oha may round)
  python3 - "$exp" "$got" <<'PY' || true
import sys
exp, got = float(sys.argv[1]), float(sys.argv[2])
if exp <= 0: sys.exit(0)
err = abs(got - exp) / exp
if err > 0.10:
    print(f"  WARN size-mismatch {sys.argv[0] if False else ''}: oha Size/request={got:.0f} expected={exp:.0f} (RPS may still be valid; verify manually)", file=sys.stderr)
    sys.exit(1)
sys.exit(0)
PY
}

start_peer() {
  local name="$1"
  kill_port "$PORT"
  kill_port "$UPSTREAM_PORT"
  ENVOY_UPSTREAM_PID=""
  ENVOY_CID=""
  case "$name" in
    ntex)
      [[ -x ntex/target/release/ntex-tfb ]] || (cd ntex && cargo build --release)
      env DATABASE_PATH="$DATABASE_PATH" PORT="$PORT" WORKERS="$WORKERS" \
        ./ntex/target/release/ntex-tfb >"$LOGDIR/ntex.server.log" 2>&1 &
      ;;
    ntex-compio)
      [[ -x ntex-compio/target/release/ntex-compio-tfb ]] || (cd ntex-compio && cargo build --release)
      env DATABASE_PATH="$DATABASE_PATH" PORT="$PORT" WORKERS="$WORKERS" \
        ./ntex-compio/target/release/ntex-compio-tfb >"$LOGDIR/ntex-compio.server.log" 2>&1 &
      ;;
    compio)
      [[ -x compio/target/release/compio-tfb ]] || (cd compio && cargo build --release)
      env DATABASE_PATH="$DATABASE_PATH" PORT="$PORT" WORKERS="$WORKERS" \
        ./compio/target/release/compio-tfb >"$LOGDIR/compio.server.log" 2>&1 &
      ;;
    asio)
      [[ -x asio/asio_tfb ]] || ./asio/build.sh
      env DATABASE_PATH="$DATABASE_PATH" PORT="$PORT" \
        ./asio/asio_tfb >"$LOGDIR/asio.server.log" 2>&1 &
      ;;
    laytan)
      [[ -x laytan/tfb-laytan ]] || (cd laytan && odin build . -out:tfb-laytan -o:speed \
        -collection:laytan="$ROOT/vendor/laytan")
      env PORT="$PORT" WORKERS="$WORKERS" \
        ./laytan/tfb-laytan >"$LOGDIR/laytan.server.log" 2>&1 &
      ;;
    go)
      [[ -x go/tfb-go ]] || (cd go && go build -o tfb-go .)
      env DATABASE_PATH="$DATABASE_PATH" PORT="$PORT" WORKERS="$WORKERS" \
        ./go/tfb-go >"$LOGDIR/go.server.log" 2>&1 &
      ;;
    drogon)
      if [[ ! -x drogon/build/drogon_tfb ]]; then
        ./drogon/build.sh || return 1
      fi
      env DATABASE_PATH="$DATABASE_PATH" PORT="$PORT" WORKERS="$WORKERS" \
        ./drogon/build/drogon_tfb >"$LOGDIR/drogon.server.log" 2>&1 &
      ;;
    envoy)
      if ! have docker; then
        echo "envoy needs docker"; return 1
      fi
      [[ -x ntex/target/release/ntex-tfb ]] || (cd ntex && cargo build --release)
      env DATABASE_PATH="$DATABASE_PATH" PORT="$UPSTREAM_PORT" WORKERS="$WORKERS" \
        ./ntex/target/release/ntex-tfb >"$LOGDIR/envoy-upstream.server.log" 2>&1 &
      ENVOY_UPSTREAM_PID=$!
      if ! wait_up "$UPSTREAM_PORT"; then
        echo "envoy upstream failed"; return 1
      fi
      # rewrite yaml port if needed — use stock yaml (18080 + upstream 18081)
      ENVOY_CID=$(docker run -d --rm --network host \
        -v "$HERE/envoy/envoy.yaml:/etc/envoy/envoy.yaml:ro" \
        envoyproxy/envoy:v1.31-latest -c /etc/envoy/envoy.yaml 2>"$LOGDIR/envoy.docker.err" || true)
      if [[ -z "$ENVOY_CID" ]]; then
        echo "envoy docker failed"; cat "$LOGDIR/envoy.docker.err" || true
        kill "$ENVOY_UPSTREAM_PID" 2>/dev/null || true
        return 1
      fi
      echo "$ENVOY_CID" >"$LOGDIR/envoy.cid"
      # wait for proxy
      if ! wait_up "$PORT"; then
        docker kill "$ENVOY_CID" 2>/dev/null || true
        kill "$ENVOY_UPSTREAM_PID" 2>/dev/null || true
        return 1
      fi
      # fake pid for harness — use upstream pid; cleanup special-cased
      echo "$ENVOY_UPSTREAM_PID"
      return 0
      ;;
    seastar)
      if [[ ! -x seastar/build/seastar_tfb ]]; then
        ./seastar/build.sh || return 1
      fi
      # -c: shard count from WORKERS
      env DATABASE_PATH="$DATABASE_PATH" PORT="$PORT" \
        ./seastar/build/seastar_tfb -c"$WORKERS" \
        --port="$PORT" --db="$DATABASE_PATH" \
        >"$LOGDIR/seastar.server.log" 2>&1 &
      ;;
    proactr|proactr-sync)
      if [[ ! -x proactr/tfb-proactr.bin ]]; then
        (cd proactr && odin build . -out:tfb-proactr.bin -o:speed) || return 1
      fi
      # FORTUNES_SYNC_SHARED=1 → ntex-like one conn+mutex; default = per-worker conn.
      env DATABASE_PATH="$DATABASE_PATH" PORT="$PORT" WORKERS="$WORKERS" \
        FORTUNES_MODE=sync FORTUNES_SYNC_SHARED="${FORTUNES_SYNC_SHARED:-0}" \
        ./proactr/tfb-proactr.bin >"$LOGDIR/${name}.server.log" 2>&1 &
      ;;
    proactr-async)
      if [[ ! -x proactr/tfb-proactr.bin ]]; then
        (cd proactr && odin build . -out:tfb-proactr.bin -o:speed) || return 1
      fi
      # DB_WORKERS defaults to WORKERS inside the peer; override with DB_WORKERS=N.
      env DATABASE_PATH="$DATABASE_PATH" PORT="$PORT" WORKERS="$WORKERS" \
        FORTUNES_MODE=async DB_WORKERS="${DB_WORKERS:-$WORKERS}" \
        ./proactr/tfb-proactr.bin >"$LOGDIR/proactr-async.server.log" 2>&1 &
      ;;
    *)
      echo "unknown peer $name" >&2; return 1
      ;;
  esac
  local pid=$!
  if ! wait_up "$PORT"; then
    echo "FAIL start $name (log $LOGDIR/${name}.server.log)"
    kill "$pid" 2>/dev/null || true
    return 1
  fi
  echo "$pid"
}

stop_peer() {
  local name="$1" pid="${2:-}"
  if [[ "$name" == "envoy" ]]; then
    if [[ -f "$LOGDIR/envoy.cid" ]]; then
      docker kill "$(cat "$LOGDIR/envoy.cid")" 2>/dev/null || true
      rm -f "$LOGDIR/envoy.cid"
    fi
    kill_port "$UPSTREAM_PORT"
  fi
  [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  kill_port "$PORT"
}

# Ceiling noise: short runs are not comparable (CRITIC).
case "$BENCH_Z" in
  *ms|*s|*m|*h) ;;
  *) echo "WARN: BENCH_Z=$BENCH_Z unparsed; prefer >=10s" >&2 ;;
esac
if [[ "$BENCH_Z" =~ ^([0-9]+)s$ ]] && (( BASH_REMATCH[1] < 10 )); then
  echo "WARN: BENCH_Z=$BENCH_Z <10s — not a ceiling; noise-dominated" >&2
fi

echo "=== proactr-odin TFB (size ladder + fortunes) ==="
echo "host=$(uname -s) $(uname -m) kernel=$(uname -r 2>/dev/null || true)"
echo "db=$DATABASE_PATH port=$PORT workers=$WORKERS c=$BENCH_C z=$BENCH_Z warmup=$WARMUP_Z"
echo "servers=$SERVERS"
echo "tests=$TESTS"
echo "logs=$LOGDIR"
echo "backends: proactr=io_uring(Linux) laytan=nbio/io_uring ntex=neon-uring drogon=epoll(trantor)"
echo "proactr size-ladder wire: materialize (plan_optimize=false) — not kernel writev/sendfile"
echo "fortunes app work is NOT equal across peers — see WORKLOAD.md / run_peer_matrix.sh notes"
echo ""

# matrix header
SUMMARY="$LOGDIR/summary.tsv"
{
  printf 'peer'
  for t in $TESTS; do printf '\t%s' "$t"; done
  printf '\n'
} | tee "$SUMMARY"

DETAIL="$LOGDIR/detail.txt"
: >"$DETAIL"

for srv in $SERVERS; do
  echo "==> peer $srv"
  pid=""
  if ! pid=$(start_peer "$srv"); then
    echo "  (skip $srv)"
    {
      printf '%s' "$srv"
      for t in $TESTS; do printf '\tskip'; done
      printf '\n'
    } | tee -a "$SUMMARY"
    continue
  fi
  # Reject wrong body sizes before burning BENCH_Z (CRITIC: different bodies = fake).
  if ! verify_peer_bodies "$srv"; then
    echo "  (skip $srv — body-check failed)"
    {
      printf '%s' "$srv"
      for t in $TESTS; do printf '\tbody-fail'; done
      printf '\n'
    } | tee -a "$SUMMARY"
    stop_peer "$srv" "$pid"
    continue
  fi
  row="$srv"
  for t in $TESTS; do
    # laytan fortunes still 501; proactr-sync / proactr-async implement /fortunes.
    if [[ "$srv" == "laytan" && "$t" == "fortunes" ]]; then
      echo "  skip fortunes (501)"
      row+=$'\tn/a'
      echo "$srv $t n/a" >>"$DETAIL"
      continue
    fi
    run_load "$srv" "$t" || true
    rps=$(rps_from "$LOGDIR/${srv}_${t}.txt")
    lat=$(lat_from "$LOGDIR/${srv}_${t}.txt")
    sz=$(size_from "$LOGDIR/${srv}_${t}.txt")
    if ! check_load_size "$srv" "$t" "$LOGDIR/${srv}_${t}.txt"; then
      echo "$srv $t SIZE_WARN oha_size=$sz" >>"$DETAIL"
    fi
    row+=$'\t'"$rps"
    echo "$srv $t rps=$rps lat_avg=$lat oha_size=${sz:-?}" | tee -a "$DETAIL"
  done
  printf '%s\n' "$row" | tee -a "$SUMMARY"
  stop_peer "$srv" "$pid"
done

echo ""
echo "=== RPS matrix (columns = tests) ==="
column -t -s $'\t' "$SUMMARY" 2>/dev/null || cat "$SUMMARY"
echo ""
echo "Detail: $DETAIL"
echo "Logs: $LOGDIR"
