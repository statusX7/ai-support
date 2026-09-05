#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
MANAGE_SCRIPT="${PROJECT_ROOT}/manage.sh"

fail() {
  printf '管理菜单契约失败：%s\n' "$1" >&2
  exit 1
}

[[ -f "$MANAGE_SCRIPT" && ! -L "$MANAGE_SCRIPT" ]] || fail "manage.sh 缺失或不是普通文件"

MENU_OUTPUT=$(printf '0\n' | "$MANAGE_SCRIPT" --deploy-dir "$PROJECT_ROOT")
EXPECTED_MENU=(
  '1. 查看状态'
  '2. 修改AI配置'
  '3. 修改Prompt'
  '4. 管理知识库'
  '5. 查看统计'
  '6. 查看日志'
  '7. 备份'
  '8. 恢复'
  '9. 更新'
  '10. 回滚'
  '11. 卸载系统'
  '0. 退出'
)
for menu_line in "${EXPECTED_MENU[@]}"; do
  grep -Fxq "$menu_line" <<< "$MENU_OUTPUT" || fail "主菜单缺少或错序项：${menu_line}"
done
MENU_NUMBERS=$(grep -E '^(0|[1-9][0-9]*)\. ' <<< "$MENU_OUTPUT" | sed 's/\..*$//' | paste -sd, -)
[[ "$MENU_NUMBERS" == '1,2,3,4,5,6,7,8,9,10,11,0' ]] \
  || fail "主菜单必须严格按 1..11、0 排列，实际为：${MENU_NUMBERS:-空}"

MAIN_CASE=$(awk '
  /^[[:space:]]*case "\$CHOICE" in[[:space:]]*$/ { capture = 1; next }
  capture && /^  esac[[:space:]]*$/ { exit }
  capture { print }
' "$MANAGE_SCRIPT")
[[ -n "$MAIN_CASE" ]] || fail "无法定位主菜单 case 映射"

branch_code() {
  local number=$1
  awk -v wanted="$number" '
    $0 ~ "^    " wanted "\\)[[:space:]]*$" { capture = 1; next }
    capture && $0 ~ "^    ([0-9]+|0|\\*)\\)" { exit }
    capture { print }
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

assert_mapping 1 'status_menu' '状态子菜单'
assert_mapping 2 'ai_config_menu' 'AI 配置'
assert_mapping 3 'prompt_menu' 'Prompt 管理'
assert_mapping 4 'knowledge_menu' '知识库管理'
assert_mapping 5 'statistics_menu' '统计子菜单'
assert_mapping 6 'logs --tail 200' '日志查看'
assert_mapping 7 'run_backup' '备份'
assert_mapping 8 'run_restore' '恢复'
assert_mapping 9 'update.sh' '更新'
assert_mapping 10 'run_rollback' '版本回滚'
assert_mapping 11 'uninstall_menu' '卸载子菜单'

UNINSTALL_MENU=$(awk '
  /^uninstall_menu\(\)[[:space:]]*\{/ { capture = 1 }
  capture { print }
  capture && /^\}[[:space:]]*$/ { exit }
' "$MANAGE_SCRIPT")
[[ "$UNINSTALL_MENU" == *'安全卸载'* ]] || fail "卸载子菜单缺少安全卸载"
[[ "$UNINSTALL_MENU" == *'完整清理'* ]] || fail "卸载子菜单缺少完整清理"
[[ "$UNINSTALL_MENU" == *'--purge'* ]] || fail "完整清理未映射到 --purge"

printf '管理菜单 1..11 映射契约：通过\n'
