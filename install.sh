#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/scripts/common.sh"

DEPLOY_REQUEST=""
NON_INTERACTIVE=0
SKIP_START=0
RECONFIGURE=0

usage() {
  cat <<'EOF'
用法：./install.sh [选项]

选项：
  --deploy-dir PATH   指定部署目录，默认 /opt/crisp-ai
  --non-interactive   从环境变量读取配置，不进行交互
  --skip-start        只安装文件，不启动 Docker 服务
  --reconfigure       重复安装时重新配置 Provider 与 Crisp
  --help              显示帮助
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --deploy-dir)
      (( $# >= 2 )) || die "--deploy-dir 缺少参数"
      DEPLOY_REQUEST=$2
      shift 2
      ;;
    --non-interactive)
      NON_INTERACTIVE=1
      shift
      ;;
    --skip-start)
      SKIP_START=1
      shift
      ;;
    --reconfigure)
      RECONFIGURE=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "未知选项：$1"
      ;;
  esac
done

VERSION=$(<"${SCRIPT_DIR}/VERSION")
printf '%s\n' '================================'
printf ' AI客服管理系统 %s\n' "$VERSION"
printf '%s\n\n' '================================'

if [[ -z "$DEPLOY_REQUEST" && $NON_INTERACTIVE -eq 0 ]]; then
  printf '部署目录 [%s]：' "$DEFAULT_DEPLOY_DIR"
  IFS= read -r DEPLOY_REQUEST
  DEPLOY_REQUEST=${DEPLOY_REQUEST:-$DEFAULT_DEPLOY_DIR}
fi
DEPLOY_DIR=$(resolve_deploy_dir "${DEPLOY_REQUEST:-$DEFAULT_DEPLOY_DIR}")

require_command install
require_command mktemp
require_command curl
require_command jq
require_command openssl
require_command base64
require_command sha256sum
require_command tar
require_command df
require_command du

if [[ $EUID -ne 0 ]]; then
  die "安装需要 root 权限，以便设置容器数据目录权限"
fi

if (( SKIP_START == 0 )); then
  require_docker_runtime
fi

EXISTING=0
PREVIOUS_STATE="new"
PREVIOUS_VERSION=""
if [[ -d "$DEPLOY_DIR" ]] && find "$DEPLOY_DIR" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
  if [[ -f "${DEPLOY_DIR}/${INSTALL_MARKER}" ]]; then
    assert_managed_installation "$DEPLOY_DIR"
    PREVIOUS_STATE=$(installation_state "$DEPLOY_DIR")
    [[ ! -f "${DEPLOY_DIR}/VERSION" ]] || PREVIOUS_VERSION=$(<"${DEPLOY_DIR}/VERSION")
    if [[ "$PREVIOUS_STATE" == "ready" ]]; then
      EXISTING=1
    else
      warn "检测到未完成或已卸载的部署状态（${PREVIOUS_STATE}），本次将安全重试安装"
    fi
  else
    die "目标目录非空且没有有效安装标记，拒绝覆盖：$DEPLOY_DIR"
  fi
fi

if (( EXISTING == 1 )) && [[ -n "$PREVIOUS_VERSION" && "$PREVIOUS_VERSION" != "$VERSION" ]]; then
  die "检测到不同版本的现有部署（${PREVIOUS_VERSION} -> ${VERSION}）；请使用 update.sh 创建一致性快照后升级"
fi

umask 077
mkdir -p -- "$DEPLOY_DIR"
acquire_maintenance_lock "$DEPLOY_DIR"
write_installation_marker "$DEPLOY_DIR" "$SCRIPT_DIR" "$VERSION" installing
copy_project_files "$SCRIPT_DIR" "$DEPLOY_DIR"
initialize_config_files "$DEPLOY_DIR"
migrate_config_files "$DEPLOY_DIR"

ENV_FILE="${DEPLOY_DIR}/.env"
if [[ ! -f "$ENV_FILE" ]]; then
  printf '# 此文件由 ai-support 安装程序管理，禁止提交或公开。\n' > "$ENV_FILE"
  chmod 600 "$ENV_FILE"
fi

env_set "$ENV_FILE" DEPLOY_DIR "$DEPLOY_DIR"
EXISTING_N8N_IMAGE=$(env_get "$ENV_FILE" N8N_IMAGE 2>/dev/null || true)
EXISTING_POSTGRES_IMAGE=$(env_get "$ENV_FILE" POSTGRES_IMAGE 2>/dev/null || true)
EXISTING_ANYTHING_IMAGE=$(env_get "$ENV_FILE" ANYTHINGLLM_IMAGE 2>/dev/null || true)
[[ -n "$EXISTING_N8N_IMAGE" && "$EXISTING_N8N_IMAGE" != "docker.n8n.io/n8nio/n8n:2" ]] \
  || EXISTING_N8N_IMAGE=docker.n8n.io/n8nio/n8n:2.33.0
