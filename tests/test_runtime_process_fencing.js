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
};

const runtimeChild = async (options) => {
  const runtime = createRuntime(runtimeEnvironment, {
    root: options.root,
    request: async () => { throw new Error('跨进程会话事务负例不应访问网络'); },
  });
  const key = runtime.stateKey(website, options.session);
  const jobId = hash(`runtime-process-fencing\0${options.session}`);
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
    await testRouterProcessLocks(root);
    process.stdout.write('通过 UNIT/CONTRACT：Provider路由锁活owner、dead/无owner恢复及并发发布不丢写\n');
    writeJson(path.join(root, 'result.json'), {
      layer: 'UNIT/CONTRACT', passed: 2, failed: 0, real_external: false,
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
