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
export PLAN_FILE_PATH="${PLAN_FILE_PATH:-/tmp/proactr-profile-file-1m.bin}"

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
    code=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${p}/api/tiny" 2>/dev/null || echo 000)
    if [[ "$code" != "200" ]]; then
      code=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${p}/plaintext" 2>/dev/null || echo 000)
    fi
    if [[ "$code" == "200" ]]; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

path_for_test() {
  case "$1" in
    plaintext|tiny) echo /api/tiny ;;
    gen) echo /gen/ok ;;
    assembled) echo /static/assembled ;;
    blob) echo /static/blob/1m ;;
    file) echo /file/1m ;;
    sse) echo /sse ;;
    s4k) echo /s/4k ;;
    s64k) echo /s/64k ;;
    s1m) echo /s/1m ;;
    s4m) echo /s/4m ;;
    fortunes) echo /fortunes ;;
    # legacy alias still used by older scripts
    plaintext_legacy) echo /plaintext ;;
    *) echo "/$1" ;;
  esac
}

# Exact body lengths (bytes). Fortunes is HTML (variable; only 200 + non-empty).
# See PROFILE_MATRIX.md for construction rules.
expected_body_len() {
  case "$1" in
    plaintext|tiny) echo 13 ;;
    gen) echo 13 ;;
    assembled) echo 524288 ;;
    blob|s1m) echo 1048576 ;;
    file) echo 1048576 ;;
    sse) echo 42 ;;
    s4k) echo 4096 ;;
    s64k) echo 65536 ;;
    s4m) echo 4194304 ;;
    *) echo "" ;;
  esac
}

# Fail closed if a peer returns wrong body size OR content (PROFILE_MATRIX.md contracts).
# Length-only is not enough: tiny and gen are both 13 B; assembled first-byte contract
# is mandatory; /file/1m must match $PLAN_FILE_PATH on disk (not an in-memory alias).
verify_peer_bodies() {
  local name="$1"
  local t path exp got code body fpath
  body="/tmp/tfb_body_check.$$"
  fpath="${PLAN_FILE_PATH:-/tmp/proactr-profile-file-1m.bin}"
  for t in $TESTS; do
    path="$(path_for_test "$t")"
    if [[ "$t" == "fortunes" ]]; then
      if [[ "$name" == "laytan" ]]; then
        continue
      fi
      code=$(curl -s -o "$body" -w "%{http_code}" "http://127.0.0.1:${PORT}${path}" || echo 000)
      got=$(wc -c <"$body" 2>/dev/null | tr -d ' ' || echo 0)
      rm -f "$body"
      if [[ "$code" != "200" || "${got:-0}" -lt 200 ]]; then
        echo "FAIL body-check $name $t: http=$code bytes=$got (need 200 and HTML)" >&2
        return 1
      fi
      continue
    fi
    exp="$(expected_body_len "$t")"
    [[ -z "$exp" ]] && continue
    code=$(curl -s -o "$body" -w "%{http_code}" "http://127.0.0.1:${PORT}${path}" || echo 000)
    got=$(wc -c <"$body" 2>/dev/null | tr -d ' ' || echo 0)
    if [[ "$code" != "200" || "$got" != "$exp" ]]; then
      echo "FAIL body-check $name $t: http=$code bytes=$got expected=$exp" >&2
      rm -f "$body"
      return 1
    fi
    # Exact content / structural contracts (not just length).
    case "$t" in
      plaintext|tiny)
        if ! cmp -s "$body" <(printf 'Hello, World!'); then
          echo "FAIL body-check $name $t: body != Hello, World!" >&2
          rm -f "$body"
          return 1
        fi
        ;;
      gen)
        if ! cmp -s "$body" <(printf 'generated:ok\n'); then
          echo "FAIL body-check $name $t: body != generated:ok\\\\n (gen must not be tiny)" >&2
          rm -f "$body"
          return 1
        fi
        ;;
      sse)
        if ! cmp -s "$body" <(printf 'event: ping\ndata: 1\n\nevent: ping\ndata: 2\n\n'); then
          echo "FAIL body-check $name $t: SSE oneshot body mismatch (need exact 42 B events)" >&2
          rm -f "$body"
          return 1
        fi
        # Content-Type must be event-stream (PROFILE_MATRIX).
        ct=$(curl -s -D - -o /dev/null "http://127.0.0.1:${PORT}${path}" 2>/dev/null | tr -d '\r' | awk -F': ' 'tolower($1)=="content-type"{print tolower($2); exit}')
        if [[ "$ct" != *event-stream* ]]; then
          echo "FAIL body-check $name $t: Content-Type='$ct' (need text/event-stream)" >&2
          rm -f "$body"
          return 1
        fi
        ;;
      assembled)
        # 8×64KiB; slice i first byte must be 'A'+i (PROFILE_MATRIX mandatory).
        if ! python3 - "$body" <<'PY'
import sys
p = sys.argv[1]
with open(p, "rb") as f:
    data = f.read()
