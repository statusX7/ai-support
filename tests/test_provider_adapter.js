'use strict';

const assert = require('node:assert/strict');
const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const {createAdapter, parseHeaders, chatToResponses} = require('../scripts/provider-adapter.js');

async function main() {
  const root = path.resolve(__dirname, '..');
  fs.mkdirSync(path.join(root, '.work'), {recursive:true});
  const work = fs.mkdtempSync(path.join(root, '.work/provider-adapter-contract-'));
  const configurationPath = path.join(work, 'provider.json');
  fs.writeFileSync(configurationPath, JSON.stringify({schema_version:2,provider:{}}));
  let calls = [], mode='responses', delay=0;
  const upstream = http.createServer(async (request, response) => {
    let text=''; for await (const chunk of request) text += chunk;
    const body=JSON.parse(text || '{}');
    calls.push({path:request.url,body,headers:request.headers});
    if (delay) await new Promise(resolve=>setTimeout(resolve,delay));
    response.setHeader('content-type','application/json');
    if (request.url === '/proxy/v1/responses' && mode === 'responses') response.end(JSON.stringify({id:'synthetic-response',output:[{type:'message',content:[{type:'output_text',text:'协议验证回答'}]}],usage:{input_tokens:4,output_tokens:3,total_tokens:7}}));
    else if (request.url === '/proxy/v1/chat/completions' && mode === 'chat') response.end(JSON.stringify({id:'synthetic-chat',choices:[{message:{content:'Chat 协议验证回答'},finish_reason:'stop'}]}));
    else if (mode === 'redirect') {response.writeHead(302,{location:'http://127.0.0.1:1/leak'});response.end();}
    else if (mode === 'empty') response.end(JSON.stringify({choices:[]}));
    else {response.writeHead(401);response.end(JSON.stringify({error:{message:'secret-do-not-echo'}}));}
  });
  await new Promise(resolve=>upstream.listen(0,'127.0.0.1',resolve));
  const environment={AI_API_BASE_URL:`http://127.0.0.1:${upstream.address().port}/proxy/v1`,AI_API_KEY:'synthetic-key-$#=\\"',AI_MODEL:'synthetic-model',AI_API_MODE:'responses',PROVIDER_CONFIG_PATH:configurationPath,AI_CUSTOM_HEADERS_JSON:'{"X-Synthetic":"fixture"}',PROVIDER_TIMEOUT_MS:'1000'};
  const adapter=createAdapter(environment);
  await new Promise(resolve=>adapter.listen(0,'127.0.0.1',resolve));
  const base=`http://127.0.0.1:${adapter.address().port}`;
  const body={messages:[{role:'system',content:'仅使用当前中文提示词。'},{role:'user',content:'问题一'},{role:'assistant',content:'先前回答'},{role:'user',content:'下一问'}]};
  const post=async value=>fetch(`${base}/v1/chat/completions`,{method:'POST',headers:{authorization:`Bearer ${environment.AI_API_KEY}`,'content-type':'application/json'},body:JSON.stringify(value)});
  let count=0;
  const pass=name=>{count++;process.stdout.write(`通过 UNIT/CONTRACT：${name}\n`);};
  try {
    const response=await post(body);assert.equal(response.status,200);assert.equal((await response.json()).choices[0].message.content,'协议验证回答');assert.equal(calls.at(-1).path,'/proxy/v1/responses');assert.equal(calls.at(-1).body.model,'synthetic-model');assert.deepEqual(calls.at(-1).body.input.map(item=>item.role),['system','user','assistant','user']);pass('Responses-only 最终出站协议、Prompt 和上下文');
    assert.equal(calls.at(-1).headers['x-synthetic'],'fixture');assert.equal(calls.at(-1).headers.authorization,`Bearer ${environment.AI_API_KEY}`);pass('特殊字符 Key 与安全高级请求头');
    const stream=await post({...body,stream:true});assert.equal(stream.status,200);assert.match(await stream.text(),/data: \[DONE\]/);pass('AnythingLLM 流式 Chat 客户端兼容');
    const image='data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=';
    const visual=await post({messages:[{role:'user',content:[{type:'text',text:'识图'},{type:'image_url',image_url:{url:image}}]}]});assert.equal(visual.status,200);assert.equal(calls.at(-1).body.input[0].content[1].type,'input_image');pass('图片内容实际转为 Responses input_image');
    assert.throws(()=>chatToResponses({messages:[{role:'user',content:[{type:'image_url',image_url:{url:'http://169.254.169.254/latest/meta-data'}}]}]}, {model:'test'}));pass('适配器拒绝未经下载校验的外链图片');
    environment.AI_API_MODE='chat_completions';mode='chat';const chat=await post(body);assert.equal(chat.status,200);assert.equal(calls.at(-1).path,'/proxy/v1/chat/completions');pass('Chat-only 实际接线');
    mode='empty';const empty=await post(body);assert.equal(empty.status,502);pass('HTTP 200 空正文拒绝');
    mode='failure';const failure=await post(body);assert.equal(failure.status,401);assert.ok(!(await failure.text()).includes('secret-do-not-echo'));pass('上游错误码保留且响应脱敏');
    mode='redirect';const redirect=await post(body);assert.equal(redirect.status,502);pass('拒绝跨主机重定向');
    assert.throws(()=>parseHeaders({Host:'attacker.invalid'}));assert.throws(()=>parseHeaders({'X-Test':'value\r\nInjected: yes'}));pass('请求头覆盖与换行注入拒绝');
    const rejected=await fetch(`${base}/v1/chat/completions`,{method:'POST',body:JSON.stringify(body)});assert.equal(rejected.status,401);pass('内部请求需要认证');
    mode='chat';delay=1500;const timeout=await post(body);assert.equal(timeout.status,504);pass('模型超时有界失败');
    const callsBeforeInvalid=calls.length;fs.writeFileSync(configurationPath,'invalid-json');
    assert.equal((await fetch(`${base}/healthz`)).status,503);
    assert.equal((await post(body)).status,502);assert.equal(calls.length,callsBeforeInvalid);
    pass('受管配置损坏时健康失败且不静默回退到环境旧值');
    process.stdout.write(`UNIT/CONTRACT 合计 ${count} 通过，0 失败\n`);
  } finally {adapter.closeAllConnections();upstream.closeAllConnections();await new Promise(resolve=>adapter.close(resolve));await new Promise(resolve=>upstream.close(resolve));}
}
main().catch(error=>{console.error(error);process.exitCode=1;});
