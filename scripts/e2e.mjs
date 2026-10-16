// End-to-end cases for the Discord workflow. Runs inside the n8n container.
// Env: BASE_URL (test webhook URL), PRIVATE_KEY_PEM (throwaway Ed25519 key),
//      TEST_USER_ID (Discord-like id owned by the tests),
//      STUB_URL (scripts/stub-server.mjs, playing OpenRouter and Discord),
//      HELP_TEXT (the /ayuda text from docs/contract.md).
import crypto from 'node:crypto';

const { BASE_URL, PRIVATE_KEY_PEM, TEST_USER_ID, STUB_URL, HELP_TEXT } = process.env;
const privateKey = crypto.createPrivateKey(PRIVATE_KEY_PEM);
const strangerKey = crypto.generateKeyPairSync('ed25519').privateKey;
const runId = Date.now();
let sequence = 0;
let passed = 0;
let failed = 0;
// Discord drops replies after 3 s; leave margin for the network between Discord and n8n.
const MAX_REPLY_MS = 2500;
const replyTimes = [];

function interaction(name, options = []) {
  sequence += 1;
  return {
    id: `e2e-${runId}-${sequence}`,
    token: `token-${runId}-${sequence}`,
    application_id: 'test-application',
    type: 2,
    member: { user: { id: TEST_USER_ID } },
    data: { name, options: options.map(([optionName, value]) => ({ name: optionName, value })) },
  };
}

async function send(body, { key = privateKey, timestamp, tamper, headers } = {}) {
  const raw = typeof body === 'string' ? body : JSON.stringify(body);
  const ts = String(timestamp ?? Math.floor(Date.now() / 1000));
  const signature = crypto.sign(null, Buffer.from(ts + raw), key).toString('hex');
  const started = performance.now();
  const response = await fetch(BASE_URL, {
    method: 'POST',
    headers: headers ?? {
      'content-type': 'application/json',
      'x-signature-ed25519': signature,
      'x-signature-timestamp': ts,
    },
    body: tamper ? raw.replace(tamper[0], tamper[1]) : raw,
  });
  const text = await response.text();
  replyTimes.push(Math.round(performance.now() - started));
  let json = null;
  try { json = JSON.parse(text); } catch { /* not JSON */ }
  return { status: response.status, json, text };
}

function check(description, condition, got) {
  if (condition) {
    passed += 1;
    console.log(`PASS  ${description}`);
  } else {
    failed += 1;
    console.log(`FAIL  ${description} (got: ${JSON.stringify(got).slice(0, 300)})`);
  }
}

function reply(result) {
  return result.json?.data?.content ?? '';
}

const isPrivateReply = (r) => r.status === 200 && r.json?.type === 4 && r.json?.data?.flags === 64;

// --- Signature and transport ---
let r = await send({ type: 1 });
check('PING gets PONG', r.status === 200 && r.json?.type === 1, r);

// Bytes that do not survive JSON.parse + JSON.stringify: the check must use them as sent.
r = await send('{ "type" : 1, "note": "café\\u0020" }');
check('signature is checked over the exact bytes sent', r.status === 200 && r.json?.type === 1, r);

r = await send({ type: 1 }, { key: strangerKey });
check('signature from another key is rejected', r.status === 401, r);

r = await send({ type: 1 }, { headers: { 'content-type': 'application/json' } });
check('missing signature headers are rejected', r.status === 401, r);

r = await send(interaction('saldo'), { tamper: ['saldo', 'resumen'] });
check('body changed after signing is rejected', r.status === 401, r);

r = await send({ type: 1 }, { timestamp: Math.floor(Date.now() / 1000) - 600 });
check('replayed old request is rejected', r.status === 401, r);

// --- Commands ---
const expense = interaction('gasto', [['monto', 20000], ['categoria', 'mercado'], ['nota', 'arepa, tinto']]);
r = await send(expense);
check('gasto confirms amount and category',
  isPrivateReply(r) && reply(r).includes('✅ Gasto registrado: $20.000 en mercado.'), r);

r = await send(expense);
check('same interaction twice is not stored twice',
  isPrivateReply(r) && reply(r) === 'Ese movimiento ya estaba registrado.', r);

r = await send(interaction('ingreso', [['monto', 1500000], ['categoria', 'sueldo']]));
check('ingreso shows the new balance',
  isPrivateReply(r) && reply(r).includes('Saldo total: $1.480.000'), r);

r = await send(interaction('saldo'));
check('saldo shows balance and month totals',
  isPrivateReply(r) && reply(r).includes('Saldo total: $1.480.000')
    && reply(r).includes('ingresos $1.500.000 · gastos $20.000'), r);

r = await send(interaction('resumen', [['periodo', 'semana']]));
check('resumen groups expenses by category',
  isPrivateReply(r) && reply(r).includes('Resumen de esta semana') && reply(r).includes('• mercado: $20.000'), r);
check('resumen explains what is left in the period',
  reply(r).includes('💵 Te queda esta semana: $1.480.000\n   ↳ lo que entró esta semana menos lo que gastaste esta semana'), r);
