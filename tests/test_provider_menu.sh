#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
TEST_ROOT=$(mktemp -d "${PROJECT_ROOT}/.work/provider-menu-contract.XXXXXX")
trap 'rm -rf -- "$TEST_ROOT"' EXIT

# shellcheck source=scripts/menu-provider-ui.sh
source "${PROJECT_ROOT}/scripts/menu-provider-ui.sh"

fail() { printf '失败：%s\n' "$*" >&2; exit 1; }
pass() { printf '通过 UNIT/MENU：%s\n' "$*"; }

declare -A EXPECTED=(
  [authentication_failed]='鉴权'
  [model_unavailable]='模型'
  [protocol_error]='协议'
  [invalid_response]='响应'
  [rate_limited]='频率'
  [quota_exhausted]='额度'
  [upstream_timeout]='超时'
  [upstream_unavailable]='服务端'
  [connection_failed]='连接'
)

for code in "${!EXPECTED[@]}"; do
  output=$(provider_error_message "$code") || fail "$code 没有中文解释"
  [[ "$output" == *"${EXPECTED[$code]}"* ]] || fail "$code 未显示对应原因：$output"
  [[ ! "$output" =~ (Bearer|Authorization|https?://|Key=|token=) ]] || fail "$code 的固定说明包含认证或地址内容"
done
[[ $(provider_error_message 'Bearer synthetic-secret https://upstream.invalid/?token=synthetic') == *'未能分类'* ]] \
  || fail '未知上游分类没有收敛为安全中文说明'
pass '九类安全错误码均有独立中文说明，未知错误不回显原值'

generic_404=$(provider_error_message protocol_error)
[[ "$generic_404" == *'请求协议不匹配'* && "$generic_404" == *'Base URL 路径'* ]] \
  || fail '普通 404 的协议/端点故障没有中文核对路径'
pass '普通 404 的结构化协议故障具有中文地址与协议诊断'

counter=0
CURRENT_CODE=''
CURRENT_STATUS=1
manager_temporary() {
  counter=$((counter + 1))
  MANAGE_FILE="${TEST_ROOT}/result-${counter}.json"
  : > "$MANAGE_FILE"
}
manager_tool() {
  printf '{"ok":false,"error":{"code":"%s","message":"Bearer synthetic-menu-secret https://upstream.invalid/?token=synthetic"}}\n' "$CURRENT_CODE"
  return "$CURRENT_STATUS"
}
menu_read() {
  printf -v "$1" '%s' 0
}
warn() { printf '提示：%s\n' "$*"; }

candidate="${TEST_ROOT}/candidate.json"
printf '%s\n' '{"provider":{"model":"fixture-model"}}' > "$candidate"
for value in \
  'authentication_failed:3:鉴权' \
  'model_unavailable:1:模型' \
  'protocol_error:1:协议' \
  'invalid_response:1:响应' \
  'rate_limited:4:频率' \
  'quota_exhausted:4:额度' \
  'upstream_timeout:4:超时' \
  'upstream_unavailable:4:服务端' \
  'connection_failed:4:连接'; do
  IFS=: read -r CURRENT_CODE CURRENT_STATUS expected <<< "$value"
  status=0
  output=$(provider_model_select "$candidate" p_000000000000000000000000) || status=$?
  (( status != 0 )) || fail "$CURRENT_CODE 的失败被当作模型列表成功"
  [[ "$output" == *"$expected"* ]] || fail "$CURRENT_CODE 没有在模型选择流程显示具体中文原因：$output"
  [[ ! "$output" =~ (synthetic-menu-secret|upstream\.invalid|Bearer|token=|\{"ok") ]] \
    || fail "$CURRENT_CODE 的模型选择流程泄漏上游响应"
done
pass '模型选择按错误码解释失败，未输出原始 JSON、URL、Header 或密钥'

# 管理员查询先经过 configuration_query_failure，再由 doctor 映射；两层都必须
# 保留 adapter 的白名单 protocol_error，不能二次降为 admin_query_failed。
# shellcheck source=scripts/configuration.sh
source "${PROJECT_ROOT}/scripts/configuration.sh"
status=0
output=$(CRISPAI_DIAGNOSTIC_JSON=1 configuration_query_failure protocol_error 1) || status=$?
(( status == 1 )) || fail 'configuration protocol_error 返回码错误'
jq -e '.verified == false and .error.code == "protocol_error"' <<< "$output" >/dev/null \
  || fail 'configuration 将 protocol_error 降级成其他错误码'
status=0
output=$(configuration_query_failure protocol_error 1 2>&1) || status=$?
(( status == 1 )) || fail 'configuration 中文 protocol_error 返回码错误'
[[ "$output" == *'协议、地址路径或请求格式不兼容'* \
  && "$output" == *'Chat Completions / Responses'* ]] \
  || fail 'configuration protocol_error 缺少协议/路径/请求格式中文分类'

doctor_definition=$(sed -n '/^doctor_provider_inference_failure() {/,/^}/p' \
  "${PROJECT_ROOT}/scripts/doctor.sh")
[[ -n "$doctor_definition" ]] || fail '无法取得 doctor Provider 诊断映射'
eval "$doctor_definition"
doctor_provider_inference_failure protocol_error
[[ "$DOCTOR_PROVIDER_FAILURE_SUMMARY" == '接口协议、地址路径或请求格式不兼容' \
  && "$DOCTOR_PROVIDER_FAILURE_SUGGESTION" == *'Chat Completions / Responses'* ]] \
  || fail 'doctor protocol_error 未显示独立中文分类'
pass 'configuration 与 doctor 全链保留 protocol_error，并显示协议、地址路径和请求格式说明'
