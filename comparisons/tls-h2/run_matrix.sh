#!/usr/bin/env bash
# TLS/H2 peer matrix: proactr · ntex · drogon · go
# Fair: same certs, routes, WORKERS, loadgen; honest backend labels; h2load fail-closed.
set -euo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:${HOME}/.cargo/bin:${HOME}/go/bin:/usr/local/bin:${PATH}"

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
cd "$HERE"

PORT="${PORT:-18443}"
WORKERS="${WORKERS:-8}"
BENCH_C="${BENCH_C:-100}"
BENCH_Z="${BENCH_Z:-15}"
WARMUP_Z="${WARMUP_Z:-3}"
SERVERS="${SERVERS:-proactr ntex drogon go}"
TESTS="${TESTS:-plaintext s4k s64k s1m}"
PROTOCOLS="${PROTOCOLS:-h2 h1s}"
LOGDIR="${LOGDIR:-/tmp/proactr-tls-h2}"
CERT_DIR="${CERT_DIR:-$HERE/certs}"
export CERT_FILE="${CERT_FILE:-$CERT_DIR/cert.pem}"
export KEY_FILE="${KEY_FILE:-$CERT_DIR/key.pem}"
CERT_FILE="$(cd "$(dirname "$CERT_FILE")" && pwd)/$(basename "$CERT_FILE")"
KEY_FILE="$(cd "$(dirname "$KEY_FILE")" && pwd)/$(basename "$KEY_FILE")"
export CERT_FILE KEY_FILE PORT WORKERS
mkdir -p "$LOGDIR" "$HERE/results"

have() { command -v "$1" >/dev/null 2>&1; }

if ! have h2load; then
  echo "Need h2load (nghttp2)" >&2
  exit 1
fi
if ! have curl; then
  echo "Need curl" >&2
  exit 1
fi

echo "=== TLS/H2 peer matrix ==="
echo "host=$(hostname) $(uname -s) $(uname -r) nproc=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo '?')"
echo "SERVERS=$SERVERS TESTS=$TESTS PROTOCOLS=$PROTOCOLS"
echo "WORKERS=$WORKERS BENCH_C=$BENCH_C BENCH_Z=${BENCH_Z}s WARMUP_Z=${WARMUP_Z}s PORT=$PORT"
echo "CERT_FILE=$CERT_FILE"
echo "LOGDIR=$LOGDIR"
echo "backends (must stay labeled):"
if [[ "$(uname -s)" == "Darwin" ]]; then
  echo "  proactr: kqueue + mem-BIO OpenSSL · ALPN h2|http/1.1"
  echo "  ntex:    tokio + OpenSSL · ALPN h2|http/1.1 (Darwin; neon-uring is Linux-only)"
  echo "  drogon:  trantor/kqueue + OpenSSL · primarily HTTP/1.1 (h2 may be N/A)"
  echo "  go:      net/http + crypto/tls · auto HTTP/2 · kqueue/net"
else
  echo "  proactr: io_uring + mem-BIO OpenSSL · ALPN h2|http/1.1"
  echo "  ntex:    neon-uring + OpenSSL · ALPN h2|http/1.1 (ntex bind_openssl)"
  echo "  drogon:  trantor/epoll + OpenSSL · primarily HTTP/1.1 (h2 may be N/A)"
  echo "  go:      net/http + crypto/tls · auto HTTP/2 · epoll/net"
fi
echo ""

./gen_certs.sh

kill_port() {
  # macOS ships a different fuser; use lsof on Darwin always.
  if [[ "$(uname -s)" == "Darwin" ]] && have lsof; then
    pids=$(lsof -tiTCP:"$PORT" -sTCP:LISTEN 2>/dev/null || true)
    if [[ -n "$pids" ]]; then
      # shellcheck disable=SC2086
      kill -9 $pids 2>/dev/null || true
    fi
  elif have fuser; then
    fuser -k "${PORT}/tcp" 2>/dev/null || true
  elif have lsof; then
    pids=$(lsof -tiTCP:"$PORT" -sTCP:LISTEN 2>/dev/null || true)
    if [[ -n "$pids" ]]; then
      # shellcheck disable=SC2086
      kill -9 $pids 2>/dev/null || true
    fi
  fi
  sleep 0.3
}

