# Contrato del bot (v1)

Qué acepta y qué devuelve el bot. El código debe seguir este archivo; primero se modifica este archivo.

## Transporte

- Discord envía cada slash command como un `POST` HTTPS a
  `{WEBHOOK_URL}webhook/discord-interactions` ("Interactions Endpoint URL" de Discord).
- Toda solicitud incluye `X-Signature-Ed25519` y `X-Signature-Timestamp`.
  El bot verifica la firma sobre `timestamp + raw body` (los bytes exactos recibidos,
  nunca JSON re-serializado) con la clave pública de Discord.
  - Firma inválida o ausente → `401`, no se procesa nada.
  - Timestamp con más de 300 segundos de diferencia respecto del reloj del servidor → `401` (protección contra replay).
- `type: 1` (PING) → `{"type": 1}`.
- `type: 2` (APPLICATION_COMMAND) → `{"type": 4, "data": {"content": "...", "flags": 64}}`.
  - `flags: 64` hace que la respuesta solo sea visible para quien la envía (los datos financieros son privados).
- Los comandos básicos deben responder en menos de 3 segundos (límite de Discord).

## Identidad

- Cada movimiento pertenece al id de usuario de Discord que envió el comando (`member.user.id` o `user.id`).
- Un usuario solo puede leer y modificar sus propios movimientos.

## Montos

- Tipo de opción `INTEGER`, pesos colombianos enteros, `min_value: 1`, `max_value: 1000000000`.
- Por qué INTEGER y no NUMBER: en Colombia `20.000` significa veinte mil. Una opción NUMBER
  lo leería silenciosamente como `20`; una opción INTEGER hace que Discord lo rechace antes de enviarlo.
- Se muestra como `$20.000` (formato es-CO).

## Comandos

Las definiciones de los slash commands están en `discord/commands.json`; sus opciones deben coincidir con las
restricciones de la base de datos en `sql/001_transactions.up.sql`.

### `/gasto`

| Opción | Tipo | Obligatoria | Reglas |
|---|---|---|---|
| `monto` | INTEGER | sí | 1 a 1,000,000,000 |
| `categoria` | STRING (choices) | sí | `mercado`, `comida`, `transporte`, `servicios`, `hogar`, `salud`, `deudas`, `otro` |
| `nota` | STRING | no | máximo 200 caracteres |

Respuesta: `✅ Gasto registrado: $20.000 en mercado.\nGastado este mes: $350.000`

La misma interacción entregada dos veces se almacena una sola vez; la repetición recibe
`Ese movimiento ya estaba registrado.` (también aplica a `/ingreso`).

### `/ingreso`

| Opción | Tipo | Obligatoria | Reglas |
|---|---|---|---|
| `monto` | INTEGER | sí | 1 a 1,000,000,000 |
| `categoria` | STRING (choices) | sí | `sueldo`, `ventas`, `regalo`, `otro` |
| `nota` | STRING | no | máximo 200 caracteres |

Respuesta: `✅ Ingreso registrado: $1.500.000 (sueldo).\nSaldo total: $1.150.000`

### `/saldo`

Sin opciones. Respuesta:

```
💰 Saldo total: $1.150.000
Este mes: ingresos $1.500.000 · gastos $350.000
```

### `/resumen`

| Opción | Tipo | Obligatoria | Reglas |
|---|---|---|---|
| `periodo` | STRING (choices) | no | `hoy`, `semana`, `mes` (predeterminado), `año` |

Respuesta: totales de ingresos y gastos del periodo, más los gastos agrupados por categoría,
de mayor a menor. Los periodos usan el calendario de `America/Bogota`; `semana` comienza el lunes.

### `/deshacer`

Sin opciones. Elimina el movimiento más reciente de quien envía el comando y muestra lo que se eliminó:
`↩️ Eliminado: gasto de $20.000 (mercado).\nSaldo total: $1.130.000`
Si no hay nada que eliminar: `No hay movimientos para deshacer.`
Los saldos negativos se muestran como `-$20.000`.

## Errores

| Caso | Respuesta |
|---|---|
| Comando desconocido | `No conozco ese comando.` |
| Base de datos no disponible | `⚠️ No pude guardar el movimiento. Intenta de nuevo en un momento.` |
| Cualquier otra falla | `⚠️ Algo salió mal. Intenta de nuevo.` |

El bot nunca confirma un movimiento que no se haya almacenado.

## Fuera del alcance de v1

- Registro en texto libre con IA (`/registrar`, fase 6).
- Edición de movimientos pasados (usa `/deshacer` y registra de nuevo).
- Presupuestos, alertas, notas de voz.
