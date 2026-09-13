'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const crypto = require('node:crypto');
const {spawn} = require('node:child_process');
const {createAdapter} = require('../scripts/provider-adapter.js');
const root = path.resolve(__dirname, '..');

async function main() {
  fs.mkdirSync(path.join(root,'.work/v1.2.1'),{recursive:true});
  const work = fs.mkdtempSync(path.join(root,'.work/v1.2.1/configuration-contract-'));
  const deploy = path.join(work,'deploy');
  for (const directory of ['config','knowledge','tmp','data/runtime','backups/config-history','n8n','scripts','bin']) fs.mkdirSync(path.join(deploy,directory),{recursive:true});
  fs.writeFileSync(path.join(deploy,'.crisp-ai-installation'),'ai-support\nstate=staged\n');
  fs.writeFileSync(path.join(deploy,'VERSION'),'v1.1.0\n');
  for (const name of ['keyword','handoff','menu','tags','feedback','provider']) {
    const target=path.join(deploy,`config/${name}.yaml`);
    fs.copyFileSync(path.join(root,`config/${name}.yaml.example`),target);
    fs.chmodSync(target,0o640);
  }
  fs.copyFileSync(path.join(root,'config/prompt.md.example'),path.join(deploy,'config/prompt.md'));
  fs.chmodSync(path.join(deploy,'config/prompt.md'),0o640);
  fs.copyFileSync(path.join(root,'n8n/workflow.json'),path.join(deploy,'n8n/workflow.json'));
  fs.copyFileSync(path.join(root,'docker-compose.yml'),path.join(deploy,'docker-compose.yml'));
  for (const name of ['provider-adapter.js','provider-router.js','provider-envelope.js','provider-pool.py']) fs.copyFileSync(path.join(root,'scripts',name),path.join(deploy,'scripts',name));
  fs.copyFileSync(path.join(root,'tests/mocks/configuration_docker'),path.join(deploy,'bin/docker'));
  fs.chmodSync(path.join(deploy,'bin/docker'),0o755);
  const documents = new Map(); let locations=[], prompt=fs.readFileSync(path.join(deploy,'config/prompt.md'),'utf8'), sequence=0, modelStatus=200, sourceRemoval=[], lastProviderHeaders={};
  let providerChatFailure=false;
  let modelEmpty=false, modelHang=false, modelCalls=0, systemWindowReads=0;
  const service=http.createServer(async(request,response)=>{
    let data=Buffer.alloc(0);for await(const chunk of request)data=Buffer.concat([data,chunk]);
    const send=(status,body)=>{response.writeHead(status,{'content-type':'application/json'});response.end(JSON.stringify(body));};
    const body = request.headers['content-type']?.includes('application/json') ? JSON.parse(data.toString('utf8') || '{}') : {};
    if(request.url === '/api/v1/auth'){send(200,{authenticated:true});return;}
    if(request.url === '/api/v1/system'){
      assert.equal(request.method,'GET');assert.equal(request.headers.authorization,'Bearer '+secret);
      const running=path.join(deploy,'tmp/configuration-rag-running.json');
      if(!fs.existsSync(running)){send(503,{error:'synthetic-component-not-recreated'});return;}
      systemWindowReads++;
      send(200,{settings:{GenericOpenAiTokenLimit:String(JSON.parse(fs.readFileSync(running)).context_window)}});return;
    }
    if(request.url === '/healthz' || request.url === '/api/ping'){send(200,{ok:true});return;}
    if(request.url.startsWith('/webhook/crisp-webhook?')){send(401,{accepted:false,reason:'Webhook 校验失败'});return;}
    if(request.url === '/api/v1/workspace/crisp-support'){send(200,{workspace:[{slug:'crisp-support',openAiPrompt:prompt,documents:locations.map(docpath=>({docpath}))}]});return;}
    if(request.url === '/api/v1/workspace/crisp-support/update'){prompt=body.openAiPrompt;send(200,{workspace:{slug:'crisp-support',openAiPrompt:prompt}});return;}
    if(request.url === '/api/v1/document/upload'){
      const filename=/filename="([^"]+)"/.exec(data.toString('utf8'))?.[1];
      const location=`custom-documents/${filename}.${++sequence}.json`;
      const parsed=path.join(deploy,'data/anythingllm/documents',location);
      fs.mkdirSync(path.dirname(parsed),{recursive:true});
      fs.writeFileSync(parsed,JSON.stringify({pageContent:`# ${filename}\n协议解析正文，不是真实业务知识。\n`}),{mode:0o640});
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
      modelCalls++;
      if(modelHang)return;
      if(modelStatus===200)send(200,{data:modelEmpty?[]:[{id:'synthetic-b'},{id:'synthetic-a'},{id:'synthetic-a'}]});else send(modelStatus,{error:{message:'fixture'}});return;
    }
    if(request.url === '/proxy/v1/chat/completions'){lastProviderHeaders=request.headers;if(providerChatFailure)send(500,{error:{message:'fixture'}});else send(200,{choices:[{message:{content:'协议模型回答'}}]});return;}
    if(request.url === '/proxy/v1/responses'){lastProviderHeaders=request.headers;send(200,{output_text:'协议模型回答'});return;}
    send(404,{error:'fixture-unknown-route'});
  });
  await new Promise(resolve=>service.listen(0,'127.0.0.1',resolve));
  const port=service.address().port;
  const secret='synthetic-secret-not-for-real-use';
  fs.writeFileSync(path.join(deploy,'.env'),`ANYTHINGLLM_API_KEY=${secret}\nANYTHINGLLM_WORKSPACE=crisp-support\nANYTHINGLLM_PORT=${port}\nN8N_PORT=${port}\nLOCAL_HEALTH_TIMEOUT_SECONDS=2\nLOCAL_HEALTH_INTERVAL_SECONDS=1\nN8N_WORKFLOW_READY_TIMEOUT_SECONDS=2\nAI_API_BASE_URL=http://127.0.0.1:${port}/proxy/v1\nAI_API_PROBE_BASE_URL=http://127.0.0.1:${port}/proxy/v1\nAI_API_KEY=${secret}\nAI_MODEL=synthetic-a\nAI_API_MODE=chat_completions\n`);
  fs.appendFileSync(path.join(deploy,'.env'),'AI_CUSTOM_HEADERS_JSON=\'{"x-original":"synthetic-original"}\'\n');
  fs.chmodSync(path.join(deploy,'.env'),0o600);
  fs.writeFileSync(path.join(deploy,'config/provider.yaml'),JSON.stringify({schema_version:2,provider:{base_url:`http://127.0.0.1:${port}/proxy/v1`,model:'synthetic-a',api_mode:'chat_completions',api_key_env:'AI_API_KEY'}}));
  let count=0;
  let adapter, adapterBase='';
  const startAdapter=async()=>{
    const internal=/^PROVIDER_ADAPTER_KEY=(.*)$/m.exec(fs.readFileSync(path.join(deploy,'.env'),'utf8'))[1];
    adapter=createAdapter({PROVIDER_ROOT:deploy,PROVIDER_POOL_REQUIRED:'true',PROVIDER_REQUIRE_ENVELOPE:'true',PROVIDER_ADAPTER_KEY:internal});
    await new Promise(resolve=>adapter.listen(0,'127.0.0.1',resolve));
    adapterBase=`http://127.0.0.1:${adapter.address().port}`;
  };
  const pass=name=>{count++;console.log(`通过 UNIT/CONTRACT：${name}`);};
  const invoke=(script,args=[],overrides={})=>new Promise(resolve=>{
    const child=spawn('bash',[path.join(root,'scripts',script),'--deploy-dir',deploy,...args],{cwd:work,env:{...process.env,PATH:`${deploy}/bin:${process.env.PATH}`,CONFIGURATION_FIXTURE_DEPLOY:deploy,PROVIDER_ADAPTER_MANAGEMENT_URL:adapterBase,...overrides}});
    let stdout='',stderr='';child.stdout.on('data',chunk=>stdout+=chunk);child.stderr.on('data',chunk=>stderr+=chunk);child.on('close',code=>resolve({code,stdout,stderr}));
  });
  const invokeCommonMigration=()=>new Promise(resolve=>{
    const child=spawn('bash',['-c','set -euo pipefail; source "$1/scripts/common.sh"; migrate_config_files "$2"','configuration-common-migrate',root,deploy],{cwd:work,env:{...process.env,PATH:`${deploy}/bin:${process.env.PATH}`}});
    let stdout='',stderr='';child.stdout.on('data',chunk=>stdout+=chunk);child.stderr.on('data',chunk=>stderr+=chunk);child.on('close',code=>resolve({code,stdout,stderr}));
  });
  const ok=async(script,args)=>{const output=await invoke(script,args);assert.equal(output.code,0,`${script} ${args.join(' ')}\n${output.stderr}\n${output.stdout}`);return output;};
  const readCatalog=()=>JSON.parse(fs.readFileSync(path.join(deploy,'knowledge/catalog.json')));
  try {
    await ok('provider.sh',['migrate']);
    await startAdapter();
    const installationFile=path.join(deploy,'.crisp-ai-installation'), installationBefore=fs.readFileSync(installationFile);
    fs.writeFileSync(installationFile,'ai-support\nstate=local-ready\n');
    const initialPool=JSON.parse(fs.readFileSync(path.join(deploy,'config/provider-pool-applied.json')));
    const initialWindow=initialPool.entries.find(entry=>entry.id===initialPool.primary_id).context_window;
    const windowCandidate=path.join(work,'rag-window-candidate.json');
    fs.writeFileSync(windowCandidate,JSON.stringify({provider:{context_window:initialWindow*2}}));
    const windowApplied=JSON.parse((await ok('provider.sh',['edit',initialPool.primary_id,windowCandidate])).stdout);
    assert.deepEqual(windowApplied.rag_context,{context_window:initialWindow*2,state:'applied'});
    const runningWindow=()=>JSON.parse(fs.readFileSync(path.join(deploy,'tmp/configuration-rag-running.json')));
    assert.equal(runningWindow().context_window,initialWindow*2);
    fs.writeFileSync(windowCandidate,JSON.stringify({provider:{context_window:initialWindow}}));
    const windowRestored=JSON.parse((await ok('provider.sh',['edit',initialPool.primary_id,windowCandidate])).stdout);
    assert.deepEqual(windowRestored.rag_context,{context_window:initialWindow,state:'applied'});
    assert.equal(runningWindow().context_window,initialWindow);
    assert.equal(runningWindow().recreates,2);
    assert.equal(systemWindowReads,2,'两次受控重建都必须经过官方API运行回读');
    assert.equal(runningWindow().service,'anythingllm');
    assert.equal(fs.existsSync(path.join(deploy,'config/provider-pool-transaction.json')),false);
    fs.writeFileSync(installationFile,installationBefore);
    pass('实际接口池窗口编辑触发受管AnythingLLM单组件重建并双回读，恢复原窗口且不跳过生产helper');
    fs.writeFileSync(path.join(deploy,'knowledge/原先资料.md'),'# 原先资料\n虚构内容，流程标记为蓝色。\n');
    const legacyFeedback=JSON.parse(fs.readFileSync(path.join(deploy,'config/feedback.yaml')));
    legacyFeedback.feedback.enabled=true;
    legacyFeedback.feedback.prompt='历史自定义评价文案，仅保留不派发';
    fs.writeFileSync(path.join(deploy,'config/feedback.yaml'),JSON.stringify(legacyFeedback));
    await ok('configuration.sh',['migrate']);
    const migratedFeedback=JSON.parse(fs.readFileSync(path.join(deploy,'config/feedback.yaml')));
    assert.equal(migratedFeedback.feedback.enabled,false);
    assert.equal(migratedFeedback.feedback.auto_invite,false);
    assert.equal(migratedFeedback.feedback.prompt,legacyFeedback.feedback.prompt);
    const migratedFeedbackBytes=fs.readFileSync(path.join(deploy,'config/feedback.yaml'));
    await ok('configuration.sh',['migrate']);
    assert.deepEqual(fs.readFileSync(path.join(deploy,'config/feedback.yaml')),migratedFeedbackBytes);
    pass('旧评价配置显式幂等停用，历史自定义文案及保留设置不丢失');
    const keywordFile=path.join(deploy,'config/keyword.yaml'), handoffFile=path.join(deploy,'config/handoff.yaml');
    const legacyKeyword=JSON.parse(fs.readFileSync(keywordFile)), legacyHandoff=JSON.parse(fs.readFileSync(handoffFile));
    legacyKeyword.rules[0].cancel_label='继续 AI 客服';
    legacyKeyword.rules[0].confirm_message='已暂停本次对话的 AI 回复，您的人工协助请求已收到。';
    legacyKeyword.rules.push({...legacyKeyword.rules[0],id:'custom-display-test',cancel_label:'自定义继续处理',confirm_message:'自定义人工协助说明'});
    legacyHandoff.handoff.message=legacyKeyword.rules[0].confirm_message;
    legacyHandoff.handoff.failure_message='当前自动客服暂时不可用，请稍后再试。';
    legacyHandoff.handoff.resume_after_seconds=37;
    fs.writeFileSync(keywordFile,JSON.stringify(legacyKeyword));fs.writeFileSync(handoffFile,JSON.stringify(legacyHandoff));
    await ok('configuration.sh',['migrate']);
    const neutralKeyword=JSON.parse(fs.readFileSync(keywordFile)), neutralHandoff=JSON.parse(fs.readFileSync(handoffFile));
    assert.equal(neutralKeyword.rules[0].cancel_label,'继续咨询');
    assert.equal(neutralKeyword.rules[0].confirm_message,'您的人工协助请求已收到，请稍候。');
    assert.deepEqual(neutralKeyword.rules[1],legacyKeyword.rules[1]);
    assert.equal(neutralHandoff.handoff.message,'您的人工协助请求已收到，请稍候。');
    assert.equal(neutralHandoff.handoff.failure_message,'你最希望先解决哪一处？可以把具体情况、相关提示和已经尝试的方法一起告诉我。');
    assert.equal(neutralHandoff.handoff.resume_after_seconds,37);
    assert.deepEqual(JSON.parse(fs.readFileSync(path.join(deploy,'backups/config-history/keyword.display.pre-v1.2.1.yaml'))),legacyKeyword);
    assert.deepEqual(JSON.parse(fs.readFileSync(path.join(deploy,'backups/config-history/handoff.display.pre-v1.2.1.yaml'))),legacyHandoff);
    const neutralBytes=[fs.readFileSync(keywordFile),fs.readFileSync(handoffFile)];
    await ok('configuration.sh',['migrate']);
    assert.deepEqual([fs.readFileSync(keywordFile),fs.readFileSync(handoffFile)],neutralBytes);
    pass('中性显示只迁移系统精确旧默认，保留自定义和人工秒数，受限备份且重复不变');
    const currentKeywordBytes=fs.readFileSync(keywordFile);
    fs.writeFileSync(keywordFile,JSON.stringify({keywords:[{
      id:'legacy-confirmation',name:'旧结构人工确认',enabled:true,match_mode:'contains',
      keywords:['联系人工'],exclude_keywords:[],priority:9,cooldown_seconds:5,
      action:{type:'handoff',text:'需要人工协助吗？请点击下方按钮确认。'}
    }]}));
    await ok('configuration.sh',['migrate']);
    const convertedKeyword=JSON.parse(fs.readFileSync(keywordFile));
    const convertedRule=convertedKeyword.rules.find(rule=>rule.id==='legacy-confirmation');
    assert.equal(convertedKeyword.schema_version,2);
    assert.equal(convertedRule.cancel_label,'继续咨询');
    assert.equal(convertedRule.confirm_message,'您的人工协助请求已收到，请稍候。');
    assert.doesNotMatch(JSON.stringify(convertedRule),/继续 AI 客服|已暂停本次对话的 AI 回复/);
    fs.writeFileSync(keywordFile,currentKeywordBytes);
    pass('旧关键词schema在同一次迁移返回前完成中性文案归一化，不发布旧生成缺省');
    const currentHandoffBytes=fs.readFileSync(handoffFile);
    const legacyHandoffWithoutMessage={handoff:{
      keywords:['人工','客服','真人'],resume_keywords:['恢复AI'],topic_keywords:{payment:['付款']},
      resume_after_seconds:1800,on_operator_message:true,on_low_confidence:true,on_no_answer:true,
      confirmation:'已为您转接人工客服，AI 将暂停回复。',
      no_answer_message:'知识库暂时没有足够信息，已为您转接人工客服。',
      low_confidence_message:'当前答案可信度不足，已为您转接人工客服。',
      failure_message:'当前自动客服暂时不可用，已为您转接人工客服。',
      low_confidence:{require_sources:true,minimum_score:0.25}
    }};
    fs.writeFileSync(handoffFile,JSON.stringify(legacyHandoffWithoutMessage));
    await ok('configuration.sh',['migrate']);
    const migratedLegacyHandoff=JSON.parse(fs.readFileSync(handoffFile));
    assert.equal(migratedLegacyHandoff.handoff.message,'正在为您转接人工客服，请稍候。');
    assert.equal(migratedLegacyHandoff.handoff.disable_ai,true);
    assert.equal(migratedLegacyHandoff.handoff.notify_user.enabled,true);
    assert.equal(migratedLegacyHandoff.handoff.resume_after_seconds,1800);
    assert.deepEqual(migratedLegacyHandoff.handoff.low_confidence,legacyHandoffWithoutMessage.handoff.low_confidence);
    assert.deepEqual(migratedLegacyHandoff.handoff.low_confidence,legacyHandoffWithoutMessage.handoff.low_confidence);
    for(const removed of ['confirmation','topic_keywords','on_operator_message','on_low_confidence','on_no_answer','resume_keywords','resume_match_mode']) {
      assert.equal(Object.hasOwn(migratedLegacyHandoff.handoff,removed),false,`旧字段仍存在：${removed}`);
    }
    const migratedLegacyHandoffBytes=fs.readFileSync(handoffFile);
    await ok('configuration.sh',['migrate']);
    assert.deepEqual(fs.readFileSync(handoffFile),migratedLegacyHandoffBytes);
    const invalidModernHandoff=path.join(work,'invalid-modern-handoff.json');
    fs.writeFileSync(invalidModernHandoff,JSON.stringify({handoff:{
      keywords:['人工'],match_mode:'contains',resume_after_seconds:3600,disable_ai:true,
      notify_user:{enabled:true}
    }}));
    const invalidModernResult=await invoke('configuration.sh',['apply','handoff','--input',invalidModernHandoff]);
    assert.notEqual(invalidModernResult.code,0);
    assert.deepEqual(fs.readFileSync(handoffFile),migratedLegacyHandoffBytes);
    const invalidModernBytes=fs.readFileSync(invalidModernHandoff);
    fs.writeFileSync(handoffFile,invalidModernBytes);
    const commonMigrationResult=await invokeCommonMigration();
    assert.equal(commonMigrationResult.code,0,commonMigrationResult.stderr);
    assert.deepEqual(fs.readFileSync(handoffFile),invalidModernBytes,'公共旧版迁移不得补齐现代损坏配置');
    const strictMigrationResult=await invoke('configuration.sh',['migrate']);
    assert.notEqual(strictMigrationResult.code,0);
    assert.deepEqual(fs.readFileSync(handoffFile),invalidModernBytes,'严格迁移失败不得改写现代损坏配置');
    fs.writeFileSync(handoffFile,currentHandoffBytes);
    pass('旧人工配置先迁移再严格校验且幂等，现代缺失通知文案仍拒绝并保留旧值');
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
    const queryOutput=(await ok('knowledge.sh',['query',libraryIds[0],'电脑问题的处理标记是什么？'])).stdout;
    const query=JSON.parse(queryOutput);
    assert.equal(query.answer,'协议模型回答');assert.equal(query.verified,true);assert.equal(query.retrieval_state,'knowledge_hit');
    assert.equal(query.scope,'全部已启用知识库（与实际客服一致）');assert.match(query.note,/实际客服保持一致/);
    assert.equal(query.sources.length,5);assert.ok(new Set(query.sources.map(item=>item.library_name)).size>=2);
    assert.ok(query.sources.every(item=>assert.deepEqual(Object.keys(item).sort(),['library_name','projection'])===undefined));
    for(const location of locations) assert.equal(queryOutput.includes(location),false);
    pass('菜单检索走生产管理员同链，以全部已启用库返回脱敏唯一来源');
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
    const welcomeCandidate=path.join(work,'welcome.json');
    const oldMenu=JSON.parse((await ok('configuration.sh',['get','menu'])).stdout);
    oldMenu.welcome.enabled=false;
    fs.writeFileSync(welcomeCandidate,JSON.stringify(oldMenu));
    const welcomeResult=JSON.parse((await ok('configuration.sh',['apply','menu','--input',welcomeCandidate])).stdout);
    assert.equal(welcomeResult.target,'menu');assert.equal(welcomeResult.applied,true);
    assert.equal(welcomeResult.value.welcome.enabled,false);
    assert.equal(welcomeResult.enabled,true);
    const welcomeProjection=JSON.parse(fs.readFileSync(path.join(deploy,'config/materials-applied.json')));
    assert.equal(welcomeProjection.configuration.menu.welcome.enabled,false);
    assert.equal(welcomeProjection.configuration.runtime.enabled,true);
    pass('关闭欢迎回执指明真实目标及已应用值，不能把总开关 enabled=true 误当欢迎');
    const feedbackCandidate=path.join(work,'feedback.json');
    fs.writeFileSync(feedbackCandidate,JSON.stringify(legacyFeedback));
    const feedbackResult=JSON.parse((await ok('configuration.sh',['apply','feedback','--input',feedbackCandidate])).stdout);
    assert.equal(feedbackResult.value.feedback.enabled,false);assert.equal(feedbackResult.value.feedback.auto_invite,false);
    assert.equal(JSON.parse(fs.readFileSync(path.join(deploy,'config/feedback.yaml'))).feedback.prompt,legacyFeedback.feedback.prompt);
    pass('旧启用反馈候选重新应用仍停用邀请，不篡改历史正文');
    const candidate=path.join(work,'runtime.json');fs.writeFileSync(candidate,JSON.stringify({enabled:false}));await ok('configuration.sh',['apply','runtime','--input',candidate]);
    let runtime=JSON.parse((await ok('configuration.sh',['status'])).stdout);assert.equal(runtime.enabled,false);assert.equal(runtime.applied_revision,runtime.revision);pass('全局配置原子提交与运行时文件读回');
    const revision=runtime.revision;fs.writeFileSync(candidate,JSON.stringify({enabled:true}));const failure=await invoke('configuration.sh',['apply','runtime','--input',candidate],{CONFIGURATION_FIXTURE_READBACK_FAIL:'1'});assert.notEqual(failure.code,0);
    runtime=JSON.parse((await ok('configuration.sh',['status'])).stdout);assert.equal(runtime.enabled,false);assert.ok(runtime.revision>revision);pass('应用失败恢复旧值且revision单调防旧请求复活');
    const models=JSON.parse((await ok('provider.sh',['models'])).stdout);assert.deepEqual(models.models,['synthetic-a','synthetic-b']);pass('模型列表去重与排序');
    modelStatus=401;assert.equal((await invoke('provider.sh',['models'])).code,3);modelStatus=404;assert.equal((await invoke('provider.sh',['models'])).code,2);modelStatus=200;pass('模型鉴权失败和手填后备状态可区分');
    modelEmpty=true;const emptyModels=await invoke('provider.sh',['models']);
    assert.equal(emptyModels.code,2);
    const emptyResult=JSON.parse(emptyModels.stdout);assert.equal(emptyResult.ok,false);assert.equal(emptyResult.error.code,'models_unavailable');assert.equal(emptyResult.models,undefined);modelEmpty=false;
    pass('空模型列表进入手填后备，不编造模型');
    modelStatus=429;let initialCalls=modelCalls;const limited=await invoke('provider.sh',['models']);
    assert.equal(limited.code,4);assert.equal(modelCalls-initialCalls,3);assert(!limited.stdout.includes(secret));modelStatus=200;
    pass('模型列表429使用三次有界请求并返回可重试错误');
    modelHang=true;initialCalls=modelCalls;const started=Date.now();const timed=await invoke('provider.sh',['models']);
    assert.equal(timed.code,4);assert(modelCalls-initialCalls<=3);assert(Date.now()-started>=29000 && Date.now()-started<110000);assert(!timed.stdout.includes(secret));modelHang=false;
    pass('模型列表真实HTTP挂起在有限超时内失败，不伪造可用模型');
    const providerCandidate=path.join(work,'provider.json');fs.writeFileSync(providerCandidate,JSON.stringify({provider:{custom_headers:{'X-New':'synthetic-new'}}}));
    await ok('provider.sh',['probe',providerCandidate]);assert.equal(lastProviderHeaders['x-original'],'synthetic-original');assert.equal(lastProviderHeaders['x-new'],'synthetic-new');pass('新增高级Header保留未编辑的现有Header');
    fs.writeFileSync(providerCandidate,JSON.stringify({provider:{remove_header:'x-original'}}));await ok('provider.sh',['probe',providerCandidate]);assert.equal(lastProviderHeaders['x-original'],undefined);pass('高级Header可以安全单项删除');
    const handoffPath=path.join(deploy,'config/handoff.yaml');
    fs.writeFileSync(handoffPath,'handoff:\n  resume_after_seconds: 1800\n  message: "YAML 直编内容 🙂"\n',{mode:0o640});
    await ok('configuration.sh',['materials-apply']);
    const normalizedHandoff=JSON.parse((await ok('configuration.sh',['get','handoff'])).stdout);
    assert.equal(normalizedHandoff.handoff.message,'YAML 直编内容 🙂');
    pass('真实 YAML 原文应用后仍能由配置菜单规范化读取');
    const runtimeBeforeExport=JSON.parse(fs.readFileSync(path.join(deploy,'config/runtime.yaml'),'utf8'));
    fs.writeFileSync(path.join(deploy,'config/runtime.yaml'),`schema_version: 2\nenabled: ${runtimeBeforeExport.enabled}\nrevision: ${runtimeBeforeExport.revision}\napplied_revision: ${runtimeBeforeExport.applied_revision}\n`,{mode:0o640});
    const migration=path.join(work,'business.tar.gz');await ok('migration.sh',['export',migration]);const preview=JSON.parse((await ok('migration.sh',['import-preview',migration])).stdout);assert.equal(preview.manifest.contains_secrets,false);assert.equal(preview.libraries.length,3);
    const extracted=path.join(work,'migration-files');fs.mkdirSync(extracted);await new Promise((resolve,reject)=>{const child=spawn('tar',['-xzf',migration,'-C',extracted]);child.on('close',code=>code?reject(new Error('tar')):resolve());});
    assert.equal(fs.readFileSync(path.join(extracted,'config/prompt.md'),'utf8'),promptContent);assert.equal(fs.existsSync(path.join(extracted,'.env')),false);assert.ok(readCatalog().libraries.flatMap(library=>library.documents.map(document=>path.join(extracted,'knowledge',library.id,document.source))).every(file=>fs.existsSync(file)));pass('完整业务迁移包包含多库原文和Prompt，不含秘密');
    assert.equal(JSON.parse(fs.readFileSync(path.join(extracted,'config/handoff.yaml'),'utf8')).handoff.message,'YAML 直编内容 🙂');
    const knowledgeInode=fs.statSync(path.join(deploy,'knowledge')).ino;
    await ok('migration.sh',['import',migration]);
    assert.equal(fs.statSync(path.join(deploy,'knowledge')).ino,knowledgeInode);
    pass('业务导入应用真实 YAML 且替换知识内容时保持既有 bind 根目录 inode');
    providerChatFailure=true;
    // 相同接口池导入不会重复付费探测；关闭本地 adapter，真实覆盖应用与恢复回读均失败。
    adapter.closeAllConnections();await new Promise(resolve=>adapter.close(resolve));adapter=null;
    const failedImport=await invoke('migration.sh',['import',migration]);
    assert.notEqual(failedImport.code,0);assert.match(failedImport.stderr,/恢复未完全确认/);assert.doesNotMatch(failedImport.stderr,/已恢复原配置与知识/);
    assert.equal(fs.statSync(path.join(deploy,'knowledge')).ino,knowledgeInode);
    assert.equal(JSON.parse(fs.readFileSync(path.join(deploy,'config/materials-applied.json'),'utf8')).state,'applying');
    providerChatFailure=false;
    await startAdapter();
    pass('导入失败且 Provider 回读恢复失败时不再假称完整恢复，以 applying 阻止自动回复且知识 bind 根 inode 不变');
    assert.ok(!JSON.stringify(preview).includes(secret));pass('导出预览和正常输出不泄露Key');
    const unsafeSource=path.join(work,'unsafe');fs.mkdirSync(unsafeSource);fs.symlinkSync(path.join(deploy,'.env'),path.join(unsafeSource,'secret-link'));
    const unsafeArchive=path.join(work,'unsafe.tar.gz');await new Promise((resolve,reject)=>{const child=spawn('tar',['-czf',unsafeArchive,'-C',unsafeSource,'.']);child.on('close',code=>code?reject(new Error('tar')):resolve());});
    assert.notEqual((await invoke('migration.sh',['import-preview',unsafeArchive])).code,0);pass('迁移包拒绝未授权路径和符号链接');
    console.log(`UNIT/CONTRACT 合计 ${count} 通过，0 失败；证据 ${path.relative(root,work)}`);
  } finally {
    if(adapter){adapter.closeAllConnections();await new Promise(resolve=>adapter.close(resolve));}
    service.closeAllConnections();await new Promise(resolve=>service.close(resolve));
  }
}
main().catch(error=>{console.error(error);process.exitCode=1;});
