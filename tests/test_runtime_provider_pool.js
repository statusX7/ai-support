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
const {verifyEnvelope,signEnvelope,requestContract} = require('../scripts/provider-envelope');
const project = path.resolve(__dirname,'..');
const area = path.join(project,'.work/v1.3.0');
fs.mkdirSync(area,{recursive:true});
const base = fs.mkdtempSync(path.join(area,'runtime-pool-'));
const write = (file,value) => {fs.mkdirSync(path.dirname(file),{recursive:true});fs.writeFileSync(file,JSON.stringify(value),{mode:0o600});};
const read = file => JSON.parse(fs.readFileSync(file));
const canonical = value => Array.isArray(value) ? '[' + value.map(canonical).join(',') + ']'
  : value && typeof value === 'object' ? '{' + Object.keys(value).sort().map(key => JSON.stringify(key) + ':' + canonical(value[key])).join(',') + '}'
    : JSON.stringify(value);
const digest = value => crypto.createHash('sha256').update(value).digest('hex');
const sealMaterials = value => {
  const runtime = structuredClone(value.configuration.runtime);
  delete runtime.revision; delete runtime.applied_revision;
  value.source_components = {runtime:digest(canonical(runtime)),handoff:digest(canonical(value.configuration.handoff)),
    keyword:digest(canonical(value.configuration.keyword)),menu:digest(canonical(value.configuration.menu)),
    tags:digest(canonical(value.configuration.tags)),feedback:digest(canonical(value.configuration.feedback)),
    prompt:value.prompt.sha256,knowledge:digest(canonical(value.knowledge))};
  value.source_sha256 = digest(canonical(value.source_components)); return value;
};
const wait = ms => new Promise(resolve=>setTimeout(resolve,ms));
const until = async (check,message,timeout=5000) => {
  const deadline=Date.now()+timeout;
  while(Date.now()<deadline){if(check())return;await wait(5);}
  assert.ok(check(),message);
};
const png = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=','base64');
const execute = (args,environment={}) => new Promise(resolve=>{
  const child=spawn('python3',[path.join(project,'scripts/provider-pool.py'),...args],{env:{...process.env,...environment}});
  let stdout='',stderr='',finished=false,forced=null,timedOut=false,deadline=null;
  const finish=code=>{if(finished)return;finished=true;if(deadline)clearTimeout(deadline);if(forced)clearTimeout(forced);
    resolve({code:timedOut?124:code,stdout,stderr});};
  child.stdout.on('data',chunk=>stdout+=chunk);child.stderr.on('data',chunk=>stderr+=chunk);
  child.once('error',error=>{stderr+='\n受控 provider-pool 子进程启动失败：'+error.message;finish(127);});
  child.once('close',code=>finish(code));
  deadline=setTimeout(()=>{timedOut=true;stderr+='\n受控 provider-pool 子进程超过 60 秒本地截止时间';child.kill('SIGTERM');
    forced=setTimeout(()=>child.kill('SIGKILL'),2000);},60000);
});

