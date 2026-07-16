#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
DB="${DATABASE_PATH:-/tmp/proactr-tfb.sqlite}"
rm -f "$DB"
if command -v sqlite3 >/dev/null 2>&1; then
  sqlite3 "$DB" <"$DIR/init_sqlite.sql"
else
  echo "sqlite3 CLI required to prepare DB" >&2
  exit 1
fi
echo "prepared $DB"
sqlite3 "$DB" 'SELECT COUNT(*) AS worlds FROM world; SELECT COUNT(*) AS fortunes FROM fortune;'
