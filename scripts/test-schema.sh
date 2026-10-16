#!/usr/bin/env bash
# Tests the database rules of sql/001 against the real local Postgres.
# Each case runs in a transaction that is rolled back, so no data is left behind.
# Usage: scripts/test-schema.sh   (requires: docker compose up -d postgres)
set -uo pipefail
cd "$(dirname "$0")/.."

pass=0
fail=0

run_sql() {
  docker compose exec -T postgres sh -c \
    'psql -v ON_ERROR_STOP=1 -q -At -U "$POSTGRES_USER" -d "$POSTGRES_DB"' >/dev/null 2>&1
}

# expect <accept|reject> <description> <values for (interaction_id, user_id, type, amount, category, note)>
expect() {
  local want=$1 desc=$2 values=$3 got
  if printf 'BEGIN;\nINSERT INTO finance.transactions (interaction_id, user_id, type, amount, category, note) VALUES %s;\nROLLBACK;\n' "$values" | run_sql; then
    got=accept
  else
    got=reject
  fi
  if [[ $got == "$want" ]]; then
    pass=$((pass + 1)); echo "PASS  $desc"
  else
    fail=$((fail + 1)); echo "FAIL  $desc (expected $want, got $got)"
  fi
}

U="'123456789012345678'"

expect accept "valid expense"                 "('i1', $U, 'expense', 20000, 'mercado', 'leche')"
expect accept "valid income without note"     "('i1', $U, 'income', 1500000, 'sueldo', NULL)"
expect accept "maximum amount"                "('i1', $U, 'expense', 1000000000, 'otro', NULL)"
expect reject "amount zero"                   "('i1', $U, 'expense', 0, 'mercado', NULL)"
expect reject "negative amount"               "('i1', $U, 'expense', -5000, 'mercado', NULL)"
expect reject "amount above maximum"          "('i1', $U, 'expense', 1000000001, 'mercado', NULL)"
expect reject "unknown type"                  "('i1', $U, 'loan', 5000, 'otro', NULL)"
expect reject "income category on expense"    "('i1', $U, 'expense', 5000, 'sueldo', NULL)"
expect reject "expense category on income"    "('i1', $U, 'income', 5000, 'mercado', NULL)"
expect reject "user id not a snowflake"       "('i1', 'mama', 'expense', 5000, 'mercado', NULL)"
expect reject "note longer than 200 chars"    "('i1', $U, 'expense', 5000, 'mercado', repeat('x', 201))"
expect reject "duplicate interaction id"      "('i1', $U, 'expense', 5000, 'mercado', NULL), ('i1', $U, 'expense', 5000, 'mercado', NULL)"

# Money must be exact: 0.10 + 0.20 has to be exactly 0.30 (it is not with FLOAT).
exact=$(printf "BEGIN;\nINSERT INTO finance.transactions (interaction_id, user_id, type, amount, category) VALUES ('a', $U, 'expense', 0.10, 'otro'), ('b', $U, 'expense', 0.20, 'otro');\nSELECT sum(amount) = 0.30 FROM finance.transactions WHERE interaction_id IN ('a', 'b');\nROLLBACK;\n" \
  | docker compose exec -T postgres sh -c 'psql -q -At -U "$POSTGRES_USER" -d "$POSTGRES_DB"' 2>/dev/null | grep -x '[tf]')
if [[ $exact == t ]]; then
  pass=$((pass + 1)); echo "PASS  amounts add up exactly"
else
  fail=$((fail + 1)); echo "FAIL  amounts add up exactly (got '$exact')"
fi

echo "---"
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
