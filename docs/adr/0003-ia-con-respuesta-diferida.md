# ADR 0003: Registro con IA mediante respuesta diferida y validación por lista blanca

- Estado: aceptado
- Fecha: 2026-10-16

## Contexto

`/registrar` permite escribir un movimiento en lenguaje natural ("gasté 20 mil en el mercado").
Un modelo de lenguaje lo convierte en datos estructurados. Medición real del 2026-10-16 con
`nvidia/nemotron-3-super-120b-a12b:free` en OpenRouter: 5,8 s por respuesta, casi el doble del
límite de 3 s de Discord. Además, un modelo puede equivocarse, inventar valores u obedecer
instrucciones escondidas en el texto del usuario.

## Decisión

- **Respuesta diferida:** el bot responde de inmediato con `type: 5` (privado) y, cuando la IA
  termina, edita ese mensaje con `PATCH /webhooks/{application_id}/{token}/messages/@original`.
  Discord da 15 minutos para esa edición.
- **Salida estructurada:** se pide JSON con un esquema estricto (`response_format: json_schema`).
- **La salida de la IA no es confiable:** un nodo Code la valida con una lista blanca (tipo,
  entero entre 1 y 1.000.000.000, categoría permitida para ese tipo). Si algo falla, no se
  registra nada y se pide usar `/gasto` o `/ingreso`.
- **La IA nunca decide de quién es el movimiento:** el usuario sale de la interacción firmada.
- **Mismas reglas que el resto del bot:** se reutiliza `finance.record_transaction`, así que las
  restricciones de la base de datos siguen siendo la última defensa.
- **Modelos gratuitos con respaldo:** OpenRouter recibe una lista de modelos y prueba el siguiente
  si el primero falla. La key tiene límite de crédito de $0: solo puede usar modelos gratuitos.

## Alternativas consideradas

| Opción | Por qué no se eligió |
|---|---|
| Responder de forma síncrona | 5,8 s supera el límite de 3 s de Discord |
| Confiar en el JSON del modelo | Un modelo puede devolver categorías inventadas, montos negativos o texto suelto |
| Pedir confirmación antes de registrar | Doble interacción para cada gasto; `/deshacer` cubre los errores con un solo paso |
| Interpretar fechas relativas ("ayer") | Otra fuente de errores; queda fuera del alcance de v1 |

## Consecuencias

- Sin créditos comprados, OpenRouter permite 50 consultas gratuitas al día; si se agotan, el bot
  avisa que la IA no está disponible y no registra nada.
- La respuesta final llega en unos segundos, no al instante.
- Las pruebas usan un servidor falso (`scripts/stub-server.mjs`) que imita a OpenRouter y a
  Discord, para comprobar respuestas válidas, maliciosas y fallidas de forma repetible.
