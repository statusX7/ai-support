'use strict';

// 生产 CLI、接口池与本地 HTTP adapter；Docker/数据库边界明确使用既有协议夹具。
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const crypto = require('node:crypto');
const {spawn} = require('node:child_process');
const {createAdapter} = require('../scripts/provider-adapter.js');

const project = path.resolve(__dirname, '..');
const baseWork = path.join(project, '.work/v1.3.0');
const currentVersion = fs.readFileSync(path.join(project, 'VERSION'), 'utf8').trim();
const knowledgeModules = ['scripts/knowledge-component.js','scripts/knowledge-profile.py',
  'scripts/knowledge-profile.sh','scripts/knowledge-lexical.py','n8n/admin-query.js','n8n/knowledge-lexical.js'];
fs.mkdirSync(baseWork, {recursive:true});
const work = fs.mkdtempSync(path.join(baseWork, 'provider-lifecycle-'));
const read = file => JSON.parse(fs.readFileSync(file, 'utf8'));
const write = (file, value) => fs.writeFileSync(file, typeof value === 'string' ? value : JSON.stringify(value), {mode:0o600});
const digest = value => crypto.createHash('sha256').update(value).digest('hex');
const command = (program, args, options = {}) => new Promise((resolve, reject) => {
  const child = spawn(program, args, {cwd:work, env:{...process.env,...options.env}, stdio:['pipe','pipe','pipe']});
  let stdout='', stderr='', finished=false, forced=null, timedOut=false, deadline=null;
  const finish=(result,error=null)=>{
    if(finished)return;
    finished=true;
    if(deadline)clearTimeout(deadline);
    if(forced)clearTimeout(forced);
    if(error)reject(error);else resolve(timedOut ? {...result,code:124} : result);
  };
  child.stdout.on('data', chunk => stdout += chunk); child.stderr.on('data', chunk => stderr += chunk);
  child.once('error', error => finish(null,error));
  child.once('close', code => finish({code,stdout,stderr}));
  deadline=setTimeout(()=>{
    timedOut=true;
    stderr+='\n受控生命周期子进程超过本地截止时间';
    child.kill('SIGTERM');
    forced=setTimeout(()=>child.kill('SIGKILL'),2000);
  },options.timeout || 300000);
  child.stdin.end(options.input || '');
});
const checked = async (program, args, options) => { const result=await command(program,args,options); assert.equal(result.code,0,result.stderr + result.stdout); return result; };
const files = directory => fs.readdirSync(directory,{withFileTypes:true}).flatMap(entry => {
  const file=path.join(directory,entry.name); return entry.isDirectory() ? files(file) : [file];
});
async function repack(archive, name, mutate) {
  const directory=path.join(work,name); fs.mkdirSync(directory);
  await checked('tar',['-xzf',archive,'-C',directory]);
  await mutate(directory);
  const checksums=files(directory).filter(file=>path.basename(file)!=='checksums.sha256').sort().map(file=>digest(fs.readFileSync(file))+'  ./'+path.relative(directory,file)+'\n').join('');
  write(path.join(directory,'checksums.sha256'),checksums);
  const output=path.join(work,name+'.tar.gz'); await checked('tar',['-czf',output,'-C',directory,'.']); return output;
}

