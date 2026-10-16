# El workflow de n8n, nodo por nodo

Archivo: `workflows/discord-interactions.json` (25 nodos). Las capturas de pantalla provienen de una
instancia desechable de n8n que importó exactamente este archivo; las credenciales que se muestran son marcadores de posición.

![Vista general del workflow](images/workflow-overview.png)

El flujo: Discord envía cada slash command al webhook. El bot comprueba que la solicitud
realmente proviene de Discord, la enruta según el comando, llama a una función SQL y responde en
la misma respuesta HTTP. Las reglas de negocio residen en PostgreSQL (`sql/`); n8n solo adapta
Discord a la base de datos.

La excepción es `/registrar` (nodos 14 a 24): la IA tarda más que el límite de 3 s de Discord, así
que el bot responde de inmediato que está pensando y después edita ese mensaje con el resultado
(ver `docs/adr/0003-ia-con-respuesta-diferida.md`).

## 1. Discord webhook

Recibe el `POST` de Discord en `/webhook/discord-interactions`. La opción **Raw Body** conserva
los bytes exactos que envió Discord, que la verificación de firma necesita. Las respuestas las genera
más adelante un nodo *Respond to Webhook*, de modo que la solicitud HTTP permanece abierta hasta que el bot tiene
una respuesta.

![Discord webhook](images/node-01-discord-webhook.png)

## 2. Verify signature

JavaScript (nodo Code). Discord firma `timestamp + raw body` con Ed25519; este nodo
la verifica con la clave **pública** de Discord, rechaza timestamps con más de 5 minutos de antigüedad
(solicitudes repetidas) y extrae el comando, sus opciones y el id de usuario de Discord.

Por qué los bytes sin procesar: el JSON analizado por n8n cambia valores como `1.50` a `1.5`, por lo que una verificación
contra JSON re-serializado rechazaría solicitudes legítimas.

![Verify signature](images/node-02-verify-signature.png)

## 3. Is authentic?

Nodo `If` sobre el indicador `authentic`. Todo lo que no esté firmado por Discord va a *Reject 401*
y nunca llega a la base de datos.

![Is authentic?](images/node-03-is-authentic.png)

## 4. Reject 401

Responde `401 invalid request signature`. El propio Discord comprueba este comportamiento cuando se
guarda la Interactions Endpoint URL: envía una solicitud con una firma incorrecta y rechaza
la URL a menos que la respuesta sea 401.

![Reject 401](images/node-04-reject-401.png)

## 5. Route

Nodo `Switch` con cinco salidas: `ping` (la verificación de estado de Discord), `record`
(`/gasto`, `/ingreso`), `summary` (`/saldo`, `/resumen`), `undo` (`/deshacer`) y
`ai` (`/registrar`), `help` (`/ayuda`) y `unknown` (alternativa por defecto).

![Route](images/node-05-route.png)

## 6. Build PONG

Responde al `PING` de Discord con `{"type": 1}`.

![Build PONG](images/node-06-build-pong.png)

## 7. Record transaction

Llama a `finance.record_transaction($1, ... $6)`. Los valores viajan como **parámetros de consulta**,
nunca insertados en el texto SQL, lo que descarta la inyección SQL; una nota como
`arepa, tinto` se almacena con su coma intacta. La salida de error del nodo conduce a
*Build database error*, de modo que una inserción fallida nunca se confirma al usuario.

![Record transaction](images/node-07-record-transaction.png)

## 8. Get summary

Llama a `finance.summary(user, period)` para `/saldo` (mes en curso) y `/resumen`
(`hoy`, `semana`, `mes`, `año`, según el calendario de Bogotá).

![Get summary](images/node-08-get-summary.png)

## 9. Undo last

Llama a `finance.undo_last(user)`, que elimina únicamente el movimiento más reciente de quien envía el comando.

![Undo last](images/node-09-undo-last.png)

## 10. Build unknown command

Responde `No conozco ese comando.` para los comandos que el bot no conoce.

![Build unknown command](images/node-10-build-unknown-command.png)

## 11. Format reply

