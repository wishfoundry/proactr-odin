#!/usr/bin/env bash
# Planner A/B harness: materialize vs optimize shadow policy + iso load.
# See comparisons/plan/README.md
set -euo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:${HOME}/.cargo/bin:/usr/local/bin:${PATH}"

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

PORT="${PORT:-19090}"
WORKERS="${WORKERS:-2}"
LOGDIR="${LOGDIR:-/tmp/proactr-plan-logs}"
BENCH_C="${BENCH_C:-20}"
BENCH_Z="${BENCH_Z:-5s}"
WARMUP_Z="${WARMUP_Z:-1s}"
SCENARIOS="${SCENARIOS:-iso_tiny iso_gen iso_assembled iso_blob iso_file iso_sse mixed_seq}"
MODES="${MODES:-materialize optimize}"
PLAN_SENDFILE_OK="${PLAN_SENDFILE_OK:-1}"
PLAN_COPY_BUDGET="${PLAN_COPY_BUDGET:-4096}"
PLAN_MAX_IOVECS="${PLAN_MAX_IOVECS:-1024}"
BIN="${BIN:-$HERE/server/plan-bench.bin}"
mkdir -p "$LOGDIR"

have() { command -v "$1" >/dev/null 2>&1; }

if ! have bombardier && ! have oha; then
  echo "Need bombardier or oha on PATH" >&2
  exit 1
fi

kill_port() {
  local p="${1:-$PORT}"
  # Prefer lsof: macOS fuser is not Linux fuser -k PORT/tcp.
  if have lsof; then
    local pids
    pids=$(lsof -tiTCP:"$p" -sTCP:LISTEN 2>/dev/null || true)
    if [[ -n "${pids:-}" ]]; then
      # shellcheck disable=SC2086
      kill -9 $pids 2>/dev/null || true
    fi
  elif have fuser && [[ "$(uname -s)" == "Linux" ]]; then
    fuser -k "${p}/tcp" 2>/dev/null || true
  fi
  sleep 0.25
}

wait_up() {
  local path="${1:-/health}"
  local i code
  for i in $(seq 1 80); do
    code=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${PORT}${path}" 2>/dev/null || echo 000)
    [[ "$code" == "200" ]] && return 0
    sleep 0.1
  done
  return 1
}

build_server() {
  if [[ ! -x "$BIN" ]] || [[ "${FORCE_BUILD:-0}" == "1" ]]; then
    echo "building plan-bench…"
    odin build "$HERE/server" -out:"$BIN" -o:speed
  fi
}

start_server() {
  local mode="$1"
  kill_port "$PORT"
  env PORT="$PORT" WORKERS="$WORKERS" PLAN_MODE="$mode" \
    PLAN_SENDFILE_OK="$PLAN_SENDFILE_OK" \
    PLAN_COPY_BUDGET="$PLAN_COPY_BUDGET" \
    PLAN_MAX_IOVECS="$PLAN_MAX_IOVECS" \
    "$BIN" >"$LOGDIR/server-${mode}.log" 2>&1 &
  echo $! >"$LOGDIR/server.pid"
  if ! wait_up /health; then
    echo "FAIL: server did not come up (mode=$mode)" | tee "$LOGDIR/fail.txt"
    head -40 "$LOGDIR/server-${mode}.log" || true
    return 1
  fi
  head -2 "$LOGDIR/server-${mode}.log" || true
}

stop_server() {
  if [[ -f "$LOGDIR/server.pid" ]]; then
    kill "$(cat "$LOGDIR/server.pid")" 2>/dev/null || true
    wait "$(cat "$LOGDIR/server.pid")" 2>/dev/null || true
    rm -f "$LOGDIR/server.pid"
  fi
  kill_port "$PORT"
}

alive() {
  [[ -f "$LOGDIR/server.pid" ]] && kill -0 "$(cat "$LOGDIR/server.pid")" 2>/dev/null
}

