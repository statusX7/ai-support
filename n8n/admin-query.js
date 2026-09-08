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
})().catch(() => {
  // 自由格式 HTTP/JSON 异常可能含秘密或知识；只返回固定错误，不打印堆栈。
  process.stderr.write('知识问答测试未完成；请检查当前检索、接口或配置应用状态。\n');
  process.exitCode = 1;
});
