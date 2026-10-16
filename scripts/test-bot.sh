#!/usr/bin/env bash
# End-to-end test of an n8n workflow file (default: workflows/discord-interactions.json)
# through real n8n and Postgres.
# Deploys a test copy whose public key belongs to a throwaway key pair, so tests can
# sign requests without Discord's private key. The private key only lives in memory.
# Usage: scripts/test-bot.sh [workflow.json]   (requires: docker compose up -d)
set -euo pipefail
workflow_file=$(realpath "${1:-$(dirname "$0")/../workflows/discord-interactions.json}")
cd "$(dirname "$0")/.."

TEST_USER_ID=100000000000000001
TEST_WORKFLOW_ID=discordFinanzaT1
TEST_PATH=discord-interactions-test
test_file=$(mktemp --suffix=.json)

sql() { docker compose exec -T postgres sh -c 'psql -v ON_ERROR_STOP=1 -q -At -U "$POSTGRES_USER" -d "$POSTGRES_DB"'; }

cleanup() {
  # Leaves the test copy unpublished; its key pair no longer exists anyway.
  docker compose stop n8n >/dev/null 2>&1
  docker compose run --rm --no-deps -T n8n unpublish:workflow --id="$TEST_WORKFLOW_ID" >/dev/null 2>&1 || true
  docker compose up -d n8n >/dev/null 2>&1
  echo "DELETE FROM finance.transactions WHERE user_id = '$TEST_USER_ID';" | sql
  rm -f "$test_file"
}
trap cleanup EXIT

# 1. Throwaway key pair: raw public key (hex) for the workflow, PEM private key for signing.
keys=$(docker compose exec -T n8n node -e '
  const c = require("crypto");
  const { publicKey, privateKey } = c.generateKeyPairSync("ed25519");
  const raw = publicKey.export({ format: "der", type: "spki" }).subarray(12).toString("hex");
  console.log(JSON.stringify({ raw, pem: privateKey.export({ format: "pem", type: "pkcs8" }) }));')
public_hex=$(jq -r .raw <<<"$keys")
private_pem=$(jq -r .pem <<<"$keys")

# 2. Test copy of the workflow: same nodes, test key, test path, test id.
real_key=$(grep -oE "DISCORD_PUBLIC_KEY = '[0-9a-f]{64}'" "$workflow_file" | grep -oE '[0-9a-f]{64}')
jq --arg id "$TEST_WORKFLOW_ID" --arg path "$TEST_PATH" --arg real "$real_key" --arg test "$public_hex" '
  .id = $id
  | .name = "TEST " + .name
  | (.nodes[] | select(.type == "n8n-nodes-base.webhook")) |= (.parameters.path = $path | .webhookId = "00000000-0000-4000-8000-000000000e2e")
  | (.nodes[] | select(.name == "Verify signature") | .parameters.jsCode) |= sub($real; $test)
' "$workflow_file" > "$test_file"
grep -q "$public_hex" "$test_file" || { echo "test key was not injected" >&2; exit 1; }

echo "DELETE FROM finance.transactions WHERE user_id = '$TEST_USER_ID';" | sql
scripts/deploy-workflow.sh "$test_file" "$TEST_PATH"

# 3. Run the cases inside the n8n container (it has Node and reaches n8n on localhost).
docker compose cp scripts/e2e.mjs n8n:/tmp/e2e.mjs >/dev/null 2>&1
set +e
docker compose exec -T \
  -e BASE_URL="http://localhost:5678/webhook/$TEST_PATH" \
  -e PRIVATE_KEY_PEM="$private_pem" \
  -e TEST_USER_ID="$TEST_USER_ID" \
  n8n node /tmp/e2e.mjs
e2e_status=$?
set -e

# 4. What actually reached the database: one expense, note with its comma intact.
stored=$(echo "SELECT count(*) || '|' || coalesce(string_agg(note, ','), '') FROM finance.transactions WHERE user_id = '$TEST_USER_ID';" | sql)
if [[ $stored == "1|arepa, tinto" ]]; then
  echo "PASS  database holds exactly the confirmed expense, note intact"
else
  echo "FAIL  database holds exactly the confirmed expense, note intact (got: $stored)"
  e2e_status=1
fi

exit "$e2e_status"
