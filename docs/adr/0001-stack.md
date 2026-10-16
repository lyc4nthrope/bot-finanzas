# ADR 0001: Stack Discord + n8n + PostgreSQL

- Estado: aceptado
- Fecha: 2026-10-16

## Contexto

Un bot de finanzas para uso personal debe registrar ingresos y gastos desde una aplicación de chat y
responder consultas de saldo. Restricción estricta: costo cero.

## Decisión

- **Canal:** slash commands de Discord, recibidos a través de la Interactions Endpoint URL.
- **Automatización:** n8n en Docker. Desarrollo local, despliegue en un Docker Space de Hugging Face.
- **Almacenamiento:** PostgreSQL. Contenedor local para desarrollo, Supabase para el despliegue.
  El estado propio de n8n también reside en Supabase porque el disco del Space es efímero.
- **Keep-alive:** un programador externo (cron-job.org) hace ping al Space; los Spaces gratuitos se suspenden
  tras 48 horas sin tráfico.
- **IA (opcional, más adelante):** modelos gratuitos de OpenRouter, solo para entradas en texto libre.
  *Actualización: implementada como `/registrar`; ver ADR 0003.*

## Alternativas consideradas

| Opción | Por qué se descartó |
|---|---|
| Telegram | Según se informa, los Spaces de Hugging Face no pueden resolver `api.telegram.org`; el registro puede requerir pagar la verificación por SMS en algunos países |
| WhatsApp Cloud API | Requiere una configuración de Meta Business; demasiado pesado para una primera versión |
| WhatsApp mediante Evolution API | No oficial; riesgo de que se bloquee el número de teléfono |
| Obsidian | Archivos Markdown locales, sin una API que un bot pueda usar de forma confiable |
| Notion | Funciona, pero agregar montos resulta incómodo en comparación con SQL |
| Mensajes de texto libre en Discord | n8n no tiene un trigger oficial para ellos; requiere una conexión persistente al gateway |

## Consecuencias

- Positivas: gratuito, APIs oficiales, solicitudes firmadas, entrada estructurada validada por Discord.
- Negativas: los usuarios necesitan una cuenta de Discord; las respuestas deben llegar en menos de 3 segundos.
- Riesgo: las llamadas salientes desde Hugging Face hacia `discord.com` no están verificadas. Se ejecuta una
  prueba de conectividad antes del despliegue; los comandos básicos evitan por completo las llamadas salientes.
