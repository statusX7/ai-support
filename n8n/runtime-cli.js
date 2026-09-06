'use strict';

const fs = require('fs');
const { createRuntime } = require('./runtime');
const runtime = createRuntime(process.env);
const [command = 'status', key, value] = process.argv.slice(2);
(async () => {
  let result;
  if (command === 'list') result = await runtime.list();
  else if (command === 'observations') result = await runtime.observations();
  else if (command === 'status') result = { configuration: runtime.settings(), sessions: (await runtime.list()).map(({ key: id, mode, resume_at, pause_reason }) => ({ key: id, mode, resume_at, pause_reason })) };
  else if (command === 'resume') result = await runtime.resume(key);
  else if (command === 'adjust-resume') result = await runtime.adjustResume(key, value);
  else if (command === 'clear-analytics') result = await runtime.clearAnalytics();
  else if (command === 'validate-config') { runtime.validateConfig(key.replace(/\.yaml$/, ''), JSON.parse(fs.readFileSync(value, 'utf8'))); result = { valid: true }; }
  else if (command === 'preview-rule') result = runtime.matchRule(key) || null;
  else if (command === 'public-config') result = await runtime.publicConfig({ website_id: process.env.CRISP_WEBSITE_ID, session_id: key });
  else if (command === 'snippet') {
    const url = new URL(process.env.PUBLIC_WEBHOOK_URL || process.env.WEBHOOK_URL || 'https://support.example.com/');
    if (url.protocol !== 'https:' || url.username || url.password) throw new Error('公网 HTTPS 地址尚未配置');
    url.search = ''; url.hash = ''; url.pathname = url.pathname.replace(/\/+$/, '') + '/';
    const script = new URL('webhook/crispai-web-chat', url);
    const configuration = new URL('webhook/crispai-public-config', url);
    const escape = (value) => String(value).replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/</g, '&lt;');
    result = { instructions: '将片段放在站点已有 Crisp 初始化代码之后；无需重复安装 Crisp，不含 API 凭据。', html: '<script src="' + escape(script.href) + '" data-config-url="' + escape(configuration.href) + '" defer></script>', events: ['message:send', 'message:received', 'message:updated', 'session:sync:events'] };
  }
  else throw new Error('未知操作：支持 status / list / resume / adjust-resume / validate-config / preview-rule / public-config');
  process.stdout.write(JSON.stringify(result) + '\n');
})().catch((error) => { process.stderr.write('操作失败：' + error.message + '\n'); process.exitCode = 1; });
