#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"

if ! command -v node >/dev/null 2>&1; then
  printf '跳过：未安装 Node.js，未执行工作流行为测试。\n' >&2
  exit 77
fi

PROJECT_ROOT="$PROJECT_ROOT" node <<'NODE'
'use strict';

const assert = require('assert');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const projectRoot = process.env.PROJECT_ROOT;
const workflow = JSON.parse(fs.readFileSync(path.join(projectRoot, 'n8n', 'workflow.json'), 'utf8'));
const codeFor = (name) => {
  const node = workflow.nodes.find((candidate) => candidate.name === name);
  assert(node && typeof node.parameters?.jsCode === 'string', `找不到 Code node：${name}`);
  return node.parameters.jsCode;
};

const eventLines = [];
const configOverrides = new Map();
let virtualInode = 100;
let virtualDescriptor = 10;
const virtualFiles = new Map();
const virtualDirectories = new Map([
  ['/opt/crisp-ai/data', { dev: 1, ino: virtualInode++, mtimeMs: Date.now() }],
  ['/opt/crisp-ai/data/analytics', { dev: 1, ino: virtualInode++, mtimeMs: Date.now() }],
  ['/opt/crisp-ai/data/runtime', { dev: 1, ino: virtualInode++, mtimeMs: Date.now() }],
]);
const openDescriptors = new Map();
const missing = (requestedPath, code = 'ENOENT') => {
  const error = new Error(`${code}: ${requestedPath}`);
  error.code = code;
  return error;
};
const statFor = (entry, kind) => ({
  dev: entry.dev,
  ino: entry.ino,
  mtimeMs: entry.mtimeMs,
  size: kind === 'file' ? Buffer.byteLength(entry.content) : 0,
  isFile: () => kind === 'file',
  isDirectory: () => kind === 'directory',
  isSymbolicLink: () => false,
});
const createFile = (requestedPath, content = '') => {
  const entry = { content: String(content), mode: 0o600, dev: 1, ino: virtualInode++, mtimeMs: Date.now() };
  virtualFiles.set(requestedPath, entry);
  return entry;
};
const configFs = {
  constants: fs.constants,
  readFileSync(requestedPath, encoding) {
    if (requestedPath.startsWith('/opt/crisp-ai/config/')) {
      const name = path.basename(requestedPath);
      if (configOverrides.has(name)) return configOverrides.get(name);
      let localPath = path.join(projectRoot, 'config', name);
      if (!fs.existsSync(localPath)) localPath += '.example';
      return fs.readFileSync(localPath, encoding);
    }
    const entry = virtualFiles.get(requestedPath);
    if (!entry) throw missing(requestedPath);
    return encoding ? entry.content : Buffer.from(entry.content);
  },
  lstatSync(requestedPath) {
    if (virtualFiles.has(requestedPath)) return statFor(virtualFiles.get(requestedPath), 'file');
    if (virtualDirectories.has(requestedPath)) return statFor(virtualDirectories.get(requestedPath), 'directory');
    throw missing(requestedPath);
  },
  statSync(requestedPath) {
    return this.lstatSync(requestedPath);
  },
  mkdirSync(requestedPath, options = {}) {
    if (virtualDirectories.has(requestedPath)) {
      if (options.recursive) return requestedPath;
      throw missing(requestedPath, 'EEXIST');
    }
    if (virtualFiles.has(requestedPath)) throw missing(requestedPath, 'EEXIST');
    virtualDirectories.set(requestedPath, { dev: 1, ino: virtualInode++, mtimeMs: Date.now() });
    return requestedPath;
  },
  rmdirSync(requestedPath) {
    if (!virtualDirectories.has(requestedPath)) throw missing(requestedPath);
    const prefix = `${requestedPath}/`;
    if ([...virtualDirectories.keys(), ...virtualFiles.keys()].some((candidate) => candidate.startsWith(prefix))) {
      throw missing(requestedPath, 'ENOTEMPTY');
    }
    virtualDirectories.delete(requestedPath);
  },
  writeFileSync(requestedPath, value, options = {}) {
    if (options.flag === 'wx' && virtualFiles.has(requestedPath)) throw missing(requestedPath, 'EEXIST');
    const entry = createFile(requestedPath, value);
    if (typeof options.mode === 'number') entry.mode = options.mode;
  },
  appendFileSync(requestedPath, value, options = {}) {
    const entry = virtualFiles.get(requestedPath) || createFile(requestedPath);
    entry.content += String(value);
    entry.mtimeMs = Date.now();
    if (typeof options.mode === 'number') entry.mode = options.mode;
    if (requestedPath.endsWith('/data/analytics/events.jsonl')) {
      eventLines.push(...String(value).trim().split('\n').filter(Boolean));
    }
  },
  renameSync(source, destination) {
    const entry = virtualFiles.get(source);
    if (!entry) throw missing(source);
    virtualFiles.delete(source);
    entry.mtimeMs = Date.now();
    virtualFiles.set(destination, entry);
  },
  unlinkSync(requestedPath) {
    if (!virtualFiles.delete(requestedPath)) throw missing(requestedPath);
  },
  chmodSync(requestedPath, mode) {
    const entry = virtualFiles.get(requestedPath);
    if (!entry) throw missing(requestedPath);
    entry.mode = mode;
  },
  readdirSync(requestedPath) {
    if (!virtualDirectories.has(requestedPath)) throw missing(requestedPath);
    const prefix = `${requestedPath}/`;
    return [...new Set([...virtualFiles.keys(), ...virtualDirectories.keys()]
      .filter((candidate) => candidate.startsWith(prefix))
      .map((candidate) => candidate.slice(prefix.length))
      .filter((candidate) => candidate && !candidate.includes('/')))];
  },
  openSync(requestedPath, flags, mode) {
    const exclusive = Boolean(flags & fs.constants.O_EXCL);
    const create = Boolean(flags & fs.constants.O_CREAT);
    if (exclusive && virtualFiles.has(requestedPath)) throw missing(requestedPath, 'EEXIST');
    if (!virtualFiles.has(requestedPath)) {
      if (!create) throw missing(requestedPath);
      const entry = createFile(requestedPath);
      entry.mode = mode;
    }
    const descriptor = virtualDescriptor++;
    openDescriptors.set(descriptor, requestedPath);
    return descriptor;
  },
  fstatSync(descriptor) {
    const requestedPath = openDescriptors.get(descriptor);
    if (!requestedPath || !virtualFiles.has(requestedPath)) throw missing(String(descriptor), 'EBADF');
    return statFor(virtualFiles.get(requestedPath), 'file');
  },
  fchmodSync(descriptor, mode) {
    const requestedPath = openDescriptors.get(descriptor);
    if (!requestedPath || !virtualFiles.has(requestedPath)) throw missing(String(descriptor), 'EBADF');
    virtualFiles.get(requestedPath).mode = mode;
  },
  futimesSync(descriptor, _accessedAt, modifiedAt) {
    const requestedPath = openDescriptors.get(descriptor);
    if (!requestedPath || !virtualFiles.has(requestedPath)) throw missing(String(descriptor), 'EBADF');
    virtualFiles.get(requestedPath).mtimeMs = Number(modifiedAt);
  },
  closeSync(descriptor) {
    if (!openDescriptors.delete(descriptor)) throw missing(String(descriptor), 'EBADF');
  },
};
const controlledRequire = (name) => {
  if (name === 'crypto') return crypto;
  if (name === 'fs') return configFs;
  throw new Error(`测试不允许加载模块：${name}`);
};

