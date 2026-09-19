'use strict';

// 两个真实 Node 子进程共享同一受管目录，验证会话事务与 Provider 路由锁。
// 这是 TARGET-A 上执行的 UNIT/CONTRACT 负例，不是真实 Crisp 或第三方 Provider 验收。
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { spawn } = require('node:child_process');
const { createRuntime } = require('../n8n/runtime');
const { createRouter, DEFAULT_POLICY } = require('../scripts/provider-router');

const project = path.resolve(__dirname, '..');
const website = '11111111-1111-4111-8111-111111111111';
const activeChildren = new Set();
const hash = (value) => crypto.createHash('sha256').update(String(value)).digest('hex');
const canonical = (value) => Array.isArray(value) ? '[' + value.map(canonical).join(',') + ']'
  : value && typeof value === 'object' ? '{' + Object.keys(value).sort()
    .map((key) => JSON.stringify(key) + ':' + canonical(value[key])).join(',') + '}'
    : JSON.stringify(value);
const digest = (value) => crypto.createHash('sha256').update(value).digest('hex');
const wait = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));
const writeJson = (file, value) => {
  fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  fs.writeFileSync(file, JSON.stringify(value), { mode: 0o600 });
};
const readJson = (file) => JSON.parse(fs.readFileSync(file, 'utf8'));
const sleepSync = (milliseconds) => Atomics.wait(
  new Int32Array(new SharedArrayBuffer(4)), 0, 0, milliseconds);

const decodeArguments = () => JSON.parse(Buffer.from(process.argv[3], 'base64url').toString('utf8'));
const writeChildResult = (file, value) => writeJson(file, value);

const runtimeEnvironment = {
  CRISP_WEBSITE_ID: website,
  CRISP_WEBSITE_HOOK_SECRET: 'synthetic-process-fencing-hook',
  CRISP_AUTH_B64: 'synthetic-process-fencing-auth',
  ANYTHINGLLM_WORKSPACE: 'crisp-support',
  PROVIDER_POOL_REQUIRED: 'false',
  PROVIDER_POOL_READBACK_REQUIRED: 'false',
};

const runtimeChild = async (options) => {
  const childClock = () => options.clock ? readJson(options.clock).now : Date.now();
  const childRequest = async (url, request = {}) => {
    if (options.action === 'process-until-killed') {
      const parsed = new URL(url);
      const exactPath = `/message/${encodeURIComponent(String(options.fingerprint))}`;
      if ((request.method || 'GET') === 'GET' && parsed.pathname.endsWith(exactPath)) {
        fs.writeFileSync(options.held, 'held', { mode: 0o600 });
        return new Promise((_, reject) => {
          setTimeout(() => reject(new Error('等待父进程终止受控 worker 超时')), 15000);
        });
      }
    }
    throw new Error('跨进程会话事务负例不应访问未授权网络');
  };
  const runtime = createRuntime(runtimeEnvironment, {
    root: options.root,
    request: childRequest,
    clock: childClock,
    processingPermitClock: childClock,
  });
  const key = runtime.stateKey(website, options.session);
  const jobId = options.jobId || hash(`runtime-process-fencing\0${options.session}`);
  const transact = (mutate) => runtime.transaction(key, mutate, website, options.session);
  try {
    if (options.action === 'initialize') {
      await transact((state) => {
        state.sequence = 1;
        state.jobs = [{
          id: jobId, event: 'message:send', status: 'received', control: false,
          revision: 1, generation: 0, response_generation: 0, sequence: 1,
          received_at: Date.now(), event_time: Date.now(), attempts: 0,
          responsibility_status: 'pending',
          data: { from: 'user', type: 'text', content: '受控跨进程问题', fingerprint: 70001 },
        }];
      });
    } else if (options.action === 'hold-stale-writer') {
      await transact((state) => {
        state.stale_writer_started = true;
        fs.writeFileSync(options.held, 'held', { mode: 0o600 });
        const deadline = Date.now() + 15000;
        while (!fs.existsSync(options.release)) {
          if (Date.now() >= deadline) throw new Error('等待释放受控旧写者超时');
          sleepSync(20);
        }
        state.mode = 'ai';
        state.generation = 0;
        state.stale_writer_committed = true;
      });
    } else if (options.action === 'human-control') {
      await transact((state) => {
        const job = state.jobs.find((entry) => entry.id === jobId);
        assert(job, '人工控制必须更新同一原始责任');
        state.mode = 'human';
        state.generation += 1;
        state.resume_at = Date.now() + 3600000;
        state.pause_reason = 'operator_reply';
        state.last_human_at = Date.now();
        state.control_watermark = state.last_human_at;
        job.status = 'cancelled';
        job.retry_at = null;
        job.responsibility_status = 'intentional_silence';
        job.responsibility_reason = 'human_reply';
      });
    } else if (options.action === 'mark-recovered') {
      await transact((state) => { state.recovered_by = options.marker; });
    } else if (options.action === 'process-until-killed') {
      await runtime.process(key, jobId);
      throw new Error('受控崩溃 worker 不应在父进程终止前返回');
    } else {
      throw new Error('未知 runtime 子进程动作');
    }
    writeChildResult(options.result, { ok: true, action: options.action });
  } catch (error) {
    writeChildResult(options.result, { ok: false, action: options.action,
      code: String(error?.code || ''), message: String(error?.message || error) });
  }
};

