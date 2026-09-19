#!/usr/bin/env bash
set -euo pipefail

PROFILE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/materials.sh
source "${PROFILE_DIR}/materials.sh"

knowledge_component() {
  local deploy=$1 action=$2 output=$3 seconds=45 workspace
  shift 3
  [[ "$action" != probe ]] || seconds=900
  workspace=$(env_get "${deploy}/.env" ANYTHINGLLM_WORKSPACE)
  [[ "$workspace" =~ ^[A-Za-z0-9_-]{1,128}$ ]] || return 1
  local -a command=(docker compose --project-directory "$deploy" --env-file "${deploy}/.env" -f "${deploy}/docker-compose.yml")
  if ! timeout --signal=TERM --kill-after=10s "$seconds" "${command[@]}" exec -T anythingllm \
    node - "$action" "$workspace" "$@" < "${PROFILE_DIR}/knowledge-component.js" > "$output" 2>/dev/null; then
    configuration_error '知识组件读取或模型准备未完成，未确认索引可用'
    return 1
  fi
  chmod 600 "$output" || return 1
  jq -e '.engine == "native" and (.model|type=="string") and (.chunk_size|type=="number") and (.chunk_overlap|type=="number")' "$output" >/dev/null \
    || return 1
}

knowledge_profile_valid_model() {
  case "$1" in
    Xenova/all-MiniLM-L6-v2|Xenova/nomic-embed-text-v1|MintplexLabs/multilingual-e5-small) return 0 ;;
    *) configuration_error '知识模型不在固定组件的已验证 Native 名单内'; return 1 ;;
  esac
}

knowledge_profile_capture() {
  local deploy=$1 active desired observed model explicit=false memory_kib=0 persisted=''
  active=$(env_get "${deploy}/.env" KNOWLEDGE_ACTIVE_EMBEDDING_MODEL 2>/dev/null || true)
  desired=$(env_get "${deploy}/.env" KNOWLEDGE_EMBEDDING_MODEL 2>/dev/null || true)
  if [[ -n "$active" ]]; then
    knowledge_profile_valid_model "$active" || return 1
    if [[ -z "$desired" ]]; then
      env_set "${deploy}/.env" KNOWLEDGE_EMBEDDING_MODEL "$active" || return 1
    else
      knowledge_profile_valid_model "$desired" || return 1
    fi
    return 0
  fi
  model=Xenova/all-MiniLM-L6-v2
  persisted=$(env_get "${deploy}/data/anythingllm/.env" EMBEDDING_MODEL_PREF 2>/dev/null || true)
  if [[ -n "$persisted" ]]; then
    knowledge_profile_valid_model "$persisted" || return 1
    model=$persisted
    explicit=true
  fi
  if [[ -f "${deploy}/data/anythingllm/anythingllm.db" ]]; then
    observed=$(mktemp "${deploy}/tmp/knowledge-observe.XXXXXXXX") || return 1
    if knowledge_component "$deploy" observe "$observed"; then
      model=$(jq -er '.model' "$observed") || { rm -f -- "$observed"; return 1; }
      if [[ "$explicit" != true ]]; then
        explicit=$(jq -er '.explicit_model | tostring' "$observed") \
          || { rm -f -- "$observed"; return 1; }
      fi
    elif [[ -z "$persisted" ]]; then
      # 固定旧版未显式配置时就是 MiniLM；先投影该值，启动后 ensure 仍会实际回读。
      warn '旧知识容器当前不可读取；按固定版本缺省模型启动，启动后将再次严格核对'
    fi
    rm -f -- "$observed" || return 1
  fi
  knowledge_profile_valid_model "$model" || return 1
  if [[ -z "$desired" ]]; then
    memory_kib=$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null || printf 0)
    if [[ "$explicit" == true || ! "$memory_kib" =~ ^[0-9]+$ || "$memory_kib" -lt 6291456 ]]; then
      desired=$model
      [[ "$explicit" == true ]] || warn '当前内存不足以安全自动切换多语言知识模型；保留原模型并使用词法补召回'
    else
      desired=MintplexLabs/multilingual-e5-small
    fi
  fi
  knowledge_profile_valid_model "$desired" || return 1
  # active 只是迁移生成的投影；先保留旧模型启动，绝不能新模型读取旧向量。
  env_set "${deploy}/.env" KNOWLEDGE_ACTIVE_EMBEDDING_MODEL "$model" || return 1
  env_set "${deploy}/.env" KNOWLEDGE_EMBEDDING_MODEL "$desired" || return 1
}

