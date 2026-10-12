'use strict';

const assert = require('node:assert/strict');
const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const zlib = require('node:zlib');
const {createAdapter, parseHeaders, chatToResponses, mechanicalFailureAnswer} = require('../scripts/provider-adapter.js');
const {VISITOR_FALLBACKS, visitorFallbackFor, mechanicalFailureAnswer: sharedMechanicalFailureAnswer,
  legacyGenericNonAnswer, sanitizeVisitorText} = require('../scripts/visitor-output.js');

async function main() {
  const root = path.resolve(__dirname, '..');
  fs.mkdirSync(path.join(root, '.work'), {recursive:true});
  const work = fs.mkdtempSync(path.join(root, '.work/provider-adapter-contract-'));
  const configurationPath = path.join(work, 'provider.json');
  fs.writeFileSync(configurationPath, JSON.stringify({schema_version:2,provider:{}}));
  let calls = [], mode='responses', delay=0, answer='协议验证回答';
  let responseEncoding='identity', chatFields={}, probeNeedsReasoning=false;
  let temperatureFailure=null, temperatureStatus=400, temperatureBlockConfiguration=false;
  const upstream = http.createServer(async (request, response) => {
    let text=''; for await (const chunk of request) text += chunk;
    const body=JSON.parse(text || '{}');
    calls.push({path:request.url,body,headers:request.headers});
    if (delay) await new Promise(resolve=>setTimeout(resolve,delay));
    response.setHeader('content-type','application/json');
    const sendJson = async (value,status=200) => {
      response.statusCode=status;
      const raw=Buffer.from(JSON.stringify(value));
      if(responseEncoding==='corrupt-gzip') {
        response.setHeader('content-encoding','gzip');response.end(Buffer.from('not-a-gzip-stream'));return;
      }
      let encoded=raw;
      if(responseEncoding==='gzip')encoded=zlib.gzipSync(raw);
      else if(responseEncoding==='deflate')encoded=zlib.deflateSync(raw);
      else if(responseEncoding==='br')encoded=zlib.brotliCompressSync(raw);
      else if(responseEncoding==='slow-gzip')encoded=zlib.gzipSync(raw);
      else if(responseEncoding==='multiple')encoded=zlib.gzipSync(raw);
      if(responseEncoding!=='identity')response.setHeader('content-encoding',
        responseEncoding==='multiple'?'gzip, br':responseEncoding==='unknown'?'zstd':
          responseEncoding==='slow-gzip'?'gzip':responseEncoding);
      if(responseEncoding==='slow-gzip') {
        const split=Math.max(1,Math.floor(encoded.length/2));
        response.write(encoded.subarray(0,split));
        await new Promise(resolve=>setTimeout(resolve,1500));
        response.end(encoded.subarray(split));return;
      }
      response.end(encoded);
    };
    if (temperatureFailure && Object.hasOwn(body,'temperature')) {
      if (temperatureBlockConfiguration) {
        fs.mkdirSync(path.join(work,'config'),{recursive:true});
        fs.writeFileSync(path.join(work,'config/provider-pool-transaction.json'),'{}');
      }
      await sendJson({error:temperatureFailure},temperatureStatus);return;
    }
    if (probeNeedsReasoning && (body.max_output_tokens || body.max_tokens) < 128) {
      if (mode === 'responses') await sendJson({status:'incomplete',incomplete_details:{reason:'max_output_tokens'},
        output:[{type:'reasoning',summary:[]}],usage:{output_tokens:64,output_tokens_details:{reasoning_tokens:64}}});
      else await sendJson({choices:[{message:{role:'assistant',content:'',reasoning_content:'合成推理'},finish_reason:'length'}]});
    }
    else if (request.url === '/proxy/v1/responses' && mode === 'responses') await sendJson({id:'synthetic-response',output:[{type:'message',content:[{type:'output_text',text:answer}]}],usage:{input_tokens:4,output_tokens:3,total_tokens:7}});
    else if (request.url === '/proxy/v1/chat/completions' && mode === 'chat') await sendJson({id:'synthetic-chat',choices:[{message:{content:answer,...chatFields},finish_reason:'stop'}]});
    else if (mode === 'redirect') {response.writeHead(302,{location:'http://127.0.0.1:1/leak'});response.end();}
    else if (mode === 'empty') await sendJson({choices:[]});
    else await sendJson({error:{message:'secret-do-not-echo'}},401);
  });
  await new Promise(resolve=>upstream.listen(0,'127.0.0.1',resolve));
  // 固定到本夹具自己的实例根，避免发布验收机上真实 /opt/crisp-ai 接口池
  // 将这个旧单接口协议测试误切换为池模式。
  const environment={AI_API_BASE_URL:`http://127.0.0.1:${upstream.address().port}/proxy/v1`,AI_API_KEY:'synthetic-key-$#=\\"',AI_MODEL:'synthetic-model',AI_API_MODE:'responses',PROVIDER_ROOT:work,PROVIDER_CONFIG_PATH:configurationPath,AI_CUSTOM_HEADERS_JSON:'{"X-Synthetic":"fixture"}',PROVIDER_TIMEOUT_MS:'1000'};
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
    environment.AI_API_MODE='chat_completions';mode='chat';answer='Chat 协议验证回答';const chat=await post(body);assert.equal(chat.status,200);assert.equal(calls.at(-1).path,'/proxy/v1/chat/completions');pass('Chat-only 实际接线');
    answer='空工具数组仍是完整业务答案';chatFields={tool_calls:[]};
    const emptyTools=await post(body);assert.equal(emptyTools.status,200);
    assert.equal((await emptyTools.json()).choices[0].message.content,answer);
    for(const invalid of [
      {tool_calls:[{id:'call-fixture',type:'function',function:{name:'unsafe',arguments:'{}'}}]},
      {tool_calls:{}},{tool_calls:'[]'},{function_call:{}},{function_call:''},
    ]) {
      chatFields=invalid;assert.equal((await post(body)).status,502,
        '非空或畸形工具字段必须失败关闭');
    }
    chatFields={tool_calls:null,function_call:null};
    assert.equal((await post(body)).status,200,'null 工具字段与缺失字段等价');
    chatFields={};pass('P01 空 tool_calls 合法，真实或畸形工具请求失败关闭');

    for(const item of [
      {protocol:'chat_completions',mode:'chat',encoding:'gzip'},
      {protocol:'responses',mode:'responses',encoding:'deflate'},
      {protocol:'responses',mode:'responses',encoding:'br'},
    ]) {
      environment.AI_API_MODE=item.protocol;mode=item.mode;responseEncoding=item.encoding;
      answer=`${item.encoding} 压缩响应中的完整中文答案`;
      const compressed=await post(body);assert.equal(compressed.status,200,item.encoding);
      assert.equal((await compressed.json()).choices[0].message.content,answer,item.encoding);
    }
    environment.AI_API_MODE='chat_completions';mode='chat';answer='压缩协议负例正文';
    for(const encoding of ['unknown','multiple','corrupt-gzip']) {
      responseEncoding=encoding;
      assert.equal((await post(body)).status,502,encoding+' 必须失败关闭');
    }
    responseEncoding='gzip';answer='x'.repeat(8*1024*1024);
    assert.equal((await post(body)).status,502,'解压后超过8MiB必须在JSON解析前拒绝');
    responseEncoding='slow-gzip';answer='压缩响应头之后仍在等待的正文';
    assert.equal((await post(body)).status,504,'压缩半流超时必须保持timeout分类');
    responseEncoding='identity';answer='Chat 协议验证回答';
    pass('U01 gzip/deflate/br按解压后容量读取，未知、多重、损坏及炸弹拒绝');
    environment.PROVIDER_POOL_REQUIRED='true';environment.PROVIDER_ADAPTER_KEY='synthetic-management-key';
    probeNeedsReasoning=true;
    try {
      for (const protocol of ['responses','chat_completions']) {
        mode=protocol==='responses'?'responses':'chat';
        const provider={base_url:environment.AI_API_BASE_URL,model:'synthetic-reasoning-model',api_mode:protocol,
          context_window:65535,max_output_tokens:1200,capabilities:{chat_completions:true,responses:true,vision:true}};
        const probe=async (maximum,vision=true)=>fetch(`${base}/internal/provider/probe`,{method:'POST',
          headers:{authorization:'Bearer '+environment.PROVIDER_ADAPTER_KEY,'content-type':'application/json'},
          body:JSON.stringify({provider:{...provider,max_output_tokens:maximum},api_key:'synthetic-probe-key',vision})});
        const accepted=await probe(1200);assert.equal(accepted.status,200);
        assert.equal((await accepted.json()).verified,true);
        const budgetField=protocol==='responses'?'max_output_tokens':'max_tokens';
        assert.equal(calls.at(-1).body[budgetField],1200);
        assert.equal(calls.at(-1).body.model,provider.model);
        assert.equal(calls.at(-1).headers.authorization,'Bearer synthetic-probe-key');
        const beforeRejected=calls.length;
        const rejected=await probe(64);assert.equal(rejected.ok,false);
        assert.equal((await rejected.json()).error.code,'invalid_response');
        assert.equal(calls.at(-1).body[budgetField],64,'不得擅自超过管理员配置的输出额度');
        assert.equal(calls.length,beforeRejected+1,'预算不足必须明确失败，不能无限重试');
        const bounded=await probe(9000,false);assert.equal(bounded.status,200);
        assert.equal(calls.at(-1).body[budgetField],1200,'探针不能继承无限放大的输出额度');
      }
      pass('管理探针保留推理输出预算，Chat/Responses及图片遵守候选额度与1200上限，空正文仍拒绝');
    } finally {
      delete environment.PROVIDER_POOL_REQUIRED;delete environment.PROVIDER_ADAPTER_KEY;
      probeNeedsReasoning=false;environment.AI_API_MODE='chat_completions';mode='chat';
    }
    const originalModel=environment.AI_MODEL,originalKey=environment.AI_API_KEY;
    const unsupportedTemperature={type:'invalid_request_error',param:'temperature',message:'Unsupported parameter: temperature is not supported with this model.'};
    try {
      temperatureFailure=unsupportedTemperature;
      for (const protocol of ['responses','chat_completions']) {
        environment.AI_API_MODE=protocol;mode=protocol==='responses'?'responses':'chat';
        environment.AI_MODEL='temperature-'+protocol;
        const input={...body,temperature:0.7},beforeInput=JSON.stringify(input),before=calls.length;
        const adapted=await post(input);assert.equal(adapted.status,200);
        const attempts=calls.slice(before);assert.equal(attempts.length,2);
        assert.equal(attempts[0].body.temperature,0.7);assert.equal(Object.hasOwn(attempts[1].body,'temperature'),false);
        assert.deepEqual(attempts[0].body.input||attempts[0].body.messages,attempts[1].body.input||attempts[1].body.messages);
        assert.equal(attempts[0].body.model,attempts[1].body.model);assert.equal(JSON.stringify(input),beforeInput);
        const beforeCached=calls.length;assert.equal((await post(input)).status,200);
        assert.equal(calls.length,beforeCached+1);assert.equal(Object.hasOwn(calls.at(-1).body,'temperature'),false);
        environment.AI_API_KEY=originalKey+'-rotated';
        const beforeRotated=calls.length;assert.equal((await post(input)).status,200);
        assert.equal(calls.length,beforeRotated+2,'新认证身份不能继承旧能力假设');
        assert.equal(calls[beforeRotated].body.temperature,0.7);
        environment.AI_API_KEY=originalKey;
      }
      temperatureFailure=null;environment.AI_MODEL='temperature-supported';
      const supportedBefore=calls.length;assert.equal((await post({...body,temperature:0.7})).status,200);
      assert.equal(calls.length,supportedBefore+1);assert.equal(calls.at(-1).body.temperature,0.7);
      pass('显式温度不兼容只在同候选省略该参数重试一次，双协议、缓存和认证隔离保留正常模型温度');

      for(const [status,param] of [[400,'input'],[401,'temperature']]) {
        environment.AI_MODEL='rejected-parameter-'+status;
        temperatureStatus=status;temperatureFailure={...unsupportedTemperature,param};
        const before=calls.length;assert.equal((await post({...body,temperature:0.7})).status,status);
        assert.equal(calls.length,before+1,'认证或真正输入错误不能被兼容重试掩盖');
      }
      pass('认证失败和非温度输入错误不触发参数删除或额外请求');

      temperatureStatus=400;temperatureFailure=unsupportedTemperature;
      environment.AI_MODEL='bounded-parameter';delay=600;
      const beforeTimeout=calls.length;assert.equal((await post({...body,temperature:0.7})).status,504);
      assert.equal(calls.length,beforeTimeout+2);delay=0;
      pass('参数兼容的第二次请求只使用首轮剩余时间，不重置总期限');

      environment.PROVIDER_POOL_REQUIRED='true';environment.PROVIDER_ADAPTER_KEY='synthetic-management-key';
      temperatureBlockConfiguration=true;
      const beforeConfiguration=calls.length;
      const blocked=await fetch(`${base}/internal/provider/probe`,{method:'POST',
        headers:{authorization:'Bearer '+environment.PROVIDER_ADAPTER_KEY,'content-type':'application/json'},
        body:JSON.stringify({provider:{base_url:environment.AI_API_BASE_URL,model:'configuration-parameter',
          api_mode:'chat_completions',context_window:8192,max_output_tokens:1200,
          capabilities:{chat_completions:true,responses:false,vision:false}},api_key:'synthetic-probe-key'})});
      assert.equal(blocked.status,400);assert.equal((await blocked.json()).error.code,'configuration_applying');
      assert.equal(calls.length,beforeConfiguration+1,'配置应用中不得启动参数兼容第二请求');
      pass('保存探针携带业务温度，配置变化仍立即阻止第二次请求');
    } finally {
      delete environment.PROVIDER_POOL_REQUIRED;delete environment.PROVIDER_ADAPTER_KEY;
      environment.AI_MODEL=originalModel;environment.AI_API_KEY=originalKey;
      environment.AI_API_MODE='chat_completions';mode='chat';delay=0;
      temperatureFailure=null;temperatureStatus=400;temperatureBlockConfiguration=false;
      const marker=path.join(work,'config/provider-pool-transaction.json');
      if(fs.existsSync(marker))fs.unlinkSync(marker);
    }
    const mechanical = ['暂时无法回复，请稍后再试。', '  抱歉，暂时无法回复，请稍后再试。谢谢理解！  ',
      '系\u200b统　正忙，请稍后再试，谢谢理解。', '当前暂时不能答复，建议过一会儿再试。',
      '服务开了小差，请过会儿再试。', '很抱歉，我们目前没有办法为您提供帮助，请您耐心等待。',
      '抱歉呀，客服系统有点忙，您过会儿再咨询吧。', '由于系统繁忙，现在暂时无法回答您的问题，请稍候。',
      '服务器繁忙，请稍后再试。', '暂时无法进行回复，稍后重试。', '系统出了点小差，请稍后再试。',
      '系统维护中，请稍后再试。', '模型繁忙，请过会再试。', 'AI暂时无法回复，请稍后再试。',
      '机器人开小差了，稍后重试。', '请稍后再试。', 'ＡＩ暂时无法答复，过会再试。',
      'A\u0000I暂时无法回\u0007复，请稍后再试。', '系统正在升级，请稍后再试。',
      '系统拥堵，请稍后再试。', '请求人数较多，请稍后再试。', '网络开小差了，请稍后再试。',
      '后台维护中，请稍后再试。', '系统超时，请稍后重试。',
      'AI暂时无法回答您的曜石展柜问题，请稍后再试。', '客服暂时无法回答关于月桥通行牌的问题，请稍后再试。',
      '我现在没法回答这个，过一会儿再问吧。', '这会儿答不了，晚点再问我。',
      '服务开小差，待会再试一次。', '我暂时回答不了你的问题，请等一下再问。',
      '抱歉，我现在答不上来，晚点再问吧。', '目前没办法回复你，待会儿再问。'];
    const substantive = ['网站显示“系统繁忙，请稍后再试”时，请检查网络设置并刷新页面。',
      '设置保存后可能需要几十秒生效；如页面仍显示旧值，刷新后再试。',
      '虚构月桥暂时不开放东门，请从西门进入。', '虚构蓝羽核验口当前不可用，请改用南侧人工检票口。',
      '抱歉，我无法回答这个问题。', '抱歉，我无法回答关于制造武器的问题。', '我不能回答您的账户问题。',
      '当前平台不可用。', '当前服务不可用，预计十分钟恢复。',
      '当前平台升级中。', '当前服务超时。', '请求人数较多。',
      '你最希望先解决哪一处？可以把具体情况、相关提示和已经尝试的方法一起告诉我。'];
    assert.equal(mechanicalFailureAnswer,sharedMechanicalFailureAnswer,'adapter 必须直接复用公共分类函数');
    assert(mechanical.every(mechanicalFailureAnswer));assert(substantive.every(value=>!mechanicalFailureAnswer(value)));
    assert(Object.values(VISITOR_FALLBACKS).every(value=>!mechanicalFailureAnswer(value)));
    assert.equal(visitorFallbackFor('handoff_ack'),VISITOR_FALLBACKS.handoff_ack);
    assert.equal(visitorFallbackFor('menu'),VISITOR_FALLBACKS.menu);
    const retiredGeneric='你最希望先解决哪一处？可以把具体情况、相关提示和已经尝试的方法一起告诉我。';
    assert.equal(legacyGenericNonAnswer(retiredGeneric),true,'CASE-K02 旧泛问必须由最终访客输出分类器明确识别');
    const mixed='暂时无法回复，请稍后再试。您可以查看帮助中心。';
    assert.equal(sanitizeVisitorText(mixed),mixed,'成功正文不能按句删除后伪造成另一份模型答案');
    for(const value of ['虚构月桥暂时不开放东门。','网站显示“暂时无法回复，请稍后再试。”时，请检查网络设置。'])
      assert.equal(sanitizeVisitorText(value),value,'业务事实或引述不得被输出守卫篡改');
    const compose=fs.readFileSync(path.join(root,'docker-compose.yml'),'utf8');
    assert.match(compose,/scripts\/visitor-output\.js:\/opt\/crisp-ai\/scripts\/visitor-output\.js:ro/);
    for(const protocol of ['chat_completions','responses']) {
      environment.AI_API_MODE=protocol;mode=protocol==='responses'?'responses':'chat';
      for(const failure of mechanical) {
        answer=failure;assert.equal((await post(body)).status,502,protocol+' 机械故障正文必须按无效响应拒绝');
      }
      answer=retiredGeneric;assert.equal((await post(body)).status,502,protocol+' 旧泛问正文必须在 adapter 出口拒绝');
      answer=substantive[protocol==='responses'?0:1];const allowed=await post(body);assert.equal(allowed.status,200);
      assert.equal((await allowed.json()).choices[0].message.content,answer);
      answer=mixed;const sanitized=await post(body);assert.equal(sanitized.status,200);
      assert.equal((await sanitized.json()).choices[0].message.content,mixed);
      answer='页面若显示“系统维护中，请稍后再试”，请先核对虚构蓝灯是否常亮。\n蓝灯常亮时改用南侧入口。';
      const quoted=await post(body);assert.equal(quoted.status,200);
      assert.equal((await quoted.json()).choices[0].message.content,answer,'adapter 不得逐句删除成功正文或重排换行');
      answer='抱歉，我无法回答这个问题。';const refusal=await post(body);assert.equal(refusal.status,200);
      assert.equal((await refusal.json()).choices[0].message.content,answer);
    }
    pass('Chat/Responses 仅拒绝整条机械故障，成功业务正文逐字保持');
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
