#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
TEST_ROOT=$(mktemp -d "${PROJECT_ROOT}/.test-runtime.release-package.XXXXXX")
PASSED=0

cleanup() {
  if [[ "$TEST_ROOT" == "${PROJECT_ROOT}"/.test-runtime.release-package.* && -d "$TEST_ROOT" ]]; then
    rm -rf -- "$TEST_ROOT"
  fi
}
trap cleanup EXIT

fail() {
  printf '发布包验收失败：%s\n' "$1" >&2
  exit 1
}

pass() {
  ((PASSED += 1))
  printf '通过：%s\n' "$1"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "缺少测试命令：$1"
}

require_regular_file() {
  [[ -f "$1" && ! -L "$1" ]] || fail "缺少安全普通文件：$1"
}

require_executable_file() {
  require_regular_file "$1"
  [[ -x "$1" ]] || fail "生产入口不可执行：$1"
}

assert_contains() {
  local file=$1
  local pattern=$2
  local description=$3
  grep -Eq -- "$pattern" "$file" || fail "$description"
}

run_lightweight_option() {
  local root=$1
  local relative=$2
  local option=$3
  local expected=$4
  local label=$5
  local output
  output="${TEST_ROOT}/$(tr '/-' '__' <<< "${relative}-${option}").log"

  if ! (
    cd -- "${TEST_ROOT}/foreign-cwd"
    /usr/bin/env -i PATH="${MINIMAL_BIN}" LANG=C.UTF-8 \
      "${root}/${relative}" "$option"
  ) > "$output" 2>&1; then
    fail "${label} 在无 Git、Docker、curl、jq 的最小 PATH 中执行失败"
  fi
  [[ -s "$output" ]] || fail "${label} 没有输出"
  grep -Fq -- "$expected" "$output" || fail "${label} 输出不符合契约"
}

