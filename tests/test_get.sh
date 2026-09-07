#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
TEST_ROOT=$(mktemp -d "${PROJECT_ROOT}/.test-runtime.get.XXXXXX")
SERVER_PID=""
SUDO_TEST_ROOT=""
PASSED=0

cleanup() {
  if [[ -n "$SERVER_PID" ]]; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  if [[ "$TEST_ROOT" == "${PROJECT_ROOT}"/.test-runtime.get.* \
    && -d "$TEST_ROOT" && ! -L "$TEST_ROOT" ]]; then
    rm -rf -- "$TEST_ROOT"
  fi
  if [[ -n "$SUDO_TEST_ROOT" && "$SUDO_TEST_ROOT" == /tmp/crispai-get-sudo-test.* \
    && -d "$SUDO_TEST_ROOT" && ! -L "$SUDO_TEST_ROOT" ]]; then
    rm -rf -- "$SUDO_TEST_ROOT"
  fi
}
trap cleanup EXIT

fail() {
  printf '在线安装入口测试失败：%s\n' "$1" >&2
  exit 1
}

pass() {
  (( PASSED += 1 ))
  printf '通过：%s\n' "$1"
}

assert_contains() {
  local file=$1 text=$2 description=$3
  grep -Fq -- "$text" "$file" || fail "$description"
}

recommended_command() {
  awk '
    /CRISPAI_RECOMMENDED_INSTALL_COMMAND/ { marker = 1; next }
    marker && /^```bash$/ { block = 1; next }
    block && /^```$/ { exit }
    block { print }
  ' "$1"
}

for command_name in bash chmod curl grep gzip kill ln mkdir mktemp python3 rm script sha256sum tar; do
  command -v "$command_name" >/dev/null 2>&1 || fail "缺少测试命令：${command_name}"
done
bash -n "${PROJECT_ROOT}/get.sh" || fail 'get.sh Bash 语法无效'
[[ -x "${PROJECT_ROOT}/get.sh" ]] || fail 'get.sh 不可执行'
README_COMMAND=$(recommended_command "${PROJECT_ROOT}/README.md")
INSTALL_COMMAND=$(recommended_command "${PROJECT_ROOT}/docs/INSTALL.md")
[[ -n "$README_COMMAND" && "$README_COMMAND" == "$INSTALL_COMMAND" \
  && "$(wc -l <<< "$README_COMMAND")" == 1 ]] \
  || fail 'README 与 INSTALL 的唯一推荐命令不是逐字一致的一行'
[[ "$README_COMMAND" == *'https://raw.githubusercontent.com/statusX7/ai-support/main/get.sh'* \
  && "$README_COMMAND" == *'curl -q '* \
  && "$README_COMMAND" != *'curl | bash'* ]] \
  || fail '推荐命令没有使用安全临时文件或没有禁用 curl 用户配置'
if grep -Eiq '浏览器下载|上传服务器|private 仓库|私有仓库.*(下载|登录)' \
  "${PROJECT_ROOT}/README.md" "${PROJECT_ROOT}/docs/INSTALL.md"; then
  fail '活跃新手文档仍要求浏览器上传或私有仓库登录'
fi
pass 'README 与 INSTALL 冻结同一条公共临时文件安装命令'

COMMAND_TEST="${TEST_ROOT}/recommended-command"
COMMAND_BIN="${COMMAND_TEST}/bin"
mkdir -p -- "$COMMAND_BIN"
for command_name in bash chmod env mktemp rm; do
  ln -s -- "$(command -v "$command_name")" "${COMMAND_BIN}/${command_name}"
done
COMMAND_CAPTURE="${COMMAND_TEST}/get.capture"
APT_CAPTURE="${COMMAND_TEST}/apt.capture"
MOCK_GET="${COMMAND_TEST}/downloaded-get.sh"
cat > "$MOCK_GET" <<'MOCK_GET_SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
printf 'recommended-command-ran\n' > "${COMMAND_CAPTURE:?}"
# crispai-get-end
MOCK_GET_SCRIPT
cat > "${COMMAND_TEST}/curl.fixture" <<'MOCK_CURL'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == -q ]] || exit 91
output=""
while (( $# > 0 )); do
  case "$1" in
    --output) output=$2; shift 2 ;;
    *) shift ;;
  esac
done
[[ -n "$output" ]]
/bin/cp -- "${MOCK_GET:?}" "$output"
MOCK_CURL
cat > "${COMMAND_BIN}/apt-get" <<'MOCK_APT'
#!/usr/bin/env bash
set -euo pipefail
printf '%q ' "$@" >> "${APT_CAPTURE:?}"
printf '\n' >> "${APT_CAPTURE:?}"
if [[ " $* " == *' install '* ]]; then
  /bin/cp -- "${COMMAND_CURL_FIXTURE:?}" "${COMMAND_BIN:?}/curl"
  /bin/chmod 0755 "${COMMAND_BIN:?}/curl"
fi
MOCK_APT
chmod 0755 "$MOCK_GET" "${COMMAND_TEST}/curl.fixture" "${COMMAND_BIN}/apt-get"
: > "$COMMAND_CAPTURE"
: > "$APT_CAPTURE"
env PATH="$COMMAND_BIN" COMMAND_CAPTURE="$COMMAND_CAPTURE" MOCK_GET="$MOCK_GET" \
  APT_CAPTURE="$APT_CAPTURE" COMMAND_CURL_FIXTURE="${COMMAND_TEST}/curl.fixture" \
  COMMAND_BIN="$COMMAND_BIN" /bin/bash -c "$README_COMMAND"
assert_contains "$COMMAND_CAPTURE" 'recommended-command-ran' \
  '推荐命令在 curl 缺失时没有补齐工具并执行完整 get.sh'
