'use strict';

// 生产 provider-adapter/router 的持久恢复契约；只使用虚构凭据和本机协议服务。
// 本测试必须在 TARGET-A 执行，不能在开发机运行，也不是真实第三方 Provider 验收。
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const {createAdapter} = require('../scripts/provider-adapter.js');
const {signEnvelope,requestContract} = require('../scripts/provider-envelope.js');

const project = path.resolve(__dirname, '..');
const work = path.join(project, '.work', 'v1.3.0');
fs.mkdirSync(work, {recursive:true, mode:0o700});
const base = fs.mkdtempSync(path.join(work, 'provider-recovery-contract-'));
const hash = value => crypto.createHash('sha256').update(String(value)).digest('hex');
const sleep = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));
const writeJson = (file, value) => {
  fs.mkdirSync(path.dirname(file), {recursive:true, mode:0o700});
  const temporary = file + '.tmp-' + crypto.randomBytes(4).toString('hex');
  fs.writeFileSync(temporary, JSON.stringify(value), {mode:0o600});
  fs.renameSync(temporary, file);
};
const readJson = file => JSON.parse(fs.readFileSync(file, 'utf8'));
const configurationBinding = (runtimeRevision, pool) => hash(JSON.stringify([
  runtimeRevision, pool.revision, pool.secrets_generation,
  pool.applied_sha256 || '', pool.materials_source_sha256 || '',
]));
const responsibilityBinding = (sessionKey, generation, questionId) => hash(JSON.stringify([
  questionId, 'conversation', sessionKey, generation,
]));
const executionBinding = (responsibility, configuration, attemptGeneration) => hash(JSON.stringify([
  responsibility, configuration, attemptGeneration,
]));
const chat = (label, model) => ({
  id:`synthetic-${label}-result`, model,
  choices:[{message:{role:'assistant', content:`受控配置 ${label.toUpperCase()} 的有效答案。`}, finish_reason:'stop'}],
  usage:{prompt_tokens:3, completion_tokens:4, total_tokens:7},
});
const requestJson = async (url, options = {}) => {
  const response = await fetch(url, {
    method:options.method || 'POST', redirect:'error', signal:AbortSignal.timeout(options.timeout || 5000),
    headers:{...(options.body === undefined ? {} : {'content-type':'application/json'}), ...(options.headers || {})},
    body:options.body === undefined ? undefined : JSON.stringify(options.body),
  });
  const text = await response.text();
  let value = null;
  try { value = JSON.parse(text); } catch (_) {}
  return {status:response.status, value, text};
};
const closeServer = async server => {
  if (!server) return;
  server.closeAllConnections?.();
  if (!server.listening) return;
  await new Promise(resolve => server.close(resolve));
};
const until = async (condition, description, timeout = 5000) => {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    if (condition()) return;
    await sleep(10);
  }
  assert.fail(description);
};