const router = new Function('$input', '$env', '$getWorkflowStaticData', 'require', codeFor('校验并分类事件'));
const knowledgeFormatter = new Function('$input', '$', '$getWorkflowStaticData', codeFor('整理知识库回复'));
const visionFormatter = new Function('$input', '$', '$getWorkflowStaticData', codeFor('整理视觉回复'));
const prepareReply = new Function('$input', '$getWorkflowStaticData', 'require', codeFor('准备回复与统计'));
const mergeTags = new Function('$input', '$', codeFor('合并 Crisp 标签'));
const confirmDelivery = new Function('$input', '$', '$getWorkflowStaticData', 'require', codeFor('确认发送并提交统计'));
const handoffGate = new Function('$input', '$', '$getWorkflowStaticData', 'require', codeFor('发送前人工接管复核'));
const injectCrispContext = new Function('$input', '$', codeFor('注入 Crisp 会话上下文'));

const websiteId = '11111111-1111-1111-1111-111111111111';
const websiteSecret = 'test-only-website-hook-secret';
const pluginSecret = 'test-only-plugin-signing-secret';
const baseEnv = {
  CRISP_HOOK_MODE: 'website',
  CRISP_WEBSITE_HOOK_SECRET: websiteSecret,
  CRISP_PLUGIN_SIGNING_SECRET: pluginSecret,
  CRISP_WEBSITE_ID: websiteId,
  CRISP_IMAGE_HOSTS: '',
  AI_SUPPORTS_VISION: 'true',
  AI_MODEL: 'gpt-vision-test',
  AI_API_BASE_URL: 'https://provider.invalid/v1',
  AI_API_MODE: 'responses',
  AI_MAX_OUTPUT_TOKENS: '1200',
  ANYTHINGLLM_CHAT_MODE: 'chat',
};

