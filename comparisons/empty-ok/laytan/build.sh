#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../../.." && pwd)"
odin build "$DIR" -out:"$DIR/server.bin" -o:speed \
  -collection:laytan="$ROOT/vendor/laytan"
echo "built $DIR/server.bin"
