#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail
# 单引号内容由测试子 shell 展开位置参数。

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
BOOTSTRAP_SCRIPT="${PROJECT_ROOT}/scripts/bootstrap.sh"
TEST_ROOT=$(mktemp -d "${PROJECT_ROOT}/.test-runtime.bootstrap.XXXXXX")
PASSED=0

cleanup() {
  if [[ "$TEST_ROOT" == "${PROJECT_ROOT}"/.test-runtime.bootstrap.* && -d "$TEST_ROOT" ]]; then
    rm -rf -- "$TEST_ROOT"
  fi
}
trap cleanup EXIT

fail() {
  printf '依赖引导测试失败：%s\n' "$1" >&2
  exit 1
}

pass() {
  ((PASSED += 1))
  printf '通过：%s\n' "$1"
}

assert_contains() {
  local file=$1
  local expected=$2
  grep -Fq -- "$expected" "$file" || fail "${file} 缺少内容：${expected}"
}

write_os_release() {
  local target=$1
  local id=$2
  local version=$3
  local codename=$4
  mkdir -p -- "$(dirname -- "$target")"
  {
    printf 'ID=%s\n' "$id"
    printf 'ID_LIKE=debian\n'
    printf 'VERSION_ID="%s"\n' "$version"
    printf 'VERSION_CODENAME=%s\n' "$codename"
    [[ "$id" != ubuntu ]] || printf 'UBUNTU_CODENAME=%s\n' "$codename"
  } > "$target"
}

write_mock_commands() {
  local root=$1
  local bin="${root}/bin"
  local state="${root}/state"
  local command_name path
  mkdir -p -- "$bin" "$state" "${root}/etc"

  cat > "${bin}/mock-apt-get" <<'MOCK'
#!/bin/bash
set -euo pipefail
printf 'apt-get' >> "${MOCK_STATE}/apt.log"
printf ' %s' "$@" >> "${MOCK_STATE}/apt.log"
printf '\n' >> "${MOCK_STATE}/apt.log"
if [[ -n "${MOCK_APT_FAIL_CODE:-}" ]]; then
  exit "$MOCK_APT_FAIL_CODE"
fi
action=""
for argument in "$@"; do
  case "$argument" in
    update|install) action=$argument ;;
  esac
done
[[ "$action" != install ]] || {
  while IFS='=' read -r command_name command_path; do
    [[ -n "$command_name" && -x "$command_path" ]] || continue
    /usr/bin/ln -sfn -- "$command_path" "${MOCK_BIN}/${command_name}"
  done < "${MOCK_STATE}/runtime-links"
  /usr/bin/mkdir -p -- "${CRISP_AI_BOOTSTRAP_ETC_ROOT}/ssl/certs"
  printf 'test CA bundle\n' > "${CRISP_AI_BOOTSTRAP_ETC_ROOT}/ssl/certs/ca-certificates.crt"
  for argument in "$@"; do
    case "$argument" in
      docker-ce)
        /usr/bin/ln -sfn -- "${MOCK_BIN}/mock-docker" "${MOCK_BIN}/docker"
        : > "${MOCK_STATE}/installed-docker-ce"
        ;;
      docker-compose-plugin|docker-compose-v2|docker-compose)
        : > "${MOCK_STATE}/compose"
        ;;
    esac
  done
}
MOCK

  cat > "${bin}/mock-docker" <<'MOCK'