const routerChild = (options) => {
  try {
    const router = createRouter({ PROVIDER_ROOT: options.root, PROVIDER_POOL_REQUIRED: 'true' },
      async () => { throw new Error('路由锁负例不应调用第三方接口'); });
    const status = router.status();
    writeChildResult(options.result, { ok: true, revision: status.revision });
  } catch (error) {
    writeChildResult(options.result, { ok: false, code: String(error?.code || ''),
      message: String(error?.message || error) });
  }
};

const blockerChild = (options) => {
  fs.writeFileSync(options.held, 'held', { mode: 0o600 });
  setInterval(() => {}, 1000);
};

const childMode = process.argv[2];
if (childMode === '--runtime-child') {
  runtimeChild(decodeArguments()).catch((error) => {
    try { writeChildResult(decodeArguments().result, { ok: false, message: String(error?.message || error) }); }
    catch (_) {}
    process.exitCode = 1;
  });
} else if (childMode === '--router-child') {
  routerChild(decodeArguments());
} else if (childMode === '--blocker-child') {
  blockerChild(decodeArguments());
} else {
  main().catch((error) => {
    process.stderr.write(`跨进程 owner/fencing 负例失败：${String(error?.message || error)}\n`);
    process.exitCode = 1;
  });
}

function startChild(mode, options) {
  const encoded = Buffer.from(JSON.stringify(options)).toString('base64url');
  const child = spawn(process.execPath, [__filename, mode, encoded], {
    cwd: project,
    env: { PATH: process.env.PATH || '/usr/bin:/bin', LANG: 'C.UTF-8' },
    stdio: ['ignore', 'ignore', 'pipe'],
  });
  activeChildren.add(child);
  child.once('close', () => activeChildren.delete(child));
  let stderr = '';
  child.stderr.on('data', (chunk) => { stderr = (stderr + chunk).slice(-8192); });
  return { child, stderr: () => stderr };
}

async function waitForExit(handle, timeout = 20000) {
  if (handle.child.exitCode !== null || handle.child.signalCode !== null) {
    return { code: handle.child.exitCode, signal: handle.child.signalCode };
  }
  let timer;
  return new Promise((resolve, reject) => {
    const done = (code, signal) => {
      clearTimeout(timer);
      resolve({ code, signal });
    };
    handle.child.once('close', done);
    timer = setTimeout(() => {
      handle.child.removeListener('close', done);
      reject(new Error(`等待子进程退出超时：${handle.stderr()}`));
    }, timeout);
  });
}

async function until(check, message, timeout = 5000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    if (check()) return;
    await wait(10);
  }
  assert.fail(message);
}

function childPaths(root, label) {
  const directory = path.join(root, 'child-results');
  fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
  return {
    result: path.join(directory, `${label}-result.json`),
    held: path.join(directory, `${label}-held`),
    release: path.join(directory, `${label}-release`),
  };
}

