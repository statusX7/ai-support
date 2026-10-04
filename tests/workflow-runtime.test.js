'use strict';

const assert = require('assert/strict');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const vm = require('vm');
const { createRuntime } = require('../n8n/runtime');
const { verifyEnvelope, requestContract } = require('../scripts/provider-envelope');
const { chatToResponses, responseToChat, validChat } = require('../scripts/provider-adapter');
const project = path.resolve(__dirname, '..');
fs.mkdirSync(path.join(project, '.work', 'v1.3.0'), { recursive: true });
const root = fs.mkdtempSync(path.join(project, '.work', 'v1.3.0', 'runtime-test-'));
fs.mkdirSync(path.join(root, 'config'), { recursive: true });
fs.mkdirSync(path.join(root, 'data', 'runtime'), { recursive: true });
for (const name of ['keyword', 'handoff', 'menu', 'tags', 'feedback', 'provider']) fs.copyFileSync(path.join(project, 'config', name + '.yaml.example'), path.join(root, 'config', name + '.yaml'));
fs.writeFileSync(path.join(root, 'config', 'prompt.md'), '中文提示词 $ # " \\ 😀\n优先知识，不编造。');
const writeConfig = (name, data) => fs.writeFileSync(path.join(root, 'config', name + '.yaml'), JSON.stringify(data));
const readConfig = (name) => JSON.parse(fs.readFileSync(path.join(root, 'config', name + '.yaml'), 'utf8'));
writeConfig('runtime', { schema_version: 2, enabled: true, revision: 1, applied_revision: 1 });
writeConfig('provider', { provider: { base_url: 'https://provider.invalid/proxy/v1', model: 'controlled-model', api_mode: 'chat_completions', supports_vision: true } });
const welcomeOff = readConfig('menu'); welcomeOff.welcome.enabled = false; writeConfig('menu', welcomeOff);
const env = { CRISP_WEBSITE_ID: '11111111-1111-4111-8111-111111111111', CRISP_WEBSITE_HOOK_SECRET: 'test-only-website-secret-0001', CRISP_PLUGIN_SIGNING_SECRET: 'test-only-plugin-secret-0001', CRISP_AUTH_B64: 'test-only-auth', CRISP_TOKEN_TIER: 'website', AI_API_KEY: 'test-only-key', AI_SUPPORTS_VISION: 'true', ANYTHINGLLM_WORKSPACE: 'crisp-support', ANYTHINGLLM_API_KEY: 'test-only-anything-key', PROVIDER_ADAPTER_KEY: 'test-only-provider-adapter-key-0001', PROVIDER_POOL_REQUIRED: 'true', PROVIDER_POOL_READBACK_REQUIRED: 'true', PROVIDER_ADAPTER_URL: 'https://provider.invalid/proxy/v1' };
const fixtureStartedAt = Date.now();
const projection = 'kb_1111111111111111_doc_2222222222222222.md';
fs.writeFileSync(path.join(root, 'data/runtime/knowledge-map.json'), JSON.stringify({ schema_version: 2, documents: [{
  library_id: 'kb_1111111111111111', document_id: 'doc_2222222222222222', projection,
  location: 'custom-documents/' + projection + '-33333333-3333-4333-8333-333333333333.json',
}] }));
const canonical = value => Array.isArray(value) ? '[' + value.map(canonical).join(',') + ']'
  : value && typeof value === 'object' ? '{' + Object.keys(value).sort().map(key => JSON.stringify(key) + ':' + canonical(value[key])).join(',') + '}'
    : JSON.stringify(value);
const digest = value => crypto.createHash('sha256').update(value).digest('hex');
const writeJson = (file, value) => fs.writeFileSync(file, JSON.stringify(value), { mode: 0o600 });
const atomicWriteJson = (file, value) => {
  fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  const temporary = file + '.candidate-' + crypto.randomBytes(8).toString('hex');
  try {
    fs.writeFileSync(temporary, JSON.stringify(value), { mode: 0o600 });
    fs.renameSync(temporary, file);
  } finally {
    try { fs.unlinkSync(temporary); } catch (error) { if (error.code !== 'ENOENT') throw error; }
  }
};
const materialsKnowledge = () => {
  const mapFile = path.join(root, 'data/runtime/knowledge-map.json');
  const mapRaw = fs.readFileSync(mapFile);
  const map = JSON.parse(mapRaw);
  const settingsFile = path.join(root, 'data/runtime/knowledge-settings.json');
  const settings = { schema_version: 1, workspace_slug: env.ANYTHINGLLM_WORKSPACE, temperature: 0.7, observed_at: fixtureStartedAt };
  writeJson(settingsFile, settings);
  const profileValue = { engine: 'native', model: 'synthetic-embedding', chunk_size: 1000, chunk_overlap: 20,
    passage_prefix: '', query_prefix: '', component_version: 'synthetic' };
  const profileFile = path.join(root, 'data/runtime/knowledge-profile.json');
  writeJson(profileFile, { schema_version: 1, state: 'applied', profile: profileValue,
    fingerprint: digest(canonical(profileValue)), applied_at: fixtureStartedAt });
  const payload = { schema_version: 2, algorithm: 'crispai-lexical-v2', map_sha256: digest(mapRaw), complete: false,
    coverage: { source_documents: map.documents.length, indexed_documents: 0, omitted_documents: map.documents.length,
      source_bytes: map.documents.length, indexed_bytes: 0, omitted_bytes: map.documents.length,
      reasons: map.documents.length ? ['index_capacity'] : [] }, passages: [] };
  const lexicalFile = path.join(root, 'data/runtime/knowledge-lexical.json');
  writeJson(lexicalFile, { ...payload, payload_sha256: digest(canonical(payload)) });
  const enabledLibraries = [...new Set(map.documents.map(item => item.library_id))].sort();
  return {
    catalog_revision: 1,
    catalog_sha256: digest(canonical({ fixture: 'catalog', documents: map.documents })),
    manifest_sha256: digest(canonical({ fixture: 'manifest', locations: map.documents.map(item => item.location) })),
    map_sha256: digest(mapRaw),
    settings_sha256: digest(fs.readFileSync(settingsFile)),
    profile_sha256: digest(fs.readFileSync(profileFile)),
    lexical_sha256: digest(fs.readFileSync(lexicalFile)),
    enabled_library_ids: enabledLibraries,
    library_count: enabledLibraries.length,
    document_count: map.documents.length,
    enabled_document_count: map.documents.length,
  };
};
const sealMaterials = value => {
  const runtime = { ...value.configuration.runtime };
  delete runtime.revision;
  delete runtime.applied_revision;
  value.source_components = {
    runtime: digest(canonical(runtime)), handoff: digest(canonical(value.configuration.handoff)),
    keyword: digest(canonical(value.configuration.keyword)), menu: digest(canonical(value.configuration.menu)),
    tags: digest(canonical(value.configuration.tags)), feedback: digest(canonical(value.configuration.feedback)),
    prompt: value.prompt.sha256, knowledge: digest(canonical(value.knowledge)),
  };
  value.source_sha256 = digest(canonical(value.source_components));
  return value;
};
const makeMaterials = (configuration, prompt, revision) => sealMaterials({
  schema_version: 2, revision, state: 'applied', applied_at: fixtureStartedAt + revision, source_sha256: '', source_components: {},
  configuration, prompt: { text: prompt, sha256: digest(prompt), bytes: Buffer.byteLength(prompt) },
  knowledge: materialsKnowledge(),
});
const materialsPath = path.join(root, 'config/materials-applied.json');
const assertReplyReadyMaterials = (materials) => {
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
  assert.equal(typeof materials.configuration.runtime.enabled, 'boolean');
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
  assert.equal(settings.workspace_slug, env.ANYTHINGLLM_WORKSPACE);
  assert.equal(typeof settings.temperature, 'number');
  assert.equal(profile.schema_version, 1);
  assert.equal(profile.state, 'applied');
  assert.equal(profile.fingerprint, digest(canonical(profile.profile)));
  assert.equal(lexical.schema_version, 2);
  assert.equal(lexical.map_sha256, digest(mapRaw));
  const { payload_sha256, ...lexicalPayload } = lexical;
  assert.equal(payload_sha256, digest(canonical(lexicalPayload)));
  const runtimeConfiguration = structuredClone(materials.configuration.runtime);
  delete runtimeConfiguration.revision;
  delete runtimeConfiguration.applied_revision;
  assert.deepEqual(materials.source_components, {
    runtime: digest(canonical(runtimeConfiguration)),
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
const managedConfiguration = () => Object.fromEntries(
  ['runtime', 'handoff', 'keyword', 'menu', 'tags', 'feedback']
    .map((name) => [name, readConfig(name)]));
const initialMaterials = makeMaterials(managedConfiguration(),
  fs.readFileSync(path.join(root, 'config/prompt.md'), 'utf8'), 1);
atomicWriteJson(materialsPath, initialMaterials);
assertReplyReadyMaterials(JSON.parse(fs.readFileSync(materialsPath, 'utf8')));
assert.equal(initialMaterials.configuration.runtime.enabled, true);
const publishConfiguration = (name, value) => {
  assert(['runtime', 'handoff', 'keyword', 'menu', 'tags', 'feedback'].includes(name));
  const previous = JSON.parse(fs.readFileSync(materialsPath, 'utf8'));
  const revision = previous.revision + 1;
  const configuration = structuredClone(previous.configuration);
  const next = structuredClone(value);
  if (name === 'runtime') {
    const crossed = previous.configuration.runtime.enabled === true && next.enabled === false;
    next.disable_epoch = Math.min(2147483647,
      Number(previous.configuration.runtime.disable_epoch || 0) + (crossed ? 1 : 0));
    next.revision = revision;
    next.applied_revision = revision;
    configuration.runtime = next;
  } else {
    configuration[name] = next;
    configuration.runtime = { ...configuration.runtime, revision, applied_revision: revision };
  }
  writeConfig(name, next);
  writeConfig('runtime', configuration.runtime);
  const applied = makeMaterials(configuration, previous.prompt.text, revision);
  atomicWriteJson(materialsPath, applied);
  assertReplyReadyMaterials(JSON.parse(fs.readFileSync(materialsPath, 'utf8')));
  return applied;
};
const providerPoolPath = path.join(root, 'config/provider-pool-applied.json');
const providerReadbackPath = path.join(root, 'config/provider-pool-readback.json');
const providerEntryId = 'p_111111111111111111111111';
const publishProviderPool = (apiMode, revision = 1) => {
  assert(['chat_completions', 'responses'].includes(apiMode));
  const generation = digest('workflow-provider-secrets-' + revision).slice(0, 32);
  const pool = {
    schema_version: 1, revision, secrets_generation: generation, primary_id: providerEntryId,
    entries: [{ id: providerEntryId, name: '受控主接口', role: 'primary', order: 0, enabled: true,
      base_url: 'https://provider.invalid/proxy/v1', model: 'controlled-model', api_mode: apiMode,
      custom_header_names: [], capabilities: { chat_completions: apiMode === 'chat_completions',
        responses: apiMode === 'responses', vision: true }, context_window: 8192,
      max_output_tokens: 1200, draft: false }],
    policy: { question_timeout_ms: 7000, call_timeout_ms: 1500, connect_timeout_ms: 100,
      max_attempts: 1, cooldown_initial_ms: 1000, cooldown_max_ms: 2000,
      pool_cooldown_ms: 100 },
  };
  const secretPath = path.join(root, 'secrets/provider/generations', generation + '.json');
  atomicWriteJson(secretPath, { schema_version: 1, generation, revision,
    entries: { [providerEntryId]: { api_key: env.AI_API_KEY, custom_headers: {} } } });
  atomicWriteJson(providerPoolPath, pool);
  const poolSha256 = digest(fs.readFileSync(providerPoolPath));
  atomicWriteJson(providerReadbackPath, { schema_version: 1, readback_contract_version: 1,
    revision, secrets_generation: generation, pool_sha256: poolSha256,
    verified_at: fixtureStartedAt + revision });
  const readback = JSON.parse(fs.readFileSync(providerReadbackPath, 'utf8'));
  assert.equal(readback.revision, pool.revision);
  assert.equal(readback.secrets_generation, pool.secrets_generation);
  assert.equal(readback.pool_sha256, poolSha256);
  const rawProvider = readConfig('provider');
  rawProvider.provider.api_mode = apiMode;
  rawProvider.provider.model = pool.entries[0].model;
  rawProvider.provider.base_url = pool.entries[0].base_url;
  writeConfig('provider', rawProvider);
  return { pool, readback };
};
publishProviderPool('chat_completions');
const messagesOf = body => body.messages || body.input;
const textOf = message => typeof message.content === 'string' ? message.content
  : message.content.filter(part => ['text', 'input_text', 'output_text'].includes(part.type)).map(part => part.text).join('\n');
const textOfRequest = body => messagesOf(body).map(textOf).join('\n');
let now = fixtureStartedAt;
let sequence = 1000;
let delayed;
let delayedAll;
let modelFailure = false;
let tagFailure = false;
let crispFailure = false;
let unknownSend = false;
let sendRejection = 0;
let sendAttempts = 0;
let delayedCrisp;
let ignoreCrispAbort = false;
let unknownSources = false;
let miss = false;
let low = false;
let imageMode = 'valid';
let visualAnswer = '受控视觉协议回答';
let modelAnswerOverride = null;
let delayedVision;
let delayedControlLookups;
let abortSignalProbe;
let m13RetrievalGate;
const sent = [];
const histories = new Map();
const modelRequests = [];
const providerRequests = [];
const retrievalRequests = [];
const segments = new Map();
let runtime;
const wait = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));
const awaitNamedGate = async (promise, label, timeout = 5000) => {
  let timer;
  try {
    await Promise.race([promise, new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error('等待' + label + '超过本地截止时间')), timeout);
    })]);
  } finally {
    if (timer) clearTimeout(timer);
  }
};
const request = async (url, options = {}) => {
  const parsed = new URL(url);
  const match = parsed.pathname.match(/\/conversation\/([^/]+)(\/.*)$/);
  if (match) {
    const session = decodeURIComponent(match[1]);
    const suffix = match[2];
    const history = histories.get(session) || [];
    if (crispFailure) return { status: 403, body: { error: true } };
    if (suffix === '/messages') return { status: 200, body: { error: false, data: history } };
    if (suffix.startsWith('/message/')) {
      if (delayedControlLookups) await delayedControlLookups;
      return { status: 200, body: { error: false, data: history.find((message) => String(message.fingerprint) === suffix.slice(9)) || {} } };
    }
    if (suffix === '/meta' && options.method === 'GET') return { status: tagFailure ? 403 : 200, body: { error: tagFailure, data: { segments: segments.get(session) || ['external-vip'] } } };
    if (suffix === '/meta' && options.method === 'PATCH') { segments.set(session, options.body.segments); return { status: 200, body: { error: false } }; }
    if (suffix === '/message') {
      const body = options.body;
      sendAttempts += 1;
      if (abortSignalProbe) abortSignalProbe(options.signal);
      if (sendRejection) return { status: sendRejection, body: { error: true, reason: 'invalid_data' } };
      // 重现实机发现的拒绝：本项目旧版自定义 properties 键不满足 Crisp 的校验。
      // 不模拟完整第三方 schema；本项目使用官方昵称字段和本地持久 fingerprint。
      if (body.properties && ('ai_support' in body.properties || 'ai_support_version' in body.properties)) {
        return { status: 400, body: { error: true, reason: 'invalid_data' } };
      }
      if (delayedCrisp) {
        const pending = delayedCrisp;
        delayedCrisp = null;
        if (ignoreCrispAbort) await pending;
        else await new Promise((resolve, reject) => {
          const abort = () => {
            const error = new Error('受控出站已取消');
            error.name = 'AbortError';
            error.code = 'ABORT_ERR';
            reject(error);
          };
          if (options.signal?.aborted) { abort(); return; }
          options.signal?.addEventListener('abort', abort, { once: true });
          pending.then(resolve, reject).finally(() => options.signal?.removeEventListener('abort', abort));
        });
      }
      sent.push({ ...body, session_id: session });
      history.push({ ...body, timestamp: now }); histories.set(session, history);
      await runtime.receive({ query: { key: env.CRISP_WEBSITE_HOOK_SECRET }, body: { website_id: env.CRISP_WEBSITE_ID, event: 'message:received', data: { ...body, automated: undefined, properties: undefined, session_id: session }, timestamp: now } });
      if (unknownSend) { unknownSend = false; throw new Error('受控发送超时'); }
      return { status: 200, body: { error: false, reason: 'dispatched', data: { fingerprint: body.fingerprint } } };
    }
    throw new Error('未知 Crisp 测试路径：' + suffix);
  }
  if (parsed.hostname === 'anythingllm') {
    assert.equal(options.headers.Authorization, 'Bearer ' + env.ANYTHINGLLM_API_KEY);
    const workspacePath = '/api/v1/workspace/' + env.ANYTHINGLLM_WORKSPACE;
    if (parsed.pathname === workspacePath) {
      assert.equal(options.method, 'GET'); assert.equal(options.body, undefined);
      return { status: 200, body: { workspace: [{ slug: env.ANYTHINGLLM_WORKSPACE, openAiTemp: null }] } };
    }
    assert.equal(parsed.pathname, workspacePath + '/vector-search'); assert.equal(options.method, 'POST');
    assert.deepEqual(Object.keys(options.body), ['query']);
    retrievalRequests.push(structuredClone(options.body));
    if (m13RetrievalGate?.queries.has(options.body.query)) {
      const gate = m13RetrievalGate;
      gate.entered.add(options.body.query);
      if (gate.entered.size === gate.queries.size) gate.resolveEntered();
      await gate.release;
      return { status: 503, body: { error: true } };
    }
    return { status: 200, body: { results: miss ? [] : [{ id: 'synthetic-workflow-chunk', text: '问题：设置如何保存？\n回答：在设置页保存后重试。',
      ...(unknownSources ? {} : { metadata: { title: projection } }), distance: low ? 0.9 : 0.1, score: low ? 0.1 : 0.9 }] } };
  }
  if (parsed.hostname === 'provider.invalid') {
    assert.equal(options.method, 'POST');
    assert.equal(options.headers.Authorization, 'Bearer ' + env.PROVIDER_ADAPTER_KEY);
    const envelope = verifyEnvelope(options.headers['x-crispai-question'], env.PROVIDER_ADAPTER_KEY);
    if (parsed.pathname === '/proxy/internal/provider/settle') {
      assert.equal(options.body.outcome, 'plan_persisted');
      assert.match(options.body.plan_sha256, /^[a-f0-9]{64}$/);
      return { status: 200, body: { state: 'settled' } };
    }
    if (parsed.pathname === '/proxy/internal/provider/retire') {
      assert.equal(options.body.outcome, 'responsibility_retired');
      return { status: 200, body: { state: 'absent' } };
    }
    const poolRaw = fs.readFileSync(providerPoolPath);
    const pool = JSON.parse(poolRaw);
    const materials = JSON.parse(fs.readFileSync(materialsPath, 'utf8'));
    assert.equal(envelope.runtime_revision, materials.revision);
    assert.equal(envelope.pool_revision, pool.revision);
    assert.equal(envelope.secrets_generation, pool.secrets_generation);
    assert.equal(envelope.pool_sha256, digest(poolRaw));
    assert.equal(envelope.materials_source_sha256, materials.source_sha256);
    assert.equal(envelope.configuration_binding, digest(JSON.stringify([
      envelope.runtime_revision, envelope.pool_revision, envelope.secrets_generation,
      envelope.pool_sha256, envelope.materials_source_sha256,
    ])));
    if (parsed.pathname === '/proxy/internal/provider/replay') {
      return { status: 409, body: { error: { code: 'question_result_absent' } } };
    }
    assert.equal(parsed.pathname, '/proxy/v1/chat/completions');
    assert.equal(requestContract(options.body).request_sha256, envelope.request_sha256,
      'adapter 输入正文必须与受管问题信封绑定');
    const entry = pool.entries.find((item) => item.id === pool.primary_id);
    assert(entry && entry.enabled && entry.draft === false);
    const upstreamBody = entry.api_mode === 'responses'
      ? chatToResponses(options.body, { model: entry.model, maxOutput: entry.max_output_tokens })
      : { model: entry.model, messages: options.body.messages, stream: false,
        max_tokens: entry.max_output_tokens,
        ...(options.body.temperature !== undefined ? { temperature: options.body.temperature } : {}),
        ...(options.body.top_p !== undefined ? { top_p: options.body.top_p } : {}) };
    const upstreamPath = new URL(entry.base_url).pathname.replace(/\/$/, '')
      + (entry.api_mode === 'responses' ? '/responses' : '/chat/completions');
    const hasImage = messagesOf(upstreamBody).some(message => Array.isArray(message.content)
      && message.content.some(part => ['image_url', 'input_image'].includes(part.type)));
    let answer;
    if (hasImage) {
      providerRequests.push({ path: upstreamPath, body: structuredClone(upstreamBody) });
      if (delayedVision) { const pending = delayedVision; delayedVision = null; await pending; }
      answer = visualAnswer;
    } else {
      modelRequests.push(structuredClone(upstreamBody));
      assert.equal(upstreamBody.temperature, 0.7);
      if (delayedAll) await delayedAll;
      if (delayed) { const pending = delayed; delayed = null; await pending; }
      if (modelFailure) return { status: 503, body: { error: { code: 'upstream_unavailable' } } };
      answer = modelAnswerOverride ?? '受控协议回答：' + textOf(messagesOf(upstreamBody).at(-1)).slice(-25);
    }
    const upstreamResult = entry.api_mode === 'responses'
      ? { status: 'completed', output: [{ type: 'message', role: 'assistant',
        content: [{ type: 'output_text', text: answer }] }] }
      : { choices: [{ message: { role: 'assistant', content: answer } }] };
    return { status: 200, body: entry.api_mode === 'responses'
      ? responseToChat(upstreamResult, entry.model) : validChat(upstreamResult, entry.model) };
  }
  if (parsed.hostname === 'storage.crisp.chat') {
    const png = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=', 'base64');
    if (imageMode === 'huge') { png.writeUInt32BE(40000, 16); png.writeUInt32BE(40000, 20); }
    return { status: imageMode === 'expired' ? 404 : 200, headers: { 'content-type': 'image/png' }, body: imageMode === 'wrong' ? Buffer.from('not an image') : png };
  }
  throw new Error('未知受控地址');
};
const runtimeOptions = { root, clock: () => now, request, lookup: (_host, _options, callback) => callback(null, [{ address: '8.8.8.8', family: 4 }]) };
runtime = createRuntime(env, runtimeOptions);
const message = (session, content, overrides = {}) => ({ website_id: env.CRISP_WEBSITE_ID, event: 'message:send', timestamp: now, data: { session_id: session, from: 'user', type: 'text', content, fingerprint: ++sequence, timestamp: now, ...overrides } });
const receive = async (body) => {
  if (body.event === 'message:send' && ['text', 'file', 'animation'].includes(body.data.type)) {
    const history = histories.get(body.data.session_id) || []; history.push({ ...body.data }); histories.set(body.data.session_id, history);
  }
  return runtime.receive({ body, query: { key: env.CRISP_WEBSITE_HOOK_SECRET } });
};
const deliver = async (body) => { const entry = await receive(body); if (entry.route === 'process') return runtime.process(entry.key, entry.jobId); return entry; };
const state = (session) => runtime.readState(runtime.stateKey(env.CRISP_WEBSITE_ID, session));
const key = (session) => runtime.stateKey(env.CRISP_WEBSITE_ID, session);
const assertUnresolved = (session, result, code) => {
  assert.equal(result.status, 'unresolved');
  const job = state(session).jobs.find((item) => item.id === result.jobId); assert(job);
  assert.equal(job.status, 'received'); assert.equal(job.responsibility_status, 'unresolved_failure');
  assert.equal(job.failure_code, code); assert(Number.isFinite(job.retry_at)); return job;
};
const recoverUnresolved = async (session, result) => {
  await runtime.transaction(result.key, (current) => {
    const job = current.jobs.find((item) => item.id === result.jobId); assert(job); job.retry_at = 0;
  });
  const before = sent.filter((item) => item.session_id === session).length;
  let recovered = await runtime.process(result.key, result.jobId);
  if (recovered.status === 'unresolved') {
    const replayed = state(session).jobs.find((item) => item.id === result.jobId);
    assert(replayed, '同一应答责任必须保留');
    assert.equal(replayed.responsibility_status, 'unresolved_failure');
    assert.equal(replayed.inference, undefined,
      'adapter 明确返回 absent 后才可释放旧推理代');
    assert.equal(replayed.provider_result_receipt, undefined);
    assert.equal(sent.filter((item) => item.session_id === session).length, before,
      '只读 replay 收敛轮不得产生可见出站');
    await runtime.transaction(result.key, (current) => {
      const job = current.jobs.find((item) => item.id === result.jobId); assert(job); job.retry_at = 0;
    });
    recovered = await runtime.process(result.key, result.jobId);
  }
  assert.equal(recovered.status, 'sent');
  assert.equal(sent.filter((item) => item.session_id === session).length, before + 1);
  assert.equal(state(session).jobs.find((item) => item.id === result.jobId).responsibility_status, 'answered_confirmed');
};
const click = (session, card, index = 0, event = 'message:updated') => ({ website_id: env.CRISP_WEBSITE_ID, event, timestamp: now, data: { session_id: session, fingerprint: card.fingerprint, ...(event === 'message:send' ? { type: 'picker', from: 'user' } : {}), content: { ...card.content, choices: card.content.choices.map((choice, at) => ({ ...choice, selected: at === index })) } } });
const operator = async (session, overrides = {}) => {
  const body = { ...message(session, '真人公开处理进度', { from: 'operator', automated: false, ...overrides }), event: 'message:received' };
  const history = histories.get(session) || []; history.push(body.data); histories.set(session, history);
  return deliver(body);
};
let passed = 0;
const test = async (name, action) => { await action(); passed += 1; process.stdout.write('通过 UNIT/CONTRACT ' + name + '\n'); };
const waitForPermitSlot = async (slot) => {
  const target = path.join(root, 'data/runtime/ordinary-processing-permits', 'slot-' + slot);
  for (let attempt = 0; attempt < 200; attempt += 1) {
    if (fs.existsSync(path.join(target, 'owner.json'))) return target;
    await wait(5);
  }
  throw new Error('未在期限内观察到后台任务许可 slot-' + slot);
};
const replacePermitOwner = (slot, kind) => {
  const permitRoot = path.join(root, 'data/runtime/ordinary-processing-permits');
  const slotPath = path.join(permitRoot, 'slot-' + slot);
  const quarantine = path.join(permitRoot, '.stale-slot-' + slot + '-' + crypto.randomBytes(16).toString('hex'));
  fs.renameSync(slotPath, quarantine);
  fs.mkdirSync(slotPath, { mode: 0o700 });
  const token = crypto.randomBytes(16).toString('hex');
  const at = Date.now();
  fs.writeFileSync(path.join(slotPath, 'owner.json'), JSON.stringify({ schema_version: 1, slot, token, kind,
    acquired_at: at, expires_at: at + 60000 }), { mode: 0o600 });
  fs.writeFileSync(path.join(slotPath, 'heartbeat.json'), JSON.stringify({ schema_version: 1, token }), { mode: 0o600 });
  const remove = (directory) => {
    try {
      const stat = fs.lstatSync(directory);
      if (!stat.isDirectory() || stat.isSymbolicLink()) throw new Error('测试许可目录异常');
      for (const name of fs.readdirSync(directory)) {
        if (!['owner.json', 'heartbeat.json'].includes(name)) throw new Error('测试许可成员异常');
        fs.unlinkSync(path.join(directory, name));
      }
      fs.rmdirSync(directory);
    } catch (error) { if (error.code !== 'ENOENT') throw error; }
  };
  return { token, slotPath, quarantine, cleanup() { remove(slotPath); remove(quarantine); } };
};
const abortablePending = (signal, started) => {
  started();
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('许可丢失未在期限内中止网络请求')), 1500);
    const abort = () => {
      clearTimeout(timer);
      reject(signal?.reason || Object.assign(new Error('请求已取消'), { name: 'AbortError', code: 'ABORT_ERR' }));
    };
    if (signal?.aborted) { abort(); return; }
    signal?.addEventListener('abort', abort, { once: true });
  });
};

(async () => {
  await test('M13 多个繁忙失败会话不阻止普通小流量沿同一责任完成唯一回答', async () => {
    const permitRoot = path.join(root, 'data/runtime/ordinary-processing-permits');
    const busyQueries = Array.from({ length: 7 }, (_, index) => 'M13 繁忙队列受控问题 ' + index);
    const busySessions = busyQueries.map((_, index) => 'session_m13-busy-' + index);
    const smallQuery = 'M13 小流量受控问题';
    const smallSession = 'session_m13-small';
    const baseline = { models: modelRequests.length, posts: sendAttempts, sent: sent.length };
    const pending = [];
    const track = (promise) => {
      pending.push(promise);
      promise.catch(() => {});
      return promise;
    };
    let resolveEntered;
    let resolveRelease;
    let released = false;
    const entered = new Promise((resolve) => { resolveEntered = resolve; });
    const release = new Promise((resolve) => { resolveRelease = resolve; });
    const releaseBusy = () => {
      if (released) return;
      released = true;
      resolveRelease();
    };
    const bounded = async (promise, label, timeout = 10000) => {
      let timer;
      try {
        return await Promise.race([promise, new Promise((_, reject) => {
          timer = setTimeout(() => reject(new Error('等待' + label + '超过本地截止时间')), timeout);
        })]);
      } finally {
        if (timer) clearTimeout(timer);
      }
    };
    const permitCount = () => fs.existsSync(permitRoot)
      ? fs.readdirSync(permitRoot).filter((name) => /^slot-[0-6]$/.test(name)).length : 0;
    const modelCallsFor = (question) => modelRequests.filter((body) =>
      textOf(messagesOf(body).at(-1)) === question).length;
    const jobFor = (session, jobId) => state(session).jobs.find((job) => job.id === jobId);
    let busyEntries = [];
    try {
      m13RetrievalGate = {
        queries: new Set(busyQueries), entered: new Set(), resolveEntered, release,
      };
      for (let index = 0; index < busySessions.length; index += 1) {
        busyEntries.push(await bounded(track(receive(message(busySessions[index], busyQueries[index]))),
          'M13 繁忙问题持久接收-' + index));
        assert.equal(busyEntries.at(-1).route, 'process');
      }
      const workers = Array.from({ length: 7 }, () => createRuntime(env, runtimeOptions));
      const firstBusyProcesses = busyEntries.map((entry, index) =>
        track(workers[index].process(entry.key, entry.jobId)));
      await bounded(entered, 'M13 七个繁忙任务进入向量门');
      assert.equal(m13RetrievalGate.entered.size, 7);
      assert.equal(permitCount(), 7, '七个繁忙会话必须真实占满普通处理许可');

      const smallEntry = await bounded(track(receive(message(smallSession, smallQuery))), 'M13 小流量持久接收');
      assert.equal(smallEntry.route, 'process');
      const firstSelection = await bounded(track(runtime.scan()), 'M13 小流量首次扫描');
      assert.equal(firstSelection.length, 1, '繁忙任务 processing 时扫描只能选择小流量责任');
      assert.deepEqual(firstSelection[0], { key: smallEntry.key, jobId: smallEntry.jobId, control: false });
      const smallBeforeCapacity = jobFor(smallSession, smallEntry.jobId); assert(smallBeforeCapacity);
      const capacityAttempts = smallBeforeCapacity.attempts;
      const capacityResult = await bounded(track(
        runtime.process(firstSelection[0].key, firstSelection[0].jobId)), 'M13 小流量容量延期');
      assert.deepEqual(capacityResult, { status: 'deferred', reason: 'processing_capacity' });
      const capacityJob = jobFor(smallSession, smallEntry.jobId); assert(capacityJob);
      assert.equal(capacityJob.status, 'received');
      assert.equal(capacityJob.responsibility_status, 'pending');
      assert.equal(capacityJob.attempts, capacityAttempts, '容量延期不得冒充一次业务尝试');
      assert.equal(capacityJob.retry_at, now + 1000);
      assert.equal(capacityJob.lease_until, 0);
      assert(capacityJob.data, '容量延期必须保留同一访客责任');
      assert.equal(state(smallSession).worker, null);
      assert.equal(modelRequests.length, baseline.models);
      assert.equal(sendAttempts, baseline.posts);
      assert.equal(sent.length, baseline.sent);

      releaseBusy();
      const firstBusyResults = await bounded(Promise.all(firstBusyProcesses), 'M13 繁忙任务失败收口');
      assert(firstBusyResults.every((result) => result.status === 'unresolved'));
      m13RetrievalGate = null;
      for (let index = 0; index < busyEntries.length; index += 1) {
        const busyJob = jobFor(busySessions[index], busyEntries[index].jobId); assert(busyJob);
        assert.equal(busyJob.status, 'received');
        assert.equal(busyJob.responsibility_status, 'unresolved_failure');
        assert.equal(busyJob.failure_code, 'retrieval_error');
        assert(busyJob.retry_at > now);
        assert(busyJob.data, '繁忙会话技术失败后必须保留原始应答责任');
        assert.equal(state(busySessions[index]).worker, null);
        assert.equal(Object.values(state(busySessions[index]).outgoing)
          .filter((record) => record.job_id === busyEntries[index].jobId).length, 0);
        assert.equal(modelCallsFor(busyQueries[index]), 0);
        assert.equal(sent.filter((entry) => entry.session_id === busySessions[index]).length, 0);
      }
      assert.equal(permitCount(), 0, '繁忙任务技术失败后必须释放全部普通处理许可');

      const smallRetryAt = jobFor(smallSession, smallEntry.jobId).retry_at;
      assert(Number.isFinite(smallRetryAt) && smallRetryAt > now);
      assert.equal(Object.hasOwn(jobFor(smallSession, smallEntry.jobId), 'plan'), false,
        '恢复前执行快照尚无 plan；首次成功回执必须使用随后持久的权威 plan');
      now = smallRetryAt;
      const secondSelection = await bounded(track(runtime.scan()), 'M13 小流量恢复扫描');
      assert.equal(secondSelection.length, 1);
      assert.deepEqual(secondSelection[0], { key: smallEntry.key, jobId: smallEntry.jobId, control: false },
        '必须消费 scanner 返回的同一小流量责任，不能绕过公平调度直接调用已知身份');
      const smallResult = await bounded(track(
        runtime.process(secondSelection[0].key, secondSelection[0].jobId)), 'M13 小流量完成回答');
      assert.equal(smallResult.status, 'sent');
      const completedSmall = jobFor(smallSession, smallEntry.jobId); assert(completedSmall);
      assert.equal(completedSmall.status, 'done');
      assert.equal(completedSmall.responsibility_status, 'answered_confirmed');
      assert.equal(completedSmall.delivery_receipt_unknown, undefined,
        '正常首次回执不得被误标为身份未解决');
      const smallOutgoing = Object.values(state(smallSession).outgoing)
        .filter((record) => record.job_id === smallEntry.jobId);
      assert.equal(smallOutgoing.length, 1);
      assert.equal(smallOutgoing[0].status, 'sent');
      assert.equal(modelCallsFor(smallQuery), 1);
      assert.equal(modelRequests.length, baseline.models + 1);
      assert.equal(sendAttempts, baseline.posts + 1, '小流量恢复阶段必须只有一次 Crisp POST');
      assert.equal(sent.filter((entry) => entry.session_id === smallSession).length, 1);
      assert.equal(sent.length, baseline.sent + 1);
      for (let index = 0; index < busyEntries.length; index += 1) {
        const busyJob = jobFor(busySessions[index], busyEntries[index].jobId); assert(busyJob);
        assert.equal(busyJob.status, 'received');
        assert.equal(busyJob.responsibility_status, 'unresolved_failure');
        assert.equal(sent.filter((entry) => entry.session_id === busySessions[index]).length, 0);
      }

      const busyRetryAt = Math.max(...busyEntries.map((entry, index) => {
        const retryAt = jobFor(busySessions[index], entry.jobId)?.retry_at;
        assert(Number.isFinite(retryAt));
        return retryAt;
      }));
      now = Math.max(now, busyRetryAt);
      const thirdSelection = await bounded(track(runtime.scan()), 'M13 繁忙责任恢复扫描');
      assert.equal(thirdSelection.length, 7);
      assert.deepEqual(thirdSelection.map((entry) => entry.jobId).sort(),
        busyEntries.map((entry) => entry.jobId).sort(),
        '繁忙责任必须通过生产 scanner 自然恢复，不能手工改写 retry 或终态');
      const recoveredProcesses = thirdSelection.map((entry) =>
        track(runtime.process(entry.key, entry.jobId)));
      const recoveredResults = await bounded(Promise.all(recoveredProcesses), 'M13 繁忙责任最终回答');
      assert(recoveredResults.every((result) => result.status === 'sent'));
      for (let index = 0; index < busyEntries.length; index += 1) {
        const busyJob = jobFor(busySessions[index], busyEntries[index].jobId); assert(busyJob);
        assert.equal(busyJob.status, 'done');
        assert.equal(busyJob.responsibility_status, 'answered_confirmed');
        const outgoing = Object.values(state(busySessions[index]).outgoing)
          .filter((record) => record.job_id === busyEntries[index].jobId);
        assert.equal(outgoing.length, 1);
        assert.equal(outgoing[0].status, 'sent');
        assert.equal(modelCallsFor(busyQueries[index]), 1);
        assert.equal(sent.filter((entry) => entry.session_id === busySessions[index]).length, 1);
      }
      assert.equal(sendAttempts, baseline.posts + 8);
      assert.equal(modelRequests.length, baseline.models + 8);
      assert.equal(sent.length, baseline.sent + 8);
      assert.deepEqual(await bounded(track(runtime.scan()), 'M13 最终空扫描'), []);
      assert.equal(permitCount(), 0, '全部责任完成后不得残留普通处理许可');
    } finally {
      releaseBusy();
      try {
        await bounded(Promise.allSettled(pending), 'M13 已启动任务清理');
      } finally {
        m13RetrievalGate = null;
      }
    }
  });
  await test('鉴权模式、网站、时间窗和不安全会话', async () => {
    assert.equal((await runtime.receive({ body: message('session_auth0001', '测试'), query: { key: 'wrong' } })).statusCode, 401);
    assert.equal((await receive({ ...message('session_auth0001', '测试'), website_id: 'wrong' })).statusCode, 403);
    assert.equal((await receive(message('../escape', '测试'))).statusCode, 400);
    const body = message('session_plugin001', '测试'); const raw = JSON.stringify(body); const time = String(now);
    const signature = crypto.createHmac('sha256', env.CRISP_PLUGIN_SIGNING_SECRET).update('[' + time + ';' + raw + ']').digest('hex');
    const plugin = createRuntime({ ...env, CRISP_HOOK_MODE: 'plugin' }, runtimeOptions);
    const input = { body, headers: { 'X-Crisp-Signature': signature, 'X-Crisp-Request-Timestamp': time }, query: {} };
    assert.equal((await plugin.receive(input, { data: { data: Buffer.from(raw).toString('base64') } })).accepted, true);
    assert.equal((await plugin.receive({ body, query: { key: env.CRISP_WEBSITE_HOOK_SECRET } })).statusCode, 401);
    input.headers['X-Crisp-Request-Timestamp'] = String(now - 400000);
    assert.equal((await plugin.receive(input, { data: { data: Buffer.from(raw).toString('base64') } })).statusCode, 401);
  });
  await test('P0 Code sandbox 缺少原生 AbortController 时普通回复及人工中止仍有效', async () => {
    const nativeAbortController = globalThis.AbortController;
    try {
      globalThis.AbortController = undefined;
      runtime = createRuntime(env, runtimeOptions);
      const normalSession = 'session_abort-fallback-normal';
      const beforeNormal = sent.length;
      let normalSignal;
      const normalEvents = [];
      const removed = () => normalEvents.push('removed');
      abortSignalProbe = (signal) => {
        normalSignal = signal;
        signal.onabort = () => { normalEvents.push('onabort'); throw new Error('受控 onabort 异常'); };
        signal.addEventListener('abort', removed);
        signal.removeEventListener('abort', removed);
        signal.addEventListener('abort', () => { normalEvents.push('throwing'); throw new Error('受控监听器异常'); });
        signal.addEventListener('abort', () => normalEvents.push('survivor'), { once: true });
      };
      assert.equal((await deliver(message(normalSession, '缺少原生控制器时的普通问题'))).status, 'sent');
      assert.equal(sent.length, beforeNormal + 1);
      assert.equal(sent.at(-1).session_id, normalSession);
      assert.equal(normalSignal.aborted, false, '正常完成不应伪造取消');
      assert.equal(normalSignal.reason, undefined);
      assert.deepEqual(normalEvents, [], '正常完成不应通知 abort 监听器');

      let release;
      delayedCrisp = new Promise((resolve) => { release = resolve; });
      const interruptedSession = 'session_abort-fallback-human';
      const attempts = sendAttempts;
      const beforeInterrupted = sent.filter((entry) => entry.session_id === interruptedSession).length;
      const interruptedEvents = [];
      const removedInterrupted = () => interruptedEvents.push('removed');
      abortSignalProbe = (signal) => {
        signal.onabort = () => { interruptedEvents.push('onabort'); throw new Error('受控 onabort 异常'); };
        signal.addEventListener('abort', () => { interruptedEvents.push('throwing'); throw new Error('受控首监听器异常'); });
        signal.addEventListener('abort', () => interruptedEvents.push('survivor'), { once: true });
        signal.addEventListener('abort', removedInterrupted);
        signal.removeEventListener('abort', removedInterrupted);
      };
      const entry = await receive(message(interruptedSession, '人工介入前的挂起回复'));
      const pending = runtime.process(entry.key, entry.jobId);
      for (let tries = 0; tries < 200 && sendAttempts === attempts; tries += 1) await wait(5);
      assert.equal(sendAttempts, attempts + 1, 'fallback signal 必须真实进入挂起的 Crisp POST');
      now += 1;
      const controlRuntime = createRuntime(env, runtimeOptions);
      const human = { ...message(interruptedSession, '真人介入', { from: 'operator', automated: false }), event: 'message:received' };
      const history = histories.get(interruptedSession) || []; history.push(human.data); histories.set(interruptedSession, history);
      const accepted = await controlRuntime.receive({ body: human, query: { key: env.CRISP_WEBSITE_HOOK_SECRET } });
      if (accepted.route === 'process') await controlRuntime.process(accepted.key, accepted.jobId);
      const wasCancelled = () => Object.values(state(interruptedSession).outgoing || {})
        .some((record) => record.cancellation_reason === 'conversation_state_changed');
      for (let tries = 0; tries < 100 && (!wasCancelled() || !interruptedEvents.includes('survivor')); tries += 1) await wait(10);
      assert.equal(wasCancelled(), true, '持久人工状态必须触发 fallback signal 的 abort 监听器');
      assert(interruptedEvents.includes('survivor'), '原 worker 仍存活时必须继续收到持久状态触发的网络取消');
      await operator(interruptedSession, { content: '重复真人事件不得重复触发 abort' });
      const result = await pending;
      release();
      assert.equal(result.status, 'cancelled');
      assert.equal(state(interruptedSession).mode, 'human');
      assert.equal(sent.filter((item) => item.session_id === interruptedSession).length, beforeInterrupted);
      assert.equal(state(interruptedSession).jobs.find((job) => job.id === entry.jobId).status, 'cancelled');
      assert.deepEqual(interruptedEvents, ['onabort', 'throwing', 'survivor'],
        '重复取消只能通知一次，onabort/监听器异常不能阻断后续监听器和网络取消');
    } finally {
      globalThis.AbortController = nativeAbortController;
      runtime = createRuntime(env, runtimeOptions);
      delayedCrisp = null;
      abortSignalProbe = undefined;
    }
  });
  const deferredOperatorCase = async (suffix, resolved, advance = 5) => {
    const session = 'session_deferred-' + suffix;
    const operatorFingerprint = ++sequence;
    const ambiguous = {
      website_id: env.CRISP_WEBSITE_ID, event: 'message:received', timestamp: now,
      data: { session_id: session, from: 'operator', type: 'text', content: '受控 operator 事件',
        fingerprint: operatorFingerprint, timestamp: now, user: { type: 'website', nickname: '受控来源' } },
    };
    const control = await receive(ambiguous);
    assert.equal(control.route, 'process');
    now += advance;
    const visitor = await receive(message(session, 'operator 归属确认期间的新问题'));
    assert.equal(visitor.route, 'ignore', '未决控制期间访客任务只持久化，不应立即抢跑');
    const visitorJob = () => state(session).jobs.find((job) => job.id === visitor.jobId);
    assert.equal(visitorJob().status, 'received');
    assert.equal(visitorJob().deferred_control, true);
    histories.set(session, [{ ...ambiguous.data, ...resolved }, ...(histories.get(session) || [])]);
    return { session, control, visitor, visitorJob };
  };
  const processingOperatorBarrierCase = async (suffix, resolvedAsHuman) => {
    const session = 'session_processing-operator-' + suffix;
    const parallelSession = 'session_processing-operator-parallel-' + suffix;
    const modelCount = modelRequests.length;
    const postCount = sendAttempts;
    const visibleCount = sent.filter((entry) => entry.session_id === session).length;
    let targetJobId = '';
    let releaseSettlement;
    let settlementReleased = false;
    let settlementEnteredResolve;
    let settlementAbortedResolve;
    let settlementSignal;
    let settlementEnvelope;
    let heldSettlements = 0;
    let running;
    let runningSettled = false;
    const settlementEntered = new Promise((resolve) => { settlementEnteredResolve = resolve; });
    const settlementAborted = new Promise((resolve) => { settlementAbortedResolve = resolve; });
    const settlementRelease = new Promise((resolve) => { releaseSettlement = resolve; });
    const releaseSettlementGate = () => {
      if (settlementReleased) return;
      settlementReleased = true;
      releaseSettlement();
    };
    const boundedResult = async (promise, label, timeout = 5000) => {
      let value;
      await awaitNamedGate(Promise.resolve(promise).then((result) => { value = result; }), label, timeout);
      return value;
    };
    const gatedRequest = async (url, options = {}) => {
      const parsed = new URL(url);
      if (parsed.pathname === '/proxy/internal/provider/settle' && heldSettlements === 0) {
        heldSettlements += 1;
        settlementEnvelope = verifyEnvelope(options.headers['x-crispai-question'], env.PROVIDER_ADAPTER_KEY);
        settlementSignal = options.signal;
        const observeAbort = () => settlementAbortedResolve();
        if (settlementSignal?.aborted) observeAbort();
        else settlementSignal?.addEventListener('abort', observeAbort, { once: true });
        settlementEnteredResolve();
        let timer;
        try {
          await Promise.race([settlementRelease, new Promise((_, reject) => {
            timer = setTimeout(() => reject(new Error('等待释放受控 Provider 结算门超过本地截止时间')), 10000);
          })]);
        } finally {
          if (timer) clearTimeout(timer);
          settlementSignal?.removeEventListener('abort', observeAbort);
        }
      }
      return request(url, options);
    };

    try {
      runtime = createRuntime(env, { ...runtimeOptions, request: gatedRequest });
      const visitor = await receive(message(session, '未确认 operator 屏障前的普通问题'));
      targetJobId = visitor.jobId;
      running = runtime.process(visitor.key, visitor.jobId).then((result) => {
        runningSettled = true;
        return result;
      }, (error) => {
        runningSettled = true;
        throw error;
      });
      await awaitNamedGate(settlementEntered, '普通问题进入 Provider 结算网络门');
      assert.equal(heldSettlements, 1);
      assert.equal(settlementEnvelope.question_id, targetJobId,
        '受控结算门必须绑定当前普通访客责任');
      const beforeBarrier = state(session);
      const claimed = beforeBarrier.jobs.find((job) => job.id === visitor.jobId); assert(claimed);
      assert.equal(claimed.status, 'processing');
      assert.equal(claimed.attempts, 1);
      assert(claimed.data && claimed.plan && claimed.inference && claimed.provider_result_receipt
        && claimed.provider_settlement, '屏障测试必须在答案和推理回执均已持久后挂起');
      assert.equal(claimed.provider_result_receipt.state, 'available');
      assert.equal(claimed.provider_settlement.state, 'pending');
      assert.equal(modelRequests.length, modelCount + 1);
      assert.equal(sent.filter((entry) => entry.session_id === session).length, visibleCount);
      const frozen = Object.fromEntries(['data', 'plan', 'inference', 'provider_result_receipt',
        'provider_settlement'].map((name) => [name, structuredClone(claimed[name])]));

      now += 1;
      const operatorFingerprint = ++sequence;
      const ambiguousData = {
        session_id: session, from: 'operator', type: 'text', content: '待确认归属的公开 operator 事件',
        fingerprint: operatorFingerprint, timestamp: now,
        user: { type: 'website', nickname: '受控待确认来源' },
      };
      const control = await receive({ website_id: env.CRISP_WEBSITE_ID,
        event: 'message:received', timestamp: now, data: ambiguousData });
      assert.equal(control.route, 'process');
      assert(state(session).uncertain_events.includes(control.jobId),
        '未确认 operator 必须先建立持久屏障');
      await awaitNamedGate(settlementAborted, '未确认 operator 屏障中止普通处理网络');
      assert.equal(settlementSignal.aborted, true);
      releaseSettlementGate();
      const interrupted = await boundedResult(running, '屏障中止后的普通处理收敛');

      const afterBarrier = state(session);
      const preserved = afterBarrier.jobs.find((job) => job.id === visitor.jobId); assert(preserved);
      assert.equal(preserved.status, 'received',
        '未确认 operator 屏障只能延后同一责任；不得压成 conversation_state_changed 后终态取消并删除 data');
      assert(preserved.deferred_control === true || afterBarrier.uncertain_events.includes(control.jobId),
        '未确认 operator 必须以 deferred_control 或等价持久屏障保留原责任');
      assert.notEqual(preserved.responsibility_status, 'intentional_silence');
      assert.equal(preserved.attempts, 1);
      assert.equal(afterBarrier.worker, null);
      for (const name of Object.keys(frozen)) {
        assert.deepEqual(preserved[name], frozen[name], '屏障中止不得改写已持久的 ' + name);
      }
      assert.equal(interrupted.status, 'deferred');
      assert.equal(typeof interrupted.reason, 'string');
      assert.notEqual(interrupted.reason, 'conversation_state_changed',
        '未确认屏障不得被压成已确认会话状态变化');
      assert.equal(modelRequests.length, modelCount + 1);
      assert.equal(sendAttempts, postCount);

      histories.set(session, [{ ...ambiguousData, automated: !resolvedAsHuman },
        ...(histories.get(session) || [])]);
      const controlResult = await boundedResult(runtime.process(control.key, control.jobId),
        'operator 归属控制任务完成');
      assert(!['failed', 'unresolved'].includes(controlResult.status));
      const resolvedState = state(session);
      const resolvedControl = resolvedState.jobs.find((job) => job.id === control.jobId); assert(resolvedControl);
      assert.equal(resolvedControl.operator_resolution.result, resolvedAsHuman ? 'human' : 'not-human');
      assert.equal(resolvedControl.responsibility_status, 'control_handled');

      if (!resolvedAsHuman) {
        const ready = resolvedState.jobs.find((job) => job.id === visitor.jobId); assert(ready);
        assert.equal(resolvedState.mode, 'ai');
        assert.equal(ready.status, 'received');
        assert.equal(ready.deferred_control, undefined);
        assert.deepEqual(ready.plan, frozen.plan);
        assert.deepEqual(ready.inference, frozen.inference);
        assert.deepEqual(ready.provider_result_receipt, frozen.provider_result_receipt);
        assert.deepEqual(ready.provider_settlement, frozen.provider_settlement);
        let recovered = await boundedResult(runtime.process(visitor.key, visitor.jobId),
          'not-human 后恢复原普通问题第一步');
        if (['provider_settlement_settled', 'provider_settlement_absent'].includes(recovered.status)) {
          assert.equal(sendAttempts, postCount,
            '独立 Provider 结算收敛步骤不得提前 POST Crisp');
          assert.equal(modelRequests.length, modelCount + 1,
            '独立 Provider 结算收敛步骤不得重新推理');
          recovered = await boundedResult(runtime.process(visitor.key, visitor.jobId),
            'not-human 后恢复原普通问题第二步');
        }
        assert.equal(recovered.status, 'sent');
        const completed = state(session).jobs.find((job) => job.id === visitor.jobId); assert(completed);
        assert.equal(completed.status, 'done');
        assert.equal(completed.responsibility_status, 'answered_confirmed');
        assert.equal(modelRequests.length, modelCount + 1,
          'not-human 恢复必须复用已持久答案，不能重新推理');
        assert.equal(sendAttempts, postCount + 1);
        assert.equal(sent.filter((entry) => entry.session_id === session).length, visibleCount + 1);
        assert.equal((await boundedResult(runtime.process(visitor.key, visitor.jobId),
          'not-human 恢复后的重复 process')).status, 'idle');
        assert.equal(sendAttempts, postCount + 1, '重复 process 不得再次 POST 同一答案');
      } else {
        const cancelled = resolvedState.jobs.find((job) => job.id === visitor.jobId); assert(cancelled);
        assert.equal(resolvedState.mode, 'human');
        assert.equal(cancelled.status, 'cancelled');
        assert.equal(cancelled.responsibility_status, 'intentional_silence');
        assert.equal(cancelled.responsibility_reason, 'human_reply');
        assert.equal(cancelled.data, undefined);
        assert.equal(sent.filter((entry) => entry.session_id === session).length, visibleCount,
          '确认真人后的迟到答案不得发送');
        assert.equal(sendAttempts, postCount);
        assert.equal(modelRequests.length, modelCount + 1);
        const settlementCleanup = await boundedResult(runtime.process(visitor.key, visitor.jobId),
          '真人确认后的 Provider 清理');
        assert.equal(settlementCleanup.status, 'provider_settlement_settled',
          '真人确认后必须先完成已在途的 Provider settlement');
        let cleaned = state(session).jobs.find((job) => job.id === visitor.jobId); assert(cleaned);
        assert.equal(cleaned.status, 'cancelled');
        assert.equal(cleaned.responsibility_status, 'intentional_silence');
        assert.equal(cleaned.responsibility_reason, 'human_reply');
        assert.equal(cleaned.provider_settlement, undefined);
        assert.equal(cleaned.provider_retirement?.state, 'pending');
        assert.equal(cleaned.provider_retirement?.purpose, 'conversation_cancelled');
        assert(cleaned.inference && cleaned.provider_result_receipt,
          'retirement 完成前必须保留待清理的 Provider 身份');
        assert.equal(sendAttempts, postCount,
          '真人确认后的 settlement 不得 POST Crisp');
        assert.equal(sent.filter((entry) => entry.session_id === session).length, visibleCount);
        assert.equal(modelRequests.length, modelCount + 1,
          '真人确认后的 settlement 不得重新推理');

        const retirementCleanup = await boundedResult(runtime.process(visitor.key, visitor.jobId),
          '真人确认后的 Provider retirement');
        assert.equal(retirementCleanup.status, 'provider_retirement_absent');
        cleaned = state(session).jobs.find((job) => job.id === visitor.jobId); assert(cleaned);
        assert.equal(cleaned.status, 'cancelled');
        assert.equal(cleaned.responsibility_status, 'intentional_silence');
        assert.equal(cleaned.responsibility_reason, 'human_reply');
        assert.equal(cleaned.provider_retirement?.state, 'absent');
        assert.equal(cleaned.provider_retirement?.purpose, 'conversation_cancelled');
        assert.equal(cleaned.inference, undefined);
        assert.equal(cleaned.provider_result_receipt, undefined);
        assert.equal(sendAttempts, postCount,
          '真人确认后的 retirement 不得 POST Crisp');
        assert.equal(sent.filter((entry) => entry.session_id === session).length, visibleCount);
        assert.equal(modelRequests.length, modelCount + 1,
          '真人确认后的 retirement 不得重新推理');

        assert.equal((await boundedResult(runtime.process(visitor.key, visitor.jobId),
          '真人确认后的重复原任务')).status, 'idle');
        assert.equal(sendAttempts, postCount);
        assert.equal(sent.filter((entry) => entry.session_id === session).length, visibleCount);
        assert.equal(modelRequests.length, modelCount + 1,
          '真人取消与 Provider 两阶段清理均不得重放推理');

        const parallel = await boundedResult(deliver(message(parallelSession, '另一会话继续正常回答')),
          '另一会话独立回答');
        assert.equal(parallel.status, 'sent');
        assert.equal(state(parallelSession).mode, 'ai');
        assert.equal(sent.filter((entry) => entry.session_id === parallelSession).length, 1);
        assert.equal(modelRequests.length, modelCount + 2);
        assert.equal(sendAttempts, postCount + 1);
      }
    } finally {
      releaseSettlementGate();
      if (running && !runningSettled) {
        try { await awaitNamedGate(running.catch(() => undefined),
          '失败分支释放普通处理网络门', 2000); } catch (_) {}
      }
      runtime = createRuntime(env, runtimeOptions);
    }
  };
  await test('P0 processing 遇未确认 operator 后，确认自动化时复用同一答案继续一次', async () => {
    await processingOperatorBarrierCase('not-human', false);
  });
  await test('P0 processing 遇未确认 operator 后，确认真人才静默且另一会话继续', async () => {
    await processingOperatorBarrierCase('human', true);
  });
  await test('P0 推理前出现未确认 operator 时保留同一问题，确认自动化后只回答一次', async () => {
    const session = 'session_processing-operator-before-inference';
    const modelCount = modelRequests.length;
    const postCount = sendAttempts;
    const visibleCount = sent.filter((entry) => entry.session_id === session).length;
    let injected = false;
    let control;
    let ambiguousData;
    const gatedRequest = async (url, options = {}) => {
      const parsed = new URL(url);
      const match = parsed.pathname.match(/\/conversation\/([^/]+)(\/.*)$/);
      if (!injected && match && decodeURIComponent(match[1]) === session
        && match[2] === '/messages') {
        const before = state(session);
        const claimed = before.jobs.find((job) => job.id === visitor.jobId); assert(claimed);
        assert.equal(claimed.status, 'processing');
        assert.equal(claimed.attempts, 1);
        assert(claimed.data, '推理前屏障必须发生在原始问题仍已持久的窗口');
        assert.equal(claimed.plan, undefined);
        assert.equal(claimed.inference, undefined);
        assert.equal(Object.values(before.outgoing || {})
          .some((record) => record?.job_id === visitor.jobId), false);
        now += 1;
        ambiguousData = {
          session_id: session, from: 'operator', type: 'text',
          content: '推理前待确认归属的公开 operator 事件',
          fingerprint: ++sequence, timestamp: now,
          user: { type: 'website', nickname: '受控待确认来源' },
        };
        control = await runtime.receive({
          body: { website_id: env.CRISP_WEBSITE_ID, event: 'message:received',
            timestamp: now, data: ambiguousData },
          query: { key: env.CRISP_WEBSITE_HOOK_SECRET },
        });
        assert.equal(control.route, 'process');
        assert(state(session).uncertain_events.includes(control.jobId));
        injected = true;
      }
      return request(url, options);
    };
    runtime = createRuntime(env, { ...runtimeOptions, request: gatedRequest });
    let visitor;
    try {
      visitor = await receive(message(session, '推理前归属核验窗口里的普通配置问题'));
      const interrupted = await runtime.process(visitor.key, visitor.jobId);
      assert.equal(injected, true);
      assert.equal(interrupted.status, 'deferred');
      assert(['operator_identity_pending', 'operator_identity_resolved'].includes(interrupted.reason));
      let preserved = state(session).jobs.find((job) => job.id === visitor.jobId); assert(preserved);
      assert.equal(preserved.status, 'received');
      assert.equal(preserved.responsibility_status, 'pending');
      assert.equal(preserved.attempts, 1);
      assert(preserved.data, '未确认身份不得删除原始访客问题');
      assert.equal(preserved.plan, undefined);
      assert.equal(preserved.inference, undefined);
      assert.equal(modelRequests.length, modelCount);
      assert.equal(sendAttempts, postCount);

      histories.set(session, [{ ...ambiguousData, automated: true },
        ...(histories.get(session) || [])]);
      const controlResult = await runtime.process(control.key, control.jobId);
      assert(!['failed', 'unresolved'].includes(controlResult.status));
      const resolved = state(session);
      assert.equal(resolved.uncertain_events.length, 0);
      assert.equal(resolved.jobs.find((job) => job.id === control.jobId)
        .operator_resolution.result, 'not-human');
      preserved = resolved.jobs.find((job) => job.id === visitor.jobId); assert(preserved);
      assert.equal(preserved.status, 'received');
      assert.equal(preserved.deferred_control, undefined);

      const completed = await runtime.process(visitor.key, visitor.jobId);
      assert.equal(completed.status, 'sent');
      assert.equal(modelRequests.length, modelCount + 1);
      assert.equal(sendAttempts, postCount + 1);
      assert.equal(sent.filter((entry) => entry.session_id === session).length, visibleCount + 1);
      assert.equal(state(session).jobs.find((job) => job.id === visitor.jobId)
        .responsibility_status, 'answered_confirmed');
      assert.equal((await runtime.process(visitor.key, visitor.jobId)).status, 'idle');
      assert.equal(sendAttempts, postCount + 1);
    } finally {
      runtime = createRuntime(env, runtimeOptions);
    }
  });
  await test('P0 未确认 operator 延期落盘失败后保留同一问题并由 scanner 恢复', async () => {
    const session = 'session_processing-operator-persistence-failure';
    const modelCount = modelRequests.length;
    const postCount = sendAttempts;
    const visibleCount = sent.filter((entry) => entry.session_id === session).length;
    const originalRenameSync = fs.renameSync;
    let armed = false;
    let injected = false;
    let control;
    let ambiguousData;
    let visitor;
    const stateFile = path.join(root, 'data/runtime',
      'session-' + runtime.stateKey(env.CRISP_WEBSITE_ID, session) + '.json');
    fs.renameSync = function (source, destination) {
      if (armed && !injected && path.resolve(String(destination)) === path.resolve(stateFile)
        && String(source).startsWith(stateFile + '.tmp-')) {
        const current = JSON.parse(fs.readFileSync(stateFile, 'utf8'));
        const stored = current.jobs.find((job) => job.id === visitor?.jobId);
        if (stored?.status === 'processing' && current.uncertain_events.includes(control?.jobId)) {
          armed = false;
          injected = true;
          const failure = new Error('受控 operator 延期状态提交失败');
          failure.code = 'EIO';
          throw failure;
        }
      }
      return originalRenameSync.apply(this, arguments);
    };
    const gatedRequest = async (url, options = {}) => {
      const parsed = new URL(url);
      const match = parsed.pathname.match(/\/conversation\/([^/]+)(\/.*)$/);
      if (!control && match && decodeURIComponent(match[1]) === session
        && match[2] === '/messages') {
        const claimed = state(session).jobs.find((job) => job.id === visitor.jobId); assert(claimed);
        assert.equal(claimed.status, 'processing');
        assert.equal(claimed.attempts, 1);
        assert(claimed.data, '故障注入必须发生在原始问题已持久的 processing 窗口');
        assert.equal(claimed.plan, undefined);
        assert.equal(claimed.inference, undefined);
        assert.equal(Object.values(state(session).outgoing || {})
          .some((record) => record?.job_id === visitor.jobId), false);
        now += 1;
        ambiguousData = {
          session_id: session, from: 'operator', type: 'text',
          content: '延期写入失败前的待确认 operator 事件',
          fingerprint: ++sequence, timestamp: now,
          user: { type: 'website', nickname: '受控待确认来源' },
        };
        control = await runtime.receive({
          body: { website_id: env.CRISP_WEBSITE_ID, event: 'message:received',
            timestamp: now, data: ambiguousData },
          query: { key: env.CRISP_WEBSITE_HOOK_SECRET },
        });
        assert.equal(control.route, 'process');
        assert(state(session).uncertain_events.includes(control.jobId));
        armed = true;
      }
      return request(url, options);
    };
    runtime = createRuntime(env, { ...runtimeOptions, request: gatedRequest });
    try {
      visitor = await receive(message(session, '延期事务失败也必须保留的普通问题'));
      const interrupted = await runtime.process(visitor.key, visitor.jobId);
      assert.equal(injected, true, '必须精确命中首次 operator 延期状态提交');
      assert.deepEqual([interrupted.status, interrupted.reason],
        ['deferred', 'operator_identity_persistence_failed']);
      let snapshot = state(session);
      let preserved = snapshot.jobs.find((job) => job.id === visitor.jobId); assert(preserved);
      assert.equal(snapshot.mode, 'ai');
      assert.equal(preserved.status, 'processing');
      assert.equal(preserved.responsibility_status, 'pending');
      assert(preserved.data, '技术性延期写入失败不得删除原始访客问题');
      assert.equal(preserved.plan, undefined);
      assert.equal(preserved.inference, undefined);
      assert(preserved.lease_until > now, '原 processing lease 必须留给 scanner 有界回收');
      assert(snapshot.uncertain_events.includes(control.jobId));
      assert.equal(modelRequests.length, modelCount);
      assert.equal(sendAttempts, postCount);

      now = preserved.lease_until + 1;
      const scheduled = await runtime.scan();
      assert(scheduled.some((entry) => entry.key === visitor.key && entry.jobId === control.jobId),
        'lease 到期后 scanner 必须继续调度同会话 operator 控制责任');
      snapshot = state(session);
      preserved = snapshot.jobs.find((job) => job.id === visitor.jobId); assert(preserved);
      assert.equal(preserved.status, 'received');
      assert.equal(preserved.responsibility_status, 'pending');
      assert(preserved.data);
      assert.equal(preserved.execution_token, undefined);

      histories.set(session, [{ ...ambiguousData, automated: true },
        ...(histories.get(session) || [])]);
      const controlResult = await runtime.process(control.key, control.jobId);
      assert(!['failed', 'unresolved'].includes(controlResult.status));
      snapshot = state(session);
      assert.equal(snapshot.uncertain_events.length, 0);
      assert.equal(snapshot.jobs.find((job) => job.id === control.jobId)
        .operator_resolution.result, 'not-human');
      preserved = snapshot.jobs.find((job) => job.id === visitor.jobId); assert(preserved);
      assert.equal(preserved.status, 'received');
      assert.equal(preserved.deferred_control, undefined);

      const completed = await runtime.process(visitor.key, visitor.jobId);
      assert.equal(completed.status, 'sent');
      assert.equal(modelRequests.length, modelCount + 1);
      assert.equal(sendAttempts, postCount + 1);
      assert.equal(sent.filter((entry) => entry.session_id === session).length, visibleCount + 1);
      assert.equal(state(session).jobs.find((job) => job.id === visitor.jobId)
        .responsibility_status, 'answered_confirmed');
      assert.equal((await runtime.process(visitor.key, visitor.jobId)).status, 'idle');
      assert.equal(sendAttempts, postCount + 1, '恢复后不得重复发送同一答案');
    } finally {
      fs.renameSync = originalRenameSync;
      runtime = createRuntime(env, runtimeOptions);
    }
  });
  await test('P0 历史 operator 缺失或超前时间必须先持久回查，不得冒充当前真人', async () => {
    const cases = [
      { suffix: 'not-human', raw: {}, firstExact: { automated: true }, human: false },
      { suffix: 'pending', raw: {}, firstExact: {}, resolveLater: true, human: false },
      { suffix: 'human-future', raw: { automated: false, timestamp: now + 120000 },
        firstExact: { automated: false }, human: true },
    ];
    for (const item of cases) {
      const session = 'session_history-operator-time-' + item.suffix;
      const modelCount = modelRequests.length;
      const postCount = sendAttempts;
      const visibleCount = sent.filter((entry) => entry.session_id === session).length;
      const operatorFingerprint = ++sequence;
      const ambiguous = {
        session_id: session, from: 'operator', type: 'text',
        content: '历史中待核验的公开 operator 消息', fingerprint: operatorFingerprint,
        user: { type: 'website', nickname: '受控待确认来源' }, ...item.raw,
      };
      let exact = { ...ambiguous, ...item.firstExact };
      delete exact.timestamp;
      let exactAt = now + 1;
      exact.timestamp = exactAt;
      const historyRuntime = createRuntime(env, { ...runtimeOptions,
        request: async (url, options = {}) => {
          const parsed = new URL(url);
          const match = parsed.pathname.match(/\/conversation\/([^/]+)(\/.*)$/);
          if (match && decodeURIComponent(match[1]) === session
            && match[2] === '/message/' + operatorFingerprint) {
            return { status: 200, body: { error: false, data: structuredClone(exact) } };
          }
          return request(url, options);
        } });
      runtime = historyRuntime;
      try {
        const visitor = await receive(message(session, '历史 operator 时间待核验时的普通问题'));
        const history = histories.get(session) || [];
        history.push(structuredClone(ambiguous)); histories.set(session, history);
        const deferred = await runtime.process(visitor.key, visitor.jobId);
        assert.equal(deferred.status, 'deferred');
        assert.equal(deferred.reason, 'operator_identity_pending');
        let snapshot = state(session);
        const visitorJob = snapshot.jobs.find((job) => job.id === visitor.jobId); assert(visitorJob);
        const control = snapshot.jobs.find((job) => job.control === true
          && job.action === 'resolve_operator' && String(job.data?.fingerprint) === String(operatorFingerprint));
        assert(control, '未知原始时间的 operator 必须建立持久 control 责任');
        assert.equal(control.event_time_unverified, true);
        assert(snapshot.uncertain_events.includes(control.id));
        assert.equal(visitorJob.status, 'received');
        assert(visitorJob.data, '时间回查前不得删除原访客问题');
        assert.equal(modelRequests.length, modelCount);
        assert.equal(sendAttempts, postCount);

        now = exactAt + 1;
        let controlResult = await runtime.process(visitor.key, control.id);
        if (item.resolveLater) {
          snapshot = state(session);
          const pending = snapshot.jobs.find((job) => job.id === control.id); assert(pending);
          assert.equal(pending.status, 'received');
          assert.equal(pending.failure_code, 'operator_identity_pending');
          assert(snapshot.uncertain_events.includes(control.id));
          assert.equal(snapshot.mode, 'ai');
          now += 1;
          exact = { ...ambiguous, timestamp: exactAt, automated: true };
          await runtime.transaction(visitor.key, (current) => {
            const stored = current.jobs.find((job) => job.id === control.id); assert(stored);
            stored.retry_at = 0;
          });
          controlResult = await runtime.process(visitor.key, control.id);
        }
        assert(!['failed', 'unresolved'].includes(controlResult.status));
        snapshot = state(session);
        const resolved = snapshot.jobs.find((job) => job.id === control.id); assert(resolved);
        assert.equal(resolved.operator_resolution.result, item.human ? 'human' : 'not-human');
        assert.equal(resolved.event_time, exactAt,
          '控制时间必须来自 Crisp 精确消息，不得用本机收件时间冒充');
        assert.equal(resolved.responsibility_status, 'control_handled');
        assert.equal(resolved.responsibility_reason,
          item.human ? 'operator_reply' : 'operator_identity_resolved');
        for (const field of ['failure', 'failure_code', 'failure_since', 'last_failure_at',
          'failure_rounds', 'event_time_retry_reason']) {
          assert.equal(resolved[field], undefined,
            '控制归属恢复成功后必须清除旧瞬态失败字段：' + field);
        }
        assert.equal(snapshot.uncertain_events.includes(control.id), false);

        if (item.human) {
          const cancelled = snapshot.jobs.find((job) => job.id === visitor.jobId); assert(cancelled);
          assert.equal(snapshot.mode, 'human');
          assert.equal(snapshot.last_human_at, exactAt);
          assert.equal(cancelled.status, 'cancelled');
          assert.equal(cancelled.responsibility_status, 'intentional_silence');
          assert.equal(sent.filter((entry) => entry.session_id === session).length, visibleCount);
          assert.equal(modelRequests.length, modelCount);
          assert.equal(sendAttempts, postCount);
        } else {
          const ready = snapshot.jobs.find((job) => job.id === visitor.jobId); assert(ready);
          assert.equal(snapshot.mode, 'ai');
          assert.equal(ready.status, 'received');
          assert.equal(ready.deferred_control, undefined);
          const completed = await runtime.process(visitor.key, visitor.jobId);
          assert.equal(completed.status, 'sent');
          assert.equal(modelRequests.length, modelCount + 1);
          assert.equal(sendAttempts, postCount + 1);
          assert.equal(sent.filter((entry) => entry.session_id === session).length, visibleCount + 1);
        }
      } finally {
        runtime = createRuntime(env, runtimeOptions);
      }
    }
  });
  await test('P0 不确定 operator 回查为自动消息后，期间访客任务继续调度', async () => {
    const before = sent.length;
    const item = await deferredOperatorCase('automated', { automated: true });
    await runtime.process(item.control.key, item.control.jobId);
    assert.equal(state(item.session).uncertain_events.length, 0);
    assert.equal(item.visitorJob().status, 'received');
    assert.equal(item.visitorJob().deferred_control, undefined);
    assert.equal((await runtime.process(item.visitor.key, item.visitor.jobId)).status, 'sent');
    assert.equal(sent.length, before + 1);
  });
  await test('P0 不确定 operator 仍无法归属时保留屏障，确认自动化后才放行其后问题', async () => {
    const before = sent.length;
    const beforeModels = modelRequests.length;
    const beforePosts = sendAttempts;
    const item = await deferredOperatorCase('unknown', {});
    const previousGeneration = state(item.session).generation;
    assert.equal((await runtime.process(item.control.key, item.control.jobId)).status, 'deferred');
    let retryControl = state(item.session).jobs.find((job) => job.id === item.control.jobId);
    assert.equal(retryControl.failure_rounds, 1, '身份失败必须进入现有退避记账，不能永久固定5秒');
    assert.equal(retryControl.retry_at - now, 10000);
    const originalControlInput = JSON.stringify(retryControl.data);
    for (let round = 2; round <= 7; round += 1) {
      now = retryControl.retry_at + 1;
      assert.equal((await runtime.process(item.control.key, item.control.jobId)).status, 'deferred');
      retryControl = state(item.session).jobs.find((job) => job.id === item.control.jobId);
      assert.equal(retryControl.failure_rounds, round);
      assert.equal(retryControl.retry_at - now, Math.min(300000, 5000 * (2 ** round)));
      assert.equal(JSON.stringify(retryControl.data), originalControlInput);
      assert(state(item.session).uncertain_events.includes(item.control.jobId));
      assert.equal(item.visitorJob().status, 'received');
    }
    await runtime.transaction(item.control.key, (current) => {
      const legacy = current.jobs.find((job) => job.id === item.control.jobId);
      legacy.attempts = 13801;
      delete legacy.failure_rounds;
    });
    now = retryControl.retry_at + 1;
    assert.equal((await runtime.process(item.control.key, item.control.jobId)).status, 'deferred');
    retryControl = state(item.session).jobs.find((job) => job.id === item.control.jobId);
    assert.equal(retryControl.attempts, 13802, '旧尝试次数不得被升级或更名归零');
    assert.equal(retryControl.failure_rounds, 13802);
    assert.equal(retryControl.retry_at - now, 300000, '旧反复失败任务直接沿用有界退避，不重新密集试错');
    assert.equal(JSON.stringify(retryControl.data), originalControlInput);
    assert.equal(state(item.session).generation, previousGeneration);
    assert(state(item.session).uncertain_events.includes(item.control.jobId));
    assert.equal(item.visitorJob().status, 'received');
    assert.equal(item.visitorJob().deferred_control, true);
    assert.equal((await runtime.process(item.visitor.key, item.visitor.jobId)).status, 'idle');
    assert.equal(sent.length, before);
    const history = histories.get(item.session);
    history[0].automated = true;
    const control = state(item.session).jobs.find((job) => job.id === item.control.jobId);
    now = Math.max(now + 1, control.retry_at + 1);
    assert.equal((await runtime.process(item.control.key, item.control.jobId)).status, 'none');
    const resolved = state(item.session);
    const resolvedControl = resolved.jobs.find((job) => job.id === item.control.jobId);
    assert(resolvedControl);
    assert.equal(resolvedControl.status, 'done');
    assert.equal(resolvedControl.responsibility_status, 'control_handled');
    assert.equal(resolvedControl.responsibility_reason, 'operator_identity_resolved');
    assert.equal(resolved.uncertain_events.length, 0);
    assert.equal(item.visitorJob().deferred_control, undefined);
    assert.equal(modelRequests.length, beforeModels);
    assert.equal(sendAttempts, beforePosts);
    assert.equal(sent.length, before);
    const visitorResult = await runtime.process(item.visitor.key, item.visitor.jobId);
    assert.equal(visitorResult.status, 'sent');
    const answered = state(item.session);
    const answeredVisitor = answered.jobs.find((job) => job.id === item.visitor.jobId);
    assert(answeredVisitor);
    assert.equal(answeredVisitor.status, 'done');
    assert.equal(answeredVisitor.responsibility_status, 'answered_confirmed');
    const visitorOutgoing = Object.values(answered.outgoing || {})
      .filter((entry) => entry.job_id === item.visitor.jobId);
    assert.equal(visitorOutgoing.length, 1);
    assert.equal(visitorOutgoing[0].status, 'sent');
    assert.equal(modelRequests.length, beforeModels + 1);
    assert.equal(sendAttempts, beforePosts + 1);
    assert.equal(sent.length, before + 1);
  });
  const removeSessionState = (session) => {
    const file = path.join(root, 'data/runtime/session-' + key(session) + '.json');
    try { fs.unlinkSync(file); } catch (error) { if (error.code !== 'ENOENT') throw error; }
  };
  const windowOperator = (session, eventTime = now) => ({
    website_id: env.CRISP_WEBSITE_ID, event: 'message:received', timestamp: eventTime,
    data: { session_id: session, from: 'operator', type: 'text', content: '待核实身份的历史公开消息',
      fingerprint: ++sequence, timestamp: eventTime, user: { type: 'website', nickname: '受控来源' } },
  });
  await test('OW01 过期未知控制释放窗口后的原任务，历史回查与重复事件不重建屏障', async () => {
    const session = 'session_window-late-control';
    const originalHandoff = readConfig('handoff');
    const configuration = structuredClone(originalHandoff); configuration.handoff.resume_after_seconds = 3600;
    publishConfiguration('handoff', configuration);
    try {
      now += 100;
      const visitor = await receive(message(session, '窗口结束后的独立新咨询'));
      const visitorInput = structuredClone(state(session).jobs.find((job) => job.id === visitor.jobId).data);
      const ambiguous = windowOperator(session, now - 30 * 86400000);
      const historicalHuman = { ...ambiguous.data, fingerprint: ++sequence, automated: false,
        timestamp: ambiguous.data.timestamp + 180000 };
      histories.set(session, [ambiguous.data, historicalHuman, ...(histories.get(session) || [])]);
      const control = await receive(ambiguous);
      const before = state(session); const generation = before.generation;
      const original = structuredClone(before.jobs.find((job) => job.id === control.jobId));
      assert(before.uncertain_events.includes(control.jobId));
      const modelBaseline = modelRequests.length; const postBaseline = sendAttempts;
      const candidates = await runtime.scan();
      assert(candidates.some((entry) => entry.key === visitor.key && entry.jobId === visitor.jobId));
      let snapshot = state(session); let resolved = snapshot.jobs.find((job) => job.id === control.jobId);
      assert.equal(snapshot.generation, generation); assert.equal(snapshot.mode, 'ai');
      assert.equal(snapshot.uncertain_events.length, 0);
      assert.equal(resolved.operator_resolution.result, 'window-expired');
      assert.equal(resolved.operator_resolution.human_changed, false);
      assert.equal(resolved.operator_resolution.event_time, original.event_time);
      assert.equal(resolved.operator_resolution.expires_at, original.event_time + 3600000);
      assert.equal(resolved.input_identity_sha256, original.input_identity_sha256);
      assert.deepEqual(resolved.data, original.data);
      assert.equal(resolved.responsibility_reason, 'operator_window_expired');
      assert.equal((await runtime.process(visitor.key, visitor.jobId)).status, 'sent');
      assert.equal((await receive(ambiguous)).reason, '重复事件已忽略');
      runtime = createRuntime(env, runtimeOptions);
      await runtime.scan(); await runtime.process(visitor.key, visitor.jobId);
      snapshot = state(session); resolved = snapshot.jobs.find((job) => job.id === control.jobId);
      assert.equal(snapshot.uncertain_events.length, 0); assert.equal(snapshot.generation, generation);
      assert.equal(snapshot.last_human_at, historicalHuman.timestamp);
      assert.equal(snapshot.control_watermark, historicalHuman.timestamp + 3600000);
      assert.equal(snapshot.mode, 'ai', '已过期真人历史不得取消窗口后的新咨询再伪装恢复');
      assert.deepEqual(resolved.data, original.data, '历史原事件不得在普通收尾中删除');
      assert.equal(snapshot.jobs.find((job) => job.id === visitor.jobId).responsibility_status, 'answered_confirmed');
      assert.equal(modelRequests.length, modelBaseline + 1); assert.equal(sendAttempts, postBaseline + 1);
      assert.equal(sent.filter((entry) => entry.session_id === session).length, 1);
      assert.equal(Object.values(snapshot.outgoing).filter((record) => record.job_id === visitor.jobId && record.status === 'sent').length, 1);
      assert.equal(visitorInput.content, '窗口结束后的独立新咨询');
      process.stdout.write('观察过期窗口：' + JSON.stringify({ original_task_answered_once: true, original_control_retained: true, identity_not_assumed: true, generation_unchanged: true, duplicate_and_history_barrier_absent: true }) + '\n');
    } finally {
      removeSessionState(session); histories.delete(session); publishConfiguration('handoff', originalHandoff);
    }
  });
  await test('OW02 有效窗口、零秒及不可信时间保持屏障，窗口内旧咨询保留复核责任', async () => {
    const originalHandoff = readConfig('handoff');
    const sessions = [];
    try {
      const configuration = structuredClone(originalHandoff); configuration.handoff.resume_after_seconds = 3600;
      publishConfiguration('handoff', configuration);
      const session = 'session_window-expiry-backoff'; sessions.push(session);
      const started = now += 100; const ambiguous = windowOperator(session);
      const control = await receive(ambiguous); histories.set(session, [ambiguous.data]);
      now += 1; const during = await receive(message(session, '窗口内原咨询'));
      const duringInput = structuredClone(state(session).jobs.find((job) => job.id === during.jobId).data);
      await runtime.transaction(control.key, (current) => {
        const job = current.jobs.find((entry) => entry.id === control.jobId);
        job.attempts = 13801; job.failure_rounds = 13801; job.retry_at = started + 4000000;
        job.responsibility_status = 'unresolved_failure'; job.failure_code = 'operator_identity_pending';
      });
      const models = modelRequests.length; const posts = sendAttempts;
      now = started + 3599999; await runtime.scan();
      assert(state(session).uncertain_events.includes(control.jobId));
      assert.equal(state(session).jobs.find((job) => job.id === during.jobId).status, 'received');
      now = started + 3600001; await runtime.scan();
      let snapshot = state(session); const expired = snapshot.jobs.find((job) => job.id === control.jobId);
      assert.equal(snapshot.uncertain_events.length, 0); assert.equal(expired.attempts, 13801);
      assert.equal(expired.operator_resolution.result, 'window-expired', '到期不应等待旧五分钟重查资格');
      const held = snapshot.jobs.find((job) => job.id === during.jobId);
      assert.equal(held.status, 'failed'); assert.equal(held.recovery_requires_review, true);
      assert.equal(held.failure_code, 'operator_window_review_required'); assert.deepEqual(held.data, duringInput);
      assert.equal(modelRequests.length, models); assert.equal(sendAttempts, posts);
      const late = await receive(message(session, '窗口内迟到咨询', { timestamp: started + 2 }));
      assert.equal(late.route, 'ignore');
      assert.equal(state(session).jobs.find((job) => job.id === late.jobId).recovery_requires_review, true);
      const fresh = await receive(message(session, '窗口后的新咨询'));
      assert.equal((await runtime.process(fresh.key, fresh.jobId)).status, 'sent');
      assert.equal(modelRequests.length, models + 1); assert.equal(sendAttempts, posts + 1);
      for (const variant of ['zero', 'missing-time', 'wrong-source', 'wrong-identity']) {
        const itemSession = 'session_window-guard-' + variant; sessions.push(itemSession);
        const config = structuredClone(originalHandoff); config.handoff.resume_after_seconds = variant === 'zero' ? 0 : 3600;
        publishConfiguration('handoff', config); now += 100;
        const body = windowOperator(itemSession);
        if (variant === 'missing-time') { delete body.timestamp; delete body.data.timestamp; }
        const entry = await receive(body); histories.set(itemSession, [body.data]);
        await runtime.transaction(entry.key, (current) => {
          const job = current.jobs.find((item) => item.id === entry.jobId);
          if (variant === 'wrong-source') job.event_time_source = 'untrusted';
          if (variant === 'wrong-identity') job.input_identity_sha256 = '0'.repeat(64);
        });
        const beforeModels = modelRequests.length; const beforePosts = sendAttempts;
        now += 30 * 86400000; await runtime.scan();
        assert(state(itemSession).uncertain_events.includes(entry.jobId), variant + ' 不能只按年龄移除屏障');
        assert.notEqual(state(itemSession).jobs.find((job) => job.id === entry.jobId).operator_resolution?.result, 'window-expired');
        assert.equal(modelRequests.length, beforeModels); assert.equal(sendAttempts, beforePosts);
        removeSessionState(itemSession); histories.delete(itemSession);
      }
    } finally {
      for (const session of sessions) { removeSessionState(session); histories.delete(session); }
      publishConfiguration('handoff', originalHandoff);
    }
  });
  await test('OW03 过期未知控制不改有效真人、永久人工和总关的静默', async () => {
    const originalHandoff = readConfig('handoff'); const originalRuntime = readConfig('runtime');
    const sessions = [];
    try {
      for (const variant of ['active-human', 'permanent-human', 'global-disabled']) {
        const session = 'session_window-silence-' + variant; sessions.push(session);
        const config = structuredClone(originalHandoff); config.handoff.resume_after_seconds = 3600;
        publishConfiguration('handoff', config); now += 100;
        const ambiguous = windowOperator(session, now - 30 * 86400000);
        const control = await receive(ambiguous); histories.set(session, [ambiguous.data]);
        await runtime.scan();
        assert.equal(state(session).jobs.find((job) => job.id === control.jobId).operator_resolution.result, 'window-expired');
        if (variant === 'permanent-human') { config.handoff.resume_after_seconds = 0; publishConfiguration('handoff', config); }
        if (variant === 'global-disabled') publishConfiguration('runtime', { ...originalRuntime, enabled: false });
        else await operator(session);
        const snapshot = state(session); const models = modelRequests.length; const posts = sendAttempts;
        await deliver(message(session, '必须保持静默的咨询')); await runtime.scan();
        assert.equal(modelRequests.length, models); assert.equal(sendAttempts, posts);
        assert.equal(state(session).mode, variant === 'global-disabled' ? 'ai' : 'human');
        assert.equal(state(session).resume_at, snapshot.resume_at);
        assert.equal(state(session).generation, snapshot.generation);
        assert.equal(state(session).jobs.find((job) => job.id === control.jobId).operator_resolution.result, 'window-expired');
        if (variant === 'permanent-human') assert.equal(snapshot.resume_at, null);
        publishConfiguration('runtime', originalRuntime);
      }
    } finally {
      for (const session of sessions) { removeSessionState(session); histories.delete(session); }
      publishConfiguration('handoff', originalHandoff); publishConfiguration('runtime', originalRuntime);
    }
  });
  await test('P0 同一时间戳按持久 sequence 判断先后，控制后的访客消息仍处理一次', async () => {
    const before = sent.length;
    const item = await deferredOperatorCase('same-timestamp', { automated: true }, 0);
    assert.equal(item.visitorJob().event_time, state(item.session).jobs.find((job) => job.id === item.control.jobId).event_time);
    assert(item.visitorJob().sequence > state(item.session).jobs.find((job) => job.id === item.control.jobId).sequence);
    await runtime.process(item.control.key, item.control.jobId);
    assert.equal(item.visitorJob().status, 'received');
    assert.equal(item.visitorJob().generation, state(item.session).generation);
    assert.equal((await runtime.process(item.visitor.key, item.visitor.jobId)).status, 'sent');
    assert.equal(sent.length, before + 1);
  });
  await test('P0 不确定 operator 回查为真人后，只取消当前会话保留的问题', async () => {
    const before = sent.length;
    const item = await deferredOperatorCase('human', { automated: false });
    await runtime.process(item.control.key, item.control.jobId);
    assert.equal(state(item.session).mode, 'human');
    assert.equal(item.visitorJob().status, 'cancelled');
    assert.equal((await runtime.process(item.visitor.key, item.visitor.jobId)).status, 'idle');
    assert.equal(sent.length, before);
  });
  await test('P0 调度并发只先处理未决控制，重启状态保持且后续访客不丢失', async () => {
    const before = sent.length;
    const item = await deferredOperatorCase('scheduler', { automated: true });
    runtime = createRuntime(env, runtimeOptions);
    const first = (await runtime.scan()).filter((job) => job.key === item.control.key);
    assert.deepEqual(first.map((job) => [job.jobId, job.control]), [[item.control.jobId, true]]);
    await Promise.all(first.map((job) => runtime.process(job.key, job.jobId)));
    const second = (await runtime.scan()).filter((job) => job.key === item.control.key);
    assert.deepEqual(second.map((job) => [job.jobId, job.control]), [[item.visitor.jobId, false]]);
    await Promise.all(second.map((job) => runtime.process(job.key, job.jobId)));
    assert.equal(sent.length, before + 1);
  });
  await test('P0 多个未决 operator 逐次建立栅栏，最后归属前不提前释放访客任务', async () => {
    for (const [suffix, resolutions, firstStatus, barriersAfterFirst, secondStatus, barriersAfterSecond, outcome] of [
      ['automated-then-automated', [{ automated: true }, { automated: true }], 'none', [1], 'none', [], 'send'],
      ['unknown-then-automated', [{}, { automated: true }], 'deferred', [0, 1], 'none', [0], 'pending'],
      ['unknown-then-unknown', [{}, {}], 'deferred', [0, 1], 'deferred', [0, 1], 'pending'],
      ['unknown-then-human', [{}, { automated: false }], 'deferred', [0, 1], 'none', [0], 'human'],
    ]) {
      const before = sent.length;
      const modelBefore = modelRequests.length;
      const postBefore = sendAttempts;
      const session = 'session_multi-control-' + suffix;
      const controls = [];
      const originals = [];
      for (let index = 0; index < 2; index += 1) {
        const data = { session_id: session, from: 'operator', type: 'text', content: '受控多控制事件',
          fingerprint: ++sequence, timestamp: now, user: { type: 'website', nickname: '受控来源' } };
        originals.push(data);
        controls.push(await receive({ website_id: env.CRISP_WEBSITE_ID, event: 'message:received', timestamp: now, data }));
      }
      now += 1;
      const visitor = await receive(message(session, '两个 operator 归属确认期间的新问题'));
      const visitorJob = () => state(session).jobs.find((job) => job.id === visitor.jobId);
      const originalVisitorData = structuredClone(visitorJob().data);
      assert.equal(visitorJob().deferred_control, true);
      histories.set(session, [...originals.map((data, index) => ({ ...data, ...resolutions[index] })), ...(histories.get(session) || [])]);
      const firstResult = await runtime.process(controls[0].key, controls[0].jobId);
      assert.equal(firstResult.status, firstStatus);
      if (firstStatus === 'deferred') assert.equal(firstResult.reason, 'operator_identity_pending');
      const controlJob = (index) => state(session).jobs.find((job) => job.id === controls[index].jobId);
      assert.deepEqual(state(session).uncertain_events, barriersAfterFirst.map((index) => controls[index].jobId));
      assert.equal(controlJob(0).status, firstStatus === 'deferred' ? 'received' : 'done');
      assert.equal(controlJob(0).responsibility_status, firstStatus === 'deferred' ? 'unresolved_failure' : 'control_handled');
      if (firstStatus === 'deferred') assert.equal(controlJob(0).failure_code, 'operator_identity_pending');
      assert.equal(visitorJob().status, 'received');
      assert.equal(visitorJob().deferred_control, true, '尚有未决控制时不能提前释放');
      assert.equal(modelRequests.length, modelBefore, '控制归属处理不得调用模型');
      assert.equal(sendAttempts, postBefore, '控制归属处理不得发普通客服消息');
      assert.equal(sent.length, before, '控制归属处理不得产生可见 AI 回复');
      const secondResult = await runtime.process(controls[1].key, controls[1].jobId);
      assert.equal(secondResult.status, secondStatus);
      if (secondStatus === 'deferred') assert.equal(secondResult.reason, 'operator_identity_pending');
      assert.deepEqual(state(session).uncertain_events, barriersAfterSecond.map((index) => controls[index].jobId));
      assert.equal(controlJob(1).status, secondStatus === 'deferred' ? 'received' : 'done');
      assert.equal(controlJob(1).responsibility_status, secondStatus === 'deferred' ? 'unresolved_failure' : 'control_handled');
      if (secondStatus === 'deferred') assert.equal(controlJob(1).failure_code, 'operator_identity_pending');
      if (outcome === 'send') {
        assert.equal(state(session).mode, 'ai');
        assert.equal(visitorJob().status, 'received');
        assert.equal(visitorJob().deferred_control, undefined);
        assert.equal((await runtime.process(visitor.key, visitor.jobId)).status, 'sent');
        assert.equal(visitorJob().status, 'done');
        assert.equal(visitorJob().responsibility_status, 'answered_confirmed');
        const outgoing = Object.values(state(session).outgoing || {})
          .filter((record) => record.job_id === visitor.jobId);
        assert.equal(outgoing.length, 1);
        assert.equal(outgoing[0].status, 'sent');
        assert.equal(modelRequests.length, modelBefore + 1);
        assert.equal(sendAttempts, postBefore + 1);
        assert.equal(sent.length, before + 1);
      } else if (outcome === 'human') {
        assert.equal(state(session).mode, 'human');
        assert.equal(visitorJob().status, 'cancelled');
        assert.equal(visitorJob().responsibility_status, 'intentional_silence');
        assert.equal(visitorJob().responsibility_reason, 'human_reply');
        assert.equal(modelRequests.length, modelBefore);
        assert.equal(sendAttempts, postBefore);
        assert.equal(sent.length, before);
      } else {
        assert.equal(state(session).mode, 'ai');
        assert.equal(visitorJob().status, 'received');
        assert.equal(visitorJob().deferred_control, true);
        assert.equal((await runtime.process(visitor.key, visitor.jobId)).status, 'idle');
        assert.equal(visitorJob().status, 'received');
        assert.equal(visitorJob().responsibility_status, 'pending');
        assert.deepEqual(visitorJob().data, originalVisitorData, '未决屏障不得删除或改写访客原始责任');
        assert.equal(modelRequests.length, modelBefore);
        assert.equal(sendAttempts, postBefore);
        assert.equal(sent.length, before);
      }
    }
  });
  await test('P0 operator 归属事务后崩溃重放保持幂等，不取消恢复期间的新消息', async () => {
    for (const [suffix, resolved, expectedResult] of [
      ['not-human', { automated: true }, 'not-human'],
      ['human', { automated: false }, 'human'],
    ]) {
      const item = await deferredOperatorCase('resolution-replay-' + suffix, resolved);
      const originalData = structuredClone(state(item.session).jobs.find((job) => job.id === item.control.jobId).data);
      await runtime.process(item.control.key, item.control.jobId);
      const resolvedJob = state(item.session).jobs.find((job) => job.id === item.control.jobId);
      assert.equal(resolvedJob.operator_resolution.result, expectedResult);
      const firstGeneration = state(item.session).generation;
      const firstResume = state(item.session).resume_at;
      if (expectedResult !== 'human') {
        assert.equal((await runtime.process(item.visitor.key, item.visitor.jobId)).status, 'sent');
      }
      const sentBeforeNewVisitor = sent.length;
      now += 1;
      const later = await receive(message(item.session, '归属事务提交后、控制任务完成前到达的新问题'));
      await runtime.transaction(item.control.key, (current) => {
        const stored = current.jobs.find((job) => job.id === item.control.jobId);
        // 精确模拟：operator 归属及栅栏事务已经落盘，process 的完成事务尚未提交。
        stored.status = 'processing';
        stored.lease_until = now - 1;
        stored.data = originalData;
        stored.responsibility_status = 'unresolved_failure';
        stored.failure_code = 'operator_identity_pending';
        stored.failure_since = now - 1000;
        stored.last_failure_at = now - 500;
        stored.failure_rounds = 2;
        delete stored.plan;
      });
      runtime = createRuntime(env, runtimeOptions);
      await runtime.process(item.control.key, item.control.jobId);
      const replayedControl = state(item.session).jobs.find((job) => job.id === item.control.jobId);
      assert.equal(replayedControl.responsibility_status, 'control_handled');
      assert.equal(replayedControl.responsibility_reason,
        expectedResult === 'human' ? 'operator_reply' : 'operator_identity_resolved');
      assert.equal(replayedControl.failure_code, undefined,
        '已持久身份结果的崩溃重放必须收敛旧控制故障');
      assert.equal(state(item.session).generation, firstGeneration, '重放不得再次推进会话代次');
      assert.equal(state(item.session).resume_at, firstResume, '重放不得重复延长或改写人工截止时间');
      if (expectedResult === 'human') {
        assert.equal(state(item.session).jobs.find((job) => job.id === later.jobId).status, 'done');
        assert.equal(sent.length, sentBeforeNewVisitor);
        assert(!(await runtime.scan()).some((entry) => entry.key === later.key && entry.jobId === item.visitor.jobId),
          '真人确认前已取消的访客任务在重启扫描后不得重放');
      } else {
        assert.equal(state(item.session).jobs.find((job) => job.id === later.jobId).status, 'received');
        assert.equal((await runtime.process(later.key, later.jobId)).status, 'sent');
        assert.equal(sent.length, sentBeforeNewVisitor + 1);
      }
    }
  });
  await test('P0 旧版已移除 operator 屏障但未保存归属结果时收敛控制责任', async () => {
    const item = await deferredOperatorCase('legacy-committed-not-human', { automated: true });
    const initialGeneration = state(item.session).generation;
    await runtime.transaction(item.control.key, (current) => {
      const stored = current.jobs.find((job) => job.id === item.control.jobId); assert(stored);
      current.uncertain_events = current.uncertain_events.filter((id) => id !== stored.id);
      for (const pending of current.jobs) {
        if (!pending.control && pending.status === 'received') delete pending.deferred_control;
      }
      stored.status = 'received';
      stored.responsibility_status = 'unresolved_failure';
      stored.failure_code = 'operator_identity_pending';
      stored.failure_since = now - 1000;
      stored.last_failure_at = now - 500;
      stored.failure_rounds = 2;
      delete stored.operator_resolution;
      delete stored.plan;
    });
    const result = await runtime.process(item.control.key, item.control.jobId);
    assert(!['failed', 'unresolved'].includes(result.status));
    const recovered = state(item.session).jobs.find((job) => job.id === item.control.jobId); assert(recovered);
    assert.equal(recovered.operator_resolution.result, 'not-human');
    assert.equal(recovered.operator_resolution.legacy_recovered, true);
    assert.equal(recovered.responsibility_status, 'control_handled');
    assert.equal(recovered.responsibility_reason, 'operator_identity_resolved');
    assert.equal(recovered.failure_code, undefined);
    assert.equal(recovered.failure_since, undefined);
    assert.equal(recovered.last_failure_at, undefined);
    assert.equal(recovered.failure_rounds, undefined);
    assert.equal(state(item.session).generation, initialGeneration);
    assert.equal(item.visitorJob().deferred_control, undefined);
    assert.equal((await runtime.process(item.visitor.key, item.visitor.jobId)).status, 'sent');
  });
  await test('P0 兼容旧版误终结 unknown 的崩溃状态，恢复屏障后精确确认才放行', async () => {
    const item = await deferredOperatorCase('legacy-resolution-replay', {});
    const originalData = structuredClone(state(item.session).jobs.find((job) => job.id === item.control.jobId).data);
    await runtime.process(item.control.key, item.control.jobId);
    assert.equal((await runtime.process(item.visitor.key, item.visitor.jobId)).status, 'idle');
    const firstGeneration = state(item.session).generation;
    await runtime.transaction(item.control.key, (current) => {
      const stored = current.jobs.find((job) => job.id === item.control.jobId);
      stored.operator_resolution = { schema_version: 1, result: 'unknown', human_changed: false };
      stored.status = 'done';
      stored.lease_until = 0;
      stored.data = originalData;
      delete stored.plan;
      current.uncertain_events = current.uncertain_events.filter((id) => id !== stored.id);
    });
    const sentBefore = sent.length;
    now += 1;
    const later = await receive(message(item.session, '旧版崩溃状态恢复后的新问题'));
    runtime = createRuntime(env, runtimeOptions);
    await runtime.scan();
    let recovered = state(item.session).jobs.find((job) => job.id === item.control.jobId);
    assert.equal(recovered.status, 'received');
    assert.equal(recovered.failure_code, 'operator_identity_pending');
    assert(state(item.session).uncertain_events.includes(item.control.jobId));
    assert.equal(state(item.session).jobs.find((job) => job.id === later.jobId).deferred_control, true);
    histories.set(item.session, [{ ...originalData, automated: true }, ...(histories.get(item.session) || [])]);
    now = Math.max(now + 1, recovered.retry_at + 1);
    assert.equal((await runtime.process(item.control.key, item.control.jobId)).status, 'none');
    recovered = state(item.session).jobs.find((job) => job.id === item.control.jobId);
    assert.equal(recovered.operator_resolution.result, 'not-human');
    assert.equal(state(item.session).generation, firstGeneration);
    assert.equal((await runtime.process(later.key, later.jobId)).status, 'sent');
    assert.equal(sent.length, sentBefore + 1);
  });
  await test('P0 未决控制队列满时返回可重试失败，释放容量后访客消息只处理一次', async () => {
    const session = 'session_deferred-capacity';
    const operatorFingerprint = ++sequence;
    const ambiguous = { website_id: env.CRISP_WEBSITE_ID, event: 'message:received', timestamp: now,
      data: { session_id: session, from: 'operator', type: 'text', content: '受控队列 operator',
        fingerprint: operatorFingerprint, timestamp: now, user: { type: 'website', nickname: '受控来源' } } };
    const control = await receive(ambiguous);
    await runtime.transaction(control.key, (current) => {
      for (let index = 0; index < 127; index += 1) current.jobs.push({
        id: crypto.createHash('sha256').update('capacity|' + index).digest('hex'), event: 'synthetic',
        event_time: now, received_at: now, sequence: ++current.sequence, status: 'received', attempts: 0,
        revision: 1, generation: current.generation, control: true,
      });
    });
    const visitorBody = message(session, '控制队列满时的访客问题');
    const rejected = await receive(visitorBody);
    assert.equal(rejected.statusCode, 503);
    assert(!state(session).jobs.some((job) => String(job.data?.fingerprint) === String(visitorBody.data.fingerprint)),
      '队列拒绝事务不得留下半持久化访客任务');
    await runtime.transaction(control.key, (current) => {
      for (const job of current.jobs) if (job.event === 'synthetic') job.status = 'cancelled';
    });
    const accepted = await receive(visitorBody);
    assert.equal(accepted.route, 'ignore');
    histories.set(session, [{ ...ambiguous.data, automated: true }, ...(histories.get(session) || [])]);
    await runtime.process(control.key, control.jobId);
    const before = sent.length;
    assert.equal((await runtime.process(accepted.key, accepted.jobId)).status, 'sent');
    assert.equal(sent.length, before + 1);
    runtime = createRuntime(env, runtimeOptions);
    assert(!(await runtime.scan()).some((job) => job.key === accepted.key && job.jobId === accepted.jobId));
  });
  await test('T18 人工关键词仅展示原生可继续聊天 picker', async () => {
    const before = modelRequests.length;
    await deliver(message('session_client-a', '我想转人工'));
    const card = sent.at(-1);
    assert.equal(card.type, 'picker'); assert.equal(card.content.required, false); assert.equal(card.content.choices[0].label, '召唤人工客服');
    assert.equal('automated' in card, false); assert.equal('properties' in card, false);
    assert.deepEqual(card.user, {type: 'website', nickname: '在线客服'});
    assert.equal(state('session_client-a').mode, 'ai'); assert.equal(modelRequests.length, before);
    await deliver(message('session_client-a', '尚未点击，请回答普通问题'));
    assert.equal(state('session_client-a').mode, 'ai'); assert.equal(modelRequests.length, before + 1);
    assert.equal(sent.at(-1).type, 'text');
  });
  await test('C03 已确认 Crisp 拒绝只发送一次，保留脱敏状态且不自动转人工', async () => {
    for (const status of [400, 401, 403, 404, 413]) {
      const session = 'session_rejected-' + status;
      try {
        sendRejection = status;
        const attempts = sendAttempts;
        const modelCount = modelRequests.length;
        const result = await deliver(message(session, '虚构发送拒绝回归问题'));
        assert.equal(result.status, 'rejected');
        assert.equal(sendAttempts, attempts + 1);
        assert.equal(modelRequests.length, modelCount + 1);
        const rejectedState = state(session);
        assert.equal(rejectedState.mode, 'ai');
        const job = rejectedState.jobs.find((item) => item.id === result.jobId); assert(job);
        assert.equal(job.status, 'received');
        assert.equal(job.responsibility_status, 'unresolved_failure');
        assert.equal(job.failure_code, 'crisp_http_' + status);
        assert(job.data && job.plan, '明确拒绝不得删除原始问题或已生成答案');
        const [fingerprint, rejected] = Object.entries(rejectedState.outgoing)
          .find(([, record]) => record.job_id === result.jobId);
        assert.equal(rejected.status, 'rejected');
        assert.equal(rejected.failure, 'crisp_http_' + status);
        assert.equal(rejected.resend_forbidden, undefined);
        assert.equal(rejected.recovery_deferred, true);
        assert(Number.isSafeInteger(rejected.next_action_at));
        assert(rejected.body, '明确未接收的正文必须留作同一内容恢复');
        const frozenBody = structuredClone(rejected.body);
        sendRejection = 0;
        now = Math.max(now + 1, rejected.next_action_at + 1);
        const recovered = await runtime.process(result.key, result.jobId);
        assert.equal(recovered.status, 'sent');
        assert.equal(sendAttempts, attempts + 2, '恢复只重投同一持久正文一次');
        assert.equal(modelRequests.length, modelCount + 1, 'Crisp 拒绝恢复不得重新推理');
        assert.deepEqual(sent.at(-1), { ...frozenBody, session_id: session });
        const finished = state(session);
        assert.equal(finished.jobs.find((item) => item.id === result.jobId).responsibility_status,
          'answered_confirmed');
        assert.equal(finished.outgoing[fingerprint].status, 'sent');
      } finally {
        sendRejection = 0;
      }
    }
  });
  await test('P0 已冻结 rejected/rate-limited/unknown 答案遇待确认 operator 只延后不删除', async () => {
    const cases = [
      { suffix: 'rejected', rejection: 403, expected: 'rejected' },
      { suffix: 'rate-limited', rejection: 429, expected: 'rate_limited' },
      { suffix: 'unknown', rejection: 403, expected: 'unknown' },
    ];
    for (const item of cases) {
      const session = 'session_frozen-outgoing-operator-' + item.suffix;
      runtime = createRuntime(env, runtimeOptions);
      const modelCount = modelRequests.length;
      const postCount = sendAttempts;
      let initial;
      try {
        sendRejection = item.rejection;
        initial = await deliver(message(session, '已冻结答案遇到待确认 operator'));
      } finally { sendRejection = 0; }
      assert.equal(initial.status, item.expected === 'rate_limited' ? 'rate_limited' : 'rejected');
      let snapshot = state(session);
      let stored = snapshot.jobs.find((job) => job.id === initial.jobId); assert(stored);
      let pair = Object.entries(snapshot.outgoing).find(([, record]) => record.job_id === initial.jobId);
      assert(pair);
      const [fingerprint] = pair;
      if (item.expected === 'unknown') {
        await runtime.transaction(initial.key, (current) => {
          const record = current.outgoing[fingerprint]; assert(record);
          record.status = 'unknown';
          record.delivery_uncertain = true;
          record.resend_forbidden = true;
          record.recovery_deferred = true;
          record.next_action_at = 0;
          record.created_at = now - 20000;
          record.reconcile_misses = 1;
          record.reconcile_checked_at = now - 5001;
          delete record.failure;
          const job = current.jobs.find((entry) => entry.id === initial.jobId); assert(job);
          job.retry_at = 0;
        });
      } else {
        now = Math.max(now + 1, pair[1].next_action_at + 1);
        await runtime.transaction(initial.key, (current) => {
          const job = current.jobs.find((entry) => entry.id === initial.jobId); assert(job);
          job.retry_at = 0;
        });
      }
      snapshot = state(session);
      stored = snapshot.jobs.find((job) => job.id === initial.jobId); assert(stored);
      pair = Object.entries(snapshot.outgoing).find(([, record]) => record.job_id === initial.jobId);
      assert(pair);
      const frozenRecord = structuredClone(pair[1]);
      const frozenPlan = structuredClone(stored.plan);
      const frozenData = structuredClone(stored.data);
      const ambiguous = {
        session_id: session, from: 'operator', type: 'text',
        content: '冻结出站恢复期间的待确认 operator', fingerprint: ++sequence,
        timestamp: now, user: { type: 'website', nickname: '受控待确认来源' },
      };
      const frozenRuntime = createRuntime(env, { ...runtimeOptions,
        request: async (url, options = {}) => {
          const parsed = new URL(url);
          const match = parsed.pathname.match(/\/conversation\/([^/]+)(\/.*)$/);
          if (item.expected === 'unknown' && match && decodeURIComponent(match[1]) === session
            && match[2] === '/message/' + fingerprint) {
            return { status: 404, body: { error: true, reason: 'not_found' } };
          }
          return request(url, options);
        } });
      runtime = frozenRuntime;
      const running = runtime.process(initial.key, initial.jobId);
      // process() 的领取事务在首个 await 前已持久；让它创建取消
      // 监视后，在下一个恢复阶段之前插入未确认控制事件。
      await Promise.resolve();
      assert.equal(state(session).jobs.find((job) => job.id === initial.jobId).status, 'processing');
      const control = await runtime.receive({
        body: { website_id: env.CRISP_WEBSITE_ID, event: 'message:received',
          timestamp: now, data: ambiguous },
        query: { key: env.CRISP_WEBSITE_HOOK_SECRET },
      });
      assert.equal(control.route, 'process');
      const deferred = await running;
      assert.equal(deferred.status, 'deferred');
      assert.equal(deferred.reason, 'operator_identity_pending');
      snapshot = state(session);
      stored = snapshot.jobs.find((job) => job.id === initial.jobId); assert(stored);
      const preserved = snapshot.outgoing[fingerprint]; assert(preserved);
      assert.equal(stored.status, 'received');
      assert.notEqual(stored.responsibility_status, 'intentional_silence');
      assert.deepEqual(stored.data, frozenData);
      assert.deepEqual(stored.plan, frozenPlan);
      assert.equal(preserved.status, item.expected);
      assert.deepEqual(preserved.body, frozenRecord.body,
        '未确认 operator 不得删除已冻结待发正文');
      assert.equal(preserved.job_id, frozenRecord.job_id);
      assert.equal(preserved.content_sha256, frozenRecord.content_sha256);
      assert.equal(preserved.response_generation, frozenRecord.response_generation);
      if (item.expected === 'unknown') {
        assert.equal(preserved.resend_forbidden, true);
        assert.equal(preserved.delivery_uncertain, true);
      }
      assert.equal(modelRequests.length, modelCount + 1);
      assert.equal(sendAttempts, postCount + 1);

      const history = histories.get(session) || [];
      history.push({ ...ambiguous, automated: true }); histories.set(session, history);
      const controlResult = await runtime.process(control.key, control.jobId);
      assert(!['failed', 'unresolved'].includes(controlResult.status));
      if (item.expected === 'unknown') {
        const currentRecord = state(session).outgoing[fingerprint]; assert(currentRecord?.body);
        const updated = histories.get(session) || [];
        updated.push({ ...currentRecord.body, timestamp: now }); histories.set(session, updated);
      }
      now = Math.max(now + 5001,
        Number(state(session).outgoing[fingerprint]?.next_action_at || 0) + 1);
      await runtime.transaction(initial.key, (current) => {
        const job = current.jobs.find((entry) => entry.id === initial.jobId); assert(job);
        job.retry_at = 0;
      });
      const recovered = await runtime.process(initial.key, initial.jobId);
      assert.equal(recovered.status, 'sent');
      snapshot = state(session);
      assert.equal(snapshot.jobs.find((job) => job.id === initial.jobId).responsibility_status,
        'answered_confirmed');
      assert.equal(snapshot.outgoing[fingerprint].status, 'sent');
      assert.equal(modelRequests.length, modelCount + 1,
        '控制屏障恢复不得重新调用 Provider');
      assert.equal(sendAttempts, postCount + (item.expected === 'unknown' ? 1 : 2),
        '未知回执只读对账，明确拒绝/限流只重投原正文一次');
    }
    runtime = createRuntime(env, runtimeOptions);
  });
  await test('P0 operator 待确认窗口的 sent/null 回执解除屏障后严格重分类', async () => {
    const session = 'session_operator-pending-null-receipt';
    runtime = createRuntime(env, runtimeOptions);
    const modelCount = modelRequests.length;
    const postCount = sendAttempts;
    let initial;
    try {
      sendRejection = 403;
      initial = await deliver(message(session, '待确认 operator 窗口已收到的原答案'));
    } finally { sendRejection = 0; }
    assert.equal(initial.status, 'rejected');
    let snapshot = state(session);
    const [fingerprint, rejected] = Object.entries(snapshot.outgoing)
      .find(([, record]) => record.job_id === initial.jobId);
    assert(rejected?.body);
    const expectedDigest = rejected.content_sha256;
    await runtime.transaction(initial.key, (current) => {
      const job = current.jobs.find((entry) => entry.id === initial.jobId); assert(job?.plan);
      const record = current.outgoing[fingerprint]; assert(record);
      record.status = 'sent';
      record.semantic_status = 'valid_answer';
      record.receipt_current = null;
      record.receipt_state_change_reason = 'operator_identity_pending';
      record.receipt_confirmed_at = now;
      record.sent_at = now;
      record.resend_forbidden = true;
      delete record.body;
      delete record.failure;
      delete record.recovery_deferred;
      delete record.next_action_at;
      job.status = 'received';
      job.retry_at = 0;
      job.lease_until = 0;
      job.responsibility_status = 'unresolved_failure';
      job.failure_code = 'operator_identity_pending';
    });
    const result = await runtime.process(initial.key, initial.jobId);
    assert.equal(result.status, 'sent');
    snapshot = state(session);
    const completed = snapshot.jobs.find((job) => job.id === initial.jobId); assert(completed);
    const receipt = snapshot.outgoing[fingerprint]; assert(receipt);
    assert.equal(completed.status, 'done');
    assert.equal(completed.responsibility_status, 'answered_confirmed');
    assert.equal(receipt.status, 'sent');
    assert.equal(receipt.semantic_status, 'valid_answer');
    assert.equal(receipt.content_sha256, expectedDigest);
    assert.equal(receipt.receipt_current, true);
    assert.equal(Object.hasOwn(receipt, 'receipt_state_change_reason'), false);
    assert.equal(Object.hasOwn(receipt, 'state_changed_before_receipt'), false);
    assert(Number.isFinite(receipt.receipt_reclassified_at));
    assert.equal(modelRequests.length, modelCount + 1,
      '收敛已有 sent 回执不得再次推理');
    assert.equal(sendAttempts, postCount + 1,
      '收敛已有 sent 回执不得再次 POST Crisp');
  });
  await test('P0 operator 待确认窗口的 sent/null 摘要错配必须拒绝重分类', async () => {
    const session = 'session_operator-pending-null-receipt-mismatch';
    runtime = createRuntime(env, runtimeOptions);
    let initial;
    try {
      sendRejection = 403;
      initial = await deliver(message(session, '待确认 operator 窗口摘要错配的原答案'));
    } finally { sendRejection = 0; }
    assert.equal(initial.status, 'rejected');
    let snapshot = state(session);
    const [fingerprint, rejected] = Object.entries(snapshot.outgoing)
      .find(([, record]) => record.job_id === initial.jobId);
    assert(rejected?.body);
    const mismatchedDigest = rejected.content_sha256 === '0'.repeat(64)
      ? '1'.repeat(64) : '0'.repeat(64);
    let frozenRecord;
    await runtime.transaction(initial.key, (current) => {
      const job = current.jobs.find((entry) => entry.id === initial.jobId); assert(job?.plan);
      const record = current.outgoing[fingerprint]; assert(record);
      record.status = 'sent';
      record.semantic_status = 'valid_answer';
      record.receipt_current = null;
      record.receipt_state_change_reason = 'operator_identity_pending';
      record.receipt_confirmed_at = now;
      record.sent_at = now;
      record.resend_forbidden = true;
      record.content_sha256 = mismatchedDigest;
      delete record.body;
      delete record.failure;
      delete record.recovery_deferred;
      delete record.next_action_at;
      job.status = 'received';
      job.retry_at = 0;
      job.lease_until = 0;
      job.responsibility_status = 'unresolved_failure';
      job.failure_code = 'operator_identity_pending';
      frozenRecord = structuredClone(record);
    });
    const modelCount = modelRequests.length;
    const postCount = sendAttempts;
    const result = await runtime.process(initial.key, initial.jobId);
    assert.equal(result.status, 'delivery_identity_unresolved');
    snapshot = state(session);
    const unresolved = snapshot.jobs.find((job) => job.id === initial.jobId); assert(unresolved);
    const receipt = snapshot.outgoing[fingerprint]; assert(receipt);
    assert.equal(unresolved.status, 'received');
    assert.equal(unresolved.responsibility_status, 'unresolved_failure');
    assert.notEqual(unresolved.responsibility_status, 'answered_confirmed');
    assert.equal(unresolved.failure_code, 'delivery_identity_unresolved');
    assert(Number.isSafeInteger(unresolved.retry_at) && unresolved.retry_at > now,
      '身份损坏的 sent 回执必须保留未来人工恢复窗口');
    assert.deepEqual(receipt, frozenRecord,
      '身份损坏的 sent 回执不得被重分类或静默修复');
    assert.equal(receipt.status, 'sent');
    assert.equal(receipt.receipt_current, null);
    assert.equal(receipt.receipt_state_change_reason, 'operator_identity_pending');
    assert.equal(receipt.content_sha256, mismatchedDigest);
    assert.equal(Object.hasOwn(receipt, 'receipt_reclassified_at'), false);
    assert.equal(modelRequests.length, modelCount,
      '摘要错配的 sent 回执不得触发新的 Provider 请求');
    assert.equal(sendAttempts, postCount,
      '摘要错配的 sent 回执不得再次 POST Crisp');
  });
  await test('P0 Crisp POST 已开始时出现未确认 operator，只保留 unknown 对账且不重发', async () => {
    const session = 'session_operator-pending-post-started';
    const modelCount = modelRequests.length;
    let startedResolve;
    const started = new Promise((resolve) => { startedResolve = resolve; });
    let postCalls = 0;
    let frozenBody;
    const postRuntime = createRuntime(env, { ...runtimeOptions,
      request: async (url, options = {}) => {
        const parsed = new URL(url);
        const match = parsed.pathname.match(/\/conversation\/([^/]+)(\/.*)$/);
        if (match && decodeURIComponent(match[1]) === session
          && match[2] === '/message' && options.method === 'POST') {
          postCalls += 1;
          frozenBody = structuredClone(options.body);
          return abortablePending(options.signal, startedResolve);
        }
        return request(url, options);
      } });
    runtime = postRuntime;
    try {
      const visitor = await receive(message(session, 'POST 已开始时的 operator 归属窗口'));
      const running = runtime.process(visitor.key, visitor.jobId);
      await awaitNamedGate(started, 'Crisp POST 进入未确认 operator 窗口');
      assert.equal(postCalls, 1);
      assert(frozenBody && typeof frozenBody.content === 'string');
      now += 1;
      const ambiguous = {
        session_id: session, from: 'operator', type: 'text',
        content: 'POST 期间的待确认 operator', fingerprint: ++sequence,
        timestamp: now, user: { type: 'website', nickname: '受控待确认来源' },
      };
      const history = histories.get(session) || [];
      history.push(structuredClone(ambiguous)); histories.set(session, history);
      const control = await runtime.receive({
        body: { website_id: env.CRISP_WEBSITE_ID, event: 'message:received',
          timestamp: now, data: ambiguous },
        query: { key: env.CRISP_WEBSITE_HOOK_SECRET },
      });
      assert.equal(control.route, 'process');
      const deferred = await running;
      assert.equal(deferred.status, 'deferred');
      assert.equal(deferred.reason, 'operator_identity_pending');
      let snapshot = state(session);
      const pendingJob = snapshot.jobs.find((job) => job.id === visitor.jobId); assert(pendingJob);
      const [fingerprint, unknown] = Object.entries(snapshot.outgoing)
        .find(([, record]) => record.job_id === visitor.jobId);
      assert.equal(pendingJob.status, 'received');
      assert(pendingJob.data && pendingJob.plan,
        '未确认 operator 不得丢失原问题或已持久答案');
      assert.equal(unknown.status, 'unknown');
      assert.equal(unknown.delivery_uncertain, true);
      assert.equal(unknown.resend_forbidden, true);
      assert.equal(unknown.recovery_deferred, true);
      assert.equal(unknown.cancellation_reason, 'operator_identity_pending');
      assert.deepEqual(unknown.body, frozenBody);
      assert(Number.isFinite(unknown.next_action_at));
      assert.equal(modelRequests.length, modelCount + 1);

      histories.set(session, [{ ...ambiguous, automated: true },
        ...(histories.get(session) || []).filter((entry) =>
          String(entry.fingerprint) !== String(ambiguous.fingerprint))]);
      const controlResult = await runtime.process(control.key, control.jobId);
      assert(!['failed', 'unresolved'].includes(controlResult.status));
      snapshot = state(session);
      assert.equal(snapshot.uncertain_events.includes(control.jobId), false);
      const remoteHistory = histories.get(session) || [];
      remoteHistory.push({ ...frozenBody, timestamp: now }); histories.set(session, remoteHistory);
      now = Math.max(now + 5001, Number(unknown.next_action_at || 0) + 1);
      await runtime.transaction(visitor.key, (current) => {
        const job = current.jobs.find((entry) => entry.id === visitor.jobId); assert(job);
        job.retry_at = 0;
      });
      const recovered = await runtime.process(visitor.key, visitor.jobId);
      assert.equal(recovered.status, 'sent');
      snapshot = state(session);
      assert.equal(snapshot.jobs.find((job) => job.id === visitor.jobId).responsibility_status,
        'answered_confirmed');
      assert.equal(snapshot.outgoing[fingerprint].status, 'sent');
      assert.equal(snapshot.outgoing[fingerprint].receipt_current, true);
      assert.equal(postCalls, 1, '同一 fingerprint 的未知回执确认后不得二次 POST');
      assert.equal(modelRequests.length, modelCount + 1,
        '未知回执对账不得重新推理');
    } finally {
      runtime = createRuntime(env, runtimeOptions);
    }
  });
  await test('T19/T21 真点击缺少from/type、原fingerprint已见也只暂停A', async () => {
    const modelCount = modelRequests.length;
    await deliver(message('session_client-a', '人工'));
    const card = sent.at(-1);
    assert.equal(card.session_id, 'session_client-a');
    assert.equal(card.type, 'picker');
    assert.equal(modelRequests.length, modelCount);
    const current = state('session_client-a');
    const outbound = current.outgoing[String(card.fingerprint)];
    assert(outbound && outbound.status === 'sent' && outbound.message_type === 'picker'
      && outbound.purpose === 'handoff_offer',
      '人工按钮 fingerprint 必须先形成已确认的本项目出站身份');
    const echoId = digest(['message:received', String(card.fingerprint),
      digest(JSON.stringify(card.content))].join('|'));
    const echo = current.jobs.find((job) => job.id === echoId);
    assert(echo && echo.status === 'done' && echo.control === true
      && echo.action === 'non_operator_message' && echo.responsibility_status === 'control_handled',
      '人工按钮自回流必须先被接收核心识别为本项目控制消息');
    const offer = current.offers[card.content.id];
    assert(offer && offer.consumed_at === null && offer.expires_at > now,
      '点击场景必须使用当前有效且尚未消费的人工按钮');
    await deliver(click('session_client-a', card));
    assert.equal(state('session_client-a').mode, 'human');
    assert.equal(sent.at(-1).content, '您的人工协助请求已收到，请稍候。');
    await deliver(message('session_client-b', 'B 的正常问题'));
    assert.equal(state('session_client-b').mode, 'ai'); assert.equal(sent.at(-1).session_id, 'session_client-b');
    const before = sent.length; await deliver(message('session_client-a', '人工期间的新问题')); assert.equal(sent.length, before);
  });
  await test('T20/T22 取消、跨会话、重复双通知和伪造按钮', async () => {
    await deliver(message('session_cancel01', '人工'));
    const card = sent.at(-1);
    await deliver(click('session_client-b', card)); assert.equal(state('session_client-b').mode, 'ai');
    await deliver(click('session_cancel01', card, 1)); assert.equal(state('session_cancel01').mode, 'ai');
    await deliver(click('session_cancel01', card)); assert.equal(state('session_cancel01').mode, 'ai');
    await deliver(message('session_double01', '人工')); const another = sent.at(-1);
    await deliver(click('session_double01', another, 0, 'message:send'));
    const deadline = state('session_double01').resume_at; const count = sent.length;
    now += 500; await deliver(click('session_double01', another));
    assert.equal(sent.length, count); assert.equal(state('session_double01').resume_at, deadline);
    const fake = click('session_client-b', { fingerprint: 999999, content: { id: 'fake', choices: [{ value: 'handoff', selected: true }] } });
    await deliver(fake); assert.equal(state('session_client-b').mode, 'ai');
  });
  await test('T22/T23 到期、否定词、规则禁用和旧代次', async () => {
    const original = readConfig('keyword'); const revised = structuredClone(original); revised.rules[0].offer_ttl_seconds = 1; publishConfiguration('keyword', revised);
    await deliver(message('session_expired01', '人工')); const card = sent.at(-1); now += 1100; await deliver(click('session_expired01', card)); assert.equal(state('session_expired01').mode, 'ai');
    assert.equal(runtime.matchRule('不需要人工'), undefined);
    revised.rules[0].enabled = false; publishConfiguration('keyword', revised); assert.equal(runtime.matchRule('人工'), undefined); publishConfiguration('keyword', original);
    await deliver(message('session_oldoffer1', '人工')); const stale = sent.at(-1);
    await deliver(click('session_oldoffer1', stale));
    assert.equal(state('session_oldoffer1').mode, 'human', '旧按钮反例须先完成真正人工确认');
    await runtime.resume(key('session_oldoffer1'));
    await deliver(click('session_oldoffer1', stale)); assert.equal(state('session_oldoffer1').mode, 'ai');
    await deliver(message('session_offer-noop1', '人工')); const live = sent.at(-1);
    const liveGeneration = state('session_offer-noop1').generation;
    await runtime.resume(key('session_offer-noop1'));
    assert.equal(state('session_offer-noop1').generation, liveGeneration, '已AI恢复不得作废当前有效按钮');
    await deliver(click('session_offer-noop1', live)); assert.equal(state('session_offer-noop1').mode, 'human');
  });
  await test('T24/T25/T26 真人公开全部类型、自己的回流和非公开事件', async () => {
    for (const type of ['text', 'file', 'audio', 'animation']) { now += 1; const session = 'session_operator-' + type; await operator(session, { type, content: type === 'text' ? '人工文本' : { type: 'application/octet-stream' } }); assert.equal(state(session).mode, 'human'); }
    for (const type of ['note', 'event']) { now += 1; const session = 'session_nonhuman-' + type; await operator(session, { type }); assert.equal(state(session).mode, 'ai'); }
    await operator('session_stealth01', { stealth: true }); assert.equal(state('session_stealth01').mode, 'ai');
    await deliver({ ...message('session_opened01', '打开'), event: 'session:set_opened' }); assert.equal(state('session_opened01').mode, 'ai');
    assert.equal(state('session_client-b').mode, 'ai');
  });
  await test('T27/T28 人工事件不排在慢模型后，B继续且A迟到结果丢弃', async () => {
    let finish; delayed = new Promise((resolve) => { finish = resolve; });
    const entry = await receive(message('session_slowmodel1', '慢问题'));
    const pending = runtime.process(entry.key, entry.jobId); await wait(30);
    assert.equal(state('session_slowmodel1').worker.job, entry.jobId);
    now += 5; await operator('session_slowmodel1'); await deliver(message('session_parallel-b', 'B 的快速问题'));
    assert.equal(state('session_slowmodel1').mode, 'human');
    assert.equal(state('session_slowmodel1').worker, null, '真人事务取消 processing job 时必须同步释放其 worker');
    const generationAfterPause = state('session_slowmodel1').generation;
    await operator('session_slowmodel1', { fingerprint: sequence - 1, timestamp: now - 1 });
    assert.equal(state('session_slowmodel1').worker, null, '重复/旧人工控制不得恢复已取消 worker');
    assert.equal(state('session_slowmodel1').generation, generationAfterPause);
    const before = sent.filter((entry) => entry.session_id === 'session_slowmodel1').length;
    finish(); await pending;
    assert.equal(sent.filter((entry) => entry.session_id === 'session_slowmodel1').length, before);
    assert.equal(sent.at(-1).session_id, 'session_parallel-b');
  });
  await test('P0 worker 崩溃恢复只清孤儿或过期租约，保留活跃任务并隔离会话', async () => {
    const staleSession = 'session_worker-stale';
    const stale = await receive(message(staleSession, '过期 worker 的问题'));
    await runtime.transaction(stale.key, (current) => {
      const job = current.jobs.find((entry) => entry.id === stale.jobId);
      job.status = 'processing'; job.lease_until = now - 1;
      current.worker = { job: job.id, token: 'stale-token', until: now - 1 };
    });
    const orphanSession = 'session_worker-orphan';
    const orphanKey = key(orphanSession);
    await runtime.transaction(orphanKey, (current) => {
      current.worker = { job: 'f'.repeat(64), token: 'orphan-token', until: now + 60000 };
    }, env.CRISP_WEBSITE_ID, orphanSession);
    const cancelledSession = 'session_worker-cancelled';
    const cancelled = await receive(message(cancelledSession, '已取消任务不得重放'));
    await runtime.transaction(cancelled.key, (current) => {
      const job = current.jobs.find((entry) => entry.id === cancelled.jobId);
      job.status = 'cancelled'; delete job.data;
      current.worker = { job: job.id, token: 'cancelled-token', until: now + 60000 };
    });
    const receivedSession = 'session_worker-received';
    const received = await receive(message(receivedSession, '待处理任务应在孤儿 worker 清理后继续'));
    await runtime.transaction(received.key, (current) => {
      current.worker = { job: received.jobId, token: 'received-token', until: now + 60000 };
    });
    const activeSession = 'session_worker-active';
    const active = await receive(message(activeSession, '活跃 worker 不得被扫描器清理'));
    await runtime.transaction(active.key, (current) => {
      const job = current.jobs.find((entry) => entry.id === active.jobId);
      job.status = 'processing'; job.lease_until = now + 60000;
      current.worker = { job: job.id, token: 'active-token', until: now + 60000 };
    });
    const permanentSession = 'session_worker-permanent';
    await runtime.transaction(key(permanentSession), (current) => {
      current.mode = 'human'; current.generation = 7; current.resume_at = null;
      current.worker = { job: 'e'.repeat(64), token: 'permanent-orphan', until: now + 60000 };
    }, env.CRISP_WEBSITE_ID, permanentSession);

    runtime = createRuntime(env, runtimeOptions);
    const scanJobs = await runtime.scan();
    assert.equal(state(staleSession).worker, null);
    assert(scanJobs.some((item) => item.key === stale.key && item.jobId === stale.jobId),
      '过期 processing 租约应恢复为可调度任务');
    assert.equal(state(orphanSession).worker, null);
    assert.equal(state(cancelledSession).worker, null);
    assert.equal(state(receivedSession).worker, null);
    assert(!scanJobs.some((item) => item.key === cancelled.key && item.jobId === cancelled.jobId),
      '已取消任务不得因孤儿 worker 被重新调度');
    assert.deepEqual(state(activeSession).worker, { job: active.jobId, token: 'active-token', until: now + 60000 });
    assert(!scanJobs.some((item) => item.key === active.key), '活跃 processing worker 不得被重复调度');
    assert.equal(state(permanentSession).worker, null);
    assert.equal(state(permanentSession).mode, 'human');
    assert.equal(state(permanentSession).generation, 7);
    assert.equal(state(permanentSession).resume_at, null);

    const before = sent.length;
    await runtime.process(stale.key, stale.jobId);
    assert.equal(sent.length, before + 1);
    await runtime.process(received.key, received.jobId);
    assert.equal(sent.length, before + 2, 'received job 清理孤儿 worker 后只应正常处理一次');
    const fresh = await receive(message(orphanSession, '孤儿 worker 清理后的新问题'));
    assert.equal((await runtime.process(fresh.key, fresh.jobId)).status, 'sent');
    assert.equal(state(activeSession).worker.token, 'active-token', '其他会话恢复不得触碰活跃 worker');
  });
  await test('P0 人工接管中止已开始的 Crisp 出站，只保留 unknown 对账且 B 独立', async () => {
    const analytics = path.join(root, 'data/analytics/events.jsonl');
    const analyticsEvents = () => fs.existsSync(analytics)
      ? fs.readFileSync(analytics, 'utf8').trim().split('\n').filter(Boolean)
        .map(line => JSON.parse(line)) : [];
    const countEventsIn = (events, type) => events.filter(event => event.type === type).length;
    const countEvents = type => countEventsIn(analyticsEvents(), type);
    const countedFlag = value => value === undefined ? 'absent' : value === true ? 'true' : 'invalid';
    const normalReplies = countEvents('ai_reply');
    const interruptAfterPostStarted = async (session) => {
      let release;
      delayedCrisp = new Promise((resolve) => { release = resolve; });
      const attempts = sendAttempts;
      const before = sent.filter((item) => item.session_id === session).length;
      const entry = await receive(message(session, '等待发送的普通问题'));
      let pendingSettled = false;
      const pending = runtime.process(entry.key, entry.jobId).then((result) => {
        pendingSettled = true; return result;
      }, (error) => { pendingSettled = true; throw error; });
      for (let tries = 0; tries < 200 && sendAttempts === attempts; tries += 1) await wait(5);
      assert.equal(sendAttempts, attempts + 1, '普通回答必须已经进入受控 Crisp POST');
      now += 5;
      const controlRuntime = createRuntime(env, runtimeOptions);
      const human = { ...message(session, '另一运行时实例收到真人公开回复', {
        from: 'operator', automated: false,
      }), event: 'message:received' };
      const history = histories.get(session) || [];
      history.push(human.data); histories.set(session, history);
      const accepted = await controlRuntime.receive({ body: human,
        query: { key: env.CRISP_WEBSITE_HOOK_SECRET } });
      assert.equal(accepted.accepted, true);
      if (accepted.route === 'process') await controlRuntime.process(accepted.key, accepted.jobId);
      const cancellationReason = 'conversation_state_changed';
      for (let tries = 0; tries < 100 && (!pendingSettled || !Object.values(state(session).outgoing)
        .some(record => record.cancellation_reason === cancellationReason)); tries += 1) await wait(10);
      assert.equal(pendingSettled, true, '原 worker 仍存活时必须由持久状态轮询中止网络请求');
      const result = await pending;
      release();
      assert.equal(result.status, 'cancelled');
      const current = state(session);
      assert.equal(current.mode, 'human');
      assert.equal(sent.filter((item) => item.session_id === session).length, before,
        '挂起出站必须在写入受控远端记录前中止');
      const outgoing = Object.values(current.outgoing).find((record) => record.job_id === entry.jobId);
      const job = current.jobs.find((item) => item.id === entry.jobId);
      assert(outgoing && job, '人工接管后必须保留原 job 与出站对账身份');
      assert.equal(outgoing.status, 'unknown');
      assert.equal(outgoing.delivery_uncertain, true);
      assert.equal(outgoing.resend_forbidden, true, '人工接管后未知结果只能对账，绝不能重发');
      assert.equal(outgoing.recovery_deferred, true);
      assert(outgoing.next_action_at > now, '未知回执必须登记后续只读对账时间');
      assert.equal(outgoing.cancellation_reason, cancellationReason);
      const fingerprint = String(outgoing.body.fingerprint);
      assert.equal(current.outgoing[fingerprint], outgoing,
        '原 fingerprint 必须继续指向同一未知出站记录');
      assert.equal(typeof outgoing.body.content, 'string');
      assert(outgoing.body.content.length > 0, '未知回执必须保留原正文供同 fingerprint 对账');
      assert.equal(job.status, 'cancelled');
      assert.equal(job.responsibility_status, 'intentional_silence');
      assert.equal(job.responsibility_reason, 'human_reply');
      assert.equal(Object.hasOwn(job, 'plan'), false,
        '政策取消后只能是 plan 字段确实不存在，不得用空值伪装');
      assert.equal(job.provider_settlement?.state, 'settled',
        '政策取消前已完成的 Provider settlement 必须保留给独立清理诊断');
      assert.equal(job.provider_retirement_failure_code,
        'provider_retirement_identity_unresolved',
        '缺少推理回执时 Provider retirement 故障必须保留，不能被 Crisp 对账洗掉');
      return { entry, body: structuredClone(outgoing.body), fingerprint,
        cancellationReason,
        providerSettlement: structuredClone(job.provider_settlement),
        providerRetirementFailureCode: job.provider_retirement_failure_code };
    };
    const assertSingleJobAcrossMaintenance = async (runtimeInstance, tracked) => {
      for (let cycle = 0; cycle < 3; cycle += 1) {
        let snapshot = runtimeInstance.readState(tracked.entry.key);
        assert.equal(snapshot.jobs.filter((item) => item.id === tracked.entry.jobId).length, 1,
          'cancelled+unknown 责任经 read 后仍只能保留一个原 job ID');
        assert.equal(snapshot.outgoing[tracked.fingerprint].status, 'unknown');
        assert.equal(snapshot.outgoing[tracked.fingerprint].resend_forbidden, true);
        const transactionCount = await runtimeInstance.transaction(tracked.entry.key, (current) =>
          current.jobs.filter((item) => item.id === tracked.entry.jobId).length);
        assert.equal(transactionCount, 1,
          'expire 的 pendingJobs/completedJobs 分组不得把同一 cancelled+unknown job 重复追加');
        const scheduled = (await runtimeInstance.scan()).filter((item) =>
          item.key === tracked.entry.key && item.jobId === tracked.entry.jobId);
        assert(scheduled.length <= 1, '同一应答责任不得在一次扫描中产生重复调度项');
        snapshot = runtimeInstance.readState(tracked.entry.key);
        assert.equal(snapshot.jobs.filter((item) => item.id === tracked.entry.jobId).length, 1,
          '多次 transaction/scan 后原 job ID 数量必须始终为 1');
        assert.equal(snapshot.jobs.find((item) => item.id === tracked.entry.jobId).responsibility_status,
          'intentional_silence');
      }
    };

    const absentSession = 'session_crisp-send-race-absent';
    const absent = await interruptAfterPostStarted(absentSession);
    await assertSingleJobAcrossMaintenance(runtime, absent);
    const attemptsAfterAbort = sendAttempts;
    let exactMisses = 0;
    const missingRuntime = createRuntime(env, { ...runtimeOptions, request: async (url, options = {}) => {
      const parsed = new URL(url);
      const match = parsed.pathname.match(/\/conversation\/([^/]+)(\/.*)$/);
      if (match && decodeURIComponent(match[1]) === absentSession
        && match[2] === '/message/' + absent.fingerprint) {
        exactMisses += 1;
        return { status: 404, body: { error: true, reason: 'not_found' } };
      }
      return request(url, options);
    } });
    now += 10000;
    assert.equal((await missingRuntime.process(absent.entry.key, absent.entry.jobId)).status, 'retry');
    let current = missingRuntime.readState(absent.entry.key);
    let record = current.outgoing[absent.fingerprint];
    let job = current.jobs.find((item) => item.id === absent.entry.jobId);
    assert.equal(exactMisses, 1);
    assert.equal(record.status, 'unknown');
    assert.equal(record.resend_forbidden, true);
    assert.deepEqual(record.body, absent.body,
      '首次精确 404 后必须完整保留原 fingerprint/body，等待第二次只读确认');
    assert.equal(job.status, 'cancelled');
    assert.equal(job.responsibility_status, 'intentional_silence');
    now += 5000;
    assert.equal((await missingRuntime.process(absent.entry.key, absent.entry.jobId)).status, 'cancelled_reconciled');
    current = missingRuntime.readState(absent.entry.key);
    record = current.outgoing[absent.fingerprint];
    job = current.jobs.find((item) => item.id === absent.entry.jobId);
    assert.equal(exactMisses, 2);
    assert.equal(record.status, 'cancelled');
    assert.equal(record.confirmed_absent_at, now);
    assert.equal(Object.hasOwn(record, 'body'), false);
    assert.equal(job.status, 'cancelled');
    assert.equal(job.responsibility_status, 'intentional_silence');
    assert.equal(sendAttempts, attemptsAfterAbort, '两次精确 404 只能取消未知记录，不能再次 POST');

    const foundSession = 'session_crisp-send-race-found';
    const found = await interruptAfterPostStarted(foundSession);
    const attemptsBeforeFound = sendAttempts;
    const modelsBeforeFound = modelRequests.length;
    const visibleBeforeFound = sent.filter((item) => item.session_id === foundSession).length;
    const analyticsBeforeFound = analyticsEvents();
    const lateDeliveriesBeforeFound = countEventsIn(
      analyticsBeforeFound, 'delivery_after_state_change');
    const permitLossesBeforeFound = countEventsIn(analyticsBeforeFound, 'processing_permit_lost');
    const foundJobBefore = runtime.readState(found.entry.key).jobs
      .find((item) => item.id === found.entry.jobId);
    assert(foundJobBefore);
    assert.equal(countedFlag(foundJobBefore.delivery_state_change_counted), 'absent',
      '精确对账前不得预先标记迟到投递已计数');
    const analyticsLock = path.join(root, 'data/analytics/.events.lock');
    const analyticsLockBeforeFound = fs.existsSync(analyticsLock);
    assert.equal(analyticsLockBeforeFound, false, '精确对账前不得遗留统计锁');
    let exactHits = 0;
    const foundRuntime = createRuntime(env, { ...runtimeOptions, request: async (url, options = {}) => {
      const parsed = new URL(url);
      const match = parsed.pathname.match(/\/conversation\/([^/]+)(\/.*)$/);
      if (match && decodeURIComponent(match[1]) === foundSession
        && match[2] === '/message/' + found.fingerprint) {
        exactHits += 1;
        return { status: 200, body: { error: false, data: {
          ...found.body, fingerprint: Number(found.fingerprint), timestamp: now - 1000,
        } } };
      }
      return request(url, options);
    } });
    now += 10000;
    assert.equal((await foundRuntime.process(found.entry.key, found.entry.jobId)).status, 'dispatched_after_cancel');
    current = foundRuntime.readState(found.entry.key);
    record = current.outgoing[found.fingerprint];
    job = current.jobs.find((item) => item.id === found.entry.jobId);
    assert.equal(exactHits, 1);
    assert.equal(record.status, 'sent');
    assert.equal(record.delivery_identity_version, 1);
    assert.equal(record.semantic_intent, 'answer');
    assert.equal(record.semantic_status, 'valid_answer');
    assert.equal(record.state_changed_before_receipt, true);
    assert.equal(record.receipt_current, false);
    assert.equal(record.receipt_state_change_reason, 'conversation_state_changed');
    assert.equal(record.receipt_identity_unbound, undefined);
    assert.equal(Object.hasOwn(record, 'body'), false);
    assert.equal(job.status, 'cancelled');
    assert.equal(job.responsibility_status, 'intentional_silence');
    assert.equal(job.responsibility_reason, 'human_reply');
    assert.equal(job.delivery_state_change_counted, true,
      '迟到送达事件必须与持久一次性标志在同一责任收尾中提交');
    assert.equal(job.delivery_state_change_counted_generation, 0,
      '迟到送达计数必须绑定发生时的回答代');
    assert.deepEqual(job.provider_settlement, found.providerSettlement,
      'Crisp 精确命中不得删除或改写独立的 Provider cleanup 故障证据');
    assert.equal(job.provider_retirement_failure_code,
      found.providerRetirementFailureCode);
    assert.equal(sendAttempts, attemptsBeforeFound, '精确命中只能收敛原 fingerprint，不能重新 POST');
    assert.equal(modelRequests.length, modelsBeforeFound,
      '精确命中只能收敛运输事实，不能重新推理');
    assert.equal(sent.filter((item) => item.session_id === foundSession).length,
      visibleBeforeFound, '人工接管后的精确命中不得新增可见消息');
    const analyticsAfterFound = analyticsEvents();
    assert.equal(countEventsIn(analyticsAfterFound, 'ai_reply'), normalReplies,
      '人工接管后的迟到送达不得计作正常 AI 回答');
    const lateDeliveriesAfterFound = countEventsIn(
      analyticsAfterFound, 'delivery_after_state_change');
    if (lateDeliveriesAfterFound !== lateDeliveriesBeforeFound + 1) {
      const newReasonCounts = { none: 0, attempt_superseded: 0, other: 0 };
      const newReasons = analyticsAfterFound
        .filter((event) => event.type === 'delivery_after_state_change')
        .slice(lateDeliveriesBeforeFound)
        .map((event) => event.reason === undefined ? 'none'
          : event.reason === 'attempt_superseded' ? 'attempt_superseded' : 'other');
      for (const reason of newReasons) newReasonCounts[reason] += 1;
      process.stderr.write('CRISPAI_WORKFLOW_DIAGNOSTIC ' + JSON.stringify({
        case: 'delivery_after_state_change_count',
        before: lateDeliveriesBeforeFound,
        after: lateDeliveriesAfterFound,
        delta: lateDeliveriesAfterFound - lateDeliveriesBeforeFound,
        job_flag_before: countedFlag(foundJobBefore.delivery_state_change_counted),
        job_flag_after: countedFlag(job.delivery_state_change_counted),
        job_status: ['cancelled', 'done', 'received', 'processing', 'failed'].includes(job.status)
          ? job.status : 'other',
        responsibility_status: ['intentional_silence', 'answered_confirmed',
          'unresolved_failure', 'pending'].includes(job.responsibility_status)
          ? job.responsibility_status : 'other',
        record_status: ['sent', 'unknown', 'sending', 'cancelled'].includes(record.status)
          ? record.status : 'other',
        receipt_current: typeof record.receipt_current === 'boolean'
          ? record.receipt_current : null,
        permit_lost_delta: countEventsIn(
          analyticsAfterFound, 'processing_permit_lost') - permitLossesBeforeFound,
        analytics_lock_before: analyticsLockBeforeFound,
        analytics_lock_after: fs.existsSync(analyticsLock),
        exact_hits: exactHits,
        new_reason_counts: newReasonCounts,
      }) + '\n');
    }
    assert.equal(lateDeliveriesAfterFound, lateDeliveriesBeforeFound + 1,
      '迟到送达必须只记录一次状态变化事实');
    assert.equal((await foundRuntime.process(found.entry.key, found.entry.jobId)).status, 'idle');
    assert.equal(exactHits, 1, '已确认的精确 wire 不得再次查询');
    assert.equal(sendAttempts, attemptsBeforeFound);
    assert.equal(modelRequests.length, modelsBeforeFound);
    assert.equal(countEvents('delivery_after_state_change'), lateDeliveriesBeforeFound + 1);

    // 模拟总开关曾关闭后又启用：配置已恢复，但旧任务的静默原因和
    // 已冻结 wire 事实仍必须保留。用真实 disable_epoch crossing 让 exact-hit
    // 自行推导回执不再属于当前责任；子例结束后逐字节恢复夹具配置。
    const disabledSession = 'session_crisp-send-race-global-disabled';
    const disabled = await interruptAfterPostStarted(disabledSession);
    const runtimeConfigPath = path.join(root, 'config/runtime.yaml');
    const runtimeConfigBeforeDisabled = fs.readFileSync(runtimeConfigPath);
    const materialsBeforeDisabled = fs.readFileSync(materialsPath);
    let disabledExactHits = 0;
    try {
      publishConfiguration('runtime', { schema_version: 2, enabled: false });
      publishConfiguration('runtime', { schema_version: 2, enabled: true });
      await runtime.transaction(disabled.entry.key, (currentState) => {
        const disabledJob = currentState.jobs.find((entry) => entry.id === disabled.entry.jobId);
        const disabledRecord = currentState.outgoing[disabled.fingerprint];
        assert(disabledJob && disabledRecord);
        assert.equal(Object.hasOwn(disabledJob, 'plan'), false);
        assert((readConfig('runtime').disable_epoch || 0)
          > (disabledJob.global_disable_epoch || 0),
        '总关后重启必须保留已跨过的禁用代次');
        for (const field of ['receipt_current', 'receipt_state_change_reason',
          'state_changed_before_receipt', 'receipt_confirmed_at']) {
          assert.equal(Object.hasOwn(disabledRecord, field), false,
            '精确回执前不得预写回执结论 ' + field);
        }
        currentState.mode = 'ai';
        currentState.generation = disabledJob.generation;
        currentState.resume_at = null;
        currentState.pause_reason = '';
        disabledJob.responsibility_reason = 'global_disabled';
        disabledRecord.cancellation_reason = 'global_disabled';
      });
      histories.set(disabledSession, (histories.get(disabledSession) || [])
        .filter((entry) => entry.from !== 'operator'));
      const attemptsBeforeDisabled = sendAttempts;
      const modelsBeforeDisabled = modelRequests.length;
      const visibleBeforeDisabled = sent.filter((item) => item.session_id === disabledSession).length;
      const repliesBeforeDisabled = countEvents('ai_reply');
      const lateDeliveriesBeforeDisabled = countEvents('delivery_after_state_change');
      const disabledRuntime = createRuntime(env, { ...runtimeOptions,
        request: async (url, options = {}) => {
          const parsed = new URL(url);
          const match = parsed.pathname.match(/\/conversation\/([^/]+)(\/.*)$/);
          if (match && decodeURIComponent(match[1]) === disabledSession
            && match[2] === '/message/' + disabled.fingerprint) {
            disabledExactHits += 1;
            return { status: 200, body: { error: false, data: {
              ...disabled.body, fingerprint: Number(disabled.fingerprint), timestamp: now - 1000,
            } } };
          }
          return request(url, options);
        } });
      now += 10000;
      assert.equal((await disabledRuntime.process(
        disabled.entry.key, disabled.entry.jobId)).status, 'dispatched_after_cancel');
      const disabledState = disabledRuntime.readState(disabled.entry.key);
      const disabledRecord = disabledState.outgoing[disabled.fingerprint];
      const disabledJob = disabledState.jobs.find((item) => item.id === disabled.entry.jobId);
      assert.equal(disabledExactHits, 1);
      assert.equal(disabledRecord.status, 'sent');
      assert.equal(disabledRecord.delivery_identity_version, 1);
      assert.equal(disabledRecord.semantic_intent, 'answer');
      assert.equal(disabledRecord.semantic_status, 'valid_answer');
      assert.equal(disabledRecord.receipt_current, false);
      assert.equal(disabledRecord.receipt_state_change_reason, 'global_disabled');
      assert.equal(disabledRecord.receipt_identity_unbound, undefined);
      assert.equal(Object.hasOwn(disabledRecord, 'body'), false);
      assert.equal(disabledJob.status, 'cancelled');
      assert.equal(disabledJob.responsibility_status, 'intentional_silence');
      assert.equal(disabledJob.responsibility_reason, 'global_disabled');
      assert.equal(disabledJob.delivery_state_change_counted, true,
        '总关后的迟到送达也必须持久化一次性计数标志');
      assert.equal(disabledJob.delivery_state_change_counted_generation, 0,
        '总关后的迟到送达计数必须绑定原回答代');
      assert.equal(Object.hasOwn(disabledJob, 'plan'), false);
      assert.deepEqual(disabledJob.provider_settlement, disabled.providerSettlement);
      assert.equal(disabledJob.provider_retirement_failure_code,
        disabled.providerRetirementFailureCode);
      assert.equal(sendAttempts, attemptsBeforeDisabled);
      assert.equal(modelRequests.length, modelsBeforeDisabled);
      assert.equal(sent.filter((item) => item.session_id === disabledSession).length,
        visibleBeforeDisabled);
      assert.equal(countEvents('ai_reply'), repliesBeforeDisabled);
      assert.equal(countEvents('delivery_after_state_change'),
        lateDeliveriesBeforeDisabled + 1);
      assert.equal((await disabledRuntime.process(
        disabled.entry.key, disabled.entry.jobId)).status, 'idle');
      assert.equal(disabledExactHits, 1);
    } finally {
      fs.writeFileSync(runtimeConfigPath, runtimeConfigBeforeDisabled);
      fs.writeFileSync(materialsPath, materialsBeforeDisabled);
    }
    assert(fs.readFileSync(runtimeConfigPath).equals(runtimeConfigBeforeDisabled));
    assert(fs.readFileSync(materialsPath).equals(materialsBeforeDisabled));

    const malformedPlans = [
      { label: 'null', value: null },
      { label: 'false', value: false },
      { label: 'array', value: [] },
      { label: 'empty-object', value: {} },
      { label: 'malformed-object', value: { type: 'text', purpose: 'ai_text',
        content: '不属于原出站的损坏计划', fingerprint: 'wrong-fingerprint' } },
    ];
    for (const item of malformedPlans) {
      const claimRejected = ['null', 'false', 'array'].includes(item.label);
      const session = 'session_crisp-send-race-plan-' + item.label;
      let tracked;
      try {
        tracked = await interruptAfterPostStarted(session);
      await runtime.transaction(tracked.entry.key, (currentState) => {
        const stored = currentState.jobs.find((entry) => entry.id === tracked.entry.jobId);
        assert(stored);
        assert.equal(Object.hasOwn(stored, 'plan'), false);
        stored.plan = structuredClone(item.value);
      });
      const beforeState = runtime.readState(tracked.entry.key);
      const beforeRecord = structuredClone(beforeState.outgoing[tracked.fingerprint]);
      const beforeProviderSettlement = structuredClone(beforeState.jobs
        .find((entry) => entry.id === tracked.entry.jobId).provider_settlement);
      const beforeProviderFailure = beforeState.jobs
        .find((entry) => entry.id === tracked.entry.jobId).provider_retirement_failure_code;
      const beforeMalformed = { posts: sendAttempts, models: modelRequests.length,
        visible: sent.filter((entry) => entry.session_id === session).length,
        replies: countEvents('ai_reply'),
        lateDeliveries: countEvents('delivery_after_state_change') };
      let exactHits = 0;
      const malformedRuntime = createRuntime(env, { ...runtimeOptions,
        request: async (url, options = {}) => {
          const parsed = new URL(url);
          const match = parsed.pathname.match(/\/conversation\/([^/]+)(\/.*)$/);
          if (match && decodeURIComponent(match[1]) === session
            && match[2] === '/message/' + tracked.fingerprint) {
            exactHits += 1;
            return { status: 200, body: { error: false, data: {
              ...tracked.body, fingerprint: Number(tracked.fingerprint), timestamp: now - 1000,
            } } };
          }
          return request(url, options);
        } });
      now += 10000;
      assert.equal((await malformedRuntime.process(
        tracked.entry.key, tracked.entry.jobId)).status,
      claimRejected ? 'deferred' : 'delivery_identity_unresolved',
      item.label + ': 字段存在但损坏的 plan 不得冒充政策删除');
      let malformedState = malformedRuntime.readState(tracked.entry.key);
      let malformedJob = malformedState.jobs.find((entry) => entry.id === tracked.entry.jobId);
      assert.equal(exactHits, claimRejected ? 0 : 1, item.label);
      assert.equal(malformedJob.status, 'cancelled', item.label);
      assert.equal(malformedJob.responsibility_status, 'intentional_silence', item.label);
      assert.equal(malformedJob.responsibility_reason, 'human_reply', item.label);
      assert.equal(Object.hasOwn(malformedJob, 'plan'), true, item.label);
      assert.deepEqual(malformedJob.plan, item.value, item.label);
      assert.deepEqual(malformedJob.provider_settlement, beforeProviderSettlement, item.label);
      assert.equal(malformedJob.provider_retirement_failure_code, beforeProviderFailure, item.label);
      assert.deepEqual(malformedState.outgoing[tracked.fingerprint], beforeRecord,
        item.label + ': 严格身份失败不得半迁移原 unknown 记录');
      if (claimRejected) {
        assert.equal(malformedJob.delivery_receipt_unknown, undefined, item.label);
      } else {
        assert.equal(malformedJob.delivery_receipt_unknown?.identity_status, 'unresolved', item.label);
        assert.equal(malformedJob.delivery_receipt_unknown?.resend_forbidden, true, item.label);
        assert.equal(malformedJob.failure_code, 'reconciliation_receipt_invalid', item.label);
        assert.equal(malformedJob.recovery_requires_review, true, item.label);
        assert(malformedJob.retry_at > now, item.label);
      }
      assert.deepEqual({ posts: sendAttempts, models: modelRequests.length,
        visible: sent.filter((entry) => entry.session_id === session).length,
        replies: countEvents('ai_reply'),
        lateDeliveries: countEvents('delivery_after_state_change') }, beforeMalformed, item.label);
      assert.equal((await malformedRuntime.process(
        tracked.entry.key, tracked.entry.jobId)).status,
      claimRejected ? 'deferred' : 'idle', item.label);
      malformedState = malformedRuntime.readState(tracked.entry.key);
      malformedJob = malformedState.jobs.find((entry) => entry.id === tracked.entry.jobId);
      assert.equal(exactHits, claimRejected ? 0 : 1,
        item.label + ': 失败关闭后不得再查或重发');
      assert.equal(malformedJob.status, 'cancelled', item.label);
      assert.equal(malformedJob.responsibility_status, 'intentional_silence', item.label);
      assert.deepEqual(malformedState.outgoing[tracked.fingerprint], beforeRecord, item.label);
      assert.deepEqual({ posts: sendAttempts, models: modelRequests.length,
        visible: sent.filter((entry) => entry.session_id === session).length,
        replies: countEvents('ai_reply'),
        lateDeliveries: countEvents('delivery_after_state_change') }, beforeMalformed, item.label);
      } finally {
        if (tracked) {
          const stateFile = path.join(root, 'data/runtime/session-' + tracked.entry.key + '.json');
          const bucket = path.join(root, 'data/runtime/owned-' + tracked.entry.key + '-'
            + (Number(tracked.fingerprint) % 256).toString(16).padStart(2, '0') + '.json');
          for (const file of [stateFile, bucket]) {
            if (!fs.existsSync(file)) continue;
            const stat = fs.lstatSync(file);
            assert(stat.isFile() && !stat.isSymbolicLink(), item.label + ': 测试清理目标必须是普通文件');
            fs.unlinkSync(file);
          }
          histories.delete(session);
          assert.equal(fs.existsSync(stateFile), false, item.label);
          assert.equal(fs.existsSync(bucket), false, item.label);
        }
      }
    }

    const cleanupTrackedSession = (tracked) => {
      const stateFile = path.join(root, 'data/runtime/session-' + tracked.entry.key + '.json');
      const bucket = path.join(root, 'data/runtime/owned-' + tracked.entry.key + '-'
        + (Number(tracked.fingerprint) % 256).toString(16).padStart(2, '0') + '.json');
      for (const file of [stateFile, bucket]) {
        if (!fs.existsSync(file)) continue;
        const stat = fs.lstatSync(file);
        assert(stat.isFile() && !stat.isSymbolicLink(), '故障窗口清理目标必须是普通文件');
        fs.unlinkSync(file);
      }
    };
    const reconcileWithPostCommitFailure = async (suffix, code) => {
      const session = 'session_crisp-send-race-post-commit-' + suffix;
      const tracked = await interruptAfterPostStarted(session);
      const stateFile = path.join(root, 'data/runtime/session-' + tracked.entry.key + '.json');
      const beforeState = runtime.readState(tracked.entry.key);
      const beforeJob = beforeState.jobs.find((entry) => entry.id === tracked.entry.jobId);
      const providerSettlement = structuredClone(beforeJob.provider_settlement);
      const providerFailure = beforeJob.provider_retirement_failure_code;
      const before = { posts: sendAttempts, models: modelRequests.length,
        visible: sent.filter((entry) => entry.session_id === session).length,
        replies: countEvents('ai_reply'), lateDeliveries: countEvents('delivery_after_state_change') };
      let exactHits = 0;
      let receiptCommitted = false;
      let injected = false;
      const originalRenameSync = fs.renameSync;
      const originalReadFileSync = fs.readFileSync;
      const failureRuntime = createRuntime(env, { ...runtimeOptions,
        request: async (url, options = {}) => {
          const parsed = new URL(url);
          const match = parsed.pathname.match(/\/conversation\/([^/]+)(\/.*)$/);
          if (match && decodeURIComponent(match[1]) === session
            && match[2] === '/message/' + tracked.fingerprint) {
            exactHits += 1;
            return { status: 200, body: { error: false, data: {
              ...tracked.body, fingerprint: Number(tracked.fingerprint), timestamp: now - 1000,
            } } };
          }
          return request(url, options);
        } });
      fs.renameSync = (source, target) => {
        if (target === stateFile) {
          try {
            const candidate = JSON.parse(originalReadFileSync(source, 'utf8'));
            const stored = candidate.jobs.find((entry) => entry.id === tracked.entry.jobId);
            const record = candidate.outgoing[tracked.fingerprint];
            if (stored?.status === 'processing'
              && stored.reconciliation_claim?.phase === 'settled'
              && record?.status === 'sent' && record.receipt_current === false
              && !Object.hasOwn(stored, 'delivery_state_change_counted')) receiptCommitted = true;
          } catch (_) {}
        }
        return originalRenameSync(source, target);
      };
      fs.readFileSync = (target, ...args) => {
        if (target === stateFile && receiptCommitted && !injected) {
          injected = true;
          const error = new Error('受控回执提交后故障');
          error.code = code;
          throw error;
        }
        return originalReadFileSync(target, ...args);
      };
      let result;
      try {
        now += 10000;
        result = await failureRuntime.process(tracked.entry.key, tracked.entry.jobId);
      } finally {
        fs.renameSync = originalRenameSync;
        fs.readFileSync = originalReadFileSync;
      }
      assert.equal(receiptCommitted, true, suffix + ': 必须先持久提交严格精确回执');
      assert.equal(injected, true, suffix + ': 必须命中回执提交后的故障窗口');
      if (code === 'PROCESSING_PERMIT_LOST') {
        assert.equal(result.status, 'dispatched_after_cancel', suffix);
      } else {
        assert.deepEqual(result, { status: 'deferred', reason: 'answer_responsibility_unresolved' }, suffix);
      }
      const current = failureRuntime.readState(tracked.entry.key);
      const stored = current.jobs.find((entry) => entry.id === tracked.entry.jobId);
      const record = current.outgoing[tracked.fingerprint];
      assert.equal(exactHits, 1, suffix);
      assert.equal(record.status, 'sent', suffix);
      assert.equal(record.receipt_current, false, suffix);
      assert.equal(stored.status, 'cancelled', suffix);
      assert.equal(stored.responsibility_status, 'intentional_silence', suffix);
      assert.equal(stored.delivery_state_change_counted, true, suffix);
      assert.equal(stored.delivery_state_change_counted_generation, 0, suffix);
      assert.equal(stored.execution_token, undefined, suffix);
      assert.equal(current.worker, null, suffix);
      assert.deepEqual(stored.provider_settlement, providerSettlement, suffix);
      assert.equal(stored.provider_retirement_failure_code, providerFailure, suffix);
      assert.deepEqual({ posts: sendAttempts, models: modelRequests.length,
        visible: sent.filter((entry) => entry.session_id === session).length,
        replies: countEvents('ai_reply') }, {
        posts: before.posts, models: before.models, visible: before.visible, replies: before.replies,
      }, suffix);
      assert.equal(countEvents('delivery_after_state_change'), before.lateDeliveries + 1, suffix);
      assert.equal((await failureRuntime.process(
        tracked.entry.key, tracked.entry.jobId)).status, 'idle', suffix);
      assert.equal(countEvents('delivery_after_state_change'), before.lateDeliveries + 1, suffix);
      cleanupTrackedSession(tracked);
      histories.delete(session);
    };
    await reconcileWithPostCommitFailure('permit-lost', 'PROCESSING_PERMIT_LOST');
    await reconcileWithPostCommitFailure('generic-eio', 'EIO');

    const absentPermitSession = 'session_crisp-send-race-absent-permit-lost';
    const absentPermit = await interruptAfterPostStarted(absentPermitSession);
    const absentPermitStateFile = path.join(root,
      'data/runtime/session-' + absentPermit.entry.key + '.json');
    const absentPermitBefore = { posts: sendAttempts, models: modelRequests.length,
      visible: sent.filter((entry) => entry.session_id === absentPermitSession).length,
      replies: countEvents('ai_reply'), lateDeliveries: countEvents('delivery_after_state_change') };
    const absentPermitInitial = runtime.readState(absentPermit.entry.key).jobs
      .find((entry) => entry.id === absentPermit.entry.jobId);
    const absentPermitSettlement = structuredClone(absentPermitInitial.provider_settlement);
    const absentPermitFailure = absentPermitInitial.provider_retirement_failure_code;
    let absentPermitMisses = 0;
    const absentPermitRuntime = createRuntime(env, { ...runtimeOptions,
      request: async (url, options = {}) => {
        const parsed = new URL(url);
        const match = parsed.pathname.match(/\/conversation\/([^/]+)(\/.*)$/);
        if (match && decodeURIComponent(match[1]) === absentPermitSession
          && match[2] === '/message/' + absentPermit.fingerprint) {
          absentPermitMisses += 1;
          return { status: 404, body: { error: true, reason: 'not_found' } };
        }
        return request(url, options);
      } });
    now += 10000;
    assert.equal((await absentPermitRuntime.process(
      absentPermit.entry.key, absentPermit.entry.jobId)).status, 'retry');
    assert.equal(absentPermitMisses, 1);
    const absentPermitRenameSync = fs.renameSync;
    const absentPermitReadFileSync = fs.readFileSync;
    let absentPermitCommitted = false;
    let absentPermitInjected = false;
    fs.renameSync = (source, target) => {
      if (target === absentPermitStateFile) {
        try {
          const candidate = JSON.parse(absentPermitReadFileSync(source, 'utf8'));
          const stored = candidate.jobs.find((entry) => entry.id === absentPermit.entry.jobId);
          const record = candidate.outgoing[absentPermit.fingerprint];
          if (stored?.status === 'processing'
            && stored.reconciliation_claim?.phase === 'settled'
            && record?.status === 'cancelled'
            && Number.isFinite(record.confirmed_absent_at)) absentPermitCommitted = true;
        } catch (_) {}
      }
      return absentPermitRenameSync(source, target);
    };
    fs.readFileSync = (target, ...args) => {
      if (target === absentPermitStateFile && absentPermitCommitted && !absentPermitInjected) {
        absentPermitInjected = true;
        const error = new Error('受控阴性回执提交后许可丢失');
        error.code = 'PROCESSING_PERMIT_LOST';
        throw error;
      }
      return absentPermitReadFileSync(target, ...args);
    };
    let absentPermitResult;
    try {
      now += 5000;
      absentPermitResult = await absentPermitRuntime.process(
        absentPermit.entry.key, absentPermit.entry.jobId);
    } finally {
      fs.renameSync = absentPermitRenameSync;
      fs.readFileSync = absentPermitReadFileSync;
    }
    assert.equal(absentPermitCommitted, true);
    assert.equal(absentPermitInjected, true);
    assert.equal(absentPermitResult.status, 'cancelled_reconciled');
    assert.equal(absentPermitMisses, 2);
    const absentPermitState = absentPermitRuntime.readState(absentPermit.entry.key);
    const absentPermitJob = absentPermitState.jobs
      .find((entry) => entry.id === absentPermit.entry.jobId);
    const absentPermitRecord = absentPermitState.outgoing[absentPermit.fingerprint];
    assert.equal(absentPermitRecord.status, 'cancelled');
    assert.equal(Object.hasOwn(absentPermitRecord, 'body'), false);
    assert.equal(absentPermitJob.status, 'cancelled');
    assert.equal(absentPermitJob.responsibility_status, 'intentional_silence');
    assert.equal(absentPermitJob.delivery_state_change_counted, undefined);
    assert.equal(absentPermitJob.execution_token, undefined);
    assert.equal(absentPermitState.worker, null);
    assert.deepEqual(absentPermitJob.provider_settlement, absentPermitSettlement);
    assert.equal(absentPermitJob.provider_retirement_failure_code, absentPermitFailure);
    assert.deepEqual({ posts: sendAttempts, models: modelRequests.length,
      visible: sent.filter((entry) => entry.session_id === absentPermitSession).length,
      replies: countEvents('ai_reply'), lateDeliveries: countEvents('delivery_after_state_change') },
    absentPermitBefore);
    assert.equal((await absentPermitRuntime.process(
      absentPermit.entry.key, absentPermit.entry.jobId)).status, 'idle');
    cleanupTrackedSession(absentPermit);
    histories.delete(absentPermitSession);

    const supersededSession = 'session_crisp-send-race-post-reconcile-superseded';
    const superseded = await interruptAfterPostStarted(supersededSession);
    const supersededStateFile = path.join(root,
      'data/runtime/session-' + superseded.entry.key + '.json');
    const supersededBefore = { posts: sendAttempts, models: modelRequests.length,
      visible: sent.filter((entry) => entry.session_id === supersededSession).length,
      replies: countEvents('ai_reply'), lateDeliveries: countEvents('delivery_after_state_change') };
    const originalRenameSync = fs.renameSync;
    const originalReadFileSync = fs.readFileSync;
    let supersededCommitted = false;
    let ownerReplaced = false;
    let postCommitStateReads = 0;
    let supersededExactHits = 0;
    let replacementJob;
    let replacementRecord;
    let replacementWorker;
    const newerToken = 'e'.repeat(24);
    const supersededRuntime = createRuntime(env, { ...runtimeOptions,
      request: async (url, options = {}) => {
        const parsed = new URL(url);
        const match = parsed.pathname.match(/\/conversation\/([^/]+)(\/.*)$/);
        if (match && decodeURIComponent(match[1]) === supersededSession
          && match[2] === '/message/' + superseded.fingerprint) {
          supersededExactHits += 1;
          return { status: 200, body: { error: false, data: {
            ...superseded.body, fingerprint: Number(superseded.fingerprint), timestamp: now - 1000,
          } } };
        }
        return request(url, options);
      } });
    fs.renameSync = (source, target) => {
      if (target === supersededStateFile) {
        try {
          const candidate = JSON.parse(originalReadFileSync(source, 'utf8'));
          const stored = candidate.jobs.find((entry) => entry.id === superseded.entry.jobId);
          const record = candidate.outgoing[superseded.fingerprint];
          if (stored?.status === 'processing'
            && stored.reconciliation_claim?.phase === 'settled'
            && record?.status === 'sent' && record.receipt_current === false
            && !Object.hasOwn(stored, 'delivery_state_change_counted')) supersededCommitted = true;
        } catch (_) {}
      }
      return originalRenameSync(source, target);
    };
    fs.readFileSync = (target, ...args) => {
      if (target === supersededStateFile && supersededCommitted && !ownerReplaced
        && ++postCommitStateReads === 4) {
        const candidate = JSON.parse(originalReadFileSync(target, 'utf8'));
        const stored = candidate.jobs.find((entry) => entry.id === superseded.entry.jobId);
        assert(stored && stored.execution_token !== newerToken);
        stored.execution_token = newerToken;
        stored.lease_until = now + 300000;
        candidate.worker = { job: stored.id, token: newerToken, until: now + 300000 };
        replacementJob = structuredClone(stored);
        replacementRecord = structuredClone(candidate.outgoing[superseded.fingerprint]);
        replacementWorker = structuredClone(candidate.worker);
        fs.writeFileSync(target, JSON.stringify(candidate));
        ownerReplaced = true;
      }
      return originalReadFileSync(target, ...args);
    };
    let supersededResult;
    try {
      now += 10000;
      supersededResult = await supersededRuntime.process(
        superseded.entry.key, superseded.entry.jobId);
    } finally {
      fs.renameSync = originalRenameSync;
      fs.readFileSync = originalReadFileSync;
    }
    assert.equal(supersededCommitted, true);
    assert.equal(ownerReplaced, true);
    assert.equal(postCommitStateReads, 4);
    assert.deepEqual(supersededResult,
      { status: 'deferred', reason: 'execution_superseded',
        key: superseded.entry.key, jobId: superseded.entry.jobId });
    const supersededState = supersededRuntime.readState(superseded.entry.key);
    const supersededJob = supersededState.jobs.find(
      (entry) => entry.id === superseded.entry.jobId);
    assert.equal(supersededExactHits, 1);
    assert.deepEqual(supersededState.outgoing[superseded.fingerprint], replacementRecord,
      '旧执行不得改写新 owner 接管前已冻结的 sent 回执');
    assert.deepEqual(supersededJob, replacementJob,
      '旧执行不得改写新 owner 持有的取消对账责任');
    assert.deepEqual(supersededState.worker, replacementWorker,
      '旧执行不得释放新 owner 的 worker');
    assert.deepEqual({ posts: sendAttempts, models: modelRequests.length,
      visible: sent.filter((entry) => entry.session_id === supersededSession).length,
      replies: countEvents('ai_reply'), lateDeliveries: countEvents('delivery_after_state_change') },
    supersededBefore);
    cleanupTrackedSession(superseded);
    histories.delete(supersededSession);

    await deliver(message('session_crisp-send-race-b', '另一会话继续工作'));
    assert.equal(sent.at(-1).session_id, 'session_crisp-send-race-b');
  });
  await test('P0 远端已收字节的迟到回执如实隔离，不记正常 AI 回复且旧 attempt 不覆盖新记录', async () => {
    const analytics = path.join(root, 'data/analytics/events.jsonl');
    const events = () => fs.existsSync(analytics) ? fs.readFileSync(analytics, 'utf8').trim().split('\n')
      .filter(Boolean).map(line => JSON.parse(line)) : [];
    const countEvents = type => events().filter(event => event.type === type).length;
    const countSupersededEvents = () => events().filter(event => event.type === 'delivery_after_state_change'
      && event.reason === 'attempt_superseded').length;
    const normalReplies = countEvents('ai_reply');
    const lateDeliveries = countEvents('delivery_after_state_change');
    let release;
    ignoreCrispAbort = true;
    delayedCrisp = new Promise((resolve) => { release = resolve; });
    const session = 'session_crisp-receipt-race';
    const attempts = sendAttempts;
    const entry = await receive(message(session, '模拟已写出字节的普通问题'));
    const pending = runtime.process(entry.key, entry.jobId);
    for (let tries = 0; tries < 200 && sendAttempts === attempts; tries += 1) await wait(5);
    assert.equal(sendAttempts, attempts + 1);
    const controlRuntime = createRuntime(env, runtimeOptions);
    now += 5;
    const human = { ...message(session, '另一实例确认人工已经接管', { from: 'operator', automated: false }), event: 'message:received' };
    const history = histories.get(session) || []; history.push(human.data); histories.set(session, history);
    const humanAccepted = await controlRuntime.receive({ body: human,
      query: { key: env.CRISP_WEBSITE_HOOK_SECRET } });
    assert.equal(humanAccepted.accepted, true);
    assert.equal(humanAccepted.route, 'process');
    release();
    const result = await pending;
    ignoreCrispAbort = false;
    assert.equal(result.status, 'dispatched_after_cancel');
    const outgoingPair = Object.entries(state(session).outgoing)
      .find(([, record]) => record.job_id === entry.jobId); assert(outgoingPair);
    const [lateFingerprint, outgoing] = outgoingPair;
    const lateJob = state(session).jobs.find((job) => job.id === entry.jobId);
    assert.equal(outgoing.status, 'sent');
    assert.equal(outgoing.state_changed_before_receipt, true);
    assert.equal(lateJob.delivery_state_change_counted, true,
      '原POST迟到回执必须与一次性计数标志原子提交');
    assert.equal(lateJob.delivery_state_change_counted_generation, 0,
      '原POST迟到回执计数必须绑定原回答代');
    assert.equal(countEvents('delivery_after_state_change'), lateDeliveries + 1);
    assert.equal(countEvents('ai_reply'), normalReplies, '状态变化后的迟到回执不能登记为正常 AI 回复');
    const frozenLateOutgoing = structuredClone(outgoing);
    const frozenLateSettlement = structuredClone(lateJob.provider_settlement);
    const frozenLateRetirement = structuredClone(lateJob.provider_retirement);
    const frozenLateRetirementFailure = lateJob.provider_retirement_failure_code;
    const postLateBaseline = { posts: sendAttempts, models: modelRequests.length,
      providers: providerRequests.length, retrievals: retrievalRequests.length,
      visible: sent.filter((item) => item.session_id === session).length,
      lateDeliveries: countEvents('delivery_after_state_change'),
      aiReplies: countEvents('ai_reply') };
    const controlCompletion = await runtime.process(entry.key, entry.jobId);
    assert.equal(controlCompletion.status, 'none',
      '旧任务已终结时应回退处理同会话尚未收尾的真人控制任务');
    assert.equal(controlCompletion.jobId, humanAccepted.jobId);
    let afterControl = state(session);
    const handledControl = afterControl.jobs.find((job) => job.id === humanAccepted.jobId);
    assert(handledControl);
    assert.equal(handledControl.status, 'done');
    assert.equal(handledControl.responsibility_status, 'control_handled');
    assert.equal(handledControl.responsibility_reason, 'operator');
    let unchangedLateJob = afterControl.jobs.find((job) => job.id === entry.jobId);
    assert(unchangedLateJob);
    assert.equal(unchangedLateJob.status, 'cancelled');
    assert.equal(unchangedLateJob.responsibility_status, 'intentional_silence');
    assert.equal(unchangedLateJob.delivery_state_change_counted, true);
    assert.equal(unchangedLateJob.delivery_state_change_counted_generation, 0);
    assert.deepEqual(unchangedLateJob.provider_settlement, frozenLateSettlement);
    assert.deepEqual(unchangedLateJob.provider_retirement, frozenLateRetirement);
    assert.equal(unchangedLateJob.provider_retirement_failure_code,
      frozenLateRetirementFailure);
    assert.deepEqual(afterControl.outgoing[lateFingerprint], frozenLateOutgoing);
    assert.deepEqual({ posts: sendAttempts, models: modelRequests.length,
      providers: providerRequests.length, retrievals: retrievalRequests.length,
      visible: sent.filter((item) => item.session_id === session).length,
      lateDeliveries: countEvents('delivery_after_state_change'),
      aiReplies: countEvents('ai_reply') }, postLateBaseline,
      '真人控制任务收尾不得重放推理、检索、Provider、Crisp POST或统计事件');
    assert.equal((await runtime.process(entry.key, entry.jobId)).status, 'idle');
    afterControl = state(session);
    unchangedLateJob = afterControl.jobs.find((job) => job.id === entry.jobId);
    assert(unchangedLateJob);
    assert.equal(unchangedLateJob.delivery_state_change_counted, true);
    assert.equal(unchangedLateJob.delivery_state_change_counted_generation, 0);
    assert.deepEqual(afterControl.outgoing[lateFingerprint], frozenLateOutgoing);
    assert.deepEqual({ posts: sendAttempts, models: modelRequests.length,
      providers: providerRequests.length, retrievals: retrievalRequests.length,
      visible: sent.filter((item) => item.session_id === session).length,
      lateDeliveries: countEvents('delivery_after_state_change'),
      aiReplies: countEvents('ai_reply') }, postLateBaseline,
      '重复处理原任务不得新增任何模型、网络、可见消息或统计事实');
    assert.equal(countEvents('delivery_after_state_change'), lateDeliveries + 1,
      '重复处理已收敛的迟到回执不得重复计数');

    ignoreCrispAbort = true;
    delayedCrisp = new Promise((resolve) => { release = resolve; });
    const invalidCountSession = 'session_crisp-receipt-race-invalid-count';
    let invalidCountAbortResolve;
    const invalidCountAbort = new Promise((resolve) => { invalidCountAbortResolve = resolve; });
    const invalidRuntime = createRuntime(env, { ...runtimeOptions,
      request: async (url, options = {}) => {
        const parsed = new URL(url);
        const match = parsed.pathname.match(/\/conversation\/([^/]+)(\/.*)$/);
        if (match && decodeURIComponent(match[1]) === invalidCountSession
          && match[2] === '/message' && options.method === 'POST') {
          if (options.signal?.aborted) invalidCountAbortResolve();
          else options.signal?.addEventListener('abort', invalidCountAbortResolve, { once: true });
        }
        return request(url, options);
      } });
    const invalidCountAttempts = sendAttempts;
    const invalidCountReplies = countEvents('ai_reply');
    const invalidCountLateDeliveries = countEvents('delivery_after_state_change');
    const invalidCountBody = message(invalidCountSession, '模拟畸形迟到投递计数标志');
    const invalidCountEntry = await invalidRuntime.receive({ body: invalidCountBody,
      query: { key: env.CRISP_WEBSITE_HOOK_SECRET } });
    const invalidCountPending = invalidRuntime.process(
      invalidCountEntry.key, invalidCountEntry.jobId);
    for (let tries = 0; tries < 200 && sendAttempts === invalidCountAttempts; tries += 1) await wait(5);
    assert.equal(sendAttempts, invalidCountAttempts + 1,
      '畸形计数子例必须先进入同一个受控 Crisp POST');
    const invalidControlRuntime = createRuntime(env, runtimeOptions);
    now += 5;
    const invalidHuman = { ...message(invalidCountSession, '另一实例确认人工接管畸形计数子例', {
      from: 'operator', automated: false,
    }), event: 'message:received' };
    const invalidHistory = histories.get(invalidCountSession) || [];
    invalidHistory.push(invalidHuman.data); histories.set(invalidCountSession, invalidHistory);
    await invalidControlRuntime.receive({ body: invalidHuman,
      query: { key: env.CRISP_WEBSITE_HOOK_SECRET } });
    let invalidCountFingerprint;
    await invalidRuntime.transaction(invalidCountEntry.key, (current) => {
      const stored = current.jobs.find((job) => job.id === invalidCountEntry.jobId); assert(stored);
      const pair = Object.entries(current.outgoing)
        .find(([, record]) => record.job_id === invalidCountEntry.jobId); assert(pair);
      [invalidCountFingerprint] = pair;
      assert.equal(pair[1].status, 'unknown');
      stored.delivery_state_change_counted = false;
    });
    await awaitNamedGate(invalidCountAbort,
      '畸形计数子例的原出站已观察到人工接管取消');
    release();
    const invalidCountResult = await invalidCountPending;
    ignoreCrispAbort = false;
    assert.equal(invalidCountResult.status, 'cancelled',
      '畸形计数标志必须回滚 sent 候选并保持政策取消');
    const invalidCountState = invalidRuntime.readState(invalidCountEntry.key);
    const invalidCountJob = invalidCountState.jobs.find(
      (job) => job.id === invalidCountEntry.jobId); assert(invalidCountJob);
    const invalidCountRecord = invalidCountState.outgoing[invalidCountFingerprint];
    assert.equal(invalidCountJob.status, 'cancelled');
    assert.equal(invalidCountJob.responsibility_status, 'intentional_silence');
    assert.equal(invalidCountJob.delivery_state_change_counted, false,
      '畸形计数标志不得被迟到回执静默改成 true');
    assert.equal(Object.hasOwn(invalidCountJob,
      'delivery_state_change_counted_generation'), false,
      '畸形布尔标志不得被失败的回执事务补造代次绑定');
    assert.equal(invalidCountRecord.status, 'unknown',
      '计数标志畸形时 sent 候选与回执字段必须整笔回滚');
    assert.equal(Object.hasOwn(invalidCountRecord, 'receipt_current'), false);
    assert(invalidCountRecord.body, '失败关闭后仍须保留同 fingerprint 正文供只读对账');
    assert.equal(countEvents('delivery_after_state_change'), invalidCountLateDeliveries);
    assert.equal(countEvents('ai_reply'), invalidCountReplies);
    assert.equal(sendAttempts, invalidCountAttempts + 1, '失败关闭不得发起第二次 POST');
    const invalidCountStateFile = path.join(root,
      'data/runtime/session-' + invalidCountEntry.key + '.json');
    const invalidCountBucket = path.join(root, 'data/runtime/owned-' + invalidCountEntry.key + '-'
      + (Number(invalidCountFingerprint) % 256).toString(16).padStart(2, '0') + '.json');
    for (const file of [invalidCountStateFile, invalidCountBucket]) {
      if (!fs.existsSync(file)) continue;
      const stat = fs.lstatSync(file);
      assert(stat.isFile() && !stat.isSymbolicLink(), '畸形计数子例清理目标必须是普通文件');
      fs.unlinkSync(file);
    }
    histories.delete(invalidCountSession);

    ignoreCrispAbort = true;
    delayedCrisp = new Promise((resolve) => { release = resolve; });
    const fencedSession = 'session_crisp-attempt-fence';
    const fencedAttempts = sendAttempts;
    const fencedNormalReplies = countEvents('ai_reply');
    const fencedLateDeliveries = countEvents('delivery_after_state_change');
    const fencedSupersededDeliveries = countSupersededEvents();
    const fenced = await receive(message(fencedSession, '模拟旧实例迟到回执'));
    const fencedPending = runtime.process(fenced.key, fenced.jobId);
    for (let tries = 0; tries < 200 && sendAttempts === fencedAttempts; tries += 1) await wait(5);
    assert.equal(sendAttempts, fencedAttempts + 1, '旧 attempt 只能发起一次 POST');
    let replacement;
    let replacementRecord;
    let replacementJob;
    let replacementWorker;
    await runtime.transaction(fenced.key, current => {
      const record = Object.values(current.outgoing).find(value => value.job_id === fenced.jobId);
      const stored = current.jobs.find(value => value.id === fenced.jobId);
      const candidate = 'e'.repeat(32);
      const ownerCandidate = stored.execution_token === 'd'.repeat(24)
        ? 'c'.repeat(24) : 'd'.repeat(24);
      replacement = record.attempt_token === candidate ? 'f'.repeat(32) : candidate;
      assert.notEqual(record.attempt_token, replacement);
      assert.notEqual(stored.execution_token, ownerCandidate);
      record.attempt_token = replacement;
      record.status = 'sending';
      stored.status = 'processing';
      stored.execution_token = ownerCandidate;
      stored.lease_until = now + 300000;
      current.worker = { job: stored.id, token: ownerCandidate, until: now + 300000 };
      replacementRecord = JSON.parse(JSON.stringify(record));
      replacementJob = JSON.parse(JSON.stringify(stored));
      replacementWorker = JSON.parse(JSON.stringify(current.worker));
    });
    release();
    const fencedResult = await fencedPending;
    ignoreCrispAbort = false;
    assert.equal(fencedResult.status, 'dispatched_after_cancel');
    const fencedState = state(fencedSession);
    const fencedRecord = Object.values(fencedState.outgoing).find(record => record.job_id === fenced.jobId);
    const fencedJob = fencedState.jobs.find(job => job.id === fenced.jobId);
    assert.deepEqual(fencedRecord, replacementRecord,
      '旧实例不得用迟到回执修改新 attempt 的任何持久字段');
    assert.equal(sendAttempts, fencedAttempts + 1, '迟到回执不得触发第二次 POST');
    assert.equal(countEvents('ai_reply'), fencedNormalReplies,
      '旧 attempt 的迟到回执不得登记为正常 AI 回复');
    assert.equal(countEvents('delivery_after_state_change'), fencedLateDeliveries + 1,
      '旧 attempt 只记录一次脱敏的发送代次变化事件');
    assert.equal(countSupersededEvents(), fencedSupersededDeliveries + 1);
    assert.deepEqual(fencedJob, replacementJob,
      '旧 worker 的回执及收尾都不能改写新 owner 持有的应答责任');
    assert.deepEqual(fencedState.worker, replacementWorker,
      '旧 worker 的收尾不能释放新 owner 的执行租约');
    assert.equal(fencedJob.status, 'processing');
    assert.equal(fencedJob.responsibility_status, 'pending');
    assert.notEqual(fencedJob.responsibility_status, 'answered_confirmed');
  });
  await test('P0 发送代次 token 只迁移真实旧版缺字段记录，现代空值、畸形、不对称与正文错配均关闭失败', async () => {
    const analytics = path.join(root, 'data/analytics/events.jsonl');
    const events = () => fs.existsSync(analytics) ? fs.readFileSync(analytics, 'utf8').trim().split('\n')
      .filter(Boolean).map(JSON.parse) : [];
    const countEvents = (type, reason) => events().filter((event) => event.type === type
      && (reason === undefined || event.reason === reason)).length;
    const gate = () => {
      let enter;
      let release;
      let released = false;
      const entered = new Promise((resolve) => { enter = resolve; });
      const waiting = new Promise((resolve) => { release = resolve; });
      return { entered, waiting, enter,
        release: () => { if (!released) { released = true; release(); } } };
    };
    const removeSessionState = (session) => {
      const file = path.join(root, 'data/runtime/session-' + key(session) + '.json');
      if (fs.existsSync(file)) fs.unlinkSync(file);
      histories.delete(session);
    };
    const prepareHistoryReceipt = async (session, options = {}) => {
      const identity = options.identity || 'legacy';
      const tokenPresent = options.tokenPresent === true;
      const token = options.token;
      const purpose = options.purpose || 'keyword_reply';
      assert(['legacy', 'modern'].includes(identity));
      runtime = createRuntime(env, runtimeOptions);
      const initial = await receive(message(session, '受控旧版回执责任'));
      assert.equal(initial.accepted, true);
      assert.equal(initial.route, 'process');
      const fingerprint = Number.parseInt(digest('legacy-delivery|' + session).slice(0, 12), 16);
      let body;
      await runtime.transaction(initial.key, (current) => {
        const job = current.jobs.find((item) => item.id === initial.jobId); assert(job);
        assert.equal(Object.keys(current.outgoing).length, 0);
        if (options.stateGeneration !== undefined) {
          current.generation = options.stateGeneration;
        }
        const content = '旧版已交给 Crisp 的确定性业务答复';
        const plan = { type: 'text', purpose, ordinary: true,
          ...(options.ai === true ? { ai: true } : {}), content, fingerprint };
        job.plan = plan;
        for (const field of ['inference', 'inference_generation', 'provider_result_receipt',
          'provider_settlement', 'provider_settlement_failure_code', 'provider_retirement',
          'provider_retirement_failure_code', 'provider_migration_from',
          'delivery_receipt_unknown']) delete job[field];
        if (options.jobExtras) Object.assign(job, structuredClone(options.jobExtras));
        body = { type: 'text', from: 'operator', origin: 'chat', automated: true,
          fingerprint, content };
        if (options.bodyExtras) Object.assign(body, structuredClone(options.bodyExtras));
        const record = { status: 'unknown', body: structuredClone(body),
          created_at: now - 20000, attempts: 1, job_id: job.id,
          generation: job.generation };
        if (identity === 'modern') Object.assign(record, {
          response_generation: 0, delivery_identity_version: 1,
          purpose: plan.purpose, message_type: plan.type, semantic_intent: 'answer',
          content_sha256: digest(canonical({ type: plan.type, content })),
        });
        if (options.recordExtras) Object.assign(record, structuredClone(options.recordExtras));
        if (tokenPresent) record.attempt_token = structuredClone(token);
        current.outgoing[String(fingerprint)] = record;
        job.status = 'received';
        job.responsibility_status = 'pending';
        job.retry_at = 0;
        job.lease_until = 0;
        delete job.failure_code;
        delete job.failure_since;
        delete job.last_failure_at;
        delete job.execution_token;
        current.worker = null;
      });
      const history = histories.get(session) || [];
      history.push({ ...body, timestamp: now });
      histories.set(session, history);
      return { ...initial, fingerprint, body };
    };

    const legacy = await prepareHistoryReceipt('session_attempt-token-legacy-missing');
    let snapshot = state('session_attempt-token-legacy-missing');
    let record = snapshot.outgoing[legacy.fingerprint];
    assert.equal(Object.hasOwn(record, 'attempt_token'), false);
    assert.equal(Object.hasOwn(record, 'delivery_identity_version'), false);
    let postBaseline = sendAttempts;
    let modelBaseline = modelRequests.length;
    assert.equal((await runtime.process(legacy.key, legacy.jobId)).status, 'sent');
    snapshot = state('session_attempt-token-legacy-missing');
    record = snapshot.outgoing[legacy.fingerprint];
    let job = snapshot.jobs.find((item) => item.id === legacy.jobId);
    assert.equal(record.status, 'sent');
    assert.equal(Object.hasOwn(record, 'body'), false);
    assert.equal(record.delivery_identity_version, 1);
    assert.match(record.attempt_token, /^[a-f0-9]{32}$/);
    assert(Number.isSafeInteger(record.legacy_delivery_identity_migrated_at));
    assert.equal(job.status, 'done');
    assert.equal(job.responsibility_status, 'answered_confirmed');
    assert.equal(sendAttempts, postBaseline, '旧版缺 token 字段的回执只能对账，不能重新 POST');
    assert.equal(modelRequests.length, modelBaseline, '已有计划的旧版回执不得重新推理');
    const migratedLegacyRecord = structuredClone(record);
    assert.equal((await runtime.process(legacy.key, legacy.jobId)).status, 'idle');
    assert.deepEqual(state('session_attempt-token-legacy-missing')
      .outgoing[legacy.fingerprint], migratedLegacyRecord,
      '重复处理不得改写已经严格迁移的 sent 身份');
    assert.equal(sendAttempts, postBaseline);
    assert.equal(modelRequests.length, modelBaseline);

    const legacyProvider = await prepareHistoryReceipt(
      'session_attempt-token-legacy-provider-missing', { purpose: 'ai_text', ai: true });
    postBaseline = sendAttempts;
    modelBaseline = modelRequests.length;
    assert.equal((await runtime.process(legacyProvider.key, legacyProvider.jobId)).status, 'sent');
    snapshot = state('session_attempt-token-legacy-provider-missing');
    record = snapshot.outgoing[legacyProvider.fingerprint];
    job = snapshot.jobs.find((item) => item.id === legacyProvider.jobId);
    assert.equal(record.delivery_identity_version, 1);
    assert.match(record.attempt_token, /^[a-f0-9]{32}$/);
    assert(Number.isSafeInteger(record.legacy_delivery_identity_migrated_at));
    assert.equal(record.status, 'sent');
    assert.equal(Object.hasOwn(record, 'body'), false);
    assert.equal(job.status, 'done');
    assert.equal(job.responsibility_status, 'answered_confirmed');
    assert.equal(sendAttempts, postBaseline,
      '旧版已缓存 Provider 正文只能凭精确回执迁移，不能再次 POST');
    assert.equal(modelRequests.length, modelBaseline,
      '旧版已缓存 Provider 正文不得触发第二次推理');

    const delayedLegacySession = 'session_attempt-token-legacy-provider-delayed-receipt';
    const delayedLegacy = await prepareHistoryReceipt(
      delayedLegacySession, { purpose: 'ai_text', ai: true });
    histories.set(delayedLegacySession, (histories.get(delayedLegacySession) || [])
      .filter((item) => String(item.fingerprint) !== String(delayedLegacy.fingerprint)));
    let delayedMessageReads = 0;
    let delayedExactReads = 0;
    runtime = createRuntime(env, { ...runtimeOptions, request: async (url, options = {}) => {
      const parsed = new URL(url);
      const match = parsed.pathname.match(/\/conversation\/([^/]+)(\/.*)$/);
      if (match && decodeURIComponent(match[1]) === delayedLegacySession) {
        if (match[2] === '/messages') delayedMessageReads += 1;
        if (match[2].startsWith('/message/')) {
          delayedExactReads += 1;
          return { status: 404, body: { error: true } };
        }
      }
      return request(url, options);
    } });
    postBaseline = sendAttempts;
    modelBaseline = modelRequests.length;
    assert.equal((await runtime.process(delayedLegacy.key, delayedLegacy.jobId)).status, 'retry');
    snapshot = state(delayedLegacySession);
    record = snapshot.outgoing[delayedLegacy.fingerprint];
    assert.equal(record.delivery_identity_version, 1);
    assert.match(record.attempt_token, /^[a-f0-9]{32}$/);
    assert(Number.isSafeInteger(record.legacy_delivery_identity_migrated_at));
    assert.equal(record.reconcile_misses, 1);
    assert.equal(delayedMessageReads, 1);
    assert.equal(delayedExactReads, 1);
    now += 5000;
    (histories.get(delayedLegacySession) || []).push({
      ...delayedLegacy.body, timestamp: now });
    assert.equal((await runtime.process(delayedLegacy.key, delayedLegacy.jobId)).status, 'sent');
    snapshot = state(delayedLegacySession);
    record = snapshot.outgoing[delayedLegacy.fingerprint];
    job = snapshot.jobs.find((item) => item.id === delayedLegacy.jobId);
    assert.equal(record.status, 'sent');
    assert.equal(job.status, 'done');
    assert.equal(job.responsibility_status, 'answered_confirmed');
    assert.equal(delayedMessageReads, 2);
    assert.equal(delayedExactReads, 1,
      '第二轮列表已经精确命中时不得再消耗 exact GET');
    assert.equal(sendAttempts, postBaseline);
    assert.equal(modelRequests.length, modelBaseline);
    runtime = createRuntime(env, runtimeOptions);

    const ambiguousProvider = await prepareHistoryReceipt(
      'session_attempt-token-legacy-provider-ambiguous', { purpose: 'ai_text', ai: true });
    let ambiguousOriginal;
    await runtime.transaction(ambiguousProvider.key, (current) => {
      const owner = current.jobs.find((item) => item.id === ambiguousProvider.jobId); assert(owner);
      ambiguousOriginal = structuredClone(current.outgoing[ambiguousProvider.fingerprint]);
      current.outgoing[String(ambiguousProvider.fingerprint + 1)] = {
        status: 'cancelled', created_at: now - 10000, attempts: 1,
        job_id: owner.id, generation: owner.generation,
      };
    });
    postBaseline = sendAttempts;
    modelBaseline = modelRequests.length;
    assert.equal((await runtime.process(
      ambiguousProvider.key, ambiguousProvider.jobId)).status, 'delivery_identity_unresolved');
    snapshot = state('session_attempt-token-legacy-provider-ambiguous');
    assert.deepEqual(snapshot.outgoing[ambiguousProvider.fingerprint], ambiguousOriginal,
      '同一旧责任存在第二条相关出站时不得挑选 tokenless 记录迁移');
    job = snapshot.jobs.find((item) => item.id === ambiguousProvider.jobId);
    assert.equal(job.status, 'received');
    assert.equal(job.responsibility_status, 'unresolved_failure');
    assert.equal(job.failure_code, 'delivery_identity_unresolved');
    assert.equal(sendAttempts, postBaseline);
    assert.equal(modelRequests.length, modelBaseline);
    removeSessionState('session_attempt-token-legacy-provider-ambiguous');

    const localFutureSession = 'session_attempt-token-local-future-conflict';
    const localFuture = await prepareHistoryReceipt(localFutureSession);
    let localFutureOriginal;
    await runtime.transaction(localFuture.key, (current) => {
      const owner = current.jobs.find((item) => item.id === localFuture.jobId); assert(owner);
      localFutureOriginal = structuredClone(current.outgoing[localFuture.fingerprint]);
      current.outgoing[String(localFuture.fingerprint + 1)] = {
        status: 'cancelled', created_at: now - 10000, attempts: 1,
        job_id: owner.id, generation: owner.generation, response_generation: 1,
      };
    });
    postBaseline = sendAttempts;
    modelBaseline = modelRequests.length;
    assert.equal((await runtime.process(localFuture.key, localFuture.jobId)).status,
      'delivery_semantic_unknown');
    snapshot = state(localFutureSession);
    assert.deepEqual(snapshot.outgoing[localFuture.fingerprint], localFutureOriginal,
      '同一旧责任的未来回答代记录不得被唯一性过滤后放行 tokenless 迁移');
    job = snapshot.jobs.find((item) => item.id === localFuture.jobId);
    assert.equal(job.status, 'received');
    assert.equal(job.responsibility_status, 'unresolved_failure');
    assert.equal(job.failure_code, 'delivery_semantic_unknown');
    assert.equal(sendAttempts, postBaseline);
    assert.equal(modelRequests.length, modelBaseline);
    removeSessionState(localFutureSession);

    for (const invalidProvider of [
      { suffix: 'legacy-empty', identity: 'legacy', tokenPresent: true, token: '' },
      { suffix: 'modern-missing', identity: 'modern', tokenPresent: false },
    ]) {
      const session = 'session_attempt-token-provider-invalid-' + invalidProvider.suffix;
      const prepared = await prepareHistoryReceipt(session, { purpose: 'ai_text', ai: true,
        identity: invalidProvider.identity, tokenPresent: invalidProvider.tokenPresent,
        token: invalidProvider.token });
      const frozen = structuredClone(state(session).outgoing[prepared.fingerprint]);
      postBaseline = sendAttempts;
      modelBaseline = modelRequests.length;
      assert.equal((await runtime.process(prepared.key, prepared.jobId)).status,
        'delivery_identity_unresolved');
      snapshot = state(session);
      assert.deepEqual(snapshot.outgoing[prepared.fingerprint], frozen,
        'Provider 兼容前门不得洗白显式空值或现代缺失 token');
      job = snapshot.jobs.find((item) => item.id === prepared.jobId);
      assert.equal(job.status, 'received');
      assert.equal(job.responsibility_status, 'unresolved_failure');
      assert.equal(job.failure_code, 'delivery_identity_unresolved');
      assert.equal(sendAttempts, postBaseline);
      assert.equal(modelRequests.length, modelBaseline);
      removeSessionState(session);
    }

    for (const malformed of [
      { suffix: 'legacy-empty', identity: 'legacy', tokenPresent: true, value: '' },
      { suffix: 'legacy-null', identity: 'legacy', tokenPresent: true, value: null },
      { suffix: 'legacy-object', identity: 'legacy', tokenPresent: true,
        value: { invalid: true } },
      { suffix: 'legacy-receipt-field', identity: 'legacy', tokenPresent: false,
        recordExtras: { receipt_current: false } },
      { suffix: 'legacy-feedback-marker', identity: 'legacy', tokenPresent: false,
        recordExtras: { legacy_feedback_wire_identity: true } },
      { suffix: 'legacy-job-generation-null', identity: 'legacy', tokenPresent: false,
        jobExtras: { response_generation: null } },
      { suffix: 'legacy-conversation-generation-negative', identity: 'legacy', tokenPresent: false,
        stateGeneration: -1, jobExtras: { generation: -1 } },
      { suffix: 'legacy-job-provider-marker', identity: 'legacy', tokenPresent: false,
        jobExtras: { provider_settlement: null } },
      { suffix: 'legacy-body-not-automated', identity: 'legacy', tokenPresent: false,
        bodyExtras: { automated: false } },
      { suffix: 'modern-missing', identity: 'modern', tokenPresent: false },
      { suffix: 'modern-empty', identity: 'modern', tokenPresent: true, value: '' },
    ]) {
      const session = 'session_attempt-token-malformed-' + malformed.suffix;
      const prepared = await prepareHistoryReceipt(session, { identity: malformed.identity,
        tokenPresent: malformed.tokenPresent, token: malformed.value,
        recordExtras: malformed.recordExtras, jobExtras: malformed.jobExtras,
        bodyExtras: malformed.bodyExtras, stateGeneration: malformed.stateGeneration });
      const before = state(session);
      const frozenRecord = structuredClone(before.outgoing[prepared.fingerprint]);
      assert.equal(Object.hasOwn(frozenRecord, 'attempt_token'), malformed.tokenPresent);
      if (malformed.tokenPresent) assert.deepEqual(frozenRecord.attempt_token, malformed.value);
      assert.equal(Object.hasOwn(frozenRecord, 'delivery_identity_version'),
        malformed.identity === 'modern');
      postBaseline = sendAttempts;
      modelBaseline = modelRequests.length;
      const replies = countEvents('ai_reply');
      const result = await runtime.process(prepared.key, prepared.jobId);
      assert.equal(result.status, 'delivery_semantic_unknown', malformed.suffix);
      snapshot = state(session);
      assert.deepEqual(snapshot.outgoing[prepared.fingerprint], frozenRecord,
        '畸形 token 的迟到回执不得改写持久出站记录');
      job = snapshot.jobs.find((item) => item.id === prepared.jobId);
      assert.equal(job.status, 'received');
      assert.equal(job.responsibility_status, 'unresolved_failure');
      assert.equal(job.failure_code, 'delivery_semantic_unknown');
      assert(job.data, '畸形 token 不得删除原访客责任');
      assert(job.plan, '畸形 token 不得删除仍需对账的冻结计划');
      assert.equal(sendAttempts, postBaseline);
      assert.equal(modelRequests.length, modelBaseline);
      assert.equal(countEvents('ai_reply'), replies);
      removeSessionState(session);
    }

    const receiptOnlySession = 'session_attempt-token-settlement-read-only';
    const receiptOnly = await prepareHistoryReceipt(receiptOnlySession, {
      jobExtras: { provider_settlement: null },
    });
    histories.set(receiptOnlySession, (histories.get(receiptOnlySession) || [])
      .filter((item) => String(item.fingerprint) !== String(receiptOnly.fingerprint)));
    let receiptOnlyLists = 0;
    let receiptOnlyExact = 0;
    runtime = createRuntime(env, { ...runtimeOptions, request: async (url, options = {}) => {
      const parsed = new URL(url);
      const match = parsed.pathname.match(/\/conversation\/([^/]+)(\/.*)$/);
      if (match && decodeURIComponent(match[1]) === receiptOnlySession) {
        if (match[2] === '/messages') receiptOnlyLists += 1;
        if (match[2] === '/message/' + receiptOnly.fingerprint) {
          receiptOnlyExact += 1;
          return { status: 404, body: { error: true } };
        }
      }
      return request(url, options);
    } });
    const receiptOnlyRecord = structuredClone(
      state(receiptOnlySession).outgoing[receiptOnly.fingerprint]);
    const receiptOnlyPlan = structuredClone(state(receiptOnlySession).jobs
      .find((item) => item.id === receiptOnly.jobId).plan);
    postBaseline = sendAttempts;
    modelBaseline = modelRequests.length;
    for (let attempt = 1; attempt <= 2; attempt += 1) {
      const result = await runtime.process(receiptOnly.key, receiptOnly.jobId);
      assert.equal(result.status, 'retry', '只读阴性对账第' + attempt + '轮');
      snapshot = state(receiptOnlySession);
      assert.deepEqual(snapshot.outgoing[receiptOnly.fingerprint], receiptOnlyRecord,
        '连续阴性不得改写、删除或重新登记原 outgoing');
      job = snapshot.jobs.find((item) => item.id === receiptOnly.jobId);
      assert.equal(job.status, 'received');
      assert.equal(job.responsibility_status, 'unresolved_failure');
      assert.equal(job.failure_code, 'provider_settlement_identity_unresolved');
      assert.equal(job.provider_settlement_failure_code,
        'provider_settlement_identity_unresolved');
      assert.equal(job.provider_settlement, null);
      assert.deepEqual(job.plan, receiptOnlyPlan);
      assert(job.data, '只读阴性对账不得清除原访客责任');
      assert.equal(job.retry_at, now + 300000,
        '坏 settlement 的只读核对必须给后续健康任务留下有界调度窗口');
      now = job.retry_at;
    }
    await runtime.transaction(receiptOnly.key, (current) => {
      const stored = current.jobs.find((item) => item.id === receiptOnly.jobId); assert(stored);
      stored.delivery_retries = 59;
    });
    assert.equal((await runtime.process(
      receiptOnly.key, receiptOnly.jobId)).status, 'unresolved');
    snapshot = state(receiptOnlySession);
    job = snapshot.jobs.find((item) => item.id === receiptOnly.jobId);
    assert.equal(job.status, 'failed');
    assert.equal(job.responsibility_status, 'unresolved_failure');
    assert.equal(job.failure_code, 'provider_settlement_identity_unresolved');
    assert.equal(job.delivery_retries, 60);
    assert.equal(job.retry_at, null);
    assert.equal(job.recovery_requires_review, true);
    assert(Number.isSafeInteger(
      job.provider_settlement_receipt_reconciliation_exhausted_at));
    assert.deepEqual(snapshot.outgoing[receiptOnly.fingerprint], receiptOnlyRecord);
    assert.equal(job.provider_settlement, null);
    assert.deepEqual(job.plan, receiptOnlyPlan);
    assert(job.data, '自动核对达到上限也必须保留原访客责任');
    assert.equal(receiptOnlyLists, 3);
    assert.equal(receiptOnlyExact, 3);
    assert.equal((await runtime.process(
      receiptOnly.key, receiptOnly.jobId)).status, 'idle');
    assert.equal(receiptOnlyLists, 3,
      '达到自动核对上限后显式处理也不得继续查询');
    assert.equal(receiptOnlyExact, 3);
    assert.equal(sendAttempts, postBaseline,
      '三次列表和精确404也不得授予新的 Crisp POST');
    assert.equal(modelRequests.length, modelBaseline,
      '坏 settlement 的只读对账不得重新推理');
    removeSessionState(receiptOnlySession);

    const positiveCapSession = 'session_attempt-token-settlement-positive-cap';
    const positiveCap = await prepareHistoryReceipt(positiveCapSession, {
      jobExtras: { provider_settlement: null },
    });
    await runtime.transaction(positiveCap.key, (current) => {
      const stored = current.jobs.find((item) => item.id === positiveCap.jobId); assert(stored);
      stored.delivery_retries = 59;
    });
    let positiveCapLists = 0;
    let positiveCapExact = 0;
    runtime = createRuntime(env, { ...runtimeOptions, request: async (url, options = {}) => {
      const parsed = new URL(url);
      const match = parsed.pathname.match(/\/conversation\/([^/]+)(\/.*)$/);
      if (match && decodeURIComponent(match[1]) === positiveCapSession) {
        if (match[2] === '/messages') positiveCapLists += 1;
        if (match[2].startsWith('/message/')) positiveCapExact += 1;
      }
      return request(url, options);
    } });
    const positiveCapRecord = structuredClone(
      state(positiveCapSession).outgoing[positiveCap.fingerprint]);
    const positiveCapPlan = structuredClone(state(positiveCapSession).jobs
      .find((item) => item.id === positiveCap.jobId).plan);
    postBaseline = sendAttempts;
    modelBaseline = modelRequests.length;
    assert.equal((await runtime.process(
      positiveCap.key, positiveCap.jobId)).status, 'unresolved');
    snapshot = state(positiveCapSession);
    assert.deepEqual(snapshot.outgoing[positiveCap.fingerprint], positiveCapRecord,
      '正向 wire 无法认领时也不得半迁移原记录');
    job = snapshot.jobs.find((item) => item.id === positiveCap.jobId);
    assert.equal(job.status, 'failed');
    assert.equal(job.responsibility_status, 'unresolved_failure');
    assert.equal(job.failure_code, 'delivery_semantic_unknown');
    assert.equal(job.provider_settlement_failure_code,
      'provider_settlement_identity_unresolved');
    assert.equal(job.delivery_retries, 60);
    assert.equal(job.retry_at, null);
    assert.equal(job.recovery_requires_review, true);
    assert(Number.isSafeInteger(
      job.provider_settlement_receipt_reconciliation_exhausted_at));
    assert.equal(job.provider_settlement, null);
    assert.deepEqual(job.plan, positiveCapPlan);
    assert(job.data);
    assert.equal(positiveCapLists, 1);
    assert.equal(positiveCapExact, 0,
      '列表正向命中后不得再调用精确端点');
    assert.equal(sendAttempts, postBaseline);
    assert.equal(modelRequests.length, modelBaseline);
    assert.equal((await runtime.process(
      positiveCap.key, positiveCap.jobId)).status, 'idle');
    const exhaustedState = structuredClone(state(positiveCapSession));
    const exhaustedScan = await runtime.scan();
    assert.equal(exhaustedScan.some((item) => item.key === positiveCap.key
      && item.jobId === positiveCap.jobId), false,
    '正向不可认领回执耗尽后 scanner 不得继续空转查询');
    assert.deepEqual(state(positiveCapSession), exhaustedState,
      '耗尽后的 scanner 不得再改写该会话');
    assert.equal(positiveCapLists, 1);
    assert.equal(positiveCapExact, 0);
    assert.equal(sendAttempts, postBaseline);
    assert.equal(modelRequests.length, modelBaseline);
    removeSessionState(positiveCapSession);

    const invalidTokenCaps = [];
    for (const item of [
      { suffix: 'empty', value: '' },
      { suffix: 'null', value: null },
      { suffix: 'object', value: { invalid: true } },
    ]) {
      const session = 'session_attempt-token-settlement-invalid-cap-' + item.suffix;
      const prepared = await prepareHistoryReceipt(session, {
        tokenPresent: true, token: item.value,
        jobExtras: { provider_settlement: null },
      });
      await runtime.transaction(prepared.key, (current) => {
        const stored = current.jobs.find((entry) => entry.id === prepared.jobId); assert(stored);
        stored.delivery_retries = 59;
      });
      invalidTokenCaps.push({ ...item, session, prepared,
        record: structuredClone(state(session).outgoing[prepared.fingerprint]),
        plan: structuredClone(state(session).jobs
          .find((entry) => entry.id === prepared.jobId).plan) });
    }
    const invalidTokenSessions = new Set(invalidTokenCaps.map((item) => item.session));
    let invalidTokenLists = 0;
    let invalidTokenExact = 0;
    runtime = createRuntime(env, { ...runtimeOptions, request: async (url, options = {}) => {
      const parsed = new URL(url);
      const match = parsed.pathname.match(/\/conversation\/([^/]+)(\/.*)$/);
      if (match && invalidTokenSessions.has(decodeURIComponent(match[1]))) {
        if (match[2] === '/messages') invalidTokenLists += 1;
        if (match[2].startsWith('/message/')) invalidTokenExact += 1;
      }
      return request(url, options);
    } });
    postBaseline = sendAttempts;
    modelBaseline = modelRequests.length;
    for (const item of invalidTokenCaps) {
      assert.equal((await runtime.process(
        item.prepared.key, item.prepared.jobId)).status, 'unresolved', item.suffix);
      snapshot = state(item.session);
      assert.deepEqual(snapshot.outgoing[item.prepared.fingerprint], item.record, item.suffix);
      job = snapshot.jobs.find((entry) => entry.id === item.prepared.jobId);
      assert.equal(job.status, 'failed', item.suffix);
      assert.equal(job.responsibility_status, 'unresolved_failure', item.suffix);
      assert.equal(job.failure_code, 'delivery_identity_unresolved', item.suffix);
      assert.equal(job.provider_settlement_failure_code,
        'provider_settlement_identity_unresolved', item.suffix);
      assert.equal(job.delivery_retries, 60, item.suffix);
      assert.equal(job.retry_at, null, item.suffix);
      assert.equal(job.provider_settlement, null, item.suffix);
      assert.deepEqual(job.plan, item.plan, item.suffix);
      assert(job.data, item.suffix);
      assert(Number.isSafeInteger(
        job.provider_settlement_receipt_reconciliation_exhausted_at), item.suffix);
      assert.equal((await runtime.process(
        item.prepared.key, item.prepared.jobId)).status, 'idle', item.suffix);
    }
    assert.equal(invalidTokenLists, invalidTokenCaps.length);
    assert.equal(invalidTokenExact, 0);
    assert.equal(sendAttempts, postBaseline);
    assert.equal(modelRequests.length, modelBaseline);
    const invalidTokenStates = new Map(invalidTokenCaps.map((item) =>
      [item.session, structuredClone(state(item.session))]));
    const invalidTokenScan = await runtime.scan();
    assert.equal(invalidTokenCaps.some((item) => invalidTokenScan.some((candidate) =>
      candidate.key === item.prepared.key && candidate.jobId === item.prepared.jobId)), false,
    '显式坏 token 的正向回执耗尽后 scanner 不得继续查询');
    for (const item of invalidTokenCaps) {
      assert.deepEqual(state(item.session), invalidTokenStates.get(item.session), item.suffix);
      removeSessionState(item.session);
    }
    assert.equal(invalidTokenLists, invalidTokenCaps.length);
    assert.equal(invalidTokenExact, 0);
    assert.equal(sendAttempts, postBaseline);
    assert.equal(modelRequests.length, modelBaseline);

    const atomicSession = 'session_attempt-token-settlement-finalization-atomic';
    const atomicPrepared = await prepareHistoryReceipt(atomicSession, {
      jobExtras: { provider_settlement: null },
    });
    histories.set(atomicSession, (histories.get(atomicSession) || [])
      .filter((item) => String(item.fingerprint) !== String(atomicPrepared.fingerprint)));
    const atomicStateFile = path.join(root, 'data/runtime',
      'session-' + atomicPrepared.key + '.json');
    const atomicRecord = structuredClone(
      state(atomicSession).outgoing[atomicPrepared.fingerprint]);
    const atomicPlan = structuredClone(state(atomicSession).jobs
      .find((item) => item.id === atomicPrepared.jobId).plan);
    let atomicClaimedState;
    let atomicArmed = false;
    let atomicFailuresRemaining = 2;
    let atomicInjected = 0;
    let atomicRenamesAfterExact = 0;
    let atomicAllowedReclassification = 0;
    let atomicLists = 0;
    let atomicExact = 0;
    runtime = createRuntime(env, { ...runtimeOptions, request: async (url, options = {}) => {
      const parsed = new URL(url);
      const match = parsed.pathname.match(/\/conversation\/([^/]+)(\/.*)$/);
      if (match && decodeURIComponent(match[1]) === atomicSession) {
        if (match[2] === '/messages') atomicLists += 1;
        if (match[2] === '/message/' + atomicPrepared.fingerprint) {
          atomicExact += 1;
          atomicClaimedState = structuredClone(state(atomicSession));
          atomicArmed = true;
          return { status: 404, body: { error: true } };
        }
      }
      return request(url, options);
    } });
    const unresolvedBeforeAtomic = countEvents('answer_responsibility_unresolved');
    postBaseline = sendAttempts;
    modelBaseline = modelRequests.length;
    const atomicRenameSync = fs.renameSync;
    fs.renameSync = function (source, destination) {
      if (atomicArmed && atomicFailuresRemaining > 0
        && path.resolve(String(destination)) === path.resolve(atomicStateFile)
        && String(source).startsWith(atomicStateFile + '.tmp-')) {
        atomicRenamesAfterExact += 1;
        if (atomicRenamesAfterExact === 1) {
          atomicAllowedReclassification += 1;
          atomicClaimedState = JSON.parse(fs.readFileSync(source, 'utf8'));
          return atomicRenameSync.apply(this, arguments);
        }
        atomicFailuresRemaining -= 1;
        atomicInjected += 1;
        const error = new Error('受控 receipt-only 最终状态提交失败');
        error.code = 'EIO';
        throw error;
      }
      return atomicRenameSync.apply(this, arguments);
    };
    let atomicFailure;
    try {
      atomicFailure = await runtime.process(atomicPrepared.key, atomicPrepared.jobId);
    } finally {
      fs.renameSync = atomicRenameSync;
    }
    assert.deepEqual(atomicFailure,
      { status: 'deferred', reason: 'answer_responsibility_unresolved' });
    assert.equal(atomicInjected, 2,
      '最终事务与异常收尾事务均须命中受控原子提交失败');
    assert.equal(atomicRenamesAfterExact, 3,
      '必须依次发布重分类、receipt-only 最终状态和异常收尾候选');
    assert.equal(atomicAllowedReclassification, 1,
      '精确放行中间无变化重分类后才可注入目标故障');
    assert(atomicClaimedState, '必须先冻结已持久领取的 processing 状态');
    assert.deepEqual(state(atomicSession), atomicClaimedState,
      '状态提交失败不得留下半次 receipt-only 结果');
    assert.equal(countEvents('answer_responsibility_unresolved'), unresolvedBeforeAtomic,
      '状态未提交时不得预写 unresolved 统计事件');
    now += 300001;
    assert.equal((await runtime.process(
      atomicPrepared.key, atomicPrepared.jobId)).status, 'retry');
    snapshot = state(atomicSession);
    assert.deepEqual(snapshot.outgoing[atomicPrepared.fingerprint], atomicRecord);
    job = snapshot.jobs.find((item) => item.id === atomicPrepared.jobId);
    assert.equal(job.status, 'received');
    assert.equal(job.failure_code, 'provider_settlement_identity_unresolved');
    assert.equal(job.provider_settlement, null);
    assert.deepEqual(job.plan, atomicPlan);
    assert(job.data);
    assert.equal(countEvents('answer_responsibility_unresolved'),
      unresolvedBeforeAtomic + 1,
    '状态成功提交后才允许追加一次 unresolved 事件');
    now = job.retry_at;
    assert.equal((await runtime.process(
      atomicPrepared.key, atomicPrepared.jobId)).status, 'retry');
    assert.equal(countEvents('answer_responsibility_unresolved'),
      unresolvedBeforeAtomic + 1,
    '同一 failure code 的后续核对不得重复统计');
    assert.equal(atomicLists, 3);
    assert.equal(atomicExact, 3);
    assert.equal(sendAttempts, postBaseline);
    assert.equal(modelRequests.length, modelBaseline);
    removeSessionState(atomicSession);

    const scannerSession = 'session_attempt-token-settlement-scanner';
    const scannerPrepared = await prepareHistoryReceipt(scannerSession, {
      jobExtras: { provider_settlement: null },
    });
    histories.set(scannerSession, (histories.get(scannerSession) || [])
      .filter((item) => String(item.fingerprint) !== String(scannerPrepared.fingerprint)));
    const healthy = await receive(message(scannerSession, '同会话后续健康任务'));
    assert.equal(healthy.accepted, true);
    assert.equal(healthy.route, 'process');
    const scannerRecord = structuredClone(
      state(scannerSession).outgoing[scannerPrepared.fingerprint]);
    const scannerPlan = structuredClone(state(scannerSession).jobs
      .find((item) => item.id === scannerPrepared.jobId).plan);
    const scannerData = structuredClone(state(scannerSession).jobs
      .find((item) => item.id === scannerPrepared.jobId).data);
    let scannerLists = 0;
    let scannerExact = 0;
    runtime = createRuntime(env, { ...runtimeOptions, request: async (url, options = {}) => {
      const parsed = new URL(url);
      const match = parsed.pathname.match(/\/conversation\/([^/]+)(\/.*)$/);
      if (match && decodeURIComponent(match[1]) === scannerSession) {
        if (match[2] === '/messages') scannerLists += 1;
        if (match[2] === '/message/' + scannerPrepared.fingerprint) {
          scannerExact += 1;
          return { status: 404, body: { error: true } };
        }
      }
      return request(url, options);
    } });
    postBaseline = sendAttempts;
    modelBaseline = modelRequests.length;
    const scannerHealth = path.join(root, 'data/runtime/scheduler-health.json');
    const scanFor = async (targetKey, targetJobId, label) => {
      const sessionFileCount = fs.readdirSync(path.join(root, 'data/runtime'))
        .filter((name) => /^session-[a-f0-9]{64}\.json$/.test(name)).length;
      const targetIdentity = targetKey + '\0' + targetJobId;
      const seenOrdinary = new Set();
      const baseline = { models: modelRequests.length, retrievals: retrievalRequests.length,
        posts: sendAttempts, visible: sent.length, lists: scannerLists, exact: scannerExact };
      let selected;
      for (let attempt = 0; attempt <= sessionFileCount && !selected; attempt += 1) {
        const previousCursor = JSON.parse(
          fs.readFileSync(scannerHealth, 'utf8')).ordinary_cursor;
        const scanned = await runtime.scan();
        const ordinary = scanned.filter((entry) => entry.control !== true);
        const currentCursor = JSON.parse(
          fs.readFileSync(scannerHealth, 'utf8')).ordinary_cursor;
        assert.equal(currentCursor, previousCursor + ordinary.length,
          label + ': 每轮必须按真实返回数推进普通公平游标');
        assert(ordinary.length > 0,
          label + ': 目标仍到期时必须保留至少一个普通任务槽');
        for (const entry of ordinary) {
          const identity = entry.key + '\0' + entry.jobId;
          if (identity === targetIdentity) { selected = entry; break; }
          assert(!seenOrdinary.has(identity),
            label + ': 目标获选前公平游标不得重复普通任务');
          seenOrdinary.add(identity);
        }
        const current = state(scannerSession);
        const blocked = current.jobs.find((item) => item.id === scannerPrepared.jobId);
        assert(blocked, label + ': 坏 settlement 责任必须持续存在');
        assert.deepEqual(current.outgoing[scannerPrepared.fingerprint], scannerRecord,
          label + ': 仅扫描不得改写原 outgoing');
        assert.equal(blocked.provider_settlement, null);
        assert.deepEqual(blocked.plan, scannerPlan);
        assert.deepEqual(blocked.data, scannerData);
        assert.deepEqual({ models: modelRequests.length,
          retrievals: retrievalRequests.length, posts: sendAttempts,
          visible: sent.length, lists: scannerLists, exact: scannerExact }, baseline,
        label + ': 仅扫描不得检索、调用模型、读Crisp或产生出站');
      }
      assert.deepEqual(selected, { key: targetKey, jobId: targetJobId, control: false },
        label + ': 目标必须在受管会话数限定的公平轮转内获选');
      return selected;
    };
    let selected = await scanFor(scannerPrepared.key, scannerPrepared.jobId,
      '坏 settlement 首轮恢复');
    assert.equal((await runtime.process(
      selected.key, selected.jobId)).status, 'retry');
    snapshot = state(scannerSession);
    assert.deepEqual(snapshot.outgoing[scannerPrepared.fingerprint], scannerRecord,
      'scanner 恢复也不得半迁移畸形旧记录');
    job = snapshot.jobs.find((item) => item.id === scannerPrepared.jobId);
    assert.equal(job.provider_settlement, null);
    assert.equal(job.responsibility_status, 'unresolved_failure');
    assert.equal(job.failure_code, 'provider_settlement_identity_unresolved');
    const scannerRetryAt = job.retry_at;
    assert.equal(scannerRetryAt, now + 300000);
    now += 5000;
    selected = await scanFor(healthy.key, healthy.jobId,
      '坏责任退避期间的同会话健康任务');
    await runtime.transaction(scannerPrepared.key, (current) => {
      const index = current.jobs.findIndex((item) => item.id === healthy.jobId);
      assert(index >= 0);
      current.jobs.splice(index, 1);
    });
    now = scannerRetryAt;
    selected = await scanFor(scannerPrepared.key, scannerPrepared.jobId,
      '退避结束后的坏 settlement 恢复');
    assert.equal((await runtime.process(
      selected.key, selected.jobId)).status, 'retry');
    snapshot = state(scannerSession);
    assert.deepEqual(snapshot.outgoing[scannerPrepared.fingerprint], scannerRecord);
    job = snapshot.jobs.find((item) => item.id === scannerPrepared.jobId);
    assert.equal(job.provider_settlement, null);
    assert.equal(job.provider_settlement_failure_code,
      'provider_settlement_identity_unresolved');
    assert.equal(job.retry_at, now + 300000);
    assert.equal(scannerLists, 2);
    assert.equal(scannerExact, 2);
    assert.equal(sendAttempts, postBaseline);
    assert.equal(modelRequests.length, modelBaseline);
    removeSessionState(scannerSession);

    const emptyToNonemptySession = 'session_attempt-token-empty-to-nonempty';
    const emptyToNonempty = await prepareHistoryReceipt(emptyToNonemptySession);
    const historyGate = gate();
    let historyCalls = 0;
    runtime = createRuntime(env, { ...runtimeOptions, request: async (url, options = {}) => {
      const parsed = new URL(url);
      const match = parsed.pathname.match(/\/conversation\/([^/]+)(\/.*)$/);
      if (match && decodeURIComponent(match[1]) === emptyToNonemptySession
        && match[2] === '/messages' && historyCalls++ === 0) {
        historyGate.enter();
        await historyGate.waiting;
      }
      return request(url, options);
    } });
    let historyPending;
    try {
      const replies = countEvents('ai_reply');
      postBaseline = sendAttempts;
      modelBaseline = modelRequests.length;
      historyPending = runtime.process(emptyToNonempty.key, emptyToNonempty.jobId);
      await awaitNamedGate(historyGate.entered, '空 token 历史对账进入网络门');
      assert.equal(historyCalls, 1);
      assert.equal(Object.hasOwn(state(emptyToNonemptySession).outgoing[emptyToNonempty.fingerprint],
        'attempt_token'), false);
      let frozenRecord;
      await runtime.transaction(emptyToNonempty.key, (current) => {
        const currentRecord = current.outgoing[emptyToNonempty.fingerprint]; assert(currentRecord);
        currentRecord.attempt_token = 'a'.repeat(32);
        frozenRecord = structuredClone(currentRecord);
      });
      assert.equal(state(emptyToNonemptySession).outgoing[emptyToNonempty.fingerprint].attempt_token,
        'a'.repeat(32));
      historyGate.release();
      const result = await historyPending;
      assert.equal(result.status, 'delivery_semantic_unknown');
      snapshot = state(emptyToNonemptySession);
      assert.deepEqual(snapshot.outgoing[emptyToNonempty.fingerprint], frozenRecord,
        '空 caller 不得认领后来出现的非空 token');
      job = snapshot.jobs.find((item) => item.id === emptyToNonempty.jobId);
      assert.equal(job.status, 'received');
      assert.equal(job.responsibility_status, 'unresolved_failure');
      assert.equal(job.failure_code, 'delivery_semantic_unknown');
      assert(job.data);
      assert(job.plan);
      assert.equal(sendAttempts, postBaseline);
      assert.equal(modelRequests.length, modelBaseline);
      assert.equal(countEvents('ai_reply'), replies);
    } finally {
      historyGate.release();
      if (historyPending) await awaitNamedGate(historyPending.then(() => undefined, () => undefined),
        '空 token 历史对账收尾', 10000);
      runtime = createRuntime(env, runtimeOptions);
    }
    removeSessionState(emptyToNonemptySession);

    const frozenLegacySession = 'session_attempt-token-legacy-policy-freeze';
    const frozenLegacy = await prepareHistoryReceipt(frozenLegacySession);
    postBaseline = sendAttempts;
    modelBaseline = modelRequests.length;
    const lateEvents = countEvents('delivery_after_state_change');
    const aiReplies = countEvents('ai_reply');
    await operator(frozenLegacySession);
    snapshot = state(frozenLegacySession);
    record = snapshot.outgoing[frozenLegacy.fingerprint];
    job = snapshot.jobs.find((item) => item.id === frozenLegacy.jobId);
    assert.equal(snapshot.mode, 'human');
    assert.equal(record.status, 'unknown');
    assert.equal(record.delivery_identity_version, 1);
    assert.match(record.attempt_token, /^[a-f0-9]{32}$/);
    assert(Number.isSafeInteger(record.legacy_delivery_identity_migrated_at));
    assert.equal(record.delivery_uncertain, true);
    assert.equal(record.recovery_deferred, true);
    assert.equal(record.resend_forbidden, true);
    assert.equal(job.status, 'cancelled');
    assert.equal(job.responsibility_status, 'intentional_silence');
    assert.equal(sendAttempts, postBaseline);
    assert.equal(modelRequests.length, modelBaseline);
    now += 5000;
    assert.equal((await runtime.process(frozenLegacy.key, frozenLegacy.jobId)).status,
      'dispatched_after_cancel');
    snapshot = state(frozenLegacySession);
    record = snapshot.outgoing[frozenLegacy.fingerprint];
    job = snapshot.jobs.find((item) => item.id === frozenLegacy.jobId);
    assert.equal(record.status, 'sent');
    assert.equal(record.receipt_current, false);
    assert.equal(record.receipt_state_change_reason, 'conversation_state_changed');
    assert.equal(job.status, 'cancelled');
    assert.equal(job.responsibility_status, 'intentional_silence');
    assert.equal(countEvents('delivery_after_state_change'), lateEvents + 1);
    assert.equal(countEvents('ai_reply'), aiReplies);
    assert.equal(sendAttempts, postBaseline);
    assert.equal(modelRequests.length, modelBaseline);
    assert.equal((await runtime.process(frozenLegacy.key, frozenLegacy.jobId)).status, 'idle');

    const ambiguousFreezeSession = 'session_attempt-token-legacy-policy-ambiguous';
    const ambiguousFreeze = await prepareHistoryReceipt(ambiguousFreezeSession);
    const secondFingerprint = ambiguousFreeze.fingerprint + 1;
    await runtime.transaction(ambiguousFreeze.key, (current) => {
      const duplicate = structuredClone(current.outgoing[ambiguousFreeze.fingerprint]);
      duplicate.body.fingerprint = secondFingerprint;
      current.outgoing[String(secondFingerprint)] = duplicate;
    });
    postBaseline = sendAttempts;
    modelBaseline = modelRequests.length;
    await operator(ambiguousFreezeSession);
    snapshot = state(ambiguousFreezeSession);
    for (const candidateFingerprint of [ambiguousFreeze.fingerprint, secondFingerprint]) {
      record = snapshot.outgoing[candidateFingerprint];
      assert.equal(Object.hasOwn(record, 'attempt_token'), false);
      assert.equal(Object.hasOwn(record, 'delivery_identity_version'), false);
      assert.equal(record.receipt_identity_unbound, true);
      assert.equal(record.semantic_status, 'semantic_unknown');
    }
    job = snapshot.jobs.find((item) => item.id === ambiguousFreeze.jobId);
    assert.equal(snapshot.mode, 'human');
    assert.equal(job.status, 'cancelled');
    assert.equal(job.responsibility_status, 'intentional_silence');
    assert.equal(sendAttempts, postBaseline);
    assert.equal(modelRequests.length, modelBaseline);
    removeSessionState(ambiguousFreezeSession);

    const postCases = [
      { suffix: 'missing', mutate: (currentRecord) => { delete currentRecord.attempt_token; },
        assertShape: (currentRecord) => assert.equal(Object.hasOwn(currentRecord, 'attempt_token'), false),
        expected: 'delivery_semantic_unknown' },
      { suffix: 'empty', mutate: (currentRecord) => { currentRecord.attempt_token = ''; },
        assertShape: (currentRecord) => assert.equal(currentRecord.attempt_token, ''),
        expected: 'delivery_semantic_unknown' },
      { suffix: 'body-mismatch', mutate: (currentRecord, originalToken) => {
        currentRecord.attempt_token = originalToken === 'b'.repeat(32) ? 'c'.repeat(32) : 'b'.repeat(32);
      }, assertShape: (currentRecord) => assert.match(currentRecord.attempt_token, /^[bc]{32}$/),
      mutateBody: true, expected: 'delivery_semantic_unknown' },
    ];
    for (const item of postCases) {
      const session = 'session_attempt-token-post-' + item.suffix;
      const postGate = gate();
      let capturedBody;
      let postCalls = 0;
      runtime = createRuntime(env, { ...runtimeOptions, request: async (url, options = {}) => {
        const parsed = new URL(url);
        const match = parsed.pathname.match(/\/conversation\/([^/]+)(\/.*)$/);
        if (match && decodeURIComponent(match[1]) === session
          && match[2] === '/message' && options.method === 'POST') {
          postCalls += 1;
          capturedBody = options.body;
          postGate.enter();
          await postGate.waiting;
        }
        return request(url, options);
      } });
      let pending;
      try {
        const replies = countEvents('ai_reply');
        const superseded = countEvents('delivery_after_state_change', 'attempt_superseded');
        const sessionSent = sent.filter((entry) => entry.session_id === session).length;
        postBaseline = sendAttempts;
        modelBaseline = modelRequests.length;
        const entry = await receive(message(session, '受控发送代次竞态'));
        pending = runtime.process(entry.key, entry.jobId);
        await awaitNamedGate(postGate.entered, '非空 token Crisp POST 进入网络门');
        assert.equal(postCalls, 1);
        assert(capturedBody && typeof capturedBody.content === 'string');
        let frozenRecord;
        let originalBody;
        await runtime.transaction(entry.key, (current) => {
          const currentRecord = Object.values(current.outgoing)
            .find((candidate) => candidate.job_id === entry.jobId); assert(currentRecord);
          assert.match(currentRecord.attempt_token, /^[a-f0-9]{32}$/);
          const originalToken = currentRecord.attempt_token;
          originalBody = structuredClone(currentRecord.body);
          item.mutate(currentRecord, originalToken);
          assert.notEqual(currentRecord.attempt_token, originalToken);
          item.assertShape(currentRecord);
          frozenRecord = structuredClone(currentRecord);
        });
        if (item.mutateBody) {
          capturedBody.content += '（受控错配）';
          assert.notEqual(digest(JSON.stringify(capturedBody.content)),
            digest(JSON.stringify(originalBody.content)));
          assert.deepEqual(state(session).outgoing[String(capturedBody.fingerprint)].body, originalBody,
            '只允许修改已经离开持久层的受控请求副本');
        }
        postGate.release();
        const result = await pending;
        assert.equal(result.status, item.expected);
        snapshot = state(session);
        record = Object.values(snapshot.outgoing).find((candidate) => candidate.job_id === entry.jobId);
        assert.deepEqual(record, frozenRecord,
          '旧 POST 回执不得修改缺失、空值或新 token 持有的 record');
        job = snapshot.jobs.find((candidate) => candidate.id === entry.jobId);
        assert.notEqual(job.responsibility_status, 'answered_confirmed');
        assert(job.data, '发送代次冲突不得删除原访客责任');
        assert.equal(job.status, 'received');
        assert.equal(job.failure_code, 'delivery_semantic_unknown');
        assert.equal(postCalls, 1);
        assert.equal(sendAttempts, postBaseline + 1, '每个竞态子例只能交出一次 POST');
        assert.equal(modelRequests.length, modelBaseline + 1, '每个竞态子例只能生成一次答案');
        assert.equal(sent.filter((entry) => entry.session_id === session).length, sessionSent + 1);
        assert.equal(countEvents('ai_reply'), replies);
        assert.equal(countEvents('delivery_after_state_change', 'attempt_superseded'), superseded + 1);
        removeSessionState(session);
      } finally {
        postGate.release();
        if (pending) await awaitNamedGate(pending.then(() => undefined, () => undefined),
          '非空 token POST 竞态收尾', 10000);
        runtime = createRuntime(env, runtimeOptions);
      }
    }
  });
  await test('T29/T30 十秒截止、真人追加、访客与乱序不改时间', async () => {
    const handoff = readConfig('handoff'); handoff.handoff.resume_after_seconds = 10; publishConfiguration('handoff', handoff);
    const start = now += 100; await operator('session_timeline01');
    assert.equal(state('session_timeline01').resume_at, start + 10000);
    now = start + 5000; await deliver(message('session_timeline01', '访客消息')); assert.equal(state('session_timeline01').resume_at, start + 10000);
    now = start + 6000; await operator('session_timeline01'); assert.equal(state('session_timeline01').resume_at, start + 16000);
    await operator('session_timeline01', { timestamp: start + 2000 }); assert.equal(state('session_timeline01').resume_at, start + 16000);
    now = start + 10000; await runtime.list(); assert.equal(state('session_timeline01').mode, 'human');
    now = start + 16001; await runtime.scan(); assert.equal(state('session_timeline01').mode, 'ai'); await deliver(message('session_timeline01', '恢复后的新问题')); assert.equal(sent.at(-1).session_id, 'session_timeline01');
  });
  await test('P0 人工恢复后缺时间戳消息先精确核对，旧消息不补答而真正新消息仍回复', async () => {
    const session = 'session_exact-event-time';
    const start = now += 100;
    await operator(session);
    const resumeAt = state(session).resume_at;
    now = resumeAt + 1;
    await runtime.scan();
    assert.equal(state(session).mode, 'ai');
    assert.equal(state(session).control_watermark, resumeAt);

    const oldBody = message(session, '人工期内已发送但延迟投递的问题');
    const oldExact = { ...oldBody.data, timestamp: start + 1 };
    histories.set(session, [...(histories.get(session) || []), oldExact]);
    delete oldBody.timestamp; delete oldBody.data.timestamp;
    const oldAccepted = await runtime.receive({ body: oldBody, query: { key: env.CRISP_WEBSITE_HOOK_SECRET } });
    assert.equal(oldAccepted.route, 'process');
    assert.equal((await runtime.process(oldAccepted.key, oldAccepted.jobId)).status, 'discarded');
    assert.equal(state(session).jobs.find((job) => job.id === oldAccepted.jobId).status, 'done');

    const before = sent.filter((entry) => entry.session_id === session).length;
    const modelsBefore = modelRequests.length;
    const freshBody = message(session, '恢复后真正的新问题');
    const freshExact = { ...freshBody.data, timestamp: now + 1 };
    histories.set(session, [...(histories.get(session) || []), freshExact]);
    delete freshBody.timestamp; freshBody.data.timestamp = 'invalid-time';
    const freshAccepted = await runtime.receive({ body: freshBody, query: { key: env.CRISP_WEBSITE_HOOK_SECRET } });
    assert.equal(freshAccepted.route, 'process');
    assert.equal((await runtime.process(freshAccepted.key, freshAccepted.jobId)).status, 'sent');
    assert.equal(sent.filter((entry) => entry.session_id === session).length, before + 1);
    assert.equal(modelRequests.length, modelsBefore + 1);
    assert.equal(state(session).mode, 'ai');
  });
  await test('T30/T31 零秒人工重建runtime与八天后不丢失', async () => {
    const handoff = readConfig('handoff'); handoff.handoff.resume_after_seconds = 0; publishConfiguration('handoff', handoff);
    now += 100; await operator('session_permanent1'); assert.equal(state('session_permanent1').resume_at, null);
    now += 8 * 86400000; runtime = createRuntime(env, runtimeOptions); await runtime.scan(); assert.equal(state('session_permanent1').mode, 'human');
    const before = sent.length; await deliver(message('session_permanent1', '永久人工后问题')); assert.equal(sent.length, before);
  });
  await test('T32/T33 总开关关闭阻断在途且仍接收真人控制', async () => {
    let finish; delayed = new Promise((resolve) => { finish = resolve; }); const entry = await receive(message('session_globalrace', '慢回复'));
    const pending = runtime.process(entry.key, entry.jobId); await wait(20);
    publishConfiguration('runtime', { schema_version: 2, enabled: false });
    const before = sent.length; finish(); await pending; await deliver(message('session_globalnew1', '人工')); assert.equal(sent.length, before);
    now += 10; await operator('session_globalhuman'); assert.equal(state('session_globalhuman').mode, 'human');
    publishConfiguration('runtime', { schema_version: 2, enabled: true }); await deliver(message('session_globalhuman', '仍人工')); assert.equal(sent.length, before);
  });
  await test('T34/T35 欢迎独立、SDK事件与公开白名单按会话控制', async () => {
    const menu = readConfig('menu'); menu.welcome = { enabled: true, text: '自定义欢迎\n第二行 😀', trigger: 'widget_load', auto_open: true, show_menu: false }; publishConfiguration('menu', menu);
    const signal = { ...message('session_welcome001', ''), event: 'session:sync:events', data: { session_id: 'session_welcome001', events: [{ text: 'crispai_widget_load', timestamp: now }] } };
    await deliver(signal); assert.equal(sent.at(-1).content, menu.welcome.text); const before = sent.length;
    await deliver(signal); now += 1; signal.timestamp = now; await deliver(signal); assert.equal(sent.length, before);
    const publicOptions = await runtime.publicConfig({ website_id: env.CRISP_WEBSITE_ID, session_id: 'session_welcome001' }); assert.equal(publicOptions.auto_open, true); assert.deepEqual(Object.keys(publicOptions).sort(), ['auto_open', 'enabled', 'revision', 'trigger', 'welcome_enabled']);
    await operator('session_welcome001'); assert.equal((await runtime.publicConfig({ website_id: env.CRISP_WEBSITE_ID, session_id: 'session_welcome001' })).auto_open, false);
    menu.welcome.enabled = false; publishConfiguration('menu', menu); await deliver(message('session_welcomeoff', '普通问题')); assert(!sent.at(-1).content.includes('自定义欢迎'));
  });
  await test('T36 菜单原生选择、返回与人工二次确认', async () => {
    await deliver(message('session_menu0001', '菜单')); let card = sent.at(-1); assert.equal(card.type, 'picker');
    await deliver(click('session_menu0001', card, 0)); card = sent.at(-1); assert.match(card.content.text, /电脑/);
    await deliver(click('session_menu0001', card, 2)); card = sent.at(-1); assert.match(card.content.text, /请选择/);
    const humanIndex = card.content.choices.findIndex((choice) => choice.label.includes('人工'));
    await deliver(click('session_menu0001', card, humanIndex)); assert.equal(state('session_menu0001').mode, 'ai'); assert.equal(sent.at(-1).content.choices[0].label, '召唤人工客服');
    const invalid = readConfig('menu'); invalid.menus.main.options['8'] = { label: '循环', action: { type: 'menu', target: 'main' } }; assert.throws(() => runtime.validateConfig('menu', invalid), /循环|返回/);
    for (const [field, value] of [['confirm_label', '  '], ['cancel_label', '\t'], ['confirm_message', '\n ']]) {
      const keyword = readConfig('keyword'); keyword.rules[0][field] = value;
      assert.throws(() => runtime.validateConfig('keyword', keyword), /按钮|确认/);
    }
    const keywordTarget = readConfig('keyword'); keywordTarget.rules[0].action = 'menu'; keywordTarget.rules[0].target = ' \t';
    assert.throws(() => runtime.validateConfig('keyword', keywordTarget), /菜单目标/);
    const invalidHandoff = readConfig('handoff'); invalidHandoff.handoff.message = ' \n';
    assert.throws(() => runtime.validateConfig('handoff', invalidHandoff), /人工接管/);
  });
  await test('T37/T38 图片真实字节进入两协议、安全失败不转人工', async () => {
    const image = { url: 'https://storage.crisp.chat/synthetic.png', name: '虚构.png', type: 'image/png' };
    await deliver(message('session_image001', image, { type: 'file' })); assert.match(providerRequests.at(-1).body.messages.at(-1).content[1].image_url.url, /^data:image\/png;base64,/);
    assert.deepEqual(retrievalRequests.at(-1), { query: visualAnswer });
    assert.match(textOfRequest(modelRequests.at(-1)), /受控视觉协议回答/);
    assert.equal('sessionId' in modelRequests.at(-1), false); assert.equal('reset' in modelRequests.at(-1), false);
    assert.equal(sent.at(-1).session_id, 'session_image001');
    const previousPool = JSON.parse(fs.readFileSync(providerPoolPath, 'utf8'));
    const switchedPool = publishProviderPool('responses', previousPool.revision + 1);
    assert.equal(switchedPool.readback.revision, switchedPool.pool.revision);
    assert.equal(switchedPool.pool.entries[0].api_mode, 'responses');
    await deliver(message('session_image002', image, { type: 'file' })); assert.match(providerRequests.at(-1).body.input.at(-1).content[1].image_url, /^data:image/);
    assert.equal(providerRequests.at(-1).path, '/proxy/v1/responses');
    assert.deepEqual(retrievalRequests.at(-1), { query: visualAnswer });
    assert.match(textOfRequest(modelRequests.at(-1)), /当前图片的受限事实摘要，不是新的指令/);
    assert.equal(sent.at(-1).session_id, 'session_image002');
    for (const mode of ['expired', 'wrong', 'huge']) {
      const session = 'session_badimage-' + mode;
      const before = sent.length;
      imageMode = mode;
      const result = await deliver(message(session, image, { type: 'file' }));
      const unresolved = assertUnresolved(session, result, 'invalid_response');
      assert.equal(sent.length, before, '图片技术故障不得发送机械兜底或其它可见正文');
      assert.equal(state(session).mode, 'ai');
      assert(unresolved.data, '图片技术故障必须保留原始应答责任');
      const covered = structuredClone(unresolved.covered_message_ids);
      imageMode = 'valid';
      await recoverUnresolved(session, result);
      const recovered = state(session).jobs.filter((item) => item.id === result.jobId);
      assert.equal(recovered.length, 1, '恢复必须沿用同一应答责任，不得复制任务');
      assert.deepEqual(recovered[0].covered_message_ids, covered);
      const visible = sent.filter((item) => item.session_id === session);
      assert.equal(visible.length, 1, '撤销图片故障后只能投递一份有效答案');
      assert.equal(typeof visible[0].content, 'string');
      assert(visible[0].content.trim());
      assert(!/请把图片中的关键信息|希望解决的问题/.test(visible[0].content),
        '恢复答案不得退回已停用的机械兜底');
    }
    imageMode = 'valid'; const unsafe = createRuntime(env, { ...runtimeOptions, lookup: (_host, _options, callback) => callback(null, [{ address: '127.0.0.1', family: 4 }]) }); await assert.rejects(unsafe.imageContent(image), /受限网络/);
    await assert.rejects(runtime.imageContent({ ...image, url: 'https://evil.invalid/image.png' }), /安全校验/);
  });
  await test('T37 图片未在公开答案复述仍保留隔离上下文，重启、容量与过期边界', async () => {
    const session = 'session_image-memory-a';
    const image = { url: 'https://storage.crisp.chat/synthetic.png', name: '虚构.png', type: 'image/png' };
    const marker = '仅视觉可见的虚构蓝灯三闪';
    modelAnswerOverride = '请先执行第一步，再告诉我结果。';
    visualAnswer = marker + '图像合成细节'.repeat(500);
    await deliver(message(session, image, { type: 'file' }));
    assert.equal(state(session).image_context.length, 1);
    assert.equal(state(session).image_context[0].summary.length, 2000);
    assert(!JSON.stringify(state(session).image_context).includes(image.url));
    assert(!sent.at(-1).content.includes(marker));
    runtime = createRuntime(env, runtimeOptions);
    await deliver(message(session, '这是什么意思？'));
    assert.equal(textOfRequest(modelRequests.at(-1)).split(marker).length - 1, 1);
    assert.match(textOfRequest(modelRequests.at(-1)), /不可信客户资料/);
    assert.deepEqual(retrievalRequests.at(-1), { query: '这是什么意思？' });
    await deliver(message('session_image-memory-b', '独立访客提问'));
    assert(!textOfRequest(modelRequests.at(-1)).includes(marker));
    for (let index = 0; index < 3; index += 1) {
      visualAnswer = '新图片受控描述-' + index;
      await deliver(message(session, image, { type: 'file' }));
    }
    assert.equal(state(session).image_context.length, 3);
    assert(!state(session).image_context.some((entry) => entry.summary.includes(marker)));
    const before = now;
    now += 86400001;
    await runtime.transaction(key(session), () => {});
    assert.equal(state(session).image_context.length, 0);
    await deliver(message(session, '超过保留期的图片问题'));
    assert(!textOfRequest(modelRequests.at(-1)).includes('新图片受控描述-'));
    now = before;
    modelAnswerOverride = null; visualAnswer = '受控视觉协议回答';
  });
  await test('T27/T32 图片慢解析被人工或全局停用打断时不保存过期摘要、不发送', async () => {
    for (const reason of ['human', 'global']) {
      const session = 'session_image-race-' + reason;
      let release;
      delayedVision = new Promise((resolve) => { release = resolve; });
      const count = providerRequests.length;
      const pending = deliver(message(session, { url: 'https://storage.crisp.chat/synthetic.png', name: '虚构.png', type: 'image/png' }, { type: 'file' }));
      for (let tries = 0; tries < 200 && providerRequests.length === count; tries += 1) await wait(5);
      assert.equal(providerRequests.length, count + 1);
      if (reason === 'human') await operator(session);
      else { const global = readConfig('runtime'); global.enabled = false; publishConfiguration('runtime', global); }
      release(); await pending;
      assert.equal((state(session).image_context || []).length, 0);
      assert(!sent.some((item) => item.session_id === session));
      if (reason === 'human') assert.equal(state(session).mode, 'human');
      else { const global = readConfig('runtime'); global.enabled = true; publishConfiguration('runtime', global); }
    }
  });
  await test('T39 持久任务重启、重复Hook和发送结果未知对账', async () => {
    const body = message('session_recovery1', '持久接收'); const entry = await receive(body); assert.equal(entry.reason, '已持久接收');
    runtime = createRuntime(env, runtimeOptions); assert((await runtime.scan()).some((job) => job.jobId === entry.jobId));
    unknownSend = true; const before = sent.length; assert.equal((await runtime.process(entry.key, entry.jobId)).status, 'retry');
    now += 6000; await runtime.process(entry.key, entry.jobId); assert.equal(sent.length, before + 1);
    assert.equal((await receive(body)).reason, '重复事件已忽略');
    const file = path.join(root, 'data', 'runtime', 'session-' + entry.key + '.json'); assert.equal(fs.statSync(file).mode & 0o777, 0o600); assert(!fs.readFileSync(file, 'utf8').includes('持久接收'));
  });
  await test('T40/T41 标签并集、权限失败、检索未知与历史负反馈保留', async () => {
    await deliver(message('session_tags0001', '有资料的问题')); assert(segments.get('session_tags0001').includes('external-vip')); assert(segments.get('session_tags0001').includes('ai_replied')); assert(!segments.get('session_tags0001').includes('ai_resolved'));
    tagFailure = true; await deliver(message('session_tagsfail1', '标签失败正文仍发送')); assert.equal(sent.at(-1).session_id, 'session_tagsfail1'); tagFailure = false;
    const eventFile = path.join(root, 'data', 'analytics', 'events.jsonl');
    const readEvents = () => fs.existsSync(eventFile) ? fs.readFileSync(eventFile, 'utf8').trim().split('\n')
      .filter(Boolean).map(JSON.parse) : [];
    const countEvents = (type, reason) => readEvents().filter((event) => event.type === type
      && (reason === undefined || event.reason === reason)).length;
    const missBaseline = {
      question: countEvents('question'), hit: countEvents('knowledge_hit'), miss: countEvents('knowledge_miss'),
      unresolved: countEvents('answer_responsibility_unresolved', 'knowledge_miss'),
      replies: countEvents('ai_reply'), models: modelRequests.length,
      sent: sent.filter((entry) => entry.session_id === 'session_miss0001').length,
    };
    miss = true; const missResult = await deliver(message('session_miss0001', '知识未命中')); miss = false;
    assert.equal(sent.filter((entry) => entry.session_id === 'session_miss0001').length, missBaseline.sent);
    const missJob = assertUnresolved('session_miss0001', missResult, 'knowledge_miss');
    assert(missJob.data, '知识暂时不可用时必须保留原始应答责任');
    assert.equal(missJob.plan, undefined, '技术未完成不得持久成普通知识计划');
    assert.equal(Object.values(state('session_miss0001').outgoing)
      .filter((record) => record.job_id === missResult.jobId).length, 0);
    assert.equal(modelRequests.length, missBaseline.models, '知识未命中不得调用 Provider 伪造答案');
    assert.equal(countEvents('question'), missBaseline.question);
    assert.equal(countEvents('knowledge_hit'), missBaseline.hit);
    assert.equal(countEvents('knowledge_miss'), missBaseline.miss,
      '未完成的知识故障不能冒充普通 knowledge outcome');
    assert.equal(countEvents('answer_responsibility_unresolved', 'knowledge_miss'), missBaseline.unresolved + 1);
    assert.equal(countEvents('ai_reply'), missBaseline.replies);
    await recoverUnresolved('session_miss0001', missResult);
    const recoveredMissJob = state('session_miss0001').jobs.find((job) => job.id === missResult.jobId);
    assert.equal(recoveredMissJob.status, 'done');
    assert.equal(recoveredMissJob.responsibility_status, 'answered_confirmed');
    assert.equal(recoveredMissJob.knowledge_counted, true);
    assert.equal(countEvents('question'), missBaseline.question + 1);
    assert.equal(countEvents('knowledge_hit'), missBaseline.hit + 1);
    assert.equal(countEvents('knowledge_miss'), missBaseline.miss);
    assert.equal(countEvents('answer_responsibility_unresolved', 'knowledge_miss'), missBaseline.unresolved + 1);
    assert.equal(countEvents('ai_reply'), missBaseline.replies + 1);
    low = true; await deliver(message('session_low00001', '低分问题')); low = false;
    const beforeInvalidRetrieval = modelRequests.length;
    const beforeInvalidSend = sent.length; unknownSources = true;
    const invalidResult = await deliver(message('session_unknown1', '元数据缺失')); unknownSources = false;
    assert.equal(modelRequests.length, beforeInvalidRetrieval, '缺失来源元数据不可进入生成，也不能冒充无命中');
    assert.equal(sent.length, beforeInvalidSend); assertUnresolved('session_unknown1', invalidResult, 'retrieval_invalid');
    await recoverUnresolved('session_unknown1', invalidResult);
    const beforeModelSend = sent.length; modelFailure = true;
    const modelResult = await deliver(message('session_modelerror', '接口失败')); modelFailure = false;
    assert.equal(sent.length, beforeModelSend); assertUnresolved('session_modelerror', modelResult, 'upstream_unavailable');
    await recoverUnresolved('session_modelerror', modelResult);
    const historicalFeedback = { type: 'feedback', at: new Date(now).toISOString(), answer_id: 'synthetic-historical-answer', session: 'synthetic-history', question: '[历史问题指纹]', feedback: 'negative' };
    fs.appendFileSync(eventFile, JSON.stringify(historicalFeedback) + '\n');
    const modelCount = modelRequests.length;
    await deliver(message('session_negative1', 'token=synthetic-private-value 为什么失败')); await deliver(message('session_negative1', '👎')); assert.equal(state('session_negative1').mode, 'ai');
    assert.equal(modelRequests.length, modelCount + 2); assert.equal(state('session_negative1').pending_feedback, null);
    const events = readEvents();
    assert(events.some((event) => event.type === 'retrieval_failed' && event.reason === 'retrieval_invalid'));
    assert.deepEqual(events.filter((event) => event.type === 'feedback'), [historicalFeedback]);
    assert(!JSON.stringify(events).includes('synthetic-private-value')); assert.equal(state('session_modelerror').mode, 'ai');
  });
  await test('上下文单源、当前问题纯检索、独立生成和隐私过滤', async () => {
    const generated = modelRequests.find(entry => textOf(messagesOf(entry).at(-1)) === '恢复后的新问题');
    assert(generated); assert.match(textOfRequest(generated), /人工公开/);
    assert.equal(textOf(messagesOf(generated)[0]), fs.readFileSync(path.join(root, 'config/prompt.md'), 'utf8'));
    assert.equal(textOfRequest(generated).split('恢复后的新问题').length - 1, 1);
    assert.deepEqual(retrievalRequests.find(entry => entry.query === '恢复后的新问题'), { query: '恢复后的新问题' });
    assert.equal('sessionId' in generated, false); assert.equal('reset' in generated, false);
    const generic = '你最希望先解决哪一处？可以把具体情况、相关提示和已经尝试的方法一起告诉我。';
    const transcriptState = structuredClone(state('session_client-b'));
    transcriptState.outgoing['107'] = { status: 'sent', created_at: now };
    const prior = runtime.transcript([
      { from: 'operator', type: 'note', content: '内部内容', fingerprint: 100, timestamp: now },
      { from: 'operator', type: 'text', content: '秘密', stealth: true, timestamp: now },
      { from: 'user', type: 'text', content: '本条', fingerprint: 101, timestamp: now },
      { from: 'user', type: 'text', content: '公开', fingerprint: 102, timestamp: now },
      { from: 'operator', type: 'text', content: generic, automated: true, fingerprint: 103, timestamp: now },
      { from: 'operator', type: 'text', content: '暂时无法回复，请稍后再试。', automated: true, fingerprint: 104, timestamp: now },
      { from: 'operator', type: 'text', content: generic, automated: false, fingerprint: 105, timestamp: now },
      { from: 'operator', type: 'text', content: '此前已确认保存成功。', automated: true, fingerprint: 106, timestamp: now },
      { from: 'operator', type: 'text', content: generic, fingerprint: 107, timestamp: now },
      { from: 'user', type: 'text', content: generic, fingerprint: 108, timestamp: now },
      { from: 'operator', type: 'text', content: generic, fingerprint: 109, timestamp: now },
    ], { data: { fingerprint: 101 }, event_time: now }, transcriptState);
    assert.deepEqual(prior.map((message) => message.content), [
      '公开', '[人工公开回复] ' + generic, '此前已确认保存成功。', generic,
      '[人工公开回复] ' + generic,
    ]);
  });
  await test('旧版本持久人工迁移及永久模式保留', async () => {
    const session = 'session_legacy001'; const legacy = { version: 1, aiEnabled: false, aiResumeAt: 0, handoffGeneration: 3, lastOperatorAt: now, welcomeSent: true, fingerprints: [] };
    const legacyFile = path.join(root, 'data', 'runtime',
      'session-' + crypto.createHash('sha256').update(session).digest('hex') + '.json');
    const currentFile = path.join(root, 'data', 'runtime', 'session-' + key(session) + '.json');
    fs.writeFileSync(legacyFile, JSON.stringify(legacy), { mode: 0o600 });
    try {
      await deliver(message(session, '迁移后不自动回复'));
      assert.equal(state(session).mode, 'human'); assert.equal(state(session).generation, 3);
      assert.equal(state(session).welcome_sent, true);
      assert.equal(fs.existsSync(currentFile), true, '迁移结果必须使用当前正式 stateKey');
    } finally {
      assert.notEqual(path.resolve(legacyFile), path.resolve(currentFile),
        'fixture teardown 绝不能删除正式状态文件');
      const legacyIdentity = fs.lstatSync(legacyFile);
      assert(legacyIdentity.isFile() && !legacyIdentity.isSymbolicLink());
      assert.equal(legacyIdentity.nlink, 1);
      assert.equal(legacyIdentity.uid, process.geteuid());
      fs.unlinkSync(legacyFile);
    }
    assert.equal(fs.existsSync(legacyFile), false, '本场景旧源文件不得污染后续严格 scanner');
  });
  await test('生产生成Code采用同一实现，SDK无密钥且状态决定展开', async () => {
    const workflow = JSON.parse(fs.readFileSync(path.join(project, 'n8n', 'workflow.json'), 'utf8'));
    const node = workflow.nodes.find((entry) => entry.name === '校验并持久接收');
    const scanNode = workflow.nodes.find((entry) => entry.name === '扫描持久会话与任务');
    assert(scanNode.parameters.jsCode.includes('const processing = Promise.all(jobs.map'));
    assert(scanNode.parameters.jsCode.includes('const catchingUp = runtime.catchup()'));
    assert(scanNode.parameters.jsCode.includes('Promise.all([processing,catchingUp])'),
      'REST 补偿不得串行阻塞已持久本地任务');
    const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
    const execute = new AsyncFunction('$input', '$env', 'require', node.parameters.jsCode.replace('createRuntime($env)', 'createRuntime($env, {root:' + JSON.stringify(root) + '})'));
    const response = await execute({ first: () => ({ json: { body: message('session_generated', '测试'), query: { key: 'invalid' } } }) }, env, require); assert.equal(response[0].json.statusCode, 401);
    const callbacks = {}; const emitted = []; const values = { enabled: true, welcome_enabled: true, auto_open: false, trigger: 'widget_load', revision: 1 };
    const sandbox = { window: { CRISP_WEBSITE_ID: env.CRISP_WEBSITE_ID, $crisp: { push: (entry) => entry[0] === 'on' ? callbacks[entry[1]] = entry[2] : emitted.push(entry) } }, document: { currentScript: { getAttribute: () => 'https://support.invalid/webhook/crispai-public-config' } }, URL, AbortController, setTimeout, clearTimeout, fetch: async () => ({ ok: true, json: async () => values }) };
    vm.runInNewContext(fs.readFileSync(path.join(project, 'n8n', 'web-chat.js'), 'utf8'), sandbox); await callbacks['session:loaded']('session_sdk0001'); assert(!emitted.some((entry) => entry[1] === 'chat:open'));
    values.auto_open = true; await callbacks['session:loaded']('session_sdk0002'); assert(emitted.some((entry) => entry[1] === 'chat:open'));
    assert(!JSON.stringify(emitted).includes(env.CRISP_WEBSITE_HOOK_SECRET));
  });
  await test('接入事实绑定当前凭据，协议端点不能冒充真实 Crisp', async () => {
    assert.equal((await runtime.observations()).hook_observed, true);
    const protocol = createRuntime({ ...env, CRISP_API_BASE_URL: 'http://127.0.0.1:18787/v1' }, runtimeOptions);
    assert.equal((await protocol.observations()).conversation_observed, false);
    assert.equal((await protocol.observations()).scope, 'protocol_or_custom_endpoint');
    const rotated = createRuntime({ ...env, CRISP_AUTH_B64: 'synthetic-rotated-credential' }, runtimeOptions);
    assert.equal((await rotated.observations()).hook_observed, false);
  });
  await test('统计保留天数实际清理旧事件，不清除永久人工状态', async () => {
    const feedback = readConfig('feedback'); feedback.feedback.retention_days = 1; publishConfiguration('feedback', feedback);
    const file = path.join(root, 'data/analytics/events.jsonl');
    fs.appendFileSync(file, JSON.stringify({ type: 'synthetic_expired', at: new Date(now - 172800000).toISOString() }) + '\n');
    fs.appendFileSync(file, JSON.stringify({ type: 'synthetic_current', at: new Date(now).toISOString() }) + '\n');
    await runtime.scan();
    assert(!fs.readFileSync(file, 'utf8').includes('synthetic_expired'));
    assert(fs.readFileSync(file, 'utf8').includes('synthetic_current'));
    assert.equal(state('session_permanent1').mode, 'human');
  });
  await test('D12 无客户流量时持久扫描心跳仍更新且不包含客户资料', async () => {
    const file = path.join(root, 'data/runtime/scheduler-health.json');
    fs.writeFileSync(file, JSON.stringify({
      schema_version: 1, started_at: now - 1, completed_at: now - 1,
      control_cursor: 0, ordinary_cursor: 0,
      isolated_sessions: { count: 0, reasons: { too_large: 0, invalid_json: 0, invalid_state: 0 } },
      health_recovered: null,
    }), { mode: 0o600 });
    await runtime.scan();
    const first = JSON.parse(fs.readFileSync(file, 'utf8'));
    assert.equal(first.completed_at, now);
    assert.deepEqual(first.isolated_sessions,
      { count: 0, reasons: { too_large: 0, invalid_json: 0, invalid_state: 0, io_error: 0 } },
      '旧三键隔离心跳必须在下一次成功扫描后规范化为当前四键 schema');
    now += 5000;
    await runtime.scan();
    const next = JSON.parse(fs.readFileSync(file, 'utf8'));
    assert.equal(next.started_at, now);
    assert.equal(next.completed_at, now);
    assert(next.completed_at > first.completed_at);
    assert.deepEqual(Object.keys(next).sort(), ['completed_at', 'control_cursor', 'crisp_rest_catchup', 'health_recovered',
      'isolated_sessions', 'ordinary_cursor', 'schema_version', 'started_at']);
    assert(['bootstrap', 'idle', 'ok', 'warning'].includes(next.crisp_rest_catchup.status));
    assert(!JSON.stringify(next.crisp_rest_catchup).includes('session_'));
    assert.deepEqual(Object.keys(next.isolated_sessions.reasons).sort(),
      ['invalid_json', 'invalid_state', 'io_error', 'too_large']);
    assert.equal(next.isolated_sessions.count, Object.values(next.isolated_sessions.reasons)
      .reduce((total, count) => total + count, 0));
    assert.equal(next.health_recovered, null);
    assert.equal(fs.statSync(file).mode & 0o777, 0o600);
    assert.equal(state('session_permanent1').mode, 'human');
  });
  await test('P0 大量历史会话不放大周期扫描，重叠调度退让且到期人工仍恢复', async () => {
    const bulk = [];
    const currentDisableEpoch = readConfig('runtime').disable_epoch || 0;
    for (let index = 0; index < 500; index += 1) {
      const session = 'session_archived-' + String(index).padStart(4, '0');
      const filename = path.join(root, 'data/runtime/session-' + key(session) + '.json');
      const value = {
        schema_version: 2, website_id: env.CRISP_WEBSITE_ID, session_id: session,
        mode: index === 0 ? 'human' : 'ai', generation: 0,
        resume_at: index === 0 ? now + 4000 : null, pause_reason: index === 0 ? 'operator_reply' : '',
        last_human_at: index === 0 ? now : 0, human_event_id: '', control_watermark: 0, sequence: 0,
        welcome_sent: false, menu_node: null, offers: {}, cooldowns: {}, jobs: [], outgoing: {},
        worker: null, uncertain_events: [], pending_feedback: null, updated_at: now,
      };
      if (index === 1) {
        value.jobs.push({ id: 'a'.repeat(64), event: 'message:send', control: false, status: 'received',
          received_at: now, retry_at: now + 60000, lease_until: 0, attempts: 1, data: { type: 'text' },
          global_disable_epoch: currentDisableEpoch,
          responsibility_status: 'unresolved_failure', failure_code: 'legacy_generic_non_answer',
          plan: { type: 'internal', ordinary: true, purpose: 'technical_unresolved', safe_error_context: 'text',
            content: '', answer_responsibility: 'unresolved_failure', diagnostic_code: 'legacy_generic_non_answer', tags: [] } });
      }
      if (index === 2) {
        value.jobs.push({ id: 'b'.repeat(64), event: 'message:send', purpose: 'feedback', feedback_retired: true,
          control: false, status: 'done', received_at: now, retry_at: null, lease_until: 0, attempts: 1 });
      }
      fs.writeFileSync(filename, JSON.stringify(value), { mode: 0o600 });
      bulk.push(filename);
    }
    const before = new Map(bulk.map((file) => [file, fs.readFileSync(file)]));
    now += 5000;
    const started = process.hrtime.bigint();
    const recovered = await runtime.scan();
    assert(recovered.every((job) => !bulk.includes(path.join(root, 'data/runtime/session-' + job.key + '.json'))));
    const elapsedMs = Number(process.hrtime.bigint() - started) / 1e6;
    assert(elapsedMs < 2000, '500 个历史会话扫描耗时异常：' + elapsedMs + 'ms');
    assert.equal(state('session_archived-0000').mode, 'ai');
    const changed = bulk.filter((file) => !fs.readFileSync(file).equals(before.get(file)));
    assert.deepEqual(changed, [bulk[0]], '只允许到期人工会话发生持久状态写入');

    const health = path.join(root, 'data/runtime/scheduler-health.json');
    const healthBefore = fs.readFileSync(health, 'utf8');
    fs.mkdirSync(path.join(root, 'data/runtime/scheduler-scan.lock'), { mode: 0o700 });
    now += 5000;
    assert.deepEqual(await runtime.scan(), []);
    assert.equal(fs.readFileSync(health, 'utf8'), healthBefore, '重叠扫描不能覆盖活动扫描心跳');
    fs.rmdirSync(path.join(root, 'data/runtime/scheduler-scan.lock'));

    const lock = path.join(root, 'data/runtime/scheduler-scan.lock');
    const old = new Date(Date.now() - 120000);
    fs.mkdirSync(lock, { mode: 0o700 });
    fs.utimesSync(lock, old, old);
    await runtime.scan();
    assert(!fs.existsSync(lock), '超时的旧版空锁必须恢复，且新扫描完成后释放锁');
    assert.notEqual(fs.readFileSync(health, 'utf8'), healthBefore);

    const bootId = fs.readFileSync('/proc/sys/kernel/random/boot_id', 'utf8').trim().toLowerCase();
    const statText = fs.readFileSync('/proc/self/stat', 'utf8');
    const statEnd = statText.lastIndexOf(') ');
    const ownPid = Number(statText.slice(0, statText.indexOf(' ')));
    const ownStart = statText.slice(statEnd + 2).trim().split(/\s+/)[19];
    const owner = (token, pid = ownPid, start = ownStart) => ({ schema_version: 1, token, pid,
      boot_id: bootId, process_start: start, started_at: Date.now() - 120000, heartbeat_at: Date.now() - 120000 });

    fs.mkdirSync(lock, { mode: 0o700 });
    const activeOwner = owner('a'.repeat(32));
    fs.writeFileSync(path.join(lock, 'owner.json'), JSON.stringify(activeOwner), { mode: 0o600 });
    fs.utimesSync(lock, old, old);
    assert.deepEqual(await runtime.scan(), []);
    assert.deepEqual(JSON.parse(fs.readFileSync(path.join(lock, 'owner.json'), 'utf8')), activeOwner,
      '同一 boot/pid/start 的活动所有者即使心跳较旧也不能被另一扫描器覆盖');
    fs.unlinkSync(path.join(lock, 'owner.json')); fs.rmdirSync(lock);

    for (const kind of ['extra-file', 'extra-link']) {
      fs.mkdirSync(lock, { mode: 0o700 });
      const unsafeOwner = owner(kind === 'extra-file' ? 'c'.repeat(32) : 'd'.repeat(32), 2147483647, '1');
      fs.writeFileSync(path.join(lock, 'owner.json'), JSON.stringify(unsafeOwner), { mode: 0o600 });
      if (kind === 'extra-file') fs.writeFileSync(path.join(lock, 'unexpected'), 'must-remain', { mode: 0o600 });
      else fs.symlinkSync('../scheduler-health.json', path.join(lock, 'unexpected'));
      const unsafeHealth = fs.readFileSync(health, 'utf8');
      assert.deepEqual(await runtime.scan(), []);
      assert(fs.existsSync(lock), kind + ' 的旧锁必须保留原路径');
      assert.deepEqual(JSON.parse(fs.readFileSync(path.join(lock, 'owner.json'), 'utf8')), unsafeOwner);
      if (kind === 'extra-file') assert.equal(fs.readFileSync(path.join(lock, 'unexpected'), 'utf8'), 'must-remain');
      else assert(fs.lstatSync(path.join(lock, 'unexpected')).isSymbolicLink(), '额外链接不得被移动或跟随');
      assert.equal(fs.readFileSync(health, 'utf8'), unsafeHealth, '不安全旧锁不能允许第二个扫描器启动');
      assert(!fs.readdirSync(path.dirname(lock)).some((name) => name.startsWith('scheduler-scan.lock.stale-')),
        '额外成员或链接存在时不能先把锁移入 quarantine');
      fs.unlinkSync(path.join(lock, 'unexpected'));
      fs.unlinkSync(path.join(lock, 'owner.json'));
      fs.rmdirSync(lock);
    }

    fs.mkdirSync(lock, { mode: 0o700 });
    fs.writeFileSync(path.join(lock, 'owner.json'), JSON.stringify(owner('b'.repeat(32), 2147483647, '1')), { mode: 0o600 });
    const staleHealth = fs.readFileSync(health, 'utf8');
    now += 5000;
    await runtime.scan();
    assert(!fs.existsSync(lock), '心跳超时且进程身份不存在的锁必须安全回收');
    assert.notEqual(fs.readFileSync(health, 'utf8'), staleHealth);

    const originalReaddir = fs.readdirSync;
    let replacedOwner = false;
    fs.readdirSync = function (target, ...args) {
      const values = originalReaddir.call(this, target, ...args);
      if (!replacedOwner && path.resolve(String(target)) === path.join(root, 'data/runtime')) {
        const file = path.join(lock, 'owner.json');
        if (fs.existsSync(file)) {
          const value = JSON.parse(fs.readFileSync(file, 'utf8'));
          value.token = 'f'.repeat(32);
          fs.writeFileSync(file, JSON.stringify(value), { mode: 0o600 });
          replacedOwner = true;
        }
      }
      return values;
    };
    try { await assert.rejects(runtime.scan(), /调度锁所有权已变化/); }
    finally { fs.readdirSync = originalReaddir; }
    assert(replacedOwner);
    assert(fs.existsSync(lock), 'finally 不能删除已不再属于自己的扫描锁');
    assert.equal(JSON.parse(fs.readFileSync(path.join(lock, 'owner.json'), 'utf8')).token, 'f'.repeat(32));
    fs.unlinkSync(path.join(lock, 'owner.json')); fs.rmdirSync(lock);
  });
  await test('W03/W04 生效投影隔离未完成编辑，同一会话的新问按新版本规则回答', async () => {
    const configuration = Object.fromEntries(['runtime', 'handoff', 'keyword', 'menu', 'tags', 'feedback'].map((name) => [name, readConfig(name)]));
    const file = path.join(root, 'config/materials-applied.json');
    const originalMaterials = fs.readFileSync(file);
    const originalKeyword = fs.readFileSync(path.join(root, 'config/keyword.yaml'));
    const originalPrompt = fs.readFileSync(path.join(root, 'config/prompt.md'));
    const prompt = '完整中文提示 😀\n' + 'x'.repeat(31000) + '\nSYNTHETIC_PROMPT_TAIL';
    configuration.runtime = { ...configuration.runtime, enabled: true, revision: 400, applied_revision: 400 };
    const projection = makeMaterials(configuration, prompt, 400);
    projection.configuration.keyword.rules.unshift({ id: 'projection-test', enabled: true, keywords: ['资料应用测试'], match_mode: 'exact', action: 'reply', text: '已应用版本一' });
    const publish = () => {
      sealMaterials(projection);
      fs.writeFileSync(file + '.candidate', JSON.stringify(projection)); fs.renameSync(file + '.candidate', file);
    };
    try {
      publish();
      fs.writeFileSync(path.join(root, 'config/keyword.yaml'), '{partial');
      fs.writeFileSync(path.join(root, 'config/prompt.md'), '');
      await deliver(message('session_materials001', '资料应用测试'));
      assert.equal(sent.at(-1).content, '已应用版本一');
      assert.equal(runtime.settings().revision, 400);
      const visualCount = providerRequests.length;
      await deliver(message('session_materials-img', { url: 'https://storage.crisp.chat/synthetic.png', type: 'image/png' }, { type: 'file' }));
      assert.equal(providerRequests.length, visualCount + 1);
      const visual = providerRequests.at(-1).body;
      assert.equal(visual.messages?.[0]?.content || visual.input?.[0]?.content?.[0]?.text, prompt, '视觉协议不得截断合法已应用 Prompt');
      const serviceRule = visual.messages?.[1] || visual.input?.[1];
      assert.equal(serviceRule.role, 'system');
      const serviceText = typeof serviceRule.content === 'string' ? serviceRule.content : serviceRule.content[0].text;
      assert.match(serviceText, /不得主动邀请用户评价、评分、点赞或确认满意度/);
      assert.match(serviceText, /只有缺少一个会改变判断的必要字段时/);
      assert.match(serviceText, /先回答能够确认的部分，再只询问该具体字段/);
      assert.match(serviceText, /不得要求用户笼统重述情况、提示和已尝试方法/);
      assert.match(serviceText, /不得连续索取已经提供的信息/);
      projection.revision += 1; projection.configuration.runtime.revision += 1; projection.configuration.runtime.applied_revision += 1;
      projection.configuration.keyword.rules[0].text = '已应用版本二'; publish();
      await deliver(message('session_materials001', '资料应用测试'));
      assert.equal(sent.at(-1).content, '已应用版本二');
      const next = createRuntime(env, runtimeOptions);
      assert.equal(next.settings().revision, 401);
      fs.writeFileSync(file, '{partial');
      assert.throws(() => next.settings(), /JSON|投影/);
      const before = sent.length;
      assert.equal((await receive(message('session_materials-bad', '不能采用损坏配置'))).statusCode, 503);
      assert.equal(sent.length, before);
    } finally {
      fs.writeFileSync(path.join(root, 'config/keyword.yaml'), originalKeyword);
      fs.writeFileSync(path.join(root, 'config/prompt.md'), originalPrompt);
      fs.writeFileSync(file, originalMaterials, { mode: 0o600 });
    }
  });
  await test('W03/B01 应用过渡取消旧答案，保留真人控制，期间新问题按新代恢复一次', async () => {
    const file = path.join(root, 'config/materials-applied.json');
    const originalMaterials = fs.readFileSync(file);
    const mapFile = path.join(root, 'data/runtime/knowledge-map.json');
    const originalMap = fs.existsSync(mapFile) ? fs.readFileSync(mapFile) : null;
    const configuration = Object.fromEntries(['runtime', 'handoff', 'keyword', 'menu', 'tags', 'feedback'].map((name) => [name, readConfig(name)]));
    const text = fs.readFileSync(path.join(root, 'config/prompt.md'), 'utf8');
    configuration.runtime = { ...configuration.runtime, enabled: true, revision: 500, applied_revision: 500 };
    const projection = makeMaterials(configuration, text, 500);
    const publish = () => {
      sealMaterials(projection);
      fs.writeFileSync(file + '.candidate', JSON.stringify(projection)); fs.renameSync(file + '.candidate', file);
    };
    let finish;
    try {
      publish();
      delayed = new Promise((resolve) => { finish = resolve; });
      const entry = await receive(message('session_materials-race', '慢答案'));
      const pending = runtime.process(entry.key, entry.jobId); await wait(20);
      projection.state = 'applying'; projection.revision = 501;
      projection.configuration.runtime.revision = 501; projection.configuration.runtime.applied_revision = 501; publish();
      assert.equal(runtime.settings().enabled, false);
      const before = sent.length;
      const during = await receive(message('session_materials-during', '过渡期间问题'));
      assert.equal(during.accepted, true); assert.equal(during.route, 'ignore');
      const queued = state('session_materials-during').jobs.find((job) => job.id === during.jobId);
      assert.equal(queued.status, 'received'); assert.equal(queued.deferred_configuration, true);
      assert(queued.data, '过渡期间已持久接收的问题不得丢失');
      const queuedData = structuredClone(queued.data);
      const queuedCoveredMessageIds = structuredClone(queued.covered_message_ids);
      const queuedGeneration = queued.generation;
      now += 10; await operator('session_materials-human');
      assert.equal(state('session_materials-human').mode, 'human');
      finish(); await pending;
      assert.equal(sent.length, before);
      projection.state = 'applied'; publish();
      now += 5000;
      const scanBaseline = { models: modelRequests.length, retrievals: retrievalRequests.length,
        posts: sendAttempts, visible: sent.length };
      const healthFile = path.join(root, 'data/runtime/scheduler-health.json');
      const sessionFileCount = fs.readdirSync(path.join(root, 'data/runtime'))
        .filter((name) => /^session-[a-f0-9]{64}\.json$/.test(name)).length;
      const targetIdentity = during.key + '\0' + during.jobId;
      const seenOrdinary = new Set();
      let selected;
      for (let attempt = 0; attempt <= sessionFileCount && !selected; attempt += 1) {
        const previousCursor = JSON.parse(fs.readFileSync(healthFile, 'utf8')).ordinary_cursor;
        const resumed = await runtime.scan();
        const ordinary = resumed.filter((entry) => entry.control !== true);
        const currentCursor = JSON.parse(fs.readFileSync(healthFile, 'utf8')).ordinary_cursor;
        assert.equal(currentCursor, previousCursor + ordinary.length,
          '每轮扫描必须按实际返回的普通任务数持久推进公平游标');
        assert(ordinary.length > 0, '目标责任仍到期时每轮必须保留至少一个普通任务槽');
        for (const entry of ordinary) {
          const identity = entry.key + '\0' + entry.jobId;
          if (identity === targetIdentity) { selected = entry; break; }
          assert(!seenOrdinary.has(identity), '目标责任获选前普通游标不得重复同一任务');
          seenOrdinary.add(identity);
        }
        const waiting = state('session_materials-during').jobs.filter((job) => job.id === during.jobId);
        assert.equal(waiting.length, 1);
        assert.deepEqual(waiting[0].data, queuedData, '公平轮转期间不得替换或截断原问题');
        assert.deepEqual(waiting[0].covered_message_ids, queuedCoveredMessageIds,
          '公平轮转期间不得丢失原消息覆盖关系');
        assert.equal(waiting[0].generation, queuedGeneration);
        assert.deepEqual({ models: modelRequests.length, retrievals: retrievalRequests.length,
          posts: sendAttempts, visible: sent.length }, scanBaseline,
        '仅扫描不得推理、检索、发送或产生可见消息');
      }
      assert.deepEqual(selected, { key: during.key, jobId: during.jobId, control: false },
        '配置过渡责任必须由持久公平游标在有界轮次内重新选中');
      const rebound = state('session_materials-during').jobs.find((job) => job.id === during.jobId);
      assert(rebound); assert.equal(rebound.status, 'received'); assert.equal(rebound.revision, 501);
      assert.equal(rebound.deferred_configuration, undefined);
      assert.equal(rebound.generation, queuedGeneration);
      assert.equal(rebound.generation, state('session_materials-during').generation);
      assert.deepEqual(rebound.data, queuedData);
      assert.deepEqual(rebound.covered_message_ids, queuedCoveredMessageIds);
      assert.equal((await runtime.process(selected.key, selected.jobId)).status, 'sent');
      assert.deepEqual({ models: modelRequests.length, retrievals: retrievalRequests.length,
        posts: sendAttempts, visible: sent.length }, { models: scanBaseline.models + 1,
        retrievals: scanBaseline.retrievals + 1, posts: scanBaseline.posts + 1,
        visible: scanBaseline.visible + 1 });
      const completed = state('session_materials-during');
      const completedJob = completed.jobs.find((job) => job.id === during.jobId); assert(completedJob);
      assert.equal(completedJob.status, 'done');
      assert.equal(completedJob.responsibility_status, 'answered_confirmed');
      const firstOutgoing = Object.values(completed.outgoing)
        .filter((record) => record.job_id === during.jobId);
      assert.equal(firstOutgoing.length, 1); assert.equal(firstOutgoing[0].status, 'sent');
      assert.equal(state('session_materials-human').mode, 'human');
      assert.equal(sent.filter((entry) => entry.session_id === 'session_materials-human').length, 0);
      assert.equal(sent.length, before + 1); assert.equal(sent.at(-1).session_id, 'session_materials-during');
      await deliver(message('session_materials-during', '之后的新问题'));
      assert.equal(sent.length, before + 2);
      assert.equal(sent.at(-1).session_id, 'session_materials-during');
      assert.equal(Object.values(state('session_materials-during').outgoing)
        .filter((record) => record.job_id === during.jobId).length, 1,
      '后续新问题不得使首个恢复责任重复出站');
      fs.writeFileSync(mapFile, JSON.stringify({ synthetic: 'unapplied-map' }));
      assert.equal(runtime.settings().enabled, false, '知识投影错代禁止普通出站');
      now += 10; await operator('session_materials-map-human');
      assert.equal(state('session_materials-map-human').mode, 'human');
    } finally {
      if (finish) finish();
      if (originalMap) fs.writeFileSync(mapFile, originalMap); else if (fs.existsSync(mapFile)) fs.unlinkSync(mapFile);
      fs.writeFileSync(file, originalMaterials, { mode: 0o600 });
    }
  });
  await test('V122-R03 普通长任务跨执行限为七个，Webhook/人工控制不等待并保留扫描公平性', async () => {
    const permitRoot = path.join(root, 'data/runtime/ordinary-processing-permits');
    let releaseSlow;
    let slowReleased = false;
    let runningSettled = 0;
    let running = [];
    delayedAll = new Promise((resolve) => { releaseSlow = resolve; });
    const releaseSlowOnce = () => {
      if (slowReleased) return;
      slowReleased = true;
      releaseSlow();
    };
    const permitCount = () => fs.existsSync(permitRoot)
      ? fs.readdirSync(permitRoot).filter((name) => /^slot-[0-6]$/.test(name)).length : 0;
    const totalPermitCount = () => fs.existsSync(permitRoot)
      ? fs.readdirSync(permitRoot).filter((name) => /^slot-[0-7]$/.test(name)).length : 0;
    const entries = [];
    try {
      for (let index = 0; index < 15; index += 1) {
        entries.push(await receive(message('session_capacity-' + String(index).padStart(2, '0'), '容量测试问题 ' + index)));
      }
      const workers = Array.from({ length: 7 }, () => createRuntime(env, runtimeOptions));
      running = entries.slice(0, 7).map((entry, index) =>
        workers[index].process(entry.key, entry.jobId).finally(() => { runningSettled += 1; }));
      for (let attempt = 0; attempt < 200; attempt += 1) {
        if (permitCount() === 7) break;
        await wait(5);
      }
      assert.equal(permitCount(), 7, '七个不同 runtime 实例必须共享同一许可容量');
      assert.equal(totalPermitCount(), 7, '普通任务占满时不得提前占用控制保留槽');

      const deferred = await Promise.race([
        runtime.process(entries[7].key, entries[7].jobId),
        wait(500).then(() => ({ status: 'timeout' })),
      ]);
      assert.deepEqual(deferred, { status: 'deferred', reason: 'processing_capacity' });
      assert.equal(runningSettled, 0, '容量延期返回时七个普通任务必须仍被慢上游阻塞');
      assert.equal(permitCount(), 7, '容量延期不得释放或窃取其它普通任务许可');
      assert.equal(totalPermitCount(), 7, '普通任务容量延期不得遗留控制许可');
      const deferredState = state('session_capacity-07');
      const deferredJob = deferredState.jobs.find((job) => job.id === entries[7].jobId);
      assert.equal(deferredJob.status, 'received');
      assert.equal(deferredJob.lease_until, 0);
      assert.equal(deferredState.worker, null);
      assert.equal(deferredJob.retry_at, now + 1000);

      const controlSession = 'session_capacity-control';
      const controlVisibleBefore = sent.filter((entry) => entry.session_id === controlSession).length;
      const visibleBeforeControl = sent.length;
      const control = await Promise.race([
        operator(controlSession),
        wait(500).then(() => ({ status: 'timeout' })),
      ]);
      assert.notEqual(control.status, 'timeout', '人工控制不得被普通任务许可阻塞');
      assert.equal(control.status, 'none');
      assert.equal(control.key, key(controlSession));
      assert.match(control.jobId, /^[a-f0-9]{64}$/);
      assert.equal(runningSettled, 0, '人工控制完成时七个普通任务必须仍未结算');
      assert.equal(permitCount(), 7, '人工控制必须使用保留容量，不能抢占普通许可');
      assert.equal(totalPermitCount(), 7, '人工控制完成后必须释放控制保留槽');
      const controlState = state(controlSession);
      assert.equal(controlState.mode, 'human');
      assert.equal(controlState.pause_reason, 'operator_reply');
      assert.equal(controlState.last_human_at, now);
      assert.equal(controlState.control_watermark, now);
      assert.equal(controlState.human_event_id, control.jobId);
      assert.equal(controlState.generation, 1);
      assert.equal(controlState.worker, null);
      const controlJobs = controlState.jobs.filter((job) => job.id === control.jobId);
      assert.equal(controlJobs.length, 1);
      assert.equal(controlJobs[0].control, true);
      assert.equal(controlJobs[0].action, 'operator');
      assert.equal(controlJobs[0].status, 'done');
      assert.equal(controlJobs[0].responsibility_status, 'control_handled');
      assert.equal(controlJobs[0].responsibility_reason, 'operator');
      assert.equal(sent.length, visibleBeforeControl,
        '真人控制完成不得向任何会话错误路由可见出站');
      assert.equal(sent.filter((entry) => entry.session_id === controlSession).length,
        controlVisibleBefore, '真人公开回复只提交控制状态，不产生本项目可见出站');

      now += 1001;
      const firstOrdinary = (await runtime.scan()).filter((entry) => !entry.control);
      const secondOrdinary = (await runtime.scan()).filter((entry) => !entry.control);
      assert(firstOrdinary.length > 0 && firstOrdinary.length <= 7, '每轮扫描最多返回许可容量个普通任务');
      assert(secondOrdinary.length > 0 && secondOrdinary.length <= 7);
      assert(new Set([...firstOrdinary, ...secondOrdinary].map((entry) => entry.key)).size > firstOrdinary.length,
        '公平游标必须让上轮未选中的普通任务进入下一轮');

      releaseSlowOnce();
      const runningResults = await Promise.all(running);
      assert.equal(runningSettled, 7);
      assert(runningResults.every((result) => result.status === 'sent'));
      delayedAll = null;
      assert.equal((await runtime.process(entries[7].key, entries[7].jobId)).status, 'sent');
      const remaining = await Promise.all(entries.slice(8)
        .map((entry) => runtime.process(entry.key, entry.jobId)));
      assert(remaining.every((result) => result.status === 'sent'));
      assert.equal(permitCount(), 0, '完成后必须释放全部普通任务许可');
      assert.equal(totalPermitCount(), 0, '完成后不得遗留控制保留槽');
      assert.equal(sent.filter((entry) => entry.session_id === controlSession).length,
        controlVisibleBefore, '普通任务恢复后也不得给人工控制事件生成回复');
    } finally {
      releaseSlowOnce();
      await Promise.allSettled(running);
      delayedAll = null;
    }
  });
  await test('V122-R03 控制任务总后台限为八个，普通满载仍可控制且控制积压不阻塞接收', async () => {
    const permitRoot = path.join(root, 'data/runtime/ordinary-processing-permits');
    let releaseControls;
    let releaseRetryLookup;
    let controlsReleased = false;
    let retryReleased = false;
    const releaseControlsOnce = () => {
      if (controlsReleased) return;
      controlsReleased = true;
      releaseControls?.();
    };
    const releaseRetryOnce = () => {
      if (retryReleased) return;
      retryReleased = true;
      releaseRetryLookup?.();
    };
    const totalPermitCount = () => fs.existsSync(permitRoot)
      ? fs.readdirSync(permitRoot).filter((name) => /^slot-[0-7]$/.test(name)).length : 0;
    const controlJob = (session, jobId) => state(session).jobs.find((job) => job.id === jobId);
    const entries = [];
    const sessions = [];
    const started = [];
    const running = [];
    let eighth;
    let retryPending;
    let accepted;
    let settledControls = 0;
    const trackStarted = (promise) => {
      started.push(promise);
      promise.catch(() => {});
      return promise;
    };
    try {
      delayedControlLookups = new Promise((resolve) => { releaseControls = resolve; });
      for (let index = 0; index < 9; index += 1) {
        const session = 'session_control-capacity-' + String(index).padStart(2, '0');
        sessions.push(session);
        const body = { ...message(session, '待核验人工事件 ' + index,
          { from: 'operator', automated: undefined }), event: 'message:received' };
        const history = histories.get(session) || [];
        history.push(body.data);
        histories.set(session, history);
        entries.push(await runtime.receive({ body, query: { key: env.CRISP_WEBSITE_HOOK_SECRET } }));
        assert.equal(entries.at(-1).route, 'process');
      }
      const workers = Array.from({ length: 8 }, () => createRuntime(env, runtimeOptions));
      const trackedControl = (promise) => promise.then((result) => {
        settledControls += 1;
        return result;
      }, (error) => {
        settledControls += 1;
        throw error;
      });
      running.push(...entries.slice(0, 7)
        .map((entry, index) => trackStarted(
          trackedControl(workers[index].process(entry.key, entry.jobId)))));
      for (let attempt = 0; attempt < 200; attempt += 1) {
        if (totalPermitCount() === 7) break;
        await wait(5);
      }
      assert.equal(totalPermitCount(), 7);

      const ordinaryEntry = await receive(message('session_control-capacity-ordinary', '控制满载下的普通问题'));
      const ordinaryPending = trackStarted(runtime.process(ordinaryEntry.key, ordinaryEntry.jobId));
      const ordinaryResult = await Promise.race([
        ordinaryPending,
        wait(500).then(() => ({ status: 'timeout' })),
      ]);
      assert.equal(ordinaryResult.status, 'sent', '七个控制任务时仍须为普通任务保留一个后台槽');
      assert.equal(totalPermitCount(), 7, '普通任务完成后必须释放普通许可，七个控制任务仍在等待精确回查');

      eighth = trackStarted(trackedControl(workers[7].process(entries[7].key, entries[7].jobId)));
      for (let attempt = 0; attempt < 200; attempt += 1) {
        if (totalPermitCount() === 8) break;
        await wait(5);
      }
      assert.equal(totalPermitCount(), 8, '控制任务最多占八个后台许可');
      assert.equal(settledControls, 0, '精确回查门释放前八个控制任务都必须仍在处理');

      const capacityPending = trackStarted(runtime.process(entries[8].key, entries[8].jobId));
      const deferred = await Promise.race([
        capacityPending,
        wait(500).then(() => ({ status: 'timeout' })),
      ]);
      assert.deepEqual(deferred, { status: 'deferred', reason: 'processing_capacity' });
      let deferredJob = controlJob(sessions[8], entries[8].jobId); assert(deferredJob);
      assert(deferredJob.data);
      const deferredData = structuredClone(deferredJob.data);
      assert.equal(deferredJob.status, 'received');
      assert.equal(deferredJob.responsibility_status, 'pending');
      assert.equal(deferredJob.attempts, 0, '容量延期不得冒充一次控制处理尝试');
      assert.equal(deferredJob.failure_code, undefined);
      assert.equal(deferredJob.operator_resolution, undefined);
      assert.equal(deferredJob.lease_until, 0);
      assert.equal(deferredJob.retry_at, now + 1000);
      assert.deepEqual(deferredJob.data, deferredData, '容量延期必须保留同一控制责任');
      assert.equal(state(sessions[8]).worker, null);
      assert.equal(totalPermitCount(), 8, '第九个容量延期不得改变前八个在途许可');

      const acceptedPending = trackStarted(
        receive(message('session_control-capacity-receive', '控制积压期间的新消息')));
      accepted = await Promise.race([
        acceptedPending,
        wait(500).then(() => ({ status: 'timeout' })),
      ]);
      assert.notEqual(accepted.status, 'timeout');
      assert.equal(accepted.accepted, true);
      assert.equal(accepted.route, 'process');
      assert.equal(settledControls, 0, '控制积压期间新消息持久接收不能释放或取代在途控制任务');
      assert.equal(totalPermitCount(), 8, '持久接收不得占用后台处理许可');

      releaseControlsOnce();
      const firstResults = await Promise.all([...running, eighth]);
      assert.equal(settledControls, 8);
      assert(firstResults.every((result) => result.status === 'deferred'
        && result.reason === 'operator_identity_pending'),
      '精确身份仍未知时必须保留控制责任，不能猜测真人或自动消息');
      delayedControlLookups = null;
      assert.equal(totalPermitCount(), 0, '首批八个控制任务结算后必须释放全部后台许可');
      for (let index = 0; index < 8; index += 1) {
        const pending = controlJob(sessions[index], entries[index].jobId); assert(pending);
        assert.equal(pending.status, 'received');
        assert.equal(pending.responsibility_status, 'unresolved_failure');
        assert.equal(pending.failure_code, 'operator_identity_pending');
        assert.equal(pending.operator_resolution, undefined);
        assert.equal(pending.attempts, 1);
        assert.equal(pending.lease_until, 0);
        assert(Number.isFinite(pending.retry_at) && pending.retry_at > now);
        assert.equal(pending.execution_token, undefined);
        assert(pending.data, '身份待确认时不得删除控制责任原始数据');
        assert(state(sessions[index]).uncertain_events.includes(entries[index].jobId));
        assert.equal(state(sessions[index]).mode, 'ai');
        assert.equal(state(sessions[index]).worker, null);
        assert.equal(Object.values(state(sessions[index]).outgoing || {})
          .filter((record) => record.job_id === entries[index].jobId).length, 0);
        assert.equal(sent.filter((entry) => entry.session_id === sessions[index]).length, 0);
      }

      now += 1001;
      delayedControlLookups = new Promise((resolve) => { releaseRetryLookup = resolve; });
      retryPending = trackStarted(runtime.process(entries[8].key, entries[8].jobId));
      for (let attempt = 0; attempt < 200; attempt += 1) {
        if (totalPermitCount() === 1) break;
        await wait(5);
      }
      assert.equal(totalPermitCount(), 1, '第九个控制任务必须在容量恢复后真实重获唯一许可');
      const retryOwner = JSON.parse(fs.readFileSync(path.join(permitRoot, 'slot-7/owner.json'), 'utf8'));
      assert.equal(retryOwner.slot, 7);
      assert.equal(retryOwner.kind, 'control');
      deferredJob = controlJob(sessions[8], entries[8].jobId); assert(deferredJob);
      assert.equal(deferredJob.status, 'processing');
      assert.equal(deferredJob.attempts, 1);
      assert.equal(deferredJob.operator_resolution, undefined);
      assert.equal(typeof deferredJob.execution_token, 'string');
      assert.deepEqual(deferredJob.data, deferredData);
      assert(state(sessions[8]).uncertain_events.includes(entries[8].jobId));
      assert.equal(state(sessions[8]).mode, 'ai');
      assert.equal(state(sessions[8]).worker, null);

      releaseRetryOnce();
      const retryResult = await retryPending;
      assert.deepEqual(retryResult, { status: 'deferred', reason: 'operator_identity_pending' });
      delayedControlLookups = null;
      deferredJob = controlJob(sessions[8], entries[8].jobId); assert(deferredJob);
      assert.equal(deferredJob.status, 'received');
      assert.equal(deferredJob.responsibility_status, 'unresolved_failure');
      assert.equal(deferredJob.failure_code, 'operator_identity_pending');
      assert.equal(deferredJob.operator_resolution, undefined);
      assert.equal(deferredJob.attempts, 1);
      assert.equal(deferredJob.lease_until, 0);
      assert.equal(deferredJob.execution_token, undefined);
      assert(Number.isFinite(deferredJob.retry_at) && deferredJob.retry_at > now);
      assert.deepEqual(deferredJob.data, deferredData, '身份延期必须保留同一控制责任');
      assert(state(sessions[8]).uncertain_events.includes(entries[8].jobId));
      assert.equal(state(sessions[8]).mode, 'ai');
      assert.equal(state(sessions[8]).worker, null);
      assert.equal(Object.values(state(sessions[8]).outgoing || {})
        .filter((record) => record.job_id === entries[8].jobId).length, 0);
      assert.equal(sent.filter((entry) => entry.session_id === sessions[8]).length, 0);
      assert.equal(totalPermitCount(), 0, '身份延期结算后必须再次释放控制许可');

      for (let index = 0; index < entries.length; index += 1) {
        const history = histories.get(sessions[index]) || [];
        histories.set(sessions[index], history.map((item) =>
          String(item.fingerprint) === String(controlJob(sessions[index], entries[index].jobId).data.fingerprint)
            ? { ...item, automated: true } : item));
      }
      now = Math.max(now, ...entries.map((entry, index) =>
        controlJob(sessions[index], entry.jobId).retry_at || now));
      for (let index = 0; index < entries.length; index += 1) {
        const resolved = await runtime.process(entries[index].key, entries[index].jobId);
        assert.equal(resolved.status, 'none');
        const completed = controlJob(sessions[index], entries[index].jobId); assert(completed);
        assert.equal(completed.status, 'done');
        assert.equal(completed.responsibility_status, 'control_handled');
        assert.equal(completed.responsibility_reason, 'operator_identity_resolved');
        assert.equal(completed.operator_resolution.result, 'not-human');
        assert.equal(completed.failure_code, undefined);
        assert.equal(state(sessions[index]).uncertain_events.includes(entries[index].jobId), false);
        assert.equal(state(sessions[index]).mode, 'ai');
        assert.equal(sent.filter((entry) => entry.session_id === sessions[index]).length, 0);
      }
      const acceptedResult = await runtime.process(accepted.key, accepted.jobId);
      assert.equal(acceptedResult.status, 'sent', '容量恢复后必须继续处理积压期间已持久接收的普通问题');
      const acceptedJob = controlJob('session_control-capacity-receive', accepted.jobId); assert(acceptedJob);
      assert.equal(acceptedJob.status, 'done');
      assert.equal(acceptedJob.responsibility_status, 'answered_confirmed');
      assert.equal(sent.filter((entry) => entry.session_id === 'session_control-capacity-receive').length, 1);
      assert.equal(totalPermitCount(), 0, '本场全部责任收口后不得遗留后台许可');
    } finally {
      releaseControlsOnce();
      releaseRetryOnce();
      await Promise.allSettled(started);
      delayedControlLookups = null;
    }
  });
  await test('V122-R03 过期许可续租竞态不误删，稳定过期可回收且异常链接失败关闭', async () => {
    const permitRoot = path.join(root, 'data/runtime/ordinary-processing-permits');
    fs.mkdirSync(permitRoot, { recursive: true, mode: 0o700 });
    fs.chmodSync(permitRoot, 0o700);
    const staleSlot = path.join(permitRoot, 'slot-0');
    fs.mkdirSync(staleSlot, { mode: 0o700 });
    const staleToken = 'a'.repeat(32);
    fs.writeFileSync(path.join(staleSlot, 'owner.json'), JSON.stringify({ schema_version: 1, slot: 0,
      token: staleToken, kind: 'ordinary', acquired_at: 1, expires_at: 2 }), { mode: 0o600 });
    fs.writeFileSync(path.join(staleSlot, 'heartbeat.json'), JSON.stringify({ schema_version: 1,
      token: staleToken }), { mode: 0o600 });
    fs.utimesSync(path.join(staleSlot, 'heartbeat.json'), new Date(1), new Date(1));

    // 精确制造 TOCTOU：回收者已把旧 slot rename 到 quarantine，并完成第一次
    // moved snapshot 后，旧执行仍通过打开的 descriptor 续租。第二次快照必须
    // 比较 heartbeat mtime/size，拒绝删除并把许可恢复到原 slot。
    const heartbeatDescriptor = fs.openSync(path.join(staleSlot, 'heartbeat.json'), 'r+');
    const originalRenameSync = fs.renameSync;
    const originalLstatSync = fs.lstatSync;
    let quarantinePath = '';
    let quarantineStats = 0;
    fs.renameSync = (source, target) => {
      const result = originalRenameSync(source, target);
      if (source === staleSlot && /\.stale-slot-0-[a-f0-9]{32}$/.test(target)) quarantinePath = target;
      return result;
    };
    fs.lstatSync = (target, ...args) => {
      if (target === quarantinePath && ++quarantineStats === 2) {
        const renewed = new Date();
        fs.futimesSync(heartbeatDescriptor, renewed, renewed);
        fs.fsyncSync(heartbeatDescriptor);
      }
      return originalLstatSync(target, ...args);
    };
    try {
      const raced = await deliver(message('session_capacity-raced-renewal', '竞态续租保护'));
      assert.equal(raced.status, 'sent');
      assert(fs.existsSync(staleSlot), 'rename 后续租的旧许可必须恢复，不能被当作稳定过期删除');
      assert.equal(JSON.parse(fs.readFileSync(path.join(staleSlot, 'owner.json'), 'utf8')).token, staleToken);
    } finally {
      fs.renameSync = originalRenameSync;
      fs.lstatSync = originalLstatSync;
      fs.closeSync(heartbeatDescriptor);
    }

    fs.utimesSync(path.join(staleSlot, 'heartbeat.json'), new Date(1), new Date(1));
    const recovered = await deliver(message('session_capacity-stale', '回收过期许可'));
    assert.equal(recovered.status, 'sent');
    assert(!fs.existsSync(staleSlot), '过期许可回收并完成任务后不应残留');

    const outside = path.join(root, 'outside-permit-sentinel');
    fs.mkdirSync(outside, { mode: 0o700 });
    fs.writeFileSync(path.join(outside, 'keep'), '保留', { mode: 0o600 });
    for (let slot = 0; slot < 7; slot += 1) fs.symlinkSync(outside, path.join(permitRoot, 'slot-' + slot));
    const entry = await receive(message('session_capacity-unsafe', '异常许可目录'));
    const unsafe = await runtime.process(entry.key, entry.jobId);
    assert.deepEqual(unsafe, { status: 'deferred', reason: 'processing_capacity' });
    assert.equal(fs.readFileSync(path.join(outside, 'keep'), 'utf8'), '保留');
    for (let slot = 0; slot < 7; slot += 1) fs.unlinkSync(path.join(permitRoot, 'slot-' + slot));
    fs.unlinkSync(path.join(outside, 'keep')); fs.rmdirSync(outside);
    now += 1001;
    assert.equal((await runtime.process(entry.key, entry.jobId)).status, 'sent');

    const writeFixedPermit = (slot, kind, suffix) => {
      const item = path.join(permitRoot, 'slot-' + slot);
      fs.mkdirSync(item, { mode: 0o700 });
      const token = String(suffix).repeat(32).slice(0, 32);
      const owner = { schema_version: 1, slot, token, acquired_at: Date.now() - 1000,
        expires_at: Date.now() + 120000 };
      if (kind !== undefined) owner.kind = kind;
      fs.writeFileSync(path.join(item, 'owner.json'), JSON.stringify(owner), { mode: 0o600 });
      fs.writeFileSync(path.join(item, 'heartbeat.json'), JSON.stringify({ schema_version: 1, token }), { mode: 0o600 });
    };
    const clearFixedPermits = () => {
      for (const name of fs.readdirSync(permitRoot)) {
        const item = path.join(permitRoot, name);
        for (const member of fs.readdirSync(item)) fs.unlinkSync(path.join(item, member));
        fs.rmdirSync(item);
      }
    };
    for (const [caseIndex, [kind, label]] of [[undefined, '缺失 kind'], ['invalid', '非法 kind']].entries()) {
      for (let slot = 0; slot < 7; slot += 1) writeFixedPermit(slot, kind, slot + 1);
      const malformedEntry = await receive(message('session_capacity-malformed-' + caseIndex, label));
      assert.deepEqual(await runtime.process(malformedEntry.key, malformedEntry.jobId),
        { status: 'deferred', reason: 'processing_capacity' }, label + ' 必须失败关闭');
      assert.equal(fs.readdirSync(permitRoot).length, 7, label + ' 不得被当作过期许可删除');
      clearFixedPermits();
    }

    // slot 7 是控制任务专用保留槽；即使 owner 其余字段合法，
    // kind=ordinary 也必须视为不安全，不回收、不重用。
    for (let slot = 0; slot < 7; slot += 1) writeFixedPermit(slot, 'ordinary', slot + 1);
    writeFixedPermit(7, 'ordinary', 8);
    const invalidSlotSession = 'session_capacity-slot7-ordinary';
    const invalidSlotBody = { ...message(invalidSlotSession, '待核验人工事件',
      { from: 'operator', automated: undefined }), event: 'message:received' };
    histories.set(invalidSlotSession, [invalidSlotBody.data]);
    const invalidSlotEntry = await runtime.receive({ body: invalidSlotBody,
      query: { key: env.CRISP_WEBSITE_HOOK_SECRET } });
    assert.deepEqual(await runtime.process(invalidSlotEntry.key, invalidSlotEntry.jobId),
      { status: 'deferred', reason: 'processing_capacity' }, 'slot 7 ordinary owner 必须失败关闭');
    assert.equal(JSON.parse(fs.readFileSync(path.join(permitRoot, 'slot-7/owner.json'), 'utf8')).kind, 'ordinary');
    clearFixedPermits();
  });
  await test('P0 普通推理失去许可立即中止，不计业务失败且可有界恢复', async () => {
    const session = 'session_permit-lost-provider';
    const beforeSent = sent.filter((entry) => entry.session_id === session).length;
    const beforeModels = modelRequests.length;
    const beforePosts = sendAttempts;
    let startedResolve;
    const started = new Promise((resolve) => { startedResolve = resolve; });
    const guarded = createRuntime(env, { ...runtimeOptions, processingPermitHeartbeatMilliseconds: 10,
      request: async (url, options = {}) => {
        const parsed = new URL(url);
        if (parsed.hostname === 'provider.invalid' && /\/(?:chat\/completions|responses)$/.test(parsed.pathname)) {
          return abortablePending(options.signal, startedResolve);
        }
        return request(url, options);
      } });
    const body = message(session, '请处理许可换代后的恢复问题');
    histories.set(session, [{ ...body.data }]);
    const entry = await guarded.receive({ body, query: { key: env.CRISP_WEBSITE_HOOK_SECRET } });
    const running = guarded.process(entry.key, entry.jobId);
    let replacement;
    let stored;
    try {
      await awaitNamedGate(started, '普通推理进入受控上游');
      await waitForPermitSlot(0);
      replacement = replacePermitOwner(0, 'ordinary');
      const result = await Promise.race([running, wait(1000).then(() => ({ status: 'timeout' }))]);
      assert.deepEqual(result, { status: 'deferred', reason: 'processing_permit_lost' });
      stored = guarded.readState(entry.key).jobs.find((job) => job.id === entry.jobId);
      assert.equal(stored.status, 'received');
      assert.equal(stored.attempts, 0, '许可换代不得消耗业务失败次数');
      assert.equal(stored.processing_permit_losses, 1);
      assert.equal(stored.retry_at, now + 1000);
      assert.equal(stored.execution_token, undefined);
      assert(stored.inference, '已发起的 Provider 代次必须保留到精确结果对账');
      assert.equal(stored.provider_result_receipt?.state, 'requesting');
      assert.equal(stored.provider_result_receipt?.stage, 'answer');
      assert.equal(sent.filter((item) => item.session_id === session).length, beforeSent);
      assert.equal(JSON.parse(fs.readFileSync(path.join(replacement.slotPath, 'owner.json'), 'utf8')).token,
        replacement.token, '旧执行 finally 不得删除新持有者');
    } finally {
      replacement?.cleanup();
    }

    now += 1001;
    let replayCalls = 0;
    let routeCalls = 0;
    let settlementCalls = 0;
    const recovered = createRuntime(env, { ...runtimeOptions,
      request: async (url, options = {}) => {
        const parsed = new URL(url);
        if (parsed.hostname === 'provider.invalid') {
          if (parsed.pathname === '/proxy/internal/provider/replay') replayCalls += 1;
          else if (parsed.pathname === '/proxy/internal/provider/settle') settlementCalls += 1;
          else if (/\/(?:chat\/completions|responses)$/.test(parsed.pathname)) routeCalls += 1;
        }
        return request(url, options);
      } });
    const replayed = await recovered.process(entry.key, entry.jobId);
    assert.equal(replayed.status, 'unresolved',
      '许可丢失后的第一轮恢复必须先只读确认旧 Provider 请求没有结果');
    stored = recovered.readState(entry.key).jobs.find((job) => job.id === entry.jobId);
    assert.equal(stored.status, 'received');
    assert.equal(stored.responsibility_status, 'unresolved_failure');
    assert.equal(stored.failure_code, 'question_result_absent');
    assert.equal(stored.retry_at, now);
    assert.equal(stored.inference, undefined);
    assert.equal(stored.provider_result_receipt, undefined);
    assert.equal(stored.provider_migration_from, undefined);
    assert.equal(stored.provider_settlement, undefined);
    assert.equal(stored.provider_retirement, undefined);
    assert.equal(stored.plan, undefined);
    assert.equal(stored.failure_rounds, undefined,
      '精确阴性对账不是新的业务失败轮');
    assert.equal(stored.processing_permit_losses, undefined);
    assert.equal(stored.data?.content, body.data.content, '同一访客责任必须保留原始问题');
    assert.equal(replayCalls, 1);
    assert.equal(routeCalls, 0, '只读对账轮不得递归发起第二次推理');
    assert.equal(settlementCalls, 0);
    assert.equal(modelRequests.length, beforeModels);
    assert.equal(sendAttempts, beforePosts);
    assert.equal(sent.filter((item) => item.session_id === session).length, beforeSent);

    now += 1;
    assert.equal((await recovered.process(entry.key, entry.jobId)).status, 'sent');
    stored = recovered.readState(entry.key).jobs.find((job) => job.id === entry.jobId);
    assert.equal(stored.status, 'done');
    assert.equal(stored.responsibility_status, 'answered_confirmed');
    assert.equal(stored.processing_permit_losses, undefined);
    assert.equal(replayCalls, 1);
    assert.equal(routeCalls, 1, '精确确认旧结果不存在后只允许一个 successor 推理');
    assert.equal(settlementCalls, 1);
    assert.equal(modelRequests.length, beforeModels + 1);
    assert.equal(sendAttempts, beforePosts + 1);
    assert.equal(sent.filter((item) => item.session_id === session).length, beforeSent + 1);
    const outgoing = Object.values(recovered.readState(entry.key).outgoing)
      .filter((record) => record.job_id === entry.jobId);
    assert.equal(outgoing.length, 1, '同一访客责任只能存在一个出站记录');
    assert.equal(outgoing[0].status, 'sent', '唯一出站必须已经得到明确发送回执');
  });
  await test('P0 忽略取消的旧请求返回后仍被 fence 丢弃，不覆盖新执行代次', async () => {
    const session = 'session_permit-lost-superseded';
    const beforeSent = sent.filter((entry) => entry.session_id === session).length;
    let startedResolve, releaseProvider;
    let providerReleased = false;
    const started = new Promise((resolve) => { startedResolve = resolve; });
    const release = new Promise((resolve) => { releaseProvider = resolve; });
    const releaseProviderGate = () => {
      if (!providerReleased && releaseProvider) { providerReleased = true; releaseProvider(); }
    };
    const staleRuntime = createRuntime(env, { ...runtimeOptions, processingPermitHeartbeatMilliseconds: 10,
      request: async (url, options = {}) => {
        const parsed = new URL(url);
        if (parsed.hostname === 'provider.invalid' && /\/(?:chat\/completions|responses)$/.test(parsed.pathname)) {
          startedResolve();
          await release; // 故意忽略 signal，验证 await 返回后的所有权 fence。
        }
        return request(url, options);
      } });
    const body = message(session, '请验证旧执行不覆盖新执行');
    histories.set(session, [{ ...body.data }]);
    const entry = await staleRuntime.receive({ body, query: { key: env.CRISP_WEBSITE_HOOK_SECRET } });
    const running = staleRuntime.process(entry.key, entry.jobId);
    let replacement;
    try {
      await awaitNamedGate(started, '忽略取消的旧推理进入受控上游');
      await waitForPermitSlot(0);
      replacement = replacePermitOwner(0, 'ordinary');
      const newerToken = 'f'.repeat(24);
      await staleRuntime.transaction(entry.key, (current) => {
        const stored = current.jobs.find((job) => job.id === entry.jobId);
        stored.execution_token = newerToken;
        stored.status = 'processing';
        stored.attempts = 41;
        stored.lease_until = now + 300000;
        current.worker = { job: stored.id, token: newerToken, until: now + 300000 };
      });
      releaseProviderGate();
      assert.deepEqual(await running, { status: 'deferred', reason: 'processing_permit_lost' });
      const stored = staleRuntime.readState(entry.key).jobs.find((job) => job.id === entry.jobId);
      assert.equal(stored.execution_token, newerToken);
      assert.equal(stored.status, 'processing');
      assert.equal(stored.attempts, 41);
      assert.equal(staleRuntime.readState(entry.key).worker.token, newerToken);
      assert.equal(sent.filter((item) => item.session_id === session).length, beforeSent);
      await staleRuntime.transaction(entry.key, (current) => {
        const currentJob = current.jobs.find((job) => job.id === entry.jobId);
        currentJob.status = 'cancelled'; currentJob.lease_until = 0; delete currentJob.execution_token;
        current.worker = null;
      });
    } finally {
      releaseProviderGate();
      replacement?.cleanup();
    }
  });
  await test('P0 控制任务失去许可不提前释放人工归属栅栏', async () => {
    const session = 'session_permit-lost-control';
    const beforeModels = modelRequests.length;
    const beforeRetrievals = retrievalRequests.length;
    const beforePosts = sendAttempts;
    const beforeSent = sent.filter((item) => item.session_id === session).length;
    let startedResolve;
    const started = new Promise((resolve) => { startedResolve = resolve; });
    const controlRuntime = createRuntime(env, { ...runtimeOptions, processingPermitHeartbeatMilliseconds: 10,
      request: async (url, options = {}) => {
        const parsed = new URL(url);
        if (/\/message\/[^/]+$/.test(parsed.pathname)) return abortablePending(options.signal, startedResolve);
        return request(url, options);
      } });
    const data = message(session, '待核验人工公开回复', { from: 'operator', automated: undefined }).data;
    histories.set(session, [{ ...data }]);
    const entry = await controlRuntime.receive({ body: { website_id: env.CRISP_WEBSITE_ID,
      event: 'message:received', timestamp: now, data }, query: { key: env.CRISP_WEBSITE_HOOK_SECRET } });
    const running = controlRuntime.process(entry.key, entry.jobId);
    let replacement;
    let persistedData;
    try {
      await awaitNamedGate(started, '人工归属精确回查开始');
      await waitForPermitSlot(7);
      replacement = replacePermitOwner(7, 'control');
      assert.deepEqual(await running, { status: 'deferred', reason: 'processing_permit_lost' });
      const current = controlRuntime.readState(entry.key);
      const stored = current.jobs.find((job) => job.id === entry.jobId);
      persistedData = structuredClone(stored.data);
      assert.equal(stored.status, 'received');
      assert.equal(stored.attempts, 0);
      assert.equal(stored.operator_resolution, undefined);
      assert(current.uncertain_events.includes(entry.jobId), '未确认归属前必须保留栅栏');
      assert.equal(current.mode, 'ai');
      assert.equal(modelRequests.length, beforeModels);
      assert.equal(retrievalRequests.length, beforeRetrievals);
      assert.equal(sendAttempts, beforePosts);
      assert.equal(sent.filter((item) => item.session_id === session).length, beforeSent);
    } finally {
      replacement?.cleanup();
    }
    now += 1001;
    let exactLookups = 0;
    const recovered = createRuntime(env, { ...runtimeOptions,
      request: async (url, options = {}) => {
        const parsed = new URL(url);
        if (parsed.pathname.includes('/conversation/' + encodeURIComponent(session) + '/message/')) {
          exactLookups += 1;
        }
        return request(url, options);
      } });
    assert.deepEqual(await recovered.process(entry.key, entry.jobId),
      { status: 'deferred', reason: 'operator_identity_pending' });
    const pendingState = recovered.readState(entry.key);
    const pendingJob = pendingState.jobs.find((job) => job.id === entry.jobId);
    assert.equal(exactLookups, 1);
    assert.equal(pendingJob.status, 'received');
    assert.equal(pendingJob.attempts, 1);
    assert.equal(pendingJob.responsibility_status, 'unresolved_failure');
    assert.equal(pendingJob.failure_code, 'operator_identity_pending');
    assert.equal(pendingJob.operator_resolution, undefined);
    assert(Number.isFinite(pendingJob.retry_at) && pendingJob.retry_at > now);
    assert.deepEqual(pendingJob.data, persistedData, '身份待确认时必须保留原始控制责任');
    for (const field of ['session_id', 'fingerprint', 'from', 'type', 'content', 'timestamp']) {
      assert.deepEqual(pendingJob.data[field], data[field], '持久控制消息身份字段不得改变：' + field);
    }
    assert(pendingState.uncertain_events.includes(entry.jobId), '官方身份仍不明时必须继续 fail-closed');
    assert.equal(pendingState.mode, 'ai');
    assert.equal(modelRequests.length, beforeModels);
    assert.equal(retrievalRequests.length, beforeRetrievals);
    assert.equal(sendAttempts, beforePosts);
    assert.equal(sent.filter((item) => item.session_id === session).length, beforeSent);

    // 同一官方消息后续获得明确 automated 身份时，必须收敛原控制责任；
    // 不得把身份未决直接猜成非人工，也不得在恢复过程中触发模型或访客出站。
    histories.set(session, [{ ...data, automated: true }]);
    now = pendingJob.retry_at;
    const resolved = await recovered.process(entry.key, entry.jobId);
    assert.equal(resolved.status, 'none');
    assert.equal(exactLookups, 2);
    const resolvedState = recovered.readState(entry.key);
    const resolvedJob = resolvedState.jobs.find((job) => job.id === entry.jobId);
    assert.equal(resolvedJob.status, 'done');
    assert.equal(resolvedJob.attempts, 2);
    assert.equal(resolvedJob.responsibility_status, 'control_handled');
    assert.equal(resolvedJob.responsibility_reason, 'operator_identity_resolved');
    assert.equal(resolvedJob.operator_resolution.result, 'not-human');
    assert.equal(resolvedJob.operator_resolution.human_changed, false);
    assert.equal(resolvedJob.data, undefined);
    assert.equal(resolvedJob.execution_token, undefined);
    assert.equal(resolvedJob.processing_permit_losses, undefined);
    assert.equal(resolvedState.uncertain_events.includes(entry.jobId), false);
    assert.equal(resolvedState.mode, 'ai');
    assert.equal(Object.values(resolvedState.outgoing || {})
      .some((record) => record?.job_id === entry.jobId), false);
    assert.equal(modelRequests.length, beforeModels);
    assert.equal(retrievalRequests.length, beforeRetrievals);
    assert.equal(sendAttempts, beforePosts);
    assert.equal(sent.filter((item) => item.session_id === session).length, beforeSent);

    // 同一栅栏还要覆盖 control 的旧执行迟到：新代次已接管后，
    // 旧 resolve_operator 不得写入 unknown/human，也不得改变新任务的尝试次数。
    const staleSession = 'session_permit-lost-control-stale';
    let staleStartedResolve, releaseLookup;
    let lookupReleased = false;
    const staleStarted = new Promise((resolve) => { staleStartedResolve = resolve; });
    const lookupRelease = new Promise((resolve) => { releaseLookup = resolve; });
    const releaseLookupGate = () => {
      if (!lookupReleased && releaseLookup) { lookupReleased = true; releaseLookup(); }
    };
    const staleControl = createRuntime(env, { ...runtimeOptions, processingPermitHeartbeatMilliseconds: 10,
      request: async (url, options = {}) => {
        const parsed = new URL(url);
        if (/\/message\/[^/]+$/.test(parsed.pathname)) {
          staleStartedResolve();
          await lookupRelease; // 故意忽略 signal，由返回后 fence 拒绝旧结果。
        }
        return request(url, options);
      } });
    const staleData = message(staleSession, '另一条待核验人工回复',
      { from: 'operator', automated: undefined }).data;
    histories.set(staleSession, [{ ...staleData }]);
    const staleEntry = await staleControl.receive({ body: { website_id: env.CRISP_WEBSITE_ID,
      event: 'message:received', timestamp: now, data: staleData }, query: { key: env.CRISP_WEBSITE_HOOK_SECRET } });
    const staleRunning = staleControl.process(staleEntry.key, staleEntry.jobId);
    let staleReplacement;
    try {
      await awaitNamedGate(staleStarted, '旧人工归属精确回查开始');
      await waitForPermitSlot(7);
      staleReplacement = replacePermitOwner(7, 'control');
      const newerToken = 'e'.repeat(24);
      await staleControl.transaction(staleEntry.key, (state) => {
        const job = state.jobs.find((item) => item.id === staleEntry.jobId);
        job.execution_token = newerToken; job.status = 'processing'; job.attempts = 23;
        job.lease_until = now + 300000;
      });
      releaseLookupGate();
      assert.deepEqual(await staleRunning, { status: 'deferred', reason: 'processing_permit_lost' });
      const staleState = staleControl.readState(staleEntry.key);
      const staleJob = staleState.jobs.find((item) => item.id === staleEntry.jobId);
      assert.equal(staleJob.execution_token, newerToken);
      assert.equal(staleJob.status, 'processing');
      assert.equal(staleJob.attempts, 23);
      assert.equal(staleJob.operator_resolution, undefined);
      assert(staleState.uncertain_events.includes(staleEntry.jobId));
      await staleControl.transaction(staleEntry.key, (state) => {
        const job = state.jobs.find((item) => item.id === staleEntry.jobId);
        job.status = 'cancelled'; job.lease_until = 0; delete job.execution_token;
      });
    } finally {
      releaseLookupGate();
      staleReplacement?.cleanup();
    }
  });
  await test('P0 Crisp POST 中失去许可保留 unknown 对账，回执确认后不重新推理或重复发送', async () => {
    const session = 'session_permit-lost-outgoing';
    let startedResolve;
    const started = new Promise((resolve) => { startedResolve = resolve; });
    const beforeModels = modelRequests.length;
    const beforeSent = sent.filter((entry) => entry.session_id === session).length;
    const outgoingRuntime = createRuntime(env, { ...runtimeOptions, processingPermitHeartbeatMilliseconds: 10,
      request: async (url, options = {}) => {
        const parsed = new URL(url);
        const match = parsed.pathname.match(/\/conversation\/([^/]+)(\/.*)$/);
        if (match && match[2] === '/message' && options.method === 'POST') {
          const body = options.body;
          const history = histories.get(session) || [];
          sent.push({ ...body, session_id: session });
          history.push({ ...body, timestamp: now });
          histories.set(session, history);
          return abortablePending(options.signal, startedResolve);
        }
        return request(url, options);
      } });
    const body = message(session, '请验证未知回执只对账不重发');
    histories.set(session, [{ ...body.data }]);
    const entry = await outgoingRuntime.receive({ body, query: { key: env.CRISP_WEBSITE_HOOK_SECRET } });
    const running = outgoingRuntime.process(entry.key, entry.jobId);
    let replacement;
    let current;
    let afterFirstModels;
    try {
      await awaitNamedGate(started, 'Crisp 正文 POST 开始');
      await waitForPermitSlot(0);
      replacement = replacePermitOwner(0, 'ordinary');
      assert.deepEqual(await running, { status: 'deferred', reason: 'processing_permit_lost' });
      current = outgoingRuntime.readState(entry.key);
      const unknown = Object.values(current.outgoing).find((record) => record.job_id === entry.jobId);
      assert.equal(unknown.status, 'unknown');
      assert.equal(unknown.delivery_uncertain, true);
      assert.equal(unknown.cancellation_reason, 'processing_permit_lost');
      assert.equal(current.jobs.find((job) => job.id === entry.jobId).status, 'received');
      assert.equal(sent.filter((item) => item.session_id === session).length, beforeSent + 1);
      afterFirstModels = modelRequests.length;
      assert.equal(afterFirstModels, beforeModels + 1);
    } finally {
      replacement?.cleanup();
    }

    now += 1001;
    const recovered = createRuntime(env, runtimeOptions);
    assert.equal((await recovered.process(entry.key, entry.jobId)).status, 'sent');
    current = recovered.readState(entry.key);
    assert.equal(Object.values(current.outgoing).find((record) => record.job_id === entry.jobId).status, 'sent');
    assert.equal(current.jobs.find((job) => job.id === entry.jobId).status, 'done');
    assert.equal(modelRequests.length, afterFirstModels, '对账确认不得重新调用模型');
    assert.equal(sent.filter((item) => item.session_id === session).length, beforeSent + 1,
      '相同 fingerprint 已确认后不得重复 POST');
  });
  await test('P0 答案已确定发送后标签阶段失去许可，仍保持 sent 且不重排', async () => {
    const session = 'session_permit-lost-after-sent';
    let startedResolve;
    const started = new Promise((resolve) => { startedResolve = resolve; });
    const beforeSent = sent.filter((entry) => entry.session_id === session).length;
    const sentRuntime = createRuntime(env, { ...runtimeOptions, processingPermitHeartbeatMilliseconds: 10,
      request: async (url, options = {}) => {
        const parsed = new URL(url);
        const match = parsed.pathname.match(/\/conversation\/([^/]+)(\/.*)$/);
        if (match && match[2] === '/meta' && options.method === 'GET') {
          return abortablePending(options.signal, startedResolve);
        }
        return request(url, options);
      } });
    const body = message(session, '请验证已发送回执不回滚');
    histories.set(session, [{ ...body.data }]);
    const entry = await sentRuntime.receive({ body, query: { key: env.CRISP_WEBSITE_HOOK_SECRET } });
    const running = sentRuntime.process(entry.key, entry.jobId);
    let replacement;
    try {
      await awaitNamedGate(started, '答案发送后的标签读取开始');
      await waitForPermitSlot(0);
      replacement = replacePermitOwner(0, 'ordinary');
      const result = await running;
      assert.equal(result.status, 'sent');
      const current = sentRuntime.readState(entry.key);
      const stored = current.jobs.find((job) => job.id === entry.jobId);
      const outgoing = Object.values(current.outgoing).find((record) => record.job_id === entry.jobId);
      assert.equal(stored.status, 'done');
      assert.equal(stored.retry_at, null);
      assert.equal(stored.execution_token, undefined);
      assert.equal(outgoing.status, 'sent');
      assert.equal(sent.filter((item) => item.session_id === session).length, beforeSent + 1);
    } finally {
      replacement?.cleanup();
    }
  });
  await test('P0 已冻结 sent 回执在外层许可丢失后按闭合矩阵收敛且不重发', async () => {
    const cases = [
      { suffix: 'valid-answer', semanticStatus: 'valid_answer', semanticIntent: 'answer',
        receiptCurrent: true, expectedStatus: 'sent', ai: true, expectAiReply: true },
      { suffix: 'control', semanticStatus: 'control_delivered', semanticIntent: 'control',
        receiptCurrent: true, expectedStatus: 'sent', control: true },
      { suffix: 'receipt-not-current', semanticStatus: 'valid_answer', semanticIntent: 'answer',
        receiptCurrent: false, expectedStatus: 'dispatched_after_cancel', ai: true,
        expectStateChange: true },
      { suffix: 'receipt-not-current-already-counted', semanticStatus: 'valid_answer',
        semanticIntent: 'answer', receiptCurrent: false,
        expectedStatus: 'dispatched_after_cancel', ai: true,
        countedPresent: true, countedValue: true, countedGeneration: 0 },
      { suffix: 'receipt-not-current-legacy-counted', semanticStatus: 'valid_answer',
        semanticIntent: 'answer', receiptCurrent: false,
        expectedStatus: 'dispatched_after_cancel', ai: true,
        countedPresent: true, countedValue: true },
      { suffix: 'next-generation-valid-answer-after-counted-late-delivery',
        semanticStatus: 'valid_answer', semanticIntent: 'answer', receiptCurrent: true,
        responseGeneration: 1, expectedStatus: 'sent', ai: true, expectAiReply: true,
        countedPresent: true, countedValue: true, countedGeneration: 0 },
      { suffix: 'semantic-unknown', semanticStatus: 'semantic_unknown', semanticIntent: 'unknown',
        receiptCurrent: null, expectedStatus: 'delivery_semantic_unknown', ai: true },
      { suffix: 'legacy-bare-claim', semanticStatus: 'valid_answer', semanticIntent: 'answer',
        receiptCurrent: true, expectedStatus: 'delivery_evidence_unavailable', bareClaim: true, ai: true },
      { suffix: 'valid-answer-count-conflict-true', semanticStatus: 'valid_answer',
        semanticIntent: 'answer', receiptCurrent: true,
        expectedStatus: 'delivery_identity_unresolved', ai: true,
        countedPresent: true, countedValue: true,
        expectedCountFailure: 'delivery_state_change_count_conflict' },
      { suffix: 'valid-answer-count-conflict-false', semanticStatus: 'valid_answer',
        semanticIntent: 'answer', receiptCurrent: true,
        expectedStatus: 'delivery_identity_unresolved', ai: true,
        countedPresent: true, countedValue: false,
        expectedCountFailure: 'delivery_state_change_count_conflict' },
      { suffix: 'control-count-conflict-null', semanticStatus: 'control_delivered',
        semanticIntent: 'control', receiptCurrent: true,
        expectedStatus: 'delivery_identity_unresolved', control: true,
        countedPresent: true, countedValue: null,
        expectedCountFailure: 'delivery_state_change_count_conflict' },
      { suffix: 'semantic-unknown-count-conflict-object', semanticStatus: 'semantic_unknown',
        semanticIntent: 'unknown', receiptCurrent: null,
        expectedStatus: 'delivery_identity_unresolved', ai: true,
        countedPresent: true, countedValue: { invalid: true },
        expectedCountFailure: 'delivery_state_change_count_conflict' },
      { suffix: 'receipt-not-current-count-invalid-false', semanticStatus: 'valid_answer',
        semanticIntent: 'answer', receiptCurrent: false,
        expectedStatus: 'delivery_identity_unresolved', ai: true,
        countedPresent: true, countedValue: false,
        expectedCountFailure: 'delivery_state_change_count_invalid' },
      { suffix: 'receipt-not-current-count-invalid-null', semanticStatus: 'valid_answer',
        semanticIntent: 'answer', receiptCurrent: false,
        expectedStatus: 'delivery_identity_unresolved', ai: true,
        countedPresent: true, countedValue: null,
        expectedCountFailure: 'delivery_state_change_count_invalid' },
      { suffix: 'receipt-not-current-count-invalid-object', semanticStatus: 'valid_answer',
        semanticIntent: 'answer', receiptCurrent: false,
        expectedStatus: 'delivery_identity_unresolved', ai: true,
        countedPresent: true, countedValue: { invalid: true },
        expectedCountFailure: 'delivery_state_change_count_invalid' },
      { suffix: 'receipt-not-current-count-future-generation', semanticStatus: 'valid_answer',
        semanticIntent: 'answer', receiptCurrent: false,
        expectedStatus: 'delivery_identity_unresolved', ai: true,
        countedPresent: true, countedValue: true, countedGeneration: 1,
        expectedCountFailure: 'delivery_state_change_count_invalid' },
      { suffix: 'valid-answer-orphan-count-generation', semanticStatus: 'valid_answer',
        semanticIntent: 'answer', receiptCurrent: true,
        expectedStatus: 'delivery_identity_unresolved', ai: true,
        countedGeneration: 0,
        expectedCountFailure: 'delivery_state_change_count_conflict' },
    ];
    const analytics = path.join(root, 'data/analytics/events.jsonl');
    const countEvents = (type) => fs.existsSync(analytics)
      ? fs.readFileSync(analytics, 'utf8').trim().split('\n').filter(Boolean)
        .map((line) => JSON.parse(line)).filter((event) => event.type === type).length : 0;
    const permitRoot = path.join(root, 'data/runtime/ordinary-processing-permits');
    const permitCount = () => fs.existsSync(permitRoot)
      ? fs.readdirSync(permitRoot).filter((name) => /^slot-[0-7]$/.test(name)
        || /^\.stale-slot-[0-7]-[a-f0-9]{32}$/.test(name)).length : 0;
    for (const [index, item] of cases.entries()) {
      const session = 'session_permit-lost-frozen-' + item.suffix;
      const content = '已冻结的受控答案 ' + item.suffix;
      const fingerprint = Number.parseInt(digest('permit-lost-frozen|' + item.suffix).slice(0, 12), 16);
      let startedResolve;
      let lookupCalls = 0;
      const started = new Promise((resolve) => { startedResolve = resolve; });
      const frozenRuntime = createRuntime(env, { ...runtimeOptions,
        processingPermitHeartbeatMilliseconds: 10,
        request: async (url, options = {}) => {
          const parsed = new URL(url);
          const match = parsed.pathname.match(/\/conversation\/([^/]+)(\/.*)$/);
          if (match && decodeURIComponent(match[1]) === session
            && /^\/message\/[^/]+$/.test(match[2])) {
            lookupCalls += 1;
            return abortablePending(options.signal, startedResolve);
          }
          return request(url, options);
        } });
      const body = message(session, '外层许可丢失闭合矩阵回执 ' + index);
      delete body.timestamp;
      delete body.data.timestamp;
      const entry = await frozenRuntime.receive({ body,
        query: { key: env.CRISP_WEBSITE_HOOK_SECRET } });
      assert.equal(entry.route, 'process');
      let frozenData;
      let frozenPlan;
      let frozenRecord;
      await frozenRuntime.transaction(entry.key, (current) => {
        const stored = current.jobs.find((job) => job.id === entry.jobId); assert(stored);
        assert.equal(stored.event_time_unverified, true);
        if (item.control) {
          stored.control = true;
          stored.action = 'confirm_handoff';
          stored.confirm_message = content;
        }
        const purpose = item.control ? 'handoff_ack' : 'ai_text';
        stored.response_generation = item.responseGeneration || 0;
        stored.plan = { type: 'text', purpose, ordinary: item.control !== true,
          ai: item.ai === true, content, fingerprint, tags: [],
          ...(item.bareClaim ? { answer_responsibility: 'clarification_confirmed' } : {}) };
        if (!item.control) {
          // ai_text 必须来自可核验的 Provider producer。这个矩阵验证的是
          // Crisp 回执收敛，不得用缺少推理权威的伪造 plan 绕过 fail-closed。
          stored.inference_generation = 1;
          stored.inference = {
            runtime_revision: stored.revision,
            pool_revision: null,
            deadline_at: now + 90000,
            attempt_generation: 1,
            provider_receipt_protocol_version: 1,
          };
          stored.provider_settlement = {
            schema_version: 1,
            state: 'settled',
            plan_sha256: digest(canonical({
              type: stored.plan.type || '',
              purpose: stored.plan.purpose || '',
              content: stored.plan.content || '',
              outcome: stored.plan.outcome || '',
              sources: stored.plan.sources || [],
              tags: stored.plan.tags || [],
            })),
            response_generation: stored.response_generation,
            attempts: 1,
            settled_at: now - 1,
          };
          assert.deepEqual(Object.keys(stored.inference).sort(), [
            'attempt_generation', 'deadline_at', 'pool_revision',
            'provider_receipt_protocol_version', 'runtime_revision',
          ].sort());
          assert.deepEqual(Object.keys(stored.provider_settlement).sort(), [
            'attempts', 'plan_sha256', 'response_generation', 'schema_version',
            'settled_at', 'state',
          ].sort());
          assert.equal(Object.hasOwn(stored, 'provider_result_receipt'), false);
          assert.equal(Object.hasOwn(stored, 'provider_migration_from'), false);
          assert.equal(Object.hasOwn(stored, 'provider_settlement_failure_code'), false);
          assert.equal(Object.hasOwn(stored, 'provider_retirement'), false);
          assert.equal(Object.hasOwn(stored, 'provider_retirement_failure_code'), false);
        } else {
          assert.equal(Object.hasOwn(stored, 'inference'), false);
          assert.equal(Object.hasOwn(stored, 'provider_result_receipt'), false);
          assert.equal(Object.hasOwn(stored, 'provider_settlement'), false);
        }
        if (item.countedPresent) {
          stored.delivery_state_change_counted = structuredClone(item.countedValue);
        }
        if (Object.hasOwn(item, 'countedGeneration')) {
          stored.delivery_state_change_counted_generation = item.countedGeneration;
        }
        frozenData = structuredClone(stored.data);
        frozenPlan = structuredClone(stored.plan);
        current.outgoing[String(fingerprint)] = {
          status: 'sent', created_at: now - 1, sent_at: now - 1, attempts: 1,
          job_id: stored.id, generation: stored.generation,
          response_generation: stored.response_generation,
          delivery_identity_version: 1, purpose, message_type: 'text',
          semantic_intent: item.semanticIntent, semantic_status: item.semanticStatus,
          content_sha256: digest(canonical({ type: 'text', content })),
          attempt_token: digest('permit-lost-frozen-attempt|' + item.suffix).slice(0, 32),
          receipt_confirmed_at: now - 1,
          receipt_current: item.receiptCurrent,
          ...(item.receiptCurrent === false ? {
            receipt_state_change_reason: 'configuration_changed',
            state_changed_before_receipt: true,
          } : {}),
          ...(item.semanticStatus === 'semantic_unknown' ? { resend_forbidden: true } : {}),
        };
        frozenRecord = structuredClone(current.outgoing[String(fingerprint)]);
      });

      const baseline = { models: modelRequests.length, retrievals: retrievalRequests.length,
        posts: sendAttempts, visible: sent.length, aiReplies: countEvents('ai_reply'),
        stateChanges: countEvents('delivery_after_state_change') };
      const running = frozenRuntime.process(entry.key, entry.jobId);
      running.catch(() => {});
      const slot = item.control ? 7 : 0;
      let replacement;
      let result;
      try {
        await awaitNamedGate(started, '冻结回执的精确消息回查开始');
        await waitForPermitSlot(slot);
        replacement = replacePermitOwner(slot, item.control ? 'control' : 'ordinary');
        await awaitNamedGate(running.then((value) => { result = value; }),
          '冻结回执的外层许可丢失收敛', 10000);
      } finally {
        replacement?.cleanup();
      }
      assert.equal(result.status, item.expectedStatus);
      assert.equal(lookupCalls, 1, '每个子例只允许一次精确消息回查');
      assert(replacement);
      assert.equal(fs.existsSync(replacement.slotPath), false);
      assert.equal(fs.existsSync(replacement.quarantine), false);
      assert.equal(permitCount(), 0, '子例收口后不得遗留普通或控制许可');

      const snapshot = frozenRuntime.readState(entry.key);
      const stored = snapshot.jobs.find((job) => job.id === entry.jobId); assert(stored);
      const records = Object.values(snapshot.outgoing)
        .filter((record) => record.job_id === entry.jobId);
      assert.equal(records.length, 1, '已冻结回执不得补建第二条出站责任');
      assert.deepEqual(snapshot.outgoing[String(fingerprint)], frozenRecord,
        '已冻结 fingerprint 及回执身份不得在许可丢失收敛中改写');
      assert.equal(snapshot.worker, null);
      assert.equal(stored.execution_token, undefined);
      assert.equal(stored.processing_permit_losses, undefined);
      assert.equal(stored.lease_until, 0);

      if (item.expectedCountFailure) {
        assert.equal(stored.status, 'done');
        assert.equal(stored.responsibility_status, 'unresolved_failure');
        assert.equal(stored.failure_code, item.expectedCountFailure);
        assert.equal(stored.recovery_requires_review, true);
        assert.equal(stored.retry_at, null);
        assert.deepEqual(stored.delivery_state_change_counted, item.countedValue,
          '冲突或畸形计数标志必须原样保留供诊断');
        if (Object.hasOwn(item, 'countedGeneration')) {
          assert.equal(stored.delivery_state_change_counted_generation,
            item.countedGeneration, '冲突计数代次必须原样保留供诊断');
        }
        assert.deepEqual(stored.data, frozenData);
        assert.deepEqual(stored.plan, frozenPlan);
      } else if (item.semanticStatus === 'semantic_unknown') {
        assert.equal(stored.status, 'received');
        assert.equal(stored.responsibility_status, 'unresolved_failure');
        assert.equal(stored.failure_code, 'delivery_semantic_unknown');
        assert.equal(stored.retry_at, now + 300000);
        assert.deepEqual(stored.data, frozenData);
        assert.deepEqual(stored.plan, frozenPlan);
      } else if (item.bareClaim) {
        assert.equal(stored.status, 'done');
        assert.equal(stored.responsibility_status, 'unresolved_failure');
        assert.equal(stored.failure_code, 'delivery_evidence_unavailable');
        assert.equal(stored.recovery_requires_review, true);
        assert.equal(stored.retry_at, null);
        assert.deepEqual(stored.data, frozenData);
        assert.equal(stored.plan, undefined);
      } else if (item.receiptCurrent === false) {
        assert.equal(stored.status, 'done');
        assert.equal(stored.responsibility_status, 'unresolved_failure');
        assert.equal(stored.failure_code, 'delivery_after_state_change');
        assert.equal(stored.delivery_state_change_counted, true);
        assert.equal(stored.delivery_state_change_counted_generation,
          stored.response_generation, '一次性计数必须绑定当前回答代');
        assert.equal(stored.data, undefined);
        assert.equal(stored.plan, undefined);
      } else if (item.control) {
        assert.equal(stored.status, 'done');
        assert.equal(stored.responsibility_status, 'control_handled');
        assert.equal(stored.responsibility_reason, 'confirm_handoff');
        assert.equal(stored.data, undefined);
        assert.equal(stored.plan, undefined);
      } else {
        assert.equal(stored.status, 'done');
        assert.equal(stored.responsibility_status, 'answered_confirmed');
        assert.equal(stored.answer_metrics_counted, true);
        assert.equal(snapshot.observations.ai_reply_sent_at, now);
        assert.equal(stored.data, undefined);
        assert.equal(stored.plan, undefined);
      }
      const expectedAiReplies = item.expectAiReply ? 1 : 0;
      const expectedStateChanges = item.expectStateChange ? 1 : 0;
      assert.equal(countEvents('ai_reply'), baseline.aiReplies + expectedAiReplies);
      assert.equal(countEvents('delivery_after_state_change'),
        baseline.stateChanges + expectedStateChanges);
      if (!expectedAiReplies) {
        assert.equal(stored.answer_metrics_counted, undefined);
        assert.equal(snapshot.observations?.ai_reply_sent_at, undefined);
      }
      assert.deepEqual({ models: modelRequests.length, retrievals: retrievalRequests.length,
        posts: sendAttempts, visible: sent.length }, {
        models: baseline.models, retrievals: baseline.retrievals,
        posts: baseline.posts, visible: baseline.visible,
      },
      '外层许可丢失只能消费已冻结回执，不得新推理或新出站');
      assert.equal((await frozenRuntime.process(entry.key, entry.jobId)).status, 'idle');
      assert.deepEqual({ models: modelRequests.length, retrievals: retrievalRequests.length,
        posts: sendAttempts, visible: sent.length }, {
        models: baseline.models, retrievals: baseline.retrievals,
        posts: baseline.posts, visible: baseline.visible,
      },
      '重复执行不得重新推理或重发已冻结正文');
      assert.equal(countEvents('ai_reply'), baseline.aiReplies + expectedAiReplies);
      assert.equal(countEvents('delivery_after_state_change'),
        baseline.stateChanges + expectedStateChanges);
      assert.equal(permitCount(), 0, '重复执行后不得遗留许可');
      assert.equal(Object.values(frozenRuntime.readState(entry.key).outgoing)
        .filter((record) => record.job_id === entry.jobId).length, 1);
    }
  });
  await test('V122-R03 控制优先时仍为普通会话保留一个扫描名额', async () => {
    const ordinary = await receive(message('session_capacity-fair-ordinary', '普通待处理问题'));
    const controlKeys = new Set();
    for (let index = 0; index < 16; index += 1) {
      const session = 'session_capacity-fair-control-' + String(index).padStart(2, '0');
      const data = message(session, '待核验 operator', { from: 'operator', automated: undefined }).data;
      const item = await receive({ website_id: env.CRISP_WEBSITE_ID, event: 'message:received', timestamp: now,
        data: { ...data, session_id: session } });
      assert.equal(item.route, 'process');
      controlKeys.add(item.key);
    }
    const selected = await runtime.scan();
    assert.equal(selected.length, 8);
    assert.equal(selected.filter((entry) => entry.control).length, 7);
    assert(selected.some((entry) => !entry.control),
      '控制任务很多时仍须保留至少一个普通任务名额');
  });
  await test('L08 请求/解析异常落盘前采用白名单，不泄漏秘密或用户正文', async () => {
    const injected = 'synthetic-private-text & $ # = " 引号\n第二行';
    const variants = [injected, JSON.stringify(injected), encodeURIComponent(injected), Buffer.from(injected).toString('base64')];
    for (const [index, variant] of variants.entries()) {
      const isolated = createRuntime(env, { ...runtimeOptions, request: async () => { throw new SyntaxError(variant); } });
      const session = 'session_log-private-' + index;
      const beforeSent = sent.filter((item) => item.session_id === session).length;
      const beforeModels = modelRequests.length;
      const body = message(session, '无敏感资料的虚构问题');
      const entry = await isolated.receive({ body, query: { key: env.CRISP_WEBSITE_HOOK_SECRET } });
      const result = await isolated.process(entry.key, entry.jobId);
      assert.deepEqual(result, { status: 'deferred', reason: 'answer_responsibility_unresolved' });
      const unresolved = isolated.readState(entry.key).jobs.find((job) => job.id === entry.jobId);
      assert(unresolved?.data, '技术异常后必须保留原始应答责任');
      assert.equal(unresolved.status, 'received');
      assert.equal(unresolved.responsibility_status, 'unresolved_failure');
      assert.equal(unresolved.failure_code, 'runtime_processing_failed');
      assert(Number.isFinite(unresolved.retry_at));
      assert.equal(sent.filter((item) => item.session_id === session).length, beforeSent,
        '技术异常不得生成可见机械或空泛话术');
      const log = fs.readFileSync(path.join(root, 'data/analytics/events.jsonl'), 'utf8');
      assert(log.includes('配置或协议 JSON 解析失败'));
      for (const secret of variants) {
        assert(!log.includes(secret), '异常正文不得进入落盘日志');
        assert(!JSON.stringify(result).includes(secret));
      }
      await runtime.transaction(entry.key, (current) => {
        const job = current.jobs.find((item) => item.id === entry.jobId); assert(job); job.retry_at = 0;
      });
      const recovered = await runtime.process(entry.key, entry.jobId);
      assert.equal(recovered.status, 'sent');
      assert.equal(modelRequests.length, beforeModels + 1);
      assert.equal(sent.filter((item) => item.session_id === session).length, beforeSent + 1,
        '恢复后同一问题只发送一份有效答案');
      assert.equal(state(session).jobs.find((job) => job.id === entry.jobId).responsibility_status,
        'answered_confirmed');
    }
    assert.equal(state('session_permanent1').mode, 'human');
  });
  const savedNumericMenu = readConfig('menu');
  const savedNumericRuntime = readConfig('runtime');
  publishConfiguration('runtime', { ...savedNumericRuntime, enabled: true });
  publishConfiguration('menu', { welcome: { enabled: false }, root: 'main', menus: {
    main: { title: 'NUMERIC-ROOT', options: {
      '1': { label: 'NUMERIC-MOBILE', action: { type: 'menu', target: 'mobile' } },
      '2': { label: 'NUMERIC-ROOT-REPLY', action: { type: 'reply', text: 'NUMERIC-ROOT-TWO' } },
      '0': { label: 'NUMERIC-HANDOFF', action: { type: 'show_handoff_offer' } },
    } },
    mobile: { title: 'NUMERIC-MOBILE', options: {
      '1': { label: 'NUMERIC-IOS', action: { type: 'prompt', prompt: 'NUMERIC-MENU-IOS-ONLY' } },
      '2': { label: 'NUMERIC-MOBILE-REPLY', action: { type: 'reply', text: 'NUMERIC-MOBILE-TWO' } },
      '0': { label: 'NUMERIC-BACK', action: { type: 'menu', target: 'main' } },
    } },
  } });
  const numericRoot = async (session) => {
    await deliver(message(session, '菜单'));
    const card = sent.at(-1);
    assert.equal(card.type, 'picker');
    assert.equal(card.content.text, 'NUMERIC-ROOT');
    assert.equal(state(session).outgoing[String(card.fingerprint)].status, 'sent');
    return card;
  };
  const numericMobile = async (session) => {
    const card = await numericRoot(session);
    await deliver(click(session, card));
    assert.equal(sent.at(-1).content.text, 'NUMERIC-MOBILE');
    return sent.at(-1);
  };
  try {
    await test('MNU01 新主菜单数字按已送达绑定导航，子菜单数字正确且消费一次', async () => {
      const session = 'session_numeric-fresh-01';
      const beforeModels = modelRequests.length;
      const rootCard = await numericRoot(session);
      const entry = await receive(message(session, '1'));
      const queued = state(session).jobs.find((job) => job.id === entry.jobId);
      assert.equal(queued.action, 'menu_action');
      assert.equal(queued.control, false, '数字业务选择仍参加普通会话调度');
      assert.equal(queued.data.content, '1', '落盘保留真实访客原话');
      assert.equal(queued.choice_action.option_id, '1');
      assert.equal((await runtime.process(entry.key, entry.jobId)).status, 'sent');
      assert.equal(sent.at(-1).content.text, 'NUMERIC-MOBILE');
      assert(state(session).offers[rootCard.content.id].consumed_at != null);
      const child = sent.at(-1);
      await deliver(message(session, '2'));
      assert.equal(sent.at(-1).content, 'NUMERIC-MOBILE-TWO');
      assert(state(session).offers[child.content.id].consumed_at != null);
      assert.equal(modelRequests.length, beforeModels, '本地菜单导航和固定答复不调用模型');
    });
    await test('MNU02 原生选择消费后旧导航不截获后续数字，当前上下文不携带旧咨询方向', async () => {
      const session = 'session_numeric-consumed-02';
      const card = await numericMobile(session);
      await deliver(click(session, card));
      assert(state(session).offers[card.content.id].consumed_at != null);
      await deliver(message(session, '现在处理电脑上的另一个问题'));
      const beforeModels = modelRequests.length;
      await deliver(message(session, '2'));
      assert.equal(modelRequests.length, beforeModels + 1);
      assert.notEqual(sent.at(-1).content, 'NUMERIC-MOBILE-TWO');
      assert(!textOfRequest(modelRequests.at(-1)).includes('NUMERIC-MENU-IOS-ONLY'));
      assert.equal(textOf(messagesOf(modelRequests.at(-1)).at(-1)), '2');
    });
    await test('MNU03 普通咨询、过期、错代及早于菜单的数字不消费有效按钮', async () => {
      for (const variant of ['ordinary', 'expired', 'revision', 'generation', 'older-input', 'late-sent']) {
        const session = 'session_numeric-boundary-' + variant;
        const card = await numericMobile(session);
        const baselineNow = now;
        try {
          if (variant === 'ordinary') await deliver(message(session, '继续处理另一项电脑咨询'));
          if (variant === 'expired') now += 601000;
          if (['revision', 'generation', 'late-sent'].includes(variant)) {
            await runtime.transaction(key(session), (current) => {
              const offer = current.offers[card.content.id];
              if (variant === 'revision') offer.revision -= 1;
              if (variant === 'generation') offer.generation -= 1;
              if (variant === 'late-sent') current.outgoing[String(card.fingerprint)].sent_at = now + 1;
            });
          }
          const beforeModels = modelRequests.length;
          const input = message(session, '2', variant === 'older-input' ? { timestamp: now - 60000 } : {});
          await deliver(input);
          assert.equal(modelRequests.length, beforeModels + 1, variant);
          assert.notEqual(sent.at(-1).content, 'NUMERIC-MOBILE-TWO', variant);
          assert.equal(state(session).offers[card.content.id].consumed_at, null, variant);
        } finally { now = baselineNow; }
      }
    });
    await test('MNU04 未登记、未知送达、发送中或身份不匹配的菜单不把数字登记成选择', async () => {
      for (const variant of ['missing-outgoing', 'unknown', 'sending', 'wrong-purpose', 'wrong-fingerprint', 'unverified-time']) {
        const session = 'session_numeric-unverified-' + variant;
        const card = await numericMobile(session);
        await runtime.transaction(key(session), (current) => {
          const record = current.outgoing[String(card.fingerprint)];
          if (variant === 'missing-outgoing') delete current.outgoing[String(card.fingerprint)];
          if (variant === 'unknown' || variant === 'sending') record.status = variant;
          if (variant === 'wrong-purpose') record.purpose = 'keyword_reply';
          if (variant === 'wrong-fingerprint') current.offers[card.content.id].fingerprint += 1;
        });
        const input = message(session, '2');
        if (variant === 'unverified-time') { delete input.timestamp; delete input.data.timestamp; }
        const entry = await receive(input);
        assert.equal(entry.accepted, true, variant);
        const stored = state(session).jobs.find((job) => job.id === entry.jobId);
        assert.equal(stored.action, undefined, variant);
        assert.equal(stored.choice_action, undefined, variant);
        assert.equal(stored.data.content, '2', variant);
        assert.equal(state(session).offers[card.content.id].consumed_at, null, variant);
      }
    });
    await test('MNU05 数字选择在前置失败及重建runtime后保留，重复事件不消费或回复两次', async () => {
      const session = 'session_numeric-retry-05';
      const card = await numericMobile(session);
      const input = message(session, '1');
      const entry = await receive(input);
      const beforeModels = modelRequests.length;
      let historyFailure = true;
      const isolated = createRuntime(env, { ...runtimeOptions, request: async (url, options) => {
        if (historyFailure && new URL(url).pathname.endsWith('/messages')) {
          historyFailure = false; throw new Error('synthetic menu history unavailable');
        }
        return request(url, options);
      } });
      await isolated.process(entry.key, entry.jobId);
      const stored = state(session).jobs.find((job) => job.id === entry.jobId);
      assert.equal(stored.status, 'received');
      assert.equal(stored.data.content, '1');
      assert.equal(stored.choice_action.action.prompt, 'NUMERIC-MENU-IOS-ONLY');
      assert(state(session).offers[card.content.id].consumed_at != null);
      assert.equal(modelRequests.length, beforeModels);
      assert.equal((await receive(input)).reason, '重复事件已忽略');
      runtime = createRuntime(env, runtimeOptions);
      await runtime.transaction(entry.key, (current) => {
        current.jobs.find((job) => job.id === entry.jobId).retry_at = 0;
      });
      const retryRetrievals = retrievalRequests.length;
      assert.equal((await runtime.process(entry.key, entry.jobId)).status, 'sent');
      assert.equal(modelRequests.length, beforeModels + 1);
      assert(textOfRequest(modelRequests.at(-1)).includes('NUMERIC-MENU-IOS-ONLY'));
      assert.deepEqual(retrievalRequests.slice(retryRetrievals), [{ query: 'NUMERIC-IOS\nNUMERIC-MENU-IOS-ONLY' }],
        '数字菜单在前置异常及重建后仍以已绑定方向检索，不以数字或旧导航检索');
      const count = sent.filter((item) => item.session_id === session).length;
      assert.equal((await receive(input)).reason, '重复事件已忽略');
      assert.equal(sent.filter((item) => item.session_id === session).length, count);
    });
    await test('MNU09 菜单已送达事实进入后续上下文，未知非自有及隐私消息不伪造完成', async () => {
      const session = 'session_menu-history-09';
      const card = await numericMobile(session);
      const entry = await receive(click(session, card));
      const saved = state(session);
      const job = saved.jobs.find(row => row.id === entry.jobId);
      const history = structuredClone(histories.get(session));
      const rootCard = history.find(row => row.type === 'picker' && row.fingerprint !== card.fingerprint);
      assert(rootCard, '必须先经真实接收/规划/发送保存原生主菜单');
      const originalSent = sent.filter(row => row.session_id === session).length;
      const prior = runtime.transcript(history, job, saved);
      console.log('观察菜单历史上下文：' + JSON.stringify({
        original_navigation_retained: prior.some(row => row.role === 'user' && row.content === '菜单'),
        confirmed_menu_display_retained: prior.some(row => row.role === 'assistant' && row.content === '已展示客服菜单。'),
        current_selection_not_in_history: !prior.some(row => row.content.includes('NUMERIC-IOS')),
        actual_menu_posts: originalSent,
      }));
      assert(prior.some(row => row.role === 'assistant' && row.content === '已展示客服菜单。'),
        '菜单已确认送达，其展示事实必须保留在后续上下文');
      assert(prior.some(row => row.role === 'user' && row.content === '菜单'));
      console.log('观察菜单选择意图基线：' + JSON.stringify({
        accepted_navigation_retained: prior.some(row => row.role === 'user' && row.content === '客户选择：NUMERIC-MOBILE'),
        current_selection_excluded: !prior.some(row => row.content.includes('NUMERIC-IOS')),
      }));
      assert(prior.some(row => row.role === 'user' && row.content === '客户选择：NUMERIC-MOBILE'),
        '已持久接受的实际手机导航选择必须作为客户事实进入后续上下文');
      const navigation = saved.jobs.find(row => row.choice_action?.action?.target === 'mobile');
      const rootChoiceIndex = rootCard.content.choices.findIndex(choice => choice.label === navigation?.choice_action?.label);
      assert(rootChoiceIndex >= 0, '已验证的手机导航必须对应实际主菜单选项');
      const nativeHistory = structuredClone(history);
      for (const item of nativeHistory.filter(row => row.type === 'picker')) {
        item.content = click(session, item, item.fingerprint === rootCard.fingerprint ? rootChoiceIndex : 0).data.content;
      }
      const nativeBefore = JSON.stringify(nativeHistory), stateBefore = JSON.stringify(saved);
      const nativePrior = runtime.transcript(nativeHistory, job, saved);
      console.log('观察原生已选菜单历史基线：' + JSON.stringify({
        selected_menu_display_retained: nativePrior.some(row => row.role === 'assistant' && row.content === '已展示客服菜单。'),
        original_menu_posts: originalSent, native_selected_marks: nativeHistory.filter(row => row.type === 'picker')
          .reduce((total, row) => total + row.content.choices.filter(choice => choice.selected === true).length, 0),
      }));
      assert(nativePrior.some(row => row.role === 'assistant' && row.content === '已展示客服菜单。'),
        '原生选择只改变selected，已确认菜单展示事实不得丢失');
      assert(!nativePrior.some(row => row.content.includes('NUMERIC-IOS')), '当前选择不得混入历史');
      assert.equal(JSON.stringify(nativeHistory), nativeBefore, '历史校验不改写官方picker');
      assert.equal(JSON.stringify(saved), stateBefore, '历史校验不改写持久状态');
      assert.equal(nativePrior.filter(row => row.role === 'user' && row.content === '客户选择：NUMERIC-MOBILE').length, 1,
        '原生已选与未标选择的历史只恢复一次已接受导航，不恢复全菜单');
      const selectionConflicts = [
        ['missing-job', value => { value.jobs = value.jobs.filter(row => row.id !== navigation.id); }],
        ['cancelled', value => { value.jobs.find(row => row.id === navigation.id).status = 'cancelled'; }],
        ['failed', value => { value.jobs.find(row => row.id === navigation.id).status = 'failed'; }],
        ['pending', value => { value.jobs.find(row => row.id === navigation.id).status = 'received'; }],
        ['wrong-action', value => { value.jobs.find(row => row.id === navigation.id).action = 'invalid_choice'; }],
        ['wrong-label', value => { value.jobs.find(row => row.id === navigation.id).choice_action.label += 'changed'; }],
        ['wrong-binding', value => { value.jobs.find(row => row.id === navigation.id).choice_action.action.target = 'changed'; }],
        ['missing-identity', value => { delete value.jobs.find(row => row.id === navigation.id).input_identity_sha256; }],
        ['wrong-covered-id', value => { value.jobs.find(row => row.id === navigation.id).covered_message_ids = ['changed']; }],
        ['unverified-time', value => { value.jobs.find(row => row.id === navigation.id).event_time_unverified = true; }],
        ['future-selection', value => { value.jobs.find(row => row.id === navigation.id).event_time = job.event_time + 1; }],
        ['future-sequence', value => { value.jobs.find(row => row.id === navigation.id).sequence = job.sequence + 1; }],
        ['wrong-generation', value => { value.jobs.find(row => row.id === navigation.id).generation += 1; }],
        ['wrong-revision', value => { value.jobs.find(row => row.id === navigation.id).revision += 1; }],
        ['missing-offer', value => { delete value.offers[rootCard.content.id]; }],
        ['unconsumed-offer', value => { value.offers[rootCard.content.id].consumed_at = null; }],
        ['wrong-offer-revision', value => { value.offers[rootCard.content.id].revision += 1; }],
        ['wrong-offer-kind', value => { value.offers[rootCard.content.id].kind = 'handoff'; }],
        ['future-consumption', value => { value.offers[rootCard.content.id].consumed_at = job.received_at + 1; }],
        ['duplicate-selection', value => { value.jobs.push({ ...structuredClone(value.jobs.find(row => row.id === navigation.id)), id: 'duplicate-navigation' }); }],
      ];
      for (const [variant, mutate] of selectionConflicts) {
        const value = structuredClone(saved); mutate(value);
        assert(!runtime.transcript(nativeHistory, job, value).some(row => row.content === '客户选择：NUMERIC-MOBILE'), variant);
      }
      const afterExpiry = structuredClone(job);
      afterExpiry.event_time += 601000; afterExpiry.received_at += 601000;
      assert(runtime.transcript(nativeHistory, afterExpiry, saved).some(row => row.content === '客户选择：NUMERIC-MOBILE'),
        '菜单按钮到期不抹掉此前确已接受的客户选择事实');
      assert(!nativePrior.some(row => row.role === 'user' && ['NUMERIC-ROOT-REPLY', 'NUMERIC-HANDOFF'].some(label => row.content.includes(label))),
        '未选择的菜单项不能作为客户意图');
      const numericSession = 'session_menu-history-numeric-09';
      await numericRoot(numericSession);
      await deliver(message(numericSession, '1'));
      const numericCard = sent.at(-1);
      assert.equal(numericCard.content.text, 'NUMERIC-MOBILE');
      const numericEntry = await receive(click(numericSession, numericCard));
      const numericState = state(numericSession), numericJob = numericState.jobs.find(row => row.id === numericEntry.jobId);
      assert(runtime.transcript(histories.get(numericSession), numericJob, numericState)
        .some(row => row.role === 'user' && row.content === '客户选择：NUMERIC-MOBILE'),
        '数字选择已按真实offer接收时也要保留实际导航事实，不能信任任意数字');
      const fingerprint = String(rootCard.fingerprint);
      const mutations = [
        ['unknown', (rows, value) => { value.outgoing[fingerprint].status = 'unknown'; }],
        ['sending', (rows, value) => { value.outgoing[fingerprint].status = 'sending'; }],
        ['missing-record', (rows, value) => { delete value.outgoing[fingerprint]; }],
        ['wrong-content', rows => { rows.find(row => String(row.fingerprint) === fingerprint).content.text += 'changed'; }],
        ['private', rows => { rows.find(row => String(row.fingerprint) === fingerprint).stealth = true; }],
        ['private-properties', rows => { rows.find(row => String(row.fingerprint) === fingerprint).properties = { stealth: true }; }],
        ['nonowned', rows => { rows.find(row => String(row.fingerprint) === fingerprint).fingerprint += 101; }],
        ['wrong-generation', (rows, value) => { value.outgoing[fingerprint].generation += 1; }],
        ['wrong-type', (rows, value) => { value.outgoing[fingerprint].message_type = 'text'; }],
        ['wrong-purpose', (rows, value) => { value.outgoing[fingerprint].purpose = 'handoff_offer'; }],
        ['wrong-semantic', (rows, value) => { value.outgoing[fingerprint].semantic_intent = 'answer'; }],
        ['future', rows => { rows.find(row => String(row.fingerprint) === fingerprint).timestamp = job.event_time + 1; }],
      ];
      for (const [variant, mutate] of mutations) {
        const rows = structuredClone(history), value = structuredClone(saved);
        mutate(rows, value);
        assert(!runtime.transcript(rows, job, value).some(row => row.content === '已展示客服菜单。'), variant);
      }
      for (const [variant, mutate] of mutations) {
        const rows = structuredClone(nativeHistory), value = structuredClone(saved);
        mutate(rows, value);
        assert(!runtime.transcript(rows, job, value).some(row => row.content === '已展示客服菜单。'), '原生已选：' + variant);
      }
      const nativeConflicts = [
        ['changed-label', content => { content.choices[0].label += 'changed'; }],
        ['changed-value', content => { content.choices[0].value += 'changed'; }],
        ['changed-text', content => { content.text += 'changed'; }],
        ['changed-id', content => { content.id += 'changed'; }],
        ['changed-required', content => { content.required = true; }],
        ['changed-order', content => { content.choices.reverse(); }],
        ['added-choice', content => { content.choices.push({ label: 'changed', value: 'changed', selected: false }); }],
        ['added-field', content => { content.choices[0].unexpected = 'changed'; }],
        ['removed-choice', content => { content.choices.pop(); }],
        ['invalid-selected-type', content => { content.choices[0].selected = 'true'; }],
        ['multiple-selected', content => { for (const choice of content.choices) choice.selected = true; }],
      ];
      for (const [variant, mutate] of nativeConflicts) {
        const rows = structuredClone(nativeHistory);
        mutate(rows.find(row => String(row.fingerprint) === fingerprint).content);
        assert(!runtime.transcript(rows, job, saved).some(row => row.content === '已展示客服菜单。'), variant);
      }
      assert.equal(sent.filter(row => row.session_id === session).length, originalSent, '历史组装不触发发送');
      histories.set(session, nativeHistory);
      const beforeModels = modelRequests.length, beforeRetrievals = retrievalRequests.length;
      assert.equal((await runtime.process(entry.key, entry.jobId)).status, 'sent');
      assert.equal(modelRequests.length, beforeModels + 1);
      const currentRetrievals = retrievalRequests.slice(beforeRetrievals);
      console.log('观察菜单意图检索基线：' + JSON.stringify({
        query: currentRetrievals[0]?.query, expected_query: 'NUMERIC-IOS\nNUMERIC-MENU-IOS-ONLY',
        retrieval_calls: currentRetrievals.length, model_calls: modelRequests.length - beforeModels,
      }));
      assert.deepEqual(currentRetrievals, [{ query: 'NUMERIC-IOS\nNUMERIC-MENU-IOS-ONLY' }],
        '已验证菜单咨询方向必须进入检索，不能只在模型生成时附加');
      const requestMessages = messagesOf(modelRequests.at(-1));
      assert(requestMessages.some(row => row.role === 'assistant' && textOf(row) === '已展示客服菜单。'));
      assert.equal(textOf(requestMessages.at(-1)), 'NUMERIC-IOS', '实际选择不被历史导航覆盖');
      assert.equal(requestMessages.filter(row => row.role === 'user' && textOf(row) === '客户选择：NUMERIC-MOBILE').length, 1,
        '真实组装请求必须保留已验证的客户导航事实');
      assert(textOfRequest(modelRequests.at(-1)).includes('NUMERIC-MENU-IOS-ONLY'));
      const followupRetrievals = retrievalRequests.length, followupModels = modelRequests.length;
      await deliver(message(session, '后续独立问题，不再咨询手机排障'));
      assert.deepEqual(retrievalRequests.slice(followupRetrievals), [{ query: '后续独立问题，不再咨询手机排障' }],
        '已消费菜单方向不能污染后续独立问题的检索');
      assert.equal(modelRequests.length, followupModels + 1);
      assert(messagesOf(modelRequests.at(-1)).some(row => row.role === 'user' && textOf(row) === '客户选择：NUMERIC-IOS'),
        '消费过的实际平台选择应留在后续历史，不能把整个菜单或提示词作为客户原话');
      console.log('观察菜单选择意图：' + JSON.stringify({
        accepted_navigation_retained: true, selected_platform_retained_in_followup: true, current_selection_excluded: true,
        only_selected_labels_retained: true, selection_conflicts_rejected: selectionConflicts.length,
        numeric_navigation_retained: true, accepted_choice_retained_after_button_expiry: true,
        official_picker_and_state_unchanged: true, additional_posts_during_history: 0,
      }));
      console.log('观察菜单意图检索：' + JSON.stringify({
        validated_direction_retrieved: true, current_question_preserved: true, retrieval_calls: 1, model_calls: 1,
        consumed_direction_absent_from_followup: true, followup_retrieval_calls: 1, followup_model_calls: 1,
      }));
      console.log('观察菜单历史反例：' + JSON.stringify({ variants: mutations.length, conflicts_rejected: true,
        additional_posts_during_history: 0, model_calls_for_consultation: followupModels - beforeModels }));
      console.log('观察原生已选菜单历史：' + JSON.stringify({
        selected_menu_display_retained: true, native_selected_marks: 2, current_selection_not_in_history: true,
        original_conflicts_rejected: mutations.length, immutable_conflicts_rejected: nativeConflicts.length,
        official_picker_and_state_unchanged: true, additional_posts_during_history: 0, model_calls_for_consultation: 1,
      }));
    });
    await test('MNU06 数字人工入口仅展示确认，真人确认及总关继续正确静默', async () => {
      const session = 'session_numeric-handoff-06';
      await numericRoot(session);
      await deliver(message(session, '0'));
      const card = sent.at(-1);
      assert.equal(card.type, 'picker');
      assert.equal(state(session).mode, 'ai');
      await deliver(click(session, card));
      assert.equal(state(session).mode, 'human');
      const humanCount = sent.filter((item) => item.session_id === session).length;
      await deliver(message(session, '2'));
      assert.equal(sent.filter((item) => item.session_id === session).length, humanCount);
      const disabledSession = 'session_numeric-disabled-06';
      await numericRoot(disabledSession);
      const currentRuntime = readConfig('runtime');
      publishConfiguration('runtime', { ...currentRuntime, enabled: false });
      try {
        const count = sent.filter((item) => item.session_id === disabledSession).length;
        await deliver(message(disabledSession, '2'));
        assert.equal(sent.filter((item) => item.session_id === disabledSession).length, count);
      } finally { publishConfiguration('runtime', { ...currentRuntime, enabled: true }); }
    });
  } finally {
    runtime = createRuntime(env, runtimeOptions);
    publishConfiguration('menu', savedNumericMenu);
    publishConfiguration('runtime', savedNumericRuntime);
  }
  process.stdout.write(JSON.stringify({ layer: 'UNIT/CONTRACT', passed, failed: 0, evidence: path.relative(project, root) }) + '\n');
})().catch((error) => { process.stderr.write(error.stack + '\n'); process.exitCode = 1; });
