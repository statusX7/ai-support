'use strict';

// 合成 Crisp REST/Hook，验证可见昵称与内部归属独立；不连接真实客户。
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {spawnSync} = require('node:child_process');
const {createRuntime} = require('../n8n/runtime.js');
const project = path.resolve(__dirname, '..');
const root = fs.mkdtempSync(path.join(project, '.test-runtime.outgoing-identity.'));
fs.mkdirSync(path.join(root, 'config'));
for (const name of ['keyword', 'handoff', 'menu', 'tags', 'feedback', 'runtime', 'provider']) {
  fs.copyFileSync(path.join(project, 'config', name + '.yaml.example'), path.join(root, 'config', name + '.yaml'));
}
fs.writeFileSync(path.join(root, 'config/prompt.md'), '这是虚构协议测试提示词。');
const json = (name, value) => fs.writeFileSync(path.join(root, 'config', name + '.yaml'), JSON.stringify(value));
json('runtime', {schema_version:2, enabled:true, revision:1, applied_revision:1});
json('provider', {provider:{base_url:'https://identity-provider.invalid/v1',model:'synthetic-identity-model',api_mode:'chat_completions'}});
fs.mkdirSync(path.join(root,'data/runtime'),{recursive:true});
fs.writeFileSync(path.join(root,'data/runtime/knowledge-map.json'),JSON.stringify({schema_version:2,revision:1,documents:[{
  library_id:'kb_default',document_id:'doc_2222222222222222',projection:'synthetic-identity.md',location:'synthetic/identity.json'
}]}));
const menu = JSON.parse(fs.readFileSync(path.join(root, 'config/menu.yaml')));
menu.welcome.enabled = false; json('menu', menu);
const env = {CRISP_WEBSITE_ID:'fixture-website-identity', CRISP_HOOK_MODE:'website', CRISP_WEBSITE_HOOK_SECRET:'fixture-hook-identity-0123456789', CRISP_AUTH_B64:'Zml4dHVyZTpleGFtcGxl', ANYTHINGLLM_API_KEY:'fixture-internal', ANYTHINGLLM_WORKSPACE:'support'};
let now = Date.now(), sequence = 200, runtime, sent = [], requests = 0, messageLookups = 0;
const histories = new Map();
let onSend = null, onModel = null, sendFailure = false;
const key = session => runtime.stateKey(env.CRISP_WEBSITE_ID, session);
const state = session => runtime.readState(key(session));
const bucket = (session, fingerprint) => path.join(root, 'data/runtime', 'owned-' + key(session) + '-' + (fingerprint % 256).toString(16).padStart(2, '0') + '.json');
const event = (session, content, extra={}) => ({website_id:env.CRISP_WEBSITE_ID, event:'message:send', timestamp:now, data:{session_id:session, from:'user', type:'text', content, fingerprint:++sequence, timestamp:now, ...extra}});
const receive = body => runtime.receive({body, query:{key:env.CRISP_WEBSITE_HOOK_SECRET}});
const deliver = async body => {const accepted=await receive(body); assert.equal(accepted.accepted,true); return accepted.route==='process' ? runtime.process(accepted.key,accepted.jobId) : accepted;};
const request = async (url, options={}) => {
  const parsed = new URL(url), match = parsed.pathname.match(/\/conversation\/([^/]+)(\/.*)$/);
  if (match) {
    const session = decodeURIComponent(match[1]), suffix = match[2], history = histories.get(session) || [];
    if (suffix === '/messages') return {status:200,body:{error:false,data:history}};
    if (suffix.startsWith('/message/')) {messageLookups++;return {status:200,body:{error:false,data:history.find(item=>String(item.fingerprint)===suffix.slice(9)) || {}}};}
    if (suffix === '/meta') return {status:200,body:{error:false,data:{segments:[]}}};
    if (suffix === '/message' && options.method === 'POST') {
      if (sendFailure) return {status:400,body:{error:true,reason:'synthetic-rejection'}};
      const body = structuredClone(options.body);
      assert.equal('automated' in body,false);
      assert.equal('properties' in body,false);
      assert.deepEqual(body.user,{type:'website',nickname:'在线客服'});
      assert(fs.existsSync(bucket(session,body.fingerprint)), 'POST 前必须持久登记归属');
      assert.equal(fs.statSync(bucket(session,body.fingerprint)).mode & 0o777,0o600);
      history.push({...body,timestamp:now}); histories.set(session,history);
      sent.push({...body,session_id:session});
      if (onSend) await onSend(session,body);
      await receive({website_id:env.CRISP_WEBSITE_ID,event:'message:received',timestamp:now,data:{...body,automated:false,session_id:session,timestamp:now}});
      return {status:200,body:{error:false,reason:'dispatched',data:{fingerprint:body.fingerprint}}};
    }
    throw Error('未知合成路径');
  }
  if (parsed.hostname === 'anythingllm') {
    if (options.method === 'GET') return {status:200,body:{workspace:{slug:env.ANYTHINGLLM_WORKSPACE || 'crisp-support',openAiTemp:0.7}}};
    assert(parsed.pathname.endsWith('/vector-search'));
    return {status:200,body:{results:[{id:'synthetic-identity-chunk',text:'虚构身份测试处理说明。',metadata:{title:'synthetic-identity.md'},distance:0.1,score:0.9}]}};
  }
  if (parsed.hostname === 'identity-provider.invalid') {requests++;if(onModel)return onModel(options);return {status:200,body:{choices:[{message:{content:'合成问题处理结果。'}}]}};}
  throw Error('禁止外部网络');
};
const restart = () => {runtime=createRuntime(env,{root,clock:()=>now,request});};
restart();
let passed = 0;
const test = async (name, work) => {await work();passed++;console.log('通过 UNIT/CONTRACT：'+name);};
// 官方 message:received 的 text/file 结构；身份及内容全部另造，不使用官方样例真人身份。
// https://docs.crisp.chat/references/web-hooks/v1/#message-received
const operatorId = 'e24b5d87-a1c2-4a90-8b6d-c7e8f9012345';
const operatorEvent = (session, extra={}) => JSON.parse(JSON.stringify({website_id:env.CRISP_WEBSITE_ID,
  event:'message:received',timestamp:now,data:{website_id:env.CRISP_WEBSITE_ID,session_id:session,inbox_id:null,
    type:'text',from:'operator',origin:'chat',content:'合成操作者公开答复',fingerprint:++sequence,
    user:{nickname:'合成操作者',user_id:operatorId},mentions:[],timestamp:now,stamped:true,...extra}}));