wait_up() {
  local i code
  for i in $(seq 1 120); do
    code=$(curl -sk -o /dev/null -w "%{http_code}" --http1.1 "https://127.0.0.1:${PORT}/plaintext" 2>/dev/null || echo 000)
    if [[ "$code" == "200" ]]; then
      return 0
    fi
    sleep 0.15
  done
  return 1
}

path_for() {
  case "$1" in
    plaintext|tiny) echo /plaintext ;;
    s4k) echo /s/4k ;;
    s64k) echo /s/64k ;;
    s1m) echo /s/1m ;;
    sse) echo /sse ;;
    *) echo "/$1" ;;
  esac
}

expected_len() {
  case "$1" in
    plaintext|tiny) echo 13 ;;
    s4k) echo 4096 ;;
    s64k) echo 65536 ;;
    s1m) echo 1048576 ;;
    sse) echo 42 ;;
    *) echo "" ;;
  esac
}

expected_prefix() {
  case "$1" in
    plaintext|tiny) echo "Hello, World!" ;;
    s4k|s64k|s1m) echo "0123456789abcdef" ;;
    sse) echo "event: ping" ;;
    *) echo "" ;;
  esac
}

# Content + length verify over H1.s (and optionally note H2 via h2load later).
verify_one() {
  local name="$1" t="$2" mode="$3" # mode: h1s | h2
  local path exp got code pref body curlflags=()
  path="$(path_for "$t")"
  exp="$(expected_len "$t")"
  pref="$(expected_prefix "$t")"
  body="$LOGDIR/${name}.bodycheck.${mode}.${t//\//_}"
  if [[ "$mode" == "h2" ]]; then
    curlflags=(--http2)
  else
    curlflags=(--http1.1)
  fi
  code=$(curl -sk -o "$body" -w "%{http_code}" "${curlflags[@]}" "https://127.0.0.1:${PORT}${path}" || echo 000)
  if [[ "$code" != "200" ]]; then
    echo "FAIL body-check $name $t $mode http=$code" | tee -a "$LOGDIR/errors.txt"
    return 1
  fi
  if [[ -n "$exp" ]]; then
    got=$(wc -c <"$body" | tr -d ' ')
    if [[ "$got" != "$exp" ]]; then
      echo "FAIL body-check $name $t $mode len=$got want=$exp" | tee -a "$LOGDIR/errors.txt"
      return 1
    fi
  fi
  if [[ -n "$pref" ]]; then
    if ! head -c "${#pref}" "$body" | cmp -s - <(printf '%s' "$pref"); then
      echo "FAIL body-check $name $t $mode prefix mismatch want=$pref" | tee -a "$LOGDIR/errors.txt"
      return 1
    fi
  fi
  return 0
}

verify_bodies() {
  local name="$1" t
  for t in $TESTS; do
    verify_one "$name" "$t" h1s || return 1
  done
  # H2 body check when peer can speak h2 (skip if curl --http2 fails ALPN).
  local h2_ok=0
  if curl -sk --http2 -o /dev/null -w "%{http_code}" "https://127.0.0.1:${PORT}/plaintext" 2>/dev/null | grep -q 200; then
    # Confirm ALPN via h2load -n1
    local proto
    proto=$(SSL_CERT_FILE="$CERT_FILE" h2load -c1 -n1 "https://127.0.0.1:${PORT}/plaintext" 2>/dev/null | grep 'Application protocol:' | sed 's/.*: //' || true)
    if [[ "$proto" == "h2" ]]; then
      h2_ok=1
      for t in $TESTS; do
        verify_one "$name" "$t" h2 || return 1
      done
    fi
  fi
  if [[ $h2_ok -eq 1 ]]; then
    echo "OK body-check $name (len+prefix H1.s + H2)"
  else
    echo "OK body-check $name (len+prefix H1.s; h2 not available — h2 cells will be N/A)"
  fi
}

