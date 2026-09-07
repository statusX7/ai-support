#!/usr/bin/env bash
set -euo pipefail

LOGS_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/common.sh disable=SC1091
source "${LOGS_SCRIPT_DIR}/common.sh"

# 保留调用者原始 stderr；外部探针通常整体重定向，signal trap 仍需能说明恢复状态。
exec {LOGS_NOTICE_FD}>&2

LOGS_DEPLOY_REQUEST=''
LOGS_JSON=0
LOGS_COMMAND=''
LOGS_SOURCE=''
LOGS_LINES=200
LOGS_SINCE=''
LOGS_OUTPUT=''
LOGS_APPLY=0
LOGS_SCHEDULED=0
LOGS_NO_DOCKER=0
LOGS_DAYS=''
LOGS_MAX_SIZE_MIB=''
LOGS_MAX_FILES=''
LOGS_PROFILE=''
LOGS_ACTION=''
LOGS_PHASE=''
LOGS_CODE=''
LOGS_INPUT=''
LOGS_TIMEOUT=${CRISPAI_LOGS_TIMEOUT_SECONDS:-30}
LOGS_TIMEOUT_EXPLICIT=0
LOGS_TEMP_ROOT=''
LOGS_APPLY_ACTIVE=0
LOGS_APPLY_CONFIG_BACKUP=''
LOGS_APPLY_ENV_BACKUP=''
LOGS_APPLY_CHANGED=0
LOGS_ACTIVE_CHILD_PID=''

logs_usage() {
  cat <<'EOF'
用法：logs.sh [--deploy-dir PATH] [--json] COMMAND [选项]

只读：
  sources                         列出受管日志来源及边界
  status                          显示占用、策略、调度和最近清理
  policy                          显示期望值与实际应用值
  show SOURCE [--lines N] [--since 2h]
  follow SOURCE [--lines N] [--since 30m]
  audit [--no-docker]             供 doctor 使用的有界结构化核对

需明确应用：
  cleanup [--preview|--apply]     仅删除过期的受管历史文件
  rotate SOURCE [--preview|--apply]
  clear SOURCE [--preview|--apply]
  configure --days D --max-size-mib M --max-files C [--preview|--apply]
  export [--output FILE]          生成不含配置正文/业务数据的脱敏诊断包

内部生命周期接口：
  initialize [--profile new|upgrade-v1]
  event --action NAME --phase NAME --code N
  record-doctor --input FILE
  timer install|remove|status|run

SOURCE：maintenance、doctor-cache、doctor-history、provider-adapter、postgres、
anythingllm、n8n、caddy、log-maintenance、n8n-executions、analytics。

说明：Docker 容器日志只通过 Docker API 查看，不能清空或直接操作 LogPath；
n8n execution 与 analytics 是独立数据，由各自官方/业务保留策略管理。
退出码：0 成功；2 警告或待应用；1 故障；64 参数错误；130 中断。
EOF
}

logs_parameter_error() {
  printf '错误：%s\n' "$*" >&2
  logs_usage >&2
  exit 64
}

logs_cleanup_temp() {
  if [[ -n "$LOGS_TEMP_ROOT" && -d "$LOGS_TEMP_ROOT" && ! -L "$LOGS_TEMP_ROOT" ]]; then
    find "$LOGS_TEMP_ROOT" -depth -delete 2>/dev/null || true
  fi
}

logs_stop_active_child() {
  local pid=${LOGS_ACTIVE_CHILD_PID:-} attempt
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 0
  kill -TERM "$pid" 2>/dev/null || true
  for ((attempt=0; attempt<10; attempt++)); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.05
  done
  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  LOGS_ACTIVE_CHILD_PID=''
}

logs_restore_apply() {
  local status=0 mode
  (( LOGS_APPLY_ACTIVE == 1 && LOGS_APPLY_CHANGED == 1 )) || return 0
  [[ -f "$LOGS_APPLY_CONFIG_BACKUP" && -f "$LOGS_APPLY_ENV_BACKUP" ]] || return 1
  install -m 0640 -- "$LOGS_APPLY_CONFIG_BACKUP" "$LOGS_CONFIG" || status=1
  install -m 0600 -- "$LOGS_APPLY_ENV_BACKUP" "$LOGS_DEPLOY_DIR/.env" || status=1
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    mode=$(env_get "$LOGS_DEPLOY_DIR/.env" WEBHOOK_ACCESS_MODE 2>/dev/null || true)
    if [[ "$mode" == managed_https ]]; then
      timeout --signal=TERM --kill-after=5s 120s \
        docker compose --project-directory "$LOGS_DEPLOY_DIR" --env-file "$LOGS_DEPLOY_DIR/.env" \
          -f "$LOGS_DEPLOY_DIR/docker-compose.yml" --profile managed-https up -d --force-recreate \
          </dev/null >/dev/null 2>&1 || status=1
    else
      timeout --signal=TERM --kill-after=5s 120s \
        docker compose --project-directory "$LOGS_DEPLOY_DIR" --env-file "$LOGS_DEPLOY_DIR/.env" \
          -f "$LOGS_DEPLOY_DIR/docker-compose.yml" up -d --force-recreate \
          </dev/null >/dev/null 2>&1 || status=1
    fi
  fi
  LOGS_APPLY_CHANGED=0
  return "$status"
}

logs_on_exit() {
  local status=$?
  trap - EXIT
  # 恢复与临时目录收尾必须不可再次被 INT/TERM 打断，避免留下半套运行代。
  trap '' INT TERM
  logs_stop_active_child
  if (( status != 0 && LOGS_APPLY_ACTIVE == 1 && LOGS_APPLY_CHANGED == 1 )); then
    printf '日志策略操作异常退出，正在恢复旧配置与容器运行代……\n' >&"$LOGS_NOTICE_FD"
    logs_restore_apply || printf '警告：自动恢复未完成，请使用版本恢复功能核对整组运行代。\n' >&"$LOGS_NOTICE_FD"
  fi
  logs_cleanup_temp
  exit "$status"
}

logs_interrupted() {
  # 第一次信号进入受控恢复后，忽略后续 INT/TERM，直至整组恢复和清理完成。
  trap '' INT TERM
  logs_stop_active_child
  if (( LOGS_APPLY_ACTIVE )); then
    printf '\n日志策略应用被中断，正在恢复旧配置与容器运行代……\n' >&"$LOGS_NOTICE_FD"
    logs_restore_apply || printf '警告：自动恢复未完成，请使用版本恢复功能核对整组运行代。\n' >&"$LOGS_NOTICE_FD"
  else
    printf '\n日志操作已中断；未改变客服、知识或会话状态。\n' >&"$LOGS_NOTICE_FD"
  fi
  exit 130
}

trap logs_on_exit EXIT
trap logs_interrupted INT TERM