const boundedWait = async promise => {
  let timer;
  try {return await Promise.race([promise,new Promise((_,reject)=>{timer=setTimeout(()=>reject(Error('合成调用未按时进入')),2000);})]);}
  finally {clearTimeout(timer);}
};
const verifyImmediateOperator = async (type, queued=0) => {
  const session='session_identity-official-'+type+'-'+queued, other='session_identity-peer-'+type+'-'+queued;
  let reached, release;
  const started=new Promise(resolve=>{reached=resolve;});
  onModel=()=>{onModel=null;reached();return new Promise(resolve=>{release=()=>resolve({status:200,body:{choices:[{message:{content:'合成迟到答复'}}]}});});};
  const accepted=await receive(event(session,'合成在途咨询'));
  assert.equal(accepted.route,'process');
  const processing=runtime.process(accepted.key,accepted.jobId);
  try {
    await boundedWait(started);now+=1000;
    if(queued) await seedQueue(session,queued,0,true);
    const body=operatorEvent(session,{type,...(type==='file'?{content:{name:'synthetic.pdf',url:'https://files.example.invalid/synthetic.pdf',type:'application/pdf'}}:{})});
    assert.equal(Object.hasOwn(body.data,'automated'),false);assert.equal(Object.hasOwn(body.data.user,'type'),false);
    const lookups=messageLookups, control=await receive(body);
    assert.equal(control.accepted,true);assert.equal(state(session).mode,'human','可信官方结构必须在接收事务内立即暂停');
    assert.equal(state(session).pause_reason,'operator_reply');
    assert.equal(state(session).jobs.find(job=>job.id===accepted.jobId).status,'cancelled');
    assert.equal(messageLookups,lookups,'明确官方身份不应等待 REST 回查');
    await deliver(event(other,'另一会话继续合成咨询'));
    assert.equal(state(other).mode,'ai');assert.equal(sent.filter(message=>message.session_id===other).length,1);
    await runtime.process(control.key,control.jobId);
  } finally {
    onModel=null;if(release)release();await processing;
  }
  assert.equal(sent.filter(message=>message.session_id===session).length,0,'旧在途答案不能迟到出站');
  assert.equal(state(session).mode,'human');
};

