#!/usr/bin/env bash
# System test: a throwaway PostgreSQL, fresh keys, the real server, one
# admin, then tool/live_check.dart drives every flow over HTTP.
# Needs initdb/pg_ctl/psql on PATH and internet (breached-password check).
set -euo pipefail
cd "$(dirname "$0")/.."

WORK="$(mktemp -d /tmp/echopin-live.XXXXXX)"
PORT="${ECHOPIN_LIVE_PORT:-18080}"
PGPORT=$(( 55000 + RANDOM % 4000 ))
SERVER_PID=""
cleanup() {
  [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null || true
  pg_ctl -D "$WORK/pg" -m immediate stop >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

initdb -D "$WORK/pg" -U echopin --auth=trust >/dev/null
pg_ctl -D "$WORK/pg" -l "$WORK/pg.log" -w \
  -o "-c unix_socket_directories='' -c listen_addresses=127.0.0.1 -p $PGPORT" start >/dev/null
psql "postgresql://echopin@127.0.0.1:$PGPORT/postgres" -qc 'create database echopin'
export DATABASE_URL="postgresql://echopin@127.0.0.1:$PGPORT/echopin"

# Fresh keys for this run only; nothing is written outside $WORK.
eval "export $(dart run bin/echopin_admin.dart init-keys --print-env 2>/dev/null | grep '^ECHOPIN_KEYS=')"
CUST="$(dart run bin/echopin_admin.dart init-custodian 2>/dev/null)"
CUSTODIAN_PUBLIC_KEYS="$(grep -o 'CUSTODIAN_PUBLIC_KEYS=[^ ]*' <<<"$CUST" | cut -d= -f2-)"
export CUSTODIAN_PUBLIC_KEYS
grep -o 'ECHOPIN-CUSTODIAN-1:[^ ]*' <<<"$CUST" > "$WORK/custodian.private"

export PORT HOST=127.0.0.1 BACKUPS_DIR="$WORK/backups" CORS_ORIGINS=
dart run bin/server.dart > "$WORK/server.log" 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 150); do
  curl -sf -m 2 "http://127.0.0.1:$PORT/v1/health" >/dev/null && break
  sleep 0.4
done
curl -sf -m 2 "http://127.0.0.1:$PORT/v1/health" >/dev/null || { echo "server did not start:"; tail -20 "$WORK/server.log"; exit 1; }

echo 'Admin unique phrase 4471 zebra' | dart run bin/echopin_admin.dart \
  create-admin --email boss@example.org --name Boss --password-stdin >/dev/null

SERVER_LOG="$WORK/server.log" CUSTODIAN_FILE="$WORK/custodian.private" \
  ECHOPIN_LIVE_URL="http://127.0.0.1:$PORT" dart run tool/live_check.dart
