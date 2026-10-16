// Test double for OpenRouter and Discord, used by scripts/test-bot.sh.
// Runs inside the n8n container; the test copy of the workflow points its
// https://openrouter.ai and https://discord.com URLs here.
//
// OpenRouter: the reply is chosen by a scenario tag in the user's text, e.g.
//   "STUB:valid gasté 20 mil" -> a correct parse; see SCENARIOS below.
// Discord: records every PATCH to .../messages/@original; GET /calls returns them.
import http from 'node:http';

const PORT = Number(process.env.STUB_PORT ?? 8787);
const patches = {};

const parse = (fields) => JSON.stringify({
  understood: true, type: 'expense', amount: 20000, category: 'mercado', note: 'leche', ...fields,
});

// Each scenario returns [httpStatus, body, delayMs?].
const SCENARIOS = {
  valid: () => [200, completion(parse({}))],
  income: () => [200, completion(parse({ type: 'income', amount: 1500000, category: 'sueldo', note: 'sueldo' }))],
  'not-understood': () => [200, completion(parse({ understood: false }))],
  'bad-category': () => [200, completion(parse({ category: 'lujos' }))],
  'category-type-mismatch': () => [200, completion(parse({ type: 'income', category: 'mercado' }))],
  negative: () => [200, completion(parse({ amount: -5000 }))],
  'too-big': () => [200, completion(parse({ amount: 5000000000 }))],
  'amount-as-text': () => [200, completion(parse({ amount: '20 mil' }))],
  'decimal-amount': () => [200, completion(parse({ amount: 20000.5 }))],
  'not-json': () => [200, completion('Claro, registré tu gasto de 20 mil.')],
  'missing-fields': () => [200, completion(JSON.stringify({ understood: true, amount: 20000 }))],
  'long-note': () => [200, completion(parse({ note: 'x'.repeat(500) }))],
  'server-error': () => [500, { error: { message: 'upstream failure' } }],
  'rate-limited': () => [429, { error: { message: 'Rate limit exceeded: free-models-per-day' } }],
  // Inherited property names: a plain `in` lookup would accept them and crash.
  'proto-type': () => [200, completion(parse({ type: '__proto__' }))],
  'constructor-type': () => [200, completion(parse({ type: 'constructor' }))],
  'wrong-json-types': () => [200, completion(parse({ understood: 'yes', type: ['expense'] }))],
  // OpenRouter can answer 200 with an error body and no choices.
  'provider-error-200': () => [200, { error: { message: 'No endpoints available', code: 503 } }],
  // 200 without choices or error: n8n passes it on, so the validator must catch it.
  'empty-200': () => [200, {}],
  // Longer than the workflow's 25 s timeout.
  slow: () => [200, completion(parse({})), 27000],
  // Echoed note with a mass mention and a NUL byte.
  mentions: () => [200, completion(parse({ note: '@everyone hola\u0000' }))],
};

function completion(content) {
  return { model: 'stub', choices: [{ message: { role: 'assistant', content } }] };
}

function readBody(request) {
  return new Promise((resolve) => {
    let data = '';
    request.on('data', (chunk) => { data += chunk; });
    request.on('end', () => resolve(data));
  });
}

function send(response, status, body) {
  response.writeHead(status, { 'content-type': 'application/json' });
  response.end(JSON.stringify(body));
}

http.createServer(async (request, response) => {
  const body = await readBody(request);

  if (request.method === 'POST' && request.url === '/api/v1/chat/completions') {
    const userText = JSON.parse(body).messages.find((m) => m.role === 'user')?.content ?? '';
    const scenario = /STUB:([a-z0-9-]+)/.exec(userText)?.[1] ?? 'valid';
    if (!(Object.hasOwn(SCENARIOS, scenario))) {
      // Fail loudly: a typo in a test must not silently become a "valid" answer.
      console.error(`unknown stub scenario: ${scenario}`);
      return send(response, 418, { error: { message: `unknown stub scenario: ${scenario}` } });
    }
    const [status, payload, delayMs = 0] = SCENARIOS[scenario]();
    return setTimeout(() => send(response, status, payload), delayMs);
  }

  const patch = /^\/api\/v10\/webhooks\/[^/]+\/([^/]+)\/messages\/@original$/.exec(request.url);
  if (request.method === 'PATCH' && patch) {
    patches[patch[1]] = JSON.parse(body);
    return send(response, 200, { id: 'stub-message' });
  }

  if (request.method === 'GET' && request.url.startsWith('/calls/')) {
    return send(response, 200, patches[decodeURIComponent(request.url.slice('/calls/'.length))] ?? null);
  }

  return send(response, 404, { error: 'not stubbed' });
}).listen(PORT, () => console.log(`stub listening on ${PORT}`));
