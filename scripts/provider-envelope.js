'use strict';

const crypto = require('node:crypto');
const MARKER = /\[\[CRISPAI_PROVIDER_CONTEXT_V1:([A-Za-z0-9_.-]{1,4096})\]\]/g;

function signEnvelope(value, key) {
  const payload = Buffer.from(JSON.stringify(value)).toString('base64url');
  const signature = crypto.createHmac('sha256', key).update('crispai-provider-v1\0' + payload).digest('hex');
  return payload + '.' + signature;
}

function envelopeMarker(value, key) {
  return '[[CRISPAI_PROVIDER_CONTEXT_V1:' + signEnvelope(value, key) + ']]';
}

function verifyEnvelope(token, key) {
  if (typeof token !== 'string' || token.length > 4096) throw new Error('问题信封无效');
  const parts = token.split('.');
  if (parts.length !== 2 || !/^[A-Za-z0-9_-]+$/.test(parts[0]) || !/^[a-f0-9]{64}$/.test(parts[1])) throw new Error('问题信封无效');
  const expected = crypto.createHmac('sha256', key).update('crispai-provider-v1\0' + parts[0]).digest('hex');
  if (!crypto.timingSafeEqual(Buffer.from(parts[1]), Buffer.from(expected))) throw new Error('问题信封认证失败');
  const value = JSON.parse(Buffer.from(parts[0], 'base64url').toString('utf8'));
  const scope = value.scope || 'conversation';
  if (value.version !== 1 || !['conversation', 'admin'].includes(scope) || !/^[a-f0-9]{64}$/.test(value.question_id || '')
    || scope === 'conversation' && (!/^[a-f0-9]{64}$/.test(value.session_key || '') || !Number.isSafeInteger(value.generation) || value.generation < 0)
    || !['vision', 'answer'].includes(value.stage) || !['runtime_revision', 'pool_revision', 'deadline_at'].every(name => Number.isSafeInteger(value[name]) && value[name] >= 0)) throw new Error('问题信封字段无效');
  return value;
}

function extractEnvelope(body, header, key, required) {
  const tokens = new Set(header ? [header] : []);
  const strip = text => text.replace(MARKER, (_, token) => { tokens.add(token); return ''; });
  for (const message of body.messages || []) {
    if (typeof message.content === 'string') message.content = strip(message.content);
    else if (Array.isArray(message.content)) for (const part of message.content) if (typeof part.text === 'string') part.text = strip(part.text);
  }
  if (tokens.size > 1 || required && !tokens.size) throw new Error('问题信封缺失或冲突');
  return tokens.size ? verifyEnvelope([...tokens][0], key) : null;
}

module.exports = {signEnvelope, envelopeMarker, verifyEnvelope, extractEnvelope};