let sequence = 0;
const makeMessage = (content, overrides = {}) => {
  sequence += 1;
  return {
    event: 'message:send',
    website_id: websiteId,
    data: {
      session_id: overrides.session_id || `session_test${String(sequence).padStart(8, '0')}`,
      fingerprint: overrides.fingerprint || `fingerprint_${sequence}`,
      from: overrides.from || 'user',
      type: overrides.type || 'text',
      content,
      ...(overrides.data || {}),
    },
  };
};

const runRouter = (body, options = {}) => {
  const state = options.state || {};
  const request = {
    body,
    headers: options.headers || {},
    query: options.query === undefined ? { key: websiteSecret } : options.query,
  };
  const input = { json: request };
  if (options.rawBody !== undefined) {
    input.binary = { data: { data: Buffer.from(options.rawBody, 'utf8').toString('base64') } };
  }
  const result = router(
    { first: () => input },
    { ...baseEnv, ...(options.env || {}) },
    () => state,
    controlledRequire,
  );
  assert(Array.isArray(result) && result[0]?.json, '路由节点未返回 n8n item');
  return { json: result[0].json, state };
};

let result = runRouter(makeMessage('测试'), { query: { key: 'wrong-secret' } }).json;
assert.strictEqual(result.accepted, false);
assert.strictEqual(result.statusCode, 401);

result = runRouter({ ...makeMessage('测试'), website_id: 'wrong-website' }).json;
assert.strictEqual(result.statusCode, 403);

const invalidSession = makeMessage('测试');
invalidSession.data.session_id = '../invalid';
result = runRouter(invalidSession).json;
assert.strictEqual(result.statusCode, 400);

const signatureBody = makeMessage('签名测试');
const rawBody = JSON.stringify(signatureBody);
const timestamp = String(Date.now());
const signature = crypto.createHmac('sha256', pluginSecret).update(`[${timestamp};${rawBody}]`).digest('hex');
result = runRouter(signatureBody, {
  query: {},
  rawBody,
  env: { CRISP_HOOK_MODE: 'plugin' },
  headers: {
    'X-Crisp-Signature': signature,
    'X-Crisp-Request-Timestamp': timestamp,
  },
}).json;
assert.strictEqual(result.accepted, true);
assert.strictEqual(result.verification, 'plugin-signature');

result = runRouter(signatureBody, {
  query: { key: websiteSecret },
  rawBody,
  env: { CRISP_HOOK_MODE: 'plugin' },
}).json;
assert.strictEqual(result.statusCode, 401, 'Plugin 模式不得回退到 URL Secret');

result = runRouter(signatureBody, {
  query: {},
  rawBody,
  headers: {
    'X-Crisp-Signature': signature,
    'X-Crisp-Request-Timestamp': timestamp,
  },
}).json;
assert.strictEqual(result.statusCode, 401, 'Website 模式不得接受 Plugin 签名');

const staleTimestamp = String(Date.now() - 400000);
const staleSignature = crypto.createHmac('sha256', pluginSecret).update(`[${staleTimestamp};${rawBody}]`).digest('hex');
result = runRouter(signatureBody, {
  query: {},
  rawBody,
  env: { CRISP_HOOK_MODE: 'plugin' },
  headers: {
    'X-Crisp-Signature': staleSignature,
    'X-Crisp-Request-Timestamp': staleTimestamp,
  },
}).json;
assert.strictEqual(result.statusCode, 401);

const automated = makeMessage('机器人消息', { data: { automated: true } });
result = runRouter(automated).json;
assert.strictEqual(result.route, 'ignore');

