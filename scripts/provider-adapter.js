'use strict';

const http = require('node:http');
const fs = require('node:fs');
const crypto = require('node:crypto');

const MAX_INPUT_BYTES = 12 * 1024 * 1024;
const MAX_RESPONSE_BYTES = 8 * 1024 * 1024;
const forbiddenHeaders = new Set(['authorization', 'host', 'connection', 'content-length', 'content-type', 'transfer-encoding', 'cookie', 'proxy-authorization']);

function parseHeaders(input) {
  if (!input || typeof input !== 'object' || Array.isArray(input)) throw new Error('自定义请求头必须是对象');
  if (Object.keys(input).length > 32) throw new Error('自定义请求头过多');
  const headers = {};
  for (const [name, value] of Object.entries(input)) {
    if (!/^[A-Za-z][A-Za-z0-9-]{0,99}$/.test(name) || forbiddenHeaders.has(name.toLowerCase())) throw new Error('请求头名称不允许');
    if (typeof value !== 'string' || value.length > 4096 || /[\x00-\x1f\x7f]/.test(value)) throw new Error('请求头值无效');
    headers[name] = value;
  }
  return headers;
}

function providerSettings(environment = process.env) {
  const configPath = environment.PROVIDER_CONFIG_PATH || '/opt/crisp-ai/config/provider.yaml';
  let provider;
  try { provider = JSON.parse(fs.readFileSync(configPath, 'utf8')).provider; }
  catch { throw new Error('受管 Provider 配置缺失、不可读或格式无效'); }
  if (!provider || typeof provider !== 'object' || Array.isArray(provider)) throw new Error('受管 Provider 配置结构无效');
  const base = new URL(provider.base_url || environment.AI_API_BASE_URL);
  if (!['https:', 'http:'].includes(base.protocol) || base.username || base.password || base.search || base.hash) throw new Error('Provider 地址无效');
  if (base.protocol === 'http:' && !['127.0.0.1', 'localhost', 'host.docker.internal'].includes(base.hostname)) throw new Error('Provider 明文地址仅允许受管宿主网关');
  const mode = provider.api_mode || environment.AI_API_MODE || 'chat_completions';
  if (!['chat_completions', 'responses'].includes(mode)) throw new Error('Provider 协议无效');
  let extraHeaders = provider.custom_headers || {};
  if (environment.AI_CUSTOM_HEADERS_JSON) extraHeaders = JSON.parse(environment.AI_CUSTOM_HEADERS_JSON);
  const key = environment.AI_API_KEY;
  if (!key || /[\r\n\0]/.test(key)) throw new Error('Provider 认证缺失');
  const timeout = Math.min(180000, Math.max(1000, Number(environment.PROVIDER_TIMEOUT_MS) || 120000));
  return {base:base.href.replace(/\/$/, ''), mode, key, headers:parseHeaders(extraHeaders), model:provider.model || environment.AI_MODEL, timeout};
}

function validImage(image) {
  if (typeof image !== 'string' || image.length > MAX_INPUT_BYTES) throw new Error('图片输入超限');
  if (/^data:image\/(png|jpeg|webp|gif);base64,[A-Za-z0-9+/=]+$/.test(image)) return image;
  throw new Error('图片必须经过受管下载校验并使用 data URL');
}

function chatToResponses(body, settings) {
  if (!Array.isArray(body.messages) || body.messages.length === 0 || body.messages.length > 200) throw new Error('消息列表无效');
  const input = body.messages.map(message => {
    if (!['system', 'developer', 'user', 'assistant'].includes(message.role)) throw new Error('消息角色不受支持');
    const role = message.role;
    let content;
    if (typeof message.content === 'string') content = [{type:role === 'assistant' ? 'output_text' : 'input_text', text:message.content}];
    else if (Array.isArray(message.content)) content = message.content.map(part => {
      if (part.type === 'text' && typeof part.text === 'string') return {type:role === 'assistant' ? 'output_text' : 'input_text', text:part.text};
      if (part.type === 'image_url' && role !== 'assistant') return {type:'input_image', image_url:validImage(part.image_url?.url), detail:part.image_url?.detail || 'auto'};
      throw new Error('消息内容类型不受支持');
    });
    else throw new Error('消息正文无效');
    return {role, content};
  });
  const converted = {model:settings.model, input, stream:false, store:false};
  const maximum = body.max_completion_tokens ?? body.max_tokens ?? body.max_output_tokens;
  if (Number.isInteger(maximum) && maximum > 0) converted.max_output_tokens = Math.min(maximum, 16384);
  return converted;
}

function responseToChat(body, model) {
  if (body.error || body.status === 'failed') throw new Error('Provider 返回错误');
  const content = typeof body.output_text === 'string' ? body.output_text : (body.output || []).flatMap(item => item.content || []).filter(part => part.type === 'output_text' && typeof part.text === 'string').map(part => part.text).join('');
  if (!content.trim()) throw new Error('Provider 未返回有效正文');
  return {id:body.id || `chatcmpl-${crypto.randomUUID()}`, object:'chat.completion', created:Math.floor(Date.now()/1000), model,
    choices:[{index:0, message:{role:'assistant', content}, finish_reason:body.status === 'incomplete' ? 'length' : 'stop'}],
    usage:{prompt_tokens:body.usage?.input_tokens || 0, completion_tokens:body.usage?.output_tokens || 0, total_tokens:body.usage?.total_tokens || 0}};
}

