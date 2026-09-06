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
  --skip-restart       恢复后不重启容器
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

if [[ "$INPUT_REQUEST" != /* ]]; then
  INPUT_REQUEST="${PWD}/${INPUT_REQUEST}"
fi
INPUT_FILE=$(realpath -e -- "$INPUT_REQUEST")
[[ -f "$INPUT_FILE" && ! -L "$INPUT_FILE" ]] || die "备份必须是普通文件且不能是符号链接"
[[ "$INPUT_FILE" == *.tar.gz ]] || die "备份文件必须以 .tar.gz 结尾"

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
  SERVICES_STOPPED=0
fi

trap - EXIT
rm -rf -- "$STAGING"
info '备份恢复完成；.env 和现有密钥未被覆盖'