#!/bin/bash
set -euo pipefail
printf 'docker' >> "${MOCK_STATE}/docker.log"
printf ' %s' "$@" >> "${MOCK_STATE}/docker.log"
printf '\n' >> "${MOCK_STATE}/docker.log"
case "${1:-}" in
  context)
    case "${2:-}" in
      show) printf '%s\n' "${MOCK_DOCKER_CONTEXT:-default}" ;;
      inspect) printf '%s\n' "${MOCK_DOCKER_ENDPOINT:-unix:///var/run/docker.sock}" ;;
      *) exit 2 ;;
    esac
    ;;
  compose)
    [[ -f "${MOCK_STATE}/compose" \
      || -x "${CRISP_AI_BOOTSTRAP_USR_LOCAL_ROOT:-/nonexistent}/lib/docker/cli-plugins/docker-compose" ]] || exit 3
    case "${2:-}" in
      --help) printf '%s\n' 'Usage: docker compose --project-directory PATH --env-file FILE' ;;
      version) printf 'Docker Compose version v5.5.1\n' ;;
      config|up) [[ "${3:-}" == --help ]] || exit 4 ;;
      *) exit 4 ;;
    esac
    ;;
  info)
    [[ -f "${MOCK_STATE}/daemon" ]] || exit 5
    if [[ "${2:-}" == --format && "${3:-}" == '{{.Architecture}}' ]]; then
      printf '%s\n' "${MOCK_DOCKER_ARCH:-x86_64}"
    fi
    ;;
  version)
    [[ -f "${MOCK_STATE}/daemon" ]] || exit 5
    [[ "${2:-}" == --format && "${3:-}" == '{{.Server.Version}}' ]] || exit 11
    printf '%s\n' "${MOCK_DOCKER_VERSION:-28.0.1}"
    ;;
  run)
    [[ -f "${MOCK_STATE}/daemon" ]] || exit 5
    [[ "$*" == *hello-world* ]] || exit 6
    : > "${MOCK_STATE}/hello-world"
    ;;
  *) exit 7 ;;
esac
MOCK

  cat > "${bin}/curl-mock" <<'MOCK'
#!/bin/bash
set -euo pipefail
output=""
url=""
while (( $# > 0 )); do
  case "$1" in
    --output)
      output=$2
      shift 2
      ;;
    http://*|https://*) url=$1; shift ;;
    *) shift ;;
  esac
done
[[ -n "$output" ]] || exit 8
case "$url" in
  */gpg)
    printf '%s\n' '-----BEGIN PGP PUBLIC KEY BLOCK-----' 'test-only-key' '-----END PGP PUBLIC KEY BLOCK-----' > "$output"
    ;;
  */checksums.txt)
    [[ -s "${MOCK_STATE}/compose-sha256" ]] || exit 9
    digest=$(<"${MOCK_STATE}/compose-sha256")
    [[ "${MOCK_BAD_CHECKSUM:-0}" != 1 ]] || digest=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    printf '%s *docker-compose-linux-x86_64\n' "$digest" > "$output"
    printf '%s *docker-compose-linux-aarch64\n' "$digest" >> "$output"
    ;;
  */docker-compose-linux-*)
    printf '%s\n' 'test-only-compose-binary' > "$output"
    /usr/bin/sha256sum "$output" | {
      read -r digest _
      printf '%s\n' "$digest" > "${MOCK_STATE}/compose-sha256"
    }
    ;;
  *) exit 10 ;;
esac
MOCK

  cat > "${bin}/uname" <<'MOCK'
#!/bin/bash
set -euo pipefail
printf '%s\n' "${MOCK_UNAME_MACHINE:-x86_64}"
MOCK

  cat > "${bin}/dpkg-query" <<'MOCK'
#!/bin/bash
set -euo pipefail
package=${!#}
if [[ -f "${MOCK_STATE}/installed-${package}" ]]; then
  printf 'ii \n'
  exit 0
fi
exit 1
MOCK

  cat > "${bin}/apt-cache" <<'MOCK'
#!/bin/bash
set -euo pipefail
[[ "${1:-}" == show && "${2:-}" == docker-compose-v2 && "${MOCK_COMPOSE_PACKAGE:-1}" == 1 ]]
MOCK

  cat > "${bin}/systemctl" <<'MOCK'
#!/bin/bash
set -euo pipefail
printf 'systemctl %s\n' "$*" >> "${MOCK_STATE}/systemctl.log"
if [[ -n "${MOCK_SYSTEMCTL_FAIL_CODE:-}" ]]; then
  exit "$MOCK_SYSTEMCTL_FAIL_CODE"
fi
: > "${MOCK_STATE}/daemon"
MOCK

  cat > "${bin}/service" <<'MOCK'
#!/bin/bash
set -euo pipefail
printf 'service %s\n' "$*" >> "${MOCK_STATE}/service.log"
: > "${MOCK_STATE}/daemon"
MOCK

  chmod 0755 "${bin}/mock-apt-get" "${bin}/mock-docker" "${bin}/curl-mock" \
    "${bin}/uname" "${bin}/dpkg-query" "${bin}/apt-cache" "${bin}/systemctl" "${bin}/service"
  ln -s -- mock-apt-get "${bin}/apt-get"

  : > "${state}/runtime-links"
  for command_name in \
    jq openssl tar gzip base64 sha256sum realpath stat df du install cat dirname basename mkdir rmdir \
    mktemp chmod chown cp mv rm touch date sort head tail tr cut paste wc find grep \
    sed awk xargs flock ss sleep python3 cmp; do
    path=$(command -v "$command_name" 2>/dev/null || true)
    [[ -n "$path" ]] || fail "测试主机缺少用于构造隔离工具的命令：${command_name}"
    printf '%s=%s\n' "$command_name" "$path" >> "${state}/runtime-links"
  done
  printf 'curl=%s\n' "${bin}/curl-mock" >> "${state}/runtime-links"
}

