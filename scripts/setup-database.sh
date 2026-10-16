#!/usr/bin/env bash
# Prepares a database for the bot: optionally applies the migrations, then enables
# the least-privilege roles of sql/003 with the passwords from .env and checks that
# each role can log in and do its job.
# Passwords are sent as SCRAM-SHA-256 verifiers computed on this machine, so the
# plaintext never reaches the server or its logs.
# Usage: scripts/setup-database.sh <local|supabase> [--migrate]
set -euo pipefail
cd "$(dirname "$0")/.."

target=${1:?usage: scripts/setup-database.sh <local|supabase> [--migrate]}
migrate=${2:-}

# Reads a value as plain text; never eval .env (passwords may contain quotes).
env_value() { grep -E "^$1=" .env | cut -d= -f2-; }

case $target in
  local)
    db=$(env_value POSTGRES_DB)
    admin_psql() {
      docker compose exec -T postgres sh -c \
        'psql -v ON_ERROR_STOP=1 -q -At -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
    }
    # role_psql <role> <password>: logs in from another container over the compose
    # network, as n8n does. Inside the postgres container 127.0.0.1 is "trust" and
    # would accept any password.
    role_psql() {
      PGPASSWORD=$2 docker compose run --rm --no-deps -T -e PGPASSWORD postgres \
        psql -v ON_ERROR_STOP=1 -q -At -h postgres -U "$1" -d "$db" 2>/dev/null
    }
    ;;
  supabase)
    host=$(env_value SUPABASE_DB_HOST)
    port=$(env_value SUPABASE_DB_PORT)
    db=$(env_value SUPABASE_DB_NAME)
    admin_user=$(env_value SUPABASE_DB_USER)
    if [[ -z $host || $admin_user != postgres.* ]]; then
      echo "Set SUPABASE_DB_HOST and SUPABASE_DB_USER (postgres.<project-ref>) in .env" >&2
      exit 1
    fi
    project_ref=${admin_user#postgres.}
    # The pooler occasionally rejects a valid login when connections come in quick
    # succession. Retries only that: a SQL error is never retried, because the
    # statements could have partially run.
    remote_psql() {
      local sql output attempt
      sql=$(cat)
      for attempt in 1 2 3; do
        if output=$(PGPASSWORD=$2 docker run --rm -i -e PGPASSWORD postgres:17.11-alpine \
            psql -v ON_ERROR_STOP=1 -q -At \
            "host=$host port=$port dbname=$db user=$1 sslmode=require connect_timeout=10" \
            <<<"$sql" 2>&1); then
          [[ -n $output ]] && printf '%s\n' "$output"
          return 0
        fi
        if ! grep -qE 'connection to server .* failed' <<<"$output" || [[ $attempt == 3 ]]; then
          printf '%s\n' "$output" >&2
          return 1
        fi
        sleep $((attempt * 2))
      done
    }
    admin_psql() { remote_psql "$admin_user" "$(env_value SUPABASE_DB_PASSWORD)"; }
    # The Supabase pooler identifies the project through the "<role>.<ref>" user name.
    role_psql() { remote_psql "$1.$project_ref" "$2"; }
    ;;
  *)
    echo "Unknown target: $target (use local or supabase)" >&2
    exit 1
    ;;
esac

if [[ $migrate == --migrate ]]; then
  for file in sql/0*.up.sql; do
    echo "Applying $file"
    admin_psql < "$file"
  done
fi

# SCRAM-SHA-256 verifier in the format PostgreSQL stores (RFC 5802 / RFC 7677).
scram_verifier() {
  PASSWORD=$1 python3 -I -c '
import base64, hashlib, hmac, os
password = os.environ["PASSWORD"].encode()
salt, iterations = os.urandom(16), 4096
salted = hashlib.pbkdf2_hmac("sha256", password, salt, iterations)
client_key = hmac.new(salted, b"Client Key", "sha256").digest()
server_key = hmac.new(salted, b"Server Key", "sha256").digest()
b64 = lambda raw: base64.b64encode(raw).decode()
print(f"SCRAM-SHA-256${iterations}:{b64(salt)}${b64(hashlib.sha256(client_key).digest())}:{b64(server_key)}")'
}

n8n_password=$(env_value DB_N8N_PASSWORD)
bot_password=$(env_value DB_BOT_PASSWORD)
if [[ -z $n8n_password || -z $bot_password ]]; then
  echo "Set DB_N8N_PASSWORD and DB_BOT_PASSWORD in .env" >&2
  exit 1
fi

for role in n8n_app bot_app; do
  [[ $role == n8n_app ]] && password=$n8n_password || password=$bot_password
  printf "ALTER ROLE %s WITH LOGIN PASSWORD '%s';\n" "$role" "$(scram_verifier "$password")" | admin_psql
  echo "Enabled login for $role"
done

# Each role logs in with its own password and does exactly its job.
bot_check=$(echo "SELECT finance.summary('100000000000000003', 'mes')->>'period';" | role_psql bot_app "$bot_password")
n8n_check=$(echo "CREATE TABLE n8n.setup_probe (id int); DROP TABLE n8n.setup_probe; SELECT 'ok';" | role_psql n8n_app "$n8n_password")
if [[ $bot_check == mes && $n8n_check == ok ]]; then
  echo "Verified: bot_app reads finance, n8n_app manages schema n8n ($target)"
else
  echo "Role check failed: bot_app='$bot_check' n8n_app='$n8n_check'" >&2
  exit 1
fi
