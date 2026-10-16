#!/usr/bin/env bash
# Tests the least-privilege roles of sql/003 against the real local Postgres.
# Each case switches role with SET ROLE inside a transaction that is rolled back.
# Usage: scripts/test-roles.sh   (requires: docker compose up -d postgres)
set -uo pipefail
cd "$(dirname "$0")/.."

pass=0
fail=0
U="'100000000000000002'"

run() {
  printf 'BEGIN;\nCREATE ROLE nobody_probe;\nGRANT USAGE ON SCHEMA finance TO nobody_probe;\n%s\nROLLBACK;\n' "$1" \
    | docker compose exec -T postgres sh -c \
        'psql -v ON_ERROR_STOP=1 -q -At -U "$POSTGRES_USER" -d "$POSTGRES_DB"' 2>&1
}

report() {
  if [[ $1 == ok ]]; then pass=$((pass + 1)); echo "PASS  $2"
  else fail=$((fail + 1)); echo "FAIL  $2 (got: $3)"; fi
}

# allowed <description> <role> <SQL>
allowed() {
  local out
  if out=$(run "SET ROLE $2; $3"); then report ok "$1"; else report no "$1" "$(grep -m1 ERROR <<<"$out")"; fi
}

# denied <description> <role> <SQL> <text the error must contain>
denied() {
  local out
  if out=$(run "SET ROLE $2; $3"); then report no "$1" "allowed"
  elif grep -q -- "$4" <<<"$out"; then report ok "$1"
  else report no "$1" "wrong error: $(grep -m1 ERROR <<<"$out")"; fi
}

allowed "bot_app records a transaction"        bot_app "SELECT finance.record_transaction('role-1', $U, 'expense', 100, 'otro', NULL);"
allowed "bot_app reads a summary"              bot_app "SELECT finance.summary($U, 'mes');"
allowed "bot_app undoes its last transaction"  bot_app "SELECT finance.undo_last($U);"
denied  "bot_app cannot update amounts"        bot_app "UPDATE finance.transactions SET amount = 1;"            "permission denied for table transactions"
denied  "bot_app cannot empty the table"       bot_app "TRUNCATE finance.transactions;"                         "permission denied for table transactions"
denied  "bot_app cannot drop the table"        bot_app "DROP TABLE finance.transactions;"                       "must be owner of table transactions"
denied  "bot_app cannot create tables"         bot_app "CREATE TABLE finance.x (id int);"                       "permission denied for schema finance"
denied  "bot_app cannot read n8n state"        bot_app "SELECT * FROM n8n.workflow_entity;"                     "permission denied for schema n8n"

allowed "n8n_app manages its own schema"       n8n_app "CREATE TABLE n8n.probe (id int); DROP TABLE n8n.probe;"
# n8n runs this on every start; PostgreSQL checks CREATE on the database even when
# the schema already exists (without it n8n hangs silently at startup).
allowed "n8n_app passes n8n's startup check"   n8n_app 'CREATE SCHEMA IF NOT EXISTS "n8n";'
denied  "n8n_app cannot alter finance schema"  n8n_app "CREATE TABLE finance.x (id int);"                       "permission denied for schema finance"
denied  "n8n_app cannot read money data"       n8n_app "SELECT * FROM finance.transactions;"                    "permission denied for schema finance"
denied  "n8n_app cannot call money functions"  n8n_app "SELECT finance.summary($U, 'mes');"                     "permission denied for"

# A role with schema access but no function grants stands in for PUBLIC
# (and for Supabase's anon/authenticated): only the function REVOKE can stop it.
denied  "other roles cannot call functions"    nobody_probe "SELECT finance.summary($U, 'mes');"                "permission denied for function summary"

echo "---"
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
