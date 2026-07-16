#!/usr/bin/env bash
# Linux-only: Asio with full io_uring backend (epoll disabled).
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../../.." && pwd)"

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "asio tfb peer is Linux/io_uring only" >&2
  exit 1
fi

ASIO_INC="${ASIO_INC:-}"
if [[ -z "$ASIO_INC" ]]; then
  if [[ -d "$ROOT/third_party/asio/include" ]]; then
    ASIO_INC="$ROOT/third_party/asio/include"
  else
    ASIO_INC=/usr/include
  fi
fi
# boostorg/asio needs Boost.Config (libboost-dev)
BOOST_INC="${BOOST_INC:-/usr/include}"

CXX="${CXX:-c++}"
# Prefer pkg-config liburing when available
URING_CFLAGS=()
URING_LIBS=(-luring)
if pkg-config --exists liburing 2>/dev/null; then
  # shellcheck disable=SC2207
  URING_CFLAGS=($(pkg-config --cflags liburing))
  # shellcheck disable=SC2207
  URING_LIBS=($(pkg-config --libs liburing))
fi

SQLITE_LIBS=(-lsqlite3)

"$CXX" -std=c++17 -O3 -DNDEBUG \
  -DBOOST_ASIO_HAS_IO_URING -DBOOST_ASIO_DISABLE_EPOLL \
  -I"$ASIO_INC" "${URING_CFLAGS[@]}" \
  "$DIR/main.cpp" -o "$DIR/asio_tfb" \
  -pthread "${URING_LIBS[@]}" "${SQLITE_LIBS[@]}"

echo "built $DIR/asio_tfb (io_uring, ASIO_INC=$ASIO_INC)"
