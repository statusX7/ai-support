#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/bootstrap.sh
source "${SCRIPT_DIR}/scripts/bootstrap.sh"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/scripts/common.sh"
# shellcheck source=scripts/wizard.sh
source "${SCRIPT_DIR}/scripts/wizard.sh"
# shellcheck source=scripts/menu-ui.sh
source "${SCRIPT_DIR}/scripts/menu-ui.sh"

DEPLOY_REQUEST=""
ORIGINAL_ARGS=("$@")
MANAGE_COMMAND=menu
DOCTOR_ARGS=()
LOG_ARGS=()
MATERIALS_COMMAND=apply
MATERIALS_ARGS=()
MANAGE_EOF=0
MANAGE_TEMP=""
MANAGE_READER_PID=''
MANAGE_READER_DIR=''
MANAGE_READER_TTY=''
MANAGE_INPUT_SIGNAL=0

manage_usage() {
  printf '%s\n' '用法：crispai [--deploy-dir PATH] [命令]' '无参数打开中文管理菜单。' \
    'status：本地状态；doctor：非破坏自检；init：快速初始化或继续安装。' \
    'doctor [--local|--full] [--json] [--fix]：本地/完整检查、JSON 与显式安全修复。' \
    'enable / disable：客服总开关；uninstall：数字确认卸载。' \
    'apply [--check|--force-external]：应用资料；--check 只校验，--force-external 重新同步并回读组件。' \
    'logs --help：日志查看、清理和保留策略。' \
    '--help / --version：帮助与版本，不要求 Docker 或完整配置。'
}

while (( $# > 0 )); do
  case "$1" in
    --deploy-dir) (( $# >= 2 )) || die '--deploy-dir 缺少参数'; DEPLOY_REQUEST=$2; shift 2 ;;
    --help|-h) manage_usage; exit 0 ;;
    --version) printf '%s\n' "$(<"${SCRIPT_DIR}/VERSION")"; exit 0 ;;
    logs)
      [[ "$MANAGE_COMMAND" == menu ]] || die '一次只能执行一个管理命令'
      MANAGE_COMMAND=logs; shift; LOG_ARGS=("$@"); break ;;
    menu|status|init|doctor|enable|disable|uninstall|apply)
      [[ "$MANAGE_COMMAND" == menu ]] || die '一次只能执行一个管理命令'
      MANAGE_COMMAND=$1; shift ;;
    --check)
      [[ "$MANAGE_COMMAND" == apply ]] || { printf '错误：--check 仅用于 apply。\n' >&2; exit 64; }
      (( ${#MATERIALS_ARGS[@]} == 0 )) || { printf '错误：只校验不能同时强制应用。\n' >&2; exit 64; }
      MATERIALS_COMMAND=validate; shift ;;
    --force-external)
      [[ "$MANAGE_COMMAND" == apply && "$MATERIALS_COMMAND" == apply && ${#MATERIALS_ARGS[@]} == 0 ]] \
        || { printf '错误：--force-external 仅用于 apply，不能与 --check 或自身重复。\n' >&2; exit 64; }
      MATERIALS_ARGS=(--force-external); shift ;;
    --local|--full|--json|--fix|--last|--offline)
      [[ "$MANAGE_COMMAND" == doctor ]] || { printf '错误：%s 仅用于 doctor 命令。\n' "$1" >&2; exit 64; }
      DOCTOR_ARGS+=("$1"); shift ;;
    --timeout)
      [[ "$MANAGE_COMMAND" == doctor && $# -ge 2 ]] || { printf '错误：doctor --timeout 需要秒数。\n' >&2; exit 64; }
      DOCTOR_ARGS+=("$1" "$2"); shift 2 ;;
    *) die "未知参数：$1" ;;
  esac
done
if (( EUID != 0 )); then
  command -v sudo >/dev/null 2>&1 || die '管理操作需要 root 或 sudo 权限'
  printf '管理 CrispAI 需要管理员权限，正在调用 sudo。\n' >&2
  exec sudo -- bash "$SCRIPT_DIR/manage.sh" "${ORIGINAL_ARGS[@]}"
fi
umask 077
DEPLOY_DIR=$(resolve_deploy_dir "$DEPLOY_REQUEST")
if [[ "$MANAGE_COMMAND" == doctor ]]; then
  # 默认自检不得隐式补依赖；缺失项由 doctor 报告，只有 --fix 才修复。
  exec bash "$SCRIPT_DIR/scripts/doctor.sh" --deploy-dir "$DEPLOY_DIR" "${DOCTOR_ARGS[@]}"
fi
bootstrap_prepare_minimal_dependencies || die '基础工具自动修复失败，请查看上方具体原因'

manage_reader_cleanup() {
  local interrupted=${1:-0}
  if [[ -n "$MANAGE_READER_PID" ]]; then
    # 仅终止当前输入子进程，不能向菜单/服务所在进程组广播信号。
    kill -TERM "$MANAGE_READER_PID" 2>/dev/null || true
    wait "$MANAGE_READER_PID" 2>/dev/null || true
    MANAGE_READER_PID=''
  fi
  if [[ -n "$MANAGE_READER_TTY" ]]; then
    if (( interrupted )); then
      # 定向 kill 不会像终端 Ctrl+C 一样丢弃尚未换行的秘密输入。
      python3 -c 'import termios; termios.tcflush(0, termios.TCIFLUSH)' 2>/dev/null || true
    fi
    stty "$MANAGE_READER_TTY" <&0 2>/dev/null || true
    MANAGE_READER_TTY=''
  fi
  if [[ "$MANAGE_READER_DIR" == /tmp/crispai-menu-input.* && -d "$MANAGE_READER_DIR" && ! -L "$MANAGE_READER_DIR" ]]; then
    rm -f -- "$MANAGE_READER_DIR/line"
    rmdir -- "$MANAGE_READER_DIR"
  fi
  MANAGE_READER_DIR=''
}

manage_cleanup() {
  manage_reader_cleanup 1
  if [[ -n "$MANAGE_TEMP" && "$MANAGE_TEMP" == "$DEPLOY_DIR"/tmp/manage.* && -d "$MANAGE_TEMP" && ! -L "$MANAGE_TEMP" ]]; then
    find "$MANAGE_TEMP" -depth -delete
  fi
}
trap manage_cleanup EXIT
manage_interrupt() {
  trap '' INT TERM
  printf '\n操作已中断；已生效配置保留，未确认输入未应用。\n' >&2
  exit 130
}
trap manage_interrupt INT TERM

menu_input_line() {
  local input_target=$1 input_prompt=${2:-} input_hidden=${3:-0} input_status=0 input_value
  # Bash 5.2 的 read 在信号早于 read(2) 时可能延后执行 trap，read -p 也有此窗口。
  # 将读取隔离；父进程使用会检查 pending trap 的 wait，不用超时轮询。
  MANAGE_INPUT_SIGNAL=0
  trap 'MANAGE_INPUT_SIGNAL=1' INT TERM
  MANAGE_READER_DIR=$(mktemp -d /tmp/crispai-menu-input.XXXXXXXX) || input_status=1
  if (( input_status == 0 )); then
    : > "$MANAGE_READER_DIR/line"
    if (( input_hidden )) && [[ -t 0 ]]; then
      MANAGE_READER_TTY=$(stty -g <&0) || input_status=1
      if (( input_status == 0 )); then stty -echo <&0 || input_status=1; fi
    fi
  fi
  if (( input_status == 0 && MANAGE_INPUT_SIGNAL == 0 )); then
    (
      # 异步 Bash 默认忽略 INT；父进程负责用默认 TERM 结束这个唯一 reader。
      trap - INT TERM EXIT
      printf '%s' "$input_prompt"
      IFS= read -r input_value || exit 1
      printf '%s' "$input_value" > "$MANAGE_READER_DIR/line"
    ) <&0 &
    MANAGE_READER_PID=$!
  fi
  trap manage_interrupt INT TERM
  (( MANAGE_INPUT_SIGNAL == 0 )) || manage_interrupt
  if (( input_status == 0 )); then
    wait "$MANAGE_READER_PID" || input_status=$?
    MANAGE_READER_PID=''
  fi
  if (( input_status == 0 )); then input_value=$(<"$MANAGE_READER_DIR/line"); fi
  manage_reader_cleanup
  (( input_status < 128 )) || manage_interrupt
  (( input_status == 0 )) || return "$input_status"
  printf -v "$input_target" '%s' "$input_value"
}

menu_read() {
  local target=$1 prompt=$2 hidden=${3:-0} typed
  if ! menu_input_line typed "$prompt" "$hidden"; then
    MANAGE_EOF=1; printf '\n输入已结束，未确认操作已取消。\n'; return 1
  fi
  if (( hidden )); then printf '\n'; fi
  printf -v "$target" '%s' "$typed"
}

menu_confirm() {
  local answer
  menu_read answer "${1} 1 确认 / 0 返回：" || return 1
  [[ "$answer" == 1 ]]
}

require_installation() {
  if ! (assert_installation "$DEPLOY_DIR"); then
    warn '请选择 1 快速初始化 / 继续安装；未改动现有文件'
    return 1
  fi
}

manager_temporary() {
  if [[ -z "$MANAGE_TEMP" || ! -d "$MANAGE_TEMP" ]]; then
    [[ -d "$DEPLOY_DIR/tmp" && ! -L "$DEPLOY_DIR/tmp" ]] || return 1
    MANAGE_TEMP=$(mktemp -d "$DEPLOY_DIR/tmp/manage.XXXXXX") || return 1
    chmod 0700 "$MANAGE_TEMP"
  fi
  MANAGE_FILE=$(mktemp "$MANAGE_TEMP/candidate.XXXXXX") || return 1
  chmod 0600 "$MANAGE_FILE"
}

manager_tool() {
  local module=$1
  shift
  [[ -f "$DEPLOY_DIR/scripts/$module.sh" && ! -L "$DEPLOY_DIR/scripts/$module.sh" ]] \
    || { warn "运行模块缺失：$module，请从完整发布包继续安装"; return 1; }
  # 模块输出通过普通文本管道，避免 jq 在 TTY 下无视旧版 NO_COLOR 产生颜色转义。
  bash "$DEPLOY_DIR/scripts/$module.sh" --deploy-dir "$DEPLOY_DIR" "$@" | cat
}

manager_action() {
  local status
  if "$@"; then return 0; else status=$?; fi
  if (( status == 2 )); then warn '操作取消或本地完成但外部接入待验证，请查看本次结果'
  else warn "操作未完成（退出码 $status）；保留现有状态，可修复对应项后重试"; fi
  return 0
}

manager_candidate() {
  manager_temporary || return 1
  manager_tool configuration get "$1" > "$MANAGE_FILE" || return 1
}

manager_apply() { manager_action manager_tool configuration apply "$1" --input "$2"; }

menu_multiline() {
  local output=$1 line bytes=0 max_bytes=${2:-262144}
  local LC_ALL=C
  printf '请粘贴多行正文。单独一行 ::END:: 保存，::CANCEL:: 取消。\n正文需要结束符字面量时，在行首加反斜线，例如 \\::END::。\n'
  : > "$output"
  while true; do
    if ! menu_input_line line; then MANAGE_EOF=1; warn '输入结束，正文未应用'; return 1; fi
    case "$line" in ::END::) break ;; ::CANCEL::) printf '已取消正文修改。\n'; return 1 ;; '\::END::'|'\::CANCEL::') line=${line:1} ;; esac
    bytes=$((bytes+${#line}+1))
    (( bytes <= max_bytes )) || { warn '正文超过输入上限，未应用'; return 1; }
    printf '%s\n' "$line" >> "$output"
  done
  [[ -s "$output" ]] || { warn '空正文未覆盖现有内容'; return 1; }
}

menu_pick_json() {
  local data=$1 id_field=$2 title_field=$3 answer count
  count=$(jq -M 'length' "$data")
  (( count > 0 )) || { printf '暂无可选项目。\n'; return 1; }
  jq -M -r --arg title "$title_field" 'to_entries[] | "\(.key+1). \(.value[$title] // .value.id // .value.key)"' "$data"
  menu_read answer '请选择序号（0 返回）：' || return 1
  [[ "$answer" =~ ^[1-9][0-9]{0,5}$ ]] && (( 10#$answer <= count )) || return 1
  MENU_SELECTED_ID=$(jq -M -r --arg field "$id_field" --argjson index "$((10#$answer-1))" '.[$index][$field]' "$data")
}

quick_initialization() {
  local choice
  local -a arguments=(--deploy-dir "$DEPLOY_DIR")
  if [[ -f "$DEPLOY_DIR/$INSTALL_MARKER" ]] && [[ "$(installation_state "$DEPLOY_DIR")" =~ ^(ready|local-ready)$ ]]; then
    printf '\n1. 保留现有配置继续检查与修复\n2. 重新运行十项初始化（保留数据）\n0. 返回\n'
    menu_read choice '请选择：' || return
    case "$choice" in 1) ;; 2) arguments+=(--reconfigure) ;; *) return ;; esac
  fi
  bash "$SCRIPT_DIR/install.sh" "${arguments[@]}"
}

show_installation_facts() {
  local fact label value state_file
  if [[ ! -f "$DEPLOY_DIR/$INSTALL_MARKER" ]]; then printf '本地尚未初始化；运行 crispai init。\n'; return; fi
  printf '安装状态：%s\n' "$(installation_state "$DEPLOY_DIR")"
  for fact in dependencies local_services app_config provider crisp_api webhook conversation; do
    case "$fact" in
      dependencies) label=依赖 ;; local_services) label=本地服务 ;; app_config) label=应用初始化 ;;
      provider) label=模型接口 ;; crisp_api) label='Crisp 认证' ;; webhook) label='公网 Hook' ;; conversation) label=真实会话往返 ;;
    esac
    value=$(installation_fact "$DEPLOY_DIR" "$fact" 2>/dev/null || true)
    printf '%s：%s\n' "$label" "${value:-未检测}"
  done
  state_file="$DEPLOY_DIR/config/runtime.yaml"
  if [[ -f "$DEPLOY_DIR/config/materials-applied.json" ]]; then state_file="$DEPLOY_DIR/config/materials-applied.json"; fi
  if [[ -f "$state_file" && ! -L "$state_file" ]]; then
    jq -M -r '(.configuration.runtime // .) | select(.enabled|type=="boolean") |
      "客服总开关（已应用）：\(if .enabled then "启用" else "停用" end)；配置版本：\(.revision // 0) / 已应用：\(.applied_revision // 0)"' \
      "$state_file" 2>/dev/null || printf '客服配置：无法解析；请从菜单 2 检查，未修改当前配置。\n'
  fi
}

