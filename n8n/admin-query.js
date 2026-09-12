'use strict';

// 仅由宿主受控管理入口执行，问题通过 stdin 传入；不创建会话、不调用 Crisp。
const {createRuntime} = require('./runtime');

(async () => {
  let bytes = 0;
  const chunks = [];
  for await (const chunk of process.stdin) {
    bytes += chunk.length;
    if (bytes > 16384) throw new Error('管理员测试输入过大');
    chunks.push(chunk);
  }
  const input = JSON.parse(Buffer.concat(chunks).toString('utf8'));
  const runtime = createRuntime(process.env, {allowAdmin: true});
  const result = await runtime.administratorQuery(input.question, input.budget_ms ?? 0);
  process.stdout.write(JSON.stringify(result) + '\n');
})().catch((error) => {
  // 自由格式 HTTP/JSON 异常可能含秘密或知识；只返回白名单类别，不打印消息或堆栈。
  const allowed = new Set([
    'materials_not_ready', 'provider_configuration_invalid', 'state_changed', 'retrieval_error',
    'retrieval_invalid', 'retrieval_unavailable', 'source_unmapped', 'source_ambiguous',
    'context_invalid', 'authentication_failed', 'rate_limited', 'quota_exhausted',
    'model_unavailable', 'upstream_timeout', 'upstream_unavailable', 'connection_failed',
    'invalid_response', 'invalid_input', 'context_preparation_incomplete',
    'configuration_applying', 'pool_cooling', 'pool_exhausted', 'no_capable_provider',
    'question_budget_exhausted', 'question_cancelled', 'safety_refusal', 'protocol_error',
    'provider_inference_failed',
  ]);
  const code = allowed.has(error?.code) ? error.code : 'admin_query_failed';
  process.stdout.write(JSON.stringify({ verified: false, error: { code } }) + '\n');
  process.exitCode = 1;
});