fetch_metrics() {
  local out="$1"
  curl -s "http://127.0.0.1:${PORT}/metrics" >"$out" || true
}

metric() {
  # metric <file> <name>
  local f="$1" name="$2"
  awk -v n="$name" '$1==n {print $2; exit}' "$f" 2>/dev/null || echo 0
}

parse_load_out() {
  local f="$1"
  RPS="0"; P99_MS="0"; ERR_N="0"; OK_N="0"
  if grep -q 'Reqs/sec' "$f" 2>/dev/null; then
    RPS=$(awk '/Reqs\/sec/ {print $2; exit}' "$f")
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
    OK_N=$(grep -oE '2xx - [0-9]+' "$f" | head -1 | awk '{print $3}'); OK_N=${OK_N:-0}
    local o4 o5 others
    o4=$(grep -oE '4xx - [0-9]+' "$f" | head -1 | awk '{print $3}'); o4=${o4:-0}
    o5=$(grep -oE '5xx - [0-9]+' "$f" | head -1 | awk '{print $3}'); o5=${o5:-0}
    others=$(grep -oE 'others - [0-9]+' "$f" | head -1 | awk '{print $3}'); others=${others:-0}
    ERR_N=$((o4 + o5 + others))
  elif grep -qi 'Requests/sec' "$f" 2>/dev/null; then
    RPS=$(awk '/Requests\/sec/ {print $2; exit}' "$f")
    P99_MS=$(awk '/99%/ {print $2; exit}' "$f" | sed 's/ms//')
  fi
  RPS=${RPS:-0}; P99_MS=${P99_MS:-0}; ERR_N=${ERR_N:-0}; OK_N=${OK_N:-0}
}

run_loadgen() {
  local url="$1" c="$2" dur="$3" out="$4"
  if have bombardier; then
    bombardier -c "$c" -d "$WARMUP_Z" "$url" >/dev/null 2>&1 || true
    bombardier -c "$c" -d "$dur" --latencies "$url" >"$out" 2>&1
  else
    oha -z "$WARMUP_Z" -c "$c" --no-tui "$url" >/dev/null 2>&1 || true
    oha -z "$dur" -c "$c" --no-tui "$url" >"$out" 2>&1
  fi
}

path_for() {
  case "$1" in
    iso_tiny) echo /api/tiny ;;
    iso_gen) echo /gen/ok ;;
    iso_assembled) echo /static/assembled ;;
    iso_blob) echo /static/blob/1m ;;
    iso_file) echo /file/1m ;;
    iso_sse) echo /sse ;;
    *) echo "/$1" ;;
  esac
}

c_for() {
  case "$1" in
    iso_blob|iso_file|iso_assembled) echo "${BENCH_C_HEAVY:-10}" ;;
    *) echo "$BENCH_C" ;;
  esac
}

