#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"

DEPLOY_REQUEST=""
INPUT_REQUEST=""
SKIP_RESTART=0
SAFETY_BACKUP=1
SERVICES_STOPPED=0
FULL_BACKUP=0

usage() {
  cat <<'EOF'
用法：restore.sh --input backup.tar.gz [选项]

选项：
  --deploy-dir PATH    指定部署目录
  --skip-restart       仅用于旧 v1 单目录备份的离线文件恢复；新业务迁移必须应用并回读
  --no-safety-backup   不创建恢复前安全备份
  --full              恢复可信的本机完整备份（包含密钥、数据库及会话）
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --full) FULL_BACKUP=1; shift ;;
    --deploy-dir)
      (( $# >= 2 )) || die "--deploy-dir 缺少参数"
      DEPLOY_REQUEST=$2
      shift 2
      ;;
    --input)
      (( $# >= 2 )) || die "--input 缺少参数"
      INPUT_REQUEST=$2
      shift 2
      ;;
    --skip-restart)
      SKIP_RESTART=1
      shift
      ;;
    --no-safety-backup)
      SAFETY_BACKUP=0
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *) die "未知选项：$1" ;;
  esac
done

[[ -n "$INPUT_REQUEST" ]] || die "必须通过 --input 指定备份文件"
if (( FULL_BACKUP )); then
  (( SKIP_RESTART == 0 )) || die "完整数据库恢复不能跳过服务操作"
  full_args=(restore --deploy-dir "$(resolve_deploy_dir "$DEPLOY_REQUEST")" --input "$INPUT_REQUEST")
  (( SAFETY_BACKUP )) || full_args+=(--no-safety-backup)
  exec bash "${SCRIPT_DIR}/full-backup.sh" "${full_args[@]}"
fi
DEPLOY_DIR=$(resolve_deploy_dir "$DEPLOY_REQUEST")
assert_installation "$DEPLOY_DIR"
acquire_maintenance_lock "$DEPLOY_DIR"
require_command tar
require_command jq
require_command sha256sum
require_command realpath
require_command python3
require_command timeout

