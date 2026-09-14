'use strict';

// 只有明确的产品动作才允许使用固定文案。推理、检索或投递故障必须留在
// 内部持久责任中，不能伪装成访客表达不清，也不能用另一句空泛追问结题。
const VISITOR_FALLBACKS = Object.freeze({
  clarification: '',
  image: '',
  handoff_offer: '需要人工协助吗？请点击下方按钮确认。',
  handoff_ack: '好的，已收到您的人工协助请求。',
  welcome: '您好，请告诉我您遇到的具体问题。',
  menu: '请告诉我您正在进行哪项操作，以及遇到了什么问题。',
});

// 仅列出项目历史版本自己生成过的整条空泛结题文案。调用方只能将它用于
// 本项目生成的计划或 Provider 最终正文，不能扫描访客输入、用户 Prompt、
// 知识原文和业务固定回复。
const LEGACY_GENERIC_NON_ANSWERS = new Set([
  '你最希望先解决哪一处？可以把具体情况、相关提示和已经尝试的方法一起告诉我。',
  '请把图片中的关键信息或报错文字贴出来，并说明你正在进行的操作和希望解决的问题。',
  '知识库暂时没有足够信息，请换一种方式描述问题。',
  '目前知识还不足以确认，请补充您遇到的具体情况。',
  '当前答案可信度不足，请补充更多问题细节。',
  '现有资料还不足以确定答案，请补充更多细节。',
].map((value) => value.normalize('NFKC').trim().replace(/\s+/gu, ' ')));

function legacyGenericNonAnswer(value) {
  return typeof value === 'string'
    && LEGACY_GENERIC_NON_ANSWERS.has(value.normalize('NFKC').trim().replace(/\s+/gu, ' '));
}

function visitorFallbackFor(purpose, context = 'text') {
  if (context === 'image') return VISITOR_FALLBACKS.image;
  if (purpose === 'handoff_offer' || purpose === 'handoff_offer_reminder') return VISITOR_FALLBACKS.handoff_offer;
  if (purpose === 'handoff_ack') return VISITOR_FALLBACKS.handoff_ack;
  if (purpose === 'welcome') return VISITOR_FALLBACKS.welcome;
  if (purpose === 'menu' || purpose === 'menu_missing') return VISITOR_FALLBACKS.menu;
  return '';
}