while (( $# > 0 )); do
  case "$1" in
    --deploy-dir) (( $# >= 2 )) || logs_parameter_error '--deploy-dir 缺少参数'; LOGS_DEPLOY_REQUEST=$2; shift 2 ;;
    --json) LOGS_JSON=1; shift ;;
    --lines) (( $# >= 2 )) || logs_parameter_error '--lines 缺少参数'; LOGS_LINES=$2; shift 2 ;;
    --since) (( $# >= 2 )) || logs_parameter_error '--since 缺少参数'; LOGS_SINCE=$2; shift 2 ;;
    --output) (( $# >= 2 )) || logs_parameter_error '--output 缺少参数'; LOGS_OUTPUT=$2; shift 2 ;;
    --apply) LOGS_APPLY=1; shift ;;
    --preview) LOGS_APPLY=0; shift ;;
    --scheduled) LOGS_SCHEDULED=1; shift ;;
    --no-docker) LOGS_NO_DOCKER=1; shift ;;
    --days) (( $# >= 2 )) || logs_parameter_error '--days 缺少参数'; LOGS_DAYS=$2; shift 2 ;;
    --max-size-mib) (( $# >= 2 )) || logs_parameter_error '--max-size-mib 缺少参数'; LOGS_MAX_SIZE_MIB=$2; shift 2 ;;
    --max-files) (( $# >= 2 )) || logs_parameter_error '--max-files 缺少参数'; LOGS_MAX_FILES=$2; shift 2 ;;
    --profile) (( $# >= 2 )) || logs_parameter_error '--profile 缺少参数'; LOGS_PROFILE=$2; shift 2 ;;
    --action) (( $# >= 2 )) || logs_parameter_error '--action 缺少参数'; LOGS_ACTION=$2; shift 2 ;;
    --phase) (( $# >= 2 )) || logs_parameter_error '--phase 缺少参数'; LOGS_PHASE=$2; shift 2 ;;
    --code) (( $# >= 2 )) || logs_parameter_error '--code 缺少参数'; LOGS_CODE=$2; shift 2 ;;
    --input) (( $# >= 2 )) || logs_parameter_error '--input 缺少参数'; LOGS_INPUT=$2; shift 2 ;;
    --timeout) (( $# >= 2 )) || logs_parameter_error '--timeout 缺少参数'; LOGS_TIMEOUT=$2; LOGS_TIMEOUT_EXPLICIT=1; shift 2 ;;
    --help|-h) logs_usage; exit 0 ;;
    --version)
      if [[ -f "${LOGS_SCRIPT_DIR}/../VERSION" && ! -L "${LOGS_SCRIPT_DIR}/../VERSION" ]]; then
        sed -n '1p' "${LOGS_SCRIPT_DIR}/../VERSION"
      else
        printf '%s\n' unknown
      fi
      exit 0
      ;;
    sources|status|policy|show|follow|audit|cleanup|rotate|clear|configure|export|initialize|event|record-doctor)
      [[ -z "$LOGS_COMMAND" ]] || logs_parameter_error '只能指定一个 COMMAND'
      LOGS_COMMAND=$1; shift
      ;;
    timer)
      [[ -z "$LOGS_COMMAND" ]] || logs_parameter_error '只能指定一个 COMMAND'
      LOGS_COMMAND=timer
      (( $# >= 2 )) || logs_parameter_error 'timer 需要 install、remove、status 或 run'
      LOGS_ACTION=$2; shift 2
      ;;
    maintenance|doctor-cache|doctor-history|provider-adapter|postgres|anythingllm|n8n|caddy|log-maintenance|n8n-executions|analytics)
      [[ -z "$LOGS_SOURCE" ]] || logs_parameter_error '只能指定一个 SOURCE'
      LOGS_SOURCE=$1; shift
      ;;
    *) logs_parameter_error "未知参数：$1" ;;
  esac
done

[[ -n "$LOGS_COMMAND" ]] || logs_parameter_error '缺少 COMMAND'
if [[ ! "$LOGS_LINES" =~ ^[1-9][0-9]{0,4}$ ]] || (( 10#$LOGS_LINES > 10000 )); then
  logs_parameter_error '--lines 必须是 1 到 10000 的整数'
fi
[[ -z "$LOGS_SINCE" || "$LOGS_SINCE" =~ ^[1-9][0-9]{0,5}(s|m|h|d)$ ]] \
  || logs_parameter_error '--since 格式应为 30m、2h 或 7d'
if [[ ! "$LOGS_TIMEOUT" =~ ^[1-9][0-9]{0,3}$ ]] || (( 10#$LOGS_TIMEOUT > 600 )); then
  logs_parameter_error '--timeout 必须是 1 到 600 秒的整数'
fi
if [[ "$LOGS_COMMAND" == configure && "$LOGS_APPLY" == 1 && "$LOGS_TIMEOUT_EXPLICIT" == 0 ]]; then
  # 重建固定组件可能包含首次健康等待；其余只读命令仍保持 30 秒默认预算。
  LOGS_TIMEOUT=300
fi

require_command jq
require_command python3
require_command realpath
LOGS_DEPLOY_DIR=$(resolve_deploy_dir "$LOGS_DEPLOY_REQUEST")
assert_managed_installation "$LOGS_DEPLOY_DIR"
LOGS_ROOT="${LOGS_DEPLOY_DIR}/logs"
LOGS_CONFIG="${LOGS_DEPLOY_DIR}/config/logging.yaml"
LOGS_REDACTOR="${LOGS_DEPLOY_DIR}/scripts/log-redact.py"
LOGS_DEADLINE=$((SECONDS + 10#$LOGS_TIMEOUT))
LOGS_TEMP_ROOT=$(mktemp -d /tmp/crispai-logs.XXXXXXXX)
chmod 0700 "$LOGS_TEMP_ROOT"

[[ -d "$LOGS_ROOT" && ! -L "$LOGS_ROOT" ]] || die "受管日志目录不安全：$LOGS_ROOT"
[[ -f "$LOGS_REDACTOR" && ! -L "$LOGS_REDACTOR" ]] || die '日志脱敏模块缺失或不安全'

logs_now() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

logs_remaining() {
  local remaining=$((LOGS_DEADLINE - SECONDS))
  (( remaining > 0 )) || return 1
  printf '%s\n' "$remaining"
}

logs_timeout() {
  local requested=$1 remaining status=0
  shift
  remaining=$(logs_remaining) || return 124
  (( requested < remaining )) || requested=$remaining
  # 使用异步子进程配合 wait，使 Bash 等待外部命令时仍能立即执行 INT/TERM trap；
  # 否则同步前台命令可能直接以 130 退出，跳过整组配置恢复。
  timeout --signal=TERM --kill-after=2s "${requested}s" "$@" &
  LOGS_ACTIVE_CHILD_PID=$!
  if wait "$LOGS_ACTIVE_CHILD_PID"; then status=0; else status=$?; fi
  LOGS_ACTIVE_CHILD_PID=''
  return "$status"
}

logs_config_valid() {
  local file=$LOGS_CONFIG
  [[ -f "$file" && ! -L "$file" ]] \
    && jq -e '
      . as $root |
      .schema_version == 1 and
      (.revision | type == "number" and floor == . and . >= 1) and
      (.applied_revision | type == "number" and floor == . and . >= 0 and . <= $root.revision) and
      (.retention_days | type == "number" and floor == . and . >= 1 and . <= 3650) and
      (.max_size_mib | type == "number" and floor == . and . >= 1 and . <= 1024) and
      (.max_files | type == "number" and floor == . and . >= 1 and . <= 20) and
      (.timer_enabled | type == "boolean") and
      (.updated_at | type == "string" and length >= 20 and length <= 40)
    ' "$file" >/dev/null 2>&1
}

logs_config_or_default() {
  if logs_config_valid; then
    jq -M '.' "$LOGS_CONFIG"
  else
    jq -M -cn '{schema_version:1,revision:0,applied_revision:0,retention_days:7,max_size_mib:10,max_files:5,timer_enabled:true,updated_at:"1970-01-01T00:00:00Z"}'
  fi
}

logs_redact() {
  local mode=${1:-display}
  python3 "$LOGS_REDACTOR" --env "$LOGS_DEPLOY_DIR/.env" --mode "$mode"
}

logs_safe_regular_file() {
  local file=$1
  [[ -f "$file" && ! -L "$file" \
    && "$(stat -c '%h' -- "$file" 2>/dev/null || true)" == 1 ]]
}

logs_source_type() {
  case "$1" in
    maintenance|doctor-cache|doctor-history) printf '%s\n' file ;;
    provider-adapter|postgres|anythingllm|n8n|caddy) printf '%s\n' container ;;
    log-maintenance) printf '%s\n' journal ;;
    n8n-executions) printf '%s\n' execution-policy ;;
    analytics) printf '%s\n' business-data ;;
    *) return 1 ;;
  esac
}

logs_source_name() {
  case "$1" in
    maintenance) printf '%s\n' '安装与维护事件' ;;
    doctor-cache) printf '%s\n' '最近自检缓存' ;;
    doctor-history) printf '%s\n' '自检历史' ;;
    provider-adapter) printf '%s\n' 'Provider adapter 容器' ;;
    postgres) printf '%s\n' 'PostgreSQL 容器' ;;
    anythingllm) printf '%s\n' 'AnythingLLM 容器' ;;
    n8n) printf '%s\n' 'n8n 容器' ;;
    caddy) printf '%s\n' 'Caddy 容器' ;;
    log-maintenance) printf '%s\n' '日志清理调度单元' ;;
    n8n-executions) printf '%s\n' 'n8n 执行记录策略' ;;
    analytics) printf '%s\n' '匿名统计业务数据' ;;
    *) return 1 ;;
  esac
}

logs_source_mutable() {
  case "$1" in maintenance|doctor-cache|doctor-history) printf true ;; *) printf false ;; esac
}

logs_source_followable() {
  case "$1" in maintenance|provider-adapter|postgres|anythingllm|n8n|caddy|log-maintenance) printf true ;; *) printf false ;; esac
}

logs_timer_identity() {
  local digest
  digest=$(printf '%s' "$LOGS_DEPLOY_DIR" | sha256sum | cut -d ' ' -f 1)
  printf 'crispai-log-maintenance-%s\n' "${digest:0:16}"
}

logs_timer_marker() { printf '%s/config/.crispai-log-timer\n' "$LOGS_DEPLOY_DIR"; }

logs_timer_status_json() {
  local base marker enabled=false active=false available=false owned=false last='unknown'
  local systemd_dir service timer digest
  base=$(logs_timer_identity)
  marker=$(logs_timer_marker)
  systemd_dir=${CRISPAI_LOGS_SYSTEMD_DIR:-/etc/systemd/system}
  service="$systemd_dir/${base}.service"; timer="$systemd_dir/${base}.timer"
  digest=$(printf '%s' "$LOGS_DEPLOY_DIR" | sha256sum | cut -d ' ' -f 1)
  if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system || "${CRISPAI_LOGS_SYSTEMD_TEST:-0}" == 1 ]]; then
    available=true
    systemctl is-enabled --quiet "${base}.timer" >/dev/null 2>&1 && enabled=true
    systemctl is-active --quiet "${base}.timer" >/dev/null 2>&1 && active=true
  fi
  if [[ -f "$marker" && ! -L "$marker" ]] \
    && grep -Fxq 'ai-support-log-maintenance/v1' "$marker" 2>/dev/null \
    && grep -Fxq "deploy_sha256=${digest}" "$marker" 2>/dev/null \
    && grep -Fxq "unit=${base}" "$marker" 2>/dev/null \
    && [[ -f "$service" && ! -L "$service" && -f "$timer" && ! -L "$timer" ]] \
    && grep -Fxq '# ai-support-log-maintenance/v1' "$service" 2>/dev/null \
    && grep -Fxq "# deploy-sha256: ${digest}" "$service" 2>/dev/null \
    && grep -Fxq '# ai-support-log-maintenance/v1' "$timer" 2>/dev/null \
    && grep -Fxq "# deploy-sha256: ${digest}" "$timer" 2>/dev/null; then
    owned=true
  fi
  if [[ -f "$LOGS_ROOT/log-maintenance-last.json" && ! -L "$LOGS_ROOT/log-maintenance-last.json" ]] \
    && jq -e '.schema_version == 1 and (.completed_at | type == "string")' "$LOGS_ROOT/log-maintenance-last.json" >/dev/null 2>&1; then
    last=$(jq -r '.completed_at' "$LOGS_ROOT/log-maintenance-last.json")
  fi
  jq -M -cn --arg unit "$base" --arg last "$last" --argjson available "$available" \
    --argjson owned "$owned" --argjson enabled "$enabled" --argjson active "$active" \
    '{unit:$unit,systemd_available:$available,owned:$owned,enabled:$enabled,active:$active,last_cleanup:$last}'
}

logs_sources_json() {
  local id type name mutable followable available note path service running=false
  local output="${LOGS_TEMP_ROOT}/sources.jsonl"
  : > "$output"
  for id in maintenance doctor-cache doctor-history provider-adapter postgres anythingllm n8n caddy log-maintenance n8n-executions analytics; do
    type=$(logs_source_type "$id"); name=$(logs_source_name "$id")
    mutable=$(logs_source_mutable "$id"); followable=$(logs_source_followable "$id")
    available=false; note=''
    case "$id" in
      maintenance) path="$LOGS_ROOT/maintenance.jsonl"; [[ -f "$path" && ! -L "$path" ]] && available=true ;;
      doctor-cache) path="$LOGS_ROOT/doctor-last.json"; [[ -f "$path" && ! -L "$path" ]] && available=true ;;
      doctor-history) path="$LOGS_ROOT/doctor-history"; [[ -d "$path" && ! -L "$path" ]] && available=true ;;
      provider-adapter|postgres|anythingllm|n8n|caddy)
        if (( LOGS_NO_DOCKER == 0 )) && command -v docker >/dev/null 2>&1 && logs_timeout 4 docker info >/dev/null 2>&1; then
          service=$id
          # shellcheck disable=SC2016 # 位置参数由受限子 shell 展开。
          if logs_timeout 4 bash -c 'source "$1"; docker_compose "$2" ps --services --filter status=running' \
            logs-source "$LOGS_SCRIPT_DIR/common.sh" "$LOGS_DEPLOY_DIR" 2>/dev/null | grep -Fxq "$service"; then running=true; else running=false; fi
          available=$running
        fi
        note='仅通过 Docker API 读取；禁止直接操作 Docker LogPath'
        ;;
      log-maintenance)
        command -v journalctl >/dev/null 2>&1 && [[ -d /run/systemd/system || "${CRISPAI_LOGS_SYSTEMD_TEST:-0}" == 1 ]] && available=true
        note='仅查看本项目 unit；不会 vacuum 全局 journal'
        ;;
      n8n-executions)
        available=true; note='仅核对官方保存/清理设置；不直接 SQL 删除 execution'
        ;;
      analytics)
        [[ -d "$LOGS_DEPLOY_DIR/data/analytics" && ! -L "$LOGS_DEPLOY_DIR/data/analytics" ]] && available=true
        note='业务统计数据，不属于运维日志；按 feedback.retention_days 独立保留'
        ;;
    esac
    jq -M -cn --arg id "$id" --arg name "$name" --arg type "$type" --arg note "$note" \
      --argjson available "$available" --argjson mutable "$mutable" --argjson followable "$followable" \
      '{id:$id,name:$name,type:$type,available:$available,mutable:$mutable,followable:$followable,note:$note}' >> "$output"
  done
  jq -M -s '.' "$output"
}