if [[ "$INPUT_REQUEST" != /* ]]; then
  INPUT_REQUEST="${PWD}/${INPUT_REQUEST}"
fi
[[ ! -L "$INPUT_REQUEST" && "$INPUT_REQUEST" != *[[:cntrl:]]* ]] || die '备份路径不能包含符号链接或控制字符'
INPUT_FILE=$(realpath -e -- "$INPUT_REQUEST")
[[ "$INPUT_FILE" == "$(realpath -ms -- "$INPUT_REQUEST")" ]] || die '备份路径的父目录不能包含符号链接'
[[ -f "$INPUT_FILE" && ! -L "$INPUT_FILE" ]] || die "备份必须是普通文件且不能是符号链接"
[[ "$INPUT_FILE" == *.tar.gz ]] || die "备份文件必须以 .tar.gz 结尾"

# 只读取归档中大小受限的 manifest 判断既有格式，不提取或执行归档内容。
# 后续仍由对应恢复器完整验证成员、checksum、大小、schema 和路径。
BACKUP_FORMAT=$(timeout --signal=TERM --kill-after=2s 30s python3 - "$INPUT_FILE" <<'PY'
import json
import pathlib
import sys
import tarfile

rejection = "压缩包损坏或格式无效"
try:
    path = pathlib.Path(sys.argv[1])
    if not 0 < path.stat().st_size <= 512 * 1024 * 1024:
        rejection = "压缩包大小必须为 1～536870912 字节"
        raise ValueError("size")
    total = 0
    seen = set()
    format_name = ""
    with tarfile.open(path, "r:gz") as archive:
        for count, member in enumerate(archive):
            if count >= 20000:
                rejection = "归档成员超过 20000 个"
                raise ValueError("members")
            name = member.name
            while name.startswith("./"):
                name = name[2:]
            name = name.rstrip("/")
            if name == ".":
                name = ""
            if (name.startswith("/") or ".." in pathlib.PurePosixPath(name).parts
                    or "\\" in name or any(ord(c) < 32 or ord(c) == 127 for c in name)):
                rejection = "备份包含路径穿越或控制字符"
                raise ValueError("path")
            if name in seen:
                rejection = "备份包含重复归档路径"
                raise ValueError("duplicate")
            if not (member.isfile() or member.isdir()):
                rejection = "备份包含链接或特殊文件"
                raise ValueError("type")
            seen.add(name)
            total += member.size
            if total > 4 * 1024 * 1024 * 1024:
                rejection = "归档展开大小超过 4 GiB"
                raise ValueError("expanded")
            if name == "manifest.json":
                if not member.isfile() or member.size > 65536:
                    rejection = "备份清单类型或大小无效"
                    raise ValueError("manifest")
                value = json.load(archive.extractfile(member))
                if value.get("format") == "ai-support-business-v2":
                    format_name = "ai-support-business-v2"
    print(format_name)
except (OSError, ValueError, AttributeError, tarfile.TarError):
    print("错误：" + rejection + "；现有资料未改变", file=sys.stderr)
    raise SystemExit(1)
PY
) || die '备份格式预检失败或超时：请检查压缩包完整性、重复/链接/越界路径及大小（压缩 512 MiB、展开 4 GiB、成员 20000）；现有资料未改变'
if [[ "$BACKUP_FORMAT" == ai-support-business-v2 ]]; then
  # 即使指定不适用的离线参数，也先通过安全校验给出准确的坏包原因。
  bash "${SCRIPT_DIR}/migration.sh" --deploy-dir "$DEPLOY_DIR" import-preview "$INPUT_FILE" >/dev/null \
    || die '业务备份校验和、成员或 schema 校验失败；现有资料未改变'
  (( SKIP_RESTART == 0 )) || die '新业务备份必须通过应用与回读完成恢复，不支持 --skip-restart；未修改资料'
  bash "${SCRIPT_DIR}/migration.sh" --deploy-dir "$DEPLOY_DIR" import "$INPUT_FILE"
  record_maintenance_event "$DEPLOY_DIR" restore complete
  exit 0
fi

is_allowed_archive_path() {
  local path=${1#./}
  path=${path%/}
  [[ -z "$path" ]] && return 0
  case "$path" in
    VERSION|manifest.json|checksums.sha256|n8n|n8n/workflow.json|data|data/knowledge-manifest.json|config|knowledge)
      return 0
      ;;
    config/app.yaml|config/provider.yaml|config/provider.yaml.example|config/prompt.md|config/prompt.md.example|config/keyword.yaml|config/keyword.yaml.example|config/menu.yaml|config/menu.yaml.example|config/handoff.yaml|config/handoff.yaml.example|config/tags.yaml|config/tags.yaml.example|config/feedback.yaml|config/feedback.yaml.example|config/Caddyfile|config/Caddyfile.example)
      return 0
      ;;
    knowledge/*)
      local name=${path#knowledge/}
      [[ "$name" != */* && "$name" != *\\* && "$name" != *$'\n'* \
        && "$name" != *$'\r'* && "$name" != *';'* && "$name" != *','* ]] || return 1
      [[ "$name" == "README.md" ]] || is_supported_knowledge_file "$name"
      return
      ;;
    *) return 1 ;;
  esac
}

