#!/usr/bin/env bash
# Corre la migración + prueba e2e en un Postgres desechable con pgvector.
set -euo pipefail
cd "$(dirname "$0")/.."
name=clm-core-test
docker rm -f "$name" >/dev/null 2>&1 || true
docker run -d --name "$name" -e POSTGRES_PASSWORD=x pgvector/pgvector:pg16 >/dev/null
trap 'docker rm -f "$name" >/dev/null' EXIT
until docker exec "$name" pg_isready -U postgres -q; do sleep 1; done
sleep 1
run() { docker exec -i "$name" psql -U postgres -v ON_ERROR_STOP=1 -q "$@"; }
run < tests/_stubs_supabase.sql
run < migrations/20261022000000_clm_core.sql
run < tests/clm_core_test.sql
