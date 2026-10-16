#!/usr/bin/env bash
# Regenerates docs/images/ from workflows/discord-interactions.json.
# Starts a THROWAWAY n8n (no real data or secrets): creates a random owner, placeholder
# Postgres and OpenRouter credentials and imports the workflow, takes the screenshots, then removes it all.
# Usage: scripts/docs-screenshots.sh
set -euo pipefail
cd "$(dirname "$0")/.."

network=bot-finanzas-docs
n8n=bot-finanzas-docs-n8n
work=$(mktemp -d)
cleanup() { docker rm -f "$n8n" >/dev/null 2>&1 || true; docker network rm "$network" >/dev/null 2>&1 || true; rm -rf "$work"; }
trap cleanup EXIT

docker build -q -t bot-finanzas-docs docs/build >/dev/null
docker pull -q curlimages/curl:8.11.1 >/dev/null
docker build -q -t bot-finanzas-n8n:local -f deploy/Dockerfile . >/dev/null
docker network create "$network" >/dev/null
docker run -d --name "$n8n" --network "$network" -e N8N_SECURE_COOKIE=false \
  -e N8N_DIAGNOSTICS_ENABLED=false -e N8N_PERSONALIZATION_ENABLED=false bot-finanzas-n8n:local >/dev/null

# Talk to n8n's REST API from a container on the same network.
api() { docker run --rm -i --network "$network" --user "$(id -u):$(id -g)" -v "$work:/work" curlimages/curl:8.11.1 -s -b /work/cookies -c /work/cookies "$@"; }
# /healthz answers while the REST API still says "n8n is starting up"; wait for real JSON.
for _ in $(seq 1 90); do
  api "http://$n8n:5678/rest/settings" | jq -e .data >/dev/null 2>&1 && break
  sleep 2
done

password="Docs-$(openssl rand -hex 8)A1"
api -o /dev/null -X POST "http://$n8n:5678/rest/owner/setup" -H 'Content-Type: application/json' \
  -d "{\"email\":\"docs@example.com\",\"firstName\":\"Docs\",\"lastName\":\"Bot\",\"password\":\"$password\"}"
credential_id=$(api -X POST "http://$n8n:5678/rest/credentials" -H 'Content-Type: application/json' \
  -d '{"name":"Postgres local","type":"postgres","data":{"host":"postgres","database":"finanzas","user":"bot_app","password":"documentation-only","port":5432,"ssl":"disable"}}' \
  | jq -r '.data.id')
ai_credential_id=$(api -X POST "http://$n8n:5678/rest/credentials" -H 'Content-Type: application/json' \
  -d '{"name":"OpenRouter","type":"httpHeaderAuth","data":{"name":"Authorization","value":"Bearer documentation-only"}}' \
  | jq -r '.data.id')
jq --arg id "$credential_id" --arg ai "$ai_credential_id" '
  (.nodes[] | select(.credentials.postgres)) .credentials.postgres.id = $id
  | (.nodes[] | select(.credentials.httpHeaderAuth)) .credentials.httpHeaderAuth.id = $ai
  | {name, nodes, connections, settings}' workflows/discord-interactions.json > "$work/workflow.json"
workflow_id=$(api -X POST "http://$n8n:5678/rest/workflows" -H 'Content-Type: application/json' \
  --data-binary @/work/workflow.json | jq -r '.data.id')

mkdir -p docs/images
docker run --rm --network "$network" --user "$(id -u):$(id -g)" -e HOME=/tmp \
  -e N8N_URL="http://$n8n:5678" -e PW="$password" -e WF="$workflow_id" \
  -v "$PWD/docs/build:/build:ro" -v "$PWD/docs/images:/out" \
  bot-finanzas-docs python3 /build/screenshots.py