knowledge_profile_wait() {
  local deploy=$1 port end=$((SECONDS + 180))
  port=$(env_get "${deploy}/.env" ANYTHINGLLM_PORT 2>/dev/null || true)
  port=${port:-3001}
  validate_port "$port" || return 1
  while (( SECONDS < end )); do
    if curl -q --fail --silent --connect-timeout 3 --max-time 5 "http://127.0.0.1:${port}/api/ping" >/dev/null; then return 0; fi
    sleep 2
  done
  return 1
}

knowledge_profile_backup_path_valid() {
  local deploy=$1 backup=$2 owner
  [[ "$backup" == "${deploy}/backups/knowledge-profiles/"generation.* \
    && -d "$backup" && ! -L "$backup" \
    && $(stat -c '%a' -- "$backup" 2>/dev/null) == 700 ]] || return 1
  owner=$(stat -c '%u' -- "$backup" 2>/dev/null) || return 1
  [[ "$owner" == "$(id -u)" ]]
}

# pointer 在停止组件前先持久发布。若进程在完整保全形成前中断，live
# AnythingLLM 尚未被替换；确认旧服务重新可用后，才允许清除该未完成事务。
knowledge_profile_recover_incomplete_pointer() {
  local deploy=$1 pointer=$2 backup=$3
  knowledge_profile_backup_path_valid "$deploy" "$backup" || return 1
  [[ ! -e "${backup}/complete.json" && ! -L "${backup}/complete.json" ]] || return 1
  [[ -f "$pointer" && ! -L "$pointer" ]] || return 1
  docker_compose "$deploy" up -d --no-deps anythingllm >/dev/null || return 1
  knowledge_profile_wait "$deploy" || return 1
  rm -f -- "$pointer" || return 1
  if ! rm -rf -- "$backup"; then
    warn '旧知识服务已恢复；未完成保全目录暂未清理，可在确认无活动引用后清理'
  fi
  return 0
}

