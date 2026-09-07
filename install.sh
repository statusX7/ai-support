#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/bootstrap.sh
source "${SCRIPT_DIR}/scripts/bootstrap.sh"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/scripts/common.sh"
# shellcheck source=scripts/wizard.sh
source "${SCRIPT_DIR}/scripts/wizard.sh"
# shellcheck source=scripts/launcher.sh
source "${SCRIPT_DIR}/scripts/launcher.sh"

ORIGINAL_ARGS=("$@")
DEPLOY_REQUEST=""
NON_INTERACTIVE=0
SKIP_START=0
RECONFIGURE=0
COMMAND_PATH=""

handle_install_interrupt() {
  # timeout 和终端可能把同一中断同时投递给进程及进程组；收尾期间忽略重复信号，
  # 确保恢复说明完整写出，再以稳定的中断状态退出。
  trap '' INT TERM
  printf '\n警告：安装已中断；已完成的初始化或安装步骤可在下次运行同一命令时恢复。\n' >&2
  exit 130
}

trap handle_install_interrupt INT TERM

validate_preserved_installation() {
  local deploy_dir=$1
  local env_file="${deploy_dir}/.env"
  local config_file key value hook_mode expected_auth provider_base provider_model provider_mode
  local provider_probe_base normalized_probe_base expected_runtime_base
  local model_token_limit max_output_tokens public_url n8n_protocol
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
    provider_probe_base=$(env_get "$env_file" AI_API_PROBE_BASE_URL 2>/dev/null || true)
    normalized_probe_base=$(normalize_api_base "${provider_probe_base:-$value}" 2>/dev/null || true)
    expected_runtime_base=$(provider_runtime_base "$normalized_probe_base" 2>/dev/null || true)
    [[ -n "$expected_runtime_base" && "$expected_runtime_base" == "$value" ]] \
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
      keyword.yaml) jq -e '(.keywords | type == "array") or (.schema_version==2 and (.rules | type == "array"))' "${deploy_dir}/config/${config_file}" >/dev/null 2>&1 ;;
      menu.yaml) jq -e '.menus | type == "object"' "${deploy_dir}/config/${config_file}" >/dev/null 2>&1 ;;
      handoff.yaml) jq -e '.handoff | type == "object"' "${deploy_dir}/config/${config_file}" >/dev/null 2>&1 ;;
      tags.yaml) jq -e '.tags | type == "object"' "${deploy_dir}/config/${config_file}" >/dev/null 2>&1 ;;
      feedback.yaml) jq -e '.feedback | type == "object"' "${deploy_dir}/config/${config_file}" >/dev/null 2>&1 ;;
    esac || invalid_config+=("config/${config_file}")
  done
  if [[ -s "${deploy_dir}/config/provider.yaml" ]]; then
    if jq -e '.provider | type=="object" and (.base_url|type=="string") and (.model|type=="string") and (.api_mode=="responses" or .api_mode=="chat_completions") and (.api_key_env=="AI_API_KEY")' "${deploy_dir}/config/provider.yaml" >/dev/null 2>&1; then
      provider_base=$(jq -r '.provider.base_url' "${deploy_dir}/config/provider.yaml")
      provider_model=$(jq -r '.provider.model' "${deploy_dir}/config/provider.yaml")
      provider_mode=$(jq -r '.provider.api_mode' "${deploy_dir}/config/provider.yaml")
      [[ "$provider_base" == "$(env_get "$env_file" AI_API_BASE_URL 2>/dev/null || true)" \
        && "$provider_model" == "$(env_get "$env_file" AI_MODEL 2>/dev/null || true)" \
        && "$provider_mode" == "$(env_get "$env_file" AI_API_MODE 2>/dev/null || true)" ]] \
        || invalid_config+=(config/provider.yaml)
      jq -e '[.. | objects | keys[] | ascii_downcase] | all(. != "api_key" and . != "token" and . != "secret" and . != "custom_headers")' "${deploy_dir}/config/provider.yaml" >/dev/null \
        || invalid_config+=(config/provider.yaml)
    elif provider_config_has_secret_field "${deploy_dir}/config/provider.yaml" \
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

