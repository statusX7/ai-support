'use strict';

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const {mechanicalFailureAnswer,legacyGenericNonAnswer} = require('./visitor-output.js');

const DEFAULT_POLICY = Object.freeze({question_timeout_ms:90000, call_timeout_ms:20000, connect_timeout_ms:5000,
  max_attempts:21, cooldown_initial_ms:60000, cooldown_max_ms:300000, pool_cooldown_ms:3000});
const POLICY_BOUNDS = {question_timeout_ms:[1000,180000],call_timeout_ms:[1000,60000],connect_timeout_ms:[100,10000],
  max_attempts:[1,21],cooldown_initial_ms:[1000,300000],cooldown_max_ms:[1000,3600000],pool_cooldown_ms:[100,60000]};
const MAX_PRESSURE_RETIREMENT_CHECKS = 64;
const forbiddenHeaders = new Set(['authorization','host','connection','content-length','content-type','transfer-encoding','cookie','proxy-authorization','x-crispai-question']);
const hash = value => crypto.createHash('sha256').update(String(value)).digest('hex');
const canonical = value => Array.isArray(value) ? '[' + value.map(canonical).join(',') + ']'
  : value && typeof value === 'object' ? '{' + Object.keys(value).sort()
    .map(key => JSON.stringify(key) + ':' + canonical(value[key])).join(',') + '}'
    : JSON.stringify(value);
const requestContract = value => value?.request_contract_version === 1
  && /^[a-f0-9]{64}$/.test(value.request_sha256 || '')
  && /^[a-f0-9]{64}$/.test(value.plan_context_sha256 || '')
  ? {request_contract_version:1,request_sha256:value.request_sha256,
    plan_context_sha256:value.plan_context_sha256} : null;
const sameRequestContract = (left,right) => Boolean(left && right
  && left.request_contract_version === right.request_contract_version
  && left.request_sha256 === right.request_sha256
  && left.plan_context_sha256 === right.plan_context_sha256);
const validQuestionSettlement = (value,question) => Boolean(value
  && typeof value === 'object' && !Array.isArray(value)
  && Object.keys(value).sort().join(',') === [
    'outcome','plan_sha256','request_contract','response_generation','settled_at',
  ].sort().join(',')
  && value.outcome === 'plan_persisted'
  && /^[a-f0-9]{64}$/.test(value.plan_sha256 || '')
  && Number.isSafeInteger(value.response_generation) && value.response_generation >= 0
  && Number.isSafeInteger(value.settled_at) && value.settled_at >= 0
  && value.request_contract && typeof value.request_contract === 'object'
  && !Array.isArray(value.request_contract)
  && Object.keys(value.request_contract).sort().join(',') === [
    'plan_context_sha256','request_contract_version','request_sha256',
  ].sort().join(',')
  && requestContract(value.request_contract)
  && question?.stages?.answer
  && sameRequestContract(requestContract(question.stages.answer.request_contract),
    requestContract(value.request_contract)));

function cachedResultDisposition(result) {
  if (!result || typeof result !== 'object' || Array.isArray(result)) return 'invalid';
  const choice = result.choices?.[0], message = choice?.message;
  const refusal = typeof message?.refusal === 'string' && Boolean(message.refusal.trim());
  if (refusal || choice?.finish_reason === 'content_filter') return 'safety_refusal';
  if (!message || message.tool_calls || message.function_call
    || typeof message.content !== 'string' || !message.content.trim()) return 'invalid';
  return mechanicalFailureAnswer(message.content) || legacyGenericNonAnswer(message.content)
    ? 'non_answer' : 'answer';
}

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

function normalizeApiBase(value) {
  if (typeof value !== 'string' || !value || value.length > 4096 || value.includes('?') || value.includes('#') || /[\\\x00-\x20\x7f]/.test(value)) throw terminal('invalid_pool','接口地址无效');
  const normalized = value.replace(/\/+$/,'');
  let base;
  try { base = new URL(normalized); } catch (_) { throw terminal('invalid_pool','接口地址无效'); }
  if (!['https:','http:'].includes(base.protocol) || base.username || base.password || base.search || base.hash
    || base.protocol === 'http:' && !['127.0.0.1','localhost','host.docker.internal','[::1]'].includes(base.hostname)) throw terminal('invalid_pool','接口地址无效');
  const rawPath = /^[A-Za-z][A-Za-z0-9+.-]*:\/\/[^/]*(\/.*)?$/.exec(normalized)?.[1] || '';
  let decoded; try { decoded = decodeURIComponent(rawPath); } catch (_) { throw terminal('invalid_pool','接口地址无效'); }
  if (decoded.includes('\\') || decoded.split('/').some(part => part === '.' || part === '..')) throw terminal('invalid_pool','接口地址无效');
  let pathname = base.pathname.replace(/\/+$/,'');
  if (!pathname.endsWith('/v1')) pathname += '/v1';
  base.pathname = pathname;
  const result = base.href.replace(/\/$/,'');
  if (result.length > 4096) throw terminal('invalid_pool','接口地址无效');
  return result;
}

