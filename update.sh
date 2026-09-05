#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/bootstrap.sh
source "${SCRIPT_DIR}/scripts/bootstrap.sh"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/scripts/common.sh"

DEPLOY_REQUEST=""
SOURCE_REQUEST=""
NO_PULL=0
SKIP_START=0
SNAPSHOT_ID=""
SNAPSHOT_SCRIPT=""
ROLLBACK_SCRIPT=""
UPDATE_COMPLETE=0
SERVICES_STOPPED=0

usage() {
  cat <<'EOF'
用法：./update.sh [选项]

选项：
  --deploy-dir PATH   指定部署目录
  --source-dir PATH   使用已下载的 ai-support 源码目录
  --no-pull           不执行 git pull，仅使用当前源码
  --skip-start        已禁用；更新必须完成快照、重启与健康检查
  --version           显示版本
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --deploy-dir)
      (( $# >= 2 )) || die "--deploy-dir 缺少参数"
      DEPLOY_REQUEST=$2
      shift 2
      ;;
    --source-dir)
      (( $# >= 2 )) || die "--source-dir 缺少参数"
      SOURCE_REQUEST=$2
      shift 2
      ;;
    --no-pull)
      NO_PULL=1
      shift
      ;;
    --skip-start)
      SKIP_START=1
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
    *) die "未知选项：$1" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "更新需要 root 权限"
bootstrap_prepare_minimal_dependencies \
  || die "更新所需基础依赖自动安装失败；现有部署未改变"
DEPLOY_DIR=$(resolve_deploy_dir "$DEPLOY_REQUEST")
assert_installation "$DEPLOY_DIR"
acquire_maintenance_lock "$DEPLOY_DIR"
require_command realpath
(( SKIP_START == 0 )) || die "为保证 n8n 数据库与 AnythingLLM 数据一致，更新不再支持 --skip-start"

if [[ -n "$SOURCE_REQUEST" ]]; then
  SOURCE_DIR=$(realpath -e -- "$SOURCE_REQUEST")
else
  SOURCE_DIR=$(sed -n 's/^source=//p' "${DEPLOY_DIR}/${INSTALL_MARKER}" | head -n 1)
  if [[ -z "$SOURCE_DIR" || ! -d "$SOURCE_DIR" ]]; then
    die "找不到原始 Git 工作区，请使用 --source-dir 指定已下载的源码"
  fi
  SOURCE_DIR=$(realpath -e -- "$SOURCE_DIR")
fi
[[ -f "${SOURCE_DIR}/VERSION" && -f "${SOURCE_DIR}/install.sh" && -f "${SOURCE_DIR}/docker-compose.yml" ]] \
  || die "指定目录不是完整的 ai-support 源码"
[[ "$(realpath -m -- "$SOURCE_DIR")" != "$(realpath -m -- "$DEPLOY_DIR")" ]] \
  || die "源码目录不能与部署目录相同；请在独立 Git 工作区中运行 update.sh 并指定 --source-dir"

if (( NO_PULL == 0 )); then
  require_command git
  [[ -d "${SOURCE_DIR}/.git" ]] || die "源码目录不是 Git 工作区；请准备新版本源码并使用 --no-pull"
  [[ -z "$(git -C "$SOURCE_DIR" status --porcelain)" ]] \
    || die "源码工作区存在未提交修改，拒绝自动更新；请先处理修改或使用 --no-pull"
  git -C "$SOURCE_DIR" pull --ff-only
fi

