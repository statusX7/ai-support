'use strict';

const assert = require('assert/strict');
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const project = path.resolve(__dirname, '..');
fs.mkdirSync(path.join(project, '.work', 'v1.1.0'), { recursive: true });
const evidence = fs.mkdtempSync(path.join(project, '.work', 'v1.1.0', 'guards-'));
let passed = 0;
const record = (name) => { passed += 1; process.stdout.write('通过 UNIT/CONTRACT ' + name + '\n'); };
const cases = [
  ['safe-json', '{"provider":{"api_key_env":"AI_API_KEY","custom_header_names":["X-Test"]}}', 1],
  ['safe-legacy', 'provider:\n  api_key_env: AI_API_KEY\n  model: synthetic-model\n', 1],
  ['json-key', '{"provider":{"api_key":"synthetic-only"}}', 0],
  ['nested-array', '{"provider":{"nested":[{"token":"synthetic-only"}]}}', 0],
  ['nested-authorization', '{"provider":{"headers":{"Authorization":"synthetic-only"}}}', 0],
  ['custom-headers', '{"provider":{"custom_headers":{"X-Secret":"synthetic-only"}}}', 0],
  ['quoted-yaml', 'provider:\n  "password": "synthetic-only"\n', 0],
  ['malformed-mixed', '{"provider":{"model":"test"}}\napi_key: synthetic-only\n', 0],
];
for (const [name, input, expected] of cases) {
  const file = path.join(evidence, name + '.yaml');
  fs.writeFileSync(file, input, { mode: 0o600 });
  const result = spawnSync('bash', ['-c', 'source scripts/common.sh; provider_config_has_secret_field "$1"', 'guard', file], { cwd: project, encoding: 'utf8' });
  assert.equal(result.status, expected, name + ': ' + result.stderr);
  record('Provider 导出秘密边界 ' + name);
}
const envFile = path.join(evidence, '.env');
const value = 'synthetic $dollar #hash =equal "double" \'single\' \\path';
const result = spawnSync('bash', ['-c', 'source scripts/common.sh; IFS= read -r value; env_set "$1" ROUNDTRIP "$value"; env_get "$1" ROUNDTRIP', 'guard', envFile], { cwd: project, input: value + '\n', encoding: 'utf8' });
assert.equal(result.status, 0, result.stderr);
assert.equal(result.stdout.replace(/\n$/, ''), value);
assert.equal(fs.statSync(envFile).mode & 0o777, 0o600);
record('特殊字符环境值经生产序列化逐字往返、权限600');
const updatedValue = 'synthetic-existing-value';
const updated = spawnSync('bash', ['-c', 'source scripts/common.sh; env_set "$1" ROUNDTRIP "$2"; env_get "$1" ROUNDTRIP', 'guard', envFile, updatedValue], { cwd: project, encoding: 'utf8' });
assert.equal(updated.status, 0, updated.stderr);
assert.equal(updated.stdout.replace(/\n$/, ''), updatedValue);
assert.equal(fs.existsSync(envFile + '.crispai-atomic.json'), false);
assert.equal(fs.existsSync(envFile + '.crispai-atomic.next'), false);
assert.deepEqual(fs.readdirSync(evidence).filter(name => name.startsWith('.env.source.')
  || name.startsWith('.env.tmp.')), []);
