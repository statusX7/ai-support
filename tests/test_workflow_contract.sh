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
require_text "$ROUTER_CODE" "session.handoffUntil" "会话级人工接管"
require_text "$ROUTER_CODE" "resume_after_seconds" "AI 自动恢复等待时间"
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
require_text "$KNOWLEDGE_CODE" "lowConfidence" "低置信度识别"
require_text "$KNOWLEDGE_CODE" "sources.length === 0" "知识库无来源识别"
require_text "$KNOWLEDGE_CODE" "session.handoffUntil" "知识库失败转人工"
require_text "$VISION_CODE" "session.handoffReason = '图片理解失败'" "图片失败转人工"

jq -e '
  ([.keywords[].match[]] | index("无法连接") != null) and
  ([.keywords[].match[]] | index("打不开") != null) and
  ([.keywords[].match[]] | index("退款") != null) and
  ([.keywords[].match[]] | index("充值") != null) and
  ([.keywords[].match[]] | index("订阅") != null) and
  any(.keywords[]; .action.type == "reply") and
  any(.keywords[]; .action.type == "menu") and
  any(.keywords[]; .action.type == "prompt") and
  any(.keywords[]; .action.type == "handoff")
' "${PROJECT_ROOT}/config/keyword.yaml.example" >/dev/null

jq -e '
  .welcome.enabled == true and
  (.menus.main.options | length >= 4) and
  any(.menus[]; any(.options[]; .action.type == "menu")) and
  any(.menus[]; any(.options[]; .action.type == "handoff"))
' "${PROJECT_ROOT}/config/menu.yaml.example" >/dev/null

jq -e '
  (.handoff.keywords | index("人工") != null) and
  (.handoff.keywords | index("客服") != null) and
  (.handoff.keywords | index("真人") != null) and
  (.handoff.topic_keywords | has("complaint")) and
  (.handoff.topic_keywords | has("payment")) and
  (.handoff.topic_keywords | has("account")) and
  (.handoff.resume_after_seconds >= 60) and
  .handoff.on_low_confidence == true and
  .handoff.on_no_answer == true
' "${PROJECT_ROOT}/config/handoff.yaml.example" >/dev/null

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
  any(.nodes[]; .name == "发送 Crisp 回复" and (.parameters.body | contains("automated: true")))
' "$WORKFLOW" >/dev/null

printf '工作流契约测试：通过\n'
