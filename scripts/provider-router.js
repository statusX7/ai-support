'use strict';

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');

const DEFAULT_POLICY = Object.freeze({question_timeout_ms:90000, call_timeout_ms:20000, connect_timeout_ms:5000,
  max_attempts:21, cooldown_initial_ms:60000, cooldown_max_ms:300000, pool_cooldown_ms:3000});
const POLICY_BOUNDS = {question_timeout_ms:[1000,180000],call_timeout_ms:[1000,60000],connect_timeout_ms:[100,10000],
  max_attempts:[1,21],cooldown_initial_ms:[1000,300000],cooldown_max_ms:[1000,3600000],pool_cooldown_ms:[100,60000]};
const forbiddenHeaders = new Set(['authorization','host','connection','content-length','content-type','transfer-encoding','cookie','proxy-authorization','x-crispai-question']);
const hash = value => crypto.createHash('sha256').update(String(value)).digest('hex');

function estimateTextTokens(text) {
  let estimate = 0, ascii = 0;
  const flush = () => { estimate += Math.ceil(ascii/3); ascii = 0; };
  for (const character of String(text)) {
    if (character.codePointAt(0) < 128) { ascii++; continue; }
    flush();
    if (/[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Hangul}]/u.test(character)) estimate += 2;
    else if (/\p{Extended_Pictographic}/u.test(character)) estimate += 4;
    else estimate += Math.ceil(Buffer.byteLength(character)/2);
  }
  flush();
  return Math.ceil(estimate*1.1);
}

class RouterError extends Error {
  constructor(code, message, options = {}) { super(message); this.name = 'RouterError'; this.code = code; Object.assign(this, options); }
}
const terminal = (code, message) => new RouterError(code, message, {status:400, terminal:true});

function parseHeaders(input) {
  if (!input || typeof input !== 'object' || Array.isArray(input) || Object.keys(input).length > 32) throw terminal('invalid_input', '自定义请求头必须是至多32项的对象');
  const headers = {};
  for (const [name,value] of Object.entries(input)) {
    if (!/^[A-Za-z][A-Za-z0-9-]{0,99}$/.test(name) || forbiddenHeaders.has(name.toLowerCase()) || name.toLowerCase().startsWith('proxy-')) throw terminal('invalid_input', '请求头名称不允许');
    if (typeof value !== 'string' || value.length > 4096 || /[\x00-\x1f\x7f]/.test(value)) throw terminal('invalid_input', '请求头值无效');
    if (Object.hasOwn(headers, name.toLowerCase())) throw terminal('invalid_input', '请求头名称重复');
    headers[name.toLowerCase()] = value;
  }
  return headers;
}

function validatePolicy(value = {}) {
  if (!value || typeof value !== 'object' || Array.isArray(value) || Object.keys(value).some(key => !Object.hasOwn(POLICY_BOUNDS,key))) throw terminal('invalid_policy', '路由策略字段无效');
  const result = {...DEFAULT_POLICY,...value};
  for (const [key,[low,high]] of Object.entries(POLICY_BOUNDS)) if (!Number.isSafeInteger(result[key]) || result[key] < low || result[key] > high) throw terminal('invalid_policy', '路由策略数值超出范围');
  if (result.connect_timeout_ms > result.call_timeout_ms || result.call_timeout_ms > result.question_timeout_ms || result.cooldown_initial_ms > result.cooldown_max_ms) throw terminal('invalid_policy','路由策略先后限制无效');
  return result;
}