if len(data) != 524288:
    print(f"assembled len {len(data)}", file=sys.stderr)
    sys.exit(1)
for i in range(8):
    b = data[i * 65536]
    want = ord("A") + i
    if b != want:
        print(f"assembled slice[{i}] first_byte={b!r} want={want!r} ({chr(want)!r})", file=sys.stderr)
        sys.exit(1)
sys.exit(0)
PY
        then
          echo "FAIL body-check $name $t: assembled first-byte contract failed" >&2
          rm -f "$body"
          return 1
        fi
        ;;
      file)
        if [[ ! -f "$fpath" ]]; then
          echo "FAIL body-check $name $t: PLAN_FILE_PATH missing: $fpath" >&2
          rm -f "$body"
          return 1
        fi
        if ! cmp -s "$body" "$fpath"; then
          echo "FAIL body-check $name $t: response body != disk file $fpath (in-memory alias?)" >&2
          rm -f "$body"
          return 1
        fi
        ;;
      blob|s1m)
        # Pattern payload: first 32 B of repeating 64-char hex pattern.
        if ! python3 - "$body" <<'PY'
import sys
pat = b"0123456789abcdef0123456789ABCDEF0123456789abcdef0123456789ABCDEF"
with open(sys.argv[1], "rb") as f:
    data = f.read()
if len(data) != 1048576:
    print(f"blob len {len(data)}", file=sys.stderr)
    sys.exit(1)
if data[:64] != pat:
    print("blob prefix mismatch", file=sys.stderr)
    sys.exit(1)
if data[64:128] != pat:
    print("blob repeat mismatch", file=sys.stderr)
    sys.exit(1)
sys.exit(0)
PY
        then
          echo "FAIL body-check $name $t: pattern payload mismatch" >&2
          rm -f "$body"
          return 1
        fi
        ;;
    esac
    rm -f "$body"
  done
  echo "  body-check ok ($name) [len+content+assembled-first+file=disk]"
  return 0
}

