'use strict';

// 只用虚构 parsed JSON；直接运行生产构建器和检索函数，不访问实例或网络。
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const {spawnSync} = require('node:child_process');
const project = path.resolve(__dirname, '..');
const area = path.join(project, '.work/v1.2.1');
fs.mkdirSync(area, {recursive:true});
const evidence = fs.mkdtempSync(path.join(area, 'knowledge-lexical-'));
const script = path.join(project, 'scripts/knowledge-lexical.py');
const modulePath = path.join(project, 'n8n/knowledge-lexical.js');
const hash = value => crypto.createHash('sha256').update(value).digest('hex');
const canonical = value => JSON.stringify(value, (_key, item) => item && typeof item === 'object' && !Array.isArray(item)
  ? Object.fromEntries(Object.keys(item).sort().map(key => [key, item[key]])) : item);
const question = '曜石灯塔补给箱的启封口令是什么？';
const answer = '启封口令是翠羽环-4831，核对箱体编号后使用。';
const qa = '问：' + question + '\n答：' + answer + '\n';
const save = (file, value) => {fs.mkdirSync(path.dirname(file), {recursive:true}); fs.writeFileSync(file, typeof value === 'string' ? value : JSON.stringify(value), {mode:0o600});};
function fixture(name, contents=[qa]) {
  const root = fs.mkdtempSync(path.join(evidence, name + '-'));
  const documents = contents.map((content, index) => {
    const id = (index + 1).toString(16).padStart(16, '0');
    const projection = 'kb_1111111111111111_doc_' + id + '.md';
    const item = {library_id:'kb_1111111111111111', document_id:'doc_' + id, projection, location:'custom-documents/' + projection + '.json'};
    save(path.join(root, 'data/anythingllm/documents', item.location), {pageContent:content, title:projection, secret_field:'synthetic-metadata-not-indexed'});
    return item;
  });
  const mapPath = path.join(root, 'data/runtime/knowledge-map.json');
  save(mapPath, {schema_version:2, revision:7, documents});
  save(path.join(root, '.env'), 'SYNTHETIC_SECRET=never-read-or-index\n');
  save(path.join(root, 'data/runtime/session-synthetic.json'), {content:'synthetic-private-conversation-never-index'});
  const indexPath = path.join(root, 'data/runtime/knowledge-lexical.json');
  const build = (...extra) => spawnSync('python3', [script, 'build', '--deploy-dir', root, ...extra], {encoding:'utf8', timeout:45000});
  const read = () => JSON.parse(fs.readFileSync(indexPath, 'utf8'));
  const mapRaw = () => fs.readFileSync(mapPath, 'utf8');
  const search = (query, overrides={}) => require(modulePath).searchKnowledgeLexical({query, index:read(), mapRaw:mapRaw(), ...overrides});
  return {root, documents, mapPath, indexPath, build, read, mapRaw, search};
}
function built(f) {
  const result=f.build(); assert.equal(result.status,0,result.stdout + result.stderr);
  assert.equal(JSON.parse(result.stdout).ok,true); return f.read();
}
function rejectedBuild(f, code) {
  const before=fs.existsSync(f.indexPath)?fs.readFileSync(f.indexPath):null;
  const result=f.build(); assert.equal(result.status,1);
  assert.equal(JSON.parse(result.stdout).error.code,code);
  assert(!result.stdout.includes(f.root)); assert(!result.stderr.includes('Traceback'));
  if(before) assert.deepEqual(fs.readFileSync(f.indexPath),before);
}
let passed=0,failed=0;
function test(name, action) {
  try {action(); passed++; console.log('通过 UNIT/CONTRACT：'+name);}
  catch(error) {failed++; console.error('失败 UNIT/CONTRACT：'+name+'\n'+error.stack);}
}
test('L01 明确尾部问答完整补回，不受向量512 token截断且保持原字节',()=>{
  const f=fixture('tail', ['虚构历史说明。'.repeat(4000)+'\n'+qa]);
  const index=built(f); const result=f.search(question);
  assert.equal(result.results.length,1); assert(result.results[0].text.includes(qa));
  assert.equal(result.results[0].metadata.title,f.documents[0].projection);
  assert.equal(result.results[0].metadata.docpath,f.documents[0].location);
  assert.equal(result.results[0].lexical.kind,'exact_question');
  assert.equal('distance' in result.results[0],false); assert.equal('score' in result.results[0],false);
  assert.equal(index.complete,true); assert.equal(index.map_sha256,hash(f.mapRaw()));
  assert.equal(fs.statSync(f.indexPath).mode & 0o777,0o640);
});
test('L02 中文标点/全角字符和英文大小写规范化，不修改原文',()=>{
  const f=fixture('normalization',[qa,'Question: How do I open the Zephyr archive?\nAnswer: Enter Kestrel-7348 at the archive gate.\n']); built(f);
  assert.equal(f.search('曜石灯塔补给箱的启封口令是什么?').results[0].text.includes(answer),true);
  assert.equal(f.search('ＨＯＷ ＤＯ Ｉ ＯＰＥＮ ＴＨＥ ＺＥＰＨＹＲ ＡＲＣＨＩＶＥ？').results[0].text.includes('Kestrel-7348'),true);
});
test('L03 具体中英关键词重叠可补召回，但通用词和不相关问题保持空',()=>{
  const f=fixture('overlap',[qa,'Question: How do I open the Zephyr archive?\nAnswer: Enter Kestrel-7348 at the archive gate.\n']); built(f);
  assert.equal(f.search('曜石灯塔补给箱 启封口令').results.length,1);
  assert.equal(f.search('open Zephyr archive').results.length,1);
  for(const query of ['请问怎么办','可以吗','怎么使用','我要咨询','如何操作','please help','how do I','另一座银杉花园的停车时间是什么？'])
    assert.deepEqual(f.search(query).results,[],query);
});
test('L04 数字条件不符不撞入近似资料，同编号才命中',()=>{
  const f=fixture('numbers',['问：ZK-4831号补给箱怎样开启？\n答：按蓝色按钮开启。\n']); built(f);
  assert.equal(f.search('ZK-4831号补给箱怎样开启？').results.length,1);
  assert.equal(f.search('ZK-4832号补给箱怎样开启？').results.length,0);
});
test('L05 最多四条、正文总量有界，不截短一个已选片段',()=>{
  const f=fixture('bounds',Array.from({length:6},(_,i)=>qa+'虚构记录序号：'+i+'\n')); built(f);
  const result=f.search(question); assert.equal(result.results.length,4);
  const maximum=Buffer.byteLength(result.results[0].text)-1;
  assert.equal(f.search(question,{maxBytes:maximum}).results.length,0);
  assert.throws(()=>f.search(question,{maxResults:5}),error=>error.code==='lexical_unavailable');
  assert.throws(()=>f.search(question,{maxBytes:2097153}),error=>error.code==='lexical_unavailable');
});
test('L06 映射原字节/启停/来源变化使旧索引整份不可用',()=>{
  const f=fixture('map-generation'); built(f);
  const index=f.read();
  for(const map of [f.mapRaw()+'\n', JSON.stringify({schema_version:2,revision:8,documents:[]}), JSON.stringify({schema_version:2,documents:[{...f.documents[0],enabled:false}]})])
    assert.throws(()=>f.search(question,{index,mapRaw:map}),error=>error.code==='lexical_unavailable');
});
test('L07 摘要被改、片段越界、未映射来源均明确拒绝，不返回旧内容',()=>{
  const f=fixture('integrity'); built(f);
  for(const change of [i=>i.passages[0].text+='伪造正文',i=>i.schema_version=99,i=>i.passages[0].location='custom-documents/another.json',i=>i.passages[0].end_byte++]) {
    const index=f.read(); change(index);
    if(index.passages[0].location.includes('another') || index.passages[0].end_byte!==f.read().passages[0].end_byte) {
      delete index.payload_sha256; index.payload_sha256=hash(canonical(index));
    }
    assert.throws(()=>f.search(question,{index}),error=>error.code==='lexical_unavailable');
  }
});
test('L08 缺失/畸形parsed JSON或pageContent校验失败，旧索引原样保留',()=>{
  const f=fixture('bad-source'); built(f); const file=path.join(f.root,'data/anythingllm/documents',f.documents[0].location);
  for(const value of ['{bad', {pageContent:17}, {pageContent:qa+'\0'}]) {save(file,value); rejectedBuild(f,'source_invalid');}
  fs.unlinkSync(file); rejectedBuild(f,'source_invalid');
});
test('L09 路径穿越/链接目录/链接文件/硬链接不能读取映射以外文件',()=>{
  for(const kind of ['traversal','file-link','directory-link','hard-link']) {
    const f=fixture('unsafe-'+kind); built(f);
    const file=path.join(f.root,'data/anythingllm/documents',f.documents[0].location);
    if(kind==='traversal') save(f.mapPath,{schema_version:2,documents:[{...f.documents[0],location:'../../../../.env'}]});
    if(kind==='file-link') {fs.unlinkSync(file); fs.symlinkSync(path.join(f.root,'.env'),file);}
    if(kind==='hard-link') {fs.unlinkSync(file); fs.linkSync(path.join(f.root,'.env'),file);}
    if(kind==='directory-link') {const dir=path.dirname(file); fs.renameSync(dir,dir+'-old'); fs.symlinkSync(dir+'-old',dir);}
    rejectedBuild(f,kind==='traversal'?'map_invalid':'source_invalid');
  }
});
test('L10 只索引当前启用映射，不读取未映射文件、会话或非pageContent元数据',()=>{
  const f=fixture('allowlist');
  const disabled={...f.documents[0],document_id:'doc_ffffffffffffffff',location:'custom-documents/nonexistent-disabled.json',enabled:false};
  save(f.mapPath,{schema_version:2,documents:[f.documents[0],disabled]});
  save(path.join(f.root,'data/anythingllm/documents/custom-documents/unmapped.json'),'{bad-and-never-read');
  const index=built(f),raw=JSON.stringify(index);
  assert.equal(index.coverage.source_documents,1);
  assert(!/never-read|never-index|synthetic-metadata-not-indexed|unmapped/.test(raw));
  assert.equal(f.search(question).results.length,1);
});
test('L11 重复构建逐字幂等；替换原子且不跟随输出链接',()=>{
  const f=fixture('atomic'); built(f); const first=fs.readFileSync(f.indexPath),inode=fs.statSync(f.indexPath).ino;
  built(f); assert.deepEqual(fs.readFileSync(f.indexPath),first); assert.equal(fs.statSync(f.indexPath).ino,inode);
  const protectedFile=path.join(f.root,'.env'),original=fs.readFileSync(protectedFile);
  fs.unlinkSync(f.indexPath); fs.symlinkSync(protectedFile,f.indexPath);
  const result=f.build(); assert.equal(result.status,1); assert.equal(JSON.parse(result.stdout).error.code,'output_invalid');
  assert.deepEqual(fs.readFileSync(protectedFile),original);
});
test('L12 完整50MiB合法正文生成明确部分索引，保留显式尾问答与首中尾窗口',()=>{
  const paragraph='这一段只记载虚构园艺展品、颜色、木架、花盆和日常维护事项。'.repeat(100)+'\n\n';
  const head='头部窗口标记。\n',middle='中部窗口标记。\n',tail='尾部窗口标记。\n'+qa;
  const available=52428800-Buffer.byteLength(head+middle+tail),left=Math.floor(available/2);
  const fill=bytes=>paragraph.repeat(Math.floor(bytes/Buffer.byteLength(paragraph)))+' '.repeat(bytes%Buffer.byteLength(paragraph));
  const text=head+fill(left)+middle+fill(available-left)+tail;
  assert.equal(Buffer.byteLength(text),52428800);
  const f=fixture('partial',[text]); const index=built(f);
  assert(fs.statSync(f.indexPath).size<=16777216); assert.equal(index.complete,false);
  assert(index.coverage.omitted_bytes>0); assert(index.coverage.reasons.includes('index_capacity'));
  assert.equal(f.search(question).results[0].text.includes(answer),true);
  for(const marker of ['头部窗口标记','中部窗口标记','尾部窗口标记']) assert(index.passages.some(p=>p.text.includes(marker)),marker);
});
test('L13 单个过大明确问答跳过并记录，不能截断后假装完整',()=>{
  const f=fixture('huge-qa',['问：巨型虚构文档的专用口令是什么？\n答：'+'虚构长段。'.repeat(40000)+'\n',qa]);
  const index=built(f); assert.equal(index.complete,false); assert(index.coverage.reasons.includes('passage_too_large'));
  assert.equal(index.coverage.omitted_documents,1); assert.equal(f.search('巨型虚构文档的专用口令是什么？').results.length,0);
  assert.equal(f.search(question).results.length,1);
});
test('L14 相同投影的多parsed位置仍逐个绑定，伪造跨库绑定拒绝',()=>{
  const f=fixture('multi-location',[qa,qa+'第二解析页。']);
  f.documents[1]={...f.documents[1],library_id:f.documents[0].library_id,document_id:f.documents[0].document_id,projection:f.documents[0].projection};
  save(f.mapPath,{schema_version:2,documents:f.documents}); built(f);
  const result=f.search(question); assert.equal(result.results.length,2);
  assert.equal(new Set(result.results.map(item=>item.metadata.docpath)).size,2);
  const index=f.read(); index.passages[0].library_id='kb_ffffffffffffffff'; delete index.payload_sha256; index.payload_sha256=hash(canonical(index));
  assert.throws(()=>f.search(question,{index}),error=>error.code==='lexical_unavailable');
});
test('L15 空启用库输出有效空索引，不从其它数据猜测知识',()=>{
  const f=fixture('empty'); save(f.mapPath,{schema_version:2,documents:[]}); const index=built(f);
  assert.equal(index.complete,true); assert.equal(index.coverage.source_documents,0); assert.deepEqual(f.search(question).results,[]);
});
test('L16 空白前缀和普通正文保持完整，英文不同分词不因去标点误算精确问句',()=>{
  const f=fixture('whitespace',['\n \n'+qa,'Question: Where are the safetylogs stored?\nAnswer: They are stored in the synthetic Zephyr archive.\n']);
  const index=built(f); assert.equal(index.complete,true); assert.equal(f.search(question).results.length,1);
  assert.equal(f.search('Where are the safe tylogs stored?').results.length,0);
  const first=index.passages.filter(p=>p.location===f.documents[0].location).map(p=>p.text).join('');
  assert.equal(first,'\n \n'+qa);
});
test('L17 构建期间映射或源身份改变时拒绝发布，原索引及其inode保持',()=>{
  for(const changed of ['map','source']) {
    const f=fixture('changed-'+changed); built(f);
    const original=fs.readFileSync(f.indexPath), inode=fs.statSync(f.indexPath).ino;
    const code=`import importlib.util,pathlib,sys\nspec=importlib.util.spec_from_file_location('tested',sys.argv[1]);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)\noriginal=m.read_relative\ncalls=0\ndef read(*args):\n global calls\n if args[1]=='data/runtime/knowledge-map.json':\n  calls+=1\n  if calls==2:\n   target=pathlib.Path(sys.argv[2])/('data/runtime/knowledge-map.json' if sys.argv[3]=='map' else 'data/anythingllm/documents/'+sys.argv[4])\n   target.write_bytes(target.read_bytes()+b' ')\n return original(*args)\nm.read_relative=read\ntry:\n m.build_index(sys.argv[2])\nexcept m.LexicalError as error:\n print(error.code)\n sys.exit(17)\nsys.exit(99)\n`;
    const result=spawnSync('python3',['-c',code,script,f.root,changed,f.documents[0].location],{encoding:'utf8'});
    assert.equal(result.status,17,result.stderr); assert.equal(result.stdout.trim(),changed+'_changed');
    assert.deepEqual(fs.readFileSync(f.indexPath),original); assert.equal(fs.statSync(f.indexPath).ino,inode);
  }
});
test('L18 宿主verify只读核验hash/映射/实际parsed来源，部分覆盖可用但旧来源不得通过',()=>{
  const f=fixture('verify'); built(f);
  const before=fs.readFileSync(f.indexPath), inode=fs.statSync(f.indexPath).ino;
  const verify=()=>spawnSync('python3',[script,'verify','--deploy-dir',f.root],{encoding:'utf8',timeout:45000});
  const valid=verify(); assert.equal(valid.status,0,valid.stdout+valid.stderr);
  assert.equal(JSON.parse(valid.stdout).ok,true); assert.equal(JSON.parse(valid.stdout).complete,true);
  assert.deepEqual(fs.readFileSync(f.indexPath),before); assert.equal(fs.statSync(f.indexPath).ino,inode);
  const file=path.join(f.root,'data/anythingllm/documents',f.documents[0].location); fs.appendFileSync(file,' ');
  const changed=verify(); assert.equal(changed.status,1); assert.equal(JSON.parse(changed.stdout).error.code,'source_changed');
  assert.deepEqual(fs.readFileSync(f.indexPath),before); assert.equal(fs.statSync(f.indexPath).ino,inode);
  built(f); fs.chmodSync(f.indexPath,0o644);
  const insecure=verify(); assert.equal(insecure.status,1); assert.equal(JSON.parse(insecure.stdout).error.code,'index_invalid');
  const partial=fixture('verify-partial',['问：巨型虚构正文？\n答：'+'虚构段。'.repeat(50000)+'\n',qa]); built(partial);
  const limited=spawnSync('python3',[script,'verify','--deploy-dir',partial.root],{encoding:'utf8'});
  assert.equal(limited.status,0,limited.stdout+limited.stderr); assert.equal(JSON.parse(limited.stdout).complete,false);
});
test('L19 非标准NaN/Infinity不当作官方JSON接受，旧索引保持',()=>{
  const f=fixture('strict-json'); built(f);
  const file=path.join(f.root,'data/anythingllm/documents',f.documents[0].location);
  for(const invalid of ['NaN','Infinity','-Infinity']) {
    save(file,'{"pageContent":'+JSON.stringify(qa)+',"invalid":'+invalid+'}');
    rejectedBuild(f,'source_invalid');
  }
  const mapped=fixture('strict-json-map'); built(mapped);
  save(mapped.mapPath,mapped.mapRaw().replace(/}$/,',"invalid":NaN}'));
  rejectedBuild(mapped,'map_invalid');
  const indexed=fixture('strict-json-index'); built(indexed);
  save(indexed.indexPath,fs.readFileSync(indexed.indexPath,'utf8').trim().replace(/}$/,',"invalid":Infinity}'));
  const invalidIndex=spawnSync('python3',[script,'verify','--deploy-dir',indexed.root],{encoding:'utf8'});
  assert.equal(invalidIndex.status,1); assert.equal(JSON.parse(invalidIndex.stdout).error.code,'index_invalid');
});
test('L20 完整且锚定的礼貌范围说明可剥离为完整FAQ强命中，不裁改问答',()=>{
  const f=fixture('prefixed-question'); built(f);
  const before=fs.readFileSync(f.indexPath);
  for(const query of ['请根据现有知识库回答：'+question,
    '  请根据现有知识库回答：\n'+question+'\n']) {
    const result=f.search(query);
    assert.equal(result.results.length,1,query);
    assert.equal(result.results[0].lexical.kind,'exact_question');
    assert.equal(result.results[0].text,qa);
    assert.equal(result.results[0].metadata.docpath,f.documents[0].location);
  }
  assert.deepEqual(fs.readFileSync(f.indexPath),before);
});
test('L21 范围说明、否定引用、复述改问、复合问题、短泛问及数字冲突不能绕过门槛',()=>{
  const f=fixture('prefix-negative',[qa,'问：可以吗？\n答：请先说明具体事项。\n',
    '问：ZK-4831号补给箱怎样开启？\n答：按蓝色按钮开启。\n']); built(f);
  for(const query of ['请根据现有知识库回答：另一座银杉花园的停车时间是什么？',
    '本次只检查资料目录，不询问其中任何补给箱事实。',
    '请根据现有知识库回答：可以吗？',
    '请根据现有知识库回答：补给箱',
    '请根据现有知识库回答：ZK-4832号补给箱怎样开启？',
    '请确认编号4832是否适用，再回答：'+question,
    '不要回答“'+question+'”，我真正想问银杉花园的停车时间。',
    '上一个问题是“'+question+'”。现在请回答银杉花园几点关门？',
    question+'另外，银杉花园几点关门？',
    '请根据现有知识库回答：不要回答“'+question+'”，请改答停车时间。']) {
    assert.deepEqual(f.search(query).results,[],query);
  }
});
process.stdout.write(JSON.stringify({layer:'UNIT/CONTRACT',passed,failed,evidence:path.relative(project,evidence),synthetic_only:true})+'\n');
process.exitCode=failed?1:0;