assert_contains "$APT_CAPTURE" 'install' '推荐命令在 curl 缺失时没有调用受限包安装'
pass '推荐命令缺少 curl 时自动补齐，并检查下载结束标记后执行'

: > "$COMMAND_CAPTURE"
: > "$APT_CAPTURE"
/bin/cp -- "${COMMAND_TEST}/curl.fixture" "${COMMAND_BIN}/curl"
chmod 0755 "${COMMAND_BIN}/curl"
env PATH="$COMMAND_BIN" COMMAND_CAPTURE="$COMMAND_CAPTURE" MOCK_GET="$MOCK_GET" \
  APT_CAPTURE="$APT_CAPTURE" COMMAND_CURL_FIXTURE="${COMMAND_TEST}/curl.fixture" \
  COMMAND_BIN="$COMMAND_BIN" /bin/bash -c "$README_COMMAND"
assert_contains "$COMMAND_CAPTURE" 'recommended-command-ran' \
  '推荐命令在已有 curl 时没有运行 get.sh'
[[ ! -s "$APT_CAPTURE" ]] || fail '推荐命令在 curl/CA 已就绪时仍重复调用 apt'
pass '推荐命令已有安全下载工具时不重复执行 apt'

SERVER_ROOT="${TEST_ROOT}/server"
BUILD_ROOT="${TEST_ROOT}/build"
mkdir -p -- "$SERVER_ROOT" "$BUILD_ROOT"

write_mock_package() {
  local release=$1 layout=${2:-current} package asset_dir
  local relative
  local -a required=(
    VERSION install.sh manage.sh update.sh uninstall.sh docker-compose.yml
    scripts/bootstrap.sh scripts/common.sh scripts/wizard.sh scripts/launcher.sh
    scripts/healthcheck.sh scripts/configuration.sh scripts/knowledge.sh scripts/provider.sh
    scripts/provider-adapter.js n8n/workflow.json n8n/runtime.js
    config/app.yaml config/provider.yaml.example
  )
  if [[ "$layout" == current || "$layout" == v120 ]]; then
    required+=(
      .env.example get.sh
      config/Caddyfile.example config/feedback.yaml.example config/handoff.yaml.example
      config/keyword.yaml.example config/menu.yaml.example config/prompt.md.example
      config/runtime.yaml.example config/tags.yaml.example knowledge/README.md
      n8n/runtime-cli.js n8n/build-workflow.js n8n/web-chat.js
      scripts/analytics.sh scripts/backup.sh scripts/doctor.sh scripts/package-release.sh
      scripts/restore.sh scripts/rollback.sh scripts/snapshot.sh scripts/menu-ui.sh
      scripts/migration.sh scripts/crisp-settings.sh scripts/full-backup.sh scripts/archive-guard.py
    )
    if [[ "$layout" == v120 ]]; then
      required+=(scripts/materials.sh scripts/logs.sh scripts/log-redact.py config/logging.yaml.example)
    fi
  elif [[ "$layout" != legacy ]]; then
    fail "未知测试包布局：${layout}"
  fi
  package="${BUILD_ROOT}/ai-support-${release}"
  asset_dir="${SERVER_ROOT}/releases/download/${release}"
  mkdir -p -- "$package" "$asset_dir"
  for relative in "${required[@]}"; do
    mkdir -p -- "$(dirname -- "${package}/${relative}")"
    printf 'fixture:%s\n' "$relative" > "${package}/${relative}"
  done
  printf '%s\n' "$release" > "${package}/VERSION"
  cat > "${package}/install.sh" <<'MOCK_INSTALL'
#!/usr/bin/env bash
set -euo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
deploy_dir=""
original=("$@")
while (( $# > 0 )); do
  case "$1" in
    --deploy-dir) deploy_dir=$2; shift 2 ;;
    *) shift ;;
  esac
done
[[ -n "$deploy_dir" ]]
mkdir -p -- "$deploy_dir/config"
printf 'ai-support\nstate=local-ready\ninstalled_version=%s\n' "$(<"${script_dir}/VERSION")" \
  > "${deploy_dir}/.crisp-ai-installation"
cp -- "${script_dir}/manage.sh" "${deploy_dir}/manage.sh"
cp -- "${script_dir}/VERSION" "${deploy_dir}/VERSION"
chmod 0755 "${deploy_dir}/manage.sh"
{
  printf 'action=install\n'
  printf 'cwd=%s\n' "$PWD"
  printf 'stdin_tty=%s\n' "$([[ -t 0 ]] && printf yes || printf no)"
  printf 'args='
  printf '%q ' "${original[@]}"
  printf '\n'
} >> "${MOCK_CAPTURE:?}"
MOCK_INSTALL
  cat > "${package}/manage.sh" <<'MOCK_MANAGE'
#!/usr/bin/env bash
set -euo pipefail
{
  printf 'action=manage\n'
  printf 'cwd=%s\n' "$PWD"
  printf 'args='
  printf '%q ' "$@"
  printf '\n'
} >> "${MOCK_CAPTURE:?}"
MOCK_MANAGE
  cat > "${package}/update.sh" <<'MOCK_UPDATE'
#!/usr/bin/env bash
set -euo pipefail
deploy_dir=""
source_dir=""
original=("$@")
while (( $# > 0 )); do
  case "$1" in
    --deploy-dir) deploy_dir=$2; shift 2 ;;
    --source-dir) source_dir=$2; shift 2 ;;
    *) shift ;;
  esac