# check_mechanism mode scenario metrics_file
# Sets FAIL=1 on hard mechanism violations.
check_mechanism() {
  local mode="$1" scen="$2" mf="$3"
  local writev sendfile mat stream
  writev=$(metric "$mf" plan_writev_total)
  sendfile=$(metric "$mf" plan_sendfile_total)
  mat=$(metric "$mf" plan_materialize_total)
  stream=$(metric "$mf" stream_responses_total)

  case "$mode" in
    materialize)
      if [[ "$scen" != "iso_sse" ]]; then
        if [[ "$(python3 -c "print(1 if int(float('$writev'))>0 else 0)")" == "1" ]]; then
          echo "  FAIL mechanism: materialize mode saw plan_writev=$writev"
          return 1
        fi
        if [[ "$(python3 -c "print(1 if int(float('$sendfile'))>0 else 0)")" == "1" ]]; then
          echo "  FAIL mechanism: materialize mode saw plan_sendfile=$sendfile"
          return 1
        fi
      fi
      ;;
    optimize)
      case "$scen" in
        iso_assembled)
          if [[ "$(python3 -c "print(1 if int(float('$writev'))<=0 else 0)")" == "1" ]]; then
            echo "  FAIL mechanism: optimize assembled expected plan_writev>0 got $writev"
            return 1
          fi
          echo "  OK mechanism: writev=$writev materialize=$mat"
          ;;
        iso_file)
          if [[ "$(python3 -c "print(1 if int(float('$sendfile'))<=0 else 0)")" == "1" ]]; then
            echo "  FAIL mechanism: optimize file expected plan_sendfile>0 got $sendfile"
            return 1
          fi
          echo "  OK mechanism: sendfile=$sendfile materialize=$mat"
          ;;
        iso_tiny|iso_gen)
          if [[ "$(python3 -c "print(1 if int(float('$writev'))>0 else 0)")" == "1" ]]; then
            echo "  FAIL mechanism: tiny/gen should not writev under optimize (got $writev)"
            return 1
          fi
          if [[ "$(python3 -c "print(1 if int(float('$sendfile'))>0 else 0)")" == "1" ]]; then
            echo "  FAIL mechanism: tiny/gen should not sendfile (got $sendfile)"
            return 1
          fi
          echo "  OK mechanism: materialize=$mat writev=$writev sendfile=$sendfile"
          ;;
        iso_sse)
          if [[ "$(python3 -c "print(1 if int(float('$stream'))<=0 else 0)")" == "1" ]]; then
            echo "  FAIL mechanism: sse expected stream_responses>0"
            return 1
          fi
          echo "  OK mechanism: stream=$stream writev=$writev sendfile=$sendfile"
          ;;
        *)
          echo "  INFO mechanism: writev=$writev sendfile=$sendfile materialize=$mat stream=$stream"
          ;;
      esac
      ;;
  esac
  return 0
}

run_iso() {
  local mode="$1" scen="$2"
  local path c url out mf tag
  path=$(path_for "$scen")
  c=$(c_for "$scen")
  url="http://127.0.0.1:${PORT}${path}"
  tag="${mode}_${scen}"
  out="$LOGDIR/${tag}.load.txt"
  mf="$LOGDIR/${tag}.metrics.txt"

  echo "==> [$mode] $scen path=$path c=$c z=$BENCH_Z"
  run_loadgen "$url" "$c" "$BENCH_Z" "$out"
  parse_load_out "$out"
  fetch_metrics "$mf"

  local line
  line="$tag rps=$RPS p99_ms=$P99_MS err=$ERR_N writev=$(metric "$mf" plan_writev_total) sendfile=$(metric "$mf" plan_sendfile_total) mat=$(metric "$mf" plan_materialize_total) stream=$(metric "$mf" stream_responses_total)"
  echo "  $line" | tee -a "$LOGDIR/summary.tsv"

  if ! alive; then
    echo "  FAIL $tag: server dead"
    return 1
  fi
  if [[ "$(python3 -c "print(1 if float('$ERR_N')>0 else 0)")" == "1" ]]; then
    echo "  FAIL $tag: loadgen errors=$ERR_N"
    return 1
  fi
  check_mechanism "$mode" "$scen" "$mf"
}