parse_h2load_rps() {
  local f="$1"
  grep -E 'finished in' "$f" | head -1 | sed -E 's/.*finished in [^,]+, *([0-9.]+) *req\/s.*/\1/'
}

parse_h2load_failed() {
  local f="$1"
  # requests: N total, ... M succeeded, F failed, E errored, T timeout
  grep -E '^requests:' "$f" | head -1 | sed -E 's/.* ([0-9]+) failed, ([0-9]+) errored, ([0-9]+) timeout.*/\1 \2 \3/' || echo "0 0 0"
}

parse_h2load_proto() {
  local f="$1"
  grep -E 'Application protocol:' "$f" | head -1 | sed -E 's/.*Application protocol: *//' || echo "?"
}

parse_h2load_mbps() {
  local f="$1"
  grep -E 'finished in' "$f" | head -1 | sed -E 's/.*, *([0-9.]+)(KB|MB|GB)\/s.*/\1 \2/' || echo "?"
}

scrape_stats() {
  local peer="$1" tag="$2"
  local out="$LOGDIR/${peer}.${tag}.stats.txt"
  # Sanitize: peers must emit text key=value; strip non-printables (drogon/log noise).
  if curl -sk --http1.1 "https://127.0.0.1:${PORT}/_matrix/stats" 2>/dev/null \
      | tr -cd '\11\12\15\40-\176' >"$out"; then
    :
  else
    echo "stats_unavailable" >"$out"
  fi
  echo "--- stats $peer $tag ---" | tee -a "$LOGDIR/instrumentation.txt"
  cat "$out" | tee -a "$LOGDIR/instrumentation.txt" || true
}

reset_stats() {
  curl -sk -X POST --http1.1 "https://127.0.0.1:${PORT}/_matrix/reset" -o /dev/null 2>/dev/null || \
    curl -sk --http1.1 "https://127.0.0.1:${PORT}/_matrix/reset" -o /dev/null 2>/dev/null || true
}

