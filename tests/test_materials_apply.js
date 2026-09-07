'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const {spawn} = require('node:child_process');

const root = path.resolve(__dirname, '..');
const sha = file => crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');

async function main() {
  const evidenceRoot = path.join(root, '.work', 'v1.2.0');
  fs.mkdirSync(evidenceRoot, {recursive:true});
  const work = fs.mkdtempSync(path.join(evidenceRoot, 'materials-'));
  const deploy = path.join(work, 'deploy');
  for (const directory of ['config','knowledge','tmp','data/runtime','backups/config-history','bin']) {
    fs.mkdirSync(path.join(deploy, directory), {recursive:true});
  }
  fs.writeFileSync(path.join(deploy,'.crisp-ai-installation'),'ai-support\nstate=ready\n',{mode:0o600});
  fs.writeFileSync(path.join(deploy,'VERSION'),'v1.2.0\n',{mode:0o600});
  for (const name of ['runtime','keyword','handoff','menu','tags','feedback']) {
    const target=path.join(deploy,`config/${name}.yaml`);
    fs.copyFileSync(path.join(root,`config/${name}.yaml.example`),target);
    fs.chmodSync(target,0o640);
  }
  fs.writeFileSync(path.join(deploy,'config/runtime.yaml'),'schema_version: 2\nenabled: true\nrevision: 1\napplied_revision: 0\n',{mode:0o640});
  const initialPrompt='## 虚构客服规则 🙂\n\n只回答测试资料。\n';
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
  let workspaceReads=0;
  let promptDelayMs=0;
  let applyingObservation=null;
  const documents=new Map();
  const server=http.createServer(async(request,response)=>{
    let data=Buffer.alloc(0);
    for await(const chunk of request) data=Buffer.concat([data,chunk]);
    const send=(status,body)=>{response.writeHead(status,{'content-type':'application/json'});response.end(JSON.stringify(body));};
    let body={};
    if(request.headers['content-type']?.includes('application/json')) body=JSON.parse(data.toString('utf8')||'{}');
    if(request.url==='/api/v1/workspace/crisp-support' && request.method==='GET') {
      workspaceReads++;
      send(200,{workspace:[{slug:'crisp-support',openAiPrompt:prompt,documents:locations.map(docpath=>({docpath}))}]});return;
    }
    if(request.url==='/api/v1/workspace/crisp-support/update') {
      const projection=JSON.parse(fs.readFileSync(path.join(deploy,'config/materials-applied.json'),'utf8'));
      applyingObservation={state:projection.state,revision:projection.revision,applied_revision:projection.configuration.runtime.applied_revision};
      if(promptFailures>0){promptFailures--;send(500,{error:true});return;}
      promptUpdates++;prompt=body.openAiPrompt;
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
      const filename=/filename="([^"]+)"/.exec(data.toString('latin1'))?.[1] || `document-${sequence}`;
      const location=`custom-documents/${filename}.${++sequence}.json`;
      documents.set(location,{filename});send(200,{success:true,documents:[{location}]});return;
    }
    if(request.url==='/api/v1/workspace/crisp-support/update-embeddings') {
      embeddingUpdates++;
      if(embeddingFailures>0){embeddingFailures--;send(400,{error:true});return;}
      locations=[...new Set([...locations,...(body.adds||[])])].filter(item=>!(body.deletes||[]).includes(item));
      send(200,{success:true});return;
    }
    if(request.url==='/api/v1/system/remove-documents') {
      for(const name of body.names||[]) documents.delete(name);
      send(200,{success:true});return;
    }
    send(404,{error:true});
  });
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  const port=server.address().port;
  fs.writeFileSync(path.join(deploy,'.env'),`ANYTHINGLLM_API_KEY=synthetic-materials-key\nANYTHINGLLM_WORKSPACE=crisp-support\nANYTHINGLLM_PORT=${port}\nANYTHINGLLM_EMBED_STATE_WAIT_SECONDS=0\n`,{mode:0o600});
  const docker=path.join(deploy,'bin/docker');
  fs.writeFileSync(docker,`#!/usr/bin/env bash\nset -euo pipefail\nif [[ "$*" == *materials-applied.json* ]]; then sha256sum -- "${deploy}/config/materials-applied.json" | awk '{printf "%s",$1}'; exit 0; fi\nprintf 'fixture不支持请求\\n' >&2; exit 1\n`,{mode:0o755});

  let passed=0;
  const pass=name=>{passed++;process.stdout.write(`通过 UNIT/CONTRACT：${name}\n`);};
  const invoke=(args,extra={})=>new Promise(resolve=>{
    const child=spawn('bash',[path.join(root,'scripts/materials.sh'),'--deploy-dir',deploy,...args],{
      cwd:work,env:{...process.env,PATH:`${deploy}/bin:${process.env.PATH}`,...extra}
    });
    let stdout='',stderr='';child.stdout.on('data',chunk=>stdout+=chunk);child.stderr.on('data',chunk=>stderr+=chunk);
    child.on('close',code=>resolve({code,stdout,stderr}));
  });
  const ok=async(args)=>{const result=await invoke(args);assert.equal(result.code,0,`${args.join(' ')}\n${result.stderr}\n${result.stdout}`);return result;};
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
    pass('旧部署经外部 Prompt/知识回读后建立首份受限原子投影');

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
    assert.equal(JSON.parse((await invoke(['status'])).stdout).pending,true);
    pass('Prompt 已写外部而知识失败时恢复旧外部状态、旧投影以新代次生效且保留待修原文');

    await ok(['apply']);
    const knowledgeApplied=JSON.parse(fs.readFileSync(projectionPath));
    const catalog=JSON.parse(fs.readFileSync(path.join(deploy,'knowledge/catalog.json')));
    assert.equal(catalog.libraries[0].documents[0].sha256,sha(sourcePath));
    assert.equal(knowledgeApplied.knowledge.document_count,1);assert.notEqual(knowledgeApplied.knowledge.map_sha256,'');
    assert.equal(prompt,failedPrompt);
    pass('重试后直接编辑的登记文档哈希、索引 map 与 Prompt 同代生效');

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
    assert.deepEqual({promptUpdates,embeddingUpdates},beforeRequests);
    assert.equal(configApplied.configuration.runtime.revision,configApplied.revision);
    assert.equal(configApplied.configuration.runtime.applied_revision,configApplied.revision);
    assert.equal(JSON.parse(fs.readFileSync(runtimePath)).enabled,false);
    pass('合法 YAML runtime 可初始化和应用，配置快路径规范写回且不触发付费模型、Prompt或知识重建');

    const beforeForced={promptUpdates,workspaceReads};
    prompt='## WebUI 漂移的虚构 Prompt\n';
    await ok(['apply','--force-external']);
    assert.equal(prompt,failedPrompt);
    assert.ok(promptUpdates>beforeForced.promptUpdates);
    assert.ok(workspaceReads>=beforeForced.workspaceReads+2);
    assert.equal(JSON.parse(fs.readFileSync(projectionPath)).state,'applied');
    pass('显式 force-external 即使原文未变也重新同步并回读 Prompt 与启用知识，知识使用增量对账');

    const beforeInterrupt=JSON.parse(fs.readFileSync(projectionPath));
    const interruptPrompt='## 中断后待恢复的 Prompt\n';
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
            process.kill(-child.pid,'SIGINT');
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
    assert.equal(interruptedResult.code,130,interruptedResult.stderr);
    assert.match(interruptedResult.stderr,/资料应用已中断/);
    const afterInterrupt=JSON.parse(fs.readFileSync(projectionPath));
    assert.equal(afterInterrupt.state,'applying');
    assert.ok(afterInterrupt.revision>beforeInterrupt.revision);
    assert.equal(afterInterrupt.prompt.text,beforeInterrupt.prompt.text);
    assert.equal(fs.readFileSync(path.join(deploy,'config/prompt.md'),'utf8'),interruptPrompt);
    await ok(['apply']);
    assert.equal(prompt,interruptPrompt);
    assert.equal(JSON.parse(fs.readFileSync(projectionPath)).state,'applied');
    pass('真实进程组 SIGINT 后以更高代次保持 applying、保留候选与旧快照，重试才解除停发');

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
    process.stdout.write(JSON.stringify({layer:'UNIT/CONTRACT',passed,failed:0,evidence:path.relative(root,work)})+'\n');
  } finally {
    server.closeAllConnections();
    await new Promise(resolve=>server.close(resolve));
  }
}

main().catch(error=>{console.error(error);process.exitCode=1;});