run_mixed_seq() {
  local mode="$1"
  local fail=0
  echo "==> [$mode] mixed_seq (short sequential phases)"
  for scen in iso_tiny iso_assembled iso_file iso_sse; do
    local path c url out
    path=$(path_for "$scen")
    c=10
    url="http://127.0.0.1:${PORT}${path}"
    out="$LOGDIR/${mode}_mixed_${scen}.load.txt"
    run_loadgen "$url" "$c" "2s" "$out"
    parse_load_out "$out"
    if [[ "$(python3 -c "print(1 if float('$ERR_N')>0 else 0)")" == "1" ]]; then
      echo "  FAIL mixed phase $scen errors=$ERR_N"
      fail=1
    else
      echo "  phase $scen rps=$RPS p99=${P99_MS}ms err=$ERR_N"
    fi
  done
  local mf="$LOGDIR/${mode}_mixed_seq.metrics.txt"
  fetch_metrics "$mf"
  echo "  mixed metrics: writev=$(metric "$mf" plan_writev_total) sendfile=$(metric "$mf" plan_sendfile_total) mat=$(metric "$mf" plan_materialize_total) stream=$(metric "$mf" stream_responses_total)" | tee -a "$LOGDIR/summary.tsv"
  if [[ "$mode" == "optimize" ]]; then
    local w s
    w=$(metric "$mf" plan_writev_total)
    s=$(metric "$mf" plan_sendfile_total)
    if [[ "$(python3 -c "print(1 if int(float('$w'))<=0 else 0)")" == "1" ]]; then
      echo "  FAIL mixed optimize: expected writev>0"
      fail=1
    fi
    if [[ "$(python3 -c "print(1 if int(float('$s'))<=0 else 0)")" == "1" ]]; then
      echo "  FAIL mixed optimize: expected sendfile>0"
      fail=1
    fi
  fi
  return $fail
}

print_ab_table() {
  echo
  echo "=== A/B comparison (from summary.tsv + metrics) ==="
  printf "%-12s %-16s %12s %10s %10s %10s %10s\n" "mode" "scenario" "rps" "p99_ms" "writev" "sendfile" "materialize"
  if [[ -f "$LOGDIR/summary.tsv" ]]; then
    # shellcheck disable=SC2013
    while read -r line; do
      # tag rps=… p99_ms=… …
      local tag mode scen rps p99 w s m
      tag=$(echo "$line" | awk '{print $1}')
      mode=${tag%%_*}
      scen=${tag#*_}
      rps=$(echo "$line" | grep -oE 'rps=[^ ]+' | head -1 | cut -d= -f2)
      p99=$(echo "$line" | grep -oE 'p99_ms=[^ ]+' | head -1 | cut -d= -f2)
      w=$(echo "$line" | grep -oE 'writev=[^ ]+' | head -1 | cut -d= -f2)
      s=$(echo "$line" | grep -oE 'sendfile=[^ ]+' | head -1 | cut -d= -f2)
      m=$(echo "$line" | grep -oE 'mat=[^ ]+' | head -1 | cut -d= -f2)
      printf "%-12s %-16s %12s %10s %10s %10s %10s\n" "${mode:-?}" "${scen:-?}" "${rps:-}" "${p99:-}" "${w:-}" "${s:-}" "${m:-}"
    done <"$LOGDIR/summary.tsv"
  fi
  echo
  echo "Full logs: $LOGDIR"
  echo "Note: RPS is informational until Writev/Sendfile hit the wire (Phase 3–4)."
}

# --- main ---
FAILED=0
: >"$LOGDIR/summary.tsv"

echo "=== proactr plan A/B ==="
echo "port=$PORT workers=$WORKERS modes=$MODES scenarios=$SCENARIOS"
echo "bench c=$BENCH_C z=$BENCH_Z logs=$LOGDIR"
echo "sendfile_ok=$PLAN_SENDFILE_OK copy_budget=$PLAN_COPY_BUDGET max_iovecs=$PLAN_MAX_IOVECS"
echo

build_server
trap 'stop_server' EXIT

for mode in $MODES; do
  echo
  echo "######## MODE=$mode ########"
  start_server "$mode"
  # reset: new process has zero counters

  for scen in $SCENARIOS; do
    if [[ "$scen" == "mixed_seq" ]]; then
      if ! run_mixed_seq "$mode"; then
        FAILED=1
      fi
      continue
    fi
    if ! run_iso "$mode" "$scen"; then
      FAILED=1
    fi
  done

  stop_server
  sleep 0.3
done

print_ab_table

if [[ "$FAILED" -ne 0 ]]; then
  echo "RESULT: FAIL (see mechanism / error lines above)"
  exit 1
fi
echo "RESULT: PASS (mechanism A/B checks ok)"
exit 0
