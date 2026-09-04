#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"

DEPLOY_REQUEST=""
OFFLINE=0
LOCAL_ONLY=0

usage() {
  cat <<'EOF'
用法：healthcheck.sh [--deploy-dir PATH] [--offline] [--local]

--offline 只检查文件、权限和配置格式，不访问 Docker 或外部 API。
--local 检查文件、容器与本地健康接口，不访问外部 Provider 或 Crisp API。
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
    --help|-h)
      usage
      exit 0
      ;;
    *) die "未知选项：$1" ;;
  esac
done

DEPLOY_DIR=$(resolve_deploy_dir "$DEPLOY_REQUEST")
assert_installation "$DEPLOY_DIR"
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
  (.handoff.disable_ai | type == "boolean") and
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

for key in N8N_ENCRYPTION_KEY POSTGRES_PASSWORD ANYTHINGLLM_AUTH_TOKEN CRISP_WEBHOOK_SECRET AI_API_KEY CRISP_AUTH_B64; do
  value=$(env_get "${DEPLOY_DIR}/.env" "$key" 2>/dev/null || true)
  if is_placeholder "$value"; then
    fail "敏感配置尚未完成：$key"
  else
    pass "敏感配置已设置：$key"
  fi
done

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
  for service in postgres anythingllm n8n; do
    if grep -Fxq "$service" <<< "$RUNNING"; then
      pass "容器运行：$service"
    else
      fail "容器未运行：$service"
    fi
  done

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
    API_BASE=$(env_get "${DEPLOY_DIR}/.env" AI_API_BASE_URL 2>/dev/null || true)
    API_KEY=$(env_get "${DEPLOY_DIR}/.env" AI_API_KEY 2>/dev/null || true)
    PROVIDER_STATUS=$(curl --silent --output /dev/null --write-out '%{http_code}' \
      --connect-timeout 5 --max-time 20 --header "Authorization: Bearer ${API_KEY}" \
      "${API_BASE}/models" 2>/dev/null || true)
    if [[ "$PROVIDER_STATUS" == 2?? ]]; then
      pass "Provider /v1/models 可用"
    else
      fail "Provider 检查失败（HTTP ${PROVIDER_STATUS:-000}）"
    fi

    CRISP_ID=$(env_get "${DEPLOY_DIR}/.env" CRISP_WEBSITE_ID 2>/dev/null || true)
    CRISP_TIER=$(env_get "${DEPLOY_DIR}/.env" CRISP_TOKEN_TIER 2>/dev/null || printf 'website')
    CRISP_AUTH=$(env_get "${DEPLOY_DIR}/.env" CRISP_AUTH_B64 2>/dev/null || true)
    CRISP_STATUS=$(curl --silent --output /dev/null --write-out '%{http_code}' \
      --connect-timeout 5 --max-time 20 \
      --header "Authorization: Basic ${CRISP_AUTH}" \
      --header "X-Crisp-Tier: ${CRISP_TIER}" \
      "https://api.crisp.chat/v1/website/${CRISP_ID}" 2>/dev/null || true)
    if [[ "$CRISP_STATUS" == 2?? ]]; then
      pass "Crisp REST API 可用"
    else
      fail "Crisp REST API 检查失败（HTTP ${CRISP_STATUS:-000}）"
    fi

    ANYTHING_KEY_VALUE=$(env_get "${DEPLOY_DIR}/.env" ANYTHINGLLM_API_KEY 2>/dev/null || true)
    ANYTHING_AUTH_STATUS=$(curl --silent --output /dev/null --write-out '%{http_code}' \
      --connect-timeout 5 --max-time 20 \
      --header "Authorization: Bearer ${ANYTHING_KEY_VALUE}" \
      "http://127.0.0.1:${ANYTHING_PORT_VALUE}/api/v1/auth" 2>/dev/null || true)
    if [[ "$ANYTHING_AUTH_STATUS" == 2?? ]]; then
      pass "AnythingLLM Developer API 可用"
    else
      fail "AnythingLLM Developer API 检查失败（HTTP ${ANYTHING_AUTH_STATUS:-000}）"
    fi
  fi
fi

printf '\n结果：失败 %d，警告 %d。\n' "$FAILURES" "$WARNINGS"
(( FAILURES == 0 ))
