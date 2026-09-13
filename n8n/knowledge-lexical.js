'use strict';

// 只检索受管 parsed 正文片段；词法重叠不是概率、向量距离或答案正确性。
// n8n 2.33.0 的 Code runner 按请求字面量匹配内置模块白名单；这里必须与
// NODE_FUNCTION_ALLOW_BUILTIN 中的 `crypto` 一致，不能使用 `node:crypto` 别名。
const crypto = require('crypto');
const MAX_INDEX_BYTES = 16 * 1024 * 1024;
const MAX_PASSAGE_BYTES = 512 * 1024;
const MAX_RESULT_BYTES = 2 * 1024 * 1024;
const MAX_SYNONYM_BYTES = 4096;
const ALGORITHM = 'crispai-lexical-v1';
const hash = value => crypto.createHash('sha256').update(value).digest('hex');
const canonical = value => JSON.stringify(value, (_key, item) => item && typeof item === 'object' && !Array.isArray(item)
  ? Object.fromEntries(Object.keys(item).sort().map(key => [key, item[key]])) : item);
const record = value => value !== null && typeof value === 'object' && !Array.isArray(value);
const text = (value, maximum, empty=false) => typeof value === 'string' && !value.includes('\0')
  && (empty || Boolean(value.trim())) && Buffer.byteLength(value, 'utf8') <= maximum
  && Buffer.from(value, 'utf8').toString('utf8') === value;
