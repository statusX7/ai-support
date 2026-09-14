'use strict';

// 生产 runtime -> 生产 provider-adapter 子进程 -> 两个受控上游。
// 本文件验证访客最终出站与进程崩溃恢复，不是真实 Crisp/Provider E2E。
const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const { spawn } = require('node:child_process');
const { createRuntime } = require('../n8n/runtime');
const { signEnvelope } = require('../scripts/provider-envelope');
const { mechanicalFailureAnswer } = require('../scripts/visitor-output');

const project = path.resolve(__dirname, '..');
const area = path.join(project, '.work', 'v1.3.0');
fs.mkdirSync(area, { recursive: true, mode: 0o700 });
const base = fs.mkdtempSync(path.join(area, 'provider-failure-reply-'));
const wait = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));
const writeJson = (file, value) => {
  fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  fs.writeFileSync(file, JSON.stringify(value), { mode: 0o600 });
};
const readJson = (file) => JSON.parse(fs.readFileSync(file, 'utf8'));
const until = async (check, timeout = 5000) => {
  const deadline = Date.now() + timeout;
  let last;
  while (Date.now() < deadline) {
    try {
      last = await check();
      if (last) return last;
    } catch (error) { last = error; }
    await wait(20);
  }
  throw new Error('等待受控测试状态超时' + (last instanceof Error ? `：${last.message}` : ''));
};
const executePool = (root) => new Promise((resolve) => {
  const child = spawn('python3', [path.join(project, 'scripts/provider-pool.py'), '--deploy-dir', root, 'migrate'], {
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  let stdout = '', stderr = '';
  child.stdout.on('data', (chunk) => { stdout += chunk; });
  child.stderr.on('data', (chunk) => { stderr += chunk; });
  child.on('close', (code) => resolve({ code, stdout, stderr }));
});
const reservePort = async () => {
  const server = http.createServer();
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const port = server.address().port;
  await new Promise((resolve) => server.close(resolve));
  return port;
};
const fetchJson = async (url, options = {}) => {
  const controller = new AbortController();
  const abort = () => controller.abort();
  options.signal?.addEventListener('abort', abort, { once: true });
  if (options.signal?.aborted) controller.abort();
  const timer = setTimeout(abort, options.timeout || 10000);
  try {
    const response = await fetch(url, {
      method: options.method || 'GET',
      headers: { ...(options.body === undefined ? {} : { 'content-type': 'application/json' }), ...(options.headers || {}) },
      body: options.body === undefined ? undefined : JSON.stringify(options.body),
      signal: controller.signal,
      redirect: 'error',
    });
    const text = await response.text();
    let body = null;
    try { body = JSON.parse(text); } catch (_) {}
    return { status: response.status, headers: Object.fromEntries(response.headers.entries()), body };
  } finally {
    clearTimeout(timer);
    options.signal?.removeEventListener('abort', abort);
  }
};
const assertNoVisibleFailureReply = (fixture) => {
  assert.equal(fixture.sent.length, 0, '技术故障不得生成访客可见的机械或空泛话术');
};
const assertSingleBusinessReply = (fixture) => {
  assert.equal(fixture.sent.length, 1, '同一问题必须只有一条访客出站');
  const message = fixture.sent[0];
  assert.equal(message.content, '受控正常答案。');
  assert.equal(mechanicalFailureAnswer(message.content), false);
  assert.equal(message.user?.nickname, '在线客服');
  assert.doesNotMatch(message.content, /暂时无法|稍后|稍候|稍等|重试|最希望先解决哪一处|机器人|人工智能|AI(?:客服|助手|系统|模型)/iu);
  assert.doesNotMatch(message.user?.nickname || '', /机器人|人工智能|AI/iu);
};

async function fixture(label, behavior) {
  const root = path.join(base, label);
  const calls = [], sent = [], histories = new Map(), adapterResponses = [];
  let now = Date.now();
  for (const name of ['config', 'data/runtime', 'data/analytics', 'tmp']) {
    fs.mkdirSync(path.join(root, name), { recursive: true, mode: 0o700 });
  }
  for (const name of ['keyword', 'handoff', 'menu', 'tags', 'feedback']) {
    fs.copyFileSync(path.join(project, `config/${name}.yaml.example`), path.join(root, `config/${name}.yaml`));
  }
  const menu = readJson(path.join(root, 'config/menu.yaml'));
  menu.welcome.enabled = false;
  writeJson(path.join(root, 'config/menu.yaml'), menu);
  const prompt = '受控客服规则：只根据当前问题、公开历史和已启用知识回答。';
  fs.writeFileSync(path.join(root, 'config/prompt.md'), prompt, { mode: 0o600 });
  writeJson(path.join(root, 'config/runtime.yaml'), { schema_version: 2, enabled: true, revision: 1, applied_revision: 1 });
  const projection = 'kb_1111111111111111_doc_2222222222222222.md';
  writeJson(path.join(root, 'data/runtime/knowledge-map.json'), { schema_version: 2, revision: 1, documents: [{
    library_id: 'kb_1111111111111111', library_name: '受控资料', document_id: 'doc_2222222222222222', projection,
    location: `custom-documents/${projection}-33333333-3333-4333-8333-333333333333.json`,
  }] });

  let upstreamBehavior = behavior;
  const upstream = http.createServer(async (request, response) => {
    let raw = '';
    for await (const chunk of request) raw += chunk;
    const index = Number(/^\/p(\d+)\//.exec(request.url)?.[1]);
    calls.push({ index, at: Date.now(), body: JSON.parse(raw || '{}') });
    if (upstreamBehavior === 'hang') return;
    response.setHeader('content-type', 'application/json');
    if (upstreamBehavior === '401') {
      response.writeHead(401);
      response.end(JSON.stringify({ error: { code: 'invalid_api_key' } }));
      return;
    }
    if (upstreamBehavior === '429') {
      response.writeHead(429, { 'retry-after': '1' });
      response.end(JSON.stringify({ error: { code: 'rate_limit_exceeded' } }));
      return;
    }
    if (upstreamBehavior === 'error-json') {
      response.end(JSON.stringify({ error: { code: 'synthetic_protocol_error' } }));
      return;
    }
    response.end(JSON.stringify({ choices: [{ message: { role: 'assistant', content: '受控正常答案。' } }] }));
  });
  await new Promise((resolve) => upstream.listen(0, '127.0.0.1', resolve));
  const upstreamBase = `http://127.0.0.1:${upstream.address().port}`;
  fs.writeFileSync(path.join(root, '.env'), [
    `AI_API_BASE_URL=${upstreamBase}/p0/v1`,
    `AI_API_PROBE_BASE_URL=${upstreamBase}/p0/v1`,
    'AI_API_KEY=synthetic-primary-key',
    'AI_MODEL=synthetic-primary',
    'AI_API_MODE=chat_completions',
    '',
  ].join('\n'), { mode: 0o600 });
  writeJson(path.join(root, 'config/provider.yaml'), { schema_version: 2, provider: {
    base_url: `${upstreamBase}/p0/v1`, model: 'synthetic-primary', api_mode: 'chat_completions',
    capabilities: { chat_completions: true, responses: false, vision: false },
  } });
  const migrated = await executePool(root);
  assert.equal(migrated.code, 0, migrated.stderr + migrated.stdout);
  const poolPath = path.join(root, 'config/provider-pool-applied.json');
  const pool = readJson(poolPath);
  const secretPath = path.join(root, 'secrets/provider/generations', `${pool.secrets_generation}.json`);
  const secrets = readJson(secretPath);
  const backupId = 'p_222222222222222222222222';
  pool.entries.push({ ...pool.entries[0], id: backupId, name: '受控备用', role: 'backup', order: 1,
    base_url: `${upstreamBase}/p1/v1`, model: 'synthetic-backup' });
  secrets.entries[backupId] = { api_key: 'synthetic-backup-key', custom_headers: {} };
  Object.assign(pool.policy, { question_timeout_ms: 7000, call_timeout_ms: 1000, connect_timeout_ms: 100,
    max_attempts: 2, cooldown_initial_ms: 1000, cooldown_max_ms: 2000, pool_cooldown_ms: 100 });
  writeJson(secretPath, secrets);
  writeJson(poolPath, pool);
  const internal = /^PROVIDER_ADAPTER_KEY=(.*)$/m.exec(fs.readFileSync(path.join(root, '.env'), 'utf8'))?.[1];
  assert(internal && !/[\r\n]/.test(internal));

  let adapterChild = null;
  let adapterPort = 0;
  let adapterBase = '';
  let adapterErrors = '';
  const startAdapter = async () => {
    adapterPort = await reservePort();
    adapterBase = `http://127.0.0.1:${adapterPort}`;
    adapterErrors = '';
    adapterChild = spawn(process.execPath, [path.join(project, 'scripts/provider-adapter.js')], {
      env: {
        PATH: process.env.PATH || '/usr/bin:/bin', LANG: 'C.UTF-8',
        PROVIDER_ROOT: root, PROVIDER_POOL_REQUIRED: 'true', PROVIDER_REQUIRE_ENVELOPE: 'true',
        PROVIDER_ADAPTER_KEY: internal, PROVIDER_ADAPTER_PORT: String(adapterPort),
      },
      stdio: ['ignore', 'ignore', 'pipe'],
    });
    adapterChild.stderr.on('data', (chunk) => { adapterErrors = (adapterErrors + chunk).slice(-8192); });
    adapterChild.once('error', (error) => { adapterErrors = (adapterErrors + error.message).slice(-8192); });
    await until(async () => {
      if (adapterChild.exitCode !== null) throw new Error('适配器提前退出');
      const result = await fetchJson(`${adapterBase}/healthz`, { timeout: 300 }).catch(() => null);
      return result?.status === 200;
    }, 5000);
  };
  const stopAdapter = async (signal = 'SIGTERM') => {
    const child = adapterChild;
    adapterChild = null;
    if (!child || child.exitCode !== null) return;
    const exited = new Promise((resolve) => child.once('exit', resolve));
    child.kill(signal);
    await Promise.race([exited, wait(1500)]);
    if (child.exitCode === null) {
      child.kill('SIGKILL');
      await exited;
    }
  };
  await startAdapter();

  const rag = http.createServer(async (request, response) => {
    assert.equal(request.headers.authorization, 'Bearer synthetic-rag-key');
    response.setHeader('content-type', 'application/json');
    if (request.method === 'GET') {
      assert.equal(request.url, '/api/v1/workspace/synthetic');
      response.end(JSON.stringify({ workspace: { slug: 'synthetic', openAiTemp: 0.25 } }));
      return;
    }
    let raw = '';
    for await (const chunk of request) raw += chunk;
    assert.equal(request.url, '/api/v1/workspace/synthetic/vector-search');
    assert.equal(typeof JSON.parse(raw).query, 'string');
    response.end(JSON.stringify({ results: [{
      id: '44444444-4444-4444-8444-444444444444', text: '受控资料要求先描述具体问题。',
      metadata: { title: projection }, distance: 0.1, score: 0.9,
    }] }));
  });
  await new Promise((resolve) => rag.listen(0, '127.0.0.1', resolve));
  const env = {
    CRISP_WEBSITE_ID: '11111111-1111-4111-8111-111111111111',
    CRISP_WEBSITE_HOOK_SECRET: 'synthetic-hook-secret', CRISP_AUTH_B64: 'synthetic-crisp-auth',
    ANYTHINGLLM_WORKSPACE: 'synthetic', ANYTHINGLLM_API_KEY: 'synthetic-rag-key',
    ANYTHINGLLM_INTERNAL_URL: `http://127.0.0.1:${rag.address().port}`,
    PROVIDER_ADAPTER_KEY: internal, PROVIDER_POOL_REQUIRED: 'true', PROVIDER_ADAPTER_URL: `${adapterBase}/v1`,
  };
  const request = async (url, options = {}) => {
    const parsed = new URL(url);
    if (parsed.hostname === 'api.crisp.chat') {
      const match = /\/conversation\/([^/]+)(\/.*)$/.exec(parsed.pathname);
      assert(match, `未预期 Crisp 路由：${parsed.pathname}`);
      const session = decodeURIComponent(match[1]);
      const suffix = match[2];
      const history = histories.get(session) || [];
      if (suffix === '/messages') return { status: 200, body: { error: false, data: history } };
      if (suffix.startsWith('/message/')) {
        const fingerprint = decodeURIComponent(suffix.slice('/message/'.length));
        return { status: 200, body: { error: false, data: history.find((item) => String(item.fingerprint) === fingerprint) || {} } };
      }
      if (suffix === '/meta' && options.method === 'GET') return { status: 200, body: { error: false, data: { segments: [] } } };
      if (suffix === '/meta' && options.method === 'PATCH') return { status: 200, body: { error: false } };
      if (suffix === '/message' && options.method === 'POST') {
        const entry = { ...structuredClone(options.body), session_id: session, timestamp: Date.now() };
        sent.push(entry); history.push(entry); histories.set(session, history);
        return { status: 200, body: { error: false, reason: 'dispatched', data: { fingerprint: entry.fingerprint } } };
      }
      throw new Error(`未预期 Crisp 方法：${options.method || 'GET'} ${suffix}`);
    }
    const response = await fetchJson(url, options);
    if (parsed.port === String(adapterPort) && parsed.pathname === '/v1/chat/completions') {
      adapterResponses.push(structuredClone(response));
    }
    return response;
  };
  let runtime;
  const restartRuntime = () => {
    env.PROVIDER_ADAPTER_URL = `${adapterBase}/v1`;
    runtime = createRuntime(env, { root, request, clock: () => now,
      lookup: (_host, _options, callback) => callback(null, [{ address: '8.8.8.8', family: 4 }]) });
  };
  restartRuntime();
  let sequence = 50000;
  const event = (suffix) => ({
    website_id: env.CRISP_WEBSITE_ID, event: 'message:send', timestamp: now,
    data: { session_id: `session_failure-${suffix}`, from: 'user', type: 'text',
      content: '请说明当前处理方式。', fingerprint: ++sequence, timestamp: now },
  });
  const receive = async (body) => {
    const history = histories.get(body.data.session_id) || [];
    if (!history.some((item) => String(item.fingerprint) === String(body.data.fingerprint))) history.push(body.data);
    histories.set(body.data.session_id, history);
    return runtime.receive({ body, query: { key: env.CRISP_WEBSITE_HOOK_SECRET } });
  };
  const deliver = async (body) => {
    const accepted = await receive(body);
    assert.equal(accepted.accepted, true);
    return accepted.route === 'process' ? runtime.process(accepted.key, accepted.jobId) : accepted;
  };
  const state = (session) => runtime.readState(runtime.stateKey(env.CRISP_WEBSITE_ID, session));
  const close = async () => {
    await stopAdapter();
    for (const server of [rag, upstream]) server.closeAllConnections();
    await Promise.all([rag, upstream].map((server) => new Promise((resolve) => server.close(resolve))));
  };
  return {
    root, prompt, pool, internal, calls, sent, adapterResponses, event, receive, deliver, state,
    get adapterBase() { return adapterBase; },
    setBehavior(value) { upstreamBehavior = value; },
    advance(milliseconds) { now += milliseconds; },
    now: () => now,
    async killAdapter() { await stopAdapter('SIGKILL'); },
    async restartAdapter() { await startAdapter(); restartRuntime(); },
    process: (key, jobId) => runtime.process(key, jobId),
    question: (jobId) => readJson(path.join(root, 'data/provider-router/questions', `${jobId}.json`)),
    close,
    adapterErrors: () => adapterErrors,
  };
}

const pendingJob = (fixture, event, jobId) => fixture.state(event.data.session_id).jobs
  .find((entry) => entry.id === jobId);
const advancePastRetry = (fixture, event, jobId) => {
  const job = pendingJob(fixture, event, jobId);
  assert(job && Number.isFinite(job.retry_at), '未完成责任必须登记下一次恢复时间');
  fixture.advance(Math.max(1, job.retry_at - fixture.now() + 1));
};

let passed = 0;
async function test(name, action) {
  const instance = await fixture(`case-${passed}`, 'normal');
  try {
    await action(instance);
    passed += 1;
    console.log(`通过 UNIT/PROTOCOL：${name}`);
  } finally {
    await instance.close();
  }
}

(async () => {
  for (const variant of [
    { name: '全池401', behavior: '401', code: 'authentication_failed' },
    { name: '全池429', behavior: '429', code: 'rate_limited' },
    { name: '全池网络超时', behavior: 'hang', code: 'upstream_timeout' },
    { name: '全池200错误JSON', behavior: 'error-json', code: 'invalid_response' },
  ]) {
    await test(`${variant.name}零可见故障话术，恢复后同一任务只发送一份有效答案`, async (f) => {
      f.setBehavior(variant.behavior);
      const event = f.event(variant.behavior.replace(/[^a-z0-9]+/g, '-'));
      const result = await f.deliver(event);
      assert.equal(result.status, 'unresolved');
      assert.deepEqual(f.calls.map((call) => call.index), [0, 1]);
      assertNoVisibleFailureReply(f);
      assert.equal(f.state(event.data.session_id).mode, 'ai');
      let stored = pendingJob(f, event, result.jobId);
      assert(stored, '原始访客任务不得因技术故障消失');
      assert.equal(stored.status, 'received');
      assert.equal(stored.responsibility_status, 'unresolved_failure');
      assert.equal(stored.failure_code, variant.code);
      assert.equal(stored.data?.content, event.data.content);
      const response = f.adapterResponses.at(-1);
      assert.equal(response.status >= 400, true);
      assert.equal(response.body?.error?.code, variant.code);
      const duplicate = await f.receive(event);
      assert.equal(duplicate.reason, '重复事件已忽略');
      assert.equal(f.calls.length, 2);
      assertNoVisibleFailureReply(f);

      f.setBehavior('normal');
      advancePastRetry(f, event, result.jobId);
      // provider-router 的冷却使用真实单调时间；runtime 的持久退避使用受控时钟。
      await wait(1100);
      const recovered = await f.process(result.key, result.jobId);
      assert.equal(recovered.status, 'sent');
      assert.deepEqual(f.calls.map((call) => call.index), [0, 1, 0]);
      assertSingleBusinessReply(f);
      stored = pendingJob(f, event, result.jobId);
      assert.equal(stored.status, 'done');
      assert.equal(stored.responsibility_status, 'answered_confirmed');
      assert.equal(stored.data, undefined);
      assert.equal((await f.process(result.key, result.jobId)).status, 'idle');
      assert.equal(f.calls.length, 3);
      assert.equal(f.sent.length, 1);
    });
  }

  await test('adapter上游调用中被杀后保留未完成责任，重启恢复同一问题且不重复出站', async (f) => {
    f.setBehavior('hang');
    const event = f.event('interrupted');
    const accepted = await f.receive(event);
    assert.equal(accepted.accepted, true);
    assert.equal(accepted.route, 'process');
    const stateFile = path.join(f.root, 'data/runtime', `session-${accepted.key}.json`);
    const state = readJson(stateFile);
    const job = state.jobs.find((entry) => entry.id === accepted.jobId);
    assert(job);
    const deadlineAt = Date.now() + f.pool.policy.question_timeout_ms;
    job.inference = { pool_revision: f.pool.revision, deadline_at: deadlineAt };
    writeJson(stateFile, state);
    const envelope = {
      version: 1, scope: 'conversation', question_id: accepted.jobId, session_key: accepted.key,
      generation: state.generation, runtime_revision: job.revision, pool_revision: f.pool.revision,
      deadline_at: deadlineAt, stage: 'answer',
    };
    const direct = fetchJson(`${f.adapterBase}/v1/chat/completions`, {
      method: 'POST', timeout: 10000,
      headers: { authorization: `Bearer ${f.internal}`, 'x-crispai-question': signEnvelope(envelope, f.internal) },
      body: { model: 'ignored-by-pool', messages: [
        { role: 'system', content: f.prompt }, { role: 'user', content: '请说明当前处理方式。' },
      ], stream: false },
    }).then((value) => ({ resolved: true, value }), (error) => ({ resolved: false, error }));
    const questionFile = path.join(f.root, 'data/provider-router/questions', `${accepted.jobId}.json`);
    await until(() => f.calls.length === 1 && fs.existsSync(questionFile)
      && readJson(questionFile).stages?.answer?.owner, 3000);
    await f.killAdapter();
    const interrupted = await direct;
    assert.equal(interrupted.resolved, false, '强制终止适配器必须中断原上游请求');
    f.setBehavior('normal');
    await f.restartAdapter();
    let result = await f.process(accepted.key, accepted.jobId);
    if (result.status === 'unresolved') {
      assertNoVisibleFailureReply(f);
      const stored = pendingJob(f, event, accepted.jobId);
      assert.equal(stored.status, 'received');
      assert.equal(stored.responsibility_status, 'unresolved_failure');
      assert.equal(stored.data?.content, event.data.content);
      assert.equal(f.adapterResponses.at(-1).body?.error?.code, 'question_interrupted');
      advancePastRetry(f, event, accepted.jobId);
      await wait(1100);
      result = await f.process(accepted.key, accepted.jobId);
    }
    assert.equal(result.status, 'sent', f.adapterErrors());
    assert.equal(f.calls.length, 2, '恢复轮只允许一次新的有效上游调用');
    assertSingleBusinessReply(f);
    assert.equal(f.state(event.data.session_id).mode, 'ai');
    assert.equal(pendingJob(f, event, accepted.jobId).responsibility_status, 'answered_confirmed');
    const duplicate = await f.receive(event);
    assert.equal(duplicate.reason, '重复事件已忽略');
    await f.process(accepted.key, accepted.jobId);
    assert.equal(f.calls.length, 2);
    assert.equal(f.sent.length, 1);
  });

  writeJson(path.join(base, 'result.json'), { layer: 'UNIT/PROTOCOL', passed, failed: 0, real_external: false });
  console.log(`Provider访客失败收敛：${passed} 通过，0 失败（受控协议服务，不是真实第三方）。`);
})().catch((error) => {
  console.error(error.stack);
  process.exitCode = 1;
}).finally(() => {
  if (process.exitCode !== 1) fs.rmSync(base, { recursive: true, force: true });
});
