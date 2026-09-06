'use strict';

// Chromium executes the shipped SDK bridge against actual n8n public routes.
// The Crisp browser SDK and account are a named protocol fixture, not real Crisp.
const fs = require('fs');
const path = require('path');
const https = require('https');
const crypto = require('crypto');
const assert = require('assert/strict');
const { spawn, execFileSync } = require('child_process');
const WebSocket = require('ws');
const project = path.resolve(__dirname, '..');
if (!process.argv[2]) throw new Error('用法：node tests/test_web_chat_browser.js <受限协议配置JSON>；开发环境需要 chromium/node-ws/openssl');
const config = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const evidence = fs.mkdtempSync(path.join(project, '.work/v1.1.0/browser-'));
fs.chmodSync(evidence, 0o700);
const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const until = async (predicate, limit = 45000) => { const end = Date.now() + limit; do { const value = await predicate(); if (value) return value; await wait(150); } while (Date.now() < end); throw new Error('浏览器验收等待超时'); };
const filenames = Object.fromEntries(['runtime', 'menu'].map((name) => [name, path.join(config.deploy_dir, 'config', name + '.yaml')]));
const originals = Object.fromEntries(Object.entries(filenames).map(([name, filename]) => [name, fs.readFileSync(filename, 'utf8')]));
const write = (name, value) => { const temporary = filenames[name] + '.browser.tmp'; fs.writeFileSync(temporary, JSON.stringify(value), { mode: 0o640 }); fs.chownSync(temporary, 0, 1000); fs.renameSync(temporary, filenames[name]); };
const globalConfig = JSON.parse(originals.runtime);
const menu = JSON.parse(originals.menu);
const call = async (route, body) => { const response = await fetch(config.protocol_url + '/test/' + route, { method: body === undefined ? 'GET' : 'POST', headers: { 'Content-Type': 'application/json', 'X-Test-Control': config.protocol_key }, body: body === undefined ? undefined : JSON.stringify(body), signal: AbortSignal.timeout(45000) }); assert.equal(response.status, 200); return response.json(); };
const key = path.join(evidence, 'localhost.key');
const cert = path.join(evidence, 'localhost.crt');
execFileSync('openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1', '-subj', '/CN=localhost', '-addext', 'subjectAltName=DNS:localhost,IP:127.0.0.1', '-keyout', key, '-out', cert], { stdio: 'ignore' });
fs.chmodSync(key, 0o600);
const certificate = new crypto.X509Certificate(fs.readFileSync(cert));
const pin = crypto.createHash('sha256').update(certificate.publicKey.export({ type: 'spki', format: 'der' })).digest('base64');
const upstream = new URL(config.webhook_url); upstream.search = '';
let selectedSession = '';
let blocked = false;
let port;
let browser;
let socket;
let passed = 0;
const server = https.createServer({ key: fs.readFileSync(key), cert: fs.readFileSync(cert) }, async (request, response) => {
  try {
    const url = new URL(request.url, 'https://localhost');
    if (url.pathname === '/sdk-event') {
      const chunks = []; for await (const chunk of request) chunks.push(chunk);
      const payload = JSON.parse(Buffer.concat(chunks));
      if (payload.session !== selectedSession || !['crispai_widget_load', 'crispai_chat_open'].includes(payload.text)) { response.writeHead(403); response.end(); return; }
      const now = Date.now();
      await call('event', { website_id: config.website_id, event: 'session:sync:events', timestamp: now, data: { session_id: selectedSession, events: [{ text: payload.text, timestamp: now }] } });
      response.writeHead(200); response.end('{}'); return;
    }
    if (url.pathname.startsWith('/webhook/')) {
      if (blocked && url.pathname.endsWith('public-config')) { response.writeHead(503); response.end('{}'); return; }
      const target = new URL(upstream);
      target.pathname = target.pathname.replace(/crisp-webhook$/, url.pathname.split('/').pop()); target.search = url.search;
      const result = await fetch(target, { signal: AbortSignal.timeout(10000) });
      response.writeHead(result.status, { 'Content-Type': result.headers.get('content-type'), 'Cache-Control': 'no-store' }); response.end(await result.text()); return;
    }
    const html = '<!doctype html><meta charset="utf-8"><title>CrispAI 本地浏览器协议验收</title><pre id="result">运行中</pre>' +
      '<script>window.CRISP_WEBSITE_ID=' + JSON.stringify(config.website_id) + ';window.callbacks={};window.emitted=[];window.pending=[];window.$crisp={push:function(e){if(e[0]==="on")callbacks[e[1]]=e[2];else{emitted.push(e);if(e[0]==="set"&&e[1]==="session:event")pending.push(fetch("/sdk-event",{method:"POST",body:JSON.stringify({session:' + JSON.stringify(selectedSession) + ',text:e[2][0][0][0]})}));}}};</script>' +
      '<script src="/webhook/crispai-web-chat" data-config-url="https://localhost:' + port + '/webhook/crispai-public-config" defer></script>' +
      '<script>window.addEventListener("load",async function(){try{await callbacks["session:loaded"](' + JSON.stringify(selectedSession) + ');await callbacks["session:loaded"](' + JSON.stringify(selectedSession) + ');callbacks["chat:opened"]();await new Promise(r=>setTimeout(r,300));await Promise.all(pending);window.__crispaiResult={done:true,emitted};document.getElementById("result").textContent=JSON.stringify(__crispaiResult);}catch(e){window.__crispaiResult={done:true,error:String(e)};}});</script>';
    response.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' }); response.end(html);
  } catch (_) { response.writeHead(500); response.end('{}'); }
});
const record = (name, details) => { passed += 1; fs.writeFileSync(path.join(evidence, 'case-' + passed + '.json'), JSON.stringify(details), { mode: 0o600 }); process.stdout.write('通过 REAL-LOCAL ' + name + '\n'); };
(async () => {
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve)); port = server.address().port;
  await call('setup', { webhook: config.webhook_url });
  const profile = path.join(evidence, 'profile');
  browser = spawn('chromium', ['--headless', '--no-sandbox', '--disable-gpu', '--disable-background-networking', '--no-first-run', '--remote-debugging-port=0', '--remote-debugging-address=127.0.0.1', '--user-data-dir=' + profile, '--ignore-certificate-errors-spki-list=' + pin, 'about:blank'], { stdio: 'ignore' });
  const debugFile = path.join(profile, 'DevToolsActivePort');
  await until(() => fs.existsSync(debugFile));
  const debugPort = fs.readFileSync(debugFile, 'utf8').split('\n')[0];
  const targets = await (await fetch('http://127.0.0.1:' + debugPort + '/json/list')).json();
  socket = new WebSocket(targets.find((target) => target.type === 'page').webSocketDebuggerUrl);
  await new Promise((resolve, reject) => { socket.once('open', resolve); socket.once('error', reject); });
  let sequence = 0; const pending = new Map();
  socket.on('message', (value) => { const message = JSON.parse(value); if (pending.has(message.id)) { const job = pending.get(message.id); pending.delete(message.id); clearTimeout(job.timer); message.error ? job.reject(new Error(JSON.stringify(message.error))) : job.resolve(message.result); } });
  const cdp = (method, params = {}) => new Promise((resolve, reject) => { const id = ++sequence; const timer = setTimeout(() => { pending.delete(id); reject(new Error('CDP 请求超时')); }, 10000); pending.set(id, { resolve, reject, timer }); socket.send(JSON.stringify({ id, method, params })); });
  await cdp('Page.enable');
  const navigate = async () => {
    await cdp('Runtime.evaluate', { expression: 'window.__crispaiResult=null' });
    await cdp('Page.navigate', { url: 'https://localhost:' + port + '/?run=' + crypto.randomBytes(4).toString('hex') });
    return until(async () => { const result = await cdp('Runtime.evaluate', { expression: 'window.__crispaiResult', returnByValue: true }); const value = result.result?.value; if (!value?.done) return false; assert(!value.error, value.error); return value; });
  };
  let index = 0;
  for (const test of [
    { name: '加载后展开且欢迎一次', enabled: true, welcome: true, open: true, trigger: 'widget_load', expectOpen: true, expectWelcome: true },
    { name: '关闭展开不影响加载欢迎', enabled: true, welcome: true, open: false, trigger: 'widget_load', expectOpen: false, expectWelcome: true },
    { name: '总开关关闭浏览器及后端均静默', enabled: false, welcome: true, open: true, trigger: 'widget_load', expectOpen: false, expectWelcome: false },
    { name: '欢迎关闭不展开不欢迎', enabled: true, welcome: false, open: true, trigger: 'widget_load', expectOpen: false, expectWelcome: false },
    { name: '打开聊天框事件经实际生产Hook欢迎', enabled: true, welcome: true, open: false, trigger: 'chat_open', expectOpen: false, expectWelcome: true },
    { name: '人工暂停阻止页面展开及后端欢迎', enabled: true, welcome: true, open: true, trigger: 'widget_load', human: true, expectOpen: false, expectWelcome: false },
    { name: '公开配置不可取时不强制展开', enabled: true, welcome: true, open: true, trigger: 'widget_load', blocked: true, expectOpen: false, expectWelcome: false },
  ]) {
    index += 1; selectedSession = 'session_browser-' + crypto.randomBytes(6).toString('hex'); blocked = Boolean(test.blocked);
    globalConfig.enabled = test.enabled; globalConfig.revision += 1; globalConfig.applied_revision = globalConfig.revision; write('runtime', globalConfig);
    menu.welcome = { ...menu.welcome, enabled: test.welcome, auto_open: test.open, trigger: test.trigger, show_menu: false, text: '虚构浏览器欢迎\n第二行 😀' }; write('menu', menu);
    if (test.human) { const now = Date.now(); await call('event', { website_id: config.website_id, event: 'message:received', timestamp: now, data: { session_id: selectedSession, from: 'operator', type: 'text', automated: false, content: '虚构人工处理', timestamp: now, fingerprint: now } }); }
    const result = await navigate();
    assert.equal(result.emitted.some((event) => event[0] === 'do' && event[1] === 'chat:open'), test.expectOpen);
    const count = async () => (await call('state')).sent.filter((message) => message.session_id === selectedSession && message.content === menu.welcome.text).length;
    if (test.expectWelcome) await until(async () => (await count()) === 1);
    else { await wait(300); assert.equal(await count(), 0); }
    if (index === 1) { await navigate(); await wait(700); assert.equal(await count(), 1); }
    record('T34/T35 ' + test.name, { ...test, emissions: result.emitted.map((event) => event.slice(0, 2)), actual_welcome_count: await count() });
  }
  process.stdout.write(JSON.stringify({ layer: 'REAL-LOCAL', passed, failed: 0, browser: execFileSync('chromium', ['--version'], { encoding: 'utf8' }).trim(), evidence: path.relative(project, evidence), external: '真实Chromium与n8n；Crisp SDK账户为协议fixture，非真实Crisp UI' }) + '\n');
})().catch((error) => { process.stderr.write(error.stack + '\n'); process.exitCode = 1; }).finally(async () => {
  socket?.close(); browser?.kill('SIGTERM'); await new Promise((resolve) => server.close(resolve));
  for (const [name, original] of Object.entries(originals)) write(name, JSON.parse(original));
});