done
[[ -n "$deploy_dir" && -n "$source_dir" ]]
mkdir -p -- "$deploy_dir/config"
cp -- "${source_dir}/VERSION" "${deploy_dir}/VERSION"
printf 'ai-support\nstate=local-ready\ninstalled_version=%s\n' "$(<"${source_dir}/VERSION")" \
  > "${deploy_dir}/.crisp-ai-installation"
{
  printf 'action=update\n'
  printf 'cwd=%s\n' "$PWD"
  printf 'args='
  printf '%q ' "${original[@]}"
  printf '\n'
} >> "${MOCK_CAPTURE:?}"
MOCK_UPDATE
  chmod 0755 "${package}/install.sh" "${package}/manage.sh" "${package}/update.sh"
  cp -- "${PROJECT_ROOT}/scripts/launcher.sh" "${package}/scripts/launcher.sh"
  cp -- "${PROJECT_ROOT}/scripts/common.sh" "${package}/scripts/common.sh"
  repack_mock_package "$release"
}

repack_mock_package() {
  local release=$1
  local asset_dir="${SERVER_ROOT}/releases/download/${release}"
  mkdir -p -- "$asset_dir"
  tar --create --gzip --file "${asset_dir}/ai-support-${release}.tar.gz" \
    --directory "$BUILD_ROOT" "ai-support-${release}"
  (
    cd -- "$asset_dir"
    sha256sum "ai-support-${release}.tar.gz" > SHA256SUMS
  )
}

write_mock_package v1.1.0 legacy
write_mock_package v1.1.1
write_mock_package v1.1.2
write_mock_package v1.2.0 v120
V120_REQUIRED=(scripts/materials.sh scripts/logs.sh scripts/log-redact.py config/logging.yaml.example)
for entry_index in "${!V120_REQUIRED[@]}"; do
  missing_release="v1.2.$((entry_index + 1))"
  write_mock_package "$missing_release" v120
  rm -f -- "${BUILD_ROOT}/ai-support-${missing_release}/${V120_REQUIRED[entry_index]}"
  repack_mock_package "$missing_release"
done

# SHA 正确但缺少次级生产模块时，也必须在执行 install.sh 前拒绝。
write_mock_package v1.1.8
rm -f -- "${BUILD_ROOT}/ai-support-v1.1.8/scripts/menu-ui.sh"
repack_mock_package v1.1.8

# 资产大小协议与硬下载边界专项。
write_mock_package v1.1.10
write_mock_package v1.1.11
write_mock_package v1.1.12

# 有效 checksum 保护下也必须拒绝路径穿越归档。
MALICIOUS_DIR="${SERVER_ROOT}/releases/download/v1.1.4"
mkdir -p -- "$MALICIOUS_DIR"
printf 'escape\n' > "${TEST_ROOT}/escape-source"
tar --create --gzip --file "${MALICIOUS_DIR}/ai-support-v1.1.4.tar.gz" \
  --directory "$TEST_ROOT" --transform='s#^escape-source$#../escape-target#' escape-source
(
  cd -- "$MALICIOUS_DIR"
  sha256sum ai-support-v1.1.4.tar.gz > SHA256SUMS
)

# 校验清单与下载内容不一致。
BAD_HASH_DIR="${SERVER_ROOT}/releases/download/v1.1.5"
mkdir -p -- "$BAD_HASH_DIR"
cp -- "${SERVER_ROOT}/releases/download/v1.1.1/ai-support-v1.1.1.tar.gz" \
  "${BAD_HASH_DIR}/ai-support-v1.1.5.tar.gz"
printf '%064d  ai-support-v1.1.5.tar.gz\n' 0 > "${BAD_HASH_DIR}/SHA256SUMS"

# 清单内出现额外目标时不得让 sha256sum 读取任意路径。
CONFLICT_DIR="${SERVER_ROOT}/releases/download/v1.1.6"
mkdir -p -- "$CONFLICT_DIR"
cp -- "${SERVER_ROOT}/releases/download/v1.1.1/ai-support-v1.1.1.tar.gz" \
  "${CONFLICT_DIR}/ai-support-v1.1.6.tar.gz"
HASH_V116=$(sha256sum "${CONFLICT_DIR}/ai-support-v1.1.6.tar.gz")
HASH_V116=${HASH_V116%% *}
printf '%s  ai-support-v1.1.6.tar.gz\n%s  /etc/passwd\n' "$HASH_V116" "$HASH_V116" \
  > "${CONFLICT_DIR}/SHA256SUMS"

# HTTP 200 HTML 不得被当成发布包。
HTML_DIR="${SERVER_ROOT}/releases/download/v1.1.7"
mkdir -p -- "$HTML_DIR"
printf '<!doctype html><title>login</title>\n' > "${HTML_DIR}/ai-support-v1.1.7.tar.gz"
(
  cd -- "$HTML_DIR"
  sha256sum ai-support-v1.1.7.tar.gz > SHA256SUMS
)

SERVER_SCRIPT="${TEST_ROOT}/server.py"
cat > "$SERVER_SCRIPT" <<'PY_SERVER'
import http.server
import json
import os
import pathlib
import sys
import urllib.parse

root = pathlib.Path(sys.argv[1]).resolve()
port_file = pathlib.Path(sys.argv[2])
access_log = pathlib.Path(sys.argv[3])

class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(root), **kwargs)

    def log_message(self, fmt, *args):
        pass

    def do_GET(self):
        path = urllib.parse.urlsplit(self.path).path
        with access_log.open("a", encoding="utf-8") as output:
            output.write(path + "\n")
        if path == "/latest":
            self.send_response(302)
            self.send_header("Location", f"http://127.0.0.1:{self.server.server_port}/tag/v1.1.1")
            self.end_headers()
            return
        if path.startswith("/tag/"):
            body = b"release\n"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if path.startswith("/api/releases/tags/"):
            tag = path.rsplit("/", 1)[-1]
            asset_dir = root / "releases" / "download" / tag
            archive_name = f"ai-support-{tag}.tar.gz"
            archive_path = asset_dir / archive_name
            checksum_path = asset_dir / "SHA256SUMS"
            archive_size = archive_path.stat().st_size if archive_path.is_file() else 1
            checksum_size = checksum_path.stat().st_size if checksum_path.is_file() else 1
            archive_state = "uploaded"
            if tag == "v1.1.9":
                archive_size = 512 * 1024 * 1024 + 1
            elif tag == "v1.1.10":
                archive_size += 1
            elif tag == "v1.1.12":
                archive_size = max(1, archive_size - 10)
            elif tag == "v1.1.14":
                archive_size = str(archive_size)
            elif tag == "v1.1.15":
                archive_state = "new"
            body = json.dumps({
                "tag_name": tag,
                "draft": False,
                "prerelease": tag == "v1.1.13",
                "published_at": "2026-09-07T00:00:00Z",
                "assets": [
                    {"name": archive_name, "state": archive_state, "size": archive_size},
                    {"name": "SHA256SUMS", "state": "uploaded", "size": checksum_size},
                ],
            }).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        super().do_GET()

