#!/usr/bin/env bash
# Runs the "n8n-cloud" compose service: a local n8n that reads and writes the
# production n8n state in Supabase. Derives the pooler user for n8n_app from .env.
# Usage: scripts/cloud-n8n.sh <up|down|logs|cli ARGS...>
#        scripts/cloud-n8n.sh deploy <workflow.json> <credential id> <credential name>
set -euo pipefail
cd "$(dirname "$0")/.."

env_value() { grep -E "^$1=" .env | cut -d= -f2-; }
admin_user=$(env_value SUPABASE_DB_USER)
[[ $admin_user == postgres.* ]] || { echo "SUPABASE_DB_USER must look like postgres.<project-ref>" >&2; exit 1; }

# The Supabase pooler identifies the project through "<role>.<project-ref>".
export CLOUD_N8N_DB_USER="n8n_app.${admin_user#postgres.}"

admin_psql() {
  local attempt
  for attempt in 1 2 3; do
    PGPASSWORD=$(env_value SUPABASE_DB_PASSWORD) docker run --rm -e PGPASSWORD postgres:17.11-alpine \
      psql -At "host=$(env_value SUPABASE_DB_HOST) port=5432 dbname=postgres user=$admin_user sslmode=require" \
      -c "$1" 2>/dev/null && return 0
    sleep $((attempt * 2))
  done
  return 1
}

# deploy <workflow.json> <credential id> <credential name>
# Imports a workflow bound to the production Postgres credential and publishes it.
# n8n must be stopped while the CLI changes workflows (see scripts/deploy-workflow.sh).
deploy() {
  local source=$1 credential_id=$2 credential_name=$3 bound workflow_id synced=0
  bound=$(mktemp --suffix=.json)
  trap 'rm -f "$bound"' RETURN
  jq --arg id "$credential_id" --arg name "$credential_name" \
    '(.nodes[] | select(.credentials.postgres)) .credentials.postgres = {id: $id, name: $name}' \
    "$source" > "$bound"
  workflow_id=$(jq -r .id "$bound")

  docker compose --profile cloud stop n8n-cloud >/dev/null 2>&1
  for command in "import:workflow --input=/tmp/import.json" "publish:workflow --id=$workflow_id"; do
    # shellcheck disable=SC2086
    docker compose --profile cloud run --rm --no-deps -T -v "$bound:/tmp/import.json:ro" n8n-cloud $command 2>&1 \
      | grep -E 'Successfully|Publishing|Error' || true
  done
  docker compose --profile cloud up -d n8n-cloud >/dev/null 2>&1

  for _ in $(seq 1 100); do
    synced=$(admin_psql "SELECT count(*) FROM n8n.workflow_entity w JOIN n8n.workflow_published_version p ON p.\"workflowId\" = w.id
      WHERE w.id = '$workflow_id' AND p.\"publishedVersionId\" = w.\"activeVersionId\" AND w.\"activeVersionId\" = w.\"versionId\"") || true
    [[ $synced == 1 ]] && { echo "Published $workflow_id"; return 0; }
    sleep 3
  done
  echo "n8n did not switch to the new version of $workflow_id" >&2
  return 1
}

case ${1:-} in
  deploy) shift; deploy "$@" ;;
  up)   docker compose --profile cloud up -d --build n8n-cloud ;;
  down) docker compose --profile cloud stop n8n-cloud ;;
  logs) docker compose --profile cloud logs --tail "${2:-40}" n8n-cloud ;;
  cli)  shift; docker compose --profile cloud run --rm --no-deps -T n8n-cloud "$@" ;;
  *)    echo "usage: scripts/cloud-n8n.sh <up|down|logs|cli ARGS...>" >&2; exit 1 ;;
esac
