#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"

DEPLOY_REQUEST=""
REASON="manual"
QUIET=0
CHECK_CAPACITY=0
PROTECTED_ID=""

usage() {
  cat <<'EOF'
用法：snapshot.sh [--deploy-dir PATH] [--reason TEXT] [--protect ID] [--check-capacity] [--quiet]

创建仅用于本机版本回滚的受限快照，包含程序、配置、知识文件、AnythingLLM 数据和 n8n 数据库逻辑备份。
快照包含 .env、人工会话状态和内部凭据，必须按敏感数据保存，禁止上传。创建期间短暂停止 n8n 与 AnythingLLM 以保证一致性。

--check-capacity 只执行容量预检，不创建快照。
--protect ID      清理历史时保留指定快照，供回滚过程内部使用。
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
    --protect)
      (( $# >= 2 )) || die "--protect 缺少参数"
      PROTECTED_ID=$2
      shift 2
      ;;
    --check-capacity)
      CHECK_CAPACITY=1
      shift
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
acquire_maintenance_lock "$DEPLOY_DIR"
[[ $EUID -eq 0 ]] || die "创建版本快照需要 root 权限"
require_command tar
require_command jq
require_command sha256sum
require_command openssl
require_command df
require_command find
require_command awk
require_command python3
REASON=${REASON//$'\n'/ }
REASON=${REASON//$'\r'/ }
REASON=${REASON//$'\t'/ }
[[ -z "$PROTECTED_ID" || "$PROTECTED_ID" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] \
  || die "受保护的版本快照 ID 无效"

VERSION_VALUE=$(<"${DEPLOY_DIR}/VERSION")
[[ "$VERSION_VALUE" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "VERSION 格式无效"
VERSIONS_DIR="${DEPLOY_DIR}/backups/versions"
mkdir -p -- "$VERSIONS_DIR" "${DEPLOY_DIR}/tmp"
for directory in "$VERSIONS_DIR" "${DEPLOY_DIR}/tmp" "${DEPLOY_DIR}/data" "${DEPLOY_DIR}/data/anythingllm" "${DEPLOY_DIR}/data/postgres"; do
  [[ -d "$directory" && ! -L "$directory" ]] || die "快照目录缺失或是符号链接：$directory"
done
chmod 700 "$VERSIONS_DIR"

SNAPSHOT_MIN_FREE_MB_VALUE=$(env_get "${DEPLOY_DIR}/.env" SNAPSHOT_MIN_FREE_MB 2>/dev/null || printf '1024')
SNAPSHOT_RETENTION_COUNT_VALUE=$(env_get "${DEPLOY_DIR}/.env" SNAPSHOT_RETENTION_COUNT 2>/dev/null || printf '10')
if [[ ! "$SNAPSHOT_MIN_FREE_MB_VALUE" =~ ^(0|[1-9][0-9]*)$ ]] \
  || (( 10#$SNAPSHOT_MIN_FREE_MB_VALUE > 2147483647 )); then
  die "SNAPSHOT_MIN_FREE_MB 必须是 0 到 2147483647 的整数"
fi
if [[ ! "$SNAPSHOT_RETENTION_COUNT_VALUE" =~ ^(0|[1-9][0-9]*)$ ]] \
  || (( 10#$SNAPSHOT_RETENTION_COUNT_VALUE > 1000 )); then
  die "SNAPSHOT_RETENTION_COUNT 必须是 0 到 1000 的整数"
fi
SNAPSHOT_MIN_FREE_MB_VALUE=$((10#$SNAPSHOT_MIN_FREE_MB_VALUE))
SNAPSHOT_RETENTION_COUNT_VALUE=$((10#$SNAPSHOT_RETENTION_COUNT_VALUE))

ROOT_FILES=(VERSION CHANGELOG.md README.md LICENSE AGENTS.md .env .env.example docker-compose.yml install.sh manage.sh update.sh uninstall.sh)
OPTIONAL_ROOT_FILES=(get.sh)
CONFIG_FILES=(app.yaml provider.yaml provider.yaml.example prompt.md prompt.md.example keyword.yaml keyword.yaml.example menu.yaml menu.yaml.example handoff.yaml handoff.yaml.example tags.yaml tags.yaml.example feedback.yaml feedback.yaml.example Caddyfile Caddyfile.example)
SCRIPT_FILES=(common.sh healthcheck.sh backup.sh restore.sh)
OPTIONAL_SCRIPT_FILES=(analytics.sh snapshot.sh rollback.sh bootstrap.sh wizard.sh package-release.sh doctor.sh)
DOC_FILES=(INSTALL.md ARCHITECTURE.md CONFIG.md SECURITY.md TESTING.md)
OPTIONAL_DOC_FILES=(RELEASE.md)

snapshot_version_at_least() {
  local value=$1 wanted_major=$2 wanted_minor=$3 wanted_patch=$4 major minor patch
  IFS=. read -r major minor patch <<< "${value#v}"
  (( 10#$major > wanted_major \
    || (10#$major == wanted_major && 10#$minor > wanted_minor) \
    || (10#$major == wanted_major && 10#$minor == wanted_minor && 10#$patch >= wanted_patch) ))
}

# get.sh 与 doctor.sh 是 v1.1.1 新增的版本能力。目标版本自身缺失时拒绝生成
# 不完整快照；从 v1.1.0 升级时则允许旧部署尚无这些文件。
if snapshot_version_at_least "$VERSION_VALUE" 1 1 1; then
  ROOT_FILES+=(get.sh)
  OPTIONAL_ROOT_FILES=()
  SCRIPT_FILES+=(doctor.sh)
  OPTIONAL_SCRIPT_FILES=(analytics.sh snapshot.sh rollback.sh bootstrap.sh wizard.sh package-release.sh)
fi
if snapshot_version_at_least "$VERSION_VALUE" 1 2 0; then
  SCRIPT_FILES+=(materials.sh logs.sh log-redact.py)
  CONFIG_FILES+=(logging.yaml.example)
fi
if snapshot_version_at_least "$VERSION_VALUE" 1 2 1; then
  SCRIPT_FILES+=(provider-router.js provider-envelope.js provider-pool.py menu-display.py menu-provider-ui.sh)
  snapshot_pool_required=true
fi

snapshot_validate_file() {
  local relative=$1 label=$2 path="${DEPLOY_DIR}/${1}"
  [[ -f "$path" && ! -L "$path" ]] || die "${label}缺失或不安全：${relative}"
}

snapshot_validate_optional_file() {
  local relative=$1 label=$2 path="${DEPLOY_DIR}/${1}"
  if [[ -e "$path" || -L "$path" ]]; then
    snapshot_validate_file "$relative" "$label"
  fi
}

snapshot_scan_sources() {
  # GNU find的目录打开分支并不总受-ignore_readdir_race保护。只容忍子成员
  # 在列举/stat/open间明确ENOENT；根缺失、权限及其他I/O错误一律失败。
  python3 - "$@" <<'PY'
import os
import stat
import sys

mode, *roots = sys.argv[1:]
seen = set()
total = 0

def identity(value):
    return value.st_dev, value.st_ino

def visit(name, parent=None, required=False):
    global total
    if any(character in name for character in "\\\n\r\t"):
        raise ValueError("name")
    try:
        value = os.stat(name, dir_fd=parent, follow_symlinks=False)
    except FileNotFoundError:
        if required:
            raise
        return
    directory = stat.S_ISDIR(value.st_mode)
    if not directory and not stat.S_ISREG(value.st_mode):
        raise ValueError("kind")
    if required and mode == "tree" and not directory:
        raise ValueError("root")
    key = identity(value)
    if key not in seen:
        seen.add(key)
        total += (value.st_blocks + 1) // 2
    if directory:
        try:
            descriptor = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
        except FileNotFoundError:
            if required:
                raise
            return
        try:
            opened = os.fstat(descriptor)
            if required and identity(opened) != key:
                raise ValueError("root")
            if identity(opened) not in seen:
                seen.add(identity(opened))
                total += (opened.st_blocks + 1) // 2
            with os.scandir(descriptor) as entries:
                for entry in entries:
                    visit(entry.name, descriptor)
        finally:
            os.close(descriptor)
    if required:
        current = os.stat(name, follow_symlinks=False)
        if identity(current) != key or stat.S_IFMT(current.st_mode) != stat.S_IFMT(value.st_mode):
            raise ValueError("root")

try:
    for root in roots:
        visit(root, required=True)
except ValueError as error:
    messages = {"name": "快照源包含不安全文件名", "kind": "快照源包含链接或特殊文件"}
    print(messages.get(str(error), "快照源目录在预检时发生不安全变化"), file=sys.stderr)
    sys.exit(1)
except OSError:
    print("快照源目录无法完整读取", file=sys.stderr)
    sys.exit(1)
if mode == "capacity":
    print(total)
PY
}

snapshot_validate_tree() {
  local relative=$1 source="${DEPLOY_DIR}/${1}"
  snapshot_scan_sources tree "$source" || die "快照源目录预检失败：$relative"
}

snapshot_assert_provider_settled() {
  local pending="${DEPLOY_DIR}/config/provider-pool-transaction.json"
  [[ ! -e "$pending" && ! -L "$pending" ]] \
    || die "接口窗口存在未完成事务，暂不能创建一致快照；请等待应用完成，或使用菜单 3→10→12 恢复后重试"
}

SNAPSHOT_POOL_LOCK_FD=''
snapshot_acquire_provider_lock() {
  local lock="${DEPLOY_DIR}/config/provider-pool.lock"
  [[ -e "${DEPLOY_DIR}/config/provider-pool-applied.json" || -L "${DEPLOY_DIR}/config/provider-pool-applied.json" ]] || return 0
  [[ ! -L "$lock" && ( ! -e "$lock" || -f "$lock" ) ]] || die "接口池快照锁不安全"
  exec {SNAPSHOT_POOL_LOCK_FD}>>"$lock"
  chmod 0600 "$lock"
  flock --shared --wait 10 "$SNAPSHOT_POOL_LOCK_FD" || die "接口池仍在提交配置，暂不能创建一致快照"
}

snapshot_release_provider_lock() {
  if [[ ${SNAPSHOT_POOL_LOCK_FD:-} =~ ^[0-9]+$ ]]; then
    flock --unlock "$SNAPSHOT_POOL_LOCK_FD"
    exec {SNAPSHOT_POOL_LOCK_FD}>&-
    SNAPSHOT_POOL_LOCK_FD=''
  fi
}

# 在容量检查及停服务之前完成源代际和树结构检查。这样 --check-capacity 不会
# 对缺模块的部署给出假绿灯，正式快照也不会先暂停服务才发现源文件损坏。
snapshot_assert_provider_settled
for name in "${ROOT_FILES[@]}"; do
  snapshot_validate_file "$name" '快照源文件'
done
for name in "${OPTIONAL_ROOT_FILES[@]}"; do
  snapshot_validate_optional_file "$name" '可选快照源文件'
done
for name in "${CONFIG_FILES[@]}"; do
  snapshot_validate_optional_file "config/${name}" '快照配置文件'
done
for name in "${SCRIPT_FILES[@]}"; do
  snapshot_validate_file "scripts/${name}" '快照脚本'
done
for name in "${OPTIONAL_SCRIPT_FILES[@]}"; do
  snapshot_validate_optional_file "scripts/${name}" '可选快照脚本'
done
for name in "${DOC_FILES[@]}"; do
  snapshot_validate_file "docs/${name}" '快照文档'
done
for name in "${OPTIONAL_DOC_FILES[@]}"; do
  snapshot_validate_optional_file "docs/${name}" '可选快照文档'
done
snapshot_validate_file 'n8n/workflow.json' '快照 workflow'
for directory in config knowledge n8n scripts docs data/anythingllm; do
  snapshot_validate_tree "$directory"
done
for directory in data/n8n data/runtime data/provider-router secrets; do
  [[ ! -e "${DEPLOY_DIR}/${directory}" && ! -L "${DEPLOY_DIR}/${directory}" ]] \
    || snapshot_validate_tree "$directory"
done
if [[ ${snapshot_pool_required:-false} == true ]]; then
  snapshot_validate_file config/provider-pool.yaml '接口池原文'
  snapshot_validate_file config/provider-pool-applied.json '接口池生效投影'
  snapshot_validate_tree secrets/provider/generations
  snapshot_validate_tree data/provider-router
fi
snapshot_validate_optional_file 'data/knowledge-manifest.json' '知识索引清单'

SNAPSHOT_SOURCE_PATHS=()
for name in "${ROOT_FILES[@]}"; do
  SNAPSHOT_SOURCE_PATHS+=("${DEPLOY_DIR}/${name}")
done
for name in "${OPTIONAL_ROOT_FILES[@]}"; do
  [[ -e "${DEPLOY_DIR}/${name}" ]] && SNAPSHOT_SOURCE_PATHS+=("${DEPLOY_DIR}/${name}")
done
for directory in config knowledge n8n scripts docs data/anythingllm data/n8n data/runtime data/provider-router secrets; do
  [[ -d "${DEPLOY_DIR}/${directory}" ]] || continue
  SNAPSHOT_SOURCE_PATHS+=("${DEPLOY_DIR}/${directory}")
done
SNAPSHOT_SOURCE_PATHS+=("${DEPLOY_DIR}/data/postgres")
if [[ -f "${DEPLOY_DIR}/data/knowledge-manifest.json" ]]; then
  SNAPSHOT_SOURCE_PATHS+=("${DEPLOY_DIR}/data/knowledge-manifest.json")
fi

snapshot_capacity_check() {
  local reserve_kib required_kib source
  for source in "${SNAPSHOT_SOURCE_PATHS[@]}"; do
    [[ ! -L "$source" && ( -f "$source" || -d "$source" ) ]] || die "快照容量预检源缺失或不安全"
  done
  # du遇到短命锁消失也会失败。仍按实际分配的512字节块计量，并按设备/inode
  # 跨根去重硬链接；每个inode向上取KiB，保留原两倍容量与管理员预留。
  if ! SNAPSHOT_SOURCE_KIB=$(snapshot_scan_sources capacity "${SNAPSHOT_SOURCE_PATHS[@]}"); then
    die "无法完整读取版本快照容量；请检查源目录权限或磁盘状态"
  fi
  for source in "${SNAPSHOT_SOURCE_PATHS[@]}"; do
    [[ ! -L "$source" && ( -f "$source" || -d "$source" ) ]] || die "快照容量预检源缺失或不安全"
  done
  SNAPSHOT_FREE_KIB=$(df -Pk -- "$VERSIONS_DIR" | awk 'NR == 2 { print $4 }')
  [[ "$SNAPSHOT_SOURCE_KIB" =~ ^[0-9]+$ && "$SNAPSHOT_FREE_KIB" =~ ^[0-9]+$ ]] \
    || die "无法计算版本快照容量"
  reserve_kib=$((SNAPSHOT_MIN_FREE_MB_VALUE * 1024))
  required_kib=$((SNAPSHOT_SOURCE_KIB * 2 + reserve_kib))
  if (( SNAPSHOT_FREE_KIB < required_kib )); then
    die "版本快照空间不足：可用 $(((SNAPSHOT_FREE_KIB + 1023) / 1024)) MiB，至少需要 $(((required_kib + 1023) / 1024)) MiB（含 ${SNAPSHOT_MIN_FREE_MB_VALUE} MiB 预留）"
  fi
  if (( QUIET == 0 )); then
    info "快照容量预检通过：可用 $(((SNAPSHOT_FREE_KIB + 1023) / 1024)) MiB，至少需要 $(((required_kib + 1023) / 1024)) MiB"
  fi
}

snapshot_capacity_check
if (( CHECK_CAPACITY )); then
  exit 0
fi
if [[ -f "${DEPLOY_DIR}/config/provider.yaml" ]] \
  && provider_config_has_secret_field "${DEPLOY_DIR}/config/provider.yaml"; then
  die "provider.yaml 包含疑似密钥字段；请将密钥移入 .env 后再创建版本快照"
fi

SNAPSHOT_ID="$(date -u '+%Y%m%dT%H%M%SZ')-${VERSION_VALUE}-$(random_hex 4)"
TARGET_DIR="${VERSIONS_DIR}/${SNAPSHOT_ID}"
[[ ! -e "$TARGET_DIR" ]] || die "版本快照已存在：$SNAPSHOT_ID"

STAGING=$(mktemp -d "${DEPLOY_DIR}/tmp/snapshot-stage.XXXXXX")
TARGET_TEMP=$(mktemp -d "${VERSIONS_DIR}/.snapshot.XXXXXX")
SERVICES_PAUSED=0
PAUSED_SERVICES=()
cleanup() {
  snapshot_release_provider_lock
  if (( SERVICES_PAUSED == 1 )); then
    docker_compose "$DEPLOY_DIR" up -d "${PAUSED_SERVICES[@]}" >/dev/null 2>&1 \
      || warn "快照失败后重新启动 n8n 或 AnythingLLM 失败"
  fi
  rm -rf -- "$STAGING" "$TARGET_TEMP"
}
trap cleanup EXIT

mkdir -p -- "$STAGING/payload/config" "$STAGING/payload/knowledge" "$STAGING/payload/n8n" \
  "$STAGING/payload/scripts" "$STAGING/payload/docs" "$STAGING/payload/data/anythingllm" \
  "$STAGING/payload/data/postgres"

require_docker_runtime
RUNNING_SERVICES=$(docker_compose "$DEPLOY_DIR" ps --services --filter status=running 2>/dev/null || true)
POSTGRES_WAS_RUNNING=0
grep -Fxq postgres <<< "$RUNNING_SERVICES" && POSTGRES_WAS_RUNNING=1
(( POSTGRES_WAS_RUNNING == 1 )) || die "PostgreSQL 容器未运行，无法创建一致的 n8n 数据库快照"
mapfile -t PAUSED_SERVICES < <(printf '%s\n' "$RUNNING_SERVICES" | grep -E '^(n8n|anythingllm|provider-adapter)$' || true)
if (( ${#PAUSED_SERVICES[@]} )); then
  docker_compose "$DEPLOY_DIR" stop "${PAUSED_SERVICES[@]}" >/dev/null
  SERVICES_PAUSED=1
fi

restart_paused_services() {
  if (( SERVICES_PAUSED == 1 )); then
    docker_compose "$DEPLOY_DIR" up -d "${PAUSED_SERVICES[@]}" >/dev/null \
      || warn "快照后重新启动 n8n 或 AnythingLLM 失败"
    SERVICES_PAUSED=0
  fi
}

# 服务停止后才锁定短配置提交；锁内只复制.env、配置及其秘密代次。
snapshot_acquire_provider_lock
snapshot_assert_provider_settled

for name in "${ROOT_FILES[@]}"; do
  [[ -f "${DEPLOY_DIR}/${name}" && ! -L "${DEPLOY_DIR}/${name}" ]] || die "快照源文件缺失或不安全：$name"
  install -m 0600 -- "${DEPLOY_DIR}/${name}" "$STAGING/payload/${name}"
done
for name in "${OPTIONAL_ROOT_FILES[@]}"; do
  if [[ -e "${DEPLOY_DIR}/${name}" || -L "${DEPLOY_DIR}/${name}" ]]; then
    snapshot_validate_file "$name" '可选快照源文件'
    install -m 0600 -- "${DEPLOY_DIR}/${name}" "$STAGING/payload/${name}"
  fi
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
for name in "${OPTIONAL_DOC_FILES[@]}"; do
  if [[ -f "${DEPLOY_DIR}/docs/${name}" && ! -L "${DEPLOY_DIR}/docs/${name}" ]]; then
    install -m 0600 -- "${DEPLOY_DIR}/docs/${name}" "$STAGING/payload/docs/${name}"
  fi
done
install -m 0600 -- "${DEPLOY_DIR}/n8n/workflow.json" "$STAGING/payload/n8n/workflow.json"

copy_snapshot_tree() {
  local relative=$1 item name scan_fd scan_pid source="${DEPLOY_DIR}/$1" target="$STAGING/payload/$1"
  [[ -d "$source" && ! -L "$source" ]] || die "快照源目录不安全：$relative"
  exec {scan_fd}< <(find "$source" -mindepth 1 -print0)
  scan_pid=$!
  while IFS= read -r -d '' item; do
    name=${item#"$source"/}
    [[ "$name" != *\\* && "$name" != *$'\n'* && "$name" != *$'\r'* && "$name" != *$'\t'* ]] \
      || die "快照源包含不安全文件名：$relative"
    [[ ! -L "$item" && ( -f "$item" || -d "$item" ) ]] || die "快照源包含链接或特殊文件：$relative"
  done <&"$scan_fd"
  exec {scan_fd}<&-
  wait "$scan_pid" || die "快照源目录无法完整读取：$relative"
  mkdir -p -- "$target"
  cp -a -- "$source/." "$target/"
}

# 新模块、所有命名知识库及其映射均属于本机恢复范围，不再只备份根目录文档。
copy_snapshot_tree config
[[ ! -d "${DEPLOY_DIR}/secrets" ]] || copy_snapshot_tree secrets
snapshot_release_provider_lock

for directory in knowledge n8n scripts docs; do
  copy_snapshot_tree "$directory"
done
for directory in data/n8n data/runtime data/provider-router; do
  [[ ! -d "${DEPLOY_DIR}/${directory}" ]] || copy_snapshot_tree "$directory"
done

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

# shellcheck disable=SC2016 # 变量必须在 PostgreSQL 容器内展开，避免密钥出现在宿主机 argv。
if ! docker_compose "$DEPLOY_DIR" exec -T postgres sh -c \
  'PGPASSWORD="$POSTGRES_PASSWORD" pg_dump --username="$POSTGRES_USER" --dbname="$POSTGRES_DB" --format=custom --no-owner --no-acl' \
  > "$STAGING/payload/data/postgres/n8n.dump"; then
  restart_paused_services
  die "n8n PostgreSQL 逻辑备份失败"
fi
[[ -s "$STAGING/payload/data/postgres/n8n.dump" ]] || {
  restart_paused_services
  die "n8n PostgreSQL 逻辑备份为空"
}
chmod 600 "$STAGING/payload/data/postgres/n8n.dump"

IMAGES='[]'
N8N_IMAGE_VALUE=$(env_get "${DEPLOY_DIR}/.env" N8N_IMAGE 2>/dev/null || printf 'docker.n8n.io/n8nio/n8n:2.33.0')
POSTGRES_IMAGE_VALUE=$(env_get "${DEPLOY_DIR}/.env" POSTGRES_IMAGE 2>/dev/null || printf 'postgres:16.10-alpine')
ANYTHINGLLM_IMAGE_VALUE=$(env_get "${DEPLOY_DIR}/.env" ANYTHINGLLM_IMAGE 2>/dev/null || printf 'mintplexlabs/anythingllm:1.16.1')
CADDY_IMAGE_VALUE=$(env_get "${DEPLOY_DIR}/.env" CADDY_IMAGE 2>/dev/null || printf 'caddy:2.10.2-alpine')
mapfile -t IMAGE_REFERENCES < <(docker_compose "$DEPLOY_DIR" config --images | sort -u)
(( ${#IMAGE_REFERENCES[@]} > 0 )) || die "Compose 未返回镜像列表"
for image_ref in "${IMAGE_REFERENCES[@]}"; do
  [[ "$image_ref" =~ ^[A-Za-z0-9][A-Za-z0-9._/@:-]{0,255}$ ]] || die "Compose 镜像引用无效"
  image_id=$(docker image inspect --format '{{.Id}}' "$image_ref" 2>/dev/null || true)
  [[ "$image_id" =~ ^sha256:[0-9a-f]{64}$ ]] || die "无法记录本机镜像 ID：$image_ref"
  IMAGES=$(jq -c --arg reference "$image_ref" --arg id "$image_id" '. + [{reference:$reference,id:$id}]' <<< "$IMAGES")
done

ARCHIVE_TEMP="${TARGET_TEMP}/snapshot.tar.gz"
tar --create --gzip --file "$ARCHIVE_TEMP" --directory "$STAGING" payload
chmod 600 "$ARCHIVE_TEMP"
ARCHIVE_SHA=$(sha256sum "$ARCHIVE_TEMP" | awk '{print $1}')
CREATED_AT=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
jq -n \
  --arg format "ai-support-snapshot-v3" \
  --arg id "$SNAPSHOT_ID" \
  --arg version "$VERSION_VALUE" \
  --arg created_at "$CREATED_AT" \
  --arg reason "$REASON" \
  --arg archive_sha256 "$ARCHIVE_SHA" \
  --argjson estimated_source_kib "$SNAPSHOT_SOURCE_KIB" \
  --argjson free_before_kib "$SNAPSHOT_FREE_KIB" \
  --argjson min_free_mb "$SNAPSHOT_MIN_FREE_MB_VALUE" \
  --argjson retention_count "$SNAPSHOT_RETENTION_COUNT_VALUE" \
  --argjson images "$IMAGES" \
  --arg n8n_image "$N8N_IMAGE_VALUE" \
  --arg postgres_image "$POSTGRES_IMAGE_VALUE" \
  --arg anythingllm_image "$ANYTHINGLLM_IMAGE_VALUE" \
  --arg caddy_image "$CADDY_IMAGE_VALUE" \
  '{format:$format,id:$id,version:$version,created_at:$created_at,reason:$reason,archive_sha256:$archive_sha256,contains_runtime_data:true,contains_database_dump:true,contains_env:true,capacity:{estimated_source_kib:$estimated_source_kib,free_before_kib:$free_before_kib,min_free_mb:$min_free_mb},retention_count:$retention_count,images:$images,image_variables:{N8N_IMAGE:$n8n_image,POSTGRES_IMAGE:$postgres_image,ANYTHINGLLM_IMAGE:$anythingllm_image,CADDY_IMAGE:$caddy_image}}' \
  > "${TARGET_TEMP}/manifest.json"
chmod 600 "${TARGET_TEMP}/manifest.json"
mv -- "$TARGET_TEMP" "$TARGET_DIR"
rm -rf -- "$STAGING"
chmod 700 "$TARGET_DIR"
restart_paused_services
trap - EXIT

prune_snapshot_history() {
  local manifest directory id created record candidate remaining
  local -a records=()
  (( SNAPSHOT_RETENTION_COUNT_VALUE > 0 )) || return 0
  while IFS= read -r -d '' manifest; do
    directory=$(dirname -- "$manifest")
    id=$(basename -- "$directory")
    [[ "$id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ && -d "$directory" && ! -L "$directory" && ! -L "$manifest" ]] || continue
    created=$(jq -er --arg id "$id" 'select((.format == "ai-support-snapshot-v1" or .format == "ai-support-snapshot-v2" or .format == "ai-support-snapshot-v3") and .id == $id) | .created_at' "$manifest" 2>/dev/null || true)
    [[ "$created" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || continue
    records+=("${created}"$'\t'"${id}")
  done < <(find "$VERSIONS_DIR" -mindepth 2 -maxdepth 2 -type f -name manifest.json -print0)
  remaining=${#records[@]}
  (( remaining > SNAPSHOT_RETENTION_COUNT_VALUE )) || return 0
  while IFS= read -r record; do
    (( remaining > SNAPSHOT_RETENTION_COUNT_VALUE )) || break
    id=${record#*$'\t'}
    [[ "$id" != "$SNAPSHOT_ID" && "$id" != "$PROTECTED_ID" ]] || continue
    candidate="${VERSIONS_DIR}/${id}"
    [[ -d "$candidate" && ! -L "$candidate" && "$(basename -- "$candidate")" == "$id" ]] || continue
    if find "$candidate" -depth -delete 2>/dev/null; then
      warn "已按保留策略删除旧版本快照：$id"
      ((remaining -= 1))
    else
      warn "无法删除旧版本快照：$id"
    fi
  done < <(printf '%s\n' "${records[@]}" | LC_ALL=C sort)
  if (( remaining > SNAPSHOT_RETENTION_COUNT_VALUE )); then
    warn "受保护快照使历史数量暂时超过保留上限，将在后续快照时重试清理"
  fi
}

prune_snapshot_history

if (( QUIET )); then
  printf '%s\n' "$SNAPSHOT_ID"
else
  info "版本快照已创建：$SNAPSHOT_ID"
  warn "快照包含密钥、知识与会话状态，仅可保存在受限目录，禁止作为无密钥业务迁移包上传"
fi
