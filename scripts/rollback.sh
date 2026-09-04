#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"

DEPLOY_REQUEST=""
SNAPSHOT_ID=""
LIST_ONLY=0
SKIP_START=0
SAFETY_SNAPSHOT=1
SERVICES_STOPPED=0

usage() {
  cat <<'EOF'
用法：rollback.sh --snapshot ID [选项]
      rollback.sh --list [--deploy-dir PATH]

选项：
  --deploy-dir PATH       指定部署目录
  --snapshot ID           指定版本快照
  --list                  查看本机版本历史
  --skip-start            只恢复文件，不操作 Docker
  --no-safety-snapshot    不创建回滚前安全快照
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --deploy-dir)
      (( $# >= 2 )) || die "--deploy-dir 缺少参数"
      DEPLOY_REQUEST=$2
      shift 2
      ;;
    --snapshot)
      (( $# >= 2 )) || die "--snapshot 缺少参数"
      SNAPSHOT_ID=$2
      shift 2
      ;;
    --list)
      LIST_ONLY=1
      shift
      ;;
    --skip-start)
      SKIP_START=1
      shift
      ;;
    --no-safety-snapshot)
      SAFETY_SNAPSHOT=0
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
VERSIONS_DIR="${DEPLOY_DIR}/backups/versions"
[[ -d "$VERSIONS_DIR" && ! -L "$VERSIONS_DIR" ]] || die "版本历史目录缺失或是符号链接"

list_snapshots() {
  local found=0 manifest
  printf '%-43s %-10s %-20s %s\n' '快照 ID' '版本' '创建时间' '原因'
  if [[ -d "$VERSIONS_DIR" ]]; then
    while IFS= read -r -d '' manifest; do
      if jq -e '.format == "ai-support-snapshot-v1"' "$manifest" >/dev/null 2>&1; then
        jq -r '[.id,.version,.created_at,.reason] | @tsv' "$manifest" | \
          while IFS=$'\t' read -r id version created reason; do
            printf '%-43s %-10s %-20s %s\n' "$id" "$version" "$created" "$reason"
          done
        found=1
      fi
    done < <(find "$VERSIONS_DIR" -mindepth 2 -maxdepth 2 -type f -name manifest.json -print0 | sort -rz)
  fi
  (( found == 1 )) || printf '%s\n' '（暂无版本快照）'
}

require_command jq
if (( LIST_ONLY )); then
  list_snapshots
  exit 0
fi