server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
port_file.write_text(str(server.server_port), encoding="ascii")
server.serve_forever()
PY_SERVER
PORT_FILE="${TEST_ROOT}/port"
ACCESS_LOG="${TEST_ROOT}/access.log"
: > "$ACCESS_LOG"
python3 "$SERVER_SCRIPT" "$SERVER_ROOT" "$PORT_FILE" "$ACCESS_LOG" &
SERVER_PID=$!
for _ in {1..100}; do
  [[ -s "$PORT_FILE" ]] && break
  sleep 0.05
done
[[ -s "$PORT_FILE" ]] || fail '本地协议服务未启动'
PORT=$(<"$PORT_FILE")
BASE_URL="http://127.0.0.1:${PORT}"

run_tty() {
  local cwd=$1 log=$2 capture=$3
  shift 3
  local command argument
  printf -v command 'cd -- %q && env CRISPAI_GET_TEST_MODE=1 CRISPAI_GET_TEST_LATEST_URL=%q CRISPAI_GET_TEST_RELEASE_ROOT=%q CRISPAI_GET_TEST_RELEASE_API_ROOT=%q CRISPAI_GET_TEST_TAG_PREFIX=%q CRISPAI_GET_TEST_RETRIES=1 CRISPAI_GET_TEST_RETRY_DELAY=0 CRISPAI_GET_TEST_TOTAL_TIMEOUT=%q MOCK_CAPTURE=%q bash %q' \
    "$cwd" "${BASE_URL}/latest" "${BASE_URL}/releases/download" "${BASE_URL}/api/releases/tags" "${BASE_URL}/tag/" \
    "${TEST_TOTAL_TIMEOUT:-3}" \
    "$capture" "${TEST_ROOT}/standalone-get.sh"
  for argument in "$@"; do
    printf -v command '%s %q' "$command" "$argument"
  done
  script -qefc "$command" "$log" >/dev/null 2>&1
}

cp -- "${PROJECT_ROOT}/get.sh" "${TEST_ROOT}/standalone-get.sh"
chmod 0755 "${TEST_ROOT}/standalone-get.sh"

HELP_LOG="${TEST_ROOT}/help.log"
REQUESTS_BEFORE=$(wc -l < "$ACCESS_LOG")
"${TEST_ROOT}/standalone-get.sh" --help > "$HELP_LOG"
"${TEST_ROOT}/standalone-get.sh" --version >> "$HELP_LOG"
REQUESTS_AFTER=$(wc -l < "$ACCESS_LOG")
[[ "$REQUESTS_AFTER" == "$REQUESTS_BEFORE" ]] || fail '--help/--version 意外访问网络'
assert_contains "$HELP_LOG" "$(<"${PROJECT_ROOT}/VERSION")" '--version 没有显示引导器版本'
pass '单文件 --help/--version 不依赖邻接模块、不联网且无需 TTY'

INVALID_LOG="${TEST_ROOT}/invalid.log"
set +e
"${TEST_ROOT}/standalone-get.sh" --release '../v1.1.1' > "$INVALID_LOG" 2>&1
INVALID_STATUS=$?
set -e
[[ "$INVALID_STATUS" == 64 ]] || fail '非法 tag 没有返回参数错误 64'
assert_contains "$INVALID_LOG" '正式版本格式无效' '非法 tag 拒绝原因不清楚'
pass '指定 Release 严格拒绝路径与 tag 注入'

NO_TTY_LOG="${TEST_ROOT}/no-tty.log"
set +e
env CRISPAI_GET_TEST_MODE=1 \
  CRISPAI_GET_TEST_LATEST_URL="${BASE_URL}/latest" \
  CRISPAI_GET_TEST_RELEASE_ROOT="${BASE_URL}/releases/download" \
  CRISPAI_GET_TEST_RELEASE_API_ROOT="${BASE_URL}/api/releases/tags" \
  CRISPAI_GET_TEST_TAG_PREFIX="${BASE_URL}/tag/" \
  bash "${TEST_ROOT}/standalone-get.sh" --release v1.1.1 \
  --deploy-dir "${TEST_ROOT}/no-tty-deploy" > "$NO_TTY_LOG" 2>&1
NO_TTY_STATUS=$?
set -e
[[ "$NO_TTY_STATUS" == 1 && ! -e "${TEST_ROOT}/no-tty-deploy" ]] \
  || fail '无 TTY 执行产生副作用或退出码错误'
assert_contains "$NO_TTY_LOG" '在线安装需要交互终端' '无 TTY 提示不清楚'
pass '无 TTY 在下载和部署副作用前明确退出'

if (( EUID == 0 )) && command -v setpriv >/dev/null 2>&1; then
  SUDO_TEST_ROOT=$(mktemp -d /tmp/crispai-get-sudo-test.XXXXXXXX)
  mkdir -p -- "${SUDO_TEST_ROOT}/bin" "${SUDO_TEST_ROOT}/caller"
  cp -- "${PROJECT_ROOT}/get.sh" "${SUDO_TEST_ROOT}/get.sh"
  SUDO_CAPTURE="${SUDO_TEST_ROOT}/sudo.capture"
  : > "$SUDO_CAPTURE"
  cat > "${SUDO_TEST_ROOT}/bin/sudo" <<'MOCK_SUDO'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == -- && "$2" == bash ]]
