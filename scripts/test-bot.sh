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
  | (.nodes[] | select(.type == "n8n-nodes-base.httpRequest") | .parameters.url) |=
      (sub("https://openrouter.ai"; $stub) | sub("https://discord.com"; $stub))
' --arg stub "http://localhost:8787" "$workflow_file" > "$test_file"
grep -q "$public_hex" "$test_file" || { echo "test key was not injected" >&2; exit 1; }

echo "DELETE FROM finance.transactions WHERE user_id = '$TEST_USER_ID';" | sql
scripts/deploy-workflow.sh "$test_file" "$TEST_PATH"

# The /ayuda text must match docs/contract.md exactly: the contract is the source of truth.
help_text=$(awk '/^### `\/ayuda`/{section=1} section && /^```$/{if (inside) exit; inside=1; next} inside' docs/contract.md)
[[ -n $help_text ]] || { echo "could not read the /ayuda text from docs/contract.md" >&2; exit 1; }

# 3. Run the cases inside the n8n container (it has Node and reaches n8n on localhost),
#    with a stub playing OpenRouter and Discord for the AI command.
docker compose cp scripts/e2e.mjs n8n:/tmp/e2e.mjs >/dev/null 2>&1
docker compose cp scripts/stub-server.mjs n8n:/tmp/stub-server.mjs >/dev/null 2>&1
docker compose exec -d n8n node /tmp/stub-server.mjs
for _ in $(seq 1 20); do
  docker compose exec -T n8n wget -q -O /dev/null http://localhost:8787/calls/ping 2>/dev/null && break
  sleep 0.5
done
set +e
docker compose exec -T \
  -e BASE_URL="http://localhost:5678/webhook/$TEST_PATH" \
  -e PRIVATE_KEY_PEM="$private_pem" \
  -e TEST_USER_ID="$TEST_USER_ID" \
  -e STUB_URL="http://localhost:8787" \
  -e HELP_TEXT="$help_text" \
  n8n node /tmp/e2e.mjs
e2e_status=$?
set -e

# 4. What actually reached the database: the /gasto expense (note with its comma intact)
#    plus the five AI registrations that passed validation (one replay stored once), the long
#    note trimmed to 200 and the NUL byte removed.
#    Nothing from the rejected or failed AI calls.
# Exact notes, sorted: a count alone can pass when one extra row hides one missing row.
stored=$(echo "SELECT string_agg(CASE WHEN note = repeat('x', 200) THEN 'x*200' ELSE note END, ';' ORDER BY note COLLATE \"C\")
               FROM finance.transactions WHERE user_id = '$TEST_USER_ID';" | sql)
if [[ $stored == "@everyone hola;arepa, tinto;leche;leche;sueldo;x*200" ]]; then
  echo "PASS  database holds exactly the confirmed transactions, notes intact"
else
  echo "FAIL  database holds exactly the confirmed transactions, notes intact (got: $stored)"
  e2e_status=1
fi

exit "$e2e_status"