[[ "$SNAPSHOT_ID" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || die "版本快照 ID 无效"
[[ $EUID -eq 0 ]] || die "回滚版本需要 root 权限"
require_command tar
require_command sha256sum

SNAPSHOT_DIR="${VERSIONS_DIR}/${SNAPSHOT_ID}"
MANIFEST="${SNAPSHOT_DIR}/manifest.json"
ARCHIVE="${SNAPSHOT_DIR}/snapshot.tar.gz"
[[ -d "$SNAPSHOT_DIR" && ! -L "$SNAPSHOT_DIR" ]] || die "版本快照不存在：$SNAPSHOT_ID"
[[ -f "$MANIFEST" && ! -L "$MANIFEST" && -f "$ARCHIVE" && ! -L "$ARCHIVE" ]] || die "版本快照不完整"
jq -e --arg id "$SNAPSHOT_ID" '.format == "ai-support-snapshot-v1" and .id == $id and .contains_env == false' "$MANIFEST" >/dev/null \
  || die "版本快照清单无效"
EXPECTED_SHA=$(jq -er '.archive_sha256' "$MANIFEST")
ACTUAL_SHA=$(sha256sum "$ARCHIVE" | awk '{print $1}')
[[ "$EXPECTED_SHA" == "$ACTUAL_SHA" ]] || die "版本快照完整性校验失败"

is_allowed_snapshot_path() {
  local path=${1#./}
  path=${path%/}
  [[ -z "$path" ]] && return 0
  case "$path" in
    payload|payload/config|payload/knowledge|payload/n8n|payload/scripts|payload/docs|payload/data|payload/data/anythingllm|payload/data/knowledge-manifest.json)
      return 0
      ;;
    payload/VERSION|payload/CHANGELOG.md|payload/README.md|payload/LICENSE|payload/AGENTS.md|payload/.env.example|payload/docker-compose.yml|payload/install.sh|payload/manage.sh|payload/update.sh|payload/uninstall.sh|payload/n8n/workflow.json)
      return 0
      ;;
    payload/config/app.yaml|payload/config/provider.yaml|payload/config/provider.yaml.example|payload/config/prompt.md|payload/config/prompt.md.example|payload/config/keyword.yaml|payload/config/keyword.yaml.example|payload/config/menu.yaml|payload/config/menu.yaml.example|payload/config/handoff.yaml|payload/config/handoff.yaml.example|payload/config/tags.yaml|payload/config/tags.yaml.example|payload/config/feedback.yaml|payload/config/feedback.yaml.example)
      return 0
      ;;
    payload/scripts/common.sh|payload/scripts/healthcheck.sh|payload/scripts/backup.sh|payload/scripts/restore.sh|payload/scripts/analytics.sh|payload/scripts/snapshot.sh|payload/scripts/rollback.sh)
      return 0
      ;;
    payload/docs/INSTALL.md|payload/docs/ARCHITECTURE.md|payload/docs/CONFIG.md|payload/docs/SECURITY.md|payload/docs/TESTING.md)
      return 0
      ;;
    payload/knowledge/*)
      local name=${path#payload/knowledge/}
      [[ "$name" != */* && "$name" != *\\* && "$name" != *$'\n'* && "$name" != *$'\r'* ]] || return 1
      [[ "$name" == "README.md" ]] || is_supported_knowledge_file "$name"
      ;;
    payload/data/anythingllm/*)
      return 0
      ;;
    *) return 1 ;;
  esac
}

while IFS= read -r entry; do
  clean=${entry#./}
  [[ "$clean" != /* && "$clean" != ".." && "$clean" != ../* && "$clean" != */../* && "$clean" != *\\* ]] \
    || die "版本快照包含路径穿越：$entry"
  is_allowed_snapshot_path "$entry" || die "版本快照包含未授权路径：$entry"
done < <(tar --list --gzip --file "$ARCHIVE")
while IFS= read -r listing; do
  case "${listing:0:1}" in
    -|d) ;;
    *) die "版本快照包含链接或特殊文件" ;;
  esac
done < <(tar --list --verbose --gzip --file "$ARCHIVE")

STAGING=$(mktemp -d "${DEPLOY_DIR}/tmp/rollback-stage.XXXXXX")
cleanup() {
  local status=$?
  trap - EXIT
  rm -rf -- "$STAGING"
  if (( status != 0 && SERVICES_STOPPED == 1 )); then
    warn "回滚未完成，尝试重新启动当前服务"
    docker_compose "$DEPLOY_DIR" up -d --remove-orphans >/dev/null 2>&1 || true
  fi
  exit "$status"
}
trap cleanup EXIT
tar --extract --gzip --file "$ARCHIVE" --directory "$STAGING" --no-same-owner --no-same-permissions
PAYLOAD="${STAGING}/payload"
[[ -f "${PAYLOAD}/VERSION" && -f "${PAYLOAD}/docker-compose.yml" && -f "${PAYLOAD}/n8n/workflow.json" ]] || die "版本快照缺少必要文件"
[[ "$(<"${PAYLOAD}/VERSION")" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "快照 VERSION 格式无效"
jq empty "${PAYLOAD}/n8n/workflow.json" || die "快照 workflow 无效"
for name in keyword.yaml menu.yaml handoff.yaml tags.yaml feedback.yaml; do
  [[ ! -f "${PAYLOAD}/config/${name}" ]] || jq empty "${PAYLOAD}/config/${name}" || die "快照配置无效：$name"
done
if [[ -f "${PAYLOAD}/config/provider.yaml" ]] && provider_config_has_secret_field "${PAYLOAD}/config/provider.yaml"; then
  die "快照 provider.yaml 包含疑似密钥字段"
fi

if (( SKIP_START == 0 )); then
  require_command docker
  docker_compose "$DEPLOY_DIR" config --quiet
  docker_compose "$DEPLOY_DIR" stop n8n anythingllm
  SERVICES_STOPPED=1
fi

if (( SAFETY_SNAPSHOT )); then
  SAFETY_ID=$("${DEPLOY_DIR}/scripts/snapshot.sh" --deploy-dir "$DEPLOY_DIR" --reason "pre-rollback-${SNAPSHOT_ID}" --quiet)
  info "回滚前安全快照：$SAFETY_ID"
fi

ROOT_FILES=(VERSION CHANGELOG.md README.md LICENSE AGENTS.md .env.example docker-compose.yml)
ROOT_EXECUTABLES=(install.sh manage.sh update.sh uninstall.sh)
CONFIG_FILES=(app.yaml provider.yaml provider.yaml.example prompt.md prompt.md.example keyword.yaml keyword.yaml.example menu.yaml menu.yaml.example handoff.yaml handoff.yaml.example tags.yaml tags.yaml.example feedback.yaml feedback.yaml.example)
SCRIPT_FILES=(common.sh healthcheck.sh backup.sh restore.sh analytics.sh snapshot.sh rollback.sh)
DOC_FILES=(INSTALL.md ARCHITECTURE.md CONFIG.md SECURITY.md TESTING.md)

for name in "${ROOT_FILES[@]}"; do
  install -m 0640 -- "${PAYLOAD}/${name}" "${DEPLOY_DIR}/${name}"
done
for name in "${ROOT_EXECUTABLES[@]}"; do
  install -m 0750 -- "${PAYLOAD}/${name}" "${DEPLOY_DIR}/${name}"
done
for name in "${CONFIG_FILES[@]}"; do
  if [[ -f "${PAYLOAD}/config/${name}" ]]; then
    install -m 0640 -- "${PAYLOAD}/config/${name}" "${DEPLOY_DIR}/config/${name}"
  fi
done
for name in "${SCRIPT_FILES[@]}"; do
  if [[ -f "${PAYLOAD}/scripts/${name}" ]]; then
    install -m 0750 -- "${PAYLOAD}/scripts/${name}" "${DEPLOY_DIR}/scripts/${name}"
  fi
done
for name in "${DOC_FILES[@]}"; do
  install -m 0640 -- "${PAYLOAD}/docs/${name}" "${DEPLOY_DIR}/docs/${name}"
done
install -m 0640 -- "${PAYLOAD}/n8n/workflow.json" "${DEPLOY_DIR}/n8n/workflow.json"

find "${DEPLOY_DIR}/knowledge" -maxdepth 1 -type f ! -name 'README.md' \
  \( -iname '*.md' -o -iname '*.txt' -o -iname '*.pdf' -o -iname '*.docx' \) -delete
while IFS= read -r -d '' file; do
  name=$(basename -- "$file")
  install -m 0640 -- "$file" "${DEPLOY_DIR}/knowledge/${name}"
done < <(find "${PAYLOAD}/knowledge" -maxdepth 1 -type f ! -name 'README.md' -print0 | sort -z)

find "${DEPLOY_DIR}/data/anythingllm" -mindepth 1 -delete
cp -a -- "${PAYLOAD}/data/anythingllm/." "${DEPLOY_DIR}/data/anythingllm/"
if [[ -f "${PAYLOAD}/data/knowledge-manifest.json" ]]; then
  install -m 0600 -- "${PAYLOAD}/data/knowledge-manifest.json" "${DEPLOY_DIR}/data/knowledge-manifest.json"
fi

MARKER_TEMP=$(mktemp "${DEPLOY_DIR}/${INSTALL_MARKER}.tmp.XXXXXX")
{
  printf 'ai-support\n'
  sed -n 's/^source=/source=/p' "${DEPLOY_DIR}/${INSTALL_MARKER}" | head -n 1
  printf 'installed_version=%s\n' "$(<"${DEPLOY_DIR}/VERSION")"
} > "$MARKER_TEMP"
chmod 600 "$MARKER_TEMP"
mv -f -- "$MARKER_TEMP" "${DEPLOY_DIR}/${INSTALL_MARKER}"
chown -R root:1000 "${DEPLOY_DIR}/config" "${DEPLOY_DIR}/knowledge" "${DEPLOY_DIR}/n8n" \
  "${DEPLOY_DIR}/data/anythingllm" 2>/dev/null || true
secure_permissions "$DEPLOY_DIR"

if (( SKIP_START == 0 )); then
  while IFS=$'\t' read -r reference image_id; do
    [[ -n "$reference" && -n "$image_id" ]] || continue
    if [[ ! "$reference" =~ ^[A-Za-z0-9][A-Za-z0-9._/@:-]{0,255}$ || ! "$image_id" =~ ^sha256:[0-9a-f]{64}$ ]]; then
      warn "快照包含无效镜像标识，已跳过"
      continue
    fi
    if docker image inspect "$image_id" >/dev/null 2>&1; then
      docker image tag "$image_id" "$reference"
    else
      warn "本机缺少历史镜像，无法恢复标签：$reference"
    fi
  done < <(jq -r '.images[]? | [.reference,.id] | @tsv' "$MANIFEST")
  docker_compose "$DEPLOY_DIR" config --quiet
  docker_compose "$DEPLOY_DIR" up -d --remove-orphans
  wait_for_local_health "$DEPLOY_DIR" 30 2
  if anythingllm_api_ready "$DEPLOY_DIR"; then
    sync_prompt_to_anythingllm "$DEPLOY_DIR" || warn "回滚已完成，但 Prompt 同步失败"
    import_and_publish_workflow "$DEPLOY_DIR" || warn "回滚已完成，但 workflow 发布失败"
  fi
  SERVICES_STOPPED=0
fi

trap - EXIT
rm -rf -- "$STAGING"
info "版本回滚完成：${SNAPSHOT_ID} -> $(<"${DEPLOY_DIR}/VERSION")"
warn "已保留 .env、PostgreSQL、n8n 数据库、匿名统计与版本历史"