record('现有普通单链接环境配置经完整读取后原子更新');
const envGuardRoot = path.join(evidence, 'env-target-guards');
fs.mkdirSync(envGuardRoot);
const outsideEnv = path.join(envGuardRoot, 'outside.env');
fs.writeFileSync(outsideEnv, 'SAFE=outside\n', { mode: 0o600 });
const symlinkEnv = path.join(envGuardRoot, 'symlink.env');
fs.symlinkSync(outsideEnv, symlinkEnv);
let guarded = spawnSync('bash', ['-c', 'source scripts/common.sh; env_set "$1" SAFE changed', 'guard', symlinkEnv], { cwd: project, encoding: 'utf8' });
assert.notEqual(guarded.status, 0, guarded.stderr);
assert.equal(fs.readFileSync(outsideEnv, 'utf8'), 'SAFE=outside\n');
assert.equal(fs.readlinkSync(symlinkEnv), outsideEnv);
record('环境配置拒绝符号链接且不改写链接目标');
const hardlinkSource = path.join(envGuardRoot, 'hardlink-source.env');
const hardlinkEnv = path.join(envGuardRoot, 'hardlink.env');
fs.writeFileSync(hardlinkSource, 'SAFE=hardlink\n', { mode: 0o600 });
fs.linkSync(hardlinkSource, hardlinkEnv);
guarded = spawnSync('bash', ['-c', 'source scripts/common.sh; env_set "$1" SAFE changed', 'guard', hardlinkEnv], { cwd: project, encoding: 'utf8' });
assert.notEqual(guarded.status, 0, guarded.stderr);
assert.equal(fs.readFileSync(hardlinkSource, 'utf8'), 'SAFE=hardlink\n');
assert.equal(fs.readFileSync(hardlinkEnv, 'utf8'), 'SAFE=hardlink\n');
record('环境配置拒绝多链接文件且不改写共享 inode');
const directoryEnv = path.join(envGuardRoot, 'directory.env');
fs.mkdirSync(directoryEnv);
guarded = spawnSync('bash', ['-c', 'source scripts/common.sh; env_set "$1" SAFE changed', 'guard', directoryEnv], { cwd: project, encoding: 'utf8' });
assert.notEqual(guarded.status, 0, guarded.stderr);
assert.equal(fs.statSync(directoryEnv).isDirectory(), true);
record('环境配置拒绝目录目标且保留原对象');
const failedReadEnv = path.join(envGuardRoot, 'read-failure.env');
fs.writeFileSync(failedReadEnv, 'SAFE=before\n', { mode: 0o600 });
const wrapperDirectory = path.join(envGuardRoot, 'bin');
fs.mkdirSync(wrapperDirectory);
const cpWrapper = path.join(wrapperDirectory, 'cp');
fs.writeFileSync(cpWrapper, '#!/usr/bin/env bash\nexit 74\n', { mode: 0o700 });
guarded = spawnSync('bash', ['-c', 'source scripts/common.sh; env_set "$1" SAFE changed', 'guard', failedReadEnv], {
  cwd: project,
  encoding: 'utf8',
  env: { ...process.env, PATH: wrapperDirectory + path.delimiter + process.env.PATH },
});
assert.notEqual(guarded.status, 0, guarded.stderr);
assert.equal(fs.readFileSync(failedReadEnv, 'utf8'), 'SAFE=before\n');
assert.deepEqual(fs.readdirSync(envGuardRoot).filter(name => name.startsWith('read-failure.env.')), []);
record('环境配置源文件未完整复制时拒绝发布且清理临时文件');
const realPython = spawnSync('bash', ['-c', 'command -v python3'], { encoding: 'utf8' }).stdout.trim();
assert(realPython);
const pythonWrapperDirectory = path.join(envGuardRoot, 'python-bin');
fs.mkdirSync(pythonWrapperDirectory);
const pythonWrapper = path.join(pythonWrapperDirectory, 'python3');
fs.writeFileSync(pythonWrapper, `#!/usr/bin/env bash
set -euo pipefail
if [[ \${1:-} == */atomic-config.py && -n \${CRISPAI_TEST_FORCE_EXIT:-} ]]; then
  exit "$CRISPAI_TEST_FORCE_EXIT"
fi
if [[ \${1:-} == */atomic-config.py && \${2:-} == "\${CRISPAI_TEST_RACE_MODE:-}" ]]; then
  race="\${3}.race-\${BASHPID}"
  printf 'SAFE=concurrent\\n' > "$race"
  chmod 600 "$race"
  mv -fT -- "$race" "$3"
fi
exec "$CRISPAI_TEST_REAL_PYTHON" "$@"
`, { mode: 0o700 });
const raceEnvironment = mode => ({ ...process.env,
  PATH: pythonWrapperDirectory + path.delimiter + process.env.PATH,
  CRISPAI_TEST_REAL_PYTHON: realPython,
  CRISPAI_TEST_RACE_MODE: mode,
});
const existingRaceEnv = path.join(envGuardRoot, 'existing-race.env');
fs.writeFileSync(existingRaceEnv, 'SAFE=before\n', { mode: 0o600 });
guarded = spawnSync('bash', ['-c', 'source scripts/common.sh; env_set "$1" SAFE candidate', 'guard', existingRaceEnv], {
  cwd: project, encoding: 'utf8', env: raceEnvironment('replace'),
});
assert.notEqual(guarded.status, 0, guarded.stderr);
assert.equal(fs.readFileSync(existingRaceEnv, 'utf8'), 'SAFE=concurrent\n');
assert.deepEqual(fs.readdirSync(envGuardRoot).filter(name => name.startsWith('existing-race.env.source.')
  || name.startsWith('existing-race.env.tmp.')), []);
