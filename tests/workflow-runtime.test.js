'use strict';

const assert = require('assert/strict');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const vm = require('vm');
const { createRuntime } = require('../n8n/runtime');
const project = path.resolve(__dirname, '..');
fs.mkdirSync(path.join(project, '.work', 'v1.1.0'), { recursive: true });
const root = fs.mkdtempSync(path.join(project, '.work', 'v1.1.0', 'runtime-test-'));
fs.mkdirSync(path.join(root, 'config'), { recursive: true });
fs.mkdirSync(path.join(root, 'data', 'runtime'), { recursive: true });
for (const name of ['keyword', 'handoff', 'menu', 'tags', 'feedback', 'provider']) fs.copyFileSync(path.join(project, 'config', name + '.yaml.example'), path.join(root, 'config', name + '.yaml'));
fs.writeFileSync(path.join(root, 'config', 'prompt.md'), '中文提示词 $ # " \\ 😀\n优先知识，不编造。');
const writeConfig = (name, data) => fs.writeFileSync(path.join(root, 'config', name + '.yaml'), JSON.stringify(data));
const readConfig = (name) => JSON.parse(fs.readFileSync(path.join(root, 'config', name + '.yaml'), 'utf8'));
writeConfig('runtime', { schema_version: 2, enabled: true, revision: 1, applied_revision: 1 });
writeConfig('provider', { provider: { base_url: 'https://provider.invalid/proxy/v1', model: 'controlled-model', api_mode: 'chat_completions', supports_vision: true } });
const welcomeOff = readConfig('menu'); welcomeOff.welcome.enabled = false; writeConfig('menu', welcomeOff);
const env = { CRISP_WEBSITE_ID: '11111111-1111-4111-8111-111111111111', CRISP_WEBSITE_HOOK_SECRET: 'test-only-website-secret-0001', CRISP_PLUGIN_SIGNING_SECRET: 'test-only-plugin-secret-0001', CRISP_AUTH_B64: 'test-only-auth', CRISP_TOKEN_TIER: 'website', AI_API_KEY: 'test-only-key', AI_SUPPORTS_VISION: 'true', ANYTHINGLLM_WORKSPACE: 'crisp-support', ANYTHINGLLM_API_KEY: 'test-only-anything-key' };
const projection = 'kb_1111111111111111_doc_2222222222222222.md';
fs.writeFileSync(path.join(root, 'data/runtime/knowledge-map.json'), JSON.stringify({ schema_version: 2, documents: [{
  library_id: 'kb_1111111111111111', document_id: 'doc_2222222222222222', projection,
  location: 'custom-documents/' + projection + '-33333333-3333-4333-8333-333333333333.json',
}] }));
const messagesOf = body => body.messages || body.input;
const textOf = message => typeof message.content === 'string' ? message.content
  : message.content.filter(part => ['text', 'input_text', 'output_text'].includes(part.type)).map(part => part.text).join('\n');