script_path=$3
[[ "$script_path" == /tmp/crispai-get-sudo-test.*'/get.sh' ]]
[[ -f "$script_path" && ! -L "$script_path" ]]
[[ "$(stat -c '%a' "$script_path")" == 700 ]]
{
  printf 'sudo_script=%s\n' "$script_path"
  printf 'sudo_args='
  printf '%q ' "$@"
  printf '\n'
} > "${SUDO_CAPTURE:?}"
MOCK_SUDO
  chmod 0755 "${SUDO_TEST_ROOT}/bin/sudo"
  chmod 0700 "${SUDO_TEST_ROOT}/get.sh"
  chown -R 65534:65534 "$SUDO_TEST_ROOT"
  SUDO_TYPESCRIPT="${TEST_ROOT}/sudo.typescript"
  printf -v SUDO_COMMAND 'cd -- %q && env PATH=%q SUDO_CAPTURE=%q setpriv --reuid=65534 --regid=65534 --clear-groups bash %q --release v1.1.1 --deploy-dir /opt/crisp-ai' \
    "${SUDO_TEST_ROOT}/caller" "${SUDO_TEST_ROOT}/bin:/usr/bin:/bin" \
    "$SUDO_CAPTURE" "${SUDO_TEST_ROOT}/get.sh"
  script -qefc "$SUDO_COMMAND" "$SUDO_TYPESCRIPT" >/dev/null 2>&1 \
    || fail '普通用户 sudo 提权参数测试失败'
  assert_contains "$SUDO_CAPTURE" "sudo_script=${SUDO_TEST_ROOT}/get.sh" \
    'sudo 前没有传递安全的真实脚本文件路径'
  assert_contains "$SUDO_CAPTURE" "--_caller-dir ${SUDO_TEST_ROOT}/caller" \
    'sudo 提权没有显式保留原始工作目录'
  pass '普通用户提权前验证安全普通脚本，并显式传递原 cwd'
else
  printf '跳过：当前测试账号无法执行 root→普通用户 sudo 参数专项测试\n'
fi

CALLER_DIR="${TEST_ROOT}/用户 工作目录"
DEPLOY_DIR="${TEST_ROOT}/deploy"
CAPTURE="${TEST_ROOT}/capture.log"
INSTALL_LOG="${TEST_ROOT}/install.typescript"
mkdir -p -- "$CALLER_DIR"
: > "$CAPTURE"
run_tty "$CALLER_DIR" "$INSTALL_LOG" "$CAPTURE" \
  --release v1.1.1 --deploy-dir "$DEPLOY_DIR"
assert_contains "$CAPTURE" 'action=install' '正式包内 install.sh 未被调用'
assert_contains "$CAPTURE" "cwd=${CALLER_DIR}" '原始工作目录没有传给生产安装器'
assert_contains "$CAPTURE" 'stdin_tty=yes' '生产安装器没有连接交互终端'
assert_contains "$CAPTURE" "--deploy-dir ${DEPLOY_DIR}" '部署目录参数没有安全透传'
assert_contains "${DEPLOY_DIR}/config/.online-release" 'release=v1.1.1' '缺少已校验包版本元数据'
assert_contains "${DEPLOY_DIR}/config/.online-release" 'archive_sha256=' '缺少归档 SHA-256 元数据'
pass '单文件指定版本下载、校验、安全解压并从原 cwd 调用生产安装器'

REQUESTS_BEFORE=$(wc -l < "$ACCESS_LOG")
MANAGE_LOG="${TEST_ROOT}/manage.typescript"
run_tty "$CALLER_DIR" "$MANAGE_LOG" "$CAPTURE" --deploy-dir "$DEPLOY_DIR"
REQUESTS_AFTER=$(wc -l < "$ACCESS_LOG")
[[ "$REQUESTS_AFTER" == "$REQUESTS_BEFORE" ]] || fail '同版本已有实例仍访问了 Release'
assert_contains "$CAPTURE" 'action=manage' '同版本已有实例没有进入受管菜单'
pass '已有完整实例直接打开管理菜单，不下载或重问初始化'

REPAIR_DEPLOY="${TEST_ROOT}/repair-deploy"
REPAIR_COMMAND="${TEST_ROOT}/repair-bin/crispai"
REPAIR_CAPTURE="${TEST_ROOT}/repair.capture"
REPAIR_LOG="${TEST_ROOT}/repair.typescript"
mkdir -p -- "$REPAIR_DEPLOY" "$(dirname -- "$REPAIR_COMMAND")"
cp -a -- "${BUILD_ROOT}/ai-support-v1.1.1/." "$REPAIR_DEPLOY/"
printf 'ai-support\nstate=local-ready\ninstalled_version=v1.1.1\n' > "$REPAIR_DEPLOY/.crisp-ai-installation"
printf '%s\n' "$REPAIR_COMMAND" > "$REPAIR_DEPLOY/config/.crispai-launcher"
printf 'AI_API_KEY=synthetic-repair-secret\n' > "$REPAIR_DEPLOY/.env"
printf '{"enabled":false}\n' > "$REPAIR_DEPLOY/config/runtime.yaml"
mkdir -p -- "$REPAIR_DEPLOY/data/runtime"
printf '{"mode":"human","resume_at":null}\n' > "$REPAIR_DEPLOY/data/runtime/session-fixture.json"
: > "$REPAIR_CAPTURE"
run_tty "$CALLER_DIR" "$REPAIR_LOG" "$REPAIR_CAPTURE" --repair --deploy-dir "$REPAIR_DEPLOY"
[[ -x "$REPAIR_COMMAND" && -x "$(dirname -- "$REPAIR_COMMAND")/crisp" ]] \
  || fail '--repair 没有从校验包恢复正式与兼容命令'
