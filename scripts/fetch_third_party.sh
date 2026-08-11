#!/usr/bin/env bash
# Shallow-fetch third_party peers used by comparisons.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DEPTH="${DEPTH:-1}"

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

echo "Fetching peers (depth=$DEPTH)…"
fetch_one third_party/ntex
fetch_one third_party/drogon

if [[ -f .gitmodules ]] && grep -q 'vendor/laytan/odin-http' .gitmodules 2>/dev/null; then
  fetch_one vendor/laytan/odin-http
fi

echo "Done."
git submodule status
