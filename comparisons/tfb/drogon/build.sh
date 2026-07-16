#!/usr/bin/env bash
# Build drogon_tfb against third_party/drogon (+ trantor submodule).
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../../.." && pwd)"
DROGON_SRC="${DROGON_SRC:-$ROOT/third_party/drogon}"
BUILD="$DIR/build"
INSTALL="$DIR/install"

if [[ ! -f "$DROGON_SRC/CMakeLists.txt" ]]; then
  echo "missing drogon at $DROGON_SRC" >&2
  exit 1
fi
if [[ ! -f "$DROGON_SRC/trantor/CMakeLists.txt" ]]; then
  echo "init trantor: git -C $DROGON_SRC submodule update --init --depth 1 trantor" >&2
  exit 1
fi

# Build/install drogon once
if [[ ! -f "$INSTALL/lib/cmake/Drogon/DrogonConfig.cmake" && \
      ! -f "$INSTALL/lib/cmake/Drogon/DrogonConfig.cmake" ]]; then
  mkdir -p "$DROGON_SRC/build"
  cmake -S "$DROGON_SRC" -B "$DROGON_SRC/build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$INSTALL" \
    -DBUILD_EXAMPLES=OFF \
    -DBUILD_CTL=OFF \
    -DBUILD_YAML_CONFIG=OFF \
    -DUSE_SUBMODULE=ON
  cmake --build "$DROGON_SRC/build" -j"$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"
  cmake --install "$DROGON_SRC/build"
fi

mkdir -p "$BUILD"
cmake -S "$DIR" -B "$BUILD" -DCMAKE_PREFIX_PATH="$INSTALL" -DCMAKE_BUILD_TYPE=Release
cmake --build "$BUILD" -j"$(nproc 2>/dev/null || echo 4)"
echo "built $BUILD/drogon_tfb"