run_bootstrap_function() {
  local root=$1
  local function_name=$2
  local extra_path=${3:-}
  env \
    CRISP_AI_BOOTSTRAP_TEST_MODE=1 \
    CRISP_AI_BOOTSTRAP_OS_RELEASE="${root}/os-release" \
    CRISP_AI_BOOTSTRAP_ETC_ROOT="${root}/etc" \
    CRISP_AI_BOOTSTRAP_USR_LOCAL_ROOT="${root}/usr-local" \
    CRISP_AI_BOOTSTRAP_INIT=systemd \
    CRISP_AI_BOOTSTRAP_DOCKER_ATTEMPTS=2 \
    CRISP_AI_BOOTSTRAP_DOCKER_INTERVAL=0 \
    MOCK_BIN="${root}/bin" \
    MOCK_STATE="${root}/state" \
    MOCK_COMPOSE_PACKAGE="${MOCK_COMPOSE_PACKAGE:-1}" \
    MOCK_BAD_CHECKSUM="${MOCK_BAD_CHECKSUM:-0}" \
    PATH="${root}/bin${extra_path:+:$extra_path}" \
    /bin/bash -c 'source "$1"; "$2"' bootstrap-test "$BOOTSTRAP_SCRIPT" "$function_name"
}

[[ -f "$BOOTSTRAP_SCRIPT" && ! -L "$BOOTSTRAP_SCRIPT" ]] || fail "bootstrap.sh 缺失或不安全"

# source 与 --help 必须只依赖 Bash，不执行 apt、Docker 或 root 检查。
HELP_ROOT="${TEST_ROOT}/help"
write_mock_commands "$HELP_ROOT"
ln -s -- "$(command -v dirname)" "${HELP_ROOT}/bin/dirname"
ln -s -- "$(command -v cat)" "${HELP_ROOT}/bin/cat"
HELP_OUTPUT=$(PATH="${HELP_ROOT}/bin" MOCK_STATE="${HELP_ROOT}/state" \
  /bin/bash "$BOOTSTRAP_SCRIPT" --help)
[[ "$HELP_OUTPUT" == *'--minimal'* && "$HELP_OUTPUT" == *'--docker'* ]] || fail "--help 输出不完整"
[[ ! -e "${HELP_ROOT}/state/apt.log" && ! -e "${HELP_ROOT}/state/docker.log" ]] \
  || fail "--help 意外调用 apt 或 Docker"
PATH="${HELP_ROOT}/bin" MOCK_STATE="${HELP_ROOT}/state" \
  /bin/bash -c '
    set +e +u +o pipefail
    source "$1"
    [[ "$-" != *e* && "$-" != *u* ]]
    ! shopt -qo pipefail
    [[ -z "${BOOTSTRAP_PLATFORM_ID+x}" && -z "${BOOTSTRAP_DOCKER_INSTALLED+x}" ]]
  ' bootstrap-source "$BOOTSTRAP_SCRIPT"
[[ ! -e "${HELP_ROOT}/state/apt.log" && ! -e "${HELP_ROOT}/state/docker.log" ]] \
  || fail "source bootstrap.sh 出现运行期副作用"