const integer = value => Number.isSafeInteger(value) && value >= 0;
const digest = value => typeof value === 'string' && /^[a-f0-9]{64}$/.test(value);
function unavailable(reason) {
  const error = new Error('词法补召回索引不可用；本次不使用过期或未校验资料。');
  error.code = 'lexical_unavailable'; error.reason = reason; throw error;
}
function mapping(raw) {
  if (!text(raw, MAX_INDEX_BYTES)) unavailable('map_invalid');
  let map;
  try {map=JSON.parse(raw);} catch (_) {unavailable('map_invalid');}
  if (!record(map) || map.schema_version !== 2 || !Array.isArray(map.documents)) unavailable('map_invalid');
  const documents = new Map();
  for (const item of map.documents) {
    if (!record(item) || !/^kb_(?:[a-f0-9]{16}|default)$/.test(item.library_id || '')
      || !/^doc_[a-f0-9]{16}$/.test(item.document_id || '') || !text(item.projection,255)
      || /[\\/;,\x00-\x1f\x7f]/.test(item.projection) || !text(item.location,2048)
      || /[\\\x00-\x1f\x7f]/.test(item.location) || item.location.split('/').length<2
      || item.location.split('/').some(part=>!part||part==='.'||part==='..') || !item.location.endsWith('.json')
      || Object.hasOwn(item,'enabled') && typeof item.enabled !== 'boolean') unavailable('map_invalid');
    if(item.enabled === false) continue;
    if(documents.has(item.location)) unavailable('map_invalid');
    documents.set(item.location,item);
  }
  return documents;
}
function checkedIndex(input, mapRaw) {
  let index;
  try {
    if(typeof input === 'string') {
      if(!text(input,MAX_INDEX_BYTES)) unavailable('index_invalid');
      index=JSON.parse(input);
    } else {
      const raw=JSON.stringify(input);
      if(!text(raw,MAX_INDEX_BYTES)) unavailable('index_invalid');
      index=JSON.parse(raw);
    }
  } catch (_) {unavailable('index_invalid');}
  if(!record(index)||index.schema_version!==1||index.algorithm!==ALGORITHM||!digest(index.map_sha256)
    ||!digest(index.payload_sha256)||typeof index.complete!=='boolean'||!record(index.coverage)||!Array.isArray(index.passages)) unavailable('index_invalid');
  const {payload_sha256:expected,...payload}=index;
  let actual;
  try {actual=hash(canonical(payload));} catch (_) {unavailable('index_invalid');}
  if(actual!==expected) unavailable('hash_mismatch');
  const documents=mapping(mapRaw);
  if(index.map_sha256!==hash(mapRaw)) unavailable('map_mismatch');
  const coverage=index.coverage;
  if(!['source_documents','indexed_documents','omitted_documents','source_bytes','indexed_bytes','omitted_bytes'].every(key=>integer(coverage[key]))
    ||coverage.source_documents!==documents.size||coverage.indexed_documents+coverage.omitted_documents!==coverage.source_documents
    ||coverage.indexed_bytes+coverage.omitted_bytes!==coverage.source_bytes||index.complete!==(coverage.omitted_bytes===0)
    ||!Array.isArray(coverage.reasons)||coverage.reasons.some(reason=>!['index_capacity','passage_too_large'].includes(reason))) unavailable('index_invalid');
  let indexedBytes=0;
  const seen=new Set(), positions=new Map(), identities=new Map();
  for(const passage of index.passages) {
    const source=record(passage) && documents.get(passage.location);
    if(!source||!['library_id','document_id','projection','location'].every(key=>passage[key]===source[key])
      ||!text(passage.text,MAX_PASSAGE_BYTES,true)||!text(passage.question,MAX_PASSAGE_BYTES,true)
      ||!digest(passage.text_sha256)||hash(passage.text)!==passage.text_sha256
      ||!digest(passage.parsed_sha256)||!digest(passage.content_sha256)
      ||!integer(passage.start_byte)||!integer(passage.end_byte)||passage.end_byte<=passage.start_byte||passage.end_byte-passage.start_byte!==Buffer.byteLength(passage.text)
      ||passage.start_byte<(positions.get(passage.location)||0)) unavailable('passage_invalid');
    const identity={};
    for(const key of ['library_id','document_id','location','start_byte','end_byte','text_sha256']) identity[key]=passage[key];
    if(passage.id!=='lexical-'+hash(canonical(identity))||seen.has(passage.id)) unavailable('passage_invalid');
    const original=identities.get(passage.location), current=passage.parsed_sha256+'|'+passage.content_sha256;
    if(original && original!==current) unavailable('passage_invalid');
    if(passage.question && !normalize(passage.text).includes(normalize(passage.question))) unavailable('passage_invalid');
    identities.set(passage.location,current); seen.add(passage.id); positions.set(passage.location,passage.end_byte);
    indexedBytes+=Buffer.byteLength(passage.text);
  }
  if(indexedBytes!==coverage.indexed_bytes||identities.size!==coverage.indexed_documents) unavailable('index_invalid');
  return index;
}
function normalize(value) {
  return value.normalize('NFKC').toLowerCase().replace(/[\p{P}\p{S}\s\p{Cf}]+/gu,'');
}
function managedQuestion(value) {
  // 这里只剥离一段完整、锚定的礼貌范围说明；它不是管理员身份或授权标记。
  // 任意访客也可能输入相同文字，因此引用、否定或复合问句不能因为正文中
  // 碰巧包含一条 FAQ 原问就跳过向量检索。
  const matched=value.normalize('NFKC').match(/^\s*请根据现有知识库回答\s*:\s*([\s\S]*?)\s*$/u);
  return matched?matched[1]:'';
}
const CHINESE_COMMON=/请问|告诉我|帮帮我|帮我|怎么办|怎么|如何|什么|哪个|是否|可以|需要|知道|一下|我要|咨询|问题|方法|使用|操作|为什么|谢谢|请|的|是|吗|呢|了/gu;
const ENGLISH_COMMON=new Set(['a','an','the','and','or','i','we','you','my','your','how','do','does','did','to','of','for','in','on','is','are','can','could','would','please','help','use','it','this','that','what']);
function tokens(value) {
  const normalized=value.normalize('NFKC').toLowerCase().replace(CHINESE_COMMON,' ');
  const found=new Set(); let chinese=false;
  for(const part of normalized.match(/[\p{Script=Han}]+|[a-z0-9]+/gu)||[]) {
    if(/\p{Script=Han}/u.test(part)) {
      chinese=true; const letters=Array.from(part);
      for(let i=0;i+1<letters.length;i++) found.add(letters[i]+letters[i+1]);
    } else if(part.length>=2&&!ENGLISH_COMMON.has(part)) found.add(part);
  }
  return {found,chinese};
}

