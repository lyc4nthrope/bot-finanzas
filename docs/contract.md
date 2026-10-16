# Bot contract (v1)

What the bot accepts and returns. Code must follow this file; change this file first.

## Transport

- Discord sends each slash command as an HTTPS `POST` to
  `{WEBHOOK_URL}webhook/discord-interactions` (Discord "Interactions Endpoint URL").
- Every request carries `X-Signature-Ed25519` and `X-Signature-Timestamp`.
  The bot verifies the signature over `timestamp + raw body` with `DISCORD_PUBLIC_KEY`.
  - Invalid or missing signature → `401`, nothing is processed.
- `type: 1` (PING) → `{"type": 1}`.
- `type: 2` (APPLICATION_COMMAND) → `{"type": 4, "data": {"content": "...", "flags": 64}}`.
  - `flags: 64` makes the reply visible only to the sender (financial data is private).
- Basic commands must reply in under 3 seconds (Discord limit).

## Identity

- Each transaction belongs to the Discord user id that sent the command (`member.user.id` or `user.id`).
- A user only ever reads and changes their own transactions.

## Amounts

- Option type `INTEGER`, whole Colombian pesos, `min_value: 1`, `max_value: 1000000000`.
- Why INTEGER and not NUMBER: in Colombia `20.000` means twenty thousand. A NUMBER option
  would silently read it as `20`; an INTEGER option makes Discord reject it before sending.
- Displayed as `$20.000` (es-CO format).

## Commands

### `/gasto`

| Option | Type | Required | Rules |
|---|---|---|---|
| `monto` | INTEGER | yes | 1 to 1,000,000,000 |
| `categoria` | STRING (choices) | yes | `mercado`, `comida`, `transporte`, `servicios`, `hogar`, `salud`, `deudas`, `otro` |
| `nota` | STRING | no | max 200 characters |

Reply: `✅ Gasto registrado: $20.000 en mercado.\nGastado este mes: $350.000`

### `/ingreso`

| Option | Type | Required | Rules |
|---|---|---|---|
| `monto` | INTEGER | yes | 1 to 1,000,000,000 |
| `categoria` | STRING (choices) | yes | `sueldo`, `ventas`, `regalo`, `otro` |
| `nota` | STRING | no | max 200 characters |

Reply: `✅ Ingreso registrado: $1.500.000 (sueldo).\nSaldo total: $1.150.000`

### `/saldo`

No options. Reply:

```
💰 Saldo total: $1.150.000
Este mes: ingresos $1.500.000 · gastos $350.000
```

### `/resumen`

| Option | Type | Required | Rules |
|---|---|---|---|
| `periodo` | STRING (choices) | no | `hoy`, `semana`, `mes` (default), `año` |

Reply: totals of income and expenses for the period, plus expenses grouped by category,
largest first. Periods use the `America/Bogota` calendar; `semana` starts on Monday.

### `/deshacer`

No options. Deletes the sender's most recent transaction and shows what was deleted.
If there is nothing to delete: `No hay movimientos para deshacer.`

## Errors

| Case | Reply |
|---|---|
| Unknown command | `No conozco ese comando.` |
| Database unavailable | `⚠️ No pude guardar el movimiento. Intenta de nuevo en un momento.` |
| Any other failure | `⚠️ Algo salió mal. Intenta de nuevo.` |

The bot never confirms a transaction that was not stored.

## Out of scope for v1

- Free-text registration with AI (`/registrar`, phase 6).
- Editing past transactions (use `/deshacer` and register again).
- Budgets, alerts, voice notes.
