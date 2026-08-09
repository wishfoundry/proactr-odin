#!/usr/bin/env bash
# Sync tree to ranch-bastion and run TLS/H2 matrix there.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
HOST="${BASTION:-ranch-bastion.local}"
REMOTE_DIR="${REMOTE_DIR:-/home/bngreer/Projects/proactr-odin}"
REMOTE_LOG="${REMOTE_LOG:-/tmp/proactr-tls-h2}"

echo "==> rsync to $HOST:$REMOTE_DIR"
rsync -az --delete \
  --exclude '.git' \
  --exclude '**/target' \
  --exclude '**/*.bin' \
  --exclude 'third_party' \
  --exclude 'comparisons/tfb/ntex/target' \
  "$ROOT/" "$HOST:$REMOTE_DIR/"

echo "==> run matrix on bastion"
ssh "$HOST" bash -s <<EOF
set -euo pipefail
export PATH="/usr/bin:/bin:/usr/local/bin:\${HOME}/.cargo/bin:\${HOME}/go/bin:\$PATH"
cd "$REMOTE_DIR/comparisons/tls-h2"
chmod +x gen_certs.sh run_matrix.sh
SERVERS="${SERVERS:-proactr ntex drogon go}" \\
WORKERS="${WORKERS:-8}" \\
BENCH_C="${BENCH_C:-100}" \\
BENCH_Z="${BENCH_Z:-15}" \\
WARMUP_Z="${WARMUP_Z:-3}" \\
TESTS="${TESTS:-plaintext s4k s64k s1m}" \\
PROTOCOLS="${PROTOCOLS:-h2 h1s}" \\
LOGDIR="$REMOTE_LOG" \\
  ./run_matrix.sh
echo "=== remote summary ==="
cat "$REMOTE_LOG/SUMMARY.md"
EOF

echo "==> fetch results"
mkdir -p "$HERE/results"
scp "$HOST:$REMOTE_LOG/SUMMARY.md" "$HERE/results/BASTION_TLS_H2.md"
scp "$HOST:$REMOTE_LOG/summary.tsv" "$HERE/results/bastion_summary.tsv" || true
scp "$HOST:$REMOTE_LOG/instrumentation.txt" "$HERE/results/bastion_instrumentation.txt" || true
echo "wrote $HERE/results/BASTION_TLS_H2.md"
