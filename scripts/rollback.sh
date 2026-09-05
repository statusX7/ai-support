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
assert_managed_installation "$DEPLOY_DIR"
acquire_maintenance_lock "$DEPLOY_DIR"
VERSIONS_DIR="${DEPLOY_DIR}/backups/versions"
[[ -d "$VERSIONS_DIR" && ! -L "$VERSIONS_DIR" ]] || die "版本历史目录缺失或是符号链接"

list_snapshots() {
  local found=0 manifest
  printf '%-43s %-10s %-20s %s\n' '快照 ID' '版本' '创建时间' '原因'
  if [[ -d "$VERSIONS_DIR" ]]; then
    while IFS= read -r -d '' manifest; do
      if jq -e '.format == "ai-support-snapshot-v1" or .format == "ai-support-snapshot-v2"' "$manifest" >/dev/null 2>&1; then
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
jq -e --arg id "$SNAPSHOT_ID" '.format == "ai-support-snapshot-v2" and .id == $id and .contains_env == false and .contains_database_dump == true' "$MANIFEST" >/dev/null \
  || die "版本快照清单无效"
(( SKIP_START == 0 )) || die "包含数据库的版本回滚必须操作 Docker，不能使用 --skip-start"
EXPECTED_SHA=$(jq -er '.archive_sha256' "$MANIFEST")
ACTUAL_SHA=$(sha256sum "$ARCHIVE" | awk '{print $1}')
[[ "$EXPECTED_SHA" == "$ACTUAL_SHA" ]] || die "版本快照完整性校验失败"
for image_key in N8N_IMAGE POSTGRES_IMAGE ANYTHINGLLM_IMAGE; do
  image_value=$(jq -er --arg key "$image_key" '.image_variables[$key] | select(type == "string")' "$MANIFEST")
  [[ "$image_value" =~ ^[A-Za-z0-9][A-Za-z0-9._/@:-]{0,255}$ ]] || die "快照镜像变量无效：$image_key"
done

is_allowed_snapshot_path() {
  local path=${1#./}
  path=${path%/}
  [[ -z "$path" ]] && return 0
  case "$path" in
    payload|payload/config|payload/knowledge|payload/n8n|payload/scripts|payload/docs|payload/data|payload/data/anythingllm|payload/data/postgres|payload/data/postgres/n8n.dump|payload/data/knowledge-manifest.json)
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
    payload/docs/INSTALL.md|payload/docs/ARCHITECTURE.md|payload/docs/CONFIG.md|payload/docs/SECURITY.md|payload/docs/TESTING.md|payload/docs/RELEASE.md)
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
  if (( status != 0 && ${ANYTHING_SWAPPED:-0} == 1 )) \
    && [[ -d "${ANYTHING_PREVIOUS:-}" && ! -L "${ANYTHING_PREVIOUS:-}" ]]; then
    rm -rf -- "${DEPLOY_DIR}/data/anythingllm"
    mv -- "$ANYTHING_PREVIOUS" "${DEPLOY_DIR}/data/anythingllm" \
      || warn "无法自动还原回滚前的 AnythingLLM 数据"
  fi
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
[[ -s "${PAYLOAD}/data/postgres/n8n.dump" && ! -L "${PAYLOAD}/data/postgres/n8n.dump" ]] || die "版本快照缺少 n8n 数据库备份"
[[ "$(<"${PAYLOAD}/VERSION")" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "快照 VERSION 格式无效"
jq empty "${PAYLOAD}/n8n/workflow.json" || die "快照 workflow 无效"
for name in keyword.yaml menu.yaml handoff.yaml tags.yaml feedback.yaml; do
  [[ ! -f "${PAYLOAD}/config/${name}" ]] || jq empty "${PAYLOAD}/config/${name}" || die "快照配置无效：$name"
done
if [[ -f "${PAYLOAD}/config/provider.yaml" ]] && provider_config_has_secret_field "${PAYLOAD}/config/provider.yaml"; then
  die "快照 provider.yaml 包含疑似密钥字段"
fi

require_docker_runtime
docker_compose "$DEPLOY_DIR" config --quiet

# 在修改任何文件或数据前确认历史镜像仍可用，避免“文件已回滚、镜像未回滚”的混合状态。
while IFS=$'\t' read -r reference image_id; do
  [[ -n "$reference" && -n "$image_id" ]] || continue
  [[ "$reference" =~ ^[A-Za-z0-9][A-Za-z0-9._/@:-]{0,255}$ && "$image_id" =~ ^sha256:[0-9a-f]{64}$ ]] \
    || die "快照包含无效镜像标识"
  docker image inspect "$image_id" >/dev/null 2>&1 \
    || die "本机缺少回滚所需历史镜像：$reference ($image_id)"
done < <(jq -r '.images[]? | [.reference,.id] | @tsv' "$MANIFEST")

docker_compose "$DEPLOY_DIR" stop n8n anythingllm
SERVICES_STOPPED=1

if (( SAFETY_SNAPSHOT )); then
  SAFETY_ID=$("${DEPLOY_DIR}/scripts/snapshot.sh" --deploy-dir "$DEPLOY_DIR" --reason "pre-rollback-${SNAPSHOT_ID}" --protect "$SNAPSHOT_ID" --quiet)
  info "回滚前安全快照：$SAFETY_ID"
fi

for image_key in N8N_IMAGE POSTGRES_IMAGE ANYTHINGLLM_IMAGE; do
  image_value=$(jq -er --arg key "$image_key" '.image_variables[$key]' "$MANIFEST")
  env_set "${DEPLOY_DIR}/.env" "$image_key" "$image_value"
done

ROOT_FILES=(VERSION CHANGELOG.md README.md LICENSE AGENTS.md .env.example docker-compose.yml)
ROOT_EXECUTABLES=(install.sh manage.sh update.sh uninstall.sh)
CONFIG_FILES=(app.yaml provider.yaml provider.yaml.example prompt.md prompt.md.example keyword.yaml keyword.yaml.example menu.yaml menu.yaml.example handoff.yaml handoff.yaml.example tags.yaml tags.yaml.example feedback.yaml feedback.yaml.example)
SCRIPT_FILES=(common.sh healthcheck.sh backup.sh restore.sh analytics.sh snapshot.sh rollback.sh)
DOC_FILES=(INSTALL.md ARCHITECTURE.md CONFIG.md SECURITY.md TESTING.md)
OPTIONAL_DOC_FILES=(RELEASE.md)

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
for name in "${OPTIONAL_DOC_FILES[@]}"; do
  if [[ -f "${PAYLOAD}/docs/${name}" ]]; then
    install -m 0640 -- "${PAYLOAD}/docs/${name}" "${DEPLOY_DIR}/docs/${name}"
  else
    rm -f -- "${DEPLOY_DIR}/docs/${name}"
  fi
done
install -m 0640 -- "${PAYLOAD}/n8n/workflow.json" "${DEPLOY_DIR}/n8n/workflow.json"

find "${DEPLOY_DIR}/knowledge" -maxdepth 1 -type f ! -name 'README.md' \
  \( -iname '*.md' -o -iname '*.txt' -o -iname '*.pdf' -o -iname '*.docx' \) -delete
while IFS= read -r -d '' file; do
  name=$(basename -- "$file")
  install -m 0640 -- "$file" "${DEPLOY_DIR}/knowledge/${name}"
done < <(find "${PAYLOAD}/knowledge" -maxdepth 1 -type f ! -name 'README.md' -print0 | sort -z)

ANYTHING_RESTORE="${DEPLOY_DIR}/data/.anythingllm-restore-${SNAPSHOT_ID}"
ANYTHING_PREVIOUS="${DEPLOY_DIR}/data/.anythingllm-previous-${SNAPSHOT_ID}"
ANYTHING_SWAPPED=0
[[ ! -e "$ANYTHING_RESTORE" && ! -e "$ANYTHING_PREVIOUS" ]] || die "回滚暂存目录已存在，请先人工检查"
mkdir -m 0700 -- "$ANYTHING_RESTORE"
cp -a -- "${PAYLOAD}/data/anythingllm/." "$ANYTHING_RESTORE/"
chown -R 1000:1000 "$ANYTHING_RESTORE" 2>/dev/null || die "无法设置 AnythingLLM 回滚数据权限"
mv -- "${DEPLOY_DIR}/data/anythingllm" "$ANYTHING_PREVIOUS"
mv -- "$ANYTHING_RESTORE" "${DEPLOY_DIR}/data/anythingllm"
ANYTHING_SWAPPED=1
if [[ -f "${PAYLOAD}/data/knowledge-manifest.json" ]]; then
  install -m 0600 -- "${PAYLOAD}/data/knowledge-manifest.json" "${DEPLOY_DIR}/data/knowledge-manifest.json"
fi

MARKER_SOURCE=$(sed -n 's/^source=//p' "${DEPLOY_DIR}/${INSTALL_MARKER}" | head -n 1)
write_installation_marker "$DEPLOY_DIR" "$MARKER_SOURCE" "$(<"${DEPLOY_DIR}/VERSION")" installing
mkdir -p -- "${DEPLOY_DIR}/data/n8n" "${DEPLOY_DIR}/data/anythingllm" "${DEPLOY_DIR}/data/runtime"
set_runtime_ownership "$DEPLOY_DIR"
secure_permissions "$DEPLOY_DIR"

while IFS=$'\t' read -r reference image_id; do
  [[ -n "$reference" && -n "$image_id" ]] || continue
  docker image tag "$image_id" "$reference"
done < <(jq -r '.images[]? | [.reference,.id] | @tsv' "$MANIFEST")

# shellcheck disable=SC2016 # 变量必须在 PostgreSQL 容器内展开，避免密钥出现在宿主机 argv。
if ! docker_compose "$DEPLOY_DIR" exec -T postgres sh -c \
  'PGPASSWORD="$POSTGRES_PASSWORD" pg_restore --username="$POSTGRES_USER" --dbname="$POSTGRES_DB" --clean --if-exists --no-owner --no-acl' \
  < "${PAYLOAD}/data/postgres/n8n.dump"; then
  rm -rf -- "${DEPLOY_DIR}/data/anythingllm"
  mv -- "$ANYTHING_PREVIOUS" "${DEPLOY_DIR}/data/anythingllm"
  ANYTHING_SWAPPED=0
  die "n8n 数据库恢复失败；AnythingLLM 数据已还原，安全快照可用于人工恢复"
fi

docker_compose "$DEPLOY_DIR" config --quiet
docker_compose "$DEPLOY_DIR" up -d --remove-orphans
wait_for_local_health "$DEPLOY_DIR" 30 2
sync_prompt_to_anythingllm "$DEPLOY_DIR"
import_and_publish_workflow "$DEPLOY_DIR"
wait_for_local_health "$DEPLOY_DIR" 30 2
write_installation_marker "$DEPLOY_DIR" "$MARKER_SOURCE" "$(<"${DEPLOY_DIR}/VERSION")" ready
SERVICES_STOPPED=0
rm -rf -- "$ANYTHING_PREVIOUS"
ANYTHING_SWAPPED=0

trap - EXIT
rm -rf -- "$STAGING"
info "版本回滚完成：${SNAPSHOT_ID} -> $(<"${DEPLOY_DIR}/VERSION")"
warn "已保留 .env、匿名统计与版本历史；n8n 数据库和 AnythingLLM 数据已恢复到快照状态"