const duplicateState = {};
const duplicateMessage = makeMessage('重复消息');
runRouter(duplicateMessage, { state: duplicateState });
result = runRouter(duplicateMessage, { state: {} }).json;
assert.strictEqual(result.reason, '重复事件已忽略');
const durableStateFiles = [...virtualFiles.entries()]
  .filter(([requestedPath]) => /\/data\/runtime\/session-[a-f0-9]{64}\.json$/.test(requestedPath));
assert(durableStateFiles.length > 0, '未写入持久会话控制状态');
for (const [, entry] of durableStateFiles) {
  assert.strictEqual(entry.mode, 0o600);
  assert(!entry.content.includes(duplicateMessage.data.session_id));
  assert(!entry.content.includes(duplicateMessage.data.fingerprint));
}
const runtimeDirectory = '/opt/crisp-ai/data/runtime';
const gcMarker = virtualFiles.get(`${runtimeDirectory}/.gc.marker`);
assert(gcMarker, '未创建持久状态 GC marker');
gcMarker.mtimeMs = 0;
const staleGcName = `session-${crypto.createHash('sha256').update('stale-gc-state').digest('hex')}.json`;
const staleGcPath = `${runtimeDirectory}/${staleGcName}`;
const staleGcEntry = createFile(staleGcPath, '{}');
staleGcEntry.mtimeMs = Date.now() - 8 * 24 * 60 * 60 * 1000;
for (let index = 0; index < 2001; index += 1) {
  const name = crypto.createHash('sha256').update(`capacity-gc-${index}`).digest('hex');
  const entry = createFile(`${runtimeDirectory}/session-${name}.json`, '{}');
  entry.mtimeMs = Date.now() - index;
}
const gcMessage = makeMessage('触发持久状态回收', { session_id: 'session_gccurrent1234' });
runRouter(gcMessage);
const retainedRuntimeStates = [...virtualFiles.keys()]
  .filter((requestedPath) => /\/data\/runtime\/session-[a-f0-9]{64}\.json$/.test(requestedPath));
assert.strictEqual(retainedRuntimeStates.length, 1500);
assert(!virtualFiles.has(staleGcPath), '七天前的持久状态未被回收');
const currentGcPath = `${runtimeDirectory}/session-${crypto.createHash('sha256').update(gcMessage.data.session_id).digest('hex')}.json`;
assert(virtualFiles.has(currentGcPath), 'GC 错误删除当前会话状态');
assert(!virtualDirectories.has(`${runtimeDirectory}/.gc.lock`), 'GC 全局锁未释放');

result = runRouter(makeMessage('请问服务时间')).json;
assert.strictEqual(result.route, 'reply');
assert(result.reply.includes('人工客服服务时间'));

result = runRouter(makeMessage('我要退款')).json;
assert.strictEqual(result.route, 'ai_text');
assert(result.anythingBody.message.includes('退款规则'));
assert.strictEqual(result.anythingBody.mode, 'chat');

result = runRouter(makeMessage('错误 AnythingLLM 模式'), {
  env: { ANYTHINGLLM_CHAT_MODE: 'query' },
}).json;
assert.strictEqual(result.route, 'reply');
assert(result.reply.includes('自动客服暂时不可用'));
assert(result.tagsToApply.includes('low_confidence'));
assert(eventLines.map((line) => JSON.parse(line)).some(
  (entry) => entry.type === 'provider_failed' && entry.reason === 'anythingllm_chat_mode_invalid',
));

const explicitHandoffState = {};
for (const nonExactText of ['请转人工客服', '人工智能', '不需要人工']) {
  const nonExact = makeMessage(nonExactText);
  result = runRouter(nonExact).json;
  assert.notStrictEqual(result.handoffReason, '用户关键词请求');
  assert(!result.tagsToApply.includes('human_required'));
}
const explicitHandoff = makeMessage('转人工', { session_id: 'session_handoff1234' });
result = runRouter(explicitHandoff, { state: explicitHandoffState }).json;
const explicitHandoffResult = result;
assert.strictEqual(result.route, 'reply');
assert(result.reply.includes('正在为您转接'));
assert.strictEqual(explicitHandoffState.sessions[explicitHandoff.data.session_id].aiEnabled, false);
assert.strictEqual(result.reply, '正在为您转接人工客服，请稍候。');
assert(result.tagsToApply.includes('human_required'));

