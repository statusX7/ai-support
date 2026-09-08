'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const crypto = require('node:crypto');
const {spawn} = require('node:child_process');
const {createAdapter} = require('../scripts/provider-adapter.js');
const {signEnvelope,envelopeMarker} = require('../scripts/provider-envelope.js');
const {DEFAULT_POLICY,retryAfterMilliseconds,classifyFailure,estimateTextTokens} = require('../scripts/provider-router.js');
const root = path.resolve(__dirname,'..');
const sleep = delay => new Promise(resolve => setTimeout(resolve,delay));
async function until(condition,message,timeout=3000) {
  const end=Date.now()+timeout;
  while(!condition()&&Date.now()<end)await sleep(5);
  assert.ok(condition(),message);
}
const json = (file,value) => fs.writeFileSync(file,JSON.stringify(value),{mode:0o600});
const read = file => JSON.parse(fs.readFileSync(file,'utf8'));
const sample = {messages:[{role:'system',content:'请用中文回答。'},{role:'user',content:'合成问题'}]};
const image = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=';
function chat(text='验证回答') { return {id:'fixture-result',model:'untrusted-upstream-name',choices:[{message:{role:'assistant',content:text},finish_reason:'stop'}],usage:{prompt_tokens:3,completion_tokens:2,total_tokens:5}}; }
function command(args,environment={}) { return new Promise(resolve => {
  const child = spawn('python3',[path.join(root,'scripts/provider-pool.py'),...args],{cwd:root,env:{...process.env,...environment}});
  let stdout='',stderr=''; child.stdout.on('data',data=>stdout+=data); child.stderr.on('data',data=>stderr+=data);
  child.on('close',code=>{ let value; try {value=JSON.parse(stdout);} catch (_) {} resolve({code,value,stdout,stderr}); });
}); }