doctor() {
  bash "$SCRIPT_DIR/scripts/doctor.sh" --deploy-dir "$DEPLOY_DIR" "$@"
}

export_doctor_report() {
  local status=0 target temporary
  require_installation || return 1
  [[ -d "$DEPLOY_DIR/logs" && ! -L "$DEPLOY_DIR/logs" ]] || return 1
  temporary=$(mktemp "$DEPLOY_DIR/logs/.doctor-export.XXXXXX") || return 1
  doctor --json > "$temporary" || status=$?
  if ! jq -e '.schema_version == 1 and (.results | type == "array")' "$temporary" >/dev/null 2>&1; then
    rm -f -- "$temporary"
    warn '自检没有生成有效 JSON，未导出报告'
    return 1
  fi
  target="$DEPLOY_DIR/logs/doctor-$(date -u '+%Y%m%dT%H%M%SZ')-$$.json"
  chmod 0600 "$temporary"
  mv -- "$temporary" "$target"
  printf '已导出脱敏自检报告：%s（不含密钥、Prompt、知识或客户正文）\n' "$target"
  return "$status"
}

status_menu() {
  local choice
  while (( MANAGE_EOF == 0 )); do
    printf '\n1. 快速自检：本地组件与配置状态\n2. 完整自检：外部连接与少量模型测试\n3. 查看上次自检结果（缓存）\n4. 修复本次发现的可自动修复问题\n5. 导出脱敏自检报告\n0. 返回\n'
    menu_read choice '请选择：' || return
    case "$choice" in
      1) manager_action doctor --local ;;
      2) printf '完整自检会发出少量合成模型请求，可能产生费用；不会向客户发送消息。\n'; manager_action doctor --full ;;
      3) manager_action doctor --last ;;
      4) manager_action doctor --fix ;;
      5) manager_action export_doctor_report ;;
      0) return ;; *) warn '请输入有效数字' ;;
    esac
  done
}

provider_candidate() {
  manager_temporary || return 1
  manager_tool provider get > "$MANAGE_FILE" || return 1
  jq -M 'if has("provider") then {provider:.provider} else {provider:del(.key_status,.custom_header_names)} end' "$MANAGE_FILE" > "$MANAGE_FILE.new"
  mv -f -- "$MANAGE_FILE.new" "$MANAGE_FILE"
}

