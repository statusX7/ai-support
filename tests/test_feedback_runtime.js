'use strict';

// 全部资料与网络回应均为 synthetic；测试直接运行生产 runtime，不连接真实 Crisp。
const assert = require('assert/strict');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { spawnSync } = require('child_process');
const { createRuntime } = require('../n8n/runtime');

const project = path.resolve(__dirname, '..');
const work = path.join(project, '.work', 'v1.2.1');
fs.mkdirSync(work, { recursive: true });
const evidence = fs.mkdtempSync(path.join(work, 'feedback-runtime-'));
const digest = (value) => crypto.createHash('sha256').update(String(value)).digest('hex');
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
  const patches = [];
  const modes = { modelFailure: false, imageFailure: false, historyFailure: false, exactFailure: false,
    answer: '受控业务答案：请在设置中保存后重试。' };
  const request = async (url, options = {}) => {
    const parsed = new URL(url);
    const match = parsed.pathname.match(/\/conversation\/([^/]+)(\/.*)$/);
    if (match) {
      const session = decodeURIComponent(match[1]);
      const suffix = match[2];
      const history = histories.get(session) || [];
      if (suffix === '/messages') {
        const listed = modes.listHistoryOverride === undefined ? history
          : typeof modes.listHistoryOverride === 'function' ? modes.listHistoryOverride(session, history) : modes.listHistoryOverride;
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
  const events = () => { const file = path.join(root, 'data/analytics/events.jsonl'); return fs.existsSync(file) ? fs.readFileSync(file, 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse) : []; };
  const noFeedback = () => {
    assert(!sent.some((item) => typeof item.content === 'string' && item.content.includes(invitation)), '不能发送系统自动评价邀请');
    assert(!events().some((item) => item.type === 'feedback'), '不能新登记自动评价');
  };
  return { root, prompt, env, sent, postAttempts, patches, histories, exactRequests, modelRequests, visionRequests, retrievalRequests, workspaceRequests, modes, key, state, rawState, seed, makeJob, makeOutgoing, event, receive, deliver, readConfig, writeConfig, restart, events, noFeedback, runtime: () => runtime, advance: (milliseconds) => { now += milliseconds; }, now: () => now };
};

let passed = 0;
let failed = 0;
const test = async (name, action) => {
  try { await action(); passed += 1; process.stdout.write('通过 UNIT/CONTRACT ' + name + '\n'); }
  catch (error) { failed += 1; process.stdout.write('失败 UNIT/CONTRACT ' + name + '\n' + error.stack + '\n'); }
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

  await test('F09 正常文字、图片、图片错误和模型错误保持业务回复，总开关仍静默', async () => {
    const f = makeFixture('business');
    await f.deliver(f.event('session_business1', '如何保存设置？')); assert.equal(f.sent.at(-1).content, f.modes.answer);
    await f.deliver(f.event('session_picture01', { url: 'https://storage.crisp.chat/synthetic.png', type: 'image/png' }, { type: 'file' }));
    assert.equal(f.visionRequests.length, 1); assert.equal(f.sent.at(-1).content, f.modes.answer);
    f.modes.imageFailure = true;
    await f.deliver(f.event('session_badimage1', { url: 'https://storage.crisp.chat/synthetic.png', type: 'image/png' }, { type: 'file' }));
    assert.equal(f.sent.at(-1).content, imageClarification); assert.equal(f.state('session_badimage1').mode, 'ai');
    f.modes.modelFailure = true; await f.deliver(f.event('session_badmodel1', '模型错误的普通问题'));
    assert.equal(f.sent.at(-1).content, clarification); assert.equal(f.state('session_badmodel1').mode, 'ai');
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

  await test('F12 超过五分钟的旧 unknown 重启后仍对账，历史缺席也不补发', async () => {
    for (const purpose of ['ai_text', 'feedback_invite']) for (const found of [false, true]) {
      const f = makeFixture('old-unknown-' + purpose + '-' + found); const session = 'session_oldresult1';
      const job = f.makeJob(session, 'old-result', { type: 'text', purpose, ordinary: true, feedback: true, content: f.modes.answer, fingerprint: 76001 }, { received_at: f.now() - 600000 });
      const outgoing = f.makeOutgoing(job, f.modes.answer + '\n\n' + invitation);
      outgoing.created_at = f.now() - 590000;
      await f.seed(session, (state) => { state.jobs.push(job); state.outgoing['76001'] = outgoing; });
      if (found) f.histories.set(session, [{ ...outgoing.body, timestamp: f.now() - 589000 }]);
      f.restart(); await f.runtime().scan();
      const first = await f.runtime().process(f.key(session));
      if (!found && purpose === 'ai_text') {
        assert.equal(first.status, 'retry');
        f.advance(5000); f.restart(); await f.runtime().scan();
        assert.equal((await f.runtime().process(f.key(session))).status, 'failed');
      }
      assert.equal(f.rawState(session).outgoing['76001'].status, found ? 'sent' : purpose === 'ai_text' ? 'failed' : 'cancelled');
      const restoredJob = f.rawState(session).jobs.find((entry) => entry.id === job.id);
      if (purpose === 'ai_text') {
        assert.notEqual(restoredJob.feedback_retired, true, '超时普通答案不能误标为评价');
        assert.equal(restoredJob.status, found ? 'done' : 'failed');
        assert.equal(f.events().filter(event => event.type === 'delivery_failed' && event.reason === 'delivery_unknown').length, found ? 0 : 1);
      }
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

  await test('F14 所有已知系统错误出口使用受控澄清，不消费旧自定义失败句或误计成功', async () => {
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
      if (kind === 'expired') {
        const job = f.makeJob(session, 'expired-error', null, { inference: { pool_revision: null, deadline_at: f.now() - 1 } });
        await f.seed(session, state => state.jobs.push(job));
        await f.runtime().process(f.key(session));
        assert.equal(f.modelRequests.length, 0);
      } else {
        const data = kind.startsWith('image-') ? { url: 'https://storage.crisp.chat/synthetic.png', type: 'image/png' } : '合成问题';
        await f.deliver(f.event(session, data, { type: kind.startsWith('image-') ? 'file' : 'text' }));
      }
      assert.equal(f.sent.length, 1, kind);
      assert.equal(f.modelRequests.length, ['http', 'throw', 'payload-error', 'missing-payload', 'image-rag'].includes(kind) ? 1 : 0, kind + ' 的故障注入必须发生在实际生成阶段');
      assert.equal(f.sent[0].content, kind.startsWith('image-') ? imageClarification : clarification, kind);
      assert.equal(f.state(session).mode, 'ai'); assert.deepEqual(f.state(session).offers, {});
      assert.equal(f.events().filter(event => event.type === 'ai_reply' || event.type === 'handoff').length, 0);
      assert.deepEqual(f.readConfig('handoff'), policy, '兼容原配置但不直接消费其系统错误文案');
      assert.equal(fs.readFileSync(path.join(f.root, 'config/prompt.md'), 'utf8'), f.prompt);
      f.noFeedback();
    }
  });

  await test('F15 旧已计划 safe_error 重启与排队恢复统一自然文案，且不重新推理', async () => {
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
      assert.equal(f.rawState(session).jobs[0].plan.content, kind === 'image' ? imageClarification : clarification);
      if (outgoingStatus !== 'none') assert.equal(f.rawState(session).outgoing['78001'].body.content, kind === 'image' ? imageClarification : clarification);
      assert.equal((await f.runtime().process(f.key(session))).status, 'sent');
      assert.equal(f.sent.length, 1); assert.equal(f.sent[0].content, kind === 'image' ? imageClarification : clarification);
      assert.equal(f.modelRequests.length, 0); assert.equal(f.visionRequests.length, 0);
      assert.equal((await f.runtime().process(f.key(session))).status, 'idle');
    }
  });

  await test('F16 旧系统错误发送未知先对账，已送历史不改、未送才按同指纹发送自然句', async () => {
    for (const status of ['unknown', 'sending']) for (const found of [false, true]) {
      const f = makeFixture('natural-uncertain-' + status + '-' + found); const session = 'session_uncertain-error';
      const job = f.makeJob(session, 'uncertain-safe-error', { type: 'text', purpose: 'safe_error', ordinary: true, content: legacyFailure, fingerprint: 79001 });
      const record = f.makeOutgoing(job, legacyFailure, status);
      await f.seed(session, state => { state.jobs.push(job); state.outgoing['79001'] = record; });
      const historical = [{ ...record.body, timestamp: f.now() - 1000 }];
      if (found) f.histories.set(session, structuredClone(historical));
      f.restart(); await f.runtime().scan();
      assert.equal(f.rawState(session).outgoing['79001'].body.content, legacyFailure, '未知回执正文在核实前保留');
      const first = await f.runtime().process(f.key(session));
      if (!found) {
        assert.equal(first.status, 'retry'); assert.equal(f.sent.length, 0);
        f.advance(5000); f.restart(); await f.runtime().scan();
      }
      assert.equal(found ? first.status : (await f.runtime().process(f.key(session))).status, 'sent');
      assert.equal(f.sent.length, found ? 0 : 1);
      if (found) assert.deepEqual(f.histories.get(session), historical);
      else { assert.equal(f.sent[0].content, clarification); assert.equal(f.sent[0].fingerprint, 79001); }
      assert.equal(f.modelRequests.length, 0); assert.equal(f.state(session).mode, 'ai');
      assert.equal(f.rawState(session).outgoing['79001'].status, 'sent');
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
    const business = f.makeJob(session, 'business-quote', { type: 'text', purpose: 'keyword_reply', ordinary: true, content: legacyFailure, fingerprint: 81001 });
    await f.seed(session, state => state.jobs.push(business));
    await f.runtime().process(f.key(session));
    assert.equal(f.sent.at(-1).content, legacyFailure, '普通业务固定回复不按系统错误来源处理');
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

  await test('F20 配置迁移精确更新旧失败默认和缺省秒数，保留显式1800、自定义及0且重复不变', async () => {
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
      if (index < 3) expected.handoff.failure_message = clarification;
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

  await test('F21 缺知识与低置信度真实出口使用自然默认，旧已应用投影同样受控且自定义保留', async () => {
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
        const projection = { schema_version: 1, state: 'applied', revision: 1, source_sha256: digest('synthetic-materials-source'), configuration,
          prompt: { text: f.prompt, bytes: Buffer.byteLength(f.prompt), sha256: digest(f.prompt) },
          knowledge: { map_sha256: digest(fs.readFileSync(path.join(f.root, 'data/runtime/knowledge-map.json'), 'utf8')) } };
        fs.writeFileSync(path.join(f.root, 'config/materials-applied.json'), JSON.stringify(projection));
        f.writeConfig('handoff', { handoff: { ...policy.handoff, [field]: '未应用编辑不应生效' } });
      }
      f.modes.retrievalPayload = { results: field === 'no_answer_message' ? [] : [retrievalResult(0.99)] };
      f.modes.answer = '合成低分候选答案';
      await f.deliver(f.event(session, '请帮我确认这个具体问题。'));
      assert.equal(f.sent.length, 1);
      assert.equal(f.sent[0].content, variant === 'custom' ? custom : clarification, [field, storage, variant].join('/'));
      assert.equal(f.state(session).mode, 'ai'); assert.deepEqual(f.state(session).offers, {});
      assert.equal(f.workspaceRequests.length, 1); assert.equal(f.retrievalRequests.length, 1);
      assert.equal(f.modelRequests.length, field === 'no_answer_message' ? 0 : 1, '无来源按策略直接澄清，低分来源仍执行一次实际生成'); f.noFeedback();
      assert.equal(fs.readFileSync(path.join(f.root, 'config/prompt.md'), 'utf8'), f.prompt);
    }
  });

  await test('F22 资料归一化精确迁移两类旧澄清默认，缺省补齐而自定义原文不改', async () => {
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
      assert.equal(normalized.handoff.no_answer_message, index === 3 ? messages[0] : clarification);
      assert.equal(normalized.handoff.low_confidence_message, index === 3 ? messages[1] : clarification);
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
        assert.equal(received.accepted, true); assert.equal(received.route, 'ignore', kind);
        const job = f.rawState(session).jobs.find(item => item.id === received.jobId);
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

  await test('F24 窗口维护只延后依赖接口的旧AI计划，本地澄清当场自然回复一次', async () => {
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
        assert.equal(result.status, 'sent', kind);
        assert.equal(f.sent.length, 1); assert.equal(f.sent[0].content, clarification);
        assert.equal(f.modelRequests.length, 0);
        assert.equal(f.events().filter(event => event.type === 'ai_reply' || event.type === 'handoff').length, 0);
        fs.unlinkSync(marker); f.modes.onModelResponse = null; f.modes.modelFailure = false;
        assert.equal((await f.runtime().process(f.key(session))).status, 'idle');
        assert.equal(f.sent.length, 1, '本地澄清不得因marker清除再发一次');
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
    assert.equal(delayed.accepted, true); assert.equal(delayed.route, 'ignore');
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

  await test('F26 上游200完整答案恰为已知旧系统失败句时硬性自然澄清，不能计AI成功', async () => {
    for (const [index, content] of [legacyFailure, '当前自动客服暂时不可用，请稍后再试。', '自动客服暂时无法回答，请稍后再试。'].entries()) {
      const f = makeFixture('natural-exact-model-failure-' + index), session = 'session_exact-failure';
      f.modes.answer = content;
      await f.deliver(f.event(session, '真实query出口的合成问题'));
      assert.equal(f.sent.length, 1); assert.equal(f.sent[0].content, clarification);
      assert.equal(f.modelRequests.length, 1); assert.equal(f.state(session).mode, 'ai');
      assert.equal(f.events().filter(event => event.type === 'ai_reply' || event.type === 'knowledge_hit').length, 0);
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
    assert.equal(f.sent[1].content, '请描述你遇到的问题和正在进行的操作。');
    assert.equal(f.modelRequests.length, 0); assert.equal(f.visionRequests.length, 0);
    assert.equal(f.state(session).mode, 'ai');
    assert.equal(f.events().filter(event => event.type === 'ai_reply' || event.type === 'handoff').length, 0);
    assert.deepEqual(f.readConfig('menu'), menu, '不改管理员的当前菜单原文');
    f.noFeedback();
  });

  await test('F28 视觉200完整旧系统失败句不写图片记忆且不续RAG，只发送一次图片澄清', async () => {
    for (const [index, content] of [legacyFailure, '当前自动客服暂时不可用，请稍后再试。', '自动客服暂时无法回答，请稍后再试。'].entries()) {
      const f = makeFixture('natural-exact-vision-failure-' + index), session = 'session_exact-vision-failure';
      f.modes.visionAnswer = content;
      await f.deliver(f.event(session, { url: 'https://storage.crisp.chat/synthetic.png', type: 'image/png' }, { type: 'file' }));
      assert.equal(f.visionRequests.length, 1); assert.equal(f.modelRequests.length, 0, '旧系统失败句不是可供RAG使用的识图结果');
      assert.equal(Object.hasOwn(f.rawState(session), 'image_context'), false, '失败句不能记为图片上下文');
      assert.equal(f.sent.length, 1); assert.equal(f.sent[0].content, imageClarification);
      assert.equal(f.state(session).mode, 'ai'); assert.deepEqual(f.state(session).offers, {});
      assert.equal(f.events().filter(event => ['ai_reply', 'knowledge_hit', 'handoff'].includes(event.type)).length, 0);
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
      const f = makeFixture('temperature-invalid-' + failure);
      f.modes.workspacePayload = { workspace: [{ slug: failure === 'slug' ? 'another-synthetic-workspace' : f.env.ANYTHINGLLM_WORKSPACE,
        openAiTemp: failure === 'temperature-string' ? '0.7' : null }] };
      if (failure === 'http') f.modes.workspaceStatus = 503;
      await f.deliver(f.event('session_workspace-invalid', '虚构温度失败问题'));
      assert.equal(f.workspaceRequests.length, 1); assert.equal(f.retrievalRequests.length, 0); assert.equal(f.modelRequests.length, 0);
      assert.equal(f.sent.length, 1); assert.equal(f.sent[0].content, clarification);
      assert.equal(f.state('session_workspace-invalid').mode, 'ai');
      assert.equal(f.events().filter(event => ['ai_reply', 'knowledge_hit', 'knowledge_miss', 'handoff'].includes(event.type)).length, 0);
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
    assert.equal(typeof f.sent[0].content, 'string'); assert(f.sent[0].content.trim());
    assert.doesNotMatch(f.sent[0].content, /AI|机器人|暂时[^\n]{0,12}(?:无法|不能)[^\n]{0,12}回复|稍后再试/i);
    const generated = f.modelRequests.length;
    assert(generated <= 1, '过期恢复可本地澄清或有界生成，不得放大请求');
    assert.equal((await f.receive(input)).route, 'ignore');
    assert.equal(f.sent.length, 1); assert.equal(f.modelRequests.length, generated, '重复Hook不得重复生成');
    assert.equal(f.rawState(session).jobs.find(job => job.id === received.jobId).status, 'done'); f.noFeedback();
  });

  await test('F34 空的固定reply配置在运行时防御为自然澄清，不以none完成', async () => {
    const f = makeFixture('empty-keyword-reply'), session = 'session_empty-reply';
    const keywords = f.readConfig('keyword');
    keywords.rules.unshift({ id: 'synthetic-empty-reply', name: '合成空回复', enabled: true, match_mode: 'exact',
      keywords: ['空回复边界'], exclude_keywords: [], priority: 1000, action: 'reply', text: '', cooldown_seconds: 0 });
    f.writeConfig('keyword', keywords); f.restart();
    const result = await f.deliver(f.event(session, '空回复边界'));
    assert.equal(result.status, 'sent'); assert.equal(f.sent.length, 1);
    assert.equal(f.sent[0].type, 'text'); assert.equal(f.sent[0].content, clarification);
    assert.equal(f.modelRequests.length, 0); assert.equal(f.state(session).mode, 'ai');
    assert.equal(f.rawState(session).jobs.find(job => job.event === 'message:send').status, 'done'); f.noFeedback();
  });

  await test('F35 规划阶段连续异常不得终态吞消息，恢复后恰好回复一次', async () => {
    const f = makeFixture('planning-recoverable'), session = 'session_planning-recoverable';
    f.modes.historyFailure = true;
    const input = f.event(session, '历史回读暂时异常的普通问题');
    const received = await f.receive(input);
    assert.equal(received.route, 'process');
    for (let attempt = 0; attempt < 5; attempt += 1) {
      await f.runtime().process(f.key(session), received.jobId);
      const job = f.rawState(session).jobs.find(item => item.id === received.jobId);
      if (job.status !== 'received') break;
      f.advance(5000);
    }
    const duringFailure = f.rawState(session).jobs.find(job => job.id === received.jobId);
    const controlled = f.sent.filter(message => message.session_id === session);
    assert(controlled.length === 1 || duringFailure.status === 'received', '连续规划异常只能受控回复或保持可恢复');
    assert.notEqual(duringFailure.status, 'failed'); assert.notEqual(duringFailure.status, 'cancelled');
    if (controlled.length) {
      assert.equal(typeof controlled[0].content, 'string'); assert(controlled[0].content.trim());
      assert.doesNotMatch(controlled[0].content, /AI|机器人|暂时[^\n]{0,12}(?:无法|不能)[^\n]{0,12}回复|稍后再试/i);
    } else {
      assert(duringFailure.data && duringFailure.data.content, '可恢复任务必须保留访客问题');
      assert(duringFailure.retry_at >= f.now(), '可恢复任务必须有界延后重试');
      f.modes.historyFailure = false; f.advance(5000); f.restart();
      const scanned = await f.runtime().scan();
      assert(scanned.some(item => item.jobId === received.jobId));
      assert.equal((await f.runtime().process(f.key(session), received.jobId)).status, 'sent');
    }
    assert.equal(f.sent.filter(message => message.session_id === session).length, 1);
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

  fs.writeFileSync(path.join(evidence, 'result.json'), JSON.stringify({ layer: 'UNIT/CONTRACT', passed, failed, synthetic_only: true }, null, 2));
  process.stdout.write(JSON.stringify({ layer: 'UNIT/CONTRACT', passed, failed, synthetic_only: true, evidence: path.relative(project, evidence) }) + '\n');
  if (failed) process.exitCode = 1;
})().catch((error) => { process.stderr.write(error.stack + '\n'); process.exitCode = 1; });
