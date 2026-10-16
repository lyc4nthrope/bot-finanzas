# bot-finanzas

Personal finance bot: record income and expenses and ask for balances from Discord.

## Stack

| Piece | Tool |
|---|---|
| Chat channel | Discord slash commands |
| Automation | n8n (Docker; local first, then Hugging Face Space) |
| Database | PostgreSQL (local container, then Supabase) |
| Optional AI | OpenRouter free models |

## Setup

1. Copy the environment template and restrict its permissions:

   ```bash
   cp .env.example .env && chmod 600 .env
   ```

2. Fill in `.env`. Values marked `[SECRET]` stay out of chats and commits.

3. Start the local stack (Postgres, n8n and a temporary public tunnel) and apply migrations:

   ```bash
   docker compose --profile tunnel up -d
   for f in sql/0*.up.sql; do
     docker compose exec -T postgres sh -c 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"' < "$f"
   done
   docker compose logs tunnel | grep -o 'https://.*trycloudflare.com'   # public URL
   ```

4. In n8n (http://localhost:5678) create the owner account and a Postgres credential named
   `Postgres local` (host `postgres`, database and user `finanzas`, password from `.env`).

5. Deploy the workflow and register the slash commands:

   ```bash
   scripts/deploy-workflow.sh workflows/discord-interactions.json discord-interactions
   scripts/register-commands.sh
   ```

6. In the Discord Developer Portal set **Interactions Endpoint URL** to
   `<tunnel URL>/webhook/discord-interactions`.

## Tests

All tests run against the real local Postgres and n8n; nothing is mocked.

| Script | What it proves |
|---|---|
| `scripts/test-schema.sh` | Table constraints reject invalid money data |
| `scripts/test-functions.sh` | Balances, periods (Bogota calendar), idempotency, undo |
| `scripts/test-bot.sh` | The workflow end to end: signatures, replies, database writes |

## Layout

```
discord/    slash command definitions
docs/       contract and architecture decision records (ADR)
sql/        database migrations
workflows/  exported n8n workflows (JSON, no secrets)
scripts/    test and utility scripts
```
