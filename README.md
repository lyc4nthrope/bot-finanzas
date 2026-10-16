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

## Production

```
Discord ──► Render (n8n, deploy/Dockerfile) ──► Supabase (PostgreSQL)
                 ▲
     cron-job.org pings /healthz every 10 minutes so the free instance never sleeps
```

| Piece | Where | Notes |
|---|---|---|
| n8n | Render free web service, Virginia | Built from `deploy/Dockerfile`; pushes do not auto-deploy |
| n8n state | Supabase, schema `n8n` | Role `n8n_app`; the Render instance is disposable |
| Money data | Supabase, schema `finance` | Role `bot_app`: no UPDATE, no DDL |
| TLS to Supabase | `deploy/supabase-ca.crt` | Certificates verified; never disable verification |

Set up from scratch:

1. `scripts/setup-database.sh supabase --migrate` applies migrations and enables the roles.
2. `scripts/cloud-n8n.sh up`, then open http://localhost:5679 to create the owner account
   and a Postgres credential (`bot_app.<project-ref>`, SSL require) **before** the cloud
   instance exists, so its setup page is never publicly claimable.
3. `scripts/cloud-n8n.sh deploy workflows/discord-interactions.json <credential id> "<credential name>"`,
   then `scripts/cloud-n8n.sh down`.
4. Create the Render service (Docker, `deploy/Dockerfile`, health check `/healthz`) with the
   variables listed in ADR 0002, and point Discord's Interactions Endpoint URL to
   `<render URL>/webhook/discord-interactions`.

Decisions and measurements: `docs/adr/0002-render-instead-of-hugging-face.md`.

## Tests

All tests run against the real local Postgres and n8n; nothing is mocked.

| Script | What it proves |
|---|---|
| `scripts/test-schema.sh` | Table constraints reject invalid money data |
| `scripts/test-functions.sh` | Balances, periods (Bogota calendar), idempotency, undo |
| `scripts/test-roles.sh` | Least privilege: what `bot_app` and `n8n_app` can and cannot do |
| `scripts/test-bot.sh` | The workflow end to end: signatures, replies, database writes |

## Layout

```
discord/    slash command definitions
docs/       contract and architecture decision records (ADR)
sql/        database migrations
workflows/  exported n8n workflows (JSON, no secrets)
scripts/    test and utility scripts
```
