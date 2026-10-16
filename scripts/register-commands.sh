#!/usr/bin/env bash
# Registers discord/commands.json as the bot's global slash commands.
# PUT replaces the whole set, so running it twice is safe (idempotent).
# Reads DISCORD_APPLICATION_ID and DISCORD_BOT_TOKEN from .env; never prints the token.
set -euo pipefail
cd "$(dirname "$0")/.."

env_value() { grep -E "^$1=" .env | cut -d= -f2-; }
app_id=$(env_value DISCORD_APPLICATION_ID)
token=$(env_value DISCORD_BOT_TOKEN)
[[ -n $app_id && -n $token ]] || { echo "Set DISCORD_APPLICATION_ID and DISCORD_BOT_TOKEN in .env" >&2; exit 1; }

response=$(mktemp)
trap 'rm -f "$response"' EXIT
status=$(curl -s -o "$response" -w '%{http_code}' -X PUT \
  -H "Authorization: Bot $token" \
  -H 'Content-Type: application/json' \
  --data-binary @discord/commands.json \
  "https://discord.com/api/v10/applications/$app_id/commands")

if [[ $status != 200 ]]; then
  echo "Discord answered HTTP $status:" >&2
  cat "$response" >&2
  exit 1
fi
echo "Registered commands: $(jq -r '[.[].name] | join(", ")' "$response")"
