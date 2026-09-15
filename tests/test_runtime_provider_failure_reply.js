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
  let finished = false;
  let timedOut = false;
  let forced = null;
  let deadline = null;
  const finish = (code) => {
    if (finished) return;
    finished = true;
    if (deadline) clearTimeout(deadline);
    if (forced) clearTimeout(forced);
    resolve({ code: timedOut ? 124 : code, stdout, stderr });
  };
  child.stdout.on('data', (chunk) => { stdout += chunk; });
  child.stderr.on('data', (chunk) => { stderr += chunk; });
  child.once('error', (error) => {
    stderr += `\n受控 provider-pool 子进程启动失败：${error.message}`;
    finish(127);
  });
  child.once('close', (code) => finish(code));
  deadline = setTimeout(() => {
    timedOut = true;
    stderr += '\n受控 provider-pool 子进程超过 60 秒本地截止时间';
    child.kill('SIGTERM');
    forced = setTimeout(() => child.kill('SIGKILL'), 2000);
  }, 60000);
});
const reservePort = async () => {
  const server = http.createServer();
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const port = server.address().port;
  await new Promise((resolve) => server.close(resolve));
  return port;
};
const fetchFailureDetails = new WeakMap();
const classifyNestedFetchFailure = (error) => {
  const codeKinds = new Map([
    ['UND_ERR_SOCKET', 'socket_closed_or_reset'], ['ECONNRESET', 'socket_closed_or_reset'],
    ['EPIPE', 'socket_closed_or_reset'], ['UND_ERR_CONNECT_TIMEOUT', 'connect_timeout'],
    ['ETIMEDOUT', 'connect_timeout'], ['UND_ERR_HEADERS_TIMEOUT', 'response_timeout'],
    ['UND_ERR_BODY_TIMEOUT', 'response_timeout'], ['UND_ERR_ABORTED', 'request_aborted'],
    ['ABORT_ERR', 'request_aborted'], ['ECONNREFUSED', 'connection_refused'],
    ['ENETUNREACH', 'network_unreachable'], ['EHOSTUNREACH', 'network_unreachable'],
    ['UND_ERR_DESTROYED', 'client_state_invalid'], ['ERR_INVALID_STATE', 'client_state_invalid'],
    ['ERR_INVALID_ARG_TYPE', 'client_state_invalid'], ['EAI_AGAIN', 'dns_temporary'],
    ['ENOTFOUND', 'dns_not_found'], ['CERT_HAS_EXPIRED', 'tls_error'],
    ['DEPTH_ZERO_SELF_SIGNED_CERT', 'tls_error'], ['SELF_SIGNED_CERT_IN_CHAIN', 'tls_error'],
    ['UNABLE_TO_VERIFY_LEAF_SIGNATURE', 'tls_error'], ['ERR_TLS_CERT_ALTNAME_INVALID', 'tls_error'],
  ]);
  let nestedCausePresent = false;
  let aggregatePresent = false;
  let aggregateMembersAdded = 0;
  const pending = [];
  const addNested = (value, depth) => {
    if (depth > 2 || value === null || !['object', 'function'].includes(typeof value)) return;
    pending.push({ value, depth });
  };
  const addAggregate = (owner, depth) => {
    if (aggregateMembersAdded >= 4) return;
    try {
      const values = owner.errors;
      if (!Array.isArray(values)) return;
      aggregatePresent = true;
      const limit = Math.min(values.length, 4 - aggregateMembersAdded);
      for (let index = 0; index < limit; index += 1) {
        aggregateMembersAdded += 1;
        try { addNested(values[index], depth); } catch (_) {}
      }
    } catch (_) {}
  };
  try {
    if (error !== null && ['object', 'function'].includes(typeof error)) {
      const cause = error.cause;
      if (cause !== undefined && cause !== null) {
        nestedCausePresent = true;
        addNested(cause, 1);
      }
      addAggregate(error, 1);
    }
    let visited = 0;
    while (pending.length && visited < 12) {
      const { value, depth } = pending.shift();
      visited += 1;
      let code = '';
      let name = '';
      try {
        code = typeof value.code === 'string' ? value.code : '';
        name = typeof value.name === 'string' ? value.name : '';
      } catch (_) {}
      if (codeKinds.has(code)) return {
        nested_error_kind: codeKinds.get(code), nested_cause_present: nestedCausePresent,
        aggregate_present: aggregatePresent,
      };
      if (name === 'AbortError') return {
        nested_error_kind: 'request_aborted', nested_cause_present: nestedCausePresent,
        aggregate_present: aggregatePresent,
      };
      if (depth < 2) {
        try {
          const cause = value.cause;
          if (cause !== undefined && cause !== null) {
            nestedCausePresent = true;
            addNested(cause, depth + 1);
          }
          addAggregate(value, depth + 1);
        } catch (_) {}
      }
    }
  } catch (_) {}
  return { nested_error_kind: 'unclassified', nested_cause_present: nestedCausePresent,
    aggregate_present: aggregatePresent };
};
const fetchJson = async (url, options = {}) => {
  let fetchPhase = 'signal_setup';
  let localTimeoutFired = false;
  const controller = new AbortController();
  const abort = () => controller.abort();
  options.signal?.addEventListener('abort', abort, { once: true });
  if (options.signal?.aborted) controller.abort();
  const timer = setTimeout(() => { localTimeoutFired = true; abort(); }, options.timeout || 10000);
  try {
    fetchPhase = 'body_serialization';
    const requestBody = options.body === undefined ? undefined : JSON.stringify(options.body);
    fetchPhase = 'fetch_pending';
    const response = await fetch(url, {
      method: options.method || 'GET',
      headers: { ...(options.body === undefined ? {} : { 'content-type': 'application/json' }), ...(options.headers || {}) },
      body: requestBody,
      signal: controller.signal,
      redirect: 'error',
    });
    fetchPhase = 'response_received';
    const text = await response.text();
    fetchPhase = 'body_read';
    let responseBody = null;
    try { responseBody = JSON.parse(text); } catch (_) {}
    return { status: response.status, headers: Object.fromEntries(response.headers.entries()), body: responseBody };
  } catch (error) {
    if (error !== null && ['object', 'function'].includes(typeof error)) {
      try {
        fetchFailureDetails.set(error, {
          fetch_phase: fetchPhase,
          local_timeout_fired: localTimeoutFired,
          ...classifyNestedFetchFailure(error),
        });
      } catch (_) {}
    }
    throw error;
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
  const ragServerRequests = [], ragClientResults = [];
  const crispPostResponses = [], crispPostAttempts = [], retirementAdapterResponses = [];
  let dropNextAdapterResponse = false;
  let armSettlementWritebackFailure = false;
  let armRetirementWritebackFailure = false;
  let failNextSessionCommit = false;
  let sessionCommitFailureKind = '';
  let settlementWritebackFailures = 0;
  let retirementWritebackFailures = 0;
  let settlementTransportFailures = 0;
  let retirementTransportFailures = 0;
  let pendingRetirementResponseGate = null;
  let activeRetirementResponseGate = null;
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
  const materialsPath = path.join(root, 'config/materials-applied.json');
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
    const currentMaterials = readJson(materialsPath);
    const value = {
      runtime_revision: currentMaterials.revision,
      pool_revision: currentPool.revision,
      secrets_generation: currentPool.secrets_generation,
      pool_sha256: digest(fs.readFileSync(poolPath)),
      materials_source_sha256: currentMaterials.source_sha256,
    };
    value.configuration_binding = digest(JSON.stringify([
      value.runtime_revision, value.pool_revision, value.secrets_generation,
      value.pool_sha256, value.materials_source_sha256,
    ]));
    return value;
  };
  const providerConfiguration = currentProviderConfiguration();

  const rag = http.createServer(async (request, response) => {
    const observation = { kind: request.method === 'GET' ? 'workspace_read' : 'vector_search',
      body_read: false, response_started: false, finished: false, closed: false };
    ragServerRequests.push(observation);
    response.once('finish', () => { observation.finished = true; });
    response.once('close', () => { observation.closed = true; });
    assert.equal(request.headers.authorization, 'Bearer synthetic-rag-key');
    response.setHeader('content-type', 'application/json');
    if (request.method === 'GET') {
      assert.equal(request.url, '/api/v1/workspace/synthetic');
      observation.response_started = true;
      response.end(JSON.stringify({ workspace: { slug: 'synthetic', openAiTemp: 0.25 } }));
      return;
    }
    let raw = '';
    for await (const chunk of request) raw += chunk;
    observation.body_read = true;
    assert.equal(request.url, '/api/v1/workspace/synthetic/vector-search');
    assert.equal(typeof JSON.parse(raw).query, 'string');
    observation.response_started = true;
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
        crispPostAttempts.push({ session_id: session, body: structuredClone(options.body) });
        if (crispPostResponses.length) return structuredClone(crispPostResponses.shift());
        const entry = { ...structuredClone(options.body), session_id: session, timestamp: Date.now() };
        sent.push(entry); history.push(entry); histories.set(session, history);
        return { status: 200, body: { error: false, reason: 'dispatched', data: { fingerprint: entry.fingerprint } } };
      }
      throw new Error(`未预期 Crisp 方法：${options.method || 'GET'} ${suffix}`);
    }
    if (parsed.port === String(adapterPort)
      && ['/v1/chat/completions', '/internal/provider/replay', '/internal/provider/settle',
        '/internal/provider/retire'].includes(parsed.pathname)) {
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
    if (parsed.port === String(adapterPort) && parsed.pathname === '/internal/provider/retire'
      && retirementTransportFailures > 0) {
      retirementTransportFailures -= 1;
      const error = new Error('受控夹具暂时中断 Provider 退休回程');
      error.code = 'ECONNREFUSED';
      throw error;
    }
    if (parsed.port === String(adapterPort) && parsed.pathname === '/internal/provider/retire'
      && retirementAdapterResponses.length) {
      const response = structuredClone(retirementAdapterResponses.shift());
      adapterResponses.push(structuredClone(response));
      return response;
    }
    const isRag = parsed.port === String(rag.address()?.port || '');
    let response;
    try {
      response = await fetchJson(url, options);
      if (isRag) ragClientResults.push({
        kind: options.method === 'GET' ? 'workspace_read' : 'vector_search',
        outcome: 'response', status: response.status,
        timeout_ms: Number.isFinite(options.timeout) ? options.timeout : null,
        execution_aborted: options.signal?.aborted === true,
      });
    } catch (error) {
      if (isRag) {
        const executionAborted = options.signal?.aborted === true;
        const details = error !== null && ['object', 'function'].includes(typeof error)
          ? fetchFailureDetails.get(error) : null;
        const transportCodes = new Set(['ECONNREFUSED', 'ECONNRESET', 'EPIPE', 'ETIMEDOUT']);
        const errorKind = executionAborted ? 'execution_aborted'
          : error?.name === 'AbortError' ? 'request_aborted'
            : transportCodes.has(error?.code) ? 'transport_error' : 'other_error';
        ragClientResults.push({
          kind: options.method === 'GET' ? 'workspace_read' : 'vector_search',
          outcome: 'error', error_kind: errorKind,
          fetch_phase: ['signal_setup', 'body_serialization', 'fetch_pending',
            'response_received', 'body_read'].includes(details?.fetch_phase)
            ? details.fetch_phase : 'unclassified',
          local_timeout_fired: details?.local_timeout_fired === true,
          nested_error_kind: ['socket_closed_or_reset', 'connect_timeout', 'response_timeout',
            'request_aborted', 'connection_refused', 'network_unreachable', 'client_state_invalid',
            'dns_temporary', 'dns_not_found', 'tls_error'].includes(details?.nested_error_kind)
            ? details.nested_error_kind : 'unclassified',
          nested_cause_present: details?.nested_cause_present === true,
          aggregate_present: details?.aggregate_present === true,
          timeout_ms: Number.isFinite(options.timeout) ? options.timeout : null,
          execution_aborted: executionAborted,
        });
      }
      throw error;
    }
    if (parsed.port === String(adapterPort) && parsed.pathname === '/internal/provider/retire'
      && pendingRetirementResponseGate) {
      const gate = pendingRetirementResponseGate;
      pendingRetirementResponseGate = null;
      activeRetirementResponseGate = gate;
      gate.arrivedResolve();
      await gate.wait;
      if (activeRetirementResponseGate === gate) activeRetirementResponseGate = null;
    }
    if (parsed.port === String(adapterPort)
      && ['/v1/chat/completions', '/internal/provider/replay', '/internal/provider/settle',
        '/internal/provider/retire'].includes(parsed.pathname)) {
      adapterResponses.push(structuredClone(response));
      if (armSettlementWritebackFailure && parsed.pathname === '/internal/provider/settle'
        && response.status >= 200 && response.status < 300) {
        armSettlementWritebackFailure = false;
        failNextSessionCommit = true;
        sessionCommitFailureKind = 'settlement';
      }
      if (armRetirementWritebackFailure && parsed.pathname === '/internal/provider/retire'
        && response.status >= 200 && response.status < 300) {
        armRetirementWritebackFailure = false;
        failNextSessionCommit = true;
        sessionCommitFailureKind = 'retirement';
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
      const kind = sessionCommitFailureKind;
      sessionCommitFailureKind = '';
      if (kind === 'retirement') retirementWritebackFailures += 1;
      else settlementWritebackFailures += 1;
      const error = new Error(kind === 'retirement'
        ? '受控会话退休写回失败' : '受控会话结算写回失败');
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
    pendingRetirementResponseGate?.release();
    activeRetirementResponseGate?.release();
    fs.renameSync = originalRenameSync;
    await stopAdapter();
    for (const server of [rag, upstream]) server.closeAllConnections();
    await Promise.all([rag, upstream].map((server) => new Promise((resolve) => server.close(resolve))));
  };
  return {
    root, prompt, pool, providerConfiguration, internal, calls, sent, adapterResponses, signedProviderPayloads,
    ragServerRequests, ragClientResults,
    crispPostAttempts,
    event, receive, deliver, state,
    get adapterBase() { return adapterBase; },
    setBehavior(value) { upstreamBehavior = value; },
    dropNextAdapterResponse() { dropNextAdapterResponse = true; },
    failNextSettlementWriteback() { armSettlementWritebackFailure = true; },
    failNextSettlementRequest() { settlementTransportFailures += 1; },
    failNextRetirementWriteback() { armRetirementWritebackFailure = true; },
    failNextRetirementRequest() { retirementTransportFailures += 1; },
    holdNextRetirementResponse() {
      if (pendingRetirementResponseGate || activeRetirementResponseGate) {
        throw new Error('已有受控 Provider 退休响应等待释放');
      }
      let arrivedResolve;
      let releaseResolve;
      const arrived = new Promise((resolve) => { arrivedResolve = resolve; });
      const wait = new Promise((resolve) => { releaseResolve = resolve; });
      const gate = { arrivedResolve, wait, release: releaseResolve };
      pendingRetirementResponseGate = gate;
      return { arrived, release: () => gate.release() };
    },
    queueRetirementAdapterResponse(value) {
      retirementAdapterResponses.push(structuredClone(value));
    },
    queueCrispPostResponse(value) { crispPostResponses.push(structuredClone(value)); },
    settlementWritebackFailures: () => settlementWritebackFailures,
    retirementWritebackFailures: () => retirementWritebackFailures,
    advance(milliseconds) { now += milliseconds; },
    now: () => now,
    async killAdapter() { await stopAdapter('SIGKILL'); },
    async restartAdapter() { await startAdapter(); restartRuntime(); },
    restartRuntime,
    async verifyPool() {
      const result = await executePool(root, 'verify-applied', {
        PROVIDER_ADAPTER_MANAGEMENT_URL: adapterBase,
      });
      assert.equal(result.code, 0, result.stderr + result.stdout);
      return JSON.parse(result.stdout);
    },
    applyPrimary,
    publishRuntime(enabled) {
      const current = readJson(materialsPath);
      current.revision += 1;
      const previousEpoch = Number.isSafeInteger(current.configuration.runtime.disable_epoch)
        ? current.configuration.runtime.disable_epoch : 0;
      current.configuration.runtime = { ...current.configuration.runtime, enabled,
        disable_epoch: enabled ? previousEpoch : previousEpoch + 1,
        revision: current.revision, applied_revision: current.revision };
      writeJson(materialsPath, sealMaterials(current));
      return currentProviderConfiguration();
    },
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
    mutateState: (session, mutate) => runtime.transaction(
      runtime.stateKey(env.CRISP_WEBSITE_ID, session), mutate, env.CRISP_WEBSITE_ID, session),
    question: (jobId) => readJson(path.join(root, 'data/provider-router/questions', `${jobId}.json`)),
    questionPath: (jobId) => path.join(root, 'data/provider-router/questions', `${jobId}.json`),
    knowledgeIntegrity() {
      try {
        const current = readJson(materialsPath);
        return {
          readback_ok: true,
          projection_schema_v2: current.schema_version === 2,
          projection_state_applied: current.state === 'applied',
          map_matches: digest(fs.readFileSync(mapPath)) === current.knowledge?.map_sha256,
          settings_matches: digest(fs.readFileSync(settingsPath)) === current.knowledge?.settings_sha256,
          profile_matches: digest(fs.readFileSync(profilePath)) === current.knowledge?.profile_sha256,
          lexical_matches: digest(fs.readFileSync(lexicalPath)) === current.knowledge?.lexical_sha256,
        };
      } catch (_) {
        return { readback_ok: false, projection_schema_v2: null, projection_state_applied: null,
          map_matches: null, settings_matches: null, profile_matches: null,
          lexical_matches: null };
      }
    },
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
      assert.equal(stored.inference?.attempt_generation, 1,
        '模糊技术失败必须保留原代信封，先核对 adapter 是否已经持久结果');
      assert.equal(stored.inference?.provider_receipt_protocol_version, 1);
      assert.equal(stored.provider_result_receipt?.state, 'unknown');
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
      const converged = await f.process(result.key, result.jobId);
      assert.equal(converged.status, 'unresolved');
      assert.deepEqual(f.calls.map((call) => call.index), [0, 1],
        '首次恢复只能只读 replay，不能在确认旧结果前再次调用第三方接口');
      stored = pendingJob(f, event, result.jobId);
      assert.equal(stored.failure_code, 'question_result_absent');
      assert.equal(stored.inference, undefined,
        '只有 router 以完整身份确认 absent 后才释放旧推理信封');
      assert.equal(stored.provider_result_receipt, undefined);
      assert.equal(stored.data?.content, event.data.content);
      assertNoVisibleFailureReply(f);

      advancePastRetry(f, event, result.jobId);
      const recovered = await f.process(result.key, result.jobId);
      stored = pendingJob(f, event, result.jobId);
      const recoveryQuestionState = fs.existsSync(f.questionPath(result.jobId))
        ? f.question(result.jobId) : null;
      const routerStatusResponse = await fetchJson(`${f.adapterBase}/internal/provider/status`, {
        timeout: 1000, headers: { authorization: `Bearer ${f.internal}` },
      }).catch(() => ({ status: 0, body: null }));
      const matchesCurrentConfiguration = (payload) => Boolean(payload
        && payload.runtime_revision === f.providerConfiguration.runtime_revision
        && payload.pool_revision === f.providerConfiguration.pool_revision
        && payload.secrets_generation === f.providerConfiguration.secrets_generation
        && payload.pool_sha256 === f.providerConfiguration.pool_sha256
        && payload.materials_source_sha256 === f.providerConfiguration.materials_source_sha256);
      const recoveryDiagnostic = {
        result_status: recovered?.status || '',
        job_status: stored?.status || '',
        responsibility_status: stored?.responsibility_status || '',
        failure_code: stored?.failure_code || '',
        failure_rounds: Number.isSafeInteger(stored?.failure_rounds) ? stored.failure_rounds : null,
        retry_in_ms: Number.isFinite(stored?.retry_at)
          ? Math.max(0, stored.retry_at - f.now()) : null,
        data_present: stored?.data !== undefined,
        inference_present: stored?.inference !== undefined,
        inference_generation: Number.isSafeInteger(stored?.inference_generation)
          ? stored.inference_generation : null,
        active_attempt_generation: Number.isSafeInteger(stored?.inference?.attempt_generation)
          ? stored.inference.attempt_generation : null,
        receipt_state: stored?.provider_result_receipt?.state || '',
        receipt_reason: stored?.provider_result_receipt?.reason || '',
        receipt_stage: stored?.provider_result_receipt?.stage || '',
        settlement_state: stored?.provider_settlement?.state || '',
        plan_purpose: stored?.plan?.purpose || '',
        plan_diagnostic_code: stored?.plan?.diagnostic_code || '',
        question_attempt_generation: Number.isSafeInteger(recoveryQuestionState?.attempt_generation)
          ? recoveryQuestionState.attempt_generation : null,
        question_attempts: Number.isSafeInteger(recoveryQuestionState?.attempts)
          ? recoveryQuestionState.attempts : null,
        question_round_attempts: Number.isSafeInteger(recoveryQuestionState?.round_attempts)
          ? recoveryQuestionState.round_attempts : null,
        question_terminal_code: recoveryQuestionState?.terminal?.code || '',
        question_deadline_remaining_ms: Number.isFinite(recoveryQuestionState?.deadline)
          ? Math.max(0, recoveryQuestionState.deadline - Date.now()) : null,
        question_answer_tried_count: Array.isArray(recoveryQuestionState?.stages?.answer?.tried)
          ? recoveryQuestionState.stages.answer.tried.length : 0,
        question_answer_owner_present: recoveryQuestionState?.stages?.answer?.owner !== undefined,
        question_answer_result_present: recoveryQuestionState?.stages?.answer?.result !== undefined,
        upstream_call_indexes: f.calls.map((call) => call.index),
        signed_requests: f.signedProviderPayloads.map((entry) => ({
          path: entry.path,
          stage: entry.payload?.stage || '',
          attempt_generation: Number.isSafeInteger(entry.payload?.attempt_generation)
            ? entry.payload.attempt_generation : null,
          current_configuration: matchesCurrentConfiguration(entry.payload),
        })),
        adapter_responses: f.adapterResponses.map((entry) => ({
          status: Number.isSafeInteger(entry?.status) ? entry.status : 0,
          error_code: entry?.body?.error?.code || '',
        })),
        router_status_http: routerStatusResponse.status,
        router_pool_cooldown_remaining_ms: Number.isFinite(routerStatusResponse.body?.pool_cooldown_until)
          ? Math.max(0, routerStatusResponse.body.pool_cooldown_until - Date.now()) : null,
        router_entries: Array.isArray(routerStatusResponse.body?.entries)
          ? routerStatusResponse.body.entries.map((entry, index) => ({
            index, health: entry.health || '', last_error: entry.last_error || '',
            cooldown_remaining_ms: Number.isFinite(entry.cooldown_until)
              ? Math.max(0, entry.cooldown_until - Date.now()) : null,
          })) : [],
        router_questions: routerStatusResponse.body?.questions || null,
        rag_server_requests: f.ragServerRequests.map((entry) => ({ ...entry })),
        rag_client_results: f.ragClientResults.map((entry) => ({ ...entry })),
        knowledge_integrity: f.knowledgeIntegrity(),
        crisp_post_attempts: f.crispPostAttempts.length,
        visible_sends: f.sent.length,
      };
      assert.equal(recovered.status, 'sent',
        `恢复白名单快照：${JSON.stringify(recoveryDiagnostic)}`);
      assert.deepEqual(f.calls.map((call) => call.index), [0, 1, 0]);
      assertSingleBusinessReply(f);
      assert.equal(stored.status, 'done');
      assert.equal(stored.responsibility_status, 'answered_confirmed');
      assert.equal(stored.id, result.jobId, '恢复轮不得新建另一问题责任');
      assert.equal(stored.inference_generation, 2);
      assert.equal(stored.inference, undefined,
        'Provider 计划已结算后必须释放临时推理身份，不能把已完成尝试留成活动责任');
      assert.equal(stored.provider_result_receipt, undefined);
      assert.equal(stored.provider_settlement?.state, 'settled');
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

  await test('错代Provider回执必须保留原责任并阻止二次推理，等待受控诊断恢复', async (f) => {
    const event = f.event('invalid-provider-receipt');
    const accepted = await f.receive(event);
    assert.equal(accepted.accepted, true);
    await f.mutateState(event.data.session_id, (state) => {
      const job = state.jobs.find((entry) => entry.id === accepted.jobId);
      job.inference_generation = 1;
      job.inference = { ...f.providerConfiguration, deadline_at: f.now() + 7000,
        attempt_generation: 1, provider_receipt_protocol_version: 1 };
      job.provider_result_receipt = {
        state: 'unknown', stage: 'answer', attempt_generation: 2,
        configuration_binding: f.providerConfiguration.configuration_binding,
        request_contract_version: 1, request_sha256: 'a'.repeat(64),
        plan_context_sha256: digest(canonical(null)), plan_context: null,
        first_unknown_at: f.now(), last_checked_at: f.now(), next_action_at: 0, checks: 1,
      };
    });
    const first = await f.process(accepted.key, accepted.jobId);
    assert.equal(first.status, 'unresolved');
    assert.equal(f.calls.length, 0, '错代回执不得取得任何 Provider route 权限');
    assert.equal(f.signedProviderPayloads.filter((entry) =>
      ['/v1/chat/completions', '/internal/provider/replay'].includes(entry.path)).length, 0,
    '错代回执不得触发 adapter route 或 replay');
    assertNoVisibleFailureReply(f);
    let stored = pendingJob(f, event, accepted.jobId);
    assert.equal(stored.responsibility_status, 'unresolved_failure');
    assert.equal(stored.failure_code, 'provider_receipt_identity_unresolved');
    assert.equal(stored.inference?.attempt_generation, 1);
    assert.equal(stored.provider_result_receipt?.attempt_generation, 2);
    assert.equal(stored.data?.content, event.data.content);

    advancePastRetry(f, event, accepted.jobId);
    const repeated = await f.process(accepted.key, accepted.jobId);
    assert.equal(repeated.status, 'unresolved');
    assert.equal(f.calls.length, 0, '重复扫描不得把损坏身份反推成 absent 后重新推理');
    assert.equal(f.signedProviderPayloads.filter((entry) =>
      ['/v1/chat/completions', '/internal/provider/replay'].includes(entry.path)).length, 0,
    '重复扫描仍不得把错代回执提交给 adapter');
    assertNoVisibleFailureReply(f);
    stored = pendingJob(f, event, accepted.jobId);
    assert.equal(stored.failure_code, 'provider_receipt_identity_unresolved');
    assert.equal(stored.inference?.attempt_generation, 1);
    assert.equal(stored.provider_result_receipt?.attempt_generation, 2);
  });

  for (const variant of [
    { name: '字符串', slug: 'string', value: () => 'corrupt' },
    { name: '数组', slug: 'array', value: () => [] },
    { name: '空对象', slug: 'empty', value: () => ({}) },
    { name: '缺少期限', slug: 'missing-deadline', value: (f) => ({ pool_revision: f.providerConfiguration.pool_revision }) },
    { name: '带多余字段', slug: 'extra-field', value: (f) => ({ pool_revision: f.providerConfiguration.pool_revision,
      deadline_at: f.now() + 7000, extra: true }) },
    { name: '旧式完整配置对象', slug: 'full-object', value: (f) => ({ ...f.providerConfiguration,
      deadline_at: f.now() + 7000, attempt_generation: 1 }) },
  ]) {
    await test(`畸形旧推理信封（${variant.name}）必须保留责任且零adapter调用`, async (f) => {
      const event = f.event(`malformed-legacy-${variant.slug}`);
      const accepted = await f.receive(event);
      assert.equal(accepted.accepted, true);
      await f.mutateState(event.data.session_id, (state) => {
        const job = state.jobs.find((entry) => entry.id === accepted.jobId);
        job.inference_generation = 1;
        job.inference = variant.value(f);
        delete job.provider_result_receipt;
      });
      const result = await f.process(accepted.key, accepted.jobId);
      assert.equal(result.status, 'unresolved');
      assert.equal(f.calls.length, 0);
      assert.equal(f.signedProviderPayloads.filter((entry) =>
        ['/v1/chat/completions', '/internal/provider/replay'].includes(entry.path)).length, 0,
      '未知旧状态不得取得 route 或 replay 权限');
      assertNoVisibleFailureReply(f);
      const stored = pendingJob(f, event, accepted.jobId);
      assert.equal(stored.status, 'received');
      assert.equal(stored.responsibility_status, 'unresolved_failure');
      assert.equal(stored.failure_code, 'provider_receipt_identity_unresolved');
      assert.equal(stored.data?.content, event.data.content);
      assert.deepEqual(stored.inference, variant.value(f));
    });
  }

  await test('配置事务窗口不得清除畸形旧推理身份，恢复配置后仍保持未完成责任', async (f) => {
    const event = f.event('malformed-inference-during-configuration');
    const accepted = await f.receive(event);
    assert.equal(accepted.accepted, true);
    await f.mutateState(event.data.session_id, (state) => {
      const job = state.jobs.find((entry) => entry.id === accepted.jobId);
      job.inference_generation = 1;
      job.inference = 'unknown-legacy-inference';
      job.deferred_configuration = true;
      delete job.provider_result_receipt;
    });
    const marker = path.join(f.root, 'config/provider-pool-transaction.json');
    fs.writeFileSync(marker, '{}\n', { mode: 0o600 });
    const waiting = await f.process(accepted.key, accepted.jobId);
    assert.equal(waiting.status, 'idle');
    let stored = pendingJob(f, event, accepted.jobId);
    assert.equal(stored.status, 'received');
    assert.equal(stored.responsibility_status, 'unresolved_failure');
    assert.equal(stored.failure_code, 'provider_receipt_identity_unresolved');
    assert.equal(stored.inference, 'unknown-legacy-inference');
    assert.equal(stored.deferred_configuration, true);
    assert.equal(stored.retry_at, f.now() + 5000);
    assert.equal(stored.lease_until, 0);
    assert.equal(stored.data?.content, event.data.content);
    assert.equal(f.calls.length, 0);
    assert.equal(f.signedProviderPayloads.length, 0);
    assert.equal(f.crispPostAttempts.length, 0);
    assertNoVisibleFailureReply(f);

    const deferredFailure = {
      rounds: stored.failure_rounds,
      since: stored.failure_since,
      last: stored.last_failure_at,
      attempts: stored.attempts,
    };
    for (let round = 0; round < 3; round += 1) {
      f.advance(Math.max(1, stored.retry_at - f.now() + 1));
      if (round % 2 === 0) {
        const selected = await f.scan();
        assert.equal(selected.some((entry) => entry.key === accepted.key
          && entry.jobId === accepted.jobId), false,
        '配置 marker 存在时 scan 不得把身份故障重新交给执行器');
      } else {
        const repeated = await f.process(accepted.key, accepted.jobId);
        assert.equal(repeated.status, 'idle');
      }
      stored = pendingJob(f, event, accepted.jobId);
      assert.deepEqual({
        rounds: stored.failure_rounds,
        since: stored.failure_since,
        last: stored.last_failure_at,
        attempts: stored.attempts,
      }, deferredFailure, '配置 marker 轮询不得虚增故障轮次、时间或尝试数');
      assert.equal(stored.inference, 'unknown-legacy-inference');
      assert.equal(stored.deferred_configuration, true);
      assert.equal(stored.retry_at, f.now() + 5000);
      assert.equal(stored.lease_until, 0);
      assert.equal(stored.data?.content, event.data.content);
      assert.equal(f.calls.length, 0);
      assert.equal(f.signedProviderPayloads.length, 0);
      assert.equal(f.crispPostAttempts.length, 0);
      assertNoVisibleFailureReply(f);
    }

    fs.unlinkSync(marker);
    f.advance(Math.max(1, stored.retry_at - f.now() + 1));
    const protectedResult = await f.process(accepted.key, accepted.jobId);
    assert.equal(protectedResult.status, 'idle');
    stored = pendingJob(f, event, accepted.jobId);
    assert.equal(stored.status, 'received');
    assert.equal(stored.responsibility_status, 'unresolved_failure');
    assert.equal(stored.failure_code, 'provider_receipt_identity_unresolved');
    assert.equal(stored.inference, 'unknown-legacy-inference');
    assert.equal(stored.data?.content, event.data.content);
    assert.equal(stored.deferred_configuration, undefined);
    assert.equal(stored.retry_at, f.now() + 300000);
    assert.equal(stored.lease_until, 0);
    assert.equal(stored.failure_rounds, deferredFailure.rounds + 1,
      '配置事务结束后才应按身份故障语义登记新的恢复轮次');
    assert.equal(stored.failure_since, deferredFailure.since);
    assert.equal(stored.last_failure_at, f.now());
    assert.equal(stored.attempts, deferredFailure.attempts);
    assert.equal(f.calls.length, 0);
    assert.equal(f.signedProviderPayloads.length, 0);
    assert.equal(f.crispPostAttempts.length, 0);
    assertNoVisibleFailureReply(f);
  });

  await test('v1.2.1临时迁移来源与旧推理不一致时fail closed且不得调用adapter', async (f) => {
    const event = f.event('legacy-pending-origin-conflict');
    const accepted = await f.receive(event);
    assert.equal(accepted.accepted, true);
    await f.mutateState(event.data.session_id, (state) => {
      const job = state.jobs.find((entry) => entry.id === accepted.jobId);
      const legacyDeadline = f.now() + 7000;
      job.inference_generation = 1;
      job.inference = { pool_revision: f.providerConfiguration.pool_revision,
        deadline_at: legacyDeadline };
      job.legacy_v121_pending_origin = { schema_version: 1, phase: 'source_frozen', source: {
        runtime_revision: job.revision,
        pool_revision: f.providerConfiguration.pool_revision,
        deadline_at: legacyDeadline + 1,
      } };
      delete job.provider_result_receipt;
    });
    const result = await f.process(accepted.key, accepted.jobId);
    assert.equal(result.status, 'unresolved');
    assert.equal(f.calls.length, 0);
    assert.equal(f.signedProviderPayloads.filter((entry) =>
      ['/v1/chat/completions', '/internal/provider/replay'].includes(entry.path)).length, 0);
    assertNoVisibleFailureReply(f);
    const stored = pendingJob(f, event, accepted.jobId);
    assert.equal(stored.status, 'received');
    assert.equal(stored.responsibility_status, 'unresolved_failure');
    assert.equal(stored.failure_code, 'provider_receipt_identity_unresolved');
    assert.equal(stored.data?.content, event.data.content);
    assert.equal(stored.inference?.deadline_at + 1,
      stored.legacy_v121_pending_origin?.source?.deadline_at);
  });

  await test('v1.2.1旧推理混入未知结算时不得迁移或重新调用Provider', async (f) => {
    const event = f.event('legacy-inference-with-settlement');
    const accepted = await f.receive(event);
    assert.equal(accepted.accepted, true);
    let legacyInference;
    await f.mutateState(event.data.session_id, (state) => {
      const job = state.jobs.find((entry) => entry.id === accepted.jobId);
      job.inference_generation = 1;
      legacyInference = { pool_revision: f.providerConfiguration.pool_revision,
        deadline_at: f.now() + 7000 };
      job.inference = { ...legacyInference };
      job.provider_settlement = { schema_version: 1, state: 'deferred' };
      delete job.provider_result_receipt;
    });
    const result = await f.process(accepted.key, accepted.jobId);
    assert.equal(result.status, 'unresolved');
    assert.equal(result.reason, 'provider_settlement_identity_unresolved');
    assert.equal(f.calls.filter((call) => call.phase === 'runtime').length, 0);
    assert.equal(f.signedProviderPayloads.filter((entry) =>
      ['/v1/chat/completions', '/internal/provider/replay', '/internal/provider/settle']
        .includes(entry.path)).length, 0);
    assertNoVisibleFailureReply(f);
    const stored = pendingJob(f, event, accepted.jobId);
    assert.equal(stored.status, 'received');
    assert.equal(stored.responsibility_status, 'unresolved_failure');
    assert.equal(stored.failure_code, 'provider_settlement_identity_unresolved');
    assert.equal(stored.provider_settlement_failure_code,
      'provider_settlement_identity_unresolved');
    assert.deepEqual(stored.inference, legacyInference);
    assert.equal(stored.provider_settlement?.schema_version, 1);
    assert.equal(stored.provider_settlement?.state, 'invalid');
    assert.equal(stored.provider_settlement?.reason, 'settlement_invalid');
    assert.equal(stored.data?.content, event.data.content);
  });

  await test('v1.2.1旧推理混入伪完成结算时不得迁移或采用未知结果', async (f) => {
    const event = f.event('legacy-inference-with-finished-settlement');
    const accepted = await f.receive(event);
    assert.equal(accepted.accepted, true);
    const legacyInference = { pool_revision: f.providerConfiguration.pool_revision,
      deadline_at: f.now() + 7000 };
    await f.mutateState(event.data.session_id, (state) => {
      const job = state.jobs.find((entry) => entry.id === accepted.jobId);
      job.inference_generation = 1;
      job.inference = { ...legacyInference };
      job.provider_settlement = { schema_version: 1, state: 'settled',
        plan_sha256: digest('unknown-plan'), response_generation: 0,
        attempts: 1, settled_at: f.now() };
      delete job.provider_result_receipt;
    });
    const result = await f.process(accepted.key, accepted.jobId);
    assert.equal(result.status, 'unresolved');
    assert.equal(f.calls.filter((call) => call.phase === 'runtime').length, 0);
    assert.equal(f.signedProviderPayloads.filter((entry) =>
      ['/v1/chat/completions', '/internal/provider/replay', '/internal/provider/settle']
        .includes(entry.path)).length, 0);
    assertNoVisibleFailureReply(f);
    const stored = pendingJob(f, event, accepted.jobId);
    assert.equal(stored.status, 'received');
    assert.equal(stored.responsibility_status, 'unresolved_failure');
    assert.equal(stored.failure_code, 'provider_receipt_identity_unresolved');
    assert.deepEqual(stored.inference, legacyInference);
    assert.equal(stored.provider_settlement?.state, 'settled');
    assert.equal(stored.data?.content, event.data.content);
  });

  for (const variant of [
    { name: '缺少协议标记', slug: 'missing-marker', marker: undefined, stage: 'answer' },
    { name: '未知协议标记', slug: 'unknown-marker', marker: 2, stage: 'answer' },
    { name: '跨阶段回执', slug: 'cross-stage', marker: 1, stage: 'vision' },
  ]) {
    await test(`${variant.name}的Provider回执必须fail closed且零adapter调用`, async (f) => {
      const event = f.event(`invalid-receipt-${variant.slug}`);
      const accepted = await f.receive(event);
      assert.equal(accepted.accepted, true);
      await f.mutateState(event.data.session_id, (state) => {
        const job = state.jobs.find((entry) => entry.id === accepted.jobId);
        job.inference_generation = 1;
        job.inference = { ...f.providerConfiguration, deadline_at: f.now() + 7000,
          attempt_generation: 1 };
        if (variant.marker !== undefined) {
          job.inference.provider_receipt_protocol_version = variant.marker;
        }
        job.provider_result_receipt = {
          state: 'unknown', stage: variant.stage, attempt_generation: 1,
          configuration_binding: f.providerConfiguration.configuration_binding,
          request_contract_version: 1, request_sha256: 'a'.repeat(64),
          plan_context_sha256: digest(canonical(null)), plan_context: null,
          first_unknown_at: f.now(), last_checked_at: f.now(), next_action_at: 0, checks: 1,
        };
      });
      const result = await f.process(accepted.key, accepted.jobId);
      assert.equal(result.status, 'unresolved');
      assert.equal(f.calls.length, 0);
      assert.equal(f.signedProviderPayloads.filter((entry) =>
        ['/v1/chat/completions', '/internal/provider/replay'].includes(entry.path)).length, 0,
      '无效回执不得提交给 adapter');
      assertNoVisibleFailureReply(f);
      const stored = pendingJob(f, event, accepted.jobId);
      assert.equal(stored.responsibility_status, 'unresolved_failure');
      assert.equal(stored.failure_code, 'provider_receipt_identity_unresolved');
      assert.equal(stored.data?.content, event.data.content);
    });
  }

  await test('v1.2.x无回执旧推理信封由独占任务迁移，原问题以新代只回答一次', async (f) => {
    const event = f.event('legacy-inference-migration');
    const accepted = await f.receive(event);
    assert.equal(accepted.accepted, true);
    const legacyDeadline = f.now() + 7000;
    await f.mutateState(event.data.session_id, (state) => {
      const job = state.jobs.find((entry) => entry.id === accepted.jobId);
      job.inference_generation = 1;
      job.inference = { pool_revision: f.providerConfiguration.pool_revision,
        deadline_at: legacyDeadline };
      delete job.provider_result_receipt;
      const binding = digest(JSON.stringify(['conversation', accepted.key, state.generation,
        job.revision, f.providerConfiguration.pool_revision, legacyDeadline]));
      writeJson(path.join(f.root, 'data/provider-router/questions', `${accepted.jobId}.json`), {
        id: accepted.jobId, binding, attempt_generation: 1,
        revision: f.providerConfiguration.pool_revision, deadline: legacyDeadline,
        attempts: 0, round_attempts: 0, stages: {}, created_at: f.now(),
      });
    });
    const recovered = await f.process(accepted.key, accepted.jobId);
    assert.equal(recovered.status, 'sent', f.adapterErrors());
    assert.deepEqual(f.calls.map((call) => call.index), [0]);
    assertSingleBusinessReply(f);
    const stored = pendingJob(f, event, accepted.jobId);
    assert.equal(stored.status, 'done');
    assert.equal(stored.responsibility_status, 'answered_confirmed');
    assert.equal(stored.inference_generation, 2);
    assert.equal(stored.inference, undefined);
    assert.equal(stored.provider_result_receipt, undefined);
    assert.equal(stored.provider_settlement?.state, 'settled');
    assert.equal(Number.isFinite(stored.legacy_provider_inference_migrated_at), true);
    const question = f.question(accepted.jobId);
    assert.equal(question.schema_version, 2);
    assert.equal(question.attempt_generation, 2);
    assert.equal(Number.isFinite(question.legacy_v121_migrated_at), true);
    assert.deepEqual(question.legacy_v121_origin, {
      runtime_revision: f.providerConfiguration.runtime_revision,
      pool_revision: f.providerConfiguration.pool_revision,
      deadline_at: legacyDeadline,
    });
    assert.equal(stored.id, accepted.jobId);
    assert.equal(f.sent.length, 1);
  });

  await test('v1.2.1旧问题先遇接口A到B换代仍保留责任，四类缓存均只采用B代新答案', async (f) => {
    const legacyCases = [
      { name: '无阶段', stages: {}, attempts: 0 },
      { name: '遗留owner', stages: { answer: { owner: { token: 'legacy-owner' }, tried: [] } }, attempts: 0 },
      { name: '技术终态', stages: { answer: { tried: [] } }, attempts: 1,
        terminal: { code: 'question_timeout', message: '旧版技术终态' } },
      { name: '无请求契约答案', stages: { answer: { tried: [0],
        result: { choices: [{ message: { role: 'assistant', content: '旧版不可直接采用答案。' } }] } } }, attempts: 1 },
    ];
    const pending = [];
    for (const [index, item] of legacyCases.entries()) {
      const event = f.event(`legacy-before-pool-change-${index}`);
      const accepted = await f.receive(event);
      assert.equal(accepted.accepted, true);
      const legacyDeadline = f.now() + 7000 + index;
      await f.mutateState(event.data.session_id, (state) => {
        const job = state.jobs.find((entry) => entry.id === accepted.jobId);
        job.inference_generation = 1;
        job.inference = { pool_revision: f.providerConfiguration.pool_revision,
          deadline_at: legacyDeadline };
        delete job.provider_result_receipt;
        const binding = digest(JSON.stringify(['conversation', accepted.key, state.generation,
          job.revision, f.providerConfiguration.pool_revision, legacyDeadline]));
        writeJson(path.join(f.root, 'data/provider-router/questions', `${accepted.jobId}.json`), {
          id: accepted.jobId, binding, revision: f.providerConfiguration.pool_revision,
          deadline: legacyDeadline, attempts: item.attempts, stages: structuredClone(item.stages),
          ...(item.terminal ? { terminal: structuredClone(item.terminal) } : {}), created_at: f.now(),
        });
      });
      pending.push({ event, accepted, name: item.name, legacyDeadline });
    }

    await f.applyPrimary('b', 3);
    const appliedB = { configuration: f.publishRuntime(true) };
    f.restartRuntime();
    let latestRetryAt = f.now();
    for (const item of pending) {
      const deferred = await f.process(item.accepted.key, item.accepted.jobId);
      assert.equal(deferred.status, 'deferred', `${item.name}必须先冻结旧来源再跨配置代`);
      const stored = pendingJob(f, item.event, item.accepted.jobId);
      assert.deepEqual(stored.legacy_v121_pending_origin, {
        schema_version: 1,
        phase: 'source_frozen',
        source: {
          runtime_revision: f.providerConfiguration.runtime_revision,
          pool_revision: f.providerConfiguration.pool_revision,
          deadline_at: item.legacyDeadline,
        },
      }, `${item.name}必须在改写runtime revision前冻结完整旧来源`);
      assert.equal(stored.inference?.pool_revision, f.providerConfiguration.pool_revision,
        `${item.name}配置事务等待期必须保留旧推理身份`);
      latestRetryAt = Math.max(latestRetryAt, stored.retry_at);
    }
    assert.equal(f.calls.filter((call) => call.phase === 'runtime').length, 0,
      '冻结旧来源的维护轮不得调用任何第三方接口');
    f.advance(Math.max(1, latestRetryAt - f.now() + 1));
    for (const item of pending) {
      const result = await f.process(item.accepted.key, item.accepted.jobId);
      assert.equal(result.status, 'sent', `${item.name}: ${f.adapterErrors()}`);
      const stored = pendingJob(f, item.event, item.accepted.jobId);
      assert.equal(stored.status, 'done', item.name);
      assert.equal(stored.responsibility_status, 'answered_confirmed', item.name);
      assert.equal(stored.inference_generation, 2, item.name);
      assert.equal(stored.inference, undefined, item.name);
      assert.equal(stored.provider_result_receipt, undefined, item.name);
      assert.equal(stored.provider_settlement?.state, 'settled', item.name);
      assert.equal(stored.legacy_v121_pending_origin, undefined,
        `${item.name}签名迁移完成后必须原子消费临时来源标记`);
      const question = f.question(item.accepted.jobId);
      assert.deepEqual(question.legacy_v121_origin, {
        runtime_revision: f.providerConfiguration.runtime_revision,
        pool_revision: f.providerConfiguration.pool_revision,
        deadline_at: item.legacyDeadline,
      }, item.name);
      assert.equal(question.schema_version, 2, item.name);
      assert.equal(question.configuration.pool_revision, appliedB.configuration.pool_revision, item.name);
      assert.equal(question.configuration_binding,
        appliedB.configuration.configuration_binding, item.name);
      assert.equal(question.attempt_generation, 2, item.name);
      assert.equal(JSON.stringify(question).includes('旧版不可直接采用答案。'), false,
        `${item.name}不得把无请求契约旧正文直接出站或继续缓存`);
    }
    assert.deepEqual(f.calls.filter((call) => call.phase === 'runtime').map((call) => call.index),
      [3, 3, 3, 3], '四个旧责任都必须只调用当前B配置');
    assert.equal(f.sent.length, legacyCases.length);
    for (const message of f.sent) assert.equal(message.content, '受控配置 B 的有效答案。');
  });

  await test('v1.2.1旧问题来源任一字段不符时保留责任且不采用旧正文', async (f) => {
    const event = f.event('legacy-origin-conflict');
    const accepted = await f.receive(event);
    assert.equal(accepted.accepted, true);
    const legacyDeadline = f.now() + 7000;
    await f.mutateState(event.data.session_id, (state) => {
      const job = state.jobs.find((entry) => entry.id === accepted.jobId);
      job.inference_generation = 1;
      job.inference = { pool_revision: f.providerConfiguration.pool_revision,
        deadline_at: legacyDeadline };
      delete job.provider_result_receipt;
      const wrongBinding = digest(JSON.stringify(['conversation', accepted.key, state.generation,
        job.revision, f.providerConfiguration.pool_revision, legacyDeadline + 1]));
      writeJson(path.join(f.root, 'data/provider-router/questions', `${accepted.jobId}.json`), {
        id: accepted.jobId, binding: wrongBinding, revision: f.providerConfiguration.pool_revision,
        deadline: legacyDeadline, attempts: 0, stages: {}, created_at: f.now(),
      });
    });
    await f.applyPrimary('b', 3);
    f.publishRuntime(true);
    f.restartRuntime();
    const beforeRuntime = f.calls.filter((call) => call.phase === 'runtime').length;
    const deferred = await f.process(accepted.key, accepted.jobId);
    assert.equal(deferred.status, 'deferred');
    let stored = pendingJob(f, event, accepted.jobId);
    assert.deepEqual(stored.legacy_v121_pending_origin, {
      schema_version: 1,
      phase: 'source_frozen',
      source: {
        runtime_revision: f.providerConfiguration.runtime_revision,
        pool_revision: f.providerConfiguration.pool_revision,
        deadline_at: legacyDeadline,
      },
    });
    advancePastRetry(f, event, accepted.jobId);
    const result = await f.process(accepted.key, accepted.jobId);
    assert.equal(result.status, 'unresolved');
    assert.equal(f.calls.filter((call) => call.phase === 'runtime').length, beforeRuntime,
      '旧来源不匹配不得调用任何第三方接口');
    assertNoVisibleFailureReply(f);
    stored = pendingJob(f, event, accepted.jobId);
    assert.equal(stored.status, 'received');
    assert.equal(stored.responsibility_status, 'unresolved_failure');
    assert.equal(stored.failure_code, 'question_conflict');
    assert.equal(stored.data?.content, event.data.content);
    assert.equal(stored.inference?.attempt_generation, 2);
    assert.deepEqual(stored.inference?.legacy_v121_origin, {
      runtime_revision: f.providerConfiguration.runtime_revision,
      pool_revision: f.providerConfiguration.pool_revision,
      deadline_at: f.question(accepted.jobId).deadline,
    });
  });

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

  await test('adapter已缓存结果但真人先接管时只退休该结果，不重放、不出站且身份可审计', async (f) => {
    f.dropNextAdapterResponse();
    const event = f.event('response-lost-then-human-retirement');
    const first = await f.deliver(event);
    assert.equal(first.status, 'unresolved');
    assert.equal(f.calls.filter((call) => call.phase === 'runtime').length, 1);
    assertNoVisibleFailureReply(f);
    const questionFile = path.join(f.root, 'data/provider-router/questions', `${first.jobId}.json`);
    assert.equal(fs.existsSync(questionFile), true);
    assert.equal(f.question(first.jobId).stages.answer.result.choices[0].message.content,
      '受控正常答案。');

    const operator = {
      website_id: event.website_id, event: 'message:received', timestamp: f.now() + 1,
      data: { session_id: event.data.session_id, from: 'operator', type: 'text',
        content: '受控人工已接管。', fingerprint: 900101, timestamp: f.now() + 1,
        automated: false },
    };
    const received = await f.receive(operator);
    assert.equal(received.accepted, true);
    let stored = pendingJob(f, event, first.jobId);
    assert.equal(f.state(event.data.session_id).mode, 'human');
    assert.equal(stored.status, 'cancelled');
    assert.equal(stored.responsibility_status, 'intentional_silence');
    assert.equal(stored.responsibility_reason, 'human_reply');
    assert.equal(stored.provider_retirement?.state, 'pending');
    assert(stored.inference);assert(stored.provider_result_receipt);
    assert.equal(fs.existsSync(questionFile), true,
      '人工事务提交后必须先保留精确Provider身份，不能无签名删除缓存');

    const controlSelected = await f.scan();
    assert.equal(controlSelected.some((entry) => entry.key === received.key
      && entry.jobId === received.jobId && entry.control === true), true,
    '真人控制任务必须先于 cleanup-only 退休任务完成后处理');
    assert.equal(controlSelected.some((entry) => entry.key === first.key
      && entry.jobId === first.jobId), false,
    '同一会话每轮只选一个任务，首轮不得用缓存清理挤占真人控制');
    const controlled = await f.process(received.key, received.jobId);
    assert.equal(controlled.status, 'none');
    const controlJob = f.state(event.data.session_id).jobs
      .find((entry) => entry.id === received.jobId);
    assert.equal(controlJob.status, 'done');
    assert.equal(controlJob.responsibility_status, 'control_handled');
    assertNoVisibleFailureReply(f);
    assert.equal(fs.existsSync(questionFile), true,
      '真人控制完成前后均不得无签名删除 Provider 缓存');

    const selected = await f.scan();
    assert.equal(selected.some((entry) => entry.key === first.key && entry.jobId === first.jobId), true,
      '真人控制完成后的下一轮必须选择到期的 cleanup-only 退休任务');
    const retired = await f.process(first.key, first.jobId);
    assert.equal(retired.status, 'provider_retirement_retired', f.adapterErrors());
    stored = pendingJob(f, event, first.jobId);
    assert.equal(stored.status, 'cancelled');
    assert.equal(stored.responsibility_status, 'intentional_silence');
    assert.equal(stored.inference, undefined);assert.equal(stored.provider_result_receipt, undefined);
    assert.deepEqual(Object.keys(stored.provider_retirement).sort(),
      ['attempts','identity_sha256','purpose','retired_at','schema_version','state'].sort());
    assert.equal(stored.provider_retirement.state, 'retired');
    assert.equal(stored.provider_retirement.purpose, 'conversation_cancelled');
    assert.equal(fs.existsSync(questionFile), false);
    const signed = f.signedProviderPayloads.filter((entry) => entry.path === '/internal/provider/retire');
    assert.equal(signed.length, 1);assert.ok(signed[0].token_length < 8192);
    assert.deepEqual(Object.keys(signed[0].payload).sort(), [
      'attempt_generation', 'configuration_binding', 'deadline_at', 'generation',
      'materials_source_sha256', 'plan_context_sha256', 'pool_revision', 'pool_sha256',
      'question_id', 'request_contract_version', 'request_sha256', 'runtime_revision',
      'scope', 'secrets_generation', 'session_key', 'stage', 'version',
    ].sort());
    assert.equal(f.calls.filter((call) => call.phase === 'runtime').length, 1,
      '退休事务不得重放或重新调用Provider');
    assert.equal(f.sent.length, 0,'人工接管后的缓存结果不得出站');
  });

  await test('v1.2.1直接/source_frozen/successor_bound旧缓存遇人工时均只做签名清理', async (f) => {
    const variants = ['direct', 'source_frozen', 'successor_bound'];
    for (const [index, variant] of variants.entries()) {
      const event = f.event(`legacy-retirement-${variant.replace(/_/g, '-')}`);
      const accepted = await f.receive(event);
      assert.equal(accepted.accepted, true);
      const deadline = f.now() + 7000 + index;
      await f.mutateState(event.data.session_id, (state) => {
        const job = state.jobs.find((entry) => entry.id === accepted.jobId);
        const source = { runtime_revision: job.revision,
          pool_revision: f.providerConfiguration.pool_revision, deadline_at: deadline };
        job.inference_generation = 1;
        job.inference = { pool_revision: source.pool_revision, deadline_at: deadline };
        delete job.provider_result_receipt; delete job.provider_settlement; delete job.plan;
        if (variant === 'source_frozen') {
          job.legacy_v121_pending_origin = { schema_version: 1,
            phase: 'source_frozen', source: { ...source } };
        }
        if (variant === 'successor_bound') {
          job.revision = source.runtime_revision + 1;
          const { configuration_binding: _binding, ...baseTarget } = f.providerConfiguration;
          const target = { ...baseTarget, runtime_revision: job.revision };
          const targetConfigurationBinding = digest(JSON.stringify([
            target.runtime_revision, target.pool_revision, target.secrets_generation,
            target.pool_sha256, target.materials_source_sha256,
          ]));
          job.legacy_v121_pending_origin = { schema_version: 1,
            phase: 'successor_bound', source: { ...source }, target,
            target_configuration_binding: targetConfigurationBinding };
          delete job.inference;
        }
        const binding = digest(JSON.stringify(['conversation', accepted.key, state.generation,
          source.runtime_revision, source.pool_revision, source.deadline_at]));
        writeJson(path.join(f.root, 'data/provider-router/questions', `${accepted.jobId}.json`), {
          id: accepted.jobId, binding, revision: source.pool_revision,
          deadline: source.deadline_at, attempts: 1,
          stages: { answer: { tried: [f.pool.primary_id],
            result: { choices: [{ message: { role: 'assistant',
              content: '人工接管后不得出站的旧缓存结果。' } }] } } }, created_at: f.now(),
        });
      });
      const operator = {
        website_id: event.website_id, event: 'message:received', timestamp: f.now() + index + 1,
        data: { session_id: event.data.session_id, from: 'operator', type: 'text',
          content: '受控人工已接管。', fingerprint: 901000 + index,
          timestamp: f.now() + index + 1, automated: false },
      };
      assert.equal((await f.receive(operator)).accepted, true);
      let stored = pendingJob(f, event, accepted.jobId);
      assert.equal(stored.status, 'cancelled', variant);
      assert.equal(stored.responsibility_status, 'intentional_silence', variant);
      assert.equal(stored.provider_retirement?.state, 'pending', variant);
      assert.equal(stored.provider_retirement?.purpose, 'conversation_cancelled', variant);
      assert.equal(stored.provider_retirement?.envelope?.legacy_v121_cleanup, true, variant);
      assert.deepEqual(Object.keys(stored.provider_retirement.envelope).sort(), [
        'attempt_generation', 'deadline_at', 'generation', 'legacy_v121_cleanup',
        'pool_revision', 'question_id', 'runtime_revision', 'scope', 'session_key',
        'stage', 'version',
      ].sort(), variant);
      const retired = await f.process(accepted.key, accepted.jobId);
      assert.equal(retired.status, 'provider_retirement_retired', `${variant}: ${f.adapterErrors()}`);
      stored = pendingJob(f, event, accepted.jobId);
      assert.equal(stored.provider_retirement?.state, 'retired', variant);
      assert.equal(stored.inference, undefined, variant);
      assert.equal(stored.legacy_v121_pending_origin, undefined, variant);
      assert.equal(fs.existsSync(f.questionPath(accepted.jobId)), false, variant);
    }
    assert.equal(f.calls.filter((call) => call.phase === 'runtime').length, 0,
      '三种旧缓存清理均不得调用任何第三方模型');
    assert.equal(f.crispPostAttempts.length, 0,
      '人工接管后的旧缓存清理不得向访客发送任何正文');
    assert.equal(f.signedProviderPayloads.filter((entry) =>
      entry.path === '/internal/provider/retire').length, variants.length);
    assert.equal(f.sent.length, 0);
  });

  await test('精确时间回查确认输入已退役时只清理同一Provider结果且零重放', async (f) => {
    f.dropNextAdapterResponse();
    const event = f.event('event-time-input-retired');
    const first = await f.deliver(event);
    assert.equal(first.status, 'unresolved');
    assert.equal(f.calls.filter((call) => call.phase === 'runtime').length, 1);
    assert.equal(fs.existsSync(f.questionPath(first.jobId)), true);

    await f.mutateState(event.data.session_id, (state) => {
      const stored = state.jobs.find((entry) => entry.id === first.jobId);
      stored.event_time_unverified = true;
      delete stored.event_time_source;
      stored.retry_at = null;
      state.control_watermark = f.now() + 1;
    });

    const discarded = await f.process(first.key, first.jobId);
    assert.equal(discarded.status, 'discarded');
    let stored = pendingJob(f, event, first.jobId);
    assert.equal(stored.status, 'done');
    assert.equal(stored.responsibility_status, 'intentional_silence');
    assert.equal(stored.responsibility_reason, 'before_control_watermark');
    assert.equal(stored.provider_retirement?.state, 'pending');
    assert.equal(stored.provider_retirement?.purpose, 'input_retired');
    assert.equal(stored.data, undefined);
    assert.equal(f.calls.filter((call) => call.phase === 'runtime').length, 1,
      '时间分类不得重放或重新调用Provider');
    assert.equal(f.crispPostAttempts.length, 0);
    assert.equal(f.sent.length, 0);

    const retired = await f.process(first.key, first.jobId);
    assert.equal(retired.status, 'provider_retirement_retired', f.adapterErrors());
    stored = pendingJob(f, event, first.jobId);
    assert.equal(stored.provider_retirement?.state, 'retired');
    assert.equal(stored.provider_retirement?.purpose, 'input_retired');
    assert.equal(stored.inference, undefined);
    assert.equal(stored.provider_result_receipt, undefined);
    assert.equal(fs.existsSync(f.questionPath(first.jobId)), false);
    assert.equal(f.calls.filter((call) => call.phase === 'runtime').length, 1);
    assert.equal(f.crispPostAttempts.length, 0);
    assert.equal(f.sent.length, 0);
  });

  await test('failed但仍未解决的Provider责任遇真人接管时原子静默并只续做退休', async (f) => {
    f.dropNextAdapterResponse();
    const event = f.event('failed-responsibility-then-human');
    const first = await f.deliver(event);
    assert.equal(first.status, 'unresolved');
    await f.mutateState(event.data.session_id, (state) => {
      const stored = state.jobs.find((entry) => entry.id === first.jobId);
      stored.status = 'failed';
      stored.recovery_requires_review = true;
      stored.retry_at = null;
    });
    const operator = {
      website_id: event.website_id, event: 'message:received', timestamp: f.now() + 1,
      data: { session_id: event.data.session_id, from: 'operator', type: 'text',
        content: '受控人工已接管。', fingerprint: 900107, timestamp: f.now() + 1,
        automated: false },
    };
    assert.equal((await f.receive(operator)).accepted, true);
    let stored = pendingJob(f, event, first.jobId);
    assert.equal(stored.status, 'cancelled');
    assert.equal(stored.responsibility_status, 'intentional_silence');
    assert.equal(stored.responsibility_reason, 'human_reply');
    assert.equal(stored.provider_retirement?.purpose, 'conversation_cancelled');
    assert.equal(stored.provider_retirement?.state, 'pending');
    const retired = await f.process(first.key, first.jobId);
    assert.equal(retired.status, 'provider_retirement_retired', f.adapterErrors());
    stored = pendingJob(f, event, first.jobId);
    assert.equal(stored.provider_retirement?.state, 'retired');
    assert.equal(stored.inference, undefined);
    assert.equal(stored.provider_result_receipt, undefined);
    assert.equal(fs.existsSync(f.questionPath(first.jobId)), false);
    assert.equal(f.calls.filter((call) => call.phase === 'runtime').length, 1,
      'failed责任的人工取消不得重放或重新推理');
    assert.equal(f.crispPostAttempts.length, 0,
      'failed责任的人工取消不得向访客补发旧答案');
    assert.equal(f.sent.length, 0);
  });

  await test('failed但仍未解决的Provider责任跨总关代时原子静默并只续做退休', async (f) => {
    f.dropNextAdapterResponse();
    const event = f.event('failed-responsibility-then-global-off');
    const first = await f.deliver(event);
    assert.equal(first.status, 'unresolved');
    await f.mutateState(event.data.session_id, (state) => {
      const stored = state.jobs.find((entry) => entry.id === first.jobId);
      stored.status = 'failed';
      stored.recovery_requires_review = true;
      stored.retry_at = null;
    });
    f.publishRuntime(false);
    const retired = await f.process(first.key, first.jobId);
    assert.equal(retired.status, 'provider_retirement_retired', f.adapterErrors());
    const stored = pendingJob(f, event, first.jobId);
    assert.equal(stored.status, 'cancelled');
    assert.equal(stored.responsibility_status, 'intentional_silence');
    assert.equal(stored.responsibility_reason, 'global_disabled');
    assert.equal(stored.provider_retirement?.state, 'retired');
    assert.equal(stored.provider_retirement?.purpose, 'global_disabled');
    assert.equal(stored.inference, undefined);
    assert.equal(stored.provider_result_receipt, undefined);
    assert.equal(fs.existsSync(f.questionPath(first.jobId)), false);
    assert.equal(f.calls.filter((call) => call.phase === 'runtime').length, 1,
      'failed责任的总关取消不得重放或重新推理');
    assert.equal(f.crispPostAttempts.length, 0,
      '总关后不得向访客补发旧答案');
    assert.equal(f.sent.length, 0);
  });

  await test('Provider退休回程中断后保留精确责任，runtime重启后只续做清理', async (f) => {
    f.dropNextAdapterResponse();
    const event = f.event('retirement-transport-recovery');
    const first = await f.deliver(event);
    assert.equal(first.status, 'unresolved');
    const questionFile = f.questionPath(first.jobId);
    assert.equal(fs.existsSync(questionFile), true);
    const operator = {
      website_id: event.website_id, event: 'message:received', timestamp: f.now() + 1,
      data: { session_id: event.data.session_id, from: 'operator', type: 'text',
        content: '受控人工已接管。', fingerprint: 900102, timestamp: f.now() + 1,
        automated: false },
    };
    const received = await f.receive(operator);
    assert.equal(received.accepted, true);
    const controlSelected = await f.scan();
    assert.equal(controlSelected.some((entry) => entry.key === received.key
      && entry.jobId === received.jobId && entry.control === true), true,
    '真人控制任务必须先于 cleanup-only 退休任务完成后处理');
    assert.equal(controlSelected.some((entry) => entry.key === first.key
      && entry.jobId === first.jobId), false,
    '同一会话首轮扫描不得跳过真人控制而直接退休旧 Provider 缓存');
    const controlled = await f.process(received.key, received.jobId);
    assert.equal(controlled.status, 'none');
    const controlJob = f.state(event.data.session_id).jobs
      .find((entry) => entry.id === received.jobId);
    assert.equal(controlJob.status, 'done');
    assert.equal(controlJob.responsibility_status, 'control_handled');
    assertNoVisibleFailureReply(f);
    const retirementSelected = await f.scan();
    assert.equal(retirementSelected.some((entry) => entry.key === first.key
      && entry.jobId === first.jobId), true,
    '真人控制后处理完成后的下一轮必须选中到期的 cleanup-only 退休任务');
    f.failNextRetirementRequest();
    const interrupted = await f.process(first.key, first.jobId);
    assert.equal(interrupted.status, 'deferred');
    assert.equal(interrupted.reason, 'provider_retirement_deferred');
    let stored = pendingJob(f, event, first.jobId);
    assert.equal(stored.provider_retirement?.state, 'deferred');
    assert.equal(stored.provider_retirement?.attempts, 1);
    assert(stored.inference);assert(stored.provider_result_receipt);
    assert.equal(fs.existsSync(questionFile), true);
    const retryAt = stored.provider_retirement.next_action_at;
    f.restartRuntime();
    f.advance(Math.max(1, retryAt - f.now() + 1));
    const selected = await f.scan();
    assert.equal(selected.some((entry) => entry.key === first.key && entry.jobId === first.jobId), true);
    const recovered = await f.process(first.key, first.jobId);
    assert.equal(recovered.status, 'provider_retirement_retired', f.adapterErrors());
    stored = pendingJob(f, event, first.jobId);
    assert.equal(stored.provider_retirement?.state, 'retired');
    assert.equal(stored.provider_retirement?.attempts, 2);
    assert.equal(stored.inference, undefined);assert.equal(stored.provider_result_receipt, undefined);
    assert.equal(fs.existsSync(questionFile), false);
    assert.equal(f.calls.filter((call) => call.phase === 'runtime').length, 1,
      '退休传输恢复不得重新调用 Provider');
    assert.equal(f.sent.length, 0);
    assert.equal(f.signedProviderPayloads.filter((entry) => entry.path === '/internal/provider/retire').length, 2);
  });

  await test('router已退休但会话写回失败时，重启以 absent 幂等收敛且不重新推理', async (f) => {
    f.dropNextAdapterResponse();
    const event = f.event('retirement-local-writeback-recovery');
    const first = await f.deliver(event);
    assert.equal(first.status, 'unresolved');
    const questionFile = f.questionPath(first.jobId);
    const operator = {
      website_id: event.website_id, event: 'message:received', timestamp: f.now() + 1,
      data: { session_id: event.data.session_id, from: 'operator', type: 'text',
        content: '受控人工已接管。', fingerprint: 900103, timestamp: f.now() + 1,
        automated: false },
    };
    assert.equal((await f.receive(operator)).accepted, true);
    f.failNextRetirementWriteback();
    const interrupted = await f.process(first.key, first.jobId);
    assert.equal(interrupted.status, 'deferred');
    assert.equal(interrupted.reason, 'provider_retirement_owner_changed');
    assert.equal(f.retirementWritebackFailures(), 1,
      '夹具必须精确命中 router 删除后的会话原子写回');
    assert.equal(fs.existsSync(questionFile), false,
      'router 已删除缓存后本地失败不得伪装为远端未执行');
    let stored = pendingJob(f, event, first.jobId);
    assert.equal(stored.provider_retirement?.state, 'pending');
    assert(stored.provider_retirement?.lease_until > f.now());
    const leaseUntil = stored.provider_retirement.lease_until;
    f.restartRuntime();
    f.advance(Math.max(1, leaseUntil - f.now() + 1));
    const recovered = await f.process(first.key, first.jobId);
    assert.equal(recovered.status, 'provider_retirement_absent');
    stored = pendingJob(f, event, first.jobId);
    assert.equal(stored.provider_retirement?.state, 'absent');
    assert.equal(stored.provider_retirement?.attempts, 1);
    assert.equal(stored.inference, undefined);assert.equal(stored.provider_result_receipt, undefined);
    assert.equal(f.calls.filter((call) => call.phase === 'runtime').length, 1,
      '退休本地写回恢复不得重新调用 Provider');
    assert.equal(f.sent.length, 0);
    assert.equal(f.signedProviderPayloads.filter((entry) => entry.path === '/internal/provider/retire').length, 2);
  });

  await test('退休原因与业务终态不一致时本地拒绝，保留精确问题且不触达adapter', async (f) => {
    f.dropNextAdapterResponse();
    const event = f.event('retirement-purpose-authorization');
    const first = await f.deliver(event);
    assert.equal(first.status, 'unresolved');
    const questionFile = f.questionPath(first.jobId);
    const operator = {
      website_id: event.website_id, event: 'message:received', timestamp: f.now() + 1,
      data: { session_id: event.data.session_id, from: 'operator', type: 'text',
        content: '受控人工已接管。', fingerprint: 900104, timestamp: f.now() + 1,
        automated: false },
    };
    assert.equal((await f.receive(operator)).accepted, true);
    await f.mutateState(event.data.session_id, (state) => {
      const stored = state.jobs.find((entry) => entry.id === first.jobId);
      assert.equal(stored.provider_retirement?.purpose, 'conversation_cancelled');
      stored.provider_retirement.purpose = 'global_disabled';
      stored.provider_retirement.identity_sha256 = digest(canonical({
        envelope: stored.provider_retirement.envelope, purpose: 'global_disabled',
      }));
    });

    const rejected = await f.process(first.key, first.jobId);
    assert.equal(rejected.status, 'unresolved');
    assert.equal(rejected.reason, 'provider_retirement_identity_unresolved');
    const stored = pendingJob(f, event, first.jobId);
    assert.equal(stored.status, 'cancelled');
    assert.equal(stored.responsibility_status, 'intentional_silence');
    assert.equal(stored.responsibility_reason, 'human_reply');
    assert.equal(stored.provider_retirement?.state, 'invalid');
    assert.equal(stored.provider_retirement_failure_code,
      'provider_retirement_identity_unresolved');
    assert(stored.inference);assert(stored.provider_result_receipt);
    assert.equal(fs.existsSync(questionFile), true,
      '错误授权必须 fail closed，不能删除仍有精确身份的 Provider 问题');
    assert.equal(f.signedProviderPayloads.filter((entry) =>
      entry.path === '/internal/provider/retire').length, 0,
    '本地业务终态校验失败时不得发出签名退休请求');
    assert.equal(f.calls.filter((call) => call.phase === 'runtime').length, 1);
    assert.equal(f.sent.length, 0);
  });

  await test('adapter明确拒绝退休信封时停止重试并保留原问题供诊断恢复', async (f) => {
    f.dropNextAdapterResponse();
    const event = f.event('retirement-terminal-adapter-error');
    const first = await f.deliver(event);
    assert.equal(first.status, 'unresolved');
    const questionFile = f.questionPath(first.jobId);
    const operator = {
      website_id: event.website_id, event: 'message:received', timestamp: f.now() + 1,
      data: { session_id: event.data.session_id, from: 'operator', type: 'text',
        content: '受控人工已接管。', fingerprint: 900105, timestamp: f.now() + 1,
        automated: false },
    };
    assert.equal((await f.receive(operator)).accepted, true);
    f.queueRetirementAdapterResponse({ status: 400, headers: {},
      body: { error: { code: 'invalid_envelope' } } });

    const rejected = await f.process(first.key, first.jobId);
    assert.equal(rejected.status, 'unresolved');
    assert.equal(rejected.reason, 'provider_retirement_identity_unresolved');
    const stored = pendingJob(f, event, first.jobId);
    assert.equal(stored.provider_retirement?.state, 'invalid');
    assert.equal(stored.provider_retirement?.reason, 'retirement_invalid');
    assert.equal(stored.provider_retirement_failure_code,
      'provider_retirement_identity_unresolved');
    assert(stored.inference);assert(stored.provider_result_receipt);
    assert.equal(fs.existsSync(questionFile), true,
      'adapter拒绝签名时不得把未知问题当作已经退休');
    assert.equal(f.signedProviderPayloads.filter((entry) =>
      entry.path === '/internal/provider/retire').length, 1);
    assert.equal(f.calls.filter((call) => call.phase === 'runtime').length, 1);
    assert.equal(f.sent.length, 0);
    assert.equal((await f.process(first.key, first.jobId)).status, 'idle',
      '永久身份错误必须等待受控修复，不能在后台形成无界请求');
  });

  await test('旧非答案退休已远端执行时真人接管原子重绑原因并以 absent 收敛', async (f) => {
    f.dropNextAdapterResponse();
    const event = f.event('retirement-purpose-superseded');
    const first = await f.deliver(event);
    assert.equal(first.status, 'unresolved');
    const originalRequest = f.signedProviderPayloads.find((entry) =>
      entry.path === '/v1/chat/completions');
    assert(originalRequest);
    let oldIdentity = '';
    await f.mutateState(event.data.session_id, (state) => {
      const stored = state.jobs.find((entry) => entry.id === first.jobId);
      stored.provider_retirement = {
        schema_version: 1, state: 'pending', purpose: 'non_answer_retired',
        envelope: structuredClone(originalRequest.payload), identity_sha256: '',
        attempts: 0, first_recorded_at: f.now(), next_action_at: 0,
        lease_until: f.now() + 10000, lease_token: 'a'.repeat(24),
      };
      stored.provider_retirement.identity_sha256 = digest(canonical({
        envelope: stored.provider_retirement.envelope, purpose: 'non_answer_retired',
      }));
      oldIdentity = stored.provider_retirement.identity_sha256;
    });
    const remote = await f.postAdapter('/internal/provider/retire', originalRequest.token, {
      outcome: 'responsibility_retired', purpose: 'non_answer_retired',
    });
    assert.equal(remote.status, 200, JSON.stringify(remote.body));
    assert.equal(remote.body?.state, 'retired');
    assert.equal(fs.existsSync(f.questionPath(first.jobId)), false);

    const operator = {
      website_id: event.website_id, event: 'message:received', timestamp: f.now() + 1,
      data: { session_id: event.data.session_id, from: 'operator', type: 'text',
        content: '受控人工已接管。', fingerprint: 900106, timestamp: f.now() + 1,
        automated: false },
    };
    assert.equal((await f.receive(operator)).accepted, true);
    let stored = pendingJob(f, event, first.jobId);
    assert.equal(stored.status, 'cancelled');
    assert.equal(stored.responsibility_reason, 'human_reply');
    assert.equal(stored.provider_retirement?.state, 'pending');
    assert.equal(stored.provider_retirement?.purpose, 'conversation_cancelled');
    assert.notEqual(stored.provider_retirement?.identity_sha256, oldIdentity);
    assert.equal(stored.provider_retirement?.lease_token, undefined,
      '新业务终态必须取得新退休身份，不能等待旧在途租约');

    const converged = await f.process(first.key, first.jobId);
    assert.equal(converged.status, 'provider_retirement_absent');
    stored = pendingJob(f, event, first.jobId);
    assert.equal(stored.provider_retirement?.state, 'absent');
    assert.equal(stored.provider_retirement?.purpose, 'conversation_cancelled');
    assert.equal(stored.inference, undefined);assert.equal(stored.provider_result_receipt, undefined);
    assert.equal(f.calls.filter((call) => call.phase === 'runtime').length, 1);
    assert.equal(f.sent.length, 0);
    assert.equal(f.signedProviderPayloads.filter((entry) =>
      entry.path === '/internal/provider/retire').length, 2);
  });

  await test('旧退休HTTP响应迟到时不能覆盖真人接管后的新purpose与identity', async (f) => {
    f.dropNextAdapterResponse();
    const event = f.event('retirement-late-writeback-after-human');
    const first = await f.deliver(event);
    assert.equal(first.status, 'unresolved');
    const originalRequest = f.signedProviderPayloads.find((entry) =>
      entry.path === '/v1/chat/completions');
    assert(originalRequest);
    let oldIdentity = '';
    await f.mutateState(event.data.session_id, (state) => {
      const stored = state.jobs.find((entry) => entry.id === first.jobId);
      stored.provider_retirement = {
        schema_version: 1, state: 'pending', purpose: 'non_answer_retired',
        envelope: structuredClone(originalRequest.payload), identity_sha256: '',
        attempts: 0, first_recorded_at: f.now(), next_action_at: 0,
      };
      stored.provider_retirement.identity_sha256 = digest(canonical({
        envelope: stored.provider_retirement.envelope, purpose: 'non_answer_retired',
      }));
      oldIdentity = stored.provider_retirement.identity_sha256;
    });

    const gate = f.holdNextRetirementResponse();
    const staleProcess = f.process(first.key, first.jobId);
    await Promise.race([gate.arrived, wait(5000).then(() => {
      throw new Error('旧退休请求未在期限内取得受控HTTP响应');
    })]);
    assert.equal(fs.existsSync(f.questionPath(first.jobId)), false,
      '迟到写回前router应已精确删除旧Provider缓存');

    const operator = {
      website_id: event.website_id, event: 'message:received', timestamp: f.now() + 1,
      data: { session_id: event.data.session_id, from: 'operator', type: 'text',
        content: '受控人工已接管。', fingerprint: 900107, timestamp: f.now() + 1,
        automated: false },
    };
    assert.equal((await f.receive(operator)).accepted, true);
    let stored = pendingJob(f, event, first.jobId);
    const humanIdentity = stored.provider_retirement?.identity_sha256;
    assert.equal(stored.provider_retirement?.purpose, 'conversation_cancelled');
    assert.notEqual(humanIdentity, oldIdentity);
    assert.equal(stored.provider_retirement?.lease_token, undefined,
      'purpose重绑必须撤销旧在途lease');

    gate.release();
    const stale = await staleProcess;
    assert.equal(stale.status, 'deferred');
    assert.equal(stale.reason, 'provider_retirement_owner_changed');
    stored = pendingJob(f, event, first.jobId);
    assert.equal(stored.provider_retirement?.purpose, 'conversation_cancelled');
    assert.equal(stored.provider_retirement?.identity_sha256, humanIdentity,
      '旧HTTP响应不得覆盖真人接管后的新退休身份');
    assert.equal(stored.status, 'cancelled');
    assert.equal(stored.responsibility_status, 'intentional_silence');
    assert.equal(stored.responsibility_reason, 'human_reply');

    const converged = await f.process(first.key, first.jobId);
    assert.equal(converged.status, 'provider_retirement_absent');
    stored = pendingJob(f, event, first.jobId);
    assert.equal(stored.provider_retirement?.state, 'absent');
    assert.equal(stored.provider_retirement?.purpose, 'conversation_cancelled');
    assert.equal(stored.inference, undefined);
    assert.equal(stored.provider_result_receipt, undefined);
    assert.equal(f.calls.filter((call) => call.phase === 'runtime').length, 1,
      '迟到退休响应和真人接管均不得重新推理');
    assert.equal(f.crispPostAttempts.length, 0);
    assert.equal(f.sent.length, 0);
  });

  await test('旧非答案清理已完成后再遇人工只转换业务静默，不伪造第二次退休损坏', async (f) => {
    f.dropNextAdapterResponse();
    const event = f.event('finished-retirement-then-human');
    const first = await f.deliver(event);
    assert.equal(first.status, 'unresolved');
    const originalRequest = f.signedProviderPayloads.find((entry) =>
      entry.path === '/v1/chat/completions');
    assert(originalRequest);
    await f.mutateState(event.data.session_id, (state) => {
      const stored = state.jobs.find((entry) => entry.id === first.jobId);
      stored.status = 'received'; stored.responsibility_status = 'unresolved_failure';
      stored.retry_at = null; delete stored.plan;
      stored.provider_retirement = {
        schema_version: 1, state: 'pending', purpose: 'non_answer_retired',
        envelope: structuredClone(originalRequest.payload), identity_sha256: '',
        attempts: 0, first_recorded_at: f.now(), next_action_at: 0,
      };
      stored.provider_retirement.identity_sha256 = digest(canonical({
        envelope: stored.provider_retirement.envelope, purpose: 'non_answer_retired',
      }));
    });
    const retired = await f.process(first.key, first.jobId);
    assert.equal(retired.status, 'provider_retirement_retired', f.adapterErrors());
    let stored = pendingJob(f, event, first.jobId);
    assert.equal(stored.provider_retirement?.state, 'retired');
    assert.equal(stored.inference, undefined);assert.equal(stored.provider_result_receipt, undefined);
    assert.equal(fs.existsSync(f.questionPath(first.jobId)), false);

    const operator = {
      website_id: event.website_id, event: 'message:received', timestamp: f.now() + 1,
      data: { session_id: event.data.session_id, from: 'operator', type: 'text',
        content: '受控人工已接管。', fingerprint: 901100, timestamp: f.now() + 1,
        automated: false },
    };
    assert.equal((await f.receive(operator)).accepted, true);
    stored = pendingJob(f, event, first.jobId);
    assert.equal(stored.status, 'cancelled');
    assert.equal(stored.responsibility_status, 'intentional_silence');
    assert.equal(stored.responsibility_reason, 'human_reply');
    assert.equal(stored.provider_retirement, undefined,
      '远端缓存已清除时只需释放旧完成摘要，不得创建无身份的第二次退休');
    assert.equal(stored.provider_retirement_failure_code, undefined);
    assert.equal(f.signedProviderPayloads.filter((entry) =>
      entry.path === '/internal/provider/retire').length, 1);
    assert.equal(f.calls.filter((call) => call.phase === 'runtime').length, 1,
      '业务静默转换不得再次推理');
    assert.equal(f.crispPostAttempts.length, 0);
    assert.equal(f.sent.length, 0);
  });

  await test('已完成退休摘要与失败码并存时必须fail closed且不重新推理', async (f) => {
    const event = f.event('finished-retirement-with-failure-code');
    const accepted = await f.receive(event);
    assert.equal(accepted.accepted, true);
    const oldGeneric = '你最希望先解决哪一处？可以把具体情况、相关提示和已经尝试的方法一起告诉我。';
    const fingerprint = 901101;
    await f.mutateState(event.data.session_id, (state) => {
      const stored = state.jobs.find((entry) => entry.id === accepted.jobId);
      stored.status = 'done';
      stored.responsibility_status = 'answered_confirmed';
      stored.retry_at = null;
      stored.plan = { type: 'text', purpose: 'safe_error', ordinary: true,
        content: oldGeneric, fingerprint };
      stored.provider_retirement = {
        schema_version: 1, state: 'retired', purpose: 'non_answer_retired',
        attempts: 1, retired_at: f.now(), identity_sha256: 'f'.repeat(64),
      };
      stored.provider_retirement_failure_code = 'provider_retirement_identity_unresolved';
      state.outgoing[String(fingerprint)] = {
        job_id: stored.id, status: 'sent', purpose: 'safe_error', message_type: 'text',
        body: { type: 'text', content: oldGeneric }, created_at: f.now(), sent_at: f.now(),
        response_generation: 0,
      };
    });

    assert.equal((await f.process(accepted.key, accepted.jobId)).status, 'idle');
    const stored = pendingJob(f, event, accepted.jobId);
    assert.equal(stored.status, 'failed');
    assert.equal(stored.responsibility_status, 'unresolved_failure');
    assert.equal(stored.failure_code, 'legacy_non_answer_requires_review');
    assert.equal(stored.provider_retirement?.state, 'retired');
    assert.equal(stored.provider_retirement_failure_code,
      'provider_retirement_identity_unresolved');
    assert.equal(stored.data?.content, event.data.content,
      '损坏组合不得清除原始访客责任');
    assert.equal(f.calls.length, 0);
    assert.equal(f.signedProviderPayloads.length, 0);
    assert.equal(f.crispPostAttempts.length, 0);
    assert.equal(f.sent.length, 0);
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
    assert.equal(stored.inference, undefined);
    assert.equal(stored.provider_result_receipt, undefined);
    assert.equal(stored.provider_settlement?.state, 'settled');
    question = f.question(first.jobId);
    assert.equal(question.attempt_generation, 3);
    assert.equal(question.configuration_binding,
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

  await test('损坏的伪结算完成记录保留终态责任，只有完整完成记录到期后才允许清理', async (f) => {
    const event = f.event('settlement-retention');
    const first = await f.deliver(event);
    assert.equal(first.status, 'sent');
    let stored = pendingJob(f, event, first.jobId);
    assert.equal(stored.provider_settlement?.state, 'settled');
    const completed = structuredClone(stored.provider_settlement);

    await f.mutateState(event.data.session_id, (state) => {
      const job = state.jobs.find((entry) => entry.id === first.jobId);
      job.received_at = f.now() - 8 * 86400000;
      job.provider_settlement = { ...completed, settled_at: -1 };
    });
    await f.mutateState(event.data.session_id, () => {});
    stored = pendingJob(f, event, first.jobId);
    assert(stored, '损坏的完成记录不能让旧终态责任被保留期清理');
    assert.equal(stored.provider_settlement.settled_at, -1);

    await f.mutateState(event.data.session_id, (state) => {
      const job = state.jobs.find((entry) => entry.id === first.jobId);
      job.provider_settlement = { ...completed, settled_at: f.now() };
    });
    await f.mutateState(event.data.session_id, () => {});
    assert.equal(pendingJob(f, event, first.jobId), undefined,
      '完整结算记录在既有保留期外仍应按正常生命周期清理');
    assertSingleBusinessReply(f);
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

  await test('Crisp限流后接口池换代与runtime重启只重投已持久答案，不再次推理', async (f) => {
    const appliedA = await f.applyPrimary('a', 2);
    f.queueCrispPostResponse({ status: 429, headers: { 'retry-after': '1' },
      body: { error: true, reason: 'rate_limited' } });
    const event = f.event('frozen-delivery-after-rate-limit');
    const first = await f.deliver(event);
    assert.equal(first.status, 'rate_limited');
    assertNoVisibleFailureReply(f);

    let stored = pendingJob(f, event, first.jobId);
    assert.equal(stored.status, 'received');
    assert.equal(stored.responsibility_status, 'unresolved_failure');
    assert.equal(stored.failure_code, 'crisp_rate_limited');
    assert.equal(stored.plan?.content, '受控配置 A 的有效答案。');
    assert.equal(stored.provider_settlement?.state, 'settled');
    assert.equal(stored.provider_result_receipt, undefined);
    assert.equal(f.calls.filter((call) => call.phase === 'runtime').length, 1);
    assert.equal(f.crispPostAttempts.length, 1);
    assert.equal(f.sent.length, 0);
    const frozenPlan = structuredClone(stored.plan);
    const frozenAttempt = structuredClone(f.crispPostAttempts[0]);

    const appliedB = await f.applyPrimary('b', 3);
    assert.notEqual(appliedB.configuration.configuration_binding,
      appliedA.configuration.configuration_binding);
    f.restartRuntime();
    f.advance(Math.max(1, stored.retry_at - f.now() + 1));
    const recovered = await f.process(first.key, first.jobId);
    assert.equal(recovered.status, 'sent', f.adapterErrors());
    assert.equal(f.calls.filter((call) => call.phase === 'runtime').length, 1,
      'Crisp发送失败后的恢复不得调用新B配置重新生成答案');
    assert.equal(f.crispPostAttempts.length, 2);
    assert.deepEqual(f.crispPostAttempts[1], frozenAttempt,
      '恢复必须沿用同一会话、正文和fingerprint重投已持久答案');
    assertSingleBusinessReply(f, frozenPlan.content);

    stored = pendingJob(f, event, first.jobId);
    assert.equal(stored.status, 'done');
    assert.equal(stored.responsibility_status, 'answered_confirmed');
    assert.equal(stored.failure_code, undefined);
    assert.equal(stored.plan, undefined);
    assert.equal(stored.provider_settlement?.state, 'settled');
    assert.equal((await f.process(first.key, first.jobId)).status, 'idle');
    assert.equal(f.crispPostAttempts.length, 2);
    assert.equal(f.sent.length, 1);
  });

  for (const status of [400, 401, 413]) {
    await test(`Crisp明确拒绝${status}后跨接口换代与重启仍以同一正文自动恢复`, async (f) => {
      const appliedA = await f.applyPrimary('a', 2);
      f.queueCrispPostResponse({ status, headers: {},
        body: { error: true, reason: 'synthetic_rejection' } });
      const event = f.event(`frozen-delivery-after-${status}`);
      const first = await f.deliver(event);
      assert.equal(first.status, 'rejected');
      assertNoVisibleFailureReply(f);

      let stored = pendingJob(f, event, first.jobId);
      assert.equal(stored.status, 'received');
      assert.equal(stored.responsibility_status, 'unresolved_failure');
      assert.equal(stored.failure_code, `crisp_http_${status}`);
      assert.equal(stored.plan?.content, '受控配置 A 的有效答案。');
      assert.equal(stored.provider_settlement?.state, 'settled');
      assert.equal(f.calls.filter((call) => call.phase === 'runtime').length, 1);
      assert.equal(f.crispPostAttempts.length, 1);
      assert.equal(f.sent.length, 0);
      const frozenPlan = structuredClone(stored.plan);
      const frozenAttempt = structuredClone(f.crispPostAttempts[0]);
      const firstRetryAt = stored.retry_at;

      const appliedB = await f.applyPrimary('b', 3);
      assert.notEqual(appliedB.configuration.configuration_binding,
        appliedA.configuration.configuration_binding);
      f.restartRuntime();
      const beforeDue = await f.process(first.key, first.jobId);
      assert.equal(beforeDue.status, 'idle', '退避到期前不得绕过调度再次POST');
      assert.equal(f.calls.filter((call) => call.phase === 'runtime').length, 1);
      assert.equal(f.crispPostAttempts.length, 1);

      f.advance(Math.max(1, firstRetryAt - f.now() + 1));
      const recovered = await f.process(first.key, first.jobId);
      assert.equal(recovered.status, 'sent', f.adapterErrors());
      assert.equal(f.calls.filter((call) => call.phase === 'runtime').length, 1,
        'Crisp明确拒绝后的恢复不得调用新B配置重新生成答案');
      assert.equal(f.crispPostAttempts.length, 2);
      assert.deepEqual(f.crispPostAttempts[1], frozenAttempt,
        '恢复必须沿用同一会话、正文和fingerprint');
      assertSingleBusinessReply(f, frozenPlan.content);

      stored = pendingJob(f, event, first.jobId);
      assert.equal(stored.status, 'done');
      assert.equal(stored.responsibility_status, 'answered_confirmed');
      assert.equal(stored.failure_code, undefined);
      assert.equal(stored.plan, undefined);
      assert.equal((await f.process(first.key, first.jobId)).status, 'idle');
      assert.equal(f.crispPostAttempts.length, 2);
    });
  }

  await test('Crisp连续三次明确拒绝后仍保留同一答案并在外部恢复时自动投递', async (f) => {
    for (let index = 0; index < 3; index += 1) {
      f.queueCrispPostResponse({ status: 400, headers: {},
        body: { error: true, reason: 'synthetic_rejection' } });
    }
    const event = f.event('rejected-three-times-then-recover');
    const first = await f.deliver(event);
    assert.equal(first.status, 'rejected');
    const original = structuredClone(f.crispPostAttempts[0]);
    for (let attempt = 2; attempt <= 3; attempt += 1) {
      advancePastRetry(f, event, first.jobId);
      const rejected = await f.process(first.key, first.jobId);
      assert.equal(rejected.status, 'rejected');
      assert.equal(f.crispPostAttempts.length, attempt);
      assert.deepEqual(f.crispPostAttempts.at(-1), original);
      const stored = pendingJob(f, event, first.jobId);
      assert.equal(stored.status, 'received');
      assert.equal(stored.responsibility_status, 'unresolved_failure');
      assert.equal(stored.failure_code, 'crisp_http_400');
      const record = Object.values(f.state(event.data.session_id).outgoing)
        .find((entry) => entry?.job_id === first.jobId);
      assert.equal(record.attempts, attempt);
      assert.notEqual(record.resend_forbidden, true,
        '明确拒绝的第三次POST不能永久终结未回答责任');
    }
    advancePastRetry(f, event, first.jobId);
    const recovered = await f.process(first.key, first.jobId);
    assert.equal(recovered.status, 'sent');
    assert.equal(f.calls.filter((call) => call.phase === 'runtime').length, 1,
      'Crisp投递恢复不得再次调用Provider');
    assert.equal(f.crispPostAttempts.length, 4);
    assert.deepEqual(f.crispPostAttempts.at(-1), original);
    assertSingleBusinessReply(f);
    const stored = pendingJob(f, event, first.jobId);
    assert.equal(stored.status, 'done');
    assert.equal(stored.responsibility_status, 'answered_confirmed');
  });

  await test('Crisp明确拒绝等待期内真人接管会永久取消该会话正文且不再POST', async (f) => {
    f.queueCrispPostResponse({ status: 400, headers: {},
      body: { error: true, reason: 'synthetic_rejection' } });
    const event = f.event('rejected-then-human');
    const first = await f.deliver(event);
    assert.equal(first.status, 'rejected');
    assert.equal(f.crispPostAttempts.length, 1);
    const operator = {
      website_id: event.website_id, event: 'message:received', timestamp: f.now() + 1,
      data: { session_id: event.data.session_id, from: 'operator', type: 'text',
        content: '受控人工回复。', fingerprint: 900001, timestamp: f.now() + 1,
        automated: false },
    };
    const received = await f.receive(operator);
    assert.equal(received.accepted, true);
    let state = f.state(event.data.session_id);
    let stored = state.jobs.find((entry) => entry.id === first.jobId);
    assert.equal(state.mode, 'human');
    assert.equal(stored.status, 'cancelled');
    assert.equal(stored.responsibility_status, 'intentional_silence');
    const record = Object.values(state.outgoing).find((entry) => entry?.job_id === first.jobId);
    assert.equal(record.status, 'cancelled');
    assert.equal(record.resend_forbidden, true);
    assert.equal(record.body, undefined);
    f.advance(86400000);
    assert.equal((await f.process(first.key, first.jobId)).status, 'idle');
    assert.equal(f.crispPostAttempts.length, 1);
    assertNoVisibleFailureReply(f);
  });

  await test('Crisp明确拒绝等待期内客服总开关关闭会清除正文且不再POST', async (f) => {
    f.queueCrispPostResponse({ status: 401, headers: {},
      body: { error: true, reason: 'synthetic_rejection' } });
    const event = f.event('rejected-then-global-off');
    const first = await f.deliver(event);
    assert.equal(first.status, 'rejected');
    assert.equal(f.crispPostAttempts.length, 1);
    f.publishRuntime(false);
    const stopped = await f.process(first.key, first.jobId);
    assert.equal(stopped.status, 'idle');
    const state = f.state(event.data.session_id);
    const stored = state.jobs.find((entry) => entry.id === first.jobId);
    assert.equal(stored.status, 'cancelled');
    assert.equal(stored.responsibility_status, 'intentional_silence');
    assert.equal(stored.responsibility_reason, 'global_disabled');
    const record = Object.values(state.outgoing).find((entry) => entry?.job_id === first.jobId);
    assert.equal(record.status, 'cancelled');
    assert.equal(record.resend_forbidden, true);
    assert.equal(record.body, undefined);
    f.advance(86400000);
    assert.equal((await f.process(first.key, first.jobId)).status, 'idle');
    assert.equal(f.crispPostAttempts.length, 1);
    assertNoVisibleFailureReply(f);
  });

  for (const [name, slug, value] of [
    ['缺失', 'missing', undefined], ['字符串', 'string', 'soon'],
    ['负数', 'negative', -1], ['小数', 'fraction', 1.5],
  ]) {
    await test(`Crisp拒绝记录的next_action_at${name}时fail closed且保留答案责任`, async (f) => {
      f.queueCrispPostResponse({ status: 413, headers: {},
        body: { error: true, reason: 'synthetic_rejection' } });
      const event = f.event(`rejected-invalid-next-action-${slug}`);
      const first = await f.deliver(event);
      assert.equal(first.status, 'rejected');
      const callsBefore = f.calls.filter((call) => call.phase === 'runtime').length;
      const postsBefore = f.crispPostAttempts.length;
      await f.mutateState(event.data.session_id, (state) => {
        const job = state.jobs.find((entry) => entry.id === first.jobId);
        const record = Object.values(state.outgoing).find((entry) => entry?.job_id === first.jobId);
        assert(job && record);
        job.retry_at = 0;
        if (value === undefined) delete record.next_action_at;
        else record.next_action_at = value;
      });
      const unresolved = await f.process(first.key, first.jobId);
      assert.equal(unresolved.status, 'delivery_identity_unresolved');
      assert.equal(f.calls.filter((call) => call.phase === 'runtime').length, callsBefore);
      assert.equal(f.crispPostAttempts.length, postsBefore);
      assertNoVisibleFailureReply(f);
      const stored = pendingJob(f, event, first.jobId);
      assert.equal(stored.status, 'received');
      assert.equal(stored.responsibility_status, 'unresolved_failure');
      assert.equal(stored.failure_code, 'delivery_identity_unresolved');
      assert.equal(stored.plan?.content, '受控正常答案。');
      const record = Object.values(f.state(event.data.session_id).outgoing)
        .find((entry) => entry?.job_id === first.jobId);
      assert.equal(record.body?.content, '受控正常答案。');
    });
  }

  for (const variant of [
    { name: '缺少待恢复标记', slug: 'missing-recovery', mutate: (record) => {
      delete record.recovery_deferred;
    } },
    { name: '待恢复标记类型错误', slug: 'invalid-recovery', mutate: (record) => {
      record.recovery_deferred = 'true';
    } },
    { name: '尝试次数为零', slug: 'zero-attempts', mutate: (record) => {
      record.attempts = 0;
    } },
    { name: '拒绝原因不受支持', slug: 'invalid-failure', mutate: (record) => {
      record.failure = 'crisp_http_unknown';
    } },
  ]) {
    await test(`Crisp拒绝记录${variant.name}时fail closed且不重新推理或发送`, async (f) => {
      f.queueCrispPostResponse({ status: 400, headers: {},
        body: { error: true, reason: 'synthetic_rejection' } });
      const event = f.event(`rejected-invalid-${variant.slug}`);
      const first = await f.deliver(event);
      assert.equal(first.status, 'rejected');
      const callsBefore = f.calls.filter((call) => call.phase === 'runtime').length;
      const postsBefore = f.crispPostAttempts.length;
      await f.mutateState(event.data.session_id, (state) => {
        const job = state.jobs.find((entry) => entry.id === first.jobId);
        const record = Object.values(state.outgoing).find((entry) => entry?.job_id === first.jobId);
        assert(job && record);
        job.retry_at = 0;
        variant.mutate(record);
      });
      const unresolved = await f.process(first.key, first.jobId);
      assert.equal(unresolved.status, 'delivery_identity_unresolved');
      assert.equal(f.calls.filter((call) => call.phase === 'runtime').length, callsBefore);
      assert.equal(f.crispPostAttempts.length, postsBefore);
      assertNoVisibleFailureReply(f);
      const stored = pendingJob(f, event, first.jobId);
      assert.equal(stored.status, 'received');
      assert.equal(stored.responsibility_status, 'unresolved_failure');
      assert.equal(stored.failure_code, 'delivery_identity_unresolved');
      assert.equal(stored.plan?.content, '受控正常答案。');
      const record = Object.values(f.state(event.data.session_id).outgoing)
        .find((entry) => entry?.job_id === first.jobId);
      assert.equal(record.body?.content, '受控正常答案。');
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
    job.inference_generation = 1;
    job.inference = { ...f.providerConfiguration, deadline_at: deadlineAt,
      attempt_generation: 1, provider_receipt_protocol_version: 1 };
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
    assert.equal(stored.inference, undefined);
    assert.equal(stored.provider_result_receipt, undefined);
    assert.equal(stored.provider_settlement?.state, 'settled');
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
    const firstConvergence = await f.process(first.key, first.jobId);
    assert.equal(firstConvergence.status, 'unresolved');
    assert.deepEqual(f.calls.map((call) => call.index), [0, 1],
      '第一代收敛只能 replay 并确认没有缓存结果');
    stored = pendingJob(f, event, first.jobId);
    assert.equal(stored.failure_code, 'question_result_absent');
    assert.equal(stored.inference, undefined);
    assertNoVisibleFailureReply(f);

    advancePastRetry(f, event, first.jobId);
    const second = await f.process(first.key, first.jobId);
    assert.equal(second.status, 'unresolved');
    assert.deepEqual(f.calls.map((call) => call.index), [0, 1, 0, 1],
      '第二恢复轮仍只能按 max_attempts=2 调用两个候选');
    stored = pendingJob(f, event, first.jobId);
    question = f.question(first.jobId);
    assert.equal(stored.inference_generation, 2);
    assert.equal(stored.inference?.attempt_generation, 2,
      '第二次模糊失败同样必须先保留本代信封等待只读收敛');
    assert.equal(stored.provider_result_receipt?.state, 'unknown');
    assert.equal(Number(stored.response_generation || 0), 0);
    assert.deepEqual([question.attempt_generation, question.round_attempts, question.attempts], [2, 2, 4]);
    assert.equal(question.deadline > firstDeadline, true);
    assertNoVisibleFailureReply(f);

    f.setBehavior('normal');
    advancePastRetry(f, event, first.jobId);
    // 第二轮失败把接口冷却提升到两秒；等真实冷却到期，不改持久业务时钟语义。
    await wait(2200);
    const secondConvergence = await f.process(first.key, first.jobId);
    assert.equal(secondConvergence.status, 'unresolved');
    assert.deepEqual(f.calls.map((call) => call.index), [0, 1, 0, 1],
      '第二代收敛仍只能 replay，累计调用数不得增加');
    stored = pendingJob(f, event, first.jobId);
    assert.equal(stored.failure_code, 'question_result_absent');
    assert.equal(stored.inference, undefined);
    assertNoVisibleFailureReply(f);

    advancePastRetry(f, event, first.jobId);
    const recovered = await f.process(first.key, first.jobId);
    assert.equal(recovered.status, 'sent');
    stored = pendingJob(f, event, first.jobId);
    question = f.question(first.jobId);
    assert.equal(stored.id, first.jobId);
    assert.equal(stored.inference_generation, 3);
    assert.equal(stored.inference, undefined);
    assert.equal(stored.provider_result_receipt, undefined);
    assert.equal(stored.provider_settlement?.state, 'settled');
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
