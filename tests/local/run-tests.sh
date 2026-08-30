#!/usr/bin/env bash
# ============================================================
# Runs the whole backend against a throwaway local PostgreSQL,
# no hosted Supabase project required.
#
#   bash tests/local/run-tests.sh
#
# Steps: shim -> 7 migrations -> migrations again (re-run check)
#        -> backend.test.sql -> concurrency.test.sh
#
# Needs: postgresql-16 server running locally and a superuser
# role matching $PGUSER (default: the current OS user).
# ============================================================
set -euo pipefail

DB="${JANEIRO_TEST_DB:-janeiro_test}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HERE="$ROOT/tests/local"

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
bold()  { printf '\033[1m%s\033[0m\n' "$*"; }

bold "==> recreating $DB"
dropdb --if-exists "$DB"
createdb "$DB"

bold "==> applying local Supabase shim"
psql -q -v ON_ERROR_STOP=1 -d "$DB" -f "$HERE/supabase-shim.sql"

bold "==> applying migrations"
for m in "$ROOT"/supabase/migrations/*.sql; do
  printf '    %s\n' "$(basename "$m")"
  psql -q -v ON_ERROR_STOP=1 -d "$DB" -f "$m"
done

# The migrations claim to be idempotent, so a second pass must be clean
# and must not duplicate any seed rows.
bold "==> applying migrations a SECOND time (idempotency check)"
before=$(psql -d "$DB" -X -A -t -c 'select count(*) from payment_methods;')
for m in "$ROOT"/supabase/migrations/*.sql; do
  psql -q -v ON_ERROR_STOP=1 -d "$DB" -f "$m"
done
after=$(psql -d "$DB" -X -A -t -c 'select count(*) from payment_methods;')
if [ "$before" != "$after" ]; then
  red "FAIL: re-running the seed changed payment_methods ($before -> $after)"
  exit 1
fi
green "    migrations re-run cleanly, seed rows stable ($after payment methods)"

bold "==> backend.test.sql"
# The grep is for readability, but a pipeline reports the LAST command's
# status -- so for as long as this was `psql ... | grep ... || true`, a
# backend test that died on a SQL error printed its ERROR line and the
# run still ended with "ALL LOCAL TESTS PASSED". Found the day a broken
# trigger did exactly that. psql's own status is what decides now.
set -o pipefail
if ! psql -v ON_ERROR_STOP=1 -d "$DB" -f "$ROOT/tests/backend.test.sql" 2>&1 \
     | grep -E 'PASS|FAIL|ERROR|=====' ; then
  red "FAIL: backend.test.sql did not run to completion (see the ERROR above)"
  exit 1
fi
set +o pipefail

bold "==> concurrency.test.sh"
bash "$HERE/concurrency.test.sh" "$DB"

echo
green "ALL LOCAL TESTS PASSED"
