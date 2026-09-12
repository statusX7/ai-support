'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const crypto = require('node:crypto');
const {spawn} = require('node:child_process');
const {createAdapter} = require('../scripts/provider-adapter.js');
const {signEnvelope,envelopeMarker} = require('../scripts/provider-envelope.js');
const {DEFAULT_POLICY,retryAfterMilliseconds,cooldownMilliseconds,classifyFailure,estimateTextTokens,normalizeApiBase} = require('../scripts/provider-router.js');
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
  fs.writeFileSync(path.join(directory,'config/prompt.md'),sample.messages[0].content,{mode:0o600});
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

function testCooldownJitter() {
  assert.equal(normalizeApiBase('https://EXAMPLE.invalid/'),'https://example.invalid/v1');
  assert.equal(normalizeApiBase('https://example.invalid/api/'),'https://example.invalid/api/v1');
  assert.equal(normalizeApiBase('https://example.invalid/api/v1'),'https://example.invalid/api/v1');
  for(const invalid of ['https://example.invalid/api?x=1','https://example.invalid/api#fragment','https://example.invalid/api/../admin',
    'https://example.invalid/api/%2e%2e/admin','https://example.invalid:99999/api','http://example.invalid/api','https://example.invalid\\api']) {
    assert.throws(()=>normalizeApiBase(invalid));
  }
  const nearLimit={cooldown_initial_ms:295000,cooldown_max_ms:300000};
  const atLimit={cooldown_initial_ms:1000,cooldown_max_ms:1000};
  const rounding={cooldown_initial_ms:1001,cooldown_max_ms:2000};
  const cases=[
    [DEFAULT_POLICY,1,0,0,60000],[DEFAULT_POLICY,1,0,0.5,61500],[DEFAULT_POLICY,1,0,1,63000],
    [DEFAULT_POLICY,2,0,0,120000],[DEFAULT_POLICY,2,0,1,126000],[DEFAULT_POLICY,3,0,1,252000],
    [DEFAULT_POLICY,4,0,0,300000],[DEFAULT_POLICY,4,0,1,300000],[DEFAULT_POLICY,99,0,1,300000],
    [nearLimit,1,0,0,295000],[nearLimit,1,0,0.25,298687],[nearLimit,1,0,1,300000],
    [atLimit,1,0,0,1000],[atLimit,1,0,1,1000],[rounding,1,0,1,1051],
    [DEFAULT_POLICY,1,0,-1,60000],[DEFAULT_POLICY,1,0,2,63000],
    [DEFAULT_POLICY,1,62000,0,62000],[DEFAULT_POLICY,1,62000,1,63000],
    [DEFAULT_POLICY,1,900000,0,900000],[DEFAULT_POLICY,1,900000,1,900000],[DEFAULT_POLICY,99,900000,1,900000]
  ];
  for(const [policy,failures,retry,fraction,expected] of cases)assert.equal(cooldownMilliseconds(policy,failures,retry,fraction),expected);
  for(let failures=1;failures<=24;failures++)for(const fraction of [0,0.125,0.5,0.875,1]) {
    const base=Math.min(300000,60000*2**(failures-1)),delay=cooldownMilliseconds(DEFAULT_POLICY,failures,0,fraction);
    assert.ok(Number.isSafeInteger(delay));assert.ok(delay>=base);assert.ok(delay<=Math.min(300000,base*1.05));
  }
  const now=Date.UTC(2026,0,1);
  for(const header of ['900',new Date(now+900000).toUTCString()]) {
    const retry=retryAfterMilliseconds(header,now);assert.equal(retry,900000);
    assert.equal(cooldownMilliseconds(DEFAULT_POLICY,1,retry,0),retry);assert.equal(cooldownMilliseconds(DEFAULT_POLICY,99,retry,1),retry);
  }
  process.stdout.write('通过 UNIT：冷却0～5%正向抖动的首次、指数递增、近上限、上限、取整及长Retry-After确定性边界（1组，不计入HTTP协议组数）\n');
}