function validChat(body) {
  if (body.error || !Array.isArray(body.choices) || !body.choices.length || typeof body.choices[0]?.message?.content !== 'string' || !body.choices[0].message.content.trim()) throw new Error('Provider 未返回有效 Chat 正文');
  return body;
}

async function readLimited(stream, maximum) {
  const buffers = [];
  let total = 0;
  for await (const chunk of stream) {
    total += chunk.length;
    if (total > maximum) throw new Error('请求或响应体超过限制');
    buffers.push(Buffer.from(chunk));
  }
  return Buffer.concat(buffers).toString('utf8');
}

function sendJson(response, status, value) {
  if (response.destroyed || response.writableEnded) return;
  response.writeHead(status, {'content-type':'application/json; charset=utf-8', 'cache-control':'no-store'});
  response.end(JSON.stringify(value));
}

function writeChatStream(response, result) {
  response.writeHead(200, {'content-type':'text/event-stream', 'cache-control':'no-cache'});
  const shared = {id:result.id,object:'chat.completion.chunk',created:result.created,model:result.model};
  response.write(`data: ${JSON.stringify({...shared,choices:[{index:0,delta:{role:'assistant',content:result.choices[0].message.content},finish_reason:null}]})}\n\n`);
  response.write(`data: ${JSON.stringify({...shared,choices:[{index:0,delta:{},finish_reason:result.choices[0].finish_reason || 'stop'}],usage:result.usage})}\n\n`);
  response.end('data: [DONE]\n\n');
}

function createAdapter(environment = process.env, fetchFunction = fetch) {
  const server = http.createServer(async (request, response) => {
    if (request.url === '/healthz' && request.method === 'GET') {
      try { providerSettings(environment); sendJson(response, 200, {ready:true}); }
      catch { sendJson(response, 503, {ready:false}); }
      return;
    }
    const controller = new AbortController();
    let timer;
    response.on('close', () => { if (!response.writableEnded) controller.abort(); });
    try {
      const settings = providerSettings(environment);
      const provided = Buffer.from(request.headers.authorization || '');
      const expected = Buffer.from(`Bearer ${settings.key}`);
      if (provided.length !== expected.length || !crypto.timingSafeEqual(provided, expected)) { sendJson(response, 401, {error:{message:'内部认证失败'}}); return; }
      if (request.method !== 'POST' || request.url !== '/v1/chat/completions') { sendJson(response, 404, {error:{message:'不支持的协议路由'}}); return; }
      const body = JSON.parse(await readLimited(request, MAX_INPUT_BYTES));
      if (body.tools || body.functions) { sendJson(response, 400, {error:{message:'客服协议适配不执行模型工具'}}); return; }
      if (!Array.isArray(body.messages) || body.messages.length > 200) throw new Error('消息格式无效');
      let outbound;
      if (settings.mode === 'responses') outbound = chatToResponses(body, settings);
      else {
        chatToResponses(body, settings);
        outbound = {...body, model:settings.model, stream:false};
        delete outbound.stream_options;
      }
      timer = setTimeout(() => controller.abort(), settings.timeout);
      const upstream = await fetchFunction(`${settings.base}/${settings.mode === 'responses' ? 'responses' : 'chat/completions'}`, {
        method:'POST',headers:{...settings.headers,'authorization':`Bearer ${settings.key}`,'content-type':'application/json'},
        redirect:'error',signal:controller.signal,body:JSON.stringify(outbound)
      });
      if (!upstream.ok) {
        await upstream.body?.cancel();
        sendJson(response, upstream.status >= 400 && upstream.status < 600 ? upstream.status : 502, {error:{message:`Provider 请求失败（HTTP ${upstream.status}）`,type:'upstream_error'}});
        return;
      }
      const upstreamBody = JSON.parse(await readLimited(upstream.body, MAX_RESPONSE_BYTES));
      const result = settings.mode === 'responses' ? responseToChat(upstreamBody, settings.model) : validChat(upstreamBody);
      if (body.stream) writeChatStream(response, result); else sendJson(response, 200, result);
    } catch (error) {
      sendJson(response, error.name === 'AbortError' ? 504 : 502, {error:{message:error.name === 'AbortError' ? 'Provider 请求超时或已取消' : 'Provider 响应或输入格式无效',type:'provider_adapter_error'}});
    } finally { if (timer) clearTimeout(timer); }
  });
  server.requestTimeout = 200000;
  server.headersTimeout = 15000;
  return server;
}

module.exports = {createAdapter, chatToResponses, responseToChat, parseHeaders, providerSettings};
if (require.main === module) {
  const server = createAdapter();
  server.listen(Number(process.env.PROVIDER_ADAPTER_PORT) || 8787, '0.0.0.0');
  process.on('SIGTERM', () => server.close(() => process.exit(0)));
}
