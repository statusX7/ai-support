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
  docker compose version >/dev/null 2>&1 || die "未检测到 Docker Compose v2"
  docker info >/dev/null 2>&1 || die "无法连接 Docker daemon，请确认 Docker Engine 已启动且当前用户有权限访问"
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
}

env_get() {
  local env_file=$1
  local key=$2
  local line value

  [[ -f "$env_file" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == "${key}="* ]] || continue
    value=${line#*=}
    if [[ ${#value} -ge 2 && "$value" == \"*\" && "$value" == *\" ]]; then
      value=${value:1:${#value}-2}
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
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || return 1
  [[ "$value" =~ ^[A-Za-z0-9._~:/@+,=%?\&-]+$ ]]
}

env_set() {
  local env_file=$1
  local key=$2
  local value=$3
  local temp line replaced=0

  [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || die "环境变量名称无效：$key"
  validate_env_value "$value" || die "${key} 包含不安全字符或为空"
  mkdir -p -- "$(dirname -- "$env_file")"
  touch -- "$env_file"
  temp=$(mktemp "${env_file}.tmp.XXXXXX")
  chmod 600 "$temp"

  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == "${key}="* ]]; then
      if (( replaced == 0 )); then
        printf '%s=%s\n' "$key" "$value" >> "$temp"
        replaced=1
      fi
    else
      printf '%s\n' "$line" >> "$temp"
    fi
  done < "$env_file"
  if (( replaced == 0 )); then
    printf '%s=%s\n' "$key" "$value" >> "$temp"
  fi
  mv -f -- "$temp" "$env_file"
  chmod 600 "$env_file"
}

is_placeholder() {
  local value=${1:-}
  [[ -z "$value" || "$value" == replace-with-* || "$value" == pending-* ]]
}

provider_config_has_secret_field() {
  local provider_file=$1
  grep -Eiq '^[[:space:]]*(api[-_]?key|key|token|secret|password|authorization)[[:space:]]*:' "$provider_file"
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

docker_compose() {
  local deploy_dir=$1
  shift
  docker compose \
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
    "${deploy_dir}/backups/versions" "${deploy_dir}/tmp" 2>/dev/null || true
  chmod 750 "${deploy_dir}/config" "${deploy_dir}/knowledge" "${deploy_dir}/n8n" "${deploy_dir}/scripts" "${deploy_dir}/docs" 2>/dev/null || true
  chmod 770 "${deploy_dir}/data/analytics" 2>/dev/null || true
  [[ -f "${deploy_dir}/.env" ]] && chmod 600 "${deploy_dir}/.env"
  [[ -f "${deploy_dir}/config/provider.yaml" ]] && chmod 600 "${deploy_dir}/config/provider.yaml"
  [[ -f "${deploy_dir}/data/analytics/events.jsonl" ]] && chmod 660 "${deploy_dir}/data/analytics/events.jsonl"
  find "${deploy_dir}/config" -maxdepth 1 -type f ! -name 'provider.yaml' -exec chmod 640 {} + 2>/dev/null || true
  find "${deploy_dir}/knowledge" -maxdepth 1 -type f -exec chmod 640 {} + 2>/dev/null || true
}

copy_project_files() {
  local source_dir=$1
  local deploy_dir=$2
  local file directory
  local regular_files=(
    VERSION CHANGELOG.md README.md LICENSE AGENTS.md .env.example docker-compose.yml
    config/app.yaml config/provider.yaml.example config/prompt.md.example
    config/keyword.yaml.example config/menu.yaml.example config/handoff.yaml.example
    config/tags.yaml.example config/feedback.yaml.example
    n8n/workflow.json knowledge/README.md
    docs/INSTALL.md docs/ARCHITECTURE.md docs/CONFIG.md docs/SECURITY.md docs/TESTING.md
  )
  local executable_files=(
    install.sh manage.sh update.sh uninstall.sh
    scripts/common.sh scripts/healthcheck.sh scripts/backup.sh scripts/restore.sh
    scripts/analytics.sh scripts/snapshot.sh scripts/rollback.sh
  )

  mkdir -p -- "$deploy_dir" "${deploy_dir}/config" "${deploy_dir}/knowledge" "${deploy_dir}/n8n" \
    "${deploy_dir}/scripts" "${deploy_dir}/docs" "${deploy_dir}/data/n8n" "${deploy_dir}/data/postgres" \
    "${deploy_dir}/data/anythingllm" "${deploy_dir}/data/analytics" "${deploy_dir}/logs" \
    "${deploy_dir}/backups" "${deploy_dir}/backups/versions" "${deploy_dir}/tmp"
  for directory in config knowledge n8n scripts docs data data/n8n data/postgres data/anythingllm \
    data/analytics logs backups backups/versions tmp; do
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
  handoff_temp=$(mktemp "${handoff_file}.tmp.XXXXXX")
  jq '
    if .handoff.keywords == ["人工", "客服", "真人"] or
       .handoff.keywords == ["人工", "人工客服", "转人工", "真人客服"] then
      .handoff.keywords = ["人工", "人工客服", "转人工", "真人", "真人客服"]
    else . end |
    if (.handoff | has("disable_ai")) then . else .handoff.disable_ai = true end |
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
    del(.handoff.topic_keywords, .handoff.on_operator_message, .handoff.on_low_confidence, .handoff.on_no_answer, .handoff.confirmation)
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

normalize_api_base() {
  local base=$1
  base=${base%/}
  [[ "$base" =~ ^https?://[^/@[:space:]]+(:[0-9]{1,5})?(/[^?#[:space:]]*)?$ ]] || return 1
  [[ "$base" != *".."* ]] || return 1
  if [[ "$base" != */v1 ]]; then
    base="${base}/v1"
  fi
  validate_env_value "$base" || return 1
  printf '%s\n' "$base"
}

probe_api_endpoint() {
  local url=$1
  local api_key=$2
  local payload=$3
  local status
  status=$(curl --silent --output /dev/null --write-out '%{http_code}' \
    --connect-timeout 8 --max-time 30 \
    --header "Authorization: Bearer ${api_key}" \
    --header 'Content-Type: application/json' \
    --data "$payload" "$url" 2>/dev/null || true)
  case "$status" in
    2??|400|409|422|429) return 0 ;;
    *) return 1 ;;
  esac
}

configure_provider() {
  local deploy_dir=$1
  local non_interactive=${2:-0}
  local env_file="${deploy_dir}/.env"
  local base api_key response_file status selected_model choice manual_model
  local responses=false chat=false api_mode inferred_vision=false vision_answer=false
  local default_model=${DEFAULT_AI_MODEL:-gpt-4.1-mini}
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
  status=$(curl --silent --output "$response_file" --write-out '%{http_code}' \
    --connect-timeout 8 --max-time 30 \
    --header "Authorization: Bearer ${api_key}" \
    "${base}/models" 2>/dev/null || true)
  if [[ "$status" == 2?? ]] && jq -e '.data | type == "array"' "$response_file" >/dev/null 2>&1; then
    mapfile -t models < <(jq -r '.data[]?.id | select(type == "string")' "$response_file" | head -n 100)
  fi
  rm -f -- "$response_file"

  if (( ${#models[@]} > 0 )); then
    if (( non_interactive )); then
      selected_model=${AI_MODEL:-${models[0]}}
      if ! printf '%s\n' "${models[@]}" | grep -Fxq -- "$selected_model"; then
        warn "指定模型不在 /v1/models 返回列表中，将继续使用：$selected_model"
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
    else
      printf '1. 手动输入模型名称\n2. 使用默认模型（%s）\n请选择：' "$default_model"
      IFS= read -r choice
      if [[ "$choice" == "1" ]]; then
        printf '请输入模型名称：'
        IFS= read -r manual_model
        selected_model=$manual_model
      else
        selected_model=$default_model
      fi
    fi
  fi
  validate_env_value "$selected_model" || die "模型名称包含不安全字符或为空"

  local responses_payload chat_payload
  responses_payload=$(jq -cn --arg model "$selected_model" '{model:$model,input:"ping",max_output_tokens:1}')
  chat_payload=$(jq -cn --arg model "$selected_model" '{model:$model,messages:[{role:"user",content:"ping"}],max_tokens:1}')
  if probe_api_endpoint "${base}/responses" "$api_key" "$responses_payload"; then responses=true; fi
  if probe_api_endpoint "${base}/chat/completions" "$api_key" "$chat_payload"; then chat=true; fi
  if [[ "$responses" == true ]]; then
    api_mode=responses
  elif [[ "$chat" == true ]]; then
    api_mode=chat_completions
  else
    api_mode=chat_completions
    warn "未确认 Responses 或 Chat Completions 能力；已保存 Chat Completions 作为兼容回退"
  fi
  [[ "$chat" == true ]] || warn "AnythingLLM 的 generic-openai 模式通常需要 /v1/chat/completions"

  if [[ "$selected_model" =~ ([Vv]ision|[Vv][Ll]|[Pp]ixtral|[Gg]emini|[Cc]laude|gpt-4[o.]|gpt-4\.1|gpt-5) ]]; then
    inferred_vision=true
  fi
  if (( non_interactive )); then
    case "${AI_SUPPORTS_VISION:-$inferred_vision}" in
      true|TRUE|1|yes|YES) vision_answer=true ;;
      *) vision_answer=false ;;
    esac
  else
    printf '模型可能支持图片理解：%s。确认启用图片消息？[y/N] ' "$inferred_vision"
    IFS= read -r choice
    case "$choice" in y|Y|yes|YES) vision_answer=true ;; esac
  fi

  env_set "$env_file" AI_API_BASE_URL "$base"
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
    printf '  base_url: "%s"\n' "$base"
    printf '  api_key_env: AI_API_KEY\n'
    printf '  model: "%s"\n' "$selected_model"
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
  info "Provider 已配置：模型 ${selected_model}，模式 ${api_mode}"
}

anythingllm_api_ready() {
  local deploy_dir=$1
  local key
  key=$(env_get "${deploy_dir}/.env" ANYTHINGLLM_API_KEY 2>/dev/null || true)
  ! is_placeholder "$key"
}

sync_prompt_to_anythingllm() {
  local deploy_dir=$1
  local env_file="${deploy_dir}/.env"
  local key workspace port prompt payload response
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
  response=$(curl --silent --output /dev/null --write-out '%{http_code}' \
    --connect-timeout 5 --max-time 30 \
    --header "Authorization: Bearer ${key}" \
    --header 'Content-Type: application/json' \
    --data "$payload" \
    "http://127.0.0.1:${port}/api/v1/workspace/${workspace}/update" 2>/dev/null || true)
  if [[ "$response" != 2?? ]]; then
    warn "同步 Prompt 到 AnythingLLM 失败（HTTP ${response:-000}）"
    return 1
  fi
  info "Prompt 已同步到 AnythingLLM 工作区"
}

import_and_publish_workflow() {
  local deploy_dir=$1
  require_command docker
  if ! docker_compose "$deploy_dir" exec -T n8n n8n import:workflow --input=/opt/crisp-ai/n8n/workflow.json >/dev/null; then
    warn "n8n workflow 导入失败"
    return 1
  fi
  if ! docker_compose "$deploy_dir" exec -T n8n n8n publish:workflow --id="$WORKFLOW_ID" >/dev/null; then
    warn "n8n workflow 发布失败"
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

anythingllm_connection() {
  local deploy_dir=$1
  local env_file="${deploy_dir}/.env"
  ANYTHING_KEY=$(env_get "$env_file" ANYTHINGLLM_API_KEY 2>/dev/null || true)
  ANYTHING_WORKSPACE=$(env_get "$env_file" ANYTHINGLLM_WORKSPACE 2>/dev/null || true)
  ANYTHING_PORT=$(env_get "$env_file" ANYTHINGLLM_PORT 2>/dev/null || printf '3001')
  anythingllm_api_ready "$deploy_dir" || die "AnythingLLM Developer API Key 尚未配置"
  [[ "$ANYTHING_WORKSPACE" =~ ^[A-Za-z0-9_-]{1,128}$ ]] || die "AnythingLLM 工作区 slug 无效"
  [[ "$ANYTHING_PORT" =~ ^[0-9]{1,5}$ ]] || die "AnythingLLM 端口无效"
}

anythingllm_update_embeddings() {
  local payload=$1
  local status
  status=$(curl --silent --output /dev/null --write-out '%{http_code}' \
    --connect-timeout 5 --max-time 120 \
    --header "Authorization: Bearer ${ANYTHING_KEY}" \
    --header 'Content-Type: application/json' \
    --data "$payload" \
    "http://127.0.0.1:${ANYTHING_PORT}/api/v1/workspace/${ANYTHING_WORKSPACE}/update-embeddings" 2>/dev/null || true)
  [[ "$status" == 2?? ]]
}

knowledge_sync() {
  local deploy_dir=$1
  local knowledge_dir="${deploy_dir}/knowledge"
  local manifest="${deploy_dir}/data/knowledge-manifest.json"
  local response_file manifest_temp file filename hash old_hash locations old_locations payload status
  local failures=0 uploaded=0 removed=0 skipped=0
  local -a files=()

  require_command curl
  require_command jq
  require_command sha256sum
  anythingllm_connection "$deploy_dir"
  if [[ ! -f "$manifest" ]]; then
    printf '{"version":1,"files":{}}\n' > "$manifest"
    chmod 600 "$manifest"
  fi
  jq -e '.version == 1 and (.files | type == "object")' "$manifest" >/dev/null || die "知识库清单格式无效：$manifest"

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
    if [[ "$hash" == "$old_hash" ]]; then
      ((skipped += 1))
      continue
    fi

    response_file=$(mktemp "${deploy_dir}/tmp/knowledge-upload.XXXXXX")
    status=$(curl --silent --output "$response_file" --write-out '%{http_code}' \
      --connect-timeout 5 --max-time 300 \
      --header "Authorization: Bearer ${ANYTHING_KEY}" \
      --form "file=@${file}" \
      --form "addToWorkspaces=${ANYTHING_WORKSPACE}" \
      "http://127.0.0.1:${ANYTHING_PORT}/api/v1/document/upload" 2>/dev/null || true)
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
    if [[ "$old_locations" != "[]" ]]; then
      payload=$(jq -cn --argjson deletes "$old_locations" '{adds:[],deletes:$deletes}')
      anythingllm_update_embeddings "$payload" || { warn "旧索引清理失败：$filename"; ((failures += 1)); }
    fi
    manifest_temp=$(mktemp "${manifest}.tmp.XXXXXX")
    jq --arg name "$filename" --arg hash "$hash" --argjson locations "$locations" \
      '.files[$name] = {sha256:$hash, locations:$locations}' "$manifest" > "$manifest_temp"
    chmod 600 "$manifest_temp"
    mv -f -- "$manifest_temp" "$manifest"
    ((uploaded += 1))
  done

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
    manifest_temp=$(mktemp "${manifest}.tmp.XXXXXX")
    jq --arg name "$filename" 'del(.files[$name])' "$manifest" > "$manifest_temp"
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
  local locations delete_payload add_payload

  require_command jq
  anythingllm_connection "$deploy_dir"
  [[ -f "$manifest" ]] || die "尚无知识库同步清单，请先执行同步"
  locations=$(jq -c '[.files[]?.locations[]?] | unique' "$manifest")
  [[ "$locations" != "[]" ]] || die "没有可重新索引的文档"
  delete_payload=$(jq -cn --argjson deletes "$locations" '{adds:[],deletes:$deletes}')
  add_payload=$(jq -cn --argjson adds "$locations" '{adds:$adds,deletes:[]}')
  anythingllm_update_embeddings "$delete_payload" || die "清理旧索引失败"
  anythingllm_update_embeddings "$add_payload" || die "重新建立索引失败"
  info "知识库重新索引完成"
}
