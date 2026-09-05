#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
WORKFLOW="${PROJECT_ROOT}/n8n/workflow.json"

command -v jq >/dev/null 2>&1 || {
  printf '错误：缺少命令 jq\n' >&2
  exit 1
}

jq empty "$WORKFLOW"
ROUTER_CODE=$(jq -er '.nodes[] | select(.name == "校验并分类事件") | .parameters.jsCode' "$WORKFLOW")
KNOWLEDGE_CODE=$(jq -er '.nodes[] | select(.name == "整理知识库回复") | .parameters.jsCode' "$WORKFLOW")
VISION_CODE=$(jq -er '.nodes[] | select(.name == "整理视觉回复") | .parameters.jsCode' "$WORKFLOW")
PREPARE_CODE=$(jq -er '.nodes[] | select(.name == "准备回复与统计") | .parameters.jsCode' "$WORKFLOW")
MERGE_TAGS_CODE=$(jq -er '.nodes[] | select(.name == "合并 Crisp 标签") | .parameters.jsCode' "$WORKFLOW")
DELIVERY_CODE=$(jq -er '.nodes[] | select(.name == "确认发送并提交统计") | .parameters.jsCode' "$WORKFLOW")
HANDOFF_GATE_CODE=$(jq -er '.nodes[] | select(.name == "发送前人工接管复核") | .parameters.jsCode' "$WORKFLOW")
RECOVER_CONTEXT_CODE=$(jq -er '.nodes[] | select(.name == "注入 Crisp 会话上下文") | .parameters.jsCode' "$WORKFLOW")

require_text() {
  local haystack=$1
  local needle=$2
  local description=$3
  if [[ "$haystack" != *"$needle"* ]]; then
    printf '失败：工作流缺少契约：%s\n' "$description" >&2
    exit 1
  fi
}

