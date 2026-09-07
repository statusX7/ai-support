'use strict';

const assert = require('assert/strict');
const fs = require('fs');
const path = require('path');
const http = require('http');
const { spawn } = require('child_process');
const project = path.resolve(__dirname, '..');
fs.mkdirSync(path.join(project, '.work', 'v1.2.0'), { recursive: true });
const root = fs.mkdtempSync(path.join(project, '.work', 'v1.2.0', 'crisp-auth-'));
fs.mkdirSync(path.join(root, 'tmp'));
const identifier = 'synthetic-标识-😀-"-$&#=\\';
const token = 'synthetic-only:密钥 & $ # = " \' \\ 😀';
const auth = Buffer.from(identifier + ':' + token, 'utf8').toString('base64');
const website = '11111111-1111-4111-8111-111111111111';
let protocolBase = '';
const run = (script, args = [], input = '') => new Promise((resolve, reject) => {
  // 仅将生产固定 Crisp 地址路由至受控 HTTP 服务，不使用真实网络或账户。
  const transport = 'curl() { local arg; local -a routed=(); for arg in "$@"; do if [[ $arg == https://api.crisp.chat/v1/* ]]; then arg="$CRISPAI_AUTH_TEST_BASE/${arg#https://api.crisp.chat/v1/}"; fi; routed+=("$arg"); done; command curl "${routed[@]}"; };\n';
  const child = spawn('bash', ['-c', 'source scripts/common.sh\n' + transport + script, 'auth-test', ...args], {
    cwd: project, env: { ...process.env, CURL_HOME: root, CRISPAI_AUTH_TEST_BASE: protocolBase }, stdio: ['pipe', 'pipe', 'pipe'],
  });
  let stdout = ''; let stderr = '';
  const timer = setTimeout(() => child.kill('SIGKILL'), 15000);
  child.stdout.on('data', (data) => { stdout += data; });
  child.stderr.on('data', (data) => { stderr += data; });
  child.on('error', reject);
  child.on('close', (status) => { clearTimeout(timer); resolve({ status, stdout, stderr }); });
  child.stdin.end(input);
});
let passed = 0;
const check = (name) => { passed += 1; process.stdout.write('通过 UNIT/CONTRACT ' + name + '\n'); };
let response = { code: 200, body: { error: false, data: { website_id: website } } };
let seen = [];
const server = http.createServer((request, result) => {
  seen.push({ path: request.url, headers: request.headers });
  result.writeHead(response.code, { 'Content-Type': 'application/json', ...(response.headers || {}) });
  result.end(typeof response.body === 'string' ? response.body : JSON.stringify(response.body));
});
(async () => {
  const encoded = await run('IFS= read -r identifier; IFS= read -r token; crisp_auth_b64 "$identifier" "$token"', [], identifier + '\n' + token + '\n');
  assert.equal(encoded.status, 0); assert.equal(encoded.stdout, auth); assert.equal(encoded.stderr, '');
  check('C01 UTF-8/特殊字符 Token 配对只编码一次且没有 Base64 换行');
  const invalid = await run('crisp_auth_b64 "invalid:identifier" "synthetic"');
  assert.equal(invalid.status, 1); assert.equal(invalid.stdout, '');
  check('C02 含冒号 Identifier 被拒绝，不生成歧义认证');
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const base = 'http://127.0.0.1:' + server.address().port + '/v1';
  protocolBase = base;
  const candidate = path.join(root, 'candidate.json');
  const values = { CRISP_WEBSITE_ID: website, CRISP_TOKEN_IDENTIFIER: identifier, CRISP_TOKEN_KEY: token,
    CRISP_AUTH_B64: auth, CRISP_TOKEN_TIER: 'website', CRISP_API_BASE_URL: base };
  const save = async () => {
    fs.writeFileSync(candidate, JSON.stringify(values), { mode: 0o600 });
    const result = await run('while IFS= read -r key; do value=$(jq -r --arg key "$key" \'.[$key]\' "$2"); env_set "$1/.env" "$key" "$value"; done < <(jq -r \'keys[]\' "$2")', [root, candidate]);
    assert.equal(result.status, 0);
  };
  // 自定义 curl 配置不得进入项目认证请求；以下均是虚构值。
  fs.writeFileSync(path.join(root, '.curlrc'), 'header = "X-Unexpected-Authentication: synthetic-only"\n', { mode: 0o600 });
  for (const tier of ['website', 'plugin']) {
    values.CRISP_TOKEN_TIER = tier; await save(); seen = [];
    const result = await run('crisp_api_check "$1"', [root]);
    assert.equal(result.status, 0); assert.equal(result.stdout, ''); assert.equal(result.stderr, '');
    assert.equal(seen.length, 1); assert.equal(seen[0].path, '/v1/website/' + website);
    assert.equal(seen[0].headers.authorization, 'Basic ' + auth);
    assert.equal(seen[0].headers['x-crisp-tier'], tier);
    assert.equal(seen[0].headers['x-unexpected-authentication'], undefined);
    check('C01/C02 生产 HTTP 请求 ' + tier + ' tier、真实 Header 配对及 curl 配置隔离');
  }
  for (const [name, code, body] of [
    ['401', 401, { error: true }], ['403', 403, { error: true }], ['404', 404, { error: true }], ['429', 429, { error: true }],
    ['HTTP200 错误对象', 200, { error: true, data: { website_id: website } }],
    ['HTTP200 缺少成功字段', 200, { data: { website_id: website } }],
    ['HTTP200 挑战 HTML', 200, '<html>synthetic challenge</html>'],
    ['其他 workspace', 200, { error: false, data: { website_id: 'another-workspace' } }],
    ['重定向', 302, { error: false, data: { website_id: website } }],
  ]) {
    response = { code, body, headers: { Location: base + '/redirect-target' } }; seen = [];
    const result = await run('crisp_api_check "$1"', [root]);
    assert.equal(result.status, 1, name); assert.equal(seen.length, code === 429 ? 3 : 1, '重试有界，不能重定向转发认证');
    assert(!result.stdout.includes(token) && !result.stderr.includes(auth));
    check('C03 ' + name + ' 不假绿、不泄露认证、不跨主机重定向');
  }
  values.CRISP_TOKEN_IDENTIFIER = 'synthetic-rotated-id'; await save(); seen = [];
  const stale = await run('crisp_api_check "$1"', [root]);
  assert.equal(stale.status, 1); assert.equal(seen.length, 0);
  check('C02 凭据配对与派生认证不一致时禁止请求，不沿用旧 Basic');
  assert.equal(fs.statSync(path.join(root, '.env')).mode & 0o777, 0o600);
  process.stdout.write(JSON.stringify({ layer: 'UNIT/CONTRACT', passed, failed: 0 }) + '\n');
})().catch((error) => { process.stderr.write(error.stack + '\n'); process.exitCode = 1; }).finally(() => server.close());
