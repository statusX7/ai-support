#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"

DEPLOY_REQUEST=""
OFFLINE=0
LOCAL_ONLY=0
APPLICATION_ONLY=0
INSTALLATION_IN_PROGRESS=0

usage() {
  cat <<'EOF'
用法：healthcheck.sh [--deploy-dir PATH] [--offline] [--local] [--application]

--offline 只检查文件、权限和配置格式，不访问 Docker 或外部 API。
--local 检查文件、容器与本地健康接口，不访问外部 Provider 或 Crisp API。
--application 检查本地应用、Provider 与 AnythingLLM，不访问 Crisp API。
--installation-in-progress 仅供 install.sh/update.sh 在提交 ready 状态前使用。
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --deploy-dir)
      (( $# >= 2 )) || die "--deploy-dir 缺少参数"
      DEPLOY_REQUEST=$2
      shift 2
      ;;
    --offline)
      OFFLINE=1
      shift
      ;;
    --local)
      LOCAL_ONLY=1
      shift
      ;;
    --application)
      APPLICATION_ONLY=1
      shift
      ;;
    --installation-in-progress)
      INSTALLATION_IN_PROGRESS=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *) die "未知选项：$1" ;;
  esac
done

DEPLOY_DIR=$(resolve_deploy_dir "$DEPLOY_REQUEST")
if (( INSTALLATION_IN_PROGRESS )); then
  assert_managed_installation "$DEPLOY_DIR"
  [[ "$(installation_state "$DEPLOY_DIR")" == installing ]] \
    || die "--installation-in-progress 仅允许检查 installing 状态"
else
  assert_installation "$DEPLOY_DIR"
fi
repair_runtime_modules_from_source "$DEPLOY_DIR"
FAILURES=0
WARNINGS=0

pass() {
  printf '通过：%s\n' "$*"
}

fail() {
  printf '失败：%s\n' "$*" >&2
  ((FAILURES += 1))
}

health_warn() {
  printf '警告：%s\n' "$*" >&2
  ((WARNINGS += 1))
}

printf 'AI客服管理系统健康检查 %s\n\n' "$(<"${DEPLOY_DIR}/VERSION")"

REQUIRED_FILES=(
  VERSION docker-compose.yml .env n8n/workflow.json
  config/app.yaml config/provider.yaml config/prompt.md
  config/keyword.yaml config/menu.yaml config/handoff.yaml
  config/tags.yaml config/feedback.yaml data/analytics/events.jsonl
  scripts/bootstrap.sh scripts/wizard.sh scripts/package-release.sh config/Caddyfile.example
)
for relative in "${REQUIRED_FILES[@]}"; do
  if [[ -f "${DEPLOY_DIR}/${relative}" && ! -L "${DEPLOY_DIR}/${relative}" ]]; then
    pass "文件存在：$relative"
  else
    fail "文件缺失或是符号链接：$relative"
  fi
done

require_command jq
for json_file in config/keyword.yaml config/menu.yaml config/handoff.yaml config/tags.yaml config/feedback.yaml n8n/workflow.json; do
  if jq empty "${DEPLOY_DIR}/${json_file}" >/dev/null 2>&1; then
    pass "JSON/YAML 格式有效：$json_file"
  else
    fail "JSON/YAML 格式无效：$json_file"
  fi
done

if jq -e '
  (.handoff.keywords | type == "array") and
  (.handoff.keywords | all(type == "string" and length > 0)) and
  (.handoff.match_mode == "exact" or .handoff.match_mode == "contains") and
  (.handoff.disable_ai == true) and
  (.handoff.notify_user.enabled | type == "boolean") and
  (.handoff.resume_after_seconds | type == "number" and . >= 0)
' "${DEPLOY_DIR}/config/handoff.yaml" >/dev/null 2>&1; then
  pass "人工接管配置结构有效"
else
  fail "人工接管配置结构无效"