async function runChild(mode, root, label, options = {}) {
  const files = childPaths(root, label);
  const handle = startChild(mode, { root, ...files, ...options });
  const exited = await waitForExit(handle);
  assert.equal(exited.code, 0, handle.stderr());
  assert.equal(exited.signal, null, handle.stderr());
  assert.equal(fs.existsSync(files.result), true, `子进程 ${label} 缺少结果`);
  return { ...readJson(files.result), files };
}

function prepareRuntimeRoot(root) {
  for (const name of ['config', 'data/runtime', 'data/analytics']) {
    fs.mkdirSync(path.join(root, name), { recursive: true, mode: 0o700 });
  }
  for (const name of ['handoff', 'keyword', 'menu', 'tags', 'feedback']) {
    fs.copyFileSync(path.join(project, `config/${name}.yaml.example`),
      path.join(root, `config/${name}.yaml`));
  }
  writeJson(path.join(root, 'config/runtime.yaml'), {
    schema_version: 2, enabled: true, revision: 1, applied_revision: 1, disable_epoch: 0,
  });
  const menu = readJson(path.join(root, 'config/menu.yaml'));
  menu.welcome.enabled = false;
  writeJson(path.join(root, 'config/menu.yaml'), menu);
  const keyword = readJson(path.join(root, 'config/keyword.yaml'));
  keyword.rules.unshift({
    id: 'process-crash-recovery', name: '受控进程崩溃恢复', enabled: true,
    match_mode: 'exact', keywords: ['受控跨进程恢复问题'], exclude_keywords: [],
    priority: 1000, action: 'reply', text: '受控跨进程恢复答案。', cooldown_seconds: 0,
  });
  writeJson(path.join(root, 'config/keyword.yaml'), keyword);
  const prompt = '受控跨进程恢复测试提示词。';
  fs.writeFileSync(path.join(root, 'config/prompt.md'), prompt, { mode: 0o600 });

  const mapPath = path.join(root, 'data/runtime/knowledge-map.json');
  writeJson(mapPath, { schema_version: 2, revision: 1, documents: [] });
  const mapRaw = fs.readFileSync(mapPath);
  const settingsPath = path.join(root, 'data/runtime/knowledge-settings.json');
  writeJson(settingsPath, {
    schema_version: 1, workspace_slug: runtimeEnvironment.ANYTHINGLLM_WORKSPACE,
    temperature: 0.2, observed_at: Date.now(),
  });
  const lexicalPayload = {
    schema_version: 2, algorithm: 'crispai-lexical-v2', map_sha256: digest(mapRaw),
    complete: true,
    coverage: { source_documents: 0, indexed_documents: 0, omitted_documents: 0,
      source_bytes: 0, indexed_bytes: 0, omitted_bytes: 0, reasons: [] },
    passages: [],
  };
  const lexicalPath = path.join(root, 'data/runtime/knowledge-lexical.json');
  writeJson(lexicalPath, { ...lexicalPayload,
    payload_sha256: digest(canonical(lexicalPayload)) });
  const configuration = Object.fromEntries(
    ['runtime', 'handoff', 'keyword', 'menu', 'tags', 'feedback']
      .map((name) => [name, readJson(path.join(root, `config/${name}.yaml`))]));
  const knowledge = {
    catalog_revision: 1, catalog_sha256: digest(canonical({ fixture: 'process-fencing' })),
    manifest_sha256: digest(canonical({ documents: [] })), map_sha256: digest(mapRaw),
    settings_sha256: digest(fs.readFileSync(settingsPath)), profile_sha256: '',
    lexical_sha256: digest(fs.readFileSync(lexicalPath)), enabled_library_ids: [],
    library_count: 0, document_count: 0, enabled_document_count: 0,
  };
  const runtimeSource = structuredClone(configuration.runtime);
  delete runtimeSource.revision;
  delete runtimeSource.applied_revision;
  const sourceComponents = {
    runtime: digest(canonical(runtimeSource)),
    handoff: digest(canonical(configuration.handoff)),
    keyword: digest(canonical(configuration.keyword)),
    menu: digest(canonical(configuration.menu)),
    tags: digest(canonical(configuration.tags)),
    feedback: digest(canonical(configuration.feedback)),
    prompt: digest(prompt),
    knowledge: digest(canonical(knowledge)),
  };
  writeJson(path.join(root, 'config/materials-applied.json'), {
    schema_version: 2, state: 'applied', revision: 1, applied_at: Date.now(),
    source_sha256: digest(canonical(sourceComponents)), source_components: sourceComponents,
    configuration, prompt: { text: prompt, sha256: digest(prompt), bytes: Buffer.byteLength(prompt) },
    knowledge,
  });
}