async function fixture() {
  const deploy=path.join(work,'deploy');
  for (const directory of ['config','knowledge','tmp','logs','data/runtime','data/anythingllm','data/postgres','data/n8n','data/analytics','backups/config-history','backups/versions','bin','systemd']) fs.mkdirSync(path.join(deploy,directory),{recursive:true});
  for (const directory of ['scripts','docs','n8n']) fs.cpSync(path.join(project,directory),path.join(deploy,directory),{recursive:true});
  for (const name of ['VERSION','CHANGELOG.md','README.md','LICENSE','AGENTS.md','.env.example','docker-compose.yml','get.sh','install.sh','manage.sh','update.sh','uninstall.sh']) fs.copyFileSync(path.join(project,name),path.join(deploy,name));
  for (const name of fs.readdirSync(path.join(project,'config'))) if(name.endsWith('.example') || name==='app.yaml') fs.copyFileSync(path.join(project,'config',name),path.join(deploy,'config',name));
  for (const name of ['keyword','handoff','menu','tags','feedback','provider','runtime']) {
    const target=path.join(deploy,`config/${name}.yaml`);fs.copyFileSync(path.join(project,`config/${name}.yaml.example`),target);fs.chmodSync(target,0o640);
  }
  fs.copyFileSync(path.join(project,'config/prompt.md.example'),path.join(deploy,'config/prompt.md'));
  fs.chmodSync(path.join(deploy,'config/prompt.md'),0o640);
  fs.copyFileSync(path.join(project,'tests/mocks/configuration_docker'),path.join(deploy,'bin/docker')); fs.chmodSync(path.join(deploy,'bin/docker'),0o755);
  write(path.join(deploy,'VERSION'),currentVersion+'\n');
  write(path.join(deploy,'.crisp-ai-installation'),'ai-support\nstate=local-ready\nsource='+project+'\ninstalled_version='+currentVersion+'\n');
  write(path.join(deploy,'config/.crispai-launcher'),path.join(work,'crispai')+'\n');
  let prompt=fs.readFileSync(path.join(deploy,'config/prompt.md'),'utf8');
  const f={deploy,calls:[],rejectModel:'',adapter:null,adapterBase:'',secret:'synthetic-lifecycle-primary-key',header:'synthetic-lifecycle-header-value'};
  f.service=http.createServer(async(request,response)=>{
    let raw='';for await(const chunk of request)raw+=chunk;
    const body=JSON.parse(raw || '{}');
    const send=(status,value)=>{response.writeHead(status,{'content-type':'application/json'});response.end(JSON.stringify(value));};
    if(request.url==='/api/v1/auth'){send(200,{authenticated:true});return;}
    if(request.url==='/healthz' || request.url==='/api/ping'){send(200,{ok:true});return;}
    if(request.url.startsWith('/webhook/crisp-webhook?')){send(401,{accepted:false,reason:'Webhook 校验失败'});return;}
    if(request.url==='/api/v1/workspace/crisp-support'){send(200,{workspace:[{slug:'crisp-support',openAiPrompt:prompt,documents:[]}]});return;}
    if(request.url==='/api/v1/workspace/crisp-support/update'){prompt=body.openAiPrompt;send(200,{workspace:{slug:'crisp-support',openAiPrompt:prompt}});return;}
    if(request.url==='/api/v1/workspace/crisp-support/update-embeddings' || request.url==='/api/v1/system/remove-documents'){send(200,{success:true});return;}
    if(request.url.startsWith('/upstream/')){
      f.calls.push({path:request.url,headers:request.headers,body});
      if(body.model===f.rejectModel){send(404,{error:{code:'model_not_found'}});return;}
      send(200,request.url.endsWith('/models')?{data:[{id:'synthetic-model'}]}:request.url.endsWith('/responses')?{output_text:'受控生命周期回答'}:{choices:[{message:{content:'受控生命周期回答'}}]});return;
    }
    send(404,{error:'synthetic-unknown-route'});
  });
  await new Promise(resolve=>f.service.listen(0,'127.0.0.1',resolve));
  f.port=f.service.address().port; f.base=`http://127.0.0.1:${f.port}/upstream/primary/v1`;
  f.initialEnv=`ANYTHINGLLM_API_KEY=synthetic-lifecycle-anything-key\nANYTHINGLLM_WORKSPACE=crisp-support\nANYTHINGLLM_PORT=${f.port}\nN8N_PORT=${f.port}\nLOCAL_HEALTH_TIMEOUT_SECONDS=2\nLOCAL_HEALTH_INTERVAL_SECONDS=1\nN8N_WORKFLOW_READY_TIMEOUT_SECONDS=2\nAI_API_BASE_URL=${f.base}\nAI_API_PROBE_BASE_URL=${f.base}\nAI_API_KEY=${f.secret}\nAI_MODEL=synthetic-primary-model\nAI_API_MODE=chat_completions\nAI_CUSTOM_HEADERS_JSON='{"X-Original":"${f.header}"}'\nPOSTGRES_PASSWORD=synthetic-lifecycle-database-password\nPOSTGRES_USER=crisp_ai\nPOSTGRES_DB=n8n\nN8N_IMAGE=docker.n8n.io/n8nio/n8n:2.33.0\nPOSTGRES_IMAGE=postgres:16.10-alpine\nANYTHINGLLM_IMAGE=mintplexlabs/anythingllm:1.16.1\nCADDY_IMAGE=caddy:2.10.2-alpine\nSNAPSHOT_MIN_FREE_MB=0\nSNAPSHOT_RETENTION_COUNT=0\n`;
  write(path.join(deploy,'.env'),f.initialEnv);
  write(path.join(deploy,'config/provider.yaml'),{schema_version:2,provider:{base_url:f.base,model:'synthetic-primary-model',api_mode:'chat_completions',api_key_env:'AI_API_KEY'}});
  f.invoke=(script,args=[],overrides={})=>command('bash',[path.join(project,'scripts',script),'--deploy-dir',deploy,...args],{env:{PATH:deploy+'/bin:'+process.env.PATH,CONFIGURATION_FIXTURE_DEPLOY:deploy,PROVIDER_ADAPTER_MANAGEMENT_URL:f.adapterBase,...overrides}});
  f.reconfigurePrimary=(base,key,model,mode='chat_completions',vision='false')=>command('bash',['-c',
    'set -euo pipefail\nsource "$1/scripts/common.sh"\nconfigure_provider_pool_primary "$1" "$2" "$3" "$4" "$5" "$6"',
    '--',deploy,base,key,model,mode,vision],{env:{PATH:deploy+'/bin:'+process.env.PATH,PROVIDER_ADAPTER_MANAGEMENT_URL:f.adapterBase}});
  f.ok=async(script,args=[],overrides={})=>{const result=await f.invoke(script,args,overrides);assert.equal(result.code,0,script+' '+args.join(' ')+'\n'+result.stderr+result.stdout);return result;};
  f.pool=()=>read(path.join(deploy,'config/provider-pool-applied.json'));
  f.source=()=>read(path.join(deploy,'config/provider-pool.yaml'));
  f.secretEntries=()=>read(path.join(deploy,'secrets/provider/generations',f.pool().secrets_generation+'.json')).entries;
  f.candidate=(name,value)=>{const file=path.join(work,name+'.json');write(file,value);return file;};
  f.capture=()=>Object.fromEntries(['.env','config/provider-pool.yaml','config/provider-pool-applied.json'].map(name=>[name,fs.readFileSync(path.join(deploy,name),'utf8')]));
  f.start=async()=>{
    const key=/^PROVIDER_ADAPTER_KEY=(.*)$/m.exec(fs.readFileSync(path.join(deploy,'.env'),'utf8'))[1];
    f.adapter=createAdapter({PROVIDER_ROOT:deploy,PROVIDER_POOL_REQUIRED:'true',PROVIDER_REQUIRE_ENVELOPE:'true',PROVIDER_ADAPTER_KEY:key});
    await new Promise(resolve=>f.adapter.listen(0,'127.0.0.1',resolve));f.adapterBase=`http://127.0.0.1:${f.adapter.address().port}`;
  };
  f.close=async()=>{if(f.adapter){f.adapter.closeAllConnections();await new Promise(resolve=>f.adapter.close(resolve));}f.service.closeAllConnections();await new Promise(resolve=>f.service.close(resolve));};
  f.snapshotEnv={PATH:path.join(project,'tests/mocks')+':'+process.env.PATH,MOCK_DOCKER_LOG:path.join(work,'snapshot-docker.log'),MOCK_DOCKER_SERVICE_STATE:path.join(work,'snapshot-services'),CRISPAI_LOGS_SYSTEMD_TEST:'1',CRISPAI_LOGS_SYSTEMD_DIR:path.join(deploy,'systemd'),MOCK_SYSTEMD_STATE:path.join(work,'systemd-state')};
  write(f.snapshotEnv.MOCK_DOCKER_LOG,'');write(f.snapshotEnv.MOCK_DOCKER_SERVICE_STATE,'postgres\nanythingllm\nn8n\nprovider-adapter\n');fs.mkdirSync(f.snapshotEnv.MOCK_SYSTEMD_STATE,{recursive:true});
  return f;
}

