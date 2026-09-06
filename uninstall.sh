#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/bootstrap.sh
source "${SCRIPT_DIR}/scripts/bootstrap.sh"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/scripts/common.sh"
# shellcheck source=scripts/launcher.sh
source "${SCRIPT_DIR}/scripts/launcher.sh"

DEPLOY_REQUEST=""
MODE="safe"
MODE_SELECTED=0
ASSUME_YES=0
NUMERIC_CONFIRM=1

usage() {
  cat <<'EOF'
用法：./uninstall.sh [选项]

默认执行安全卸载：自动备份，删除容器、网络、Compose 定义和程序文件，
保留 config、knowledge、backups、logs、data 以及恢复数据所需的 .env。

选项：
  --deploy-dir PATH  指定部署目录
  --keep-data        显式选择安全卸载（默认行为，兼容旧命令）
  --purge            完整清理部署目录，默认两次数字确认
  --numeric-confirm  兼容参数，两次数字确认已是默认方式
  --yes              仅跳过安全卸载的普通确认，不能跳过完整清理确认
  --help              显示帮助
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --deploy-dir)
      (( $# >= 2 )) || die "--deploy-dir 缺少参数"
      DEPLOY_REQUEST=$2
      shift 2
      ;;
    --keep-data)
      (( MODE_SELECTED == 0 )) || die "--keep-data 与其他卸载模式不能同时使用"
      MODE=safe
      MODE_SELECTED=1
      shift
      ;;
    --purge)
      (( MODE_SELECTED == 0 )) || die "--purge 与其他卸载模式不能同时使用"
      MODE=purge
      MODE_SELECTED=1
      shift
      ;;
    --yes)
      ASSUME_YES=1
      shift
      ;;
    --numeric-confirm)
      NUMERIC_CONFIRM=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *) die "未知选项：$1" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "卸载需要 root 权限"
bootstrap_prepare_minimal_dependencies \
  || die "卸载所需基础依赖自动安装失败；部署未改变"
DEPLOY_DIR=$(resolve_deploy_dir "$DEPLOY_REQUEST")
assert_installation "$DEPLOY_DIR"
acquire_maintenance_lock "$DEPLOY_DIR"

for protected_directory in config knowledge backups logs data; do
  path="${DEPLOY_DIR}/${protected_directory}"
  [[ -d "$path" && ! -L "$path" ]] || die "受保护目录缺失或不安全：$path"
done
[[ -f "${DEPLOY_DIR}/.env" && ! -L "${DEPLOY_DIR}/.env" ]] \
  || die "恢复密钥文件缺失或不安全：${DEPLOY_DIR}/.env"

printf '本次操作部署目录：%s\n' "$DEPLOY_DIR"
printf '只操作此实例的服务、网络与 crispai 入口；不卸载 Docker。\n'
if [[ "$MODE" == purge ]]; then
  printf '%s\n' '完整清理会永久删除运行数据、知识库、历史备份、日志和密钥。'
  if (( NUMERIC_CONFIRM )); then
    printf '第一次确认：1 确认完整清理 / 0 返回：'
    IFS= read -r confirmation || confirmation=""
    [[ "$confirmation" == 1 || "$confirmation" == y || "$confirmation" == Y ]] || { info '已取消完整清理，部署保持不变'; exit 2; }
    printf '第二次确认：再次输入 1 永久删除 / 0 返回：'
    IFS= read -r confirmation || confirmation=""
    [[ "$confirmation" == 1 || "$confirmation" == PURGE ]] || { info '已取消完整清理，部署保持不变'; exit 2; }
  else
    printf '第一次确认：确定进入完整清理模式？[y/N] '
    IFS= read -r confirmation || confirmation=""
    case "$confirmation" in
      y|Y|yes|YES) ;;
      *) die "已取消完整清理，部署保持不变" ;;
    esac
    printf '第二次确认：请输入 PURGE：'
    IFS= read -r confirmation || confirmation=""
    [[ "$confirmation" == "PURGE" ]] || die "未输入 PURGE，已取消完整清理"
  fi
elif (( ASSUME_YES == 0 )); then
  printf '确认安全卸载并保留配置、知识库和运行数据？1 确认 / 0 返回：'
  IFS= read -r confirmation || confirmation=""
  case "$confirmation" in
    1|y|Y|yes|YES) ;;
    *) info '已取消安全卸载，部署保持不变'; exit 2 ;;
  esac
fi

chmod 0600 "${DEPLOY_DIR}/.env"

TIMESTAMP=$(date -u '+%Y%m%dT%H%M%SZ')
BACKUP_SUFFIX=$(random_hex 4)
if [[ "$MODE" == purge ]]; then
  BACKUP_FILE="$(dirname -- "$DEPLOY_DIR")/crisp-ai-purge-backup-${TIMESTAMP}-${BACKUP_SUFFIX}.tar.gz"
else
  BACKUP_FILE="${DEPLOY_DIR}/backups/uninstall-backup-${TIMESTAMP}-${BACKUP_SUFFIX}.tar.gz"
fi

BACKUP_SCRIPT="${DEPLOY_DIR}/scripts/backup.sh"
[[ -f "$BACKUP_SCRIPT" && ! -L "$BACKUP_SCRIPT" && -x "$BACKUP_SCRIPT" ]] \
  || die "自动备份脚本缺失或不安全：$BACKUP_SCRIPT"
info "卸载前创建包含凭据与运行数据的完整备份，请勿公开或上传"
"$BACKUP_SCRIPT" --deploy-dir "$DEPLOY_DIR" --full --output "$BACKUP_FILE"
[[ -f "$BACKUP_FILE" && ! -L "$BACKUP_FILE" ]] || die "自动备份没有生成有效文件"