function sessionPaths(root, session) {
  const key = hash(`${website}\0${session}`);
  const file = path.join(root, 'data/runtime', `session-${key}.json`);
  return { key, file, lock: `${file}.lock` };
}

function assertHumanState(root, session) {
  const state = readJson(sessionPaths(root, session).file);
  const jobId = hash(`runtime-process-fencing\0${session}`);
  assert.equal(state.mode, 'human');
  assert.equal(state.generation, 1);
  assert.equal(state.pause_reason, 'operator_reply');
  assert.equal(state.stale_writer_committed, undefined,
    '失去锁的旧写者不得覆盖新人工状态');
  assert.equal(state.jobs.filter((entry) => entry.id === jobId).length, 1,
    '跨进程恢复不得复制或丢失原问题责任');
  const job = state.jobs.find((entry) => entry.id === jobId);
  assert.equal(job.status, 'cancelled');
  assert.equal(job.responsibility_status, 'intentional_silence');
  assert.equal(job.responsibility_reason, 'human_reply');
}

function ageRuntimeLock(lock) {
  const ownerFile = path.join(lock, 'owner.json');
  if (fs.existsSync(ownerFile)) {
    const owner = readJson(ownerFile);
    owner.heartbeat_at = Date.now() - 61000;
    writeJson(ownerFile, owner);
  }
  const old = new Date(Date.now() - 61000);
  fs.utimesSync(lock, old, old);
}

function removeExactLock(lock) {
  if (!fs.existsSync(lock)) return;
  for (const name of fs.readdirSync(lock)) fs.unlinkSync(path.join(lock, name));
  fs.rmdirSync(lock);
}