provider_model_select() {
  local candidate=$1 models_file choice query='' page=0 total start request_status
  manager_temporary || return; models_file=$MANAGE_FILE
  while true; do
    if manager_tool provider models "$candidate" > "$models_file"; then break; else request_status=$?; fi
    if (( request_status == 3 )); then warn '模型列表鉴权失败，请先修正本次地址与 Key'; return; fi
    if (( request_status == 4 )); then
      menu_read choice '模型列表请求暂时失败：1 重试 / 2 返回修改接口 / 0 取消：' || return
      case "$choice" in 1) continue ;; *) return ;; esac
    fi
    warn '列表不可用；可手填模型并验证实际推理，空输入取消本次修改'
    menu_read choice '手动模型原名：' || return
    [[ -n "$choice" ]] || return
    jq -M --arg model "$choice" '.provider.model=$model' "$candidate" > "$candidate.new"
    mv -f -- "$candidate.new" "$candidate"
    if menu_confirm '使用手填模型验证并应用？'; then manager_action manager_tool provider apply "$candidate"; fi
    return
  done
  jq -M '[if type=="array" then .[] else (.models // .data // [])[] end | if type=="string" then . else .id end | select(type=="string")] | unique' "$models_file" > "$models_file.ids"
  while true; do
    jq -M --arg query "$query" '[.[] | select(contains($query))]' "$models_file.ids" > "$models_file.filtered"
    total=$(jq -M 'length' "$models_file.filtered")
    (( total > 0 )) || { warn '列表为空，请使用手动模型入口'; return; }
    start=$((page*15)); (( start < total )) || { page=0; start=0; }
    jq -M -r --argjson start "$start" 'to_entries[$start:$start+15][] | "\(.key+1). \(.value)"' "$models_file.filtered"
    menu_read choice '选择模型（数字，n 下一页，p 上一页，/词 搜索，0 返回）：' || return
    case "$choice" in
      0) return ;; n) ((page+=1)) ;; p) if ((page>0)); then page=$((page-1)); fi ;; /*) query=${choice:1}; page=0 ;;
      *)
        if [[ "$choice" =~ ^[1-9][0-9]{0,5}$ ]] && (( 10#$choice <= total )); then
          jq -M --slurpfile models "$models_file.filtered" --argjson index "$((10#$choice-1))" '.provider.model=$models[0][$index]' "$candidate" > "$candidate.new"
          mv -f -- "$candidate.new" "$candidate"
          manager_action manager_tool provider apply "$candidate"; return
        fi
        warn '序号无效' ;;
    esac
  done
}

ai_config_menu() {
  local choice value candidate secret_file header_name field
  while (( MANAGE_EOF == 0 )); do
    printf '\n1. 查看脱敏配置\n2. 修改 API 地址\n3. 替换 API Key\n4. 刷新并选择模型\n5. 手动指定模型\n6. 选择请求协议\n7. 测试当前模型\n8. 测试图片能力\n9. 自定义请求头\n10. 同时更换供应商地址、Key 与模型\n0. 返回\n'
    menu_read choice '请选择：' || return
    case "$choice" in
      1) manager_action manager_tool provider get ;;
      2|3|4|5|6|9|10)
        provider_candidate || { warn '无法读取当前接口配置'; continue; }; candidate=$MANAGE_FILE
        case "$choice" in
          2|5)
            if [[ "$choice" == 2 ]]; then field=base_url; else field=model; fi
            menu_read value "新的 $field（回车保留）：" || return; [[ -n "$value" ]] || continue
            jq -M --arg field "$field" --arg value "$value" '.provider[$field]=$value' "$candidate" > "$candidate.new" ;;
          3)
            menu_read value '新 API Key（隐藏输入，回车保留）：' 1 || return; [[ -n "$value" ]] || continue
            manager_temporary || return; secret_file=$MANAGE_FILE
            printf '%s' "$value" > "$secret_file"; unset value
            jq -M --rawfile secret "$secret_file" '.api_key=$secret' "$candidate" > "$candidate.new"; rm -f -- "$secret_file" ;;
          4) provider_model_select "$candidate"; continue ;;
          6)
            menu_read value '1 Chat Completions（聊天接口）/ 2 Responses（响应接口）/ 0 返回：' || return
            case "$value" in 1) value=chat_completions ;; 2) value=responses ;; *) continue ;; esac
            jq -M --arg value "$value" '.provider.api_mode=$value' "$candidate" > "$candidate.new" ;;
          9)
            menu_read header_name '请求头名称（回车返回；不能覆盖 Host 等协议头）：' || return; [[ -n "$header_name" ]] || continue
            menu_read value '请求头值（隐藏输入；::DELETE:: 删除该项）：' 1 || return; [[ -n "$value" ]] || continue
            manager_temporary || return; secret_file=$MANAGE_FILE
            printf '%s' "$value" > "$secret_file"; unset value
            jq -M --arg name "$header_name" --rawfile value "$secret_file" 'if $value=="::DELETE::" then .provider.remove_header=$name else .provider.custom_headers[$name]=$value end' "$candidate" > "$candidate.new"
            rm -f -- "$secret_file" ;;
          10)
            menu_read value '新 API Base URL（回车保留）：' || return
            if [[ -n "$value" ]]; then jq -M --arg value "$value" '.provider.base_url=$value' "$candidate" > "$candidate.new"; mv -f -- "$candidate.new" "$candidate"; fi
            menu_read value '新 API Key（隐藏输入，回车保留）：' 1 || return
            if [[ -n "$value" ]]; then
              manager_temporary || return; secret_file=$MANAGE_FILE; printf '%s' "$value" > "$secret_file"; unset value
              jq -M --rawfile value "$secret_file" '.api_key=$value' "$candidate" > "$candidate.new"; mv -f -- "$candidate.new" "$candidate"; rm -f -- "$secret_file"
            fi
            menu_read value '请求协议：1 Chat Completions / 2 Responses（回车保留）：' || return
            case "$value" in 1) value=chat_completions ;; 2) value=responses ;; '') value=$(jq -M -r '.provider.api_mode' "$candidate") ;; *) continue ;; esac
            jq -M --arg value "$value" '.provider.api_mode=$value' "$candidate" > "$candidate.new"; mv -f -- "$candidate.new" "$candidate"
            printf '将使用候选地址与 Key 读取模型列表，选定后才验证并应用完整配置。\n'
            provider_model_select "$candidate"; continue ;;
        esac
        chmod 0600 "$candidate.new"; mv -f -- "$candidate.new" "$candidate"
        printf '将发送少量合成请求验证配置，可能产生服务商费用。\n'
        if menu_confirm '应用本次接口修改？'; then manager_action manager_tool provider apply "$candidate"; fi ;;
      7) manager_action manager_tool provider test ;; 8) manager_action manager_tool provider vision-test ;;
      0) return ;; *) warn '请输入有效数字' ;;
    esac
  done
}

prompt_menu() {
  local choice path candidate query
  while (( MANAGE_EOF == 0 )); do
    printf '\n1. 查看当前 Prompt 与状态\n2. 直接粘贴多行正文\n3. 从文件导入\n4. 终端编辑候选正文\n5. 恢复上一版\n6. 导出当前 Prompt\n7. 合成问题验证\n0. 返回\n'
    menu_read choice '请选择：' || return
    case "$choice" in
      1) manager_action manager_tool configuration prompt-show; manager_action manager_tool configuration status ;;
      2|3|4)
        manager_temporary || return; candidate=$MANAGE_FILE
        case "$choice" in
          2) menu_multiline "$candidate" || continue ;;
          3)
            menu_read path 'Prompt 文件路径（回车返回）：' || return; [[ -n "$path" ]] || continue
            [[ -f "$path" && ! -L "$path" && -r "$path" ]] || { warn '必须是可读普通文件'; continue; }
            install -m 0600 -- "$path" "$candidate" ;;
          4)
            install -m 0600 -- "$DEPLOY_DIR/config/prompt.md" "$candidate"
            if command -v nano >/dev/null 2>&1; then nano "$candidate"
            elif command -v vi >/dev/null 2>&1; then vi "$candidate"
            else warn '没有可选编辑器，请选择直接粘贴'; continue; fi ;;
        esac
        if menu_confirm '应用新 Prompt 到当前客服？'; then manager_action manager_tool configuration prompt-apply "$candidate"; fi ;;
      5) if menu_confirm '恢复上一版 Prompt？'; then manager_action manager_tool configuration prompt-restore; fi ;;
      6) menu_read path '导出文件路径（回车返回）：' || return; [[ -z "$path" ]] || manager_action manager_tool configuration prompt-export "$path" ;;
      7) menu_read query '合成测试问题（回车返回）：' || return; [[ -z "$query" ]] || manager_action manager_tool configuration prompt-test "$query" ;;
      0) return ;; *) warn '请输入有效数字' ;;
    esac
  done
}

knowledge_select() {
  local listing
  manager_temporary || return 1; listing=$MANAGE_FILE
  manager_tool knowledge list > "$listing" || return 1
  jq -M 'if type=="array" then . else .libraries end' "$listing" > "$listing.array"
  menu_pick_json "$listing.array" id name || return 1
  KNOWLEDGE_SELECTED=$MENU_SELECTED_ID
}

knowledge_menu() {
  local choice name path selected listing query document
  while (( MANAGE_EOF == 0 )); do
    printf '\n1. 查看知识库及索引状态\n2. 创建命名知识库\n3. 重命名知识库\n4. 粘贴知识正文\n5. 导入文件或目录\n6. 查看/删除指定条目\n7. 启用知识库\n8. 停用知识库\n9. 删除知识库\n10. 同步知识库\n11. 重建索引\n12. 检索问题预览\n0. 返回\n'
    menu_read choice '请选择：' || return
    case "$choice" in
      1) manager_action manager_tool knowledge list ;;
      2) menu_read name '知识库中文名称（回车返回）：' || return; [[ -z "$name" ]] || manager_action manager_tool knowledge create "$name" ;;
      3|4|5|6|7|8|9)
        knowledge_select || continue; selected=$KNOWLEDGE_SELECTED
        case "$choice" in
          3) menu_read name '新名称（回车保留）：' || return; [[ -z "$name" ]] || manager_action manager_tool knowledge rename "$selected" "$name" ;;
          4)
            menu_read name '文本条目名称（不含目录，回车返回）：' || return; [[ -n "$name" ]] || continue
            [[ ${#name} -le 80 && "$name" != */* && "$name" != .* && "$name" != *$'\r'* ]] || { warn '条目名称无效或过长'; continue; }
            manager_temporary || return; path="${MANAGE_FILE}-${name}.md"; (umask 077; : > "$path")
            menu_multiline "$path" 8388608 || continue
            manager_action manager_tool knowledge import "$selected" "$path" ;;
          5) menu_read path '知识文件或目录路径（回车返回）：' || return; [[ -z "$path" ]] || manager_action manager_tool knowledge import "$selected" "$path" ;;
          6)
            manager_temporary || return; listing=$MANAGE_FILE
            if manager_tool knowledge entries "$selected" > "$listing"; then
              jq -M 'if type=="array" then . else (.documents // .entries // []) end' "$listing" > "$listing.array"
              if menu_pick_json "$listing.array" id name; then
                document=$MENU_SELECTED_ID
                if menu_confirm '删除此知识条目及其索引？'; then manager_action manager_tool knowledge remove "$selected" "$document"; fi
              fi
            fi ;;
          7) manager_action manager_tool knowledge enable "$selected" ;; 8) manager_action manager_tool knowledge disable "$selected" ;;
          9) if menu_confirm '删除所选知识库及原文？'; then manager_action manager_tool knowledge delete "$selected"; fi ;;
        esac ;;
      10|11|12)
        menu_read name '1 全部启用库 / 2 选择单库 / 0 返回：' || return
        case "$name" in 1) selected=all ;; 2) knowledge_select || continue; selected=$KNOWLEDGE_SELECTED ;; *) continue ;; esac
        case "$choice" in
          10) manager_action manager_tool knowledge sync "$selected" ;;
          11) if menu_confirm '重建所选知识索引？'; then manager_action manager_tool knowledge reindex "$selected"; fi ;;
          12) menu_read query '检索测试问题：' || return; [[ -z "$query" ]] || manager_action manager_tool knowledge query "$selected" "$query" ;;
        esac ;;
      0) return ;; *) warn '请输入有效数字' ;;
    esac
  done
}

