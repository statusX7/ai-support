#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"

DEPLOY_REQUEST=""
OUTPUT_REQUEST=""

usage() {
  cat <<'EOF'
用法：backup.sh [--deploy-dir PATH] [--output FILE]

备份包含配置、Prompt、规则、n8n workflow、知识文件和知识库清单。
备份不包含 .env、API Key、Crisp Token、Webhook Secret、日志或用户会话数据。
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --deploy-dir)
      (( $# >= 2 )) || die "--deploy-dir 缺少参数"
      DEPLOY_REQUEST=$2
      shift 2
      ;;
    --output)
      (( $# >= 2 )) || die "--output 缺少参数"
      OUTPUT_REQUEST=$2
      shift 2
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
require_command tar
require_command jq
require_command sha256sum
require_command realpath

if [[ -z "$OUTPUT_REQUEST" ]]; then
  OUTPUT_REQUEST="${DEPLOY_DIR}/backups/backup.tar.gz"
elif [[ "$OUTPUT_REQUEST" != /* ]]; then
  OUTPUT_REQUEST="${PWD}/${OUTPUT_REQUEST}"
fi
OUTPUT_FILE=$(realpath -m -- "$OUTPUT_REQUEST")
[[ "$OUTPUT_FILE" == *.tar.gz ]] || die "备份文件必须以 .tar.gz 结尾"
[[ "$OUTPUT_FILE" != "$DEPLOY_DIR"/*/../* ]] || die "备份路径无效"
[[ ! -L "$OUTPUT_FILE" ]] || die "备份目标不得是符号链接"
mkdir -p -- "$(dirname -- "$OUTPUT_FILE")" "${DEPLOY_DIR}/tmp"

STAGING=$(mktemp -d "${DEPLOY_DIR}/tmp/backup-stage.XXXXXX")
ARCHIVE_TEMP=$(mktemp "$(dirname -- "$OUTPUT_FILE")/.backup.tmp.XXXXXX")
cleanup() {
  rm -rf -- "$STAGING"
  [[ -e "$ARCHIVE_TEMP" ]] && rm -f -- "$ARCHIVE_TEMP"
}
trap cleanup EXIT

mkdir -p -- "${STAGING}/config" "${STAGING}/knowledge" "${STAGING}/n8n" "${STAGING}/data"
install -m 0640 -- "${DEPLOY_DIR}/VERSION" "${STAGING}/VERSION"

if [[ -f "${DEPLOY_DIR}/config/provider.yaml" ]] \
  && provider_config_has_secret_field "${DEPLOY_DIR}/config/provider.yaml"; then
  die "provider.yaml 包含疑似密钥字段；请将密钥移入 .env 后再备份"
fi

CONFIG_FILES=(
  app.yaml provider.yaml provider.yaml.example prompt.md prompt.md.example
  keyword.yaml keyword.yaml.example menu.yaml menu.yaml.example
  handoff.yaml handoff.yaml.example tags.yaml tags.yaml.example
  feedback.yaml feedback.yaml.example
)
for name in "${CONFIG_FILES[@]}"; do
  if [[ -f "${DEPLOY_DIR}/config/${name}" && ! -L "${DEPLOY_DIR}/config/${name}" ]]; then
    install -m 0640 -- "${DEPLOY_DIR}/config/${name}" "${STAGING}/config/${name}"
  fi
done
install -m 0640 -- "${DEPLOY_DIR}/n8n/workflow.json" "${STAGING}/n8n/workflow.json"

while IFS= read -r -d '' file; do
  name=$(basename -- "$file")
  [[ "$name" != *$'\n'* && "$name" != *$'\r'* && "$name" != *\\* \
    && "$name" != */* && "$name" != *';'* && "$name" != *','* ]] \
    || die "知识文件名包含非法字符"
  if [[ "$name" == "README.md" ]] || is_supported_knowledge_file "$name"; then
    install -m 0640 -- "$file" "${STAGING}/knowledge/${name}"
  fi
done < <(find "${DEPLOY_DIR}/knowledge" -maxdepth 1 -type f ! -type l -print0 | sort -z)

if [[ -f "${DEPLOY_DIR}/data/knowledge-manifest.json" && ! -L "${DEPLOY_DIR}/data/knowledge-manifest.json" ]]; then
  install -m 0600 -- "${DEPLOY_DIR}/data/knowledge-manifest.json" "${STAGING}/data/knowledge-manifest.json"
fi

KNOWLEDGE_JSON=$(find "${STAGING}/knowledge" -maxdepth 1 -type f ! -name 'README.md' -printf '%f\n' | sort | jq -Rsc 'split("\n") | map(select(length > 0))')
CREATED_AT=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
jq -n \
  --arg format "ai-support-backup-v1" \
  --arg version "$(<"${DEPLOY_DIR}/VERSION")" \
  --arg created_at "$CREATED_AT" \
  --argjson knowledge "$KNOWLEDGE_JSON" \
  '{format:$format,version:$version,created_at:$created_at,contains_secrets:false,knowledge_files:$knowledge}' \
  > "${STAGING}/manifest.json"

(
  cd -- "$STAGING"
  find . -type f ! -name 'checksums.sha256' -print0 | sort -z | xargs -0 sha256sum > checksums.sha256
)

tar --create --gzip --file "$ARCHIVE_TEMP" --directory "$STAGING" .
chmod 600 "$ARCHIVE_TEMP"
mv -f -- "$ARCHIVE_TEMP" "$OUTPUT_FILE"
trap - EXIT
rm -rf -- "$STAGING"
info "备份已生成：$OUTPUT_FILE"
warn '备份不含密钥；迁移后需重新配置 .env 中的 Token 与 Secret'