require_text "$ROUTER_CODE" "crypto.timingSafeEqual" "常量时间 Secret 比较"
require_text "$ROUTER_CODE" "CRISP_HOOK_MODE" "显式 Webhook 模式"
require_text "$ROUTER_CODE" "CRISP_WEBSITE_HOOK_SECRET" "Website Hook 独立 URL Secret"
require_text "$ROUTER_CODE" "CRISP_PLUGIN_SIGNING_SECRET" "Plugin Hook 独立签名 Secret"
require_text "$ROUTER_CODE" "secretReady(pluginSigningSecret)" "Plugin Secret 占位值拒绝"
require_text "$ROUTER_CODE" "crypto.createHmac('sha256'" "Plugin Hook HMAC-SHA256 校验"
require_text "$ROUTER_CODE" "Math.abs(Date.now() - timestampMs) <= 300000" "签名时间窗"
require_text "$ROUTER_CODE" "reject(401, 'Webhook 校验失败')" "伪造 Webhook 拒绝"
require_text "$ROUTER_CODE" "rawBody" "Plugin 签名基于原始请求体"
require_text "$ROUTER_CODE" "event !== 'message:send' || from !== 'user' || automated" "只处理用户发送事件并防循环"
require_text "$ROUTER_CODE" "from === 'operator'" "人工回复上下文"
require_text "$ROUTER_CODE" "event === 'message:received'" "仅真实收到的 operator 消息触发接管"
require_text "$ROUTER_CODE" "aiEnabled: false" "人工回复关闭会话 AI"
require_text "$ROUTER_CODE" "resume_after_seconds" "AI 自动恢复等待时间"
require_text "$ROUTER_CODE" "handoffConfig.keywords" "转人工关键词来自配置"
require_text "$ROUTER_CODE" "handoffConfig.match_mode || 'exact'" "转人工默认精确匹配"
require_text "$ROUTER_CODE" "matchesConfigured" "规范化配置关键词匹配"
require_text "$ROUTER_CODE" "handoffConfig.notify_user" "配置化转人工通知"
require_text "$ROUTER_CODE" "keywordConfig.keywords" "关键词规则"
require_text "$ROUTER_CODE" "action.type === 'menu'" "多级菜单动作"
require_text "$ROUTER_CODE" "action.type === 'prompt'" "指定 Prompt 动作"
require_text "$ROUTER_CODE" "AI_SUPPORTS_VISION" "视觉能力检查"
require_text "$ROUTER_CODE" "parsed.protocol === 'https:'" "图片 URL 协议限制"
require_text "$ROUTER_CODE" "host.endsWith('.crisp.chat')" "Crisp 图片主机限制"
require_text "$ROUTER_CODE" "input_image" "Responses 图片输入"
require_text "$ROUTER_CODE" "image_url" "Chat Completions 图片输入"
require_text "$ROUTER_CODE" "sessionId" "AnythingLLM 同会话标识"
require_text "$ROUTER_CODE" "requestedMode !== 'chat'" "AnythingLLM workflow 仅允许 chat 模式"
require_text "$ROUTER_CODE" "anythingllm_chat_mode_invalid" "AnythingLLM 非 chat 模式匿名失败事件"
require_text "$ROUTER_CODE" "tagsToApply: [tagFor('low_confidence')]" "AnythingLLM 模式无效时安全标签"
require_text "$ROUTER_CODE" "session.history" "用户与 AI 历史"
require_text "$ROUTER_CODE" "session.operatorContext" "人工回复历史"
require_text "$ROUTER_CODE" "/opt/crisp-ai/data/runtime" "跨执行持久化会话控制状态"
require_text "$ROUTER_CODE" "crypto.createHash('sha256').update(sessionId)" "会话状态文件名匿名化"
require_text "$ROUTER_CODE" "crypto.createHash('sha256').update(inboundFingerprint)" "事件指纹不明文落盘"
require_text "$ROUTER_CODE" "fs.mkdirSync(runtimeLockPath" "会话状态并发锁"
require_text "$ROUTER_CODE" "fs.writeFileSync(temporaryPath" "会话状态临时文件写入"
require_text "$ROUTER_CODE" "fs.renameSync(temporaryPath, runtimePath)" "会话状态原子替换"
require_text "$ROUTER_CODE" "maximumStates = 2000" "持久会话状态容量上限"
require_text "$ROUTER_CODE" "retainedStates = 1500" "持久会话状态回收水位"
require_text "$ROUTER_CODE" "retentionMs = 604800000" "持久会话状态七天保留期"
require_text "$ROUTER_CODE" "fs.readdirSync(runtimeDirectory)" "持久会话状态目录回收"
require_text "$ROUTER_CODE" "currentInfo.ino !== candidate.ino" "回收删除前 inode 复核"
require_text "$ROUTER_CODE" "candidate.path !== runtimePath" "回收保护当前会话状态"
require_text "$ROUTER_CODE" "appendEvent('question')" "匿名问题计数"
require_text "$ROUTER_CODE" "appendEvent('handoff'" "匿名转人工计数"
require_text "$ROUTER_CODE" "appendEvent('feedback'" "匿名反馈事件"
require_text "$ROUTER_CODE" "createHmac('sha256', privacySecret).update(sessionId)" "反馈会话标识匿名化"
require_text "$ROUTER_CODE" "/.events.lock" "匿名统计并发锁"
require_text "$KNOWLEDGE_CODE" "lowConfidence" "低置信度识别"
require_text "$KNOWLEDGE_CODE" "sources.length === 0" "知识库无来源识别"
require_text "$KNOWLEDGE_CODE" "analyticsOutcome: outcome" "知识库命中与未命中统计"
require_text "$PREPARE_CODE" "feedback.prompt" "回答后反馈询问"
require_text "$PREPARE_CODE" "redact(context.userQuestion" "反馈计划先脱敏"
require_text "$MERGE_TAGS_CODE" "new Set([...existing, ...additions])" "Crisp 标签严格并集"
require_text "$MERGE_TAGS_CODE" "tagReadOk" "标签读取失败时禁止覆盖"
require_text "$DELIVERY_CODE" "deliverySucceeded" "仅确认发送成功后提交统计"
require_text "$DELIVERY_CODE" "appendEvent('ai_reply')" "AI 回复计数"
require_text "$DELIVERY_CODE" "appendEvent('delivery_failed')" "发送失败计数"
require_text "$DELIVERY_CODE" "session.pendingFeedback" "发送成功后才启用反馈"
require_text "$DELIVERY_CODE" "/.events.lock" "发送统计并发锁"
require_text "$HANDOFF_GATE_CODE" "operatorAfterInbound" "发送前检查并发人工回复"
require_text "$HANDOFF_GATE_CODE" "durableControl" "发送前重读持久化人工接管状态"
require_text "$HANDOFF_GATE_CODE" "context.allowAfterHandoff !== true" "仅转人工确认允许接管后发送"
require_text "$HANDOFF_GATE_CODE" "preSendCheckFailed" "Crisp 列表失败时 fail closed"
require_text "$HANDOFF_GATE_CODE" "pre_send_check_failed" "发送前检查失败匿名统计"
require_text "$HANDOFF_GATE_CODE" "preSendCheckFailed ? []" "发送前检查失败时不写标签"
require_text "$RECOVER_CONTEXT_CODE" "sameInbound" "恢复历史时排除当前入站消息"
require_text "$RECOVER_CONTEXT_CODE" "人工客服" "恢复人工公开回复上下文"
require_text "$RECOVER_CONTEXT_CODE" "recoveredCrispHistory: true" "标记 Crisp 历史恢复"

