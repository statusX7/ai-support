#!/usr/bin/env bash
set -euo pipefail

launcher_owned_by_instance() {
  local launcher_path=$1 deploy_dir=$2 digest
  [[ -f "$launcher_path" && ! -L "$launcher_path" ]] || return 1
  digest=$(printf '%s' "$deploy_dir" | sha256sum | cut -d ' ' -f 1)
  grep -Fxq '# crispai-launcher: ai-support/v1' "$launcher_path" \
    && grep -Fxq "# crispai-target-sha256: $digest" "$launcher_path"
}

launcher_validate_path() {
  local launcher_path=$1 parent resolved
  [[ "$launcher_path" == /* && "$launcher_path" != *$'\n'* && "$launcher_path" != *$'\r'* ]] || return 1
  parent=$(dirname -- "$launcher_path")
  resolved=$(realpath -m -- "$parent")
  [[ "$resolved" == "$parent" && -d "$parent" && ! -L "$parent" ]] || return 1
  [[ ! -L "$launcher_path" && ! -d "$launcher_path" ]] || return 1
}

install_crispai_launcher() {
  local deploy_dir=$1 non_interactive=${2:-0}
  local launcher_path=${3:-} version digest temporary choice backup
  [[ $EUID -eq 0 ]] || { printf '错误：安装 crispai 命令需要 root 权限。\n' >&2; return 1; }
  [[ -f "$deploy_dir/manage.sh" && ! -L "$deploy_dir/manage.sh" \
    && -f "$deploy_dir/.crisp-ai-installation" && ! -L "$deploy_dir/.crisp-ai-installation" ]] || return 1
  [[ "$deploy_dir" == "$(realpath -e -- "$deploy_dir")" && "$deploy_dir" != *$'\n'* ]] || return 1
  if [[ -z "$launcher_path" && -f "$deploy_dir/config/.crispai-launcher" && ! -L "$deploy_dir/config/.crispai-launcher" ]]; then
    IFS= read -r launcher_path < "$deploy_dir/config/.crispai-launcher" || return 1
  fi
  launcher_path=${launcher_path:-/usr/local/bin/crispai}
  launcher_validate_path "$launcher_path" || { printf '错误：crispai 入口路径不安全。\n' >&2; return 1; }
  if [[ -e "$launcher_path" ]] && ! launcher_owned_by_instance "$launcher_path" "$deploy_dir"; then
    printf '警告：%s 已由其他程序或实例占用。\n' "$launcher_path" >&2
    (( non_interactive == 0 )) || return 1
    printf '1. 保留原命令并取消\n2. 备份原命令后安装 crispai\n0. 返回\n请选择：'
    IFS= read -r choice || return 2
    [[ "$choice" == 2 ]] || return 2
    backup="${launcher_path}.before-crispai-$(date -u '+%Y%m%dT%H%M%SZ')-$$"
    [[ ! -e "$backup" && ! -L "$backup" ]] || return 1
    mv -- "$launcher_path" "$backup"
    printf '原命令已保留，可恢复：%s\n' "$backup"
  fi
  version=$(<"$deploy_dir/VERSION")
  [[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  digest=$(printf '%s' "$deploy_dir" | sha256sum | cut -d ' ' -f 1)
  temporary=$(mktemp "$(dirname -- "$launcher_path")/.crispai-launcher.XXXXXX") || return 1
  # shellcheck disable=SC2016
  {
    printf '#!/usr/bin/env bash\nset -euo pipefail\n'
    printf '# crispai-launcher: ai-support/v1\n# crispai-target-sha256: %s\n' "$digest"
    printf 'CRISPAI_MANAGED_DIR=%q\nCRISPAI_LAUNCHER_PATH=%q\n' "$deploy_dir" "$launcher_path"
    printf 'case "${1:-}" in\n'
    printf '  --version) printf "%%s\\n" %q; exit 0 ;;\n' "$version"
    printf '  --help|-h) printf "%%s\\n" %q %q %q; exit 0 ;;\n' \
      '用法：crispai [status|init|doctor|enable|disable|uninstall|--help|--version]' \
      '无参数打开中文管理菜单；日常配置由受管实例自动应用。' \
      '管理操作需要 root，普通用户将通过 sudo 受控提权。'
    printf 'esac\n'
    printf 'if (( EUID != 0 )); then\n'
    printf '  if command -v sudo >/dev/null 2>&1; then\n'
    printf '    printf "管理 CrispAI 需要管理员权限，正在调用 sudo。\\n" >&2\n'
    printf '    exec sudo -- "$CRISPAI_LAUNCHER_PATH" "$@"\n'
    printf '  fi\n'
    printf '  printf "错误：管理操作需要 root 或 sudo 权限。\\n" >&2; exit 1\nfi\n'
    printf '[[ -f "$CRISPAI_MANAGED_DIR/manage.sh" && ! -L "$CRISPAI_MANAGED_DIR/manage.sh" ]] || { printf "错误：受管实例程序缺失，请从完整发布包恢复安装。\\n" >&2; exit 1; }\n'
    printf 'exec bash "$CRISPAI_MANAGED_DIR/manage.sh" --deploy-dir "$CRISPAI_MANAGED_DIR" "$@"\n'
  } > "$temporary"
  chmod 0755 "$temporary"
  bash -n "$temporary" || { rm -f -- "$temporary"; return 1; }
  mv -f -- "$temporary" "$launcher_path"
  temporary=$(mktemp "$deploy_dir/config/.launcher.XXXXXX") || return 1
  printf '%s\n' "$launcher_path" > "$temporary"
  chmod 0600 "$temporary"
  mv -f -- "$temporary" "$deploy_dir/config/.crispai-launcher"
  printf 'crispai 管理命令已安装：%s\n' "$launcher_path"
}

remove_crispai_launcher() {
  local deploy_dir=$1 launcher_path=/usr/local/bin/crispai record
  record="$deploy_dir/config/.crispai-launcher"
  if [[ -f "$record" && ! -L "$record" ]]; then
    IFS= read -r launcher_path < "$record" || return 1
  fi
  launcher_validate_path "$launcher_path" || { printf '警告：crispai 入口路径无法验证，保留原文件。\n' >&2; return 0; }
  if launcher_owned_by_instance "$launcher_path" "$deploy_dir"; then
    rm -f -- "$launcher_path"
    printf '已移除本实例管理入口：%s（重装会重新创建）\n' "$launcher_path"
  elif [[ -e "$launcher_path" || -L "$launcher_path" ]]; then
    printf '保留非本实例的同名命令：%s\n' "$launcher_path"
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  action=${1:-help}
  (( $# == 0 )) || shift
  launcher_deploy="" launcher_command="" launcher_non_interactive=0
  while (( $# > 0 )); do
    case "$1" in
      --deploy-dir) (( $# >= 2 )) || exit 1; launcher_deploy=$2; shift 2 ;;
      --command-path) (( $# >= 2 )) || exit 1; launcher_command=$2; shift 2 ;;
      --non-interactive) launcher_non_interactive=1; shift ;;
      *) printf '错误：未知参数。\n' >&2; exit 1 ;;
    esac
  done
  case "$action" in
    install) install_crispai_launcher "$launcher_deploy" "$launcher_non_interactive" "$launcher_command" ;;
    remove) remove_crispai_launcher "$launcher_deploy" ;;
    --help|help) printf '用法：launcher.sh install|remove --deploy-dir PATH [--non-interactive] [--command-path PATH]\n' ;;
    *) exit 1 ;;
  esac
fi
