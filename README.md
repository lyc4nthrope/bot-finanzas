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

## Layout

```
docs/       contract and architecture decision records (ADR)
sql/        database migrations
workflows/  exported n8n workflows (JSON, no secrets)
scripts/    test and utility scripts
```
