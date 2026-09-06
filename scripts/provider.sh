#!/usr/bin/env bash
set -euo pipefail

PROVIDER_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/configuration.sh
source "${PROVIDER_SCRIPT_DIR}/configuration.sh"

provider_candidate() {
  local deploy_dir=$1 input=${2:-} output=$3 current base model mode key headers headers_file
  current="${deploy_dir}/.env"
  base=$(env_get "$current" AI_API_PROBE_BASE_URL 2>/dev/null || env_get "$current" AI_API_BASE_URL 2>/dev/null || true)
  model=$(env_get "$current" AI_MODEL 2>/dev/null || true)
  mode=$(env_get "$current" AI_API_MODE 2>/dev/null || printf auto)
  key=$(env_get "$current" AI_API_KEY 2>/dev/null || true)
  headers=$(env_get "$current" AI_CUSTOM_HEADERS_JSON 2>/dev/null || printf '{}')
  if [[ -n "$input" ]]; then
    [[ -f "$input" && ! -L "$input" && $(stat -c '%s' "$input") -le 65536 ]] || return 1
    jq -M -e 'type == "object" and (.provider | type == "object")' "$input" >/dev/null || return 1
    base=$(jq -M -r --arg value "$base" '.provider.base_url // $value' "$input")
    model=$(jq -M -r --arg value "$model" '.provider.model // $value' "$input")
    mode=$(jq -M -r --arg value "$mode" '.provider.api_mode // $value' "$input")
    if jq -M -e '(.api_key // "") | length > 0' "$input" >/dev/null; then key=$(jq -M -r '.api_key' "$input"); fi
    if jq -M -e '.provider | has("custom_headers") or has("remove_header")' "$input" >/dev/null; then
      headers=$(printf '%s' "$headers" | jq -M -c --slurpfile candidate "$input" '
        with_entries(.key |= ascii_downcase) + (($candidate[0].provider.custom_headers // {}) | with_entries(.key |= ascii_downcase)) |
        if (($candidate[0].provider.remove_header // "") | length) > 0 then del(.[($candidate[0].provider.remove_header | ascii_downcase)]) else . end') || return 1
    fi
  fi
  base=$(normalize_api_base "$base") || { configuration_error 'AI 地址无效'; return 1; }
  validate_env_value "$key" || { configuration_error 'AI Key 为空或包含非法控制字符'; return 1; }
  [[ "$mode" == auto || "$mode" == responses || "$mode" == chat_completions ]] || return 1
  [[ -z "$model" ]] || validate_model_identifier "$model" || return 1
  printf '%s' "$headers" | jq -M -e 'type == "object" and length <= 32 and all(to_entries[];
    (.key | test("^[A-Za-z][A-Za-z0-9-]{0,99}$")) and
    (.key | ascii_downcase | . != "authorization" and . != "host" and . != "content-length" and . != "content-type" and . != "transfer-encoding" and . != "connection" and . != "cookie" and . != "proxy-authorization") and
    (.value | type == "string" and length <= 4096 and (test("[\\x00-\\x1f\\x7f]") | not)))' >/dev/null || { configuration_error '高级请求头无效或试图覆盖受管协议头'; return 1; }
  headers_file=$(mktemp "${deploy_dir}/tmp/provider-headers.XXXXXX")
  chmod 600 "$headers_file"
  printf '%s' "$headers" > "$headers_file"
  printf '%s' "$key" | jq -M -Rs --arg base "$base" --arg model "$model" --arg mode "$mode" --slurpfile headers "$headers_file" \
    '{provider:{base_url:$base,model:$model,api_mode:$mode,custom_headers:$headers[0]},api_key:.}' > "$output"
  rm -f -- "$headers_file"
  chmod 600 "$output"
}

provider_request() {
  local deploy_dir=$1 candidate=$2 endpoint=$3 payload=${4:-} output=$5 base config status body
  base=$(jq -M -r '.provider.base_url' "$candidate")
  [[ "$endpoint" == models || "$endpoint" == chat/completions || "$endpoint" == responses ]] || return 1
  config=$(mktemp "${deploy_dir}/tmp/provider-request.XXXXXX")
  body=$(mktemp "${deploy_dir}/tmp/provider-body.XXXXXX")
  chmod 600 "$config" "$body" "$output"
  jq -M -r '"header = " + ("Authorization: Bearer " + .api_key | @json),
    (.provider.custom_headers | to_entries[] | "header = " + (.key + ": " + .value | @json)),
    "header = \"Content-Type: application/json\""' "$candidate" > "$config"
  if [[ -n "$payload" ]]; then
    printf '%s' "$payload" > "$body"
    status=$(curl --silent --output "$output" --write-out '%{http_code}' --connect-timeout 8 --max-time 45 \
      --retry 2 --retry-delay 1 --retry-max-time 100 --config "$config" --data-binary "@${body}" "${base}/${endpoint}" 2>/dev/null || true)
  else
    status=$(curl --silent --output "$output" --write-out '%{http_code}' --connect-timeout 8 --max-time 30 \
      --retry 2 --retry-delay 1 --retry-max-time 70 --config "$config" "${base}/${endpoint}" 2>/dev/null || true)
  fi
  rm -f -- "$config" "$body"
  printf '%s\n' "${status:-000}"
}

provider_probe_candidate() {
  local deploy_dir=$1 candidate=$2 vision=${3:-false} response payload model status endpoint mode chat=false responses=false image
  model=$(jq -M -r '.provider.model' "$candidate")
  validate_model_identifier "$model" || { configuration_error '请先选择或填写模型'; return 1; }
  mode=$(jq -M -r '.provider.api_mode' "$candidate")
  response=$(mktemp "${deploy_dir}/tmp/provider-probe.XXXXXX")
  image='data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII='
  for endpoint in chat/completions responses; do
    if [[ "$vision" == true && "$mode" != auto ]]; then
      [[ "$mode" != responses || "$endpoint" == responses ]] || continue
      [[ "$mode" != chat_completions || "$endpoint" == chat/completions ]] || continue
    fi
    if [[ "$endpoint" == responses ]]; then
      payload=$(jq -M -cn --arg model "$model" --arg image "$image" --argjson vision "$vision" '{model:$model,store:false,max_output_tokens:64,input:[{role:"user",content:([{type:"input_text",text:"只回复：测试正常"}]+if $vision then [{type:"input_image",image_url:$image}] else [] end)}]}')
    else
      payload=$(jq -M -cn --arg model "$model" --arg image "$image" --argjson vision "$vision" '{model:$model,messages:[{role:"user",content:(if $vision then [{type:"text",text:"请描述图片颜色。"},{type:"image_url",image_url:{url:$image}}] else "只回复：测试正常" end)}]}')
    fi
    status=$(provider_request "$deploy_dir" "$candidate" "$endpoint" "$payload" "$response")
    if [[ "$status" == 401 || "$status" == 403 ]]; then
      configuration_error "Provider 认证或模型权限被拒绝（HTTP ${status}），请修改 Key 或模型"
    fi
    [[ "$status" == 2?? ]] || continue
    if [[ "$endpoint" == responses ]]; then
      if jq -M -e '(.error == null or .error == false) and (.status != "failed") and
        ((.output_text // ([.output[]?.content[]? | select(.type == "output_text") | .text] | join(""))) | type == "string" and test("\\S"))' "$response" >/dev/null 2>&1; then responses=true; fi
    elif jq -M -e '(.error == null or .error == false) and (.choices[0].message.content | type == "string" and test("\\S"))' "$response" >/dev/null 2>&1; then chat=true; fi
  done
  rm -f -- "$response"
  if [[ "$mode" == auto ]]; then
    if [[ "$chat" == true ]]; then mode=chat_completions; elif [[ "$responses" == true ]]; then mode=responses; else mode=unsupported; fi
  fi
  if [[ "$mode" == chat_completions && "$chat" != true || "$mode" == responses && "$responses" != true || "$mode" == unsupported ]]; then
    configuration_error '选定协议未返回有效正文，配置未生效'
    return 1
  fi
  jq -M -cn --arg mode "$mode" --argjson chat "$chat" --argjson responses "$responses" --argjson vision "$vision" \
    '{api_mode:$mode,capabilities:{chat_completions:$chat,responses:$responses,vision:$vision},verified:true}'
}

provider_runtime_test() {
  local deploy_dir=$1
  docker_compose "$deploy_dir" exec -T anythingllm node -e '
    const base = process.env.GENERIC_OPEN_AI_BASE_PATH;
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 120000);
    fetch(base.replace(/\/$/, "") + "/chat/completions", {
      method:"POST",redirect:"error",signal:controller.signal,
      headers:{"content-type":"application/json","authorization":"Bearer " + process.env.GENERIC_OPEN_AI_API_KEY},
      body:JSON.stringify({model:process.env.GENERIC_OPEN_AI_MODEL_PREF,messages:[{role:"user",content:"只回复：测试正常"}]})
    }).then(async response => {
      const body=await response.json();
      if (!response.ok || body.error || !body.choices?.[0]?.message?.content?.trim()) throw new Error();
      process.stdout.write(JSON.stringify({verified:true,environment:"anythingllm",path:"/chat/completions"}));
    }).catch(() => {process.stderr.write("应用容器中的实际 Provider 调用失败\n");process.exitCode=1;}).finally(() => clearTimeout(timeout));
  '
}

provider_apply() (
  local deploy_dir=$1 input=$2 candidate result runtime_base env_candidate config_candidate history value mode vision=false
  acquire_maintenance_lock "$deploy_dir"
  configuration_runtime_init "$deploy_dir"
  candidate=$(mktemp "${deploy_dir}/tmp/provider-candidate.XXXXXX")
  trap 'rm -f -- "$candidate"' EXIT
  provider_candidate "$deploy_dir" "$input" "$candidate" || return 1
  result=$(provider_probe_candidate "$deploy_dir" "$candidate") || return 1
  mode=$(jq -M -r '.api_mode' <<< "$result")
  config_candidate=$(mktemp "${deploy_dir}/config/provider.yaml.tmp.XXXXXX")
  jq -M --arg mode "$mode" '.provider.api_mode=$mode' "$candidate" > "$config_candidate"
  mv -f -- "$config_candidate" "$candidate"
  if provider_probe_candidate "$deploy_dir" "$candidate" true >/dev/null; then vision=true; fi
  history=$(mktemp -d "${deploy_dir}/backups/config-history/provider.XXXXXXXX")
  cp -p -- "${deploy_dir}/.env" "${history}/previous.env"
  cp -p -- "${deploy_dir}/config/provider.yaml" "${history}/previous.yaml"
  configuration_revision "$deploy_dir"
  env_candidate=$(mktemp "${deploy_dir}/.env.tmp.XXXXXX")
  cp -p -- "${deploy_dir}/.env" "$env_candidate"
  value=$(jq -M -r '.provider.base_url' "$candidate")
  runtime_base=$(provider_runtime_base "$value") || return 1
  env_set "$env_candidate" AI_API_PROBE_BASE_URL "$value"
  env_set "$env_candidate" AI_API_BASE_URL "$runtime_base"
  value=$(jq -M -r '.api_key' "$candidate"); env_set "$env_candidate" AI_API_KEY "$value"
  value=$(jq -M -r '.provider.model' "$candidate"); env_set "$env_candidate" AI_MODEL "$value"
  value=$(jq -M -c '.provider.custom_headers' "$candidate"); env_set "$env_candidate" AI_CUSTOM_HEADERS_JSON "$value"
  env_set "$env_candidate" AI_API_MODE "$mode"
  env_set "$env_candidate" AI_SUPPORTS_VISION "$vision"
  env_set "$env_candidate" AI_ANYTHINGLLM_BASE_URL 'http://provider-adapter:8787/v1'
  config_candidate=$(mktemp "${deploy_dir}/config/provider.yaml.tmp.XXXXXX")
  jq -M --arg base "$runtime_base" --argjson result "$result" --argjson vision "$vision" '{schema_version:2,provider:(.provider | .base_url=$base | .api_key_env="AI_API_KEY" | .custom_header_names=(.custom_headers | keys) | del(.custom_headers) | .capabilities=$result.capabilities | .capabilities.vision=$vision)}' "$candidate" > "$config_candidate"
  chmod 640 "$config_candidate"; chown root:1000 "$config_candidate" 2>/dev/null || true
  mv -f -- "$env_candidate" "${deploy_dir}/.env"
  mv -f -- "$config_candidate" "${deploy_dir}/config/provider.yaml"
  if ! docker_compose "$deploy_dir" config --quiet || ! docker_compose "$deploy_dir" up -d provider-adapter anythingllm n8n >&2 || ! wait_for_local_health "$deploy_dir" >&2 || ! wait_for_n8n_workflow_runtime "$deploy_dir" >&2 || ! provider_runtime_test "$deploy_dir"; then
    configuration_revision "$deploy_dir"
    cp -p -- "${history}/previous.env" "${deploy_dir}/.env"
    cp -p -- "${history}/previous.yaml" "${deploy_dir}/config/provider.yaml"
    if docker_compose "$deploy_dir" up -d provider-adapter anythingllm n8n >&2 && wait_for_local_health "$deploy_dir" >&2 && wait_for_n8n_workflow_runtime "$deploy_dir" >&2 && provider_runtime_test "$deploy_dir" >/dev/null; then
      configuration_mark_applied "$deploy_dir"
      configuration_error 'Provider 运行验证失败；旧凭据、配置和已验证运行状态已恢复'
    else
      configuration_error 'Provider 运行验证失败；旧凭据和配置已恢复，但运行状态仍待验证，请从状态与诊断继续修复'
    fi
    return 1
  fi
  configuration_revision "$deploy_dir" true
  rm -f -- "${deploy_dir}/data/provider-models.json"
  printf '\n'
)

provider_main() {
  local deploy_request='' deploy_dir action candidate response status digest
  while (( $# )); do
    case "$1" in
      --deploy-dir) deploy_request=${2:?}; shift 2 ;;
      --help|-h) printf '%s\n' '用法：provider.sh [--deploy-dir PATH] get | models | probe FILE | apply FILE | test | vision-test' '候选文件为受限 JSON：{provider:{base_url,model,api_mode,custom_headers},api_key}。空 Key 保留本机原值。'; return ;;
      *) break ;;
    esac
  done
  action=${1:-get}; shift || true
  deploy_dir=$(resolve_deploy_dir "$deploy_request")
  assert_managed_installation "$deploy_dir"
  candidate=$(mktemp "${deploy_dir}/tmp/provider-candidate.XXXXXX")
  case "$action" in probe) provider_candidate "$deploy_dir" "${1:?}" "$candidate" ;; models) provider_candidate "$deploy_dir" "${1:-}" "$candidate" ;; *) provider_candidate "$deploy_dir" '' "$candidate" ;; esac || { rm -f -- "$candidate"; return 1; }
  case "$action" in
    get|show) jq -M '.provider | .key_status="已保存" | .custom_header_names=(.custom_headers | keys) | del(.custom_headers)' "$candidate" ;;
    models)
      response=$(mktemp "${deploy_dir}/tmp/models-response.XXXXXX")
      status=$(provider_request "$deploy_dir" "$candidate" models '' "$response")
      if [[ "$status" == 401 || "$status" == 403 ]]; then rm -f -- "$candidate" "$response"; configuration_error "模型列表权限失败（HTTP ${status}），请修改凭据"; return 3; fi
      if [[ "$status" != 2?? ]] || ! jq -M -e '.data | type == "array" and any(.[]; .id | type == "string" and length > 0)' "$response" >/dev/null 2>&1; then
        rm -f -- "$candidate" "$response"; configuration_error "模型列表不可用（HTTP ${status}），可以手动填写模型"; return 2
      fi
      digest=$(sha256sum "$candidate" | awk '{print $1}')
      jq -M --arg digest "$digest" '{cache_revision:$digest,models:([.data[]?.id | select(type == "string" and length > 0)] | unique | .[0:1000])}' "$response" > "${deploy_dir}/data/provider-models.json"
      chmod 600 "${deploy_dir}/data/provider-models.json"
      jq -M '.' "${deploy_dir}/data/provider-models.json"; rm -f -- "$response" ;;
    probe) provider_probe_candidate "$deploy_dir" "$candidate" ;;
    apply) rm -f -- "$candidate"; provider_apply "$deploy_dir" "${1:?}"; return ;;
    test) provider_probe_candidate "$deploy_dir" "$candidate" && provider_runtime_test "$deploy_dir" ;;
    vision-test) provider_probe_candidate "$deploy_dir" "$candidate" true ;;
    *) rm -f -- "$candidate"; return 1 ;;
  esac
  status=$?; rm -f -- "$candidate"; return "$status"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then provider_main "$@"; fi