const handoffConfigPath = path.join(projectRoot, 'config', 'handoff.yaml.example');
const handoffWithDisableFalse = JSON.parse(fs.readFileSync(handoffConfigPath, 'utf8'));
handoffWithDisableFalse.handoff.disable_ai = false;
configOverrides.set('handoff.yaml', JSON.stringify(handoffWithDisableFalse));
const disableFalseState = {};
const disableFalseHandoff = makeMessage('转人工', { session_id: 'session_disablefalse1234' });
result = runRouter(disableFalseHandoff, { state: disableFalseState }).json;
configOverrides.delete('handoff.yaml');
assert.strictEqual(result.route, 'reply');
assert.strictEqual(disableFalseState.sessions[disableFalseHandoff.data.session_id].aiEnabled, false);

result = runRouter(makeMessage('菜单')).json;
assert.strictEqual(result.route, 'reply');
assert(result.reply.includes('电脑排障流程'));

const contextMessage = makeMessage('普通问题');
result = runRouter(contextMessage).json;
assert.strictEqual(result.route, 'ai_text');
assert.strictEqual(result.anythingBody.sessionId, contextMessage.data.session_id);

const recoveredContext = injectCrispContext(
  { first: () => ({ json: { data: [
    { from: 'user', type: 'text', content: '更早的公开问题', timestamp: 1000, fingerprint: 'history-user' },
    { from: 'operator', type: 'text', content: '人工公开回复', timestamp: 2000, fingerprint: 'history-operator' },
    { from: 'operator', type: 'text', content: 'AI 公开回复', timestamp: 3000, automated: true, fingerprint: 'history-ai' },
    { from: 'operator', type: 'text', content: '不应恢复的私密消息', timestamp: 4000, stealth: true, fingerprint: 'history-stealth' },
    { from: 'user', type: 'text', content: '不应重复的当前消息', timestamp: 5000, fingerprint: contextMessage.data.fingerprint },
  ] } }) },
  (name) => {
    assert.strictEqual(name, '校验并分类事件');
    return { first: () => ({ json: result }) };
  },
)[0].json;
assert.strictEqual(recoveredContext.recoveredCrispHistory, true);
assert(recoveredContext.anythingBody.message.includes('访客：更早的公开问题'));
assert(recoveredContext.anythingBody.message.includes('人工客服：人工公开回复'));
assert(recoveredContext.anythingBody.message.includes('AI客服：AI 公开回复'));
assert(!recoveredContext.anythingBody.message.includes('不应恢复的私密消息'));
assert(!recoveredContext.anythingBody.message.includes('不应重复的当前消息'));
assert(recoveredContext.anythingBody.message.includes('访客当前消息：普通问题'));

const handoffState = {};
const sharedSession = 'session_operator1234';
const operatorMessage = makeMessage('人工处理意见', { session_id: sharedSession, from: 'operator' });
operatorMessage.event = 'message:received';
result = runRouter(operatorMessage, { state: handoffState }).json;
assert.strictEqual(result.route, 'tag_only');
assert.strictEqual(handoffState.sessions[sharedSession].aiEnabled, false);
assert(handoffState.sessions[sharedSession].aiResumeAt > Date.now());
assert(result.tagsToApply.includes('human_required'));
result = runRouter(makeMessage('还有问题', { session_id: sharedSession }), { state: {} }).json;
assert.strictEqual(result.route, 'ignore');
const resumeMessage = makeMessage('恢复AI', { session_id: sharedSession, from: 'operator' });
resumeMessage.event = 'message:received';
result = runRouter(resumeMessage, { state: handoffState }).json;
assert.strictEqual(result.route, 'tag_only');
assert.strictEqual(handoffState.sessions[sharedSession].aiEnabled, false);
result = runRouter(makeMessage('继续处理', { session_id: sharedSession }), { state: handoffState }).json;
assert.strictEqual(result.route, 'ignore');

