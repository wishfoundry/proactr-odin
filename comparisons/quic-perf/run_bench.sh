#!/usr/bin/env bash
# OpenSSL product quic microbench (BoringSSL A/B archived — quic-bssl removed).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/results"
mkdir -p "$OUT"

export LIBRARY_PATH="/opt/homebrew/opt/openssl@3/lib:${LIBRARY_PATH:-}"
export DYLD_LIBRARY_PATH="/opt/homebrew/opt/openssl@3/lib:${DYLD_LIBRARY_PATH:-}"
RUNS="${RUNS:-5}"
ARGS=(-packet-iters=30000 -hs-iters=80 -warmup-packet=2000 -warmup-hs=10)

echo "==> build ossl (product quic)"
odin build "$HERE/ossl_bench" -out:"$OUT/ossl_bench.bin" -o:speed 2>&1 | tail -5
wc -c "$OUT/ossl_bench.bin"
otool -L "$OUT/ossl_bench.bin" 2>/dev/null | head -10 || true

: > "$OUT/ossl_all.tsv"
for r in $(seq 1 "$RUNS"); do
  echo "==> run $r/$RUNS ossl"
  "$OUT/ossl_bench.bin" "${ARGS[@]}" | tee -a "$OUT/ossl_all.tsv"
done

echo "Done. Historical BSSL numbers in results/bssl_all.tsv + DECISION.md (archived)."