async function testRagContextTransactions() {
  const f=await fixture(3);
  const run=script=>new Promise(resolve=>{
    const child=spawn('python3',['-B','-c',script,path.join(root,'scripts/provider-pool.py'),f.directory],{env:{...process.env,PROVIDER_ADAPTER_MANAGEMENT_URL:f.base}});
    let stdout='',stderr='';child.stdout.on('data',value=>stdout+=value);child.stderr.on('data',value=>stderr+=value);
    child.on('close',code=>resolve({code,stdout,stderr}));
  });
  const imports=`import copy, fcntl, importlib.util, json, os, stat, sys
from pathlib import Path
spec=importlib.util.spec_from_file_location('tested_provider_pool',sys.argv[1])
module=importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
manager=module.Manager(sys.argv[2])
calls=[]
def apply_window(window):
    with open(manager.root/'config/provider-pool.lock','a') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
    pool,secret=manager.load()
    assert module.rag_context_window(pool)==window
    assert module.read_env(manager.env)['PROVIDER_RAG_CONTEXT_WINDOW']==str(window)
    assert manager.transaction.exists()
    assert stat.S_IMODE(manager.transaction.stat().st_mode)==0o600
    pending=module.read(manager.transaction)
    assert (pending['owner_boot_id'],pending['owner_start_ticks'])==module.process_identity(os.getpid())
    calls.append(window)
    return {'ok':True,'state':'applied','context_window':window}
manager.apply_rag_window=apply_window
`;
  try {
    const before=f.envelope();
    const first=await run(imports+`
pool,secret=manager.load()
primary=pool['primary_id']
assert module.read_env(manager.env)['PROVIDER_RAG_CONTEXT_WINDOW']=='8192'
pool['entries'][1]['context_window']=32768
result=manager.commit(pool,secret,pool['revision'])
assert calls==[32768] and result['rag_context']=={'context_window':32768,'state':'applied'}
env=module.read_env(manager.env)
assert env['AI_MODEL_TOKEN_LIMIT']=='8192' and env['AI_MAX_OUTPUT_TOKENS']=='1200'
pool,secret=manager.load()
assert not manager.transaction.exists()
pool['entries'][0]['name']='同容量改名'
pool['entries'][0]['model']='same-window-model'
secret[primary]['api_key']='synthetic-same-window-new-key'
manager.commit(pool,secret,pool['revision'])
assert calls==[32768]
pool,secret=manager.load()
pool['entries'][0],pool['entries'][1]=pool['entries'][1],pool['entries'][0]
pool['primary_id']=pool['entries'][0]['id']
for index,item in enumerate(pool['entries']): item.update(order=index,role='primary' if index==0 else 'backup')
manager.commit(pool,secret,pool['revision'])
assert calls==[32768] and module.read_env(manager.env)['AI_MODEL_TOKEN_LIMIT']=='32768'
pool,secret=manager.load()
probe=copy.deepcopy(pool)
probe['entries'][2].update(context_window=2097152,enabled=False,draft=True)
assert module.rag_context_window(probe)==32768
probe['entries'][0]['capabilities'][probe['entries'][0]['api_mode']]=False
assert module.rag_context_window(probe)==8192
pool['entries'][0]['context_window']=16384
manager.commit(pool,secret,pool['revision'])
assert calls==[32768,16384]
pool,secret=manager.load()
original=copy.deepcopy(pool)
def reject_candidate(window):
    apply_window(window)
    concurrent,current_secret=manager.load()
    try: manager.commit(concurrent,current_secret,concurrent['revision'])
    except module.PoolError as failure: assert failure.code=='configuration_applying'
    else: raise AssertionError('concurrent commit was accepted')
    if window==65536: raise module.PoolError('rag_context_apply_failed','synthetic candidate refusal')
    return {'ok':True,'state':'applied','context_window':window}
manager.apply_rag_window=reject_candidate
pool['entries'][0]['context_window']=65536
try: manager.commit(pool,secret,pool['revision'])
except module.PoolError as failure: assert failure.code=='rag_context_apply_failed'
else: raise AssertionError('failed application was accepted')
restored,restored_secret=manager.load()
assert restored['entries']==original['entries'] and restored_secret==secret
assert restored['revision']==original['revision']+2 and calls[-2:]==[65536,16384]
assert not manager.transaction.exists()
assert module.read_env(manager.env)['PROVIDER_RAG_CONTEXT_WINDOW']=='16384'
# 旧版已迁池缺少新投影，即使聚合数值未变化也必须同步一次。
manager.apply_rag_window=apply_window
module.atomic(manager.env,'\\n'.join(line for line in manager.env.read_text().splitlines() if not line.startswith('PROVIDER_RAG_CONTEXT_WINDOW='))+'\\n',0o600)
manager.migrate()
assert calls[-1]==16384 and len(calls)==5
pool,secret=manager.load()
def reject_all(window):
    apply_window(window)
    raise module.PoolError('rag_context_apply_failed','synthetic component unavailable')
manager.apply_rag_window=reject_all
pool['entries'][0]['context_window']=65536
try: manager.commit(pool,secret,pool['revision'])
except module.PoolError as failure: assert failure.code=='rag_context_restore_failed'
else: raise AssertionError('failed restoration was accepted')
pending=module.read(manager.transaction)
assert pending['phase']=='restore_failed'
assert stat.S_IMODE(manager.transaction.stat().st_mode)==0o600
assert module.rag_context_window(manager.load()[0])==16384
print(json.dumps({'ok':True,'helper_calls':calls,'phase':pending['phase']}))
`);
    assert.equal(first.code,0,first.stderr+first.stdout);
    assert.deepEqual(JSON.parse(first.stdout).helper_calls,[32768,16384,65536,16384,16384,65536,16384]);
    assert.equal((await f.get('status')).configuration_state,'applying');
    assert.equal((await fetch(f.base+'/healthz')).status,503);
    const blocked=await f.post();assert.equal(blocked.status,400);assert.equal(blocked.value.error.code,'configuration_applying');assert.equal(f.calls.length,0);
    const second=await run(imports+`
import time
pending=module.read(manager.transaction)
boot=Path('/proc/sys/kernel/random/boot_id').read_text().strip()
fields=Path('/proc/self/stat').read_text().rsplit(')',1)[1].split()
start_ticks=int(fields[19])
pending.update(owner_pid=os.getpid(),owner_boot_id=boot,owner_start_ticks=start_ticks,started_at=int(time.time()*1000)-150000)
module.atomic(manager.transaction,pending,0o600)
try: manager.recover_rag_context()
except module.PoolError as failure: assert failure.code=='configuration_applying'
else: raise AssertionError('live transaction owner was bypassed')
assert calls==[]
for changed in ({'owner_boot_id':'00000000-0000-0000-0000-000000000000'},{'owner_start_ticks':start_ticks+1}):
    stale=dict(pending,phase='applying',started_at=int(time.time()*1000),**changed)
    module.atomic(manager.transaction,stale,0o600)
    try: manager.recover_rag_context()
    except module.PoolError as failure: assert failure.code=='configuration_applying'
    else: raise AssertionError('140 second helper safety interval was bypassed')
    assert module.read(manager.transaction)==stale
    stale['started_at']-=150000
    module.atomic(manager.transaction,stale,0o600)
    result=manager.recover_rag_context()
    assert result['rag_context']=={'context_window':16384,'state':'applied'}
    assert not manager.transaction.exists()
assert calls==[16384,16384]
# 身份字段缺失或不可核对时仍闭锁，不能用坏记录绕过真实存活helper。
malformed=dict(pending)
del malformed['owner_boot_id']
module.atomic(manager.transaction,malformed,0o600)
try: manager.recover_rag_context()
except module.PoolError as failure: assert failure.code=='invalid_configuration'
else: raise AssertionError('missing owner identity was accepted')
assert module.read(manager.transaction)==malformed and calls==[16384,16384]
manager.transaction.unlink()
print(json.dumps({'ok':True,'recovered':True,'stale_owner_identity_cases':2}))
`);
    assert.equal(second.code,0,second.stderr+second.stdout);f.reload();
    assert.equal((await f.get('status')).configuration_state,'applied');
    assert.equal((await f.post(sample,before)).status,400);assert.equal(f.calls.length,0);
    assert.equal((await f.post()).status,200);assert.equal(f.calls.length,1);
    const recoveredRevision=read(f.poolFile).revision;
    const noRecovery=await f.cli(['recover-rag-context']);assert.equal(noRecovery.code,0,noRecovery.stdout);
    assert.deepEqual(noRecovery.value,{ok:true,restored:false,message:'没有待恢复的知识上下文配置，未修改组件。'});
    assert.equal(read(f.poolFile).revision,recoveredRevision);assert.equal(f.calls.length,1);
    const acknowledgements=await run(imports+`
from types import SimpleNamespace
actual_run=module.subprocess.run
for payload,status in [({'ok':True,'state':'deferred','context_window':16384},0),({'ok':True,'state':'applied','context_window':8192},0),({'ok':True,'state':'applied','context_window':'16384'},0),({'ok':True,'state':'applied','context_window':16384},1)]:
    def returned(command,**options):
        assert command[-2:]==['internal-rag-context-apply','16384'] and options['timeout']==135
        return SimpleNamespace(returncode=status,stdout=json.dumps(payload))
    module.subprocess.run=returned
    try: module.Manager.apply_rag_window(manager,16384)
    except module.PoolError as failure: assert failure.code=='rag_context_apply_failed'
    else: raise AssertionError('invalid helper acknowledgement was accepted')
module.subprocess.run=actual_run
print(json.dumps({'ok':True,'invalid_acknowledgements_rejected':4}))
`);
    assert.equal(acknowledgements.code,0,acknowledgements.stderr+acknowledgements.stdout);
    const marker=path.join(f.directory,'.crisp-ai-installation'),envFile=path.join(f.directory,'.env');
    for(const state of ['ready','local-ready']) {
      fs.writeFileSync(marker,'ai-support\nstate='+state+'\n',{mode:0o600});
      assert.equal((await f.cli(['migrate','--defer-runtime'])).value.error.code,'invalid_installation_state');
    }
    for(const state of ['collecting','installing','staged']) {
      fs.writeFileSync(marker,'ai-support\nstate='+state+'\n',{mode:0o600});
      fs.writeFileSync(envFile,fs.readFileSync(envFile,'utf8').split('\n').filter(line=>!line.startsWith('PROVIDER_RAG_CONTEXT_WINDOW=')).join('\n'),{mode:0o600});
      const deferred=await f.cli(['migrate','--defer-runtime']);assert.equal(deferred.code,0,deferred.stdout);
      assert.deepEqual(deferred.value.rag_context,{context_window:16384,state:'deferred'});assert.equal(f.calls.length,1);
    }
    assert.equal((await f.cli(['list','--defer-runtime'])).value.error.code,'invalid_action');
    const pendingFile=path.join(f.directory,'config/provider-pool-transaction.json');
    json(pendingFile,{schema_version:1,phase:'restore_failed'});
    assert.equal((await f.cli(['migrate','--defer-runtime'])).value.error.code,'configuration_applying');assert.ok(fs.existsSync(pendingFile));fs.unlinkSync(pendingFile);
    fs.symlinkSync(path.join(f.directory,'missing-transaction'),pendingFile);
    assert.notEqual((await f.cli(['recover-rag-context'])).code,0);assert.ok(fs.lstatSync(pendingFile).isSymbolicLink());fs.unlinkSync(pendingFile);
    process.stdout.write('通过 UNIT/CONFIG：有限聚合窗口、仅变化时同步、锁外回读、并发拒绝、新代次回滚、失败闭锁恢复与仅安装可延后（helper为受控替身，不计入HTTP协议组数）\n');
  } finally {await f.close();}
}

