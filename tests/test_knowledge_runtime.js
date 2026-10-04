'use strict';

// 虚构中文 FAQ；验证生产 runtime 的检索与生成接线，不冒称真实 Embedding 或模型能力。
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const {spawnSync} = require('node:child_process');
const {createRuntime} = require('../n8n/runtime');
const project = path.resolve(__dirname, '..');
const area = path.join(project, '.work/v1.3.0');
fs.mkdirSync(area, {recursive: true});
const evidence = fs.mkdtempSync(path.join(area, 'knowledge-runtime-'));
const lexicalBuilder = path.join(project, 'scripts/knowledge-lexical.py');
const question = '展厅周日开放吗？';
const reference = '周日闭馆，周一至周六开放。';
const retiredGeneric = '你最希望先解决哪一处？可以把具体情况、相关提示和已经尝试的方法一起告诉我。';
const fragment = '问题：展厅周日开放吗？\n回答：' + reference;
const canonical = value => Array.isArray(value) ? '[' + value.map(canonical).join(',') + ']'
  : value && typeof value === 'object' ? '{' + Object.keys(value).sort().map(key => JSON.stringify(key) + ':' + canonical(value[key])).join(',') + '}'
    : JSON.stringify(value);
const digest = value => crypto.createHash('sha256').update(value).digest('hex');
const componentNames = ['feedback', 'handoff', 'keyword', 'knowledge', 'menu', 'prompt', 'runtime', 'tags'];

function sealMaterials(projection) {
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
}

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
  const parsed = path.join(root, 'data/anythingllm/documents', mapping.documents[0].location);
  fs.mkdirSync(path.dirname(parsed), {recursive: true});
  fs.writeFileSync(parsed, JSON.stringify({pageContent: '这是虚构展馆的受管索引占位资料。', title: projection}), {mode: 0o600});
  const f = {root, prompt, mapping, write, read, queries: [], generated: [], sent: [], history: new Map(), workspaceReads: 0, providerAnswer: null,
    fragments: [{id: '44444444-4444-4444-8444-444444444444', text: fragment, metadata: {title: projection}, distance: 0.1, score: 0.9}]};
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
      const answer = f.providerAnswer ?? (text.includes(reference) ? reference : '请说明要查询的展馆信息。');
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
    if (f.crispPostResponse) return structuredClone(f.crispPostResponse(entry));
    return {status: 200, body: {error: false, data: {fingerprint: entry.fingerprint}}};
  };
  let runtime;
  const restart = () => {
    runtime = createRuntime(env, {root, request, allowAdmin});
    f.runtime = runtime;
    return runtime;
  };
  restart();
  f.installLexical = (contents = [fragment]) => {
    const documents = contents.map((content, index) => {
      const suffix = (index + 1).toString(16).padStart(16, '0');
      const currentProjection = 'kb_1111111111111111_doc_' + suffix + '.md';
      const location = 'custom-documents/' + currentProjection + '-' + suffix.slice(0, 8) + '-3333-4333-8333-333333333333.json';
      const item = {library_id: 'kb_1111111111111111', library_name: '虚构展馆', document_id: 'doc_' + suffix,
        projection: currentProjection, location};
      const target = path.join(root, 'data/anythingllm/documents', location);
      fs.mkdirSync(path.dirname(target), {recursive: true});
      fs.writeFileSync(target, JSON.stringify({pageContent: content, title: currentProjection}), {mode: 0o600});
      return item;
    });
    f.mapping.documents = documents;
    f.write('data/runtime/knowledge-map.json', f.mapping);
    f.fragments = documents.length ? [{id: '44444444-4444-4444-8444-444444444444', text: contents[0],
      metadata: {title: documents[0].projection}, distance: 0.1, score: 0.9}] : [];
    const result = spawnSync('python3', [lexicalBuilder, 'build', '--deploy-dir', root], {encoding: 'utf8', timeout: 45000});
    assert.equal(result.status, 0, result.stdout + result.stderr);
    assert.equal(JSON.parse(result.stdout).ok, true);
    return f.read('data/runtime/knowledge-lexical.json');
  };
  f.applyKnowledgeSettings = (temperature, options = {}) => {
    const lexical = path.join(root, 'data/runtime/knowledge-lexical.json');
    if (!fs.existsSync(lexical)) {
      const built = spawnSync('python3', [lexicalBuilder, 'build', '--deploy-dir', root], {encoding: 'utf8', timeout: 45000});
      assert.equal(built.status, 0, built.stdout + built.stderr);
      assert.equal(JSON.parse(built.stdout).ok, true);
    }
    const settings = Buffer.from(JSON.stringify({schema_version: 1, workspace_slug: env.ANYTHINGLLM_WORKSPACE, temperature, observed_at: Date.now()}));
    fs.writeFileSync(path.join(root, 'data/runtime/knowledge-settings.json'), settings, {mode: 0o600});
    const currentMap = read('data/runtime/knowledge-map.json');
    let profile = Buffer.alloc(0);
    const profileFile = path.join(root, 'data/runtime/knowledge-profile.json');
    if (currentMap.documents.length || options.profileForEmpty === true) {
      const profileValue = {engine: 'native', model: 'synthetic-embedding', chunk_size: 1000, chunk_overlap: 20,
        passage_prefix: '', query_prefix: '', component_version: 'synthetic'};
      profile = Buffer.from(JSON.stringify({schema_version: 1, state: 'applied', profile: profileValue,
        fingerprint: digest(canonical(profileValue)), applied_at: Date.now()}));
      fs.writeFileSync(profileFile, profile, {mode: 0o600});
    } else {
      fs.rmSync(profileFile, {force: true});
    }
    const configuration = {};
    for (const name of ['runtime', 'handoff', 'keyword', 'menu', 'tags', 'feedback']) configuration[name] = read('config/' + name + '.yaml');
    const promptBytes = Buffer.from(prompt);
    const enabledLibraries = [...new Set(currentMap.documents.map(item => item.library_id))].sort();
    const knowledge = {
      catalog_revision: Number(currentMap.revision || 1),
      catalog_sha256: digest(canonical({fixture: 'catalog', revision: Number(currentMap.revision || 1), documents: currentMap.documents})),
      manifest_sha256: digest(canonical({fixture: 'manifest', documents: currentMap.documents.map(item => item.location)})),
      map_sha256: digest(fs.readFileSync(path.join(root, 'data/runtime/knowledge-map.json'))),
      settings_sha256: digest(settings),
      profile_sha256: profile.length ? digest(profile) : '',
      lexical_sha256: digest(fs.readFileSync(lexical)),
      enabled_library_ids: enabledLibraries,
      library_count: enabledLibraries.length,
      document_count: options.sourceDocumentCount ?? currentMap.documents.length,
      enabled_document_count: currentMap.documents.length,
    };
    const materials = sealMaterials({schema_version: 2, revision: 1, state: 'applied', applied_at: Date.now(),
      source_sha256: '', source_components: {}, configuration,
      prompt: {text: prompt, bytes: promptBytes.length, sha256: digest(promptBytes)},
      knowledge});
    write('config/materials-applied.json', materials);
    return materials;
  };
  f.sealMaterials = sealMaterials;
  f.publishMaterials = materials => {
    sealMaterials(materials);
    write('config/materials-applied.next.json', materials);
    fs.renameSync(path.join(root, 'config/materials-applied.next.json'), path.join(root, 'config/materials-applied.json'));
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
  f.key = session => runtime.stateKey(env.CRISP_WEBSITE_ID, session);
  f.runtime = runtime;
  f.restart = restart;
  f.ownedBucket = (session, fingerprint) => path.join(root, 'data/runtime', 'owned-' + f.key(session) + '-'
    + (Number(fingerprint) % 256).toString(16).padStart(2, '0') + '.json');
  f.seedOwnedFingerprint = (session, fingerprint) => {
    const value = String(fingerprint);
    assert.match(value, /^(?:0|[1-9][0-9]{0,15})$/);
    assert(Number.isSafeInteger(Number(value)));
    const file = f.ownedBucket(session, value);
    const index = fs.existsSync(file) ? JSON.parse(fs.readFileSync(file, 'utf8')) : {schema_version: 1, fingerprints: []};
    assert.equal(index.schema_version, 1); assert(Array.isArray(index.fingerprints));
    if (!index.fingerprints.includes(value)) index.fingerprints.push(value);
    fs.writeFileSync(file, JSON.stringify(index), {mode: 0o600});
    fs.chmodSync(file, 0o600);
    return file;
  };
  f.registerOwnedHistory = (session, fingerprint) => runtime.transaction(f.key(session), (state) => {
    state.outgoing[String(fingerprint)] = { status: 'sent', created_at: Date.now() };
  }, env.CRISP_WEBSITE_ID, session);
  return f;
}