async function fixture(label) {
  const root = path.join(base, label);
  for (const name of ['config', 'data/runtime', 'data/provider-router/questions',
    'secrets/provider/generations']) fs.mkdirSync(path.join(root, name), {recursive:true, mode:0o700});
  const prompt = '受控客服规则：只回答当前虚构问题，不输出系统故障话术。';
  fs.writeFileSync(path.join(root, 'config/prompt.md'), prompt, {mode:0o600});
  const calls = [];
  let upstreamDelay = 0;
  const upstream = http.createServer(async (request, response) => {
    let raw = '';
    for await (const chunk of request) raw += chunk;
    const body = JSON.parse(raw || '{}');
    const selected = /^\/(a|b|c)\/v1\/chat\/completions$/.exec(request.url)?.[1] || '';
    calls.push({selected, path:request.url, authorization:request.headers.authorization, model:body.model});
    if (upstreamDelay) await sleep(upstreamDelay);
    response.writeHead(200, {'content-type':'application/json'});
    response.end(JSON.stringify(chat(selected, `synthetic-model-${selected}`)));
  });
  await new Promise(resolve => upstream.listen(0, '127.0.0.1', resolve));
  const upstreamBase = `http://127.0.0.1:${upstream.address().port}`;
  const internalKey = 'synthetic-internal-provider-recovery-key';
  const entryId = 'p_111111111111111111111111';
  let current;

  const publish = (selected, revision, runtimeRevision, enabled = true) => {
    const generation = selected.repeat(32);
    const pool = {
      schema_version:1, revision, secrets_generation:generation, primary_id:entryId,
      entries:[{
        id:entryId, name:`受控接口 ${selected.toUpperCase()}`, role:'primary', order:0, enabled:true,
        base_url:`${upstreamBase}/${selected}/v1`, model:`synthetic-model-${selected}`,
        api_mode:'chat_completions', custom_header_names:[],
        capabilities:{chat_completions:true, responses:false, vision:false},
        context_window:8192, max_output_tokens:256,
      }],
      policy:{question_timeout_ms:5000, call_timeout_ms:2000, connect_timeout_ms:200,
        max_attempts:1, cooldown_initial_ms:1000, cooldown_max_ms:2000, pool_cooldown_ms:100},
    };
    const poolSha256 = hash(JSON.stringify(pool));
    writeJson(path.join(root, 'secrets/provider/generations', generation + '.json'), {
      schema_version:1, generation, revision,
      entries:{[entryId]:{api_key:`synthetic-key-${selected}`, custom_headers:{}}},
    });
    writeJson(path.join(root, 'config/provider-pool-applied.json'), pool);
    const materialsSourceSha256 = hash(`synthetic-materials-${runtimeRevision}`);
    writeJson(path.join(root, 'config/materials-applied.json'), {
      schema_version:2, state:'applied', revision:runtimeRevision,
      source_sha256:materialsSourceSha256,
      configuration:{runtime:{schema_version:2, enabled, revision:runtimeRevision,
        applied_revision:runtimeRevision, disable_epoch:enabled ? 0 : 1}},
      prompt:{text:prompt, bytes:Buffer.byteLength(prompt), sha256:hash(prompt)},
    });
    writeJson(path.join(root, 'config/runtime.yaml'), {
      schema_version:2, enabled, revision:runtimeRevision, applied_revision:runtimeRevision,
    });
    current = {selected, runtimeRevision,
      pool:{...pool, applied_sha256:poolSha256,
        materials_source_sha256:materialsSourceSha256}};
    current.binding = configurationBinding(runtimeRevision, current.pool);
    return current;
  };

  const initial = publish('a', 1, 1, true);
  const sessionId = `session_recovery-${label}`;
  const sessionKey = hash('11111111-1111-4111-8111-111111111111\0' + sessionId);
  const questionId = hash('provider-recovery-question\0' + label);
  const responsibility = responsibilityBinding(sessionKey, 0, questionId);
  const sessionFile = path.join(root, 'data/runtime', `session-${sessionKey}.json`);
  const questionFile = path.join(root, 'data/provider-router/questions', `${questionId}.json`);
  const routerStateFile = path.join(root, 'data/provider-router/state.json');
  let armTelemetryWriteFailure = false;
  let failNextTelemetryWrite = false;
  let telemetryWriteFailures = 0;
  const originalRenameSync = fs.renameSync;
  fs.renameSync = function(source, destination) {
    if (armTelemetryWriteFailure && destination === questionFile) {
      try {
        const candidate = JSON.parse(fs.readFileSync(source, 'utf8'));
        if (Object.values(candidate.stages || {}).some(phase => phase?.result !== undefined)) {
          armTelemetryWriteFailure = false;
          failNextTelemetryWrite = true;
        }
      } catch (_) {}
    } else if (failNextTelemetryWrite && destination === routerStateFile) {
      failNextTelemetryWrite = false;
      telemetryWriteFailures += 1;
      const error = new Error('受控路由健康统计写入失败');
      error.code = 'EIO';
      throw error;
    }
    return originalRenameSync.call(fs, source, destination);
  };
  const initialInference = {
    runtime_revision:initial.runtimeRevision, pool_revision:initial.pool.revision,
    secrets_generation:initial.pool.secrets_generation,
    pool_sha256:initial.pool.applied_sha256,
    materials_source_sha256:initial.pool.materials_source_sha256,
    configuration_binding:initial.binding, deadline_at:Date.now() + 5000, attempt_generation:1,
  };
  writeJson(sessionFile, {
    schema_version:2, website_id:'11111111-1111-4111-8111-111111111111', session_id:sessionId,
    mode:'ai', generation:0, resume_at:null, uncertain_events:[], outgoing:{},
    jobs:[{
      id:questionId, status:'processing', revision:1, generation:0, response_generation:0,
      responsibility_status:'pending', data:{type:'text', content:'虚构恢复问题'},
      inference_generation:1, inference:initialInference,
    }],
  });
  const body = {model:'synthetic-model-a', stream:false, messages:[
    {role:'system', content:prompt}, {role:'user', content:'虚构恢复问题'},
  ]};
  const envelope = (configuration = current, attemptGeneration = 1, extra = {}, requestBody = body) => {
    return {
      version:1, scope:'conversation', question_id:questionId, session_key:sessionKey,
      generation:0, runtime_revision:configuration.runtimeRevision,
      pool_revision:configuration.pool.revision, secrets_generation:configuration.pool.secrets_generation,
      pool_sha256:configuration.pool.applied_sha256,
      materials_source_sha256:configuration.pool.materials_source_sha256,
      configuration_binding:configuration.binding,
      deadline_at:Date.now() + 5000, attempt_generation:attemptGeneration, stage:'answer',
      ...requestContract(requestBody), ...extra,
    };
  };
  const adapterEnvironment = {
    PROVIDER_ROOT:root, PROVIDER_ADAPTER_KEY:internalKey,
    PROVIDER_POOL_REQUIRED:'true', PROVIDER_REQUIRE_ENVELOPE:'true',
  };
  const adapter = createAdapter(adapterEnvironment);
  await new Promise(resolve => adapter.listen(0, '127.0.0.1', resolve));
  const peers = [];
  const adapterBase = `http://127.0.0.1:${adapter.address().port}`;
  const post = (route, value, requestBody = body) => requestJson(adapterBase + route, {
    headers:{authorization:'Bearer ' + internalKey, 'x-crispai-question':signEnvelope(value, internalKey)},
    body:requestBody,
  });
  const replay = value => post('/internal/provider/replay', value, {});
  const settle = (value, planSha256 = hash('synthetic-final-plan')) => post('/internal/provider/settle', value, {
    outcome:'plan_persisted', plan_sha256:planSha256, response_generation:0,
  });
  const state = () => readJson(sessionFile);
  const updateState = change => {
    const value = state();
    change(value, value.jobs[0]);
    writeJson(sessionFile, value);
    return value;
  };
  const question = () => readJson(questionFile);

  const loseCompletedResponse = async value => {
    let forwardingError = null;
    const proxy = http.createServer(async (request, response) => {
      try {
        let raw = '';
        for await (const chunk of request) raw += chunk;
        const forwarded = await fetch(adapterBase + '/v1/chat/completions', {
          method:'POST', headers:{authorization:'Bearer ' + internalKey,
            'content-type':'application/json', 'x-crispai-question':signEnvelope(value, internalKey)},
          body:raw, signal:AbortSignal.timeout(5000),
        });
        await forwarded.arrayBuffer();
        if (!forwarded.ok) forwardingError = new Error('adapter 未生成可缓存的有效结果');
      } catch (error) {
        forwardingError = error;
      } finally {
        response.destroy();
      }
    });
    await new Promise(resolve => proxy.listen(0, '127.0.0.1', resolve));
    let lost = false;
    try {
      await requestJson(`http://127.0.0.1:${proxy.address().port}/drop`, {body});
    } catch (_) { lost = true; }
    await closeServer(proxy);
    assert.equal(lost, true, '夹具必须在完整 adapter 结果之后丢弃回程');
    assert.equal(forwardingError, null, 'adapter 必须先完整生成并缓存有效结果');
    await until(() => fs.existsSync(questionFile) && question().stages?.answer?.result,
      'Provider 已成功但 router 没有持久缓存结果');
  };

  const markReceiptUnknown = value => updateState((_state, job) => {
    job.status = 'received';
    job.responsibility_status = 'unresolved_failure';
    job.failure_code = 'provider_result_receipt_unknown';
    job.retry_at = 0;
    job.provider_result_receipt = {
      state:'unknown', stage:'answer', attempt_generation:value.attempt_generation,
      configuration_binding:value.configuration_binding, first_unknown_at:Date.now(),
      last_checked_at:0, next_action_at:0, checks:0,
      request_contract_version:value.request_contract_version,
      request_sha256:value.request_sha256,
      plan_context_sha256:value.plan_context_sha256,
      plan_context:null,
    };
  });

  return {
    root, calls, body, initial, publish, envelope, post, replay, settle, question, state, updateState,
    questionId, sessionKey, responsibility, questionFile,
    setUpstreamDelay(milliseconds) { upstreamDelay = milliseconds; },
    failTelemetryAfterResult() { armTelemetryWriteFailure = true; },
    telemetryWriteFailures: () => telemetryWriteFailures,
    async startPeer() {
      const server = createAdapter(adapterEnvironment);
      await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
      peers.push(server);
      const peerBase = `http://127.0.0.1:${server.address().port}`;
      return {
        post: (route, value, requestBody = body) => requestJson(peerBase + route, {
          headers:{authorization:'Bearer ' + internalKey,
            'x-crispai-question':signEnvelope(value, internalKey)},
          body:requestBody,
        }),
        close: () => closeServer(server),
      };
    },
    async seedLostCache() {
      const value = envelope(initial, 1, {deadline_at:initialInference.deadline_at});
      await loseCompletedResponse(value);
      markReceiptUnknown(value);
      assert.equal(calls.length, 1);
      assert.equal(question().stages.answer.result.choices[0].message.content,
        '受控配置 A 的有效答案。');
      return value;
    },
    async close() {
      fs.renameSync = originalRenameSync;
      await Promise.all(peers.map(closeServer));
      await closeServer(adapter);
      await closeServer(upstream);
      fs.rmSync(root, {recursive:true, force:true});
    },
  };
}

