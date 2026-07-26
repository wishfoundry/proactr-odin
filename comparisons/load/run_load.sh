#!/usr/bin/env bash
# Product-readiness load scenarios with pass/fail SLOs.
# See SCENARIOS.md.
set -euo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:${HOME}/.cargo/bin:${HOME}/go/bin:/usr/local/bin:${PATH}"

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TFB="$(cd "$(dirname "$0")/../tfb" && pwd)"
cd "$TFB"

PORT="${PORT:-18080}"
WORKERS="${WORKERS:-8}"
PEER="${PEER:-proactr}"
DATABASE_PATH="${DATABASE_PATH:-/tmp/proactr-tfb.sqlite}"
LOGDIR="${LOGDIR:-/tmp/proactr-load-logs}"
# Default readiness pack (no long soak unless requested)
SCENARIOS="${SCENARIOS:-api_steady api_busy payload_medium payload_bulk spike ramp mixed}"
SLO_STRICT_RPS="${SLO_STRICT_RPS:-0}"
mkdir -p "$LOGDIR"

export DATABASE_PATH PORT WORKERS

have() { command -v "$1" >/dev/null 2>&1; }

if ! have bombardier && ! have oha; then
  echo "Need bombardier or oha on PATH" >&2
  exit 1
fi

kill_port() {
  local p="${1:-$PORT}"
  if have fuser; then
    fuser -k "${p}/tcp" 2>/dev/null || true
  elif have lsof; then
    lsof -tiTCP:"$p" -sTCP:LISTEN 2>/dev/null | xargs -r kill -9 2>/dev/null || true
  fi
  sleep 0.3
}

wait_up() {
  local path="${1:-/plaintext}"
  local i code
  for i in $(seq 1 80); do
    code=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${PORT}${path}" 2>/dev/null || echo 000)
    [[ "$code" == "200" ]] && return 0
    sleep 0.1
  done
  return 1
}

start_peer() {
  kill_port "$PORT"
  case "$PEER" in
    proactr)
      if [[ ! -x proactr/tfb-proactr.bin ]]; then
        echo "building proactr…"
        odin build proactr -out:proactr/tfb-proactr.bin -o:speed
      fi
      env PORT="$PORT" WORKERS="$WORKERS" DATABASE_PATH="$DATABASE_PATH" \
        ./proactr/tfb-proactr.bin >"$LOGDIR/server.log" 2>&1 &
      echo $! >"$LOGDIR/server.pid"
      ;;
    ntex)
      [[ -x ntex/target/release/ntex-tfb ]] || (cd ntex && cargo build --release)
      env PORT="$PORT" WORKERS="$WORKERS" DATABASE_PATH="$DATABASE_PATH" \
        ./ntex/target/release/ntex-tfb >"$LOGDIR/server.log" 2>&1 &
      echo $! >"$LOGDIR/server.pid"
      ;;
    laytan)
      [[ -x laytan/tfb-laytan ]] || (cd laytan && odin build . -out:tfb-laytan -o:speed \
        -collection:laytan="$ROOT/vendor/laytan")
      env PORT="$PORT" WORKERS="$WORKERS" \
        ./laytan/tfb-laytan >"$LOGDIR/server.log" 2>&1 &
      echo $! >"$LOGDIR/server.pid"
      ;;
    drogon)
      [[ -x drogon/build/drogon_tfb ]] || ./drogon/build.sh
      env PORT="$PORT" WORKERS="$WORKERS" DATABASE_PATH="$DATABASE_PATH" \
        ./drogon/build/drogon_tfb >"$LOGDIR/server.log" 2>&1 &
      echo $! >"$LOGDIR/server.pid"
      ;;
    *)
      echo "unknown PEER=$PEER (proactr|ntex|laytan|drogon)" >&2
      exit 1
      ;;
  esac
  if ! wait_up /plaintext; then
    echo "FAIL: $PEER did not serve /plaintext" | tee "$LOGDIR/fail.txt"
    head -30 "$LOGDIR/server.log" || true
    return 1
  fi
  head -3 "$LOGDIR/server.log" || true
}