async function fixture(count=1,policy={}) {
  fs.mkdirSync(path.join(root,'.work'),{recursive:true});
  const directory = fs.mkdtempSync(path.join(root,'.work/provider-pool-contract-'));
  for (const name of ['config','data/runtime']) fs.mkdirSync(path.join(directory,name),{recursive:true});
  const f = {directory,calls:[],behavior:null};
  f.upstream = http.createServer(async (request,response) => {
    let raw=''; for await (const data of request) raw+=data;
    const body = JSON.parse(raw || '{}'), index = Number(/^\/p(\d+)\//.exec(request.url)?.[1] || 0);
    const call={index,path:request.url,method:request.method,headers:request.headers,body}; f.calls.push(call);
    if (f.behavior && await f.behavior(call,response) === true) return;
    response.setHeader('content-type','application/json');
    response.end(JSON.stringify(request.url.endsWith('/models') ? {data:[{id:'fixture-b'},{id:'fixture-a'},{id:'fixture-b'}]} : request.url.endsWith('/responses') ? {status:'completed',output:[{type:'message',content:[{type:'output_text',text:'Responses 回答'}]}],usage:{input_tokens:3,output_tokens:2}}:chat()));
  });
  await new Promise(resolve=>f.upstream.listen(0,'127.0.0.1',resolve));
  f.upstreamBase = `http://127.0.0.1:${f.upstream.address().port}`;
  fs.writeFileSync(path.join(directory,'.env'),`AI_API_BASE_URL=${f.upstreamBase}/p0/v1\nAI_API_PROBE_BASE_URL=${f.upstreamBase}/p0/v1\nAI_API_KEY=fixture-key-0\nAI_MODEL=fixture-model-0\nAI_API_MODE=chat_completions\nAI_CUSTOM_HEADERS_JSON={"X-Fixture":"value"}\n`);
  json(path.join(directory,'config/provider.yaml'),{schema_version:2,provider:{model:'fixture-model-0',api_mode:'chat_completions',base_url:f.upstreamBase+'/p0/v1',capabilities:{chat_completions:true,responses:false,vision:true}}});
  json(path.join(directory,'config/runtime.yaml'),{schema_version:2,enabled:true,revision:1});
  const migrated = await command(['--deploy-dir',directory,'migrate']); assert.equal(migrated.code,0,migrated.stdout+ migrated.stderr);
  f.poolFile = path.join(directory,'config/provider-pool-applied.json');
  f.pool = read(f.poolFile);
  f.secret = read(path.join(directory,'secrets/provider/generations',f.pool.secrets_generation+'.json')).entries;
  f.key = /^PROVIDER_ADAPTER_KEY=(.*)$/m.exec(fs.readFileSync(path.join(directory,'.env'),'utf8'))[1];
  for (let index=1;index<count;index++) {
    const id='p_'+index.toString(16).padStart(24,'0');
    f.pool.entries.push({...copy(f.pool.entries[0]),id,name:'备用'+index,base_url:f.upstreamBase+`/p${index}/v1`,model:'fixture-model-'+index,role:'backup',order:index});
    f.secret[id]={api_key:'fixture-key-'+index,custom_headers:{'x-fixture':'value'}};
  }
  f.pool.policy={...DEFAULT_POLICY,...policy};
  f.publish = (change=()=>{}) => {
    change(f.pool,f.secret); f.pool.revision+=1; f.pool.secrets_generation=crypto.randomBytes(16).toString('hex');
    json(path.join(directory,'secrets/provider/generations',f.pool.secrets_generation+'.json'),{schema_version:1,generation:f.pool.secrets_generation,revision:f.pool.revision,entries:f.secret});
    json(path.join(directory,'config/provider-pool.yaml'),Object.fromEntries(Object.entries(f.pool).filter(([key])=>key!=='secrets_generation')));
    const temporary=f.poolFile+'.tmp';json(temporary,f.pool);fs.renameSync(temporary,f.poolFile);
  };
  f.publish();
  f.environment={PROVIDER_ROOT:directory,PROVIDER_POOL_REQUIRED:'true',PROVIDER_REQUIRE_ENVELOPE:'true',PROVIDER_ADAPTER_KEY:f.key};
  f.start = async () => {f.adapter=createAdapter(f.environment);await new Promise(resolve=>f.adapter.listen(0,'127.0.0.1',resolve));f.base=`http://127.0.0.1:${f.adapter.address().port}`;};
  await f.start();
  f.envelope = (stage='answer',extra={}) => ({version:1,scope:'admin',question_id:crypto.randomBytes(32).toString('hex'),runtime_revision:1,pool_revision:read(f.poolFile).revision,deadline_at:Date.now()+90000,stage,...extra});
  f.post = async (body=sample,envelope=f.envelope(),options={}) => {
    const response=await fetch(f.base+'/v1/chat/completions',{method:'POST',headers:{authorization:'Bearer '+f.key,'content-type':'application/json',...(envelope? {'x-crispai-question':signEnvelope(envelope,f.key)}:{})},body:JSON.stringify(body),...options});
    const text=await response.text();let value;try{value=JSON.parse(text);}catch(_){}return{status:response.status,value,text};
  };
  f.get = async action => (await fetch(f.base+'/internal/provider/'+action,{headers:{authorization:'Bearer '+f.key}})).json();
  f.cli = (args,environment={}) => command(['--deploy-dir',directory,...args],{PROVIDER_ADAPTER_MANAGEMENT_URL:f.base,...environment});
  f.file = value => { const file=path.join(directory,'candidate-'+crypto.randomBytes(4).toString('hex')+'.json');json(file,value);return file; };
  f.reload = () => {f.pool=read(f.poolFile);f.secret=read(path.join(directory,'secrets/provider/generations',f.pool.secrets_generation+'.json')).entries;};
  f.restart = async () => {f.adapter.closeAllConnections();await new Promise(resolve=>f.adapter.close(resolve));await f.start();};
  f.close = async () => {f.adapter.closeAllConnections();f.upstream.closeAllConnections();await Promise.all([new Promise(resolve=>f.adapter.close(resolve)),new Promise(resolve=>f.upstream.close(resolve))]);};
  return f;
}

let count=0;
async function test(name,work) { await work();count++;process.stdout.write('通过 UNIT/PROTOCOL：'+name+'\n'); }

async function main() {
  await test('幂等单接口迁移、独立内部Key、非敏感池与同代秘密',async()=>{
    const f=await fixture();try {
      const before=fs.readFileSync(f.poolFile,'utf8');const result=await f.cli(['migrate']);assert.equal(result.code,0);assert.equal(fs.readFileSync(f.poolFile,'utf8'),before);
      assert.equal(f.pool.entries.length,1);assert.equal(f.pool.entries.filter(entry=>entry.role==='primary').length,1);assert.equal(f.pool.entries[0].id,f.pool.primary_id);
      assert.notEqual(f.key,'fixture-key-0');assert.equal(f.pool.entries[0].base_url,f.upstreamBase+'/p0/v1');
      const visible=JSON.stringify((await f.cli(['list'])).value);assert.ok(!visible.includes('fixture-key-0'));assert.ok(!visible.includes('"x-fixture":"value"'));
      assert.equal((await f.post(sample,null)).status,400);assert.equal(f.calls.length,0);
      assert.equal((await fetch(f.base+'/v1/chat/completions',{method:'POST',headers:{authorization:'Bearer fixture-key-0'},body:JSON.stringify(sample)})).status,401);
    }finally{await f.close();}
  });
  await test('管理添加20备、停用仍占21容量、原子设主排序删除与每接口模型列表',async()=>{
    const f=await fixture();try {
      for(let index=1;index<=20;index++) {
        const result=await f.cli(['add',f.file({provider:{name:'备用'+index,base_url:f.upstreamBase+`/p${index}/v1`,model:'fixture-model-'+index,api_mode:'chat_completions'},api_key:'fixture-key-'+index})]);assert.equal(result.code,0,result.stdout);
      }
      f.reload();assert.equal(f.pool.entries.length,21);
      const backup=f.pool.entries[20].id;assert.equal((await f.cli(['enable',backup,'false'])).code,0);
      assert.equal((await f.cli(['add',f.file({provider:{},api_key:'fixture'})])).value.error.code,'pool_capacity');
      assert.equal((await f.cli(['primary',backup])).code,0);f.reload();assert.equal(f.pool.entries[0].id,backup);assert.equal(f.pool.entries[0].enabled,true);
      const selected=await f.post();assert.equal(selected.status,200);assert.equal(f.calls.at(-1).index,20);assert.equal(f.calls.at(-1).body.model,'fixture-model-20');assert.equal(f.calls.at(-1).headers.authorization,'Bearer fixture-key-20');
      assert.equal((await f.cli(['delete',backup])).value.error.code,'primary_required');
      const order=f.pool.entries.slice(1).map(entry=>entry.id).reverse();assert.equal((await f.cli(['order',f.file({ids:order})])).code,0);f.reload();assert.deepEqual(f.pool.entries.slice(1).map(entry=>entry.id),order);
      const models=await f.cli(['models',backup]);assert.equal(models.code,0,models.stdout);assert.deepEqual(models.value.models,['fixture-a','fixture-b']);assert.match(f.calls.at(-1).path,/p20\/v1\/models$/);
      assert.equal((await f.cli(['delete',order[0]])).code,0);
    }finally{await f.close();}
  });
  await test('20条失败后最后1条成功、21总次数、模型/Header按候选切换、SSE只包装整答',async()=>{
    const f=await fixture(21);try {
      f.behavior=async(call,response)=>{if(call.index<20){response.writeHead(503);response.end(JSON.stringify({error:{message:'不可输出的上游正文 fixture-key-0'}}));return true;}return false;};
      const envelope=f.envelope(), result=await f.post({...sample,stream:true},envelope);assert.equal(result.status,200,result.text);assert.match(result.text,/data: \[DONE\]/);assert.equal(f.calls.length,21);
      assert.equal(f.calls[20].body.model,'fixture-model-20');assert.equal(f.calls[20].headers.authorization,'Bearer fixture-key-20');assert.equal(f.calls[20].headers['x-fixture'],'value');assert.ok(!result.text.includes('fixture-key'));
      assert.equal((await f.post(sample,envelope)).status,200);assert.equal(f.calls.length,21);
      const recent=await f.get('recent');assert.equal(recent.records.length,21);assert.ok(!JSON.stringify(recent).includes('fixture-key'));assert.ok(!JSON.stringify(recent).includes('http:'));
      assert.ok(recent.records.every(record=>record.pool_revision===f.pool.revision && Number.isSafeInteger(record.remaining_budget_ms) && record.remaining_budget_ms>=0 && record.remaining_budget_ms<=f.pool.policy.question_timeout_ms));
    }finally{await f.close();}
  });
  await test('401共享认证范围、429额度/Retry-After不截短、模型不存在仅影响同模型',async()=>{
    const f=await fixture(3);try {
      f.publish((pool,secret)=>{secret[pool.entries[1].id]=copy(secret[pool.entries[0].id]);});
      f.behavior=async(call,response)=>{if(call.index===0){response.writeHead(401);response.end(JSON.stringify({error:{code:'invalid_api_key'}}));return true;}return false;};
      assert.equal((await f.post()).status,200);assert.deepEqual(f.calls.map(call=>call.index),[0,2]);
      await f.restart();assert.equal((await f.post()).status,200);assert.equal(f.calls.at(-1).index,2);
    }finally{await f.close();}
    const g=await fixture(3);try {
      g.publish((pool,secret)=>{secret[pool.entries[1].id]=copy(secret[pool.entries[0].id]);});
      g.behavior=async(call,response)=>{if(call.index===0){response.writeHead(404);response.end(JSON.stringify({error:{code:'model_not_found'}}));return true;}return false;};
      assert.equal((await g.post()).status,200);assert.deepEqual(g.calls.map(call=>call.index),[0,1]);
    }finally{await g.close();}
    assert.equal(retryAfterMilliseconds('900'),900000);assert.ok(retryAfterMilliseconds(new Date(Date.now()+900000).toUTCString())>899000);
    for(const code of ['credit_balance_exhausted','project_spend_limit_exceeded','organization_spend_limit_exceeded','organization_usage_limit_exceeded'])assert.equal(classifyFailure(429,{error:{code}}).kind,'quota_exhausted');
  });
  await test('Responses拒绝/不完整usage保持、业务不知道与输入错误不切备用',async()=>{
    const f=await fixture(2);try {
      f.publish(pool=>{pool.entries[0].api_mode='responses';pool.entries[0].capabilities.responses=true;});
      f.behavior=async(call,response)=>{response.end(JSON.stringify({status:'completed',output:[{type:'message',content:[{type:'refusal',refusal:'无法协助该请求'}]}],usage:{input_tokens:4,output_tokens:2,output_tokens_details:{reasoning_tokens:1}}}));return true;};
      const result=await f.post();assert.equal(result.status,200);assert.equal(result.value.choices[0].message.refusal,'无法协助该请求');assert.equal(result.value.usage.total_tokens,6);assert.equal(result.value.usage.completion_tokens_details.reasoning_tokens,1);assert.equal(f.calls.length,1);
      f.behavior=async(call,response)=>{response.end(JSON.stringify({status:'incomplete',incomplete_details:{reason:'max_output_tokens'},output_text:'部分但完整接收的回答',usage:{input_tokens:2,output_tokens:3}}));return true;};
      const incomplete=await f.post();assert.equal(incomplete.value.choices[0].finish_reason,'length');assert.equal(f.calls.length,2);
      f.behavior=async(call,response)=>{response.end(JSON.stringify({output_text:'不知道，资料未提到。'}));return true;};assert.equal((await f.post()).status,200);assert.equal(f.calls.length,3);
      f.behavior=async(call,response)=>{response.writeHead(400);response.end(JSON.stringify({error:{code:'invalid_request_error'}}));return true;};assert.equal((await f.post()).status,400);assert.equal(f.calls.length,4);
    }finally{await f.close();}
  });
  await test('视觉与回答共享预算，图片不静默删除、重复并发不放大调用',async()=>{
    const f=await fixture(3,{max_attempts:3});try {
      f.behavior=async(call,response)=>{const vision=Array.isArray(call.body.messages?.[0]?.content);if(call.index===0 || !vision){response.writeHead(503);response.end('{}');return true;}return false;};
      const envelope=f.envelope('vision');const vision={messages:[{role:'user',content:[{type:'text',text:'描述合成图片'},{type:'image_url',image_url:{url:image}}]}]};
      assert.equal((await f.post(vision,envelope)).status,200);assert.equal(f.calls.length,2);assert.equal(f.calls[1].body.messages[0].content[1].image_url.url,image);
      const answer=await f.post(sample,{...envelope,stage:'answer'});assert.equal(answer.status,400);assert.equal(answer.value.error.code,'question_budget_exhausted');assert.equal(f.calls.length,3);
      await f.post(sample,{...envelope,stage:'answer'});assert.equal(f.calls.length,3);
    }finally{await f.close();}
    const g=await fixture();try {
      g.behavior=async()=>{await sleep(100);return false;};const envelope=g.envelope();const results=await Promise.all([g.post(sample,envelope),g.post(sample,envelope),g.post(sample,envelope)]);
      assert.ok(results.every(result=>result.status===200));assert.equal(g.calls.length,1);
    }finally{await g.close();}
  });
  await test('AnythingLLM消息信封去除、伪造信封拒绝、未授权供应商状态拒绝',async()=>{
    const f=await fixture();try {
      const envelope=f.envelope();const body=copy(sample);body.messages[1].content+='\n'+envelopeMarker(envelope,f.key);
      assert.equal((await f.post(body,null)).status,200);assert.ok(!JSON.stringify(f.calls[0].body).includes('CRISPAI_PROVIDER_CONTEXT'));
      body.messages[1].content+='[[CRISPAI_PROVIDER_CONTEXT_V1:tampered]]';assert.equal((await f.post(body,null)).status,400);assert.equal(f.calls.length,1);
      for(const field of ['previous_response_id','thread_id','file_ids']) {
        assert.equal((await f.post({...sample,[field]:field==='file_ids'?['provider-specific']:'provider-specific'})).status,400);assert.equal(f.calls.length,1);
      }
    }finally{await f.close();}
  });
  await test('冷却跨重启保持、单半开租约、连续两次业务成功恢复且无后台付费探测',async()=>{
    const f=await fixture(2,{cooldown_initial_ms:1000,cooldown_max_ms:1000});try {
      let failed=false;f.behavior=async(call,response)=>{if(call.index===0&&!failed){failed=true;response.writeHead(503);response.end('{}');return true;}if(call.index===0)await sleep(180);return false;};
      assert.equal((await f.post()).status,200);await f.restart();assert.equal((await f.post()).status,200);assert.equal(f.calls.at(-1).index,1);
      await sleep(1100);const before=f.calls.length;await Promise.all([f.post(),f.post()]);assert.equal(f.calls.slice(before).filter(call=>call.index===0).length,1);
      assert.equal((await f.get('status')).entries[0].health,'unknown');await f.post();assert.equal((await f.get('status')).entries[0].health,'healthy');
      const total=f.calls.length;await sleep(200);assert.equal(f.calls.length,total);
      f.behavior=async(call,response)=>{if(call.index===0){response.writeHead(503);response.end('{}');return true;}return false;};
      assert.equal((await f.post()).status,200);assert.deepEqual(f.calls.slice(total).map(call=>call.index),[0,1]);assert.equal((await f.get('status')).entries[0].health,'cooling');
      await sleep(1100);f.behavior=null;await f.post();assert.equal((await f.get('status')).entries[0].health,'unknown');
    }finally{await f.close();}
  });
  await test('人工接管、总开关、池热改取消在途且不记上游故障',async()=>{
    for(const control of ['human','global','pool']) {
      const f=await fixture(2);try {
        f.behavior=async()=>{await sleep(400);return false;};const sessionKey='a'.repeat(64),envelope=f.envelope('answer',{scope:'conversation',session_key:sessionKey,generation:2});
        const session={schema_version:2,mode:'ai',generation:2,uncertain_events:[],jobs:[{id:envelope.question_id,generation:2,revision:1,status:'processing'}]};
        const sessionFile=path.join(f.directory,'data/runtime/session-'+sessionKey+'.json');json(sessionFile,session);
        const pending=f.post(sample,envelope);while(!f.calls.length)await sleep(5);
        if(control==='human')json(sessionFile,{...session,mode:'human',generation:3});
        if(control==='global')json(path.join(f.directory,'config/runtime.yaml'),{schema_version:2,enabled:false,revision:2});
        if(control==='pool')f.publish(pool=>{pool.entries[1].enabled=false;});
        const result=await pending;assert.equal(result.status,400);assert.equal(result.value.error.code,'question_cancelled');assert.equal(f.calls.length,1);
        assert.equal((await f.get('recent')).records.filter(record=>record.outcome==='failed').length,0);
        assert.equal((await f.post(sample,envelope)).status,400);assert.equal(f.calls.length,1);
      }finally{await f.close();}
    }
  });
  await test('200 HTML/空响应/断连顺序回退；上游超时有界、终态SDK重试无新增调用',async()=>{
    const f=await fixture(4);try {
      f.behavior=async(call,response)=>{if(call.index===0){response.end('<html>error</html>');return true;}if(call.index===1){response.end('{}');return true;}if(call.index===2){response.destroy();return true;}return false;};
      assert.equal((await f.post()).status,200);assert.deepEqual(f.calls.map(call=>call.index),[0,1,2,3]);
    }finally{await f.close();}
    const g=await fixture(1,{call_timeout_ms:1000,connect_timeout_ms:200,question_timeout_ms:2000});try {
      g.behavior=async()=>{await sleep(1300);return false;};const envelope=g.envelope();const started=Date.now();const result=await g.post(sample,envelope);assert.equal(result.status,400);assert.ok(Date.now()-started<2000);assert.equal(g.calls.length,1);
      await g.post(sample,envelope);assert.equal(g.calls.length,1);
    }finally{await g.close();}
  });
  await test('A13 多候选连续挂起共享总期限，剩余时间不够时不继续遍历',async()=>{
    const f=await fixture(3,{call_timeout_ms:1200,connect_timeout_ms:200,question_timeout_ms:2000});try {
      let closed=0;f.behavior=async(_call,response)=>{response.once('close',()=>{closed++;});return true;};
      const envelope=f.envelope(),started=Date.now();const result=await f.post(sample,envelope);const elapsed=Date.now()-started;
      assert.equal(result.status,400);assert.equal(result.value.error.code,'question_timeout');
      assert.deepEqual(f.calls.map(call=>call.index),[0,1]);assert.ok(elapsed>=1900&&elapsed<3000,`共享2秒预算实耗${elapsed}ms`);
      await until(()=>closed===2,'两个挂起请求均应被取消');await f.post(sample,envelope);assert.equal(f.calls.length,2);
    }finally{await f.close();}
  });
  await test('A08 新接口池拒绝上游重定向，第三方接收端拿不到Key或Header',async()=>{
    let received=0;const collector=http.createServer((_request,response)=>{received++;response.end('{}');});
    await new Promise(resolve=>collector.listen(0,'127.0.0.1',resolve));
    const f=await fixture(2);try {
      f.behavior=async(call,response)=>{if(call.index===0){response.writeHead(302,{location:`http://127.0.0.1:${collector.address().port}/capture`});response.end('{}');return true;}return false;};
      assert.equal((await f.post()).status,200);assert.deepEqual(f.calls.map(call=>call.index),[0,1]);assert.equal(received,0);
      assert.equal(f.calls[1].headers.authorization,'Bearer fixture-key-1');assert.equal(f.calls[1].body.model,'fixture-model-1');
    }finally{await f.close();collector.closeAllConnections();await new Promise(resolve=>collector.close(resolve));}
  });
  await test('编辑先验证失败保旧、Key/Header分代热改与实际运行回读',async()=>{
    const f=await fixture(2);try {
      const before=fs.readFileSync(f.poolFile,'utf8');f.behavior=async(call,response)=>{if(call.body.model==='invalid-model'){response.writeHead(404);response.end(JSON.stringify({error:{code:'model_not_found'}}));return true;}return false;};
      let result=await f.cli(['edit',f.pool.primary_id,f.file({provider:{model:'invalid-model'}})]);assert.notEqual(result.code,0);assert.equal(fs.readFileSync(f.poolFile,'utf8'),before);
      result=await f.cli(['edit',f.pool.primary_id,f.file({provider:{model:'new-model',custom_headers:{'X-New':'new-value'}},api_key:'new-fixture-key'})]);assert.equal(result.code,0,result.stdout);f.reload();assert.equal(f.secret[f.pool.primary_id].api_key,'new-fixture-key');
      assert.equal((await f.post()).status,200);assert.equal(f.calls.at(-1).body.model,'new-model');assert.equal(f.calls.at(-1).headers['x-new'],'new-value');assert.equal(f.calls.at(-1).headers['x-fixture'],'value');
      result=await f.cli(['edit',f.pool.primary_id,f.file({provider:{remove_header:'X-Fixture'}})]);assert.equal(result.code,0,result.stdout);await f.post();assert.equal(f.calls.at(-1).headers['x-fixture'],undefined);
    }finally{await f.close();}
  });
  await test('429真实HTTP共享额度冷却及秒数/HTTP日期Retry-After均不截短',async()=>{
    for(const retry of ['900',new Date(Date.now()+900000).toUTCString()]) {
      const f=await fixture(3);try {
        f.publish((pool,secret)=>{secret[pool.entries[1].id]=copy(secret[pool.entries[0].id]);});
        f.behavior=async(call,response)=>{if(call.index===0){response.writeHead(429,{'retry-after':retry});response.end(JSON.stringify({error:{code:'project_spend_limit_exceeded'}}));return true;}return false;};
        assert.equal((await f.post()).status,200);assert.deepEqual(f.calls.map(call=>call.index),[0,2]);
        const status=await f.get('status');assert.ok(status.entries[0].cooldown_until>Date.now()+890000);assert.equal(status.entries[1].health,'cooling');
        assert.equal((await f.get('recent')).records.find(item=>item.entry_id===f.pool.primary_id).error_class,'quota_exhausted');
      }finally{await f.close();}
    }
  });
  await test('每接口上下文与图片能力筛选、Responses图片实际出站不丢图',async()=>{
    const f=await fixture(2);try {
      f.publish(pool=>{pool.entries[0].context_window=512;pool.entries[0].max_output_tokens=64;pool.entries[0].capabilities.vision=false;pool.entries[1].api_mode='responses';pool.entries[1].capabilities.responses=true;});
      assert.equal((await f.post({messages:[{role:'user',content:'x'.repeat(1000)}]})).status,200);assert.deepEqual(f.calls.map(call=>call.index),[1]);
      const result=await f.post({messages:[{role:'user',content:[{type:'text',text:'合成图片'},{type:'image_url',image_url:{url:image}}]}]},f.envelope('vision'));
      assert.equal(result.status,200);assert.equal(f.calls.at(-1).body.input[0].content[1].image_url,image);assert.equal(f.calls.length,2);
    }finally{await f.close();}
  });
  await test('完整池源校验与应用、跨实例导入缺Key草稿、有效主保持',async()=>{
    const f=await fixture(2);try {
      const source=Object.fromEntries(Object.entries(f.pool).filter(([key])=>key!=='secrets_generation'));
      assert.equal((await f.cli(['validate-file',f.file(source)])).code,0);
      const sensitive=copy(source);sensitive.entries[0].api_key='must-not-be-public';assert.notEqual((await f.cli(['validate-file',f.file(sensitive)])).code,0);assert.equal(f.calls.length,0);
      const changed=copy(source);changed.entries[1].model='changed-model';assert.equal((await f.cli(['apply-file',f.file(changed)])).code,0);f.reload();assert.equal(f.pool.entries[1].model,'changed-model');
      const imported=copy(changed);imported.entries[1].id='p_'+'b'.repeat(24);assert.equal((await f.cli(['import',f.file(imported)])).code,0);f.reload();assert.equal(f.pool.entries[1].draft,true);assert.equal(f.pool.entries[1].enabled,false);
      assert.equal((await f.post()).status,200);assert.equal((await f.cli(['enable',imported.entries[1].id,'true'])).code,1);
      const unknown=copy(source);unknown.entries[0].id='p_'+'c'.repeat(24);unknown.primary_id=unknown.entries[0].id;
      const before=fs.readFileSync(f.poolFile,'utf8');const draft=await f.cli(['import',f.file(unknown)]);assert.equal(draft.code,0);assert.equal(draft.value.applied,false);assert.equal(draft.value.draft,true);assert.equal(fs.readFileSync(f.poolFile,'utf8'),before);
    }finally{await f.close();}
  });
  await test('Python管理员签名与JS验证一致、停客服可显式测试、签名预算受限',async()=>{
    const f=await fixture();try {
      json(path.join(f.directory,'config/runtime.yaml'),{schema_version:2,enabled:false,revision:2});
      const result=await f.cli(['admin-marker','2000']);assert.equal(result.code,0,result.stdout);assert.ok(result.value.deadline_at<=Date.now()+2000);
      const body=copy(sample);body.messages[1].content+='\n'+result.value.marker;assert.equal((await f.post(body,null)).status,200);assert.ok(!JSON.stringify(f.calls[0].body).includes('CRISPAI_PROVIDER'));
    }finally{await f.close();}
  });
  await test('提交后回读失败恢复旧配置但代次递增，旧信封不能重新生效',async()=>{
    const f=await fixture(2);try {
      const envelope=f.envelope(),before=copy(f.pool);assert.equal((await f.post(sample,envelope)).status,200);
      const result=await f.cli(['enable',f.pool.entries[1].id,'false'],{PROVIDER_ADAPTER_MANAGEMENT_URL:'http://127.0.0.1:1'});
      assert.notEqual(result.code,0);f.reload();assert.ok(f.pool.revision>before.revision+1);assert.deepEqual(f.pool.entries,before.entries);
      assert.equal((await f.post(sample,envelope)).status,400);assert.equal(f.calls.length,1);
      assert.ok(fs.existsSync(path.join(f.directory,'backups/config-history/provider-pool',before.revision+'.json')));
    }finally{await f.close();}
  });
  await test('未知主导入草稿可补Key、保持稳定ID并完整验证应用',async()=>{
    const f=await fixture(2);try {
      const source=Object.fromEntries(Object.entries(f.pool).filter(([key])=>key!=='secrets_generation'));
      source.entries[0].id='p_'+'d'.repeat(24);source.primary_id=source.entries[0].id;
      source.entries[1].id='p_'+'e'.repeat(24);
      assert.equal((await f.cli(['import',f.file(source)])).value.applied,false);
      const list=await f.cli(['draft']);assert.equal(list.code,0);assert.equal(list.value.entries[0].key_status,'待填写');
      const item=await f.cli(['draft-entry',source.primary_id]);assert.equal(item.value.entry.id,source.primary_id);
      const edited=await f.cli(['edit-draft',source.primary_id,f.file({provider:{},api_key:'imported-fixture-key'})]);assert.equal(edited.code,0,edited.stdout);assert.equal(edited.value.applied,false);
      assert.equal(read(f.poolFile).primary_id,f.pool.primary_id);
      const applied=await f.cli(['apply-draft']);assert.equal(applied.code,0,applied.stdout);assert.equal(applied.value.primary_id,source.primary_id);assert.equal(applied.value.entries[1].draft,true);
      assert.equal((await f.post()).status,200);assert.equal(f.calls.at(-1).headers.authorization,'Bearer imported-fixture-key');
      assert.ok(!JSON.stringify((await f.cli(['draft'])).value).includes('imported-fixture-key'));
    }finally{await f.close();}
  });
  await test('中文Emoji与ASCII混合token估算允许正常RAG，上游真实上下文拒绝不遍历备用',async()=>{
    const f=await fixture(2);try {
      const content='正常中文资料😀'.repeat(50)+'document content '.repeat(700);
      assert.ok(Buffer.byteLength(content)>8192);assert.ok(estimateTextTokens(content)+1200+272<8192);
      assert.equal((await f.post({messages:[{role:'user',content}]})).status,200);assert.equal(f.calls.length,1);
      f.behavior=async(call,response)=>{response.writeHead(400);response.end(JSON.stringify({error:{code:'context_length_exceeded'}}));return true;};
      assert.equal((await f.post()).status,400);assert.equal(f.calls.length,2);
    }finally{await f.close();}
  });
  await test('明确模型不支持图片时只冷却视觉并切备用，文字仍用主且共享问题预算',async()=>{
    const failures=[
      {code:'image_not_supported',message:'This model does not support image input.'},
      {code:'unsupported_image',message:'The selected model does not support images.'},
      {type:'invalid_request_error',message:'Image input is not supported by this model.'}
    ];
    for(const failure of failures) {
      const f=await fixture(2,{max_attempts:3});try {
        const visual={messages:[{role:'user',content:[{type:'text',text:'合成图片问题'},{type:'image_url',image_url:{url:image}}]}]};
        f.behavior=async(call,response)=>{if(call.index===0&&Array.isArray(call.body.messages?.[0]?.content)){response.writeHead(400);response.end(JSON.stringify({error:failure}));return true;}return false;};
        const envelope=f.envelope('vision');const first=await f.post(visual,envelope);assert.equal(first.status,200,first.text);assert.deepEqual(f.calls.map(call=>call.index),[0,1]);
        assert.equal(f.calls[1].body.messages[0].content[1].image_url.url,image);
        const status=await f.get('status');assert.equal(status.entries[0].vision_health,'cooling');assert.notEqual(status.entries[0].health,'cooling');
        const until=status.entries[0].vision_cooldown_until;
        assert.equal((await f.post(sample,{...envelope,stage:'answer'})).status,200);assert.deepEqual(f.calls.map(call=>call.index),[0,1,0]);
        assert.equal(read(path.join(f.directory,'data/provider-router/questions',envelope.question_id+'.json')).attempts,3);
        assert.equal((await f.get('status')).entries[0].vision_cooldown_until,until);
        await f.post(visual,f.envelope('vision'));assert.equal(f.calls.at(-1).index,1);
        await f.restart();await f.post(visual,f.envelope('vision'));assert.equal(f.calls.at(-1).index,1);assert.equal(f.calls.filter(call=>call.index===0).length,2);
        assert.equal((await f.get('recent')).records.find(record=>record.outcome==='failed').error_class,'vision_unsupported');
      }finally{await f.close();}
    }
  });
  await test('视觉备用不绕过坏图、一般输入错误、安全拒绝或无图请求',async()=>{
    const failures=[
      {error:{code:'invalid_image',message:'The image data is malformed.'}},
      {error:{code:'unsupported_image',message:'Unsupported image format. Use PNG or JPEG.'}},
      {error:{code:'unsupported_image'}},
      {error:{type:'invalid_request_error',message:'Invalid image URL.'}},
      {error:{code:'image_not_supported',type:'content_policy_violation',message:'The selected model does not support images.'}},
      {error:{code:'unsupported_image',message:'The selected model does not support images.'},text:true},
      {refusal:true}
    ];
    for(const failure of failures) {
      const f=await fixture(2);try {
        const visual={messages:[{role:'user',content:[{type:'text',text:'合成图片问题'},{type:'image_url',image_url:{url:image}}]}]};
        f.behavior=async(call,response)=>{response.writeHead(failure.refusal?200:400);response.end(JSON.stringify(failure.refusal?{choices:[{message:{role:'assistant',content:null,refusal:'不能协助此请求'},finish_reason:'stop'}]}:{error:failure.error}));return true;};
        const envelope=f.envelope(failure.text?'answer':'vision'),body=failure.text?sample:visual;
        const result=await f.post(body,envelope);assert.equal(result.status,failure.refusal?200:400,result.text);assert.equal(f.calls.length,1);
        if(failure.refusal)assert.equal(result.value.choices[0].message.refusal,'不能协助此请求');
        await f.post(body,envelope);assert.equal(f.calls.length,1);
        const status=await f.get('status');assert.notEqual(status.entries[0].health,'cooling');assert.notEqual(status.entries[0].vision_health,'cooling');
      }finally{await f.close();}
    }
  });
  await test('视觉能力冷却半开仅允许一次并发恢复，连续两次视觉成功才恢复健康',async()=>{
    const f=await fixture(2,{cooldown_initial_ms:1000,cooldown_max_ms:1000});try {
      const visual={messages:[{role:'user',content:[{type:'text',text:'合成图片问题'},{type:'image_url',image_url:{url:image}}]}]};
      let failed=false;
      f.behavior=async(call,response)=>{if(call.index===0&&Array.isArray(call.body.messages?.[0]?.content)){if(!failed){failed=true;response.writeHead(400);response.end(JSON.stringify({error:{code:'image_not_supported',message:'This model does not support image input.'}}));return true;}await sleep(180);}return false;};
      assert.equal((await f.post(visual,f.envelope('vision'))).status,200);
      await f.post();await f.post();assert.equal((await f.get('status')).entries[0].vision_health,'cooling');
      await sleep(1100);const before=f.calls.length;await Promise.all([f.post(visual,f.envelope('vision')),f.post(visual,f.envelope('vision'))]);
      assert.equal(f.calls.slice(before).filter(call=>call.index===0).length,1);assert.equal((await f.get('status')).entries[0].vision_health,'unknown');
      await f.post(visual,f.envelope('vision'));assert.equal((await f.get('status')).entries[0].vision_health,'healthy');
    }finally{await f.close();}
  });
  await test('A05 主备独立Key获取模型，选择后实际调用；改备不改主且备用使用新Key/模型',async()=>{
    const f=await fixture(2);try {
      const primary=f.pool.primary_id,backup=f.pool.entries[1].id,newKey='fixture-rotated-backup-key';let failPrimary=false;
      f.behavior=async(call,response)=>{
        if(call.path.endsWith('/models')) {
          const model=call.index===0?'listed-primary-model':call.headers.authorization==='Bearer '+newKey?'listed-new-backup-model':'listed-backup-model';
          response.end(JSON.stringify({data:[{id:model},{id:model}]}));return true;
        }
        if(failPrimary&&call.index===0){response.writeHead(503);response.end('{}');return true;}
        return false;
      };
      const primaryModels=await f.cli(['models',primary]);assert.equal(primaryModels.code,0,primaryModels.stdout);
      assert.deepEqual(primaryModels.value.models,['listed-primary-model']);
      assert.equal(f.calls.at(-1).method,'GET');assert.equal(f.calls.at(-1).path,'/p0/v1/models');assert.equal(f.calls.at(-1).headers.authorization,'Bearer fixture-key-0');
      assert.equal((await f.cli(['edit',primary,f.file({provider:{model:primaryModels.value.models[0]}})])).code,0);f.reload();
      assert.equal((await f.post()).value.model,'listed-primary-model');assert.equal(f.calls.at(-1).body.model,'listed-primary-model');assert.equal(f.calls.at(-1).headers.authorization,'Bearer fixture-key-0');
      const primaryBefore=copy(f.pool.entries[0]),primarySecretBefore=copy(f.secret[primary]);
      const backupModels=await f.cli(['models',backup]);assert.equal(backupModels.code,0,backupModels.stdout);
      assert.deepEqual(backupModels.value.models,['listed-backup-model']);assert.equal(f.calls.at(-1).method,'GET');assert.equal(f.calls.at(-1).path,'/p1/v1/models');assert.equal(f.calls.at(-1).headers.authorization,'Bearer fixture-key-1');
      const refreshed=await f.cli(['models',backup,f.file({provider:{},api_key:newKey})]);assert.equal(refreshed.code,0,refreshed.stdout);
      assert.deepEqual(refreshed.value.models,['listed-new-backup-model']);assert.equal(f.calls.at(-1).method,'GET');assert.equal(f.calls.at(-1).headers.authorization,'Bearer '+newKey);
      const result=await f.cli(['edit',backup,f.file({provider:{name:'改名后仍是原备用',model:refreshed.value.models[0]},api_key:newKey})]);assert.equal(result.code,0,result.stdout);f.reload();assert.equal(f.pool.entries[1].name,'改名后仍是原备用');
      assert.deepEqual(f.pool.entries[0],primaryBefore);assert.deepEqual(f.secret[primary],primarySecretBefore);assert.equal(f.pool.entries[1].id,backup);assert.equal(f.secret[backup].api_key,newKey);
      failPrimary=true;const before=f.calls.length,answer=await f.post();assert.equal(answer.status,200,answer.text);assert.equal(answer.value.model,'listed-new-backup-model');
      const attempts=f.calls.slice(before);assert.deepEqual(attempts.map(call=>call.index),[0,1]);
      assert.equal(attempts[0].body.model,'listed-primary-model');assert.equal(attempts[0].headers.authorization,'Bearer fixture-key-0');
      assert.equal(attempts[1].body.model,'listed-new-backup-model');assert.equal(attempts[1].headers.authorization,'Bearer '+newKey);
    }finally{await f.close();}
  });
  await test('A23 慢备用未完成时主恢复服务新问题，原问题不抢占不重复且只交付备用整答',async()=>{
    const f=await fixture(2,{question_timeout_ms:8000,call_timeout_ms:5000,connect_timeout_ms:200,cooldown_initial_ms:1000,cooldown_max_ms:1000});
    let releaseBackup;const backupGate=new Promise(resolve=>{releaseBackup=resolve;});
    try {
      let firstPrimary=true,backupEntered=false,oldSettled=false;
      f.behavior=async(call,response)=>{
        if(call.index===0&&firstPrimary){firstPrimary=false;response.writeHead(503);response.end('{}');return true;}
        if(call.index===1){backupEntered=true;await backupGate;response.end(JSON.stringify(chat('旧问题仅由原备用完整回答')));return true;}
        response.end(JSON.stringify(chat('恢复主接口只回答新问题')));return true;
      };
      const oldEnvelope=f.envelope(),oldBody={messages:[{role:'user',content:'原问题等待备用'}]};
      const pending=f.post(oldBody,oldEnvelope).then(result=>{oldSettled=true;return result;});
      await until(()=>backupEntered,'原问题未进入慢备用');
      const cooling=(await f.get('status')).entries[0];assert.equal(cooling.health,'cooling');assert.equal(oldSettled,false);
      await sleep(Math.max(0,cooling.cooldown_until-Date.now())+40);
      const newEnvelope=f.envelope(),newBody={messages:[{role:'user',content:'冷却到期后的独立新问题'}]};
      const current=await f.post(newBody,newEnvelope);assert.equal(current.status,200,current.text);assert.equal(current.value.choices[0].message.content,'恢复主接口只回答新问题');
      assert.equal(oldSettled,false);assert.deepEqual(f.calls.map(call=>call.index),[0,1,0]);assert.equal((await f.get('status')).entries[0].health,'unknown');
      releaseBackup();const previous=await pending;assert.equal(previous.status,200,previous.text);assert.equal(previous.value.choices[0].message.content,'旧问题仅由原备用完整回答');assert.equal(previous.value.model,'fixture-model-1');
      assert.deepEqual(f.calls.map(call=>call.index),[0,1,0]);
      const successes=(await f.get('recent')).records.filter(record=>record.outcome==='success');
      assert.equal(successes.filter(record=>record.question_id===oldEnvelope.question_id&&record.entry_id===f.pool.entries[1].id).length,1);
      assert.equal(successes.filter(record=>record.question_id===newEnvelope.question_id&&record.entry_id===f.pool.primary_id).length,1);assert.equal(successes.length,2);
      const cached=await f.post(oldBody,oldEnvelope);assert.equal(cached.value.choices[0].message.content,'旧问题仅由原备用完整回答');assert.equal(f.calls.length,3);
    }finally{releaseBackup();await f.close();}
  });
  await test('A27 半份JSON或违规SSE断流只交付备用完整SSE；半份等待中取消不续备、不计成功',async()=>{
    for(const format of ['json','sse']) {
      const f=await fixture(2);let release;const gate=new Promise(resolve=>{release=resolve;});
      try {
        let partialSent=false,clientHeaders=false;
        const leaked='不得拼入最终答案的半份上游内容',complete='仅保留备用接口的完整回答';
        f.behavior=async(call,response)=>{
          if(call.index===0){response.writeHead(200,{'content-type':format==='sse'?'text/event-stream':'application/json'});response.flushHeaders();response.write(format==='sse'?'data: '+JSON.stringify({choices:[{delta:{content:leaked}}]})+'\n\n':'{"choices":[{"message":{"content":"'+leaked);partialSent=true;await gate;response.destroy();return true;}
          response.end(JSON.stringify(chat(complete)));return true;
        };
        const envelope=f.envelope(),body={...sample,stream:true};
        const pending=fetch(f.base+'/v1/chat/completions',{method:'POST',headers:{authorization:'Bearer '+f.key,'content-type':'application/json','x-crispai-question':signEnvelope(envelope,f.key)},body:JSON.stringify(body)}).then(async response=>{clientHeaders=true;return{status:response.status,type:response.headers.get('content-type'),text:await response.text()};});
        await until(()=>partialSent,'上游未发出半份内容');await sleep(30);assert.equal(clientHeaders,false);release();
        const result=await pending;assert.equal(result.status,200);assert.match(result.type,/text\/event-stream/);assert.ok(!result.text.includes(leaked));
        const events=result.text.split('\n').filter(line=>line.startsWith('data: ')).map(line=>line.slice(6));assert.equal(events.filter(event=>event==='[DONE]').length,1);assert.equal(events.at(-1),'[DONE]');
        const chunks=events.filter(event=>event!=='[DONE]').map(event=>JSON.parse(event));assert.equal(chunks.length,2);assert.equal(chunks.map(chunk=>chunk.choices[0].delta.content||'').join(''),complete);assert.ok(chunks.every(chunk=>chunk.model==='fixture-model-1'));assert.equal(chunks.at(-1).choices[0].finish_reason,'stop');assert.equal(chunks.at(-1).usage.total_tokens,5);
        assert.deepEqual(f.calls.map(call=>call.index),[0,1]);assert.ok(f.calls.every(call=>call.body.stream===false));
        const records=(await f.get('recent')).records.filter(record=>record.question_id===envelope.question_id);assert.equal(records.filter(record=>record.outcome==='failed').length,1);assert.equal(records.filter(record=>record.outcome==='success').length,1);assert.equal(records.find(record=>record.outcome==='success').entry_id,f.pool.entries[1].id);
        assert.equal((await f.post(body,envelope)).text,result.text);assert.equal(f.calls.length,2);
      }finally{release();await f.close();}
    }
    const f=await fixture(2);let release;const gate=new Promise(resolve=>{release=resolve;});
    try {
      let partialSent=false,clientHeaders=false,upstreamClosed=false;
      f.behavior=async(_call,response)=>{response.once('close',()=>{upstreamClosed=true;});response.writeHead(200,{'content-type':'application/json'});response.write('{"choices":[{"message":{"content":"迟到内容');partialSent=true;await gate;response.end('不能出站"}}]}');return true;};
      const envelope=f.envelope(),body={...sample,stream:true},controller=new AbortController();
      const pending=fetch(f.base+'/v1/chat/completions',{method:'POST',headers:{authorization:'Bearer '+f.key,'content-type':'application/json','x-crispai-question':signEnvelope(envelope,f.key)},body:JSON.stringify(body),signal:controller.signal}).then(async response=>{clientHeaders=true;return{status:response.status,text:await response.text()};}).catch(error=>({aborted:error.name==='AbortError'}));
      await until(()=>partialSent,'取消例未收到半份上游');assert.equal(clientHeaders,false);controller.abort();assert.equal((await pending).aborted,true);
      const file=path.join(f.directory,'data/provider-router/questions',envelope.question_id+'.json');
      await until(()=>upstreamClosed&&read(file).terminal?.code==='question_cancelled','客户端取消未持久结束上游');release();await sleep(30);
      assert.equal(clientHeaders,false);assert.equal(f.calls.length,1);const stored=read(file);assert.equal(stored.attempts,1);assert.equal(stored.stages.answer.result,undefined);assert.equal((await f.get('recent')).records.length,0);
      const again=await f.post(body,envelope);assert.equal(again.status,400);assert.equal(again.value.error.code,'question_cancelled');assert.ok(!again.text.includes('data: '));assert.ok(!again.text.includes('迟到内容'));assert.equal(f.calls.length,1);
    }finally{release();await f.close();}
  });
  process.stdout.write(`UNIT/PROTOCOL 主备协议合计 ${count} 组通过，0 失败\n`);
}
function copy(value){return JSON.parse(JSON.stringify(value));}
main().catch(error=>{console.error(error);process.exitCode=1;});