let passed = 0;
async function test(name, action) {
  const instance = await fixture('case-' + passed);
  try {
    await action(instance);
    passed += 1;
    process.stdout.write('通过 UNIT/PROTOCOL：' + name + '\n');
  } finally { await instance.close(); }
}

(async () => {
  await test('两个独立adapter实例竞争同一问题时只授予一个上游调用并复用持久结果', async f => {
    f.setUpstreamDelay(100);
    const peer = await f.startPeer();
    const token = f.envelope(f.initial, 1);
    const [first, second] = await Promise.all([
      f.post('/v1/chat/completions', token),
      peer.post('/v1/chat/completions', token),
    ]);
    assert.equal(first.status, 200, first.text);
    assert.equal(second.status, 200, second.text);
    assert.equal(first.value?.choices?.[0]?.message?.content, '受控配置 A 的有效答案。');
    assert.deepEqual(second.value, first.value);
    assert.equal(f.calls.length, 1,
      '跨router实例竞争不得绕过持久锁或重复调用第三方接口');
    const question = f.question();
    assert.deepEqual([question.attempt_generation, question.round_attempts, question.attempts], [1, 1, 1]);
    assert.equal(question.stages.answer.owner, undefined);
    await peer.close();
  });

  await test('结果已持久后健康统计写入失败不推翻成功或重复推理', async f => {
    f.failTelemetryAfterResult();
    const token = f.envelope(f.initial, 1);
    const result = await f.post('/v1/chat/completions', token);
    assert.equal(result.status, 200, result.text);
    assert.equal(result.value?.choices?.[0]?.message?.content,
      '受控配置 A 的有效答案。');
    assert.equal(f.telemetryWriteFailures(), 1,
      '夹具必须在结果落盘后命中一次非关键健康统计写入');
    assert.equal(f.calls.length, 1);
    assert.equal(f.question().stages.answer.result.choices[0].message.content,
      '受控配置 A 的有效答案。');
    const replayed = await f.replay(token);
    assert.equal(replayed.status, 200, replayed.text);
    assert.deepEqual(replayed.value, result.value);
    assert.equal(f.calls.length, 1,
      '非关键 telemetry 失败不得使 runtime 重新调用上游');
  });

  await test('缓存成功但adapter回程丢失时只读同代重放，settle后保留审计且禁止二次推理', async f => {
    const token = await f.seedLostCache();
    const before = f.question();
    assert.equal(before.responsibility_binding, f.responsibility);
    assert.equal(before.configuration_binding, f.initial.binding);
    assert.equal(before.execution_binding,
      executionBinding(f.responsibility, f.initial.binding, 1));
    assert.deepEqual([before.attempt_generation, before.round_attempts, before.attempts], [1, 1, 1]);

    const replayed = await f.replay(token);
    assert.equal(replayed.status, 200, replayed.text);
    assert.equal(replayed.value?.choices?.[0]?.message?.content,
      '受控配置 A 的有效答案。');
    assert.equal(f.calls.length, 1, 'replay-only 不得再次调用第三方接口');

    const resultDigest = hash(JSON.stringify(replayed.value));
    const planDigest = hash('synthetic-final-plan-a');
    const settlement = await f.settle(token, planDigest);
    assert.equal(settlement.status, 200, settlement.text);
    assert.deepEqual(settlement.value, {ok:true, state:'settled'});

    f.updateState((_state, job) => {
      job.status = 'done';
      job.responsibility_status = 'answered_confirmed';
      job.retry_at = null;
      delete job.inference;
      delete job.provider_result_receipt;
    });
    const replayAfterSettle = await f.replay(token);
    assert.notEqual(replayAfterSettle.status, 200,
      '责任完成后旧 replay token 不得再次取得正文');
    const next = await f.post('/v1/chat/completions', f.envelope(f.initial, 2));
    assert.notEqual(next.status, 200, '责任完成后递增推理代不得重新打开 Provider');
    assert.equal(f.calls.length, 1);
    const retained = f.question();
    assert.deepEqual([retained.round_attempts, retained.attempts], [1, 1]);
    assert.deepEqual(retained.settlement, {
      outcome:'plan_persisted', plan_sha256:planDigest,
      response_generation:0, settled_at:retained.settlement.settled_at,
    });
    assert.equal(Number.isFinite(retained.settlement.settled_at), true);
    assert.equal(retained.stages.answer.result, undefined,
      'settle 后不保留可再次交付的完整 Provider 正文');
    assert.equal(retained.stages.answer.result_receipt?.sha256, resultDigest,
      'settle 后必须保留不可重复推理所需的结果审计摘要');
  });

  await test('缓存重放逐字绑定请求正文与计划上下文，错配时不返回旧答案也不重新推理', async f => {
    const original = await f.seedLostCache();
    const changedBody = {...f.body, messages:[
      f.body.messages[0], {role:'user', content:'同一责任下被替换的另一问题'},
    ]};
    const changedRequest = f.envelope(f.initial, 1,
      {deadline_at:original.deadline_at}, changedBody);
    const requestMismatch = await f.post('/v1/chat/completions', changedRequest, changedBody);
    assert.notEqual(requestMismatch.status, 200,
      '同一 question_id 不得用另一请求正文读取旧缓存');
    assert.equal(f.calls.length, 1,
      '请求身份冲突不得重新调用第三方接口');

    const changedContext = f.envelope(f.initial, 1, {
      deadline_at:original.deadline_at,
      ...requestContract(f.body, {outcome:'knowledge_answer', sources:['受控另一知识来源']}),
    }, f.body);
    const contextMismatch = await f.replay(changedContext);
    assert.notEqual(contextMismatch.status, 200,
      '同一请求正文不得跨计划上下文读取旧缓存');
    assert.equal(f.calls.length, 1,
      '计划上下文身份冲突不得重新调用第三方接口');

    const exact = await f.replay(original);
    assert.equal(exact.status, 200, exact.text);
    assert.equal(exact.value?.choices?.[0]?.message?.content,
      '受控配置 A 的有效答案。');
    assert.equal(f.calls.length, 1,
      '只有完整请求契约一致时才允许只读重放');
  });

  await test('配置A→B→C只允许同一责任的单调successor，地址Key模型不混代', async f => {
    const oldToken = await f.seedLostCache();
    const oldResult = f.question().stages.answer.result;
    const oldResultDigest = hash(JSON.stringify(oldResult));
    const next = f.publish('b', 2, 2, true);
    const nextBody = {...f.body, model:'synthetic-model-b'};
    const successor = f.envelope(next, 2, {
      migration_from:{runtime_revision:f.initial.runtimeRevision,
        pool_revision:f.initial.pool.revision,
        secrets_generation:f.initial.pool.secrets_generation,
        pool_sha256:f.initial.pool.applied_sha256,
        materials_source_sha256:f.initial.pool.materials_source_sha256,
        attempt_generation:1},
      transition_reason:'configuration_changed',
    }, nextBody);
    f.updateState((_state, job) => {
      job.status = 'processing';
      job.revision = 2;
      job.inference_generation = 2;
      job.inference = {
        runtime_revision:next.runtimeRevision, pool_revision:next.pool.revision,
        secrets_generation:next.pool.secrets_generation,
        pool_sha256:next.pool.applied_sha256,
        materials_source_sha256:next.pool.materials_source_sha256,
        configuration_binding:next.binding, deadline_at:successor.deadline_at, attempt_generation:2,
      };
      job.provider_migration_from = {...successor.migration_from};
      delete job.provider_result_receipt;
    });

    const oldReplay = await f.replay(oldToken);
    assert.notEqual(oldReplay.status, 200, '旧配置 token 必须在缓存读取前失效');
    assert.equal(f.calls.length, 1);
    const migrated = await f.post('/v1/chat/completions', successor, nextBody);
    assert.equal(migrated.status, 200, migrated.text);
    assert.equal(migrated.value?.choices?.[0]?.message?.content,
      '受控配置 B 的有效答案。');
    assert.deepEqual(f.calls.map(call => [call.selected, call.authorization, call.model]), [
      ['a', 'Bearer synthetic-key-a', 'synthetic-model-a'],
      ['b', 'Bearer synthetic-key-b', 'synthetic-model-b'],
    ]);

    const question = f.question();
    assert.equal(question.responsibility_binding, f.responsibility);
    assert.equal(question.configuration_binding, next.binding);
    assert.equal(question.execution_binding,
      executionBinding(f.responsibility, next.binding, 2));
    assert.deepEqual([question.attempt_generation, question.round_attempts, question.attempts], [2, 1, 2]);
    assert.equal(question.stages.answer.result.choices[0].message.content,
      '受控配置 B 的有效答案。');
    assert.equal(JSON.stringify(question).includes(oldResultDigest), true,
      '配置换代后必须保留旧缓存失效摘要，不能删除审计或继续使用旧正文');

    const bResultDigest = hash(JSON.stringify(question.stages.answer.result));
    const final = f.publish('c', 3, 3, true);
    const finalBody = {...f.body, model:'synthetic-model-c'};
    const finalSuccessor = f.envelope(final, 3, {
      // runtime 在多次配置变更中保留最早尚未 settle 的 A 代根；
      // router 只能依据自己已持久的 migration_origin 接受这条链。
      migration_from:{runtime_revision:f.initial.runtimeRevision,
        pool_revision:f.initial.pool.revision,
        secrets_generation:f.initial.pool.secrets_generation,
        pool_sha256:f.initial.pool.applied_sha256,
        materials_source_sha256:f.initial.pool.materials_source_sha256,
        attempt_generation:1},
      transition_reason:'configuration_changed',
    }, finalBody);
    f.updateState((_state, job) => {
      job.status = 'processing';
      job.revision = 3;
      job.inference_generation = 3;
      job.inference = {
        runtime_revision:final.runtimeRevision, pool_revision:final.pool.revision,
        secrets_generation:final.pool.secrets_generation,
        pool_sha256:final.pool.applied_sha256,
        materials_source_sha256:final.pool.materials_source_sha256,
        configuration_binding:final.binding, deadline_at:finalSuccessor.deadline_at,
        attempt_generation:3,
      };
      job.provider_migration_from = {...finalSuccessor.migration_from};
      delete job.provider_result_receipt;
    });

    assert.notEqual((await f.replay(successor)).status, 200,
      'B 代缓存不得跨配置回放到 C');
    const finalResult = await f.post('/v1/chat/completions', finalSuccessor, finalBody);
    assert.equal(finalResult.status, 200, finalResult.text);
    assert.equal(finalResult.value?.choices?.[0]?.message?.content,
      '受控配置 C 的有效答案。');
    assert.deepEqual(f.calls.map(call => [call.selected, call.authorization, call.model]), [
      ['a', 'Bearer synthetic-key-a', 'synthetic-model-a'],
      ['b', 'Bearer synthetic-key-b', 'synthetic-model-b'],
      ['c', 'Bearer synthetic-key-c', 'synthetic-model-c'],
    ]);
    const fenced = f.question();
    assert.equal(fenced.configuration_binding, final.binding);
    assert.equal(fenced.stages.answer.result.choices[0].message.content,
      '受控配置 C 的有效答案。');
    assert.deepEqual([fenced.attempt_generation, fenced.round_attempts, fenced.attempts], [3, 1, 3]);
    assert.equal(fenced.migration_origin.attempt_generation, 1);
    assert.equal(fenced.invalidated_results.some(item => item.sha256 === oldResultDigest), true);
    assert.equal(fenced.invalidated_results.some(item => item.sha256 === bResultDigest), true);

    assert.notEqual((await f.post('/v1/chat/completions', oldToken)).status, 200);
    const forbiddenFourthInference = await f.post('/v1/chat/completions',
      f.envelope(final, 4, {}, finalBody), finalBody);
    assert.notEqual(forbiddenFourthInference.status, 200,
      '当前配置已有有效缓存时不得再借下一代推理');
    assert.equal(f.calls.length, 3);

    const finalResultDigest = hash(JSON.stringify(fenced.stages.answer.result));
    const planDigest = hash('synthetic-final-plan-c');
    const settlement = await f.settle(finalSuccessor, planDigest);
    assert.equal(settlement.status, 200, settlement.text);
    assert.deepEqual(settlement.value, {ok:true, state:'settled'});

    f.updateState((_state, job) => {
      job.status = 'done';
      job.responsibility_status = 'answered_confirmed';
      job.retry_at = null;
      delete job.inference;
      delete job.provider_migration_from;
    });
    assert.notEqual((await f.replay(finalSuccessor)).status, 200);
    assert.equal(f.calls.length, 3);
    const settled = f.question();
    assert.equal(settled.attempts, 3);
    assert.equal(JSON.stringify(settled).includes(oldResultDigest), true);
    assert.equal(JSON.stringify(settled).includes(bResultDigest), true);
    assert.equal(settled.stages.answer.result, undefined);
    assert.equal(settled.stages.answer.result_receipt?.sha256, finalResultDigest);
    assert.equal(settled.settlement.plan_sha256, planDigest);
  });

  await test('真人接管后缓存重放和配置successor都拒绝，保留明确人工静默', async f => {
    const oldToken = await f.seedLostCache();
    f.updateState((state, job) => {
      state.mode = 'human';
      state.generation = 1;
      state.resume_at = Date.now() + 3600000;
      job.status = 'cancelled';
      job.responsibility_status = 'intentional_silence';
      job.responsibility_reason = 'human_reply';
    });
    assert.notEqual((await f.replay(oldToken)).status, 200);
    const next = f.publish('b', 2, 2, true);
    const nextBody = {...f.body, model:'synthetic-model-b'};
    const successor = f.envelope(next, 2, {
      migration_from:{runtime_revision:f.initial.runtimeRevision,
        pool_revision:f.initial.pool.revision,
        secrets_generation:f.initial.pool.secrets_generation,
        pool_sha256:f.initial.pool.applied_sha256,
        materials_source_sha256:f.initial.pool.materials_source_sha256,
        attempt_generation:1},
      transition_reason:'configuration_changed',
    }, nextBody);
    f.updateState((_state, job) => {
      job.revision = 2;
      job.inference_generation = 2;
      job.inference = {runtime_revision:next.runtimeRevision, pool_revision:2,
        secrets_generation:next.pool.secrets_generation,
        pool_sha256:next.pool.applied_sha256,
        materials_source_sha256:next.pool.materials_source_sha256,
        configuration_binding:next.binding, deadline_at:successor.deadline_at, attempt_generation:2};
      job.provider_migration_from = {...successor.migration_from};
    });
    assert.notEqual((await f.post('/v1/chat/completions', successor, nextBody)).status, 200);
    assert.equal(f.calls.length, 1);
    const state = f.state(), job = state.jobs[0];
    assert.equal(state.mode, 'human');
    assert.equal(job.status, 'cancelled');
    assert.equal(job.responsibility_status, 'intentional_silence');
    assert.equal(job.responsibility_reason, 'human_reply');
  });

  await test('客服总关后缓存重放和配置迁移都拒绝，不以恢复率强迫AI出站', async f => {
    const oldToken = await f.seedLostCache();
    const next = f.publish('b', 2, 2, false);
    const nextBody = {...f.body, model:'synthetic-model-b'};
    const successor = f.envelope(next, 2, {
      migration_from:{runtime_revision:f.initial.runtimeRevision,
        pool_revision:f.initial.pool.revision,
        secrets_generation:f.initial.pool.secrets_generation,
        pool_sha256:f.initial.pool.applied_sha256,
        materials_source_sha256:f.initial.pool.materials_source_sha256,
        attempt_generation:1},
      transition_reason:'configuration_changed',
    }, nextBody);
    f.updateState((_state, job) => {
      job.status = 'received';
      job.revision = 2;
      job.inference_generation = 2;
      job.inference = {runtime_revision:next.runtimeRevision, pool_revision:2,
        secrets_generation:next.pool.secrets_generation,
        pool_sha256:next.pool.applied_sha256,
        materials_source_sha256:next.pool.materials_source_sha256,
        configuration_binding:next.binding, deadline_at:successor.deadline_at, attempt_generation:2};
      job.provider_migration_from = {...successor.migration_from};
    });
    assert.notEqual((await f.replay(oldToken)).status, 200);
    assert.notEqual((await f.post('/v1/chat/completions', successor, nextBody)).status, 200);
    assert.equal(f.calls.length, 1);
    f.updateState((_state, job) => {
      job.status = 'cancelled';
      job.responsibility_status = 'intentional_silence';
      job.responsibility_reason = 'global_disabled';
      job.retry_at = null;
    });
    assert.notEqual((await f.replay(successor)).status, 200);
    assert.equal(f.calls.length, 1);
    assert.equal(f.state().jobs[0].responsibility_reason, 'global_disabled');
    assert.equal(fs.existsSync(f.questionFile), true, '合法静默不得删除既有 Provider 审计');
  });

  process.stdout.write(`Provider持久恢复契约：${passed} 通过，0 失败（受控协议服务，不是真实第三方）。\n`);
})().then(() => {
  fs.rmSync(base, {recursive:true, force:true});
}).catch(error => {
  process.stderr.write((error?.stack || String(error)) + '\n');
  process.exitCode = 1;
});