rule_edit() {
  local candidate=$1 rule_id=$2 name words exclusions match rule_action value text title cancel confirm seconds ttl priority field existing temp lines
  existing=$(jq -M -c --arg id "$rule_id" '.rules[]? | select(.id==$id)' "$candidate")
  [[ -n "$existing" ]] || existing='{"enabled":true,"match_mode":"contains","action":"show_handoff_offer","cooldown_seconds":60,"offer_ttl_seconds":600,"priority":100,"confirm_label":"召唤人工客服","cancel_label":"继续 AI 客服","confirm_message":"已暂停本次对话的 AI 回复，您的人工协助请求已收到。"}'
  menu_read name "规则名称 [$(jq -M -r '.name // "人工确认"' <<< "$existing")]：" || return
  name=${name:-$(jq -M -r '.name // "人工确认"' <<< "$existing")}
  menu_read words '关键词（逗号分隔；::PASTE:: 逐行粘贴；回车保留）：' || return
  manager_temporary || return; lines=$MANAGE_FILE
  if [[ "$words" == ::PASTE:: ]]; then
    menu_multiline "$lines" 32768 || return; words=$(jq -M -Rs 'split("\n") | map(select(length>0))' "$lines")
  elif [[ -n "$words" ]]; then words=$(printf '%s' "$words" | jq -M -Rs 'split(",") | map(gsub("^\\s+|\\s+$";"")) | map(select(length>0))')
  else words=$(jq -M -c '.keywords // ["人工","转人工","人工客服"]' <<< "$existing"); fi
  menu_read exclusions '排除词（逗号分隔；回车保留，::CLEAR:: 清空）：' || return
  case "$exclusions" in
    '') exclusions=$(jq -M -c '.exclude_keywords // ["不要人工","不需要人工","不用人工","不转人工"]' <<< "$existing") ;;
    ::CLEAR::) exclusions='[]' ;; *) exclusions=$(printf '%s' "$exclusions" | jq -M -Rs 'split(",") | map(select(length>0))') ;;
  esac
  menu_read match '匹配：1 包含 / 2 完全匹配（回车保留）：' || return
  case "$match" in 1) match=contains ;; 2) match=exact ;; '') match=$(jq -M -r '.match_mode // "contains"' <<< "$existing") ;; *) return ;; esac
  menu_read rule_action '动作：1 人工确认按钮 / 2 固定回复 / 3 多级菜单 / 4 知识问答（回车保留）：' || return
  case "$rule_action" in 1) rule_action=show_handoff_offer ;; 2) rule_action=reply ;; 3) rule_action=menu ;; 4) rule_action=prompt ;; '') rule_action=$(jq -M -r '.action // "show_handoff_offer"' <<< "$existing") ;; *) return ;; esac
  menu_read priority '优先级整数（越大越优先，回车保留）：' || return; priority=${priority:-$(jq -M -r '.priority // 100' <<< "$existing")}
  menu_read seconds '重复展示冷却秒数（回车保留）：' || return; seconds=${seconds:-$(jq -M -r '.cooldown_seconds // 60' <<< "$existing")}
  menu_read ttl '按钮有效期秒数（回车保留）：' || return; ttl=${ttl:-$(jq -M -r '.offer_ttl_seconds // 600' <<< "$existing")}
  for value in "$priority" "$seconds" "$ttl"; do [[ "$value" =~ ^[0-9]{1,8}$ ]] || { warn '秒数和优先级必须是整数'; return; }; done
  menu_read text '提示或固定回复文案（回车保留）：' || return; text=${text:-$(jq -M -r '.text // "需要人工协助吗？请点击下方按钮确认。"' <<< "$existing")}
  title=$(jq -M -r '.confirm_label // "召唤人工客服"' <<< "$existing")
  cancel=$(jq -M -r '.cancel_label // "继续 AI 客服"' <<< "$existing")
  confirm=$(jq -M -r '.confirm_message // "已暂停本次对话的 AI 回复，您的人工协助请求已收到。"' <<< "$existing")
  if [[ "$rule_action" == show_handoff_offer ]]; then
    menu_read value "确认按钮 [$title]：" || return; title=${value:-$title}
    menu_read value "取消按钮 [$cancel]：" || return; cancel=${value:-$cancel}
    menu_read value '点击后的确认文案（回车保留）：' || return; confirm=${value:-$confirm}
  fi
  temp="$candidate.rule"
  jq -M -n --arg id "$rule_id" --arg name "$name" --arg match "$match" --arg action "$rule_action" --argjson words "$words" --argjson exclusions "$exclusions" --argjson original "$existing" \
    --argjson priority "$((10#$priority))" --argjson seconds "$((10#$seconds))" --argjson ttl "$((10#$ttl))" --arg text "$text" --arg title "$title" --arg cancel "$cancel" --arg confirm "$confirm" \
    '$original + {id:$id,name:$name,keywords:$words,exclude_keywords:$exclusions,match_mode:$match,action:$action,priority:$priority,cooldown_seconds:$seconds,offer_ttl_seconds:$ttl,text:$text,confirm_label:$title,cancel_label:$cancel,confirm_message:$confirm}' > "$temp"
  case "$rule_action" in
    menu|prompt)
      if [[ "$rule_action" == menu ]]; then field=target; else field=prompt; fi
      menu_read value "${field}（目标菜单 ID / 知识问答引导，回车保留）：" || return
      if [[ -n "$value" ]]; then jq -M --arg field "$field" --arg value "$value" '.[$field]=$value' "$temp" > "$temp.new"; mv -f -- "$temp.new" "$temp"; fi ;;
  esac
  jq -M --slurpfile rule "$temp" --arg id "$rule_id" '.schema_version=2 | .rules=((.rules // [] | map(select(.id!=$id))) + $rule) | del(.keywords)' "$candidate" > "$candidate.new"
  mv -f -- "$candidate.new" "$candidate"
  if menu_confirm '应用规则？关键词本身不会暂停 AI。'; then manager_apply keyword "$candidate"; fi
}

rules_menu() {
  local choice candidate rule_id query matched_rule value
  while (( MANAGE_EOF == 0 )); do
    printf '\n1. 查看规则\n2. 创建规则\n3. 修改规则\n4. 启用规则\n5. 停用规则\n6. 删除规则\n7. 输入客户文字预演\n0. 返回\n'
    menu_read choice '请选择：' || return
    case "$choice" in
      1) manager_action manager_tool configuration get keyword ;;
      2|3|4|5|6)
        manager_candidate keyword || continue; candidate=$MANAGE_FILE
        if [[ "$choice" == 2 ]]; then rule_id="rule_$(random_hex 8)"
        else
          jq -M '.rules // []' "$candidate" > "$candidate.rules"
          menu_pick_json "$candidate.rules" id name || continue; rule_id=$MENU_SELECTED_ID
        fi
        case "$choice" in
          2|3) rule_edit "$candidate" "$rule_id" ;;
          4|5)
            if [[ "$choice" == 4 ]]; then value=true; else value=false; fi
            jq -M --arg id "$rule_id" --argjson enabled "$value" '(.rules[] | select(.id==$id)).enabled=$enabled' "$candidate" > "$candidate.new"
            mv -f -- "$candidate.new" "$candidate"; manager_apply keyword "$candidate" ;;
          6) if menu_confirm '删除所选规则？'; then
              jq -M --arg id "$rule_id" '.rules |= map(select(.id!=$id))' "$candidate" > "$candidate.new"
              mv -f -- "$candidate.new" "$candidate"; manager_apply keyword "$candidate"
            fi ;;
        esac ;;
      7)
        menu_read query '虚构客户消息（只预演，不向 Crisp 发送）：' || return
        if ! matched_rule=$(runtime_cli preview-rule "$query"); then warn '无法读取运行中规则，请先诊断服务'; continue; fi
        if [[ "$matched_rule" == null ]]; then printf '未命中关键词，将按总开关和会话模式进行普通问答。\n'
        else jq -M -r '"命中：\(.name // .id)\n动作：\(.action)\n文案：\(.text // .prompt // "")\n按钮：\(.confirm_label // "无")"' <<< "$matched_rule"; printf '只有合法人工确认按钮点击才会暂停当前会话。\n'; fi ;;
      0) return ;; *) warn '请输入有效数字' ;;
    esac
  done
}

