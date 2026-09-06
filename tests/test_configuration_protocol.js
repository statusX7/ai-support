'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const crypto = require('node:crypto');
const {spawn} = require('node:child_process');
const root = path.resolve(__dirname, '..');

async function main() {
  fs.mkdirSync(path.join(root,'.work'),{recursive:true});
  const work = fs.mkdtempSync(path.join(root,'.work/configuration-contract-'));
  const deploy = path.join(work,'deploy');
  for (const directory of ['config','knowledge','tmp','data/runtime','backups/config-history','n8n','bin']) fs.mkdirSync(path.join(deploy,directory),{recursive:true});
  fs.writeFileSync(path.join(deploy,'.crisp-ai-installation'),'ai-support\nstate=staged\n');
  fs.writeFileSync(path.join(deploy,'VERSION'),'v1.1.0\n');
  for (const name of ['keyword','handoff','menu','tags','feedback','provider']) fs.copyFileSync(path.join(root,`config/${name}.yaml.example`),path.join(deploy,`config/${name}.yaml`));
  fs.copyFileSync(path.join(root,'config/prompt.md.example'),path.join(deploy,'config/prompt.md'));
  fs.copyFileSync(path.join(root,'n8n/workflow.json'),path.join(deploy,'n8n/workflow.json'));
  fs.copyFileSync(path.join(root,'tests/mocks/configuration_docker'),path.join(deploy,'bin/docker'));
  fs.chmodSync(path.join(deploy,'bin/docker'),0o755);
  const documents = new Map(); let locations=[], prompt='', sequence=0, modelStatus=200, sourceRemoval=[], lastProviderHeaders={};
  const service=http.createServer(async(request,response)=>{
    let data=Buffer.alloc(0);for await(const chunk of request)data=Buffer.concat([data,chunk]);
    const send=(status,body)=>{response.writeHead(status,{'content-type':'application/json'});response.end(JSON.stringify(body));};
    const body = request.headers['content-type']?.includes('application/json') ? JSON.parse(data.toString('utf8') || '{}') : {};
    if(request.url === '/api/v1/auth'){send(200,{authenticated:true});return;}
    if(request.url === '/api/v1/workspace/crisp-support'){send(200,{workspace:[{slug:'crisp-support',openAiPrompt:prompt,documents:locations.map(docpath=>({docpath}))}]});return;}
    if(request.url === '/api/v1/workspace/crisp-support/update'){prompt=body.openAiPrompt;send(200,{workspace:{slug:'crisp-support',openAiPrompt:prompt}});return;}
    if(request.url === '/api/v1/document/upload'){
      const filename=/filename="([^"]+)"/.exec(data.toString('utf8'))?.[1];
      const location=`custom-documents/${filename}.${++sequence}.json`;
      documents.set(location,{filename});send(200,{success:true,documents:[{location}]});return;
    }
    if(request.url === '/api/v1/workspace/crisp-support/update-embeddings'){
      locations=[...new Set([...locations,...(body.adds || [])])].filter(item=>!(body.deletes || []).includes(item));send(200,{success:true});return;
    }
    if(request.url === '/api/v1/system/remove-documents'){
      for(const name of body.names || []){sourceRemoval.push(name);documents.delete(name);}send(200,{success:true});return;
    }
    if(request.url === '/api/v1/workspace/crisp-support/vector-search'){
      send(200,{results:locations.map(location=>({text:'协议服务检索样本，不是真实模型',metadata:{docpath:location,title:documents.get(location)?.filename},score:0.8}))});return;
    }
    if(request.url === '/proxy/v1/models'){
      if(modelStatus===200)send(200,{data:[{id:'synthetic-b'},{id:'synthetic-a'},{id:'synthetic-a'}]});else send(modelStatus,{error:{message:'fixture'}});return;
    }
    if(request.url === '/proxy/v1/chat/completions'){lastProviderHeaders=request.headers;send(200,{choices:[{message:{content:'协议模型回答'}}]});return;}
    if(request.url === '/proxy/v1/responses'){lastProviderHeaders=request.headers;send(200,{output_text:'协议模型回答'});return;}
    send(404,{error:'fixture-unknown-route'});
  });
  await new Promise(resolve=>service.listen(0,'127.0.0.1',resolve));
  const port=service.address().port;
  const secret='synthetic-secret-not-for-real-use';
  fs.writeFileSync(path.join(deploy,'.env'),`ANYTHINGLLM_API_KEY=${secret}\nANYTHINGLLM_WORKSPACE=crisp-support\nANYTHINGLLM_PORT=${port}\nAI_API_BASE_URL=http://127.0.0.1:${port}/proxy/v1\nAI_API_PROBE_BASE_URL=http://127.0.0.1:${port}/proxy/v1\nAI_API_KEY=${secret}\nAI_MODEL=synthetic-a\nAI_API_MODE=chat_completions\n`);
  fs.chmodSync(path.join(deploy,'.env'),0o600);
  fs.writeFileSync(path.join(deploy,'config/provider.yaml'),JSON.stringify({schema_version:2,provider:{base_url:`http://127.0.0.1:${port}/proxy/v1`,model:'synthetic-a',api_mode:'chat_completions',api_key_env:'AI_API_KEY'}}));
  let count=0;
  const pass=name=>{count++;console.log(`通过 UNIT/CONTRACT：${name}`);};
  const invoke=(script,args=[],overrides={})=>new Promise(resolve=>{
    const child=spawn('bash',[path.join(root,'scripts',script),'--deploy-dir',deploy,...args],{cwd:work,env:{...process.env,PATH:`${deploy}/bin:${process.env.PATH}`,CONFIGURATION_FIXTURE_DEPLOY:deploy,...overrides}});
    let stdout='',stderr='';child.stdout.on('data',chunk=>stdout+=chunk);child.stderr.on('data',chunk=>stderr+=chunk);child.on('close',code=>resolve({code,stdout,stderr}));
  });
  const ok=async(script,args)=>{const output=await invoke(script,args);assert.equal(output.code,0,`${script} ${args.join(' ')}\n${output.stderr}\n${output.stdout}`);return output;};
  const readCatalog=()=>JSON.parse(fs.readFileSync(path.join(deploy,'knowledge/catalog.json')));
  try {
    fs.writeFileSync(path.join(deploy,'knowledge/原先资料.md'),'# 原先资料\n虚构内容，流程标记为蓝色。\n');
    await ok('configuration.sh',['migrate']);
    await ok('knowledge.sh',['sync']);
    assert.equal(readCatalog().libraries[0].id,'kb_default');assert.equal(readCatalog().libraries[0].documents.length,1);const originalSequence=sequence;
    await ok('knowledge.sh',['sync']);assert.equal(sequence,originalSequence);pass('单库幂等迁移保留既有 filename 与索引');
    const libraryIds=[];
    for(const name of ['电脑排障','手机排障','订阅与账号']) {
      const created=JSON.parse((await ok('knowledge.sh',['create',name])).stdout);libraryIds.push(created.library_id);
      const source=path.join(work,`${name}.TXT`);fs.writeFileSync(source,`# ${name}\n虚构业务内容，不能用于实际运营。\n`);
      await ok('knowledge.sh',['import',created.library_id,source]);
    }
    assert.equal(readCatalog().libraries.length,4);assert.equal(locations.length,4);pass('生产CLI 创建三个命名库并同步所属文档');
    const commonSource=path.join(work,'同名.md');fs.writeFileSync(commonSource,'# 文件同名\n不同库独立所有权。\n');
    await ok('knowledge.sh',['import',libraryIds[0],commonSource]);await ok('knowledge.sh',['import',libraryIds[1],commonSource]);
    assert.equal(new Set(readCatalog().libraries.flatMap(library=>library.documents.map(document=>document.projection))).size,6);pass('跨库同名源文件使用独立稳定投影');
    const before=sequence;await ok('knowledge.sh',['sync']);assert.equal(sequence,before);pass('重复同步不重复上传或计数');
    const beforeReindex=Object.fromEntries(Object.entries(JSON.parse(fs.readFileSync(path.join(deploy,'data/knowledge-manifest.json'))).files).map(([name,entry])=>[name,entry.locations]));
    await ok('knowledge.sh',['reindex',libraryIds[0]]);
    const afterReindex=JSON.parse(fs.readFileSync(path.join(deploy,'data/knowledge-manifest.json'))).files;
    for(const library of readCatalog().libraries) for(const document of library.documents) {
      if(library.id===libraryIds[0]) assert.notDeepEqual(afterReindex[document.projection].locations,beforeReindex[document.projection]);
      else assert.deepEqual(afterReindex[document.projection].locations,beforeReindex[document.projection]);
    }
    assert.equal(sequence,before+2);pass('单库重建只重新上传所选库，其他库索引保持原位置');
    assert.notEqual((await invoke('knowledge.sh',['sync','kb_0123456789abcdef'])).code,0);pass('单库同步拒绝不存在的库 ID');
    const disabled=readCatalog().libraries.find(library=>library.id===libraryIds[1]);
    const removalBeforeDisable=sourceRemoval.length;
    await ok('knowledge.sh',['disable',libraryIds[1]]);assert.equal(locations.length,4);assert.equal(sourceRemoval.length,removalBeforeDisable+2);assert.ok(disabled.documents.every(document=>!fs.existsSync(path.join(deploy,'knowledge',document.projection))));pass('停用库实际移除workspace索引，原文保留');
    await ok('knowledge.sh',['enable',libraryIds[1]]);assert.equal(locations.length,6);pass('重新启用恢复索引且不影响其他库');
    await ok('knowledge.sh',['delete',libraryIds[2]]);assert.equal(locations.length,5);assert.ok(!readCatalog().libraries.some(library=>library.id===libraryIds[2]));pass('删除指定库保护其他库与索引');
    const query=JSON.parse((await ok('knowledge.sh',['query',libraryIds[0],'电脑问题的处理标记是什么？'])).stdout);assert.equal(query.results.length,2);assert.ok(query.results.every(item=>item.library_id===libraryIds[0]));pass('单库检索预览正确关联来源，明确协议层');
    const removedDocument=readCatalog().libraries.find(library=>library.id===libraryIds[0]).documents.find(document=>document.name==='同名.md');
    await ok('knowledge.sh',['remove',libraryIds[0],removedDocument.id]);
    assert.ok(!fs.existsSync(path.join(deploy,'knowledge',libraryIds[0],removedDocument.source)));
    assert.ok(fs.readdirSync(path.join(deploy,'backups/config-history')).some(item=>fs.existsSync(path.join(deploy,'backups/config-history',item,libraryIds[0],removedDocument.source))));
    assert.equal(locations.length,4);pass('删除条目移走当前原文并保留受限历史恢复副本');
    const promptContent='## 中文 🙂 Prompt\n\n保留 $ # = " \\ 原样。\n\n';const promptSource=path.join(work,'新 提示.md');fs.writeFileSync(promptSource,promptContent);
    await ok('configuration.sh',['prompt-apply',promptSource]);assert.equal(prompt,promptContent);assert.equal(fs.readFileSync(path.join(deploy,'config/prompt.md'),'utf8'),promptContent);pass('Prompt 特殊字符和末尾空行逐字同步');
    const marked=await ok('configuration.sh',['mark-applied']);
    assert.equal(marked.stdout.trim(),'');
    const markedState=JSON.parse(fs.readFileSync(path.join(deploy,'config/runtime.yaml')));
    assert.equal(markedState.revision,markedState.applied_revision);
    pass('mark-applied 反向加载 knowledge 不重复派发入口或输出旧状态');
    const candidate=path.join(work,'runtime.json');fs.writeFileSync(candidate,JSON.stringify({enabled:false}));await ok('configuration.sh',['apply','runtime','--input',candidate]);
    let runtime=JSON.parse((await ok('configuration.sh',['status'])).stdout);assert.equal(runtime.enabled,false);assert.equal(runtime.applied_revision,runtime.revision);pass('全局配置原子提交与运行时文件读回');
    const revision=runtime.revision;fs.writeFileSync(candidate,JSON.stringify({enabled:true}));const failure=await invoke('configuration.sh',['apply','runtime','--input',candidate],{CONFIGURATION_FIXTURE_READBACK_FAIL:'1'});assert.notEqual(failure.code,0);
    runtime=JSON.parse((await ok('configuration.sh',['status'])).stdout);assert.equal(runtime.enabled,false);assert.ok(runtime.revision>revision);pass('应用失败恢复旧值且revision单调防旧请求复活');
    const models=JSON.parse((await ok('provider.sh',['models'])).stdout);assert.deepEqual(models.models,['synthetic-a','synthetic-b']);pass('模型列表去重与排序');
    modelStatus=401;assert.equal((await invoke('provider.sh',['models'])).code,3);modelStatus=404;assert.equal((await invoke('provider.sh',['models'])).code,2);modelStatus=200;pass('模型鉴权失败和手填后备状态可区分');
    fs.appendFileSync(path.join(deploy,'.env'),'AI_CUSTOM_HEADERS_JSON=\'{"x-original":"synthetic-original"}\'\n');
    const providerCandidate=path.join(work,'provider.json');fs.writeFileSync(providerCandidate,JSON.stringify({provider:{custom_headers:{'X-New':'synthetic-new'}}}));
    await ok('provider.sh',['probe',providerCandidate]);assert.equal(lastProviderHeaders['x-original'],'synthetic-original');assert.equal(lastProviderHeaders['x-new'],'synthetic-new');pass('新增高级Header保留未编辑的现有Header');
    fs.writeFileSync(providerCandidate,JSON.stringify({provider:{remove_header:'x-original'}}));await ok('provider.sh',['probe',providerCandidate]);assert.equal(lastProviderHeaders['x-original'],undefined);pass('高级Header可以安全单项删除');
    const migration=path.join(work,'business.tar.gz');await ok('migration.sh',['export',migration]);const preview=JSON.parse((await ok('migration.sh',['import-preview',migration])).stdout);assert.equal(preview.manifest.contains_secrets,false);assert.equal(preview.libraries.length,3);
    const extracted=path.join(work,'migration-files');fs.mkdirSync(extracted);await new Promise((resolve,reject)=>{const child=spawn('tar',['-xzf',migration,'-C',extracted]);child.on('close',code=>code?reject(new Error('tar')):resolve());});
    assert.equal(fs.readFileSync(path.join(extracted,'config/prompt.md'),'utf8'),promptContent);assert.equal(fs.existsSync(path.join(extracted,'.env')),false);assert.ok(readCatalog().libraries.flatMap(library=>library.documents.map(document=>path.join(extracted,'knowledge',library.id,document.source))).every(file=>fs.existsSync(file)));pass('完整业务迁移包包含多库原文和Prompt，不含秘密');
    assert.ok(!JSON.stringify(preview).includes(secret));pass('导出预览和正常输出不泄露Key');
    const unsafeSource=path.join(work,'unsafe');fs.mkdirSync(unsafeSource);fs.symlinkSync(path.join(deploy,'.env'),path.join(unsafeSource,'secret-link'));
    const unsafeArchive=path.join(work,'unsafe.tar.gz');await new Promise((resolve,reject)=>{const child=spawn('tar',['-czf',unsafeArchive,'-C',unsafeSource,'.']);child.on('close',code=>code?reject(new Error('tar')):resolve());});
    assert.notEqual((await invoke('migration.sh',['import-preview',unsafeArchive])).code,0);pass('迁移包拒绝未授权路径和符号链接');
    console.log(`UNIT/CONTRACT 合计 ${count} 通过，0 失败；证据 ${path.relative(root,work)}`);
  } finally {service.closeAllConnections();await new Promise(resolve=>service.close(resolve));}
}
main().catch(error=>{console.error(error);process.exitCode=1;});
