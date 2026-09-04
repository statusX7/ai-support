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
require_text "$ROUTER_CODE" "crypto.createHmac('sha256'" "Plugin Hook HMAC-SHA256 校验"
require_text "$ROUTER_CODE" "Math.abs(Date.now() - timestampMs) <= 300000" "签名时间窗"
require_text "$ROUTER_CODE" "reject(401, 'Webhook 校验失败')" "伪造 Webhook 拒绝"
require_text "$ROUTER_CODE" "event !== 'message:send' || from !== 'user' || automated" "只处理用户发送事件并防循环"
require_text "$ROUTER_CODE" "from === 'operator'" "人工回复上下文"
require_text "$ROUTER_CODE" "session.aiEnabled = false" "人工回复关闭会话 AI"
require_text "$ROUTER_CODE" "resume_after_seconds" "AI 自动恢复等待时间"
require_text "$ROUTER_CODE" "handoffConfig.keywords" "转人工关键词来自配置"
require_text "$ROUTER_CODE" "handoffConfig.disable_ai" "配置化关闭 AI"
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
require_text "$ROUTER_CODE" "session.history" "用户与 AI 历史"
require_text "$ROUTER_CODE" "session.operatorContext" "人工回复历史"
require_text "$ROUTER_CODE" "appendEvent('question')" "匿名问题计数"
require_text "$ROUTER_CODE" "appendEvent('handoff'" "匿名转人工计数"
require_text "$ROUTER_CODE" "appendEvent('feedback'" "匿名反馈事件"
require_text "$ROUTER_CODE" "createHmac('sha256', secret).update(sessionId)" "反馈会话标识匿名化"
require_text "$KNOWLEDGE_CODE" "lowConfidence" "低置信度识别"
require_text "$KNOWLEDGE_CODE" "sources.length === 0" "知识库无来源识别"
require_text "$KNOWLEDGE_CODE" "analyticsOutcome: outcome" "知识库命中与未命中统计"
require_text "$PREPARE_CODE" "appendEvent('ai_reply')" "AI 回复计数"
require_text "$PREPARE_CODE" "feedback.prompt" "回答后反馈询问"
require_text "$MERGE_TAGS_CODE" "managed.includes(tag)" "保留非托管 Crisp 标签"
require_text "$MERGE_TAGS_CODE" "tagReadOk" "标签读取失败时禁止覆盖"

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
  any(.keywords[]; .action.type == "prompt")
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
  any(.nodes[]; .name == "是否读取到标签")
' "$WORKFLOW" >/dev/null

printf '工作流契约测试：通过\n'
