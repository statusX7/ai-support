'use strict';

const http = require('node:http');
const https = require('node:https');
const fs = require('node:fs');
const crypto = require('node:crypto');
const path = require('node:path');
const {createRouter,loadPool,validateEntry,parseHeaders,RouterError,terminal,classifyFailure} = require('./provider-router.js');
const {extractEnvelope,promptRetained} = require('./provider-envelope.js');

const MAX_INPUT_BYTES = 12 * 1024 * 1024;
const MAX_RESPONSE_BYTES = 8 * 1024 * 1024;

function appliedPrompt(root, revision) {
  const read = (file, maximum) => {
    const stat = fs.lstatSync(file);
    if (!stat.isFile() || stat.isSymbolicLink() || stat.size < 1 || stat.size > maximum) throw new Error('invalid prompt source');
    return fs.readFileSync(file,'utf8');
  };
  const projectionPath = path.join(root,'config/materials-applied.json');
  let source;
  try { source = read(projectionPath,16777216); }
  catch (error) { if (error.code !== 'ENOENT') throw error; }
  let prompt;
  if (source !== undefined) {
    const projection = JSON.parse(source);
    prompt = projection.prompt?.text;
    if (projection.schema_version !== 1 || projection.state !== 'applied' || projection.revision !== revision
      || projection.configuration?.runtime?.revision !== revision || typeof prompt !== 'string'
      || Buffer.byteLength(prompt) !== projection.prompt.bytes
      || crypto.createHash('sha256').update(prompt).digest('hex') !== projection.prompt.sha256) throw new Error('invalid applied prompt');
  } else prompt = read(path.join(root,'config/prompt.md'),262144);
  if (!prompt.trim() || prompt.includes('\0') || Buffer.byteLength(prompt) > 262144) throw new Error('invalid prompt');
  return prompt;
}

function providerSettings(environment = process.env) {
  let provider;
  try { provider = JSON.parse(fs.readFileSync(environment.PROVIDER_CONFIG_PATH || '/opt/crisp-ai/config/provider.yaml','utf8')).provider; }
  catch (_) { throw new Error('受管 Provider 配置缺失、不可读或格式无效'); }
  if (!provider || typeof provider !== 'object' || Array.isArray(provider)) throw new Error('受管 Provider 配置结构无效');
  const base = new URL(provider.base_url || environment.AI_API_BASE_URL);
  if (!['https:','http:'].includes(base.protocol) || base.username || base.password || base.search || base.hash
    || base.protocol === 'http:' && !['127.0.0.1','localhost','host.docker.internal'].includes(base.hostname)) throw new Error('Provider 地址无效');
  const mode = provider.api_mode || environment.AI_API_MODE || 'chat_completions';
  if (!['chat_completions','responses'].includes(mode)) throw new Error('Provider 协议无效');
  const key = environment.AI_API_KEY;
  if (!key || /[\r\n\0]/.test(key)) throw new Error('Provider 认证缺失');
  return {base:base.href.replace(/\/$/,''),mode,key,headers:parseHeaders(environment.AI_CUSTOM_HEADERS_JSON ? JSON.parse(environment.AI_CUSTOM_HEADERS_JSON) : provider.custom_headers || {}),
    model:provider.model || environment.AI_MODEL,timeout:Math.min(180000,Math.max(1000,Number(environment.PROVIDER_TIMEOUT_MS) || 120000)),connectTimeout:5000,maxOutput:16384};
}

function validImage(image) {
  if (typeof image !== 'string' || image.length > MAX_INPUT_BYTES || !/^data:image\/(png|jpeg|webp|gif);base64,[A-Za-z0-9+/=]+$/.test(image)) throw terminal('invalid_input','图片必须经过受管下载校验并使用 data URL');
  return image;
}