installation_config_is_reusable() {
  local deploy_dir=$1
  (validate_preserved_installation "$deploy_dir") >/dev/null 2>&1
}

usage() {
  cat <<'EOF'
用法：./install.sh [选项]

选项：
  --deploy-dir PATH   指定部署目录，默认 /opt/crisp-ai
  --command-path PATH 高级：管理入口的绝对路径，默认 /usr/local/bin/crispai
  --non-interactive   从环境变量读取配置，不进行交互
  --skip-start        只安装文件，不启动 Docker 服务
  --reconfigure       重复安装时重新配置 Provider 与 Crisp
  --version           显示版本
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
    --command-path)
      (( $# >= 2 )) || die '--command-path 缺少参数'
      COMMAND_PATH=$2
      shift 2
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
    --version)
      printf '%s\n' "$(<"${SCRIPT_DIR}/VERSION")"
      exit 0
      ;;
    *)
      die "未知选项：$1"
      ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    exec sudo --preserve-env=AI_API_BASE_URL,AI_API_KEY,AI_MODEL,DEFAULT_AI_MODEL,CRISP_WEBSITE_ID,CRISP_TOKEN_TIER,CRISP_TOKEN_IDENTIFIER,CRISP_TOKEN_KEY,CRISP_HOOK_MODE,CRISP_PLUGIN_SIGNING_SECRET,PUBLIC_WEBHOOK_URL,WEBHOOK_PRODUCTION_URL,WEBHOOK_ACCESS_MODE,N8N_HOST,TIMEZONE,ANYTHINGLLM_API_KEY,ANYTHINGLLM_WORKSPACE,ANYTHINGLLM_CHAT_MODE,BIND_ADDRESS,N8N_PORT,ANYTHINGLLM_PORT,N8N_IMAGE,POSTGRES_IMAGE,ANYTHINGLLM_IMAGE,CADDY_IMAGE,AI_MODEL_TOKEN_LIMIT,AI_MAX_OUTPUT_TOKENS,SNAPSHOT_MIN_FREE_MB,SNAPSHOT_RETENTION_COUNT \
      bash "$SCRIPT_DIR/install.sh" "${ORIGINAL_ARGS[@]}"
  fi
  die "安装需要 root 权限；请使用 sudo bash ./install.sh，或由 root 直接运行"
fi

VERSION=$(<"${SCRIPT_DIR}/VERSION")
printf '%s\n' '================================'
printf ' AI客服管理系统 %s\n' "$VERSION"
printf '%s\n\n' '================================'

bootstrap_prepare_minimal_dependencies \
  || die "基础依赖自动安装失败；修复网络或软件包管理器后重新运行，已完成进度会保留"
DEPLOY_DIR=$(resolve_deploy_dir "${DEPLOY_REQUEST:-$DEFAULT_DEPLOY_DIR}")