record('现有环境配置提交前出现新代时拒绝覆盖并保留竞争者内容');
const createRaceEnv = path.join(envGuardRoot, 'create-race.env');
guarded = spawnSync('bash', ['-c', 'source scripts/common.sh; env_set "$1" SAFE candidate', 'guard', createRaceEnv], {
  cwd: project, encoding: 'utf8', env: raceEnvironment('create'),
});
assert.notEqual(guarded.status, 0, guarded.stderr);
assert.equal(fs.readFileSync(createRaceEnv, 'utf8'), 'SAFE=concurrent\n');
assert.deepEqual(fs.readdirSync(envGuardRoot).filter(name => name.startsWith('create-race.env.source.')
  || name.startsWith('create-race.env.tmp.')), []);
record('新环境配置原子创建遇并发目标时不覆盖且不伪报成功');
const unknownExitEnv = path.join(envGuardRoot, 'unknown-exit.env');
fs.writeFileSync(unknownExitEnv, 'SAFE=before\n', { mode: 0o600 });
guarded = spawnSync('bash', ['-c', 'source scripts/common.sh; env_set "$1" SAFE candidate', 'guard', unknownExitEnv], {
  cwd: project,
  encoding: 'utf8',
  env: { ...process.env, PATH: pythonWrapperDirectory + path.delimiter + process.env.PATH,
    CRISPAI_TEST_REAL_PYTHON: realPython, CRISPAI_TEST_FORCE_EXIT: '137' },
});
assert.notEqual(guarded.status, 0, guarded.stderr);
assert.equal(fs.readFileSync(unknownExitEnv, 'utf8'), 'SAFE=before\n');
const unknownArtifacts = fs.readdirSync(envGuardRoot).filter(name =>
  name.startsWith('unknown-exit.env.source.') || name.startsWith('unknown-exit.env.tmp.'));