stop_peer() {
  if [[ -f "$LOGDIR/server.pid" ]]; then
    kill "$(cat "$LOGDIR/server.pid")" 2>/dev/null || true
    wait "$(cat "$LOGDIR/server.pid")" 2>/dev/null || true
    rm -f "$LOGDIR/server.pid"
  fi
  kill_port "$PORT"
}

# Parse bombardier or oha output → metrics file
# Sets: RPS P99_MS ERR_N OK_N
parse_load_out() {
  local f="$1"
  RPS="0"; P99_MS="0"; ERR_N="0"; OK_N="0"
  if grep -q 'Reqs/sec' "$f" 2>/dev/null; then
    # bombardier
    RPS=$(awk '/Reqs\/sec/ {print $2; exit}' "$f")
    # latency line "99%    21.72ms" or "99%   263.00us"
    local lat
    lat=$(awk '/99%/ {print $2; exit}' "$f")
    P99_MS=$(python3 - "$lat" <<'PY'
import sys
s=sys.argv[1].strip().lower()
if s.endswith("us"):
  print(float(s[:-2])/1000.0)
elif s.endswith("ms"):
  print(float(s[:-2]))
elif s.endswith("s") and not s.endswith("ms"):
  print(float(s[:-1])*1000.0)
else:
  try: print(float(s))
  except: print(0)
PY
)
    OK_N=$(grep -oE '2xx - [0-9]+' "$f" | head -1 | awk '{print $3}')
    OK_N=${OK_N:-0}
    local o4 o5 others
    o4=$(grep -oE '4xx - [0-9]+' "$f" | head -1 | awk '{print $3}'); o4=${o4:-0}
    o5=$(grep -oE '5xx - [0-9]+' "$f" | head -1 | awk '{print $3}'); o5=${o5:-0}
    others=$(grep -oE 'others - [0-9]+' "$f" | head -1 | awk '{print $3}'); others=${others:-0}
    ERR_N=$((o4 + o5 + others))
  elif grep -qi 'Requests/sec' "$f" 2>/dev/null; then
    RPS=$(awk '/Requests\/sec/ {print $2; exit}' "$f")
    P99_MS=$(awk '/99%/ {print $2; exit}' "$f" | sed 's/ms//')
    OK_N=0
    ERR_N=0
  fi
  RPS=${RPS:-0}
  P99_MS=${P99_MS:-0}
  ERR_N=${ERR_N:-0}
  OK_N=${OK_N:-0}
}

run_bombardier() {
  local url="$1" c="$2" dur="$3" out="$4"
  if have bombardier; then
    # short warm
    bombardier -c "$c" -d 2s "$url" >/dev/null 2>&1 || true
    bombardier -c "$c" -d "$dur" --latencies "$url" >"$out" 2>&1
  else
    oha -z 2s -c "$c" --no-tui "$url" >/dev/null 2>&1 || true
    oha -z "$dur" -c "$c" --no-tui "$url" >"$out" 2>&1
  fi
}

alive() {
  if [[ -f "$LOGDIR/server.pid" ]]; then
    kill -0 "$(cat "$LOGDIR/server.pid")" 2>/dev/null
  else
    return 1
  fi
}

# check_slo name p99_budget_ms min_rps
check_slo() {
  local name="$1" p99_budget="$2" min_rps="$3"
  local fail=0
  local note=""

  if ! alive; then
    echo "  FAIL $name: server process dead"
    return 1
  fi
  if [[ "$(python3 -c "print(1 if float('$ERR_N')>0 else 0)")" == "1" ]]; then
    echo "  FAIL $name: errors=$ERR_N (non-2xx/others)"
    fail=1
  fi
  if [[ "$(python3 -c "print(1 if float('$P99_MS')>float('$p99_budget') else 0)")" == "1" ]]; then
    echo "  FAIL $name: p99=${P99_MS}ms > budget ${p99_budget}ms"
    fail=1
  fi
  if [[ "$(python3 -c "print(1 if float('$RPS')<float('$min_rps') else 0)")" == "1" ]]; then
    if [[ "$SLO_STRICT_RPS" == "1" ]]; then
      echo "  FAIL $name: rps=$RPS < floor $min_rps"
      fail=1
    else
      note=" WARN rps=$RPS < soft floor $min_rps"
    fi
  fi
  if [[ "$fail" -eq 0 ]]; then
    echo "  PASS $name: rps=$RPS p99=${P99_MS}ms err=$ERR_N ok≈$OK_N$note"
    return 0
  fi
  return 1
}