function validateEntry(entry, secret) {
  if (!entry || !/^p_[a-f0-9]{24}$/.test(entry.id || '') || typeof entry.enabled !== 'boolean'
    || !['chat_completions','responses'].includes(entry.api_mode) || !/^[A-Za-z0-9][A-Za-z0-9._:/+@-]{0,511}$/.test(entry.model || '')) throw terminal('invalid_pool','接口定义无效');
  const base = new URL(entry.base_url);
  if (!['https:','http:'].includes(base.protocol) || base.username || base.password || base.search || base.hash || /[\x00-\x20\x7f]/.test(entry.base_url)
    || base.protocol === 'http:' && !['127.0.0.1','localhost','host.docker.internal','[::1]'].includes(base.hostname)) throw terminal('invalid_pool','接口地址无效');
  if (!Number.isSafeInteger(entry.context_window) || entry.context_window < 256 || entry.context_window > 2097152
    || !Number.isSafeInteger(entry.max_output_tokens) || entry.max_output_tokens < 1 || entry.max_output_tokens >= entry.context_window) throw terminal('invalid_pool','接口上下文限制无效');
  if (!entry.capabilities || !['chat_completions','responses','vision'].every(name => typeof entry.capabilities[name] === 'boolean')) throw terminal('invalid_pool','接口能力定义无效');
  if (entry.draft === true && entry.enabled) throw terminal('invalid_pool','待补凭据的接口不能启用');
  if (entry.draft === true && !entry.enabled && !secret?.api_key) secret = {api_key:'',custom_headers:{}};
  if (!secret || typeof secret.api_key !== 'string' || !secret.api_key && entry.draft !== true || secret.api_key.length > 16384 || /[\x00-\x1f\x7f]/.test(secret.api_key)) throw terminal('invalid_pool','接口秘密缺失或无效');
  const headers = parseHeaders(secret.custom_headers || {});
  const authScope = hash(base.origin + '\0' + secret.api_key + '\0' + JSON.stringify(Object.entries(headers).sort()));
  const entryIdentity = hash(entry.id + '\0' + entry.base_url + '\0' + entry.api_mode + '\0' + entry.model + '\0' + authScope);
  return {...entry, base:base.href.replace(/\/$/,''), model:entry.model, mode:entry.api_mode, key:secret.api_key, headers,
    authScope:'auth:' + authScope, modelScope:'model:' + hash(authScope + '\0' + entry.model), entryScope:'entry:' + entryIdentity, visionScope:'vision:' + entryIdentity};
}

function readJson(file, maximum = 16777216) {
  const stat = fs.lstatSync(file);
  if (!stat.isFile() || stat.isSymbolicLink() || stat.size > maximum) throw terminal('invalid_state','受管文件无效');
  return JSON.parse(fs.readFileSync(file,'utf8'));
}

function atomic(file, value) {
  const directory = path.dirname(file);
  fs.mkdirSync(directory,{recursive:true,mode:0o700});
  if (fs.lstatSync(directory).isSymbolicLink()) throw terminal('invalid_state','受管目录无效');
  const temporary = file + '.tmp-' + crypto.randomBytes(8).toString('hex');
  let descriptor;
  try {
    descriptor = fs.openSync(temporary,'wx',0o600);
    fs.writeFileSync(descriptor,JSON.stringify(value)); fs.fsyncSync(descriptor); fs.closeSync(descriptor); descriptor = undefined;
    fs.renameSync(temporary,file);
    const parent = fs.openSync(directory,'r'); try { fs.fsyncSync(parent); } finally { fs.closeSync(parent); }
  } finally {
    if (descriptor !== undefined) fs.closeSync(descriptor);
    try { fs.unlinkSync(temporary); } catch (_) {}
  }
}

