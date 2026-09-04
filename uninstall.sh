#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/scripts/common.sh"

DEPLOY_REQUEST=""
MODE=""
ASSUME_YES=0
FINAL_BACKUP=1

usage() {
  cat <<'EOF'
用法：./uninstall.sh [选项]

选项：
  --deploy-dir PATH  指定部署目录
  --keep-data        删除容器和程序文件，保留配置、知识库及运行数据
  --purge            创建最终备份后删除整个部署目录
  --no-backup        与 --purge 配合，不创建最终备份
  --yes              跳过普通确认；彻底删除仍必须同时指定 --purge
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
      [[ "$MODE" != purge ]] || die "--keep-data 与 --purge 不能同时使用"
      MODE=keep
      shift
      ;;
    --purge)
      [[ "$MODE" != keep ]] || die "--keep-data 与 --purge 不能同时使用"
      MODE=purge
      shift
      ;;
    --no-backup)
      FINAL_BACKUP=0
      shift
      ;;
    --yes)
      ASSUME_YES=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *) die "未知选项：$1" ;;
  esac
done

DEPLOY_DIR=$(resolve_deploy_dir "$DEPLOY_REQUEST")
assert_installation "$DEPLOY_DIR"
[[ $EUID -eq 0 ]] || die "卸载需要 root 权限"

if [[ -z "$MODE" ]]; then
  if [[ -t 0 ]]; then
    printf '1. 保留配置和数据（推荐）\n2. 彻底删除部署目录\n请选择：'
    IFS= read -r choice
    [[ "$choice" == "2" ]] && MODE=purge || MODE=keep
  else
    MODE=keep
  fi
fi

if (( ASSUME_YES == 0 )); then
  if [[ "$MODE" == purge ]]; then
    printf '彻底删除不可撤销。请输入完整部署路径以确认：'
    IFS= read -r confirmation
    [[ "$confirmation" == "$DEPLOY_DIR" ]] || die "确认内容不匹配，已取消"
  else
    printf '确认停止服务并移除程序文件？[y/N] '
    IFS= read -r confirmation
    case "$confirmation" in y|Y|yes|YES) ;; *) die "已取消" ;; esac
  fi
fi

if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  docker_compose "$DEPLOY_DIR" down --remove-orphans || warn "部分容器未能正常停止"
else
  warn "Docker Compose 不可用，跳过容器停止步骤"
fi

if [[ "$MODE" == keep ]]; then
  rm -f -- \
    "${DEPLOY_DIR}/install.sh" "${DEPLOY_DIR}/manage.sh" "${DEPLOY_DIR}/update.sh" "${DEPLOY_DIR}/uninstall.sh" \
    "${DEPLOY_DIR}/docker-compose.yml" "${DEPLOY_DIR}/README.md" "${DEPLOY_DIR}/LICENSE" \
    "${DEPLOY_DIR}/AGENTS.md" "${DEPLOY_DIR}/CHANGELOG.md" "${DEPLOY_DIR}/.env.example"
  rm -rf -- "${DEPLOY_DIR}/scripts" "${DEPLOY_DIR}/docs" "${DEPLOY_DIR}/n8n"
  rm -f -- "${DEPLOY_DIR}/config/app.yaml" "${DEPLOY_DIR}/config/"*.example
  MARKER_TEMP=$(mktemp "${DEPLOY_DIR}/${INSTALL_MARKER}.tmp.XXXXXX")
  {
    printf 'ai-support\n'
    printf 'state=uninstalled-data-kept\n'
  } > "$MARKER_TEMP"
  chmod 600 "$MARKER_TEMP"
  mv -f -- "$MARKER_TEMP" "${DEPLOY_DIR}/${INSTALL_MARKER}"
  printf '卸载完成，配置和数据保留在：%s\n' "$DEPLOY_DIR"
  printf '重新安装时请从新的源码目录运行 install.sh。\n'
  exit 0
fi

BACKUP_FILE=""
if (( FINAL_BACKUP )); then
  PARENT_DIR=$(dirname -- "$DEPLOY_DIR")
  BACKUP_FILE="${PARENT_DIR}/crisp-ai-final-backup-$(date -u '+%Y%m%dT%H%M%SZ').tar.gz"
  "${DEPLOY_DIR}/scripts/backup.sh" --deploy-dir "$DEPLOY_DIR" --output "$BACKUP_FILE" >/dev/null
fi

find "$DEPLOY_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
rmdir -- "$DEPLOY_DIR"
printf '部署目录已删除：%s\n' "$DEPLOY_DIR"
if [[ -n "$BACKUP_FILE" ]]; then
  printf '可恢复的最终备份：%s\n' "$BACKUP_FILE"
else
  printf '未创建备份，删除内容无法通过本项目恢复。\n'
fi
