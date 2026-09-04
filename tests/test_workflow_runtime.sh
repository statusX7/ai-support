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

const configFs = {
  readFileSync(requestedPath, encoding) {
    const name = path.basename(requestedPath);
    let localPath = path.join(projectRoot, 'config', name);
    if (!fs.existsSync(localPath)) localPath += '.example';
    return fs.readFileSync(localPath, encoding);
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

const websiteId = '11111111-1111-1111-1111-111111111111';
const secret = 'test-only-webhook-secret';
const baseEnv = {
  CRISP_WEBHOOK_SECRET: secret,
  CRISP_WEBSITE_ID: websiteId,
  CRISP_IMAGE_HOSTS: '',
  AI_SUPPORTS_VISION: 'true',
  AI_MODEL: 'gpt-vision-test',
  AI_API_BASE_URL: 'https://provider.invalid/v1',
  AI_API_MODE: 'responses',
  AI_MAX_OUTPUT_TOKENS: '1200',
  ANYTHINGLLM_CHAT_MODE: 'query',
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
    query: options.query === undefined ? { key: secret } : options.query,
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
const signature = crypto.createHmac('sha256', secret).update(`[${timestamp};${rawBody}]`).digest('hex');
result = runRouter(signatureBody, {
  query: {},
  rawBody,
  headers: {
    'X-Crisp-Signature': signature,
    'X-Crisp-Request-Timestamp': timestamp,
  },
}).json;
assert.strictEqual(result.accepted, true);
assert.strictEqual(result.verification, 'signature');

const staleTimestamp = String(Date.now() - 400000);
const staleSignature = crypto.createHmac('sha256', secret).update(`[${staleTimestamp};${rawBody}]`).digest('hex');
result = runRouter(signatureBody, {
  query: {},
  rawBody,
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
result = runRouter(duplicateMessage, { state: duplicateState }).json;
assert.strictEqual(result.reason, '重复事件已忽略');

result = runRouter(makeMessage('请问服务时间')).json;
assert.strictEqual(result.route, 'reply');
assert(result.reply.includes('人工客服服务时间'));

result = runRouter(makeMessage('我要退款')).json;
assert.strictEqual(result.route, 'reply');
assert.strictEqual(result.handoffReason, '退款问题');
assert(result.reply.includes('转接人工客服'));

result = runRouter(makeMessage('菜单')).json;
assert.strictEqual(result.route, 'reply');
assert(result.reply.includes('电脑排障流程'));

const contextMessage = makeMessage('普通问题');
result = runRouter(contextMessage).json;
assert.strictEqual(result.route, 'ai_text');
assert.strictEqual(result.anythingBody.sessionId, contextMessage.data.session_id);

const handoffState = {};
const sharedSession = 'session_operator1234';
const operatorMessage = makeMessage('人工处理意见', { session_id: sharedSession, from: 'operator' });
operatorMessage.event = 'message:received';
result = runRouter(operatorMessage, { state: handoffState }).json;
assert.strictEqual(result.route, 'ignore');
assert(handoffState.sessions[sharedSession].handoffUntil > Date.now());
result = runRouter(makeMessage('还有问题', { session_id: sharedSession }), { state: handoffState }).json;
assert.strictEqual(result.route, 'ignore');
const resumeMessage = makeMessage('恢复AI', { session_id: sharedSession, from: 'operator' });
resumeMessage.event = 'message:received';
runRouter(resumeMessage, { state: handoffState });
result = runRouter(makeMessage('继续处理', { session_id: sharedSession }), { state: handoffState }).json;
assert.strictEqual(result.route, 'ai_text');
assert(result.anythingBody.message.includes('人工客服：人工处理意见'));

const welcomeState = {};
const welcomeBody = {
  event: 'session:set_opened',
  website_id: websiteId,
  data: { session_id: 'session_welcome1234' },
};
result = runRouter(welcomeBody, { state: welcomeState }).json;
assert.strictEqual(result.route, 'reply');
assert(result.reply.includes('您好，欢迎联系客服'));
result = runRouter(welcomeBody, { state: welcomeState }).json;
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

let formatterState = {};
let routed = runRouter(makeMessage('需要知识库回答'), { state: formatterState }).json;
result = formatKnowledge(routed, { data: { textResponse: '无来源回答', sources: [] } }, formatterState);
assert(result.reply.includes('可信度不足'));
assert(formatterState.sessions[routed.sessionId].handoffUntil > Date.now());

formatterState = {};
routed = runRouter(makeMessage('已有依据的问题'), { state: formatterState }).json;
result = formatKnowledge(routed, { data: { textResponse: '有依据的回答', sources: [{ score: 0.9 }] } }, formatterState);
assert(result.reply.includes('有依据的回答'));

formatterState = {};
routed = runRouter(makeMessage('触发 API 失败'), { state: formatterState }).json;
result = formatKnowledge(routed, { error: { message: 'test failure' } }, formatterState);
assert(result.reply.includes('自动客服暂时不可用'));
assert.strictEqual(formatterState.sessions[routed.sessionId].handoffReason, 'AI 调用失败');

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
assert.strictEqual(formatterState.sessions[routed.sessionId].handoffReason, '图片理解失败');

process.stdout.write('工作流行为测试：通过\n');
NODE
