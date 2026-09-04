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

if [[ $EUID -ne 0 ]]; then
  die "安装需要 root 权限，以便设置容器数据目录权限"
fi

EXISTING=0
if [[ -d "$DEPLOY_DIR" ]] && find "$DEPLOY_DIR" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
  if [[ -f "${DEPLOY_DIR}/${INSTALL_MARKER}" ]]; then
    assert_installation "$DEPLOY_DIR"
    EXISTING=1
  else
    die "目标目录非空且没有有效安装标记，拒绝覆盖：$DEPLOY_DIR"
  fi
fi

umask 077
copy_project_files "$SCRIPT_DIR" "$DEPLOY_DIR"
initialize_config_files "$DEPLOY_DIR"

MARKER_TEMP=$(mktemp "${DEPLOY_DIR}/${INSTALL_MARKER}.tmp.XXXXXX")
{
  printf 'ai-support\n'
  printf 'source=%s\n' "$SCRIPT_DIR"
  printf 'installed_version=%s\n' "$VERSION"
} > "$MARKER_TEMP"
chmod 600 "$MARKER_TEMP"
mv -f -- "$MARKER_TEMP" "${DEPLOY_DIR}/${INSTALL_MARKER}"

ENV_FILE="${DEPLOY_DIR}/.env"
if [[ ! -f "$ENV_FILE" ]]; then
  printf '# 此文件由 ai-support 安装程序管理，禁止提交或公开。\n' > "$ENV_FILE"
  chmod 600 "$ENV_FILE"
fi

env_set "$ENV_FILE" DEPLOY_DIR "$DEPLOY_DIR"
env_set "$ENV_FILE" BIND_ADDRESS "${BIND_ADDRESS:-127.0.0.1}"
env_set "$ENV_FILE" N8N_PORT "${N8N_PORT:-5678}"
env_set "$ENV_FILE" ANYTHINGLLM_PORT "${ANYTHINGLLM_PORT:-3001}"
env_set "$ENV_FILE" N8N_IMAGE "${N8N_IMAGE:-docker.n8n.io/n8nio/n8n:2}"
env_set "$ENV_FILE" POSTGRES_IMAGE "${POSTGRES_IMAGE:-postgres:16-alpine}"
env_set "$ENV_FILE" ANYTHINGLLM_IMAGE "${ANYTHINGLLM_IMAGE:-mintplexlabs/anythingllm:latest}"
env_set "$ENV_FILE" AI_MODEL_TOKEN_LIMIT "${AI_MODEL_TOKEN_LIMIT:-8192}"
env_set "$ENV_FILE" AI_MAX_OUTPUT_TOKENS "${AI_MAX_OUTPUT_TOKENS:-1200}"
env_set "$ENV_FILE" ANYTHINGLLM_WORKSPACE "${ANYTHINGLLM_WORKSPACE:-crisp-support}"
env_set "$ENV_FILE" ANYTHINGLLM_CHAT_MODE "${ANYTHINGLLM_CHAT_MODE:-query}"

ensure_secret "$ENV_FILE" N8N_ENCRYPTION_KEY 32
ensure_secret "$ENV_FILE" POSTGRES_PASSWORD 32
ensure_secret "$ENV_FILE" ANYTHINGLLM_AUTH_TOKEN 24
ensure_secret "$ENV_FILE" ANYTHINGLLM_JWT_SECRET 32
ensure_secret "$ENV_FILE" ANYTHINGLLM_SIG_KEY 32
ensure_secret "$ENV_FILE" ANYTHINGLLM_SIG_SALT 32
ensure_secret "$ENV_FILE" CRISP_WEBHOOK_SECRET 32