knowledge_profile_restore() {
  local deploy=$1 backup=$2 previous old revision state schema current_revision old_revision revision_base
  local old_editable='' live_editable='' editable_matches=false editable_status=0
  knowledge_profile_backup_path_valid "$deploy" "$backup" \
    && [[ -f "${backup}/complete.json" && ! -L "${backup}/complete.json" ]] || return 1
  previous=$(jq -er '.previous_model' "${backup}/plan.json") || return 1
  knowledge_profile_valid_model "$previous" || return 1
  docker_compose "$deploy" stop --timeout 30 anythingllm >/dev/null || return 1
  python3 "${PROFILE_DIR}/knowledge-profile.py" --deploy-dir "$deploy" restore --backup "$backup" >/dev/null || return 1
  env_set "${deploy}/.env" KNOWLEDGE_ACTIVE_EMBEDDING_MODEL "$previous" || return 1
  docker_compose "$deploy" up -d --no-deps --force-recreate anythingllm >/dev/null || return 1
  knowledge_profile_wait "$deploy" || return 1
  # Python restore 已对 metadata 清单及逐文件摘要完成校验；恢复投影必须只取这份
  # 同一 complete.json 绑定的副本，不能信任另存且未入清单的旁路文件。
  old="${backup}/metadata/config/materials-applied.json"
  if [[ -f "$old" ]]; then
    [[ -f "${deploy}/config/materials-applied.json" \
      && ! -L "${deploy}/config/materials-applied.json" ]] || return 1
    current_revision=$(jq -M -er \
      '.revision | select(type == "number" and floor == . and . >= 1 and . < 2147483647)' \
      "${deploy}/config/materials-applied.json") || return 1
    old_revision=$(jq -M -er \
      '.revision | select(type == "number" and floor == . and . >= 1 and . < 2147483647)' \
      "$old") || return 1
    if (( current_revision >= old_revision )); then revision_base=$current_revision; else revision_base=$old_revision; fi
    revision=$(( revision_base + 1 ))
    state=$(jq -M -er '.state | select(. == "applied" or . == "applying")' "$old") || return 1
    schema=$(jq -M -er '.schema_version | select(. == 1 or . == 2)' "$old") || return 1
    materials_publish_old_generation "$deploy" "$old" "$revision" "$state" || return 1
    old_editable=$(mktemp "${deploy}/tmp/knowledge-restore-old-editable.XXXXXXXX") || return 1
    live_editable=$(mktemp "${deploy}/tmp/knowledge-restore-live-editable.XXXXXXXX") \
      || { rm -f -- "$old_editable"; return 1; }
    if ! materials_projection_editable_identity "$old" "$old_editable" \
      || ! materials_editable_identity_capture "$deploy" "$live_editable" 2>/dev/null; then
      rm -f -- "$old_editable" "$live_editable"
      return 1
    fi
    if cmp -s -- "$old_editable" "$live_editable"; then
      editable_matches=true
    else
      editable_status=$?
      [[ "$editable_status" -eq 1 ]] \
        || { rm -f -- "$old_editable" "$live_editable"; return 1; }
    fi
    rm -f -- "$old_editable" "$live_editable" || return 1
    # live 可编辑资料已成为 B 时不修改其 runtime revision/applied_revision；
    # 服务继续消费旧投影 A，B 由 materials status 明确显示待应用。
    if [[ "$editable_matches" == true ]]; then
      materials_finalize_runtime_source "$deploy" "$revision" || return 1
    fi
    if [[ "$schema" == 1 ]]; then
      # 旧 schema 升级必须消费 live 原文；若已出现 B，宁可保留
      # applying 现场而不把 B 隐式发布。当前 v1.2.x 正式投影为 schema 2。
      [[ "$editable_matches" == true ]] || return 1
      materials_initialize "$deploy" >/dev/null || return 1
    fi
    materials_applied_external_readback "$deploy" \
      "${deploy}/backups/config-history/materials.applied.tar.gz" \
      "${deploy}/config/materials-applied.json" || return 1
  elif [[ -e "${deploy}/config/materials-applied.json" \
    || -L "${deploy}/config/materials-applied.json" \
    || -e "${deploy}/backups/config-history/materials.applied.tar.gz" \
    || -L "${deploy}/backups/config-history/materials.applied.tar.gz" ]]; then
    return 1
  fi
  if [[ -e "${deploy}/data/runtime/knowledge-migration.json" \
    || -L "${deploy}/data/runtime/knowledge-migration.json" ]]; then
    [[ -f "${deploy}/data/runtime/knowledge-migration.json" \
      && ! -L "${deploy}/data/runtime/knowledge-migration.json" ]] \
      && rm -f -- "${deploy}/data/runtime/knowledge-migration.json" || return 1
  fi
}

