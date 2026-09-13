'use strict';

// 虚构 FAQ：实际构建索引并执行生产 runtime/生成 Code；HTTP 为严格协议夹具，非真实召回或模型能力。
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const {spawnSync} = require('node:child_process');
const {isBuiltin} = require('node:module');
const {createRuntime} = require('../n8n/runtime');
const {searchKnowledgeLexical} = require('../n8n/knowledge-lexical');
const project = path.resolve(__dirname, '..');
const area = path.join(project, '.work/v1.2.1');
fs.mkdirSync(area, {recursive:true});
const evidence = fs.mkdtempSync(path.join(area, 'knowledge-hybrid-'));
const hash = value => crypto.createHash('sha256').update(value).digest('hex');
const canonical = value => JSON.stringify(value, (_key, item) => item && typeof item === 'object' && !Array.isArray(item)
  ? Object.fromEntries(Object.keys(item).sort().map(key => [key, item[key]])) : item);
const question = '曜石灯塔补给箱的启封口令是什么？';
const overlapQuestion = '曜石灯塔补给箱 启封口令';
const answer = '启封口令是翠羽环-4831，核对箱体编号后使用。';
const qa = '问：' + question + '\n答：' + answer + '\n';
const pairedQuestion = '能寄存苍蓝行李箱吗？可以存放苍蓝行李箱吗？';
const pairedAnswer = '仅可寄存带有虚构蓝羽标记的行李箱。';
const pairedQa = '问题：' + pairedQuestion + '\n回答：' + pairedAnswer + '\n';
const clarification = '你最希望先解决哪一处？可以把具体情况、相关提示和已经尝试的方法一起告诉我。';
const AsyncFunction = Object.getPrototypeOf(async function(){}).constructor;

