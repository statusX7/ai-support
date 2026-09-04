#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"

DEPLOY_REQUEST=""
REASON="manual"
QUIET=0

usage() {
  cat <<'EOF'
用法：snapshot.sh [--deploy-dir PATH] [--reason TEXT] [--quiet]

创建仅用于本机版本回滚的受限快照，包含程序、配置、知识文件和 AnythingLLM 数据。
快照不包含 .env、PostgreSQL、n8n 数据库、统计事件或日志。
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --deploy-dir)
      (( $# >= 2 )) || die "--deploy-dir 缺少参数"
      DEPLOY_REQUEST=$2
      shift 2
      ;;
    --reason)
      (( $# >= 2 )) || die "--reason 缺少参数"
      REASON=${2:0:200}
      shift 2
      ;;
    --quiet)
      QUIET=1
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
[[ $EUID -eq 0 ]] || die "创建版本快照需要 root 权限"
require_command tar
require_command jq
require_command sha256sum
require_command openssl
REASON=${REASON//$'\n'/ }
REASON=${REASON//$'\r'/ }
REASON=${REASON//$'\t'/ }

VERSION_VALUE=$(<"${DEPLOY_DIR}/VERSION")
[[ "$VERSION_VALUE" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "VERSION 格式无效"
SNAPSHOT_ID="$(date -u '+%Y%m%dT%H%M%SZ')-${VERSION_VALUE}-$(random_hex 4)"
VERSIONS_DIR="${DEPLOY_DIR}/backups/versions"
TARGET_DIR="${VERSIONS_DIR}/${SNAPSHOT_ID}"
mkdir -p -- "$VERSIONS_DIR" "${DEPLOY_DIR}/tmp"
for directory in "$VERSIONS_DIR" "${DEPLOY_DIR}/tmp" "${DEPLOY_DIR}/data" "${DEPLOY_DIR}/data/anythingllm"; do
  [[ -d "$directory" && ! -L "$directory" ]] || die "快照目录缺失或是符号链接：$directory"
done
chmod 700 "$VERSIONS_DIR"
[[ ! -e "$TARGET_DIR" ]] || die "版本快照已存在：$SNAPSHOT_ID"

STAGING=$(mktemp -d "${DEPLOY_DIR}/tmp/snapshot-stage.XXXXXX")
TARGET_TEMP=$(mktemp -d "${VERSIONS_DIR}/.snapshot.XXXXXX")
cleanup() {
  rm -rf -- "$STAGING" "$TARGET_TEMP"
}
trap cleanup EXIT

mkdir -p -- "$STAGING/payload/config" "$STAGING/payload/knowledge" "$STAGING/payload/n8n" \
  "$STAGING/payload/scripts" "$STAGING/payload/docs" "$STAGING/payload/data/anythingllm"

ROOT_FILES=(VERSION CHANGELOG.md README.md LICENSE AGENTS.md .env.example docker-compose.yml install.sh manage.sh update.sh uninstall.sh)
CONFIG_FILES=(app.yaml provider.yaml provider.yaml.example prompt.md prompt.md.example keyword.yaml keyword.yaml.example menu.yaml menu.yaml.example handoff.yaml handoff.yaml.example tags.yaml tags.yaml.example feedback.yaml feedback.yaml.example)
SCRIPT_FILES=(common.sh healthcheck.sh backup.sh restore.sh)
OPTIONAL_SCRIPT_FILES=(analytics.sh snapshot.sh rollback.sh)
DOC_FILES=(INSTALL.md ARCHITECTURE.md CONFIG.md SECURITY.md TESTING.md)

for name in "${ROOT_FILES[@]}"; do
  [[ -f "${DEPLOY_DIR}/${name}" && ! -L "${DEPLOY_DIR}/${name}" ]] || die "快照源文件缺失或不安全：$name"
  install -m 0600 -- "${DEPLOY_DIR}/${name}" "$STAGING/payload/${name}"
done
for name in "${CONFIG_FILES[@]}"; do
  if [[ -f "${DEPLOY_DIR}/config/${name}" && ! -L "${DEPLOY_DIR}/config/${name}" ]]; then
    install -m 0600 -- "${DEPLOY_DIR}/config/${name}" "$STAGING/payload/config/${name}"
  fi
done
for name in "${SCRIPT_FILES[@]}"; do
  [[ -f "${DEPLOY_DIR}/scripts/${name}" && ! -L "${DEPLOY_DIR}/scripts/${name}" ]] || die "快照脚本缺失或不安全：$name"
  install -m 0700 -- "${DEPLOY_DIR}/scripts/${name}" "$STAGING/payload/scripts/${name}"
done
for name in "${OPTIONAL_SCRIPT_FILES[@]}"; do
  if [[ -f "${DEPLOY_DIR}/scripts/${name}" && ! -L "${DEPLOY_DIR}/scripts/${name}" ]]; then
    install -m 0700 -- "${DEPLOY_DIR}/scripts/${name}" "$STAGING/payload/scripts/${name}"
  fi
done
for name in "${DOC_FILES[@]}"; do
  [[ -f "${DEPLOY_DIR}/docs/${name}" && ! -L "${DEPLOY_DIR}/docs/${name}" ]] || die "快照文档缺失或不安全：$name"
  install -m 0600 -- "${DEPLOY_DIR}/docs/${name}" "$STAGING/payload/docs/${name}"
done
install -m 0600 -- "${DEPLOY_DIR}/n8n/workflow.json" "$STAGING/payload/n8n/workflow.json"

while IFS= read -r -d '' file; do
  name=$(basename -- "$file")
  [[ "$name" != */* && "$name" != *\\* && "$name" != *$'\n'* && "$name" != *$'\r'* ]] || die "知识文件名不安全"
  if [[ "$name" == "README.md" ]] || is_supported_knowledge_file "$name"; then
    install -m 0600 -- "$file" "$STAGING/payload/knowledge/${name}"
  fi
done < <(find "${DEPLOY_DIR}/knowledge" -maxdepth 1 -type f ! -type l -print0 | sort -z)

if [[ -f "${DEPLOY_DIR}/data/knowledge-manifest.json" && ! -L "${DEPLOY_DIR}/data/knowledge-manifest.json" ]]; then
  install -m 0600 -- "${DEPLOY_DIR}/data/knowledge-manifest.json" "$STAGING/payload/data/knowledge-manifest.json"
fi

if find "${DEPLOY_DIR}/data/anythingllm" -mindepth 1 \! -type f \! -type d -print -quit | grep -q .; then
  die "AnythingLLM 数据包含链接或特殊文件，拒绝创建回滚快照"
fi
while IFS= read -r -d '' item; do
  relative=${item#"${DEPLOY_DIR}/data/anythingllm/"}
  [[ "$relative" != *\\* && "$relative" != *$'\n'* && "$relative" != *$'\r'* ]] \
    || die "AnythingLLM 数据包含不安全文件名"
done < <(find "${DEPLOY_DIR}/data/anythingllm" -mindepth 1 -print0)
cp -a -- "${DEPLOY_DIR}/data/anythingllm/." "$STAGING/payload/data/anythingllm/"

IMAGES='[]'
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  while IFS= read -r image_ref; do
    [[ -n "$image_ref" ]] || continue
    [[ "$image_ref" =~ ^[A-Za-z0-9][A-Za-z0-9._/@:-]{0,255}$ ]] || continue
    image_id=$(docker image inspect --format '{{.Id}}' "$image_ref" 2>/dev/null || true)
    [[ "$image_id" =~ ^sha256:[0-9a-f]{64}$ ]] || continue
    IMAGES=$(jq -c --arg reference "$image_ref" --arg id "$image_id" '. + [{reference:$reference,id:$id}]' <<< "$IMAGES")
  done < <(docker_compose "$DEPLOY_DIR" config --images 2>/dev/null | sort -u)
fi

ARCHIVE_TEMP="${TARGET_TEMP}/snapshot.tar.gz"
tar --create --gzip --file "$ARCHIVE_TEMP" --directory "$STAGING" payload
chmod 600 "$ARCHIVE_TEMP"
ARCHIVE_SHA=$(sha256sum "$ARCHIVE_TEMP" | awk '{print $1}')
CREATED_AT=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
jq -n \
  --arg format "ai-support-snapshot-v1" \
  --arg id "$SNAPSHOT_ID" \
  --arg version "$VERSION_VALUE" \
  --arg created_at "$CREATED_AT" \
  --arg reason "$REASON" \
  --arg archive_sha256 "$ARCHIVE_SHA" \
  --argjson images "$IMAGES" \
  '{format:$format,id:$id,version:$version,created_at:$created_at,reason:$reason,archive_sha256:$archive_sha256,contains_runtime_data:true,contains_env:false,images:$images}' \
  > "${TARGET_TEMP}/manifest.json"
chmod 600 "${TARGET_TEMP}/manifest.json"
mv -- "$TARGET_TEMP" "$TARGET_DIR"
trap - EXIT
rm -rf -- "$STAGING"
chmod 700 "$TARGET_DIR"

if (( QUIET )); then
  printf '%s\n' "$SNAPSHOT_ID"
else
  info "版本快照已创建：$SNAPSHOT_ID"
  warn "快照含 AnythingLLM 运行数据，仅可保存在本机受限目录，禁止上传或作为迁移备份"
fi