run_one() {
  local name="$1" path="$2" c="$3" dur="$4" p99_budget="$5" min_rps="$6"
  local url="http://127.0.0.1:${PORT}${path}"
  local out="$LOGDIR/${name}.load.txt"
  echo "==> $name path=$path c=$c z=$dur p99≤${p99_budget}ms rps≥${min_rps} (strict_rps=$SLO_STRICT_RPS)"
  run_bombardier "$url" "$c" "$dur" "$out"
  parse_load_out "$out"
  # save metrics line
  echo "$name rps=$RPS p99_ms=$P99_MS err=$ERR_N ok=$OK_N" | tee -a "$LOGDIR/metrics.txt"
  check_slo "$name" "$p99_budget" "$min_rps"
}

run_ramp() {
  local fail=0
  # c → p99 budget ms, soft min rps
  local steps="20:5:20000 50:8:40000 100:15:80000 200:25:100000"
  echo "==> ramp /plaintext stepped concurrency"
  for step in $steps; do
    local c p99 minr
    c=${step%%:*}; rest=${step#*:}; p99=${rest%%:*}; minr=${rest#*:}
    if ! run_one "ramp_c${c}" "/plaintext" "$c" "15s" "$p99" "$minr"; then
      fail=1
    fi
  done
  return $fail
}

run_mixed() {
  local total_s=60
  local fail=0
  # path:share_seconds of 60
  local phases="/plaintext:30 /s/4k:15 /s/64k:9 /s/1m:6"
  echo "==> mixed weighted phases (total ~${total_s}s, c=50)"
  for ph in $phases; do
    local path secs
    path=${ph%%:*}; secs=${ph#*:}
    local p99=20 minr=1000
    case "$path" in
      /plaintext) p99=10; minr=30000 ;;
      /s/4k) p99=15; minr=10000 ;;
      /s/64k) p99=30; minr=5000 ;;
      /s/1m) p99=120; minr=500 ;;
    esac
    local tag="mixed_${path//\//_}"
    if ! run_one "$tag" "$path" 50 "${secs}s" "$p99" "$minr"; then
      fail=1
    fi
  done
  return $fail
}

# --- main ---
FAILED=0
PASSED=0
RAN=0

echo "=== proactr load / readiness ==="
echo "peer=$PEER port=$PORT workers=$WORKERS scenarios=$SCENARIOS logs=$LOGDIR"
echo "strict_rps=$SLO_STRICT_RPS"
echo

if [[ ! -f "$DATABASE_PATH" ]]; then
  DATABASE_PATH="$DATABASE_PATH" ./schema/prepare.sh || true
fi

start_peer
trap 'stop_peer' EXIT

for sc in $SCENARIOS; do
  RAN=$((RAN + 1))
  ok=0
  case "$sc" in
    api_steady)
      run_one api_steady /plaintext 50 30s 5 50000 && ok=1
      ;;
    api_busy)
      run_one api_busy /plaintext 200 30s 15 100000 && ok=1
      ;;
    payload_medium)
      run_one payload_medium /s/64k 50 30s 20 20000 && ok=1
      ;;
    payload_bulk)
      run_one payload_bulk /s/1m 20 30s 100 1000 && ok=1
      ;;
    spike)
      run_one spike /plaintext 500 10s 50 0 && ok=1
      ;;
    soak)
      run_one soak /plaintext 50 5m 10 30000 && ok=1
      ;;
    ramp)
      run_ramp && ok=1
      ;;
    mixed)
      run_mixed && ok=1
      ;;
    *)
      echo "unknown scenario: $sc" >&2
      ok=0
      ;;
  esac
  if [[ "$ok" -eq 1 ]]; then
    PASSED=$((PASSED + 1))
  else
    FAILED=$((FAILED + 1))
  fi
  echo
done

echo "=== summary ==="
echo "ran=$RAN passed=$PASSED failed=$FAILED"
echo "metrics: $LOGDIR/metrics.txt"
echo "detail:  $LOGDIR/*.load.txt"

if [[ "$FAILED" -gt 0 ]]; then
  exit 1
fi
exit 0