runtime_cli() { docker_compose "$DEPLOY_DIR" exec -T n8n node /opt/crisp-ai/n8n/runtime-cli.js "$@"; }

handoff_menu() {
  local choice seconds candidate listing key
  while (( MANAGE_EOF == 0 )); do
    printf '\n1. 查看恢复设置\n2. 修改恢复秒数\n3. 查看当前人工会话\n4. 手动恢复指定会话\n5. 调整指定会话倒计时\n0. 返回\n'
    menu_read choice '请选择：' || return
    case "$choice" in
      1) manager_action manager_tool configuration get handoff; printf '0 秒表示不自动恢复；正整数从最后有效真人回复或首次确认按钮点击计时。\n' ;;
      2)
        menu_read seconds '新恢复秒数（0 永久人工，正整数自动恢复；回车返回）：' || return
        [[ -n "$seconds" ]] || continue; [[ "$seconds" =~ ^[0-9]{1,8}$ ]] || { warn '请输入非负整数'; continue; }
        manager_candidate handoff || continue; candidate=$MANAGE_FILE
        jq -M --argjson seconds "$((10#$seconds))" '.handoff.resume_after_seconds=$seconds' "$candidate" > "$candidate.new"
        mv -f -- "$candidate.new" "$candidate"; printf '只影响后续新接管或真人回复，现有截止时间保留。\n'; manager_apply handoff "$candidate" ;;
      3) manager_action runtime_cli list ;;
      4|5)
        manager_temporary || return; listing=$MANAGE_FILE
        if ! runtime_cli list > "$listing"; then warn '无法读取会话状态'; continue; fi
        jq -M 'if type=="array" then . else .sessions // .conversations // [] end | map(. + {name:(.session_id+"；原因="+(.pause_reason // "未知")+"；截止="+((.resume_at // "永久")|tostring))})' "$listing" > "$listing.array"
        menu_pick_json "$listing.array" key name || continue; key=$MENU_SELECTED_ID
        if [[ "$choice" == 4 ]]; then
          if menu_confirm '恢复所选会话 AI？'; then manager_action runtime_cli resume "$key"; fi
        else
          menu_read seconds '从现在起重新计时多少秒（0 永久人工）：' || return
          [[ "$seconds" =~ ^[0-9]{1,8}$ ]] || continue
          if menu_confirm '调整此会话截止时间？'; then manager_action runtime_cli adjust-resume "$key" "$seconds"; fi
        fi ;;
      0) return ;; *) warn '请输入有效数字' ;;
    esac
  done
}

set_global_switch() {
  local candidate
  manager_candidate runtime || return 1; candidate=$MANAGE_FILE
  jq -M --argjson enabled "$1" '.enabled=$enabled' "$candidate" > "$candidate.new"
  mv -f -- "$candidate.new" "$candidate"
  manager_tool configuration apply runtime --input "$candidate"
}

global_switch_menu() {
  local choice
  while (( MANAGE_EOF == 0 )); do
    printf '\n关闭客服会停止自动出站，继续接收真人事件，不停止容器。\n1. 启用自动客服\n2. 停用自动客服\n3. 查看当前状态\n0. 返回\n'
    menu_read choice '请选择：' || return
    case "$choice" in 1) manager_action set_global_switch true ;; 2) manager_action set_global_switch false ;; 3) manager_action manager_tool configuration get runtime ;; 0) return ;; *) warn '请输入有效数字' ;; esac
  done
}

menus_select_node() {
  local candidate=$1
  jq -M '[.menus | to_entries[] | {id:.key,name:(.key+" — "+.value.title)}]' "$candidate" > "$candidate.nodes"
  menu_pick_json "$candidate.nodes" id name
}

menus_edit_option() {
  local candidate=$1 node_id=$2 number title action value position is_back=false
  menu_read number '选项数字（0 为返回选项，回车取消）：' || return; [[ "$number" =~ ^[0-9]{1,2}$ ]] || return; number=$((10#$number))
  menu_read title '按钮标题：' || return; [[ -n "$title" ]] || return
  menu_read action '动作：1 下级菜单 / 2 固定回复 / 3 知识问答 / 4 人工确认 / 5 返回父级：' || return
  case "$action" in
    1) action=menu; menu_read value '目标菜单 ID：' || return ;; 2) action=reply; menu_read value '固定回复文案：' || return ;;
    3) action=prompt; menu_read value '知识问答引导：' || return ;; 4) action=show_handoff_offer; value='' ;;
    5) action=menu; is_back=true; value=$(jq -M -r --arg node "$node_id" '.menus[$node].parent // .root' "$candidate") ;; *) return ;;
  esac
  menu_read position '显示顺序（回车使用选项数字）：' || return; position=${position:-$number}
  [[ "$position" =~ ^[0-9]{1,4}$ ]] || { warn '排序必须为整数'; return; }
  jq -M --arg node "$node_id" --arg number "$number" --arg title "$title" --arg action "$action" --arg value "$value" --argjson order "$((10#$position))" --argjson back "$is_back" \
    '.menus[$node].options[$number]={label:$title,order:$order,action:({type:$action}+if $action=="menu" then {target:$value,back:$back} elif $action=="reply" then {text:$value} elif $action=="prompt" then {prompt:$value} else {} end)}' "$candidate" > "$candidate.new"
  mv -f -- "$candidate.new" "$candidate"; manager_apply menu "$candidate"
}

multilevel_menu() {
  local choice candidate node title parent number
  while (( MANAGE_EOF == 0 )); do
    printf '\n1. 查看/预览菜单\n2. 新建节点\n3. 修改节点标题\n4. 新增/修改按钮\n5. 删除按钮\n6. 删除节点\n7. 设置根菜单\n0. 返回\n'
    menu_read choice '请选择：' || return
    case "$choice" in
      1) manager_action manager_tool configuration get menu ;;
      2)
        menu_read title '新节点标题：' || return; [[ -n "$title" ]] || continue
        manager_candidate menu || continue; candidate=$MANAGE_FILE
        printf '请选择父级菜单：\n'; menus_select_node "$candidate" || continue; parent=$MENU_SELECTED_ID; node="menu_$(random_hex 6)"
        jq -M --arg node "$node" --arg title "$title" --arg parent "$parent" \
          '(([.menus[$parent].options | keys[] | tonumber] | max // 0)+1) as $next | .menus[$node]={title:$title,parent:$parent,options:{"0":{label:"返回上一级",action:{type:"menu",target:$parent,back:true}}}} | .menus[$parent].options[($next|tostring)]={label:$title,order:$next,action:{type:"menu",target:$node}}' "$candidate" > "$candidate.new"
        mv -f -- "$candidate.new" "$candidate"
        if manager_tool configuration apply menu --input "$candidate"; then
          printf '新节点 ID：%s；已在父级增加入口与返回按钮。\n' "$node"
        else warn '新节点未生效；请修正当前菜单配置后重试'; fi ;;
      3|4|5|6|7)
        manager_candidate menu || continue; candidate=$MANAGE_FILE; menus_select_node "$candidate" || continue; node=$MENU_SELECTED_ID
        case "$choice" in
          3) menu_read title '新标题（回车保留）：' || return; [[ -n "$title" ]] || continue
            jq -M --arg node "$node" --arg title "$title" '.menus[$node].title=$title' "$candidate" > "$candidate.new" ;;
          4) menus_edit_option "$candidate" "$node"; continue ;;
          5) menu_read number '要删除的选项数字：' || return; [[ "$number" =~ ^[0-9]{1,2}$ ]] || continue
            jq -M --arg node "$node" --arg number "$((10#$number))" 'del(.menus[$node].options[$number])' "$candidate" > "$candidate.new" ;;
          6) menu_confirm '删除节点？仍被引用或包含子节点时会被拒绝。' || continue
            jq -M --arg node "$node" 'del(.menus[$node])' "$candidate" > "$candidate.new" ;;
          7) jq -M --arg node "$node" '.root=$node' "$candidate" > "$candidate.new" ;;
        esac
        mv -f -- "$candidate.new" "$candidate"; manager_apply menu "$candidate" ;;
      0) return ;; *) warn '请输入有效数字' ;;
    esac
  done
}

