#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/scripts/common.sh"

DEPLOY_REQUEST=""
NON_INTERACTIVE=0
SKIP_START=0
RECONFIGURE=0

validate_preserved_installation() {
  local deploy_dir=$1
  local env_file="${deploy_dir}/.env"
  local config_file key value hook_mode expected_auth provider_base provider_model provider_mode
  local normalized_api_base model_token_limit max_output_tokens public_url n8n_protocol
  local -a required_config_files=(
    provider.yaml prompt.md keyword.yaml menu.yaml handoff.yaml tags.yaml feedback.yaml
  )
  local -a json_config_files=(keyword.yaml menu.yaml handoff.yaml tags.yaml feedback.yaml)
  local -a required_env_keys=(
    DEPLOY_DIR BIND_ADDRESS N8N_PORT ANYTHINGLLM_PORT N8N_HOST PUBLIC_WEBHOOK_URL TIMEZONE
    N8N_ENCRYPTION_KEY POSTGRES_PASSWORD ANYTHINGLLM_AUTH_TOKEN ANYTHINGLLM_JWT_SECRET
    ANYTHINGLLM_SIG_KEY ANYTHINGLLM_SIG_SALT AI_API_BASE_URL AI_API_KEY AI_MODEL
    AI_API_MODE AI_SUPPORTS_VISION AI_MODEL_TOKEN_LIMIT AI_MAX_OUTPUT_TOKENS
    ANYTHINGLLM_API_KEY ANYTHINGLLM_WORKSPACE ANYTHINGLLM_CHAT_MODE
    CRISP_WEBSITE_ID CRISP_TOKEN_TIER CRISP_TOKEN_IDENTIFIER CRISP_TOKEN_KEY
    CRISP_AUTH_B64 CRISP_HOOK_MODE N8N_PROTOCOL N8N_SECURE_COOKIE
    SNAPSHOT_MIN_FREE_MB SNAPSHOT_RETENTION_COUNT
  )
  local -a reconfigure_reasons=()
  local -a invalid_config=()

  if [[ -e "$env_file" || -L "$env_file" ]]; then
    [[ -f "$env_file" && ! -L "$env_file" ]] \
      || die "安全卸载保留的 .env 不是安全普通文件；请先人工检查，未改写保留配置或业务数据"
    [[ "$(stat -c '%a' "$env_file")" == 600 ]] \
      || die "安全卸载保留的 .env 权限必须为 0600；请修正权限后重试"
  else
    reconfigure_reasons+=(.env)
  fi

  for config_file in "${required_config_files[@]}"; do
    if [[ -e "${deploy_dir}/config/${config_file}" || -L "${deploy_dir}/config/${config_file}" ]]; then
      [[ -f "${deploy_dir}/config/${config_file}" && ! -L "${deploy_dir}/config/${config_file}" ]] \
        || die "安全卸载保留的配置不是安全普通文件：config/${config_file}；请先人工检查"
      [[ -s "${deploy_dir}/config/${config_file}" ]] || invalid_config+=("config/${config_file}")
    else
      reconfigure_reasons+=("config/${config_file}")
    fi
  done

  if [[ -f "$env_file" && ! -L "$env_file" ]]; then
    for key in "${required_env_keys[@]}"; do
      value=$(env_get "$env_file" "$key" 2>/dev/null || true)
      if is_placeholder "$value" || ! validate_env_value "$value"; then
        reconfigure_reasons+=(".env:${key}")
      fi
    done

    value=$(env_get "$env_file" DEPLOY_DIR 2>/dev/null || true)
    [[ "$value" == "$deploy_dir" ]] || reconfigure_reasons+=(".env:DEPLOY_DIR")
    value=$(env_get "$env_file" BIND_ADDRESS 2>/dev/null || true)
    validate_ipv4_address "$value" || reconfigure_reasons+=(".env:BIND_ADDRESS")
    value=$(env_get "$env_file" N8N_PORT 2>/dev/null || true)
    validate_port "$value" || reconfigure_reasons+=(".env:N8N_PORT")
    value=$(env_get "$env_file" ANYTHINGLLM_PORT 2>/dev/null || true)
    validate_port "$value" || reconfigure_reasons+=(".env:ANYTHINGLLM_PORT")
    value=$(env_get "$env_file" N8N_HOST 2>/dev/null || true)
    validate_hostname "$value" || reconfigure_reasons+=(".env:N8N_HOST")
    public_url=$(env_get "$env_file" PUBLIC_WEBHOOK_URL 2>/dev/null || true)
    validate_public_url "$public_url" || reconfigure_reasons+=(".env:PUBLIC_WEBHOOK_URL")
    value=$(env_get "$env_file" AI_API_BASE_URL 2>/dev/null || true)
    normalized_api_base=$(normalize_api_base "$value" 2>/dev/null || true)
    [[ -n "$normalized_api_base" && "$normalized_api_base" == "$value" ]] \
      || reconfigure_reasons+=(".env:AI_API_BASE_URL")
    value=$(env_get "$env_file" CRISP_WEBSITE_ID 2>/dev/null || true)
    [[ "$value" =~ ^[A-Za-z0-9-]{8,128}$ ]] || reconfigure_reasons+=(".env:CRISP_WEBSITE_ID")
    value=$(env_get "$env_file" CRISP_TOKEN_TIER 2>/dev/null || true)
    [[ "$value" == website || "$value" == plugin ]] || reconfigure_reasons+=(".env:CRISP_TOKEN_TIER")
    value=$(env_get "$env_file" CRISP_TOKEN_IDENTIFIER 2>/dev/null || true)
    [[ "$value" != *:* ]] || reconfigure_reasons+=(".env:CRISP_TOKEN_IDENTIFIER")
    value=$(env_get "$env_file" AI_API_MODE 2>/dev/null || true)
    [[ "$value" == responses || "$value" == chat_completions ]] \
      || reconfigure_reasons+=(".env:AI_API_MODE")
    value=$(env_get "$env_file" AI_SUPPORTS_VISION 2>/dev/null || true)
    [[ "$value" == true || "$value" == false ]] || reconfigure_reasons+=(".env:AI_SUPPORTS_VISION")
    value=$(env_get "$env_file" ANYTHINGLLM_CHAT_MODE 2>/dev/null || true)
    [[ "$value" == chat ]] || reconfigure_reasons+=(".env:ANYTHINGLLM_CHAT_MODE")
    n8n_protocol=$(env_get "$env_file" N8N_PROTOCOL 2>/dev/null || true)
    [[ "$n8n_protocol" == http || "$n8n_protocol" == https ]] \
      || reconfigure_reasons+=(".env:N8N_PROTOCOL")
    [[ "$public_url" == "${n8n_protocol}:"* ]] || reconfigure_reasons+=(".env:N8N_PROTOCOL")
    value=$(env_get "$env_file" N8N_SECURE_COOKIE 2>/dev/null || true)
    [[ "$value" == true || "$value" == false ]] || reconfigure_reasons+=(".env:N8N_SECURE_COOKIE")
    if [[ "$public_url" == https://* && "$value" != true ]] \
      || [[ "$public_url" == http://* && "$value" != false ]]; then
      reconfigure_reasons+=(".env:N8N_SECURE_COOKIE")
    fi
    model_token_limit=$(env_get "$env_file" AI_MODEL_TOKEN_LIMIT 2>/dev/null || true)
    if [[ ! "$model_token_limit" =~ ^[1-9][0-9]{1,6}$ ]] \
      || (( 10#${model_token_limit:-0} > 2000000 )); then
      reconfigure_reasons+=(".env:AI_MODEL_TOKEN_LIMIT")
    fi
    max_output_tokens=$(env_get "$env_file" AI_MAX_OUTPUT_TOKENS 2>/dev/null || true)
    if [[ ! "$max_output_tokens" =~ ^[1-9][0-9]{0,6}$ ]]; then
      reconfigure_reasons+=(".env:AI_MAX_OUTPUT_TOKENS")
    elif [[ "$model_token_limit" =~ ^[1-9][0-9]{1,6}$ ]] \
      && (( 10#$max_output_tokens > 10#$model_token_limit )); then
      reconfigure_reasons+=(".env:AI_MAX_OUTPUT_TOKENS")
    fi
    for key in SNAPSHOT_MIN_FREE_MB SNAPSHOT_RETENTION_COUNT; do
      value=$(env_get "$env_file" "$key" 2>/dev/null || true)
      [[ "$value" =~ ^(0|[1-9][0-9]*)$ ]] || reconfigure_reasons+=(".env:${key}")
    done
    value=$(env_get "$env_file" SNAPSHOT_MIN_FREE_MB 2>/dev/null || true)
    if [[ "$value" =~ ^(0|[1-9][0-9]*)$ ]] && (( 10#$value > 2147483647 )); then
      reconfigure_reasons+=(".env:SNAPSHOT_MIN_FREE_MB")
    fi
    value=$(env_get "$env_file" SNAPSHOT_RETENTION_COUNT 2>/dev/null || true)
    if [[ "$value" =~ ^(0|[1-9][0-9]*)$ ]] && (( 10#$value > 1000 )); then
      reconfigure_reasons+=(".env:SNAPSHOT_RETENTION_COUNT")
    fi
    hook_mode=$(env_get "$env_file" CRISP_HOOK_MODE 2>/dev/null || true)
    case "$hook_mode" in
      website)
        value=$(env_get "$env_file" CRISP_WEBSITE_HOOK_SECRET 2>/dev/null || true)
        if is_placeholder "$value" || ! validate_env_value "$value"; then
          reconfigure_reasons+=(".env:CRISP_WEBSITE_HOOK_SECRET")
        fi
        ;;
      plugin)
        value=$(env_get "$env_file" CRISP_PLUGIN_SIGNING_SECRET 2>/dev/null || true)
        if is_placeholder "$value" || ! validate_env_value "$value"; then
          reconfigure_reasons+=(".env:CRISP_PLUGIN_SIGNING_SECRET")
        fi
        ;;
      *) reconfigure_reasons+=(".env:CRISP_HOOK_MODE") ;;
    esac

    if ! is_placeholder "$(env_get "$env_file" CRISP_TOKEN_IDENTIFIER 2>/dev/null || true)" \
      && ! is_placeholder "$(env_get "$env_file" CRISP_TOKEN_KEY 2>/dev/null || true)"; then
      expected_auth=$(printf '%s' \
        "$(env_get "$env_file" CRISP_TOKEN_IDENTIFIER):$(env_get "$env_file" CRISP_TOKEN_KEY)" \
        | base64 | tr -d '\n')
      [[ "$(env_get "$env_file" CRISP_AUTH_B64 2>/dev/null || true)" == "$expected_auth" ]] \
        || reconfigure_reasons+=(".env:CRISP_AUTH_B64")
    fi
  fi

  for config_file in "${json_config_files[@]}"; do
    [[ -s "${deploy_dir}/config/${config_file}" ]] || continue
    case "$config_file" in
      keyword.yaml) jq -e '.keywords | type == "array"' "${deploy_dir}/config/${config_file}" >/dev/null 2>&1 ;;
      menu.yaml) jq -e '.menus | type == "object"' "${deploy_dir}/config/${config_file}" >/dev/null 2>&1 ;;
      handoff.yaml) jq -e '.handoff | type == "object"' "${deploy_dir}/config/${config_file}" >/dev/null 2>&1 ;;
      tags.yaml) jq -e '.tags | type == "object"' "${deploy_dir}/config/${config_file}" >/dev/null 2>&1 ;;
      feedback.yaml) jq -e '.feedback | type == "object"' "${deploy_dir}/config/${config_file}" >/dev/null 2>&1 ;;
    esac || invalid_config+=("config/${config_file}")
  done
  if [[ -s "${deploy_dir}/config/provider.yaml" ]]; then
    if provider_config_has_secret_field "${deploy_dir}/config/provider.yaml" \
      || ! grep -Eq '^[[:space:]]*type:[[:space:]]*openai-compatible[[:space:]]*$' \
        "${deploy_dir}/config/provider.yaml" \
      || ! grep -Eq '^[[:space:]]*base_url:[[:space:]]*"?https?://[^"[:space:]]+"?[[:space:]]*$' \
        "${deploy_dir}/config/provider.yaml" \
      || ! grep -Eq '^[[:space:]]*api_key_env:[[:space:]]*AI_API_KEY[[:space:]]*$' \
        "${deploy_dir}/config/provider.yaml" \
      || ! grep -Eq '^[[:space:]]*model:[[:space:]]*"?[^"[:space:]]+"?[[:space:]]*$' \
        "${deploy_dir}/config/provider.yaml"; then
      invalid_config+=(config/provider.yaml)
    else
      provider_base=$(sed -n 's/^[[:space:]]*base_url:[[:space:]]*//p' \
        "${deploy_dir}/config/provider.yaml" | head -n 1)
      provider_model=$(sed -n 's/^[[:space:]]*model:[[:space:]]*//p' \
        "${deploy_dir}/config/provider.yaml" | head -n 1)
      provider_mode=$(sed -n 's/^[[:space:]]*api_mode:[[:space:]]*//p' \
        "${deploy_dir}/config/provider.yaml" | head -n 1)
      provider_base=${provider_base#\"}; provider_base=${provider_base%\"}
      provider_model=${provider_model#\"}; provider_model=${provider_model%\"}
      [[ "$provider_base" == "$(env_get "$env_file" AI_API_BASE_URL 2>/dev/null || true)" \
        && "$provider_model" == "$(env_get "$env_file" AI_MODEL 2>/dev/null || true)" \
        && "$provider_mode" == "$(env_get "$env_file" AI_API_MODE 2>/dev/null || true)" ]] \
        || invalid_config+=(config/provider.yaml)
    fi
  fi

  if (( ${#invalid_config[@]} > 0 )); then
    die "安全卸载保留的实际配置无效（${invalid_config[*]}）；请从备份恢复，或移除损坏文件后使用 --reconfigure，未改写保留配置或业务数据"
  fi
  if (( ${#reconfigure_reasons[@]} > 0 )); then
    die "安全卸载保留配置缺失、不一致或包含占位值（${reconfigure_reasons[*]}）；请使用 --reconfigure 重新输入 Provider/Crisp 凭据，未改写保留配置或业务数据"
  fi
}

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
require_command stat

if [[ $EUID -ne 0 ]]; then
  die "安装需要 root 权限，以便设置容器数据目录权限"
fi

if (( SKIP_START == 0 )); then
  require_docker_runtime
fi

EXISTING=0
REUSE_PRESERVED_CONFIG=0
PREVIOUS_STATE="new"
PREVIOUS_VERSION=""
if [[ -d "$DEPLOY_DIR" ]] && find "$DEPLOY_DIR" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
  if [[ -f "${DEPLOY_DIR}/${INSTALL_MARKER}" ]]; then
    assert_managed_installation "$DEPLOY_DIR"
    PREVIOUS_STATE=$(installation_state "$DEPLOY_DIR")
    [[ ! -f "${DEPLOY_DIR}/VERSION" ]] || PREVIOUS_VERSION=$(<"${DEPLOY_DIR}/VERSION")
    case "$PREVIOUS_STATE" in
      ready) EXISTING=1 ;;
      uninstalled-data-kept)
        if (( RECONFIGURE )); then
          warn "检测到安全卸载后的保留数据，本次将按 --reconfigure 重新配置"
        else
          REUSE_PRESERVED_CONFIG=1
        fi
        ;;
      *)
        warn "检测到未完成的部署状态（${PREVIOUS_STATE}），本次将安全重试安装"
        ;;
    esac
  else
    die "目标目录非空且没有有效安装标记，拒绝覆盖：$DEPLOY_DIR"
  fi
fi

umask 077
mkdir -p -- "$DEPLOY_DIR"
acquire_maintenance_lock "$DEPLOY_DIR"
if (( REUSE_PRESERVED_CONFIG )); then
  validate_preserved_installation "$DEPLOY_DIR"
  EXISTING=1
  info '已验证安全卸载保留的 .env 与实际配置；本次将直接复用，不重新输入凭据'
fi
if (( EXISTING == 1 )) && [[ -n "$PREVIOUS_VERSION" && "$PREVIOUS_VERSION" != "$VERSION" ]]; then
  die "检测到不同版本的现有部署（${PREVIOUS_VERSION} -> ${VERSION}）；请使用 update.sh 创建一致性快照后升级"
fi
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
