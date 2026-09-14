'use strict';

// 生产 runtime -> 生产 provider-adapter 子进程 -> 两个受控上游。
// 本文件验证访客最终出站与进程崩溃恢复，不是真实 Crisp/Provider E2E。
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const { spawn } = require('node:child_process');
const { createRuntime } = require('../n8n/runtime');
const { signEnvelope, requestContract } = require('../scripts/provider-envelope');
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
const canonical = (value) => Array.isArray(value) ? '[' + value.map(canonical).join(',') + ']'
  : value && typeof value === 'object' ? '{' + Object.keys(value).sort()
    .map((key) => JSON.stringify(key) + ':' + canonical(value[key])).join(',') + '}'
    : JSON.stringify(value);
const digest = (value) => crypto.createHash('sha256').update(value).digest('hex');
const sealMaterials = (value) => {
  const runtime = structuredClone(value.configuration.runtime);
  delete runtime.revision;
  delete runtime.applied_revision;
  value.source_components = {
    runtime: digest(canonical(runtime)),
    handoff: digest(canonical(value.configuration.handoff)),
    keyword: digest(canonical(value.configuration.keyword)),
    menu: digest(canonical(value.configuration.menu)),
    tags: digest(canonical(value.configuration.tags)),
    feedback: digest(canonical(value.configuration.feedback)),
    prompt: value.prompt.sha256,
    knowledge: digest(canonical(value.knowledge)),
  };
  value.source_sha256 = digest(canonical(value.source_components));
  return value;
};
const assertReplyReadyMaterials = (root, materials) => {
  const mapRaw = fs.readFileSync(path.join(root, 'data/runtime/knowledge-map.json'));
  const settingsRaw = fs.readFileSync(path.join(root, 'data/runtime/knowledge-settings.json'));
  const profileRaw = fs.readFileSync(path.join(root, 'data/runtime/knowledge-profile.json'));
  const lexicalRaw = fs.readFileSync(path.join(root, 'data/runtime/knowledge-lexical.json'));
  const map = JSON.parse(mapRaw);
  const settings = JSON.parse(settingsRaw);
  const profile = JSON.parse(profileRaw);
  const lexical = JSON.parse(lexicalRaw);
  assert.equal(materials.schema_version, 2);
  assert.equal(materials.state, 'applied');
  assert.equal(materials.configuration.runtime.enabled, true);
  assert.equal(materials.configuration.runtime.revision, materials.revision);
  assert.equal(materials.configuration.runtime.applied_revision, materials.revision);
  assert.equal(materials.prompt.bytes, Buffer.byteLength(materials.prompt.text));
  assert.equal(materials.prompt.sha256, digest(materials.prompt.text));
  assert.equal(materials.knowledge.map_sha256, digest(mapRaw));
  assert.equal(materials.knowledge.settings_sha256, digest(settingsRaw));
  assert.equal(materials.knowledge.profile_sha256, digest(profileRaw));
  assert.equal(materials.knowledge.lexical_sha256, digest(lexicalRaw));
  assert.equal(map.schema_version, 2);
  assert.equal(materials.knowledge.enabled_document_count, map.documents.length);
  assert.deepEqual(materials.knowledge.enabled_library_ids,
    [...new Set(map.documents.map((item) => item.library_id))].sort());
  assert.equal(settings.schema_version, 1);
  assert.equal(settings.workspace_slug, 'synthetic');
  assert.equal(typeof settings.temperature, 'number');
  assert.equal(profile.state, 'applied');
  assert.equal(profile.fingerprint, digest(canonical(profile.profile)));
  assert.equal(lexical.schema_version, 2);
  assert.equal(lexical.map_sha256, digest(mapRaw));
  const { payload_sha256: lexicalDigest, ...lexicalPayload } = lexical;
  assert.equal(lexicalDigest, digest(canonical(lexicalPayload)));
  const runtime = structuredClone(materials.configuration.runtime);
  delete runtime.revision;
  delete runtime.applied_revision;
  assert.deepEqual(materials.source_components, {
    runtime: digest(canonical(runtime)),
    handoff: digest(canonical(materials.configuration.handoff)),
    keyword: digest(canonical(materials.configuration.keyword)),
    menu: digest(canonical(materials.configuration.menu)),
    tags: digest(canonical(materials.configuration.tags)),
    feedback: digest(canonical(materials.configuration.feedback)),
    prompt: materials.prompt.sha256,
    knowledge: digest(canonical(materials.knowledge)),
  });
  assert.equal(materials.source_sha256, digest(canonical(materials.source_components)));
  assert.equal(fs.existsSync(path.join(root, 'data/runtime/knowledge-migration.json')), false);
};
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
const executePool = (root, action = 'migrate', environment = {}) => new Promise((resolve) => {
  const actions = Array.isArray(action) ? action : [action];
  const child = spawn('python3', [path.join(project, 'scripts/provider-pool.py'), '--deploy-dir', root, ...actions], {
    env: { ...process.env, ...environment },
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
const assertSingleBusinessReply = (fixture, expected = '受控正常答案。') => {
  assert.equal(fixture.sent.length, 1, '同一问题必须只有一条访客出站');
  const message = fixture.sent[0];
  assert.equal(message.content, expected);
  assert.equal(mechanicalFailureAnswer(message.content), false);
  assert.equal(message.user?.nickname, '在线客服');
  assert.doesNotMatch(message.content, /暂时无法|稍后|稍候|稍等|重试|最希望先解决哪一处|机器人|人工智能|AI(?:客服|助手|系统|模型)/iu);
  assert.doesNotMatch(message.user?.nickname || '', /机器人|人工智能|AI/iu);
};

async function fixture(label, behavior) {
  const root = path.join(base, label);
  const calls = [], sent = [], histories = new Map(), adapterResponses = [], signedProviderPayloads = [];
  let dropNextAdapterResponse = false;
  let armSettlementWritebackFailure = false;
  let failNextSessionCommit = false;
  let settlementWritebackFailures = 0;
  let settlementTransportFailures = 0;
  let upstreamPhase = 'runtime';
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
  const mapPath = path.join(root, 'data/runtime/knowledge-map.json');
  writeJson(mapPath, { schema_version: 2, revision: 1, documents: [{
    library_id: 'kb_1111111111111111', library_name: '受控资料', document_id: 'doc_2222222222222222', projection,
    location: `custom-documents/${projection}-33333333-3333-4333-8333-333333333333.json`,
  }] });
  const settingsPath = path.join(root, 'data/runtime/knowledge-settings.json');
  writeJson(settingsPath, { schema_version: 1, workspace_slug: 'synthetic', temperature: 0.25, observed_at: now });
  const profileValue = { engine: 'native', model: 'synthetic-provider-failure-embedding', chunk_size: 1000,
    chunk_overlap: 20, passage_prefix: '', query_prefix: '', component_version: 'synthetic' };
  const profilePath = path.join(root, 'data/runtime/knowledge-profile.json');
  writeJson(profilePath, { schema_version: 1, state: 'applied', profile: profileValue,
    fingerprint: digest(canonical(profileValue)), applied_at: now });
  const mapRaw = fs.readFileSync(mapPath);
  const lexicalPayload = { schema_version: 2, algorithm: 'crispai-lexical-v2', map_sha256: digest(mapRaw),
    complete: false, coverage: { source_documents: 1, indexed_documents: 0, omitted_documents: 1,
      source_bytes: 1, indexed_bytes: 0, omitted_bytes: 1, reasons: ['index_capacity'] }, passages: [] };
  const lexicalPath = path.join(root, 'data/runtime/knowledge-lexical.json');
  writeJson(lexicalPath, { ...lexicalPayload, payload_sha256: digest(canonical(lexicalPayload)) });
  const configuration = Object.fromEntries(['runtime', 'handoff', 'keyword', 'menu', 'tags', 'feedback']
    .map((name) => [name, readJson(path.join(root, `config/${name}.yaml`))]));
  const materials = sealMaterials({ schema_version: 2, state: 'applied', revision: 1, applied_at: now,
    source_sha256: '', source_components: {}, configuration,
    prompt: { text: prompt, bytes: Buffer.byteLength(prompt), sha256: digest(prompt) },
    knowledge: {
      catalog_revision: 1, catalog_sha256: digest(canonical({ fixture: 'catalog', documents: 1 })),
      manifest_sha256: digest(canonical({ fixture: 'manifest', projection })), map_sha256: digest(mapRaw),
      settings_sha256: digest(fs.readFileSync(settingsPath)), profile_sha256: digest(fs.readFileSync(profilePath)),
      lexical_sha256: digest(fs.readFileSync(lexicalPath)), enabled_library_ids: ['kb_1111111111111111'],
      library_count: 1, document_count: 1, enabled_document_count: 1,
    } });
  writeJson(path.join(root, 'config/materials-applied.json'), materials);
  assertReplyReadyMaterials(root, materials);

  let upstreamBehavior = behavior;
  const upstream = http.createServer(async (request, response) => {
    let raw = '';
    for await (const chunk of request) raw += chunk;
    const index = Number(/^\/p(\d+)\//.exec(request.url)?.[1]);
    const body = JSON.parse(raw || '{}');
    calls.push({ index, at: Date.now(), path: request.url,
      authorization: request.headers.authorization, phase: upstreamPhase, body });
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
    const transaction = /^synthetic-transaction-([abc])$/.exec(String(body.model || ''))?.[1];
    const content = transaction ? `受控配置 ${transaction.toUpperCase()} 的有效答案。` : '受控正常答案。';
    response.end(JSON.stringify({ choices: [{ message: { role: 'assistant', content } }] }));
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
  const verifiedPool = await executePool(root, 'verify-applied', {
    PROVIDER_ADAPTER_MANAGEMENT_URL: adapterBase,
  });
  assert.equal(verifiedPool.code, 0, verifiedPool.stderr + verifiedPool.stdout);
  const currentProviderConfiguration = () => {
    const currentPool = readJson(poolPath);
    const value = {
      runtime_revision: materials.revision,
      pool_revision: currentPool.revision,
      secrets_generation: currentPool.secrets_generation,
      pool_sha256: digest(fs.readFileSync(poolPath)),
      materials_source_sha256: materials.source_sha256,
    };
    value.configuration_binding = digest(JSON.stringify([
      value.runtime_revision, value.pool_revision, value.secrets_generation,
      value.pool_sha256, value.materials_source_sha256,
    ]));
    return value;
  };
  const providerConfiguration = currentProviderConfiguration();

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
    PROVIDER_ADAPTER_KEY: internal, PROVIDER_POOL_REQUIRED: 'true',
    PROVIDER_POOL_READBACK_REQUIRED: 'true', PROVIDER_ADAPTER_URL: `${adapterBase}/v1`,
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
    if (parsed.port === String(adapterPort)
      && ['/v1/chat/completions', '/internal/provider/replay', '/internal/provider/settle'].includes(parsed.pathname)) {
      const token = options.headers?.['x-crispai-question'];
      if (token) {
        const encoded = String(token).split('.')[0];
        signedProviderPayloads.push({
          path: parsed.pathname,
          token: String(token),
          token_length: String(token).length,
          payload: JSON.parse(Buffer.from(encoded, 'base64url').toString('utf8')),
        });
      }
    }
    if (parsed.port === String(adapterPort) && parsed.pathname === '/internal/provider/settle'
      && settlementTransportFailures > 0) {
      settlementTransportFailures -= 1;
      const error = new Error('受控夹具暂时中断 Provider 结算回程');
      error.code = 'ECONNREFUSED';
      throw error;
    }
    const response = await fetchJson(url, options);
    if (parsed.port === String(adapterPort)
      && ['/v1/chat/completions', '/internal/provider/replay', '/internal/provider/settle'].includes(parsed.pathname)) {
      adapterResponses.push(structuredClone(response));
      if (armSettlementWritebackFailure && parsed.pathname === '/internal/provider/settle'
        && response.status >= 200 && response.status < 300) {
        armSettlementWritebackFailure = false;
        failNextSessionCommit = true;
      }
      if (dropNextAdapterResponse && parsed.pathname === '/v1/chat/completions') {
        dropNextAdapterResponse = false;
        const error = new Error('受控夹具在 adapter 完整响应后丢弃回程');
        error.code = 'ECONNRESET';
        throw error;
      }
    }
    return response;
  };
  // 只在 router 已确认 settle 之后，让紧接着的一次会话原子替换失败。
  // 外层恢复事务可以正常写回，精确覆盖“答案已结算、局部状态回写失败”的崩溃点。
  const originalRenameSync = fs.renameSync;
  fs.renameSync = function(source, destination) {
    if (failNextSessionCommit
      && String(destination).startsWith(path.join(root, 'data/runtime/session-'))
      && String(source).startsWith(String(destination) + '.tmp-')) {
      failNextSessionCommit = false;
      settlementWritebackFailures += 1;
      const error = new Error('受控会话结算写回失败');
      error.code = 'EIO';
      throw error;
    }
    return originalRenameSync.call(fs, source, destination);
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
    assert.equal(accepted.route, 'process', 'reply-ready fixture 必须直接进入 Provider 处理链');
    return runtime.process(accepted.key, accepted.jobId);
  };
  const state = (session) => runtime.readState(runtime.stateKey(env.CRISP_WEBSITE_ID, session));
  const applyPrimary = async (label, index) => {
    const candidate = path.join(root, 'tmp', `provider-transaction-${label}.json`);
    writeJson(candidate, { provider: {
      name: `受控配置 ${label.toUpperCase()}`,
      base_url: `${upstreamBase}/p${index}/v1`,
      model: `synthetic-transaction-${label}`,
      api_mode: 'chat_completions',
      capabilities: { chat_completions: true, responses: false, vision: false },
    }, api_key: `synthetic-transaction-key-${label}` });
    upstreamPhase = `apply-${label}`;
    let result;
    try {
      result = await executePool(root, ['apply', candidate], {
        PROVIDER_ADAPTER_MANAGEMENT_URL: adapterBase,
      });
    } finally { upstreamPhase = 'runtime'; }
    assert.equal(result.code, 0, result.stderr + result.stdout);
    const current = readJson(poolPath);
    const primary = current.entries.find((entry) => entry.id === current.primary_id);
    const currentSecrets = readJson(path.join(root, 'secrets/provider/generations',
      `${current.secrets_generation}.json`));
    assert.equal(primary.base_url, `${upstreamBase}/p${index}/v1`);
    assert.equal(primary.model, `synthetic-transaction-${label}`);
    assert.equal(currentSecrets.entries[current.primary_id].api_key,
      `synthetic-transaction-key-${label}`);
    assert.equal(fs.existsSync(path.join(root, 'config/provider-pool-transaction.json')), false,
      '受管配置事务成功后不得遗留 applying 标记');
    const readback = readJson(path.join(root, 'config/provider-pool-readback.json'));
    assert.deepEqual([readback.revision, readback.secrets_generation, readback.pool_sha256],
      [current.revision, current.secrets_generation, digest(fs.readFileSync(poolPath))],
      '配置事务必须回读完全相同的 revision、秘密代次和公开池字节');
    return { pool: current, configuration: currentProviderConfiguration() };
  };
  const postAdapter = (route, token, body = {}) => fetchJson(`${adapterBase}${route}`, {
    method: 'POST', timeout: 5000,
    headers: { authorization: `Bearer ${internal}`, 'x-crispai-question': token }, body,
  });
  const close = async () => {
    fs.renameSync = originalRenameSync;
    await stopAdapter();
    for (const server of [rag, upstream]) server.closeAllConnections();
    await Promise.all([rag, upstream].map((server) => new Promise((resolve) => server.close(resolve))));
  };
  return {
    root, prompt, pool, providerConfiguration, internal, calls, sent, adapterResponses, signedProviderPayloads,
    event, receive, deliver, state,
    get adapterBase() { return adapterBase; },
    setBehavior(value) { upstreamBehavior = value; },
    dropNextAdapterResponse() { dropNextAdapterResponse = true; },
    failNextSettlementWriteback() { armSettlementWritebackFailure = true; },
    failNextSettlementRequest() { settlementTransportFailures += 1; },
    settlementWritebackFailures: () => settlementWritebackFailures,
    advance(milliseconds) { now += milliseconds; },
    now: () => now,
    async killAdapter() { await stopAdapter('SIGKILL'); },
    async restartAdapter() { await startAdapter(); restartRuntime(); },
    async verifyPool() {
      const result = await executePool(root, 'verify-applied', {
        PROVIDER_ADAPTER_MANAGEMENT_URL: adapterBase,
      });
      assert.equal(result.code, 0, result.stderr + result.stdout);
      return JSON.parse(result.stdout);
    },
    applyPrimary,
    postAdapter,
    scan: () => runtime.scan(),
    async enterHumanMode(session) {
      const key = runtime.stateKey(env.CRISP_WEBSITE_ID, session);
      await runtime.transaction(key, (current) => {
        current.mode = 'human';
        current.generation += 1;
        current.resume_at = now + 3600000;
        current.pause_reason = 'operator_reply';
        current.last_human_at = now;
        current.control_watermark = Math.max(current.control_watermark || 0, now);
      }, env.CRISP_WEBSITE_ID, session);
    },
    readbackPath: path.join(root, 'config/provider-pool-readback.json'),
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
  await test('未取得adapter完整回读时保留新问题且零推理，回读同一池后原责任恢复', async (f) => {
    fs.unlinkSync(f.readbackPath);
    const event = f.event('readback-gate');
    const accepted = await f.receive(event);
    assert.equal(accepted.accepted, true);
    const before = f.calls.length;
    const deferred = await f.process(accepted.key, accepted.jobId);
    assert.ok(['deferred', 'idle'].includes(deferred.status));
    let stored = pendingJob(f, event, accepted.jobId);
    assert.equal(stored.status, 'received');
    assert.equal(stored.deferred_configuration, true);
    assert.equal(f.calls.length, before);
    assert.equal(f.sent.length, 0);
    const verified = await f.verifyPool();
    assert.equal(verified.state, 'verified');
    advancePastRetry(f, event, accepted.jobId);
    const completed = await f.process(accepted.key, accepted.jobId);
    assert.equal(completed.status, 'sent');
    stored = pendingJob(f, event, accepted.jobId);
    assert.equal(stored.responsibility_status, 'answered_confirmed');
    assert.equal(f.calls.length, before + 1);
    assertSingleBusinessReply(f);
  });

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
      assert.equal(stored.id, result.jobId);
      assert.equal(stored.inference_generation, 1);
      assert.equal(stored.inference, undefined, '技术失败后应释放本轮推理信封，保留原任务等待新轮');
      assert.equal(Number(stored.response_generation || 0), 0);
      const firstQuestion = f.question(result.jobId);
      assert.equal(firstQuestion.attempt_generation, 1);
      assert.equal(firstQuestion.attempts, 2, '累计审计必须记录本轮两个真实上游调用');
      assert.equal(firstQuestion.round_attempts, 2, '本轮调用数必须受 max_attempts=2 约束');
      assert.equal(Number.isFinite(firstQuestion.deadline), true);
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
      assert.equal(stored.id, result.jobId, '恢复轮不得新建另一问题责任');
      assert.equal(stored.inference_generation, 2);
      assert.equal(stored.inference?.attempt_generation, 2);
      assert.equal(Number(stored.response_generation || 0), 0,
        '未向 Crisp 发出旧答案时，Provider 恢复不得擅自换可见回复代次');
      assert.equal(stored.data, undefined);
      const recoveredQuestion = f.question(result.jobId);
      assert.equal(recoveredQuestion.attempt_generation, 2);
      assert.equal(recoveredQuestion.attempts, 3, '累计审计不得因新恢复轮清零');
      assert.equal(recoveredQuestion.round_attempts, 1, '新恢复轮只消费一次有效调用');
      assert.equal(recoveredQuestion.deadline > firstQuestion.deadline, true,
        '新恢复轮必须取得独立且有限的新期限');
      assert.equal(f.state(event.data.session_id).jobs.filter((entry) => entry.id === result.jobId).length, 1);
      assert.equal((await f.process(result.key, result.jobId)).status, 'idle');
      assert.equal(f.calls.length, 3);
      assert.equal(f.sent.length, 1);
    });
  }

  await test('adapter已缓存成功但runtime回程丢失时同代重放，最终只推理和出站一次', async (f) => {
    f.dropNextAdapterResponse();
    const event = f.event('response-lost-after-cache');
    const first = await f.deliver(event);
    assert.equal(first.status, 'unresolved');
    assertNoVisibleFailureReply(f);
    assert.equal(f.calls.length, 1, '首轮只能调用一次已成功的真实路由候选');
    let stored = pendingJob(f, event, first.jobId);
    assert.equal(stored.status, 'received');
    assert.equal(stored.responsibility_status, 'unresolved_failure');
    assert.equal(stored.failure_code, 'provider_response_unknown');
    assert.equal(stored.provider_result_receipt?.state, 'unknown');
    assert.equal(stored.inference?.attempt_generation, 1,
      '回程未知必须保留同代信封，不得直接新建一次推理');
    let question = f.question(first.jobId);
    assert.equal(question.stages.answer.result.choices[0].message.content, '受控正常答案。');
    assert.deepEqual([question.attempt_generation, question.round_attempts, question.attempts], [1, 1, 1]);

    advancePastRetry(f, event, first.jobId);
    const recovered = await f.process(first.key, first.jobId);
    assert.equal(recovered.status, 'sent', f.adapterErrors());
    assert.equal(f.calls.length, 1, '只读 replay 不得再次调用第三方接口');
    assertSingleBusinessReply(f);
    stored = pendingJob(f, event, first.jobId);
    assert.equal(stored.status, 'done');
    assert.equal(stored.responsibility_status, 'answered_confirmed');
    assert.equal(stored.provider_result_receipt, undefined);
    assert.equal(stored.provider_settlement?.state, 'settled');
    question = f.question(first.jobId);
    assert.equal(question.stages.answer.result, undefined,
      'runtime 持久化计划后 adapter 不得继续保留可重放正文');
    assert.equal(question.stages.answer.result_receipt?.disposition, 'answer');
    assert.equal(question.settlement?.outcome, 'plan_persisted');
    for (const route of ['/internal/provider/replay', '/internal/provider/settle']) {
      const signed = f.signedProviderPayloads.find((entry) => entry.path === route);
      assert(signed, `${route} 必须携带受控签名信封`);
      assert.ok(signed.token_length < 8192, `${route} 的签名头必须保持有界`);
      assert.deepEqual(Object.keys(signed.payload).sort(), [
        'attempt_generation', 'configuration_binding', 'deadline_at', 'generation',
        'materials_source_sha256', 'plan_context_sha256', 'pool_revision', 'pool_sha256',
        'question_id', 'request_contract_version', 'request_sha256', 'runtime_revision',
        'scope', 'secrets_generation', 'session_key', 'stage', 'version',
      ].sort());
      assert.equal(signed.payload.stage, 'answer');
      for (const forbidden of ['plan_context', 'state', 'first_unknown_at', 'checks', 'reason']) {
        assert.equal(Object.hasOwn(signed.payload, forbidden), false,
          `${route} 不得把本地回执或知识上下文放入 HTTP Header`);
      }
    }
    assert.equal((await f.process(first.key, first.jobId)).status, 'idle');
    assert.equal(f.calls.length, 1);
    assert.equal(f.sent.length, 1);
  });

  await test('真实配置事务A→B→C迁移同一未答责任，旧代失效且最终只出站C答案', async (f) => {
    const appliedA = await f.applyPrimary('a', 2);
    const event = f.event('managed-configuration-a-b-c');
    f.dropNextAdapterResponse();
    const first = await f.deliver(event);
    assert.equal(first.status, 'unresolved');
    assertNoVisibleFailureReply(f);
    let stored = pendingJob(f, event, first.jobId);
    assert.equal(stored.id, first.jobId);
    assert.equal(stored.inference_generation, 1);
    assert.equal(stored.inference?.configuration_binding,
      appliedA.configuration.configuration_binding);
    const aToken = f.signedProviderPayloads.filter((entry) => entry.path === '/v1/chat/completions').at(-1)?.token;
    assert(aToken, 'A代业务请求必须携带冻结信封');
    let question = f.question(first.jobId);
    assert.deepEqual([question.attempt_generation, question.round_attempts, question.attempts], [1, 1, 1]);
    assert.equal(question.stages.answer.result.choices[0].message.content,
      '受控配置 A 的有效答案。');

    const appliedB = await f.applyPrimary('b', 3);
    assert.equal(appliedB.pool.revision, appliedA.pool.revision + 1);
    advancePastRetry(f, event, first.jobId);
    const deferredB = await f.process(first.key, first.jobId);
    assert.equal(deferredB.status, 'deferred', 'runtime 必须先把旧A责任迁移到已回读B代');
    stored = pendingJob(f, event, first.jobId);
    assert.equal(stored.deferred_configuration, true);
    assert.deepEqual(stored.provider_migration_from, {
      runtime_revision: appliedA.configuration.runtime_revision,
      pool_revision: appliedA.configuration.pool_revision,
      secrets_generation: appliedA.configuration.secrets_generation,
      pool_sha256: appliedA.configuration.pool_sha256,
      materials_source_sha256: appliedA.configuration.materials_source_sha256,
      attempt_generation: 1,
    });
    assert.equal(f.calls.filter((call) => call.phase === 'runtime').length, 1,
      '配置发布窗口不得额外调用旧A或尚未绑定的B');

    advancePastRetry(f, event, first.jobId);
    f.dropNextAdapterResponse();
    const second = await f.process(first.key, first.jobId);
    assert.equal(second.status, 'unresolved');
    assertNoVisibleFailureReply(f);
    stored = pendingJob(f, event, first.jobId);
    assert.equal(stored.id, first.jobId);
    assert.equal(stored.inference_generation, 2);
    assert.equal(stored.inference?.configuration_binding,
      appliedB.configuration.configuration_binding);
    const bToken = f.signedProviderPayloads.filter((entry) => entry.path === '/v1/chat/completions').at(-1)?.token;
    assert(bToken && bToken !== aToken, 'B代必须使用新的完整配置信封');
    question = f.question(first.jobId);
    assert.deepEqual([question.attempt_generation, question.round_attempts, question.attempts], [2, 1, 2]);
    assert.equal(question.stages.answer.result.choices[0].message.content,
      '受控配置 B 的有效答案。');

    const appliedC = await f.applyPrimary('c', 4);
    assert.equal(appliedC.pool.revision, appliedB.pool.revision + 1);
    advancePastRetry(f, event, first.jobId);
    const deferredC = await f.process(first.key, first.jobId);
    assert.equal(deferredC.status, 'deferred', 'B回程未收敛时再次换代必须保留最早迁移根');
    stored = pendingJob(f, event, first.jobId);
    assert.deepEqual(stored.provider_migration_from, {
      runtime_revision: appliedA.configuration.runtime_revision,
      pool_revision: appliedA.configuration.pool_revision,
      secrets_generation: appliedA.configuration.secrets_generation,
      pool_sha256: appliedA.configuration.pool_sha256,
      materials_source_sha256: appliedA.configuration.materials_source_sha256,
      attempt_generation: 1,
    });
    assert.equal(stored.inference_generation, 2,
      '仅登记配置迁移不得凭空消费下一推理代');

    advancePastRetry(f, event, first.jobId);
    const completed = await f.process(first.key, first.jobId);
    assert.equal(completed.status, 'sent', f.adapterErrors());
    assertSingleBusinessReply(f, '受控配置 C 的有效答案。');
    stored = pendingJob(f, event, first.jobId);
    assert.equal(stored.id, first.jobId);
    assert.equal(stored.status, 'done');
    assert.equal(stored.responsibility_status, 'answered_confirmed');
    assert.equal(stored.inference_generation, 3);
    assert.equal(stored.inference?.attempt_generation, 3);
    assert.equal(stored.inference?.configuration_binding,
      appliedC.configuration.configuration_binding);
    assert.equal(Number(stored.response_generation || 0), 0);
    assert.equal(f.state(event.data.session_id).jobs.filter((entry) => entry.id === first.jobId).length, 1,
      '配置换代不得复制原问题责任');

    const business = f.calls.filter((call) => call.phase === 'runtime');
    assert.deepEqual(business.map((call) => [call.index, call.authorization, call.body.model]), [
      [2, 'Bearer synthetic-transaction-key-a', 'synthetic-transaction-a'],
      [3, 'Bearer synthetic-transaction-key-b', 'synthetic-transaction-b'],
      [4, 'Bearer synthetic-transaction-key-c', 'synthetic-transaction-c'],
    ], '每代实际请求必须使用同一配置事务发布的地址、Key和模型');
    for (const [label, index] of [['a', 2], ['b', 3], ['c', 4]]) {
      const probes = f.calls.filter((call) => call.phase === `apply-${label}`);
      assert.equal(probes.length, 1, `配置${label.toUpperCase()}必须先完成一次受管小样本验证`);
      assert.deepEqual([probes[0].index, probes[0].authorization, probes[0].body.model],
        [index, `Bearer synthetic-transaction-key-${label}`, `synthetic-transaction-${label}`]);
    }
    question = f.question(first.jobId);
    assert.deepEqual([question.attempt_generation, question.round_attempts, question.attempts], [3, 1, 3]);
    assert.equal(question.settlement?.outcome, 'plan_persisted');
    assert.equal(JSON.stringify(question).includes('受控配置 A 的有效答案。'), false,
      'A代缓存只能留下失效摘要，不得成为C代答案');
    assert.equal(JSON.stringify(question).includes('受控配置 B 的有效答案。'), false,
      'B代缓存只能留下失效摘要，不得成为C代答案');

    const callsBeforeFencedReplay = f.calls.length;
    assert.notEqual((await f.postAdapter('/internal/provider/replay', aToken)).status, 200,
      'A代token必须在最终C代读取前失效');
    assert.notEqual((await f.postAdapter('/internal/provider/replay', bToken)).status, 200,
      'B代token必须在最终C代读取前失效');
    assert.equal(f.calls.length, callsBeforeFencedReplay,
      '旧代缓存读取不得产生新的第三方调用');
    assert.equal((await f.process(first.key, first.jobId)).status, 'idle');
    assert.equal(f.sent.length, 1);
  });

  await test('Provider结算暂不可用时终态答案只重试结算，配置换代和人工接管后不再推理或出站', async (f) => {
    const appliedA = await f.applyPrimary('a', 2);
    f.failNextSettlementRequest();
    const event = f.event('settlement-only-recovery');
    const first = await f.deliver(event);
    assert.equal(first.status, 'sent');
    assertSingleBusinessReply(f, '受控配置 A 的有效答案。');

    let stored = pendingJob(f, event, first.jobId);
    assert.equal(stored.status, 'done');
    assert.equal(stored.responsibility_status, 'answered_confirmed');
    assert.equal(stored.provider_settlement?.state, 'deferred');
    assert.equal(stored.provider_settlement?.attempts, 1);
    assert.equal(stored.provider_result_receipt?.state, 'available');
    assert.equal(Number.isFinite(stored.provider_settlement?.next_action_at), true);
    const firstSettlement = structuredClone(stored.provider_settlement);
    const routerBefore = f.question(first.jobId);
    assert.equal(routerBefore.settlement, undefined,
      '首次结算传输中断后 router 必须继续保留未结算结果');
    assert.equal(routerBefore.stages.answer.result.choices[0].message.content,
      '受控配置 A 的有效答案。');
    assert.equal(f.calls.filter((call) => call.phase === 'runtime').length, 1);
    assert.equal(f.signedProviderPayloads.filter((entry) => entry.path === '/internal/provider/settle').length, 1);

    const callsBeforeBackoff = f.calls.length;
    const sentBeforeBackoff = f.sent.length;
    assert.equal((await f.process(first.key, first.jobId)).status, 'idle',
      '结算退避期内显式 process 不得绕过 next_action_at');
    assert.equal(f.calls.length, callsBeforeBackoff);
    assert.equal(f.sent.length, sentBeforeBackoff);

    const appliedB = await f.applyPrimary('b', 3);
    assert.equal(appliedB.pool.revision, appliedA.pool.revision + 1);
    await f.enterHumanMode(event.data.session_id);
    stored = pendingJob(f, event, first.jobId);
    assert.equal(f.state(event.data.session_id).mode, 'human');
    assert.equal(stored.status, 'done', '已确认答案进入人工模式后不得倒退或重新生成');
    assert.equal(stored.provider_settlement?.state, 'deferred');
    assert.equal(stored.provider_settlement?.envelope.configuration_binding,
      appliedA.configuration.configuration_binding,
      '待结算记录必须冻结原A代完整非秘密身份');

    f.advance(Math.max(1, firstSettlement.next_action_at - f.now() + 1));
    const selected = await f.scan();
    assert.equal(selected.some((entry) => entry.key === first.key && entry.jobId === first.jobId), true,
      'scanner 必须继续选择终态 job 的独立结算责任');
    const settlement = await f.process(first.key, first.jobId);
    assert.equal(settlement.status, 'provider_settlement_settled');
    stored = pendingJob(f, event, first.jobId);
    assert.equal(stored.status, 'done');
    assert.equal(stored.responsibility_status, 'answered_confirmed');
    assert.equal(stored.provider_settlement?.state, 'settled');
    assert.equal(stored.provider_settlement?.attempts, 2);
    assert.equal(stored.provider_result_receipt, undefined);
    assert.equal(stored.plan, undefined);
    assert.equal(f.state(event.data.session_id).mode, 'human');

    const routerAfter = f.question(first.jobId);
    assert.equal(routerAfter.settlement?.outcome, 'plan_persisted');
    assert.equal(routerAfter.stages.answer.result, undefined,
      '结算恢复后 router 必须释放可重放的完整结果正文');
    assert.equal(routerAfter.stages.answer.result_receipt?.disposition, 'answer');
    assert.equal(f.signedProviderPayloads.filter((entry) => entry.path === '/internal/provider/settle').length, 2,
      '首次失败和恢复轮各允许一次 exact settle');
    assert.equal(f.signedProviderPayloads.filter((entry) => entry.path === '/v1/chat/completions').length, 1,
      'settlement-only 不得取得第二份 Provider route 权限');
    assert.equal(f.signedProviderPayloads.filter((entry) => entry.path === '/internal/provider/replay').length, 0,
      '答案已持久后结算恢复不得退回结果重放路径');
    assert.equal(f.calls.filter((call) => call.phase === 'runtime').length, 1,
      'settlement-only 不得调用当前B配置或重新执行原A推理');
    assert.equal(f.sent.length, 1, 'settlement-only 不得再次 POST Crisp 正文');
    assert.equal((await f.process(first.key, first.jobId)).status, 'idle');
    assert.equal(f.calls.filter((call) => call.phase === 'runtime').length, 1);
    assert.equal(f.sent.length, 1);
  });

  await test('router结算后本地写回失败仍保留已生成计划，恢复时不再推理', async (f) => {
    f.failNextSettlementWriteback();
    const event = f.event('settled-local-writeback-failure');
    const first = await f.deliver(event);
    assert.equal(first.status, 'deferred');
    assert.equal(first.reason, 'answer_responsibility_unresolved');
    assert.equal(f.settlementWritebackFailures(), 1, '夹具必须精确命中结算后的本地写回');
    assert.equal(f.calls.length, 1);
    assertNoVisibleFailureReply(f);
    let stored = pendingJob(f, event, first.jobId);
    assert.equal(stored.status, 'received');
    assert.equal(stored.responsibility_status, 'unresolved_failure');
    assert.equal(stored.failure_code, 'persisted_plan_delivery_pending');
    assert.equal(stored.plan?.content, '受控正常答案。');
    assert.equal(stored.data?.content, event.data.content);
    const settled = f.question(first.jobId);
    assert.equal(settled.settlement?.outcome, 'plan_persisted');
    assert.equal(settled.stages.answer.result, undefined,
      'router 已结算后不得继续保留可重放正文');

    advancePastRetry(f, event, first.jobId);
    const recovered = await f.process(first.key, first.jobId);
    assert.equal(recovered.status, 'sent');
    assert.equal(f.calls.length, 1, '已持久计划恢复不得重新调用 Provider');
    assertSingleBusinessReply(f);
    stored = pendingJob(f, event, first.jobId);
    assert.equal(stored.status, 'done');
    assert.equal(stored.responsibility_status, 'answered_confirmed');
    assert.equal(stored.provider_result_receipt, undefined);
    assert.equal(stored.plan, undefined);
    assert.equal((await f.process(first.key, first.jobId)).status, 'idle');
    assert.equal(f.calls.length, 1);
    assert.equal(f.sent.length, 1);
  });

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
    job.inference_generation = 1;
    job.inference = { ...f.providerConfiguration, deadline_at: deadlineAt,
      attempt_generation: 1 };
    writeJson(stateFile, state);
    const envelope = {
      version: 1, scope: 'conversation', question_id: accepted.jobId, session_key: accepted.key,
      generation: state.generation, runtime_revision: job.revision, pool_revision: f.pool.revision,
      secrets_generation: f.providerConfiguration.secrets_generation,
      pool_sha256: f.providerConfiguration.pool_sha256,
      materials_source_sha256: f.providerConfiguration.materials_source_sha256,
      configuration_binding: f.providerConfiguration.configuration_binding,
      deadline_at: deadlineAt, attempt_generation: 1, stage: 'answer',
    };
    const directBody = { model: 'ignored-by-pool', messages: [
      { role: 'system', content: f.prompt }, { role: 'user', content: '请说明当前处理方式。' },
    ], stream: false };
    const direct = fetchJson(`${f.adapterBase}/v1/chat/completions`, {
      method: 'POST', timeout: 10000,
      headers: { authorization: `Bearer ${f.internal}`,
        'x-crispai-question': signEnvelope({ ...envelope, ...requestContract(directBody) }, f.internal) },
      body: directBody,
    }).then((value) => ({ resolved: true, value }), (error) => ({ resolved: false, error }));
    const questionFile = path.join(f.root, 'data/provider-router/questions', `${accepted.jobId}.json`);
    await until(() => f.calls.length === 1 && fs.existsSync(questionFile)
      && readJson(questionFile).stages?.answer?.owner, 3000);
    const interruptedQuestion = readJson(questionFile);
    assert.equal(interruptedQuestion.attempt_generation, 1);
    assert.equal(interruptedQuestion.attempts, 1);
    assert.equal(interruptedQuestion.round_attempts, 1);
    assert.equal(Number.isFinite(interruptedQuestion.deadline), true);
    await f.killAdapter();
    const interrupted = await direct;
    assert.equal(interrupted.resolved, false, '强制终止适配器必须中断原上游请求');
    f.setBehavior('normal');
    await f.restartAdapter();
    let result = await f.process(accepted.key, accepted.jobId);
    assert.equal(result.status, 'unresolved');
    assertNoVisibleFailureReply(f);
    let stored = pendingJob(f, event, accepted.jobId);
    assert.equal(stored.status, 'received');
    assert.equal(stored.responsibility_status, 'unresolved_failure');
    assert.equal(stored.data?.content, event.data.content);
    assert.equal(stored.inference_generation, 1);
    assert.equal(stored.inference, undefined);
    assert.equal(Number(stored.response_generation || 0), 0);
    assert.equal(f.adapterResponses.at(-1).body?.error?.code, 'question_interrupted');
    advancePastRetry(f, event, accepted.jobId);
    await wait(1100);
    result = await f.process(accepted.key, accepted.jobId);
    assert.equal(result.status, 'sent', f.adapterErrors());
    assert.equal(f.calls.length, 2, '恢复轮只允许一次新的有效上游调用');
    assertSingleBusinessReply(f);
    assert.equal(f.state(event.data.session_id).mode, 'ai');
    stored = pendingJob(f, event, accepted.jobId);
    assert.equal(stored.responsibility_status, 'answered_confirmed');
    assert.equal(stored.id, accepted.jobId);
    assert.equal(stored.inference_generation, 2);
    assert.equal(stored.inference?.attempt_generation, 2);
    assert.equal(Number(stored.response_generation || 0), 0);
    const recoveredQuestion = f.question(accepted.jobId);
    assert.equal(recoveredQuestion.attempt_generation, 2);
    assert.equal(recoveredQuestion.attempts, 2);
    assert.equal(recoveredQuestion.round_attempts, 1);
    assert.equal(recoveredQuestion.deadline > interruptedQuestion.deadline, true);
    const duplicate = await f.receive(event);
    assert.equal(duplicate.reason, '重复事件已忽略');
    await f.process(accepted.key, accepted.jobId);
    assert.equal(f.calls.length, 2);
    assert.equal(f.sent.length, 1);
  });

  await test('连续技术失败每个恢复轮仍有界，累计审计不清零且外部恢复后原任务仅答一次', async (f) => {
    f.setBehavior('401');
    const event = f.event('repeated-rounds');
    const first = await f.deliver(event);
    assert.equal(first.status, 'unresolved');
    assert.deepEqual(f.calls.map((call) => call.index), [0, 1]);
    let stored = pendingJob(f, event, first.jobId);
    let question = f.question(first.jobId);
    assert.equal(stored.inference_generation, 1);
    assert.equal(Number(stored.response_generation || 0), 0);
    assert.deepEqual([question.attempt_generation, question.round_attempts, question.attempts], [1, 2, 2]);
    const firstDeadline = question.deadline;
    assertNoVisibleFailureReply(f);

    advancePastRetry(f, event, first.jobId);
    await wait(1100);
    const second = await f.process(first.key, first.jobId);
    assert.equal(second.status, 'unresolved');
    assert.deepEqual(f.calls.map((call) => call.index), [0, 1, 0, 1],
      '第二恢复轮仍只能按 max_attempts=2 调用两个候选');
    stored = pendingJob(f, event, first.jobId);
    question = f.question(first.jobId);
    assert.equal(stored.inference_generation, 2);
    assert.equal(stored.inference, undefined);
    assert.equal(Number(stored.response_generation || 0), 0);
    assert.deepEqual([question.attempt_generation, question.round_attempts, question.attempts], [2, 2, 4]);
    assert.equal(question.deadline > firstDeadline, true);
    assertNoVisibleFailureReply(f);

    f.setBehavior('normal');
    advancePastRetry(f, event, first.jobId);
    // 第二轮失败把接口冷却提升到两秒；等真实冷却到期，不改持久业务时钟语义。
    await wait(2200);
    const recovered = await f.process(first.key, first.jobId);
    assert.equal(recovered.status, 'sent');
    stored = pendingJob(f, event, first.jobId);
    question = f.question(first.jobId);
    assert.equal(stored.id, first.jobId);
    assert.equal(stored.inference_generation, 3);
    assert.equal(stored.inference?.attempt_generation, 3);
    assert.equal(Number(stored.response_generation || 0), 0);
    assert.deepEqual([question.attempt_generation, question.round_attempts, question.attempts], [3, 1, 5]);
    assert.equal(f.state(event.data.session_id).jobs.filter((entry) => entry.id === first.jobId).length, 1);
    assertSingleBusinessReply(f);
    assert.equal((await f.process(first.key, first.jobId)).status, 'idle');
    assert.equal(f.calls.length, 5);
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
