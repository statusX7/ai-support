'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {spawnSync} = require('node:child_process');

const root = path.resolve(__dirname, '..');
const evidenceRoot = path.join(root, '.work', 'v1.2.0');
fs.mkdirSync(evidenceRoot, {recursive:true});
const work = fs.mkdtempSync(path.join(evidenceRoot, 'limits-'));
let passed = 0;
const pass = (name) => { passed++; process.stdout.write(`通过 UNIT/CONTRACT：${name}\n`); };
const run = (command, args, options={}) => spawnSync(command, args, {cwd:work,encoding:'utf8',...options});
const inspect = (source) => run('bash',[path.join(root,'scripts/knowledge.sh'),'inspect-source',source]);
const validateLibraryName = (name) => run('bash',[path.join(root,'scripts/knowledge.sh'),'validate-library-name',name]);
const shellFunction = (script, expression, ...args) => run('bash',['-c',`source "$1"; shift; ${expression}`,'fixture',path.join(root,'scripts',script),...args]);

try {
  const sources = path.join(work,'中文 资料🙂');
  fs.mkdirSync(sources);
  fs.writeFileSync(path.join(sources,'说明 文档🙂.md'),'# 虚构说明\n');
  fs.writeFileSync(path.join(sources,'问答.TXT'),'虚构答案\n');
  fs.writeFileSync(path.join(sources,'手册.pdf'),'%PDF-1.4\n虚构\n');
  const docx = path.join(sources,'操作 指南🙂.docx');
  let result = run('python3',['-c','import sys,zipfile\np=sys.argv[1]\nwith zipfile.ZipFile(p,"w") as z:\n z.writestr("[Content_Types].xml","<Types/>")\n z.writestr("word/document.xml","<document/>")',docx]);
  assert.equal(result.status,0,result.stderr);
  result=inspect(sources);assert.equal(result.status,0,result.stderr);
  const inventory=JSON.parse(result.stdout);
  assert.equal(inventory.supported_files,4);assert.deepEqual(inventory.formats,{md:1,txt:1,pdf:1,docx:1});assert.equal('files' in inventory,false);
  pass('无部署 inspect-source 对中文空格 Emoji 与四种格式使用实际导入规则且不泄露绝对文件清单');

  const empty=path.join(work,'empty');fs.mkdirSync(empty);
  result=inspect(empty);assert.notEqual(result.status,0);assert.match(result.stderr,/没有可导入/);
  const badPdf=path.join(work,'bad.pdf');fs.writeFileSync(badPdf,'not-pdf');
  result=inspect(badPdf);assert.notEqual(result.status,0);assert.match(result.stderr,/PDF 文件头/);
  pass('空目录与伪 PDF 在登记或索引前被拒绝');

  const linkedTree=path.join(work,'linked-tree');fs.mkdirSync(linkedTree);fs.symlinkSync(path.join(sources,'说明 文档🙂.md'),path.join(linkedTree,'link.md'));
  result=inspect(linkedTree);assert.notEqual(result.status,0);assert.match(result.stderr,/符号链接/);
  const realParent=path.join(work,'real-parent');fs.mkdirSync(realParent);fs.writeFileSync(path.join(realParent,'item.md'),'虚构\n');
  const linkedParent=path.join(work,'linked-parent');fs.symlinkSync(realParent,linkedParent);
  result=inspect(path.join(linkedParent,'item.md'));assert.notEqual(result.status,0);assert.match(result.stderr,/父目录/);
  pass('来源自身、目录成员及父路径的符号链接均被拒绝');

  let permissionFixture;
  try {
    permissionFixture=fs.mkdtempSync('/tmp/crispai-knowledge-permission-');
    fs.chmodSync(permissionFixture,0o755);
    const copiedScripts=path.join(permissionFixture,'scripts');fs.mkdirSync(copiedScripts,{mode:0o755});
    for(const script of ['common.sh','configuration.sh','knowledge.sh']) {
      fs.copyFileSync(path.join(root,'scripts',script),path.join(copiedScripts,script));
      fs.chmodSync(path.join(copiedScripts,script),0o755);
    }
    const permissionSource=path.join(permissionFixture,'source');fs.mkdirSync(permissionSource,{mode:0o755});
    const denied=path.join(permissionSource,'denied');fs.mkdirSync(denied,{mode:0o700});
    fs.writeFileSync(path.join(denied,'secret.md'),'虚构内容\n',{mode:0o600});
    if(process.getuid?.()===0) {
      result=run('python3',['-c',
        'import os,sys\nos.setgroups([])\nos.setgid(65534)\nos.setuid(65534)\nos.execv("/bin/bash",["bash",sys.argv[1],"inspect-source",sys.argv[2]])',
        path.join(copiedScripts,'knowledge.sh'),permissionSource],{cwd:'/tmp'});
    } else {
      fs.chmodSync(denied,0o000);
      result=run('bash',[path.join(copiedScripts,'knowledge.sh'),'inspect-source',permissionSource],{cwd:'/tmp'});
    }
    assert.notEqual(result.status,0);assert.match(result.stderr,/无法完整读取.*权限/);
    pass('目录子树权限错误由统一扫描器可靠返回，不被进程替换吞掉');
  } finally {
    if(permissionFixture) {
      try { fs.chmodSync(path.join(permissionFixture,'source','denied'),0o700); } catch {}
      fs.rmSync(permissionFixture,{recursive:true,force:true});
    }
  }

  const depth16=path.join(work,'depth16');fs.mkdirSync(depth16);let cursor=depth16;
  for(let index=0;index<15;index++){cursor=path.join(cursor,`d${index}`);fs.mkdirSync(cursor);}
  fs.writeFileSync(path.join(cursor,'depth.md'),'边界\n');
  result=inspect(depth16);assert.equal(result.status,0,result.stderr);
  const depth17=path.join(work,'depth17');fs.mkdirSync(depth17);cursor=depth17;
  for(let index=0;index<16;index++){cursor=path.join(cursor,`d${index}`);fs.mkdirSync(cursor);}
  fs.writeFileSync(path.join(cursor,'depth.md'),'越界\n');
  result=inspect(depth17);assert.notEqual(result.status,0);assert.match(result.stderr,/16 层/);
  pass('目录相对条目深度 16 可用，深度 17 在扫描阶段拒绝');

  const promptMax=path.join(work,'prompt-max.md');fs.writeFileSync(promptMax,Buffer.alloc(262144,0x61));
  result=shellFunction('configuration.sh','configuration_prompt_candidate_validate "$1"',promptMax);assert.equal(result.status,0,result.stderr);
  const promptLarge=path.join(work,'prompt-large.md');fs.writeFileSync(promptLarge,Buffer.alloc(262145,0x61));
  result=shellFunction('configuration.sh','configuration_prompt_candidate_validate "$1"',promptLarge);assert.notEqual(result.status,0);
  const promptInvalid=path.join(work,'prompt-invalid.md');fs.writeFileSync(promptInvalid,Buffer.from([0xff]));
  result=shellFunction('configuration.sh','configuration_prompt_candidate_validate "$1"',promptInvalid);assert.notEqual(result.status,0);
  pass('Prompt 精确使用 262144 UTF-8 字节上限，越界与非法 UTF-8 被拒绝');

  const yamlRuntimeDeploy=path.join(work,'yaml-runtime');
  fs.mkdirSync(path.join(yamlRuntimeDeploy,'config'),{recursive:true});fs.mkdirSync(path.join(yamlRuntimeDeploy,'tmp'),{recursive:true});
  fs.writeFileSync(path.join(yamlRuntimeDeploy,'config/runtime.yaml'),'schema_version: 2\nenabled: true\nrevision: 4\napplied_revision: 3\n',{mode:0o640});
  result=shellFunction('configuration.sh','configuration_revision "$1" true',yamlRuntimeDeploy);assert.equal(result.status,0,result.stderr);
  let runtimeValue=JSON.parse(fs.readFileSync(path.join(yamlRuntimeDeploy,'config/runtime.yaml'),'utf8'));
  assert.equal(runtimeValue.revision,5);assert.equal(runtimeValue.applied_revision,5);
  fs.writeFileSync(path.join(yamlRuntimeDeploy,'config/runtime.yaml'),'schema_version: 2\nenabled: true\nrevision: 5\napplied_revision: 2\n',{mode:0o640});
  result=shellFunction('configuration.sh','configuration_mark_applied "$1"',yamlRuntimeDeploy);assert.equal(result.status,0,result.stderr);
  runtimeValue=JSON.parse(fs.readFileSync(path.join(yamlRuntimeDeploy,'config/runtime.yaml'),'utf8'));assert.equal(runtimeValue.applied_revision,5);
  pass('runtime revision 与 mark-applied 共用 YAML 规范化，不再出现校验成功后 jq 提交失败');

  const pdfMax=path.join(work,'pdf-max.pdf');const descriptor=fs.openSync(pdfMax,'w');fs.writeSync(descriptor,Buffer.from('%PDF-'));fs.ftruncateSync(descriptor,50*1024*1024);fs.closeSync(descriptor);
  result=inspect(pdfMax);assert.equal(result.status,0,result.stderr);
  const pdfLarge=path.join(work,'pdf-large.pdf');const largeDescriptor=fs.openSync(pdfLarge,'w');fs.writeSync(largeDescriptor,Buffer.from('%PDF-'));fs.ftruncateSync(largeDescriptor,50*1024*1024+1);fs.closeSync(largeDescriptor);
  result=inspect(pdfLarge);assert.notEqual(result.status,0);assert.match(result.stderr,/50 MiB/);
  pass('单文档 50 MiB 边界可用，50 MiB 加 1 字节在读取内容前拒绝');

  const catalog=(count,name='库')=>({schema_version:2,revision:1,libraries:Array.from({length:count},(_,index)=>({
    id:`kb_${index.toString(16).padStart(16,'0')}`,name,enabled:true,revision:1,documents:[],status:'pending',last_sync:null,error:null
  }))});
  const catalogPath=path.join(work,'catalog.json');fs.writeFileSync(catalogPath,JSON.stringify(catalog(100)));
  result=shellFunction('knowledge.sh','knowledge_catalog_validate "$1"',catalogPath);assert.equal(result.status,0,result.stderr);
  fs.writeFileSync(catalogPath,JSON.stringify(catalog(101)));
  result=shellFunction('knowledge.sh','knowledge_catalog_validate "$1"',catalogPath);assert.notEqual(result.status,0);
  fs.writeFileSync(catalogPath,JSON.stringify(catalog(1,'人'.repeat(34))));
  result=shellFunction('knowledge.sh','knowledge_catalog_validate "$1"',catalogPath);assert.notEqual(result.status,0);
  result=validateLibraryName('人'.repeat(33));assert.equal(result.status,0,result.stderr);assert.equal(JSON.parse(result.stdout).utf8_bytes,99);
  result=validateLibraryName('人'.repeat(34));assert.notEqual(result.status,0);assert.match(result.stderr,/100 个 UTF-8 字节/);
  pass('命名库上限 100，库名按 100 UTF-8 字节而不是字符计数');

  const oversizedArchive=path.join(work,'oversized.tar.gz');fs.closeSync(fs.openSync(oversizedArchive,'w'));fs.truncateSync(oversizedArchive,128*1024*1024+1);
  result=shellFunction('migration.sh','migration_archive_preflight "$1"',oversizedArchive);assert.notEqual(result.status,0);assert.match(result.stderr,/128 MiB/);
  const membersArchive=path.join(work,'members.tar.gz');
  result=run('python3',['-c','import sys,tarfile\np=sys.argv[1]\nwith tarfile.open(p,"w:gz") as t:\n for i in range(20001):\n  x=tarfile.TarInfo(f"entry-{i}");x.type=tarfile.DIRTYPE;t.addfile(x)',membersArchive]);assert.equal(result.status,0,result.stderr);
  result=shellFunction('migration.sh','migration_archive_preflight "$1"',membersArchive);assert.notEqual(result.status,0);assert.match(result.stderr,/20000/);
  pass('业务迁移包压缩体积 128 MiB 与成员 20000 的边界在解压前执行');

  process.stdout.write(JSON.stringify({layer:'UNIT/CONTRACT',passed,failed:0,evidence:path.relative(root,work),host:os.platform()})+'\n');
} catch (error) {
  console.error(error);
  process.exitCode=1;
}
