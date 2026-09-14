'use strict';

const assert = require('assert/strict');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { createRuntime } = require('../n8n/runtime');

const project = path.resolve(__dirname, '..');
const workRoot = path.join(project, '.work', 'v1.3.0');
fs.mkdirSync(workRoot, { recursive: true, mode: 0o700 });
const work = fs.mkdtempSync(path.join(workRoot, 'missing-reply-p0-'));
const website = '11111111-1111-4111-8111-111111111111';
const env = {
  CRISP_WEBSITE_ID: website,
  CRISP_WEBSITE_HOOK_SECRET: 'test-only-website-secret-0001',
  CRISP_AUTH_B64: 'test-only-auth',
  CRISP_TOKEN_TIER: 'website',
  AI_API_KEY: 'test-only-key',
};
const digest = (value) => crypto.createHash('sha256').update(String(value)).digest('hex');
const oldTime = () => new Date(Date.now() - 120000);
const wait = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));

const fixture = (name, runtimeOverrides = {}) => {
  const root = path.join(work, name);
  const runtimeDirectory = path.join(root, 'data', 'runtime');
  fs.mkdirSync(path.join(root, 'config'), { recursive: true });
  fs.mkdirSync(runtimeDirectory, { recursive: true });
  for (const config of ['handoff', 'keyword', 'menu', 'tags', 'feedback', 'provider']) {
    fs.copyFileSync(path.join(project, 'config', config + '.yaml.example'), path.join(root, 'config', config + '.yaml'));
  }
  fs.writeFileSync(path.join(root, 'config', 'runtime.yaml'), JSON.stringify({ schema_version: 2, enabled: true,
    disable_epoch: 0, revision: 1, applied_revision: 1 }));
  fs.writeFileSync(path.join(root, 'config', 'prompt.md'), '受控测试提示');
  let now = 1760000000000;
  const exactMessages = new Map();
  const exactRequests = [];
  const catchupConversationPages = new Map();
  const catchupMessages = new Map();
  const catchupRequests = [];
  const postAttempts = [];
  const postResponses = [];
  const sent = [];
  const catchupMessageBatchSize = Number.isSafeInteger(runtimeOverrides.catchupMessageBatchSize)
    && runtimeOverrides.catchupMessageBatchSize > 0 ? runtimeOverrides.catchupMessageBatchSize : Number.MAX_SAFE_INTEGER;
  const request = async (url, options = {}) => {
    const parsed = new URL(url);
    const conversationPage = /\/website\/[^/]+\/conversations\/([0-9]+)$/.exec(parsed.pathname);
    if (conversationPage) {
      const start = Date.parse(parsed.searchParams.get('filter_date_start'));
      const end = Date.parse(parsed.searchParams.get('filter_date_end'));
      const configured = catchupConversationPages.get(Number(conversationPage[1])) || [];
      const data = Array.isArray(configured) ? configured.filter((conversation) => {
        const raw = conversation?.updated_at;
        const updated = typeof raw === 'number' ? raw : Date.parse(raw);
        return !Number.isFinite(updated) || updated >= start && updated <= end;
      }) : configured;
      catchupRequests.push({ type: 'conversations', page: Number(conversationPage[1]),
        start: parsed.searchParams.get('filter_date_start'), end: parsed.searchParams.get('filter_date_end') });
      return { status: 200, body: { error: false, data } };
    }
    const conversationMessages = /\/website\/[^/]+\/conversation\/(session_[A-Za-z0-9-]+)\/messages$/.exec(parsed.pathname);
    if (conversationMessages) {
      const session = decodeURIComponent(conversationMessages[1]);
      const after = Number(parsed.searchParams.get('timestamp_after'));
      catchupRequests.push({ type: 'messages', session, after });
      const data = (catchupMessages.get(session) || []).filter((message) => {
        const value = Number(message.timestamp);
        return !Number.isFinite(value) || value > after;
      }).sort((left, right) => {
        const leftTime = Number(left.timestamp);
        const rightTime = Number(right.timestamp);
        if (!Number.isFinite(leftTime) && !Number.isFinite(rightTime)) return 0;
        if (!Number.isFinite(leftTime)) return -1;
        if (!Number.isFinite(rightTime)) return 1;
        return leftTime - rightTime;
      }).slice(0, catchupMessageBatchSize);
      return { status: 200, body: { error: false, data } };
    }
    if (/\/message\//.test(parsed.pathname)) {
      const fingerprint = decodeURIComponent(parsed.pathname.split('/').at(-1));
      exactRequests.push(fingerprint);
      const exact = exactMessages.get(fingerprint);
      if (exact?.status) return { status: exact.status, headers: exact.headers || {},
        body: exact.body || { error: true } };
      return { status: 200, body: { error: false,
        data: exact || { from: 'operator', type: 'text', fingerprint } } };
    }
    if (parsed.pathname.endsWith('/meta') && options.method === 'GET') return { status: 200, body: { error: false, data: { segments: [] } } };
    if (parsed.pathname.endsWith('/meta') && options.method === 'PATCH') return { status: 200, body: { error: false } };
    if (parsed.pathname.endsWith('/message') && options.method === 'POST') {
      const match = /\/conversation\/([^/]+)\/message$/.exec(parsed.pathname);
      const session = decodeURIComponent(match?.[1] || '');
      const body = structuredClone(options.body);
      postAttempts.push({ session_id: session, ...body });
      const configured = postResponses.shift();
      if (configured) return structuredClone(configured);
      sent.push({ session_id: session, ...body, timestamp: now });
      const history = catchupMessages.get(session) || [];
      history.push({ session_id: session, ...body, timestamp: now });
      catchupMessages.set(session, history);
      return { status: 200, body: { error: false, reason: 'dispatched', data: { fingerprint: body.fingerprint } } };
    }
    throw new Error('未预期受控网络请求');
  };
  const options = { root, clock: () => now, request, catchupIntervalMilliseconds: 1000,
    lookup: (_host, _options, callback) => callback(null, [{ address: '8.8.8.8', family: 4 }]),
    ...runtimeOverrides };
  let runtimeEnvironment = { ...env };
  let runtime = createRuntime(runtimeEnvironment, options);
  return {
    root, runtimeDirectory, options,
    get runtime() { return runtime; },
    restart() { runtime = createRuntime(runtimeEnvironment, options); return runtime; },
    restartWithEnv(overrides) {
      runtimeEnvironment = { ...runtimeEnvironment, ...overrides };
      runtime = createRuntime(runtimeEnvironment, options);
      return runtime;
    },
    tick(milliseconds = 5000) { now += milliseconds; },
    now: () => now,
    exactMessages, exactRequests, catchupConversationPages, catchupMessages, catchupRequests,
    postAttempts, postResponses, sent,
  };
};

const stateValue = (fx, session, jobs = [], extra = {}) => ({
  schema_version: 2, website_id: website, session_id: session,
  mode: 'ai', generation: 0, resume_at: null, pause_reason: '', last_human_at: 0,
  human_event_id: '', control_watermark: 0, sequence: jobs.length,
  welcome_sent: false, menu_node: null, offers: {}, cooldowns: {}, jobs, outgoing: {},
  worker: null, uncertain_events: [], pending_feedback: null, updated_at: fx.now(), ...extra,
});
const jobValue = (fx, seed, sequence = 1, extra = {}) => ({
  id: digest(seed), event: 'message:send', data: { from: 'user', type: 'text', content: seed,
    fingerprint: sequence, timestamp: fx.now(), session_id: 'session_placeholder' },
  event_time: fx.now(), received_at: fx.now(), sequence, status: 'received', attempts: 0,
  revision: 1, generation: 0, global_disable_epoch: 0,
  control: false, lease_until: 0, retry_at: null, ...extra,
});
const outgoingValue = (fx, job, plan, extra = {}) => ({
  status: 'unknown',
  body: { type: plan.type || 'text', from: 'operator', origin: 'chat', content: plan.content,
    fingerprint: plan.fingerprint, user: { type: 'website', nickname: '在线客服' } },
  created_at: fx.now() - 20000, attempts: 1, job_id: job.id, generation: 0,
  attempt_token: 'a'.repeat(32), delivery_uncertain: true, ...extra,
});
const stateFile = (fx, session) => path.join(fx.runtimeDirectory, 'session-' + fx.runtime.stateKey(website, session) + '.json');
const writeState = (fx, session, value) => fs.writeFileSync(stateFile(fx, session), JSON.stringify(value), { mode: 0o600 });
const webhook = (fx, session, content, fingerprint, extra = {}) => {
  const timestampFields = extra.omitTimestamp ? {} : { timestamp: extra.timestamp ?? fx.now() };
  return fx.runtime.receive({ query: { key: env.CRISP_WEBSITE_HOOK_SECRET }, body: {
    website_id: website, event: extra.event || 'message:send', ...timestampFields, data: {
      session_id: session, from: extra.from || 'user', type: 'text', content, fingerprint,
      ...timestampFields, ...(extra.automated === undefined ? {} : { automated: extra.automated }),
    },
  } });
};
let passed = 0;
const test = async (name, action) => {
  await action();
  passed += 1;
  process.stdout.write('通过 P0/REGRESSION ' + name + '\n');
};