[[ ! -s "$REPAIR_CAPTURE" ]] || fail '--repair 意外运行了安装器、更新器或菜单'
[[ "$(<"$REPAIR_DEPLOY/.env")" == 'AI_API_KEY=synthetic-repair-secret' \
  && "$(<"$REPAIR_DEPLOY/config/runtime.yaml")" == '{"enabled":false}' \
  && "$(<"$REPAIR_DEPLOY/data/runtime/session-fixture.json")" == '{"mode":"human","resume_at":null}' ]] \
  || fail '--repair 改动了凭据、总开关或人工状态'
[[ ! -e "$REPAIR_DEPLOY/config/.online-release" ]] || fail '--repair 改写了部署包来源'
pass '--repair 绕过已有菜单并用校验同版包仅恢复受管命令，保留业务和人工状态'

REQUESTS_BEFORE=$(wc -l < "$ACCESS_LOG")
set +e
run_tty "$CALLER_DIR" "${TEST_ROOT}/repair-cross-version.typescript" "$REPAIR_CAPTURE" \
  --repair --release v1.1.2 --deploy-dir "$REPAIR_DEPLOY"
REPAIR_CROSS_STATUS=$?
run_tty "$CALLER_DIR" "${TEST_ROOT}/repair-update.typescript" "$REPAIR_CAPTURE" \
  --repair --update --deploy-dir "$REPAIR_DEPLOY"
REPAIR_UPDATE_STATUS=$?
set -e
[[ "$REPAIR_CROSS_STATUS" != 0 && "$REPAIR_UPDATE_STATUS" == 64 \
  && "$(wc -l < "$ACCESS_LOG")" == "$REQUESTS_BEFORE" ]] \
  || fail '--repair 没有在网络访问前拒绝跨版本或与 --update 混用'
pass '--repair 拒绝跨版本与 --update 混用，不进入下载或变更'

mv -- "$REPAIR_DEPLOY/n8n/runtime.js" "$REPAIR_DEPLOY/n8n/runtime.saved"
rm -f -- "$REPAIR_COMMAND"
set +e
run_tty "$CALLER_DIR" "${TEST_ROOT}/repair-missing-module.typescript" "$REPAIR_CAPTURE" \
  --repair --deploy-dir "$REPAIR_DEPLOY"
REPAIR_MISSING_STATUS=$?
set -e
[[ "$REPAIR_MISSING_STATUS" != 0 && ! -e "$REPAIR_COMMAND" && ! -s "$REPAIR_CAPTURE" ]] \
  || fail '--repair 在业务程序缺失时伪装为入口修复成功'
assert_contains "${TEST_ROOT}/repair-missing-module.typescript" 'n8n/runtime.js' '缺少程序模块时没有给出精确相对路径'
mv -- "$REPAIR_DEPLOY/n8n/runtime.saved" "$REPAIR_DEPLOY/n8n/runtime.js"
printf '#!/usr/bin/env bash\nprintf "foreign\\n"\n' > "$REPAIR_COMMAND"
chmod 0755 "$REPAIR_COMMAND"
set +e
run_tty "$CALLER_DIR" "${TEST_ROOT}/repair-foreign-command.typescript" "$REPAIR_CAPTURE" \
  --repair --deploy-dir "$REPAIR_DEPLOY"
REPAIR_FOREIGN_STATUS=$?
set -e
[[ "$REPAIR_FOREIGN_STATUS" != 0 ]] || fail '--repair 覆盖了不属于本实例的同名命令'
assert_contains "$REPAIR_COMMAND" foreign '--repair 损坏了外来命令'
pass '--repair 对缺失程序和外来同名命令保守失败，不覆盖其他内容'

OLD_DEPLOY="${TEST_ROOT}/old-deploy"
mkdir -p -- "$OLD_DEPLOY/config"
printf 'ai-support\nstate=local-ready\ninstalled_version=v1.1.0\n' \
  > "${OLD_DEPLOY}/.crisp-ai-installation"
printf 'v1.1.0\n' > "${OLD_DEPLOY}/VERSION"
cp -- "${BUILD_ROOT}/ai-support-v1.1.1/manage.sh" "${OLD_DEPLOY}/manage.sh"
chmod 0755 "${OLD_DEPLOY}/manage.sh"
UPDATE_LOG="${TEST_ROOT}/update.typescript"
run_tty "$CALLER_DIR" "$UPDATE_LOG" "$CAPTURE" \
  --update --release v1.1.1 --deploy-dir "$OLD_DEPLOY"
assert_contains "$CAPTURE" 'action=update' '--update 没有调用正式包内更新入口'
[[ "$(<"${OLD_DEPLOY}/VERSION")" == v1.1.1 ]] || fail '在线更新没有应用指定版本'
pass '旧实例仅在显式 --update 时使用同一校验包升级'

[[ ! -e "${BUILD_ROOT}/ai-support-v1.1.0/get.sh" \
  && ! -e "${BUILD_ROOT}/ai-support-v1.1.0/scripts/doctor.sh" ]] \
  || fail 'v1.1.0 兼容契约包错误包含 v1.1.1 新模块'