async function testRuntimeProcessFencing(root) {
  const liveSession = 'session_process-live-owner';
  assert.equal((await runChild('--runtime-child', root, 'live-init', {
    action: 'initialize', session: liveSession,
  })).ok, true);
  const liveFiles = childPaths(root, 'live-holder');
  const liveHolder = startChild('--runtime-child', {
    root, ...liveFiles, action: 'hold-stale-writer', session: liveSession,
  });
  await until(() => fs.existsSync(liveFiles.held), '活动会话 owner 未进入事务');
  const blocked = await runChild('--runtime-child', root, 'live-contender', {
    action: 'human-control', session: liveSession,
  });
  assert.equal(blocked.ok, false);
  assert.match(blocked.message, /会话状态忙/);
  assert.equal(liveHolder.child.exitCode, null, '竞争者不得终止或抢占活动 owner');
  fs.writeFileSync(liveFiles.release, 'release', { mode: 0o600 });
  assert.equal((await waitForExit(liveHolder)).code, 0, liveHolder.stderr());
  assert.equal(readJson(liveFiles.result).ok, true);
  const liveState = readJson(sessionPaths(root, liveSession).file);
  assert.equal(liveState.stale_writer_committed, true);
  assert.equal(liveState.jobs.length, 1);

  const deadSession = 'session_process-dead-owner';
  assert.equal((await runChild('--runtime-child', root, 'dead-init', {
    action: 'initialize', session: deadSession,
  })).ok, true);
  const deadFiles = childPaths(root, 'dead-holder');
  const deadHolder = startChild('--runtime-child', {
    root, ...deadFiles, action: 'hold-stale-writer', session: deadSession,
  });
  await until(() => fs.existsSync(deadFiles.held), '待终止会话 owner 未进入事务');
  deadHolder.child.kill('SIGKILL');
  assert.equal((await waitForExit(deadHolder)).signal, 'SIGKILL');
  const deadLock = sessionPaths(root, deadSession).lock;
  assert.equal(fs.existsSync(path.join(deadLock, 'owner.json')), true,
    '受控崩溃必须留下可识别 owner');
  ageRuntimeLock(deadLock);
  const recoveredDead = await runChild('--runtime-child', root, 'dead-recovery', {
    action: 'human-control', session: deadSession,
  });
  assert.equal(recoveredDead.ok, true, recoveredDead.message);
  assertHumanState(root, deadSession);

  const emptySession = 'session_process-empty-owner';
  assert.equal((await runChild('--runtime-child', root, 'empty-init', {
    action: 'initialize', session: emptySession,
  })).ok, true);
  const emptyLock = sessionPaths(root, emptySession).lock;
  fs.mkdirSync(emptyLock, { mode: 0o700 });
  const premature = await runChild('--runtime-child', root, 'empty-premature', {
    action: 'mark-recovered', marker: 'premature', session: emptySession,
  });
  assert.equal(premature.ok, false, '无 owner 新锁在保守期内不得被抢占');
  assert.match(premature.message, /会话状态忙/);
  ageRuntimeLock(emptyLock);
  const recoveredEmpty = await runChild('--runtime-child', root, 'empty-recovery', {
    action: 'mark-recovered', marker: 'after-timeout', session: emptySession,
  });
  assert.equal(recoveredEmpty.ok, true, recoveredEmpty.message);
  assert.equal(readJson(sessionPaths(root, emptySession).file).recovered_by, 'after-timeout');

  const fencedSession = 'session_process-stale-writer';
  assert.equal((await runChild('--runtime-child', root, 'fenced-init', {
    action: 'initialize', session: fencedSession,
  })).ok, true);
  const fencedFiles = childPaths(root, 'fenced-holder');
  const staleWriter = startChild('--runtime-child', {
    root, ...fencedFiles, action: 'hold-stale-writer', session: fencedSession,
  });
  await until(() => fs.existsSync(fencedFiles.held), '旧写者未进入受控事务');
  const lock = sessionPaths(root, fencedSession).lock;
  const quarantine = `${lock}.fixture-stale`;
  fs.renameSync(lock, quarantine);
  const currentWriter = await runChild('--runtime-child', root, 'fenced-current', {
    action: 'human-control', session: fencedSession,
  });
  assert.equal(currentWriter.ok, true, currentWriter.message);
  fs.writeFileSync(fencedFiles.release, 'release', { mode: 0o600 });
  assert.equal((await waitForExit(staleWriter)).code, 0, staleWriter.stderr());
  const staleResult = readJson(fencedFiles.result);
  assert.equal(staleResult.ok, false, '已失去 owner 的旧事务不得写回');
  assert.match(staleResult.message, /所有权已变化/);
  assertHumanState(root, fencedSession);
  removeExactLock(quarantine);
}

