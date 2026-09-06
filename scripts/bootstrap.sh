#!/usr/bin/env bash

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
fi

# 此文件可被 install.sh source。source 时只定义函数，不改变调用者 shell
# 选项、不导出变量，也不执行系统探测、权限检查、包安装或 Docker 操作。

bootstrap_info() {
  printf '信息：%s\n' "$*"
}

bootstrap_warn() {
  printf '警告：%s\n' "$*" >&2
}

bootstrap_error() {
  printf '错误：%s\n' "$*" >&2
}

bootstrap_die() {
  bootstrap_error "$*"
  return 1
}

bootstrap_is_test_mode() {
  [[ "${CRISP_AI_BOOTSTRAP_TEST_MODE:-0}" == 1 ]]
}

bootstrap_os_release_file() {
  if bootstrap_is_test_mode && [[ -n "${CRISP_AI_BOOTSTRAP_OS_RELEASE:-}" ]]; then
    printf '%s\n' "$CRISP_AI_BOOTSTRAP_OS_RELEASE"
  else
    printf '%s\n' /etc/os-release
  fi
}

bootstrap_etc_root() {
  if bootstrap_is_test_mode && [[ -n "${CRISP_AI_BOOTSTRAP_ETC_ROOT:-}" ]]; then
    printf '%s\n' "$CRISP_AI_BOOTSTRAP_ETC_ROOT"
  else
    printf '%s\n' /etc
  fi
}

bootstrap_usr_local_root() {
  if bootstrap_is_test_mode && [[ -n "${CRISP_AI_BOOTSTRAP_USR_LOCAL_ROOT:-}" ]]; then
    printf '%s\n' "$CRISP_AI_BOOTSTRAP_USR_LOCAL_ROOT"
  else
    printf '%s\n' /usr/local
  fi
}

bootstrap_read_os_value() {
  local os_file=$1
  local wanted=$2
  local line key value

  # Debian/Ubuntu 常把 /etc/os-release 作为指向 /usr/lib/os-release 的系统符号链接。
  [[ -f "$os_file" && -r "$os_file" ]] || return 1
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
  done < "$os_file"
  return 1
}

bootstrap_detect_platform() {
  local os_file machine id id_like version codename ubuntu_codename
  os_file=$(bootstrap_os_release_file)
  [[ -r "$os_file" ]] || bootstrap_die "无法读取系统版本文件：${os_file}" || return

  id=$(bootstrap_read_os_value "$os_file" ID 2>/dev/null || true)
  id_like=$(bootstrap_read_os_value "$os_file" ID_LIKE 2>/dev/null || true)
  version=$(bootstrap_read_os_value "$os_file" VERSION_ID 2>/dev/null || true)
  codename=$(bootstrap_read_os_value "$os_file" VERSION_CODENAME 2>/dev/null || true)
  ubuntu_codename=$(bootstrap_read_os_value "$os_file" UBUNTU_CODENAME 2>/dev/null || true)
  machine=$(uname -m 2>/dev/null || true)
  BOOTSTRAP_PLATFORM_ID_LIKE=$id_like

  case "$machine" in
    x86_64|amd64) BOOTSTRAP_PLATFORM_ARCH=amd64 ;;
    aarch64|arm64) BOOTSTRAP_PLATFORM_ARCH=arm64 ;;
    *) bootstrap_die "当前 CPU 架构尚未经过项目镜像验收：${machine:-未知}；仅支持 amd64、arm64" || return ;;
  esac

  case "${id}:${version}" in
    debian:12)
      BOOTSTRAP_PLATFORM_ID=debian
      BOOTSTRAP_PLATFORM_VERSION=12
      BOOTSTRAP_PLATFORM_CODENAME=bookworm
      ;;
    debian:13)
      BOOTSTRAP_PLATFORM_ID=debian
      BOOTSTRAP_PLATFORM_VERSION=13
      BOOTSTRAP_PLATFORM_CODENAME=trixie
      ;;
    ubuntu:22.04)
      BOOTSTRAP_PLATFORM_ID=ubuntu
      BOOTSTRAP_PLATFORM_VERSION=22.04
      BOOTSTRAP_PLATFORM_CODENAME=jammy
      ;;
    ubuntu:24.04)
      BOOTSTRAP_PLATFORM_ID=ubuntu
      BOOTSTRAP_PLATFORM_VERSION=24.04
      BOOTSTRAP_PLATFORM_CODENAME=noble
      ;;
    *)
      bootstrap_die "不支持的系统：${id:-未知} ${version:-未知}；当前支持 Debian 12/13、Ubuntu 22.04/24.04" || return
      ;;
  esac

  # 仅接受与已识别版本一致的发行版代号，防止把错误源写入 apt 配置。
  if [[ -n "$codename" && "$codename" != "$BOOTSTRAP_PLATFORM_CODENAME" ]] \
    && [[ -z "$ubuntu_codename" || "$ubuntu_codename" != "$BOOTSTRAP_PLATFORM_CODENAME" ]]; then
    bootstrap_die "系统版本与发行版代号不一致（${version}/${codename}），拒绝配置软件源" || return
  fi
}