for legacy_state in collecting uninstalled-data-kept; do
  LEGACY_DEPLOY="${TEST_ROOT}/legacy-${legacy_state}"
  LEGACY_CAPTURE="${TEST_ROOT}/legacy-${legacy_state}.capture"
  LEGACY_LOG="${TEST_ROOT}/legacy-${legacy_state}.typescript"
  mkdir -p -- "$LEGACY_DEPLOY/config"
  printf 'ai-support\nstate=%s\ninstalled_version=v1.1.0\n' "$legacy_state" \
    > "${LEGACY_DEPLOY}/.crisp-ai-installation"
  : > "$LEGACY_CAPTURE"
  run_tty "$CALLER_DIR" "$LEGACY_LOG" "$LEGACY_CAPTURE" \
    --deploy-dir "$LEGACY_DEPLOY"
  assert_contains "$LEGACY_CAPTURE" 'action=install' \
    "${legacy_state} 没有从原版本包继续安装"
  [[ "$(<"${LEGACY_DEPLOY}/VERSION")" == v1.1.0 ]] \
    || fail "${legacy_state} 错误混入其他版本"
  assert_contains "$LEGACY_LOG" '已锁定正式版本 v1.1.0' \
    "${legacy_state} 没有锁定原安装版本"
done
pass 'v1.1.0 未完成/保留资料实例按旧包能力恢复，不要求新版 get/doctor 且不混代'

V120_CAPTURE="${TEST_ROOT}/v120.capture"
: > "$V120_CAPTURE"
run_tty "$CALLER_DIR" "${TEST_ROOT}/v120.typescript" "$V120_CAPTURE" \
  --release v1.2.0 --deploy-dir "${TEST_ROOT}/v120-deploy"
assert_contains "$V120_CAPTURE" 'action=install' 'v1.2.0 完整包没有进入正式安装器'
pass 'v1.2.0 完整包满足新增资料与日志模块能力，同时保持旧版本包兼容'

for entry_index in "${!V120_REQUIRED[@]}"; do
  missing_release="v1.2.$((entry_index + 1))"
  MISSING_CAPTURE="${TEST_ROOT}/missing-${missing_release}.capture"
  MISSING_DEPLOY="${TEST_ROOT}/missing-${missing_release}.deploy"
  MISSING_LOG="${TEST_ROOT}/missing-${missing_release}.typescript"
  : > "$MISSING_CAPTURE"
  set +e
  run_tty "$CALLER_DIR" "$MISSING_LOG" "$MISSING_CAPTURE" \
    --release "$missing_release" --deploy-dir "$MISSING_DEPLOY"
  MISSING_STATUS=$?
  set -e
  [[ "$MISSING_STATUS" != 0 && ! -s "$MISSING_CAPTURE" && ! -e "$MISSING_DEPLOY" ]] \
    || fail "${missing_release} 缺少新增生产模块时仍执行了安装器"
  assert_contains "$MISSING_LOG" "归档缺少生产文件：${V120_REQUIRED[entry_index]}" \
    'v1.2.0 缺少生产模块时没有在执行前明确拒绝'
done
pass 'v1.2.0 四个新增模块逐项缺失即使 SHA 正确也在执行包内程序前拒绝'

LATEST_DEPLOY="${TEST_ROOT}/latest-deploy"
LATEST_CAPTURE="${TEST_ROOT}/latest-capture.log"
LATEST_LOG="${TEST_ROOT}/latest.typescript"
: > "$LATEST_CAPTURE"
run_tty "$CALLER_DIR" "$LATEST_LOG" "$LATEST_CAPTURE" --deploy-dir "$LATEST_DEPLOY"
assert_contains "$LATEST_LOG" '已锁定正式版本 v1.1.1' 'Latest 重定向没有锁定为具体 tag'
assert_contains "$LATEST_CAPTURE" 'action=install' 'Latest 路径没有调用安装器'
pass 'Latest 先解析一次具体 tag，再下载同版本包与清单'

PRERELEASE_LOG="${TEST_ROOT}/prerelease.typescript"
PRERELEASE_CAPTURE="${TEST_ROOT}/prerelease.capture"
: > "$PRERELEASE_CAPTURE"
set +e
run_tty "$CALLER_DIR" "$PRERELEASE_LOG" "$PRERELEASE_CAPTURE" \
  --release v1.1.13 --deploy-dir "${TEST_ROOT}/prerelease-deploy"
PRERELEASE_STATUS=$?
set -e
[[ "$PRERELEASE_STATUS" != 0 && ! -s "$PRERELEASE_CAPTURE" \
  && ! -e "${TEST_ROOT}/prerelease-deploy" ]] \
  || fail 'GitHub 标记为 prerelease 的纯 semver tag 被执行'
assert_contains "$PRERELEASE_LOG" '目标是 prerelease' 'prerelease 拒绝原因不清楚'
pass '显式 --release 同样核对非 draft、非 prerelease 的正式元数据'

for release in v1.1.4 v1.1.5 v1.1.6 v1.1.7 v1.1.8; do
  FAILURE_LOG="${TEST_ROOT}/failure-${release}.typescript"
  FAILURE_CAPTURE="${TEST_ROOT}/failure-${release}.capture"
  FAILURE_DEPLOY="${TEST_ROOT}/failure-${release}.deploy"
  : > "$FAILURE_CAPTURE"
  set +e
  run_tty "$CALLER_DIR" "$FAILURE_LOG" "$FAILURE_CAPTURE" \
    --release "$release" --deploy-dir "$FAILURE_DEPLOY"
  FAILURE_STATUS=$?
  set -e
  [[ "$FAILURE_STATUS" != 0 && ! -s "$FAILURE_CAPTURE" && ! -e "$FAILURE_DEPLOY" ]] \
    || fail "${release} 坏包被执行或写入部署目录"