async function testMaintenanceTransactions() {
  const f=await fixture(2);
  const script=`import copy, fcntl, importlib.util, json, os, sys
from pathlib import Path
spec=importlib.util.spec_from_file_location('tested_provider_pool',sys.argv[1])
module=importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
manager=module.Manager(sys.argv[2])
calls=[]
def apply_window(window):
    assert module.inherited_maintenance_descriptor(manager.root/'tmp/maintenance.lock') is not None
    with (manager.root/'tmp/maintenance.lock').open('a') as observer:
        try: fcntl.flock(observer,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError: pass
        else: raise AssertionError('helper was outside the maintenance transaction')
    calls.append(window)
    return {'ok':True,'state':'applied','context_window':window}
manager.apply_rag_window=apply_window
pool,secret=manager.load()
candidate=copy.deepcopy(pool)
candidate['entries'][1]['context_window']=16384
temporary=manager.root/'tmp'
temporary.mkdir(exist_ok=True)
lock_path=temporary/'maintenance.lock'
with lock_path.open('a') as held:
    fcntl.flock(held,fcntl.LOCK_EX|fcntl.LOCK_NB)
    try: manager.commit(candidate,secret,pool['revision'])
    except module.PoolError as failure: assert failure.code=='maintenance_busy'
    else: raise AssertionError('window commit and helper ran while a real maintenance lock was held')
    assert manager.load()[0]==pool and calls==[]
    assert manager.main('list',[])['revision']==pool['revision']
    assert manager.main('status',[])['revision']==pool['revision']
    assert manager.recover_rag_context()['restored'] is False
    candidate_file=manager.root/'fixture-window-edit.json'
    module.atomic(candidate_file,{'provider':{'context_window':16384}},0o600)
    try: manager.main('edit',[pool['entries'][1]['id'],str(candidate_file)])
    except module.PoolError as failure: assert failure.code=='maintenance_busy'
    else: raise AssertionError('CLI mutation bypassed the maintenance gate')
    module.atomic(manager.transaction,{'phase':'restore_failed'},0o600)
    try: manager.recover_rag_context()
    except module.PoolError as failure: assert failure.code=='maintenance_busy'
    else: raise AssertionError('pending recovery bypassed the maintenance gate')
    assert manager.transaction.exists()
    manager.transaction.unlink()
    values={'CRISP_AI_MAINTENANCE_LOCK_HELD':'1','MAINTENANCE_LOCK_FD':str(held.fileno()),'CRISP_AI_MAINTENANCE_LOCK_PATH':str(lock_path)}
    previous={key:os.environ.get(key) for key in values}
    try:
        os.environ.update(values)
        manager.commit(candidate,secret,pool['revision'])
        assert calls==[16384]
        with lock_path.open('a') as observer:
            try: fcntl.flock(observer,fcntl.LOCK_EX|fcntl.LOCK_NB)
            except BlockingIOError: pass
            else: raise AssertionError('successful child released the inherited parent lock')
        try: manager.commit(candidate,secret,pool['revision'])
        except module.PoolError as failure: assert failure.code=='revision_conflict'
        else: raise AssertionError('old revision was accepted')
        with (temporary/'fixture-unrelated.lock').open('a') as unrelated:
            os.environ['MAINTENANCE_LOCK_FD']=str(unrelated.fileno())
            try: manager.commit(candidate,secret,pool['revision'])
            except module.PoolError as failure: assert failure.code=='maintenance_busy'
            else: raise AssertionError('unrelated inherited fd bypassed the real lock')
            os.fstat(unrelated.fileno())
        with lock_path.open('a') as observer:
            try: fcntl.flock(observer,fcntl.LOCK_EX|fcntl.LOCK_NB)
            except BlockingIOError: pass
            else: raise AssertionError('failed child released the inherited parent lock')
    finally:
        for key,value in previous.items():
            if value is None: os.environ.pop(key,None)
            else: os.environ[key]=value
with lock_path.open('a') as observer:
    fcntl.flock(observer,fcntl.LOCK_EX|fcntl.LOCK_NB)
# 实际Bash父维护锁经exec传给Python；内部helper再经pass_fds承接同一个锁。
child_code='''import fcntl,importlib.util,json,os,sys
from pathlib import Path
spec=importlib.util.spec_from_file_location('child_pool',sys.argv[1]); module=importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
manager=module.Manager(sys.argv[2])
actual_run=module.subprocess.run
def helper_run(command,**options):
    assert command[-2:]==['internal-rag-context-apply','32768']
    descriptor=module.inherited_maintenance_descriptor(manager.root/'tmp/maintenance.lock')
    assert descriptor is not None and options['pass_fds']==(descriptor,)
    return actual_run([sys.executable,'-c',sys.argv[3],sys.argv[2]],**options)
module.subprocess.run=helper_run
pool,secret=manager.load(); pool['entries'][1]['context_window']=32768
manager.commit(pool,secret,pool['revision'])
'''
helper_code='''import fcntl,json,os,sys
from pathlib import Path
fd=int(os.environ['MAINTENANCE_LOCK_FD']); opened=os.fstat(fd); source=(Path(sys.argv[1])/'tmp/maintenance.lock').stat()
assert (opened.st_dev,opened.st_ino)==(source.st_dev,source.st_ino)
with (Path(sys.argv[1])/'tmp/maintenance.lock').open('a') as observer:
    try: fcntl.flock(observer,fcntl.LOCK_EX|fcntl.LOCK_NB)
    except BlockingIOError: pass
    else: raise AssertionError('helper did not retain parent maintenance lock')
print(json.dumps({'ok':True,'state':'applied','context_window':32768}))
'''
parent_check='''import fcntl,sys
from pathlib import Path
with (Path(sys.argv[1])/'tmp/maintenance.lock').open('a') as observer:
    try: fcntl.flock(observer,fcntl.LOCK_EX|fcntl.LOCK_NB)
    except BlockingIOError: pass
    else: raise AssertionError('Python operation unlocked the parent Bash transaction')
print('parent-lock-retained')
'''
completed=module.subprocess.run(['bash','-c','set -euo pipefail; source "$1"; acquire_maintenance_lock "$2"; python3 -B -c "$3" "$4" "$2" "$5"; python3 -B -c "$6" "$2"','--',str(Path(sys.argv[1]).with_name('common.sh')),str(manager.root),child_code,sys.argv[1],helper_code,parent_check],stdout=module.subprocess.PIPE,stderr=module.subprocess.PIPE,text=True,timeout=8)
assert completed.returncode==0,completed.stderr+completed.stdout
assert completed.stdout.strip()=='parent-lock-retained'
assert module.rag_context_window(manager.load()[0])==32768
with lock_path.open('a') as observer:
    fcntl.flock(observer,fcntl.LOCK_EX|fcntl.LOCK_NB)
# 异常锁类型必须快速拒绝，不能在FIFO打开阶段阻塞维护入口。
import time
lock_path.unlink()
for kind in ('fifo','symlink'):
    if kind=='fifo': os.mkfifo(lock_path)
    else: lock_path.symlink_to(temporary/'fixture-missing-lock')
    try:
        before=manager.load()[0]
        started=time.monotonic()
        try: manager.commit(copy.deepcopy(before),secret,before['revision'])
        except (module.PoolError,OSError): pass
        else: raise AssertionError('unsafe maintenance lock type was accepted')
        assert time.monotonic()-started<1
        assert manager.load()[0]==before and calls==[16384]
    finally: lock_path.unlink()
print(json.dumps({'ok':True,'maintenance_conflict_rejected':True,'inherited_parent_and_helper_verified':True}))
`;
  try {
    const result=await new Promise(resolve=>{
      const child=spawn('python3',['-B','-c',script,path.join(root,'scripts/provider-pool.py'),f.directory],{env:{...process.env,PROVIDER_ADAPTER_MANAGEMENT_URL:f.base}});
      let stdout='',stderr='';child.stdout.on('data',value=>stdout+=value);child.stderr.on('data',value=>stderr+=value);
      child.on('close',code=>resolve({code,stdout,stderr}));
    });
    assert.equal(result.code,0,result.stderr+result.stdout);
    assert.equal(f.calls.length,0);
    process.stdout.write('通过 UNIT/CONFIG：真实维护锁拒绝写入/恢复、只读可用、Bash父锁与helper继承及异常不解锁（helper为受控替身，不计入HTTP协议组数）\n');
  } finally {await f.close();}
}

