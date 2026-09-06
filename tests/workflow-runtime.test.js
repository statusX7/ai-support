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
let now = Date.now();
let sequence = 1000;
let delayed;
let modelFailure = false;
let tagFailure = false;
let crispFailure = false;
let unknownSend = false;
let unknownSources = false;
let miss = false;
let low = false;
let imageMode = 'valid';
const sent = [];
const histories = new Map();
const modelRequests = [];
const providerRequests = [];
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
      sent.push({ ...body, session_id: session });
      history.push({ ...body, timestamp: now }); histories.set(session, history);
      await runtime.receive({ query: { key: env.CRISP_WEBSITE_HOOK_SECRET }, body: { website_id: env.CRISP_WEBSITE_ID, event: 'message:received', data: { ...body, automated: undefined, properties: undefined, session_id: session }, timestamp: now } });
      if (unknownSend) { unknownSend = false; throw new Error('受控发送超时'); }
      return { status: 200, body: { error: false, reason: 'dispatched', data: { fingerprint: body.fingerprint } } };
    }
    throw new Error('未知 Crisp 测试路径：' + suffix);
  }
  if (parsed.hostname === 'anythingllm') {
    modelRequests.push(options.body);
    if (delayed) { const pending = delayed; delayed = null; await pending; }
    if (modelFailure) return { status: 503, body: { error: 'provider_failed' } };
    const body = { textResponse: '受控协议回答：' + options.body.message.slice(-25) };
    if (!unknownSources) body.sources = miss ? [] : [{ docpath: 'controlled/document.json', score: low ? 0.1 : 0.9 }];
    return { status: 200, body };
  }
  if (parsed.hostname === 'provider.invalid') {
    providerRequests.push({ path: parsed.pathname, body: options.body });
    return { status: 200, body: parsed.pathname.endsWith('/responses') ? { output: [{ content: [{ text: '受控视觉协议回答' }] }] } : { choices: [{ message: { content: '受控视觉协议回答' } }] } };
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
  if (body.event === 'message:send' && body.data.type === 'text') {
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
  await test('T18 人工关键词仅展示原生可继续聊天 picker', async () => {
    const before = modelRequests.length;
    await deliver(message('session_client-a', '我想转人工'));
    const card = sent.at(-1);
    assert.equal(card.type, 'picker'); assert.equal(card.content.required, false); assert.equal(card.content.choices[0].label, '召唤人工客服');
    assert.equal(state('session_client-a').mode, 'ai'); assert.equal(modelRequests.length, before);
    await deliver(message('session_client-a', '尚未点击，请回答普通问题'));
    assert.equal(state('session_client-a').mode, 'ai'); assert.equal(modelRequests.length, before + 1);
    assert.equal(sent.at(-1).type, 'text');
  });
  await test('T19/T21 真点击缺少from/type、原fingerprint已见也只暂停A', async () => {
    const card = sent.find((entry) => entry.session_id === 'session_client-a' && entry.type === 'picker');
    await deliver(click('session_client-a', card));
    assert.equal(state('session_client-a').mode, 'human');
    assert.match(sent.at(-1).content, /已暂停/);
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
    assert.match(modelRequests.at(-1).message, /受控视觉协议回答/);
    assert.equal(modelRequests.at(-1).sessionId, 'session_image001');
    assert.equal(modelRequests.at(-1).reset, true);
    const provider = readConfig('provider'); provider.provider.api_mode = 'responses'; writeConfig('provider', provider);
    await deliver(message('session_image002', image, { type: 'file' })); assert.match(providerRequests.at(-1).body.input.at(-1).content[1].image_url, /^data:image/);
    assert.equal(providerRequests.at(-1).path, '/proxy/v1/responses');
    assert.match(modelRequests.at(-1).message, /不可信客户资料/);
    assert.equal(modelRequests.at(-1).sessionId, 'session_image002');
    for (const mode of ['expired', 'wrong', 'huge']) { imageMode = mode; await deliver(message('session_badimage-' + mode, image, { type: 'file' })); assert.match(sent.at(-1).content, /补充|重新上传/); assert.equal(state('session_badimage-' + mode).mode, 'ai'); }
    imageMode = 'valid'; const unsafe = createRuntime(env, { ...runtimeOptions, lookup: (_host, _options, callback) => callback(null, [{ address: '127.0.0.1', family: 4 }]) }); await assert.rejects(unsafe.imageContent(image), /受限网络/);
    await assert.rejects(runtime.imageContent({ ...image, url: 'https://evil.invalid/image.png' }), /安全校验/);
  });
  await test('T39 持久任务重启、重复Hook和发送结果未知对账', async () => {
    const body = message('session_recovery1', '持久接收'); const entry = await receive(body); assert.equal(entry.reason, '已持久接收');
    runtime = createRuntime(env, runtimeOptions); assert((await runtime.scan()).some((job) => job.jobId === entry.jobId));
    unknownSend = true; const before = sent.length; assert.equal((await runtime.process(entry.key, entry.jobId)).status, 'retry');
    now += 6000; await runtime.process(entry.key, entry.jobId); assert.equal(sent.length, before + 1);
    assert.equal((await receive(body)).reason, '重复事件已忽略');
    const file = path.join(root, 'data', 'runtime', 'session-' + entry.key + '.json'); assert.equal(fs.statSync(file).mode & 0o777, 0o600); assert(!fs.readFileSync(file, 'utf8').includes('持久接收'));
  });
  await test('T40/T41 标签并集、权限失败、检索未知与负反馈', async () => {
    await deliver(message('session_tags0001', '有资料的问题')); assert(segments.get('session_tags0001').includes('external-vip')); assert(segments.get('session_tags0001').includes('ai_replied')); assert(!segments.get('session_tags0001').includes('ai_resolved'));
    tagFailure = true; await deliver(message('session_tagsfail1', '标签失败正文仍发送')); assert.equal(sent.at(-1).session_id, 'session_tagsfail1'); tagFailure = false;
    miss = true; await deliver(message('session_miss0001', '知识未命中')); miss = false;
    low = true; await deliver(message('session_low00001', '低分问题')); low = false;
    unknownSources = true; await deliver(message('session_unknown1', '元数据缺失')); unknownSources = false;
    modelFailure = true; await deliver(message('session_modelerror', '接口失败')); modelFailure = false;
    await deliver(message('session_negative1', 'token=synthetic-private-value 为什么失败')); await deliver(message('session_negative1', '👎')); assert.equal(state('session_negative1').mode, 'ai');
    const events = fs.readFileSync(path.join(root, 'data', 'analytics', 'events.jsonl'), 'utf8').trim().split('\n').map(JSON.parse);
    assert(events.some((event) => event.type === 'knowledge_unknown')); assert(events.some((event) => event.type === 'knowledge_miss')); assert(events.some((event) => event.type === 'feedback' && event.feedback === 'negative'));
    assert(!JSON.stringify(events).includes('synthetic-private-value')); assert.equal(state('session_modelerror').mode, 'ai');
  });
  await test('上下文单源、同session reset、新Prompt和隐私过滤', async () => {
    const request = modelRequests.find((entry) => entry.sessionId === 'session_timeline01'); assert.equal(request.reset, true); assert.match(request.message, /人工公开/);
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
  process.stdout.write(JSON.stringify({ layer: 'UNIT/CONTRACT', passed, failed: 0, evidence: path.relative(project, root) }) + '\n');
})().catch((error) => { process.stderr.write(error.stack + '\n'); process.exitCode = 1; });