welcome_menu() {
  local choice candidate value textfile
  while (( MANAGE_EOF == 0 )); do
    printf '\n1. 查看欢迎配置\n2. 启用欢迎\n3. 关闭欢迎\n4. 粘贴多行欢迎文案\n5. 选择触发方式\n6. 设置自动展开聊天框\n7. 设置欢迎附带根菜单\n8. 多级菜单管理\n9. 查看无密钥页面接入片段\n0. 返回\n'
    menu_read choice '请选择：' || return
    case "$choice" in
      1) manager_action manager_tool configuration get menu ;;
      2|3|4|5|6|7)
        manager_candidate menu || continue; candidate=$MANAGE_FILE
        case "$choice" in
          2) jq -M '.welcome.enabled=true' "$candidate" > "$candidate.new" ;; 3) jq -M '.welcome.enabled=false' "$candidate" > "$candidate.new" ;;
          4) manager_temporary || return; textfile=$MANAGE_FILE; menu_multiline "$textfile" 16384 || continue
            jq -M --rawfile text "$textfile" '.welcome.text=$text' "$candidate" > "$candidate.new" ;;
          5) menu_read value '1 首条访客消息 / 2 页面加载 / 3 访客打开聊天框 / 0 返回：' || return
            case "$value" in 1) value=first_message ;; 2) value=widget_load ;; 3) value=chat_open ;; *) continue ;; esac
            jq -M --arg value "$value" '.welcome.trigger=$value' "$candidate" > "$candidate.new"
            [[ "$value" == first_message ]] || printf '此模式需要把无密钥 SDK 片段接入已有网站一次。\n' ;;
          6|7) menu_read value '1 启用 / 2 关闭 / 0 返回：' || return
            case "$value" in 1) value=true ;; 2) value=false ;; *) continue ;; esac
            if [[ "$choice" == 6 ]]; then jq -M --argjson value "$value" '.welcome.auto_open=$value' "$candidate" > "$candidate.new"; printf '自动展开需要网页 SDK 片段，后端消息不等于浏览器已打开。\n'
            else jq -M --argjson value "$value" '.welcome.show_menu=$value' "$candidate" > "$candidate.new"; fi ;;
        esac
        mv -f -- "$candidate.new" "$candidate"; manager_apply menu "$candidate" ;;
      8) multilevel_menu ;; 9) manager_action runtime_cli snippet ;;
      0) return ;; *) warn '请输入有效数字' ;;
    esac
  done
}

crisp_menu() {
  local choice candidate field value secret_file
  while (( MANAGE_EOF == 0 )); do
    printf '\n1. 查看脱敏接入配置\n2. 修改 Website ID\n3. 修改 Token Identifier\n4. 修改 Token Key\n5. 修改域名/公网地址\n6. 测试 REST 与公网接入\n7. 受控显示真实 Hook URL\n8. 轮换 Website Hook Secret\n9. 高级 Token/Hook 模式\n10. Crisp 接入教程\n11. 同时更换 Website 与整组 Token\n12. 查看 Hook/真实会话接收事实\n0. 返回\n'
    menu_read choice '请选择：' || return
    case "$choice" in
      1) manager_action manager_tool configuration crisp-get ;;
      2|3|4|5|8|9|11)
        manager_temporary || return; candidate=$MANAGE_FILE; printf '{}\n' > "$candidate"
        case "$choice" in
          2) field=website_id; menu_read value 'Website ID（回车保留）：' || return ;;
          3) field=token_identifier; menu_read value 'Token Identifier（隐藏输入，回车保留）：' 1 || return ;;
          4) field=token_key; menu_read value 'Token Key（隐藏输入，回车保留）：' 1 || return ;;
          5) field=webhook_input; menu_read value '域名或现有 HTTPS 生产 Hook 地址：' || return ;;
          8) menu_confirm '轮换后需更新 Crisp 后台 URL，旧地址会失效。继续？' || continue
            printf '{"rotate_secret":true}\n' > "$candidate"; value=rotate ;;
          9)
            menu_read value 'Token tier：1 Website / 2 Plugin / 0 返回：' || return
            case "$value" in 1) value=website ;; 2) value=plugin ;; *) continue ;; esac
            jq -M --arg value "$value" '.token_tier=$value' "$candidate" > "$candidate.new"; mv -f -- "$candidate.new" "$candidate"
            menu_read value 'Hook 类型：1 Website / 2 Plugin（与 Token tier 独立）/ 0 返回：' || return
            case "$value" in 1) value=website ;; 2) value=plugin ;; *) continue ;; esac
            jq -M --arg value "$value" '.hook_mode=$value' "$candidate" > "$candidate.new"; mv -f -- "$candidate.new" "$candidate"
            if [[ "$value" == plugin ]]; then field=plugin_signing_secret; menu_read value 'Plugin Signing Secret（隐藏输入，回车保留）：' 1 || return
            else field=hook_mode; fi ;;
          11)
            for field in website_id token_identifier token_key; do
              if [[ "$field" == website_id ]]; then menu_read value 'Website ID（回车保留）：' || return
              else menu_read value "$field（隐藏输入，回车保留）：" 1 || return; fi
              if [[ -n "$value" ]]; then
                manager_temporary || return; secret_file=$MANAGE_FILE; printf '%s' "$value" > "$secret_file"; unset value
                jq -M --arg field "$field" --rawfile value "$secret_file" '.[$field]=$value' "$candidate" > "$candidate.new"
                mv -f -- "$candidate.new" "$candidate"; rm -f -- "$secret_file"
              fi
            done
            menu_read value 'Token tier：1 Website / 2 Plugin（回车保留）：' || return
            case "$value" in 1) value=website ;; 2) value=plugin ;; '') ;; *) continue ;; esac
            field=token_tier ;;
        esac
        if [[ "$choice" != 8 && -n "$value" ]]; then
          manager_temporary || return; secret_file=$MANAGE_FILE; printf '%s' "$value" > "$secret_file"; unset value
          jq -M --arg field "$field" --rawfile value "$secret_file" '.[$field]=$value' "$candidate" > "$candidate.new"
          mv -f -- "$candidate.new" "$candidate"; rm -f -- "$secret_file"
        fi
        if menu_confirm '验证并应用本次 Crisp 配置？'; then manager_action manager_tool configuration crisp-apply "$candidate"; fi ;;
      6) manager_action manager_tool configuration crisp-test ;;
      7) if menu_confirm '仅在私密终端显示含 Secret 地址，禁止截图或公开。继续？'; then manager_action manager_tool crisp-settings hook-url; fi ;;
      10) show_document CRISP.md ;;
      12) manager_action runtime_cli observations ;;
      0) return ;; *) warn '请输入有效数字' ;;
    esac
  done
}

statistics_menu() {
  local choice candidate value field
  while (( MANAGE_EOF == 0 )); do
    printf '\n1. 知识命中分析\n2. 回答反馈统计\n3. 查看标签配置\n4. 修改标签\n5. 反馈启停与保留设置\n6. 清除统计与反馈记录\n0. 返回\n'
    menu_read choice '请选择：' || return
    case "$choice" in
      1) manager_action bash "$DEPLOY_DIR/scripts/analytics.sh" knowledge --deploy-dir "$DEPLOY_DIR" ;;
      2) manager_action bash "$DEPLOY_DIR/scripts/analytics.sh" feedback --deploy-dir "$DEPLOY_DIR" ;;
      3) manager_action manager_tool configuration get tags ;;
      4)
        menu_read value '标签：1 已回复 / 2 未命中 / 3 低置信度 / 4 人工 / 5 启用 / 6 关闭 / 0 返回：' || return
        case "$value" in 1) field=ai_replied ;; 2) field=knowledge_miss ;; 3) field=low_confidence ;; 4) field=human_required ;; 5|6) field=enabled ;; *) continue ;; esac
        manager_candidate tags || continue; candidate=$MANAGE_FILE
        if [[ "$field" == enabled ]]; then
          if [[ "$value" == 5 ]]; then value=true; else value=false; fi
          jq -M --argjson value "$value" '.tags.enabled=$value' "$candidate" > "$candidate.new"
        else
          menu_read value '新标签文案（回车保留）：' || return; [[ -n "$value" ]] || continue
          jq -M --arg field "$field" --arg value "$value" '.tags[$field]=$value' "$candidate" > "$candidate.new"
        fi
        mv -f -- "$candidate.new" "$candidate"; manager_apply tags "$candidate" ;;
      5)
        manager_candidate feedback || continue; candidate=$MANAGE_FILE
        menu_read value '反馈：1 启用 / 2 关闭 / 3 有效期秒数 / 4 保留天数 / 0 返回：' || return
        case "$value" in
          1|2) if [[ "$value" == 1 ]]; then value=true; else value=false; fi
            jq -M --argjson value "$value" '.feedback.enabled=$value' "$candidate" > "$candidate.new" ;;
          3|4) if [[ "$value" == 3 ]]; then field=expires_after_seconds; else field=retention_days; fi
            menu_read value '请输入正整数：' || return; [[ "$value" =~ ^[1-9][0-9]{0,7}$ ]] || continue
            jq -M --arg field "$field" --argjson value "$value" '.feedback[$field]=$value' "$candidate" > "$candidate.new" ;;
          *) continue ;;
        esac
        mv -f -- "$candidate.new" "$candidate"; manager_apply feedback "$candidate" ;;
      6) if menu_confirm '删除统计反馈记录（保留人工状态）？'; then manager_action runtime_cli clear-analytics; fi ;;
      0) return ;; *) warn '请输入有效数字' ;;
    esac
  done
}