function fixture(label, options={}) {
  const root = path.join(evidence, label);
  for(const name of ['config', 'data/runtime', 'data/analytics', 'data/anythingllm/documents/custom-documents'])
    fs.mkdirSync(path.join(root, name), {recursive:true});
  const write = (name, value) => fs.writeFileSync(path.join(root, name), typeof value === 'string' ? value : JSON.stringify(value), {mode:0o600});
  const raw = name => fs.readFileSync(path.join(root, name), 'utf8');
  const read = name => JSON.parse(raw(name));
  for(const name of ['menu', 'keyword', 'handoff', 'tags', 'feedback'])
    fs.copyFileSync(path.join(project, 'config', name + '.yaml.example'), path.join(root, 'config', name + '.yaml'));
  const menu = read('config/menu.yaml'); menu.welcome.enabled = false; write('config/menu.yaml', menu);
  write('config/runtime.yaml', {schema_version:2, revision:1, applied_revision:1, enabled:true});
  write('config/provider.yaml', {provider:{base_url:'https://provider.invalid/v1', model:'synthetic-hybrid', api_mode:'chat_completions'}});
  const prompt = '只依据当前启用资料中的相关事实回答；缺少信息时提出具体澄清，不猜测口令。';
  write('config/prompt.md', prompt);
  const documents = (options.contents || [qa]).map((content, index) => {
    const id = (index + 1).toString(16).padStart(16, '0');
    const projection = 'kb_1111111111111111_doc_' + id + '.md';
    const item = {library_id:'kb_1111111111111111', library_name:'虚构灯塔资料', document_id:'doc_' + id,
      projection, location:'custom-documents/' + projection + '.json'};
    if(options.sameDocument && index) {
      item.document_id = 'doc_0000000000000001';
      item.projection = 'kb_1111111111111111_doc_0000000000000001.md';
    }
    write('data/anythingllm/documents/' + item.location, {pageContent:content, title:item.projection});
    return item;
  });
  write('data/runtime/knowledge-map.json', {schema_version:2, revision:1, documents});
  const build = spawnSync('python3', [path.join(project, 'scripts/knowledge-lexical.py'), 'build', '--deploy-dir', root],
    {encoding:'utf8', timeout:30000});
  assert.equal(build.status, 0, build.stdout + build.stderr); assert.equal(JSON.parse(build.stdout).ok, true);
  const index = () => read('data/runtime/knowledge-lexical.json');
  const search = query => searchKnowledgeLexical({query, index:index(), mapRaw:raw('data/runtime/knowledge-map.json')});
  const env = {CRISP_WEBSITE_ID:'11111111-1111-4111-8111-111111111111', CRISP_WEBSITE_HOOK_SECRET:'synthetic-hybrid-hook-secret',
    CRISP_AUTH_B64:'synthetic-hybrid-crisp-auth', AI_API_KEY:'synthetic-hybrid-provider-key',
    ANYTHINGLLM_API_KEY:'synthetic-hybrid-knowledge-key', ANYTHINGLLM_WORKSPACE:'synthetic-hybrid'};
  write('data/runtime/knowledge-settings.json', {schema_version:1, workspace_slug:env.ANYTHINGLLM_WORKSPACE, temperature:0.23});
  const configuration = {};
  for(const name of ['runtime', 'handoff', 'keyword', 'menu', 'tags', 'feedback']) configuration[name] = read('config/' + name + '.yaml');
  const applied = {schema_version:1, state:'applied', revision:1, applied_at:Date.now(), source_sha256:'a'.repeat(64),
    source_components:{}, configuration, prompt:{text:prompt, bytes:Buffer.byteLength(prompt), sha256:hash(prompt)},
    knowledge:{map_sha256:hash(raw('data/runtime/knowledge-map.json')), settings_sha256:hash(raw('data/runtime/knowledge-settings.json'))}};
  if(options.legacy !== true) applied.knowledge.lexical_sha256 = hash(raw('data/runtime/knowledge-lexical.json'));
  write('config/materials-applied.json', applied);
  const f = {root, env, prompt, documents, write, raw, read, index, search, vector:[], generated:[], sent:[],
    history:new Map(), metadata:new Map(), workspaceReads:0, violations:[], vectorResponse:{status:200, body:{results:[]}}};
  const strict = check => {try {return check();} catch(error) {f.violations.push(error.message); throw error;}};
  const request = async (url, request={}) => {
    const parsed = new URL(url);
    if(parsed.hostname === 'anythingllm') {
      strict(() => {
        assert.equal(parsed.pathname, '/api/v1/workspace/' + env.ANYTHINGLLM_WORKSPACE + '/vector-search');
        assert.equal(request.method, 'POST');
        assert.deepEqual(Object.keys(request.body), ['query']);
        assert.equal(typeof request.body.query, 'string');
        assert.equal(request.headers.Authorization, 'Bearer ' + env.ANYTHINGLLM_API_KEY);
        assert(request.timeout > 0 && request.timeout <= 15000);
      });
      if(request.method === 'GET') f.workspaceReads++;
      f.vector.push(structuredClone(request.body));
      if(f.beforeVectorResponse) await f.beforeVectorResponse();
      if(f.vectorError) throw f.vectorError;
      return structuredClone(f.vectorResponse);
    }
    if(parsed.hostname === 'provider.invalid') {
      strict(() => {
        assert.equal(parsed.pathname, '/v1/chat/completions'); assert.equal(request.method, 'POST');
        assert.equal(request.headers.Authorization, 'Bearer ' + env.AI_API_KEY);
        assert.equal(request.body.model, 'synthetic-hybrid'); assert.equal(request.body.temperature, 0.23);
        assert.equal(request.body.stream, false); assert.equal(request.body.messages[0].content, prompt);
        assert.equal(request.body.messages.at(-1).role, 'user');
      });
      f.generated.push(structuredClone(request.body));
      if(f.beforeModelResponse) await f.beforeModelResponse();
      return {status:200, body:{choices:[{message:{role:'assistant', content:answer}}]}};
    }
    const match = parsed.pathname.match(/^\/v1\/website\/[^/]+\/conversation\/([^/]+)(\/.*)$/);
    strict(() => {assert.equal(parsed.hostname, 'api.crisp.chat'); assert(match);});
    const session = match[1], suffix = match[2], history = f.history.get(session) || [];
    if(suffix === '/messages') {
      strict(() => assert.equal(request.method, 'GET'));
      return {status:200, body:{error:false, data:history}};
    }
    if(suffix === '/meta') {
      strict(() => assert(['GET', 'PATCH'].includes(request.method)));
      if(request.method === 'PATCH') f.metadata.set(session, structuredClone(request.body));
      return {status:200, body:{error:false, data:f.metadata.get(session) || {segments:[]}}};
    }
    strict(() => {assert.equal(suffix, '/message'); assert.equal(request.method, 'POST'); assert.equal(request.body.from, 'operator');});
    const message = {...structuredClone(request.body), session_id:session, timestamp:Date.now()};
    f.sent.push(message); history.push(message); f.history.set(session, history);
    return {status:200, body:{error:false, reason:'dispatched', data:{fingerprint:message.fingerprint}}};
  };
  f.runtime = createRuntime(env, {root, request});
  f.runtimeOptions = {root, request};
  let sequence = 9000;
  f.event = (session, content=question, overrides={}) => ({website_id:env.CRISP_WEBSITE_ID, event:'message:send', timestamp:Date.now(),
    data:{session_id:session, from:'user', type:'text', content, fingerprint:++sequence, timestamp:Date.now(), ...overrides}});
  f.remember = event => {
    const history = f.history.get(event.data.session_id) || []; history.push(structuredClone(event.data)); f.history.set(event.data.session_id, history);
  };
  f.receive = async event => {
    f.remember(event);
    const result = await f.runtime.receive({body:event, query:{key:env.CRISP_WEBSITE_HOOK_SECRET}});
    assert.equal(result.accepted, true, JSON.stringify(result)); assert.equal(result.statusCode, 200);
    return result;
  };
  f.deliver = async event => {
    const accepted = await f.receive(event);
    const result = accepted.route === 'process' ? await f.runtime.process(accepted.key, accepted.jobId) : accepted;
    assert.deepEqual(f.violations, []); return {accepted, result};
  };
  f.state = session => f.runtime.readState(f.runtime.stateKey(env.CRISP_WEBSITE_ID, session));
  f.events = () => {
    const file = path.join(root, 'data/analytics/events.jsonl');
    return fs.existsSync(file) ? fs.readFileSync(file, 'utf8').trim().split('\n').filter(Boolean).map(line => JSON.parse(line)) : [];
  };
  f.rebind = patch => {const current = read('config/materials-applied.json'); patch(current); write('config/materials-applied.json', current);};
  f.vectorResult = (text, index=0, id='synthetic-vector-result') => ({id, text,
    metadata:{title:documents[index].projection, docpath:documents[index].location}, distance:0.1});
  return f;
}

