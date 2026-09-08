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
  const env = { CRISP_WEBSITE_ID: '11111111-1111-4111-8111-111111111111', CRISP_WEBSITE_HOOK_SECRET: 'synthetic-feedback-hook-0001', CRISP_AUTH_B64: 'synthetic-feedback-auth', AI_API_KEY: 'synthetic-feedback-key', AI_SUPPORTS_VISION: 'true', ANYTHINGLLM_API_KEY: 'synthetic-feedback-rag', ANYTHINGLLM_WORKSPACE: 'synthetic-feedback' };
  let now = Date.now();
  let sequence = 1000;
  let runtime;
  const sent = [];
  const modelRequests = [];
  const visionRequests = [];
  const histories = new Map();
  const patches = [];
  const modes = { modelFailure: false, imageFailure: false, historyFailure: false, answer: '受控业务答案：请在设置中保存后重试。' };
  const request = async (url, options = {}) => {
    const parsed = new URL(url);
    const match = parsed.pathname.match(/\/conversation\/([^/]+)(\/.*)$/);
    if (match) {
      const session = decodeURIComponent(match[1]);
      const suffix = match[2];
      const history = histories.get(session) || [];
      if (suffix === '/messages') return { status: modes.historyFailure ? 503 : 200, body: { error: modes.historyFailure, data: history } };
      if (suffix.startsWith('/message/')) return { status: 200, body: { error: false, data: history.find((item) => String(item.fingerprint) === suffix.slice(9)) || {} } };
      if (suffix === '/meta' && options.method === 'GET') return { status: 200, body: { error: false, data: { segments: ['existing-manual-segment'] } } };
      if (suffix === '/meta' && options.method === 'PATCH') { patches.push(options.body); return { status: 200, body: { error: false } }; }
      if (suffix === '/message' && options.method === 'POST') {
        const body = structuredClone(options.body);
        sent.push({ ...body, session_id: session });
        history.push({ ...body, timestamp: now }); histories.set(session, history);
        return { status: 200, body: { error: false, reason: 'dispatched', data: { fingerprint: body.fingerprint } } };
      }
      throw new Error('未知 synthetic Crisp 路径：' + suffix);
    }
    if (parsed.hostname === 'anythingllm') {
      modelRequests.push(structuredClone(options.body));
      return { status: modes.modelFailure ? 503 : 200, body: modes.modelFailure ? { error: 'synthetic-failure' } : { textResponse: modes.answer, sources: [{ docpath: 'synthetic/document.json', score: 0.9 }] } };
    }
    if (parsed.hostname === 'provider.invalid') {
      visionRequests.push(structuredClone(options.body));
      return { status: 200, body: { choices: [{ message: { content: '截图显示保存设置按钮。' } }] } };
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
  return { root, prompt, env, sent, patches, histories, modelRequests, visionRequests, modes, key, state, rawState, seed, makeJob, makeOutgoing, event, receive, deliver, readConfig, writeConfig, restart, events, noFeedback, runtime: () => runtime, advance: (milliseconds) => { now += milliseconds; }, now: () => now };
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
      assert(f.modelRequests.at(-1).message.includes('访客当前问题：' + content));
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
    assert(scanned.some((job) => job.jobId === normal.id)); assert(scanned.some((job) => job.jobId === ordinary.id));
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
      assert.equal(f.events().filter((event) => event.type === 'ai_reply').length, 1);
      assert.equal(f.state(session).pending_feedback, null); f.noFeedback();
    }
  });

  await test('F06 旧 unknown 普通答案未送达时复用原 plan，仅重发无评价正文', async () => {
    const f = makeFixture('unknown-absent'); const session = 'session_absent0001';
    const job = f.makeJob(session, 'unknown', { type: 'text', purpose: 'ai_text', ordinary: true, ai: true, feedback: true, content: f.modes.answer, fingerprint: 72001 });
    await f.seed(session, (state) => { state.jobs.push(job); state.outgoing['72001'] = f.makeOutgoing(job, f.modes.answer + '\n\n' + invitation); });
    f.restart(); await f.runtime().scan(); await f.runtime().process(f.key(session));
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
    assert.match(f.sent.at(-1).content, /补充报错文字/); assert.equal(f.state('session_badimage1').mode, 'ai');
    f.modes.modelFailure = true; await f.deliver(f.event('session_badmodel1', '模型错误的普通问题'));
    assert.equal(f.sent.at(-1).content, '暂时无法回复，请稍后再试。'); assert.equal(f.state('session_badmodel1').mode, 'ai');
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
      f.restart(); await f.runtime().scan(); await f.runtime().process(f.key(session));
      assert.equal(f.rawState(session).outgoing['76001'].status, found ? 'sent' : 'cancelled');
      const restoredJob = f.rawState(session).jobs.find((entry) => entry.id === job.id);
      if (purpose === 'ai_text') {
        assert.notEqual(restoredJob.feedback_retired, true, '超时普通答案不能误标为评价');
        assert.equal(restoredJob.status, found ? 'done' : 'cancelled');
      }
      assert.equal(f.sent.length, 0); assert.equal(f.modelRequests.length, 0);
      assert.equal(f.state(session).pending_feedback, null);
    }
  });

  await test('F13 发送注册前接口池代次改变时丢弃迟到正文', async () => {
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
      assert.equal((await f.runtime().process(f.key(session))).status, 'cancelled');
    } finally { fs.readFileSync = originalRead; }
    assert(poolReads >= 3); assert.equal(f.sent.length, 0); assert.equal(f.modelRequests.length, 0);
    assert.equal(Object.keys(f.rawState(session).outgoing).length, 0);
  });

  fs.writeFileSync(path.join(evidence, 'result.json'), JSON.stringify({ layer: 'UNIT/CONTRACT', passed, failed, synthetic_only: true }, null, 2));
  process.stdout.write(JSON.stringify({ layer: 'UNIT/CONTRACT', passed, failed, synthetic_only: true, evidence: path.relative(project, evidence) }) + '\n');
  if (failed) process.exitCode = 1;
})().catch((error) => { process.stderr.write(error.stack + '\n'); process.exitCode = 1; });