async function testManagementErrorClassification() {
  const f=await fixture();
  let current='upstream_unavailable';
  const management=http.createServer((_request,response)=>{
    response.writeHead(503,{'content-type':'application/json'});
    response.end(JSON.stringify({ok:false,error:{
      code:current,
      message:'untrusted Bearer fixture-management-secret https://upstream.invalid/path?token=fixture-token',
      headers:{authorization:'Bearer fixture-management-secret'}
    }}));
  });
  await new Promise(resolve=>management.listen(0,'127.0.0.1',resolve));
  const managementBase=`http://127.0.0.1:${management.address().port}`;
  try {
    const cases=new Map([
      ['authentication_failed',3],['model_unavailable',1],['protocol_error',1],['invalid_response',1],
      ['rate_limited',4],['quota_exhausted',4],['upstream_timeout',4],['upstream_unavailable',4],['connection_failed',4]
    ]);
    for(const [code,status] of cases) {
      current=code;
      const result=await f.cli(['status'],{PROVIDER_ADAPTER_MANAGEMENT_URL:managementBase});
      assert.equal(result.code,status,`${code}: ${result.stdout}`);
      assert.equal(result.value.error.code,code,result.stdout);
      assert.ok(typeof result.value.error.message==='string'&&result.value.error.message.length>4,result.stdout);
      assert.ok(!/fixture-management-secret|fixture-token|upstream\.invalid|authorization|Bearer/i.test(result.stdout),result.stdout);
    }
    current='Bearer fixture-management-secret https://upstream.invalid/?token=fixture-token';
    const unknown=await f.cli(['status'],{PROVIDER_ADAPTER_MANAGEMENT_URL:managementBase});
    assert.equal(unknown.code,1,unknown.stdout);
    assert.equal(unknown.value.error.code,'provider_error',unknown.stdout);
    assert.ok(!/fixture-management-secret|fixture-token|upstream\.invalid|authorization|Bearer/i.test(unknown.stdout),unknown.stdout);
    process.stdout.write('通过 UNIT/CONFIG：管理接口保留安全故障分类并拒绝透传上游错误内容（1组，不计入HTTP协议组数）\n');
  } finally {
    management.closeAllConnections();
    await new Promise(resolve=>management.close(resolve));
    await f.close();
  }
}

