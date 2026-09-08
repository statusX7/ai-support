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
  chmod 600 "$output"
  jq -e '.engine == "native" and (.model|type=="string") and (.chunk_size|type=="number") and (.chunk_overlap|type=="number")' "$output" >/dev/null
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
      env_set "${deploy}/.env" KNOWLEDGE_EMBEDDING_MODEL "$active"
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
    observed=$(mktemp "${deploy}/tmp/knowledge-observe.XXXXXXXX")
    if knowledge_component "$deploy" observe "$observed"; then
      model=$(jq -er '.model' "$observed")
      [[ "$explicit" == true ]] || explicit=$(jq -er '.explicit_model | tostring' "$observed")
    elif [[ -z "$persisted" ]]; then
      # 固定旧版未显式配置时就是 MiniLM；先投影该值，启动后 ensure 仍会实际回读。
      warn '旧知识容器当前不可读取；按固定版本缺省模型启动，启动后将再次严格核对'
    fi
    rm -f -- "$observed"
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
  env_set "${deploy}/.env" KNOWLEDGE_ACTIVE_EMBEDDING_MODEL "$model"
  env_set "${deploy}/.env" KNOWLEDGE_EMBEDDING_MODEL "$desired"
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

knowledge_profile_restore() {
  local deploy=$1 backup=$2 previous old revision state
  [[ "$backup" == "${deploy}/backups/knowledge-profiles/"generation.* && -f "${backup}/complete.json" && ! -L "$backup" ]] || return 1
  previous=$(jq -er '.previous_model' "${backup}/plan.json")
  knowledge_profile_valid_model "$previous" || return 1
  docker_compose "$deploy" stop --timeout 30 anythingllm >/dev/null || return 1
  python3 "${PROFILE_DIR}/knowledge-profile.py" --deploy-dir "$deploy" restore --backup "$backup" >/dev/null || return 1
  env_set "${deploy}/.env" KNOWLEDGE_ACTIVE_EMBEDDING_MODEL "$previous"
  docker_compose "$deploy" up -d --no-deps --force-recreate anythingllm >/dev/null || return 1
  knowledge_profile_wait "$deploy" || return 1
  # Python restore 已对 metadata 清单及逐文件摘要完成校验；恢复投影必须只取这份
  # 同一 complete.json 绑定的副本，不能信任另存且未入清单的旁路文件。
  old="${backup}/metadata/config/materials-applied.json"
  if [[ -f "$old" ]]; then
    revision=$(( $(jq -er '.revision' "${deploy}/config/materials-applied.json") + 1 ))
    state=$(jq -er '.state' "$old")
    materials_publish_old_generation "$deploy" "$old" "$revision" "$state" || return 1
    materials_finalize_runtime_source "$deploy" "$revision" || return 1
    materials_projection_readback "$deploy" || return 1
  fi
  rm -f -- "${deploy}/data/runtime/knowledge-migration.json"
}