const pendingJob = job => !['done','cancelled','failed'].includes(job.status);
const seedQueue = async (session,ordinary,controls=0,append=false) => runtime.transaction(key(session),current=>{
  if(!append) current.jobs=[];
  for(let index=0;index<ordinary+controls;index++) {
    const control=index>=ordinary;
    current.jobs.push({id:(++sequence).toString(16).padStart(64,'0'),event:control?'message:received':'message:send',
      event_time:now,received_at:now,sequence:++current.sequence,status:'received',attempts:0,revision:1,generation:current.generation,
      control,...(control?{action:'operator',human_changed:false}:{data:{type:'text',from:'user',content:'合成排队问题'}})});
  }
},env.CRISP_WEBSITE_ID,session);
const registeredConfirmation = async (session,expired=false) => {
  let offer;
  await runtime.transaction(key(session),current=>{
    const value=(++sequence).toString(16).padStart(24,'0');
    offer={id:'crispai_'+sequence.toString(16).padStart(32,'0'),fingerprint:++sequence,kind:'handoff',revision:1,
      generation:current.generation,issued_at:now,expires_at:now+(expired?-1:600000),consumed_at:null,
      choices:{[value]:{type:'confirm_handoff'}},confirm_message:'合成已登记人工确认'};
    current.offers[offer.id]=offer;
  },env.CRISP_WEBSITE_ID,session);
  return {website_id:env.CRISP_WEBSITE_ID,event:'message:updated',timestamp:now,data:{session_id:session,type:'picker',from:'user',
    fingerprint:offer.fingerprint,timestamp:now,content:{id:offer.id,choices:[{value:Object.keys(offer.choices)[0],label:'合成确认',selected:true}]}}};
};