(async () => {
  await test('人工期产生但恢复后才到达的消息不补答，恢复后的新消息仍入队', async () => {
    const fx = fixture('delayed-human-period-message');
    const session = 'session_delayed-human01';
    const humanAt = fx.now();
    const operator = await webhook(fx, session, '人工处理', 90001,
      { event: 'message:received', from: 'operator', automated: false, timestamp: humanAt });
    const paused = fx.runtime.readState(operator.key);
    assert.equal(paused.mode, 'human');
    const resumeAt = paused.resume_at;
    assert(resumeAt > humanAt);

    fx.tick(resumeAt - fx.now() + 1000);
    const delayed = await webhook(fx, session, '人工期内已发送但迟到的问题', 90002,
      { timestamp: humanAt + 1000 });
    assert.equal(delayed.statusCode, 200);
    assert.equal(delayed.route, 'ignore');
    const afterDelayed = fx.runtime.readState(operator.key);
    const discarded = afterDelayed.jobs.find((job) => job.id === delayed.jobId);
    assert.equal(afterDelayed.mode, 'ai');
    assert.equal(afterDelayed.control_watermark, resumeAt);
    assert.equal(discarded.status, 'done');
    assert.equal(discarded.data, undefined);
    assert(discarded.event_time < afterDelayed.control_watermark);
    assert(!(await fx.runtime.scan()).some((job) => job.jobId === delayed.jobId));

    const current = await webhook(fx, session, '恢复后真正的新问题', 90003, { timestamp: fx.now() });
    assert.equal(current.statusCode, 200);
    assert.equal(current.route, 'process');
    const queued = fx.runtime.readState(operator.key).jobs.find((job) => job.id === current.jobId);
    assert.equal(queued.status, 'received');
    assert(queued.event_time > afterDelayed.control_watermark);
  });

  await test('缺失或损坏 timestamp 先经精确 REST 核对，旧消息丢弃而真正新消息继续', async () => {
    for (const variant of ['missing', 'invalid']) {
      const fx = fixture('unverified-event-time-' + variant);
      const session = 'session_unverified-' + variant;
      const humanAt = fx.now();
      const operator = await webhook(fx, session, '人工处理', variant === 'missing' ? 91001 : 92001,
        { event: 'message:received', from: 'operator', automated: false, timestamp: humanAt });
      const resumeAt = fx.runtime.readState(operator.key).resume_at;
      fx.tick(resumeAt - fx.now() + 1000);

      const oldFingerprint = variant === 'missing' ? 91002 : 92002;
      fx.exactMessages.set(String(oldFingerprint), { from: 'user', type: 'text', fingerprint: oldFingerprint,
        content: '人工期内的迟到消息', timestamp: humanAt + 1000 });
      const old = await webhook(fx, session, '人工期内的迟到消息', oldFingerprint,
        variant === 'missing' ? { omitTimestamp: true } : { timestamp: 'not-a-timestamp' });
      assert.equal(old.route, 'process');
      assert.equal(fx.runtime.readState(operator.key).jobs.find((job) => job.id === old.jobId).event_time_unverified, true);
      assert.equal((await fx.runtime.process(old.key, old.jobId)).status, 'discarded');
      let stored = fx.runtime.readState(operator.key).jobs.find((job) => job.id === old.jobId);
      assert.equal(stored.status, 'done'); assert.equal(stored.data, undefined);
      assert.equal(stored.event_time, humanAt + 1000);

      // 精确端点的短暂 404 只延后，不会把本机收件时间当成新消息，也不会
      // 消耗通用三次失败后发送澄清的兜底次数。
      const newFingerprint = variant === 'missing' ? 91003 : 92003;
      fx.exactMessages.set(String(newFingerprint), { status: 404 });
      const current = await webhook(fx, session, '恢复后真正的新消息', newFingerprint,
        variant === 'missing' ? { omitTimestamp: true } : { timestamp: 'still-invalid' });
      assert.equal(current.route, 'process');
      assert.equal((await fx.runtime.process(current.key, current.jobId)).status, 'deferred');
      stored = fx.runtime.readState(operator.key).jobs.find((job) => job.id === current.jobId);
      assert.equal(stored.status, 'received'); assert.equal(stored.attempts, 0);
      assert.equal(stored.event_time_unverified, true);

      stored = fx.runtime.readState(operator.key).jobs.find((job) => job.id === current.jobId);
      const provisionalIdentity = stored.input_identity_sha256;
      if (stored.retry_at > fx.now()) fx.tick(stored.retry_at - fx.now() + 1);
      fs.writeFileSync(path.join(fx.root, 'config', 'provider-pool-transaction.json'), '{}', { mode: 0o600 });
      fx.exactMessages.set(String(newFingerprint), { from: 'user', type: 'text', fingerprint: newFingerprint,
        content: '恢复后真正的新消息', timestamp: fx.now() });
      assert.equal((await fx.runtime.process(current.key, current.jobId)).status, 'deferred');
      stored = fx.runtime.readState(operator.key).jobs.find((job) => job.id === current.jobId);
      assert.equal(stored.status, 'received'); assert.equal(stored.event_time_source, 'crisp_exact');
      assert.equal(stored.event_time_unverified, undefined);
      assert(stored.event_time >= resumeAt);
      assert.notEqual(stored.input_identity_sha256, provisionalIdentity,
        '精确时间和身份回读后必须重算持久输入责任摘要');
      assert.deepEqual(fx.exactRequests, [String(oldFingerprint), String(newFingerprint), String(newFingerprint)]);
    }
  });

  await test('REST 补偿首次只立水位，随后可发现无本地状态的新会话并去重', async () => {
    const fx = fixture('rest-catchup-new-conversation');
    const session = 'session_catchup-new01';
    const before = fx.now();
    fx.catchupConversationPages.set(1, [{ website_id: website, session_id: session, updated_at: before - 1000 }]);
    fx.catchupMessages.set(session, [{ website_id: website, session_id: session, from: 'user', type: 'text',
      content: '上线补偿前的历史问题', fingerprint: 93001, timestamp: before - 1000 }]);
    assert.equal((await fx.runtime.catchup()).status, 'bootstrap');
    assert.equal(fx.catchupRequests.length, 0, '首次启用必须只持久当前水位');
    assert(!fs.existsSync(stateFile(fx, session)), '上线前的历史会话不得被补答');

    fx.tick(16000);
    const eventTime = before + 5000;
    fx.catchupConversationPages.set(1, [{ website_id: website, session_id: session, updated_at: eventTime }]);
    fx.catchupMessages.set(session, [
      ...fx.catchupMessages.get(session),
      { website_id: website, session_id: session, from: 'user', type: 'text',
        content: '未收到 Hook 的新问题', fingerprint: 93002, timestamp: eventTime },
    ]);
    await fx.runtime.catchup();
    assert.equal(fx.catchupRequests.find((item) => item.type === 'conversations').page, 1,
      'Crisp Conversations 分页从 1 开始，绝不请求 page/0');
    assert(!fx.catchupRequests.some((item) => item.type === 'conversations' && item.page === 0));
    const selected = await fx.runtime.scan();
    const key = fx.runtime.stateKey(website, session);
    assert(selected.some((entry) => entry.key === key), '新 conversation 应在同轮扫描进入调度');
    let current = fx.runtime.readState(key);
    assert.deepEqual(current.jobs.map((job) => job.data?.fingerprint).filter(Boolean), [93002]);
    assert(!current.observations?.hook_received_at, 'REST 补偿不得冒充 Hook 成功观察');
    const duplicate = await webhook(fx, session, '未收到 Hook 的新问题', 93002, { timestamp: eventTime });
    assert.equal(duplicate.reason, '重复事件已忽略');
    current = fx.runtime.readState(key);
    assert.equal(current.jobs.length, 1, '补偿与迟到 Hook 必须共用同一去重事实');
    const health = JSON.parse(fs.readFileSync(path.join(fx.runtimeDirectory, 'scheduler-health.json'), 'utf8'));
    assert.equal(health.crisp_rest_catchup.status, 'ok');
    assert.equal(health.crisp_rest_catchup.recovered_messages, 1);
  });

  await test('会话更新时间后移不会让较早但上线后的漏收消息永久越过水位', async () => {
    const fx = fixture('rest-catchup-updated-at-race');
    const session = 'session_catchup-updated-race';
    const baseline = fx.now();
    assert.equal((await fx.runtime.catchup()).status, 'bootstrap');
    const missedAt = baseline + 120000;
    // 消息实际产生于 t+2m，但 conversation.updated_at 直到 t+11m
    // 才前移。两轮空窗已把全局水位推到 t+10m；第三轮仍必须
    // 从该会话自己的上线水位取回 t+2m，而不是从全局 t+5m 开始。
    fx.tick(300000);
    await fx.runtime.catchup();
    fx.tick(300000);
    await fx.runtime.catchup();
    const movedAt = baseline + 660000;
    fx.tick(120000);
    fx.catchupConversationPages.set(1, [{ website_id: website, session_id: session, updated_at: movedAt }]);
    fx.catchupMessages.set(session, [{ website_id: website, session_id: session, from: 'user', type: 'text',
      content: '会话更新时间后移前漏收的问题', fingerprint: 93201, timestamp: missedAt }]);
    const requestStart = fx.catchupRequests.length;
    await fx.runtime.catchup();
    const currentRequests = fx.catchupRequests.slice(requestStart);
    const lists = currentRequests.filter((item) => item.type === 'conversations');
    const list = lists.at(-1);
    assert(Date.parse(list.start) > missedAt, '回归必须真实覆盖全局窗口已越过消息的场景');
    assert.equal(Date.parse(list.end), fx.now());
    const messageRequest = currentRequests.find((item) => item.type === 'messages');
    assert(messageRequest && messageRequest.after < missedAt);
    const current = fx.runtime.readState(fx.runtime.stateKey(website, session));
    assert.equal(current.jobs.length, 1);
    assert.equal(current.jobs[0].data.fingerprint, 93201);
    assert.equal(current.crisp_rest_catchup.cursor, fx.now());
  });

  await test('REST 补偿从自有 picker 绑定恢复 message:updated，重复过期和跨会话选择均安全', async () => {
    const fx = fixture('rest-catchup-picker-update');
    const baseline = fx.now();
    await fx.runtime.catchup();
    const validSession = 'session_catchup-picker-valid';
    const crossSession = 'session_catchup-picker-cross';
    const expiredSession = 'session_catchup-picker-expired';
    const offerId = 'offer-catchup-picker';
    const fingerprint = 93401;
    const choice = 'confirm-catchup-handoff';
    const offer = (expiresAt) => ({ id: offerId, fingerprint, kind: 'handoff', rule_id: 'synthetic-rule',
      revision: 1, generation: 0, issued_at: baseline, expires_at: expiresAt, consumed_at: null,
      choices: { [choice]: { type: 'confirm_handoff' }, cancel: { type: 'cancel_handoff' } },
      confirm_message: '已收到您的人工协助请求。' });
    writeState(fx, validSession, stateValue(fx, validSession, [], { offers: { [offerId]: offer(baseline + 600000) } }));
    writeState(fx, expiredSession, stateValue(fx, expiredSession, [], { offers: { [offerId]: offer(baseline + 1000) } }));
    fx.tick(16000);
    const selected = { session_id: validSession, fingerprint, timestamp: baseline + 1000,
      content: { id: offerId, text: '请选择', choices: [{ value: choice, label: '召唤人工客服', selected: true }] } };
    fx.catchupConversationPages.set(1, [validSession, crossSession, expiredSession].map((session) => ({
      website_id: website, session_id: session, updated_at: fx.now(),
    })));
    fx.catchupMessages.set(validSession, [selected]);
    fx.catchupMessages.set(crossSession, [{ ...selected, session_id: crossSession }]);
    fx.catchupMessages.set(expiredSession, [{ ...selected, session_id: expiredSession }]);
    await fx.runtime.catchup();
    let current = fx.runtime.readState(fx.runtime.stateKey(website, validSession));
    assert.equal(current.mode, 'human');
    assert.equal(current.pause_reason, 'confirmed_handoff');
    assert(current.control_watermark >= fx.now(), '缺 from/type 的 REST picker 更新必须以当前更新事实提交人工水位');
    const generation = current.generation;
    assert.equal(fx.runtime.readState(fx.runtime.stateKey(website, crossSession)).mode, 'ai');
    assert.equal(fx.runtime.readState(fx.runtime.stateKey(website, expiredSession)).mode, 'ai');
    fx.tick(1001);
    await fx.runtime.catchup();
    current = fx.runtime.readState(fx.runtime.stateKey(website, validSession));
    assert.equal(current.generation, generation, '重复选择不得再次暂停或重置计时');
  });

  await test('REST 补偿生产默认至少六十秒，未到持久时间不访问 Crisp', async () => {
    const fx = fixture('rest-catchup-production-interval', { catchupIntervalMilliseconds: undefined });
    assert.equal((await fx.runtime.catchup()).status, 'bootstrap');
    const statePath = path.join(fx.runtimeDirectory, 'crisp-rest-catchup.json');
    let persisted = JSON.parse(fs.readFileSync(statePath, 'utf8'));
    assert.equal(persisted.next_scan_at - fx.now(), 60000, '生产默认补偿间隔必须至少六十秒');
    fx.tick(59999);
    const beforeRequests = fx.catchupRequests.length;
    assert.equal((await fx.runtime.catchup()).status, 'idle');
    assert.equal(fx.catchupRequests.length, beforeRequests, '未到 next_scan_at 不得访问会话列表或消息');
    fx.tick(1);
    await fx.runtime.catchup();
    assert.equal(fx.catchupRequests.slice(beforeRequests).filter((item) => item.type === 'conversations').length, 1);
    persisted = JSON.parse(fs.readFileSync(statePath, 'utf8'));
    assert(persisted.next_scan_at >= fx.now() + 60000);
  });

  await test('Crisp endpoint 与 Token 代次独立于站点水位，合法变更不丢固定窗口', async () => {
    const fx = fixture('rest-catchup-credential-generation');
    await fx.runtime.catchup();
    const baseline = fx.now();
    fx.tick(16000);
    const sessions = Array.from({ length: 4 }, (_, index) => 'session_catchup-rotate' + index);
    fx.catchupConversationPages.set(1, sessions.map((session) => ({ website_id: website,
      session_id: session, updated_at: baseline + 1000 })));
    for (const [index, session] of sessions.entries()) fx.catchupMessages.set(session, [{
      website_id: website, session_id: session, from: 'user', type: 'text', content: '轮换窗口问题',
      fingerprint: 93500 + index, timestamp: baseline + 1000,
    }]);
    await fx.runtime.catchup();
    const statePath = path.join(fx.runtimeDirectory, 'crisp-rest-catchup.json');
    const before = JSON.parse(fs.readFileSync(statePath, 'utf8'));
    assert(before.window, '夹具必须保留未完成固定窗口');
    assert.equal(before.schema_version, 2, '补偿状态必须使用可区分站点、endpoint 与凭据代次的 schema2');
    for (const field of ['site_binding', 'endpoint_binding', 'credential_binding']) {
      assert.match(before[field] || '', /^[a-f0-9]{64}$/, field + ' 必须是本机不可导出的绑定摘要');
    }
    const requestCount = fx.catchupRequests.length;

    fx.restartWithEnv({ CRISP_API_BASE_URL: 'https://api-alternate.example.test/v1' });
    await fx.runtime.scan();
    let health = JSON.parse(fs.readFileSync(path.join(fx.runtimeDirectory, 'scheduler-health.json'), 'utf8'));
    assert.equal(health.crisp_rest_catchup.status, 'warning');
    assert.equal(health.crisp_rest_catchup.error_code, 'endpoint_changed',
      '尚未运行 catchup 时只读健康也必须立即失效旧 endpoint 的 PASS');
    const changed = await fx.runtime.catchup();
    assert.equal(changed.status, 'warning');
    assert.equal(changed.error_code, 'endpoint_changed');
    assert.equal(fx.catchupRequests.length, requestCount, 'endpoint 换代标记本身不得向旧地址继续发 REST');
    const afterEndpoint = JSON.parse(fs.readFileSync(statePath, 'utf8'));
    assert.equal(afterEndpoint.schema_version, 2);
    assert.equal(afterEndpoint.site_binding, before.site_binding, '合法 endpoint 变化不得冒充换站点');
    assert.notEqual(afterEndpoint.endpoint_binding, before.endpoint_binding);
    assert.equal(afterEndpoint.credential_binding, before.credential_binding);
    assert.equal(afterEndpoint.watermark, before.watermark);
    assert.deepEqual(afterEndpoint.window, before.window, 'endpoint 换代不得丢掉未完成窗口和消息游标');
    assert.equal(afterEndpoint.next_scan_at, fx.now());

    // 下一轮先用完整的新 endpoint 代次推进一次，再轮换 Token/tier；两次
    // 变更分别验证，避免“新地址 + 旧 Key”或“旧地址 + 新 Key”的混代请求。
    await fx.runtime.catchup();
    const beforeCredential = JSON.parse(fs.readFileSync(statePath, 'utf8'));
    const credentialRequestCount = fx.catchupRequests.length;
    fx.restartWithEnv({ CRISP_AUTH_B64: 'rotated-test-only-auth', CRISP_TOKEN_TIER: 'plugin' });
    await fx.runtime.scan();
    health = JSON.parse(fs.readFileSync(path.join(fx.runtimeDirectory, 'scheduler-health.json'), 'utf8'));
    assert.equal(health.crisp_rest_catchup.status, 'warning');
    assert.equal(health.crisp_rest_catchup.error_code, 'credentials_changed',
      '只读健康必须立即失效旧凭据的 PASS');
    const credentialChanged = await fx.runtime.catchup();
    assert.equal(credentialChanged.status, 'warning');
    assert.equal(credentialChanged.error_code, 'credentials_changed');
    assert.equal(fx.catchupRequests.length, credentialRequestCount, '凭据换代标记本身不得发混代 REST');
    const afterCredential = JSON.parse(fs.readFileSync(statePath, 'utf8'));
    assert.equal(afterCredential.site_binding, beforeCredential.site_binding);
    assert.equal(afterCredential.endpoint_binding, beforeCredential.endpoint_binding);
    assert.notEqual(afterCredential.credential_binding, beforeCredential.credential_binding);
    assert.equal(afterCredential.watermark, beforeCredential.watermark);
    assert.deepEqual(afterCredential.window, beforeCredential.window, 'Token/tier 轮换不得丢掉未完成窗口和消息游标');
    assert.equal(afterCredential.next_scan_at, fx.now());

    await fx.runtime.scan();
    health = JSON.parse(fs.readFileSync(path.join(fx.runtimeDirectory, 'scheduler-health.json'), 'utf8'));
    assert.equal(health.crisp_rest_catchup.status, 'warning');
    assert.equal(health.crisp_rest_catchup.error_code, 'credentials_changed');
    const exposed = JSON.stringify(health.crisp_rest_catchup);
    for (const binding of [afterCredential.site_binding, afterCredential.endpoint_binding,
      afterCredential.credential_binding]) assert(!exposed.includes(binding),
      '调度/doctor 事实不得输出任何本地 binding');
    assert(!exposed.includes('rotated-test-only-auth'));
    await fx.runtime.catchup();
    const verified = JSON.parse(fs.readFileSync(statePath, 'utf8'));
    assert.notEqual(verified.last_result.error_code, 'credentials_changed', '下一次真实 REST 结果必须覆盖轮换警告');
    assert(verified.window === null || verified.window.index >= beforeCredential.window.index);
  });

  await test('REST 补偿按时间先落人工控制，总开关关闭期也只留去重不补答', async () => {
    const fx = fixture('rest-catchup-controls');
    await fx.runtime.catchup();
    const baseline = fx.now();
    fx.tick(16000);
    const humanSession = 'session_catchup-human01';
    fx.catchupConversationPages.set(1, [{ website_id: website, session_id: humanSession, updated_at: fx.now() }]);
    // REST 响应故意乱序：runtime 必须先按权威 timestamp 摄入早到访客、
    // 再立即提交真人暂停，最后将后到访客标为人工期事实。
    fx.catchupMessages.set(humanSession, [
      { session_id: humanSession, from: 'user', type: 'text', content: '人工后的问题', fingerprint: 94003, timestamp: baseline + 3000 },
      { session_id: humanSession, from: 'operator', type: 'text', content: '真人公开回复', fingerprint: 94002,
        timestamp: baseline + 2000, automated: false },
      { session_id: humanSession, from: 'user', type: 'text', content: '人工前待处理问题', fingerprint: 94001, timestamp: baseline + 1000 },
    ]);
    await fx.runtime.catchup();
    const selected = await fx.runtime.scan();
    const humanKey = fx.runtime.stateKey(website, humanSession);
    const human = fx.runtime.readState(humanKey);
    assert.equal(human.mode, 'human');
    assert(selected.filter((entry) => entry.key === humanKey).every((entry) => entry.control),
      '真人已提交后不得调度同会话普通推理');
    const visitorJobs = human.jobs.filter((job) => !job.control);
    assert.equal(visitorJobs.length, 2);
    assert(visitorJobs.every((job) => ['cancelled', 'done'].includes(job.status) && job.data === undefined),
      '真人暂停必须取消/关闭前后的普通任务并释放正文');

    // 关闭总开关后补偿仍推进水位，否则重新开启时会把关闭期旧问题补发。
    fs.writeFileSync(path.join(fx.root, 'config', 'runtime.yaml'),
      JSON.stringify({ schema_version: 2, enabled: false, revision: 2, applied_revision: 2 }));
    fx.tick(16000);
    const offSession = 'session_catchup-off0001';
    fx.catchupConversationPages.set(1, [{ website_id: website, session_id: offSession, updated_at: fx.now() }]);
    fx.catchupMessages.set(offSession, [{ session_id: offSession, from: 'user', type: 'text',
      content: '总开关关闭期的问题', fingerprint: 94004, timestamp: fx.now() - 1000 }]);
    await fx.runtime.catchup();
    assert(!(await fx.runtime.scan()).some((entry) => entry.key === fx.runtime.stateKey(website, offSession)));
    const off = fx.runtime.readState(fx.runtime.stateKey(website, offSession));
    assert.equal(off.jobs.length, 1); assert.equal(off.jobs[0].status, 'done');
    fs.writeFileSync(path.join(fx.root, 'config', 'runtime.yaml'),
      JSON.stringify({ schema_version: 2, enabled: true, revision: 3, applied_revision: 3 }));
    fx.tick(16000);
    await fx.runtime.catchup();
    await fx.runtime.scan();
    assert.equal(fx.runtime.readState(fx.runtime.stateKey(website, offSession)).jobs.length, 1,
      '重新开启不得补答关闭期旧问题');
  });

  await test('REST 补偿单轮网络预算有界且重启继续游标，外部失败不阻本地队列', async () => {
    const fx = fixture('rest-catchup-budget-restart');
    await fx.runtime.catchup();
    const baseline = fx.now();
    fx.tick(16000);
    const sessions = Array.from({ length: 5 }, (_, index) => 'session_catchup-budget' + index);
    fx.catchupConversationPages.set(1, sessions.map((session, index) => ({ website_id: website,
      session_id: session, updated_at: baseline + 1000 + index })));
    for (const [index, session] of sessions.entries()) fx.catchupMessages.set(session, [{ session_id: session,
      from: 'user', type: 'text', content: '有界补偿问题 ' + index,
      fingerprint: 95000 + index, timestamp: baseline + 1000 + index }]);
    let beforeRequests = fx.catchupRequests.length;
    await fx.runtime.catchup();
    assert(fx.catchupRequests.length - beforeRequests <= 4,
      '单轮 REST 总预算不得超过一次会话列表加三次消息列表');
    assert.equal(fx.catchupRequests.slice(beforeRequests).filter((item) => item.type === 'messages').length, 3,
      '单轮不得超过消息 REST 请求预算');
    let progress = JSON.parse(fs.readFileSync(path.join(fx.runtimeDirectory, 'crisp-rest-catchup.json'), 'utf8'));
    assert(progress.window && progress.window.index >= 1 && progress.window.message,
      '未完成会话消息游标必须先持久再退出');
    beforeRequests = fx.catchupRequests.length;
    assert.equal((await fx.runtime.catchup()).status, 'idle');
    assert.equal(fx.catchupRequests.length, beforeRequests,
      '固定窗口未完成时也必须尊重 next_scan_at，不得被五秒 scheduler 放大请求');
    for (let round = 0; round < 4 && progress.window; round += 1) {
      fx.restart(); fx.tick(1001); beforeRequests = fx.catchupRequests.length;
      await fx.runtime.catchup();
      assert(fx.catchupRequests.slice(beforeRequests).filter((item) => item.type === 'messages').length <= 3);
      progress = JSON.parse(fs.readFileSync(path.join(fx.runtimeDirectory, 'crisp-rest-catchup.json'), 'utf8'));
    }
    assert.equal(progress.window, null);
    for (const session of sessions) {
      const state = fx.runtime.readState(fx.runtime.stateKey(website, session));
      assert.equal(state.jobs.length, 1); assert.equal(state.jobs[0].status, 'received');
    }

    const localSession = 'session_local-survives1';
    writeState(fx, localSession, stateValue(fx, localSession, [jobValue(fx, 'local-survives')]));
    fx.tick(16000);
    fx.catchupConversationPages.set(1, { malformed: true });
    const selected = await fx.runtime.scan();
    assert(selected.some((entry) => entry.key === fx.runtime.stateKey(website, localSession)),
      '补偿端点异常不得阻断已持久本地任务');

    // 真正挂起 REST 列表请求：catch-up 使用独立锁和执行路径，
    // 本地 scan 必须在它还未返回时立即选出已持久任务。
    fx.tick(16000);
    let releaseList;
    let listStartedResolve;
    const listStarted = new Promise((resolve) => { listStartedResolve = resolve; });
    const blockedList = new Promise((resolve) => { releaseList = resolve; });
    const originalRequest = fx.options.request;
    const blocked = createRuntime(env, { ...fx.options, request: async (url, options) => {
      if (/\/conversations\/[1-9][0-9]*(?:\?|$)/.test(url)) {
        listStartedResolve();
        return blockedList;
      }
      return originalRequest(url, options);
    } });
    const pendingCatchup = blocked.catchup();
    await Promise.race([listStarted, wait(500).then(() => { throw new Error('REST 挂起夹具未启动'); })]);
    const scanStarted = Date.now();
    const whileBlocked = await blocked.scan();
    assert(Date.now() - scanStarted < 500, '本地 scan 不得等待 REST 超时预算');
    assert(whileBlocked.some((entry) => entry.key === fx.runtime.stateKey(website, localSession)));
    releaseList({ status: 503, body: { error: true } });
    assert.equal((await pendingCatchup).status, 'warning');
  });

  await test('REST 消息有界分批逐批持久游标，预算用尽重启后继续且仅空批推到窗口末端', async () => {
    const fx = fixture('rest-catchup-message-batches', {
      catchupMessageBatchSize: 1, catchupMessageRequestBudget: 2,
    });
    await fx.runtime.catchup();
    const baseline = fx.now();
    const session = 'session_catchup-batches01';
    fx.tick(16000);
    fx.catchupConversationPages.set(1, [{ website_id: website, session_id: session, updated_at: fx.now() }]);
    fx.catchupMessages.set(session, [1, 2, 3].map((index) => ({ website_id: website, session_id: session,
      from: 'user', type: 'text', content: '分批漏收问题 ' + index,
      fingerprint: 95500 + index, timestamp: baseline + index * 1000,
    })));

    const firstRequest = fx.catchupRequests.length;
    await fx.runtime.catchup();
    assert.equal(fx.catchupRequests.slice(firstRequest).filter((item) => item.type === 'messages').length, 2);
    let progress = JSON.parse(fs.readFileSync(path.join(fx.runtimeDirectory, 'crisp-rest-catchup.json'), 'utf8'));
    assert.equal(progress.window.message.cursor, baseline + 2000,
      '第二批游标必须在预算用尽前原子落盘');
    assert.equal(fx.runtime.readState(fx.runtime.stateKey(website, session)).jobs.length, 2);
    assert.equal(fx.runtime.readState(fx.runtime.stateKey(website, session)).crisp_rest_catchup, undefined,
      '未观察到空批前不得过早宣告该会话已扫到窗口末端');

    fx.restart();
    const beforeDue = fx.catchupRequests.length;
    assert.equal((await fx.runtime.catchup()).status, 'idle');
    assert.equal(fx.catchupRequests.length, beforeDue);
    fx.tick(1001);
    await fx.runtime.catchup();
    progress = JSON.parse(fs.readFileSync(path.join(fx.runtimeDirectory, 'crisp-rest-catchup.json'), 'utf8'));
    const current = fx.runtime.readState(fx.runtime.stateKey(website, session));
    assert.equal(current.jobs.length, 3);
    assert.equal(progress.window, null);
    assert.equal(current.crisp_rest_catchup.cursor, progress.watermark,
      '只有后续严格空批确认后才把逐会话游标推到固定 window.end');
  });

  await test('REST 固定窗口中断超过旧五分钟后仍从原水位续扫，不用 now 滑窗遗忘消息', async () => {
    const fx = fixture('rest-catchup-fixed-window-over-five-minutes', { catchupMessageRequestBudget: 1 });
    const baseline = fx.now();
    assert.equal((await fx.runtime.catchup()).status, 'bootstrap');
    const sessions = ['session_catchup-old-window-a', 'session_catchup-old-window-b'];
    fx.tick(11 * 60 * 1000);
    fx.catchupConversationPages.set(1, sessions.map((session, index) => ({ website_id: website,
      session_id: session, updated_at: baseline + (index + 2) * 60000 })));
    for (const [index, session] of sessions.entries()) fx.catchupMessages.set(session, [{
      website_id: website, session_id: session, from: 'user', type: 'text',
      content: '跨旧滑窗的漏收问题 ' + index, fingerprint: 95530 + index,
      timestamp: baseline + (index + 1) * 60000,
    }]);

    await fx.runtime.catchup();
    const catchupFile = path.join(fx.runtimeDirectory, 'crisp-rest-catchup.json');
    let progress = JSON.parse(fs.readFileSync(catchupFile, 'utf8'));
    assert(progress.window, '有限预算必须留下可续做的固定窗口');
    const frozenEnd = progress.window.end;
    assert.equal(progress.watermark, baseline, '未完整覆盖前不得推进全局水位');
    assert(Date.parse(fx.catchupRequests.find((entry) => entry.type === 'conversations').start) <= baseline);

    // 模拟任务中断十一分钟并重建 runtime；此时消息都早于 now-5m，仍必须
    // 使用持久固定窗口，而不是从新的五分钟滑窗重新开始。
    fx.tick(11 * 60 * 1000);
    fx.restart();
    for (let round = 0; round < 8 && progress.window; round += 1) {
      await fx.runtime.catchup();
      progress = JSON.parse(fs.readFileSync(catchupFile, 'utf8'));
      if (progress.window) {
        assert.equal(progress.window.end, frozenEnd, '重启续扫不得把固定窗口上界改成当前时刻');
        fx.tick(1001);
      }
    }
    assert.equal(progress.window, null);
    assert.equal(progress.watermark, frozenEnd, '只允许在旧固定窗口完整覆盖后提交原上界');
    for (const [index, session] of sessions.entries()) {
      const current = fx.runtime.readState(fx.runtime.stateKey(website, session));
      assert.equal(current.jobs.filter((job) => job.data?.fingerprint === 95530 + index).length, 1,
        '跨旧五分钟窗口的每条消息必须且只能建立一份责任');
      assert.equal(current.crisp_rest_catchup.cursor, frozenEnd);
    }
  });

  await test('REST 多页会话排序变化不跳项，同 timestamp 消息均先持久再推进水位', async () => {
    const fx = fixture('rest-catchup-page-order-and-equal-time', { catchupMessageRequestBudget: 3 });
    const baseline = fx.now();
    await fx.runtime.catchup();
    fx.tick(16000);
    const sessions = Array.from({ length: 21 }, (_, index) => 'session_catchup-page-' + String(index).padStart(2, '0'));
    const conversations = sessions.map((session, index) => ({ website_id: website,
      session_id: session, updated_at: baseline + 1000 + index }));
    fx.catchupConversationPages.set(1, conversations.slice(0, 20));
    fx.catchupConversationPages.set(2, conversations.slice(20));
    const target = sessions[20];
    const sameTimestamp = baseline + 2000;
    fx.catchupMessages.set(target, [95541, 95542].map((fingerprint) => ({ website_id: website,
      session_id: target, from: 'user', type: 'text', content: '同一时间戳的独立问题 ' + fingerprint,
      fingerprint, timestamp: sameTimestamp })));

    const catchupFile = path.join(fx.runtimeDirectory, 'crisp-rest-catchup.json');
    let progress = null;
    for (let round = 0; round < 12; round += 1) {
      await fx.runtime.catchup();
      progress = JSON.parse(fs.readFileSync(catchupFile, 'utf8'));
      if (progress.window?.page === 2) break;
      fx.tick(1001);
    }
    assert(progress?.window && progress.window.page === 2 && progress.window.index === 0,
      '夹具必须在第二页请求前中断并持久分页位置');
    assert(!fx.catchupRequests.some((entry) => entry.type === 'conversations' && entry.page === 2),
      '中断点前不得已经读取目标页');
    const frozenEnd = progress.window.end;
    const oldWatermark = progress.watermark;

    // 固定窗口处理中，目标会话因新的 updated_at 排序从第二页移到第一页；
    // 只保存 page=2 再查询会跳过它。实现必须使用冻结身份/稳定游标或受控
    // 页重叠去重，不能因列表排序变化把水位直接推进到 end。
    const movedTarget = { ...conversations[20], updated_at: frozenEnd };
    fx.catchupConversationPages.set(1, [...conversations.slice(1, 20), movedTarget]);
    fx.catchupConversationPages.set(2, []);
    fx.tick(11 * 60 * 1000);
    fx.restart();
    for (let round = 0; round < 16 && progress.window; round += 1) {
      await fx.runtime.catchup();
      progress = JSON.parse(fs.readFileSync(catchupFile, 'utf8'));
      const targetState = fx.runtime.readState(fx.runtime.stateKey(website, target));
      if (!progress.window) assert.equal(targetState.jobs.length, 2,
        '分页排序变化中的目标消息未持久前绝不能宣告窗口完整');
      else {
        assert.equal(progress.watermark, oldWatermark, '未覆盖移动会话前不得推进全局水位');
        assert.equal(progress.window.end, frozenEnd);
        fx.tick(1001);
      }
    }
    const current = fx.runtime.readState(fx.runtime.stateKey(website, target));
    assert.deepEqual(current.jobs.map((job) => job.data?.fingerprint).filter(Boolean).sort(), [95541, 95542],
      '同一 timestamp 的不同 fingerprint 必须各自建立责任');
    assert.equal(new Set(current.jobs.map((job) => job.id)).size, 2, '分页重叠不得重复同一责任');
    assert.equal(progress.window, null);
    assert.equal(progress.watermark, frozenEnd);
    assert.equal(current.crisp_rest_catchup.cursor, frozenEnd);
  });

  await test('已存在但结构无效的 catchup 状态 fail closed，不覆盖为当前新水位', async () => {
    const fx = fixture('rest-catchup-invalid-existing-state');
    await fx.runtime.catchup();
    const catchupFile = path.join(fx.runtimeDirectory, 'crisp-rest-catchup.json');
    const valid = JSON.parse(fs.readFileSync(catchupFile, 'utf8'));
    assert.equal(valid.schema_version, 2);
    const malformed = { ...valid, watermark: 'invalid-watermark',
      last_result: { status: 'ok', at: fx.now(), recovered_messages: 0, checked_conversations: 0 } };
    const malformedBytes = Buffer.from(JSON.stringify(malformed));
    fs.writeFileSync(catchupFile, malformedBytes, { mode: 0o600 });
    fx.tick(11 * 60 * 1000);
    const beforeRequests = fx.catchupRequests.length;

    const result = await fx.runtime.catchup();
    assert.equal(result.status, 'warning');
    assert.equal(result.error_code, 'state_invalid');
    assert(fs.readFileSync(catchupFile).equals(malformedBytes),
      '结构无效的既存状态不得被 bootstrap 覆盖成 now，从而掩盖未知缺口');
    assert.equal(fx.catchupRequests.length, beforeRequests, '状态来源不可信时不得请求并提交新的覆盖水位');
  });

  await test('畸形 catchup 消息持久隔离且不阻塞其它会话，严格 exact 恢复后才清除责任', async () => {
    const fx = fixture('rest-catchup-message-quarantine');
    assert.equal((await fx.runtime.catchup()).status, 'bootstrap');
    const baseline = fx.now();
    fx.tick(2000);
    const badSession = 'session_catchup-bad-user';
    const goodSession = 'session_catchup-good-user';
    const badFingerprint = 62001;
    const goodFingerprint = 62002;
    fx.catchupConversationPages.set(1, [badSession, goodSession].map((session) => ({
      website_id: website, session_id: session, updated_at: fx.now(),
    })));
    const badMessage = { website_id: website, session_id: badSession,
      from: 'user', type: 'text', content: null, fingerprint: badFingerprint, timestamp: fx.now() };
    fx.catchupMessages.set(badSession, [badMessage, { ...badMessage, origin: 'chat' }]);
    fx.catchupMessages.set(goodSession, [{ website_id: website, session_id: goodSession,
      from: 'user', type: 'text', content: '其它会话的有效问题', fingerprint: goodFingerprint, timestamp: fx.now() }]);
    await fx.runtime.catchup();
    const catchupFile = path.join(fx.runtimeDirectory, 'crisp-rest-catchup.json');
    let progress = JSON.parse(fs.readFileSync(catchupFile, 'utf8'));
    assert.equal(progress.unresolved_messages.length, 1);
    assert.equal(progress.unresolved_messages[0].session_id, badSession);
    assert.equal(progress.unresolved_messages[0].fingerprint, String(badFingerprint));
    assert.equal(progress.unresolved_messages[0].occurrences, 2,
      '同一 fingerprint 的元数据变化必须收敛为同一条持久责任');
    assert.equal(progress.unresolved_messages[0].window_start, baseline);
    assert(!fs.readFileSync(catchupFile, 'utf8').includes('其它会话的有效问题'));
    const goodState = fx.runtime.readState(fx.runtime.stateKey(website, goodSession));
    assert(goodState.jobs.some((job) => String(job.data?.fingerprint) === String(goodFingerprint)),
      '单条畸形消息不得阻断其它会话的本地应答责任');
    await fx.runtime.scan();
    const health = JSON.parse(fs.readFileSync(path.join(fx.runtimeDirectory, 'scheduler-health.json'), 'utf8'));
    assert.equal(health.crisp_rest_catchup.status, 'warning');
    assert.equal(health.crisp_rest_catchup.unresolved_messages, 1);
    assert.equal(health.crisp_rest_catchup.unresolved_since, baseline);

    fx.exactMessages.set(String(badFingerprint), { website_id: website,
      session_id: 'session_wrong-exact', from: 'user', type: 'text', content: '错误会话',
      fingerprint: badFingerprint, timestamp: fx.now() });
    // 普通 history 中同 fingerprint 但 from/type 已改变的项不能替代精确
    // 消息端点解除原 quarantine；旧实现会在 receive 后按 ID 直接删除。
    fx.catchupMessages.set(badSession, [{ website_id: website, session_id: badSession,
      from: 'user', type: 'file', content: 'https://example.invalid/changed-kind',
      fingerprint: badFingerprint, timestamp: fx.now() }]);
    fx.tick(60001);
    const beforeMalformed = fx.catchupRequests.filter((entry) => entry.type === 'messages').length;
    await fx.runtime.catchup();
    progress = JSON.parse(fs.readFileSync(catchupFile, 'utf8'));
    assert.equal(progress.unresolved_messages.length, 1,
      '畸形 HTTP 200 exact 及普通 history 身份变化均不能删除未解决责任');
    assert.equal(progress.unresolved_messages[0].from, 'user');
    assert.equal(progress.unresolved_messages[0].type, 'text');
    assert(fx.catchupRequests.filter((entry) => entry.type === 'messages').length - beforeMalformed <= 2,
      'exact 恢复请求必须计入单轮三次消息 REST 预算');

    const durableContent = '已持久但与首次精确结果不同的合成问题';
    const duplicate = await webhook(fx, badSession, durableContent, badFingerprint, { timestamp: fx.now() });
    assert.equal(duplicate.statusCode, 200);
    const mismatchedExact = { website_id: website, session_id: badSession, from: 'user', type: 'text',
      content: '同 fingerprint 的另一份正文', fingerprint: badFingerprint, timestamp: fx.now() };
    fx.exactMessages.set(String(badFingerprint), mismatchedExact);
    fx.tick(120001);
    await fx.runtime.catchup();
    progress = JSON.parse(fs.readFileSync(catchupFile, 'utf8'));
    assert.equal(progress.unresolved_messages.length, 1,
      'receive 返回重复 200 但 durable identity 不同，不能解除 quarantine');

    const storedResponsibility = fx.runtime.readState(fx.runtime.stateKey(website, badSession))
      .jobs.find((job) => job.id === duplicate.jobId);
    const resolvedMessage = { website_id: website, session_id: badSession, from: 'user', type: 'text',
      content: durableContent, fingerprint: badFingerprint, timestamp: storedResponsibility.event_time };
    fx.exactMessages.set(String(badFingerprint), resolvedMessage);
    fx.catchupMessages.set(badSession, [resolvedMessage]);
    fx.tick(240001);
    await fx.runtime.catchup();
    progress = JSON.parse(fs.readFileSync(catchupFile, 'utf8'));
    assert.equal(progress.unresolved_messages.length, 0);
    const recovered = fx.runtime.readState(fx.runtime.stateKey(website, badSession));
    assert(recovered.jobs.some((job) => String(job.data?.fingerprint) === String(badFingerprint)),
      '必须先建立真实会话应答责任，再清除 quarantine');
  });

  await test('畸形 operator catchup 建立会话屏障，精确确认为自动消息后才释放访客', async () => {
    const fx = fixture('rest-catchup-operator-quarantine');
    await fx.runtime.catchup();
    fx.tick(2000);
    const session = 'session_catchup-bad-operator';
    const fingerprint = 62101;
    const malformed = { website_id: website, session_id: session, from: 'operator', type: 'text',
      content: null, fingerprint, timestamp: fx.now() };
    fx.catchupConversationPages.set(1, [{ website_id: website, session_id: session, updated_at: fx.now() }]);
    fx.catchupMessages.set(session, [malformed]);
    await fx.runtime.catchup();
    let current = fx.runtime.readState(fx.runtime.stateKey(website, session));
    assert.equal(current.uncertain_events.length, 1);
    assert.equal(current.jobs.find((job) => job.catchup_unresolved_id)?.failure_code, 'catchup_message_invalid');
    const visitor = await webhook(fx, session, '人工归属待核查期间的新问题', 62102);
    assert.equal(visitor.route, 'ignore');
    assert.equal(fx.runtime.readState(visitor.key).jobs.find((job) => job.id === visitor.jobId).deferred_control, true);

    const exact = { ...malformed, content: '本项目自动消息', automated: true };
    fx.exactMessages.set(String(fingerprint), exact);
    fx.catchupMessages.set(session, [exact]);
    fx.tick(60001);
    await fx.runtime.catchup();
    current = fx.runtime.readState(visitor.key);
    assert.deepEqual(current.uncertain_events, []);
    assert.equal(current.jobs.find((job) => job.id === visitor.jobId).deferred_control, undefined);
    assert.equal(current.mode, 'ai');
  });

  await test('REST text 内容必须是非空字符串，对象正文先隔离再按精确消息恢复', async () => {
    const fx = fixture('rest-catchup-text-content-type');
    await fx.runtime.catchup();
    fx.tick(2000);
    const session = 'session_catchup-text-object';
    const fingerprint = 62151;
    const invalid = { website_id: website, session_id: session, from: 'user', type: 'text',
      content: { text: '错误结构' }, fingerprint, timestamp: fx.now() };
    fx.catchupConversationPages.set(1, [{ website_id: website, session_id: session, updated_at: fx.now() }]);
    fx.catchupMessages.set(session, [invalid]);
    await fx.runtime.catchup();
    const catchupFile = path.join(fx.runtimeDirectory, 'crisp-rest-catchup.json');
    let progress = JSON.parse(fs.readFileSync(catchupFile, 'utf8'));
    assert.equal(progress.unresolved_messages.length, 1);
    assert.equal(progress.unresolved_messages[0].reason, 'invalid_content');
    assert(!fs.existsSync(stateFile(fx, session)), '错误 text 结构不能进入知识或 Provider 责任链');

    const valid = { ...invalid, content: '精确端点恢复出的合法合成问题' };
    fx.exactMessages.set(String(fingerprint), valid);
    fx.catchupMessages.set(session, [valid]);
    fx.tick(60001);
    await fx.runtime.catchup();
    progress = JSON.parse(fs.readFileSync(catchupFile, 'utf8'));
    assert.equal(progress.unresolved_messages.length, 0);
    const current = fx.runtime.readState(fx.runtime.stateKey(website, session));
    assert.equal(current.jobs.length, 1);
    assert.equal(current.jobs[0].responsibility_status, 'pending');
    assert.equal(current.jobs[0].data.content, valid.content);
  });

  await test('REST 结构消息逐类型校验，畸形对象只能进入持久 quarantine', async () => {
    const fx = fixture('rest-catchup-structured-content');
    assert.equal((await fx.runtime.catchup()).status, 'bootstrap');
    fx.tick(2000);
    const session = 'session_catchup-structured';
    const malformed = [
      { type: 'file', content: { type: 'image/png', url: 'https://example.invalid/file' } },
      { type: 'animation', content: { type: 'image/gif', url: 7 } },
      { type: 'audio', content: { type: 'audio/ogg', url: 'https://example.invalid/audio', duration: '3' } },
      { type: 'picker', content: { id: 'picker-1', text: '请选择', choices: [{ value: 'one' }] } },
      { type: 'field', content: { id: 'field-1', text: '请输入', value: '' } },
      { type: 'carousel', content: { text: '请选择', targets: [{ title: '选项', description: '' }] } },
    ].map((entry, index) => ({ website_id: website, session_id: session, from: 'user',
      fingerprint: 62200 + index, timestamp: fx.now(), ...entry }));
    fx.catchupConversationPages.set(1, [{ website_id: website, session_id: session,
      updated_at: fx.now() }]);
    fx.catchupMessages.set(session, malformed);
    const result = await fx.runtime.catchup();
    assert.equal(result.status, 'warning');
    const catchup = JSON.parse(fs.readFileSync(path.join(fx.runtimeDirectory,
      'crisp-rest-catchup.json'), 'utf8'));
    assert.equal(catchup.unresolved_messages.length, malformed.length);
    assert.deepEqual(new Set(catchup.unresolved_messages.map((entry) => entry.reason)),
      new Set(['invalid_content']));
    assert(!fs.existsSync(stateFile(fx, session)),
      '畸形结构消息不得绕过 quarantine 进入业务责任或 Provider');
  });

  await test('REST 补偿内部接收 400/413 时不推进任何水位并报告本地持久失败', async () => {
    for (const variant of ['invalid_after_validation', 'too_large']) {
      const fx = fixture('rest-catchup-local-persistence-' + variant);
      const baseline = fx.now();
      assert.equal((await fx.runtime.catchup()).status, 'bootstrap');
      const catchupFile = path.join(fx.runtimeDirectory, 'crisp-rest-catchup.json');
      const session = variant === 'too_large'
        ? 'session_catchup-local413' : 'session_catchup-local400';

      // 先经真实空批建立逐会话水位，后续只比较 runtime 自己写出的结构，
      // 不在测试里复制或写死任一 catchup schema。
      fx.tick(2000);
      fx.catchupConversationPages.set(1, [{ website_id: website, session_id: session,
        updated_at: baseline + 1000 }]);
      fx.catchupMessages.set(session, []);
      await fx.runtime.catchup();
      const covered = JSON.parse(fs.readFileSync(catchupFile, 'utf8'));
      assert.equal(covered.window, null);
      const coveredWatermark = covered.watermark;
      const coveredConversation = fx.runtime.readState(fx.runtime.stateKey(website, session));
      const coveredCursor = coveredConversation.crisp_rest_catchup.cursor;
      assert.equal(coveredCursor, coveredWatermark);

      fx.tick(16000);
      let clockRewound = false;
      const content = variant === 'too_large' ? 'x'.repeat(263000) : {
        // catchupMessage 已完成结构校验后，在内部 receive 计算请求字节时模拟
        // 本机时钟突然回拨，使同一个候选被 receive 以 400 拒绝。
        toJSON() {
          if (!clockRewound) { fx.tick(-120000); clockRewound = true; }
          return { text: '受控时间边界消息' };
        },
      };
      fx.catchupConversationPages.set(1, [{ website_id: website, session_id: session,
        updated_at: coveredWatermark + 1000 }]);
      fx.catchupMessages.set(session, [{ website_id: website, session_id: session,
        from: 'user', type: 'text', content, fingerprint: variant === 'too_large' ? 95514 : 95513,
        timestamp: coveredWatermark + 1000 }]);

      const result = await fx.runtime.catchup();
      if (clockRewound) fx.tick(120000);
      assert.equal(result.status, 'warning');
      assert.equal(result.error_code, 'local_persistence_failed');
      const progress = JSON.parse(fs.readFileSync(catchupFile, 'utf8'));
      assert.equal(progress.watermark, coveredWatermark, '内部接收失败不得推进全局水位');
      assert(progress.window, '失败窗口必须持久保留供恢复');
      assert.equal(progress.window.index, 0);
      assert.equal(progress.window.message.session_id, session);
      assert.equal(progress.window.message.cursor, coveredCursor, '失败候选不得推进窗口内会话游标');
      assert.equal(progress.last_result.status, 'warning');
      assert.equal(progress.last_result.error_code, 'local_persistence_failed');
      const conversation = fx.runtime.readState(fx.runtime.stateKey(website, session));
      assert.equal(conversation.crisp_rest_catchup.cursor, coveredCursor,
        '内部接收失败不得提交 per-conversation 已覆盖水位');
      assert.equal(conversation.jobs.length, 0, '未持久成功的候选不得伪造本地 job');
      if (variant === 'invalid_after_validation') assert.equal(clockRewound, true,
        '400 夹具必须真实经过内部 receive 的时间校验');

      // 修复本地校验条件后，同一 fingerprint 必须仍可从原固定窗口摄入；
      // 这证明先前 400/413 没有被当作 ACK 或已覆盖事实。
      if (variant === 'too_large') fx.catchupMessages.get(session)[0].content = '恢复后的受控可持久正文';
      fx.tick(1001);
      await fx.runtime.catchup();
      const recovered = fx.runtime.readState(fx.runtime.stateKey(website, session));
      const fingerprint = variant === 'too_large' ? 95514 : 95513;
      assert.equal(recovered.jobs.filter((job) => job.data?.fingerprint === fingerprint).length, 1,
        '本地条件恢复后只能建立一份原候选责任');
      assert.equal(recovered.jobs.find((job) => job.data?.fingerprint === fingerprint).status, 'received');
    }
  });

  await test('Crisp 420/429 均限流退避且保留固定补偿窗口和水位', async () => {
    for (const status of [420, 429]) {
      const fx = fixture('rest-catchup-rate-limit-' + status, { catchupMessageRequestBudget: 1 });
      const baseline = fx.now();
      await fx.runtime.catchup();
      fx.tick(16000);
      const sessions = ['session_catchup-rate-a' + status, 'session_catchup-rate-b' + status];
      fx.catchupConversationPages.set(1, sessions.map((session, index) => ({ website_id: website,
        session_id: session, updated_at: baseline + 1000 + index })));
      for (const [index, session] of sessions.entries()) fx.catchupMessages.set(session, [{
        website_id: website, session_id: session, from: 'user', type: 'text',
        content: '限流窗口中的消息', fingerprint: status * 100 + index,
        timestamp: baseline + 1000 + index,
      }]);
      await fx.runtime.catchup();
      const catchupFile = path.join(fx.runtimeDirectory, 'crisp-rest-catchup.json');
      const before = JSON.parse(fs.readFileSync(catchupFile, 'utf8'));
      assert(before.window, '限流前必须先形成一个未完成固定窗口');
      const responsibilityBefore = sessions.map((session) => {
        const current = fx.runtime.readState(fx.runtime.stateKey(website, session));
        return { session, cursor: current.crisp_rest_catchup?.cursor ?? null,
          fingerprints: current.jobs.map((job) => job.data?.fingerprint).filter(Boolean) };
      });

      fx.tick(1001);
      const originalRequest = fx.options.request;
      const limited = createRuntime(env, { ...fx.options, request: async (url, options) => {
        if (/\/conversations\/[1-9][0-9]*(?:\?|$)/.test(url)) return {
          status, headers: { 'retry-after': '60' }, body: { error: true, reason: 'rate_limited' },
        };
        return originalRequest(url, options);
      } });
      const result = await limited.catchup();
      assert.equal(result.status, 'warning');
      assert.equal(result.error_code, 'rate_limited');
      const after = JSON.parse(fs.readFileSync(catchupFile, 'utf8'));
      assert.equal(after.watermark, before.watermark, status + ' 不得推进全局水位');
      assert.deepEqual(after.window, before.window, status + ' 不得丢弃未完成窗口/游标');
      assert(after.next_scan_at >= fx.now() + 60000, status + ' 必须有界退避而非快速轮询');
      assert.equal(after.last_result.status, 'warning');
      assert.equal(after.last_result.error_code, 'rate_limited');
      const responsibilityAfter = sessions.map((session) => {
        const current = fx.runtime.readState(fx.runtime.stateKey(website, session));
        return { session, cursor: current.crisp_rest_catchup?.cursor ?? null,
          fingerprints: current.jobs.map((job) => job.data?.fingerprint).filter(Boolean) };
      });
      assert.deepEqual(responsibilityAfter, responsibilityBefore,
        status + ' 限流轮不得把未检查候选伪装成本地已接收或已覆盖');
    }
  });

  await test('本机时钟回拨不把补偿水位重置到当前时刻，受控重放后安全收敛', async () => {
    const fx = fixture('rest-catchup-clock-rewind', { catchupMessageRequestBudget: 1 });
    const baseline = fx.now();
    await fx.runtime.catchup();
    fx.tick(16000);
    const sessions = ['session_catchup-clock-a', 'session_catchup-clock-b'];
    fx.catchupConversationPages.set(1, sessions.map((session, index) => ({ website_id: website,
      session_id: session, updated_at: baseline + 1000 + index })));
    for (const [index, session] of sessions.entries()) fx.catchupMessages.set(session, [{
      website_id: website, session_id: session, from: 'user', type: 'text',
      content: '时钟回拨窗口中的消息', fingerprint: 95520 + index,
      timestamp: baseline + 1000 + index,
    }]);
    await fx.runtime.catchup();
    const catchupFile = path.join(fx.runtimeDirectory, 'crisp-rest-catchup.json');
    const before = JSON.parse(fs.readFileSync(catchupFile, 'utf8'));
    assert(before.window, '回拨前必须保留尚未完整覆盖的固定窗口');
    const frozenEnd = before.window.end;

    fx.tick(-120000);
    const rewoundNow = fx.now();
    const rewound = await fx.runtime.catchup();
    assert.equal(rewound.status, 'warning');
    assert.equal(rewound.error_code, 'clock_rewound');
    let progress = JSON.parse(fs.readFileSync(catchupFile, 'utf8'));
    assert.equal(progress.watermark, before.watermark,
      '本机回拨不能把已持久水位重置为较新的 now 并丢失旧窗口');
    assert.notEqual(progress.watermark, rewoundNow);
    assert.equal(progress.window.clock_rewind_recovery, true);
    assert.equal(progress.window.end, frozenEnd, '回拨恢复必须固定原覆盖上界');

    fx.tick(120000);
    for (let round = 0; round < 12 && progress.window; round += 1) {
      await fx.runtime.catchup();
      progress = JSON.parse(fs.readFileSync(catchupFile, 'utf8'));
      if (progress.window) fx.tick(1001);
    }
    assert.equal(progress.window, null, '受控重放应能完成而不是永久卡住回拨窗口');
    assert.equal(progress.watermark, frozenEnd);
    assert(progress.watermark >= before.watermark);
    for (const [index, session] of sessions.entries()) {
      const current = fx.runtime.readState(fx.runtime.stateKey(website, session));
      assert.equal(current.jobs.filter((job) => job.data?.fingerprint === 95520 + index).length, 1,
        '回拨重放只能持久一份相同消息责任');
      assert.equal(current.crisp_rest_catchup.cursor, frozenEnd,
        '完整重放后 per-conversation 水位必须安全恢复到固定上界');
    }
  });

  await test('回拨恢复在当前时钟仍早于业务接入水位时完成也不会写坏状态', async () => {
    const fx = fixture('rest-catchup-clock-rewind-before-bootstrap', { catchupMessageRequestBudget: 1 });
    const baseline = fx.now();
    await fx.runtime.catchup();
    const catchupFile = path.join(fx.runtimeDirectory, 'crisp-rest-catchup.json');
    fx.tick(-120000);
    const rewound = await fx.runtime.catchup();
    assert.equal(rewound.error_code, 'clock_rewound');
    fx.catchupConversationPages.set(1, []);
    fx.tick(1001);
    await fx.runtime.catchup();
    const progress = JSON.parse(fs.readFileSync(catchupFile, 'utf8'));
    assert.equal(progress.window, null);
    assert.equal(progress.bootstrapped_at, baseline);
    assert(progress.watermark >= progress.bootstrapped_at,
      '回拨窗口完成时的安全水位不能低于首次业务接入水位');
    fx.restart();
    assert.notEqual((await fx.runtime.catchup()).error_code, 'state_invalid',
      '重启后必须能够继续读取回拨恢复写出的状态');
  });

  await test('补偿 REST 的 24 小时预算跨重启持久并为正文与控制保留站点配额', async () => {
    const fx = fixture('rest-catchup-persistent-daily-budget', {
      catchupMessageRequestBudget: 3, catchupDailyRequestBudget: 4,
    });
    await fx.runtime.catchup();
    fx.tick(2000);
    const sessions = Array.from({ length: 5 }, (_, index) => 'session_catchup-daily-' + index);
    fx.catchupConversationPages.set(1, sessions.map((session) => ({ website_id: website,
      session_id: session, updated_at: fx.now() })));
    for (const [index, session] of sessions.entries()) fx.catchupMessages.set(session, [{
      website_id: website, session_id: session, from: 'user', type: 'text',
      content: '预算内持久消息', fingerprint: 95600 + index, timestamp: fx.now(),
    }]);
    const before = fx.catchupRequests.length;
    await fx.runtime.catchup();
    assert.equal(fx.catchupRequests.length - before, 4,
      '单轮必须精确记入一次列表和三次消息请求');
    const catchupFile = path.join(fx.runtimeDirectory, 'crisp-rest-catchup.json');
    let progress = JSON.parse(fs.readFileSync(catchupFile, 'utf8'));
    assert.equal(progress.rest_budget.used, 4);
    assert.equal(progress.rest_budget.limit, 4);
    const protectedProgress = JSON.stringify({ watermark: progress.watermark, window: progress.window });
    fx.tick(1001);
    const exhausted = await fx.runtime.catchup();
    assert.equal(exhausted.error_code, 'daily_budget_exhausted');
    assert.equal(fx.catchupRequests.length - before, 4, '预算耗尽后不得再发补偿 REST');
    progress = JSON.parse(fs.readFileSync(catchupFile, 'utf8'));
    assert.equal(JSON.stringify({ watermark: progress.watermark, window: progress.window }), protectedProgress,
      '预算暂停不得推进未覆盖水位或丢弃固定窗口');
    await fx.runtime.scan();
    let health = JSON.parse(fs.readFileSync(
      path.join(fx.runtimeDirectory, 'scheduler-health.json'), 'utf8')).crisp_rest_catchup;
    assert.equal(health.request_budget_used, 4);
    assert.equal(health.request_budget_limit, 4);
    assert.equal(health.error_code, 'daily_budget_exhausted');
    fx.restart();
    const afterRestart = fx.catchupRequests.length;
    await fx.runtime.catchup();
    assert.equal(fx.catchupRequests.length, afterRestart,
      '重启不能重置预算后立即继续消耗站点 REST 配额');
    fx.tick(progress.rest_budget.reset_at - fx.now() + 1);
    await fx.runtime.catchup();
    assert(fx.catchupRequests.length > afterRestart, '完整 24 小时周期后才可恢复补偿请求');
    await fx.runtime.scan();
    health = JSON.parse(fs.readFileSync(
      path.join(fx.runtimeDirectory, 'scheduler-health.json'), 'utf8')).crisp_rest_catchup;
    assert(health.request_budget_used > 0 && health.request_budget_used <= 4);
  });

  await test('REST 历史缺失或损坏 timestamp 先持久责任并精确核验，再区分旧消息与新访客/真人', async () => {
    const cases = [
      { name: 'old-visitor-missing', from: 'user', fingerprint: 95561, timestamp: undefined,
        exactOffset: -1000, expected: 'old' },
      { name: 'old-operator-invalid', from: 'operator', automated: false, fingerprint: 95562,
        timestamp: 'broken-timestamp', exactOffset: -1000, expected: 'old' },
      { name: 'new-visitor-invalid', from: 'user', fingerprint: 95563,
        timestamp: 'not-a-time', exactOffset: 1000, expected: 'visitor' },
      { name: 'new-operator-missing', from: 'operator', automated: false, fingerprint: 95564,
        timestamp: undefined, exactOffset: 1000, expected: 'human' },
    ];
    for (const item of cases) {
      const fx = fixture('rest-catchup-unverified-time-' + item.name);
      const baseline = fx.now();
      assert.equal((await fx.runtime.catchup()).status, 'bootstrap');
      const catchupFile = path.join(fx.runtimeDirectory, 'crisp-rest-catchup.json');
      const session = 'session_catchup-time-' + item.name;
      fx.tick(16000);
      fx.catchupConversationPages.set(1, [{ website_id: website, session_id: session,
        updated_at: fx.now() }]);
      const history = { website_id: website, session_id: session, from: item.from, type: 'text',
        content: '受控无可信时间消息', fingerprint: item.fingerprint };
      if (item.automated !== undefined) history.automated = item.automated;
      if (item.timestamp !== undefined) history.timestamp = item.timestamp;
      fx.catchupMessages.set(session, [history]);
      fx.exactMessages.set(String(item.fingerprint), { status: 503 });

      const first = await fx.runtime.catchup();
      assert.equal(first.status, 'warning');
      assert.equal(first.error_code, 'event_time_pending');
      let progress = JSON.parse(fs.readFileSync(catchupFile, 'utf8'));
      const frozenEnd = progress.window?.end;
      assert(Number.isFinite(frozenEnd));
      assert.equal(progress.watermark, baseline, '精确时间确认前不得推进全局水位');
      assert.equal(progress.last_result.error_code, 'event_time_pending');
      const key = fx.runtime.stateKey(website, session);
      let current = fx.runtime.readState(key);
      let stored = current.jobs.find((job) => job.data?.fingerprint === item.fingerprint);
      assert(stored, 'REST history 的无可信时间消息必须先建立本地持久责任');
      assert.equal(stored.status, 'received');
      assert.equal(stored.event_time_unverified, true);
      assert.equal(stored.catchup_bootstrapped_at_receive, baseline,
        '任务必须冻结接入水位，不能稍后用本机 now 猜新旧');
      assert.equal(current.mode, 'ai', '真人时间未核实前不能用本机收件时间立即暂停');
      assert.equal(fx.postAttempts.length, 0);

      const unresolved = await fx.runtime.process(key, stored.id);
      assert(['deferred', 'unresolved'].includes(unresolved.status));
      current = fx.runtime.readState(key);
      stored = current.jobs.find((job) => job.id === stored.id);
      assert.equal(stored.status, 'received');
      assert.equal(stored.responsibility_status, 'unresolved_failure');
      assert.equal(stored.failure_code, 'event_time_crisp_unavailable');
      assert(stored.data, '精确端点暂不可用时不得删除访客/真人原始责任');
      assert(fx.exactRequests.includes(String(item.fingerprint)));

      // 即使补偿调度再次运行，也不能越过尚未确认的新旧边界。
      fx.tick(1001);
      const stillPending = await fx.runtime.catchup();
      assert.equal(stillPending.status, 'warning');
      assert.equal(stillPending.error_code, 'event_time_pending');
      progress = JSON.parse(fs.readFileSync(catchupFile, 'utf8'));
      assert.equal(progress.watermark, baseline);
      assert.equal(progress.window.end, frozenEnd);
      assert.equal(fx.runtime.readState(key).jobs.filter((job) => job.id === stored.id).length, 1,
        '重扫同一无可信时间 fingerprint 不得重复建立责任');

      const exactTime = baseline + item.exactOffset;
      fx.exactMessages.set(String(item.fingerprint), { website_id: website, session_id: session,
        from: item.from, type: 'text', content: history.content, fingerprint: item.fingerprint,
        timestamp: exactTime, ...(item.automated === undefined ? {} : { automated: item.automated }) });
      if (item.expected === 'visitor') {
        fs.writeFileSync(path.join(fx.root, 'config', 'provider-pool-transaction.json'), '{}', { mode: 0o600 });
      }
      current = fx.runtime.readState(key);
      stored = current.jobs.find((job) => job.id === stored.id);
      if (stored.retry_at > fx.now()) fx.tick(stored.retry_at - fx.now() + 1);
      const resolved = await fx.runtime.process(key, stored.id);
      current = fx.runtime.readState(key);
      stored = current.jobs.find((job) => job.id === stored.id);
      assert.equal(stored.event_time, exactTime);
      assert.equal(stored.event_time_source, 'crisp_exact');
      assert.equal(stored.event_time_unverified, undefined);
      if (item.expected === 'old') {
        assert(['discarded', 'cancelled'].includes(resolved.status));
        assert.equal(current.mode, 'ai');
        assert.equal(stored.status, 'done');
        assert(['intentional_silence', 'control_handled'].includes(stored.responsibility_status));
        assert.equal(stored.responsibility_reason, 'before_catchup_bootstrap');
      } else if (item.expected === 'visitor') {
        assert.equal(resolved.status, 'deferred');
        assert.equal(current.mode, 'ai');
        assert.equal(stored.status, 'received');
        assert(stored.data, '真正新访客在配置暂不可用时仍保留原问题');
        assert.notEqual(stored.responsibility_status, 'intentional_silence');
      } else {
        assert.equal(current.mode, 'human');
        assert.equal(current.pause_reason, 'operator_reply');
        assert.equal(current.last_human_at, exactTime);
        assert.equal(stored.status, 'done');
        assert.equal(stored.responsibility_status, 'control_handled');
      }
      assert.equal(fx.postAttempts.length, 0, '时间确认流程不得向访客产生任何消息');

      // 精确结果落盘后，原固定窗口才可安全完成；history 持续返回损坏
      // timestamp 也必须复用同一责任，不能永久卡住或生成第二条 job。
      progress = JSON.parse(fs.readFileSync(catchupFile, 'utf8'));
      for (let round = 0; round < 8 && progress.window; round += 1) {
        fx.tick(1001);
        await fx.runtime.catchup();
        progress = JSON.parse(fs.readFileSync(catchupFile, 'utf8'));
      }
      assert.equal(progress.window, null);
      assert.equal(progress.watermark, frozenEnd);
      assert.equal(fx.runtime.readState(key).jobs.filter((job) => job.id === stored.id).length, 1);
    }
  });

  await test('REST 重叠窗口迟到发现的上线后消息不被滚动扫描水位误判为接入前历史', async () => {
    const fx = fixture('rest-catchup-overlap-business-watermark');
    const baseline = fx.now();
    assert.equal((await fx.runtime.catchup()).status, 'bootstrap');
    const catchupFile = path.join(fx.runtimeDirectory, 'crisp-rest-catchup.json');
    fx.tick(20000);
    const progress = JSON.parse(fs.readFileSync(catchupFile, 'utf8'));
    progress.watermark = baseline + 10000;
    progress.next_scan_at = fx.now();
    fs.writeFileSync(catchupFile, JSON.stringify(progress), { mode: 0o600 });

    const session = 'session_catchup-overlap-late';
    const fingerprint = 95601;
    fx.catchupConversationPages.set(1, [{ website_id: website, session_id: session,
      updated_at: fx.now() }]);
    fx.catchupMessages.set(session, [{ website_id: website, session_id: session,
      from: 'user', type: 'text', content: '上线后迟到可见的问题', fingerprint }]);
    const first = await fx.runtime.catchup();
    assert.equal(first.status, 'warning');
    assert.equal(first.error_code, 'event_time_pending');
    const key = fx.runtime.stateKey(website, session);
    let stored = fx.runtime.readState(key).jobs.find((job) => job.data?.fingerprint === fingerprint);
    assert(stored);
    assert.equal(stored.catchup_bootstrapped_at_receive, baseline,
      '任务必须绑定首次业务接入水位，而不是较新的滚动扫描水位');
    assert.equal(stored.catchup_watermark_at_receive, undefined);

    const exactTime = baseline + 5000;
    fx.exactMessages.set(String(fingerprint), { website_id: website, session_id: session,
      from: 'user', type: 'text', content: '上线后迟到可见的问题', fingerprint, timestamp: exactTime });
    fs.writeFileSync(path.join(fx.root, 'config', 'provider-pool-transaction.json'), '{}', { mode: 0o600 });
    const resolved = await fx.runtime.process(key, stored.id);
    assert.equal(resolved.status, 'deferred');
    stored = fx.runtime.readState(key).jobs.find((job) => job.id === stored.id);
    assert.equal(stored.event_time, exactTime);
    assert.equal(stored.event_time_source, 'crisp_exact');
    assert.notEqual(stored.status, 'done');
    assert.notEqual(stored.responsibility_status, 'intentional_silence');
    assert(stored.data, '迟到可见但上线后的原始问题必须继续保留应答责任');
    assert.equal(fx.postAttempts.length, 0);
  });

  await test('布尔、数组和对象 timestamp 不得伪装成1970时间，必须按精确身份与时间处理', async () => {
    const malformedValues = [true, [1760000000], { value: 1760000000 }];
    for (let index = 0; index < malformedValues.length; index += 1) {
      for (const from of ['user', 'operator']) {
        const fx = fixture('strict-event-time-' + index + '-' + from);
        const session = 'session_strict-time-' + index + '-' + from;
        const fingerprint = 95620 + index * 10 + (from === 'operator' ? 1 : 0);
        const accepted = await webhook(fx, session, '受控事件正文', fingerprint, {
          event: from === 'operator' ? 'message:received' : 'message:send', from,
          automated: from === 'operator' ? false : undefined, timestamp: malformedValues[index],
        });
        assert.equal(accepted.statusCode, 200);
        let stored = fx.runtime.readState(accepted.key).jobs.find((job) => job.id === accepted.jobId);
        assert.equal(stored.event_time_unverified, true,
          '非标量 timestamp 必须进入精确回查，不能经 Number() 变成历史时间');
        assert.notEqual(stored.event_time, 1000);
        fx.exactMessages.set(String(fingerprint), { website_id: website, session_id: session,
          from, type: 'text', content: '受控事件正文', fingerprint, timestamp: fx.now(),
          ...(from === 'operator' ? { automated: false } : {}) });
        if (from === 'user') fs.writeFileSync(path.join(fx.root, 'config', 'provider-pool-transaction.json'), '{}', { mode: 0o600 });
        const result = await fx.runtime.process(accepted.key, accepted.jobId);
        stored = fx.runtime.readState(accepted.key).jobs.find((job) => job.id === accepted.jobId);
        assert.equal(stored.event_time_source, 'crisp_exact');
        assert.equal(stored.event_time_unverified, undefined);
        if (from === 'operator') {
          assert.equal(fx.runtime.readState(accepted.key).mode, 'human');
          assert.equal(stored.responsibility_status, 'control_handled');
        } else {
          assert.equal(result.status, 'deferred');
          assert(stored.data, '合法新访客在精确时间确认后仍保留原问题');
        }
        assert.equal(fx.postAttempts.length, 0);
      }
    }

    for (const [from, event, malformed] of [['user', 'message:send', true], ['operator', 'message:received', []]]) {
      const fx = fixture('strict-event-time-automated-' + from);
      const session = 'session_strict-auto-' + from;
      const accepted = await webhook(fx, session, '本项目自动化回流', 95660 + (from === 'operator' ? 1 : 0),
        { event, from, automated: true, timestamp: malformed });
      const stored = fx.runtime.readState(accepted.key).jobs.find((job) => job.id === accepted.jobId);
      assert.equal(stored.status, 'done');
      assert.equal(stored.event_time_unverified, undefined);
      assert.equal(stored.responsibility_status, 'control_handled');
      assert.equal(fx.exactRequests.length, 0, '已确认自动化身份不应浪费精确消息配额');
      assert.equal(fx.postAttempts.length, 0);
    }
  });

  await test('待处理问题跨过一次全局停用后即使到期前重开也保持静默', async () => {
    const fx = fixture('global-disable-epoch-pending');
    const session = 'session_global-disable-epoch';
    const job = jobValue(fx, 'global-disable-epoch', 1, {
      retry_at: fx.now() + 120000, responsibility_status: 'unresolved_failure',
      failure_code: 'provider_unavailable',
    });
    job.data.session_id = session;
    writeState(fx, session, stateValue(fx, session, [job]));
    const runtimeConfig = path.join(fx.root, 'config', 'runtime.yaml');
    fs.writeFileSync(runtimeConfig, JSON.stringify({ schema_version: 2, enabled: false,
      disable_epoch: 1, revision: 2, applied_revision: 2 }));
    fs.writeFileSync(runtimeConfig, JSON.stringify({ schema_version: 2, enabled: true,
      disable_epoch: 1, revision: 3, applied_revision: 3 }));

    assert.deepEqual(await fx.runtime.scan(), [], '停用代次处理本身不得把旧问题重新排入发送队列');
    const current = fx.runtime.readState(fx.runtime.stateKey(website, session));
    const stored = current.jobs.find((entry) => entry.id === job.id);
    assert.equal(stored.status, 'cancelled');
    assert.equal(stored.responsibility_status, 'intentional_silence');
    assert.equal(stored.responsibility_reason, 'global_disabled');
    assert.equal(fx.postAttempts.length, 0);
    assert.equal(fx.sent.length, 0);
  });

  await test('缺时间事件精确查询遇到420或429时遵守Retry-After且不绕过时间栅栏', async () => {
    for (const status of [420, 429]) {
      const fx = fixture('event-time-rate-limit-' + status);
      const session = 'session_event-time-rate-' + status;
      const fingerprint = 95610 + status;
      const accepted = await webhook(fx, session, '缺失时间但仍需保留的问题', fingerprint,
        { omitTimestamp: true });
      assert.equal(accepted.route, 'process');
      fx.exactMessages.set(String(fingerprint), { status, headers: { 'retry-after': '120' } });
      const first = await fx.runtime.process(accepted.key, accepted.jobId);
      assert.equal(first.status, 'deferred');
      assert.equal(first.reason, 'event_time_rate_limited');
      let stored = fx.runtime.readState(accepted.key).jobs.find((job) => job.id === accepted.jobId);
      assert.equal(stored.status, 'received');
      assert.equal(stored.event_time_unverified, true);
      assert.equal(stored.responsibility_status, 'unresolved_failure');
      assert.equal(stored.failure_code, 'event_time_rate_limited');
      assert.equal(stored.event_time_retry_reason, 'rate_limited');
      assert.equal(stored.failure_rounds, 1);
      assert(stored.retry_at >= fx.now() + 120000);
      assert(stored.data, '限流不得删除原始消息责任');
      assert.equal(fx.exactRequests.length, 1);
      assert.equal(fx.postAttempts.length, 0, '时间尚未核实时不得继续生成或发送答复');

      fx.tick(5000);
      assert.equal((await fx.runtime.process(accepted.key, accepted.jobId)).status, 'idle');
      assert.equal(fx.exactRequests.length, 1, 'Retry-After 到期前不得反复请求精确消息端点');

      stored = fx.runtime.readState(accepted.key).jobs.find((job) => job.id === accepted.jobId);
      fx.exactMessages.set(String(fingerprint), { website_id: website, session_id: session,
        from: 'user', type: 'text', content: '缺失时间但仍需保留的问题', fingerprint,
        timestamp: fx.now() });
      fs.writeFileSync(path.join(fx.root, 'config', 'provider-pool-transaction.json'), '{}', { mode: 0o600 });
      fx.tick(stored.retry_at - fx.now() + 1);
      const recovered = await fx.runtime.process(accepted.key, accepted.jobId);
      assert.equal(recovered.status, 'deferred');
      stored = fx.runtime.readState(accepted.key).jobs.find((job) => job.id === accepted.jobId);
      assert.equal(stored.event_time_unverified, undefined);
      assert.equal(stored.event_time_source, 'crisp_exact');
      assert.notEqual(stored.failure_code, 'event_time_rate_limited');
      assert.equal(stored.event_time_retry_reason, undefined);
      assert.equal(fx.exactRequests.length, 2);
      assert.equal(fx.postAttempts.length, 0);
    }
  });

  await test('正文 POST 遇到 420/429 按 Retry-After 延后同一答案，不进入 unknown 对账或重新推理', async () => {
    const seedRateLimited = async (status, suffix) => {
      const fx = fixture('delivery-rate-limited-' + status + '-' + suffix);
      const session = 'session_delivery-rate-' + status + '-' + suffix;
      const fingerprint = 95700 + status;
      const plan = { type: 'text', purpose: 'keyword_reply', ordinary: true,
        content: '限流恢复后仍发送这一份受控业务答案。', fingerprint };
      const job = jobValue(fx, 'delivery-rate-' + status + '-' + suffix, 1, { plan });
      job.data.session_id = session;
      writeState(fx, session, stateValue(fx, session, [job]));
      const delay = status === 420 ? 90000 : 120000;
      const retryAfter = status === 420 ? new Date(fx.now() + delay).toUTCString() : String(delay / 1000);
      fx.postResponses.push({ status, headers: { 'retry-after': retryAfter },
        body: { error: true, reason: 'rate_limited' } });

      const first = await fx.runtime.process(fx.runtime.stateKey(website, session), job.id);
      assert(['deferred', 'rate_limited', 'unresolved'].includes(first.status));
      const current = fx.runtime.readState(fx.runtime.stateKey(website, session));
      const stored = current.jobs.find((entry) => entry.id === job.id);
      const record = current.outgoing[String(fingerprint)];
      assert(stored && record);
      assert.equal(stored.status, 'received');
      assert.equal(stored.responsibility_status, 'unresolved_failure');
      assert.equal(stored.failure_code, 'crisp_rate_limited');
      assert.equal(stored.data?.content, job.data.content);
      assert.equal(stored.plan?.content, plan.content);
      assert.equal(record.status, 'rate_limited', '明确限流拒绝不能记成发送结果 unknown');
      assert.equal(record.failure, 'crisp_rate_limited');
      assert.notEqual(record.delivery_uncertain, true);
      assert.equal(record.body?.content, plan.content);
      assert.equal(record.body?.fingerprint, fingerprint);
      assert(record.next_action_at >= fx.now() + delay - 1000);
      assert(record.next_action_at <= fx.now() + delay + 1000);
      assert.equal(stored.retry_at, record.next_action_at);
      assert.equal(fx.postAttempts.length, 1);
      assert.equal(fx.sent.length, 0);

      // 五秒 scheduler 可以反复看本地状态，但 Retry-After 到期前不得请求
      // history/exact、重复 POST 或重新生成答案。
      const exactBefore = fx.exactRequests.length;
      for (let round = 0; round < 3; round += 1) {
        fx.tick(5000);
        const waiting = await fx.runtime.process(fx.runtime.stateKey(website, session), job.id);
        assert(['idle', 'deferred', 'rate_limited'].includes(waiting.status));
        assert.equal(fx.postAttempts.length, 1);
        assert.equal(fx.exactRequests.length, exactBefore);
        const unchanged = fx.runtime.readState(fx.runtime.stateKey(website, session));
        assert.equal(unchanged.jobs.find((entry) => entry.id === job.id).plan?.content, plan.content);
        assert.equal(unchanged.outgoing[String(fingerprint)].status, 'rate_limited');
      }
      return { fx, session, fingerprint, plan, job, retryAt: record.next_action_at };
    };

    for (const status of [420, 429]) {
      const normal = await seedRateLimited(status, 'recover');
      if (normal.retryAt > normal.fx.now()) normal.fx.tick(normal.retryAt - normal.fx.now() + 1);
      const recovered = await normal.fx.runtime.process(
        normal.fx.runtime.stateKey(website, normal.session), normal.job.id);
      assert.equal(recovered.status, 'sent');
      assert.equal(normal.fx.postAttempts.length, 2);
      assert.equal(normal.fx.sent.length, 1);
      assert.equal(normal.fx.exactRequests.length, 0, '明确 420/429 不需要 unknown 指纹对账');
      assert.deepEqual(normal.fx.postAttempts.map((item) => item.fingerprint),
        [normal.fingerprint, normal.fingerprint]);
      assert.deepEqual(normal.fx.postAttempts.map((item) => item.content),
        [normal.plan.content, normal.plan.content]);
      const settled = normal.fx.runtime.readState(normal.fx.runtime.stateKey(website, normal.session));
      assert.equal(settled.jobs.find((entry) => entry.id === normal.job.id).status, 'done');
      assert.equal(settled.jobs.find((entry) => entry.id === normal.job.id).responsibility_status, 'answered_confirmed');
      assert.equal(settled.outgoing[String(normal.fingerprint)].status, 'sent');

      const policy = await seedRateLimited(status, status === 420 ? 'human' : 'global-off');
      const key = policy.fx.runtime.stateKey(website, policy.session);
      if (status === 420) {
        await webhook(policy.fx, policy.session, '真人已接管', 95820,
          { event: 'message:received', from: 'operator', automated: false });
      } else {
        fs.writeFileSync(path.join(policy.fx.root, 'config', 'runtime.yaml'),
          JSON.stringify({ schema_version: 2, enabled: false, revision: 2, applied_revision: 2 }));
      }
      if (policy.retryAt > policy.fx.now()) policy.fx.tick(policy.retryAt - policy.fx.now() + 1);
      for (let round = 0; round < 3; round += 1) {
        await policy.fx.runtime.process(key, policy.job.id);
        await policy.fx.runtime.scan();
        policy.fx.tick(5000);
      }
      const cancelled = policy.fx.runtime.readState(key);
      const cancelledJob = cancelled.jobs.find((entry) => entry.id === policy.job.id);
      const cancelledRecord = cancelled.outgoing[String(policy.fingerprint)];
      assert.equal(cancelledJob.status, 'cancelled');
      assert.equal(cancelledJob.responsibility_status, 'intentional_silence');
      assert.equal(cancelledJob.responsibility_reason, status === 420 ? 'human_reply' : 'global_disabled');
      assert(cancelledRecord, '政策取消仍需保留禁止重发栅栏');
      assert.equal(cancelledRecord.status, 'cancelled');
      assert.equal(cancelledRecord.resend_forbidden, true);
      assert.equal(policy.fx.postAttempts.length, 1, '人工/总关生效后不得重发限流中的正文');
      assert.equal(policy.fx.sent.length, 0);
      assert.equal(policy.fx.exactRequests.length, 0);
    }
  });

  await test('未知发送达到三次后禁止第四次 POST，保留原计划并可由迟到回执收敛', async () => {
    const fx = fixture('delivery-unknown-post-maximum');
    const session = 'session_delivery-max01';
    const fingerprint = 95601;
    const plan = { type: 'text', purpose: 'keyword_reply', ordinary: true,
      content: '受控业务答案只允许发送一次。', fingerprint };
    const job = jobValue(fx, 'delivery-max', 1, { plan });
    job.data.session_id = session;
    const outgoing = outgoingValue(fx, job, plan, { attempts: 3 });
    writeState(fx, session, stateValue(fx, session, [job], { outgoing: { [fingerprint]: outgoing } }));
    fx.exactMessages.set(String(fingerprint), { status: 404 });

    for (const elapsed of [0, 5000, 300001, 300001]) {
      fx.tick(elapsed);
      const result = await fx.runtime.process(fx.runtime.stateKey(website, session), job.id);
      assert(['retry', 'deferred', 'unresolved'].includes(result.status),
        '网络轮次用尽只能延后责任，不能写成业务完成或失败终态');
      const current = fx.runtime.readState(fx.runtime.stateKey(website, session));
      const stored = current.jobs.find((entry) => entry.id === job.id);
      const record = current.outgoing[String(fingerprint)];
      assert(stored && record, '原始任务和发送身份必须持久保留');
      assert.equal(stored.status, 'received');
      assert.equal(stored.plan?.content, plan.content);
      assert.equal(stored.plan?.fingerprint, fingerprint);
      assert.equal(stored.data?.content, job.data.content);
      assert.equal(record.status, 'unknown');
      assert.equal(record.body?.content, plan.content);
      assert.equal(record.attempts, 3);
      assert.equal(fx.postAttempts.length, 0, '达到三次以后绝不能绕过上限再次 POST');
    }

    // 先前某次 POST 的迟到可见结果仍可收敛同一 fingerprint，不能生成新答案。
    fx.exactMessages.set(String(fingerprint), { session_id: session, from: 'operator', type: 'text',
      content: plan.content, fingerprint, timestamp: fx.now() - 1000 });
    fx.tick(5000);
    const reconciled = await fx.runtime.process(fx.runtime.stateKey(website, session), job.id);
    assert(['sent', 'dispatched_after_cancel'].includes(reconciled.status));
    const settled = fx.runtime.readState(fx.runtime.stateKey(website, session));
    assert.equal(settled.outgoing[String(fingerprint)].status, 'sent');
    assert.equal(settled.jobs.find((entry) => entry.id === job.id).status, 'done');
    assert.equal(fx.postAttempts.length, 0);
    assert.equal(fx.sent.length, 0, '对账确认不得再产生一条新的本地 POST');
  });

  await test('精确消息端点畸形 2xx 不是阴性证据，不增加 miss 或触发重发', async () => {
    const fx = fixture('delivery-exact-malformed-2xx');
    const session = 'session_exact-malformed';
    const fingerprint = 95602;
    const plan = { type: 'text', purpose: 'keyword_reply', ordinary: true,
      content: '畸形协议期间必须保留的原答案。', fingerprint };
    const job = jobValue(fx, 'exact-malformed', 1, { plan });
    job.data.session_id = session;
    const outgoing = outgoingValue(fx, job, plan);
    writeState(fx, session, stateValue(fx, session, [job], { outgoing: { [fingerprint]: outgoing } }));
    fx.exactMessages.set(String(fingerprint), { from: 'operator', type: 'text', content: '缺少目标 fingerprint' });

    for (let round = 0; round < 3; round += 1) {
      const result = await fx.runtime.process(fx.runtime.stateKey(website, session), job.id);
      assert(['retry', 'deferred', 'unresolved'].includes(result.status));
      const current = fx.runtime.readState(fx.runtime.stateKey(website, session));
      const stored = current.jobs.find((entry) => entry.id === job.id);
      const record = current.outgoing[String(fingerprint)];
      assert.equal(record.status, 'unknown');
      assert.equal(record.reconcile_misses ?? 0, 0, '只有精确 404 才能累计阴性证据');
      assert.equal(record.body?.content, plan.content);
      assert.equal(stored.plan?.content, plan.content);
      assert.equal(stored.status, 'received');
      assert.equal(fx.postAttempts.length, 0);
      fx.tick(5000);
    }
    assert.equal(fx.exactRequests.length, 3);
  });

  await test('真人接管后未知出站只核对原 fingerprint，永不重新 POST', async () => {
    const fx = fixture('delivery-unknown-human-cancel');
    const session = 'session_unknown-human';
    const fingerprint = 95603;
    const plan = { type: 'text', purpose: 'keyword_reply', ordinary: true,
      content: '人工接管前可能已发送的答案。', fingerprint };
    const job = jobValue(fx, 'unknown-human', 1, { plan });
    job.data.session_id = session;
    const outgoing = outgoingValue(fx, job, plan);
    writeState(fx, session, stateValue(fx, session, [job], { outgoing: { [fingerprint]: outgoing } }));

    const control = await webhook(fx, session, '真人已接管', 95604,
      { event: 'message:received', from: 'operator', automated: false });
    let current = fx.runtime.readState(control.key);
    assert.equal(current.mode, 'human');
    let record = current.outgoing[String(fingerprint)];
    assert(record, '可能已送达的 fingerprint 不得因人工接管被删除');
    assert.equal(record.status, 'unknown');
    assert.equal(record.delivery_uncertain, true);
    assert.equal(record.resend_forbidden, true, '人工接管后必须持久禁止重发');
    assert.equal(record.attempt_token, outgoing.attempt_token);

    fx.exactMessages.set(String(fingerprint), { session_id: session, from: 'operator', type: 'text',
      content: plan.content, fingerprint, timestamp: fx.now() - 1000 });
    fx.tick(5000);
    const reconciled = await fx.runtime.process(control.key, job.id);
    assert(['sent', 'dispatched_after_cancel'].includes(reconciled.status));
    current = fx.runtime.readState(control.key);
    record = current.outgoing[String(fingerprint)];
    assert.equal(record.status, 'sent');
    assert.equal(record.state_changed_before_receipt, true);
    assert.equal(fx.exactRequests.filter((value) => value === String(fingerprint)).length, 1,
      '人工接管后的未知发送只能进行一次受控精确对账');
    assert.equal(fx.postAttempts.length, 0, '人工接管后的未知发送绝不能重发');
    assert.equal(fx.sent.length, 0);
    assert.equal(fx.runtime.readState(control.key).mode, 'human');
  });

  await test('128×16KiB 受字节水位限制，超限 Hook 非2xx且旧状态字节不变', async () => {
    const fx = fixture('state-bytes');
    fs.writeFileSync(path.join(fx.root, 'config', 'provider-pool-transaction.json'), '{}', { mode: 0o600 });
    const session = 'session_statebytes01';
    let accepted = 0;
    let firstRejectedBytes;
    for (let index = 0; index < 128; index += 1) {
      const result = await webhook(fx, session, 'x'.repeat(16 * 1024), 10000 + index);
      if (result.statusCode === 200) accepted += 1;
      else {
        assert.equal(result.statusCode, 503);
        const current = fs.readFileSync(stateFile(fx, session));
        if (!firstRejectedBytes) firstRejectedBytes = current;
        else assert(current.equals(firstRejectedBytes), '每次超限提交都不得覆盖活动状态');
      }
    }
    assert(accepted > 80 && accepted < 128, '字节上限应在128条上限前发生');
    assert(firstRejectedBytes.length > 1600000 && firstRejectedBytes.length < 2097152);
    assert.doesNotThrow(() => fx.runtime.readState(fx.runtime.stateKey(website, session)));
    const before = fs.readFileSync(stateFile(fx, session));
    const rejected = await webhook(fx, session, 'y'.repeat(16 * 1024), 20000);
    assert.equal(rejected.statusCode, 503);
    assert(fs.readFileSync(stateFile(fx, session)).equals(before));

    const control = await webhook(fx, session, 'h'.repeat(255 * 1024), 30000,
      { event: 'message:received', from: 'operator', automated: false });
    assert.equal(control.statusCode, 200, '低水位不得阻断已确认真人接管');
    const afterControl = fx.runtime.readState(fx.runtime.stateKey(website, session));
    assert.equal(afterControl.mode, 'human');
    assert(fs.statSync(stateFile(fx, session)).size <= 2097152);
  });

  await test('旧版接近硬上限的状态仍优先提交真人暂停', async () => {
    const fx = fixture('legacy-high-water-handoff');
    const session = 'session_legacy-highwater';
    const jobs = Array.from({ length: 9 }, (_, index) => jobValue(fx,
      'legacy-' + index + '-' + 'x'.repeat(207 * 1024), index + 1));
    writeState(fx, session, stateValue(fx, session, jobs));
    const before = fs.statSync(stateFile(fx, session)).size;
    assert(before > 1850000 && before < 2097152, '夹具必须模拟旧版可读但超过新入站水位的状态');
    const control = await webhook(fx, session, 'h'.repeat(240 * 1024), 31000,
      { event: 'message:received', from: 'operator', automated: false });
    assert.equal(control.statusCode, 200);
    const current = fx.runtime.readState(fx.runtime.stateKey(website, session));
    assert.equal(current.mode, 'human');
    assert(current.jobs.filter((job) => !job.control).every((job) => job.status === 'cancelled' && job.data === undefined));
    assert(fs.statSync(stateFile(fx, session)).size < before);
  });

  await test('超限/坏 JSON/坏结构会话匿名隔离，好会话仍进入调度', async () => {
    const fx = fixture('state-isolation');
    const good = 'session_isolation-good';
    writeState(fx, good, stateValue(fx, good, [jobValue(fx, 'good')]));
    const tooLarge = 'session_isolation-large';
    fs.writeFileSync(stateFile(fx, tooLarge), JSON.stringify({ padding: 'x'.repeat(2097152) }), { mode: 0o600 });
    const invalidJson = 'session_isolation-json';
    fs.writeFileSync(stateFile(fx, invalidJson), '{broken', { mode: 0o600 });
    const invalidState = 'session_isolation-shape';
    fs.writeFileSync(stateFile(fx, invalidState), JSON.stringify({ schema_version: 2, jobs: 'broken' }), { mode: 0o600 });
    const jobs = await fx.runtime.scan();
    assert(jobs.some((entry) => entry.key === fx.runtime.stateKey(website, good)));
    const health = JSON.parse(fs.readFileSync(path.join(fx.runtimeDirectory, 'scheduler-health.json'), 'utf8'));
    assert.deepEqual(health.isolated_sessions,
      { count: 3, reasons: { too_large: 1, invalid_json: 1, invalid_state: 1 } });

    const runtimeConfig = path.join(fx.root, 'config', 'runtime.yaml');
    const original = fs.readFileSync(runtimeConfig);
    fs.writeFileSync(runtimeConfig, '{broken');
    await assert.rejects(fx.runtime.scan(), /JSON|Unexpected token/,
      '全局配置故障不得被伪装成单会话隔离');
    fs.writeFileSync(runtimeConfig, original);
  });

  await test('safe_error 的坏 outgoing.body 只隔离所属会话', async () => {
    const fx = fixture('state-nested-isolation');
    const good = 'session_nested-good';
    writeState(fx, good, stateValue(fx, good, [jobValue(fx, 'nested-good')]));
    const bad = 'session_nested-bad';
    const badJob = jobValue(fx, 'nested-bad', 1, {
      plan: { purpose: 'safe_error', type: 'text', content: '旧内容' },
    });
    writeState(fx, bad, stateValue(fx, bad, [badJob], {
      outgoing: { 12345: { status: 'prepared', job_id: badJob.id, body: 'broken' } },
    }));
    const scheduled = await fx.runtime.scan();
    assert(scheduled.some((entry) => entry.key === fx.runtime.stateKey(website, good)));
    assert(!scheduled.some((entry) => entry.key === fx.runtime.stateKey(website, bad)));
    const health = JSON.parse(fs.readFileSync(path.join(fx.runtimeDirectory, 'scheduler-health.json'), 'utf8'));
    assert.deepEqual(health.isolated_sessions,
      { count: 1, reasons: { too_large: 0, invalid_json: 0, invalid_state: 1 } });
  });

  await test('operator 归属连续不明时保持持久屏障，精确确认自动消息后才放行', async () => {
    const fx = fixture('operator-retry-fence');
    const session = 'session_operator-eio';
    const accepted = await webhook(fx, session, '真人消息', 40000, { event: 'message:received', from: 'operator' });
    assert.equal(accepted.statusCode, 200);
    for (let attempt = 0; attempt < 3; attempt += 1) {
      const result = await fx.runtime.process(accepted.key, accepted.jobId);
      assert.deepEqual([result.status, result.reason], ['deferred', 'operator_identity_pending']);
      const pending = fx.runtime.readState(accepted.key);
      const control = pending.jobs.find((entry) => entry.id === accepted.jobId);
      assert.equal(control.status, 'received');
      assert.equal(control.responsibility_status, 'unresolved_failure');
      assert.equal(control.failure_code, 'operator_identity_pending');
      assert(pending.uncertain_events.includes(accepted.jobId));
      assert.equal(control.operator_resolution, undefined);
      fx.tick(6000);
    }
    const visitor = await webhook(fx, session, '栅栏后的新问题', 40001);
    assert.equal(visitor.statusCode, 200);
    assert.equal(visitor.route, 'ignore');
    assert.equal(fx.runtime.readState(visitor.key).jobs.find((entry) => entry.id === visitor.jobId).deferred_control, true);
    fx.exactMessages.set('40000', { session_id: session, website_id: website, from: 'operator',
      type: 'text', content: '本项目自动消息', fingerprint: 40000, timestamp: fx.now(), automated: true });
    await fx.runtime.process(accepted.key, accepted.jobId);
    const recovered = fx.runtime.readState(accepted.key);
    assert(!recovered.uncertain_events.includes(accepted.jobId));
    assert.equal(recovered.jobs.find((entry) => entry.id === accepted.jobId).operator_resolution.result, 'not-human');
    assert.equal(recovered.jobs.find((entry) => entry.id === visitor.jobId).deferred_control, undefined);
  });

  await test('scan 自愈旧版 terminal/missing barrier，且保留 human/not-human 已知结果', async () => {
    const fx = fixture('operator-orphan-migration');
    const cases = [
      { name: 'human', resolution: { schema_version: 1, result: 'human', human_changed: true }, selected: false },
      { name: 'not-human', resolution: { schema_version: 1, result: 'not-human', human_changed: false }, selected: true },
      { name: 'unknown', resolution: { schema_version: 1, result: 'unknown', human_changed: false },
        data: { from: 'operator', type: 'text', content: '旧版待核查消息', fingerprint: 51003 }, selected: false },
      { name: 'missing', missing: true, selected: false },
    ];
    const expectedKeys = new Set();
    for (const item of cases) {
      const session = 'session_orphan-' + item.name;
      const controlId = digest('control-' + item.name);
      const visitor = jobValue(fx, 'visitor-' + item.name, 2, { deferred_control: true, generation: 7 });
      const jobs = item.missing ? [visitor] : [jobValue(fx, 'control-' + item.name, 1, {
        id: controlId, event: 'message:received', data: item.data, control: true, action: 'resolve_operator',
        status: 'failed', operator_resolution: item.resolution || undefined,
      }), visitor];
      writeState(fx, session, stateValue(fx, session, jobs, { sequence: 2, generation: 7, uncertain_events: [controlId] }));
      if (item.selected) expectedKeys.add(fx.runtime.stateKey(website, session));
    }
    const scheduled = await fx.runtime.scan();
    assert.deepEqual(new Set(scheduled.map((entry) => entry.key)), expectedKeys);
    for (const item of cases) {
      const session = 'session_orphan-' + item.name;
      const current = fx.runtime.readState(fx.runtime.stateKey(website, session));
      if (item.name === 'human') {
        assert.deepEqual(current.uncertain_events, []);
        assert.equal(current.mode, 'human');
        assert.equal(current.jobs.find((entry) => !entry.control).status, 'cancelled');
        assert.equal(current.jobs.find((entry) => entry.control).operator_resolution.result, 'human');
      } else if (item.name === 'not-human') {
        assert.deepEqual(current.uncertain_events, []);
        const visitor = current.jobs.find((entry) => !entry.control);
        assert.equal(visitor.status, 'received');
        assert.equal(visitor.generation, current.generation);
        assert.equal(visitor.deferred_control, undefined);
        assert.equal(current.generation, 7);
      } else {
        assert(current.uncertain_events.includes(digest('control-' + item.name)));
        const visitor = current.jobs.find((entry) => !entry.control);
        assert.equal(visitor.status, 'received');
        assert.equal(visitor.deferred_control, true);
        if (item.name === 'unknown') {
          const control = current.jobs.find((entry) => entry.control);
          assert.equal(control.status, 'received');
          assert.equal(control.failure_code, 'operator_identity_pending');
          assert.equal(control.operator_resolution, undefined);
        }
      }
    }
  });

  await test('每会话每轮最多一件，繁忙会话不再遮蔽其它会话', async () => {
    const fx = fixture('fair-two-sessions');
    const busy = 'session_fair-busy';
    const other = 'session_fair-other';
    writeState(fx, busy, stateValue(fx, busy,
      Array.from({ length: 64 }, (_, index) => jobValue(fx, 'busy-' + index, index + 1))));
    writeState(fx, other, stateValue(fx, other, [jobValue(fx, 'other', 1)]));
    const scheduled = await fx.runtime.scan();
    assert.equal(scheduled.length, 2);
    assert.equal(new Set(scheduled.map((entry) => entry.key)).size, 2);
    assert(scheduled.some((entry) => entry.key === fx.runtime.stateKey(website, other)));
  });

  await test('超过单轮七会话的普通任务在重建 runtime 后三轮完整轮转', async () => {
    const fx = fixture('fair-restart');
    const all = new Set();
    for (let index = 0; index < 21; index += 1) {
      const session = 'session_fair-' + String(index).padStart(3, '0');
      const key = fx.runtime.stateKey(website, session);
      all.add(key);
      writeState(fx, session, stateValue(fx, session, [jobValue(fx, 'round-' + index)]));
    }
    const first = await fx.runtime.scan();
    assert.equal(first.length, 7);
    const firstKeys = new Set(first.map((entry) => entry.key));
    fx.restart();
    const second = await fx.runtime.scan();
    assert.equal(second.length, 7);
    const secondKeys = new Set(second.map((entry) => entry.key));
    fx.restart();
    const third = await fx.runtime.scan();
    assert.equal(third.length, 7);
    const thirdKeys = new Set(third.map((entry) => entry.key));
    assert.equal(new Set([...firstKeys, ...secondKeys, ...thirdKeys]).size, all.size);
    assert.notDeepEqual([...firstKeys].sort(), [...secondKeys].sort());
    assert.notDeepEqual([...secondKeys].sort(), [...thirdKeys].sort());
    const health = JSON.parse(fs.readFileSync(path.join(fx.runtimeDirectory, 'scheduler-health.json'), 'utf8'));
    assert.equal(health.ordinary_cursor, 21);
  });

  await test('控制件优先但混合批次保留普通会话，两类游标均跨重启', async () => {
    const fx = fixture('fair-controls');
    for (let index = 0; index < 20; index += 1) {
      const session = 'session_control-' + String(index).padStart(3, '0');
      writeState(fx, session, stateValue(fx, session, [jobValue(fx, 'control-round-' + index, 1,
        { event: 'message:received', control: true, action: 'operator' })]));
    }
    for (let index = 0; index < 2; index += 1) {
      const session = 'session_ordinary-' + index;
      writeState(fx, session, stateValue(fx, session, [jobValue(fx, 'ordinary-round-' + index)]));
    }
    const first = await fx.runtime.scan();
    assert.equal(first.length, 8);
    assert(first.slice(0, 7).every((entry) => entry.control));
    assert.equal(first[7].control, false);
    fx.restart();
    const second = await fx.runtime.scan();
    assert.equal(second.length, 8);
    assert(second.slice(0, 7).every((entry) => entry.control));
    assert.equal(second[7].control, false);
    assert.notEqual(first[7].key, second[7].key);
    fx.restart();
    const third = await fx.runtime.scan();
    assert.equal(third.length, 8);
    assert(third.slice(0, 7).every((entry) => entry.control));
    assert.equal(third[7].control, false);
    assert.equal(new Set([...first.slice(0, 7), ...second.slice(0, 7), ...third.slice(0, 7)]
      .map((entry) => entry.key)).size, 20);
  });

  await test('坏/超限 scheduler-health 可重建，链接仍失败关闭', async () => {
    const fx = fixture('health-recovery');
    const session = 'session_health-good';
    writeState(fx, session, stateValue(fx, session, [jobValue(fx, 'health-good')]));
    const healthFile = path.join(fx.runtimeDirectory, 'scheduler-health.json');
    fs.writeFileSync(healthFile, '{broken', { mode: 0o600 });
    assert((await fx.runtime.scan()).some((entry) => entry.key === fx.runtime.stateKey(website, session)));
    assert.deepEqual(JSON.parse(fs.readFileSync(healthFile, 'utf8')).health_recovered,
      { at: fx.now(), reason: 'invalid_json' });
    fs.writeFileSync(healthFile, JSON.stringify({ padding: 'x'.repeat(65536) }), { mode: 0o600 });
    fx.tick();
    await fx.runtime.scan();
    assert.deepEqual(JSON.parse(fs.readFileSync(healthFile, 'utf8')).health_recovered,
      { at: fx.now(), reason: 'too_large' });
    fs.unlinkSync(healthFile);
    fs.symlinkSync('session-' + fx.runtime.stateKey(website, session) + '.json', healthFile);
    await assert.rejects(fx.runtime.scan(), /受管文件格式不安全/);
    fs.unlinkSync(healthFile);
  });

  await test('旧空锁/.owner 残件可恢复，新 claim/heartbeat 残件有界清理', async () => {
    const fx = fixture('scan-lock-remnants');
    const lock = path.join(fx.runtimeDirectory, 'scheduler-scan.lock');
    fs.mkdirSync(lock, { mode: 0o700 });
    fs.utimesSync(lock, oldTime(), oldTime());
    await fx.runtime.scan();
    assert(!fs.existsSync(lock));

    fs.mkdirSync(lock, { mode: 0o700 });
    const oldOwner = path.join(lock, '.owner-' + 'a'.repeat(32));
    fs.writeFileSync(oldOwner, '{partial', { mode: 0o600 });
    fs.utimesSync(oldOwner, oldTime(), oldTime());
    fs.utimesSync(lock, oldTime(), oldTime());
    await fx.runtime.scan();
    assert(!fs.existsSync(lock));

    const bootId = fs.readFileSync('/proc/sys/kernel/random/boot_id', 'utf8').trim().toLowerCase();
    const token = 'b'.repeat(32);
    const owner = { schema_version: 1, token, pid: 2147483647, boot_id: bootId,
      process_start: '1', started_at: Date.now() - 120000, heartbeat_at: Date.now() - 120000 };
    fs.mkdirSync(lock, { mode: 0o700 });
    fs.writeFileSync(path.join(lock, 'owner.json'), JSON.stringify(owner), { mode: 0o600 });
    fs.writeFileSync(path.join(lock, '.owner-' + token), '{partial', { mode: 0o600 });
    for (const file of [path.join(lock, 'owner.json'), path.join(lock, '.owner-' + token), lock]) {
      fs.utimesSync(file, oldTime(), oldTime());
    }
    await fx.runtime.scan();
    assert(!fs.existsSync(lock));

    for (let index = 0; index < 70; index += 1) {
      const token = index.toString(16).padStart(32, '0');
      const file = path.join(fx.runtimeDirectory,
        'scheduler-scan.lock.heartbeat-' + token + '-' + index.toString(16).padStart(12, '0'));
      fs.writeFileSync(file, '{partial', { mode: 0o600 });
      fs.utimesSync(file, oldTime(), oldTime());
    }
    await fx.runtime.scan();
    const remnants = () => fs.readdirSync(fx.runtimeDirectory)
      .filter((name) => name.startsWith('scheduler-scan.lock.heartbeat-'));
    assert.equal(remnants().length, 6, '单轮清理上限必须为64');
    await fx.runtime.scan();
    assert.equal(remnants().length, 0);
  });

  await test('claim/heartbeat 真实提交窗口失败残件不阻断后续扫描', async () => {
    const fx = fixture('scan-lock-crash-injection');
    const lock = path.join(fx.runtimeDirectory, 'scheduler-scan.lock');
    const originalRename = fs.renameSync;
    const originalUnlink = fs.unlinkSync;
    let strandedClaim = '';
    fs.renameSync = function (source, target) {
      if (path.resolve(String(target)) === path.resolve(lock) && String(source).startsWith(lock + '.claim-')) {
        strandedClaim = String(source);
        const error = new Error('受控 claim 发布中断'); error.code = 'EIO'; throw error;
      }
      return originalRename.apply(this, arguments);
    };
    fs.unlinkSync = function (target) {
      if (strandedClaim && path.resolve(String(target)) === path.resolve(strandedClaim, 'owner.json')) {
        const error = new Error('模拟进程退出'); error.code = 'EBUSY'; throw error;
      }
      return originalUnlink.apply(this, arguments);
    };
    try { await assert.rejects(fx.runtime.scan(), /受控 claim/); }
    finally { fs.renameSync = originalRename; fs.unlinkSync = originalUnlink; }
    assert(strandedClaim && fs.existsSync(strandedClaim));
    const claimOwnerFile = path.join(strandedClaim, 'owner.json');
    const claimOwner = JSON.parse(fs.readFileSync(claimOwnerFile, 'utf8'));
    claimOwner.pid = 2147483647; claimOwner.process_start = '1';
    fs.writeFileSync(claimOwnerFile, JSON.stringify(claimOwner), { mode: 0o600 });
    fs.utimesSync(claimOwnerFile, oldTime(), oldTime());
    fs.utimesSync(strandedClaim, oldTime(), oldTime());
    await fx.runtime.scan();
    assert(!fs.existsSync(strandedClaim));

    let strandedHeartbeat = '';
    fs.renameSync = function (source, target) {
      if (path.resolve(String(target)) === path.resolve(lock, 'owner.json')
        && String(source).startsWith(lock + '.heartbeat-')) {
        strandedHeartbeat = String(source);
        const error = new Error('受控 heartbeat 发布中断'); error.code = 'EIO'; throw error;
      }
      return originalRename.apply(this, arguments);
    };
    fs.unlinkSync = function (target) {
      if (strandedHeartbeat && path.resolve(String(target)) === path.resolve(strandedHeartbeat)) {
        const error = new Error('模拟进程退出'); error.code = 'EBUSY'; throw error;
      }
      return originalUnlink.apply(this, arguments);
    };
    try { await assert.rejects(fx.runtime.scan(), /受控 heartbeat/); }
    finally { fs.renameSync = originalRename; fs.unlinkSync = originalUnlink; }
    assert(strandedHeartbeat && fs.existsSync(strandedHeartbeat));
    fs.utimesSync(strandedHeartbeat, oldTime(), oldTime());
    await fx.runtime.scan();
    assert(!fs.existsSync(strandedHeartbeat));
  });

  await test('两个 scanner 竞态只有一方取得完整 owner', async () => {
    const fx = fixture('scan-lock-race');
    const session = 'session_lock-race';
    writeState(fx, session, stateValue(fx, session, [jobValue(fx, 'lock-race')]));
    const other = createRuntime(env, fx.options);
    const results = await Promise.all([fx.runtime.scan(), other.scan()]);
    assert.deepEqual(results.map((entries) => entries.length).sort((left, right) => left - right), [0, 1]);
    assert(!fs.existsSync(path.join(fx.runtimeDirectory, 'scheduler-scan.lock')));
  });

  process.stdout.write('聚焦 P0 回归完成：' + passed + '/' + passed + '\n');
})().catch((error) => {
  process.stderr.write((error && error.stack) || String(error));
  process.stderr.write('\n');
  process.exitCode = 1;
});
