#!/usr/bin/env bash
set -euo pipefail

# CrispAI 公共发行包引导器。此文件必须能够脱离 Git 仓库和其他相邻文件独立运行。
GET_VERSION="v1.1.1"
REPOSITORY="statusX7/ai-support"
REPOSITORY_URL="https://github.com/${REPOSITORY}"
LATEST_URL="${REPOSITORY_URL}/releases/latest"
RELEASE_DOWNLOAD_ROOT="${REPOSITORY_URL}/releases/download"
RELEASE_API_ROOT="https://api.github.com/repos/${REPOSITORY}/releases/tags"
DEFAULT_DEPLOY_DIR="/opt/crisp-ai"
ARCHIVE_MAX_BYTES=$((4 * 1024 * 1024 * 1024))
ARCHIVE_DOWNLOAD_MAX_BYTES=$((512 * 1024 * 1024))
CHECKSUM_DOWNLOAD_MAX_BYTES=$((64 * 1024))
RELEASE_METADATA_MAX_BYTES=$((1024 * 1024))
DOWNLOAD_SPACE_RESERVE_BYTES=$((64 * 1024 * 1024))
DOWNLOAD_CONNECT_TIMEOUT=15
DOWNLOAD_TOTAL_TIMEOUT=300
DOWNLOAD_RETRIES=3
DOWNLOAD_RETRY_DELAY=2

RELEASE_REQUEST=""
DEPLOY_REQUEST=""
UPDATE_REQUEST=0
INTERNAL_CALLER_DIR=""
WORK_DIR=""
SELECTED_RELEASE=""
ARCHIVE_SHA256=""
ARCHIVE_EXPECTED_BYTES=""
CHECKSUM_EXPECTED_BYTES=""

info() {
  printf '信息：%s\n' "$*"
}

warn() {
  printf '警告：%s\n' "$*" >&2
}

die() {
  local message=$1 status=${2:-1}
  printf '错误：%s\n' "$message" >&2
  exit "$status"
}

usage() {
  cat <<'EOF'
用法：get.sh [选项]

从公开 GitHub Release 下载并校验完整正式包，然后调用包内生产安装器。

选项：
  --release VERSION  安装指定正式版本，例如 v1.1.1
  --deploy-dir PATH  指定部署目录，默认 /opt/crisp-ai
  --update           更新一个已完成的旧版本实例
  --help             显示帮助，不安装依赖或访问网络
  --version          显示引导器版本，不安装依赖或访问网络

无参数运行时：新实例安装当前 Latest 正式版；已有完整实例打开 crispai 管理菜单；
未完成的安装会下载原版本正式包并继续。回滚仍在 crispai 的更新与回滚菜单中执行。
EOF
}

cleanup() {
  local status=$?
  trap - EXIT INT TERM
  if [[ -n "$WORK_DIR" && "$WORK_DIR" == /tmp/crispai-get.* \
    && -d "$WORK_DIR" && ! -L "$WORK_DIR" ]]; then
    rm -rf -- "$WORK_DIR"
  fi
  exit "$status"
}

handle_interrupt() {
  trap - INT TERM
  printf '\n警告：在线引导已中断；部署目录内已经保存的初始化进度不会被删除。\n' >&2
  exit 130
}