INSTALL_HELP_OUTPUT=$(PATH="${HELP_ROOT}/bin" MOCK_STATE="${HELP_ROOT}/state" \
  /bin/bash "${PROJECT_ROOT}/install.sh" --help)
[[ "$INSTALL_HELP_OUTPUT" == *'--deploy-dir'* && "$INSTALL_HELP_OUTPUT" == *'--version'* ]] \
  || fail "生产 install.sh --help 输出不完整"
[[ ! -e "${HELP_ROOT}/state/apt.log" && ! -e "${HELP_ROOT}/state/docker.log" ]] \
  || fail "install.sh --help 在参数处理前调用了依赖引导"
pass "帮助与 source 无依赖副作用"

# 四个明确支持版本必须映射为固定发行版代号。
for platform in 'debian 12 bookworm' 'debian 13 trixie' 'ubuntu 22.04 jammy' 'ubuntu 24.04 noble'; do
  read -r os_id os_version os_codename <<< "$platform"
  PLATFORM_ROOT="${TEST_ROOT}/platform-${os_id}-${os_version}"
  write_mock_commands "$PLATFORM_ROOT"
  write_os_release "${PLATFORM_ROOT}/os-release" "$os_id" "$os_version" "$os_codename"
  env CRISP_AI_BOOTSTRAP_TEST_MODE=1 \
    CRISP_AI_BOOTSTRAP_OS_RELEASE="${PLATFORM_ROOT}/os-release" \
    PATH="${PLATFORM_ROOT}/bin:/usr/bin:/bin" MOCK_STATE="${PLATFORM_ROOT}/state" \
    /bin/bash -c 'source "$1"; bootstrap_detect_platform; [[ "$BOOTSTRAP_PLATFORM_CODENAME" == "$2" && "$BOOTSTRAP_PLATFORM_ID_LIKE" == debian ]]' \
    platform-test "$BOOTSTRAP_SCRIPT" "$os_codename" \
    || fail "系统识别失败：${platform}"
done
pass "Debian 12/13 与 Ubuntu 22.04/24.04 系统识别"

# 完全隔离 PATH：先补齐基础工具，再经官方 apt 源安装 Engine/CLI/containerd/Compose，启动 daemon 并运行容器。
CLEAN_ROOT="${TEST_ROOT}/clean"
write_mock_commands "$CLEAN_ROOT"
write_os_release "${CLEAN_ROOT}/os-release" debian 12 bookworm
run_bootstrap_function "$CLEAN_ROOT" bootstrap_prepare_host \
  || fail "无依赖主机的完整引导失败"
assert_contains "${CLEAN_ROOT}/state/apt.log" 'ca-certificates'
assert_contains "${CLEAN_ROOT}/state/apt.log" 'jq'
assert_contains "${CLEAN_ROOT}/state/apt.log" 'findutils'
assert_contains "${CLEAN_ROOT}/state/apt.log" 'iproute2'
assert_contains "${CLEAN_ROOT}/state/apt.log" 'python3'
assert_contains "${CLEAN_ROOT}/state/apt.log" 'python3-yaml'
assert_contains "${CLEAN_ROOT}/state/apt.log" 'diffutils'
MAPPED_XARGS_PACKAGE=$(env PATH="${CLEAN_ROOT}/bin" /bin/bash -c \
  'source "$1"; bootstrap_command_package xargs' bootstrap-map "$BOOTSTRAP_SCRIPT")
[[ "$MAPPED_XARGS_PACKAGE" == findutils ]] || fail "xargs 未映射到 findutils"
assert_contains "${CLEAN_ROOT}/state/apt.log" 'docker-ce'
assert_contains "${CLEAN_ROOT}/state/apt.log" 'containerd.io'
assert_contains "${CLEAN_ROOT}/state/apt.log" 'docker-compose-plugin'
assert_contains "${CLEAN_ROOT}/etc/apt/sources.list.d/docker.sources" 'URIs: https://download.docker.com/linux/debian'
assert_contains "${CLEAN_ROOT}/etc/apt/sources.list.d/docker.sources" 'Suites: bookworm'
[[ -f "${CLEAN_ROOT}/state/daemon" && -f "${CLEAN_ROOT}/state/hello-world" ]] \
  || fail "未真实经过 daemon 启动和 hello-world 生产函数路径"
