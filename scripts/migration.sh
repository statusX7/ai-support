#!/usr/bin/env bash
set -euo pipefail

MIGRATION_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/knowledge.sh
source "${MIGRATION_SCRIPT_DIR}/knowledge.sh"

migration_allowed_path() {
  local entry=${1#./}
  entry=${entry%/}
  [[ "$entry" != /* && "$entry" != *'..'* && "$entry" != *\\* && "$entry" != *$'\n'* && "$entry" != *$'\r'* ]] || return 1
  case "$entry" in
    ''|config|knowledge|n8n|VERSION|manifest.json|checksums.sha256|knowledge/catalog.json|n8n/workflow.json|config/runtime.yaml|config/provider.yaml|config/prompt.md|config/keyword.yaml|config/menu.yaml|config/handoff.yaml|config/tags.yaml|config/feedback.yaml) return 0 ;;
  esac
  [[ "$entry" =~ ^knowledge/kb_([a-f0-9]{16}|default)(/sources(/doc_[a-f0-9]{16}\.(md|txt|pdf|docx))?)?$ ]]
}

migration_export() (
  local deploy_dir=$1 output=$2 stage temporary name row library source
  [[ "$output" == /* && "$output" == *.tar.gz && ! -L "$output" ]] || { configuration_error '导出目标必须是绝对 .tar.gz 路径'; return 1; }
  acquire_maintenance_lock "$deploy_dir"
  configuration_runtime_init "$deploy_dir"
  knowledge_catalog_migrate "$deploy_dir"
  stage=$(mktemp -d "${deploy_dir}/tmp/migration-export.XXXXXX")
  trap 'rm -rf -- "$stage"' EXIT
  mkdir -p -- "${stage}/config" "${stage}/knowledge" "${stage}/n8n" "$(dirname -- "$output")"
  for name in runtime handoff keyword menu tags feedback; do
    configuration_validate "$name" "${deploy_dir}/config/${name}.yaml" || return 1
    install -m 600 -- "${deploy_dir}/config/${name}.yaml" "${stage}/config/${name}.yaml"
  done
  jq -M '.revision=0 | .applied_revision=0' "${deploy_dir}/config/runtime.yaml" > "${stage}/config/runtime.yaml"
  if jq -M -e '.provider | type == "object"' "${deploy_dir}/config/provider.yaml" >/dev/null 2>&1; then
    jq -M --arg base "$(env_get "${deploy_dir}/.env" AI_API_PROBE_BASE_URL 2>/dev/null || true)" '{schema_version:2,provider:{type:"openai-compatible",base_url:(if $base != "" then $base else .provider.base_url end),model:.provider.model,api_mode:.provider.api_mode,api_key_env:"AI_API_KEY"}}' "${deploy_dir}/config/provider.yaml" > "${stage}/config/provider.yaml"
  else
    jq -M -n --arg base "$(env_get "${deploy_dir}/.env" AI_API_PROBE_BASE_URL)" --arg model "$(env_get "${deploy_dir}/.env" AI_MODEL)" --arg mode "$(env_get "${deploy_dir}/.env" AI_API_MODE)" '{schema_version:2,provider:{type:"openai-compatible",base_url:$base,model:$model,api_mode:$mode,api_key_env:"AI_API_KEY"}}' > "${stage}/config/provider.yaml"
  fi
  install -m 600 -- "${deploy_dir}/config/prompt.md" "${stage}/config/prompt.md"
  install -m 600 -- "${deploy_dir}/VERSION" "${stage}/VERSION"
  install -m 600 -- "${deploy_dir}/n8n/workflow.json" "${stage}/n8n/workflow.json"
  jq -M '.libraries |= map(.status="pending" | .last_sync=null | .error=null)' "${deploy_dir}/knowledge/catalog.json" > "${stage}/knowledge/catalog.json"
  while IFS= read -r row; do
    library=$(jq -M -r '.library' <<< "$row"); source=$(jq -M -r '.source' <<< "$row")
    [[ -f "${deploy_dir}/knowledge/${library}/${source}" && ! -L "${deploy_dir}/knowledge/${library}/${source}" ]] || return 1
    install -D -m 600 -- "${deploy_dir}/knowledge/${library}/${source}" "${stage}/knowledge/${library}/${source}"
  done < <(jq -M -c '.libraries[] | .id as $library | .documents[] | {library:$library,source:.source}' "${stage}/knowledge/catalog.json")
  jq -M -n --arg version "$(<"${stage}/VERSION")" '{format:"ai-support-business-v2",schema_version:2,version:$version,contains_secrets:false,contains_knowledge:true,requires_credentials:["AI_API_KEY","CRISP_TOKEN_IDENTIFIER","CRISP_TOKEN_KEY","Webhook Secret"]}' > "${stage}/manifest.json"
  # shellcheck disable=SC2094
  (cd -- "$stage"; find . -type f ! -name checksums.sha256 -print0 | sort -z | xargs -0 sha256sum > checksums.sha256)
  temporary=$(mktemp "$(dirname -- "$output")/.migration.XXXXXX")
  tar -czf "$temporary" -C "$stage" .
  chmod 600 "$temporary"
  mv -f -- "$temporary" "$output"
  jq -M -n --arg output "$output" --arg hash "$(sha256sum "$output" | awk '{print $1}')" '{output:$output,sha256:$hash,contains_secrets:false,contains_knowledge:true}'
)

migration_extract_validate() {
  local deploy_dir=$1 input=$2 stage=$3 listing entry bytes count expected actual line path row source hash
  [[ -f "$input" && ! -L "$input" && $(stat -c '%s' "$input") -le 134217728 ]] || { configuration_error '迁移包无效或超过 128 MiB'; return 1; }
  listing=$(mktemp "${deploy_dir}/tmp/migration-list.XXXXXX")
  if ! tar -tzf "$input" > "$listing"; then rm -f -- "$listing"; return 1; fi
  count=$(wc -l < "$listing"); (( count <= 20000 )) || return 1
  [[ -z $(sed 's#^\./##;s#/$##' "$listing" | LC_ALL=C sort | uniq -d) ]] || { rm -f -- "$listing"; configuration_error '迁移包含重复路径'; return 1; }
  while IFS= read -r entry; do migration_allowed_path "$entry" || { configuration_error '迁移包包含未授权路径'; return 1; }; done < "$listing"
  if ! tar -tvzf "$input" > "$listing"; then rm -f -- "$listing"; return 1; fi
  while IFS= read -r entry; do [[ ${entry:0:1} == - || ${entry:0:1} == d ]] || { configuration_error '迁移包包含链接或特殊文件'; return 1; }; done < "$listing"
  bytes=$(awk '{total+=$3} END {printf "%.0f",total}' "$listing")
  rm -f -- "$listing"
  (( bytes <= 536870912 )) || { configuration_error '迁移包解压后超过 512 MiB'; return 1; }
  tar -xzf "$input" -C "$stage" --no-same-owner --no-same-permissions || return 1
  jq -M -e '.format == "ai-support-business-v2" and .contains_secrets == false and .contains_knowledge == true' "${stage}/manifest.json" >/dev/null || return 1
  [[ -f "${stage}/checksums.sha256" ]] || return 1
  while IFS= read -r line; do
    [[ "$line" =~ ^[a-f0-9]{64}[[:space:]][[:space:]].+ ]] || return 1
    path=${line#*  }; migration_allowed_path "$path" || return 1
  done < "${stage}/checksums.sha256"
  expected=$(sed -n 's/^[a-f0-9]\{64\}  //p' "${stage}/checksums.sha256" | sed 's#^\./##' | LC_ALL=C sort)
  actual=$(find "$stage" -type f ! -name checksums.sha256 -printf '%P\n' | LC_ALL=C sort)
  [[ "$expected" == "$actual" ]] || { configuration_error '迁移包清单与普通文件集合不一致'; return 1; }
  (cd -- "$stage"; sha256sum -c --strict checksums.sha256 >/dev/null) || return 1
  for entry in runtime handoff keyword menu tags feedback; do configuration_validate "$entry" "${stage}/config/${entry}.yaml" || return 1; done
  knowledge_catalog_validate "${stage}/knowledge/catalog.json" || return 1
  jq -M -e '.provider | type == "object" and (keys - ["type","base_url","model","api_mode","api_key_env"] | length == 0) and
    (.model | type == "string" and length > 0) and (.base_url | type == "string" and length > 0) and
    (.api_mode == "responses" or .api_mode == "chat_completions")' "${stage}/config/provider.yaml" >/dev/null || return 1
  normalize_api_base "$(jq -M -r '.provider.base_url' "${stage}/config/provider.yaml")" >/dev/null || return 1
  validate_model_identifier "$(jq -M -r '.provider.model' "${stage}/config/provider.yaml")" || return 1
  [[ -s "${stage}/config/prompt.md" && $(stat -c '%s' "${stage}/config/prompt.md") -le 262144 ]] || return 1
  while IFS= read -r row; do
    source=$(jq -M -r '.path' <<< "$row"); hash=$(jq -M -r '.sha256' <<< "$row")
    [[ -f "${stage}/knowledge/${source}" && $(sha256sum "${stage}/knowledge/${source}" | awk '{print $1}') == "$hash" ]] || return 1
  done < <(jq -M -c '.libraries[] | .id as $id | .documents[] | {path:($id+"/"+.source),sha256:.sha256}' "${stage}/knowledge/catalog.json")
}

migration_import() (
  local deploy_dir=$1 input=$2 preview=${3:-false} stage history name row library source temporary previous_revision current_revision
  stage=$(mktemp -d "${deploy_dir}/tmp/migration-import.XXXXXX")
  trap 'rm -rf -- "$stage"' EXIT
  migration_extract_validate "$deploy_dir" "$input" "$stage" || { configuration_error '迁移包校验失败，现有配置未改变'; return 1; }
  if [[ "$preview" == true ]]; then
    jq -M -n --slurpfile manifest "${stage}/manifest.json" --slurpfile catalog "${stage}/knowledge/catalog.json" '{manifest:$manifest[0],libraries:[$catalog[0].libraries[] | {id,name,enabled,documents:(.documents|length)}],mode:"替换业务配置并保留本机秘密"}'
    return 0
  fi
  acquire_maintenance_lock "$deploy_dir"
  configuration_runtime_init "$deploy_dir"
  history=$(mktemp -d "${deploy_dir}/backups/config-history/migration.XXXXXXXX")
  migration_export "$deploy_dir" "${history}/previous.tar.gz" >/dev/null || return 1
  tar -czf "${history}/local.tar.gz" -C "$deploy_dir" config knowledge .env
  chmod 600 "${history}/local.tar.gz"
  previous_revision=$(jq -M '.revision // 0' "${deploy_dir}/config/runtime.yaml")
  for name in runtime handoff keyword menu tags feedback; do
    temporary=$(mktemp "${deploy_dir}/config/${name}.yaml.tmp.XXXXXX")
    install -m 640 -- "${stage}/config/${name}.yaml" "$temporary"
    if [[ "$name" == runtime ]]; then
      jq -M --argjson previous "$previous_revision" '.revision=($previous+1) | .applied_revision=$previous' "${stage}/config/runtime.yaml" > "$temporary"
    fi
    chown root:1000 "$temporary" 2>/dev/null || true
    mv -f -- "$temporary" "${deploy_dir}/config/${name}.yaml"
  done
  cp -p -- "${stage}/knowledge/catalog.json" "${deploy_dir}/knowledge/catalog.json"
  while IFS= read -r row; do
    library=$(jq -M -r '.library' <<< "$row"); source=$(jq -M -r '.source' <<< "$row")
    install -D -m 640 -- "${stage}/knowledge/${library}/${source}" "${deploy_dir}/knowledge/${library}/${source}"
  done < <(jq -M -c '.libraries[] | .id as $library | .documents[] | {library:$library,source:.source}' "${stage}/knowledge/catalog.json")
  chown -R root:1000 "${deploy_dir}/knowledge" 2>/dev/null || true
  if configuration_prompt_apply "$deploy_dir" "${stage}/config/prompt.md" >/dev/null &&
    bash "${MIGRATION_SCRIPT_DIR}/provider.sh" --deploy-dir "$deploy_dir" apply "${stage}/config/provider.yaml" >/dev/null &&
    knowledge_sync_catalog "$deploy_dir" && configuration_readback "$deploy_dir" keyword.yaml; then
    configuration_revision "$deploy_dir" true
    jq -M -n --arg backup "${history}/local.tar.gz" '{applied:true,secrets_preserved:true,recovery_backup:$backup}'
    return 0
  fi
  current_revision=$(jq -M '.revision // 0' "${deploy_dir}/config/runtime.yaml")
  tar -xzf "${history}/local.tar.gz" -C "$deploy_dir" --no-same-owner
  temporary=$(mktemp "${deploy_dir}/config/runtime.yaml.tmp.XXXXXX")
  jq -M --argjson current "$current_revision" '.revision=($current+1) | .applied_revision=.revision' "${deploy_dir}/config/runtime.yaml" > "$temporary"
  chmod 640 "$temporary"; chown root:1000 "$temporary" 2>/dev/null || true
  mv -f -- "$temporary" "${deploy_dir}/config/runtime.yaml"
  sync_prompt_to_anythingllm "$deploy_dir" >&2 || true
  knowledge_sync_catalog "$deploy_dir" >&2 || true
  docker_compose "$deploy_dir" up -d provider-adapter anythingllm n8n >&2 || true
  configuration_error '导入应用失败，已恢复原配置与知识；请执行状态检查'
  return 1
)

migration_main() {
  local deploy_request='' action deploy_dir
  while (( $# )); do
    case "$1" in
      --deploy-dir) deploy_request=${2:?}; shift 2 ;;
      --help|-h) printf '%s\n' '用法：migration.sh [--deploy-dir PATH] export FILE | import-preview FILE | import FILE' '迁移包含业务知识原文，仍属敏感资料；不含 Key、Token、会话及本机内部密码。'; return ;;
      *) break ;;
    esac
  done
  action=${1:?}; shift
  deploy_dir=$(resolve_deploy_dir "$deploy_request")
  assert_managed_installation "$deploy_dir"
  case "$action" in
    export) migration_export "$deploy_dir" "${1:?}" ;;
    import-preview) migration_import "$deploy_dir" "${1:?}" true ;;
    import) migration_import "$deploy_dir" "${1:?}" ;;
    *) return 1 ;;
  esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then migration_main "$@"; fi