valid_release() {
  [[ "$1" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]
}

version_compare() {
  local left=$1 right=$2
  local left_major left_minor left_patch right_major right_minor right_patch
  IFS=. read -r left_major left_minor left_patch <<< "${left#v}"
  IFS=. read -r right_major right_minor right_patch <<< "${right#v}"
  if (( 10#$left_major < 10#$right_major )); then printf '%s\n' -1; return; fi
  if (( 10#$left_major > 10#$right_major )); then printf '%s\n' 1; return; fi
  if (( 10#$left_minor < 10#$right_minor )); then printf '%s\n' -1; return; fi
  if (( 10#$left_minor > 10#$right_minor )); then printf '%s\n' 1; return; fi
  if (( 10#$left_patch < 10#$right_patch )); then printf '%s\n' -1; return; fi
  if (( 10#$left_patch > 10#$right_patch )); then printf '%s\n' 1; return; fi
  printf '%s\n' 0
}

read_os_value() {
  local wanted=$1 line key value
  [[ -r /etc/os-release ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == *=* ]] || continue
    key=${line%%=*}
    [[ "$key" == "$wanted" ]] || continue
    value=${line#*=}
    if [[ ${#value} -ge 2 && "$value" == \"*\" && "$value" == *\" ]]; then
      value=${value:1:${#value}-2}
    elif [[ ${#value} -ge 2 && "$value" == \'*\' && "$value" == *\' ]]; then
      value=${value:1:${#value}-2}
    fi
    printf '%s\n' "$value"
    return 0
  done < /etc/os-release
  return 1
}

detect_supported_platform() {
  local id version architecture
  id=$(read_os_value ID 2>/dev/null || true)
  version=$(read_os_value VERSION_ID 2>/dev/null || true)
  architecture=$(uname -m 2>/dev/null || true)
  case "${id}:${version}" in
    debian:12|debian:13|ubuntu:22.04|ubuntu:24.04) ;;
    *) die "不支持的系统：${id:-未知} ${version:-未知}；当前支持 Debian 12/13、Ubuntu 22.04/24.04" ;;
  esac
  case "$architecture" in
    x86_64|amd64|aarch64|arm64) ;;
    *) die "当前 CPU 架构尚不支持：${architecture:-未知}" ;;
  esac
}

prepare_download_tools() {
  local need_install=0 command_name
  local -a required=(curl python3 tar gzip sha256sum realpath mktemp chmod mkdir mv rm date)
  local -a elevate=()

  detect_supported_platform
  [[ -s /etc/ssl/certs/ca-certificates.crt ]] || need_install=1
  for command_name in "${required[@]}"; do
    command -v "$command_name" >/dev/null 2>&1 || need_install=1
  done
  (( need_install == 1 )) || return 0

  command -v apt-get >/dev/null 2>&1 \
    || die '缺少安全下载/校验工具，且系统没有 apt-get，无法自动补齐'
  if (( EUID != 0 )); then
    command -v sudo >/dev/null 2>&1 \
      || die '补齐在线安装工具需要 root 或 sudo 权限'
    elevate=(sudo --)
  fi
  info '正在自动补齐安全下载、校验和解压所需的最小工具'
  "${elevate[@]}" env DEBIAN_FRONTEND=noninteractive apt-get -q \
    -o APT::Color=0 -o Dpkg::Use-Pty=0 -o DPkg::Lock::Timeout=180 \
    -o Acquire::Retries=3 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 \
    update
  "${elevate[@]}" env DEBIAN_FRONTEND=noninteractive apt-get -q \
    -o APT::Color=0 -o Dpkg::Use-Pty=0 -o DPkg::Lock::Timeout=180 \
    -o Acquire::Retries=3 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 \
    install --yes --no-install-recommends ca-certificates curl python3 tar gzip coreutils

  [[ -s /etc/ssl/certs/ca-certificates.crt ]] || die 'CA 证书包安装后仍不可用'
  for command_name in "${required[@]}"; do
    command -v "$command_name" >/dev/null 2>&1 \
      || die "工具安装后仍缺少命令：${command_name}"
  done
}

require_root() {
  local self_path=$1 caller_dir=$2 self_mode
  shift 2
  (( EUID == 0 )) && return 0
  [[ -f "$self_path" && ! -L "$self_path" && -O "$self_path" ]] \
    || die '提权前的 get.sh 必须是当前用户拥有的安全普通文件'
  if command -v stat >/dev/null 2>&1; then
    self_mode=$(stat -c '%a' "$self_path" 2>/dev/null || true)
    [[ "$self_mode" =~ ^[0-7]{3,4}$ ]] \
      || die '无法核对提权前 get.sh 的文件权限'
    (( (8#$self_mode & 8#022) == 0 )) \
      || die '提权前的 get.sh 不得允许 group/other 写入'
  fi
  command -v sudo >/dev/null 2>&1 \
    || die '安装或更新需要 root 权限；当前账号也没有可用的 sudo'
  info '安装需要管理员权限，正在调用 sudo'
  exec sudo -- bash "$self_path" --_caller-dir "$caller_dir" "$@"
}

require_interactive_terminal() {
  [[ -t 0 && -t 1 && -r /dev/tty && -w /dev/tty ]] \
    || die '在线安装需要交互终端。请在 SSH/本机终端原样执行文档中的一行命令，不要使用 curl | bash' 1
}

configure_test_endpoints() {
  [[ "${CRISPAI_GET_TEST_MODE:-0}" == 1 ]] || return 0
  local latest=${CRISPAI_GET_TEST_LATEST_URL:-}
  local root=${CRISPAI_GET_TEST_RELEASE_ROOT:-}
  local api_root=${CRISPAI_GET_TEST_RELEASE_API_ROOT:-}
  [[ "$latest" =~ ^http://(127\.0\.0\.1|localhost):[0-9]+/ \
    && "$root" =~ ^http://(127\.0\.0\.1|localhost):[0-9]+/ \
    && "$api_root" =~ ^http://(127\.0\.0\.1|localhost):[0-9]+/ ]] \
    || die '测试下载端点必须是本机回环 HTTP 地址'
  LATEST_URL=$latest
  RELEASE_DOWNLOAD_ROOT=${root%/}
  RELEASE_API_ROOT=${api_root%/}
  DOWNLOAD_CONNECT_TIMEOUT=${CRISPAI_GET_TEST_CONNECT_TIMEOUT:-$DOWNLOAD_CONNECT_TIMEOUT}
  DOWNLOAD_TOTAL_TIMEOUT=${CRISPAI_GET_TEST_TOTAL_TIMEOUT:-$DOWNLOAD_TOTAL_TIMEOUT}
  DOWNLOAD_RETRIES=${CRISPAI_GET_TEST_RETRIES:-$DOWNLOAD_RETRIES}
  DOWNLOAD_RETRY_DELAY=${CRISPAI_GET_TEST_RETRY_DELAY:-$DOWNLOAD_RETRY_DELAY}
  [[ "$DOWNLOAD_CONNECT_TIMEOUT" =~ ^[1-9][0-9]*$ \
    && "$DOWNLOAD_TOTAL_TIMEOUT" =~ ^[1-9][0-9]*$ \
    && "$DOWNLOAD_RETRIES" =~ ^[0-9]+$ \
    && "$DOWNLOAD_RETRY_DELAY" =~ ^[0-9]+$ ]] \
    || die '测试下载超时或重试参数无效'
}

curl_protocols() {
  if [[ "$1" == https://* ]]; then
    printf '%s\n' '=https'
  elif [[ "${CRISPAI_GET_TEST_MODE:-0}" == 1 && "$1" =~ ^http://(127\.0\.0\.1|localhost): ]]; then
    printf '%s\n' '=http,https'
  else
    return 1
  fi
}

bounded_stream_to_file() {
  local destination=$1 max_bytes=$2
  python3 -c '
import os
import sys

destination, maximum_text = sys.argv[1:]
try:
    maximum = int(maximum_text)
    if maximum <= 0:
        raise ValueError("下载大小上限无效")
    written = 0
    with open(destination, "wb", buffering=0) as output:
        while True:
            remaining = maximum - written
            chunk = sys.stdin.buffer.read(min(1024 * 1024, remaining + 1))
            if not chunk:
                break
            if len(chunk) > remaining:
                raise ValueError("下载内容超过允许大小")
            output.write(chunk)
            written += len(chunk)
except (OSError, ValueError) as error:
    try:
        os.remove(destination)
    except OSError:
        pass
    print("错误：" + str(error), file=sys.stderr)
    sys.exit(1)
' "$destination" "$max_bytes"
}

download_file() {
  local url=$1 destination=$2 max_bytes=$3 expected_bytes=$4 label=$5
  local protocols partial status actual_bytes
  protocols=$(curl_protocols "$url") || die '拒绝不安全的下载地址'
  [[ "$max_bytes" =~ ^[1-9][0-9]*$ && "$expected_bytes" =~ ^[1-9][0-9]*$ ]] \
    || die "${label} 的下载大小约束无效"
  (( 10#$expected_bytes <= 10#$max_bytes )) || die "${label} 的下载大小约束无效"
  partial="${destination}.part"
  rm -f -- "$partial"
  : > "$partial"
  chmod 0600 "$partial"
  if curl -q --fail --location --silent --show-error \
    --max-redirs 5 --proto "$protocols" --proto-redir "$protocols" --tlsv1.2 \
    --retry "$DOWNLOAD_RETRIES" --retry-delay "$DOWNLOAD_RETRY_DELAY" \
    --connect-timeout "$DOWNLOAD_CONNECT_TIMEOUT" \
    --max-time "$DOWNLOAD_TOTAL_TIMEOUT" "$url" \
      | bounded_stream_to_file "$partial" "$expected_bytes"; then
    :
  else
    status=$?
    rm -f -- "$partial"
    die "${label} 下载失败（受限传输退出码 ${status}）：${url}"
  fi
  [[ -s "$partial" ]] || { rm -f -- "$partial"; die "下载结果为空：${url}"; }
  actual_bytes=$(stat -c '%s' "$partial" 2>/dev/null || true)
  [[ "$actual_bytes" == "$expected_bytes" ]] || {
    rm -f -- "$partial"
    die "${label} 实际大小与 Release 元数据不一致（期望 ${expected_bytes} 字节，实际 ${actual_bytes:-未知} 字节）"
  }
  mv -f -- "$partial" "$destination"
}

download_release_metadata() {
  local url=$1 destination=$2 protocols partial status
  protocols=$(curl_protocols "$url") || die '拒绝不安全的 Release API 地址'
  partial="${destination}.part"
  rm -f -- "$partial"
  : > "$partial"
  chmod 0600 "$partial"
  if curl -q --fail --location --silent --show-error \
    --max-redirs 5 --proto "$protocols" --proto-redir "$protocols" --tlsv1.2 \
    --retry "$DOWNLOAD_RETRIES" --retry-delay "$DOWNLOAD_RETRY_DELAY" \
    --connect-timeout "$DOWNLOAD_CONNECT_TIMEOUT" --max-time "$DOWNLOAD_TOTAL_TIMEOUT" \
    --header 'Accept: application/vnd.github+json' \
    --header 'X-GitHub-Api-Version: 2022-11-28' \
    --user-agent "CrispAI-get/${GET_VERSION}" "$url" \
      | bounded_stream_to_file "$partial" "$RELEASE_METADATA_MAX_BYTES"; then
    :
  else
    status=$?
    rm -f -- "$partial"
    die "无法读取正式 Release 元数据（curl 退出码 ${status}）：${url}"
  fi
  [[ -s "$partial" ]] || { rm -f -- "$partial"; die 'Release 元数据为空'; }
  mv -f -- "$partial" "$destination"
}

verify_release_metadata() {
  local release=$1 archive_name=$2 metadata_file=$3
  local metadata_url="${RELEASE_API_ROOT}/${release}" asset_sizes
  download_release_metadata "$metadata_url" "$metadata_file"
  if ! asset_sizes=$(python3 - "$metadata_file" "$release" "$archive_name" \
      "$ARCHIVE_DOWNLOAD_MAX_BYTES" "$CHECKSUM_DOWNLOAD_MAX_BYTES" <<'PY'
import json
import sys

path, expected_tag, archive_name, archive_max_text, checksum_max_text = sys.argv[1:]
try:
    archive_max = int(archive_max_text)
    checksum_max = int(checksum_max_text)
    with open(path, "r", encoding="utf-8") as source:
        release = json.load(source)
    if release.get("tag_name") != expected_tag:
        raise ValueError("tag 与请求不一致")
    if release.get("draft") is not False:
        raise ValueError("目标仍是 draft")
    if release.get("prerelease") is not False:
        raise ValueError("目标是 prerelease")
    if not release.get("published_at"):
        raise ValueError("目标尚未正式发布")
    assets = release.get("assets")
    if not isinstance(assets, list):
        raise ValueError("资产列表格式无效")
    def asset_size(name, maximum):
        matches = [item for item in assets
                   if isinstance(item, dict) and item.get("name") == name]
        if len(matches) != 1:
            raise ValueError("完整包或 SHA256SUMS 尚未唯一就绪")
        item = matches[0]
        if item.get("state") != "uploaded":
            raise ValueError(name + " 尚未完成上传")
        size = item.get("size")
        if isinstance(size, bool) or not isinstance(size, int):
            raise ValueError(name + " 的 size 不是整数")
        if size <= 0 or size > maximum:
            raise ValueError(name + " 的 size 超出允许范围")
        return size
    archive_size = asset_size(archive_name, archive_max)
    checksum_size = asset_size("SHA256SUMS", checksum_max)
    print(str(archive_size) + "\t" + str(checksum_size))
except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as error:
    print("错误：正式 Release 元数据校验失败：" + str(error), file=sys.stderr)
    sys.exit(1)
PY
  ); then
    return 1
  fi
  IFS=$'\t' read -r ARCHIVE_EXPECTED_BYTES CHECKSUM_EXPECTED_BYTES <<< "$asset_sizes"
  [[ "$ARCHIVE_EXPECTED_BYTES" =~ ^[1-9][0-9]*$ \
    && "$CHECKSUM_EXPECTED_BYTES" =~ ^[1-9][0-9]*$ ]] \
    || die '正式 Release 元数据没有返回有效资产大小'
}

check_download_capacity() {
  local directory=$1 archive_bytes=$2 checksum_bytes=$3
  local available_override=""
  if [[ "${CRISPAI_GET_TEST_MODE:-0}" == 1 ]]; then
    available_override=${CRISPAI_GET_TEST_AVAILABLE_BYTES:-}
    [[ -z "$available_override" || "$available_override" =~ ^[0-9]+$ ]] \
      || die '测试可用空间覆盖值无效'
  fi
  python3 - "$directory" "$archive_bytes" "$checksum_bytes" \
    "$DOWNLOAD_SPACE_RESERVE_BYTES" "$available_override" <<'PY'
import os
import sys

directory, archive_text, checksum_text, reserve_text, override_text = sys.argv[1:]
try:
    archive = int(archive_text)
    checksum = int(checksum_text)
    reserve = int(reserve_text)
    if archive <= 0 or checksum <= 0 or reserve < 0:
        raise ValueError("空间预检参数无效")
    available = int(override_text) if override_text else os.statvfs(directory).f_bavail * os.statvfs(directory).f_frsize
    required = archive + checksum + reserve
    if available < required:
        raise ValueError(
            "临时目录空间不足：可用 %d 字节，下载及安全余量至少需要 %d 字节"
            % (available, required)
        )
except (OSError, ValueError) as error:
    print("错误：" + str(error), file=sys.stderr)
    sys.exit(1)
PY
}

required_package_entries() {
  local release=$1 capability
  cat <<'EOF'
VERSION
install.sh
manage.sh
update.sh
uninstall.sh
docker-compose.yml
scripts/bootstrap.sh
scripts/common.sh
scripts/wizard.sh
scripts/launcher.sh
scripts/healthcheck.sh
scripts/configuration.sh
scripts/knowledge.sh
scripts/provider.sh
scripts/provider-adapter.js
n8n/workflow.json
n8n/runtime.js
config/app.yaml
config/provider.yaml.example
EOF
  capability=$(version_compare "$release" v1.1.1)
  (( capability >= 0 )) || return 0
  cat <<'EOF'
.env.example
get.sh
config/Caddyfile.example
config/feedback.yaml.example
config/handoff.yaml.example
config/keyword.yaml.example
config/menu.yaml.example
config/prompt.md.example
config/runtime.yaml.example
config/tags.yaml.example
knowledge/README.md
n8n/runtime-cli.js
n8n/build-workflow.js
n8n/web-chat.js
scripts/analytics.sh
scripts/backup.sh
scripts/doctor.sh
scripts/package-release.sh
scripts/restore.sh
scripts/rollback.sh
scripts/snapshot.sh
scripts/menu-ui.sh
scripts/migration.sh
scripts/crisp-settings.sh
scripts/full-backup.sh
scripts/archive-guard.py
EOF
}

resolve_latest_release() {
  local protocols effective status prefix
  protocols=$(curl_protocols "$LATEST_URL") || die 'Latest 地址不是受信任的 HTTPS 地址'
  if effective=$(curl -q --fail --location --silent --show-error \
      --max-redirs 5 --proto "$protocols" --proto-redir "$protocols" --tlsv1.2 \
      --retry "$DOWNLOAD_RETRIES" --retry-delay "$DOWNLOAD_RETRY_DELAY" \
      --connect-timeout "$DOWNLOAD_CONNECT_TIMEOUT" \
      --max-time "$DOWNLOAD_TOTAL_TIMEOUT" --output /dev/null \
      --write-out '%{url_effective}' "$LATEST_URL"); then
    :
  else
    status=$?
    die "无法解析当前 Latest 正式版（curl 退出码 ${status}）"
  fi
  if [[ "${CRISPAI_GET_TEST_MODE:-0}" == 1 ]]; then
    prefix=${CRISPAI_GET_TEST_TAG_PREFIX:-}
    [[ -n "$prefix" ]] || die '测试模式缺少 tag URL 前缀'
  else
    prefix="${REPOSITORY_URL}/releases/tag/"
  fi
  [[ "$effective" == "$prefix"* ]] || die 'Latest 重定向没有落在本仓库的正式 Release 页面'
  SELECTED_RELEASE=${effective#"$prefix"}
  [[ "$SELECTED_RELEASE" != */* && "$SELECTED_RELEASE" != *\?* && "$SELECTED_RELEASE" != *\#* ]] \
    || die 'Latest Release tag 格式不安全'
  valid_release "$SELECTED_RELEASE" \
    || die "Latest 不是稳定语义版本：${SELECTED_RELEASE:-未知}"
}

verify_checksum_file() {
  local checksum_file=$1 archive_file=$2 archive_name=$3
  local line hash listed actual records=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] || die 'SHA256SUMS 含空记录，拒绝使用'
    [[ "$line" =~ ^([0-9a-fA-F]{64})[[:space:]][[:space:]]([^[:space:]]+)$ ]] \
      || die 'SHA256SUMS 格式无效'
    hash=${BASH_REMATCH[1],,}
    listed=${BASH_REMATCH[2]}
    [[ "$listed" == "$archive_name" ]] \
      || die "SHA256SUMS 含非目标文件或不安全路径：${listed}"
    ARCHIVE_SHA256=$hash
    (( records += 1 ))
  done < "$checksum_file"
  (( records == 1 )) || die 'SHA256SUMS 必须且只能含目标归档的一条记录'
  actual=$(sha256sum "$archive_file")
  actual=${actual%% *}
  [[ "$actual" == "$ARCHIVE_SHA256" ]] \
    || die '发布包 SHA-256 不匹配；不会执行或解压该文件'
}

validate_and_extract_archive() {
  local archive=$1 destination=$2 expected_root=$3 release=$4 required_file=$5
  python3 - "$archive" "$destination" "$expected_root" "$ARCHIVE_MAX_BYTES" "$release" \
    "$required_file" "$DOWNLOAD_SPACE_RESERVE_BYTES" <<'PY'
import os
import re
import shutil
import sys
import tarfile

archive_path, destination, expected_root, max_text, release, required_path, reserve_text = sys.argv[1:]
max_bytes = int(max_text)
reserve_bytes = int(reserve_text)
match = re.fullmatch(r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", release)
if match is None:
    print("错误：正式包安全检查失败：版本格式无效", file=sys.stderr)
    sys.exit(1)

try:
    with open(required_path, "r", encoding="utf-8") as source:
        required_lines = [line.rstrip("\n") for line in source]
    if (not required_lines or len(required_lines) != len(set(required_lines))
            or any(not line or line.startswith("/") or "\\" in line
                   or any(part in ("", ".", "..") for part in line.split("/"))
                   for line in required_lines)):
        raise ValueError("生产必需文件清单无效")
    required = set(required_lines)
    with tarfile.open(archive_path, "r:gz") as source:
        members = source.getmembers()
        if not members or len(members) > 10000:
            raise ValueError("归档为空或成员数量超过 10000")
        seen = set()
        regular = set()
        total = 0
        validated = []
        for member in members:
            raw = member.name
            name = raw[:-1] if raw.endswith("/") else raw
            if (not name or name.startswith("/") or "\\" in name
                    or len(name) > 4096 or any(ord(ch) < 32 for ch in name)):
                raise ValueError("归档包含不安全路径")
            parts = name.split("/")
            if any(part in ("", ".", "..") for part in parts):
                raise ValueError("归档包含路径穿越或非规范路径")
            if parts[0] != expected_root:
                raise ValueError("归档顶层目录与锁定版本不一致")
            if name in seen:
                raise ValueError("归档包含重复成员")
            seen.add(name)
            if not (member.isdir() or member.isfile()):
                raise ValueError("归档包含链接或特殊文件")
            if member.size < 0:
                raise ValueError("归档成员大小无效")
            total += member.size
            if total > max_bytes:
                raise ValueError("归档展开容量超过安全上限")
            relative = "/".join(parts[1:])
            if member.isfile():
                regular.add(relative)
            validated.append((member, parts))
        missing = sorted(required - regular)
        if missing:
            raise ValueError("归档缺少生产文件：" + ", ".join(missing))

        available = shutil.disk_usage(os.path.dirname(destination)).free
        if available < total + reserve_bytes:
            raise ValueError("临时目录空间不足，无法安全展开正式包")

        os.makedirs(destination, mode=0o700, exist_ok=False)
        for member, parts in validated:
            target = os.path.join(destination, *parts)
            if member.isdir():
                os.makedirs(target, mode=0o700, exist_ok=True)
                continue
            os.makedirs(os.path.dirname(target), mode=0o700, exist_ok=True)
            mode = 0o700 if member.mode & 0o111 else 0o600
            source_file = source.extractfile(member)
            if source_file is None:
                raise ValueError("无法读取归档普通文件")
            descriptor = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)
            with source_file, os.fdopen(descriptor, "wb") as output:
                shutil.copyfileobj(source_file, output, length=1024 * 1024)
except (OSError, tarfile.TarError, ValueError) as error:
    print("错误：正式包安全检查失败：" + str(error), file=sys.stderr)
    sys.exit(1)
PY
}

read_marker_value() {
  local marker=$1 wanted=$2 line
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == "${wanted}="* ]] || continue
    printf '%s\n' "${line#*=}"
    return 0
  done < "$marker"
  return 1
}

directory_has_entries() {
  local directory=$1
  local -a entries=()
  shopt -s nullglob dotglob
  entries=("$directory"/*)
  shopt -u nullglob dotglob
  (( ${#entries[@]} > 0 ))
}

inspect_existing_installation() {
  local deploy_dir=$1 marker="${1}/.crisp-ai-installation"
  local first_line state installed_version comparison
  [[ -d "$deploy_dir" ]] || return 0
  if [[ ! -e "$marker" && ! -L "$marker" ]]; then
    directory_has_entries "$deploy_dir" \
      && die "目标目录非空且不是受管 CrispAI 实例：${deploy_dir}"
    return 0
  fi
  [[ -f "$marker" && ! -L "$marker" ]] \
    || die "安装标记不是安全普通文件：${marker}"
  IFS= read -r first_line < "$marker" || true
  [[ "$first_line" == ai-support ]] || die "安装标记无效：${marker}"
  state=$(read_marker_value "$marker" state 2>/dev/null || printf ready)
  installed_version=$(read_marker_value "$marker" installed_version 2>/dev/null || true)
  [[ -z "$installed_version" ]] || valid_release "$installed_version" \
    || die '现有安装记录的版本格式无效'

  case "$state" in
    ready|local-ready)
      if (( UPDATE_REQUEST == 0 )); then
        if [[ -n "$RELEASE_REQUEST" && -n "$installed_version" ]]; then
          comparison=$(version_compare "$RELEASE_REQUEST" "$installed_version")
          (( comparison >= 0 )) \
            || die "已安装版本 ${installed_version} 高于指定版本 ${RELEASE_REQUEST}；回滚请使用 crispai 菜单"
          if (( comparison > 0 )); then
            warn "当前为 ${installed_version}，指定版本为 ${RELEASE_REQUEST}；未使用 --update，不会静默升级"
          fi
        fi
        if [[ -f "${deploy_dir}/manage.sh" && ! -L "${deploy_dir}/manage.sh" ]]; then
          info "检测到已安装实例 ${installed_version:-未知版本}，正在打开管理菜单"
          exec bash "${deploy_dir}/manage.sh" --deploy-dir "$deploy_dir"
        fi
        warn '现有实例缺少管理入口，将下载同版本正式包进行受控修复'
        [[ -z "$installed_version" ]] || SELECTED_RELEASE=$installed_version
      fi
      ;;
    collecting|installing|staged|uninstalled-data-kept)
      (( UPDATE_REQUEST == 0 )) \
        || die "当前实例状态为 ${state}，请先不带 --update 继续或恢复安装"
      if [[ -n "$RELEASE_REQUEST" && -n "$installed_version" \
        && "$RELEASE_REQUEST" != "$installed_version" ]]; then
        die "未完成实例必须先用原版本 ${installed_version} 恢复，不能混入 ${RELEASE_REQUEST}"
      fi
      [[ -z "$installed_version" ]] || SELECTED_RELEASE=$installed_version
      info "检测到 ${state} 状态，将从已保存进度继续"
      ;;
    *) die "现有安装状态无效：${state:-空}" ;;
  esac
}

write_release_metadata() {
  local deploy_dir=$1 release=$2 checksum=$3 source_url=$4
  local config_dir="${deploy_dir}/config" target="${deploy_dir}/config/.online-release" temporary
  [[ -d "$config_dir" && ! -L "$config_dir" ]] || return 1
  temporary=$(mktemp "${config_dir}/.online-release.XXXXXX") || return 1
  {
    printf 'schema=1\n'
    printf 'release=%s\n' "$release"
    printf 'archive_sha256=%s\n' "$checksum"
    printf 'source=%s\n' "$source_url"
    printf 'verified_at=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  } > "$temporary"
  chmod 0600 "$temporary"
  mv -f -- "$temporary" "$target"
}

run_package_entry() {
  local package_root=$1 deploy_dir=$2 release=$3 archive_url=$4 status
  cd -- "$INTERNAL_CALLER_DIR"
  if (( UPDATE_REQUEST )); then
    if bash "${package_root}/update.sh" --deploy-dir "$deploy_dir" \
      --source-dir "$package_root" --no-pull; then
      status=0
    else
      status=$?
    fi
  else
    if bash "${package_root}/install.sh" --deploy-dir "$deploy_dir"; then
      status=0
    else
      status=$?
    fi
  fi
  if (( status == 0 || status == 2 )); then
    write_release_metadata "$deploy_dir" "$release" "$ARCHIVE_SHA256" "$archive_url" \
      || warn '安装已完成，但无法保存非敏感的在线包来源记录'
  fi
  return "$status"
}

ORIGINAL_ARGS=("$@")
SHOW_HELP=0
SHOW_VERSION=0
while (( $# > 0 )); do
  case "$1" in
    --release)
      (( $# >= 2 )) || die '--release 缺少参数' 64
      RELEASE_REQUEST=$2
      shift 2
      ;;
    --deploy-dir)
      (( $# >= 2 )) || die '--deploy-dir 缺少参数' 64
      DEPLOY_REQUEST=$2
      shift 2
      ;;
    --update)
      UPDATE_REQUEST=1
      shift
      ;;
    --help|-h)
      SHOW_HELP=1
      shift
      ;;
    --version)
      SHOW_VERSION=1
      shift
      ;;
    --_caller-dir)
      (( $# >= 2 )) || die '--_caller-dir 缺少参数' 64
      INTERNAL_CALLER_DIR=$2
      shift 2
      ;;
    *) die "未知选项：$1" 64 ;;
  esac
done

if (( SHOW_HELP )); then usage; exit 0; fi
if (( SHOW_VERSION )); then printf '%s\n' "$GET_VERSION"; exit 0; fi
[[ -z "$RELEASE_REQUEST" ]] || valid_release "$RELEASE_REQUEST" \
  || die "正式版本格式无效：${RELEASE_REQUEST}" 64

SELF_PATH=${BASH_SOURCE[0]:-}
[[ -n "$SELF_PATH" && -f "$SELF_PATH" && ! -L "$SELF_PATH" ]] \
  || die '不支持从管道或进程替换直接执行 get.sh；请使用文档中的安全临时文件命令'
if [[ "$SELF_PATH" != /* ]]; then SELF_PATH="$(pwd -P)/${SELF_PATH}"; fi
if [[ -z "$INTERNAL_CALLER_DIR" ]]; then INTERNAL_CALLER_DIR=$(pwd -P); fi
[[ "$INTERNAL_CALLER_DIR" == /* && -d "$INTERNAL_CALLER_DIR" \
  && "$INTERNAL_CALLER_DIR" != *$'\n'* && "$INTERNAL_CALLER_DIR" != *$'\r'* ]] \
  || die '原始工作目录无效，无法安全解析 Prompt 或知识库相对路径'

require_interactive_terminal
require_root "$SELF_PATH" "$INTERNAL_CALLER_DIR" "${ORIGINAL_ARGS[@]}"
trap cleanup EXIT
trap handle_interrupt INT TERM

configure_test_endpoints
if ! command -v realpath >/dev/null 2>&1; then
  prepare_download_tools
fi
DEPLOY_DIR=$(realpath -m -- "${DEPLOY_REQUEST:-$DEFAULT_DEPLOY_DIR}")
[[ "$DEPLOY_DIR" == /* && "$DEPLOY_DIR" != / && "$DEPLOY_DIR" != *$'\n'* \
  && "$DEPLOY_DIR" != *$'\r'* ]] || die '部署目录无效或范围过宽'
[[ ! -L "$DEPLOY_DIR" ]] || die '部署目录不得是符号链接'

inspect_existing_installation "$DEPLOY_DIR"
if (( UPDATE_REQUEST )) && [[ ! -f "${DEPLOY_DIR}/.crisp-ai-installation" ]]; then
  die '--update 只适用于已完成的受管实例'
fi
prepare_download_tools
if [[ -z "$SELECTED_RELEASE" ]]; then
  if [[ -n "$RELEASE_REQUEST" ]]; then
    SELECTED_RELEASE=$RELEASE_REQUEST
  else
    info '正在解析当前 Latest 正式版'
    resolve_latest_release
  fi
fi
valid_release "$SELECTED_RELEASE" || die '无法确定安全的正式版本'

if (( UPDATE_REQUEST )); then
  MARKER="${DEPLOY_DIR}/.crisp-ai-installation"
  [[ -f "$MARKER" && ! -L "$MARKER" ]] \
    || die '--update 只适用于已完成的受管实例'
  INSTALLED_VERSION=$(read_marker_value "$MARKER" installed_version 2>/dev/null || true)
  valid_release "$INSTALLED_VERSION" || die '无法确认当前安装版本，拒绝在线更新'
  COMPARISON=$(version_compare "$SELECTED_RELEASE" "$INSTALLED_VERSION")
  (( COMPARISON >= 0 )) \
    || die "目标版本 ${SELECTED_RELEASE} 低于当前版本 ${INSTALLED_VERSION}；请使用受管回滚功能"
  if (( COMPARISON == 0 )); then
    info "当前已经是 ${SELECTED_RELEASE}，无需更新"
    exit 0
  fi
fi

WORK_DIR=$(mktemp -d /tmp/crispai-get.XXXXXXXX)
[[ "$WORK_DIR" == /tmp/crispai-get.* && -d "$WORK_DIR" && ! -L "$WORK_DIR" ]] \
  || die '无法创建安全的临时目录'
chmod 0700 "$WORK_DIR"

ARCHIVE_NAME="ai-support-${SELECTED_RELEASE}.tar.gz"
ARCHIVE_URL="${RELEASE_DOWNLOAD_ROOT}/${SELECTED_RELEASE}/${ARCHIVE_NAME}"
CHECKSUM_URL="${RELEASE_DOWNLOAD_ROOT}/${SELECTED_RELEASE}/SHA256SUMS"
ARCHIVE_FILE="${WORK_DIR}/${ARCHIVE_NAME}"
CHECKSUM_FILE="${WORK_DIR}/SHA256SUMS"
EXTRACT_DIR="${WORK_DIR}/extract"
PACKAGE_ROOT="${EXTRACT_DIR}/ai-support-${SELECTED_RELEASE}"
REQUIRED_ENTRIES_FILE="${WORK_DIR}/required-production-files.txt"
required_package_entries "$SELECTED_RELEASE" > "$REQUIRED_ENTRIES_FILE"
chmod 0600 "$REQUIRED_ENTRIES_FILE"

info "已锁定正式版本 ${SELECTED_RELEASE}，正在核对 Release 和资产状态"
verify_release_metadata "$SELECTED_RELEASE" "$ARCHIVE_NAME" "${WORK_DIR}/release.json"
check_download_capacity "$WORK_DIR" "$ARCHIVE_EXPECTED_BYTES" "$CHECKSUM_EXPECTED_BYTES"
info "Release 已正式发布，正在下载完整包和校验文件"
download_file "$ARCHIVE_URL" "$ARCHIVE_FILE" "$ARCHIVE_DOWNLOAD_MAX_BYTES" \
  "$ARCHIVE_EXPECTED_BYTES" '正式发布包'
download_file "$CHECKSUM_URL" "$CHECKSUM_FILE" "$CHECKSUM_DOWNLOAD_MAX_BYTES" \
  "$CHECKSUM_EXPECTED_BYTES" 'SHA256SUMS'
verify_checksum_file "$CHECKSUM_FILE" "$ARCHIVE_FILE" "$ARCHIVE_NAME"
info "SHA-256 校验通过：${ARCHIVE_SHA256}"
validate_and_extract_archive "$ARCHIVE_FILE" "$EXTRACT_DIR" \
  "ai-support-${SELECTED_RELEASE}" "$SELECTED_RELEASE" "$REQUIRED_ENTRIES_FILE"

[[ -d "$PACKAGE_ROOT" && ! -L "$PACKAGE_ROOT" \
  && -f "${PACKAGE_ROOT}/VERSION" && ! -L "${PACKAGE_ROOT}/VERSION" ]] \
  || die '解压后没有得到唯一、完整的版本目录'
PACKAGE_VERSION=$(<"${PACKAGE_ROOT}/VERSION")
[[ "$PACKAGE_VERSION" == "$SELECTED_RELEASE" ]] \
  || die "包内 VERSION 与锁定版本不一致：${PACKAGE_VERSION:-空}"
while IFS= read -r REQUIRED_ENTRY || [[ -n "$REQUIRED_ENTRY" ]]; do
  [[ -f "${PACKAGE_ROOT}/${REQUIRED_ENTRY}" && ! -L "${PACKAGE_ROOT}/${REQUIRED_ENTRY}" ]] \
    || die "正式包缺少安全生产文件：${REQUIRED_ENTRY}"
done < "$REQUIRED_ENTRIES_FILE"

printf '%s\n' '================================'
printf ' CrispAI 在线安装 %s\n' "$SELECTED_RELEASE"
printf '%s\n' '================================'
if run_package_entry "$PACKAGE_ROOT" "$DEPLOY_DIR" "$SELECTED_RELEASE" "$ARCHIVE_URL"; then
  info "${SELECTED_RELEASE} 已通过校验并完成安装或更新"
else
  STATUS=$?
  if (( STATUS == 2 )); then
    warn '本地安装已完成，外部 Crisp/公网接入仍待验证；可运行 crispai doctor 继续检查'
  fi
  exit "$STATUS"
fi

# crispai-get-end