normalize_archive_entry() {
  local entry=${1#./}
  entry=${entry%/}
  if [[ "$entry" == ai-support-*/* ]]; then
    entry=${entry#*/}
  elif [[ "$entry" == ai-support-* ]]; then
    entry=""
  fi
  printf '%s\n' "$entry"
}

for command_name in awk bash dirname env find git grep gzip jq ln mkdir mkfifo mktemp rm sed sha256sum stat tar timeout tr wc; do
  require_command "$command_name"
done

VERSION_VALUE=$(<"${PROJECT_ROOT}/VERSION")
[[ "$VERSION_VALUE" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "VERSION 格式无效"

PRODUCTION_EXECUTABLES=(
  install.sh
  manage.sh
  update.sh
  uninstall.sh
  scripts/bootstrap.sh
  scripts/wizard.sh
  scripts/package-release.sh
)
for relative in "${PRODUCTION_EXECUTABLES[@]}"; do
  require_executable_file "${PROJECT_ROOT}/${relative}"
done
require_regular_file "${PROJECT_ROOT}/scripts/common.sh"
bash -n \
  "${PROJECT_ROOT}/install.sh" \
  "${PROJECT_ROOT}/manage.sh" \
  "${PROJECT_ROOT}/update.sh" \
  "${PROJECT_ROOT}/uninstall.sh" \
  "${PROJECT_ROOT}/scripts/bootstrap.sh" \
  "${PROJECT_ROOT}/scripts/wizard.sh" \
  "${PROJECT_ROOT}/scripts/package-release.sh"
pass "生产入口存在、可执行且 Bash 语法有效"

assert_contains "${PROJECT_ROOT}/install.sh" \
  'source .*scripts/(bootstrap|wizard)\.sh' \
  "install.sh 未加载 bootstrap/wizard 生产实现"
grep -Fq 'bootstrap_prepare_minimal_dependencies' "${PROJECT_ROOT}/install.sh" \
  || fail "install.sh 未在向导前调用最小依赖引导"
grep -Fq 'bootstrap_prepare_docker_runtime' "${PROJECT_ROOT}/install.sh" \
  || fail "install.sh 未在向导确认后调用 Docker 运行时引导"
grep -Fq 'quick_init_wizard' "${PROJECT_ROOT}/install.sh" \
  || fail "install.sh 未实际调用 quick_init_wizard"
grep -Fq 'Dpkg::Use-Pty=0' "${PROJECT_ROOT}/scripts/bootstrap.sh" \
  || fail "apt 自动安装未关闭不可审计的 PTY 动画"
grep -Fq "COMPOSE_PROGRESS=\"\$progress\"" "${PROJECT_ROOT}/scripts/common.sh" \
  || fail "Compose 生产入口未在 dumb/日志终端使用稳定进度输出"
for script_name in bootstrap.sh wizard.sh package-release.sh; do
  grep -Fq "scripts/${script_name}" "${PROJECT_ROOT}/scripts/common.sh" \
    || fail "部署复制清单未包含 ${script_name}"
  SNAPSHOT_SCRIPT_LIST=$(awk '
    /^(SCRIPT_FILES|OPTIONAL_SCRIPT_FILES)=\(/ { capture = 1 }
    capture { print }
    capture && /\)/ { capture = 0 }
  ' "${PROJECT_ROOT}/scripts/snapshot.sh")
  grep -Fq "$script_name" <<< "$SNAPSHOT_SCRIPT_LIST" \
    || fail "版本快照清单未包含 ${script_name}"
  ROLLBACK_ALLOW_LIST=$(awk '
    /^is_allowed_snapshot_path\(\)/ { capture = 1 }
    capture { print }
    capture && /^}/ { exit }
  ' "${PROJECT_ROOT}/scripts/rollback.sh")
  grep -Fq "$script_name" <<< "$ROLLBACK_ALLOW_LIST" \
    || fail "回滚归档允许路径未覆盖 ${script_name}"
  ROLLBACK_SCRIPT_LIST=$(awk '
    /^SCRIPT_FILES=\(/ { capture = 1 }
    capture { print }
    capture && /\)/ { exit }
  ' "${PROJECT_ROOT}/scripts/rollback.sh")
  grep -Fq "$script_name" <<< "$ROLLBACK_SCRIPT_LIST" \
    || fail "回滚恢复清单未包含 ${script_name}"
done
assert_contains "${PROJECT_ROOT}/manage.sh" \
  'SCRIPT_DIR[^\n]*install\.sh|\$\{SCRIPT_DIR\}/install\.sh' \
  "manage.sh 的首次安装入口未调用同目录 install.sh"
read -r CRISP_CHECK_LINE READY_MARKER_LINE LOCAL_READY_MARKER_LINE WIZARD_CLEANUP_LINE < <(awk '
  index($0, "if crisp_api_check") { crisp_check_line = NR }
  crisp_check_line > 0 && ready_line == 0 \
    && index($0, "write_installation_marker") && $0 ~ / ready/ {
    ready_line = NR
  }
  crisp_check_line > 0 && local_ready_line == 0 \
    && index($0, "write_installation_marker") && $0 ~ / local-ready/ {
    local_ready_line = NR
  }
  crisp_check_line > 0 && local_ready_line > 0 && cleanup_line == 0 \
    && index($0, "WIZARD_RESULT") && tolower($0) ~ /(rm|remove|delete|cleanup)/ {
    cleanup_line = NR
  }
  END { print crisp_check_line + 0, ready_line + 0, local_ready_line + 0, cleanup_line + 0 }
' "${PROJECT_ROOT}/install.sh")
(( CRISP_CHECK_LINE > 0 \
  && READY_MARKER_LINE > CRISP_CHECK_LINE \
  && LOCAL_READY_MARKER_LINE > READY_MARKER_LINE \
  && WIZARD_CLEANUP_LINE > LOCAL_READY_MARKER_LINE )) \
  || fail "install.sh 完成真实启动并提交 ready/local-ready 后未清理含凭据的 quick-init.json"
pass "安装、首次管理、升级与回滚均接入新生产入口"

SOURCE_PROBE="${TEST_ROOT}/source-probe"
mkdir -p -- "$SOURCE_PROBE"
if ! (
  cd -- "$SOURCE_PROBE"
  # 内层 Bash 通过位置参数接收路径。
  # shellcheck disable=SC2016
  /usr/bin/env -i PATH="$PATH" LANG=C.UTF-8 /bin/bash -c '
    set +e +u
    set +o pipefail
    before_options=$(set +o)
    before_exports=$(export -p)
    source "$1"
    after_options=$(set +o)
    after_exports=$(export -p)
    [[ "$after_options" == "$before_options" ]] || exit 20
    [[ "$after_exports" == "$before_exports" ]] || exit 21
    declare -F bootstrap_prepare_minimal_dependencies >/dev/null || exit 22
    declare -F bootstrap_prepare_docker_runtime >/dev/null || exit 23
    declare -F bootstrap_prepare_host >/dev/null || exit 24
    declare -F bootstrap_check_host >/dev/null || exit 25
  ' bash "${PROJECT_ROOT}/scripts/bootstrap.sh"
); then
  fail "bootstrap.sh 无法无副作用地 source 或缺少约定函数"
fi
[[ -z "$(find "$SOURCE_PROBE" -mindepth 1 -print -quit)" ]] \
  || fail "source bootstrap.sh 产生了文件副作用"
if ! (
  cd -- "$SOURCE_PROBE"
  # 内层 Bash 通过位置参数接收路径。
  # shellcheck disable=SC2016
  /usr/bin/env -i PATH="$PATH" LANG=C.UTF-8 /bin/bash -c '
    set +e +u
    set +o pipefail
    before_options=$(set +o)
    before_exports=$(export -p)
    source "$1"
    after_options=$(set +o)
    after_exports=$(export -p)
    [[ "$after_options" == "$before_options" ]] || exit 20
    [[ "$after_exports" == "$before_exports" ]] || exit 21
    declare -F quick_init_wizard >/dev/null || exit 22
  ' bash "${PROJECT_ROOT}/scripts/wizard.sh"
); then
  fail "wizard.sh 无法无副作用地 source 或缺少 quick_init_wizard"
fi
[[ -z "$(find "$SOURCE_PROBE" -mindepth 1 -print -quit)" ]] \
  || fail "source wizard.sh 产生了文件副作用"
pass "bootstrap 与 wizard 可安全 source 且暴露生产函数"

SPECIAL_ENV_FILE="${TEST_ROOT}/special.env"
SPECIAL_VALUE=$'Ab $dollar#hash "double" \'single\' \\slash = tail'
# 内层 Bash 读取显式注入的测试值和位置参数。
# shellcheck disable=SC2016
if ! /usr/bin/env -i PATH="$PATH" LANG=C.UTF-8 SPECIAL_VALUE="$SPECIAL_VALUE" /bin/bash -c '
  set -euo pipefail
  source "$1"
  env_set "$2" TEST_SPECIAL "$SPECIAL_VALUE"
  actual=$(env_get "$2" TEST_SPECIAL)
  [[ "$actual" == "$SPECIAL_VALUE" ]]
  [[ "$(stat -c %a "$2")" == 600 ]]
' bash "${PROJECT_ROOT}/scripts/common.sh" "$SPECIAL_ENV_FILE"; then
  fail "env_set/env_get 未保持包含空格、引号、反斜线、$、# 和 = 的值"
fi
if grep -REq -- '(^|[[:space:]])(source|\.)[[:space:]]+[^#\n]*\.env([[:space:]]|$)' \
  "${PROJECT_ROOT}"/*.sh "${PROJECT_ROOT}"/scripts/*.sh; then
  fail "生产脚本不得 source .env"
fi
pass "特殊字符配置往返一致且未 source .env"

DIST_DIR="${TEST_ROOT}/dist"
mkdir -p -- "$DIST_DIR"
if ! "${PROJECT_ROOT}/scripts/package-release.sh" --output-dir "$DIST_DIR" \
  > "${TEST_ROOT}/package.log" 2>&1; then
  fail "正式 package-release.sh 执行失败"
fi
ARCHIVE="${DIST_DIR}/ai-support-${VERSION_VALUE}.tar.gz"
CHECKSUMS="${DIST_DIR}/SHA256SUMS"
require_regular_file "$ARCHIVE"
require_regular_file "$CHECKSUMS"
[[ "$(wc -l < "$CHECKSUMS")" -eq 1 ]] || fail "SHA256SUMS 必须只列出本版本归档"
assert_contains "$CHECKSUMS" \
  "^[0-9a-f]{64}  ai-support-${VERSION_VALUE//./\\.}\\.tar\\.gz$" \
  "SHA256SUMS 格式错误或包含目录路径"
if ! (cd -- "$DIST_DIR" && sha256sum --check SHA256SUMS >/dev/null); then
  fail "发布包 SHA-256 校验失败"
fi

ARCHIVE_LIST="${TEST_ROOT}/archive.list"
tar --list --gzip --file "$ARCHIVE" > "$ARCHIVE_LIST"
[[ -s "$ARCHIVE_LIST" ]] || fail "发布包为空"
while IFS= read -r entry; do
  relative=$(normalize_archive_entry "$entry")
  [[ -n "$relative" ]] || continue
  git -C "$PROJECT_ROOT" ls-files --error-unmatch -- "$relative" >/dev/null 2>&1 \
    || fail "发布包包含未跟踪文件：$entry"
  [[ "$relative" != /* && "$relative" != ".." && "$relative" != ../* \
    && "$relative" != */../* && "$relative" != *\\* ]] \
    || fail "发布包存在不安全路径：$entry"
  if [[ "/${relative}/" == *"/.git/"* \
    || "/${relative}/" == *"/.work/"* \
    || "/${relative}/" == *"/dist/"* \
    || "/${relative}/" == *"/.test-tools/"* \
    || "/${relative}/" == *"/.test-runtime"* \
    || "/${relative}/" == *"/.external-e2e"* \
    || "/${relative}/" == *"/node_modules/"* ]]; then
    fail "发布包包含开发缓存或控制目录：$entry"
  fi
  case "$relative" in
    .env|.env.*)
      [[ "$relative" == .env.example ]] || fail "发布包包含实际环境配置：$entry"
      ;;
    config/provider.yaml|config/prompt.md|config/keyword.yaml|config/menu.yaml|config/handoff.yaml|config/tags.yaml|config/feedback.yaml|config/runtime.yaml)
      fail "发布包包含实际业务配置：$entry"
      ;;
    data|data/*|logs|logs/*|backups|backups/*|tmp|tmp/*|*.log|*.pid|*.tmp)
      fail "发布包包含运行数据或日志：$entry"
      ;;
    knowledge/*)
      [[ "$relative" == knowledge/README.md ]] || fail "发布包包含知识库数据：$entry"
      ;;
  esac
done < "$ARCHIVE_LIST"
while IFS= read -r listing; do
  case "${listing:0:1}" in
    -|d) ;;
    *) fail "发布包包含链接或特殊文件" ;;
  esac
done < <(tar --list --verbose --gzip --file "$ARCHIVE")
pass "正式发布包仅含已跟踪源码，不含 Git、开发缓存、实际配置或运行数据"

EXTRACT_DIR="${TEST_ROOT}/extract"
mkdir -p -- "$EXTRACT_DIR"
tar --extract --gzip --file "$ARCHIVE" --directory "$EXTRACT_DIR" \
  --no-same-owner --no-same-permissions
mapfile -d '' -t VERSION_FILES < <(find "$EXTRACT_DIR" -maxdepth 2 -type f -name VERSION -print0)
(( ${#VERSION_FILES[@]} == 1 )) || fail "发布包必须且只能包含一个顶层 VERSION"
PACKAGE_ROOT=$(dirname -- "${VERSION_FILES[0]}")
[[ "$(<"${PACKAGE_ROOT}/VERSION")" == "$VERSION_VALUE" ]] || fail "发布包 VERSION 不一致"
for relative in "${PRODUCTION_EXECUTABLES[@]}"; do
  require_executable_file "${PACKAGE_ROOT}/${relative}"
done
for relative in scripts/common.sh docker-compose.yml n8n/workflow.json \
  config/app.yaml config/provider.yaml.example config/prompt.md.example config/runtime.yaml.example knowledge/README.md \
  scripts/launcher.sh scripts/menu-ui.sh scripts/configuration.sh scripts/knowledge.sh \
  scripts/provider.sh scripts/provider-adapter.js scripts/migration.sh scripts/full-backup.sh \
  scripts/crisp-settings.sh scripts/archive-guard.py n8n/runtime.js n8n/runtime-cli.js n8n/web-chat.js \
  docs/MENU.md docs/CRISP.md docs/TROUBLESHOOTING.md; do
  require_regular_file "${PACKAGE_ROOT}/${relative}"
done
[[ ! -e "${PACKAGE_ROOT}/.git" && ! -e "${PACKAGE_ROOT}/.work" ]] \
  || fail "解压后的发布包包含 .git 或 .work"
pass "发布包版本、生产入口、权限与必要资源完整"

MINIMAL_BIN="${TEST_ROOT}/minimal-bin"
mkdir -p -- "$MINIMAL_BIN" "${TEST_ROOT}/foreign-cwd"
for command_name in bash basename cat dirname grep head sed tr; do
  ln -s -- "$(command -v "$command_name")" "${MINIMAL_BIN}/${command_name}"
done
for relative in install.sh manage.sh update.sh uninstall.sh \
  scripts/bootstrap.sh scripts/wizard.sh scripts/package-release.sh; do
  run_lightweight_option "$PACKAGE_ROOT" "$relative" --help '用法' "${relative} --help"
done
run_lightweight_option "$PACKAGE_ROOT" install.sh --version "$VERSION_VALUE" "install.sh --version"
run_lightweight_option "$PACKAGE_ROOT" manage.sh --version "$VERSION_VALUE" "manage.sh --version"
pass "无 .git 的绝对路径入口可执行 help/version 且不依赖 Docker 或开发工具"

HOST_FIXTURE="${TEST_ROOT}/host-fixture"
mkdir -p -- "${HOST_FIXTURE}/etc/ssl/certs"
printf '%s\n' \
  'ID=debian' \
  'VERSION_ID="12"' \
  'VERSION_CODENAME=bookworm' \
  > "${HOST_FIXTURE}/os-release"
printf '%s\n' 'agent-c-test-ca-bundle' > "${HOST_FIXTURE}/etc/ssl/certs/ca-certificates.crt"
CHECK_OUTPUT="${TEST_ROOT}/bootstrap-check.log"
set +e
/usr/bin/env -i PATH="$PATH" LANG=C.UTF-8 \
  CRISP_AI_BOOTSTRAP_TEST_MODE=1 \
  CRISP_AI_BOOTSTRAP_OS_RELEASE="${HOST_FIXTURE}/os-release" \
  CRISP_AI_BOOTSTRAP_ETC_ROOT="${HOST_FIXTURE}/etc" \
  "${PACKAGE_ROOT}/scripts/bootstrap.sh" --check > "$CHECK_OUTPUT" 2>&1
CHECK_STATUS=$?
set -e
(( CHECK_STATUS != 126 && CHECK_STATUS != 127 )) || fail "bootstrap --check 无法执行"
[[ -s "$CHECK_OUTPUT" ]] || fail "bootstrap --check 没有明确输出"
pass "bootstrap --check 调用真实主机检查并明确报告结果"

WIZARD_RESULT="${TEST_ROOT}/wizard-eof.json"
set +e
# 内层 Bash 通过位置参数接收路径。
# shellcheck disable=SC2016
timeout 15 /usr/bin/env -i PATH="$PATH" LANG=C.UTF-8 /bin/bash -c '
  set -euo pipefail
  source "$1"
  quick_init_wizard "$2"
' bash "${PACKAGE_ROOT}/scripts/wizard.sh" "$WIZARD_RESULT" \
  </dev/null > "${TEST_ROOT}/wizard-eof.log" 2>&1
WIZARD_EOF_STATUS=$?
set -e
(( WIZARD_EOF_STATUS != 124 )) || fail "quick_init_wizard 遇到 EOF 后未在有限时间退出"
[[ ! -s "$WIZARD_RESULT" ]] || fail "quick_init_wizard 遇到 EOF 仍生成了有效配置"
pass "quick_init_wizard 遇到 EOF 安全退出"

PARTIAL_WIZARD_RESULT="${TEST_ROOT}/wizard-partial.json"
set +e
timeout 15 /usr/bin/env -i PATH="$PATH" LANG=C.UTF-8 \
  "${PACKAGE_ROOT}/scripts/wizard.sh" --output "$PARTIAL_WIZARD_RESULT" \
  <<< 'https://provider.invalid/v1' \
  > "${TEST_ROOT}/wizard-partial.log" 2>&1
PARTIAL_WIZARD_STATUS=$?
set -e
(( PARTIAL_WIZARD_STATUS == 2 )) \
  || fail "quick_init_wizard 完成一步后遇到 EOF 未以取消状态 2 退出"
require_regular_file "$PARTIAL_WIZARD_RESULT"
[[ "$(stat -c %a "$PARTIAL_WIZARD_RESULT")" == 600 ]] \
  || fail "quick_init_wizard collecting 状态文件权限不是 0600"
jq -e '
  .status == "collecting"
  and .next_step == 2
  and .provider.base_url == "https://provider.invalid/v1"
' "$PARTIAL_WIZARD_RESULT" >/dev/null \
  || fail "quick_init_wizard 未原子保留可继续的 collecting 状态"
pass "quick_init_wizard 中断进度以 0600 collecting 状态安全保留"

FIRST_DEPLOY="${TEST_ROOT}/first-install"
set +e
timeout 30 /usr/bin/env -i PATH="$PATH" LANG=C.UTF-8 \
  CRISP_AI_BOOTSTRAP_TEST_MODE=1 \
  CRISP_AI_BOOTSTRAP_OS_RELEASE="${HOST_FIXTURE}/os-release" \
  CRISP_AI_BOOTSTRAP_ETC_ROOT="${HOST_FIXTURE}/etc" \
  "${PACKAGE_ROOT}/install.sh" --deploy-dir "$FIRST_DEPLOY" --skip-start \
  </dev/null > "${TEST_ROOT}/install-eof.log" 2>&1
INSTALL_EOF_STATUS=$?
set -e
(( INSTALL_EOF_STATUS != 124 )) || fail "install.sh 首次向导遇到 EOF 后未在有限时间退出"
if [[ -f "${FIRST_DEPLOY}/.crisp-ai-installation" ]] \
  && grep -Fq 'state=ready' "${FIRST_DEPLOY}/.crisp-ai-installation"; then
  fail "install.sh 在 EOF 取消后错误提交 ready 状态"
fi
assert_contains "${TEST_ROOT}/install-eof.log" '向导|初始化|输入|取消|中止|结束' \
  "无 .env 首次运行未进入可识别的中文初始化流程"
pass "无 .env 的生产 install.sh 自动进入向导且 EOF 安全"

INTERRUPT_DEPLOY="${TEST_ROOT}/interrupt-install"
INTERRUPT_FIFO="${TEST_ROOT}/interrupt-input.fifo"
INTERRUPT_LOG="${TEST_ROOT}/interrupt-install.log"
mkfifo -- "$INTERRUPT_FIFO"
exec 9<> "$INTERRUPT_FIFO"
set +e
timeout --preserve-status --signal=INT --kill-after=3 10 \
  /usr/bin/env -i PATH="$PATH" LANG=C.UTF-8 TERM=dumb \
  CRISP_AI_BOOTSTRAP_TEST_MODE=1 \
  CRISP_AI_BOOTSTRAP_OS_RELEASE="${HOST_FIXTURE}/os-release" \
  CRISP_AI_BOOTSTRAP_ETC_ROOT="${HOST_FIXTURE}/etc" \
  "${PACKAGE_ROOT}/install.sh" --deploy-dir "$INTERRUPT_DEPLOY" --skip-start \
  <&9 > "$INTERRUPT_LOG" 2>&1
INTERRUPT_STATUS=$?
set -e
exec 9>&-
(( INTERRUPT_STATUS == 130 || INTERRUPT_STATUS == 2 )) \
  || fail "install.sh 收到 SIGINT 后退出码异常：${INTERRUPT_STATUS}"
assert_contains "$INTERRUPT_LOG" '\[1/10\] AI API 地址' \
  "install.sh 未进入可发送 SIGINT 的首次向导"
assert_contains "$INTERRUPT_LOG" '安装已中断.*下次运行.*恢复' \
  "install.sh 收到 SIGINT 后没有明确中文恢复提示"
if [[ -f "${INTERRUPT_DEPLOY}/.crisp-ai-installation" ]] \
  && grep -Fq 'state=ready' "${INTERRUPT_DEPLOY}/.crisp-ai-installation"; then
  fail "install.sh 收到 SIGINT 后错误提交 ready 状态"
fi
pass "生产 install.sh 收到 SIGINT 后明确退出并保留恢复入口"

MANAGE_DEPLOY="${TEST_ROOT}/manage-first-run"
set +e
timeout 15 /usr/bin/env -i PATH="$PATH" LANG=C.UTF-8 \
  CRISP_AI_BOOTSTRAP_TEST_MODE=1 \
  CRISP_AI_BOOTSTRAP_OS_RELEASE="${HOST_FIXTURE}/os-release" \
  CRISP_AI_BOOTSTRAP_ETC_ROOT="${HOST_FIXTURE}/etc" \
  "${PACKAGE_ROOT}/manage.sh" --deploy-dir "$MANAGE_DEPLOY" \
  </dev/null > "${TEST_ROOT}/manage-eof.log" 2>&1
MANAGE_EOF_STATUS=$?
set -e
(( MANAGE_EOF_STATUS != 124 )) || fail "manage.sh 遇到 EOF 后未在有限时间退出"
if [[ -f "${MANAGE_DEPLOY}/.crisp-ai-installation" ]] \
  && grep -Fq 'state=ready' "${MANAGE_DEPLOY}/.crisp-ai-installation"; then
  fail "manage.sh 在 EOF 后错误创建 ready 部署"
fi
assert_contains "${TEST_ROOT}/manage-eof.log" '安装|初始化|退出' \
  "未安装状态的 manage.sh 未提供首次安装入口"
pass "manage.sh 未安装菜单与 EOF 边界安全"

SECRET_PATTERN='AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}|sk-[A-Za-z0-9_-]{20,}|gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|-----BEGIN ([A-Z0-9 ]+ )?PRIVATE KEY-----'
PACKAGE_SECRET_MATCHES=$(grep -RIlE -- "$SECRET_PATTERN" "$PACKAGE_ROOT" 2>/dev/null || true)
[[ -z "$PACKAGE_SECRET_MATCHES" ]] || fail "发布包内容疑似包含真实密钥"
for log_file in "${TEST_ROOT}"/*.log; do
  [[ -f "$log_file" ]] || continue
  if grep -Eq -- "$SECRET_PATTERN" "$log_file"; then
    fail "专项测试日志疑似泄露密钥：$(basename -- "$log_file")"
  fi
done
pass "发布包与入口日志未命中常见真实密钥模式"

printf '发布包专项验收完成：%d 项通过\n' "$PASSED"