bench_one() {
  local peer="$1" proto="$2" test="$3"
  local path url out rps failed_line f e t appproto mbps
  path="$(path_for "$test")"
  url="https://127.0.0.1:${PORT}${path}"
  out="$LOGDIR/${peer}.${proto}.${test}.h2load.txt"
  echo "--- $peer $proto $test → $url ---"
  # Bash 3.2 (macOS) + set -u: empty arrays are "unbound"; use a scalar flag.
  local h1_opt=""
  if [[ "$proto" == "h1s" ]]; then
    h1_opt="--h1"
  fi
  export SSL_CERT_FILE="$CERT_FILE"
  reset_stats
  if [[ "${WARMUP_Z}" != "0" ]]; then
    if [[ -n "$h1_opt" ]]; then
      SSL_CERT_FILE="$CERT_FILE" h2load -c "$BENCH_C" -D "$WARMUP_Z" -t 4 "$h1_opt" "$url" >/dev/null 2>&1 || true
    else
      SSL_CERT_FILE="$CERT_FILE" h2load -c "$BENCH_C" -D "$WARMUP_Z" -t 4 "$url" >/dev/null 2>&1 || true
    fi
    reset_stats
  fi
  if [[ -n "$h1_opt" ]]; then
    SSL_CERT_FILE="$CERT_FILE" h2load -c "$BENCH_C" -D "$BENCH_Z" -t 4 "$h1_opt" "$url" | tee "$out"
  else
    SSL_CERT_FILE="$CERT_FILE" h2load -c "$BENCH_C" -D "$BENCH_Z" -t 4 "$url" | tee "$out"
  fi
  rps="$(parse_h2load_rps "$out")"
  failed_line="$(parse_h2load_failed "$out")"
  read -r f e t <<<"$failed_line"
  f="${f:-0}"; e="${e:-0}"; t="${t:-0}"
  appproto="$(parse_h2load_proto "$out")"
  mbps="$(parse_h2load_mbps "$out")"
  # Protocol honesty: h2 cell must negotiate h2 unless peer labeled h2-limited.
  local status="ok"
  # Fail-closed: empty/unparseable h2load must not look like a real score.
  if [[ -z "$rps" || "$rps" == "?" ]] || ! [[ "$rps" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    if [[ ! -s "$out" ]] || ! grep -q 'finished in' "$out" 2>/dev/null; then
      status="fail"
      rps="INVALID"
      echo "FAIL $peer $proto $test unparseable/empty h2load" | tee -a "$LOGDIR/errors.txt"
    else
      rps="INVALID"
      status="fail"
      echo "FAIL $peer $proto $test could not parse req/s" | tee -a "$LOGDIR/errors.txt"
    fi
  fi
  if [[ "$status" == "ok" && "$proto" == "h2" ]]; then
    if [[ "$appproto" != "h2" ]]; then
      status="no_h2"
      rps="N/A"
      echo "WARN $peer h2 $test negotiated '$appproto' not h2 → N/A" | tee -a "$LOGDIR/errors.txt"
    fi
  fi
  if [[ "$status" == "ok" ]] && { [[ "$f" != "0" ]] || [[ "$e" != "0" ]] || [[ "$t" != "0" ]]; }; then
    status="fail"
    echo "FAIL $peer $proto $test failed=$f errored=$e timeout=$t" | tee -a "$LOGDIR/errors.txt"
    rps="INVALID"
  fi
  scrape_stats "$peer" "${proto}.${test}"
  echo -e "$peer\t$proto\t$test\t$rps\t$status\t$appproto\t$f\t$e\t$t" >>"$LOGDIR/summary.tsv"
  echo "RPS=$rps status=$status proto=$appproto failed=$f"
}

build_proactr() {
  # Ranking build: no PHASE cycle timers (they tax proactr unfairly).
  # INSTRUMENT=1 adds HTTP_PHASE_STATS for deeper tuning runs only.
  echo "==> build proactr tls-h2 (INSTRUMENT=${INSTRUMENT:-0})"
  local defs=(-o:speed)
  if [[ "${INSTRUMENT:-0}" == "1" ]]; then
    defs+=(-define:HTTP_PHASE_STATS=true)
  fi
  (cd "$HERE/proactr" && odin build . -out:server.bin "${defs[@]}")
}

build_go() {
  echo "==> build go tls-h2"
  (cd "$HERE/go" && go build -o server.bin .)
}

build_ntex() {
  echo "==> build ntex tls-h2"
  (cd "$HERE/ntex" && cargo build --release 2>&1 | tail -20)
  cp -f "$HERE/ntex/target/release/ntex-tls-h2" "$HERE/ntex/server.bin"
}

build_drogon() {
  echo "==> build drogon tls-h2"
  chmod +x "$HERE/drogon/build.sh"
  if ! "$HERE/drogon/build.sh"; then
    echo "WARN: drogon build failed — peer will be skipped" | tee -a "$LOGDIR/errors.txt"
    return 1
  fi
}

start_proactr() {
  env PORT="$PORT" WORKERS="$WORKERS" CERT_FILE="$CERT_FILE" KEY_FILE="$KEY_FILE" \
    "$HERE/proactr/server.bin"
}

start_go() {
  env PORT="$PORT" WORKERS="$WORKERS" GOMAXPROCS="$WORKERS" \
    CERT_FILE="$CERT_FILE" KEY_FILE="$KEY_FILE" \
    "$HERE/go/server.bin"
}

start_ntex() {
  env PORT="$PORT" WORKERS="$WORKERS" CERT_FILE="$CERT_FILE" KEY_FILE="$KEY_FILE" \
    "$HERE/ntex/server.bin"
}

start_drogon() {
  env PORT="$PORT" WORKERS="$WORKERS" CERT_FILE="$CERT_FILE" KEY_FILE="$KEY_FILE" \
    "$HERE/drogon/server.bin"
}

run_peer() {
  local name="$1"
  kill_port
  echo "==> start $name"
  case "$name" in
    proactr) start_proactr >"$LOGDIR/${name}.server.log" 2>&1 & ;;
    go) start_go >"$LOGDIR/${name}.server.log" 2>&1 & ;;
    ntex) start_ntex >"$LOGDIR/${name}.server.log" 2>&1 & ;;
    drogon) start_drogon >"$LOGDIR/${name}.server.log" 2>&1 & ;;
    *) echo "unknown peer $name"; return 1 ;;
  esac
  local pid=$!
  if ! wait_up; then
    echo "FAIL: $name did not serve :$PORT" | tee -a "$LOGDIR/errors.txt" | tee "$LOGDIR/${name}.fail.txt"
    head -60 "$LOGDIR/${name}.server.log" || true
    kill "$pid" 2>/dev/null || true
    return 1
  fi
  head -8 "$LOGDIR/${name}.server.log" || true
  if ! verify_bodies "$name"; then
    kill "$pid" 2>/dev/null || true
    return 1
  fi
  for proto in $PROTOCOLS; do
    for t in $TESTS; do
      bench_one "$name" "$proto" "$t" || true
    done
  done
  scrape_stats "$name" "final"
  # Dump PHASE lines if present
  if grep -q 'PHASE\|PATH_METRICS' "$LOGDIR/${name}.server.log" 2>/dev/null; then
    echo "--- $name phase/path log ---" | tee -a "$LOGDIR/instrumentation.txt"
    grep -E 'PHASE|PATH_METRICS' "$LOGDIR/${name}.server.log" | tail -20 | tee -a "$LOGDIR/instrumentation.txt" || true
  fi
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  kill_port
}