logs_managed_usage_json() {
  local maintenance=0 doctor_cache=0 doctor_history=0 diagnostics=0 total=0 file size unsafe=0
  if [[ -f "$LOGS_ROOT/maintenance.jsonl" && ! -L "$LOGS_ROOT/maintenance.jsonl" \
    && "$(stat -c '%h' "$LOGS_ROOT/maintenance.jsonl" 2>/dev/null || true)" == 1 ]]; then
    maintenance=$(stat -c '%s' "$LOGS_ROOT/maintenance.jsonl" 2>/dev/null || printf 0)
  elif [[ -e "$LOGS_ROOT/maintenance.jsonl" || -L "$LOGS_ROOT/maintenance.jsonl" ]]; then
    ((unsafe += 1))
  fi
  if [[ -f "$LOGS_ROOT/doctor-last.json" && ! -L "$LOGS_ROOT/doctor-last.json" \
    && "$(stat -c '%h' "$LOGS_ROOT/doctor-last.json" 2>/dev/null || true)" == 1 ]]; then
    doctor_cache=$(stat -c '%s' "$LOGS_ROOT/doctor-last.json" 2>/dev/null || printf 0)
  elif [[ -e "$LOGS_ROOT/doctor-last.json" || -L "$LOGS_ROOT/doctor-last.json" ]]; then
    ((unsafe += 1))
  fi
  shopt -s nullglob
  if [[ -e "$LOGS_ROOT/doctor-history" || -L "$LOGS_ROOT/doctor-history" ]] \
    && [[ ! -d "$LOGS_ROOT/doctor-history" || -L "$LOGS_ROOT/doctor-history" ]]; then
    ((unsafe += 1))
  else
    for file in "$LOGS_ROOT"/maintenance.jsonl.[1-9]* "$LOGS_ROOT"/doctor-[0-9]*.json "$LOGS_ROOT"/doctor-history/doctor-[0-9]*.json; do
      [[ -f "$file" && ! -L "$file" && "$(stat -c '%h' "$file" 2>/dev/null || true)" == 1 ]] || { ((unsafe += 1)); continue; }
      size=$(stat -c '%s' "$file" 2>/dev/null || printf 0); [[ "$size" =~ ^[0-9]+$ ]] || size=0
      if [[ "$file" == *doctor* ]]; then ((doctor_history += size)); else ((maintenance += size)); fi
    done
  fi
  if [[ -e "$LOGS_ROOT/diagnostics" || -L "$LOGS_ROOT/diagnostics" ]] \
    && [[ ! -d "$LOGS_ROOT/diagnostics" || -L "$LOGS_ROOT/diagnostics" ]]; then
    ((unsafe += 1))
  else
    for file in "$LOGS_ROOT"/diagnostics/crispai-diagnostics-[0-9]*.tar.gz; do
      [[ -f "$file" && ! -L "$file" && "$(stat -c '%h' "$file" 2>/dev/null || true)" == 1 ]] || { ((unsafe += 1)); continue; }
      size=$(stat -c '%s' "$file" 2>/dev/null || printf 0); [[ "$size" =~ ^[0-9]+$ ]] || size=0
      ((diagnostics += size))
    done
  fi
  shopt -u nullglob
  total=$((maintenance + doctor_cache + doctor_history + diagnostics))
  jq -M -cn --argjson total "$total" --argjson maintenance "$maintenance" \
    --argjson doctor_cache "$doctor_cache" --argjson doctor_history "$doctor_history" \
    --argjson diagnostics "$diagnostics" --argjson unsafe "$unsafe" \
    '{managed_bytes:$total,by_source:{maintenance:$maintenance,doctor_cache:$doctor_cache,doctor_history:$doctor_history,diagnostics:$diagnostics},unsafe_entries:$unsafe,container_bytes:null,container_note:"Docker API 不安全地公开逐容器日志占用；仅核对容量上限，不读取 LogPath"}'
}

logs_compose_policy_json() {
  local config_file="${LOGS_TEMP_ROOT}/compose-policy.json" rc=0 validation=skipped
  # offline/daemon 不可用时仍静态核对受管 Compose 白名单字段；这不需要展开 Env。
  # 有 Compose CLI 时额外执行无输出语法校验，但绝不保存完整 config。
  if (( LOGS_NO_DOCKER == 0 )) && command -v docker >/dev/null 2>&1 \
    && logs_timeout 4 docker compose version >/dev/null 2>&1; then
    validation=checked
    # shellcheck disable=SC2016 # 位置参数由受限子 shell展开。
    logs_timeout 8 bash -c 'source "$1"; docker_compose "$2" config --quiet' \
      logs-compose "$LOGS_SCRIPT_DIR/common.sh" "$LOGS_DEPLOY_DIR" </dev/null >/dev/null 2>&1 || rc=$?
  fi
  # 静态读取 compose 源文件，只返回受管字段是否引用预期环境变量；不展开、
  # 不输出或持久化任何环境变量值。
  if (( rc == 0 )); then
    python3 - "$LOGS_DEPLOY_DIR/docker-compose.yml" "$validation" > "$config_file" <<'PY' || rc=$?
import json
import pathlib
import sys

try:
    import yaml
except ImportError:
    raise SystemExit(3)

path = pathlib.Path(sys.argv[1])
validation = sys.argv[2]
if not path.is_file() or path.is_symlink() or path.stat().st_size > 2 * 1024 * 1024:
    raise SystemExit(4)
try:
    data = yaml.safe_load(path.read_text(encoding="utf-8"))
except (OSError, UnicodeError, yaml.YAMLError):
    raise SystemExit(5)
if not isinstance(data, dict) or not isinstance(data.get("services"), dict):
    raise SystemExit(6)
services = data["services"]
result = []
for name in ("postgres", "anythingllm", "n8n", "provider-adapter", "caddy"):
    service = services.get(name, {})
    logging = service.get("logging", {}) if isinstance(service, dict) else {}
    options = logging.get("options", {}) if isinstance(logging, dict) else {}
    wired = (
        logging.get("driver") == "json-file"
        and str(options.get("max-size", "")).startswith("${CRISPAI_LOG_MAX_SIZE:-")
        and str(options.get("max-file", "")).startswith("${CRISPAI_LOG_MAX_FILES:-")
    )
    result.append({"name": name, "logging_wired": wired})
n8n = services.get("n8n", {})
environment = n8n.get("environment", {}) if isinstance(n8n, dict) else {}
if not isinstance(environment, dict):
    environment = {}
privacy = {
    "prune_wired": str(environment.get("EXECUTIONS_DATA_PRUNE", "")).lower() == "true",
    "max_age_wired": str(environment.get("EXECUTIONS_DATA_MAX_AGE", "")).startswith("${CRISPAI_LOG_RETENTION_HOURS:-"),
    "save_success_wired": str(environment.get("EXECUTIONS_DATA_SAVE_ON_SUCCESS", "")).lower() == "none",
    "save_error_wired": str(environment.get("EXECUTIONS_DATA_SAVE_ON_ERROR", "")).lower() == "none",
}
print(json.dumps({"state": "configured", "validation": validation, "services": result, "n8n": privacy}, separators=(",", ":")))
PY
  fi
  if (( rc != 0 )) || ! jq -e '.state == "configured" and (.services | type == "array") and (.n8n | type == "object")' "$config_file" >/dev/null 2>&1; then
    : > "$config_file"
    jq -M -cn --argjson rc "$rc" '{state:"invalid",reason:"Compose 配置无法安全解析",exit_code:$rc}'
    return 0
  fi
  jq -M -c '.' "$config_file"
  : > "$config_file"
}

logs_actual_container_policy_json() {
  local expected_size=$1 expected_files=$2 service id observed output="${LOGS_TEMP_ROOT}/container-policy.jsonl"
  : > "$output"
  if (( LOGS_NO_DOCKER )) || ! command -v docker >/dev/null 2>&1 || ! logs_timeout 5 docker info >/dev/null 2>&1; then
    jq -M -cn '{state:"unavailable",matched:false,services:[],reason:"Docker daemon 不可用或本次跳过"}'
    return 0
  fi
  for service in postgres anythingllm n8n provider-adapter caddy; do
    # shellcheck disable=SC2016 # 位置参数由受限子 shell 展开。
    id=$(logs_timeout 4 bash -c 'source "$1"; docker_compose "$2" ps -q "$3"' \
      logs-container "$LOGS_SCRIPT_DIR/common.sh" "$LOGS_DEPLOY_DIR" "$service" </dev/null 2>/dev/null || true)
    [[ -n "$id" ]] || continue
    observed=$(logs_timeout 4 docker inspect --format '{{json .HostConfig.LogConfig}}' "$id" </dev/null 2>/dev/null || true)
    if jq -e . >/dev/null 2>&1 <<< "$observed"; then
      jq -M -cn --arg service "$service" --argjson observed "$observed" \
        '{name:$service,driver:($observed.Type//""),max_size:($observed.Config["max-size"]//""),max_files:($observed.Config["max-file"]//"")}' >> "$output"
    else
      jq -M -cn --arg service "$service" '{name:$service,driver:"",max_size:"",max_files:""}' >> "$output"
    fi
  done
  jq -M -s --arg size "$expected_size" --arg files "$expected_files" '
    {state:(if length==0 then "unavailable" else "checked" end),
     matched:(length>0 and all(.[]; .driver=="json-file" and .max_size==$size and .max_files==$files)),services:.}
  ' "$output"
}