async function main() {
  testCooldownJitter();
  await testMaintenanceTransactions();
  await testRagContextTransactions();
  await testManagementErrorClassification();
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
  await test('RAG system须完整保留有效Prompt，截断/用户段替代零推理且显式短probe不受影响',async()=>{
    const f=await fixture(3);try {
      const prompt='首端合成业务规则。\n'+'中段不可丢失的规则。'.repeat(50)+'\n末端合成业务规则。';
      fs.writeFileSync(path.join(f.directory,'config/prompt.md'),prompt,{mode:0o600});
      const truncated=prompt.slice(0,20)+'\n--prompt truncated for brevity--\n'+prompt.slice(-20);
      for(const messages of [
        [{role:'system',content:truncated},{role:'user',content:'合成问题'}],
        [{role:'user',content:prompt+'\n合成问题'}],
        [{role:'system',content:truncated},{role:'user',content:prompt}],
        [{role:'system',content:prompt.slice(0,100)},{role:'system',content:prompt.slice(100)},{role:'user',content:'合成问题'}]
      ]) {
        const envelope=f.envelope(),result=await f.post({messages},envelope);
        assert.equal(result.status,400,result.text);assert.equal(result.value.error.code,'context_preparation_incomplete');
        assert.ok(!result.text.includes('中段不可丢失'));assert.equal(f.calls.length,0);
        assert.equal((await f.post({messages},envelope)).value.error.code,'context_preparation_incomplete');assert.equal(f.calls.length,0);
      }
      assert.equal((await f.get('recent')).records.length,0);
      const complete={messages:[{role:'system',content:prompt+'\nContext: 合成知识内容。'},{role:'user',content:'合成问题'}]};
      assert.equal((await f.post(complete)).status,200);assert.equal(f.calls.length,1);assert.ok(f.calls[0].body.messages[0].content.includes(prompt));
      const projection={schema_version:1,state:'applied',revision:1,configuration:{runtime:{revision:1,enabled:true}},prompt:{text:prompt,bytes:Buffer.byteLength(prompt),sha256:crypto.createHash('sha256').update(prompt).digest('hex')}};
      json(path.join(f.directory,'config/materials-applied.json'),projection);
      fs.writeFileSync(path.join(f.directory,'config/prompt.md'),'尚未应用的编辑稿',{mode:0o600});
      assert.equal((await f.post(complete)).status,200);assert.equal(f.calls.length,2);
      projection.prompt.sha256='0'.repeat(64);json(path.join(f.directory,'config/materials-applied.json'),projection);
      assert.equal((await f.post(complete)).value.error.code,'context_preparation_incomplete');assert.equal(f.calls.length,2);
      const probe=await f.cli(['test']);assert.equal(probe.code,0,probe.stdout);assert.equal(f.calls.length,3);assert.ok(!JSON.stringify(f.calls[2].body).includes(prompt));
    }finally{await f.close();}
  });
  await test('窗口事务期间新请求不推理，原在途结果不出站或续备且不记上游故障',async()=>{
    const f=await fixture(2);let release;const gate=new Promise(resolve=>{release=resolve;});
    const pendingFile=path.join(f.directory,'config/provider-pool-transaction.json');
    try {
      f.behavior=async()=>{await gate;return false;};
      const envelope=f.envelope(),waiting=f.post(sample,envelope);
      await until(()=>f.calls.length===1,'原请求未进入合成上游');
      json(pendingFile,{schema_version:1,token:'a'.repeat(32),phase:'applying'});
      assert.equal((await f.post()).value.error.code,'configuration_applying');assert.equal(f.calls.length,1);
      assert.equal((await f.get('status')).configuration_state,'applying');assert.equal((await fetch(f.base+'/healthz')).status,503);
      release();const result=await waiting;assert.equal(result.status,400);assert.equal(result.value.error.code,'configuration_applying');assert.ok(!result.text.includes('验证回答'));assert.equal(f.calls.length,1);
      assert.equal((await f.get('recent')).records.length,0);
      fs.unlinkSync(pendingFile);f.behavior=null;
      assert.equal((await f.post(sample,envelope)).status,400);assert.equal(f.calls.length,1);
      assert.equal((await f.post()).status,200);assert.equal(f.calls.length,2);
    }finally{release();await f.close();}
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
      const envelope=f.envelope(),started=Date.now(),result=await f.post({...sample,stream:true},envelope),ended=Date.now();assert.equal(result.status,200,result.text);assert.match(result.text,/data: \[DONE\]/);assert.equal(f.calls.length,21);
      const cooling=(await f.get('status')).entries[0].cooldown_until;assert.ok(cooling>=started+60000);assert.ok(cooling<=ended+63000);
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
  await test('普通404按接口协议故障切换备用，单接口保留结构化诊断',async()=>{
    assert.deepEqual(classifyFailure(404,{error:{message:'route not found'}}),{
      kind:'protocol_error',fallback:true,scope:'entryScope',retryAfter:0,status:404
    });
    const fallback=await fixture(2);try {
      fallback.behavior=async(call,response)=>{
        if(call.index===0){response.writeHead(404,{'content-type':'application/json'});response.end(JSON.stringify({error:{message:'route not found'}}));return true;}
        return false;
      };
      const result=await fallback.post();assert.equal(result.status,200,result.text);
      assert.deepEqual(fallback.calls.map(call=>call.index),[0,1]);
    }finally{await fallback.close();}
    const single=await fixture();try {
      single.behavior=async(_call,response)=>{response.writeHead(404,{'content-type':'application/json'});response.end(JSON.stringify({error:{message:'route not found'}}));return true;};
      const result=await single.post();assert.equal(result.status,400,result.text);
      assert.equal(result.value.error.code,'protocol_error',result.text);
      assert.equal(single.calls.length,1);
      assert.ok(!result.text.includes('route not found'),result.text);
    }finally{await single.close();}
  });
  await test('实际推理失败保留可操作类别，多类故障才汇总为接口池耗尽',async()=>{
    const cases=[
      [401,{error:{code:'invalid_api_key'}},'authentication_failed'],
      [404,{error:{code:'model_not_found'}},'model_unavailable'],
      [429,{error:{code:'project_spend_limit_exceeded'}},'quota_exhausted'],
      [503,{error:{code:'synthetic_unavailable'}},'upstream_unavailable'],
      [200,{choices:[]},'invalid_response'],
    ];
    for(const [status,body,expected] of cases) {
      const f=await fixture();try {
        f.behavior=async(_call,response)=>{response.writeHead(status,{'content-type':'application/json'});response.end(JSON.stringify(body));return true;};
        const result=await f.post();assert.equal(result.status,400,result.text);assert.equal(result.value.error.code,expected,result.text);
        assert.equal(f.calls.length,1);assert.ok(!result.text.includes('synthetic_unavailable'));
      }finally{await f.close();}
    }
    const same=await fixture(2);try {
      same.behavior=async(_call,response)=>{response.writeHead(503,{'content-type':'application/json'});response.end('{}');return true;};
      const result=await same.post();assert.equal(result.value.error.code,'upstream_unavailable',result.text);assert.equal(same.calls.length,2);
    }finally{await same.close();}
    const mixed=await fixture(2);try {
      mixed.behavior=async(call,response)=>{response.writeHead(call.index===0?401:503,{'content-type':'application/json'});response.end(JSON.stringify({error:{code:call.index===0?'invalid_api_key':'synthetic_unavailable'}}));return true;};
      const result=await mixed.post();assert.equal(result.value.error.code,'pool_exhausted',result.text);assert.equal(mixed.calls.length,2);
    }finally{await mixed.close();}
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
  await test('A29 /api编辑与旧投影统一到/api/v1，候选验证、秘密提交、热加载及Chat/Responses实际路径同核',async()=>{
    const f=await fixture();try {
      const primary=f.pool.primary_id,apiBase=f.upstreamBase+'/p0/api',canonical=apiBase+'/v1',
        runtimeCanonical=canonical.replace('127.0.0.1','host.docker.internal'),canonicalPath='/p0/api/v1';
      for(const suffix of ['?x=1','#fragment','/../escape','/%2e%2e/escape']) {
        const source=copy(f.pool);delete source.secrets_generation;source.entries[0].base_url=apiBase+suffix;
        const rejected=await f.cli(['validate-file',f.file(source)]);assert.notEqual(rejected.code,0,rejected.stdout);
      }
      const allowed=new Set([canonicalPath+'/models',canonicalPath+'/chat/completions',canonicalPath+'/responses']);
      f.behavior=async(call,response)=>{
        response.setHeader('content-type','application/json');
        if(call.path===canonicalPath+'/models'){response.end(JSON.stringify({data:[{id:'fixture-path-chat'},{id:'fixture-path-responses'}]}));return true;}
        if(call.path===canonicalPath+'/chat/completions'){response.end(JSON.stringify(chat('Chat 路径回答')));return true;}
        if(call.path===canonicalPath+'/responses'){response.end(JSON.stringify({status:'completed',output:[{type:'message',content:[{type:'output_text',text:'Responses 回答'}]}]}));return true;}
        assert.ok(!allowed.has(call.path));response.writeHead(404);response.end(JSON.stringify({error:{code:'fixture_wrong_path'}}));return true;
      };
      let result=await f.cli(['models',primary,f.file({provider:{base_url:apiBase},api_key:'fixture-path-chat-key'})]);
      assert.equal(result.code,0,result.stdout);assert.equal(f.calls.at(-1).path,canonicalPath+'/models');
      assert.equal(f.calls.at(-1).headers.authorization,'Bearer fixture-path-chat-key');
      result=await f.cli(['edit',primary,f.file({provider:{base_url:apiBase,model:'fixture-path-chat',api_mode:'chat_completions',
        capabilities:{chat_completions:true,responses:false,vision:false}},api_key:'fixture-path-chat-key'})]);
      assert.equal(result.code,0,result.stdout);f.reload();
      assert.equal(f.pool.entries[0].base_url,canonical);assert.equal(f.pool.entries[0].api_mode,'chat_completions');
      assert.equal(f.secret[primary].api_key,'fixture-path-chat-key');
      assert.equal(read(path.join(f.directory,'config/provider-pool.yaml')).entries[0].base_url,canonical);
      assert.equal(read(path.join(f.directory,'config/provider.yaml')).provider.base_url,runtimeCanonical);
      assert.match(fs.readFileSync(path.join(f.directory,'.env'),'utf8'),new RegExp('^AI_API_PROBE_BASE_URL='+canonical.replace(/[.*+?^${}()|[\]\\]/g,'\\$&')+'$','m'));
      assert.match(fs.readFileSync(path.join(f.directory,'.env'),'utf8'),new RegExp('^AI_API_BASE_URL='+runtimeCanonical.replace(/[.*+?^${}()|[\]\\]/g,'\\$&')+'$','m'));
      assert.equal((await f.get('status')).revision,f.pool.revision);
      let answer=await f.post();assert.equal(answer.status,200,answer.text);assert.equal(f.calls.at(-1).path,canonicalPath+'/chat/completions');
      assert.equal(f.calls.at(-1).body.model,'fixture-path-chat');assert.equal(f.calls.at(-1).headers.authorization,'Bearer fixture-path-chat-key');

      result=await f.cli(['edit',primary,f.file({provider:{base_url:apiBase+'/',model:'fixture-path-responses',api_mode:'responses',
        capabilities:{chat_completions:false,responses:true,vision:false}},api_key:'fixture-path-responses-key'})]);
      assert.equal(result.code,0,result.stdout);f.reload();
      assert.equal(f.pool.entries[0].base_url,canonical);assert.equal(f.pool.entries[0].api_mode,'responses');
      assert.equal(f.secret[primary].api_key,'fixture-path-responses-key');
      answer=await f.post();assert.equal(answer.status,200,answer.text);assert.equal(answer.value.choices[0].message.content,'Responses 回答');
      assert.equal(f.calls.at(-1).path,canonicalPath+'/responses');assert.equal(f.calls.at(-1).body.model,'fixture-path-responses');
      assert.equal(f.calls.at(-1).headers.authorization,'Bearer fixture-path-responses-key');
      const visible=await f.cli(['entry',primary]);assert.equal(visible.code,0,visible.stdout);assert.equal(visible.value.entry.base_url,canonical);
      assert.ok(!visible.stdout.includes('fixture-path-responses-key'));

      // 兼容已由旧编辑器发布为 /api 的投影：运行中 adapter 也使用同一规范化，不请求错误路径。
      f.publish(pool=>{pool.entries[0].base_url=apiBase;});
      answer=await f.post();assert.equal(answer.status,200,answer.text);assert.equal(f.calls.at(-1).path,canonicalPath+'/responses');
      assert.equal(f.calls.at(-1).headers.authorization,'Bearer fixture-path-responses-key');
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
      assert.equal((await f.post({messages:[sample.messages[0],{role:'user',content:'x'.repeat(1000)}]})).status,200);assert.deepEqual(f.calls.map(call=>call.index),[1]);
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
  await test('适配器仅回显新revision不得冒充已应用，原池与Key必须成套恢复',async()=>{
    const f=await fixture(2);let liar;
    try {
      liar=http.createServer((_request,response)=>{
        response.setHeader('content-type','application/json');
        response.end(JSON.stringify({revision:read(f.poolFile).revision}));
      });
      await new Promise(resolve=>liar.listen(0,'127.0.0.1',resolve));
      const beforePool=copy(f.pool),beforeSecret=copy(f.secret);
      const result=await f.cli(['enable',f.pool.entries[1].id,'false'],{
        PROVIDER_ADAPTER_MANAGEMENT_URL:`http://127.0.0.1:${liar.address().port}`
      });
      assert.notEqual(result.code,0,result.stdout);
      assert.equal(result.value.error.code,'readback_failed');
      f.reload();
      assert.ok(f.pool.revision>beforePool.revision+1);
      assert.deepEqual(f.pool.entries,beforePool.entries);
      assert.deepEqual(f.secret,beforeSecret);
    }finally{
      if(liar){liar.closeAllConnections();await new Promise(resolve=>liar.close(resolve));}
      await f.close();
    }
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
      assert.equal((await f.post({messages:[sample.messages[0],{role:'user',content}]})).status,200);assert.equal(f.calls.length,1);
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
      const oldEnvelope=f.envelope(),oldBody={messages:[sample.messages[0],{role:'user',content:'原问题等待备用'}]};
      const pending=f.post(oldBody,oldEnvelope).then(result=>{oldSettled=true;return result;});
      await until(()=>backupEntered,'原问题未进入慢备用');
      const cooling=(await f.get('status')).entries[0];assert.equal(cooling.health,'cooling');assert.equal(oldSettled,false);
      await sleep(Math.max(0,cooling.cooldown_until-Date.now())+40);
      const newEnvelope=f.envelope(),newBody={messages:[sample.messages[0],{role:'user',content:'冷却到期后的独立新问题'}]};
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