knowledge_profile_ensure() (
  local deploy=$1 observed plan desired active size backup='' old='' stage='' pointer="${1}/data/runtime/knowledge-migration.json"
  local revision=1 current_revision='' changed=false completed=false result=0 materials_state='' materials_status_code=0
  local frozen_editable='' projection_editable='' candidate_editable='' editable_changed=false cleanup_result=0
  local editable_status=0
  # 中断保留 applying 和受限保全，由同一入口明确恢复；不会触碰人工/offer/jobs。
  trap 'trap "" INT TERM; configuration_error "知识索引迁移已中断，资料和受限保全保留；请用同一入口继续"; exit 130' INT
  trap 'trap "" INT TERM; configuration_error "知识索引迁移已中断，资料和受限保全保留；请用同一入口继续"; exit 143' TERM
  acquire_maintenance_lock "$deploy"
  if [[ -e "$pointer" || -L "$pointer" ]]; then
    [[ -f "$pointer" && ! -L "$pointer" ]] || return 1
    backup=$(jq -M -er '
      select(.schema_version == 1 and (.backup | type == "string")) | .backup
    ' "$pointer") || return 1
    knowledge_profile_backup_path_valid "$deploy" "$backup" || return 1
    if [[ -e "${backup}/complete.json" || -L "${backup}/complete.json" ]]; then
      [[ -f "${backup}/complete.json" && ! -L "${backup}/complete.json" ]] \
        && knowledge_profile_restore "$deploy" "$backup" \
        || { configuration_error '上次知识迁移尚未成套恢复，自动回复保持受阻止；未强启混合索引'; return 1; }
    else
      knowledge_profile_recover_incomplete_pointer "$deploy" "$pointer" "$backup" \
        || { configuration_error '上次知识迁移在完整保全前中断，旧服务尚未确认恢复；自动回复保持受阻止'; return 1; }
    fi
    backup=''
  fi
  knowledge_profile_capture "$deploy" || return 1
  observed=$(mktemp "${deploy}/tmp/knowledge-profile-observe.XXXXXXXX") || return 1
  plan=$(mktemp "${deploy}/tmp/knowledge-profile-plan.XXXXXXXX") \
    || { rm -f -- "$observed"; return 1; }
  if ! knowledge_component "$deploy" observe "$observed"; then rm -f -- "$observed" "$plan"; return 1; fi
  desired=$(env_get "${deploy}/.env" KNOWLEDGE_EMBEDDING_MODEL) \
    || { rm -f -- "$observed" "$plan"; return 1; }
  active=$(jq -er '.model' "$observed") \
    || { rm -f -- "$observed" "$plan"; return 1; }
  size=$(env_get "${deploy}/.env" KNOWLEDGE_CHUNK_SIZE 2>/dev/null || true)
  if [[ -z "$size" && "$desired" == MintplexLabs/multilingual-e5-small && "$active" != "$desired" \
    && $(jq -er '.explicit_chunk_size | tostring' "$observed") == false ]]; then
    # 固定模型 tokenizer 最多 512 token；400 字符避免长中文 FAQ 块在向量前被整段截尾。
    size=400
  fi
  local -a arguments=(--deploy-dir "$deploy" plan --observed "$observed" --model "$desired")
  [[ -z "$size" ]] || arguments+=(--chunk-size "$size")
  if ! python3 "${PROFILE_DIR}/knowledge-profile.py" "${arguments[@]}" > "$plan"; then rm -f -- "$observed" "$plan"; return 1; fi
  changed=$(jq -er '.requires_reindex | tostring' "$plan") \
    || { rm -f -- "$observed" "$plan"; return 1; }
  if [[ "$changed" == false ]]; then rm -f -- "$observed" "$plan"; return 0; fi
  if [[ -f "${deploy}/config/materials-applied.json" && ! -L "${deploy}/config/materials-applied.json" ]]; then
    materials_state=$(mktemp "${deploy}/tmp/knowledge-materials-status.XXXXXXXX") || return 1
    if materials_status "$deploy" > "$materials_state"; then
      materials_status_code=0
    else
      materials_status_code=$?
    fi
    if (( materials_status_code == 1 )) || ! jq -e '
      .source_valid == true and .projection_valid == true and .state == "applied"
    ' "$materials_state" >/dev/null; then
      rm -f -- "$materials_state" "$observed" "$plan"
      configuration_error '当前资料投影无效；未开始知识模型迁移'
      return 1
    fi
    if ! jq -e '.source_sha256 == .applied_sha256' "$materials_state" >/dev/null; then
      rm -f -- "$materials_state" "$observed" "$plan"
      configuration_error '存在尚未应用的 Prompt、知识或业务配置；请先明确应用或撤销后再迁移知识模型'
      return 1
    fi
    rm -f -- "$materials_state"
  fi
  knowledge_catalog_migrate "$deploy" \
    || { rm -f -- "$observed" "$plan"; return 1; }
  frozen_editable=$(mktemp "${deploy}/tmp/knowledge-editable-frozen.XXXXXXXX") || return 1
  if ! materials_editable_identity_capture "$deploy" "$frozen_editable"; then
    rm -f -- "$frozen_editable" "$observed" "$plan"
    configuration_error '当前 Prompt、知识或业务配置无法稳定读取；未开始知识模型迁移'
    return 1
  fi
  if [[ -f "${deploy}/config/materials-applied.json" ]]; then
    projection_editable=$(mktemp "${deploy}/tmp/knowledge-editable-applied.XXXXXXXX") \
      || { rm -f -- "$frozen_editable" "$observed" "$plan"; return 1; }
    if ! materials_projection_editable_identity "${deploy}/config/materials-applied.json" "$projection_editable" \
      || ! cmp -s -- "$frozen_editable" "$projection_editable"; then
      rm -f -- "$frozen_editable" "$projection_editable" "$observed" "$plan"
      configuration_error '当前可编辑资料与已应用代不一致；请先明确应用或撤销后再迁移知识模型'
      return 1
    fi
  fi
  mkdir -p -- "${deploy}/backups/knowledge-profiles" \
    || { rm -f -- "$frozen_editable" "$projection_editable" "$observed" "$plan"; return 1; }
  chmod 700 "${deploy}/backups/knowledge-profiles" \
    || { rm -f -- "$frozen_editable" "$projection_editable" "$observed" "$plan"; return 1; }
  if [[ -f "${deploy}/config/materials-applied.json" ]]; then
    [[ -f "${deploy}/backups/config-history/materials.applied.tar.gz" \
      && ! -L "${deploy}/backups/config-history/materials.applied.tar.gz" ]] \
      && materials_snapshot_validate_generation "$deploy" \
        "${deploy}/backups/config-history/materials.applied.tar.gz" \
        "${deploy}/config/materials-applied.json" \
      && materials_applied_external_readback "$deploy" \
        "${deploy}/backups/config-history/materials.applied.tar.gz" \
        "${deploy}/config/materials-applied.json" \
      || { configuration_error '当前资料原文、索引与投影不是同一已应用代；未开始知识迁移'; return 1; }
    old=$(mktemp "${deploy}/tmp/knowledge-old-projection.XXXXXXXX") \
      || return 1
    install -m 600 -- "${deploy}/config/materials-applied.json" "$old" \
      || { rm -f -- "$old"; return 1; }
    current_revision=$(jq -M -er \
      '.revision | select(type == "number" and floor == . and . >= 1 and . < 2147483647)' \
      "$old") || { rm -f -- "$old"; return 1; }
    revision=$(( current_revision + 1 ))
  fi
  backup=$(mktemp -d "${deploy}/backups/knowledge-profiles/generation.XXXXXXXX") \
    || { rm -f -- "${old:-}"; return 1; }
  local temporary=''
  if ! temporary=$(mktemp "${pointer}.tmp.XXXXXXXX") \
    || ! jq -n --arg backup "$backup" '{schema_version:1,backup:$backup}' > "$temporary" \
    || ! chmod 600 "$temporary" \
    || ! mv -f -- "$temporary" "$pointer"; then
    [[ -z "$temporary" ]] || rm -f -- "$temporary"
    rm -rf -- "$backup"
    rm -f -- "$old" "$frozen_editable" "$projection_editable" "$observed" "$plan"
    configuration_error '未能建立知识迁移恢复索引；旧服务和资料保持不变'
    return 1
  fi
  if [[ $(jq -M -er 'select(.schema_version == 1) | .backup' "$pointer" 2>/dev/null || true) != "$backup" ]]; then
    if knowledge_profile_recover_incomplete_pointer "$deploy" "$pointer" "$backup"; then
      configuration_error '知识迁移恢复索引回读不一致；旧服务已确认恢复，未开始迁移'
    else
      configuration_error '知识迁移恢复索引回读不一致且旧服务尚未确认恢复；保留现场并阻止自动回复'
    fi
    rm -f -- "$old" "$frozen_editable" "$projection_editable" "$observed" "$plan"
    return 1
  fi
  info '正在保全知识组件并重建模型对应索引；该期间自动回复暂停，人工控制事件仍可接收'
  docker_compose "$deploy" stop --timeout 30 anythingllm >/dev/null || return 1
  if ! python3 "${PROFILE_DIR}/knowledge-profile.py" --deploy-dir "$deploy" backup --plan "$plan" --backup "$backup" >/dev/null; then
    if knowledge_profile_recover_incomplete_pointer "$deploy" "$pointer" "$backup"; then
      configuration_error '知识组件保全失败，未切换模型；旧服务已恢复，原资料保持不变'
    else
      configuration_error '知识组件保全失败且旧服务尚未确认恢复；自动回复保持受阻止，保留恢复索引'
    fi
    return 1
  fi
  if (( result == 0 )) && [[ -n "$old" ]] \
    && ! materials_publish_old_generation "$deploy" "$old" "$revision" applying; then result=1; fi
  if (( result == 0 )) && ! python3 "${PROFILE_DIR}/knowledge-profile.py" --deploy-dir "$deploy" activate --backup "$backup" >/dev/null; then result=1; fi
  if (( result == 0 )); then
    env_set "${deploy}/.env" KNOWLEDGE_ACTIVE_EMBEDDING_MODEL "$desired" || result=1
  fi
  if (( result == 0 )); then
    docker_compose "$deploy" up -d --no-deps --force-recreate anythingllm >/dev/null || result=1
  fi
  if (( result == 0 )); then knowledge_profile_wait "$deploy" || result=1; fi
  if (( result == 0 )); then
    knowledge_component "$deploy" configure-chunks "$observed" "$(jq -er '.profile.chunk_size' "$plan")" "$(jq -er '.profile.chunk_overlap' "$plan")" || result=1
  fi
  if (( result == 0 )); then
    if materials_editable_identity_compare_live "$deploy" "$frozen_editable"; then :; else
      editable_status=$?
      [[ "$editable_status" -eq 1 ]] && editable_changed=true
      result=1
    fi
  fi
  if (( result == 0 )); then
    knowledge_sync_catalog "$deploy" 1 all true || result=1
  fi
  if (( result == 0 )); then
    if materials_editable_identity_compare_live "$deploy" "$frozen_editable"; then :; else
      editable_status=$?
      [[ "$editable_status" -eq 1 ]] && editable_changed=true
      result=1
    fi
  fi
  if (( result == 0 )); then
    knowledge_component "$deploy" observe "$observed" \
      && python3 "${PROFILE_DIR}/knowledge-profile.py" --deploy-dir "$deploy" commit --backup "$backup" --observed "$observed" >/dev/null \
      || result=1
  fi
  if (( result == 0 )); then
    if materials_editable_identity_compare_live "$deploy" "$frozen_editable"; then :; else
      editable_status=$?
      [[ "$editable_status" -eq 1 ]] && editable_changed=true
      result=1
    fi
  fi
  if (( result == 0 )); then
    knowledge_catalog_readback "$deploy" all true || result=1
  fi
  if (( result == 0 )); then
    if materials_editable_identity_compare_live "$deploy" "$frozen_editable"; then :; else
      editable_status=$?
      [[ "$editable_status" -eq 1 ]] && editable_changed=true
      result=1
    fi
  fi
  if (( result == 0 )) && [[ -n "$old" ]]; then
    stage=$(mktemp -d "${deploy}/tmp/knowledge-profile-final.XXXXXXXX") || result=1
  fi
  if (( result == 0 )) && [[ -n "$old" ]]; then
    configuration_prompt_verify_file "$deploy" "${deploy}/config/prompt.md" \
      && materials_finalize_runtime_source "$deploy" "$revision" \
      && materials_prepare_candidate "$deploy" "$stage" "$revision" applied || result=1
  fi
  if (( result == 0 )) && [[ -n "$old" ]]; then
    candidate_editable=$(mktemp "${deploy}/tmp/knowledge-editable-candidate.XXXXXXXX") || result=1
  fi
  if (( result == 0 )) && [[ -n "$old" ]]; then
    if ! materials_projection_editable_identity "${stage}/materials-applied.json" "$candidate_editable"; then
      result=1
    elif ! cmp -s -- "$frozen_editable" "$candidate_editable"; then
      editable_changed=true
      result=1
    elif materials_editable_identity_compare_live "$deploy" "$frozen_editable"; then
      :
    else
      editable_status=$?
      [[ "$editable_status" -eq 1 ]] && editable_changed=true
      result=1
    fi
  fi
  if (( result == 0 )) && [[ -n "$old" ]]; then
    materials_snapshot_create "$deploy" "${stage}/materials.applied.tar.gz" \
      && materials_snapshot_validate_generation "$deploy" "${stage}/materials.applied.tar.gz" \
        "${stage}/materials-applied.json" \
      && materials_snapshot_publish "$deploy" "${stage}/materials.applied.tar.gz" \
        "${deploy}/backups/config-history/materials.applied.tar.gz" \
      && materials_projection_write_current "$deploy" "${stage}/materials-applied.json" \
      && materials_applied_external_readback "$deploy" \
        "${deploy}/backups/config-history/materials.applied.tar.gz" \
        "${deploy}/config/materials-applied.json" || result=1
  fi
  if (( result != 0 )) && [[ "$editable_changed" == false ]]; then
    if materials_editable_identity_compare_live "$deploy" "$frozen_editable"; then :; else
      editable_status=$?
      [[ "$editable_status" -eq 1 ]] && editable_changed=true
    fi
  fi
  if (( result == 0 )); then
    if [[ -f "$pointer" && ! -L "$pointer" ]] && rm -f -- "$pointer"; then
      completed=true
      info '知识模型、文档索引和运行映射已对账；旧组件保全受限保留在 backups/knowledge-profiles'
    else
      result=1
    fi
  fi
  if (( result != 0 )) && knowledge_profile_restore "$deploy" "$backup"; then
    if [[ "$editable_changed" == true ]]; then
      configuration_error '迁移期间检测到可编辑资料发生变化；已恢复上一运行代，新编辑保留为待应用'
    else
      configuration_error '知识索引迁移未完成，已恢复原组件和索引；用户原文及会话保持'
    fi
  elif (( result != 0 )); then
    configuration_error '知识索引迁移及恢复尚未确认，自动回复保持受阻止；受限保全未删除'
  fi
  rm -f -- "$observed" "$plan" "${old:-}" "${frozen_editable:-}" \
    "${projection_editable:-}" "${candidate_editable:-}" || cleanup_result=1
  if [[ -n "$stage" ]] && ! rm -rf -- "$stage"; then cleanup_result=1; fi
  [[ "$completed" == true && "$cleanup_result" -eq 0 ]]
)

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  if [[ ${1:-} == --help || ${1:-} == -h ]]; then
    printf '%s\n' '用法：knowledge-profile.sh --deploy-dir PATH capture | ensure | status' 'ensure 仅维护本实例知识模型及索引；保全旧组件，失败时保持受阻止或成套恢复，不改人工会话。'
    exit 0
  fi
  [[ ${1:-} == --deploy-dir && $# == 3 ]] || { configuration_error '知识模型维护参数无效'; exit 64; }
  deploy=$(resolve_deploy_dir "$2")
  assert_managed_installation "$deploy"
  case "$3" in
    capture) knowledge_profile_capture "$deploy" ;;
    ensure) knowledge_profile_ensure "$deploy" ;;
    status) python3 "${PROFILE_DIR}/knowledge-profile.py" --deploy-dir "$deploy" status ;;
    *) configuration_error '未知知识模型维护操作'; exit 64 ;;
  esac
fi