function validateEntry(entry, secret) {
  if (!entry || !/^p_[a-f0-9]{24}$/.test(entry.id || '') || typeof entry.enabled !== 'boolean'
    || !['chat_completions','responses'].includes(entry.api_mode) || !/^[A-Za-z0-9][A-Za-z0-9._:/+@-]{0,511}$/.test(entry.model || '')) throw terminal('invalid_pool','接口定义无效');
  const baseUrl = normalizeApiBase(entry.base_url), base = new URL(baseUrl);
  if (!Number.isSafeInteger(entry.context_window) || entry.context_window < 256 || entry.context_window > 2097152
    || !Number.isSafeInteger(entry.max_output_tokens) || entry.max_output_tokens < 1 || entry.max_output_tokens >= entry.context_window) throw terminal('invalid_pool','接口上下文限制无效');
  if (!entry.capabilities || !['chat_completions','responses','vision'].every(name => typeof entry.capabilities[name] === 'boolean')) throw terminal('invalid_pool','接口能力定义无效');
  if (entry.draft === true && entry.enabled) throw terminal('invalid_pool','待补凭据的接口不能启用');
  if (entry.draft === true && !entry.enabled && !secret?.api_key) secret = {api_key:'',custom_headers:{}};
  if (!secret || typeof secret.api_key !== 'string' || !secret.api_key && entry.draft !== true || secret.api_key.length > 16384 || /[\x00-\x1f\x7f]/.test(secret.api_key)) throw terminal('invalid_pool','接口秘密缺失或无效');
  const headers = parseHeaders(secret.custom_headers || {});
  const authScope = hash(base.origin + '\0' + secret.api_key + '\0' + JSON.stringify(Object.entries(headers).sort()));
  const entryIdentity = hash(entry.id + '\0' + baseUrl + '\0' + entry.api_mode + '\0' + entry.model + '\0' + authScope);
  return {...entry, base_url:baseUrl, base:base.href.replace(/\/$/,''), model:entry.model, mode:entry.api_mode, key:secret.api_key, headers,
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
  const poolPath = environment.PROVIDER_POOL_PATH || path.join(root,'config/provider-pool-applied.json');
  const poolStat = fs.lstatSync(poolPath);
  if (!poolStat.isFile() || poolStat.isSymbolicLink() || poolStat.size < 1 || poolStat.size > 1048576) throw terminal('invalid_pool','主备池结构无效');
  const poolRaw = fs.readFileSync(poolPath,'utf8');
  const value = JSON.parse(poolRaw);
  if (value.schema_version !== 1 || !Number.isSafeInteger(value.revision) || value.revision < 1 || !/^[a-f0-9]{32}$/.test(value.secrets_generation || '')
    || !Array.isArray(value.entries) || !value.entries.length || value.entries.length > 21 || new Set(value.entries.map(entry => entry.id)).size !== value.entries.length) throw terminal('invalid_pool','主备池结构无效');
  const secretsRoot = environment.PROVIDER_SECRETS_DIR || path.join(root,'secrets/provider/generations');
  const secrets = readJson(path.join(secretsRoot,value.secrets_generation + '.json'),16777216);
  if (secrets.generation !== value.secrets_generation || secrets.revision !== value.revision || !secrets.entries) throw terminal('invalid_pool','主备池与秘密代次不一致');
  const entries = value.entries.map(entry => validateEntry(entry,secrets.entries[entry.id]));
  if (entries.filter(entry => entry.role === 'primary').length !== 1 || entries[0].id !== value.primary_id || entries[0].role !== 'primary' || !entries[0].enabled
    || entries.some((entry,index) => entry.order !== index || index > 0 && entry.role !== 'backup')) throw terminal('invalid_pool','主备池排序或主接口无效');
  return {...value, entries, policy:validatePolicy(value.policy),applied_sha256:hash(poolRaw)};
}

function retryAfterMilliseconds(value, now = Date.now()) {
  if (typeof value !== 'string' || !value.trim()) return 0;
  if (/^\d+(?:\.\d+)?$/.test(value.trim())) return Math.min(Number(value) * 1000,Number.MAX_SAFE_INTEGER - now);
  const time = Date.parse(value); return Number.isFinite(time) ? Math.max(0,time-now) : 0;
}

function cooldownMilliseconds(policy, failures, retryAfter = 0, randomFraction = Math.random()) {
  const base = Math.min(policy.cooldown_max_ms,policy.cooldown_initial_ms * 2 ** Math.min(failures-1,20));
  // 只增加0～5%，普通退避受上限约束；Retry-After独立取最大值，绝不截短。
  const jitter = Math.floor(base * 0.05 * Math.max(0,Math.min(1,randomFraction)));
  return Math.max(Math.min(policy.cooldown_max_ms,base+jitter),retryAfter || 0);
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
  // 没有可识别模型错误结构的 404 表示当前接口路径/协议端点不可用，而不是客户输入错误。
  // 仅冷却这个独立接口并允许备用继续；明确的 model_not_found 已在上方按模型范围隔离。
  if (status === 404) return {kind:'protocol_error',fallback:true,scope:'entryScope',retryAfter,status};
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
  const stateLockPath = path.join(directory,'.state.lock');
  const boot = crypto.randomUUID();
  const inflight = new Map();
  const pause = milliseconds => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)),0,0,milliseconds);
  const processIdentity = (pid = process.pid) => {
    try {
      const value = fs.readFileSync('/proc/' + pid + '/stat','utf8');
      const end = value.lastIndexOf(') ');
      if (end < 1) return null;
      const fields = value.slice(end+2).trim().split(/\s+/);
      return {pid:Number(value.slice(0,value.indexOf(' '))),started:fields[19]};
    } catch (_) { return null; }
  };
  const selfIdentity = processIdentity();
  if (!selfIdentity) throw terminal('invalid_state','无法建立路由锁进程身份');
  const freshState = () => {
    let value;
    try { value = readJson(stateFile); } catch (error) {
      if (error.code !== 'ENOENT') throw error;
      value = {schema_version:1,state_revision:0,health:{},recent:[],pool_until:0};
    }
    if (value.schema_version !== 1 || !value.health || typeof value.health !== 'object'
      || Array.isArray(value.health) || !Array.isArray(value.recent)
      || value.state_revision !== undefined && (!Number.isSafeInteger(value.state_revision) || value.state_revision < 0)) {
      throw terminal('invalid_state','路由状态无效');
    }
    value.state_revision = value.state_revision || 0;
    value.pool_until = Number.isFinite(value.pool_until) ? value.pool_until : 0;
    value.retirement_cursor = /^[a-f0-9]{64}\.json$/.test(value.retirement_cursor || '')
      ? value.retirement_cursor : '';
    return value;
  };
  let state = freshState();
  const lockOwner = lockPath => {
    try { return readJson(path.join(lockPath,'owner.json'),4096); } catch (_) { return null; }
  };
  const ownerStatus = owner => {
    if (!owner || !Number.isSafeInteger(owner.pid) || owner.pid < 1
      || typeof owner.started !== 'string' || !owner.started) return 'invalid';
    const current = processIdentity(owner.pid);
    if (current) return current.pid === owner.pid && current.started === owner.started ? 'alive' : 'dead';
    // /proc 的读取若被宿主限制，不能把“未知”当作进程已死后抢锁。
    return fs.existsSync('/proc/' + owner.pid) ? 'unknown' : 'dead';
  };
  const lockOldEnoughToRecover = lockPath => {
    try { return fs.lstatSync(lockPath).mtimeMs < Date.now()-5000; }
    catch (error) { if (error.code === 'ENOENT') return true; throw error; }
  };
  const recoverableLock = lockPath => {
    const status = ownerStatus(lockOwner(lockPath));
    return status === 'dead' || status === 'invalid' && lockOldEnoughToRecover(lockPath);
  };
  const publishLock = (lockPath,token) => {
    // 不能用 rename(claimDir, lockPath) 充当 no-replace：POSIX 允许源目录
    // 替换一个已存在的空目录。释放者删除 owner.json 到 rmdir 之间恰有
    // 这样一个短窗口，会让旧 owner 误删或覆盖新锁。mkdir 本身才是这里
    // 所需的原子“仅当不存在时创建”；进程若在 owner 落盘前退出，则由
    // 既有的无 owner 五秒保守恢复规则处理。
    try { fs.mkdirSync(lockPath,{mode:0o700}); }
    catch (error) {
      if (error.code === 'EEXIST') return false;
      throw error;
    }
    try {
      atomic(path.join(lockPath,'owner.json'),{schema_version:1,token,boot,
        pid:selfIdentity?.pid || process.pid,started:selfIdentity?.started || '',acquired_at:Date.now()});
      const parent = fs.openSync(path.dirname(lockPath),'r');
      try { fs.fsyncSync(parent); } finally { fs.closeSync(parent); }
      return true;
    } catch (error) {
      try { fs.unlinkSync(path.join(lockPath,'owner.json')); } catch (_) {}
      try { fs.rmdirSync(lockPath); } catch (_) {}
      throw error;
    }
  };
  const discardLock = lockPath => {
    let info;
    try { info = fs.lstatSync(lockPath); }
    catch (error) { if (error.code === 'ENOENT') return false; throw error; }
    if (!info.isDirectory() || info.isSymbolicLink()) throw terminal('invalid_state','受管锁路径无效');
    const quarantine = lockPath + '.stale-' + crypto.randomBytes(8).toString('hex');
    try { fs.renameSync(lockPath,quarantine); }
    catch (error) { if (['ENOENT','ENOTEMPTY','EEXIST'].includes(error.code)) return false; throw error; }
    try { fs.unlinkSync(path.join(quarantine,'owner.json')); } catch (_) {}
    try { fs.rmdirSync(quarantine); } catch (_) {}
    return true;
  };
  const acquireSyncLock = lockPath => {
    fs.mkdirSync(path.dirname(lockPath),{recursive:true,mode:0o700});
    const token = crypto.randomBytes(24).toString('hex');
    for (let attempt=0;attempt<200;attempt+=1) {
      try {
        if (!publishLock(lockPath,token)) throw Object.assign(new Error('lock exists'),{code:'EEXIST'});
        return {path:lockPath,token};
      } catch (error) {
        if (error.code !== 'EEXIST') throw error;
        if (recoverableLock(lockPath)) { discardLock(lockPath); continue; }
        pause(5);
      }
    }
    throw terminal('state_busy','路由状态正忙，请稍后重试');
  };
  const lockCurrent = lock => {
    const owner = lockOwner(lock.path);
    return Boolean(owner && owner.token === lock.token && owner.boot === boot);
  };
  const releaseSyncLock = lock => {
    if (!lockCurrent(lock)) return;
    try { fs.unlinkSync(path.join(lock.path,'owner.json')); } catch (_) {}
    try { fs.rmdirSync(lock.path); } catch (_) {}
  };
  const mutateState = action => {
    const lock = acquireSyncLock(stateLockPath);
    try {
      const current = freshState();
      const result = action(current);
      current.state_revision += 1;
      atomic(stateFile,current);
      state = current;
      return result;
    } finally { releaseSyncLock(lock); }
  };
  const refreshState = () => { state = freshState(); return state; };
  let loadedPoolBinding;
  const currentPool = () => {
    const pool = loadPool(environment);
    const poolBinding = pool.revision + ':' + pool.secrets_generation + ':' + pool.applied_sha256;
    if (loadedPoolBinding !== poolBinding) {
      const active = new Set(pool.entries.flatMap(entry => [entry.authScope,entry.modelScope,entry.entryScope,entry.visionScope]));
      mutateState(current => {
        for (const key of Object.keys(current.health)) if (!active.has(key)) delete current.health[key];
        if (loadedPoolBinding !== undefined) current.pool_until = 0;
      });
      loadedPoolBinding = poolBinding;
    }
    return pool;
  };
  const record = value => mutateState(current => {
    current.recent.push(value); current.recent = current.recent.slice(-200);
  });
  // 健康与近期切换记录是运维证据，不能反向决定一个已经持久化的业务结果
  // 是否存在。它们写入失败时保留问题缓存作为唯一事实来源。
  const bestEffortState = action => { try { return action(); } catch (_) { return undefined; } };
  const scopes = (entry, visual = false) => [entry.authScope,entry.modelScope,entry.entryScope,...(visual ? [entry.visionScope] : [])];
  const allowedIn = (current, entry, now, visual = false) => scopes(entry,visual).every(key => {
    const health = current.health[key];
    return !health || health.until <= now && (!health.lease || health.lease.until <= now);
  });
  const allowed = (entry, now, visual = false) => allowedIn(refreshState(),entry,now,visual);
  const reserve = (entry, policy, now, visual = false) => {
    return mutateState(current => {
      if (!allowedIn(current,entry,now,visual)) return false;
      for (const key of scopes(entry,visual)) {
        const health = current.health[key];
        if (health && health.failures > 0 && health.successes < 2) {
          health.lease = {owner:boot,until:now + policy.call_timeout_ms + 1000};
        }
      }
      return true;
    });
  };
  const release = (entry, visual = false) => mutateState(current => {
    for (const key of scopes(entry,visual)) if (current.health[key]?.lease?.owner === boot) delete current.health[key].lease;
  });
  const success = (entry, visual = false) => mutateState(current => {
    for (const key of scopes(entry,visual)) {
      const health = current.health[key] || {failures:0,successes:0,until:0};
      health.successes = Math.min(2,health.successes+1); health.until = 0; delete health.lease;
      if (health.successes >= 2) { health.failures = 0; health.last_error = ''; }
      current.health[key] = health;
    }
    current.pool_until = 0;
  });
  const fault = (entry, failure, policy, visual = false) => mutateState(current => {
    for (const key of scopes(entry,visual)) if (current.health[key]?.lease?.owner === boot) delete current.health[key].lease;
    const key = entry[failure.scope || 'entryScope'];
    const health = current.health[key] || {failures:0};
    health.failures += 1; health.successes = 0; health.last_error = failure.kind;
    health.until = Date.now() + cooldownMilliseconds(policy,health.failures,failure.retryAfter);
    current.health[key] = health;
  });
  const configurationTuple = (runtimeRevision,poolRevision,secretsGeneration,poolSha256='',materialsSourceSha256='') => ({
    runtime_revision:runtimeRevision,pool_revision:poolRevision,secrets_generation:secretsGeneration,
    pool_sha256:poolSha256,materials_source_sha256:materialsSourceSha256,
  });
  const sameConfiguration = (left,right) => Boolean(left && right
    && left.runtime_revision === right.runtime_revision && left.pool_revision === right.pool_revision
    && left.secrets_generation === right.secrets_generation
    && String(left.pool_sha256 || '') === String(right.pool_sha256 || '')
    && String(left.materials_source_sha256 || '') === String(right.materials_source_sha256 || ''));
  const assertCurrent = (envelope, pool, deadline, options = {}) => {
    if (options.ignoreDeadline !== true && Date.now() >= deadline) throw terminal('question_timeout','本次问题的总处理时间已用尽');
    const current = loadPool(environment);
    if (current.revision !== pool.revision || current.secrets_generation !== pool.secrets_generation) throw terminal('question_cancelled','接口配置已变更，本次问题已取消');
    if (!envelope) return;
    if (envelope.pool_revision !== pool.revision || envelope.secrets_generation !== undefined
      && envelope.secrets_generation !== pool.secrets_generation) throw terminal('question_cancelled','接口配置已变更，本次问题已取消');
    let runtime, materialsSourceSha256 = '';
    try {
      const projection = readJson(path.join(root,'config/materials-applied.json'));
      if (projection.state !== 'applied') throw terminal('question_cancelled','客服配置正在应用，本次问题已取消');
      runtime = projection.configuration?.runtime;
      materialsSourceSha256 = String(projection.source_sha256 || '');
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
      runtime = readJson(path.join(root,'config/runtime.yaml'),1048576);
    }
    if (!runtime || runtime.enabled !== true && envelope.scope !== 'admin' || runtime.revision !== envelope.runtime_revision) throw terminal('question_cancelled','客服状态已变更，本次问题已取消');
    if (envelope.pool_sha256 !== undefined && envelope.pool_sha256 !== pool.applied_sha256
      || envelope.materials_source_sha256 !== undefined
        && envelope.materials_source_sha256 !== materialsSourceSha256) throw terminal('question_cancelled','应用配置身份已变更，本次问题已取消');
    if (envelope.scope === 'admin') {
      if (envelope.migration_from) throw terminal('invalid_envelope','管理员问题不能携带配置迁移凭证');
      return;
    }
    const session = readJson(path.join(root,'data/runtime/session-' + envelope.session_key + '.json'));
    const currentConfiguration = configurationTuple(envelope.runtime_revision,envelope.pool_revision,
      envelope.secrets_generation || pool.secrets_generation,envelope.pool_sha256 || pool.applied_sha256,
      envelope.materials_source_sha256 || materialsSourceSha256);
    const currentConfigurationBinding = configurationBinding(currentConfiguration);
    if (envelope.configuration_binding !== undefined
      && envelope.configuration_binding !== currentConfigurationBinding) {
      throw terminal('question_cancelled','应用配置身份已变更，本次问题已取消');
    }
    const expectedMigration = envelope.migration_from;
    if (session.schema_version !== 2 || session.mode !== 'ai' || session.generation !== envelope.generation || session.uncertain_events?.length
      || !Array.isArray(session.jobs) || !session.jobs.some(job => {
        const inference = job.inference || {};
        const strictBinding = envelope.secrets_generation !== undefined
          || envelope.pool_sha256 !== undefined || envelope.materials_source_sha256 !== undefined
          || envelope.configuration_binding !== undefined;
        if (job.id !== envelope.question_id || job.generation !== envelope.generation
          || job.revision !== envelope.runtime_revision || inference.attempt_generation !== envelope.attempt_generation
          || inference.pool_revision !== envelope.pool_revision
          || strictBinding && (inference.runtime_revision !== currentConfiguration.runtime_revision
            || inference.secrets_generation !== currentConfiguration.secrets_generation
            || inference.pool_sha256 !== currentConfiguration.pool_sha256
            || inference.materials_source_sha256 !== currentConfiguration.materials_source_sha256
            || inference.configuration_binding !== currentConfigurationBinding)
          || !strictBinding && inference.secrets_generation !== undefined
            && inference.secrets_generation !== currentConfiguration.secrets_generation
          || ['cancelled','failed','done'].includes(job.status)) return false;
        if (!expectedMigration) return !job.provider_migration_from;
        return sameConfiguration(job.provider_migration_from,expectedMigration)
          && job.provider_migration_from.attempt_generation === expectedMigration.attempt_generation;
      })) throw terminal('question_cancelled','会话状态已变更，本次问题已取消');
  };
  const questionFile = id => path.join(directory,'questions',id + '.json');
  const readQuestion = id => { try { return readJson(questionFile(id),20000000); } catch (error) { if (error.code === 'ENOENT') return null; throw error; } };
  const questionLockPath = id => path.join(directory,'questions','.locks',id + '.lock');
  const authorizedSession = sessionKey => {
    let session;
    try { session = readJson(path.join(root,'data/runtime/session-' + sessionKey + '.json'),2097152); }
    catch (_) { return null; }
    if (session?.schema_version !== 2 || typeof session.website_id !== 'string'
      || !session.website_id || typeof session.session_id !== 'string' || !session.session_id
      || hash(session.website_id + '\0' + session.session_id) !== sessionKey
      || !Number.isSafeInteger(session.generation) || session.generation < 0
      || !Array.isArray(session.jobs)) return null;
    return session;
  };
  const safelyTerminalResponsibility = job => {
    if (!job || Object.prototype.hasOwnProperty.call(job,'provider_retirement')
      || Object.prototype.hasOwnProperty.call(job,'provider_retirement_failure_code')
      || Object.prototype.hasOwnProperty.call(job,'provider_settlement')
      || Object.prototype.hasOwnProperty.call(job,'provider_result_receipt')) return false;
    if (job.status === 'done') {
      return !job.failure_code
        && ['answered_confirmed','clarification_confirmed','control_handled']
          .includes(job.responsibility_status);
    }
    return job.status === 'cancelled' && job.responsibility_status === 'intentional_silence'
      && ['human_reply','human_handoff','conversation_state_changed','global_disabled']
        .includes(job.responsibility_reason);
  };
  const responsibilityRetired = question => {
    if (question?.schema_version !== 2 || question.scope !== 'conversation'
      || !/^[a-f0-9]{64}$/.test(question.id || '')
      || !/^[a-f0-9]{64}$/.test(question.session_key || '')
      || !Number.isSafeInteger(question.conversation_generation)
      || question.conversation_generation < 0
      || question.responsibility_binding !== hash(JSON.stringify([
        question.id,'conversation',question.session_key,question.conversation_generation,
      ]))) return false;
    const session = authorizedSession(question.session_key);
    if (!session) return false;
    const job = session.jobs.find(value => value?.id === question.id);
    // 会话代次已推进不能证明某个缺失 job 已经安全终结。
    // job 可能因旧版容量截断或损坏而消失；此时应保留 Provider
    // 结果并报警，绝不能为释放压力把未知责任当成已回答。
    if (!job) return false;
    return job.generation === question.conversation_generation
      && safelyTerminalResponsibility(job);
  };
  const retirementAuthorized = (question,envelope,purpose) => {
    if (question?.scope !== 'conversation') return false;
    const session = authorizedSession(question.session_key);
    const job = session?.jobs.find(value => value?.id === question.id
      && value.generation === question.conversation_generation);
    const record = job?.provider_retirement;
    if (!record || typeof record !== 'object' || Array.isArray(record)
      || record.schema_version !== 1 || !['pending','deferred'].includes(record.state)
      || record.purpose !== purpose || !record.envelope
      || canonical(record.envelope) !== canonical(envelope)
      || record.identity_sha256 !== hash(canonical({envelope:record.envelope,purpose}))) return false;
    if (purpose === 'conversation_cancelled') {
      return job.status === 'cancelled' && job.responsibility_status === 'intentional_silence'
        && ['human_reply','human_handoff','conversation_state_changed']
          .includes(job.responsibility_reason);
    }
    if (purpose === 'global_disabled') {
      return job.status === 'cancelled' && job.responsibility_status === 'intentional_silence'
        && job.responsibility_reason === 'global_disabled';
    }
    if (purpose === 'input_retired') {
      return ['done','cancelled','failed'].includes(job.status)
        && ['intentional_silence','control_handled'].includes(job.responsibility_status)
        && ['non_visitor_message','before_catchup_bootstrap','before_control_watermark']
          .includes(job.responsibility_reason);
    }
    return purpose === 'non_answer_retired'
      && ['received','failed'].includes(job.status)
      && job.responsibility_status === 'unresolved_failure';
  };
  const legacyV121CleanupEnvelope = envelope => Boolean(envelope
    && envelope.version === 1 && envelope.legacy_v121_cleanup === true
    && envelope.scope === 'conversation'
    && /^[a-f0-9]{64}$/.test(envelope.question_id || '')
    && /^[a-f0-9]{64}$/.test(envelope.session_key || '')
    && Number.isSafeInteger(envelope.generation) && envelope.generation >= 0
    && Number.isSafeInteger(envelope.runtime_revision) && envelope.runtime_revision >= 0
    && Number.isSafeInteger(envelope.pool_revision) && envelope.pool_revision >= 1
    && Number.isSafeInteger(envelope.deadline_at) && envelope.deadline_at >= 0
    && envelope.stage === 'answer' && envelope.attempt_generation === 1
    && Object.keys(envelope).sort().join(',') === [
      'attempt_generation','deadline_at','generation','legacy_v121_cleanup','pool_revision',
      'question_id','runtime_revision','scope','session_key','stage','version',
    ].sort().join(','));
  const legacyV121RetirementAuthorized = (envelope,purpose) => {
    if (!legacyV121CleanupEnvelope(envelope)) return false;
    const session = authorizedSession(envelope.session_key);
    const job = session?.jobs.find(value => value?.id === envelope.question_id
      && value.generation === envelope.generation);
    const record = job?.provider_retirement;
    if (!record || typeof record !== 'object' || Array.isArray(record)
      || record.schema_version !== 1 || !['pending','deferred'].includes(record.state)
      || record.purpose !== purpose || !record.envelope
      || canonical(record.envelope) !== canonical(envelope)
      || record.identity_sha256 !== hash(canonical({envelope:record.envelope,purpose}))) return false;
    return retirementAuthorized({scope:'conversation',session_key:envelope.session_key,
      id:envelope.question_id,conversation_generation:envelope.generation},envelope,purpose);
  };
  const acquireQuestionLock = async (id,signal,deadline=Date.now()+180000) => {
    const lockPath = questionLockPath(id), token = crypto.randomBytes(24).toString('hex');
    fs.mkdirSync(path.dirname(lockPath),{recursive:true,mode:0o700});
    for (;;) {
      if (signal?.aborted) throw terminal('question_cancelled','本次问题已取消');
      if (Date.now() >= deadline) throw terminal('question_timeout','本次问题的总处理时间已用尽');
      try {
        if (!publishLock(lockPath,token)) throw Object.assign(new Error('lock exists'),{code:'EEXIST'});
        const ownerPath = path.join(lockPath,'owner.json');
        let descriptor;
        try { descriptor = fs.openSync(ownerPath,'r+'); }
        catch (error) {
          const owned = {path:lockPath,token};
          if (lockCurrent(owned)) {
            try { fs.unlinkSync(ownerPath); } catch (_) {}
            try { fs.rmdirSync(lockPath); } catch (_) {}
          }
          throw error;
        }
        const lock = {path:lockPath,ownerPath,token,descriptor,recordRevision:0};
        lock.heartbeat = setInterval(() => {
          try {
            if (!lockCurrent(lock)) return;
            const now = new Date(); fs.futimesSync(descriptor,now,now);
          } catch (_) {}
        },1000);
        lock.heartbeat.unref?.();
        return lock;
      } catch (error) {
        if (error.code !== 'EEXIST') throw error;
        if (recoverableLock(lockPath)) {
          if (discardLock(lockPath)) await new Promise(resolve => setTimeout(resolve,25));
          continue;
        }
        await new Promise(resolve => setTimeout(resolve,20));
      }
    }
  };
  const releaseQuestionLock = lock => {
    clearInterval(lock?.heartbeat);
    try { if (lock?.descriptor !== undefined) fs.closeSync(lock.descriptor); } catch (_) {}
    if (!lock || !lockCurrent(lock)) return;
    try { fs.unlinkSync(lock.ownerPath); } catch (_) {}
    try { fs.rmdirSync(lock.path); } catch (_) {}
  };
  const storage = (pressure = false, prune = true) => {
    const folder = path.join(directory,'questions');
    let files; try { files = fs.readdirSync(folder); } catch (error) { if (error.code === 'ENOENT') return {count:0,bytes:0,settled:0,unsettled:0,retired:0,legacy:0}; throw error; }
    const records = [];
    for (const name of files) {
      if (!/^[a-f0-9]{64}\.json$/.test(name)) continue;
      const file = path.join(folder,name), info = fs.lstatSync(file);
      if (!info.isFile() || info.isSymbolicLink()) throw terminal('invalid_state','问题缓存文件无效');
      let value;
      try { value = readJson(file,20000000); } catch (error) { throw terminal('invalid_state','问题缓存文件无效'); }
      records.push({name,file,info,value});
    }
    if (pressure) records.sort((left,right) => left.info.mtimeMs-right.info.mtimeMs
      || left.name.localeCompare(right.name));
    let count = 0, bytes = 0, settled = 0, unsettled = 0, retired = 0, legacy = 0;
    let retirementNames = null;
    if (pressure) {
      const candidates = records.filter(record => record.value.schema_version === 2);
      if (candidates.length) {
        const cursor = refreshState().retirement_cursor;
        const found = candidates.findIndex(record => record.name === cursor);
        const start = found < 0 || found + 1 >= candidates.length ? 0 : found + 1;
        const selected = [];
        for (let offset=0;offset<Math.min(MAX_PRESSURE_RETIREMENT_CHECKS,candidates.length);offset+=1) {
          selected.push(candidates[(start+offset)%candidates.length]);
        }
        retirementNames = new Set(selected.map(record => record.name));
        const nextCursor = selected.at(-1)?.name || '';
        // 单次请求最多反查64个会话，但游标跨请求持久推进。前一批不可回收
        // 时，后续安全终态仍会被扫描到，不会永久卡在相同的前64项。
        bestEffortState(() => mutateState(current => { current.retirement_cursor = nextCursor; }));
      } else retirementNames = new Set();
    }
    let retirementScanned = 0;
    for (const {name,file,info,value} of records) {
      const activeLock = fs.existsSync(questionLockPath(name.slice(0,-5)));
      const adminExpired = value.schema_version === 2 && value.scope === 'admin'
        && !value.settlement && info.mtimeMs < Date.now()-600000;
      // 只有由 settle 事务写出的完整终态才可按保留期回收。损坏或半写入的
      // truthy 对象仍代表未知责任，宁可占用容量并报警，也不能静默删除。
      const settledExpired = value.schema_version === 2
        && validQuestionSettlement(value.settlement,value)
        && info.mtimeMs < Date.now()-(pressure ? 600000 : 604800000);
      // 真人接管、总关或任务终结后，runtime 会先以会话状态持久取消责任。
      // router 只在该权威状态、问题责任绑定和本地缓存身份完全一致时回收；
      // 正常路径留十分钟观察，容量压力时可立即释放，避免取消竞态永久占满1024项。
      // 普通推理持久化不能为了统计旧退休项而逐问题再读取一遍 session；
      // 否则缓存接近上限时每个请求都会产生 O(N) 额外会话 I/O。只在显式
      // status（prune=false）或容量压力扫描时核对反向责任。
      const inspectRetirement = value.schema_version === 2
        && (!prune || pressure && retirementNames.has(name));
      if (inspectRetirement) retirementScanned += 1;
      const responsibilityIsRetired = inspectRetirement && responsibilityRetired(value);
      const retiredExpired = responsibilityIsRetired
        && info.mtimeMs < Date.now()-(pressure ? 0 : 600000);
      if (prune && !activeLock && (adminExpired || settledExpired || retiredExpired)) { fs.unlinkSync(file); continue; }
      count++; bytes += info.size;
      if (value.schema_version !== 2) legacy += 1;
      else if (validQuestionSettlement(value.settlement,value)) settled += 1;
      else if (responsibilityIsRetired) retired += 1;
      else unsettled += 1;
    }
    return {count,bytes,settled,unsettled,retired,legacy,retirement_scanned:retirementScanned,
      retirement_scan_limited:pressure && records.filter(record => record.value.schema_version === 2).length
        > retirementScanned};
  };
  const persistQuestion = (question,lock) => {
    if (!lockCurrent(lock)) throw terminal('question_owner_changed','问题处理所有权已变化');
    const target = questionFile(question.id);
    let disk = null, previous = 0;
    try { disk = readQuestion(question.id); previous = fs.statSync(target).size; } catch (error) { if (error.code !== 'ENOENT') throw error; }
    const diskRevision = Number.isSafeInteger(disk?.record_revision) ? disk.record_revision : 0;
    if (diskRevision !== lock.recordRevision) throw terminal('question_owner_changed','问题处理记录已由新的执行者接管');
    question.schema_version = 2;
    question.record_revision = diskRevision + 1;
    question.updated_at = Date.now();
    const size = Buffer.byteLength(JSON.stringify(question));
    if (size > 20000000) throw terminal('question_cache_full','问题处理记录超过安全限制');
    let used = storage();
    if (!previous && used.count >= 1024 || used.bytes-previous+size > 67108864) {
      used = storage(true);
    }
    if (!previous && used.count >= 1024 || used.bytes-previous+size > 67108864) {
      question.record_revision = diskRevision;
      throw terminal('question_cache_full','问题处理缓存已达容量上限');
    }
    atomic(target,question);
    lock.recordRevision = question.record_revision;
  };

  const envelopeConfiguration = (envelope,pool) => configurationTuple(envelope?.runtime_revision ?? 0,
    envelope?.pool_revision ?? pool.revision,envelope?.secrets_generation || pool.secrets_generation,
    envelope?.pool_sha256 || pool.applied_sha256,envelope?.materials_source_sha256 || '');
  const legacyIdentityParts = (envelope,configuration,pool) => envelope
    ? [envelope.scope || 'conversation',envelope.session_key,envelope.generation,
      configuration.runtime_revision,configuration.pool_revision] : [pool.revision];
  const responsibilityBinding = (id,envelope) => hash(JSON.stringify([id,envelope?.scope || 'admin',
    envelope?.session_key || '',envelope?.generation ?? 0]));
  const configurationBinding = value => hash(JSON.stringify([value.runtime_revision,value.pool_revision,
    value.secrets_generation,value.pool_sha256 || '',value.materials_source_sha256 || '']));
  const executionBinding = (responsibility,configuration,generation) => hash(JSON.stringify([
    responsibility,configurationBinding(configuration),generation]));
  const legacyBindings = (envelope,configuration,pool,generation) => {
    const parts = legacyIdentityParts(envelope,configuration,pool);
    return {identity:hash(JSON.stringify(parts)),binding:hash(JSON.stringify([...parts,generation]))};
  };
  const legacyV121Binding = (envelope) => envelope?.legacy_v121_origin
    ? hash(JSON.stringify([envelope.scope || 'conversation',envelope.session_key,envelope.generation,
      envelope.legacy_v121_origin.runtime_revision,envelope.legacy_v121_origin.pool_revision,
      envelope.legacy_v121_origin.deadline_at])) : '';
  const legacyV121CleanupBinding = envelope => legacyV121CleanupEnvelope(envelope)
    ? hash(JSON.stringify(['conversation',envelope.session_key,envelope.generation,
      envelope.runtime_revision,envelope.pool_revision,envelope.deadline_at])) : '';
  const legacyV121QuestionMatchesCleanup = (question,envelope) => Boolean(question
    && question.schema_version === undefined && question.id === envelope.question_id
    && question.configuration_binding === undefined && question.execution_binding === undefined
    && question.responsibility_binding === undefined && question.identity_binding === undefined
    && question.binding === legacyV121CleanupBinding(envelope)
    && question.revision === envelope.pool_revision
    && question.deadline === envelope.deadline_at
    && Number.isSafeInteger(question.attempts) && question.attempts >= 0
    && question.stages && typeof question.stages === 'object' && !Array.isArray(question.stages));
  const normalizeQuestion = (question,id,envelope,pool,lock) => {
    lock.recordRevision = Number.isSafeInteger(question?.record_revision) ? question.record_revision : 0;
    if (!question) return null;
    if (question.id !== id || !question.stages || typeof question.stages !== 'object' || Array.isArray(question.stages)
      || !Number.isSafeInteger(question.attempts) || question.attempts < 0
      || question.round_attempts !== undefined && (!Number.isSafeInteger(question.round_attempts) || question.round_attempts < 0)) {
      throw terminal('invalid_state','问题处理预算状态无效');
    }
    for (const [stage,phase] of Object.entries(question.stages)) {
      if (!['vision','answer'].includes(stage) || !phase || typeof phase !== 'object' || Array.isArray(phase)
        || phase.request_contract !== undefined && !requestContract(phase.request_contract)) {
        throw terminal('invalid_state','问题阶段请求身份无效');
      }
    }
    if (Object.prototype.hasOwnProperty.call(question,'settlement')
      && !validQuestionSettlement(question.settlement,question)) {
      throw terminal('invalid_state','问题结算记录无效');
    }
    const priorGeneration = Number.isSafeInteger(question.attempt_generation) && question.attempt_generation > 0
      ? question.attempt_generation : 1;
    let originalConfiguration = question.configuration;
    if (!originalConfiguration) {
      const candidates = [envelopeConfiguration(envelope,pool),envelope?.migration_from].filter(Boolean);
      originalConfiguration = candidates.find(value => {
        const legacy = legacyBindings(envelope,value,pool,priorGeneration);
        const v121 = question.schema_version === undefined
          && question.configuration_binding === undefined && question.execution_binding === undefined
          && question.responsibility_binding === undefined
          && question.identity_binding === undefined
          && envelope.legacy_v121_origin
          && question.revision === envelope.legacy_v121_origin.pool_revision
          && Number.isSafeInteger(question.deadline) && question.deadline >= 0
          && question.deadline === envelope.legacy_v121_origin.deadline_at
          && question.binding === legacyV121Binding(envelope);
        if (v121) {
          question.legacy_v121_migrated_at = Date.now();
          question.legacy_v121_origin = { ...envelope.legacy_v121_origin };
        }
        return v121 || question.binding === legacy.binding || question.identity_binding === legacy.identity;
      });
      if (!originalConfiguration) throw terminal('question_conflict','旧问题记录无法与当前责任安全绑定');
    }
    if (!Number.isSafeInteger(originalConfiguration.runtime_revision)
      || !Number.isSafeInteger(originalConfiguration.pool_revision)
      || typeof originalConfiguration.secrets_generation !== 'string'
      || originalConfiguration.pool_sha256 !== undefined && !/^[a-f0-9]{64}$/.test(originalConfiguration.pool_sha256)
      || originalConfiguration.materials_source_sha256 !== undefined
        && originalConfiguration.materials_source_sha256 !== ''
        && !/^[a-f0-9]{64}$/.test(originalConfiguration.materials_source_sha256)) throw terminal('invalid_state','问题配置代次无效');
    if (question.migration_origin !== undefined
      && (!Number.isSafeInteger(question.migration_origin.attempt_generation)
        || question.migration_origin.attempt_generation < 1
        || !Number.isSafeInteger(question.migration_origin.runtime_revision)
        || !Number.isSafeInteger(question.migration_origin.pool_revision)
        || !/^[a-f0-9]{32}$/.test(question.migration_origin.secrets_generation || '')
        || !/^[a-f0-9]{64}$/.test(question.migration_origin.pool_sha256 || '')
        || !/^[a-f0-9]{64}$/.test(question.migration_origin.materials_source_sha256 || ''))) {
      throw terminal('invalid_state','问题配置迁移根无效');
    }
    const responsibility = responsibilityBinding(id,envelope);
    if (question.responsibility_binding && question.responsibility_binding !== responsibility) throw terminal('question_conflict','问题责任与当前会话不一致');
    if (question.scope !== undefined && question.scope !== (envelope?.scope || 'admin')
      || question.session_key !== undefined && question.session_key !== (envelope?.session_key || '')
      || question.conversation_generation !== undefined
        && question.conversation_generation !== (envelope?.generation ?? 0)) {
      throw terminal('question_conflict','问题持久身份与当前会话不一致');
    }
    const expectedConfigurationBinding = configurationBinding(originalConfiguration);
    if (question.configuration_binding !== undefined
      && question.configuration_binding !== expectedConfigurationBinding) {
      throw terminal('invalid_state','问题配置绑定已损坏');
    }
    question.schema_version = 2;
    question.scope = question.scope || envelope?.scope || 'admin';
    question.session_key = question.session_key || envelope?.session_key || '';
    question.conversation_generation = question.conversation_generation ?? envelope?.generation ?? 0;
    question.responsibility_binding = responsibility;
    question.configuration = originalConfiguration;
    question.configuration_binding = expectedConfigurationBinding;
    question.execution_binding = question.execution_binding
      || executionBinding(responsibility,originalConfiguration,priorGeneration);
    question.attempt_generation = priorGeneration;
    // v1.2.x 只有累计 attempts。升级时保守视为本轮已消费；明确恢复代才清零。
    if (question.round_attempts === undefined) question.round_attempts = Math.min(question.attempts,pool.policy.max_attempts);
    return question;
  };
  const setQuestionExecution = (question,envelope,pool,generation) => {
    const configuration = envelopeConfiguration(envelope,pool);
    const legacy = legacyBindings(envelope,configuration,pool,generation);
    question.configuration = configuration;
    question.configuration_binding = configurationBinding(configuration);
    question.execution_binding = executionBinding(question.responsibility_binding,configuration,generation);
    question.binding = legacy.binding;
    question.identity_binding = legacy.identity;
    question.revision = pool.revision;
    question.attempt_generation = generation;
    question.deadline = Math.min(envelope?.deadline_at || Infinity,Date.now()+pool.policy.question_timeout_ms);
  };
  const migrationAllowed = (question,envelope,pool,attemptGeneration) => {
    const from = envelope?.migration_from;
    if (!from || envelope.transition_reason !== 'configuration_changed'
      || !Number.isSafeInteger(from.attempt_generation)
      || attemptGeneration <= question.attempt_generation) return false;
    const origin = question.migration_origin;
    const direct = sameConfiguration(question.configuration,from)
      && from.attempt_generation === question.attempt_generation;
    // runtime 保留最早尚未 settle 的配置迁移根。若 router 已经
    // 把 A 迁到 B，但 B 的 adapter 回程未确认时又应用 C，则
    // C 信封仍携带 A 根；只有 router 自身持久的同责任迁移根
    // 能证明这条 A→B→C 继承链，不接受任意旧配置。
    const inherited = origin && sameConfiguration(origin,from)
      && origin.attempt_generation === from.attempt_generation;
    if (!direct && !inherited) return false;
    const current = envelopeConfiguration(envelope,pool);
    return !sameConfiguration(question.configuration,current);
  };
  const invalidateQuestionResults = (question,reason) => {
    for (const [stage,phase] of Object.entries(question.stages || {})) {
      if (phase?.result !== undefined) {
        question.invalidated_results = [...(question.invalidated_results || []),{
          stage,sha256:hash(JSON.stringify(phase.result)),disposition:cachedResultDisposition(phase.result),
          reason,attempt_generation:question.attempt_generation,invalidated_at:Date.now(),
        }].slice(-8);
        delete phase.result;
      }
      phase.tried = [];
      delete phase.request_contract;
      delete phase.owner;
    }
  };

  async function run(body,envelope,signal,lock,id) {
    const pool = currentPool();
    if (envelope && Date.now() >= envelope.deadline_at) throw terminal('question_timeout','本次问题的总处理时间已用尽');
    const stage = envelope?.stage || 'answer';
    const contract = requestContract(envelope);
    if (envelope?.scope === 'conversation' && !contract) {
      throw terminal('provider_request_identity_unknown',
        '会话推理缺少与实际请求及知识上下文绑定的身份');
    }
    const attemptGeneration = envelope?.attempt_generation || 1;
    if (!Number.isSafeInteger(attemptGeneration) || attemptGeneration < 1) throw terminal('invalid_input','问题恢复代次无效');
    assertCurrent(envelope,pool,envelope?.deadline_at || Date.now()+pool.policy.question_timeout_ms);
    let question = normalizeQuestion(readQuestion(id),id,envelope,pool,lock);
    const currentConfiguration = envelopeConfiguration(envelope,pool);
    const responsibility = responsibilityBinding(id,envelope);
    if (question && !sameConfiguration(question.configuration,currentConfiguration)) {
      if (!migrationAllowed(question,envelope,pool,attemptGeneration)
        || ['invalid_input','safety_refusal'].includes(question.terminal?.code)) {
        throw terminal('question_conflict','问题配置与当前应用代次不一致');
      }
      const from = {...question.configuration,attempt_generation:question.attempt_generation};
      if (!question.migration_origin) question.migration_origin = {...from};
      if (question.settlement) {
        question.prior_settlements = [...(question.prior_settlements || []),{
          ...question.settlement,reason:'configuration_changed',invalidated_at:Date.now(),
        }].slice(-8);
        delete question.settlement;
      }
      invalidateQuestionResults(question,'configuration_changed');
      setQuestionExecution(question,envelope,pool,attemptGeneration);
      question.round_attempts = 0;
      question.configuration_migrations = [...(question.configuration_migrations || []),{
        from_runtime_revision:from.runtime_revision,from_pool_revision:from.pool_revision,
        from_secrets_generation:from.secrets_generation,from_attempt_generation:from.attempt_generation,
        from_pool_sha256:from.pool_sha256 || '',from_materials_source_sha256:from.materials_source_sha256 || '',
        to_runtime_revision:currentConfiguration.runtime_revision,to_pool_revision:currentConfiguration.pool_revision,
        to_secrets_generation:currentConfiguration.secrets_generation,to_attempt_generation:attemptGeneration,
        to_pool_sha256:currentConfiguration.pool_sha256 || '',to_materials_source_sha256:currentConfiguration.materials_source_sha256 || '',
        migrated_at:Date.now(),
      }].slice(-8);
      if (question.terminal) delete question.terminal;
      persistQuestion(question,lock);
    }
    if (question?.settlement) throw terminal('question_settled','该问题已由运行时持久接管');
    if (question) {
      const expectedExecution = executionBinding(responsibility,currentConfiguration,attemptGeneration);
      if (question.execution_binding !== expectedExecution) {
        const priorGeneration = question.attempt_generation;
        const nonRetryable = new Set(['invalid_input','safety_refusal']);
        const sameIdentity = sameConfiguration(question.configuration,currentConfiguration)
          && question.responsibility_binding === responsibility;
        const cached = question.stages?.[stage];
        const cachedDisposition = cachedResultDisposition(cached?.result);
        const cachedContract = requestContract(cached?.request_contract);
        const otherCachedDispositions = Object.entries(question.stages || {})
          .filter(([name,phase]) => name !== stage && phase?.result !== undefined)
          .map(([,phase]) => cachedResultDisposition(phase.result));
        const otherCachedResultsSafe = otherCachedDispositions.every(value => value === 'answer');
        const recoverBoundAnswer = sameIdentity && attemptGeneration === priorGeneration + 1
          && cachedDisposition === 'answer' && contract && sameRequestContract(cachedContract,contract)
          && otherCachedResultsSafe && (!question.terminal || !nonRetryable.has(question.terminal.code));
        const recoverUnboundAnswer = sameIdentity && attemptGeneration === priorGeneration + 1
          && cachedDisposition === 'answer' && contract && !sameRequestContract(cachedContract,contract)
          && otherCachedResultsSafe && (!question.terminal || !nonRetryable.has(question.terminal.code));
        const recoverCachedNonAnswer = sameIdentity && attemptGeneration === priorGeneration + 1
          && cachedDisposition === 'non_answer' && otherCachedResultsSafe && !question.output_policy_recovery
          && (!question.terminal || !nonRetryable.has(question.terminal.code));
        if (recoverBoundAnswer) {
          setQuestionExecution(question,envelope,pool,attemptGeneration);
          question.round_attempts = 0;
          if (question.terminal && !nonRetryable.has(question.terminal.code)) delete question.terminal;
          persistQuestion(question,lock);
        } else if (recoverUnboundAnswer) {
          question.invalidated_results = [...(question.invalidated_results || []),{
            stage,sha256:hash(JSON.stringify(cached.result)),disposition:'answer',
            reason:'request_identity_changed',attempt_generation:priorGeneration,
            invalidated_at:Date.now(),
          }].slice(-8);
          delete cached.result; delete cached.owner; delete cached.request_contract;
          cached.tried = [];
          setQuestionExecution(question,envelope,pool,attemptGeneration);
          question.round_attempts = 0;
          if (question.terminal && !nonRetryable.has(question.terminal.code)) delete question.terminal;
          persistQuestion(question,lock);
        } else if (recoverCachedNonAnswer) {
          const invalidatedSha256 = hash(JSON.stringify(cached.result));
          delete cached.result; delete cached.owner;
          delete cached.request_contract;
          cached.invalidated_result = {sha256:invalidatedSha256,
            reason:'current_output_policy_non_answer',attempt_generation:priorGeneration,invalidated_at:Date.now()};
          question.output_policy_recovery = {stage,from_attempt_generation:priorGeneration,
            to_attempt_generation:attemptGeneration,result_sha256:invalidatedSha256,invalidated_at:Date.now()};
          setQuestionExecution(question,envelope,pool,attemptGeneration);
          if (question.terminal && !nonRetryable.has(question.terminal.code)) delete question.terminal;
          persistQuestion(question,lock);
          bestEffortState(() => record({at:Date.now(),question_id:id,stage,pool_revision:pool.revision,
            outcome:'cached_non_answer_invalidated',attempt:question.attempts}));
        } else if (sameIdentity && attemptGeneration === priorGeneration + 1
          && cachedDisposition === 'invalid' && cached?.result === undefined
          && otherCachedResultsSafe && (!question.terminal || !nonRetryable.has(question.terminal.code))) {
          setQuestionExecution(question,envelope,pool,attemptGeneration);
          for (const phase of Object.values(question.stages || {})) {
            if (phase?.result !== undefined) continue;
            phase.tried = []; delete phase.owner; delete phase.request_contract;
          }
          question.round_attempts = 0;
          if (question.terminal && !nonRetryable.has(question.terminal.code)) delete question.terminal;
          persistQuestion(question,lock);
        } else throw terminal('question_conflict','问题标识与原处理上下文不一致');
      }
    }
    if (!question) {
      question = {id,schema_version:2,record_revision:0,scope:envelope?.scope || 'admin',
        session_key:envelope?.session_key || '',conversation_generation:envelope?.generation ?? 0,
        responsibility_binding:responsibility,configuration:currentConfiguration,
        configuration_binding:configurationBinding(currentConfiguration),
        execution_binding:executionBinding(responsibility,currentConfiguration,attemptGeneration),
        attempts:0,round_attempts:0,stages:{},created_at:Date.now()};
      setQuestionExecution(question,envelope,pool,attemptGeneration);
    }
    const check = () => {
      if (signal?.aborted) throw terminal('question_cancelled','本次问题已取消');
      if (!lockCurrent(lock)) throw terminal('question_owner_changed','问题处理所有权已变化');
      assertCurrent(envelope,pool,question.deadline);
    };
    try { check(); } catch (error) {
      if (lockCurrent(lock)) {
        question.terminal = {code:error.code || 'question_cancelled',message:'本次问题已取消或到期'};
        persistQuestion(question,lock);
      }
      throw error;
    }
    const existing = question.stages[stage];
    // 旧版或崩溃恢复状态可能只留下另一阶段的结果。即使当前阶段尚未创建
    // result，也必须先封住安全拒绝和畸形缓存，不能因此取得一次新的上游调用权。
    const otherDispositions = Object.entries(question.stages || {})
      .filter(([name,phase]) => name !== stage && phase?.result !== undefined)
      .map(([,phase]) => cachedResultDisposition(phase.result));
    if (otherDispositions.includes('safety_refusal')) {
      throw terminal('safety_refusal','模型已拒绝该内容，本次问题已终止');
    }
    if (otherDispositions.some(value => value !== 'answer')) {
      throw terminal('invalid_response','跨阶段缓存结果未通过当前输出策略');
    }
    if (existing?.result) {
      const disposition = cachedResultDisposition(existing.result);
      if (disposition === 'non_answer') {
        // v1.2.x 缓存没有请求摘要，但 responsibility/question 身份仍能证明
        // 这份正文属于同一应答责任。已知空泛正文在任何请求下都不可见，
        // 因此可以安全拒绝；合法答案仍必须有完整请求契约才能读取。
        throw terminal('question_result_rejected','缓存结果未通过当前访客输出策略');
      }
      if (!contract || !sameRequestContract(requestContract(existing.request_contract),contract)) {
        throw terminal('provider_request_identity_unknown',
          '缓存结果缺少与当前请求及知识上下文一致的身份');
      }
      if (disposition === 'answer' || disposition === 'safety_refusal') return existing.result;
      throw terminal('invalid_response','缓存结果未通过当前输出策略');
    }
    if (question.terminal) throw terminal(question.terminal.code,question.terminal.message);
    if (existing?.owner && existing.owner !== boot) {
      question.terminal = {code:'question_interrupted',message:'先前请求未获得确定结果，本次问题已终止'}; persistQuestion(question,lock);
      throw terminal(question.terminal.code,question.terminal.message);
    }
    const phase = question.stages[stage] || {tried:[]};
    question.stages[stage] = phase;
    if (contract) phase.request_contract = contract;
    else delete phase.request_contract;
    phase.owner = boot; persistQuestion(question,lock);
    const visual = body.messages.some(message => Array.isArray(message.content) && message.content.some(part => part.type === 'image_url'));
    if (envelope && visual && stage !== 'vision') throw terminal('invalid_input','图片必须使用受管视觉阶段');
    // 近似估算而非模型专用 tokenizer；保留消息开销、256 token 余量与每图4096，不裁剪知识或图片。
    const inputTokens = 256 + body.messages.reduce((sum,message) => sum + 16 + (typeof message.content === 'string' ? estimateTextTokens(message.content) : message.content.reduce((total,part) => total + (part.type === 'image_url' ? 4096 : estimateTextTokens(part.text || '')),0)),0);
    let candidates = 0;
    const attemptFailures = [];
    try {
      if (refreshState().pool_until > Date.now()) throw terminal('pool_cooling','接口池处于冷却保护状态');
      for (const entry of pool.entries) {
        check();
        if (question.round_attempts >= pool.policy.max_attempts) throw terminal('question_budget_exhausted','本轮问题调用次数已用尽');
        if (!entry.enabled || !entry.capabilities[entry.mode] || visual && !entry.capabilities.vision || phase.tried.includes(entry.id)) continue;
        const requestedOutput = Number(body.max_completion_tokens ?? body.max_tokens ?? body.max_output_tokens) || entry.max_output_tokens;
        const maxOutput = Math.min(entry.max_output_tokens,Math.max(1,requestedOutput));
        if (inputTokens + maxOutput > entry.context_window) continue;
        candidates += 1;
        if (!reserve(entry,pool.policy,Date.now(),visual)) continue;
        phase.tried.push(entry.id); question.attempts += 1; question.round_attempts += 1; persistQuestion(question,lock);
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
          phase.result = result; delete phase.owner;
          if (result.choices?.[0]?.message?.refusal || result.choices?.[0]?.finish_reason === 'content_filter') question.terminal = {code:'safety_refusal',message:'模型已拒绝该内容，本次问题已终止'};
          try { persistQuestion(question,lock); }
          catch (error) {
            delete phase.result;
            throw error.terminal ? error
              : terminal('question_persistence_failed','推理结果未能安全持久化');
          }
          // 结果落盘后再次检查取消/配置栅栏。若 runtime 在上一步与此处之间
          // 提交人工接管或总关，本次结果仍留作可审计事实，但绝不能返回为有效回答。
          check();
          bestEffortState(() => success(entry,visual));
          bestEffortState(() => record({at:Date.now(),question_id:id,stage,entry_id:entry.id,
            pool_revision:pool.revision,remaining_budget_ms:Math.max(0,question.deadline-Date.now()),
            outcome:result.choices?.[0]?.message?.refusal || result.choices?.[0]?.finish_reason === 'content_filter' ? 'refused':'success',
            attempt:question.attempts,duration_ms:Date.now()-start}));
          return result;
        } catch (error) {
          if (!cancelError) { try { check(); } catch (currentError) { cancelError = currentError; } }
          if (cancelError || error.terminal || signal?.aborted) { bestEffortState(() => release(entry,visual)); throw cancelError || error; }
          const failure = error.failure || {kind:error.name === 'AbortError' ? 'upstream_timeout':'connection_failed',fallback:true,scope:'entryScope',status:0};
          if (!failure.fallback || failure.scope === 'visionScope' && !visual) { bestEffortState(() => release(entry,visual)); throw terminal(failure.kind === 'vision_unsupported' ? 'invalid_request' : failure.kind,failure.kind === 'safety_refusal' ? '模型拒绝处理该内容':'模型拒绝本次请求的输入格式'); }
          bestEffortState(() => fault(entry,failure,pool.policy,visual));
          attemptFailures.push(failure.kind);
          bestEffortState(() => record({at:Date.now(),question_id:id,stage,entry_id:entry.id,
            pool_revision:pool.revision,remaining_budget_ms:Math.max(0,question.deadline-Date.now()),
            outcome:'failed',error_class:failure.kind,http_status:failure.status || 0,
            attempt:question.attempts,duration_ms:Date.now()-start}));
        } finally { clearInterval(monitor); signal?.removeEventListener('abort',cancel); }
      }
      if (candidates && !pool.entries.some(entry => entry.enabled && allowed(entry,Date.now()))) {
        mutateState(current => { current.pool_until = Date.now() + pool.policy.pool_cooldown_ms; });
      }
      const diagnosticKinds = new Set(['authentication_failed','model_unavailable','rate_limited','quota_exhausted',
        'upstream_timeout','upstream_unavailable','connection_failed','protocol_error','invalid_response']);
      const distinctFailures = [...new Set(attemptFailures)];
      // 单接口，或本轮所有真正发出的尝试都是同一类故障时，直接向管理员返回该安全类别。
      // 多类故障仍保留 pool_exhausted，详情由受限的近期切换记录展示，不透传上游正文。
      if (attemptFailures.length === candidates && distinctFailures.length === 1 && diagnosticKinds.has(distinctFailures[0])) {
        throw terminal(distinctFailures[0],'已确认本轮推理失败类别');
      }
      if (candidates && attemptFailures.length === 0) throw terminal('pool_cooling','当前候选接口处于冷却或半开保护状态');
      throw terminal(candidates ? 'pool_exhausted':'no_capable_provider',candidates ? '本次问题可用的接口已用尽':'没有满足协议、图片能力或上下文限制的可用接口');
    } catch (error) {
      question.terminal = {code:error.code || 'question_failed',message:error.terminal ? error.message:'本次问题处理已终止'};
      delete phase.owner;
      if (lockCurrent(lock)) persistQuestion(question,lock);
      if (error.terminal) throw error;
      throw terminal(question.terminal.code,question.terminal.message);
    }
  }

  const route = async (body,envelope,signal) => {
    const id = envelope?.question_id || hash(crypto.randomUUID());
    const previous = id && inflight.get(id);
    const pending = (async () => {
      if (previous) { try { await previous; } catch (_) {} }
      const deadline = Math.max(Date.now()+1000,envelope?.deadline_at || Date.now()+180000);
      const lock = await acquireQuestionLock(id,signal,deadline);
      try { return await run(body,envelope,signal,lock,id); }
      finally { releaseQuestionLock(lock); }
    })();
    if (id) inflight.set(id,pending);
    try { return await pending; } finally { if (id && inflight.get(id) === pending) inflight.delete(id); }
  };
  const replay = async envelope => {
    if (!envelope?.question_id) throw terminal('invalid_envelope','受管问题信封缺失或无效');
    const contract = requestContract(envelope);
    if (!contract) throw terminal('provider_request_identity_unknown','重放请求缺少原请求身份');
    const pool = currentPool();
    assertCurrent(envelope,pool,Date.now()+5000,{ignoreDeadline:true});
    const lock = await acquireQuestionLock(envelope.question_id,undefined,Date.now()+5000);
    try {
      const question = normalizeQuestion(readQuestion(envelope.question_id),envelope.question_id,envelope,pool,lock);
      if (!question) throw terminal('question_result_absent','没有可重放的已确认推理结果');
      if (!sameConfiguration(question.configuration,envelopeConfiguration(envelope,pool))
        && migrationAllowed(question,envelope,pool,envelope.attempt_generation || 1)) {
        // successor 还未进入正常 route：旧配置缓存不能被当成新代结果。
        // 返回明确 absent，让 runtime 保留迁移凭证并使用同代正常请求。
        throw terminal('question_result_absent','当前配置代尚无可重放结果');
      }
      const expected = executionBinding(responsibilityBinding(envelope.question_id,envelope),
        envelopeConfiguration(envelope,pool),envelope.attempt_generation || 1);
      if (question.execution_binding !== expected) throw terminal('question_conflict','重放请求与原问题代次不一致');
      if (question.settlement) throw terminal('question_settled','该问题已由运行时持久接管');
      const phase = question.stages?.[envelope.stage || 'answer'];
      if (phase?.result !== undefined) {
        const disposition = cachedResultDisposition(phase.result);
        if (disposition === 'non_answer') {
          throw terminal('question_result_rejected','缓存结果未通过当前访客输出策略');
        }
        if (!sameRequestContract(requestContract(phase.request_contract),contract)) {
          throw terminal('provider_request_identity_unknown','缓存结果与原请求或知识上下文身份不一致');
        }
        if (disposition === 'answer' || disposition === 'safety_refusal') {
          bestEffortState(() => record({at:Date.now(),question_id:question.id,stage:envelope.stage || 'answer',
            pool_revision:pool.revision,outcome:'cached_replay',attempt:question.attempts}));
          return phase.result;
        }
        throw terminal('invalid_response','缓存结果未通过当前输出策略');
      }
      if (phase?.owner) throw terminal('question_interrupted','先前请求未获得确定结果');
      // 没有持久正文时，上一次终态只说明该轮没有结果。replay 用统一 absent
      // 让 runtime 安全开启后续有界恢复，而不是把模糊类别误当缓存正文。
      if (question.terminal) throw terminal('question_result_absent','原处理轮没有可重放结果');
      throw terminal('question_result_absent','没有可重放的已确认推理结果');
    } finally { releaseQuestionLock(lock); }
  };
  const settle = async (envelope,value={}) => {
    if (!envelope?.question_id || value.outcome !== 'plan_persisted'
      || !/^[a-f0-9]{64}$/.test(value.plan_sha256 || '')
      || !Number.isSafeInteger(value.response_generation) || value.response_generation < 0) {
      throw terminal('invalid_input','问题结算内容无效');
    }
    const contract = requestContract(envelope);
    if (!contract) throw terminal('provider_request_identity_unknown','结算请求缺少原请求身份');
    const pool = currentPool();
    // settle 只是确认 runtime 已持久接管一份既有结果，不授予新的推理权。
    // adapter 暂时不可用期间，conversation、总开关或接口配置可能已经换代；
    // 仍须允许携带原始完整配置/请求绑定的签名回执释放旧缓存。下面逐字核对
    // question 的责任、执行代和结果摘要，不能复用 route/replay 的“当前状态”门禁。
    const lock = await acquireQuestionLock(envelope.question_id,undefined,Date.now()+5000);
    try {
      const question = normalizeQuestion(readQuestion(envelope.question_id),envelope.question_id,envelope,pool,lock);
      if (!question) return {ok:true,state:'absent'};
      const expected = executionBinding(responsibilityBinding(envelope.question_id,envelope),
        envelopeConfiguration(envelope,pool),envelope.attempt_generation || 1);
      if (question.execution_binding !== expected) throw terminal('question_conflict','结算请求与原问题代次不一致');
      if (question.settlement) {
        if (question.settlement.plan_sha256 !== value.plan_sha256
          || question.settlement.response_generation !== value.response_generation
          || !sameRequestContract(question.settlement.request_contract,contract)) {
          throw terminal('question_conflict','问题已经由不同结果结算');
        }
        return {ok:true,state:'settled'};
      }
      const phase = question.stages?.[envelope.stage || 'answer'];
      if (!phase?.result || !sameRequestContract(requestContract(phase.request_contract),contract)) {
        throw terminal('provider_request_identity_unknown','结算结果与原请求或知识上下文身份不一致');
      }
      question.settlement = {outcome:'plan_persisted',plan_sha256:value.plan_sha256,
        response_generation:value.response_generation,request_contract:contract,settled_at:Date.now()};
      for (const phase of Object.values(question.stages || {})) {
        if (phase?.result !== undefined) {
          phase.result_receipt = {sha256:hash(JSON.stringify(phase.result)),
            disposition:cachedResultDisposition(phase.result)};
          delete phase.result;
        }
        delete phase.owner;
      }
      persistQuestion(question,lock);
      return {ok:true,state:'settled'};
    } finally { releaseQuestionLock(lock); }
  };
  const retire = async (envelope,value={}) => {
    const purposes = new Set(['conversation_cancelled','global_disabled','input_retired',
      'non_answer_retired']);
    if (!envelope?.question_id || envelope.scope !== 'conversation'
      || !value || typeof value !== 'object' || Array.isArray(value)
      || Object.keys(value).sort().join(',') !== 'outcome,purpose'
      || value.outcome !== 'responsibility_retired' || !purposes.has(value.purpose)) {
      throw terminal('invalid_input','问题退休内容无效');
    }
    const contract = requestContract(envelope);
    const legacyCleanup = legacyV121CleanupEnvelope(envelope);
    if (!contract && !legacyCleanup) {
      throw terminal('provider_request_identity_unknown','退休请求缺少原请求身份');
    }
    if (legacyCleanup) {
      // 公开 v1.2.1 的问题缓存尚无 request contract。它只能通过这一条
      // cleanup-only 事务释放：签名信封逐字绑定旧 runtime/pool/deadline，
      // 会话文件再反向授权同一 job 与业务终态；不能 route、replay 或 settle。
      if (!legacyV121RetirementAuthorized(envelope,value.purpose)) {
        throw terminal('question_conflict','运行时尚未持久授权退休该旧问题');
      }
      const lock = await acquireQuestionLock(envelope.question_id,undefined,Date.now()+5000);
      try {
        const question = readQuestion(envelope.question_id);
        if (!question) return {ok:true,state:'absent'};
        if (!legacyV121QuestionMatchesCleanup(question,envelope)) {
          throw terminal('question_conflict','旧问题缓存与退休身份不一致');
        }
        if (!lockCurrent(lock)) throw terminal('question_owner_changed','问题处理所有权已变化');
        const target = questionFile(envelope.question_id), disk = readQuestion(envelope.question_id);
        if (!disk || canonical(disk) !== canonical(question)) {
          throw terminal('question_owner_changed','问题处理记录已由新的执行者接管');
        }
        fs.unlinkSync(target);
        const parent = fs.openSync(path.dirname(target),'r');
        try { fs.fsyncSync(parent); } finally { fs.closeSync(parent); }
        bestEffortState(() => record({at:Date.now(),question_id:envelope.question_id,
          stage:'answer',pool_revision:envelope.pool_revision,
          outcome:'legacy_v121_responsibility_retired',reason:value.purpose}));
        return {ok:true,state:'retired'};
      } finally { releaseQuestionLock(lock); }
    }
    const pool = currentPool();
    // retire 只撤销一个已签名、已持久登记的推理责任，不授予 route/replay
    // 权限，也不要求旧 generation 仍是当前 AI 状态。人工接管和总关正是
    // 通过这条 cleanup-only 路径在结果竞态中删除不可见缓存。
    const lock = await acquireQuestionLock(envelope.question_id,undefined,Date.now()+5000);
    try {
      const question = normalizeQuestion(readQuestion(envelope.question_id),
        envelope.question_id,envelope,pool,lock);
      if (!question) return {ok:true,state:'absent'};
      const expected = executionBinding(responsibilityBinding(envelope.question_id,envelope),
        envelopeConfiguration(envelope,pool),envelope.attempt_generation || 1);
      if (question.execution_binding !== expected) {
        throw terminal('question_conflict','退休请求与原问题代次不一致');
      }
      if (!retirementAuthorized(question,envelope,value.purpose)) {
        throw terminal('question_conflict','运行时尚未持久授权退休该问题');
      }
      if (question.settlement) {
        if (question.settlement.outcome !== 'plan_persisted'
          || !sameRequestContract(question.settlement.request_contract,contract)) {
          throw terminal('question_conflict','问题已经由不同结果结算');
        }
      } else {
        const phase = question.stages?.[envelope.stage || 'answer'];
        if (!phase || !sameRequestContract(requestContract(phase.request_contract),contract)) {
          throw terminal('provider_request_identity_unknown','退休目标与原请求或知识上下文身份不一致');
        }
      }
      if (!lockCurrent(lock)) throw terminal('question_owner_changed','问题处理所有权已变化');
      const target = questionFile(envelope.question_id);
      const disk = readQuestion(envelope.question_id);
      if (!disk || disk.record_revision !== lock.recordRevision) {
        throw terminal('question_owner_changed','问题处理记录已由新的执行者接管');
      }
      fs.unlinkSync(target);
      const parent = fs.openSync(path.dirname(target),'r');
      try { fs.fsyncSync(parent); } finally { fs.closeSync(parent); }
      bestEffortState(() => record({at:Date.now(),question_id:envelope.question_id,
        stage:envelope.stage,pool_revision:envelope.pool_revision,
        outcome:'responsibility_retired',reason:value.purpose}));
      return {ok:true,state:'retired'};
    } finally { releaseQuestionLock(lock); }
  };
  const status = () => {
    const pool = currentPool(), now = Date.now(), current = refreshState(), questions = storage(false,false);
    // 管理面用这一组非敏感身份确认：严格读取了哪一份完整池与秘密代次。
    // pool_sha256 是公开配置投影的原始文件摘要，不含 Key 或自定义 Header 值。
    return {ok:true,readback_contract_version:1,revision:pool.revision,
      secrets_generation:pool.secrets_generation,pool_sha256:pool.applied_sha256,
      pool_cooldown_until:current.pool_until,questions,entries:pool.entries.map(entry => {
      const values = scopes(entry).map(key => current.health[key]).filter(Boolean);
      const until = Math.max(0,...values.map(value => value.until || 0));
      const visionValues = scopes(entry,true).map(key => current.health[key]).filter(Boolean);
      const visionUntil = Math.max(0,...visionValues.map(value => value.until || 0));
      return {id:entry.id,enabled:entry.enabled,health:!entry.enabled ? 'disabled' : until > now ? 'cooling' : values.some(value => value.lease?.until > now) ? 'half_open' : values.length && values.every(value => value.successes >= 2) ? 'healthy' : 'unknown',cooldown_until:until,last_error:values.find(value => value.last_error)?.last_error || '',
        vision_health:!entry.enabled || !entry.capabilities.vision ? 'disabled' : visionUntil > now ? 'cooling' : visionValues.some(value => value.lease?.until > now) ? 'half_open' : current.health[entry.visionScope] && visionValues.every(value => value.successes >= 2) ? 'healthy' : 'unknown',vision_cooldown_until:visionUntil,vision_last_error:visionValues.find(value => value.last_error)?.last_error || ''};
    })};
  };
  return {route,replay,settle,retire,status,recent:() => ({ok:true,records:refreshState().recent.slice().reverse()}),
    loadPool:currentPool,clearHealth:entry => mutateState(current => {
      for (const key of scopes(entry,true)) delete current.health[key]; current.pool_until = 0;
    })};
}

module.exports = {createRouter,loadPool,validateEntry,validatePolicy,normalizeApiBase,parseHeaders,DEFAULT_POLICY,
  RouterError,terminal,classifyFailure,retryAfterMilliseconds,cooldownMilliseconds,readJson,estimateTextTokens};