assert_contains "${CLEAN_ROOT}/state/systemctl.log" 'enable --now docker'
pass "无基础依赖与无 Docker 的自动安装完整路径"

CLEAN_APT_LINES_BEFORE=$(wc -l < "${CLEAN_ROOT}/state/apt.log")
CLEAN_SOURCE_SHA_BEFORE=$(sha256sum "${CLEAN_ROOT}/etc/apt/sources.list.d/docker.sources" | awk '{print $1}')
run_bootstrap_function "$CLEAN_ROOT" bootstrap_prepare_host \
  || fail "完整引导重复执行失败"
CLEAN_APT_LINES_AFTER=$(wc -l < "${CLEAN_ROOT}/state/apt.log")
CLEAN_SOURCE_SHA_AFTER=$(sha256sum "${CLEAN_ROOT}/etc/apt/sources.list.d/docker.sources" | awk '{print $1}')
[[ "$CLEAN_APT_LINES_AFTER" == "$CLEAN_APT_LINES_BEFORE" ]] || fail "重复引导重新运行了 apt"
[[ "$CLEAN_SOURCE_SHA_AFTER" == "$CLEAN_SOURCE_SHA_BEFORE" ]] || fail "重复引导改写了 Docker apt source"
pass "依赖与 Docker 引导重复执行幂等"

# 已有健康 Docker/Compose 时只验证能力，不调用 apt 或重启服务。
EXISTING_ROOT="${TEST_ROOT}/existing"
write_mock_commands "$EXISTING_ROOT"
write_os_release "${EXISTING_ROOT}/os-release" ubuntu 24.04 noble
ln -s -- mock-docker "${EXISTING_ROOT}/bin/docker"
: > "${EXISTING_ROOT}/state/compose"
: > "${EXISTING_ROOT}/state/daemon"
run_bootstrap_function "$EXISTING_ROOT" bootstrap_prepare_docker_runtime /usr/bin:/bin \
  || fail "已有健康 Docker 的复用失败"
[[ ! -e "${EXISTING_ROOT}/state/apt.log" && ! -e "${EXISTING_ROOT}/state/systemctl.log" ]] \
  || fail "已有健康 Docker 被安装或重启"
[[ -f "${EXISTING_ROOT}/state/hello-world" ]] || fail "已有 Docker 未执行容器能力验证"
pass "已有健康 Docker 与兼容高版本 Compose 的无损复用"

# host-gateway 是当前 Compose 的实际能力依赖；旧 Engine 要明确拒绝且不自动升级现有环境。
OLD_ENGINE_ROOT="${TEST_ROOT}/old-engine"
write_mock_commands "$OLD_ENGINE_ROOT"
write_os_release "${OLD_ENGINE_ROOT}/os-release" debian 12 bookworm
ln -s -- mock-docker "${OLD_ENGINE_ROOT}/bin/docker"
: > "${OLD_ENGINE_ROOT}/state/compose"
: > "${OLD_ENGINE_ROOT}/state/daemon"
if env MOCK_DOCKER_VERSION=19.03.15 \
  CRISP_AI_BOOTSTRAP_TEST_MODE=1 CRISP_AI_BOOTSTRAP_OS_RELEASE="${OLD_ENGINE_ROOT}/os-release" \
  CRISP_AI_BOOTSTRAP_ETC_ROOT="${OLD_ENGINE_ROOT}/etc" MOCK_BIN="${OLD_ENGINE_ROOT}/bin" \
  MOCK_STATE="${OLD_ENGINE_ROOT}/state" PATH="${OLD_ENGINE_ROOT}/bin:/usr/bin:/bin" \
  /bin/bash -c 'source "$1"; bootstrap_prepare_docker_runtime' old-engine "$BOOTSTRAP_SCRIPT" \
  > "${OLD_ENGINE_ROOT}/output.log" 2>&1; then
  fail "低于实际最低需求的 Docker Engine 被错误接受"
