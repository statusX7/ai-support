#!/usr/bin/env bash
set -euo pipefail

MENU_TITLES=(
  '快速初始化' '状态与自检' '第三方 AI 接口' '客服提示词' '多知识库管理' '关键词与按钮'
  '人工接管与恢复' '客服总开关' '欢迎语与多级菜单' 'Crisp 接入设置' '命中率与回答反馈'
  '配置导入导出' '备份与恢复' '更新与回滚' '日志与故障排查' '服务与依赖维护'
  '部署及操作说明' '卸载系统'
)
MENU_ICONS=('🚀' '🩺' '🤖' '📝' '📚' '🔑' '👤' '🎛️' '👋' '🔗' '📈' '📦' '💾' '🔄' '📜' '🧰' '📖' '🗑️')

menu_utf8_enabled() {
  local encoding=${LC_ALL:-${LC_CTYPE:-${LANG:-C}}}
  [[ "${encoding,,}" == *utf-8* || "${encoding,,}" == *utf8* ]]
}

menu_display_width() {
  local value=$1 character code index width=0
  local ansi=$'\e''\[[0-9;]*[a-zA-Z]'
  while [[ "$value" =~ $ansi ]]; do value=${value/"${BASH_REMATCH[0]}"/}; done
  for (( index=0; index<${#value}; index++ )); do
    character=${value:index:1}
    printf -v code '%d' "'$character"
    if (( code < 32 || (code >= 127 && code < 160) \
      || (code >= 768 && code <= 879) || code == 8205 \
      || (code >= 65024 && code <= 65039) )); then
      continue
    elif (( (code >= 4352 && code <= 4607) || (code >= 9001 && code <= 9002) \
      || (code >= 11904 && code <= 42191) || (code >= 44032 && code <= 55203) \
      || (code >= 63744 && code <= 64255) || (code >= 65040 && code <= 65049) \
      || (code >= 65072 && code <= 65135) || (code >= 65281 && code <= 65376) \
      || (code >= 65504 && code <= 65510) || (code >= 9728 && code <= 10175) \
      || (code >= 126976 && code <= 129791) || code >= 131072 )); then
      (( width+=2 ))
    else
      (( width+=1 ))
    fi
  done
  printf '%s' "$width"
}

menu_fit_text() {
  local value=$1 limit=$2 character result='' used=0 width index
  for (( index=0; index<${#value}; index++ )); do
    character=${value:index:1}
    width=$(menu_display_width "$character")
    (( used+width <= limit )) || break
    result+=$character
    (( used+=width )) || true
  done
  printf '%s' "$result"
  (( used >= limit )) || printf '%*s' "$((limit-used))" ''
}

menu_cached_diagnostic() {
  local cache="${1}/logs/doctor-last.json" summary
  if [[ -f "$cache" && ! -L "$cache" ]] && command -v jq >/dev/null 2>&1; then
    summary=$(jq -M -er 'select(.schema_version == 1) |
      select(.checked_at | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) |
      select(.summary.fail | type == "number" and . >= 0) |
      select(.summary.warn | type == "number" and . >= 0) |
      "上次自检（缓存）：\(.checked_at)；失败 \(.summary.fail)，警告 \(.summary.warn)"' "$cache" 2>/dev/null || true)
    if [[ -n "$summary" ]]; then printf '%s\n' "$summary"; return; fi
  fi
  printf '上次自检：未检测（菜单 2）\n'
}

menu_render() {
  local version=$1 deploy_dir=$2 enabled=$3 crisp=$4 libraries=$5
  local columns=${COLUMNS:-0} index title left right column_width
  if [[ ! "$columns" =~ ^[1-9][0-9]{1,3}$ ]]; then
    columns=80
    if [[ -t 1 ]] && command -v stty >/dev/null 2>&1; then
      read -r _ columns < <(stty size 2>/dev/null) || columns=80
    fi
  fi
  [[ "$columns" =~ ^[1-9][0-9]{1,3}$ ]] || columns=80
  printf '\nCrispAI %s\n自动客服：%s    Crisp：%s    知识库：%s\n' "$version" "$enabled" "$crisp" "$libraries"
  printf '部署目录：%s\n' "$deploy_dir"
  menu_cached_diagnostic "$deploy_dir"
  printf '\n'
  if [[ "${TERM:-dumb}" != dumb && -t 1 && "$columns" -ge 80 ]] && menu_utf8_enabled; then
    column_width=$(( (columns-4)/2 )); (( column_width <= 48 )) || column_width=48
    for (( index=0; index<${#MENU_TITLES[@]}; index+=2 )); do
      printf -v left '%2d. %s' "$((index+1))" "${MENU_TITLES[index]}"
      printf -v right '%2d. %s' "$((index+2))" "${MENU_TITLES[index+1]}"
      if [[ "${CRISPAI_NO_EMOJI:-0}" != 1 ]]; then
        printf -v left '%2d. %s %s' "$((index+1))" "${MENU_ICONS[index]}" "${MENU_TITLES[index]}"
        printf -v right '%2d. %s %s' "$((index+2))" "${MENU_ICONS[index+1]}" "${MENU_TITLES[index+1]}"
      fi
      menu_fit_text "$left" "$column_width"
      printf '  %s\n' "$right"
    done
  else
    for index in "${!MENU_TITLES[@]}"; do
      title=${MENU_TITLES[index]}
      if [[ "${CRISPAI_NO_EMOJI:-0}" != 1 && "${TERM:-dumb}" != dumb && -t 1 ]] && menu_utf8_enabled; then
        title="${MENU_ICONS[index]} $title"
      fi
      printf '%d. %s\n' "$((index+1))" "$title"
    done
  fi
  printf '0. 退出\n\n请选择：'
}