Convierte el resultado SQL en los mensajes en español definidos en `docs/contract.md`, formatea
el dinero como pesos colombianos (`$1.500.000`, los negativos como `-$20.000`) y establece `flags: 64`
para que solo quien envía el comando vea la respuesta.

![Format reply](images/node-11-format-reply.png)

## 12. Build database error

Se ejecuta cuando falla un nodo de Postgres. Para `/gasto` y `/ingreso` responde
`⚠️ No pude guardar el movimiento...`; en los demás casos, `⚠️ Algo salió mal...`.

![Build database error](images/node-12-build-database-error.png)

## 13. Reply

Nodo *Respond to Webhook* que devuelve a Discord el mensaje que le haya llegado.
Discord descarta las respuestas que tardan más de 3 segundos; las pruebas de extremo a extremo imponen un
presupuesto de 2.5 segundos.

![Reply](images/node-13-reply.png)

## 14. Acknowledge

Primer nodo de `/registrar`. Responde de inmediato `{"type": 5, "data": {"flags": 64}}`: Discord
muestra, solo a quien envió el comando, que el bot está pensando. El workflow sigue ejecutándose
después de esta respuesta.

![Acknowledge](images/node-14-acknowledge.png)

## 15. Build AI request

Arma la petición a OpenRouter: la lista de modelos gratuitos (con respaldo), las instrucciones del
sistema y un esquema JSON estricto. Las instrucciones indican que el texto del usuario son datos,
no órdenes; es una primera barrera, no la defensa principal.

![Build AI request](images/node-15-build-ai-request.png)

## 16. Ask AI

Llama a `https://openrouter.ai/api/v1/chat/completions` con la credencial cifrada `OpenRouter`
(Header Auth) y 25 s de tiempo máximo. Si OpenRouter falla, se agota el límite diario o tarda
demasiado, la salida de error lleva a *Build AI unavailable*.

![Ask AI](images/node-16-ask-ai.png)

## 17. Validate AI output

La defensa principal: trata la respuesta del modelo como entrada no confiable. Solo la acepta si
`understood` es `true`, el tipo es `expense` o `income`, el monto es un entero entre 1 y
1.000.000.000 y la categoría está permitida para ese tipo. Recorta la nota a 200 caracteres.

![Validate AI output](images/node-17-validate-ai-output.png)

## 18. Is valid?

Nodo `If`: lo válido se registra y lo inválido nunca llega a la base de datos.

![Is valid?](images/node-18-is-valid.png)

## 19. Record AI transaction

La misma función `finance.record_transaction` que usa `/gasto`, con parámetros de consulta. El
usuario y el id de la interacción salen de *Verify signature*, nunca del texto ni de la IA.

![Record AI transaction](images/node-19-record-ai-transaction.png)

## 20. Format AI reply

Cuenta lo que entendió y lo que registró, y sugiere `/deshacer` por si la IA se equivocó.

![Format AI reply](images/node-20-format-ai-reply.png)

## 21. Build AI database error

Mensaje para cuando la base de datos falla: el movimiento nunca se confirma si no se guardó.

![Build AI database error](images/node-21-build-ai-database-error.png)

## 22. Build AI not understood

Mensaje para cuando la IA no entendió o su respuesta no pasó la validación.

![Build AI not understood](images/node-22-build-ai-not-understood.png)

## 23. Build AI unavailable

Mensaje para cuando OpenRouter no respondió.

![Build AI unavailable](images/node-23-build-ai-unavailable.png)

## 24. Edit Discord message

Reemplaza el mensaje "pensando" con el resultado mediante
`PATCH /webhooks/{application_id}/{token}/messages/@original`. Reintenta hasta 3 veces si Discord
falla.

![Edit Discord message](images/node-24-edit-discord-message.png)

## 25. Build help

Responde `/ayuda` con el instructivo en palabras sencillas. El texto es el mismo de
`docs/contract.md`: las pruebas de extremo a extremo leen el contrato y exigen que la respuesta
sea idéntica, así que no pueden quedar desalineados.

![Build help](images/node-25-build-help.png)
