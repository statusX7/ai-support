#!/usr/bin/env bash

# 直接执行时启用严格模式；被安装器 source 时不修改调用者现有 Shell 选项。
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
fi

# 快速初始化向导。此文件可以由 install.sh source，也可以直接执行做入口测试。
# 主接口：quick_init_wizard RESULT_JSON [DEFAULTS_JSON]
# 返回值：0 已确认；2 用户取消、EOF 或中断；其他值为配置/运行错误。

WIZARD_SCHEMA_VERSION=1
WIZARD_PAGE_SIZE=${WIZARD_PAGE_SIZE:-10}

wizard_info() {
  printf '信息：%s\n' "$*"
}

wizard_warn() {
  printf '警告：%s\n' "$*" >&2
}

wizard_error() {
  printf '错误：%s\n' "$*" >&2
}

wizard_require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    wizard_error "快速初始化缺少运行级命令：$1；请先执行依赖引导"
    return 1
  }
}

wizard_validate_plain_value() {
  local value=$1
  local max_length=${2:-4096}
  [[ -n "$value" && ${#value} -le $max_length ]] || return 1
  [[ ! "$value" =~ [[:cntrl:]] ]]
}

wizard_validate_model_id() {
  local value=$1
  (( ${#value} >= 1 && ${#value} <= 256 )) || return 1
  [[ "$value" =~ ^[A-Za-z0-9._~:/@+,=%?\&-]+$ ]]
}

wizard_validate_hostname() {
  local value=${1,,}
  local label
  local -a labels=()

  (( ${#value} >= 1 && ${#value} <= 253 )) || return 1
  [[ "$value" =~ ^[a-z0-9.-]+$ ]] || return 1
  [[ "$value" != .* && "$value" != *. && "$value" != *..* ]] || return 1
  IFS=. read -r -a labels <<< "$value"
  for label in "${labels[@]}"; do
    (( ${#label} >= 1 && ${#label} <= 63 )) || return 1
    [[ "$label" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || return 1
  done
}

wizard_validate_port() {
  local value=$1
  [[ "$value" =~ ^[1-9][0-9]{0,4}$ ]] || return 1
  (( 10#$value <= 65535 ))
}

wizard_parse_http_url() {
  local value=$1
  local require_https=${2:-0}
  local scheme authority host port path

  [[ ! "$value" =~ [[:cntrl:][:space:]] ]] || return 1
  [[ "$value" != *'?'* && "$value" != *'#'* && "$value" != *'@'* ]] || return 1
  [[ "$value" =~ ^(https?)://([^/]+)(/.*)?$ ]] || return 1
  scheme=${BASH_REMATCH[1]}
  authority=${BASH_REMATCH[2]}
  path=${BASH_REMATCH[3]:-}
  (( require_https == 0 )) || [[ "$scheme" == https ]] || return 1

  if [[ "$authority" == *:* ]]; then
    host=${authority%:*}
    port=${authority##*:}
    [[ "$host" != "$authority" ]] || return 1
    wizard_validate_port "$port" || return 1
  else
    host=$authority
  fi
  wizard_validate_hostname "$host" || return 1
  [[ "$path" != *'/../'* && "$path" != */.. && "$path" != *'/./'* && "$path" != */. ]] || return 1

  WIZARD_URL_HOST=${host,,}
  WIZARD_URL_PATH=$path
}

wizard_normalize_api_base() {
  local value=$1

  while [[ "$value" == */ ]]; do value=${value%/}; done
  wizard_parse_http_url "$value" 0 || return 1
  if [[ "$value" == http://* && "$WIZARD_URL_HOST" != localhost \
    && "$WIZARD_URL_HOST" != 127.* ]]; then
    return 1
  fi
  if [[ "$value" != */v1 ]]; then
    value="${value}/v1"
  fi
  (( ${#value} <= 2048 )) || return 1
  printf '%s\n' "$value"
}

wizard_parse_webhook_input() {
  local value=$1
  local endpoint_suffix='/webhook/crisp-webhook'
  local base

  while [[ "$value" == */ ]]; do value=${value%/}; done
  if [[ "$value" == https://* ]]; then
    wizard_parse_http_url "$value" 1 || return 1
    if [[ -z "$WIZARD_URL_PATH" ]]; then
      WIZARD_WEBHOOK_MODE=domain
      WIZARD_WEBHOOK_BASE_URL="${value}/"
      WIZARD_WEBHOOK_PRODUCTION_URL="${value}${endpoint_suffix}"
    else
      [[ "$WIZARD_URL_PATH" == *"$endpoint_suffix" ]] || return 1
      [[ "$WIZARD_URL_PATH" != *"${endpoint_suffix}/"* ]] || return 1
      base=${value%"$endpoint_suffix"}
      WIZARD_WEBHOOK_MODE=existing_url
      WIZARD_WEBHOOK_BASE_URL="${base}/"
      WIZARD_WEBHOOK_PRODUCTION_URL=$value
    fi
  else
    wizard_validate_hostname "$value" || return 1
    WIZARD_WEBHOOK_MODE=domain
    WIZARD_WEBHOOK_BASE_URL="https://${value}/"
    WIZARD_WEBHOOK_PRODUCTION_URL="https://${value}${endpoint_suffix}"
  fi
  WIZARD_WEBHOOK_INPUT=$value
}

wizard_https_ports_in_use() {
  local line local_address

  command -v ss >/dev/null 2>&1 || return 1
  while IFS= read -r line; do
    # ss -H -ltn 的第 4 列是 Local Address:Port；这里只读，不停止或修改现有服务。
    read -r _ _ _ local_address _ <<< "$line"
    case "$local_address" in
      *:80|*:443) return 0 ;;
    esac
  done < <(ss -H -ltn 2>/dev/null || true)
  return 1
}

wizard_read_value() {
  local target=$1
  local prompt=$2
  local hidden=${3:-0}
  local _wizard_value

  printf '%s' "$prompt"
  if (( hidden )); then
    if ! IFS= read -r -s _wizard_value; then
      printf '\n' >&2
      wizard_warn '输入已结束；已完成步骤保存在受限状态文件中，可重新运行继续'
      return 2
    fi
    printf '\n'
  elif ! IFS= read -r _wizard_value; then
    wizard_warn '输入已结束；已完成步骤保存在受限状态文件中，可重新运行继续'
    return 2
  fi
  printf -v "$target" '%s' "$_wizard_value"
}

wizard_init_values() {
  WIZARD_CREATED_AT=''
  WIZARD_STATUS=collecting
  WIZARD_NEXT_STEP=1
  WIZARD_BASE_URL=''
  WIZARD_API_KEY=''
  WIZARD_MODEL=''
  WIZARD_MODEL_DISCOVERY=unknown
  WIZARD_MODELS_HTTP_STATUS=000
  WIZARD_API_MODE=chat_completions
  WIZARD_CHAT_CAPABILITY=false
  WIZARD_RESPONSES_CAPABILITY=false
  WIZARD_VISION_CAPABILITY=false
  WIZARD_PROVIDER_LOOPBACK=false
  WIZARD_CRISP_WEBSITE_ID=''
  WIZARD_CRISP_IDENTIFIER=''
  WIZARD_CRISP_TOKEN_KEY=''
  WIZARD_WEBHOOK_INPUT=''
  WIZARD_WEBHOOK_MODE=''
  WIZARD_WEBHOOK_BASE_URL=''
  WIZARD_WEBHOOK_PRODUCTION_URL=''
  WIZARD_PROMPT_MODE=default
  WIZARD_PROMPT_SOURCE=''
  WIZARD_PROMPT_CONTENT=''
  WIZARD_KNOWLEDGE_MODE=empty
  WIZARD_KNOWLEDGE_SOURCE=''
  WIZARD_KNOWLEDGE_FILES=0
  WIZARD_KNOWLEDGE_LIBRARIES='[]'
}

wizard_load_state() {
  local state_file=$1
  local state_mode

  [[ -f "$state_file" && ! -L "$state_file" ]] || {
    wizard_error "向导状态不是安全普通文件：$state_file"
    return 1
  }
  state_mode=$(stat -c '%a' "$state_file" 2>/dev/null || true)
  [[ "$state_mode" == 600 ]] || {
    wizard_error "向导状态权限必须为 0600：$state_file"
    return 1
  }
  jq -e '
    .schema_version == 1 and
    (.status == "collecting" or .status == "confirmed") and
    (.next_step | type == "number" and . >= 1 and . <= 10 and floor == .) and
    (.provider | type == "object") and
    (.crisp | type == "object") and
    (.webhook | type == "object") and
    (.prompt | type == "object") and
    (.knowledge | type == "object")
  ' "$state_file" >/dev/null 2>&1 || {
    wizard_error "向导状态格式无效：$state_file"
    return 1
  }

  WIZARD_CREATED_AT=$(jq -r '.created_at // ""' "$state_file")
  WIZARD_STATUS=$(jq -r '.status' "$state_file")
  WIZARD_NEXT_STEP=$(jq -r '.next_step' "$state_file")
  WIZARD_BASE_URL=$(jq -r '.provider.base_url // ""' "$state_file")
  WIZARD_API_KEY=$(jq -r '.provider.api_key // ""' "$state_file")
  WIZARD_MODEL=$(jq -r '.provider.model // ""' "$state_file")
  WIZARD_MODEL_DISCOVERY=$(jq -r '.provider.model_discovery // "unknown"' "$state_file")
  WIZARD_MODELS_HTTP_STATUS=$(jq -r '.provider.models_http_status // "000"' "$state_file")
  WIZARD_API_MODE=$(jq -r '.provider.api_mode // "chat_completions"' "$state_file")
  WIZARD_CHAT_CAPABILITY=$(jq -r '.provider.capabilities.chat_completions // false' "$state_file")
  WIZARD_RESPONSES_CAPABILITY=$(jq -r '.provider.capabilities.responses // false' "$state_file")
  WIZARD_VISION_CAPABILITY=$(jq -r '.provider.capabilities.vision // false' "$state_file")
  WIZARD_PROVIDER_LOOPBACK=$(jq -r '.provider.loopback // false' "$state_file")
  WIZARD_CRISP_WEBSITE_ID=$(jq -r '.crisp.website_id // ""' "$state_file")
  WIZARD_CRISP_IDENTIFIER=$(jq -r '.crisp.token_identifier // ""' "$state_file")
  WIZARD_CRISP_TOKEN_KEY=$(jq -r '.crisp.token_key // ""' "$state_file")
  WIZARD_WEBHOOK_INPUT=$(jq -r '.webhook.input // ""' "$state_file")
  WIZARD_WEBHOOK_MODE=$(jq -r '.webhook.mode // ""' "$state_file")
  WIZARD_WEBHOOK_BASE_URL=$(jq -r '.webhook.public_base_url // ""' "$state_file")
  WIZARD_WEBHOOK_PRODUCTION_URL=$(jq -r '.webhook.production_url // ""' "$state_file")
  WIZARD_PROMPT_MODE=$(jq -r '.prompt.mode // "default"' "$state_file")
  WIZARD_PROMPT_SOURCE=$(jq -r '.prompt.source // ""' "$state_file")
  WIZARD_PROMPT_CONTENT=$(jq -j '.prompt.content // ""' "$state_file"; printf '.')
  WIZARD_PROMPT_CONTENT=${WIZARD_PROMPT_CONTENT%.}
  WIZARD_KNOWLEDGE_MODE=$(jq -r '.knowledge.mode // "empty"' "$state_file")
  WIZARD_KNOWLEDGE_SOURCE=$(jq -r '.knowledge.source // ""' "$state_file")
  WIZARD_KNOWLEDGE_FILES=$(jq -r '.knowledge.supported_files // 0' "$state_file")
  WIZARD_KNOWLEDGE_LIBRARIES=$(jq -c '.knowledge.libraries // []' "$state_file")
}

wizard_write_value_file() {
  local directory=$1
  local name=$2
  local value=$3
  printf '%s' "$value" > "${directory}/${name}"
  chmod 600 "${directory}/${name}"
}

wizard_write_state() {
  local output_file=$1
  local status=$2
  local next_step=$3
  local output_dir temp_dir temp_file name
  local -a value_names=(
    created_at base_url api_key model model_discovery models_http_status api_mode
    website_id token_identifier token_key webhook_input webhook_mode webhook_base webhook_url
    prompt_mode prompt_source prompt_content knowledge_mode knowledge_source knowledge_libraries
  )
  local -a value_values=(
    "$WIZARD_CREATED_AT" "$WIZARD_BASE_URL" "$WIZARD_API_KEY" "$WIZARD_MODEL"
    "$WIZARD_MODEL_DISCOVERY" "$WIZARD_MODELS_HTTP_STATUS" "$WIZARD_API_MODE"
    "$WIZARD_CRISP_WEBSITE_ID" "$WIZARD_CRISP_IDENTIFIER" "$WIZARD_CRISP_TOKEN_KEY"
    "$WIZARD_WEBHOOK_INPUT" "$WIZARD_WEBHOOK_MODE" "$WIZARD_WEBHOOK_BASE_URL"
    "$WIZARD_WEBHOOK_PRODUCTION_URL" "$WIZARD_PROMPT_MODE" "$WIZARD_PROMPT_SOURCE"
    "$WIZARD_PROMPT_CONTENT" "$WIZARD_KNOWLEDGE_MODE" "$WIZARD_KNOWLEDGE_SOURCE" "$WIZARD_KNOWLEDGE_LIBRARIES"
  )

  [[ "$status" == collecting || "$status" == confirmed ]] || return 1
  [[ "$next_step" =~ ^([1-9]|10)$ ]] || return 1
  [[ ! -e "$output_file" || -f "$output_file" ]] || {
    wizard_error "向导状态目标必须是普通文件：$output_file"
    return 1
  }
  [[ ! -L "$output_file" ]] || {
    wizard_error "拒绝写入符号链接向导状态：$output_file"
    return 1
  }
  output_dir=$(dirname -- "$output_file")
  mkdir -p -- "$output_dir"
  [[ -d "$output_dir" && ! -L "$output_dir" ]] || {
    wizard_error "向导状态目录不安全：$output_dir"
    return 1
  }
  temp_dir=$(mktemp -d "${output_dir}/.wizard-values.XXXXXX") || return 1
  chmod 700 "$temp_dir"
  for name in "${!value_names[@]}"; do
    wizard_write_value_file "$temp_dir" "${value_names[name]}" "${value_values[name]}"
  done
  temp_file=$(mktemp "${output_file}.tmp.XXXXXX") || {
    rm -rf -- "$temp_dir"
    return 1
  }
  chmod 600 "$temp_file"
  if ! jq -n \
    --argjson schema "$WIZARD_SCHEMA_VERSION" \
    --arg status "$status" \
    --argjson next_step "$next_step" \
    --rawfile created_at "${temp_dir}/created_at" \
    --rawfile base_url "${temp_dir}/base_url" \
    --rawfile api_key "${temp_dir}/api_key" \
    --rawfile model "${temp_dir}/model" \
    --rawfile discovery "${temp_dir}/model_discovery" \
    --rawfile models_status "${temp_dir}/models_http_status" \
    --rawfile api_mode "${temp_dir}/api_mode" \
    --argjson chat "$WIZARD_CHAT_CAPABILITY" \
    --argjson responses "$WIZARD_RESPONSES_CAPABILITY" \
    --argjson vision "$WIZARD_VISION_CAPABILITY" \
    --argjson loopback "$WIZARD_PROVIDER_LOOPBACK" \
    --rawfile website "${temp_dir}/website_id" \
    --rawfile identifier "${temp_dir}/token_identifier" \
    --rawfile token_key "${temp_dir}/token_key" \
    --rawfile webhook_input "${temp_dir}/webhook_input" \
    --rawfile webhook_mode "${temp_dir}/webhook_mode" \
    --rawfile webhook_base "${temp_dir}/webhook_base" \
    --rawfile webhook_url "${temp_dir}/webhook_url" \
    --rawfile prompt_mode "${temp_dir}/prompt_mode" \
    --rawfile prompt_source "${temp_dir}/prompt_source" \
    --rawfile prompt_content "${temp_dir}/prompt_content" \
    --rawfile knowledge_mode "${temp_dir}/knowledge_mode" \
    --rawfile knowledge_source "${temp_dir}/knowledge_source" \
    --slurpfile knowledge_libraries "${temp_dir}/knowledge_libraries" \
    --argjson knowledge_files "$WIZARD_KNOWLEDGE_FILES" '
      {
        schema_version: $schema,
        status: $status,
        next_step: $next_step,
        created_at: $created_at,
        provider: {
          type: "openai-compatible",
          base_url: $base_url,
          api_key: $api_key,
          model: $model,
          model_discovery: $discovery,
          models_http_status: $models_status,
          api_mode: $api_mode,
          capabilities: {
            chat_completions: $chat,
            responses: $responses,
            vision: $vision
          },
          loopback: $loopback
        },
        crisp: {
          website_id: $website,
          token_tier: "website",
          hook_mode: "website",
          token_identifier: $identifier,
          token_key: $token_key
        },
        webhook: {
          input: $webhook_input,
          mode: $webhook_mode,
          public_base_url: $webhook_base,
          production_url: $webhook_url
        },
        prompt: {
          mode: $prompt_mode,
          source: $prompt_source,
          content: $prompt_content
        },
        knowledge: {
          mode: $knowledge_mode,
          source: $knowledge_source,
          libraries: $knowledge_libraries[0],
          supported_files: $knowledge_files
        }
      }
    ' > "$temp_file"; then
    rm -f -- "$temp_file"
    rm -rf -- "$temp_dir"
    wizard_error '无法序列化向导状态'
    return 1
  fi
  mv -f -- "$temp_file" "$output_file"
  chmod 600 "$output_file"
  rm -rf -- "$temp_dir"
  WIZARD_STATUS=$status
  WIZARD_NEXT_STEP=$next_step
}

wizard_curl_escape() {
  local value=$1
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  printf '%s' "$value"
}

wizard_provider_request() {
  local method=$1
  local url=$2
  local api_key=$3
  local payload=$4
  local response_file=$5
  local temp_dir config_file payload_file escaped_key status

  temp_dir=$(dirname -- "$response_file")
  config_file=$(mktemp "${temp_dir}/provider-curl.XXXXXX") || return 1
  payload_file=$(mktemp "${temp_dir}/provider-payload.XXXXXX") || {
    rm -f -- "$config_file"
    return 1
  }
  chmod 600 "$config_file" "$payload_file" "$response_file"
  escaped_key=$(wizard_curl_escape "$api_key")
  printf 'header = "Authorization: Bearer %s"\nheader = "Content-Type: application/json"\n' \
    "$escaped_key" > "$config_file"
  printf '%s' "$payload" > "$payload_file"

  if [[ "$method" == GET ]]; then
    status=$(curl --silent --show-error --output "$response_file" --write-out '%{http_code}' \
      --connect-timeout 8 --max-time 30 --retry 2 --retry-delay 1 --retry-max-time 25 \
      --proto '=http,https' --max-redirs 0 --config "$config_file" --request GET "$url" \
      2>/dev/null || true)
  else
    status=$(curl --silent --show-error --output "$response_file" --write-out '%{http_code}' \
      --connect-timeout 8 --max-time 45 --retry 2 --retry-delay 1 --retry-max-time 30 \
      --proto '=http,https' --max-redirs 0 --config "$config_file" --request POST \
      --data-binary "@${payload_file}" "$url" 2>/dev/null || true)
  fi
  rm -f -- "$config_file" "$payload_file"
  WIZARD_LAST_HTTP_STATUS=${status:-000}
}

wizard_fetch_models() {
  local work_dir=$1
  local response_file status model

  WIZARD_MODELS=()
  response_file=$(mktemp "${work_dir}/wizard-models.XXXXXX") || return 1
  chmod 600 "$response_file"
  wizard_provider_request GET "${WIZARD_BASE_URL}/models" "$WIZARD_API_KEY" '' \
    "$response_file" || {
      rm -f -- "$response_file"
      return 1
    }
  status=$WIZARD_LAST_HTTP_STATUS
  WIZARD_MODELS_HTTP_STATUS=$status
  if [[ "$status" == 2?? ]] && jq -e '.data | type == "array"' "$response_file" >/dev/null 2>&1; then
    while IFS= read -r model; do
      wizard_validate_model_id "$model" && WIZARD_MODELS+=("$model")
    done < <(jq -r '[.data[]?.id | select(type == "string")] | unique | .[]' "$response_file")
  fi
  rm -f -- "$response_file"
}

wizard_render_models() {
  local query=${1,,}
  local page=$2
  local start end model index shown=0

  WIZARD_VISIBLE_MODEL_INDEXES=()
  for index in "${!WIZARD_MODELS[@]}"; do
    model=${WIZARD_MODELS[index]}
    [[ -z "$query" || "${model,,}" == *"$query"* ]] || continue
    WIZARD_VISIBLE_MODEL_INDEXES+=("$index")
  done
  (( ${#WIZARD_VISIBLE_MODEL_INDEXES[@]} > 0 )) || return 1
  start=$((page * WIZARD_PAGE_SIZE))
  (( start < ${#WIZARD_VISIBLE_MODEL_INDEXES[@]} )) || return 1
  end=$((start + WIZARD_PAGE_SIZE))
  (( end <= ${#WIZARD_VISIBLE_MODEL_INDEXES[@]} )) || end=${#WIZARD_VISIBLE_MODEL_INDEXES[@]}
  printf '检测到模型（第 %d 页）：\n' "$((page + 1))"
  for (( index = start; index < end; index++ )); do
    shown=${WIZARD_VISIBLE_MODEL_INDEXES[index]}
    printf '%d. %s\n' "$((shown + 1))" "${WIZARD_MODELS[shown]}"
  done
  WIZARD_PAGE_START=$start
  WIZARD_PAGE_END=$end
}

wizard_model_index_visible() {
  local wanted=$1
  local position actual
  for (( position = WIZARD_PAGE_START; position < WIZARD_PAGE_END; position++ )); do
    actual=${WIZARD_VISIBLE_MODEL_INDEXES[position]}
    (( actual + 1 == wanted )) && return 0
  done
  return 1
}

wizard_select_model_from_list() {
  local choice query='' page=0 index

  while true; do
    if ! wizard_render_models "$query" "$page"; then
      wizard_warn '没有匹配的模型；已恢复完整列表'
      query=''
      page=0
      wizard_render_models "$query" "$page"
    fi
    wizard_read_value choice \
      '[3/10] 选择模型（数字；n 下一页，p 上一页，/关键词搜索，m 手动输入）：' \
      || return $?
    case "$choice" in
      n|N)
        if (( WIZARD_PAGE_END < ${#WIZARD_VISIBLE_MODEL_INDEXES[@]} )); then
          ((page += 1))
        else
          wizard_warn '已经是最后一页'
        fi
        ;;
      p|P)
        if (( page > 0 )); then ((page -= 1)); else wizard_warn '已经是第一页'; fi
        ;;
      /*)
        query=${choice#/}
        page=0
        ;;
      m|M)
        wizard_read_value WIZARD_MODEL '请输入模型名称：' || return $?
        wizard_validate_model_id "$WIZARD_MODEL" || {
          wizard_warn '模型名称为空或含不安全字符'
          WIZARD_MODEL=''
          continue
        }
        WIZARD_MODEL_DISCOVERY=manual
        return 0
        ;;
      '')
        if [[ -n "$WIZARD_MODEL" ]]; then
          for index in "${!WIZARD_MODELS[@]}"; do
            if [[ "${WIZARD_MODELS[index]}" == "$WIZARD_MODEL" ]]; then
              WIZARD_MODEL_DISCOVERY=models_api
              return 0
            fi
          done
        fi
        wizard_warn '请输入模型序号'
        ;;
      *)
        if [[ "$choice" =~ ^[1-9][0-9]*$ ]] \
          && (( choice <= ${#WIZARD_MODELS[@]} )) \
          && wizard_model_index_visible "$choice"; then
          WIZARD_MODEL=${WIZARD_MODELS[choice - 1]}
          WIZARD_MODEL_DISCOVERY=models_api
          return 0
        fi
        wizard_warn '请输入当前页面显示的有效序号'
        ;;
    esac
  done
}

wizard_select_model_manually() {
  while true; do
    wizard_read_value WIZARD_MODEL \
      '[3/10] 模型列表不可用，请手动输入模型名称：' || return $?
    if wizard_validate_model_id "$WIZARD_MODEL"; then
      WIZARD_MODEL_DISCOVERY=manual
      return 0
    fi
    wizard_warn '模型名称为空或含不安全字符'
  done
}

wizard_probe_json_endpoint() {
  local work_dir=$1
  local endpoint=$2
  local payload=$3
  local jq_filter=$4
  local response_file status

  response_file=$(mktemp "${work_dir}/wizard-probe.XXXXXX") || return 1
  chmod 600 "$response_file"
  wizard_provider_request POST "${WIZARD_BASE_URL}/${endpoint}" "$WIZARD_API_KEY" "$payload" \
    "$response_file" || {
      rm -f -- "$response_file"
      return 1
    }
  status=$WIZARD_LAST_HTTP_STATUS
  if [[ "$status" == 2?? ]] && jq -e "$jq_filter" "$response_file" >/dev/null 2>&1; then
    rm -f -- "$response_file"
    return 0
  fi
  rm -f -- "$response_file"
  return 1
}

wizard_probe_selected_model() {
  local work_dir=$1
  local chat_payload responses_payload vision_payload tiny_image

  chat_payload=$(jq -cn --arg model "$WIZARD_MODEL" \
    '{model:$model,messages:[{role:"user",content:"Reply only OK."}],max_tokens:16}')
  if wizard_probe_json_endpoint "$work_dir" chat/completions "$chat_payload" \
    '((has("error") | not) or .error == null or .error == false) and (.choices[0].message.content | type == "string" and length > 0)'; then
    WIZARD_CHAT_CAPABILITY=true
  else
    WIZARD_CHAT_CAPABILITY=false
  fi

  responses_payload=$(jq -cn --arg model "$WIZARD_MODEL" \
    '{model:$model,input:"Reply only OK.",max_output_tokens:16}')
  if wizard_probe_json_endpoint "$work_dir" responses "$responses_payload" \
    '((has("error") | not) or .error == null or .error == false) and (((.output_text // "") | length > 0) or any(.output[]?.content[]?; .type=="output_text" and (.text | type=="string" and length>0)))'; then
    WIZARD_RESPONSES_CAPABILITY=true
    WIZARD_API_MODE=responses
  else
    WIZARD_RESPONSES_CAPABILITY=false
    WIZARD_API_MODE=chat_completions
  fi
  [[ "$WIZARD_CHAT_CAPABILITY" == true || "$WIZARD_RESPONSES_CAPABILITY" == true ]] || return 1

  tiny_image='data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII='
  if [[ "$WIZARD_API_MODE" == responses ]]; then
    vision_payload=$(jq -cn --arg model "$WIZARD_MODEL" --arg image "$tiny_image" \
      '{model:$model,input:[{role:"user",content:[{type:"input_text",text:"Reply only OK."},{type:"input_image",image_url:$image}]}],max_output_tokens:16}')
    if wizard_probe_json_endpoint "$work_dir" responses "$vision_payload" \
      '((has("error") | not) or .error == null or .error == false) and (((.output_text // "") | length > 0) or any(.output[]?.content[]?; .type=="output_text" and (.text | type=="string" and length>0)))'; then
      WIZARD_VISION_CAPABILITY=true
    else WIZARD_VISION_CAPABILITY=false; fi
  else
    vision_payload=$(jq -cn --arg model "$WIZARD_MODEL" --arg image "$tiny_image" \
      '{model:$model,messages:[{role:"user",content:[{type:"text",text:"Reply only OK."},{type:"image_url",image_url:{url:$image}}]}],max_tokens:16}')
    if wizard_probe_json_endpoint "$work_dir" chat/completions "$vision_payload" \
      '((has("error") | not) or .error == null or .error == false) and (.choices[0].message.content | type == "string" and length > 0)'; then
      WIZARD_VISION_CAPABILITY=true
    else WIZARD_VISION_CAPABILITY=false; fi
  fi
}

wizard_validate_prompt_bytes() {
  python3 -c '
import sys
maximum = int(sys.argv[1])
raw = sys.stdin.buffer.read(maximum + 1)
if not 0 < len(raw) <= maximum:
    raise SystemExit(1)
try:
    text = raw.decode("utf-8", "strict")
except UnicodeDecodeError:
    raise SystemExit(1)
if "\x00" in text or not text.strip():
    raise SystemExit(1)
' "${1:-262144}"
}

wizard_read_multiline() {
  local target=$1 max_length=${2:-262144} line collected=''
  local LC_ALL=C
  printf '请粘贴多行正文。单独一行 ::END:: 保存，::CANCEL:: 取消。\n'
  printf '正文需要结束符字面量时，在前面加反斜线，例如 \\::END::。\n'
  while true; do
    if ! IFS= read -r line; then wizard_warn '输入结束，当前正文未保存，可重跑此步骤'; return 2; fi
    case "$line" in ::END::) break ;; ::CANCEL::) return 3 ;; '\::END::'|'\::CANCEL::') line=${line:1} ;; esac
    collected+="$line"$'\n'
    (( ${#collected} <= max_length )) || { wizard_warn '正文超过本步骤输入上限'; return 3; }
  done
  printf '%s' "$collected" | wizard_validate_prompt_bytes "$max_length" \
    || { wizard_warn '正文须为有效 UTF-8，不能为空、全空白或包含 NUL'; return 3; }
  printf -v "$target" '%s' "$collected"
}

wizard_provider_is_loopback() {
  wizard_parse_http_url "$WIZARD_BASE_URL" 0 || return 1
  [[ "$WIZARD_URL_HOST" == localhost || "$WIZARD_URL_HOST" == 127.* ]]
}

wizard_knowledge_inspect() {
  local module_dir
  module_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" || return 1
  bash "$module_dir/knowledge.sh" inspect-source "$1"
}

wizard_knowledge_name_valid() {
  local module_dir
  module_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" || return 1
  bash "$module_dir/knowledge.sh" validate-library-name "$1" >/dev/null
}

wizard_collect_step() {
  local step=$1
  local output_file=$2
  local work_dir=$3
  local value normalized resolved count auth_attempt multiline_status library_name library_path library_temp knowledge_summary

  case "$step" in
    1)
      while true; do
        if [[ -n "$WIZARD_BASE_URL" ]]; then
          wizard_read_value value "[1/10] AI API 地址 [${WIZARD_BASE_URL}]：" || return $?
          value=${value:-$WIZARD_BASE_URL}
        else
          wizard_read_value value '[1/10] AI API 地址：' || return $?
        fi
        normalized=$(wizard_normalize_api_base "$value" 2>/dev/null || true)
        if [[ -n "$normalized" ]]; then
          WIZARD_BASE_URL=$normalized
          if wizard_provider_is_loopback; then WIZARD_PROVIDER_LOOPBACK=true; else WIZARD_PROVIDER_LOOPBACK=false; fi
          WIZARD_MODEL=''
          WIZARD_NEXT_STEP=2
          wizard_write_state "$output_file" collecting 2
          return 0
        fi
        wizard_warn 'API 地址无效；请输入不含账号、查询参数或路径穿越的 HTTP(S) Base URL'
      done
      ;;
    2)
      while true; do
        if [[ -n "$WIZARD_API_KEY" ]]; then
          wizard_read_value value '[2/10] AI API Key（回车保留现有值，输入不显示）：' 1 || return $?
          value=${value:-$WIZARD_API_KEY}
        else
          wizard_read_value value '[2/10] AI API Key（输入不显示）：' 1 || return $?
        fi
        if wizard_validate_plain_value "$value" 4096; then
          WIZARD_API_KEY=$value
          WIZARD_MODEL=''
          WIZARD_NEXT_STEP=3
          wizard_write_state "$output_file" collecting 3
          return 0
        fi
        wizard_warn 'API Key 不能为空、不能含控制字符且不得超过 4096 字符'
      done
      ;;
    3)
      auth_attempt=0
      while true; do
        wizard_fetch_models "$work_dir"
        if [[ "$WIZARD_MODELS_HTTP_STATUS" == 401 || "$WIZARD_MODELS_HTTP_STATUS" == 403 ]]; then
          ((auth_attempt += 1))
          if (( auth_attempt >= 3 )); then
            wizard_error 'Provider 连续拒绝 API Key，已保留当前步骤供纠正后重试'
            return 1
          fi
          wizard_warn "Provider 鉴权失败（HTTP ${WIZARD_MODELS_HTTP_STATUS}）"
          wizard_read_value value '请重新输入 AI API Key（输入不显示）：' 1 || return $?
          wizard_validate_plain_value "$value" 4096 || {
            wizard_warn 'API Key 无效'
            continue
          }
          WIZARD_API_KEY=$value
          wizard_write_state "$output_file" collecting 3
          continue
        fi
        break
      done
      if (( ${#WIZARD_MODELS[@]} > 0 )); then
        wizard_select_model_from_list || return $?
      else
        wizard_warn "模型列表请求未成功（HTTP ${WIZARD_MODELS_HTTP_STATUS}）；不会编造默认模型"
        wizard_select_model_manually || return $?
      fi
      if ! wizard_probe_selected_model "$work_dir"; then
        wizard_error '所选模型的 Chat Completions 与 Responses 请求均未取得有效回答；请修正模型或凭据'
        WIZARD_MODEL=''
        wizard_write_state "$output_file" collecting 3
        return 1
      fi
      WIZARD_NEXT_STEP=4
      wizard_write_state "$output_file" collecting 4
      ;;
    4)
      while true; do
        if [[ -n "$WIZARD_CRISP_WEBSITE_ID" ]]; then
          wizard_read_value value "[4/10] Crisp Website ID [${WIZARD_CRISP_WEBSITE_ID}]：" || return $?
          value=${value:-$WIZARD_CRISP_WEBSITE_ID}
        else
          wizard_read_value value '[4/10] Crisp Website ID：' || return $?
        fi
        if [[ "$value" =~ ^[A-Za-z0-9-]{8,128}$ ]]; then
          WIZARD_CRISP_WEBSITE_ID=$value
          wizard_write_state "$output_file" collecting 5
          return 0
        fi
        wizard_warn 'Crisp Website ID 格式无效'
      done
      ;;
    5)
      while true; do
        if [[ -n "$WIZARD_CRISP_IDENTIFIER" ]]; then
          wizard_read_value value '[5/10] Crisp Token Identifier（回车保留现有值，输入不显示）：' 1 || return $?
          value=${value:-$WIZARD_CRISP_IDENTIFIER}
        else
          wizard_read_value value '[5/10] Crisp Token Identifier（输入不显示）：' 1 || return $?
        fi
        if wizard_validate_plain_value "$value" 512 && [[ "$value" != *:* ]]; then
          WIZARD_CRISP_IDENTIFIER=$value
          wizard_write_state "$output_file" collecting 6
          return 0
        fi
        wizard_warn 'Token Identifier 不能为空、不能含冒号或控制字符'
      done
      ;;
    6)
      while true; do
        if [[ -n "$WIZARD_CRISP_TOKEN_KEY" ]]; then
          wizard_read_value value '[6/10] Crisp Token Key（回车保留现有值，输入不显示）：' 1 || return $?
          value=${value:-$WIZARD_CRISP_TOKEN_KEY}
        else
          wizard_read_value value '[6/10] Crisp Token Key（输入不显示）：' 1 || return $?
        fi
        if wizard_validate_plain_value "$value" 4096; then
          WIZARD_CRISP_TOKEN_KEY=$value
          wizard_write_state "$output_file" collecting 7
          return 0
        fi
        wizard_warn 'Token Key 不能为空、不能含控制字符且不得超过 4096 字符'
      done
      ;;
    7)
      while true; do
        if [[ -n "$WIZARD_WEBHOOK_INPUT" ]]; then
          wizard_read_value value "[7/10] 公网域名或现有 HTTPS Webhook 地址 [${WIZARD_WEBHOOK_INPUT}]：" || return $?
          value=${value:-$WIZARD_WEBHOOK_INPUT}
        else
          wizard_read_value value '[7/10] 公网域名或现有 HTTPS Webhook 地址：' || return $?
        fi
        if wizard_parse_webhook_input "$value"; then
          if [[ "$WIZARD_WEBHOOK_MODE" == domain \
            && "${WIZARD_HTTPS_PORTS_MANAGED:-0}" != 1 ]] \
            && wizard_https_ports_in_use; then
            wizard_warn '检测到本机 TCP 80 或 443 已被占用；不会停止或覆盖现有网站'
            wizard_warn '请改填现有反向代理最终转发到本项目的完整 HTTPS 生产 Webhook 地址'
            continue
          fi
          wizard_write_state "$output_file" collecting 8
          return 0
        fi
        wizard_warn '请输入域名，或以 /webhook/crisp-webhook 结尾且不含查询参数的 HTTPS 地址'
      done
      ;;
    8)
      while true; do
        wizard_read_value value \
          '[8/10] 客服提示词（回车使用安全默认；文件路径、单行内容或 ::PASTE:: 多行粘贴）：' || return $?
        if [[ -z "$value" ]]; then
          WIZARD_PROMPT_MODE=default
          WIZARD_PROMPT_SOURCE=''
          WIZARD_PROMPT_CONTENT=''
          break
        elif [[ "$value" == ::PASTE:: ]]; then
          if wizard_read_multiline WIZARD_PROMPT_CONTENT; then
            WIZARD_PROMPT_MODE=inline
            WIZARD_PROMPT_SOURCE=''
            break
          else
            multiline_status=$?
            (( multiline_status != 2 )) || return 2
            continue
          fi
        elif [[ -e "$value" || -L "$value" ]]; then
          [[ -f "$value" && ! -L "$value" && -r "$value" ]] || {
            wizard_warn 'Prompt 路径必须是可读普通文件且不能是符号链接'
            continue
          }
          if ! wizard_validate_prompt_bytes < "$value"; then
            wizard_warn 'Prompt 文件须为 1～262144 个 UTF-8 字节，不能全空白或包含 NUL'
            continue
          fi
          resolved=$(realpath -e -- "$value") || {
            wizard_warn '无法解析 Prompt 文件路径'
            continue
          }
          if [[ "$value" =~ [[:cntrl:]] || "$resolved" != "$(realpath -ms -- "$value")" ]]; then
            wizard_warn 'Prompt 来源及其父目录不能含控制字符或经符号链接跳转'
            continue
          fi
          WIZARD_PROMPT_MODE='file'
          WIZARD_PROMPT_SOURCE=$resolved
          WIZARD_PROMPT_CONTENT=''
          break
        elif printf '%s' "$value" | wizard_validate_prompt_bytes; then
          WIZARD_PROMPT_MODE=inline
          WIZARD_PROMPT_SOURCE=''
          WIZARD_PROMPT_CONTENT=$value
          break
        else
          wizard_warn 'Prompt 内容须为 1～262144 个 UTF-8 字节，不能全空白或包含 NUL'
        fi
      done
      wizard_write_state "$output_file" collecting 9
      ;;
    9)
      while true; do
        wizard_read_value value '[9/10] 知识库文件或目录（回车跳过，::PASTE:: 粘贴，::LIBRARIES:: 多库）：' || return $?
        if [[ -z "$value" ]]; then
          WIZARD_KNOWLEDGE_MODE=empty
          WIZARD_KNOWLEDGE_SOURCE=''
          WIZARD_KNOWLEDGE_FILES=0
          WIZARD_KNOWLEDGE_LIBRARIES='[]'
          wizard_info '尚未配置业务知识；安装后 AI 不应编造业务规则'
          break
        fi
        if [[ "$value" == ::PASTE:: || "$value" == ::LIBRARIES:: ]]; then
          WIZARD_KNOWLEDGE_LIBRARIES='[]'
          WIZARD_KNOWLEDGE_MODE=libraries
          WIZARD_KNOWLEDGE_SOURCE=''
          WIZARD_KNOWLEDGE_FILES=0
          while true; do
            wizard_read_value library_name '知识库名称（回车使用默认知识库，0 完成添加）：' || return $?
            [[ "$library_name" != 0 ]] || break
            library_name=${library_name:-默认知识库}
            if ! wizard_knowledge_name_valid "$library_name"; then
              wizard_warn '知识库名称须为 1～100 个 UTF-8 字节，不含控制字符；尚未登记，请重新输入'
              continue
            fi
            if (( $(jq 'length' <<< "$WIZARD_KNOWLEDGE_LIBRARIES") >= 100 )); then
              wizard_warn '一次初始化最多登记 100 个命名库；输入 0 完成添加'
              continue
            fi
            if [[ "$value" == ::PASTE:: ]]; then library_path=::PASTE::
            else wizard_read_value library_path '文件/目录路径，或 ::PASTE:: 粘贴正文（0 完成添加）：' || return $?; fi
            [[ "$library_path" != 0 ]] || break
            if [[ "$library_path" == ::PASTE:: ]]; then
              if wizard_read_multiline library_temp 8388608; then
                library_path=$(mktemp "$work_dir/wizard-knowledge.XXXXXX.md") || return 1
                printf '%s' "$library_temp" > "$library_path"; chmod 0600 "$library_path"
              else
                multiline_status=$?
                (( multiline_status != 2 )) || return 2
                continue
              fi
            fi
            if ! knowledge_summary=$(wizard_knowledge_inspect "$library_path"); then
              wizard_warn '知识来源未通过与管理菜单相同的递归、类型、大小和路径校验'
              continue
            fi
            library_path=$(realpath -e -- "$library_path") || return 1
            WIZARD_KNOWLEDGE_LIBRARIES=$(jq -cn --argjson libraries "$WIZARD_KNOWLEDGE_LIBRARIES" --arg name "$library_name" --arg source "$library_path" '$libraries+[{name:$name,source:$source}]')
            count=$(jq -er '.supported_files' <<< "$knowledge_summary") || return 1
            ((WIZARD_KNOWLEDGE_FILES+=count))
            wizard_write_state "$output_file" collecting 9
            [[ "$value" != ::PASTE:: ]] || break
          done
          break
        fi
        if ! knowledge_summary=$(wizard_knowledge_inspect "$value"); then
          wizard_warn '知识来源未通过校验；可更正路径，或回车明确跳过知识配置'
          continue
        fi
        resolved=$(realpath -e -- "$value") || {
          wizard_warn '无法解析知识路径'
          continue
        }
        if [[ -f "$resolved" ]]; then
          WIZARD_KNOWLEDGE_MODE='file'
        elif [[ -d "$resolved" ]]; then
          WIZARD_KNOWLEDGE_MODE=directory
        else
          wizard_warn '知识路径必须是普通文件或目录'
          continue
        fi
        WIZARD_KNOWLEDGE_SOURCE=$resolved
        WIZARD_KNOWLEDGE_FILES=$(jq -er '.supported_files' <<< "$knowledge_summary") || return 1
        break
      done
      wizard_write_state "$output_file" collecting 10
      ;;
    *) wizard_error "未知向导步骤：$step"; return 1 ;;
  esac
}

wizard_mask_website_id() {
  local value=$1
  if (( ${#value} <= 8 )); then printf '已填写'; else printf '%s…%s' "${value:0:4}" "${value: -4}"; fi
}

wizard_show_summary() {
  printf '\n[10/10] 核对并开始\n'
  printf '  AI API 地址：%s\n' "$WIZARD_BASE_URL"
  printf '  AI API Key：已填写（不显示）\n'
  printf '  模型：%s\n' "$WIZARD_MODEL"
  printf '  Crisp Website ID：%s\n' "$(wizard_mask_website_id "$WIZARD_CRISP_WEBSITE_ID")"
  printf '  Crisp Token Identifier：已填写（不显示）\n'
  printf '  Crisp Token Key：已填写（不显示）\n'
  printf '  生产 Webhook：%s\n' "$WIZARD_WEBHOOK_PRODUCTION_URL"
  case "$WIZARD_PROMPT_MODE" in
    default) printf '  客服提示词：安全默认提示词\n' ;;
    file) printf '  客服提示词：已选择本地文件\n' ;;
    inline) printf '  客服提示词：已填写自定义内容\n' ;;
  esac
  if [[ "$WIZARD_KNOWLEDGE_MODE" == empty ]]; then
    printf '  知识库：尚未配置业务知识\n'
  elif [[ "$WIZARD_KNOWLEDGE_MODE" == libraries ]]; then
    printf '  知识库：已选择 %s 个命名库、%s 个支持文件；解析和索引数量将在安装后对账。\n' \
      "$(jq -r 'length' <<< "$WIZARD_KNOWLEDGE_LIBRARIES")" "$WIZARD_KNOWLEDGE_FILES"
  else
    printf '  知识库：已选择 %s 个支持文件\n' "$WIZARD_KNOWLEDGE_FILES"
  fi
  printf '  新实例默认：客服启用；关键词展示确认按钮；人工恢复 1800 秒；欢迎启用；自动展开关闭。\n'
  printf '  已有实例：保留合法的自定义启停、欢迎和恢复设置。\n'
}

wizard_confirm() {
  local output_file=$1
  local choice step

  while true; do
    wizard_show_summary
    wizard_read_value choice '1 开始安装 / 2 返回修改 / 0 取消：' || return $?
    case "$choice" in
      1)
        wizard_write_state "$output_file" confirmed 10
        wizard_info '快速初始化参数已确认；下面将自动完成内部配置和服务安装'
        return 0
        ;;
      2)
        wizard_read_value step '请输入要修改的步骤（1-9）：' || return $?
        if [[ "$step" =~ ^[1-9]$ ]]; then
          WIZARD_NEXT_STEP=$step
          wizard_write_state "$output_file" collecting "$step"
          return 3
        fi
        wizard_warn '请输入 1 到 9'
        ;;
      0)
        wizard_info '已取消安装；已填写内容保存在受限状态文件中'
        return 2
        ;;
      *) wizard_warn '请选择 1、2 或 0' ;;
    esac
  done
}

wizard_offer_existing() {
  local choice
  printf '检测到已确认的快速初始化配置（敏感值不会显示）。\n'
  while true; do
    wizard_read_value choice '1 使用现有配置 / 2 重新配置 / 0 取消：' || return $?
    case "$choice" in
      1) return 0 ;;
      2) return 3 ;;
      0) return 2 ;;
      *) wizard_warn '请选择 1、2 或 0' ;;
    esac
  done
}

wizard_result_is_confirmed() {
  local result_file=$1
  [[ -f "$result_file" && ! -L "$result_file" ]] \
    && jq -e '.schema_version == 1 and .status == "confirmed"' "$result_file" >/dev/null 2>&1
}

quick_init_wizard() {
  local output_file=$1
  local defaults_file=${2:-}
  local work_dir source_file result step edit_mode=0

  wizard_require_command mktemp || return 1
  wizard_require_command curl || return 1
  wizard_require_command jq || return 1
  wizard_require_command python3 || return 1
  wizard_require_command realpath || return 1
  wizard_require_command stat || return 1
  wizard_require_command find || return 1
  [[ "$WIZARD_PAGE_SIZE" =~ ^[1-9][0-9]?$ ]] || {
    wizard_error 'WIZARD_PAGE_SIZE 必须是 1 到 99 的整数'
    return 1
  }

  wizard_init_values
  source_file=''
  if [[ -e "$output_file" || -L "$output_file" ]]; then
    source_file=$output_file
  elif [[ -n "$defaults_file" && ( -e "$defaults_file" || -L "$defaults_file" ) ]]; then
    source_file=$defaults_file
  fi
  if [[ -n "$source_file" ]]; then
    wizard_load_state "$source_file" || return 1
    if [[ "$WIZARD_STATUS" == confirmed ]]; then
      if wizard_offer_existing; then
        [[ "$source_file" == "$output_file" ]] || wizard_write_state "$output_file" confirmed 10
        return 0
      else
        result=$?
        case "$result" in
          2) return 2 ;;
          3)
            WIZARD_STATUS=collecting
            WIZARD_NEXT_STEP=1
            wizard_write_state "$output_file" collecting 1 || return 1
            ;;
          *) return "$result" ;;
        esac
      fi
    else
      wizard_info "检测到未完成的快速初始化，将从第 ${WIZARD_NEXT_STEP} 步继续"
    fi
  fi
  if [[ -z "$WIZARD_CREATED_AT" ]]; then
    printf -v WIZARD_CREATED_AT '%(%Y-%m-%dT%H:%M:%SZ)T' -1
  fi

  work_dir=$(dirname -- "$output_file")
  mkdir -p -- "$work_dir"
  [[ -d "$work_dir" && ! -L "$work_dir" ]] || {
    wizard_error "向导工作目录不安全：$work_dir"
    return 1
  }

  while true; do
    step=$WIZARD_NEXT_STEP
    while (( step <= 9 )); do
      wizard_collect_step "$step" "$output_file" "$work_dir" || return $?
      if (( edit_mode )); then
        if (( step == 1 || step == 2 )); then
          step=3
          WIZARD_NEXT_STEP=3
          wizard_write_state "$output_file" collecting 3
          edit_mode=0
          continue
        fi
        step=10
        WIZARD_NEXT_STEP=10
        wizard_write_state "$output_file" collecting 10
        edit_mode=0
        break
      fi
      step=$WIZARD_NEXT_STEP
    done
    if wizard_confirm "$output_file"; then
      return 0
    else
      result=$?
      case "$result" in
        2) return 2 ;;
        3) edit_mode=1 ;;
        *) return "$result" ;;
      esac
    fi
  done
}

wizard_usage() {
  printf '%s\n' \
    '用法：scripts/wizard.sh --output RESULT_JSON [--defaults DEFAULTS_JSON]' \
    '' \
    '执行十项中文快速初始化并把结果原子写入权限为 0600 的 JSON 文件。' \
    '该文件含 API Key 和 Crisp Token，只能交给安装器读取，禁止公开或提交 Git。'
}

wizard_cli_main() {
  local output_file='' defaults_file=''
  while (( $# > 0 )); do
    case "$1" in
      --output)
        (( $# >= 2 )) || { wizard_error '--output 缺少参数'; return 1; }
        output_file=$2
        shift 2
        ;;
      --defaults)
        (( $# >= 2 )) || { wizard_error '--defaults 缺少参数'; return 1; }
        defaults_file=$2
        shift 2
        ;;
      --help|-h) wizard_usage; return 0 ;;
      *) wizard_error "未知选项：$1"; wizard_usage >&2; return 1 ;;
    esac
  done
  [[ -n "$output_file" ]] || { wizard_error '必须指定 --output'; return 1; }
  quick_init_wizard "$output_file" "$defaults_file"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  trap 'printf "\n警告：快速初始化已中断；已完成步骤可在下次运行恢复。\n" >&2; exit 2' INT TERM
  if wizard_cli_main "$@"; then
    exit 0
  else
    wizard_status=$?
    exit "$wizard_status"
  fi
fi