EXISTING=0
REUSE_PRESERVED_CONFIG=0
REUSE_CONFIG_REASON=""
PREVIOUS_STATE="new"
PREVIOUS_VERSION=""
if [[ -d "$DEPLOY_DIR" ]] && find "$DEPLOY_DIR" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
  if [[ -f "${DEPLOY_DIR}/${INSTALL_MARKER}" ]]; then
    assert_managed_installation "$DEPLOY_DIR"
    PREVIOUS_STATE=$(installation_state "$DEPLOY_DIR")
    [[ ! -f "${DEPLOY_DIR}/VERSION" ]] || PREVIOUS_VERSION=$(<"${DEPLOY_DIR}/VERSION")
    case "$PREVIOUS_STATE" in
      ready|local-ready) EXISTING=1 ;;
      collecting)
        warn "检测到未完成的快速初始化，本次将从保存的步骤继续"
        ;;
      installing|failed)
        if (( RECONFIGURE )); then
          warn "检测到未完成的部署状态（${PREVIOUS_STATE}），本次将按 --reconfigure 重新配置"
        elif installation_config_is_reusable "$DEPLOY_DIR"; then
          REUSE_PRESERVED_CONFIG=1
          REUSE_CONFIG_REASON=incomplete
        else
          warn "检测到未完成的部署状态（${PREVIOUS_STATE}），现有配置不完整，将返回快速初始化"
        fi
        ;;
      uninstalled-data-kept)
        if (( RECONFIGURE )); then
          warn "检测到安全卸载后的保留数据，本次将按 --reconfigure 重新配置"
        else
          REUSE_PRESERVED_CONFIG=1
          REUSE_CONFIG_REASON=uninstalled
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
  if [[ "$REUSE_CONFIG_REASON" == incomplete ]]; then
    info '已验证未完成部署的 .env 与实际配置；本次将直接复用并继续，不重新输入凭据'
  else
    info '已验证安全卸载保留的 .env 与实际配置；本次将直接复用，不重新输入凭据'
  fi
fi
if (( EXISTING == 1 )) && [[ -n "$PREVIOUS_VERSION" && "$PREVIOUS_VERSION" != "$VERSION" ]]; then
  die "检测到不同版本的现有部署（${PREVIOUS_VERSION} -> ${VERSION}）；请使用 update.sh 创建一致性快照后升级"
fi

WIZARD_RESULT="${DEPLOY_DIR}/tmp/quick-init.json"
if (( NON_INTERACTIVE == 0 && (EXISTING == 0 || RECONFIGURE == 1) )); then
  RESTORE_STATE=$PREVIOUS_STATE
  case "$RESTORE_STATE" in ready|local-ready) ;; *) RESTORE_STATE=collecting ;; esac
  write_installation_marker "$DEPLOY_DIR" "$SCRIPT_DIR" "$VERSION" collecting
  if quick_init_wizard "$WIZARD_RESULT"; then
    :
  else
    WIZARD_STATUS_CODE=$?
    if (( WIZARD_STATUS_CODE == 2 )); then
      if [[ "$RESTORE_STATE" == ready || "$RESTORE_STATE" == local-ready ]]; then
        write_installation_marker "$DEPLOY_DIR" "$SCRIPT_DIR" "$VERSION" "$RESTORE_STATE"
      fi
      die "快速初始化已取消或输入结束；重新运行同一命令可继续"
    fi
    die "快速初始化未完成；修正提示的问题后重新运行同一命令"
  fi
fi

if (( SKIP_START == 0 )); then
  bootstrap_prepare_docker_runtime \
    || die "Docker 自动安装或真实运行验证失败；修复提示的问题后重新运行，配置进度不会丢失"
fi

write_installation_marker "$DEPLOY_DIR" "$SCRIPT_DIR" "$VERSION" installing
if (( SKIP_START == 0 )); then
  set_installation_fact "$DEPLOY_DIR" dependencies ready
else
  set_installation_fact "$DEPLOY_DIR" dependencies pending
fi
copy_project_files "$SCRIPT_DIR" "$DEPLOY_DIR"
initialize_config_files "$DEPLOY_DIR"
migrate_config_files "$DEPLOY_DIR"
bash "${DEPLOY_DIR}/scripts/configuration.sh" --deploy-dir "$DEPLOY_DIR" migrate

ENV_FILE="${DEPLOY_DIR}/.env"
if [[ ! -f "$ENV_FILE" ]]; then
  printf '# 此文件由 ai-support 安装程序管理，禁止提交或公开。\n' > "$ENV_FILE"
  chmod 600 "$ENV_FILE"
fi

