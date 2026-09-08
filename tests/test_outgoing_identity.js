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
const menu = JSON.parse(fs.readFileSync(path.join(root, 'config/menu.yaml')));
menu.welcome.enabled = false; json('menu', menu);
const env = {CRISP_WEBSITE_ID:'fixture-website-identity', CRISP_HOOK_MODE:'website', CRISP_WEBSITE_HOOK_SECRET:'fixture-hook-identity-0123456789', CRISP_AUTH_B64:'Zml4dHVyZTpleGFtcGxl', ANYTHINGLLM_API_KEY:'fixture-internal', ANYTHINGLLM_WORKSPACE:'support'};
let now = Date.now(), sequence = 200, runtime, sent = [], requests = 0, messageLookups = 0;
const histories = new Map();
let onSend = null, onModel = null;
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
  if (parsed.hostname === 'anythingllm') {requests++;if(onModel)return onModel(options);return {status:200,body:{textResponse:'合成问题处理结果。',sources:[]}};}
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
const verifyImmediateOperator = async type => {
  const session='session_identity-official-'+type, other='session_identity-peer-'+type;
  let reached, release;
  const started=new Promise(resolve=>{reached=resolve;});
  onModel=()=>{onModel=null;reached();return new Promise(resolve=>{release=()=>resolve({status:200,body:{textResponse:'合成迟到答复',sources:[]}});});};
  const accepted=await receive(event(session,'合成在途咨询'));
  assert.equal(accepted.route,'process');
  const processing=runtime.process(accepted.key,accepted.jobId);
  try {
    await boundedWait(started);now+=1000;
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
      return {status:200,body:{textResponse:'不应发送的合成旧答案',sources:[]}};};
    try {await deliver(event(session,'需要处理的合成问题'));} finally {onModel=null;}
    assert.equal(requests,before+1);assert.equal(state(session).mode,'human');
    assert.equal(state(session).pause_reason,'operator_reply');assert.equal(sent.filter(message=>message.session_id===session).length,0);
  });
  console.log('中性显示与持久出站身份专项：'+passed+'组通过；Crisp实际徽标显示仍由目标SDK验收。');
})().catch(error=>{console.error(error);process.exitCode=1;}).finally(()=>fs.rmSync(root,{recursive:true,force:true}));
