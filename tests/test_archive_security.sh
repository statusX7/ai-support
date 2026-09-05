#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf '失败：%s\n' "$1" >&2
  exit 1
}

(( $# == 2 )) || fail "用法：test_archive_security.sh DEPLOY_DIR VALID_BACKUP"
DEPLOY_DIR=$1
VALID_BACKUP=$2

[[ -d "$DEPLOY_DIR" && ! -L "$DEPLOY_DIR" ]] || fail "测试部署目录无效"
[[ -f "${DEPLOY_DIR}/.crisp-ai-installation" ]] || fail "测试部署缺少安装标记"
[[ -f "$VALID_BACKUP" && ! -L "$VALID_BACKUP" ]] || fail "基准备份无效"
command -v tar >/dev/null 2>&1 || fail "缺少命令 tar"
command -v sha256sum >/dev/null 2>&1 || fail "缺少命令 sha256sum"

WORK_DIR=$(mktemp -d "${DEPLOY_DIR}/tmp/archive-security.XXXXXX")
cleanup() {
  rm -rf -- "$WORK_DIR"
}
trap cleanup EXIT

EXTRACTED="${WORK_DIR}/payload"
TAMPERED="${WORK_DIR}/missing-checksum.tar.gz"
LOG_FILE="${WORK_DIR}/restore.log"
mkdir -p -- "$EXTRACTED"
tar --extract --gzip --file "$VALID_BACKUP" --directory "$EXTRACTED"

# 保持 JSON 合法，但让 workflow 不再受 checksums.sha256 覆盖。
printf '{"name":"未受校验和保护的 workflow","nodes":[],"connections":{}}\n' \
  > "${EXTRACTED}/n8n/workflow.json"
sed -i '\#[[:space:]]\./n8n/workflow\.json$#d' "${EXTRACTED}/checksums.sha256"
if grep -Eq '[[:space:]]\./n8n/workflow\.json$' "${EXTRACTED}/checksums.sha256"; then
  fail "测试归档未能移除 workflow 校验和"
fi
tar --create --gzip --file "$TAMPERED" --directory "$EXTRACTED" .

PROMPT_BEFORE=$(sha256sum "${DEPLOY_DIR}/config/prompt.md" | awk '{print $1}')
if "${DEPLOY_DIR}/scripts/restore.sh" \
  --deploy-dir "$DEPLOY_DIR" \
  --input "$TAMPERED" \
  --skip-restart \
  --no-safety-backup > "$LOG_FILE" 2>&1; then
  fail "恢复接受了未被 checksums.sha256 覆盖的 workflow"
fi
PROMPT_AFTER=$(sha256sum "${DEPLOY_DIR}/config/prompt.md" | awk '{print $1}')
[[ "$PROMPT_BEFORE" == "$PROMPT_AFTER" ]] || fail "拒绝恶意备份前已修改现有配置"
grep -Eq '校验和|完整性' "$LOG_FILE" || fail "恢复拒绝原因没有指出校验和问题"

TRAVERSAL_SOURCE="${WORK_DIR}/traversal-source"
TRAVERSAL_ARCHIVE="${WORK_DIR}/path-traversal.tar.gz"
TRAVERSAL_LOG="${WORK_DIR}/path-traversal.log"
printf '不得解压到部署目录之外。\n' > "$TRAVERSAL_SOURCE"
tar --create --gzip --file "$TRAVERSAL_ARCHIVE" \
  --directory "$WORK_DIR" \
  --transform='s#^traversal-source$#../escape-target#' \
  traversal-source
if "${DEPLOY_DIR}/scripts/restore.sh" \
  --deploy-dir "$DEPLOY_DIR" \
  --input "$TRAVERSAL_ARCHIVE" \
  --skip-restart \
  --no-safety-backup > "$TRAVERSAL_LOG" 2>&1; then
  fail "恢复接受了包含路径穿越成员的归档"
fi
grep -Eq '路径穿越|未授权路径' "$TRAVERSAL_LOG" \
  || fail "路径穿越归档的拒绝原因不清晰"
[[ ! -e "${DEPLOY_DIR}/escape-target" ]] || fail "路径穿越归档在拒绝前写入了文件"

LINK_SOURCE="${WORK_DIR}/link-source"
LINK_ARCHIVE="${WORK_DIR}/symlink.tar.gz"
LINK_LOG="${WORK_DIR}/symlink.log"
mkdir -p -- "${LINK_SOURCE}/knowledge"
ln -s README.md "${LINK_SOURCE}/knowledge/linked.md"
tar --create --gzip --file "$LINK_ARCHIVE" --directory "$LINK_SOURCE" knowledge
if "${DEPLOY_DIR}/scripts/restore.sh" \
  --deploy-dir "$DEPLOY_DIR" \
  --input "$LINK_ARCHIVE" \
  --skip-restart \
  --no-safety-backup > "$LINK_LOG" 2>&1; then
  fail "恢复接受了包含符号链接的归档"
fi
grep -Eq '链接|特殊文件|不安全文件类型' "$LINK_LOG" \
  || fail "符号链接归档的拒绝原因不清晰"

trap - EXIT
rm -rf -- "$WORK_DIR"
printf '备份校验和、路径穿越与链接防护：通过\n'