[[ -n "$EXISTING_POSTGRES_IMAGE" && "$EXISTING_POSTGRES_IMAGE" != "postgres:16-alpine" ]] \
  || EXISTING_POSTGRES_IMAGE=postgres:16.10-alpine
[[ -n "$EXISTING_ANYTHING_IMAGE" && "$EXISTING_ANYTHING_IMAGE" != "mintplexlabs/anythingllm:latest" ]] \
  || EXISTING_ANYTHING_IMAGE=mintplexlabs/anythingllm:1.16.1
BIND_ADDRESS_VALUE=${BIND_ADDRESS:-$(env_get "$ENV_FILE" BIND_ADDRESS 2>/dev/null || printf '127.0.0.1')}
N8N_PORT_VALUE=${N8N_PORT:-$(env_get "$ENV_FILE" N8N_PORT 2>/dev/null || printf '5678')}
ANYTHINGLLM_PORT_VALUE=${ANYTHINGLLM_PORT:-$(env_get "$ENV_FILE" ANYTHINGLLM_PORT 2>/dev/null || printf '3001')}
AI_MODEL_TOKEN_LIMIT_VALUE=${AI_MODEL_TOKEN_LIMIT:-$(env_get "$ENV_FILE" AI_MODEL_TOKEN_LIMIT 2>/dev/null || printf '8192')}
AI_MAX_OUTPUT_TOKENS_VALUE=${AI_MAX_OUTPUT_TOKENS:-$(env_get "$ENV_FILE" AI_MAX_OUTPUT_TOKENS 2>/dev/null || printf '1200')}
ANYTHING_CHAT_MODE_VALUE=${ANYTHINGLLM_CHAT_MODE:-$(env_get "$ENV_FILE" ANYTHINGLLM_CHAT_MODE 2>/dev/null || printf 'chat')}
validate_ipv4_address "$BIND_ADDRESS_VALUE" || die "BIND_ADDRESS 必须是有效 IPv4 地址"
validate_port "$N8N_PORT_VALUE" || die "N8N_PORT 必须是 1 到 65535 的整数"
validate_port "$ANYTHINGLLM_PORT_VALUE" || die "ANYTHINGLLM_PORT 必须是 1 到 65535 的整数"
if [[ ! "$AI_MODEL_TOKEN_LIMIT_VALUE" =~ ^[1-9][0-9]{1,6}$ ]] \
  || (( 10#$AI_MODEL_TOKEN_LIMIT_VALUE > 2000000 )); then
  die "AI_MODEL_TOKEN_LIMIT 必须是 10 到 2000000 的整数"
fi
if [[ ! "$AI_MAX_OUTPUT_TOKENS_VALUE" =~ ^[1-9][0-9]{0,6}$ ]] \
  || (( 10#$AI_MAX_OUTPUT_TOKENS_VALUE > 10#$AI_MODEL_TOKEN_LIMIT_VALUE )); then
  die "AI_MAX_OUTPUT_TOKENS 必须是 1 到 AI_MODEL_TOKEN_LIMIT 的整数"
fi
[[ "$ANYTHING_CHAT_MODE_VALUE" == chat ]] \
  || die "ANYTHINGLLM_CHAT_MODE 必须为 chat，才能保持同一 Crisp conversation 的上下文"
env_set "$ENV_FILE" BIND_ADDRESS "$BIND_ADDRESS_VALUE"
env_set "$ENV_FILE" N8N_PORT "$N8N_PORT_VALUE"
env_set "$ENV_FILE" ANYTHINGLLM_PORT "$ANYTHINGLLM_PORT_VALUE"
env_set "$ENV_FILE" N8N_IMAGE "${N8N_IMAGE:-$EXISTING_N8N_IMAGE}"
env_set "$ENV_FILE" POSTGRES_IMAGE "${POSTGRES_IMAGE:-$EXISTING_POSTGRES_IMAGE}"
env_set "$ENV_FILE" ANYTHINGLLM_IMAGE "${ANYTHINGLLM_IMAGE:-$EXISTING_ANYTHING_IMAGE}"
env_set "$ENV_FILE" AI_MODEL_TOKEN_LIMIT "$AI_MODEL_TOKEN_LIMIT_VALUE"
env_set "$ENV_FILE" AI_MAX_OUTPUT_TOKENS "$AI_MAX_OUTPUT_TOKENS_VALUE"
env_set "$ENV_FILE" ANYTHINGLLM_WORKSPACE "${ANYTHINGLLM_WORKSPACE:-$(env_get "$ENV_FILE" ANYTHINGLLM_WORKSPACE 2>/dev/null || printf 'crisp-support')}"
env_set "$ENV_FILE" ANYTHINGLLM_CHAT_MODE "$ANYTHING_CHAT_MODE_VALUE"
EXISTING_SNAPSHOT_MIN_FREE_MB=$(env_get "$ENV_FILE" SNAPSHOT_MIN_FREE_MB 2>/dev/null || true)
EXISTING_SNAPSHOT_RETENTION_COUNT=$(env_get "$ENV_FILE" SNAPSHOT_RETENTION_COUNT 2>/dev/null || true)
SNAPSHOT_MIN_FREE_MB_VALUE=${SNAPSHOT_MIN_FREE_MB:-${EXISTING_SNAPSHOT_MIN_FREE_MB:-1024}}
SNAPSHOT_RETENTION_COUNT_VALUE=${SNAPSHOT_RETENTION_COUNT:-${EXISTING_SNAPSHOT_RETENTION_COUNT:-10}}
if [[ ! "$SNAPSHOT_MIN_FREE_MB_VALUE" =~ ^(0|[1-9][0-9]*)$ ]] \
  || (( 10#$SNAPSHOT_MIN_FREE_MB_VALUE > 2147483647 )); then
  die "SNAPSHOT_MIN_FREE_MB 必须是 0 到 2147483647 的整数"
fi
if [[ ! "$SNAPSHOT_RETENTION_COUNT_VALUE" =~ ^(0|[1-9][0-9]*)$ ]] \
  || (( 10#$SNAPSHOT_RETENTION_COUNT_VALUE > 1000 )); then
  die "SNAPSHOT_RETENTION_COUNT 必须是 0 到 1000 的整数"
fi
env_set "$ENV_FILE" SNAPSHOT_MIN_FREE_MB "$SNAPSHOT_MIN_FREE_MB_VALUE"
env_set "$ENV_FILE" SNAPSHOT_RETENTION_COUNT "$SNAPSHOT_RETENTION_COUNT_VALUE"

ensure_secret "$ENV_FILE" N8N_ENCRYPTION_KEY 32
ensure_secret "$ENV_FILE" POSTGRES_PASSWORD 32
ensure_secret "$ENV_FILE" ANYTHINGLLM_AUTH_TOKEN 24
ensure_secret "$ENV_FILE" ANYTHINGLLM_JWT_SECRET 32
ensure_secret "$ENV_FILE" ANYTHINGLLM_SIG_KEY 32
ensure_secret "$ENV_FILE" ANYTHINGLLM_SIG_SALT 32
LEGACY_WEBHOOK_SECRET=$(env_get "$ENV_FILE" CRISP_WEBHOOK_SECRET 2>/dev/null || true)
WEBSITE_HOOK_SECRET=$(env_get "$ENV_FILE" CRISP_WEBSITE_HOOK_SECRET 2>/dev/null || true)
if is_placeholder "$WEBSITE_HOOK_SECRET"; then
  if ! is_placeholder "$LEGACY_WEBHOOK_SECRET" && validate_env_value "$LEGACY_WEBHOOK_SECRET"; then
    env_set "$ENV_FILE" CRISP_WEBSITE_HOOK_SECRET "$LEGACY_WEBHOOK_SECRET"
  else
    ensure_secret "$ENV_FILE" CRISP_WEBSITE_HOOK_SECRET 32
  fi
fi

if (( EXISTING == 0 || RECONFIGURE == 1 )); then
  if (( NON_INTERACTIVE )); then
    N8N_HOST_VALUE=${N8N_HOST:-localhost}
    PUBLIC_URL_VALUE=${PUBLIC_WEBHOOK_URL:-https://${N8N_HOST_VALUE}/}
    TIMEZONE_VALUE=${TIMEZONE:-UTC}
    CRISP_WEBSITE_VALUE=${CRISP_WEBSITE_ID:-}
    CRISP_TIER_VALUE=${CRISP_TOKEN_TIER:-website}
    CRISP_HOOK_MODE_VALUE=${CRISP_HOOK_MODE:-website}
    CRISP_PLUGIN_SECRET_VALUE=${CRISP_PLUGIN_SIGNING_SECRET:-}
    CRISP_IDENTIFIER_VALUE=${CRISP_TOKEN_IDENTIFIER:-}
    CRISP_KEY_VALUE=${CRISP_TOKEN_KEY:-}
    ANYTHING_KEY_VALUE=${ANYTHINGLLM_API_KEY:-pending-anythingllm-api-key}
  else
    printf 'n8n 公网域名（不含协议）：'
    IFS= read -r N8N_HOST_VALUE
    N8N_HOST_VALUE=${N8N_HOST_VALUE:-localhost}
    printf 'Webhook 公网地址 [https://%s/]：' "$N8N_HOST_VALUE"
    IFS= read -r PUBLIC_URL_VALUE
    PUBLIC_URL_VALUE=${PUBLIC_URL_VALUE:-https://${N8N_HOST_VALUE}/}
    printf '时区 [UTC]：'
    IFS= read -r TIMEZONE_VALUE
    TIMEZONE_VALUE=${TIMEZONE_VALUE:-UTC}
    printf 'Crisp Website ID：'
    IFS= read -r CRISP_WEBSITE_VALUE
    printf 'Crisp Token tier（website/plugin）[website]：'
    IFS= read -r CRISP_TIER_VALUE
    CRISP_TIER_VALUE=${CRISP_TIER_VALUE:-website}
    printf 'Crisp Token Identifier：'
    IFS= read -r CRISP_IDENTIFIER_VALUE
    printf 'Crisp Token Key（输入内容不会显示）：'
    IFS= read -r -s CRISP_KEY_VALUE
    printf '\nCrisp Hook 模式（website/plugin）[website]：'
    IFS= read -r CRISP_HOOK_MODE_VALUE
    CRISP_HOOK_MODE_VALUE=${CRISP_HOOK_MODE_VALUE:-website}
    CRISP_PLUGIN_SECRET_VALUE=""
    if [[ "$CRISP_HOOK_MODE_VALUE" == plugin ]]; then
      printf 'Crisp Plugin Hook Signing Secret（输入内容不会显示）：'
      IFS= read -r -s CRISP_PLUGIN_SECRET_VALUE
    fi
    printf '\nAnythingLLM Developer API Key（可留空，启动后自动创建）：'
    IFS= read -r -s ANYTHING_KEY_VALUE
    printf '\n'
    ANYTHING_KEY_VALUE=${ANYTHING_KEY_VALUE:-pending-anythingllm-api-key}
  fi

  validate_hostname "$N8N_HOST_VALUE" || die "n8n 域名无效；只填写主机名，不含协议、端口或路径"
  validate_public_url "$PUBLIC_URL_VALUE" \
    || die "Webhook 公网地址必须是不含认证信息、查询参数或路径穿越且以 / 结尾的 HTTP(S) 地址"
  validate_env_value "$TIMEZONE_VALUE" || die "时区无效"
  [[ "$CRISP_WEBSITE_VALUE" =~ ^[A-Za-z0-9-]{8,128}$ ]] || die "Crisp Website ID 格式无效"
  [[ "$CRISP_TIER_VALUE" == website || "$CRISP_TIER_VALUE" == plugin ]] || die "Crisp Token tier 只能是 website 或 plugin"
  [[ "$CRISP_HOOK_MODE_VALUE" == website || "$CRISP_HOOK_MODE_VALUE" == plugin ]] || die "Crisp Hook 模式只能是 website 或 plugin"
  if [[ "$CRISP_HOOK_MODE_VALUE" == plugin ]]; then
    validate_env_value "$CRISP_PLUGIN_SECRET_VALUE" || die "Plugin Hook Signing Secret 无效或为空"
  fi
  if ! validate_env_value "$CRISP_IDENTIFIER_VALUE" || [[ "$CRISP_IDENTIFIER_VALUE" == *:* ]]; then
    die "Crisp Token Identifier 无效"
  fi
  validate_env_value "$CRISP_KEY_VALUE" || die "Crisp Token Key 无效"
  validate_env_value "$ANYTHING_KEY_VALUE" || die "AnythingLLM API Key 无效"

  CRISP_AUTH_VALUE=$(printf '%s' "${CRISP_IDENTIFIER_VALUE}:${CRISP_KEY_VALUE}" | base64 | tr -d '\n')
  env_set "$ENV_FILE" N8N_HOST "$N8N_HOST_VALUE"
  env_set "$ENV_FILE" PUBLIC_WEBHOOK_URL "$PUBLIC_URL_VALUE"
  env_set "$ENV_FILE" N8N_PROTOCOL "$( [[ "$PUBLIC_URL_VALUE" == https://* ]] && printf https || printf http )"
  env_set "$ENV_FILE" N8N_SECURE_COOKIE "$( [[ "$PUBLIC_URL_VALUE" == https://* ]] && printf true || printf false )"
  env_set "$ENV_FILE" TIMEZONE "$TIMEZONE_VALUE"
  env_set "$ENV_FILE" CRISP_WEBSITE_ID "$CRISP_WEBSITE_VALUE"
  env_set "$ENV_FILE" CRISP_TOKEN_TIER "$CRISP_TIER_VALUE"
  env_set "$ENV_FILE" CRISP_TOKEN_IDENTIFIER "$CRISP_IDENTIFIER_VALUE"
  env_set "$ENV_FILE" CRISP_TOKEN_KEY "$CRISP_KEY_VALUE"
  env_set "$ENV_FILE" CRISP_AUTH_B64 "$CRISP_AUTH_VALUE"
  env_set "$ENV_FILE" CRISP_HOOK_MODE "$CRISP_HOOK_MODE_VALUE"
  if [[ "$CRISP_HOOK_MODE_VALUE" == plugin ]]; then
    env_set "$ENV_FILE" CRISP_PLUGIN_SIGNING_SECRET "$CRISP_PLUGIN_SECRET_VALUE"
  fi
  env_set "$ENV_FILE" ANYTHINGLLM_API_KEY "$ANYTHING_KEY_VALUE"
  configure_provider "$DEPLOY_DIR" "$NON_INTERACTIVE"
else
  info '检测到已有配置；本次重复安装将保留 .env 和实际配置文件'
fi

migrate_runtime_env "$DEPLOY_DIR"

[[ ! -L "${DEPLOY_DIR}/data/analytics/events.jsonl" ]] || die "统计事件文件不得是符号链接"
set_runtime_ownership "$DEPLOY_DIR"
touch -- "${DEPLOY_DIR}/data/analytics/events.jsonl"
chown root:1000 "${DEPLOY_DIR}/data/analytics/events.jsonl" 2>/dev/null || true
chmod 0770 "${DEPLOY_DIR}/data/analytics"
chmod 0660 "${DEPLOY_DIR}/data/analytics/events.jsonl"
chmod 0700 "${DEPLOY_DIR}/data/postgres"
secure_permissions "$DEPLOY_DIR"

if (( SKIP_START == 0 )); then
  docker_compose "$DEPLOY_DIR" config --quiet
  docker_compose "$DEPLOY_DIR" up -d
  wait_for_local_health "$DEPLOY_DIR" 45 2
  bootstrap_anythingllm_api_key "$DEPLOY_DIR"
  ensure_anythingllm_workspace "$DEPLOY_DIR"
  docker_compose "$DEPLOY_DIR" up -d --force-recreate n8n
  wait_for_local_health "$DEPLOY_DIR" 30 2
  sync_prompt_to_anythingllm "$DEPLOY_DIR"
  import_and_publish_workflow "$DEPLOY_DIR"
  wait_for_local_health "$DEPLOY_DIR" 30 2
  "${DEPLOY_DIR}/scripts/healthcheck.sh" --deploy-dir "$DEPLOY_DIR" --installation-in-progress
  write_installation_marker "$DEPLOY_DIR" "$SCRIPT_DIR" "$VERSION" ready
else
  if [[ "$PREVIOUS_STATE" == ready && "$PREVIOUS_VERSION" == "$VERSION" && $RECONFIGURE -eq 0 ]]; then
    write_installation_marker "$DEPLOY_DIR" "$SCRIPT_DIR" "$VERSION" ready
  else
    write_installation_marker "$DEPLOY_DIR" "$SCRIPT_DIR" "$VERSION" staged
  fi
fi

printf '部署目录：%s\n' "$DEPLOY_DIR"
if (( SKIP_START )) && [[ "$(installation_state "$DEPLOY_DIR")" == staged ]]; then
  printf '部署文件已暂存，尚未启动或验收。请不带 --skip-start 重新运行 install.sh。\n'
elif (( SKIP_START )); then
  printf '重复安装检查完成；现有 ready 状态未降级。\n'
else
  printf '\n安装、工作流发布与健康检查完成。\n'
  if [[ "$(env_get "$ENV_FILE" CRISP_HOOK_MODE)" == website ]]; then
    printf 'Webhook：%swebhook/crisp-webhook?key=<CRISP_WEBSITE_HOOK_SECRET>\n' "$(env_get "$ENV_FILE" PUBLIC_WEBHOOK_URL)"
  else
    printf 'Plugin Webhook：%swebhook/crisp-webhook（必须由 Crisp 签名）\n' "$(env_get "$ENV_FILE" PUBLIC_WEBHOOK_URL)"
  fi
  printf '请在 Crisp 同时订阅 message:send 与 message:received。\n'
fi
