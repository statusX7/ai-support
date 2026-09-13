'use strict';

// 生产 runtime → HTTP 知识检索 → runtime → 生产 adapter → HTTP 上游；不是真实 AnythingLLM/Crisp E2E。
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const http = require('node:http');
const {spawn} = require('node:child_process');
const {createRuntime} = require('../n8n/runtime');
const {createAdapter} = require('../scripts/provider-adapter');
const {verifyEnvelope} = require('../scripts/provider-envelope');
const project = path.resolve(__dirname,'..');
const area = path.join(project,'.work/v1.2.1');
fs.mkdirSync(area,{recursive:true});
const base = fs.mkdtempSync(path.join(area,'runtime-pool-'));
const write = (file,value) => {fs.mkdirSync(path.dirname(file),{recursive:true});fs.writeFileSync(file,JSON.stringify(value),{mode:0o600});};
const read = file => JSON.parse(fs.readFileSync(file));
const wait = ms => new Promise(resolve=>setTimeout(resolve,ms));
const png = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=','base64');
const execute = args => new Promise(resolve=>{
  const child=spawn('python3',[path.join(project,'scripts/provider-pool.py'),...args]);
  let stdout='',stderr='';child.stdout.on('data',chunk=>stdout+=chunk);child.stderr.on('data',chunk=>stderr+=chunk);
  child.on('close',code=>resolve({code,stdout,stderr}));
});

