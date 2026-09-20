'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const {spawn,execFileSync} = require('node:child_process');

const root = path.resolve(__dirname, '..');
const sha = file => crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const digest = value => crypto.createHash('sha256').update(value).digest('hex');
const canonical = value => Array.isArray(value) ? '[' + value.map(canonical).join(',') + ']'
  : value && typeof value === 'object' ? '{' + Object.keys(value).sort().map(key => JSON.stringify(key) + ':' + canonical(value[key])).join(',') + '}'
    : JSON.stringify(value);
const resealProjection = value => {
  value.source_components.knowledge = digest(canonical(value.knowledge));
  value.source_sha256 = digest(canonical(value.source_components));
  return value;
};

async function main() {
  const evidenceRoot = path.join(root, '.work', 'v1.3.0');
  fs.mkdirSync(evidenceRoot, {recursive:true});
  const work = fs.mkdtempSync(path.join(evidenceRoot, 'materials-'));
  const deploy = path.join(work, 'deploy');
  for (const directory of ['config','knowledge','tmp','data/runtime','data/anythingllm/documents/custom-documents','data/anythingllm/vector-cache','backups/config-history','bin']) {
    fs.mkdirSync(path.join(deploy, directory), {recursive:true});
  }
  fs.writeFileSync(path.join(deploy,'.crisp-ai-installation'),'ai-support\nstate=ready\n',{mode:0o600});
  fs.writeFileSync(path.join(deploy,'VERSION'),'v1.3.0\n',{mode:0o600});
  for (const name of ['runtime','keyword','handoff','menu','tags','feedback']) {
    const target=path.join(deploy,`config/${name}.yaml`);
    fs.copyFileSync(path.join(root,`config/${name}.yaml.example`),target);
    fs.chmodSync(target,0o640);
  }
  fs.writeFileSync(path.join(deploy,'config/runtime.yaml'),'schema_version: 2\nenabled: true\nrevision: 1\napplied_revision: 0\n',{mode:0o640});
  const initialPrompt='## 虚构客服规则 🙂\n\n只回答测试资料。\n';
  const anythingKey='synthetic-materials-key';
  fs.writeFileSync(path.join(deploy,'config/prompt.md'),initialPrompt,{mode:0o640});
  fs.writeFileSync(path.join(deploy,'knowledge/catalog.json'),JSON.stringify({schema_version:2,revision:1,libraries:[]})+'\n',{mode:0o640});
  fs.writeFileSync(path.join(deploy,'data/knowledge-manifest.json'),JSON.stringify({version:1,files:{},pending_files:{},garbage_locations:[]})+'\n',{mode:0o600});

  let prompt=initialPrompt;
  let locations=[];
  let sequence=0;
  let embeddingFailures=0;
  let promptUpdates=0;
  let promptFailures=0;
  let embeddingUpdates=0;
  const embeddingPayloads=[];
  const removePayloads=[];
  const httpEvents=[];
  let workspaceReads=0;
  let promptDelayMs=0;
  let promptGate=null;
  let failReadAfterNextEmbedding=false;
  let workspaceReadFailureCountdown=0;
  let removeFailures=0;
  let removeFailureAfterDelete=0;
  let removeRequests=0;
  let uploadFailureAfterWrite=0;
  let uploadReplyLostAfterWrite=0;
  let uploadRequests=0;
  const uploadEvents=[];
  let uploadLocationsPerDocument=1;
  let reuseNextLocation=null;
  let applyingObservation=null;
  const documents=new Map();
  const urlNamespace=Buffer.from('6ba7b8119dad11d180b400c04fd430c8','hex');
  const cacheName=location=>{
    const bytes=crypto.createHash('sha1').update(urlNamespace).update(location).digest().subarray(0,16);
    bytes[6]=(bytes[6]&0x0f)|0x50;bytes[8]=(bytes[8]&0x3f)|0x80;
    const hex=bytes.toString('hex');
    return `${hex.slice(0,8)}-${hex.slice(8,12)}-${hex.slice(12,16)}-${hex.slice(16,20)}-${hex.slice(20)}.json`;
  };
  const cachePath=location=>path.join(deploy,'data/anythingllm/vector-cache',cacheName(location));
  const parsedText=location=>JSON.parse(fs.readFileSync(
    path.join(deploy,'data/anythingllm/documents',location),'utf8')).pageContent;
  const server=http.createServer(async(request,response)=>{
    let data=Buffer.alloc(0);
    for await(const chunk of request) data=Buffer.concat([data,chunk]);
    const send=(status,body)=>{response.writeHead(status,{'content-type':'application/json'});response.end(JSON.stringify(body));};
    let body={};
    if(request.headers['content-type']?.includes('application/json')) body=JSON.parse(data.toString('utf8')||'{}');
    if(request.url==='/api/v1/workspace/crisp-support' && request.method==='GET') {
      httpEvents.push('workspace_get');
      workspaceReads++;
      if(workspaceReadFailureCountdown>0&&--workspaceReadFailureCountdown===0){send(500,{error:true});return;}
      send(200,{workspace:[{slug:'crisp-support',openAiPrompt:prompt,documents:locations.map(docpath=>({docpath}))}]});return;
    }
    if(request.url==='/api/v1/workspace/crisp-support/update') {
      const projection=JSON.parse(fs.readFileSync(path.join(deploy,'config/materials-applied.json'),'utf8'));
      applyingObservation={state:projection.state,revision:projection.revision,applied_revision:projection.configuration.runtime.applied_revision};
      if(promptFailures>0){promptFailures--;send(500,{error:true});return;}
      httpEvents.push('prompt_update');promptUpdates++;prompt=body.openAiPrompt;
      if(promptGate!==null) {
        promptGate.entered++;
        promptGate.signal();
        await promptGate.release;
      }
      if(promptDelayMs>0) {
        await new Promise(resolve=>{
          const timer=setTimeout(resolve,promptDelayMs);
          response.once('close',()=>{clearTimeout(timer);resolve();});
        });
        if(response.destroyed) return;
      }
      send(200,{workspace:{slug:'crisp-support',openAiPrompt:prompt}});return;
    }
    if(request.url==='/api/v1/document/upload') {
      assert.equal(request.headers.authorization,`Bearer ${anythingKey}`,'知识上传必须携带内存配置中的虚构认证头');
      const uploadAuthResidues=fs.readdirSync(path.join(deploy,'tmp')).filter(name=>
        name.startsWith('knowledge-curl.')||name.startsWith('materials-retry-curl.'));
      assert.deepEqual(uploadAuthResidues,[],'HTTP请求在途时不得存在含认证的curl配置文件');
      for(const name of fs.readdirSync(path.join(deploy,'tmp'))) {
        const candidate=path.join(deploy,'tmp',name);
        const candidateStat=fs.lstatSync(candidate);
        if(candidateStat.isFile()&&!candidateStat.isSymbolicLink()) {
          assert.equal(fs.readFileSync(candidate).includes(Buffer.from(anythingKey)),false,
            `受管临时文件不得落盘虚构AnythingLLM Key：${name}`);
        }
      }
      uploadRequests++;
      httpEvents.push('upload');
      const raw=data.toString('latin1');
      const match=/filename="([^"]+)"/.exec(raw);
      const filename=match?.[1] || `document-${sequence}`;
      const boundary=/boundary=([^;]+)/.exec(request.headers['content-type']||'')?.[1];
      const contentStart=match?raw.indexOf('\r\n\r\n',match.index)+4:-1;
      const contentEnd=boundary&&contentStart>=4?raw.indexOf(`\r\n--${boundary}`,contentStart):-1;
      if(contentStart<4||contentEnd<contentStart){send(400,{error:true});return;}
      const pageContent=data.subarray(contentStart,contentEnd).toString('utf8');
      uploadEvents.push({filename,pageContent});
      const uploaded=[];
      for(let index=0;index<uploadLocationsPerDocument;index++) {
        const location=index===0&&reuseNextLocation?reuseNextLocation:`custom-documents/${filename}.${++sequence}.json`;
        uploaded.push({location});
        reuseNextLocation=null;
        documents.set(location,{filename,pageContent});
        fs.writeFileSync(path.join(deploy,'data/anythingllm/documents',location),JSON.stringify({pageContent})+'\n',{mode:0o600});
      }
      if(uploadReplyLostAfterWrite>0){uploadReplyLostAfterWrite--;response.destroy();return;}
      if(uploadFailureAfterWrite>0){uploadFailureAfterWrite--;send(500,{error:true,documents:uploaded});return;}
      send(200,{success:true,documents:uploaded});return;
    }
    if(request.url==='/api/v1/workspace/crisp-support/update-embeddings') {
      httpEvents.push('embedding_update');
      embeddingUpdates++;
      embeddingPayloads.push({adds:[...(body.adds||[])],deletes:[...(body.deletes||[])]});
      if(embeddingFailures>0){embeddingFailures--;send(400,{error:true});return;}
      for(const location of body.adds||[]) {
        fs.writeFileSync(cachePath(location),JSON.stringify({location,embedding:[0.1,0.2,0.3]})+'\n',{mode:0o600});
      }
      locations=[...new Set([...locations,...(body.adds||[])])].filter(item=>!(body.deletes||[]).includes(item));
      if(failReadAfterNextEmbedding&&(body.adds||[]).length>0){failReadAfterNextEmbedding=false;workspaceReadFailureCountdown=3;}
      send(200,{success:true});return;
    }
    if(request.url==='/api/v1/system/remove-documents') {
      httpEvents.push('remove_documents');
      removeRequests++;
      removePayloads.push([...(body.names||[])]);
      if(removeFailures>0){removeFailures--;send(500,{error:true});return;}
      for(const name of body.names||[]) {
        documents.delete(name);
        fs.rmSync(path.join(deploy,'data/anythingllm/documents',name),{force:true});
        fs.rmSync(cachePath(name),{force:true});
      }
      if(removeFailureAfterDelete>0){removeFailureAfterDelete--;send(500,{error:true});return;}
      send(200,{success:true});return;
    }
    send(404,{error:true});
  });
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  const port=server.address().port;
  fs.writeFileSync(path.join(deploy,'.env'),`ANYTHINGLLM_API_KEY=${anythingKey}\nANYTHINGLLM_WORKSPACE=crisp-support\nANYTHINGLLM_PORT=${port}\nANYTHINGLLM_EMBED_STATE_WAIT_SECONDS=0\n`,{mode:0o600});
  const readbackFixture=path.join(deploy,'bin/materials-readback-fixture.js');
  fs.writeFileSync(readbackFixture,`'use strict';
const crypto=require('node:crypto'),fs=require('node:fs'),path=require('node:path');
const deploy=process.argv[2];
const digest=value=>crypto.createHash('sha256').update(value).digest('hex');
const canonical=value=>Array.isArray(value)?'['+value.map(canonical).join(',')+']'
  :value&&typeof value==='object'?'{'+Object.keys(value).sort().map(key=>JSON.stringify(key)+':'+canonical(value[key])).join(',')+'}'
    :JSON.stringify(value);
const regular=(file,optional=false)=>{try{const stat=fs.lstatSync(file);if(!stat.isFile()||stat.isSymbolicLink()||stat.size<1)throw new Error('unsafe');return fs.readFileSync(file);}
  catch(error){if(optional&&error.code==='ENOENT')return null;throw error;}};
const raw=regular(path.join(deploy,'config/materials-applied.json'));
const value=JSON.parse(raw.toString('utf8'));
if(value.schema_version!==2||value.state!=='applied')throw new Error('projection');
if(digest(canonical(value.knowledge))!==value.source_components?.knowledge
  ||digest(canonical(value.source_components))!==value.source_sha256)throw new Error('identity');
const base=path.join(deploy,'data/runtime');
const map=regular(path.join(base,'knowledge-map.json'));
const settings=regular(path.join(base,'knowledge-settings.json'));
const lexical=regular(path.join(base,'knowledge-lexical.json'));
const profile=regular(path.join(base,'knowledge-profile.json'),true);
if(digest(map)!==value.knowledge.map_sha256||digest(settings)!==value.knowledge.settings_sha256
  ||digest(lexical)!==value.knowledge.lexical_sha256
  ||(profile===null?'':digest(profile))!==value.knowledge.profile_sha256)throw new Error('runtime knowledge');
const mapValue=JSON.parse(map.toString('utf8')),settingsValue=JSON.parse(settings.toString('utf8'));
const envValue=Object.fromEntries(fs.readFileSync(path.join(deploy,'.env'),'utf8').split(/\\r?\\n/).filter(line=>line&&line.includes('=')&&!line.startsWith('#')).map(line=>{const index=line.indexOf('=');return [line.slice(0,index),line.slice(index+1).replace(/^"|"$/g,'')];}));
if(mapValue.schema_version!==2||!Array.isArray(mapValue.documents)||mapValue.documents.length!==value.knowledge.enabled_document_count)throw new Error('map');
if(settingsValue.schema_version!==1||settingsValue.workspace_slug!==(envValue.ANYTHINGLLM_WORKSPACE||'crisp-support'))throw new Error('settings');
if(profile!==null){const profileValue=JSON.parse(profile.toString('utf8'));if(profileValue.schema_version!==1||profileValue.state!=='applied'
  ||digest(canonical(profileValue.profile))!==profileValue.fingerprint)throw new Error('profile');}
else if(value.knowledge.enabled_document_count>0)throw new Error('profile missing');
process.stdout.write(digest(raw)+':'+value.revision+':ready');
`,{mode:0o600});
  const docker=path.join(deploy,'bin/docker');
  fs.writeFileSync(docker,`#!/usr/bin/env bash\nset -euo pipefail\nif [[ "$*" == *materials-applied.json* ]]; then\n  exec node "${readbackFixture}" "${deploy}"\nfi\nprintf 'fixture不支持请求\\n' >&2\nexit 1\n`,{mode:0o755});

  let passed=0;
  const pass=name=>{passed++;process.stdout.write(`通过 UNIT/CONTRACT：${name}\n`);};
  const invoke=(args,extra={})=>new Promise(resolve=>{
    const child=spawn('bash',[path.join(root,'scripts/materials.sh'),'--deploy-dir',deploy,...args],{
      cwd:work,env:{...process.env,PATH:`${deploy}/bin:${process.env.PATH}`,...extra}
    });
    let stdout='',stderr='';child.stdout.on('data',chunk=>stdout+=chunk);child.stderr.on('data',chunk=>stderr+=chunk);
    child.on('close',code=>resolve({code,stdout,stderr}));
  });
  const delay=milliseconds=>new Promise(resolve=>setTimeout(resolve,milliseconds));
  const externalCounters=()=>({promptUpdates,uploadRequests,embeddingUpdates,removeRequests,workspaceReads});
  const assertNoExternalWrites=(before,label)=>{
    assert.deepEqual({promptUpdates,uploadRequests,embeddingUpdates,removeRequests},{
      promptUpdates:before.promptUpdates,uploadRequests:before.uploadRequests,
      embeddingUpdates:before.embeddingUpdates,removeRequests:before.removeRequests,
    },label);
  };
  const armPromptGate=()=>{
    assert.equal(promptGate,null,'同一时刻只能建立一个 Prompt 响应门');
    let signalEntered,releaseGate;
    const entered=new Promise(resolve=>{signalEntered=resolve;});
    const release=new Promise(resolve=>{releaseGate=resolve;});
    const gate={entered:0,signal:()=>signalEntered(),release,
      close:()=>{releaseGate();if(promptGate===gate)promptGate=null;}};
    promptGate=gate;
    return {gate,entered,close:gate.close};
  };
  const processGroupId=pid=>{
    const value=fs.readFileSync(`/proc/${pid}/stat`,'utf8');
    const close=value.lastIndexOf(') ');
    if(close<0)throw new Error(`无法解析进程状态：${pid}`);
    const suffix=value.slice(close+2).trim().split(/\s+/);
    if(suffix.length<3||!/^\d+$/.test(suffix[2]))throw new Error(`无法读取进程组：${pid}`);
    return Number(suffix[2]);
  };
  const processGroupAlive=pgid=>{
    try { process.kill(-pgid,0);return true; }
    catch(error) { if(error.code==='ESRCH')return false;throw error; }
  };
  const invokeKilledAtMarker=async(args,readyMarker,extra={})=>{
    const ownPgid=processGroupId(process.pid);
    const groupReady=`${readyMarker}.group-ready`;
    const groupGo=`${readyMarker}.group-go`;
    const groupReadyTmp=`${groupReady}.tmp`;
    const groupGoTmp=`${groupGo}.tmp`;
    for(const file of [groupReady,groupGo,groupReadyTmp,groupGoTmp])fs.rmSync(file,{force:true});
    const launcher=[
      'set -euo pipefail',
      'group_ready=$1',
      'group_go=$2',
      'shift 2',
      'umask 077',
      'printf "%s\\n" "$BASHPID" > "${group_ready}.tmp"',
      'mv -f -- "${group_ready}.tmp" "$group_ready"',
      'deadline=$((SECONDS+10))',
      'while [[ ! -f "$group_go" ]]; do',
      '  (( SECONDS < deadline )) || exit 96',
      '  sleep 0.02',
      'done',
      'exec bash "$@"',
    ].join('\n');
    const child=spawn('bash',['-c',launcher,'materials-crash-group',groupReady,groupGo,
      path.join(root,'scripts/materials.sh'),'--deploy-dir',deploy,...args],{
      cwd:work,detached:true,env:{...process.env,PATH:`${deploy}/bin:${process.env.PATH}`,...extra}
    });
    let stdout='',stderr='',closedResult=null,spawnError=null,pgid=null;
    child.stdout.on('data',chunk=>stdout+=chunk);child.stderr.on('data',chunk=>stderr+=chunk);
    const closed=new Promise(resolve=>{
      child.on('error',error=>{spawnError=error;});
      child.on('close',(code,signal)=>{closedResult={code,signal,stdout,stderr};resolve(closedResult);});
    });
    const waitForClose=async(timeout,message)=>{
      const timeoutValue=Symbol('close-timeout');
      const value=await Promise.race([closed,delay(timeout).then(()=>timeoutValue)]);
      if(value===timeoutValue)throw new Error(message);
      return value;
    };
    const killAndDrainGroup=async()=>{
      if(pgid===null||pgid!==child.pid||pgid===ownPgid)throw new Error('拒绝清理未经核验的测试进程组');
      if(processGroupAlive(pgid))process.kill(-pgid,'SIGKILL');
      const result=await waitForClose(3000,`崩溃测试主进程未退出：${child.pid}`);
      const goneDeadline=Date.now()+3000;
      while(processGroupAlive(pgid)&&Date.now()<goneDeadline)await delay(20);
      if(processGroupAlive(pgid)) {
        process.kill(-pgid,'SIGKILL');
        const finalDeadline=Date.now()+1000;
        while(processGroupAlive(pgid)&&Date.now()<finalDeadline)await delay(20);
      }
      if(processGroupAlive(pgid))throw new Error(`崩溃测试进程组未退出：${pgid}`);
      return result;
    };
    try {
      const groupDeadline=Date.now()+3000;
      while(!fs.existsSync(groupReady)) {
        if(closedResult)throw new Error(`隔离进程组尚未就绪，apply 已退出：${JSON.stringify(closedResult)}`);
        if(Date.now()>=groupDeadline)throw new Error('未在时限内建立隔离测试进程组');
        await delay(20);
      }
      if(spawnError)throw spawnError;
      const announcedPid=fs.readFileSync(groupReady,'utf8').trim();
      if(!/^\d+$/.test(announcedPid)||Number(announcedPid)!==child.pid) {
        throw new Error(`隔离进程组身份不一致：child=${child.pid} announced=${announcedPid}`);
      }
      const observedPgid=processGroupId(child.pid);
      if(observedPgid!==child.pid||observedPgid===ownPgid) {
        throw new Error(`拒绝向未隔离进程组发送信号：child=${child.pid} pgrp=${observedPgid} own=${ownPgid}`);
      }
      pgid=observedPgid;
      fs.writeFileSync(groupGoTmp,'go\n',{mode:0o600});
      fs.renameSync(groupGoTmp,groupGo);
      const markerDeadline=Date.now()+20000;
      while(!fs.existsSync(readyMarker)) {
        if(closedResult)throw new Error(`崩溃窗口尚未建立，apply 已退出：${JSON.stringify(closedResult)}`);
        if(Date.now()>=markerDeadline)throw new Error('未在时限内观察到持久上传回执崩溃窗口');
        await delay(20);
      }
      if(spawnError)throw spawnError;
      const result=await killAndDrainGroup();
      return {...result,markerObserved:true,groupGone:true};
    } catch(error) {
      try {
        if(pgid!==null)await killAndDrainGroup();
        else if(!closedResult) {
          child.kill('SIGKILL');
          await waitForClose(3000,`未核验的测试启动进程未退出：${child.pid}`);
          const startupGoneDeadline=Date.now()+1000;
          while(processGroupAlive(child.pid)&&Date.now()<startupGoneDeadline)await delay(20);
          if(processGroupAlive(child.pid))throw new Error(`未核验的测试启动进程组仍存在：${child.pid}`);
        }
      } catch(cleanupError) {
        if(cleanupError.code!=='ESRCH')error.cleanupError=cleanupError.message;
      }
      throw error;
    } finally {
      for(const file of [groupReady,groupGo,groupReadyTmp,groupGoTmp])fs.rmSync(file,{force:true});
    }
  };
  const ok=async(args)=>{const result=await invoke(args);assert.equal(result.code,0,`${args.join(' ')}\n${result.stderr}\n${result.stdout}`);return result;};
  const invokeReadback=()=>new Promise(resolve=>{
    const child=spawn('bash',['-c','source "$1"; materials_projection_readback "$2"','materials-readback',path.join(root,'scripts/materials.sh'),deploy],{
      cwd:work,env:{...process.env,PATH:`${deploy}/bin:${process.env.PATH}`}
    });
    let stdout='',stderr='';child.stdout.on('data',chunk=>stdout+=chunk);child.stderr.on('data',chunk=>stderr+=chunk);
    child.on('close',code=>resolve({code,stdout,stderr}));
  });
  const invokeProjectionValidator=(validator,file)=>new Promise(resolve=>{
    const child=spawn('bash',['-c','source "$1"; if "$2" "$3"; then exit 0; else exit 1; fi',
      'materials-validator',path.join(root,'scripts/materials.sh'),validator,file],{
      cwd:work,env:{...process.env,PATH:`${deploy}/bin:${process.env.PATH}`}
    });
    let stdout='',stderr='';child.stdout.on('data',chunk=>stdout+=chunk);child.stderr.on('data',chunk=>stderr+=chunk);
    child.on('close',code=>resolve({code,stdout,stderr}));
  });
  const invokeCatalogReconcile=(output,semantic)=>new Promise(resolve=>{
    const child=spawn('bash',['-c','source "$1"; if materials_reconcile_catalog "$2" "$3" "$4"; then exit 0; else exit 1; fi',
      'materials-reconcile',path.join(root,'scripts/materials.sh'),deploy,output,semantic],{
      cwd:work,env:{...process.env,PATH:`${deploy}/bin:${process.env.PATH}`}
    });
    let stdout='',stderr='';child.stdout.on('data',chunk=>stdout+=chunk);child.stderr.on('data',chunk=>stderr+=chunk);
    child.on('close',code=>resolve({code,stdout,stderr}));
  });
  const invokeSnapshotValidate=()=>new Promise(resolve=>{
    const child=spawn('bash',['-c','source "$1"; materials_snapshot_validate_generation "$2" "$3" "$4"',
      'materials-snapshot',path.join(root,'scripts/materials.sh'),deploy,
      path.join(deploy,'backups/config-history/materials.applied.tar.gz'),
      path.join(deploy,'config/materials-applied.json')],{
      cwd:work,env:{...process.env,PATH:`${deploy}/bin:${process.env.PATH}`}
    });
    let stdout='',stderr='';child.stdout.on('data',chunk=>stdout+=chunk);child.stderr.on('data',chunk=>stderr+=chunk);
    child.on('close',code=>resolve({code,stdout,stderr}));
  });
  const invokeRecovery=(recovery,args)=>new Promise(resolve=>{
    const child=spawn('python3',['-B',path.join(root,'scripts/materials-recovery.py'),
      '--deploy-dir',deploy,'--recovery',recovery,...args],{cwd:work,env:{...process.env}});
    let stdout='',stderr='';child.stdout.on('data',chunk=>stdout+=chunk);child.stderr.on('data',chunk=>stderr+=chunk);
    child.on('close',code=>resolve({code,stdout,stderr}));
  });
  const assertProjectionArtifacts=async projection=>{
    const files={manifest:'data/knowledge-manifest.json',map:'data/runtime/knowledge-map.json',
      settings:'data/runtime/knowledge-settings.json',profile:'data/runtime/knowledge-profile.json',
      lexical:'data/runtime/knowledge-lexical.json'};
    for(const [key,relative] of Object.entries(files)) {
      const target=path.join(deploy,relative);
      assert.equal(fs.existsSync(target)?sha(target):'',projection.knowledge[`${key}_sha256`],`${key} 摘要`);
    }
    const readback=await invokeReadback();assert.equal(readback.code,0,readback.stderr||readback.stdout);
    const snapshot=await invokeSnapshotValidate();assert.equal(snapshot.code,0,snapshot.stderr||snapshot.stdout);
  };
  const appliedSnapshotPath=path.join(deploy,'backups/config-history/materials.applied.tar.gz');
  const readKnowledgeSettingsSemantic=()=>{
    const value=JSON.parse(fs.readFileSync(path.join(deploy,'data/runtime/knowledge-settings.json'),'utf8'));
    return {schema_version:value.schema_version,workspace_slug:value.workspace_slug,temperature:value.temperature};
  };
  const assertRestoredBusinessGeneration=(restored,baseline,frozenSnapshotSha,baselineLocations,baselineSettings)=>{
    assert.equal(restored.state,'applied');
    assert.equal(restored.revision,baseline.revision+2,
      '普通失败恢复必须只推进候选屏障和恢复投影两个代次');
    assert.notEqual(restored.source_sha256,baseline.source_sha256,
      '从冻结原文重建到新 location 后必须诚实生成新的完整运行代身份');
    for(const key of ['runtime','handoff','keyword','menu','tags','feedback','prompt']) {
      assert.equal(restored.source_components[key],baseline.source_components[key],`${key} 业务源身份`);
    }
    assert.deepEqual(restored.prompt,baseline.prompt);
    for(const key of ['catalog_revision','catalog_sha256','enabled_library_ids','library_count',
      'document_count','enabled_document_count']) {
      assert.deepEqual(restored.knowledge[key],baseline.knowledge[key],`${key} 旧知识语义`);
    }
    assert.notEqual(restored.knowledge.manifest_sha256,baseline.knowledge.manifest_sha256);
    assert.notEqual(restored.knowledge.map_sha256,baseline.knowledge.map_sha256);
    assert.notEqual(restored.knowledge.lexical_sha256,baseline.knowledge.lexical_sha256);
    assert.equal(restored.knowledge.profile_sha256,baseline.knowledge.profile_sha256,
      '恢复必须继续使用冻结的 Embedding profile');
    assert.deepEqual(readKnowledgeSettingsSemantic(),baselineSettings,
      '恢复不得改变知识工作区或温度等非瞬态设置');
    assert.equal(restored.source_components.knowledge,digest(canonical(restored.knowledge)));
    assert.equal(restored.source_sha256,digest(canonical(restored.source_components)));
    assert.equal(sha(appliedSnapshotPath),frozenSnapshotSha,'恢复后必须发布同一份冻结旧原文包');
    assert.equal(locations.length,baselineLocations.length);
    for(const location of baselineLocations) {
      assert.equal(locations.includes(location),false,'旧 location 不得继续绑定工作区');
      assert.equal(documents.has(location),false,'旧 location 不得继续留在上游文档记录');
      assert.equal(fs.existsSync(path.join(deploy,'data/anythingllm/documents',location)),false,
        '旧 location 正文必须已删除');
      assert.equal(fs.existsSync(cachePath(location)),false,'旧 location 向量缓存必须已删除');
    }
    assert.equal(documents.size,locations.length,'不得遗留 workspace 外的候选或旧文档');
  };
  const writeProfile=()=>{
    const value={engine:'native',model:'synthetic-embedding',chunk_size:1000,chunk_overlap:20,
      passage_prefix:'',query_prefix:'',component_version:'synthetic',splitter:'synthetic'};
    const fingerprint=digest(canonical(value));
    const manifestPath=path.join(deploy,'data/knowledge-manifest.json');
    const manifest=JSON.parse(fs.readFileSync(manifestPath,'utf8'));
    assert.equal(manifest.version,1);
    assert.deepEqual(manifest.pending_files||{},{});
    assert.deepEqual(manifest.garbage_locations||[],[]);
    assert.deepEqual(manifest.files||{},{});
    assert.deepEqual(locations,[]);
    manifest.embedding_profile=fingerprint;
    fs.writeFileSync(manifestPath,JSON.stringify(manifest)+'\n',{mode:0o600});
    fs.writeFileSync(path.join(deploy,'data/runtime/knowledge-profile.json'),JSON.stringify({schema_version:1,state:'applied',
      profile:value,fingerprint,applied_at:Date.now()})+'\n',{mode:0o640});
  };
  writeProfile();
  try {
    prompt='## 尚未同步的远端 Prompt\n';
    let result=await invoke(['initialize']);
    assert.notEqual(result.code,0);assert.equal(fs.existsSync(path.join(deploy,'config/materials-applied.json')),false);
    prompt=initialPrompt;
    pass('首份投影必须先确认外部 Prompt 回读一致，不能仅凭本地文件建立');

    const initialized=JSON.parse((await ok(['initialize'])).stdout);
    assert.equal(initialized.state,'applied');
    assert.equal(fs.statSync(path.join(deploy,'config/materials-applied.json')).mode&0o777,0o640);
    assert.ok(fs.existsSync(path.join(deploy,'backups/config-history/materials.applied.tar.gz')));
    const emptyProjection=JSON.parse(fs.readFileSync(path.join(deploy,'config/materials-applied.json')));
    assert.equal(emptyProjection.schema_version,2);
    assert.deepEqual(Object.keys(emptyProjection.source_components).sort(),
      ['feedback','handoff','keyword','knowledge','menu','prompt','runtime','tags']);
    assert.deepEqual(Object.keys(emptyProjection.knowledge).sort(),
      ['catalog_revision','catalog_sha256','document_count','enabled_document_count','enabled_library_ids','lexical_sha256','library_count','manifest_sha256','map_sha256','profile_sha256','settings_sha256']);
    assert.equal(emptyProjection.knowledge.enabled_document_count,0);
    const emptyProfile=path.join(deploy,'data/runtime/knowledge-profile.json');
    if(fs.existsSync(emptyProfile)) {
      const profileValue=JSON.parse(fs.readFileSync(emptyProfile));
      assert.equal(emptyProjection.knowledge.profile_sha256,sha(emptyProfile));
      assert.equal(profileValue.fingerprint,digest(canonical(profileValue.profile)));
    } else assert.equal(emptyProjection.knowledge.profile_sha256,'');
    assert.equal(emptyProjection.source_components.knowledge,digest(canonical(emptyProjection.knowledge)));
    assert.equal(emptyProjection.source_sha256,digest(canonical(emptyProjection.source_components)));
    pass('旧部署经回读建立 schema v2 投影，空知识兼容无 profile 或同代有效 profile 且完整知识身份受保护');

    const validatorRoot=path.join(work,'validator-cases');
    fs.mkdirSync(validatorRoot,{mode:0o700});
    const invalidV2=structuredClone(emptyProjection);
    invalidV2.prompt.sha256='0'.repeat(64);
    const invalidV2Path=path.join(validatorRoot,'invalid-v2.json');
    fs.writeFileSync(invalidV2Path,JSON.stringify(invalidV2)+'\n',{mode:0o600});
    result=await invokeProjectionValidator('materials_projection_validate',invalidV2Path);
    assert.notEqual(result.code,0,'v2 坏 Prompt 摘要在 if 条件调用中不得被后续配置校验覆盖');

    const validLegacy=structuredClone(emptyProjection);
    validLegacy.schema_version=1;
    const legacyPath=path.join(validatorRoot,'legacy.json');
    fs.writeFileSync(legacyPath,JSON.stringify(validLegacy)+'\n',{mode:0o600});
    result=await invokeProjectionValidator('materials_projection_validate_legacy',legacyPath);
    assert.equal(result.code,0,result.stderr||result.stdout);
    validLegacy.prompt.sha256='0'.repeat(64);
    fs.writeFileSync(legacyPath,JSON.stringify(validLegacy)+'\n',{mode:0o600});
    result=await invokeProjectionValidator('materials_projection_validate_legacy',legacyPath);
    assert.notEqual(result.code,0,'legacy 坏 Prompt 摘要在 if 条件调用中不得被后续配置校验覆盖');

    const reconciledCatalog=path.join(validatorRoot,'catalog.json');
    const semanticDirectory=path.join(validatorRoot,'semantic-is-directory');
    fs.mkdirSync(semanticDirectory,{mode:0o700});
    result=await invokeCatalogReconcile(reconciledCatalog,semanticDirectory);
    assert.notEqual(result.code,0,'目录调和的第二个输出失败时不得被第一个有效输出覆盖');
    const reconciledValue=JSON.parse(fs.readFileSync(reconciledCatalog,'utf8'));
    assert.equal(reconciledValue.schema_version,2);
    assert.equal(Array.isArray(reconciledValue.libraries),true);
    assert.equal(fs.statSync(semanticDirectory).isDirectory(),true);
    pass('投影摘要与目录调和在 Bash 条件上下文中显式传播 Python 校验失败');

    const projectionPath=path.join(deploy,'config/materials-applied.json');
    const stableHash=sha(projectionPath);
    fs.writeFileSync(path.join(deploy,'config/prompt.md'),'   \n',{mode:0o640});
    result=await invoke(['apply']);
    assert.notEqual(result.code,0);assert.equal(sha(projectionPath),stableHash);assert.equal(prompt,initialPrompt);
    pass('空白 Prompt 在任何外部调用前被拒绝且旧投影继续生效');
    fs.writeFileSync(path.join(deploy,'config/prompt.md'),initialPrompt,{mode:0o640});

    const handoff=path.join(deploy,'config/handoff.yaml');
    const savedHandoff=fs.readFileSync(handoff);
    fs.writeFileSync(handoff,'handoff:\n  resume_after_seconds: 10\n  resume_after_seconds: 20\n',{mode:0o640});
    result=await invoke(['validate']);
    assert.notEqual(result.code,0);assert.equal(sha(projectionPath),stableHash);
    assert.doesNotMatch(result.stderr,/resume_after_seconds: 10/);
    pass('YAML 重复键与半写候选被拒绝且错误不回显用户正文');
    fs.writeFileSync(handoff,savedHandoff,{mode:0o640});

    const menuPath=path.join(deploy,'config/menu.yaml');
    const savedMenu=fs.readFileSync(menuPath);
    const makeMenu=(optionCount,nodeCount=1)=>{
      const menus={};
      for(let index=0;index<nodeCount;index++) {
        const action=index+1<nodeCount?{type:'menu',target:`node${index+1}`}:{type:'reply',text:'虚构回复'};
        menus[`node${index}`]={title:`第${index}级`,options:{'1':{label:'继续',action}}};
      }
      menus.node0.options=Object.fromEntries(Array.from({length:optionCount},(_,index)=>[String(index+1),{label:`选项${index+1}`,action:index===0&&nodeCount>1?{type:'menu',target:'node1'}:{type:'reply',text:'虚构'}}]));
      return {welcome:{enabled:true,text:'欢迎',trigger:'first_message',auto_open:false},root:'node0',menus};
    };
    fs.writeFileSync(menuPath,JSON.stringify(makeMenu(13))+'\n',{mode:0o640});
    result=await invoke(['validate']);assert.notEqual(result.code,0);
    fs.writeFileSync(menuPath,JSON.stringify(makeMenu(12))+'\n',{mode:0o640});
    await ok(['validate']);
    pass('每个原生 picker 菜单节点最多 12 个选项，边界值可应用而 13 个被拒绝');
    fs.writeFileSync(menuPath,JSON.stringify(makeMenu(1,10))+'\n',{mode:0o640});
    result=await invoke(['validate']);assert.notEqual(result.code,0);
    fs.writeFileSync(menuPath,JSON.stringify(makeMenu(1,9))+'\n',{mode:0o640});
    await ok(['validate']);
    fs.writeFileSync(menuPath,savedMenu,{mode:0o640});
    pass('菜单从根节点最多允许 8 次向下跳转，超一层在保存前被拒绝');

    const changedPrompt='## 新 Prompt 🚀\n\n保留 $ 与反斜线 \\\n';
    fs.writeFileSync(path.join(deploy,'config/prompt.md'),changedPrompt,{mode:0o640});
    result=await invoke(['status']);
    const pending=JSON.parse(result.stdout);assert.equal(pending.pending,true);assert.equal(result.code,2);
    await ok(['apply']);
    const promptProjection=JSON.parse(fs.readFileSync(projectionPath));
    assert.equal(promptProjection.prompt.text,changedPrompt);assert.equal(prompt,changedPrompt);
    assert.equal(applyingObservation.state,'applying');
    assert.ok(applyingObservation.applied_revision<applyingObservation.revision);
    pass('有效直接编辑显示 pending，慢应用先递增 applying 代次再同步并回读');

    const oldAppliedPrompt=prompt;
    const oldRevision=promptProjection.revision;
    const library='kb_1111111111111111';
    const document='doc_2222222222222222';
    const sourceDir=path.join(deploy,'knowledge',library,'sources');fs.mkdirSync(sourceDir,{recursive:true});
    const sourcePath=path.join(sourceDir,`${document}.md`);
    fs.writeFileSync(sourcePath,'# 虚构资料\n失败回滚标记为橙色。\n',{mode:0o640});
    fs.writeFileSync(path.join(deploy,'knowledge/catalog.json'),JSON.stringify({schema_version:2,revision:2,libraries:[{
      id:library,name:'中文 库🙂',enabled:true,revision:1,status:'pending',last_sync:null,error:null,documents:[{
        id:document,name:'中文 空格🙂.md',source:`sources/${document}.md`,projection:`${library}_${document}.md`,sha256:'0'.repeat(64)
      }]
    }]})+'\n',{mode:0o640});
    const failedPrompt='## 等待修复的 Prompt\n';
    fs.writeFileSync(path.join(deploy,'config/prompt.md'),failedPrompt,{mode:0o640});
    embeddingFailures=1;
    result=await invoke(['apply']);
    assert.notEqual(result.code,0);
    const rolledBack=JSON.parse(fs.readFileSync(projectionPath));
    assert.equal(rolledBack.state,'applied');assert.equal(rolledBack.prompt.text,oldAppliedPrompt);
    assert.equal(prompt,oldAppliedPrompt);assert.equal(rolledBack.revision,oldRevision+2);
    assert.equal(fs.readFileSync(path.join(deploy,'config/prompt.md'),'utf8'),failedPrompt);
    for(const name of ['knowledge-map.json','knowledge-settings.json','knowledge-lexical.json']) {
      const restored=path.join(deploy,'data/runtime',name),info=fs.statSync(restored);
      assert.equal(info.mode&0o777,0o640,`${name} 恢复权限`);
      if(typeof process.getuid==='function'&&process.getuid()===0) {assert.equal(info.uid,0);assert.equal(info.gid,1000);}
    }
    assert.equal(sha(path.join(deploy,'data/runtime/knowledge-lexical.json')),rolledBack.knowledge.lexical_sha256);
    const restoredEmptyManifest=JSON.parse(fs.readFileSync(path.join(deploy,'data/knowledge-manifest.json')));
    const restoredEmptyProfile=JSON.parse(fs.readFileSync(path.join(deploy,'data/runtime/knowledge-profile.json')));
    assert.equal(restoredEmptyManifest.embedding_profile,restoredEmptyProfile.fingerprint);
    assert.deepEqual(restoredEmptyManifest.files,{});assert.deepEqual(restoredEmptyManifest.pending_files,{});
    assert.deepEqual(restoredEmptyManifest.garbage_locations,[]);assert.deepEqual(locations,[]);
    assert.equal(fs.existsSync(path.join(deploy,'backups/config-history/materials.recovery')),false);
    await assertProjectionArtifacts(rolledBack);
    assert.equal(JSON.parse((await invoke(['status'])).stdout).pending,true);
    pass('Prompt 已写外部而知识失败时恢复旧外部状态、旧投影以新代次生效且保留待修原文');

    await ok(['apply']);
    const knowledgeApplied=JSON.parse(fs.readFileSync(projectionPath));
    const catalog=JSON.parse(fs.readFileSync(path.join(deploy,'knowledge/catalog.json')));
    assert.equal(catalog.libraries[0].documents[0].sha256,sha(sourcePath));
    assert.equal(knowledgeApplied.knowledge.document_count,1);assert.notEqual(knowledgeApplied.knowledge.map_sha256,'');
    assert.equal(prompt,failedPrompt);
    pass('重试后直接编辑的登记文档哈希、索引 map 与 Prompt 同代生效');

    const nonemptyBaseline=JSON.parse(fs.readFileSync(projectionPath));
    const nonemptyManifest=JSON.parse(fs.readFileSync(path.join(deploy,'data/knowledge-manifest.json')));
    const nonemptyLocations=[...locations];
    const nonemptySnapshotSha=sha(appliedSnapshotPath);
    const nonemptySettings=readKnowledgeSettingsSemantic();
    assert.match(parsedText(nonemptyLocations[0]),/橙色/);
    fs.writeFileSync(sourcePath,'# 虚构资料\n失败回滚标记改为蓝色。\n',{mode:0o640});
    reuseNextLocation=nonemptyLocations[0];
    const reusedLocationPayloadOffset=embeddingPayloads.length;
    embeddingFailures=1;
    result=await invoke(['apply']);assert.notEqual(result.code,0);
    const nonemptyRestored=JSON.parse(fs.readFileSync(projectionPath));
    assert.equal(nonemptyRestored.state,'applied',result.stderr||result.stdout);
    assertRestoredBusinessGeneration(nonemptyRestored,nonemptyBaseline,nonemptySnapshotSha,
      nonemptyLocations,nonemptySettings);
    assert.deepEqual(embeddingPayloads[reusedLocationPayloadOffset],
      {adds:nonemptyLocations,deletes:[]},'复用旧受管 location 仍必须先进入候选索引请求');
    assert.equal(locations.length,1);assert.notDeepEqual(locations,nonemptyLocations);
    assert.match(parsedText(locations[0]),/橙色/);assert.doesNotMatch(parsedText(locations[0]),/蓝色/);
    assert.notDeepEqual(JSON.parse(fs.readFileSync(path.join(deploy,'data/knowledge-manifest.json'))),nonemptyManifest);
    assert.equal(fs.readFileSync(sourcePath,'utf8').includes('蓝色'),true);
    await assertProjectionArtifacts(nonemptyRestored);
    assert.equal(JSON.parse((await invoke(['status'])).stdout).pending,true);
    pass('上游复用旧 location 并覆盖正文时拒绝快速复用，从冻结旧原文重建且待应用原文不被覆盖');

    await ok(['apply']);
    const responseCrashBaseline=JSON.parse(fs.readFileSync(projectionPath));
    const responseCrashLocations=[...locations];
    const responseCrashRecovery=path.join(deploy,'backups/config-history/materials.recovery');
    const responseCrashArm=path.join(work,'kill-after-upload-response.arm');
    const responseCrashReady=path.join(work,'kill-after-upload-response.ready');
    const responseCrashJq=path.join(deploy,'bin/jq');
    const responseCrashFile=path.join(responseCrashRecovery,'upload-response.json');
    const responseCrashRealJq=execFileSync('sh',['-c','command -v jq'],{encoding:'utf8'}).trim();
    fs.writeFileSync(responseCrashArm,'armed\n',{mode:0o600});
    fs.writeFileSync(responseCrashJq,[
      '#!/usr/bin/env bash',
      'set -euo pipefail',
      'umask 077',
      'jq_rc=0',
      `${JSON.stringify(responseCrashRealJq)} "$@" || jq_rc=$?`,
      'saw_filter=false',
      'saw_response=false',
      'for argument in "$@"; do',
      `  [[ "$argument" == '[.documents[]?.location | select(type == "string")] | unique' ]] && saw_filter=true`,
      `  [[ "$argument" == ${JSON.stringify(responseCrashFile)} ]] && saw_response=true`,
      'done',
      `if (( jq_rc == 0 )) && [[ "$saw_filter" == true && "$saw_response" == true && -f ${JSON.stringify(responseCrashArm)} ]]; then`,
      `  rm -f -- ${JSON.stringify(responseCrashArm)}`,
      `  printf 'ready\\n' > ${JSON.stringify(`${responseCrashReady}.tmp`)}`,
      `  chmod 600 ${JSON.stringify(`${responseCrashReady}.tmp`)}`,
      `  mv -f -- ${JSON.stringify(`${responseCrashReady}.tmp`)} ${JSON.stringify(responseCrashReady)}`,
      '  wrapper_pid=$BASHPID',
      '  ( sleep 20; kill -CONT "$wrapper_pid" 2>/dev/null || true ) &',
      '  watchdog_pid=$!',
      '  kill -STOP "$wrapper_pid"',
      '  kill "$watchdog_pid" 2>/dev/null || true',
      '  wait "$watchdog_pid" 2>/dev/null || true',
      '  exit 97',
      'fi',
      'exit "$jq_rc"',
      '',
    ].join('\n'),{mode:0o700});
    reuseNextLocation=responseCrashLocations[0];
    try {
      result=await invokeKilledAtMarker(['apply','--force-knowledge'],responseCrashReady);
      assert.equal(result.code,null,JSON.stringify(result));
      assert.equal(result.signal,'SIGKILL',JSON.stringify(result));
      assert.equal(result.markerObserved,true);assert.equal(result.groupGone,true);
    } finally {
      fs.rmSync(responseCrashJq,{force:true});
      fs.rmSync(responseCrashArm,{force:true});
      fs.rmSync(responseCrashReady,{force:true});
      fs.rmSync(`${responseCrashReady}.tmp`,{force:true});
    }
    assert.equal(fs.existsSync(path.join(responseCrashRecovery,'upload-response.json')),true);
    assert.equal(fs.existsSync(path.join(responseCrashRecovery,'upload-intent.json')),true);
    assert.equal(fs.existsSync(path.join(responseCrashRecovery,'upload-payload')),true);
    assert.equal(fs.existsSync(path.join(responseCrashRecovery,'touched.json')),false,
      '测试必须停在HTTP回执已落盘但恢复账本尚未写入的崩溃窗口');
    assert.deepEqual(fs.readdirSync(path.join(deploy,'tmp')).filter(name=>name.startsWith('knowledge-curl.')),[],
      '持久回执崩溃窗口必须位于含认证curl配置删除之后');
    assert.equal(server.listening,true,'崩溃注入不得终止测试HTTP服务');
    for(const controlFile of [responseCrashJq,responseCrashArm,responseCrashReady,`${responseCrashReady}.tmp`,
      `${responseCrashReady}.group-ready`,`${responseCrashReady}.group-ready.tmp`,
      `${responseCrashReady}.group-go`,`${responseCrashReady}.group-go.tmp`]) {
      assert.equal(fs.existsSync(controlFile),false,`崩溃夹具控制文件残留：${path.basename(controlFile)}`);
    }
    assert.equal(JSON.parse(fs.readFileSync(projectionPath)).state,'applying');
    const responseCrashUploadOffset=uploadRequests;
    await ok(['apply']);
    const responseCrashRecovered=JSON.parse(fs.readFileSync(projectionPath));
    assert.equal(responseCrashRecovered.state,'applied');
    assert.ok(responseCrashRecovered.revision>responseCrashBaseline.revision);
    assert.equal(fs.existsSync(responseCrashRecovery),false);
    assert.equal(uploadRequests,responseCrashUploadOffset+1,
      '重入只能从冻结原文重建一次；不得忽略已持久回执后先重放上传');
    assert.equal(locations.length,1);assert.notDeepEqual(locations,responseCrashLocations);
    assert.match(parsedText(locations[0]),/蓝色/);
    pass('HTTP回执已持久但写恢复账本前崩溃时，重入先核验回执中的旧受管location再恢复且不永久卡住');

    const beforeRebuild=JSON.parse(fs.readFileSync(projectionPath));
    const beforeRebuildLocations=[...locations];
    fs.writeFileSync(sourcePath,'# 虚构资料\n失败回滚标记改为紫色。\n',{mode:0o640});
    failReadAfterNextEmbedding=true;
    result=await invoke(['apply']);assert.notEqual(result.code,0);
    const rebuiltOld=JSON.parse(fs.readFileSync(projectionPath));
    assert.equal(rebuiltOld.state,'applied');assert.equal(rebuiltOld.prompt.text,beforeRebuild.prompt.text);
    assert.equal(rebuiltOld.knowledge.catalog_sha256,beforeRebuild.knowledge.catalog_sha256);
    assert.equal(locations.length,1);assert.notDeepEqual(locations,beforeRebuildLocations);
    const rebuiltManifest=JSON.parse(fs.readFileSync(path.join(deploy,'data/knowledge-manifest.json')));
    assert.deepEqual(rebuiltManifest.pending_files,{});assert.deepEqual(rebuiltManifest.garbage_locations,[]);
    assert.equal(rebuiltManifest.files[`${library}_${document}.md`].locations[0],locations[0]);
    assert.equal(rebuiltManifest.files[`${library}_${document}.md`].cache_bindings[0].location,locations[0]);
    assert.equal(fs.readFileSync(sourcePath,'utf8').includes('紫色'),true);
    assert.match(parsedText(locations[0]),/蓝色/);assert.doesNotMatch(parsedText(locations[0]),/紫色/);
    await assertProjectionArtifacts(rebuiltOld);
    assert.equal(JSON.parse((await invoke(['status'])).stdout).pending,true);
    pass('候选已替换旧 location 后读回失败时，从旧原文在真实根重建并按新 location/cache 生成恢复投影');

    await ok(['apply']);

    const uncertainUploadBaseline=JSON.parse(fs.readFileSync(projectionPath));
    const uncertainUploadLocations=[...locations];
    const uncertainUploadSnapshotSha=sha(appliedSnapshotPath);
    const uncertainUploadSettings=readKnowledgeSettingsSemantic();
    fs.writeFileSync(sourcePath,'# 虚构资料\n失败回滚标记改为青色。\n',{mode:0o640});
    uploadFailureAfterWrite=1;
    result=await invoke(['apply']);assert.notEqual(result.code,0);
    const uncertainUploadRestored=JSON.parse(fs.readFileSync(projectionPath));
    assertRestoredBusinessGeneration(uncertainUploadRestored,uncertainUploadBaseline,
      uncertainUploadSnapshotSha,uncertainUploadLocations,uncertainUploadSettings);
    assert.equal(locations.length,1);assert.equal(documents.size,1);
    assert.match(parsedText(locations[0]),/紫色/);assert.doesNotMatch(parsedText(locations[0]),/青色/);
    assert.equal(fs.existsSync(path.join(deploy,'backups/config-history/materials.recovery')),false);
    await assertProjectionArtifacts(uncertainUploadRestored);
    pass('上传已生成非workspace文档但返回5xx时持久取得location，回滚精确清理后从旧原文重建');

    await ok(['apply']);

    const lostUploadReplyBaseline=JSON.parse(fs.readFileSync(projectionPath));
    const lostUploadReplyLocations=[...locations];
    const lostUploadReplySnapshotSha=sha(appliedSnapshotPath);
    const lostUploadReplySettings=readKnowledgeSettingsSemantic();
    fs.writeFileSync(sourcePath,'# 虚构资料\n上传回执完全丢失后标记改为银色。\n',{mode:0o640});
    uploadReplyLostAfterWrite=1;
    result=await invoke(['apply']);assert.notEqual(result.code,0);
    const lostUploadReplyRestored=JSON.parse(fs.readFileSync(projectionPath));
    assertRestoredBusinessGeneration(lostUploadReplyRestored,lostUploadReplyBaseline,
      lostUploadReplySnapshotSha,lostUploadReplyLocations,lostUploadReplySettings);
    assert.equal(locations.length,1);assert.equal(documents.size,1);
    assert.match(parsedText(locations[0]),/青色/);assert.doesNotMatch(parsedText(locations[0]),/银色/);
    assert.equal(fs.existsSync(path.join(deploy,'backups/config-history/materials.recovery')),false);
    assert.deepEqual(fs.readdirSync(path.join(deploy,'backups/config-history')).filter(name=>name.startsWith('materials.recovery.retired.')),[]);
    await assertProjectionArtifacts(lostUploadReplyRestored);
    pass('上传已写源文档但HTTP回执完全丢失时，按持久上传意图识别受管位置并恢复旧代');

    await ok(['apply']);

    const dispatchCrashBaseline=JSON.parse(fs.readFileSync(projectionPath));
    fs.writeFileSync(sourcePath,'# 虚构资料\n上传发出前崩溃后标记改为金色。\n',{mode:0o640});
    const realCurl=execFileSync('sh',['-c','command -v curl'],{encoding:'utf8'}).trim();
    assert.equal(fs.existsSync(realCurl),true);
    const curlWrapper=path.join(deploy,'bin/curl');
    const dispatchArm=path.join(work,'kill-before-upload-dispatch.arm');
    const dispatchReady=path.join(work,'kill-before-upload-dispatch.ready');
    fs.writeFileSync(dispatchArm,'armed\n',{mode:0o600});
    fs.writeFileSync(curlWrapper,[
      '#!/usr/bin/env bash',
      'set -euo pipefail',
      'umask 077',
      `if [[ " $* " == *"/api/v1/document/upload"* && -f ${JSON.stringify(dispatchArm)} ]]; then`,
      `  rm -f -- ${JSON.stringify(dispatchArm)}`,
      `  printf 'ready\\n' > ${JSON.stringify(`${dispatchReady}.tmp`)}`,
      `  chmod 600 ${JSON.stringify(`${dispatchReady}.tmp`)}`,
      `  mv -f -- ${JSON.stringify(`${dispatchReady}.tmp`)} ${JSON.stringify(dispatchReady)}`,
      '  wrapper_pid=$BASHPID',
      '  ( sleep 20; kill -CONT "$wrapper_pid" 2>/dev/null || true ) &',
      '  watchdog_pid=$!',
      '  kill -STOP "$wrapper_pid"',
      '  kill "$watchdog_pid" 2>/dev/null || true',
      '  wait "$watchdog_pid" 2>/dev/null || true',
      '  exit 97',
      'fi',
      `exec ${JSON.stringify(realCurl)} "$@"`,
      '',
    ].join('\n'),{mode:0o700});
    const dispatchUploadOffset=uploadRequests;
    const dispatchEventOffset=uploadEvents.length;
    try {
      result=await invokeKilledAtMarker(['apply'],dispatchReady);
      assert.equal(result.code,null,JSON.stringify(result));
      assert.equal(result.signal,'SIGKILL',JSON.stringify(result));
      assert.equal(result.markerObserved,true);assert.equal(result.groupGone,true);
    } finally {
      fs.rmSync(curlWrapper,{force:true});
      fs.rmSync(dispatchArm,{force:true});
      fs.rmSync(dispatchReady,{force:true});
      fs.rmSync(`${dispatchReady}.tmp`,{force:true});
    }
    const dispatchRecovery=path.join(deploy,'backups/config-history/materials.recovery');
    assert.equal(uploadRequests,dispatchUploadOffset,'请求发出前崩溃不得到达HTTP fixture');
    assert.equal(fs.existsSync(path.join(dispatchRecovery,'upload-intent.json')),true);
    const dispatchUploadFilename=JSON.parse(
      fs.readFileSync(path.join(dispatchRecovery,'upload-intent.json'),'utf8')).upload_filename;
    assert.match(dispatchUploadFilename,/^crispai-upload-[a-f0-9]{32}\.[A-Za-z0-9]{1,16}$/);
    assert.equal(fs.existsSync(path.join(dispatchRecovery,'upload-payload')),true);
    assert.equal(fs.existsSync(path.join(dispatchRecovery,'upload-response.json')),true);
    assert.equal(fs.statSync(path.join(dispatchRecovery,'upload-response.json')).size,0);
    assert.equal(fs.existsSync(path.join(dispatchRecovery,'touched.json')),false);
    assert.equal(JSON.parse(fs.readFileSync(projectionPath)).state,'applying');
    assert.deepEqual(fs.readdirSync(path.join(deploy,'tmp')).filter(name=>
      name.startsWith('knowledge-curl.')||name.startsWith('materials-retry-curl.')),[],
      '请求发出前崩溃不得遗留含认证的curl配置文件');
    assert.equal(server.listening,true,'请求前崩溃注入不得终止测试HTTP服务');
    for(const controlFile of [curlWrapper,dispatchArm,dispatchReady,`${dispatchReady}.tmp`,
      `${dispatchReady}.group-ready`,`${dispatchReady}.group-ready.tmp`,
      `${dispatchReady}.group-go`,`${dispatchReady}.group-go.tmp`]) {
      assert.equal(fs.existsSync(controlFile),false,`请求前崩溃夹具控制文件残留：${path.basename(controlFile)}`);
    }
    await ok(['apply']);
    const dispatchRecovered=JSON.parse(fs.readFileSync(projectionPath));
    assert.equal(dispatchRecovered.state,'applied');
    assert.notEqual(dispatchRecovered.source_sha256,dispatchCrashBaseline.source_sha256);
    assert.equal(fs.existsSync(dispatchRecovery),false);
    const dispatchEvents=uploadEvents.slice(dispatchEventOffset);
    assert.equal(uploadRequests,dispatchUploadOffset+3,'重入必须严格完成随机alias重放、旧代重建和新候选应用三个阶段');
    assert.equal(dispatchEvents.length,3);
    assert.equal(new Set(dispatchEvents.map(event=>event.filename)).size,3,'三个独立上传阶段必须使用不同随机alias');
    assert.equal(dispatchEvents[0].filename,dispatchUploadFilename,'必须先重放中断前已冻结的上传责任');
    assert.equal(dispatchEvents.filter(event=>event.filename===dispatchUploadFilename).length,1,
      '中断前冻结的上传责任必须且只能重放一次');
    assert.match(dispatchEvents[0].pageContent,/金色/);
    assert.match(dispatchEvents[1].pageContent,/银色/);
    assert.match(dispatchEvents[2].pageContent,/金色/);
    assert.equal(locations.length,1);assert.equal(documents.size,1);
    assert.match(parsedText(locations[0]),/金色/);
    await assertProjectionArtifacts(dispatchRecovered);
    pass('上传意图与正文持久化后进程在发出请求前崩溃，重入只重放该责任并完成同代应用');

    const unknownDeleteBaseline=JSON.parse(fs.readFileSync(projectionPath));
    const unknownDeleteLocations=[...locations];
    const unknownDeleteSnapshotSha=sha(appliedSnapshotPath);
    const unknownDeleteSettings=readKnowledgeSettingsSemantic();
    fs.writeFileSync(sourcePath,'# 虚构资料\n删除回执丢失后标记改为黄色。\n',{mode:0o640});
    embeddingFailures=1;removeFailures=1;removeFailureAfterDelete=1;
    result=await invoke(['apply']);assert.notEqual(result.code,0);
    const unknownDeleteRestored=JSON.parse(fs.readFileSync(projectionPath));
    assertRestoredBusinessGeneration(unknownDeleteRestored,unknownDeleteBaseline,
      unknownDeleteSnapshotSha,unknownDeleteLocations,unknownDeleteSettings);
    assert.equal(locations.length,1);assert.equal(documents.size,1);
    assert.match(parsedText(locations[0]),/金色/);assert.doesNotMatch(parsedText(locations[0]),/黄色/);
    assert.equal(fs.existsSync(path.join(deploy,'backups/config-history/materials.recovery')),false);
    await assertProjectionArtifacts(unknownDeleteRestored);
    pass('源文档删除已完成但HTTP回执丢失时，以受管持久卷缺失证据幂等收口且不遗留孤儿');

    await ok(['apply']);

    const partialBaseline=JSON.parse(fs.readFileSync(projectionPath));
    fs.writeFileSync(sourcePath,'# 虚构资料\n失败恢复后标记改为绿色。\n',{mode:0o640});
    embeddingFailures=1;removeFailures=2;
    result=await invoke(['apply']);assert.notEqual(result.code,0);
    assert.equal(JSON.parse(fs.readFileSync(projectionPath)).state,'applying');
    const recoveryRoot=path.join(deploy,'backups/config-history/materials.recovery');
    assert.equal(fs.existsSync(path.join(recoveryRoot,'cleanup.json')),true);
    assert.equal(fs.existsSync(path.join(recoveryRoot,'touched.json')),true);
    assert.equal(fs.statSync(recoveryRoot).mode&0o777,0o700);
    assert.equal(fs.statSync(path.join(recoveryRoot,'complete.json')).mode&0o777,0o600);
    const outsideProjection=path.join(work,'outside-restored.json');
    let helper=await invokeRecovery(recoveryRoot,['build-projection','--revision','99','--output',outsideProjection]);
    assert.notEqual(helper.code,0);assert.equal(fs.existsSync(outsideProjection),false);
    const frozenProjectionList=path.join(recoveryRoot,'metadata/data/knowledge-projection.json');
    const savedProjectionList=fs.readFileSync(frozenProjectionList);
    fs.writeFileSync(frozenProjectionList,'["synthetic-wrong.md"]\n',{mode:0o600});
    helper=await invokeRecovery(recoveryRoot,['validate']);assert.notEqual(helper.code,0);
    fs.writeFileSync(frozenProjectionList,savedProjectionList,{mode:0o600});
    fs.chmodSync(path.join(recoveryRoot,'complete.json'),0o644);
    helper=await invokeRecovery(recoveryRoot,['validate']);assert.notEqual(helper.code,0);
    fs.chmodSync(path.join(recoveryRoot,'complete.json'),0o600);
    helper=await invokeRecovery(recoveryRoot,['validate']);assert.equal(helper.code,0,helper.stderr);
    const interruptedPayload=path.join(recoveryRoot,'upload-payload');
    fs.writeFileSync(interruptedPayload,'',{mode:0o600});
    helper=await invokeRecovery(recoveryRoot,['cleanup-upload-orphan']);
    assert.equal(helper.code,0,helper.stderr);assert.equal(JSON.parse(helper.stdout).cleaned,true);
    assert.equal(fs.existsSync(interruptedPayload),false);
    const historyRoot=path.dirname(recoveryRoot);
    const siblingOrphans=[
      'materials.recovery.upload-payload.'+'a'.repeat(32),
      'materials.recovery.upload-intent.Ab12Cd34',
      'materials.recovery.touched.Ab12Cd34',
      'materials.recovery.cleanup.Ab12Cd34',
      'materials.applied.tar.gz.tmp.Ab12Cd34',
    ];
    const captureOrphan=path.join(historyRoot,'materials.recovery.Ab12Cd34');
    fs.mkdirSync(captureOrphan,{mode:0o700});
    fs.writeFileSync(path.join(captureOrphan,'partial.json'),'{}\n',{mode:0o600});
    for(const name of siblingOrphans)fs.writeFileSync(path.join(historyRoot,name),'',{mode:0o600});
    helper=await invokeRecovery(recoveryRoot,['cleanup-orphans']);
    assert.equal(helper.code,0,helper.stderr);
    assert.deepEqual(JSON.parse(helper.stdout).removed.sort(),[path.basename(captureOrphan),...siblingOrphans].sort());
    for(const name of [path.basename(captureOrphan),...siblingOrphans])assert.equal(fs.existsSync(path.join(historyRoot,name)),false,name);
    assert.equal(fs.existsSync(recoveryRoot),true);
    helper=await invokeRecovery(recoveryRoot,['validate']);assert.equal(helper.code,0,helper.stderr);
    pass('严格命名、归属和权限均匹配的 SIGKILL 临时对象可安全收口，固定恢复事务及未知外部责任保持不变');
    assert.equal(partialBaseline.state,'applied');
    await ok(['apply']);
    const partialRecovered=JSON.parse(fs.readFileSync(projectionPath));
    assert.equal(partialRecovered.state,'applied');assert.equal(fs.existsSync(recoveryRoot),false);
    assert.equal(locations.length,1);assert.equal(documents.size,1);
    assert.match(parsedText(locations[0]),/绿色/);
    assert.equal(fs.readdirSync(path.join(deploy,'data/anythingllm/documents/custom-documents')).length,1);
    pass('workspace 去嵌入成功而源文档删除失败时持久保留清理责任，重入收口后再应用候选且无孤儿');

    fs.writeFileSync(sourcePath,'# 虚构资料\n同一源文件由解析器返回两个受管位置。\n',{mode:0o640});
    uploadLocationsPerDocument=2;
    try {
      await ok(['apply']);
    } finally {
      uploadLocationsPerDocument=1;
    }
    const multiLocationProjection=JSON.parse(fs.readFileSync(projectionPath));
    const multiLocationMap=JSON.parse(fs.readFileSync(path.join(deploy,'data/runtime/knowledge-map.json')));
    assert.equal(locations.length,2);assert.equal(documents.size,2);
    assert.equal(multiLocationMap.documents.length,2);
    assert.equal(multiLocationProjection.knowledge.enabled_document_count,2);
    await assertProjectionArtifacts(multiLocationProjection);
    pass('一个登记源解析成两个 AnythingLLM location 时，运行计数按 map 位置计算且快照同代门禁通过');

    const settingsPath=path.join(deploy,'data/runtime/knowledge-settings.json');
    const profilePath=path.join(deploy,'data/runtime/knowledge-profile.json');
    const savedIdentity={projection:fs.readFileSync(projectionPath),settings:fs.readFileSync(settingsPath),profile:fs.readFileSync(profilePath)};
    const identityCases=[
      ['workspace错配',()=>{
        const settings=JSON.parse(savedIdentity.settings);settings.workspace_slug='another-synthetic-workspace';
        fs.writeFileSync(settingsPath,JSON.stringify(settings)+'\n',{mode:0o640});
        const projection=JSON.parse(savedIdentity.projection);projection.knowledge.settings_sha256=sha(settingsPath);
        fs.writeFileSync(projectionPath,JSON.stringify(resealProjection(projection))+'\n',{mode:0o640});
      }],
      ['profile正文与fingerprint错配',()=>{
        const profile=JSON.parse(savedIdentity.profile);profile.profile.chunk_size+=1;
        fs.writeFileSync(profilePath,JSON.stringify(profile)+'\n',{mode:0o640});
        const projection=JSON.parse(savedIdentity.projection);projection.knowledge.profile_sha256=sha(profilePath);
        fs.writeFileSync(projectionPath,JSON.stringify(resealProjection(projection))+'\n',{mode:0o640});
      }],
    ];
    for(const [label,mutate] of identityCases) {
      fs.writeFileSync(projectionPath,savedIdentity.projection,{mode:0o640});
      fs.writeFileSync(settingsPath,savedIdentity.settings,{mode:0o640});
      fs.writeFileSync(profilePath,savedIdentity.profile,{mode:0o640});
      mutate();
      result=await invoke(['validate']);assert.notEqual(result.code,0,label+' 的候选校验不得通过');
      result=await invokeReadback();assert.notEqual(result.code,0,label+' 的容器回读不得通过');
    }
    fs.writeFileSync(projectionPath,savedIdentity.projection,{mode:0o640});
    fs.writeFileSync(settingsPath,savedIdentity.settings,{mode:0o640});
    fs.writeFileSync(profilePath,savedIdentity.profile,{mode:0o640});
    const unboundSettings=JSON.parse(savedIdentity.settings);unboundSettings.observed_at+=1;
    fs.writeFileSync(settingsPath,JSON.stringify(unboundSettings)+'\n',{mode:0o640});
    result=await invokeSnapshotValidate();assert.notEqual(result.code,0,
      '快照门禁必须拒绝未写入生效投影摘要的 settings 变化');
    fs.writeFileSync(settingsPath,savedIdentity.settings,{mode:0o640});
    const wrongEnabled=JSON.parse(savedIdentity.projection);
    assert.ok(wrongEnabled.knowledge.enabled_document_count>0);
    wrongEnabled.knowledge.enabled_document_count-=1;
    fs.writeFileSync(projectionPath,JSON.stringify(resealProjection(wrongEnabled))+'\n',{mode:0o640});
    result=await invokeSnapshotValidate();assert.notEqual(result.code,0,
      '即使投影重新自签，enabled_document_count 也必须和实际 map/canonical 一致');
    fs.writeFileSync(projectionPath,savedIdentity.projection,{mode:0o640});
    pass('快照复制后门禁把五项运行知识摘要与投影绑定，并拒绝自签但计数错误的混合代');
    pass('候选与容器回读均拒绝 workspace 错配及 profile 正文/fingerprint 错配，即使外层哈希已重封');

    const orphan=path.join(sourceDir,'doc_3333333333333333.txt');
    fs.writeFileSync(orphan,'未登记孤儿\n',{mode:0o640});
    const beforeOrphan=sha(projectionPath);
    result=await invoke(['apply']);assert.notEqual(result.code,0);assert.equal(sha(projectionPath),beforeOrphan);
    assert.match(result.stderr,/未登记文件/);fs.unlinkSync(orphan);
    pass('sources 孤儿文件不会被静默忽略或进入当前投影');

    const beforeRequests={promptUpdates,embeddingUpdates};
    const runtimePath=path.join(deploy,'config/runtime.yaml');
    const runtime=JSON.parse(fs.readFileSync(runtimePath));runtime.enabled=false;
    fs.writeFileSync(runtimePath,`schema_version: 2\nenabled: false\nrevision: ${runtime.revision}\napplied_revision: ${runtime.applied_revision}\n`,{mode:0o640});
    await ok(['apply']);
    const configApplied=JSON.parse(fs.readFileSync(projectionPath));
    assert.equal(configApplied.configuration.runtime.enabled,false);
    assert.equal(configApplied.configuration.runtime.disable_epoch,1,
      '首次成功应用 true→false 必须递增受管停用代次');
    assert.deepEqual({promptUpdates,embeddingUpdates},beforeRequests);
    assert.equal(configApplied.configuration.runtime.revision,configApplied.revision);
    assert.equal(configApplied.configuration.runtime.applied_revision,configApplied.revision);
    assert.equal(JSON.parse(fs.readFileSync(runtimePath)).enabled,false);
    assert.equal(JSON.parse(fs.readFileSync(runtimePath)).disable_epoch,1);
    pass('合法 YAML runtime 可初始化和应用，配置快路径规范写回且不触发付费模型、Prompt或知识重建');

    const disabledRevision=configApplied.revision;
    const enableRuntime=JSON.parse(fs.readFileSync(runtimePath));enableRuntime.enabled=true;
    fs.writeFileSync(runtimePath,JSON.stringify(enableRuntime)+'\n',{mode:0o640});
    await ok(['apply']);
    const reenabled=JSON.parse(fs.readFileSync(projectionPath));
    assert.equal(reenabled.configuration.runtime.enabled,true);
    assert.equal(reenabled.configuration.runtime.disable_epoch,1,
      '重新启用和其它配置应用不得再次递增停用代次');
    assert(reenabled.revision>disabledRevision);
    pass('客服停用代次只在成功停用边界递增，重新启用保持同一代次');

    const sourceIdentityFiles=[projectionPath,appliedSnapshotPath,
      path.join(deploy,'data/knowledge-manifest.json'),path.join(deploy,'data/knowledge-projection.json'),
      path.join(deploy,'data/runtime/knowledge-map.json'),path.join(deploy,'data/runtime/knowledge-settings.json'),
      path.join(deploy,'data/runtime/knowledge-profile.json'),path.join(deploy,'data/runtime/knowledge-lexical.json')];
    const driftIdentity=Object.fromEntries(sourceIdentityFiles.map(file=>[file,fs.readFileSync(file)]));
    const beforeDrift=externalCounters();
    prompt='## WebUI 漂移的虚构 Prompt\n';
    result=await invoke(['apply']);
    assert.notEqual(result.code,0);assert.match(result.stderr,/外部 Prompt 或受管知识关系.*不一致/);
    assertNoExternalWrites(beforeDrift,'普通 apply 面对外部漂移必须零写失败');
    assert.ok(workspaceReads>beforeDrift.workspaceReads,'普通 apply 必须实际执行外部只读回读');
    for(const [file,content] of Object.entries(driftIdentity))assert.deepEqual(fs.readFileSync(file),content,file);
    assert.equal(fs.existsSync(path.join(deploy,'backups/config-history/materials.recovery')),false);
    pass('普通 apply 面对 Prompt 外部漂移严格回读并零写失败，不再用 changed=false 假成功');

    const beforeForced=externalCounters();
    const forcedResult=await ok(['apply','--force-external']);
    assert.equal(prompt,failedPrompt);
    assert.equal(promptUpdates,beforeForced.promptUpdates+1);
    assert.equal(uploadRequests,beforeForced.uploadRequests);
    assert.equal(embeddingUpdates,beforeForced.embeddingUpdates);
    assert.equal(removeRequests,beforeForced.removeRequests);
    assert.ok(workspaceReads>=beforeForced.workspaceReads+2);
    assert.equal(JSON.parse(forcedResult.stdout).components.knowledge,false);
    assert.equal(JSON.parse(fs.readFileSync(projectionPath)).state,'applied');
    const afterForced=externalCounters();
    await ok(['apply']);
    assertNoExternalWrites(afterForced,'修复后的普通 apply 不得产生外部写');
    pass('显式 force-external 对 Prompt-only 漂移只写一次 Prompt，知识上传、Embedding 和删除均为零');

    let interruptPrompt;
    for(const signals of [['SIGINT'],['SIGTERM'],['SIGINT','SIGTERM']]) {
    const beforeInterrupt=JSON.parse(fs.readFileSync(projectionPath));
    interruptPrompt='## 中断后待恢复的 Prompt '+signals.join('+')+'\n';
    fs.writeFileSync(path.join(deploy,'config/prompt.md'),interruptPrompt,{mode:0o640});
    promptDelayMs=5000;
    const interruptedResult=await new Promise((resolve,reject)=>{
      const child=spawn('bash',[path.join(root,'scripts/materials.sh'),'--deploy-dir',deploy,'apply'],{
        cwd:work,detached:true,env:{...process.env,PATH:`${deploy}/bin:${process.env.PATH}`}
      });
      let stdout='',stderr='',finished=false;
      child.stdout.on('data',chunk=>stdout+=chunk);child.stderr.on('data',chunk=>stderr+=chunk);
      child.on('error',reject);
      child.on('close',(code,signal)=>{finished=true;resolve({code,signal,stdout,stderr});});
      const deadline=Date.now()+5000;
      const observe=()=>{
        if(finished)return;
        try {
          const value=JSON.parse(fs.readFileSync(projectionPath,'utf8'));
          if(value.state==='applying') {
            process.kill(-child.pid,signals[0]);
            if(signals.length>1)setTimeout(()=>{if(!finished){try{process.kill(-child.pid,signals[1]);}catch(error){if(error.code!=='ESRCH')reject(error);}}},35);
            return;
          }
        } catch {}
        if(Date.now()>=deadline) {
          process.kill(-child.pid,'SIGKILL');
          reject(new Error('未观察到 applying，无法执行中断测试'));
          return;
        }
        setTimeout(observe,20);
      };
      observe();
    });
    promptDelayMs=0;
    assert.equal(interruptedResult.code,signals[0]==='SIGINT'?130:143,JSON.stringify({code:interruptedResult.code,signal:interruptedResult.signal})+'\n'+interruptedResult.stderr);
    assert.equal(interruptedResult.signal,null);
    assert.match(interruptedResult.stderr,/资料应用已中断/);
    const afterInterrupt=JSON.parse(fs.readFileSync(projectionPath));
    assert.equal(afterInterrupt.state,'applying');
    assert.ok(afterInterrupt.revision>beforeInterrupt.revision);
    assert.equal(afterInterrupt.prompt.text,beforeInterrupt.prompt.text);
    assert.equal(fs.readFileSync(path.join(deploy,'config/prompt.md'),'utf8'),interruptPrompt);
    assert.equal(fs.readdirSync(path.join(deploy,'tmp')).filter(name=>name.startsWith('materials-result.')).length,0);
    await ok(['apply']);
    assert.equal(prompt,interruptPrompt);
    assert.equal(JSON.parse(fs.readFileSync(projectionPath)).state,'applied');
    }
    pass('真实进程组 SIGINT/SIGTERM/连续信号保持130/143、清理结果文件并以更高代次保持applying，保留候选且重试才解除停发');

    const unconfirmedPrompt='## 外部恢复失败后待重试的 Prompt\n';
    const beforeUnconfirmed=JSON.parse(fs.readFileSync(projectionPath));
    fs.writeFileSync(path.join(deploy,'config/prompt.md'),unconfirmedPrompt,{mode:0o640});
    promptFailures=2;
    result=await invoke(['apply']);assert.notEqual(result.code,0);assert.match(result.stderr,/外部恢复尚未确认/);
    const unconfirmed=JSON.parse(fs.readFileSync(projectionPath));
    assert.equal(unconfirmed.state,'applying');assert.ok(unconfirmed.revision>beforeUnconfirmed.revision);
    assert.equal(unconfirmed.prompt.text,beforeUnconfirmed.prompt.text);
    assert.equal(fs.readFileSync(path.join(deploy,'config/prompt.md'),'utf8'),unconfirmedPrompt);
    await ok(['apply']);assert.equal(prompt,unconfirmedPrompt);assert.equal(JSON.parse(fs.readFileSync(projectionPath)).state,'applied');
    pass('候选失败且旧外部状态无法确认时不假恢复，EXIT 门禁保留更高代次 applying 并支持重试');

    const interrupted=JSON.parse(fs.readFileSync(projectionPath));
    const interruptedAppliedRevision=interrupted.revision;
    interrupted.revision+=1;interrupted.state='applying';
    interrupted.configuration.runtime.revision=interrupted.revision;
    interrupted.configuration.runtime.applied_revision=interruptedAppliedRevision;
    fs.writeFileSync(projectionPath,JSON.stringify(interrupted)+'\n',{mode:0o640});
    result=await invoke(['status']);assert.notEqual(result.code,0);assert.equal(JSON.parse(result.stdout).pending,true);
    const beforeRecovery={promptUpdates,embeddingUpdates};
    await ok(['apply']);
    const recovered=JSON.parse(fs.readFileSync(projectionPath));
    assert.equal(recovered.state,'applied');
    assert.equal(recovered.revision,interrupted.revision+1);
    assert.equal(recovered.configuration.runtime.applied_revision,recovered.revision);
    assert.ok(promptUpdates>beforeRecovery.promptUpdates);assert.ok(embeddingUpdates>beforeRecovery.embeddingUpdates);
    pass('中断遗留 applying 即使原文哈希相同也会重做外部同步与回读后才解除停发');

    const validProjection=fs.readFileSync(projectionPath);
    fs.writeFileSync(projectionPath,'{"schema_version":1',{mode:0o640});
    result=await invoke(['apply']);assert.notEqual(result.code,0);assert.match(result.stderr,/投影损坏/);
    assert.equal(prompt,unconfirmedPrompt);
    fs.writeFileSync(projectionPath,validProjection,{mode:0o640});
    pass('已存在的坏投影 fail-closed，绝不回退读取可编辑原文');

    const duplicateCatalogPath=path.join(deploy,'knowledge/catalog.json');
    const duplicateCatalog=JSON.parse(fs.readFileSync(duplicateCatalogPath));
    const duplicateLibrary='kb_4444444444444444';
    const duplicateSourceDir=path.join(deploy,'knowledge',duplicateLibrary,'sources');
    fs.mkdirSync(duplicateSourceDir,{recursive:true});
    const duplicateSource=path.join(duplicateSourceDir,`${document}.md`);
    fs.writeFileSync(duplicateSource,'# 另一虚构资料库\n跨库可以使用相同稳定文档 ID。\n',{mode:0o640});
    duplicateCatalog.revision+=1;
    duplicateCatalog.libraries.push({
      id:duplicateLibrary,name:'第二个虚构库',enabled:true,revision:1,status:'pending',last_sync:null,error:null,
      documents:[{id:document,name:'跨库同 ID.md',source:`sources/${document}.md`,
        projection:`${duplicateLibrary}_${document}.md`,sha256:'0'.repeat(64)}],
    });
    fs.writeFileSync(duplicateCatalogPath,JSON.stringify(duplicateCatalog)+'\n',{mode:0o640});
    await ok(['apply']);
    const duplicateMap=JSON.parse(fs.readFileSync(path.join(deploy,'data/runtime/knowledge-map.json')));
    const duplicateRows=duplicateMap.documents.filter(row=>row.document_id===document);
    assert.equal(duplicateRows.length,3);
    assert.equal(new Set(duplicateRows.map(row=>row.library_id)).size,2);
    assert.equal(new Set(duplicateRows.map(row=>row.projection)).size,2);
    pass('文档 ID 只要求库内唯一；两个命名库可使用相同 ID，秘密和索引映射仍按稳定库 ID 隔离');

    const repairManifestPath=path.join(deploy,'data/knowledge-manifest.json');
    const repairMapPath=path.join(deploy,'data/runtime/knowledge-map.json');
    const repairManifestBefore=JSON.parse(fs.readFileSync(repairManifestPath));
    const repairEntries=Object.entries(repairManifestBefore.files);
    const singleLocationEntries=repairEntries
      .filter(([,record])=>Array.isArray(record.locations)&&record.locations.length===1);
    assert.ok(singleLocationEntries.length>=1,'定向修复夹具必须包含一个单 location 目标投影');
    const [repairTarget,repairTargetRecord]=singleLocationEntries[0];
    const [repairControl,repairControlRecord]=repairEntries.find(([name])=>name!==repairTarget) || [];
    assert.ok(repairControl&&repairControlRecord,'定向修复夹具必须包含一个不同的 control 投影');
    const repairMissingLocation=repairTargetRecord.locations[0];
    const repairControlRows=JSON.parse(fs.readFileSync(repairMapPath)).documents
      .filter(row=>row.projection===repairControl);
    locations=locations.filter(location=>location!==repairMissingLocation);
    assert.equal(documents.has(repairMissingLocation),true,'missing 负例必须保留原源文档以模拟仅远端解绑');
    assert.equal(fs.existsSync(cachePath(repairMissingLocation)),true,'missing 负例必须保留冻结缓存');
    const repairForeignLocation='custom-documents/external-repair-foreign.json';
    const repairForeignContent='外部修复边界中的虚构管理员资料';
    locations.push(repairForeignLocation);
    documents.set(repairForeignLocation,{filename:'external-repair-foreign.json',pageContent:repairForeignContent});
    fs.writeFileSync(path.join(deploy,'data/anythingllm/documents',repairForeignLocation),
      JSON.stringify({pageContent:repairForeignContent})+'\n',{mode:0o600});
    const canonicalPrompt=fs.readFileSync(path.join(deploy,'config/prompt.md'),'utf8');
    prompt='## 定向修复前的虚构外部漂移\n';
    const repairCounters=externalCounters();
    const repairEmbeddingOffset=embeddingPayloads.length;
    const repairRemoveOffset=removePayloads.length;
    const repairGate=armPromptGate();
    const repairPromise=invoke(['apply','--force-external']);
    let repairInspectionError=null;
    try {
      await Promise.race([repairGate.entered,delay(5000).then(()=>{throw new Error('未在时限内进入 Prompt 修复响应门');})]);
      assert.equal(repairGate.gate.entered,1);
      const repairRecovery=path.join(deploy,'backups/config-history/materials.recovery');
      const completePath=path.join(repairRecovery,'complete.json');
      assert.equal(fs.statSync(repairRecovery).mode&0o777,0o700);
      assert.equal(fs.statSync(completePath).mode&0o777,0o600);
      assert.equal(JSON.parse(fs.readFileSync(projectionPath)).state,'applying');
      const completeBytes=fs.readFileSync(completePath);
      const complete=JSON.parse(completeBytes);
      assert.equal(complete.schema_version,2);assert.equal(complete.capture_mode,'external_repair');
      const managed=[...complete.managed_locations].sort();
      const observed=[...complete.observed_workspace_locations].sort();
      assert.deepEqual(complete.protected_workspace_locations,[...new Set([...managed,...observed])].sort());
      assert.deepEqual(complete.deletable_managed_locations,managed.filter(item=>observed.includes(item)));
      assert.deepEqual(complete.missing_managed_locations,managed.filter(item=>!observed.includes(item)));
      assert.deepEqual(complete.missing_managed_locations,[repairMissingLocation]);
      assert.ok(complete.observed_workspace_locations.includes(repairForeignLocation));
      assert.equal(complete.managed_locations.includes(repairForeignLocation),false);
      const repairScopeResult=await invokeRecovery(repairRecovery,['repair-scope']);
      assert.equal(repairScopeResult.code,0,repairScopeResult.stderr);
      const repairScope=JSON.parse(repairScopeResult.stdout);
      assert.deepEqual(repairScope.projections.map(item=>item.projection),[repairTarget]);
      assert.deepEqual(repairScope.projections[0].missing_locations,[repairMissingLocation]);
      assert.equal(repairScope.projections.some(item=>item.projection===repairControl),false);
      const tampered=[
        value=>({...value,capture_mode:'unknown'}),
        value=>({...value,protected_workspace_locations:[...value.protected_workspace_locations,'custom-documents/tamper.json'].sort()}),
        value=>({...value,missing_managed_locations:[]}),
        value=>({...value,deletable_managed_locations:[...value.deletable_managed_locations,repairMissingLocation].sort()}),
        value=>({...value,observed_workspace_locations:[...value.observed_workspace_locations,value.observed_workspace_locations[0]]}),
        value=>({...value,unexpected_field:true}),
      ];
      for(const mutate of tampered) {
        fs.writeFileSync(completePath,JSON.stringify(mutate(structuredClone(complete)))+'\n',{mode:0o600});
        const rejected=await invokeRecovery(repairRecovery,['validate']);
        assert.notEqual(rejected.code,0,'篡改的 schema v2 恢复清单必须被拒绝');
        fs.writeFileSync(completePath,completeBytes,{mode:0o600});
      }
      const restoredValidation=await invokeRecovery(repairRecovery,['validate']);
      assert.equal(restoredValidation.code,0,restoredValidation.stderr);
      // capture 已完成后才让同字符串位置重新出现在 workspace。它可能已由
      // 管理员或第三方接管；旧 manifest 只能保护它，不能重新取得删除权。
      locations.push(repairMissingLocation);
      assert.equal(locations.includes(repairMissingLocation),true);
    } catch(error) {
      repairInspectionError=error;
    } finally {
      repairGate.close();
    }
    result=await repairPromise;
    if(repairInspectionError!==null)throw repairInspectionError;
    assert.equal(result.code,0,result.stderr||result.stdout);
    assert.equal(prompt,canonicalPrompt);
    assert.equal(promptUpdates,repairCounters.promptUpdates+1);
    assert.equal(uploadRequests,repairCounters.uploadRequests+1);
    assert.equal(embeddingUpdates,repairCounters.embeddingUpdates+1);
    assert.equal(removeRequests,repairCounters.removeRequests);
    const repairManifestAfter=JSON.parse(fs.readFileSync(repairManifestPath));
    assert.notDeepEqual(repairManifestAfter.files[repairTarget].locations,[repairMissingLocation]);
    assert.deepEqual(repairManifestAfter.files[repairControl],repairControlRecord);
    assert.deepEqual(JSON.parse(fs.readFileSync(repairMapPath)).documents.filter(row=>row.projection===repairControl),repairControlRows);
    assert.equal(fs.existsSync(path.join(deploy,'data/anythingllm/documents',repairMissingLocation)),true);
    assert.equal(locations.includes(repairMissingLocation),true,
      'capture 后同字符串重现的位置必须保留为非受管 workspace 成员');
    assert.equal(fs.existsSync(path.join(deploy,'data/anythingllm/documents',repairForeignLocation)),true);
    assert.equal(locations.includes(repairForeignLocation),true);
    for(const payload of embeddingPayloads.slice(repairEmbeddingOffset)) {
      assert.equal(payload.deletes.includes(repairMissingLocation),false);
      assert.equal(payload.deletes.includes(repairForeignLocation),false);
    }
    for(const payload of removePayloads.slice(repairRemoveOffset)) {
      assert.equal(payload.includes(repairMissingLocation),false);
      assert.equal(payload.includes(repairForeignLocation),false);
    }
    assert.equal(fs.existsSync(path.join(deploy,'backups/config-history/materials.recovery')),false);
    await assertProjectionArtifacts(JSON.parse(fs.readFileSync(projectionPath)));
    pass('schema v2 定向重建唯一 missing 投影，control 与外来位置保持不变且无越权删除');

    const failedRepairBaseline=JSON.parse(fs.readFileSync(projectionPath));
    const failedRepairSnapshotSha=sha(appliedSnapshotPath);
    const failedRepairManifest=JSON.parse(fs.readFileSync(repairManifestPath));
    const failedRepairTargetLocation=failedRepairManifest.files[repairTarget].locations[0];
    locations=locations.filter(location=>location!==failedRepairTargetLocation);
    assert.equal(documents.has(failedRepairTargetLocation),true);
    prompt='## 知识失败恢复前的虚构外部漂移\n';
    const failedRepairCounters=externalCounters();
    const failedRepairEmbeddingOffset=embeddingPayloads.length;
    const failedRepairRemoveOffset=removePayloads.length;
    const failedRepairEventOffset=httpEvents.length;
    const failedRepairUploadOffset=uploadEvents.length;
    const enabledProjectionCount=Object.keys(failedRepairManifest.files).length;
    const enabledProjectionContents=Object.keys(failedRepairManifest.files).sort()
      .map(name=>fs.readFileSync(path.join(deploy,'knowledge',name),'utf8')).sort();
    const failedRepairTargetContent=fs.readFileSync(path.join(deploy,'knowledge',repairTarget),'utf8');
    embeddingFailures=1;
    const failedRepairGate=armPromptGate();
    const failedRepairPromise=invoke(['apply','--force-external']);
    let failedRepairInspectionError=null;
    try {
      await Promise.race([failedRepairGate.entered,delay(5000).then(()=>{throw new Error('未在时限内进入失败恢复 Prompt 门');})]);
      assert.equal(failedRepairGate.gate.entered,1);
      locations.push(failedRepairTargetLocation);
      assert.equal(locations.includes(failedRepairTargetLocation),true);
    } catch(error) {
      failedRepairInspectionError=error;
    } finally {
      failedRepairGate.close();
    }
    result=await failedRepairPromise;
    if(failedRepairInspectionError!==null)throw failedRepairInspectionError;
    assert.notEqual(result.code,0,'修复阶段知识失败后即使旧代恢复成功，本次 apply 仍须返回失败');
    const failedRepairRestored=JSON.parse(fs.readFileSync(projectionPath));
    assert.equal(failedRepairRestored.state,'applied');
    assert.equal(failedRepairRestored.revision,failedRepairBaseline.revision+2);
    assert.equal(prompt,canonicalPrompt);
    assert.equal(promptUpdates,failedRepairCounters.promptUpdates+2);
    assert.equal(uploadRequests,failedRepairCounters.uploadRequests+1+enabledProjectionCount);
    const failedRepairUploads=uploadEvents.slice(failedRepairUploadOffset);
    assert.equal(failedRepairUploads.length,1+enabledProjectionCount);
    assert.equal(failedRepairUploads[0].pageContent,failedRepairTargetContent,
      '修复阶段唯一上传必须对应 missing target');
    assert.deepEqual(failedRepairUploads.slice(1).map(event=>event.pageContent).sort(),enabledProjectionContents,
      '恢复阶段必须把每个 canonical projection 恰好重建一次');
    assert.equal(new Set(failedRepairUploads.map(event=>event.filename)).size,failedRepairUploads.length,
      '修复与恢复的每次上传必须使用不同随机 alias');
    const failedRepairEvents=httpEvents.slice(failedRepairEventOffset);
    assert.equal(failedRepairEvents[0],'workspace_get');
    assert.ok(failedRepairEvents.indexOf('prompt_update')>=0);
    assert.ok(failedRepairEvents.indexOf('prompt_update')<failedRepairEvents.indexOf('upload'));
    assert.equal(sha(appliedSnapshotPath),failedRepairSnapshotSha);
    assert.equal(fs.readFileSync(path.join(deploy,'config/prompt.md'),'utf8'),canonicalPrompt);
    for(const payload of embeddingPayloads.slice(failedRepairEmbeddingOffset)) {
      assert.equal(payload.deletes.includes(failedRepairTargetLocation),false);
      assert.equal(payload.deletes.includes(repairForeignLocation),false);
    }
    for(const payload of removePayloads.slice(failedRepairRemoveOffset)) {
      assert.equal(payload.includes(failedRepairTargetLocation),false);
      assert.equal(payload.includes(repairForeignLocation),false);
    }
    assert.equal(fs.existsSync(path.join(deploy,'data/anythingllm/documents',failedRepairTargetLocation)),true);
    assert.equal(locations.includes(failedRepairTargetLocation),true,
      '失败恢复也不得删除 capture 后重现的 missing 同字符串位置');
    assert.equal(fs.existsSync(path.join(deploy,'data/anythingllm/documents',repairForeignLocation)),true);
    assert.equal(locations.includes(repairForeignLocation),true);
    assert.equal(fs.existsSync(path.join(deploy,'backups/config-history/materials.recovery')),false);
    await assertProjectionArtifacts(failedRepairRestored);
    pass('Prompt 修复成功后知识失败会恢复冻结 canonical，missing 与外来同名位置始终不获删除权');

    const bytesResult=await new Promise(resolve=>{
      const child=spawn('bash',['-c','source scripts/knowledge.sh; knowledge_utf8_bytes 人工客服'],{cwd:root});
      let stdout='';child.stdout.on('data',chunk=>stdout+=chunk);child.on('close',code=>resolve({code,stdout}));
    });
    assert.equal(bytesResult.code,0);assert.equal(bytesResult.stdout.trim(),'12');
    pass('字符串限制明确按 UTF-8 字节计算（人工客服为12字节）');

    const finalStatus=JSON.parse((await invoke(['status'])).stdout);
    assert.equal(finalStatus.source_valid,true);assert.equal(finalStatus.projection_valid,true);
    assert.ok(!JSON.stringify(finalStatus).includes('虚构资料'));
    pass('状态只返回哈希、revision与稳定路径，不输出用户正文或秘密');

    const foreignLocation='custom-documents/admin-owned.json';
    const foreignContent='不属于本项目资料代的虚构管理员正文';
    locations.push(foreignLocation);
    documents.set(foreignLocation,{filename:'admin-owned.json',pageContent:foreignContent});
    fs.writeFileSync(path.join(deploy,'data/anythingllm/documents',foreignLocation),
      JSON.stringify({pageContent:foreignContent})+'\n',{mode:0o600});
    const foreignRemoveOffset=removeRequests;
    fs.writeFileSync(sourcePath,'# 虚构资料\n外来位置授权边界候选。\n',{mode:0o640});
    uploadLocationsPerDocument=2;
    reuseNextLocation=foreignLocation;
    result=await invoke(['apply']);assert.notEqual(result.code,0);
    const foreignRecovery=path.join(deploy,'backups/config-history/materials.recovery');
    const foreignClaims=JSON.parse(fs.readFileSync(path.join(foreignRecovery,'upload-response.json'))).documents
      .map(item=>item.location);
    assert.equal(foreignClaims.length,2);
    assert.equal(foreignClaims.includes(foreignLocation),true);
    assert.equal(foreignClaims.some(item=>item!==foreignLocation),true);
    assert.equal(JSON.parse(fs.readFileSync(projectionPath)).state,'applying');
    assert.equal(fs.existsSync(path.join(foreignRecovery,'upload-response.json')),true);
    assert.equal(fs.existsSync(path.join(foreignRecovery,'upload-intent.json')),true);
    assert.equal(fs.existsSync(path.join(foreignRecovery,'touched.json')),false);
    assert.equal(removeRequests,foreignRemoveOffset,'外来workspace位置不得进入删除调用');
    assert.equal(fs.existsSync(path.join(deploy,'data/anythingllm/documents',foreignLocation)),true);
    assert.equal(locations.includes(foreignLocation),true);
    assert.match(result.stderr,/外部恢复尚未确认/);
    pass('HTTP声称复用外来workspace位置时保持fail-closed且不登记、不删除该位置');
    process.stdout.write(JSON.stringify({layer:'UNIT/CONTRACT',passed,failed:0,evidence:path.relative(root,work)})+'\n');
  } finally {
    server.closeAllConnections();
    await new Promise(resolve=>server.close(resolve));
  }
}

main().catch(error=>{console.error(error);process.exitCode=1;});
