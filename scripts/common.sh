#!/usr/bin/env bash
set -euo pipefail

COMMON_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "${COMMON_DIR}/.." && pwd -P)"
DEFAULT_DEPLOY_DIR="/opt/crisp-ai"
INSTALL_MARKER=".crisp-ai-installation"
WORKFLOW_ID="5d2c37c9-1c8e-45d0-8f53-c0a6e79b3a40"

info() {
  printf '信息：%s\n' "$*"
}

warn() {
  printf '警告：%s\n' "$*" >&2
}

die() {
  printf '错误：%s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1"
}

require_docker_runtime() {
  require_command docker
  docker compose version >/dev/null 2>&1 || die "未检测到兼容的 Docker Compose 插件"
  docker info >/dev/null 2>&1 || die "无法连接 Docker daemon，请确认 Docker Engine 已启动且当前用户有权限访问"
}

acquire_maintenance_lock() {
  local deploy_dir=$1
  local lock_file="${deploy_dir}/tmp/maintenance.lock"

  [[ "${CRISP_AI_MAINTENANCE_LOCK_HELD:-0}" != 1 ]] || return 0
  require_command flock
  mkdir -p -- "${deploy_dir}/tmp"
  [[ -d "${deploy_dir}/tmp" && ! -L "${deploy_dir}/tmp" ]] || die "维护锁目录不安全"
  exec {MAINTENANCE_LOCK_FD}> "$lock_file"
  flock -n "$MAINTENANCE_LOCK_FD" || die "另一个安装、更新、备份或恢复任务正在运行"
  export CRISP_AI_MAINTENANCE_LOCK_HELD=1
}

validate_deploy_dir() {
  local requested=${1:-}
  local resolved

  [[ -n "$requested" ]] || die "部署目录不能为空"
  [[ "$requested" == /* ]] || die "部署目录必须是绝对路径"
  [[ "$requested" != *$'\n'* && "$requested" != *$'\r'* ]] || die "部署目录包含非法字符"
  [[ "/${requested#/}/" != *"/../"* && "/${requested#/}/" != *"/./"* ]] || die "部署目录不得包含 . 或 .. 路径段"
  require_command realpath
  resolved=$(realpath -m -- "$requested")

  case "$resolved" in
    /|/opt|/root|/home|/var|/usr|/etc|/tmp)
      die "拒绝使用过宽或系统关键目录：$resolved"
      ;;
  esac
  [[ ! -L "$resolved" ]] || die "部署目录不得是符号链接：$resolved"
  printf '%s\n' "$resolved"
}

resolve_deploy_dir() {
  local requested=${1:-}
  if [[ -n "$requested" ]]; then
    validate_deploy_dir "$requested"
  elif [[ -f "${PROJECT_ROOT}/${INSTALL_MARKER}" ]]; then
    validate_deploy_dir "$PROJECT_ROOT"
  elif [[ -n "${CRISP_AI_DEPLOY_DIR:-}" ]]; then
    validate_deploy_dir "$CRISP_AI_DEPLOY_DIR"
  else
    validate_deploy_dir "$DEFAULT_DEPLOY_DIR"
  fi
}

assert_installation() {
  local deploy_dir=$1
  local marker="${deploy_dir}/${INSTALL_MARKER}"
  [[ -f "$marker" && ! -L "$marker" ]] || die "目录不是受管理的 ai-support 部署：$deploy_dir"
  [[ "$(sed -n '1p' "$marker")" == "ai-support" ]] || die "安装标记无效：$marker"
  case "$(installation_state "$deploy_dir")" in
    ready|local-ready) ;;
    collecting) die "快速初始化尚未确认，请从源码目录重新运行 install.sh" ;;
    installing) die "安装尚未完成，请从源码目录重新运行 install.sh" ;;
    staged) die "部署文件已暂存但服务尚未验收，请重新运行 install.sh（不要使用 --skip-start）" ;;
    uninstalled-data-kept) die "程序已卸载但数据仍保留，请从源码目录重新运行 install.sh" ;;
    *) die "安装标记状态无效：$marker" ;;
  esac
}

assert_managed_installation() {
  local deploy_dir=$1
  local marker="${deploy_dir}/${INSTALL_MARKER}"
  [[ -f "$marker" && ! -L "$marker" ]] || die "目录不是受管理的 ai-support 部署：$deploy_dir"
  [[ "$(sed -n '1p' "$marker")" == "ai-support" ]] || die "安装标记无效：$marker"
  case "$(installation_state "$deploy_dir")" in
    ready|local-ready|collecting|installing|staged|uninstalled-data-kept) ;;
    *) die "安装标记状态无效：$marker" ;;
  esac
}

installation_state() {
  local deploy_dir=$1
  local marker="${deploy_dir}/${INSTALL_MARKER}"
  local state
  state=$(sed -n 's/^state=//p' "$marker" 2>/dev/null | head -n 1)
  # v0.7.0 及更早版本没有 state 字段，兼容地视为已完成安装。
  printf '%s\n' "${state:-ready}"
}

write_installation_marker() {
  local deploy_dir=$1
  local source_dir=$2
  local version=$3
  local state=$4
  local marker="${deploy_dir}/${INSTALL_MARKER}"
  local temp fact value
  local -a facts=(dependencies local_services app_config provider crisp_api webhook conversation)

  [[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "安装标记版本无效"
  case "$state" in
    ready|local-ready|collecting|installing|staged|uninstalled-data-kept) ;;
    *) die "安装标记状态无效：$state" ;;
  esac
  mkdir -p -- "$deploy_dir"
  [[ -d "$deploy_dir" && ! -L "$deploy_dir" ]] || die "部署目录不安全：$deploy_dir"
  temp=$(mktemp "${marker}.tmp.XXXXXX")
  {
    printf 'ai-support\n'
    printf 'state=%s\n' "$state"
    [[ -z "$source_dir" ]] || printf 'source=%s\n' "$source_dir"
    printf 'installed_version=%s\n' "$version"
    if [[ -f "$marker" && ! -L "$marker" ]]; then
      for fact in "${facts[@]}"; do
        value=$(sed -n "s/^fact_${fact}=//p" "$marker" | head -n 1)
        case "$value" in
          pending|ready|failed|skipped) printf 'fact_%s=%s\n' "$fact" "$value" ;;
        esac
      done
    fi
  } > "$temp"
  chmod 600 "$temp"
  mv -f -- "$temp" "$marker"
}

installation_fact() {
  local deploy_dir=$1
  local name=$2
  [[ "$name" =~ ^(dependencies|local_services|app_config|provider|crisp_api|webhook|conversation)$ ]] \
    || return 1
  sed -n "s/^fact_${name}=//p" "${deploy_dir}/${INSTALL_MARKER}" 2>/dev/null | head -n 1
}

set_installation_fact() {
  local deploy_dir=$1
  local name=$2
  local value=$3
  local marker="${deploy_dir}/${INSTALL_MARKER}"
  local temp line replaced=0

  [[ "$name" =~ ^(dependencies|local_services|app_config|provider|crisp_api|webhook|conversation)$ ]] \
    || die "安装事实名称无效：$name"
  [[ "$value" =~ ^(pending|ready|failed|skipped)$ ]] || die "安装事实值无效：$value"
  [[ -f "$marker" && ! -L "$marker" ]] || die "安装标记缺失或不安全：$marker"
  temp=$(mktemp "${marker}.tmp.XXXXXX")
  chmod 600 "$temp"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == "fact_${name}="* ]]; then
      if (( replaced == 0 )); then
        printf 'fact_%s=%s\n' "$name" "$value" >> "$temp"
        replaced=1
      fi
    else
      printf '%s\n' "$line" >> "$temp"
    fi
  done < "$marker"
  if (( replaced == 0 )); then
    printf 'fact_%s=%s\n' "$name" "$value" >> "$temp"
  fi
  mv -f -- "$temp" "$marker"
}

env_get() {
  local env_file=$1
  local key=$2
  local line value decoded

  [[ -f "$env_file" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == "${key}="* ]] || continue
    value=${line#*=}
    if [[ ${#value} -ge 2 && "$value" == \"*\" && "$value" == *\" ]]; then
      command -v jq >/dev/null 2>&1 || return 1
      value=${value//\$\$/\$}
      decoded=$(printf '%s' "$value" | jq -Rer 'fromjson | select(type == "string")') || return 1
      value=$decoded
    elif [[ ${#value} -ge 2 && "$value" == \'*\' && "$value" == *\' ]]; then
      value=${value:1:${#value}-2}
    fi
    printf '%s\n' "$value"
    return 0
  done < "$env_file"
  return 1
}

validate_env_value() {
  local value=$1
  [[ -n "$value" ]] || return 1
  (( ${#value} <= 8192 )) || return 1
  [[ ! "$value" =~ [[:cntrl:]] ]]
}

validate_port() {
  local value=$1
  [[ "$value" =~ ^(0|[1-9][0-9]{0,4})$ ]] || return 1
  (( 10#$value >= 1 && 10#$value <= 65535 ))
}

validate_ipv4_address() {
  local value=$1
  local octet
  local -a octets=()

  IFS=. read -r -a octets <<< "$value"
  (( ${#octets[@]} == 4 )) || return 1
  for octet in "${octets[@]}"; do
    [[ "$octet" =~ ^(0|[1-9][0-9]{0,2})$ ]] || return 1
    (( 10#$octet <= 255 )) || return 1
  done
}

validate_hostname() {
  local value=$1
  local label
  local -a labels=()

  (( ${#value} >= 1 && ${#value} <= 253 )) || return 1
  [[ "$value" =~ ^[A-Za-z0-9.-]+$ ]] || return 1
  [[ "$value" != .* && "$value" != *. && "$value" != *..* ]] || return 1
  IFS=. read -r -a labels <<< "$value"
  for label in "${labels[@]}"; do
    (( ${#label} >= 1 && ${#label} <= 63 )) || return 1
    [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
  done
}

validate_public_url() {
  local value=$1
  local host port path

  [[ "$value" == */ && "$value" != *$'\n'* && "$value" != *$'\r'* ]] || return 1
  [[ "$value" =~ ^https?://([^/@: \\?#]+)(:([0-9]{1,5}))?(/[^?#]*)$ ]] || return 1
  host=${BASH_REMATCH[1]}
  port=${BASH_REMATCH[3]}
  path=${BASH_REMATCH[4]}
  validate_hostname "$host" || return 1
  [[ -z "$port" ]] || validate_port "$port" || return 1
  [[ "$path" != *".."* && "$path" != *$'\t'* ]] || return 1
  validate_env_value "$value"
}

webhook_ports_available() {
  local deploy_dir=$1
  local current_mode running

  require_command ss
  current_mode=$(env_get "${deploy_dir}/.env" WEBHOOK_ACCESS_MODE 2>/dev/null || true)
  if [[ "$current_mode" == managed_https ]] && command -v docker >/dev/null 2>&1 \
    && docker info >/dev/null 2>&1; then
    running=$(docker_compose "$deploy_dir" ps --services --filter status=running 2>/dev/null || true)
    grep -Fxq caddy <<< "$running" && return 0
  fi
  ! ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -Eq '(^|:)(80|443)$'
}

configure_webhook_access() {
  local deploy_dir=$1
  local mode=$2
  local public_base=$3
  local production_url=$4
  local domain=$5
  local env_file="${deploy_dir}/.env"
  local previous_mode

  previous_mode=$(env_get "$env_file" WEBHOOK_ACCESS_MODE 2>/dev/null || true)

  validate_public_url "$public_base" || die "Webhook 公网 Base URL 无效"
  [[ "$production_url" == https://*'/webhook/crisp-webhook' ]] \
    || die "生产 Webhook 地址必须使用 HTTPS 并以 /webhook/crisp-webhook 结尾"
  case "$mode" in
    domain|managed_https)
      validate_hostname "$domain" || die "自动 HTTPS 域名无效"
      webhook_ports_available "$deploy_dir" \
        || die "80 或 443 端口已被其他服务占用；安装器不会停止现有网站，请重新配置并填写现有 HTTPS 完整 Webhook 地址"
      [[ -f "${deploy_dir}/config/Caddyfile.example" \
        && ! -L "${deploy_dir}/config/Caddyfile.example" ]] || die "受管 HTTPS 模板缺失或不安全"
      if [[ ! -e "${deploy_dir}/config/Caddyfile" ]]; then
        install -m 0640 -- "${deploy_dir}/config/Caddyfile.example" "${deploy_dir}/config/Caddyfile"
      fi
      [[ -f "${deploy_dir}/config/Caddyfile" && ! -L "${deploy_dir}/config/Caddyfile" ]] \
        || die "受管 HTTPS 配置不安全"
      env_set "$env_file" WEBHOOK_ACCESS_MODE managed_https
      env_set "$env_file" WEBHOOK_DOMAIN "$domain"
      env_set "$env_file" COMPOSE_PROFILES managed-https
      ;;
    existing_url|external_proxy)
      # 关闭本实例此前托管的 HTTPS 容器，避免 profile 取消后留下 80/443 孤儿。
      # 只按当前 Compose 项目和服务名操作，不触碰宿主机其他反向代理。
      if [[ "$previous_mode" == managed_https ]] && command -v docker >/dev/null 2>&1 \
        && docker info >/dev/null 2>&1; then
        docker_compose "$deploy_dir" --profile managed-https stop caddy >/dev/null 2>&1 || true
        docker_compose "$deploy_dir" --profile managed-https rm -f caddy >/dev/null 2>&1 || true
      fi
      env_set "$env_file" WEBHOOK_ACCESS_MODE external_proxy
      env_set "$env_file" WEBHOOK_DOMAIN "$domain"
      env_unset "$env_file" COMPOSE_PROFILES
      ;;
    *) die "Webhook 接入模式无效：$mode" ;;
  esac
  env_set "$env_file" PUBLIC_WEBHOOK_URL "$public_base"
  env_set "$env_file" WEBHOOK_PRODUCTION_URL "$production_url"
}

env_set() {
  local env_file=$1
  local key=$2
  local value=$3
  local temp line replaced=0 encoded

  [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || die "环境变量名称无效：$key"
  validate_env_value "$value" || die "${key} 包含不安全字符或为空"
  if [[ "$value" =~ ^[A-Za-z0-9._~:/@+,=%?\&-]+$ ]]; then
    encoded=$value
  else
    require_command jq
    encoded=$(jq -Rn --arg value "$value" '$value')
    # Compose 会展开双引号值中的 `$`；使用 `$$` 保留原始字面值。
    encoded=${encoded//\$/\$\$}
  fi
  mkdir -p -- "$(dirname -- "$env_file")"
  touch -- "$env_file"
  temp=$(mktemp "${env_file}.tmp.XXXXXX")
  chmod 600 "$temp"

  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == "${key}="* ]]; then
      if (( replaced == 0 )); then
        printf '%s=%s\n' "$key" "$encoded" >> "$temp"
        replaced=1
      fi
    else
      printf '%s\n' "$line" >> "$temp"
    fi
  done < "$env_file"
  if (( replaced == 0 )); then
    printf '%s=%s\n' "$key" "$encoded" >> "$temp"
  fi
  mv -f -- "$temp" "$env_file"
  chmod 600 "$env_file"
}

env_unset() {
  local env_file=$1
  local key=$2
  local temp line

  [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || die "环境变量名称无效：$key"
  [[ -f "$env_file" && ! -L "$env_file" ]] || return 0
  temp=$(mktemp "${env_file}.tmp.XXXXXX")
  chmod 600 "$temp"
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == "${key}="* ]] || printf '%s\n' "$line" >> "$temp"
  done < "$env_file"
  mv -f -- "$temp" "$env_file"
  chmod 600 "$env_file"
}