env_set "$ENV_FILE" DEPLOY_DIR "$DEPLOY_DIR"
EXISTING_N8N_IMAGE=$(env_get "$ENV_FILE" N8N_IMAGE 2>/dev/null || true)
EXISTING_POSTGRES_IMAGE=$(env_get "$ENV_FILE" POSTGRES_IMAGE 2>/dev/null || true)
EXISTING_ANYTHING_IMAGE=$(env_get "$ENV_FILE" ANYTHINGLLM_IMAGE 2>/dev/null || true)
EXISTING_CADDY_IMAGE=$(env_get "$ENV_FILE" CADDY_IMAGE 2>/dev/null || true)
[[ -n "$EXISTING_N8N_IMAGE" && "$EXISTING_N8N_IMAGE" != "docker.n8n.io/n8nio/n8n:2" ]] \
  || EXISTING_N8N_IMAGE=docker.n8n.io/n8nio/n8n:2.33.0
[[ -n "$EXISTING_POSTGRES_IMAGE" && "$EXISTING_POSTGRES_IMAGE" != "postgres:16-alpine" ]] \
  || EXISTING_POSTGRES_IMAGE=postgres:16.10-alpine
[[ -n "$EXISTING_ANYTHING_IMAGE" && "$EXISTING_ANYTHING_IMAGE" != "mintplexlabs/anythingllm:latest" ]] \
  || EXISTING_ANYTHING_IMAGE=mintplexlabs/anythingllm:1.16.1