async function testRuntimeClaimCrashRecovery(root) {
  const session = 'session_process-claim-crash';
  const fingerprint = 70002;
  const content = '受控跨进程恢复问题';
  const answer = '受控跨进程恢复答案。';
  const clockPath = path.join(root, 'child-results/process-claim-clock.json');
  const startedAt = Date.now();
  writeJson(clockPath, { now: startedAt });
  const fixtureClock = () => readJson(clockPath).now;
  const exactMessage = {
    website_id: website, session_id: session, from: 'user', type: 'text',
    content, fingerprint, timestamp: startedAt,
  };
  const crispPosts = [];
  const networkKinds = [];
  const request = async (url, options = {}) => {
    const parsed = new URL(url);
    const method = options.method || 'GET';
    if (method === 'GET' && parsed.pathname.endsWith(`/message/${fingerprint}`)) {
      networkKinds.push('exact_message');
      return { status: 200, body: { error: false, data: structuredClone(exactMessage) } };
    }
    if (method === 'GET' && parsed.pathname.endsWith('/messages')) {
      networkKinds.push('message_history');
      return { status: 200, body: { error: false,
        data: [structuredClone(exactMessage), ...crispPosts.map((entry) => structuredClone(entry))] } };
    }
    if (method === 'POST' && parsed.pathname.endsWith('/message')) {
      networkKinds.push('message_post');
      crispPosts.push(structuredClone(options.body));
      return { status: 200, body: { error: false, reason: 'dispatched',
        data: { fingerprint: options.body.fingerprint } } };
    }
    throw new Error(`恢复夹具出现未授权请求：${method}`);
  };
  const runtimeOptions = (network) => ({
    root, request: network, clock: fixtureClock, processingPermitClock: fixtureClock,
  });
  const ingress = createRuntime(runtimeEnvironment, runtimeOptions(
    async () => { throw new Error('持久接收阶段不应访问网络'); }));
  const event = {
    website_id: website, event: 'message:send',
    data: { session_id: session, from: 'user', type: 'text', content, fingerprint },
  };
  const accepted = await ingress.receive({ body: event,
    query: { key: runtimeEnvironment.CRISP_WEBSITE_HOOK_SECRET } });
  assert.equal(accepted.accepted, true);
  assert.equal(accepted.route, 'process');
  const beforeClaim = readJson(sessionPaths(root, session).file);
  assert.equal(beforeClaim.jobs.filter((entry) => entry.id === accepted.jobId).length, 1);
  const receivedJob = beforeClaim.jobs.find((entry) => entry.id === accepted.jobId);
  assert.equal(receivedJob.status, 'received');
  assert.equal(receivedJob.attempts, 0);
  assert.equal(receivedJob.event_time_unverified, true);
  assert.equal(receivedJob.data.content, content);

  const files = childPaths(root, 'process-claim-crash');
  let worker;
  try {
    worker = startChild('--runtime-child', {
      root, ...files, action: 'process-until-killed', session,
      jobId: accepted.jobId, fingerprint, clock: clockPath,
    });
    await until(() => fs.existsSync(files.held),
      '真实 process worker 未在精确消息回查处进入受控等待', 5000);

    const claimed = readJson(sessionPaths(root, session).file);
    assert.equal(claimed.jobs.filter((entry) => entry.id === accepted.jobId).length, 1);
    const claimedJob = claimed.jobs.find((entry) => entry.id === accepted.jobId);
    assert.equal(claimedJob.status, 'processing');
    assert.equal(claimedJob.attempts, 1);
    assert.equal(claimedJob.event_time_unverified, true);
    assert.equal(claimedJob.data.content, content);
    assert.equal(claimedJob.plan, undefined);
    assert.equal(claimedJob.inference, undefined);
    assert.deepEqual(claimed.outgoing, {});
    assert.equal(claimed.worker?.job, accepted.jobId);
    assert.equal(claimed.worker?.token, claimedJob.execution_token);
    assert.equal(claimedJob.lease_until > fixtureClock(), true);

    const permitDirectory = path.join(root, 'data/runtime/ordinary-processing-permits');
    const claimedSlots = fs.readdirSync(permitDirectory)
      .filter((name) => /^slot-[0-7]$/.test(name));
    assert.equal(claimedSlots.length, 1, '崩溃点必须持有且只持有一个普通执行许可');
    const deadPermitOwner = readJson(path.join(permitDirectory, claimedSlots[0], 'owner.json'));
    assert.equal(deadPermitOwner.kind, 'ordinary');
    assert.equal(deadPermitOwner.expires_at > fixtureClock(), true);

    worker.child.kill('SIGKILL');
    const killed = await waitForExit(worker, 5000);
    assert.equal(killed.signal, 'SIGKILL');
    assert.equal(fs.existsSync(files.result), false,
      '被终止的 worker 不得伪造完成回执');

    writeJson(clockPath, { now: claimedJob.lease_until + 1 });
    const recovery = createRuntime(runtimeEnvironment, runtimeOptions(request));
    const selected = await recovery.scan();
    assert.equal(selected.filter((entry) => entry.key === accepted.key
      && entry.jobId === accepted.jobId).length, 1,
    '租约到期后 scanner 必须只选择同一原始责任');
    let state = readJson(sessionPaths(root, session).file);
    let job = state.jobs.find((entry) => entry.id === accepted.jobId);
    assert.equal(state.jobs.filter((entry) => entry.id === accepted.jobId).length, 1);
    assert.equal(state.worker, null);
    assert.equal(job.status, 'received');
    assert.equal(job.attempts, 1);
    assert.equal(job.lease_until, 0);
    assert.equal(job.execution_token, undefined);
    assert.equal(job.data.content, content);
    assert.equal(job.responsibility_status, 'pending');
    assert.equal(fs.readdirSync(permitDirectory).filter((name) => /^slot-[0-7]$/.test(name)).length, 1,
      'scan 只恢复业务租约；dead permit 应由下一次真实 process 原子回收');

    const recovered = await recovery.process(accepted.key, accepted.jobId);
    assert.equal(recovered.status, 'sent');
    state = readJson(sessionPaths(root, session).file);
    job = state.jobs.find((entry) => entry.id === accepted.jobId);
    assert.equal(state.jobs.filter((entry) => entry.id === accepted.jobId).length, 1);
    assert.equal(job.status, 'done');
    assert.equal(job.attempts, 2,
      '崩溃 claim 与恢复 claim 都必须保留在累计处理审计中');
    assert.equal(job.responsibility_status, 'answered_confirmed');
    assert.equal(job.id, accepted.jobId);
    assert.equal(crispPosts.length, 1);
    assert.equal(crispPosts[0].content, answer);
    const outgoing = Object.values(state.outgoing)
      .filter((entry) => entry?.job_id === accepted.jobId);
    assert.equal(outgoing.length, 1);
    assert.equal(outgoing[0].status, 'sent');
    assert.equal(networkKinds.filter((kind) => kind === 'exact_message').length, 1);
    assert.equal(networkKinds.filter((kind) => kind === 'message_post').length, 1);
    assert.equal(fs.readdirSync(permitDirectory)
      .some((name) => /^slot-[0-7]$|^\.stale-slot-/.test(name)), false,
    '恢复 process 完成后必须同时释放 dead permit 与当前 permit');

    const repeatedScan = await recovery.scan();
    assert.equal(repeatedScan.some((entry) => entry.key === accepted.key
      && entry.jobId === accepted.jobId), false);
    assert.equal((await recovery.process(accepted.key, accepted.jobId)).status, 'idle');
    assert.equal(crispPosts.length, 1,
      '重复 scan/process 不得再次 POST 同一问题答案');
  } finally {
    if (worker && worker.child.exitCode === null && worker.child.signalCode === null) {
      try { worker.child.kill('SIGKILL'); } catch (_) {}
    }
    if (worker) {
      try { await waitForExit(worker, 5000); } catch (_) {}
    }
  }
}