# Single-route body contract (post-load). Fail closed.
verify_one_body() {
  local name="$1" test="$2"
  local saved="$TESTS"
  TESTS="$test"
  verify_peer_bodies "$name"
  local st=$?
  TESTS="$saved"
  return $st
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
        PLAN_FILE_PATH="${PLAN_FILE_PATH:-/tmp/proactr-profile-file-1m.bin}" \
        ./ntex/target/release/ntex-tfb >"$LOGDIR/ntex.server.log" 2>&1 &
      ;;
    ntex-compio)
      [[ -x ntex-compio/target/release/ntex-compio-tfb ]] || (cd ntex-compio && cargo build --release)
      env DATABASE_PATH="$DATABASE_PATH" PORT="$PORT" WORKERS="$WORKERS" \
        PLAN_FILE_PATH="${PLAN_FILE_PATH:-/tmp/proactr-profile-file-1m.bin}" \
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
        PLAN_FILE_PATH="${PLAN_FILE_PATH:-/tmp/proactr-profile-file-1m.bin}" \
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
        PLAN_FILE_PATH="${PLAN_FILE_PATH:-/tmp/proactr-profile-file-1m.bin}" \
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
    proactr|proactr-sync|proactr-mat)
      if [[ ! -x proactr/tfb-proactr.bin ]]; then
        (cd proactr && odin build . -out:tfb-proactr.bin -o:speed) || return 1
      fi
      # FORTUNES_SYNC_SHARED=1 → ntex-like one conn+mutex; default = per-worker conn.
      env DATABASE_PATH="$DATABASE_PATH" PORT="$PORT" WORKERS="$WORKERS" \
        FORTUNES_MODE=sync FORTUNES_SYNC_SHARED="${FORTUNES_SYNC_SHARED:-0}" \
        PLAN_MODE=materialize PLAN_FILE_PATH="${PLAN_FILE_PATH:-/tmp/proactr-profile-file-1m.bin}" \
        ./proactr/tfb-proactr.bin >"$LOGDIR/${name}.server.log" 2>&1 &
      ;;
    proactr-opt)
      if [[ ! -x proactr/tfb-proactr.bin ]]; then
        (cd proactr && odin build . -out:tfb-proactr.bin -o:speed) || return 1
      fi
      # Linux default: kernel WRITEV + sendfile(2). Override PLAN_WIRE_SENDFILE=0 for chunked.
      env DATABASE_PATH="$DATABASE_PATH" PORT="$PORT" WORKERS="$WORKERS" \
        FORTUNES_MODE=sync FORTUNES_SYNC_SHARED="${FORTUNES_SYNC_SHARED:-0}" \
        PLAN_MODE=optimize PLAN_WIRE_MODE="${PLAN_WIRE_MODE:-kernel}" \
        PLAN_WIRE_SENDFILE="${PLAN_WIRE_SENDFILE:-}" \
        PLAN_FILE_PATH="${PLAN_FILE_PATH:-/tmp/proactr-profile-file-1m.bin}" \
        ./proactr/tfb-proactr.bin >"$LOGDIR/proactr-opt.server.log" 2>&1 &
      ;;
    proactr-opt-fallback)
      if [[ ! -x proactr/tfb-proactr.bin ]]; then
        (cd proactr && odin build . -out:tfb-proactr.bin -o:speed) || return 1
      fi
      env DATABASE_PATH="$DATABASE_PATH" PORT="$PORT" WORKERS="$WORKERS" \
        FORTUNES_MODE=sync FORTUNES_SYNC_SHARED="${FORTUNES_SYNC_SHARED:-0}" \
        PLAN_MODE=optimize PLAN_WIRE_MODE=fallback PLAN_WIRE_SENDFILE=0 \
        PLAN_FILE_PATH="${PLAN_FILE_PATH:-/tmp/proactr-profile-file-1m.bin}" \
        ./proactr/tfb-proactr.bin >"$LOGDIR/proactr-opt-fallback.server.log" 2>&1 &
      ;;
    proactr-opt-chunked)
      # Kernel WRITEV + file_chunked (sendfile off) — A/B vs default sendfile.
      if [[ ! -x proactr/tfb-proactr.bin ]]; then
        (cd proactr && odin build . -out:tfb-proactr.bin -o:speed) || return 1
      fi
      env DATABASE_PATH="$DATABASE_PATH" PORT="$PORT" WORKERS="$WORKERS" \
        FORTUNES_MODE=sync FORTUNES_SYNC_SHARED="${FORTUNES_SYNC_SHARED:-0}" \
        PLAN_MODE=optimize PLAN_WIRE_MODE=kernel PLAN_WIRE_SENDFILE=0 \
        PLAN_FILE_PATH="${PLAN_FILE_PATH:-/tmp/proactr-profile-file-1m.bin}" \
        ./proactr/tfb-proactr.bin >"$LOGDIR/proactr-opt-chunked.server.log" 2>&1 &
      ;;
    proactr-opt-sendfile)
      # Explicit kernel WRITEV + sendfile(2) (same as proactr-opt default on Linux).
      if [[ ! -x proactr/tfb-proactr.bin ]]; then
        (cd proactr && odin build . -out:tfb-proactr.bin -o:speed) || return 1
      fi
      env DATABASE_PATH="$DATABASE_PATH" PORT="$PORT" WORKERS="$WORKERS" \
        FORTUNES_MODE=sync FORTUNES_SYNC_SHARED="${FORTUNES_SYNC_SHARED:-0}" \
        PLAN_MODE=optimize PLAN_WIRE_MODE=kernel PLAN_WIRE_SENDFILE=1 \
        PLAN_FILE_PATH="${PLAN_FILE_PATH:-/tmp/proactr-profile-file-1m.bin}" \
        ./proactr/tfb-proactr.bin >"$LOGDIR/proactr-opt-sendfile.server.log" 2>&1 &
      ;;
    proactr-async)
      if [[ ! -x proactr/tfb-proactr.bin ]]; then
        (cd proactr && odin build . -out:tfb-proactr.bin -o:speed) || return 1
      fi
      # DB_WORKERS defaults to WORKERS inside the peer; override with DB_WORKERS=N.
      env DATABASE_PATH="$DATABASE_PATH" PORT="$PORT" WORKERS="$WORKERS" \
        FORTUNES_MODE=async DB_WORKERS="${DB_WORKERS:-$WORKERS}" \
        PLAN_MODE=materialize PLAN_FILE_PATH="${PLAN_FILE_PATH:-/tmp/proactr-profile-file-1m.bin}" \
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
echo "proactr-opt assembled=multi_send (NOT writev); file=file_chunked (NOT kernel_sendfile)"
echo "peers assembled=preconcat_blob (ntex/drogon/laytan/proactr-mat)"
echo "PLAN_FILE_PATH=$PLAN_FILE_PATH"
echo "fortunes app work is NOT equal across peers — see run_peer_matrix.sh notes"
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
    # Fail-closed: re-verify exact body contract after load (peer still up).
    if ! verify_one_body "$srv" "$t"; then
      echo "  FAIL post-load body-check $srv $t — invalidating RPS" | tee -a "$DETAIL"
      rps="INVALID"
    fi
    if ! check_load_size "$srv" "$t" "$LOGDIR/${srv}_${t}.txt"; then
      # oha Size metric often lies (esp. drogon); body re-check is authoritative.
      echo "$srv $t OHA_SIZE_WARN oha_size=$sz (body re-check is source of truth)" >>"$DETAIL"
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
# Mechanism-split note (PROFILE_MATRIX honesty)
if [[ -f "$LOGDIR/meta.txt" ]]; then
  echo "=== mechanism notes (from meta) ==="
  grep -E 'mech|multi_send|preconcat|writev|sendfile|chunked' "$LOGDIR/meta.txt" || true
fi
echo "Detail: $DETAIL"
echo "Logs: $LOGDIR"