const gateState = {};
const gateSession = 'session_gatehandoff1234';
const gateInbound = makeMessage('发送前并发复核', { session_id: gateSession });
const gateRouted = runRouter(gateInbound, { state: gateState }).json;
const gateContext = {
  ...gateRouted,
  reply: '此回复必须被并发人工接管阻止',
  baseReply: '此回复必须被并发人工接管阻止',
  analyticsAiReply: true,
  feedbackPlan: { question: '问题', answer: '回答', expiresAfterSeconds: 60 },
};
const concurrentOperator = makeMessage('并发人工回复', { session_id: gateSession, from: 'operator' });
concurrentOperator.event = 'message:received';
runRouter(concurrentOperator, { state: {} });
const gated = handoffGate(
  { first: () => ({ json: { error: false, data: [] } }) },
  (name) => {
    assert.strictEqual(name, '准备回复与统计');
    return { first: () => ({ json: gateContext }) };
  },
  () => gateState,
  controlledRequire,
)[0].json;
assert.strictEqual(gated.handoffBlocked, true);
assert.strictEqual(gated.reply, '');
assert.strictEqual(gated.feedbackPlan, null);
assert(gated.tagsToApply.includes('human_required'));

const failedGateState = {};
const failedGateInbound = makeMessage('Crisp 列表失败必须停止发送', { session_id: 'session_gatefailure1234' });
const failedGateRouted = runRouter(failedGateInbound, { state: failedGateState }).json;
const failedGateContext = {
  ...failedGateRouted,
  reply: '此回复不得发送',
  baseReply: '此回复不得发送',
  analyticsAiReply: true,
  analyticsOutcome: 'knowledge_hit',
  feedbackPlan: { question: '问题', answer: '回答', expiresAfterSeconds: 60 },
  tagsToApply: ['ai_resolved'],
};
const preSendFailed = handoffGate(
  { first: () => ({ json: { error: true, message: 'forbidden' } }) },
  (name) => {
    assert.strictEqual(name, '准备回复与统计');
    return { first: () => ({ json: failedGateContext }) };
  },
  () => failedGateState,
  controlledRequire,
)[0].json;
assert.strictEqual(preSendFailed.preSendCheckFailed, true);
assert.strictEqual(preSendFailed.handoffBlocked, false);
assert.strictEqual(preSendFailed.reply, '');
assert.strictEqual(preSendFailed.feedbackPlan, null);
assert.strictEqual(preSendFailed.analyticsAiReply, false);
assert.strictEqual(preSendFailed.analyticsOutcome, '');
assert.deepStrictEqual(preSendFailed.tagsToApply, []);
assert.strictEqual(failedGateState.sessions[failedGateInbound.data.session_id].aiEnabled, true);
assert(eventLines.map((line) => JSON.parse(line)).some(
  (entry) => entry.type === 'delivery_failed' && entry.reason === 'pre_send_check_failed',
));

const explicitHandoffPrepared = {
  ...explicitHandoffResult,
  baseReply: explicitHandoffResult.reply,
  feedbackPlan: null,
};
const allowedHandoffAck = handoffGate(
  { first: () => ({ json: { error: true, message: 'forbidden' } }) },
  (name) => {
    assert.strictEqual(name, '准备回复与统计');
    return { first: () => ({ json: explicitHandoffPrepared }) };
  },
  () => explicitHandoffState,
  controlledRequire,
)[0].json;
assert.strictEqual(allowedHandoffAck.preSendCheckFailed, false);
assert.strictEqual(allowedHandoffAck.reply, '正在为您转接人工客服，请稍候。');

const welcomeState = {};
const welcomeBody = {
  event: 'session:request:initiated',
  website_id: websiteId,
  data: { session_id: 'session_welcome1234' },
};
result = runRouter(welcomeBody, { state: welcomeState }).json;
assert.strictEqual(result.route, 'reply');
assert(result.reply.includes('您好，欢迎联系客服'));
result = runRouter(welcomeBody, { state: {} }).json;
assert.strictEqual(result.route, 'ignore');

const unsupportedWelcome = {
  event: 'session:set_opened',
  website_id: websiteId,
  data: { session_id: 'session_unsupportedwelcome1234' },
};
result = runRouter(unsupportedWelcome).json;
assert.strictEqual(result.route, 'ignore');

const unsafeImage = makeMessage({ type: 'image/png', name: 'bad.png', url: 'https://evil.invalid/bad.png' }, { type: 'file' });
result = runRouter(unsafeImage).json;
assert.strictEqual(result.route, 'reply');
assert(result.reply.includes('图片地址未通过安全校验'));

