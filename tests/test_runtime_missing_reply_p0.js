'use strict';

const assert = require('assert/strict');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { createRuntime } = require('../n8n/runtime');

const project = path.resolve(__dirname, '..');
const workRoot = path.join(project, '.work', 'v1.2.1');
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

const fixture = (name) => {
  const root = path.join(work, name);
  const runtimeDirectory = path.join(root, 'data', 'runtime');
  fs.mkdirSync(path.join(root, 'config'), { recursive: true });
  fs.mkdirSync(runtimeDirectory, { recursive: true });
  for (const config of ['handoff', 'keyword', 'menu', 'tags', 'feedback', 'provider']) {
    fs.copyFileSync(path.join(project, 'config', config + '.yaml.example'), path.join(root, 'config', config + '.yaml'));
  }
  fs.writeFileSync(path.join(root, 'config', 'runtime.yaml'), JSON.stringify({ schema_version: 2, enabled: true, revision: 1, applied_revision: 1 }));
  fs.writeFileSync(path.join(root, 'config', 'prompt.md'), '受控测试提示');
  let now = 1760000000000;
  const request = async (url, options = {}) => {
    const parsed = new URL(url);
    if (/\/message\//.test(parsed.pathname)) {
      const fingerprint = decodeURIComponent(parsed.pathname.split('/').at(-1));
      return { status: 200, body: { error: false, data: { from: 'operator', type: 'text', fingerprint } } };
    }
    if (parsed.pathname.endsWith('/meta') && options.method === 'GET') return { status: 200, body: { error: false, data: { segments: [] } } };
    if (parsed.pathname.endsWith('/meta') && options.method === 'PATCH') return { status: 200, body: { error: false } };
    throw new Error('未预期受控网络请求');
  };
  const options = { root, clock: () => now, request,
    lookup: (_host, _options, callback) => callback(null, [{ address: '8.8.8.8', family: 4 }]) };
  let runtime = createRuntime(env, options);
  return {
    root, runtimeDirectory, options,
    get runtime() { return runtime; },
    restart() { runtime = createRuntime(env, options); return runtime; },
    tick(milliseconds = 5000) { now += milliseconds; },
    now: () => now,
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
  revision: 1, generation: 0, control: false, lease_until: 0, retry_at: null, ...extra,
});
const stateFile = (fx, session) => path.join(fx.runtimeDirectory, 'session-' + fx.runtime.stateKey(website, session) + '.json');
const writeState = (fx, session, value) => fs.writeFileSync(stateFile(fx, session), JSON.stringify(value), { mode: 0o600 });
const webhook = (fx, session, content, fingerprint, extra = {}) => fx.runtime.receive({
  query: { key: env.CRISP_WEBSITE_HOOK_SECRET },
  body: { website_id: website, event: extra.event || 'message:send', timestamp: fx.now(), data: {
    session_id: session, from: extra.from || 'user', type: 'text', content, fingerprint,
    timestamp: fx.now(), ...(extra.automated === undefined ? {} : { automated: extra.automated }),
  } },
});
let passed = 0;
const test = async (name, action) => {
  await action();
  passed += 1;
  process.stdout.write('通过 P0/REGRESSION ' + name + '\n');
};