assert.equal(unknownArtifacts.length, 2);
for (const name of unknownArtifacts) fs.unlinkSync(path.join(envGuardRoot, name));
record('原子提交未知退出保留旧值与两份受限恢复材料而不误删');
const exchangeRaceFixture = path.join(envGuardRoot, 'exchange-race.py');
fs.writeFileSync(exchangeRaceFixture, String.raw`import importlib.util
import os
from pathlib import Path
import sys

helper = Path(sys.argv[1])
root = Path(sys.argv[2])
spec = importlib.util.spec_from_file_location("crispai_atomic_config", helper)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
target = root / "exchange-target.env"
expected = root / "exchange-expected.env"
candidate = root / "exchange-candidate.env"
for path_value, body in ((target, b"SAFE=before\n"),
                         (expected, b"SAFE=before\n"),
                         (candidate, b"SAFE=candidate\n")):
    path_value.write_bytes(body)
    path_value.chmod(0o600)
identity = target.stat()
real_renameat2 = module.renameat2
injected = False

def racing_renameat2(source, destination, flags):
    global injected
    if flags == module.RENAME_EXCHANGE and not injected:
        injected = True
        replacement = root / "exchange-concurrent.tmp"
        replacement.write_bytes(b"SAFE=concurrent\n")
        replacement.chmod(0o600)
        os.replace(replacement, target)
    return real_renameat2(source, destination, flags)

module.renameat2 = racing_renameat2
status = module.replace(target, expected, candidate, identity.st_dev, identity.st_ino)
assert injected
assert status == module.EXIT_CONFLICT, status
assert target.read_bytes() == b"SAFE=concurrent\n"
assert candidate.read_bytes() == b"SAFE=candidate\n"
assert expected.read_bytes() == b"SAFE=before\n"

crash_target = root / "crash-target.env"
crash_expected = root / "crash-target.env.source.fixture"
crash_candidate = root / "crash-target.env.tmp.fixture"
for path_value, body in ((crash_target, b"SAFE=before\n"),
                         (crash_expected, b"SAFE=before\n"),
                         (crash_candidate, b"SAFE=candidate\n")):
    path_value.write_bytes(body)
    path_value.chmod(0o600)
identity = crash_target.stat()
real_mark_committed = module.mark_committed

def interrupted_commit(*_arguments):
    raise OSError("synthetic interruption before commit acknowledgement")

module.mark_committed = interrupted_commit
status = module.replace(crash_target, crash_expected, crash_candidate,
                        identity.st_dev, identity.st_ino)
assert status == module.EXIT_RECOVERY_REQUIRED, status
assert crash_target.read_bytes() == b"SAFE=candidate\n"
assert crash_candidate.read_bytes() == b"SAFE=before\n"
assert module.journal_path(crash_target).is_file()
module.mark_committed = real_mark_committed
assert module.recover_existing(crash_target) == 0
assert crash_target.read_bytes() == b"SAFE=before\n"
assert not crash_expected.exists()
assert not crash_candidate.exists()
assert not module.journal_path(crash_target).exists()

tamper_target = root / "tamper-target.env"
tamper_expected = root / "tamper-target.env.source.fixture"
tamper_candidate = root / "tamper-target.env.tmp.fixture"
for path_value, body in ((tamper_target, b"SAFE=before\n"),
                         (tamper_expected, b"SAFE=before\n"),
                         (tamper_candidate, b"SAFE=candidate\n")):
    path_value.write_bytes(body)
    path_value.chmod(0o600)
identity = tamper_target.stat()
module.mark_committed = interrupted_commit
status = module.replace(tamper_target, tamper_expected, tamper_candidate,
                        identity.st_dev, identity.st_ino)
module.mark_committed = real_mark_committed
assert status == module.EXIT_RECOVERY_REQUIRED, status
assert tamper_target.read_bytes() == b"SAFE=candidate\n"
assert tamper_candidate.read_bytes() == b"SAFE=before\n"
third_party = root / "tamper-third-party.tmp"
third_party.write_bytes(b"SAFE=third-party\n")
third_party.chmod(0o600)
os.replace(third_party, tamper_candidate)
assert module.recover_existing(tamper_target) == module.EXIT_RECOVERY_REQUIRED
assert tamper_target.read_bytes() == b"SAFE=candidate\n"
assert tamper_candidate.read_bytes() == b"SAFE=third-party\n"
assert tamper_expected.read_bytes() == b"SAFE=before\n"
assert module.journal_path(tamper_target).is_file()

for path_value, body in ((crash_expected, b"SAFE=before\n"),
                         (crash_candidate, b"SAFE=candidate\n")):
    path_value.write_bytes(body)
    path_value.chmod(0o600)
identity = crash_target.stat()
real_clear_journal = module.clear_journal

def interrupted_clear(*_arguments):
    raise OSError("synthetic interruption after durable commit")

module.clear_journal = interrupted_clear
status = module.replace(crash_target, crash_expected, crash_candidate,
                        identity.st_dev, identity.st_ino)
assert status == module.EXIT_RECOVERY_REQUIRED, status
assert crash_target.read_bytes() == b"SAFE=candidate\n"
assert not crash_candidate.exists()
assert not crash_expected.exists()
assert module.journal_path(crash_target).is_file()
module.clear_journal = real_clear_journal
assert module.recover_existing(crash_target) == 0
assert crash_target.read_bytes() == b"SAFE=candidate\n"
assert not crash_expected.exists()
assert not crash_candidate.exists()
assert not module.journal_path(crash_target).exists()

create_tamper_target = root / "create-tamper.env"
create_tamper_expected = root / "create-tamper.env.source.fixture"
create_tamper_candidate = root / "create-tamper.env.tmp.fixture"
create_tamper_expected.write_bytes(b"")
create_tamper_candidate.write_bytes(b"SAFE=candidate\n")
create_tamper_expected.chmod(0o600)
create_tamper_candidate.chmod(0o600)
module.mark_committed = interrupted_commit
status = module.create(create_tamper_target, create_tamper_expected,
                       create_tamper_candidate)
module.mark_committed = real_mark_committed
assert status == module.EXIT_RECOVERY_REQUIRED, status
assert create_tamper_target.read_bytes() == b"SAFE=candidate\n"
assert not create_tamper_candidate.exists()
assert module.journal_path(create_tamper_target).is_file()
create_third_party = root / "create-third-party.tmp"
create_third_party.write_bytes(b"SAFE=third-party\n")
create_third_party.chmod(0o600)
os.replace(create_third_party, create_tamper_target)
assert module.recover_existing(create_tamper_target) == module.EXIT_RECOVERY_REQUIRED
assert create_tamper_target.read_bytes() == b"SAFE=third-party\n"
assert create_tamper_expected.read_bytes() == b""
assert not create_tamper_candidate.exists()
assert module.journal_path(create_tamper_target).is_file()

create_target = root / "create-crash.env"
create_expected = root / "create-crash.env.source.fixture"
create_candidate = root / "create-crash.env.tmp.fixture"
create_expected.write_bytes(b"")
create_candidate.write_bytes(b"SAFE=candidate\n")
create_expected.chmod(0o600)
create_candidate.chmod(0o600)
module.clear_journal = interrupted_clear
status = module.create(create_target, create_expected, create_candidate)
assert status == module.EXIT_RECOVERY_REQUIRED, status
assert create_target.read_bytes() == b"SAFE=candidate\n"
assert module.journal_path(create_target).is_file()
module.clear_journal = real_clear_journal
assert module.recover_existing(create_target) == 0
assert create_target.read_bytes() == b"SAFE=candidate\n"
assert not create_expected.exists()
assert not create_candidate.exists()
assert not module.journal_path(create_target).exists()

next_target = root / "next-crash.env"
next_expected = root / "next-crash.env.source.fixture"
next_candidate = root / "next-crash.env.tmp.fixture"
for path_value, body in ((next_target, b"SAFE=before\n"),
                         (next_expected, b"SAFE=before\n"),
                         (next_candidate, b"SAFE=candidate\n")):
    path_value.write_bytes(body)
    path_value.chmod(0o600)
next_record = module.prepared_record(
    "replace", next_target, next_expected, next_candidate,
    module.regular_snapshot(next_target),
)
module.write_exclusive(module.journal_next_path(next_target),
                       module.record_contents(next_record))
assert module.recover_existing(next_target) == 0
assert next_target.read_bytes() == b"SAFE=before\n"
assert not next_expected.exists()
assert not next_candidate.exists()
assert not module.journal_path(next_target).exists()
assert not module.journal_next_path(next_target).exists()
`, { mode: 0o600 });
const exchangeRace = spawnSync(realPython, [exchangeRaceFixture,
  path.join(project, 'scripts', 'atomic-config.py'), envGuardRoot], {
  cwd: project, encoding: 'utf8',
});
assert.equal(exchangeRace.status, 0, exchangeRace.stderr);
record('内核交换竞态、第三方换代、提交前回滚与提交后续做均由两阶段日志保留正确代次');
const validateConfiguration = (name, value, expected) => {
  const file = path.join(evidence, 'configuration-' + name + '-' + passed + '.json');
  fs.writeFileSync(file, JSON.stringify(value), { mode: 0o600 });
  const checked = spawnSync('bash', ['-c', 'source scripts/common.sh; source scripts/configuration.sh; configuration_validate "$1" "$2"',
    'guard', name, file], { cwd: project, encoding: 'utf8' });
  assert.equal(checked.status, expected, name + ': ' + checked.stderr);
};
const baseKeyword = JSON.parse(fs.readFileSync(path.join(project, 'config/keyword.yaml.example')));
for (const [label, mutate] of [
  ['空白固定回复', rule => { rule.action = 'reply'; rule.text = ' \t\n'; }],
  ['空白提示指令', rule => { rule.action = 'prompt'; rule.prompt = '\n  \t'; }],
  ['空白匹配词', rule => { rule.keywords = ['  \t']; }],
  ['空白菜单目标', rule => { rule.action = 'menu'; rule.target = '  \t'; }],
  ['空白确认按钮标题', rule => { rule.confirm_label = ' \t'; }],
  ['空白取消按钮标题', rule => { rule.cancel_label = '\n '; }],
  ['空白人工确认消息', rule => { rule.confirm_message = '  '; }],
]) {
  const value = structuredClone(baseKeyword); mutate(value.rules[0]);
  validateConfiguration('keyword', value, 1); record(label + '在Shell配置层被拒绝');
}
const invalidHandoff = JSON.parse(fs.readFileSync(path.join(project, 'config/handoff.yaml.example')));
invalidHandoff.handoff.message = ' \t\n';
validateConfiguration('handoff', invalidHandoff, 1); record('启用人工通知时空白确认正文在Shell配置层被拒绝');
for (const [label, field] of [['空白菜单固定回复', 'text'], ['空白菜单提示指令', 'prompt']]) {
  const value = JSON.parse(fs.readFileSync(path.join(project, 'config/menu.yaml.example')));
  value.menus.main.options['3'].action = { type: field === 'text' ? 'reply' : 'prompt', [field]: ' \t\n' };
  validateConfiguration('menu', value, 1); record(label + '在Shell配置层被拒绝');
}
const lockDirectory = path.join(evidence, 'lock-instance');
fs.mkdirSync(lockDirectory);
const nested = spawnSync('bash', ['-c', 'source scripts/common.sh; ( acquire_maintenance_lock "$1"; ( acquire_maintenance_lock "$1"; printf reentrant ); )', 'guard', lockDirectory], { cwd: project, encoding: 'utf8', timeout: 5000 });
assert.equal(nested.status, 0, nested.stderr);
assert.equal(nested.stdout, 'reentrant');
record('subshell 内取得的维护锁可被嵌套迁移备份安全继承');
const competing = spawnSync('bash', ['-c', 'source scripts/common.sh; acquire_maintenance_lock "$1"; ( unset CRISP_AI_MAINTENANCE_LOCK_HELD MAINTENANCE_LOCK_FD CRISP_AI_MAINTENANCE_LOCK_PATH; acquire_maintenance_lock "$1" )', 'guard', lockDirectory], { cwd: project, encoding: 'utf8', timeout: 5000 });
assert.equal(competing.status, 1);
assert.match(competing.stderr, /另一个/);
record('非继承的并发维护任务仍被互斥拒绝');
fs.writeFileSync(path.join(lockDirectory, '.env'), 'CRISP_WEBSITE_ID="11111111-1111-4111-8111-111111111111"\nCRISP_TOKEN_TIER="website"\nCRISP_AUTH_B64="c3ludGhldGljOnRlc3Q="\n', { mode: 0o600 });
const website = '11111111-1111-4111-8111-111111111111';
for (const [name, body, expected] of [
  ['valid', JSON.stringify({ error: false, data: { website_id: website } }), 0],
  ['soft-error', JSON.stringify({ error: true, data: { website_id: website } }), 1],
  ['other-website', JSON.stringify({ error: false, data: { website_id: 'another-website' } }), 1],
  ['missing-data', JSON.stringify({ error: false }), 1],
  ['not-json', '<html>not Crisp</html>', 1],
]) {
  const responseFile = path.join(evidence, 'crisp-' + name + '.json');
  fs.writeFileSync(responseFile, body, { mode: 0o600 });
  const script = 'source scripts/common.sh; fixture=$2; curl() { local output; while (($#)); do if [[ $1 == --output ]]; then output=$2; shift; fi; shift; done; cp -- "$fixture" "$output"; printf 200; }; crisp_api_check "$1"';
  const checked = spawnSync('bash', ['-c', script, 'guard', lockDirectory, responseFile], { cwd: project, encoding: 'utf8' });
  assert.equal(checked.status, expected, name + ': ' + checked.stderr);
  record('Crisp HTTP200 响应实际字段校验 ' + name);
}
process.stdout.write(JSON.stringify({ layer: 'UNIT/CONTRACT', passed, failed: 0, evidence: path.relative(project, evidence) }) + '\n');