is_placeholder() {
  local value=${1:-}
  [[ -z "$value" || "$value" == replace-with-* || "$value" == pending-* ]]
}

provider_config_has_secret_field() {
  local provider_file=$1
  grep -Eiq '^[[:space:]]*(api[-_]?key|key|token|secret|client[-_]?secret|credential|password|authorization|private[-_]?key)[[:space:]]*:' "$provider_file"
}

random_hex() {
  local bytes=${1:-32}
  require_command openssl
  openssl rand -hex "$bytes"
}

ensure_secret() {
  local env_file=$1
  local key=$2
  local bytes=${3:-32}
  local current
  current=$(env_get "$env_file" "$key" 2>/dev/null || true)
  if is_placeholder "$current"; then
    env_set "$env_file" "$key" "$(random_hex "$bytes")"
  fi
}

docker_compose_command() {
  local progress=${COMPOSE_PROGRESS:-plain}
  COMPOSE_PROGRESS="$progress" docker compose "$@"
}

docker_compose() {
  local deploy_dir=$1
  shift
  docker_compose_command \
    --project-directory "$deploy_dir" \
    --env-file "${deploy_dir}/.env" \
    -f "${deploy_dir}/docker-compose.yml" \
    "$@"
}

wait_for_local_health() {
  local deploy_dir=$1
  local attempts=${2:-30}
  local interval=${3:-2}
  local n8n_port anything_port running

  require_command docker
  require_command curl
  docker_compose "$deploy_dir" config --quiet
  n8n_port=$(env_get "${deploy_dir}/.env" N8N_PORT 2>/dev/null || printf '5678')
  anything_port=$(env_get "${deploy_dir}/.env" ANYTHINGLLM_PORT 2>/dev/null || printf '3001')
  for (( attempt = 1; attempt <= attempts; attempt++ )); do
    running=$(docker_compose "$deploy_dir" ps --services --filter status=running 2>/dev/null || true)
    if grep -Fxq postgres <<< "$running" \
      && grep -Fxq anythingllm <<< "$running" \
      && grep -Fxq n8n <<< "$running" \
      && curl --silent --fail --connect-timeout 3 --max-time 10 "http://127.0.0.1:${n8n_port}/healthz" >/dev/null 2>&1 \
      && curl --silent --fail --connect-timeout 3 --max-time 10 "http://127.0.0.1:${anything_port}/api/ping" >/dev/null 2>&1; then
      return 0
    fi
    sleep "$interval"
  done
  warn "本地服务健康检查超时"
  return 1
}

secure_permissions() {
  local deploy_dir=$1
  chmod 700 "$deploy_dir" "${deploy_dir}/data" "${deploy_dir}/logs" "${deploy_dir}/backups" \
    "${deploy_dir}/backups/versions" "${deploy_dir}/tmp" "${deploy_dir}/data/caddy" \
    "${deploy_dir}/data/caddy-config" 2>/dev/null || true
  chmod 750 "${deploy_dir}/config" "${deploy_dir}/knowledge" "${deploy_dir}/n8n" "${deploy_dir}/scripts" "${deploy_dir}/docs" 2>/dev/null || true
  chmod 770 "${deploy_dir}/data/analytics" 2>/dev/null || true
  [[ -f "${deploy_dir}/.env" ]] && chmod 600 "${deploy_dir}/.env"
  [[ -f "${deploy_dir}/config/provider.yaml" ]] && chmod 600 "${deploy_dir}/config/provider.yaml"
  [[ -f "${deploy_dir}/data/analytics/events.jsonl" ]] && chmod 660 "${deploy_dir}/data/analytics/events.jsonl"
  find "${deploy_dir}/config" -maxdepth 1 -type f ! -name 'provider.yaml' -exec chmod 640 {} + 2>/dev/null || true
  find "${deploy_dir}/knowledge" -maxdepth 1 -type f -exec chmod 640 {} + 2>/dev/null || true
}

set_runtime_ownership() {
  local deploy_dir=$1

  chown -R root:1000 "${deploy_dir}/config" "${deploy_dir}/knowledge" "${deploy_dir}/n8n" \
    "${deploy_dir}/data/analytics" 2>/dev/null || true
  chown -R 1000:1000 "${deploy_dir}/data/n8n" "${deploy_dir}/data/anythingllm" \
    "${deploy_dir}/data/runtime" 2>/dev/null \
    || die "无法设置 n8n 或 AnythingLLM 数据目录所有权"
  chmod 0750 "${deploy_dir}/data/n8n" "${deploy_dir}/data/anythingllm" "${deploy_dir}/data/runtime"
}