(async () => {
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

  await test('operator 解析提交连续失败三次后原子建立 unknown fence', async () => {
    const fx = fixture('operator-retry-fence');
    const session = 'session_operator-eio';
    const accepted = await webhook(fx, session, '真人消息', 40000, { event: 'message:received', from: 'operator' });
    assert.equal(accepted.statusCode, 200);
    const file = stateFile(fx, session);
    const originalRename = fs.renameSync;
    let rejectedFenceCommits = 0;
    fs.renameSync = function (source, target) {
      if (path.resolve(String(target)) === path.resolve(file) && String(source).includes('.tmp-')) {
        const candidate = JSON.parse(fs.readFileSync(source, 'utf8'));
        const control = candidate.jobs.find((entry) => entry.id === accepted.jobId);
        if (control?.status === 'processing' && !candidate.uncertain_events.includes(accepted.jobId)
          && control.operator_resolution?.result === 'unknown' && control.operator_resolution.recovered !== true) {
          rejectedFenceCommits += 1;
          const error = new Error('受控原子 rename 瞬时失败');
          error.code = 'EIO';
          throw error;
        }
      }
      return originalRename.apply(this, arguments);
    };
    try {
      for (let attempt = 0; attempt < 3; attempt += 1) {
        assert.equal((await fx.runtime.process(accepted.key, accepted.jobId)).status, 'failed');
        fx.tick(6000);
      }
    } finally { fs.renameSync = originalRename; }
    assert.equal(rejectedFenceCommits, 3);
    const recovered = fx.runtime.readState(accepted.key);
    const control = recovered.jobs.find((entry) => entry.id === accepted.jobId);
    assert.equal(control.status, 'done');
    assert.equal(control.operator_resolution.result, 'unknown');
    assert.equal(control.operator_resolution.recovered, true);
    assert(!recovered.uncertain_events.includes(accepted.jobId));
    const visitor = await webhook(fx, session, '栅栏后的新问题', 40001);
    assert.equal(visitor.statusCode, 200);
    assert.equal(visitor.route, 'process');
  });

  await test('scan 自愈旧版 terminal/missing barrier，且保留 human/not-human 已知结果', async () => {
    const fx = fixture('operator-orphan-migration');
    const cases = [
      { name: 'human', resolution: { schema_version: 1, result: 'human', human_changed: true }, selected: false },
      { name: 'not-human', resolution: { schema_version: 1, result: 'not-human', human_changed: false }, selected: true },
      { name: 'unknown', resolution: null, selected: true },
      { name: 'missing', missing: true, selected: true },
    ];
    const expectedKeys = new Set();
    for (const item of cases) {
      const session = 'session_orphan-' + item.name;
      const controlId = digest('control-' + item.name);
      const visitor = jobValue(fx, 'visitor-' + item.name, 2, { deferred_control: true, generation: 7 });
      const jobs = item.missing ? [visitor] : [jobValue(fx, 'control-' + item.name, 1, {
        id: controlId, event: 'message:received', data: undefined, control: true, action: 'resolve_operator',
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
      assert.deepEqual(current.uncertain_events, []);
      if (item.name === 'human') {
        assert.equal(current.mode, 'human');
        assert.equal(current.jobs.find((entry) => !entry.control).status, 'cancelled');
        assert.equal(current.jobs.find((entry) => entry.control).operator_resolution.result, 'human');
      } else {
        const visitor = current.jobs.find((entry) => !entry.control);
        assert.equal(visitor.status, 'received');
        assert.equal(visitor.generation, current.generation);
        assert.equal(visitor.deferred_control, undefined);
        if (item.name === 'not-human') assert.equal(current.generation, 7);
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

  await test('超过16会话的普通任务在重建 runtime 后继续轮转', async () => {
    const fx = fixture('fair-restart');
    const all = new Set();
    for (let index = 0; index < 21; index += 1) {
      const session = 'session_fair-' + String(index).padStart(3, '0');
      const key = fx.runtime.stateKey(website, session);
      all.add(key);
      writeState(fx, session, stateValue(fx, session, [jobValue(fx, 'round-' + index)]));
    }
    const first = await fx.runtime.scan();
    assert.equal(first.length, 16);
    const firstKeys = new Set(first.map((entry) => entry.key));
    fx.restart();
    const second = await fx.runtime.scan();
    assert.equal(second.length, 16);
    const secondKeys = new Set(second.map((entry) => entry.key));
    assert.equal(new Set([...firstKeys, ...secondKeys]).size, all.size);
    assert.notDeepEqual([...firstKeys].sort(), [...secondKeys].sort());
    const health = JSON.parse(fs.readFileSync(path.join(fx.runtimeDirectory, 'scheduler-health.json'), 'utf8'));
    assert.equal(health.ordinary_cursor, 32);
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
    assert.equal(first.length, 16);
    assert(first.slice(0, 15).every((entry) => entry.control));
    assert.equal(first[15].control, false);
    fx.restart();
    const second = await fx.runtime.scan();
    assert(second.slice(0, 15).every((entry) => entry.control));
    assert.equal(second[15].control, false);
    assert.notEqual(first[15].key, second[15].key);
    assert([...new Set([...first.slice(0, 15).map((entry) => entry.key),
      ...second.slice(0, 15).map((entry) => entry.key)])].length > 15);
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

  process.stdout.write('聚焦 P0 回归完成：' + passed + '/13\n');
})().catch((error) => {
  process.stderr.write((error && error.stack) || String(error));
  process.stderr.write('\n');
  process.exitCode = 1;
});
