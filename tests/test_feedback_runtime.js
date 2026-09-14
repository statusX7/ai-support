'use strict';

// 全部资料与网络回应均为 synthetic；测试直接运行生产 runtime，不连接真实 Crisp。
const assert = require('assert/strict');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { spawnSync } = require('child_process');
const { createRuntime, mechanicalFailureAnswer } = require('../n8n/runtime');
const { visitorFallbackFor } = require('../scripts/visitor-output');

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
const makeFixture = (name) => {
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
  const env = { CRISP_WEBSITE_ID: '11111111-1111-4111-8111-111111111111', CRISP_WEBSITE_HOOK_SECRET: 'synthetic-feedback-hook-0001', CRISP_AUTH_B64: 'synthetic-feedback-auth', AI_API_KEY: 'synthetic-feedback-key', AI_SUPPORTS_VISION: 'true', ANYTHINGLLM_API_KEY: 'synthetic-feedback-rag', ANYTHINGLLM_WORKSPACE: 'synthetic-feedback' };
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
      if (suffix === '/meta' && options.method === 'GET') return { status: 200, body: { error: false, data: { segments: ['existing-manual-segment'] } } };
      if (suffix === '/meta' && options.method === 'PATCH') { patches.push(options.body); return { status: 200, body: { error: false } }; }
      if (suffix === '/message' && options.method === 'POST') {
        const body = structuredClone(options.body);
        postAttempts.push({ ...body, session_id: session });
        if (modes.crispDropBeforeAccept) {
          if (modes.onCrispPost) await modes.onCrispPost({ body, signal: options.signal });
          throw Object.assign(new Error('synthetic-crisp-post-dropped'), { code: 'ECONNRESET' });
        }
        sent.push({ ...body, session_id: session });
        history.push({ ...body, timestamp: now }); histories.set(session, history);
        if (modes.onCrispPost) await modes.onCrispPost({ body, signal: options.signal });
        if (modes.crispPostThrow || options.signal?.aborted) throw Object.assign(new Error('synthetic-crisp-post-uncertain'), { code: 'ECONNRESET' });
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
  restart();
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
  const makeOutgoing = (job, content, status = 'unknown') => ({ status, body: { type: job.plan.type || 'text', from: 'operator', origin: 'chat', automated: true, fingerprint: job.plan.fingerprint, content }, created_at: now - 15000, attempts: 1, job_id: job.id, generation: 0 });
  const writeAppliedMaterials = (configuration) => {
    const revision = configuration.runtime.revision;
    const mapFile = path.join(root, 'data/runtime/knowledge-map.json');
    const mapRaw = fs.readFileSync(mapFile);
    const settings = Buffer.from(JSON.stringify({ schema_version: 1, workspace_slug: env.ANYTHINGLLM_WORKSPACE,
      temperature: 0.7, observed_at: now }));
    fs.writeFileSync(path.join(root, 'data/runtime/knowledge-settings.json'), settings, { mode: 0o600 });
    const profile = { engine: 'native', model: 'synthetic-feedback-embedding', chunk_size: 1000,
      chunk_overlap: 20, passage_prefix: '', query_prefix: '', component_version: 'synthetic' };
    const profileProjection = Buffer.from(JSON.stringify({ schema_version: 1, state: 'applied', profile,
      fingerprint: digest(canonical(profile)), applied_at: now }));
    fs.writeFileSync(path.join(root, 'data/runtime/knowledge-profile.json'), profileProjection, { mode: 0o600 });
    const lexicalPayload = { schema_version: 2, algorithm: 'crispai-lexical-v2',
      map_sha256: digest(mapRaw), complete: false,
      coverage: { source_documents: 1, indexed_documents: 0, omitted_documents: 1,
        source_bytes: 0, indexed_bytes: 0, omitted_bytes: 0, reasons: ['empty_source'] },
      passages: [] };
    const lexical = Buffer.from(JSON.stringify({ ...lexicalPayload,
      payload_sha256: digest(canonical(lexicalPayload)) }));
    fs.writeFileSync(path.join(root, 'data/runtime/knowledge-lexical.json'), lexical, { mode: 0o600 });
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
    fs.writeFileSync(path.join(root, 'config/materials-applied.json'), JSON.stringify(materials), { mode: 0o600 });
    return materials;
  };
  const events = () => { const file = path.join(root, 'data/analytics/events.jsonl'); return fs.existsSync(file) ? fs.readFileSync(file, 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse) : []; };
  const noFeedback = () => {
    assert(!sent.some((item) => typeof item.content === 'string' && item.content.includes(invitation)), '不能发送系统自动评价邀请');
    assert(!events().some((item) => item.type === 'feedback'), '不能新登记自动评价');
  };
  return { root, prompt, env, sent, postAttempts, patches, histories, exactRequests,
    catchupConversationPages, catchupRequests, modelRequests, visionRequests, retrievalRequests,
    workspaceRequests, modes, key, state, rawState, seed, makeJob, makeOutgoing, event,
    receive, deliver, readConfig, writeConfig, writeAppliedMaterials, restart, events, noFeedback,
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
  assert.equal(result.status, 'sent');
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
      for (const session of ['session_before001', 'session_after0001']) {
        f.restart(); await f.deliver(f.event(session, '如何保存设置？'));
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
    const normal = f.makeJob(session, 'answer', { type: 'text', purpose: 'ai_text', content: f.modes.answer, ordinary: true, ai: true, feedback: true, fingerprint: 51001 });
    const ordinary = f.makeJob(session, 'question');
    const retired = ['feedback', 'feedback_invite', 'feedback_thanks', 'feedback_clarification'].map((purpose, index) => f.makeJob(session, purpose, { type: 'text', purpose, content: '旧评价专用文案', fingerprint: 52001 + index }));
    retired.push(f.makeJob(session, 'event-marker', { type: 'text', purpose: 'legacy', content: '旧评价感谢', feedback_event: { feedback: 'negative' }, fingerprint: 52009 }));
    await f.seed(session, (state) => {
      state.jobs.push(...retired, normal, ordinary);
      state.worker = { job: retired[0].id, token: 'synthetic-old-worker', until: f.now() + 200000 };
      state.outgoing['51001'] = f.makeOutgoing(normal, f.modes.answer + '\n\n' + invitation, 'queued');
      state.offers.manual = { kind: 'handoff', expires_at: f.now() + 600000, choices: { yes: { type: 'confirm_handoff' } } };
    });
    f.restart(); const scanned = await f.runtime().scan();
    assert(retired.every((job) => f.rawState(session).jobs.find((item) => item.id === job.id).status === 'cancelled'));
    assert.equal(f.rawState(session).outgoing['51001'].body.content, f.modes.answer);
    assert(f.rawState(session).offers.manual, '人工 offer 必须保留');
    assert(scanned.some((job) => job.jobId === normal.id));
    assert(!scanned.some((job) => job.jobId === ordinary.id), '单会话每轮只调度最早的一个可执行任务');
    await f.runtime().process(f.key(session)); await f.runtime().process(f.key(session));
    assert.equal(f.sent.length, 2); assert.equal(f.modelRequests.length, 1, '缓存答案不应重新推理');
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
      const job = f.makeJob(session, 'unknown', plan);
      const outgoing = f.makeOutgoing(job, f.modes.answer + '\n\n' + invitation);
      await f.seed(session, (state) => { state.jobs.push(job); state.outgoing['71001'] = outgoing; });
      const historical = { ...outgoing.body, timestamp: f.now() - 1000 }; f.histories.set(session, [historical]);
      if (disabled) f.writeConfig('runtime', { schema_version: 2, enabled: false, revision: 2, applied_revision: 2 });
      f.restart(); await f.runtime().scan(); await f.runtime().process(f.key(session));
      assert.equal(f.sent.length, 0); assert.equal(f.modelRequests.length, 0);
      assert.equal(f.rawState(session).outgoing['71001'].status, 'sent');
      assert.deepEqual(f.histories.get(session), [historical]);
      assert.equal(f.events().filter((event) => event.type === 'ai_reply').length, disabled ? 0 : 1);
      assert.equal(f.events().filter((event) => event.type === 'delivery_after_state_change').length, disabled ? 1 : 0,
        '状态已变化的历史回执必须单列，不能冒充当前正常 AI 回复');
      assert.equal(f.state(session).pending_feedback, null); f.noFeedback();
    }
  });

  await test('F06 旧 unknown 普通答案未送达时复用原 plan，仅重发无评价正文', async () => {
    const f = makeFixture('unknown-absent'); const session = 'session_absent0001';
    const job = f.makeJob(session, 'unknown', { type: 'text', purpose: 'ai_text', ordinary: true, ai: true, feedback: true, content: f.modes.answer, fingerprint: 72001 });
    await f.seed(session, (state) => { state.jobs.push(job); state.outgoing['72001'] = f.makeOutgoing(job, f.modes.answer + '\n\n' + invitation); });
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
    f.advance(6000); f.modes.historyFailure = false; await f.runtime().process(f.key(session));
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
    await f.deliver(f.event('session_disable01', '否'));
    assert.equal(f.sent.length, count); assert.equal(f.modelRequests.length, inferenceCount); f.noFeedback();
  });

  await test('F10 用户与业务正文中相似评价文字完整保留，仅移除可证明的系统后缀', async () => {
    const f = makeFixture('owned-suffix'); const session = 'session_ownership1';
    const quoted = '业务文档引用的原句：\n' + invitation;
    const job = f.makeJob(session, 'quoted', { type: 'text', purpose: 'ai_text', ordinary: true, feedback: true, content: quoted, fingerprint: 75001 });
    const other = f.makeJob(session, 'ambiguous', { type: 'text', purpose: 'keyword_reply', ordinary: true, content: '普通答案', fingerprint: 75002 });
    const ambiguousBody = '普通答案\n\n' + invitation;
    await f.seed(session, (state) => {
      state.jobs.push(job, other);
      state.outgoing['75001'] = f.makeOutgoing(job, (quoted + '\n\n' + invitation).slice(0, 8000), 'queued');
      state.outgoing['75002'] = f.makeOutgoing(other, ambiguousBody, 'queued');
    });
    await f.runtime().scan();
    assert.equal(f.rawState(session).outgoing['75001'].body.content, quoted);
    assert.equal(f.rawState(session).outgoing['75002'].body.content, ambiguousBody, '无系统追加证据的缓存不能按相似文本清理');
    await f.runtime().process(f.key(session)); assert.equal(f.sent[0].content, quoted);
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
      const job = f.makeJob(session, 'old-result', { type: 'text', purpose, ordinary: true, feedback: true, content: f.modes.answer, fingerprint: 76001 }, { received_at: f.now() - 600000 });
      const outgoing = f.makeOutgoing(job, f.modes.answer + '\n\n' + invitation);
      outgoing.created_at = f.now() - 590000;
      outgoing.delivery_uncertain = true;
      await f.seed(session, (state) => { state.jobs.push(job); state.outgoing['76001'] = outgoing; });
      if (found) f.histories.set(session, [{ ...outgoing.body, timestamp: f.now() - 589000 }]);
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
        f.advance(8 * 86400000); f.restart();
        assert((await f.runtime().scan()).some((item) => item.jobId === job.id), '跨日志期限仍须调度同一对账责任');
        stored = f.rawState(session); pending = stored.jobs.find((entry) => entry.id === job.id);
        assert(pending, '未知投递关联 job 不得按日志期限删除');
        assert.equal(stored.outgoing['76001'].status, 'unknown');
        assert.equal(stored.outgoing['76001'].body.content, outgoing.body.content);
      } else {
        assert.equal(first.status, purpose === 'ai_text' ? 'sent' : 'cancelled');
        assert.equal(f.rawState(session).outgoing['76001'].status, 'sent');
      }
      const restoredJob = f.rawState(session).jobs.find((entry) => entry.id === job.id);
      if (purpose === 'ai_text') {
        assert.notEqual(restoredJob.feedback_retired, true, '超时普通答案不能误标为评价');
        assert.equal(restoredJob.status, found ? 'done' : 'received');
      }
      assert.equal(f.events().filter(event => event.type === 'delivery_failed' && event.reason === 'delivery_unknown').length, 0);
      assert.equal(f.sent.length, 0); assert.equal(f.modelRequests.length, 0);
      assert.equal(f.state(session).pending_feedback, null);
    }
  });

  await test('F13 发送注册前接口池代次改变时不发旧正文并持久延后重规划', async () => {
    const f = makeFixture('provider-register-race'); const session = 'session_poolrace1';
    const poolFile = path.join(f.root, 'config/provider-pool-applied.json');
    const pool = { schema_version: 1, revision: 1, primary_id: 'synthetic-primary', policy: { question_timeout_ms: 90000 }, entries: [{ id: 'synthetic-primary', enabled: true, model: 'synthetic-model' }] };
    fs.writeFileSync(poolFile, JSON.stringify(pool));
    const job = f.makeJob(session, 'cached-answer', { type: 'text', purpose: 'ai_text', ordinary: true, content: f.modes.answer, fingerprint: 77001 }, { inference: { pool_revision: 1, deadline_at: f.now() + 90000 } });
    await f.seed(session, (state) => { state.jobs.push(job); });
    const originalRead = fs.readFileSync; let poolReads = 0;
    try {
      fs.readFileSync = (file, ...args) => {
        const result = originalRead(file, ...args);
        // 在第二次 active 读取快照后发布新代次，强制覆盖最终注册检查这一真实窗口。
        if (file === poolFile && ++poolReads === 2) fs.writeFileSync(poolFile, JSON.stringify({ ...pool, revision: 2 }));
        return result;
      };
      assert.equal((await f.runtime().process(f.key(session))).status, 'deferred');
    } finally { fs.readFileSync = originalRead; }
    assert(poolReads >= 3); assert.equal(f.sent.length, 0); assert.equal(f.modelRequests.length, 0);
    assert.equal(Object.keys(f.rawState(session).outgoing).length, 0);
    const deferred = f.rawState(session).jobs.find(item => item.id === job.id);
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
        const job = f.makeJob(session, 'expired-error', null, { inference: { pool_revision: null, deadline_at: f.now() - 1 } });
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
  });

  await test('F15 旧 safe_error 与未发送缓存转为不可见责任，恢复后同一 job 重新规划一次', async () => {
    for (const kind of ['text', 'image']) for (const outgoingStatus of ['none', 'queued']) {
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
      assert.equal(normalized.plan.purpose, 'technical_unresolved');
      assert.equal(normalized.plan.content, '');
      if (outgoingStatus !== 'none') {
        assert.equal(f.rawState(session).outgoing['78001'].status, 'cancelled');
        assert.equal(Object.hasOwn(f.rawState(session).outgoing['78001'], 'body'), false);
      }
      const result = await f.runtime().process(f.key(session), job.id);
      assert.equal(result.status, 'unresolved');
      assertUnresolvedResponsibility(f, session, job.id, job.data.content);
      assert.equal(f.modelRequests.length, 0); assert.equal(f.visionRequests.length, 0);
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
        assert(['sent', 'dispatched_after_cancel'].includes(first.status));
        assert.deepEqual(f.histories.get(session), historical, '已送达历史不得被改写成另一条正文');
        assert.equal(f.rawState(session).outgoing['79001'].status, 'sent');
        const settled = f.rawState(session).jobs.find((entry) => entry.id === job.id);
        assert.notEqual(settled.responsibility_status, 'answered_confirmed',
          '旧机械正文的历史回执不能冒充本版正常回答');
      } else {
        assert.equal(first.status, 'retry');
        assert.equal(f.rawState(session).outgoing['79001'].body.content, legacyFailure);
        f.advance(5000); f.restart(); await f.runtime().scan();
        assert.equal((await f.runtime().process(f.key(session), job.id)).status, 'retry');
        assert.equal(f.postAttempts.length, 0, '两次精确负查只能退出旧机械正文，不能发送 generic 替代句');
        f.advance(5000); f.restart();
        assert.equal((await f.runtime().process(f.key(session), job.id)).status, 'unresolved');
        assertUnresolvedResponsibility(f, session, job.id, job.data.content);
        await recoverSameJobOnce(f, session, job.id, f.modes.answer);
        assert.equal(f.modelRequests.length, 1);
      }
      assert.equal(f.state(session).mode, 'ai');
    }
  });

  await test('F17 自然错误计划仍服从全局停用与人工状态，未发送时不创建身份记录', async () => {
    for (const mode of ['disabled', 'human']) {
      const f = makeFixture('natural-cancel-' + mode); const session = 'session_cancel-error';
      const job = f.makeJob(session, 'cancel-safe-error', { type: 'text', purpose: 'safe_error', ordinary: true, content: legacyFailure, fingerprint: 80001 });
      await f.seed(session, state => { state.jobs.push(job); if (mode === 'human') { state.mode = 'human'; state.resume_at = null; } });
      if (mode === 'disabled') f.writeConfig('runtime', { schema_version: 2, enabled: false, revision: 1, applied_revision: 1 });
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
    assert(textOfRequest(f.modelRequests.at(-1)).includes('不得使用“暂时无法回复，请稍后再试。”及同类系统忙、稍后再试的机械话术'));
    await f.deliver(f.event('session_error-image-rule', { url: 'https://storage.crisp.chat/synthetic.png', type: 'image/png' }, { type: 'file' }));
    assert.equal(f.visionRequests[0].messages[0].content, f.prompt);
    assert(f.visionRequests[0].messages[1].content.includes('不得使用“暂时无法回复，请稍后再试。”及同类系统忙、稍后再试的机械话术'));
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
      const f = makeFixture('natural-config-' + index), input = path.join(f.root, 'config/handoff.yaml');
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
    for (const field of Object.keys(legacy)) for (const storage of ['raw', 'applied']) for (const variant of ['example', 0, 1, 'missing', 'custom']) {
      const f = makeFixture('natural-default-' + field + '-' + storage + '-' + variant), session = 'session_natural-default';
      const policy = f.readConfig('handoff'), custom = '请告诉我你使用的设备型号与发生问题的具体步骤。';
      if (typeof variant === 'number') policy.handoff[field] = legacy[field][variant];
      if (variant === 'missing') delete policy.handoff[field];
      if (variant === 'custom') policy.handoff[field] = custom;
      f.writeConfig('handoff', policy);
      if (storage === 'applied') {
        const configuration = Object.fromEntries(['runtime', 'handoff', 'keyword', 'menu', 'tags', 'feedback'].map(name => [name, f.readConfig(name)]));
        f.writeAppliedMaterials(configuration);
        f.writeConfig('handoff', { handoff: { ...policy.handoff, [field]: '未应用编辑不应生效' } });
      }
      f.modes.retrievalPayload = { results: field === 'no_answer_message' ? [] : [retrievalResult(0.99)] };
      f.modes.answer = '合成低分候选答案';
      const input = f.event(session, '请帮我确认这个具体问题。');
      const result = await f.deliver(input);
      assert.equal(f.state(session).mode, 'ai'); assert.deepEqual(f.state(session).offers, {});
      assert.equal(f.workspaceRequests.length, 1); assert.equal(f.retrievalRequests.length, 1);
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
      const f = makeFixture('natural-normalize-' + index), policy = f.readConfig('handoff');
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
      } else {
        const job = f.makeJob(session, kind, { type: 'text', purpose: kind === 'cached-error' ? 'safe_error' : 'ai_text', ordinary: true,
          content: kind === 'cached-error' ? legacyFailure : '旧代缓存AI正文不得发送', fingerprint: 82001 });
        await f.seed(session, state => state.jobs.push(job));
        if (kind === 'register-race') {
          const lstat = fs.lstatSync; let checks = 0;
          try {
            fs.lstatSync = (file, ...args) => {
              if (file === marker && ++checks === 2) { createMarker(); throw Object.assign(new Error('synthetic-previous-missing'), { code: 'ENOENT' }); }
              return lstat(file, ...args);
            };
            result = await f.runtime().process(f.key(session));
            assert(checks >= 3, '最终注册必须再次检查维护标记');
          } finally { fs.lstatSync = lstat; }
        } else { createMarker(); result = await f.runtime().process(f.key(session)); }
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
      assert.equal(f.sent.length, 0); assert.equal(f.modelRequests.length, kind === 'model-error' ? 1 : 0);
      assert.equal(fs.readdirSync(path.join(f.root, 'data/runtime')).filter(name => name.startsWith('owned-')).length, 0);
      assert.equal(f.events().filter(event => event.type === 'ai_reply' || event.type === 'handoff').length, 0);
      const deferred = f.rawState(session).jobs.find(job => job.event === 'message:send');
      assert.equal(deferred.status, 'received'); assert.equal(deferred.deferred_configuration, true);
      assert(deferred.data, '延后任务必须保留原始访客数据');
      assert.equal(deferred.plan, undefined, '旧代AI正文必须丢弃后重新规划');
      f.writeConfig('runtime', { schema_version: 2, enabled: true, revision: 2, applied_revision: 2 });
      f.modes.onModelResponse = null; f.modes.modelFailure = false;
      fs.unlinkSync(marker); f.advance(5000); f.restart();
      assert((await f.runtime().scan()).some(item => item.jobId === deferred.id));
      const rebound = f.rawState(session).jobs.find(job => job.id === deferred.id);
      assert.equal(rebound.revision, 2); assert.equal(rebound.deferred_configuration, undefined);
      assert.equal((await f.runtime().process(f.key(session), deferred.id)).status, 'sent');
      assert.equal(f.sent.length, 1); assert.equal(f.sent[0].content, f.modes.answer);
      assert.equal(f.modelRequests.length, kind === 'model-error' ? 2 : 1,
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
    fs.unlinkSync(marker); f.advance(5000); f.restart(); await f.runtime().scan();
    const cancelled = f.rawState(sessionC).jobs.find(job => job.id === disabled.jobId);
    assert.equal(cancelled.status, 'cancelled'); assert.equal(cancelled.data, undefined);
    assert.equal(f.sent.filter(message => message.session_id === sessionC).length, 0);
    f.writeConfig('runtime', { schema_version: 2, enabled: true, revision: 3, applied_revision: 3 });
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
        if (action === 'disabled') f.writeConfig('runtime', { schema_version: 2, enabled: false, revision: 2, applied_revision: 2 });
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

  await test('F31 工作区温度严格回读后用于两种生成协议，错误形态不检索也不生成', async () => {
    for (const apiMode of ['chat_completions', 'responses']) for (const shape of ['object-default', 'array-explicit']) {
      const f = makeFixture('temperature-' + apiMode + '-' + shape);
      f.writeConfig('provider', { provider: { ...f.readConfig('provider').provider, api_mode: apiMode } });
      const workspace = { slug: f.env.ANYTHINGLLM_WORKSPACE, openAiTemp: shape === 'array-explicit' ? 0.23 : null };
      f.modes.workspacePayload = { workspace: shape === 'array-explicit' ? [workspace] : workspace };
      f.modes.expectedTemperature = shape === 'array-explicit' ? 0.23 : 0.7;
      await f.deliver(f.event('session_workspace-temperature', '虚构温度协议问题'));
      assert.equal(f.workspaceRequests.length, 1); assert.equal(f.retrievalRequests.length, 1); assert.equal(f.modelRequests.length, 1);
      assert.equal(f.modelRequests[0].temperature, f.modes.expectedTemperature);
      assert.equal(textOf(messagesOf(f.modelRequests[0])[0]), f.prompt);
      assert.equal(f.sent[0].content, f.modes.answer); assert.equal(f.state('session_workspace-temperature').mode, 'ai');
    }
    for (const failure of ['http', 'slug', 'temperature-string']) {
      const f = makeFixture('temperature-invalid-' + failure), session = 'session_workspace-invalid';
      f.modes.workspacePayload = { workspace: [{ slug: failure === 'slug' ? 'another-synthetic-workspace' : f.env.ANYTHINGLLM_WORKSPACE,
        openAiTemp: failure === 'temperature-string' ? '0.7' : null }] };
      if (failure === 'http') f.modes.workspaceStatus = 503;
      const input = f.event(session, '虚构温度失败问题');
      const result = await f.deliver(input);
      assert.equal(result.status, 'unresolved');
      assert.equal(f.workspaceRequests.length, 1); assert.equal(f.retrievalRequests.length, 0); assert.equal(f.modelRequests.length, 0);
      assertUnresolvedResponsibility(f, session, result.jobId, input.data.content);
      assert.equal(f.state(session).mode, 'ai');
      assert.equal(f.events().filter(event => ['ai_reply', 'knowledge_hit', 'knowledge_miss', 'handoff'].includes(event.type)).length, 0);
      f.modes.workspaceStatus = 200;
      f.modes.workspacePayload = { workspace: [{ slug: f.env.ANYTHINGLLM_WORKSPACE, openAiTemp: null }] };
      await recoverSameJobOnce(f, session, result.jobId, f.modes.answer);
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
    f.writeConfig('keyword', keywords); f.restart();
    const input = f.event(session, '空回复边界');
    const result = await f.deliver(input);
    assert.equal(result.status, 'unresolved');
    assertUnresolvedResponsibility(f, session, result.jobId, input.data.content);
    assert.equal(f.modelRequests.length, 0); assert.equal(f.state(session).mode, 'ai');
    const repaired = f.readConfig('keyword');
    repaired.rules.find((rule) => rule.id === 'synthetic-empty-reply').text = '已根据有效固定规则回答。';
    f.writeConfig('keyword', repaired);
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
    const poolFile = path.join(f.root, 'config/provider-pool-applied.json');
    const pool = { schema_version: 1, revision: 1, primary_id: 'synthetic-primary', policy: { question_timeout_ms: 90000 },
      entries: [{ id: 'synthetic-primary', enabled: true, model: 'synthetic-model' }] };
    fs.writeFileSync(poolFile, JSON.stringify(pool));
    const fingerprint = 77123;
    const job = f.makeJob(session, 'registered-race', { type: 'text', purpose: 'ai_text', ai: true, ordinary: true,
      content: '旧代缓存AI正文不得发送', fingerprint }, { inference: { pool_revision: 1, deadline_at: f.now() + 90000 } });
    await f.seed(session, state => state.jobs.push(job));
    const stateFile = path.join(f.root, 'data/runtime/session-' + f.key(session) + '.json');
    const rename = fs.renameSync; let injected = false;
    try {
      fs.renameSync = (from, to) => {
        const result = rename(from, to);
        if (!injected && to === stateFile) {
          const state = JSON.parse(fs.readFileSync(stateFile));
          if (state.outgoing?.[String(fingerprint)]?.status === 'sending') {
            fs.writeFileSync(poolFile, JSON.stringify({ ...pool, revision: 2 }));
            injected = true;
          }
        }
        return result;
      };
      assert.equal((await f.runtime().process(f.key(session), job.id)).status, 'deferred');
    } finally { fs.renameSync = rename; }
    assert.equal(injected, true, '必须精确触发sending已提交但Crisp POST尚未发生的窗口');
    assert.equal(f.sent.length, 0); assert.equal(f.modelRequests.length, 0);
    let stored = f.rawState(session).jobs.find(item => item.id === job.id);
    assert.equal(stored.status, 'received'); assert.equal(stored.deferred_configuration, true);
    assert(stored.data, '配置换代后必须保留原始访客问题');
    assert.equal(f.rawState(session).outgoing[String(fingerprint)], undefined, '尚未POST的旧代登记不得成为永久取消栅栏');

    f.advance(5000); f.restart();
    assert((await f.runtime().scan()).some(item => item.jobId === job.id));
    await f.seed(session, state => {
      const current = state.jobs.find(item => item.id === job.id);
      current.plan = { type: 'text', purpose: 'ai_text', ai: true, ordinary: true, content: f.modes.answer, fingerprint };
      current.inference = { pool_revision: 2, deadline_at: f.now() + 90000 };
    });
    assert.equal((await f.runtime().process(f.key(session), job.id)).status, 'sent');
    assert.equal(f.sent.length, 1); assert.equal(f.sent[0].fingerprint, fingerprint); assert.equal(f.sent[0].content, f.modes.answer);
    assert.equal(f.rawState(session).outgoing[String(fingerprint)].status, 'sent');
    assert.equal((await f.runtime().process(f.key(session), job.id)).status, 'idle');
    assert.equal(f.sent.length, 1, '同一访客问题只能有一个最终出站'); f.noFeedback();
  });

  await test('F37 Crisp已收字节但配置换代无回执时先对账旧指纹，不因规则变化重复回复', async () => {
    const f = makeFixture('post-accepted-config-change'), session = 'session_post-uncertain';
    const poolFile = path.join(f.root, 'config/provider-pool-applied.json');
    const pool = { schema_version: 1, revision: 1, primary_id: 'synthetic-primary', policy: { question_timeout_ms: 90000 },
      entries: [{ id: 'synthetic-primary', enabled: true, model: 'synthetic-model' }] };
    fs.writeFileSync(poolFile, JSON.stringify(pool));
    const fingerprint = 77124;
    const job = f.makeJob(session, 'post-uncertain', { type: 'text', purpose: 'ai_text', ai: true, ordinary: true,
      content: '旧代已经交给Crisp的唯一正文', fingerprint }, { inference: { pool_revision: 1, deadline_at: f.now() + 90000 } });
    await f.seed(session, state => state.jobs.push(job));
    f.modes.onCrispPost = async () => {
      fs.writeFileSync(poolFile, JSON.stringify({ ...pool, revision: 2 }));
      await new Promise(resolve => setTimeout(resolve, 150));
    };
    f.modes.crispPostThrow = true;
    assert.equal((await f.runtime().process(f.key(session), job.id)).status, 'deferred');
    assert.equal(f.sent.length, 1, '合成远端已接收旧指纹一次');
    let stored = f.rawState(session).jobs.find(item => item.id === job.id);
    assert.equal(stored.status, 'received'); assert.equal(stored.deferred_configuration, true);
    assert.equal(stored.plan.fingerprint, fingerprint, '结果未知时必须保留旧计划供同指纹对账');
    assert.equal(f.rawState(session).outgoing[String(fingerprint)].status, 'unknown');

    // 模拟新配置把同一访客文字改成固定回复。旧回执未完成对账前不得使用这个
    // 新 purpose/fingerprint，否则远端会看到两条不同答案。
    const keyword = f.readConfig('keyword');
    keyword.rules.unshift({ id: 'synthetic-new-rule', name: '换代后新规则', enabled: true, match_mode: 'exact',
      keywords: ['旧队列的普通问题'], exclude_keywords: [], priority: 1000, action: 'reply', text: '新代固定回复不得重复发送', cooldown_seconds: 0 });
    f.writeConfig('keyword', keyword);
    f.modes.onCrispPost = null; f.modes.crispPostThrow = false;
    f.advance(5000); f.restart();
    assert((await f.runtime().scan()).some(item => item.jobId === job.id));
    const result = await f.runtime().process(f.key(session), job.id);
    assert.equal(result.status, 'dispatched_after_cancel');
    stored = f.rawState(session).jobs.find(item => item.id === job.id);
    assert.equal(stored.status, 'done'); assert.equal(f.rawState(session).outgoing[String(fingerprint)].status, 'sent');
    assert.equal(f.sent.length, 1, '已在Crisp找到旧指纹后不得发送新规则的第二条正文');
    assert.equal((await f.runtime().process(f.key(session), job.id)).status, 'idle');
    assert.equal(f.sent.length, 1); f.noFeedback();
  });

  await test('F38 配置换代时旧POST确定未送达，双重负查后按新规则恢复一次且不永久卡住', async () => {
    const f = makeFixture('post-absent-config-change'), session = 'session_post-absent';
    const poolFile = path.join(f.root, 'config/provider-pool-applied.json');
    const pool = { schema_version: 1, revision: 1, primary_id: 'synthetic-primary', policy: { question_timeout_ms: 90000 },
      entries: [{ id: 'synthetic-primary', enabled: true, model: 'synthetic-model' }] };
    fs.writeFileSync(poolFile, JSON.stringify(pool));
    const fingerprint = 77125;
    const job = f.makeJob(session, 'post-absent', { type: 'text', purpose: 'ai_text', ai: true, ordinary: true,
      content: '旧代未被Crisp接收的正文', fingerprint }, { inference: { pool_revision: 1, deadline_at: f.now() + 90000 } });
    await f.seed(session, state => state.jobs.push(job));
    f.modes.crispDropBeforeAccept = true;
    f.modes.onCrispPost = async () => {
      fs.writeFileSync(poolFile, JSON.stringify({ ...pool, revision: 2 }));
      await new Promise(resolve => setTimeout(resolve, 150));
    };
    assert.equal((await f.runtime().process(f.key(session), job.id)).status, 'deferred');
    assert.equal(f.postAttempts.length, 1); assert.equal(f.sent.length, 0);
    assert.equal(f.rawState(session).outgoing[String(fingerprint)].status, 'unknown');

    const keyword = f.readConfig('keyword');
    keyword.rules.unshift({ id: 'synthetic-new-rule-absent', name: '换代后恢复规则', enabled: true, match_mode: 'exact',
      keywords: ['旧队列的普通问题'], exclude_keywords: [], priority: 1000, action: 'reply', text: '新代确认回复', cooldown_seconds: 0 });
    f.writeConfig('keyword', keyword);
    f.modes.crispDropBeforeAccept = false; f.modes.onCrispPost = null;
    f.advance(10000); f.restart(); await f.runtime().scan();
    assert.equal((await f.runtime().process(f.key(session), job.id)).status, 'retry', '第一次精确负查只登记证据，不立即换正文');
    assert.equal(f.sent.length, 0); assert.equal(f.postAttempts.length, 1);
    f.advance(5000); f.restart(); await f.runtime().scan();
    assert.equal((await f.runtime().process(f.key(session), job.id)).status, 'deferred', '第二次间隔负查后才允许按新代重规划');
    assert.equal(f.rawState(session).outgoing[String(fingerprint)], undefined);
    f.advance(5000); f.restart(); await f.runtime().scan();
    assert.equal((await f.runtime().process(f.key(session), job.id)).status, 'sent');
    assert.equal(f.sent.length, 1); assert.equal(f.sent[0].content, '新代确认回复');
    assert.equal(f.postAttempts.length, 2, '旧代一次不确定尝试后只允许一次新代出站');
    assert.equal((await f.runtime().process(f.key(session), job.id)).status, 'idle');
    assert.equal(f.sent.length, 1); f.noFeedback();
  });

  await test('F39 旧版unknown仍绑定job但plan已丢失时先对账已送指纹，不生成第二条', async () => {
    const f = makeFixture('legacy-unknown-without-plan-found'), session = 'session_legacy-unknown-found';
    const fingerprint = 77126;
    const job = f.makeJob(session, 'legacy-unknown-found');
    const body = { type: 'text', from: 'operator', origin: 'chat', content: '旧版远端已经收到的正文', fingerprint };
    await f.seed(session, state => {
      state.jobs.push(job);
      state.outgoing[String(fingerprint)] = { status: 'unknown', body, created_at: f.now() - 15000, attempts: 1,
        job_id: job.id, generation: 0, attempt_token: 'legacy-unknown-found' };
    });
    f.histories.set(session, [{ ...body, timestamp: f.now() - 1000 }]);
    const keyword = f.readConfig('keyword');
    keyword.rules.unshift({ id: 'synthetic-legacy-new-rule', name: '旧状态后的新规则', enabled: true, match_mode: 'exact',
      keywords: ['旧队列的普通问题'], exclude_keywords: [], priority: 1000, action: 'reply', text: '不得产生的第二条回复', cooldown_seconds: 0 });
    f.writeConfig('keyword', keyword); f.restart();
    assert.equal((await f.runtime().process(f.key(session), job.id)).status, 'dispatched_after_cancel');
    assert.equal(f.sent.length, 0); assert.equal(f.postAttempts.length, 0); assert.equal(f.modelRequests.length, 0);
    assert.equal(f.rawState(session).outgoing[String(fingerprint)].status, 'sent');
    assert.equal(f.rawState(session).jobs.find(item => item.id === job.id).status, 'done');
    assert.equal((await f.runtime().process(f.key(session), job.id)).status, 'idle'); f.noFeedback();
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
    f.writeConfig('keyword', keyword); f.restart();
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
      await f.seed(session, state => { state.jobs.push(job); state.outgoing[String(fingerprint)] = outgoing; });
      f.histories.set(session, [{ ...outgoing.body, timestamp: f.now() - 1000 }]);
      f.modes.listHistoryOverride = [];
      f.restart(); await f.runtime().scan();
      assert.equal((await f.runtime().process(f.key(session), job.id)).status, 'sent');
      assert.equal(f.exactRequests.length, 1, '列表缺席后必须查询精确 fingerprint');
      assert.equal(f.postAttempts.length, 0, '精确端点已找到的消息绝不能再次 POST');
      assert.equal(f.rawState(session).outgoing[String(fingerprint)].status, 'sent');
      assert.equal(f.rawState(session).jobs.find(item => item.id === job.id).status, 'done');
    }
  });

  await test('F42 单一unknown经两次间隔精确负查后才允许同指纹重发一次', async () => {
    const f = makeFixture('single-unknown-confirmed-absent'), session = 'session_single-confirmed-absent';
    const fingerprint = 77129;
    const plan = { type: 'text', purpose: 'keyword_reply', ordinary: true, content: '已确认未送达后的唯一回复', fingerprint };
    const job = f.makeJob(session, 'single-confirmed-absent', plan);
    await f.seed(session, state => { state.jobs.push(job); state.outgoing[String(fingerprint)] = f.makeOutgoing(job, plan.content); });
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
    f.writeConfig('keyword', keyword); f.modes.exactStatus = 404; f.restart();
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
      if(change === 'global-off') f.writeConfig('runtime', { schema_version:2, enabled:false, revision:2, applied_revision:2 });
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
      f.restart(); const result = await f.runtime().process(f.key(session));
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
    };

    const delivered = makeFixture('mechanical-cached-unknown-found'), deliveredSession = 'session_mechanical-unknown-found';
    const deliveredPlan = { type: 'text', purpose: 'ai_text', ordinary: true, ai: true,
      content: clarification, fingerprint: 77221 };
    const deliveredJob = delivered.makeJob(deliveredSession, 'unknown-found', deliveredPlan);
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
    const exactJob = exact.makeJob(exactSession, 'exact-found', exactPlan);
    const exactOutgoing = exact.makeOutgoing(exactJob, exactPlan.content, 'unknown');
    const exactHistorical = { ...exactOutgoing.body, timestamp: exact.now() - 1000 };
    await exact.seed(exactSession, state => { state.jobs.push(exactJob); state.outgoing['77223'] = exactOutgoing; });
    exact.histories.set(exactSession, [exactHistorical]); exact.modes.listHistoryOverride = []; exact.restart();
    assert.equal((await exact.runtime().process(exact.key(exactSession))).status, 'delivered_non_answer');
    assert.equal(exact.exactRequests.length, 1); assert.equal(exact.postAttempts.length, 0);
    await assertRecoveredReceipt(exact, exactSession, exactJob, exactPlan.fingerprint);

    const sentReceipt = makeFixture('mechanical-cached-sent-found'), sentSession = 'session_mechanical-sent-found';
    const sentPlan = { ...deliveredPlan, fingerprint: 77224 };
    const sentJob = sentReceipt.makeJob(sentSession, 'sent-found', sentPlan);
    const sentOutgoing = sentReceipt.makeOutgoing(sentJob, sentPlan.content, 'sent');
    delete sentOutgoing.body;
    await sentReceipt.seed(sentSession, state => { state.jobs.push(sentJob); state.outgoing['77224'] = sentOutgoing; });
    sentReceipt.restart();
    assert.equal((await sentReceipt.runtime().process(sentReceipt.key(sentSession))).status, 'delivered_non_answer');
    assert.equal(sentReceipt.postAttempts.length, 0);
    await assertRecoveredReceipt(sentReceipt, sentSession, sentJob, sentPlan.fingerprint);

    const absent = makeFixture('mechanical-cached-unknown-absent'), absentSession = 'session_mechanical-unknown-absent';
    const absentPlan = { type: 'text', purpose: 'ai_text', ordinary: true, ai: true,
      content: 'A\u0000I暂时无法回\u0007复，请稍后再试。', fingerprint: 77222 };
    const absentJob = absent.makeJob(absentSession, 'unknown-absent', absentPlan);
    await absent.seed(absentSession, state => { state.jobs.push(absentJob); state.outgoing['77222'] = absent.makeOutgoing(absentJob, absentPlan.content, 'unknown'); });
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
    assert.equal(stored.outgoing['77222'].status, 'cancelled'); assert.equal(Object.hasOwn(stored.outgoing['77222'], 'body'), false);
    absent.advance(5000); absent.restart();
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

    f.advance(5000); f.restart();
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
    const staleJob = stale.makeJob(staleSession, 'unknown-two-attempts-stale', stalePlan,
      { received_at: stale.now() - 600000 });
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
    assert.equal(stale.postAttempts.length, 0); assert.equal(stale.sent.length, 0);
  });

  await test('F56 两次发送失败可在第三次恢复，三次后只对账并保留原责任', async () => {
    const recovered = makeFixture('crisp-post-third-attempt-recovery'), recoveredSession = 'session_crisp-third-recovery';
    const keyword = recovered.readConfig('keyword');
    keyword.rules.unshift({ id: 'synthetic-third-post', name: '第三次发送恢复', enabled: true, match_mode: 'exact',
      keywords: ['发送恢复问题'], exclude_keywords: [], priority: 1000, action: 'reply', text: '发送恢复后的唯一回复', cooldown_seconds: 0 });
    recovered.writeConfig('keyword', keyword);
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

  await test('F58 legacy sent 丢失 body、计划和冻结语义时保持 semantic unknown', async () => {
    const f = makeFixture('legacy-sent-semantic-unknown');
    const session = 'session_legacy-sent-unknown';
    const fingerprint = 77410;
    const plan = { type: 'text', purpose: 'ai_text', ordinary: true, ai: true,
      content: clarification, fingerprint };
    const job = f.makeJob(session, 'legacy-sent-no-evidence', plan);
    const outgoing = f.makeOutgoing(job, plan.content, 'sent');
    delete job.plan;
    delete outgoing.body;
    await f.seed(session, (state) => {
      state.jobs.push(job);
      state.outgoing[String(fingerprint)] = outgoing;
    });
    f.restart();

    assert.equal((await f.runtime().process(f.key(session), job.id)).status,
      'delivery_semantic_unknown');
    const stored = f.rawState(session);
    const unresolved = stored.jobs.find((item) => item.id === job.id);
    assert.equal(stored.outgoing[String(fingerprint)].status, 'sent');
    assert.equal(stored.outgoing[String(fingerprint)].semantic_status, 'semantic_unknown',
      '没有正文、计划或冻结语义时不得猜成有效回答或已送泛问');
    assert.equal(unresolved.status, 'received');
    assert.equal(unresolved.responsibility_status, 'unresolved_failure');
    assert.equal(unresolved.failure_code, 'delivery_semantic_unknown');
    assert(unresolved.data, '语义未知时必须保留原始访客责任供管理员核查');
    assert.equal(f.events().filter((event) => event.type === 'ai_reply').length, 0);
    assert.equal(f.postAttempts.length, 0); assert.equal(f.sent.length, 0);
  });

  await test('F59 首次 receipt_current 冻结后不被后续人工或配置状态追溯改判', async () => {
    const appliedConfiguration = (fixture, revision) => {
      const configuration = Object.fromEntries(['runtime', 'handoff', 'keyword', 'menu', 'tags', 'feedback']
        .map((name) => [name, fixture.readConfig(name)]));
      configuration.runtime = { ...configuration.runtime, enabled: true, revision,
        applied_revision: revision };
      fixture.writeAppliedMaterials(configuration);
      fixture.restart();
      return configuration;
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
      stale.writeAppliedMaterials(changed);
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
    stale.writeAppliedMaterials(later); stale.restart();
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
    assert.equal(fs.existsSync(path.join(f.root, 'data/runtime/session-' + f.key(session) + '.json')),
      false, '畸形结构不得进入知识、Provider 或普通应答队列');
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
    outgoing.receipt_current = true;
    delete outgoing.body;
    await f.seed(session, (state) => { state.jobs.push(job); state.outgoing[String(fingerprint)] = outgoing; });
    f.restart();
    assert.equal((await f.runtime().process(f.key(session), job.id)).status, 'sent');
    let stored = f.rawState(session);
    assert.equal(stored.jobs.find((item) => item.id === job.id).responsibility_status, 'control_handled');
    const menuId = digest(job.id + '|welcome_menu');
    assert.equal(stored.jobs.filter((item) => item.id === menuId).length, 1);
    assert.equal((await f.runtime().process(f.key(session), job.id)).status, 'idle');
    stored = f.rawState(session);
    assert.equal(stored.jobs.filter((item) => item.id === menuId).length, 1, '恢复不得重复创建欢迎菜单任务');
    assert.equal(f.postAttempts.length, 0); assert.equal(f.sent.length, 0);
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
    assert.equal(stored.outgoing[String(plans[0].fingerprint)].status, 'sent');
    assert.equal(stored.outgoing[String(plans[1].fingerprint)].status, 'unknown',
      '另一条未知回执不能因首条命中而被取消');
    assert.equal(stored.outgoing[String(plans[1].fingerprint)].reconcile_misses, 1);
    assert.equal(f.postAttempts.length, 0);
    f.advance(5000); f.restart(); await f.runtime().scan();
    assert.equal((await f.runtime().process(f.key(session), job.id)).status, 'delivered_non_answer');
    stored = f.rawState(session);
    assert.equal(stored.outgoing[String(plans[1].fingerprint)], undefined);
    const unresolved = stored.jobs.find((item) => item.id === job.id);
    assert.equal(unresolved.responsibility_status, 'unresolved_failure');
    assert.equal(unresolved.failure_code, 'delivered_non_answer');
    assert.equal(unresolved.response_generation, 1);
    assert(unresolved.data); assert.equal(f.postAttempts.length, 0); assert.equal(f.sent.length, 0);
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
    const job = f.makeJob(session, 'nonanswer-config-change', plan);
    const outgoing = f.makeOutgoing(job, plan.content, 'unknown');
    await f.seed(session, (state) => { state.jobs.push(job); state.outgoing[String(plan.fingerprint)] = outgoing; });
    f.histories.set(session, [{ ...outgoing.body, timestamp: f.now() - 1000 }]);
    f.writeConfig('runtime', { schema_version: 2, enabled: true, revision: 2, applied_revision: 2 });
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
          { response_generation: 1, responsibility_status: 'unresolved_failure',
            reconciliation_only: true });
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

  fs.writeFileSync(path.join(evidence, 'result.json'), JSON.stringify({ layer: 'UNIT/CONTRACT', passed, failed, synthetic_only: true }, null, 2));
  process.stdout.write(JSON.stringify({ layer: 'UNIT/CONTRACT', passed, failed, synthetic_only: true, evidence: path.relative(project, evidence) }) + '\n');
  if (failed) process.exitCode = 1;
})().catch((error) => { process.stderr.write(error.stack + '\n'); process.exitCode = 1; });