done
assert_contains "${TEST_ROOT}/failure-v1.1.4.typescript" '安全检查失败' '路径穿越归档拒绝原因不清楚'
assert_contains "${TEST_ROOT}/failure-v1.1.5.typescript" 'SHA-256 不匹配' '校验不符拒绝原因不清楚'
assert_contains "${TEST_ROOT}/failure-v1.1.6.typescript" '非目标文件或不安全路径' '额外 checksum 目标未被严格拒绝'
assert_contains "${TEST_ROOT}/failure-v1.1.7.typescript" '安全检查失败' 'HTTP 200 HTML 未在执行前拒绝'
assert_contains "${TEST_ROOT}/failure-v1.1.8.typescript" '归档缺少生产文件：scripts/menu-ui.sh' \
  '有效 SHA 的正式包缺少次级生产模块时没有在执行前拒绝'
[[ ! -e "${TEST_ROOT}/escape-target" ]] || fail '路径穿越归档写出了临时目录外文件'
pass 'checksum 不符、冲突目标、HTML、路径穿越和缺失生产模块均在执行包内代码前拒绝'

for release in v1.1.9 v1.1.14 v1.1.15; do
  METADATA_LOG="${TEST_ROOT}/metadata-${release}.typescript"
  METADATA_CAPTURE="${TEST_ROOT}/metadata-${release}.capture"
  METADATA_DEPLOY="${TEST_ROOT}/metadata-${release}.deploy"
  : > "$METADATA_CAPTURE"
  set +e
  run_tty "$CALLER_DIR" "$METADATA_LOG" "$METADATA_CAPTURE" \
    --release "$release" --deploy-dir "$METADATA_DEPLOY"
  METADATA_STATUS=$?
  set -e
  [[ "$METADATA_STATUS" != 0 && ! -s "$METADATA_CAPTURE" && ! -e "$METADATA_DEPLOY" ]] \
    || fail "${release} 的无效资产元数据被错误接受"
  if grep -Fq "/releases/download/${release}/" "$ACCESS_LOG"; then
    fail "${release} 元数据无效后仍下载了 Release 资产"
  fi
done
assert_contains "${TEST_ROOT}/metadata-v1.1.9.typescript" 'size 超出允许范围' \
  '超大压缩资产没有在下载前拒绝'
assert_contains "${TEST_ROOT}/metadata-v1.1.14.typescript" 'size 不是整数' \
  '非整数资产 size 没有被拒绝'
assert_contains "${TEST_ROOT}/metadata-v1.1.15.typescript" '尚未完成上传' \
  '未完成上传的资产被错误接受'
pass 'Release 资产上传状态、整数 size 与压缩包上限均在下载前验证'

DISK_LOG="${TEST_ROOT}/insufficient-disk.typescript"
DISK_CAPTURE="${TEST_ROOT}/insufficient-disk.capture"
DISK_DEPLOY="${TEST_ROOT}/insufficient-disk.deploy"
: > "$DISK_CAPTURE"
export CRISPAI_GET_TEST_AVAILABLE_BYTES=1
set +e
run_tty "$CALLER_DIR" "$DISK_LOG" "$DISK_CAPTURE" \
  --release v1.1.11 --deploy-dir "$DISK_DEPLOY"
DISK_STATUS=$?
set -e
unset CRISPAI_GET_TEST_AVAILABLE_BYTES
[[ "$DISK_STATUS" != 0 && ! -s "$DISK_CAPTURE" && ! -e "$DISK_DEPLOY" ]] \
  || fail '临时目录空间不足时仍执行了正式包'
assert_contains "$DISK_LOG" '临时目录空间不足' '下载前空间预检没有给出明确原因'
if grep -Fq '/releases/download/v1.1.11/' "$ACCESS_LOG"; then
  fail '临时目录空间预检失败后仍下载了 Release 资产'
fi
pass '可信资产大小用于下载前临时盘空间预检，空间不足不取包'

for release in v1.1.10 v1.1.12; do
  SIZE_LOG="${TEST_ROOT}/size-${release}.typescript"
  SIZE_CAPTURE="${TEST_ROOT}/size-${release}.capture"
  SIZE_DEPLOY="${TEST_ROOT}/size-${release}.deploy"
  : > "$SIZE_CAPTURE"
  set +e
  run_tty "$CALLER_DIR" "$SIZE_LOG" "$SIZE_CAPTURE" \
    --release "$release" --deploy-dir "$SIZE_DEPLOY"
  SIZE_STATUS=$?
  set -e
  [[ "$SIZE_STATUS" != 0 && ! -s "$SIZE_CAPTURE" && ! -e "$SIZE_DEPLOY" ]] \
    || fail "${release} 元数据与实际响应大小不符时仍执行了正式包"
done
assert_contains "${TEST_ROOT}/size-v1.1.10.typescript" '实际大小与 Release 元数据不一致' \
  '短响应没有进行实际字节对账'
assert_contains "${TEST_ROOT}/size-v1.1.12.typescript" '下载内容超过允许大小' \
  '超出元数据 size 的响应没有被硬传输上限中止'
pass '资产下载独立硬限界，并逐字节对账 Release 元数据 size'

NON_PROJECT="${TEST_ROOT}/not-project"
mkdir -p -- "$NON_PROJECT"
printf '保留\n' > "${NON_PROJECT}/user-file"
NON_PROJECT_LOG="${TEST_ROOT}/not-project.typescript"
REQUESTS_BEFORE=$(wc -l < "$ACCESS_LOG")
set +e
run_tty "$CALLER_DIR" "$NON_PROJECT_LOG" "$CAPTURE" --deploy-dir "$NON_PROJECT"
NON_PROJECT_STATUS=$?
set -e
REQUESTS_AFTER=$(wc -l < "$ACCESS_LOG")
[[ "$NON_PROJECT_STATUS" != 0 && "$REQUESTS_AFTER" == "$REQUESTS_BEFORE" \
  && "$(<"${NON_PROJECT}/user-file")" == 保留 ]] \
  || fail '非项目目录拒绝不及时或修改了用户文件'
pass '非空非项目目录在下载前拒绝且不修改原内容'

printf '在线安装入口专项测试：%d 通过，0 失败\n' "$PASSED"