function procStart(pid) {
  const value = fs.readFileSync(`/proc/${pid}/stat`, 'utf8');
  const end = value.lastIndexOf(') ');
  assert(end > 0);
  return value.slice(end + 2).trim().split(/\s+/)[19];
}

function prepareRouterRoot(root) {
  for (const name of ['config', 'data/provider-router', 'secrets/provider/generations']) {
    fs.mkdirSync(path.join(root, name), { recursive: true, mode: 0o700 });
  }
  const generation = 'a'.repeat(32);
  const entryId = `p_${'1'.repeat(24)}`;
  writeJson(path.join(root, 'config/provider-pool-applied.json'), {
    schema_version: 1, revision: 1, secrets_generation: generation, primary_id: entryId,
    entries: [{
      id: entryId, name: '受控进程锁接口', role: 'primary', order: 0, enabled: true,
      base_url: 'https://provider-lock.invalid/v1', model: 'synthetic-lock-model',
      api_mode: 'chat_completions', custom_header_names: [],
      capabilities: { chat_completions: true, responses: false, vision: false },
      context_window: 8192, max_output_tokens: 256,
    }],
    policy: { ...DEFAULT_POLICY, question_timeout_ms: 5000, call_timeout_ms: 1000,
      connect_timeout_ms: 100, max_attempts: 1 },
  });
  writeJson(path.join(root, 'secrets/provider/generations', `${generation}.json`), {
    schema_version: 1, generation, revision: 1,
    entries: { [entryId]: { api_key: 'synthetic-router-lock-key', custom_headers: {} } },
  });
}