const noVisionImage = makeMessage({ type: 'image/png', name: 'image.png', url: 'https://storage.crisp.chat/image.png' }, { type: 'file' });
result = runRouter(noVisionImage, { env: { AI_SUPPORTS_VISION: 'false' } }).json;
assert.strictEqual(result.route, 'reply');
assert(result.reply.includes('切换为支持视觉的模型'));

const responsesImage = makeMessage({ type: 'image/png', name: 'image.png', url: 'https://storage.crisp.chat/image.png' }, { type: 'file' });
result = runRouter(responsesImage).json;
assert.strictEqual(result.route, 'vision_responses');
assert.strictEqual(result.aiBody.input[1].content[1].type, 'input_image');

const chatImage = makeMessage({ type: 'image/jpeg', name: 'image.jpg', url: 'https://storage.crisp.chat/image.jpg' }, { type: 'file' });
result = runRouter(chatImage, { env: { AI_API_MODE: 'chat_completions' } }).json;
assert.strictEqual(result.route, 'vision_chat');
assert(result.aiUrl.endsWith('/chat/completions'));

const formatKnowledge = (context, payload, state) => knowledgeFormatter(
  { first: () => ({ json: payload }) },
  (name) => {
    assert.strictEqual(name, '校验并分类事件');
    return { first: () => ({ json: context }) };
  },
  () => state,
)[0].json;

const commitDelivery = (context, payload, state) => confirmDelivery(
  { first: () => ({ json: payload }) },
  (name) => {
    assert.strictEqual(name, '发送前人工接管复核');
    return { first: () => ({ json: context }) };
  },
  () => state,
  controlledRequire,
)[0].json;

const deliveredPayload = (context) => ({
  error: false,
  reason: 'dispatched',
  data: { fingerprint: context.outboundFingerprint },
});

let formatterState = {};
let routed = runRouter(makeMessage('需要知识库回答'), { state: formatterState }).json;
result = formatKnowledge(routed, { data: { textResponse: '无来源回答', sources: [] } }, formatterState);
assert(result.reply.includes('知识库暂时没有足够信息'));
assert.strictEqual(result.analyticsOutcome, 'knowledge_miss');
assert(result.tagsToApply.includes('knowledge_miss'));
assert.strictEqual(formatterState.sessions[routed.sessionId].aiEnabled, true);
let prepared = prepareReply(
  { first: () => ({ json: result }) },
  () => formatterState,
  controlledRequire,
)[0].json;
result = commitDelivery(prepared, deliveredPayload(prepared), formatterState);
assert.strictEqual(result.deliverySucceeded, true);

formatterState = {};
routed = runRouter(makeMessage('低分依据的问题'), { state: formatterState }).json;
result = formatKnowledge(routed, { data: { textResponse: '低分回答', sources: [{ score: 0.1 }] } }, formatterState);
assert(result.reply.includes('可信度不足'));
assert(result.tagsToApply.includes('low_confidence'));
assert.strictEqual(formatterState.sessions[routed.sessionId].aiEnabled, true);

formatterState = {};
routed = runRouter(makeMessage('已有依据的问题'), { state: formatterState }).json;
result = formatKnowledge(routed, { data: { textResponse: '有依据的回答', sources: [{ score: 0.9 }] } }, formatterState);
assert(result.reply.includes('有依据的回答'));
assert.strictEqual(result.analyticsOutcome, 'knowledge_hit');
assert(result.tagsToApply.includes('ai_resolved'));
prepared = prepareReply(
  { first: () => ({ json: result }) },
  () => formatterState,
  controlledRequire,
)[0].json;
result = commitDelivery(prepared, deliveredPayload(prepared), formatterState);
assert.strictEqual(result.deliverySucceeded, true);

formatterState = {};
routed = runRouter(makeMessage('触发 API 失败'), { state: formatterState }).json;
result = formatKnowledge(routed, { error: { message: 'test failure' } }, formatterState);
assert(result.reply.includes('自动客服暂时不可用'));
assert.strictEqual(formatterState.sessions[routed.sessionId].aiEnabled, true);

const formatVision = (context, payload, state) => visionFormatter(
  { first: () => ({ json: payload }) },
  (name) => {
    assert.strictEqual(name, '校验并分类事件');
    return { first: () => ({ json: context }) };
  },
  () => state,
)[0].json;

