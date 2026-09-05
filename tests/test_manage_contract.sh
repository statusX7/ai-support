#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
MANAGE_SCRIPT="${PROJECT_ROOT}/manage.sh"
TEST_ROOT=$(mktemp -d "${PROJECT_ROOT}/.test-runtime.manage-contract.XXXXXX")

cleanup() {
  if [[ "$TEST_ROOT" == "${PROJECT_ROOT}"/.test-runtime.manage-contract.* && -d "$TEST_ROOT" ]]; then
    rm -rf -- "$TEST_ROOT"
  fi
}
trap cleanup EXIT

fail() {
  printf '管理菜单契约失败：%s\n' "$1" >&2
  exit 1
}

[[ -f "$MANAGE_SCRIPT" && ! -L "$MANAGE_SCRIPT" ]] || fail "manage.sh 缺失或不是普通文件"

MENU_OUTPUT=$(printf '0\n' | "$MANAGE_SCRIPT" --deploy-dir "$PROJECT_ROOT")
EXPECTED_MENU=(
  '1. 快速初始化 / 继续未完成安装'
  '2. 查看运行与接入状态'
  '3. AI 接口和模型设置'
  '4. 客服提示词与知识库'
  '5. 关键词、欢迎菜单及人工接管设置'
  '6. 标签、统计与反馈'
  '7. 日志、环境检查与依赖修复'
  '8. 备份与恢复'
  '9. 更新与回滚'
  '10. 卸载系统'
  '0. 退出'
)
for menu_line in "${EXPECTED_MENU[@]}"; do
  grep -Fxq "$menu_line" <<< "$MENU_OUTPUT" || fail "主菜单缺少或错序项：${menu_line}"
done
MENU_NUMBERS=$(grep -E '^(0|[1-9][0-9]*)\. ' <<< "$MENU_OUTPUT" | sed 's/\..*$//' | paste -sd, -)
[[ "$MENU_NUMBERS" == '1,2,3,4,5,6,7,8,9,10,0' ]] \
  || fail "主菜单必须严格按 1..10、0 排列，实际为：${MENU_NUMBERS:-空}"

MAIN_CASE=$(awk '
  /^[[:space:]]*case "\$CHOICE" in[[:space:]]*$/ { capture = 1; next }
  capture && /^  esac[[:space:]]*$/ { exit }
  capture { print }
' "$MANAGE_SCRIPT")
[[ -n "$MAIN_CASE" ]] || fail "无法定位主菜单 case 映射"

branch_code() {
  local number=$1
  awk -v wanted="$number" '
    $0 ~ "^[[:space:]]*" wanted "\\)" {
      capture = 1
      line = $0
      sub("^[[:space:]]*" wanted "\\)[[:space:]]*", "", line)
      print line
      if (line ~ /;;[[:space:]]*$/) exit
      next
    }
    capture && $0 ~ "^[[:space:]]*([0-9]+|0|\\*)\\)" { exit }
    capture {
      print
      if ($0 ~ /;;[[:space:]]*$/) exit
    }
  ' <<< "$MAIN_CASE"
}

assert_mapping() {
  local number=$1
  local token=$2
  local description=$3
  local code
  code=$(branch_code "$number")
  [[ -n "$code" && "$code" == *"$token"* ]] \
    || fail "菜单 ${number} 未映射到${description}"
}

assert_mapping 1 'quick_initialization' '快速初始化'
assert_mapping 2 'status_menu' '运行与接入状态'
assert_mapping 3 'ai_config_menu' 'AI 接口和模型设置'
assert_mapping 4 'prompt_knowledge_menu' 'Prompt 与知识库'
assert_mapping 5 'rules_menu' '关键词、欢迎菜单与人工接管'
assert_mapping 6 'analysis_menu' '标签、统计与反馈'
assert_mapping 7 'diagnostics_menu' '日志、环境检查与依赖修复'
assert_mapping 8 'backup_restore_menu' '备份与恢复'
assert_mapping 9 'update_rollback_menu' '更新与回滚'
assert_mapping 10 'uninstall_menu' '卸载子菜单'

for menu_number in 2 3 4 5 6 7 8 9 10; do
  [[ "$(branch_code "$menu_number")" == *'require_installation'* ]] \
    || fail "未安装状态选择菜单 ${menu_number} 时没有统一安装边界"
done

function_body() {
  local function_name=$1
  awk -v wanted="$function_name" '
    $0 ~ "^" wanted "\\(\\)[[:space:]]*\\{" { capture = 1 }
    capture { print }
    capture && /^}[[:space:]]*$/ { exit }
  ' "$MANAGE_SCRIPT"
}

QUICK_INIT=$(function_body quick_initialization)
# shellcheck disable=SC2016 # 断言生产脚本使用自身 SCRIPT_DIR，而不是展开测试脚本变量。
[[ "$QUICK_INIT" == *'${SCRIPT_DIR}/install.sh'* ]] \
  || fail "快速初始化未调用 manage.sh 同目录的 install.sh"
[[ "$QUICK_INIT" == *'--reconfigure'* ]] \
  || fail "已安装状态不能从快速初始化入口安全重新配置"

PROMPT_KNOWLEDGE_MENU=$(function_body prompt_knowledge_menu)
[[ "$PROMPT_KNOWLEDGE_MENU" == *'prompt_menu'* && "$PROMPT_KNOWLEDGE_MENU" == *'knowledge_menu'* ]] \
  || fail "Prompt 与知识库子菜单映射不完整"