fi
if jq -e '
  (.tags.enabled | type == "boolean") and
  ([.tags.ai_resolved,.tags.knowledge_miss,.tags.low_confidence,.tags.human_required]
    | all(type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$")))
' "${DEPLOY_DIR}/config/tags.yaml" >/dev/null 2>&1; then
  pass "Conversation 标签配置结构有效"
else
  fail "Conversation 标签配置结构无效"
fi
if jq -e '
  (.feedback.enabled | type == "boolean") and
  (.feedback.positive_keywords | type == "array" and all(type == "string" and length > 0)) and
  (.feedback.negative_keywords | type == "array" and all(type == "string" and length > 0)) and
  (.feedback.max_text_chars | type == "number" and . >= 50 and . <= 2000)
' "${DEPLOY_DIR}/config/feedback.yaml" >/dev/null 2>&1; then
  pass "回答反馈配置结构有效"
else
  fail "回答反馈配置结构无效"
fi

ANALYTICS_MODE=$(stat -c '%a' "${DEPLOY_DIR}/data/analytics/events.jsonl" 2>/dev/null || printf '777')
if (( (8#$ANALYTICS_MODE & 007) == 0 )); then
  pass "匿名统计事件未向其他用户开放"
else
  fail "匿名统计事件权限过宽：$ANALYTICS_MODE"
fi
for suffix in 1 2 3 4 5; do
  ANALYTICS_ROTATED="${DEPLOY_DIR}/data/analytics/events.jsonl.${suffix}"
  if [[ -L "$ANALYTICS_ROTATED" ]]; then
    fail "统计轮转文件不得是符号链接：$ANALYTICS_ROTATED"
    continue
  fi
  [[ ! -e "$ANALYTICS_ROTATED" ]] && continue
  if [[ ! -f "$ANALYTICS_ROTATED" ]]; then
    fail "统计轮转文件不是安全的普通文件：$ANALYTICS_ROTATED"
    continue
  fi
  ANALYTICS_MODE=$(stat -c '%a' "$ANALYTICS_ROTATED" 2>/dev/null || printf '777')
  if (( (8#$ANALYTICS_MODE & 007) == 0 )); then
    pass "统计轮转文件权限有效：events.jsonl.${suffix}"
  else
    fail "统计轮转文件权限过宽：events.jsonl.${suffix}（${ANALYTICS_MODE}）"
  fi
done

if provider_config_has_secret_field "${DEPLOY_DIR}/config/provider.yaml"; then
  fail "provider.yaml 不得保存密钥"
else
  pass "provider.yaml 未发现密钥字段"
fi

SNAPSHOT_MIN_FREE_MB_VALUE=$(env_get "${DEPLOY_DIR}/.env" SNAPSHOT_MIN_FREE_MB 2>/dev/null || printf '1024')
SNAPSHOT_RETENTION_COUNT_VALUE=$(env_get "${DEPLOY_DIR}/.env" SNAPSHOT_RETENTION_COUNT 2>/dev/null || printf '10')
if [[ "$SNAPSHOT_MIN_FREE_MB_VALUE" =~ ^(0|[1-9][0-9]*)$ ]] \
  && (( 10#$SNAPSHOT_MIN_FREE_MB_VALUE <= 2147483647 )) \
  && [[ "$SNAPSHOT_RETENTION_COUNT_VALUE" =~ ^(0|[1-9][0-9]*)$ ]] \
  && (( 10#$SNAPSHOT_RETENTION_COUNT_VALUE <= 1000 )); then
  pass "版本快照策略有效：预留 ${SNAPSHOT_MIN_FREE_MB_VALUE} MiB，保留 ${SNAPSHOT_RETENTION_COUNT_VALUE} 份（0 表示关闭对应限制）"
else
  fail "版本快照策略无效"
fi

ENV_MODE=$(stat -c '%a' "${DEPLOY_DIR}/.env" 2>/dev/null || printf '777')
if (( (8#$ENV_MODE & 077) == 0 )); then
  pass ".env 权限未向组或其他用户开放"
else
  fail ".env 权限过宽：$ENV_MODE"
fi

for runtime_dir in data/n8n data/anythingllm data/runtime; do
  RUNTIME_OWNER=$(stat -c '%u:%g' "${DEPLOY_DIR}/${runtime_dir}" 2>/dev/null || printf 'unknown')
  RUNTIME_MODE=$(stat -c '%a' "${DEPLOY_DIR}/${runtime_dir}" 2>/dev/null || printf '777')
  if [[ "$RUNTIME_OWNER" == "1000:1000" ]] && (( (8#$RUNTIME_MODE & 002) == 0 )); then
    pass "容器数据目录所有权有效：${runtime_dir}"
  else
    fail "容器数据目录权限无效：${runtime_dir}（${RUNTIME_OWNER} ${RUNTIME_MODE}）"
  fi
done

for key in N8N_ENCRYPTION_KEY POSTGRES_PASSWORD ANYTHINGLLM_AUTH_TOKEN ANYTHINGLLM_JWT_SECRET \
  ANYTHINGLLM_SIG_KEY ANYTHINGLLM_SIG_SALT ANYTHINGLLM_API_KEY AI_API_KEY \
  CRISP_TOKEN_IDENTIFIER CRISP_TOKEN_KEY CRISP_AUTH_B64; do
  value=$(env_get "${DEPLOY_DIR}/.env" "$key" 2>/dev/null || true)
  if is_placeholder "$value"; then
    fail "敏感配置尚未完成：$key"
  else
    pass "敏感配置已设置：$key"
  fi
done
CRISP_HOOK_MODE_VALUE=$(env_get "${DEPLOY_DIR}/.env" CRISP_HOOK_MODE 2>/dev/null || true)
case "$CRISP_HOOK_MODE_VALUE" in
  website) CRISP_HOOK_SECRET_KEY=CRISP_WEBSITE_HOOK_SECRET ;;
  plugin) CRISP_HOOK_SECRET_KEY=CRISP_PLUGIN_SIGNING_SECRET ;;
  *)
    CRISP_HOOK_SECRET_KEY=""
    fail "CRISP_HOOK_MODE 必须是 website 或 plugin"
    ;;
esac
if [[ -n "$CRISP_HOOK_SECRET_KEY" ]]; then
  value=$(env_get "${DEPLOY_DIR}/.env" "$CRISP_HOOK_SECRET_KEY" 2>/dev/null || true)
  if is_placeholder "$value"; then
    fail "Webhook 校验配置尚未完成：$CRISP_HOOK_SECRET_KEY"
  else
    pass "Webhook 校验配置已设置：$CRISP_HOOK_SECRET_KEY"
  fi
fi

if (( OFFLINE )); then
  health_warn "离线模式未检查容器和 API"
else
  require_command docker
  require_command curl
  if docker compose version >/dev/null 2>&1; then
    pass "Docker Compose 可用"
  else
    fail "Docker Compose v2 不可用"
  fi
  if docker info >/dev/null 2>&1; then
    pass "Docker daemon 可连接"
  else
    fail "Docker daemon 不可连接"
  fi
  if docker_compose "$DEPLOY_DIR" config --quiet >/dev/null 2>&1; then
    pass "docker compose config 有效"
  else
    fail "docker compose config 无效"
  fi

  RUNNING=$(docker_compose "$DEPLOY_DIR" ps --services --filter status=running 2>/dev/null || true)
  REQUIRED_SERVICES=(postgres anythingllm n8n)
  if [[ "$(env_get "${DEPLOY_DIR}/.env" WEBHOOK_ACCESS_MODE 2>/dev/null || true)" == managed_https ]]; then
    REQUIRED_SERVICES+=(caddy)
  fi
  for service in "${REQUIRED_SERVICES[@]}"; do
    if grep -Fxq "$service" <<< "$RUNNING"; then
      pass "容器运行：$service"
    else
      fail "容器未运行：$service"
    fi
  done
  # shellcheck disable=SC2016 # $1 与 $output 必须在 n8n 容器内展开。
  if docker_compose "$DEPLOY_DIR" exec -T n8n sh -c '
    output=/tmp/ai-support-health-workflow.json
    n8n export:workflow --id="$1" --output="$output" >/dev/null 2>&1 || exit 1
    node -e '\''const fs=require("fs");const value=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));const workflow=Array.isArray(value)?value[0]:value;process.exit(workflow&&workflow.active===true?0:1)'\'' "$output"
    status=$?
    rm -f "$output"
    exit "$status"
  ' sh "$WORKFLOW_ID"; then
    pass "n8n 工作流已发布"
  else
    fail "n8n 工作流未发布或无法导出"
  fi

  N8N_PORT_VALUE=$(env_get "${DEPLOY_DIR}/.env" N8N_PORT 2>/dev/null || printf '5678')
  ANYTHING_PORT_VALUE=$(env_get "${DEPLOY_DIR}/.env" ANYTHINGLLM_PORT 2>/dev/null || printf '3001')
  if curl --silent --fail --connect-timeout 3 --max-time 10 "http://127.0.0.1:${N8N_PORT_VALUE}/healthz" >/dev/null 2>&1; then
    pass "n8n 健康接口可用"
  else
    fail "n8n 健康接口不可用"
  fi
  if curl --silent --fail --connect-timeout 3 --max-time 10 "http://127.0.0.1:${ANYTHING_PORT_VALUE}/api/ping" >/dev/null 2>&1; then
    pass "AnythingLLM 健康接口可用"
  else
    fail "AnythingLLM 健康接口不可用"
  fi

  if (( LOCAL_ONLY )); then
    health_warn "本地模式未检查外部 Provider、Crisp API 与 AnythingLLM Developer API 鉴权"
  else
    API_BASE=$(env_get "${DEPLOY_DIR}/.env" AI_API_PROBE_BASE_URL 2>/dev/null \
      || env_get "${DEPLOY_DIR}/.env" AI_API_BASE_URL 2>/dev/null || true)
    API_KEY=$(env_get "${DEPLOY_DIR}/.env" AI_API_KEY 2>/dev/null || true)
    AI_MODEL_VALUE=$(env_get "${DEPLOY_DIR}/.env" AI_MODEL 2>/dev/null || true)
    PROVIDER_PAYLOAD=$(jq -cn --arg model "$AI_MODEL_VALUE" '{model:$model,messages:[{role:"user",content:"Reply only OK."}]}')
    if probe_api_endpoint "${API_BASE}/chat/completions" "$API_KEY" "$PROVIDER_PAYLOAD" "${DEPLOY_DIR}/tmp"; then
      pass "Provider Chat Completions 与所选模型可用"
    else
      fail "Provider Chat Completions 或所选模型不可用"
    fi

    if (( APPLICATION_ONLY )); then
      health_warn "应用模式未检查 Crisp REST API、Webhook 登记和真实会话"
    elif crisp_api_check "$DEPLOY_DIR"; then
      pass "Crisp REST API 可用"
    else
      fail "Crisp REST API 检查失败（HTTP ${CRISP_API_STATUS:-000}）"
    fi
    if (( APPLICATION_ONLY == 0 )); then
      if webhook_access_check "$DEPLOY_DIR"; then
        pass "生产 Webhook 的 DNS、TLS 与路由可达"
      else
        fail "生产 Webhook 尚不可达（HTTP ${WEBHOOK_ACCESS_STATUS:-000}）"
      fi
    fi

    ANYTHING_KEY_VALUE=$(env_get "${DEPLOY_DIR}/.env" ANYTHINGLLM_API_KEY 2>/dev/null || true)
    if anythingllm_validate_api_key "$DEPLOY_DIR" "$ANYTHING_KEY_VALUE"; then
      pass "AnythingLLM Developer API 可用"
    else
      fail "AnythingLLM Developer API Key 无效"
    fi

    ANYTHING_WORKSPACE_VALUE=$(env_get "${DEPLOY_DIR}/.env" ANYTHINGLLM_WORKSPACE 2>/dev/null || true)
    ANYTHING_CHAT_MODE_VALUE=$(env_get "${DEPLOY_DIR}/.env" ANYTHINGLLM_CHAT_MODE 2>/dev/null || true)
    LOCAL_PROMPT=$(<"${DEPLOY_DIR}/config/prompt.md")
    ANYTHING_RESPONSE=$(mktemp "${DEPLOY_DIR}/tmp/anything-health.XXXXXX")
    ANYTHING_STATUS=$(anythingllm_secure_request "$DEPLOY_DIR" GET \
      "http://127.0.0.1:${ANYTHING_PORT_VALUE}/api/v1/workspace/${ANYTHING_WORKSPACE_VALUE}" \
      "$ANYTHING_KEY_VALUE" "" "$ANYTHING_RESPONSE")
    if [[ "$ANYTHING_STATUS" == 2?? ]] && jq -e --arg slug "$ANYTHING_WORKSPACE_VALUE" --arg prompt "$LOCAL_PROMPT" '
      .workspace as $workspace |
      (if ($workspace | type) == "array" then $workspace[0] else $workspace end) as $item |
      $item.slug == $slug and $item.openAiPrompt == $prompt
    ' "$ANYTHING_RESPONSE" >/dev/null 2>&1; then
      pass "AnythingLLM 工作区与 Prompt 已生效"
    else
      fail "AnythingLLM 工作区缺失或 Prompt 未同步"
    fi
    rm -f -- "$ANYTHING_RESPONSE"

    if [[ "$ANYTHING_CHAT_MODE_VALUE" == chat ]]; then
      ANYTHING_RESPONSE=$(mktemp "${DEPLOY_DIR}/tmp/anything-chat-health.XXXXXX")
      ANYTHING_PAYLOAD=$(jq -cn --arg mode "$ANYTHING_CHAT_MODE_VALUE" \
        --arg session "ai-support-health-$(date -u '+%Y%m%d')" \
        '{message:"请只回复：健康检查通过",mode:$mode,sessionId:$session}')
      ANYTHING_STATUS=$(anythingllm_secure_request "$DEPLOY_DIR" POST \
        "http://127.0.0.1:${ANYTHING_PORT_VALUE}/api/v1/workspace/${ANYTHING_WORKSPACE_VALUE}/chat" \
        "$ANYTHING_KEY_VALUE" "$ANYTHING_PAYLOAD" "$ANYTHING_RESPONSE")
      if [[ "$ANYTHING_STATUS" == 2?? ]] && jq -e '.textResponse | type == "string" and length > 0' "$ANYTHING_RESPONSE" >/dev/null 2>&1; then
        pass "AnythingLLM 工作区 Chat 可用"
      else
        fail "AnythingLLM 工作区 Chat 失败（HTTP ${ANYTHING_STATUS:-000}）"
      fi
      rm -f -- "$ANYTHING_RESPONSE"
    else
      fail "ANYTHINGLLM_CHAT_MODE 必须为 chat，才能保持同一 Crisp conversation 的上下文"
    fi
  fi
fi

printf '\n结果：失败 %d，警告 %d。\n' "$FAILURES" "$WARNINGS"
(( FAILURES == 0 ))
