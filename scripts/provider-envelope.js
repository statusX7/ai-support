'use strict';

const crypto = require('node:crypto');
const MARKER = /\[\[CRISPAI_PROVIDER_CONTEXT_V1:([A-Za-z0-9_.-]{1,4096})\]\]/g;

function canonical(value) {
  if (Array.isArray(value)) return '[' + value.map(canonical).join(',') + ']';
  if (value && typeof value === 'object') {
    return '{' + Object.keys(value).sort()
      .map(name => JSON.stringify(name) + ':' + canonical(value[name])).join(',') + '}';
  }
  return JSON.stringify(value);
}

function jsonValue(value) {
  return JSON.parse(JSON.stringify(value));
}

function requestContract(body, planContext = null) {
  return {
    request_contract_version: 1,
    request_sha256: crypto.createHash('sha256').update(canonical(jsonValue(body))).digest('hex'),
    plan_context_sha256: crypto.createHash('sha256').update(canonical(jsonValue(planContext))).digest('hex'),
  };
}

function validRequestContract(value) {
  const names = ['request_contract_version', 'request_sha256', 'plan_context_sha256'];
  const present = names.filter(name => value?.[name] !== undefined).length;
  if (present === 0) return null;
  if (present !== names.length || value.request_contract_version !== 1
    || !/^[a-f0-9]{64}$/.test(value.request_sha256 || '')
    || !/^[a-f0-9]{64}$/.test(value.plan_context_sha256 || '')) {
    throw new Error('问题请求身份无效');
  }
  return Object.fromEntries(names.map(name => [name, value[name]]));
}

function signEnvelope(value, key) {
  const payload = Buffer.from(JSON.stringify(value)).toString('base64url');
  const signature = crypto.createHmac('sha256', key).update('crispai-provider-v1\0' + payload).digest('hex');
  return payload + '.' + signature;
}

function envelopeMarker(value, key) {
  return '[[CRISPAI_PROVIDER_CONTEXT_V1:' + signEnvelope(value, key) + ']]';
}