formatterState = {};
routed = runRouter(makeMessage('图片后续问题'), { state: formatterState }).json;
result = formatVision(routed, {}, formatterState);
assert(result.reply.includes('自动客服暂时不可用'));
assert.strictEqual(formatterState.sessions[routed.sessionId].aiEnabled, true);
assert(result.tagsToApply.includes('low_confidence'));

const feedbackState = {};
const feedbackQuestion = makeMessage('接口 token=should-not-leak 为什么失败', { session_id: 'session_feedback1234' });
routed = runRouter(feedbackQuestion, { state: feedbackState }).json;
let answered = formatKnowledge(routed, { data: { textResponse: '请按文档步骤操作', sources: [{ score: 0.95 }] } }, feedbackState);
answered = prepareReply(
  { first: () => ({ json: answered }) },
  () => feedbackState,
  controlledRequire,
)[0].json;
assert(answered.reply.includes('是否解决问题？'));
assert(!feedbackState.sessions[feedbackQuestion.data.session_id].pendingFeedback);
answered = commitDelivery(answered, deliveredPayload(answered), feedbackState);
assert.strictEqual(answered.deliverySucceeded, true);
assert(feedbackState.sessions[feedbackQuestion.data.session_id].pendingFeedback);
result = runRouter(makeMessage('👎', { session_id: feedbackQuestion.data.session_id }), { state: feedbackState }).json;
assert.strictEqual(result.feedbackRecorded, true);
const events = eventLines.map((line) => JSON.parse(line));
const negative = events.find((entry) => entry.type === 'feedback' && entry.feedback === 'negative');
assert(negative);
assert.notStrictEqual(negative.session, feedbackQuestion.data.session_id);
assert(!JSON.stringify(negative).includes('should-not-leak'));
assert(events.some((entry) => entry.type === 'knowledge_hit'));
assert(events.some((entry) => entry.type === 'knowledge_miss'));
assert(events.some((entry) => entry.type === 'ai_reply'));
const analyticsEntry = virtualFiles.get('/opt/crisp-ai/data/analytics/events.jsonl');
assert(analyticsEntry, '匿名统计文件未写入');
assert.strictEqual(analyticsEntry.mode, 0o660);
assert(!virtualDirectories.has('/opt/crisp-ai/data/analytics/.events.lock'), '匿名统计锁未释放');

const failedDeliveryState = {};
const failedQuestion = makeMessage('发送失败不得开放反馈', { session_id: 'session_deliveryfail1234' });
const failedRouted = runRouter(failedQuestion, { state: failedDeliveryState }).json;
let failedAnswer = formatKnowledge(
  failedRouted,
  { data: { textResponse: '此回答发送失败', sources: [{ score: 0.95 }] } },
  failedDeliveryState,
);
failedAnswer = prepareReply(
  { first: () => ({ json: failedAnswer }) },
  () => failedDeliveryState,
  controlledRequire,
)[0].json;
failedAnswer = commitDelivery(
  failedAnswer,
  { error: true, reason: 'failed', data: {} },
  failedDeliveryState,
);
assert.strictEqual(failedAnswer.deliverySucceeded, false);
assert(!failedDeliveryState.sessions[failedQuestion.data.session_id].pendingFeedback);
assert(eventLines.map((line) => JSON.parse(line)).some((entry) => entry.type === 'delivery_failed'));

const merged = mergeTags(
  { first: () => ({ json: { data: { segments: ['customer-vip', 'knowledge_miss'] } } }) },
  (name) => {
    assert.strictEqual(name, '准备回复与统计');
    return { first: () => ({ json: answered }) };
  },
)[0].json;
assert(merged.mergedSegments.includes('customer-vip'));
assert(merged.mergedSegments.includes('ai_resolved'));
assert(merged.mergedSegments.includes('knowledge_miss'));

const skippedTagUpdate = mergeTags(
  { first: () => ({ json: { error: { message: 'forbidden' } } }) },
  (name) => {
    assert.strictEqual(name, '准备回复与统计');
    return { first: () => ({ json: answered }) };
  },
)[0].json;
assert.strictEqual(skippedTagUpdate.tagReadOk, false);
assert.deepStrictEqual(skippedTagUpdate.mergedSegments, []);
assert(skippedTagUpdate.reply.includes('是否解决问题'));

process.stdout.write('工作流行为测试：通过\n');
NODE