function chatToResponses(body, settings) {
  if (!Array.isArray(body.messages) || body.messages.length === 0 || body.messages.length > 200) throw terminal('invalid_input','消息列表无效');
  const input = body.messages.map(message => {
    if (!message || !['system','developer','user','assistant'].includes(message.role)) throw terminal('invalid_input','消息角色不受支持');
    const role = message.role;
    let content;
    if (typeof message.content === 'string') content = [{type:role === 'assistant' ? 'output_text':'input_text',text:message.content}];
    else if (Array.isArray(message.content) && message.content.length) content = message.content.map(part => {
      if (part.type === 'text' && typeof part.text === 'string') return {type:role === 'assistant' ? 'output_text':'input_text',text:part.text};
      if (part.type === 'image_url' && role !== 'assistant') {
        const detail = part.image_url?.detail || 'auto';
        if (!['auto','low','high'].includes(detail)) throw terminal('invalid_input','图片细节等级无效');
        return {type:'input_image',image_url:validImage(part.image_url?.url),detail};
      }
      throw terminal('invalid_input','消息内容类型不受支持');
    }); else throw terminal('invalid_input','消息正文无效');
    return {role,content};
  });
  const converted = {model:settings.model,input,stream:false,store:false};
  const maximum = settings.maxOutput ?? body.max_completion_tokens ?? body.max_tokens ?? body.max_output_tokens;
  if (Number.isInteger(maximum) && maximum > 0) converted.max_output_tokens = maximum;
  if (typeof body.temperature === 'number' && body.temperature >= 0 && body.temperature <= 2) converted.temperature = body.temperature;
  if (typeof body.top_p === 'number' && body.top_p >= 0 && body.top_p <= 1) converted.top_p = body.top_p;
  return converted;
}

function upstreamFailure(status, body, headers) {
  const failure = classifyFailure(status,body,headers);
  return new RouterError(failure.kind,'Provider 请求未返回可用结果',{failure,status:failure.status || 502});
}

function responseToChat(body, model) {
  if (body.error || body.status === 'failed' || ['queued','in_progress','cancelled'].includes(body.status)) throw upstreamFailure(200,body);
  const parts = (Array.isArray(body.output) ? body.output : []).flatMap(item => Array.isArray(item.content) ? item.content : []);
  const content = typeof body.output_text === 'string' ? body.output_text : parts.filter(part => part.type === 'output_text' && typeof part.text === 'string').map(part => part.text).join('');
  const refusal = parts.filter(part => part.type === 'refusal' && typeof part.refusal === 'string').map(part => part.refusal).join('');
  const filtered = body.incomplete_details?.reason === 'content_filter';
  if (!content.trim() && !refusal.trim() && !filtered) throw upstreamFailure(200,{});
  const input = Number(body.usage?.input_tokens) || 0, output = Number(body.usage?.output_tokens) || 0;
  const usage = {prompt_tokens:input,completion_tokens:output,total_tokens:Number(body.usage?.total_tokens) || input+output};
  if (body.usage?.input_tokens_details) usage.prompt_tokens_details = body.usage.input_tokens_details;
  if (body.usage?.output_tokens_details) usage.completion_tokens_details = body.usage.output_tokens_details;
  return {id:body.id || `chatcmpl-${crypto.randomUUID()}`,object:'chat.completion',created:Number(body.created_at) || Math.floor(Date.now()/1000),model,
    choices:[{index:0,message:{role:'assistant',content:content || null,...(refusal ? {refusal}: {})},finish_reason:filtered ? 'content_filter':body.status === 'incomplete' ? 'length':'stop'}],usage};
}

function validChat(body,model) {
  if (body.error) throw upstreamFailure(200,body);
  const choice = body.choices?.[0], message = choice?.message;
  if (!message || !(typeof message.content === 'string' && message.content.trim()) && !(typeof message.refusal === 'string' && message.refusal.trim()) && choice.finish_reason !== 'content_filter') throw upstreamFailure(200,{});
  if (message.tool_calls || message.function_call) throw terminal('invalid_input','客服协议不执行模型工具');
  return {id:body.id || `chatcmpl-${crypto.randomUUID()}`,object:'chat.completion',created:body.created || Math.floor(Date.now()/1000),model:model || body.model,
    choices:[{index:0,message:{role:'assistant',content:message.content ?? null,...(message.refusal ? {refusal:message.refusal}:{})},finish_reason:choice.finish_reason || 'stop'}],...(body.usage ? {usage:body.usage}: {})};
}

async function readLimited(stream, maximum) {
  const buffers = []; let total = 0;
  for await (const chunk of stream) { total += chunk.length; if (total > maximum) throw new Error('请求或响应体超过限制'); buffers.push(Buffer.from(chunk)); }
  return Buffer.concat(buffers).toString('utf8');
}