let passed=0,failed=0;
async function test(name, action) {
  try {await action();passed++;process.stdout.write('通过 UNIT/CONTRACT '+name+'\n');}
  catch(error){failed++;process.stdout.write('失败 UNIT/CONTRACT '+name+'\n'+error.stack+'\n');}
}
async function main(){
  const f=await fixture();let bundle,fullSnapshot;
  try{
    await test('PL01 生产迁移保持单接口四元组及Header，独立内部认证与本地adapter一致',async()=>{
      await f.ok('provider.sh',['migrate']);await f.start();
      const current=f.pool(),primary=current.entries[0],secret=f.secretEntries()[primary.id];
      assert.equal(primary.base_url,f.base);assert.equal(primary.model,'synthetic-primary-model');assert.equal(primary.api_mode,'chat_completions');
      assert.equal(secret.api_key,f.secret);assert.equal(secret.custom_headers['x-original'],f.header);assert.equal(f.calls.length,0);
      const before=f.capture();await f.ok('provider.sh',['migrate']);assert.deepEqual(f.capture(),before);
      const observed=JSON.parse((await f.ok('provider.sh',['status'])).stdout);assert.equal(observed.revision,current.revision);
      await f.ok('configuration.sh',['migrate']);await f.ok('knowledge.sh',['sync']);await f.ok('materials.sh',['initialize']);await f.ok('configuration.sh',['materials-apply']);
      assert.notEqual(/^PROVIDER_ADAPTER_KEY=(.*)$/m.exec(fs.readFileSync(path.join(f.deploy,'.env'),'utf8'))[1],f.secret);
    });
    await test('PL02 业务导出包含全部非敏感池原文，排除全部Key、Header值和运行秘密引用',async()=>{
      for(let index=1;index<=2;index++)await f.ok('provider.sh',['add',f.candidate('backup-'+index,{provider:{name:'备用'+index,base_url:`http://127.0.0.1:${f.port}/upstream/backup${index}/v1`,model:'synthetic-backup-'+index,api_mode:index===2?'responses':'chat_completions',custom_headers:{'X-Backup':'synthetic-backup-header-'+index}},api_key:'synthetic-backup-key-'+index})]);
      const backup=f.pool().entries[2].id;await f.ok('provider.sh',['enable',backup,'false']);
      const original=f.source();bundle=path.join(work,'business.tar.gz');await f.ok('migration.sh',['export',bundle]);
      const directory=path.join(work,'exported');fs.mkdirSync(directory);await checked('tar',['-xzf',bundle,'-C',directory]);
      const exported=read(path.join(directory,'config/provider-pool.yaml'));assert.deepEqual(exported,{...original,revision:0});
      assert.equal(exported.entries.length,3);assert.equal(exported.entries[2].enabled,false);
      const all=files(directory).map(file=>fs.readFileSync(file,'utf8')).join('\n');
      for(const secret of [f.secret,f.header,'synthetic-backup-key-1','synthetic-backup-key-2','synthetic-backup-header-1','synthetic-backup-header-2'])assert(!all.includes(secret));
      assert(!all.includes('secrets_generation'));assert(!fs.existsSync(path.join(directory,'.env')));assert(!fs.existsSync(path.join(directory,'secrets')));
      const preview=JSON.parse((await f.ok('migration.sh',['import-preview',bundle])).stdout);assert.equal(preview.provider_pool.entries.length,3);assert.equal(preview.manifest.contains_secrets,false);
    });
    await test('PL03 旧版无pool的启用评价业务包可导入，评价开关强制停用且保留原文',async()=>{
      const legacy=await repack(bundle,'legacy-feedback',directory=>{
        fs.unlinkSync(path.join(directory,'config/provider-pool.yaml'));
        const feedback=read(path.join(directory,'config/feedback.yaml'));Object.assign(feedback.feedback,{enabled:true,auto_invite:true,prompt:'旧包评价原文，仅供历史回读'});write(path.join(directory,'config/feedback.yaml'),feedback);
      });
      const before=f.secretEntries();const result=await f.ok('migration.sh',['import',legacy]);assert.equal(JSON.parse(result.stdout).applied,true);
      const feedback=read(path.join(f.deploy,'config/feedback.yaml')).feedback;assert.equal(feedback.enabled,false);assert.equal(feedback.auto_invite,false);assert.equal(feedback.prompt,'旧包评价原文，仅供历史回读');assert.deepEqual(f.secretEntries(),before);
    });
    await test('PL04 同ID导入保留每条秘密，未知备用仅存停用草稿',async()=>{
      const known=f.secretEntries(),primary=f.pool().primary_id;
      const candidate=await repack(bundle,'same-id-import',directory=>{
        const source=read(path.join(directory,'config/provider-pool.yaml'));source.entries[1].model='synthetic-imported-model';
        source.entries.push({...source.entries[1],id:'p_'+'d'.repeat(24),name:'缺Key的导入备用',order:source.entries.length});write(path.join(directory,'config/provider-pool.yaml'),source);
      });
      const result=JSON.parse((await f.ok('migration.sh',['import',candidate])).stdout);assert.equal(result.applied,true);
      assert.equal(f.pool().primary_id,primary);for(const [id,secret]of Object.entries(known))assert.deepEqual(f.secretEntries()[id],secret);
      const imported=f.pool().entries.at(-1);assert.equal(imported.draft,true);assert.equal(imported.enabled,false);assert.equal(f.secretEntries()[imported.id].api_key,'');
      assert.equal((await f.invoke('provider.sh',['enable',imported.id,'true'])).code,1);
    });
    await test('PL05 未知主导入只保存草稿，已有有效池和本机Key不改变',async()=>{
      const before=f.capture(),secret=f.secretEntries();
      const candidate=await repack(bundle,'unknown-primary-import',directory=>{
        const source=read(path.join(directory,'config/provider-pool.yaml'));source.primary_id='p_'+'e'.repeat(24);source.entries[0].id=source.primary_id;write(path.join(directory,'config/provider-pool.yaml'),source);
      });
      const result=JSON.parse((await f.ok('migration.sh',['import',candidate])).stdout);assert.equal(result.applied,false);assert.equal(result.business_applied,true);assert.equal(result.provider_pool_applied,false);assert.equal(result.draft,true);
      assert.deepEqual(f.capture(),before);assert.deepEqual(f.secretEntries(),secret);
      const draft=JSON.parse((await f.ok('provider.sh',['draft'])).stdout);assert.equal(draft.applied,false);assert.equal(draft.entries[0].draft,true);assert.equal(draft.entries[0].enabled,false);
    });
    await test('PL06 22项候选apply与业务import在发布前拒绝且不改变旧池',async()=>{
      const original=f.source(),over=structuredClone(original);
      while(over.entries.length<22){const index=over.entries.length;over.entries.push({...over.entries[0],id:'p_'+index.toString(16).padStart(24,'0'),name:'超限备用'+index,role:'backup',order:index,enabled:false,draft:true});}
      const before=f.capture(),secret=f.secretEntries(),candidate=f.candidate('over-capacity',over);
      assert.notEqual((await f.invoke('provider.sh',['apply-file',candidate])).code,0);assert.deepEqual(f.capture(),before);
      const archive=await repack(bundle,'over-capacity-import',directory=>write(path.join(directory,'config/provider-pool.yaml'),over));
      assert.notEqual((await f.invoke('migration.sh',['import-preview',archive])).code,0);assert.notEqual((await f.invoke('migration.sh',['import',archive])).code,0);assert.deepEqual(f.capture(),before);assert.deepEqual(f.secretEntries(),secret);
      const material=fs.readFileSync(path.join(f.deploy,'config/materials-applied.json'),'utf8');write(path.join(f.deploy,'config/provider-pool.yaml'),over);
      try{assert.notEqual((await f.invoke('materials.sh',['apply'])).code,0);assert.equal(fs.readFileSync(path.join(f.deploy,'config/materials-applied.json'),'utf8'),material);assert.equal(fs.readFileSync(path.join(f.deploy,'config/provider-pool-applied.json'),'utf8'),before['config/provider-pool-applied.json']);}
      finally{write(path.join(f.deploy,'config/provider-pool.yaml'),before['config/provider-pool.yaml']);}
    });
    await test('PL07 materials候选验证失败保留有效池和秘密，状态仍明确待应用',async()=>{
      const before=f.capture(),secret=f.secretEntries(),candidate=f.source();candidate.entries[0].model='synthetic-rejected-model';f.rejectModel=candidate.entries[0].model;
      write(path.join(f.deploy,'config/provider-pool.yaml'),candidate);
      try{
        const result=await f.invoke('materials.sh',['apply']);assert.notEqual(result.code,0);assert.match(result.stderr,/上一有效池/);
        assert.equal(fs.readFileSync(path.join(f.deploy,'config/provider-pool-applied.json'),'utf8'),before['config/provider-pool-applied.json']);assert.equal(fs.readFileSync(path.join(f.deploy,'.env'),'utf8'),before['.env']);assert.deepEqual(f.secretEntries(),secret);
        const status=await f.invoke('materials.sh',['status']);assert.equal(status.code,2);assert.equal(JSON.parse(status.stdout).provider_pool.pending,true);
      }finally{f.rejectModel='';write(path.join(f.deploy,'config/provider-pool.yaml'),before['config/provider-pool.yaml']);}
    });
    await test('PL07A 已有池快速初始化原子替换当前主接口，失败保留投影且重复操作不丢备用',async()=>{
      const original=f.pool(),primary=original.primary_id,originalSecret=f.secretEntries()[primary];
      const layout=value=>value.entries.map(item=>({id:item.id,role:item.role,order:item.order}));
      const expectedLayout=layout(original),replacementBase=`http://127.0.0.1:${f.port}/upstream/reconfigured/v1`;
      const replacementKey='synthetic-reconfigured-primary-key',replacementModel='synthetic-reconfigured-model';
      let callStart=f.calls.length;
      let result=await f.reconfigurePrimary(replacementBase,replacementKey,replacementModel);
      assert.equal(result.code,0,result.stderr+result.stdout);
      assert.equal(f.pool().primary_id,primary);assert.deepEqual(layout(f.pool()),expectedLayout);
      assert.equal(f.pool().entries[0].base_url,replacementBase);assert.equal(f.pool().entries[0].model,replacementModel);
      assert.equal(f.secretEntries()[primary].api_key,replacementKey);
      assert.match(fs.readFileSync(path.join(f.deploy,'.env'),'utf8'),new RegExp('^AI_API_KEY='+replacementKey+'$','m'));
      assert.equal(read(path.join(f.deploy,'config/provider.yaml')).provider.model,replacementModel);
      await f.ok('provider.sh',['test',primary]);
      const replacementCalls=f.calls.slice(callStart);
      assert(replacementCalls.some(call=>call.path==='/upstream/reconfigured/v1/chat/completions' && call.body.model===replacementModel
        && call.headers.authorization==='Bearer '+replacementKey));

      const protectedFiles=['.env','config/provider.yaml','config/provider-pool.yaml','config/provider-pool-applied.json'];
      const beforeFailure=Object.fromEntries(protectedFiles.map(name=>[name,fs.readFileSync(path.join(f.deploy,name))]));
      const secretsBeforeFailure=structuredClone(f.secretEntries());
      f.rejectModel='synthetic-reconfigure-rejected-model';
      try{
        result=await f.reconfigurePrimary(`http://127.0.0.1:${f.port}/upstream/rejected/v1`,
          'synthetic-rejected-primary-key',f.rejectModel);
        assert.notEqual(result.code,0);assert.match(result.stderr,/原配置未更改/);
        for(const [name,content] of Object.entries(beforeFailure))assert.deepEqual(fs.readFileSync(path.join(f.deploy,name)),content,name);
        assert.deepEqual(f.secretEntries(),secretsBeforeFailure);
      }finally{f.rejectModel='';}

      result=await f.reconfigurePrimary(replacementBase,replacementKey,replacementModel);
      assert.equal(result.code,0,result.stderr+result.stdout);assert.equal(f.pool().primary_id,primary);
      assert.deepEqual(layout(f.pool()),expectedLayout);assert.equal(f.pool().entries.length,original.entries.length);
      assert.equal(new Set(f.pool().entries.map(item=>item.id)).size,original.entries.length);

      result=await f.reconfigurePrimary(original.entries[0].base_url,originalSecret.api_key,
        original.entries[0].model,original.entries[0].api_mode,String(original.entries[0].capabilities.vision));
      assert.equal(result.code,0,result.stderr+result.stdout);assert.deepEqual(layout(f.pool()),expectedLayout);
    });
    await test('PL11 任何知识迁移标记在容量及完整快照停服务前拒绝，不改池或调用模型',async()=>{
      const marker=path.join(f.deploy,'data/runtime/knowledge-migration.json'),before=f.capture(),callCount=f.calls.length;
      assert(!fs.existsSync(marker));
      for(const kind of ['file','malformed','dangling','fifo','directory']){
        if(kind==='file')write(marker,{state:'applying',synthetic:true});
        else if(kind==='malformed')write(marker,'{');
        else if(kind==='dangling')fs.symlinkSync('synthetic-missing',marker);
        else if(kind==='fifo')await checked('mkfifo',[marker]);
        else fs.mkdirSync(marker);
        try{
          for(const args of [['--quiet','--check-capacity'],['--quiet']]){
            write(f.snapshotEnv.MOCK_DOCKER_LOG,'');
            const result=await f.invoke('snapshot.sh',args,f.snapshotEnv);
            write(path.join(work,`pending-knowledge-${kind}-${args.length}.log`),result.stdout+result.stderr);
            assert.notEqual(result.code,0);assert.match(result.stderr,/知识迁移/);
            assert(!/\bstop\b/.test(fs.readFileSync(f.snapshotEnv.MOCK_DOCKER_LOG,'utf8')));
            assert.deepEqual(f.capture(),before);assert.equal(f.calls.length,callCount);assert(fs.lstatSync(marker));
          }
        }finally{kind==='directory'?fs.rmdirSync(marker):fs.unlinkSync(marker);}
      }
    });
    await test('PL08 本机完整快照包含同代secret/router、排除瞬时回读且缺回读仍可救援',async()=>{
      await f.ok('logs.sh',['initialize','--profile','new'],f.snapshotEnv);
      write(path.join(f.deploy,'data/provider-router/synthetic-preserved.json'),{synthetic:true,state:'旧路由状态必须成套恢复'});
      const readbackFile=path.join(f.deploy,'config/provider-pool-readback.json');
      await f.ok('provider.sh',['verify-applied']);
      const liveReadback=read(readbackFile),livePool=f.pool();
      assert.equal(liveReadback.revision,livePool.revision);
      assert.equal(liveReadback.secrets_generation,livePool.secrets_generation);
      assert.equal(liveReadback.pool_sha256,digest(fs.readFileSync(path.join(f.deploy,'config/provider-pool-applied.json'))));
      const adapter=path.join(f.deploy,'scripts/provider-adapter.js'),held=adapter+'.held';
      fs.renameSync(adapter,held);write(f.snapshotEnv.MOCK_DOCKER_LOG,'');
      try {
        const missing=await f.invoke('snapshot.sh',['--quiet','--check-capacity'],f.snapshotEnv);
        assert.notEqual(missing.code,0);assert.match(missing.stderr,/provider-adapter/);
        assert(!/\bstop\b/.test(fs.readFileSync(f.snapshotEnv.MOCK_DOCKER_LOG,'utf8')));
      } finally { fs.renameSync(held,adapter); }
      const result=await f.ok('snapshot.sh',['--quiet','--reason','synthetic-provider-lifecycle'],f.snapshotEnv);const id=result.stdout.trim();
      fullSnapshot=path.join(f.deploy,'backups/versions',id);const archive=path.join(fullSnapshot,'snapshot.tar.gz');
      assert.equal(fs.statSync(archive).mode&0o777,0o600);const directory=path.join(work,'snapshot-extracted');fs.mkdirSync(directory);await checked('tar',['-xzf',archive,'-C',directory]);
      const payload=path.join(directory,'payload'),pool=read(path.join(payload,'config/provider-pool-applied.json'));
      assert.deepEqual(pool,f.pool());assert.deepEqual(read(path.join(payload,'secrets/provider/generations',pool.secrets_generation+'.json')).entries,f.secretEntries());
      assert.deepEqual(fs.readFileSync(path.join(payload,'data/provider-router/synthetic-preserved.json')),fs.readFileSync(path.join(f.deploy,'data/provider-router/synthetic-preserved.json')));
      assert(!fs.existsSync(path.join(payload,'config/provider-pool-readback.json')));
      for(const name of ['provider-adapter.js','visitor-output.js','provider-router.js','provider-envelope.js','provider-pool.py','provider.sh','configuration.sh','materials-recovery.py','atomic-config.py'])assert.deepEqual(fs.readFileSync(path.join(payload,'scripts',name)),fs.readFileSync(path.join(f.deploy,'scripts',name)));
      for(const name of [...knowledgeModules,'n8n/runtime.js'])assert.deepEqual(fs.readFileSync(path.join(payload,name)),fs.readFileSync(path.join(f.deploy,name)));
      assert.deepEqual(fs.readFileSync(path.join(payload,'data/knowledge-projection.json')),fs.readFileSync(path.join(f.deploy,'data/knowledge-projection.json')));
      assert.equal(fs.statSync(path.join(payload,'data/knowledge-projection.json')).mode&0o777,0o600);
      assert.deepEqual(fs.readFileSync(path.join(payload,'backups/config-history/materials.applied.tar.gz')),
        fs.readFileSync(path.join(f.deploy,'backups/config-history/materials.applied.tar.gz')));
      assert.equal(fs.statSync(path.join(payload,'backups/config-history/materials.applied.tar.gz')).mode&0o777,0o600);
      assert.deepEqual(fs.readFileSync(path.join(payload,'.env')),fs.readFileSync(path.join(f.deploy,'.env')));
      assert.match(fs.readFileSync(f.snapshotEnv.MOCK_DOCKER_LOG,'utf8'),/stop .*provider-adapter/);

      fs.unlinkSync(readbackFile);write(f.snapshotEnv.MOCK_DOCKER_LOG,'');
      const rescue=await f.ok('snapshot.sh',['--quiet','--reason','synthetic-provider-rescue-without-readback'],f.snapshotEnv);
      assert(!fs.existsSync(readbackFile));
      const rescueDirectory=path.join(work,'snapshot-rescue-extracted');fs.mkdirSync(rescueDirectory);
      await checked('tar',['-xzf',path.join(f.deploy,'backups/versions',rescue.stdout.trim(),'snapshot.tar.gz'),'-C',rescueDirectory]);
      const rescuePayload=path.join(rescueDirectory,'payload'),rescuePool=read(path.join(rescuePayload,'config/provider-pool-applied.json'));
      assert(!fs.existsSync(path.join(rescuePayload,'config/provider-pool-readback.json')));
      assert.deepEqual(rescuePool,f.pool());
      assert.deepEqual(read(path.join(rescuePayload,'secrets/provider/generations',rescuePool.secrets_generation+'.json')).entries,f.secretEntries());
      assert.deepEqual(fs.readFileSync(path.join(rescuePayload,'data/provider-router/synthetic-preserved.json')),fs.readFileSync(path.join(f.deploy,'data/provider-router/synthetic-preserved.json')));
      await f.ok('provider.sh',['verify-applied']);
      assert.equal(read(readbackFile).pool_sha256,digest(fs.readFileSync(path.join(f.deploy,'config/provider-pool-applied.json'))));
    });
    await test('PL08A 历史快照中的旧回读在回滚组件启动前失效并由当前adapter重新签发',async()=>{
      const stage=path.join(work,'stale-readback-snapshot');fs.mkdirSync(stage);
      await checked('tar',['-xzf',path.join(fullSnapshot,'snapshot.tar.gz'),'-C',stage]);
      const payload=path.join(stage,'payload'),poolFile=path.join(payload,'config/provider-pool-applied.json'),pool=read(poolFile);
      const archivedReadback=path.join(payload,'config/provider-pool-readback.json');
      write(archivedReadback,{schema_version:1,readback_contract_version:1,revision:pool.revision,
        secrets_generation:pool.secrets_generation,pool_sha256:digest(fs.readFileSync(poolFile)),verified_at:1});
      const id='synthetic-stale-provider-readback',directory=path.join(f.deploy,'backups/versions',id);
      fs.mkdirSync(directory);const archive=path.join(directory,'snapshot.tar.gz');
      await checked('tar',['-czf',archive,'-C',stage,'payload']);
      write(path.join(directory,'manifest.json'),{...read(path.join(fullSnapshot,'manifest.json')),id,archive_sha256:digest(fs.readFileSync(archive))});
      const expectedMaterials=fs.readFileSync(path.join(payload,'backups/config-history/materials.applied.tar.gz'));
      fs.writeFileSync(path.join(f.deploy,'backups/config-history/materials.applied.tar.gz'),'synthetic-invalid-current-canonical',{mode:0o600});

      const guardBin=path.join(work,'readback-guard-bin'),guardLog=path.join(work,'readback-guard.log');
      fs.mkdirSync(guardBin);write(guardLog,'');
      const guardDocker=path.join(guardBin,'docker');
      fs.writeFileSync(guardDocker,[
        '#!/usr/bin/env bash',
        'set -euo pipefail',
        'if [[ "${MOCK_REQUIRE_READBACK_ABSENT_ON_UP:-0}" == 1 && "${1:-}" == compose && " $* " == *" up "* ]]; then',
        '  [[ ! -e "${MOCK_READBACK_GUARD_DEPLOY:?}/config/provider-pool-readback.json" && ! -L "${MOCK_READBACK_GUARD_DEPLOY}/config/provider-pool-readback.json" ]] || { printf "%s\\n" "旧回读在组件启动前仍存在" >&2; exit 86; }',
        '  printf "%s\\n" "checked-before-up" >> "${MOCK_READBACK_GUARD_LOG:?}"',
        'fi',
        `exec ${JSON.stringify(path.join(project,'tests/mocks/docker'))} "$@"`,
        '',
      ].join('\n'),{mode:0o700});
      write(f.snapshotEnv.MOCK_DOCKER_LOG,'');
      const result=await f.invoke('rollback.sh',['--snapshot',id,'--no-safety-snapshot'],{
        ...f.snapshotEnv,PATH:guardBin+':'+f.snapshotEnv.PATH,MOCK_REQUIRE_READBACK_ABSENT_ON_UP:'1',
        MOCK_READBACK_GUARD_DEPLOY:f.deploy,MOCK_READBACK_GUARD_LOG:guardLog,
      });
      assert.equal(result.code,0,result.stdout+result.stderr);
      assert.match(fs.readFileSync(guardLog,'utf8'),/checked-before-up/);
      const current=f.pool(),receipt=read(path.join(f.deploy,'config/provider-pool-readback.json'));
      assert.notEqual(receipt.verified_at,1);assert.equal(receipt.revision,current.revision);
      assert.equal(receipt.secrets_generation,current.secrets_generation);
      assert.equal(receipt.pool_sha256,digest(fs.readFileSync(path.join(f.deploy,'config/provider-pool-applied.json'))));
      assert.deepEqual(fs.readFileSync(path.join(f.deploy,'backups/config-history/materials.applied.tar.gz')),expectedMaterials);
      await f.ok('provider.sh',['readback']);
    });
    await test('PL09 缺秘密代次的自洽快照在停服务前拒绝，不留下混合恢复',async()=>{
      const stage=path.join(work,'broken-snapshot');fs.mkdirSync(stage);await checked('tar',['-xzf',path.join(fullSnapshot,'snapshot.tar.gz'),'-C',stage]);
      const pool=read(path.join(stage,'payload/config/provider-pool-applied.json'));fs.unlinkSync(path.join(stage,'payload/secrets/provider/generations',pool.secrets_generation+'.json'));
      const id='synthetic-broken-provider',directory=path.join(f.deploy,'backups/versions',id);fs.mkdirSync(directory);const archive=path.join(directory,'snapshot.tar.gz');await checked('tar',['-czf',archive,'-C',stage,'payload']);
      write(path.join(directory,'manifest.json'),{...read(path.join(fullSnapshot,'manifest.json')),id,archive_sha256:digest(fs.readFileSync(archive))});
      const before=f.capture();write(f.snapshotEnv.MOCK_DOCKER_LOG,'');const result=await f.invoke('rollback.sh',['--snapshot',id,'--no-safety-snapshot'],f.snapshotEnv);
      assert.notEqual(result.code,0);assert.match(result.stderr,/接口池与秘密代次不完整/);assert.deepEqual(f.capture(),before);assert(!/\bstop\b/.test(fs.readFileSync(f.snapshotEnv.MOCK_DOCKER_LOG,'utf8')));
    });
    await test('PL09A 活动资料恢复或初始化事务在停服务前阻止版本回滚',async()=>{
      for(const journal of ['materials.recovery','materials.initialize']){
        const target=path.join(f.deploy,'backups/config-history',journal);fs.mkdirSync(target,{mode:0o700});
        try{
          const before=f.capture();write(f.snapshotEnv.MOCK_DOCKER_LOG,'');
          const result=await f.invoke('rollback.sh',['--snapshot',path.basename(fullSnapshot),'--no-safety-snapshot'],f.snapshotEnv);
          assert.notEqual(result.code,0,journal);assert.match(result.stderr,/资料事务尚未收口/,journal);
          assert.deepEqual(f.capture(),before);assert(!/\bstop\b/.test(fs.readFileSync(f.snapshotEnv.MOCK_DOCKER_LOG,'utf8')),journal);
        }finally{fs.rmdirSync(target);}
      }
    });
    await test('PL09B 未决敏感配置事务与恢复材料在停服务前阻止无安全快照回滚',async()=>{
      const variants=[
        ['journal','.env.crispai-atomic.json',/敏感配置提交事务尚未收口/],
        ['transition','.env.crispai-atomic.next',/敏感配置提交事务尚未收口/],
        ['source','.env.source.synthetic',/敏感配置存在未归属恢复材料/],
        ['candidate','.env.tmp.synthetic',/敏感配置存在未归属恢复材料/],
      ];
      for(const [name,relative,expected] of variants){
        const target=path.join(f.deploy,relative),body='synthetic-atomic-recovery-'+name+'\n';
        write(target,body);
        try{
          const before=f.capture(),callCount=f.calls.length;write(f.snapshotEnv.MOCK_DOCKER_LOG,'');
          const result=await f.invoke('rollback.sh',['--snapshot',path.basename(fullSnapshot),'--no-safety-snapshot'],f.snapshotEnv);
          assert.notEqual(result.code,0,name);assert.match(result.stderr,expected,name);
          assert.deepEqual(f.capture(),before,name);assert.equal(f.calls.length,callCount,name);
          assert.equal(fs.readFileSync(target,'utf8'),body,name);
          assert(!/\bstop\b/.test(fs.readFileSync(f.snapshotEnv.MOCK_DOCKER_LOG,'utf8')),name);
        }finally{fs.unlinkSync(target);}
      }
    });
    await test('PL12 知识中间代、部分模块及冒充旧候选的自洽载荷全部停前拒绝',async()=>{
      const clearNewModules=payload=>{
        for(const name of knowledgeModules)fs.unlinkSync(path.join(payload,name));
        for(const name of ['knowledge-profile.json','knowledge-lexical.json']){
          const file=path.join(payload,'data/runtime',name);if(fs.existsSync(file))fs.unlinkSync(file);
        }
        const materialFile=path.join(payload,'config/materials-applied.json'),material=read(materialFile);
        delete material.knowledge.profile_sha256;delete material.knowledge.lexical_sha256;write(materialFile,material);
      };
      const clearLexicalMetadata=payload=>{
        const file=path.join(payload,'n8n/workflow.json'),value=read(file);delete value.meta.lexicalFileSha256;write(file,value);
      };
      const variants=[
        ['pending',payload=>write(path.join(payload,'data/runtime/knowledge-migration.json'),{state:'applying'}),/未完成知识迁移/],
        ['malformed-pending',payload=>write(path.join(payload,'data/runtime/knowledge-migration.json'),'{'),/未完成知识迁移/],
        ['partial-module',payload=>fs.unlinkSync(path.join(payload,knowledgeModules[0])),/知识快照模块不完整/],
        ['missing-runtime',payload=>fs.unlinkSync(path.join(payload,'n8n/runtime.js')),/缺少必要文件.*runtime/],
        ['missing-adapter',payload=>fs.unlinkSync(path.join(payload,'scripts/provider-adapter.js')),/主备版本快照缺少必要文件.*provider-adapter/],
        ['missing-visitor-output',payload=>fs.unlinkSync(path.join(payload,'scripts/visitor-output.js')),/访客输出策略快照缺少必要文件.*visitor-output/],
        ['missing-materials-recovery',payload=>fs.unlinkSync(path.join(payload,'scripts/materials-recovery.py')),/资料恢复事务快照缺少必要文件.*materials-recovery/],
        ['missing-atomic-config',payload=>fs.unlinkSync(path.join(payload,'scripts/atomic-config.py')),/敏感配置原子提交快照缺少必要文件.*atomic-config/],
        ['missing-materials-canonical',payload=>fs.unlinkSync(path.join(payload,'backups/config-history/materials.applied.tar.gz')),/缺少成套资料投影或规范原文包/],
        ['mismatched-materials-canonical',async payload=>{
          const canonical=path.join(payload,'backups/config-history/materials.applied.tar.gz');
          const inner=path.join(work,'mismatched-materials-canonical-inner');fs.mkdirSync(inner);
          await checked('tar',['-xzf',canonical,'-C',inner]);
          fs.appendFileSync(path.join(inner,'config/prompt.md'),'\n不属于投影的候选文本\n');
          await checked('tar',['-czf',canonical,'-C',inner,'config','knowledge']);
        },/资料原文、知识索引与投影不同代/],
        ['unbound-knowledge-settings',payload=>{
          const file=path.join(payload,'data/runtime/knowledge-settings.json'),value=read(file);
          value.observed_at=(value.observed_at||0)+1;write(file,value);
        },/资料原文、知识索引与投影不同代/],
        ['linked-module',payload=>{fs.unlinkSync(path.join(payload,knowledgeModules[0]));fs.symlinkSync('synthetic-missing',path.join(payload,knowledgeModules[0]));},/链接或特殊文件/],
        ['declared-lexical',payload=>clearNewModules(payload),/声明了缺失的词法/],
        ['retained-profile',payload=>{clearNewModules(payload);clearLexicalMetadata(payload);write(path.join(payload,'data/runtime/knowledge-profile.json'),{state:'applied'});},/保留新索引代次/],
        ['retained-projection',payload=>{clearNewModules(payload);clearLexicalMetadata(payload);const file=path.join(payload,'config/materials-applied.json'),value=read(file);value.knowledge.profile_sha256='a'.repeat(64);write(file,value);},/投影引用了缺失/],
      ];
      for(const [name,mutate,expected] of variants){
        const stage=path.join(work,'knowledge-broken-'+name);fs.mkdirSync(stage);
        await checked('tar',['-xzf',path.join(fullSnapshot,'snapshot.tar.gz'),'-C',stage]);await mutate(path.join(stage,'payload'));
        const id='synthetic-knowledge-'+name,directory=path.join(f.deploy,'backups/versions',id);fs.mkdirSync(directory);
        const archive=path.join(directory,'snapshot.tar.gz');await checked('tar',['-czf',archive,'-C',stage,'payload']);
        write(path.join(directory,'manifest.json'),{...read(path.join(fullSnapshot,'manifest.json')),id,archive_sha256:digest(fs.readFileSync(archive))});
        const before=f.capture(),callCount=f.calls.length;write(f.snapshotEnv.MOCK_DOCKER_LOG,'');
        const result=await f.invoke('rollback.sh',['--snapshot',id,'--no-safety-snapshot'],f.snapshotEnv);
        write(path.join(work,'rollback-knowledge-'+name+'.log'),result.stdout+result.stderr);
        assert.notEqual(result.code,0,name);assert.match(result.stderr,expected,name);assert.deepEqual(f.capture(),before);assert.equal(f.calls.length,callCount);
        assert(!/\bstop\b/.test(fs.readFileSync(f.snapshotEnv.MOCK_DOCKER_LOG,'utf8')),name);
      }
    });
    await test('PL10 真实v1.1.0快照恢复旧程序配置，主备秘密与router受限成套保留',async()=>{
      const legacy=path.join(work,'legacy-v110');fs.mkdirSync(legacy);
      let sourceArchive=process.env.CRISPAI_TEST_V110_ARCHIVE||'';
      let sourceSha256=process.env.CRISPAI_TEST_V110_ARCHIVE_SHA256||'';
      assert.equal(Boolean(sourceArchive),Boolean(sourceSha256),
        'CRISPAI_TEST_V110_ARCHIVE 与 CRISPAI_TEST_V110_ARCHIVE_SHA256 必须成对提供');
      if(!sourceArchive){
        sourceArchive=path.join(work,'legacy-source.tar');
        const tag=await command('git',['-C',project,'rev-parse','--verify','v1.1.0^{commit}']);
        assert.equal(tag.code,0,'源码镜像不含 Git 历史时必须由测试编排器提供受控 v1.1.0 归档及 SHA256');
        await checked('git',['-C',project,'archive','--format=tar','--output',sourceArchive,'v1.1.0']);
        fs.chmodSync(sourceArchive,0o600);
        sourceSha256=digest(fs.readFileSync(sourceArchive));
      }
      await checked('python3',[path.join(project,'tests/extract_legacy_source.py'),'--archive',sourceArchive,
        '--sha256',sourceSha256,'--destination',legacy]);
      assert.equal(fs.readFileSync(path.join(legacy,'VERSION'),'utf8').trim(),'v1.1.0');
      for(const directory of ['knowledge','tmp','data/runtime','data/postgres','data/n8n','data/anythingllm','backups/versions'])fs.mkdirSync(path.join(legacy,directory),{recursive:true});
      for(const name of ['keyword','handoff','menu','tags','feedback','provider','runtime'])if(fs.existsSync(path.join(legacy,`config/${name}.yaml.example`)))fs.copyFileSync(path.join(legacy,`config/${name}.yaml.example`),path.join(legacy,`config/${name}.yaml`));
      fs.copyFileSync(path.join(legacy,'config/prompt.md.example'),path.join(legacy,'config/prompt.md'));
      write(path.join(legacy,'config/provider.yaml'),{schema_version:2,provider:{base_url:f.base,model:'synthetic-primary-model',api_mode:'chat_completions',api_key_env:'AI_API_KEY'}});
      write(path.join(legacy,'config/.crispai-launcher'),path.join(work,'crispai')+'\n');
      write(path.join(legacy,'.env'),f.initialEnv);write(path.join(legacy,'.crisp-ai-installation'),'ai-support\nstate=local-ready\nsource='+legacy+'\ninstalled_version=v1.1.0\n');
      write(path.join(legacy,'data/runtime/synthetic-legacy.json'),{synthetic:true,mode:'human',generation:7});
      write(path.join(legacy,'data/anythingllm/synthetic-legacy.json'),{synthetic:true,version:'v1.1.0'});
      const legacyEnv={...f.snapshotEnv,MOCK_ANYTHING_STATE:path.join(work,'legacy-anything-state.json'),MOCK_POSTGRES_PASSWORD_DIGEST_FILE:path.join(work,'legacy-postgres-password.sha256')};
      write(legacyEnv.MOCK_ANYTHING_STATE,{documents:[]});
      write(f.snapshotEnv.MOCK_DOCKER_SERVICE_STATE,'postgres\nanythingllm\nn8n\n');
      const snapshot=await checked('bash',[path.join(project,'scripts/snapshot.sh'),'--deploy-dir',legacy,'--quiet','--reason','synthetic-v110-restore'],{env:legacyEnv});const id=snapshot.stdout.trim();
      fs.cpSync(path.join(legacy,'backups/versions',id),path.join(f.deploy,'backups/versions',id),{recursive:true});
      const previous=f.pool(),previousSecret=f.secretEntries(),newRouter=fs.readFileSync(path.join(f.deploy,'data/provider-router/synthetic-preserved.json'));
      const appliedSource=path.join(work,'legacy-downgrade-applied-source');fs.mkdirSync(appliedSource);
      await checked('tar',['-xzf',path.join(f.deploy,'backups/config-history/materials.applied.tar.gz'),'-C',appliedSource]);
      const appliedPrompt=fs.readFileSync(path.join(appliedSource,'config/prompt.md'));
      const pendingPrompt='## 仅待编辑、尚未应用的降版保全 Prompt\n';
      fs.writeFileSync(path.join(f.deploy,'config/prompt.md'),pendingPrompt,{mode:0o640});
      assert(!fs.existsSync(path.join(legacy,'data/knowledge-projection.json')));
      assert(fs.existsSync(path.join(f.deploy,'data/knowledge-projection.json')));
      write(path.join(f.deploy,'data/runtime/synthetic-current-only.json'),{synthetic:true,version:currentVersion});
      write(f.snapshotEnv.MOCK_DOCKER_LOG,'');write(f.snapshotEnv.MOCK_DOCKER_SERVICE_STATE,'postgres\nanythingllm\nn8n\nprovider-adapter\n');
      f.adapter.closeAllConnections();await new Promise(resolve=>f.adapter.close(resolve));f.adapter=null;
      const rejected=await f.invoke('rollback.sh',['--snapshot',id,'--no-safety-snapshot'],legacyEnv);
      assert.notEqual(rejected.code,0);assert.match(rejected.stderr,/必须先创建安全快照/);
      assert(!/\bstop\b/.test(fs.readFileSync(f.snapshotEnv.MOCK_DOCKER_LOG,'utf8')));
      assert.equal(fs.readFileSync(path.join(f.deploy,'config/prompt.md'),'utf8'),pendingPrompt);
      write(f.snapshotEnv.MOCK_DOCKER_LOG,'');
      const result=await f.invoke('rollback.sh',['--snapshot',id],legacyEnv);
      write(path.join(work,'legacy-rollback.log'),result.stdout+result.stderr);assert.equal(result.code,0,result.stdout+result.stderr);
      for(const name of ['VERSION','install.sh','manage.sh','scripts/common.sh','scripts/provider.sh','n8n/runtime.js'])assert.deepEqual(fs.readFileSync(path.join(f.deploy,name)),fs.readFileSync(path.join(legacy,name)));
      for(const name of ['visitor-output.js','provider-router.js','provider-envelope.js','provider-pool.py','menu-display.py','menu-provider-ui.sh','materials-recovery.py','atomic-config.py'])assert(!fs.existsSync(path.join(f.deploy,'scripts',name)));
      for(const name of knowledgeModules)assert(!fs.existsSync(path.join(f.deploy,name)),name);
      assert(!fs.existsSync(path.join(f.deploy,'data/knowledge-projection.json')));
      assert(!fs.existsSync(path.join(f.deploy,'config/provider-pool-applied.json')));assert(!fs.existsSync(path.join(f.deploy,'config/provider-pool.yaml')));
      assert(!fs.existsSync(path.join(f.deploy,'secrets')));assert(!fs.existsSync(path.join(f.deploy,'data/provider-router')));
      assert(!fs.readFileSync(path.join(f.deploy,'.env'),'utf8').includes('PROVIDER_POOL_REQUIRED'));
      assert.deepEqual(read(path.join(f.deploy,'data/runtime/synthetic-legacy.json')),{synthetic:true,mode:'human',generation:7});assert(!fs.existsSync(path.join(f.deploy,'data/runtime/synthetic-current-only.json')));
      const kept=fs.readdirSync(path.join(f.deploy,'backups')).filter(name=>name.startsWith('provider-pre-rollback.')).map(name=>path.join(f.deploy,'backups',name));
      assert.equal(kept.length,2);assert(kept.every(directory=>(fs.statSync(directory).mode&0o777)===0o700));
      const retainedSecret=kept.map(directory=>path.join(directory,'secrets/provider/generations',previous.secrets_generation+'.json')).find(file=>fs.existsSync(file));assert.deepEqual(read(retainedSecret).entries,previousSecret);
      const retainedRouter=kept.map(directory=>path.join(directory,'provider-router/synthetic-preserved.json')).find(file=>fs.existsSync(file));assert.deepEqual(fs.readFileSync(retainedRouter),newRouter);
      const safetyDirectory=fs.readdirSync(path.join(f.deploy,'backups/versions')).map(name=>path.join(f.deploy,'backups/versions',name))
        .find(directory=>fs.existsSync(path.join(directory,'manifest.json'))
          && read(path.join(directory,'manifest.json')).reason===`pre-rollback-${id}`);
      assert.ok(safetyDirectory,'降版前必须保留成套安全快照');
      const safetyStage=path.join(work,'legacy-downgrade-safety');fs.mkdirSync(safetyStage);
      await checked('tar',['-xzf',path.join(safetyDirectory,'snapshot.tar.gz'),'-C',safetyStage]);
      assert.equal(fs.readFileSync(path.join(safetyStage,'payload/config/prompt.md'),'utf8'),pendingPrompt);
      const safetyCanonical=path.join(work,'legacy-downgrade-safety-canonical');fs.mkdirSync(safetyCanonical);
      await checked('tar',['-xzf',path.join(safetyStage,'payload/backups/config-history/materials.applied.tar.gz'),'-C',safetyCanonical]);
      assert.deepEqual(fs.readFileSync(path.join(safetyCanonical,'config/prompt.md')),appliedPrompt);
      const docker=fs.readFileSync(f.snapshotEnv.MOCK_DOCKER_LOG,'utf8');assert.match(docker,/pg_restore/);assert.match(docker,/--force-recreate anythingllm/);assert.equal(fs.readFileSync(legacyEnv.MOCK_POSTGRES_PASSWORD_DIGEST_FILE,'utf8').trim(),digest('synthetic-lifecycle-database-password'));
    });
    await test('PL13 旧版回滚后真实程序复制补齐七模块，不改知识原文或人工状态',async()=>{
      const protectedFiles=files(path.join(f.deploy,'knowledge')).concat(files(path.join(f.deploy,'data/runtime')));
      const before=Object.fromEntries(protectedFiles.map(file=>[file,digest(fs.readFileSync(file))]));
      await checked('bash',['-c','set -euo pipefail\nsource "$1/scripts/common.sh"\ncopy_project_files "$1" "$2"','--',project,f.deploy]);
      for(const name of ['scripts/visitor-output.js','scripts/materials-recovery.py','scripts/atomic-config.py',...knowledgeModules,'n8n/runtime.js','n8n/workflow.json'])assert.deepEqual(fs.readFileSync(path.join(f.deploy,name)),fs.readFileSync(path.join(project,name)),name);
      for(const [file,hash] of Object.entries(before))assert.equal(digest(fs.readFileSync(file)),hash,file);
      assert(!fs.existsSync(path.join(f.deploy,'data/knowledge-projection.json')));
      // 此组只验证真实升级的程序复制阶段，不冒充组件启动或索引迁移验收。
    });
  }finally{await f.close();}
  write(path.join(work,'result.json'),{layer:'UNIT/CONTRACT',passed,failed,synthetic_only:true});
  process.stdout.write(JSON.stringify({layer:'UNIT/CONTRACT',passed,failed,synthetic_only:true,evidence:path.relative(project,work)})+'\n');
  if(failed)process.exitCode=1;
}
main().catch(error=>{process.stderr.write(error.stack+'\n');process.exitCode=1;});
