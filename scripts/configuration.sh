#!/usr/bin/env bash
set -euo pipefail

CONFIGURATION_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
if ! declare -F env_get >/dev/null; then
  # shellcheck source=scripts/common.sh
  source "${CONFIGURATION_DIR}/common.sh"
fi

configuration_error() { printf '错误：%s\n' "$*" >&2; }

configuration_path() {
  case "$2" in
    runtime|handoff|keyword|menu|tags|feedback) printf '%s/config/%s.yaml\n' "$1" "$2" ;;
    *) configuration_error '配置名称不受支持'; return 1 ;;
  esac
}

configuration_runtime_init() {
  local deploy_dir=$1 target="${1}/config/runtime.yaml" temporary
  mkdir -p -- "${deploy_dir}/config" "${deploy_dir}/tmp" "${deploy_dir}/backups/config-history"
  [[ ! -L "${deploy_dir}/config" && ! -L "$target" ]] || return 1
  if [[ ! -f "$target" ]]; then
    temporary=$(mktemp "${target}.tmp.XXXXXX")
    jq -M -n '{schema_version:2,enabled:true,revision:1,applied_revision:0}' > "$temporary"
    chmod 640 "$temporary"
    chown root:1000 "$temporary" 2>/dev/null || true
    mv -f -- "$temporary" "$target"
  fi
}