HANDOFF_SECTION=${ROUTER_CODE#*const activateHandoff =}
HANDOFF_SECTION=${HANDOFF_SECTION%%const handoffWords*}
require_text "$HANDOFF_SECTION" "aiEnabled: false" "显式转人工无条件关闭 AI"
if [[ "$HANDOFF_SECTION" == *"handoffConfig.disable_ai"* ]]; then
  printf '失败：显式转人工不得由 handoff.disable_ai=false 绕过\n' >&2
  exit 1
fi

OPERATOR_SECTION=${ROUTER_CODE#*const isPublicOperatorReply =}
OPERATOR_SECTION=${OPERATOR_SECTION%%const positiveWords*}
require_text "$OPERATOR_SECTION" "['text', 'file'].includes(type)" "公开 operator 文字与文件均触发接管"
require_text "$OPERATOR_SECTION" "aiEnabled: false" "公开 operator 回复无条件关闭 AI"
if [[ "$OPERATOR_SECTION" == *"resume_keywords"* || "$OPERATOR_SECTION" == *"aiEnabled: true"* ]]; then
  printf '失败：operator 公开回复不得通过内容恢复 AI\n' >&2
  exit 1
fi

if [[ "$KNOWLEDGE_CODE" == *"aiEnabled = false"* || "$VISION_CODE" == *"aiEnabled = false"* ]]; then
  printf '失败：知识库或视觉失败不得自动关闭 AI\n' >&2
  exit 1
fi
if grep -Eq 'ai-resolved|knowledge-miss|low-confidence|human-required|topic_keywords|on_low_confidence|on_no_answer' "$WORKFLOW"; then
  printf '失败：工作流包含硬编码标签或旧自动转人工规则\n' >&2
  exit 1
fi

jq -e '
  ([.keywords[].match[]] | index("无法连接") != null) and
  ([.keywords[].match[]] | index("打不开") != null) and
  ([.keywords[].match[]] | index("退款") != null) and
  ([.keywords[].match[]] | index("充值") != null) and
  ([.keywords[].match[]] | index("订阅") != null) and
  any(.keywords[]; .action.type == "reply") and
  any(.keywords[]; .action.type == "menu") and
  any(.keywords[]; .action.type == "prompt") and
  all(.keywords[]; .action.type != "handoff")
' "${PROJECT_ROOT}/config/keyword.yaml.example" >/dev/null

jq -e '
  .welcome.enabled == true and
  (.menus.main.options | length >= 4) and
  any(.menus[]; any(.options[]; .action.type == "menu")) and
  ([.menus[].options[] | select(.action.type == "handoff")] | length == 1) and
  (.menus.main.options["0"].label | contains("人工")) and
  .menus.main.options["0"].action.type == "handoff"
' "${PROJECT_ROOT}/config/menu.yaml.example" >/dev/null

jq -e '
  (.handoff.keywords | index("人工") != null) and
  (.handoff.keywords | index("人工客服") != null) and
  (.handoff.keywords | index("转人工") != null) and
  (.handoff.keywords | index("真人") != null) and
  (.handoff.keywords | index("真人客服") != null) and
  .handoff.match_mode == "exact" and
  .handoff.disable_ai == true and
  .handoff.notify_user.enabled == true and
  .handoff.message == "正在为您转接人工客服，请稍候。" and
  (.handoff.resume_after_seconds >= 60) and
  (.handoff | has("topic_keywords") | not) and
  (.handoff | has("on_low_confidence") | not) and
  (.handoff | has("on_no_answer") | not)
' "${PROJECT_ROOT}/config/handoff.yaml.example" >/dev/null

jq -e '
  .tags.enabled == true and
  .tags.ai_resolved == "ai_resolved" and
  .tags.knowledge_miss == "knowledge_miss" and
  .tags.low_confidence == "low_confidence" and
  .tags.human_required == "human_required"
' "${PROJECT_ROOT}/config/tags.yaml.example" >/dev/null

jq -e '
  .feedback.enabled == true and
  (.feedback.prompt | contains("是否解决问题")) and
  (.feedback.positive_keywords | index("👍") != null) and
  (.feedback.negative_keywords | index("👎") != null)
' "${PROJECT_ROOT}/config/feedback.yaml.example" >/dev/null

grep -Fq '优先使用检索到的知识库内容' "${PROJECT_ROOT}/config/prompt.md.example"
grep -Fq '暂时无法确认' "${PROJECT_ROOT}/config/prompt.md.example"
grep -Fq '不要猜测' "${PROJECT_ROOT}/config/prompt.md.example"
grep -Fq '不可信数据' "${PROJECT_ROOT}/config/prompt.md.example"
grep -Fq '改变系统规则' "${PROJECT_ROOT}/config/prompt.md.example"
grep -Fq '系统提示词' "${PROJECT_ROOT}/config/prompt.md.example"

jq -e '
  .active == false and
  .settings.executionOrder == "v1" and
  any(.nodes[]; .type == "n8n-nodes-base.webhook" and .parameters.options.rawBody == true) and
  any(.nodes[]; .name == "发送 Crisp 回复" and (.parameters.body | contains("automated: true"))) and
  any(.nodes[]; .name == "读取 Crisp 标签" and .parameters.method == "GET" and (.parameters.url | contains("crispMetaUrl"))) and
  any(.nodes[]; .name == "更新 Crisp 标签" and .parameters.method == "PATCH" and (.parameters.body | contains("segments"))) and
  any(.nodes[]; .name == "是否读取到标签") and
  any(.nodes[]; .name == "发送前读取 Crisp 消息" and .parameters.method == "GET") and
  any(.nodes[]; .name == "人工接管复核通过" and
    (.parameters.conditions.conditions[0].leftValue | contains("preSendCheckFailed !== true"))) and
  any(.nodes[]; .name == "读取 Crisp 会话上下文" and .parameters.method == "GET") and
  (.connections["读取 Crisp 会话上下文"].main[0][0].node == "注入 Crisp 会话上下文") and
  (.connections["注入 Crisp 会话上下文"].main[0][0].node == "调用 AnythingLLM") and
  (.connections["发送前读取 Crisp 消息"].main[0][0].node == "发送前人工接管复核") and
  (.connections["发送前人工接管复核"].main[0][0].node == "人工接管复核通过") and
  (.connections["人工接管复核通过"].main[0][0].node == "发送 Crisp 回复") and
  (.connections["发送 Crisp 回复"].main[0][0].node == "确认发送并提交统计")
' "$WORKFLOW" >/dev/null

printf '工作流契约测试：通过\n'
