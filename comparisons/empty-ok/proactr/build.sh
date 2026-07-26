#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
odin build "$DIR" -out:"$DIR/server.bin" -o:speed
echo "built $DIR/server.bin (honors PORT + WORKERS; pass opts to listen_and_serve)"
