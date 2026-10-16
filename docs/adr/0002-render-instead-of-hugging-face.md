# ADR 0002: Host n8n on Render instead of Hugging Face

- Status: accepted (supersedes the hosting part of ADR 0001)
- Date: 2026-10-16

## Context

ADR 0001 planned to run n8n in a free Hugging Face Docker Space. When creating the Space,
Hugging Face answered: "hosting Gradio and Docker Spaces on free cpu-basic requires a PRO
subscription". Since July 2026 only Spaces created earlier keep the free tier.

## Decision

Run n8n as a free Render web service built from `deploy/Dockerfile`, in the Virginia
region (same AWS region as the Supabase project). An external scheduler pings it so the
free instance does not sleep.

## Alternatives considered

| Option | Why not chosen |
|---|---|
| Hugging Face PRO (~9 USD/month) | The project must cost nothing |
| Oracle Cloud Always Free | Requires a card; ARM capacity is often unavailable; more operations work |
| Koyeb | Free tier closed to new users after its acquisition (Feb 2026) |
| Developer PC with a tunnel | The bot would stop whenever the PC is off |

## Measurements (Render free limits emulated locally: 512 MB, 0.1 CPU)

- Memory: 347 MB idle, no out-of-memory kills.
- Startup: about 110 s until `/healthz` answers.
- Reply time: 2.0 to 4.9 s, half above Discord's 3 s limit.

## Measurements on the real Render service (2026-10-16)

- Webhook path with signature check, warm, 20 requests from Colombia: median 0.70 s,
  p90 0.98 s, max 1.28 s (about 0.3 s of that is network from Colombia).
- First request after a restart: about 22 s (the code-node runner loads on first use).
- `docker --cpus 0.1` turned out much stricter than Render's real CPU, so the local
  emulation overestimates reply times.
- The code-node runner needs ~47 s to start, more than n8n's default 30 s grant token:
  `N8N_RUNNERS_GRANT_TOKEN_TTL=180` is set in `deploy/Dockerfile`.

## Consequences

- Synchronous replies fit Discord's 3 s limit for now. If they stop fitting, switch to
  Discord's deferred responses (acknowledge at once, edit the message later). The e2e
  suite enforces a 2.5 s reply budget so regressions are detected before users see them.
- A restart or deploy makes the bot unavailable for about two minutes.
- The keep-alive ping relies on Render tolerating it; if not, the bot answers late after
  15 minutes without traffic.
- Production n8n state lives in Supabase (schema `n8n`), so the Render instance is
  disposable: redeploying it loses nothing.