logs_n8n_actual_json() {
  local output="${LOGS_TEMP_ROOT}/n8n-env.json" rc=0
  if (( LOGS_NO_DOCKER )) || ! command -v docker >/dev/null 2>&1 || ! logs_timeout 5 docker info >/dev/null 2>&1; then
    jq -M -cn '{state:"unavailable"}'
    return 0
  fi
  # shellcheck disable=SC2016 # 位置参数和容器内 JS 由受限子 shell 展开/执行。
  logs_timeout 8 bash -c '
    source "$1"
    docker_compose "$2" exec -T n8n node -e '\''process.stdout.write(JSON.stringify({prune:process.env.EXECUTIONS_DATA_PRUNE||"",max_age_hours:process.env.EXECUTIONS_DATA_MAX_AGE||"",save_success:process.env.EXECUTIONS_DATA_SAVE_ON_SUCCESS||"",save_error:process.env.EXECUTIONS_DATA_SAVE_ON_ERROR||""}))'\'' </dev/null
  ' logs-n8n "$LOGS_SCRIPT_DIR/common.sh" "$LOGS_DEPLOY_DIR" > "$output" 2>/dev/null || rc=$?
  if (( rc == 0 )) && jq -e 'type == "object"' "$output" >/dev/null 2>&1; then
    jq -M -c '. + {state:"checked"}' "$output"
  else
    jq -M -cn --argjson rc "$rc" '{state:"unavailable",exit_code:$rc}'
  fi
}

logs_audit_json() {
  local configured=false config status=PASS summary='' env_match=false compose actual n8n timer usage
  local days size files hours desired applied max_bytes
  if logs_config_valid; then configured=true; fi
  config=$(logs_config_or_default)
  days=$(jq -r '.retention_days' <<< "$config")
  size=$(jq -r '.max_size_mib' <<< "$config")
  files=$(jq -r '.max_files' <<< "$config")
  desired=$(jq -r '.revision' <<< "$config")
  applied=$(jq -r '.applied_revision' <<< "$config")
  hours=$((days * 24)); max_bytes=$((size * 1024 * 1024))
  if [[ "$configured" == true ]] \
    && [[ "$(env_get "$LOGS_DEPLOY_DIR/.env" CRISPAI_LOG_RETENTION_DAYS 2>/dev/null || true)" == "$days" ]] \
    && [[ "$(env_get "$LOGS_DEPLOY_DIR/.env" CRISPAI_LOG_RETENTION_HOURS 2>/dev/null || true)" == "$hours" ]] \
    && [[ "$(env_get "$LOGS_DEPLOY_DIR/.env" CRISPAI_LOG_MAX_SIZE 2>/dev/null || true)" == "${size}m" ]] \
    && [[ "$(env_get "$LOGS_DEPLOY_DIR/.env" CRISPAI_LOG_MAX_FILES 2>/dev/null || true)" == "$files" ]]; then
    env_match=true
  fi
  compose=$(logs_compose_policy_json)
  actual=$(logs_actual_container_policy_json "${size}m" "$files")
  n8n=$(logs_n8n_actual_json)
  timer=$(logs_timer_status_json)
  usage=$(logs_managed_usage_json)

  if [[ "$configured" != true ]]; then status=FAIL; summary='日志策略文件缺失或 schema 无效'
  elif (( desired != applied )); then status=WARN; summary='日志策略 revision 尚未应用'
  elif [[ "$env_match" != true ]]; then status=FAIL; summary='日志策略与 .env 投影不一致'
  elif [[ "$(jq -r '.state' <<< "$compose")" == invalid ]]; then status=FAIL; summary='Compose 日志/执行策略无法解析'
  elif [[ "$(jq -r '.state' <<< "$compose")" == configured ]] \
    && ! jq -e '
      all(.services[]; .logging_wired == true) and
      .n8n.prune_wired == true and .n8n.max_age_wired == true and
      .n8n.save_success_wired == true and .n8n.save_error_wired == true
    ' >/dev/null <<< "$compose"; then status=FAIL; summary='Compose 容量或 n8n execution 保留设置未应用'
  elif [[ "$(jq -r '.state' <<< "$actual")" == checked && "$(jq -r '.matched' <<< "$actual")" != true ]]; then status=FAIL; summary='运行中容器日志容量与当前策略不一致'
  elif [[ "$(jq -r '.state' <<< "$n8n")" == checked ]] \
    && ! jq -e --arg hours "$hours" '.prune=="true" and .max_age_hours==$hours and .save_success=="none" and .save_error=="none"' >/dev/null <<< "$n8n"; then
    status=FAIL; summary='运行中 n8n execution 保存/清理策略不一致'
  elif [[ "$(jq -r '.unsafe_entries' <<< "$usage")" != 0 ]]; then status=FAIL; summary='受管日志路径发现链接或特殊条目'
  elif (( $(jq -r '.managed_bytes' <<< "$usage") > max_bytes * (files + 2) )); then status=WARN; summary='受管日志占用超过当前策略的预期余量'
  elif [[ "$(jq -r '.systemd_available' <<< "$timer")" != true ]]; then status=WARN; summary='当前环境没有可用 systemd，自动按天清理待接入'
  elif [[ "$(jq -r '.owned and .enabled and .active' <<< "$timer")" != true ]]; then status=WARN; summary='日志维护 timer 未完整启用'
  else summary='日志策略、容量、n8n execution 隐私设置和自动清理接线一致'; fi

  jq -M -cn --arg checked_at "$(logs_now)" --arg status "$status" --arg summary "$summary" \
    --argjson configured "$configured" --argjson env_match "$env_match" --argjson policy "$config" \
    --argjson compose "$compose" --argjson runtime_containers "$actual" --argjson runtime_n8n "$n8n" \
    --argjson timer "$timer" --argjson usage "$usage" \
    '{schema_version:1,checked_at:$checked_at,status:$status,summary:$summary,configured:$configured,
      env_projection_matched:$env_match,policy:$policy,compose:$compose,runtime:{containers:$runtime_containers,n8n:$runtime_n8n},
      timer:$timer,usage:$usage,boundaries:{docker_logpath:"never_accessed",journal_vacuum:"never_run",n8n_execution_sql:"never_deleted",analytics:"managed_separately"}}'
}

logs_print_audit() {
  local report=$1
  if (( LOGS_JSON )); then
    jq -M '.' <<< "$report"
  else
    jq -M -r '
      "日志维护状态：\(.status) — \(.summary)",
      "策略：保留 \(.policy.retention_days) 天；单文件 \(.policy.max_size_mib) MiB；保留 \(.policy.max_files) 份；revision \(.policy.revision)/\(.policy.applied_revision)",
      "受管文件占用：\(.usage.managed_bytes) bytes；Docker 日志占用：未知（不读取内部 LogPath）",
      "自动清理：" + (if .timer.systemd_available then (if .timer.active then "已启用" else "未启用" end) else "当前环境无 systemd" end) + "；最近完成：\(.timer.last_cleanup)",
      "边界：analytics 独立保留；n8n execution 由官方 prune 设置管理；不执行全局 journal/Docker 清理。"
    ' <<< "$report"
  fi
}

logs_status() {
  local report status
  report=$(logs_audit_json)
  logs_print_audit "$report"
  status=$(jq -r '.status' <<< "$report")
  [[ "$status" == FAIL ]] && return 1
  [[ "$status" == WARN ]] && return 2
  return 0
}

logs_show_sources() {
  local sources
  sources=$(logs_sources_json)
  if (( LOGS_JSON )); then
    jq -M -cn --argjson sources "$sources" '{schema_version:1,sources:$sources}'
  else
    jq -M -r '.[] | "\(.id)\t\(.name)\t\(.type)\t" + (if .available then "可用" else "未就绪" end) + (if .note=="" then "" else "\t\(.note)" end)' <<< "$sources"
  fi
}

logs_since_seconds() {
  local number unit
  [[ -n "$LOGS_SINCE" ]] || { printf '0\n'; return; }
  number=${LOGS_SINCE%?}; unit=${LOGS_SINCE: -1}
  case "$unit" in s) ;; m) number=$((10#$number * 60)) ;; h) number=$((10#$number * 3600)) ;; d) number=$((10#$number * 86400)) ;; esac
  printf '%s\n' "$number"
}

logs_show_file_jsonl() {
  local file=$1 seconds cutoff=0
  seconds=$(logs_since_seconds)
  (( seconds == 0 )) || cutoff=$(( $(date -u '+%s') - seconds ))
  python3 - "$file" "$LOGS_LINES" "$cutoff" <<'PY' | logs_redact display
import collections, datetime, json, os, pathlib, stat, sys
path = pathlib.Path(sys.argv[1]); limit = int(sys.argv[2]); cutoff = int(sys.argv[3])
rows = collections.deque(maxlen=limit)
try:
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
except FileNotFoundError:
    descriptor = None
except OSError:
    raise SystemExit("日志文件类型不安全")
if descriptor is not None:
    info = os.fstat(descriptor)
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
        os.close(descriptor)
        raise SystemExit("日志文件不是单链接普通文件")
    with os.fdopen(descriptor, "r", encoding="utf-8", errors="replace") as handle:
      for raw in handle:
        line = raw.rstrip("\r\n")
        if len(line) > 131072:
            line = line[:131072] + "[单行已截断]"
        if cutoff:
            try:
                stamp = json.loads(line).get("at", "")
                when = int(datetime.datetime.fromisoformat(stamp.replace("Z", "+00:00")).timestamp())
            except (ValueError, TypeError, json.JSONDecodeError):
                continue
            if when < cutoff:
                continue
        rows.append(line)
for row in rows:
    print(row)
PY
}

logs_show_doctor_history() {
  local output="${LOGS_TEMP_ROOT}/doctor-history.jsonl" file
  [[ ! -e "$LOGS_ROOT/doctor-history" \
    || -d "$LOGS_ROOT/doctor-history" && ! -L "$LOGS_ROOT/doctor-history" ]] \
    || die '自检历史目录不安全'
  : > "$output"
  shopt -s nullglob
  for file in "$LOGS_ROOT"/doctor-history/doctor-[0-9]*.json "$LOGS_ROOT"/doctor-[0-9]*.json; do
    logs_safe_regular_file "$file" || die '自检历史包含链接、硬链接或特殊文件'
    jq -M -c '{checked_at,scope,version,summary}' "$file" 2>/dev/null >> "$output" || true
  done
  shopt -u nullglob
  tail -n "$LOGS_LINES" "$output" | logs_redact display
}

logs_show_container() {
  local service=$1 arguments=(logs --tail "$LOGS_LINES" --no-color)
  [[ -z "$LOGS_SINCE" ]] || arguments+=(--since "$LOGS_SINCE")
  arguments+=("$service")
  require_docker_runtime
  # shellcheck disable=SC2016 # 位置参数由受限子 shell 展开。
  logs_timeout 20 bash -c 'source "$1"; shift; docker_compose "$1" "${@:2}"' \
    logs-show "$LOGS_SCRIPT_DIR/common.sh" "$LOGS_DEPLOY_DIR" "${arguments[@]}" \
    </dev/null 2>&1 | logs_redact display
}

logs_show_journal() {
  local unit since_args=() seconds
  unit="$(logs_timer_identity).service"
  command -v journalctl >/dev/null 2>&1 || die '当前系统没有 journalctl'
  if [[ -n "$LOGS_SINCE" ]]; then
    seconds=$(logs_since_seconds)
    since_args=(--since "@$(($(date -u '+%s') - seconds))")
  fi
  logs_timeout 20 journalctl --no-pager --output short-iso --unit "$unit" \
    --lines "$LOGS_LINES" "${since_args[@]}" 2>&1 | logs_redact display
}

logs_show_policy_source() {
  local config analytics_days
  config=$(logs_config_or_default)
  case "$LOGS_SOURCE" in
    n8n-executions)
      jq -M -n --arg hours "$(( $(jq -r '.retention_days' <<< "$config") * 24 ))" \
        '{source:"n8n-executions",save_success:"none",save_error:"none",prune:true,max_age_hours:($hours|tonumber),note:"仅由 n8n 官方 pruning 删除已完成记录；不直接 SQL 删除活跃执行"}'
      ;;
    analytics)
      analytics_days=$(jq -r '.feedback.retention_days // 30' "$LOGS_DEPLOY_DIR/config/feedback.yaml" 2>/dev/null || printf 30)
      jq -M -n --arg days "$analytics_days" '{source:"analytics",retention_days:($days|tonumber),note:"业务统计数据；由 runtime 独立保留，不受运维日志清理影响"}'
      ;;
  esac
}