// 只识别“整条可见答复主要在说当前不能回答，并要求等待或重试”的机械兜底。
// 不能用这个函数扫描或改写用户 Prompt、知识、历史；包含真实排障步骤或业务事实
// 的说明会留下实质残余，因此不会因为引用了相同词语而被误判。
function mechanicalFailureAnswer(value) {
  if (typeof value !== 'string') return false;
  const visible = value.trim().slice(0, 8000);
  if (!visible) return false;
  const compact = visible.normalize('NFKC').toLowerCase().replace(/[\p{Cc}\p{Cf}]/gu, '')
    .replace(/[\p{P}\p{S}\s]+/gu, '');
  if (!compact) return false;
  // 常见的非结构化安全拒绝是有效模型结果，不得通过换源绕过。
  if (/^(?:(?:真的|非常|十分|实在|很)?(?:抱歉|对不起|不好意思))?我(?:无法|不能|不便)(?:回答|答复)(?:(?:这个|该|此)?问题|(?:关于|针对|对于)?(?:您|你)?(?:的)?[\p{L}\p{N}]{1,64}(?:的)?(?:问题|咨询|请求))(?:了|呢)?$/u.test(compact)) return false;
  // 平台、业务服务或接口的单纯可用性陈述可能就是用户询问的事实；没有
  // “稍后再试”等机械重试要求时，不把它当作模型自身故障。
  if (/^(?:当前|目前|现在|此刻)?(?:平台|服务|接口)(?:当前|目前|现在|正在|正)?(?:暂时|临时)?(?:繁忙|忙碌|忙|不可用|异常|故障|维护|升级|更新|拥堵|超时|过载)(?:中|了|时)?$/u.test(compact)) return false;
  if (/^(?:当前|目前|现在|此刻)?(?:请求|访问|咨询|用户|访客|客户|人数)(?:量|人数)?(?:当前|目前|现在|正在|正)?(?:较多|过多|太多|较大|过大|拥堵|繁忙|高峰)(?:中|了|时)?$/u.test(compact)) return false;
  const time = '(?:当前|目前|现在|此刻|这会儿|这会)?';
  const subject = '(?:(?:我|我们|这边)|(?:ai(?:客服|助手|系统|模型)?|自动客服|智能客服|在线客服|机器人(?:客服|助手)?|客服系统|模型服务|客服|系统|服务|服务器|接口|平台|网络|后台|助手|模型))?';
  const object = '(?:(?:这个|该|此)(?:问题|咨询|请求)?|(?:(?:关于|针对|对于)?(?:您|你)?(?:的)?[\\p{L}\\p{N}]{1,32}(?:的)?(?:问题|咨询|请求))|(?:您|你)(?:的)?(?:问题|咨询|请求)?)?';
  const failures = [
    new RegExp(time + subject + time + '(?:暂时|临时)?(?:无法|不能|不可|没法|没办法|没有办法|未能)(?:及时|正常)?(?:(?:为|给)(?:您|你))?(?:进行)?(?:回复|回答|答复|回应|处理|响应|提供(?:回复|回答|答复|帮助|服务)|帮(?:助)?(?:您|你)?)' + object + '(?:中|了)?', 'gu'),
    new RegExp(time + subject + time + '(?:暂时|临时)?(?:回复|回答|答复|回应|处理|响应|答)(?:不了|不上来|不出来|不上|失败)(?:了)?' + object, 'gu'),
    /(?:当前|目前|现在|此刻|这会儿|这会)?(?:ai(?:客服|助手|系统|模型)?|自动客服|智能客服|在线客服|机器人(?:客服|助手)?|客服系统|模型服务|客服|系统|服务|服务器|接口|平台|网络|后台|助手|模型)?(?:当前|目前|现在|正在|正|有点|太)?(?:暂时|临时)?(?:繁忙|忙碌|忙|不可用|异常|故障|维护|升级|更新|拥堵|超时|过载|开(?:了)?小差|出(?:了)?(?:点)?小差)(?:中|了|时)?/gu,
    /(?:当前|目前|现在|此刻)?(?:系统|平台|服务|服务器|接口|网络|后台)?(?:当前|目前|现在|正在|正)?(?:请求|访问|咨询|用户|访客|客户|人数)(?:量|人数)?(?:当前|目前|现在|正在|正)?(?:较多|过多|太多|较大|过大|拥堵|繁忙|高峰)(?:中|了|时)?/gu,
  ];
  let residual = compact;
  let unavailable = false;
  for (const pattern of failures) residual = residual.replace(pattern, () => { unavailable = true; return ''; });
  const fillers = [
    /(?:您好|你好|嗨)/gu,
    /(?:真的|非常|十分|实在|很)?(?:抱歉|对不起|不好意思)/gu,
    /(?:给|为)(?:您|你)(?:带来|造成)(?:的|了)?(?:一些)?不便/gu,
    /(?:谢谢|感谢)(?:您|你)?(?:的)?(?:理解|谅解|耐心等待|耐心|配合|等待)/gu,
    /(?:请|还请|敬请)?(?:您|你)?(?:多多)?(?:谅解|理解|见谅)/gu,
    /(?:我们|后台)?(?:当前|目前|现在|正在)?(?:为(?:您|你))?(?:检查|处理中|处理|恢复中|恢复)/gu,
    /(?:我们|本客服|本系统)/gu,
    /(?:由于|因为|所以|因此|可能|似乎|看来)/gu,
    /(?:您|你|我|这边)/gu,
    /(?:如果|若|要是|遇到|出现)(?:这种|此类|上述|该)?(?:情况|问题)?/gu,
    /(?:(?:您|你|我们|这个|该|当前|上述)(?:的)?)?(?:问题|请求|咨询|消息)(?:当前|目前)?/gu,
    /(?:这会儿|这会)/gu,
  ];
  for (const pattern of fillers) residual = residual.replace(pattern, '');
  let retry = false;
  const retryFillers = [
    /(?:请|还请|建议|麻烦)?(?:您|你)?(?:耐心)?(?:稍后|稍晚|稍候(?:一下|片刻)?|稍等(?:一下|片刻)?|过一会儿?|过会儿?|待会儿?|等一会儿?|等会儿?|等一下|过阵子|晚点|之后)(?:再|重新)?(?:尝试|试试|试|重试|联系|咨询|操作|访问|提交|刷新|回来|发起|来|问|发送)?(?:一下|一次|一遍|看看)?/gu,
    /(?:请|还请|麻烦)?(?:您|你)?耐心等待(?:一下|片刻)?/gu,
  ];
  for (const pattern of retryFillers) residual = residual.replace(pattern, () => { retry = true; return ''; });
  return (unavailable || retry) && /^(?:了|的|呢|吧|啊|呀|哦|啦|哈)*$/u.test(residual);
}

// 只拦截整条机械故障话术。不得逐句删除成功的业务回答：诸如“不支持某项
// 服务”本身可能就是知识事实，基础设施故障应由调用方的结构化状态判断。
function sanitizeVisitorText(value, purpose = 'safe_error', context = 'text') {
  if (typeof value !== 'string') return visitorFallbackFor(purpose, context);
  const visible = value.trim().slice(0, 8000);
  if (!visible || mechanicalFailureAnswer(visible)) return visitorFallbackFor(purpose, context);
  return visible;
}

module.exports = { VISITOR_FALLBACKS, visitorFallbackFor, mechanicalFailureAnswer,
  legacyGenericNonAnswer, sanitizeVisitorText };