bootstrap_require_root() {
  local effective_uid=$EUID
  if bootstrap_is_test_mode && [[ -n "${CRISP_AI_BOOTSTRAP_EUID:-}" ]]; then
    effective_uid=$CRISP_AI_BOOTSTRAP_EUID
  fi
  (( effective_uid == 0 )) \
    || bootstrap_die "自动安装依赖需要 root 权限；请使用 sudo bash ./install.sh，或由 root 直接运行" || return
}

bootstrap_apt_get() {
  local description=$1
  shift
  local status
  local lock_timeout=${CRISP_AI_BOOTSTRAP_APT_LOCK_TIMEOUT:-180}
  local -a apt_options=(
    -q
    -o APT::Color=0
    -o Dpkg::Use-Pty=0
    -o "DPkg::Lock::Timeout=${lock_timeout}"
    -o Acquire::Retries=3
    -o Acquire::http::Timeout=30
    -o Acquire::https::Timeout=30
  )

  [[ "$lock_timeout" =~ ^[1-9][0-9]{0,3}$ ]] \
    || bootstrap_die "软件包锁等待时间配置无效" || return
  bootstrap_info "${description}；如软件包管理器正被占用，将等待最多 ${lock_timeout} 秒"
  if DEBIAN_FRONTEND=noninteractive apt-get "${apt_options[@]}" "$@"; then
    return 0
  else
    status=$?
    bootstrap_error "${description}失败（退出码 ${status}）；已保留 apt/dpkg 锁与当前安装状态"
    return "$status"
  fi
}

bootstrap_command_package() {
  case "$1" in
    curl) printf '%s\n' curl ;;
    jq) printf '%s\n' jq ;;
    python3) printf '%s\n' python3 ;;
    cmp) printf '%s\n' diffutils ;;
    openssl) printf '%s\n' openssl ;;
    tar) printf '%s\n' tar ;;
    gzip) printf '%s\n' gzip ;;
    find|xargs) printf '%s\n' findutils ;;
    grep) printf '%s\n' grep ;;
    sed) printf '%s\n' sed ;;
    awk) printf '%s\n' mawk ;;
    flock) printf '%s\n' util-linux ;;
    ss) printf '%s\n' iproute2 ;;
    *) printf '%s\n' coreutils ;;
  esac
}