configuration_validate() {
  local name=$1 input=$2
  [[ -f "$input" && ! -L "$input" && $(stat -c '%s' "$input") -le 1048576 ]] || return 1
  jq -M -e 'type == "object"' "$input" >/dev/null 2>&1 || return 1
  case "$name" in
    runtime)
      jq -M -e '.enabled | type == "boolean"' "$input" >/dev/null ;;
    handoff)
      jq -M -e '.handoff | type == "object" and (.resume_after_seconds | type == "number" and floor == . and . >= 0 and . <= 604800) and ((.message // "") | type == "string" and utf8bytelength <= 10000)' "$input" >/dev/null ;;
    keyword)
      jq -M -e '
        .schema_version == 2 and (.rules | type == "array" and length <= 200) and
        ([.rules[].id] | length == (unique | length)) and
        all(.rules[]; (.id | type == "string" and test("^[A-Za-z0-9_-]{1,80}$")) and
          (.enabled | type == "boolean") and (.match_mode == "contains" or .match_mode == "exact") and
          (.keywords | type == "array" and length > 0 and length <= 100 and all(type == "string" and utf8bytelength > 0 and utf8bytelength <= 256)) and
          ((.exclude_keywords // []) | type == "array" and all(type == "string" and utf8bytelength <= 256)) and
          (.action == "show_handoff_offer" or .action == "reply" or .action == "menu" or .action == "prompt") and
          ((.cooldown_seconds // 60) | type == "number" and floor == . and . >= 0 and . <= 86400) and
          ((.offer_ttl_seconds // 600) | type == "number" and floor == . and . >= 10 and . <= 86400) and
          ((.priority // 0) | type == "number" and floor == . and . >= -10000 and . <= 10000) and
          ([.text,.confirm_label,.cancel_label,.confirm_message,.prompt,.target] | all(. == null or (type == "string" and utf8bytelength <= 10000))))
      ' "$input" >/dev/null ;;
    menu)
      jq -M -e '
        . as $root |
        def nodeok($id;$trail;$depth):
          if $depth > 8 or ($trail | index($id)) != null then false
          elif ($root.menus[$id] | type) != "object" then false
          else all($root.menus[$id].options[]?;
            if .action.type == "menu" then
              if (.action.back // .action.is_back // false) then .action.target as $target | ($trail | index($target)) != null
              else nodeok(.action.target; $trail + [$id]; $depth + 1) end
            else true end)
          end;
        (.welcome | type == "object") and (.welcome.enabled | type == "boolean") and
        ((.welcome.text // "") | type == "string" and utf8bytelength <= 10000) and
        ((.welcome.trigger // "first_message") | . == "first_message" or . == "widget_load" or . == "chat_open") and
        ((.welcome.auto_open // false) | type == "boolean") and
        (.menus | type == "object" and length <= 100) and (.menus[.root] | type == "object") and
        all(.menus[]; (.title | type == "string" and utf8bytelength <= 2000) and (.options | type == "object" and length <= 12) and
          all(.options[]; (.label | type == "string" and utf8bytelength > 0 and utf8bytelength <= 100) and
            (.action.type | . == "menu" or . == "reply" or . == "prompt" or . == "show_handoff_offer") and
            (if .action.type == "menu" then $root.menus[.action.target] != null else true end))) and nodeok(.root; []; 0)
      ' "$input" >/dev/null ;;
    tags) jq -M -e '.tags | type == "object" and all(to_entries[]; if .key == "enabled" then (.value|type)=="boolean" else (.value|type)=="string" and (.value|utf8bytelength)<=100 end)' "$input" >/dev/null ;;
    feedback) jq -M -e '
      def words: type == "array" and length <= 100 and all(type == "string" and utf8bytelength > 0 and utf8bytelength <= 200);
      .feedback | type == "object" and (.enabled | type == "boolean") and
      (.expires_after_seconds | type == "number" and floor == . and . >= 1 and . <= 604800) and
      ((.retention_days // 30) | type == "number" and floor == . and . >= 1 and . <= 3650) and
      (.max_text_chars | type == "number" and floor == . and . >= 50 and . <= 2000) and
      ((.retain_text // false) | type == "boolean") and
      (.positive_keywords | words) and (.negative_keywords | words) and
      all([.prompt, .positive_message, .negative_message][]; type == "string" and utf8bytelength <= 10000)
    ' "$input" >/dev/null ;;
    *) return 1 ;;
  esac
}

configuration_decode_file() {
  local input=$1 output=$2 size
  [[ -f "$input" && ! -L "$input" ]] || { configuration_error '配置来源必须是普通文件且不得是符号链接'; return 1; }
  size=$(stat -c '%s' -- "$input")
  (( size > 0 && size <= 1048576 )) || { configuration_error '单份配置必须为 1～1048576 字节'; return 1; }
  python3 - "$input" "$output" <<'PY'
import json
import pathlib
import sys

import yaml

class StrictLoader(yaml.SafeLoader):
    pass

def construct_mapping(loader, node, deep=False):
    mapping = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if not isinstance(key, str) or key in mapping:
            raise ValueError("配置键必须是唯一字符串")
        mapping[key] = loader.construct_object(value_node, deep=deep)
    return mapping

StrictLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, construct_mapping)
raw = pathlib.Path(sys.argv[1]).read_bytes()
try:
    text = raw.decode("utf-8", "strict")
except UnicodeDecodeError:
    raise SystemExit("配置不是有效 UTF-8")
if "\x00" in text:
    raise SystemExit("配置包含 NUL")
try:
    value = yaml.load(text, Loader=StrictLoader)
except yaml.MarkedYAMLError as exc:
    mark = exc.problem_mark
    location = f"（第 {mark.line + 1} 行，第 {mark.column + 1} 列）" if mark else ""
    raise SystemExit(f"配置解析失败{location}")
except Exception:
    raise SystemExit("配置解析失败")
if not isinstance(value, dict):
    raise SystemExit("配置顶层必须是对象")
try:
    encoded = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
except (TypeError, ValueError, UnicodeError):
    raise SystemExit("配置包含不能安全保存的数据类型")
try:
    pathlib.Path(sys.argv[2]).write_text(encoded + "\n", encoding="utf-8")
except OSError:
    raise SystemExit("配置规范化结果无法安全保存")
PY
}

configuration_normalize_file() {
  local name=$1 input=$2 output=$3
  configuration_decode_file "$input" "$output" || return 1
  configuration_validate "$name" "$output" \
    || { configuration_error "${name} 配置不符合 schema 或边界"; return 1; }
}

configuration_revision() {
  local deploy_dir=$1 applied=${2:-false} temporary normalized target="${1}/config/runtime.yaml"
  configuration_runtime_init "$deploy_dir" || return 1
  normalized=$(mktemp "${deploy_dir}/tmp/runtime-normalized.XXXXXX")
  configuration_normalize_file runtime "$target" "$normalized" || { rm -f -- "$normalized"; return 1; }
  temporary=$(mktemp "${target}.tmp.XXXXXX")
  jq -M --argjson applied "$applied" '.schema_version = 2 | .revision = ((.revision // 0) + 1) |
    if $applied then .applied_revision = .revision else . end' "$normalized" > "$temporary" \
    || { rm -f -- "$normalized" "$temporary"; return 1; }
  rm -f -- "$normalized"
  chmod 640 "$temporary"
  chown root:1000 "$temporary" 2>/dev/null || true
  mv -f -- "$temporary" "$target"
}

configuration_mark_applied() {
  local deploy_dir=$1 temporary normalized target="${1}/config/runtime.yaml"
  configuration_runtime_init "$deploy_dir" || return 1
  normalized=$(mktemp "${deploy_dir}/tmp/runtime-normalized.XXXXXX")
  configuration_normalize_file runtime "$target" "$normalized" || { rm -f -- "$normalized"; return 1; }
  temporary=$(mktemp "${target}.tmp.XXXXXX")
  jq -M '.applied_revision = .revision' "$normalized" > "$temporary" \
    || { rm -f -- "$normalized" "$temporary"; return 1; }
  rm -f -- "$normalized"
  chmod 640 "$temporary"
  chown root:1000 "$temporary" 2>/dev/null || true
  mv -f -- "$temporary" "$target"
}

configuration_readback() {
  local deploy_dir=$1 name=$2 expected actual
  expected=$(sha256sum -- "${deploy_dir}/config/${name}" | awk '{print $1}')
  actual=$(docker_compose "$deploy_dir" exec -T n8n node -e '
    const fs = require("fs"), crypto = require("crypto");
    const name = process.argv[1];
    if (!/^[a-z][a-z0-9_-]*\.(yaml|md|json)$/.test(name)) process.exit(2);
    process.stdout.write(crypto.createHash("sha256").update(fs.readFileSync("/opt/crisp-ai/config/" + name)).digest("hex"));
  ' "$name" 2>/dev/null) || return 1
  [[ "$actual" == "$expected" ]]
}

configuration_materials_ensure() {
  local deploy_dir=$1
  [[ -x "${CONFIGURATION_DIR}/materials.sh" ]] \
    || { configuration_error '资料应用模块缺失'; return 1; }
  if [[ ! -e "${deploy_dir}/config/materials-applied.json" && ! -L "${deploy_dir}/config/materials-applied.json" ]]; then
    bash "${CONFIGURATION_DIR}/materials.sh" --deploy-dir "$deploy_dir" initialize >/dev/null
  fi
}

configuration_apply() (
  local deploy_dir=$1 name=$2 input=$3 target temporary history normalized previous_normalized=''
  target=$(configuration_path "$deploy_dir" "$name") || return 1
  configuration_runtime_init "$deploy_dir" || return 1
  normalized=$(mktemp "${deploy_dir}/tmp/configuration-candidate.XXXXXX")
  trap 'rm -f -- "${normalized:-}"' EXIT
  configuration_normalize_file "$name" "$input" "$normalized" \
    || { rm -f -- "$normalized"; configuration_error '候选配置格式或边界无效，原设置未修改'; return 1; }
  acquire_maintenance_lock "$deploy_dir"
  configuration_materials_ensure "$deploy_dir" || return 1
  history=$(mktemp -d "${deploy_dir}/backups/config-history/${name}.XXXXXXXX")
  [[ ! -f "$target" ]] || cp -p -- "$target" "${history}/previous"
  temporary=$(mktemp "${target}.tmp.XXXXXX")
  jq -M '.' "$normalized" > "$temporary"
  if [[ "$name" == runtime ]]; then
    previous_normalized=$(mktemp "${deploy_dir}/tmp/runtime-previous.XXXXXX")
    configuration_normalize_file runtime "${history}/previous" "$previous_normalized" \
      || { rm -f -- "$normalized" "$previous_normalized" "$temporary"; return 1; }
    jq -M --slurpfile previous "$previous_normalized" '.schema_version=2 |
      .revision=($previous[0].revision // 1) | .applied_revision=($previous[0].applied_revision // 0)' "$normalized" > "$temporary" \
      || { rm -f -- "$normalized" "$previous_normalized" "$temporary"; return 1; }
    rm -f -- "$previous_normalized"
  fi
  rm -f -- "$normalized"
  trap - EXIT
  chmod 640 "$temporary"
  chown root:1000 "$temporary" 2>/dev/null || true
  mv -f -- "$temporary" "$target"
  if ! bash "${CONFIGURATION_DIR}/materials.sh" --deploy-dir "$deploy_dir" apply >/dev/null; then
    [[ ! -f "${history}/previous" ]] || cp -p -- "${history}/previous" "$target"
    configuration_error '配置未通过统一应用与运行时回读；原编辑文件已恢复'
    return 1
  fi
  jq -M '.configuration.runtime | {schema_version,enabled,revision,applied_revision}' \
    "${deploy_dir}/config/materials-applied.json"
)

configuration_prompt_verify() {
  configuration_prompt_verify_file "$1" "${1}/config/prompt.md"
}

configuration_prompt_verify_file() {
  local deploy_dir=$1 prompt_file=$2 response status
  [[ -f "$prompt_file" && ! -L "$prompt_file" ]] || return 1
  anythingllm_connection "$deploy_dir"
  response=$(mktemp "${deploy_dir}/tmp/prompt-readback.XXXXXX")
  chmod 600 "$response"
  status=$(anythingllm_secure_request "$deploy_dir" GET "http://127.0.0.1:${ANYTHING_PORT}/api/v1/workspace/${ANYTHING_WORKSPACE}" "$ANYTHING_KEY" '' "$response")
  if [[ "$status" != 2?? ]] || ! jq -M -e --rawfile expected "$prompt_file" '
    (.workspace | if type == "array" then .[0] else . end).openAiPrompt == $expected
  ' "$response" >/dev/null; then
    rm -f -- "$response"
    return 1
  fi
  rm -f -- "$response"
}

configuration_prompt_sync_file() {
  local deploy_dir=$1 prompt_file=$2 key workspace port payload response_file status
  [[ -f "$prompt_file" && ! -L "$prompt_file" ]] || return 1
  anythingllm_connection "$deploy_dir"
  key=$ANYTHING_KEY
  workspace=$ANYTHING_WORKSPACE
  port=$ANYTHING_PORT
  payload=$(jq -M -cn --rawfile prompt "$prompt_file" '{openAiPrompt:$prompt}')
  response_file=$(mktemp "${deploy_dir}/tmp/prompt-apply.XXXXXX")
  chmod 600 "$response_file"
  status=$(anythingllm_secure_request "$deploy_dir" POST \
    "http://127.0.0.1:${port}/api/v1/workspace/${workspace}/update" "$key" "$payload" "$response_file")
  if [[ "$status" != 2?? ]] || ! jq -M -e --rawfile expected "$prompt_file" '
    .workspace as $workspace |
    (if ($workspace | type) == "array" then $workspace[0]
     elif ($workspace | type) == "object" then $workspace else {} end) |
    (.openAiPrompt // "") == $expected
  ' "$response_file" >/dev/null; then
    rm -f -- "$response_file"
    return 1
  fi
  rm -f -- "$response_file"
  configuration_prompt_verify_file "$deploy_dir" "$prompt_file"
}

configuration_prompt_candidate_validate() {
  local input=$1 size
  [[ -f "$input" && ! -L "$input" ]] \
    || { configuration_error 'Prompt 来源必须是普通文件'; return 1; }
  size=$(stat -c '%s' -- "$input")
  (( size > 0 && size <= 262144 )) \
    || { configuration_error 'Prompt 必须为 1～262144 个 UTF-8 字节'; return 1; }
  python3 - "$input" <<'PY'
import pathlib
import sys
raw = pathlib.Path(sys.argv[1]).read_bytes()
try:
    text = raw.decode("utf-8", "strict")
except UnicodeDecodeError:
    raise SystemExit("Prompt 不是有效 UTF-8")
if "\x00" in text or not text.strip():
    raise SystemExit("Prompt 不能为空、全空白或包含 NUL")
PY
}

configuration_prompt_apply() (
  local deploy_dir=$1 input=$2 target="${1}/config/prompt.md" stage history
  configuration_prompt_candidate_validate "$input" \
    || { configuration_error 'Prompt 候选无效，原正文未修改'; return 1; }
  acquire_maintenance_lock "$deploy_dir"
  configuration_runtime_init "$deploy_dir"
  configuration_materials_ensure "$deploy_dir" || return 1
  history=$(mktemp -d "${deploy_dir}/backups/config-history/prompt.XXXXXXXX")
  cp -p -- "$target" "${history}/previous.md"
  stage=$(mktemp "${target}.tmp.XXXXXX")
  install -m 640 -- "$input" "$stage"
  chown root:1000 "$stage" 2>/dev/null || true
  mv -f -- "$stage" "$target"
  if ! bash "${CONFIGURATION_DIR}/materials.sh" --deploy-dir "$deploy_dir" apply >/dev/null; then
    install -m 640 -- "${history}/previous.md" "$target"
    chown root:1000 "$target" 2>/dev/null || true
    configuration_error 'Prompt 应用失败；上一有效正文与运行投影保持，编辑文件已恢复'
    return 1
  fi
  install -m 600 -- "${history}/previous.md" "${deploy_dir}/backups/config-history/prompt.previous.md"
  jq -M -n --arg hash "$(sha256sum "$target" | awk '{print $1}')" '{applied:true,sha256:$hash}'
)

configuration_query() {
  local deploy_dir=$1 question=$2 response payload status question_bytes
  question_bytes=$(printf '%s' "$question" | wc -c | tr -d ' ')
  (( question_bytes > 0 && question_bytes <= 8000 )) || return 1
  anythingllm_connection "$deploy_dir"
  response=$(mktemp "${deploy_dir}/tmp/configuration-query.XXXXXX")
  chmod 600 "$response"
  payload=$(jq -M -cn --arg message "$question" '{message:$message,mode:"chat",sessionId:"ai-support-admin-test",reset:true}')
  status=$(anythingllm_secure_request "$deploy_dir" POST "http://127.0.0.1:${ANYTHING_PORT}/api/v1/workspace/${ANYTHING_WORKSPACE}/chat" "$ANYTHING_KEY" "$payload" "$response" 120)
  if [[ "$status" != 2?? ]] || ! jq -M -e '(.error == null or .error == false) and (.textResponse | type == "string" and length > 0)' "$response" >/dev/null; then
    rm -f -- "$response"
    configuration_error '测试问答失败，请检查 Provider 和知识索引'
    return 1
  fi
  jq -M '{answer:.textResponse,sources:(.sources // []),verified:true}' "$response"
  rm -f -- "$response"
}

configuration_migrate() {
  local deploy_dir=$1 target temporary decoded handoff_decoded
  configuration_runtime_init "$deploy_dir"
  target="${deploy_dir}/config/provider.yaml"
  if [[ -f "$target" ]] && ! jq -M -e '.provider | type == "object"' "$target" >/dev/null 2>&1; then
    temporary=$(mktemp "${target}.tmp.XXXXXX")
    chmod 600 "$temporary"
    python3 -c 'import json,sys,yaml
value=yaml.safe_load(open(sys.argv[1],encoding="utf-8"))
if not isinstance(value,dict) or not isinstance(value.get("provider"),dict): raise SystemExit("Provider 配置格式错误")
provider=value["provider"]
if any(key.lower() in ("api_key","key","token","secret","password","authorization") for key in provider): raise SystemExit("Provider 配置包含秘密字段，请使用受限凭据存储")
value["schema_version"]=2
json.dump(value,sys.stdout,ensure_ascii=False,indent=2)
' "$target" > "$temporary" || return 1
    install -m 600 -- "$target" "${deploy_dir}/backups/config-history/provider.v1.previous.yaml"
    chmod 640 "$temporary"; chown root:1000 "$temporary" 2>/dev/null || true
    mv -f -- "$temporary" "$target"
  fi
  target="${deploy_dir}/config/keyword.yaml"
  if [[ -f "$target" ]]; then
    decoded=$(mktemp "${deploy_dir}/tmp/keyword-migrate.XXXXXX")
    configuration_decode_file "$target" "$decoded" || { rm -f -- "$decoded"; return 1; }
  fi
  if [[ -f "$target" ]] && ! jq -M -e '.schema_version == 2 and (.rules | type == "array")' "$decoded" >/dev/null 2>&1; then
    temporary=$(mktemp "${target}.tmp.XXXXXX")
    handoff_decoded=$(mktemp "${deploy_dir}/tmp/handoff-migrate.XXXXXX")
    configuration_decode_file "${deploy_dir}/config/handoff.yaml" "$handoff_decoded" \
      || { rm -f -- "$decoded" "$handoff_decoded" "$temporary"; return 1; }
    jq -M --slurpfile handoff "$handoff_decoded" '
      {schema_version:2,rules:([(.keywords // [])[] | {
        id:.id,name:(.name // .id),enabled:(if has("enabled") then .enabled else true end),
        match_mode:(.match_mode // "contains"),keywords:(.keywords // .match // []),
        exclude_keywords:(.exclude_keywords // []),priority:(.priority // 0),cooldown_seconds:(.cooldown_seconds // 0),offer_ttl_seconds:600,
        action:(if .action.type == "handoff" then "show_handoff_offer" else .action.type end),
        text:(.action.text // ""),prompt:(.action.prompt // ""),target:(.action.target // ""),
        confirm_label:"召唤人工客服",cancel_label:"继续 AI 客服",confirm_message:($handoff[0].handoff.message // "已暂停本次对话的 AI 回复，您的人工协助请求已收到。")
      }] + [{id:"handoff-offer",name:"人工协助确认",enabled:(if ($handoff[0].handoff | has("enabled")) then $handoff[0].handoff.enabled else true end),match_mode:($handoff[0].handoff.match_mode // "contains"),
        keywords:($handoff[0].handoff.keywords // ["人工","转人工","人工客服"]),exclude_keywords:["不要人工","不需要人工","不用人工","不转人工"],priority:100,
        cooldown_seconds:60,offer_ttl_seconds:600,action:"show_handoff_offer",text:"需要人工协助吗？请点击下方按钮确认。",confirm_label:"召唤人工客服",cancel_label:"继续 AI 客服",
        confirm_message:($handoff[0].handoff.message // "已暂停本次对话的 AI 回复，您的人工协助请求已收到。")}] | unique_by(.id))}
    ' "$decoded" > "$temporary" \
      || { rm -f -- "$decoded" "$handoff_decoded" "$temporary"; return 1; }
    configuration_validate keyword "$temporary" \
      || { rm -f -- "$decoded" "$handoff_decoded" "$temporary"; return 1; }
    install -m 600 -- "$target" "${deploy_dir}/backups/config-history/keyword.v1.previous.yaml"
    chmod 640 "$temporary"
    chown root:1000 "$temporary" 2>/dev/null || true
    mv -f -- "$temporary" "$target"
    rm -f -- "$handoff_decoded"
  fi
  rm -f -- "${decoded:-}"
  target="${deploy_dir}/config/menu.yaml"
  if [[ -f "$target" ]]; then
    decoded=$(mktemp "${deploy_dir}/tmp/menu-migrate.XXXXXX")
    configuration_decode_file "$target" "$decoded" || { rm -f -- "$decoded"; return 1; }
    temporary=$(mktemp "${target}.tmp.XXXXXX")
    jq -M 'walk(if type == "object" and .type? == "handoff" then .type="show_handoff_offer" else . end) |
      .welcome.trigger = (.welcome.trigger // "first_message") | .welcome.auto_open = (.welcome.auto_open // false) |
      . as $root | .menus |= with_entries(. as $menu | .value.options |= with_entries(
        if .value.action.type == "menu" and .value.action.target == $root.root and $menu.key != $root.root then .value.action.back = true else . end))' "$decoded" > "$temporary" \
      || { rm -f -- "$decoded" "$temporary"; return 1; }
    configuration_validate menu "$temporary" \
      || { rm -f -- "$decoded" "$temporary"; return 1; }
    chmod 640 "$temporary"
    chown root:1000 "$temporary" 2>/dev/null || true
    mv -f -- "$temporary" "$target"
    rm -f -- "$decoded"
  fi
}

configuration_main() {
  local deploy_request='' action name input deploy_dir temporary
  while (( $# )); do
    case "$1" in
      --deploy-dir) deploy_request=${2:?}; shift 2 ;;
      --help|-h) printf '%s\n' '用法：configuration.sh [--deploy-dir PATH] get NAME | apply NAME --input FILE | status | migrate' 'Prompt：prompt-show | prompt-apply FILE | prompt-restore | prompt-export FILE | prompt-test QUESTION' '统一资料：materials-status | materials-validate | materials-apply [--force-external]'; return ;;
      *) break ;;
    esac
  done
  action=${1:-status}; shift || true
  deploy_dir=$(resolve_deploy_dir "$deploy_request")
  assert_managed_installation "$deploy_dir"
  case "$action" in
    get|read)
      name=${1:?}; input=$(configuration_path "$deploy_dir" "$name")
      temporary=$(mktemp "${deploy_dir}/tmp/configuration-read.XXXXXX")
      configuration_normalize_file "$name" "$input" "$temporary" || { rm -f -- "$temporary"; return 1; }
      jq -M '.' "$temporary"
      rm -f -- "$temporary"
      ;;
    apply) name=${1:?}; shift; [[ ${1:-} != --input ]] || shift; configuration_apply "$deploy_dir" "$name" "${1:?}" ;;
    status)
      configuration_runtime_init "$deploy_dir"
      if [[ -e "${deploy_dir}/config/materials-applied.json" || -L "${deploy_dir}/config/materials-applied.json" ]]; then
        if [[ ! -f "${deploy_dir}/config/materials-applied.json" || -L "${deploy_dir}/config/materials-applied.json" ]] \
          || ! jq -M -e '.schema_version == 1 and (.state == "applied" or .state == "applying") and (.configuration.runtime | type == "object")' "${deploy_dir}/config/materials-applied.json" >/dev/null 2>&1; then
          configuration_error '资料投影损坏，拒绝将可编辑原文显示为当前运行配置'
          return 1
        fi
        jq -M '.configuration.runtime' "${deploy_dir}/config/materials-applied.json"
      else
        temporary=$(mktemp "${deploy_dir}/tmp/configuration-status.XXXXXX")
        configuration_normalize_file runtime "${deploy_dir}/config/runtime.yaml" "$temporary" \
          || { rm -f -- "$temporary"; return 1; }
        jq -M '.' "$temporary"
        rm -f -- "$temporary"
      fi
      ;;
    mark-applied)
      if [[ -f "${deploy_dir}/config/materials-applied.json" ]]; then
        bash "${CONFIGURATION_DIR}/materials.sh" --deploy-dir "$deploy_dir" apply --refresh-projection >/dev/null
      else
        bash "${CONFIGURATION_DIR}/materials.sh" --deploy-dir "$deploy_dir" initialize >/dev/null
      fi
      ;;
    crisp-get|crisp-apply|crisp-test)
      [[ -f "${CONFIGURATION_DIR}/crisp-settings.sh" ]] || { configuration_error 'Crisp 配置模块缺失'; return 1; }
      bash "${CONFIGURATION_DIR}/crisp-settings.sh" --deploy-dir "$deploy_dir" "${action#crisp-}" "$@"
      ;;
    migrate) acquire_maintenance_lock "$deploy_dir"; configuration_migrate "$deploy_dir" ;;
    prompt-show) sed -n '1,10000p' "${deploy_dir}/config/prompt.md" ;;
    prompt-apply) configuration_prompt_apply "$deploy_dir" "${1:?}" ;;
    prompt-restore) configuration_prompt_apply "$deploy_dir" "${deploy_dir}/backups/config-history/prompt.previous.md" ;;
    prompt-export) [[ ! -e ${1:?} && ! -L $1 ]] || { configuration_error '导出文件已存在'; return 1; }; install -m 600 -- "${deploy_dir}/config/prompt.md" "$1" ;;
    prompt-test) configuration_query "$deploy_dir" "${1:?}" ;;
    materials-status) bash "${CONFIGURATION_DIR}/materials.sh" --deploy-dir "$deploy_dir" status ;;
    materials-validate) bash "${CONFIGURATION_DIR}/materials.sh" --deploy-dir "$deploy_dir" validate ;;
    materials-apply) bash "${CONFIGURATION_DIR}/materials.sh" --deploy-dir "$deploy_dir" apply "$@" ;;
    resync)
      acquire_maintenance_lock "$deploy_dir"
      configuration_migrate "$deploy_dir" && sync_prompt_to_anythingllm "$deploy_dir" &&
        knowledge_sync "$deploy_dir" && import_and_publish_workflow "$deploy_dir" &&
        configuration_prompt_verify "$deploy_dir" || return 1
      if [[ -f "${deploy_dir}/config/materials-applied.json" ]]; then
        bash "${CONFIGURATION_DIR}/materials.sh" --deploy-dir "$deploy_dir" apply --refresh-projection >/dev/null
      else
        bash "${CONFIGURATION_DIR}/materials.sh" --deploy-dir "$deploy_dir" initialize >/dev/null
      fi
      ;;
    *) configuration_error "未知配置操作：$action"; return 1 ;;
  esac
}

# knowledge.sh 会反向 source 本模块；只有最外层脚本入口可派发命令。
if [[ ${BASH_SOURCE[0]} == "$0" && ${#BASH_SOURCE[@]} -eq 1 ]]; then configuration_main "$@"; fi
