#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
DB="${DATABASE_PATH:-/tmp/proactr-tfb.sqlite}"
rm -f "$DB"
if ! command -v sqlite3 >/dev/null 2>&1; then
  echo "sqlite3 CLI required" >&2
  exit 1
fi
sqlite3 "$DB" <"$DIR/init_sqlite.sql"
echo "prepared $DB"
sqlite3 "$DB" 'SELECT COUNT(*) AS fortunes FROM fortune;'
