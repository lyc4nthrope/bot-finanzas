// End-to-end cases for the Discord workflow. Runs inside the n8n container.
// Env: BASE_URL (test webhook URL), PRIVATE_KEY_PEM (throwaway Ed25519 key),
//      TEST_USER_ID (Discord-like id owned by the tests).
import crypto from 'node:crypto';

const { BASE_URL, PRIVATE_KEY_PEM, TEST_USER_ID } = process.env;
const privateKey = crypto.createPrivateKey(PRIVATE_KEY_PEM);
const strangerKey = crypto.generateKeyPairSync('ed25519').privateKey;
const runId = Date.now();
let sequence = 0;
let passed = 0;
let failed = 0;

function interaction(name, options = []) {
  sequence += 1;
  return {
    id: `e2e-${runId}-${sequence}`,
    type: 2,
    member: { user: { id: TEST_USER_ID } },
    data: { name, options: options.map(([optionName, value]) => ({ name: optionName, value })) },
  };
}

async function send(body, { key = privateKey, timestamp, tamper, headers } = {}) {
  const raw = typeof body === 'string' ? body : JSON.stringify(body);
  const ts = String(timestamp ?? Math.floor(Date.now() / 1000));
  const signature = crypto.sign(null, Buffer.from(ts + raw), key).toString('hex');
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

r = await send(interaction('deshacer'));
check('deshacer removes the latest transaction',
  isPrivateReply(r) && reply(r).includes('Eliminado: ingreso de $1.500.000 (sueldo)')
    && reply(r).includes('Saldo total: -$20.000'), r);

r = await send(interaction('gasto', [['monto', -5], ['categoria', 'mercado']]));
check('invalid amount is never confirmed',
  isPrivateReply(r) && reply(r).startsWith('⚠️ No pude guardar') && !reply(r).includes('✅'), r);

r = await send(interaction('prestamo'));
check('unknown command gets a clear answer',
  isPrivateReply(r) && reply(r) === 'No conozco ese comando.', r);

console.log('---');
console.log(`${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