// 这是一组有界、与具体知识正文无关的紧义中文概念，只用于 FAQ 词法兜底。
// 它不改变索引、映射或启停校验，也不把该分支提升为可跳过向量的 strong 命中。
const INVOICE_TERMS=['开具发票','发票开具','开发票','开票','发票'];
const CHINESE_CONCEPTS=[
  ['capability',['是否支持','是否可以','可不可以','能不能','不支持','不允许','不能','支持','提供','可以','能够','能否','可否','允许','能']],
  ['invoice',INVOICE_TERMS],
  ['credential',['票据','凭证','凭条']],
  ['storage',['临时保管','寄存','存放','保管','暂存']],
  ['luggage',['行李箱','旅行箱','箱包','箱件','箱子','行李','箱']],
  ['order',['订购单','订单']],
  ['change',['修改','更改','变更','改动']],
  ['account',['账户','账号','帐号']],
  ['sign_in',['登录','登入','登陆']],
  ['passcode',['密码','口令']],
  ['open',['开启','打开','启封']],
  ['close',['关闭','关停']],
  ['remove',['删除','移除','清除']],
  ['lookup',['查询','查看','查找']],
  ['purchase',['购买','订购','选购']],
  ['booking',['预约','预订']],
  ['refund',['退款','退费']],
  ['cost',['费用','价钱','价格']],
  ['expiry',['到期','过期','失效']],
].map(([name,terms])=>({name,terms:[...terms].sort((left,right)=>right.length-left.length)}));
const SYNONYM_ANCHOR_COMMON=/不好意思|打扰一下|麻烦您|麻烦你|能不能|是不是|能否|您好|你好|麻烦|劳驾|想请问|请教一下|怎样|哪里|哪儿|想问|想要|请教|关于|有关|相关|这个|那个|事情|情况|内容|资料|服务|业务|事项|功能|办理|开具|现在|目前|这次|就是|确实|真的|由|嗨/gu;
const NON_MODAL_NENG_BEFORE=new Set(Array.from('功性技智节动势热电光核本潜万才可全储'));
const NON_MODAL_NENG_AFTER=new Set(Array.from('耗源力量效率级手够见谱带态障'));
function stripModalNeng(value) {
  const letters=Array.from(value); let changed=false;
  for(let index=0;index<letters.length;index++) {
    if(letters[index]!=='能'||NON_MODAL_NENG_BEFORE.has(letters[index-1]||'')
      ||NON_MODAL_NENG_AFTER.has(letters[index+1]||'')) continue;
    letters[index]=' '; changed=true;
  }
  return {value:letters.join(''),changed};
}
function longestTerms(value,terms) {
  const matched=[]; let remaining=value;
  for(const term of terms) {
    if(term==='能') {
      const stripped=stripModalNeng(remaining);
      if(stripped.changed) {matched.push(term); remaining=stripped.value;}
      continue;
    }
    if(!remaining.includes(term)) continue;
    matched.push(term); remaining=remaining.split(term).join(' ');
  }
  return matched;
}
function semanticProfile(value) {
  const normalized=value.normalize('NFKC').toLowerCase().replace(/[\p{P}\p{S}\s\p{Cf}]+/gu,' '),concepts=new Map(); let residual=normalized;
  for(const concept of CHINESE_CONCEPTS) {
    const matched=longestTerms(normalized,concept.terms);
    if(matched.length) concepts.set(concept.name,new Set(matched));
    for(const term of concept.terms) residual=term==='能'?stripModalNeng(residual).value:residual.split(term).join(' ');
  }
  residual=residual.replace(SYNONYM_ANCHOR_COMMON,' ');
  const lexicalResidual=residual.replace(CHINESE_COMMON,' '),qualifierCharacters=[],isolatedCharacters=[];
  for(const unit of lexicalResidual.match(/[\p{Script=Han}]+|[\p{L}\p{N}]+/gu)||[]) {
    if(!/\p{Script=Han}/u.test(unit)&&ENGLISH_COMMON.has(unit)) continue;
    const characters=Array.from(unit);
    qualifierCharacters.push(...characters);
    if(characters.length===1) isolatedCharacters.push(characters[0]);
  }
  return {concepts,anchors:tokens(residual).found,
    qualifierCharacters:qualifierCharacters.sort(),isolatedCharacters:new Set(isolatedCharacters)};
}
const POLITE_QUESTION_PREFIX=/^(?:你好|您好|嗨|麻烦(?:你|您)?|劳驾|打扰(?:一下)?|不好意思|请问|想请问|请教(?:一下)?)$/u;
const INTENT_QUESTION_PREFIX=/^(?:我|我们)(?:也|还)?(?:想|希望|需要)(?:(?:知道|了解|咨询)(?:一下|下)?|(?:向|跟)(?:您|你)(?:咨询|了解)(?:一下|下)?)$/u;
const COMPLEMENT_MODIFIER='(?:也|还|只|要|现在|目前|这次|就是|确实|真的)';
const COMPLEMENT_INTENT='(?:想要|想|希望|需要|要)';
const COMPLEMENT_INVOICE_PREFIX=new RegExp('^(?:我|我们)(?:(?:'+COMPLEMENT_MODIFIER+')?'+COMPLEMENT_INTENT
  +'|'+COMPLEMENT_INTENT+'(?:'+COMPLEMENT_MODIFIER+')?)('+INVOICE_TERMS.join('|')+')$','u');