RULES_MENU=$(function_body rules_menu)
for expected in configure_crisp configure_webhook_menu keyword.yaml menu.yaml handoff.yaml; do
  [[ "$RULES_MENU" == *"$expected"* ]] || fail "客服规则子菜单缺少：$expected"
done

ANALYSIS_MENU=$(function_body analysis_menu)
for expected in statistics_menu tags.yaml feedback.yaml; do
  [[ "$ANALYSIS_MENU" == *"$expected"* ]] || fail "标签统计反馈子菜单缺少：$expected"
done

DIAGNOSTICS_MENU=$(function_body diagnostics_menu)
for expected in 'logs --tail 200' 'healthcheck.sh' 'bootstrap.sh" --check' 'bootstrap.sh" --all'; do
  [[ "$DIAGNOSTICS_MENU" == *"$expected"* ]] || fail "诊断子菜单缺少：$expected"
done

BACKUP_RESTORE_MENU=$(function_body backup_restore_menu)
[[ "$BACKUP_RESTORE_MENU" == *'run_backup'* && "$BACKUP_RESTORE_MENU" == *'run_restore'* ]] \
  || fail "备份恢复子菜单映射不完整"

UPDATE_ROLLBACK_MENU=$(function_body update_rollback_menu)
for expected in update.sh run_rollback '--list'; do
  [[ "$UPDATE_ROLLBACK_MENU" == *"$expected"* ]] || fail "更新回滚子菜单缺少：$expected"
done

UNINSTALL_MENU=$(awk '
  /^uninstall_menu\(\)[[:space:]]*\{/ { capture = 1 }
  capture { print }
  capture && /^\}[[:space:]]*$/ { exit }
' "$MANAGE_SCRIPT")
[[ "$UNINSTALL_MENU" == *'安全卸载'* ]] || fail "卸载子菜单缺少安全卸载"
[[ "$UNINSTALL_MENU" == *'完整清理'* ]] || fail "卸载子菜单缺少完整清理"
[[ "$UNINSTALL_MENU" == *'--purge'* ]] || fail "完整清理未映射到 --purge"
[[ "$UNINSTALL_MENU" == *'--numeric-confirm'* ]] \
  || fail "管理菜单完整清理未使用两次数字确认"

HOST_FIXTURE="${TEST_ROOT}/host-fixture"
mkdir -p -- "${HOST_FIXTURE}/etc/ssl/certs"
printf '%s\n' 'ID=debian' 'VERSION_ID="12"' 'VERSION_CODENAME=bookworm' \
  > "${HOST_FIXTURE}/os-release"
printf '%s\n' 'agent-c-test-ca-bundle' > "${HOST_FIXTURE}/etc/ssl/certs/ca-certificates.crt"

UNINSTALLED_DEPLOY="${TEST_ROOT}/uninstalled"
set +e
printf '2\n' | timeout 30 env \
  CRISP_AI_BOOTSTRAP_TEST_MODE=1 \
  CRISP_AI_BOOTSTRAP_OS_RELEASE="${HOST_FIXTURE}/os-release" \
  CRISP_AI_BOOTSTRAP_ETC_ROOT="${HOST_FIXTURE}/etc" \
  "$MANAGE_SCRIPT" --deploy-dir "$UNINSTALLED_DEPLOY" \
  > "${TEST_ROOT}/uninstalled-option.log" 2>&1
UNINSTALLED_STATUS=$?
set -e
(( UNINSTALLED_STATUS != 0 && UNINSTALLED_STATUS != 124 )) \
  || fail "未安装状态选择菜单 2 未明确且有限地拒绝"
grep -Fq '目录不是受管理的 ai-support 部署' "${TEST_ROOT}/uninstalled-option.log" \
  || fail "未安装状态选择非初始化菜单时缺少明确提示"
[[ ! -e "${UNINSTALLED_DEPLOY}/.crisp-ai-installation" ]] \
  || fail "未安装状态选择菜单 2 时错误创建安装标记"

INITIALIZE_DEPLOY="${TEST_ROOT}/initialize"
set +e
printf '1\n' | timeout 30 env \
  CRISP_AI_BOOTSTRAP_TEST_MODE=1 \
  CRISP_AI_BOOTSTRAP_OS_RELEASE="${HOST_FIXTURE}/os-release" \
  CRISP_AI_BOOTSTRAP_ETC_ROOT="${HOST_FIXTURE}/etc" \
  "$MANAGE_SCRIPT" --deploy-dir "$INITIALIZE_DEPLOY" \
  > "${TEST_ROOT}/initialize-eof.log" 2>&1
INITIALIZE_STATUS=$?
set -e
(( INITIALIZE_STATUS != 0 && INITIALIZE_STATUS != 124 )) \
  || fail "快速初始化入口遇到 EOF 后未安全取消"
grep -Eq '快速初始化|AI API 地址|输入已结束' "${TEST_ROOT}/initialize-eof.log" \
  || fail "菜单 1 未进入生产快速初始化"
grep -Fxq 'state=collecting' "${INITIALIZE_DEPLOY}/.crisp-ai-installation" \
  || fail "菜单 1 遇到 EOF 后未保留 collecting 状态"

printf '管理菜单 1..10、子菜单及未安装边界契约：通过\n'
