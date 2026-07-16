#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
DIR="$(cd "$(dirname "$0")" && pwd)"
ASIO_INC="${ASIO_INC:-}"

# Prefer submodule standalone-style include (boostorg/asio uses boost/asio.hpp).
if [[ -z "$ASIO_INC" ]]; then
  if [[ -d "$ROOT/third_party/asio/include" ]]; then
    ASIO_INC="$ROOT/third_party/asio/include"
  elif [[ -d /opt/homebrew/include ]]; then
    ASIO_INC=/opt/homebrew/include
  else
    ASIO_INC=/usr/include
  fi
fi

CXX="${CXX:-c++}"
stdflag="-std=c++17"
# boostorg/asio is header-only; needs pthread + (on some systems) boost system when using Boost install
"$CXX" $stdflag -O3 -I"$ASIO_INC" "$DIR/main.cpp" -o "$DIR/asio_empty_ok" -pthread
echo "built $DIR/asio_empty_ok (ASIO_INC=$ASIO_INC)"