logs_show() {
  [[ -n "$LOGS_SOURCE" ]] || logs_parameter_error 'show 需要 SOURCE'
  case "$LOGS_SOURCE" in
    maintenance) logs_show_file_jsonl "$LOGS_ROOT/maintenance.jsonl" ;;
    doctor-cache)
      logs_safe_regular_file "$LOGS_ROOT/doctor-last.json" || die '尚无安全的自检缓存'
      jq -M '.' "$LOGS_ROOT/doctor-last.json" | logs_redact display
      ;;
    doctor-history) logs_show_doctor_history ;;
    provider-adapter|postgres|anythingllm|n8n|caddy) logs_show_container "$LOGS_SOURCE" ;;
    log-maintenance) logs_show_journal ;;
    n8n-executions|analytics) logs_show_policy_source ;;
  esac
}

logs_follow() {
  local arguments unit seconds
  [[ -n "$LOGS_SOURCE" ]] || logs_parameter_error 'follow 需要 SOURCE'
  case "$LOGS_SOURCE" in
    maintenance)
      logs_safe_regular_file "$LOGS_ROOT/maintenance.jsonl" || die '尚无安全的维护事件日志'
      printf '正在跟踪维护事件；按 Ctrl+C 返回。\n' >&2
      tail -n "$LOGS_LINES" -F -- "$LOGS_ROOT/maintenance.jsonl" | logs_redact display
      ;;
    provider-adapter|postgres|anythingllm|n8n|caddy)
      require_docker_runtime
      arguments=(logs --follow --tail "$LOGS_LINES" --no-color)
      [[ -z "$LOGS_SINCE" ]] || arguments+=(--since "$LOGS_SINCE")
      arguments+=("$LOGS_SOURCE")
      printf '正在跟踪容器日志；按 Ctrl+C 返回。\n' >&2
      docker_compose "$LOGS_DEPLOY_DIR" "${arguments[@]}" 2>&1 | logs_redact display
      ;;
    log-maintenance)
      command -v journalctl >/dev/null 2>&1 || die '当前系统没有 journalctl'
      unit="$(logs_timer_identity).service"; arguments=(--follow --no-pager --output short-iso --unit "$unit" --lines "$LOGS_LINES")
      if [[ -n "$LOGS_SINCE" ]]; then seconds=$(logs_since_seconds); arguments+=(--since "@$(($(date -u '+%s') - seconds))"); fi
      printf '正在跟踪本项目日志调度单元；按 Ctrl+C 返回。\n' >&2
      journalctl "${arguments[@]}" 2>&1 | logs_redact display
      ;;
    *) die '该来源不支持 follow；不会跟踪业务数据或执行正文' ;;
  esac
}