async function fixture(label) {
  const root=path.join(base,label), calls=[], sent=[], histories=new Map(), tasks=[];
  for(const name of ['config','data/runtime','data/analytics','tmp'])fs.mkdirSync(path.join(root,name),{recursive:true});
  for(const name of ['keyword','handoff','menu','tags','feedback'])fs.copyFileSync(path.join(project,`config/${name}.yaml.example`),path.join(root,`config/${name}.yaml`));
  const menu=read(path.join(root,'config/menu.yaml'));menu.welcome.enabled=false;write(path.join(root,'config/menu.yaml'),menu);
  const prompt='用户原文规则：结合知识与公开历史回答。';fs.writeFileSync(path.join(root,'config/prompt.md'),prompt);
  write(path.join(root,'config/runtime.yaml'),{schema_version:2,enabled:true,revision:1,applied_revision:1});
  const projection='kb_1111111111111111_doc_2222222222222222.md';
  write(path.join(root,'data/runtime/knowledge-map.json'),{schema_version:2,revision:1,documents:[{
    library_id:'kb_1111111111111111',library_name:'合成处理资料',document_id:'doc_2222222222222222',projection,
    location:'custom-documents/'+projection+'-33333333-3333-4333-8333-333333333333.json',
  }]});
  let sequence=10000, runtime;
  const f={root,calls,sent,histories,tasks,failed:new Set(),slow:false,delay:400,failAnswer:false,adapterRestarts:0,answerRequests:[],answerResponses:[],sendAttempts:0,metaCalls:0,unknownSend:false,tagFailure:false};
  const upstream=http.createServer(async(req,res)=>{
    let raw='';for await(const chunk of req)raw+=chunk;const body=JSON.parse(raw||'{}');
    const index=Number(/^\/p(\d)\//.exec(req.url)?.[1]);
    const messages=body.messages||body.input;
    const visual=messages.some(message=>Array.isArray(message.content)&&message.content.some(part=>['image_url','input_image'].includes(part.type)));
    const call={index,body,visual,authorization:req.headers.authorization,at:Date.now()};calls.push(call);
    if(f.behavior&&await f.behavior(call,res)===true)return;
    if(f.slow)await wait(f.delay);
    res.setHeader('content-type','application/json');
    if(f.failed.has(index)||f.failAnswer&&!visual){res.writeHead(503);res.end(JSON.stringify({error:{code:'server_error'}}));return;}
    const text=visual?'合成图片中是蓝色保存按钮。':'受控业务答案：保存后重试。';
    res.end(JSON.stringify(req.url.endsWith('/responses')?{status:'completed',output_text:text}:{choices:[{message:{role:'assistant',content:text}}]}));
  });
  await new Promise(resolve=>upstream.listen(0,'127.0.0.1',resolve));
  const upstreamBase=`http://127.0.0.1:${upstream.address().port}`;
  fs.writeFileSync(path.join(root,'.env'),`AI_API_BASE_URL=${upstreamBase}/p0/v1\nAI_API_PROBE_BASE_URL=${upstreamBase}/p0/v1\nAI_API_KEY=synthetic-primary-key\nAI_MODEL=synthetic-primary\nAI_API_MODE=chat_completions\n`);
  write(path.join(root,'config/provider.yaml'),{schema_version:2,provider:{base_url:upstreamBase+'/p0/v1',model:'synthetic-primary',api_mode:'chat_completions',capabilities:{chat_completions:true,responses:false,vision:true}}});
  const result=await execute(['--deploy-dir',root,'migrate']);assert.equal(result.code,0,result.stderr+result.stdout);
  const poolPath=path.join(root,'config/provider-pool-applied.json');let pool=read(poolPath);
  const secretPath=path.join(root,'secrets/provider/generations',pool.secrets_generation+'.json'),secrets=read(secretPath);
  for(let n=1;n<=2;n++){
    const id='p_'+String(n).repeat(24);
    pool.entries.push({...pool.entries[0],id,name:'合成备用'+n,role:'backup',order:n,base_url:upstreamBase+`/p${n}/v1`,model:'synthetic-backup-'+n,api_mode:n===2?'responses':'chat_completions',capabilities:{chat_completions:n!==2,responses:n===2,vision:true}});
    secrets.entries[id]={api_key:'synthetic-backup-key-'+n,custom_headers:{}};
  }
  write(secretPath,secrets);write(poolPath,pool);
  const internal=/^PROVIDER_ADAPTER_KEY=(.*)$/m.exec(fs.readFileSync(path.join(root,'.env'),'utf8'))[1];
  let adapter,adapterBase;
  const startAdapter=async()=>{
    adapter=createAdapter({PROVIDER_ROOT:root,PROVIDER_ADAPTER_KEY:internal,PROVIDER_POOL_REQUIRED:'true',PROVIDER_REQUIRE_ENVELOPE:'true'});
    await new Promise(resolve=>adapter.listen(0,'127.0.0.1',resolve));adapterBase=`http://127.0.0.1:${adapter.address().port}`;
  };
  await startAdapter();
  const postAdapter=async(body,headers={},timeout=10000)=>{
    const response=await fetch(adapterBase+'/v1/chat/completions',{method:'POST',headers:{Authorization:'Bearer '+internal,'content-type':'application/json',...headers},body:JSON.stringify(body),signal:AbortSignal.timeout(timeout)});
    return{status:response.status,body:await response.json()};
  };
  const rag=http.createServer(async(req,res)=>{
    assert.equal(req.headers.authorization,'Bearer synthetic-rag-key');
    if(req.method==='GET'){
      assert.equal(req.url,'/api/v1/workspace/synthetic');
      res.writeHead(200,{'content-type':'application/json'});res.end(JSON.stringify({workspace:{slug:'synthetic',openAiTemp:0.35}}));return;
    }
    let raw='';for await(const chunk of req)raw+=chunk;const body=JSON.parse(raw);tasks.push(body);
    assert.equal(req.method,'POST');assert.equal(req.url,'/api/v1/workspace/synthetic/vector-search');
    assert.equal(typeof body.query,'string');assert(!JSON.stringify(body).includes('CRISPAI_PROVIDER_CONTEXT'));
    // 固定官方检索响应；该服务不生成答案、不持有内部 adapter Key，也不构造信封。
    res.writeHead(200,{'content-type':'application/json'});res.end(JSON.stringify({results:[{
      id:'44444444-4444-4444-8444-444444444444',text:'合成处理码是蓝色，保存后可再次尝试。',
      metadata:{title:projection},distance:0.1,score:0.9,
    }]}));
  });
  await new Promise(resolve=>rag.listen(0,'127.0.0.1',resolve));
  const env={CRISP_WEBSITE_ID:'11111111-1111-4111-8111-111111111111',CRISP_WEBSITE_HOOK_SECRET:'synthetic-hook-only',CRISP_AUTH_B64:'synthetic-crisp-auth',ANYTHINGLLM_WORKSPACE:'synthetic',ANYTHINGLLM_API_KEY:'synthetic-rag-key',PROVIDER_ADAPTER_KEY:internal,PROVIDER_POOL_REQUIRED:'true',PROVIDER_ADAPTER_URL:adapterBase+'/v1',ANYTHINGLLM_INTERNAL_URL:`http://127.0.0.1:${rag.address().port}`};
  const request=async(url,options={})=>{
    const parsed=new URL(url);
    if(parsed.hostname==='storage.crisp.chat')return{status:200,headers:{'content-type':'image/png'},body:png};
    if(parsed.hostname==='api.crisp.chat'){
      const match=parsed.pathname.match(/\/conversation\/([^/]+)(\/.*)$/);assert(match);
      const session=match[1],suffix=match[2],history=histories.get(session)||[];
      if(suffix==='/messages')return{status:200,body:{error:false,data:history}};
      if(suffix.startsWith('/message/'))return{status:200,body:{error:false,data:history.find(x=>String(x.fingerprint)===suffix.slice(9))||{}}};
      if(suffix==='/meta'){f.metaCalls++;return{status:f.tagFailure?403:200,body:{error:f.tagFailure,data:{segments:['external-tag']}}};}
      if(suffix==='/message'){
        f.sendAttempts++;
        const entry={...structuredClone(options.body),session_id:session,timestamp:Date.now()};sent.push(entry);history.push(entry);histories.set(session,history);
        if(f.unknownSend){f.unknownSend=false;throw new Error('受控Crisp已记录消息但发送回执超时');}
        return{status:200,body:{error:false,reason:'dispatched',data:{fingerprint:entry.fingerprint}}};
      }
      throw Error('未知合成 Crisp 路由');
    }
    assert.equal(parsed.hostname,'127.0.0.1');
    if(options.headers?.['x-crispai-question']){
      assert.equal(parsed.pathname,'/v1/chat/completions');
      const captured={body:structuredClone(options.body),headers:structuredClone(options.headers),envelope:verifyEnvelope(options.headers['x-crispai-question'],internal)};
      if(captured.envelope.stage==='vision')f.visionRequest=captured;
      else {
        assert.equal(captured.envelope.stage,'answer');assert.equal(captured.body.temperature,0.35);f.answerRequests.push(structuredClone(captured));
        if(f.beforeAnswer)await f.beforeAnswer(captured);
        // 在实际 adapter 之前扰动载荷，以保留完整 Prompt 守卫负例。
        if(f.answerSystem!==undefined)captured.body.messages[0].content=f.answerSystem;
      }
      // 重启会更换本地随机端口；始终解析当前 adapter，模拟部署中不变的服务地址。
      const response=await postAdapter(captured.body,captured.headers,options.timeout||10000);
      if(captured.envelope.stage==='answer')f.answerResponses.push(response);
      return response;
    }
    const response=await fetch(url,{method:options.method||'GET',headers:{'content-type':'application/json',...options.headers},body:options.body?JSON.stringify(options.body):undefined,signal:AbortSignal.timeout(options.timeout||10000)});
    return{status:response.status,body:await response.json()};
  };
  f.restart=()=>{runtime=createRuntime(env,{root,request,lookup:(_host,_opts,callback)=>callback(null,[{address:'8.8.8.8',family:4}])});};f.restart();
  f.restartAdapter=async()=>{adapter.closeAllConnections();await new Promise(resolve=>adapter.close(resolve));await startAdapter();env.PROVIDER_ADAPTER_URL=adapterBase+'/v1';f.adapterRestarts++;};
  f.replayVision=()=>postAdapter(f.visionRequest.body,{'x-crispai-question':f.visionRequest.headers['x-crispai-question']});
  f.decode=token=>verifyEnvelope(token,internal);
  f.question=id=>read(path.join(root,'data/provider-router/questions',id+'.json'));
  f.process=(key,id)=>runtime.process(key,id);
  f.scan=()=>runtime.scan();
  f.event=(session,content,extra={})=>({website_id:env.CRISP_WEBSITE_ID,event:'message:send',timestamp:Date.now(),data:{session_id:session.replace(/^session_pool_/,'session_pool-'),from:'user',type:'text',content,fingerprint:++sequence,timestamp:Date.now(),...extra}});
  f.receive=async body=>{if(body.event==='message:send'||body.data.from==='operator'){const items=histories.get(body.data.session_id)||[];items.push(body.data);histories.set(body.data.session_id,items);}return runtime.receive({body,query:{key:env.CRISP_WEBSITE_HOOK_SECRET}});};
  f.deliver=async body=>{const accepted=await f.receive(body);assert.equal(accepted.accepted,true);return accepted.route==='process'?runtime.process(accepted.key,accepted.jobId):accepted;};
  f.state=session=>runtime.readState(runtime.stateKey(env.CRISP_WEBSITE_ID,session.replace(/^session_pool_/,'session_pool-')));
  f.publish=change=>{pool=read(poolPath);change(pool);pool.revision++;secrets.revision=pool.revision;write(secretPath,secrets);write(poolPath,pool);};
  f.close=async()=>{for(const server of [rag,adapter,upstream])server.closeAllConnections();await Promise.all([rag,adapter,upstream].map(server=>new Promise(resolve=>server.close(resolve))));};
  return f;
}

let passed=0;
async function test(name,action){const f=await fixture('case-'+passed);try{await action(f);passed++;console.log('通过 UNIT/PROTOCOL：'+name);}finally{await f.close();}}
(async()=>{
  await test('文本经官方检索结构/生产签名/主备到Responses，唯一答案且无评价',async f=>{
    f.failed=new Set([0,1]);assert.equal((await f.deliver(f.event('session_pool_text1','请说明保存操作。'))).status,'sent');
    assert.deepEqual(f.calls.map(x=>x.index),[0,1,2]);assert.equal(f.sent.length,1);assert.equal(f.sent[0].content,'受控业务答案：保存后重试。');
    assert.equal(f.calls[2].body.model,'synthetic-backup-2');assert(!JSON.stringify(f.calls).includes('CRISPAI_PROVIDER_CONTEXT'));assert(!f.sent[0].content.includes('是否解决'));
    await f.deliver(f.event('session_pool_text1','是'));assert.equal(f.sent.length,2);assert.equal(f.tasks.length,2);
    assert.equal(f.tasks[0].query,'请说明保存操作。');assert.equal(f.tasks[1].query,'是');
    assert(f.answerRequests[1].body.messages.some(message=>message.role==='user'&&message.content.includes('保存操作')));
    assert.equal(f.answerRequests[1].body.messages.at(-1).content,'是');
    assert.equal(f.answerRequests[0].envelope.stage,'answer');assert.equal(f.answerRequests[0].body.messages[0].content,'用户原文规则：结合知识与公开历史回答。');
    assert(JSON.stringify(f.calls[2].body).includes('合成处理码是蓝色'));
  });
  await test('adapter前丢失业务Prompt时不推理或遍历备用，仅自然澄清且重启不重识图',async f=>{
    f.answerSystem='用户原文规则：\n--prompt truncated for brevity--\n公开历史回答。';
    const event=f.event('session_pool_prompt1','合成普通问题');
    assert.equal((await f.deliver(event)).status,'sent');assert.equal(f.calls.length,0);assert.equal(f.sent.length,1);
    assert.equal(f.answerResponses[0].status,400);assert.equal(f.answerResponses[0].body.error.code,'context_preparation_incomplete');
    assert.equal(f.sent[0].content,'你最希望先解决哪一处？可以把具体情况、相关提示和已经尝试的方法一起告诉我。');assert.equal(f.state(event.data.session_id).mode,'ai');
    f.restart();await f.deliver(event);assert.equal(f.calls.length,0);assert.equal(f.sent.length,1);assert.equal(f.tasks.length,1);
    const imageEvent=f.event('session_pool_promptimage',{type:'image/png',url:'https://storage.crisp.chat/synthetic.png'},{type:'file'});
    assert.equal((await f.deliver(imageEvent)).status,'sent');assert.equal(f.calls.length,1);assert.equal(f.calls[0].visual,true);
    assert.equal(f.answerResponses[1].body.error.code,'context_preparation_incomplete');assert.equal(f.sent.length,2);assert.equal(f.state(imageEvent.data.session_id).image_context.length,1);
    assert.equal(f.state(imageEvent.data.session_id).mode,'ai');f.restart();await f.deliver(imageEvent);
    assert.equal(f.calls.length,1);assert.equal(f.sent.length,2);assert.equal(f.tasks.length,2);
  });
  await test('视觉与RAG回答共享三次上限、重启不重复识图或重放答案',async f=>{
    f.publish(pool=>{pool.policy.max_attempts=3;});f.failed=new Set([0]);f.failAnswer=true;
    const event=f.event('session_pool_image1',{type:'image/png',url:'https://storage.crisp.chat/synthetic.png'},{type:'file'});
    await f.deliver(event);assert.equal(f.calls.length,3);assert.equal(f.calls.filter(x=>x.visual).length,2);assert.equal(f.sent.length,1);assert.equal(f.state(event.data.session_id).mode,'ai');
    assert(f.tasks[0].query.includes('蓝色保存按钮'));f.restart();await f.deliver(event);assert.equal(f.calls.length,3);assert.equal(f.sent.length,1);
  });
  await test('主备等待时真人优先暂停A，B独立回复，不续尝试不发送迟到A答案',async f=>{
    f.slow=true;f.failed=new Set([0]);const pending=f.deliver(f.event('session_pool_humanA','慢问题'));
    while(!f.calls.length)await wait(5);
    const human=f.event('session_pool_humanA','真人公开处理进度',{from:'operator',automated:false});human.event='message:received';
    const started=Date.now();await f.deliver(human);assert(Date.now()-started<300);assert.equal(f.state('session_pool_humanA').mode,'human');await pending;
    assert.equal(f.calls.length,1);assert.equal(f.sent.length,0);
    f.slow=false;await f.deliver(f.event('session_pool_humanB','另一个会话的问题'));assert.equal(f.sent.length,1);assert.equal(f.sent[0].session_id,'session_pool-humanB');
  });
  await test('总关与池配置变更取消整条推理；不误发一次错误提示',async f=>{
    f.slow=true;const pending=f.deliver(f.event('session_pool_global','慢问题'));while(!f.calls.length)await wait(5);
    write(path.join(f.root,'config/runtime.yaml'),{schema_version:2,enabled:false,revision:2,applied_revision:2});await pending;assert.equal(f.calls.length,1);assert.equal(f.sent.length,0);
    write(path.join(f.root,'config/runtime.yaml'),{schema_version:2,enabled:true,revision:3,applied_revision:3});
    const changed=f.deliver(f.event('session_pool_changed','另一个慢问题'));while(f.calls.length<2)await wait(5);f.publish(pool=>{pool.entries[1].enabled=false;});await changed;assert.equal(f.sent.length,0);assert.equal(f.calls.length,2);
  });
  await test('A19 视觉后重启adapter仍共享真实总期限和累计次数，重放缓存不再次识图',async f=>{
    f.publish(pool=>{Object.assign(pool.policy,{question_timeout_ms:3000,call_timeout_ms:2500,connect_timeout_ms:100,max_attempts:4});});
    let answerClosed=false,answerClosedAt,beforeRestart,afterRestart,replay,answerEnvelope,visionCallsBefore,resolveAnswerClosed;
    const answerClosedEvent=new Promise(resolve=>{resolveAnswerClosed=resolve;});
    f.behavior=async(call,response)=>{
      if(call.visual){await wait(call.index===0?250:700);if(call.index===0){response.writeHead(503);response.end('{}');return true;}return false;}
      if(call.index===1){await wait(350);response.writeHead(503);response.end('{}');return true;}
      if(call.index===2){response.once('close',()=>{answerClosed=true;answerClosedAt=Date.now();resolveAnswerClosed();});return true;}
      return false;
    };
    f.beforeAnswer=async request=>{
      answerEnvelope=f.decode(request.headers['x-crispai-question']);
      beforeRestart=f.question(answerEnvelope.question_id);visionCallsBefore=f.calls.length;
      await f.restartAdapter();replay=await f.replayVision();afterRestart=f.question(answerEnvelope.question_id);
    };
    const event=f.event('session_pool_deadline',{type:'image/png',url:'https://storage.crisp.chat/synthetic.png'},{type:'file'});
    await f.deliver(event);const ended=Date.now(),stored=f.question(answerEnvelope.question_id);
    assert.equal(f.adapterRestarts,1);assert.equal(beforeRestart.attempts,2);assert.equal(afterRestart.attempts,2);assert.equal(visionCallsBefore,2);assert.equal(replay.status,200);assert.equal(replay.body.choices[0].message.content,'合成图片中是蓝色保存按钮。');
    assert.equal(f.visionRequest.envelope.stage,'vision');assert.equal(answerEnvelope.stage,'answer');assert.equal(f.visionRequest.envelope.question_id,answerEnvelope.question_id);assert.equal(f.visionRequest.envelope.deadline_at,answerEnvelope.deadline_at);
    assert.equal(beforeRestart.deadline,answerEnvelope.deadline_at);assert.equal(afterRestart.deadline,beforeRestart.deadline);assert.equal(stored.deadline,beforeRestart.deadline);assert.equal(stored.attempts,4);
    assert.deepEqual(f.calls.map(call=>call.index),[0,1,1,2]);assert.equal(f.calls.filter(call=>call.visual).length,2);assert.equal(f.tasks.length,1);assert.match(f.tasks[0].query,/蓝色保存按钮/);
    assert.equal(f.answerResponses[0].status,400);assert.equal(f.answerResponses[0].body.error.code,'question_timeout');assert.equal(stored.terminal.code,'question_timeout');assert.equal(stored.stages.answer.result,undefined);
    assert.ok(ended>=stored.deadline);assert.ok(ended-stored.deadline<700);assert.ok(ended-f.calls[0].at<3700);assert.ok(ended-f.calls.at(-1).at<2200);
    // 直接 adapter 回程不再多经过 RAG HTTP；给同进程 socket 的 close 事件有限派发时间。
    await Promise.race([answerClosedEvent,wait(100)]);
    write(path.join(f.root,'deadline-observation.json'),{deadline:stored.deadline,returned_at:ended,
      upstream_closed:answerClosed,upstream_closed_at:answerClosedAt??null,close_event_wait_max_ms:100,
      attempts:stored.attempts,vision_attempts:f.calls.filter(call=>call.visual).length});
    assert.equal(answerClosed,true);assert.ok(answerClosedAt<=ended+100);
    assert.equal(f.sent.length,1);assert.equal(f.sent[0].content,'请把图片中的关键信息或报错文字贴出来，并说明你正在进行的操作和希望解决的问题。');assert.equal(f.state(event.data.session_id).mode,'ai');
    f.restart();await f.deliver(event);assert.equal(f.calls.length,4);assert.equal(f.sent.length,1);assert.equal(f.tasks.length,1);
  });
  await test('主接口200机械故障切到备用，备用200机械故障继续切下一备用且仅出站业务答案',async f=>{
    const send=(response,value)=>{response.setHeader('content-type','application/json');response.end(JSON.stringify(value));};
    f.behavior=async(call,response)=>{
      if(call.index===0){send(response,{choices:[{message:{role:'assistant',content:'AI暂时无法回复，请稍后再试。'}}]});return true;}
      return false;
    };
    await f.deliver(f.event('session_pool_mechanical-primary','合成主接口故障问题'));
    assert.deepEqual(f.calls.map(call=>call.index),[0,1]);assert.equal(f.sent.length,1);
    assert.equal(f.sent[0].content,'受控业务答案：保存后重试。');
    assert(!f.sent.some(item=>/暂时无法回复|稍后再试/.test(item.content)));
  });
  await test('HTTP故障后的备用机械答复继续到Responses备用，整条链仅出站最终正常答案',async f=>{
    const send=(response,value)=>{response.setHeader('content-type','application/json');response.end(JSON.stringify(value));};
    f.behavior=async(call,response)=>{
      if(call.index===0){response.writeHead(503,{'content-type':'application/json'});response.end('{}');return true;}
      if(call.index===1){send(response,{choices:[{message:{role:'assistant',content:'模型繁忙，请稍后再试，谢谢理解。'}}]});return true;}
      return false;
    };
    await f.deliver(f.event('session_pool_mechanical-backup','合成备用接口故障问题'));
    assert.deepEqual(f.calls.map(call=>call.index),[0,1,2]);assert.equal(f.sent.length,1);
    assert.equal(f.sent[0].content,'受控业务答案：保存后重试。');
    assert(!f.sent.some(item=>/系统繁忙|稍后再试/.test(item.content)));
  });
  await test('视觉摘要及图片最终阶段的机械答复均在接口池内切换，不污染记忆或访客出站',async f=>{
    const send=(response,value)=>{response.setHeader('content-type','application/json');response.end(JSON.stringify(value));};
    f.behavior=async(call,response)=>{
      if(call.index===0&&call.visual){send(response,{choices:[{message:{role:'assistant',content:'系统维护中，请过会儿再试。'}}]});return true;}
      return false;
    };
    const first=f.event('session_pool_mechanical-vision',{type:'image/png',url:'https://storage.crisp.chat/synthetic.png'},{type:'file'});
    await f.deliver(first);assert.deepEqual(f.calls.map(call=>[call.index,call.visual]),[[0,true],[1,true],[1,false]]);
    assert.equal(f.sent.length,1);assert.equal(f.sent[0].content,'受控业务答案：保存后重试。');
    const context=f.state(first.data.session_id).image_context;assert.equal(context.length,1);
    assert.equal(context[0].summary,'合成图片中是蓝色保存按钮。');assert(!JSON.stringify(context).includes('维护中'));
  });
  await test('图片最终阶段主接口机械答复切备用，视觉事实只保存一次且不发送机械正文',async f=>{
    const send=(response,value)=>{response.setHeader('content-type','application/json');response.end(JSON.stringify(value));};
    f.behavior=async(call,response)=>{
      if(call.index===0&&!call.visual){send(response,{choices:[{message:{role:'assistant',content:'请稍后再试。'}}]});return true;}
      return false;
    };
    const event=f.event('session_pool_mechanical-image-final',{type:'image/png',url:'https://storage.crisp.chat/synthetic.png'},{type:'file'});
    await f.deliver(event);assert.deepEqual(f.calls.map(call=>[call.index,call.visual]),[[0,true],[0,false],[1,false]]);
    assert.equal(f.state(event.data.session_id).image_context.length,1);
    assert.equal(f.sent.length,1);assert.equal(f.sent[0].content,'受控业务答案：保存后重试。');
    assert(!f.sent.some(item=>/稍后再试/.test(item.content)));
  });
  await test('全池200机械故障只发送一次本地自然澄清，不误计AI成功或自动转人工',async f=>{
    const variants=['系统维护中，请稍后再试。','模型繁忙，请过会儿再试。','A\u0000I暂时无法回\u0007复，请稍后再试。'];
    f.behavior=async(call,response)=>{response.setHeader('content-type','application/json');
      response.end(JSON.stringify(call.index===2?{status:'completed',output_text:variants[2]}:{choices:[{message:{role:'assistant',content:variants[call.index]}}]}));return true;};
    const session='session_pool_mechanical-exhausted';await f.deliver(f.event(session,'合成全池机械故障问题'));
    assert.deepEqual(f.calls.map(call=>call.index),[0,1,2]);assert.equal(f.sent.length,1);
    assert.equal(f.sent[0].content,'你最希望先解决哪一处？可以把具体情况、相关提示和已经尝试的方法一起告诉我。');
    assert.equal(f.state(session).mode,'ai');assert.equal(f.state(session).jobs.filter(job=>job.status==='done').length,1);
  });
  await test('A21 全池失败后多个新会话得到单次安全提示，保护期及重启不重复轰击上游',async f=>{
    f.failed=new Set([0,1,2]);
    const initial=f.event('session_pool_exhausted0','合成全失败问题');
    assert.equal((await f.deliver(initial)).status,'sent');assert.deepEqual(f.calls.map(call=>call.index),[0,1,2]);
    await f.restartAdapter();f.restart();
    const events=Array.from({length:5},(_,n)=>f.event('session_pool_exhausted'+(n+1),'另一个合成问题'));
    const results=await Promise.all(events.map(event=>f.deliver(event)));assert(results.every(result=>result.status==='sent'));
    assert.equal(f.calls.length,3);assert.equal(f.tasks.length,6);assert.equal(f.sent.length,6);
    for(const event of [initial,...events]) {
      const messages=f.sent.filter(item=>item.session_id===event.data.session_id);assert.equal(messages.length,1);
      assert.equal(messages[0].content,'你最希望先解决哪一处？可以把具体情况、相关提示和已经尝试的方法一起告诉我。');assert.equal(f.state(event.data.session_id).mode,'ai');
      assert.equal((await f.receive(event)).reason,'重复事件已忽略');
    }
    assert.equal(f.calls.length,3);assert.equal(f.sent.length,6);
  });
  await test('A28 新池完成推理后Crisp回执未知与标签失败，重启只对账且模型/答案不重复',async f=>{
    f.failed=new Set([0,1]);f.unknownSend=true;f.tagFailure=true;
    const event=f.event('session_pool_reconcile','保存成功但发送回执暂时未知'),accepted=await f.receive(event);
    assert.equal(accepted.accepted,true);assert.equal((await f.process(accepted.key,accepted.jobId)).status,'retry');
    assert.deepEqual(f.calls.map(call=>call.index),[0,1,2]);assert.equal(f.tasks.length,1);assert.equal(f.sent.length,1);assert.equal(f.sendAttempts,1);
    const fingerprint=String(f.sent[0].fingerprint),before=f.state(event.data.session_id);assert.equal(before.outgoing[fingerprint].status,'unknown');assert.equal(f.question(accepted.jobId).attempts,3);
    await f.restartAdapter();f.restart();assert.equal((await f.receive(event)).reason,'重复事件已忽略');
    const retryAt=before.jobs.find(job=>job.id===accepted.jobId).retry_at;await wait(Math.max(0,retryAt-Date.now())+30);
    await f.scan();assert.equal((await f.process(accepted.key,accepted.jobId)).status,'sent');
    const current=f.state(event.data.session_id);assert.equal(current.outgoing[fingerprint].status,'sent');assert.equal(current.jobs.find(job=>job.id===accepted.jobId).status,'done');assert.equal(current.mode,'ai');
    assert.equal(f.calls.length,3);assert.equal(f.tasks.length,1);assert.equal(f.sent.length,1);assert.equal(f.sendAttempts,1);assert.equal(f.metaCalls,1);
    const records=fs.readFileSync(path.join(f.root,'data/analytics/events.jsonl'),'utf8').trim().split('\n').map(JSON.parse);assert.equal(records.filter(record=>record.type==='tag_failed').length,1);assert.equal(records.filter(record=>record.type==='ai_reply').length,1);
    f.tagFailure=false;f.restart();await f.scan();assert.equal((await f.process(accepted.key,accepted.jobId)).status,'idle');assert.equal((await f.receive(event)).reason,'重复事件已忽略');
    assert.equal(f.calls.length,3);assert.equal(f.tasks.length,1);assert.equal(f.sent.length,1);assert.equal(f.sendAttempts,1);assert.equal(f.metaCalls,1);assert.equal(f.question(accepted.jobId).attempts,3);
  });
  write(path.join(base,'result.json'),{layer:'UNIT/PROTOCOL',passed,failed:0,real_external:false});
  console.log(`运行时主备联验：${passed} 通过，0 失败（协议 RAG/Crisp，不是真实第三方）。`);
})().catch(error=>{console.error(error.stack);process.exitCode=1;});