bootstrap_collect_missing_runtime_packages() {
  local command_name package etc_root
  local -a commands=(
    curl jq openssl tar gzip base64 sha256sum realpath stat df du install
    cat dirname basename mkdir rmdir mktemp chmod chown cp mv rm touch date sort head tail tr cut
    paste wc find grep sed awk xargs flock ss sleep python3 cmp
  )
  local -a packages=()

  etc_root=$(bootstrap_etc_root)
  [[ -s "${etc_root}/ssl/certs/ca-certificates.crt" ]] || packages+=(ca-certificates)

  for command_name in "${commands[@]}"; do
    command -v "$command_name" >/dev/null 2>&1 && continue
    package=$(bootstrap_command_package "$command_name")
    case " ${packages[*]} " in
      *" ${package} "*) ;;
      *) packages+=("$package") ;;
    esac
  done
  if ! command -v python3 >/dev/null 2>&1 || ! python3 -c 'import yaml' >/dev/null 2>&1; then
    packages+=(python3-yaml)
  fi
  # printf 在没有参数时仍会输出一个空行；显式跳过，避免 mapfile 将其
  # 解释为一个空包名并让幂等重跑再次调用 apt。
  (( ${#packages[@]} == 0 )) || printf '%s\n' "${packages[@]}"
}

bootstrap_verify_runtime_commands() {
  local command_name
  local -a commands=(
    curl jq openssl tar gzip base64 sha256sum realpath stat df du install
    cat dirname basename mkdir rmdir mktemp chmod chown cp mv rm touch date sort head tail tr cut
    paste wc find grep sed awk xargs flock ss sleep python3 cmp
  )
  for command_name in "${commands[@]}"; do
    command -v "$command_name" >/dev/null 2>&1 \
      || bootstrap_die "依赖安装后仍缺少命令：${command_name}" || return
  done
  python3 -c 'import yaml' >/dev/null 2>&1 \
    || bootstrap_die 'Python 3 的 YAML 库仍不可用；请检查自定义 PATH 是否遮蔽发行版 Python' || return
}

bootstrap_verify_ca_bundle() {
  local etc_root
  etc_root=$(bootstrap_etc_root)
  [[ -s "${etc_root}/ssl/certs/ca-certificates.crt" ]] \
    || bootstrap_die "CA 证书包安装后仍不可用，无法安全访问 HTTPS 服务" || return
}

bootstrap_prepare_minimal_dependencies() {
  local -a packages=()

  bootstrap_detect_platform || return $?
  mapfile -t packages < <(bootstrap_collect_missing_runtime_packages)
  if (( ${#packages[@]} == 0 )); then
    bootstrap_verify_runtime_commands || return $?
    bootstrap_verify_ca_bundle || return $?
    bootstrap_info "安装运行所需的基础工具已就绪"
    return 0
  fi

  bootstrap_require_root || return $?
  command -v apt-get >/dev/null 2>&1 \
    || bootstrap_die "受支持系统缺少 apt-get，无法自动补齐基础工具" || return
  bootstrap_apt_get "更新基础软件包索引" update || return $?
  bootstrap_apt_get "安装基础运行工具" install --yes --no-install-recommends "${packages[@]}" || return $?
  bootstrap_verify_runtime_commands || return $?
  bootstrap_verify_ca_bundle || return $?
  bootstrap_info "基础运行工具已自动补齐"
}

bootstrap_docker_endpoint_is_local() {
  case "$1" in
    ""|unix:///var/run/docker.sock|unix:///run/docker.sock) return 0 ;;
    *) return 1 ;;
  esac
}

bootstrap_validate_local_docker_target() {
  local endpoint="" context=""

  if [[ -n "${DOCKER_HOST:-}" ]] && ! bootstrap_docker_endpoint_is_local "$DOCKER_HOST"; then
    bootstrap_die "检测到远程或非系统 Docker endpoint（DOCKER_HOST）；部署包含宿主机 bind mount，拒绝连接远程 daemon" || return
  fi
  command -v docker >/dev/null 2>&1 || return 0
  context=$(docker context show 2>/dev/null) \
    || bootstrap_die "无法确认当前 Docker context，拒绝进行含 bind mount 的部署" || return
  [[ -n "$context" ]] || bootstrap_die "Docker context 名称为空，拒绝继续" || return
  endpoint=$(docker context inspect --format '{{.Endpoints.docker.Host}}' "$context" 2>/dev/null) \
    || bootstrap_die "无法检查当前 Docker endpoint，拒绝进行含 bind mount 的部署" || return
  bootstrap_docker_endpoint_is_local "$endpoint" \
    || bootstrap_die "当前 Docker context 指向远程或非系统 endpoint，拒绝用于本机 bind mount 部署" || return
}

bootstrap_dpkg_is_installed() {
  dpkg-query -W -f='${db:Status-Abbrev}\n' "$1" 2>/dev/null | grep -q '^ii '
}

bootstrap_check_docker_conflicts() {
  local package
  local -a conflicts=()
  for package in docker.io docker-compose docker-compose-v2 docker-doc podman-docker containerd runc; do
    bootstrap_dpkg_is_installed "$package" && conflicts+=("$package")
  done
  if (( ${#conflicts[@]} > 0 )); then
    bootstrap_die "检测到可能与 Docker 官方软件包冲突的现有组件（${conflicts[*]}）；为保护现有容器环境，安装器不会自动卸载或替换它们" || return
  fi
}

bootstrap_write_docker_apt_source() {
  local etc_root keyring_dir key_file source_dir source_file key_temp source_temp
  local repository_url status candidate

  etc_root=$(bootstrap_etc_root)
  keyring_dir="${etc_root}/apt/keyrings"
  key_file="${keyring_dir}/docker.asc"
  source_dir="${etc_root}/apt/sources.list.d"
  source_file="${source_dir}/docker.sources"
  repository_url="https://download.docker.com/linux/${BOOTSTRAP_PLATFORM_ID}"

  if install -m 0755 -d -- "$keyring_dir" "$source_dir"; then
    :
  else
    status=$?
    bootstrap_error "无法创建 Docker apt 配置目录（退出码 ${status}）"
    return "$status"
  fi
  # 兼容管理员按旧版官方文档配置的 .list 或自定义文件，避免重复追加同一软件源。
  for candidate in "${etc_root}/apt/sources.list" "${source_dir}"/*.list "${source_dir}"/*.sources; do
    [[ "$candidate" != "$source_file" && -f "$candidate" && ! -L "$candidate" ]] || continue
    if grep -Fq "$repository_url" "$candidate" \
      && grep -Eq "(^|[[:space:]/])${BOOTSTRAP_PLATFORM_CODENAME}([[:space:]/]|$)" "$candidate"; then
      if grep -Eiq '(signed-by=|^[[:space:]]*Signed-By:)' "$candidate"; then
        bootstrap_info "复用现有 Docker 官方 apt 软件源：${candidate}"
        return 0
      fi
      bootstrap_die "现有 Docker apt 软件源没有绑定签名密钥：${candidate}；为避免信任未约束的软件源，已停止" || return
    fi
  done

  if [[ -e "$key_file" || -L "$key_file" ]]; then
    [[ -f "$key_file" && ! -L "$key_file" ]] \
      || bootstrap_die "Docker apt 签名密钥路径不是安全普通文件：${key_file}" || return
    grep -Fq 'BEGIN PGP PUBLIC KEY BLOCK' "$key_file" \
      || bootstrap_die "现有 Docker apt 签名密钥格式无效；为避免覆盖未知系统配置，已停止" || return
  else
    key_temp=$(mktemp "${keyring_dir}/docker.asc.tmp.XXXXXX") || {
      status=$?
      bootstrap_error "无法创建 Docker apt 签名密钥临时文件（退出码 ${status}）"
      return "$status"
    }
    if curl --fail --silent --show-error --location \
      --proto '=https' --proto-redir '=https' --tlsv1.2 --connect-timeout 10 --max-time 60 \
      --retry 3 --retry-delay 2 --output "$key_temp" "${repository_url}/gpg"; then
      :
    else
      status=$?
      rm -f -- "$key_temp"
      bootstrap_error "下载 Docker 官方签名密钥失败（退出码 ${status}）"
      return "$status"
    fi
    grep -Fq 'BEGIN PGP PUBLIC KEY BLOCK' "$key_temp" || {
      rm -f -- "$key_temp"
      bootstrap_die "下载的 Docker 官方签名密钥格式无效" || return
    }
    chmod 0644 "$key_temp" || {
      status=$?
      rm -f -- "$key_temp"
      return "$status"
    }
    mv -- "$key_temp" "$key_file" || {
      status=$?
      rm -f -- "$key_temp"
      bootstrap_error "无法提交 Docker apt 签名密钥（退出码 ${status}）"
      return "$status"
    }
  fi

  if [[ -e "$source_file" || -L "$source_file" ]]; then
    [[ -f "$source_file" && ! -L "$source_file" ]] \
      || bootstrap_die "Docker apt 源路径不是安全普通文件：${source_file}" || return
    grep -Fqx "URIs: ${repository_url}" "$source_file" \
      && grep -Fqx "Suites: ${BOOTSTRAP_PLATFORM_CODENAME}" "$source_file" \
      && grep -Fqx "Architectures: ${BOOTSTRAP_PLATFORM_ARCH}" "$source_file" \
      && grep -Fqx "Signed-By: ${key_file}" "$source_file" \
      || bootstrap_die "现有 docker.sources 与当前系统不一致；为避免覆盖管理员配置，已停止" || return
  else
    source_temp=$(mktemp "${source_dir}/docker.sources.tmp.XXXXXX") || {
      status=$?
      bootstrap_error "无法创建 Docker apt source 临时文件（退出码 ${status}）"
      return "$status"
    }
    {
      printf 'Types: deb\n'
      printf 'URIs: %s\n' "$repository_url"
      printf 'Suites: %s\n' "$BOOTSTRAP_PLATFORM_CODENAME"
      printf 'Components: stable\n'
      printf 'Architectures: %s\n' "$BOOTSTRAP_PLATFORM_ARCH"
      printf 'Signed-By: %s\n' "$key_file"
    } > "$source_temp"
    chmod 0644 "$source_temp" || {
      status=$?
      rm -f -- "$source_temp"
      return "$status"
    }
    mv -- "$source_temp" "$source_file" || {
      status=$?
      rm -f -- "$source_temp"
      bootstrap_error "无法提交 Docker apt source（退出码 ${status}）"
      return "$status"
    }
  fi
}

bootstrap_install_compose_binary_fallback() {
  local version=v5.5.1 release_base asset usr_local target_dir target
  local temp_dir binary_file checksums_file expected actual status

  case "$BOOTSTRAP_PLATFORM_ARCH" in
    amd64) asset=docker-compose-linux-x86_64 ;;
    arm64) asset=docker-compose-linux-aarch64 ;;
    *) bootstrap_die "没有适用于 ${BOOTSTRAP_PLATFORM_ARCH} 的 Compose 后备二进制" || return ;;
  esac
  usr_local=$(bootstrap_usr_local_root)
  target_dir="${usr_local}/lib/docker/cli-plugins"
  target="${target_dir}/docker-compose"
  if [[ -e "$target" || -L "$target" ]]; then
    bootstrap_die "检测到未被当前安装器管理且不可用的 Compose 插件：${target}；为避免覆盖已停止" || return
  fi

  if [[ -e "$target_dir" || -L "$target_dir" ]]; then
    [[ -d "$target_dir" && ! -L "$target_dir" ]] \
      || bootstrap_die "Compose 插件目录不是安全普通目录：${target_dir}" || return
  else
    if install -m 0755 -d -- "$target_dir"; then
      :
    else
      status=$?
      bootstrap_error "无法创建 Compose 插件目录（退出码 ${status}）"
      return "$status"
    fi
  fi
  temp_dir=$(mktemp -d "${target_dir}/.compose-download.XXXXXX") || {
    status=$?
    bootstrap_error "无法创建 Compose 下载临时目录（退出码 ${status}）"
    return "$status"
  }
  binary_file="${temp_dir}/${asset}"
  checksums_file="${temp_dir}/checksums.txt"
  release_base="https://github.com/docker/compose/releases/download/${version}"
  if curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
    --proto-redir '=https' --connect-timeout 10 --max-time 180 --retry 3 --retry-delay 2 \
    --output "$binary_file" "${release_base}/${asset}" \
    && curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
      --proto-redir '=https' --connect-timeout 10 --max-time 60 --retry 3 --retry-delay 2 \
      --output "$checksums_file" "${release_base}/checksums.txt"; then
    :
  else
    status=$?
    rm -rf -- "$temp_dir"
    bootstrap_error "下载固定版本 Docker Compose ${version} 或其官方校验文件失败（退出码 ${status}）"
    return "$status"
  fi
  expected=$(awk -v asset="$asset" '$2 == asset || $2 == "*" asset {print $1; exit}' "$checksums_file") || {
    status=$?
    rm -rf -- "$temp_dir"
    return "$status"
  }
  actual=$(sha256sum "$binary_file" | awk '{print $1}') || {
    status=$?
    rm -rf -- "$temp_dir"
    return "$status"
  }
  if [[ ! "$expected" =~ ^[a-fA-F0-9]{64}$ || "$actual" != "$expected" ]]; then
    rm -rf -- "$temp_dir"
    bootstrap_die "Docker Compose ${version} 官方 SHA-256 校验失败，未安装二进制" || return
  fi
  chmod 0755 "$binary_file" || {
    status=$?
    rm -rf -- "$temp_dir"
    return "$status"
  }
  [[ ! -e "$target" && ! -L "$target" ]] || {
    rm -rf -- "$temp_dir"
    bootstrap_die "Compose 插件目标在下载期间被占用，拒绝覆盖：${target}" || return
  }
  mv -- "$binary_file" "$target" || {
    status=$?
    rm -rf -- "$temp_dir"
    bootstrap_error "无法原子提交 Compose 插件（退出码 ${status}）"
    return "$status"
  }
  rm -rf -- "$temp_dir"
  bootstrap_info "已安装并校验 Docker Compose ${version} 官方后备二进制"
}

bootstrap_install_docker_engine() {
  bootstrap_require_root || return $?
  bootstrap_check_docker_conflicts || return $?
  bootstrap_write_docker_apt_source || return $?
  bootstrap_apt_get "更新 Docker 官方软件包索引" update || return $?
  bootstrap_apt_get "安装 Docker Engine、CLI、containerd 与 Compose 插件" \
    install --yes --no-install-recommends \
    docker-ce docker-ce-cli containerd.io docker-compose-plugin || return $?
}

bootstrap_install_compose_plugin() {
  bootstrap_require_root || return $?
  if bootstrap_dpkg_is_installed docker-ce || bootstrap_dpkg_is_installed docker-ce-cli; then
    bootstrap_write_docker_apt_source || return $?
    bootstrap_apt_get "更新 Docker 官方软件包索引" update || return $?
    bootstrap_apt_get "补齐 Docker Compose 插件" install --yes --no-install-recommends docker-compose-plugin || return $?
    return 0
  fi

  # 保留发行版自带 Docker，不用 docker-ce-cli 替换它；优先安装同源 Compose 包。
  bootstrap_apt_get "更新系统软件包索引以查找兼容 Compose 插件" update || return $?
  if apt-cache show docker-compose-v2 >/dev/null 2>&1; then
    bootstrap_apt_get "为现有 Docker 补齐 Compose 插件" install --yes --no-install-recommends docker-compose-v2 || return $?
  elif [[ "$BOOTSTRAP_PLATFORM_ID" == debian && "$BOOTSTRAP_PLATFORM_VERSION" == 13 ]] \
    && apt-cache show docker-compose >/dev/null 2>&1; then
    # Debian 13 的 docker-compose 是 Go 实现的 v2 CLI plugin；Debian 12 同名包仍是 v1。
    bootstrap_apt_get "为 Debian 13 现有 Docker 补齐 Compose 插件" install --yes --no-install-recommends docker-compose || return $?
  else
    bootstrap_warn "发行版没有兼容的 Compose 插件包；保留现有 Docker，改用固定官方二进制后备方案"
    bootstrap_install_compose_binary_fallback || return $?
  fi
}

bootstrap_start_docker_daemon() {
  local ensure_enabled=${1:-0}
  local init_system=${CRISP_AI_BOOTSTRAP_INIT:-} status

  if docker info >/dev/null 2>&1 && [[ "$ensure_enabled" != 1 ]]; then
    return 0
  fi
  bootstrap_require_root || return $?
  if [[ -z "$init_system" ]] || ! bootstrap_is_test_mode; then
    if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
      init_system=systemd
    elif command -v service >/dev/null 2>&1 && [[ -x /etc/init.d/docker ]]; then
      init_system=sysv
    else
      init_system=unsupported
    fi
  fi

  case "$init_system" in
    systemd)
      bootstrap_info "正在启动 Docker daemon 并设置开机启动"
      systemctl enable --now docker || {
        status=$?
        bootstrap_error "启动 Docker systemd 服务失败（退出码 ${status}）"
        return "$status"
      }
      ;;
    sysv)
      bootstrap_info "正在通过系统服务启动 Docker daemon"
      service docker start || {
        status=$?
        bootstrap_error "启动 Docker SysV 服务失败（退出码 ${status}）"
        return "$status"
      }
      ;;
    *)
      bootstrap_die "Docker daemon 未运行，当前环境没有受支持的 systemd 或 Docker SysV 服务；未启动临时 dockerd" || return
      ;;
  esac
}

bootstrap_wait_for_docker() {
  local attempts=${CRISP_AI_BOOTSTRAP_DOCKER_ATTEMPTS:-30}
  local interval=${CRISP_AI_BOOTSTRAP_DOCKER_INTERVAL:-2}
  local attempt

  [[ "$attempts" =~ ^[1-9][0-9]{0,2}$ ]] || bootstrap_die "Docker 等待次数配置无效" || return
  [[ "$interval" =~ ^[0-9]{1,2}$ ]] || bootstrap_die "Docker 等待间隔配置无效" || return
  for (( attempt = 1; attempt <= attempts; attempt++ )); do
    docker info >/dev/null 2>&1 && return 0
    (( attempt == attempts )) || sleep "$interval"
  done
  bootstrap_die "等待 Docker daemon 就绪超时；请检查系统服务日志和内核/虚拟化权限" || return
}

bootstrap_version_at_least() {
  local actual=$1 required_major=$2 required_minor=$3
  local major minor

  [[ "$actual" =~ ^([0-9]+)\.([0-9]+)(\.[0-9]+)?([+~-].*)?$ ]] || return 1
  major=${BASH_REMATCH[1]}
  minor=${BASH_REMATCH[2]}
  (( 10#$major > required_major \
    || (10#$major == required_major && 10#$minor >= required_minor) ))
}

bootstrap_verify_docker_engine_capability() {
  local server_version server_arch normalized_arch

  server_version=$(docker version --format '{{.Server.Version}}' 2>/dev/null) \
    || bootstrap_die "无法读取 Docker Engine 服务端版本" || return
  bootstrap_version_at_least "$server_version" 20 10 \
    || bootstrap_die "Docker Engine ${server_version:-未知} 低于项目所需的 20.10（Compose 使用 host-gateway）；为保护现有容器，未自动升级现有 Engine" || return

  server_arch=$(docker info --format '{{.Architecture}}' 2>/dev/null) \
    || bootstrap_die "无法读取 Docker daemon 架构" || return
  case "$server_arch" in
    x86_64|amd64) normalized_arch=amd64 ;;
    aarch64|arm64) normalized_arch=arm64 ;;
    *) bootstrap_die "Docker daemon 返回未支持的架构：${server_arch:-未知}" || return ;;
  esac
  [[ "$normalized_arch" == "$BOOTSTRAP_PLATFORM_ARCH" ]] \
    || bootstrap_die "Docker daemon 架构 ${server_arch} 与宿主机 ${BOOTSTRAP_PLATFORM_ARCH} 不一致，拒绝部署 bind mount 服务" || return
}

bootstrap_verify_compose_capability() {
  local compose_help
  docker compose version >/dev/null 2>&1 \
    || bootstrap_die "Docker Compose 插件不可用" || return
  compose_help=$(docker compose --help 2>/dev/null) \
    || bootstrap_die "无法读取 Docker Compose 能力列表" || return
  [[ "$compose_help" == *--project-directory* && "$compose_help" == *--env-file* ]] \
    || bootstrap_die "Docker Compose 不支持部署所需的 --project-directory/--env-file 参数" || return
  docker compose config --help >/dev/null 2>&1 \
    || bootstrap_die "Docker Compose 缺少 config 能力" || return
  docker compose up --help >/dev/null 2>&1 \
    || bootstrap_die "Docker Compose 缺少 up 能力" || return
}

bootstrap_verify_docker_execution() {
  bootstrap_info "正在运行 Docker hello-world 容器验证 daemon 与镜像执行能力"
  docker run --rm hello-world >/dev/null \
    || bootstrap_die "Docker daemon 可访问，但测试容器运行失败；请检查镜像仓库网络、CPU 架构与内核能力" || return
}

bootstrap_prepare_docker_runtime() {
  local docker_installed=0
  bootstrap_detect_platform || return $?
  bootstrap_validate_local_docker_target || return $?
  if ! command -v docker >/dev/null 2>&1; then
    bootstrap_info "未检测到 Docker，将从 Docker 官方 apt 软件源自动安装"
    bootstrap_install_docker_engine || return $?
    docker_installed=1
  fi

  command -v docker >/dev/null 2>&1 \
    || bootstrap_die "Docker 安装完成后仍找不到 CLI" || return
  bootstrap_validate_local_docker_target || return $?
  if ! docker compose version >/dev/null 2>&1; then
    bootstrap_info "未检测到 Docker Compose 插件，将自动补齐"
    bootstrap_install_compose_plugin || return $?
  fi
  bootstrap_start_docker_daemon "$docker_installed" || return $?
  bootstrap_wait_for_docker || return $?
  bootstrap_verify_docker_engine_capability || return $?
  bootstrap_verify_compose_capability || return $?
  bootstrap_verify_docker_execution || return $?
  bootstrap_info "Docker Engine、daemon 与 Compose 已通过真实运行验证"
}

bootstrap_prepare_host() {
  bootstrap_prepare_minimal_dependencies || return $?
  bootstrap_prepare_docker_runtime || return $?
}

bootstrap_check_host() {
  local failed=0
  if bootstrap_detect_platform; then
    bootstrap_info "系统：${BOOTSTRAP_PLATFORM_ID} ${BOOTSTRAP_PLATFORM_VERSION}（ID_LIKE=${BOOTSTRAP_PLATFORM_ID_LIKE:-无}，${BOOTSTRAP_PLATFORM_CODENAME}/${BOOTSTRAP_PLATFORM_ARCH}）"
  else
    failed=1
  fi
  if bootstrap_verify_runtime_commands && bootstrap_verify_ca_bundle; then
    bootstrap_info "基础运行工具：就绪"
  else
    failed=1
  fi
  if command -v docker >/dev/null 2>&1; then
    bootstrap_validate_local_docker_target || failed=1
    if docker info >/dev/null 2>&1; then
      bootstrap_info "Docker daemon：就绪"
    else
      bootstrap_warn "Docker daemon：不可用"
      failed=1
    fi
    if bootstrap_verify_compose_capability; then
      bootstrap_info "Docker Compose：就绪"
    else
      failed=1
    fi
  else
    bootstrap_warn "Docker CLI：未安装"
    failed=1
  fi
  return "$failed"
}

bootstrap_usage() {
  printf '%s\n' '用法：scripts/bootstrap.sh [选项]'
  printf '%s\n' ''
  printf '%s\n' '选项：'
  printf '%s\n' '  --check     只读检查系统、基础工具、Docker daemon 与 Compose'
  printf '%s\n' '  --minimal   自动补齐安装向导和运行所需的基础工具'
  printf '%s\n' '  --docker    自动安装/复用 Docker，并启动 daemon 后运行容器验证'
  printf '%s\n' '  --all       依次执行 --minimal 与 --docker（默认）'
  printf '%s\n' '  --help      显示帮助；不检查 root，不安装依赖，不访问 Docker'
}

bootstrap_main() {
  local action=all
  (( $# <= 1 )) || bootstrap_die "bootstrap.sh 只接受一个选项" || return
  if (( $# == 1 )); then
    action=$1
  fi
  case "$action" in
    --help|-h) bootstrap_usage ;;
    --check) bootstrap_check_host ;;
    --minimal) bootstrap_prepare_minimal_dependencies ;;
    --docker) bootstrap_prepare_docker_runtime ;;
    --all|all) bootstrap_prepare_host ;;
    *) bootstrap_die "未知选项：${action}" || return ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  bootstrap_main "$@"
fi