knowledge_profile_ensure() (
  local deploy=$1 observed plan desired active size backup='' old='' stage='' pointer="${1}/data/runtime/knowledge-migration.json"
  local revision=1 changed=false completed=false result=0
  # 中断保留 applying 和受限保全，由同一入口明确恢复；不会触碰人工/offer/jobs。
  trap 'trap "" INT TERM; configuration_error "知识索引迁移已中断，资料和受限保全保留；请用同一入口继续"; exit 130' INT
  trap 'trap "" INT TERM; configuration_error "知识索引迁移已中断，资料和受限保全保留；请用同一入口继续"; exit 143' TERM
  acquire_maintenance_lock "$deploy"
  knowledge_profile_capture "$deploy" || return 1
  if [[ -e "$pointer" || -L "$pointer" ]]; then
    [[ -f "$pointer" && ! -L "$pointer" ]] || return 1
    backup=$(jq -er '.backup' "$pointer") || return 1
    knowledge_profile_restore "$deploy" "$backup" \
      || { configuration_error '上次知识迁移尚未成套恢复，自动回复保持受阻止；未强启混合索引'; return 1; }
  fi
  observed=$(mktemp "${deploy}/tmp/knowledge-profile-observe.XXXXXXXX")
  plan=$(mktemp "${deploy}/tmp/knowledge-profile-plan.XXXXXXXX")
  if ! knowledge_component "$deploy" observe "$observed"; then rm -f -- "$observed" "$plan"; return 1; fi
  desired=$(env_get "${deploy}/.env" KNOWLEDGE_EMBEDDING_MODEL)
  active=$(jq -er '.model' "$observed")
  size=$(env_get "${deploy}/.env" KNOWLEDGE_CHUNK_SIZE 2>/dev/null || true)
  if [[ -z "$size" && "$desired" == MintplexLabs/multilingual-e5-small && "$active" != "$desired" \
    && $(jq -er '.explicit_chunk_size | tostring' "$observed") == false ]]; then
    # 固定模型 tokenizer 最多 512 token；400 字符避免长中文 FAQ 块在向量前被整段截尾。
    size=400
  fi
  local -a arguments=(--deploy-dir "$deploy" plan --observed "$observed" --model "$desired")
  [[ -z "$size" ]] || arguments+=(--chunk-size "$size")
  if ! python3 "${PROFILE_DIR}/knowledge-profile.py" "${arguments[@]}" > "$plan"; then rm -f -- "$observed" "$plan"; return 1; fi
  changed=$(jq -er '.requires_reindex | tostring' "$plan")
  if [[ "$changed" == false ]]; then rm -f -- "$observed" "$plan"; return 0; fi
  knowledge_catalog_migrate "$deploy" || return 1
  mkdir -p -- "${deploy}/backups/knowledge-profiles"
  chmod 700 "${deploy}/backups/knowledge-profiles"
  backup=$(mktemp -d "${deploy}/backups/knowledge-profiles/generation.XXXXXXXX")
  if [[ -f "${deploy}/config/materials-applied.json" ]]; then
    old=$(mktemp "${deploy}/tmp/knowledge-old-projection.XXXXXXXX")
    install -m 600 -- "${deploy}/config/materials-applied.json" "$old"
    revision=$(( $(jq -er '.revision' "$old") + 1 ))
  fi
  info '正在保全知识组件并重建模型对应索引；该期间自动回复暂停，人工控制事件仍可接收'
  docker_compose "$deploy" stop --timeout 30 anythingllm >/dev/null || return 1
  if ! python3 "${PROFILE_DIR}/knowledge-profile.py" --deploy-dir "$deploy" backup --plan "$plan" --backup "$backup" >/dev/null; then
    docker_compose "$deploy" up -d --no-deps anythingllm >/dev/null || true
    configuration_error '知识组件保全失败，未切换模型；自动回复保持受阻止，保留现场供继续'
    return 1
  fi
  local temporary
  temporary=$(mktemp "${pointer}.tmp.XXXXXXXX")
  jq -n --arg backup "$backup" '{schema_version:1,backup:$backup}' > "$temporary"
  chmod 600 "$temporary"
  mv -f -- "$temporary" "$pointer"
  if [[ -n "$old" ]] && ! materials_publish_old_generation "$deploy" "$old" "$revision" applying; then result=1; fi
  if (( result == 0 )) && ! python3 "${PROFILE_DIR}/knowledge-profile.py" --deploy-dir "$deploy" activate --backup "$backup" >/dev/null; then result=1; fi
  if (( result == 0 )); then
    env_set "${deploy}/.env" KNOWLEDGE_ACTIVE_EMBEDDING_MODEL "$desired"
    docker_compose "$deploy" up -d --no-deps --force-recreate anythingllm >/dev/null || result=1
  fi
  if (( result == 0 )); then knowledge_profile_wait "$deploy" || result=1; fi
  if (( result == 0 )); then
    knowledge_component "$deploy" configure-chunks "$observed" "$(jq -er '.profile.chunk_size' "$plan")" "$(jq -er '.profile.chunk_overlap' "$plan")" || result=1
  fi
  if (( result == 0 )); then
    knowledge_sync_catalog "$deploy" 1 all true || result=1
  fi
  if (( result == 0 )); then
    knowledge_component "$deploy" observe "$observed" \
      && python3 "${PROFILE_DIR}/knowledge-profile.py" --deploy-dir "$deploy" commit --backup "$backup" --observed "$observed" >/dev/null \
      && knowledge_catalog_readback "$deploy" all true || result=1
  fi
  if (( result == 0 )) && [[ -n "$old" ]]; then
    stage=$(mktemp -d "${deploy}/tmp/knowledge-profile-final.XXXXXXXX")
    configuration_prompt_verify_file "$deploy" "${deploy}/config/prompt.md" \
      && materials_prepare_candidate "$deploy" "$stage" "$revision" applied \
      && materials_snapshot_create "$deploy" "${stage}/materials.applied.tar.gz" \
      && materials_finalize_runtime_source "$deploy" "$revision" \
      && materials_projection_write "$deploy" "${stage}/materials-applied.json" \
      && materials_projection_readback "$deploy" \
      && install -m 600 -- "${stage}/materials.applied.tar.gz" "${deploy}/backups/config-history/materials.applied.tar.gz" || result=1
  fi
  if (( result == 0 )); then
    completed=true
    rm -f -- "$pointer"
    info '知识模型、文档索引和运行映射已对账；旧组件保全受限保留在 backups/knowledge-profiles'
  elif knowledge_profile_restore "$deploy" "$backup"; then
    configuration_error '知识索引迁移未完成，已恢复原组件和索引；用户原文及会话保持'
  else
    configuration_error '知识索引迁移及恢复尚未确认，自动回复保持受阻止；受限保全未删除'
  fi
  rm -f -- "$observed" "$plan" "${old:-}"
  [[ -z "$stage" ]] || rm -rf -- "$stage"
  [[ "$completed" == true ]]
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