(async()=>{
  await test('中性官方昵称、不请求徽标；POST前自有指纹落盘，false回流不暂停',async()=>{
    const session='session_identity-a';
    await deliver(event(session,'合成问题'));
    assert.equal(sent.length,1);assert.equal(state(session).mode,'ai');assert.equal(requests,1);
    assert.equal(state(session).outgoing[String(sent[0].fingerprint)].status,'sent');
    const recorded=JSON.parse(fs.readFileSync(bucket(session,sent[0].fingerprint)));
    assert.deepEqual(Object.keys(recorded).sort(),['fingerprints','schema_version']);
    assert(!JSON.stringify(recorded).includes('处理结果'));
  });
  await test('八天清理详细outgoing后重启，旧自有回复仍不会被误判真人',async()=>{
    const session='session_identity-a', old=sent[0];
    now+=8*86400000;await runtime.scan();restart();
    assert(!state(session).outgoing[String(old.fingerprint)]);
    await deliver(event(session,'八天后的新问题'));
    assert.equal(state(session).mode,'ai');assert.equal(sent.length,2);
    await receive({website_id:env.CRISP_WEBSITE_ID,event:'message:received',timestamp:now,data:{...old,automated:false,timestamp:now}});
    assert.equal(state(session).mode,'ai');
  });
  await test('自有指纹严格绑定会话；另一会话同指纹真人公开回复立即暂停',async()=>{
    now+=1000;
    await receive({website_id:env.CRISP_WEBSITE_ID,event:'message:received',timestamp:now,data:{...sent[0],session_id:'session_identity-b',content:'合成真人回复',automated:false,timestamp:now}});
    assert.equal(state('session_identity-b').mode,'human');assert.equal(state('session_identity-a').mode,'ai');
  });
  await test('人工卡片保持原生确认，中性取消标题，点击只暂停当前会话',async()=>{
    await deliver(event('session_identity-c','人工'));
    const card=sent.at(-1);assert.equal(card.type,'picker');
    assert.equal(card.content.choices[0].label,'召唤人工客服');assert.equal(card.content.choices[1].label,'继续咨询');
    assert.equal(state('session_identity-c').mode,'ai');
    await deliver({website_id:env.CRISP_WEBSITE_ID,event:'message:updated',timestamp:now,data:{session_id:'session_identity-c',fingerprint:card.fingerprint,content:{...card.content,choices:card.content.choices.map((item,index)=>({...item,selected:index===0}))}}});
    assert.equal(state('session_identity-c').mode,'human');assert.equal(state('session_identity-a').mode,'ai');
    assert.equal(sent.at(-1).content,'您的人工协助请求已收到，请稍候。');
  });
  await test('历史索引损坏时失败关闭，不把未确认的旧回复冒认为真人或继续发送',async()=>{
    const session='session_identity-a', old=sent[0], file=bucket(session,old.fingerprint), original=fs.readFileSync(file);
    fs.writeFileSync(file,'{}'); const before=sent.length;
    await deliver(event(session,'索引损坏时的合成问题'));
    assert.equal(sent.length,before);assert.equal(state(session).mode,'ai');
    fs.writeFileSync(file,original);
  });
  await test('外部验收按本机归属计数，其他自动化和相同昵称不冒充本项目答案',async()=>{
    const message={...sent[0],automated:false};
    const invoke=(session,payload)=>spawnSync('python3',[path.join(project,'tests/owned_outgoing.py'),root,env.CRISP_WEBSITE_ID,session],{input:JSON.stringify(payload),encoding:'utf8'});
    const result=invoke('session_identity-a',{data:[message,{...message,fingerprint:17,automated:true},{...message,fingerprint:18}]});
    assert.equal(result.status,0,result.stderr);
    assert.deepEqual(JSON.parse(result.stdout).data.map(item=>item.__crispai_owned),[true,false,false]);
    const other=invoke('session_identity-b',{data:[message]});
    assert.equal(other.status,0,other.stderr);assert.equal(JSON.parse(other.stdout).data[0].__crispai_owned,false);
    const file=bucket('session_identity-a',message.fingerprint), saved=fs.readFileSync(file);
    fs.writeFileSync(file,'{}');
    const broken=invoke('session_identity-a',{data:[message]});
    assert.equal(broken.status,1);assert.equal(broken.stdout,'');
    fs.writeFileSync(file,saved);
  });
  await test('官方省略automated/type的UUID公共文字立即人工、取消A且B正常',()=>verifyImmediateOperator('text'));
  await test('官方省略automated/type的UUID公共文件立即人工、取消A且B正常',()=>verifyImmediateOperator('file'));
  await test('Hook缺用户身份时，REST单条回查的同一官方结构确认人工',async()=>{
    const session='session_identity-rest-operator';now+=1000;
    const full=operatorEvent(session);histories.set(session,[full.data]);
    const partial=structuredClone(full);delete partial.data.user;
    const before=messageLookups, accepted=await receive(partial);
    assert.equal(state(session).mode,'ai');assert.equal(accepted.route,'process');
    await runtime.process(accepted.key,accepted.jobId);
    assert.equal(messageLookups,before+1);assert.equal(state(session).mode,'human');
    assert.equal(state(session).pause_reason,'operator_reply');assert.deepEqual(state(session).uncertain_events,[]);
  });
  await test('note/typing/未知actor/坏UUID/网站UUID别名及未认证Hook均不能误判人工',async()=>{
    const cases=[{type:'note'},{type:'typed'},{stealth:true},{properties:{stealth:true}},
      ...['website','participant','operator','unknown','',null].map(type=>({user:{nickname:'同名合成用户',user_id:operatorId,type}})),
      ...['website','participant','not-a-uuid','00000000-0000-0000-0000-000000000000',
        'e24b5d87-a1c2-0a90-8b6d-c7e8f9012345','e24b5d87-a1c2-4a90-7b6d-c7e8f9012345',123].map(user_id=>({user:{nickname:'同名合成用户',user_id}})),
      {user:{nickname:'同名合成用户'}},{user:[]},{automated:null},{automated:'false'}];
    const before=sent.length;
    for(const [index,extra] of cases.entries()){
      const session='session_identity-nonhuman-'+index;now+=1000;
      const body=operatorEvent(session,extra);histories.set(session,[body.data]);await deliver(body);
      assert.equal(state(session).mode,'ai','非人工边界 '+index);assert.notEqual(state(session).pause_reason,'operator_reply');
    }
    const typing=operatorEvent('session_identity-typing');typing.event='message:compose:receive';
    assert.equal((await receive(typing)).route,'ignore');assert.equal(state(typing.data.session_id).mode,'ai');
    const untrusted=operatorEvent('session_identity-untrusted');
    assert.equal((await runtime.receive({body:untrusted,query:{key:'invalid-synthetic-hook'}})).accepted,false);
    assert.equal(state(untrusted.data.session_id).mode,'ai');
    const website='a8b1c2d3-e4f5-4678-9abc-0123456789de';
    const siteRuntime=createRuntime({...env,CRISP_WEBSITE_ID:website},{root,clock:()=>now,request});
    for(const [index,user_id] of [website,website.toUpperCase()].entries()){
      const session='session_identity-site-alias-'+index, body=operatorEvent(session,{website_id:website,user:{nickname:'站点不是操作者',user_id}});
      body.website_id=website;histories.set(session,[body.data]);
      const accepted=await siteRuntime.receive({body,query:{key:env.CRISP_WEBSITE_HOOK_SECRET}});
      assert.equal(accepted.accepted,true);if(accepted.route==='process')await siteRuntime.process(accepted.key,accepted.jobId);
      assert.equal(siteRuntime.readState(siteRuntime.stateKey(website,session)).mode,'ai');
    }
    assert.equal(sent.length,before);
  });
  await test('自有指纹与automated优先于官方UUID，均不触发人工或REST回查',async()=>{
    now+=1000;const before=messageLookups, session='session_identity-fresh-owned';let echoObserved=false;
    onSend=async (current,body)=>{
      assert.equal(current,session);assert(fs.existsSync(bucket(session,body.fingerprint)));
      const own=operatorEvent(session,{fingerprint:body.fingerprint});
      assert.equal(Object.hasOwn(own.data,'automated'),false);assert.equal(Object.hasOwn(own.data.user,'type'),false);
      const accepted=await receive(own);
      assert.equal(accepted.accepted,true);assert.notEqual(accepted.reason,'重复事件已忽略');
      assert.equal(state(session).jobs.find(job=>job.id===accepted.jobId).status,'done');
      assert.equal(state(session).mode,'ai');assert.equal(state(session).generation,0);
      assert.equal(messageLookups,before);echoObserved=true;
    };
    try {await deliver(event(session,'新自有身份的合成咨询'));} finally {onSend=null;}
    assert.equal(echoObserved,true);assert.equal(state(session).mode,'ai');assert.equal(state(session).generation,0);
    assert.equal(state(session).jobs.filter(job=>job.event==='message:received').length,1,'默认echo只能去重，不能改变先前归属判定');
    for(const [index,extra] of [{automated:true},{properties:{ai_support:true}},{properties:{ai_support_version:'v1.2.0'}}].entries()){
      const peer='session_identity-auto-priority-'+index;await deliver(operatorEvent(peer,extra));
      assert.equal(state(peer).mode,'ai');assert.equal(state(peer).generation,0);
    }
    assert.equal(messageLookups,before);
  });
  await test('无真人Hook但发前REST历史出现官方UUID，人工接管且旧答案零出站',async()=>{
    const session='session_identity-history-only';now+=1000;const before=requests;
    onModel=()=>{onModel=null;now+=1000;histories.set(session,[operatorEvent(session).data]);
      return {status:200,body:{choices:[{message:{content:'不应发送的合成旧答案'}}]}};};
    try {await deliver(event(session,'需要处理的合成问题'));} finally {onModel=null;}
    assert.equal(requests,before+1);assert.equal(state(session).mode,'human');
    assert.equal(state(session).pause_reason,'operator_reply');assert.equal(sent.filter(message=>message.session_id===session).length,0);
  });
  await test('127/128普通及普通控制混合队列，真人在接收短事务立即暂停；总关与marker不阻控制',async()=>{
    const marker=path.join(root,'config/provider-pool-transaction.json');
    for(const [index,[ordinary,controls,maintenance,disabled]] of [[127,0,false,false],[128,0,false,false],[96,32,false,false],[128,0,true,true]].entries()){
      const session='session_identity-queue-'+index;now+=1000;
      await seedQueue(session,ordinary,controls);
      json('runtime',{schema_version:2,enabled:!disabled,revision:1,applied_revision:1});
      if(maintenance)fs.writeFileSync(marker,JSON.stringify({phase:'applying'}),{mode:0o600});
      try {
        const started=Date.now(), before=messageLookups, accepted=await receive(operatorEvent(session));
        assert.equal(accepted.accepted,true);assert(Date.now()-started<300);assert.equal(state(session).mode,'human');
        assert.equal(state(session).generation,1);assert.equal(state(session).resume_at,now+3600000);
        assert.equal(state(session).jobs.filter(job=>!job.control&&job.status==='cancelled').length,ordinary);
        assert.equal(state(session).jobs.filter(pendingJob).length,controls+1);assert.equal(messageLookups,before);
      } finally {if(maintenance)fs.unlinkSync(marker);json('runtime',{schema_version:2,enabled:true,revision:1,applied_revision:1});}
    }
  });
  await test('普通第129条与未知身份满队列仍拒绝，自有回流及伪造按钮不误人工或占优先槽',async()=>{
    const session='session_identity-capacity';now+=1000;
    for(let index=0;index<128;index++)assert.equal((await receive(event(session,'合成排队咨询'))).accepted,true);
    const before=state(session).jobs.length;
    assert.equal((await receive(event(session,'第129条合成咨询'))).statusCode,503);
    assert.equal(state(session).jobs.length,before);assert.equal(state(session).mode,'ai');
    const unknown=operatorEvent(session);delete unknown.data.user;
    assert.equal((await receive(unknown)).statusCode,503);assert.deepEqual(state(session).uncertain_events,[]);
    const forged={website_id:env.CRISP_WEBSITE_ID,event:'message:updated',data:{session_id:session,type:'picker',fingerprint:++sequence,
      priority_confirmation:true,content:{id:'crispai_not-issued',choices:[{value:'forged',selected:true}]}}};
    assert.equal((await receive(forged)).accepted,true);assert.equal(state(session).mode,'ai');
    assert.equal(state(session).jobs.filter(pendingJob).length,128);assert(!state(session).jobs.some(job=>job.priority_confirmation));
    const ownSession='session_identity-full-owned';await deliver(event(ownSession,'建立合成自有记录'));
    const own=sent.at(-1);await seedQueue(ownSession,128);const lookups=messageLookups;
    const body=operatorEvent(ownSession,{fingerprint:own.fingerprint});
    const accepted=await receive(body);assert.equal(accepted.accepted,true);assert.notEqual(accepted.reason,'重复事件已忽略');
    assert.equal(state(ownSession).mode,'ai');assert.equal(state(ownSession).jobs.filter(pendingJob).length,128);
    assert.equal(state(ownSession).jobs.find(job=>job.id===accepted.jobId).status,'done');assert.equal(messageLookups,lookups);
  });
  await test('纯128控制积压下连续确定真人仍立即暂停，统计去重且不删除旧控制或unknown对账',async()=>{
    const session='session_identity-full-controls';now+=1000;await seedQueue(session,0,128);
    const original=state(session).jobs.map(job=>job.id), oldUnknown={status:'unknown',body:{type:'text',content:'合成旧未知通知'},created_at:now,attempts:1,job_id:original[0],generation:0};
    await runtime.transaction(key(session),current=>{current.outgoing['987654321']=structuredClone(oldUnknown);});
    const analytics=path.join(root,'data/analytics/events.jsonl');
    const handoffs=()=>fs.existsSync(analytics)?fs.readFileSync(analytics,'utf8').split('\n').filter(Boolean).map(line=>JSON.parse(line)).filter(item=>item.type==='handoff').length:0;
    const countBefore=handoffs(), lookups=messageLookups;let latest;
    for(let index=0;index<8;index++){
      now+=1000;latest=operatorEvent(session);const accepted=await receive(latest);
      assert.equal(accepted.accepted,true);assert.equal(accepted.route,'ignore');assert.equal(state(session).mode,'human');
      assert.equal(state(session).generation,index+1);assert.equal(state(session).jobs.filter(pendingJob).length,128);
      const record=state(session).jobs.find(job=>job.id===accepted.jobId);
      assert.equal(record.status,'done');assert.equal(record.handoff_counted,true);assert.equal(record.tags_skipped,'queue_capacity');
      assert.equal(record.data,undefined);assert.deepEqual(state(session).outgoing['987654321'],oldUnknown);
    }
    const generation=state(session).generation, deadline=state(session).resume_at;
    assert.equal((await receive(latest)).reason,'重复事件已忽略');
    const older=operatorEvent(session,{timestamp:now-1000});await receive(older);
    assert.equal(state(session).generation,generation);assert.equal(state(session).resume_at,deadline);
    assert.equal(handoffs()-countBefore,8);assert.equal(messageLookups,lookups);
    assert(original.every(id=>state(session).jobs.some(job=>job.id===id&&pendingJob(job))));
    const unresolved='session_identity-full-unresolved';now+=1000;await seedQueue(unresolved,0,128);
    let uncertain;
    await runtime.transaction(key(unresolved),current=>{
      for(const job of current.jobs){job.action='resolve_operator';job.data={type:'text',from:'operator',fingerprint:++sequence,timestamp:now};}
      uncertain=current.jobs.map(job=>job.id);current.uncertain_events=[...uncertain];
    });
    const accepted=await receive(operatorEvent(unresolved));assert.equal(accepted.accepted,true);assert.equal(accepted.route,'ignore');
    assert.equal(state(unresolved).mode,'human');assert.equal(state(unresolved).generation,1);
    assert.deepEqual(state(unresolved).uncertain_events,uncertain);assert.equal(state(unresolved).jobs.filter(pendingJob).length,128);
    assert(uncertain.every(id=>state(unresolved).jobs.some(job=>job.id===id&&job.action==='resolve_operator'&&pendingJob(job))));
    assert.equal(messageLookups,lookups);
  });
  await test('有效人工确认在纯满控制队列使用唯一第129优先槽，跨会话/过期/重复不占槽且通知优先发送',async()=>{
    const session='session_identity-priority-confirm';now+=1000;await seedQueue(session,0,128);
    const click=await registeredConfirmation(session), other='session_identity-cross-confirm';await seedQueue(other,0,128);
    const crossed=structuredClone(click);crossed.data.session_id=other;
    assert.equal((await receive(crossed)).accepted,true);assert.equal(state(other).mode,'ai');assert.equal(state(other).jobs.filter(pendingJob).length,128);
    const expiredSession='session_identity-expired-confirm';await seedQueue(expiredSession,0,128);
    assert.equal((await receive(await registeredConfirmation(expiredSession,true))).accepted,true);assert.equal(state(expiredSession).mode,'ai');
    const marker=path.join(root,'config/provider-pool-transaction.json');fs.writeFileSync(marker,JSON.stringify({phase:'applying'}),{mode:0o600});
    let accepted;
    try {accepted=await receive(click);assert.equal(accepted.accepted,true);assert.equal(state(session).mode,'human');}
    finally {fs.unlinkSync(marker);}
    const reserved=state(session).jobs.find(job=>job.id===accepted.jobId);
    assert.equal(reserved.priority_confirmation,true);assert.equal(state(session).jobs.filter(pendingJob).length,129);
    assert.equal((await receive(click)).reason,'重复事件已忽略');assert.equal(state(session).jobs.filter(pendingJob).length,129);
    const before=sent.length;await runtime.process(key(session));
    assert.equal(sent.length,before+1);assert.equal(sent.at(-1).session_id,session);assert.equal(sent.at(-1).content,'合成已登记人工确认');
    assert.equal(state(session).jobs.find(job=>job.id===accepted.jobId).status,'done');assert.equal(state(session).jobs.filter(pendingJob).length,128);
    const disabled='session_identity-disabled-confirm';await seedQueue(disabled,128);const offClick=await registeredConfirmation(disabled);
    json('runtime',{schema_version:2,enabled:false,revision:1,applied_revision:1});
    try {assert.equal((await receive(offClick)).accepted,true);assert.equal(state(disabled).mode,'human');assert.equal(state(disabled).jobs.filter(pendingJob).length,0);}
    finally {json('runtime',{schema_version:2,enabled:true,revision:1,applied_revision:1});}
    const fullSlot='session_identity-priority-human';now+=1000;await seedQueue(fullSlot,0,128);
    const reservedClick=await receive(await registeredConfirmation(fullSlot));assert.equal(reservedClick.accepted,true);
    const unknown={status:'unknown',body:{type:'text',content:'合成旧通知仍待对账'},created_at:now,attempts:1,job_id:reservedClick.jobId,generation:1};
    await runtime.transaction(key(fullSlot),current=>{current.outgoing['987654323']=structuredClone(unknown);});
    now+=1000;const control=await receive(operatorEvent(fullSlot));assert.equal(control.accepted,true);assert.equal(control.route,'ignore');
    assert.equal(state(fullSlot).generation,2);assert.equal(state(fullSlot).mode,'human');assert.equal(state(fullSlot).jobs.filter(pendingJob).length,129);
    assert.equal(state(fullSlot).jobs.filter(job=>pendingJob(job)&&job.priority_confirmation).length,1);
    assert.deepEqual(state(fullSlot).outgoing['987654323'],unknown);
  });
  await test('优先确认未终态时手动恢复也不新增handoff offer；sent/failed/cancelled后可再次提供确认',async()=>{
    const blocked='session_identity-priority-backpressure';now+=1000;await seedQueue(blocked,0,128);
    const received=await receive(await registeredConfirmation(blocked));assert.equal(received.accepted,true);
    const unknown={status:'unknown',body:{type:'text',content:'合成正在对账的人工通知'},created_at:now,attempts:1,job_id:received.jobId,generation:1};
    await runtime.transaction(key(blocked),current=>{
      for(const job of current.jobs)if(job.id!==received.jobId)job.status='done';
      const slot=current.jobs.find(job=>job.id===received.jobId);slot.status='processing';slot.lease_until=now+300000;
      current.outgoing['987654322']=structuredClone(unknown);
    });
    now+=1000;await runtime.resume(key(blocked));now+=1000;
    const before=sent.length;await deliver(event(blocked,'人工'));
    assert.equal(sent.length,before);assert.equal(Object.values(state(blocked).offers).filter(offer=>offer.kind==='handoff').length,0);
    assert.equal(state(blocked).jobs.filter(job=>pendingJob(job)&&job.priority_confirmation).length,1);
    assert.deepEqual(state(blocked).outgoing['987654322'],unknown);
    for(const outcome of ['sent','failed','cancelled']){
      const session='session_identity-slot-'+outcome;now+=1000;await seedQueue(session,0,128);
      const accepted=await receive(await registeredConfirmation(session));assert.equal(accepted.accepted,true);
      if(outcome==='cancelled'){now+=1000;await runtime.resume(key(session));}
      sendFailure=outcome==='failed';
      try {await runtime.process(key(session));} finally {sendFailure=false;}
      assert.equal(state(session).jobs.find(job=>job.id===accepted.jobId).status,outcome==='sent'?'done':outcome);
      await runtime.transaction(key(session),current=>{for(const job of current.jobs)if(job.id!==accepted.jobId)job.status='done';});
      now+=1000;await runtime.resume(key(session));now+=1000;
      const prior=sent.length;await deliver(event(session,'人工'));
      assert.equal(sent.length,prior+1);assert.equal(sent.at(-1).type,'picker');
    }
  });
  await test('满128任务时文字/文件真人控制不等待在途模型、A旧答零出站且B独立',async()=>{
    await verifyImmediateOperator('text',127);await verifyImmediateOperator('file',127);
  });
  console.log('中性显示与持久出站身份专项：'+passed+'组通过；Crisp实际徽标显示仍由目标SDK验收。');
})().catch(error=>{console.error(error);process.exitCode=1;}).finally(()=>fs.rmSync(root,{recursive:true,force:true}));