function requestUpstream(url,settings,payload,signal,fetchFunction) {
  const controller = new AbortController();
  const abort = () => controller.abort();
  signal?.addEventListener('abort',abort,{once:true});
  if (signal?.aborted) controller.abort();
  const timeout = setTimeout(abort,settings.timeout);
  const headers = {...settings.headers,authorization:`Bearer ${settings.key}`,'content-type':'application/json'};
  if (fetchFunction) return (async () => {
    try {
      const response = await fetchFunction(url,{method:payload ? 'POST':'GET',headers,redirect:'error',signal:controller.signal,...(payload ? {body:JSON.stringify(payload)}:{})});
      const raw = await readLimited(response.body,MAX_RESPONSE_BYTES);
      let body; try { body = JSON.parse(raw); } catch (_) { throw upstreamFailure(response.status,{},response.headers); }
      if (!response.ok) throw upstreamFailure(response.status,body,response.headers);
      return body;
    } finally { clearTimeout(timeout); signal?.removeEventListener('abort',abort); }
  })();
  return new Promise((resolve,reject) => {
    let connectionTimer;
    const cleanup = () => { clearTimeout(timeout); clearTimeout(connectionTimer); signal?.removeEventListener('abort',abort); };
    const request = (url.startsWith('https:') ? https:http).request(url,{method:payload ? 'POST':'GET',headers,signal:controller.signal,agent:false},async response => {
      try {
        const raw = await readLimited(response,MAX_RESPONSE_BYTES);
        let body; try { body = JSON.parse(raw); } catch (_) { throw upstreamFailure(response.statusCode,{},response.headers); }
        if (response.statusCode < 200 || response.statusCode >= 300) throw upstreamFailure(response.statusCode,body,response.headers);
        resolve(body);
      } catch (error) { reject(error); } finally { cleanup(); }
    });
    connectionTimer = setTimeout(abort,settings.connectTimeout);
    request.on('socket',socket => { socket.once(url.startsWith('https:') ? 'secureConnect':'connect',() => clearTimeout(connectionTimer)); });
    request.on('error',error => { cleanup(); reject(error); });
    request.end(payload ? JSON.stringify(payload):undefined);
  });
}

function sendJson(response,status,value) {
  if (response.destroyed || response.writableEnded) return;
  response.writeHead(status,{'content-type':'application/json; charset=utf-8','cache-control':'no-store'}); response.end(JSON.stringify(value));
}

function writeChatStream(response,result) {
  response.writeHead(200,{'content-type':'text/event-stream','cache-control':'no-cache'});
  const shared = {id:result.id,object:'chat.completion.chunk',created:result.created,model:result.model};
  const message = result.choices[0].message;
  response.write(`data: ${JSON.stringify({...shared,choices:[{index:0,delta:{role:'assistant',...(message.content !== null ? {content:message.content}:{}),...(message.refusal ? {refusal:message.refusal}:{})},finish_reason:null}]})}\n\n`);
  response.write(`data: ${JSON.stringify({...shared,choices:[{index:0,delta:{},finish_reason:result.choices[0].finish_reason || 'stop'}],...(result.usage ? {usage:result.usage}:{})})}\n\n`);
  response.end('data: [DONE]\n\n');
}

