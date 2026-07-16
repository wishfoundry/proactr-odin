#!/usr/bin/env bash
# Shallow-fetch third_party submodules. Heavy peers are opt-in.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DEPTH="${DEPTH:-1}"
WITH_HEAVY="${WITH_HEAVY:-0}"

fetch_one() {
  local path="$1"
  echo "==> $path"
  if [[ ! -e "$path/.git" && ! -f "$path/.git" ]]; then
    git submodule update --init --depth "$DEPTH" -- "$path"
  else
    git submodule update --depth "$DEPTH" -- "$path" || \
      git -C "$path" fetch --depth "$DEPTH" origin && \
      git submodule update -- "$path"
  fi
}

echo "Fetching core peers (depth=$DEPTH)…"
fetch_one third_party/ntex
fetch_one third_party/compio
fetch_one third_party/drogon
fetch_one third_party/asio

if [[ "$WITH_HEAVY" == "1" ]]; then
  echo "Fetching heavy peers (seastar, envoy)…"
  fetch_one third_party/seastar
  fetch_one third_party/envoy
  echo "Note: run their own scripts for recursive build deps if needed."
else
  echo "Skipping seastar/envoy (set WITH_HEAVY=1 to fetch)."
fi

# Always keep vendor baseline
if [[ -f .gitmodules ]] && grep -q 'vendor/laytan/odin-http' .gitmodules 2>/dev/null; then
  fetch_one vendor/laytan/odin-http
fi

echo "Done."
git submodule status
