'use strict';

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const root = path.resolve(__dirname, '..');
const version = fs.readFileSync(path.join(root, 'VERSION'), 'utf8').trim();
const source = fs.readFileSync(path.join(__dirname, 'runtime.js'), 'utf8').replace(/^if \(typeof module[^\n]+\n?$/m, '').replace(/ai_support_version: 'v[^']+'/g, "ai_support_version: '" + version + "'");
const makeNode = (name, type, parameters, x, y, typeVersion = 2) => ({ name, id: crypto.createHash('md5').update('ai-support:' + name).digest('hex').replace(/(.{8})(.{4})(.{4})(.{4})(.{12})/, '$1-$2-$3-$4-$5'), type: 'n8n-nodes-base.' + type, typeVersion, position: [x, y], parameters });
const code = (body) => source + '\nconst runtime = createRuntime($env);\n' + body;
const nodes = [
  makeNode('Crisp Webhook', 'webhook', { httpMethod: 'POST', path: 'crisp-webhook', responseMode: 'responseNode', options: { rawBody: true } }, 0, 0, 2.1),
  makeNode('校验并持久接收', 'code', { jsCode: code('const input = $input.first();\nreturn [{ json: await runtime.receive(input.json, input.binary || {}) }];') }, 240, 0),
  makeNode('返回 Webhook', 'respondToWebhook', { respondWith: 'json', responseBody: '={{ JSON.stringify({accepted: $json.accepted, reason: $json.reason}) }}', options: { responseCode: '={{ $json.statusCode }}' } }, 480, 0, 1.5),
  makeNode('处理持久任务', 'code', { jsCode: code("const item = $input.first().json;\nif (!item.accepted || item.route !== 'process') return [{json:{status:'ignored'}}];\nreturn [{json:await runtime.process(item.key,item.jobId)}];") }, 720, 0),
  makeNode('每五秒恢复与重试', 'scheduleTrigger', { rule: { interval: [{ field: 'seconds', secondsInterval: 5 }] } }, 0, 260, 1.2),
  makeNode('扫描持久会话与任务', 'code', { jsCode: code('const jobs = await runtime.scan();\nconst results = await Promise.all(jobs.map((job) => runtime.process(job.key,job.jobId)));\nreturn [{json:{processed:results.length,failed:results.filter((result)=>result.status===\'failed\').length}}];') }, 240, 260),
  makeNode('公开欢迎配置', 'webhook', { httpMethod: 'GET', path: 'crispai-public-config', responseMode: 'responseNode', options: {} }, 0, 520, 2.1),
  makeNode('只读公开显示选项', 'code', { jsCode: code('return [{json:await runtime.publicConfig($input.first().json.query || {})}];') }, 240, 520),
  makeNode('返回公开配置', 'respondToWebhook', { respondWith: 'json', responseBody: '={{ JSON.stringify($json) }}', options: { responseCode: 200, responseHeaders: { entries: [{ name: 'Cache-Control', value: 'no-store' }, { name: 'Access-Control-Allow-Origin', value: '*' }, { name: 'X-Content-Type-Options', value: 'nosniff' }] } } }, 480, 520, 1.5),
  makeNode('网页接入脚本', 'webhook', { httpMethod: 'GET', path: 'crispai-web-chat', responseMode: 'responseNode', options: {} }, 0, 780, 2.1),
  makeNode('读取固定网页脚本', 'code', { jsCode: "return [{json:{script:require('fs').readFileSync('/opt/crisp-ai/n8n/web-chat.js','utf8')}}];" }, 240, 780),
  makeNode('返回网页脚本', 'respondToWebhook', { respondWith: 'text', responseBody: '={{ $json.script }}', options: { responseCode: 200, responseHeaders: { entries: [{ name: 'Content-Type', value: 'application/javascript; charset=utf-8' }, { name: 'Cache-Control', value: 'no-store' }, { name: 'X-Content-Type-Options', value: 'nosniff' }] } } }, 480, 780, 1.5),
];
for (const node of nodes.filter((entry) => entry.type === 'n8n-nodes-base.webhook')) node.webhookId = 'ai-support-' + node.parameters.path;
const edge = (name) => ({ main: [[{ node: name, type: 'main', index: 0 }]] });
const workflow = {
  id: '5d2c37c9-1c8e-45d0-8f53-c0a6e79b3a40', name: 'Crisp AI 客服', nodes,
  connections: { 'Crisp Webhook': edge('校验并持久接收'), '校验并持久接收': edge('返回 Webhook'), '返回 Webhook': edge('处理持久任务'), '每五秒恢复与重试': edge('扫描持久会话与任务'), '公开欢迎配置': edge('只读公开显示选项'), '只读公开显示选项': edge('返回公开配置'), '网页接入脚本': edge('读取固定网页脚本'), '读取固定网页脚本': edge('返回网页脚本') },
  active: false, settings: { executionOrder: 'v1', saveManualExecutions: false, saveDataErrorExecution: 'none', saveDataSuccessExecution: 'none', saveExecutionProgress: false, callerPolicy: 'workflowsFromSameOwner' },
  versionId: 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee', meta: { templateCredsSetupCompleted: true, aiSupportVersion: version, runtimeSha256: crypto.createHash('sha256').update(source).digest('hex') }, tags: [],
};
const rendered = JSON.stringify(workflow, null, 2) + '\n';
const filename = path.join(__dirname, 'workflow.json');
if (process.argv.includes('--check')) {
  if (fs.readFileSync(filename, 'utf8') !== rendered) { process.stderr.write('工作流与运行时源码不同步，请执行 node n8n/build-workflow.js。\n'); process.exitCode = 1; }
} else fs.writeFileSync(filename, rendered);
