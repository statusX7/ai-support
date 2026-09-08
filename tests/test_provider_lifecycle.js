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
const baseWork = path.join(project, '.work/v1.2.1');
fs.mkdirSync(baseWork, {recursive:true});
const work = fs.mkdtempSync(path.join(baseWork, 'provider-lifecycle-'));
const read = file => JSON.parse(fs.readFileSync(file, 'utf8'));
const write = (file, value) => fs.writeFileSync(file, typeof value === 'string' ? value : JSON.stringify(value), {mode:0o600});
const digest = value => crypto.createHash('sha256').update(value).digest('hex');
const command = (program, args, options = {}) => new Promise((resolve, reject) => {
  const child = spawn(program, args, {cwd:work, env:{...process.env,...options.env}, stdio:['pipe','pipe','pipe']});
  let stdout='', stderr='';
  child.stdout.on('data', chunk => stdout += chunk); child.stderr.on('data', chunk => stderr += chunk);
  child.on('error', reject); child.on('close', code => resolve({code,stdout,stderr})); child.stdin.end(options.input || '');
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
  write(path.join(deploy,'VERSION'),'v1.2.1\n');
  write(path.join(deploy,'.crisp-ai-installation'),'ai-support\nstate=local-ready\nsource='+project+'\ninstalled_version=v1.2.1\n');
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
    await test('PL08 本机完整快照包含同代secret/router并保持受限权限',async()=>{
      await f.ok('logs.sh',['initialize','--profile','new'],f.snapshotEnv);
      write(path.join(f.deploy,'data/provider-router/synthetic-preserved.json'),{synthetic:true,state:'旧路由状态必须成套恢复'});
      const result=await f.ok('snapshot.sh',['--quiet','--reason','synthetic-provider-lifecycle'],f.snapshotEnv);const id=result.stdout.trim();
      fullSnapshot=path.join(f.deploy,'backups/versions',id);const archive=path.join(fullSnapshot,'snapshot.tar.gz');
      assert.equal(fs.statSync(archive).mode&0o777,0o600);const directory=path.join(work,'snapshot-extracted');fs.mkdirSync(directory);await checked('tar',['-xzf',archive,'-C',directory]);
      const payload=path.join(directory,'payload'),pool=read(path.join(payload,'config/provider-pool-applied.json'));
      assert.deepEqual(pool,f.pool());assert.deepEqual(read(path.join(payload,'secrets/provider/generations',pool.secrets_generation+'.json')).entries,f.secretEntries());
      assert.deepEqual(fs.readFileSync(path.join(payload,'data/provider-router/synthetic-preserved.json')),fs.readFileSync(path.join(f.deploy,'data/provider-router/synthetic-preserved.json')));
      for(const name of ['provider-router.js','provider-envelope.js','provider-pool.py'])assert.deepEqual(fs.readFileSync(path.join(payload,'scripts',name)),fs.readFileSync(path.join(f.deploy,'scripts',name)));
      assert.deepEqual(fs.readFileSync(path.join(payload,'.env')),fs.readFileSync(path.join(f.deploy,'.env')));
      assert.match(fs.readFileSync(f.snapshotEnv.MOCK_DOCKER_LOG,'utf8'),/stop .*provider-adapter/);
    });
    await test('PL09 缺秘密代次的自洽快照在停服务前拒绝，不留下混合恢复',async()=>{
      const stage=path.join(work,'broken-snapshot');fs.mkdirSync(stage);await checked('tar',['-xzf',path.join(fullSnapshot,'snapshot.tar.gz'),'-C',stage]);
      const pool=read(path.join(stage,'payload/config/provider-pool-applied.json'));fs.unlinkSync(path.join(stage,'payload/secrets/provider/generations',pool.secrets_generation+'.json'));
      const id='synthetic-broken-provider',directory=path.join(f.deploy,'backups/versions',id);fs.mkdirSync(directory);const archive=path.join(directory,'snapshot.tar.gz');await checked('tar',['-czf',archive,'-C',stage,'payload']);
      write(path.join(directory,'manifest.json'),{...read(path.join(fullSnapshot,'manifest.json')),id,archive_sha256:digest(fs.readFileSync(archive))});
      const before=f.capture();write(f.snapshotEnv.MOCK_DOCKER_LOG,'');const result=await f.invoke('rollback.sh',['--snapshot',id,'--no-safety-snapshot'],f.snapshotEnv);
      assert.notEqual(result.code,0);assert.match(result.stderr,/接口池与秘密代次不完整/);assert.deepEqual(f.capture(),before);assert(!/\bstop\b/.test(fs.readFileSync(f.snapshotEnv.MOCK_DOCKER_LOG,'utf8')));
    });
    await test('PL10 真实v1.1.0快照恢复旧程序配置，主备秘密与router受限成套保留',async()=>{
      const legacy=path.join(work,'legacy-v110'),sourceArchive=path.join(work,'legacy-source.tar');fs.mkdirSync(legacy);
      await checked('git',['-C',project,'archive','--format=tar','--output',sourceArchive,'v1.1.0']);await checked('tar',['-xf',sourceArchive,'-C',legacy]);
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
      write(path.join(f.deploy,'data/runtime/synthetic-current-only.json'),{synthetic:true,version:'v1.2.1'});
      write(f.snapshotEnv.MOCK_DOCKER_LOG,'');write(f.snapshotEnv.MOCK_DOCKER_SERVICE_STATE,'postgres\nanythingllm\nn8n\nprovider-adapter\n');
      f.adapter.closeAllConnections();await new Promise(resolve=>f.adapter.close(resolve));f.adapter=null;
      const result=await f.invoke('rollback.sh',['--snapshot',id,'--no-safety-snapshot'],legacyEnv);
      write(path.join(work,'legacy-rollback.log'),result.stdout+result.stderr);assert.equal(result.code,0,result.stdout+result.stderr);
      for(const name of ['VERSION','install.sh','manage.sh','scripts/common.sh','scripts/provider.sh','n8n/runtime.js'])assert.deepEqual(fs.readFileSync(path.join(f.deploy,name)),fs.readFileSync(path.join(legacy,name)));
      for(const name of ['provider-router.js','provider-envelope.js','provider-pool.py','menu-display.py','menu-provider-ui.sh'])assert(!fs.existsSync(path.join(f.deploy,'scripts',name)));
      assert(!fs.existsSync(path.join(f.deploy,'config/provider-pool-applied.json')));assert(!fs.existsSync(path.join(f.deploy,'config/provider-pool.yaml')));
      assert(!fs.existsSync(path.join(f.deploy,'secrets')));assert(!fs.existsSync(path.join(f.deploy,'data/provider-router')));
      assert(!fs.readFileSync(path.join(f.deploy,'.env'),'utf8').includes('PROVIDER_POOL_REQUIRED'));
      assert.deepEqual(read(path.join(f.deploy,'data/runtime/synthetic-legacy.json')),{synthetic:true,mode:'human',generation:7});assert(!fs.existsSync(path.join(f.deploy,'data/runtime/synthetic-current-only.json')));
      const kept=fs.readdirSync(path.join(f.deploy,'backups')).filter(name=>name.startsWith('provider-pre-rollback.')).map(name=>path.join(f.deploy,'backups',name));
      assert.equal(kept.length,2);assert(kept.every(directory=>(fs.statSync(directory).mode&0o777)===0o700));
      const retainedSecret=kept.map(directory=>path.join(directory,'secrets/provider/generations',previous.secrets_generation+'.json')).find(file=>fs.existsSync(file));assert.deepEqual(read(retainedSecret).entries,previousSecret);
      const retainedRouter=kept.map(directory=>path.join(directory,'provider-router/synthetic-preserved.json')).find(file=>fs.existsSync(file));assert.deepEqual(fs.readFileSync(retainedRouter),newRouter);
      const docker=fs.readFileSync(f.snapshotEnv.MOCK_DOCKER_LOG,'utf8');assert.match(docker,/pg_restore/);assert.match(docker,/--force-recreate anythingllm/);assert.equal(fs.readFileSync(legacyEnv.MOCK_POSTGRES_PASSWORD_DIGEST_FILE,'utf8').trim(),digest('synthetic-lifecycle-database-password'));
    });
  }finally{await f.close();}
  write(path.join(work,'result.json'),{layer:'UNIT/CONTRACT',passed,failed,synthetic_only:true});
  process.stdout.write(JSON.stringify({layer:'UNIT/CONTRACT',passed,failed,synthetic_only:true,evidence:path.relative(project,work)})+'\n');
  if(failed)process.exitCode=1;
}
main().catch(error=>{process.stderr.write(error.stack+'\n');process.exitCode=1;});