let passed = 0, failed = 0;
async function test(name, action) {
  try { await action(); passed++; console.log('通过 UNIT/PROTOCOL：' + name); }
  catch (error) { failed++; console.error('失败 UNIT/PROTOCOL：' + name + '\n' + error.stack); }
}
(async () => {
  await test('W07 一个源文档对应多个已索引 location 时运行时按两个维度验收', async () => {
    const f = fixture('one-source-multiple-locations', true);
    const first = f.mapping.documents[0];
    const second = {...first,
      location: 'custom-documents/' + first.projection + '-55555555-5555-4555-8555-555555555555.json'};
    const firstParsed = path.join(f.root, 'data/anythingllm/documents', first.location);
    const secondParsed = path.join(f.root, 'data/anythingllm/documents', second.location);
    fs.mkdirSync(path.dirname(secondParsed), {recursive: true});
    fs.copyFileSync(firstParsed, secondParsed);
    f.mapping.documents = [first, second];
    f.write('data/runtime/knowledge-map.json', f.mapping);
    const materials = f.applyKnowledgeSettings(0.2, {sourceDocumentCount: 1});
    assert.equal(materials.knowledge.document_count, 1);
    assert.equal(materials.knowledge.enabled_document_count, 2);
    const result = await f.admin(question);
    assert.equal(result.answer, reference);
    assert.equal(result.verified, true);
  });
  await test('K01 当前问题纯检索，相关片段完整进入生成并返回明确事实', async () => {
    const f = fixture('plain'); f.applyKnowledgeSettings(0.2);
    await f.deliver(f.event('session_knowledge-plain', question));
    assert.equal(f.queries.length, 1, '必须调用真实检索契约，不把混合正文交给 /chat');
    assert.equal(f.queries[0].query, question);
    assert.equal(f.generated.length, 1); assert.equal(f.generated[0].messages[0].content, f.prompt);
    assert.equal(f.generated[0].temperature, 0.2, '沿用工作区显式温度，不默认为上游温度');
    assert(JSON.stringify(f.generated[0]).includes(reference));
    assert.equal(f.sent.length, 1); assert.equal(f.sent[0].content, reference);
  });
  await test('K02 旧历史参与生成但不污染检索，其他会话不串入', async () => {
    const f = fixture('history'); f.applyKnowledgeSettings(0.2);
    const session = 'session_knowledge-history';
    await f.registerOwnedHistory(session, 7002);
    f.history.set(session, [
      {from: 'user', type: 'text', content: '此前讨论的是停车位。'.repeat(100), fingerprint: 7001, timestamp: Date.now()-2000},
      {from: 'operator', type: 'text', content: retiredGeneric, fingerprint: 7002, timestamp: Date.now()-1000},
    ]);
    const first = await f.deliver(f.event(session, question));
    assert.equal(f.queries[0]?.query, question);
    assert(JSON.stringify(f.generated[0]).includes('此前讨论的是停车位'));
    assert(!JSON.stringify(f.generated[0]).includes(retiredGeneric), '本项目旧 generic 不得污染后续模型上下文');
    let current = f.state(session);
    let jobs = current.jobs.filter(job => job.id === first.jobId);
    assert.equal(jobs.length, 1); assert.equal(jobs[0].status, 'done');
    assert.equal(jobs[0].responsibility_status, 'answered_confirmed');
    assert.equal(f.sent.filter(item => item.session_id === session).length, 1);
    assert.equal(f.sent.find(item => item.session_id === session)?.content, reference);
    assert(!f.sent.some(item => typeof item.content === 'string' && item.content.includes(retiredGeneric)));

    const follow = await f.deliver(f.event(session, '请问，周日可以参观展厅吗？'));
    current = f.state(session); jobs = current.jobs.filter(job => job.id === follow.jobId);
    assert.equal(jobs.length, 1); assert.equal(jobs[0].status, 'done');
    assert.equal(jobs[0].responsibility_status, 'answered_confirmed');
    assert.equal(f.sent.filter(item => item.session_id === session).length, 2);
    assert(f.sent.filter(item => item.session_id === session).every(item => item.content === reference));
    assert(!JSON.stringify(f.generated.at(-1)).includes(retiredGeneric));

    await f.deliver(f.event('session_knowledge-other', question));
    assert(!JSON.stringify(f.generated.at(-1)).includes('此前讨论的是停车位'));
    assert.equal(f.sent.length, 3); assert(f.sent.every(item => item.content === reference));

    const persisted = fixture('history-owned-after-prune'); persisted.applyKnowledgeSettings(0.2);
    const persistedSession = 'session_knowledge-history-owned';
    const genericFingerprint = 7022, normalFingerprint = 7023;
    const normalOwnedFact = '此前已确认预约资料保存成功。';
    await persisted.registerOwnedHistory(persistedSession, genericFingerprint);
    await persisted.registerOwnedHistory(persistedSession, normalFingerprint);
    const genericOwnedFile = persisted.seedOwnedFingerprint(persistedSession, genericFingerprint);
    const normalOwnedFile = persisted.seedOwnedFingerprint(persistedSession, normalFingerprint);
    await persisted.runtime.transaction(persisted.key(persistedSession), state => {
      delete state.outgoing[String(genericFingerprint)];
      delete state.outgoing[String(normalFingerprint)];
    });
    let persistedState = persisted.state(persistedSession);
    assert.equal(Object.hasOwn(persistedState.outgoing, String(genericFingerprint)), false);
    assert.equal(Object.hasOwn(persistedState.outgoing, String(normalFingerprint)), false);
    for (const [file, fingerprint] of [[genericOwnedFile, genericFingerprint], [normalOwnedFile, normalFingerprint]]) {
      const index = JSON.parse(fs.readFileSync(file, 'utf8'));
      assert.deepEqual(Object.keys(index).sort(), ['fingerprints', 'schema_version']);
      assert(index.fingerprints.includes(String(fingerprint)));
      assert.equal(fs.statSync(file).mode & 0o777, 0o600);
      assert(!JSON.stringify(index).includes(retiredGeneric), '持久身份只能保存 fingerprint，不能保存客服正文');
    }
    const previousRuntime = persisted.runtime;
    persisted.restart();
    assert.notEqual(persisted.runtime, previousRuntime, '必须由新 runtime 从磁盘恢复自有身份');
    persistedState = persisted.state(persistedSession);
    assert.equal(Object.hasOwn(persistedState.outgoing, String(genericFingerprint)), false);
    assert.equal(Object.hasOwn(persistedState.outgoing, String(normalFingerprint)), false);
    persisted.history.set(persistedSession, [
      {from: 'user', type: 'text', content: '此前已确认预约编号。', fingerprint: 7021, timestamp: Date.now()-4000},
      {from: 'operator', type: 'text', content: retiredGeneric, automated: false, fingerprint: genericFingerprint, timestamp: Date.now()-3000},
      {from: 'operator', type: 'text', content: normalOwnedFact, automated: false, fingerprint: normalFingerprint, timestamp: Date.now()-2000},
      {from: 'user', type: 'text', content: retiredGeneric, fingerprint: 7024, timestamp: Date.now()-1000},
    ]);
    const persistedResult = await persisted.deliver(persisted.event(persistedSession, question));
    assert.equal(persisted.generated.length, 1);
    const requestMessages = persisted.generated[0].messages;
    assert(Array.isArray(requestMessages));
    assert.equal(requestMessages.filter(item => item.role === 'assistant' && item.content === retiredGeneric).length, 0,
      '仅由持久 owned 身份确认的退役 generic 不得进入 Provider assistant 历史');
    assert.equal(requestMessages.filter(item => item.role === 'user' && item.content === retiredGeneric).length, 1,
      '访客引用相同正文必须保留，不能按内容全局删除');
    assert.equal(requestMessages.filter(item => item.role === 'assistant' && item.content === normalOwnedFact).length, 1,
      '正常本项目历史答复必须保留');
    assert.equal(requestMessages.filter(item => item.role === 'user' && item.content === question).length, 1,
      '当前问题只进入 Provider 一次');
    assert(requestMessages.some(item => item.role === 'system' && item.content.includes(reference)),
      '当前有效知识事实必须进入最终 Provider 请求');
    persistedState = persisted.state(persistedSession);
    const persistedJobs = persistedState.jobs.filter(job => job.id === persistedResult.jobId);
    assert.equal(persistedJobs.length, 1); assert.equal(persistedJobs[0].status, 'done');
    assert.equal(persistedJobs[0].responsibility_status, 'answered_confirmed');
    assert.equal(persisted.sent.length, 1); assert.equal(persisted.sent[0].content, reference);
    assert(!persisted.sent.some(item => typeof item.content === 'string' && item.content.includes(retiredGeneric)));

    const recovering = fixture('history-provider-recovery'); recovering.applyKnowledgeSettings(0.2);
    const recoveringSession = 'session_knowledge-history-recovery';
    await recovering.registerOwnedHistory(recoveringSession, 7012);
    recovering.history.set(recoveringSession, [
      {from: 'user', type: 'text', content: '此前讨论的是停车位。', fingerprint: 7011, timestamp: Date.now()-2000},
      {from: 'operator', type: 'text', content: retiredGeneric, fingerprint: 7012, timestamp: Date.now()-1000},
    ]);
    recovering.providerError = Object.assign(new Error('synthetic-timeout'), {code: 'ETIMEDOUT'});
    const failed = await recovering.deliver(recovering.event(recoveringSession, question));
    assert.equal(recovering.sent.length, 0, '技术失败不能再次发送旧 generic 或其它可见兜底');
    current = recovering.state(recoveringSession);
    jobs = current.jobs.filter(job => job.id === failed.jobId);
    assert.equal(jobs.length, 1); assert.equal(jobs[0].status, 'received');
    assert.equal(jobs[0].responsibility_status, 'unresolved_failure');
    recovering.providerError = null;
    await recovering.runtime.transaction(failed.key, state => {
      const job = state.jobs.find(item => item.id === failed.jobId); assert(job); job.retry_at = 0;
    });
    const recovered = await recovering.runtime.process(failed.key, failed.jobId);
    assert.equal(recovered.status, 'sent');
    current = recovering.state(recoveringSession);
    jobs = current.jobs.filter(job => job.id === failed.jobId);
    assert.equal(jobs.length, 1); assert.equal(jobs[0].status, 'done');
    assert.equal(jobs[0].responsibility_status, 'answered_confirmed');
    assert.equal(recovering.sent.length, 1); assert.equal(recovering.sent[0].content, reference);
    assert(!JSON.stringify(recovering.generated.at(-1)).includes(retiredGeneric));
  });
  await test('K03 停用来源不再进入模型，不因旧检索结果误记命中', async () => {
    const f = fixture('disabled'); f.mapping.documents=[]; f.write('data/runtime/knowledge-map.json', f.mapping); f.fragments=[];
    f.applyKnowledgeSettings(0.2);
    await f.deliver(f.event('session_knowledge-disabled', question));
    assert.equal(f.queries.length, 1);
    assert(!JSON.stringify(f.generated).includes(reference));
    assert.equal(f.generated.length, 0); assert.equal(f.sent.length, 0);
    const unresolved=f.state('session_knowledge-disabled').jobs.find(job=>job.responsibility_status==='unresolved_failure');
    assert.equal(unresolved?.failure_code,'knowledge_miss');
    assert.equal(f.state('session_knowledge-disabled').mode, 'ai');
  });
  await test('K04 检索HTTP200错误结构不进入模型、不伪造成未命中', async () => {
    const f = fixture('invalid'); f.applyKnowledgeSettings(0.2); f.retrievalResponse = {error: 'synthetic-search-failure'};
    await f.deliver(f.event('session_knowledge-invalid', question));
    assert.equal(f.queries.length, 1); assert.equal(f.generated.length, 0); assert.equal(f.sent.length, 0);
    assert.equal(f.state('session_knowledge-invalid').jobs.some(job=>job.responsibility_status==='unresolved_failure'),true);
    assert.equal(f.state('session_knowledge-invalid').mode, 'ai');
  });
  await test('K05 检索过程中真人介入，A不推理不出站而B继续', async () => {
    const f = fixture('human'); f.applyKnowledgeSettings(0.2);
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
    const f = fixture('complete'); f.applyKnowledgeSettings(0.2); const filler = '这是虚构展馆的无关历史说明。'.repeat(400);
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
      ['knowledge-lexical.json', 'knowledge-map.json', 'knowledge-profile.json', 'knowledge-settings.json']);
    assert.deepEqual(fs.readdirSync(path.join(f.root, 'data/analytics')), []);
  });
  await test('K09 管理员检索期间配置换代，不能用旧Prompt续模型或写客户消息', async () => {
    const f = fixture('admin-cancelled', true);
    f.applyKnowledgeSettings(0.2);
    f.beforeRetrievalResponse = async () => {
      const materials = f.read('config/materials-applied.json');
      materials.revision = 2; materials.configuration.runtime.revision = 2; materials.configuration.runtime.applied_revision = 2;
      f.publishMaterials(materials);
    };
    await assert.rejects(f.admin(question), /未完成/);
    assert.equal(f.queries.length, 1); assert.equal(f.generated.length, 0); assert.equal(f.sent.length, 0);
  });
  await test('K10 空知识映射允许缺少或保留同代profile，管理员连接探测仍不冒充知识命中', async () => {
    for (const profileForEmpty of [false, true]) {
      const label = profileForEmpty ? 'profile-present' : 'profile-absent';
      const f = fixture('admin-empty-' + label, true); f.installLexical([]);
      f.applyKnowledgeSettings(0.2, {profileForEmpty});
      f.providerAnswer = '这是一条无需业务资料即可确认的虚构连接结果。';
      const projection = f.read('config/materials-applied.json');
      const profileFile = path.join(f.root, 'data/runtime/knowledge-profile.json');
      assert.equal(projection.schema_version, 2);
      assert.deepEqual(Object.keys(projection.source_components).sort(), componentNames);
      assert.equal(projection.knowledge.enabled_document_count, 0);
      if (profileForEmpty) {
        const profile = JSON.parse(fs.readFileSync(profileFile, 'utf8'));
        assert.match(projection.knowledge.profile_sha256, /^[a-f0-9]{64}$/);
        assert.equal(projection.knowledge.profile_sha256, digest(fs.readFileSync(profileFile)));
        assert.equal(profile.fingerprint, digest(canonical(profile.profile)));
      } else {
        assert.equal(projection.knowledge.profile_sha256, '');
        assert.equal(fs.existsSync(profileFile), false);
      }
      assert.equal(projection.source_components.knowledge, digest(canonical(projection.knowledge)));
      const result = await f.admin('这是一条虚构连接探测问题。');
      assert.equal(result.verified, true); assert.equal(result.retrieval_state, 'knowledge_miss');
      assert.deepEqual(result.sources, []); assert.equal(f.generated.length, 1); assert.equal(f.sent.length, 0);
    }
  });
  await test('K11 已应用知识运行设置缺失或损坏时不回退读取工作区、不产生模型调用', async () => {
    const cases = [
      ['missing', f => fs.unlinkSync(path.join(f.root, 'data/runtime/knowledge-settings.json'))],
      ['tampered', f => f.write('data/runtime/knowledge-settings.json', {schema_version: 1, workspace_slug: 'synthetic-knowledge', temperature: 'bad'})],
    ];
    for (const [label, mutate] of cases) {
      const f = fixture('invalid-settings-' + label, true);
      f.applyKnowledgeSettings(0.2);
      mutate(f);
      await assert.rejects(f.admin(question), /未完成/);
      assert.equal(f.workspaceReads, 0); assert.equal(f.queries.length, 0);
      assert.equal(f.generated.length, 0); assert.equal(f.sent.length, 0);
    }
  });
  await test('K12 已应用温度投影避免每条咨询下载完整工作区，篡改时阻止推理', async () => {
    const f = fixture('projected-temperature'); f.applyKnowledgeSettings(0.35);
    await f.deliver(f.event('session_knowledge-projected', question));
    assert.equal(f.workspaceReads, 0); assert.equal(f.generated[0].temperature, 0.35); assert.equal(f.sent[0].content, reference);
    f.write('data/runtime/knowledge-settings.json', {schema_version: 1, workspace_slug: 'synthetic-knowledge', temperature: 0.7, observed_at: Date.now()});
    await f.deliver(f.event('session_knowledge-tampered', question));
    assert.equal(f.workspaceReads, 0); assert.equal(f.generated.length, 1); assert.equal(f.sent.length, 1);
    const pending=f.state('session_knowledge-tampered').jobs.find(job=>!['done','cancelled'].includes(job.status));
    assert(pending,'知识同代门禁失败时原问题必须保留，不能发固定澄清后结题');
    assert.notEqual(pending.responsibility_status,'answered_confirmed');
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
      ['wrong-workspace-resealed', f => {
        const file = path.join(f.root, 'data/runtime/knowledge-settings.json');
        f.write('data/runtime/knowledge-settings.json', {schema_version: 1, workspace_slug: 'another-synthetic-workspace', temperature: 0.35, observed_at: Date.now()});
        const materials = f.read('config/materials-applied.json');
        materials.knowledge.settings_sha256 = digest(fs.readFileSync(file));
        f.publishMaterials(materials);
      }],
      ['profile-body-fingerprint-mismatch-resealed', f => {
        const file = path.join(f.root, 'data/runtime/knowledge-profile.json');
        const value = JSON.parse(fs.readFileSync(file)); value.profile.chunk_size += 1;
        fs.writeFileSync(file, JSON.stringify(value), {mode: 0o600});
        const materials = f.read('config/materials-applied.json');
        materials.knowledge.profile_sha256 = digest(fs.readFileSync(file));
        f.publishMaterials(materials);
      }],
      ['stale-migration', f => f.write('data/runtime/knowledge-migration.json', {schema_version: 1, backup: '/synthetic/not-used'})],
      ['migration-directory', f => fs.mkdirSync(path.join(f.root, 'data/runtime/knowledge-migration.json'))],
    ];
    for (const [label, mutate] of cases) {
      const f = fixture('admin-readiness-' + label, true); f.applyKnowledgeSettings(0.35); mutate(f);
      await assert.rejects(f.admin(question), error => {
        assert.equal(error.code,'materials_not_ready',label+' 必须明确归为资料未就绪');
        return true;
      });
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
  await test('K15 管理员technical_unresolved按实际失败类别拒绝，绝不以空正文verified返回', async () => {
    const cases = [
      ['authentication', {status: 401, body: {error: {message: 'synthetic authentication failure'}}}, null, 'authentication_failed'],
      ['model', {status: 404, body: {error: {message: 'synthetic model failure'}}}, null, 'model_unavailable'],
      ['upstream', {status: 503, body: {error: {message: 'synthetic upstream failure'}}}, null, 'upstream_unavailable'],
      ['empty', {status: 200, body: {choices: []}}, null, 'invalid_response'],
      ['error-json', {status: 200, body: {error: {message: 'synthetic protocol failure'}}}, null, 'invalid_response'],
      ['protocol-error', {status: 400, body: {error: {code: 'protocol_error', message: 'synthetic adapter detail'}}}, null, 'protocol_error'],
      ['question-timeout', {status: 504, body: {error: {code: 'question_timeout', message: 'synthetic deadline detail'}}}, null, 'question_timeout'],
      ['question-interrupted', {status: 503, body: {error: {code: 'question_interrupted', message: 'synthetic owner detail'}}}, null, 'question_interrupted'],
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
  await test('K17 完整索引中唯一严格FAQ直接发送完整答案，不调用向量或Provider', async () => {
    const f = fixture('faq-direct');
    const exactQuestion = '曜石展柜周日开启吗？';
    const directAnswer = '周日不开放曜石展柜。\n周一至周六可凭虚构蓝羽票进入。';
    f.installLexical([`问题：${exactQuestion}\n回答：${directAnswer}\n`]);
    f.applyKnowledgeSettings(0.2);
    await f.deliver(f.event('session_knowledge-faq-direct', exactQuestion));
    assert.equal(f.queries.length, 0, '唯一严格FAQ不得额外调用向量服务');
    assert.equal(f.generated.length, 0, '唯一严格FAQ不得消耗Provider');
    assert.equal(f.sent.length, 1);
    assert.equal(f.sent[0].content, directAnswer, '多行答案必须完整直答，不能只发问题块或截成第一行');
    const job=f.state('session_knowledge-faq-direct').jobs.at(-1);
    assert.equal(job.status,'done'); assert.equal(job.responsibility_status,'answered_confirmed');
    assert.equal(digest(f.sent[0].content),digest(directAnswer),'访客收到的正文哈希必须与已签名严格FAQ答案一致');
  });
  await test('K18 严格同问冲突只允许一次受控Provider收敛，失败或退役泛问保留未完成责任', async () => {
    const conflictQuestion = '虚构月桥周三开放吗？';
    const first = '虚构月桥周三开放。';
    const second = '虚构月桥周三维护关闭。';
    const reviewed = '当前两条虚构规则存在冲突，需要先确认采用哪一版规则。';
    const contents = [`问：${conflictQuestion}\n答：${first}\n`, `问题：${conflictQuestion}\n回答：${second}\n`];
    const success = fixture('faq-conflict-success');
    success.installLexical(contents); success.providerAnswer=reviewed; success.applyKnowledgeSettings(0.2);
    await success.deliver(success.event('session_knowledge-faq-conflict-success', conflictQuestion));
    assert.equal(success.generated.length,1,'冲突FAQ只允许一次受控模型收敛，不能走直答');
    assert(JSON.stringify(success.generated[0]).includes(first));
    assert(JSON.stringify(success.generated[0]).includes(second));
    assert.equal(success.sent.length,1); assert.equal(success.sent[0].content,reviewed);
    assert(![first,second].includes(success.sent[0].content),'不得按排序任取一条冲突答案');

    const unavailable = fixture('faq-conflict-provider-unavailable');
    unavailable.installLexical(contents); unavailable.applyKnowledgeSettings(0.2);
    unavailable.providerResponse={status:503,body:{error:{message:'synthetic upstream unavailable'}}};
    const unavailableResult=await unavailable.deliver(unavailable.event('session_knowledge-faq-conflict-unavailable',conflictQuestion));
    assert.equal(unavailable.generated.length,1); assert.equal(unavailable.sent.length,0);
    assert(JSON.stringify(unavailable.generated[0]).includes(first)); assert(JSON.stringify(unavailable.generated[0]).includes(second));
    assert.equal(unavailableResult.status,'unresolved');
    const unavailableJob=unavailable.state('session_knowledge-faq-conflict-unavailable').jobs.at(-1);
    assert.equal(unavailableJob.status,'received'); assert.equal(unavailableJob.responsibility_status,'unresolved_failure');
    assert.equal(unavailableJob.failure_code,'upstream_unavailable'); assert(unavailableJob.data?.content);

    const retired = fixture('faq-conflict-retired-generic');
    retired.installLexical(contents); retired.applyKnowledgeSettings(0.2);
    retired.providerAnswer='现有资料还不足以确定答案，请补充更多细节。';
    const retiredResult=await retired.deliver(retired.event('session_knowledge-faq-conflict-retired',conflictQuestion));
    assert.equal(retired.generated.length,1); assert.equal(retired.sent.length,0);
    assert.equal(retiredResult.status,'unresolved');
    const retiredJob=retired.state('session_knowledge-faq-conflict-retired').jobs.at(-1);
    assert.equal(retiredJob.status,'received'); assert.equal(retiredJob.responsibility_status,'unresolved_failure');
    assert.equal(retiredJob.failure_code,'invalid_response'); assert(retiredJob.data?.content);
  });
  await test('K19 低向量分数只标记证据强弱，不覆盖Provider依据当前片段返回的正确答案', async () => {
    const f = fixture('weak-vector'); f.fragments[0].distance=0.99; f.fragments[0].score=0.01;
    f.applyKnowledgeSettings(0.2); f.providerAnswer=reference;
    await f.deliver(f.event('session_knowledge-weak-vector', '请说明虚构展厅周日安排。'));
    assert.equal(f.queries.length,1); assert.equal(f.generated.length,1);
    assert(JSON.stringify(f.generated[0]).includes(reference),'低分片段仍须真实进入本次模型上下文');
    assert.equal(f.sent.length,1); assert.equal(f.sent[0].content,reference);
    assert.equal(f.state('session_knowledge-weak-vector').jobs.at(-1).responsibility_status,'answered_confirmed');
  });
  await test('K20 要求来源但检索为空时不调用已退役fallback、不发泛问并保留未完成责任', async () => {
    const f = fixture('knowledge-miss'); f.fragments=[]; f.applyKnowledgeSettings(0.2);
    const result=await f.deliver(f.event('session_knowledge-miss', '虚构银杉花园的闭馆日是哪天？'));
    assert.equal(f.queries.length,1); assert.equal(f.generated.length,0); assert.equal(f.sent.length,0);
    assert.equal(result.status,'unresolved');
    const job=f.state('session_knowledge-miss').jobs.at(-1);
    assert.equal(job.status,'received'); assert.equal(job.responsibility_status,'unresolved_failure');
    assert.equal(job.failure_code,'knowledge_miss','明确分类可证明没有落入悬空defaultClarification或通用异常');
    assert(job.data?.content,'原始问题必须保留供资料恢复后续做');
  });
  await test('K21 缺少materials投影时客服与管理员都不得读取原始配置假装ready', async () => {
    const customer=fixture('missing-materials-customer');
    const accepted=await customer.deliver(customer.event('session_knowledge-no-materials',question));
    assert.equal(accepted.route,'ignore','未就绪任务已持久延后，不得进入当前处理链');
    assert.equal(customer.queries.length,0); assert.equal(customer.generated.length,0); assert.equal(customer.sent.length,0);
    const pending=customer.state('session_knowledge-no-materials').jobs.at(-1);
    assert.equal(pending.status,'received'); assert.equal(pending.deferred_configuration,true);
    assert.notEqual(pending.responsibility_status,'answered_confirmed');

    const administrator=fixture('missing-materials-admin',true);
    await assert.rejects(administrator.admin(question), error => {
      assert.equal(error.code, 'materials_not_ready');
      return true;
    });
    assert.equal(administrator.queries.length,0); assert.equal(administrator.generated.length,0); assert.equal(administrator.sent.length,0);
  });
  await test('K22 schema v2 拒绝内嵌组件、知识聚合和外层来源的分层篡改', async () => {
    const cases = [
      ['embedded-component', materials => { materials.configuration.runtime.enabled = false; }],
      ['knowledge-aggregate', materials => { materials.knowledge.catalog_sha256 = 'f'.repeat(64); }],
      ['source-component', materials => {
        materials.source_components.knowledge = 'e'.repeat(64);
        materials.source_sha256 = digest(canonical(materials.source_components));
      }],
    ];
    for (const [label, mutate] of cases) {
      const f = fixture('materials-tamper-' + label, true); f.applyKnowledgeSettings(0.2);
      const before = f.read('config/materials-applied.json');
      mutate(before); f.write('config/materials-applied.json', before);
      await assert.rejects(f.admin(question), /投影|资料/);
      assert.equal(f.queries.length, 0, label + ' 不得越过同代门禁调用检索');
      assert.equal(f.generated.length, 0, label + ' 不得越过同代门禁调用 Provider');
      assert.equal(f.sent.length, 0, label + ' 不得产生客户出站');
    }
  });
  await test('K23 first_message欢迎开启时严格FAQ仍逐字直答，多字节不超限且下一问不迟到补欢迎', async () => {
    const f=fixture('faq-direct-first-welcome');
    const firstQuestion='蓝羽章展厅的完整多字节说明是什么？';
    const prefix='多字节答案：';
    const firstAnswer=prefix+'蓝'.repeat(2600)+'🙂';
    const secondQuestion='蓝羽章展厅的复核标识是什么？';
    const secondAnswer='复核标识为虚构星环-73。';
    assert(Buffer.byteLength(firstAnswer,'utf8')>7800&&Buffer.byteLength(firstAnswer,'utf8')<=8000);
    f.installLexical([`问题：${firstQuestion}\n回答：${firstAnswer}\n`, `问：${secondQuestion}\n答：${secondAnswer}\n`]);
    const menu=f.read('config/menu.yaml');
    Object.assign(menu.welcome,{enabled:true,trigger:'first_message',show_menu:true,text:'这条虚构欢迎不得拼入签名FAQ答案。'});
    f.write('config/menu.yaml',menu); f.applyKnowledgeSettings(0.2);
    await f.deliver(f.event('session_knowledge-faq-welcome',firstQuestion));
    assert.equal(f.queries.length,0); assert.equal(f.generated.length,0); assert.equal(f.sent.length,1);
    assert.equal(f.sent[0].content,firstAnswer); assert.equal(Buffer.byteLength(f.sent[0].content,'utf8'),Buffer.byteLength(firstAnswer,'utf8'));
    let state=f.state('session_knowledge-faq-welcome');
    assert.equal(state.welcome_sent,true,'首问严格FAQ已满足欢迎，不得在下一问迟到补发');
    await f.deliver(f.event('session_knowledge-faq-welcome',secondQuestion));
    assert.equal(f.queries.length,0); assert.equal(f.generated.length,0); assert.equal(f.sent.length,2);
    assert.equal(f.sent[1].content,secondAnswer); assert(!f.sent.some(item=>String(item.content).includes(menu.welcome.text)));
    state=f.state('session_knowledge-faq-welcome'); assert.equal(state.welcome_sent,true);
  });
  await test('K24 首问生成答案接近字节上限时保留完整答案，不为拼欢迎静默截断', async () => {
    const f=fixture('generated-first-welcome-limit');
    const generatedAnswer='完整生成答案：'+'蓝'.repeat(2650);
    assert(Buffer.byteLength(generatedAnswer,'utf8')<=8000);
    f.providerAnswer=generatedAnswer;
    const menu=f.read('config/menu.yaml');
    Object.assign(menu.welcome,{enabled:true,trigger:'first_message',show_menu:true,text:'这条虚构欢迎会使合并正文超过字节上限。'});
    assert(Buffer.byteLength(menu.welcome.text+'\n\n'+generatedAnswer,'utf8')>8000);
    f.write('config/menu.yaml',menu); f.applyKnowledgeSettings(0.2);
    await f.deliver(f.event('session_knowledge-generated-welcome-limit','请介绍虚构展厅的周日安排。'));
    assert.equal(f.generated.length,1); assert.equal(f.sent.length,1);
    assert.equal(f.sent[0].content,generatedAnswer);
    assert.equal(Buffer.byteLength(f.sent[0].content,'utf8'),Buffer.byteLength(generatedAnswer,'utf8'));
    const state=f.state('session_knowledge-generated-welcome-limit');
    assert.equal(state.welcome_sent,true); assert.equal(state.jobs.at(-1).responsibility_status,'answered_confirmed');
  });
  await test('K25 不完整词法索引与向量失败同时出现时零可见出站并保留原问题责任', async () => {
    const f=fixture('faq-incomplete-vector-failure');
    const exactQuestion='虚构星河展馆周五开放吗？';
    const exactAnswer='虚构星河展馆周五只在蓝羽时段开放。';
    const oversized='问：另一份虚构资料的超长答案是什么？\n答：'
      +'虚构长段。'.repeat(40000)+'\n';
    const index=f.installLexical([`问：${exactQuestion}\n答：${exactAnswer}\n`,oversized]);
    assert.equal(index.complete,false); f.applyKnowledgeSettings(0.2);
    f.retrievalResponse={results:'synthetic-invalid-vector-results'};
    const result=await f.deliver(f.event('session_knowledge-incomplete-vector-failure',exactQuestion));
    assert.equal(f.queries.length,1); assert.equal(f.generated.length,0); assert.equal(f.sent.length,0);
    assert.equal(result.status,'unresolved');
    const job=f.state('session_knowledge-incomplete-vector-failure').jobs.at(-1);
    assert.equal(job.status,'received'); assert.equal(job.responsibility_status,'unresolved_failure');
    assert.equal(job.failure_code,'retrieval_invalid'); assert(job.data?.content);
  });
  await test('K26 Crisp 2xx回执显式返回错误fingerprint时不得记为已回答', async () => {
    const f=fixture('crisp-receipt-fingerprint-mismatch'); f.applyKnowledgeSettings(0.2);
    f.crispPostResponse=entry=>({status:200,body:{error:false,reason:'dispatched',
      data:{fingerprint:Number(entry.fingerprint)+1}}});
    const result=await f.deliver(f.event('session_knowledge-crisp-mismatch',question));
    assert.equal(f.generated.length,1); assert.equal(f.sent.length,1);
    assert.equal(result.status,'retry');
    const state=f.state('session_knowledge-crisp-mismatch');
    const job=state.jobs.at(-1);
    assert.equal(job.status,'received'); assert.equal(job.responsibility_status,'pending');
    assert.equal(Object.values(state.outgoing).length,1);
    assert.equal(Object.values(state.outgoing)[0].status,'unknown');
  });
  const directiveFromRequest = request => {
    const message=request.messages.find(item=>item.role==='system'&&item.content.includes('{"directive":'));
    assert(message,'当前模型请求必须含咨询方向');
    return JSON.parse(message.content.slice(message.content.indexOf('{"directive":'))).directive;
  };
  const directiveVariants = [
    ['boundary-1800','a'.repeat(1800-'SYNTHETIC-DIRECTIVE-TAIL'.length)+'SYNTHETIC-DIRECTIVE-TAIL'],
    ['unicode-long','已提供合成背景🙂。'.repeat(250)+'不得删除末尾约束：SYNTHETIC-UNICODE-TAIL'],
    ['byte-limit-10000','b'.repeat(10000-'SYNTHETIC-MAXIMUM-TAIL'.length)+'SYNTHETIC-MAXIMUM-TAIL'],
  ];
  const assertDirective = (f,entry,variant,directive) => {
    assert.equal(f.generated.length,1,'必须实际走当前生产知识生成模块');
    const actual=directiveFromRequest(f.generated[0]);
    console.log('观察合成提示词：'+JSON.stringify({entry,variant,
      configured_characters:directive.length,configured_bytes:Buffer.byteLength(directive),
      provider_characters:actual.length,provider_bytes:Buffer.byteLength(actual),
      exact_preserved:actual===directive,tail_preserved:actual.endsWith(directive.slice(-35))}));
    assert.equal(actual,directive,'已接受的局部提示词必须完整进入当前Provider请求');
    assert.equal(f.sent.filter(item=>item.type==='text').length,1);
    assert.equal(f.sent.find(item=>item.type==='text').content,reference);
  };
  await test('K27 关键词局部提示词保持1800边界、中文Emoji和10000字节尾部', async () => {
    for (const [variant,directive] of directiveVariants) {
      assert(Buffer.byteLength(directive)<=10000);
      const f=fixture('directive-keyword-'+variant);
      f.write('config/keyword.yaml',{schema_version:2,rules:[{id:'synthetic-directive',
        name:'合成提示词完整性',enabled:true,match_mode:'exact',keywords:['合成提示词咨询'],
        exclude_keywords:[],priority:50,action:'prompt',prompt:directive,cooldown_seconds:0}]});
      f.applyKnowledgeSettings(0.2);
      const session='session_directive-keyword-'+variant;
      const result=await f.deliver(f.event(session,'合成提示词咨询'));
      assertDirective(f,'keyword',variant,directive);
      const job=f.state(session).jobs.find(item=>item.id===result.jobId);
      assert.equal(job.status,'done'); assert.equal(job.responsibility_status,'answered_confirmed');
    }
  });
  await test('K28 菜单实际选择完整保留局部提示词且重复点击不重复发送', async () => {
    for (const [variant,directive] of directiveVariants) {
      assert(Buffer.byteLength(directive)<=10000);
      const f=fixture('directive-menu-'+variant);
      f.write('config/keyword.yaml',{schema_version:2,rules:[]});
      const menu=f.read('config/menu.yaml');
      menu.root='main';menu.menus={main:{title:'合成完整性菜单',options:{
        '1':{label:'合成展厅咨询',action:{type:'prompt',prompt:directive}}}}};
      f.write('config/menu.yaml',menu);f.applyKnowledgeSettings(0.2);
      const session='session_directive-menu-'+variant;
      await f.deliver(f.event(session,'菜单'));
      assert.equal(f.sent.length,1); assert.equal(f.sent[0].type,'picker');
      assert.equal(f.generated.length,0,'仅展示菜单不应调用模型');
      const card=f.sent[0];
      const event={website_id:'11111111-1111-4111-8111-111111111111',
        event:'message:updated',timestamp:Date.now(),data:{session_id:session,
        type:'picker',from:'user',fingerprint:card.fingerprint,timestamp:Date.now(),
        content:{...structuredClone(card.content),choices:card.content.choices.map((choice,index)=>({...choice,selected:index===0}))}}};
      const result=await f.deliver(event);
      assertDirective(f,'menu',variant,directive);
      const state=f.read('data/runtime/session-'+f.key(session)+'.json');
      const job=state.jobs.find(item=>item.id===result.jobId);
      assert.equal(job.status,'done'); assert.equal(job.responsibility_status,'control_handled');
      const deliveries=Object.values(state.outgoing).filter(item=>item.job_id===job.id&&item.purpose==='ai_text');
      assert.equal(deliveries.length,1);assert.equal(deliveries[0].status,'sent');
      assert.equal(deliveries[0].semantic_intent,'control');
      assert.equal(deliveries[0].semantic_status,'control_delivered');
      await f.deliver(event);
      assert.equal(f.generated.length,1);assert.equal(f.sent.filter(item=>item.type==='text').length,1);
    }
  });
  console.log(JSON.stringify({layer: 'UNIT/PROTOCOL', passed, failed}));
  process.exitCode = failed ? 1 : 0;
})().catch(error => {console.error(error.stack); process.exitCode = 1;});