migration_menu() {
  local choice path
  while (( MANAGE_EOF == 0 )); do
    printf '\n1. 导出完整业务配置与知识原文（不含秘密）\n2. 预览/导入迁移包\n0. 返回\n'
    menu_read choice '请选择：' || return
    case "$choice" in
      1) menu_read path "导出路径 [$DEPLOY_DIR/backups/business-config.tar.gz]：" || return
        path=${path:-$DEPLOY_DIR/backups/business-config.tar.gz}
        printf '知识原文属于业务资料，请保护迁移包；新服务器需重新填写 AI/Crisp 凭据。\n'
        manager_action manager_tool migration export "$path" ;;
      2) menu_read path '迁移包路径（回车返回）：' || return; [[ -n "$path" ]] || continue
        if manager_tool migration import-preview "$path"; then
          if menu_confirm '按预览替换业务配置并同步，保留本机秘密？'; then manager_action manager_tool migration import "$path"; fi
        fi ;;
      0) return ;; *) warn '请输入有效数字' ;;
    esac
  done
}

backup_restore_menu() {
  local choice path value
  while (( MANAGE_EOF == 0 )); do
    printf '\n1. 创建本机完整备份\n2. 列出备份\n3. 恢复完整备份\n4. 容量与版本保留策略\n5. 设置版本快照保留数量\n0. 返回\n'
    menu_read choice '请选择：' || return
    case "$choice" in
      1) menu_read path "备份路径 [$DEPLOY_DIR/backups/full-$(date -u '+%Y%m%dT%H%M%SZ').tar.gz]：" || return
        path=${path:-$DEPLOY_DIR/backups/full-$(date -u '+%Y%m%dT%H%M%SZ').tar.gz}
        printf '完整备份含凭据、知识、数据库和人工状态，禁止公开或上传。\n'
        manager_action bash "$DEPLOY_DIR/scripts/backup.sh" --deploy-dir "$DEPLOY_DIR" --full --output "$path" ;;
      2) find "$DEPLOY_DIR/backups" -maxdepth 1 -type f -name '*.tar.gz' -printf '%f\n' | sort ;;
      3) menu_read path '完整备份路径：' || return; [[ -n "$path" ]] || continue
        if menu_confirm '完整恢复将替换配置、秘密和运行数据，继续？'; then manager_action bash "$DEPLOY_DIR/scripts/restore.sh" --deploy-dir "$DEPLOY_DIR" --full --input "$path"; fi ;;
      4) manager_action bash "$DEPLOY_DIR/scripts/snapshot.sh" --deploy-dir "$DEPLOY_DIR" --check-capacity; df -h "$DEPLOY_DIR"
        printf '保留快照数：%s\n' "$(env_get "$DEPLOY_DIR/.env" SNAPSHOT_RETENTION_COUNT 2>/dev/null || printf 10)" ;;
      5) menu_read value '快照数量（0 不自动清理；回车保留）：' || return
        if [[ ! "$value" =~ ^[0-9]{1,4}$ ]] || (( 10#$value > 1000 )); then continue; fi
        (acquire_maintenance_lock "$DEPLOY_DIR"; env_set "$DEPLOY_DIR/.env" SNAPSHOT_RETENTION_COUNT "$((10#$value))")
        printf '已设置，之后创建快照时应用。\n' ;;
      0) return ;; *) warn '请输入有效数字' ;;
    esac
  done
}

update_rollback_menu() {
  local choice path snapshot
  while (( MANAGE_EOF == 0 )); do
    printf '\n1. 匿名在线更新至最新正式版\n2. 从已解压的新版本目录离线升级\n3. 从原 Git 源码更新（高级）\n4. 查看历史快照\n5. 回滚指定快照\n0. 返回\n'
    menu_read choice '请选择：' || return
    case "$choice" in
      1) if [[ ! -f "$DEPLOY_DIR/get.sh" || -L "$DEPLOY_DIR/get.sh" ]]; then
          warn '受管在线更新入口缺失或不安全；请从完整正式包修复当前实例'
          continue
        fi
        printf '将匿名读取公开仓库的 Latest 正式版，锁定版本后下载完整包与 SHA256SUMS 并校验。\n'
        if menu_confirm '更新会先创建一致性快照，失败自动回滚。继续？'; then
          manager_action bash "$DEPLOY_DIR/get.sh" --update --deploy-dir "$DEPLOY_DIR"
        fi ;;
      2) menu_read path '完整新版发布包的解压目录：' || return; [[ -n "$path" ]] || continue
        if menu_confirm '更新前自动快照，失败自动回滚。继续？'; then manager_action bash "$DEPLOY_DIR/update.sh" --deploy-dir "$DEPLOY_DIR" --source-dir "$path" --no-pull; fi ;;
      3) if menu_confirm '从原 Git 工作区更新并升级？'; then manager_action bash "$DEPLOY_DIR/update.sh" --deploy-dir "$DEPLOY_DIR"; fi ;;
      4) manager_action bash "$DEPLOY_DIR/scripts/rollback.sh" --deploy-dir "$DEPLOY_DIR" --list ;;
      5) manager_action bash "$DEPLOY_DIR/scripts/rollback.sh" --deploy-dir "$DEPLOY_DIR" --list
        menu_read snapshot '要恢复的快照 ID（回车返回）：' || return; [[ -n "$snapshot" ]] || continue
        if menu_confirm '恢复该版本程序、配置及数据？'; then manager_action bash "$DEPLOY_DIR/scripts/rollback.sh" --deploy-dir "$DEPLOY_DIR" --snapshot "$snapshot"; fi ;;
      0) return ;; *) warn '请输入有效数字' ;;
    esac
  done
}

menu_log_source() {
  local filter=${1:-all} list
  manager_temporary || return 1
  list=$MANAGE_FILE
  manager_tool logs sources --json > "$list" || return 1
  jq -M --arg filter "$filter" '.sources | map(select(
    if $filter=="follow" then .followable
    elif $filter=="mutable" then .mutable
    else true end))' "$list" > "$list.filtered" || return 1
  menu_pick_json "$list.filtered" id name
}

follow_log_source() {
  local source=$1 status=0
  printf '持续查看日志，Ctrl+C 仅停止查看并返回日志菜单。\n'
  # 父菜单与前台查看进程同属终端进程组；只在查看期间抑制父菜单退出。
  trap ':' INT
  bash "$DEPLOY_DIR/scripts/logs.sh" --deploy-dir "$DEPLOY_DIR" follow "$source" || status=$?
  trap manage_interrupt INT
  if (( status == 130 )); then printf '\n已停止日志查看，服务未停止。\n'; return 0; fi
  return "$status"
}

diagnostics_menu() {
  local choice source lines since days size files operation
  local -a viewing=()
  while (( MANAGE_EOF == 0 )); do
    printf '\n1. 日志来源、占用与保留策略\n2. 按来源查看最近日志\n3. 持续查看指定来源（Ctrl+C 返回）\n4. 轮转或清空选定受管日志\n5. 删除指定天数以前的历史日志\n6. 修改保留天数与容量限制\n7. 按当前策略立即清理过期日志\n8. 导出脱敏诊断包\n9. 查看排障说明\n0. 返回\n'
    menu_read choice '请选择：' || return
    case "$choice" in
      1) manager_action manager_tool logs status ;;
      2) menu_log_source || continue; source=$MENU_SELECTED_ID
        menu_read lines '最近行数（1～2000，0 或回车返回）：' || return
        if [[ ! "$lines" =~ ^[1-9][0-9]{0,3}$ ]] || (( 10#$lines > 2000 )); then continue; fi
        menu_read since '时间窗口（如 30m、2h、7d；回车不限定）：' || return
        viewing=(show "$source" --lines "$lines")
        [[ -z "$since" ]] || viewing+=(--since "$since")
        manager_action manager_tool logs "${viewing[@]}" ;;
      3) menu_log_source follow || continue
        manager_action follow_log_source "$MENU_SELECTED_ID" ;;
      4) menu_log_source mutable || continue; source=$MENU_SELECTED_ID; operation=clear
        if [[ "$source" == maintenance ]]; then
          printf '1. 轮转当前维护日志\n2. 清空该维护日志\n0. 返回\n'
          menu_read choice '请选择：' || return
          case "$choice" in 1) operation=rotate ;; 2) ;; *) continue ;; esac
        fi
        if manager_tool logs "$operation" "$source" --preview \
          && menu_confirm '只处理上述日志；清空内容不可恢复。确认？'; then
          manager_action manager_tool logs "$operation" "$source" --apply
        fi ;;
      5) menu_read days '删除多少天以前的受管历史（1～3650，0 或回车返回）：' || return
        if [[ ! "$days" =~ ^[1-9][0-9]{0,3}$ ]] || (( 10#$days > 3650 )); then continue; fi
        if manager_tool logs cleanup --days "$days" --preview \
          && menu_confirm '删除上述历史日志（不可恢复），不改变当前保留策略？'; then
          manager_action manager_tool logs cleanup --days "$days" --apply
        fi ;;
      6) manager_action manager_tool logs policy
        printf '文件日志按天清理；Docker 按每容器容量轮转；n8n execution 按小时保留。\n'
        menu_read days '文件日志保留天数（1～3650，0 或回车返回）：' || return
        if [[ ! "$days" =~ ^[1-9][0-9]{0,3}$ ]] || (( 10#$days > 3650 )); then continue; fi
        menu_read size '每份日志上限 MiB（正整数，回车返回）：' || return
        [[ "$size" =~ ^[1-9][0-9]{0,3}$ ]] || continue
        menu_read files '最多保留份数（1～20，回车返回）：' || return
        if [[ ! "$files" =~ ^[1-9][0-9]?$ ]] || (( 10#$files > 20 )); then continue; fi
        if manager_tool logs configure --days "$days" --max-size-mib "$size" --max-files "$files" --preview \
          && menu_confirm '应用容量策略需要重建本项目容器，短暂停机但保留数据及人工状态。继续？'; then
          manager_action manager_tool logs configure --days "$days" --max-size-mib "$size" --max-files "$files" --apply
        fi ;;
      7) if manager_tool logs cleanup --preview && menu_confirm '按当前策略删除上述过期日志（不可恢复）？'; then
          manager_action manager_tool logs cleanup --apply
        fi ;;
      8) manager_action manager_tool logs export ;;
      9) show_document TROUBLESHOOTING.md ;;
      0) return ;; *) warn '请输入有效数字' ;;
    esac
  done
}

