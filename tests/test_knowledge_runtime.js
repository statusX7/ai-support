'use strict';

// 虚构中文 FAQ；验证生产 runtime 的检索与生成接线，不冒称真实 Embedding 或模型能力。
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const {createRuntime} = require('../n8n/runtime');
const project = path.resolve(__dirname, '..');
const area = path.join(project, '.work/v1.2.1');
fs.mkdirSync(area, {recursive: true});
const evidence = fs.mkdtempSync(path.join(area, 'knowledge-runtime-'));
const question = '展厅周日开放吗？';
const reference = '周日闭馆，周一至周六开放。';
const fragment = '问题：展厅周日开放吗？\n回答：' + reference;
const canonical = value => Array.isArray(value) ? '[' + value.map(canonical).join(',') + ']'
  : value && typeof value === 'object' ? '{' + Object.keys(value).sort().map(key => JSON.stringify(key) + ':' + canonical(value[key])).join(',') + '}'
    : JSON.stringify(value);

function fixture(label, allowAdmin = false) {
  const root = path.join(evidence, label);
  for (const name of ['config', 'data/runtime', 'data/analytics']) fs.mkdirSync(path.join(root, name), {recursive: true});
  const write = (name, value) => fs.writeFileSync(path.join(root, name), JSON.stringify(value), {mode: 0o600});
  const read = name => JSON.parse(fs.readFileSync(path.join(root, name)));
  for (const name of ['menu', 'keyword', 'handoff', 'tags', 'feedback', 'provider'])
    fs.copyFileSync(path.join(project, 'config', name + '.yaml.example'), path.join(root, 'config', name + '.yaml'));
  const menu = read('config/menu.yaml'); menu.welcome.enabled = false; write('config/menu.yaml', menu);
  write('config/runtime.yaml', {schema_version: 2, revision: 1, applied_revision: 1, enabled: true});
  write('config/provider.yaml', {provider: {base_url: 'https://provider.invalid/v1', model: 'synthetic-text', api_mode: 'chat_completions'}});
  const prompt = '只依据当前启用资料回答业务事实，资料不足时问必要细节。';
  fs.writeFileSync(path.join(root, 'config/prompt.md'), prompt, {mode: 0o600});
  const projection = 'kb_1111111111111111_doc_2222222222222222.md';
  const mapping = {schema_version: 2, revision: 1, documents: [{library_id: 'kb_1111111111111111', library_name: '虚构展馆', document_id: 'doc_2222222222222222', projection, location: 'custom-documents/' + projection + '-33333333-3333-4333-8333-333333333333.json'}]};
  write('data/runtime/knowledge-map.json', mapping);
  const digest = value => crypto.createHash('sha256').update(value).digest('hex');
  const f = {root, prompt, mapping, write, read, queries: [], generated: [], sent: [], history: new Map(), workspaceReads: 0, fragments: [{id: '44444444-4444-4444-8444-444444444444', text: fragment, metadata: {title: projection}, distance: 0.1, score: 0.9}]};
  const env = {CRISP_WEBSITE_ID: '11111111-1111-4111-8111-111111111111', CRISP_WEBSITE_HOOK_SECRET: 'synthetic-retrieval-hook', CRISP_AUTH_B64: 'synthetic-auth', AI_API_KEY: 'synthetic-text-key', ANYTHINGLLM_API_KEY: 'synthetic-rag-key', ANYTHINGLLM_WORKSPACE: 'synthetic-knowledge'};
  let sequence = 8000;
  const request = async (url, options = {}) => {
    const parsed = new URL(url);
    if (parsed.hostname === 'anythingllm') {
      if (options.method === 'GET') { f.workspaceReads++; return {status: 200, body: f.workspaceResponse ?? {workspace: [{slug: env.ANYTHINGLLM_WORKSPACE, openAiTemp: 0.2}]}}; }
      if (parsed.pathname.endsWith('/vector-search')) {
        f.queries.push(structuredClone(options.body));
        if (f.beforeRetrievalResponse) await f.beforeRetrievalResponse();
        return {status: 200, body: f.retrievalResponse ?? {results: f.fragments}};
      }
      // 修复前的实际 /chat 契约：混合输入检索到了无关片段，来源非空也不能保证答案正确。
      assert(parsed.pathname.endsWith('/chat'));
      return {status: 200, body: {textResponse: '资料中未找到展馆开放日期。', sources: [{text: '虚构停车场信息', title: projection, score: 0.85}]}};
    }
    if (parsed.hostname === 'provider.invalid') {
      f.generated.push(structuredClone(options.body));
      const messages = options.body.messages || options.body.input;
      const text = JSON.stringify(messages);
      const answer = text.includes(reference) ? reference : '请说明要查询的展馆信息。';
      if (f.beforeModelResponse) await f.beforeModelResponse();
      if (f.providerError) throw f.providerError;
      if (f.providerResponse) return structuredClone(f.providerResponse);
      return {status: 200, body: {choices: [{message: {role: 'assistant', content: answer}}]}};
    }
    assert.equal(parsed.hostname, 'api.crisp.chat');
    const match = parsed.pathname.match(/\/conversation\/([^/]+)(\/.*)$/); assert(match);
    const session = match[1], suffix = match[2], history = f.history.get(session) || [];
    if (suffix === '/messages') return {status: 200, body: {error: false, data: history}};
    if (suffix.startsWith('/message/')) return {status: 200, body: {error: false, data: history.find(message => String(message.fingerprint) === suffix.slice(9)) || {}}};
    if (suffix === '/meta') return {status: 200, body: {error: false, data: {segments: []}}};
    assert.equal(suffix, '/message');
    const entry = {...structuredClone(options.body), session_id: session, timestamp: Date.now()};
    f.sent.push(entry); history.push(entry); f.history.set(session, history);
    return {status: 200, body: {error: false, data: {fingerprint: entry.fingerprint}}};
  };
  const runtime = createRuntime(env, {root, request, allowAdmin});
  f.applyKnowledgeSettings = temperature => {
    const settings = Buffer.from(JSON.stringify({schema_version: 1, workspace_slug: env.ANYTHINGLLM_WORKSPACE, temperature, observed_at: Date.now()}));
    fs.writeFileSync(path.join(root, 'data/runtime/knowledge-settings.json'), settings, {mode: 0o600});
    const profileValue = {engine: 'native', model: 'synthetic-embedding', chunk_size: 1000, chunk_overlap: 20,
      passage_prefix: '', query_prefix: '', component_version: 'synthetic'};
    const profile = Buffer.from(JSON.stringify({schema_version: 1, state: 'applied', profile: profileValue,
      fingerprint: digest(canonical(profileValue)), applied_at: Date.now()}));
    fs.writeFileSync(path.join(root, 'data/runtime/knowledge-profile.json'), profile, {mode: 0o600});
    const configuration = {};
    for (const name of ['runtime', 'handoff', 'keyword', 'menu', 'tags', 'feedback']) configuration[name] = read('config/' + name + '.yaml');
    const promptBytes = Buffer.from(prompt);
    write('config/materials-applied.json', {schema_version: 1, revision: 1, state: 'applied', applied_at: Date.now(),
      source_sha256: 'a'.repeat(64), source_components: {}, configuration,
      prompt: {text: prompt, bytes: promptBytes.length, sha256: digest(promptBytes)},
      knowledge: {map_sha256: digest(fs.readFileSync(path.join(root, 'data/runtime/knowledge-map.json'))),
        profile_sha256: digest(profile), settings_sha256: digest(settings)}});
  };
  f.admin = (text, budget = 0) => runtime.administratorQuery(text, budget);
  f.event = (session, text, overrides = {}) => ({website_id: env.CRISP_WEBSITE_ID, event: 'message:send', timestamp: Date.now(), data: {session_id: session, from: 'user', type: 'text', content: text, fingerprint: ++sequence, timestamp: Date.now(), ...overrides}});
  f.deliver = async body => {
    const history = f.history.get(body.data.session_id) || []; history.push(body.data); f.history.set(body.data.session_id, history);
    const accepted = await runtime.receive({body, query: {key: env.CRISP_WEBSITE_HOOK_SECRET}});
    assert.equal(accepted.accepted, true);
    return accepted.route === 'process' ? runtime.process(accepted.key, accepted.jobId) : accepted;
  };
  f.state = session => runtime.readState(runtime.stateKey(env.CRISP_WEBSITE_ID, session));
  return f;
}