fi
assert_contains "${OLD_ENGINE_ROOT}/output.log" '低于项目所需的 20.10'
[[ ! -e "${OLD_ENGINE_ROOT}/state/apt.log" && ! -e "${OLD_ENGINE_ROOT}/state/systemctl.log" ]] \
  || fail "拒绝旧 Engine 时错误升级或重启了现有 Docker"
pass "Docker Engine 最低能力与现有环境保护"

# 已有发行版 Docker 但缺 Compose，只安装同源 compose-v2，不替换 Engine。
COMPOSE_ROOT="${TEST_ROOT}/compose"
write_mock_commands "$COMPOSE_ROOT"
write_os_release "${COMPOSE_ROOT}/os-release" debian 12 bookworm
ln -s -- mock-docker "${COMPOSE_ROOT}/bin/docker"
: > "${COMPOSE_ROOT}/state/daemon"
run_bootstrap_function "$COMPOSE_ROOT" bootstrap_prepare_docker_runtime /usr/bin:/bin \
  || fail "缺失 Compose 的修复失败"
assert_contains "${COMPOSE_ROOT}/state/apt.log" 'docker-compose-v2'
if grep -Fq 'docker-ce ' "${COMPOSE_ROOT}/state/apt.log"; then
  fail "为发行版 Docker 补 Compose 时错误替换了 Engine"
fi
[[ -f "${COMPOSE_ROOT}/state/compose" ]] || fail "Compose 能力未补齐"
pass "已有 Docker 缺 Compose 的兼容补齐"

# Debian 12 的发行版源只有旧版 docker-compose v1；固定官方二进制经 SHA-256 后备安装，保留 docker.io 数据。
FALLBACK_ROOT="${TEST_ROOT}/compose-fallback"
write_mock_commands "$FALLBACK_ROOT"
write_os_release "${FALLBACK_ROOT}/os-release" debian 12 bookworm
ln -s -- mock-docker "${FALLBACK_ROOT}/bin/docker"
ln -s -- curl-mock "${FALLBACK_ROOT}/bin/curl"
: > "${FALLBACK_ROOT}/state/daemon"
MOCK_COMPOSE_PACKAGE=0 run_bootstrap_function "$FALLBACK_ROOT" bootstrap_prepare_docker_runtime /usr/bin:/bin \
  || fail "Debian 12 Compose 官方二进制后备安装失败"
[[ -x "${FALLBACK_ROOT}/usr-local/lib/docker/cli-plugins/docker-compose" ]] \
  || fail "校验后的 Compose 后备二进制未安装"
if [[ -e "${FALLBACK_ROOT}/state/installed-docker-ce" ]]; then
  fail "Compose 后备路径错误替换了现有 Docker Engine"
fi
[[ -f "${FALLBACK_ROOT}/state/hello-world" ]] || fail "Compose 后备安装后未完成容器验证"
pass "Debian 12 docker.io 的 Compose 校验后备安装"

BAD_CHECKSUM_ROOT="${TEST_ROOT}/compose-bad-checksum"
write_mock_commands "$BAD_CHECKSUM_ROOT"
write_os_release "${BAD_CHECKSUM_ROOT}/os-release" debian 12 bookworm
ln -s -- mock-docker "${BAD_CHECKSUM_ROOT}/bin/docker"
ln -s -- curl-mock "${BAD_CHECKSUM_ROOT}/bin/curl"
: > "${BAD_CHECKSUM_ROOT}/state/daemon"
if MOCK_COMPOSE_PACKAGE=0 MOCK_BAD_CHECKSUM=1 \
  run_bootstrap_function "$BAD_CHECKSUM_ROOT" bootstrap_prepare_docker_runtime /usr/bin:/bin \
  > "${BAD_CHECKSUM_ROOT}/output.log" 2>&1; then
  fail "校验错误的 Compose 二进制被安装"
fi
assert_contains "${BAD_CHECKSUM_ROOT}/output.log" 'SHA-256 校验失败'
[[ ! -e "${BAD_CHECKSUM_ROOT}/usr-local/lib/docker/cli-plugins/docker-compose" ]] \
  || fail "校验失败后仍遗留 Compose 二进制"
