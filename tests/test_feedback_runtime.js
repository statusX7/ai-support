'use strict';

// 全部资料与网络回应均为 synthetic；测试直接运行生产 runtime，不连接真实 Crisp。
const assert = require('assert/strict');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { spawnSync } = require('child_process');
const { createRuntime, mechanicalFailureAnswer } = require('../n8n/runtime');
const { visitorFallbackFor, legacyGenericNonAnswer } = require('../scripts/visitor-output');

const project = path.resolve(__dirname, '..');
const work = path.join(project, '.work', 'v1.3.0');
fs.mkdirSync(work, { recursive: true });
const evidence = fs.mkdtempSync(path.join(work, 'feedback-runtime-'));
const canonical = value => Array.isArray(value) ? '[' + value.map(canonical).join(',') + ']'
  : value && typeof value === 'object' ? '{' + Object.keys(value).sort()
    .map(key => JSON.stringify(key) + ':' + canonical(value[key])).join(',') + '}'
    : JSON.stringify(value);
const digest = (value) => crypto.createHash('sha256')
  .update(Buffer.isBuffer(value) ? value : String(value)).digest('hex');
const waitForAbort = async (signal, label) => {
  for (let attempt = 0; attempt < 300 && !signal?.aborted; attempt += 1) {
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  assert.equal(signal?.aborted, true, label + ' 必须观察到生产取消信号，不能依赖固定睡眠猜竞态');
};
const sealMaterials = (projection) => {
  const runtime = structuredClone(projection.configuration.runtime);
  delete runtime.revision;
  delete runtime.applied_revision;
  projection.source_components = {
    runtime: digest(canonical(runtime)),
    handoff: digest(canonical(projection.configuration.handoff)),
    keyword: digest(canonical(projection.configuration.keyword)),
    menu: digest(canonical(projection.configuration.menu)),
    tags: digest(canonical(projection.configuration.tags)),
    feedback: digest(canonical(projection.configuration.feedback)),
    prompt: projection.prompt.sha256,
    knowledge: digest(canonical(projection.knowledge)),
  };
  projection.source_sha256 = digest(canonical(projection.source_components));
  return projection;
};
const invitation = '此回答是否解决问题？\n👍 是\n👎 否';
const clarification = '你最希望先解决哪一处？可以把具体情况、相关提示和已经尝试的方法一起告诉我。';
const imageClarification = '请把图片中的关键信息或报错文字贴出来，并说明你正在进行的操作和希望解决的问题。';
const legacyFailure = '暂时无法回复，请稍后再试。';
const messagesOf = body => body.messages || body.input;
const textOf = message => typeof message.content === 'string' ? message.content
  : message.content.filter(part => ['text', 'input_text', 'output_text'].includes(part.type)).map(part => part.text).join('\n');
const textOfRequest = body => messagesOf(body).map(textOf).join('\n');
const projection = 'kb_1111111111111111_doc_2222222222222222.md';
const retrievalResult = (distance = 0.1) => ({ id: 'synthetic-feedback-chunk', text: '问题：如何保存设置？\n回答：在设置页面保存后重试。',
  metadata: { title: projection }, distance, score: 1 - distance });
const makeFixture = (name, { materials: materialsMode = 'current' } = {}) => {
  if (!['current', 'absent'].includes(materialsMode)) {
    throw new Error('materials 仅支持 current 或 absent');
  }
  const root = path.join(evidence, name);
  for (const directory of ['config', 'data/runtime', 'data/analytics']) fs.mkdirSync(path.join(root, directory), { recursive: true });
  for (const name of ['keyword', 'handoff', 'menu', 'tags', 'feedback', 'provider']) fs.copyFileSync(path.join(project, 'config', name + '.yaml.example'), path.join(root, 'config', name + '.yaml'));
  fs.writeFileSync(path.join(root, '.crisp-ai-installation'), 'ai-support\nstate=local-ready\n');
  const prompt = '这是用户原有 Prompt，必须完整保留。请根据知识回答客户问题。';
  fs.writeFileSync(path.join(root, 'config/prompt.md'), prompt);
  const readConfig = (name) => JSON.parse(fs.readFileSync(path.join(root, 'config', name + '.yaml')));
  const writeConfig = (name, value) => fs.writeFileSync(path.join(root, 'config', name + '.yaml'), JSON.stringify(value));
  writeConfig('runtime', { schema_version: 2, enabled: true, revision: 1, applied_revision: 1 });
  const menu = readConfig('menu'); menu.welcome.enabled = false; writeConfig('menu', menu);
  const feedback = readConfig('feedback');
  Object.assign(feedback.feedback, { enabled: true, auto_invite: true, prompt: invitation, negative_keywords: ['否', '👎', '还不行'], positive_keywords: ['是', '👍'] });
  writeConfig('feedback', feedback);
  writeConfig('provider', { provider: { base_url: 'https://provider.invalid/v1', model: 'synthetic-model', api_mode: 'chat_completions', supports_vision: true } });
  fs.writeFileSync(path.join(root, 'data/runtime/knowledge-map.json'), JSON.stringify({ schema_version: 2, documents: [{
    library_id: 'kb_1111111111111111', document_id: 'doc_2222222222222222', projection,
    location: 'custom-documents/' + projection + '-33333333-3333-4333-8333-333333333333.json',
  }] }));
  const env = { CRISP_WEBSITE_ID: '11111111-1111-4111-8111-111111111111', CRISP_WEBSITE_HOOK_SECRET: 'synthetic-feedback-hook-0001', CRISP_AUTH_B64: 'synthetic-feedback-auth', PROVIDER_ADAPTER_KEY: 'synthetic-feedback-adapter-key', AI_API_KEY: 'synthetic-feedback-key', AI_SUPPORTS_VISION: 'true', ANYTHINGLLM_API_KEY: 'synthetic-feedback-rag', ANYTHINGLLM_WORKSPACE: 'synthetic-feedback' };
  let now = Date.now();
  let sequence = 1000;
  let runtime;
  const sent = [];
  const postAttempts = [];
  const modelRequests = [];
  const visionRequests = [];
  const retrievalRequests = [];
  const workspaceRequests = [];
  const histories = new Map();
  const exactRequests = [];
  const metaRequests = [];
  const catchupConversationPages = new Map();
  const catchupRequests = [];
  const patches = [];
  const modes = { modelFailure: false, imageFailure: false, historyFailure: false, exactFailure: false,
    answer: '受控业务答案：请在设置中保存后重试。' };
  const request = async (url, options = {}) => {
    const parsed = new URL(url);
    const conversationPage = /\/website\/[^/]+\/conversations\/([0-9]+)$/.exec(parsed.pathname);
    if (conversationPage) {
      const page = Number(conversationPage[1]);
      const start = Date.parse(parsed.searchParams.get('filter_date_start'));
      const end = Date.parse(parsed.searchParams.get('filter_date_end'));
      const configured = catchupConversationPages.get(page) || [];
      const data = configured.filter((conversation) => {
        const updated = typeof conversation?.updated_at === 'number'
          ? conversation.updated_at : Date.parse(conversation?.updated_at);
        return !Number.isFinite(updated) || updated >= start && updated <= end;
      });
      catchupRequests.push({ type: 'conversations', page, start, end });
      return { status: 200, body: { error: false, data } };
    }
    const match = parsed.pathname.match(/\/conversation\/([^/]+)(\/.*)$/);
    if (match) {
      const session = decodeURIComponent(match[1]);
      const suffix = match[2];
      const history = histories.get(session) || [];
      if (suffix === '/messages') {
        if (modes.onCrispHistoryRequest) {
          await modes.onCrispHistoryRequest({ session_id: session,
            history: structuredClone(history), signal: options.signal });
        }
        let listed = modes.listHistoryOverride === undefined ? history
          : typeof modes.listHistoryOverride === 'function' ? modes.listHistoryOverride(session, history) : modes.listHistoryOverride;
        if (parsed.searchParams.has('timestamp_after')) {
          const after = Number(parsed.searchParams.get('timestamp_after'));
          catchupRequests.push({ type: 'messages', session_id: session, after });
          listed = listed.filter((message) => !Number.isFinite(Number(message?.timestamp))
            || Number(message.timestamp) > after);
        }
        return { status: modes.historyFailure ? 503 : 200, body: { error: modes.historyFailure, data: listed } };
      }
      if (suffix.startsWith('/message/')) {
        exactRequests.push({ session_id: session, fingerprint: suffix.slice(9) });
        const status = modes.exactStatus ?? (modes.exactFailure ? 503 : 200);
        return { status, body: { error: status < 200 || status >= 300,
          data: history.find((item) => String(item.fingerprint) === suffix.slice(9)) || {} } };
      }
      if (suffix === '/meta' && options.method === 'GET') {
        metaRequests.push({ method: 'GET', session_id: session });
        return { status: 200, body: { error: false, data: { segments: ['existing-manual-segment'] } } };
      }
      if (suffix === '/meta' && options.method === 'PATCH') {
        metaRequests.push({ method: 'PATCH', session_id: session });
        patches.push(options.body); return { status: 200, body: { error: false } };
      }
      if (suffix === '/message' && options.method === 'POST') {
        const body = structuredClone(options.body);
        postAttempts.push({ ...body, session_id: session });
        if (modes.crispDropBeforeAccept) {
          if (modes.onCrispPost) await modes.onCrispPost({ body, signal: options.signal });
          throw Object.assign(new Error('synthetic-crisp-post-dropped'), { code: 'ECONNRESET' });
        }
        if (modes.crispPostResponse) {
          const response = structuredClone(modes.crispPostResponse);
          if (modes.crispPostResponseOnce !== false) modes.crispPostResponse = null;
          return response;
        }
        sent.push({ ...body, session_id: session });
        history.push({ ...body, timestamp: now }); histories.set(session, history);
        if (modes.onCrispPost) await modes.onCrispPost({ body, signal: options.signal });
        if (modes.crispPostThrow
          || options.signal?.aborted && modes.crispIgnoreAbortAfterAccept !== true) {
          throw Object.assign(new Error('synthetic-crisp-post-uncertain'), { code: 'ECONNRESET' });
        }
        return { status: 200, body: { error: false, reason: 'dispatched', data: { fingerprint: body.fingerprint } } };
      }
      throw new Error('未知 synthetic Crisp 路径：' + suffix);
    }
    if (parsed.hostname === 'anythingllm') {
      assert.equal(options.headers.Authorization, 'Bearer ' + env.ANYTHINGLLM_API_KEY);
      const workspacePath = '/api/v1/workspace/' + env.ANYTHINGLLM_WORKSPACE;
      if (parsed.pathname === workspacePath) {
        assert.equal(options.method, 'GET'); assert.equal(options.body, undefined);
        workspaceRequests.push(parsed.pathname);
        return { status: modes.workspaceStatus ?? 200, body: modes.workspacePayload ?? { workspace: [{ slug: env.ANYTHINGLLM_WORKSPACE, openAiTemp: null }] } };
      }
      assert.equal(parsed.pathname, workspacePath + '/vector-search'); assert.equal(options.method, 'POST');
      assert.deepEqual(Object.keys(options.body), ['query']);
      retrievalRequests.push(structuredClone(options.body));
      return { status: 200, body: modes.retrievalPayload ?? { results: [retrievalResult()] } };
    }
    if (parsed.hostname === 'provider.invalid') {
      assert.equal(options.method, 'POST'); assert.equal(options.headers.Authorization, 'Bearer ' + env.AI_API_KEY);
      assert.equal(parsed.pathname, options.body.input ? '/v1/responses' : '/v1/chat/completions');
      const hasImage = messagesOf(options.body).some(message => Array.isArray(message.content)
        && message.content.some(part => ['image_url', 'input_image'].includes(part.type)));
      let content;
      if (hasImage) {
        visionRequests.push(structuredClone(options.body));
        if (modes.visionFailure) return { status: 503, body: { error: { code: 'synthetic-vision-error' } } };
        content = typeof modes.visionAnswer === 'function' ? modes.visionAnswer(structuredClone(options.body)) : modes.visionAnswer ?? '截图显示保存设置按钮。';
        if (modes.onVisionResponse) await modes.onVisionResponse();
      } else {
        modelRequests.push(structuredClone(options.body));
        assert.equal(options.body.temperature, modes.expectedTemperature ?? 0.7);
        if (modes.onModelResponse) await modes.onModelResponse();
        if (modes.modelThrow) throw Object.assign(new Error('synthetic-timeout'), { code: 'ETIMEDOUT' });
        if (modes.modelPayload !== undefined) return { status: 200, body: modes.modelPayload };
        if (modes.modelFailure) return { status: 503, body: { error: 'synthetic-failure' } };
        content = modes.answer;
      }
      return { status: 200, body: options.body.input ? { output: [{ type: 'message', role: 'assistant', content: [{ type: 'output_text', text: content }] }] } : { choices: [{ message: { content } }] } };
    }
    if (parsed.hostname === 'storage.crisp.chat') return { status: modes.imageFailure ? 404 : 200, headers: { 'content-type': 'image/png' }, body: Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=', 'base64') };
    throw new Error('禁止非 synthetic 网络请求');
  };
  const restart = () => { runtime = createRuntime(env, { root, clock: () => now, request, lookup: (_host, _options, callback) => callback(null, [{ address: '8.8.8.8', family: 4 }]) }); return runtime; };
  const key = (session) => runtime.stateKey(env.CRISP_WEBSITE_ID, session);
  const state = (session) => runtime.readState(key(session));
  const stateFile = (session) => path.join(root, 'data/runtime/session-' + key(session) + '.json');
  const rawState = (session) => JSON.parse(fs.readFileSync(stateFile(session)));
  const event = (session, content, overrides = {}) => ({ website_id: env.CRISP_WEBSITE_ID, event: 'message:send', timestamp: now, data: { session_id: session, from: 'user', type: 'text', content, fingerprint: ++sequence, timestamp: now, ...overrides } });
  const receive = (body) => runtime.receive({ body, query: { key: env.CRISP_WEBSITE_HOOK_SECRET } });
  const deliver = async (body) => { const accepted = await receive(body); assert.equal(accepted.accepted, true); return accepted.route === 'process' ? runtime.process(accepted.key, accepted.jobId) : accepted; };
  const seed = async (session, mutate) => {
    await runtime.transaction(key(session), () => {}, env.CRISP_WEBSITE_ID, session);
    const current = rawState(session); mutate(current); fs.writeFileSync(stateFile(session), JSON.stringify(current));
  };
  const makeJob = (session, label, plan, overrides = {}) => ({ id: digest(session + '|' + label), event: 'message:send', data: event(session, '旧队列的普通问题').data, event_time: now, received_at: now, sequence: ++sequence, status: 'received', attempts: 0, revision: 1, generation: 0, control: false, ...(plan ? { plan } : {}), ...overrides });
  const legacyUnpooled = (job) => {
    assert(job && !job.inference, 'legacyUnpooled 只能补全尚无推理身份的旧夹具');
    job.inference = { pool_revision: null, deadline_at: now + 90000 };
    return job;
  };
  const currentUnpooled = (job, deadlineAt = now + 90000) => {
    assert(job && !job.inference, 'currentUnpooled 只能补全尚无推理身份的当前夹具');
    job.inference_generation = 1;
    job.inference = { runtime_revision: job.revision, pool_revision: null,
      deadline_at: deadlineAt, attempt_generation: 1, provider_receipt_protocol_version: 1 };
    return job;
  };
  const makeOutgoing = (job, content, status = 'unknown') => {
    const type = job.plan.type || 'text';
    const wireContent = type === 'picker' && content && typeof content === 'object'
      && !Array.isArray(content) ? { ...content, required: false } : content;
    return { status,
    body: { type, from: 'operator', origin: 'chat', automated: true,
      fingerprint: job.plan.fingerprint, content: wireContent },
    created_at: now - 15000, attempts: 1, attempt_token: digest('attempt|' + job.id).slice(0, 32),
    job_id: job.id, generation: job.generation,
    ...(status === 'sent' ? { sent_at: now - 10000 } : {}) };
  };
  let atomicSequence = 0;
  const atomicWrite = (file, data) => {
    const temporary = file + '.next-' + process.pid + '-' + (++atomicSequence);
    try {
      fs.writeFileSync(temporary, data, { mode: 0o600, flag: 'wx' });
      fs.renameSync(temporary, file);
      assert.equal(fs.statSync(file).mode & 0o777, 0o600);
    } finally {
      if (fs.existsSync(temporary)) fs.unlinkSync(temporary);
    }
  };
  const writeAppliedMaterials = (configuration) => {
    const revision = configuration.runtime.revision;
    const mapFile = path.join(root, 'data/runtime/knowledge-map.json');
    const mapRaw = fs.readFileSync(mapFile);
    const settings = Buffer.from(JSON.stringify({ schema_version: 1, workspace_slug: env.ANYTHINGLLM_WORKSPACE,
      temperature: 0.7, observed_at: now }));
    atomicWrite(path.join(root, 'data/runtime/knowledge-settings.json'), settings);
    const profile = { engine: 'native', model: 'synthetic-feedback-embedding', chunk_size: 1000,
      chunk_overlap: 20, passage_prefix: '', query_prefix: '', component_version: 'synthetic' };
    const profileProjection = Buffer.from(JSON.stringify({ schema_version: 1, state: 'applied', profile,
      fingerprint: digest(canonical(profile)), applied_at: now }));
    atomicWrite(path.join(root, 'data/runtime/knowledge-profile.json'), profileProjection);
    const lexicalPayload = { schema_version: 2, algorithm: 'crispai-lexical-v2',
      map_sha256: digest(mapRaw), complete: false,
      coverage: { source_documents: 1, indexed_documents: 0, omitted_documents: 1,
        source_bytes: 0, indexed_bytes: 0, omitted_bytes: 0, reasons: ['empty_source'] },
      passages: [] };
    const lexical = Buffer.from(JSON.stringify({ ...lexicalPayload,
      payload_sha256: digest(canonical(lexicalPayload)) }));
    atomicWrite(path.join(root, 'data/runtime/knowledge-lexical.json'), lexical);
    const materials = sealMaterials({ schema_version: 2, state: 'applied', revision,
      applied_at: now, source_sha256: '', source_components: {}, configuration,
      prompt: { text: prompt, bytes: Buffer.byteLength(prompt), sha256: digest(prompt) },
      knowledge: {
        catalog_revision: 1, catalog_sha256: digest('synthetic-feedback-catalog'),
        manifest_sha256: digest('synthetic-feedback-manifest'), map_sha256: digest(mapRaw),
        settings_sha256: digest(settings), profile_sha256: digest(profileProjection),
        lexical_sha256: digest(lexical), enabled_library_ids: ['kb_1111111111111111'],
        library_count: 1, document_count: 1, enabled_document_count: 1,
      } });
    atomicWrite(path.join(root, 'config/materials-applied.json'), JSON.stringify(materials));
    return materials;
  };
  const currentConfiguration = () => Object.fromEntries(
    ['runtime', 'handoff', 'keyword', 'menu', 'tags', 'feedback']
      .map((component) => [component, readConfig(component)]));
  const publishCurrentMaterials = () => {
    const expected = currentConfiguration();
    const materials = writeAppliedMaterials(expected);
    assert.equal(materials.schema_version, 2);
    assert.equal(materials.state, 'applied');
    assert.equal(materials.revision, expected.runtime.revision);
    assert.deepEqual(materials.configuration, expected);
    assert.equal(fs.statSync(path.join(root, 'config/materials-applied.json')).mode & 0o777, 0o600);
    return materials;
  };
  // 生产 runtime 对应用投影 fail closed。绝大多数业务夹具显式从一个当前、
  // 完整的投影开始；需要验证 absent/stale 窗口的场景必须在创建时单独声明，
  // 不能让 writeConfig() 暗中同步并掩盖真实应用边界。
  if (materialsMode === 'current') publishCurrentMaterials();
  else assert.equal(fs.existsSync(path.join(root, 'config/materials-applied.json')), false);
  restart();
  const events = () => { const file = path.join(root, 'data/analytics/events.jsonl'); return fs.existsSync(file) ? fs.readFileSync(file, 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse) : []; };
  const noFeedback = () => {
    assert(!sent.some((item) => typeof item.content === 'string' && item.content.includes(invitation)), '不能发送系统自动评价邀请');
    assert(!events().some((item) => item.type === 'feedback'), '不能新登记自动评价');
  };
  return { root, prompt, env, sent, postAttempts, patches, histories, exactRequests, metaRequests,
    catchupConversationPages, catchupRequests, modelRequests, visionRequests, retrievalRequests,
    workspaceRequests, modes, key, state, rawState, seed, makeJob, makeOutgoing, event,
    receive, deliver, readConfig, writeConfig, writeAppliedMaterials, currentConfiguration,
    publishCurrentMaterials, legacyUnpooled, currentUnpooled, restart, events, noFeedback,
    runtime: () => runtime, advance: (milliseconds) => { now += milliseconds; }, now: () => now };
};

let passed = 0;
let failed = 0;
const test = async (name, action) => {
  try { await action(); passed += 1; process.stdout.write('通过 UNIT/CONTRACT ' + name + '\n'); }
  catch (error) { failed += 1; process.stdout.write('失败 UNIT/CONTRACT ' + name + '\n' + error.stack + '\n'); }
};
const visibleFor = (fixture, session) => fixture.sent.filter((item) => item.session_id === session);
const assertUnresolvedResponsibility = (fixture, session, jobId, originalContent) => {
  assert.equal(visibleFor(fixture, session).length, 0, '技术故障轮不得发送 generic/image 兜底');
  const jobs = fixture.rawState(session).jobs.filter((job) => job.id === jobId);
  assert.equal(jobs.length, 1, '同一访客输入必须只有一条持久应答责任');
  const job = jobs[0];
  assert.equal(job.status, 'received');
  assert.equal(job.responsibility_status, 'unresolved_failure');
  assert(job.data, '未解决责任必须保留原访客输入');
  if (originalContent !== undefined) assert.deepEqual(job.data.content, originalContent);
  assert(Number.isFinite(job.retry_at) && job.retry_at > fixture.now(), '未解决责任必须登记后续恢复时间');
  return job;
};
const recoverSameJobOnce = async (fixture, session, jobId, expectedContent) => {
  fixture.advance(300001); fixture.restart();
  const scheduled = await fixture.runtime().scan();
  assert(scheduled.some((item) => item.key === fixture.key(session) && item.jobId === jobId),
    '外部条件恢复后必须重新调度同一 job');
  const result = await fixture.runtime().process(fixture.key(session), jobId);
  if (result.status !== 'sent') {
    const state = fixture.rawState(session);
    const job = state.jobs.find((entry) => entry.id === jobId) || {};
    const generation = job.response_generation ?? 0;
    const inference = job.inference;
    const settlement = job.provider_settlement;
    const plan = job.plan;
    const inferenceKeys = inference && typeof inference === 'object' && !Array.isArray(inference)
      ? Object.keys(inference).sort() : [];
    const settlementKeys = settlement && typeof settlement === 'object' && !Array.isArray(settlement)
      ? Object.keys(settlement).sort() : [];
    const expectedInferenceKeys = ['attempt_generation', 'deadline_at', 'pool_revision',
      'provider_receipt_protocol_version', 'runtime_revision'].sort();
    const expectedSettlementKeys = ['attempts', 'plan_sha256', 'response_generation',
      'schema_version', 'settled_at', 'state'].sort();
    const planSha256 = plan ? digest(canonical({
      type: plan.type || '', purpose: plan.purpose || '', content: plan.content || '',
      outcome: plan.outcome || '', sources: plan.sources || [], tags: plan.tags || [],
    })) : '';
    const suffix = generation > 0 ? '|recovery:' + generation : '';
    const plannedFingerprint = plan && (plan.fingerprint
      ?? Number.parseInt(digest(fixture.key(session) + '|' + job.id + '|'
        + plan.purpose + suffix).slice(0, 12), 16));
    const outgoing = Object.entries(state.outgoing || {})
      .filter(([, record]) => record?.job_id === job.id)
      .map(([fingerprint, record]) => ({
        status: String(record?.status || ''),
        same_generation: (record?.response_generation ?? 0) === generation,
        same_fingerprint: String(fingerprint) === String(plannedFingerprint),
      }));
    const classification = {
      status: String(result.status || ''),
      response_generation: Number.isSafeInteger(generation) ? generation : null,
      inference_modern_unpooled: inferenceKeys.join(',') === expectedInferenceKeys.join(',')
        && inference.pool_revision === null && inference.runtime_revision === job.revision
        && Number.isSafeInteger(inference.attempt_generation)
        && inference.provider_receipt_protocol_version === 1,
      settlement_exact: settlementKeys.join(',') === expectedSettlementKeys.join(','),
      settlement_finished: settlement?.schema_version === 1 && settlement?.state === 'settled',
      settlement_generation_matches: settlement?.response_generation === generation,
      settlement_plan_matches: Boolean(planSha256)
        && settlement?.plan_sha256 === planSha256,
      outgoing,
    };
    assert.equal(result.status, 'sent', 'RECOVERY_CLASS ' + JSON.stringify(classification));
  }
  const visible = visibleFor(fixture, session);
  assert.equal(visible.length, 1, '恢复后同一问题只能发送一份有效答案');
  assert.equal(visible[0].content, expectedContent);
  const jobs = fixture.rawState(session).jobs.filter((job) => job.id === jobId);
  assert.equal(jobs.length, 1);
  assert.equal(jobs[0].status, 'done');
  assert.equal(jobs[0].responsibility_status, 'answered_confirmed');
  assert.equal((await fixture.runtime().process(fixture.key(session), jobId)).status, 'idle');
  assert.equal(visibleFor(fixture, session).length, 1, '已完成责任不得重复出站');
};

(async () => {
  await test('F01 旧开关、缺省开关及重启均不追加邀请或创建 pending', async () => {
    for (const variant of ['enabled', 'missing', 'disabled']) {
      const f = makeFixture('flags-' + variant);
      if (variant === 'missing') f.writeConfig('feedback', {});
      if (variant === 'disabled') f.writeConfig('feedback', { feedback: { enabled: false, auto_invite: false, prompt: invitation } });
      if (variant !== 'enabled') f.publishCurrentMaterials();
      for (const session of ['session_before001', 'session_after0001']) {
        f.restart();
        const modelBefore = f.modelRequests.length;
        const retrievalBefore = f.retrievalRequests.length;
        const sentBefore = f.sent.length;
        const result = await f.deliver(f.event(session, '如何保存设置？'));
        assert.equal(result.status, 'sent', variant + ' 必须完成正常单接口回答');
        assert.equal(f.modelRequests.length, modelBefore + 1,
          variant + ' 必须执行一次真实生产模型路径');
        assert.equal(f.retrievalRequests.length, retrievalBefore + 1,
          variant + ' 必须执行一次真实生产检索路径');
        assert.equal(f.sent.length, sentBefore + 1,
          variant + ' 每个问题必须产生且只产生一份可见回答');
        assert.equal(f.sent.at(-1).content, f.modes.answer);
        assert.equal(f.state(session).pending_feedback, null);
      }
      f.noFeedback();
      assert.equal(fs.readFileSync(path.join(f.root, 'config/prompt.md'), 'utf8'), f.prompt);
    }
  });

  await test('F02 旧 pending 的是、否、还不行与表情继续进入普通咨询', async () => {
    const f = makeFixture('pending');
    for (const [index, content] of ['是', '否', '还不行', '👍', '👎'].entries()) {
      const session = 'session_pending-' + index;
      await f.seed(session, (state) => { state.pending_feedback = { answer_id: 'synthetic-old-answer', question: '旧问题', answer: '旧答案', expires_at: f.now() + 86400000 }; });
      f.restart(); const count = f.modelRequests.length;
      await f.deliver(f.event(session, content));
      assert.equal(f.modelRequests.length, count + 1, content + ' 不应被旧评分消费');
      assert.deepEqual(f.retrievalRequests.at(-1), { query: content });
      assert.equal(textOf(messagesOf(f.modelRequests.at(-1)).at(-1)), content);
      assert.equal(f.sent.at(-1).content, f.modes.answer);
      assert.equal(f.state(session).mode, 'ai'); assert.equal(f.state(session).pending_feedback, null);
    }
    f.noFeedback();
  });

  await test('F03 旧独立评价 job 精确停用，普通 answer 与未处理问题仍恢复', async () => {
    const f = makeFixture('queue'); const session = 'session_queue0001';
    const normal = f.legacyUnpooled(f.makeJob(session, 'answer', { type: 'text', purpose: 'ai_text', content: f.modes.answer, ordinary: true, ai: true, feedback: true, fingerprint: 51001 }));
    normal.inference.deadline_at = f.now() - 1;
    const ordinary = f.makeJob(session, 'question');
    const retired = ['feedback', 'feedback_invite', 'feedback_thanks', 'feedback_clarification'].map((purpose, index) => f.makeJob(session, purpose, { type: 'text', purpose, content: '旧评价专用文案', fingerprint: 52001 + index }));
    retired.push(f.makeJob(session, 'event-marker', { type: 'text', purpose: 'legacy', content: '旧评价感谢', feedback_event: { feedback: 'negative' }, fingerprint: 52009 }));
    await f.seed(session, (state) => {
      state.jobs.push(...retired, normal, ordinary);
      state.worker = { job: retired[0].id, token: 'synthetic-old-worker', until: f.now() + 200000 };
      state.offers.manual = { kind: 'handoff', expires_at: f.now() + 600000, choices: { yes: { type: 'confirm_handoff' } } };
    });
    f.restart(); const scanned = await f.runtime().scan();
    assert(retired.every((job) => f.rawState(session).jobs.find((item) => item.id === job.id).status === 'cancelled'));
    let migrated = f.rawState(session).jobs.find((item) => item.id === normal.id);
    assert.equal(migrated.plan, undefined,
      '公开版本没有 queued 直发契约，过期旧直连计划必须先失权再重新规划');
    assert.equal(migrated.inference, undefined);
    assert.equal(migrated.inference_generation, 1);
    assert(f.rawState(session).offers.manual, '人工 offer 必须保留');
    assert(!scanned.some((job) => job.jobId === normal.id),
      '迁移所在 tick 不得递归启动第二次 Provider 请求');
    assert(scanned.some((job) => job.jobId === ordinary.id));
    const ordinaryResult = await f.runtime().process(f.key(session), ordinary.id);
    assert.equal(ordinaryResult.status, 'sent'); assert.equal(ordinaryResult.jobId, ordinary.id);
    f.advance(1); f.restart();
    assert((await f.runtime().scan()).some((job) => job.jobId === normal.id));
    const recoveredResult = await f.runtime().process(f.key(session), normal.id);
    assert.equal(recoveredResult.status, 'sent'); assert.equal(recoveredResult.jobId, normal.id);
    const stored = f.rawState(session);
    for (const id of [normal.id, ordinary.id]) {
      const completed = stored.jobs.find((item) => item.id === id);
      assert.equal(completed.status, 'done');
      assert.equal(completed.responsibility_status, 'answered_confirmed');
    }
    assert.equal(Object.values(stored.outgoing).filter((record) => record.status === 'sent').length, 2);
    assert.equal(f.sent.length, 2); assert.equal(f.retrievalRequests.length, 2);
    assert.equal(f.modelRequests.length, 2,
      '无公开直发契约的旧缓存不得直接发送，两个真实责任各重新规划一次');
    assert(f.sent.every((item) => item.content === f.modes.answer)); f.noFeedback();
  });

  await test('F04 旧评价 picker 更新与发送回调安全忽略，人工确认仍有效', async () => {
    const f = makeFixture('callbacks'); const session = 'session_callbacks1';
    for (const event of ['message:updated', 'message:send']) {
      const id = 'synthetic_feedback_' + event; const fingerprint = event === 'message:updated' ? 61001 : 61002;
      await f.seed(session, (state) => {
        state.offers[id] = { id, kind: 'feedback', fingerprint, generation: 0, revision: 1, expires_at: f.now() + 60000, choices: { no: { type: 'confirm_handoff' } } };
        state.pending_feedback = { answer_id: 'legacy', expires_at: f.now() + 60000 };
      });
      const input = f.event(session, { id, choices: [{ value: 'no', selected: true }] }, { type: 'picker', fingerprint }); input.event = event;
      const result = await f.deliver(input);
      assert.equal(result.route, 'ignore'); assert.equal(f.state(session).mode, 'ai');
      assert.equal(f.sent.length, 0); assert.equal(f.modelRequests.length, 0);
    }
    await f.deliver(f.event(session, '人工'));
    const card = f.sent.at(-1); assert.equal(card.type, 'picker'); assert.equal(f.state(session).mode, 'ai');
    const click = f.event(session, { ...card.content, choices: card.content.choices.map((choice, index) => ({ ...choice, selected: index === 0 })) }, { type: 'picker', fingerprint: card.fingerprint });
    click.event = 'message:updated'; await f.deliver(click); assert.equal(f.state(session).mode, 'human');
    assert.equal(f.sent.at(-1).content, '您的人工协助请求已收到，请稍候。');
  });

  await test('F05 旧 unknown 普通答案已送达时仅对账，原历史及统计保留', async () => {
    for (const disabled of [false, true]) {
      const f = makeFixture('unknown-found-' + disabled); const session = 'session_found0001';
      const plan = { type: 'text', purpose: 'ai_text', ordinary: true, ai: true, feedback: true, content: f.modes.answer, fingerprint: 71001 };
      const job = f.legacyUnpooled(f.makeJob(session, 'unknown', plan));
      const outgoing = f.makeOutgoing(job, f.modes.answer + '\n\n' + invitation);
      await f.seed(session, (state) => { state.jobs.push(job); state.outgoing['71001'] = outgoing; });
      const historical = { ...outgoing.body, timestamp: f.now() - 1000 }; f.histories.set(session, [historical]);
      if (disabled) {
        f.writeConfig('runtime', { schema_version: 2, enabled: false, revision: 2, applied_revision: 2 });
        f.publishCurrentMaterials();
      }
      f.restart(); await f.runtime().scan();
      // 总关会先把 unknown 收敛成只读对账责任，并将下一动作明确延后五秒；
      // 同一时钟直接 process 只能 idle，不能用旧夹具时序误判生产实现。
      if (disabled) { f.advance(5000); f.restart(); await f.runtime().scan(); }
      await f.runtime().process(f.key(session));
      assert.equal(f.sent.length, 0); assert.equal(f.modelRequests.length, 0);
      const reconciled = f.rawState(session).outgoing['71001'];
      assert.equal(reconciled.status, 'sent');
      assert.equal(reconciled.delivery_identity_version, 1);
      assert.equal(reconciled.legacy_feedback_wire_identity, true,
        '只有精确确认旧版答案+评价wire后才允许冻结兼容身份');
      assert(Number.isSafeInteger(reconciled.legacy_delivery_identity_migrated_at)
        && reconciled.legacy_delivery_identity_migrated_at >= 0);
      assert.deepEqual(f.histories.get(session), [historical]);
      assert.equal(f.events().filter((event) => event.type === 'ai_reply').length, disabled ? 0 : 1);
      assert.equal(f.events().filter((event) => event.type === 'delivery_after_state_change').length, disabled ? 1 : 0,
        '状态已变化的历史回执必须单列，不能冒充当前正常 AI 回复');
      if (disabled) {
        const cancelled = f.rawState(session).jobs.find((entry) => entry.id === job.id);
        assert.equal(cancelled.status, 'cancelled');
        assert.equal(cancelled.responsibility_status, 'intentional_silence');
        assert.equal(cancelled.responsibility_reason, 'global_disabled');
        const eventCount = f.events().filter((event) => event.type === 'delivery_after_state_change').length;
        assert.equal((await f.runtime().process(f.key(session))).status, 'idle');
        assert.equal(f.events().filter((event) => event.type === 'delivery_after_state_change').length,
          eventCount, '迟到投递事实只允许在状态事务提交后记录一次');
      }
      assert.equal(f.state(session).pending_feedback, null); f.noFeedback();
    }
  });

  await test('F06 旧 unknown 普通答案未送达时复用原 plan，仅重发无评价正文', async () => {
    const f = makeFixture('unknown-absent'); const session = 'session_absent0001';
    const job = f.legacyUnpooled(f.makeJob(session, 'unknown', { type: 'text', purpose: 'ai_text', ordinary: true, ai: true, feedback: true, content: f.modes.answer, fingerprint: 72001 }));
    await f.seed(session, (state) => { state.jobs.push(job); state.outgoing['72001'] = f.makeOutgoing(job, f.modes.answer + '\n\n' + invitation); });
    f.modes.exactStatus = 404;
    f.restart(); await f.runtime().scan();
    assert.equal((await f.runtime().process(f.key(session))).status, 'retry', '一次精确负查不能立即重发');
    assert.equal(f.sent.length, 0); assert.equal(f.postAttempts.length, 0);
    f.advance(5000); f.restart(); await f.runtime().scan(); await f.runtime().process(f.key(session));
    assert.equal(f.modelRequests.length, 0); assert.equal(f.sent.length, 1);
    assert.equal(f.sent[0].fingerprint, 72001); assert.equal(f.sent[0].content, f.modes.answer); f.noFeedback();
  });

  await test('F07 旧 unknown 独立评价仅对账，已发送不重计，未发送不补发', async () => {
    for (const found of [false, true]) {
      const f = makeFixture('feedback-unknown-' + found); const session = 'session_oldack001';
      const job = f.makeJob(session, 'ack', { type: 'text', purpose: 'feedback', ordinary: true, content: '旧评价感谢', fingerprint: 73001, feedback_event: { answer_id: 'synthetic-answer', feedback: 'positive' }, tags: ['ai_resolved'] });
      const outgoing = f.makeOutgoing(job, job.plan.content, found ? 'unknown' : 'sending');
      await f.seed(session, (state) => { state.jobs.push(job); state.outgoing['73001'] = outgoing; });
      if (found) f.histories.set(session, [{ ...outgoing.body, timestamp: f.now() - 1000 }]);
      else f.modes.exactStatus = 404;
      f.restart(); await f.runtime().scan(); await f.runtime().process(f.key(session));
      assert.equal(f.sent.length, 0); assert.equal(f.modelRequests.length, 0); assert.equal(f.patches.length, 0);
      assert.equal(f.rawState(session).outgoing['73001'].status, found ? 'sent' : 'cancelled');
      assert.equal(f.rawState(session).jobs.find((entry) => entry.id === job.id).status, 'cancelled');
      f.noFeedback();
    }
  });

  await test('F08 对账接口暂时不可用时保留旧 unknown，恢复后仍不补发评价', async () => {
    const f = makeFixture('feedback-lookup-failure'); const session = 'session_lookup001';
    const job = f.makeJob(session, 'invite', { type: 'text', purpose: 'feedback_invite', ordinary: true, content: invitation, fingerprint: 74001 });
    await f.seed(session, (state) => { state.jobs.push(job); state.outgoing['74001'] = f.makeOutgoing(job, invitation); });
    f.modes.historyFailure = true; f.restart(); await f.runtime().scan();
    assert.equal((await f.runtime().process(f.key(session))).status, 'retry');
    assert.equal(f.rawState(session).outgoing['74001'].status, 'unknown');
    f.advance(6000); f.modes.historyFailure = false; f.modes.exactStatus = 404;
    await f.runtime().process(f.key(session));
    assert.equal(f.rawState(session).outgoing['74001'].status, 'cancelled');
    assert.equal(f.sent.length, 0); f.noFeedback();
  });

  await test('F09 正常文字与图片照常回答，图片或模型技术故障保留责任并恢复同一 job', async () => {
    const f = makeFixture('business');
    await f.deliver(f.event('session_business1', '如何保存设置？')); assert.equal(f.sent.at(-1).content, f.modes.answer);
    await f.deliver(f.event('session_picture01', { url: 'https://storage.crisp.chat/synthetic.png', type: 'image/png' }, { type: 'file' }));
    assert.equal(f.visionRequests.length, 1); assert.equal(f.sent.at(-1).content, f.modes.answer);
    f.modes.imageFailure = true;
    const imageInput = f.event('session_badimage1', { url: 'https://storage.crisp.chat/synthetic.png', type: 'image/png' }, { type: 'file' });
    const imageFailure = await f.deliver(imageInput);
    assert.equal(imageFailure.status, 'unresolved');
    assertUnresolvedResponsibility(f, 'session_badimage1', imageFailure.jobId, imageInput.data.content);
    assert.equal(f.state('session_badimage1').mode, 'ai');
    f.modes.imageFailure = false;
    await recoverSameJobOnce(f, 'session_badimage1', imageFailure.jobId, f.modes.answer);

    f.modes.modelFailure = true;
    const modelInput = f.event('session_badmodel1', '模型错误的普通问题');
    const modelFailure = await f.deliver(modelInput);
    assert.equal(modelFailure.status, 'unresolved');
    assertUnresolvedResponsibility(f, 'session_badmodel1', modelFailure.jobId, modelInput.data.content);
    assert.equal(f.state('session_badmodel1').mode, 'ai');
    f.modes.modelFailure = false;
    await recoverSameJobOnce(f, 'session_badmodel1', modelFailure.jobId, f.modes.answer);
    const count = f.sent.length; const inferenceCount = f.modelRequests.length;
    f.writeConfig('runtime', { schema_version: 2, enabled: false, revision: 2, applied_revision: 2 });
    f.publishCurrentMaterials();
    await f.deliver(f.event('session_disable01', '否'));
    assert.equal(f.sent.length, count); assert.equal(f.modelRequests.length, inferenceCount); f.noFeedback();
  });

  await test('F10 用户与业务正文中相似评价文字完整保留，仅移除可证明的系统后缀', async () => {
    const f = makeFixture('owned-suffix'); const session = 'session_ownership1';
    const quoted = '业务文档引用的原句：\n' + invitation;
    const legacyWire = quoted + '\n\n' + invitation;
    const job = f.legacyUnpooled(f.makeJob(session, 'quoted', { type: 'text', purpose: 'ai_text', ordinary: true, feedback: true, content: quoted, fingerprint: 75001 }));
    const outgoing = f.makeOutgoing(job, legacyWire, 'unknown');
    Object.assign(outgoing, { response_generation: 0, delivery_identity_version: 1,
      legacy_delivery_identity_migrated_at: f.now(), legacy_feedback_wire_identity: true,
      purpose: 'ai_text', message_type: 'text', semantic_intent: 'answer',
      content_sha256: digest(canonical({ type: 'text', content: legacyWire })) });
    await f.seed(session, (state) => {
      state.jobs.push(job);
      state.outgoing['75001'] = outgoing;
    });
    await f.runtime().scan();
    let stored = f.rawState(session).outgoing['75001'];
    assert.equal(stored.body.content, legacyWire,
      '未决回执在远端事实不明时必须保留原wire，scan不得直接改写');
    assert.equal(stored.content_sha256, outgoing.content_sha256);
    f.modes.exactStatus = 404;
    assert.equal((await f.runtime().process(f.key(session), job.id)).status, 'retry');
    stored = f.rawState(session).outgoing['75001'];
    assert.equal(stored.body.content, legacyWire);
    assert.equal(stored.reconcile_misses, 1);
    assert.equal(f.postAttempts.length, 0);
    f.advance(5000); f.restart(); await f.runtime().scan();
    assert.equal((await f.runtime().process(f.key(session), job.id)).status, 'sent');
    stored = f.rawState(session).outgoing['75001'];
    assert.equal(stored.status, 'sent');
    assert.equal(stored.attempts, 2,
      '评价迁移不得重置累计POST次数或绕过单问题预算');
    assert.equal(stored.content_sha256,
      digest(canonical({ type: 'text', content: quoted })));
    assert.equal(f.postAttempts.length, 1); assert.equal(f.sent.length, 1);
    assert.equal(f.sent[0].content, quoted,
      '两次精确未送达后只发送原业务正文，不恢复系统评价后缀');

    const business = makeFixture('business-suffix'); const businessSession = 'session_ownership2';
    const ambiguousBody = '普通答案\n\n' + invitation;
    const other = business.makeJob(businessSession, 'ambiguous', {
      type: 'text', purpose: 'keyword_reply', ordinary: true,
      content: ambiguousBody, fingerprint: 75002,
    });
    await business.seed(businessSession, (state) => state.jobs.push(other));
    const sent = await business.runtime().process(business.key(businessSession), other.id);
    assert.equal(sent.status, 'sent');
    assert.equal(business.sent[0].content, ambiguousBody,
      '无系统追加证据的业务正文不能按相似文本清理');
  });

  await test('F10b 旧评价wire去后缀后的两个持久中断点均可重启恢复', async () => {
    const prepare = async (name, session, fingerprint) => {
      const fixture = makeFixture(name);
      const quoted = '业务文档引用的原句：\n' + invitation;
      const legacyWire = quoted + '\n\n' + invitation;
      const job = fixture.legacyUnpooled(fixture.makeJob(session, name, {
        type: 'text', purpose: 'ai_text', ordinary: true, feedback: true,
        content: quoted, fingerprint,
      }));
      const outgoing = fixture.makeOutgoing(job, legacyWire, 'unknown');
      Object.assign(outgoing, { response_generation: 0, delivery_identity_version: 1,
        legacy_delivery_identity_migrated_at: fixture.now(),
        legacy_feedback_wire_identity: true, purpose: 'ai_text', message_type: 'text',
        semantic_intent: 'answer',
        content_sha256: digest(canonical({ type: 'text', content: legacyWire })) });
      await fixture.seed(session, (state) => {
        state.jobs.push(job); state.outgoing[String(fingerprint)] = outgoing;
      });
      fixture.modes.exactStatus = 404;
      assert.equal((await fixture.runtime().process(fixture.key(session), job.id)).status, 'retry');
      assert.equal(fixture.exactRequests.length, 1);
      fixture.advance(5000); fixture.restart();
      return { fixture, session, fingerprint, job, quoted };
    };

    const transition = await prepare('feedback-transition-crash',
      'session_feedback-transition-crash', 75011);
    const transitionFile = path.join(transition.fixture.root, 'data/runtime/session-'
      + transition.fixture.key(transition.session) + '.json');
    const originalRename = fs.renameSync;
    let transitionCommitted = false;
    try {
      fs.renameSync = (from, to) => {
        const result = originalRename(from, to);
        if (!transitionCommitted && to === transitionFile) {
          const snapshot = JSON.parse(fs.readFileSync(transitionFile, 'utf8'));
          const record = snapshot.outgoing?.[String(transition.fingerprint)];
          if (record?.status === 'unknown'
            && record.body?.content === transition.quoted
            && record.delivery_identity_version === 1
            && record.legacy_feedback_wire_identity !== true
            && Number.isSafeInteger(record.legacy_delivery_identity_migrated_at)) {
            transitionCommitted = true;
            const error = new Error('synthetic-crash-after-feedback-transition');
            error.code = 'SYNTHETIC_TRANSITION_CRASH';
            throw error;
          }
        }
        return result;
      };
      assert.equal((await transition.fixture.runtime().process(
        transition.fixture.key(transition.session), transition.job.id)).status, 'deferred');
    } finally { fs.renameSync = originalRename; }
    assert.equal(transitionCommitted, true,
      '必须精确命中去后缀事务已提交、重新登记尚未发生的中断点');
    let record = transition.fixture.rawState(transition.session)
      .outgoing[String(transition.fingerprint)];
    assert.equal(record.status, 'unknown'); assert.equal(record.attempts, 1);
    assert.equal(record.body.content, transition.quoted);
    assert(Number.isSafeInteger(record.legacy_delivery_identity_migrated_at));
    const transitionJob = transition.fixture.rawState(transition.session).jobs
      .find((entry) => entry.id === transition.job.id);
    if (transitionJob.retry_at > transition.fixture.now()) {
      transition.fixture.advance(transitionJob.retry_at - transition.fixture.now());
    }
    transition.fixture.restart();
    assert.equal((await transition.fixture.runtime().process(
      transition.fixture.key(transition.session), transition.job.id)).status, 'sent');
    record = transition.fixture.rawState(transition.session)
      .outgoing[String(transition.fingerprint)];
    assert.equal(record.status, 'sent'); assert.equal(record.attempts, 2);
    assert.equal(transition.fixture.exactRequests.length, 3);
    assert.equal(transition.fixture.postAttempts.length, 1);
    assert.equal(transition.fixture.sent.length, 1);
    assert.equal(transition.fixture.sent[0].content, transition.quoted);
    assert.equal(transition.fixture.modelRequests.length, 0);

    const uncertain = await prepare('feedback-register-unknown',
      'session_feedback-register-unknown', 75012);
    uncertain.fixture.modes.crispDropBeforeAccept = true;
    assert.equal((await uncertain.fixture.runtime().process(
      uncertain.fixture.key(uncertain.session), uncertain.job.id)).status, 'retry');
    record = uncertain.fixture.rawState(uncertain.session)
      .outgoing[String(uncertain.fingerprint)];
    assert.equal(record.status, 'unknown'); assert.equal(record.attempts, 2);
    assert.equal(record.body.content, uncertain.quoted);
    assert(Number.isSafeInteger(record.legacy_delivery_identity_migrated_at),
      '重新登记及POST回执未知后仍须保留可重启验证的旧身份迁移时间');
    assert.equal(uncertain.fixture.postAttempts.length, 1);
    uncertain.fixture.modes.crispDropBeforeAccept = false;
    let pending = uncertain.fixture.rawState(uncertain.session).jobs
      .find((entry) => entry.id === uncertain.job.id);
    if (pending.retry_at > uncertain.fixture.now()) {
      uncertain.fixture.advance(pending.retry_at - uncertain.fixture.now());
    }
    uncertain.fixture.restart();
    assert.equal((await uncertain.fixture.runtime().process(
      uncertain.fixture.key(uncertain.session), uncertain.job.id)).status, 'retry');
    uncertain.fixture.advance(5000); uncertain.fixture.restart();
    assert.equal((await uncertain.fixture.runtime().process(
      uncertain.fixture.key(uncertain.session), uncertain.job.id)).status, 'sent');
    record = uncertain.fixture.rawState(uncertain.session)
      .outgoing[String(uncertain.fingerprint)];
    assert.equal(record.status, 'sent'); assert.equal(record.attempts, 3);
    assert.equal(uncertain.fixture.exactRequests.length, 4);
    assert.equal(uncertain.fixture.postAttempts.length, 2);
    assert.equal(uncertain.fixture.sent.length, 1);
    assert.equal(uncertain.fixture.sent[0].content, uncertain.quoted);
    assert.equal(uncertain.fixture.modelRequests.length, 0);
    for (const item of [transition, uncertain]) {
      assert.equal(item.fixture.events().filter((event) => event.type === 'feedback').length, 0,
        '业务正文引用评价句不等于本项目创建了评价事件');
      const state = item.fixture.rawState(item.session);
      assert.equal(state.jobs.filter((entry) => entry.plan?.purpose === 'feedback_invite'
        || entry.purpose === 'feedback_invite').length, 0,
      '迁移恢复不得创建独立评价任务');
      assert.equal(Object.values(state.outgoing || {})
        .filter((entry) => entry?.purpose === 'feedback_invite').length, 0,
      '迁移恢复不得登记独立评价出站');
    }
  });

  await test('F10c 负数旧评价wire迁移时间不得授权删除证据或重新发送', async () => {
    const f = makeFixture('feedback-negative-migration-time');
    const session = 'session_feedback-negative-migration-time';
    const fingerprint = 75013;
    const answer = '保留原业务答案';
    const legacyWire = answer + '\n\n' + invitation;
    const job = f.legacyUnpooled(f.makeJob(session, 'feedback-negative-time', {
      type: 'text', purpose: 'ai_text', ordinary: true, feedback: true,
      content: answer, fingerprint,
    }));
    const outgoing = f.makeOutgoing(job, legacyWire, 'unknown');
    Object.assign(outgoing, { response_generation: 0, delivery_identity_version: 1,
      legacy_delivery_identity_migrated_at: -1, legacy_feedback_wire_identity: true,
      purpose: 'ai_text', message_type: 'text', semantic_intent: 'answer',
      content_sha256: digest(canonical({ type: 'text', content: legacyWire })) });
    await f.seed(session, (state) => {
      state.jobs.push(job); state.outgoing[String(fingerprint)] = outgoing;
    });
    const originalPlan = structuredClone(job.plan);
    const originalInference = structuredClone(job.inference);
    const originalOutgoing = structuredClone(outgoing);
    const marker = path.join(f.root, 'config/provider-pool-transaction.json');
    fs.writeFileSync(marker, JSON.stringify({ phase: 'applying' }), { mode: 0o600 });

    assert.equal((await f.runtime().process(f.key(session), job.id)).status,
      'delivery_identity_unresolved');
    let state = f.rawState(session);
    let stored = state.jobs.find((entry) => entry.id === job.id);
    assert.deepEqual(stored.plan, originalPlan);
    assert.deepEqual(stored.inference, originalInference);
    assert.deepEqual(state.outgoing[String(fingerprint)], originalOutgoing);
    assert.equal(stored.responsibility_status, 'unresolved_failure');
    assert.equal(stored.failure_code, 'delivery_identity_unresolved');
    assert.equal(f.exactRequests.length, 0); assert.equal(f.postAttempts.length, 0);
    assert.equal(f.modelRequests.length, 0); assert.equal(f.sent.length, 0);

    fs.unlinkSync(marker);
    f.advance(stored.retry_at - f.now()); f.restart();
    assert.equal((await f.runtime().process(f.key(session), job.id)).status, 'idle');
    state = f.rawState(session); stored = state.jobs.find((entry) => entry.id === job.id);
    assert.deepEqual(stored.plan, originalPlan);
    assert.deepEqual(stored.inference, originalInference);
    assert.deepEqual(state.outgoing[String(fingerprint)], originalOutgoing);
    assert.equal(stored.failure_code, 'delivery_identity_unresolved');
    assert(stored.retry_at > f.now());
    assert.equal(f.exactRequests.length, 0); assert.equal(f.postAttempts.length, 0);
    assert.equal(f.modelRequests.length, 0); assert.equal(f.sent.length, 0);
  });

  await test('F10d 已版本化缺标志与近似评价尾部不能借回执补造迁移身份', async () => {
    const cases = [
      { name: 'versioned-missing-flag', versioned: true,
        wire: (answer) => answer + '\n\n' + invitation },
      { name: 'near-match-business-tail', versioned: false,
        wire: (answer) => answer + '\n\n' + invitation + '\n附加业务尾部必须保留。' },
    ];
    for(const [index,item] of cases.entries()) {
      const f = makeFixture('feedback-wire-fail-closed-' + item.name);
      const session = 'session_feedback-wire-fail-closed-' + item.name;
      const fingerprint = 75020 + index;
      const answer = '受控旧版业务答案。';
      const plan = { type:'text',purpose:'ai_text',ordinary:true,ai:true,feedback:true,
        content:answer,fingerprint };
      const job = f.legacyUnpooled(f.makeJob(session,item.name,plan));
      const wire = item.wire(answer);
      const record = f.makeOutgoing(job,wire,'unknown');
      if(item.versioned) Object.assign(record,{delivery_identity_version:1,
        legacy_delivery_identity_migrated_at:f.now(),purpose:'ai_text',message_type:'text',
        semantic_intent:'answer',response_generation:0,
        content_sha256:digest(canonical({type:'text',content:wire}))});
      const original = structuredClone(record);
      await f.seed(session,(state)=>{state.jobs.push(job);state.outgoing[String(fingerprint)]=record;});
      f.histories.set(session,[{...record.body,timestamp:f.now()-1000}]);
      f.restart();
      assert.equal((await f.runtime().process(f.key(session),job.id)).status,
        'idle',item.name + ':迁移前置门已登记长退避时不得再次领取同一任务');
      const stored=f.rawState(session);
      assert.deepEqual(stored.outgoing[String(fingerprint)],original,
        item.name+':旧证据必须逐字保留且不得补造legacy_feedback_wire_identity');
      assert.equal(stored.outgoing[String(fingerprint)].legacy_feedback_wire_identity,undefined);
      assert.equal(stored.jobs.find((entry)=>entry.id===job.id).failure_code,
        'delivery_identity_unresolved');
      assert(stored.jobs.find((entry)=>entry.id===job.id).retry_at > f.now());
      assert.equal(f.postAttempts.length,0);assert.equal(f.sent.length,0);
      assert.equal(f.modelRequests.length,0);
    }
  });

  await test('F11 原有正负评价事件与统计继续可读，新咨询不篡改历史', async () => {
    const f = makeFixture('analytics'); const session = 'session_analytics1';
    const history = ['positive', 'negative'].map((feedback, index) => ({ type: 'feedback', at: new Date(f.now() - 1000).toISOString(), answer_id: 'historical-' + index, session: 'synthetic-history', question: '历史问题' + index, feedback }));
    const file = path.join(f.root, 'data/analytics/events.jsonl');
    fs.writeFileSync(file, history.map((event) => JSON.stringify(event) + '\n').join(''));
    const summary = () => {
      const result = spawnSync('bash', [path.join(project, 'scripts/analytics.sh'), 'all', '--deploy-dir', f.root, '--json'], { encoding: 'utf8' });
      assert.equal(result.status, 0, result.stderr); return JSON.parse(result.stdout);
    };
    const before = summary();
    await f.seed(session, (state) => { state.pending_feedback = { answer_id: 'historical-new', expires_at: f.now() + 60000 }; });
    f.restart(); await f.runtime().scan(); await f.deliver(f.event(session, '是'));
    const after = summary();
    assert.deepEqual(f.events().filter((event) => event.type === 'feedback'), history);
    assert.equal(before.positive_feedback, 1); assert.equal(after.positive_feedback, 1);
    assert.equal(before.negative_feedback, 1); assert.equal(after.negative_feedback, 1);
    assert.equal(after.total_questions, 1); assert.equal(after.ai_replies, 1);
  });

  await test('F12 超过五分钟的旧 unknown 只读对账，缺席未证实时不失败或按年龄删除', async () => {
    for (const purpose of ['ai_text', 'feedback_invite']) for (const found of [false, true]) {
      const f = makeFixture('old-unknown-' + purpose + '-' + found); const session = 'session_oldresult1';
      const created = f.makeJob(session, 'old-result', { type: 'text', purpose,
        ordinary: true, ...(purpose === 'ai_text' ? { ai: true } : {}), feedback: true,
        content: f.modes.answer, fingerprint: 76001 }, { received_at: f.now() - 600000 });
      const job = purpose === 'ai_text' ? f.legacyUnpooled(created) : created;
      const outgoing = f.makeOutgoing(job, f.modes.answer + '\n\n' + invitation);
      outgoing.created_at = f.now() - 590000;
      outgoing.delivery_uncertain = true;
      await f.seed(session, (state) => { state.jobs.push(job); state.outgoing['76001'] = outgoing; });
      if (found) f.histories.set(session, [{ ...outgoing.body, timestamp: f.now() - 589000 }]);
      else f.modes.exactStatus = 200;
      f.restart(); await f.runtime().scan();
      const first = await f.runtime().process(f.key(session));
      if (!found) {
        assert.equal(first.status, 'retry');
        f.advance(5000); f.restart(); await f.runtime().scan();
        assert.equal((await f.runtime().process(f.key(session))).status, 'retry');
        let stored = f.rawState(session);
        let pending = stored.jobs.find((entry) => entry.id === job.id);
        assert(pending && !['done', 'cancelled', 'failed'].includes(pending.status), '未知投递不得伪造终态');
        assert.equal(stored.outgoing['76001'].status, 'unknown');
        assert.equal(stored.outgoing['76001'].body.content, outgoing.body.content);
        assert.equal(stored.outgoing['76001'].body.fingerprint, 76001);
        assert.equal(stored.outgoing['76001'].reconcile_misses || 0, 0,
          'HTTP 200 空对象不是精确 404，不能累计未送达阴性证据');
        f.advance(8 * 86400000); f.restart();
        assert((await f.runtime().scan()).some((item) => item.jobId === job.id), '跨日志期限仍须调度同一对账责任');
        stored = f.rawState(session); pending = stored.jobs.find((entry) => entry.id === job.id);
        assert(pending, '未知投递关联 job 不得按日志期限删除');
        assert.equal(stored.outgoing['76001'].status, 'unknown');
        assert.equal(stored.outgoing['76001'].body.content, outgoing.body.content);
      } else {
        const expectedStatus = purpose === 'ai_text' ? 'sent' : 'cancelled';
        if (first.status !== expectedStatus) {
          const diagnosticState = f.rawState(session);
          const diagnosticJob = diagnosticState.jobs.find((entry) => entry.id === job.id);
          const diagnosticOutgoing = diagnosticState.outgoing['76001'];
          const enumValue = (value, allowed) => value === undefined ? 'missing'
            : value === null ? 'null' : allowed.includes(value) ? value : 'other';
          const diagnostic = {
            case: purpose + '-found',
            result_status: enumValue(first.status,
              ['sent', 'cancelled', 'deferred', 'retry', 'idle']),
            result_reason: enumValue(first.reason, [
              'processing_capacity', 'processing_permit_lost', 'execution_superseded',
              'operator_identity_pending', 'operator_identity_persistence_failed',
              'answer_responsibility_unresolved', 'configuration_changed',
            ]),
            job_status: enumValue(diagnosticJob?.status,
              ['received', 'processing', 'done', 'cancelled', 'failed']),
            feedback_retired: diagnosticJob?.feedback_retired === true,
            responsibility_status: enumValue(diagnosticJob?.responsibility_status,
              ['pending', 'answered_confirmed', 'intentional_silence',
                'control_handled', 'unresolved_failure']),
            responsibility_reason: enumValue(diagnosticJob?.responsibility_reason,
              ['feedback_retired', 'conversation_state_changed', 'global_disabled',
                'human_handoff', 'human_reply']),
            failure_code: enumValue(diagnosticJob?.failure_code, [
              'persisted_plan_delivery_pending', 'runtime_processing_failed',
              'delivery_identity_unresolved', 'delivery_semantic_unknown',
            ]),
            deferred_configuration: diagnosticJob?.deferred_configuration === true,
            deferred_control: diagnosticJob?.deferred_control === true,
            retry_state: !Number.isFinite(diagnosticJob?.retry_at) ? 'none'
              : diagnosticJob.retry_at > f.now() ? 'future' : 'due',
            execution_token_present: typeof diagnosticJob?.execution_token === 'string',
            data_present: diagnosticJob?.data !== undefined,
            plan_present: diagnosticJob?.plan !== undefined,
            outgoing_status: enumValue(diagnosticOutgoing?.status,
              ['unknown', 'sending', 'sent', 'cancelled', 'failed']),
            delivery_identity_version: diagnosticOutgoing?.delivery_identity_version === 1
              ? 'v1' : diagnosticOutgoing?.delivery_identity_version === undefined
                ? 'missing' : 'other',
            semantic_intent: enumValue(diagnosticOutgoing?.semantic_intent,
              ['answer', 'non_answer', 'control']),
            semantic_status: enumValue(diagnosticOutgoing?.semantic_status,
              ['valid_answer', 'delivered_non_answer', 'control_delivered',
                'semantic_unknown']),
            retired_marker_present:
              diagnosticOutgoing?.retired_feedback_receipt_fingerprint !== undefined,
            receipt_current: diagnosticOutgoing?.receipt_current === true ? 'true'
              : diagnosticOutgoing?.receipt_current === false ? 'false'
                : diagnosticOutgoing?.receipt_current === null ? 'null' : 'missing',
            receipt_reason: enumValue(diagnosticOutgoing?.receipt_state_change_reason,
              ['configuration_changed', 'conversation_state_changed',
                'global_disabled', 'operator_identity_pending']),
            body_present: diagnosticOutgoing?.body !== undefined,
            exact_requests: f.exactRequests.length,
            post_attempts: f.postAttempts.length,
            model_requests: f.modelRequests.length,
            visible_sent: f.sent.length,
          };
          process.stdout.write('F12_CLASS ' + JSON.stringify(diagnostic) + '\n');
        }
        assert.equal(first.status, expectedStatus);
        const delivered = f.rawState(session).outgoing['76001'];
        assert.equal(delivered.status, 'sent');
        assert.equal(delivered.delivery_identity_version, 1);
        assert.equal(delivered.job_id, job.id);
        assert.equal(delivered.generation, job.generation);
        assert.equal(delivered.response_generation, 0);
        assert.equal(delivered.message_type, 'text');
        assert.equal(delivered.content_sha256,
          digest(canonical({ type: 'text', content: outgoing.body.content })));
        assert.equal(delivered.receipt_current, true);
        assert.equal(Object.hasOwn(delivered, 'body'), false);
        for (const field of ['delivery_uncertain', 'recovery_deferred', 'resend_forbidden',
          'next_action_at', 'failure', 'reconcile_misses', 'reconcile_checked_at']) {
          assert.equal(delivered[field], undefined,
            purpose + ':精确回执收敛后不得残留运输期字段 ' + field);
        }
        if (purpose === 'feedback_invite') {
          assert.equal(delivered.feedback_retired, true);
          assert.equal(delivered.purpose, 'feedback_invite');
          assert.equal(delivered.semantic_intent, 'control');
          assert.equal(delivered.semantic_status, 'control_delivered');
          assert.equal(delivered.retired_feedback_receipt_fingerprint, '76001');
        }
        const frozen = structuredClone(delivered);
        assert.equal(f.postAttempts.length, 0,
          purpose + ':远端历史命中不得重新POST');
        assert.equal(f.exactRequests.length, 0,
          purpose + ':列表精确命中后不得额外调用fingerprint端点');
        const requestCounts = { exact: f.exactRequests.length, model: f.modelRequests.length,
          post: f.postAttempts.length, sent: f.sent.length };
        f.restart();
        assert.deepEqual(await f.runtime().scan(), [],
          purpose + ':严格冻结回执不应重新进入调度');
        assert.equal((await f.runtime().process(f.key(session), job.id)).status, 'idle');
        assert.deepEqual(f.rawState(session).outgoing['76001'], frozen,
          purpose + ':重复处理不得再次迁移或改写已冻结回执');
        assert.deepEqual({ exact: f.exactRequests.length, model: f.modelRequests.length,
          post: f.postAttempts.length, sent: f.sent.length }, requestCounts,
        purpose + ':重复处理不得产生网络、模型或可见发送');
      }
      const restoredJob = f.rawState(session).jobs.find((entry) => entry.id === job.id);
      if (purpose === 'ai_text') {
        assert.notEqual(restoredJob.feedback_retired, true, '超时普通答案不能误标为评价');
        assert.equal(restoredJob.status, found ? 'done' : 'received');
      } else if (found) {
        assert.equal(restoredJob.status, 'cancelled');
        assert.equal(restoredJob.feedback_retired, true);
        assert.equal(restoredJob.responsibility_status, 'intentional_silence');
        assert.equal(restoredJob.responsibility_reason, 'feedback_retired');
        assert.notEqual(restoredJob.responsibility_status, 'control_handled');
      }
      assert.equal(f.events().filter(event => event.type === 'delivery_failed' && event.reason === 'delivery_unknown').length, 0);
      assert.equal(f.events().filter(event => event.type === 'ai_reply').length,
        purpose === 'ai_text' && found ? 1 : 0);
      assert.equal(f.sent.length, 0); assert.equal(f.modelRequests.length, 0);
      assert.equal(f.state(session).pending_feedback, null);
    }

    const malformedRetiredCases = [
      { name: 'legacy-marker-true', field: 'legacy_feedback_wire_identity', value: true },
      { name: 'legacy-marker-false', field: 'legacy_feedback_wire_identity', value: false },
      { name: 'legacy-marker-string', field: 'legacy_feedback_wire_identity', value: 'true' },
      { name: 'remote-origin-mismatch', remote: { origin: 'email' } },
    ];
    for (const [index, item] of malformedRetiredCases.entries()) {
      const f = makeFixture('retired-feedback-malformed-' + item.name);
      const session = 'session_retired-feedback-malformed-' + item.name;
      const fingerprint = 76010 + index;
      const plan = { type: 'text', purpose: 'feedback_invite', ordinary: true,
        feedback: true, content: f.modes.answer, fingerprint };
      const job = f.makeJob(session, item.name, plan, { feedback_retired: true });
      const outgoing = f.makeOutgoing(job, f.modes.answer + '\n\n' + invitation, 'unknown');
      outgoing.feedback_retired = true;
      if (item.field) outgoing[item.field] = item.value;
      await f.seed(session, (state) => {
        state.jobs.push(job); state.outgoing[String(fingerprint)] = outgoing;
      });
      f.histories.set(session, [{ ...outgoing.body, ...item.remote,
        timestamp: f.now() - 1000 }]);
      f.restart();
      assert.equal((await f.runtime().process(f.key(session), job.id)).status,
        'cancelled', item.name);
      const stored = f.rawState(session);
      const retained = stored.outgoing[String(fingerprint)];
      assert.equal(retained.status, 'unknown', item.name);
      assert.equal(retained.delivery_identity_version, undefined, item.name);
      assert.equal(retained.retired_feedback_receipt_fingerprint, undefined, item.name);
      assert.equal(retained.body.content, outgoing.body.content, item.name);
      if (item.field) assert.equal(retained[item.field], item.value, item.name);
      const retiredJob = stored.jobs.find((entry) => entry.id === job.id);
      assert.equal(retiredJob.status, 'cancelled', item.name);
      assert.equal(retiredJob.responsibility_status, 'intentional_silence', item.name);
      assert.equal(retiredJob.responsibility_reason, 'feedback_retired', item.name);
      assert.equal(f.modelRequests.length, 0, item.name);
      assert.equal(f.postAttempts.length, 0, item.name);
      assert.equal(f.sent.length, 0, item.name);
    }

    const exact = makeFixture('retired-feedback-exact-positive');
    const exactSession = 'session_retired-feedback-exact-positive';
    const exactPlan = { type: 'text', purpose: 'feedback_invite', ordinary: true,
      feedback: true, content: exact.modes.answer, fingerprint: 76020 };
    const exactJob = exact.makeJob(exactSession, 'exact-positive', exactPlan);
    const exactOutgoing = exact.makeOutgoing(
      exactJob, exact.modes.answer + '\n\n' + invitation, 'unknown');
    await exact.seed(exactSession, (state) => {
      state.jobs.push(exactJob); state.outgoing[String(exactPlan.fingerprint)] = exactOutgoing;
    });
    exact.histories.set(exactSession, [{ ...exactOutgoing.body,
      timestamp: exact.now() - 1000 }]);
    exact.modes.listHistoryOverride = [];
    exact.restart();
    assert.equal((await exact.runtime().process(exact.key(exactSession), exactJob.id)).status,
      'cancelled');
    const exactState = exact.rawState(exactSession);
    const exactReceipt = exactState.outgoing[String(exactPlan.fingerprint)];
    const exactStoredJob = exactState.jobs.find((job) => job.id === exactJob.id);
    assert.equal(exact.exactRequests.length, 1);
    assert.equal(exactReceipt.status, 'sent');
    assert.equal(exactReceipt.delivery_identity_version, 1);
    assert.equal(exactReceipt.semantic_intent, 'control');
    assert.equal(exactReceipt.semantic_status, 'control_delivered');
    assert.equal(exactReceipt.retired_feedback_receipt_fingerprint,
      String(exactPlan.fingerprint));
    assert.equal(Object.hasOwn(exactReceipt, 'body'), false);
    assert.equal(exactStoredJob.status, 'cancelled');
    assert.equal(exactStoredJob.feedback_retired, true);
    assert.equal(exactStoredJob.responsibility_status, 'intentional_silence');
    assert.equal(exactStoredJob.responsibility_reason, 'feedback_retired');
    assert.notEqual(exactStoredJob.responsibility_status, 'control_handled');
    assert.equal(Object.hasOwn(exactStoredJob, 'plan'), false);
    assert.equal(exact.postAttempts.length, 0);
    assert.equal(exact.modelRequests.length, 0);
    assert.equal(exact.sent.length, 0);
    const exactFrozen = structuredClone(exactReceipt);
    exact.restart();
    assert.deepEqual(await exact.runtime().scan(), []);
    assert.equal((await exact.runtime().process(
      exact.key(exactSession), exactJob.id)).status, 'idle');
    assert.deepEqual(exact.rawState(exactSession)
      .outgoing[String(exactPlan.fingerprint)], exactFrozen);
    assert.equal(exact.exactRequests.length, 1);
    assert.equal(exact.postAttempts.length, 0);
    assert.equal(exact.modelRequests.length, 0);
    assert.equal(exact.sent.length, 0);

    const countConflict = makeFixture('retired-feedback-count-conflict');
    const countConflictSession = 'session_retired-feedback-count-conflict';
    const countConflictPlan = { type: 'text', purpose: 'feedback_invite', ordinary: true,
      feedback: true, content: countConflict.modes.answer, fingerprint: 76021 };
    const countConflictJob = countConflict.makeJob(
      countConflictSession, 'count-conflict', countConflictPlan, {
        delivery_state_change_counted: true,
        delivery_state_change_counted_generation: 0,
      });
    const countConflictOutgoing = countConflict.makeOutgoing(
      countConflictJob, countConflict.modes.answer + '\n\n' + invitation, 'unknown');
    await countConflict.seed(countConflictSession, (state) => {
      state.jobs.push(countConflictJob);
      state.outgoing[String(countConflictPlan.fingerprint)] = countConflictOutgoing;
    });
    countConflict.histories.set(countConflictSession, [{ ...countConflictOutgoing.body,
      timestamp: countConflict.now() - 1000 }]);
    countConflict.restart();
    assert.equal((await countConflict.runtime().process(
      countConflict.key(countConflictSession), countConflictJob.id)).status, 'cancelled');
    const countConflictState = countConflict.rawState(countConflictSession);
    const countConflictStored = countConflictState.jobs.find(
      (job) => job.id === countConflictJob.id);
    const countConflictRecord = countConflictState.outgoing[
      String(countConflictPlan.fingerprint)];
    assert.equal(countConflictStored.status, 'cancelled');
    assert.equal(countConflictStored.feedback_retired, true);
    assert.equal(countConflictStored.responsibility_status, 'intentional_silence');
    assert.equal(countConflictStored.responsibility_reason, 'feedback_retired');
    assert.equal(countConflictStored.failure_code, 'delivery_state_change_count_conflict');
    assert.equal(countConflictStored.recovery_requires_review, true);
    assert(countConflictStored.retry_at > countConflict.now());
    assert.equal(countConflictStored.delivery_state_change_counted, true);
    assert.equal(countConflictStored.delivery_state_change_counted_generation, 0);
    assert.equal(countConflictRecord.status, 'unknown');
    assert.equal(countConflictRecord.body.content, countConflictOutgoing.body.content);
    assert.equal(countConflict.postAttempts.length, 0);
    assert.equal(countConflict.modelRequests.length, 0);
    assert.equal(countConflict.sent.length, 0);
    assert.equal(countConflict.events().filter(
      (event) => event.type === 'delivery_after_state_change').length, 0);
    assert.equal(countConflict.events().filter((event) => event.type === 'ai_reply').length, 0);

    const terminalConsumerCases = [
      { name: 'legacy-marker-present', mutate: (record) => {
        record.legacy_feedback_wire_identity = true;
      } },
      { name: 'migration-time-missing', mutate: (record) => {
        delete record.legacy_delivery_identity_migrated_at;
      } },
    ];
    for (const [index, item] of terminalConsumerCases.entries()) {
      const f = makeFixture('retired-feedback-terminal-' + item.name);
      const session = 'session_retired-feedback-terminal-' + item.name;
      const fingerprint = 76030 + index;
      const job = f.makeJob(session, item.name, null, {
        status: 'cancelled', feedback_retired: true,
        responsibility_status: 'intentional_silence',
        responsibility_reason: 'conversation_state_changed',
      });
      delete job.data;
      const contentSha256 = digest(canonical({ type: 'text', content: '历史评价控制正文' }));
      const record = { status: 'sent', created_at: f.now() - 15000,
        sent_at: f.now() - 10000, receipt_confirmed_at: f.now() - 9000,
        attempts: 1, attempt_token: digest('retired-terminal|' + item.name).slice(0, 32),
        job_id: job.id, generation: job.generation, response_generation: 0,
        delivery_identity_version: 1, purpose: 'feedback_invite', message_type: 'text',
        semantic_intent: 'control', semantic_status: 'control_delivered',
        content_sha256: contentSha256,
        receipt_current: true, feedback_retired: true,
        retired_feedback_receipt_fingerprint: String(fingerprint),
        legacy_delivery_identity_migrated_at: f.now() - 8000 };
      item.mutate(record);
      const original = structuredClone(record);
      await f.seed(session, (state) => {
        state.jobs.push(job); state.outgoing[String(fingerprint)] = record;
      });
      f.restart();
      assert.deepEqual(await f.runtime().scan(), [], item.name);
      assert.equal((await f.runtime().process(f.key(session), job.id)).status,
        'idle', item.name);
      assert.deepEqual(f.rawState(session).outgoing[String(fingerprint)], original,
        item.name + ':畸形终态回执不得被读取路径洗白或补字段');
      assert.equal(f.exactRequests.length, 0, item.name);
      assert.equal(f.postAttempts.length, 0, item.name);
      assert.equal(f.modelRequests.length, 0, item.name);
      assert.equal(f.sent.length, 0, item.name);
    }

    const recovered = makeFixture('retired-feedback-frozen-recovery');
    const recoveredSession = 'session_retired-feedback-frozen-recovery';
    const recoveredFingerprint = 76040;
    const recoveredPlan = { type: 'text', purpose: 'feedback_invite', ordinary: true,
      feedback: true, content: recovered.modes.answer, fingerprint: recoveredFingerprint };
    const recoveredJob = recovered.makeJob(recoveredSession, 'frozen-recovery', recoveredPlan, {
      status: 'processing', feedback_retired: true, attempts: 1,
      execution_token: 'a'.repeat(24), lease_until: recovered.now() - 1,
    });
    const recoveredWire = recovered.modes.answer + '\n\n' + invitation;
    const recoveredRecord = { status: 'sent', created_at: recovered.now() - 15000,
      sent_at: recovered.now() - 10000, receipt_confirmed_at: recovered.now() - 9000,
      attempts: 1, attempt_token: digest('retired-frozen-recovery').slice(0, 32),
      job_id: recoveredJob.id, generation: recoveredJob.generation, response_generation: 0,
      delivery_identity_version: 1, purpose: 'feedback_invite', message_type: 'text',
      semantic_intent: 'control', semantic_status: 'control_delivered',
      content_sha256: digest(canonical({ type: 'text', content: recoveredWire })),
      receipt_current: true, feedback_retired: true,
      retired_feedback_receipt_fingerprint: String(recoveredFingerprint),
      legacy_delivery_identity_migrated_at: recovered.now() - 8000 };
    await recovered.seed(recoveredSession, (state) => {
      state.jobs.push(recoveredJob);
      state.outgoing[String(recoveredFingerprint)] = recoveredRecord;
      state.worker = { job: recoveredJob.id, token: recoveredJob.execution_token,
        until: recovered.now() - 1 };
    });
    recovered.restart();
    assert.equal((await recovered.runtime().process(
      recovered.key(recoveredSession), recoveredJob.id)).status, 'idle');
    const recoveredState = recovered.rawState(recoveredSession);
    const recoveredStored = recoveredState.jobs.find((job) => job.id === recoveredJob.id);
    assert.equal(recoveredStored.status, 'cancelled');
    assert.equal(recoveredStored.feedback_retired, true);
    assert.equal(recoveredStored.responsibility_status, 'intentional_silence');
    assert.equal(recoveredStored.responsibility_reason, 'feedback_retired');
    assert.notEqual(recoveredStored.responsibility_status, 'control_handled');
    assert.equal(Object.hasOwn(recoveredStored, 'execution_token'), false);
    assert.equal(Object.hasOwn(recoveredStored, 'data'), false);
    assert.equal(Object.hasOwn(recoveredStored, 'plan'), false);
    assert.equal(recoveredState.worker, null);
    assert.deepEqual(recoveredState.outgoing[String(recoveredFingerprint)], recoveredRecord);
    assert.equal(recovered.exactRequests.length, 0);
    assert.equal(recovered.postAttempts.length, 0);
    assert.equal(recovered.modelRequests.length, 0);
    assert.equal(recovered.sent.length, 0);
  });

  await test('F13 Provider 回程后配置代次改变时不发旧正文并持久延后重规划', async () => {
    const f = makeFixture('provider-register-race'); const session = 'session_poolrace1';
    let changed = false;
    f.modes.onModelResponse = () => {
      assert.equal(changed, false, '配置换代只注入一次');
      changed = true;
      f.writeConfig('runtime', { schema_version: 2, enabled: true,
        revision: 2, applied_revision: 2 });
      f.publishCurrentMaterials();
    };
    const input = f.event(session, 'Provider 回程后的配置换代问题');
    const result = await f.deliver(input);
    assert.equal(result.status, 'deferred'); assert.equal(changed, true);
    assert.equal(f.sent.length, 0); assert.equal(f.postAttempts.length, 0);
    assert.equal(f.retrievalRequests.length, 1); assert.equal(f.modelRequests.length, 1);
    assert.equal(Object.keys(f.rawState(session).outgoing).length, 0);
    const deferred = f.rawState(session).jobs.find(item => item.id === result.jobId);
    assert.equal(deferred.status, 'received'); assert.equal(deferred.deferred_configuration, true);
    assert(deferred.data, '访客原始问题必须保留供新代重新规划');
    assert.equal(deferred.plan, undefined); assert.equal(deferred.inference, undefined);
  });

  await test('F14 技术、检索与视觉故障零可见兜底，保留同一责任并在恢复后回答一次', async () => {
    for (const kind of ['http', 'throw', 'payload-error', 'missing-payload', 'expired', 'image-download', 'image-disabled', 'image-provider', 'image-rag']) {
      const f = makeFixture('natural-error-' + kind); const session = 'session_natural-' + kind;
      const policy = f.readConfig('handoff');
      policy.handoff.failure_message = '系统忙，请稍后再试；后台正在检查。';
      f.writeConfig('handoff', policy);
      f.publishCurrentMaterials();
      if (kind === 'http' || kind === 'image-rag') f.modes.modelFailure = true;
      if (kind === 'throw') f.modes.modelThrow = true;
      if (kind === 'payload-error') f.modes.modelPayload = { error: 'synthetic-provider-error' };
      if (kind === 'missing-payload') f.modes.modelPayload = null;
      if (kind === 'image-download') f.modes.imageFailure = true;
      if (kind === 'image-provider') f.modes.visionFailure = true;
      if (kind === 'image-disabled') {
        f.env.AI_SUPPORTS_VISION = 'false';
        f.writeConfig('provider', { provider: { supports_vision: false } });
      }
      let failure;
      let originalContent;
      if (kind === 'expired') {
        const job = f.currentUnpooled(f.makeJob(session, 'expired-error'), f.now() - 1);
        await f.seed(session, state => state.jobs.push(job));
        failure = await f.runtime().process(f.key(session), job.id);
        originalContent = job.data.content;
        assert.equal(f.modelRequests.length, 0);
      } else {
        const data = kind.startsWith('image-') ? { url: 'https://storage.crisp.chat/synthetic.png', type: 'image/png' } : '合成问题';
        const input = f.event(session, data, { type: kind.startsWith('image-') ? 'file' : 'text' });
        originalContent = input.data.content;
        failure = await f.deliver(input);
      }
      assert.equal(failure.status, 'unresolved', kind);
      assert.equal(f.sent.length, 0, kind);
      assert.equal(f.modelRequests.length, ['http', 'throw', 'payload-error', 'missing-payload', 'image-rag'].includes(kind) ? 1 : 0, kind + ' 的故障注入必须发生在实际生成阶段');
      assertUnresolvedResponsibility(f, session, failure.jobId, originalContent);
      assert.equal(f.state(session).mode, 'ai'); assert.deepEqual(f.state(session).offers, {});
      assert.equal(f.events().filter(event => event.type === 'ai_reply' || event.type === 'handoff').length, 0);
      assert.deepEqual(f.readConfig('handoff'), policy, '兼容原配置但不直接消费其系统错误文案');
      assert.equal(fs.readFileSync(path.join(f.root, 'config/prompt.md'), 'utf8'), f.prompt);
      f.modes.modelFailure = false;
      f.modes.modelThrow = false;
      f.modes.modelPayload = undefined;
      f.modes.imageFailure = false;
      f.modes.visionFailure = false;
      f.env.AI_SUPPORTS_VISION = 'true';
      f.writeConfig('provider', { provider: { base_url: 'https://provider.invalid/v1', model: 'synthetic-model',
        api_mode: 'chat_completions', supports_vision: true } });
      await recoverSameJobOnce(f, session, failure.jobId, f.modes.answer);
      f.noFeedback();
    }
    const legacy = makeFixture('natural-error-legacy-unpooled-expired');
    const legacySession = 'session_natural-legacy-unpooled-expired';
    const legacyJob = legacy.legacyUnpooled(
      legacy.makeJob(legacySession, 'legacy-unpooled-expired'));
    legacyJob.inference.deadline_at = legacy.now() - 1;
    await legacy.seed(legacySession, (state) => state.jobs.push(legacyJob));
    const migrationTick = await legacy.runtime().process(legacy.key(legacySession), legacyJob.id);
    assert.equal(migrationTick.status, 'idle');
    assert.equal(legacy.retrievalRequests.length, 0);
    assert.equal(legacy.modelRequests.length, 0,
      '旧调用失权迁移所在 tick 不得递归启动第二次 Provider 请求');
    assert.equal(legacy.postAttempts.length, 0);
    let migratedJob = legacy.rawState(legacySession).jobs.find((job) => job.id === legacyJob.id);
    assert.equal(migratedJob.inference, undefined);
    assert.equal(migratedJob.inference_generation, 1,
      '旧 exact-two-field 调用必须先冻结为 attempt 1');
    assert(Number.isSafeInteger(migratedJob.legacy_unpooled_inference_migrated_at));
    legacy.advance(1); legacy.restart();
    const scheduled = await legacy.runtime().scan();
    assert(scheduled.some((entry) => entry.jobId === legacyJob.id));
    const migrated = await legacy.runtime().process(legacy.key(legacySession), legacyJob.id);
    assert.equal(migrated.status, 'sent');
    migratedJob = legacy.rawState(legacySession).jobs.find((job) => job.id === legacyJob.id);
    assert.equal(migratedJob.inference.attempt_generation, 2,
      '过期的精确旧直连身份必须建立单调 successor，不能覆盖为第一次调用');
    assert(Number.isSafeInteger(migratedJob.legacy_unpooled_inference_migrated_at));
    assert.equal(legacy.retrievalRequests.length, 1); assert.equal(legacy.modelRequests.length, 1);
    assert.equal(legacy.postAttempts.length, 1); assert.equal(legacy.sent.length, 1);
    legacy.noFeedback();
  });

  await test('F14a 旧直连混代与无契约投递身份隔离，不重复调用 Provider', async () => {
    for (const kind of ['receipt-conflict', 'queued-without-contract']) {
      const f = makeFixture('legacy-unpooled-conflict-' + kind);
      const session = 'session_legacy-conflict-' + kind;
      const plan = kind === 'queued-without-contract'
        ? { type: 'text', purpose: 'ai_text', ordinary: true, ai: true,
          content: '不得直接发送的旧缓存', fingerprint: 77901 }
        : undefined;
      const job = f.legacyUnpooled(f.makeJob(session, kind, plan));
      job.inference.deadline_at = f.now() - 1;
      if (kind === 'receipt-conflict') {
        job.provider_result_receipt = { schema_version: 1, state: 'available' };
      }
      await f.seed(session, (state) => {
        state.jobs.push(job);
        if (kind === 'queued-without-contract') {
          state.outgoing['77901'] = f.makeOutgoing(job, plan.content, 'queued');
        }
      });
      const result = await f.runtime().process(f.key(session), job.id);
      assert.equal(result.status, 'idle');
      const stored = f.rawState(session).jobs.find((entry) => entry.id === job.id);
      assert.equal(stored.status, 'received');
      assert.equal(stored.responsibility_status, 'unresolved_failure');
      assert.equal(stored.failure_code, kind === 'receipt-conflict'
        ? 'provider_receipt_identity_unresolved' : 'delivery_identity_unresolved');
      assert(stored.retry_at > f.now(), '混代身份必须留作可见隔离，不能立即重试');
      assert.equal(f.retrievalRequests.length, 0);
      assert.equal(f.modelRequests.length, 0);
      assert.equal(f.postAttempts.length, 0);
    }
  });

  await test('F14b 人工接管与总开关撤销旧直连及queued正文，不制造伪退休故障', async () => {
    for (const policy of ['human', 'global-disabled']) {
      const f = makeFixture('legacy-unpooled-policy-' + policy);
      const session = 'session_legacy-policy-' + policy;
      const plan = { type: 'text', purpose: 'ai_text', ordinary: true, ai: true,
        content: '政策变化后禁止发送的旧缓存', fingerprint: 77911 };
      const job = f.legacyUnpooled(f.makeJob(session, policy, plan));
      await f.seed(session, (state) => {
        state.jobs.push(job);
        state.outgoing['77911'] = f.makeOutgoing(job, plan.content, 'queued');
        if (policy === 'human') {
          state.mode = 'human';
          state.pause_reason = 'human_reply';
          state.last_human_at = f.now();
          state.resume_at = f.now() + 3600000;
        }
      });
      if (policy === 'global-disabled') {
        f.writeConfig('runtime', { schema_version: 2, enabled: false,
          revision: 2, applied_revision: 2 });
        f.publishCurrentMaterials();
        f.restart();
      }
      assert.equal((await f.runtime().process(f.key(session), job.id)).status, 'idle');
      const state = f.rawState(session);
      const stored = state.jobs.find((entry) => entry.id === job.id);
      assert.equal(stored.status, 'cancelled');
      assert.equal(stored.responsibility_status, 'intentional_silence');
      assert.equal(stored.responsibility_reason,
        policy === 'human' ? 'human_handoff' : 'global_disabled');
      assert.equal(stored.inference, undefined);
      assert.equal(stored.provider_retirement, undefined);
      assert.equal(stored.provider_retirement_failure_code, undefined);
      assert.equal(state.outgoing['77911'].status, 'cancelled');
      assert.equal(state.outgoing['77911'].body, undefined);
      assert.equal(f.retrievalRequests.length, 0);
      assert.equal(f.modelRequests.length, 0);
      assert.equal(f.postAttempts.length, 0);
    }
  });

  await test('F14c 已存在的畸形迁移标记原样隔离，不得被洗白后授权删除或重规划', async () => {
    const markerCases = [
      { name: 'negative', value: -1 },
      { name: 'string', value: '1' },
      { name: 'object', value: { invalid: true } },
    ];
    for (const markerCase of markerCases) for (const kind of [
      'unpooled-inference-only', 'unpooled-cached-plan', 'pooled-cached-plan',
    ]) {
      const f = makeFixture('legacy-invalid-marker-' + markerCase.name + '-' + kind);
      const session = 'session_invalid-marker-' + markerCase.name + '-' + kind;
      const cached = kind.endsWith('cached-plan');
      const plan = cached ? { type: 'text', purpose: 'ai_text', ordinary: true, ai: true,
        content: '畸形迁移标记不得授权的旧缓存', fingerprint: 77921 } : undefined;
      const job = f.makeJob(session, kind, plan);
      if (kind.startsWith('unpooled')) f.legacyUnpooled(job);
      else job.inference = { pool_revision: 1, deadline_at: f.now() - 1 };
      job.inference.deadline_at = f.now() - 1;
      const markerName = cached
        ? 'legacy_unsettled_plan_migrated_at' : 'legacy_unpooled_inference_migrated_at';
      job[markerName] = structuredClone(markerCase.value);
      const originalPlan = structuredClone(job.plan);
      const originalInference = structuredClone(job.inference);
      await f.seed(session, (state) => state.jobs.push(job));

      assert.equal((await f.runtime().process(f.key(session), job.id)).status, 'idle');
      const stored = f.rawState(session).jobs.find((entry) => entry.id === job.id);
      assert.deepEqual(stored[markerName], markerCase.value,
        '畸形marker必须原样保留供诊断，不能改造成破坏性授权');
      assert.deepEqual(stored.inference, originalInference);
      assert.deepEqual(stored.plan, originalPlan);
      assert.equal(stored.response_generation ?? 0, 0);
      assert.equal(stored.provider_retirement, undefined);
      assert.equal(stored.responsibility_status, 'unresolved_failure');
      assert.equal(stored.failure_code, cached
        ? 'delivery_identity_unresolved' : 'provider_receipt_identity_unresolved');
      assert(stored.retry_at > f.now());
      assert.equal(f.retrievalRequests.length, 0); assert.equal(f.modelRequests.length, 0);
      assert.equal(f.postAttempts.length, 0); assert.equal(f.sent.length, 0);
    }
  });

  await test('F14d 过期processing旧任务仍须复核畸形迁移标记，不得绕过门禁调用Provider', async () => {
    const markerCases = [
      { name: 'negative', value: -1 },
      { name: 'string', value: '1' },
      { name: 'object', value: { invalid: true } },
    ];
    for (const markerCase of markerCases) {
      const f = makeFixture('legacy-processing-invalid-marker-' + markerCase.name);
      const session = 'session_processing-invalid-marker-' + markerCase.name;
      const job = f.legacyUnpooled(f.makeJob(session, 'processing-' + markerCase.name,
        undefined, { status: 'processing', attempts: 1,
          lease_until: f.now() - 1, execution_token: 'expired-owner' }));
      job.inference.deadline_at = f.now() - 1;
      job.legacy_unpooled_inference_migrated_at = structuredClone(markerCase.value);
      const originalInference = structuredClone(job.inference);
      await f.seed(session, (state) => {
        state.jobs.push(job);
        state.worker = { job: job.id, token: 'expired-owner', until: f.now() - 1 };
      });

      assert.equal((await f.runtime().process(f.key(session), job.id)).status, 'unresolved');
      const stored = f.rawState(session).jobs.find((entry) => entry.id === job.id);
      assert.deepEqual(stored.legacy_unpooled_inference_migrated_at, markerCase.value);
      assert.deepEqual(stored.inference, originalInference);
      assert.equal(stored.status, 'received');
      assert.equal(stored.responsibility_status, 'unresolved_failure');
      assert.equal(stored.failure_code, 'provider_receipt_identity_unresolved');
      assert(stored.retry_at > f.now());
      assert.equal(f.retrievalRequests.length, 0); assert.equal(f.modelRequests.length, 0);
      assert.equal(f.postAttempts.length, 0); assert.equal(f.sent.length, 0);
    }
  });

  await test('F15 旧 safe_error 与未发送缓存转为不可见责任，恢复后同一 job 重新规划一次', async () => {
    for (const kind of ['text', 'image']) for (const outgoingStatus of ['none', 'queued', 'malformed']) {
      const f = makeFixture('natural-cached-' + kind + '-' + outgoingStatus); const session = 'session_cached-error';
      const plan = { type: 'text', purpose: 'safe_error', ordinary: true, content: '旧欢迎语\n\n' + legacyFailure, fingerprint: 78001 };
      const job = f.makeJob(session, 'cached-safe-error', plan);
      if (kind === 'image') job.data = f.event(session, { url: 'https://storage.crisp.chat/synthetic.png', type: 'image/png' }, { type: 'file' }).data;
      await f.seed(session, state => {
        state.jobs.push(job);
        if (outgoingStatus !== 'none') state.outgoing['78001'] = f.makeOutgoing(job, plan.content, outgoingStatus);
      });
      f.restart(); await f.runtime().scan();
      const normalized = f.rawState(session).jobs.find((entry) => entry.id === job.id);
      if (outgoingStatus === 'malformed') {
        assert.deepEqual(normalized.plan, plan,
          '未知 outgoing 状态必须保留原计划供诊断，不能伪装成未发送后重规划');
        assert.equal(normalized.failure_code, 'delivery_identity_unresolved');
        assert(normalized.retry_at > f.now());
      } else {
        assert.equal(normalized.plan.purpose, 'technical_unresolved');
        assert.equal(normalized.plan.content, '');
      }
      assert.equal(normalized.response_generation ?? 0,
        outgoingStatus === 'queued' ? 1 : 0,
        '同一轮机械计划收敛与旧出站退休最多推进一次回答代');
      if (outgoingStatus === 'queued') {
        assert.equal(f.rawState(session).outgoing['78001'].status, 'cancelled');
        assert.equal(Object.hasOwn(f.rawState(session).outgoing['78001'], 'body'), false);
        f.restart(); await f.runtime().scan();
        assert.equal(f.rawState(session).jobs.find((entry) => entry.id === job.id)
          .response_generation, 1, '重复读取不得再次推进回答代');
      } else if (outgoingStatus === 'malformed') {
        const record = f.rawState(session).outgoing['78001'];
        assert.equal(record.status, 'malformed');
        assert.equal(record.body.content, plan.content,
          '未知 outgoing 状态不得被洗成可忽略的 cancelled 记录');
      }
      const result = await f.runtime().process(f.key(session), job.id);
      assert.equal(result.status, outgoingStatus === 'malformed' ? 'idle' : 'unresolved');
      assertUnresolvedResponsibility(f, session, job.id, job.data.content);
      assert.equal(f.modelRequests.length, 0); assert.equal(f.visionRequests.length, 0);
      if (outgoingStatus === 'malformed') {
        f.advance(300001); f.restart(); await f.runtime().scan();
        const retry = await f.runtime().process(f.key(session), job.id);
        assert.notEqual(retry.status, 'sent', '未知 outgoing 状态不能自动恢复为第二份答复');
        assertUnresolvedResponsibility(f, session, job.id, job.data.content);
        assert.equal(f.rawState(session).outgoing['78001'].status, 'malformed');
        assert.equal(f.modelRequests.length, 0); assert.equal(f.postAttempts.length, 0);
        continue;
      }
      await recoverSameJobOnce(f, session, job.id, f.modes.answer);
      assert.equal(f.modelRequests.length, 1);
      assert.equal(f.visionRequests.length, kind === 'image' ? 1 : 0);
    }
  });

  await test('F16 旧系统错误 unknown 先原样对账；未送达转 unresolved 后恢复业务答案', async () => {
    for (const status of ['unknown', 'sending']) for (const found of [false, true]) {
      const f = makeFixture('natural-uncertain-' + status + '-' + found); const session = 'session_uncertain-error';
      const job = f.makeJob(session, 'uncertain-safe-error', { type: 'text', purpose: 'safe_error', ordinary: true, content: legacyFailure, fingerprint: 79001 });
      const record = f.makeOutgoing(job, legacyFailure, status);
      await f.seed(session, state => { state.jobs.push(job); state.outgoing['79001'] = record; });
      const historical = [{ ...record.body, timestamp: f.now() - 1000 }];
      if (found) f.histories.set(session, structuredClone(historical));
      else f.modes.exactStatus = 404;
      f.restart(); await f.runtime().scan();
      assert.equal(f.rawState(session).outgoing['79001'].body.content, legacyFailure, '未知回执正文在核实前保留');
      const first = await f.runtime().process(f.key(session));
      assert.equal(f.sent.length, 0); assert.equal(f.postAttempts.length, 0);
      if (found) {
        assert.equal(first.status, 'delivered_non_answer');
        assert.deepEqual(f.histories.get(session), historical, '已送达历史不得被改写成另一条正文');
        assert.equal(f.rawState(session).outgoing['79001'].status, 'sent');
        const settled = f.rawState(session).jobs.find((entry) => entry.id === job.id);
        assert.equal(settled.status, 'received');
        assert.equal(settled.responsibility_status, 'unresolved_failure');
        assert.equal(settled.failure_code, 'delivered_non_answer');
        assert.equal(settled.response_generation, 1);
        assert(settled.data, '旧机械正文已送达仍必须保留原问题责任');
        assert.equal(f.modelRequests.length, 0);
      } else {
        assert.equal(first.status, 'retry');
        assert.equal(f.rawState(session).outgoing['79001'].body.content, legacyFailure);
        f.advance(5000); f.restart(); await f.runtime().scan();
        assert.equal((await f.runtime().process(f.key(session), job.id)).status, 'deferred');
        assert.equal(f.postAttempts.length, 0, '两次精确负查只能退出旧机械正文，不能发送 generic 替代句');
        f.advance(5000); f.restart();
        assert.equal((await f.runtime().process(f.key(session), job.id)).status, 'sent');
        const completed = f.rawState(session).jobs.find((entry) => entry.id === job.id);
        assert.equal(completed.status, 'done');
        assert.equal(completed.responsibility_status, 'answered_confirmed');
        assert.equal(f.exactRequests.length, 2);
        assert.equal(f.modelRequests.length, 1);
        assert.equal(f.postAttempts.length, 1);
        assert.equal(f.sent.length, 1);
        assert.equal(f.sent[0].content, f.modes.answer);
        f.restart();
        assert.equal((await f.runtime().process(f.key(session), job.id)).status, 'idle');
        assert.equal(f.sent.length, 1);
      }
      assert.equal(f.state(session).mode, 'ai');
    }
  });

  await test('F17 自然错误计划仍服从全局停用与人工状态，未发送时不创建身份记录', async () => {
    for (const mode of ['disabled', 'human']) {
      const f = makeFixture('natural-cancel-' + mode); const session = 'session_cancel-error';
      const job = f.makeJob(session, 'cancel-safe-error', { type: 'text', purpose: 'safe_error', ordinary: true, content: legacyFailure, fingerprint: 80001 });
      await f.seed(session, state => { state.jobs.push(job); if (mode === 'human') { state.mode = 'human'; state.resume_at = null; } });
      if (mode === 'disabled') {
        f.writeConfig('runtime', { schema_version: 2, enabled: false, revision: 1, applied_revision: 1 });
        f.publishCurrentMaterials();
      }
      f.restart(); assert(['idle', 'cancelled'].includes((await f.runtime().process(f.key(session))).status));
      assert.equal(f.sent.length, 0); assert.equal(f.modelRequests.length, 0);
      assert.equal(fs.readdirSync(path.join(f.root, 'data/runtime')).filter(name => name.startsWith('owned-')).length, 0);
      const cancelled = f.rawState(session).jobs.find(item => item.id === job.id);
      assert.equal(cancelled.status, 'cancelled'); assert.equal(cancelled.data, undefined);
      assert.equal(f.state(session).mode, mode === 'human' ? 'human' : 'ai');
    }
  });

  await test('F18 不按文字相似度删除普通问答或业务引用，内部约束独立加入且原 Prompt 不变', async () => {
    const f = makeFixture('natural-ownership'); const session = 'session_error-quotation';
    const quoted = '网站显示“' + legacyFailure + '”时，应该怎样检查网络？';
    f.modes.answer = '请先记录网页中的“' + legacyFailure + '”，再核对网络设置。';
    await f.deliver(f.event(session, quoted));
    assert.equal(f.sent.at(-1).content, f.modes.answer);
    assert.deepEqual(f.retrievalRequests.at(-1), { query: quoted });
    assert.equal(textOf(messagesOf(f.modelRequests.at(-1)).at(-1)), quoted);
    assert(textOfRequest(f.modelRequests.at(-1)).includes('不得使用系统忙、无法回复、稍后再试等机械故障话术'));
    await f.deliver(f.event('session_error-image-rule', { url: 'https://storage.crisp.chat/synthetic.png', type: 'image/png' }, { type: 'file' }));
    assert.equal(f.visionRequests[0].messages[0].content, f.prompt);
    assert(f.visionRequests[0].messages[1].content.includes('不得使用系统忙、无法回复、稍后再试等机械故障话术'));
    const businessContent = '订单暂时无法处理，请稍后再试。';
    const business = f.makeJob(session, 'business-quote', { type: 'text', purpose: 'keyword_reply', ordinary: true, content: businessContent, fingerprint: 81001 });
    await f.seed(session, state => state.jobs.push(business));
    await f.runtime().process(f.key(session));
    assert.equal(f.sent.at(-1).content, businessContent, '含实质业务对象的固定回复不得被改写');
    assert.equal(fs.readFileSync(path.join(f.root, 'config/prompt.md'), 'utf8'), f.prompt);
  });

  await test('F19 人工公开回复始终接管，缺省3600秒，显式秒数和0仍有效且访客不刷新计时', async () => {
    for (const duration of ['template', 'missing', 42, 1800, 0]) {
      const f = makeFixture('human-default-' + duration); const session = 'session_human-default';
      const policy = f.readConfig('handoff');
      if (duration === 'missing') delete policy.handoff.resume_after_seconds;
      else if (typeof duration === 'number') policy.handoff.resume_after_seconds = duration;
      policy.handoff.enabled = false; policy.handoff.disable_ai = false;
      f.writeConfig('handoff', policy);
      f.publishCurrentMaterials();
      const event = f.event(session, '纯合成人工公开说明', { from: 'operator', user: { nickname: '合成操作者', user_id: 'b21e3759-21a4-4b3a-8c7a-379e803af142' } });
      event.event = 'message:received';
      await f.receive(event);
      const seconds = typeof duration === 'number' ? duration : 3600;
      assert.equal(f.state(session).mode, 'human');
      assert.equal(f.state(session).pause_reason, 'operator_reply');
      const deadline = seconds === 0 ? null : f.now() + seconds * 1000;
      assert.equal(f.state(session).resume_at, deadline, String(duration));
      f.advance(1000); await f.deliver(f.event(session, '是，我补充了信息。'));
      assert.equal(f.state(session).resume_at, deadline); assert.equal(f.state(session).mode, 'human');
      assert.equal(f.sent.length, 0); assert.equal(f.modelRequests.length, 0);
      if (seconds > 0) {
        f.advance(seconds * 1000 - 1001); await f.deliver(f.event(session, '到期前仍由人工处理'));
        assert.equal(f.state(session).mode, 'human'); assert.equal(f.sent.length, 0);
        f.advance(1); await f.deliver(f.event(session, '到期后新的合成问题'));
        assert.equal(f.state(session).mode, 'ai'); assert.equal(f.sent.length, 1);
      } else {
        f.advance(7200000); await f.deliver(f.event(session, '永久人工不自动恢复'));
        assert.equal(f.state(session).mode, 'human'); assert.equal(f.sent.length, 0);
      }
    }
  });

  await test('F20 配置迁移精确清空旧失败默认并补缺省秒数，保留显式1800、自定义及0', async () => {
    const variants = [
      { failure: legacyFailure, seconds: 'missing' },
      { failure: '当前自动客服暂时不可用，请稍后再试。', seconds: 1800 },
      { failure: '自动客服暂时无法回答，请稍后再试。', seconds: 0 },
      { failure: '自定义历史故障原文：系统忙，请稍后再试。', seconds: 37 },
    ];
    for (const [index, variant] of variants.entries()) {
      const f = makeFixture('natural-config-' + index, { materials: 'absent' });
      const input = path.join(f.root, 'config/handoff.yaml');
      assert.equal(fs.existsSync(path.join(f.root, 'config/materials-applied.json')), false,
        '纯配置迁移测试不得暗中依赖 applied materials');
      const policy = f.readConfig('handoff'); policy.handoff.failure_message = variant.failure;
      if (variant.seconds === 'missing') delete policy.handoff.resume_after_seconds;
      else policy.handoff.resume_after_seconds = variant.seconds;
      f.writeConfig('handoff', policy);
      const before = fs.readFileSync(input);
      const migrate = () => {
        const result = spawnSync('bash', ['-c', 'source "$1"; configuration_migrate "$2"', 'synthetic-configuration-migrate', path.join(project, 'scripts/configuration.sh'), f.root], { encoding: 'utf8' });
        assert.equal(result.status, 0, result.stderr);
      };
      migrate();
      const expected = structuredClone(policy);
      expected.handoff.resume_after_seconds = variant.seconds === 'missing' ? 3600 : variant.seconds;
      if (index < 3) expected.handoff.failure_message = '';
      assert.deepEqual(f.readConfig('handoff'), expected);
      const applied = fs.readFileSync(input); migrate();
      assert.deepEqual(fs.readFileSync(input), applied, '再次迁移不改变当前合法选择');
      if (index < 3) {
        const backup = path.join(f.root, 'backups/config-history/handoff.display.pre-v1.2.1.yaml');
        assert.deepEqual(fs.readFileSync(backup), before); assert.equal(fs.statSync(backup).mode & 0o777, 0o600);
      }
      assert.equal(fs.readFileSync(path.join(f.root, 'config/prompt.md'), 'utf8'), f.prompt);
    }
  });

  await test('F21 缺知识保留未解决责任，低置信候选仍走实质回答且旧提示字段不直接出站', async () => {
    const legacy = {
      no_answer_message: ['知识库暂时没有足够信息，请换一种方式描述问题。', '目前知识还不足以确认，请补充您遇到的具体情况。'],
      low_confidence_message: ['当前答案可信度不足，请补充更多问题细节。', '现有资料还不足以确定答案，请补充更多细节。'],
    };
    for (const field of Object.keys(legacy)) for (const storage of ['current', 'stale']) for (const variant of ['example', 0, 1, 'missing', 'custom']) {
      const f = makeFixture('natural-default-' + field + '-' + storage + '-' + variant), session = 'session_natural-default';
      const policy = f.readConfig('handoff'), custom = '请告诉我你使用的设备型号与发生问题的具体步骤。';
      if (typeof variant === 'number') policy.handoff[field] = legacy[field][variant];
      if (variant === 'missing') delete policy.handoff[field];
      if (variant === 'custom') policy.handoff[field] = custom;
      f.writeConfig('handoff', policy);
      const published = f.publishCurrentMaterials();
      assert.deepEqual(published.configuration.handoff, policy);
      if (storage === 'stale') {
        f.writeConfig('handoff', { handoff: { ...policy.handoff, [field]: '未应用编辑不应生效' } });
        assert.equal(f.readConfig('handoff').handoff[field], '未应用编辑不应生效');
        assert.deepEqual(JSON.parse(fs.readFileSync(path.join(f.root, 'config/materials-applied.json')))
          .configuration.handoff, policy, 'stale 场景必须保留上一份已应用投影');
      } else {
        assert.deepEqual(f.readConfig('handoff'), policy, 'current 场景原文与投影必须同代');
      }
      f.modes.retrievalPayload = { results: field === 'no_answer_message' ? [] : [retrievalResult(0.99)] };
      f.modes.answer = '合成低分候选答案';
      const input = f.event(session, '请帮我确认这个具体问题。');
      const result = await f.deliver(input);
      assert.equal(f.state(session).mode, 'ai'); assert.deepEqual(f.state(session).offers, {});
      assert.equal(f.workspaceRequests.length, 0, '当前 schema-v2 温度投影不得重复请求旧 workspace 设置');
      assert.equal(f.retrievalRequests.length, 1);
      if (field === 'no_answer_message') {
        assert.equal(result.status, 'unresolved');
        assert.equal(f.modelRequests.length, 0, '没有当前代知识来源时不能让模型猜测业务事实');
        assertUnresolvedResponsibility(f, session, result.jobId, input.data.content);
        f.modes.retrievalPayload = { results: [retrievalResult(0.1)] };
        await recoverSameJobOnce(f, session, result.jobId, f.modes.answer);
        assert.equal(f.modelRequests.length, 1);
      } else {
        assert.equal(result.status, 'sent');
        assert.equal(f.modelRequests.length, 1, '低置信候选仍执行一次实际生成，而非发送旧 generic 字段');
        assert.equal(f.sent.length, 1);
        assert.equal(f.sent[0].content, f.modes.answer);
      }
      assert(!f.sent.some((item) => item.content === custom || item.content === clarification),
        '旧 handoff 提示字段只兼容保留，不能作为推理或检索故障的访客正文');
      f.noFeedback();
      assert.equal(fs.readFileSync(path.join(f.root, 'config/prompt.md'), 'utf8'), f.prompt);
    }
  });

  await test('F22 资料归一化把两类程序旧澄清默认迁为空，自定义原文只保留不自动派发', async () => {
    for (const [index, messages] of [
      ['知识库暂时没有足够信息，请换一种方式描述问题。', '当前答案可信度不足，请补充更多问题细节。'],
      ['目前知识还不足以确认，请补充您遇到的具体情况。', '现有资料还不足以确定答案，请补充更多细节。'],
      [undefined, undefined], ['自定义缺知识原文。', '自定义低置信度原文。'],
    ].entries()) {
      const f = makeFixture('natural-normalize-' + index, { materials: 'absent' });
      assert.equal(fs.existsSync(path.join(f.root, 'config/materials-applied.json')), false,
        '纯归一化测试不得暗中依赖 applied materials');
      const policy = f.readConfig('handoff');
      for (const [position, field] of ['no_answer_message', 'low_confidence_message'].entries()) {
        if (messages[position] === undefined) delete policy.handoff[field];
        else policy.handoff[field] = messages[position];
      }
      f.writeConfig('handoff', policy);
      const output = path.join(f.root, 'normalized-handoff.json');
      const result = spawnSync('bash', ['-c', 'source "$1"; configuration_normalize_file handoff "$2" "$3"', 'synthetic-normalize', path.join(project, 'scripts/configuration.sh'), path.join(f.root, 'config/handoff.yaml'), output], { encoding: 'utf8' });
      assert.equal(result.status, 0, result.stderr);
      const normalized = JSON.parse(fs.readFileSync(output));
      assert.equal(normalized.handoff.no_answer_message, index === 3 ? messages[0] : '');
      assert.equal(normalized.handoff.low_confidence_message, index === 3 ? messages[1] : '');
      assert.deepEqual(f.readConfig('handoff'), policy, '归一化候选不改可编辑原文');
    }
  });

  await test('F23 窗口事务期间持久延后普通任务，清除marker后按最新revision恰好回复一次', async () => {
    for (const kind of ['applying', 'restore_failed', 'malformed', 'directory', 'symlink', 'permission']) {
      const f = makeFixture('window-marker-' + kind), session = 'session_window-marker';
      const marker = path.join(f.root, 'config/provider-pool-transaction.json');
      if (kind === 'directory') fs.mkdirSync(marker);
      else if (kind === 'symlink') fs.symlinkSync(path.join(f.root, 'missing-marker-target'), marker);
      else if (kind !== 'permission') fs.writeFileSync(marker, kind === 'malformed' ? 'invalid-synthetic-json' : JSON.stringify({ phase: kind }), { mode: 0o600 });
      const read = fs.readFileSync, lstat = fs.lstatSync; let markerReads = 0;
      const input = f.event(session, '窗口应用期间的普通合成问题'); let received;
      try {
        fs.readFileSync = (file, ...args) => { if (file === marker) { markerReads += 1; throw new Error('不能读取窗口marker正文'); } return read(file, ...args); };
        if (kind === 'permission') fs.lstatSync = (file, ...args) => { if (file === marker) throw Object.assign(new Error('synthetic-permission'), { code: 'EACCES' }); return lstat(file, ...args); };
        received = await f.receive(input);
        assert.equal(received.accepted, true); assert.equal(received.route, 'process', kind);
        let job = f.rawState(session).jobs.find(item => item.id === received.jobId);
        assert.equal(job.status, 'received'); assert.equal(job.deferred_configuration, undefined);
        assert.equal((await f.runtime().process(received.key, received.jobId)).status, 'deferred', kind);
        job = f.rawState(session).jobs.find(item => item.id === received.jobId);
        assert.equal(job.status, 'received'); assert.equal(job.deferred_configuration, true);
        assert.equal(job.data.content, '窗口应用期间的普通合成问题');
        assert.equal(markerReads, 0); assert.equal(f.sent.length, 0); assert.equal(f.modelRequests.length, 0);
      } finally { fs.readFileSync = read; fs.lstatSync = lstat; }
      f.writeConfig('runtime', { schema_version: 2, enabled: true, revision: 2, applied_revision: 2 });
      f.publishCurrentMaterials();
      if (kind === 'directory') fs.rmdirSync(marker);
      else if (kind !== 'permission') fs.unlinkSync(marker);
      f.advance(5000); f.restart();
      const pending = await f.runtime().scan();
      assert(pending.some(item => item.key === f.key(session) && item.jobId === received.jobId), kind);
      const rebound = f.rawState(session).jobs.find(item => item.id === received.jobId);
      assert.equal(rebound.status, 'received'); assert.equal(rebound.revision, 2);
      assert.equal(rebound.deferred_configuration, undefined); assert.equal(rebound.retry_at, null);
      assert.equal((await f.runtime().process(f.key(session), received.jobId)).status, 'sent');
      assert.equal(f.sent.length, 1); assert.equal(f.modelRequests.length, 1); assert.equal(f.state(session).mode, 'ai');
      assert.equal((await f.receive(input)).route, 'ignore');
      assert.equal(f.sent.length, 1); assert.equal(f.modelRequests.length, 1, '重复Hook不得二次生成');
    }
  });

  await test('F23a 接口窗口中新鲜本地规则及方案仍立即执行，只延后真正推理', async () => {
    const f = makeFixture('window-fresh-local-actions');
    const marker = path.join(f.root, 'config/provider-pool-transaction.json');
    fs.writeFileSync(marker, JSON.stringify({ phase: 'applying' }), { mode: 0o600 });
    const keywords = f.readConfig('keyword');
    keywords.rules.unshift({ id: 'window-local-reply', name: '窗口本地回复', enabled: true,
      match_mode: 'exact', keywords: ['窗口本地规则'], exclude_keywords: [], priority: 1000,
      action: 'reply', text: '当前已应用的本地回复', cooldown_seconds: 0 });
    f.writeConfig('keyword', keywords);
    f.publishCurrentMaterials();

    const fixed = await f.deliver(f.event('session_window-local-reply', '窗口本地规则'));
    assert.equal(fixed.status, 'sent');
    assert.equal(f.sent.at(-1).content, '当前已应用的本地回复');
    assert.equal(f.modelRequests.length, 0);
    assert.equal(f.retrievalRequests.length, 0);

    const handoff = await f.deliver(f.event('session_window-handoff', '人工'));
    assert.equal(handoff.status, 'sent');
    assert.equal(f.sent.at(-1).type, 'picker');
    assert.equal(f.sent.at(-1).content.choices[0].label, '召唤人工客服');
    assert.equal(f.state('session_window-handoff').mode, 'ai');
    assert.equal(f.modelRequests.length, 0);
    assert.equal(f.retrievalRequests.length, 0);

    f.modes.historyFailure = true;
    const question = f.event('session_window-provider-wait', '需要知识和模型的新问题');
    const accepted = await f.receive(question);
    assert.equal(accepted.route, 'process', '新任务应先进入本地规则规划');
    const deferred = await f.runtime().process(accepted.key, accepted.jobId);
    assert.equal(deferred.status, 'deferred');
    const stored = f.rawState('session_window-provider-wait').jobs.find((job) => job.id === accepted.jobId);
    assert.equal(stored.status, 'received');
    assert.equal(stored.deferred_configuration, true);
    assert.equal(stored.data.content, question.data.content);
    assert.equal(f.sent.length, 2);
    assert.equal(f.postAttempts.length, 2);
    assert.equal(f.modelRequests.length, 0);
    assert.equal(f.visionRequests.length, 0);
    assert.equal(f.retrievalRequests.length, 0);
    assert.equal(f.workspaceRequests.length, 0);
  });

  await test('F24 窗口维护延后依赖接口的计划，旧 safe_error 不可见且恢复后只答一次', async () => {
    for (const kind of ['cached-answer', 'cached-error', 'model-error', 'register-race']) {
      const f = makeFixture('window-send-' + kind), session = 'session_window-send';
      const marker = path.join(f.root, 'config/provider-pool-transaction.json');
      const createMarker = () => fs.writeFileSync(marker, JSON.stringify({ phase: 'restore_failed' }), { mode: 0o600 });
      let result;
      if (kind === 'model-error') {
        f.modes.onModelResponse = createMarker; f.modes.modelFailure = true;
        result = await f.deliver(f.event(session, '窗口事务在网络返回前开始'));
      } else if (kind === 'register-race') {
        const accepted = await f.receive(f.event(session, '窗口事务在计划持久化后开始'));
        assert.equal(accepted.route, 'process');
        const stateFile = path.join(f.root, 'data/runtime/session-' + accepted.key + '.json');
        const rename = fs.renameSync; let injected = false;
        try {
          fs.renameSync = (from, to) => {
            const output = rename(from, to);
            if (!injected && to === stateFile) {
              const state = JSON.parse(fs.readFileSync(stateFile, 'utf8'));
              const stored = state.jobs.find((job) => job.id === accepted.jobId);
              const hasOutgoing = Object.values(state.outgoing || {})
                .some((record) => record?.job_id === accepted.jobId);
              if (stored?.plan && !hasOutgoing) {
                injected = true;
                createMarker();
              }
            }
            return output;
          };
          result = await f.runtime().process(accepted.key, accepted.jobId);
        } finally { fs.renameSync = rename; }
        assert.equal(injected, true,
          '必须精确触发 Provider plan 已持久而 outgoing 尚未注册的维护窗口');
      } else {
        const created = f.makeJob(session, kind, { type: 'text', purpose: kind === 'cached-error' ? 'safe_error' : 'ai_text', ordinary: true,
          content: kind === 'cached-error' ? legacyFailure : '旧代缓存AI正文不得发送', fingerprint: 82001 });
        const job = kind === 'cached-answer' ? f.legacyUnpooled(created) : created;
        if (kind === 'cached-answer') job.inference.deadline_at = f.now() - 1;
        await f.seed(session, state => state.jobs.push(job));
        createMarker(); result = await f.runtime().process(f.key(session));
      }
      const local = kind === 'cached-error';
      if (local) {
        assert.equal(result.status, 'unresolved', kind);
        assertUnresolvedResponsibility(f, session, f.rawState(session).jobs.find(job => job.event === 'message:send').id,
          '旧队列的普通问题');
        assert.equal(f.modelRequests.length, 0);
        assert.equal(f.events().filter(event => event.type === 'ai_reply' || event.type === 'handoff').length, 0);
        fs.unlinkSync(marker); f.modes.onModelResponse = null; f.modes.modelFailure = false;
        const unresolvedId = f.rawState(session).jobs.find(job => job.event === 'message:send').id;
        await recoverSameJobOnce(f, session, unresolvedId, f.modes.answer);
        assert.equal(f.modelRequests.length, 1);
        continue;
      }
      assert(['idle', 'deferred'].includes(result.status), kind + ':' + result.status);
      assert.equal(f.sent.length, 0);
      assert.equal(f.modelRequests.length,
        ['model-error', 'register-race'].includes(kind) ? 1 : 0);
      assert.equal(fs.readdirSync(path.join(f.root, 'data/runtime')).filter(name => name.startsWith('owned-')).length, 0);
      assert.equal(f.events().filter(event => event.type === 'ai_reply' || event.type === 'handoff').length, 0);
      const deferred = f.rawState(session).jobs.find(job => job.event === 'message:send');
      assert.equal(deferred.status, 'received'); assert.equal(deferred.deferred_configuration, true);
      assert(deferred.data, '延后任务必须保留原始访客数据');
      if (kind === 'cached-answer') {
        assert(deferred.plan, '维护未完成时旧直连计划须先留作失权迁移，不能无证据删除');
      } else assert.equal(deferred.plan, undefined, '旧代AI正文必须丢弃后重新规划');
      f.writeConfig('runtime', { schema_version: 2, enabled: true, revision: 2, applied_revision: 2 });
      f.publishCurrentMaterials();
      f.modes.onModelResponse = null; f.modes.modelFailure = false;
      fs.unlinkSync(marker); f.advance(5000); f.restart();
      let scheduled = await f.runtime().scan();
      if (!scheduled.some((item) => item.jobId === deferred.id)) {
        f.advance(1); f.restart(); scheduled = await f.runtime().scan();
      }
      assert(scheduled.some(item => item.jobId === deferred.id));
      const rebound = f.rawState(session).jobs.find(job => job.id === deferred.id);
      assert.equal(rebound.revision, 2); assert.equal(rebound.deferred_configuration, undefined);
      assert.equal((await f.runtime().process(f.key(session), deferred.id)).status, 'sent');
      assert.equal(f.sent.length, 1); assert.equal(f.sent[0].content, f.modes.answer);
      assert.equal(f.modelRequests.length,
        ['model-error', 'register-race'].includes(kind) ? 2 : 1,
        '旧代推理结果丢弃，按新代且只重新规划一次');
      assert.equal((await f.runtime().process(f.key(session), deferred.id)).status, 'idle');
      assert.equal(f.sent.length, 1, '恢复只能有一次最终出站');
    }
  });

  await test('F25 窗口事务延后B普通问题，A人工与总开关仍立即取消各自任务', async () => {
    const f = makeFixture('window-control'), sessionA = 'session_window-human', sessionB = 'session_window-own';
    await f.deliver(f.event(sessionB, '建立真实合成自有发送记录'));
    const own = structuredClone(f.sent[0]);
    const pending = f.makeJob(sessionA, 'pending-before-human', { type: 'text', purpose: 'ai_text', ordinary: true, content: '旧A答案' });
    await f.seed(sessionA, state => state.jobs.push(pending));
    const offer = { id: 'synthetic-manual-offer', kind: 'handoff', expires_at: f.now() + 600000, choices: { yes: { type: 'confirm_handoff' } } };
    await f.seed(sessionB, state => { state.offers[offer.id] = offer; });
    const marker = path.join(f.root, 'config/provider-pool-transaction.json');
    fs.writeFileSync(marker, JSON.stringify({ phase: 'applying' }), { mode: 0o600 });
    f.advance(1000);
    const operator = f.event(sessionA, '合成人工公开回复', { from: 'operator', user: { nickname: '合成操作者', user_id: 'b21e3759-21a4-4b3a-8c7a-379e803af142' } });
    operator.event = 'message:received'; await f.receive(operator);
    assert.equal(f.state(sessionA).mode, 'human'); assert.equal(f.state(sessionA).generation, 1);
    assert.equal(f.rawState(sessionA).jobs.find(job => job.id === pending.id).status, 'cancelled');
    await f.receive({ website_id: f.env.CRISP_WEBSITE_ID, event: 'message:received', timestamp: f.now(), data: { ...own, automated: false, timestamp: f.now() } });
    assert.equal(f.state(sessionB).mode, 'ai'); assert.equal(f.state(sessionB).generation, 0);
    assert.deepEqual(f.state(sessionB).offers[offer.id], offer);
    const delayedInput = f.event(sessionB, '维护期间需要持久等待的问题');
    const delayed = await f.receive(delayedInput);
    assert.equal(delayed.accepted, true); assert.equal(delayed.route, 'process');
    assert.equal((await f.runtime().process(delayed.key, delayed.jobId)).status, 'deferred');
    const delayedJob = f.rawState(sessionB).jobs.find(job => job.id === delayed.jobId);
    assert.equal(delayedJob.status, 'received'); assert.equal(delayedJob.deferred_configuration, true);
    assert.equal(f.sent.length, 1); assert.equal(f.modelRequests.length, 1);
    fs.unlinkSync(marker); f.advance(5000); f.restart();
    assert((await f.runtime().scan()).some(item => item.jobId === delayed.jobId));
    assert.equal((await f.runtime().process(f.key(sessionB), delayed.jobId)).status, 'sent');
    assert.equal(f.sent.filter(message => message.session_id === sessionB).length, 2);
    assert.equal(f.modelRequests.length, 2);
    await f.deliver(f.event(sessionA, '人工期间的新访客消息'));
    assert.equal(f.sent.filter(message => message.session_id === sessionA).length, 0);
    assert.equal(f.sent.filter(message => message.session_id === sessionB).length, 2);
    assert.equal(f.state(sessionA).mode, 'human'); assert.equal(f.state(sessionB).mode, 'ai');

    const sessionC = 'session_window-disabled';
    fs.writeFileSync(marker, JSON.stringify({ phase: 'applying' }), { mode: 0o600 });
    const disabledInput = f.event(sessionC, '窗口期间接收但稍后管理员关闭的问题');
    const disabled = await f.receive(disabledInput);
    assert.equal(disabled.route, 'process');
    assert.equal((await f.runtime().process(disabled.key, disabled.jobId)).status, 'deferred');
    assert.equal(f.rawState(sessionC).jobs.find(job => job.id === disabled.jobId).deferred_configuration, true);
    f.writeConfig('runtime', { schema_version: 2, enabled: false, revision: 2, applied_revision: 2 });
    f.publishCurrentMaterials();
    fs.unlinkSync(marker); f.advance(5000); f.restart(); await f.runtime().scan();
    const cancelled = f.rawState(sessionC).jobs.find(job => job.id === disabled.jobId);
    assert.equal(cancelled.status, 'cancelled'); assert.equal(cancelled.data, undefined);
    assert.equal(f.sent.filter(message => message.session_id === sessionC).length, 0);
    f.writeConfig('runtime', { schema_version: 2, enabled: true, revision: 3, applied_revision: 3 });
    f.publishCurrentMaterials();
    f.restart(); assert.equal((await f.receive(disabledInput)).route, 'ignore');
    assert.equal(f.sent.filter(message => message.session_id === sessionC).length, 0, '总开关关闭期间的旧问题不得恢复补发');
  });

  await test('F26 上游200返回旧系统失败句时零出站，保留同一责任并在恢复后回答一次', async () => {
    for (const [index, content] of [legacyFailure, '当前自动客服暂时不可用，请稍后再试。', '自动客服暂时无法回答，请稍后再试。'].entries()) {
      const f = makeFixture('natural-exact-model-failure-' + index), session = 'session_exact-failure';
      f.modes.answer = content;
      const input = f.event(session, '真实query出口的合成问题');
      const failure = await f.deliver(input);
      assert.equal(failure.status, 'unresolved');
      assertUnresolvedResponsibility(f, session, failure.jobId, input.data.content);
      assert.equal(f.modelRequests.length, 1); assert.equal(f.state(session).mode, 'ai');
      assert.equal(f.events().filter(event => event.type === 'ai_reply' || event.type === 'knowledge_hit').length, 0);
      f.modes.answer = '恢复后的有效业务答案。';
      await recoverSameJobOnce(f, session, failure.jobId, f.modes.answer);
      assert.equal(f.modelRequests.length, 2);
      f.noFeedback();
    }
  });

  await test('F27 已发业务菜单指向失效节点时直接请求具体问题，不暴露内部不可用话术', async () => {
    const f = makeFixture('natural-missing-menu'), session = 'session_missing-menu';
    await f.deliver(f.event(session, '菜单'));
    const card = f.sent[0]; assert.equal(card.type, 'picker');
    const menu = f.readConfig('menu');
    delete menu.menus.computer; delete menu.menus.main.options['1'];
    f.writeConfig('menu', menu);
    f.publishCurrentMaterials();
    const click = f.event(session, { ...card.content, choices: card.content.choices.map((choice, index) => ({ ...choice, selected: index === 0 })) }, { type: 'picker', fingerprint: card.fingerprint });
    click.event = 'message:updated'; await f.deliver(click);
    assert.equal(f.sent.length, 2); assert.equal(f.sent[1].type, 'text');
    assert.equal(f.sent[1].content, visitorFallbackFor('menu_missing'));
    assert.equal(f.modelRequests.length, 0); assert.equal(f.visionRequests.length, 0);
    assert.equal(f.state(session).mode, 'ai');
    assert.equal(f.events().filter(event => event.type === 'ai_reply' || event.type === 'handoff').length, 0);
    assert.deepEqual(f.readConfig('menu'), menu, '不改管理员的当前菜单原文');
    f.noFeedback();
  });

  await test('F28 视觉200返回旧系统失败句时不写图片记忆且零出站，恢复后回答一次', async () => {
    for (const [index, content] of [legacyFailure, '当前自动客服暂时不可用，请稍后再试。', '自动客服暂时无法回答，请稍后再试。'].entries()) {
      const f = makeFixture('natural-exact-vision-failure-' + index), session = 'session_exact-vision-failure';
      f.modes.visionAnswer = content;
      const input = f.event(session, { url: 'https://storage.crisp.chat/synthetic.png', type: 'image/png' }, { type: 'file' });
      const failure = await f.deliver(input);
      assert.equal(failure.status, 'unresolved');
      assert.equal(f.visionRequests.length, 1); assert.equal(f.modelRequests.length, 0, '旧系统失败句不是可供RAG使用的识图结果');
      assert.equal(Object.hasOwn(f.rawState(session), 'image_context'), false, '失败句不能记为图片上下文');
      assertUnresolvedResponsibility(f, session, failure.jobId, input.data.content);
      assert.equal(f.state(session).mode, 'ai'); assert.deepEqual(f.state(session).offers, {});
      assert.equal(f.events().filter(event => ['ai_reply', 'knowledge_hit', 'handoff'].includes(event.type)).length, 0);
      f.modes.visionAnswer = '图片可见虚构的保存按钮。';
      await recoverSameJobOnce(f, session, failure.jobId, f.modes.answer);
      assert.equal(f.visionRequests.length, 2); assert.equal(f.modelRequests.length, 1);
      f.noFeedback();
    }
  });

  await test('F29 Chat与Responses识图只提取当前图片事实，前问格式作为引用背景而非待答消息', async () => {
    for (const apiMode of ['chat_completions', 'responses']) {
      const f = makeFixture('vision-stage-' + apiMode), session = 'session_vision-stage';
      const previous = '请计算9加8，只输出这道算术题的数字。';
      const facts = '图片可见：编号4872，左侧绿色三角形，右侧灰色圆形。';
      f.writeConfig('provider', { provider: { ...f.readConfig('provider').provider, api_mode: apiMode } });
      const history = [f.event(session, previous).data,
        { ...f.event(session, '17').data, from: 'operator', automated: true }];
      f.histories.set(session, history);
      f.advance(1000);
      // 这是请求契约夹具，不是视觉模型能力证据：旧活动提问会得到旧答案。
      f.modes.visionAnswer = body => (body.messages || body.input).some(message => message.role === 'user'
        && (typeof message.content === 'string' || !message.content.some(part => ['image_url', 'input_image'].includes(part.type)))) ? '17' : facts;
      const input = f.event(session, { url: 'https://storage.crisp.chat/stage-image.png', type: 'image/png' }, { type: 'file' });
      history.push(input.data);
      await f.deliver(input);
      assert.equal(f.visionRequests.length, 1); assert.equal(f.modelRequests.length, 1);
      const body = f.visionRequests[0], messages = body.messages || body.input;
      const textOf = message => typeof message.content === 'string' ? message.content : message.content.filter(part => ['text', 'input_text', 'output_text'].includes(part.type)).map(part => part.text).join('\n');
      assert.equal(textOf(messages[0]), f.prompt);
      assert(textOf(messages[1]).includes('不得主动邀请用户评价'));
      assert.deepEqual(messages.map(message => message.role), ['system', 'system', 'system', 'user'], '历史客服消息也不能重新成为活动消息');
      assert.equal(messages.filter(message => message.role === 'user').length, 1, '历史不能继续作为活动用户提问');
      assert(messages.some(message => message.role === 'system' && textOf(message).includes('只提取当前附带图片中可见的事实')));
      const current = messages.at(-1);
      assert.equal(current.role, 'user'); assert(Array.isArray(current.content));
      assert(textOf(current).includes('只读背景')); assert(textOf(current).includes(previous));
      const image = current.content.find(part => ['image_url', 'input_image'].includes(part.type));
      assert.match(apiMode === 'responses' ? image.image_url : image.image_url.url, /^data:image\/png;base64,/);
      if (apiMode === 'responses') { assert.equal(body.store, false); assert.equal(body.max_output_tokens, 1200); }
      else assert.equal(body.max_tokens, 1200);
      assert.equal(f.state(session).image_context[0].summary, facts);
      assert.deepEqual(f.retrievalRequests[0], { query: facts });
      assert(textOfRequest(f.modelRequests[0]).includes(facts)); assert(textOfRequest(f.modelRequests[0]).includes(previous));
      assert.equal(f.sent.length, 1); assert.equal(f.sent[0].content, f.modes.answer);
      f.restart(); f.advance(1000);
      await f.deliver(f.event(session, '刚才图片左边是什么颜色和形状？'));
      assert.equal(f.visionRequests.length, 1, '后指使用已保存事实，不重复上传识图');
      assert.deepEqual(f.retrievalRequests[1], { query: '刚才图片左边是什么颜色和形状？' });
      assert(textOfRequest(f.modelRequests[1]).includes(facts)); assert.equal(f.sent.length, 2);
      await f.deliver(f.event('session_other-vision', '另一会话的独立问题'));
      assert(!textOfRequest(f.modelRequests[2]).includes(facts)); assert(!textOfRequest(f.modelRequests[2]).includes(previous));
      assert.equal(fs.readFileSync(path.join(f.root, 'config/prompt.md'), 'utf8'), f.prompt); f.noFeedback();
    }
  });

  await test('F30 提取图片事实期间真人介入或总开关关闭，不保存迟到摘要、不续RAG、不发送', async () => {
    for (const action of ['human', 'disabled']) {
      const f = makeFixture('vision-stage-cancel-' + action), session = 'session_vision-cancel';
      f.modes.onVisionResponse = async () => {
        if (action === 'disabled') {
          f.writeConfig('runtime', { schema_version: 2, enabled: false, revision: 2, applied_revision: 2 });
          f.publishCurrentMaterials();
        }
        else {
          f.advance(1000);
          const human = f.event(session, '合成真人公开处理说明', { from: 'operator', user: { user_id: 'b21e3759-21a4-4b3a-8c7a-379e803af142' } });
          human.event = 'message:received';
          await f.receive(human);
          assert.equal(f.state(session).mode, 'human');
          assert.equal(f.state(session).resume_at, f.now() + 3600000);
        }
      };
      await f.deliver(f.event(session, { url: 'https://storage.crisp.chat/cancel-image.png', type: 'image/png' }, { type: 'file' }));
      assert.equal(f.visionRequests.length, 1); assert.equal(f.modelRequests.length, 0); assert.equal(f.sent.length, 0);
      assert.equal((f.state(session).image_context || []).length, 0);
      assert(f.rawState(session).jobs.filter(job => job.event === 'message:send').every(job => job.status === 'cancelled'));
      f.noFeedback();
    }
  });

  await test('F31 当前资料温度用于两种生成协议，普通问答不依赖旧 workspace 全量回读', async () => {
    for (const apiMode of ['chat_completions', 'responses']) for (const legacyShape of ['http-error', 'invalid-body']) {
      const f = makeFixture('temperature-' + apiMode + '-' + legacyShape);
      f.writeConfig('provider', { provider: { ...f.readConfig('provider').provider, api_mode: apiMode } });
      f.modes.workspaceStatus = legacyShape === 'http-error' ? 503 : 200;
      f.modes.workspacePayload = legacyShape === 'invalid-body' ? { workspace: 'invalid' }
        : { error: true };
      f.modes.expectedTemperature = 0.7;
      await f.deliver(f.event('session_workspace-temperature', '虚构温度协议问题'));
      assert.equal(f.workspaceRequests.length, 0,
        'schema-v2 生效投影已经冻结温度，不得在每个问题中下载旧 workspace 设置');
      assert.equal(f.retrievalRequests.length, 1); assert.equal(f.modelRequests.length, 1);
      assert.equal(f.modelRequests[0].temperature, f.modes.expectedTemperature);
      assert.equal(textOf(messagesOf(f.modelRequests[0])[0]), f.prompt);
      assert.equal(f.sent[0].content, f.modes.answer); assert.equal(f.state('session_workspace-temperature').mode, 'ai');
      f.noFeedback();
    }
  });

  await test('F32 人工词冷却期重复输入仍有一次自然响应，不暴露机器身份', async () => {
    const f = makeFixture('handoff-cooldown-reply'), session = 'session_handoff-cooldown';
    await f.deliver(f.event(session, '人工'));
    assert.equal(f.sent.length, 1); assert.equal(f.sent[0].type, 'picker');
    const offerIds = Object.keys(f.state(session).offers);
    assert.equal(offerIds.length, 1); assert.equal(f.state(session).mode, 'ai');
    f.advance(1000);
    const result = await f.deliver(f.event(session, '转人工'));
    assert.equal(result.status, 'sent'); assert.equal(f.sent.length, 2);
    assert.equal(f.sent[1].type, 'text'); assert.equal(typeof f.sent[1].content, 'string');
    assert(f.sent[1].content.trim(), '冷却期不能以空计划静默结束');
    assert.doesNotMatch(f.sent[1].content, /AI|机器人|暂时[^\n]{0,12}(?:无法|不能)[^\n]{0,12}回复|稍后再试/i);
    assert.equal(f.modelRequests.length, 0, '已有人工选择不需要额外付费推理');
    assert.deepEqual(Object.keys(f.state(session).offers), offerIds, '不重复创建人工offer');
    assert.equal(f.state(session).mode, 'ai'); f.noFeedback();
  });

  await test('F33 worker中断造成超过5分钟普通积压时仍恰好回复，不以过期静默取消', async () => {
    const f = makeFixture('old-received-recovery'), session = 'session_old-received';
    const input = f.event(session, '这条问题在worker恢复后仍需要处理');
    const received = await f.receive(input);
    assert.equal(received.route, 'process'); assert.equal(f.sent.length, 0);
    f.advance(300001); f.restart();
    const scanned = await f.runtime().scan();
    assert(scanned.some(item => item.key === f.key(session) && item.jobId === received.jobId));
    const result = await f.runtime().process(f.key(session), received.jobId);
    assert.equal(result.status, 'sent'); assert.equal(f.sent.length, 1);
    assert.equal(f.sent[0].content, f.modes.answer, '恢复后必须给出实际生成的有效业务答案');
    assert.doesNotMatch(f.sent[0].content, /AI|机器人|暂时[^\n]{0,12}(?:无法|不能)[^\n]{0,12}回复|稍后再试/i);
    const generated = f.modelRequests.length;
    assert.equal(generated, 1, '过期恢复只允许一次有界生成，不得用本地 generic 结题或放大请求');
    assert.equal((await f.receive(input)).route, 'ignore');
    assert.equal(f.sent.length, 1); assert.equal(f.modelRequests.length, generated, '重复Hook不得重复生成');
    assert.equal(f.rawState(session).jobs.find(job => job.id === received.jobId).status, 'done'); f.noFeedback();
  });

  await test('F34 空的固定reply不发送 generic，保留原责任并在配置修复后回答一次', async () => {
    const f = makeFixture('empty-keyword-reply'), session = 'session_empty-reply';
    const keywords = f.readConfig('keyword');
    keywords.rules.unshift({ id: 'synthetic-empty-reply', name: '合成空回复', enabled: true, match_mode: 'exact',
      keywords: ['空回复边界'], exclude_keywords: [], priority: 1000, action: 'reply', text: '', cooldown_seconds: 0 });
    f.writeConfig('keyword', keywords); f.publishCurrentMaterials(); f.restart();
    const input = f.event(session, '空回复边界');
    const result = await f.deliver(input);
    assert.equal(result.status, 'unresolved');
    assertUnresolvedResponsibility(f, session, result.jobId, input.data.content);
    assert.equal(f.modelRequests.length, 0); assert.equal(f.state(session).mode, 'ai');
    const repaired = f.readConfig('keyword');
    repaired.rules.find((rule) => rule.id === 'synthetic-empty-reply').text = '已根据有效固定规则回答。';
    f.writeConfig('keyword', repaired);
    f.publishCurrentMaterials();
    await recoverSameJobOnce(f, session, result.jobId, '已根据有效固定规则回答。');
    assert.equal(f.modelRequests.length, 0); f.noFeedback();
  });

  await test('F35 规划异常零可见兜底且不得终态吞消息，恢复后恰好回复一次', async () => {
    const f = makeFixture('planning-recoverable'), session = 'session_planning-recoverable';
    f.modes.historyFailure = true;
    const input = f.event(session, '历史回读暂时异常的普通问题');
    const received = await f.receive(input);
    assert.equal(received.route, 'process');
    assert.equal((await f.runtime().process(f.key(session), received.jobId)).status, 'deferred');
    assertUnresolvedResponsibility(f, session, received.jobId, input.data.content);
    f.modes.historyFailure = false;
    await recoverSameJobOnce(f, session, received.jobId, f.modes.answer);
    assert.equal((await f.receive(input)).route, 'ignore');
    assert.equal(f.sent.filter(message => message.session_id === session).length, 1, '重放不得重复出站'); f.noFeedback();
  });

  await test('F36 出站登记后但POST前配置换代时移除未发登记，新代仍恰好出站一次', async () => {
    const f = makeFixture('registered-before-config-change'), session = 'session_registered-race';
    const input = f.event(session, '旧队列的普通问题');
    const accepted = await f.receive(input);
    assert.equal(accepted.route, 'process');
    const stateFile = path.join(f.root, 'data/runtime/session-' + f.key(session) + '.json');
    const rename = fs.renameSync; let injected = false;
    try {
      fs.renameSync = (from, to) => {
        const result = rename(from, to);
        if (!injected && to === stateFile) {
          const state = JSON.parse(fs.readFileSync(stateFile));
          const stored = state.jobs.find((item) => item.id === accepted.jobId);
          const sending = Object.values(state.outgoing || {})
            .find((record) => record?.job_id === accepted.jobId && record.status === 'sending');
          if (stored?.plan && sending) {
            injected = true;
            f.writeConfig('runtime', { schema_version: 2, enabled: true,
              revision: 2, applied_revision: 2 });
            f.publishCurrentMaterials();
          }
        }
        return result;
      };
      assert.equal((await f.runtime().process(accepted.key, accepted.jobId)).status, 'deferred');
    } finally { fs.renameSync = rename; }
    assert.equal(injected, true, '必须精确触发sending已提交但Crisp POST尚未发生的窗口');
    assert.equal(f.sent.length, 0); assert.equal(f.postAttempts.length, 0);
    assert.equal(f.retrievalRequests.length, 1); assert.equal(f.modelRequests.length, 1);
    let stored = f.rawState(session).jobs.find(item => item.id === accepted.jobId);
    assert.equal(stored.status, 'received'); assert.equal(stored.deferred_configuration, true);
    assert(stored.data, '配置换代后必须保留原始访客问题');
    assert.equal(stored.plan, undefined); assert.equal(stored.inference, undefined);
    assert.equal(Object.values(f.rawState(session).outgoing).filter((record) =>
      record?.job_id === accepted.jobId).length, 0, '尚未POST的旧代登记不得成为永久取消栅栏');

    f.advance(5000); f.restart();
    assert((await f.runtime().scan()).some(item => item.jobId === accepted.jobId));
    assert.equal((await f.runtime().process(f.key(session), accepted.jobId)).status, 'sent');
    assert.equal(f.sent.length, 1); assert.equal(f.sent[0].content, f.modes.answer);
    assert.equal(f.modelRequests.length, 2, '配置换代后必须真实重新规划且只增加一次模型调用');
    assert.equal((await f.runtime().process(f.key(session), accepted.jobId)).status, 'idle');
    assert.equal(f.sent.length, 1, '同一访客问题只能有一个最终出站'); f.noFeedback();
  });

  await test('F37 Crisp已收字节但配置换代无回执时先对账旧指纹，不因规则变化重复回复', async () => {
    const f = makeFixture('post-accepted-config-change'), session = 'session_post-uncertain';
    f.modes.onCrispPost = async ({ signal }) => {
      f.writeConfig('runtime', { schema_version: 2, enabled: true,
        revision: 2, applied_revision: 2 });
      f.publishCurrentMaterials();
      await waitForAbort(signal, 'Crisp 已接收但回执未返回的配置换代');
    };
    f.modes.crispPostThrow = true;
    const first = await f.deliver(f.event(session, '旧队列的普通问题'));
    assert.equal(first.status, 'deferred');
    assert.equal(f.sent.length, 1, '合成远端已接收旧指纹一次');
    assert.equal(f.modelRequests.length, 1);
    let state = f.rawState(session);
    const initialOutgoing = Object.entries(state.outgoing)
      .filter(([, record]) => record?.job_id === first.jobId);
    assert.equal(initialOutgoing.length, 1);
    const [fingerprint, frozenOutgoing] = initialOutgoing[0];
    assert.equal(String(fingerprint), String(f.sent[0].fingerprint));
    assert.equal(frozenOutgoing.status, 'unknown');
    let stored = state.jobs.find(item => item.id === first.jobId);
    assert.equal(stored.status, 'received'); assert.equal(stored.deferred_configuration, true);
    assert.equal(stored.plan.purpose, 'ai_text');
    assert.equal(stored.plan.content, f.modes.answer);

    // 模拟新配置把同一访客文字改成固定回复。旧回执未完成对账前不得使用这个
    // 新 purpose/fingerprint，否则远端会看到两条不同答案。
    const keyword = f.readConfig('keyword');
    keyword.rules.unshift({ id: 'synthetic-new-rule', name: '换代后新规则', enabled: true, match_mode: 'exact',
      keywords: ['旧队列的普通问题'], exclude_keywords: [], priority: 1000, action: 'reply', text: '新代固定回复不得重复发送', cooldown_seconds: 0 });
    f.writeConfig('keyword', keyword);
    f.publishCurrentMaterials();
    f.modes.onCrispPost = null; f.modes.crispPostThrow = false;
    f.advance(5000); f.restart();
    assert((await f.runtime().scan()).some(item => item.jobId === first.jobId));
    const result = await f.runtime().process(f.key(session), first.jobId);
    assert.equal(result.status, 'dispatched_after_cancel');
    stored = f.rawState(session).jobs.find(item => item.id === first.jobId);
    assert.equal(stored.status, 'done'); assert.equal(f.rawState(session).outgoing[String(fingerprint)].status, 'sent');
    assert.equal(f.sent.length, 1, '已在Crisp找到旧指纹后不得发送新规则的第二条正文');
    assert.equal(f.modelRequests.length, 1, '发送对账不能重新调用模型');
    assert.equal((await f.runtime().process(f.key(session), first.jobId)).status, 'idle');
    assert.equal(f.sent.length, 1); f.noFeedback();
  });

  await test('F38 配置换代时旧POST确定未送达，双重负查后按新规则恢复一次且不永久卡住', async () => {
    const f = makeFixture('post-absent-config-change'), session = 'session_post-absent';
    f.modes.crispDropBeforeAccept = true;
    f.modes.onCrispPost = async ({ signal }) => {
      f.writeConfig('runtime', { schema_version: 2, enabled: true,
        revision: 2, applied_revision: 2 });
      f.publishCurrentMaterials();
      await waitForAbort(signal, 'Crisp 未接收前的配置换代');
    };
    const first = await f.deliver(f.event(session, '旧队列的普通问题'));
    assert.equal(first.status, 'deferred');
    assert.equal(f.postAttempts.length, 1); assert.equal(f.sent.length, 0);
    assert.equal(f.modelRequests.length, 1);
    const initialState = f.rawState(session);
    const initial = initialState.jobs.find((item) => item.id === first.jobId);
    const initialOutgoing = Object.entries(initialState.outgoing)
      .filter(([, record]) => record?.job_id === first.jobId);
    assert.equal(initialOutgoing.length, 1);
    const [fingerprint, frozenOutgoing] = initialOutgoing[0];
    assert.equal(String(fingerprint), String(f.postAttempts[0].fingerprint));
    assert.equal(frozenOutgoing.status, 'unknown');
    assert.equal(initial.plan.purpose, 'ai_text');
    assert.equal(initial.plan.content, f.modes.answer);

    const keyword = f.readConfig('keyword');
    keyword.rules.unshift({ id: 'synthetic-new-rule-absent', name: '换代后恢复规则', enabled: true, match_mode: 'exact',
      keywords: ['旧队列的普通问题'], exclude_keywords: [], priority: 1000, action: 'reply', text: '新代确认回复', cooldown_seconds: 0 });
    f.writeConfig('keyword', keyword);
    f.publishCurrentMaterials();
    f.modes.crispDropBeforeAccept = false; f.modes.onCrispPost = null;
    f.modes.exactStatus = 404;
    f.advance(10000); f.restart(); await f.runtime().scan();
    assert.equal((await f.runtime().process(f.key(session), first.jobId)).status, 'retry', '第一次精确负查只登记证据，不立即换正文');
    assert.equal(f.sent.length, 0); assert.equal(f.postAttempts.length, 1);
    f.advance(5000); f.restart(); await f.runtime().scan();
    assert.equal((await f.runtime().process(f.key(session), first.jobId)).status, 'deferred', '第二次间隔负查后才允许按新代重规划');
    assert.equal(f.rawState(session).outgoing[String(fingerprint)], undefined);
    f.advance(5000); f.restart(); await f.runtime().scan();
    assert.equal((await f.runtime().process(f.key(session), first.jobId)).status, 'sent');
    assert.equal(f.sent.length, 1); assert.equal(f.sent[0].content, '新代确认回复');
    assert.equal(f.modelRequests.length, 1, '新代固定回复不得再次调用模型');
    assert.equal(f.postAttempts.length, 2, '旧代一次不确定尝试后只允许一次新代出站');
    assert.equal((await f.runtime().process(f.key(session), first.jobId)).status, 'idle');
    assert.equal(f.sent.length, 1); f.noFeedback();
  });

  await test('F38a 当前直连答案被Crisp真实发送路径明确拒绝后换代，本地后继无旧结算且只规划一次', async () => {
    const f = makeFixture('post-rejected-config-change');
    const session = 'session_post-rejected';
    const question = '明确拒绝后换代的普通问题';
    f.modes.crispPostResponse = { status: 401, headers: {},
      body: { error: true, reason: 'synthetic_rejection' } };
    const first = await f.deliver(f.event(session, question));
    assert.equal(first.status, 'rejected');
    assert.equal(f.postAttempts.length, 1);
    assert.equal(f.sent.length, 0,
      '显式401必须由POST夹具在加入远端历史前返回，不能伪造成远端已接收');
    assert.equal(f.modelRequests.length, 1);
    let stored = f.rawState(session).jobs.find((entry) => entry.id === first.jobId);
    const rejected = Object.values(f.rawState(session).outgoing)
      .find((record) => record?.job_id === first.jobId);
    assert.equal(stored.status, 'received');
    assert.equal(stored.failure_code, 'crisp_http_401');
    assert.equal(rejected.status, 'rejected');
    assert.equal(rejected.failure, 'crisp_http_401');
    assert(stored.plan && stored.inference && stored.provider_settlement,
      '发送明确拒绝后必须保留已生成答案，不能立即重新调用Provider');
    const retryAt = stored.retry_at;
    assert(Number.isSafeInteger(retryAt) && retryAt > f.now());

    const keyword = f.readConfig('keyword');
    keyword.rules.unshift({ id: 'synthetic-rejected-local-successor',
      name: '明确拒绝后的本地后继', enabled: true, match_mode: 'exact',
      keywords: [question], exclude_keywords: [], priority: 1000,
      action: 'reply', text: '受控本地后继答案。', cooldown_seconds: 0 });
    f.writeConfig('keyword', keyword);
    f.writeConfig('runtime', { schema_version: 2, enabled: true,
      revision: 2, applied_revision: 2 });
    f.publishCurrentMaterials();
    f.restart();
    f.advance(retryAt - f.now());
    const deferred = await f.runtime().process(f.key(session), first.jobId);
    assert.equal(deferred.status, 'deferred');
    stored = f.rawState(session).jobs.find((entry) => entry.id === first.jobId);
    assert.equal(stored.status, 'received');
    assert.equal(stored.deferred_configuration, true);
    assert.equal(stored.plan, undefined);
    assert.equal(stored.inference, undefined);
    assert.equal(stored.provider_settlement, undefined,
      '旧直连答案失权时必须同步释放其finished settlement');
    assert.equal(Object.values(f.rawState(session).outgoing)
      .filter((record) => record?.job_id === first.jobId).length, 0,
      '明确未送达的旧正文必须与旧计划原子退休，不能成为后继取消栅栏');
    assert.equal(f.modelRequests.length, 1,
      '配置事务清理旧代时不得再次调用Provider');
    assert.equal(f.postAttempts.length, 1);

    f.advance(5000); f.restart();
    assert((await f.runtime().scan()).some((entry) => entry.jobId === first.jobId));
    const recovered = await f.runtime().process(f.key(session), first.jobId);
    assert.equal(recovered.status, 'sent');
    stored = f.rawState(session).jobs.find((entry) => entry.id === first.jobId);
    assert.equal(stored.status, 'done');
    assert.equal(stored.responsibility_status, 'answered_confirmed');
    assert.equal(f.modelRequests.length, 1,
      '配置换代后的本地规则不得再次调用Provider');
    assert.equal(f.postAttempts.length, 2);
    assert.equal(f.sent.length, 1);
    assert.equal(f.sent[0].content, '受控本地后继答案。');
    assert.equal(stored.provider_settlement, undefined,
      '本地后继完成后不得遗留旧Provider结算摘要');
    assert.equal((await f.runtime().process(f.key(session), first.jobId)).status, 'idle');
    assert.equal(f.sent.length, 1); f.noFeedback();
  });

  await test('F38a2 当前直连答案被Crisp真实429限流后换代，本地后继不重复推理且只发送一次', async () => {
    const f = makeFixture('post-rate-limited-config-change');
    const session = 'session_post-rate-limited';
    const question = '明确限流后换代的普通问题';
    f.modes.crispPostResponse = { status: 429, headers: { 'retry-after': '60' },
      body: { error: true, reason: 'synthetic_rate_limit' } };
    const first = await f.deliver(f.event(session, question));
    assert.equal(first.status, 'rate_limited');
    assert.equal(f.postAttempts.length, 1); assert.equal(f.sent.length, 0);
    assert.equal(f.modelRequests.length, 1);
    let stored = f.rawState(session).jobs.find((entry) => entry.id === first.jobId);
    const limited = Object.values(f.rawState(session).outgoing)
      .find((record) => record?.job_id === first.jobId);
    assert.equal(stored.status, 'received');
    assert.equal(stored.failure_code, 'crisp_rate_limited');
    assert.equal(limited.status, 'rate_limited');
    assert.equal(limited.failure, 'crisp_rate_limited');
    assert.equal(limited.delivery_identity_version, 1);
    assert(/^[a-f0-9]{32}$/.test(limited.attempt_token));
    assert(stored.plan && stored.inference && stored.provider_settlement,
      'Crisp限流后必须保留已生成答案，不能再次调用Provider');
    const retryAt = stored.retry_at;
    assert(Number.isSafeInteger(retryAt) && retryAt >= f.now() + 60000);

    const keyword = f.readConfig('keyword');
    keyword.rules.unshift({ id: 'synthetic-rate-limited-local-successor',
      name: '限流后的本地后继', enabled: true, match_mode: 'exact',
      keywords: [question], exclude_keywords: [], priority: 1000,
      action: 'reply', text: '受控限流后继答案。', cooldown_seconds: 0 });
    f.writeConfig('keyword', keyword);
    f.writeConfig('runtime', { schema_version: 2, enabled: true,
      revision: 2, applied_revision: 2 });
    f.publishCurrentMaterials();
    f.restart(); f.advance(retryAt - f.now());
    const deferred = await f.runtime().process(f.key(session), first.jobId);
    assert.equal(deferred.status, 'deferred');
    stored = f.rawState(session).jobs.find((entry) => entry.id === first.jobId);
    assert.equal(stored.status, 'received');
    assert.equal(stored.deferred_configuration, true);
    assert.equal(stored.plan, undefined); assert.equal(stored.inference, undefined);
    assert.equal(stored.provider_settlement, undefined);
    assert.equal(Object.values(f.rawState(session).outgoing)
      .filter((record) => record?.job_id === first.jobId).length, 0);
    assert.equal(f.modelRequests.length, 1); assert.equal(f.postAttempts.length, 1);

    f.advance(5000); f.restart();
    assert((await f.runtime().scan()).some((entry) => entry.jobId === first.jobId));
    const recovered = await f.runtime().process(f.key(session), first.jobId);
    assert.equal(recovered.status, 'sent');
    stored = f.rawState(session).jobs.find((entry) => entry.id === first.jobId);
    assert.equal(stored.status, 'done');
    assert.equal(stored.responsibility_status, 'answered_confirmed');
    assert.equal(f.modelRequests.length, 1);
    assert.equal(f.postAttempts.length, 2); assert.equal(f.sent.length, 1);
    assert.equal(f.sent[0].content, '受控限流后继答案。');
    assert.equal(stored.provider_settlement, undefined);
    assert.equal((await f.runtime().process(f.key(session), first.jobId)).status, 'idle');
    assert.equal(f.sent.length, 1); f.noFeedback();
  });

  await test('F38b 当前直连sent语义未知在配置换代时冻结原回执，不得按未送达重新规划', async () => {
    const f = makeFixture('sent-semantic-unknown-config-change');
    const session = 'session_sent-semantic-unknown';
    const plan = { type: 'text', purpose: 'ai_text', ordinary: true, ai: true,
      content: '已经交给Crisp但语义仍待核查的答案', fingerprint: 77121 };
    const job = f.currentUnpooled(f.makeJob(session, 'sent-semantic-unknown', plan,
      { responsibility_status: 'unresolved_failure',
        failure_code: 'delivery_semantic_unknown' }));
    const planSha256 = digest(canonical({ type: plan.type, purpose: plan.purpose,
      content: plan.content, outcome: '', sources: [], tags: [] }));
    const contentSha256 = digest(canonical({ type: plan.type, content: plan.content }));
    job.provider_settlement = { schema_version: 1, state: 'settled',
      plan_sha256: planSha256, response_generation: 0, attempts: 1,
      settled_at: f.now() };
    const sent = { ...f.makeOutgoing(job, plan.content, 'sent'),
      response_generation: 0, delivery_identity_version: 1,
      purpose: plan.purpose, message_type: plan.type, semantic_intent: 'answer',
      semantic_status: 'semantic_unknown', content_sha256: contentSha256,
      sent_at: f.now(), receipt_confirmed_at: f.now(), receipt_current: null,
      resend_forbidden: true };
    delete sent.body;
    await f.seed(session, (state) => {
      state.jobs.push(job);
      state.outgoing[String(plan.fingerprint)] = sent;
    });
    f.writeConfig('runtime', { schema_version: 2, enabled: true,
      revision: 2, applied_revision: 2 });
    f.publishCurrentMaterials();
    f.restart();

    const result = await f.runtime().process(f.key(session), job.id);
    assert.equal(result.status, 'delivery_semantic_unknown');
    const state = f.rawState(session);
    const stored = state.jobs.find((entry) => entry.id === job.id);
    assert.equal(stored.deferred_configuration, undefined);
    assert.equal(stored.responsibility_status, 'unresolved_failure');
    assert.equal(stored.failure_code, 'delivery_semantic_unknown');
    assert.equal(state.outgoing[String(plan.fingerprint)].status, 'sent');
    assert.equal(state.outgoing[String(plan.fingerprint)].content_sha256, contentSha256);
    assert.equal(f.retrievalRequests.length, 0); assert.equal(f.modelRequests.length, 0);
    assert.equal(f.postAttempts.length, 0); assert.equal(f.sent.length, 0);
  });

  await test('F38c 配置事务遇到结算或出站身份冲突时原样保留证据且绝不重规划', async () => {
    const cases = [
      { name: 'settlement-sha', mutate: ({ job }) => { job.provider_settlement.plan_sha256 = 'f'.repeat(64); } },
      { name: 'settlement-generation', mutate: ({ job }) => { job.provider_settlement.response_generation = 1; } },
      { name: 'settlement-failure-code', mutate: ({ job }) => { job.provider_settlement_failure_code = 'synthetic_conflict'; } },
      { name: 'sent-missing-job', mutate: ({ sent }) => { delete sent.job_id; } },
      { name: 'sent-wrong-job', mutate: ({ sent }) => { sent.job_id = '0'.repeat(64); } },
      { name: 'sent-wrong-origin', mutate: ({ sent }) => { sent.body.origin = 'email'; } },
      { name: 'sent-wrong-fingerprint', mutate: ({ sent }) => { sent.body.fingerprint += 1; } },
      { name: 'deferred-missing-version', outgoingStatus: 'rejected',
        mutate: ({ sent }) => { delete sent.delivery_identity_version; } },
      { name: 'deferred-bad-token', outgoingStatus: 'rate_limited',
        mutate: ({ sent }) => { sent.attempt_token = 'invalid-attempt-token'; } },
      { name: 'multiple-sent', mutate: ({ extra, sent, job }) => {
        const duplicate = structuredClone(sent);
        duplicate.body.fingerprint += 1;
        extra[String(duplicate.body.fingerprint)] = { ...duplicate, job_id: job.id };
      } },
    ];
    for (const item of cases) {
      const f = makeFixture('config-invalid-' + item.name);
      const session = 'session_config-invalid-' + item.name;
      const fingerprint = 77130 + cases.indexOf(item) * 10;
      const plan = { type: 'text', purpose: 'ai_text', ordinary: true, ai: true,
        content: '冲突身份下不得跨配置发送第二答案', fingerprint };
      const job = f.currentUnpooled(f.makeJob(session, item.name, plan));
      job.provider_settlement = { schema_version: 1, state: 'settled',
        plan_sha256: digest(canonical({ type: plan.type, purpose: plan.purpose,
          content: plan.content, outcome: '', sources: [], tags: [] })),
        response_generation: 0, attempts: 1, settled_at: f.now() };
      const outgoingStatus = item.outgoingStatus || 'sent';
      const sent = { ...f.makeOutgoing(job, plan.content, outgoingStatus),
        response_generation: 0, delivery_identity_version: 1,
        purpose: plan.purpose, message_type: plan.type, semantic_intent: 'answer',
        semantic_status: 'semantic_unknown',
        content_sha256: digest(canonical({ type: plan.type, content: plan.content })),
        sent_at: f.now(), receipt_confirmed_at: f.now(), receipt_current: null,
        ...(item.outgoingStatus ? {
          recovery_deferred: true, next_action_at: f.now() + 300000,
          failure: item.outgoingStatus === 'rate_limited'
            ? 'crisp_rate_limited' : 'crisp_http_401',
        } : { resend_forbidden: true }) };
      const extra = {};
      item.mutate({ job, sent, extra });
      const outgoingCases = item.name.startsWith('sent-') || item.name === 'multiple-sent'
        || item.outgoingStatus
        ? { [String(fingerprint)]: sent, ...extra } : {};
      const originalPlan = structuredClone(job.plan);
      const originalInference = structuredClone(job.inference);
      const originalSettlement = structuredClone(job.provider_settlement);
      const originalFailure = job.provider_settlement_failure_code;
      const originalOutgoing = structuredClone(outgoingCases);
      await f.seed(session, (state) => {
        state.jobs.push(job); Object.assign(state.outgoing, outgoingCases);
      });
      const marker = path.join(f.root, 'config/provider-pool-transaction.json');
      fs.writeFileSync(marker, JSON.stringify({ phase: 'applying' }), { mode: 0o600 });
      f.restart();
      assert.equal((await f.runtime().process(f.key(session), job.id)).status, 'idle');
      let state = f.rawState(session);
      let stored = state.jobs.find((entry) => entry.id === job.id);
      assert.deepEqual(stored.plan, originalPlan, item.name + ':plan');
      assert.deepEqual(stored.inference, originalInference, item.name + ':inference');
      assert.deepEqual(stored.provider_settlement, originalSettlement, item.name + ':settlement');
      assert.equal(stored.provider_settlement_failure_code, originalFailure, item.name + ':failure');
      assert.deepEqual(state.outgoing, originalOutgoing, item.name + ':outgoing');
      assert.equal(stored.responsibility_status, 'unresolved_failure');
      assert.equal(stored.failure_code, 'delivery_identity_unresolved');
      assert.equal(stored.deferred_configuration, true);
      assert(stored.data, item.name + ':原始访客责任必须保留');
      fs.unlinkSync(marker);
      f.advance(stored.retry_at - f.now()); f.restart();
      assert.equal((await f.runtime().process(f.key(session), job.id)).status, 'idle');
      state = f.rawState(session); stored = state.jobs.find((entry) => entry.id === job.id);
      assert.deepEqual(stored.plan, originalPlan, item.name + ':released-plan');
      assert.deepEqual(stored.inference, originalInference, item.name + ':released-inference');
      assert.deepEqual(stored.provider_settlement, originalSettlement, item.name + ':released-settlement');
      assert.equal(stored.provider_settlement_failure_code, originalFailure,
        item.name + ':released-failure');
      assert.deepEqual(state.outgoing, originalOutgoing, item.name + ':released-outgoing');
      assert.equal(stored.failure_code, 'delivery_identity_unresolved');
      assert(stored.retry_at > f.now());
      assert.equal(f.retrievalRequests.length, 0); assert.equal(f.modelRequests.length, 0);
      assert.equal(f.postAttempts.length, 0); assert.equal(f.sent.length, 0);
    }
  });

  await test('F38d 只有严格终结的旧出站可退出当前回答代唯一性，其余混代记录继续关闭', async () => {
    const cases = [
      { name: 'sent-current-generation', mutate: ({ record }) => { record.response_generation = 1; } },
      { name: 'sent-missing-response-generation', mutate: ({ record }) => {
        delete record.response_generation;
      } },
      { name: 'sent-future-generation', mutate: ({ record }) => { record.response_generation = 2; } },
      { name: 'sent-valid-answer', mutate: ({ record }) => {
        record.semantic_intent = 'answer'; record.semantic_status = 'valid_answer';
        record.content_sha256 = digest(canonical({ type: 'text', content: '历史有效业务答案。' }));
      } },
      { name: 'sent-unverified-nonanswer-digest', mutate: ({ record }) => {
        record.content_sha256 = digest(canonical({ type: 'text',
          content: '不是项目发布过的空泛话术。' }));
      } },
      { name: 'sent-semantic-unknown', mutate: ({ record }) => {
        record.semantic_intent = 'unknown'; record.semantic_status = 'semantic_unknown';
        record.content_sha256 = digest(canonical({ type: 'text', content: '历史身份未知正文。' }));
      } },
      { name: 'sent-unbound', mutate: ({ record }) => { record.receipt_identity_unbound = true; } },
      { name: 'sent-malformed-unbound', mutate: ({ record }) => {
        record.receipt_identity_unbound = 'false';
      } },
      { name: 'sent-malformed-state-change', mutate: ({ record }) => {
        record.state_changed_before_receipt = 'false';
      } },
      { name: 'sent-malformed-delivery-uncertain', mutate: ({ record }) => {
        record.delivery_uncertain = 'false';
      } },
      { name: 'sent-malformed-recovery-deferred', mutate: ({ record }) => {
        record.recovery_deferred = 'false';
      } },
      { name: 'sent-malformed-resend-forbidden', mutate: ({ record }) => {
        record.resend_forbidden = 'false';
      } },
      { name: 'sent-receipt-null', mutate: ({ record }) => { record.receipt_current = null; } },
      { name: 'sent-receipt-operator-pending', mutate: ({ record }) => {
        record.receipt_current = null;
        record.receipt_state_change_reason = 'operator_identity_pending';
      } },
      { name: 'sent-missing-token', mutate: ({ record }) => { delete record.attempt_token; } },
      { name: 'sent-bad-digest', mutate: ({ record }) => { record.content_sha256 = 'f'.repeat(63); } },
      { name: 'sent-bad-migration-marker', mutate: ({ record }) => {
        record.legacy_delivery_identity_migrated_at = 'invalid';
      } },
      { name: 'sent-bad-sent-time', mutate: ({ record }) => { record.sent_at = 'invalid'; } },
      { name: 'sent-bad-receipt-time', mutate: ({ record }) => {
        record.receipt_confirmed_at = 'invalid';
      } },
      { name: 'sent-bad-semantic-time', mutate: ({ record }) => {
        record.semantic_reported_at = 'invalid';
      } },
      { name: 'cancelled-unapproved', cancelled: true,
        mutate: ({ record }) => { record.cancellation_reason = 'conversation_state_changed'; } },
      { name: 'cancelled-uncertain', cancelled: true,
        mutate: ({ record }) => { record.delivery_uncertain = true; } },
      { name: 'cancelled-malformed-uncertain', cancelled: true,
        mutate: ({ record }) => { record.delivery_uncertain = 'false'; } },
      { name: 'cancelled-malformed-state-change', cancelled: true,
        mutate: ({ record }) => { record.state_changed_before_receipt = 'false'; } },
      { name: 'cancelled-current-fingerprint', cancelled: true, currentFingerprint: true,
        mutate: () => {} },
      { name: 'cancelled-current-generation-different-fingerprint', cancelled: true,
        mutate: ({ record }) => { record.response_generation = 1; } },
      { name: 'cancelled-bad-migration-marker', cancelled: true,
        mutate: ({ record }) => { record.legacy_delivery_identity_migrated_at = -1; } },
      { name: 'answer-evidence-missing-version', cancelled: true, answerEvidence: true,
        mutate: ({ record }) => { delete record.delivery_identity_version; } },
      { name: 'answer-evidence-wrong-purpose', cancelled: true, answerEvidence: true,
        mutate: ({ record }) => { record.purpose = 'keyword_reply'; } },
      { name: 'answer-evidence-wrong-semantic', cancelled: true, answerEvidence: true,
        mutate: ({ record }) => { record.semantic_intent = 'non_answer'; } },
      { name: 'answer-evidence-bad-digest', cancelled: true, answerEvidence: true,
        mutate: ({ record }) => { record.content_sha256 = 'a'.repeat(63); } },
      { name: 'answer-evidence-missing-resend-fence', cancelled: true, answerEvidence: true,
        mutate: ({ record }) => { delete record.resend_forbidden; } },
      { name: 'answer-evidence-recovery-still-pending', cancelled: true, answerEvidence: true,
        mutate: ({ record }) => { record.recovery_deferred = true; } },
      { name: 'answer-evidence-next-action-present', cancelled: true, answerEvidence: true,
        mutate: ({ record }) => { record.next_action_at = 0; } },
      { name: 'answer-evidence-unsupported-failure', cancelled: true, answerEvidence: true,
        mutate: ({ record }) => { record.failure = 'synthetic_unknown'; } },
      { name: 'answer-evidence-has-body', cancelled: true, answerEvidence: true,
        mutate: ({ record }) => { record.body = { type: 'text', content: '不得忽略的旧正文' }; } },
      { name: 'answer-evidence-has-sent-time', cancelled: true, answerEvidence: true,
        mutate: ({ record }) => { record.sent_at = record.cancelled_at; } },
    ];
    for (const item of cases) {
      const f = makeFixture('retired-prior-negative-' + item.name);
      const session = 'session_retired-prior-negative-' + item.name;
      const plan = { type: 'text', purpose: 'ai_text', ordinary: true, ai: true,
        content: '当前回答代必须保留唯一出站身份。', fingerprint: 77180 };
      const job = f.currentUnpooled(f.makeJob(session, item.name, plan,
        { response_generation: 1 }));
      job.provider_settlement = { schema_version: 1, state: 'settled',
        plan_sha256: digest(canonical({ type: plan.type, purpose: plan.purpose,
          content: plan.content, outcome: '', sources: [], tags: [] })),
        response_generation: 1, attempts: 1, settled_at: f.now() };
      const record = item.answerEvidence ? {
        status: 'cancelled', created_at: f.now() - 15000, cancelled_at: f.now() - 10000,
        attempts: 1, attempt_token: digest('attempt|' + job.id).slice(0, 32),
        job_id: job.id, generation: job.generation, response_generation: 0,
        cancellation_reason: 'answer_evidence_unavailable', delivery_identity_version: 1,
        purpose: 'ai_text', message_type: 'text', semantic_intent: 'answer',
        content_sha256: digest(canonical({ type: 'text', content: '已退役的旧代答案。' })),
        failure: 'crisp_http_401', resend_forbidden: true,
        recovery_deferred: false, next_action_at: null,
      } : item.cancelled ? {
        status: 'cancelled', created_at: f.now() - 15000, cancelled_at: f.now() - 10000,
        attempts: 1, attempt_token: digest('attempt|' + job.id).slice(0, 32),
        job_id: job.id, generation: job.generation, response_generation: 0,
        cancellation_reason: 'visitor_output_normalized',
      } : {
        status: 'sent', created_at: f.now() - 15000, sent_at: f.now() - 10000,
        receipt_confirmed_at: f.now() - 9000, semantic_reported_at: f.now() - 8000,
        attempts: 1, attempt_token: digest('attempt|' + job.id).slice(0, 32),
        job_id: job.id, generation: job.generation, response_generation: 0,
        delivery_identity_version: 1, purpose: 'ai_text', message_type: 'text',
        semantic_intent: 'non_answer', semantic_status: 'delivered_non_answer',
        content_sha256: digest(canonical({ type: 'text', content: clarification })),
        receipt_current: true,
      };
      item.mutate({ record, job });
      const originalRecord = structuredClone(record);
      const fingerprint = item.currentFingerprint ? String(plan.fingerprint) : '77179';
      await f.seed(session, (state) => {
        state.jobs.push(job); state.outgoing[fingerprint] = record;
      });
      f.restart();
      assert.equal((await f.runtime().process(f.key(session), job.id)).status,
        'delivery_identity_unresolved', item.name);
      const stored = f.rawState(session);
      const retained = stored.jobs.find((entry) => entry.id === job.id);
      assert.equal(retained.status, 'received', item.name);
      assert.equal(retained.responsibility_status, 'unresolved_failure', item.name);
      assert.equal(retained.failure_code, 'delivery_identity_unresolved', item.name);
      assert(retained.retry_at > f.now(), item.name);
      assert.deepEqual(stored.outgoing[fingerprint], originalRecord,
        item.name + ':身份门禁必须保留旧证据且不得改写为可重发状态');
      assert.equal(f.modelRequests.length, 0, item.name);
      assert.equal(f.postAttempts.length, 0, item.name);
    }

    const evidenceRetired = makeFixture('retired-prior-answer-evidence');
    const evidenceSession = 'session_retired-prior-answer-evidence';
    const evidencePlan = { type: 'text', purpose: 'ai_text', ordinary: true, ai: true,
      content: '当前回答代的有效业务答案。', fingerprint: 77184 };
    const evidenceJob = evidenceRetired.currentUnpooled(evidenceRetired.makeJob(
      evidenceSession, 'strict-prior-answer-evidence', evidencePlan,
      { response_generation: 1 }));
    evidenceJob.provider_settlement = { schema_version: 1, state: 'settled',
      plan_sha256: digest(canonical({ type: evidencePlan.type, purpose: evidencePlan.purpose,
        content: evidencePlan.content, outcome: '', sources: [], tags: [] })),
      response_generation: 1, attempts: 1, settled_at: evidenceRetired.now() };
    const evidenceFingerprint = '77183';
    const evidenceRecord = {
      status: 'cancelled', created_at: evidenceRetired.now() - 15000,
      cancelled_at: evidenceRetired.now() - 10000, attempts: 1,
      attempt_token: digest('attempt|' + evidenceJob.id).slice(0, 32),
      job_id: evidenceJob.id, generation: evidenceJob.generation, response_generation: 0,
      cancellation_reason: 'answer_evidence_unavailable', delivery_identity_version: 1,
      purpose: 'ai_text', message_type: 'text', semantic_intent: 'answer',
      content_sha256: digest(canonical({ type: 'text', content: '已退役的旧代答案。' })),
      failure: 'crisp_http_401', resend_forbidden: true,
      recovery_deferred: false, next_action_at: null,
    };
    const evidenceBefore = structuredClone(evidenceRecord);
    await evidenceRetired.seed(evidenceSession, (state) => {
      state.jobs.push(evidenceJob); state.outgoing[evidenceFingerprint] = evidenceRecord;
    });
    evidenceRetired.restart();
    assert.equal((await evidenceRetired.runtime().process(
      evidenceRetired.key(evidenceSession), evidenceJob.id)).status, 'sent');
    const evidenceState = evidenceRetired.rawState(evidenceSession);
    assert.deepEqual(evidenceState.outgoing[evidenceFingerprint], evidenceBefore,
      '严格退役的旧回答代审计必须逐字保留');
    assert.equal(evidenceState.outgoing[String(evidencePlan.fingerprint)].status, 'sent');
    assert.equal(evidenceRetired.postAttempts.length, 1);
    assert.equal(evidenceRetired.sent.length, 1);
    assert.equal(evidenceRetired.modelRequests.length, 0);
    assert.equal(evidenceRetired.retrievalRequests.length, 0);

    const unpooledConflict = makeFixture('unpooled-settlement-null-conflict');
    const unpooledSession = 'session_unpooled-settlement-null-conflict';
    const unpooledPlan = { type: 'text', purpose: 'ai_text', ordinary: true, ai: true,
      content: '损坏结算字段不得被直连接口覆盖。', fingerprint: 77186 };
    const unpooledJob = unpooledConflict.currentUnpooled(unpooledConflict.makeJob(
      unpooledSession, 'unpooled-settlement-null-conflict', unpooledPlan));
    unpooledJob.provider_settlement = null;
    const unpooledBefore = structuredClone(unpooledJob);
    await unpooledConflict.seed(unpooledSession, (state) => state.jobs.push(unpooledJob));
    unpooledConflict.restart();
    assert.equal((await unpooledConflict.runtime().process(
      unpooledConflict.key(unpooledSession), unpooledJob.id)).status, 'idle');
    const unpooledStored = unpooledConflict.rawState(unpooledSession).jobs
      .find((entry) => entry.id === unpooledJob.id);
    assert.deepEqual(unpooledStored, unpooledBefore,
      'unpooled的falsy settlement字段必须逐字保留并阻止普通计划持久化');
    assert.equal(unpooledConflict.modelRequests.length, 0);
    assert.equal(unpooledConflict.retrievalRequests.length, 0);
    assert.equal(unpooledConflict.postAttempts.length, 0);
    assert.equal(unpooledConflict.sent.length, 0);

    for (const [index, field] of ['provider_result_receipt',
      'provider_migration_from', 'legacy_v121_pending_origin'].entries()) {
      const conflict = makeFixture('unpooled-finished-conflict-' + field);
      const session = 'session_unpooled-finished-conflict-' + field.replace(/_/g, '-');
      const plan = { type: 'text', purpose: 'ai_text', ordinary: true, ai: true,
        content: '直连接口完成结算不得绕过冲突字段。', fingerprint: 77190 + index };
      const job = conflict.currentUnpooled(conflict.makeJob(
        session, 'unpooled-finished-conflict-' + field, plan));
      job.provider_settlement = { schema_version: 1, state: 'settled',
        plan_sha256: digest(canonical({ type: plan.type, purpose: plan.purpose,
          content: plan.content, outcome: '', sources: [], tags: [] })),
        response_generation: 0, attempts: 1, settled_at: conflict.now() };
      job[field] = null;
      const frozenSettlement = structuredClone(job.provider_settlement);
      await conflict.seed(session, (state) => state.jobs.push(job));
      conflict.restart();
      const result = await conflict.runtime().process(conflict.key(session), job.id);
      assert.equal(result.status, 'deferred', field);
      const stored = conflict.rawState(session).jobs.find((entry) => entry.id === job.id);
      assert.deepEqual(stored.provider_settlement, frozenSettlement,
        field + ':finished settlement不得被冲突字段重入覆盖');
      assert.equal(Object.hasOwn(stored, field), true, field);
      assert.equal(stored[field], null, field + ':falsy冲突字段必须逐字保留');
      assert.equal(stored.responsibility_status, 'unresolved_failure', field);
      assert.equal(stored.failure_code, 'persisted_plan_delivery_pending', field);
      assert.equal(conflict.modelRequests.length, 0, field);
      assert.equal(conflict.retrievalRequests.length, 0, field);
      assert.equal(conflict.postAttempts.length, 0, field);
      assert.equal(conflict.sent.length, 0, field);
    }

    const retired = makeFixture('retired-prior-strict-nonanswer');
    const retiredSession = 'session_retired-prior-strict-nonanswer';
    const retiredPlan = { type: 'text', purpose: 'ai_text', ordinary: true, ai: true,
      content: '当前回答代的业务答案。', fingerprint: 77182 };
    const retiredJob = retired.currentUnpooled(retired.makeJob(retiredSession,
      'strict-prior-nonanswer', retiredPlan, { response_generation: 1 }));
    retiredJob.provider_settlement = { schema_version: 1, state: 'settled',
      plan_sha256: digest(canonical({ type: retiredPlan.type, purpose: retiredPlan.purpose,
        content: retiredPlan.content, outcome: '', sources: [], tags: [] })),
      response_generation: 1, attempts: 1, settled_at: retired.now() };
    const priorFingerprint = '77181';
    const priorRecord = {
      status: 'sent', created_at: retired.now() - 15000,
      sent_at: retired.now() - 10000, receipt_confirmed_at: retired.now() - 9000,
      semantic_reported_at: retired.now() - 8000, attempts: 1,
      attempt_token: digest('attempt|' + retiredJob.id).slice(0, 32),
      job_id: retiredJob.id, generation: retiredJob.generation, response_generation: 0,
      delivery_identity_version: 1, purpose: 'ai_text', message_type: 'text',
      semantic_intent: 'non_answer', semantic_status: 'delivered_non_answer',
      content_sha256: digest(canonical({ type: 'text', content: clarification })),
      receipt_current: true,
    };
    const priorBefore = structuredClone(priorRecord);
    await retired.seed(retiredSession, (state) => {
      state.jobs.push(retiredJob); state.outgoing[priorFingerprint] = priorRecord;
    });
    retired.restart();
    assert.equal((await retired.runtime().process(
      retired.key(retiredSession), retiredJob.id)).status, 'sent');
    const retiredState = retired.rawState(retiredSession);
    const completed = retiredState.jobs.find((entry) => entry.id === retiredJob.id);
    assert.equal(completed.status, 'done');
    assert.equal(completed.responsibility_status, 'answered_confirmed');
    assert.deepEqual(retiredState.outgoing[priorFingerprint], priorBefore,
      '严格终结的旧代non-answer审计必须逐字保留');
    assert.equal(retiredState.outgoing[String(retiredPlan.fingerprint)].status, 'sent');
    assert.equal(retired.postAttempts.length, 1);
    assert.equal(retired.sent.length, 1);
    assert.equal(retired.modelRequests.length, 0);
    assert.equal(retired.retrievalRequests.length, 0);
    retired.restart();
    assert.equal((await retired.runtime().process(
      retired.key(retiredSession), retiredJob.id)).status, 'idle');
    assert.equal(retired.postAttempts.length, 1);
    assert.equal(retired.sent.length, 1);
  });

  await test('F38e bodyless legacy non-answer 的畸形可选字段不能被迁移洗白', async () => {
    const cases = [
      { name: 'migration-marker', field: 'legacy_delivery_identity_migrated_at', value: 'invalid' },
      { name: 'sent-time', field: 'sent_at', value: 'invalid' },
      { name: 'receipt-time', field: 'receipt_confirmed_at', value: 'invalid' },
      { name: 'semantic-time', field: 'semantic_reported_at', value: 'invalid' },
      { name: 'receipt-current', field: 'receipt_current', value: 'invalid' },
      { name: 'receipt-reason', field: 'receipt_state_change_reason', value: 'invalid' },
      { name: 'receipt-identity-type', field: 'receipt_identity_unbound', value: 'false' },
      { name: 'state-change-type', field: 'state_changed_before_receipt', value: 'false' },
      { name: 'delivery-uncertain-type', field: 'delivery_uncertain', value: 'false' },
      { name: 'recovery-deferred-type', field: 'recovery_deferred', value: 'false' },
      { name: 'resend-forbidden-type', field: 'resend_forbidden', value: 'false' },
      { name: 'semantic-conflict', mutate: ({ record }) => {
        record.semantic_intent = 'answer'; record.semantic_status = 'control_delivered';
      } },
      { name: 'operator-pending-receipt', mutate: ({ record }) => {
        record.receipt_current = null;
        record.receipt_state_change_reason = 'operator_identity_pending';
      } },
      { name: 'mutable-plan-mismatch', mutate: ({ job }) => {
        job.plan.content = '当前可变计划不是已发送正文。';
      } },
    ];
    for (const item of cases) {
      const f = makeFixture('legacy-nonanswer-malformed-' + item.name);
      const session = 'session_legacy-nonanswer-malformed-' + item.name;
      const plan = { type: 'text', purpose: 'ai_text', ordinary: true, ai: true,
        content: clarification, fingerprint: 77190 };
      const job = f.legacyUnpooled(f.makeJob(session, item.name, plan));
      const record = f.makeOutgoing(job, plan.content, 'sent');
      Object.assign(record, { purpose: plan.purpose, message_type: plan.type,
        semantic_intent: 'non_answer', semantic_status: 'delivered_non_answer',
        response_generation: 0,
        content_sha256: digest(canonical({ type: plan.type, content: plan.content })),
        sent_at: f.now() - 10000,
        receipt_confirmed_at: f.now() - 9000, semantic_reported_at: f.now() - 8000,
        receipt_current: true });
      delete record.body;
      if (item.mutate) item.mutate({ record, job });
      else record[item.field] = item.value;
      const originalRecord = structuredClone(record);
      await f.seed(session, (state) => {
        state.jobs.push(job); state.outgoing[String(plan.fingerprint)] = record;
      });
      f.restart();
      assert.equal((await f.runtime().process(f.key(session), job.id)).status,
        'idle', item.name + ':迁移前置门已登记长退避时不得再次领取同一任务');
      const stored = f.rawState(session);
      const retained = stored.jobs.find((entry) => entry.id === job.id);
      assert.deepEqual(stored.outgoing[String(plan.fingerprint)], originalRecord,
        item.name + ':畸形字段及完整旧证据必须原样保留，不能被当前值洗白');
      assert.equal(stored.outgoing[String(plan.fingerprint)].delivery_identity_version,
        undefined, item.name);
      assert.equal(retained.responsibility_status, 'unresolved_failure', item.name);
      assert.equal(retained.failure_code, 'delivery_identity_unresolved', item.name);
      assert(retained.retry_at > f.now(), item.name);
      assert(retained.data, item.name + ':原始访客责任必须保留');
      assert.equal(f.retrievalRequests.length, 0, item.name);
      assert.equal(f.modelRequests.length, 0, item.name);
      assert.equal(f.postAttempts.length, 0, item.name);
      assert.equal(f.sent.length, 0, item.name);
    }

    const ordinary = makeFixture('legacy-nonanswer-claim-on-valid-wire');
    const ordinarySession = 'session_legacy-nonanswer-claim-on-valid-wire';
    const ordinaryPlan = { type: 'text', purpose: 'ai_text', ordinary: true, ai: true,
      content: '这是一条有具体事实的正常合成业务答案。', fingerprint: 77194 };
    const ordinaryJob = ordinary.legacyUnpooled(ordinary.makeJob(ordinarySession,
      'legacy-nonanswer-claim-on-valid-wire', ordinaryPlan));
    const ordinaryRecord = ordinary.makeOutgoing(ordinaryJob, ordinaryPlan.content, 'sent');
    Object.assign(ordinaryRecord, { purpose: ordinaryPlan.purpose,
      message_type: ordinaryPlan.type, semantic_intent: 'non_answer',
      semantic_status: 'delivered_non_answer', response_generation: 0,
      content_sha256: digest(canonical({ type: ordinaryPlan.type,
        content: ordinaryPlan.content })),
      sent_at: ordinary.now() - 10000, receipt_confirmed_at: ordinary.now() - 9000,
      semantic_reported_at: ordinary.now() - 8000, receipt_current: true });
    delete ordinaryRecord.body;
    const ordinaryBefore = structuredClone(ordinaryRecord);
    await ordinary.seed(ordinarySession, (state) => {
      state.jobs.push(ordinaryJob);
      state.outgoing[String(ordinaryPlan.fingerprint)] = ordinaryRecord;
    });
    ordinary.restart();
    assert.equal((await ordinary.runtime().process(
      ordinary.key(ordinarySession), ordinaryJob.id)).status,
    'idle', 'legacy-unpooled迁移前置门登记长退避后不得领取冲突任务');
    const ordinaryStored = ordinary.rawState(ordinarySession);
    assert.deepEqual(ordinaryStored.outgoing[String(ordinaryPlan.fingerprint)], ordinaryBefore,
      '仅有冲突non-answer字段不能改写普通有效wire');
    const ordinaryRetained = ordinaryStored.jobs.find((entry) => entry.id === ordinaryJob.id);
    assert.equal(ordinaryRetained.status, 'received');
    assert.equal(ordinaryRetained.responsibility_status, 'unresolved_failure');
    assert.equal(ordinaryRetained.failure_code, 'delivery_identity_unresolved');
    assert(ordinaryRetained.retry_at > ordinary.now());
    assert(ordinaryRetained.data); assert(ordinaryRetained.plan); assert(ordinaryRetained.inference);
    assert.equal(ordinary.retrievalRequests.length, 0);
    assert.equal(ordinary.modelRequests.length, 0);
    assert.equal(ordinary.postAttempts.length, 0); assert.equal(ordinary.sent.length, 0);
  });

  await test('F38f legacy sent compatibility 缺失身份或语义冲突时原样关闭', async () => {
    const cases = [
      { name: 'missing-purpose', mutate: (record) => { delete record.purpose; } },
      { name: 'missing-message-type', mutate: (record) => { delete record.message_type; } },
      { name: 'missing-semantic-intent', mutate: (record) => { delete record.semantic_intent; } },
      { name: 'missing-semantic-status', mutate: (record) => { delete record.semantic_status; } },
      { name: 'answer-as-nonanswer', mutate: (record) => {
        record.semantic_status = 'delivered_non_answer';
      } },
      { name: 'answer-as-control', mutate: (record) => {
        record.semantic_status = 'control_delivered';
      } },
      { name: 'answer-as-unknown', mutate: (record) => {
        record.semantic_status = 'semantic_unknown';
      } },
      { name: 'control-intent-on-answer', mutate: (record) => {
        record.semantic_intent = 'control'; record.semantic_status = 'control_delivered';
      } },
    ];
    for (const item of cases) {
      const f = makeFixture('legacy-sent-compatibility-' + item.name);
      const session = 'session_legacy-sent-compatibility-' + item.name;
      const plan = { type: 'text', purpose: 'ai_text', ordinary: true, ai: true,
        content: '当前计划是一条有实际内容的业务答案。', fingerprint: 77195 };
      const job = f.legacyUnpooled(f.makeJob(session, item.name, plan));
      const record = f.makeOutgoing(job, plan.content, 'sent');
      Object.assign(record, {
        delivery_identity_version: 1,
        legacy_delivery_identity_migrated_at: f.now() - 7000,
        purpose: plan.purpose, message_type: plan.type,
        semantic_intent: 'answer', semantic_status: 'valid_answer',
        response_generation: 0,
        content_sha256: digest(canonical({ type: plan.type, content: plan.content })),
        sent_at: f.now() - 10000, receipt_confirmed_at: f.now() - 9000,
        receipt_current: true,
      });
      delete record.body;
      item.mutate(record);
      const originalRecord = structuredClone(record);
      await f.seed(session, (state) => {
        state.jobs.push(job); state.outgoing[String(plan.fingerprint)] = record;
      });
      f.restart();
      assert.equal((await f.runtime().process(f.key(session), job.id)).status,
        'idle', item.name + ':迁移前置门已登记长退避时不得再次领取同一任务');
      const stored = f.rawState(session);
      const retained = stored.jobs.find((entry) => entry.id === job.id);
      assert.deepEqual(stored.outgoing[String(plan.fingerprint)], originalRecord,
        item.name + ':既有 sent 证据不能由当前 plan 补字段或改语义');
      assert.equal(retained.responsibility_status, 'unresolved_failure', item.name);
      assert.equal(retained.failure_code, 'delivery_identity_unresolved', item.name);
      assert(retained.retry_at > f.now(), item.name);
      assert(retained.data, item.name + ':原始访客责任必须保留');
      assert.equal(f.retrievalRequests.length, 0, item.name);
      assert.equal(f.modelRequests.length, 0, item.name);
      assert.equal(f.postAttempts.length, 0, item.name);
      assert.equal(f.sent.length, 0, item.name);
    }

  });

  await test('F38g 所有本地与现代Provider sent concrete语义统一经过严格身份门', async () => {
    const cases = [
      { name: 'local-answer-as-control', local: true,
        mutate: (record) => { record.semantic_status = 'control_delivered'; } },
      { name: 'local-missing-receipt-time', local: true,
        mutate: (record) => { delete record.receipt_confirmed_at; } },
      { name: 'local-malformed-state-change', local: true,
        mutate: (record) => { record.state_changed_before_receipt = 'false'; } },
      { name: 'modern-answer-as-nonanswer',
        mutate: (record) => { record.semantic_status = 'delivered_non_answer'; } },
      { name: 'modern-answer-as-control',
        mutate: (record) => { record.semantic_status = 'control_delivered'; } },
      { name: 'modern-retained-body',
        mutate: (record, body) => { record.body = body; } },
      { name: 'modern-null-applicability',
        mutate: (record) => { record.receipt_current = null; } },
      { name: 'modern-malformed-unbound',
        mutate: (record) => { record.receipt_identity_unbound = 'false'; } },
    ];
    for (const [index, item] of cases.entries()) {
      const f = makeFixture('strict-concrete-sent-' + item.name);
      const session = 'session_strict-concrete-sent-' + item.name;
      const plan = { type: 'text', purpose: item.local ? 'keyword_reply' : 'ai_text',
        ordinary: true, ...(item.local ? {} : { ai: true }),
        content: '这一条是有具体内容的合成业务回答。', fingerprint: 77196 + index };
      const job = item.local
        ? f.makeJob(session, item.name, plan)
        : f.currentUnpooled(f.makeJob(session, item.name, plan));
      if (!item.local) {
        job.provider_settlement = { schema_version: 1, state: 'settled',
          plan_sha256: digest(canonical({ type: plan.type, purpose: plan.purpose,
            content: plan.content, outcome: '', sources: [], tags: [] })),
          response_generation: 0, attempts: 1, settled_at: f.now() };
      }
      const originalBody = f.makeOutgoing(job, plan.content, 'sent').body;
      const record = { ...f.makeOutgoing(job, plan.content, 'sent'),
        delivery_identity_version: 1, purpose: plan.purpose, message_type: plan.type,
        semantic_intent: 'answer', semantic_status: 'valid_answer', response_generation: 0,
        content_sha256: digest(canonical({ type: plan.type, content: plan.content })),
        sent_at: f.now() - 10000, receipt_confirmed_at: f.now() - 9000,
        receipt_current: true };
      delete record.body;
      item.mutate(record, originalBody);
      const originalRecord = structuredClone(record);
      await f.seed(session, (state) => {
        state.jobs.push(job); state.outgoing[String(plan.fingerprint)] = record;
      });
      f.restart();
      assert.equal((await f.runtime().process(f.key(session), job.id)).status,
        'delivery_identity_unresolved', item.name);
      const stored = f.rawState(session);
      const retained = stored.jobs.find((entry) => entry.id === job.id);
      assert.deepEqual(stored.outgoing[String(plan.fingerprint)], originalRecord,
        item.name + ':concrete sent 冲突证据必须逐字保留');
      assert.equal(retained.responsibility_status, 'unresolved_failure', item.name);
      assert.equal(retained.failure_code, 'delivery_identity_unresolved', item.name);
      assert(retained.data, item.name + ':原始访客责任必须保留');
      assert.equal(f.retrievalRequests.length, 0, item.name);
      assert.equal(f.modelRequests.length, 0, item.name);
      assert.equal(f.postAttempts.length, 0, item.name);
      assert.equal(f.sent.length, 0, item.name);
    }

    const rawPicker = makeFixture('strict-concrete-sent-picker-raw-plan-digest');
    const rawPickerSession = 'session_strict-concrete-picker-raw-plan-digest';
    const rawPickerPlan = { type: 'picker', purpose: 'menu', ordinary: true,
      fingerprint: 77208, content: { id: 'synthetic-menu', text: '请选择服务：',
        choices: [{ value: 'status', label: '查看状态', selected: false }] } };
    const rawPickerJob = rawPicker.makeJob(rawPickerSession,
      'strict-concrete-picker-raw-plan-digest', rawPickerPlan);
    const rawPickerRecord = {
      status: 'sent', created_at: rawPicker.now() - 15000,
      sent_at: rawPicker.now() - 10000, receipt_confirmed_at: rawPicker.now() - 9000,
      attempts: 1, attempt_token: digest('attempt|' + rawPickerJob.id).slice(0, 32),
      job_id: rawPickerJob.id, generation: rawPickerJob.generation, response_generation: 0,
      delivery_identity_version: 1, purpose: rawPickerPlan.purpose,
      message_type: 'picker', semantic_intent: 'control',
      semantic_status: 'control_delivered', receipt_current: true,
      content_sha256: digest(canonical({ type: 'picker', content: rawPickerPlan.content })),
    };
    const rawPickerBefore = structuredClone(rawPickerRecord);
    await rawPicker.seed(rawPickerSession, (state) => {
      state.jobs.push(rawPickerJob);
      state.outgoing[String(rawPickerPlan.fingerprint)] = rawPickerRecord;
    });
    rawPicker.restart();
    assert.equal((await rawPicker.runtime().process(
      rawPicker.key(rawPickerSession), rawPickerJob.id)).status,
    'delivery_identity_unresolved');
    assert.deepEqual(rawPicker.rawState(rawPickerSession)
      .outgoing[String(rawPickerPlan.fingerprint)], rawPickerBefore,
    '未按 required=false wire 冻结的 picker 摘要不得被当前 plan 洗白');
    assert.equal(rawPicker.postAttempts.length, 0);

    const legacyFixed = makeFixture('legacy-fixed-reply-generic-wire');
    const legacyFixedSession = 'session_legacy-fixed-reply-generic-wire';
    const legacyFixedPlan = { type: 'text', purpose: 'keyword_reply', ordinary: true,
      content: clarification, fingerprint: 772085 };
    const legacyFixedJob = legacyFixed.makeJob(legacyFixedSession,
      'legacy-fixed-reply-generic-wire', legacyFixedPlan, {
        status: 'done', responsibility_status: 'answered_confirmed',
        responsibility_reason: 'fixed_reply', completed_at: legacyFixed.now() - 5000,
      });
    const legacyFixedRecord = legacyFixed.makeOutgoing(
      legacyFixedJob, legacyFixedPlan.content, 'sent');
    const legacyFixedBefore = structuredClone(legacyFixedRecord);
    await legacyFixed.seed(legacyFixedSession, (state) => {
      state.jobs.push(legacyFixedJob);
      state.outgoing[String(legacyFixedPlan.fingerprint)] = legacyFixedRecord;
    });
    legacyFixed.restart();
    await legacyFixed.runtime().transaction(legacyFixed.key(legacyFixedSession), () => {});
    const legacyFixedState = legacyFixed.rawState(legacyFixedSession);
    assert.deepEqual(legacyFixedState.outgoing[String(legacyFixedPlan.fingerprint)],
      legacyFixedBefore, '升级不能把同文案的业务固定回复迁移成项目 generic non-answer');
    assert.equal(legacyFixedState.jobs.find((entry) => entry.id === legacyFixedJob.id)
      .responsibility_status, 'answered_confirmed');

    const planlessFixed = makeFixture('legacy-planless-fixed-reply-generic-wire');
    const planlessFixedSession = 'session_legacy-planless-fixed-reply-generic-wire';
    const planlessFixedJob = planlessFixed.makeJob(planlessFixedSession,
      'legacy-planless-fixed-reply-generic-wire', null, {
        status: 'done', responsibility_status: 'answered_confirmed',
        responsibility_reason: 'fixed_reply', completed_at: planlessFixed.now() - 5000,
      });
    const planlessFingerprint = 772086;
    const planlessFixedRecord = {
      status: 'sent', created_at: planlessFixed.now() - 15000,
      sent_at: planlessFixed.now() - 10000, attempts: 1,
      attempt_token: digest('attempt|' + planlessFixedJob.id).slice(0, 32),
      job_id: planlessFixedJob.id, generation: planlessFixedJob.generation,
      purpose: 'keyword_reply',
      body: { type: 'text', from: 'operator', origin: 'chat', automated: true,
        fingerprint: planlessFingerprint, content: clarification },
    };
    const planlessFixedBefore = structuredClone(planlessFixedRecord);
    await planlessFixed.seed(planlessFixedSession, (state) => {
      state.jobs.push(planlessFixedJob);
      state.outgoing[String(planlessFingerprint)] = planlessFixedRecord;
    });
    planlessFixed.restart();
    await planlessFixed.runtime().transaction(planlessFixed.key(planlessFixedSession), () => {});
    const planlessFixedState = planlessFixed.rawState(planlessFixedSession);
    assert.deepEqual(planlessFixedState.outgoing[String(planlessFingerprint)],
      planlessFixedBefore,
      'plan 已裁剪但 purpose 明示 keyword_reply 时不得只凭 generic 正文改写历史语义');
    assert.equal(planlessFixedState.jobs.find((entry) => entry.id === planlessFixedJob.id)
      .responsibility_status, 'answered_confirmed');

    const fixedGeneric = makeFixture('strict-fixed-reply-generic-wire');
    const fixedGenericSession = 'session_strict-fixed-reply-generic-wire';
    const fixedGenericPlan = { type: 'text', purpose: 'keyword_reply', ordinary: true,
      content: clarification, fingerprint: 77209 };
    const fixedGenericJob = fixedGeneric.makeJob(fixedGenericSession,
      'strict-fixed-reply-generic-wire', fixedGenericPlan);
    await fixedGeneric.seed(fixedGenericSession,
      (state) => state.jobs.push(fixedGenericJob));
    fixedGeneric.restart();
    assert.equal((await fixedGeneric.runtime().process(
      fixedGeneric.key(fixedGenericSession), fixedGenericJob.id)).status, 'sent');
    const fixedState = fixedGeneric.rawState(fixedGenericSession);
    const fixedRecord = fixedState.outgoing[String(fixedGenericPlan.fingerprint)];
    assert.equal(fixedRecord.semantic_intent, 'answer',
      'legacy generic 词表不得扫描管理员业务固定回复');
    assert.equal(fixedRecord.semantic_status, 'valid_answer');
    assert.equal(fixedState.jobs.find((entry) => entry.id === fixedGenericJob.id)
      .responsibility_status, 'answered_confirmed');
    assert.equal(fixedGeneric.sent.length, 1);
    assert.equal(fixedGeneric.sent[0].content, clarification);
  });

  await test('F39 旧版unknown仍绑定job但plan已丢失时先对账已送指纹，不生成第二条', async () => {
    const f = makeFixture('legacy-unknown-without-plan-found'), session = 'session_legacy-unknown-found';
    const fingerprint = 77126;
    const job = f.makeJob(session, 'legacy-unknown-found');
    const body = { type: 'text', from: 'operator', origin: 'chat', content: '旧版远端已经收到的正文', fingerprint };
    await f.seed(session, state => {
      state.jobs.push(job);
      state.outgoing[String(fingerprint)] = { status: 'unknown', body, created_at: f.now() - 15000, attempts: 1,
        job_id: job.id, generation: 0,
        attempt_token: digest('attempt|' + job.id).slice(0, 32) };
    });
    const originalOutgoing = structuredClone(f.rawState(session).outgoing[String(fingerprint)]);
    f.histories.set(session, [{ ...body, timestamp: f.now() - 1000 }]);
    const keyword = f.readConfig('keyword');
    keyword.rules.unshift({ id: 'synthetic-legacy-new-rule', name: '旧状态后的新规则', enabled: true, match_mode: 'exact',
      keywords: ['旧队列的普通问题'], exclude_keywords: [], priority: 1000, action: 'reply', text: '不得产生的第二条回复', cooldown_seconds: 0 });
    f.writeConfig('keyword', keyword); f.publishCurrentMaterials(); f.restart();
    assert.equal((await f.runtime().process(f.key(session), job.id)).status,
      'delivery_identity_unresolved');
    assert.equal(f.sent.length, 0); assert.equal(f.postAttempts.length, 0); assert.equal(f.modelRequests.length, 0);
    const state = f.rawState(session);
    assert.deepEqual(state.outgoing[String(fingerprint)], originalOutgoing,
      '严格身份无法闭合时必须原样保留旧 unknown，而不是部分改成 sent');
    const unresolved = state.jobs.find(item => item.id === job.id);
    assert.equal(unresolved.status, 'received');
    assert.equal(unresolved.responsibility_status, 'unresolved_failure');
    assert.equal(unresolved.failure_code, 'delivery_identity_unresolved');
    assert.equal(unresolved.delivery_receipt_unknown.identity_status, 'unresolved');
    assert.equal(unresolved.delivery_receipt_unknown.resend_forbidden, true);
    assert(unresolved.retry_at > f.now());
    assert(unresolved.data, '语义身份缺失时必须保留原问题，不能伪造有效回答');
    assert.equal(f.sent.length, 0); f.noFeedback();
  });

  await test('F40 旧版unknown无plan且明确未送达时双重负查后按当前规则恢复一次', async () => {
    const f = makeFixture('legacy-unknown-without-plan-absent'), session = 'session_legacy-unknown-absent';
    const fingerprint = 77127;
    const job = f.makeJob(session, 'legacy-unknown-absent');
    await f.seed(session, state => {
      state.jobs.push(job);
      state.outgoing[String(fingerprint)] = { status: 'unknown', body: { type: 'text', from: 'operator', origin: 'chat', content: '旧版未送正文', fingerprint },
        created_at: f.now() - 15000, attempts: 1, job_id: job.id, generation: 0, attempt_token: 'legacy-unknown-absent' };
    });
    const keyword = f.readConfig('keyword');
    keyword.rules.unshift({ id: 'synthetic-legacy-recovery-rule', name: '旧状态恢复规则', enabled: true, match_mode: 'exact',
      keywords: ['旧队列的普通问题'], exclude_keywords: [], priority: 1000, action: 'reply', text: '旧状态恢复后的唯一回复', cooldown_seconds: 0 });
    f.writeConfig('keyword', keyword); f.publishCurrentMaterials(); f.restart();
    f.modes.exactStatus = 404;
    assert.equal((await f.runtime().process(f.key(session), job.id)).status, 'retry');
    assert.equal(f.sent.length, 0); assert.equal(f.postAttempts.length, 0);
    f.advance(5000); f.restart(); await f.runtime().scan();
    assert.equal((await f.runtime().process(f.key(session), job.id)).status, 'deferred');
    assert.equal(f.rawState(session).outgoing[String(fingerprint)], undefined);
    f.advance(5000); f.restart(); await f.runtime().scan();
    assert.equal((await f.runtime().process(f.key(session), job.id)).status, 'sent');
    assert.equal(f.sent.length, 1); assert.equal(f.sent[0].content, '旧状态恢复后的唯一回复');
    assert.equal(f.postAttempts.length, 1); assert.equal(f.modelRequests.length, 0);
    assert.equal((await f.runtime().process(f.key(session), job.id)).status, 'idle'); f.noFeedback();
  });

  await test('F41 Crisp消息列表滞后但精确指纹已存在时文字与picker只确认送达，不重复POST', async () => {
    const variants = [['unknown', 'picker'], ['sending', 'picker'], ['unknown', 'text'], ['sending', 'text']];
    for (const [index, [status, type]] of variants.entries()) {
      const f = makeFixture('single-' + status + '-' + type + '-list-lag'), session = 'session_single-list-lag-' + status + '-' + type;
      const fingerprint = 77128 + index * 100;
      const content = type === 'picker' ? { id: 'synthetic-handoff-offer', text: '需要人工协助吗？请点击下方按钮确认。',
        choices: [{ value: 'confirm_handoff', label: '召唤人工客服', selected: false }] } : '列表滞后时已被平台接收的文字';
      const plan = { type, purpose: type === 'picker' ? 'handoff_offer' : 'keyword_reply', ordinary: true, content, fingerprint };
      const job = f.makeJob(session, 'single-list-lag', plan);
      const outgoing = f.makeOutgoing(job, content, status);
      if (status === 'unknown') Object.assign(outgoing, {
        delivery_uncertain: true, recovery_deferred: true, resend_forbidden: true,
        next_action_at: f.now(),
      });
      await f.seed(session, state => { state.jobs.push(job); state.outgoing[String(fingerprint)] = outgoing; });
      f.histories.set(session, [{ ...outgoing.body, timestamp: f.now() - 1000 }]);
      f.modes.listHistoryOverride = [];
      f.restart(); await f.runtime().scan();
      assert.equal((await f.runtime().process(f.key(session), job.id)).status, 'sent');
      assert.equal(f.exactRequests.length, 1, '列表缺席后必须查询精确 fingerprint');
      assert.equal(f.postAttempts.length, 0, '精确端点已找到的消息绝不能再次 POST');
      const settled = f.rawState(session).outgoing[String(fingerprint)];
      assert.equal(settled.status, 'sent');
      assert.equal(settled.delivery_uncertain, undefined,
        '精确 wire 回执确认后应清除运输不确定标志');
      assert.equal(settled.recovery_deferred, undefined,
        '精确 wire 回执确认后应清除恢复延期标志');
      assert.equal(settled.resend_forbidden, undefined,
        '已确认 sent 依靠状态防重，不得残留运输期禁重发标志');
      assert.equal(f.rawState(session).jobs.find(item => item.id === job.id).status, 'done');
    }

    const malformed = makeFixture('single-unknown-malformed-transport-marker');
    const malformedSession = 'session_single-malformed-transport-marker';
    const malformedPlan = { type: 'text', purpose: 'keyword_reply', ordinary: true,
      content: '畸形运输标志不得被远端回执洗白', fingerprint: 77586 };
    const malformedJob = malformed.makeJob(malformedSession,
      'single-malformed-transport-marker', malformedPlan);
    const malformedOutgoing = malformed.makeOutgoing(
      malformedJob, malformedPlan.content, 'unknown');
    malformedOutgoing.delivery_uncertain = 'false';
    const malformedBefore = structuredClone(malformedOutgoing);
    await malformed.seed(malformedSession, (state) => {
      state.jobs.push(malformedJob);
      state.outgoing[String(malformedPlan.fingerprint)] = malformedOutgoing;
    });
    malformed.histories.set(malformedSession,
      [{ ...malformedOutgoing.body, timestamp: malformed.now() - 1000 }]);
    malformed.restart();
    assert.equal((await malformed.runtime().process(
      malformed.key(malformedSession), malformedJob.id)).status,
    'delivery_identity_unresolved');
    const malformedStored = malformed.rawState(malformedSession);
    assert.deepEqual(malformedStored.outgoing[String(malformedPlan.fingerprint)],
      malformedBefore, 'strict 失败不得在原记录上提交 status/时间/正文等半份迁移');
    assert.equal(malformedStored.jobs.find((entry) => entry.id === malformedJob.id)
      .delivery_receipt_unknown?.resend_forbidden, true,
    '畸形原记录虽保持逐字不变，job 仍须冻结不可重发的未知回执');
    assert.equal(malformedStored.jobs.find((entry) => entry.id === malformedJob.id)
      .responsibility_status, 'unresolved_failure');
    assert.equal(malformed.postAttempts.length, 0);
  });

  await test('F42 单一unknown经两次间隔精确负查后才允许同指纹重发一次', async () => {
    const f = makeFixture('single-unknown-confirmed-absent'), session = 'session_single-confirmed-absent';
    const fingerprint = 77129;
    const plan = { type: 'text', purpose: 'keyword_reply', ordinary: true, content: '已确认未送达后的唯一回复', fingerprint };
    const job = f.makeJob(session, 'single-confirmed-absent', plan);
    await f.seed(session, state => { state.jobs.push(job); state.outgoing[String(fingerprint)] = f.makeOutgoing(job, plan.content); });
    f.modes.exactStatus = 404;
    f.restart(); await f.runtime().scan();
    assert.equal((await f.runtime().process(f.key(session), job.id)).status, 'retry');
    assert.equal(f.exactRequests.length, 1); assert.equal(f.postAttempts.length, 0);
    f.advance(4999); f.restart();
    assert.equal((await f.runtime().process(f.key(session), job.id)).status, 'idle', '调度重试时间前不能抢跑');
    f.advance(1); await f.runtime().scan();
    assert.equal((await f.runtime().process(f.key(session), job.id)).status, 'sent');
    assert.equal(f.exactRequests.length, 2); assert.equal(f.postAttempts.length, 1);
    assert.equal(f.postAttempts[0].fingerprint, fingerprint);
    assert.equal(f.sent.length, 1); assert.equal(f.sent[0].content, plan.content);
    assert.equal((await f.runtime().process(f.key(session), job.id)).status, 'idle');
    assert.equal(f.postAttempts.length, 1, '完成后重放不得再次发送');
  });

  await test('F43 精确回查暂时失败时只保留原unknown，不抢先POST第二份', async () => {
    const f = makeFixture('single-unknown-exact-failure'), session = 'session_single-exact-failure';
    const fingerprint = 77130;
    const plan = { type: 'text', purpose: 'keyword_reply', ordinary: true, content: '不得在回查失败时重复发送', fingerprint };
    const job = f.makeJob(session, 'single-exact-failure', plan);
    await f.seed(session, state => { state.jobs.push(job); state.outgoing[String(fingerprint)] = f.makeOutgoing(job, plan.content); });
    f.modes.exactFailure = true; f.restart(); await f.runtime().scan();
    assert.equal((await f.runtime().process(f.key(session), job.id)).status, 'retry');
    assert.equal(f.exactRequests.length, 1); assert.equal(f.postAttempts.length, 0);
    const stored = f.rawState(session);
    assert.equal(stored.outgoing[String(fingerprint)].status, 'unknown');
    assert.equal(stored.outgoing[String(fingerprint)].reconcile_misses, undefined, '失败查询不能充当阴性证据');
    assert.equal(stored.jobs.find(item => item.id === job.id).status, 'received');
  });

  await test('F44 精确端点404只作一次阴性，间隔复核后同指纹补发一次', async () => {
    const f = makeFixture('single-unknown-exact-404'), session = 'session_single-exact-404';
    const fingerprint = 77131;
    const plan = { type: 'text', purpose: 'keyword_reply', ordinary: true, content: '精确404确认后的唯一回复', fingerprint };
    const job = f.makeJob(session, 'single-exact-404', plan);
    await f.seed(session, state => { state.jobs.push(job); state.outgoing[String(fingerprint)] = f.makeOutgoing(job, plan.content); });
    f.modes.exactStatus = 404; f.restart(); await f.runtime().scan();
    assert.equal((await f.runtime().process(f.key(session), job.id)).status, 'retry');
    assert.equal(f.exactRequests.length, 1); assert.equal(f.postAttempts.length, 0);
    assert.equal(f.rawState(session).outgoing[String(fingerprint)].reconcile_misses, 1);
    f.advance(5000); f.restart(); await f.runtime().scan();
    assert.equal((await f.runtime().process(f.key(session), job.id)).status, 'sent');
    assert.equal(f.exactRequests.length, 2); assert.equal(f.postAttempts.length, 1);
    assert.equal(f.postAttempts[0].fingerprint, fingerprint);
    assert.equal(f.sent.length, 1); assert.equal(f.sent[0].content, plan.content);
  });

  await test('F45 旧版丢plan的unknown遇精确404时双重负查后按当前规则仅恢复一次', async () => {
    const f = makeFixture('orphan-unknown-exact-404'), session = 'session_orphan-exact-404';
    const fingerprint = 77132;
    const job = f.makeJob(session, 'orphan-exact-404');
    await f.seed(session, state => {
      state.jobs.push(job);
      state.outgoing[String(fingerprint)] = { status: 'unknown', body: { type: 'text', from: 'operator', origin: 'chat',
        automated: true, content: '旧版未送正文', fingerprint }, created_at: f.now() - 15000, attempts: 1,
        job_id: job.id, generation: 0, attempt_token: 'orphan-exact-404' };
    });
    const keyword = f.readConfig('keyword');
    keyword.rules.unshift({ id: 'synthetic-orphan-404-rule', name: '404恢复规则', enabled: true, match_mode: 'exact',
      keywords: ['旧队列的普通问题'], exclude_keywords: [], priority: 1000, action: 'reply', text: '404恢复后的唯一回复', cooldown_seconds: 0 });
    f.writeConfig('keyword', keyword); f.publishCurrentMaterials(); f.modes.exactStatus = 404; f.restart();
    assert.equal((await f.runtime().process(f.key(session), job.id)).status, 'retry');
    assert.equal(f.exactRequests.length, 1); assert.equal(f.postAttempts.length, 0);
    f.advance(5000); f.restart(); await f.runtime().scan();
    assert.equal((await f.runtime().process(f.key(session), job.id)).status, 'deferred');
    assert.equal(f.rawState(session).outgoing[String(fingerprint)], undefined);
    f.advance(5000); f.restart(); await f.runtime().scan();
    assert.equal((await f.runtime().process(f.key(session), job.id)).status, 'sent');
    assert.equal(f.exactRequests.length, 2); assert.equal(f.postAttempts.length, 1);
    assert.equal(f.sent.length, 1); assert.equal(f.sent[0].content, '404恢复后的唯一回复');
    assert.equal((await f.runtime().process(f.key(session), job.id)).status, 'idle');
    assert.equal(f.sent.length, 1);
  });

  await test('F46 人工确认通知回执未知且实际缺席时可在human模式同指纹补发一次', async () => {
    const f = makeFixture('handoff-ack-unknown-404'), session = 'session_handoff-ack-404';
    const fingerprint = 77133;
    const plan = { type: 'text', purpose: 'handoff_ack', ordinary: false, content: '您的人工协助请求已收到，请稍候。', fingerprint };
    const job = f.makeJob(session, 'handoff-ack-404', plan, { control: true, action: 'confirm_handoff', generation: 1 });
    await f.seed(session, state => {
      state.mode = 'human'; state.generation = 1; state.pause_reason = 'confirmed_handoff'; state.resume_at = f.now() + 3600000;
      state.jobs.push(job); state.outgoing[String(fingerprint)] = f.makeOutgoing(job, plan.content);
      state.outgoing[String(fingerprint)].generation = 1;
    });
    f.modes.exactStatus = 404; f.restart();
    assert.equal((await f.runtime().process(f.key(session), job.id)).status, 'retry');
    assert.equal(f.postAttempts.length, 0); f.advance(5000); f.restart(); await f.runtime().scan();
    assert.equal((await f.runtime().process(f.key(session), job.id)).status, 'sent');
    assert.equal(f.exactRequests.length, 2); assert.equal(f.postAttempts.length, 1);
    assert.equal(f.sent.length, 1); assert.equal(f.sent[0].content, plan.content);
    assert.equal(f.state(session).mode, 'human');
  });

  await test('F47 人工确认未知回执复核期间总开关关闭或会话代次改变仍禁止补发', async () => {
    for (const change of ['global-off', 'generation']) {
      const f = makeFixture('handoff-ack-cancel-' + change), session = 'session_handoff-ack-cancel-' + change;
      const fingerprint = change === 'global-off' ? 77134 : 77135;
      const plan = { type: 'text', purpose: 'handoff_ack', ordinary: false, content: '不得补发的人工确认', fingerprint };
      const job = f.makeJob(session, 'handoff-ack-cancel-' + change, plan, { control: true, action: 'confirm_handoff', generation: 1 });
      await f.seed(session, state => {
        state.mode = 'human'; state.generation = change === 'generation' ? 2 : 1;
        state.jobs.push(job); state.outgoing[String(fingerprint)] = f.makeOutgoing(job, plan.content);
        state.outgoing[String(fingerprint)].generation = 1;
      });
      if(change === 'global-off') {
        f.writeConfig('runtime', { schema_version:2, enabled:false, revision:2, applied_revision:2 });
        f.publishCurrentMaterials();
      }
      f.modes.exactStatus = 404; f.restart();
      assert.equal((await f.runtime().process(f.key(session), job.id)).status, 'retry');
      f.advance(5000); f.restart(); await f.runtime().scan();
      assert.equal((await f.runtime().process(f.key(session), job.id)).status, 'cancelled');
      assert.equal(f.exactRequests.length, 2); assert.equal(f.postAttempts.length, 0); assert.equal(f.sent.length, 0);
      assert.equal(f.rawState(session).outgoing[String(fingerprint)].status, 'cancelled');
    }
  });

  await test('F48 人工接管撞上已登记出站时立即静默，unknown 保留原发送事实且只读对账', async () => {
    const f = makeFixture('operator-post-worker-crash'), session = 'session_operator-post-crash';
    const fingerprint = 77136;
    const plan = { type: 'text', purpose: 'keyword_reply', ordinary: true, content: '不得在人工接管后补发', fingerprint };
    const job = f.makeJob(session, 'operator-post-crash', plan, {
      status: 'processing', attempts: 1, lease_until: f.now() + 300000,
    });
    const outgoing = f.makeOutgoing(job, plan.content, 'sending');
    outgoing.attempt_token = 'a'.repeat(32);
    await f.seed(session, state => {
      state.jobs.push(job);
      state.worker = { job: job.id, token: 'worker-before-crash', until: f.now() + 300000 };
      state.outgoing[String(fingerprint)] = outgoing;
    });
    const bucket = path.join(f.root, 'data/runtime', 'owned-' + f.key(session) + '-'
      + (fingerprint % 256).toString(16).padStart(2, '0') + '.json');
    fs.writeFileSync(bucket, JSON.stringify({ schema_version: 1, fingerprints: [String(fingerprint)] }), { mode: 0o600 });

    f.advance(1);
    const human = f.event(session, '合成人工公开回复', { from: 'operator', automated: false });
    human.event = 'message:received';
    const accepted = await f.receive(human);
    assert.equal(accepted.accepted, true);
    if (accepted.route === 'process') await f.runtime().process(accepted.key, accepted.jobId);

    let stored = f.rawState(session);
    const cancelled = stored.jobs.find(item => item.id === job.id);
    const record = stored.outgoing[String(fingerprint)];
    assert.equal(cancelled.status, 'cancelled');
    assert.equal(cancelled.responsibility_status, 'intentional_silence');
    assert.equal(cancelled.responsibility_reason, 'human_reply');
    assert.equal(record.status, 'unknown');
    assert.equal(record.delivery_uncertain, true);
    assert.equal(record.resend_forbidden, true);
    assert.equal(record.recovery_deferred, true);
    assert.equal(record.cancellation_reason, 'conversation_state_changed');
    assert.equal(record.attempt_token, outgoing.attempt_token, '迟到的确定回执仍须保留同一次 attempt fence');
    assert.equal(record.body.content, plan.content);
    assert.equal(record.body.fingerprint, fingerprint);
    assert.deepEqual(JSON.parse(fs.readFileSync(bucket, 'utf8')).fingerprints, [String(fingerprint)], '永久自有指纹不得随详细状态取消');

    f.restart();
    assert(!(await f.runtime().scan()).some(item => item.jobId === job.id));
    f.advance(5000); f.restart();
    assert((await f.runtime().scan()).some(item => item.jobId === job.id));
    assert.equal((await f.runtime().process(f.key(session), job.id)).status, 'retry', '畸形精确2xx不能作为未送达阴性');
    assert.equal(f.exactRequests.length, 1); assert.equal(f.postAttempts.length, 0);
    f.advance(8 * 86400000); f.restart();
    assert((await f.runtime().scan()).some(item => item.jobId === job.id), '人工静默不等于删除未知投递对账责任');
    stored = f.rawState(session);
    const retainedJob = stored.jobs.find(item => item.id === job.id);
    const retainedRecord = stored.outgoing[String(fingerprint)];
    assert.equal(retainedJob.status, 'cancelled');
    assert.equal(retainedJob.responsibility_status, 'intentional_silence');
    assert.equal(retainedJob.responsibility_reason, 'human_reply');
    assert.equal(retainedRecord.status, 'unknown');
    assert.equal(retainedRecord.resend_forbidden, true);
    assert.equal(retainedRecord.body.content, plan.content);
    assert.equal(retainedRecord.body.fingerprint, fingerprint);
    assert.deepEqual(JSON.parse(fs.readFileSync(bucket, 'utf8')).fingerprints, [String(fingerprint)]);
    assert.equal(f.sent.length, 0); assert.equal(f.modelRequests.length, 0);

    const disabled = makeFixture('global-off-post-worker-crash'), disabledSession = 'session_global-off-post-crash';
    const disabledPlan = { ...plan, content: '总开关关闭后不得补发', fingerprint: 77138 };
    const disabledJob = disabled.makeJob(disabledSession, 'global-off-post-crash', disabledPlan, {
      status: 'cancelled', responsibility_status: 'intentional_silence', responsibility_reason: 'global_disabled',
    });
    const disabledOutgoing = disabled.makeOutgoing(disabledJob, disabledPlan.content, 'sending');
    delete disabledJob.data; delete disabledJob.plan;
    await disabled.seed(disabledSession, state => {
      state.jobs.push(disabledJob); state.outgoing[String(disabledPlan.fingerprint)] = disabledOutgoing;
    });
    disabled.writeConfig('runtime', { schema_version: 2, enabled: false, revision: 2, applied_revision: 2 });
    disabled.publishCurrentMaterials();
    disabled.restart(); await disabled.runtime().scan();
    let disabledState = disabled.rawState(disabledSession);
    let disabledRecord = disabledState.outgoing[String(disabledPlan.fingerprint)];
    assert.equal(disabledRecord.status, 'unknown'); assert.equal(disabledRecord.resend_forbidden, true);
    assert.equal(disabledRecord.body.content, disabledPlan.content); assert.equal(disabledRecord.body.fingerprint, disabledPlan.fingerprint);
    disabled.advance(8 * 86400000); disabled.restart();
    assert((await disabled.runtime().scan()).some(item => item.jobId === disabledJob.id));
    disabledState = disabled.rawState(disabledSession); disabledRecord = disabledState.outgoing[String(disabledPlan.fingerprint)];
    assert.equal(disabledState.jobs.filter(item => item.id === disabledJob.id).length, 1);
    assert.equal(disabledState.jobs.find(item => item.id === disabledJob.id).responsibility_reason, 'global_disabled');
    assert.equal(disabledRecord.status, 'unknown'); assert.equal(disabledRecord.resend_forbidden, true);
    assert.equal(disabledRecord.body.content, disabledPlan.content);
    assert.equal(disabled.postAttempts.length, 0); assert.equal(disabled.sent.length, 0);
  });

  await test('F48b 人工接管删除 plan 后，精确远端回执仅结算原发送且绝不重发', async () => {
    const f = makeFixture('operator-post-worker-crash-exact'), session = 'session_operator-post-crash-exact';
    const fingerprint = 77139;
    const plan = { type: 'text', purpose: 'keyword_reply', ordinary: true,
      content: '接管前已经发送、接管后只能确认的原答案', fingerprint };
    const job = f.makeJob(session, 'operator-post-crash-exact', plan, {
      status: 'processing', attempts: 1, lease_until: f.now() + 300000,
    });
    const outgoing = f.makeOutgoing(job, plan.content, 'sending');
    outgoing.attempt_token = 'c'.repeat(32);
    await f.seed(session, state => {
      state.jobs.push(job);
      state.worker = { job: job.id, token: 'worker-before-exact-receipt', until: f.now() + 300000 };
      state.outgoing[String(fingerprint)] = outgoing;
    });

    f.advance(1);
    const human = f.event(session, '合成人工公开回复', { from: 'operator', automated: false });
    human.event = 'message:received';
    const accepted = await f.receive(human);
    assert.equal(accepted.accepted, true);
    if (accepted.route === 'process') await f.runtime().process(accepted.key, accepted.jobId);

    let stored = f.rawState(session);
    let cancelled = stored.jobs.find(item => item.id === job.id);
    let record = stored.outgoing[String(fingerprint)];
    assert.equal(cancelled.status, 'cancelled');
    assert.equal(cancelled.responsibility_status, 'intentional_silence');
    assert.equal(cancelled.responsibility_reason, 'human_reply');
    assert.equal(cancelled.plan, undefined, '真人接管后不得保留可继续派发的 plan');
    assert.equal(record.delivery_identity_version, 1);
    assert.equal(record.semantic_intent, 'answer');
    assert.equal(record.status, 'unknown');
    assert.equal(record.cancellation_reason, 'conversation_state_changed');
    assert(Number.isSafeInteger(record.cancelled_at));
    assert.equal(record.delivery_uncertain, true);
    assert.equal(record.recovery_deferred, true);
    assert.equal(record.resend_forbidden, true);

    f.histories.set(session, [{ ...outgoing.body, timestamp: f.now() - 1000 }]);
    f.modes.listHistoryOverride = [];
    f.advance(5000); f.restart();
    const reconciled = await f.runtime().process(f.key(session), job.id);
    assert.equal(reconciled.status, 'dispatched_after_cancel');

    stored = f.rawState(session);
    cancelled = stored.jobs.find(item => item.id === job.id);
    record = stored.outgoing[String(fingerprint)];
    assert.equal(cancelled.status, 'cancelled');
    assert.equal(cancelled.responsibility_status, 'intentional_silence');
    assert.equal(cancelled.responsibility_reason, 'human_reply');
    assert.equal(record.status, 'sent');
    assert.equal(record.receipt_current, false);
    assert.equal(record.state_changed_before_receipt, true);
    assert.equal(record.delivery_uncertain, undefined);
    assert.equal(record.recovery_deferred, undefined);
    assert.equal(record.resend_forbidden, undefined);
    assert.equal(f.exactRequests.length, 1);
    assert.equal(f.postAttempts.length, 0);
    assert.equal(f.sent.length, 0);
    assert.equal(stored.mode, 'human');
  });

  await test('F49 未知回执持续不可查到轮次上限时保留 unresolved 与原发送事实，不假 failed', async () => {
    const f = makeFixture('receipt-reconciliation-exhausted'), session = 'session_receipt-exhausted';
    const fingerprint = 77137;
    const plan = { type: 'text', purpose: 'keyword_reply', ordinary: true, content: '未知回执不得越过上限补发', fingerprint };
    const job = f.makeJob(session, 'receipt-exhausted', plan, {
      delivery_retries: 60, received_at: f.now() - 300000,
    });
    const outgoing = f.makeOutgoing(job, plan.content, 'unknown');
    outgoing.attempt_token = 'b'.repeat(32);
    outgoing.delivery_uncertain = true;
    await f.seed(session, state => { state.jobs.push(job); state.outgoing[String(fingerprint)] = outgoing; });
    f.modes.historyFailure = true; f.restart();

    assert.equal((await f.runtime().process(f.key(session), job.id)).status, 'retry');
    let stored = f.rawState(session);
    let unresolved = stored.jobs.find(item => item.id === job.id);
    let record = stored.outgoing[String(fingerprint)];
    assert.equal(unresolved.status, 'received');
    assert.equal(unresolved.delivery_retries, 61);
    assert.equal(unresolved.responsibility_status, 'unresolved_failure');
    assert.equal(unresolved.failure_code, 'receipt_reconciliation_unavailable');
    assert.equal(unresolved.data.content, job.data.content);
    assert.equal(unresolved.plan.content, plan.content);
    assert.equal(record.status, 'unknown');
    assert.equal(record.delivery_uncertain, true);
    assert.equal(record.attempt_token, outgoing.attempt_token);
    assert.equal(record.body.content, plan.content);
    assert.equal(record.body.fingerprint, fingerprint);
    assert.equal(f.postAttempts.length, 0); assert.equal(f.exactRequests.length, 0);

    f.restart();
    assert(!(await f.runtime().scan()).some(item => item.jobId === job.id));
    f.advance(8 * 86400000); f.restart();
    assert((await f.runtime().scan()).some(item => item.jobId === job.id), '跨日志期限仍须保留可恢复对账责任');
    assert.equal((await f.runtime().process(f.key(session), job.id)).status, 'retry');
    stored = f.rawState(session);
    assert.equal(stored.jobs.filter(item => item.id === job.id).length, 1);
    unresolved = stored.jobs.find(item => item.id === job.id);
    record = stored.outgoing[String(fingerprint)];
    assert.equal(unresolved.status, 'received');
    assert.equal(unresolved.responsibility_status, 'unresolved_failure');
    assert.equal(unresolved.data.content, job.data.content);
    assert.equal(unresolved.plan.content, plan.content);
    assert.equal(record.status, 'unknown');
    assert.equal(record.body.content, plan.content);
    assert.equal(record.body.fingerprint, fingerprint);
    assert.equal(f.postAttempts.length, 0); assert.equal(f.sent.length, 0);
  });

  await test('F50 Chat与Responses机械故障及旧 generic 零出站，业务事实与引用不误杀', async () => {
    const mechanical = ['暂时无法回复，请稍后再试。', '  抱歉，暂时无法回复，请稍后再试。谢谢理解！  ',
      '系\u200b统　正忙，请稍后再试，谢谢理解。', '当前暂时不能答复，建议过一会儿再试。',
      '服务开了小差，请过会儿再试。', '很抱歉，我们目前没有办法为您提供帮助，请您耐心等待。',
      '抱歉呀，客服系统有点忙，您过会儿再咨询吧。', '由于系统繁忙，现在暂时无法回答您的问题，请稍候。',
      '服务器繁忙，请稍后再试。', '暂时无法进行回复，稍后重试。', '系统出了点小差，请稍后再试。',
      '系统维护中，请稍后再试。', '模型繁忙，请过会再试。', 'AI暂时无法回复，请稍后再试。',
      '机器人开小差了，稍后重试。', '请稍后再试。', 'ＡＩ暂时无法答复，过会再试。',
      'A\u0000I暂时无法回\u0007复，请稍后再试。', '系统正在升级，请稍后再试。',
      '系统拥堵，请稍后再试。', '请求人数较多，请稍后再试。', '网络开小差了，请稍后再试。',
      '后台维护中，请稍后再试。', '系统超时，请稍后重试。',
      'AI暂时无法回答您的订单问题，请稍后再试。', '客服暂时无法回答关于发票的问题，请稍后再试。'];
    const retiredGeneric = [clarification, imageClarification];
    const allowed = ['网站显示“系统繁忙，请稍后再试”时，请检查网络设置并刷新页面。',
      '设置保存后可能需要几十秒生效；如页面仍显示旧值，刷新后再试。',
      '订单暂时无法处理，请稍后再试。', '退款接口当前不可用，请改用银行卡原路退款。',
      '抱歉，我无法回答这个问题。', '抱歉，我无法回答关于制造武器的问题。', '我不能回答您的账户问题。',
      '当前平台不可用。', '当前服务不可用，预计十分钟恢复。',
      '当前平台升级中。', '当前服务超时。', '请求人数较多。'];
    assert(mechanical.every(mechanicalFailureAnswer)); assert(allowed.every(value=>!mechanicalFailureAnswer(value)));
    for (const apiMode of ['chat_completions', 'responses']) for (const [index, content] of [...mechanical, ...retiredGeneric].entries()) {
      const f = makeFixture('mechanical-runtime-' + apiMode + '-' + index), session = 'session_mechanical-' + apiMode.replaceAll('_','-') + '-' + index;
      f.writeConfig('provider', { provider: { ...f.readConfig('provider').provider, api_mode: apiMode } });
      f.modes.answer = content;
      const input = f.event(session, '合成模型故障话术问题');
      const failure = await f.deliver(input);
      assert.equal(failure.status, 'unresolved');
      assert.equal(f.modelRequests.length, 1);
      assertUnresolvedResponsibility(f, session, failure.jobId, input.data.content);
      assert.equal(f.state(session).mode, 'ai');
      assert.equal(f.events().filter(event=>event.type==='ai_reply'||event.type==='knowledge_hit').length,0);
      f.modes.answer = '恢复后的有效业务答案。';
      await recoverSameJobOnce(f, session, failure.jobId, f.modes.answer);
      assert.equal(f.modelRequests.length, 2);
    }
    for (const [index, content] of allowed.entries()) {
      const f = makeFixture('mechanical-allowed-' + index), session = 'session_mechanical-allowed-' + index;
      f.modes.answer = content; await f.deliver(f.event(session, '合成实质排障问题'));
      assert.equal(f.sent.length,1);assert.equal(f.sent[0].content,content);assert.equal(f.modelRequests.length,1);
    }
    for (const apiMode of ['chat_completions', 'responses']) {
      const f = makeFixture('mechanical-mixed-' + apiMode), session = 'session_mechanical-mixed-' + apiMode.replaceAll('_','-');
      f.writeConfig('provider', { provider: { ...f.readConfig('provider').provider, api_mode: apiMode } });
      f.modes.answer = '页面显示“暂时无法回复，请稍后再试。”时，您可以查看帮助中心。';
      await f.deliver(f.event(session, '合成混合答复问题'));
      assert.equal(f.modelRequests.length, 1); assert.equal(f.sent.length, 1);
      assert.equal(f.sent[0].content, f.modes.answer, '引用机械句的实质业务说明不得被截断或误杀');
    }
  });

  await test('F51 视觉摘要和图片最终阶段残余机械话术不进入图片记忆或访客出站', async () => {
    const summaryFailure = makeFixture('mechanical-vision-summary'), summarySession = 'session_mechanical-vision-summary';
    summaryFailure.modes.visionAnswer = '服务开小差了，请过会儿再试。';
    const summaryInput = summaryFailure.event(summarySession,
      { url: 'https://storage.crisp.chat/synthetic.png', type: 'image/png' }, { type: 'file' });
    const summaryResult = await summaryFailure.deliver(summaryInput);
    assert.equal(summaryResult.status, 'unresolved');
    assert.equal(summaryFailure.visionRequests.length,1);assert.equal(summaryFailure.modelRequests.length,0);
    assert.equal(Object.hasOwn(summaryFailure.rawState(summarySession),'image_context'),false);
    assertUnresolvedResponsibility(summaryFailure, summarySession, summaryResult.jobId, summaryInput.data.content);
    summaryFailure.modes.visionAnswer = '图片可见虚构的保存按钮。';
    await recoverSameJobOnce(summaryFailure, summarySession, summaryResult.jobId, summaryFailure.modes.answer);

    const finalFailure = makeFixture('mechanical-image-final'), finalSession = 'session_mechanical-image-final';
    finalFailure.modes.visionAnswer = '图片可见虚构的蓝色保存按钮。';
    finalFailure.modes.answer = '当前暂时不能答复，建议过一会儿再试。';
    const finalInput = finalFailure.event(finalSession,
      { url: 'https://storage.crisp.chat/synthetic.png', type: 'image/png' }, { type: 'file' });
    const finalResult = await finalFailure.deliver(finalInput);
    assert.equal(finalResult.status, 'unresolved');
    assert.equal(finalFailure.visionRequests.length,1);assert.equal(finalFailure.modelRequests.length,1);
    assert.equal(finalFailure.rawState(finalSession).image_context.length,1);
    assert.equal(finalFailure.rawState(finalSession).image_context[0].summary,'图片可见虚构的蓝色保存按钮。');
    assert(!JSON.stringify(finalFailure.rawState(finalSession).image_context).includes('不能答复'));
    assertUnresolvedResponsibility(finalFailure, finalSession, finalResult.jobId, finalInput.data.content);
    assert.equal(finalFailure.state(finalSession).mode,'ai');
    finalFailure.modes.answer = '根据图片中的保存按钮，请先点击保存。';
    await recoverSameJobOnce(finalFailure, finalSession, finalResult.jobId, finalFailure.modes.answer);
  });

  await test('F52 升级后未发送机械/generic 计划转 unresolved，明确产品动作与业务正文保持可见', async () => {
    const cached = [
      { label: 'text', purpose: 'ai_text', content: '系统维护中，请稍后再试。' },
      { label: 'vision', purpose: 'vision', content: '模型繁忙，请过会再试。', image: true },
      { label: 'queued', purpose: 'ai_text', content: 'AI暂时无法回复，请稍后再试。', queued: true },
      { label: 'generic', purpose: 'ai_text', content: clarification },
      { label: 'signed-generic', purpose: 'ai_text', content: clarification, signed: true },
      { label: 'image-generic', purpose: 'vision', content: imageClarification, image: true },
    ];
    for (const [index, item] of cached.entries()) {
      const f = makeFixture('mechanical-cached-' + item.label), session = 'session_mechanical-cached-' + item.label;
      const plan = { type: 'text', purpose: item.purpose, ordinary: true, ai: true, content: item.content,
        fingerprint: 77201 + index, ...(item.signed ? { knowledge_answer_sha256: digest(item.content) } : {}) };
      const job = f.makeJob(session, 'cached-' + item.label, plan);
      if (item.image) job.data = f.event(session, { url: 'https://storage.crisp.chat/synthetic.png', type: 'image/png' }, { type: 'file' }).data;
      await f.seed(session, state => {
        state.jobs.push(job);
        if (item.queued) state.outgoing[String(plan.fingerprint)] = f.makeOutgoing(job, item.content, 'queued');
      });
      f.restart();
      if (item.queued) {
        await f.runtime().scan();
        assert.equal(f.rawState(session).jobs.find((entry) => entry.id === job.id)
          .response_generation, 1, '计划收敛与 queued 退休只能共享一次回答代推进');
        f.restart(); await f.runtime().scan();
        assert.equal(f.rawState(session).jobs.find((entry) => entry.id === job.id)
          .response_generation, 1, 'queued 退休重复扫描必须幂等');
      }
      const result = await f.runtime().process(f.key(session));
      assert.equal(result.status, 'unresolved');
      assertUnresolvedResponsibility(f, session, job.id, job.data.content);
      assert.equal(f.modelRequests.length, 0); assert.equal(f.visionRequests.length, 0);
      await recoverSameJobOnce(f, session, job.id, f.modes.answer);
      assert.equal(f.modelRequests.length, 1);
      assert.equal(f.visionRequests.length, item.image ? 1 : 0);
    }
    const normalized = [
      { label: 'mixed-fixed', purpose: 'keyword_reply', content: '页面显示“暂时无法回复，请稍后再试。”时，请查看帮助中心。', expected: '页面显示“暂时无法回复，请稍后再试。”时，请查看帮助中心。' },
      { label: 'welcome', purpose: 'welcome', content: '客服系统有点忙，请过会儿再咨询吧。', expected: visitorFallbackFor('welcome') },
      { label: 'handoff', purpose: 'handoff_ack', ordinary: false, content: '这边暂时回复不上来，您等一下再试。', expected: visitorFallbackFor('handoff_ack') },
    ];
    for (const [index, item] of normalized.entries()) {
      const f = makeFixture('mechanical-cached-normalized-' + item.label), session = 'session_mechanical-normalized-' + item.label;
      const plan = { type: 'text', purpose: item.purpose, ordinary: item.ordinary ?? true, content: item.content, fingerprint: 77211 + index };
      const job = f.makeJob(session, 'normalized-' + item.label, plan);
      await f.seed(session, state => state.jobs.push(job)); f.restart();
      assert.equal((await f.runtime().process(f.key(session))).status, 'sent');
      assert.equal(f.sent.length, 1); assert.equal(f.sent[0].content, item.expected); assert.equal(f.modelRequests.length, 0);
      assert(!mechanicalFailureAnswer(f.sent[0].content));
    }

    const fixed = makeFixture('mechanical-cached-normalized-fixed'), fixedSession = 'session_mechanical-normalized-fixed';
    const fixedPlan = { type: 'text', purpose: 'keyword_reply', ordinary: true,
      content: '暂时无法回复，请稍后再试。', fingerprint: 77210 };
    const fixedJob = fixed.makeJob(fixedSession, 'normalized-fixed', fixedPlan);
    await fixed.seed(fixedSession, state => state.jobs.push(fixedJob)); fixed.restart();
    assert.equal((await fixed.runtime().process(fixed.key(fixedSession), fixedJob.id)).status, 'unresolved');
    assertUnresolvedResponsibility(fixed, fixedSession, fixedJob.id, fixedJob.data.content);
    await recoverSameJobOnce(fixed, fixedSession, fixedJob.id, fixed.modes.answer);
    assert.equal(fixed.modelRequests.length, 1);

    const picker = makeFixture('mechanical-cached-picker'), pickerSession = 'session_mechanical-picker';
    const pickerPlan = { type: 'picker', purpose: 'menu', ordinary: true, fingerprint: 77219, content: {
      id: 'synthetic-picker', text: '当前系统繁忙，请稍后再试。', choices: [
        { label: '暂时无法回复，请稍后再试。', value: 'first' }, { label: '查看订单', value: 'second' },
      ],
    } };
    await picker.seed(pickerSession, state => state.jobs.push(picker.makeJob(pickerSession, 'picker', pickerPlan)));
    picker.restart(); assert.equal((await picker.runtime().process(picker.key(pickerSession))).status, 'sent');
    assert.equal(picker.sent[0].content.text, visitorFallbackFor('menu'));
    assert.deepEqual(picker.sent[0].content.choices.map(choice => choice.label), ['选项 1', '查看订单']);
    assert.equal(picker.sent[0].content.required, false,
      'picker plan 与真实 wire 必须共享 required=false 投影');
    const pickerState = picker.rawState(pickerSession);
    const pickerJob = pickerState.jobs.find((entry) => entry.plan?.fingerprint === pickerPlan.fingerprint
      || entry.id === digest(pickerSession + '|picker'));
    const pickerRecord = Object.values(pickerState.outgoing)
      .find((record) => record.job_id === pickerJob.id);
    assert.equal(pickerJob.status, 'done');
    assert.equal(pickerJob.responsibility_status, 'control_handled');
    assert.equal(pickerRecord.status, 'sent');
    assert.equal(pickerRecord.semantic_status, 'control_delivered');
    assert(Number.isSafeInteger(pickerRecord.sent_at));
    assert(Number.isSafeInteger(pickerRecord.receipt_confirmed_at));
    assert(pickerRecord.receipt_confirmed_at >= pickerRecord.sent_at,
      'live sent 时间必须满足发送不晚于回执确认');
    assert.equal(pickerRecord.content_sha256,
      digest(canonical({ type: 'picker', content: picker.sent[0].content })));
    assert.equal((await picker.runtime().process(picker.key(pickerSession), pickerJob.id)).status, 'idle');
    assert.equal(picker.postAttempts.length, 1, 'picker 完成后不得重复 POST');

    const allowed = makeFixture('mechanical-cached-substantive'), allowedSession = 'session_mechanical-substantive';
    const allowedContent = '网站显示“系统繁忙，请稍后再试”时，请检查网络设置。';
    const allowedPlan = { type: 'text', purpose: 'keyword_reply', ordinary: true, content: allowedContent, fingerprint: 77220 };
    await allowed.seed(allowedSession, state => state.jobs.push(allowed.makeJob(allowedSession, 'substantive', allowedPlan)));
    allowed.restart(); assert.equal((await allowed.runtime().process(allowed.key(allowedSession))).status, 'sent');
    assert.equal(allowed.sent[0].content, allowedContent); assert.equal(allowed.modelRequests.length, 0);

    const invoice = makeFixture('mechanical-cached-invoice-fact'), invoiceSession = 'session_mechanical-invoice-fact';
    const invoiceContent = '示例商店暂不提供蓝色礼盒包装。';
    const invoicePlan = { type: 'text', purpose: 'keyword_reply', ordinary: true, content: invoiceContent, fingerprint: 77221 };
    await invoice.seed(invoiceSession, state => state.jobs.push(invoice.makeJob(invoiceSession, 'invoice-fact', invoicePlan)));
    invoice.restart(); assert.equal((await invoice.runtime().process(invoice.key(invoiceSession))).status, 'sent');
    assert.equal(invoice.sent[0].content, invoiceContent); assert.equal(invoice.modelRequests.length, 0);
  });

  await test('F53 旧机械正文只收敛原回执，确认未送达后转为不可见 technical_unresolved', async () => {
    const assertRecoveredReceipt = async (fixture, session, job, oldFingerprint) => {
      let stored = fixture.rawState(session);
      const oldRecord = stored.outgoing[String(oldFingerprint)];
      assert.equal(oldRecord.status, 'sent');
      assert.equal(oldRecord.delivery_identity_version, 1);
      assert.equal(oldRecord.response_generation, 0);
      assert.equal(oldRecord.receipt_identity_unbound, undefined);
      assert(Number.isSafeInteger(oldRecord.sent_at));
      assert(Number.isSafeInteger(oldRecord.receipt_confirmed_at));
      assert(Number.isSafeInteger(oldRecord.semantic_reported_at));
      assert.equal(Object.hasOwn(oldRecord, 'body'), false);
      assert.equal(oldRecord.semantic_status, 'delivered_non_answer');
      assert.equal(stored.jobs.find(item => item.id === job.id).status, 'received');
      assert.equal(stored.jobs.find(item => item.id === job.id).responsibility_status, 'unresolved_failure');
      assert.equal(stored.jobs.find(item => item.id === job.id).failure_code, 'delivered_non_answer');
      assert(stored.jobs.find(item => item.id === job.id).data, '旧泛问已送达也必须保留原问题');
      assert.equal(fixture.events().filter(event => event.type === 'ai_reply').length, 0);
      fixture.modes.answer = '恢复后的有效业务回答。';
      await recoverSameJobOnce(fixture, session, job.id, fixture.modes.answer);
      stored = fixture.rawState(session);
      assert.equal(stored.jobs.find(item => item.id === job.id).responsibility_status, 'answered_confirmed');
      assert.equal(fixture.events().filter(event => event.type === 'ai_reply').length, 1);
      assert.equal(fixture.postAttempts.length, 1);
      assert.notEqual(String(fixture.postAttempts[0].fingerprint), String(oldFingerprint),
        '恢复答案必须使用新一代稳定 fingerprint');
      fixture.restart(); assert.deepEqual(await fixture.runtime().scan(), []);
      const stable = fixture.rawState(session).jobs.find(item => item.id === job.id);
      assert.equal(stable.status, 'done');
      assert.equal(stable.responsibility_status, 'answered_confirmed');
      assert.equal(stable.response_generation, 1,
        '旧代 generic 不能在有效恢复答复完成后再次降级当前责任');
      assert.equal(fixture.postAttempts.length, 1);
    };

    const delivered = makeFixture('mechanical-cached-unknown-found'), deliveredSession = 'session_mechanical-unknown-found';
    const deliveredPlan = { type: 'text', purpose: 'ai_text', ordinary: true, ai: true,
      content: clarification, fingerprint: 77221 };
    const deliveredJob = delivered.legacyUnpooled(delivered.makeJob(deliveredSession, 'unknown-found', deliveredPlan));
    const deliveredOutgoing = delivered.makeOutgoing(deliveredJob, deliveredPlan.content, 'unknown');
    await delivered.seed(deliveredSession, state => { state.jobs.push(deliveredJob); state.outgoing['77221'] = deliveredOutgoing; });
    const historical = { ...deliveredOutgoing.body, timestamp: delivered.now() - 1000 };
    delivered.histories.set(deliveredSession, [historical]); delivered.restart();
    assert.equal((await delivered.runtime().process(delivered.key(deliveredSession))).status, 'delivered_non_answer');
    assert.equal(delivered.postAttempts.length, 0); assert.equal(delivered.sent.length, 0);
    assert.deepEqual(delivered.histories.get(deliveredSession), [historical]);
    await assertRecoveredReceipt(delivered, deliveredSession, deliveredJob, deliveredPlan.fingerprint);

    const exact = makeFixture('mechanical-cached-exact-found'), exactSession = 'session_mechanical-exact-found';
    const exactPlan = { ...deliveredPlan, fingerprint: 77223 };
    const exactJob = exact.legacyUnpooled(exact.makeJob(exactSession, 'exact-found', exactPlan));
    const exactOutgoing = exact.makeOutgoing(exactJob, exactPlan.content, 'unknown');
    const exactHistorical = { ...exactOutgoing.body, timestamp: exact.now() - 1000 };
    await exact.seed(exactSession, state => { state.jobs.push(exactJob); state.outgoing['77223'] = exactOutgoing; });
    exact.histories.set(exactSession, [exactHistorical]); exact.modes.listHistoryOverride = []; exact.restart();
    assert.equal((await exact.runtime().process(exact.key(exactSession))).status, 'delivered_non_answer');
    assert.equal(exact.exactRequests.length, 1); assert.equal(exact.postAttempts.length, 0);
    await assertRecoveredReceipt(exact, exactSession, exactJob, exactPlan.fingerprint);

    const sentReceipt = makeFixture('mechanical-cached-sent-found'), sentSession = 'session_mechanical-sent-found';
    const sentPlan = { ...deliveredPlan, fingerprint: 77224 };
    const sentJob = sentReceipt.legacyUnpooled(sentReceipt.makeJob(sentSession, 'sent-found', sentPlan));
    const sentOutgoing = sentReceipt.makeOutgoing(sentJob, sentPlan.content, 'sent');
    Object.assign(sentOutgoing, { purpose: 'ai_text', message_type: 'text',
      semantic_intent: 'answer', semantic_status: 'valid_answer', response_generation: 0,
      sent_at: sentReceipt.now() - 10000,
      content_sha256: digest(canonical({ type: 'text', content: sentPlan.content })) });
    delete sentOutgoing.body;
    await sentReceipt.seed(sentSession, state => { state.jobs.push(sentJob); state.outgoing['77224'] = sentOutgoing; });
    sentReceipt.restart();
    assert.equal((await sentReceipt.runtime().process(sentReceipt.key(sentSession))).status, 'delivered_non_answer');
    assert.equal(sentReceipt.postAttempts.length, 0);
    await assertRecoveredReceipt(sentReceipt, sentSession, sentJob, sentPlan.fingerprint);

    const absent = makeFixture('mechanical-cached-unknown-absent'), absentSession = 'session_mechanical-unknown-absent';
    const absentPlan = { type: 'text', purpose: 'ai_text', ordinary: true, ai: true,
      content: 'A\u0000I暂时无法回\u0007复，请稍后再试。', fingerprint: 77222 };
    const absentJob = absent.legacyUnpooled(absent.makeJob(absentSession, 'unknown-absent', absentPlan));
    await absent.seed(absentSession, state => { state.jobs.push(absentJob); state.outgoing['77222'] = absent.makeOutgoing(absentJob, absentPlan.content, 'unknown'); });
    absent.modes.exactStatus = 404;
    absent.restart(); assert.equal((await absent.runtime().process(absent.key(absentSession))).status, 'retry');
    let stored = absent.rawState(absentSession);
    assert.equal(absent.exactRequests.length, 1); assert.equal(absent.postAttempts.length, 0);
    assert.equal(stored.jobs.find(job => job.id === absentJob.id).plan.content, absentPlan.content);
    assert.equal(stored.outgoing['77222'].body.content, absentPlan.content);
    absent.advance(5000); absent.restart();
    assert.equal((await absent.runtime().process(absent.key(absentSession))).status, 'retry');
    stored = absent.rawState(absentSession);
    assert.equal(absent.exactRequests.length, 2); assert.equal(absent.postAttempts.length, 0);
    const unresolved = stored.jobs.find(job => job.id === absentJob.id);
    assert.equal(unresolved.status, 'received');
    assert.equal(unresolved.plan.purpose, 'technical_unresolved');
    assert.equal(unresolved.plan.type, 'internal');
    assert.equal(unresolved.plan.content, '');
    assert.equal(unresolved.plan.answer_responsibility, 'unresolved_failure');
    assert.equal(unresolved.data.content, absentJob.data.content, '原始访客输入必须保留供恢复');
    assert.equal(unresolved.deferred_configuration, undefined,
      '机械正文退休不是配置延期');
    assert.equal(unresolved.inference, undefined,
      '双重负查后必须退休旧legacy-unpooled推理身份');
    assert.equal(stored.outgoing['77222'].status, 'cancelled'); assert.equal(Object.hasOwn(stored.outgoing['77222'], 'body'), false);
    assert(Number.isSafeInteger(unresolved.retry_at) && unresolved.retry_at > absent.now(),
      '第二次阴性回执后的恢复时间必须以持久状态为准');
    const beforeRetry = unresolved.retry_at - absent.now();
    assert(beforeRetry > 1);
    absent.advance(beforeRetry - 1); absent.restart();
    assert.equal((await absent.runtime().process(absent.key(absentSession))).status, 'idle',
      '权威 retry_at 到达前不得提前领取技术责任');
    absent.advance(1); absent.restart();
    assert.equal((await absent.runtime().process(absent.key(absentSession))).status, 'unresolved');
    stored = absent.rawState(absentSession);
    const deferred = stored.jobs.find(job => job.id === absentJob.id);
    assert.equal(deferred.status, 'received');
    assert.equal(deferred.responsibility_status, 'unresolved_failure');
    assert.equal(deferred.failure_code, 'visitor_output_rejected');
    assert.equal(deferred.data.content, absentJob.data.content);
    assert.equal(absent.postAttempts.length, 0); assert.equal(absent.sent.length, 0);
    assert.equal(absent.exactRequests.length, 2);
  });

  await test('F53b non-answer 回执状态原子写失败时不先留下假审计事件', async () => {
    const f = makeFixture('nonanswer-receipt-commit-eio');
    const session = 'session_nonanswer-receipt-commit-eio';
    const plan = { type: 'text', purpose: 'ai_text', ordinary: true, ai: true,
      content: clarification, fingerprint: 77225 };
    const job = f.legacyUnpooled(f.makeJob(session, 'nonanswer-receipt-commit-eio', plan));
    const outgoing = f.makeOutgoing(job, plan.content, 'unknown');
    await f.seed(session, (state) => {
      state.jobs.push(job);
      state.outgoing[String(plan.fingerprint)] = outgoing;
    });
    f.histories.set(session, [{ ...outgoing.body, timestamp: f.now() - 1000 }]);
    f.restart();
    const stateFile = path.join(f.root, 'data/runtime/session-' + f.key(session) + '.json');
    const originalRenameSync = fs.renameSync;
    let injected = false;
    try {
      fs.renameSync = (source, destination) => {
        if (!injected && destination === stateFile && fs.existsSync(source)) {
          let candidate = null;
          try { candidate = JSON.parse(fs.readFileSync(source, 'utf8')); } catch (_) {}
          const record = candidate?.outgoing?.[String(plan.fingerprint)];
          if (record?.status === 'sent' && record.semantic_status === 'delivered_non_answer'
            && Number.isSafeInteger(record.semantic_reported_at)) {
            injected = true;
            const error = new Error('synthetic-nonanswer-receipt-commit-eio');
            error.code = 'EIO';
            throw error;
          }
        }
        return originalRenameSync(source, destination);
      };
      const result = await f.runtime().process(f.key(session), job.id);
      assert.equal(result.status, 'deferred');
    } finally {
      fs.renameSync = originalRenameSync;
    }
    assert.equal(injected, true, '必须命中回执候选已形成、会话状态尚未原子替换的窗口');
    assert.equal(f.events().filter((event) => event.type === 'answer_responsibility_unresolved'
      && event.reason === 'delivered_non_answer').length, 0,
    '状态提交失败不得对外留下已投递 non-answer 的假审计事实');
  });

  await test('F72 旧 positive 语义不能掩盖 terminal generic，迁移只留受控责任且不批量重放', async () => {
    assert.equal(legacyGenericNonAnswer(clarification), true,
      '公开旧空泛句必须继续被同源分类器识别，不能靠修改夹具绕过迁移');
    const retained = makeFixture('terminal-generic-retained-input');
    const retainedSession = 'session_terminal-generic-retained-input';
    const retainedPlan = { type: 'text', purpose: 'ai_text', ordinary: true, ai: true,
      content: clarification, fingerprint: 77590 };
    const retainedJob = retained.makeJob(retainedSession, 'terminal-generic-retained-input', retainedPlan, {
      status: 'done', responsibility_status: 'answered_confirmed', response_generation: 0,
    });
    const retainedOutgoing = retained.makeOutgoing(retainedJob, clarification, 'sent');
    Object.assign(retainedOutgoing, { purpose: 'ai_text', message_type: 'text', semantic_intent: 'answer',
      semantic_status: 'valid_answer', content_sha256: digest(canonical({ type: 'text', content: clarification })) });
    delete retainedOutgoing.body;
    await retained.seed(retainedSession, (state) => {
      state.jobs.push(retainedJob);
      state.outgoing[String(retainedPlan.fingerprint)] = retainedOutgoing;
    });
    let before = retained.rawState(retainedSession);
    let beforeJob = before.jobs.find((job) => job.id === retainedJob.id);
    assert.equal(beforeJob.status, 'done'); assert.equal(beforeJob.responsibility_status, 'answered_confirmed');
    assert.equal(beforeJob.plan.purpose, 'ai_text'); assert.equal(beforeJob.plan.type, 'text');
    assert.equal(digest(canonical({ type: beforeJob.plan.type, content: beforeJob.plan.content })),
      retainedOutgoing.content_sha256);
    retained.restart();
    assert.deepEqual(await retained.runtime().scan(), []);
    let stored = retained.rawState(retainedSession);
    let migrated = stored.jobs.find((job) => job.id === retainedJob.id);
    assert.equal(stored.outgoing[String(retainedPlan.fingerprint)].status, 'sent', '物理投递事实必须保留');
    assert.equal(stored.outgoing[String(retainedPlan.fingerprint)].delivery_identity_version, 1);
    assert(Number.isSafeInteger(stored.outgoing[String(retainedPlan.fingerprint)]
      .legacy_delivery_identity_migrated_at));
    assert(Number.isSafeInteger(stored.outgoing[String(retainedPlan.fingerprint)].sent_at));
    assert(Number.isSafeInteger(stored.outgoing[String(retainedPlan.fingerprint)].receipt_confirmed_at));
    assert(Number.isSafeInteger(stored.outgoing[String(retainedPlan.fingerprint)].semantic_reported_at));
    assert.equal(stored.outgoing[String(retainedPlan.fingerprint)].receipt_current, true);
    assert.equal(stored.outgoing[String(retainedPlan.fingerprint)].semantic_intent, 'non_answer');
    assert.equal(stored.outgoing[String(retainedPlan.fingerprint)].semantic_status, 'delivered_non_answer');
    assert.equal(migrated.status, 'failed');
    assert.equal(migrated.responsibility_status, 'unresolved_failure');
    assert.equal(migrated.failure_code, 'legacy_non_answer_requires_review');
    assert.equal(migrated.recovery_requires_review, true);
    assert.equal(migrated.response_generation, 1);
    assert(migrated.data, '仍存在的原问题必须保留');
    assert.equal(Object.hasOwn(migrated, 'plan'), false);
    assert.equal(retained.postAttempts.length, 0); assert.equal(retained.modelRequests.length, 0);
    retained.restart(); assert.deepEqual(await retained.runtime().scan(), []);
    stored = retained.rawState(retainedSession);
    migrated = stored.jobs.find((job) => job.id === retainedJob.id);
    assert.equal(migrated.response_generation, 1, '重复扫描不得再次推进恢复代');
    assert.equal(retained.postAttempts.length, 0); assert.equal(retained.modelRequests.length, 0);
    retained.advance(8 * 86400000); retained.restart();
    assert.deepEqual(await retained.runtime().scan(), []);
    stored = retained.rawState(retainedSession);
    migrated = stored.jobs.find((job) => job.id === retainedJob.id);
    assert(migrated, '超过普通七天详情保留期后，未解决责任仍必须保留');
    assert.equal(migrated.responsibility_status, 'unresolved_failure');
    assert.equal(migrated.recovery_requires_review, true);
    assert.equal(migrated.response_generation, 1);
    assert(stored.outgoing[String(retainedPlan.fingerprint)],
      '与未解决责任绑定的冻结投递语义不得按普通日志轮转删除');
    assert.equal(stored.outgoing[String(retainedPlan.fingerprint)].semantic_status, 'delivered_non_answer');
    assert.equal(retained.postAttempts.length, 0); assert.equal(retained.modelRequests.length, 0);

    const stripped = makeFixture('terminal-generic-stripped-input');
    const strippedSession = 'session_terminal-generic-stripped-input';
    const strippedJob = stripped.makeJob(strippedSession, 'terminal-generic-stripped-input', null, {
      status: 'done', responsibility_status: 'answered_confirmed', response_generation: 0,
    });
    delete strippedJob.data;
    const strippedFingerprint = 77591;
    const strippedOutgoing = {
      status: 'sent', created_at: stripped.now() - 15000, sent_at: stripped.now() - 10000,
      attempts: 1, job_id: strippedJob.id, generation: 0, response_generation: 0,
      purpose: 'ai_text', message_type: 'text', semantic_intent: 'answer', semantic_status: 'valid_answer',
      content_sha256: digest(canonical({ type: 'text', content: clarification })),
    };
    await stripped.seed(strippedSession, (state) => {
      state.jobs.push(strippedJob);
      state.outgoing[String(strippedFingerprint)] = strippedOutgoing;
    });
    before = stripped.rawState(strippedSession);
    beforeJob = before.jobs.find((job) => job.id === strippedJob.id);
    const strippedJobBefore = structuredClone(beforeJob);
    const strippedOutgoingBefore = structuredClone(before.outgoing[String(strippedFingerprint)]);
    assert.equal(beforeJob.status, 'done'); assert.equal(beforeJob.responsibility_status, 'answered_confirmed');
    assert.equal(Object.hasOwn(beforeJob, 'data'), false); assert.equal(Object.hasOwn(beforeJob, 'plan'), false);
    assert.equal(before.outgoing[String(strippedFingerprint)].purpose, 'ai_text');
    assert.equal(before.outgoing[String(strippedFingerprint)].message_type, 'text');
    assert.equal(before.outgoing[String(strippedFingerprint)].content_sha256,
      digest(canonical({ type: 'text', content: clarification })));
    stripped.restart(); assert.deepEqual(await stripped.runtime().scan(), []);
    const strippedState = stripped.rawState(strippedSession);
    const strippedMigrated = strippedState.jobs.find((job) => job.id === strippedJob.id);
    assert.deepEqual(strippedState.outgoing[String(strippedFingerprint)], strippedOutgoingBefore,
      '缺 plan/body/token/v1/回执的 sent 只能原样保留，不能凭摘要补造语义');
    assert.deepEqual(strippedMigrated, strippedJobBefore,
      '不完整投递身份不能追溯改写历史终态或回答代');
    assert.equal(stripped.postAttempts.length, 0); assert.equal(stripped.modelRequests.length, 0);
    stripped.restart(); assert.deepEqual(await stripped.runtime().scan(), []);
    assert.deepEqual(stripped.rawState(strippedSession).jobs
      .find((job) => job.id === strippedJob.id), strippedJobBefore);
    assert.equal(stripped.postAttempts.length, 0); assert.equal(stripped.modelRequests.length, 0);

    const normalizedOnly = makeFixture('terminal-generic-normalized-digest-only');
    const normalizedOnlySession = 'session_terminal-generic-normalized-digest-only';
    const normalizedWire = clarification.normalize('NFKC');
    assert.notEqual(normalizedWire, clarification, '本例必须真正改变历史 wire 字节');
    assert.equal(legacyGenericNonAnswer(normalizedWire), true,
      '正文分类仍应识别 Unicode 兼容等价文案');
    const normalizedOnlyJob = normalizedOnly.makeJob(normalizedOnlySession,
      'terminal-generic-normalized-digest-only', null, {
        status: 'done', responsibility_status: 'answered_confirmed', response_generation: 0,
      });
    delete normalizedOnlyJob.data;
    const normalizedOnlyFingerprint = 77598;
    await normalizedOnly.seed(normalizedOnlySession, (state) => {
      state.jobs.push(normalizedOnlyJob);
      state.outgoing[String(normalizedOnlyFingerprint)] = {
        status: 'sent', created_at: normalizedOnly.now() - 15000,
        sent_at: normalizedOnly.now() - 10000, attempts: 1,
        job_id: normalizedOnlyJob.id, generation: 0, response_generation: 0,
        purpose: 'ai_text', message_type: 'text', semantic_intent: 'answer',
        semantic_status: 'valid_answer',
        content_sha256: digest(canonical({ type: 'text', content: normalizedWire })),
      };
    });
    normalizedOnly.restart(); assert.deepEqual(await normalizedOnly.runtime().scan(), []);
    const normalizedOnlyState = normalizedOnly.rawState(normalizedOnlySession);
    assert.equal(normalizedOnlyState.outgoing[String(normalizedOnlyFingerprint)].semantic_status,
      'valid_answer', '未实际发布过的归一化 wire 摘要不能被无正文迁移猜成 generic');
    assert.equal(normalizedOnlyState.jobs.find((job) => job.id === normalizedOnlyJob.id).status, 'done');
    assert.equal(normalizedOnlyState.jobs.find((job) => job.id === normalizedOnlyJob.id)
      .responsibility_status, 'answered_confirmed');
    assert.equal(normalizedOnly.postAttempts.length, 0);
    assert.equal(normalizedOnly.modelRequests.length, 0);

    const pending = makeFixture('terminal-generic-operator-pending');
    const pendingSession = 'session_terminal-generic-operator-pending';
    const pendingPlan = { type: 'text', purpose: 'ai_text', ordinary: true, ai: true,
      content: clarification, fingerprint: 77599 };
    const pendingJob = pending.makeJob(pendingSession, 'terminal-generic-operator-pending',
      pendingPlan, { status: 'done', responsibility_status: 'answered_confirmed',
        response_generation: 0 });
    const pendingOutgoing = pending.makeOutgoing(pendingJob, clarification, 'sent');
    Object.assign(pendingOutgoing, { purpose: pendingPlan.purpose,
      message_type: pendingPlan.type, semantic_intent: 'answer',
      semantic_status: 'valid_answer', response_generation: 0,
      content_sha256: digest(canonical({ type: pendingPlan.type,
        content: pendingPlan.content })) });
    delete pendingOutgoing.body;
    await pending.seed(pendingSession, (state) => {
      state.jobs.push(pendingJob);
      state.outgoing[String(pendingPlan.fingerprint)] = pendingOutgoing;
      state.uncertain_events.push('orphaned-operator-identity-barrier');
    });
    const pendingBefore = pending.rawState(pendingSession);
    const pendingJobBefore = structuredClone(pendingBefore.jobs
      .find((job) => job.id === pendingJob.id));
    const pendingOutgoingBefore = structuredClone(
      pendingBefore.outgoing[String(pendingPlan.fingerprint)]);
    pending.restart();
    await pending.runtime().transaction(pending.key(pendingSession), () => {});
    const pendingAfter = pending.rawState(pendingSession);
    assert.deepEqual(pendingAfter.jobs.find((job) => job.id === pendingJob.id),
      pendingJobBefore, 'operator身份仍待确认时不得迁移终态责任');
    assert.deepEqual(pendingAfter.outgoing[String(pendingPlan.fingerprint)],
      pendingOutgoingBefore, 'applicability未知时不得先写v1或删除旧证据');
    assert(pendingAfter.uncertain_events.includes('orphaned-operator-identity-barrier'));
    assert.equal(pending.postAttempts.length, 0);
    assert.equal(pending.modelRequests.length, 0);

    for (const [index, result] of ['not-human', 'human'].entries()) {
      const resolved = makeFixture('terminal-generic-operator-resolved-' + result);
      const session = 'session_terminal-generic-operator-resolved-' + result;
      const plan = { type: 'text', purpose: 'ai_text', ordinary: true, ai: true,
        content: clarification, fingerprint: 77620 + index };
      const answered = resolved.makeJob(session, 'terminal-generic-' + result, plan, {
        status: 'done', responsibility_status: 'answered_confirmed', response_generation: 0,
      });
      const outgoing = resolved.makeOutgoing(answered, clarification, 'sent');
      Object.assign(outgoing, { purpose: plan.purpose, message_type: plan.type,
        semantic_intent: 'answer', semantic_status: 'valid_answer', response_generation: 0,
        content_sha256: digest(canonical({ type: plan.type, content: plan.content })) });
      delete outgoing.body;
      const controlId = digest(session + '|operator-control');
      const control = resolved.makeJob(session, 'operator-control', null, {
        id: controlId, event: 'message:received', control: true, action: 'resolve_operator',
        status: 'failed', event_time: resolved.now() - 1000,
        responsibility_status: 'unresolved_failure', failure_code: 'operator_identity_pending',
        operator_resolution: { schema_version: 1, result, human_changed: false },
      });
      await resolved.seed(session, (state) => {
        state.jobs.push(answered, control);
        state.outgoing[String(plan.fingerprint)] = outgoing;
        state.uncertain_events.push(controlId);
      });
      resolved.restart();
      await resolved.runtime().transaction(resolved.key(session), () => {});
      let state = resolved.rawState(session);
      let migrated = state.jobs.find((job) => job.id === answered.id);
      let resolvedControl = state.jobs.find((job) => job.id === controlId);
      let receipt = state.outgoing[String(plan.fingerprint)];
      assert.deepEqual(state.uncertain_events, [], result);
      assert.equal(resolvedControl.status, 'done', result);
      assert.equal(resolvedControl.responsibility_status, 'control_handled', result);
      assert.equal(resolvedControl.operator_resolution.result, result);
      assert.equal(receipt.delivery_identity_version, 1, result);
      assert.equal(receipt.semantic_intent, 'non_answer', result);
      assert.equal(receipt.semantic_status, 'delivered_non_answer', result);
      assert.equal(receipt.receipt_current, result === 'not-human', result);
      assert.equal(receipt.receipt_state_change_reason,
        result === 'human' ? 'conversation_state_changed' : undefined, result);
      assert.equal(receipt.state_changed_before_receipt,
        result === 'human' ? true : undefined, result);
      assert.equal(migrated.status, 'failed', result);
      assert.equal(migrated.responsibility_status, 'unresolved_failure', result);
      assert.equal(migrated.failure_code, 'legacy_non_answer_requires_review', result);
      assert.equal(migrated.response_generation, 1, result);
      assert(migrated.data, result + ':旧问题责任必须保留');
      assert.equal(Object.hasOwn(migrated, 'plan'), false, result);
      assert.equal(state.mode, result === 'human' ? 'human' : 'ai', result);
      const receiptBeforeRepeat = structuredClone(receipt);
      await resolved.runtime().transaction(resolved.key(session), () => {});
      state = resolved.rawState(session);
      migrated = state.jobs.find((job) => job.id === answered.id);
      receipt = state.outgoing[String(plan.fingerprint)];
      assert.equal(migrated.response_generation, 1,
        result + ':屏障解除后的重复事务不得再次推进恢复代');
      assert.deepEqual(receipt, receiptBeforeRepeat,
        result + ':屏障解除后的重复事务不得再次改写冻结回执');
      assert.equal(resolved.postAttempts.length, 0, result);
      assert.equal(resolved.modelRequests.length, 0, result);
      assert.equal(resolved.sent.length, 0, result);
    }

    const silenceCases = [
      { label: 'human-reply', reason: 'human_reply', mode: 'human', generation: 3,
        resume_at: null, pause_reason: 'operator_reply' },
      { label: 'handoff-button', reason: 'human_handoff', mode: 'human', generation: 4,
        resume_at: 4102444800000, pause_reason: 'confirmed_handoff' },
      { label: 'global-disabled', reason: 'global_disabled', mode: 'ai', generation: 5,
        resume_at: null, pause_reason: '' },
    ];
    for (const [index, scenario] of silenceCases.entries()) {
      const silent = makeFixture('terminal-generic-intentional-silence-' + scenario.label);
      if (scenario.reason === 'global_disabled') silent.writeConfig('runtime', {
        schema_version: 2, enabled: false, revision: 2, applied_revision: 2,
      });
      if (scenario.reason === 'global_disabled') silent.publishCurrentMaterials();
      const silentSession = 'session_terminal-generic-intentional-silence-' + scenario.label;
      const silentPlan = { type: 'text', purpose: 'ai_text', ordinary: true, ai: true,
        content: clarification, fingerprint: 77592 + index };
      const silentJob = silent.makeJob(silentSession, 'terminal-generic-intentional-silence', silentPlan, {
        status: 'cancelled', responsibility_status: 'intentional_silence',
        responsibility_reason: scenario.reason, response_generation: 0, generation: scenario.generation,
      });
      const silentOutgoing = silent.makeOutgoing(silentJob, clarification, 'sent');
      Object.assign(silentOutgoing, { purpose: 'ai_text', message_type: 'text', semantic_intent: 'answer',
        semantic_status: 'valid_answer', response_generation: 0, generation: scenario.generation,
        content_sha256: digest(canonical({ type: 'text', content: clarification })) });
      delete silentOutgoing.body;
      await silent.seed(silentSession, (state) => {
        state.mode = scenario.mode; state.generation = scenario.generation;
        state.resume_at = scenario.resume_at; state.pause_reason = scenario.pause_reason;
        state.last_human_at = silent.now() - 1000; state.control_watermark = silent.now() - 1000;
        state.jobs.push(silentJob); state.outgoing[String(silentPlan.fingerprint)] = silentOutgoing;
      });
      const before = silent.rawState(silentSession);
      silent.restart(); assert.deepEqual(await silent.runtime().scan(), []);
      const after = silent.rawState(silentSession);
      const silentStored = after.jobs.find((job) => job.id === silentJob.id);
      assert.equal(silentStored.status, 'cancelled');
      assert.equal(silentStored.responsibility_status, 'intentional_silence');
      assert.equal(silentStored.responsibility_reason, scenario.reason);
      assert.equal(silentStored.response_generation, 0);
      assert.equal(Object.hasOwn(silentStored, 'legacy_non_answer_migrated'), false);
      for (const field of ['mode', 'generation', 'resume_at', 'pause_reason', 'last_human_at', 'control_watermark']) {
        assert.deepEqual(after[field], before[field], scenario.label + ' 不得被迁移改写会话控制字段 ' + field);
      }
      assert.equal(silent.postAttempts.length, 0); assert.equal(silent.modelRequests.length, 0);
    }
  });

  await test('F54 升级遗留的超龄 orphan unknown 不删除，标记可恢复故障并保留原发送事实', async () => {
    const f = makeFixture('aged-orphaned-outgoing-upgrade'), session = 'session_aged-orphaned-outgoing';
    const retention = 7 * 86400000;
    const fingerprints = { sending: 77301, unknown: 77302, young: 77303, linked: 77304, boundary: 77305 };
    const plans = Object.fromEntries(Object.entries(fingerprints).map(([name, fingerprint]) => [name,
      { type: 'text', purpose: 'keyword_reply', ordinary: true, content: '合成出站-' + name, fingerprint }]));
    const ghosts = {
      sending: f.makeJob(session, 'removed-sending', plans.sending),
      unknown: f.makeJob(session, 'removed-unknown', plans.unknown),
      young: f.makeJob(session, 'young-orphan', plans.young),
      boundary: f.makeJob(session, 'boundary-orphan', plans.boundary),
    };
    const linked = f.makeJob(session, 'still-linked', plans.linked, {
      received_at: f.now() - retention - 1000, retry_at: f.now() + 120000,
    });
    await f.seed(session, state => {
      // 模拟升级顺序：旧 runtime 已在七天清理中删除 job，却把其
      // sending/unknown 详情留下。未知是否送达不是普通日志，不能按年龄删除。
      state.jobs.push(linked, { ...linked, id: undefined, plan: undefined, status: 'done', received_at: f.now() });
      state.outgoing[String(fingerprints.sending)] = f.makeOutgoing(ghosts.sending, plans.sending.content, 'sending');
      state.outgoing[String(fingerprints.unknown)] = f.makeOutgoing(ghosts.unknown, plans.unknown.content, 'unknown');
      state.outgoing[String(fingerprints.young)] = f.makeOutgoing(ghosts.young, plans.young.content, 'sending');
      state.outgoing[String(fingerprints.linked)] = f.makeOutgoing(linked, plans.linked.content, 'unknown');
      state.outgoing[String(fingerprints.boundary)] = f.makeOutgoing(ghosts.boundary, plans.boundary.content, 'unknown');
      // undefined 不构成可证明的 ID 关联；旧版缺失 ID 仍必须按真正 orphan 处理。
      delete state.outgoing[String(fingerprints.unknown)].job_id;
      state.outgoing[String(fingerprints.sending)].created_at = f.now() - retention - 1000;
      state.outgoing[String(fingerprints.unknown)].created_at = f.now() - retention - 1000;
      state.outgoing[String(fingerprints.young)].created_at = f.now() - retention + 1000;
      state.outgoing[String(fingerprints.linked)].created_at = f.now() - retention - 1000;
      state.outgoing[String(fingerprints.boundary)].created_at = f.now() - retention;
    });
    for (const fingerprint of Object.values(fingerprints)) {
      const bucket = path.join(f.root, 'data/runtime', 'owned-' + f.key(session) + '-'
        + (fingerprint % 256).toString(16).padStart(2, '0') + '.json');
      fs.writeFileSync(bucket, JSON.stringify({ schema_version: 1, fingerprints: [String(fingerprint)] }), { mode: 0o600 });
    }

    f.restart();
    assert.deepEqual(await f.runtime().scan(), []);
    let stored = f.rawState(session);
    for (const name of ['sending', 'unknown']) {
      const record = stored.outgoing[String(fingerprints[name])];
      assert(record, '超龄未知回执必须保留');
      assert.equal(record.status, 'unknown');
      assert.equal(record.failure, 'orphaned_delivery_unresolved');
      assert.equal(record.recovery_deferred, true);
      assert.equal(record.delivery_uncertain, true);
      assert.equal(record.body.content, plans[name].content);
      assert(record.next_action_at > f.now());
    }
    assert.equal(stored.outgoing[String(fingerprints.young)].status, 'sending');
    assert.equal(stored.outgoing[String(fingerprints.linked)].status, 'unknown');
    assert.equal(stored.outgoing[String(fingerprints.boundary)].status, 'unknown');
    assert.equal(stored.jobs.some(job => job.id === linked.id), true);
    assert.equal(f.modelRequests.length, 0); assert.equal(f.postAttempts.length, 0); assert.equal(f.sent.length, 0);
    for (const fingerprint of Object.values(fingerprints)) {
      const bucket = path.join(f.root, 'data/runtime', 'owned-' + f.key(session) + '-'
        + (fingerprint % 256).toString(16).padStart(2, '0') + '.json');
      assert.deepEqual(JSON.parse(fs.readFileSync(bucket, 'utf8')).fingerprints, [String(fingerprint)]);
    }

    f.restart(); assert.deepEqual(await f.runtime().scan(), []);
    const accepted = await f.receive(f.event(session, '升级清理后的新问题'));
    assert.equal(accepted.accepted, true); assert.equal(accepted.route, 'process');
    f.restart();
    const scheduled = await f.runtime().scan();
    assert(scheduled.some(item => item.key === accepted.key && item.jobId === accepted.jobId));
    assert.equal((await f.runtime().process(accepted.key, accepted.jobId)).status, 'sent');
    stored = f.rawState(session);
    assert.equal(f.sent.length, 1); assert.equal(f.postAttempts.length, 1); assert.equal(f.modelRequests.length, 1);
    for (const name of ['sending', 'unknown']) {
      const record = stored.outgoing[String(fingerprints[name])];
      assert(record, '处理新问题不得顺带删除旧未知责任');
      assert.equal(record.status, 'unknown');
      assert.equal(record.failure, 'orphaned_delivery_unresolved');
      assert.equal(record.body.content, plans[name].content);
    }
    assert.equal(stored.outgoing[String(fingerprints.young)].status, 'sending');
    assert.equal(stored.outgoing[String(fingerprints.linked)].status, 'unknown');
    assert.equal(stored.outgoing[String(fingerprints.boundary)].status, 'unknown');
  });

  await test('F55 旧机械答复双重负查后停止可见出站，原问题持久等待技术恢复', async () => {
    const f = makeFixture('mechanical-cached-two-attempts'), session = 'session_mechanical-two-attempts';
    const plan = { type: 'text', purpose: 'ai_text', ordinary: true, ai: true,
      content: '系统正在升级，请稍后再试。', fingerprint: 77311 };
    const job = f.makeJob(session, 'unknown-two-attempts', plan);
    f.legacyUnpooled(job);
    const outgoing = f.makeOutgoing(job, plan.content, 'unknown');
    outgoing.attempts = 2;
    await f.seed(session, state => { state.jobs.push(job); state.outgoing[String(plan.fingerprint)] = outgoing; });
    f.modes.exactStatus = 404; f.restart();

    assert.equal((await f.runtime().process(f.key(session), job.id)).status, 'retry');
    assert.equal(f.exactRequests.length, 1); assert.equal(f.postAttempts.length, 0);
    f.advance(5000); f.restart();
    assert.equal((await f.runtime().process(f.key(session), job.id)).status, 'retry');
    let stored = f.rawState(session);
    assert.equal(f.exactRequests.length, 2); assert.equal(f.postAttempts.length, 0);
    assert.equal(stored.outgoing[String(plan.fingerprint)].status, 'cancelled');
    assert.equal(stored.outgoing[String(plan.fingerprint)].cancellation_reason, 'visitor_output_normalized');
    let unresolved = stored.jobs.find(item => item.id === job.id);
    assert.equal(unresolved.plan.purpose, 'technical_unresolved');
    assert.equal(unresolved.plan.type, 'internal');
    assert.equal(unresolved.plan.content, '');
    assert.equal(unresolved.data.content, job.data.content);
    assert.equal(unresolved.deferred_configuration, undefined);
    assert.equal(unresolved.inference, undefined);

    assert(Number.isFinite(unresolved.retry_at) && unresolved.retry_at > f.now());
    f.advance(unresolved.retry_at - f.now()); f.restart();
    assert.equal((await f.runtime().process(f.key(session), job.id)).status, 'unresolved');
    stored = f.rawState(session);
    unresolved = stored.jobs.find(item => item.id === job.id);
    assert.equal(unresolved.status, 'received');
    assert.equal(unresolved.responsibility_status, 'unresolved_failure');
    assert.equal(unresolved.failure_code, 'visitor_output_rejected');
    assert.equal(unresolved.data.content, job.data.content);
    assert.equal(f.postAttempts.length, 0); assert.equal(f.sent.length, 0);

    const stale = makeFixture('mechanical-cached-two-attempts-stale'), staleSession = 'session_mechanical-two-attempts-stale';
    const stalePlan = { ...plan, fingerprint: 77312 };
    const staleJob = stale.legacyUnpooled(stale.makeJob(staleSession,
      'unknown-two-attempts-stale', stalePlan, { received_at: stale.now() - 600000 }));
    const staleOutgoing = stale.makeOutgoing(staleJob, stalePlan.content, 'unknown');
    staleOutgoing.attempts = 2; staleOutgoing.created_at = stale.now() - 590000;
    await stale.seed(staleSession, state => { state.jobs.push(staleJob); state.outgoing[String(stalePlan.fingerprint)] = staleOutgoing; });
    stale.modes.exactStatus = 404; stale.restart();
    assert.equal((await stale.runtime().process(stale.key(staleSession), staleJob.id)).status, 'retry');
    stale.advance(5000); stale.restart();
    assert.equal((await stale.runtime().process(stale.key(staleSession), staleJob.id)).status, 'retry');
    stored = stale.rawState(staleSession);
    unresolved = stored.jobs.find(item => item.id === staleJob.id);
    assert.equal(stored.outgoing[String(stalePlan.fingerprint)].status, 'cancelled');
    assert.equal(unresolved.status, 'received');
    assert.equal(unresolved.responsibility_status, 'unresolved_failure');
    assert.equal(unresolved.plan.purpose, 'technical_unresolved');
    assert.equal(unresolved.plan.content, '');
    assert.equal(unresolved.data.content, staleJob.data.content);
    assert.equal(unresolved.deferred_configuration, undefined);
    assert.equal(unresolved.inference, undefined);
    assert.equal(stale.postAttempts.length, 0); assert.equal(stale.sent.length, 0);
  });

  await test('F56 两次发送失败可在第三次恢复，三次后只对账并保留原责任', async () => {
    const recovered = makeFixture('crisp-post-third-attempt-recovery'), recoveredSession = 'session_crisp-third-recovery';
    const keyword = recovered.readConfig('keyword');
    keyword.rules.unshift({ id: 'synthetic-third-post', name: '第三次发送恢复', enabled: true, match_mode: 'exact',
      keywords: ['发送恢复问题'], exclude_keywords: [], priority: 1000, action: 'reply', text: '发送恢复后的唯一回复', cooldown_seconds: 0 });
    recovered.writeConfig('keyword', keyword);
    recovered.publishCurrentMaterials();
    recovered.modes.exactStatus = 404;
    recovered.modes.crispDropBeforeAccept = true;
    recovered.modes.onCrispPost = async () => {
      if (recovered.postAttempts.length >= 2) recovered.modes.crispDropBeforeAccept = false;
    };
    recovered.restart();
    const event = recovered.event(recoveredSession, '发送恢复问题');
    const accepted = await recovered.receive(event);
    assert.equal(accepted.accepted, true); assert.equal(accepted.route, 'process');
    assert.equal((await recovered.runtime().process(accepted.key, accepted.jobId)).status, 'retry');
    assert.equal(recovered.postAttempts.length, 1); assert.equal(recovered.sent.length, 0);

    recovered.advance(5000); recovered.restart();
    assert.equal((await recovered.runtime().process(accepted.key, accepted.jobId)).status, 'retry');
    assert.equal(recovered.exactRequests.length, 0); assert.equal(recovered.postAttempts.length, 1);
    recovered.advance(5000); recovered.restart();
    assert.equal((await recovered.runtime().process(accepted.key, accepted.jobId)).status, 'retry');
    assert.equal(recovered.exactRequests.length, 1); assert.equal(recovered.postAttempts.length, 1);
    recovered.advance(5000); recovered.restart();
    assert.equal((await recovered.runtime().process(accepted.key, accepted.jobId)).status, 'retry');
    assert.equal(recovered.exactRequests.length, 2); assert.equal(recovered.postAttempts.length, 2);
    recovered.advance(5000); recovered.restart();
    assert.equal((await recovered.runtime().process(accepted.key, accepted.jobId)).status, 'retry');
    assert.equal(recovered.exactRequests.length, 3); assert.equal(recovered.postAttempts.length, 2);
    recovered.advance(5000); recovered.restart();
    assert.equal((await recovered.runtime().process(accepted.key, accepted.jobId)).status, 'sent');
    assert.equal(recovered.exactRequests.length, 4); assert.equal(recovered.postAttempts.length, 3);
    assert.equal(new Set(recovered.postAttempts.map(item => String(item.fingerprint))).size, 1);
    assert.equal(recovered.sent.length, 1); assert.equal(recovered.sent[0].content, '发送恢复后的唯一回复');
    assert.equal((await recovered.receive(event)).reason, '重复事件已忽略');
    assert.equal((await recovered.runtime().process(accepted.key, accepted.jobId)).status, 'idle');
    assert.equal(recovered.postAttempts.length, 3); assert.equal(recovered.sent.length, 1);

    const bounded = makeFixture('crisp-post-maximum-bounded'), boundedSession = 'session_crisp-post-bounded';
    const boundedPlan = { type: 'text', purpose: 'keyword_reply', ordinary: true, content: '不得无限重发', fingerprint: 77321 };
    const boundedJob = bounded.makeJob(boundedSession, 'maximum-post-attempts', boundedPlan);
    const boundedOutgoing = bounded.makeOutgoing(boundedJob, boundedPlan.content, 'unknown');
    boundedOutgoing.attempts = 3;
    await bounded.seed(boundedSession, state => { state.jobs.push(boundedJob); state.outgoing[String(boundedPlan.fingerprint)] = boundedOutgoing; });
    bounded.modes.exactStatus = 404; bounded.restart();
    assert.equal((await bounded.runtime().process(bounded.key(boundedSession), boundedJob.id)).status, 'retry');
    bounded.advance(5000); bounded.restart();
    assert.equal((await bounded.runtime().process(bounded.key(boundedSession), boundedJob.id)).status, 'retry');
    assert.equal(bounded.exactRequests.length, 2); assert.equal(bounded.postAttempts.length, 0);
    bounded.advance(300001); bounded.restart();
    assert.equal((await bounded.runtime().process(bounded.key(boundedSession), boundedJob.id)).status, 'retry');
    let stored = bounded.rawState(boundedSession);
    let unresolved = stored.jobs.find(item => item.id === boundedJob.id);
    let record = stored.outgoing[String(boundedPlan.fingerprint)];
    assert.equal(unresolved.status, 'received');
    assert.equal(unresolved.responsibility_status, 'unresolved_failure');
    assert.equal(unresolved.plan.content, boundedPlan.content);
    assert.equal(unresolved.data.content, boundedJob.data.content);
    assert.equal(record.status, 'unknown');
    assert.equal(record.failure, 'post_budget_exhausted');
    assert.equal(record.recovery_deferred, true);
    assert.equal(record.attempts, 3);
    assert.equal(record.body.content, boundedPlan.content);
    assert.equal(bounded.postAttempts.length, 0); assert.equal(bounded.sent.length, 0);

    bounded.advance(300001); bounded.restart();
    assert.equal((await bounded.runtime().process(bounded.key(boundedSession), boundedJob.id)).status, 'retry');
    stored = bounded.rawState(boundedSession);
    unresolved = stored.jobs.find(item => item.id === boundedJob.id);
    record = stored.outgoing[String(boundedPlan.fingerprint)];
    assert.equal(unresolved.status, 'received');
    assert.equal(unresolved.plan.content, boundedPlan.content);
    assert.equal(unresolved.data.content, boundedJob.data.content);
    assert.equal(record.status, 'unknown');
    assert.equal(record.body.content, boundedPlan.content);
    assert.equal(record.attempts, 3);
    assert.equal(bounded.postAttempts.length, 0, '三次 POST 后只允许对账，绝不能第四次发送');
    assert.equal(bounded.sent.length, 0);
  });

  await test('F57 同 fingerprint 但 from/type/content 不一致不能确认为原出站回执', async () => {
    const variants = [
      ['from', { from: 'user' }],
      ['type', { type: 'picker', content: { id: 'synthetic-other-picker', text: '其它选择',
        choices: [{ value: 'other', label: '其它', selected: false }] } }],
      ['content', { content: '同 fingerprint 的另一份正文' }],
    ];
    for (const [index, [variant, mismatch]] of variants.entries()) {
      const f = makeFixture('receipt-identity-mismatch-' + variant);
      const session = 'session_receipt-mismatch-' + variant;
      const fingerprint = 77400 + index;
      const plan = { type: 'text', purpose: 'keyword_reply', ordinary: true,
        content: '原出站正文必须按完整身份核对', fingerprint };
      const job = f.makeJob(session, 'receipt-identity-' + variant, plan);
      const outgoing = f.makeOutgoing(job, plan.content, 'unknown');
      await f.seed(session, (state) => {
        state.jobs.push(job);
        state.outgoing[String(fingerprint)] = outgoing;
      });
      const wrongReceipt = { ...outgoing.body, ...mismatch, fingerprint,
        timestamp: f.now() - 1000 };
      f.histories.set(session, [wrongReceipt]);
      f.restart();

      assert.equal((await f.runtime().process(f.key(session), job.id)).status, 'retry');
      const stored = f.rawState(session);
      const record = stored.outgoing[String(fingerprint)];
      assert.equal(record.status, 'unknown', variant + ' 不一致时必须继续保留未知回执');
      assert.equal(record.reconcile_misses ?? 0, 0,
        variant + ' 不一致的 HTTP 200 不能充当不存在的阴性证据');
      assert.equal(record.body.content, plan.content);
      assert.equal(stored.jobs.find((item) => item.id === job.id).status, 'received');
      assert.equal(f.exactRequests.length, 1, '列表同 fingerprint 不足以确认，必须精确核对');
      assert.equal(f.postAttempts.length, 0); assert.equal(f.sent.length, 0);
    }
  });

  await test('F58 legacy sent 丢失 body、计划和冻结身份时保持 identity unresolved', async () => {
    const f = makeFixture('legacy-sent-semantic-unknown');
    const session = 'session_legacy-sent-unknown';
    const fingerprint = 77410;
    const plan = { type: 'text', purpose: 'ai_text', ordinary: true, ai: true,
      content: clarification, fingerprint };
    const job = f.makeJob(session, 'legacy-sent-no-evidence', plan);
    const outgoing = f.makeOutgoing(job, plan.content, 'sent');
    delete job.plan;
    delete outgoing.body;
    const originalOutgoing = structuredClone(outgoing);
    await f.seed(session, (state) => {
      state.jobs.push(job);
      state.outgoing[String(fingerprint)] = outgoing;
    });
    f.restart();

    assert.equal((await f.runtime().process(f.key(session), job.id)).status,
      'delivery_identity_unresolved');
    const stored = f.rawState(session);
    const unresolved = stored.jobs.find((item) => item.id === job.id);
    assert.deepEqual(stored.outgoing[String(fingerprint)], originalOutgoing,
      '没有正文、计划或冻结身份时不得用当前代码补造 sent 语义');
    assert.equal(unresolved.status, 'received');
    assert.equal(unresolved.responsibility_status, 'unresolved_failure');
    assert.equal(unresolved.failure_code, 'delivery_identity_unresolved');
    assert(unresolved.data, '身份未知时必须保留原始访客责任供管理员核查');
    assert.equal(f.events().filter((event) => event.type === 'ai_reply').length, 0);
    assert.equal(f.postAttempts.length, 0); assert.equal(f.sent.length, 0);

    const planOnly = makeFixture('legacy-sent-plan-only-stale-positive');
    const planOnlySession = 'session_legacy-sent-plan-only';
    const planOnlyFingerprint = 77411;
    const planOnlyPlan = { type: 'text', purpose: 'ai_text', ordinary: true, ai: true,
      content: clarification, fingerprint: planOnlyFingerprint };
    const planOnlyJob = planOnly.makeJob(planOnlySession, 'legacy-sent-plan-only', planOnlyPlan);
    const planOnlyOutgoing = planOnly.makeOutgoing(planOnlyJob, planOnlyPlan.content, 'sent');
    Object.assign(planOnlyOutgoing, { semantic_intent: 'answer', semantic_status: 'valid_answer',
      purpose: 'ai_text', message_type: 'text' });
    delete planOnlyOutgoing.body;
    const planOnlyOriginal = structuredClone(planOnlyOutgoing);
    await planOnly.seed(planOnlySession, (state) => {
      state.jobs.push(planOnlyJob);
      state.outgoing[String(planOnlyFingerprint)] = planOnlyOutgoing;
    });
    planOnly.restart();
    assert.equal((await planOnly.runtime().process(planOnly.key(planOnlySession), planOnlyJob.id)).status,
      'delivery_identity_unresolved');
    const planOnlyStored = planOnly.rawState(planOnlySession);
    assert.deepEqual(planOnlyStored.outgoing[String(planOnlyFingerprint)], planOnlyOriginal,
      '没有冻结正文摘要时，不得用当前可变 plan 反推旧 sent 的实际语义');
    const planOnlyUnresolved = planOnlyStored.jobs.find((item) => item.id === planOnlyJob.id);
    assert.equal(planOnlyUnresolved.status, 'received');
    assert.equal(planOnlyUnresolved.responsibility_status, 'unresolved_failure');
    assert.equal(planOnlyUnresolved.failure_code, 'delivery_identity_unresolved');
    assert.equal(planOnly.postAttempts.length, 0); assert.equal(planOnly.sent.length, 0);
  });

  await test('F59 首次 receipt_current 冻结后不被后续人工或配置状态追溯改判', async () => {
    const appliedConfiguration = (fixture, revision) => {
      const runtime = { ...fixture.readConfig('runtime'), enabled: true, revision,
        applied_revision: revision };
      fixture.writeConfig('runtime', runtime);
      const materials = fixture.publishCurrentMaterials();
      fixture.restart();
      return structuredClone(materials.configuration);
    };

    const current = makeFixture('receipt-current-frozen-true');
    appliedConfiguration(current, 1);
    const currentSession = 'session_receipt-current-true';
    const currentPlan = { type: 'text', purpose: 'keyword_reply', ordinary: true,
      content: '首次确认时仍有效的业务答复', fingerprint: 77420 };
    const currentJob = current.makeJob(currentSession, 'receipt-current-true', currentPlan);
    await current.seed(currentSession, (state) => state.jobs.push(currentJob));
    current.restart();
    assert.equal((await current.runtime().process(current.key(currentSession), currentJob.id)).status, 'sent');
    let stored = current.rawState(currentSession);
    assert.equal(stored.outgoing['77420'].receipt_current, true);
    assert.equal(stored.jobs.find((item) => item.id === currentJob.id).responsibility_status,
      'answered_confirmed');

    const human = { website_id: current.env.CRISP_WEBSITE_ID, event: 'message:received',
      timestamp: current.now(), data: { session_id: currentSession, from: 'operator', type: 'text',
        content: '后续真人已接管', fingerprint: 77421, automated: false, timestamp: current.now() } };
    assert.equal((await current.receive(human)).accepted, true);
    current.restart();
    stored = current.rawState(currentSession);
    assert.equal(stored.mode, 'human');
    assert.equal(stored.outgoing['77420'].receipt_current, true,
      '后续真人状态不能把首次有效回执追溯改成 state change');
    assert.equal(stored.jobs.find((item) => item.id === currentJob.id).responsibility_status,
      'answered_confirmed');

    const stale = makeFixture('receipt-current-frozen-false');
    const initialConfiguration = appliedConfiguration(stale, 1);
    const staleSession = 'session_receipt-current-false';
    const stalePlan = { type: 'text', purpose: 'keyword_reply', ordinary: true,
      content: '配置换代边界上的合成答复', fingerprint: 77422 };
    const staleJob = stale.makeJob(staleSession, 'receipt-current-false', stalePlan);
    await stale.seed(staleSession, (state) => state.jobs.push(staleJob));
    stale.modes.onCrispPost = async () => {
      const changed = structuredClone(initialConfiguration);
      // 位数变化也使投影 stat 身份在低时间分辨率文件系统上必然改变。
      changed.runtime.revision = 12; changed.runtime.applied_revision = 12;
      stale.writeConfig('runtime', changed.runtime);
      stale.publishCurrentMaterials();
    };
    stale.restart();
    assert.equal((await stale.runtime().process(stale.key(staleSession), staleJob.id)).status,
      'dispatched_after_cancel');
    stored = stale.rawState(staleSession);
    assert.equal(stored.outgoing['77422'].receipt_current, false);
    assert.equal(stored.jobs.find((item) => item.id === staleJob.id).failure_code,
      'delivery_after_state_change');

    const later = structuredClone(initialConfiguration);
    later.runtime.revision = 13; later.runtime.applied_revision = 13;
    stale.writeConfig('runtime', later.runtime);
    stale.publishCurrentMaterials(); stale.restart();
    stored = stale.rawState(staleSession);
    assert.equal(stored.outgoing['77422'].receipt_current, false,
      '后续配置重新有效也不能把首次失效回执追溯改成正常回答');
    assert.equal(stored.jobs.find((item) => item.id === staleJob.id).responsibility_status,
      'unresolved_failure');
    assert.equal(stale.postAttempts.length, 1); assert.equal(stale.sent.length, 1);
  });

  await test('F60 普通 catchup duplicate 200 的 durable identity 不匹配时不推进水位', async () => {
    const f = makeFixture('catchup-duplicate-identity-mismatch');
    assert.equal((await f.runtime().catchup()).status, 'bootstrap');
    const catchupFile = path.join(f.root, 'data/runtime/crisp-rest-catchup.json');
    const baseline = JSON.parse(fs.readFileSync(catchupFile, 'utf8'));
    f.advance(60001);
    const session = 'session_catchup-identity-mismatch';
    const fingerprint = 77430;
    const eventTime = f.now();
    const candidate = { website_id: f.env.CRISP_WEBSITE_ID, session_id: session,
      from: 'user', type: 'text', content: 'REST 当前观察到的合成问题', fingerprint,
      timestamp: eventTime };
    f.catchupConversationPages.set(1, [{ website_id: f.env.CRISP_WEBSITE_ID,
      session_id: session, updated_at: eventTime }]);
    f.histories.set(session, [candidate]);

    const staleData = { session_id: session, from: 'user', type: 'text',
      content: '同 fingerprint 的另一份已持久正文', fingerprint, timestamp: eventTime };
    const duplicateId = digest(['message:send', String(fingerprint), ''].join('|'));
    const staleJob = f.makeJob(session, 'catchup-stale-identity', null, {
      id: duplicateId, event: 'message:send', data: staleData, event_time: eventTime,
      responsibility_status: 'pending', covered_message_ids: [String(fingerprint)],
    });
    await f.seed(session, (state) => state.jobs.push(staleJob));
    f.restart();

    const result = await f.runtime().catchup();
    assert.equal(result.status, 'warning');
    assert.equal(result.error_code, 'local_persistence_failed');
    const progress = JSON.parse(fs.readFileSync(catchupFile, 'utf8'));
    assert.equal(progress.watermark, baseline.watermark,
      'duplicate 200 后未证实同一 durable identity 时不得推进全局水位');
    assert(progress.window, '未完成的固定 catchup 窗口必须保留供恢复');
    const stored = f.rawState(session);
    assert.equal(stored.jobs.filter((item) => item.id === duplicateId).length, 1);
    assert.equal(stored.jobs.find((item) => item.id === duplicateId).data.content,
      staleData.content, '重复 ACK 不能覆盖既有不同身份责任');
    assert(f.catchupRequests.some((request) => request.type === 'messages'));
    assert.equal(f.postAttempts.length, 0); assert.equal(f.sent.length, 0);
  });

  await test('F61 缺 timestamp 经精确回查后按可信时间重算 input identity', async () => {
    const f = makeFixture('event-time-recomputes-input-identity');
    const configuration = Object.fromEntries(['runtime', 'handoff', 'keyword', 'menu', 'tags', 'feedback']
      .map((name) => [name, f.readConfig(name)]));
    f.writeAppliedMaterials(configuration);
    fs.writeFileSync(path.join(f.root, 'config/provider-pool-transaction.json'), '{}', { mode: 0o600 });
    f.restart();
    const session = 'session_event-time-rehash';
    const fingerprint = 77440;
    const content = '缺少时间但正文身份稳定的合成问题';
    const accepted = await f.receive({ website_id: f.env.CRISP_WEBSITE_ID,
      event: 'message:send', data: { session_id: session, from: 'user', type: 'text',
        content, fingerprint } });
    assert.equal(accepted.accepted, true); assert.equal(accepted.route, 'process');
    let stored = f.rawState(session).jobs.find((item) => item.id === accepted.jobId);
    const provisionalIdentity = stored.input_identity_sha256;
    assert.equal(stored.event_time_unverified, true);

    const exactTime = f.now() - 1000;
    f.histories.set(session, [{ website_id: f.env.CRISP_WEBSITE_ID, session_id: session,
      from: 'user', type: 'text', content, fingerprint, timestamp: exactTime }]);
    assert.equal((await f.runtime().process(accepted.key, accepted.jobId)).status, 'deferred');
    stored = f.rawState(session).jobs.find((item) => item.id === accepted.jobId);
    const expectedIdentity = digest(canonical({ website_id: f.env.CRISP_WEBSITE_ID,
      session_id: session, event: 'message:send', fingerprint: String(fingerprint),
      from: 'user', type: 'text', event_time: exactTime, content }));
    assert.notEqual(stored.input_identity_sha256, provisionalIdentity,
      '临时本机时间生成的 identity 不能在精确时间确认后继续沿用');
    assert.equal(stored.input_identity_sha256, expectedIdentity);
    assert.equal(stored.event_time, exactTime);
    assert.equal(stored.event_time_source, 'crisp_exact');
    assert.equal(stored.event_time_unverified, undefined);
    assert.equal(stored.data.timestamp, exactTime);
    assert.equal(f.exactRequests.length, 1);
    assert.equal(f.postAttempts.length, 0); assert.equal(f.sent.length, 0);
  });

  await test('F62 畸形结构化 catchup 消息逐条 quarantine，不进入知识或应答链', async () => {
    const f = makeFixture('catchup-malformed-structured-content');
    assert.equal((await f.runtime().catchup()).status, 'bootstrap');
    f.advance(60001);
    const session = 'session_catchup-structured-invalid';
    const types = ['file', 'audio', 'animation', 'picker', 'field', 'carousel'];
    const messages = types.map((type, index) => ({ website_id: f.env.CRISP_WEBSITE_ID,
      session_id: session, from: 'user', type, content: {}, fingerprint: 77450 + index,
      timestamp: f.now() }));
    f.catchupConversationPages.set(1, [{ website_id: f.env.CRISP_WEBSITE_ID,
      session_id: session, updated_at: f.now() }]);
    f.histories.set(session, messages);

    const result = await f.runtime().catchup();
    assert.equal(result.status, 'warning');
    const catchupFile = path.join(f.root, 'data/runtime/crisp-rest-catchup.json');
    const progress = JSON.parse(fs.readFileSync(catchupFile, 'utf8'));
    assert.equal(progress.unresolved_messages.length, types.length);
    assert.deepEqual(progress.unresolved_messages.map((item) => item.type).sort(), types.slice().sort());
    assert(progress.unresolved_messages.every((item) => item.reason === 'invalid_content'));
    assert(progress.unresolved_messages.every((item) => item.next_retry_at > f.now()),
      '有合法 fingerprint 的畸形结构必须保留可精确核查的持久责任');
    const sessionFile = path.join(f.root, 'data/runtime/session-' + f.key(session) + '.json');
    if (fs.existsSync(sessionFile)) {
      const quarantined = JSON.parse(fs.readFileSync(sessionFile, 'utf8'));
      assert.deepEqual(quarantined.jobs || [], [], '畸形结构不得进入普通应答队列');
      assert.deepEqual(quarantined.outgoing || {}, {}, '畸形结构不得创建出站责任');
      assert.deepEqual(quarantined.offers || {}, {}, '畸形结构不得创建业务控制卡片');
      assert.deepEqual(quarantined.uncertain_events || [], [], '畸形访客正文不得伪装成操作者屏障');
      assert.deepEqual(quarantined.image_context || {}, {}, '畸形结构不得写入图片上下文');
      assert.equal(quarantined.worker ?? null, null);
      assert.equal(quarantined.pending_feedback ?? null, null);
      assert.equal(quarantined.mode, 'ai'); assert.equal(quarantined.generation, 0);
    }
    assert.equal(f.modelRequests.length, 0); assert.equal(f.postAttempts.length, 0);
    assert.equal(f.sent.length, 0);
  });

  await test('F63 语义未知回执超过日志保留期仍保留防重责任', async () => {
    const f = makeFixture('semantic-unknown-retention');
    const session = 'session_semantic-unknown-retention';
    const fingerprint = 77500;
    const job = f.makeJob(session, 'semantic-unknown-retention', null, {
      received_at: f.now() - 8 * 86400000,
      responsibility_status: 'unresolved_failure', failure_code: 'delivery_semantic_unknown',
      retry_at: f.now() + 300000,
    });
    await f.seed(session, (state) => {
      state.jobs.push(job);
      state.outgoing[String(fingerprint)] = {
        status: 'sent', created_at: f.now() - 8 * 86400000, sent_at: f.now() - 8 * 86400000,
        job_id: job.id, generation: 0, response_generation: 0,
        message_type: 'text', semantic_intent: 'unknown', semantic_status: 'semantic_unknown',
        content_sha256: digest('synthetic-unknown-receipt'), receipt_current: null,
        receipt_identity_unbound: true, resend_forbidden: true,
      };
    });
    f.restart();
    await f.runtime().transaction(f.key(session), () => {});
    const stored = f.rawState(session);
    assert(stored.jobs.some((item) => item.id === job.id), '未解决应答责任不得按日志期限删除');
    assert(stored.outgoing[String(fingerprint)], '语义未知防重回执不得按日志期限删除');
    assert.equal(stored.outgoing[String(fingerprint)].semantic_status, 'semantic_unknown');
    assert.equal(f.postAttempts.length, 0); assert.equal(f.sent.length, 0);
  });

  await test('F64 frozen welcome 回执恢复使用原计划且菜单补发幂等', async () => {
    const f = makeFixture('frozen-welcome-menu');
    const session = 'session_frozen-welcome-menu';
    const fingerprint = 77510;
    const plan = { type: 'text', purpose: 'welcome', ordinary: true, welcome: true,
      welcome_menu: true, content: '欢迎使用合成站点。', fingerprint };
    const job = f.makeJob(session, 'frozen-welcome-menu', plan);
    const outgoing = f.makeOutgoing(job, plan.content, 'sent');
    outgoing.response_generation = 0;
    outgoing.purpose = plan.purpose;
    outgoing.message_type = plan.type;
    outgoing.semantic_intent = 'control';
    outgoing.semantic_status = 'control_delivered';
    outgoing.content_sha256 = digest(canonical({ type: plan.type, content: plan.content }));
    outgoing.delivery_identity_version = 1;
    outgoing.receipt_confirmed_at = f.now() - 9000;
    outgoing.receipt_current = true;
    delete outgoing.body;
    await f.seed(session, (state) => { state.jobs.push(job); state.outgoing[String(fingerprint)] = outgoing; });
    f.restart();
    assert.equal((await f.runtime().process(f.key(session), job.id)).status, 'sent');
    let stored = f.rawState(session);
    assert.equal(stored.jobs.find((item) => item.id === job.id).responsibility_status, 'control_handled');
    const menuId = digest(job.id + '|welcome_menu');
    assert.equal(stored.jobs.filter((item) => item.id === menuId).length, 1);
    const menuResult = await f.runtime().process(f.key(session), job.id);
    assert.equal(menuResult.status, 'sent',
      '欢迎回执完成后下一轮应消费同会话已创建的菜单任务');
    assert.equal(menuResult.jobId, menuId, '显式请求旧完成任务时仍只能选择唯一到期菜单任务');
    stored = f.rawState(session);
    assert.equal(stored.jobs.filter((item) => item.id === menuId).length, 1, '恢复不得重复创建欢迎菜单任务');
    const menuOutgoing = Object.entries(stored.outgoing)
      .filter(([, record]) => record?.job_id === menuId);
    assert.equal(menuOutgoing.length, 1);
    assert.equal(menuOutgoing[0][1].status, 'sent');
    assert.equal((await f.runtime().process(f.key(session), job.id)).status, 'idle');
    assert.equal(f.postAttempts.length, 1); assert.equal(f.sent.length, 1);
    assert.equal(f.sent[0].type, 'picker');
    assert.equal(String(f.sent[0].fingerprint), menuOutgoing[0][0]);
  });

  await test('F65 orphan 多回执逐条核验，部分命中不能取消另一条 unknown', async () => {
    const f = makeFixture('orphan-partial-receipts');
    const session = 'session_orphan-partial-receipts';
    const job = f.makeJob(session, 'orphan-partial-receipts', null, { received_at: f.now() - 20000 });
    const plans = [
      { type: 'text', purpose: 'ai_text', ordinary: true, ai: true, content: clarification, fingerprint: 77520 },
      { type: 'text', purpose: 'ai_text', ordinary: true, ai: true, content: '另一条仍待核验的正文', fingerprint: 77521 },
    ];
    const records = plans.map((plan) => {
      const currentJob = { ...job, plan };
      const record = f.makeOutgoing(currentJob, plan.content, 'unknown');
      record.created_at = f.now() - 15000;
      record.purpose = plan.purpose;
      record.response_generation = 0;
      return record;
    });
    await f.seed(session, (state) => {
      state.jobs.push(job);
      state.outgoing[String(plans[0].fingerprint)] = records[0];
      state.outgoing[String(plans[1].fingerprint)] = records[1];
    });
    f.histories.set(session, [{ ...records[0].body, timestamp: f.now() - 1000 }]);
    f.modes.exactStatus = 404; f.restart();
    assert.equal((await f.runtime().process(f.key(session), job.id)).status, 'retry');
    let stored = f.rawState(session);
    assert.equal(stored.outgoing[String(plans[0].fingerprint)].status, 'unknown',
      '缺 plan/语义 producer 的精确正文只能保留为语义未知，不能凭 generic 文案猜成已回答');
    assert.equal(stored.outgoing[String(plans[1].fingerprint)].status, 'unknown',
      '另一条未知回执不能因首条命中而被取消');
    assert.equal(stored.outgoing[String(plans[1].fingerprint)].reconcile_misses, 1);
    assert.equal(stored.jobs.find((item) => item.id === job.id)
      .delivery_receipt_unknown?.semantic_status, 'semantic_unknown');
    assert.equal(f.postAttempts.length, 0);
    f.advance(5000); f.restart(); await f.runtime().scan();
    assert.equal((await f.runtime().process(f.key(session), job.id)).status,
      'delivery_identity_unresolved');
    stored = f.rawState(session);
    assert(stored.outgoing[String(plans[0].fingerprint)]);
    assert.equal(stored.outgoing[String(plans[1].fingerprint)], undefined,
      '另一条出站已经过两次间隔精确404，应独立收敛为未送达而不是永久伪 pending');
    assert.equal(f.exactRequests.filter((item) =>
      item.fingerprint === String(plans[1].fingerprint)).length, 2,
    '第二条 fingerprint 必须独立完成两次负查');
    const unresolved = stored.jobs.find((item) => item.id === job.id);
    assert.equal(unresolved.responsibility_status, 'unresolved_failure');
    assert.equal(unresolved.failure_code, 'delivery_identity_unresolved');
    assert.equal(unresolved.response_generation ?? 0, 0);
    assert(unresolved.data); assert.equal(f.postAttempts.length, 0); assert.equal(f.sent.length, 0);
  });

  await test('F65b identity-unresolved marker 指纹不匹配时不得误收敛', async () => {
    const f = makeFixture('identity-marker-fingerprint-mismatch');
    const session = 'session_identity-marker-fingerprint-mismatch';
    const fingerprint = 77522;
    const plan = { type: 'text', purpose: 'ai_text', ordinary: true, ai: true,
      content: '仍需核对的原始出站正文', fingerprint };
    const job = f.makeJob(session, 'identity-marker-fingerprint-mismatch', null,
      { received_at: f.now() - 20000 });
    const outgoing = f.makeOutgoing({ ...job, plan }, plan.content, 'unknown');
    Object.assign(outgoing, { purpose: plan.purpose, response_generation: 0 });
    job.delivery_receipt_unknown = {
      fingerprint: String(fingerprint + 1), response_generation: 0,
      message_type: 'text', content_sha256: digest(canonical({ type: 'text', content: plan.content })),
      semantic_status: 'semantic_unknown', identity_status: 'unresolved', receipt_current: null,
      observed_at: f.now(), resend_forbidden: true,
    };
    await f.seed(session, (state) => {
      state.jobs.push(job);
      state.outgoing[String(fingerprint)] = outgoing;
    });
    f.modes.exactFailure = true;
    f.restart();
    assert.equal((await f.runtime().process(f.key(session), job.id)).status, 'retry');
    assert.equal(f.exactRequests.length, 1,
      '错指纹 marker 不能跳过对原始 fingerprint 的只读对账');
    const stored = f.rawState(session).jobs.find((entry) => entry.id === job.id);
    assert.notEqual(stored.failure_code, 'delivery_identity_unresolved');
    assert(f.rawState(session).outgoing[String(fingerprint)], '原始 unknown 责任必须保留');
    assert.equal(f.postAttempts.length, 0);
  });

  await test('F65c identity marker 绑定原outgoing整体，同正文替换record不得借旧标记收敛', async () => {
    const fingerprint = 77523;
    const plan = { type: 'text', purpose: 'ai_text', ordinary: true, ai: true,
      content: '远端已存在但本地语义producer不完整的正文', fingerprint };
    const markedFixture = async (label) => {
      const f = makeFixture('identity-marker-record-binding-' + label);
      const session = 'session_identity-marker-record-binding-' + label;
      const job = f.makeJob(session, 'identity-marker-record-binding-' + label, null,
        { received_at: f.now() - 20000 });
      const outgoing = f.makeOutgoing({ ...job, plan }, plan.content, 'unknown');
      Object.assign(outgoing, { purpose: plan.purpose, response_generation: 0 });
      await f.seed(session, (state) => {
        state.jobs.push(job); state.outgoing[String(fingerprint)] = outgoing;
      });
      f.histories.set(session, [{ ...outgoing.body, timestamp: f.now() - 1000 }]);
      f.restart();
      assert.equal((await f.runtime().process(f.key(session), job.id)).status,
        'delivery_identity_unresolved');
      return { f, session, job, outgoing };
    };

    const extra = await markedFixture('extra-field');
    let state = extra.f.rawState(extra.session);
    const stored = state.jobs.find((entry) => entry.id === extra.job.id);
    const marker = stored.delivery_receipt_unknown;
    assert.equal(marker.identity_status, 'unresolved');
    assert.equal(marker.record_identity_version, 1);
    assert.match(marker.record_identity_sha256, /^[a-f0-9]{64}$/);
    const markerText = JSON.stringify(marker);
    assert.equal(markerText.includes(plan.content), false, 'marker不得保存正文');
    assert.equal(markerText.includes(extra.job.id), false, 'marker不得明文保存job id');
    assert.equal(markerText.includes(extra.outgoing.attempt_token), false,
      'marker不得明文保存attempt token');

    // identity marker 是严格白名单结构；即使所有权威字段仍相同，夹带任意
    // 额外字段也不能继续作为免联网的正向事实。
    await extra.f.seed(extra.session, (current) => {
      const currentJob = current.jobs.find((entry) => entry.id === extra.job.id);
      currentJob.retry_at = extra.f.now();
      currentJob.delivery_receipt_unknown.unexpected = 'synthetic-extra-field';
    });
    extra.f.histories.set(extra.session, []); extra.f.restart();
    assert.equal((await extra.f.runtime().process(
      extra.f.key(extra.session), extra.job.id)).status, 'retry');
    assert.equal(extra.f.exactRequests.length, 1,
      '带额外字段的marker必须失败关闭并重新执行只读远端对账');
    state = extra.f.rawState(extra.session);
    assert.notEqual(state.jobs.find((entry) => entry.id === extra.job.id).failure_code,
      'delivery_identity_unresolved');
    assert.equal(extra.f.postAttempts.length, 0);

    // 保留相同 fingerprint/type/digest，仅替换 owner attempt 身份。旧 marker
    // 必须失效并重新联网核对，不能借上一负例的reconcile bookkeeping假通过。
    const replacement = await markedFixture('record-replacement');
    const originalToken = replacement.outgoing.attempt_token;
    await replacement.f.seed(replacement.session, (current) => {
      const currentJob = current.jobs.find((entry) => entry.id === replacement.job.id);
      currentJob.retry_at = replacement.f.now();
      current.outgoing[String(fingerprint)].attempt_token = 'f'.repeat(32);
    });
    assert.notEqual(originalToken, 'f'.repeat(32), '负例必须真实替换原attempt身份');
    replacement.f.histories.set(replacement.session, []); replacement.f.restart();
    assert.equal((await replacement.f.runtime().process(
      replacement.f.key(replacement.session), replacement.job.id)).status, 'retry');
    state = replacement.f.rawState(replacement.session);
    assert.notEqual(state.jobs.find((entry) => entry.id === replacement.job.id).failure_code,
      'delivery_identity_unresolved');
    assert.equal(replacement.f.exactRequests.length, 1,
      '同正文但不同完整record也必须重新执行只读远端对账');
    assert.equal(replacement.f.postAttempts.length, 0);
  });

  await test('F65d direct process 仅继承已过期的合法取消对账claim', async () => {
    const f = makeFixture('expired-reconciliation-claim-authorized');
    const session = 'session_expired-reconciliation-claim-authorized';
    const fingerprint = 77524;
    const plan = { type: 'text', purpose: 'keyword_reply', ordinary: true,
      content: '真人接管前可能已交给Crisp的正文', fingerprint };
    const job = f.makeJob(session, 'expired-reconciliation-claim-authorized', plan, {
      status: 'cancelled', responsibility_status: 'intentional_silence',
      responsibility_reason: 'human_reply', lease_until: 0,
    });
    const outgoing = f.makeOutgoing(job, plan.content, 'unknown');
    Object.assign(outgoing, { delivery_uncertain: true, resend_forbidden: true,
      recovery_deferred: true, cancelled_at: f.now() - 5000,
      cancellation_reason: 'conversation_state_changed', next_action_at: f.now() - 1,
      response_generation: 0, purpose: plan.purpose, message_type: plan.type,
      semantic_intent: 'answer', content_sha256: digest(canonical({
        type: plan.type, content: plan.content })), delivery_identity_version: 1 });
    await f.seed(session, (state) => {
      state.mode = 'human'; state.generation = 1; state.pause_reason = 'operator_reply';
      state.jobs.push(job); state.outgoing[String(fingerprint)] = outgoing;
    });
    f.histories.set(session, [{ ...outgoing.body, timestamp: f.now() - 1000 }]);
    let crashedClaim;
    f.modes.onCrispHistoryRequest = async () => {
      if (crashedClaim) return;
      crashedClaim = structuredClone(f.rawState(session));
      const claimed = crashedClaim.jobs.find((entry) => entry.id === job.id);
      assert.equal(claimed.status, 'processing');
      assert.equal(claimed.reconciliation_only, true);
      assert.match(claimed.execution_token, /^[a-f0-9]{24}$/);
      assert.equal(claimed.reconciliation_claim.schema_version, 2);
      assert.equal(claimed.reconciliation_claim.phase, 'reconciling');
      assert.match(claimed.reconciliation_claim.identity_hmac_sha256, /^[a-f0-9]{64}$/);
      assert.equal(crashedClaim.worker.token, claimed.execution_token);
    };
    f.restart();
    assert.equal((await f.runtime().process(f.key(session), job.id)).status,
      'dispatched_after_cancel');
    assert(crashedClaim, '必须从生产claim路径捕获崩溃前持久状态');
    f.modes.onCrispHistoryRequest = null;

    // 恢复生产路径产生的原始claim快照，再推进超过租约。下一实例读取时会
    // 清除过期worker，但必须依靠持久proof而不是内存worker恢复只读对账权。
    const stateFile = path.join(f.root, 'data/runtime/session-' + f.key(session) + '.json');
    fs.writeFileSync(stateFile, JSON.stringify(crashedClaim));
    f.advance(300001); f.restart();
    const result = await f.runtime().process(f.key(session), job.id);
    assert.equal(result.status, 'dispatched_after_cancel');
    const state = f.rawState(session);
    const stored = state.jobs.find((entry) => entry.id === job.id);
    assert.equal(stored.status, 'cancelled');
    assert.equal(stored.responsibility_status, 'intentional_silence');
    assert.equal(stored.responsibility_reason, 'human_reply');
    assert.equal(stored.reconciliation_only, undefined);
    assert.equal(stored.reconciliation_claim, undefined);
    assert.equal(stored.execution_token, undefined);
    assert.equal(state.worker, null);
    assert.equal(state.outgoing[String(fingerprint)].status, 'sent');
    assert.equal(state.outgoing[String(fingerprint)].receipt_current, false);
    assert.equal(f.modelRequests.length, 0); assert.equal(f.postAttempts.length, 0);
  });

  await test('F65e 完整政策形状但proof缺失或错配的过期claim必须失败关闭', async () => {
    for (const variant of ['missing', 'mismatch']) {
      const f = makeFixture('expired-reconciliation-claim-forged-' + variant);
      const session = 'session_expired-reconciliation-claim-forged-' + variant;
      const fingerprint = variant === 'missing' ? 77525 : 77526;
      const plan = { type: 'text', purpose: 'keyword_reply', ordinary: true,
        content: '真人接管后仅允许对账、不得重发的正文', fingerprint };
      const oldToken = variant === 'missing' ? 'b'.repeat(24) : 'c'.repeat(24);
      const job = f.makeJob(session, 'expired-reconciliation-claim-forged-' + variant,
        plan, { status: 'processing', responsibility_status: 'intentional_silence',
          responsibility_reason: 'human_reply', reconciliation_only: true,
          execution_token: oldToken, lease_until: f.now() - 1 });
      if (variant === 'mismatch') job.reconciliation_claim = {
        schema_version: 2, phase: 'reconciling', identity_hmac_sha256: 'f'.repeat(64) };
      const outgoing = f.makeOutgoing(job, plan.content, 'unknown');
      Object.assign(outgoing, { delivery_uncertain: true, resend_forbidden: true,
        recovery_deferred: true, cancelled_at: f.now() - 5000,
        cancellation_reason: 'conversation_state_changed', next_action_at: f.now() - 1,
        response_generation: 0, purpose: plan.purpose, message_type: plan.type,
        semantic_intent: 'answer', content_sha256: digest(canonical({
          type: plan.type, content: plan.content })), delivery_identity_version: 1 });
      await f.seed(session, (state) => {
        state.mode = 'human'; state.generation = 1; state.pause_reason = 'operator_reply';
        state.jobs.push(job); state.outgoing[String(fingerprint)] = outgoing;
        state.worker = { job: job.id, token: oldToken, until: f.now() - 1 };
      });
      f.restart();
      const result = await f.runtime().process(f.key(session), job.id);
      assert.deepEqual(result, { status: 'deferred',
        reason: 'reconciliation_claim_invalid' }, variant);
      const state = f.rawState(session);
      const stored = state.jobs.find((entry) => entry.id === job.id);
      assert.equal(stored.status, 'cancelled', variant);
      assert.equal(stored.responsibility_status, 'intentional_silence', variant);
      assert.equal(stored.responsibility_reason, 'human_reply', variant);
      assert.equal(stored.reconciliation_only, undefined, variant);
      assert.equal(stored.reconciliation_claim, undefined, variant);
      assert.equal(stored.execution_token, undefined, variant);
      assert.equal(state.worker, null, variant);
      assert.equal(state.outgoing[String(fingerprint)].status, 'unknown', variant);
      assert.equal(f.exactRequests.length, 0, variant);
      assert.equal(f.modelRequests.length, 0, variant);
      assert.equal(f.postAttempts.length, 0, variant);
    }
  });

  await test('F65h 远端阳性回执提交后、责任最终化前崩溃可由scanner恢复', async () => {
    const f = makeFixture('reconciliation-positive-post-commit-crash');
    const session = 'session_reconciliation-positive-post-commit-crash';
    const fingerprint = 77527;
    const plan = { type: 'text', purpose: 'keyword_reply', ordinary: true,
      content: '真人接管前已经交给Crisp的正文', fingerprint };
    const job = f.makeJob(session, 'reconciliation-positive-post-commit-crash', plan, {
      status: 'cancelled', responsibility_status: 'intentional_silence',
      responsibility_reason: 'human_reply', lease_until: 0,
    });
    const outgoing = f.makeOutgoing(job, plan.content, 'unknown');
    Object.assign(outgoing, { delivery_uncertain: true, resend_forbidden: true,
      recovery_deferred: true, cancelled_at: f.now() - 5000,
      cancellation_reason: 'conversation_state_changed', next_action_at: f.now() - 1,
      response_generation: 0, purpose: plan.purpose, message_type: plan.type,
      semantic_intent: 'answer', content_sha256: digest(canonical({
        type: plan.type, content: plan.content })), delivery_identity_version: 1 });
    await f.seed(session, (state) => {
      state.mode = 'human'; state.generation = 1; state.pause_reason = 'operator_reply';
      state.jobs.push(job); state.outgoing[String(fingerprint)] = outgoing;
    });
    f.histories.set(session, [{ ...outgoing.body, timestamp: f.now() - 1000 }]);
    const stateFile = path.join(f.root, 'data/runtime/session-' + f.key(session) + '.json');
    const rename = fs.renameSync;
    let committed;
    try {
      fs.renameSync = (source, destination) => {
        const result = rename(source, destination);
        if (!committed && destination === stateFile) {
          const candidate = f.rawState(session);
          const stored = candidate.jobs.find((entry) => entry.id === job.id);
          const record = candidate.outgoing[String(fingerprint)];
          if (stored?.status === 'processing' && stored.reconciliation_only === true
            && stored.reconciliation_claim?.schema_version === 2
            && stored.reconciliation_claim.phase === 'settled'
            && /^[a-f0-9]{64}$/.test(stored.reconciliation_claim.identity_hmac_sha256 || '')
            && record?.status === 'sent') committed = structuredClone(candidate);
        }
        return result;
      };
      f.restart();
      assert.equal((await f.runtime().process(f.key(session), job.id)).status,
        'dispatched_after_cancel');
    } finally { fs.renameSync = rename; }
    assert(committed, '必须捕获远端阳性回执已提交、外层责任尚未最终化的生产状态');
    fs.writeFileSync(stateFile, JSON.stringify(committed));
    f.advance(300001); f.restart();
    const scheduled = await f.runtime().scan();
    assert(scheduled.some((entry) => entry.jobId === job.id),
      'scanner必须保留并调度合法settled claim');
    const recovered = await f.runtime().process(f.key(session), job.id);
    assert.equal(recovered.status, 'dispatched_after_cancel');
    const state = f.rawState(session);
    const stored = state.jobs.find((entry) => entry.id === job.id);
    assert.equal(stored.status, 'cancelled');
    assert.equal(stored.responsibility_status, 'intentional_silence');
    assert.equal(stored.responsibility_reason, 'human_reply');
    assert.equal(stored.reconciliation_claim, undefined);
    assert.equal(state.outgoing[String(fingerprint)].status, 'sent');
    assert.equal(f.exactRequests.length, 0,
      'settled claim恢复不得再次查询或反向否定已确认远端回执');
    assert.equal(f.modelRequests.length, 0); assert.equal(f.postAttempts.length, 0);
  });

  await test('F65i 首次404记账后、责任最终化前崩溃保留合法claim并继续第二次核对', async () => {
    const f = makeFixture('reconciliation-first-404-post-commit-crash');
    const session = 'session_reconciliation-first-404-post-commit-crash';
    const fingerprint = 77528;
    const plan = { type: 'text', purpose: 'keyword_reply', ordinary: true,
      content: '真人接管前回执仍待两次阴性核对的正文', fingerprint };
    const job = f.makeJob(session, 'reconciliation-first-404-post-commit-crash', plan, {
      status: 'cancelled', responsibility_status: 'intentional_silence',
      responsibility_reason: 'human_reply', lease_until: 0,
    });
    const outgoing = f.makeOutgoing(job, plan.content, 'unknown');
    Object.assign(outgoing, { delivery_uncertain: true, resend_forbidden: true,
      recovery_deferred: true, cancelled_at: f.now() - 5000,
      cancellation_reason: 'conversation_state_changed', next_action_at: f.now() - 1,
      response_generation: 0, purpose: plan.purpose, message_type: plan.type,
      semantic_intent: 'answer', content_sha256: digest(canonical({
        type: plan.type, content: plan.content })), delivery_identity_version: 1 });
    await f.seed(session, (state) => {
      state.mode = 'human'; state.generation = 1; state.pause_reason = 'operator_reply';
      state.jobs.push(job); state.outgoing[String(fingerprint)] = outgoing;
    });
    f.modes.exactStatus = 404;
    const stateFile = path.join(f.root, 'data/runtime/session-' + f.key(session) + '.json');
    const rename = fs.renameSync;
    let committed;
    try {
      fs.renameSync = (source, destination) => {
        const result = rename(source, destination);
        if (!committed && destination === stateFile) {
          const candidate = f.rawState(session);
          const stored = candidate.jobs.find((entry) => entry.id === job.id);
          const record = candidate.outgoing[String(fingerprint)];
          if (stored?.status === 'processing' && stored.reconciliation_only === true
            && stored.reconciliation_claim?.schema_version === 2
            && stored.reconciliation_claim.phase === 'reconciling'
            && /^[a-f0-9]{64}$/.test(stored.reconciliation_claim.identity_hmac_sha256 || '')
            && record?.status === 'unknown' && record.reconcile_misses === 1) {
            committed = structuredClone(candidate);
          }
        }
        return result;
      };
      f.restart();
      assert.equal((await f.runtime().process(f.key(session), job.id)).status, 'retry');
    } finally { fs.renameSync = rename; }
    assert(committed, '必须捕获首次404与新claim同事务提交的生产状态');
    assert.equal(f.exactRequests.length, 1);
    fs.writeFileSync(stateFile, JSON.stringify(committed));
    f.advance(300001); f.restart();
    const scheduled = await f.runtime().scan();
    assert(scheduled.some((entry) => entry.jobId === job.id),
      'scanner必须调度首次404后合法续做的claim');
    const scannedState = f.rawState(session);
    const scannedJob = scannedState.jobs.find((entry) => entry.id === job.id);
    const committedJob = committed.jobs.find((entry) => entry.id === job.id);
    assert.equal(scannedJob.status, 'processing',
      'scanner必须保留生产事务已经提交的processing状态');
    assert.equal(scannedJob.reconciliation_only, true,
      'scanner不得把合法claim降级为普通cancelled后重新签发');
    assert.equal(scannedJob.execution_token, committedJob.execution_token,
      'scanner必须保留旧claim绑定的执行token');
    assert.equal(scannedJob.lease_until, committedJob.lease_until,
      'scanner必须保留旧claim绑定的租约身份');
    assert.deepEqual(scannedJob.reconciliation_claim, committedJob.reconciliation_claim,
      'scanner必须原样保留首次404事务推进后的claim');
    const recovered = await f.runtime().process(f.key(session), job.id);
    assert.equal(recovered.status, 'cancelled_reconciled');
    const state = f.rawState(session);
    const stored = state.jobs.find((entry) => entry.id === job.id);
    assert.equal(stored.status, 'cancelled');
    assert.equal(stored.responsibility_status, 'intentional_silence');
    assert.equal(stored.responsibility_reason, 'human_reply');
    assert.equal(stored.reconciliation_claim, undefined);
    assert.equal(state.outgoing[String(fingerprint)].status, 'cancelled');
    assert.equal(state.outgoing[String(fingerprint)].reconcile_misses, 2);
    assert.equal(f.exactRequests.length, 2,
      '恢复只能继续原fingerprint的第二次阴性核对，不能重发正文');
    assert.equal(f.modelRequests.length, 0); assert.equal(f.postAttempts.length, 0);
  });

  await test('F65j 生产claim必须绑定raw回答代与普通任务control身份', async () => {
    const variants = [
      { label: 'response-explicit-zero', mutate: ({ job }) => { job.response_generation = 0; } },
      { label: 'response-string', mutate: ({ job }) => { job.response_generation = '0'; } },
      { label: 'response-object', mutate: ({ job }) => { job.response_generation = { value: 0 }; } },
      { label: 'response-negative', mutate: ({ job }) => { job.response_generation = -1; } },
      { label: 'response-too-large', mutate: ({ job }) => { job.response_generation = 1000001; } },
      { label: 'control-true', mutate: ({ job }) => { job.control = true; } },
      { label: 'control-string', mutate: ({ job }) => { job.control = 'false'; } },
      { label: 'control-object', mutate: ({ job }) => { job.control = { value: false }; } },
      { label: 'control-missing', mutate: ({ job }) => { delete job.control; } },
      { label: 'plan-content', mutate: ({ job }) => { job.plan.content += '（篡改）'; } },
      { label: 'plan-tags', mutate: ({ job }) => { job.plan.tags = ['human_required']; } },
      { label: 'plan-string', mutate: ({ job }) => { job.plan = 'invalid-plan'; } },
      { label: 'plan-missing', mutate: ({ job }) => { delete job.plan; } },
    ];
    for (let index = 0; index < variants.length; index += 1) {
      const { label, mutate } = variants[index];
      const f = makeFixture('reconciliation-raw-generation-' + label);
      const session = 'session_reconciliation-raw-generation-' + label;
      const fingerprint = 77529 + index;
      const plan = { type: 'text', purpose: 'keyword_reply', ordinary: true,
        content: '只用于验证回答代身份绑定的合成正文', fingerprint };
      const job = f.makeJob(session, 'reconciliation-raw-generation-' + label, plan, {
        status: 'cancelled', responsibility_status: 'intentional_silence',
        responsibility_reason: 'human_reply', lease_until: 0,
      });
      assert.equal(Object.hasOwn(job, 'response_generation'), false,
        '合法生产claim起点必须真实缺失raw回答代字段');
      const outgoing = f.makeOutgoing(job, plan.content, 'unknown');
      Object.assign(outgoing, { delivery_uncertain: true, resend_forbidden: true,
        recovery_deferred: true, cancelled_at: f.now() - 5000,
        cancellation_reason: 'conversation_state_changed', next_action_at: f.now() - 1,
        response_generation: 0, purpose: plan.purpose, message_type: plan.type,
        semantic_intent: 'answer', content_sha256: digest(canonical({
          type: plan.type, content: plan.content })), delivery_identity_version: 1 });
      await f.seed(session, (state) => {
        state.mode = 'human'; state.generation = 1; state.pause_reason = 'operator_reply';
        state.jobs.push(job); state.outgoing[String(fingerprint)] = outgoing;
      });
      f.histories.set(session, [{ ...outgoing.body, timestamp: f.now() - 1000 }]);
      let claimSnapshot;
      let historyRequests = 0;
      f.modes.onCrispHistoryRequest = async () => {
        historyRequests += 1;
        if (!claimSnapshot) claimSnapshot = structuredClone(f.rawState(session));
      };
      f.restart();
      assert.equal((await f.runtime().process(f.key(session), job.id)).status,
        'dispatched_after_cancel', label);
      assert(claimSnapshot, label);
      const claimJob = claimSnapshot.jobs.find((entry) => entry.id === job.id);
      assert.equal(claimJob.control, false,
        '合法生产claim只能从明确的普通任务control=false产生');
      assert.equal(claimJob.reconciliation_claim.schema_version, 2, label);
      assert.equal(claimJob.reconciliation_claim.phase, 'reconciling', label);
      assert.match(claimJob.reconciliation_claim.identity_hmac_sha256,
        /^[a-f0-9]{64}$/, label);
      const callsBeforeMutation = historyRequests;
      mutate({ job: claimJob, state: claimSnapshot });
      const stateFile = path.join(f.root, 'data/runtime/session-' + f.key(session) + '.json');
      fs.writeFileSync(stateFile, JSON.stringify(claimSnapshot));
      f.advance(300001); f.restart();
      const result = await f.runtime().process(f.key(session), job.id);
      assert.deepEqual(result, { status: 'deferred',
        reason: 'reconciliation_claim_invalid' }, label);
      const state = f.rawState(session);
      const stored = state.jobs.find((entry) => entry.id === job.id);
      assert.equal(stored.status, 'cancelled', label);
      assert.equal(stored.responsibility_status, 'intentional_silence', label);
      assert.equal(stored.reconciliation_claim, undefined, label);
      assert.equal(historyRequests, callsBeforeMutation,
        label + '不得在claim验证前发起Crisp列表查询');
      assert.equal(f.exactRequests.length, 0, label);
      assert.equal(f.modelRequests.length, 0, label);
      assert.equal(f.postAttempts.length, 0, label);
    }
  });

  await test('F65k scanner拒绝非法claim后本轮不得重新签发或调度', async () => {
    const f = makeFixture('reconciliation-invalid-claim-scanner-backoff');
    const session = 'session_reconciliation-invalid-claim-scanner-backoff';
    const fingerprint = 77538;
    const plan = { type: 'text', purpose: 'keyword_reply', ordinary: true,
      content: '只用于验证非法claim扫描退避的合成正文', fingerprint };
    const job = f.makeJob(session, 'reconciliation-invalid-claim-scanner-backoff', plan, {
      status: 'cancelled', responsibility_status: 'intentional_silence',
      responsibility_reason: 'human_reply', lease_until: 0,
    });
    const outgoing = f.makeOutgoing(job, plan.content, 'unknown');
    Object.assign(outgoing, { delivery_uncertain: true, resend_forbidden: true,
      recovery_deferred: true, cancelled_at: f.now() - 5000,
      cancellation_reason: 'conversation_state_changed', next_action_at: f.now() - 1,
      response_generation: 0, purpose: plan.purpose, message_type: plan.type,
      semantic_intent: 'answer', content_sha256: digest(canonical({
        type: plan.type, content: plan.content })), delivery_identity_version: 1 });
    await f.seed(session, (state) => {
      state.mode = 'human'; state.generation = 1; state.pause_reason = 'operator_reply';
      state.jobs.push(job); state.outgoing[String(fingerprint)] = outgoing;
    });
    f.histories.set(session, [{ ...outgoing.body, timestamp: f.now() - 1000 }]);
    let claimSnapshot;
    let historyRequests = 0;
    f.modes.onCrispHistoryRequest = async () => {
      historyRequests += 1;
      if (!claimSnapshot) claimSnapshot = structuredClone(f.rawState(session));
    };
    f.restart();
    assert.equal((await f.runtime().process(f.key(session), job.id)).status,
      'dispatched_after_cancel');
    assert(claimSnapshot, '必须从生产路径捕获合法claim再制造损坏');
    const claimJob = claimSnapshot.jobs.find((entry) => entry.id === job.id);
    assert.equal(claimJob.control, false);
    claimJob.reconciliation_claim.identity_hmac_sha256 = 'f'.repeat(64);
    const stateFile = path.join(f.root, 'data/runtime/session-' + f.key(session) + '.json');
    fs.writeFileSync(stateFile, JSON.stringify(claimSnapshot));
    const callsBeforeScan = historyRequests;
    f.advance(300001); f.restart();
    const scheduled = await f.runtime().scan();
    assert.equal(scheduled.some((entry) => entry.jobId === job.id), false,
      '非法claim清除后的责任不得在同一轮scanner重新签发调度');
    const state = f.rawState(session);
    const stored = state.jobs.find((entry) => entry.id === job.id);
    assert.equal(stored.status, 'cancelled');
    assert.equal(stored.responsibility_status, 'intentional_silence');
    assert.equal(stored.responsibility_reason, 'human_reply');
    assert.equal(stored.reconciliation_only, undefined);
    assert.equal(stored.reconciliation_claim, undefined);
    assert.equal(stored.execution_token, undefined);
    assert.equal(stored.retry_at, f.now() + 5000,
      '未知回执责任必须延后一轮安全恢复，不能永久丢失');
    assert.equal(state.outgoing[String(fingerprint)].status, 'unknown');
    assert.equal(historyRequests, callsBeforeScan,
      'scanner失败关闭过程不得发起Crisp列表查询');
    assert.equal(f.exactRequests.length, 0);
    assert.equal(f.modelRequests.length, 0);
    assert.equal(f.postAttempts.length, 0);
  });

  await test('F65l scanner按文件key隔离跨会话或跨站点状态身份', async () => {
    const variants = [
      { label: 'session', mutate: (state) => { state.session_id = 'session_cross-identity-0001'; } },
      { label: 'website', mutate: (state) => {
        state.website_id = '22222222-2222-4222-8222-222222222222';
      } },
    ];
    for (let index = 0; index < variants.length; index += 1) {
      const { label, mutate } = variants[index];
      const f = makeFixture('reconciliation-state-identity-' + label);
      const session = 'session_reconciliation-state-identity-' + label;
      const fingerprint = 77539 + index;
      const plan = { type: 'text', purpose: 'keyword_reply', ordinary: true,
        content: '只用于验证会话状态路由身份的合成正文', fingerprint };
      const job = f.makeJob(session, 'reconciliation-state-identity-' + label, plan, {
        status: 'cancelled', responsibility_status: 'intentional_silence',
        responsibility_reason: 'human_reply', lease_until: 0,
      });
      const outgoing = f.makeOutgoing(job, plan.content, 'unknown');
      Object.assign(outgoing, { delivery_uncertain: true, resend_forbidden: true,
        recovery_deferred: true, cancelled_at: f.now() - 5000,
        cancellation_reason: 'conversation_state_changed', next_action_at: f.now() - 1,
        response_generation: 0, purpose: plan.purpose, message_type: plan.type,
        semantic_intent: 'answer', content_sha256: digest(canonical({
          type: plan.type, content: plan.content })), delivery_identity_version: 1 });
      await f.seed(session, (state) => {
        state.mode = 'human'; state.generation = 1; state.pause_reason = 'operator_reply';
        state.jobs.push(job); state.outgoing[String(fingerprint)] = outgoing;
      });
      f.histories.set(session, [{ ...outgoing.body, timestamp: f.now() - 1000 }]);
      let claimSnapshot;
      let historyRequests = 0;
      f.modes.onCrispHistoryRequest = async () => {
        historyRequests += 1;
        if (!claimSnapshot) claimSnapshot = structuredClone(f.rawState(session));
      };
      f.restart();
      assert.equal((await f.runtime().process(f.key(session), job.id)).status,
        'dispatched_after_cancel', label);
      assert(claimSnapshot, label);
      mutate(claimSnapshot);
      const stateFile = path.join(f.root, 'data/runtime/session-' + f.key(session) + '.json');
      fs.writeFileSync(stateFile, JSON.stringify(claimSnapshot));
      const callsBeforeScan = historyRequests;
      f.advance(300001); f.restart();
      const direct = await f.runtime().process(f.key(session), job.id);
      assert.deepEqual(direct, { status: 'deferred',
        reason: 'answer_responsibility_unresolved' },
        label + '直接处理也必须在任何网络前失败关闭跨会话状态');
      const scheduled = await f.runtime().scan();
      assert.equal(scheduled.some((entry) => entry.jobId === job.id), false, label);
      const retained = JSON.parse(fs.readFileSync(stateFile));
      assert.deepEqual(retained, claimSnapshot,
        label + '身份不一致文件必须原样隔离，不能跨会话修复或联网');
      const health = JSON.parse(fs.readFileSync(
        path.join(f.root, 'data/runtime/scheduler-health.json')));
      assert(health.isolated_sessions.reasons.invalid_state >= 1, label);
      assert.equal(historyRequests, callsBeforeScan, label);
      assert.equal(f.exactRequests.length, 0, label);
      assert.equal(f.modelRequests.length, 0, label);
      assert.equal(f.postAttempts.length, 0, label);
    }
  });

  await test('F65m reconciliation-only恢复不得执行标签或其它可见副作用', async () => {
    const f = makeFixture('reconciliation-no-tag-side-effect');
    const session = 'session_reconciliation-no-tag-side-effect';
    const fingerprint = 77541;
    const plan = { type: 'text', purpose: 'handoff_ack', ordinary: false,
      content: '', fingerprint, tags: ['human_required'] };
    const job = f.makeJob(session, 'reconciliation-no-tag-side-effect', plan, {
      status: 'cancelled', responsibility_status: 'intentional_silence',
      responsibility_reason: 'human_reply', lease_until: 0,
    });
    const outgoing = f.makeOutgoing(job, plan.content, 'unknown');
    Object.assign(outgoing, { delivery_uncertain: true, resend_forbidden: true,
      recovery_deferred: true, cancelled_at: f.now() - 5000,
      cancellation_reason: 'conversation_state_changed', next_action_at: f.now() - 1,
      response_generation: 0, purpose: plan.purpose, message_type: plan.type,
      semantic_intent: 'control', content_sha256: digest(canonical({
        type: plan.type, content: plan.content })), delivery_identity_version: 1 });
    await f.seed(session, (state) => {
      state.mode = 'human'; state.generation = 1; state.pause_reason = 'operator_reply';
      state.jobs.push(job); state.outgoing[String(fingerprint)] = outgoing;
    });
    f.histories.set(session, [{ ...outgoing.body, timestamp: f.now() - 1000 }]);
    let claimSnapshot;
    f.modes.onCrispHistoryRequest = async () => {
      if (!claimSnapshot) claimSnapshot = structuredClone(f.rawState(session));
    };
    f.restart();
    assert.equal((await f.runtime().process(f.key(session), job.id)).status,
      'dispatched_after_cancel');
    assert(claimSnapshot, '必须从真实对账入口捕获claim');
    f.patches.length = 0;
    f.metaRequests.length = 0;
    const stateFile = path.join(f.root, 'data/runtime/session-' + f.key(session) + '.json');
    fs.writeFileSync(stateFile, JSON.stringify(claimSnapshot));
    f.advance(300001); f.restart();
    assert.equal((await f.runtime().process(f.key(session), job.id)).status,
      'dispatched_after_cancel');
    assert.equal(f.patches.length, 0,
      '取消回执恢复只能核对原消息，不得读取或修改会话标签');
    assert.equal(f.metaRequests.length, 0,
      '取消回执恢复不得发起标签GET或PATCH');
    assert.equal(f.modelRequests.length, 0);
    assert.equal(f.postAttempts.length, 0);
  });

  await test('F65n 状态事务发布前拒绝内部路由身份换代', async () => {
    const f = makeFixture('transaction-state-identity-publish-barrier');
    const session = 'session_transaction-state-identity-publish-barrier';
    await f.seed(session, (state) => { state.control_watermark = f.now(); });
    const before = f.rawState(session);
    await assert.rejects(
      () => f.runtime().transaction(f.key(session), (state) => {
        state.session_id = 'session_cross-identity-transaction';
      }),
      (error) => error?.code === 'SESSION_STATE_IDENTITY_MISMATCH');
    assert.deepEqual(f.rawState(session), before,
      '身份不一致mutator必须在atomic发布前失败，旧状态逐字段保持');
    assert.equal(f.exactRequests.length, 0);
    assert.equal(f.modelRequests.length, 0);
    assert.equal(f.postAttempts.length, 0);
  });

  await test('F65o 状态读取严格区分缺失、旧版迁移与现存JSON假值', async () => {
    for (const [index, raw] of ['null', 'false', '0', '""'].entries()) {
      const f = makeFixture('state-falsey-json-' + index);
      const session = 'session_state-falsey-json-' + index;
      const stateFile = path.join(f.root, 'data/runtime/session-' + f.key(session) + '.json');
      fs.writeFileSync(stateFile, raw, { mode: 0o600 });
      assert.throws(() => f.runtime().readState(f.key(session)),
        (error) => error?.code === 'SESSION_STATE_IDENTITY_MISMATCH',
        raw + ' 必须按现存损坏状态失败关闭，不能当成ENOENT');
      const accepted = await f.receive(f.event(session, '只用于验证损坏状态读取边界'));
      assert.equal(accepted.accepted, false, raw);
      assert.equal(accepted.statusCode, 503, raw);
      assert.equal(fs.readFileSync(stateFile, 'utf8'), raw,
        raw + ' 必须保留原字节，不能被合法Webhook洗白覆盖');
      assert.deepEqual(await f.runtime().scan(), [], raw);
      assert.equal(fs.readFileSync(stateFile, 'utf8'), raw,
        raw + ' 扫描隔离后仍须保持原字节');
      const health = JSON.parse(fs.readFileSync(
        path.join(f.root, 'data/runtime/scheduler-health.json')));
      assert(health.isolated_sessions.reasons.invalid_state >= 1, raw);
      assert.equal(f.exactRequests.length, 0, raw);
      assert.equal(f.metaRequests.length, 0, raw);
      assert.equal(f.retrievalRequests.length, 0, raw);
      assert.equal(f.modelRequests.length, 0, raw);
      assert.equal(f.postAttempts.length, 0, raw);
      assert.equal(f.patches.length, 0, raw);

      const legacyFixture = makeFixture('state-falsey-legacy-json-' + index);
      const legacySession = 'session_state-falsey-legacy-json-' + index;
      const legacyFile = path.join(legacyFixture.root, 'data/runtime/session-'
        + digest(legacySession) + '.json');
      const currentFile = path.join(legacyFixture.root, 'data/runtime/session-'
        + legacyFixture.key(legacySession) + '.json');
      fs.writeFileSync(legacyFile, raw, { mode: 0o600 });
      const legacyRejected = await legacyFixture.receive(
        legacyFixture.event(legacySession, '只用于验证损坏旧版状态读取边界'));
      assert.equal(legacyRejected.accepted, false, raw + ' legacy');
      assert.equal(legacyRejected.statusCode, 503, raw + ' legacy');
      assert.equal(fs.readFileSync(legacyFile, 'utf8'), raw,
        raw + ' 损坏旧版状态必须保留原字节');
      assert.equal(fs.existsSync(currentFile), false,
        raw + ' 损坏旧版状态不得被默认值迁移成新状态');
      assert.equal(legacyFixture.exactRequests.length, 0, raw + ' legacy');
      assert.equal(legacyFixture.modelRequests.length, 0, raw + ' legacy');
      assert.equal(legacyFixture.postAttempts.length, 0, raw + ' legacy');
    }

    const invalidLegacyObjects = [
      {},
      { version: {}, aiEnabled: true, aiResumeAt: 0, handoffGeneration: 0 },
      { version: 1, aiEnabled: 'true', aiResumeAt: 0, handoffGeneration: 0 },
      { version: 1, aiEnabled: true, aiResumeAt: -1, handoffGeneration: 0 },
      { version: 1, aiEnabled: true, aiResumeAt: 0, handoffGeneration: -1 },
      { version: 1, aiEnabled: true, aiResumeAt: 0, handoffGeneration: 0,
        fingerprints: 'not-an-array' },
      { version: 1, aiEnabled: true, aiResumeAt: 0, handoffGeneration: 0,
        fingerprints: ['not-a-production-fingerprint'] },
      { version: 1, aiEnabled: true, aiResumeAt: 0, handoffGeneration: 0,
        fingerprints: Array.from({ length: 101 }, (_, index) => digest('legacy-' + index)) },
    ];
    for (const [index, value] of invalidLegacyObjects.entries()) {
      const f = makeFixture('state-invalid-legacy-object-' + index);
      const session = 'session_state-invalid-legacy-object-' + index;
      const raw = JSON.stringify(value);
      const legacyFile = path.join(f.root, 'data/runtime/session-'
        + digest(session) + '.json');
      const currentFile = path.join(f.root, 'data/runtime/session-'
        + f.key(session) + '.json');
      fs.writeFileSync(legacyFile, raw, { mode: 0o600 });
      const rejected = await f.receive(
        f.event(session, '只用于验证非法旧版对象读取边界'));
      assert.equal(rejected.accepted, false, String(index));
      assert.equal(rejected.statusCode, 503, String(index));
      assert.equal(fs.readFileSync(legacyFile, 'utf8'), raw,
        '非法旧版对象必须逐字节保留');
      assert.equal(fs.existsSync(currentFile), false,
        '非法旧版对象不得生成当前状态');
      assert.equal(f.exactRequests.length, 0, String(index));
      assert.equal(f.modelRequests.length, 0, String(index));
      assert.equal(f.postAttempts.length, 0, String(index));
    }

    const missing = makeFixture('state-absent-creates-current');
    const missingSession = 'session_state-absent-creates-current';
    const missingAccepted = await missing.receive(
      missing.event(missingSession, '只用于验证真正缺失状态可创建'));
    assert.equal(missingAccepted.accepted, true);
    const created = missing.rawState(missingSession);
    assert.equal(created.website_id, missing.env.CRISP_WEBSITE_ID);
    assert.equal(created.session_id, missingSession);
    assert.equal(created.schema_version, 2);

    const legacy = makeFixture('state-legacy-migration-preserved');
    const legacySession = 'session_state-legacy-migration-preserved';
    const legacyFingerprint = digest('legacy-production-fingerprint');
    const legacyFile = path.join(legacy.root, 'data/runtime/session-'
      + digest(legacySession) + '.json');
    fs.writeFileSync(legacyFile, JSON.stringify({ version: 1, aiEnabled: false,
      handoffGeneration: 7, aiResumeAt: 0, lastOperatorAt: legacy.now() - 1000,
      welcomeSent: true, menuNode: 'synthetic-node', fingerprints: [legacyFingerprint] }),
    { mode: 0o600 });
    const legacyAccepted = await legacy.receive(
      legacy.event(legacySession, '只用于验证旧版状态迁移'));
    assert.equal(legacyAccepted.accepted, true);
    const migrated = legacy.rawState(legacySession);
    assert.equal(migrated.website_id, legacy.env.CRISP_WEBSITE_ID);
    assert.equal(migrated.session_id, legacySession);
    assert.equal(migrated.mode, 'human');
    assert.equal(migrated.generation, 7);
    assert.equal(migrated.welcome_sent, true);
    assert.equal(migrated.menu_node, 'synthetic-node');
    assert.deepEqual(migrated.legacy_fingerprints, [legacyFingerprint]);
    assert.equal(missing.exactRequests.length + legacy.exactRequests.length, 0);
    assert.equal(missing.modelRequests.length + legacy.modelRequests.length, 0);
    assert.equal(missing.postAttempts.length + legacy.postAttempts.length, 0);
  });

  await test('F65f 跨实例operator身份待定期间Crisp已收答案，确认非真人后只完成原答案一次', async () => {
    const f = makeFixture('operator-pending-receipt-not-human');
    const session = 'session_operator-pending-receipt-not-human';
    const visitor = f.event(session, '并发身份确认期间的普通问题');
    const accepted = await f.receive(visitor);
    assert.equal(accepted.accepted, true); assert.equal(accepted.route, 'process');

    const sender = f.runtime();
    const operatorFingerprint = 875260;
    const operator = { website_id: f.env.CRISP_WEBSITE_ID,
      event: 'message:received', timestamp: f.now(),
      data: { session_id: session, from: 'operator', type: 'text',
        content: '身份待精确确认的operator消息', fingerprint: operatorFingerprint,
        timestamp: f.now() } };
    let controlAccepted;
    f.modes.crispIgnoreAbortAfterAccept = true;
    f.modes.onCrispPost = async () => {
      const history = f.histories.get(session) || [];
      history.push(structuredClone(operator.data));
      f.histories.set(session, history);
      f.restart();
      controlAccepted = await f.receive(operator);
      assert.equal(controlAccepted.accepted, true);
      assert.equal(controlAccepted.route, 'process');
    };

    const deferred = await sender.process(accepted.key, accepted.jobId);
    f.modes.onCrispPost = null;
    f.modes.crispIgnoreAbortAfterAccept = false;
    assert.deepEqual({ status: deferred.status, reason: deferred.reason },
      { status: 'deferred', reason: 'operator_identity_pending' });
    assert(controlAccepted, '另一实例必须先持久化operator控制责任');

    let state = f.rawState(session);
    let stored = state.jobs.find((entry) => entry.id === accepted.jobId);
    const pendingRecords = Object.entries(state.outgoing).filter(([, record]) =>
      record?.job_id === accepted.jobId && record.status === 'sent');
    assert.equal(pendingRecords.length, 1);
    const [fingerprint, pending] = pendingRecords[0];
    assert.equal(pending.receipt_current, null);
    assert.equal(pending.receipt_state_change_reason, 'operator_identity_pending');
    assert.equal(pending.resend_forbidden, true);
    assert.equal(pending.delivery_identity_version, 1);
    assert.equal(pending.body, undefined);
    assert.equal(stored.status, 'received');
    assert.equal(stored.responsibility_status, 'pending');
    assert.equal(stored.deferred_control, true);
    assert(stored.data); assert(stored.plan);
    assert.equal(stored.execution_token, undefined);
    assert.equal(stored.delivery_receipt_unknown, undefined,
      '严格过渡回执不能降级成永久identity marker');
    assert.equal(f.retrievalRequests.length, 1); assert.equal(f.modelRequests.length, 1);
    assert.equal(f.postAttempts.length, 1); assert.equal(f.sent.length, 1);

    const history = f.histories.get(session);
    const exactOperator = history.find((entry) =>
      String(entry.fingerprint) === String(operatorFingerprint));
    exactOperator.automated = true;
    const control = f.runtime();
    await control.process(controlAccepted.key, controlAccepted.jobId);
    state = f.rawState(session);
    const controlJob = state.jobs.find((entry) => entry.id === controlAccepted.jobId);
    assert.equal(controlJob.status, 'done');
    assert.equal(controlJob.responsibility_status, 'control_handled');
    assert.equal(controlJob.operator_resolution.result, 'not-human');
    assert.equal(state.uncertain_events.length, 0);
    assert.equal(state.mode, 'ai');

    f.restart();
    const completed = await f.runtime().process(accepted.key, accepted.jobId);
    assert.equal(completed.status, 'sent');
    state = f.rawState(session);
    stored = state.jobs.find((entry) => entry.id === accepted.jobId);
    const receipt = state.outgoing[String(fingerprint)];
    assert.equal(stored.status, 'done');
    assert.equal(stored.responsibility_status, 'answered_confirmed');
    assert.equal(receipt.receipt_current, true);
    assert.equal(receipt.receipt_state_change_reason, undefined);
    assert.equal(receipt.resend_forbidden, undefined);
    assert.equal(stored.delivery_receipt_unknown, undefined);
    assert.equal(f.retrievalRequests.length, 1); assert.equal(f.modelRequests.length, 1);
    assert.equal(f.postAttempts.length, 1); assert.equal(f.sent.length, 1);
    assert.equal((await f.runtime().process(accepted.key, accepted.jobId)).status, 'idle');
    assert.equal(f.sent.length, 1); f.noFeedback();
  });

  await test('F65g 跨实例operator身份待定期间Crisp已收答案，确认真人后保持人工静默且不重发', async () => {
    const f = makeFixture('operator-pending-receipt-human');
    const session = 'session_operator-pending-receipt-human';
    const visitor = f.event(session, '真人接管竞态中的普通问题');
    const accepted = await f.receive(visitor);
    assert.equal(accepted.accepted, true); assert.equal(accepted.route, 'process');

    const sender = f.runtime();
    const operatorFingerprint = 875270;
    const operator = { website_id: f.env.CRISP_WEBSITE_ID,
      event: 'message:received', timestamp: f.now(),
      data: { session_id: session, from: 'operator', type: 'text',
        content: '身份待精确确认的真人回复', fingerprint: operatorFingerprint,
        timestamp: f.now() } };
    let controlAccepted;
    f.modes.crispIgnoreAbortAfterAccept = true;
    f.modes.onCrispPost = async () => {
      const history = f.histories.get(session) || [];
      history.push(structuredClone(operator.data));
      f.histories.set(session, history);
      f.restart();
      controlAccepted = await f.receive(operator);
      assert.equal(controlAccepted.accepted, true);
      assert.equal(controlAccepted.route, 'process');
    };

    const deferred = await sender.process(accepted.key, accepted.jobId);
    f.modes.onCrispPost = null;
    f.modes.crispIgnoreAbortAfterAccept = false;
    assert.deepEqual({ status: deferred.status, reason: deferred.reason },
      { status: 'deferred', reason: 'operator_identity_pending' });
    assert(controlAccepted, '另一实例必须先持久化operator控制责任');

    let state = f.rawState(session);
    const pendingRecords = Object.entries(state.outgoing).filter(([, record]) =>
      record?.job_id === accepted.jobId && record.status === 'sent');
    assert.equal(pendingRecords.length, 1);
    const [fingerprint, pending] = pendingRecords[0];
    assert.equal(pending.receipt_current, null);
    assert.equal(pending.receipt_state_change_reason, 'operator_identity_pending');
    assert.equal(pending.resend_forbidden, true);
    assert.equal(f.retrievalRequests.length, 1); assert.equal(f.modelRequests.length, 1);
    assert.equal(f.postAttempts.length, 1); assert.equal(f.sent.length, 1);

    const history = f.histories.get(session);
    const exactOperator = history.find((entry) =>
      String(entry.fingerprint) === String(operatorFingerprint));
    exactOperator.automated = false;
    const control = f.runtime();
    await control.process(controlAccepted.key, controlAccepted.jobId);
    state = f.rawState(session);
    const controlJob = state.jobs.find((entry) => entry.id === controlAccepted.jobId);
    const stored = state.jobs.find((entry) => entry.id === accepted.jobId);
    const receipt = state.outgoing[String(fingerprint)];
    assert.equal(controlJob.status, 'done');
    assert.equal(controlJob.responsibility_status, 'control_handled');
    assert.equal(controlJob.operator_resolution.result, 'human');
    assert.equal(state.uncertain_events.length, 0);
    assert.equal(state.mode, 'human');
    assert.equal(state.pause_reason, 'operator_reply');
    assert.equal(stored.status, 'cancelled');
    assert.equal(stored.responsibility_status, 'intentional_silence');
    assert.equal(stored.responsibility_reason, 'human_reply');
    assert.equal(stored.data, undefined); assert.equal(stored.plan, undefined);
    assert.equal(receipt.status, 'sent');
    assert.equal(receipt.receipt_current, false);
    assert.equal(receipt.receipt_state_change_reason, 'conversation_state_changed');
    assert.equal(receipt.state_changed_before_receipt, true);
    assert.equal(receipt.resend_forbidden, undefined);
    assert.equal(stored.delivery_receipt_unknown, undefined);

    f.restart();
    assert.equal((await f.runtime().process(accepted.key, accepted.jobId)).status, 'idle');
    assert.equal(f.retrievalRequests.length, 1); assert.equal(f.modelRequests.length, 1);
    assert.equal(f.postAttempts.length, 1); assert.equal(f.sent.length, 1,
      '真人确认后不得为同一问题再次推理或补发第二条AI答案');
    f.noFeedback();
  });

  await test('F66 同一恢复代出现多个 sent 回执时冲突关闭，不挑一条假完成', async () => {
    const f = makeFixture('multiple-frozen-receipts');
    const session = 'session_multiple-frozen-receipts';
    const plan = { type: 'text', purpose: 'keyword_reply', ordinary: true,
      content: '原问题的候选业务回答', fingerprint: 77530 };
    const job = f.makeJob(session, 'multiple-frozen-receipts', plan);
    await f.seed(session, (state) => {
      state.jobs.push(job);
      for (const fingerprint of [77530, 77531]) {
        state.outgoing[String(fingerprint)] = {
          status: 'sent', created_at: f.now() - 1000, sent_at: f.now() - 1000,
          job_id: job.id, generation: 0, response_generation: 0,
          purpose: plan.purpose, message_type: 'text', semantic_intent: 'answer',
          semantic_status: 'valid_answer', content_sha256: digest(canonical({ type: 'text', content: plan.content })),
          receipt_current: true, receipt_confirmed_at: f.now() - 1000,
        };
      }
    });
    f.restart();
    assert.equal((await f.runtime().process(f.key(session), job.id)).status, 'delivery_semantic_unknown');
    const stored = f.rawState(session);
    const unresolved = stored.jobs.find((item) => item.id === job.id);
    assert.equal(unresolved.responsibility_status, 'unresolved_failure');
    assert.equal(unresolved.failure_code, 'delivery_semantic_unknown');
    assert(unresolved.data); assert.equal(f.postAttempts.length, 0); assert.equal(f.sent.length, 0);
  });

  await test('F67 配置换代期间已投递 non-answer 保持原问题并进入新恢复代', async () => {
    const f = makeFixture('nonanswer-config-change');
    const session = 'session_nonanswer-config-change';
    const plan = { type: 'text', purpose: 'ai_text', ordinary: true, ai: true,
      content: clarification, fingerprint: 77540 };
    const job = f.legacyUnpooled(f.makeJob(session, 'nonanswer-config-change', plan));
    const outgoing = f.makeOutgoing(job, plan.content, 'unknown');
    await f.seed(session, (state) => { state.jobs.push(job); state.outgoing[String(plan.fingerprint)] = outgoing; });
    f.histories.set(session, [{ ...outgoing.body, timestamp: f.now() - 1000 }]);
    f.writeConfig('runtime', { schema_version: 2, enabled: true, revision: 2, applied_revision: 2 });
    f.publishCurrentMaterials();
    f.restart();
    assert.equal((await f.runtime().process(f.key(session), job.id)).status, 'delivered_non_answer');
    const stored = f.rawState(session);
    const record = stored.outgoing[String(plan.fingerprint)];
    const unresolved = stored.jobs.find((item) => item.id === job.id);
    assert.equal(record.receipt_current, false);
    assert.equal(record.receipt_state_change_reason, 'configuration_changed');
    assert.equal(record.semantic_status, 'delivered_non_answer');
    assert.equal(unresolved.status, 'received');
    assert.equal(unresolved.failure_code, 'delivered_non_answer');
    assert.equal(unresolved.response_generation, 1);
    assert.equal(unresolved.delivery_state_change_counted, true);
    assert.equal(unresolved.delivery_state_change_counted_generation, 0,
      '配置换代 non-answer 的迟到投递计数必须保留在旧回答代');
    assert(unresolved.data); assert.equal(f.postAttempts.length, 0); assert.equal(f.sent.length, 0);
  });

  await test('F68 POST dispatched 后本地登记消失时持久冻结未知回执且禁止重发', async () => {
    const f = makeFixture('post-record-disappeared');
    const session = 'session_post-record-disappeared';
    const plan = { type: 'text', purpose: 'keyword_reply', ordinary: true,
      content: '已交给 Crisp 但本地登记被并发替换的正文', fingerprint: 77550 };
    const job = f.makeJob(session, 'post-record-disappeared', plan);
    await f.seed(session, (state) => state.jobs.push(job));
    f.modes.onCrispPost = async () => {
      const state = f.rawState(session);
      delete state.outgoing[String(plan.fingerprint)];
      fs.writeFileSync(path.join(f.root, 'data/runtime/session-' + f.key(session) + '.json'), JSON.stringify(state));
    };
    f.restart();
    assert.equal((await f.runtime().process(f.key(session), job.id)).status, 'delivery_semantic_unknown');
    let stored = f.rawState(session);
    const unresolved = stored.jobs.find((item) => item.id === job.id);
    const record = stored.outgoing[String(plan.fingerprint)];
    assert.equal(record.status, 'sent');
    assert.equal(record.receipt_identity_unbound, true);
    assert.equal(record.semantic_status, 'semantic_unknown');
    assert.equal(record.resend_forbidden, true);
    assert(unresolved.delivery_receipt_unknown);
    assert.equal(unresolved.responsibility_status, 'unresolved_failure');
    assert.equal(f.postAttempts.length, 1); assert.equal(f.sent.length, 1);
    f.advance(8 * 86400000); f.restart();
    await f.runtime().transaction(f.key(session), () => {});
    stored = f.rawState(session);
    assert(stored.outgoing[String(plan.fingerprint)], '未知防重栅栏不得在七天后消失');
    assert.equal(f.postAttempts.length, 1, '未知回执不得触发第二次 POST');
  });

  await test('F69 语义未知优先于状态变化，不能终态化或删除原责任', async () => {
    const f = makeFixture('semantic-unknown-state-change');
    const session = 'session_semantic-unknown-state-change';
    const plan = { type: 'text', purpose: 'keyword_reply', ordinary: true,
      content: '只能在语义确定后计作回答的候选正文', fingerprint: 77560 };
    const job = f.makeJob(session, 'semantic-unknown-state-change', plan);
    await f.seed(session, (state) => {
      state.jobs.push(job);
      state.outgoing[String(plan.fingerprint)] = {
        status: 'sent', created_at: f.now() - 1000, sent_at: f.now() - 1000,
        job_id: job.id, generation: 0, response_generation: 0,
        purpose: plan.purpose, message_type: plan.type, semantic_intent: 'unknown',
        semantic_status: 'semantic_unknown', content_sha256: digest('unbound-semantic-content'),
        receipt_current: false, receipt_state_change_reason: 'configuration_changed',
        receipt_confirmed_at: f.now() - 1000, resend_forbidden: true,
      };
    });
    f.restart();
    assert.equal((await f.runtime().process(f.key(session), job.id)).status,
      'delivery_semantic_unknown');
    const stored = f.rawState(session);
    const unresolved = stored.jobs.find((item) => item.id === job.id);
    assert.equal(unresolved.status, 'received');
    assert.equal(unresolved.responsibility_status, 'unresolved_failure');
    assert.equal(unresolved.failure_code, 'delivery_semantic_unknown');
    assert(unresolved.data); assert(unresolved.plan);
    assert(stored.outgoing[String(plan.fingerprint)]);
    assert.equal(f.postAttempts.length, 0); assert.equal(f.sent.length, 0);
  });

  await test('F70 缺 job_id 的旧回执仅在严格身份命中后绑定并冻结', async () => {
    const f = makeFixture('legacy-receipt-bind-job');
    const session = 'session_legacy-receipt-bind-job';
    const plan = { type: 'text', purpose: 'keyword_reply', ordinary: true,
      content: '严格核验后可确认的旧版业务答案', fingerprint: 77570 };
    const job = f.makeJob(session, 'legacy-receipt-bind-job', plan);
    const outgoing = f.makeOutgoing(job, plan.content, 'unknown');
    delete outgoing.job_id;
    delete outgoing.generation;
    delete outgoing.response_generation;
    await f.seed(session, (state) => {
      state.jobs.push(job);
      state.outgoing[String(plan.fingerprint)] = outgoing;
    });
    f.histories.set(session, [{ ...outgoing.body, website_id: f.env.CRISP_WEBSITE_ID,
      session_id: session, timestamp: f.now() - 1000 }]);
    f.restart();
    assert.equal((await f.runtime().process(f.key(session), job.id)).status, 'sent');
    const stored = f.rawState(session);
    const record = stored.outgoing[String(plan.fingerprint)];
    const answered = stored.jobs.find((item) => item.id === job.id);
    assert.equal(record.job_id, job.id);
    assert.equal(record.response_generation, 0);
    assert.equal(record.semantic_status, 'valid_answer');
    assert.equal(record.receipt_current, true);
    assert.equal(answered.status, 'done');
    assert.equal(answered.responsibility_status, 'answered_confirmed');
    assert.equal(f.postAttempts.length, 0); assert.equal(f.sent.length, 0);
  });

  await test('F70b 缺恢复代的旧回执不得提升成非零当前代或终结责任', async () => {
    for (const source of ['history', 'exact']) {
      const f = makeFixture('legacy-receipt-nonzero-unbound-' + source);
      const session = 'session_legacy-receipt-nonzero-' + source;
      const plan = { type: 'text', purpose: 'keyword_reply', ordinary: true,
        content: '只能由当前恢复代生成并核验的业务答案', fingerprint: source === 'history' ? 77571 : 77572 };
      const job = f.makeJob(session, 'legacy-receipt-nonzero-' + source, plan,
        { response_generation: 1, responsibility_status: 'unresolved_failure' });
      const outgoing = f.makeOutgoing(job, plan.content, 'unknown');
      delete outgoing.job_id;
      delete outgoing.generation;
      delete outgoing.response_generation;
      await f.seed(session, (state) => {
        state.jobs.push(job);
        state.outgoing[String(plan.fingerprint)] = outgoing;
      });
      const remote = { ...outgoing.body, website_id: f.env.CRISP_WEBSITE_ID,
        session_id: session, timestamp: f.now() - 1000 };
      f.histories.set(session, [remote]);
      if (source === 'exact') f.modes.listHistoryOverride = [];
      f.restart();
      assert.equal((await f.runtime().process(f.key(session), job.id)).status,
        'delivery_semantic_unknown');
      const stored = f.rawState(session);
      const record = stored.outgoing[String(plan.fingerprint)];
      const unresolved = stored.jobs.find((item) => item.id === job.id);
      assert.equal(record.job_id, undefined);
      assert.equal(record.response_generation, undefined);
      assert.equal(record.receipt_identity_unbound, true);
      assert.equal(record.semantic_status, 'semantic_unknown');
      assert.equal(record.resend_forbidden, true);
      assert.equal(unresolved.status, 'received');
      assert.equal(unresolved.responsibility_status, 'unresolved_failure');
      assert.equal(unresolved.failure_code, 'delivery_semantic_unknown');
      assert(unresolved.data); assert(unresolved.plan); assert(unresolved.delivery_receipt_unknown);
      assert.equal(f.postAttempts.length, 0); assert.equal(f.sent.length, 0);
      if (source === 'exact') assert.equal(f.exactRequests.length, 1);
    }
  });

  await test('F70c 已有 job_id 的缺失或冲突恢复代回执仍须冻结为未知', async () => {
    for (const source of ['history', 'exact']) {
      for (const recordGeneration of ['missing', 0]) {
        const suffix = source + '-' + recordGeneration;
        const f = makeFixture('orphan-receipt-generation-conflict-' + suffix);
        const session = 'session_orphan-receipt-generation-conflict-' + suffix;
        const plan = { type: 'text', purpose: 'keyword_reply', ordinary: true,
          content: '只能由当前恢复代确认归属的业务答案',
          fingerprint: source === 'history' ? (recordGeneration === 'missing' ? 77573 : 77574)
            : (recordGeneration === 'missing' ? 77575 : 77576) };
        const job = f.makeJob(session, 'orphan-receipt-generation-conflict-' + suffix, null,
          { response_generation: 1, responsibility_status: 'unresolved_failure' });
        const outgoing = f.makeOutgoing({ ...job, plan }, plan.content, 'unknown');
        if (recordGeneration === 'missing') delete outgoing.response_generation;
        else outgoing.response_generation = recordGeneration;
        await f.seed(session, (state) => {
          state.jobs.push(job);
          state.outgoing[String(plan.fingerprint)] = outgoing;
        });
        const remote = { ...outgoing.body, website_id: f.env.CRISP_WEBSITE_ID,
          session_id: session, timestamp: f.now() - 1000 };
        f.histories.set(session, [remote]);
        if (source === 'exact') f.modes.listHistoryOverride = [];
        f.restart();
        assert.equal((await f.runtime().process(f.key(session), job.id)).status,
          'delivery_semantic_unknown');
        const stored = f.rawState(session);
        const record = stored.outgoing[String(plan.fingerprint)];
        const unresolved = stored.jobs.find((item) => item.id === job.id);
        assert.equal(record.job_id, job.id);
        assert.equal(record.response_generation,
          recordGeneration === 'missing' ? undefined : recordGeneration);
        assert.equal(record.receipt_identity_unbound, true);
        assert.equal(record.semantic_status, 'semantic_unknown');
        assert.equal(record.resend_forbidden, true);
        assert.equal(unresolved.status, 'received');
        assert.equal(unresolved.responsibility_status, 'unresolved_failure');
        assert.equal(unresolved.failure_code, 'delivery_semantic_unknown');
        assert(unresolved.data); assert(unresolved.delivery_receipt_unknown);
        assert.equal(f.postAttempts.length, 0); assert.equal(f.sent.length, 0);
        if (source === 'exact') assert.equal(f.exactRequests.length, 1);
      }
    }
  });

  await test('F71 丢 plan 的三次 POST orphan 经双 404 后仍保留防第四次发送', async () => {
    const f = makeFixture('orphan-post-budget-retained');
    const session = 'session_orphan-post-budget-retained';
    const job = f.makeJob(session, 'orphan-post-budget-retained', null,
      { received_at: f.now() - 20000, responsibility_status: 'unresolved_failure' });
    const plan = { type: 'text', purpose: 'keyword_reply', ordinary: true,
      content: '达到发送上限后只能继续核验的原正文', fingerprint: 77580 };
    const outgoing = f.makeOutgoing({ ...job, plan }, plan.content, 'unknown');
    outgoing.created_at = f.now() - 15000;
    outgoing.attempts = 3;
    await f.seed(session, (state) => {
      state.jobs.push(job);
      state.outgoing[String(plan.fingerprint)] = outgoing;
    });
    f.modes.exactStatus = 404; f.restart();
    assert.equal((await f.runtime().process(f.key(session), job.id)).status, 'retry');
    f.advance(5000); f.restart();
    assert.equal((await f.runtime().process(f.key(session), job.id)).status, 'retry');
    let stored = f.rawState(session);
    let record = stored.outgoing[String(plan.fingerprint)];
    assert(record, '发送预算用尽的 orphan 不能删除身份后重新开始');
    assert.equal(record.status, 'unknown');
    assert.equal(record.attempts, 3);
    assert.equal(record.resend_forbidden, true);
    assert.equal(record.failure, 'post_budget_exhausted');
    assert.equal(record.body.content, plan.content);
    assert.equal(f.postAttempts.length, 0); assert.equal(f.sent.length, 0);
    const exactBefore = f.exactRequests.length;
    for (let attempt = 0; attempt < 3; attempt += 1) {
      f.advance(5000); f.restart();
      assert.equal((await f.runtime().process(f.key(session), job.id)).status, 'idle');
      assert.deepEqual(await f.runtime().scan(), []);
    }
    assert.equal(f.exactRequests.length, exactBefore,
      '发送预算用尽后的300秒内不得被5秒任务重试绕过而继续查询 Crisp');
    stored = f.rawState(session); record = stored.outgoing[String(plan.fingerprint)];
    assert(record.next_action_at > f.now());
    f.advance(record.next_action_at - f.now() + 1); f.restart();
    assert.equal((await f.runtime().process(f.key(session), job.id)).status, 'retry');
    stored = f.rawState(session); record = stored.outgoing[String(plan.fingerprint)];
    assert(record); assert.equal(record.attempts, 3);
    assert.equal(f.exactRequests.length, exactBefore + 1,
      '退避到期后只允许一轮只读对账');
    assert.equal(f.postAttempts.length, 0, '不得删除旧计数后出现第四次 POST');
  });

  const ae01Clarification = '请确认要查询的是示例订单编号 A，还是示例订单编号 B。';
  const ae01Plan = (fingerprint) => ({ type: 'text', purpose: 'ai_text', ordinary: true, ai: true,
    content: ae01Clarification, fingerprint, answer_responsibility: 'clarification_confirmed' });
  const ae01ReplyEvents = (fixture) => fixture.events().filter((event) => event.type === 'ai_reply');
  const applyAe01Materials = (fixture, enabled = true) => {
    const configuration = Object.fromEntries(['runtime', 'handoff', 'keyword', 'menu', 'tags', 'feedback']
      .map((name) => [name, fixture.readConfig(name)]));
    configuration.runtime = { ...configuration.runtime, enabled, revision: 1, applied_revision: 1 };
    fixture.writeConfig('runtime', configuration.runtime);
    const materials = fixture.writeAppliedMaterials(configuration);
    assert.equal(materials.schema_version, 2);
    assert.equal(materials.state, 'applied');
    assert.equal(materials.configuration.runtime.enabled, enabled);
    return materials;
  };
  const settleAe01ProviderPlan = (fixture, job, plan) => {
    const responseGeneration = Number.isSafeInteger(job.response_generation) ? job.response_generation : 0;
    job.provider_settlement = {
      schema_version: 1,
      state: 'settled',
      plan_sha256: digest(canonical({
        type: plan.type || '', purpose: plan.purpose || '', content: plan.content || '',
        outcome: plan.outcome || '', sources: plan.sources || [], tags: plan.tags || [],
      })),
      response_generation: responseGeneration,
      attempts: 1,
      settled_at: fixture.now() - 1000,
    };
    assert.deepEqual(Object.keys(job.provider_settlement).sort(),
      ['attempts', 'plan_sha256', 'response_generation', 'schema_version', 'settled_at', 'state']);
    return job.provider_settlement;
  };
  const freezeAe01OutgoingIdentity = (job, plan, record) => {
    Object.assign(record, {
      delivery_identity_version: 1,
      purpose: plan.purpose,
      message_type: plan.type,
      semantic_intent: 'answer',
      semantic_status: 'valid_answer',
      response_generation: Number.isSafeInteger(job.response_generation) ? job.response_generation : 0,
      content_sha256: digest(canonical({ type: plan.type, content: plan.content })),
    });
    assert.equal(record.job_id, job.id);
    return record;
  };
  const sealAe01SentRecord = (fixture, job, plan, record) => {
    freezeAe01OutgoingIdentity(job, plan, record);
    Object.assign(record, {
      receipt_current: true,
      receipt_confirmed_at: fixture.now() - 1000,
    });
    delete record.body;
    return record;
  };

  await test('AE01a 未发送的遗留裸 clarification plan 无权威且不得可见出站', async () => {
    const f = makeFixture('ae01-bare-clarification-unsent');
    applyAe01Materials(f);
    const session = 'session_ae01-bare-clarification-unsent';
    const plan = ae01Plan(77600);
    assert.equal(mechanicalFailureAnswer(plan.content), false,
      '本场景必须证明 evidence 门禁，不得借机械故障过滤假绿');
    assert.equal(legacyGenericNonAnswer(plan.content), false,
      '本场景必须使用未列入历史固定 generic 集合的具体澄清');
    const job = f.makeJob(session, 'ae01-bare-clarification-unsent', plan, {
      failure_rounds: 4, failure_since: f.now() - 10000,
    });
    settleAe01ProviderPlan(f, job, plan);
    assert.equal(Object.hasOwn(job, 'answer_evidence'), false);
    await f.seed(session, (state) => state.jobs.push(job));
    f.restart();
    const result = await f.runtime().process(f.key(session), job.id);
    const stored = f.rawState(session).jobs.find((item) => item.id === job.id);
    assert.equal(result.status, 'answer_evidence_unavailable',
      '裸 plan 必须进入明确的失权迁移，不能直接形成可见成功');
    assert.equal(f.postAttempts.length, 0, '无可信 evidence 时不得 POST 遗留正文');
    assert.equal(f.sent.length, 0);
    assert.equal(f.modelRequests.length, 0, '旧 plan 迁移不得在同一调用栈偷偷重新推理');
    assert.equal(ae01ReplyEvents(f).length, 0);
    assert(stored, '同一原始应答责任必须保留');
    assert.equal(stored.responsibility_status, 'unresolved_failure');
    assert.equal(stored.failure_code, 'answer_evidence_unavailable');
    assert.notEqual(stored.responsibility_status, 'answered_confirmed');
    assert.notEqual(stored.responsibility_status, 'clarification_confirmed');
    assert.equal(stored.plan, undefined, '失权裸 plan 不得留给下一轮自动重发');
    assert.equal(stored.response_generation, 1,
      '旧输出身份失权后必须推进一次响应代次，不能复用原 fingerprint 身份');
    assert.equal(stored.status, 'received');
    assert.equal(stored.retry_at, f.now(), '首次迁移必须在下一调度 tick 立即重规划');
    assert.equal(stored.failure_rounds, 4,
      '回答权威迁移不是一次新 Provider 故障，不得放大失败轮次');
    assert.equal(stored.failure_since, job.failure_since);
    assert.equal(Object.values(f.rawState(session).outgoing)
      .filter((record) => record.job_id === job.id).length, 0);
    assert.equal(Object.hasOwn(stored, 'answer_evidence'), false);
    assert.equal(Object.hasOwn(stored, 'answer_metrics_counted'), false);
    assert.equal(Object.hasOwn(f.rawState(session).observations || {}, 'ai_reply_sent_at'), false);
    assert(stored.data); assert.deepEqual(stored.data.content, job.data.content);

    const recovered = await f.runtime().process(f.key(session), job.id);
    assert.equal(recovered.status, 'sent', '同一持久责任必须在下一轮恢复为实际答案');
    const completed = f.rawState(session).jobs.find((item) => item.id === job.id);
    assert.equal(completed.status, 'done');
    assert.equal(completed.responsibility_status, 'answered_confirmed');
    assert.equal(completed.response_generation, 1);
    assert.equal(f.modelRequests.length, 1);
    assert.equal(f.sent.length, 1);
    assert.equal(f.sent[0].content, f.modes.answer);
    assert.notEqual(f.sent[0].content, ae01Clarification);
  });

  await test('AE01a2 同一责任再次出现失权裸 clarification 时有界转人工审核', async () => {
    const f = makeFixture('ae01-bare-clarification-repeat');
    applyAe01Materials(f);
    const session = 'session_ae01-bare-clarification-repeat';
    const plan = ae01Plan(77607);
    const job = f.makeJob(session, 'ae01-bare-clarification-repeat', plan, {
      response_generation: 1, responsibility_status: 'unresolved_failure',
      failure_code: 'answer_evidence_unavailable', failure_rounds: 2,
      failure_since: f.now() - 10000, retry_at: f.now(),
    });
    settleAe01ProviderPlan(f, job, plan);
    await f.seed(session, (state) => state.jobs.push(job));
    f.restart();
    assert.equal((await f.runtime().process(f.key(session), job.id)).status,
      'answer_evidence_unavailable');
    const stored = f.rawState(session).jobs.find((item) => item.id === job.id);
    assert.equal(stored.status, 'done');
    assert.equal(stored.responsibility_status, 'unresolved_failure');
    assert.equal(stored.failure_code, 'answer_evidence_unavailable');
    assert.equal(stored.recovery_requires_review, true);
    assert.equal(stored.retry_at, null);
    assert.equal(stored.response_generation, 1,
      '重复失权不得无限推进响应代次');
    assert.equal(stored.failure_rounds, 2,
      '重复失权也不得伪造 Provider 故障轮次');
    assert(stored.data);
    assert.equal(f.postAttempts.length, 0);
    assert.equal(f.sent.length, 0);
    assert.equal(f.modelRequests.length, 0);
    assert.deepEqual(await f.runtime().scan(), []);
  });

  await test('AE01b 已确认 sent 但缺 answer evidence 时保留防重事实且不假回答', async () => {
    const f = makeFixture('ae01-bare-clarification-sent');
    applyAe01Materials(f);
    const session = 'session_ae01-bare-clarification-sent';
    const plan = ae01Plan(77601);
    const job = f.makeJob(session, 'ae01-bare-clarification-sent', plan);
    settleAe01ProviderPlan(f, job, plan);
    const outgoing = sealAe01SentRecord(f, job, plan, f.makeOutgoing(job, plan.content, 'sent'));
    assert.equal(Object.hasOwn(job, 'answer_evidence'), false);
    assert.equal(Object.hasOwn(outgoing, 'answer_evidence_core_sha256'), false);
    await f.seed(session, (state) => {
      state.jobs.push(job);
      state.outgoing[String(plan.fingerprint)] = outgoing;
    });
    f.restart();
    const result = await f.runtime().process(f.key(session), job.id);
    assert.equal(result.status, 'delivery_evidence_unavailable');
    const state = f.rawState(session);
    const retained = state.outgoing[String(plan.fingerprint)];
    const unresolved = state.jobs.find((item) => item.id === job.id);
    assert(retained, '已确认投递记录必须保留为防重事实');
    assert.equal(retained.status, 'sent');
    assert.equal(retained.job_id, job.id);
    assert.equal(retained.delivery_identity_version, 1);
    assert.equal(retained.purpose, plan.purpose);
    assert.equal(retained.message_type, plan.type);
    assert.equal(retained.semantic_intent, 'answer');
    assert.equal(retained.response_generation, 0);
    assert.equal(retained.semantic_status, 'valid_answer', '投递语义事实不得被改写成回答权威');
    assert.equal(retained.receipt_current, true);
    assert.equal(retained.content_sha256, outgoing.content_sha256);
    assert.equal(Object.hasOwn(retained, 'body'), false);
    assert.equal(unresolved.status, 'done');
    assert.equal(unresolved.responsibility_status, 'unresolved_failure');
    assert.equal(unresolved.failure_code, 'delivery_evidence_unavailable');
    assert.equal(unresolved.recovery_requires_review, true);
    assert.equal(unresolved.retry_at, null);
    assert(unresolved.data, '投递成功但授权证据缺失时仍须保留原始责任');
    assert.deepEqual(unresolved.data.content, job.data.content);
    assert.equal(Object.hasOwn(unresolved, 'answer_evidence'), false);
    assert.equal(Object.hasOwn(unresolved, 'answer_metrics_counted'), false);
    assert.equal(Object.hasOwn(retained, 'answer_evidence_core_sha256'), false);
    assert.deepEqual(Object.entries(state.outgoing)
      .filter(([, record]) => record.job_id === job.id).map(([fingerprint]) => fingerprint),
      [String(plan.fingerprint)], '同一 job 只能保留原始 fingerprint 的一份防重事实');
    assert.equal(Object.hasOwn(state.observations || {}, 'ai_reply_sent_at'), false);
    assert.equal(f.postAttempts.length, 0); assert.equal(f.sent.length, 0);
    assert.equal(ae01ReplyEvents(f).length, 0);
  });

  await test('AE01c unknown 精确命中只能确认投递，缺 evidence 仍不得终结为回答', async () => {
    const f = makeFixture('ae01-bare-clarification-unknown');
    applyAe01Materials(f);
    const session = 'session_ae01-bare-clarification-unknown';
    const plan = ae01Plan(77602);
    const job = f.makeJob(session, 'ae01-bare-clarification-unknown', plan);
    settleAe01ProviderPlan(f, job, plan);
    const outgoing = freezeAe01OutgoingIdentity(job, plan,
      f.makeOutgoing(job, plan.content, 'unknown'));
    assert.equal(Object.hasOwn(job, 'answer_evidence'), false);
    assert.equal(Object.hasOwn(outgoing, 'answer_evidence_core_sha256'), false);
    const remote = { ...outgoing.body, website_id: f.env.CRISP_WEBSITE_ID,
      session_id: session, timestamp: f.now() - 1000 };
    await f.seed(session, (state) => {
      state.jobs.push(job);
      state.outgoing[String(plan.fingerprint)] = outgoing;
    });
    f.histories.set(session, [remote]);
    f.restart();
    const result = await f.runtime().process(f.key(session), job.id);
    assert.equal(result.status, 'delivery_evidence_unavailable');
    const state = f.rawState(session);
    const retained = state.outgoing[String(plan.fingerprint)];
    const unresolved = state.jobs.find((item) => item.id === job.id);
    assert.equal(retained.status, 'sent');
    assert.equal(retained.job_id, job.id);
    assert.equal(retained.delivery_identity_version, 1);
    assert.equal(retained.purpose, plan.purpose);
    assert.equal(retained.message_type, plan.type);
    assert.equal(retained.semantic_intent, 'answer');
    assert.equal(retained.response_generation, 0);
    assert.equal(retained.semantic_status, 'valid_answer');
    assert.equal(retained.receipt_current, true);
    assert.equal(retained.content_sha256,
      digest(canonical({ type: plan.type, content: plan.content })));
    assert.equal(unresolved.status, 'done');
    assert.equal(unresolved.responsibility_status, 'unresolved_failure');
    assert.equal(unresolved.failure_code, 'delivery_evidence_unavailable');
    assert.equal(unresolved.recovery_requires_review, true);
    assert.equal(unresolved.retry_at, null);
    assert(unresolved.data); assert.deepEqual(unresolved.data.content, job.data.content);
    assert.equal(Object.hasOwn(unresolved, 'answer_evidence'), false);
    assert.equal(Object.hasOwn(unresolved, 'answer_metrics_counted'), false);
    assert.equal(Object.hasOwn(retained, 'answer_evidence_core_sha256'), false);
    assert.deepEqual(Object.entries(state.outgoing)
      .filter(([, record]) => record.job_id === job.id).map(([fingerprint]) => fingerprint),
      [String(plan.fingerprint)], '远端确认后仍只能保留原始 fingerprint 的一份防重事实');
    assert.equal(Object.hasOwn(state.observations || {}, 'ai_reply_sent_at'), false);
    assert.deepEqual(f.histories.get(session), [remote], '只读对账不得改写远端历史');
    assert.equal(f.postAttempts.length, 0); assert.equal(f.sent.length, 0);
    assert.equal(ae01ReplyEvents(f).length, 0,
      '确认投递不等于确认知识回答或必要澄清');
  });

  await test('AE01d technical 与已证 non-answer 保持原分类，不被 evidence 缺口洗成回答', async () => {
    const technical = makeFixture('ae01-technical-control');
    applyAe01Materials(technical);
    const technicalSession = 'session_ae01-technical-control';
    const technicalPlan = { type: 'internal', purpose: 'technical_unresolved', ordinary: true,
      content: '', answer_responsibility: 'unresolved_failure', diagnostic_code: 'synthetic_evidence_control' };
    const technicalJob = technical.makeJob(technicalSession, 'ae01-technical-control', technicalPlan);
    await technical.seed(technicalSession, (state) => state.jobs.push(technicalJob));
    technical.restart();
    assert.equal((await technical.runtime().process(technical.key(technicalSession), technicalJob.id)).status,
      'unresolved');
    const technicalStored = technical.rawState(technicalSession).jobs.find((item) => item.id === technicalJob.id);
    assert.equal(technicalStored.status, 'received');
    assert.equal(technicalStored.responsibility_status, 'unresolved_failure');
    assert.equal(technicalStored.failure_code, 'synthetic_evidence_control');
    assert(technicalStored.data);
    assert.equal(technical.postAttempts.length, 0); assert.equal(technical.sent.length, 0);
    assert.equal(ae01ReplyEvents(technical).length, 0);

    const nonAnswer = makeFixture('ae01-delivered-nonanswer-control');
    applyAe01Materials(nonAnswer);
    const nonAnswerSession = 'session_ae01-delivered-nonanswer-control';
    const nonAnswerPlan = { type: 'text', purpose: 'ai_text', ordinary: true, ai: true,
      content: clarification, fingerprint: 77603, answer_responsibility: 'clarification_confirmed' };
    const nonAnswerJob = nonAnswer.makeJob(nonAnswerSession, 'ae01-delivered-nonanswer-control', nonAnswerPlan);
    settleAe01ProviderPlan(nonAnswer, nonAnswerJob, nonAnswerPlan);
    const nonAnswerOutgoing = nonAnswer.makeOutgoing(nonAnswerJob, nonAnswerPlan.content, 'sent');
    Object.assign(nonAnswerOutgoing, { purpose: nonAnswerPlan.purpose, message_type: nonAnswerPlan.type,
      semantic_intent: 'answer', semantic_status: 'valid_answer', response_generation: 0,
      content_sha256: digest(canonical({ type: nonAnswerPlan.type, content: nonAnswerPlan.content })) });
    delete nonAnswerOutgoing.body;
    await nonAnswer.seed(nonAnswerSession, (state) => {
      state.jobs.push(nonAnswerJob);
      state.outgoing[String(nonAnswerPlan.fingerprint)] = nonAnswerOutgoing;
    });
    nonAnswer.restart();
    assert.equal((await nonAnswer.runtime().process(nonAnswer.key(nonAnswerSession), nonAnswerJob.id)).status,
      'delivered_non_answer');
    const nonAnswerState = nonAnswer.rawState(nonAnswerSession);
    const nonAnswerStored = nonAnswerState.jobs.find((item) => item.id === nonAnswerJob.id);
    assert.equal(nonAnswerState.outgoing[String(nonAnswerPlan.fingerprint)].semantic_status,
      'delivered_non_answer');
    assert.equal(nonAnswerStored.status, 'received');
    assert.equal(nonAnswerStored.responsibility_status, 'unresolved_failure');
    assert.equal(nonAnswerStored.failure_code, 'delivered_non_answer');
    assert(nonAnswerStored.data);
    assert.equal(nonAnswer.postAttempts.length, 0); assert.equal(nonAnswer.sent.length, 0);
    assert.equal(ae01ReplyEvents(nonAnswer).length, 0);
  });

  await test('AE01e 人工与总开关静默优先，裸 clarification 字段不能抢答或改写控制', async () => {
    for (const mode of ['human', 'global-off']) {
      const f = makeFixture('ae01-policy-silence-' + mode);
      applyAe01Materials(f, mode !== 'global-off');
      const session = 'session_ae01-policy-silence-' + mode;
      const plan = ae01Plan(mode === 'human' ? 77604 : 77605);
      const generation = mode === 'human' ? 1 : 0;
      const job = f.makeJob(session, 'ae01-policy-silence-' + mode, plan, { generation });
      settleAe01ProviderPlan(f, job, plan);
      await f.seed(session, (state) => {
        state.jobs.push(job);
        if (mode === 'human') {
          state.mode = 'human'; state.generation = generation; state.resume_at = null;
          state.pause_reason = 'confirmed_handoff'; state.last_human_at = f.now() - 1000;
          state.control_watermark = f.now() - 1000;
        }
      });
      f.restart();
      const result = await f.runtime().process(f.key(session), job.id);
      assert(['idle', 'cancelled'].includes(result.status));
      const state = f.rawState(session);
      const silent = state.jobs.find((item) => item.id === job.id);
      assert.equal(silent.status, 'cancelled');
      assert.equal(silent.responsibility_status, 'intentional_silence');
      assert.equal(silent.responsibility_reason, mode === 'human' ? 'human_handoff' : 'global_disabled');
      assert.equal(state.mode, mode === 'human' ? 'human' : 'ai');
      assert.equal(f.postAttempts.length, 0); assert.equal(f.sent.length, 0);
      assert.equal(f.modelRequests.length, 0); assert.equal(ae01ReplyEvents(f).length, 0);
    }
  });

  await test('AE01f evidence 门禁不按问句形态拒绝本地受控具体澄清', async () => {
    const f = makeFixture('ae01-local-specific-clarification');
    applyAe01Materials(f);
    const session = 'session_ae01-local-specific-clarification';
    const plan = { type: 'text', purpose: 'keyword_reply', ordinary: true,
      content: ae01Clarification, fingerprint: 77606 };
    const job = f.makeJob(session, 'ae01-local-specific-clarification', plan);
    await f.seed(session, (state) => state.jobs.push(job));
    f.restart();
    assert.equal((await f.runtime().process(f.key(session), job.id)).status, 'sent');
    const answered = f.rawState(session).jobs.find((item) => item.id === job.id);
    assert.equal(f.postAttempts.length, 1); assert.equal(f.sent.length, 1);
    assert.equal(f.sent[0].content, ae01Clarification);
    assert.equal(answered.status, 'done');
    assert.equal(answered.responsibility_status, 'answered_confirmed');
    assert.notEqual(answered.responsibility_status, 'clarification_confirmed');
    assert.equal(f.modelRequests.length, 0); assert.equal(ae01ReplyEvents(f).length, 0);
  });

  await test('AE02 deferred 出站身份错配时保留原责任并停止可见发送', async () => {
    for (const mismatch of ['semantic_intent', 'content_sha256']) {
      const f = makeFixture('ae02-deferred-identity-' + mismatch);
      applyAe01Materials(f);
      const session = 'session_ae02-deferred-identity-' + mismatch.replaceAll('_', '-');
      const plan = { type: 'text', purpose: 'keyword_reply', ordinary: true,
        content: '受管固定回复的延迟身份负例', fingerprint: mismatch === 'semantic_intent' ? 77608 : 77609,
        answer_responsibility: 'clarification_confirmed' };
      const job = f.makeJob(session, 'ae02-deferred-identity-' + mismatch, plan,
        { response_generation: 2, failure_rounds: 3, failure_since: f.now() - 10000 });
      const outgoing = freezeAe01OutgoingIdentity(job, plan,
        f.makeOutgoing(job, plan.content, 'rejected'));
      Object.assign(outgoing, {
        failure: 'crisp_http_403', recovery_deferred: true,
        next_action_at: f.now(), resend_forbidden: false,
      });
      if (mismatch === 'semantic_intent') outgoing.semantic_intent = 'control';
      else outgoing.content_sha256 = outgoing.content_sha256 === '0'.repeat(64)
        ? '1'.repeat(64) : '0'.repeat(64);
      const frozenRecord = structuredClone(outgoing);
      const frozenPlan = structuredClone(plan);
      const frozenData = structuredClone(job.data);
      await f.seed(session, (state) => {
        state.jobs.push(job);
        state.outgoing[String(plan.fingerprint)] = outgoing;
      });
      f.restart();
      const result = await f.runtime().process(f.key(session), job.id);
      assert.equal(result.status, 'delivery_identity_unresolved', mismatch);
      const state = f.rawState(session);
      const stored = state.jobs.find((item) => item.id === job.id);
      assert.equal(stored.status, 'done');
      assert.equal(stored.responsibility_status, 'unresolved_failure');
      assert.equal(stored.failure_code, 'delivery_identity_unresolved');
      assert.equal(stored.recovery_requires_review, true);
      assert.equal(stored.retry_at, null);
      assert.deepEqual(stored.plan, frozenPlan, mismatch + ' 冲突不得删除或替换原计划');
      assert.deepEqual(stored.data, frozenData, mismatch + ' 冲突不得删除原始访客责任');
      assert.equal(stored.generation, job.generation);
      assert.equal(stored.response_generation, 2);
      assert.deepEqual(state.outgoing[String(plan.fingerprint)], frozenRecord,
        mismatch + ' 冲突不得取消、改写或换代原 deferred 记录');
      assert.equal(f.postAttempts.length, 0);
      assert.equal(f.sent.length, 0);
      assert.equal(f.modelRequests.length, 0);
      assert.equal(ae01ReplyEvents(f).length, 0);
    }
  });

  await test('AE03 control 携带遗留 clarification 声明时仍发送、打标签并正确终结', async () => {
    const f = makeFixture('ae03-control-legacy-claim-tag');
    applyAe01Materials(f);
    const session = 'session_ae03-control-legacy-claim-tag';
    const plan = { type: 'text', purpose: 'handoff_ack', ordinary: false,
      content: '您的人工协助请求已收到。', fingerprint: 77610,
      tags: ['human_required'], answer_responsibility: 'clarification_confirmed' };
    const job = f.makeJob(session, 'ae03-control-legacy-claim-tag', plan,
      { control: true, action: 'confirm_handoff', generation: 1 });
    await f.seed(session, (state) => {
      state.mode = 'human';
      state.generation = 1;
      state.pause_reason = 'confirmed_handoff';
      state.resume_at = f.now() + 3600000;
      state.jobs.push(job);
    });
    f.restart();
    assert.equal((await f.runtime().process(f.key(session), job.id)).status, 'sent');
    const state = f.rawState(session);
    const stored = state.jobs.find((item) => item.id === job.id);
    const outgoing = state.outgoing[String(plan.fingerprint)];
    assert.equal(f.postAttempts.length, 1);
    assert.equal(f.sent.length, 1);
    assert.equal(f.sent[0].content, plan.content);
    assert.equal(f.patches.length, 1);
    assert.deepEqual(f.patches[0].segments.sort(),
      ['existing-manual-segment', 'human_required'].sort());
    assert.equal(outgoing.status, 'sent');
    assert.equal(outgoing.semantic_intent, 'control');
    assert.equal(outgoing.semantic_status, 'control_delivered');
    assert.equal(stored.status, 'done');
    assert.equal(stored.responsibility_status, 'control_handled');
    assert.equal(stored.responsibility_reason, 'confirm_handoff');
    assert.equal(stored.data, undefined);
    assert.equal(stored.plan, undefined);
    assert.equal(f.modelRequests.length, 0);
    assert.equal(f.retrievalRequests.length, 0);
    assert.equal(ae01ReplyEvents(f).length, 0);
    assert.equal((await f.runtime().process(f.key(session), job.id)).status, 'idle');
    assert.equal(f.postAttempts.length, 1);
    assert.equal(f.patches.length, 1);
  });

  await test('AE04 最终责任事务写入失败不制造回答成功，恢复只收敛同一 sent', async () => {
    const f = makeFixture('ae04-finalization-commit-eio');
    applyAe01Materials(f);
    const session = 'session_ae04-finalization-commit-eio';
    const input = f.event(session, '请验证最终责任事务失败后的恢复');
    const accepted = await f.receive(input);
    assert.equal(accepted.route, 'process');
    const stateFile = path.join(f.root, 'data/runtime/session-' + f.key(session) + '.json');
    const originalRenameSync = fs.renameSync;
    let injected = false;
    try {
      fs.renameSync = (source, destination) => {
        if (!injected && destination === stateFile && fs.existsSync(source)) {
          let candidate = null;
          try { candidate = JSON.parse(fs.readFileSync(source, 'utf8')); } catch (_) {}
          const stored = candidate?.jobs?.find((item) => item.id === accepted.jobId);
          const sentRecord = Object.values(candidate?.outgoing || {})
            .find((record) => record?.job_id === accepted.jobId && record.status === 'sent');
          if (stored?.status === 'done' && stored.answer_metrics_counted === true
            && Number.isFinite(candidate?.observations?.ai_reply_sent_at) && sentRecord) {
            injected = true;
            const error = new Error('synthetic-finalization-commit-eio');
            error.code = 'EIO';
            throw error;
          }
        }
        return originalRenameSync(source, destination);
      };
      const failed = await f.runtime().process(accepted.key, accepted.jobId);
      assert.equal(failed.status, 'deferred');
      assert.equal(failed.reason, 'answer_responsibility_unresolved');
    } finally {
      fs.renameSync = originalRenameSync;
    }
    assert.equal(injected, true, '必须精确命中 sent 已冻结后的最终责任事务');
    let state = f.rawState(session);
    let stored = state.jobs.find((item) => item.id === accepted.jobId);
    const sentRecords = Object.values(state.outgoing)
      .filter((record) => record?.job_id === accepted.jobId && record.status === 'sent');
    assert.equal(sentRecords.length, 1, '远端已接收的唯一 fingerprint 必须作为防重事实保留');
    assert.equal(stored.status, 'received');
    assert.equal(stored.responsibility_status, 'unresolved_failure');
    assert.equal(stored.failure_code, 'persisted_plan_delivery_pending');
    assert(Number.isFinite(stored.retry_at) && stored.retry_at > f.now(),
      '终态写入失败必须登记有界恢复时间，不能忙循环');
    assert(stored.data, '终态提交失败必须保留原始应答责任');
    assert(stored.plan, '终态提交失败必须保留已发送计划供同指纹收敛');
    assert.notEqual(stored.responsibility_status, 'answered_confirmed');
    assert.equal(Object.hasOwn(stored, 'answer_metrics_counted'), false);
    assert.equal(Object.hasOwn(state.observations || {}, 'ai_reply_sent_at'), false);
    assert.equal(ae01ReplyEvents(f).length, 0);
    assert.equal(f.postAttempts.length, 1);
    assert.equal(f.sent.length, 1);
    assert.equal(f.modelRequests.length, 1);

    f.advance(stored.retry_at - f.now() + 1);
    f.restart();
    assert.equal((await f.runtime().process(f.key(session), accepted.jobId)).status, 'sent');
    state = f.rawState(session);
    stored = state.jobs.find((item) => item.id === accepted.jobId);
    assert.equal(stored.status, 'done');
    assert.equal(stored.responsibility_status, 'answered_confirmed');
    assert.equal(stored.answer_metrics_counted, true);
    assert(Number.isFinite(state.observations.ai_reply_sent_at));
    assert.equal(ae01ReplyEvents(f).length, 1);
    assert.equal(f.postAttempts.length, 1, '恢复只收敛既有 sent，不得再次 POST');
    assert.equal(f.sent.length, 1);
    assert.equal(f.modelRequests.length, 1, '恢复不得重新推理');
  });

  fs.writeFileSync(path.join(evidence, 'result.json'), JSON.stringify({ layer: 'UNIT/CONTRACT', passed, failed, synthetic_only: true }, null, 2));
  process.stdout.write(JSON.stringify({ layer: 'UNIT/CONTRACT', passed, failed, synthetic_only: true, evidence: path.relative(project, evidence) }) + '\n');
  if (failed) process.exitCode = 1;
})().catch((error) => { process.stderr.write(error.stack + '\n'); process.exitCode = 1; });