repair_runtime_modules_from_source() {
  local deploy_dir=$1
  local marker="${deploy_dir}/${INSTALL_MARKER}"
  local source_dir relative source target mode
  local -a required=(
    scripts/bootstrap.sh scripts/wizard.sh scripts/package-release.sh
    config/Caddyfile.example
  )

  source_dir=$(sed -n 's/^source=//p' "$marker" 2>/dev/null | head -n 1)
  [[ -n "$source_dir" && "$source_dir" == /* && -d "$source_dir" && ! -L "$source_dir" ]] || return 0
  for relative in "${required[@]}"; do
    target="${deploy_dir}/${relative}"
    [[ -f "$target" && ! -L "$target" ]] && continue
    source="${source_dir}/${relative}"
    [[ -f "$source" && ! -L "$source" ]] \
      || die "升级后缺少运行模块 ${relative}，且原始源码中无法恢复；请从完整新版本发布包运行 update.sh"
    case "$relative" in scripts/*.sh) mode=0750 ;; *) mode=0640 ;; esac
    install -D -m "$mode" -- "$source" "$target"
    info "已从升级源码补齐运行模块：${relative}"
  done
}

copy_project_files() {
  local source_dir=$1
  local deploy_dir=$2
  local file directory
  local regular_files=(
    VERSION CHANGELOG.md README.md LICENSE AGENTS.md .env.example docker-compose.yml
    config/app.yaml config/provider.yaml.example config/prompt.md.example
    config/keyword.yaml.example config/menu.yaml.example config/handoff.yaml.example
    config/tags.yaml.example config/feedback.yaml.example config/Caddyfile.example
    n8n/workflow.json knowledge/README.md
    docs/INSTALL.md docs/ARCHITECTURE.md docs/CONFIG.md docs/SECURITY.md docs/TESTING.md docs/RELEASE.md
  )
  local executable_files=(
    install.sh manage.sh update.sh uninstall.sh
    scripts/common.sh scripts/healthcheck.sh scripts/backup.sh scripts/restore.sh
    scripts/analytics.sh scripts/snapshot.sh scripts/rollback.sh
    scripts/bootstrap.sh scripts/wizard.sh scripts/package-release.sh
  )

  mkdir -p -- "$deploy_dir" "${deploy_dir}/config" "${deploy_dir}/knowledge" "${deploy_dir}/n8n" \
    "${deploy_dir}/scripts" "${deploy_dir}/docs" "${deploy_dir}/data/n8n" "${deploy_dir}/data/postgres" \
    "${deploy_dir}/data/anythingllm" "${deploy_dir}/data/analytics" "${deploy_dir}/data/runtime" \
    "${deploy_dir}/data/caddy" "${deploy_dir}/data/caddy-config" "${deploy_dir}/logs" \
    "${deploy_dir}/backups" "${deploy_dir}/backups/versions" "${deploy_dir}/tmp"
  for directory in config knowledge n8n scripts docs data data/n8n data/postgres data/anythingllm \
    data/analytics data/runtime data/caddy data/caddy-config logs backups backups/versions tmp; do
    [[ -d "${deploy_dir}/${directory}" && ! -L "${deploy_dir}/${directory}" ]] \
      || die "受管理目录缺失或是符号链接：${deploy_dir}/${directory}"
  done

  if [[ "$(realpath -m -- "$source_dir")" == "$(realpath -m -- "$deploy_dir")" ]]; then
    return 0
  fi

  for file in "${regular_files[@]}"; do
    [[ -f "${source_dir}/${file}" && ! -L "${source_dir}/${file}" ]] || die "源码文件缺失或不安全：${file}"
    if [[ "$file" == "knowledge/README.md" && -f "${deploy_dir}/${file}" ]]; then
      continue
    fi
    install -D -m 0640 -- "${source_dir}/${file}" "${deploy_dir}/${file}"
  done
  for file in "${executable_files[@]}"; do
    [[ -f "${source_dir}/${file}" && ! -L "${source_dir}/${file}" ]] || die "源码脚本缺失或不安全：${file}"
    install -D -m 0750 -- "${source_dir}/${file}" "${deploy_dir}/${file}"
  done
}

initialize_config_files() {
  local deploy_dir=$1
  local name
  for name in provider.yaml prompt.md keyword.yaml menu.yaml handoff.yaml tags.yaml feedback.yaml; do
    if [[ ! -e "${deploy_dir}/config/${name}" ]]; then
      install -m 0640 -- "${deploy_dir}/config/${name}.example" "${deploy_dir}/config/${name}"
    fi
  done
}

migrate_config_files() {
  local deploy_dir=$1
  local handoff_file="${deploy_dir}/config/handoff.yaml"
  local handoff_temp tags_file tags_temp

  [[ -f "$handoff_file" && ! -L "$handoff_file" ]] || die "人工接管配置缺失或不安全"
  require_command jq
  if ! jq -e '.handoff.disable_ai == true' "$handoff_file" >/dev/null 2>&1; then
    warn "已将人工转接配置迁移为 disable_ai=true；明确转人工后必须停止 AI 回复"
  fi
  handoff_temp=$(mktemp "${handoff_file}.tmp.XXXXXX")
  jq '
    if .handoff.keywords == ["人工", "客服", "真人"] or
       .handoff.keywords == ["人工", "人工客服", "转人工", "真人客服"] then
      .handoff.keywords = ["人工", "人工客服", "转人工", "真人", "真人客服"]
    else . end |
    if (.handoff.match_mode == "exact" or .handoff.match_mode == "contains") then . else .handoff.match_mode = "exact" end |
    .handoff.disable_ai = true |
    if (.handoff.notify_user | type) == "object" then . else .handoff.notify_user = {} end |
    if (.handoff.notify_user | has("enabled")) then . else .handoff.notify_user.enabled = true end |
    if (.handoff.message // "") == "您已请求人工客服，正在为您转接，请稍候。" then
      .handoff.message = "正在为您转接人工客服，请稍候。"
    elif ((.handoff.message // "") | length) > 0 then .
    elif (.handoff.confirmation // "") == "已为您转接人工客服，AI 将暂停回复。" then
      .handoff.message = "正在为您转接人工客服，请稍候。"
    elif ((.handoff.confirmation // "") | length) > 0 then .handoff.message = .handoff.confirmation
    else .handoff.message = "正在为您转接人工客服，请稍候。" end |
    if .handoff.no_answer_message == "知识库暂时没有足够信息，已为您转接人工客服。" then
      .handoff.no_answer_message = "知识库暂时没有足够信息，请换一种方式描述问题。"
    else . end |
    if .handoff.low_confidence_message == "当前答案可信度不足，已为您转接人工客服。" then
      .handoff.low_confidence_message = "当前答案可信度不足，请补充更多问题细节。"
    else . end |
    if .handoff.failure_message == "当前自动客服暂时不可用，已为您转接人工客服。" then
      .handoff.failure_message = "当前自动客服暂时不可用，请稍后再试。"
    else . end |
    del(.handoff.topic_keywords, .handoff.on_operator_message, .handoff.on_low_confidence, .handoff.on_no_answer, .handoff.confirmation, .handoff.resume_keywords, .handoff.resume_match_mode)
  ' "$handoff_file" > "$handoff_temp" || {
    rm -f -- "$handoff_temp"
    die "人工接管配置迁移失败"
  }
  chmod 640 "$handoff_temp"
  mv -f -- "$handoff_temp" "$handoff_file"

  tags_file="${deploy_dir}/config/tags.yaml"
  [[ -f "$tags_file" && ! -L "$tags_file" ]] || die "Conversation 标签配置缺失或不安全"
  tags_temp=$(mktemp "${tags_file}.tmp.XXXXXX")
  jq '
    if .tags.ai_resolved == "ai-resolved" then .tags.ai_resolved = "ai_resolved" else . end |
    if .tags.knowledge_miss == "knowledge-miss" then .tags.knowledge_miss = "knowledge_miss" else . end |
    if .tags.low_confidence == "low-confidence" then .tags.low_confidence = "low_confidence" else . end |
    if .tags.human_required == "human-required" then .tags.human_required = "human_required" else . end
  ' "$tags_file" > "$tags_temp" || {
    rm -f -- "$tags_temp"
    die "Conversation 标签配置迁移失败"
  }
  chmod 640 "$tags_temp"
  mv -f -- "$tags_temp" "$tags_file"
}

migrate_runtime_env() {
  local deploy_dir=$1
  local env_file="${deploy_dir}/.env"
  local value legacy_secret hook_mode token_tier

  [[ -f "$env_file" && ! -L "$env_file" ]] || die "运行配置缺失或不安全：$env_file"

  value=$(env_get "$env_file" N8N_IMAGE 2>/dev/null || true)
  case "$value" in
    ""|docker.n8n.io/n8nio/n8n:2) env_set "$env_file" N8N_IMAGE docker.n8n.io/n8nio/n8n:2.33.0 ;;
  esac
  value=$(env_get "$env_file" POSTGRES_IMAGE 2>/dev/null || true)
  case "$value" in
    ""|postgres:16-alpine) env_set "$env_file" POSTGRES_IMAGE postgres:16.10-alpine ;;
  esac
  value=$(env_get "$env_file" ANYTHINGLLM_IMAGE 2>/dev/null || true)
  case "$value" in
    ""|mintplexlabs/anythingllm:latest|mintplexlabs/anythingllm:1.15.0) \
      env_set "$env_file" ANYTHINGLLM_IMAGE mintplexlabs/anythingllm:1.16.1
      ;;
  esac
  value=$(env_get "$env_file" CADDY_IMAGE 2>/dev/null || true)
  [[ -n "$value" ]] || env_set "$env_file" CADDY_IMAGE caddy:2.10.2-alpine

  value=$(env_get "$env_file" ANYTHINGLLM_CHAT_MODE 2>/dev/null || true)
  if [[ "$value" != chat ]]; then
    env_set "$env_file" ANYTHINGLLM_CHAT_MODE chat
    warn "已将 AnythingLLM 会话模式迁移为 chat，以保持同一 Crisp conversation 的上下文"
  fi

  value=$(env_get "$env_file" AI_API_PROBE_BASE_URL 2>/dev/null || true)
  if [[ -z "$value" ]]; then
    value=$(env_get "$env_file" AI_API_BASE_URL 2>/dev/null || true)
    if [[ -n "$value" ]]; then
      env_set "$env_file" AI_API_PROBE_BASE_URL "$value"
    fi
  fi

  value=$(env_get "$env_file" WEBHOOK_ACCESS_MODE 2>/dev/null || true)
  if [[ -z "$value" ]]; then
    env_set "$env_file" WEBHOOK_ACCESS_MODE external_proxy
    env_set "$env_file" WEBHOOK_DOMAIN "$(env_get "$env_file" N8N_HOST 2>/dev/null || printf localhost)"
  elif [[ "$value" != external_proxy && "$value" != managed_https ]]; then
    die "WEBHOOK_ACCESS_MODE 只能是 external_proxy 或 managed_https"
  fi
  value=$(env_get "$env_file" WEBHOOK_PRODUCTION_URL 2>/dev/null || true)
  if [[ -z "$value" ]]; then
    value=$(env_get "$env_file" PUBLIC_WEBHOOK_URL 2>/dev/null || true)
    [[ -n "$value" ]] && env_set "$env_file" WEBHOOK_PRODUCTION_URL "${value}webhook/crisp-webhook"
  fi

  value=$(env_get "$env_file" N8N_PROTOCOL 2>/dev/null || true)
  if [[ -z "$value" ]]; then
    if [[ "$(env_get "$env_file" PUBLIC_WEBHOOK_URL 2>/dev/null || true)" == https://* ]]; then
      env_set "$env_file" N8N_PROTOCOL https
    else
      env_set "$env_file" N8N_PROTOCOL http
    fi
  elif [[ "$value" != http && "$value" != https ]]; then
    die "N8N_PROTOCOL 只能是 http 或 https"
  fi

  legacy_secret=$(env_get "$env_file" CRISP_WEBHOOK_SECRET 2>/dev/null || true)
  hook_mode=$(env_get "$env_file" CRISP_HOOK_MODE 2>/dev/null || true)
  if [[ -z "$hook_mode" ]]; then
    token_tier=$(env_get "$env_file" CRISP_TOKEN_TIER 2>/dev/null || printf 'website')
    case "$token_tier" in
      website|plugin) hook_mode=$token_tier ;;
      *) die "旧版 CRISP_TOKEN_TIER 无法用于迁移 Hook 模式，请先设置 CRISP_HOOK_MODE" ;;
    esac
    env_set "$env_file" CRISP_HOOK_MODE "$hook_mode"
    warn "旧版配置未区分 Hook 来源，已按 CRISP_TOKEN_TIER 迁移为 ${hook_mode} 模式"
  fi
  [[ "$hook_mode" == website || "$hook_mode" == plugin ]] || die "CRISP_HOOK_MODE 配置无效"

  if [[ "$hook_mode" == website ]]; then
    value=$(env_get "$env_file" CRISP_WEBSITE_HOOK_SECRET 2>/dev/null || true)
    if is_placeholder "$value"; then
      if ! is_placeholder "$legacy_secret" && validate_env_value "$legacy_secret"; then
        env_set "$env_file" CRISP_WEBSITE_HOOK_SECRET "$legacy_secret"
      else
        ensure_secret "$env_file" CRISP_WEBSITE_HOOK_SECRET 32
      fi
    fi
  else
    value=$(env_get "$env_file" CRISP_PLUGIN_SIGNING_SECRET 2>/dev/null || true)
    if is_placeholder "$value"; then
      if ! is_placeholder "$legacy_secret" && validate_env_value "$legacy_secret"; then
        env_set "$env_file" CRISP_PLUGIN_SIGNING_SECRET "$legacy_secret"
      else
        die "Plugin Hook Signing Secret 无法从旧配置迁移，请先设置 CRISP_PLUGIN_SIGNING_SECRET"
      fi
    fi
  fi
}

normalize_api_base() {
  local base=$1
  local host port
  base=${base%/}
  [[ "$base" =~ ^https?://([^/@:\ \\?#]+)(:([0-9]{1,5}))?(/[^?#[:space:]]*)?$ ]] || return 1
  host=${BASH_REMATCH[1]}
  port=${BASH_REMATCH[3]}
  validate_hostname "$host" || return 1
  [[ -z "$port" ]] || validate_port "$port" || return 1
  if [[ "$base" == http://* && "$host" != localhost && "$host" != 127.* ]]; then
    return 1
  fi
  [[ "$base" != *".."* ]] || return 1
  if [[ "$base" != */v1 ]]; then
    base="${base}/v1"
  fi
  validate_env_value "$base" || return 1
  printf '%s\n' "$base"
}

