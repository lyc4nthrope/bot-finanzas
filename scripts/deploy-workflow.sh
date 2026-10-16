#!/usr/bin/env bash
# Imports and publishes an n8n workflow file into the local stack.
# n8n must be stopped while the CLI changes workflows: with n8n running, a restart
# after `publish:workflow` still serves the previously imported version.
# Usage: scripts/deploy-workflow.sh <workflow.json> [webhook path to wait for]
set -euo pipefail
cd "$(dirname "$0")/.."

file=$(realpath "$1")
wait_path=${2:-}
workflow_id=$(jq -r .id "$file")

cli() {
  docker compose run --rm --no-deps -T -v "$file:/tmp/import.json:ro" n8n "$@" 2>&1 \
    | grep -viE 'deprecat|^\s+-|license SDK|migration lock|^$' || true
}

docker compose stop n8n >/dev/null 2>&1
cli import:workflow --input=/tmp/import.json
cli publish:workflow --id="$workflow_id"
docker compose up -d n8n >/dev/null 2>&1

for _ in $(seq 1 90); do
  [[ $(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:5678/healthz) == 200 ]] && break
  sleep 1
done

# The CLI only sets activeVersionId. n8n serves workflow_published_version, which it
# syncs some seconds after startup; until then the previous version answers requests.
synced_sql="SELECT count(*) FROM workflow_entity w JOIN workflow_published_version p ON p.\"workflowId\" = w.id
            WHERE w.id = '$workflow_id' AND p.\"publishedVersionId\" = w.\"activeVersionId\" AND w.\"activeVersionId\" = w.\"versionId\";"
synced=0
for _ in $(seq 1 90); do
  synced=$(docker compose exec -T postgres sh -c 'psql -At -U "$POSTGRES_USER" -d "$POSTGRES_DB"' <<<"$synced_sql")
  [[ $synced == 1 ]] && break
  sleep 1
done
if [[ $synced != 1 ]]; then
  echo "n8n did not switch to the new version of $workflow_id" >&2
  exit 1
fi

# /healthz answers before workflows are activated; when a path is given, wait for the
# webhook itself (an unsigned request must get 401, not 404).
if [[ -n $wait_path ]]; then
  for _ in $(seq 1 90); do
    [[ $(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:5678/webhook/$wait_path" -d '{}') == 401 ]] && exit 0
    sleep 1
  done
  echo "webhook $wait_path did not become ready" >&2
  exit 1
fi