[[ -n "$EXISTING_CADDY_IMAGE" ]] || EXISTING_CADDY_IMAGE=caddy:2.10.2-alpine
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
env_set "$ENV_FILE" CADDY_IMAGE "${CADDY_IMAGE:-$EXISTING_CADDY_IMAGE}"
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
    WEBHOOK_PRODUCTION_VALUE=${WEBHOOK_PRODUCTION_URL:-${PUBLIC_URL_VALUE}webhook/crisp-webhook}
    WEBHOOK_MODE_VALUE=${WEBHOOK_ACCESS_MODE:-external_proxy}
    TIMEZONE_VALUE=${TIMEZONE:-UTC}
    CRISP_WEBSITE_VALUE=${CRISP_WEBSITE_ID:-}
    CRISP_TIER_VALUE=${CRISP_TOKEN_TIER:-website}
    CRISP_HOOK_MODE_VALUE=${CRISP_HOOK_MODE:-website}
    CRISP_PLUGIN_SECRET_VALUE=${CRISP_PLUGIN_SIGNING_SECRET:-}
    CRISP_IDENTIFIER_VALUE=${CRISP_TOKEN_IDENTIFIER:-}
    CRISP_KEY_VALUE=${CRISP_TOKEN_KEY:-}
    ANYTHING_KEY_VALUE=${ANYTHINGLLM_API_KEY:-pending-anythingllm-api-key}
  else
    [[ -f "$WIZARD_RESULT" && ! -L "$WIZARD_RESULT" ]] \
      || die "快速初始化结果缺失或不安全；请重新运行安装"
    AI_API_BASE_URL=$(jq -er '.provider.base_url | select(type == "string" and length > 0)' "$WIZARD_RESULT")
    AI_API_KEY=$(jq -er '.provider.api_key | select(type == "string" and length > 0)' "$WIZARD_RESULT")
    AI_MODEL=$(jq -er '.provider.model | select(type == "string" and length > 0)' "$WIZARD_RESULT")
    PUBLIC_URL_VALUE=$(jq -er '.webhook.public_base_url | select(type == "string" and length > 0)' "$WIZARD_RESULT")
    WEBHOOK_PRODUCTION_VALUE=$(jq -er '.webhook.production_url | select(type == "string" and length > 0)' "$WIZARD_RESULT")
    WEBHOOK_MODE_VALUE=$(jq -er '.webhook.mode | select(type == "string" and length > 0)' "$WIZARD_RESULT")
    wizard_parse_http_url "$PUBLIC_URL_VALUE" 1 || die "快速初始化保存的 Webhook 地址无效"
    N8N_HOST_VALUE=$WIZARD_URL_HOST
    TIMEZONE_VALUE=${TIMEZONE:-$(sed -n '1p' /etc/timezone 2>/dev/null || printf UTC)}
    TIMEZONE_VALUE=${TIMEZONE_VALUE:-UTC}
    CRISP_WEBSITE_VALUE=$(jq -er '.crisp.website_id | select(type == "string" and length > 0)' "$WIZARD_RESULT")
    CRISP_TIER_VALUE=website
    CRISP_IDENTIFIER_VALUE=$(jq -er '.crisp.token_identifier | select(type == "string" and length > 0)' "$WIZARD_RESULT")
    CRISP_KEY_VALUE=$(jq -er '.crisp.token_key | select(type == "string" and length > 0)' "$WIZARD_RESULT")
    CRISP_HOOK_MODE_VALUE=website
    CRISP_PLUGIN_SECRET_VALUE=""
    ANYTHING_KEY_VALUE=pending-anythingllm-api-key
  fi

  validate_hostname "$N8N_HOST_VALUE" || die "n8n 域名无效；只填写主机名，不含协议、端口或路径"
  validate_public_url "$PUBLIC_URL_VALUE" \
    || die "Webhook 公网地址必须是不含认证信息、查询参数或路径穿越且以 / 结尾的 HTTP(S) 地址"
  [[ "$WEBHOOK_PRODUCTION_VALUE" == https://*'/webhook/crisp-webhook' ]] \
    || die "生产 Webhook 地址必须使用 HTTPS 并以 /webhook/crisp-webhook 结尾"
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
  configure_webhook_access "$DEPLOY_DIR" "$WEBHOOK_MODE_VALUE" "$PUBLIC_URL_VALUE" \
    "$WEBHOOK_PRODUCTION_VALUE" "$N8N_HOST_VALUE"
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
  if (( NON_INTERACTIVE )); then
    configure_provider "$DEPLOY_DIR" 1
  else
    configure_provider "$DEPLOY_DIR" 1
    PROMPT_MODE_VALUE=$(jq -r '.prompt.mode // "default"' "$WIZARD_RESULT")
    case "$PROMPT_MODE_VALUE" in
      default) ;;
      file)
        import_prompt_source "$DEPLOY_DIR" "$(jq -er '.prompt.source | select(type == "string" and length > 0)' "$WIZARD_RESULT")"
        ;;
      inline)
        PROMPT_TEMP=$(mktemp "${DEPLOY_DIR}/config/prompt.md.tmp.XXXXXX")
        jq -j '.prompt.content' "$WIZARD_RESULT" > "$PROMPT_TEMP"
        [[ -s "$PROMPT_TEMP" ]] || { rm -f -- "$PROMPT_TEMP"; die "自定义 Prompt 不能为空"; }
        chmod 0640 "$PROMPT_TEMP"
        mv -f -- "$PROMPT_TEMP" "${DEPLOY_DIR}/config/prompt.md"
        ;;
      *) die "快速初始化 Prompt 模式无效" ;;
    esac
    if [[ "$(jq -r '.knowledge.mode // "empty"' "$WIZARD_RESULT")" == libraries ]]; then
      while IFS= read -r KNOWLEDGE_ENTRY; do
        KNOWLEDGE_LIBRARY_NAME=$(jq -r '.name' <<< "$KNOWLEDGE_ENTRY")
        KNOWLEDGE_SOURCE_VALUE=$(jq -r '.source' <<< "$KNOWLEDGE_ENTRY")
        bash "${DEPLOY_DIR}/scripts/knowledge.sh" --deploy-dir "$DEPLOY_DIR" \
          bootstrap-source "$KNOWLEDGE_LIBRARY_NAME" "$KNOWLEDGE_SOURCE_VALUE" >/dev/null
      done < <(jq -c '.knowledge.libraries[]' "$WIZARD_RESULT")
      info '命名知识库原文已导入，将在应用启动后同步并核对索引'
    else
      KNOWLEDGE_SOURCE_VALUE=$(jq -r '.knowledge.source // ""' "$WIZARD_RESULT")
      if [[ -n "$KNOWLEDGE_SOURCE_VALUE" && -f "$DEPLOY_DIR/knowledge/catalog.json" ]]; then
        bash "${DEPLOY_DIR}/scripts/knowledge.sh" --deploy-dir "$DEPLOY_DIR" \
          bootstrap-source 默认知识库 "$KNOWLEDGE_SOURCE_VALUE" >/dev/null
        info '知识来源已加入默认知识库，将在应用启动后同步并核对索引'
      else
        KNOWLEDGE_IMPORTED=$(import_knowledge_source "$DEPLOY_DIR" "$KNOWLEDGE_SOURCE_VALUE")
        info "已复制 ${KNOWLEDGE_IMPORTED} 个知识文件到受管目录"
      fi
    fi
  fi
  set_installation_fact "$DEPLOY_DIR" provider ready
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
  docker_compose "$DEPLOY_DIR" up -d --remove-orphans
  wait_for_local_health "$DEPLOY_DIR"
  set_installation_fact "$DEPLOY_DIR" local_services ready
  bootstrap_anythingllm_api_key "$DEPLOY_DIR"
  ensure_anythingllm_workspace "$DEPLOY_DIR"
  docker_compose "$DEPLOY_DIR" up -d --force-recreate n8n
  wait_for_local_health "$DEPLOY_DIR"
  sync_prompt_to_anythingllm "$DEPLOY_DIR" || die "Prompt 同步失败；保留安装进度供重试"
  knowledge_sync "$DEPLOY_DIR" || die "知识库同步未完全成功；保留安装进度供重试"
  import_and_publish_workflow "$DEPLOY_DIR" || die "n8n 工作流导入或发布失败；保留安装进度供重试"
  wait_for_local_health "$DEPLOY_DIR"
  "${DEPLOY_DIR}/scripts/healthcheck.sh" --deploy-dir "$DEPLOY_DIR" \
    --application --installation-in-progress
  bash "${DEPLOY_DIR}/scripts/configuration.sh" --deploy-dir "$DEPLOY_DIR" mark-applied \
    || die '配置或知识的运行时回读失败，安装进度已保留'
  set_installation_fact "$DEPLOY_DIR" app_config ready
  set_installation_fact "$DEPLOY_DIR" provider ready
  set_installation_fact "$DEPLOY_DIR" crisp_api pending
  set_installation_fact "$DEPLOY_DIR" webhook pending
  set_installation_fact "$DEPLOY_DIR" conversation pending
  write_installation_marker "$DEPLOY_DIR" "$SCRIPT_DIR" "$VERSION" local-ready
  install_crispai_launcher "$DEPLOY_DIR" "$NON_INTERACTIVE" "$COMMAND_PATH" \
    || die '本地服务已完成，但 crispai 管理入口安装失败；处理命令冲突后可重跑安装恢复'
  INITIAL_BACKUP="${DEPLOY_DIR}/backups/initial-${VERSION}.tar.gz"
  if [[ ! -f "$INITIAL_BACKUP" ]]; then
    "${DEPLOY_DIR}/scripts/backup.sh" --deploy-dir "$DEPLOY_DIR" --output "$INITIAL_BACKUP" \
      >/dev/null || die "首次迁移备份失败；本地服务保持 local-ready，可修复后重试"
    info "首次迁移备份已创建：$INITIAL_BACKUP（不含密钥）"
  fi
  if webhook_access_check "$DEPLOY_DIR"; then
    set_installation_fact "$DEPLOY_DIR" webhook ready
  else
    set_installation_fact "$DEPLOY_DIR" webhook pending
    warn "公网 Webhook 尚未通过 DNS/TLS/路由检查（HTTP ${WEBHOOK_ACCESS_STATUS:-000}）；本地服务保持可用"
  fi
  if crisp_api_check "$DEPLOY_DIR"; then
    set_installation_fact "$DEPLOY_DIR" crisp_api ready
  else
    set_installation_fact "$DEPLOY_DIR" crisp_api failed
  fi
  refresh_conversation_fact "$DEPLOY_DIR" || set_installation_fact "$DEPLOY_DIR" conversation pending
  if [[ "$(installation_fact "$DEPLOY_DIR" crisp_api)" == ready \
    && "$(installation_fact "$DEPLOY_DIR" webhook)" == ready \
    && "$(installation_fact "$DEPLOY_DIR" conversation)" == ready ]]; then
    write_installation_marker "$DEPLOY_DIR" "$SCRIPT_DIR" "$VERSION" ready
  else
    write_installation_marker "$DEPLOY_DIR" "$SCRIPT_DIR" "$VERSION" local-ready
  fi
  # 确认结果含外部凭据；配置与本地应用初始化成功后删除第二份明文副本。
  rm -f -- "$WIZARD_RESULT"