while IFS= read -r entry; do
  clean=${entry#./}
  [[ "$clean" != /* && "$clean" != ".." && "$clean" != ../* && "$clean" != */../* && "$clean" != *\\* ]] || die "备份包含路径穿越：$entry"
  is_allowed_archive_path "$entry" || die "备份包含未授权路径：$entry"
done < <(tar --list --gzip --file "$INPUT_FILE")
if [[ -n "$(tar --list --gzip --file "$INPUT_FILE" | sed 's#^\./##; s#/$##' | LC_ALL=C sort | uniq -d)" ]]; then
  die "备份包含重复归档路径"
fi

while IFS= read -r listing; do
  case "${listing:0:1}" in
    -|d) ;;
    *) die "备份包含链接或特殊文件，拒绝恢复" ;;
  esac
done < <(tar --list --verbose --gzip --file "$INPUT_FILE")

STAGING=$(mktemp -d "${DEPLOY_DIR}/tmp/restore-stage.XXXXXX")
cleanup() {
  if (( SERVICES_STOPPED == 1 )); then
    docker_compose "$DEPLOY_DIR" up -d n8n anythingllm >/dev/null 2>&1 \
      || warn "恢复失败后重新启动服务失败"
  fi
  rm -rf -- "$STAGING"
}
trap cleanup EXIT
tar --extract --gzip --file "$INPUT_FILE" --directory "$STAGING" --no-same-owner --no-same-permissions
if find "$STAGING" -type l -o -type b -o -type c -o -type p | grep -q .; then
  die "解压结果包含不安全文件类型"
fi

[[ -f "${STAGING}/manifest.json" && -f "${STAGING}/checksums.sha256" ]] || die "备份缺少清单或校验和"
jq -e '.format == "ai-support-backup-v1" and .contains_secrets == false' "${STAGING}/manifest.json" >/dev/null || die "备份清单格式无效"
while IFS= read -r checksum_line; do
  [[ "$checksum_line" =~ ^[0-9a-f]{64}[[:space:]][[:space:]].+ ]] || die "校验和文件格式无效"
  checksum_path=${checksum_line#*  }
  is_allowed_archive_path "$checksum_path" || die "校验和引用了未授权路径"
done < "${STAGING}/checksums.sha256"
if [[ -n "$(sed -n 's/^[0-9a-f]\{64\}  //p' "${STAGING}/checksums.sha256" | sed 's#^\./##' | LC_ALL=C sort | uniq -d)" ]]; then
  die "校验和文件包含重复路径"
fi
EXPECTED_FILES=$(sed -n 's/^[0-9a-f]\{64\}  //p' "${STAGING}/checksums.sha256" | sed 's#^\./##' | LC_ALL=C sort)
ACTUAL_FILES=$(find "$STAGING" -type f ! -name 'checksums.sha256' -printf '%P\n' | LC_ALL=C sort)
[[ "$EXPECTED_FILES" == "$ACTUAL_FILES" ]] || die "备份普通文件集合与校验和清单不一致"
(
  cd -- "$STAGING"
  sha256sum --check --strict checksums.sha256 >/dev/null
) || die "备份完整性校验失败"

for config_name in keyword.yaml menu.yaml handoff.yaml tags.yaml feedback.yaml; do
  if [[ -f "${STAGING}/config/${config_name}" ]]; then
    jq empty "${STAGING}/config/${config_name}" || die "配置 JSON/YAML 无效：${config_name}"
  fi
done
[[ ! -f "${STAGING}/n8n/workflow.json" ]] || jq empty "${STAGING}/n8n/workflow.json" || die "n8n workflow JSON 无效"
if [[ -f "${STAGING}/config/provider.yaml" ]] \
  && provider_config_has_secret_field "${STAGING}/config/provider.yaml"; then
  die "备份中的 provider.yaml 包含疑似密钥字段，拒绝恢复"
fi

if (( SAFETY_BACKUP )); then
  SAFETY_FILE="${DEPLOY_DIR}/backups/pre-restore-$(date -u '+%Y%m%dT%H%M%SZ').tar.gz"
  "${DEPLOY_DIR}/scripts/backup.sh" --deploy-dir "$DEPLOY_DIR" --output "$SAFETY_FILE" >/dev/null
  info "已创建恢复前安全备份：$SAFETY_FILE"
fi

if (( SKIP_RESTART == 0 )); then
  require_docker_runtime
  docker_compose "$DEPLOY_DIR" stop n8n anythingllm
  SERVICES_STOPPED=1
elif command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  RUNNING_SERVICES=$(docker_compose "$DEPLOY_DIR" ps --services --filter status=running 2>/dev/null || true)
  if grep -Eq '^(n8n|anythingllm)$' <<< "$RUNNING_SERVICES"; then
    die "n8n 或 AnythingLLM 正在运行，不能使用 --skip-restart 执行恢复"
  fi
fi

for config_name in provider.yaml provider.yaml.example prompt.md prompt.md.example keyword.yaml keyword.yaml.example menu.yaml menu.yaml.example handoff.yaml handoff.yaml.example tags.yaml tags.yaml.example feedback.yaml feedback.yaml.example Caddyfile Caddyfile.example; do
  if [[ -f "${STAGING}/config/${config_name}" && ! -L "${STAGING}/config/${config_name}" ]]; then
    install -m 0640 -- "${STAGING}/config/${config_name}" "${DEPLOY_DIR}/config/${config_name}"
  fi
done
migrate_config_files "$DEPLOY_DIR"
if [[ -f "${STAGING}/n8n/workflow.json" ]]; then
  install -m 0640 -- "${STAGING}/n8n/workflow.json" "${DEPLOY_DIR}/n8n/workflow.json"
fi

find "${DEPLOY_DIR}/knowledge" -maxdepth 1 -type f ! -name 'README.md' \
  \( -iname '*.md' -o -iname '*.txt' -o -iname '*.pdf' -o -iname '*.docx' \) -delete
while IFS= read -r -d '' file; do
  config_name=$(basename -- "$file")
  [[ "$config_name" == "README.md" ]] && continue
  is_supported_knowledge_file "$config_name" || continue
  install -m 0640 -- "$file" "${DEPLOY_DIR}/knowledge/${config_name}"
done < <(find "${STAGING}/knowledge" -maxdepth 1 -type f -print0 | sort -z)
printf '{"version":1,"files":{},"garbage_locations":[]}\n' > "${DEPLOY_DIR}/data/knowledge-manifest.json"
chmod 600 "${DEPLOY_DIR}/data/knowledge-manifest.json"

set_runtime_ownership "$DEPLOY_DIR"
secure_permissions "$DEPLOY_DIR"

if (( SKIP_RESTART == 0 )); then
  docker_compose "$DEPLOY_DIR" config --quiet
  docker_compose "$DEPLOY_DIR" up -d n8n anythingllm
  wait_for_local_health "$DEPLOY_DIR"
  bootstrap_anythingllm_api_key "$DEPLOY_DIR"
  ensure_anythingllm_workspace "$DEPLOY_DIR"
  knowledge_sync "$DEPLOY_DIR" || die "知识文件恢复后同步失败"
  sync_prompt_to_anythingllm "$DEPLOY_DIR"
  import_and_publish_workflow "$DEPLOY_DIR"
  wait_for_local_health "$DEPLOY_DIR"
  if [[ -f "${DEPLOY_DIR}/scripts/materials.sh" && ! -L "${DEPLOY_DIR}/scripts/materials.sh" ]]; then
    bash "${DEPLOY_DIR}/scripts/configuration.sh" --deploy-dir "$DEPLOY_DIR" mark-applied \
      || die '恢复后的资料应用回读失败；未宣称恢复完成'
  fi
  install_log_maintenance "$DEPLOY_DIR" || die '恢复后的日志维护调度回读失败'
  if [[ -f "${DEPLOY_DIR}/scripts/doctor.sh" && ! -L "${DEPLOY_DIR}/scripts/doctor.sh" ]]; then
    bash "${DEPLOY_DIR}/scripts/healthcheck.sh" --deploy-dir "$DEPLOY_DIR" --application --installation-in-progress \
      || die '恢复后的组件或配置接线检查失败；未宣称恢复完成，请保留安全备份继续修复'
  fi
  SERVICES_STOPPED=0
fi

trap - EXIT
record_maintenance_event "$DEPLOY_DIR" restore complete
rm -rf -- "$STAGING"
info '备份恢复完成；.env 和现有密钥未被覆盖'