maintain_services() (
  acquire_maintenance_lock "$DEPLOY_DIR"
  docker_compose "$DEPLOY_DIR" "$@"
)

services_menu() {
  local choice
  local -a material_options=()
  while (( MANAGE_EOF == 0 )); do
    printf '\n1. 启动本项目服务\n2. 停止本项目服务\n3. 重启本项目服务\n4. 检查依赖与 Docker\n5. 自动修复依赖\n6. 校验并应用已编辑资料\n7. 修复 crispai / crisp 入口\n8. 查看用户资料路径与未应用变更\n0. 返回\n'
    menu_read choice '请选择：' || return
    case "$choice" in
      1) manager_action maintain_services up -d ;;
      2) if menu_confirm '停机时无法接收 Hook/真人事件。停止本项目？'; then manager_action maintain_services stop; fi ;;
      3) if menu_confirm '重启本项目服务？人工状态会保留。'; then manager_action maintain_services restart; fi ;;
      4) manager_action bash "$DEPLOY_DIR/scripts/bootstrap.sh" --check ;; 5) manager_action bash "$DEPLOY_DIR/scripts/bootstrap.sh" --all ;;
      6) printf '会校验原文，备份上一有效版并同步 Prompt/知识；慢同步期间暂缓自动回复，不清空人工状态。\n'
        printf '1. 仅应用已编辑的资料变更\n2. 重新同步现有资料并回读组件（增量知识对账）\n0. 返回\n'
        menu_read choice '请选择：' || return
        material_options=()
        case "$choice" in
          1) ;;
          2) material_options=(--force-external) ;;
          0|'') continue ;;
          *) warn '请输入有效数字'; continue ;;
        esac
        if menu_confirm '按上述范围校验并应用用户资料？'; then
          manager_action manager_tool materials apply "${material_options[@]}"
        fi ;;
      7) manager_action bash "$DEPLOY_DIR/scripts/launcher.sh" install --deploy-dir "$DEPLOY_DIR" ;;
      8) manager_action manager_tool materials status ;;
      0) return ;; *) warn '请输入有效数字' ;;
    esac
  done
}

show_document() {
  local document=$1
  if [[ -f "$DEPLOY_DIR/docs/$document" ]]; then sed -n '1,320p' "$DEPLOY_DIR/docs/$document"
  elif [[ -f "$SCRIPT_DIR/docs/$document" ]]; then sed -n '1,320p' "$SCRIPT_DIR/docs/$document"
  else warn "本地文档缺失：$document"; fi
  printf '\n对应文档：https://github.com/statusX7/ai-support/blob/main/docs/%s\n' "$document"
}

help_menu() {
  local choice
  while (( MANAGE_EOF == 0 )); do
    printf '\n1. 安装部署\n2. 逐项菜单\n3. Crisp 凭据与 Hook\n4. 配置字段\n5. 故障排查\n0. 返回\n'
    menu_read choice '请选择：' || return
    case "$choice" in 1) show_document INSTALL.md ;; 2) show_document MENU.md ;; 3) show_document CRISP.md ;; 4) show_document CONFIG.md ;; 5) show_document TROUBLESHOOTING.md ;; 0) return ;; *) warn '请输入有效数字' ;; esac
  done
}

uninstall_menu() {
  local choice status
  while (( MANAGE_EOF == 0 )); do
    printf '\n1. 安全卸载：移除本项目服务，保留配置和数据\n2. 完整清理：移除本实例服务及数据，先创建外部备份\n0. 返回\n'
    menu_read choice '请选择：' || return
    case "$choice" in
      1|2)
        if [[ "$choice" == 1 ]]; then
          if bash "$DEPLOY_DIR/uninstall.sh" --deploy-dir "$DEPLOY_DIR" --keep-data; then exit 0; else status=$?; fi
        else
          if bash "$DEPLOY_DIR/uninstall.sh" --deploy-dir "$DEPLOY_DIR" --purge --numeric-confirm; then exit 0; else status=$?; fi
        fi
        warn "卸载未执行完成（退出码 $status），请查看上方结果" ;;
      0) return ;; *) warn '请输入有效数字' ;;
    esac
  done
}

case "$MANAGE_COMMAND" in
  status) show_installation_facts; exit 0 ;; init) quick_initialization; exit 0 ;; doctor) doctor; exit $? ;;
  enable) require_installation; set_global_switch true; exit $? ;; disable) require_installation; set_global_switch false; exit $? ;;
  uninstall) require_installation; uninstall_menu; exit 0 ;;
  apply) require_installation; manager_tool materials "$MATERIALS_COMMAND" "${MATERIALS_ARGS[@]}"; exit $? ;;
  logs) require_installation; manager_tool logs "${LOG_ARGS[@]}"; exit $? ;;
esac

while (( MANAGE_EOF == 0 )); do
  CURRENT_VERSION=$(<"${SCRIPT_DIR}/VERSION")
  MENU_ENABLED=未配置 MENU_CRISP=未检测 MENU_KNOWLEDGE=0
  if [[ -f "$DEPLOY_DIR/config/materials-applied.json" && ! -L "$DEPLOY_DIR/config/materials-applied.json" ]]; then
    MENU_ENABLED=$(jq -M -er 'if .state == "applying" then "应用中" elif .state == "applied" and (.configuration.runtime.enabled|type=="boolean") then
      (if .configuration.runtime.enabled then "启用" else "停用" end) else error("invalid") end' "$DEPLOY_DIR/config/materials-applied.json" 2>/dev/null || printf 未检测)
  elif [[ -f "$DEPLOY_DIR/config/runtime.yaml" && ! -L "$DEPLOY_DIR/config/runtime.yaml" ]]; then
    MENU_ENABLED=$(jq -M -er 'if (.enabled|type)=="boolean" then (if .enabled then "启用" else "停用" end) else error("invalid") end' "$DEPLOY_DIR/config/runtime.yaml" 2>/dev/null || printf 未检测)
  fi
  if [[ -f "$DEPLOY_DIR/$INSTALL_MARKER" ]]; then
    case "$(installation_fact "$DEPLOY_DIR" conversation 2>/dev/null || true)" in ready) MENU_CRISP=已验证 ;; *) MENU_CRISP=待验证 ;; esac
  fi
  if [[ -f "$DEPLOY_DIR/knowledge/catalog.json" ]]; then MENU_KNOWLEDGE=$(jq -M '[.libraries[]? | select(.enabled)] | length' "$DEPLOY_DIR/knowledge/catalog.json" 2>/dev/null || printf 0); fi
  menu_render "$CURRENT_VERSION" "$DEPLOY_DIR" "$MENU_ENABLED" "$MENU_CRISP" "$MENU_KNOWLEDGE"
  CHOICE=''
  if ! menu_read CHOICE '请选择：'; then printf '\n输入结束，已退出。\n'; exit 0; fi
  case "$CHOICE" in
    1) manager_action quick_initialization ;; 2) status_menu ;;
    3) if require_installation; then ai_config_menu; fi ;; 4) if require_installation; then prompt_menu; fi ;;
    5) if require_installation; then knowledge_menu; fi ;; 6) if require_installation; then rules_menu; fi ;;
    7) if require_installation; then handoff_menu; fi ;; 8) if require_installation; then global_switch_menu; fi ;;
    9) if require_installation; then welcome_menu; fi ;; 10) if require_installation; then crisp_menu; fi ;;
    11) if require_installation; then statistics_menu; fi ;; 12) if require_installation; then migration_menu; fi ;;
    13) if require_installation; then backup_restore_menu; fi ;; 14) if require_installation; then update_rollback_menu; fi ;;
    15) if require_installation; then diagnostics_menu; fi ;; 16) if require_installation; then services_menu; fi ;;
    17) help_menu ;; 18) if require_installation; then uninstall_menu; fi ;;
    0) exit 0 ;; *) warn '请输入菜单中的数字；回车不会执行操作' ;;
  esac
done