pass "Compose 后备二进制校验失败即停止"

# daemon 停止时，应通过受管 systemd 服务启用并等待，而不是运行临时 dockerd。
STOPPED_ROOT="${TEST_ROOT}/stopped"
write_mock_commands "$STOPPED_ROOT"
write_os_release "${STOPPED_ROOT}/os-release" ubuntu 22.04 jammy
ln -s -- mock-docker "${STOPPED_ROOT}/bin/docker"
: > "${STOPPED_ROOT}/state/compose"
run_bootstrap_function "$STOPPED_ROOT" bootstrap_prepare_docker_runtime /usr/bin:/bin \
  || fail "停止的 daemon 未能恢复"
assert_contains "${STOPPED_ROOT}/state/systemctl.log" 'enable --now docker'
[[ -f "${STOPPED_ROOT}/state/hello-world" ]] || fail "daemon 启动后未运行容器"
pass "停止的 Docker daemon 自动启动与等待"

# 远程 endpoint 会让 bind mount 指向另一主机，必须在任何变更前拒绝。
REMOTE_ROOT="${TEST_ROOT}/remote"
write_mock_commands "$REMOTE_ROOT"
write_os_release "${REMOTE_ROOT}/os-release" debian 13 trixie
ln -s -- mock-docker "${REMOTE_ROOT}/bin/docker"
: > "${REMOTE_ROOT}/state/compose"
: > "${REMOTE_ROOT}/state/daemon"
if env DOCKER_HOST=tcp://docker.example.test:2376 \
  CRISP_AI_BOOTSTRAP_TEST_MODE=1 CRISP_AI_BOOTSTRAP_OS_RELEASE="${REMOTE_ROOT}/os-release" \
  CRISP_AI_BOOTSTRAP_ETC_ROOT="${REMOTE_ROOT}/etc" MOCK_BIN="${REMOTE_ROOT}/bin" \
  MOCK_STATE="${REMOTE_ROOT}/state" PATH="${REMOTE_ROOT}/bin:/usr/bin:/bin" \
  /bin/bash -c 'source "$1"; bootstrap_prepare_docker_runtime' remote-test "$BOOTSTRAP_SCRIPT" \
  > "${REMOTE_ROOT}/output.log" 2>&1; then
  fail "远程 DOCKER_HOST 被错误接受"
fi
assert_contains "${REMOTE_ROOT}/output.log" 'bind mount'
[[ ! -e "${REMOTE_ROOT}/state/hello-world" ]] || fail "远程 endpoint 拒绝后仍运行了容器"
pass "远程 Docker endpoint 与 bind mount 风险拒绝"

# 不支持系统必须明确失败，且不得先运行 apt。
UNSUPPORTED_ROOT="${TEST_ROOT}/unsupported"
write_mock_commands "$UNSUPPORTED_ROOT"
write_os_release "${UNSUPPORTED_ROOT}/os-release" alpine 3.20 edge
if run_bootstrap_function "$UNSUPPORTED_ROOT" bootstrap_prepare_minimal_dependencies /usr/bin:/bin \
  > "${UNSUPPORTED_ROOT}/output.log" 2>&1; then
  fail "不支持系统被错误接受"
fi
assert_contains "${UNSUPPORTED_ROOT}/output.log" '不支持的系统'
[[ ! -e "${UNSUPPORTED_ROOT}/state/apt.log" ]] || fail "不支持系统仍执行了 apt"
pass "不支持系统在变更前明确拒绝"

# apt 与 systemd 的原始失败码必须传回，不能在 ! 或日志分支中被改成 0/1。
APT_FAIL_ROOT="${TEST_ROOT}/apt-fail"
write_mock_commands "$APT_FAIL_ROOT"
write_os_release "${APT_FAIL_ROOT}/os-release" debian 12 bookworm
set +e
env CRISP_AI_BOOTSTRAP_TEST_MODE=1 CRISP_AI_BOOTSTRAP_OS_RELEASE="${APT_FAIL_ROOT}/os-release" \
  CRISP_AI_BOOTSTRAP_ETC_ROOT="${APT_FAIL_ROOT}/etc" MOCK_BIN="${APT_FAIL_ROOT}/bin" \
  MOCK_STATE="${APT_FAIL_ROOT}/state" MOCK_APT_FAIL_CODE=42 PATH="${APT_FAIL_ROOT}/bin" \
  /bin/bash -c 'source "$1"; bootstrap_prepare_minimal_dependencies' apt-fail "$BOOTSTRAP_SCRIPT" \
  > "${APT_FAIL_ROOT}/output.log" 2>&1
