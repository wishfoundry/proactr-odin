#!/usr/bin/env bash
# Build drogon_tls_h2; reuse tfb drogon install if present.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../../.." && pwd)"
TFB_INSTALL="${TFB_INSTALL:-$ROOT/comparisons/tfb/drogon/install}"
DROGON_SRC="${DROGON_SRC:-$ROOT/third_party/drogon}"
BUILD="$DIR/build"
INSTALL="$DIR/install"

# Prefer shared install from tfb peer
if [[ -f "$TFB_INSTALL/lib/cmake/Drogon/DrogonConfig.cmake" ]]; then
  PREFIX_PATH="$TFB_INSTALL"
elif [[ -f "$INSTALL/lib/cmake/Drogon/DrogonConfig.cmake" ]]; then
  PREFIX_PATH="$INSTALL"
else
  # Build drogon once into local install (heavy).
  if [[ ! -f "$DROGON_SRC/CMakeLists.txt" ]]; then
    echo "missing drogon at $DROGON_SRC" >&2
    exit 1
  fi
  if [[ ! -f "$DROGON_SRC/trantor/CMakeLists.txt" ]]; then
    echo "init trantor submodule under $DROGON_SRC" >&2
    exit 1
  fi
  mkdir -p "$DROGON_SRC/build"
  cmake -S "$DROGON_SRC" -B "$DROGON_SRC/build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$INSTALL" \
    -DBUILD_EXAMPLES=OFF \
    -DBUILD_CTL=OFF \
    -DBUILD_YAML_CONFIG=OFF \
    -DUSE_SUBMODULE=ON
  cmake --build "$DROGON_SRC/build" -j"$(nproc 2>/dev/null || echo 4)"
  cmake --install "$DROGON_SRC/build"
  PREFIX_PATH="$INSTALL"
fi

mkdir -p "$BUILD"
cmake -S "$DIR" -B "$BUILD" -DCMAKE_PREFIX_PATH="$PREFIX_PATH" -DCMAKE_BUILD_TYPE=Release
cmake --build "$BUILD" -j"$(nproc 2>/dev/null || echo 4)"
cp -f "$BUILD/drogon_tls_h2" "$DIR/server.bin"
echo "built $DIR/server.bin"