logs_rotate_file_locked() {
  local file=$1 max_files=$2 index history_files candidate suffix
  [[ ! -e "$file" ]] || logs_safe_regular_file "$file" || return 1
  [[ -e "$file" ]] || { install -m 0600 /dev/null "$file"; return 0; }
  # 与 Docker json-file 的 max-file 语义一致：总份数包含当前文件。
  history_files=$((max_files - 1))
  shopt -s nullglob
  for candidate in "${file}".[1-9]*; do
    suffix=${candidate##*.}
    [[ "$suffix" =~ ^[1-9][0-9]*$ ]] || { shopt -u nullglob; return 1; }
    if (( 10#$suffix > history_files )); then
      logs_safe_regular_file "$candidate" || { shopt -u nullglob; return 1; }
      rm -f -- "$candidate"
    fi
  done
  shopt -u nullglob
  if (( history_files == 0 )); then
    : > "$file"
    chmod 0600 "$file"
    return 0
  fi
  for ((index=history_files; index>=1; index--)); do
    if (( index == history_files )); then
      [[ ! -e "${file}.${index}" ]] || { logs_safe_regular_file "${file}.${index}" || return 1; rm -f -- "${file}.${index}"; }
    else
      [[ ! -e "${file}.${index}" ]] || { logs_safe_regular_file "${file}.${index}" || return 1; mv -f -- "${file}.${index}" "${file}.$((index+1))"; }
    fi
  done
  [[ ! -s "$file" ]] || mv -f -- "$file" "${file}.1"
  install -m 0600 /dev/null "$file"
}

logs_lock() {
  local lock="$LOGS_ROOT/.log-maintenance.lock"
  [[ ! -e "$lock" ]] || logs_safe_regular_file "$lock" || die '日志维护锁路径不安全'
  exec {LOGS_LOCK_FD}> "$lock"
  flock -w 10 "$LOGS_LOCK_FD" || die '另一个日志维护任务正在运行'
}

logs_event() {
  local config max_size max_files file entry version
  [[ "$LOGS_ACTION" =~ ^[a-z][a-z0-9_-]{0,31}$ ]] || logs_parameter_error 'event --action 只能是受限标识'
  [[ "$LOGS_PHASE" =~ ^[a-z][a-z0-9_-]{0,31}$ ]] || logs_parameter_error 'event --phase 只能是受限标识'
  if [[ ! "$LOGS_CODE" =~ ^(0|[1-9][0-9]{0,2})$ ]] || (( 10#$LOGS_CODE > 255 )); then
    logs_parameter_error 'event --code 必须是 0 到 255'
  fi
  config=$(logs_config_or_default); max_size=$(jq -r '.max_size_mib' <<< "$config"); max_files=$(jq -r '.max_files' <<< "$config")
  file="$LOGS_ROOT/maintenance.jsonl"; version=$(sed -n '1p' "$LOGS_DEPLOY_DIR/VERSION" 2>/dev/null || printf unknown)
  logs_lock
  if logs_safe_regular_file "$file" && (( $(stat -c '%s' "$file") >= max_size * 1024 * 1024 )); then
    logs_rotate_file_locked "$file" "$max_files" || die '维护事件日志轮转失败'
  fi
  [[ ! -e "$file" ]] || logs_safe_regular_file "$file" || die '维护事件日志路径不安全'
  entry=$(jq -M -cn --arg at "$(logs_now)" --arg action "$LOGS_ACTION" --arg phase "$LOGS_PHASE" \
    --arg code "$LOGS_CODE" --arg version "$version" \
    '{schema_version:1,at:$at,action:$action,phase:$phase,code:($code|tonumber),version:$version}')
  printf '%s\n' "$entry" >> "$file"
  chmod 0600 "$file"
}

logs_candidate_files() {
  local cutoff=$1 file links directory
  local -a candidates=()
  shopt -s nullglob
  candidates+=("$LOGS_ROOT"/maintenance.jsonl.[1-9]* "$LOGS_ROOT"/doctor-[0-9]*.json)
  for directory in "$LOGS_ROOT/doctor-history" "$LOGS_ROOT/diagnostics"; do
    if [[ -e "$directory" || -L "$directory" ]] && [[ ! -d "$directory" || -L "$directory" ]]; then
      printf 'unsafe\t%s\n' "$directory"
    elif [[ "$directory" == */doctor-history ]]; then
      candidates+=("$directory"/doctor-[0-9]*.json)
    else
      candidates+=("$directory"/crispai-diagnostics-[0-9]*.tar.gz)
    fi
  done
  for file in "${candidates[@]}"; do
    [[ -e "$file" ]] || continue
    [[ -f "$file" && ! -L "$file" ]] || { printf 'unsafe\t%s\n' "$file"; continue; }
    links=$(stat -c '%h' "$file" 2>/dev/null || printf 0)
    [[ "$links" == 1 ]] || { printf 'unsafe\t%s\n' "$file"; continue; }
    if [[ $(stat -c '%Y' "$file" 2>/dev/null || printf 0) -lt $cutoff ]]; then printf 'expired\t%s\n' "$file"; fi
  done
  shopt -u nullglob
}

logs_trim_count_locked() {
  local directory=$1 pattern=$2 keep=$3 file count=0
  local list="${LOGS_TEMP_ROOT}/trim.list"
  : > "$list"
  shopt -s nullglob
  for file in "$directory"/$pattern; do
    [[ -f "$file" && ! -L "$file" && "$(stat -c '%h' "$file" 2>/dev/null || true)" == 1 ]] || continue
    printf '%s\t%s\n' "$(stat -c '%Y' "$file" 2>/dev/null || printf 0)" "$file" >> "$list"
  done
  shopt -u nullglob
  count=$(wc -l < "$list")
  (( count > keep )) || return 0
  sort -n "$list" | head -n $((count-keep)) | cut -f 2- | while IFS= read -r file; do rm -f -- "$file"; done
}

logs_write_cleanup_result() {
  local removed=$1 bytes=$2 unsafe=$3 mode=$4 target temp
  target="$LOGS_ROOT/log-maintenance-last.json"
  temp=$(mktemp "$LOGS_ROOT/.log-maintenance-last.XXXXXX")
  jq -M -n --arg completed_at "$(logs_now)" --arg mode "$mode" --arg removed "$removed" \
    --arg bytes "$bytes" --arg unsafe "$unsafe" \
    '{schema_version:1,completed_at:$completed_at,mode:$mode,removed_files:($removed|tonumber),removed_bytes:($bytes|tonumber),unsafe_entries:($unsafe|tonumber),business_state_changed:false}' > "$temp"
  chmod 0600 "$temp"; mv -f -- "$temp" "$target"
}

logs_cleanup() {
  local config days files cutoff list="${LOGS_TEMP_ROOT}/cleanup.list" kind file count=0 bytes=0 unsafe=0 size
  config=$(logs_config_or_default); days=${LOGS_DAYS:-$(jq -r '.retention_days' <<< "$config")}; files=$(jq -r '.max_files' <<< "$config")
  if [[ ! "$days" =~ ^[1-9][0-9]{0,3}$ ]] || (( 10#$days > 3650 )); then logs_parameter_error 'cleanup --days 必须是 1 到 3650'; fi
  cutoff=$(( $(date -u '+%s') - days * 86400 ))
  logs_candidate_files "$cutoff" > "$list"
  while IFS=$'\t' read -r kind file; do
    [[ -n "$kind" ]] || continue
    if [[ "$kind" == unsafe ]]; then ((unsafe += 1)); continue; fi
    ((count += 1)); size=$(stat -c '%s' "$file" 2>/dev/null || printf 0); [[ "$size" =~ ^[0-9]+$ ]] || size=0; ((bytes += size))
  done < "$list"
  if (( LOGS_APPLY == 0 )); then
    if (( LOGS_JSON )); then jq -M -n --arg count "$count" --arg bytes "$bytes" --arg unsafe "$unsafe" --arg days "$days" \
      '{schema_version:1,preview:true,retention_days:($days|tonumber),expired_files:($count|tonumber),expired_bytes:($bytes|tonumber),unsafe_entries:($unsafe|tonumber)}'
    else printf '预览：%s 个受管历史文件（%s bytes）已超过 %s 天；不安全条目 %s。未执行删除。\n' "$count" "$bytes" "$days" "$unsafe"; fi
    (( unsafe == 0 )) || return 2
    return 0
  fi
  logs_lock
  while IFS=$'\t' read -r kind file; do
    [[ "$kind" == expired ]] || continue
    [[ -f "$file" && ! -L "$file" && "$(stat -c '%h' "$file" 2>/dev/null || true)" == 1 ]] || { ((unsafe += 1)); continue; }
    rm -f -- "$file"
  done < "$list"
  mkdir -p -- "$LOGS_ROOT/doctor-history" "$LOGS_ROOT/diagnostics"
  [[ ! -L "$LOGS_ROOT/doctor-history" && ! -L "$LOGS_ROOT/diagnostics" ]] || die '日志历史目录不安全'
  logs_trim_count_locked "$LOGS_ROOT/doctor-history" 'doctor-[0-9]*.json' "$files"
  logs_trim_count_locked "$LOGS_ROOT/diagnostics" 'crispai-diagnostics-[0-9]*.tar.gz' "$files"
  logs_write_cleanup_result "$count" "$bytes" "$unsafe" "$([[ $LOGS_SCHEDULED == 1 ]] && printf scheduled || printf manual)"
  flock -u "$LOGS_LOCK_FD"
  LOGS_ACTION=log_cleanup LOGS_PHASE=complete LOGS_CODE=0 logs_event
  if (( LOGS_JSON )); then jq -M -n --arg count "$count" --arg bytes "$bytes" --arg unsafe "$unsafe" \
    '{schema_version:1,applied:true,removed_files:($count|tonumber),removed_bytes:($bytes|tonumber),unsafe_entries:($unsafe|tonumber),business_state_changed:false}'
  else printf '清理完成：删除 %s 个过期受管历史文件（%s bytes）；业务状态、索引、analytics、备份和 Docker 日志未改动。\n' "$count" "$bytes"; fi
  (( unsafe == 0 )) || return 2
}

logs_rotate() {
  local config files path
  [[ "$LOGS_SOURCE" == maintenance ]] || die '只允许轮转 maintenance；容器日志由 Docker daemon 轮转，自检历史按策略整理'
  config=$(logs_config_or_default); files=$(jq -r '.max_files' <<< "$config"); path="$LOGS_ROOT/maintenance.jsonl"
  if (( LOGS_APPLY == 0 )); then printf '预览：将轮转受管维护事件日志并最多保留 %s 份（含当前文件）；未执行。\n' "$files"; return 0; fi
  logs_lock; logs_rotate_file_locked "$path" "$files" || die '维护日志轮转失败'; flock -u "$LOGS_LOCK_FD"
  LOGS_ACTION=log_rotate LOGS_PHASE=complete LOGS_CODE=0 logs_event
  printf '维护事件日志已安全轮转。\n'
}

logs_clear() {
  local path file temp count=0
  [[ -n "$LOGS_SOURCE" ]] || logs_parameter_error 'clear 需要 SOURCE'
  case "$LOGS_SOURCE" in
    provider-adapter|postgres|anythingllm|n8n|caddy)
      die '禁止清空 Docker 内部日志；可调整容量策略后由 Docker daemon 轮转'
      ;;
    n8n-executions|analytics|log-maintenance)
      die '该来源不属于可清空运维文件；请使用其独立保留策略，且不会执行 SQL、journal vacuum 或业务数据清空'
      ;;
    maintenance|doctor-cache|doctor-history) ;;
  esac
  if (( LOGS_APPLY == 0 )); then printf '预览：将清空选定的受管来源 %s；不会修改业务状态或容器内部日志。\n' "$LOGS_SOURCE"; return 0; fi
  logs_lock
  case "$LOGS_SOURCE" in
    maintenance)
      path="$LOGS_ROOT/maintenance.jsonl"; [[ ! -e "$path" ]] || logs_safe_regular_file "$path" || die '维护日志不安全'
      temp=$(mktemp "$LOGS_ROOT/.maintenance-clear.XXXXXX")
      chmod 0600 "$temp"; mv -f -- "$temp" "$path"
      ;;
    doctor-cache)
      path="$LOGS_ROOT/doctor-last.json"; [[ ! -e "$path" ]] || logs_safe_regular_file "$path" || die '自检缓存不安全'
      [[ ! -e "$path" ]] || rm -f -- "$path"
      ;;
    doctor-history)
      shopt -s nullglob
      for file in "$LOGS_ROOT"/doctor-history/doctor-[0-9]*.json "$LOGS_ROOT"/doctor-[0-9]*.json; do
        [[ -f "$file" && ! -L "$file" && "$(stat -c '%h' "$file" 2>/dev/null || true)" == 1 ]] || die '自检历史包含不安全条目'
        rm -f -- "$file"; ((count += 1))
      done
      shopt -u nullglob
      ;;
  esac
  flock -u "$LOGS_LOCK_FD"
  printf '已清空受管来源 %s；未触碰客户消息、会话状态、知识、analytics、备份或 Docker LogPath。\n' "$LOGS_SOURCE"
}

logs_write_policy() {
  local file=$1 days=$2 size=$3 files=$4 revision=$5 applied=$6 temp
  temp=$(mktemp "${file}.tmp.XXXXXX")
  jq -M -n --arg revision "$revision" --arg applied "$applied" --arg days "$days" --arg size "$size" --arg files "$files" --arg now "$(logs_now)" \
    '{schema_version:1,revision:($revision|tonumber),applied_revision:($applied|tonumber),retention_days:($days|tonumber),max_size_mib:($size|tonumber),max_files:($files|tonumber),timer_enabled:true,updated_at:$now}' > "$temp"
  chmod 0640 "$temp"; mv -f -- "$temp" "$file"
}

logs_project_env_apply() {
  local days=$1 size=$2 files=$3
  env_set "$LOGS_DEPLOY_DIR/.env" CRISPAI_LOG_RETENTION_DAYS "$days"
  env_set "$LOGS_DEPLOY_DIR/.env" CRISPAI_LOG_RETENTION_HOURS "$((days * 24))"
  env_set "$LOGS_DEPLOY_DIR/.env" CRISPAI_LOG_MAX_SIZE "${size}m"
  env_set "$LOGS_DEPLOY_DIR/.env" CRISPAI_LOG_MAX_FILES "$files"
}

logs_initialize() {
  local files env_days env_hours env_size
  case "$LOGS_PROFILE" in '' ) files='' ;; new) files=5 ;; upgrade-v1) files=3 ;; *) logs_parameter_error 'initialize --profile 必须是 new 或 upgrade-v1' ;; esac
  if logs_config_valid; then
    LOGS_DAYS=$(jq -r '.retention_days' "$LOGS_CONFIG"); LOGS_MAX_SIZE_MIB=$(jq -r '.max_size_mib' "$LOGS_CONFIG"); LOGS_MAX_FILES=$(jq -r '.max_files' "$LOGS_CONFIG")
  else
    if [[ -e "$LOGS_CONFIG" || -L "$LOGS_CONFIG" ]]; then
      [[ -f "$LOGS_CONFIG" && ! -L "$LOGS_CONFIG" ]] || die '日志配置路径不安全'
      die '已有 logging.yaml 结构无效；已原样保留，拒绝用 .env 或默认值覆盖，请先修复候选配置'
    fi
    env_days=$(env_get "$LOGS_DEPLOY_DIR/.env" CRISPAI_LOG_RETENTION_DAYS 2>/dev/null || true)
    env_hours=$(env_get "$LOGS_DEPLOY_DIR/.env" CRISPAI_LOG_RETENTION_HOURS 2>/dev/null || true)
    env_size=$(env_get "$LOGS_DEPLOY_DIR/.env" CRISPAI_LOG_MAX_SIZE 2>/dev/null || true)
    LOGS_MAX_FILES=$(env_get "$LOGS_DEPLOY_DIR/.env" CRISPAI_LOG_MAX_FILES 2>/dev/null || true)
    if [[ "$env_days" =~ ^[1-9][0-9]{0,3}$ && "$env_hours" =~ ^[1-9][0-9]{0,5}$ \
      && "$env_size" =~ ^([1-9][0-9]{0,3})m$ && "$LOGS_MAX_FILES" =~ ^[1-9][0-9]?$ ]] \
      && (( 10#$env_days <= 3650 && 10#$env_hours == 10#$env_days * 24 \
        && 10#${env_size%m} <= 1024 && 10#$LOGS_MAX_FILES <= 20 )); then
      LOGS_DAYS=$env_days; LOGS_MAX_SIZE_MIB=${env_size%m}
    elif [[ -n "$files" ]]; then
      LOGS_DAYS=7; LOGS_MAX_SIZE_MIB=10; LOGS_MAX_FILES=$files
    else
      die '日志配置不存在，且 .env 中四项 CRISPAI_LOG_* 投影不完整；安装/升级器必须先按来源版本写入受管默认值'
    fi
    logs_write_policy "$LOGS_CONFIG" "$LOGS_DAYS" "$LOGS_MAX_SIZE_MIB" "$LOGS_MAX_FILES" 1 1
  fi
  logs_project_env_apply "$LOGS_DAYS" "$LOGS_MAX_SIZE_MIB" "$LOGS_MAX_FILES"
  logs_config_valid || die '日志配置初始化回读失败'
  printf '日志策略已初始化并核对投影：%s 天 / %s MiB / %s 份。\n' "$LOGS_DAYS" "$LOGS_MAX_SIZE_MIB" "$LOGS_MAX_FILES"
}

logs_container_readback() {
  local expected_size=$1 expected_files=$2 expected_hours=$3 actual n8n
  actual=$(logs_actual_container_policy_json "$expected_size" "$expected_files")
  [[ "$(jq -r '.state' <<< "$actual")" == checked && "$(jq -r '.matched' <<< "$actual")" == true ]] || return 1
  n8n=$(logs_n8n_actual_json)
  jq -e --arg hours "$expected_hours" '.state=="checked" and .prune=="true" and .max_age_hours==$hours and .save_success=="none" and .save_error=="none"' \
    >/dev/null <<< "$n8n"
}

logs_configure() {
  local current days size files revision applied candidate status=0 health_status=0 access_mode
  logs_config_valid || die '日志策略缺失或损坏；先从正式版本配置恢复'
  current=$(jq -M -c '.' "$LOGS_CONFIG")
  days=${LOGS_DAYS:-$(jq -r '.retention_days' <<< "$current")}
  size=${LOGS_MAX_SIZE_MIB:-$(jq -r '.max_size_mib' <<< "$current")}
  files=${LOGS_MAX_FILES:-$(jq -r '.max_files' <<< "$current")}
  if [[ ! "$days" =~ ^[1-9][0-9]{0,3}$ ]] || (( 10#$days > 3650 )); then logs_parameter_error '--days 必须是 1 到 3650'; fi
  if [[ ! "$size" =~ ^[1-9][0-9]{0,3}$ ]] || (( 10#$size > 1024 )); then logs_parameter_error '--max-size-mib 必须是 1 到 1024'; fi
  if [[ ! "$files" =~ ^[1-9][0-9]?$ ]] || (( 10#$files > 20 )); then logs_parameter_error '--max-files 必须是 1 到 20'; fi
  revision=$(( $(jq -r '.revision' <<< "$current") + 1 )); applied=$(jq -r '.applied_revision' <<< "$current")
  candidate="${LOGS_TEMP_ROOT}/logging-candidate.json"
  logs_write_policy "$candidate" "$days" "$size" "$files" "$revision" "$applied"
  if (( LOGS_APPLY == 0 )); then
    if (( LOGS_JSON )); then jq -M -n --argjson current "$current" --slurpfile candidate "$candidate" '{preview:true,current:$current,candidate:$candidate[0],requires_container_recreate:true}'
    else printf '预览：%s 天 / %s MiB / %s 份；应用时仅重建本项目容器并做本地健康回读，不调用模型或发送客户消息。\n' "$days" "$size" "$files"; fi
    return 0
  fi
  (( EUID == 0 )) || die '应用日志策略需要 root；未修改任何配置'
  acquire_maintenance_lock "$LOGS_DEPLOY_DIR"
  LOGS_APPLY_CONFIG_BACKUP="${LOGS_TEMP_ROOT}/logging.before"; LOGS_APPLY_ENV_BACKUP="${LOGS_TEMP_ROOT}/env.before"
  install -m 0600 -- "$LOGS_CONFIG" "$LOGS_APPLY_CONFIG_BACKUP"
  install -m 0600 -- "$LOGS_DEPLOY_DIR/.env" "$LOGS_APPLY_ENV_BACKUP"
  LOGS_APPLY_ACTIVE=1
  install -m 0640 -- "$candidate" "$LOGS_CONFIG"
  logs_project_env_apply "$days" "$size" "$files"
  LOGS_APPLY_CHANGED=1
  require_docker_runtime
  # shellcheck disable=SC2016 # 位置参数由受限子 shell 展开。
  if ! logs_timeout 15 bash -c 'source "$1"; docker_compose "$2" config --quiet' logs-config "$LOGS_SCRIPT_DIR/common.sh" "$LOGS_DEPLOY_DIR" </dev/null >/dev/null 2>&1; then status=1; fi
  # shellcheck disable=SC2016 # 位置参数由受限子 shell 展开。
  access_mode=$(env_get "$LOGS_DEPLOY_DIR/.env" WEBHOOK_ACCESS_MODE 2>/dev/null || true)
  if (( status == 0 )); then
    if [[ "$access_mode" == managed_https ]]; then
      # shellcheck disable=SC2016 # 位置参数由受限子 shell 展开。
      logs_timeout 120 bash -c 'source "$1"; docker_compose "$2" --profile managed-https up -d --force-recreate' \
        logs-apply "$LOGS_SCRIPT_DIR/common.sh" "$LOGS_DEPLOY_DIR" </dev/null >/dev/null 2>&1 || status=1
    else
      # shellcheck disable=SC2016 # 位置参数由受限子 shell 展开。
      logs_timeout 120 bash -c 'source "$1"; docker_compose "$2" up -d --force-recreate' \
        logs-apply "$LOGS_SCRIPT_DIR/common.sh" "$LOGS_DEPLOY_DIR" </dev/null >/dev/null 2>&1 || status=1
    fi
  fi
  if (( status == 0 )) && ! logs_container_readback "${size}m" "$files" "$((days*24))"; then status=1; fi
  if (( status == 0 )); then
    logs_write_policy "$LOGS_CONFIG" "$days" "$size" "$files" "$revision" "$revision"
    bash "$LOGS_DEPLOY_DIR/scripts/healthcheck.sh" --deploy-dir "$LOGS_DEPLOY_DIR" --application >/dev/null 2>&1 || health_status=$?
    (( health_status == 0 )) || status=1
  fi
  if (( status != 0 )); then
    printf '日志策略应用或健康回读失败，正在恢复旧配置与容器运行代……\n' >&2
    if logs_restore_apply; then printf '旧日志策略已恢复并重新应用；业务配置未改变。\n' >&2; else printf '错误：旧运行代自动恢复不完整，请从完整快照成套恢复。\n' >&2; fi
    LOGS_APPLY_ACTIVE=0
    return 1
  fi
  LOGS_APPLY_CHANGED=0; LOGS_APPLY_ACTIVE=0
  LOGS_ACTION=log_policy LOGS_PHASE=complete LOGS_CODE=0 logs_event
  if (( LOGS_JSON )); then jq -M -n --slurpfile policy "$LOGS_CONFIG" '{applied:true,policy:$policy[0],readback:true,business_state_changed:false}'
  else printf '日志策略已保存、应用并回读：%s 天 / %s MiB / %s 份。项目容器已受控重建，会话与知识数据保持。\n' "$days" "$size" "$files"; fi
}

logs_record_doctor() {
  local target directory temp config files
  [[ -n "$LOGS_INPUT" ]] || logs_parameter_error 'record-doctor --input 需要安全普通文件'
  logs_safe_regular_file "$LOGS_INPUT" || logs_parameter_error 'record-doctor --input 需要单链接安全普通文件'
  (( $(stat -c '%s' "$LOGS_INPUT") <= 2097152 )) || die '自检报告过大，拒绝归档'
  jq -e '.schema_version == 1 and (.results | type == "array") and (.summary | type == "object")' "$LOGS_INPUT" >/dev/null 2>&1 || die '自检报告结构无效'
  directory="$LOGS_ROOT/doctor-history"; mkdir -p -- "$directory"; [[ -d "$directory" && ! -L "$directory" ]] || die '自检历史目录不安全'
  temp=$(mktemp "$directory/.doctor.XXXXXX")
  logs_redact export < "$LOGS_INPUT" > "$temp"
  jq -e '.schema_version == 1' "$temp" >/dev/null 2>&1 || { rm -f -- "$temp"; die '自检报告脱敏后无效'; }
  target="$directory/doctor-$(date -u '+%Y%m%dT%H%M%SZ')-$$.json"; chmod 0600 "$temp"; mv -- "$temp" "$target"
  config=$(logs_config_or_default); files=$(jq -r '.max_files' <<< "$config")
  logs_lock; logs_trim_count_locked "$directory" 'doctor-[0-9]*.json' "$files"; flock -u "$LOGS_LOCK_FD"
}

logs_export() {
  local staging archive partial status_json sources_json service log_file timer_unit secret_scan=0
  staging="${LOGS_TEMP_ROOT}/bundle"; mkdir -m 0700 -- "$staging" "$staging/containers"
  status_json=$(logs_audit_json); sources_json=$(logs_sources_json)
  jq -M -n --arg created_at "$(logs_now)" --arg version "$(sed -n '1p' "$LOGS_DEPLOY_DIR/VERSION")" \
    --argjson status "$status_json" --argjson sources "$sources_json" \
    '{schema_version:1,created_at:$created_at,version:$version,scope:"redacted-diagnostics",
      contains_secrets:false,contains_prompt_or_knowledge:false,contains_customer_transcript:false,
      status:$status,sources:$sources,
      exclusions:[".env","Prompt 与知识正文","runtime 会话/任务/offer","analytics 业务数据","数据库/WAL/备份","Docker LogPath"]}' > "$staging/manifest.json"
  if [[ -e "$LOGS_ROOT/doctor-last.json" || -L "$LOGS_ROOT/doctor-last.json" ]]; then
    logs_safe_regular_file "$LOGS_ROOT/doctor-last.json" || die '自检缓存路径不安全，拒绝导出'
    logs_redact export < "$LOGS_ROOT/doctor-last.json" > "$staging/doctor-last.json"
  fi
  if [[ -e "$LOGS_ROOT/maintenance.jsonl" || -L "$LOGS_ROOT/maintenance.jsonl" ]]; then
    logs_safe_regular_file "$LOGS_ROOT/maintenance.jsonl" || die '维护日志路径不安全，拒绝导出'
    tail -n 500 "$LOGS_ROOT/maintenance.jsonl" | logs_redact export > "$staging/maintenance.jsonl"
  fi
  if command -v docker >/dev/null 2>&1 && logs_timeout 5 docker info >/dev/null 2>&1; then
    for service in provider-adapter postgres anythingllm n8n caddy; do
      log_file="$staging/containers/${service}.log"
      # shellcheck disable=SC2016 # 位置参数由受限子 shell 展开。
      logs_timeout 8 bash -c 'source "$1"; docker_compose "$2" logs --tail 200 --no-color "$3"' \
        logs-export "$LOGS_SCRIPT_DIR/common.sh" "$LOGS_DEPLOY_DIR" "$service" </dev/null 2>&1 | logs_redact export > "$log_file" || true
      chmod 0600 "$log_file"
    done
  fi
  if command -v journalctl >/dev/null 2>&1; then
    timer_unit="$(logs_timer_identity).service"
    logs_timeout 5 journalctl --no-pager --output short-iso --unit "$timer_unit" --lines 100 2>&1 | logs_redact export > "$staging/log-maintenance.log" || true
  fi
  find "$staging" -type f -exec chmod 0600 {} +
  python3 - "$LOGS_DEPLOY_DIR/.env" "$LOGS_REDACTOR" "$staging" <<'PY' || secret_scan=$?
import importlib.util, pathlib, sys
env = pathlib.Path(sys.argv[1]); module_path = pathlib.Path(sys.argv[2]); root = pathlib.Path(sys.argv[3])
spec = importlib.util.spec_from_file_location("crispai_log_redact", module_path)
if spec is None or spec.loader is None: raise SystemExit(2)
module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
values = module.collect_secrets(module.parse_env(env))
for file in root.rglob("*"):
    if file.is_symlink(): raise SystemExit(2)
    if file.is_dir(): continue
    if not file.is_file(): raise SystemExit(2)
    data = file.read_bytes()
    if any(value.encode() in data for value in values):
        print(f"诊断包白名单文件仍含敏感变体：{file.relative_to(root)}", file=sys.stderr)
        raise SystemExit(3)
PY
  (( secret_scan == 0 )) || die '诊断包二次秘密扫描未通过，未生成归档'
  if [[ -z "$LOGS_OUTPUT" ]]; then
    mkdir -p -- "$LOGS_ROOT/diagnostics"; [[ -d "$LOGS_ROOT/diagnostics" && ! -L "$LOGS_ROOT/diagnostics" ]] || die '诊断目录不安全'
    archive="$LOGS_ROOT/diagnostics/crispai-diagnostics-$(date -u '+%Y%m%dT%H%M%SZ')-$$.tar.gz"
  else
    archive=$(realpath -m -- "$LOGS_OUTPUT")
    [[ "$archive" == *.tar.gz && ! -e "$archive" && -d "$(dirname -- "$archive")" && ! -L "$(dirname -- "$archive")" ]] || die '诊断包输出必须是不存在的 .tar.gz，且父目录为安全目录'
  fi
  [[ ! -L "$archive" ]] || die '诊断包目标不得是符号链接'
  partial="${archive}.partial-$$"; [[ ! -e "$partial" ]] || die '诊断包临时目标已存在'
  tar -C "$staging" -czf "$partial" .; chmod 0600 "$partial"; mv -- "$partial" "$archive"
  printf '脱敏诊断包：%s\n' "$archive"
}

logs_systemd_escape_value() {
  local value=$1
  value=${value//\\/\\\\}; value=${value//\"/\\\"}; value=${value//%/%%}
  printf '%s\n' "$value"
}

logs_timer_install() {
  local base marker systemd_dir service timer digest escaped_deploy escaped_script temp
  (( EUID == 0 )) || die '安装日志维护 timer 需要 root'
  command -v systemctl >/dev/null 2>&1 || { warn '当前环境没有 systemd，未安装自动清理 timer'; return 2; }
  [[ -d /run/systemd/system || "${CRISPAI_LOGS_SYSTEMD_TEST:-0}" == 1 ]] || { warn 'systemd 当前未运行，未安装自动清理 timer'; return 2; }
  systemd_dir=${CRISPAI_LOGS_SYSTEMD_DIR:-/etc/systemd/system}
  [[ "$systemd_dir" == /* && -d "$systemd_dir" && ! -L "$systemd_dir" ]] || die 'systemd 单元目录不安全'
  base=$(logs_timer_identity); marker=$(logs_timer_marker); service="$systemd_dir/${base}.service"; timer="$systemd_dir/${base}.timer"
  digest=$(printf '%s' "$LOGS_DEPLOY_DIR" | sha256sum | cut -d ' ' -f 1)
  for temp in "$service" "$timer"; do
    if [[ -e "$temp" ]] && { [[ ! -f "$temp" || -L "$temp" ]] \
      || ! grep -Fxq '# ai-support-log-maintenance/v1' "$temp" \
      || ! grep -Fxq "# deploy-sha256: ${digest}" "$temp"; }; then
      die "同名 systemd 单元不属于本实例：$temp"
    fi
  done
  escaped_deploy=$(logs_systemd_escape_value "$LOGS_DEPLOY_DIR"); escaped_script=$(logs_systemd_escape_value "$LOGS_DEPLOY_DIR/scripts/logs.sh")
  temp=$(mktemp "$systemd_dir/.${base}.service.XXXXXX")
  {
    printf '# ai-support-log-maintenance/v1\n# deploy-sha256: %s\n' "$digest"
    printf '[Unit]\nDescription=CrispAI managed operational log cleanup\nAfter=local-fs.target\n\n'
    printf '[Service]\nType=oneshot\nUMask=0077\nEnvironment="CRISP_AI_DEPLOY_DIR=%s"\nEnvironment="CRISP_AI_LOG_SCRIPT=%s"\n' "$escaped_deploy" "$escaped_script"
    # shellcheck disable=SC2016 # systemd 运行时展开受管 Environment 变量。
    printf 'ExecStart=/bin/bash ${CRISP_AI_LOG_SCRIPT} --deploy-dir ${CRISP_AI_DEPLOY_DIR} cleanup --apply --scheduled\n'
    printf 'NoNewPrivileges=true\nPrivateTmp=true\nProtectSystem=full\n'
  } > "$temp"
  chmod 0644 "$temp"; mv -f -- "$temp" "$service"
  temp=$(mktemp "$systemd_dir/.${base}.timer.XXXXXX")
  {
    printf '# ai-support-log-maintenance/v1\n# deploy-sha256: %s\n' "$digest"
    printf '[Unit]\nDescription=Run CrispAI operational log cleanup hourly\n\n'
    printf '[Timer]\nOnBootSec=5min\nOnUnitActiveSec=1h\nRandomizedDelaySec=5min\nPersistent=true\nUnit=%s.service\n\n[Install]\nWantedBy=timers.target\n' "$base"
  } > "$temp"
  chmod 0644 "$temp"; mv -f -- "$temp" "$timer"
  systemctl daemon-reload >/dev/null
  systemctl enable --now "${base}.timer" >/dev/null
  temp=$(mktemp "$LOGS_DEPLOY_DIR/config/.crispai-log-timer.XXXXXX")
  printf 'ai-support-log-maintenance/v1\ndeploy_sha256=%s\nunit=%s\n' "$digest" "$base" > "$temp"
  chmod 0600 "$temp"; mv -f -- "$temp" "$marker"
  logs_timer_status_json | jq -e '.owned and .enabled and .active' >/dev/null || die '日志维护 timer 安装后回读失败'
  printf '日志维护 timer 已启用：%s.timer\n' "$base"
}

logs_timer_remove() {
  local base marker systemd_dir service timer digest disable_rc=0 stop_rc=0 active_rc=0 enabled_rc=0 systemd_running=0
  (( EUID == 0 )) || die '移除日志维护 timer 需要 root'
  base=$(logs_timer_identity); marker=$(logs_timer_marker); systemd_dir=${CRISPAI_LOGS_SYSTEMD_DIR:-/etc/systemd/system}
  service="$systemd_dir/${base}.service"; timer="$systemd_dir/${base}.timer"; digest=$(printf '%s' "$LOGS_DEPLOY_DIR" | sha256sum | cut -d ' ' -f 1)
  [[ -f "$marker" && ! -L "$marker" ]] || { printf '本实例没有受管日志 timer。\n'; return 0; }
  if ! grep -Fxq 'ai-support-log-maintenance/v1' "$marker" || ! grep -Fxq "unit=${base}" "$marker"; then
    die '日志 timer 归属标记无效，拒绝删除'
  fi
  for file in "$service" "$timer"; do
    if [[ -e "$file" ]] && { [[ ! -f "$file" || -L "$file" ]] \
      || ! grep -Fxq '# ai-support-log-maintenance/v1' "$file" \
      || ! grep -Fxq "# deploy-sha256: ${digest}" "$file"; }; then
      die "systemd 单元归属不一致，拒绝删除：$file"
    fi
  done
  if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system || "${CRISPAI_LOGS_SYSTEMD_TEST:-0}" == 1 ]]; then
    systemd_running=1
    systemctl disable --now "${base}.timer" >/dev/null 2>&1 || disable_rc=$?
    systemctl stop "${base}.service" >/dev/null 2>&1 || stop_rc=$?
    systemctl is-active --quiet "${base}.timer" >/dev/null 2>&1 || active_rc=$?
    (( active_rc == 3 )) || die '日志 timer 停止回读失败；保留单元文件和归属标记'
    active_rc=0
    systemctl is-active --quiet "${base}.service" >/dev/null 2>&1 || active_rc=$?
    (( active_rc == 3 )) || die '日志清理 service 停止回读失败；保留单元文件和归属标记'
    systemctl is-enabled --quiet "${base}.timer" >/dev/null 2>&1 || enabled_rc=$?
    (( enabled_rc == 1 )) || die '日志 timer 禁用回读失败；保留单元文件和归属标记'
    if (( disable_rc != 0 || stop_rc != 0 )); then
      warn "systemd 停止命令曾返回非零（timer=${disable_rc}, service=${stop_rc}），但只读状态已确认禁用且停止"
    fi
  fi
  [[ ! -e "$service" ]] || rm -f -- "$service"
  [[ ! -e "$timer" ]] || rm -f -- "$timer"
  rm -f -- "$marker"
  if (( systemd_running )); then
    systemctl daemon-reload >/dev/null 2>&1 || die '单元文件已移除，但 systemd daemon-reload 失败，请修复 systemd 后复查'
    printf '仅已移除本实例拥有且已确认停止的日志维护 timer。\n'
  else
    printf 'systemd 未运行；已按归属离线移除本实例日志维护单元。\n'
  fi
}

logs_timer_command() {
  case "$LOGS_ACTION" in
    install) logs_timer_install ;;
    remove) logs_timer_remove ;;
    status)
      if (( LOGS_JSON )); then logs_timer_status_json; else logs_timer_status_json | jq -M -r '"单元：\(.unit).timer；归属：\(.owned)；启用：\(.enabled)；运行：\(.active)；最近清理：\(.last_cleanup)"'; fi
      ;;
    run) LOGS_APPLY=1; LOGS_SCHEDULED=1; logs_cleanup ;;
    *) logs_parameter_error 'timer 需要 install、remove、status 或 run' ;;
  esac
}

case "$LOGS_COMMAND" in
  sources) logs_show_sources ;;
  status|policy) logs_status ;;
  audit)
    audit=$(logs_audit_json); printf '%s\n' "$audit"
    case "$(jq -r '.status' <<< "$audit")" in PASS) exit 0 ;; WARN) exit 2 ;; *) exit 1 ;; esac
    ;;
  show) logs_show ;;
  follow) logs_follow ;;
  cleanup) logs_cleanup ;;
  rotate) logs_rotate ;;
  clear) logs_clear ;;
  configure) logs_configure ;;
  initialize) logs_initialize ;;
  event) logs_event ;;
  record-doctor) logs_record_doctor ;;
  export) logs_export ;;
  timer) logs_timer_command ;;
esac