if (( EXISTING == 0 || RECONFIGURE == 1 )); then
  if (( NON_INTERACTIVE )); then
    N8N_HOST_VALUE=${N8N_HOST:-localhost}
    PUBLIC_URL_VALUE=${PUBLIC_WEBHOOK_URL:-https://${N8N_HOST_VALUE}/}
    TIMEZONE_VALUE=${TIMEZONE:-UTC}
    CRISP_WEBSITE_VALUE=${CRISP_WEBSITE_ID:-}
    CRISP_TIER_VALUE=${CRISP_TOKEN_TIER:-website}
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
    printf '\nAnythingLLM Developer API Key（可留空，首次启动后再配置）：'
    IFS= read -r -s ANYTHING_KEY_VALUE
    printf '\n'
    ANYTHING_KEY_VALUE=${ANYTHING_KEY_VALUE:-pending-anythingllm-api-key}
  fi

  validate_env_value "$N8N_HOST_VALUE" || die "n8n 域名无效"
  [[ "$PUBLIC_URL_VALUE" =~ ^https?://[^[:space:]#]+/$ ]] || die "Webhook 公网地址必须是以 / 结尾的 HTTP(S) 地址"
  validate_env_value "$PUBLIC_URL_VALUE" || die "Webhook 公网地址包含不安全字符"
  validate_env_value "$TIMEZONE_VALUE" || die "时区无效"
  [[ "$CRISP_WEBSITE_VALUE" =~ ^[A-Za-z0-9-]{8,128}$ ]] || die "Crisp Website ID 格式无效"
  [[ "$CRISP_TIER_VALUE" == website || "$CRISP_TIER_VALUE" == plugin ]] || die "Crisp Token tier 只能是 website 或 plugin"
  validate_env_value "$CRISP_IDENTIFIER_VALUE" || die "Crisp Token Identifier 无效"
  validate_env_value "$CRISP_KEY_VALUE" || die "Crisp Token Key 无效"
  validate_env_value "$ANYTHING_KEY_VALUE" || die "AnythingLLM API Key 无效"

  CRISP_AUTH_VALUE=$(printf '%s' "${CRISP_IDENTIFIER_VALUE}:${CRISP_KEY_VALUE}" | base64 | tr -d '\n')
  env_set "$ENV_FILE" N8N_HOST "$N8N_HOST_VALUE"
  env_set "$ENV_FILE" PUBLIC_WEBHOOK_URL "$PUBLIC_URL_VALUE"
  env_set "$ENV_FILE" N8N_SECURE_COOKIE "$( [[ "$PUBLIC_URL_VALUE" == https://* ]] && printf true || printf false )"
  env_set "$ENV_FILE" TIMEZONE "$TIMEZONE_VALUE"
  env_set "$ENV_FILE" CRISP_WEBSITE_ID "$CRISP_WEBSITE_VALUE"
  env_set "$ENV_FILE" CRISP_TOKEN_TIER "$CRISP_TIER_VALUE"
  env_set "$ENV_FILE" CRISP_TOKEN_IDENTIFIER "$CRISP_IDENTIFIER_VALUE"
  env_set "$ENV_FILE" CRISP_TOKEN_KEY "$CRISP_KEY_VALUE"
  env_set "$ENV_FILE" CRISP_AUTH_B64 "$CRISP_AUTH_VALUE"
  env_set "$ENV_FILE" ANYTHINGLLM_API_KEY "$ANYTHING_KEY_VALUE"
  configure_provider "$DEPLOY_DIR" "$NON_INTERACTIVE"
else
  info '检测到已有配置；本次重复安装将保留 .env 和实际配置文件'
fi

chown -R root:1000 "${DEPLOY_DIR}/config" "${DEPLOY_DIR}/knowledge" "${DEPLOY_DIR}/n8n" \
  "${DEPLOY_DIR}/data/n8n" "${DEPLOY_DIR}/data/anythingllm" 2>/dev/null || true
chmod 0750 "${DEPLOY_DIR}/data/n8n" "${DEPLOY_DIR}/data/anythingllm"
chmod 0700 "${DEPLOY_DIR}/data/postgres"
secure_permissions "$DEPLOY_DIR"

if (( SKIP_START == 0 )); then
  require_command docker
  docker compose version >/dev/null 2>&1 || die "未检测到 Docker Compose v2"
  docker_compose "$DEPLOY_DIR" config --quiet
  docker_compose "$DEPLOY_DIR" up -d

  for (( attempt = 1; attempt <= 30; attempt++ )); do
    if docker_compose "$DEPLOY_DIR" exec -T n8n n8n --version >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done
  if anythingllm_api_ready "$DEPLOY_DIR"; then
    sync_prompt_to_anythingllm "$DEPLOY_DIR" || warn "Prompt 尚未同步，请确认 AnythingLLM 工作区已创建"
    import_and_publish_workflow "$DEPLOY_DIR" || warn "工作流尚未发布，请从管理菜单重试"
  else
    docker_compose "$DEPLOY_DIR" exec -T n8n n8n import:workflow --input=/opt/crisp-ai/n8n/workflow.json >/dev/null || warn "n8n 工作流自动导入失败，请稍后从管理菜单重试"
    warn "AnythingLLM Developer API Key 尚未配置，工作流保持未发布"
  fi
fi

printf '\n安装完成。\n'
printf '部署目录：%s\n' "$DEPLOY_DIR"
printf 'Webhook：%swebhook/crisp-webhook?key=<CRISP_WEBHOOK_SECRET>\n' "$(env_get "$ENV_FILE" PUBLIC_WEBHOOK_URL)"
printf '下一步：初始化 AnythingLLM 工作区并运行 %s/manage.sh。\n' "$DEPLOY_DIR"
