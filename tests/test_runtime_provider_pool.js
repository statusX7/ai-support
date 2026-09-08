'use strict';

// 生产 runtime → HTTP 协议 RAG → 生产 adapter → HTTP 上游；不是真实 AnythingLLM/Crisp E2E。
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const http = require('node:http');
const {spawn} = require('node:child_process');
const {createRuntime} = require('../n8n/runtime');
const {createAdapter} = require('../scripts/provider-adapter');
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
  let sequence=10000, runtime;
  const f={root,calls,sent,histories,tasks,failed:new Set(),slow:false,delay:400,failAnswer:false};
  const upstream=http.createServer(async(req,res)=>{
    let raw='';for await(const chunk of req)raw+=chunk;const body=JSON.parse(raw||'{}');
    const index=Number(/^\/p(\d)\//.exec(req.url)?.[1]);
    const messages=body.messages||body.input;
    const visual=messages.some(message=>Array.isArray(message.content)&&message.content.some(part=>['image_url','input_image'].includes(part.type)));
    calls.push({index,body,visual,authorization:req.headers.authorization});
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
  const adapter=createAdapter({PROVIDER_ROOT:root,PROVIDER_ADAPTER_KEY:internal,PROVIDER_POOL_REQUIRED:'true',PROVIDER_REQUIRE_ENVELOPE:'true'});
  await new Promise(resolve=>adapter.listen(0,'127.0.0.1',resolve));
  const adapterBase=`http://127.0.0.1:${adapter.address().port}`;
  const postAdapter=async(body,headers={})=>{
    const response=await fetch(adapterBase+'/v1/chat/completions',{method:'POST',headers:{authorization:'Bearer '+internal,'content-type':'application/json',...headers},body:JSON.stringify(body)});
    return{status:response.status,body:await response.json()};
  };
  const rag=http.createServer(async(req,res)=>{
    let raw='';for await(const chunk of req)raw+=chunk;const body=JSON.parse(raw);tasks.push(body);
    // 协议 fixture 仅模拟 RAG 附加知识的消息布局，信封仍由生产 runtime 签名。
    const response=await postAdapter({model:'anythingllm-compat-model',messages:[{role:'system',content:prompt+'\n启用知识：合成处理码是蓝色。'},{role:'user',content:body.message}]});
    res.writeHead(response.status,{'content-type':'application/json'});res.end(JSON.stringify(response.status===200?{textResponse:response.body.choices[0].message.content,sources:[{docpath:'synthetic/blue.json',score:0.9}]}:{error:'controlled-inference-failure'}));
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
      if(suffix==='/meta')return{status:200,body:{error:false,data:{segments:['external-tag']}}};
      if(suffix==='/message'){
        const entry={...structuredClone(options.body),session_id:session,timestamp:Date.now()};sent.push(entry);history.push(entry);histories.set(session,history);
        return{status:200,body:{error:false,data:{fingerprint:entry.fingerprint}}};
      }
      throw Error('未知合成 Crisp 路由');
    }
    assert.equal(parsed.hostname,'127.0.0.1');
    const response=await fetch(url,{method:options.method||'GET',headers:{'content-type':'application/json',...options.headers},body:options.body?JSON.stringify(options.body):undefined,signal:AbortSignal.timeout(options.timeout||10000)});
    return{status:response.status,body:await response.json()};
  };
  f.restart=()=>{runtime=createRuntime(env,{root,request,lookup:(_host,_opts,callback)=>callback(null,[{address:'8.8.8.8',family:4}])});};f.restart();
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
  await test('文本经生产签名/RAG布局/主备到Responses，唯一答案且无评价',async f=>{
    f.failed=new Set([0,1]);await f.deliver(f.event('session_pool_text1','请说明保存操作。'));
    assert.deepEqual(f.calls.map(x=>x.index),[0,1,2]);assert.equal(f.sent.length,1);assert.equal(f.sent[0].content,'受控业务答案：保存后重试。');
    assert.equal(f.calls[2].body.model,'synthetic-backup-2');assert(!JSON.stringify(f.calls).includes('CRISPAI_PROVIDER_CONTEXT'));assert(!f.sent[0].content.includes('是否解决'));
    await f.deliver(f.event('session_pool_text1','是'));assert.equal(f.sent.length,2);assert.equal(f.tasks.length,2);assert(f.tasks[1].message.includes('保存操作'));assert(f.tasks[1].message.includes('访客当前问题：是'));
  });
  await test('视觉与RAG回答共享三次上限、重启不重复识图或重放答案',async f=>{
    f.publish(pool=>{pool.policy.max_attempts=3;});f.failed=new Set([0]);f.failAnswer=true;
    const event=f.event('session_pool_image1',{type:'image/png',url:'https://storage.crisp.chat/synthetic.png'},{type:'file'});
    await f.deliver(event);assert.equal(f.calls.length,3);assert.equal(f.calls.filter(x=>x.visual).length,2);assert.equal(f.sent.length,1);assert.equal(f.state(event.data.session_id).mode,'ai');
    assert(f.tasks[0].message.includes('蓝色保存按钮'));f.restart();await f.deliver(event);assert.equal(f.calls.length,3);assert.equal(f.sent.length,1);
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
  write(path.join(base,'result.json'),{layer:'UNIT/PROTOCOL',passed,failed:0,real_external:false});
  console.log(`运行时主备联验：${passed} 通过，0 失败（协议 RAG/Crisp，不是真实第三方）。`);
})().catch(error=>{console.error(error.stack);process.exitCode=1;});
