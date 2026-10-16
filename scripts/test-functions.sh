#!/usr/bin/env bash
# Tests the functions of sql/002 against the real local Postgres.
# "Now" is pinned to Friday 2026-10-16 12:00 Bogota; fixtures sit on period edges
# where Bogota and UTC disagree. Every case is rolled back.
# Usage: scripts/test-functions.sh   (requires: docker compose up -d postgres)
set -uo pipefail
cd "$(dirname "$0")/.."

pass=0
fail=0

A="'111111111111111111'"
B="'222222222222222222'"
NOW="'2026-10-16 12:00-05'::timestamptz"

FIXTURES="
INSERT INTO finance.transactions (interaction_id, user_id, type, amount, category, created_at) VALUES
  ('f1', $A, 'income',  1500000, 'sueldo',     '2026-10-01 08:00-05'),  -- this month
  ('f2', $A, 'expense',   20000, 'mercado',    '2026-10-16 09:00-05'),  -- today
  ('f3', $A, 'expense',   30000, 'mercado',    '2026-10-13 10:00-05'),  -- this week (Tuesday)
  ('f4', $A, 'expense',    5000, 'transporte', '2026-10-15 23:30-05'),  -- yesterday; already 16th in UTC
  ('f5', $A, 'expense',  100000, 'salud',      '2026-09-30 20:00-05'),  -- last month; already Oct 1 in UTC
  ('f6', $A, 'income',    50000, 'ventas',     '2025-12-31 22:00-05'),  -- last year; already 2026 in UTC
  ('f7', $B, 'expense',     999, 'comida',     '2026-10-16 10:00-05'),  -- another user
  ('f8', $A, 'expense',    8000, 'comida',     '2026-10-11 22:00-05');  -- Sunday night: this month, last week; Monday in UTC
"

query() {
  printf 'BEGIN;\n%s\n%s\nROLLBACK;\n' "$FIXTURES" "$1" \
    | docker compose exec -T postgres sh -c \
        'psql -v ON_ERROR_STOP=1 -q -At -U "$POSTGRES_USER" -d "$POSTGRES_DB"' 2>&1
}

report() {
  if [[ $1 == ok ]]; then pass=$((pass + 1)); echo "PASS  $2"
  else fail=$((fail + 1)); echo "FAIL  $2 (got: $3)"; fi
}

# check <description> <SQL returning one boolean>
check() {
  local out; out=$(query "SELECT ($2);" | tail -1)
  [[ $out == t ]] && report ok "$1" || report no "$1" "$out"
}

# check_after <description> <SQL statements to run first> <SQL returning one boolean>
# The boolean runs in a later statement: within one statement PostgreSQL reads a
# snapshot taken before the function wrote anything (MVCC).
check_after() {
  local out; out=$(query "$2
SELECT ($3);" | tail -1)
  [[ $out == t ]] && report ok "$1" || report no "$1" "$out"
}

# check_error <description> <SQL that must fail> <text the error must contain>
check_error() {
  local out
  if out=$(query "$2"); then report no "$1" "no error"
  elif grep -q -- "$3" <<<"$out"; then report ok "$1"
  else report no "$1" "wrong error: $(grep -m1 ERROR <<<"$out")"; fi
}

S="finance.summary($A, '%s', $NOW)"
s() { printf "$S" "$1"; }

check "today: only today's expense, Bogota calendar"   "($(s hoy)->>'expense')::numeric = 20000"
check "week starts Monday"                             "($(s semana)->>'expense')::numeric = 55000"
check "month excludes Sep 30 night (Oct 1 in UTC)"     "($(s mes)->>'expense')::numeric = 63000"
check "month income"                                   "($(s mes)->>'income')::numeric = 1500000"
check "year excludes Dec 31 night (2026 in UTC)"       "($(s año)->>'income')::numeric = 1500000 AND ($(s año)->>'expense')::numeric = 163000"
check "balance is all-time income minus expenses"      "($(s mes)->>'balance')::numeric = 1387000"
check "categories ordered by total, largest first"     "$(s mes)->'by_category' = '[{\"category\":\"mercado\",\"total\":50000},{\"category\":\"comida\",\"total\":8000},{\"category\":\"transporte\",\"total\":5000}]'::jsonb"
check "user isolation: B only sees B"                  "(finance.summary($B, 'hoy', $NOW)->>'expense')::numeric = 999"
check "unknown user gets zeros"                        "finance.summary('333333333333333333', 'mes', $NOW) = '{\"period\":\"mes\",\"income\":0,\"expense\":0,\"balance\":0,\"by_category\":[]}'::jsonb"
check_error "unknown period is rejected"               "SELECT finance.summary($A, 'siglo', $NOW);" "unknown period"

check_after "record stores the transaction" \
  "CREATE TEMP TABLE r AS SELECT finance.record_transaction('r1', $A, 'expense', 7000, 'comida', 'arepa, tinto') AS j;" \
  "(SELECT (j->>'inserted')::boolean FROM r) AND (SELECT note = 'arepa, tinto' AND amount = 7000 FROM finance.transactions WHERE interaction_id = 'r1')"
check_after "record reports the updated month" \
  "CREATE TEMP TABLE r AS SELECT finance.record_transaction('r1', $A, 'expense', 7000, 'comida', NULL) AS j;" \
  "(SELECT (j->>'expense')::numeric FROM r) = (finance.summary($A, 'mes')->>'expense')::numeric AND (SELECT j->>'amount' FROM r) = '7000'"
check_after "record twice with same interaction is a no-op" \
  "SELECT finance.record_transaction('r1', $A, 'expense', 7000, 'comida', NULL);
   CREATE TEMP TABLE r AS SELECT finance.record_transaction('r1', $A, 'expense', 7000, 'comida', NULL) AS j;" \
  "NOT (SELECT (j->>'inserted')::boolean FROM r) AND (SELECT count(*) FROM finance.transactions WHERE interaction_id = 'r1') = 1"
check_after "blank note is stored as NULL" \
  "SELECT finance.record_transaction('r2', $A, 'expense', 7000, 'comida', '   ');" \
  "(SELECT note IS NULL FROM finance.transactions WHERE interaction_id = 'r2')"
check_error "record rejects a negative amount"         "SELECT finance.record_transaction('r3', $A, 'expense', -1, 'comida', NULL);" "transactions_amount_check"
check_error "record rejects wrong category for type"   "SELECT finance.record_transaction('r4', $A, 'income', 10, 'mercado', NULL);" "category_matches_type"

check_after "undo deletes the user's latest transaction" \
  "CREATE TEMP TABLE r AS SELECT finance.undo_last($A) AS j;" \
  "(SELECT j @> '{\"deleted\":true,\"amount\":20000,\"category\":\"mercado\"}'::jsonb FROM r) AND NOT EXISTS (SELECT 1 FROM finance.transactions WHERE interaction_id = 'f2') AND (SELECT count(*) FROM finance.transactions WHERE user_id = $A) = 6"
check_after "undo never touches another user's data" \
  "SELECT finance.undo_last($A) FROM generate_series(1, 10);" \
  "(SELECT count(*) FROM finance.transactions WHERE user_id = $A) = 0 AND EXISTS (SELECT 1 FROM finance.transactions WHERE interaction_id = 'f7')"
check "undo with nothing to delete"                    "finance.undo_last('333333333333333333') = '{\"deleted\":false}'::jsonb"

echo "---"
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