# builds
BUILT=""
for s in $SERVERS; do
  case "$s" in
    proactr) build_proactr && BUILT+=" proactr" ;;
    go) build_go && BUILT+=" go" ;;
    ntex)
      if build_ntex; then BUILT+=" ntex"; else echo "skip ntex" | tee -a "$LOGDIR/errors.txt"; fi
      ;;
    drogon)
      if build_drogon; then BUILT+=" drogon"; else echo "skip drogon" | tee -a "$LOGDIR/errors.txt"; fi
      ;;
  esac
done

: >"$LOGDIR/summary.tsv"
echo -e "peer\tproto\ttest\trps\tstatus\tapp_proto\tfailed\terrored\ttimeout" >>"$LOGDIR/summary.tsv"
: >"$LOGDIR/errors.txt"
: >"$LOGDIR/instrumentation.txt"

for s in $SERVERS; do
  # only run if binary exists
  case "$s" in
    proactr) [[ -x "$HERE/proactr/server.bin" ]] || continue ;;
    go) [[ -x "$HERE/go/server.bin" ]] || continue ;;
    ntex) [[ -x "$HERE/ntex/server.bin" ]] || continue ;;
    drogon) [[ -x "$HERE/drogon/server.bin" ]] || continue ;;
  esac
  run_peer "$s" || echo "peer $s failed" | tee -a "$LOGDIR/errors.txt"
done

