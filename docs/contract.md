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

Respuesta: totales de ingresos y gastos del periodo, lo que queda en el periodo, el saldo total
acumulado y los gastos agrupados por categoría, de mayor a menor. Los periodos usan el calendario
de `America/Bogota`; `semana` comienza el lunes.

```
📊 Resumen de este mes
Ingresos: $20.000
Gastos: $10.000

💵 Te queda este mes: $10.000
   ↳ lo que entró este mes menos lo que gastaste este mes
💰 Saldo total acumulado: $110.000
   ↳ todo lo que has registrado desde el inicio: ingresos menos gastos

Gastos por categoría:
• comida: $10.000
```

- "Te queda" = ingresos del periodo − gastos del periodo; puede ser negativo (`-$5.000`).
  Su etiqueta y su explicación siguen el periodo: `hoy`, `esta semana`, `este mes`, `este año`.
- "Saldo total acumulado" = todos los ingresos − todos los gastos, sin importar el periodo.
- Sin gastos en el periodo, la última sección dice `Sin gastos en este periodo.`

### `/deshacer`

Sin opciones. Elimina el movimiento más reciente de quien envía el comando y muestra lo que se eliminó:
`↩️ Eliminado: gasto de $20.000 (mercado).\nSaldo total: $1.130.000`
Si no hay nada que eliminar: `No hay movimientos para deshacer.`
Los saldos negativos se muestran como `-$20.000`.

### `/ayuda`

Sin opciones. Responde (privado, `flags: 64`) este texto, en Markdown de Discord:

```
📒 **Cómo usar el bot de finanzas**

Escribe **/** en el chat y elige el comando. Lo que respondo **solo lo ves tú**.

💬 **La forma fácil: escríbelo normal**
**/registrar** → "gasté 20 mil en el mercado" o "me pagaron el sueldo, 1 millón y medio"
Te digo lo que entendí. Si me equivoqué, usa **/deshacer**.

✍️ **Si prefieres hacerlo paso a paso**
**/gasto** → pones el valor y eliges en qué se fue (mercado, comida, transporte…)
**/ingreso** → pones el valor y de dónde vino (sueldo, ventas, regalo…)
⚠️ El valor va sin puntos: escribe 20000, no 20.000

📊 **Para saber cómo vas**
**/saldo** → cuánta plata tienes y cuánto llevas gastado este mes
**/resumen** → cuánto te queda y en qué se te fue la plata (hoy, semana, mes o año)

↩️ **¿Te equivocaste?**
**/deshacer** → borra lo último que registraste
```

### `/registrar` (con IA)

| Opción | Tipo | Obligatoria | Reglas |
|---|---|---|---|
| `texto` | STRING | sí | máx. 200 caracteres, por ejemplo `gasté 20 mil en el mercado` |

La IA (modelos gratuitos de OpenRouter) tarda varios segundos, más que el límite de 3 s de
Discord, por eso la respuesta es **diferida**:

1. Tras verificar la firma, el bot responde de inmediato `{"type": 5, "data": {"flags": 64}}`
   y Discord muestra que el bot está pensando (solo a quien envió el comando).
2. El bot pide a la IA un JSON con el esquema `understood`, `type`, `amount`, `category`, `note`.
3. Valida ese JSON (ver abajo) y, solo si es válido, lo registra con la misma función que `/gasto`.
4. Edita el mensaje original con `PATCH /webhooks/{application_id}/{interaction_token}/messages/@original`.

La salida de la IA **no es confiable** y se valida con una lista blanca. Se rechaza, sin registrar
nada, si ocurre cualquiera de estos casos:

- `understood` no es `true`.
- `type` no es `expense` ni `income`.
- `amount` no es un entero entre 1 y 1.000.000.000.
- `category` no pertenece a la lista del tipo (gastos: `mercado`, `comida`, `transporte`,
  `servicios`, `hogar`, `salud`, `deudas`, `otro`; ingresos: `sueldo`, `ventas`, `regalo`, `otro`).
- La respuesta no es JSON o le faltan campos.

La nota se recorta a 200 caracteres. El usuario siempre sale de la interacción firmada, nunca del
texto. El movimiento queda con la fecha del mensaje: palabras como "ayer" no cambian la fecha.

| Caso | Mensaje final |
|---|---|
| Registrado | `🤖 Entendí: gasto de $35.000 en transporte (bus y taxi).\n✅ Registrado. Gastado este mes: $350.000\nSi no es correcto, usa /deshacer.` |
| Ingreso registrado | igual, con `ingreso de` y `Saldo total:` en lugar de `Gastado este mes:` |
| La IA no entendió o su respuesta no pasó la validación | `🤔 No entendí ese movimiento. Intenta con /gasto o /ingreso.` |
| La IA no respondió (error, límite diario o demora) | `⚠️ La IA no está disponible ahora. Usa /gasto o /ingreso.` |
| Base de datos no disponible | `⚠️ No pude guardar el movimiento. Intenta de nuevo en un momento.` |
| Interacción repetida | `Ese movimiento ya estaba registrado.` |

## Errores

| Caso | Respuesta |
|---|---|
| Comando desconocido | `No conozco ese comando.` |
| Base de datos no disponible | `⚠️ No pude guardar el movimiento. Intenta de nuevo en un momento.` |
| Cualquier otra falla | `⚠️ Algo salió mal. Intenta de nuevo.` |

El bot nunca confirma un movimiento que no se haya almacenado.

## Fuera del alcance de v1

- Fechas relativas en `/registrar` ("ayer", "el lunes").
- Edición de movimientos pasados (usa `/deshacer` y registra de nuevo).
- Presupuestos, alertas, notas de voz.