function createAdapter(environment = process.env, fetchFunction) {
  let router;
  const root = environment.PROVIDER_ROOT || '/opt/crisp-ai';
  const pooled = () => environment.PROVIDER_POOL_REQUIRED === 'true' || !!environment.PROVIDER_POOL_PATH || fs.existsSync(path.join(environment.PROVIDER_ROOT || '/opt/crisp-ai','config/provider-pool-applied.json'));
  const configurationPending = () => {
    try { fs.lstatSync(path.join(root,'config/provider-pool-transaction.json')); return true; }
    catch (error) { return error.code !== 'ENOENT'; }
  };
  const requireApplied = () => { if (configurationPending()) throw terminal('configuration_applying','接口窗口配置正在应用或等待恢复，暂不能开始推理'); };
  const invoke = async (body,settings,signal) => {
    if (pooled()) requireApplied();
    const converted = chatToResponses(body,settings);
    // 只构造受支持字段，不复用不同供应商的 previous_response_id、file、thread 或工具状态。
    const outbound = settings.mode === 'responses' ? converted : {model:settings.model,messages:body.messages,stream:false,
      ...(settings.maxOutput ? {[Object.hasOwn(body,'max_completion_tokens') ? 'max_completion_tokens':'max_tokens']:settings.maxOutput}:{}),...(converted.temperature !== undefined ? {temperature:converted.temperature}:{}),...(converted.top_p !== undefined ? {top_p:converted.top_p}:{})};
    const base = new URL(settings.base);
    if (environment.PROVIDER_HOST_GATEWAY && ['127.0.0.1','localhost'].includes(base.hostname)) base.hostname = environment.PROVIDER_HOST_GATEWAY;
    const result = await requestUpstream(base.href.replace(/\/$/,'') + '/' + (settings.mode === 'responses' ? 'responses':'chat/completions'),settings,outbound,signal,fetchFunction);
    if (pooled()) requireApplied();
    return settings.mode === 'responses' ? responseToChat(result,settings.model):validChat(result,settings.model);
  };
  const getRouter = () => { if (!router) router = createRouter(environment,invoke); return router; };
  const server = http.createServer(async (request,response) => {
    const controller = new AbortController();
    response.on('close',() => { if (!response.writableEnded) controller.abort(); });
    let isPool = false;
    try {
      isPool = pooled();
      if (request.url === '/healthz' && request.method === 'GET') {
        if (isPool) {
          requireApplied();
          const pool = loadPool(environment);
          if (!environment.PROVIDER_ADAPTER_KEY || pool.entries.some(entry => entry.key === environment.PROVIDER_ADAPTER_KEY)) throw terminal('internal_key_missing','内部认证缺失或与上游认证混用');
          sendJson(response,200,{ready:true,health:'unknown',revision:getRouter().status().revision});
        }
        else { providerSettings(environment); sendJson(response,200,{ready:true}); }
        return;
      }
      const legacy = isPool ? null:providerSettings(environment);
      const key = environment.PROVIDER_ADAPTER_KEY || (!isPool ? legacy.key:'');
      if (!key) throw terminal('internal_key_missing','内部认证尚未配置');
      const provided = Buffer.from(request.headers.authorization || ''), expected = Buffer.from(`Bearer ${key}`);
      if (provided.length !== expected.length || !crypto.timingSafeEqual(provided,expected)) { sendJson(response,401,{error:{message:'内部认证失败',code:'authentication_failed'}}); return; }
      if (isPool && request.method === 'GET' && request.url === '/internal/provider/status') { sendJson(response,200,{...getRouter().status(),configuration_state:configurationPending() ? 'applying':'applied'}); return; }
      if (isPool && request.method === 'GET' && request.url === '/internal/provider/recent') { sendJson(response,200,getRouter().recent()); return; }
      if (request.method !== 'POST') { sendJson(response,404,{error:{message:'不支持的协议路由'}}); return; }
      const body = JSON.parse(await readLimited(request,MAX_INPUT_BYTES));
      if (isPool && ['/internal/provider/probe','/internal/provider/models'].includes(request.url)) {
        let candidate = body.provider || {}, secret = {api_key:body.api_key,custom_headers:candidate.custom_headers || {}};
        if (body.entry_id) {
          const entry = getRouter().loadPool().entries.find(value => value.id === body.entry_id);
          if (!entry) throw terminal('entry_not_found','接口不存在');
          secret = {api_key:body.api_key || entry.key,custom_headers:{...entry.headers,...secret.custom_headers}};
          candidate = {...entry,...candidate};
          if (candidate.remove_header) delete secret.custom_headers[candidate.remove_header.toLowerCase()];
        }
        const entry = validateEntry({id:'p_'+'0'.repeat(24),enabled:true,context_window:8192,max_output_tokens:1200,capabilities:{chat_completions:true,responses:true,vision:false},...candidate},secret);
        const settings = {...entry,timeout:20000,connectTimeout:5000,maxOutput:64};
        if (request.url.endsWith('/models')) {
          settings.timeout = 10000;
          const base = new URL(settings.base);
          if (environment.PROVIDER_HOST_GATEWAY && ['127.0.0.1','localhost'].includes(base.hostname)) base.hostname = environment.PROVIDER_HOST_GATEWAY;
          const result = await requestUpstream(base.href.replace(/\/$/,'')+'/models',settings,null,controller.signal,fetchFunction);
          if (!Array.isArray(result.data)) throw terminal('models_unavailable','接口未提供模型列表，可以手动填写模型');
          const models = [...new Set(result.data.map(value => value.id).filter(value => typeof value === 'string' && /^[A-Za-z0-9][A-Za-z0-9._:/+@-]{0,511}$/.test(value)))].sort().slice(0,1000);
          if (!models.length) throw terminal('models_unavailable','接口未提供可用模型列表，可以手动填写模型');
          sendJson(response,200,{ok:true,models}); return;
        }
        const image = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=';
        const testBody = {messages:[{role:'user',content:body.vision ? [{type:'text',text:'请描述图片。'},{type:'image_url',image_url:{url:image}}]:'只回复：测试正常'}]};
        const result = await invoke(testBody,settings,controller.signal);
        if (result.choices[0].message.refusal || result.choices[0].finish_reason === 'content_filter') throw terminal('safety_refusal','模型拒绝了测试内容，未更新能力');
        sendJson(response,200,{ok:true,id:body.entry_id || null,verified:true,api_mode:entry.mode,capabilities:{chat_completions:entry.mode === 'chat_completions',responses:entry.mode === 'responses',vision:body.vision === true}}); return;
      }
      if (request.url !== '/v1/chat/completions') { sendJson(response,404,{error:{message:'不支持的协议路由'}}); return; }
      if (body.tools || body.functions || body.previous_response_id || body.thread_id || body.file_ids) throw terminal('invalid_input','客服协议不接受工具或供应商专属会话状态');
      chatToResponses(body,{model:'validate'});
      let result;
      if (isPool) {
        let envelope;
        try { envelope = extractEnvelope(body,request.headers['x-crispai-question'],key,environment.PROVIDER_REQUIRE_ENVELOPE === 'true'); }
        catch (_) { throw terminal('invalid_envelope','受管问题信封缺失或无效'); }
        requireApplied();
        if (envelope?.stage === 'answer') {
          try { if (!promptRetained(body,appliedPrompt(root,envelope.runtime_revision))) throw new Error('prompt not retained'); }
          catch (_) { throw terminal('context_preparation_incomplete','知识上下文准备未完整保留已应用的业务规则，本次未执行模型推理'); }
        }
        result = await getRouter().route(body,envelope,controller.signal);
        requireApplied();
      } else result = await invoke(body,legacy,controller.signal);
      if (body.stream) writeChatStream(response,result); else sendJson(response,200,result);
    } catch (error) {
      if (request.url === '/healthz') { sendJson(response,503,{ready:false,health:'unavailable'}); return; }
      const status = isPool ? error.terminal ? 400:error.failure ? error.failure.fallback ? 503:400:400 : error.name === 'AbortError' ? 504:error.failure?.status >= 400 ? error.failure.status:502;
      const code = error instanceof RouterError ? error.code : error.name === 'AbortError' ? 'upstream_timeout' : ['ECONNREFUSED','ECONNRESET','ETIMEDOUT','EAI_AGAIN','ENOTFOUND','EPROTO','CERT_HAS_EXPIRED','DEPTH_ZERO_SELF_SIGNED_CERT'].includes(error.code) ? 'connection_failed':'provider_adapter_error';
      sendJson(response,status,{ok:false,error:{message:error.terminal ? error.message:'Provider 请求或响应无效',code,type:'provider_adapter_error',retryable:false,
        ...(error.failure?.retryAfter ? {retry_after_ms:error.failure.retryAfter}: {})}});
    }
  });
  server.requestTimeout = 200000; server.headersTimeout = 15000;
  return server;
}

module.exports = {createAdapter,chatToResponses,responseToChat,parseHeaders,providerSettings,validChat,writeChatStream,requestUpstream};
if (require.main === module) {
  const server = createAdapter(); server.listen(Number(process.env.PROVIDER_ADAPTER_PORT) || 8787,'0.0.0.0');
  process.on('SIGTERM',() => server.close(() => process.exit(0)));
}
