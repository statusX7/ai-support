'use strict';

// 只检索受管 parsed 正文片段；词法重叠不是概率、向量距离或答案正确性。
// n8n 2.33.0 的 Code runner 按请求字面量匹配内置模块白名单；这里必须与
// NODE_FUNCTION_ALLOW_BUILTIN 中的 `crypto` 一致，不能使用 `node:crypto` 别名。
const crypto = require('crypto');
const MAX_INDEX_BYTES = 16 * 1024 * 1024;
const MAX_PASSAGE_BYTES = 512 * 1024;
const MAX_RESULT_BYTES = 2 * 1024 * 1024;
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
  return matched?normalize(matched[1]):'';
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

function searchKnowledgeLexical({query,index,mapRaw,maxResults=4,maxBytes=MAX_RESULT_BYTES}={}) {
  if(!text(query,40000)||!Number.isInteger(maxResults)||maxResults<1||maxResults>4
    ||!Number.isInteger(maxBytes)||maxBytes<1||maxBytes>MAX_RESULT_BYTES) unavailable('query_invalid');
  const checked=checkedIndex(index,mapRaw), queryTokens=tokens(query);
  const minimum=queryTokens.chinese?3:2;
  const base={results:[],complete:checked.complete,coverage:checked.coverage};
  if(queryTokens.found.size<minimum||queryTokens.found.size>512) return base;
  const normalized=normalize(query), managed=managedQuestion(query), numbers=new Set(query.normalize('NFKC').match(/[0-9]+/g)||[]);
  const candidates=checked.passages.map(passage=>({passage,surface:passage.question||passage.text,
    features:tokens(passage.question||passage.text).found}));
  const frequencies=new Map();
  for(const token of queryTokens.found) frequencies.set(token,candidates.reduce((total,item)=>total+Number(item.features.has(token)),0));
  const weight=token=>1+Math.log(1+(candidates.length+1)/(frequencies.get(token)+1));
  const totalWeight=[...queryTokens.found].reduce((total,token)=>total+weight(token),0);
  const ranked=[];
  for(const item of candidates) {
    const passage=item.passage, candidateNumbers=new Set(passage.text.normalize('NFKC').match(/[0-9]+/g)||[]);
    if([...numbers].some(number=>!candidateNumbers.has(number))) continue;
    const matched=[...queryTokens.found].filter(token=>item.features.has(token));
    const overlap=matched.reduce((total,token)=>total+weight(token),0)/totalWeight;
    const rare=matched.filter(token=>frequencies.get(token)<=Math.max(1,Math.floor(candidates.length*.15))).length;
    const surface=normalize(item.surface);
    let kind, priority;
    if(passage.question && surface===normalized && matched.length===queryTokens.found.size) {kind='exact_question'; priority=3;}
    // 固定礼貌范围说明不应稀释完整具体 FAQ；仍保留词项和全问数字约束。
    else if(passage.question && surface.length>=6 && managed===surface
      && item.features.size>=(/\p{Script=Han}/u.test(passage.question)?3:2)
      && [...item.features].every(token=>queryTokens.found.has(token))) {kind='exact_question'; priority=3;}
    // 其他输入中的完整原问可能属于引用、否定、改问或复合问句；交给向量检索，
    // 不再降级为同一条 FAQ 的词法命中。
    else if(passage.question && normalized.includes(surface)) continue;
    else if(normalized.length>=6 && surface.includes(normalized) && matched.length===queryTokens.found.size) {kind='exact_phrase'; priority=2;}
    else if(matched.length>=minimum && overlap>=.72 && rare>=(queryTokens.chinese?2:1)) {kind='keyword_overlap'; priority=1;}
    else continue;
    ranked.push({passage,kind,priority,overlap});
  }
  ranked.sort((left,right)=>right.priority-left.priority||right.overlap-left.overlap
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