const COMPLEMENT_SITE_REFERENCE=/^(?:本站|平台|这边|这里|店里)/u;
function exhaustCapabilityClause(value) {
  let residual=value.normalize('NFKC').replace(/\p{Cf}/gu,'');
  const capability=CHINESE_CONCEPTS.find(concept=>concept.name==='capability');
  for(const term of capability.terms) residual=term==='能'?stripModalNeng(residual).value:residual.split(term).join(' ');
  residual=residual.replace(/是不是|办理|服务|业务|事项|功能|吗|呢|么|吧|呀|啊|嘛/gu,' ')
    .replace(/[\s?？!！。]+/gu,'');
  return residual.length===0;
}
function safeCommaQuestion(value) {
  const parts=value.split(/[,，]/u);
  if(parts.length!==2) return null;
  const prefix=(parts[0]||'').replace(/\s+/gu,'');
  if(POLITE_QUESTION_PREFIX.test(prefix)||INTENT_QUESTION_PREFIX.test(prefix)) return {kind:'empty_prefix',body:parts[1]};
  const complement=prefix.match(COMPLEMENT_INVOICE_PREFIX);
  if(!complement
    ||(value.match(/[?？]/gu)||[]).length!==1||!/[?？]\s*$/u.test(value)) return null;
  const rightClause=parts[1].trimStart(),siteReference=rightClause.match(COMPLEMENT_SITE_REFERENCE);
  const cleanedRight=siteReference?rightClause.slice(siteReference[0].length):rightClause;
  const left=semanticProfile(parts[0]),right=semanticProfile(cleanedRight);
  const leftSubstantive=[...left.concepts.keys()].filter(name=>name!=='capability');
  const rightSubstantive=[...right.concepts.keys()].filter(name=>name!=='capability');
  if(leftSubstantive.length!==1||leftSubstantive[0]!=='invoice'||left.concepts.has('capability')
    ||rightSubstantive.length!==0||!right.concepts.has('capability')||right.anchors.size!==0
    ||!exhaustCapabilityClause(cleanedRight)) return null;
  // 丢弃的仅是上面已完整约束的语法前缀；invoice 业务概念和能力问句均保留。
  return {kind:'complementary',body:complement[1]+' '+cleanedRight};
}
function unsafeApproximateContent(normalized) {
  if(/[`'"<>\p{Ps}\p{Pe}\p{Pi}\p{Pf}]/u.test(normalized)
    ||/[;；、:：/／\\|｜—–―…]/u.test(normalized)
    ||/[\u0009-\u000d\u0085\u2028\u2029\p{Zl}\p{Zp}]/u.test(normalized)) return true;
  // 只识别元指令式否定/改问；“是不是不能办理”这类普通能力疑问仍可检索。
  return /(?:请勿|不要|别|无需|不必)(?:再|去|继续|直接)?(?:回答|回复|提及|讨论|谈|说|查找|检索)/u.test(normalized)
    ||/(?:请勿|不要|别|无需|不必)(?:按|按照|依据)[^。！？!?；;]{0,80}(?:回答|回复|作答)/u.test(normalized)
    ||/(?:不是|并非)(?:在|想|要)?(?:问|询问|咨询|讨论)/u.test(normalized)
    ||/(?:不是|并非)(?:这个|我的|所问的)?问题/u.test(normalized)
    ||/(?:问|询问|咨询|讨论)的?(?:不是|并非)/u.test(normalized)
    ||/(?:不是|并非)[^。！？!?]{0,80}而是/u.test(normalized)
    ||/请\s*(?:忽略|无视)/u.test(normalized)
    ||/(?:忽略|无视)(?:前述|此前|上文|以上|之前|原有|这些)(?:要求|指令|内容|问题|资料)/u.test(normalized)
    ||/(?:改问|改答|真正想问|只想(?:问|了解)|而(?:是|要)(?:问|了解|咨询)|另外|此外|同时|以及|并且|或者|还是|顺便|另一个问题|再问|还想问)/u.test(normalized);
}
function safeApproximateQuestion(value) {
  const normalized=value.normalize('NFKC').replace(/\p{Cf}/gu,'');
  if(unsafeApproximateContent(normalized)||(normalized.match(/[?？]/gu)||[]).length>1
    ||/[。！？!?][\s\S]*[\p{L}\p{N}]/u.test(normalized)) return false;
  if(/\p{Script=Han}/u.test(normalized)&&/[,，]/u.test(normalized)
    &&safeCommaQuestion(normalized)===null) return false;
  return true;
}
function actualSynonym(left,right,name) {
  const leftTerms=left.concepts.get(name),rightTerms=right.concepts.get(name);
  return leftTerms&&rightTerms&&[...leftTerms].some(term=>!rightTerms.has(term))
    &&[...rightTerms].some(term=>!leftTerms.has(term));
}
function semanticRequirements(profile) {
  const names=[...profile.concepts.keys()];
  const substantive=names.filter(name=>name!=='capability');
  const core=substantive.filter(name=>name!=='luggage');
  return {substantive,core,required:core.length?core:(substantive.length?substantive:names)};
}
function sameSet(left,right) {
  return left.size===right.size&&[...left].every(value=>right.has(value));
}
function questionNumbers(value) {
  return value.normalize('NFKC').match(/[0-9]+/g)||[];
}
function sameQuestionNumbers(left,right) {
  const leftNumbers=questionNumbers(left),rightNumbers=questionNumbers(right);
  return leftNumbers.length===rightNumbers.length
    &&leftNumbers.every((value,index)=>value===rightNumbers[index]);
}
function qualifierCompatible(left,right) {
  if(!left||!right) return false;
  const leftCore=new Set(semanticRequirements(left).core),rightCore=new Set(semanticRequirements(right).core);
  if(!sameSet(leftCore,rightCore)||!sameSet(left.anchors,right.anchors)
    ||left.qualifierCharacters.length!==right.qualifierCharacters.length) return false;
  return left.qualifierCharacters.every((value,index)=>value===right.qualifierCharacters[index]);
}
function safeCandidateStructure(value) {
  if(safeApproximateQuestion(value)) return true;
  const normalized=value.normalize('NFKC').replace(/\p{Cf}/gu,'');
  if(unsafeApproximateContent(normalized)||/[,，。！!]/u.test(normalized)
    ||(normalized.match(/[?？]/gu)||[]).length!==2||!/[?？]\s*$/u.test(normalized)) return false;
  const parts=normalized.split(/[?？]/u);
  if(parts.length!==3||!parts[0].trim()||!parts[1].trim()||parts[2].trim()) return false;
  const left=semanticProfile(parts[0]),right=semanticProfile(parts[1]);
  const leftCore=new Set(semanticRequirements(left).core),rightCore=new Set(semanticRequirements(right).core);
  const homogeneous=leftCore.size>0&&sameSet(leftCore,rightCore)&&qualifierCompatible(left,right);
  const elliptical=(leftCore.size>0&&rightCore.size===0&&right.concepts.size===1&&right.concepts.has('capability')
      &&right.anchors.size===0&&right.qualifierCharacters.length===0)
    ||(rightCore.size>0&&leftCore.size===0&&left.concepts.size===1&&left.concepts.has('capability')
      &&left.anchors.size===0&&left.qualifierCharacters.length===0);
  return (homogeneous||elliptical)&&sameQuestionNumbers(parts[0],parts[1]);
}

function searchKnowledgeLexical({query,index,mapRaw,maxResults=4,maxBytes=MAX_RESULT_BYTES}={}) {
  if(!text(query,40000)||!Number.isInteger(maxResults)||maxResults<1||maxResults>4
    ||!Number.isInteger(maxBytes)||maxBytes<1||maxBytes>MAX_RESULT_BYTES) unavailable('query_invalid');
  const checked=checkedIndex(index,mapRaw), queryTokens=tokens(query);
  const minimum=queryTokens.chinese?3:2;
  const base={results:[],complete:checked.complete,coverage:checked.coverage};
  if(queryTokens.found.size<minimum||queryTokens.found.size>512) return base;
  const normalized=normalize(query),managedRaw=managedQuestion(query),managed=managedRaw?normalize(managedRaw):'';
  const synonymSafe=text(query,MAX_SYNONYM_BYTES)&&safeCandidateStructure(query);
  const approximateSafe=synonymSafe;
  const commaQuestion=safeCommaQuestion(query.normalize('NFKC').replace(/\p{Cf}/gu,''));
  const semanticQuery=commaQuestion?commaQuestion.body:query;
  const querySemantic=synonymSafe?semanticProfile(semanticQuery):null;
  const semanticRule=querySemantic?semanticRequirements(querySemantic):null;
  const candidates=checked.passages.map(passage=>{
    const surface=passage.question||passage.text;
    const bounded=text(surface,MAX_SYNONYM_BYTES);
    return {passage,surface,features:tokens(surface).found,
      approximateSafe:passage.question?bounded&&safeCandidateStructure(passage.question):bounded,
      semantic:synonymSafe&&bounded?semanticProfile(surface):null};
  });
  const frequencies=new Map();
  for(const token of queryTokens.found) frequencies.set(token,candidates.reduce((total,item)=>total+Number(item.features.has(token)),0));
  const weight=token=>1+Math.log(1+(candidates.length+1)/(frequencies.get(token)+1));
  const totalWeight=[...queryTokens.found].reduce((total,token)=>total+weight(token),0);
  const ranked=[];
  for(const item of candidates) {
    const passage=item.passage;
    const matched=[...queryTokens.found].filter(token=>item.features.has(token));
    const overlap=matched.reduce((total,token)=>total+weight(token),0)/totalWeight;
    const rare=matched.filter(token=>frequencies.get(token)<=Math.max(1,Math.floor(candidates.length*.15))).length;
    const surface=normalize(item.surface);
    const approximateCompatible=approximateSafe&&item.approximateSafe
      &&sameQuestionNumbers(query,item.surface)&&qualifierCompatible(querySemantic,item.semantic);
    let kind, priority,semanticRank=0;
    if(passage.question&&safeCandidateStructure(query)&&safeCandidateStructure(passage.question)
      &&surface===normalized&&matched.length===queryTokens.found.size) {kind='exact_question'; priority=3;}
    // 固定礼貌范围说明不应稀释完整具体 FAQ；仍保留词项和全问数字约束。
    else if(passage.question && surface.length>=6 && managed===surface
      &&safeCandidateStructure(managedRaw)&&safeCandidateStructure(passage.question)
      && item.features.size>=(/\p{Script=Han}/u.test(passage.question)?3:2)
      && [...item.features].every(token=>queryTokens.found.has(token))) {kind='exact_question'; priority=3;}
    // 其他输入中的完整原问可能属于引用、否定、改问或复合问句；交给向量检索，
    // 不再降级为同一条 FAQ 的词法命中。
    else if(passage.question && normalized.includes(surface)) continue;
    else if(!approximateCompatible) continue;
    else if(normalized.length>=6 && surface.includes(normalized) && matched.length===queryTokens.found.size) {kind='exact_phrase'; priority=2;}
    else if(matched.length>=minimum&&overlap>=.72&&rare>=(queryTokens.chinese?2:1)) {kind='keyword_overlap'; priority=1;}
    else if(synonymSafe&&item.semantic&&surface.length>=4&&querySemantic.concepts.size>0) {
      const shared=[...querySemantic.concepts.keys()].filter(name=>item.semantic.concepts.has(name));
      const {substantive,required}=semanticRule;
      const candidateSubstantive=[...item.semantic.concepts.keys()].filter(name=>name!=='capability');
      const anchors=[...querySemantic.anchors].filter(token=>item.semantic.anchors.has(token));
      const explicitAnchorless=querySemantic.anchors.size===0&&item.semantic.anchors.size===0
        &&substantive.length===1&&candidateSubstantive.length===1
        &&substantive[0]==='invoice'&&candidateSubstantive[0]===substantive[0];
      if(required.some(name=>!item.semantic.concepts.has(name))||(!explicitAnchorless&&anchors.length<1)
        ||!shared.some(name=>actualSynonym(querySemantic,item.semantic,name))) continue;
      kind='synonym_overlap'; priority=.5; semanticRank=shared.length+Math.min(anchors.length,8)/10;
    }
    else continue;
    ranked.push({passage,kind,priority,overlap,semanticRank});
  }
  ranked.sort((left,right)=>right.priority-left.priority||right.semanticRank-left.semanticRank||right.overlap-left.overlap
    ||left.passage.location.localeCompare(right.passage.location,'en')||left.passage.start_byte-right.passage.start_byte);
  let bytes=0;
  for(const item of ranked) {
    const passage=item.passage, size=Buffer.byteLength(passage.text);
    if(bytes+size>maxBytes) continue;
    base.results.push({id:passage.id,text:passage.text,
      metadata:{title:passage.projection,docpath:passage.location,library_id:passage.library_id,document_id:passage.document_id},
      lexical:{kind:item.kind,overlap:Math.round(item.overlap*1000)/1000,score_basis:'lexical_not_probability'}});
    bytes+=size;
    if(base.results.length===maxResults) break;
  }
  return base;
}

module.exports={searchKnowledgeLexical};
