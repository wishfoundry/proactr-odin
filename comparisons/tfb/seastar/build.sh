#!/usr/bin/env bash
# Build seastar library (third_party) then seastar_tfb peer.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../../.." && pwd)"
SS="$ROOT/third_party/seastar"
SS_BUILD="$SS/build"
SS_INSTALL="${SEASTAR_INSTALL:-$DIR/seastar-install}"
PEER_BUILD="$DIR/build"

export PATH="${HOME}/.cargo/bin:/usr/local/bin:$PATH"

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "seastar peer is Linux-oriented" >&2
  exit 1
fi

# Dependencies (Ubuntu/Debian)
if command -v sudo >/dev/null && sudo -n true 2>/dev/null; then
  sudo -n apt-get install -y \
    build-essential cmake ninja-build pkg-config \
    libboost-all-dev libfmt-dev libgnutls28-dev libsctp-dev \
    libyaml-cpp-dev libhwloc-dev libnuma-dev libpciaccess-dev \
    libxml2-dev xfslibs-dev systemtap-sdt-dev libtool \
    liblz4-dev libzstd-dev libxxhash-dev libprotobuf-dev protobuf-compiler \
    liburing-dev libsqlite3-dev \
    2>&1 | tail -15 || true
fi

if [[ ! -f "$SS/CMakeLists.txt" ]]; then
  echo "missing third_party/seastar" >&2
  exit 1
fi

# Configure/build seastar (posix, no DPDK, shared for faster link)
if [[ ! -f "$SS_INSTALL/lib/cmake/Seastar/SeastarConfig.cmake" && \
      ! -f "$SS_INSTALL/lib/x86_64-linux-gnu/cmake/Seastar/SeastarConfig.cmake" ]]; then
  cmake -S "$SS" -B "$SS_BUILD" -GNinja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$SS_INSTALL" \
    -DSeastar_APPS=OFF \
    -DSeastar_DEMOS=OFF \
    -DSeastar_DOCS=OFF \
    -DSeastar_TESTING=OFF \
    -DSeastar_DPDK=OFF \
    -DSeastar_HWLOC=ON \
    -DSeastar_LTTNG=OFF \
    -DSeastar_IO_URING=ON \
    -DSeastar_CXX_DIALECT=gnu++20
  cmake --build "$SS_BUILD" -j"$(nproc)"
  cmake --install "$SS_BUILD"
fi

mkdir -p "$PEER_BUILD"
cmake -S "$DIR" -B "$PEER_BUILD" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_PREFIX_PATH="$SS_INSTALL" \
  -DCMAKE_CXX_STANDARD=20
cmake --build "$PEER_BUILD" -j"$(nproc)"
echo "built $PEER_BUILD/seastar_tfb"
