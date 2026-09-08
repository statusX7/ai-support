#!/usr/bin/env bash
set -euo pipefail

PROVIDER_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/configuration.sh
source "${PROVIDER_SCRIPT_DIR}/configuration.sh"

provider_pool_init() {
  local deploy_dir=$1
  python3 "${PROVIDER_SCRIPT_DIR}/provider-pool.py" --deploy-dir "$deploy_dir" migrate
}

provider_main() {
  local deploy_request='' deploy_dir action
  while (( $# )); do
    case "$1" in
      --deploy-dir) deploy_request=${2:?}; shift 2 ;;
      --json) shift ;;
      --help|-h)
        printf '%s\n' '用法：provider.sh [--deploy-dir PATH] [--json] 操作' \
          '只读：list | get | entry ID | status | recent | policy' \
          '配置：add FILE | edit ID FILE | apply FILE | primary ID | enable ID true|false | delete ID | order FILE | policy FILE' \
          '验证：models [ID|new] [FILE] | probe [ID|new] [FILE] | test [ID] | vision-test [ID]' \
          '迁移：migrate（幂等迁移原单接口，不调用上游）' \
          '完整池：validate-file FILE | apply-file FILE | import FILE；管理员测试签名：admin-marker [MILLISECONDS]' \
          '导入草稿：draft | draft-entry ID | edit-draft ID FILE | apply-draft' \
          '候选文件：{provider:{name,base_url,model,api_mode,custom_headers,remove_header,capabilities,context_window,max_output_tokens},api_key}。空 Key 保留；新增必须填写。' \
          '输出为一份 JSON；普通交互由管理菜单提供中文呈现。'
        return ;;
      *) break ;;
    esac
  done
  action=${1:-list}
  if (( $# )); then shift; fi
  deploy_dir=$(resolve_deploy_dir "$deploy_request")
  assert_managed_installation "$deploy_dir"
  python3 "${PROVIDER_SCRIPT_DIR}/provider-pool.py" --deploy-dir "$deploy_dir" "$action" "$@"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then provider_main "$@"; fi
