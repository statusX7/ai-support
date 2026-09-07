#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
OUTPUT_REQUEST="${PROJECT_ROOT}/dist"

usage() {
  cat <<'EOF'
用法：scripts/package-release.sh [--output-dir DIR]

生成完整源码发布包 ai-support-vX.Y.Z.tar.gz、SHA256SUMS 与独立 get.sh 审计资产。
归档不包含 .git、.work、.env、实际配置、知识数据、日志或运行数据。
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --output-dir)
      (( $# >= 2 )) || { printf '错误：--output-dir 缺少参数\n' >&2; exit 1; }
      OUTPUT_REQUEST=$2
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      printf '错误：未知选项：%s\n' "$1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

for command_name in git gzip mktemp realpath sha256sum sort tar; do
  command -v "$command_name" >/dev/null 2>&1 \
    || { printf '错误：发布打包缺少维护工具：%s\n' "$command_name" >&2; exit 1; }
done

VERSION_VALUE=$(<"${PROJECT_ROOT}/VERSION")
[[ "$VERSION_VALUE" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || { printf '错误：VERSION 格式无效\n' >&2; exit 1; }
OUTPUT_DIR=$(realpath -m -- "$OUTPUT_REQUEST")
[[ "$OUTPUT_DIR" != / && "$OUTPUT_DIR" != "$PROJECT_ROOT" ]] \
  || { printf '错误：发布输出目录过宽\n' >&2; exit 1; }
[[ ! -L "$OUTPUT_DIR" ]] || { printf '错误：发布输出目录不得是符号链接\n' >&2; exit 1; }
mkdir -p -- "$OUTPUT_DIR"
[[ -d "$OUTPUT_DIR" && ! -L "$OUTPUT_DIR" ]] \
  || { printf '错误：无法建立安全的发布输出目录\n' >&2; exit 1; }

ARCHIVE_NAME="ai-support-${VERSION_VALUE}.tar.gz"
ARCHIVE_PATH="${OUTPUT_DIR}/${ARCHIVE_NAME}"
CHECKSUM_PATH="${OUTPUT_DIR}/SHA256SUMS"
WORK_DIR=$(mktemp -d "${PROJECT_ROOT}/.release-package.XXXXXX")
LIST_FILE="${WORK_DIR}/files.list"
ARCHIVE_TEMP="${WORK_DIR}/${ARCHIVE_NAME}"
CHECKSUM_TEMP="${WORK_DIR}/SHA256SUMS"

cleanup() {
  if [[ "$WORK_DIR" == "${PROJECT_ROOT}"/.release-package.* && -d "$WORK_DIR" ]]; then
    rm -rf -- "$WORK_DIR"
  fi
}
trap cleanup EXIT INT TERM

if ! git -C "$PROJECT_ROOT" diff --quiet \
  || ! git -C "$PROJECT_ROOT" diff --cached --quiet; then
  printf '错误：正式发布包只能从无已修改文件的提交生成\n' >&2
  exit 1
fi

# 固定清单不采纳任意未跟踪的 *.sh、*.example 或文档，避免本地调试文件混入资产。
RELEASE_FILES=(
  .gitignore .env.example AGENTS.md CHANGELOG.md LICENSE README.md VERSION
  docker-compose.yml get.sh install.sh manage.sh update.sh uninstall.sh
  config/app.yaml config/Caddyfile.example config/feedback.yaml.example
  config/handoff.yaml.example config/keyword.yaml.example config/menu.yaml.example
  config/prompt.md.example config/provider.yaml.example config/tags.yaml.example config/runtime.yaml.example
  config/logging.yaml.example
  knowledge/README.md n8n/workflow.json n8n/runtime.js n8n/runtime-cli.js n8n/build-workflow.js n8n/web-chat.js
  scripts/analytics.sh scripts/backup.sh scripts/bootstrap.sh scripts/common.sh
  scripts/healthcheck.sh scripts/doctor.sh scripts/package-release.sh scripts/restore.sh
  scripts/rollback.sh scripts/snapshot.sh scripts/wizard.sh scripts/launcher.sh scripts/menu-ui.sh
  scripts/configuration.sh scripts/provider.sh scripts/provider-adapter.js scripts/knowledge.sh
  scripts/migration.sh scripts/crisp-settings.sh scripts/full-backup.sh scripts/archive-guard.py
  scripts/materials.sh scripts/logs.sh scripts/log-redact.py
  docs/ARCHITECTURE.md docs/CONFIG.md docs/INSTALL.md docs/RELEASE.md
  docs/SECURITY.md docs/TESTING.md docs/MENU.md docs/CRISP.md docs/TROUBLESHOOTING.md docs/ADVANCED.md
  tests/run.sh tests/test_archive_security.sh tests/test_bootstrap.sh
  tests/test_configuration_guards.js tests/test_configuration_protocol.js
  tests/test_deployment_integration.sh tests/test_external_e2e.sh tests/test_health_wait.sh
  tests/test_knowledge_timeout.sh tests/test_manage_contract.sh tests/test_manage_ui.py
  tests/test_get.sh tests/test_doctor.sh tests/test_public_distribution.sh tests/test_legacy_rollback.sh
  tests/test_crisp_auth.js tests/test_caddy_routing.sh tests/fixtures/caddy-order-v111.conf
  tests/test_launcher.py tests/test_materials_apply.js tests/test_material_limits.js tests/test_logs.sh tests/test_docs_acceptance.py
  tests/test_provider_adapter.js tests/test_release_package.sh tests/test_static_security.sh tests/test_web_chat_browser.js
  tests/test_wizard.sh tests/test_workflow_contract.sh tests/test_workflow_runtime.sh
  tests/workflow-local-integration.js tests/workflow-runtime.test.js tests/runtime-protocol-server.js
  tests/fixtures/knowledge.md tests/mocks/chown tests/mocks/configuration_docker
  tests/mocks/curl tests/mocks/curl_knowledge_timeout tests/mocks/docker tests/mocks/stat
  tests/fixtures/doctor/curl tests/fixtures/doctor/docker tests/fixtures/doctor/df tests/fixtures/doctor/systemctl
  "docs/releases/${VERSION_VALUE}.md"
  "docs/reports/${VERSION_VALUE}-report.md"
)
for relative in "${RELEASE_FILES[@]}"; do
  [[ "$relative" != /* && "$relative" != ".." && "$relative" != ../* \
    && "$relative" != */../* && "$relative" != *\\* && "$relative" != *$'\n'* \
    && "$relative" != *$'\r'* ]] \
    || { printf '错误：发布文件路径不安全：%s\n' "$relative" >&2; exit 1; }
  git -C "$PROJECT_ROOT" ls-files --error-unmatch -- "$relative" >/dev/null 2>&1 \
    || { printf '错误：发布清单文件尚未提交：%s\n' "$relative" >&2; exit 1; }
  [[ -f "${PROJECT_ROOT}/${relative}" && ! -L "${PROJECT_ROOT}/${relative}" ]] \
    || { printf '错误：发布源不是安全普通文件：%s\n' "$relative" >&2; exit 1; }
  printf '%s\0' "$relative" >> "$LIST_FILE"
done
sort -z -o "$LIST_FILE" "$LIST_FILE"

for required in VERSION get.sh install.sh manage.sh update.sh uninstall.sh docker-compose.yml \
  scripts/common.sh scripts/bootstrap.sh scripts/wizard.sh scripts/package-release.sh \
  scripts/configuration.sh scripts/knowledge.sh scripts/provider.sh scripts/provider-adapter.js \
  scripts/launcher.sh scripts/doctor.sh scripts/migration.sh scripts/full-backup.sh scripts/archive-guard.py \
  scripts/materials.sh scripts/logs.sh scripts/log-redact.py config/logging.yaml.example \
  n8n/workflow.json n8n/runtime.js n8n/runtime-cli.js n8n/web-chat.js config/app.yaml config/provider.yaml.example; do
  grep -zFxq -- "$required" "$LIST_FILE" \
    || { printf '错误：发布清单缺少必要文件：%s\n' "$required" >&2; exit 1; }
done

tar --create --file - \
  --directory "$PROJECT_ROOT" \
  --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner \
  --transform "s,^,ai-support-${VERSION_VALUE}/," \
  --null --files-from "$LIST_FILE" | gzip -n > "$ARCHIVE_TEMP"
chmod 0644 "$ARCHIVE_TEMP"
(
  cd -- "$WORK_DIR"
  sha256sum "$ARCHIVE_NAME" > SHA256SUMS
)
chmod 0644 "$CHECKSUM_TEMP"
mv -f -- "$ARCHIVE_TEMP" "$ARCHIVE_PATH"
mv -f -- "$CHECKSUM_TEMP" "$CHECKSUM_PATH"
install -m 0755 -- "$PROJECT_ROOT/get.sh" "$OUTPUT_DIR/get.sh"
trap - EXIT INT TERM
rm -rf -- "$WORK_DIR"

printf '发布包：%s\n' "$ARCHIVE_PATH"
printf '校验文件：%s\n' "$CHECKSUM_PATH"
printf '入口审计资产：%s/get.sh\n' "$OUTPUT_DIR"