function citations(body) {
  const message = body.messages.find(item => item.role === 'system' && item.content.includes('\n{"knowledge":'));
  assert(message, '生成请求必须含完整知识引用');
  return JSON.parse(message.content.slice(message.content.indexOf('\n') + 1)).knowledge;
}
function successful(f, session, vectorCount=0) {
  assert.equal(f.vector.length, vectorCount); assert.equal(f.workspaceReads, 0);
  assert.equal(f.generated.length, 1); assert.equal(f.sent.length, 1); assert.equal(f.sent[0].content, answer);
  assert.equal(f.sent[0].session_id, session);
  assert.equal(f.state(session).mode, 'ai');
  assert(f.state(session).jobs.every(job => job.status === 'done'));
  assert(Object.values(f.state(session).outgoing).every(outgoing => outgoing.status === 'sent'));
  assert.equal(f.events().filter(event => event.type === 'ai_reply').length, 1);
  assert.deepEqual(f.violations, []);
}
function blocked(f) {
  assert.equal(f.vector.length, 0); assert.equal(f.generated.length, 0); assert.equal(f.sent.length, 0);
  assert.equal(f.events().filter(event => event.type === 'ai_reply').length, 0);
  assert.deepEqual(f.violations, []);
}
function safeFailure(f) {
  assert.equal(f.generated.length, 0); assert.equal(f.sent.length, 1); assert.equal(f.sent[0].content, clarification);
  assert.equal(f.events().filter(event => event.type === 'ai_reply').length, 0);
  assert.equal(f.events().filter(event => event.type === 'retrieval_failed').length, 1);
  assert.deepEqual(f.violations, []);
}
function builtinResolver() {
  const match = fs.readFileSync(path.join(project, 'docker-compose.yml'), 'utf8').match(/^\s+NODE_FUNCTION_ALLOW_BUILTIN:\s*(\S+)\s*$/m);
  assert(match);
  // 固定 n8n 2.33.0 createRequireResolver 使用字面名称匹配，不剥离 node: 前缀。
  const allowed = new Set(match[1].split(',').map(name => name.trim()).filter(Boolean));
  return name => {
    if(!isBuiltin(name) || !allowed.has(name)) throw new Error('DisallowedModuleError: ' + name);
    return require(name);
  };
}