function loadPool(environment = process.env) {
  const root = environment.PROVIDER_ROOT || '/opt/crisp-ai';
  const value = readJson(environment.PROVIDER_POOL_PATH || path.join(root,'config/provider-pool-applied.json'),1048576);
  if (value.schema_version !== 1 || !Number.isSafeInteger(value.revision) || value.revision < 1 || !/^[a-f0-9]{32}$/.test(value.secrets_generation || '')
    || !Array.isArray(value.entries) || !value.entries.length || value.entries.length > 21 || new Set(value.entries.map(entry => entry.id)).size !== value.entries.length) throw terminal('invalid_pool','主备池结构无效');
  const secretsRoot = environment.PROVIDER_SECRETS_DIR || path.join(root,'secrets/provider/generations');
  const secrets = readJson(path.join(secretsRoot,value.secrets_generation + '.json'),16777216);
  if (secrets.generation !== value.secrets_generation || secrets.revision !== value.revision || !secrets.entries) throw terminal('invalid_pool','主备池与秘密代次不一致');
  const entries = value.entries.map(entry => validateEntry(entry,secrets.entries[entry.id]));
  if (entries.filter(entry => entry.role === 'primary').length !== 1 || entries[0].id !== value.primary_id || entries[0].role !== 'primary' || !entries[0].enabled
    || entries.some((entry,index) => entry.order !== index || index > 0 && entry.role !== 'backup')) throw terminal('invalid_pool','主备池排序或主接口无效');
  return {...value, entries, policy:validatePolicy(value.policy)};
}

function retryAfterMilliseconds(value, now = Date.now()) {
  if (typeof value !== 'string' || !value.trim()) return 0;
  if (/^\d+(?:\.\d+)?$/.test(value.trim())) return Math.min(Number(value) * 1000,Number.MAX_SAFE_INTEGER - now);
  const time = Date.parse(value); return Number.isFinite(time) ? Math.max(0,time-now) : 0;
}

function classifyFailure(status, body, headers = {}) {
  const detail = body?.error || {};
  const code = String(detail.code || detail.type || '').toLowerCase();
  const category = String(detail.type || '').toLowerCase();
  const message = String(detail.message || '').toLowerCase();
  const retryAfter = retryAfterMilliseconds(typeof headers.get === 'function' ? headers.get('retry-after') : headers['retry-after']);
  if (/content_filter|content_policy|safety|moderation|policy_violation/.test(code + ' ' + category) || /safety system|content policy/.test(message)) return {kind:'safety_refusal',fallback:false,status:400};
  if (/model_not_found|invalid_model|model_not_exist|model_not_available/.test(code) || /model.*(?:does not exist|not found|not available)/.test(message)) return {kind:'model_unavailable',fallback:true,scope:'modelScope',retryAfter,status};
  if (status === 401 || status === 403 || /invalid_api_key|authentication_error|invalid_authentication/.test(code)) return {kind:'authentication_failed',fallback:true,scope:'authScope',retryAfter,status};
  if (status === 429 || /insufficient_quota|billing_hard_limit|quota_exceeded|billing_not_active|usage_limit|credit_balance_exhausted|spend_limit_exceeded/.test(code)) return {kind:/insufficient_quota|billing|quota_exceeded|usage_limit|credit_balance_exhausted|spend_limit_exceeded/.test(code) ? 'quota_exhausted' : 'rate_limited',fallback:true,scope:'authScope',retryAfter,status};
  if (status >= 500 || status === 408 || status === 409) return {kind:'upstream_unavailable',fallback:true,scope:'entryScope',retryAfter,status};
  // 仅接受明确模型能力错误；unsupported_image 的格式/坏数据含义仍是输入终态。
  const modelVisionUnsupported = /^(?:this|the(?: selected)?) model does not support (?:images?|image inputs?|vision)[.!]?$/.test(message.trim())
    || /^(?:image inputs?|images?|vision) (?:is|are) not supported by (?:this|the(?: selected)?) model[.!]?$/.test(message.trim());
  const explicitVisionCode = ['image_not_supported','unsupported_image','vision_not_supported','image_input_not_supported','unsupported_vision'].includes(code);
  if ([400,422].includes(status) && modelVisionUnsupported && (explicitVisionCode || code === 'invalid_request_error')) return {kind:'vision_unsupported',fallback:true,scope:'visionScope',retryAfter,status};
  if (/invalid_request_error|context_length_exceeded|invalid_argument/.test(code)) return {kind:'invalid_request',fallback:false,status:400};
  if (status >= 400 && status < 500) return {kind:'invalid_request',fallback:false,status};
  return {kind:'invalid_response',fallback:true,scope:'entryScope',retryAfter,status};
}