async function testRouterProcessLocks(root) {
  const routerRoot = path.join(root, 'router');
  prepareRouterRoot(routerRoot);
  const stateLock = path.join(routerRoot, 'data/provider-router/.state.lock');
  const blockerFiles = childPaths(root, 'router-live-blocker');
  const blocker = startChild('--blocker-child', { ...blockerFiles });
  await until(() => fs.existsSync(blockerFiles.held), '活动路由锁 owner 子进程未就绪');
  fs.mkdirSync(stateLock, { mode: 0o700 });
  writeJson(path.join(stateLock, 'owner.json'), {
    schema_version: 1, token: 'b'.repeat(48), boot: 'synthetic-live-owner',
    pid: blocker.child.pid, started: procStart(blocker.child.pid), acquired_at: Date.now(),
  });
  const liveBlocked = await runChild('--router-child', root, 'router-live-contender', { root: routerRoot });
  assert.equal(liveBlocked.ok, false, '活动 router owner 不得被另一个 OS 进程抢占');
  assert.equal(liveBlocked.code, 'state_busy');
  blocker.child.kill('SIGKILL');
  assert.equal((await waitForExit(blocker)).signal, 'SIGKILL');
  const deadRecovered = await runChild('--router-child', root, 'router-dead-recovery', { root: routerRoot });
  assert.equal(deadRecovered.ok, true, deadRecovered.message);

  fs.mkdirSync(stateLock, { mode: 0o700 });
  const freshOwnerless = await runChild('--router-child', root, 'router-ownerless-fresh', { root: routerRoot });
  assert.equal(freshOwnerless.ok, false, '刚形成的无 owner 锁必须等待保守恢复期');
  assert.equal(freshOwnerless.code, 'state_busy');
  const old = new Date(Date.now() - 6000);
  fs.utimesSync(stateLock, old, old);
  const ownerlessRecovered = await runChild('--router-child', root, 'router-ownerless-recovery', { root: routerRoot });
  assert.equal(ownerlessRecovered.ok, true, ownerlessRecovered.message);

  const first = startChild('--router-child', {
    root: routerRoot, ...childPaths(root, 'router-concurrent-a'),
  });
  const second = startChild('--router-child', {
    root: routerRoot, ...childPaths(root, 'router-concurrent-b'),
  });
  assert.equal((await waitForExit(first)).code, 0, first.stderr());
  assert.equal((await waitForExit(second)).code, 0, second.stderr());
  assert.equal(readJson(childPaths(root, 'router-concurrent-a').result).ok, true);
  assert.equal(readJson(childPaths(root, 'router-concurrent-b').result).ok, true);
  const routerState = readJson(path.join(routerRoot, 'data/provider-router/state.json'));
  assert.equal(routerState.state_revision, 4,
    'dead恢复、无owner恢复及两个并发进程的状态写入必须全部串行保留');
  assert.equal(fs.existsSync(stateLock), false, '所有 owner 退出后不得遗留活动锁');
}

async function main() {
  const area = path.join(project, '.work', 'v1.3.0');
  fs.mkdirSync(area, { recursive: true, mode: 0o700 });
  const root = fs.mkdtempSync(path.join(area, 'runtime-process-fencing-'));
  let complete = false;
  try {
    prepareRuntimeRoot(root);
    await testRuntimeProcessFencing(root);
    process.stdout.write('通过 UNIT/CONTRACT：OS子进程会话owner活动锁、崩溃恢复、无owner保守期与旧写回fencing\n');
    await testRuntimeClaimCrashRecovery(root);
    process.stdout.write('通过 UNIT/CONTRACT：真实process claim后崩溃由租约恢复同一责任且仅发送一份答案\n');
    await testRouterProcessLocks(root);
    process.stdout.write('通过 UNIT/CONTRACT：Provider路由锁活owner、dead/无owner恢复及并发发布不丢写\n');
    writeJson(path.join(root, 'result.json'), {
      layer: 'UNIT/CONTRACT', passed: 3, failed: 0, real_external: false,
    });
    complete = true;
  } finally {
    const remaining = [...activeChildren];
    for (const child of remaining) {
      try { child.kill('SIGKILL'); } catch (_) {}
    }
    await Promise.all(remaining.map((child) => new Promise((resolve) => {
      let timer = null;
      const done = () => {
        if (timer) clearTimeout(timer);
        resolve();
      };
      if (child.exitCode !== null || child.signalCode !== null) return done();
      child.once('close', done);
      timer = setTimeout(() => {
        child.removeListener('close', done);
        resolve();
      }, 5000);
    })));
    if (complete) fs.rmSync(root, { recursive: true, force: true });
  }
}
