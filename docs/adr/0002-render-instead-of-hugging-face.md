# ADR 0002: Alojar n8n en Render en lugar de Hugging Face

- Estado: aceptado (reemplaza la parte de alojamiento del ADR 0001)
- Fecha: 2026-10-16

## Contexto

El ADR 0001 planeaba ejecutar n8n en un Docker Space gratuito de Hugging Face. Al crear el Space,
Hugging Face respondió: "hosting Gradio and Docker Spaces on free cpu-basic requires a PRO
subscription". Desde julio de 2026, solo los Spaces creados antes conservan el plan gratuito.

## Decisión

Ejecutar n8n como un servicio web gratuito de Render construido desde `deploy/Dockerfile`, en la
región de Virginia (la misma región de AWS que el proyecto de Supabase). Un programador externo le hace ping para que la
instancia gratuita no se suspenda.

## Alternativas consideradas

| Opción | Por qué no se eligió |
|---|---|
| Hugging Face PRO (~9 USD/mes) | El proyecto no debe tener ningún costo |
| Oracle Cloud Always Free | Requiere tarjeta; la capacidad ARM a menudo no está disponible; más trabajo de operación |
| Koyeb | Plan gratuito cerrado a nuevos usuarios tras su adquisición (feb. 2026) |
| PC del desarrollador con un túnel | El bot se detendría cada vez que el PC estuviera apagado |

## Mediciones (límites gratuitos de Render emulados localmente: 512 MB, 0.1 CPU)

- Memoria: 347 MB en reposo, sin terminaciones por falta de memoria.
- Arranque: unos 110 s hasta que `/healthz` responde.
- Tiempo de respuesta: de 2.0 a 4.9 s, la mitad por encima del límite de 3 s de Discord.

## Mediciones en el servicio real de Render (2026-10-16)

- Ruta del webhook con verificación de firma, en caliente, 20 solicitudes desde Colombia: mediana 0.70 s,
  p90 0.98 s, máximo 1.28 s (unos 0.3 s corresponden a la red desde Colombia).
- Primera solicitud después de un reinicio: unos 22 s (el runner de los nodos Code se carga en el primer uso).
- `docker --cpus 0.1` resultó mucho más restrictivo que la CPU real de Render, por lo que la emulación
  local sobrestima los tiempos de respuesta.
- El runner de los nodos Code necesita ~47 s para arrancar, más que el grant token predeterminado de 30 s de n8n:
  `N8N_RUNNERS_GRANT_TOKEN_TTL=180` se establece en `deploy/Dockerfile`.

## Consecuencias

- Por ahora, las respuestas síncronas caben en el límite de 3 s de Discord. Si dejan de caber, se cambiará a las
  respuestas diferidas de Discord (confirmar de inmediato, editar el mensaje después). La suite e2e
  impone un presupuesto de respuesta de 2.5 s para detectar regresiones antes de que los usuarios las vean.
- Un reinicio o despliegue deja el bot no disponible durante unos dos minutos.
- El ping de keep-alive depende de que Render lo tolere; si no lo tolera, el bot responde con retraso después de
  15 minutos sin tráfico.
- El estado de n8n en producción reside en Supabase (esquema `n8n`), por lo que la instancia de Render es
  desechable: volver a desplegarla no pierde nada.