# SUMMARY.md
{
  echo "# TLS/H2 peer matrix results"
  echo ""
  echo "- **Host:** $(hostname) · $(uname -s) $(uname -r)"
  echo "- **When:** $(date -u +%Y-%m-%dT%H:%MZ)"
  echo "- **WORKERS=$WORKERS** · **BENCH_C=$BENCH_C** · **BENCH_Z=${BENCH_Z}s** · **WARMUP_Z=${WARMUP_Z}s**"
  echo "- **Loadgen:** h2load -c $BENCH_C -D $BENCH_Z -t 4 · SSL_CERT_FILE=matrix cert"
  echo "- **Protocols:** $PROTOCOLS (h2 = ALPN h2 required; h1s = TLS HTTP/1.1)"
  echo "- **Peers requested:** $SERVERS"
  echo "- **Peers built:** $BUILT"
  echo ""
  echo "## Backend labels"
  echo ""
  echo "| Peer | Stack | TLS | H2 |"
  echo "|------|-------|-----|-----|"
  if [[ "$(uname -s)" == "Darwin" ]]; then
    echo "| proactr | **kqueue** | OpenSSL mem-BIO | ALPN h2 product path |"
    echo "| ntex | **tokio** (not neon-uring) | OpenSSL (ntex-tls) | ALPN h2 via bind_openssl |"
    echo "| drogon | trantor **kqueue** | OpenSSL | primarily H1; h2 cells N/A if no_h2 |"
    echo "| go | net/http **kqueue** | crypto/tls | automatic HTTP/2 |"
  else
    echo "| proactr | io_uring | OpenSSL mem-BIO | ALPN h2 product path |"
    echo "| ntex | neon-uring | OpenSSL (ntex-tls) | ALPN h2 via bind_openssl |"
    echo "| drogon | trantor **epoll** | OpenSSL | primarily H1; h2 cells N/A if no_h2 |"
    echo "| go | net/http epoll | crypto/tls | automatic HTTP/2 |"
  fi
  echo ""
  echo "## RPS matrix"
  echo ""
  echo '```'
  column -t -s$'\t' "$LOGDIR/summary.tsv" 2>/dev/null || cat "$LOGDIR/summary.tsv"
  echo '```'
  echo ""
  echo "## Fairness notes"
  echo ""
  echo "- Body len + prefix verified on TLS HTTP/1.1 before load."
  echo "- h2 cells require Application protocol: h2; else status=no_h2 RPS=N/A."
  echo "- Nonzero failed/errored/timeout → status=fail RPS=INVALID."
  echo "- go: GOMAXPROCS=$WORKERS label only (not thread-per-worker)."
  echo "- proactr/ntex: WORKERS=$WORKERS thread/worker model."
  if [[ "$(uname -s)" == "Darwin" ]]; then
    echo "- **Darwin/kqueue host:** proactr uses kqueue (not io_uring). ntex uses tokio+openssl (not neon-uring)."
    echo "- drogon: setThreadNum=$WORKERS, trantor kqueue — not Linux epoll class."
  else
    echo "- drogon: setThreadNum=$WORKERS, epoll — not same I/O class as uring peers."
  fi
  echo "- Instrumentation: /_matrix/stats after each cell → instrumentation.txt"
  echo "- Not multi-stream SSE RPS; oneshot size ladder only."
  if [[ -s "$LOGDIR/errors.txt" ]]; then
    echo ""
    echo "## Errors / warnings"
    echo '```'
    cat "$LOGDIR/errors.txt"
    echo '```'
  fi
  if [[ -s "$LOGDIR/instrumentation.txt" ]]; then
    echo ""
    echo "## Instrumentation (excerpt)"
    echo '```'
    head -80 "$LOGDIR/instrumentation.txt"
    echo '```'
  fi
} | tee "$LOGDIR/SUMMARY.md"

cp -f "$LOGDIR/SUMMARY.md" "$HERE/results/SUMMARY.md" 2>/dev/null || true
cp -f "$LOGDIR/summary.tsv" "$HERE/results/summary.tsv" 2>/dev/null || true
cp -f "$LOGDIR/instrumentation.txt" "$HERE/results/instrumentation.txt" 2>/dev/null || true
echo "=== done → $LOGDIR/SUMMARY.md ==="