APT_STATUS=$?
set -e
[[ "$APT_STATUS" == 42 ]] || fail "apt 失败码未保留，实际为 ${APT_STATUS}"
assert_contains "${APT_FAIL_ROOT}/output.log" '退出码 42'
pass "软件包安装失败码与诊断保留"

SYSTEMD_FAIL_ROOT="${TEST_ROOT}/systemd-fail"
write_mock_commands "$SYSTEMD_FAIL_ROOT"
write_os_release "${SYSTEMD_FAIL_ROOT}/os-release" ubuntu 24.04 noble
ln -s -- mock-docker "${SYSTEMD_FAIL_ROOT}/bin/docker"
: > "${SYSTEMD_FAIL_ROOT}/state/compose"
set +e
env CRISP_AI_BOOTSTRAP_TEST_MODE=1 CRISP_AI_BOOTSTRAP_OS_RELEASE="${SYSTEMD_FAIL_ROOT}/os-release" \
  CRISP_AI_BOOTSTRAP_ETC_ROOT="${SYSTEMD_FAIL_ROOT}/etc" CRISP_AI_BOOTSTRAP_INIT=systemd \
  MOCK_BIN="${SYSTEMD_FAIL_ROOT}/bin" MOCK_STATE="${SYSTEMD_FAIL_ROOT}/state" \
  MOCK_SYSTEMCTL_FAIL_CODE=23 PATH="${SYSTEMD_FAIL_ROOT}/bin:/usr/bin:/bin" \
  /bin/bash -c 'source "$1"; bootstrap_prepare_docker_runtime' systemd-fail "$BOOTSTRAP_SCRIPT" \
  > "${SYSTEMD_FAIL_ROOT}/output.log" 2>&1
SYSTEMD_STATUS=$?
set -e
[[ "$SYSTEMD_STATUS" == 23 ]] || fail "systemd 失败码未保留，实际为 ${SYSTEMD_STATUS}"
assert_contains "${SYSTEMD_FAIL_ROOT}/output.log" '退出码 23'
pass "Docker 服务启动失败码与诊断保留"

# 缺少权限时在包管理之前终止，不宣称安装成功。
NO_ROOT_ROOT="${TEST_ROOT}/no-root"
write_mock_commands "$NO_ROOT_ROOT"
write_os_release "${NO_ROOT_ROOT}/os-release" debian 12 bookworm
if env CRISP_AI_BOOTSTRAP_TEST_MODE=1 CRISP_AI_BOOTSTRAP_EUID=1000 \
  CRISP_AI_BOOTSTRAP_OS_RELEASE="${NO_ROOT_ROOT}/os-release" \
  CRISP_AI_BOOTSTRAP_ETC_ROOT="${NO_ROOT_ROOT}/etc" MOCK_BIN="${NO_ROOT_ROOT}/bin" \
  MOCK_STATE="${NO_ROOT_ROOT}/state" PATH="${NO_ROOT_ROOT}/bin" \
  /bin/bash -c 'source "$1"; bootstrap_prepare_minimal_dependencies' no-root "$BOOTSTRAP_SCRIPT" \
  > "${NO_ROOT_ROOT}/output.log" 2>&1; then
  fail "无 root 权限时错误返回成功"
fi
assert_contains "${NO_ROOT_ROOT}/output.log" 'sudo bash ./install.sh'
[[ ! -e "${NO_ROOT_ROOT}/state/apt.log" ]] || fail "无权限时仍执行 apt"
pass "root、sudo 提示与无授权失败边界"

printf '依赖与 Docker 引导专项测试：%d 项通过\n' "$PASSED"