function verifyEnvelope(token, key) {
  if (typeof token !== 'string' || token.length > 8192) throw new Error('问题信封无效');
  const parts = token.split('.');
  if (parts.length !== 2 || !/^[A-Za-z0-9_-]+$/.test(parts[0]) || !/^[a-f0-9]{64}$/.test(parts[1])) throw new Error('问题信封无效');
  const expected = crypto.createHmac('sha256', key).update('crispai-provider-v1\0' + parts[0]).digest('hex');
  if (!crypto.timingSafeEqual(Buffer.from(parts[1]), Buffer.from(expected))) throw new Error('问题信封认证失败');
  const value = JSON.parse(Buffer.from(parts[0], 'base64url').toString('utf8'));
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('问题信封字段无效');
  const scope = value.scope || 'conversation';
  const allowed = new Set(['version', 'scope', 'question_id', 'runtime_revision', 'pool_revision',
    'secrets_generation', 'pool_sha256', 'materials_source_sha256', 'configuration_binding',
    'deadline_at', 'stage', 'attempt_generation', 'request_contract_version', 'request_sha256',
    'plan_context_sha256', 'legacy_v121_cleanup']);
  if (scope === 'conversation') for (const name of ['session_key', 'generation',
    'migration_from', 'transition_reason', 'legacy_v121_origin']) allowed.add(name);
  if (Object.keys(value).some(name => !allowed.has(name))) throw new Error('问题信封字段无效');
  const attemptGeneration = value.attempt_generation === undefined ? 1 : value.attempt_generation;
  const migration = value.migration_from;
  const contract = validRequestContract(value);
  const legacyV121Cleanup = value.legacy_v121_cleanup === true;
  const validConfiguration = configuration => configuration && typeof configuration === 'object'
    && !Array.isArray(configuration) && Number.isSafeInteger(configuration.runtime_revision)
    && configuration.runtime_revision >= 0 && Number.isSafeInteger(configuration.pool_revision)
    && configuration.pool_revision >= 0 && /^[a-f0-9]{32}$/.test(configuration.secrets_generation || '')
    && /^[a-f0-9]{64}$/.test(configuration.pool_sha256 || '')
    && /^[a-f0-9]{64}$/.test(configuration.materials_source_sha256 || '');
  const configurationBinding = validConfiguration(value)
    ? crypto.createHash('sha256').update(JSON.stringify([value.runtime_revision,value.pool_revision,
      value.secrets_generation,value.pool_sha256,value.materials_source_sha256])).digest('hex') : '';
  if (value.version !== 1 || !['conversation', 'admin'].includes(scope) || !/^[a-f0-9]{64}$/.test(value.question_id || '')
    || scope === 'conversation' && (!/^[a-f0-9]{64}$/.test(value.session_key || '') || !Number.isSafeInteger(value.generation) || value.generation < 0)
    || !Number.isSafeInteger(attemptGeneration) || attemptGeneration < 1
    || !['vision', 'answer'].includes(value.stage) || !['runtime_revision', 'pool_revision', 'deadline_at'].every(name => Number.isSafeInteger(value[name]) && value[name] >= 0)
    || value.secrets_generation !== undefined && !/^[a-f0-9]{32}$/.test(value.secrets_generation)
    || value.pool_sha256 !== undefined && !/^[a-f0-9]{64}$/.test(value.pool_sha256)
    || value.materials_source_sha256 !== undefined && !/^[a-f0-9]{64}$/.test(value.materials_source_sha256)
    || value.configuration_binding !== undefined && (!/^[a-f0-9]{64}$/.test(value.configuration_binding)
      || !configurationBinding || value.configuration_binding !== configurationBinding)
    || migration !== undefined && (scope !== 'conversation' || value.transition_reason !== 'configuration_changed'
      || !validConfiguration(migration)
      || !Number.isSafeInteger(migration.attempt_generation) || migration.attempt_generation < 1
      || Object.keys(migration).some(name => !['runtime_revision','pool_revision','secrets_generation','pool_sha256','materials_source_sha256','attempt_generation'].includes(name)))
    || value.transition_reason !== undefined && (value.transition_reason !== 'configuration_changed'
      || migration === undefined)
    || value.legacy_v121_cleanup !== undefined && value.legacy_v121_cleanup !== true
    || legacyV121Cleanup && (scope !== 'conversation' || value.stage !== 'answer'
      || attemptGeneration !== 1 || contract !== null || migration !== undefined
      || value.legacy_v121_origin !== undefined
      || Object.keys(value).sort().join(',') !== [
        'attempt_generation','deadline_at','generation','legacy_v121_cleanup','pool_revision',
        'question_id','runtime_revision','scope','session_key','stage','version',
      ].sort().join(',') || value.pool_revision < 1)
    || value.legacy_v121_origin !== undefined
      && (scope !== 'conversation' || !value.legacy_v121_origin
        || typeof value.legacy_v121_origin !== 'object'
        || Array.isArray(value.legacy_v121_origin)
        || Object.keys(value.legacy_v121_origin).sort().join(',') !== 'deadline_at,pool_revision,runtime_revision'
        || !Number.isSafeInteger(value.legacy_v121_origin.runtime_revision)
        || value.legacy_v121_origin.runtime_revision < 0
        || !Number.isSafeInteger(value.legacy_v121_origin.pool_revision)
        || value.legacy_v121_origin.pool_revision < 1
        || !Number.isSafeInteger(value.legacy_v121_origin.deadline_at)
        || value.legacy_v121_origin.deadline_at < 0 || attemptGeneration !== 2
        || migration !== undefined)) throw new Error('问题信封字段无效');
  value.attempt_generation = attemptGeneration;
  return value;
}

function extractEnvelope(body, header, key, required, verifyRequest = true) {
  const tokens = new Set(header ? [header] : []);
  const strip = text => text.replace(MARKER, (_, token) => { tokens.add(token); return ''; });
  for (const message of body.messages || []) {
    if (typeof message.content === 'string') message.content = strip(message.content);
    else if (Array.isArray(message.content)) for (const part of message.content) if (typeof part.text === 'string') part.text = strip(part.text);
  }
  if (tokens.size > 1 || required && !tokens.size) throw new Error('问题信封缺失或冲突');
  if (!tokens.size) return null;
  const envelope = verifyEnvelope([...tokens][0], key);
  const contract = validRequestContract(envelope);
  if (verifyRequest && contract && requestContract(body).request_sha256 !== contract.request_sha256) {
    throw new Error('问题请求正文与签名身份不一致');
  }
  return envelope;
}

function promptRetained(body, prompt) {
  if (typeof prompt !== 'string' || !prompt.trim()) return false;
  // 只接受单个 system 正文中的完整原文，用户引用或跨消息拼接不能替代系统规则。
  return (body.messages || []).some(message => message.role === 'system'
    && (typeof message.content === 'string' ? message.content.includes(prompt)
      : Array.isArray(message.content) && message.content.some(part => part.type === 'text' && typeof part.text === 'string' && part.text.includes(prompt))));
}

module.exports = {signEnvelope, envelopeMarker, verifyEnvelope, extractEnvelope, promptRetained,
  requestContract, validRequestContract};
