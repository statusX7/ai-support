#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
if ! command -v node >/dev/null 2>&1; then
  printf '跳过：未安装开发测试依赖 Node.js。\n' >&2
  exit 77
fi
node "${PROJECT_ROOT}/n8n/build-workflow.js" --check
PROJECT_ROOT="$PROJECT_ROOT" node <<'NODE'
'use strict';
const fs = require('fs');
const path = require('path');
const assert = require('assert/strict');
const root = process.env.PROJECT_ROOT;
const workflow = JSON.parse(fs.readFileSync(path.join(root, 'n8n/workflow.json'), 'utf8'));
const { createRuntime } = require(path.join(root, 'n8n/runtime'));
const runtime = createRuntime({}, { root });
const byName = new Map(workflow.nodes.map((node) => [node.name, node]));
assert.equal(workflow.active, false);
assert.equal(workflow.settings.saveDataSuccessExecution, 'none');
assert.equal(workflow.settings.saveDataErrorExecution, 'none');
assert.equal(byName.get('Crisp Webhook').parameters.options.rawBody, true);
assert.equal(byName.get('Crisp Webhook').parameters.path, 'crisp-webhook');
assert.equal(workflow.connections['Crisp Webhook'].main[0][0].node, '校验并持久接收');
assert.equal(workflow.connections['校验并持久接收'].main[0][0].node, '返回 Webhook');
assert.equal(workflow.connections['返回 Webhook'].main[0][0].node, '处理持久任务');
assert.equal(byName.get('每五秒恢复与重试').parameters.rule.interval[0].secondsInterval, 5);
assert.equal(workflow.connections['每五秒恢复与重试'].main[0][0].node, '扫描持久会话与任务');
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
for (const node of workflow.nodes.filter((item) => item.type === 'n8n-nodes-base.code')) new AsyncFunction('$input', '$env', 'require', node.parameters.jsCode);
for (const name of ['keyword', 'handoff', 'menu']) runtime.validateConfig(name, JSON.parse(fs.readFileSync(path.join(root, 'config/' + name + '.yaml.example'), 'utf8')));
const keywords = JSON.parse(fs.readFileSync(path.join(root, 'config/keyword.yaml.example'), 'utf8'));
assert(keywords.rules.some((rule) => rule.action === 'show_handoff_offer' && rule.enabled && rule.confirm_label === '召唤人工客服'));
assert(keywords.rules.every((rule) => rule.action !== 'handoff'));
const menus = JSON.parse(fs.readFileSync(path.join(root, 'config/menu.yaml.example'), 'utf8'));
assert.equal(menus.welcome.enabled, true);
assert.equal(menus.welcome.auto_open, false);
assert.equal(menus.welcome.trigger, 'first_message');
const handoff = JSON.parse(fs.readFileSync(path.join(root, 'config/handoff.yaml.example'), 'utf8'));
assert.equal(handoff.handoff.resume_after_seconds, 1800);
assert(!handoff.handoff.on_no_answer && !handoff.handoff.on_low_confidence);
assert.equal(byName.get('公开欢迎配置').parameters.httpMethod, 'GET');
assert.equal(byName.get('公开欢迎配置').parameters.path, 'crispai-public-config');
process.stdout.write('工作流契约与生成一致性：通过\n');
NODE