check('resumen explains the accumulated balance',
  reply(r).includes('💰 Saldo total acumulado: $1.480.000\n   ↳ todo lo que has registrado desde el inicio: ingresos menos gastos'), r);

r = await send(interaction('deshacer'));
check('deshacer removes the latest transaction',
  isPrivateReply(r) && reply(r).includes('Eliminado: ingreso de $1.500.000 (sueldo)')
    && reply(r).includes('Saldo total: -$20.000'), r);

r = await send(interaction('resumen', [['periodo', 'hoy']]));
check('resumen shows a negative remainder when spending exceeds income',
  reply(r).includes('💵 Te queda hoy: -$20.000\n   ↳ lo que entró hoy menos lo que gastaste hoy'), r);

r = await send(interaction('gasto', [['monto', -5], ['categoria', 'mercado']]));
check('invalid amount is never confirmed',
  isPrivateReply(r) && reply(r).startsWith('⚠️ No pude guardar') && !reply(r).includes('✅'), r);

r = await send(interaction('ayuda'));
check('ayuda answers privately with the text from the contract', isPrivateReply(r) && reply(r) === HELP_TEXT, r);

r = await send(interaction('prestamo'));
check('unknown command gets a clear answer',
  isPrivateReply(r) && reply(r) === 'No conozco ese comando.', r);

// --- /registrar (AI, deferred reply) ---
const AI_NOT_UNDERSTOOD = '🤔 No entendí ese movimiento. Intenta con /gasto o /ingreso.';
const AI_UNAVAILABLE = '⚠️ La IA no está disponible ahora. Usa /gasto o /ingreso.';

// Sends /registrar and returns [immediate reply, final edited message, full PATCH body].
// `body` lets a test resend an existing interaction (with a fresh token to observe the edit).
async function register(text, { waitSeconds = 10, body = interaction('registrar', [['texto', text]]) } = {}) {
  const immediate = await send(body);
  let final = null;
  for (let attempt = 0; attempt < waitSeconds * 4 && final === null; attempt += 1) {
    await new Promise((resolve) => setTimeout(resolve, 250));
    final = await (await fetch(`${STUB_URL}/calls/${body.token}`)).json();
  }
  return [immediate, final?.content ?? null, final];
}

const isDeferredPrivate = (r) => r.status === 200 && r.json?.type === 5 && r.json?.data?.flags === 64;

let [first, last, patch] = await register('STUB:valid gasté 20 mil en leche');
check('registrar answers at once with a private deferred reply', isDeferredPrivate(first), first);
check('registrar records a valid parse and says what it understood',
  last?.startsWith('🤖 Entendí: gasto de $20.000 en mercado (leche).')
    && last.includes('✅ Registrado. Gastado este mes:') && last.includes('/deshacer'), last);
check('registrar edits the message with mentions disabled',
  JSON.stringify(patch?.allowed_mentions) === '{"parse":[]}', patch);

[first, last] = await register('STUB:income me pagaron el sueldo');
check('registrar records income with the balance',
  last?.startsWith('🤖 Entendí: ingreso de $1.500.000 en sueldo (sueldo).') && last.includes('Saldo total:'), last);

[first, last] = await register('STUB:long-note gasté 20 mil');
check('registrar trims a long note instead of failing', last?.includes('✅ Registrado.'), last);

const untrusted = ['not-understood', 'bad-category', 'category-type-mismatch', 'negative', 'too-big',
  'amount-as-text', 'decimal-amount', 'not-json', 'missing-fields', 'proto-type', 'constructor-type',
  'wrong-json-types'];
for (const scenario of untrusted) {
  [first, last] = await register(`STUB:${scenario} algo`);
  check(`registrar rejects AI output: ${scenario}`, last === AI_NOT_UNDERSTOOD, last);
}

for (const scenario of ['server-error', 'rate-limited', 'provider-error-200', 'empty-200']) {
  [first, last] = await register(`STUB:${scenario} gasté 20 mil`);
  check(`registrar reports the AI as unavailable: ${scenario}`, last === AI_UNAVAILABLE, last);
}

[first, last] = await register('STUB:slow gasté 20 mil', { waitSeconds: 40 });
check('registrar reports the AI as unavailable when it times out', last === AI_UNAVAILABLE, last);

[first, last] = await register('STUB:mentions gasté 20 mil');
check('registrar stores a note with control characters removed', last?.includes('(@everyone hola).'), last);

const replayed = interaction('registrar', [['texto', 'STUB:valid gasté 20 mil']]);
await register('', { body: replayed });
[first, last] = await register('', { body: { ...replayed, token: `${replayed.token}-again` } });
check('registrar does not store the same interaction twice', last === 'Ese movimiento ya estaba registrado.', last);

// Covers every immediate reply, including the deferred acknowledgements of /registrar.
const slowest = Math.max(...replyTimes);
check(`every reply within ${MAX_REPLY_MS} ms (slowest: ${slowest} ms)`, slowest <= MAX_REPLY_MS, replyTimes);

console.log('---');
console.log(`${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