let passed = 0, failed = 0;
const cases = [];
async function test(name, action) {
  try {await action(); passed++; cases.push({name, passed:true}); console.log('通过 UNIT/PROTOCOL：' + name);}
  catch(error) {failed++; cases.push({name, passed:false}); console.error('失败 UNIT/PROTOCOL：' + name + '\n' + error.stack);}
}
(async () => {
  await test('H01 强词法命中保留长文末尾完整 FAQ，不调用向量且只生成一次', async () => {
    const f = fixture('strong-tail', {contents:['虚构灯塔建设年表。'.repeat(4000) + '\n' + qa]});
    assert.equal(f.search(question).results[0].lexical.kind, 'exact_question');
    f.vectorError = new Error('不应调用的向量服务');
    const session = 'session_hybrid-strong'; await f.deliver(f.event(session)); successful(f, session);
    const knowledge = citations(f.generated[0]); assert.equal(knowledge.length, 1); assert.equal(knowledge[0].text, qa);
    assert.equal(f.events().filter(event => event.type === 'knowledge_hit').length, 1);
  });
  await test('H02 关键词改写＋向量 miss 由绑定的中文 FAQ 补回，只生成一次', async () => {
    const f = fixture('vector-miss'); assert.equal(f.search(overlapQuestion).results[0].lexical.kind, 'keyword_overlap');
    const session = 'session_hybrid-miss'; await f.deliver(f.event(session, overlapQuestion)); successful(f, session, 1);
    assert.deepEqual(f.vector[0], {query:overlapQuestion}); assert.equal(citations(f.generated[0])[0].text, qa);
    assert.equal(f.events().filter(event => event.type === 'retrieval_degraded').length, 0);
  });
  await test('H03 向量 HTTP/网络/格式/未映射错误保留降级原因，只用有效词法并生成一次', async () => {
    const variants = ['http', 'network', 'shape', 'unmapped'];
    for(const variant of variants) {
      const f = fixture('vector-error-' + variant);
      if(variant === 'http') f.vectorResponse = {status:503, body:{error:'synthetic-vector-failure'}};
      if(variant === 'network') f.vectorError = new Error('synthetic-vector-disconnected');
      if(variant === 'shape') f.vectorResponse = {status:200, body:{results:'synthetic-invalid-results'}};
      if(variant === 'unmapped') f.vectorResponse = {status:200, body:{results:[{id:'unmapped', text:'未启用资料不能进入模型', metadata:{title:'synthetic-disabled.md'}}]}};
      const session = 'session_hybrid-error-' + variant; await f.deliver(f.event(session, overlapQuestion)); successful(f, session, 1);
      assert.equal(citations(f.generated[0]).length, 1); assert.equal(citations(f.generated[0])[0].text, qa);
      const degraded = f.events().filter(event => event.type === 'retrieval_degraded');
      assert.equal(degraded.length, 1); assert.equal(degraded[0].fallback, 'lexical'); assert(degraded[0].reason);
      assert.equal(f.events().filter(event => event.type === 'retrieval_failed').length, 0);
    }
  });
  await test('H04 向量/词法同源同正文去重，不吞掉另一条有效知识', async () => {
    const extra = '问：虚构珊瑚展架存放在哪里？\n答：存放在东侧蓝色储物间。\n';
    const f = fixture('dedup', {contents:[qa, extra]});
    const lexical = f.search(overlapQuestion).results; assert.equal(lexical.length, 1);
    f.vectorResponse = {status:200, body:{results:[f.vectorResult(lexical[0].text), f.vectorResult(extra, 1, 'synthetic-vector-extra')]}};
    const session = 'session_hybrid-dedup'; await f.deliver(f.event(session, overlapQuestion)); successful(f, session, 1);
    const knowledge = citations(f.generated[0]); assert.equal(knowledge.length, 2);
    assert.equal(knowledge.filter(item => item.text === qa).length, 1); assert.equal(knowledge.filter(item => item.text === extra).length, 1);
    assert.equal(new Set(knowledge.map(item => item.source.document_id)).size, 2);
  });
  await test('H05 真实构建 complete:false 仍可用已校验片段，不冒称完整覆盖', async () => {
    const f = fixture('partial', {contents:[qa, '问：巨型虚构仓库的完整记录是什么？\n答：' + '虚构长段。'.repeat(40000) + '\n']});
    assert.equal(f.index().complete, false); assert(f.index().coverage.omitted_bytes > 0);
    assert(f.index().coverage.reasons.includes('passage_too_large'));
    assert.equal(f.search(question).complete, false);
    const session = 'session_hybrid-partial'; await f.deliver(f.event(session)); successful(f, session);
    assert.deepEqual(citations(f.generated[0]).map(item => item.text), [qa]);
  });
  await test('H06 lexical/map 原字节和 materials 绑定 hash 篡改均在推理前阻断', async () => {
    for(const variant of ['index', 'map', 'material-lexical', 'material-map']) {
      const f = fixture('outer-tamper-' + variant);
      if(variant === 'index') f.write('data/runtime/knowledge-lexical.json', f.raw('data/runtime/knowledge-lexical.json') + '\n');
      if(variant === 'map') f.write('data/runtime/knowledge-map.json', f.raw('data/runtime/knowledge-map.json') + '\n');
      if(variant === 'material-lexical') f.rebind(current => {current.knowledge.lexical_sha256 = 'f'.repeat(64);});
      if(variant === 'material-map') f.rebind(current => {current.knowledge.map_sha256 = 'f'.repeat(64);});
      const session = 'session_hybrid-tamper-' + variant; const result = await f.deliver(f.event(session));
      assert.equal(result.accepted.route, 'ignore'); blocked(f); assert.equal(f.state(session).mode, 'ai');
    }
  });
  await test('H07 仅重绑外层 SHA 不能绕过 payload/片段/来源校验，不调用向量或模型', async () => {
    for(const variant of ['payload', 'text', 'source']) {
      const f = fixture('inner-tamper-' + variant), index = f.index();
      if(variant === 'payload') index.complete = !index.complete;
      if(variant === 'text') index.passages[0].text += '伪造片段';
      if(variant === 'source') index.passages[0].library_id = 'kb_ffffffffffffffff';
      if(variant !== 'payload') {delete index.payload_sha256; index.payload_sha256 = hash(canonical(index));}
      f.write('data/runtime/knowledge-lexical.json', index);
      f.rebind(current => {current.knowledge.lexical_sha256 = hash(f.raw('data/runtime/knowledge-lexical.json'));});
      await f.deliver(f.event('session_hybrid-inner-' + variant));
      assert.equal(f.vector.length, 0); safeFailure(f);
    }
  });
  await test('H08 map 新代即使外层已重绑，旧词法整份不可用且不回退旧资料', async () => {
    const f = fixture('stale-map'); const mapping = f.read('data/runtime/knowledge-map.json');
    mapping.revision++; mapping.documents[0].enabled = false;
    f.write('data/runtime/knowledge-map.json', mapping);
    f.rebind(current => {current.knowledge.map_sha256 = hash(f.raw('data/runtime/knowledge-map.json'));});
    await f.deliver(f.event('session_hybrid-stale')); assert.equal(f.vector.length, 0); safeFailure(f);
  });
  await test('H09 特定短问句仍可精确命中，泛问/不相关改写不能冒充词法语义召回', async () => {
    // 短问可以省略疑问尾词，但不能省略区分同类 FAQ 的实体限定。
    const short = '曜石灯塔补给箱的启封口令'; const exact = fixture('short-specific');
    assert.equal(exact.search(short).results[0].lexical.kind, 'exact_phrase');
    await exact.deliver(exact.event('session_hybrid-short', short)); successful(exact, 'session_hybrid-short');
    for(const [index, query] of ['口令', '补给箱的启封口令', '请问怎么办', '另一座银杉花园的停车时间是什么？', '那座海边建筑的物资容器怎么打开？'].entries()) {
      const f = fixture('generic-' + index); assert.deepEqual(f.search(query).results, []);
      await f.deliver(f.event('session_hybrid-generic-' + index, query));
      assert.equal(f.vector.length, 1); assert.equal(f.vector[0].query, query); assert.equal(f.generated.length, 0);
      assert.equal(f.sent.length, 1); assert.equal(f.sent[0].content, clarification);
      assert.equal(f.events().filter(event => event.type === 'knowledge_hit').length, 0);
    }
  });
  await test('H10 词法不擅长的语义改写仍走纯向量，实际有效来源可进入唯一生成', async () => {
    const f = fixture('semantic-vector'), query = '那座海边建筑的物资容器怎么打开？';
    assert.deepEqual(f.search(query).results, []);
    f.vectorResponse = {status:200, body:{results:[f.vectorResult(qa)]}};
    const session = 'session_hybrid-semantic'; await f.deliver(f.event(session, query)); successful(f, session, 1);
    assert.equal(citations(f.generated[0])[0].source.id, 'synthetic-vector-result');
    assert.equal(f.vector[0].query, query);
  });
  await test('H11 无 lexical 字段的旧投影仍只消费向量，不偷偷启用磁盘辅助索引', async () => {
    for(const hit of [true, false]) {
      const f = fixture('legacy-' + hit, {legacy:true}); assert.equal(f.search(question).results.length, 1);
      if(hit) f.vectorResponse = {status:200, body:{results:[f.vectorResult(qa)]}};
      const session = 'session_hybrid-legacy-' + hit; await f.deliver(f.event(session));
      assert.equal(f.vector.length, 1);
      if(hit) {successful(f, session, 1); assert.equal(citations(f.generated[0])[0].source.id, 'synthetic-vector-result');}
      else {assert.equal(f.generated.length, 0); assert.equal(f.sent[0].content, clarification);}
    }
  });
  await test('H12 检索或生成在途索引改变后旧结果不出站，资料恢复后按当前代重做且只回复一次', async () => {
    for(const stage of ['vector', 'generation']) {
      const f = fixture('inflight-' + stage);
      const originalIndex = f.raw('data/runtime/knowledge-lexical.json');
      const mutate = async () => {
        if(stage === 'vector') f.beforeVectorResponse = null; else f.beforeModelResponse = null;
        f.write('data/runtime/knowledge-lexical.json', originalIndex + '\n');
      };
      if(stage === 'vector') f.beforeVectorResponse = mutate; else f.beforeModelResponse = mutate;
      const session = 'session_hybrid-inflight-' + stage;
      await f.deliver(f.event(session, stage === 'vector' ? overlapQuestion : question));
      assert.equal(f.vector.length, Number(stage === 'vector')); assert.equal(f.generated.length, Number(stage === 'generation'));
      assert.equal(f.sent.length, 0); assert.equal(f.state(session).jobs[0].status, 'received');
      assert.equal(f.state(session).jobs[0].deferred_configuration, true);
      assert.equal(f.events().filter(event => event.type === 'ai_reply').length, 0);

      // 模拟受管资料事务完成：原问题应继续保留，但必须丢弃旧检索/生成结果，
      // 使用当前生效投影重新规划。测试无需真实等待调度器的五秒退避。
      f.write('data/runtime/knowledge-lexical.json', originalIndex);
      const key = f.runtime.stateKey(f.env.CRISP_WEBSITE_ID, session);
      const jobId = f.state(session).jobs[0].id;
      await f.runtime.transaction(key, state => { state.jobs.find(job => job.id === jobId).retry_at = 0; });
      const result = await f.runtime.process(key, jobId);
      assert.equal(result.status, 'sent', JSON.stringify({stage, result, state:f.state(session), vector:f.vector.length, generated:f.generated.length, sent:f.sent.length}));
      assert.equal(f.sent.length, 1);
      assert.equal(f.state(session).jobs[0].status, 'done');
      if(stage === 'vector') {
        assert.equal(f.vector.length, 2); assert.equal(f.generated.length, 1);
        assert.equal(f.sent[0].content, answer);
      } else {
        assert.equal(f.vector.length, 0); assert.equal(f.generated.length, 2);
        assert.equal(f.sent[0].content, answer);
      }
    }
  });
  await test('H13 强词法生成中官方缺字段真人立即取消 A，B 独立正常', async () => {
    const f = fixture('human-cancel'), first = 'session_hybrid-human', second = 'session_hybrid-other';
    f.beforeModelResponse = async () => {
      f.beforeModelResponse = null;
      const event = f.event(first, '这条虚构咨询由客服接续处理。', {from:'operator',
        user:{nickname:'虚构客服', user_id:'77777777-7777-4777-8777-777777777777'}});
      event.event = 'message:received';
      assert.equal(Object.hasOwn(event.data, 'automated'), false); assert.equal(Object.hasOwn(event.data.user, 'type'), false);
      const accepted = await f.receive(event);
      assert.equal(f.state(first).mode, 'human'); assert.equal(f.state(first).generation, 1);
      assert.equal(f.state(first).resume_at - f.state(first).last_human_at, 3600000);
      await f.runtime.process(accepted.key, accepted.jobId);
    };
    await f.deliver(f.event(first)); assert.equal(f.generated.length, 1); assert.equal(f.sent.length, 0);
    assert(f.state(first).jobs.some(job => job.status === 'cancelled'));
    await f.deliver(f.event(second)); assert.equal(f.generated.length, 2); assert.equal(f.sent.length, 1);
    assert.equal(f.sent[0].session_id, second); assert.equal(f.sent[0].content, answer); assert.equal(f.vector.length, 0);
    assert.equal(f.state(first).mode, 'human'); assert.equal(f.state(second).mode, 'ai');
  });
  await test('H14 同一映射文档多个 parsed 位置不会误报歧义或丢掉不同片段', async () => {
    const extra = qa + '第二页附注：先确认箱体完好。\n';
    const f = fixture('multi-location', {contents:[qa, extra], sameDocument:true});
    assert.equal(f.search(question).results.length, 2);
    const session = 'session_hybrid-multilocation'; await f.deliver(f.event(session)); successful(f, session);
    assert.deepEqual(citations(f.generated[0]).map(item => item.text).sort(), [qa, extra].sort());
    assert.equal(new Set(citations(f.generated[0]).map(item => item.source.document_id)).size, 1);
  });
  await test('H15 生成 Code 使用生产字面内置白名单完成强词法问答，源码哈希同步', async () => {
    const check = spawnSync(process.execPath, [path.join(project, 'n8n/build-workflow.js'), '--check'], {encoding:'utf8', timeout:10000});
    assert.equal(check.status, 0, check.stdout + check.stderr);
    const workflow = JSON.parse(fs.readFileSync(path.join(project, 'n8n/workflow.json'), 'utf8'));
    assert.equal(workflow.meta.runtimeFileSha256, hash(fs.readFileSync(path.join(project, 'n8n/runtime.js'))));
    assert.equal(workflow.meta.lexicalFileSha256, hash(fs.readFileSync(path.join(project, 'n8n/knowledge-lexical.js'))));
    const resolve = builtinResolver(); assert.throws(() => resolve('./knowledge-lexical.js'), /DisallowedModuleError/);
    const f = fixture('generated-code');
    const execute = async (name, input) => {
      const node = workflow.nodes.find(item => item.name === name); assert(node);
      const boundary = '\nconst runtime = createRuntime($env);\n';
      assert.equal(node.parameters.jsCode.split(boundary).length, 2);
      const code = node.parameters.jsCode.replace(boundary, '\nconst runtime = createRuntime($env, $runtimeOptions);\n');
      return new AsyncFunction('$input', '$env', 'require', '$runtimeOptions', code)({first:() => input}, f.env, resolve, f.runtimeOptions);
    };
    const session = 'session_hybrid-generated', event = f.event(session, '请根据现有知识库回答：' + question); f.remember(event);
    const received = await execute('校验并持久接收', {json:{body:event, query:{key:f.env.CRISP_WEBSITE_HOOK_SECRET}}});
    assert.equal(received[0].json.accepted, true); assert.equal(received[0].json.route, 'process');
    const processed = await execute('处理持久任务', {json:received[0].json}); assert.equal(processed[0].json.status, 'sent');
    successful(f, session); assert.equal(citations(f.generated[0])[0].text, qa);
    assert.equal(f.generated[0].messages.at(-1).content, event.data.content);
  });
  await test('H16 完整且锚定的礼貌范围说明剥离后跳过向量，完整问答及用户原句进入唯一生成', async () => {
    const cases = [
      {query:'请根据现有知识库回答：' + question, contents:[qa], expected:qa},
      {query:'  请根据现有知识库回答：\n' + question + '\n', contents:[qa], expected:qa},
      // 现场事故的同构格式：长标签“问题/回答”及同一行中的两个同义问法。
      {query:'请根据现有知识库回答：' + pairedQuestion, contents:[pairedQa], expected:pairedQa},
    ];
    for(const [index, item] of cases.entries()) {
      const {query, contents, expected} = item;
      const f = fixture('prefix-strong-' + index, {contents}); f.vectorError = new Error('此分支不应调用向量');
      const session = 'session_hybrid-prefixed-' + index;
      await f.deliver(f.event(session, query)); successful(f, session);
      assert.equal(f.search(query).results[0].lexical.kind, 'exact_question');
      assert.deepEqual(citations(f.generated[0]).map(item => item.text), [expected]);
      assert.equal(f.generated[0].messages.at(-1).content, query);
    }
  });
  await test('H17 无关/否定引用/复述改问/复合问句/数字冲突不会跳过向量或制造词法知识答案', async () => {
    const queries = ['请根据现有知识库回答：另一座银杉花园的停车时间是什么？',
      '请根据现有知识库回答：可以吗？', '请确认编号4832是否适用，再回答：' + question,
      '不要回答“' + question + '”，我真正想问银杉花园的停车时间。',
      '上一个问题是“' + question + '”。现在请回答银杉花园几点关门？',
      question + '另外，银杉花园几点关门？',
      '请根据现有知识库回答：不要回答“' + question + '”，请改答停车时间。'];
    for(const [index, query] of queries.entries()) {
      const f = fixture('prefix-negative-' + index, {contents:[qa, '问：可以吗？\n答：请先说明具体事项。\n']});
      assert.deepEqual(f.search(query).results, []);
      await f.deliver(f.event('session_hybrid-prefix-negative-' + index, query));
      assert.equal(f.vector.length, 1); assert.equal(f.vector[0].query, query);
      assert.equal(f.generated.length, 0); assert.equal(f.sent.length, 1); assert.equal(f.sent[0].content, clarification);
      assert.equal(f.events().filter(event => event.type === 'knowledge_hit').length, 0);
    }
  });
  await test('H18 中文同义词法补召回保持非 strong，向量 miss 后才作为已绑定资料生成', async () => {
    const synonymQa='问：苍蓝箱寄存？\n答：仅收取带虚构蓝羽标记的箱件。\n';
    const query='苍蓝行李能否临时保管？';
    const f=fixture('synonym-fallback',{contents:[synonymQa]});
    const lexical=f.search(query);
    assert.equal(lexical.results.length,1);
    assert.equal(lexical.results[0].lexical.kind,'synonym_overlap');
    const session='session_hybrid-synonym';
    await f.deliver(f.event(session,query)); successful(f,session,1);
    assert.deepEqual(f.vector,[{query}]);
    assert.deepEqual(citations(f.generated[0]).map(item=>item.text),[synonymQa]);
  });
  const result = {layer:'UNIT/PROTOCOL/GENERATED_CODE', passed, failed, evidence, cases};
  fs.writeFileSync(path.join(evidence, 'summary.json'), JSON.stringify(result, null, 2) + '\n', {mode:0o600});
  console.log(JSON.stringify({layer:result.layer, passed, failed, evidence})); process.exitCode = failed ? 1 : 0;
})().catch(error => {console.error(error.stack); process.exitCode = 1;});