const textOfRequest = body => messagesOf(body).map(textOf).join('\n');
let now = Date.now();
let sequence = 1000;
let delayed;
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
const sent = [];
const histories = new Map();
const modelRequests = [];
const providerRequests = [];
const retrievalRequests = [];
const segments = new Map();
let runtime;
const wait = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));
const request = async (url, options = {}) => {
  const parsed = new URL(url);
  const match = parsed.pathname.match(/\/conversation\/([^/]+)(\/.*)$/);
  if (match) {
    const session = decodeURIComponent(match[1]);
    const suffix = match[2];
    const history = histories.get(session) || [];
    if (crispFailure) return { status: 403, body: { error: true } };
    if (suffix === '/messages') return { status: 200, body: { error: false, data: history } };
    if (suffix.startsWith('/message/')) return { status: 200, body: { error: false, data: history.find((message) => String(message.fingerprint) === suffix.slice(9)) || {} } };
    if (suffix === '/meta' && options.method === 'GET') return { status: tagFailure ? 403 : 200, body: { error: tagFailure, data: { segments: segments.get(session) || ['external-vip'] } } };
    if (suffix === '/meta' && options.method === 'PATCH') { segments.set(session, options.body.segments); return { status: 200, body: { error: false } }; }
    if (suffix === '/message') {
      const body = options.body;
      sendAttempts += 1;
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
    return { status: 200, body: { results: miss ? [] : [{ id: 'synthetic-workflow-chunk', text: '问题：设置如何保存？\n回答：在设置页保存后重试。',
      ...(unknownSources ? {} : { metadata: { title: projection } }), distance: low ? 0.9 : 0.1, score: low ? 0.1 : 0.9 }] } };
  }
  if (parsed.hostname === 'provider.invalid') {
    assert.equal(options.method, 'POST'); assert.equal(options.headers.Authorization, 'Bearer ' + env.AI_API_KEY);
    assert.equal(parsed.pathname, options.body.input ? '/proxy/v1/responses' : '/proxy/v1/chat/completions');
    const hasImage = messagesOf(options.body).some(message => Array.isArray(message.content)
      && message.content.some(part => ['image_url', 'input_image'].includes(part.type)));
    let answer;
    if (hasImage) {
      providerRequests.push({ path: parsed.pathname, body: structuredClone(options.body) });
      if (delayedVision) { const pending = delayedVision; delayedVision = null; await pending; }
      answer = visualAnswer;
    } else {
      modelRequests.push(structuredClone(options.body));
      assert.equal(options.body.temperature, 0.7);
      if (delayed) { const pending = delayed; delayed = null; await pending; }
      if (modelFailure) return { status: 503, body: { error: 'provider_failed' } };
      answer = modelAnswerOverride ?? '受控协议回答：' + textOf(messagesOf(options.body).at(-1)).slice(-25);
    }
    return { status: 200, body: options.body.input ? { output: [{ type: 'message', role: 'assistant', content: [{ type: 'output_text', text: answer }] }] } : { choices: [{ message: { content: answer } }] } };
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
const click = (session, card, index = 0, event = 'message:updated') => ({ website_id: env.CRISP_WEBSITE_ID, event, timestamp: now, data: { session_id: session, fingerprint: card.fingerprint, ...(event === 'message:send' ? { type: 'picker', from: 'user' } : {}), content: { ...card.content, choices: card.content.choices.map((choice, at) => ({ ...choice, selected: at === index })) } } });
const operator = async (session, overrides = {}) => {
  const body = { ...message(session, '真人公开处理进度', { from: 'operator', automated: false, ...overrides }), event: 'message:received' };
  const history = histories.get(session) || []; history.push(body.data); histories.set(session, history);
  return deliver(body);
};
let passed = 0;
const test = async (name, action) => { await action(); passed += 1; process.stdout.write('通过 UNIT/CONTRACT ' + name + '\n'); };

(async () => {
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
  await test('P0 不确定 operator 仍无法归属时建立代次栅栏，但不吞掉其后的新问题', async () => {
    const before = sent.length;
    const item = await deferredOperatorCase('unknown', {});
    const previousGeneration = state(item.session).generation;
    await runtime.process(item.control.key, item.control.jobId);
    assert.equal(state(item.session).generation, previousGeneration + 1);
    assert.equal(item.visitorJob().generation, state(item.session).generation);
    assert.equal(item.visitorJob().status, 'received');
    assert.equal((await runtime.process(item.visitor.key, item.visitor.jobId)).status, 'sent');
    assert.equal(sent.length, before + 1);
  });
  await test('P0 同一时间戳按持久 sequence 判断先后，控制后的访客消息仍处理一次', async () => {
    const before = sent.length;
    const item = await deferredOperatorCase('same-timestamp', {}, 0);
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
    for (const [suffix, resolutions, shouldSend] of [
      ['unknown-then-automated', [{}, { automated: true }], true],
      ['unknown-then-unknown', [{}, {}], true],
      ['unknown-then-human', [{}, { automated: false }], false],
    ]) {
      const before = sent.length;
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
      assert.equal(visitorJob().deferred_control, true);
      histories.set(session, [...originals.map((data, index) => ({ ...data, ...resolutions[index] })), ...(histories.get(session) || [])]);
      await runtime.process(controls[0].key, controls[0].jobId);
      assert.equal(state(session).uncertain_events.length, 1);
      assert.equal(visitorJob().deferred_control, true, '尚有第二个未决控制时不能提前释放');
      await runtime.process(controls[1].key, controls[1].jobId);
      if (shouldSend) {
        assert.equal(state(session).mode, 'ai');
        assert.equal(visitorJob().status, 'received');
        assert.equal(visitorJob().deferred_control, undefined);
        assert.equal((await runtime.process(visitor.key, visitor.jobId)).status, 'sent');
        assert.equal(sent.length, before + 1);
      } else {
        assert.equal(state(session).mode, 'human');
        assert.equal(visitorJob().status, 'cancelled');
        assert.equal(sent.length, before);
      }
    }
  });
  await test('P0 operator 归属事务后崩溃重放保持幂等，不取消恢复期间的新消息', async () => {
    for (const [suffix, resolved, expectedResult] of [
      ['not-human', { automated: true }, 'not-human'],
      ['unknown', {}, 'unknown'],
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
        delete stored.plan;
      });
      runtime = createRuntime(env, runtimeOptions);
      await runtime.process(item.control.key, item.control.jobId);
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
  await test('P0 兼容旧版已移除 uncertain ID 的崩溃状态，不重复 unknown 栅栏', async () => {
    const item = await deferredOperatorCase('legacy-resolution-replay', {});
    const originalData = structuredClone(state(item.session).jobs.find((job) => job.id === item.control.jobId).data);
    await runtime.process(item.control.key, item.control.jobId);
    assert.equal((await runtime.process(item.visitor.key, item.visitor.jobId)).status, 'sent');
    const firstGeneration = state(item.session).generation;
    await runtime.transaction(item.control.key, (current) => {
      const stored = current.jobs.find((job) => job.id === item.control.jobId);
      delete stored.operator_resolution;
      stored.status = 'processing';
      stored.lease_until = now - 1;
      stored.data = originalData;
      delete stored.plan;
    });
    const sentBefore = sent.length;
    now += 1;
    const later = await receive(message(item.session, '旧版崩溃状态恢复后的新问题'));
    runtime = createRuntime(env, runtimeOptions);
    await runtime.process(item.control.key, item.control.jobId);
    const recovered = state(item.session).jobs.find((job) => job.id === item.control.jobId);
    assert.equal(recovered.operator_resolution.legacy_recovered, true);
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
      sendRejection = status;
      const attempts = sendAttempts;
      const modelCount = modelRequests.length;
      const result = await deliver(message(session, '虚构发送拒绝回归问题'));
      assert.equal(result.status, 'failed');
      assert.equal(sendAttempts, attempts + 1);
      assert.equal(modelRequests.length, modelCount + 1);
      assert.equal(state(session).mode, 'ai');
      const failed = Object.values(state(session).outgoing).at(-1);
      assert.equal(failed.status, 'failed');
      assert.equal(failed.failure, 'crisp_http_' + status);
      assert.equal('body' in failed, false);
      now += 15000;
      await runtime.process(key(session));
      assert.equal(sendAttempts, attempts + 1);
      assert.equal(modelRequests.length, modelCount + 1);
    }
    sendRejection = 0;
  });
  await test('T19/T21 真点击缺少from/type、原fingerprint已见也只暂停A', async () => {
    const card = sent.find((entry) => entry.session_id === 'session_client-a' && entry.type === 'picker');
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
    const original = readConfig('keyword'); const revised = structuredClone(original); revised.rules[0].offer_ttl_seconds = 1; writeConfig('keyword', revised);
    await deliver(message('session_expired01', '人工')); const card = sent.at(-1); now += 1100; await deliver(click('session_expired01', card)); assert.equal(state('session_expired01').mode, 'ai');
    assert.equal(runtime.matchRule('不需要人工'), undefined);
    revised.rules[0].enabled = false; writeConfig('keyword', revised); assert.equal(runtime.matchRule('人工'), undefined); writeConfig('keyword', original);
    await deliver(message('session_oldoffer1', '人工')); const stale = sent.at(-1); await runtime.resume(key('session_oldoffer1')); await deliver(click('session_oldoffer1', stale)); assert.equal(state('session_oldoffer1').mode, 'ai');
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
    now += 5; await operator('session_slowmodel1'); await deliver(message('session_parallel-b', 'B 的快速问题'));
    assert.equal(state('session_slowmodel1').mode, 'human'); const before = sent.filter((entry) => entry.session_id === 'session_slowmodel1').length;
    finish(); await pending;
    assert.equal(sent.filter((entry) => entry.session_id === 'session_slowmodel1').length, before);
    assert.equal(sent.at(-1).session_id, 'session_parallel-b');
  });
  await test('P0 人工接管中止已登记但仍挂起的 Crisp 出站，A 不补发且 B 独立', async () => {
    let release;
    delayedCrisp = new Promise((resolve) => { release = resolve; });
    const session = 'session_crisp-send-race';
    const attempts = sendAttempts;
    const beforeA = sent.filter((entry) => entry.session_id === session).length;
    const entry = await receive(message(session, '等待发送的普通问题'));
    const pending = runtime.process(entry.key, entry.jobId);
    for (let tries = 0; tries < 200 && sendAttempts === attempts; tries += 1) await wait(5);
    assert.equal(sendAttempts, attempts + 1, '普通回答必须已经进入受控 Crisp POST');
    now += 5;
    const controlRuntime = createRuntime(env, runtimeOptions);
    const human = { ...message(session, '另一运行时实例收到真人公开回复', { from: 'operator', automated: false }), event: 'message:received' };
    const history = histories.get(session) || []; history.push(human.data); histories.set(session, history);
    const accepted = await controlRuntime.receive({ body: human, query: { key: env.CRISP_WEBSITE_HOOK_SECRET } });
    assert.equal(accepted.accepted, true);
    if (accepted.route === 'process') await controlRuntime.process(accepted.key, accepted.jobId);
    for (let tries = 0; tries < 100 && !Object.values(state(session).outgoing)
      .some(record => record.cancellation_reason === 'conversation_state_changed'); tries += 1) await wait(10);
    const result = await pending;
    release();
    assert.equal(result.status, 'cancelled');
    assert.equal(state(session).mode, 'human');
    assert.equal(sent.filter((item) => item.session_id === session).length, beforeA, '挂起出站必须在写入远端记录前中止');
    const outgoing = Object.values(state(session).outgoing).at(-1);
    assert.equal(outgoing.status, 'cancelled', '人工接管后本地发送尝试必须终止，不能继续作为待对账发送');
    assert.equal(outgoing.delivery_uncertain, true, '已经进入 HTTP 层的尝试仍须如实标记远端收包不确定');
    assert.equal(outgoing.cancellation_reason, 'conversation_state_changed');
    assert.equal(Object.hasOwn(outgoing, 'body'), false, '取消后的记录不得长期保留待发送正文');
    assert.equal(state(session).jobs.find((job) => job.id === entry.jobId).status, 'cancelled');
    await deliver(message('session_crisp-send-race-b', '另一会话继续工作'));
    assert.equal(sent.at(-1).session_id, 'session_crisp-send-race-b');
  });
  await test('P0 远端已收字节的迟到回执如实隔离，不记正常 AI 回复且旧 attempt 不覆盖新记录', async () => {
    const analytics = path.join(root, 'data/analytics/events.jsonl');
    const countEvents = type => fs.existsSync(analytics) ? fs.readFileSync(analytics, 'utf8').trim().split('\n').filter(Boolean)
      .map(line => JSON.parse(line)).filter(event => event.type === type).length : 0;
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
    await controlRuntime.receive({ body: human, query: { key: env.CRISP_WEBSITE_HOOK_SECRET } });
    release();
    const result = await pending;
    ignoreCrispAbort = false;
    assert.equal(result.status, 'dispatched_after_cancel');
    const outgoing = Object.values(state(session).outgoing).find((record) => record.job_id === entry.jobId);
    assert.equal(outgoing.status, 'sent');
    assert.equal(outgoing.state_changed_before_receipt, true);
    assert.equal(countEvents('delivery_after_state_change'), lateDeliveries + 1);
    assert.equal(countEvents('ai_reply'), normalReplies, '状态变化后的迟到回执不能登记为正常 AI 回复');

    delayedCrisp = new Promise((resolve) => { release = resolve; });
    const fencedSession = 'session_crisp-attempt-fence';
    const fencedAttempts = sendAttempts;
    const fenced = await receive(message(fencedSession, '模拟旧实例迟到回执'));
    const fencedPending = runtime.process(fenced.key, fenced.jobId);
    for (let tries = 0; tries < 200 && sendAttempts === fencedAttempts; tries += 1) await wait(5);
    const replacement = 'e'.repeat(32);
    await runtime.transaction(fenced.key, current => {
      const record = Object.values(current.outgoing).find(value => value.job_id === fenced.jobId);
      record.attempt_token = replacement;
      record.status = 'sending';
    });
    release();
    const fencedResult = await fencedPending;
    ignoreCrispAbort = false;
    assert.equal(fencedResult.status, 'dispatched_after_cancel');
    const fencedRecord = Object.values(state(fencedSession).outgoing).find(record => record.job_id === fenced.jobId);
    assert.equal(fencedRecord.attempt_token, replacement);
    assert.equal(fencedRecord.status, 'sending', '旧实例不得用迟到回执覆盖新 attempt 的状态');
  });
  await test('T29/T30 十秒截止、真人追加、访客与乱序不改时间', async () => {
    const handoff = readConfig('handoff'); handoff.handoff.resume_after_seconds = 10; writeConfig('handoff', handoff);
    const start = now += 100; await operator('session_timeline01');
    assert.equal(state('session_timeline01').resume_at, start + 10000);
    now = start + 5000; await deliver(message('session_timeline01', '访客消息')); assert.equal(state('session_timeline01').resume_at, start + 10000);
    now = start + 6000; await operator('session_timeline01'); assert.equal(state('session_timeline01').resume_at, start + 16000);
    await operator('session_timeline01', { timestamp: start + 2000 }); assert.equal(state('session_timeline01').resume_at, start + 16000);
    now = start + 10000; await runtime.list(); assert.equal(state('session_timeline01').mode, 'human');
    now = start + 16001; await runtime.scan(); assert.equal(state('session_timeline01').mode, 'ai'); await deliver(message('session_timeline01', '恢复后的新问题')); assert.equal(sent.at(-1).session_id, 'session_timeline01');
  });
  await test('T30/T31 零秒人工重建runtime与八天后不丢失', async () => {
    const handoff = readConfig('handoff'); handoff.handoff.resume_after_seconds = 0; writeConfig('handoff', handoff);
    now += 100; await operator('session_permanent1'); assert.equal(state('session_permanent1').resume_at, null);
    now += 8 * 86400000; runtime = createRuntime(env, runtimeOptions); await runtime.scan(); assert.equal(state('session_permanent1').mode, 'human');
    const before = sent.length; await deliver(message('session_permanent1', '永久人工后问题')); assert.equal(sent.length, before);
  });
  await test('T32/T33 总开关关闭阻断在途且仍接收真人控制', async () => {
    let finish; delayed = new Promise((resolve) => { finish = resolve; }); const entry = await receive(message('session_globalrace', '慢回复'));
    const pending = runtime.process(entry.key, entry.jobId); await wait(20);
    writeConfig('runtime', { schema_version: 2, enabled: false, revision: 2, applied_revision: 2 });
    const before = sent.length; finish(); await pending; await deliver(message('session_globalnew1', '人工')); assert.equal(sent.length, before);
    now += 10; await operator('session_globalhuman'); assert.equal(state('session_globalhuman').mode, 'human');
    writeConfig('runtime', { schema_version: 2, enabled: true, revision: 3, applied_revision: 3 }); await deliver(message('session_globalhuman', '仍人工')); assert.equal(sent.length, before);
  });
  await test('T34/T35 欢迎独立、SDK事件与公开白名单按会话控制', async () => {
    const menu = readConfig('menu'); menu.welcome = { enabled: true, text: '自定义欢迎\n第二行 😀', trigger: 'widget_load', auto_open: true, show_menu: false }; writeConfig('menu', menu);
    const signal = { ...message('session_welcome001', ''), event: 'session:sync:events', data: { session_id: 'session_welcome001', events: [{ text: 'crispai_widget_load', timestamp: now }] } };
    await deliver(signal); assert.equal(sent.at(-1).content, menu.welcome.text); const before = sent.length;
    await deliver(signal); now += 1; signal.timestamp = now; await deliver(signal); assert.equal(sent.length, before);
    const publicOptions = await runtime.publicConfig({ website_id: env.CRISP_WEBSITE_ID, session_id: 'session_welcome001' }); assert.equal(publicOptions.auto_open, true); assert.deepEqual(Object.keys(publicOptions).sort(), ['auto_open', 'enabled', 'revision', 'trigger', 'welcome_enabled']);
    await operator('session_welcome001'); assert.equal((await runtime.publicConfig({ website_id: env.CRISP_WEBSITE_ID, session_id: 'session_welcome001' })).auto_open, false);
    menu.welcome.enabled = false; writeConfig('menu', menu); await deliver(message('session_welcomeoff', '普通问题')); assert(!sent.at(-1).content.includes('自定义欢迎'));
  });
  await test('T36 菜单原生选择、返回与人工二次确认', async () => {
    await deliver(message('session_menu0001', '菜单')); let card = sent.at(-1); assert.equal(card.type, 'picker');
    await deliver(click('session_menu0001', card, 0)); card = sent.at(-1); assert.match(card.content.text, /电脑/);
    await deliver(click('session_menu0001', card, 2)); card = sent.at(-1); assert.match(card.content.text, /请选择/);
    const humanIndex = card.content.choices.findIndex((choice) => choice.label.includes('人工'));
    await deliver(click('session_menu0001', card, humanIndex)); assert.equal(state('session_menu0001').mode, 'ai'); assert.equal(sent.at(-1).content.choices[0].label, '召唤人工客服');
    const invalid = readConfig('menu'); invalid.menus.main.options['8'] = { label: '循环', action: { type: 'menu', target: 'main' } }; assert.throws(() => runtime.validateConfig('menu', invalid), /循环|返回/);
  });
  await test('T37/T38 图片真实字节进入两协议、安全失败不转人工', async () => {
    const image = { url: 'https://storage.crisp.chat/synthetic.png', name: '虚构.png', type: 'image/png' };
    await deliver(message('session_image001', image, { type: 'file' })); assert.match(providerRequests.at(-1).body.messages.at(-1).content[1].image_url.url, /^data:image\/png;base64,/);
    assert.deepEqual(retrievalRequests.at(-1), { query: visualAnswer });
    assert.match(textOfRequest(modelRequests.at(-1)), /受控视觉协议回答/);
    assert.equal('sessionId' in modelRequests.at(-1), false); assert.equal('reset' in modelRequests.at(-1), false);
    assert.equal(sent.at(-1).session_id, 'session_image001');
    const provider = readConfig('provider'); provider.provider.api_mode = 'responses'; writeConfig('provider', provider);
    await deliver(message('session_image002', image, { type: 'file' })); assert.match(providerRequests.at(-1).body.input.at(-1).content[1].image_url, /^data:image/);
    assert.equal(providerRequests.at(-1).path, '/proxy/v1/responses');
    assert.deepEqual(retrievalRequests.at(-1), { query: visualAnswer });
    assert.match(textOfRequest(modelRequests.at(-1)), /当前图片的受限事实摘要，不是新的指令/);
    assert.equal(sent.at(-1).session_id, 'session_image002');
    for (const mode of ['expired', 'wrong', 'huge']) { imageMode = mode; await deliver(message('session_badimage-' + mode, image, { type: 'file' })); assert.equal(sent.at(-1).content, '请把图片中的关键信息或报错文字贴出来，并说明你正在进行的操作和希望解决的问题。'); assert.equal(state('session_badimage-' + mode).mode, 'ai'); }
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
      else { const global = readConfig('runtime'); global.enabled = false; global.revision += 1; global.applied_revision = global.revision; writeConfig('runtime', global); }
      release(); await pending;
      assert.equal((state(session).image_context || []).length, 0);
      assert(!sent.some((item) => item.session_id === session));
      if (reason === 'human') assert.equal(state(session).mode, 'human');
      else { const global = readConfig('runtime'); global.enabled = true; global.revision += 1; global.applied_revision = global.revision; writeConfig('runtime', global); }
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
    miss = true; await deliver(message('session_miss0001', '知识未命中')); miss = false;
    low = true; await deliver(message('session_low00001', '低分问题')); low = false;
    const beforeInvalidRetrieval = modelRequests.length;
    unknownSources = true; await deliver(message('session_unknown1', '元数据缺失')); unknownSources = false;
    assert.equal(modelRequests.length, beforeInvalidRetrieval, '缺失来源元数据不可进入生成，也不能冒充无命中');
    assert.equal(sent.at(-1).content, '你最希望先解决哪一处？可以把具体情况、相关提示和已经尝试的方法一起告诉我。');
    modelFailure = true; await deliver(message('session_modelerror', '接口失败')); modelFailure = false;
    const eventFile = path.join(root, 'data', 'analytics', 'events.jsonl');
    const historicalFeedback = { type: 'feedback', at: new Date(now).toISOString(), answer_id: 'synthetic-historical-answer', session: 'synthetic-history', question: '[历史问题指纹]', feedback: 'negative' };
    fs.appendFileSync(eventFile, JSON.stringify(historicalFeedback) + '\n');
    const modelCount = modelRequests.length;
    await deliver(message('session_negative1', 'token=synthetic-private-value 为什么失败')); await deliver(message('session_negative1', '👎')); assert.equal(state('session_negative1').mode, 'ai');
    assert.equal(modelRequests.length, modelCount + 2); assert.equal(state('session_negative1').pending_feedback, null);
    const events = fs.readFileSync(eventFile, 'utf8').trim().split('\n').map(JSON.parse);
    assert(events.some((event) => event.type === 'retrieval_failed' && event.reason === 'retrieval_invalid')); assert(events.some((event) => event.type === 'knowledge_miss'));
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
    const prior = runtime.transcript([{ from: 'operator', type: 'note', content: '内部内容', fingerprint: 100, timestamp: now }, { from: 'operator', type: 'text', content: '秘密', stealth: true, timestamp: now }, { from: 'user', type: 'text', content: '本条', fingerprint: 101, timestamp: now }, { from: 'user', type: 'text', content: '公开', fingerprint: 102, timestamp: now }], { data: { fingerprint: 101 }, event_time: now }, state('session_client-b')); assert.equal(prior.length, 1); assert.equal(prior[0].content, '公开');
  });
  await test('旧版本持久人工迁移及永久模式保留', async () => {
    const session = 'session_legacy001'; const legacy = { aiEnabled: false, aiResumeAt: 0, handoffGeneration: 3, lastOperatorAt: now, welcomeSent: true, fingerprints: [] };
    fs.writeFileSync(path.join(root, 'data', 'runtime', 'session-' + crypto.createHash('sha256').update(session).digest('hex') + '.json'), JSON.stringify(legacy));
    await deliver(message(session, '迁移后不自动回复')); assert.equal(state(session).mode, 'human'); assert.equal(state(session).generation, 3); assert.equal(state(session).welcome_sent, true);
  });
  await test('生产生成Code采用同一实现，SDK无密钥且状态决定展开', async () => {
    const workflow = JSON.parse(fs.readFileSync(path.join(project, 'n8n', 'workflow.json'), 'utf8'));
    const node = workflow.nodes.find((entry) => entry.name === '校验并持久接收');
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
    const feedback = readConfig('feedback'); feedback.feedback.retention_days = 1; writeConfig('feedback', feedback);
    const file = path.join(root, 'data/analytics/events.jsonl');
    fs.appendFileSync(file, JSON.stringify({ type: 'synthetic_expired', at: new Date(now - 172800000).toISOString() }) + '\n');
    fs.appendFileSync(file, JSON.stringify({ type: 'synthetic_current', at: new Date(now).toISOString() }) + '\n');
    await runtime.scan();
    assert(!fs.readFileSync(file, 'utf8').includes('synthetic_expired'));
    assert(fs.readFileSync(file, 'utf8').includes('synthetic_current'));
    assert.equal(state('session_permanent1').mode, 'human');
  });
  await test('D12 无客户流量时持久扫描心跳仍更新且不包含客户资料', async () => {
    await runtime.scan();
    const file = path.join(root, 'data/runtime/scheduler-health.json');
    const first = JSON.parse(fs.readFileSync(file, 'utf8'));
    assert.equal(first.completed_at, now);
    now += 5000;
    await runtime.scan();
    const next = JSON.parse(fs.readFileSync(file, 'utf8'));
    assert.equal(next.started_at, now);
    assert.equal(next.completed_at, now);
    assert(next.completed_at > first.completed_at);
    assert.deepEqual(Object.keys(next).sort(), ['completed_at', 'schema_version', 'started_at']);
    assert.equal(fs.statSync(file).mode & 0o777, 0o600);
    assert.equal(state('session_permanent1').mode, 'human');
  });
  await test('P0 大量历史会话不放大周期扫描，重叠调度退让且到期人工仍恢复', async () => {
    const bulk = [];
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
          plan: { type: 'text', ordinary: true, purpose: 'safe_error', safe_error_context: 'text',
            content: '你最希望先解决哪一处？可以把具体情况、相关提示和已经尝试的方法一起告诉我。', tags: ['low_confidence'] } });
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
    assert.deepEqual(await runtime.scan(), []);
    assert(fs.existsSync(lock), '没有所有权资料的旧活动锁不能只凭 mtime 被删除');
    assert.equal(fs.readFileSync(health, 'utf8'), healthBefore);
    fs.rmdirSync(lock);

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
    const originalKeyword = fs.readFileSync(path.join(root, 'config/keyword.yaml'));
    const originalPrompt = fs.readFileSync(path.join(root, 'config/prompt.md'));
    const mapFile = path.join(root, 'data/runtime/knowledge-map.json');
    const digest = (value) => crypto.createHash('sha256').update(value).digest('hex');
    const prompt = '完整中文提示 😀\n' + 'x'.repeat(31000) + '\nSYNTHETIC_PROMPT_TAIL';
    const projection = { schema_version: 1, revision: 400, state: 'applied', applied_at: now,
      source_sha256: digest('synthetic-source'), configuration,
      prompt: { text: prompt, sha256: digest(prompt), bytes: Buffer.byteLength(prompt) },
      knowledge: { map_sha256: fs.existsSync(mapFile) ? digest(fs.readFileSync(mapFile)) : '' } };
    projection.configuration.runtime = { ...configuration.runtime, enabled: true, revision: 400, applied_revision: 400 };
    projection.configuration.keyword.rules.unshift({ id: 'projection-test', enabled: true, keywords: ['资料应用测试'], match_mode: 'exact', action: 'reply', text: '已应用版本一' });
    const publish = () => {
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
      assert.match(serviceText, /仅在完成当前咨询确实缺少必要信息时提出具体澄清问题/);
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
      fs.unlinkSync(file);
    }
  });
  await test('W03/B01 应用过渡取消旧答案，保留真人控制，期间问题不补答', async () => {
    const file = path.join(root, 'config/materials-applied.json');
    const mapFile = path.join(root, 'data/runtime/knowledge-map.json');
    const originalMap = fs.existsSync(mapFile) ? fs.readFileSync(mapFile) : null;
    const digest = (value) => crypto.createHash('sha256').update(value).digest('hex');
    const configuration = Object.fromEntries(['runtime', 'handoff', 'keyword', 'menu', 'tags', 'feedback'].map((name) => [name, readConfig(name)]));
    const text = fs.readFileSync(path.join(root, 'config/prompt.md'), 'utf8');
    const projection = { schema_version: 1, revision: 500, state: 'applied', applied_at: now, source_sha256: digest('synthetic-source'), configuration,
      prompt: { text, sha256: digest(text), bytes: Buffer.byteLength(text) }, knowledge: { map_sha256: originalMap ? digest(originalMap) : '' } };
    projection.configuration.runtime = { ...configuration.runtime, enabled: true, revision: 500, applied_revision: 500 };
    const publish = () => { fs.writeFileSync(file + '.candidate', JSON.stringify(projection)); fs.renameSync(file + '.candidate', file); };
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
      await deliver(message('session_materials-during', '过渡期间问题'));
      now += 10; await operator('session_materials-human');
      assert.equal(state('session_materials-human').mode, 'human');
      finish(); await pending;
      assert.equal(sent.length, before);
      projection.state = 'applied'; publish(); await runtime.scan();
      assert.equal(sent.length, before);
      await deliver(message('session_materials-during', '之后的新问题'));
      assert.equal(sent.at(-1).session_id, 'session_materials-during');
      fs.writeFileSync(mapFile, JSON.stringify({ synthetic: 'unapplied-map' }));
      assert.equal(runtime.settings().enabled, false, '知识投影错代禁止普通出站');
      now += 10; await operator('session_materials-map-human');
      assert.equal(state('session_materials-map-human').mode, 'human');
    } finally {
      if (finish) finish();
      if (originalMap) fs.writeFileSync(mapFile, originalMap); else if (fs.existsSync(mapFile)) fs.unlinkSync(mapFile);
      fs.unlinkSync(file);
    }
  });
  await test('L08 请求/解析异常落盘前采用白名单，不泄漏秘密或用户正文', async () => {
    const injected = 'synthetic-private-text & $ # = " 引号\n第二行';
    const variants = [injected, JSON.stringify(injected), encodeURIComponent(injected), Buffer.from(injected).toString('base64')];
    for (const [index, variant] of variants.entries()) {
      const isolated = createRuntime(env, { ...runtimeOptions, request: async () => { throw new SyntaxError(variant); } });
      const body = message('session_log-private-' + index, '无敏感资料的虚构问题');
      const entry = await isolated.receive({ body, query: { key: env.CRISP_WEBSITE_HOOK_SECRET } });
      const result = await isolated.process(entry.key, entry.jobId);
      assert.equal(result.status, 'failed');
      const log = fs.readFileSync(path.join(root, 'data/analytics/events.jsonl'), 'utf8');
      assert(log.includes('配置或协议 JSON 解析失败'));
      for (const secret of variants) {
        assert(!log.includes(secret), '异常正文不得进入落盘日志');
        assert(!JSON.stringify(result).includes(secret));
      }
    }
    assert.equal(state('session_permanent1').mode, 'human');
  });
  process.stdout.write(JSON.stringify({ layer: 'UNIT/CONTRACT', passed, failed: 0, evidence: path.relative(project, root) }) + '\n');
})().catch((error) => { process.stderr.write(error.stack + '\n'); process.exitCode = 1; });
