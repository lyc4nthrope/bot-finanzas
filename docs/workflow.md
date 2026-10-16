# The n8n workflow, node by node

File: `workflows/discord-interactions.json` (13 nodes). Screenshots come from a throwaway
n8n instance that imported this exact file; the Postgres credential shown is a placeholder.

![Workflow overview](images/workflow-overview.png)

The flow: Discord sends every slash command to the webhook. The bot checks the request
really comes from Discord, routes it by command, calls one SQL function, and answers in
the same HTTP response. Business rules live in PostgreSQL (`sql/`); n8n only adapts
Discord to the database.

## 1. Discord webhook

Receives Discord's `POST` on `/webhook/discord-interactions`. The **Raw Body** option keeps
the exact bytes Discord sent, which the signature check needs. Responses are produced
later by a *Respond to Webhook* node, so the HTTP request stays open until the bot has
an answer.

![Discord webhook](images/node-01-discord-webhook.png)

## 2. Verify signature

JavaScript (Code node). Discord signs `timestamp + raw body` with Ed25519; this node
verifies it with Discord's **public** key, rejects timestamps older than 5 minutes
(replayed requests), and extracts the command, its options and the Discord user id.

Why the raw bytes: n8n's parsed JSON changes values such as `1.50` to `1.5`, so a check
against re-serialized JSON would reject genuine requests.

![Verify signature](images/node-02-verify-signature.png)

## 3. Is authentic?

`If` node on the `authentic` flag. Anything not signed by Discord goes to *Reject 401*
and never reaches the database.

![Is authentic?](images/node-03-is-authentic.png)

## 4. Reject 401

Answers `401 invalid request signature`. Discord itself checks this behaviour when the
Interactions Endpoint URL is saved: it sends a request with a bad signature and refuses
the URL unless the answer is 401.

![Reject 401](images/node-04-reject-401.png)

## 5. Route

`Switch` node with five outputs: `ping` (Discord's health check), `record`
(`/gasto`, `/ingreso`), `summary` (`/saldo`, `/resumen`), `undo` (`/deshacer`) and
`unknown` (fallback).

![Route](images/node-05-route.png)

## 6. Build PONG

Answers Discord's `PING` with `{"type": 1}`.

![Build PONG](images/node-06-build-pong.png)

## 7. Record transaction

Calls `finance.record_transaction($1, ... $6)`. Values travel as **query parameters**,
never pasted into the SQL text, which rules out SQL injection; a note such as
`arepa, tinto` is stored with its comma intact. The node's error output leads to
*Build database error*, so a failed insert is never confirmed to the user.

![Record transaction](images/node-07-record-transaction.png)

## 8. Get summary

Calls `finance.summary(user, period)` for `/saldo` (current month) and `/resumen`
(`hoy`, `semana`, `mes`, `año`, on the Bogota calendar).

![Get summary](images/node-08-get-summary.png)

## 9. Undo last

Calls `finance.undo_last(user)`, which deletes only the sender's most recent transaction.

![Undo last](images/node-09-undo-last.png)

## 10. Build unknown command

Answers `No conozco ese comando.` for commands the bot does not know.

![Build unknown command](images/node-10-build-unknown-command.png)

## 11. Format reply

Turns the SQL result into the Spanish messages defined in `docs/contract.md`, formats
money as Colombian pesos (`$1.500.000`, negatives as `-$20.000`) and sets `flags: 64`
so only the sender sees the reply.

![Format reply](images/node-11-format-reply.png)

## 12. Build database error

Runs when a Postgres node fails. For `/gasto` and `/ingreso` it answers
`⚠️ No pude guardar el movimiento...`; otherwise `⚠️ Algo salió mal...`.

![Build database error](images/node-12-build-database-error.png)

## 13. Reply

*Respond to Webhook* node that sends whichever message reached it back to Discord.
Discord drops answers that take more than 3 seconds; the end-to-end tests enforce a
2.5 second budget.

![Reply](images/node-13-reply.png)
