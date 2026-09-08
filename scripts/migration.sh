#!/usr/bin/env bash
set -euo pipefail

MIGRATION_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/materials.sh
source "${MIGRATION_SCRIPT_DIR}/materials.sh"

migration_apply_legacy_provider() {
  local deploy_dir=$1 file=$2 candidate status=0
  candidate=$(mktemp "${deploy_dir}/tmp/migration-provider.XXXXXXXX")
  # 旧业务包的 type/api_key_env 是投影元数据，不是新版池编辑字段。
  # 只应用原有三元组，Key 和敏感 Header 仍使用本机同一主接口的保存值。
  if jq -M '{provider:(.provider | {base_url,model,api_mode})}' "$file" > "$candidate"; then
    bash "${MIGRATION_SCRIPT_DIR}/provider.sh" --deploy-dir "$deploy_dir" apply "$candidate" || status=$?
  else
    status=1
  fi
  rm -f -- "$candidate"
  return "$status"
}

migration_allowed_path() {
  local entry=${1#./}
  entry=${entry%/}
  [[ "$entry" != /* && "$entry" != *'..'* && "$entry" != *\\* && "$entry" != *$'\n'* && "$entry" != *$'\r'* ]] || return 1
  case "$entry" in
    ''|config|knowledge|n8n|VERSION|manifest.json|checksums.sha256|knowledge/catalog.json|n8n/workflow.json|config/runtime.yaml|config/provider.yaml|config/provider-pool.yaml|config/prompt.md|config/keyword.yaml|config/menu.yaml|config/handoff.yaml|config/tags.yaml|config/feedback.yaml) return 0 ;;
  esac
  [[ "$entry" =~ ^knowledge/kb_([a-f0-9]{16}|default)(/sources(/doc_[a-f0-9]{16}\.(md|txt|pdf|docx))?)?$ ]]
}

migration_archive_preflight() {
  local input=$1
  python3 - "$input" <<'PY'
import pathlib
import re
import sys
import tarfile

archive = pathlib.Path(sys.argv[1])
if archive.is_symlink() or not archive.is_file() or not 0 < archive.stat().st_size <= 128 * 1024 * 1024:
    raise SystemExit("迁移包无效或超过 128 MiB")
allowed_exact = {
    "", "config", "knowledge", "n8n", "VERSION", "manifest.json", "checksums.sha256",
    "knowledge/catalog.json", "n8n/workflow.json", "config/runtime.yaml", "config/provider.yaml",
    "config/prompt.md", "config/keyword.yaml", "config/menu.yaml", "config/handoff.yaml",
    "config/tags.yaml", "config/feedback.yaml", "config/provider-pool.yaml",
}
knowledge = re.compile(r"^knowledge/kb_(?:[a-f0-9]{16}|default)(?:/sources(?:/doc_[a-f0-9]{16}\.(?:md|txt|pdf|docx))?)?$")
seen = set()
total = 0
with tarfile.open(archive, "r:gz") as bundle:
    members = bundle.getmembers()
    if len(members) > 20000:
        raise SystemExit("迁移包成员超过 20000")
    for member in members:
        name = member.name
        while name.startswith("./"):
            name = name[2:]
        name = name.rstrip("/")
        if name == ".":
            name = ""
        parts = pathlib.PurePosixPath(name).parts
        if (not name and member.isfile()) or name.startswith("/") or "\\" in name or "\n" in name or "\r" in name or ".." in parts:
            raise SystemExit("迁移包包含不安全路径")
        if name in seen:
            raise SystemExit("迁移包包含重复路径")
        seen.add(name)
        if name not in allowed_exact and not knowledge.fullmatch(name):
            raise SystemExit("迁移包包含未授权路径")
        if not (member.isfile() or member.isdir()):
            raise SystemExit("迁移包包含链接或特殊文件")
        if member.isfile():
            total += member.size
            if total > 512 * 1024 * 1024:
                raise SystemExit("迁移包解压后超过 512 MiB")
            if "/sources/" in name and member.size > 50 * 1024 * 1024:
                raise SystemExit("单个知识文件超过 50 MiB")
PY
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
    configuration_normalize_file "$name" "${deploy_dir}/config/${name}.yaml" "${stage}/config/${name}.yaml" || return 1
    chmod 600 "${stage}/config/${name}.yaml"
  done
  temporary=$(mktemp "${stage}/config/runtime.XXXXXX")
  jq -M '.revision=0 | .applied_revision=0' "${stage}/config/runtime.yaml" > "$temporary"
  mv -f -- "$temporary" "${stage}/config/runtime.yaml"
  if jq -M -e '.provider | type == "object"' "${deploy_dir}/config/provider.yaml" >/dev/null 2>&1; then
    jq -M --arg base "$(env_get "${deploy_dir}/.env" AI_API_PROBE_BASE_URL 2>/dev/null || true)" '{schema_version:2,provider:{type:"openai-compatible",base_url:(if $base != "" then $base else .provider.base_url end),model:.provider.model,api_mode:.provider.api_mode,api_key_env:"AI_API_KEY"}}' "${deploy_dir}/config/provider.yaml" > "${stage}/config/provider.yaml"
  else
    jq -M -n --arg base "$(env_get "${deploy_dir}/.env" AI_API_PROBE_BASE_URL)" --arg model "$(env_get "${deploy_dir}/.env" AI_MODEL)" --arg mode "$(env_get "${deploy_dir}/.env" AI_API_MODE)" '{schema_version:2,provider:{type:"openai-compatible",base_url:$base,model:$model,api_mode:$mode,api_key_env:"AI_API_KEY"}}' > "${stage}/config/provider.yaml"
  fi
  if [[ -f "${deploy_dir}/config/provider-pool-applied.json" && ! -L "${deploy_dir}/config/provider-pool-applied.json" ]]; then
    python3 "${MIGRATION_SCRIPT_DIR}/provider-pool.py" --deploy-dir "$deploy_dir" list > "${stage}/pool.json" || return 1
    jq -M '{schema_version:1,revision:0,primary_id,entries:(.entries|map(del(.key_status))),policy}' \
      "${stage}/pool.json" > "${stage}/config/provider-pool.yaml"
    rm -f -- "${stage}/pool.json"
    python3 "${MIGRATION_SCRIPT_DIR}/provider-pool.py" --deploy-dir "$deploy_dir" validate-file \
      "${stage}/config/provider-pool.yaml" >/dev/null || return 1
    chmod 0600 "${stage}/config/provider-pool.yaml"
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
  jq -M -n --arg version "$(<"${stage}/VERSION")" '{format:"ai-support-business-v2",schema_version:2,version:$version,contains_secrets:false,contains_knowledge:true,requires_credentials:["各接口独立 API Key 及自定义认证 Header（按稳定接口 ID 匹配本机保留值）","CRISP_TOKEN_IDENTIFIER","CRISP_TOKEN_KEY","Webhook Secret"]}' > "${stage}/manifest.json"
  # shellcheck disable=SC2094
  (cd -- "$stage"; find . -type f ! -name checksums.sha256 -print0 | sort -z | xargs -0 sha256sum > checksums.sha256)
  temporary=$(mktemp "$(dirname -- "$output")/.migration.XXXXXX")
  tar -czf "$temporary" -C "$stage" .
  chmod 600 "$temporary"
  mv -f -- "$temporary" "$output"
  jq -M -n --arg output "$output" --arg hash "$(sha256sum "$output" | awk '{print $1}')" '{output:$output,sha256:$hash,contains_secrets:false,contains_knowledge:true}'
)

migration_extract_validate() {
  local deploy_dir=$1 input=$2 stage=$3 expected actual line path row source hash extension
  migration_archive_preflight "$input" || return 1
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
  configuration_prompt_candidate_validate "${stage}/config/prompt.md" || return 1
  if [[ -f "${stage}/config/provider-pool.yaml" ]]; then
    python3 "${MIGRATION_SCRIPT_DIR}/provider-pool.py" --deploy-dir "$deploy_dir" validate-file \
      "${stage}/config/provider-pool.yaml" >/dev/null || return 1
  fi
  while IFS= read -r row; do
    source=$(jq -M -r '.path' <<< "$row"); hash=$(jq -M -r '.sha256' <<< "$row")
    extension=${source##*.}; extension=${extension,,}
    knowledge_validate_document_file "${stage}/knowledge/${source}" "$extension" || return 1
    [[ $(sha256sum "${stage}/knowledge/${source}" | awk '{print $1}') == "$hash" ]] || return 1
  done < <(jq -M -c '.libraries[] | .id as $id | .documents[] | {path:($id+"/"+.source),sha256:.sha256}' "${stage}/knowledge/catalog.json")
}

migration_import() (
  local deploy_dir=$1 input=$2 preview=${3:-false} stage history name row library source temporary
  local candidate_knowledge restore_stage provider_restore_stage failed_knowledge materials_ok=false provider_ok=false knowledge_installed=false
  local materials_restored=false provider_restored=false knowledge_restored=false runtime_guarded=false guard_projection guard_revision
  local pool_result='{}' pool_applied=true pool_preview='null'
  local -a backup_paths=(config knowledge .env)
  stage=$(mktemp -d "${deploy_dir}/tmp/migration-import.XXXXXX")
  trap 'rm -rf -- "$stage"' EXIT
  migration_extract_validate "$deploy_dir" "$input" "$stage" || { configuration_error '迁移包校验失败，现有配置未改变'; return 1; }
  if [[ "$preview" == true ]]; then
    if [[ -f "${stage}/config/provider-pool.yaml" ]]; then
      pool_preview=$(jq -Mc '{primary_id,entries:[.entries[]|{id,name,role,enabled,model,api_mode}],policy}' "${stage}/config/provider-pool.yaml")
    fi
    jq -M -n --slurpfile manifest "${stage}/manifest.json" --slurpfile catalog "${stage}/knowledge/catalog.json" --argjson pool "$pool_preview" \
      '{manifest:$manifest[0],libraries:[$catalog[0].libraries[] | {id,name,enabled,documents:(.documents|length)}],provider_pool:$pool,mode:"替换业务配置并保留本机秘密；缺少接口 Key 的项目仅保存停用草稿"}'
    return 0
  fi
  acquire_maintenance_lock "$deploy_dir"
  configuration_runtime_init "$deploy_dir"
  configuration_materials_ensure "$deploy_dir" || return 1
  history=$(mktemp -d "${deploy_dir}/backups/config-history/migration.XXXXXXXX")
  migration_export "$deploy_dir" "${history}/previous.tar.gz" >/dev/null || return 1
  if [[ -d "${deploy_dir}/secrets" && ! -L "${deploy_dir}/secrets" ]]; then
    if find "${deploy_dir}/secrets" -mindepth 1 ! -type d ! -type f -print -quit | grep -q .; then
      configuration_error '接口秘密目录不安全，导入未开始'
      return 1
    fi
    backup_paths+=(secrets)
  fi
  tar -czf "${history}/local.tar.gz" -C "$deploy_dir" "${backup_paths[@]}"
  chmod 600 "${history}/local.tar.gz"
  for name in runtime handoff keyword menu tags feedback; do
    temporary=$(mktemp "${deploy_dir}/config/${name}.yaml.tmp.XXXXXX")
    configuration_normalize_file "$name" "${stage}/config/${name}.yaml" "$temporary" || return 1
    chmod 0640 "$temporary"
    chown root:1000 "$temporary" 2>/dev/null || true
    mv -f -- "$temporary" "${deploy_dir}/config/${name}.yaml"
  done
  temporary=$(mktemp "${deploy_dir}/config/prompt.md.tmp.XXXXXX")
  install -m 640 -- "${stage}/config/prompt.md" "$temporary"
  chown root:1000 "$temporary" 2>/dev/null || true
  mv -f -- "$temporary" "${deploy_dir}/config/prompt.md"

  candidate_knowledge="${stage}/candidate-knowledge"
  mkdir -p -- "$candidate_knowledge"
  install -m 640 -- "${stage}/knowledge/catalog.json" "${candidate_knowledge}/catalog.json"
  while IFS= read -r library; do
    mkdir -p -- "${candidate_knowledge}/${library}/sources"
  done < <(jq -M -r '.libraries[].id' "${stage}/knowledge/catalog.json")
  while IFS= read -r row; do
    library=$(jq -M -r '.library' <<< "$row"); source=$(jq -M -r '.source' <<< "$row")
    install -D -m 640 -- "${stage}/knowledge/${library}/${source}" "${candidate_knowledge}/${library}/${source}"
  done < <(jq -M -c '.libraries[] | .id as $library | .documents[] | {library:$library,source:.source}' "${stage}/knowledge/catalog.json")
  find "$candidate_knowledge" -type d -exec chmod 750 {} +
  chown -R root:1000 "$candidate_knowledge" 2>/dev/null || true
  if knowledge_replace_root_contents "${deploy_dir}/knowledge" "$candidate_knowledge" "${history}/pre-import-knowledge"; then
    knowledge_installed=true
  fi

  if [[ "$knowledge_installed" == true ]] && bash "${MIGRATION_SCRIPT_DIR}/materials.sh" --deploy-dir "$deploy_dir" apply-business >/dev/null; then
    materials_ok=true
  fi
  if [[ "$materials_ok" == true ]]; then
    if [[ -f "${stage}/config/provider-pool.yaml" ]]; then
      if pool_result=$(python3 "${MIGRATION_SCRIPT_DIR}/provider-pool.py" --deploy-dir "$deploy_dir" import "${stage}/config/provider-pool.yaml") \
        && jq -e '.ok == true' <<< "$pool_result" >/dev/null; then
        provider_ok=true
        pool_applied=$(jq -r 'if .applied == false then false else true end' <<< "$pool_result")
      fi
    elif migration_apply_legacy_provider "$deploy_dir" "${stage}/config/provider.yaml" >/dev/null; then
      provider_ok=true
    fi
  fi
  if [[ "$materials_ok" == true && "$provider_ok" == true ]]; then
    jq -M -n --arg backup "${history}/local.tar.gz" --argjson revision "$(jq -M -r '.revision' "${deploy_dir}/config/materials-applied.json")" \
      --argjson pool_applied "$pool_applied" --argjson pool "$pool_result" \
      '{applied:$pool_applied,business_applied:true,provider_pool_applied:$pool_applied,draft:($pool_applied|not),
        secrets_preserved:true,recovery_backup:$backup,revision:$revision,
        missing_credentials:[$pool.entries[]?|select(.draft == true)|{id,name}],
        message:(if $pool_applied then "业务配置已应用，接口秘密按本机稳定 ID 保留" else "业务资料已应用；导入主接口缺少 Key，接口池仅保存草稿，原有效池继续工作。请到菜单 3 补齐并应用草稿" end)}'
    return 0
  fi

  restore_stage=$(mktemp -d "${deploy_dir}/tmp/migration-restore.XXXXXXXX")
  tar -xzf "${history}/local.tar.gz" -C "$restore_stage" --no-same-owner --no-same-permissions
  for name in runtime handoff keyword menu tags feedback; do
    temporary=$(mktemp "${deploy_dir}/config/${name}.yaml.tmp.XXXXXX")
    install -m 640 -- "${restore_stage}/config/${name}.yaml" "$temporary"
    chown root:1000 "$temporary" 2>/dev/null || true
    mv -f -- "$temporary" "${deploy_dir}/config/${name}.yaml"
  done
  temporary=$(mktemp "${deploy_dir}/config/prompt.md.tmp.XXXXXX")
  install -m 640 -- "${restore_stage}/config/prompt.md" "$temporary"
  chown root:1000 "$temporary" 2>/dev/null || true
  mv -f -- "$temporary" "${deploy_dir}/config/prompt.md"
  temporary=$(mktemp "${deploy_dir}/.env.tmp.XXXXXX")
  install -m 600 -- "${restore_stage}/.env" "$temporary"
  mv -f -- "$temporary" "${deploy_dir}/.env"
  failed_knowledge="${history}/failed-import-knowledge"
  if knowledge_replace_root_contents "${deploy_dir}/knowledge" "${restore_stage}/knowledge" "$failed_knowledge"; then
    knowledge_restored=true
    chown -R root:1000 "${deploy_dir}/knowledge" 2>/dev/null || true
  fi
  if [[ "$knowledge_restored" == true ]] &&
    bash "${MIGRATION_SCRIPT_DIR}/materials.sh" --deploy-dir "$deploy_dir" apply-business >/dev/null 2>&1 &&
    bash "${MIGRATION_SCRIPT_DIR}/materials.sh" --deploy-dir "$deploy_dir" status >/dev/null 2>&1; then
    materials_restored=true
  fi
  provider_restore_stage=$(mktemp -d "${deploy_dir}/tmp/migration-provider-restore.XXXXXXXX")
  if tar -xzf "${history}/previous.tar.gz" -C "$provider_restore_stage" --no-same-owner --no-same-permissions; then
    if [[ -f "${provider_restore_stage}/config/provider-pool.yaml" ]]; then
      if python3 "${MIGRATION_SCRIPT_DIR}/provider-pool.py" --deploy-dir "$deploy_dir" apply-file "${provider_restore_stage}/config/provider-pool.yaml" >/dev/null 2>&1; then
        provider_restored=true
      fi
    elif migration_apply_legacy_provider "$deploy_dir" "${provider_restore_stage}/config/provider.yaml" >/dev/null 2>&1; then
      provider_restored=true
    fi
  fi
  rm -rf -- "$provider_restore_stage"
  if [[ "$materials_restored" == true && "$provider_restored" != true ]]; then
    guard_projection=$(mktemp "${deploy_dir}/tmp/migration-provider-guard.XXXXXX")
    install -m 600 -- "${deploy_dir}/config/materials-applied.json" "$guard_projection"
    if materials_projection_validate "$guard_projection"; then
      guard_revision=$(( $(jq -M -r '.revision' "$guard_projection") + 1 ))
      if materials_publish_old_generation "$deploy_dir" "$guard_projection" "$guard_revision" applying; then
        runtime_guarded=true
      fi
    fi
    rm -f -- "$guard_projection"
  fi
  if [[ "$knowledge_restored" == true && "$materials_restored" == true && "$provider_restored" == true ]]; then
    configuration_error '导入应用失败；原配置、知识和外部接线已回读恢复'
  elif [[ "$materials_restored" != true ]]; then
    configuration_error "导入应用失败，资料恢复未完全确认（知识目录=${knowledge_restored}）；自动回复保持受阻止状态，请重试资料应用或执行完整恢复"
  elif [[ "$provider_restored" != true ]]; then
    if [[ "$runtime_guarded" == true ]]; then
      configuration_error '导入应用失败，原资料与知识已恢复，但 Provider 恢复未完全确认；运行投影保持 applying，自动回复已阻止'
    else
      configuration_error '导入应用失败，Provider 恢复未确认且无法写入受阻止投影；请立即停用客服总开关并执行完整恢复'
    fi
  else
    configuration_error '导入应用失败，知识目录恢复未完全确认；请执行完整恢复'
  fi
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
