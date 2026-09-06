#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"
ACTION=${1:-}
[[ $# -eq 0 ]] || shift
DEPLOY_REQUEST="" INPUT_REQUEST="" OUTPUT_REQUEST="" SAFETY_BACKUP=1
while (( $# )); do
  case "$1" in
    --deploy-dir) (( $# >= 2 )) || die "缺少部署目录"; DEPLOY_REQUEST=$2; shift 2 ;;
    --input) (( $# >= 2 )) || die "缺少备份文件"; INPUT_REQUEST=$2; shift 2 ;;
    --output) (( $# >= 2 )) || die "缺少输出路径"; OUTPUT_REQUEST=$2; shift 2 ;;
    --no-safety-backup) SAFETY_BACKUP=0; shift ;;
    *) die "未知完整备份选项：$1" ;;
  esac
done
[[ "$ACTION" == create || "$ACTION" == restore ]] || die "完整备份操作必须是 create 或 restore"
[[ $EUID -eq 0 ]] || die "完整备份/恢复需要 root 权限"
DEPLOY_DIR=$(resolve_deploy_dir "$DEPLOY_REQUEST")
assert_managed_installation "$DEPLOY_DIR"
acquire_maintenance_lock "$DEPLOY_DIR"
umask 077
mkdir -p -- "${DEPLOY_DIR}/tmp" "${DEPLOY_DIR}/backups/versions"
STAGING=$(mktemp -d "${DEPLOY_DIR}/tmp/full-backup.XXXXXX")
cleanup() { rm -rf -- "$STAGING"; }
trap cleanup EXIT

if [[ "$ACTION" == create ]]; then
  [[ -n "$OUTPUT_REQUEST" ]] || OUTPUT_REQUEST="${DEPLOY_DIR}/backups/full-$(date -u '+%Y%m%dT%H%M%SZ').tar.gz"
  [[ "$OUTPUT_REQUEST" == /* ]] || OUTPUT_REQUEST="${PWD}/${OUTPUT_REQUEST}"
  [[ ! -L "$OUTPUT_REQUEST" ]] || die "完整备份目标不能是符号链接"
  OUTPUT_FILE=$(realpath -m -- "$OUTPUT_REQUEST")
  [[ "$OUTPUT_FILE" == *.tar.gz && ! -d "$OUTPUT_FILE" ]] || die "完整备份输出必须为 .tar.gz 普通文件"
  mkdir -p -- "$(dirname -- "$OUTPUT_FILE")"
  SNAPSHOT_ID=$(bash "${SCRIPT_DIR}/snapshot.sh" --deploy-dir "$DEPLOY_DIR" --reason full-backup --quiet)
  SNAPSHOT_DIR="${DEPLOY_DIR}/backups/versions/${SNAPSHOT_ID}"
  [[ -f "${SNAPSHOT_DIR}/manifest.json" && -f "${SNAPSHOT_DIR}/snapshot.tar.gz" ]] || die "一致性快照没有完成"
  OUTPUT_TEMP=$(mktemp "$(dirname -- "$OUTPUT_FILE")/.full-backup.XXXXXX")
  if tar -czf "$OUTPUT_TEMP" -C "$SNAPSHOT_DIR" manifest.json snapshot.tar.gz; then
    chmod 0600 "$OUTPUT_TEMP"
    mv -f -- "$OUTPUT_TEMP" "$OUTPUT_FILE"
  else
    rm -f -- "$OUTPUT_TEMP"
    die "完整备份归档失败"
  fi
  info "完整备份已完成：$OUTPUT_FILE"
  warn "包含 API Key、内部密码、知识和会话；禁止作为无密钥迁移包分享。恢复需本机保留的历史容器镜像。"
else
  [[ -f "$INPUT_REQUEST" && ! -L "$INPUT_REQUEST" ]] || die "完整备份必须是普通文件"
  python3 "${SCRIPT_DIR}/archive-guard.py" "$INPUT_REQUEST" --kind full
  tar -xzf "$INPUT_REQUEST" -C "$STAGING" --no-same-owner --no-same-permissions
  jq -e '.format == "ai-support-snapshot-v3" and .contains_env == true and .contains_database_dump == true' \
    "${STAGING}/manifest.json" >/dev/null || die "不是包含内部凭据的一致性完整备份"
  EXPECTED=$(jq -er '.archive_sha256' "${STAGING}/manifest.json")
  ACTUAL=$(sha256sum "${STAGING}/snapshot.tar.gz"); ACTUAL=${ACTUAL%% *}
  [[ "$EXPECTED" == "$ACTUAL" ]] || die "完整备份校验和不一致"
  python3 "${SCRIPT_DIR}/archive-guard.py" "${STAGING}/snapshot.tar.gz" --kind snapshot
  SNAPSHOT_ID=$(jq -er '.id' "${STAGING}/manifest.json")
  [[ "$SNAPSHOT_ID" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || die "备份快照 ID 无效"
  TARGET="${DEPLOY_DIR}/backups/versions/${SNAPSHOT_ID}"
  [[ ! -L "$TARGET" ]] || die "快照目标目录不安全"
  if [[ -e "$TARGET" ]]; then
    [[ -f "${TARGET}/snapshot.tar.gz" && ! -L "${TARGET}/snapshot.tar.gz" ]] || die "同名快照目录不完整"
    EXISTING=$(sha256sum "${TARGET}/snapshot.tar.gz"); EXISTING=${EXISTING%% *}
    [[ "$EXISTING" == "$EXPECTED" ]] || die "同名快照内容不同，未覆盖当前快照"
  else
    mkdir -m 0700 -- "$TARGET"
    install -m 0600 -- "${STAGING}/manifest.json" "${STAGING}/snapshot.tar.gz" "$TARGET/"
  fi
  rollback_args=(--deploy-dir "$DEPLOY_DIR" --snapshot "$SNAPSHOT_ID")
  (( SAFETY_BACKUP )) || rollback_args+=(--no-safety-snapshot)
  bash "${SCRIPT_DIR}/rollback.sh" "${rollback_args[@]}"
  info "完整本机备份恢复完成"
fi