async function fixture(label) {
  const root=path.join(base,label), calls=[], sent=[], histories=new Map(), tasks=[];
  for(const name of ['config','data/runtime','data/analytics','tmp'])fs.mkdirSync(path.join(root,name),{recursive:true});
  for(const name of ['keyword','handoff','menu','tags','feedback'])fs.copyFileSync(path.join(project,`config/${name}.yaml.example`),path.join(root,`config/${name}.yaml`));
  const menu=read(path.join(root,'config/menu.yaml'));menu.welcome.enabled=false;write(path.join(root,'config/menu.yaml'),menu);
  const prompt='用户原文规则：结合知识与公开历史回答。';fs.writeFileSync(path.join(root,'config/prompt.md'),prompt);
  write(path.join(root,'config/runtime.yaml'),{schema_version:2,enabled:true,revision:1,applied_revision:1});
  const projection='kb_1111111111111111_doc_2222222222222222.md';
  const mapPath=path.join(root,'data/runtime/knowledge-map.json');
  write(mapPath,{schema_version:2,revision:1,documents:[{
    library_id:'kb_1111111111111111',library_name:'合成处理资料',document_id:'doc_2222222222222222',projection,
    location:'custom-documents/'+projection+'-33333333-3333-4333-8333-333333333333.json',
  }]});
  const settingsPath=path.join(root,'data/runtime/knowledge-settings.json');
  write(settingsPath,{schema_version:1,workspace_slug:'synthetic',temperature:0.35,observed_at:Date.now()});
  const profileValue={engine:'native',model:'synthetic-embedding',chunk_size:1000,chunk_overlap:20,
    passage_prefix:'',query_prefix:'',component_version:'synthetic',splitter:'synthetic'};
  const profilePath=path.join(root,'data/runtime/knowledge-profile.json');
  write(profilePath,{schema_version:1,state:'applied',profile:profileValue,
    fingerprint:digest(canonical(profileValue)),applied_at:Date.now()});
  const mapRaw=fs.readFileSync(mapPath);
  const lexicalPayload={schema_version:2,algorithm:'crispai-lexical-v2',map_sha256:digest(mapRaw),complete:false,
    coverage:{source_documents:1,indexed_documents:0,omitted_documents:1,source_bytes:1,indexed_bytes:0,
      omitted_bytes:1,reasons:['index_capacity']},passages:[]};
  const lexicalPath=path.join(root,'data/runtime/knowledge-lexical.json');
  write(lexicalPath,{...lexicalPayload,payload_sha256:digest(canonical(lexicalPayload))});
  const configuration=Object.fromEntries(['runtime','handoff','keyword','menu','tags','feedback']
    .map(name=>[name,read(path.join(root,'config',name+'.yaml'))]));
  const materialsPath=path.join(root,'config/materials-applied.json');
  write(materialsPath,sealMaterials({schema_version:2,state:'applied',revision:1,applied_at:Date.now(),
    source_sha256:'',source_components:{},configuration,
    prompt:{text:prompt,bytes:Buffer.byteLength(prompt),sha256:digest(prompt)},
    knowledge:{catalog_revision:1,catalog_sha256:digest(canonical({fixture:'catalog',documents:1})),
      manifest_sha256:digest(canonical({fixture:'manifest',projection})),map_sha256:digest(mapRaw),
      settings_sha256:digest(fs.readFileSync(settingsPath)),profile_sha256:digest(fs.readFileSync(profilePath)),
      lexical_sha256:digest(fs.readFileSync(lexicalPath)),enabled_library_ids:['kb_1111111111111111'],
      library_count:1,document_count:1,enabled_document_count:1}}));
  let sequence=10000, runtime;
  const f={root,calls,sent,histories,tasks,failed:new Set(),slow:false,delay:400,failAnswer:false,
    adapterRestarts:0,answerRequests:[],answerResponses:[],adapterInternalRequests:[],
    dropNextAdapterResponse:false,sendAttempts:0,metaCalls:0,unknownSend:false,tagFailure:false,
    resignAnswerSystem:false};
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
  Object.assign(pool.policy,{question_timeout_ms:7000,call_timeout_ms:1500,connect_timeout_ms:100,
    max_attempts:3,cooldown_initial_ms:1000,cooldown_max_ms:2000,pool_cooldown_ms:100});
  write(secretPath,secrets);write(poolPath,pool);
  const internal=/^PROVIDER_ADAPTER_KEY=(.*)$/m.exec(fs.readFileSync(path.join(root,'.env'),'utf8'))[1];
  let adapter,adapterBase;
  const startAdapter=async()=>{
    adapter=createAdapter({PROVIDER_ROOT:root,PROVIDER_ADAPTER_KEY:internal,PROVIDER_POOL_REQUIRED:'true',PROVIDER_REQUIRE_ENVELOPE:'true'});
    await new Promise(resolve=>adapter.listen(0,'127.0.0.1',resolve));adapterBase=`http://127.0.0.1:${adapter.address().port}`;
  };
  await startAdapter();
  const verifiedPool=await execute(['--deploy-dir',root,'verify-applied'],{
    PROVIDER_ADAPTER_MANAGEMENT_URL:adapterBase,
  });
  assert.equal(verifiedPool.code,0,verifiedPool.stderr+verifiedPool.stdout);
  const postAdapter=async(body,headers={},timeout=10000,route='/v1/chat/completions',signal)=>{
    const controller=new AbortController();
    const abort=()=>controller.abort();
    signal?.addEventListener('abort',abort,{once:true});
    if(signal?.aborted)controller.abort();
    const timer=setTimeout(abort,timeout);
    let response;
    try {
      response=await fetch(adapterBase+route,{method:'POST',headers:{Authorization:'Bearer '+internal,'content-type':'application/json',...headers},body:JSON.stringify(body),signal:controller.signal});
    } finally {
      clearTimeout(timer);signal?.removeEventListener('abort',abort);
    }
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
  const env={CRISP_WEBSITE_ID:'11111111-1111-4111-8111-111111111111',CRISP_WEBSITE_HOOK_SECRET:'synthetic-hook-only',CRISP_AUTH_B64:'synthetic-crisp-auth',ANYTHINGLLM_WORKSPACE:'synthetic',ANYTHINGLLM_API_KEY:'synthetic-rag-key',PROVIDER_ADAPTER_KEY:internal,PROVIDER_POOL_REQUIRED:'true',PROVIDER_POOL_READBACK_REQUIRED:'true',PROVIDER_ADAPTER_URL:adapterBase+'/v1',ANYTHINGLLM_INTERNAL_URL:`http://127.0.0.1:${rag.address().port}`};
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
      if(['/internal/provider/replay','/internal/provider/settle','/internal/provider/retire'].includes(parsed.pathname)){
        f.adapterInternalRequests.push(parsed.pathname);
        return postAdapter(options.body||{},options.headers,options.timeout||10000,parsed.pathname,options.signal);
      }
      assert.equal(parsed.pathname,'/v1/chat/completions');
      const captured={body:structuredClone(options.body),headers:structuredClone(options.headers),envelope:verifyEnvelope(options.headers['x-crispai-question'],internal)};
      if(captured.envelope.stage==='vision')f.visionRequest=captured;
      else {
        assert.equal(captured.envelope.stage,'answer');assert.equal(captured.body.temperature,0.35);f.answerRequests.push(structuredClone(captured));
        if(f.beforeAnswer)await f.beforeAnswer(captured);
        // 先保留签名后正文篡改反例；需要单独验证Prompt守卫时，测试夹具用内部Key
        // 重新绑定变更后的正文身份，使请求能越过请求摘要门而只命中Prompt完整性门。
        if(f.answerSystem!==undefined){
          captured.body.messages[0].content=f.answerSystem;
          if(f.resignAnswerSystem){
            const rebound=requestContract(captured.body);
            captured.headers['x-crispai-question']=signEnvelope({...captured.envelope,
              request_contract_version:rebound.request_contract_version,
              request_sha256:rebound.request_sha256},internal);
          }
        }
      }
      // 重启会更换本地随机端口；始终解析当前 adapter，模拟部署中不变的服务地址。
      const response=await postAdapter(captured.body,captured.headers,options.timeout||10000,
        '/v1/chat/completions',options.signal);
      if(captured.envelope.stage==='answer')f.answerResponses.push(response);
      if(f.dropNextAdapterResponse){f.dropNextAdapterResponse=false;const error=new Error('受控 adapter 回程丢失');error.code='ECONNRESET';throw error;}
      return response;
    }
    const controller=new AbortController();const abort=()=>controller.abort();
    options.signal?.addEventListener('abort',abort,{once:true});if(options.signal?.aborted)controller.abort();
    const timer=setTimeout(abort,options.timeout||10000);let response;
    try { response=await fetch(url,{method:options.method||'GET',headers:{'content-type':'application/json',...options.headers},body:options.body?JSON.stringify(options.body):undefined,signal:controller.signal}); }
    finally { clearTimeout(timer);options.signal?.removeEventListener('abort',abort); }
    return{status:response.status,body:await response.json()};
  };
  f.restart=()=>{runtime=createRuntime(env,{root,request,lookup:(_host,_opts,callback)=>callback(null,[{address:'8.8.8.8',family:4}])});};f.restart();
  f.restartAdapter=async()=>{adapter.closeAllConnections();await new Promise(resolve=>adapter.close(resolve));await startAdapter();env.PROVIDER_ADAPTER_URL=adapterBase+'/v1';f.adapterRestarts++;};
  f.replayVision=()=>postAdapter(f.visionRequest.body,{'x-crispai-question':f.visionRequest.headers['x-crispai-question']});
  f.decode=token=>verifyEnvelope(token,internal);
  f.question=id=>read(path.join(root,'data/provider-router/questions',id+'.json'));
  f.questionPath=id=>path.join(root,'data/provider-router/questions',id+'.json');
  f.process=(key,id)=>runtime.process(key,id);
  f.scan=()=>runtime.scan();
  f.makeDue=async(session,id)=>{
    const normalized=session.replace(/^session_pool_/,'session_pool-');
    const key=runtime.stateKey(env.CRISP_WEBSITE_ID,normalized);
    await runtime.transaction(key,state=>{const job=state.jobs.find(item=>item.id===id);assert(job);job.retry_at=0;});
  };
  f.publishRuntime=enabled=>{
    const materials=read(materialsPath);materials.revision++;
    materials.configuration.runtime={...materials.configuration.runtime,enabled,
      revision:materials.revision,applied_revision:materials.revision};
    write(materialsPath,sealMaterials(materials));
  };
  f.event=(session,content,extra={})=>({website_id:env.CRISP_WEBSITE_ID,event:'message:send',timestamp:Date.now(),data:{session_id:session.replace(/^session_pool_/,'session_pool-'),from:'user',type:'text',content,fingerprint:++sequence,timestamp:Date.now(),...extra}});
  f.receive=async body=>{if(body.event==='message:send'||body.data.from==='operator'){const items=histories.get(body.data.session_id)||[];items.push(body.data);histories.set(body.data.session_id,items);}return runtime.receive({body,query:{key:env.CRISP_WEBSITE_HOOK_SECRET}});};
  f.deliver=async body=>{const accepted=await f.receive(body);assert.equal(accepted.accepted,true);return accepted.route==='process'?runtime.process(accepted.key,accepted.jobId):accepted;};
  f.state=session=>runtime.readState(runtime.stateKey(env.CRISP_WEBSITE_ID,session.replace(/^session_pool_/,'session_pool-')));
  f.publish=async change=>{
    pool=read(poolPath);change(pool);pool.revision++;secrets.revision=pool.revision;
    write(secretPath,secrets);write(poolPath,pool);
    const verified=await execute(['--deploy-dir',root,'verify-applied'],{
      PROVIDER_ADAPTER_MANAGEMENT_URL:adapterBase,
    });
    assert.equal(verified.code,0,verified.stderr+verified.stdout);
  };
  f.close=async()=>{for(const server of [rag,adapter,upstream])server.closeAllConnections();await Promise.all([rag,adapter,upstream].map(server=>new Promise(resolve=>server.close(resolve))));};
  return f;
}