else
  if [[ "$PREVIOUS_STATE" == ready && "$PREVIOUS_VERSION" == "$VERSION" && $RECONFIGURE -eq 0 ]]; then
    write_installation_marker "$DEPLOY_DIR" "$SCRIPT_DIR" "$VERSION" ready
  else
    write_installation_marker "$DEPLOY_DIR" "$SCRIPT_DIR" "$VERSION" staged
  fi
  rm -f -- "$WIZARD_RESULT"
fi

printf '部署目录：%s\n' "$DEPLOY_DIR"
if (( SKIP_START )) && [[ "$(installation_state "$DEPLOY_DIR")" == staged ]]; then
  printf '部署文件已暂存，尚未启动或验收。请不带 --skip-start 重新运行 install.sh。\n'
elif (( SKIP_START )); then
  printf '重复安装检查完成；现有 ready 状态未降级。\n'
else
  printf '\n本地服务、AnythingLLM 工作区、知识索引和生产 workflow 已完成初始化。\n'
  if [[ "$(env_get "$ENV_FILE" CRISP_HOOK_MODE)" == website ]]; then
    printf 'Webhook（消息回调地址）：%s?key=<CRISP_WEBSITE_HOOK_SECRET>\n' \
      "$(env_get "$ENV_FILE" WEBHOOK_PRODUCTION_URL)"
  else
    printf 'Plugin Webhook：%s（必须由 Crisp 签名）\n' \
      "$(env_get "$ENV_FILE" WEBHOOK_PRODUCTION_URL)"
  fi
  printf '请在 Crisp 的 Workspace Settings → Advanced configuration → Web Hooks 登记生产地址。\n'
  printf '订阅 message:send、message:received、message:updated；页面欢迎模式另需 session:sync:events。\n'
  printf '管理入口：crispai；继续接入验证：crispai doctor；日志：%s/logs\n' "$DEPLOY_DIR"
  printf '含 Secret 的真实 Hook 地址只在 crispai → 10 → 7 的私密终端显示。\n'
  if [[ "$(installation_state "$DEPLOY_DIR")" == ready ]]; then
    printf 'Crisp REST、公网端点与已观察真实会话均已验证；客服按总开关及逐会话模式运行。\n'
  else
    printf '本地已就绪，尚未确认真实接待：Crisp API=%s（HTTP %s），公网=%s，真实会话=%s。\n' \
      "$(installation_fact "$DEPLOY_DIR" crisp_api)" "${CRISP_API_STATUS:-000}" \
      "$(installation_fact "$DEPLOY_DIR" webhook)" "$(installation_fact "$DEPLOY_DIR" conversation)"
    printf '无需重新初始化。仅修复待接入项，完成 Hook 登记/真实测试后运行 crispai doctor。\n'
    exit 2
  fi
fi