# 容器或网络未能完整移除时必须中止，禁止在仍有进程占用数据时继续删除文件。
bootstrap_prepare_docker_runtime \
  || die "Docker 自动修复失败；未删除容器、数据或程序文件，自动备份位于：$BACKUP_FILE"
require_docker_runtime
require_command jq
COMPOSE_PROJECT_NAME_VALUE=$(
  docker_compose "$DEPLOY_DIR" config --format json \
    | jq -er '.name | select(type == "string" and length > 0)'
) || die "无法确定 Docker Compose 项目名；已安全中止文件清理，自动备份位于：$BACKUP_FILE"
[[ "$COMPOSE_PROJECT_NAME_VALUE" =~ ^[a-z0-9][a-z0-9_-]*$ ]] \
  || die "Docker Compose 项目名无效；已安全中止文件清理，自动备份位于：$BACKUP_FILE"
if ! docker_compose "$DEPLOY_DIR" down --remove-orphans; then
  die "Docker 容器或网络删除失败；已安全中止文件清理，自动备份位于：$BACKUP_FILE"
fi

# Compose 可能在外部容器仍占用项目网络时输出错误却返回 0。不能因此误删程序或外部容器。
if ! REMAINING_COMPOSE_CONTAINERS=$(docker container ls --all \
  --filter "label=com.docker.compose.project=${COMPOSE_PROJECT_NAME_VALUE}" \
  --format '{{.Names}}'); then
  die "无法核验 Docker 容器清理结果；已安全中止文件清理，自动备份位于：$BACKUP_FILE"
fi
if ! REMAINING_COMPOSE_NETWORKS=$(docker network ls \
  --filter "label=com.docker.compose.project=${COMPOSE_PROJECT_NAME_VALUE}" \
  --format '{{.Name}}'); then
  die "无法核验 Docker 网络清理结果；已安全中止文件清理，自动备份位于：$BACKUP_FILE"
fi
if [[ -n "$REMAINING_COMPOSE_CONTAINERS" || -n "$REMAINING_COMPOSE_NETWORKS" ]]; then
  [[ -z "$REMAINING_COMPOSE_CONTAINERS" ]] \
    || warn "仍存在本 Compose 项目容器：${REMAINING_COMPOSE_CONTAINERS//$'\n'/, }"
  [[ -z "$REMAINING_COMPOSE_NETWORKS" ]] \
    || warn "仍存在本 Compose 项目网络：${REMAINING_COMPOSE_NETWORKS//$'\n'/, }"
  die "Docker Compose 清理未完成，网络可能被外部容器占用；未删除任何外部容器，也未删除程序文件。请先分离占用者后重试，自动备份位于：$BACKUP_FILE"
fi

if [[ "$MODE" == purge ]]; then
  remove_crispai_launcher "$DEPLOY_DIR"
  find "$DEPLOY_DIR" -mindepth 1 -depth -delete
  rmdir -- "$DEPLOY_DIR"
  printf '\n完整清理完成。\n'
  printf '删除内容：Docker 容器、Docker 网络、服务定义、程序、配置、密钥、运行数据、知识库、部署内备份和日志。\n'
  printf '保留内容：部署目录外的完整敏感备份：%s\n' "$BACKUP_FILE"
  printf '恢复方式：从完整发布包恢复安装，再使用 scripts/restore.sh --full --input 导入此备份。\n'
  exit 0
fi

INSTALLED_VERSION=$(<"${DEPLOY_DIR}/VERSION")

PROGRAM_FILES=(
  VERSION CHANGELOG.md README.md LICENSE AGENTS.md .env.example docker-compose.yml
  install.sh manage.sh update.sh uninstall.sh
)
for name in "${PROGRAM_FILES[@]}"; do
  target="${DEPLOY_DIR}/${name}"
  [[ ! -d "$target" ]] || die "预期程序文件却发现目录，已停止清理：$target"
done

PROGRAM_DIRECTORIES=(scripts docs n8n tmp)
for name in "${PROGRAM_DIRECTORIES[@]}"; do
  target="${DEPLOY_DIR}/${name}"
  if [[ -e "$target" || -L "$target" ]]; then
    [[ -d "$target" && ! -L "$target" ]] || die "程序目录不安全，已停止清理：$target"
  fi
done

# 服务已经停止且删除目标已全部验证，此时先提交保留数据状态，确保中断后可从新源码重装恢复。
write_installation_marker "$DEPLOY_DIR" "" "$INSTALLED_VERSION" uninstalled-data-kept
remove_crispai_launcher "$DEPLOY_DIR"
for name in "${PROGRAM_FILES[@]}"; do
  rm -f -- "${DEPLOY_DIR}/${name}"
done
for name in "${PROGRAM_DIRECTORIES[@]}"; do
  target="${DEPLOY_DIR}/${name}"
  [[ ! -d "$target" ]] || find "$target" -depth -delete
done
chmod 0600 "${DEPLOY_DIR}/.env" "${DEPLOY_DIR}/${INSTALL_MARKER}"

printf '\n安全卸载完成。\n'
printf '删除内容：Docker 容器、Docker 网络、Compose 服务定义、程序脚本、workflow 副本和程序文档。\n'
printf '保留内容：config、knowledge、backups、logs、data，以及权限为 0600 的 .env 离线恢复密钥。\n'
printf '完整备份：%s（含凭据和运行数据，必须私密保管）\n' "$BACKUP_FILE"
printf '恢复方式：从新的源码目录运行 sudo ./install.sh --deploy-dir %s；安装程序会复用保留的数据和 .env。\n' "$DEPLOY_DIR"
printf '安全提示：.env 仍含敏感恢复密钥，服务已停止但该文件不得上传或公开。\n'