function createRouter(environment, invoke) {
  const root = environment.PROVIDER_ROOT || '/opt/crisp-ai';
  const directory = environment.PROVIDER_STATE_DIR || path.join(root,'data/provider-router');
  const stateFile = path.join(directory,'state.json');
  const boot = crypto.randomUUID();
  const inflight = new Map();
  let state;
  try { state = readJson(stateFile); } catch (error) {
    if (error.code !== 'ENOENT') throw error;
    state = {schema_version:1,health:{},recent:[],pool_until:0};
  }
  if (state.schema_version !== 1 || !state.health || !Array.isArray(state.recent)) throw terminal('invalid_state','路由状态无效');
  const save = () => atomic(stateFile,state);
  let loadedRevision;
  const currentPool = () => {
    const pool = loadPool(environment);
    if (loadedRevision !== pool.revision) {
      const active = new Set(pool.entries.flatMap(entry => [entry.authScope,entry.modelScope,entry.entryScope,entry.visionScope]));
      for (const key of Object.keys(state.health)) if (!active.has(key)) delete state.health[key];
      if (loadedRevision !== undefined) state.pool_until = 0;
      loadedRevision = pool.revision; save();
    }
    return pool;
  };
  const record = value => {
    state.recent.push(value); state.recent = state.recent.slice(-200); save();
  };
  const scopes = (entry, visual = false) => [entry.authScope,entry.modelScope,entry.entryScope,...(visual ? [entry.visionScope] : [])];
  const allowed = (entry, now, visual = false) => scopes(entry,visual).every(key => {
    const health = state.health[key];
    return !health || health.until <= now && (!health.lease || health.lease.until <= now);
  });
  const reserve = (entry, policy, now, visual = false) => {
    if (!allowed(entry,now,visual)) return false;
    for (const key of scopes(entry,visual)) {
      const health = state.health[key];
      if (health && health.failures > 0 && health.successes < 2) health.lease = {owner:boot,until:now + policy.call_timeout_ms + 1000};
    }
    save(); return true;
  };
  const release = (entry, visual = false) => {
    for (const key of scopes(entry,visual)) if (state.health[key]?.lease?.owner === boot) delete state.health[key].lease;
  };
  const success = (entry, visual = false) => {
    for (const key of scopes(entry,visual)) {
      const health = state.health[key] || {failures:0,successes:0,until:0};
      health.successes = Math.min(2,health.successes+1); health.until = 0; delete health.lease;
      if (health.successes >= 2) { health.failures = 0; health.last_error = ''; }
      state.health[key] = health;
    }
    state.pool_until = 0; save();
  };
  const fault = (entry, failure, policy, visual = false) => {
    release(entry,visual);
    const key = entry[failure.scope || 'entryScope'];
    const health = state.health[key] || {failures:0};
    health.failures += 1; health.successes = 0; health.last_error = failure.kind;
    health.until = Date.now() + Math.max(Math.min(policy.cooldown_max_ms,policy.cooldown_initial_ms * 2 ** Math.min(health.failures-1,20)),failure.retryAfter || 0);
    state.health[key] = health; save();
  };
  const assertCurrent = (envelope, revision, deadline) => {
    if (Date.now() >= deadline) throw terminal('question_timeout','本次问题的总处理时间已用尽');
    const current = loadPool(environment);
    if (current.revision !== revision) throw terminal('question_cancelled','接口配置已变更，本次问题已取消');
    if (!envelope) return;
    if (envelope.pool_revision !== revision) throw terminal('question_cancelled','接口配置已变更，本次问题已取消');
    let runtime;
    try {
      const projection = readJson(path.join(root,'config/materials-applied.json'));
      if (projection.state !== 'applied') throw terminal('question_cancelled','客服配置正在应用，本次问题已取消');
      runtime = projection.configuration?.runtime;
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
      runtime = readJson(path.join(root,'config/runtime.yaml'),1048576);
    }
    if (!runtime || runtime.enabled !== true && envelope.scope !== 'admin' || runtime.revision !== envelope.runtime_revision) throw terminal('question_cancelled','客服状态已变更，本次问题已取消');
    if (envelope.scope === 'admin') return;
    const session = readJson(path.join(root,'data/runtime/session-' + envelope.session_key + '.json'));
    if (session.schema_version !== 2 || session.mode !== 'ai' || session.generation !== envelope.generation || session.uncertain_events?.length
      || !Array.isArray(session.jobs) || !session.jobs.some(job => job.id === envelope.question_id && job.generation === envelope.generation && job.revision === envelope.runtime_revision && !['cancelled','failed','done'].includes(job.status))) throw terminal('question_cancelled','会话状态已变更，本次问题已取消');
  };
  const questionFile = id => path.join(directory,'questions',id + '.json');
  const readQuestion = id => { try { return readJson(questionFile(id),20000000); } catch (error) { if (error.code === 'ENOENT') return null; throw error; } };
  const storage = () => {
    const folder = path.join(directory,'questions');
    let files; try { files = fs.readdirSync(folder); } catch (error) { if (error.code === 'ENOENT') return {count:0,bytes:0}; throw error; }
    let count = 0, bytes = 0;
    for (const name of files) {
      if (!/^[a-f0-9]{64}\.json$/.test(name)) continue;
      const file = path.join(folder,name), info = fs.lstatSync(file);
      if (!info.isFile() || info.isSymbolicLink()) throw terminal('invalid_state','问题缓存文件无效');
      // 最长问题预算为3分钟；最后写入超过10分钟的记录不可能仍有合法活跃信封。
      if (info.mtimeMs < Date.now()-600000) { fs.unlinkSync(file); continue; }
      count++; bytes += info.size;
    }
    return {count,bytes};
  };
  const persistQuestion = question => {
    const target = questionFile(question.id), size = Buffer.byteLength(JSON.stringify(question));
    const used = storage(); let previous = 0; try { previous = fs.statSync(target).size; } catch (_) {}
    if (!previous && used.count >= 1024 || used.bytes-previous+size > 67108864) {
      for (const phase of Object.values(question.stages)) delete phase.result;
      question.terminal = {code:'question_cache_full',message:'问题处理缓存已满，请稍后再发起新问题'};
      if (previous) atomic(target,question);
      throw terminal(question.terminal.code,question.terminal.message);
    }
    atomic(target,question);
  };

  async function run(body, envelope, signal) {
    const pool = currentPool();
    if (envelope && Date.now() >= envelope.deadline_at) throw terminal('question_timeout','本次问题的总处理时间已用尽');
    const id = envelope?.question_id || hash(crypto.randomUUID());
    const stage = envelope?.stage || 'answer';
    const binding = hash(JSON.stringify(envelope ? [envelope.scope || 'conversation',envelope.session_key,envelope.generation,envelope.runtime_revision,envelope.pool_revision,envelope.deadline_at] : [pool.revision]));
    let question = readQuestion(id);
    if (question && question.binding !== binding) throw terminal('question_conflict','问题标识与原处理上下文不一致');
    if (!question) question = {id,binding,revision:pool.revision,deadline:Math.min(envelope?.deadline_at || Infinity,Date.now()+pool.policy.question_timeout_ms),attempts:0,stages:{},created_at:Date.now()};
    const check = () => { if (signal?.aborted) throw terminal('question_cancelled','本次问题已取消'); assertCurrent(envelope,pool.revision,question.deadline); };
    try { check(); } catch (error) { question.terminal = {code:error.code || 'question_cancelled',message:'本次问题已取消或到期'}; persistQuestion(question); throw error; }
    const existing = question.stages[stage];
    if (existing?.result) return existing.result;
    if (question.terminal) throw terminal(question.terminal.code,question.terminal.message);
    if (existing?.owner && existing.owner !== boot) {
      question.terminal = {code:'question_interrupted',message:'先前请求未获得确定结果，本次问题已终止'}; persistQuestion(question);
      throw terminal(question.terminal.code,question.terminal.message);
    }
    const phase = question.stages[stage] || {tried:[]};
    question.stages[stage] = phase; phase.owner = boot; persistQuestion(question);
    const visual = body.messages.some(message => Array.isArray(message.content) && message.content.some(part => part.type === 'image_url'));
    if (envelope && visual && stage !== 'vision') throw terminal('invalid_input','图片必须使用受管视觉阶段');
    // 近似估算而非模型专用 tokenizer；保留消息开销、256 token 余量与每图4096，不裁剪知识或图片。
    const inputTokens = 256 + body.messages.reduce((sum,message) => sum + 16 + (typeof message.content === 'string' ? estimateTextTokens(message.content) : message.content.reduce((total,part) => total + (part.type === 'image_url' ? 4096 : estimateTextTokens(part.text || '')),0)),0);
    let candidates = 0;
    try {
      if (state.pool_until > Date.now()) throw terminal('pool_cooling','接口池正在短暂保护期，请稍后再发起新问题');
      for (const entry of pool.entries) {
        check();
        if (question.attempts >= pool.policy.max_attempts) throw terminal('question_budget_exhausted','本次问题的调用次数已用尽');
        if (!entry.enabled || !entry.capabilities[entry.mode] || visual && !entry.capabilities.vision || phase.tried.includes(entry.id)) continue;
        const requestedOutput = Number(body.max_completion_tokens ?? body.max_tokens ?? body.max_output_tokens) || entry.max_output_tokens;
        const maxOutput = Math.min(entry.max_output_tokens,Math.max(1,requestedOutput));
        if (inputTokens + maxOutput > entry.context_window) continue;
        candidates += 1;
        if (!reserve(entry,pool.policy,Date.now(),visual)) continue;
        phase.tried.push(entry.id); question.attempts += 1; persistQuestion(question);
        const start = Date.now();
        const controller = new AbortController();
        let cancelError;
        const cancel = () => { cancelError = terminal('question_cancelled','本次问题已取消'); controller.abort(); };
        signal?.addEventListener('abort',cancel,{once:true});
        const monitor = setInterval(() => { try { check(); } catch (error) { cancelError = error; controller.abort(); } },100);
        try {
          const result = await invoke(body,{...entry,maxOutput,timeout:Math.min(pool.policy.call_timeout_ms,question.deadline-Date.now()),connectTimeout:pool.policy.connect_timeout_ms},controller.signal);
          check();
          if (cancelError) throw cancelError;
          success(entry,visual);
          phase.result = result; delete phase.owner;
          if (result.choices?.[0]?.message?.refusal || result.choices?.[0]?.finish_reason === 'content_filter') question.terminal = {code:'safety_refusal',message:'模型已拒绝该内容，本次问题已终止'};
          persistQuestion(question);
          record({at:Date.now(),question_id:id,stage,entry_id:entry.id,pool_revision:pool.revision,remaining_budget_ms:Math.max(0,question.deadline-Date.now()),outcome:result.choices?.[0]?.message?.refusal || result.choices?.[0]?.finish_reason === 'content_filter' ? 'refused':'success',attempt:question.attempts,duration_ms:Date.now()-start});
          return result;
        } catch (error) {
          if (!cancelError) { try { check(); } catch (currentError) { cancelError = currentError; } }
          if (cancelError || error.terminal || signal?.aborted) { release(entry,visual); save(); throw cancelError || error; }
          const failure = error.failure || {kind:error.name === 'AbortError' ? 'upstream_timeout':'connection_failed',fallback:true,scope:'entryScope',status:0};
          if (!failure.fallback || failure.scope === 'visionScope' && !visual) { release(entry,visual); save(); throw terminal(failure.kind === 'vision_unsupported' ? 'invalid_request' : failure.kind,failure.kind === 'safety_refusal' ? '模型拒绝处理该内容':'模型拒绝本次请求的输入格式'); }
          fault(entry,failure,pool.policy,visual);
          record({at:Date.now(),question_id:id,stage,entry_id:entry.id,pool_revision:pool.revision,remaining_budget_ms:Math.max(0,question.deadline-Date.now()),outcome:'failed',error_class:failure.kind,http_status:failure.status || 0,attempt:question.attempts,duration_ms:Date.now()-start});
        } finally { clearInterval(monitor); signal?.removeEventListener('abort',cancel); }
      }
      if (candidates && !pool.entries.some(entry => entry.enabled && allowed(entry,Date.now()))) { state.pool_until = Date.now() + pool.policy.pool_cooldown_ms; save(); }
      throw terminal(candidates ? 'pool_exhausted':'no_capable_provider',candidates ? '本次问题可用的接口已用尽':'没有满足协议、图片能力或上下文限制的可用接口');
    } catch (error) {
      question.terminal = {code:error.code || 'question_failed',message:error.terminal ? error.message:'本次问题处理已终止'};
      delete phase.owner; persistQuestion(question);
      if (error.terminal) throw error;
      throw terminal(question.terminal.code,question.terminal.message);
    }
  }

  const route = async (body,envelope,signal) => {
    const id = envelope?.question_id;
    const previous = id && inflight.get(id);
    const pending = (async () => { if (previous) { try { await previous; } catch (_) {} } return run(body,envelope,signal); })();
    if (id) inflight.set(id,pending);
    try { return await pending; } finally { if (id && inflight.get(id) === pending) inflight.delete(id); }
  };
  const status = () => {
    const pool = currentPool(), now = Date.now();
    return {ok:true,revision:pool.revision,pool_cooldown_until:state.pool_until,entries:pool.entries.map(entry => {
      const values = scopes(entry).map(key => state.health[key]).filter(Boolean);
      const until = Math.max(0,...values.map(value => value.until || 0));
      const visionValues = scopes(entry,true).map(key => state.health[key]).filter(Boolean);
      const visionUntil = Math.max(0,...visionValues.map(value => value.until || 0));
      return {id:entry.id,enabled:entry.enabled,health:!entry.enabled ? 'disabled' : until > now ? 'cooling' : values.some(value => value.lease?.until > now) ? 'half_open' : values.length && values.every(value => value.successes >= 2) ? 'healthy' : 'unknown',cooldown_until:until,last_error:values.find(value => value.last_error)?.last_error || '',
        vision_health:!entry.enabled || !entry.capabilities.vision ? 'disabled' : visionUntil > now ? 'cooling' : visionValues.some(value => value.lease?.until > now) ? 'half_open' : state.health[entry.visionScope] && visionValues.every(value => value.successes >= 2) ? 'healthy' : 'unknown',vision_cooldown_until:visionUntil,vision_last_error:visionValues.find(value => value.last_error)?.last_error || ''};
    })};
  };
  return {route,status,recent:() => ({ok:true,records:state.recent.slice().reverse()}),loadPool:currentPool,clearHealth:entry => { for (const key of scopes(entry,true)) delete state.health[key]; state.pool_until = 0; save(); }};
}

module.exports = {createRouter,loadPool,validateEntry,validatePolicy,parseHeaders,DEFAULT_POLICY,RouterError,terminal,classifyFailure,retryAfterMilliseconds,readJson,estimateTextTokens};
