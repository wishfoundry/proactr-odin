#!/usr/bin/env bash
# Build all io_uring-capable TFB peers (Linux / ranch-bastion).
set -euo pipefail
export PATH="${HOME}/.cargo/bin:/usr/local/bin:/usr/bin:/bin:${PATH}"

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
cd "$HERE"

"$ROOT/scripts/check_io_uring.sh"

echo "==> prepare DB"
./schema/prepare.sh

echo "==> ntex (neon-uring)"
(cd ntex && cargo build --release)
test -x ntex/target/release/ntex-tfb

echo "==> ntex-compio"
(cd ntex-compio && cargo build --release)
test -x ntex-compio/target/release/ntex-compio-tfb

echo "==> compio"
(cd compio && cargo build --release)
test -x compio/target/release/compio-tfb

echo "==> asio (HAS_IO_URING + DISABLE_EPOLL)"
if [[ -f /usr/include/sqlite3.h ]] || pkg-config --exists sqlite3 2>/dev/null; then
  ./asio/build.sh
else
  echo "WARN: skip asio (need libsqlite3-dev)"
fi

echo "==> laytan (core:nbio → io_uring on Linux)"
(cd laytan && odin build . -out:tfb-laytan -o:speed \
  -collection:laytan="$ROOT/vendor/laytan")
test -x laytan/tfb-laytan

echo "All uring peers built."
ls -la ntex/target/release/ntex-tfb \
  ntex-compio/target/release/ntex-compio-tfb \
  compio/target/release/compio-tfb \
  laytan/tfb-laytan \
  asio/asio_tfb 2>/dev/null || true
