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
