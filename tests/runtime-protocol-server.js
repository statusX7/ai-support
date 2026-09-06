'use strict';

const http = require('http');
const crypto = require('crypto');
const state = { histories: {}, sent: [], provider: [], segments: {}, webhook: '', slow_seconds: 0, unknown_once: false };
const controlKey = process.env.RUNTIME_PROTOCOL_KEY;
if (!controlKey || controlKey.length < 16) throw new Error('请设置至少 16 字符的隔离测试控制 Key');
const equal = (left, right) => { const first = Buffer.from(String(left || '')); const second = Buffer.from(String(right || '')); return first.length === second.length && crypto.timingSafeEqual(first, second); };
const reply = (response, status, body) => { response.writeHead(status, { 'Content-Type': 'application/json' }); response.end(JSON.stringify(body)); };
const callback = async (body) => {
  if (!state.webhook) throw new Error('隔离测试 Webhook 尚未配置');
  const response = await fetch(state.webhook, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body), signal: AbortSignal.timeout(45000) });
  return { status: response.status, body: await response.json() };
};
const server = http.createServer(async (request, response) => {
  try {
    const url = new URL(request.url, 'http://fixture.invalid');
    const chunks = []; let size = 0;
    for await (const chunk of request) { size += chunk.length; if (size > 2097152) { reply(response, 413, { error: true }); return; } chunks.push(chunk); }
    let body = {}; if (chunks.length) { try { body = JSON.parse(Buffer.concat(chunks)); } catch (_) { reply(response, 400, { error: true }); return; } }
    if (url.pathname.startsWith('/test/')) {
      if (!equal(request.headers['x-test-control'], controlKey)) { reply(response, 403, { error: true }); return; }
      if (url.pathname === '/test/setup') {
        const target = new URL(body.webhook);
        if (!['http:', 'https:'].includes(target.protocol) || target.username || target.password) throw new Error('测试回调无效');
        state.webhook = target.href;
        state.slow_seconds = Math.max(0, Math.min(20, Number(body.slow_seconds || 0)));
        reply(response, 200, { configured: true }); return;
      }
      if (url.pathname === '/test/slow') { state.slow_seconds = Math.max(0, Math.min(20, Number(body.seconds || 0))); reply(response, 200, { configured: true }); return; }
      if (url.pathname === '/test/unknown-send') { state.unknown_once = true; reply(response, 200, { configured: true }); return; }
      if (url.pathname === '/test/event') {
        const session = body.data?.session_id;
        if (!/^session_[A-Za-z0-9-]{8,128}$/.test(session || '')) { reply(response, 400, { error: true }); return; }
        const history = state.histories[session] || (state.histories[session] = []);
        if (body.event === 'message:send' && body.data.type !== 'picker' || body.event === 'message:received') history.push({ ...body.data });
        if (body.event === 'message:updated') {
          const original = history.find((message) => String(message.fingerprint) === String(body.data.fingerprint));
          if (original) original.content = body.data.content;
        }
        reply(response, 200, await callback(body)); return;
      }
      if (url.pathname === '/test/state') { reply(response, 200, { sent: state.sent, provider: state.provider, segments: state.segments }); return; }
      reply(response, 404, { error: true }); return;
    }
    if (/\/models$/.test(url.pathname)) { reply(response, 200, { object: 'list', data: [{ id: 'protocol-model', object: 'model' }] }); return; }
    if (/\/chat\/completions$|\/responses$/.test(url.pathname)) {
      state.provider.push({ path: url.pathname, model: body.model, messages: body.messages || body.input, received_at: Date.now() });
      const wait = state.slow_seconds; if (wait) await new Promise((resolve) => setTimeout(resolve, wait * 1000));
      const answer = '受控协议服务回答，仅用于部署链路验证，不代表真实模型。';
      const item = url.pathname.endsWith('/responses') ? { id: 'resp_protocol_' + crypto.randomBytes(6).toString('hex'), object: 'response', status: 'completed', model: body.model, output: [{ type: 'message', role: 'assistant', content: [{ type: 'output_text', text: answer }] }], usage: { input_tokens: 3, output_tokens: 10, total_tokens: 13 } } : { id: 'chatcmpl_protocol_' + crypto.randomBytes(6).toString('hex'), object: 'chat.completion', created: Math.floor(Date.now() / 1000), model: body.model, choices: [{ index: 0, message: { role: 'assistant', content: answer }, finish_reason: 'stop' }], usage: { prompt_tokens: 3, completion_tokens: 10, total_tokens: 13 } };
      reply(response, 200, item); return;
    }
    const match = url.pathname.match(/^\/v1\/website\/([^/]+)\/conversation\/([^/]+)(\/.*)$/);
    if (!match || !request.headers.authorization || !['website', 'plugin'].includes(request.headers['x-crisp-tier'])) { reply(response, 404, { error: true, reason: 'not_found' }); return; }
    const website = match[1]; const session = match[2]; const suffix = match[3];
    const history = state.histories[session] || (state.histories[session] = []);
    if (suffix === '/messages') { reply(response, 200, { error: false, reason: 'listed', data: history }); return; }
    if (suffix.startsWith('/message/')) { reply(response, 200, { error: false, reason: 'resolved', data: history.find((message) => String(message.fingerprint) === suffix.slice(9)) || {} }); return; }
    if (suffix === '/message' && request.method === 'POST') {
      const existing = history.find((message) => message.from === 'operator' && String(message.fingerprint) === String(body.fingerprint));
      if (!existing) {
        const sent = { ...body, timestamp: Date.now(), session_id: session };
        history.push(sent); state.sent.push(sent);
        if (state.webhook) callback({ website_id: website, event: 'message:received', data: sent, timestamp: Date.now() }).catch(() => {});
      }
      if (state.unknown_once) { state.unknown_once = false; request.socket.destroy(); return; }
      reply(response, 200, { error: false, reason: 'dispatched', data: { fingerprint: body.fingerprint } }); return;
    }
    if (suffix === '/meta') {
      if (request.method === 'PATCH') state.segments[session] = body.segments;
      reply(response, 200, { error: false, reason: 'resolved', data: { segments: state.segments[session] || ['external-synthetic-label'] } }); return;
    }
    reply(response, 404, { error: true });
  } catch (_) { if (!response.headersSent) reply(response, 500, { error: true, reason: 'fixture_failed' }); }
});
server.listen(Number(process.env.RUNTIME_PROTOCOL_PORT || 18787), process.env.RUNTIME_PROTOCOL_BIND || '127.0.0.1', () => process.stdout.write('隔离协议测试服务已启动；并非真实 Crisp 或真实模型。\n'));
// 主机与容器共享同一个协议状态，仅监听回环和明确指定的 Docker 网关。
let containerServer;
if (process.env.RUNTIME_PROTOCOL_CONTAINER_BIND) {
  containerServer = http.createServer((request, response) => server.emit('request', request, response));
  containerServer.listen(Number(process.env.RUNTIME_PROTOCOL_PORT || 18787), process.env.RUNTIME_PROTOCOL_CONTAINER_BIND);
}
process.on('SIGTERM', () => { containerServer?.close(); server.close(() => process.exit(0)); });