NEW_VERSION=$(<"${SOURCE_DIR}/VERSION")
[[ "$NEW_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "源码 VERSION 格式无效"

OLD_VERSION=$(<"${DEPLOY_DIR}/VERSION")
[[ "$OLD_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "当前 VERSION 格式无效"
IFS=. read -r NEW_MAJOR NEW_MINOR NEW_PATCH <<< "${NEW_VERSION#v}"
IFS=. read -r OLD_MAJOR OLD_MINOR OLD_PATCH <<< "${OLD_VERSION#v}"
if (( 10#$NEW_MAJOR < 10#$OLD_MAJOR \
  || (10#$NEW_MAJOR == 10#$OLD_MAJOR && 10#$NEW_MINOR < 10#$OLD_MINOR) \
  || (10#$NEW_MAJOR == 10#$OLD_MAJOR && 10#$NEW_MINOR == 10#$OLD_MINOR && 10#$NEW_PATCH <= 10#$OLD_PATCH) )); then
  die "目标版本必须高于当前版本：${OLD_VERSION} -> ${NEW_VERSION}"
fi
SNAPSHOT_SCRIPT="${SOURCE_DIR}/scripts/snapshot.sh"
ROLLBACK_SCRIPT="${SOURCE_DIR}/scripts/rollback.sh"
if [[ ! -x "$SNAPSHOT_SCRIPT" ]]; then SNAPSHOT_SCRIPT="${DEPLOY_DIR}/scripts/snapshot.sh"; fi
if [[ ! -x "$ROLLBACK_SCRIPT" ]]; then ROLLBACK_SCRIPT="${DEPLOY_DIR}/scripts/rollback.sh"; fi
[[ -x "$SNAPSHOT_SCRIPT" && -x "$ROLLBACK_SCRIPT" ]] \
  || die "当前部署和源码均缺少可执行的快照或回滚脚本"

SNAPSHOT_MIN_FREE_MB_VALUE=$(env_get "${DEPLOY_DIR}/.env" SNAPSHOT_MIN_FREE_MB 2>/dev/null || true)
SNAPSHOT_RETENTION_COUNT_VALUE=$(env_get "${DEPLOY_DIR}/.env" SNAPSHOT_RETENTION_COUNT 2>/dev/null || true)
if [[ -z "$SNAPSHOT_MIN_FREE_MB_VALUE" ]]; then
  env_set "${DEPLOY_DIR}/.env" SNAPSHOT_MIN_FREE_MB 1024
fi
if [[ -z "$SNAPSHOT_RETENTION_COUNT_VALUE" ]]; then
  env_set "${DEPLOY_DIR}/.env" SNAPSHOT_RETENTION_COUNT 10
fi
"$SNAPSHOT_SCRIPT" --deploy-dir "$DEPLOY_DIR" --check-capacity

rollback_on_failure() {
  local status=$?
  trap - EXIT
  if (( status != 0 && UPDATE_COMPLETE == 0 )); then
    warn "更新失败，开始自动回滚"
    if [[ -n "$SNAPSHOT_ID" ]]; then
      rollback_args=(--deploy-dir "$DEPLOY_DIR" --snapshot "$SNAPSHOT_ID" --no-safety-snapshot)
      if (( SKIP_START )); then rollback_args+=(--skip-start); fi
      if "$ROLLBACK_SCRIPT" "${rollback_args[@]}"; then
        warn "已自动回滚到更新前版本：$OLD_VERSION"
      else
        warn "自动回滚未完成，请使用版本快照手动恢复：$SNAPSHOT_ID"
      fi
    elif (( SERVICES_STOPPED )); then
      docker_compose "$DEPLOY_DIR" up -d --remove-orphans >/dev/null 2>&1 || true
    fi
  fi
  exit "$status"
}
trap rollback_on_failure EXIT

bootstrap_prepare_docker_runtime \
  || die "Docker 自动修复失败；现有部署未改变"
require_docker_runtime
docker_compose "$DEPLOY_DIR" config --quiet

SNAPSHOT_ID=$("$SNAPSHOT_SCRIPT" --deploy-dir "$DEPLOY_DIR" --reason "pre-update-${OLD_VERSION}" --quiet)
info "更新前版本快照：$SNAPSHOT_ID"
BACKUP_FILE="${DEPLOY_DIR}/backups/pre-update-${OLD_VERSION}-$(date -u '+%Y%m%dT%H%M%SZ').tar.gz"
"${DEPLOY_DIR}/scripts/backup.sh" --deploy-dir "$DEPLOY_DIR" --output "$BACKUP_FILE" >/dev/null
info "更新前迁移备份：$BACKUP_FILE"

# 快照先记录旧镜像引用与镜像 ID；随后才迁移新版运行参数并拉取镜像。
migrate_runtime_env "$DEPLOY_DIR"
docker_compose_command --project-directory "$DEPLOY_DIR" --env-file "${DEPLOY_DIR}/.env" \
  -f "${SOURCE_DIR}/docker-compose.yml" config --quiet
# 镜像拉取在正式停机前完成；网络或 registry 失败不会影响当前运行服务。
docker_compose_command --project-directory "$DEPLOY_DIR" --env-file "${DEPLOY_DIR}/.env" \
  -f "${SOURCE_DIR}/docker-compose.yml" pull
docker_compose "$DEPLOY_DIR" stop n8n anythingllm
SERVICES_STOPPED=1

write_installation_marker "$DEPLOY_DIR" "$SOURCE_DIR" "$OLD_VERSION" installing
copy_project_files "$SOURCE_DIR" "$DEPLOY_DIR"
initialize_config_files "$DEPLOY_DIR"
migrate_config_files "$DEPLOY_DIR"
[[ ! -L "${DEPLOY_DIR}/data/analytics/events.jsonl" ]] || die "统计事件文件不得是符号链接"
touch -- "${DEPLOY_DIR}/data/analytics/events.jsonl"
set_runtime_ownership "$DEPLOY_DIR"
secure_permissions "$DEPLOY_DIR"

if (( SKIP_START == 0 )); then
  docker_compose "$DEPLOY_DIR" config --quiet
  docker_compose "$DEPLOY_DIR" up -d --remove-orphans
  wait_for_local_health "$DEPLOY_DIR"
  bootstrap_anythingllm_api_key "$DEPLOY_DIR"
  ensure_anythingllm_workspace "$DEPLOY_DIR"
  docker_compose "$DEPLOY_DIR" up -d --force-recreate n8n
  wait_for_local_health "$DEPLOY_DIR"
  sync_prompt_to_anythingllm "$DEPLOY_DIR"
  knowledge_sync "$DEPLOY_DIR" || die "更新后知识库同步失败"
  import_and_publish_workflow "$DEPLOY_DIR" || die "更新后 workflow 发布失败"
  wait_for_local_health "$DEPLOY_DIR"
  "${DEPLOY_DIR}/scripts/healthcheck.sh" --deploy-dir "$DEPLOY_DIR" \
    --application --installation-in-progress
  set_installation_fact "$DEPLOY_DIR" dependencies ready
  set_installation_fact "$DEPLOY_DIR" local_services ready
  set_installation_fact "$DEPLOY_DIR" app_config ready
  set_installation_fact "$DEPLOY_DIR" provider ready
  if webhook_access_check "$DEPLOY_DIR"; then
    set_installation_fact "$DEPLOY_DIR" webhook ready
  else
    set_installation_fact "$DEPLOY_DIR" webhook pending
    warn "更新后公网 Webhook 尚未通过 DNS/TLS/路由检查（HTTP ${WEBHOOK_ACCESS_STATUS:-000}）"
  fi
  set_installation_fact "$DEPLOY_DIR" conversation pending
  if crisp_api_check "$DEPLOY_DIR"; then
    set_installation_fact "$DEPLOY_DIR" crisp_api ready
    write_installation_marker "$DEPLOY_DIR" "$SOURCE_DIR" "$NEW_VERSION" ready
  else
    set_installation_fact "$DEPLOY_DIR" crisp_api failed
    write_installation_marker "$DEPLOY_DIR" "$SOURCE_DIR" "$NEW_VERSION" local-ready
    warn "更新完成且本地应用已通过检查，但 Crisp API 待修正（HTTP ${CRISP_API_STATUS:-000}）"
  fi
  SERVICES_STOPPED=0
fi

UPDATE_COMPLETE=1
trap - EXIT
info "更新完成：${OLD_VERSION} -> ${NEW_VERSION}"
info "如需撤销，请运行：${DEPLOY_DIR}/scripts/rollback.sh --deploy-dir ${DEPLOY_DIR} --snapshot ${SNAPSHOT_ID}"
