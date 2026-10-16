# ADR 0001: Discord + n8n + PostgreSQL stack

- Status: accepted
- Date: 2026-10-16

## Context

A finance bot for personal use must record income and expenses from a chat app and
answer balance questions. Hard constraint: zero cost.

## Decision

- **Channel:** Discord slash commands, received through the Interactions Endpoint URL.
- **Automation:** n8n in Docker. Develop locally, deploy to a Hugging Face Docker Space.
- **Storage:** PostgreSQL. Local container for development, Supabase for deployment.
  n8n's own state also lives in Supabase because the Space disk is ephemeral.
- **Keep-alive:** an external scheduler (cron-job.org) pings the Space; free Spaces sleep
  after 48 hours without traffic.
- **AI (optional, later):** OpenRouter free models, only for free-text input.

## Alternatives considered

| Option | Why rejected |
|---|---|
| Telegram | Hugging Face Spaces reportedly cannot resolve `api.telegram.org`; sign-up may require paying for SMS verification in some countries |
| WhatsApp Cloud API | Requires a Meta Business setup; heavy for a first version |
| WhatsApp via Evolution API | Unofficial; risk of the phone number being banned |
| Obsidian | Local Markdown files, no API a bot can use reliably |
| Notion | Works, but aggregating amounts is awkward compared with SQL |
| Free-text messages on Discord | n8n has no official trigger for them; needs a persistent gateway connection |

## Consequences

- Positive: free, official APIs, signed requests, structured input validated by Discord.
- Negative: users need a Discord account; replies must arrive within 3 seconds.
- Risk: outbound calls from Hugging Face to `discord.com` are unverified. A connectivity
  probe runs before deployment; basic commands avoid outbound calls entirely.
