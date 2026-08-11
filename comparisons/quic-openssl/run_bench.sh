#!/usr/bin/env bash
# Self-bench for product quic/ (OpenSSL dynlib) after cutover.
# Historical BSSL A/B removed with the old quic/ tree.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/results"
mkdir -p "$OUT"

export LIBRARY_PATH="/opt/homebrew/opt/openssl@3/lib:${LIBRARY_PATH:-}"
export DYLD_LIBRARY_PATH="/opt/homebrew/opt/openssl@3/lib:${DYLD_LIBRARY_PATH:-}"

ARGS=(-packet-iters=20000 -hs-iters=40 -warmup-packet=1000 -warmup-hs=5)

echo "==> build openssl_bench (product quic)"
odin build "$HERE/openssl_bench" -out:"$OUT/quic_bench.bin" -o:speed 2>&1 | tail -5
otool -L "$OUT/quic_bench.bin" 2>/dev/null | head -12 || true
openssl version 2>/dev/null || true

echo "==> run"
"$OUT/quic_bench.bin" "${ARGS[@]}" | tee "$OUT/quic.tsv"
