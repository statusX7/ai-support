#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
DOCTOR="${SCRIPT_DIR}/doctor.sh"
DEPLOY_REQUEST=''
SCOPE=default
INSTALLATION_IN_PROGRESS=0
JSON=0

usage() {
  cat <<'EOF'
用法：healthcheck.sh [--deploy-dir PATH] [--offline|--local|--application|--full] [--json]

这是统一组件自检 doctor.sh 的兼容入口：
--offline      只检查文件、权限和配置，不访问 Docker 或外部服务。
--local        检查本地组件与实际接线，不访问外部服务，不执行模型推理。
--application  与 --local 相同，供安装、更新和回滚健康门禁使用；不产生模型费用。
--full         额外检查已配置外部连接并执行一次受控模型调用，可能产生少量费用。
--installation-in-progress  仅供安装或更新期间检查尚未提交的完整暂存代。

兼容门禁将“仅有警告/外部待接入”（doctor 退出 2）视为本地检查成功；
明确组件故障仍退出 1。新管理入口请直接使用 crispai doctor。
EOF
}

parameter_error() {
  printf '错误：%s\n' "$*" >&2
  usage >&2
  exit 64
}

set_scope() {
  local requested=$1
  [[ "$SCOPE" == default ]] || parameter_error '检查范围只能选择一个'
  SCOPE=$requested
}

while (( $# > 0 )); do
  case "$1" in
    --deploy-dir)
      (( $# >= 2 )) || parameter_error '--deploy-dir 缺少参数'
      DEPLOY_REQUEST=$2
      shift 2
      ;;
    --offline) set_scope offline; shift ;;
    --local|--application) set_scope local; shift ;;
    --full) set_scope full; shift ;;
    --installation-in-progress) INSTALLATION_IN_PROGRESS=1; shift ;;
    --json) JSON=1; shift ;;
    --help|-h) usage; exit 0 ;;
    --version)
      if [[ -f "${SCRIPT_DIR}/../VERSION" && ! -L "${SCRIPT_DIR}/../VERSION" ]]; then
        sed -n '1p' "${SCRIPT_DIR}/../VERSION"
      else
        printf '%s\n' unknown
      fi
      exit 0
      ;;
    *) parameter_error "未知选项：$1" ;;
  esac
done

if [[ ! -f "$DOCTOR" || -L "$DOCTOR" ]]; then
  printf '失败：统一自检模块缺失或不是安全的普通文件：%s\n' "$DOCTOR" >&2
  exit 1
fi

arguments=(--deploy-dir "$DEPLOY_REQUEST")
case "$SCOPE" in
  offline) arguments+=(--offline) ;;
  local) arguments+=(--local) ;;
  full) arguments+=(--full) ;;
  default) ;;
esac
(( INSTALLATION_IN_PROGRESS == 0 )) || arguments+=(--installation-in-progress)
(( JSON == 0 )) || arguments+=(--json)

status=0
bash "$DOCTOR" "${arguments[@]}" || status=$?
case "$status" in
  0) exit 0 ;;
  2)
    printf '兼容健康门禁：仅有警告或外部待接入，本地检查继续。\n' >&2
    exit 0
    ;;
  1|64|130) exit "$status" ;;
  *)
    printf '失败：统一自检返回未知退出码 %s。\n' "$status" >&2
    exit 1
    ;;
esac
