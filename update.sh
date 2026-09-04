#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/scripts/common.sh"

DEPLOY_REQUEST=""
SOURCE_REQUEST=""
NO_PULL=0
SKIP_START=0

usage() {
  cat <<'EOF'
用法：./update.sh [选项]

选项：
  --deploy-dir PATH   指定部署目录
  --source-dir PATH   使用已下载的 ai-support 源码目录
  --no-pull           不执行 git pull，仅使用当前源码
  --skip-start        更新文件但不拉取镜像或重启容器
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
    *) die "未知选项：$1" ;;
  esac
done

DEPLOY_DIR=$(resolve_deploy_dir "$DEPLOY_REQUEST")
assert_installation "$DEPLOY_DIR"
[[ $EUID -eq 0 ]] || die "更新需要 root 权限"
require_command realpath
require_command git

if [[ -n "$SOURCE_REQUEST" ]]; then
  SOURCE_DIR=$(realpath -e -- "$SOURCE_REQUEST")
else
  SOURCE_DIR=$(sed -n 's/^source=//p' "${DEPLOY_DIR}/${INSTALL_MARKER}" | head -n 1)
  if [[ -z "$SOURCE_DIR" || ! -d "$SOURCE_DIR" ]]; then
    die "找不到原始 Git 工作区，请使用 --source-dir 指定已下载的源码"
  fi
  SOURCE_DIR=$(realpath -e -- "$SOURCE_DIR")
fi
[[ -f "${SOURCE_DIR}/VERSION" && -f "${SOURCE_DIR}/install.sh" && -f "${SOURCE_DIR}/docker-compose.yml" ]] || die "指定目录不是完整的 ai-support 源码"

if (( NO_PULL == 0 )); then
  if [[ -d "${SOURCE_DIR}/.git" ]]; then
    if [[ -n "$(git -C "$SOURCE_DIR" status --porcelain)" ]]; then
      die "源码工作区存在未提交修改，拒绝自动更新；请先处理修改或使用 --no-pull"
    fi
    git -C "$SOURCE_DIR" pull --ff-only
  else
    die "源码目录不是 Git 工作区；请准备新版本源码并使用 --no-pull"
  fi
fi

NEW_VERSION=$(<"${SOURCE_DIR}/VERSION")
[[ "$NEW_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "源码 VERSION 格式无效"
OLD_VERSION=$(<"${DEPLOY_DIR}/VERSION")
BACKUP_FILE="${DEPLOY_DIR}/backups/pre-update-${OLD_VERSION}-$(date -u '+%Y%m%dT%H%M%SZ').tar.gz"
"${DEPLOY_DIR}/scripts/backup.sh" --deploy-dir "$DEPLOY_DIR" --output "$BACKUP_FILE" >/dev/null
info "更新前备份已创建：$BACKUP_FILE"

copy_project_files "$SOURCE_DIR" "$DEPLOY_DIR"
initialize_config_files "$DEPLOY_DIR"
MARKER_TEMP=$(mktemp "${DEPLOY_DIR}/${INSTALL_MARKER}.tmp.XXXXXX")
{
  printf 'ai-support\n'
  printf 'source=%s\n' "$SOURCE_DIR"
  printf 'installed_version=%s\n' "$NEW_VERSION"
} > "$MARKER_TEMP"
chmod 600 "$MARKER_TEMP"
mv -f -- "$MARKER_TEMP" "${DEPLOY_DIR}/${INSTALL_MARKER}"
chown -R root:1000 "${DEPLOY_DIR}/config" "${DEPLOY_DIR}/knowledge" "${DEPLOY_DIR}/n8n" 2>/dev/null || true
secure_permissions "$DEPLOY_DIR"

if (( SKIP_START == 0 )); then
  require_command docker
  docker_compose "$DEPLOY_DIR" config --quiet
  docker_compose "$DEPLOY_DIR" pull
  docker_compose "$DEPLOY_DIR" up -d --remove-orphans
  if anythingllm_api_ready "$DEPLOY_DIR"; then
    sync_prompt_to_anythingllm "$DEPLOY_DIR" || warn "Prompt 同步失败"
    import_and_publish_workflow "$DEPLOY_DIR" || warn "n8n workflow 发布失败"
  fi
fi

info "更新完成：${OLD_VERSION} -> ${NEW_VERSION}"