let passed=0;
async function test(name,action){const f=await fixture('case-'+passed);try{await action(f);passed++;console.log('通过 UNIT/PROTOCOL：'+name);}finally{await f.close();}}
function assertUnresolved(f,event,result,code=''){
  assert.equal(result.status,'unresolved');assert.equal(f.sent.filter(item=>item.session_id===event.data.session_id).length,0);
  const job=f.state(event.data.session_id).jobs.find(item=>item.id===result.jobId);assert(job);
  assert.equal(job.status,'received');assert.equal(job.responsibility_status,'unresolved_failure');
  if(code)assert.equal(job.failure_code,code);assert(Number.isFinite(job.retry_at));return job;
}
async function recoverOnce(f,event,result){
  f.failed.clear();f.failAnswer=false;f.slow=false;f.behavior=null;f.beforeAnswer=null;
  f.answerSystem=undefined;f.resignAnswerSystem=false;
  await f.makeDue(event.data.session_id,result.jobId);await wait(1100);
  const before=f.sent.length,beforeCalls=f.calls.length;
  let recovered=await f.process(result.key,result.jobId);
  if(recovered.status==='unresolved'){
    assert.equal(f.calls.length,beforeCalls,
      '模糊技术失败的首次恢复只能只读确认旧代结果，不得再次调用上游');
    const converged=f.state(event.data.session_id).jobs.find(item=>item.id===result.jobId);
    assert.equal(converged.inference,undefined,'精确 absent 后才可释放旧推理信封');
    assert.equal(converged.provider_result_receipt,undefined);
    assert.equal(f.sent.length,before);
    await f.makeDue(event.data.session_id,result.jobId);
    recovered=await f.process(result.key,result.jobId);
  }
  assert.equal(recovered.status,'sent');
  assert.equal(f.sent.length,before+1);assert.equal(f.sent.at(-1).session_id,event.data.session_id);
  assert.equal(f.sent.at(-1).content,'受控业务答案：保存后重试。');
  const job=f.state(event.data.session_id).jobs.find(item=>item.id===result.jobId);
  assert.equal(job.status,'done');assert.equal(job.responsibility_status,'answered_confirmed');
}
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
  await test('签名后正文篡改先拒绝；重新绑定正文但丢失业务Prompt仍零出站并可恢复',async f=>{
    const truncated='用户原文规则：\n--prompt truncated for brevity--\n公开历史回答。';
    f.answerSystem=truncated;
    const tamperEvent=f.event('session_pool_request-tamper','合成签名正文篡改问题');
    const tamperUnresolved=await f.deliver(tamperEvent);assert.equal(f.calls.length,0);assert.equal(f.sent.length,0);
    assert.equal(f.answerResponses[0].status,400);assert.equal(f.answerResponses[0].body.error.code,'invalid_envelope');
    assertUnresolved(f,tamperEvent,tamperUnresolved,'invalid_response');
    await recoverOnce(f,tamperEvent,tamperUnresolved);assert.equal(f.sent.length,1);
    f.answerSystem=truncated;f.resignAnswerSystem=true;
    const promptTasksBefore=f.tasks.length;
    const event=f.event('session_pool_prompt1','合成普通问题');
    const unresolved=await f.deliver(event);assert.equal(f.calls.length,1);assert.equal(f.sent.length,1);
    assert.equal(f.answerResponses.at(-1).status,400);assert.equal(f.answerResponses.at(-1).body.error.code,'context_preparation_incomplete');
    assertUnresolved(f,event,unresolved,'context_preparation_incomplete');assert.equal(f.state(event.data.session_id).mode,'ai');
    f.restart();await f.deliver(event);assert.equal(f.calls.length,1);assert.equal(f.sent.length,1);
    assert.equal(f.tasks.length,promptTasksBefore+1,'重复事件不得再次执行知识检索');
    await recoverOnce(f,event,unresolved);assert.equal(f.sent.length,2);
    f.answerSystem=truncated;f.resignAnswerSystem=true;
    const imageEvent=f.event('session_pool_promptimage',{type:'image/png',url:'https://storage.crisp.chat/synthetic.png'},{type:'file'});
    const imageUnresolved=await f.deliver(imageEvent);assert.equal(f.calls.filter(call=>call.visual).length,1);
    assert.equal(f.answerResponses.at(-1).body.error.code,'context_preparation_incomplete');assert.equal(f.sent.length,2);assert.equal(f.state(imageEvent.data.session_id).image_context.length,1);
    assertUnresolved(f,imageEvent,imageUnresolved,'context_preparation_incomplete');
    assert.equal(f.state(imageEvent.data.session_id).mode,'ai');f.restart();await f.deliver(imageEvent);
    assert.equal(f.calls.filter(call=>call.visual).length,1);assert.equal(f.sent.length,2);
    await recoverOnce(f,imageEvent,imageUnresolved);assert.equal(f.sent.length,3);
    assert.equal(f.calls.filter(call=>call.visual).length,1,'恢复不得重新识图');
  });
  await test('视觉与RAG回答共享三次上限，耗尽后保留责任并在恢复后仅答一次',async f=>{
    await f.publish(pool=>{pool.policy.max_attempts=3;});f.failed=new Set([0]);f.failAnswer=true;
    const event=f.event('session_pool_image1',{type:'image/png',url:'https://storage.crisp.chat/synthetic.png'},{type:'file'});
    const result=await f.deliver(event);assert.equal(f.calls.length,3);assert.equal(f.calls.filter(x=>x.visual).length,2);assert.equal(f.sent.length,0);assert.equal(f.state(event.data.session_id).mode,'ai');
    assert(f.tasks[0].query.includes('蓝色保存按钮'));assertUnresolved(f,event,result);
    f.restart();await f.deliver(event);assert.equal(f.calls.length,3);assert.equal(f.sent.length,0);
    await recoverOnce(f,event,result);assert.equal(f.sent.length,1);
  });
  await test('主备等待时真人优先暂停A，B独立回复，不续尝试不发送迟到A答案',async f=>{
    f.slow=true;f.delay=1000;f.failed=new Set([0]);const pending=f.deliver(f.event('session_pool_humanA','慢问题'));
    await until(()=>f.calls.length===1,'慢推理未进入合成上游');
    const human=f.event('session_pool_humanA','真人公开处理进度',{from:'operator',automated:false});human.event='message:received';
    const started=Date.now();await f.deliver(human);const handoffElapsed=Date.now()-started;
    const cancelled=await pending;const cancellationElapsed=Date.now()-started;
    assert(handoffElapsed<600,'人工接管提交耗时 '+handoffElapsed+'ms，取消收敛 '+cancellationElapsed+'ms；超过600ms门禁');assert.equal(f.state('session_pool_humanA').mode,'human');
    assert(cancellationElapsed<750,'慢请求取消收敛耗时 '+cancellationElapsed+'ms，超过750ms门禁');assert.equal(cancelled.status,'cancelled');
    assert.equal(f.calls.length,1);assert.equal(f.sent.length,0);
    const cancelledJob=f.state('session_pool_humanA').jobs.find(item=>item.id===cancelled.jobId);
    assert.equal(cancelledJob.responsibility_status,'intentional_silence');
    assert(cancelledJob.inference);assert(cancelledJob.provider_result_receipt);
    assert.equal(cancelledJob.provider_retirement?.state,'pending');
    const questionPath=f.questionPath(cancelled.jobId);assert(fs.existsSync(questionPath));
    f.slow=false;await f.deliver(f.event('session_pool_humanB','另一个会话的问题'));assert.equal(f.sent.length,1);assert.equal(f.sent[0].session_id,'session_pool-humanB');
    const selected=await f.scan();assert(selected.some(item=>item.key===cancelled.key&&item.jobId===cancelled.jobId));
    const retired=await f.process(cancelled.key,cancelled.jobId);assert.equal(retired.status,'provider_retirement_retired');
    const finished=f.state('session_pool_humanA').jobs.find(item=>item.id===cancelled.jobId);
    assert.equal(finished.inference,undefined);assert.equal(finished.provider_result_receipt,undefined);
    assert.deepEqual(Object.keys(finished.provider_retirement).sort(),
      ['attempts','identity_sha256','purpose','retired_at','schema_version','state'].sort());
    assert.equal(finished.provider_retirement.state,'retired');
    assert.equal(fs.existsSync(questionPath),false,'签名退休确认后必须安全回收该问题缓存');
    assert.equal(f.adapterInternalRequests.filter(path=>path==='/internal/provider/retire').length,1);
  });
  await test('总关与池配置变更取消整条推理；不误发一次错误提示',async f=>{
    f.slow=true;f.delay=1000;const pending=f.deliver(f.event('session_pool_global','慢问题'));
    await until(()=>f.calls.length===1,'总关场景的慢推理未进入合成上游');
    const disabledAt=Date.now();f.publishRuntime(false);const cancelled=await pending;
    assert(Date.now()-disabledAt<400);assert.equal(cancelled.status,'cancelled');assert.equal(f.calls.length,1);assert.equal(f.sent.length,0);
    let stored=f.state('session_pool_global').jobs.find(item=>item.id===cancelled.jobId);
    assert.equal(stored.responsibility_reason,'global_disabled');assert.equal(stored.provider_retirement?.state,'pending');
    assert.equal((await f.process(cancelled.key,cancelled.jobId)).status,'provider_retirement_retired');
    stored=f.state('session_pool_global').jobs.find(item=>item.id===cancelled.jobId);
    assert.equal(stored.provider_retirement?.state,'retired');assert.equal(stored.inference,undefined);
    f.publishRuntime(true);
    const changed=f.deliver(f.event('session_pool_changed','另一个慢问题'));
    await until(()=>f.calls.length===2,'池换代场景的慢推理未进入合成上游');
    await f.publish(pool=>{pool.entries[1].enabled=false;});await changed;assert.equal(f.sent.length,0);assert.equal(f.calls.length,2);
  });
  await test('A19 视觉后重启adapter仍共享真实总期限和累计次数，重放缓存不再次识图',async f=>{
    // 本场验证跨视觉/回答阶段的5秒总期限，不验证主接口冷却后回切。
    // 5秒给全量套件负载下的真实adapter重启和缓存回读留出调度余量；回答阶段
    // 仍必须消耗同一个deadline并以question_timeout终止，不能取得新的一题预算。
    // 将失败候选冷却明确设为长于题目期限，避免毫秒级执行开销决定主接口
    // 是否恰在回答阶段前恢复资格，从而改变本场真正要观测的调用序列。
    await f.publish(pool=>{Object.assign(pool.policy,{question_timeout_ms:5000,
      call_timeout_ms:4500,connect_timeout_ms:100,max_attempts:4,
      cooldown_initial_ms:15000,cooldown_max_ms:15000});});
    let answerClosed=false,answerClosedAt,beforeRestart,afterRestart,replay,answerEnvelope,
      visionCallsBefore,replayStartedAt,replayFinishedAt,resolveAnswerClosed;
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
      await f.restartAdapter();replayStartedAt=Date.now();replay=await f.replayVision();
      replayFinishedAt=Date.now();afterRestart=f.question(answerEnvelope.question_id);
    };
    const event=f.event('session_pool_deadline',{type:'image/png',url:'https://storage.crisp.chat/synthetic.png'},{type:'file'});
    const result=await f.deliver(event),ended=Date.now(),stored=f.question(answerEnvelope.question_id);
    assert.equal(f.adapterRestarts,1);assert.equal(beforeRestart.attempts,2);assert.equal(afterRestart.attempts,2);assert.equal(visionCallsBefore,2);
    assert.equal(replay.status,200,'视觉缓存重放状态 '+replay.status+'，错误 '+String(replay.body?.error?.code||'none')
      +'，开始时剩余 '+(answerEnvelope.deadline_at-replayStartedAt)+'ms，耗时 '+(replayFinishedAt-replayStartedAt)+'ms');
    assert.equal(replay.body.choices[0].message.content,'合成图片中是蓝色保存按钮。');
    assert.equal(f.visionRequest.envelope.stage,'vision');assert.equal(answerEnvelope.stage,'answer');assert.equal(f.visionRequest.envelope.question_id,answerEnvelope.question_id);assert.equal(f.visionRequest.envelope.deadline_at,answerEnvelope.deadline_at);
    assert.equal(beforeRestart.deadline,answerEnvelope.deadline_at);assert.equal(afterRestart.deadline,beforeRestart.deadline);assert.equal(stored.deadline,beforeRestart.deadline);
    assert([3,4].includes(stored.attempts),'adapter重启后累计尝试必须保留，且不得超过四次总上限');
    const expectedCalls=stored.attempts===4?[0,1,1,2]:[0,1,1];
    assert.deepEqual(f.calls.map(call=>call.index),expectedCalls);
    assert.equal(f.calls.filter(call=>call.visual).length,2);assert.equal(f.tasks.length,1);assert.match(f.tasks[0].query,/蓝色保存按钮/);
    assert.equal(f.answerResponses[0].status,400);assert.equal(f.answerResponses[0].body.error.code,'question_timeout');assert.equal(stored.terminal.code,'question_timeout');assert.equal(stored.stages.answer.result,undefined);
    assert.ok(ended>=stored.deadline);assert.ok(ended-stored.deadline<700);assert.ok(ended-f.calls[0].at<5700);assert.ok(ended-f.calls.at(-1).at<4200);
    // 直接 adapter 回程不再多经过 RAG HTTP；给同进程 socket 的 close 事件有限派发时间。
    await Promise.race([answerClosedEvent,wait(100)]);
    write(path.join(f.root,'deadline-observation.json'),{deadline:stored.deadline,returned_at:ended,
      upstream_closed:answerClosed,upstream_closed_at:answerClosedAt??null,close_event_wait_max_ms:100,
      attempts:stored.attempts,vision_attempts:f.calls.filter(call=>call.visual).length});
    if(stored.attempts===4){assert.equal(answerClosed,true);assert.ok(answerClosedAt<=ended+100);}
    else assert.equal(answerClosed,false,'总期限先耗尽时不得启动最后一个候选再制造连接');
    assert.equal(f.sent.length,0);assert.equal(f.state(event.data.session_id).mode,'ai');assertUnresolved(f,event,result,'question_timeout');
    f.restart();await f.deliver(event);assert.equal(f.calls.length,stored.attempts);
    assert.equal(f.sent.length,0);assert.equal(f.tasks.length,1);
    await recoverOnce(f,event,result);assert.equal(f.sent.length,1);
  });
  await test('主接口200机械故障切到备用，备用200机械故障继续切下一备用且仅出站业务答案',async f=>{
    const send=(response,value)=>{response.setHeader('content-type','application/json');response.end(JSON.stringify(value));};
    f.behavior=async(call,response)=>{
      if(call.index===0){send(response,{choices:[{message:{role:'assistant',content:'暫時無法回覆，請稍後再試。'}}]});return true;}
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
      if(call.index===1){send(response,{choices:[{message:{role:'assistant',content:'The AI assistant is temporarily unavailable. Please try again later.'}}]});return true;}
      return false;
    };
    await f.deliver(f.event('session_pool_mechanical-backup','合成备用接口故障问题'));
    assert.deepEqual(f.calls.map(call=>call.index),[0,1,2]);assert.equal(f.sent.length,1);
    assert.equal(f.sent[0].content,'受控业务答案：保存后重试。');
    assert(!f.sent.some(item=>/系统繁忙|稍后再试/.test(item.content)));
  });
  await test('视觉摘要及图片最终阶段的机械答复均在接口池内切换，不污染记忆或访客出站',async f=>{
    await f.publish(pool=>{Object.assign(pool.policy,{
      cooldown_initial_ms:15000,cooldown_max_ms:15000});});
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
  await test('全池200机械故障零可见出站且保留责任，恢复后原问题仅一份有效答案',async f=>{
    const variants=['系统维护中，请稍后再试。','模型繁忙，请过会儿再试。','A\u0000I暂时无法回\u0007复，请稍后再试。'];
    f.behavior=async(call,response)=>{response.setHeader('content-type','application/json');
      response.end(JSON.stringify(call.index===2?{status:'completed',output_text:variants[2]}:{choices:[{message:{role:'assistant',content:variants[call.index]}}]}));return true;};
    const session='session_pool_mechanical-exhausted',event=f.event(session,'合成全池机械故障问题');
    const result=await f.deliver(event);assert.deepEqual(f.calls.map(call=>call.index),[0,1,2]);
    assertUnresolved(f,event,result,'invalid_response');assert.equal(f.state(session).mode,'ai');
    await recoverOnce(f,event,result);assert.equal(f.sent.length,1);
  });
  await test('旧 Provider generic 缓存及 adapter 回程丢失不会永久 replay，下一代仅发一份有效答案',async f=>{
    const generic='你最希望先解决哪一处？可以把具体情况、相关提示和已经尝试的方法一起告诉我。';
    let seeded=false;
    f.beforeAnswer=async request=>{
      if(seeded)return;seeded=true;f.beforeAnswer=undefined;
      const envelope=request.envelope,pool=read(path.join(f.root,'config/provider-pool-applied.json'));
      const binding=digest(JSON.stringify([envelope.scope||'conversation',envelope.session_key,
        envelope.generation,envelope.runtime_revision,envelope.pool_revision,envelope.attempt_generation]));
      write(path.join(f.root,'data/provider-router/questions',envelope.question_id+'.json'),{
        id:envelope.question_id,binding,attempt_generation:envelope.attempt_generation,
        revision:envelope.pool_revision,deadline:envelope.deadline_at,attempts:1,
        stages:{answer:{tried:[pool.primary_id],result:{id:'legacy-generic-cache',model:'legacy-model',
          choices:[{message:{role:'assistant',content:generic},finish_reason:'stop'}]}}},created_at:Date.now(),
      });
    };
    f.dropNextAdapterResponse=true;
    const event=f.event('session_pool_legacy-generic-cache','合成知识问题'),first=await f.deliver(event);
    assertUnresolved(f,event,first,'provider_response_unknown');
    assert.equal(f.calls.length,0,'首次只读取旧缓存，不得伪造新的上游调用');
    assert.equal(f.sent.length,0,'旧 generic 缓存不得出站');
    let firstStored=f.state(event.data.session_id).jobs.find(job=>job.id===first.jobId);
    assert.equal(firstStored.provider_result_receipt?.state,'unknown',
      'adapter 回程丢失必须先保守进入 replay-only，不能直接取得第二次推理权');
    assert.equal(firstStored.inference?.attempt_generation,1);
    let question=f.question(first.jobId);assert.equal(question.attempt_generation,1);
    assert.equal(question.stages.answer.result.choices[0].message.content,generic);

    await f.makeDue(event.data.session_id,first.jobId);
    const replayRejected=await f.process(first.key,first.jobId);
    assertUnresolved(f,event,replayRejected,'question_result_rejected');
    assert.deepEqual(f.adapterInternalRequests,['/internal/provider/replay']);
    firstStored=f.state(event.data.session_id).jobs.find(job=>job.id===first.jobId);
    assert.equal(firstStored.provider_result_receipt,undefined,
      'router 的精确拒绝结论必须释放 replay-only 回执，允许唯一下一恢复代');
    assert.equal(firstStored.inference,undefined,
      '已确认不可见的旧 generic 不能永久占住同一推理代');
    assert.equal(f.calls.length,0);assert.equal(f.sent.length,0);

    await f.makeDue(event.data.session_id,first.jobId);await wait(1100);
    const recovered=await f.process(first.key,first.jobId);
    assert.equal(recovered.status,'sent');assert.deepEqual(f.calls.map(call=>call.index),[1]);
    assert.equal(f.sent.length,1);assert.equal(f.sent[0].content,'受控业务答案：保存后重试。');
    assert(!f.sent[0].content.includes('最希望先解决'));
    question=f.question(first.jobId);
    assert.equal(question.attempt_generation,2);
    assert.equal(question.attempts,2,'缓存失效恢复不得重置原有供应商尝试预算');
    assert.equal(question.output_policy_recovery.from_attempt_generation,1);
    assert.match(question.stages.answer.invalidated_result.sha256,/^[a-f0-9]{64}$/);
    const stored=f.state(event.data.session_id).jobs.find(job=>job.id===first.jobId);
    assert.equal(stored.status,'done');assert.equal(stored.responsibility_status,'answered_confirmed');
    assert.deepEqual(f.adapterInternalRequests,['/internal/provider/replay','/internal/provider/settle']);
    assert.equal((await f.receive(event)).reason,'重复事件已忽略');
    assert.equal(f.calls.length,1);assert.equal(f.sent.length,1);
  });
  await test('A21 全池失败后多会话零可见出站且责任不丢，恢复后每问题仅一份答案',async f=>{
    // outage阶段需要明确覆盖所有并发会话；不能用默认1秒冷却并假设
    // adapter/runtime重启与五个并发任务一定会在该窗口内完成。
    await f.publish(pool=>{Object.assign(pool.policy,{
      cooldown_initial_ms:15000,cooldown_max_ms:15000});});
    f.failed=new Set([0,1,2]);
    const initial=f.event('session_pool_exhausted0','合成全失败问题');
    const firstResult=await f.deliver(initial);assertUnresolved(f,initial,firstResult,'upstream_unavailable');assert.deepEqual(f.calls.map(call=>call.index),[0,1,2]);
    await f.restartAdapter();f.restart();
    const events=Array.from({length:5},(_,n)=>f.event('session_pool_exhausted'+(n+1),'另一个合成问题'));
    const results=await Promise.all(events.map(event=>f.deliver(event)));
    assert.equal(f.calls.length,3);assert.equal(f.sent.length,0);
    for(const [index,event] of [initial,...events].entries()) {
      const result=index===0?firstResult:results[index-1];assertUnresolved(f,event,result);
      assert.equal(f.state(event.data.session_id).mode,'ai');
      assert.equal((await f.receive(event)).reason,'重复事件已忽略');
    }
    assert.equal(f.calls.length,3);assert.equal(f.sent.length,0);
    // 将“仍在故障冷却”和“上游已经恢复”两个阶段显式分开。
    await wait(15100);
    const callsBeforeRecovery=f.calls.length;
    for(const [index,event] of [initial,...events].entries()) {
      const result=index===0?firstResult:results[index-1];
      const internalBefore=f.adapterInternalRequests.length;
      await recoverOnce(f,event,result);
      assert.deepEqual(f.adapterInternalRequests.slice(internalBefore),
        ['/internal/provider/replay','/internal/provider/settle'],
        '模糊失败必须先只读 replay 收敛，再结算唯一新答案');
      assert.equal(f.state(event.data.session_id).jobs.filter(item=>item.id===result.jobId).length,1,
        '恢复必须沿用同一应答责任，不得复制任务');
    }
    assert.equal(f.calls.length,callsBeforeRecovery+6,
      '每个恢复问题最多新增一次有界上游推理；replay-only 收敛轮不得调用上游');
    assert.equal(f.sent.length,6);
    for(const event of [initial,...events])assert.equal(f.sent.filter(item=>item.session_id===event.data.session_id).length,1);
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
