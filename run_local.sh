#!/usr/bin/env bash
# Start the local PostgreSQL (if stopped) and the KPS DMS web app on http://localhost:8000.
# `run_local.sh jm` runs the jm simulation database (scripts/import_jm.py) on http://localhost:8001.
cd "$(dirname "$0")"
set -a; . ./.env; set +a
PORT=8000
if [ "$1" = "jm" ]; then DATABASE_URL=$SIM_DATABASE_URL; PORT=8001; fi
"$PG_BIN/pg_isready.exe" -q -h 127.0.0.1 -p 5433 || \
  "$PG_BIN/pg_ctl.exe" -D "$PGDATA" -o "-p 5433 -c listen_addresses=127.0.0.1" -l "$PGDATA/server.log" -w start > /dev/null
exec /c/Users/User/.venvs/kps-dms/Scripts/python.exe -m uvicorn app.main:app --host 127.0.0.1 --port "$PORT"