let passed = 0, failed = 0;
async function test(name, action) {
  try { await action(); passed++; console.log('通过 UNIT/PROTOCOL：' + name); }
  catch (error) { failed++; console.error('失败 UNIT/PROTOCOL：' + name + '\n' + error.stack); }
}
(async () => {
  await test('K01 当前问题纯检索，相关片段完整进入生成并返回明确事实', async () => {
    const f = fixture('plain'); await f.deliver(f.event('session_knowledge-plain', question));
    assert.equal(f.queries.length, 1, '必须调用真实检索契约，不把混合正文交给 /chat');
    assert.equal(f.queries[0].query, question);
    assert.equal(f.generated.length, 1); assert.equal(f.generated[0].messages[0].content, f.prompt);
    assert.equal(f.generated[0].temperature, 0.2, '沿用工作区显式温度，不默认为上游温度');
    assert(JSON.stringify(f.generated[0]).includes(reference));
    assert.equal(f.sent.length, 1); assert.equal(f.sent[0].content, reference);
  });
  await test('K02 旧历史参与生成但不污染检索，其他会话不串入', async () => {
    const f = fixture('history');
    f.history.set('session_knowledge-history', [{from: 'user', type: 'text', content: '此前讨论的是停车位。'.repeat(100), fingerprint: 7001, timestamp: Date.now()-2000}]);
    await f.deliver(f.event('session_knowledge-history', question));
    assert.equal(f.queries[0]?.query, question);
    assert(JSON.stringify(f.generated[0]).includes('此前讨论的是停车位'));
    await f.deliver(f.event('session_knowledge-other', question));
    assert(!JSON.stringify(f.generated[1]).includes('此前讨论的是停车位'));
    assert.equal(f.sent.length, 2); assert(f.sent.every(item => item.content === reference));
  });
  await test('K03 停用来源不再进入模型，不因旧检索结果误记命中', async () => {
    const f = fixture('disabled'); f.write('data/runtime/knowledge-map.json', {...f.mapping, documents: []});
    await f.deliver(f.event('session_knowledge-disabled', question));
    assert.equal(f.queries.length, 1);
    assert(!JSON.stringify(f.generated).includes(reference));
    assert.equal(f.sent.length, 1); assert.notEqual(f.sent[0].content, reference);
    assert.equal(f.state('session_knowledge-disabled').mode, 'ai');
  });
  await test('K04 检索HTTP200错误结构不进入模型、不伪造成未命中', async () => {
    const f = fixture('invalid'); f.retrievalResponse = {error: 'synthetic-search-failure'};
    await f.deliver(f.event('session_knowledge-invalid', question));
    assert.equal(f.queries.length, 1); assert.equal(f.generated.length, 0); assert.equal(f.sent.length, 1);
    assert.equal(f.state('session_knowledge-invalid').mode, 'ai');
  });
  await test('K05 检索过程中真人介入，A不推理不出站而B继续', async () => {
    const f = fixture('human');
    f.beforeRetrievalResponse = async () => {
      f.beforeRetrievalResponse = null;
      const human = f.event('session_knowledge-human', '真人正在处理此会话。', {from: 'operator', automated: false}); human.event = 'message:received';
      await f.deliver(human);
    };
    await f.deliver(f.event('session_knowledge-human', question));
    assert.equal(f.state('session_knowledge-human').mode, 'human'); assert.equal(f.generated.length, 0); assert.equal(f.sent.length, 0);
    await f.deliver(f.event('session_knowledge-normal', question));
    assert.equal(f.generated.length, 1); assert.equal(f.sent.length, 1); assert.equal(f.sent[0].session_id, 'session_knowledge-normal');
  });
  await test('K06 返回片段不被静默截断，完整事实随同当前问题送入模型', async () => {
    const f = fixture('complete'); const filler = '这是虚构展馆的无关历史说明。'.repeat(400);
    f.fragments[0].text = filler + '\n' + fragment + '\n' + filler;
    await f.deliver(f.event('session_knowledge-complete', question));
    assert.equal(f.generated.length, 1);
    const citation = f.generated[0].messages.find(message => message.role === 'system' && message.content.includes('"knowledge":'));
    const knowledge = JSON.parse(citation.content.slice(citation.content.indexOf('\n') + 1)).knowledge;
    assert.equal(knowledge[0].text, f.fragments[0].text, '整块检索正文必须逐字保留，而不比较双层 JSON 的转义表示');
    assert.equal(f.sent[0].content, reference);
  });
  await test('K07 普通Webhook运行时不允许管理员测试入口', async () => {
    const f = fixture('admin-denied');
    await assert.rejects(f.admin(question), /授权无效/);
    assert.equal(f.queries.length, 0); assert.equal(f.generated.length, 0); assert.equal(f.sent.length, 0);
  });
  await test('K08 显式管理员测试共用同链，客服关闭也不改业务状态或向Crisp发消息', async () => {
    const f = fixture('admin-enabled', true);
    f.write('config/runtime.yaml', {schema_version: 2, revision: 1, applied_revision: 1, enabled: false});
    f.applyKnowledgeSettings(0.2);
    const before = fs.readFileSync(path.join(f.root, 'config/runtime.yaml'), 'utf8');
    const result = await f.admin(question, 1000);
    assert.equal(result.answer, reference); assert.equal(result.verified, true); assert.equal(result.retrieval_state, 'knowledge_hit');
    assert.equal(f.queries[0].query, question); assert.equal(f.generated[0].messages[0].content, f.prompt);
    assert.equal(f.sent.length, 0); assert.equal(fs.readFileSync(path.join(f.root, 'config/runtime.yaml'), 'utf8'), before);
    assert.deepEqual(fs.readdirSync(path.join(f.root, 'data/runtime')).sort(),
      ['knowledge-map.json', 'knowledge-profile.json', 'knowledge-settings.json']);
    assert.deepEqual(fs.readdirSync(path.join(f.root, 'data/analytics')), []);
  });
  await test('K09 管理员检索期间配置换代，不能用旧Prompt续模型或写客户消息', async () => {
    const f = fixture('admin-cancelled', true);
    f.applyKnowledgeSettings(0.2);
    f.beforeRetrievalResponse = async () => {
      const materials = f.read('config/materials-applied.json');
      materials.revision = 2; materials.configuration.runtime.revision = 2; materials.configuration.runtime.applied_revision = 2;
      f.write('config/materials-applied.next.json', materials);
      fs.renameSync(path.join(f.root, 'config/materials-applied.next.json'), path.join(f.root, 'config/materials-applied.json'));
    };
    await assert.rejects(f.admin(question), /未完成/);
    assert.equal(f.queries.length, 1); assert.equal(f.generated.length, 0); assert.equal(f.sent.length, 0);
  });
  await test('K10 管理员空知识连接探测仍检查模型，不把它描述为知识命中', async () => {
    const f = fixture('admin-empty', true); f.applyKnowledgeSettings(0.2); f.fragments = [];
    const result = await f.admin('这是一条虚构连接探测问题。');
    assert.equal(result.verified, true); assert.equal(result.retrieval_state, 'knowledge_miss');
    assert.deepEqual(result.sources, []); assert.equal(f.generated.length, 1); assert.equal(f.sent.length, 0);
  });
  await test('K11 工作区缺失或非法温度不产生模型调用', async () => {
    for (const value of [{workspace: []}, {workspace: [{slug: 'synthetic-knowledge', openAiTemp: 'bad'}]}]) {
      const f = fixture('invalid-workspace-' + passed + '-' + Math.random(), true); f.workspaceResponse = value;
      f.applyKnowledgeSettings(0.2);
      const materials = f.read('config/materials-applied.json'); materials.knowledge.settings_sha256 = '';
      f.write('config/materials-applied.json', materials);
      fs.unlinkSync(path.join(f.root, 'data/runtime/knowledge-settings.json'));
      await assert.rejects(f.admin(question), /未完成/);
      assert.equal(f.queries.length, 0); assert.equal(f.generated.length, 0); assert.equal(f.sent.length, 0);
    }
  });
  await test('K12 已应用温度投影避免每条咨询下载完整工作区，篡改时阻止推理', async () => {
    const f = fixture('projected-temperature'); f.applyKnowledgeSettings(0.35);
    await f.deliver(f.event('session_knowledge-projected', question));
    assert.equal(f.workspaceReads, 0); assert.equal(f.generated[0].temperature, 0.35); assert.equal(f.sent[0].content, reference);
    f.write('data/runtime/knowledge-settings.json', {schema_version: 1, workspace_slug: 'synthetic-knowledge', temperature: 0.7, observed_at: Date.now()});
    await f.deliver(f.event('session_knowledge-tampered', question));
    assert.equal(f.workspaceReads, 0); assert.equal(f.generated.length, 1); assert.equal(f.sent.length, 2);
    assert.notEqual(f.sent[1].content, reference);
  });
  await test('K13 管理员问答不得绕过知识代次、字节和迁移就绪门禁', async () => {
    const cases = [
      ['missing-materials', f => fs.unlinkSync(path.join(f.root, 'config/materials-applied.json'))],
      ['missing-profile', f => fs.unlinkSync(path.join(f.root, 'data/runtime/knowledge-profile.json'))],
      ['tampered-profile', f => {
        const file = path.join(f.root, 'data/runtime/knowledge-profile.json');
        const value = JSON.parse(fs.readFileSync(file)); value.profile.chunk_size += 1;
        fs.writeFileSync(file, JSON.stringify(value), {mode: 0o600});
      }],
      ['stale-migration', f => f.write('data/runtime/knowledge-migration.json', {schema_version: 1, backup: '/synthetic/not-used'})],
      ['migration-directory', f => fs.mkdirSync(path.join(f.root, 'data/runtime/knowledge-migration.json'))],
    ];
    for (const [label, mutate] of cases) {
      const f = fixture('admin-readiness-' + label, true); f.applyKnowledgeSettings(0.35); mutate(f);
      await assert.rejects(f.admin(question), /未完成/);
      assert.equal(f.queries.length, 0, label + ' 不得调用向量检索');
      assert.equal(f.generated.length, 0, label + ' 不得调用模型');
      assert.equal(f.sent.length, 0, label + ' 不得向客户发送消息');
    }
  });
  await test('K14 迁移标记的任意非缺失类型都同时阻止客服检索与推理', async () => {
    const f = fixture('customer-migration-directory'); f.applyKnowledgeSettings(0.35);
    fs.mkdirSync(path.join(f.root, 'data/runtime/knowledge-migration.json'));
    await f.deliver(f.event('session_knowledge-migration-directory', question));
    assert.equal(f.queries.length, 0); assert.equal(f.generated.length, 0); assert.equal(f.sent.length, 0);
  });
  await test('K15 管理员推理按鉴权、模型、上游、超时及无效响应返回安全类别', async () => {
    const cases = [
      ['authentication', {status: 401, body: {error: {message: 'synthetic authentication failure'}}}, null, 'authentication_failed'],
      ['model', {status: 404, body: {error: {message: 'synthetic model failure'}}}, null, 'model_unavailable'],
      ['upstream', {status: 503, body: {error: {message: 'synthetic upstream failure'}}}, null, 'upstream_unavailable'],
      ['empty', {status: 200, body: {choices: []}}, null, 'invalid_response'],
      ['error-json', {status: 200, body: {error: {message: 'synthetic protocol failure'}}}, null, 'invalid_response'],
      ['protocol-error', {status: 400, body: {error: {code: 'protocol_error', message: 'synthetic adapter detail'}}}, null, 'protocol_error'],
      ['timeout', null, Object.assign(new Error('请求超时'), {name: 'AbortError'}), 'upstream_timeout'],
    ];
    for (const [label, response, providerError, expected] of cases) {
      const f = fixture('admin-provider-' + label, true); f.applyKnowledgeSettings(0.2);
      f.providerResponse = response; f.providerError = providerError;
      await assert.rejects(f.admin(question, 1000), error => {
        assert.equal(error.code, expected, label + ' 应返回白名单诊断类别');
        assert(!String(error.message).includes('synthetic'), label + ' 不得向管理员透传上游正文');
        return true;
      });
      assert.equal(f.queries.length, 1, label + ' 应先走实际检索链');
      assert.equal(f.generated.length, 1, label + ' 应只发起一次模型尝试');
      assert.equal(f.sent.length, 0, label + ' 管理员检查不得向客户发消息');
    }
  });
  await test('K16 管理员检索错误与推理错误分层，检索失败时不调用模型', async () => {
    const f = fixture('admin-retrieval-diagnostic', true); f.applyKnowledgeSettings(0.2);
    f.retrievalResponse = {error: 'synthetic retrieval failure'};
    await assert.rejects(f.admin(question, 1000), error => {
      assert.equal(error.code, 'retrieval_invalid');
      assert(!String(error.message).includes('synthetic'), '不得透传检索服务原始错误正文');
      return true;
    });
    assert.equal(f.queries.length, 1);
    assert.equal(f.generated.length, 0, '检索错误不得被归类为 Provider 推理错误后继续调用模型');
    assert.equal(f.sent.length, 0);
  });
  console.log(JSON.stringify({layer: 'UNIT/PROTOCOL', passed, failed}));
  process.exitCode = failed ? 1 : 0;
})().catch(error => {console.error(error.stack); process.exitCode = 1;});
