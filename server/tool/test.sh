#!/usr/bin/env bash
# Runs the server test suite against a throwaway PostgreSQL cluster.
# Needs initdb/pg_ctl/pg_dump/pg_restore on PATH (any PostgreSQL ≥ 14).
# Pass ECHOPIN_TEST_DATABASE_URL yourself to reuse an existing server.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -z "${ECHOPIN_TEST_DATABASE_URL:-}" ]]; then
  DIR="$(mktemp -d /tmp/echopin-pg.XXXXXX)"
  PORT="${ECHOPIN_TEST_PG_PORT:-$(( 55000 + RANDOM % 4000 ))}"
  trap 'pg_ctl -D "$DIR/data" -m immediate stop >/dev/null 2>&1 || true; rm -rf "$DIR"' EXIT
  initdb -D "$DIR/data" -U echopin --auth=trust >/dev/null
  pg_ctl -D "$DIR/data" -l "$DIR/log" -w \
    -o "-c unix_socket_directories='' -c listen_addresses=127.0.0.1 -p $PORT" start >/dev/null
  export ECHOPIN_TEST_DATABASE_URL="postgresql://echopin@127.0.0.1:$PORT/postgres"
fi

dart test "$@"