provider_runtime_base() {
  local base=$1
  local scheme host port path

  base=$(normalize_api_base "$base") || return 1
  if [[ "$base" =~ ^(https?)://(localhost|127\.0\.0\.1)(:([0-9]{1,5}))?(/.*)$ ]]; then
    scheme=${BASH_REMATCH[1]}
    host=host.docker.internal
    port=${BASH_REMATCH[3]}
    path=${BASH_REMATCH[5]}
    printf '%s://%s%s%s\n' "$scheme" "$host" "$port" "$path"
  else
    printf '%s\n' "$base"
  fi
}

validate_model_identifier() {
  local value=$1
  (( ${#value} >= 1 && ${#value} <= 512 )) || return 1
  [[ "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._:/+@-]*$ ]]
}

curl_config_escape() {
  local value=$1
  validate_env_value "$value" || return 1
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  printf '%s' "$value"
}

probe_api_endpoint() {
  local url=$1
  local api_key=$2
  local payload=$3
  local temp_dir=${4:-$PROJECT_ROOT}
  local status config_file response_file valid=false
  require_command jq
  config_file=$(mktemp "${temp_dir}/provider-curl.XXXXXX")
  response_file=$(mktemp "${temp_dir}/provider-response.XXXXXX")
  chmod 600 "$config_file" "$response_file"
  local escaped_api_key
  escaped_api_key=$(curl_config_escape "$api_key") || {
    rm -f -- "$config_file" "$response_file"
    return 1
  }
  printf 'header = "Authorization: Bearer %s"\nheader = "Content-Type: application/json"\n' "$escaped_api_key" > "$config_file"
  status=$(curl --silent --output "$response_file" --write-out '%{http_code}' \
    --connect-timeout 8 --max-time 30 \
    --config "$config_file" \
    --data "$payload" "$url" 2>/dev/null || true)
  if [[ "$status" == 2?? ]]; then
    case "$url" in
      */chat/completions)
        jq -e '
          ((has("error") | not) or .error == null or .error == false) and
          (.choices | type == "array" and length > 0)
        ' "$response_file" >/dev/null 2>&1 && valid=true
        ;;
      */responses)
        jq -e '
          ((has("error") | not) or .error == null or .error == false) and
          ((.id | type == "string" and length > 0) or
           (.output | type == "array") or
           (.output_text | type == "string"))
        ' "$response_file" >/dev/null 2>&1 && valid=true
        ;;
    esac
  fi
  rm -f -- "$config_file" "$response_file"
  [[ "$valid" == true ]]
}

crisp_api_check() {
  local deploy_dir=$1
  local env_file="${deploy_dir}/.env"
  local website tier auth config_file escaped_auth escaped_tier status

  website=$(env_get "$env_file" CRISP_WEBSITE_ID 2>/dev/null || true)
  tier=$(env_get "$env_file" CRISP_TOKEN_TIER 2>/dev/null || true)
  auth=$(env_get "$env_file" CRISP_AUTH_B64 2>/dev/null || true)
  [[ "$website" =~ ^[A-Za-z0-9-]{8,128}$ ]] || {
    CRISP_API_STATUS=configuration
    return 1
  }
  [[ "$tier" == website || "$tier" == plugin ]] || {
    CRISP_API_STATUS=configuration
    return 1
  }
  validate_env_value "$auth" || {
    CRISP_API_STATUS=configuration
    return 1
  }

  escaped_auth=$(curl_config_escape "$auth") || return 1
  escaped_tier=$(curl_config_escape "$tier") || return 1
  config_file=$(mktemp "${deploy_dir}/tmp/crisp-api.XXXXXX")
  chmod 600 "$config_file"
  {
    printf 'header = "Authorization: Basic %s"\n' "$escaped_auth"
    printf 'header = "X-Crisp-Tier: %s"\n' "$escaped_tier"
  } > "$config_file"
  # 不跟随重定向，避免把 Authorization 发送到其他主机。
  status=$(curl --silent --output /dev/null --write-out '%{http_code}' \
    --connect-timeout 5 --max-time 20 --retry 2 --retry-delay 1 --retry-max-time 45 \
    --config "$config_file" \
    "https://api.crisp.chat/v1/website/${website}" 2>/dev/null || true)
  rm -f -- "$config_file"
  CRISP_API_STATUS=${status:-000}
  [[ "$CRISP_API_STATUS" == 2?? ]]
}

webhook_access_check() {
  local deploy_dir=$1
  local url status response_file

  url=$(env_get "${deploy_dir}/.env" WEBHOOK_PRODUCTION_URL 2>/dev/null || true)
  [[ "$url" == https://*'/webhook/crisp-webhook' ]] || {
    WEBHOOK_ACCESS_STATUS=configuration
    return 1
  }
  response_file=$(mktemp "${deploy_dir}/tmp/webhook-access.XXXXXX")
  chmod 600 "$response_file"
  # 空事件只用于验证 DNS、TLS、反向代理及生产 webhook 路由；不携带 URL Secret，
  # 正常 workflow 会拒绝或忽略它，且不会触发 AI/Crisp 外发。
  status=$(curl --silent --output "$response_file" --write-out '%{http_code}' \
    --connect-timeout 8 --max-time 20 \
    --header 'Content-Type: application/json' --data '{}' "$url" 2>/dev/null || true)
  rm -f -- "$response_file"
  WEBHOOK_ACCESS_STATUS=${status:-000}
  case "$WEBHOOK_ACCESS_STATUS" in
    2??|3??|400|401|403|405|422) return 0 ;;
    *) return 1 ;;
  esac
}

configure_provider() {
  local deploy_dir=$1
  local non_interactive=${2:-0}
  local env_file="${deploy_dir}/.env"
  local base runtime_base api_key response_file status selected_model choice manual_model models_curl_config
  local responses=false chat=false api_mode vision_answer=false
  local default_model=${DEFAULT_AI_MODEL:-}
  local -a models=()

  require_command curl
  require_command jq
  if (( non_interactive )); then
    base=${AI_API_BASE_URL:-$(env_get "$env_file" AI_API_BASE_URL 2>/dev/null || true)}
    api_key=${AI_API_KEY:-$(env_get "$env_file" AI_API_KEY 2>/dev/null || true)}
  else
    printf '请输入 API Base URL：'
    IFS= read -r base
    printf '请输入 API Key（输入内容不会显示）：'
    IFS= read -r -s api_key
    printf '\n'
  fi
  base=$(normalize_api_base "$base") || die "API Base URL 无效；只允许不含认证信息、查询参数或路径穿越的 HTTP(S) 地址"
  validate_env_value "$api_key" || die "API Key 包含不安全字符或为空"

  response_file=$(mktemp "${deploy_dir}/tmp/models.XXXXXX")
  models_curl_config=$(mktemp "${deploy_dir}/tmp/models-curl.XXXXXX")
  chmod 600 "$models_curl_config"
  printf 'header = "Authorization: Bearer %s"\n' "$(curl_config_escape "$api_key")" > "$models_curl_config"
  status=$(curl --silent --output "$response_file" --write-out '%{http_code}' \
    --connect-timeout 8 --max-time 30 \
    --config "$models_curl_config" \
    "${base}/models" 2>/dev/null || true)
  if [[ "$status" == 2?? ]] && jq -e '.data | type == "array"' "$response_file" >/dev/null 2>&1; then
    mapfile -t models < <(jq -r '.data[]?.id | select(type == "string")' "$response_file" \
      | LC_ALL=C sort -u | head -n 500)
  fi
  rm -f -- "$response_file" "$models_curl_config"

  if (( ${#models[@]} > 0 )); then
    if (( non_interactive )); then
      selected_model=${AI_MODEL:-}
      if [[ -n "$selected_model" ]] && ! printf '%s\n' "${models[@]}" | grep -Fxq -- "$selected_model"; then
        warn "指定模型不在 /v1/models 返回列表中，将进行实际 Chat 能力验证：$selected_model"
      fi
      if [[ -z "$selected_model" ]]; then
        local candidate candidate_payload
        for candidate in "${models[@]}"; do
          validate_env_value "$candidate" || continue
          candidate_payload=$(jq -cn --arg model "$candidate" '{model:$model,messages:[{role:"user",content:"Reply only OK."}]}')
          if probe_api_endpoint "${base}/chat/completions" "$api_key" "$candidate_payload" "${deploy_dir}/tmp"; then
            selected_model=$candidate
            break
          fi
        done
        [[ -n "$selected_model" ]] || die "/v1/models 返回的模型均未通过 Chat Completions 实际请求"
      fi
    else
      printf '检测到模型：\n\n'
      local index
      for index in "${!models[@]}"; do
        printf '%d. %s\n' "$((index + 1))" "${models[index]}"
      done
      while true; do
        printf '\n请选择：'
        IFS= read -r choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#models[@]} )); then
          selected_model=${models[choice - 1]}
          break
        fi
        warn "请输入有效序号"
      done
    fi
  else
    warn "请求 /v1/models 失败或未返回模型"
    if (( non_interactive )); then
      selected_model=${AI_MODEL:-$default_model}
      [[ -n "$selected_model" ]] \
        || die "/v1/models 未返回可选模型；非交互安装必须明确设置 AI_MODEL"
    else
      printf '1. 手动输入模型名称\n'
      if [[ -n "$default_model" ]]; then
        printf '2. 使用管理员明确配置的默认模型（%s）\n' "$default_model"
      fi
      printf '请选择：'
      IFS= read -r choice
      if [[ "$choice" == "1" ]]; then
        printf '请输入模型名称：'
        IFS= read -r manual_model
        selected_model=$manual_model
      elif [[ "$choice" == "2" && -n "$default_model" ]]; then
        selected_model=$default_model
      else
        die "未选择有效模型，Provider 配置未保存"
      fi
    fi
  fi
  validate_model_identifier "$selected_model" || die "模型名称格式无效"

  local responses_payload chat_payload
  responses_payload=$(jq -cn --arg model "$selected_model" '{model:$model,input:"ping",max_output_tokens:16}')
  chat_payload=$(jq -cn --arg model "$selected_model" '{model:$model,messages:[{role:"user",content:"Reply only OK."}]}')
  if probe_api_endpoint "${base}/responses" "$api_key" "$responses_payload" "${deploy_dir}/tmp"; then responses=true; fi
  if probe_api_endpoint "${base}/chat/completions" "$api_key" "$chat_payload" "${deploy_dir}/tmp"; then chat=true; fi
  if [[ "$chat" != true ]]; then
    die "所选模型未通过 /v1/chat/completions 实际请求，AnythingLLM 无法使用该 Provider"
  fi
  if [[ "$responses" == true ]]; then
    api_mode=responses
  else
    api_mode=chat_completions
  fi

  local tiny_image vision_responses_payload vision_chat_payload
  tiny_image='data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII='
  vision_responses_payload=$(jq -cn --arg model "$selected_model" --arg image "$tiny_image" \
    '{model:$model,input:[{role:"user",content:[{type:"input_text",text:"Reply only OK."},{type:"input_image",image_url:$image}]}]}')
  vision_chat_payload=$(jq -cn --arg model "$selected_model" --arg image "$tiny_image" \
    '{model:$model,messages:[{role:"user",content:[{type:"text",text:"Reply only OK."},{type:"image_url",image_url:{url:$image}}]}]}')
  if [[ "$responses" == true ]] \
    && probe_api_endpoint "${base}/responses" "$api_key" "$vision_responses_payload" "${deploy_dir}/tmp"; then
    vision_answer=true
  elif probe_api_endpoint "${base}/chat/completions" "$api_key" "$vision_chat_payload" "${deploy_dir}/tmp"; then
    vision_answer=true
  fi
  if [[ "$vision_answer" == true ]]; then
    info "所选模型已通过实际图片输入能力检测"
  else
    warn "所选模型未通过图片输入能力检测；图片消息将提示切换视觉模型"
  fi

  runtime_base=$(provider_runtime_base "$base") || die "无法生成容器可用的 Provider 地址"
  env_set "$env_file" AI_API_PROBE_BASE_URL "$base"
  env_set "$env_file" AI_API_BASE_URL "$runtime_base"
  env_set "$env_file" AI_API_KEY "$api_key"
  env_set "$env_file" AI_MODEL "$selected_model"
  env_set "$env_file" AI_API_MODE "$api_mode"
  env_set "$env_file" AI_SUPPORTS_VISION "$vision_answer"

  local provider_temp
  provider_temp=$(mktemp "${deploy_dir}/config/provider.yaml.tmp.XXXXXX")
  chmod 600 "$provider_temp"
  {
    printf 'provider:\n'
    printf '  type: openai-compatible\n'
    printf '  base_url: %s\n' "$(jq -Rn --arg value "$runtime_base" '$value')"
    printf '  api_key_env: AI_API_KEY\n'
    printf '  model: %s\n' "$(jq -Rn --arg value "$selected_model" '$value')"
    printf '  api_mode: %s\n' "$api_mode"
    printf '  capabilities:\n'
    printf '    responses: %s\n' "$responses"
    printf '    chat_completions: %s\n' "$chat"
    printf '    vision: %s\n' "$vision_answer"
    printf '  endpoints:\n'
    printf '    models: /v1/models\n'
    printf '    responses: /v1/responses\n'
    printf '    chat_completions: /v1/chat/completions\n'
  } > "$provider_temp"
  mv -f -- "$provider_temp" "${deploy_dir}/config/provider.yaml"
  chmod 600 "${deploy_dir}/config/provider.yaml"
  if [[ "$runtime_base" != "$base" ]]; then
    info "Provider 已配置：模型 ${selected_model}，模式 ${api_mode}；容器将通过 host.docker.internal 访问宿主服务"
  else
    info "Provider 已配置：模型 ${selected_model}，模式 ${api_mode}"
  fi
}

anythingllm_api_ready() {
  local deploy_dir=$1
  local key
  key=$(env_get "${deploy_dir}/.env" ANYTHINGLLM_API_KEY 2>/dev/null || true)
  ! is_placeholder "$key"
}

anythingllm_secure_request() {
  local deploy_dir=$1
  local method=$2
  local url=$3
  local auth_value=${4:-}
  local payload=${5:-}
  local output_file=$6
  local max_time=${7:-60}
  local config_file payload_file status escaped_auth

  [[ "$method" == GET || "$method" == POST || "$method" == DELETE ]] || die "AnythingLLM 请求方法无效"
  [[ "$url" =~ ^http://127\.0\.0\.1:[0-9]{1,5}/ ]] || die "AnythingLLM 本地 API 地址无效"
  if [[ ! "$max_time" =~ ^[0-9]+$ ]] || (( max_time < 1 || max_time > 3600 )); then
    die "AnythingLLM 请求超时参数无效"
  fi
  config_file=$(mktemp "${deploy_dir}/tmp/curl-config.XXXXXX")
  payload_file=$(mktemp "${deploy_dir}/tmp/curl-body.XXXXXX")
  chmod 600 "$config_file" "$payload_file"
  {
    printf 'header = "Accept: application/json"\n'
    if [[ -n "$auth_value" ]]; then
      validate_env_value "$auth_value" || die "AnythingLLM 认证值无效"
      escaped_auth=$(curl_config_escape "$auth_value") || die "AnythingLLM 认证值无法安全写入请求配置"
      printf 'header = "Authorization: Bearer %s"\n' "$escaped_auth"
    fi
    if [[ "$method" == POST || "$method" == DELETE ]]; then
      printf 'header = "Content-Type: application/json"\n'
    fi
  } > "$config_file"
  if [[ "$method" == POST || "$method" == DELETE ]]; then
    printf '%s' "$payload" > "$payload_file"
    status=$(curl --silent --output "$output_file" --write-out '%{http_code}' \
      --connect-timeout 5 --max-time "$max_time" --config "$config_file" \
      --request "$method" \
      --data-binary "@${payload_file}" "$url" 2>/dev/null || true)
  else
    status=$(curl --silent --output "$output_file" --write-out '%{http_code}' \
      --connect-timeout 5 --max-time "$max_time" --config "$config_file" "$url" 2>/dev/null || true)
  fi
  rm -f -- "$config_file" "$payload_file"
  printf '%s\n' "${status:-000}"
}

anythingllm_validate_api_key() {
  local deploy_dir=$1
  local key=$2
  local port response_file status

  port=$(env_get "${deploy_dir}/.env" ANYTHINGLLM_PORT 2>/dev/null || printf '3001')
  response_file=$(mktemp "${deploy_dir}/tmp/anything-auth.XXXXXX")
  status=$(anythingllm_secure_request "$deploy_dir" GET \
    "http://127.0.0.1:${port}/api/v1/auth" "$key" "" "$response_file")
  if [[ "$status" != 2?? ]] || ! jq -e '(.authenticated == true) or (.success == true)' "$response_file" >/dev/null 2>&1; then
    rm -f -- "$response_file"
    return 1
  fi
  rm -f -- "$response_file"
}

bootstrap_anythingllm_api_key() {
  local deploy_dir=$1
  local env_file="${deploy_dir}/.env"
  local key auth_token port response_file payload status jwt
  local created=0

  require_command curl
  require_command jq
  key=$(env_get "$env_file" ANYTHINGLLM_API_KEY 2>/dev/null || true)
  if ! is_placeholder "$key"; then
    anythingllm_validate_api_key "$deploy_dir" "$key" \
      || die "已配置的 AnythingLLM Developer API Key 无效"
    return 0
  fi

  auth_token=$(env_get "$env_file" ANYTHINGLLM_AUTH_TOKEN 2>/dev/null || true)
  validate_env_value "$auth_token" || die "AnythingLLM 登录密码缺失或无效"
  port=$(env_get "$env_file" ANYTHINGLLM_PORT 2>/dev/null || printf '3001')
  response_file=$(mktemp "${deploy_dir}/tmp/anything-bootstrap.XXXXXX")
  payload=$(jq -cn --arg password "$auth_token" '{password:$password}')
  status=$(anythingllm_secure_request "$deploy_dir" POST \
    "http://127.0.0.1:${port}/api/request-token" "" "$payload" "$response_file")
  if [[ "$status" != 2?? ]]; then
    rm -f -- "$response_file"
    die "AnythingLLM 自动登录失败（HTTP ${status:-000}）"
  fi
  jwt=$(jq -er '.token | select(type == "string" and length > 0)' "$response_file" 2>/dev/null || true)
  rm -f -- "$response_file"
  validate_env_value "$jwt" || die "AnythingLLM 自动登录未返回有效令牌"

  response_file=$(mktemp "${deploy_dir}/tmp/anything-api-key.XXXXXX")
  status=$(anythingllm_secure_request "$deploy_dir" GET \
    "http://127.0.0.1:${port}/api/system/api-keys" "$jwt" "" "$response_file")
  if [[ "$status" == 2?? ]]; then
    key=$(jq -er '.apiKeys[]? | select(.name == "ai-support") | .secret | select(type == "string" and length > 0)' \
      "$response_file" 2>/dev/null | head -n 1 || true)
  fi
  if is_placeholder "$key"; then
    payload=$(jq -cn '{name:"ai-support"}')
    status=$(anythingllm_secure_request "$deploy_dir" POST \
      "http://127.0.0.1:${port}/api/system/generate-api-key" "$jwt" "$payload" "$response_file")
    if [[ "$status" != 2?? ]]; then
      rm -f -- "$response_file"
      die "AnythingLLM Developer API Key 自动创建失败（HTTP ${status:-000}）"
    fi
    key=$(jq -er '.apiKey.secret | select(type == "string" and length > 0)' "$response_file" 2>/dev/null || true)
    created=1
  fi
  rm -f -- "$response_file"
  validate_env_value "$key" || die "AnythingLLM 未返回有效的 Developer API Key"
  env_set "$env_file" ANYTHINGLLM_API_KEY "$key"
  anythingllm_validate_api_key "$deploy_dir" "$key" || die "新建 AnythingLLM API Key 验证失败"
  if (( created )); then
    info "AnythingLLM Developer API Key 已自动创建"
  else
    info "AnythingLLM Developer API Key 已自动复用"
  fi
}

ensure_anythingllm_workspace() {
  local deploy_dir=$1
  local env_file="${deploy_dir}/.env"
  local key requested_workspace actual_workspace port response_file payload status

  require_command jq
  key=$(env_get "$env_file" ANYTHINGLLM_API_KEY)
  requested_workspace=$(env_get "$env_file" ANYTHINGLLM_WORKSPACE)
  [[ "$requested_workspace" =~ ^[A-Za-z0-9_-]{1,128}$ ]] || die "AnythingLLM 工作区 slug 无效"
  port=$(env_get "$env_file" ANYTHINGLLM_PORT 2>/dev/null || printf '3001')
  response_file=$(mktemp "${deploy_dir}/tmp/anything-workspace.XXXXXX")
  status=$(anythingllm_secure_request "$deploy_dir" GET \
    "http://127.0.0.1:${port}/api/v1/workspace/${requested_workspace}" "$key" "" "$response_file")
  [[ "$status" == 2?? ]] || { rm -f -- "$response_file"; die "AnythingLLM 工作区检查失败（HTTP ${status:-000}）"; }
  actual_workspace=$(jq -er '
    .workspace as $workspace |
    if ($workspace | type) == "array" then $workspace[0].slug // empty
    elif ($workspace | type) == "object" then $workspace.slug // empty
    else empty end
  ' "$response_file" 2>/dev/null || true)
  if [[ -z "$actual_workspace" ]]; then
    jq -e '.workspace | type == "array" and length == 0' "$response_file" >/dev/null 2>&1 \
      || { rm -f -- "$response_file"; die "AnythingLLM 工作区响应格式无效"; }
    payload=$(jq -cn --arg name "$requested_workspace" '{name:$name}')
    status=$(anythingllm_secure_request "$deploy_dir" POST \
      "http://127.0.0.1:${port}/api/v1/workspace/new" "$key" "$payload" "$response_file")
    [[ "$status" == 2?? ]] || { rm -f -- "$response_file"; die "AnythingLLM 工作区创建失败（HTTP ${status:-000}）"; }
    actual_workspace=$(jq -er '.workspace.slug | select(type == "string" and length > 0)' "$response_file" 2>/dev/null || true)
  fi
  rm -f -- "$response_file"
  [[ "$actual_workspace" =~ ^[A-Za-z0-9_-]{1,128}$ ]] || die "AnythingLLM 返回的工作区 slug 无效"
  env_set "$env_file" ANYTHINGLLM_WORKSPACE "$actual_workspace"

  response_file=$(mktemp "${deploy_dir}/tmp/anything-workspace-verify.XXXXXX")
  status=$(anythingllm_secure_request "$deploy_dir" GET \
    "http://127.0.0.1:${port}/api/v1/workspace/${actual_workspace}" "$key" "" "$response_file")
  if [[ "$status" != 2?? ]] || ! jq -e --arg slug "$actual_workspace" '
    .workspace as $workspace |
    if ($workspace | type) == "array" then any($workspace[]; .slug == $slug)
    elif ($workspace | type) == "object" then $workspace.slug == $slug
    else false end
  ' "$response_file" >/dev/null 2>&1; then
    rm -f -- "$response_file"
    die "AnythingLLM 工作区创建后验证失败"
  fi
  rm -f -- "$response_file"
  info "AnythingLLM 工作区已就绪：${actual_workspace}"
}

sync_prompt_to_anythingllm() {
  local deploy_dir=$1
  local env_file="${deploy_dir}/.env"
  local key workspace port prompt payload response_file response
  if ! anythingllm_api_ready "$deploy_dir"; then
    warn "请先配置 AnythingLLM Developer API Key"
    return 1
  fi
  require_command curl
  require_command jq
  key=$(env_get "$env_file" ANYTHINGLLM_API_KEY)
  workspace=$(env_get "$env_file" ANYTHINGLLM_WORKSPACE)
  port=$(env_get "$env_file" ANYTHINGLLM_PORT 2>/dev/null || printf '3001')
  prompt=$(<"${deploy_dir}/config/prompt.md")
  payload=$(jq -cn --arg prompt "$prompt" '{openAiPrompt:$prompt}')
  response_file=$(mktemp "${deploy_dir}/tmp/prompt-sync.XXXXXX")
  response=$(anythingllm_secure_request "$deploy_dir" POST \
    "http://127.0.0.1:${port}/api/v1/workspace/${workspace}/update" "$key" "$payload" "$response_file")
  if [[ "$response" != 2?? ]] || ! jq -e --arg prompt "$prompt" '
    .workspace as $workspace |
    (if ($workspace | type) == "array" then $workspace[0]
     elif ($workspace | type) == "object" then $workspace
     else {} end) |
    (.openAiPrompt // "") == $prompt
  ' "$response_file" >/dev/null 2>&1; then
    rm -f -- "$response_file"
    warn "同步 Prompt 到 AnythingLLM 失败（HTTP ${response:-000}）"
    return 1
  fi
  rm -f -- "$response_file"
  info "Prompt 已同步到 AnythingLLM 工作区"
}

import_and_publish_workflow() {
  local deploy_dir=$1
  require_command docker
  if ! docker_compose "$deploy_dir" exec -T n8n timeout 900 \
    n8n import:workflow --input=/opt/crisp-ai/n8n/workflow.json >/dev/null; then
    warn "n8n workflow 导入失败或超过 15 分钟"
    return 1
  fi
  if ! docker_compose "$deploy_dir" exec -T n8n timeout 900 \
    n8n publish:workflow --id="$WORKFLOW_ID" >/dev/null; then
    warn "n8n workflow 发布失败或超过 15 分钟"
    return 1
  fi
  if ! docker_compose "$deploy_dir" restart n8n >/dev/null; then
    warn "n8n workflow 已发布，但服务重启失败"
    return 1
  fi
  info "n8n 工作流已导入并发布"
}

is_supported_knowledge_file() {
  local name=${1,,}
  case "$name" in
    *.md|*.txt|*.pdf|*.docx) return 0 ;;
    *) return 1 ;;
  esac
}

import_prompt_source() {
  local deploy_dir=$1
  local requested=${2:-}
  local resolved target size

  [[ -n "$requested" ]] || return 0
  resolved=$(realpath -e -- "$requested") || die "Prompt 文件不存在：$requested"
  [[ -f "$resolved" && ! -L "$resolved" ]] || die "Prompt 必须是普通文件且不能是符号链接"
  size=$(stat -c '%s' "$resolved")
  if [[ ! "$size" =~ ^[0-9]+$ ]] || (( size <= 0 || size > 262144 )); then
    die "Prompt 文件必须为 1 到 262144 字节"
  fi
  target="${deploy_dir}/config/prompt.md"
  if [[ "$(realpath -m -- "$resolved")" != "$(realpath -m -- "$target")" ]]; then
    install -m 0640 -- "$resolved" "$target"
  fi
  chown root:1000 "$target" 2>/dev/null || true
}

import_knowledge_source() {
  local deploy_dir=$1
  local requested=${2:-}
  local resolved file name staging target count=0
  local -a files=()

  [[ -n "$requested" ]] || {
    printf '0\n'
    return 0
  }
  resolved=$(realpath -e -- "$requested") || die "知识来源不存在：$requested"
  [[ ! -L "$resolved" ]] || die "知识来源不能是符号链接"
  if [[ -f "$resolved" ]]; then
    is_supported_knowledge_file "$resolved" || die "知识文件只支持 Markdown、TXT、PDF 或 DOCX"
    files+=("$resolved")
  elif [[ -d "$resolved" ]]; then
    while IFS= read -r -d '' file; do
      is_supported_knowledge_file "$file" || continue
      files+=("$file")
    done < <(find "$resolved" -maxdepth 1 -type f ! -type l -print0 | sort -z)
  else
    die "知识来源必须是普通文件或目录"
  fi

  staging=$(mktemp -d "${deploy_dir}/tmp/knowledge-import.XXXXXX")
  for file in "${files[@]}"; do
    name=$(basename -- "$file")
    [[ "$name" != *$'\n'* && "$name" != *$'\r'* && "$name" != *\\* \
      && "$name" != */* && "$name" != *';'* && "$name" != *','* ]] \
      || { rm -rf -- "$staging"; die "知识文件名包含不安全字符：$name"; }
    [[ ! -e "${staging}/${name}" ]] \
      || { rm -rf -- "$staging"; die "知识目录存在重名文件：$name"; }
    install -m 0640 -- "$file" "${staging}/${name}"
  done
  while IFS= read -r -d '' file; do
    name=$(basename -- "$file")
    target="${deploy_dir}/knowledge/${name}"
    if [[ "$(realpath -m -- "$file")" != "$(realpath -m -- "$target")" ]]; then
      install -m 0640 -- "$file" "$target"
    fi
    ((count += 1))
  done < <(find "$staging" -maxdepth 1 -type f -print0 | sort -z)
  rm -rf -- "$staging"
  chown -R root:1000 "${deploy_dir}/knowledge" 2>/dev/null || true
  printf '%d\n' "$count"
}

anythingllm_connection() {
  local deploy_dir=$1
  local env_file="${deploy_dir}/.env"
  ANYTHING_DEPLOY_DIR=$deploy_dir
  ANYTHING_KEY=$(env_get "$env_file" ANYTHINGLLM_API_KEY 2>/dev/null || true)
  ANYTHING_WORKSPACE=$(env_get "$env_file" ANYTHINGLLM_WORKSPACE 2>/dev/null || true)
  ANYTHING_PORT=$(env_get "$env_file" ANYTHINGLLM_PORT 2>/dev/null || printf '3001')
  anythingllm_api_ready "$deploy_dir" || die "AnythingLLM Developer API Key 尚未配置"
  [[ "$ANYTHING_WORKSPACE" =~ ^[A-Za-z0-9_-]{1,128}$ ]] || die "AnythingLLM 工作区 slug 无效"
  validate_port "$ANYTHING_PORT" || die "AnythingLLM 端口无效"
}

anythingllm_workspace_locations() {
  local response_file status locations

  response_file=$(mktemp "${ANYTHING_DEPLOY_DIR}/tmp/workspace-documents.XXXXXX")
  status=$(anythingllm_secure_request "$ANYTHING_DEPLOY_DIR" GET \
    "http://127.0.0.1:${ANYTHING_PORT}/api/v1/workspace/${ANYTHING_WORKSPACE}" \
    "$ANYTHING_KEY" "" "$response_file")
  if [[ "$status" != 2?? ]]; then
    rm -f -- "$response_file"
    return 1
  fi
  locations=$(jq -c '
    .workspace as $workspace |
    (if ($workspace | type) == "array" then $workspace
     elif ($workspace | type) == "object" then [$workspace]
     else [] end) |
    [.[].documents[]?.docpath | select(type == "string")] | unique
  ' "$response_file" 2>/dev/null) || { rm -f -- "$response_file"; return 1; }
  rm -f -- "$response_file"
  printf '%s\n' "$locations"
}

anythingllm_locations_have_state() {
  local expected=$1
  local should_exist=$2
  local actual

  actual=$(anythingllm_workspace_locations) || return 1
  if [[ "$should_exist" == true ]]; then
    jq -en --argjson expected "$expected" --argjson actual "$actual" \
      'all($expected[]; . as $item | $actual | index($item) != null)' >/dev/null
  else
    jq -en --argjson expected "$expected" --argjson actual "$actual" \
      'all($expected[]; . as $item | $actual | index($item) == null)' >/dev/null
  fi
}

anythingllm_wait_locations_state() {
  local expected=$1
  local should_exist=$2
  local timeout=${3:-180}
  local interval=${ANYTHINGLLM_EMBED_POLL_SECONDS:-2}
  local deadline

  if [[ ! "$timeout" =~ ^[0-9]+$ ]] || (( timeout < 0 || timeout > 3600 )); then
    return 1
  fi
  if [[ ! "$interval" =~ ^[0-9]+$ ]] || (( interval < 1 || interval > 30 )); then
    interval=2
  fi
  deadline=$((SECONDS + timeout))
  while true; do
    anythingllm_locations_have_state "$expected" "$should_exist" && return 0
    (( SECONDS < deadline )) || return 1
    sleep "$interval"
  done
}

anythingllm_update_embeddings() {
  local payload=$1
  local status response_file adds deletes request_timeout state_timeout

  request_timeout=${ANYTHINGLLM_EMBED_REQUEST_TIMEOUT_SECONDS:-900}
  state_timeout=${ANYTHINGLLM_EMBED_STATE_WAIT_SECONDS:-180}
  if [[ ! "$request_timeout" =~ ^[0-9]+$ ]] \
    || (( request_timeout < 60 || request_timeout > 3600 )); then
    request_timeout=900
  fi
  if [[ ! "$state_timeout" =~ ^[0-9]+$ ]] \
    || (( state_timeout < 0 || state_timeout > 3600 )); then
    state_timeout=180
  fi
  response_file=$(mktemp "${ANYTHING_DEPLOY_DIR}/tmp/update-embeddings.XXXXXX")
  status=$(anythingllm_secure_request "$ANYTHING_DEPLOY_DIR" POST \
    "http://127.0.0.1:${ANYTHING_PORT}/api/v1/workspace/${ANYTHING_WORKSPACE}/update-embeddings" \
    "$ANYTHING_KEY" "$payload" "$response_file" "$request_timeout")
  if [[ -s "$response_file" ]] \
    && jq -e '.error == true' "$response_file" >/dev/null 2>&1; then
    rm -f -- "$response_file"
    return 1
  fi
  rm -f -- "$response_file"
  adds=$(jq -c '.adds // []' <<< "$payload")
  deletes=$(jq -c '.deletes // []' <<< "$payload")
  if [[ "$status" == 2?? ]]; then
    [[ "$adds" == "[]" ]] \
      || anythingllm_wait_locations_state "$adds" true "$state_timeout" || return 2
    [[ "$deletes" == "[]" ]] \
      || anythingllm_wait_locations_state "$deletes" false "$state_timeout" || return 2
    return 0
  fi

  # 000、超时、限流和服务端错误都可能表示服务端已经受理但客户端尚未收到响应。
  # 此时只对账，不删除源文档，避免与仍在执行的索引任务竞态。
  if [[ "$status" == 000 || "$status" == 408 || "$status" == 429 || "$status" == 5?? ]]; then
    [[ "$adds" == "[]" ]] \
      || anythingllm_wait_locations_state "$adds" true "$state_timeout" || return 2
    [[ "$deletes" == "[]" ]] \
      || anythingllm_wait_locations_state "$deletes" false "$state_timeout" || return 2
    return 0
  fi
  return 1
}

anythingllm_remove_documents() {
  local names=$1
  local status response_file payload

  [[ "$names" != "[]" ]] || return 0
  payload=$(jq -cn --argjson names "$names" '{names:$names}')
  response_file=$(mktemp "${ANYTHING_DEPLOY_DIR}/tmp/remove-documents.XXXXXX")
  status=$(anythingllm_secure_request "$ANYTHING_DEPLOY_DIR" DELETE \
    "http://127.0.0.1:${ANYTHING_PORT}/api/v1/system/remove-documents" \
    "$ANYTHING_KEY" "$payload" "$response_file")
  if [[ "$status" != 2?? ]] || ! jq -e '.success == true' "$response_file" >/dev/null 2>&1; then
    rm -f -- "$response_file"
    return 1
  fi
  rm -f -- "$response_file"
}

knowledge_record_garbage() {
  local manifest=$1
  local locations=$2
  local manifest_temp

  [[ "$locations" != "[]" ]] || return 0
  manifest_temp=$(mktemp "${manifest}.tmp.XXXXXX")
  jq --argjson garbage "$locations" \
    '.garbage_locations = (((.garbage_locations // []) + $garbage) | unique)' \
    "$manifest" > "$manifest_temp"
  chmod 600 "$manifest_temp"
  mv -f -- "$manifest_temp" "$manifest"
}

knowledge_record_pending() {
  local manifest=$1
  local filename=$2
  local hash=$3
  local locations=$4
  local old_locations=$5
  local manifest_temp now

  now=$(date +%s)
  manifest_temp=$(mktemp "${manifest}.tmp.XXXXXX")
  jq --arg name "$filename" --arg hash "$hash" --argjson locations "$locations" \
    --argjson old_locations "$old_locations" --argjson started_at "$now" \
    '.pending_files = (.pending_files // {}) |
     .pending_files[$name] = {
       sha256:$hash,
       locations:$locations,
       old_locations:$old_locations,
       started_at:$started_at
     }' "$manifest" > "$manifest_temp"
  chmod 600 "$manifest_temp"
  mv -f -- "$manifest_temp" "$manifest"
}

knowledge_clear_pending() {
  local manifest=$1
  local filename=$2
  local manifest_temp

  manifest_temp=$(mktemp "${manifest}.tmp.XXXXXX")
  jq --arg name "$filename" \
    '.pending_files = (.pending_files // {}) | del(.pending_files[$name])' \
    "$manifest" > "$manifest_temp"
  chmod 600 "$manifest_temp"
  mv -f -- "$manifest_temp" "$manifest"
}

knowledge_sync() {
  local deploy_dir=$1
  local force=${2:-0}
  local knowledge_dir="${deploy_dir}/knowledge"
  local manifest="${deploy_dir}/data/knowledge-manifest.json"
  local response_file manifest_temp file filename hash old_hash locations old_locations payload status upload_config stale_locations garbage_locations escaped_key
  local pending_hash pending_locations pending_old_locations pending_started pending_age pending_retry_after update_status
  local failures=0 uploaded=0 removed=0 skipped=0
  local -a files=()

  require_command curl
  require_command jq
  require_command sha256sum
  anythingllm_connection "$deploy_dir"
  if [[ ! -f "$manifest" ]]; then
    printf '{"version":1,"files":{},"pending_files":{},"garbage_locations":[]}\n' > "$manifest"
    chmod 600 "$manifest"
  fi
  jq -e '
    .version == 1 and (.files | type == "object") and
    ((.pending_files // {}) | type == "object") and
    ((.garbage_locations // []) | type == "array" and all(type == "string"))
  ' "$manifest" >/dev/null || die "知识库清单格式无效：$manifest"

  garbage_locations=$(jq -c '(.garbage_locations // []) | unique' "$manifest")
  if [[ "$garbage_locations" != "[]" ]]; then
    payload=$(jq -cn --argjson deletes "$garbage_locations" '{adds:[],deletes:$deletes}')
    if anythingllm_update_embeddings "$payload" \
      && anythingllm_remove_documents "$garbage_locations"; then
      manifest_temp=$(mktemp "${manifest}.tmp.XXXXXX")
      jq '.garbage_locations = []' "$manifest" > "$manifest_temp"
      chmod 600 "$manifest_temp"
      mv -f -- "$manifest_temp" "$manifest"
      info "已清理上次同步遗留的 AnythingLLM 源文档"
    else
      warn "上次同步遗留的 AnythingLLM 源文档仍未清理，将在下次同步重试"
      ((failures += 1))
    fi
  fi
  pending_retry_after=${ANYTHINGLLM_PENDING_RETRY_AFTER_SECONDS:-1200}
  if [[ ! "$pending_retry_after" =~ ^[0-9]+$ ]] \
    || (( pending_retry_after < 60 || pending_retry_after > 86400 )); then
    pending_retry_after=1200
  fi

  while IFS= read -r -d '' file; do
    is_supported_knowledge_file "$file" && files+=("$file")
  done < <(find "$knowledge_dir" -maxdepth 1 -type f ! -name 'README.md' -print0 | sort -z)

  for file in "${files[@]}"; do
    [[ ! -L "$file" ]] || { warn "跳过符号链接：$file"; ((failures += 1)); continue; }
    filename=$(basename -- "$file")
    [[ "$filename" != */* && "$filename" != *$'\n'* && "$filename" != *$'\r'* \
      && "$filename" != *\\* && "$filename" != *';'* && "$filename" != *','* ]] \
      || { warn "跳过非法文件名"; ((failures += 1)); continue; }
    hash=$(sha256sum -- "$file" | awk '{print $1}')
    old_hash=$(jq -r --arg name "$filename" '.files[$name].sha256 // ""' "$manifest")
    pending_hash=$(jq -r --arg name "$filename" '.pending_files[$name].sha256 // ""' "$manifest")
    locations=''
    old_locations=''
    if [[ -n "$pending_hash" ]]; then
      pending_locations=$(jq -c --arg name "$filename" '.pending_files[$name].locations // []' "$manifest")
      pending_old_locations=$(jq -c --arg name "$filename" '.pending_files[$name].old_locations // []' "$manifest")
      pending_started=$(jq -r --arg name "$filename" '.pending_files[$name].started_at // 0' "$manifest")
      [[ "$pending_started" =~ ^[0-9]+$ ]] || pending_started=0
      pending_age=$(( $(date +%s) - pending_started ))
      if [[ "$hash" != "$pending_hash" || "$pending_locations" == "[]" ]]; then
        if (( pending_age < pending_retry_after )); then
          warn "知识文件在上次索引结果未确认时发生变化，已保留进度供稍后重试：$filename"
          ((failures += 1))
          continue
        fi
        payload=$(jq -cn --argjson deletes "$pending_locations" '{adds:[],deletes:$deletes}')
        if [[ "$pending_locations" != "[]" ]] \
          && { ! anythingllm_update_embeddings "$payload" \
            || ! anythingllm_remove_documents "$pending_locations"; }; then
          warn "无法安全清理已变更文件的上次索引进度：$filename"
          ((failures += 1))
          continue
        fi
        knowledge_clear_pending "$manifest" "$filename"
        pending_hash=''
        info "已清理发生变化文件的旧索引进度：$filename"
      elif anythingllm_wait_locations_state "$pending_locations" true \
        "${ANYTHINGLLM_EMBED_STATE_WAIT_SECONDS:-180}"; then
        locations=$pending_locations
        old_locations=$pending_old_locations
        info "已从 AnythingLLM 实际状态恢复未完成的知识索引：$filename"
      else
        if (( pending_age < pending_retry_after )); then
          warn "知识索引仍在服务端处理中，已保留进度供稍后重试：$filename"
          ((failures += 1))
          continue
        fi
        payload=$(jq -cn --argjson adds "$pending_locations" '{adds:$adds,deletes:[]}')
        knowledge_record_pending "$manifest" "$filename" "$hash" \
          "$pending_locations" "$pending_old_locations"
        if anythingllm_update_embeddings "$payload"; then
          locations=$pending_locations
          old_locations=$pending_old_locations
          info "已重试并恢复未完成的知识索引：$filename"
        else
          warn "知识索引结果仍无法确认，未删除服务端文档：$filename"
          ((failures += 1))
          continue
        fi
      fi
    fi

    if [[ -z "$locations" ]]; then
      if [[ "$force" != 1 && "$hash" == "$old_hash" ]]; then
        ((skipped += 1))
        continue
      fi

      response_file=$(mktemp "${deploy_dir}/tmp/knowledge-upload.XXXXXX")
      upload_config=$(mktemp "${deploy_dir}/tmp/knowledge-curl.XXXXXX")
      chmod 600 "$upload_config"
      escaped_key=$(curl_config_escape "$ANYTHING_KEY") \
        || { rm -f -- "$upload_config" "$response_file"; die "AnythingLLM API Key 无法安全写入请求配置"; }
      printf 'header = "Authorization: Bearer %s"\n' "$escaped_key" > "$upload_config"
      status=$(curl --silent --output "$response_file" --write-out '%{http_code}' \
        --connect-timeout 5 --max-time 300 \
        --config "$upload_config" \
        --form "file=@${file}" \
        "http://127.0.0.1:${ANYTHING_PORT}/api/v1/document/upload" 2>/dev/null || true)
      rm -f -- "$upload_config"
      if [[ "$status" != 2?? ]] || ! jq -e '.success == true and (.documents | type == "array")' "$response_file" >/dev/null 2>&1; then
        warn "知识文件同步失败：$filename（HTTP ${status:-000}）"
        rm -f -- "$response_file"
        ((failures += 1))
        continue
      fi
      locations=$(jq -c '[.documents[]?.location | select(type == "string")]' "$response_file")
      rm -f -- "$response_file"
      if [[ "$locations" == "[]" ]]; then
        warn "AnythingLLM 未返回文档位置：$filename"
        ((failures += 1))
        continue
      fi

      old_locations=$(jq -c --arg name "$filename" '.files[$name].locations // []' "$manifest")
      knowledge_record_pending "$manifest" "$filename" "$hash" "$locations" "$old_locations"
      payload=$(jq -cn --argjson adds "$locations" '{adds:$adds,deletes:[]}')
      if anythingllm_update_embeddings "$payload"; then
        update_status=0
      else
        update_status=$?
      fi
      if (( update_status != 0 )); then
        if (( update_status == 2 )); then
          warn "知识索引结果暂时未知，已保留恢复信息且不会删除服务端文档：$filename"
        else
          warn "知识索引被 AnythingLLM 明确拒绝，已保留旧索引：$filename"
          if anythingllm_remove_documents "$locations"; then
            knowledge_clear_pending "$manifest" "$filename"
          else
            knowledge_record_garbage "$manifest" "$locations"
            knowledge_clear_pending "$manifest" "$filename"
            warn "本次上传的源文档清理失败，已登记供下次同步重试：$filename"
          fi
        fi
        ((failures += 1))
        continue
      fi
    fi
    stale_locations='[]'
    if [[ "$old_locations" != "[]" ]]; then
      stale_locations=$(jq -cn --argjson old "$old_locations" --argjson current "$locations" '$old - $current')
      payload=$(jq -cn --argjson deletes "$stale_locations" '{adds:[],deletes:$deletes}')
      if [[ "$stale_locations" != "[]" ]] && ! anythingllm_update_embeddings "$payload"; then
        warn "旧索引清理结果无法确认；新索引保持可用，旧位置已登记供下次重试：$filename"
        knowledge_record_garbage "$manifest" "$stale_locations"
        ((failures += 1))
        stale_locations='[]'
      fi
    fi
    garbage_locations='[]'
    if [[ "$stale_locations" != "[]" ]] && ! anythingllm_remove_documents "$stale_locations"; then
      warn "旧源文档清理失败，已登记供下次同步重试：$filename"
      garbage_locations=$stale_locations
      ((failures += 1))
    fi
    manifest_temp=$(mktemp "${manifest}.tmp.XXXXXX")
    jq --arg name "$filename" --arg hash "$hash" --argjson locations "$locations" \
      --argjson garbage "$garbage_locations" \
      '.files[$name] = {sha256:$hash, locations:$locations} |
       .pending_files = (.pending_files // {}) | del(.pending_files[$name]) |
       .garbage_locations = (((.garbage_locations // []) + $garbage) | unique)' \
      "$manifest" > "$manifest_temp"
    chmod 600 "$manifest_temp"
    mv -f -- "$manifest_temp" "$manifest"
    ((uploaded += 1))
  done

  while IFS= read -r filename; do
    [[ -n "$filename" ]] || continue
    [[ -e "${knowledge_dir}/${filename}" ]] && continue
    pending_locations=$(jq -c --arg name "$filename" '.pending_files[$name].locations // []' "$manifest")
    pending_started=$(jq -r --arg name "$filename" '.pending_files[$name].started_at // 0' "$manifest")
    [[ "$pending_started" =~ ^[0-9]+$ ]] || pending_started=0
    pending_age=$(( $(date +%s) - pending_started ))
    if (( pending_age < pending_retry_after )) \
      && ! anythingllm_locations_have_state "$pending_locations" true; then
      warn "已删除文件的旧索引仍可能在服务端处理中，已保留进度：$filename"
      ((failures += 1))
      continue
    fi
    payload=$(jq -cn --argjson deletes "$pending_locations" '{adds:[],deletes:$deletes}')
    if [[ "$pending_locations" != "[]" ]] \
      && { ! anythingllm_update_embeddings "$payload" \
        || ! anythingllm_remove_documents "$pending_locations"; }; then
      warn "无法安全清理已删除文件的未完成索引：$filename"
      ((failures += 1))
      continue
    fi
    knowledge_clear_pending "$manifest" "$filename"
    ((removed += 1))
  done < <(jq -r '(.pending_files // {}) | keys[]' "$manifest")

  while IFS= read -r filename; do
    [[ -n "$filename" ]] || continue
    [[ "$filename" != */* && "$filename" != *$'\n'* && "$filename" != *$'\r'* \
      && "$filename" != *\\* && "$filename" != *';'* && "$filename" != *','* ]] \
      || { warn "清单含非法路径，拒绝处理：$filename"; ((failures += 1)); continue; }
    [[ -e "${knowledge_dir}/${filename}" ]] && continue
    old_locations=$(jq -c --arg name "$filename" '.files[$name].locations // []' "$manifest")
    payload=$(jq -cn --argjson deletes "$old_locations" '{adds:[],deletes:$deletes}')
    if [[ "$old_locations" != "[]" ]] && ! anythingllm_update_embeddings "$payload"; then
      warn "移除知识索引失败：$filename"
      ((failures += 1))
      continue
    fi
    garbage_locations='[]'
    if [[ "$old_locations" != "[]" ]] && ! anythingllm_remove_documents "$old_locations"; then
      warn "源文档清理失败，已登记供下次同步重试：$filename"
      garbage_locations=$old_locations
      ((failures += 1))
    fi
    manifest_temp=$(mktemp "${manifest}.tmp.XXXXXX")
    jq --arg name "$filename" --argjson garbage "$garbage_locations" \
      'del(.files[$name]) |
       .garbage_locations = (((.garbage_locations // []) + $garbage) | unique)' \
      "$manifest" > "$manifest_temp"
    chmod 600 "$manifest_temp"
    mv -f -- "$manifest_temp" "$manifest"
    ((removed += 1))
  done < <(jq -r '.files | keys[]' "$manifest")

  info "知识库同步完成：新增或更新 ${uploaded}，移除 ${removed}，未变化 ${skipped}，失败 ${failures}"
  (( failures == 0 ))
}

knowledge_reindex() {
  local deploy_dir=$1
  local manifest="${deploy_dir}/data/knowledge-manifest.json"

  require_command jq
  anythingllm_connection "$deploy_dir"
  [[ -f "$manifest" ]] || die "尚无知识库同步清单，请先执行同步"
  jq -e '.files | length > 0' "$manifest" >/dev/null || die "没有可重新索引的文档"
  knowledge_sync "$deploy_dir" 1 || die "重新建立索引失败；已验证的旧索引保持可用"
  info "知识库重新索引完成"
}
