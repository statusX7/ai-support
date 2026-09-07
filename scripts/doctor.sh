#!/usr/bin/env bash
set -euo pipefail

DOCTOR_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
DOCTOR_DEPLOY_REQUEST=""
DOCTOR_SCOPE=default
DOCTOR_JSON=0
DOCTOR_FIX=0
DOCTOR_LAST=0
DOCTOR_INSTALLATION_IN_PROGRESS=0
DOCTOR_TOTAL_TIMEOUT=${CRISPAI_DOCTOR_TIMEOUT_SECONDS:-90}

doctor_usage() {
  cat <<'EOF'
用法：doctor.sh [--deploy-dir PATH] [--local|--full] [--json] [--fix]

默认检查本地组件，并对已配置的 Crisp / 公网入口做只读、非推理检查。
--local   只检查本地系统、配置和组件，不访问外部服务。
--full    增加一次受控的实际模型调用；该检查可能产生少量费用。
--json    stdout 只输出机器可读 JSON；说明信息写入 stderr。
--fix     只修复白名单内的依赖、受管入口、权限和已停止项目服务，再复查。
--last    查看上次自检缓存，不执行新检查。
--timeout N  设置本次总截止秒数（1～600；日常默认 90）。

退出码：0 无警告或失败；2 有警告/待接入；1 有故障；64 参数错误；130 中断。
EOF
}

doctor_parameter_error() {
  printf '错误：%s\n' "$*" >&2
  doctor_usage >&2
  exit 64
}

while (( $# > 0 )); do
  case "$1" in
    --deploy-dir)
      (( $# >= 2 )) || doctor_parameter_error '--deploy-dir 缺少参数'
      DOCTOR_DEPLOY_REQUEST=$2
      shift 2
      ;;
    --local)
      [[ "$DOCTOR_SCOPE" == default ]] || doctor_parameter_error '--local 与其他检查范围不能同时使用'
      DOCTOR_SCOPE=local
      shift
      ;;
    --full)
      [[ "$DOCTOR_SCOPE" == default ]] || doctor_parameter_error '--full 与其他检查范围不能同时使用'
      DOCTOR_SCOPE=full
      shift
      ;;
    --offline)
      [[ "$DOCTOR_SCOPE" == default ]] || doctor_parameter_error '--offline 与其他检查范围不能同时使用'
      DOCTOR_SCOPE=offline
      shift
      ;;
    --json) DOCTOR_JSON=1; shift ;;
    --fix) DOCTOR_FIX=1; shift ;;
    --last) DOCTOR_LAST=1; shift ;;
    --installation-in-progress) DOCTOR_INSTALLATION_IN_PROGRESS=1; shift ;;
    --timeout)
      (( $# >= 2 )) || doctor_parameter_error '--timeout 缺少参数'
      DOCTOR_TOTAL_TIMEOUT=$2
      shift 2
      ;;
    --help|-h) doctor_usage; exit 0 ;;
    --version)
      if [[ -f "${DOCTOR_DIR}/../VERSION" ]]; then
        printf '%s\n' "$(<"${DOCTOR_DIR}/../VERSION")"
      else
        printf '%s\n' 'unknown'
      fi
      exit 0
      ;;
    *) doctor_parameter_error "未知选项：$1" ;;
  esac
done

if [[ ! "$DOCTOR_TOTAL_TIMEOUT" =~ ^[1-9][0-9]{0,3}$ ]] \
  || (( 10#$DOCTOR_TOTAL_TIMEOUT > 600 )); then
  doctor_parameter_error '--timeout 必须是 1 到 600 秒的整数'
fi
(( DOCTOR_LAST == 0 || DOCTOR_FIX == 0 )) || doctor_parameter_error '--last 不能与 --fix 同时使用'

# shellcheck source=scripts/common.sh disable=SC1091
source "${DOCTOR_DIR}/common.sh"

umask 077
DOCTOR_DEPLOY_DIR=$(resolve_deploy_dir "$DOCTOR_DEPLOY_REQUEST")
DOCTOR_STARTED_AT=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
DOCTOR_DEADLINE=$((SECONDS + 10#$DOCTOR_TOTAL_TIMEOUT))
DOCTOR_FAILURES=0
DOCTOR_WARNINGS=0
DOCTOR_PASSES=0
DOCTOR_SKIPS=0
DOCTOR_TEMP_ROOT=''
DOCTOR_RESULTS=''
DOCTOR_FIX_RESULTS=''
DOCTOR_BEFORE_SUMMARY='null'
DOCTOR_DOCKER_READY=0
DOCTOR_N8N_READY=0
DOCTOR_ANYTHING_READY=0
DOCTOR_PREBOOTSTRAP_JQ_FIXED=0
DOCTOR_EXPECTED_SERVICES=(postgres anythingllm n8n provider-adapter)

# shellcheck disable=SC2317
doctor_cleanup() {
  if [[ -n "$DOCTOR_TEMP_ROOT" && -d "$DOCTOR_TEMP_ROOT" && ! -L "$DOCTOR_TEMP_ROOT" ]]; then
    find "$DOCTOR_TEMP_ROOT" -depth -delete 2>/dev/null || true
  fi
}

# shellcheck disable=SC2317
doctor_interrupted() {
  printf '\n自检已中断；业务配置和会话状态未改动。\n' >&2
  exit 130
}

trap doctor_cleanup EXIT
trap doctor_interrupted INT TERM

doctor_cache_file() {
  printf '%s/logs/doctor-last.json\n' "$DOCTOR_DEPLOY_DIR"
}

doctor_render_text() {
  local report=$1 cached=${2:-0}
  jq -M -r --argjson cached "$cached" '
    if $cached == 1 then "CrispAI 上次自检（缓存）：\(.checked_at)\n范围：\(.scope)\n"
    else "CrispAI 组件自检 \(.version)\n范围：\(.scope)；检测时间：\(.checked_at)\n" end,
    (.results[] | "[\(.status)] \(.name)：\(.summary)" +
      (if (.suggestion // "") == "" then "" else "\n  建议：\(.suggestion)" end)),
    (if (.fix.actions // [] | length) > 0 then
      "修复动作：", (.fix.actions[] | "[\(.status)] \(.name)：\(.summary)")
     else empty end),
    "结果：通过 \(.summary.pass)，警告 \(.summary.warn)，失败 \(.summary.fail)，跳过 \(.summary.skip)。"
  ' "$report"
}

doctor_cached_exit() {
  local report=$1 failures warnings
  failures=$(jq -r '.summary.fail // 1' "$report")
  warnings=$(jq -r '.summary.warn // 0' "$report")
  if (( failures > 0 )); then return 1; fi
  if (( warnings > 0 )); then return 2; fi
  return 0
}

DOCTOR_PREBOOTSTRAP_STATE=$(installation_state "$DOCTOR_DEPLOY_DIR")
if ! command -v jq >/dev/null 2>&1; then
  # --fix 是唯一允许产生系统变更的诊断模式。缺少 jq 时先调用既有、受管的
  # bootstrap 补齐依赖；其输出只写 stderr，避免污染 --json 的 stdout。
  if (( DOCTOR_FIX )) && [[ "$DOCTOR_PREBOOTSTRAP_STATE" =~ ^(ready|local-ready)$ ]] \
    && (( EUID == 0 )) && command -v timeout >/dev/null 2>&1 \
    && [[ -x "${DOCTOR_DEPLOY_DIR}/scripts/bootstrap.sh" ]]; then
    printf '自检缺少 jq，正在通过受管依赖引导器尝试安全补齐……\n' >&2
    timeout --signal=TERM --kill-after=5s 300s \
      bash "${DOCTOR_DEPLOY_DIR}/scripts/bootstrap.sh" --all >&2 || true
    command -v jq >/dev/null 2>&1 && DOCTOR_PREBOOTSTRAP_JQ_FIXED=1
  fi
fi

if ! command -v jq >/dev/null 2>&1; then
  if (( DOCTOR_JSON )); then
    printf '%s\n' '{"schema_version":1,"scope":"bootstrap","results":[{"id":"system.commands","name":"基础命令","status":"FAIL","severity":"critical","summary":"缺少 jq，无法执行结构化自检","checked_at":"unknown","duration_ms":0,"source":"host","scope":"local","state":"checked","suggestion":"运行 crispai doctor --fix 自动补齐依赖","remediation":"运行 crispai doctor --fix 自动补齐依赖"}],"summary":{"pass":0,"warn":0,"fail":1,"skip":0}}'
  else
    printf '[FAIL] 基础命令：缺少 jq，无法执行结构化自检。\n' >&2
    printf '建议：运行 crispai doctor --fix 自动补齐依赖。\n' >&2
  fi
  exit 1
fi

if (( DOCTOR_LAST )); then
  DOCTOR_CACHE=$(doctor_cache_file)
  if [[ ! -f "$DOCTOR_CACHE" || -L "$DOCTOR_CACHE" ]] \
    || ! jq -e '.schema_version == 1 and (.results | type == "array") and (.summary | type == "object")' \
      "$DOCTOR_CACHE" >/dev/null 2>&1; then
    printf '尚无有效的自检缓存；请先运行 crispai doctor。\n' >&2
    exit 1
  fi
  if (( DOCTOR_JSON )); then jq -M '.' "$DOCTOR_CACHE"; else doctor_render_text "$DOCTOR_CACHE" 1; fi
  doctor_cached_exit "$DOCTOR_CACHE"
  exit $?
fi

DOCTOR_TEMP_ROOT=$(mktemp -d /tmp/crispai-doctor.XXXXXXXX)
chmod 0700 "$DOCTOR_TEMP_ROOT"
DOCTOR_RESULTS="${DOCTOR_TEMP_ROOT}/results.jsonl"
DOCTOR_FIX_RESULTS="${DOCTOR_TEMP_ROOT}/fix.jsonl"
DOCTOR_RESTARTABLE_SERVICES="${DOCTOR_TEMP_ROOT}/restartable-services"
: > "$DOCTOR_RESULTS"
: > "$DOCTOR_FIX_RESULTS"
: > "$DOCTOR_RESTARTABLE_SERVICES"

doctor_now_ms() {
  local value
  value=$(date -u '+%s%3N' 2>/dev/null || true)
  if [[ "$value" =~ ^[0-9]{13}$ ]]; then printf '%s\n' "$value"; else printf '%s000\n' "$(date -u '+%s')"; fi
}

doctor_remaining() {
  local remaining=$((DOCTOR_DEADLINE - SECONDS))
  (( remaining > 0 )) || return 1
  printf '%s\n' "$remaining"
}

doctor_timeout() {
  local requested=$1 remaining
  shift
  remaining=$(doctor_remaining) || return 124
  (( requested < remaining )) || requested=$remaining
  timeout --signal=TERM --kill-after=2s "${requested}s" "$@"
}

# coreutils timeout 不能直接执行当前 shell 的函数；在受限子 shell 中重新加载
# common.sh，才能对 docker_compose 的整次调用施加真实截止时间。
# shellcheck disable=SC2016
doctor_compose_timeout() {
  local requested=$1 remaining
  shift
  remaining=$(doctor_remaining) || return 124
  (( requested < remaining )) || requested=$remaining
  timeout --signal=TERM --kill-after=2s "${requested}s" bash -c '
    set -euo pipefail
    source "$1"
    deploy_dir=$2
    shift 2
    docker_compose "$deploy_dir" "$@"
  ' doctor-compose "${DOCTOR_DIR}/common.sh" "$DOCTOR_DEPLOY_DIR" "$@"
}

doctor_deadline_add() {
  local id=$1 name=$2 source=$3 start=${4:-0}
  if (( DOCTOR_INSTALLATION_IN_PROGRESS )); then
    doctor_add "$id" "$name" FAIL critical '自检总截止时间已到，本项未完成；安装健康门禁不能据此放行' \
      "$source" '确认组件未卡住后，以更充足的显式自检预算重试' "$start"
  else
    doctor_add "$id" "$name" WARN warning '自检总截止时间已到，本项未完成；未据此判定组件故障' \
      "$source" '使用 --timeout 增加本次诊断预算后重试' "$start"
  fi
}

# 外部检查不能直接调用 common.sh 中可能自行重试的函数，否则已耗尽的总预算
# 仍可能再等待几十秒。这里用 doctor 自己拥有的临时文件和剩余截止执行同等只读协议。
DOCTOR_EXTERNAL_STATUS=000
doctor_crisp_api_probe() {
  local website config response status curl_rc=0
  website=$(env_get "${DOCTOR_DEPLOY_DIR}/.env" CRISP_WEBSITE_ID 2>/dev/null || true)
  if [[ ! "$website" =~ ^[A-Za-z0-9-]{8,128}$ ]]; then
    DOCTOR_EXTERNAL_STATUS=configuration
    return 1
  fi
  config="${DOCTOR_TEMP_ROOT}/crisp-api.conf"
  response="${DOCTOR_TEMP_ROOT}/crisp-api-response.json"
  : > "$config"; : > "$response"; chmod 0600 "$config" "$response"
  if ! crisp_write_auth_config "${DOCTOR_DEPLOY_DIR}/.env" "$config"; then
    DOCTOR_EXTERNAL_STATUS=configuration
    return 1
  fi
  status=$(doctor_timeout 20 curl -q --silent --output "$response" --write-out '%{http_code}' \
    --max-filesize 1048576 --connect-timeout 5 --max-time 18 --config "$config" \
    "https://api.crisp.chat/v1/website/${website}" 2>/dev/null) || curl_rc=$?
  : > "$config"
  if (( curl_rc == 124 || curl_rc == 137 )); then DOCTOR_EXTERNAL_STATUS=timeout; return 1; fi
  DOCTOR_EXTERNAL_STATUS=${status:-000}
  if [[ "$DOCTOR_EXTERNAL_STATUS" == 2?? ]] && jq -e --arg website "$website" \
    '.error == false and (.data | type == "object") and .data.website_id == $website' \
    "$response" >/dev/null 2>&1; then
    return 0
  fi
  [[ "$DOCTOR_EXTERNAL_STATUS" != 2?? ]] || DOCTOR_EXTERNAL_STATUS='invalid-response'
  return 1
}

doctor_webhook_probe() {
  local url response status curl_rc=0
  url=$(env_get "${DOCTOR_DEPLOY_DIR}/.env" WEBHOOK_PRODUCTION_URL 2>/dev/null || true)
  if [[ "$url" != https://*'/webhook/crisp-webhook' ]]; then
    DOCTOR_EXTERNAL_STATUS=configuration
    return 1
  fi
  response="${DOCTOR_TEMP_ROOT}/webhook-response.json"
  status=$(doctor_timeout 20 curl --silent --output "$response" --write-out '%{http_code}' \
    --connect-timeout 5 --max-time 18 --header 'Content-Type: application/json' --data '{}' \
    "$url" 2>/dev/null) || curl_rc=$?
  if (( curl_rc == 124 || curl_rc == 137 )); then DOCTOR_EXTERNAL_STATUS=timeout; return 1; fi
  DOCTOR_EXTERNAL_STATUS=${status:-000}
  [[ "$DOCTOR_EXTERNAL_STATUS" == 401 ]] \
    && jq -e '.accepted == false and .reason == "Webhook 校验失败"' "$response" >/dev/null 2>&1
}

# AnythingLLM 的工作区回读包含 Developer API Key，不能把 Key 放进受限子进程
# 的 argv。使用仅 doctor 可读的 curl config，并由统一剩余预算包住整个请求。
doctor_anything_workspace_probe() {
  local port=$1 key=$2 workspace=$3 response=$4 config status curl_rc=0 escaped_key
  if [[ ! "$port" =~ ^[0-9]{1,5}$ || ! "$workspace" =~ ^[A-Za-z0-9_-]{1,128}$ ]] \
    || is_placeholder "$key"; then
    printf '000\n'
    return
  fi
  escaped_key=$(curl_config_escape "$key") || { printf '000\n'; return; }
  config="${DOCTOR_TEMP_ROOT}/anything-workspace.conf"
  {
    printf 'header = "Accept: application/json"\n'
    printf 'header = "Authorization: Bearer %s"\n' "$escaped_key"
  } > "$config"
  chmod 0600 "$config" "$response" 2>/dev/null || true
  status=$(doctor_timeout 12 curl --silent --output "$response" --write-out '%{http_code}' \
    --connect-timeout 3 --max-time 10 --config "$config" \
    "http://127.0.0.1:${port}/api/v1/workspace/${workspace}" 2>/dev/null) || curl_rc=$?
  : > "$config"
  if (( curl_rc == 124 || curl_rc == 137 )); then printf '000\n'; else printf '%s\n' "${status:-000}"; fi
}

doctor_container_env_binding() {
  local service=$1 fields=$2 output=$3
  shift 3
  # 期望值只经 NUL 分隔的 stdin 进入容器；argv、日志与结果只有字段名和 matched。
  # shellcheck disable=SC2016
  printf '%s\0' "$@" | doctor_compose_timeout 15 exec -T "$service" node -e '
    const crypto=require("crypto"),fs=require("fs");
    const marker="CRISPAI_EXPECTED_ENV_BINDING";
    const fields=String(process.argv[1]||"").split(",").filter(Boolean);
    const values=fs.readFileSync(0).toString("utf8").split("\0");
    if(values.at(-1)==="") values.pop();
    const equal=(left,right)=>{const a=Buffer.from(String(left)),b=Buffer.from(String(right));return a.length===b.length&&crypto.timingSafeEqual(a,b);};
    if(!marker||fields.length!==values.length||!fields.every((field,index)=>equal(process.env[field]||"",values[index]))) process.exit(1);
    process.stdout.write("matched\n");
  ' "$fields" > "$output" 2>/dev/null && grep -Fxq matched "$output"
}

doctor_add() {
  local id=$1 name=$2 status=$3 severity=$4 summary=$5 source=$6 suggestion=${7:-} start_ms=${8:-0}
  local duration=0 finished fact_state=checked
  finished=$(doctor_now_ms)
  if [[ "$start_ms" =~ ^[0-9]+$ ]] && (( start_ms > 0 && finished >= start_ms )); then duration=$((finished-start_ms)); fi
  case "$status" in
    PASS) ((DOCTOR_PASSES += 1)) ;;
    WARN) ((DOCTOR_WARNINGS += 1)) ;;
    FAIL) ((DOCTOR_FAILURES += 1)) ;;
    SKIP) ((DOCTOR_SKIPS += 1)) ;;
    *) return 1 ;;
  esac
  case "$status" in
    WARN) fact_state=pending ;;
    SKIP)
      if [[ "$summary" == 因* || "$summary" == *安装健康门禁* ]]; then
        fact_state=pending
      else
        fact_state=not_applicable
      fi
      ;;
  esac
  jq -M -cn \
    --arg id "$id" --arg name "$name" --arg status "$status" --arg severity "$severity" \
    --arg summary "$summary" --arg checked_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --arg source "$source" --arg scope "$DOCTOR_SCOPE" --arg state "$fact_state" --arg suggestion "$suggestion" \
    --argjson duration_ms "$duration" \
    '{id:$id,name:$name,status:$status,severity:$severity,summary:$summary,checked_at:$checked_at,
      duration_ms:$duration_ms,source:$source,scope:$scope,state:$state,suggestion:$suggestion,remediation:$suggestion}' >> "$DOCTOR_RESULTS"
}

doctor_skip() {
  doctor_add "$1" "$2" SKIP info "$3" "$4" "${5:-}"
}

doctor_fix_add() {
  local id=$1 name=$2 status=$3 summary=$4
  jq -M -cn --arg id "$id" --arg name "$name" --arg status "$status" --arg summary "$summary" \
    '{id:$id,name:$name,status:$status,summary:$summary}' >> "$DOCTOR_FIX_RESULTS"
}

doctor_reset_results() {
  DOCTOR_FAILURES=0
  DOCTOR_WARNINGS=0
  DOCTOR_PASSES=0
  DOCTOR_SKIPS=0
  DOCTOR_DOCKER_READY=0
  DOCTOR_N8N_READY=0
  DOCTOR_ANYTHING_READY=0
  DOCTOR_EXPECTED_SERVICES=(postgres anythingllm n8n provider-adapter)
  : > "$DOCTOR_RESULTS"
  : > "$DOCTOR_RESTARTABLE_SERVICES"
}

doctor_installation_check() {
  local start marker version installed state
  start=$(doctor_now_ms)
  marker="${DOCTOR_DEPLOY_DIR}/${INSTALL_MARKER}"
  if [[ ! -f "$marker" || -L "$marker" ]] || [[ "$(sed -n '1p' "$marker" 2>/dev/null || true)" != ai-support ]]; then
    doctor_add installation.marker '安装归属' FAIL critical '部署目录缺少有效的 ai-support 安装标记' host '从正式发布入口初始化或恢复该实例' "$start"
    return
  fi
  version=$(sed -n '1p' "${DOCTOR_DEPLOY_DIR}/VERSION" 2>/dev/null || true)
  installed=$(sed -n 's/^installed_version=//p' "$marker" | head -n 1)
  state=$(installation_state "$DOCTOR_DEPLOY_DIR")
  if [[ ! "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    doctor_add installation.marker '安装归属' FAIL critical '安装标记与部署版本不一致' host '使用更新/回滚功能恢复完整的同代文件' "$start"
    return
  fi
  if [[ "$installed" != "$version" ]]; then
    if (( DOCTOR_INSTALLATION_IN_PROGRESS )) && [[ "$state" == installing ]] \
      && [[ "$installed" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      doctor_add installation.marker '安装归属' WARN warning \
        "正在从 ${installed} 更新到 ${version}，按新版本检查当前暂存代" host \
        '完成健康门禁后安装器会原子提交新版本标记' "$start"
    else
      doctor_add installation.marker '安装归属' FAIL critical '安装标记与部署版本不一致' host '使用更新/回滚功能恢复完整的同代文件' "$start"
    fi
    return
  fi
  case "$state" in
    ready) doctor_add installation.marker '安装归属' PASS critical "受管实例版本 ${version}，状态 ready" host '' "$start" ;;
    local-ready)
      if [[ "$DOCTOR_SCOPE" == local || "$DOCTOR_SCOPE" == offline ]]; then
        doctor_add installation.marker '安装归属' PASS critical "受管实例版本 ${version}，本地状态 local-ready" host '' "$start"
      else
        doctor_add installation.marker '安装归属' WARN warning "受管实例版本 ${version}，本地已就绪但外部接入待验证" host '完成 Crisp Hook/公网配置后运行完整自检' "$start"
      fi
      ;;
    collecting|installing|staged)
      if (( DOCTOR_INSTALLATION_IN_PROGRESS )); then
        doctor_add installation.marker '安装归属' WARN warning "安装阶段 ${state}，仅报告当前可检查事实" host '完成安装后重新运行自检' "$start"
      else
        doctor_add installation.marker '安装归属' FAIL critical "安装阶段 ${state} 尚未完成" host '使用同一安装命令继续，而非重建配置' "$start"
      fi
      ;;
    uninstalled-data-kept) doctor_add installation.marker '安装归属' FAIL critical '服务已安全卸载，数据仍保留' host '从正式发布入口在原路径恢复安装' "$start" ;;
    *) doctor_add installation.marker '安装归属' FAIL critical '安装状态字段无效' host '从备份恢复安装标记或重新安装程序文件' "$start" ;;
  esac
}

doctor_system_check() {
  local start id version machine status summary missing='' command_name free_mb free_inodes now_year
  start=$(doctor_now_ms)
  id=$(sed -n 's/^ID=//p' /etc/os-release 2>/dev/null | head -n 1 | tr -d '"' || true)
  version=$(sed -n 's/^VERSION_ID=//p' /etc/os-release 2>/dev/null | head -n 1 | tr -d '"' || true)
  machine=$(uname -m 2>/dev/null || true)
  status=PASS
  case "${id}:${version}:${machine}" in
    debian:12:x86_64|debian:13:x86_64|ubuntu:22.04:x86_64|ubuntu:24.04:x86_64) summary="受支持平台 ${id} ${version} amd64" ;;
    debian:12:aarch64|debian:13:aarch64|ubuntu:22.04:aarch64|ubuntu:24.04:aarch64)
      status=WARN; summary="受支持分支 ${id} ${version} arm64，尚无同等级整机验收" ;;
    *) status=WARN; summary="当前平台 ${id:-未知} ${version:-未知} ${machine:-未知} 不在已实测范围" ;;
  esac
  doctor_add system.platform '系统与架构' "$status" warning "$summary" host '生产部署优先使用 Debian 12 amd64' "$start"

  start=$(doctor_now_ms)
  for command_name in jq curl docker timeout sha256sum base64 realpath stat df find grep sed awk flock python3 cmp; do
    command -v "$command_name" >/dev/null 2>&1 || missing+=" ${command_name}"
  done
  if [[ -z "$missing" ]]; then
    doctor_add system.commands '必要命令' PASS critical '本地运行所需命令均可用' host '' "$start"
  else
    doctor_add system.commands '必要命令' FAIL critical "缺少命令：${missing# }" host '运行 crispai doctor --fix 自动补齐受支持依赖' "$start"
  fi

  start=$(doctor_now_ms)
  free_mb=$(df -Pm -- "$DOCTOR_DEPLOY_DIR" 2>/dev/null | awk 'NR==2 {print $4}' || true)
  free_inodes=$(df -Pi -- "$DOCTOR_DEPLOY_DIR" 2>/dev/null | awk 'NR==2 {print $4}' || true)
  if [[ "$free_mb" =~ ^[0-9]+$ && "$free_inodes" =~ ^[0-9]+$ ]]; then
    if (( free_mb < 512 || free_inodes < 10000 )); then
      doctor_add system.capacity '磁盘与 inode' FAIL critical "可用 ${free_mb} MiB / ${free_inodes} inode，空间不足" host '清理本实例可确认删除的旧备份或扩容；不要全局 Docker prune' "$start"
    elif (( free_mb < 2048 || free_inodes < 50000 )); then
      doctor_add system.capacity '磁盘与 inode' WARN warning "可用 ${free_mb} MiB / ${free_inodes} inode，余量偏低" host '在更新或重建索引前扩充空间' "$start"
    else
      doctor_add system.capacity '磁盘与 inode' PASS warning "可用 ${free_mb} MiB / ${free_inodes} inode" host '' "$start"
    fi
  else
    doctor_add system.capacity '磁盘与 inode' WARN warning '无法读取容量信息' host '检查部署目录与 df 权限' "$start"
  fi

  start=$(doctor_now_ms)
  now_year=$(date -u '+%Y' 2>/dev/null || printf 0)
  if [[ "$now_year" =~ ^[0-9]{4}$ ]] && (( 10#$now_year >= 2024 && 10#$now_year <= 2100 )); then
    doctor_add system.clock '系统时间' PASS warning "UTC 年份 ${now_year} 在合理范围" host '' "$start"
  else
    doctor_add system.clock '系统时间' WARN warning '系统时钟明显异常，TLS 与事件时间判断可能失效' host '先同步系统时钟，再检查公网和 Webhook' "$start"
  fi
}

doctor_files_and_config_check() {
  local start relative missing='' invalid='' env_mode runtime_mode secret_count=0 value launcher_path launcher_digest expected_digest backup_count=0
  local website tier hook_mode hook_secret identifier token auth expected_auth
  local -a required=(VERSION docker-compose.yml .env get.sh install.sh manage.sh update.sh uninstall.sh
    n8n/workflow.json n8n/runtime.js n8n/runtime-cli.js n8n/build-workflow.js n8n/web-chat.js
    config/app.yaml config/Caddyfile.example config/runtime.yaml config/provider.yaml config/prompt.md
    config/keyword.yaml config/menu.yaml config/handoff.yaml config/tags.yaml config/feedback.yaml
    config/logging.yaml
    scripts/common.sh scripts/healthcheck.sh scripts/doctor.sh scripts/bootstrap.sh scripts/wizard.sh
    scripts/package-release.sh scripts/backup.sh scripts/restore.sh scripts/analytics.sh scripts/snapshot.sh
    scripts/rollback.sh scripts/launcher.sh scripts/menu-ui.sh scripts/configuration.sh scripts/provider.sh
    scripts/provider-adapter.js scripts/knowledge.sh scripts/migration.sh scripts/crisp-settings.sh
    scripts/full-backup.sh scripts/archive-guard.py scripts/materials.sh scripts/logs.sh scripts/log-redact.py)
  start=$(doctor_now_ms)
  for relative in "${required[@]}"; do
    [[ -f "${DOCTOR_DEPLOY_DIR}/${relative}" && ! -L "${DOCTOR_DEPLOY_DIR}/${relative}" ]] || missing+=" ${relative}"
  done
  if [[ -z "$missing" ]]; then
    doctor_add installation.files '生产文件' PASS critical '全部必要生产模块均存在且不是符号链接' filesystem '' "$start"
  else
    doctor_add installation.files '生产文件' FAIL critical "缺失或不安全的生产文件：${missing# }" filesystem '从同版本完整发布包恢复程序文件' "$start"
  fi

  start=$(doctor_now_ms)
  for relative in runtime provider keyword menu handoff tags feedback logging; do
    jq -e 'type == "object"' "${DOCTOR_DEPLOY_DIR}/config/${relative}.yaml" >/dev/null 2>&1 || invalid+=" ${relative}.yaml"
  done
  if [[ -n "$invalid" ]]; then
    doctor_add config.syntax '配置格式' FAIL critical "无效 JSON 配置：${invalid# }" filesystem '从配置历史恢复后再应用；不要 source 配置文件' "$start"
  elif ! jq -e '.schema_version == 2 and (.enabled | type == "boolean") and (.revision | type == "number") and (.applied_revision | type == "number")' \
      "${DOCTOR_DEPLOY_DIR}/config/runtime.yaml" >/dev/null 2>&1; then
    doctor_add config.syntax '配置格式' FAIL critical 'runtime.yaml schema 或字段类型无效' filesystem '从配置历史恢复有效 schema' "$start"
  elif jq -e '.revision == .applied_revision' "${DOCTOR_DEPLOY_DIR}/config/runtime.yaml" >/dev/null 2>&1; then
    doctor_add config.syntax '配置格式' PASS critical '配置 schema 有效，desired/applied revision 一致' filesystem '' "$start"
  else
    doctor_add config.syntax '配置格式' WARN warning '配置 revision 尚未完成运行时应用' filesystem '使用配置菜单重新同步有效配置' "$start"
  fi

  start=$(doctor_now_ms)
  for relative in N8N_ENCRYPTION_KEY POSTGRES_PASSWORD ANYTHINGLLM_AUTH_TOKEN ANYTHINGLLM_JWT_SECRET \
    ANYTHINGLLM_SIG_KEY ANYTHINGLLM_SIG_SALT ANYTHINGLLM_API_KEY AI_API_KEY CRISP_TOKEN_IDENTIFIER \
    CRISP_TOKEN_KEY CRISP_AUTH_B64; do
    value=$(env_get "${DOCTOR_DEPLOY_DIR}/.env" "$relative" 2>/dev/null || true)
    if ! is_placeholder "$value"; then ((secret_count += 1)); fi
  done
  if (( secret_count == 11 )); then
    doctor_add config.secrets '必要秘密' PASS critical '11 项必要秘密均已受管设置（内容未读取输出）' filesystem '' "$start"
  else
    doctor_add config.secrets '必要秘密' FAIL critical "必要秘密已配置 ${secret_count}/11" filesystem '仅从相应配置入口补齐，不要在命令行或诊断包中粘贴密钥' "$start"
  fi

  start=$(doctor_now_ms)
  website=$(env_get "${DOCTOR_DEPLOY_DIR}/.env" CRISP_WEBSITE_ID 2>/dev/null || true)
  tier=$(env_get "${DOCTOR_DEPLOY_DIR}/.env" CRISP_TOKEN_TIER 2>/dev/null || true)
  hook_mode=$(env_get "${DOCTOR_DEPLOY_DIR}/.env" CRISP_HOOK_MODE 2>/dev/null || true)
  identifier=$(env_get "${DOCTOR_DEPLOY_DIR}/.env" CRISP_TOKEN_IDENTIFIER 2>/dev/null || true)
  token=$(env_get "${DOCTOR_DEPLOY_DIR}/.env" CRISP_TOKEN_KEY 2>/dev/null || true)
  auth=$(env_get "${DOCTOR_DEPLOY_DIR}/.env" CRISP_AUTH_B64 2>/dev/null || true)
  case "$hook_mode" in
    website) hook_secret=$(env_get "${DOCTOR_DEPLOY_DIR}/.env" CRISP_WEBSITE_HOOK_SECRET 2>/dev/null || true) ;;
    plugin) hook_secret=$(env_get "${DOCTOR_DEPLOY_DIR}/.env" CRISP_PLUGIN_SIGNING_SECRET 2>/dev/null || true) ;;
    *) hook_secret='' ;;
  esac
  expected_auth=''
  if command -v base64 >/dev/null 2>&1; then
    expected_auth=$(printf '%s' "${identifier}:${token}" | base64 | tr -d '\n')
  fi
  if [[ "$website" =~ ^[A-Za-z0-9-]{8,128}$ && ( "$tier" == website || "$tier" == plugin ) \
    && ( "$hook_mode" == website || "$hook_mode" == plugin ) ]] \
    && validate_env_value "$hook_secret" && (( ${#hook_secret} >= 16 )) && ! is_placeholder "$hook_secret" \
    && validate_env_value "$auth" && [[ "$auth" == "$expected_auth" ]]; then
    doctor_add config.crisp_mode 'Crisp 本地模式与秘密接线' PASS critical "Website、${tier} Token 与 ${hook_mode} Hook 配置一致（秘密未输出）" filesystem '' "$start"
  else
    doctor_add config.crisp_mode 'Crisp 本地模式与秘密接线' FAIL critical 'Website、Token tier、Hook 模式、对应 Secret 或 Basic 派生值不一致' filesystem '从 Crisp 接入菜单成组保存凭据与 Hook 模式；不要手工拆改 .env' "$start"
  fi

  start=$(doctor_now_ms)
  env_mode=$(stat -c '%a' "${DOCTOR_DEPLOY_DIR}/.env" 2>/dev/null || printf 777)
  runtime_mode=$(stat -c '%a' "${DOCTOR_DEPLOY_DIR}/data/runtime" 2>/dev/null || printf 777)
  if [[ "$env_mode" =~ ^[0-7]{3,4}$ && "$runtime_mode" =~ ^[0-7]{3,4}$ ]] \
    && (( (8#$env_mode & 077) == 0 && (8#$runtime_mode & 007) == 0 )); then
    doctor_add security.permissions '敏感文件权限' PASS critical '.env 与会话状态未向其他用户开放' filesystem '' "$start"
  else
    doctor_add security.permissions '敏感文件权限' FAIL critical '敏感配置或会话状态目录权限过宽' filesystem '运行 crispai doctor --fix 恢复受管权限' "$start"
  fi

  start=$(doctor_now_ms)
  launcher_path=/usr/local/bin/crispai
  if [[ -f "${DOCTOR_DEPLOY_DIR}/config/.crispai-launcher" && ! -L "${DOCTOR_DEPLOY_DIR}/config/.crispai-launcher" ]]; then
    IFS= read -r launcher_path < "${DOCTOR_DEPLOY_DIR}/config/.crispai-launcher" || true
  fi
  expected_digest=$(printf '%s' "$DOCTOR_DEPLOY_DIR" | sha256sum | cut -d ' ' -f 1)
  launcher_digest=$(sed -n 's/^# crispai-target-sha256: //p' "$launcher_path" 2>/dev/null | head -n 1 || true)
  if (( DOCTOR_INSTALLATION_IN_PROGRESS )) \
    && [[ ! -e "${DOCTOR_DEPLOY_DIR}/config/.crispai-launcher" \
      && ! -L "${DOCTOR_DEPLOY_DIR}/config/.crispai-launcher" ]]; then
    # The installer may have an explicit --command-path not registered yet.
    # Ownership/conflict checks remain mandatory when it creates that launcher.
    doctor_skip installation.launcher 'crispai 管理入口' '本实例尚未登记入口路径；安装器将在健康门禁后校验归属并创建入口' filesystem
  elif [[ "$launcher_path" == /* && -f "$launcher_path" && ! -L "$launcher_path" ]] \
    && grep -Fxq '# crispai-launcher: ai-support/v1' "$launcher_path" 2>/dev/null \
    && [[ "$launcher_digest" == "$expected_digest" ]]; then
    doctor_add installation.launcher 'crispai 管理入口' PASS warning '受管入口指向当前部署目录' filesystem '' "$start"
  elif [[ -e "$launcher_path" || -L "$launcher_path" ]]; then
    doctor_add installation.launcher 'crispai 管理入口' FAIL critical '入口存在但不属于当前实例或指向错误' filesystem '保留其他程序；从服务维护菜单处理入口冲突' "$start"
  elif (( DOCTOR_INSTALLATION_IN_PROGRESS )); then
    doctor_skip installation.launcher 'crispai 管理入口' '安装健康门禁早于受管入口创建，完成安装后再检查' filesystem
  else
    doctor_add installation.launcher 'crispai 管理入口' WARN warning '受管 crispai 入口缺失' filesystem '运行 crispai doctor --fix 尝试恢复入口' "$start"
  fi

  start=$(doctor_now_ms)
  backup_count=$(find "${DOCTOR_DEPLOY_DIR}/backups" -mindepth 1 -maxdepth 3 -type f ! -type l 2>/dev/null | wc -l)
  if (( backup_count > 0 )); then
    doctor_add maintenance.backup '最近备份' PASS warning "发现 ${backup_count} 个受限备份文件；未执行恢复性推断" filesystem '' "$start"
  elif (( DOCTOR_INSTALLATION_IN_PROGRESS )); then
    doctor_skip maintenance.backup '最近备份' '初始一致性备份将在安装健康门禁通过后创建' filesystem
  else
    doctor_add maintenance.backup '最近备份' WARN warning '尚未发现本机备份文件' filesystem '在重要配置或更新前创建一致性备份' "$start"
  fi

  start=$(doctor_now_ms)
  if jq -e '.enabled | type == "boolean"' "${DOCTOR_DEPLOY_DIR}/config/runtime.yaml" >/dev/null 2>&1 \
    && jq -e '.welcome.enabled | type == "boolean"' "${DOCTOR_DEPLOY_DIR}/config/menu.yaml" >/dev/null 2>&1 \
    && jq -e '.handoff.resume_after_seconds | type == "number" and . >= 0' "${DOCTOR_DEPLOY_DIR}/config/handoff.yaml" >/dev/null 2>&1; then
    value=$(jq -r 'if .enabled then "启用" else "停用（管理员设置）" end' "${DOCTOR_DEPLOY_DIR}/config/runtime.yaml")
    runtime_mode=$(jq -r 'if .welcome.enabled then "启用" else "停用" end' "${DOCTOR_DEPLOY_DIR}/config/menu.yaml")
    secret_count=$(jq -r '.handoff.resume_after_seconds' "${DOCTOR_DEPLOY_DIR}/config/handoff.yaml")
    doctor_add business.settings '业务开关与恢复' PASS info "客服 ${value}；欢迎语 ${runtime_mode}；自动恢复 ${secret_count} 秒" filesystem '' "$start"
  else
    doctor_add business.settings '业务开关与恢复' FAIL critical '业务开关或恢复参数格式无效' filesystem '从配置历史恢复有效值；自检不会自动开启客服或恢复会话' "$start"
  fi
}

doctor_service_record() {
  local service=$1 start output record state health container_id inspect_file oom restarting
  start=$(doctor_now_ms)
  output="${DOCTOR_TEMP_ROOT}/ps-${service}.json"
  if ! doctor_compose_timeout 12 ps --all --format json "$service" > "$output" 2>/dev/null; then
    doctor_add "container.${service}" "容器 ${service}" FAIL critical '无法读取当前项目容器状态' docker '检查 Docker daemon、Compose 项目和权限' "$start"
    return
  fi
  record=$(jq -cs '[.[] | if type == "array" then .[] else . end] | .[0] // null' "$output" 2>/dev/null || printf null)
  if [[ "$record" == null ]]; then
    doctor_add "container.${service}" "容器 ${service}" FAIL critical '项目容器不存在' docker '运行 crispai doctor --fix 启动当前实例服务' "$start"
    printf '%s\n' "$service" >> "$DOCTOR_RESTARTABLE_SERVICES"
    return
  fi
  state=$(jq -r '(.State // .state // "") | ascii_downcase' <<< "$record")
  health=$(jq -r '(.Health // .health // "") | ascii_downcase' <<< "$record")
  container_id=$(jq -r '.ID // .Id // ""' <<< "$record")
  if [[ "$state" != running ]]; then
    doctor_add "container.${service}" "容器 ${service}" FAIL critical "状态为 ${state:-未知}" docker '查看该服务脱敏日志；可用 --fix 启动已停止服务' "$start"
    printf '%s\n' "$service" >> "$DOCTOR_RESTARTABLE_SERVICES"
    return
  fi
  inspect_file="${DOCTOR_TEMP_ROOT}/inspect-${service}.json"
  oom=false; restarting=false
  if [[ -n "$container_id" ]] && doctor_timeout 8 docker inspect --format '{{json .State}}' "$container_id" > "$inspect_file" 2>/dev/null; then
    oom=$(jq -r '.OOMKilled == true' "$inspect_file" 2>/dev/null || printf false)
    restarting=$(jq -r '.Restarting == true' "$inspect_file" 2>/dev/null || printf false)
  fi
  if [[ "$oom" == true || "$restarting" == true ]]; then
    doctor_add "container.${service}" "容器 ${service}" FAIL critical '容器发生 OOM 或正在重启' docker '检查本实例日志、资源和退出原因' "$start"
  elif [[ "$health" == healthy ]]; then
    doctor_add "container.${service}" "容器 ${service}" PASS critical 'running 且 health=healthy' docker '' "$start"
  elif [[ "$health" == starting ]]; then
    doctor_add "container.${service}" "容器 ${service}" WARN warning 'running，健康检查仍在启动阶段' docker '稍后复查；若持续不变请查看该服务日志' "$start"
  elif [[ "$health" == unhealthy ]]; then
    doctor_add "container.${service}" "容器 ${service}" FAIL critical 'running 但 health=unhealthy' docker '查看该服务健康检查与脱敏日志' "$start"
  else
    doctor_add "container.${service}" "容器 ${service}" WARN warning 'running，但镜像未报告 Docker health 状态' docker '结合对应应用协议检查判断；不要只依赖 running' "$start"
  fi
}

doctor_container_file_binding() {
  local id=$1 name=$2 service=$3 host_file=$4 container_file=$5 marker=$6 start status output expected binding_rc=0
  start=$(doctor_now_ms)
  status=$(doctor_result_status "container.${service}")
  if [[ "$status" != PASS && "$status" != WARN ]]; then
    doctor_skip "$id" "$name" "因容器 ${service} 未正常运行，本次未读取挂载文件" docker
    return
  fi
  if [[ ! -f "$host_file" || -L "$host_file" || "$(stat -c '%h' -- "$host_file" 2>/dev/null || true)" != 1 ]]; then
    doctor_add "$id" "$name" FAIL critical '宿主受管文件缺失、为链接或存在额外硬链接' filesystem '从同版本正式包恢复受管文件后重新创建对应容器' "$start"
    return
  fi
  expected=$(sha256sum -- "$host_file" 2>/dev/null | cut -d ' ' -f 1 || true)
  if [[ ! "$expected" =~ ^[a-f0-9]{64}$ ]]; then
    doctor_add "$id" "$name" FAIL critical '无法计算宿主受管文件摘要' filesystem '核对受管文件权限与完整性' "$start"
    return
  fi
  output="${DOCTOR_TEMP_ROOT}/${id//./-}.txt"
  if [[ "$service" == caddy ]]; then
    # Caddy 镜像不依赖 Node；摘要只经 stdin 输入，容器只输出 matched。
    # shellcheck disable=SC2016 # $1/变量由容器内 sh 展开。
    printf '%s\n' "$expected" | doctor_compose_timeout 12 exec -T "$service" sh -ec '
      marker="CRISPAI_EXPECTED_FILE_BINDING_CADDY"
      IFS= read -r expected
      actual=$(sha256sum "$1")
      actual=${actual%% *}
      [ -n "$marker" ] && [ "$actual" = "$expected" ]
      printf "matched\n"
    ' sh "$container_file" > "$output" 2>/dev/null || binding_rc=$?
  else
    # provider-adapter 固定镜像提供 Node；恒定时间比较，不输出代码或摘要。
    printf '%s' "$expected" | doctor_compose_timeout 12 exec -T "$service" node -e '
      const crypto=require("crypto"),fs=require("fs");
      const marker=process.argv[2];
      const expected=fs.readFileSync(0,"utf8").trim();
      const actual=crypto.createHash("sha256").update(fs.readFileSync(process.argv[1])).digest("hex");
      const left=Buffer.from(actual),right=Buffer.from(expected);
      if(!marker||left.length!==right.length||!crypto.timingSafeEqual(left,right)) process.exit(1);
      process.stdout.write("matched\n");
    ' "$container_file" "$marker" > "$output" 2>/dev/null || binding_rc=$?
  fi
  if (( binding_rc == 0 )) && grep -Fxq matched "$output"; then
    doctor_add "$id" "$name" PASS critical '运行容器读取的单文件挂载与当前宿主受管文件逐字节一致' docker '' "$start"
  elif (( binding_rc == 124 || binding_rc == 137 )) || ! doctor_remaining >/dev/null 2>&1; then
    doctor_deadline_add "$id" "$name" docker "$start"
  else
    doctor_add "$id" "$name" FAIL critical '运行容器仍读取旧版或偏离的单文件挂载' docker '用受管安装/更新流程校验文件后强制重新创建该服务' "$start"
  fi
}

doctor_file_bindings_check() {
  local access_mode=$1
  doctor_container_file_binding provider.adapter_code_binding 'Provider adapter 程序运行代' \
    provider-adapter "${DOCTOR_DEPLOY_DIR}/scripts/provider-adapter.js" \
    /opt/crisp-ai/scripts/provider-adapter.js CRISPAI_EXPECTED_FILE_BINDING_PROVIDER
  if [[ "$access_mode" == managed_https ]]; then
    doctor_container_file_binding caddy.file_binding 'Caddy 配置运行代' caddy \
      "${DOCTOR_DEPLOY_DIR}/config/Caddyfile" /etc/caddy/Caddyfile CRISPAI_EXPECTED_FILE_BINDING_CADDY
  else
    doctor_skip caddy.file_binding 'Caddy 配置运行代' '当前使用已有外部反向代理，受管 Caddy 单文件挂载不适用' docker
  fi
}

doctor_docker_check() {
  local start endpoint access_mode service
  start=$(doctor_now_ms)
  if ! command -v docker >/dev/null 2>&1; then
    doctor_add docker.cli 'Docker CLI' FAIL critical 'Docker CLI 不可用' host '运行 crispai doctor --fix 自动补齐受支持的 Docker 组件' "$start"
    for service in "${DOCTOR_EXPECTED_SERVICES[@]}"; do doctor_skip "container.${service}" "容器 ${service}" '因 Docker CLI 缺失未检查' docker; done
    return
  fi
  if doctor_timeout 8 docker compose version >/dev/null 2>&1; then
    doctor_add docker.compose 'Docker Compose' PASS critical 'Compose 能力可用' docker '' "$start"
  else
    doctor_add docker.compose 'Docker Compose' FAIL critical 'Compose 插件不可用或超时' docker '运行 crispai doctor --fix 补齐受支持插件' "$start"
    return
  fi
  start=$(doctor_now_ms)
  if doctor_timeout 10 docker info >/dev/null 2>&1; then
    doctor_add docker.daemon 'Docker daemon' PASS critical 'daemon 可访问' docker '' "$start"
    DOCTOR_DOCKER_READY=1
  else
    doctor_add docker.daemon 'Docker daemon' FAIL critical 'daemon 不可访问、权限不足或响应超时' docker '检查 systemd 服务和当前用户权限；不要删除 Docker 数据目录' "$start"
    for service in "${DOCTOR_EXPECTED_SERVICES[@]}"; do doctor_skip "container.${service}" "容器 ${service}" '因 Docker daemon 不可用未检查' docker; done
    return
  fi
  start=$(doctor_now_ms)
  endpoint=$(doctor_timeout 8 docker context inspect --format '{{(index .Endpoints "docker").Host}}' 2>/dev/null || true)
  case "$endpoint" in
    unix://*|npipe://*) doctor_add docker.context 'Docker context' PASS critical '使用本机 Docker socket/context' docker '' "$start" ;;
    '') doctor_add docker.context 'Docker context' WARN warning '无法确认 Docker context 地址' docker '确认没有通过远程 daemon 使用本机 bind mount' "$start" ;;
    *) doctor_add docker.context 'Docker context' FAIL critical '当前是远程 Docker context，无法安全使用本机 bind mount' docker '切换到当前服务器的本机 Docker context' "$start" ;;
  esac
  start=$(doctor_now_ms)
  if doctor_compose_timeout 15 config --quiet >/dev/null 2>&1; then
    doctor_add docker.configuration 'Compose 配置' PASS critical '当前 .env 与 Compose 可以解析' docker '' "$start"
  else
    doctor_add docker.configuration 'Compose 配置' FAIL critical 'Compose 配置无法解析' docker '修复对应配置；不要输出展开后的完整配置' "$start"
    return
  fi
  access_mode=$(env_get "${DOCTOR_DEPLOY_DIR}/.env" WEBHOOK_ACCESS_MODE 2>/dev/null || true)
  if [[ "$access_mode" == managed_https ]]; then DOCTOR_EXPECTED_SERVICES+=(caddy); fi
  for service in "${DOCTOR_EXPECTED_SERVICES[@]}"; do doctor_service_record "$service"; done
  if [[ "$access_mode" != managed_https ]]; then
    doctor_skip container.caddy '容器 caddy' '当前使用现有外部反向代理，受管 Caddy 不适用' docker
  fi
}

doctor_db_check() {
  local start output binding_output managed_user managed_db managed_password
  start=$(doctor_now_ms)
  if (( DOCTOR_DOCKER_READY == 0 )); then
    doctor_skip database.authentication 'PostgreSQL 应用认证' '因 Docker daemon 不可用未检查' docker
    doctor_skip database.n8n_binding 'n8n 数据库凭据接线' '因 Docker daemon 不可用未检查' docker
    return
  fi
  managed_user=$(env_get "${DOCTOR_DEPLOY_DIR}/.env" POSTGRES_USER 2>/dev/null || printf crisp_ai)
  managed_db=$(env_get "${DOCTOR_DEPLOY_DIR}/.env" POSTGRES_DB 2>/dev/null || printf n8n)
  managed_password=$(env_get "${DOCTOR_DEPLOY_DIR}/.env" POSTGRES_PASSWORD 2>/dev/null || true)
  if [[ ! "$managed_user" =~ ^[A-Za-z_][A-Za-z0-9_]{0,62}$ \
    || ! "$managed_db" =~ ^[A-Za-z_][A-Za-z0-9_]{0,62}$ ]] \
    || ! validate_env_value "$managed_password"; then
    doctor_add database.authentication 'PostgreSQL 应用认证' FAIL critical '当前受管数据库角色、库名或密码格式无效' filesystem '从成套备份恢复数据库凭据；不要在命令行中填写密码' "$start"
    doctor_skip database.n8n_binding 'n8n 数据库凭据接线' '因当前受管数据库凭据无效未检查' docker
    return
  fi
  output="${DOCTOR_TEMP_ROOT}/postgres-select.txt"
  # 密码只经 stdin 传入容器，不放入 argv、Compose 展开输出或诊断日志。
  # shellcheck disable=SC2016
  if printf '%s\n%s\n%s\n' "$managed_user" "$managed_db" "$managed_password" \
    | doctor_compose_timeout 15 exec -T postgres sh -ec '
        IFS= read -r managed_user
        IFS= read -r managed_db
        IFS= read -r managed_password
        export PGPASSWORD="$managed_password"
        # 必须经 Compose 服务名走 backend bridge；官方镜像的容器 loopback
        # 可能被 pg_hba.conf 配成 trust，使用 127.0.0.1 会让错误密码假通过。
        pg_isready -h postgres -U "$managed_user" -d "$managed_db" >/dev/null
        psql -h postgres -U "$managed_user" -d "$managed_db" -Atqc "SELECT 1"
      ' > "$output" 2>/dev/null \
    && [[ "$(tr -d '[:space:]' < "$output")" == 1 ]]; then
    doctor_add database.authentication 'PostgreSQL 应用认证' PASS critical '使用当前受管密码经 backend 网络完成应用角色 SELECT 1' docker '' "$start"
  else
    doctor_add database.authentication 'PostgreSQL 应用认证' FAIL critical '当前受管密码无法完成数据库应用角色认证/查询' docker '核对成套恢复的数据库角色密码；不要只看容器内旧环境或 pg_isready' "$start"
  fi

  start=$(doctor_now_ms)
  binding_output="${DOCTOR_TEMP_ROOT}/n8n-database-binding.txt"
  # 在 n8n 的实际进程环境中恒定时间比较当前期望值；只输出 matched，绝不输出凭据。
  # shellcheck disable=SC2016
  if printf '%s\n%s\n%s\n' "$managed_user" "$managed_db" "$managed_password" \
    | doctor_compose_timeout 15 exec -T n8n node -e '
        const crypto=require("crypto"), fs=require("fs");
        const expected=fs.readFileSync(0,"utf8").replace(/\n$/,"").split("\n");
        const actual=[process.env.DB_POSTGRESDB_USER||"",process.env.DB_POSTGRESDB_DATABASE||"",process.env.DB_POSTGRESDB_PASSWORD||""];
        const equal=(left,right)=>{const a=Buffer.from(left),b=Buffer.from(right);return a.length===b.length&&crypto.timingSafeEqual(a,b);};
        if(expected.length!==3||!expected.every((value,index)=>equal(value,actual[index]))) process.exit(1);
        process.stdout.write("matched\n");
      ' > "$binding_output" 2>/dev/null \
    && grep -Fxq matched "$binding_output"; then
    doctor_add database.n8n_binding 'n8n 数据库凭据接线' PASS critical 'n8n 运行环境的角色、库名和密码与当前受管配置一致' docker '' "$start"
  else
    doctor_add database.n8n_binding 'n8n 数据库凭据接线' FAIL critical 'n8n 运行环境与当前受管数据库凭据不一致' docker '通过成套更新/冷恢复重新创建 n8n；不要单独覆盖数据库密码' "$start"
  fi
}

doctor_projection_prompt_extract() {
  local projection=$1 output=$2
  python3 - "$projection" "$output" <<'PY'
import hashlib
import json
import os
import pathlib
import stat
import sys

source = pathlib.Path(sys.argv[1])
target = pathlib.Path(sys.argv[2])
try:
    metadata = source.lstat()
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1 or metadata.st_size > 16_777_216:
        raise ValueError("unsafe projection")
    value = json.loads(source.read_text(encoding="utf-8"))
    prompt = value.get("prompt")
    if value.get("schema_version") != 1 or value.get("state") != "applied" or not isinstance(prompt, dict):
        raise ValueError("invalid projection")
    text = prompt.get("text")
    if not isinstance(text, str) or not text.strip() or "\x00" in text:
        raise ValueError("invalid prompt")
    encoded = text.encode("utf-8")
    if len(encoded) != prompt.get("bytes"):
        raise ValueError("invalid prompt")
    if len(encoded) > 262_144 or hashlib.sha256(encoded).hexdigest() != prompt.get("sha256"):
        raise ValueError("invalid prompt digest")
    descriptor = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        os.write(descriptor, encoded)
    finally:
        os.close(descriptor)
except (OSError, UnicodeError, ValueError, TypeError, json.JSONDecodeError):
    raise SystemExit(1)
PY
}

doctor_legacy_prompt_extract() {
  local prompt=$1 output=$2
  python3 - "$prompt" "$output" <<'PY'
import os
import pathlib
import stat
import sys

source = pathlib.Path(sys.argv[1])
target = pathlib.Path(sys.argv[2])
try:
    metadata = source.lstat()
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1 or not 0 < metadata.st_size <= 262_144:
        raise ValueError("unsafe prompt")
    raw = source.read_bytes()
    text = raw.decode("utf-8", "strict")
    if not text.strip() or "\x00" in text:
        raise ValueError("invalid prompt")
    descriptor = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        os.write(descriptor, raw)
    finally:
        os.close(descriptor)
except (OSError, UnicodeError, ValueError):
    raise SystemExit(1)
PY
}

doctor_anything_check() {
  local start port key workspace response status workspace_item enabled_count pending_count failed_count garbage_count
  local actual_locations expected_locations mapping_summary mapping_invalid_count pending_document_count
  local projection expected_prompt prompt_source=projection prompt_valid=0
  if (( DOCTOR_DOCKER_READY == 0 )); then
    doctor_skip anything.ping 'AnythingLLM 服务' '因 Docker daemon 不可用未检查' local-api
    doctor_skip anything.workspace 'AnythingLLM 工作区与 Prompt' '因上游组件不可用未检查' local-api
    doctor_skip knowledge.catalog '知识库与索引' '因上游组件不可用未检查' filesystem
    return
  fi
  port=$(env_get "${DOCTOR_DEPLOY_DIR}/.env" ANYTHINGLLM_PORT 2>/dev/null || printf 3001)
  start=$(doctor_now_ms)
  if doctor_timeout 12 curl --silent --fail --connect-timeout 3 --max-time 10 \
      "http://127.0.0.1:${port}/api/ping" >/dev/null 2>&1; then
    doctor_add anything.ping 'AnythingLLM 服务' PASS critical '本机健康接口可用' local-api '' "$start"
    DOCTOR_ANYTHING_READY=1
  else
    doctor_add anything.ping 'AnythingLLM 服务' FAIL critical '本机健康接口不可用' local-api '检查容器 health、端口绑定与日志' "$start"
  fi
  start=$(doctor_now_ms)
  key=$(env_get "${DOCTOR_DEPLOY_DIR}/.env" ANYTHINGLLM_API_KEY 2>/dev/null || true)
  workspace=$(env_get "${DOCTOR_DEPLOY_DIR}/.env" ANYTHINGLLM_WORKSPACE 2>/dev/null || true)
  response="${DOCTOR_TEMP_ROOT}/anything-workspace.json"
  projection="${DOCTOR_DEPLOY_DIR}/config/materials-applied.json"
  expected_prompt="${DOCTOR_TEMP_ROOT}/anything-expected-prompt"
  # --fix 会在同一进程内复查一次；只删除本次 doctor 私有临时文件，
  # 避免第二轮因 O_EXCL 将有效投影误报为损坏。
  rm -f -- "$expected_prompt"
  if [[ -e "$projection" || -L "$projection" ]]; then
    if doctor_projection_prompt_extract "$projection" "$expected_prompt" >/dev/null 2>&1; then prompt_valid=1; fi
  else
    prompt_source=legacy
    if doctor_legacy_prompt_extract "${DOCTOR_DEPLOY_DIR}/config/prompt.md" "$expected_prompt" >/dev/null 2>&1; then prompt_valid=1; fi
  fi
  if (( DOCTOR_ANYTHING_READY )) && ! is_placeholder "$key" && [[ "$workspace" =~ ^[A-Za-z0-9_-]{1,128}$ ]]; then
    status=$(doctor_anything_workspace_probe "$port" "$key" "$workspace" "$response")
  else status=000; fi
  if (( prompt_valid )) && [[ "$status" == 2?? ]] \
    && workspace_item=$(jq -c '.workspace | if type == "array" then .[0] else . end' "$response" 2>/dev/null) \
    && jq -e --arg slug "$workspace" --rawfile prompt "$expected_prompt" \
      '.slug == $slug and .openAiPrompt == $prompt' <<< "$workspace_item" >/dev/null 2>&1; then
    if [[ "$prompt_source" == projection ]]; then
      doctor_add anything.workspace 'AnythingLLM 工作区与 Prompt' PASS critical 'Developer API 鉴权、目标工作区和已应用 Prompt 投影回读一致' local-api '' "$start"
    else
      doctor_add anything.workspace 'AnythingLLM 工作区与 Prompt' PASS critical 'Developer API 鉴权、目标工作区和 legacy Prompt 回读一致' local-api '' "$start"
    fi
  elif (( prompt_valid == 0 )) && [[ "$prompt_source" == projection ]]; then
    doctor_add anything.workspace 'AnythingLLM 工作区与 Prompt' FAIL critical '当前资料投影无效，拒绝回退使用可编辑 Prompt 原文判断运行状态' filesystem '恢复上一份有效资料投影或完成显式资料应用' "$start"
  else
    doctor_add anything.workspace 'AnythingLLM 工作区与 Prompt' FAIL critical "Developer API、工作区或 Prompt 回读失败（HTTP ${status:-000}）" local-api '从 Prompt/知识配置入口重新同步；不要重置管理员或 API Key' "$start"
  fi

  start=$(doctor_now_ms)
  if [[ ! -f "${DOCTOR_DEPLOY_DIR}/knowledge/catalog.json" || -L "${DOCTOR_DEPLOY_DIR}/knowledge/catalog.json" ]] \
    || ! jq -e '.schema_version == 2 and (.revision | type == "number") and (.libraries | type == "array") and
      ([.libraries[].id] | length == (unique | length)) and all(.libraries[]; (.enabled | type == "boolean") and (.documents | type == "array"))' \
      "${DOCTOR_DEPLOY_DIR}/knowledge/catalog.json" >/dev/null 2>&1; then
    doctor_add knowledge.catalog '知识库与索引' FAIL critical '多知识库 catalog 缺失或结构无效' filesystem '从业务配置备份恢复 catalog；不要自动重建全部索引' "$start"
    return
  fi
  enabled_count=$(jq '[.libraries[] | select(.enabled) | .documents[]] | length' "${DOCTOR_DEPLOY_DIR}/knowledge/catalog.json")
  failed_count=$(jq '[.libraries[] | select(.enabled) | select(.status == "failed" or (.documents[]?.index_status == "failed"))] | length' "${DOCTOR_DEPLOY_DIR}/knowledge/catalog.json")
  if [[ -f "${DOCTOR_DEPLOY_DIR}/data/knowledge-manifest.json" && ! -L "${DOCTOR_DEPLOY_DIR}/data/knowledge-manifest.json" ]]; then
    pending_count=$(jq '(.pending_files // {}) | length' "${DOCTOR_DEPLOY_DIR}/data/knowledge-manifest.json" 2>/dev/null || printf -1)
    garbage_count=$(jq '(.garbage_locations // []) | length' "${DOCTOR_DEPLOY_DIR}/data/knowledge-manifest.json" 2>/dev/null || printf -1)
    # 不能仅比较 expected/actual location 集合；若 manifest 丢失映射且
    # workspace 同时为空，两个空数组会相等并产生假 PASS。逐个启用文档
    # 必须有同 hash、非空 location 的已完成映射，或同等完整的 pending
    # 对账记录。后者是正常处理中，只能 WARN，不能被误判为损坏。
    mapping_summary=$(jq -c --slurpfile catalog "${DOCTOR_DEPLOY_DIR}/knowledge/catalog.json" '
      select((.files | type == "object") and ((.pending_files // {}) | type == "object")) |
      . as $manifest |
      [$catalog[0].libraries[] | select(.enabled) | .documents[] |
        . as $document |
        ($document.sha256 | type == "string" and test("^[a-f0-9]{64}$")) as $hash_valid |
        ($manifest.files[$document.projection] // null) as $indexed |
        (($manifest.pending_files // {})[$document.projection] // null) as $pending |
        {
          indexed:($hash_valid and ($indexed | type == "object") and
            $indexed.sha256 == $document.sha256 and
            ($indexed.locations | type == "array" and length > 0) and
            all($indexed.locations[]; type == "string" and length > 0)),
          pending:($hash_valid and ($pending | type == "object") and
            $pending.sha256 == $document.sha256 and
            ($pending.locations | type == "array" and length > 0) and
            all($pending.locations[]; type == "string" and length > 0))
        }
      ] | {
        invalid:(map(select((.indexed or .pending) | not)) | length),
        pending:(map(select((.indexed | not) and .pending)) | length)
      }' "${DOCTOR_DEPLOY_DIR}/data/knowledge-manifest.json" 2>/dev/null || true)
    if [[ -n "$mapping_summary" ]]; then
      mapping_invalid_count=$(jq -r '.invalid' <<< "$mapping_summary")
      pending_document_count=$(jq -r '.pending' <<< "$mapping_summary")
    else
      mapping_invalid_count=-1
      pending_document_count=-1
    fi
  else pending_count=-1; garbage_count=-1; mapping_invalid_count=-1; pending_document_count=-1; fi
  if (( failed_count > 0 || pending_count < 0 || garbage_count < 0 )); then
    doctor_add knowledge.catalog '知识库与索引' FAIL critical '启用知识库存在失败状态，或索引 manifest 无效' filesystem '从多知识库菜单查看失败项并执行指定库同步' "$start"
  elif (( mapping_invalid_count != 0 )); then
    doctor_add knowledge.catalog '知识库与索引' FAIL critical '启用文档缺少有效的索引映射、内容 hash 不一致或 location 为空' filesystem '从多知识库菜单同步对应库并回读；不要把空 workspace 当作已索引' "$start"
  elif (( enabled_count == 0 )); then
    doctor_add knowledge.catalog '知识库与索引' WARN warning '当前没有启用的知识文档；本地服务可继续运行' filesystem '按业务需要添加或启用知识；AI 不应编造业务事实' "$start"
  elif (( pending_count > 0 || pending_document_count > 0 )); then
    doctor_add knowledge.catalog '知识库与索引' WARN warning "${enabled_count} 个启用文档中有 ${pending_document_count} 个仍在服务端对账（pending 记录共 ${pending_count} 个）" filesystem '等待当前索引完成后复查；默认自检不会删除或重建' "$start"
  elif [[ "$status" == 2?? ]]; then
    actual_locations=$(jq -c '[.workspace | if type == "array" then .[] else . end | .documents[]?.docpath] | unique' "$response" 2>/dev/null || printf '[]')
    expected_locations=$(jq -cn --slurpfile catalog "${DOCTOR_DEPLOY_DIR}/knowledge/catalog.json" \
      --slurpfile manifest "${DOCTOR_DEPLOY_DIR}/data/knowledge-manifest.json" \
      '[$catalog[0].libraries[] | select(.enabled) | .documents[] | .projection as $p | $manifest[0].files[$p].locations[]?] | unique')
    if jq -en --argjson actual "$actual_locations" --argjson expected "$expected_locations" \
      '($actual | sort) == ($expected | sort)' >/dev/null 2>&1; then
      doctor_add knowledge.catalog '知识库与索引' PASS critical "${enabled_count} 个启用文档与实际 workspace 索引位置一致" local-api '' "$start"
    else
      doctor_add knowledge.catalog '知识库与索引' FAIL critical '启用/停用库与实际 workspace 索引位置不一致' local-api '从多知识库菜单同步指定库；不要直接删除 workspace 文档' "$start"
    fi
  else
    doctor_add knowledge.catalog '知识库与索引' WARN warning 'catalog 有效，但因 AnythingLLM 回读失败未确认实际索引' filesystem '先修复 AnythingLLM，再重新自检' "$start"
  fi
  if (( garbage_count > 0 )); then
    doctor_add knowledge.garbage '知识索引待清理项' WARN warning "存在 ${garbage_count} 个受管待清理 location" filesystem '从多知识库同步入口有界重试；默认自检不删除数据'
  else
    doctor_add knowledge.garbage '知识索引待清理项' PASS info '没有已记录的索引垃圾项' filesystem
  fi
}

doctor_n8n_check() {
  local start port response status workflow_output remaining
  if (( DOCTOR_DOCKER_READY == 0 )); then
    doctor_skip n8n.health 'n8n 服务' '因 Docker daemon 不可用未检查' local-api
    doctor_skip n8n.workflow 'n8n 生产工作流' '因 Docker daemon 不可用未检查' docker
    doctor_skip n8n.runtime 'n8n Code runner' '因 Docker daemon 不可用未检查' local-api
    return
  fi
  port=$(env_get "${DOCTOR_DEPLOY_DIR}/.env" N8N_PORT 2>/dev/null || printf 5678)
  start=$(doctor_now_ms)
  if doctor_timeout 12 curl --silent --fail --connect-timeout 3 --max-time 10 \
      "http://127.0.0.1:${port}/healthz/readiness" >/dev/null 2>&1; then
    doctor_add n8n.health 'n8n 服务' PASS critical '本机 readiness 接口可用' local-api '' "$start"
    DOCTOR_N8N_READY=1
  else
    doctor_add n8n.health 'n8n 服务' FAIL critical '本机 readiness 接口不可用' local-api '检查 n8n 容器、数据库连接与日志' "$start"
  fi
  start=$(doctor_now_ms)
  workflow_output="${DOCTOR_TEMP_ROOT}/workflow-check.txt"
  remaining=$(doctor_remaining 2>/dev/null || printf 0)
  if (( remaining < 8 )); then
    doctor_deadline_add n8n.workflow 'n8n 生产工作流' docker "$start"
    doctor_skip n8n.runtime 'n8n Code runner' '因自检总截止时间已到未检查' local-api
    return
  fi
  # shellcheck disable=SC2016
  if (( DOCTOR_N8N_READY )) && doctor_compose_timeout 25 exec -T n8n sh -ec '
    output=$(mktemp /tmp/crispai-doctor-workflow.XXXXXX)
    trap '\''rm -f "$output"'\'' EXIT
    timeout 20 n8n export:workflow --id="$1" --output="$output" >/dev/null 2>&1
    node - "$output" "$1" "$2" "$3" /opt/crisp-ai/n8n/runtime.js <<'\''NODE'\''
const fs=require("fs"),crypto=require("crypto");
const raw=JSON.parse(fs.readFileSync(process.argv[2],"utf8"));
const workflow=Array.isArray(raw)?raw[0]:raw;
const nodes=workflow.nodes||[];
const code=nodes.filter(node=>String(node.type).includes("code")).map(node=>node.parameters?.jsCode||"").join("\n");
const types=(workflow.nodes||[]).map(node=>String(node.type));
const schedule=nodes.find(node=>String(node.type).endsWith(".scheduleTrigger") && node.disabled!==true);
const scanner=nodes.find(node=>String(node.type).includes("code") && String(node.parameters?.jsCode||"").includes("runtime.scan"));
const scheduleTargets=(workflow.connections?.[schedule?.name]?.main||[]).flat().map(connection=>connection.node);
const runtimeFile=fs.readFileSync(process.argv[6],"utf8");
const source=runtimeFile.replace(/^if \(typeof module[^\n]+\n?$/m,"").replace(/ai_support_version: '\''v[^'\'']+'\''/g,"ai_support_version: '\''"+process.argv[4]+"'\''");
const sourceHash=crypto.createHash("sha256").update(source).digest("hex");
const fileHash=crypto.createHash("sha256").update(runtimeFile).digest("hex");
const runtimePrefix=source+"\nconst runtime = createRuntime($env);\n";
const runtimeNodeNames=["校验并持久接收","处理持久任务","扫描持久会话与任务","只读公开显示选项"];
const runtimeNodesMatch=runtimeNodeNames.every(name=>{
  const node=nodes.find(candidate=>candidate.name===name && String(candidate.type).includes("code"));
  return node && String(node.parameters?.jsCode||"").startsWith(runtimePrefix);
});
if (workflow.id!==process.argv[3] || workflow.active!==true || !types.some(type=>type.endsWith(".webhook")) ||
    !schedule || !scanner || !scheduleTargets.includes(scanner.name) || !code.includes("runtime.receive") ||
    !code.includes("runtime.process") || !code.includes("runtime.scan") ||
    workflow.meta?.aiSupportVersion!==process.argv[4] || workflow.meta?.runtimeFileSha256!==fileHash ||
    workflow.meta?.runtimeFileSha256!==process.argv[5] || workflow.meta?.runtimeSha256!==sourceHash ||
    !runtimeNodesMatch) process.exit(1);
process.stdout.write("verified\n");
NODE
  ' sh "$WORKFLOW_ID" "$(sed -n '1p' "${DOCTOR_DEPLOY_DIR}/VERSION")" \
    "$(sha256sum "${DOCTOR_DEPLOY_DIR}/n8n/runtime.js" | cut -d ' ' -f 1)" \
    < /dev/null > "$workflow_output" 2>/dev/null \
    && grep -Fxq verified "$workflow_output"; then
    doctor_add n8n.workflow 'n8n 生产工作流' PASS critical '目标 workflow 已激活，接收/处理/五秒扫描代码均存在' docker '' "$start"
  else
    if ! doctor_remaining >/dev/null 2>&1; then
      doctor_deadline_add n8n.workflow 'n8n 生产工作流' docker "$start"
      doctor_skip n8n.runtime 'n8n Code runner' '因自检总截止时间已到未检查' local-api
      return
    fi
    doctor_add n8n.workflow 'n8n 生产工作流' FAIL critical '目标 workflow 未激活、版本偏离或无法导出验证' docker '从受管安装/更新流程重新导入并发布目标 workflow' "$start"
  fi
  start=$(doctor_now_ms)
  if ! doctor_remaining >/dev/null 2>&1; then
    doctor_deadline_add n8n.runtime 'n8n Code runner' local-api "$start"
    return
  fi
  response="${DOCTOR_TEMP_ROOT}/n8n-runtime.json"
  status=$(doctor_timeout 15 curl --silent --output "$response" --write-out '%{http_code}' \
    --connect-timeout 3 --max-time 12 --header 'Content-Type: application/json' --data '{}' \
    "http://127.0.0.1:${port}/webhook/crisp-webhook?key=ai-support-healthcheck-invalid" 2>/dev/null || true)
  if [[ "$status" == 401 ]] && jq -e '.accepted == false and .reason == "Webhook 校验失败"' "$response" >/dev/null 2>&1; then
    doctor_add n8n.runtime 'n8n Code runner' PASS critical '生产 Webhook 到达项目 Code 并返回特有拒绝结构；未产生业务任务' local-api '' "$start"
  elif ! doctor_remaining >/dev/null 2>&1 && [[ -z "$status" || "$status" == 000 ]]; then
    doctor_deadline_add n8n.runtime 'n8n Code runner' local-api "$start"
  else
    doctor_add n8n.runtime 'n8n Code runner' FAIL critical "生产 Code 执行探针失败（HTTP ${status:-000}）" local-api '检查 workflow 发布状态、task runner 与生产 Webhook 路由' "$start"
  fi
}

doctor_adapter_check() {
  local start output mode configured_mode runtime_base configured_base configured_model runtime_model
  local header_json header_names vision configured_vision mode_capability hook_secret plugin_secret remaining
  start=$(doctor_now_ms)
  if ! jq -e '.schema_version == 2 and (.provider.base_url | type == "string" and length > 0) and
      (.provider.model | type == "string" and length > 0) and (.provider.api_mode == "chat_completions" or .provider.api_mode == "responses")' \
      "${DOCTOR_DEPLOY_DIR}/config/provider.yaml" >/dev/null 2>&1; then
    doctor_add provider.configuration 'Provider 配置接线' FAIL critical 'Provider 配置 schema、模型或协议无效' filesystem '从第三方 AI 菜单修复整组配置' "$start"
    doctor_skip provider.adapter 'Provider adapter' '因 Provider 配置无效未检查运行路径' docker
    doctor_skip provider.adapter_binding 'Provider adapter 运行代' '因 Provider 配置无效未核对运行容器环境' docker
    doctor_skip anything.provider_binding 'AnythingLLM Provider 运行代' '因 Provider 配置无效未核对运行容器环境' docker
    doctor_skip n8n.runtime_binding 'n8n AI/Crisp 运行代' '因 Provider 配置无效未核对运行容器环境' docker
    return
  fi
  configured_mode=$(jq -r '.provider.api_mode' "${DOCTOR_DEPLOY_DIR}/config/provider.yaml")
  configured_base=$(jq -r '.provider.base_url' "${DOCTOR_DEPLOY_DIR}/config/provider.yaml")
  configured_model=$(jq -r '.provider.model' "${DOCTOR_DEPLOY_DIR}/config/provider.yaml")
  mode=$(env_get "${DOCTOR_DEPLOY_DIR}/.env" AI_API_MODE 2>/dev/null || true)
  runtime_base=$(env_get "${DOCTOR_DEPLOY_DIR}/.env" AI_ANYTHINGLLM_BASE_URL 2>/dev/null || true)
  runtime_model=$(env_get "${DOCTOR_DEPLOY_DIR}/.env" AI_MODEL 2>/dev/null || true)
  header_json=$(env_get "${DOCTOR_DEPLOY_DIR}/.env" AI_CUSTOM_HEADERS_JSON 2>/dev/null || printf '{}')
  [[ -n "$header_json" ]] || header_json='{}'
  vision=$(env_get "${DOCTOR_DEPLOY_DIR}/.env" AI_SUPPORTS_VISION 2>/dev/null || true)
  if ! header_names=$(jq -M -c 'select(type == "object") | to_entries |
      if all(.[]; (.key | test("^[A-Za-z][A-Za-z0-9-]{0,99}$")) and (.value | type == "string"))
      then ([.[].key] | sort) else empty end' <<< "$header_json" 2>/dev/null); then
    header_names='invalid'
  fi
  configured_vision=$(jq -r '.provider.capabilities.vision' "${DOCTOR_DEPLOY_DIR}/config/provider.yaml")
  mode_capability=$(jq -r --arg mode "$configured_mode" '.provider.capabilities[$mode] // false' "${DOCTOR_DEPLOY_DIR}/config/provider.yaml")
  if [[ "$mode" != "$configured_mode" || "$runtime_base" != http://provider-adapter:8787/v1 \
    || "$(env_get "${DOCTOR_DEPLOY_DIR}/.env" AI_API_BASE_URL 2>/dev/null || true)" != "$configured_base" \
    || "$runtime_model" != "$configured_model" || "$header_names" == invalid \
    || "$vision" != "$configured_vision" || "$mode_capability" != true ]] \
    || ! jq -e --argjson names "$header_names" '((.provider.custom_header_names // []) | sort) == $names' \
      "${DOCTOR_DEPLOY_DIR}/config/provider.yaml" >/dev/null 2>&1; then
    doctor_add provider.configuration 'Provider 配置接线' FAIL critical '配置文件与运行环境的地址、模型、协议、Header 名称、视觉能力或 adapter 地址不一致' filesystem '从第三方 AI 菜单重新应用已验证的整组配置' "$start"
    doctor_skip provider.adapter 'Provider adapter' '因宿主受管配置不一致未检查运行路径' docker
    doctor_skip provider.adapter_binding 'Provider adapter 运行代' '因宿主受管配置不一致未核对运行容器环境' docker
    doctor_skip anything.provider_binding 'AnythingLLM Provider 运行代' '因宿主受管配置不一致未核对运行容器环境' docker
    doctor_skip n8n.runtime_binding 'n8n AI/Crisp 运行代' '因宿主受管配置不一致未核对运行容器环境' docker
    return
  fi
  doctor_add provider.configuration 'Provider 配置接线' PASS critical "地址、模型、协议 ${mode}、Header 名称和能力已绑定受管 adapter" filesystem '' "$start"
  start=$(doctor_now_ms)
  output="${DOCTOR_TEMP_ROOT}/adapter-health.txt"
  if (( DOCTOR_DOCKER_READY == 0 )); then
    doctor_skip provider.adapter 'Provider adapter' '因 Docker daemon 不可用未检查容器网络路径' docker
    doctor_skip provider.adapter_binding 'Provider adapter 运行代' '因 Docker daemon 不可用未检查' docker
    doctor_skip anything.provider_binding 'AnythingLLM Provider 运行代' '因 Docker daemon 不可用未检查' docker
    doctor_skip n8n.runtime_binding 'n8n AI/Crisp 运行代' '因 Docker daemon 不可用未检查' docker
    return
  fi

  remaining=$(doctor_remaining 2>/dev/null || printf 0)
  if (( remaining < 8 )); then
    doctor_skip provider.adapter_binding 'Provider adapter 运行代' '因自检总截止时间已到未检查' docker
    doctor_skip anything.provider_binding 'AnythingLLM Provider 运行代' '因自检总截止时间已到未检查' docker
    doctor_skip n8n.runtime_binding 'n8n AI/Crisp 运行代' '因自检总截止时间已到未检查' docker
    doctor_deadline_add provider.adapter 'Provider adapter' docker "$start"
    return
  fi

  start=$(doctor_now_ms)
  if doctor_container_env_binding provider-adapter \
    'AI_API_BASE_URL,AI_API_KEY,AI_MODEL,AI_API_MODE,AI_CUSTOM_HEADERS_JSON' \
    "${DOCTOR_TEMP_ROOT}/adapter-binding.txt" \
    "$(env_get "${DOCTOR_DEPLOY_DIR}/.env" AI_API_BASE_URL 2>/dev/null || true)" \
    "$(env_get "${DOCTOR_DEPLOY_DIR}/.env" AI_API_KEY 2>/dev/null || true)" \
    "$(env_get "${DOCTOR_DEPLOY_DIR}/.env" AI_MODEL 2>/dev/null || true)" \
    "$(env_get "${DOCTOR_DEPLOY_DIR}/.env" AI_API_MODE 2>/dev/null || true)" \
    "$(env_get "${DOCTOR_DEPLOY_DIR}/.env" AI_CUSTOM_HEADERS_JSON 2>/dev/null || true)"; then
    doctor_add provider.adapter_binding 'Provider adapter 运行代' PASS critical '运行容器的地址、Key、模型、协议和 Header 与当前受管配置一致' docker '' "$start"
  elif ! doctor_remaining >/dev/null 2>&1; then
    doctor_deadline_add provider.adapter_binding 'Provider adapter 运行代' docker "$start"
    doctor_skip anything.provider_binding 'AnythingLLM Provider 运行代' '因自检总截止时间已到未检查' docker
    doctor_skip n8n.runtime_binding 'n8n AI/Crisp 运行代' '因自检总截止时间已到未检查' docker
    doctor_deadline_add provider.adapter 'Provider adapter' docker
    return
  else
    doctor_add provider.adapter_binding 'Provider adapter 运行代' FAIL critical '运行容器仍持有旧版或偏离的 Provider 环境' docker '重新创建本实例 provider-adapter；不要只修改宿主 .env' "$start"
  fi

  start=$(doctor_now_ms)
  if doctor_container_env_binding anythingllm \
    'GENERIC_OPEN_AI_BASE_PATH,GENERIC_OPEN_AI_API_KEY,GENERIC_OPEN_AI_MODEL_PREF' \
    "${DOCTOR_TEMP_ROOT}/anything-binding.txt" \
    "$(env_get "${DOCTOR_DEPLOY_DIR}/.env" AI_ANYTHINGLLM_BASE_URL 2>/dev/null || true)" \
    "$(env_get "${DOCTOR_DEPLOY_DIR}/.env" AI_API_KEY 2>/dev/null || true)" \
    "$(env_get "${DOCTOR_DEPLOY_DIR}/.env" AI_MODEL 2>/dev/null || true)"; then
    doctor_add anything.provider_binding 'AnythingLLM Provider 运行代' PASS critical 'AnythingLLM 实际 Provider 地址、Key 和模型与当前受管配置一致' docker '' "$start"
  elif ! doctor_remaining >/dev/null 2>&1; then
    doctor_deadline_add anything.provider_binding 'AnythingLLM Provider 运行代' docker "$start"
    doctor_skip n8n.runtime_binding 'n8n AI/Crisp 运行代' '因自检总截止时间已到未检查' docker
    doctor_deadline_add provider.adapter 'Provider adapter' docker
    return
  else
    doctor_add anything.provider_binding 'AnythingLLM Provider 运行代' FAIL critical 'AnythingLLM 仍持有旧版或偏离的 Provider 环境' docker '重新创建本实例 AnythingLLM 并执行受管 Provider 回读' "$start"
  fi

  start=$(doctor_now_ms)
  hook_secret=$(env_get "${DOCTOR_DEPLOY_DIR}/.env" CRISP_WEBSITE_HOOK_SECRET 2>/dev/null || true)
  plugin_secret=$(env_get "${DOCTOR_DEPLOY_DIR}/.env" CRISP_PLUGIN_SIGNING_SECRET 2>/dev/null || true)
  # Compose 的 ${VAR:-not-configured} 会把缺失或空的非当前 Hook secret 规范化为哨兵值。
  # 当前模式所需 secret 已由 config.crisp_mode 严格验证，这里只核对实际容器展开结果。
  [[ -n "$hook_secret" ]] || hook_secret=not-configured
  [[ -n "$plugin_secret" ]] || plugin_secret=not-configured
  if doctor_container_env_binding n8n \
    'CRISP_WEBSITE_ID,CRISP_API_BASE_URL,CRISP_TOKEN_TIER,CRISP_AUTH_B64,CRISP_HOOK_MODE,CRISP_WEBSITE_HOOK_SECRET,CRISP_PLUGIN_SIGNING_SECRET,WEBHOOK_URL,ANYTHINGLLM_API_KEY,ANYTHINGLLM_WORKSPACE,AI_API_BASE_URL,AI_API_KEY,AI_MODEL,AI_API_MODE,AI_CUSTOM_HEADERS_JSON,AI_SUPPORTS_VISION' \
    "${DOCTOR_TEMP_ROOT}/n8n-runtime-binding.txt" \
    "$(env_get "${DOCTOR_DEPLOY_DIR}/.env" CRISP_WEBSITE_ID 2>/dev/null || true)" \
    "$(env_get "${DOCTOR_DEPLOY_DIR}/.env" CRISP_API_BASE_URL 2>/dev/null || printf 'https://api.crisp.chat/v1')" \
    "$(env_get "${DOCTOR_DEPLOY_DIR}/.env" CRISP_TOKEN_TIER 2>/dev/null || true)" \
    "$(env_get "${DOCTOR_DEPLOY_DIR}/.env" CRISP_AUTH_B64 2>/dev/null || true)" \
    "$(env_get "${DOCTOR_DEPLOY_DIR}/.env" CRISP_HOOK_MODE 2>/dev/null || true)" \
    "$hook_secret" \
    "$plugin_secret" \
    "$(env_get "${DOCTOR_DEPLOY_DIR}/.env" PUBLIC_WEBHOOK_URL 2>/dev/null || true)" \
    "$(env_get "${DOCTOR_DEPLOY_DIR}/.env" ANYTHINGLLM_API_KEY 2>/dev/null || true)" \
    "$(env_get "${DOCTOR_DEPLOY_DIR}/.env" ANYTHINGLLM_WORKSPACE 2>/dev/null || true)" \
    "$(env_get "${DOCTOR_DEPLOY_DIR}/.env" AI_API_BASE_URL 2>/dev/null || true)" \
    "$(env_get "${DOCTOR_DEPLOY_DIR}/.env" AI_API_KEY 2>/dev/null || true)" \
    "$(env_get "${DOCTOR_DEPLOY_DIR}/.env" AI_MODEL 2>/dev/null || true)" \
    "$(env_get "${DOCTOR_DEPLOY_DIR}/.env" AI_API_MODE 2>/dev/null || true)" \
    "$(env_get "${DOCTOR_DEPLOY_DIR}/.env" AI_CUSTOM_HEADERS_JSON 2>/dev/null || true)" \
    "$(env_get "${DOCTOR_DEPLOY_DIR}/.env" AI_SUPPORTS_VISION 2>/dev/null || true)"; then
    doctor_add n8n.runtime_binding 'n8n AI/Crisp 运行代' PASS critical 'n8n 的 Crisp、AnythingLLM 与 AI 环境均属于当前受管配置代' docker '' "$start"
  elif ! doctor_remaining >/dev/null 2>&1; then
    doctor_deadline_add n8n.runtime_binding 'n8n AI/Crisp 运行代' docker "$start"
    doctor_deadline_add provider.adapter 'Provider adapter' docker
    return
  else
    doctor_add n8n.runtime_binding 'n8n AI/Crisp 运行代' FAIL critical 'n8n 仍持有旧版或偏离的 Crisp/AI 环境' docker '按受管流程重新创建 n8n；不要清空人工会话状态' "$start"
  fi
  # 从实际 AnythingLLM 网络命名空间验证，不以宿主可达代替容器接线。
  if doctor_compose_timeout 15 exec -T anythingllm node -e '
    const wait=ms=>new Promise(resolve=>setTimeout(resolve,ms));
    (async()=>{
      for(let attempt=0;attempt<3;attempt++){
        const controller=new AbortController(); const timer=setTimeout(()=>controller.abort(),2500);
        try {
          const response=await fetch("http://provider-adapter:8787/healthz",{signal:controller.signal});
          const body=await response.json();
          if(response.ok&&body.ready===true){process.stdout.write("ready\n");return;}
        } catch {}
        finally {clearTimeout(timer);}
        if(attempt<2) await wait(400);
      }
      process.exitCode=1;
    })();
  ' < /dev/null > "$output" 2>/dev/null && grep -Fxq ready "$output"; then
    doctor_add provider.adapter 'Provider adapter' PASS critical 'AnythingLLM 容器可访问 adapter，受管配置可加载' docker '' "$start"
  elif ! doctor_remaining >/dev/null 2>&1; then
    doctor_deadline_add provider.adapter 'Provider adapter' docker "$start"
  else
    doctor_add provider.adapter 'Provider adapter' FAIL critical 'adapter 未运行、配置不可加载或容器网络不可达' docker '检查 provider-adapter health、配置挂载和 backend 网络' "$start"
  fi
}

doctor_runtime_state_check() {
  local start now sessions invalid legacy human timed permanent active_workers stale_workers pending_jobs file counts deadline_reached=0
  start=$(doctor_now_ms)
  now=$(doctor_now_ms)
  sessions=0; invalid=0; legacy=0; human=0; timed=0; permanent=0; active_workers=0; stale_workers=0; pending_jobs=0
  shopt -s nullglob
  for file in "${DOCTOR_DEPLOY_DIR}"/data/runtime/session-*.json; do
    if ! doctor_remaining >/dev/null; then deadline_reached=1; break; fi
    [[ -f "$file" && ! -L "$file" ]] || { ((invalid += 1)); continue; }
    if ! jq -e '.schema_version == 2 and (.mode == "ai" or .mode == "human") and
      (.generation | type == "number") and (.jobs | type == "array") and (.offers | type == "object")' "$file" >/dev/null 2>&1; then
      if jq -e '((.version | type) == "number" or (.version | type) == "string") and
        (.aiEnabled | type == "boolean") and (.aiResumeAt | type == "number" and . >= 0) and
        (.handoffGeneration | type == "number" and . >= 0)' "$file" >/dev/null 2>&1; then
        ((legacy += 1))
        if jq -e '.aiEnabled == false' "$file" >/dev/null 2>&1; then
          ((human += 1))
          if jq -e '.aiResumeAt > 0' "$file" >/dev/null 2>&1; then ((timed += 1)); else ((permanent += 1)); fi
        fi
      else
        ((invalid += 1))
      fi
      continue
    fi
    ((sessions += 1))
    counts=$(jq -r --argjson now "$now" '[
      (if .mode == "human" then 1 else 0 end),
      (if .mode == "human" and .resume_at != null then 1 else 0 end),
      (if .mode == "human" and .resume_at == null then 1 else 0 end),
      (if .worker != null and (.worker.until // 0) >= $now then 1 else 0 end),
      (if .worker != null and (.worker.until // 0) < ($now - 15000) then 1 else 0 end),
      ([.jobs[] | select(.status == "received" or .status == "processing")] | length)
    ] | @tsv' "$file")
    read -r human_count timed_count permanent_count active_count stale_count job_count <<< "$counts"
    human=$((human+human_count)); timed=$((timed+timed_count)); permanent=$((permanent+permanent_count))
    active_workers=$((active_workers+active_count)); stale_workers=$((stale_workers+stale_count)); pending_jobs=$((pending_jobs+job_count))
  done
  shopt -u nullglob
  if (( deadline_reached )); then
    doctor_add runtime.state '会话状态' WARN warning "总截止时间已到，仅检查 ${sessions} 个新状态和 ${legacy} 个旧状态" filesystem '增加显式自检超时后重试；未检查项没有被判为通过' "$start"
  elif (( invalid > 0 )); then
    doctor_add runtime.state '会话状态' FAIL critical "发现 ${invalid} 个无效或不安全的会话状态文件" filesystem '停止自动出站并从受限备份恢复对应状态；不要自动删除人工会话' "$start"
  elif (( stale_workers > 0 )); then
    doctor_add runtime.state '会话状态' FAIL critical "${sessions} 个会话中有 ${stale_workers} 个 worker 租约异常滞留" filesystem '检查 n8n 五秒扫描和 Code runner；不要默认解除人工模式' "$start"
  elif (( legacy > 0 )); then
    doctor_add runtime.state '会话状态' WARN warning "新状态 ${sessions}；发现 ${legacy} 个可识别旧状态待对应会话懒迁移，人工语义保持（人工 ${human}，永久 ${permanent}）" filesystem '保留旧状态；对应会话下次受控处理时会迁移，不要自动删除或恢复 AI' "$start"
  else
    doctor_add runtime.state '会话状态' PASS critical "会话 ${sessions}；人工 ${human}（定时 ${timed} / 永久 ${permanent}）；活跃 worker ${active_workers}；待处理 ${pending_jobs}" filesystem '' "$start"
  fi
}

doctor_runtime_scheduler_check() {
  local start file now started completed age
  start=$(doctor_now_ms)
  file="${DOCTOR_DEPLOY_DIR}/data/runtime/scheduler-health.json"
  now=$(doctor_now_ms)
  if [[ ! -e "$file" ]]; then
    doctor_add runtime.scheduler '会话恢复扫描心跳' WARN warning '尚无扫描完成记录；新安装可能仍在等待首次五秒扫描' filesystem '稍候重试；若超过一分钟仍缺失，请检查 n8n workflow 与 Code runner' "$start"
    return
  fi
  if [[ ! -f "$file" || -L "$file" ]] \
    || ! jq -e '.schema_version == 1 and (.started_at | type == "number") and (.completed_at | type == "number")' "$file" >/dev/null 2>&1; then
    doctor_add runtime.scheduler '会话恢复扫描心跳' FAIL critical '扫描心跳文件无效或不安全' filesystem '检查 n8n runtime 挂载和原子写入；不要执行扫描来伪造健康' "$start"
    return
  fi
  started=$(jq -r '.started_at' "$file")
  completed=$(jq -r '.completed_at' "$file")
  if (( completed > now + 60000 || started > now + 60000 )); then
    doctor_add runtime.scheduler '会话恢复扫描心跳' WARN warning '扫描心跳时间晚于本机时钟，无法可靠判断活性' filesystem '先同步系统时钟，再复查恢复扫描' "$start"
  elif (( completed <= 0 )); then
    age=$((now-started))
    if (( started > 0 && age <= 60000 )); then
      doctor_add runtime.scheduler '会话恢复扫描心跳' WARN warning '首次或当前扫描尚未完成' filesystem '等待本轮扫描；超过一分钟请检查 n8n Code runner' "$start"
    else
      doctor_add runtime.scheduler '会话恢复扫描心跳' FAIL critical '扫描启动后超过一分钟仍无完成记录' filesystem '检查 n8n 五秒扫描、Code runner 和阻塞任务；不要自动解除人工会话' "$start"
    fi
  else
    age=$((now-completed))
    if (( age <= 30000 )); then
      doctor_add runtime.scheduler '会话恢复扫描心跳' PASS critical "最近扫描在 ${age} 毫秒前完成；不依赖客户流量" filesystem '' "$start"
    elif (( age <= 60000 )); then
      doctor_add runtime.scheduler '会话恢复扫描心跳' WARN warning "最近扫描在 ${age} 毫秒前完成，已超过正常五秒周期" filesystem '稍候复查；若继续增长请检查 workflow 调度' "$start"
    else
      doctor_add runtime.scheduler '会话恢复扫描心跳' FAIL critical "最近扫描已停滞 ${age} 毫秒" filesystem '检查 n8n workflow 调度与 Code runner；自检不会调用 scan 或修改会话' "$start"
    fi
  fi
}

doctor_logs_check() {
  local start report status rc=0 configured env_match compose_state compose_wired container_state container_match
  local n8n_state timer_available timer_owned timer_enabled timer_active unsafe managed_bytes max_size max_files
  local -a arguments=(--deploy-dir "$DOCTOR_DEPLOY_DIR" --json audit)
  start=$(doctor_now_ms)
  if [[ ! -f "${DOCTOR_DEPLOY_DIR}/scripts/logs.sh" || -L "${DOCTOR_DEPLOY_DIR}/scripts/logs.sh" \
    || ! -f "${DOCTOR_DEPLOY_DIR}/scripts/log-redact.py" || -L "${DOCTOR_DEPLOY_DIR}/scripts/log-redact.py" ]]; then
    doctor_add logs.policy '运维日志策略' FAIL critical '日志维护或脱敏模块缺失/不安全' filesystem '从同版本完整发布包恢复日志模块' "$start"
    doctor_skip logs.capacity '容器日志容量接线' '因日志模块缺失未检查' docker
    doctor_skip logs.n8n_execution 'n8n execution 保留策略' '因日志模块缺失未检查' filesystem
    doctor_skip logs.timer '日志自动清理调度' '因日志模块缺失未检查' systemd
    doctor_skip logs.usage '受管日志占用' '因日志模块缺失未检查' filesystem
    return
  fi
  if [[ "$DOCTOR_SCOPE" == offline || "$DOCTOR_DOCKER_READY" != 1 ]]; then arguments+=(--no-docker); fi
  report="${DOCTOR_TEMP_ROOT}/logs-audit.json"
  doctor_timeout 20 bash "${DOCTOR_DEPLOY_DIR}/scripts/logs.sh" "${arguments[@]}" > "$report" 2>/dev/null || rc=$?
  if (( rc == 124 || rc == 137 )) || ! doctor_remaining >/dev/null; then
    doctor_deadline_add logs.policy '运维日志策略' filesystem "$start"
    doctor_skip logs.capacity '容器日志容量接线' '因日志自检达到总截止未检查' docker
    doctor_skip logs.n8n_execution 'n8n execution 保留策略' '因日志自检达到总截止未检查' filesystem
    doctor_skip logs.timer '日志自动清理调度' '因日志自检达到总截止未检查' systemd
    doctor_skip logs.usage '受管日志占用' '因日志自检达到总截止未检查' filesystem
    return
  fi
  if (( rc != 0 && rc != 1 && rc != 2 )) \
    || ! jq -e '.schema_version == 1 and (.policy | type == "object") and (.timer | type == "object") and (.usage | type == "object")' "$report" >/dev/null 2>&1; then
    doctor_add logs.policy '运维日志策略' FAIL critical '日志自检没有返回有效的结构化结果' filesystem '单独运行 crispai logs status 定位日志配置或模块错误' "$start"
    doctor_skip logs.capacity '容器日志容量接线' '因日志审计结果无效未检查' docker
    doctor_skip logs.n8n_execution 'n8n execution 保留策略' '因日志审计结果无效未检查' filesystem
    doctor_skip logs.timer '日志自动清理调度' '因日志审计结果无效未检查' systemd
    doctor_skip logs.usage '受管日志占用' '因日志审计结果无效未检查' filesystem
    return
  fi

  configured=$(jq -r '.configured' "$report"); env_match=$(jq -r '.env_projection_matched' "$report")
  compose_state=$(jq -r '.compose.state' "$report")
  compose_wired=$(jq -r '
    (.compose.state == "configured") and all(.compose.services[]; .logging_wired == true) and
    .compose.n8n.prune_wired == true and .compose.n8n.max_age_wired == true and
    .compose.n8n.save_success_wired == true and .compose.n8n.save_error_wired == true
  ' "$report")
  if [[ "$configured" != true ]]; then
    doctor_add logs.policy '运维日志策略' FAIL critical 'logging.yaml 缺失、损坏或字段越界' filesystem '从当前版本模板恢复，再使用日志菜单应用并回读' "$start"
  elif [[ "$(jq -r '.policy.revision == .policy.applied_revision' "$report")" != true ]]; then
    doctor_add logs.policy '运维日志策略' WARN warning '日志策略 revision 尚未完成运行时应用' filesystem '从日志菜单重新应用；不要手工只改 Compose' "$start"
  elif [[ "$env_match" != true ]]; then
    doctor_add logs.policy '运维日志策略' FAIL critical '权威日志配置与 .env 运行投影不一致' filesystem '从日志菜单成组重新应用配置' "$start"
  elif [[ "$compose_state" == invalid ]]; then
    doctor_add logs.policy '运维日志策略' FAIL critical 'Compose 无法解析日志容量或 execution 配置' filesystem '恢复同版本 Compose 后重新应用日志策略' "$start"
  elif [[ "$compose_wired" != true ]]; then
    doctor_add logs.policy '运维日志策略' FAIL critical 'Compose 未完整引用受管日志容量或 n8n execution 隐私字段' filesystem '从同版本正式包恢复 Compose 接线，再显式应用日志策略' "$start"
  else
    doctor_add logs.policy '运维日志策略' PASS critical \
      "策略已应用：$(jq -r '.policy.retention_days' "$report") 天 / $(jq -r '.policy.max_size_mib' "$report") MiB / $(jq -r '.policy.max_files' "$report") 份" \
      filesystem '' "$start"
  fi

  start=$(doctor_now_ms); container_state=$(jq -r '.runtime.containers.state' "$report"); container_match=$(jq -r '.runtime.containers.matched' "$report")
  if [[ "$container_state" == checked && "$container_match" == true ]]; then
    doctor_add logs.capacity '容器日志容量接线' PASS critical '全部运行中的本项目容器由 Docker json-file 按当前容量策略轮转' docker '' "$start"
  elif [[ "$container_state" == checked ]]; then
    doctor_add logs.capacity '容器日志容量接线' FAIL critical '至少一个运行中容器仍使用旧容量或非受管日志驱动' docker '从日志菜单显式应用；仅重建本项目容器，不直接操作 LogPath' "$start"
  else
    doctor_skip logs.capacity '容器日志容量接线' '因 Docker 不可用或离线范围未读取运行中容器' docker
  fi

  start=$(doctor_now_ms); n8n_state=$(jq -r '.runtime.n8n.state' "$report")
  if [[ "$DOCTOR_SCOPE" == offline ]]; then
    doctor_skip logs.n8n_execution 'n8n execution 保留策略' '离线范围已静态核对 Compose 接线，但不读取运行中 n8n' docker
  elif [[ "$n8n_state" == checked ]] && jq -e --arg hours "$(jq -r '.policy.retention_days * 24 | tostring' "$report")" \
    '.runtime.n8n.prune=="true" and .runtime.n8n.max_age_hours==$hours and .runtime.n8n.save_success=="none" and .runtime.n8n.save_error=="none"' "$report" >/dev/null; then
    doctor_add logs.n8n_execution 'n8n execution 保留策略' PASS critical '运行中 n8n 不保存成功/失败正文，并由官方 pruning 清理已完成 execution' docker '' "$start"
  elif [[ "$n8n_state" == checked ]]; then
    doctor_add logs.n8n_execution 'n8n execution 保留策略' FAIL critical '运行中 n8n execution 保存/保留值与隐私策略不一致' docker '重新应用日志策略并重建 n8n；不要直接 SQL 删除执行表' "$start"
  elif [[ "$compose_state" == configured ]] && jq -e \
    '.compose.n8n.prune_wired == true and .compose.n8n.max_age_wired == true and
     .compose.n8n.save_success_wired == true and .compose.n8n.save_error_wired == true' "$report" >/dev/null; then
    doctor_add logs.n8n_execution 'n8n execution 保留策略' WARN warning 'Compose 隐私设置正确，但本次未从运行中 n8n 回读' filesystem '服务恢复后重跑本地自检；不会用 SQL 清理活跃执行' "$start"
  else
    doctor_add logs.n8n_execution 'n8n execution 保留策略' FAIL critical 'Compose 中 n8n execution 保存/保留策略缺失或不一致' filesystem '恢复固定版本的隐私设置后重建 n8n' "$start"
  fi

  start=$(doctor_now_ms); timer_available=$(jq -r '.timer.systemd_available' "$report"); timer_owned=$(jq -r '.timer.owned' "$report")
  timer_enabled=$(jq -r '.timer.enabled' "$report"); timer_active=$(jq -r '.timer.active' "$report")
  if [[ "$timer_available" != true ]]; then
    doctor_add logs.timer '日志自动清理调度' WARN warning '当前环境没有运行中的 systemd，按天清理未自动调度' systemd '支持的生产系统应启用本实例 timer；不会改用临时 cron' "$start"
  elif [[ "$timer_owned" == true && "$timer_enabled" == true && "$timer_active" == true ]]; then
    doctor_add logs.timer '日志自动清理调度' PASS critical "本实例 timer 已启用；最近清理：$(jq -r '.timer.last_cleanup' "$report")" systemd '' "$start"
  elif (( DOCTOR_INSTALLATION_IN_PROGRESS )); then
    doctor_add logs.timer '日志自动清理调度' WARN warning '安装健康门禁阶段尚未完成 timer 接线' systemd '安装提交后会按受管归属启用，并在菜单中回读' "$start"
  else
    doctor_add logs.timer '日志自动清理调度' FAIL critical '本实例日志 timer 未启用、未运行或归属记录不一致' systemd '运行日志维护的 timer install；不得覆盖其他实例同名单元' "$start"
  fi

  start=$(doctor_now_ms); unsafe=$(jq -r '.usage.unsafe_entries' "$report"); managed_bytes=$(jq -r '.usage.managed_bytes' "$report")
  max_size=$(jq -r '.policy.max_size_mib' "$report"); max_files=$(jq -r '.policy.max_files' "$report")
  if (( unsafe > 0 )); then
    doctor_add logs.usage '受管日志占用' FAIL critical "日志历史中有 ${unsafe} 个链接、硬链接或特殊条目" filesystem '移出可疑条目并核对归属；自动清理不会跟随链接' "$start"
  elif (( managed_bytes > max_size * 1024 * 1024 * (max_files + 2) )); then
    doctor_add logs.usage '受管日志占用' WARN warning "受管运维日志 ${managed_bytes} bytes，超过策略余量" filesystem '先用 cleanup --preview 核对，再数字确认清理过期历史' "$start"
  else
    doctor_add logs.usage '受管日志占用' PASS warning "受管运维日志 ${managed_bytes} bytes；Docker 逐容器占用未通过 LogPath 读取" filesystem '' "$start"
  fi
}

doctor_materials_check() {
  local start report rc=0 state source_valid projection_valid pending revision expected output binding_rc=0
  start=$(doctor_now_ms)
  if [[ ! -f "${DOCTOR_DEPLOY_DIR}/scripts/materials.sh" \
    || -L "${DOCTOR_DEPLOY_DIR}/scripts/materials.sh" ]]; then
    doctor_add materials.applied '资料生效投影' FAIL critical \
      '资料应用模块缺失或不是安全普通文件' filesystem \
      '从同版本完整发布包恢复 materials.sh；不要回退读取未验证原文' "$start"
    doctor_skip materials.runtime_binding 'n8n 资料运行代' '因资料应用模块缺失未检查' docker
    return
  fi

  report="${DOCTOR_TEMP_ROOT}/materials-status.json"
  doctor_timeout 20 bash "${DOCTOR_DEPLOY_DIR}/scripts/materials.sh" \
    --deploy-dir "$DOCTOR_DEPLOY_DIR" status > "$report" 2>/dev/null || rc=$?
  if (( rc == 124 || rc == 137 )) || ! doctor_remaining >/dev/null; then
    doctor_deadline_add materials.applied '资料生效投影' filesystem "$start"
    doctor_skip materials.runtime_binding 'n8n 资料运行代' '因资料状态检查达到总截止未检查' docker
    return
  fi
  if (( rc != 0 && rc != 1 && rc != 2 )) \
    || ! jq -e '
      (.source_valid | type == "boolean") and (.projection_valid | type == "boolean") and
      (.pending | type == "boolean") and (.state | type == "string") and
      (.applied_revision | type == "number" and floor == . and . >= 0) and
      (.source_sha256 | type == "string") and (.applied_sha256 | type == "string")
    ' "$report" >/dev/null 2>&1; then
    doctor_add materials.applied '资料生效投影' FAIL critical \
      '资料状态没有返回有效的结构化结果' filesystem \
      '运行 crispai 资料状态检查；修复原文或从上一有效资料投影恢复' "$start"
    doctor_skip materials.runtime_binding 'n8n 资料运行代' '因资料状态结果无效未检查' docker
    return
  fi

  state=$(jq -r '.state' "$report")
  source_valid=$(jq -r '.source_valid' "$report")
  projection_valid=$(jq -r '.projection_valid' "$report")
  pending=$(jq -r '.pending' "$report")
  revision=$(jq -r '.applied_revision' "$report")
  # status 中的 applied_sha256 是“来源语义摘要”，用于判断原文 pending；
  # 运行容器挂载对账必须使用投影文件本身的逐字节摘要。
  expected=$(sha256sum -- "${DOCTOR_DEPLOY_DIR}/config/materials-applied.json" 2>/dev/null | awk '{print $1}' || true)
  if [[ "$projection_valid" == true && "$state" == applied ]]; then
    if [[ "$source_valid" == true && "$pending" == false ]]; then
      doctor_add materials.applied '资料生效投影' PASS critical \
        "当前生效资料 revision ${revision} 有效，可编辑原文与其一致" filesystem '' "$start"
    elif [[ "$source_valid" == true ]]; then
      doctor_add materials.applied '资料生效投影' WARN warning \
        "当前生效资料 revision ${revision} 有效；可编辑原文有尚未应用的变更" filesystem \
        '先预览并显式应用资料；运行时仍使用上一有效投影' "$start"
    else
      doctor_add materials.applied '资料生效投影' WARN warning \
        "当前生效资料 revision ${revision} 有效；可编辑原文校验失败" filesystem \
        '修复可编辑原文后再显式应用；运行时不会回退读取损坏原文' "$start"
    fi
  else
    doctor_add materials.applied '资料生效投影' FAIL critical \
      "当前资料投影不可用（state=${state}）" filesystem \
      '从上一有效配置历史成套恢复或重新完成资料应用；不要强启混合代' "$start"
    doctor_skip materials.runtime_binding 'n8n 资料运行代' '因当前资料投影不可用未检查' docker
    return
  fi

  start=$(doctor_now_ms)
  if [[ "$DOCTOR_SCOPE" == offline ]]; then
    doctor_skip materials.runtime_binding 'n8n 资料运行代' '离线范围不读取运行中 n8n' docker
    return
  fi
  if (( DOCTOR_DOCKER_READY == 0 || DOCTOR_N8N_READY == 0 )); then
    doctor_skip materials.runtime_binding 'n8n 资料运行代' '因 Docker 或 n8n 不可用未检查' docker
    return
  fi
  if [[ ! "$expected" =~ ^[a-f0-9]{64}$ ]]; then
    doctor_add materials.runtime_binding 'n8n 资料运行代' FAIL critical \
      '当前有效投影缺少可核对的摘要' filesystem \
      '从上一有效资料投影恢复；不要回退读取可编辑原文' "$start"
    return
  fi
  output="${DOCTOR_TEMP_ROOT}/materials-runtime-binding"
  # 期望摘要只经 stdin 传入，不放入 argv/日志；容器只返回 matched。
  # shellcheck disable=SC2016
  printf '%s' "$expected" | doctor_compose_timeout 12 exec -T n8n node -e '
    const crypto=require("crypto"),fs=require("fs");
    const marker="CRISPAI_EXPECTED_MATERIALS_PROJECTION";
    const expected=fs.readFileSync(0,"utf8").trim();
    const file=fs.readFileSync("/opt/crisp-ai/config/materials-applied.json");
    const actual=crypto.createHash("sha256").update(file).digest("hex");
    const a=Buffer.from(actual),b=Buffer.from(expected);
    if(!marker || a.length!==b.length || !crypto.timingSafeEqual(a,b)) process.exit(1);
    process.stdout.write("matched\n");
  ' > "$output" 2>/dev/null || binding_rc=$?
  if (( binding_rc == 0 )) && grep -Fxq matched "$output"; then
    doctor_add materials.runtime_binding 'n8n 资料运行代' PASS critical \
      '运行中 n8n 读取的资料投影与当前有效投影逐字节一致' docker '' "$start"
  elif (( binding_rc == 124 || binding_rc == 137 )) || ! doctor_remaining >/dev/null; then
    doctor_deadline_add materials.runtime_binding 'n8n 资料运行代' docker "$start"
  else
    doctor_add materials.runtime_binding 'n8n 资料运行代' FAIL critical \
      '运行中 n8n 未读取当前有效资料投影' docker \
      '重新应用已验证资料并回读；不要直接修改容器内文件' "$start"
  fi
}

doctor_crisp_observation_check() {
  local start binding_file binding file matched=0 hook=0 conversation=0 api_base deadline_reached=0
  local website_secret plugin_secret
  start=$(doctor_now_ms)
  binding_file="${DOCTOR_TEMP_ROOT}/binding.bin"
  website_secret=$(env_get "${DOCTOR_DEPLOY_DIR}/.env" CRISP_WEBSITE_HOOK_SECRET 2>/dev/null || true)
  plugin_secret=$(env_get "${DOCTOR_DEPLOY_DIR}/.env" CRISP_PLUGIN_SIGNING_SECRET 2>/dev/null || true)
  # runtime 读取的是 Compose 运行环境；两个可选 Secret 的 `${VAR:-not-configured}`
  # 会把宿主缺失/空值统一投影为 sentinel。observation 绑定必须逐字节同义。
  website_secret=${website_secret:-not-configured}
  plugin_secret=${plugin_secret:-not-configured}
  # runtime 的 connectionBinding() 使用 Array.join("\0")：字段之间有 NUL，
  # 最后一项之后没有 NUL。这里必须逐字节保持相同序列，否则当前凭据的
  # observation 也会被错误判定为旧绑定。
  {
    printf '%s\0' \
      "$(env_get "${DOCTOR_DEPLOY_DIR}/.env" CRISP_WEBSITE_ID 2>/dev/null || true)" \
      "$(env_get "${DOCTOR_DEPLOY_DIR}/.env" CRISP_AUTH_B64 2>/dev/null || true)" \
      "$(env_get "${DOCTOR_DEPLOY_DIR}/.env" CRISP_HOOK_MODE 2>/dev/null || true)" \
      "$website_secret" \
      "$plugin_secret" \
      "$(env_get "${DOCTOR_DEPLOY_DIR}/.env" PUBLIC_WEBHOOK_URL 2>/dev/null || true)"
    printf '%s' \
      "$(env_get "${DOCTOR_DEPLOY_DIR}/.env" CRISP_API_BASE_URL 2>/dev/null || printf 'https://api.crisp.chat/v1')"
  } > "$binding_file"
  binding=$(sha256sum "$binding_file" | cut -d ' ' -f 1)
  shopt -s nullglob
  for file in "${DOCTOR_DEPLOY_DIR}"/data/runtime/session-*.json; do
    if ! doctor_remaining >/dev/null; then deadline_reached=1; break; fi
    [[ -f "$file" && ! -L "$file" ]] || continue
    if jq -e --arg binding "$binding" '.observations.binding == $binding' "$file" >/dev/null 2>&1; then
      ((matched += 1))
      jq -e '.observations.hook_received_at > 0' "$file" >/dev/null 2>&1 && ((hook += 1))
      jq -e '.observations.hook_received_at > 0 and .observations.ai_reply_sent_at >= .observations.hook_received_at' "$file" >/dev/null 2>&1 && ((conversation += 1))
    fi
  done
  shopt -u nullglob
  api_base=$(env_get "${DOCTOR_DEPLOY_DIR}/.env" CRISP_API_BASE_URL 2>/dev/null || printf 'https://api.crisp.chat/v1')
  if (( deadline_reached )); then
    doctor_add crisp.observations '当前 Crisp 接入观察' WARN warning "总截止时间已到，仅核对 ${matched} 个当前绑定状态" filesystem '增加显式自检超时后重试；未检查状态没有被判为通过' "$start"
  elif (( hook == 0 )); then
    doctor_add crisp.observations '当前 Crisp 接入观察' WARN warning '当前凭据/Hook 绑定尚无可信收件观察；旧绑定结果未复用' filesystem '登记 message:send / message:received / message:updated 后用隔离会话复核' "$start"
  elif [[ "${api_base%/}" != https://api.crisp.chat/v1 ]]; then
    doctor_add crisp.observations '当前 Crisp 接入观察' WARN warning "当前自定义/协议环境观察到 ${hook} 个 Hook，但不能视为官方 Crisp E2E" filesystem '在官方 Crisp 隔离会话完成真实收发' "$start"
  elif (( conversation > 0 )); then
    doctor_add crisp.observations '当前 Crisp 接入观察' PASS warning "当前绑定观察到 Hook 与真实回复链路（${conversation} 个会话）" filesystem '' "$start"
  else
    doctor_add crisp.observations '当前 Crisp 接入观察' WARN warning "当前绑定观察到 ${hook} 个 Hook，但尚无完整 AI 回复证据" filesystem '使用隔离访客会话验证收件、回复和人工按钮' "$start"
  fi
}

doctor_external_check() {
  local start mode webhook_url
  if [[ "$DOCTOR_SCOPE" == local || "$DOCTOR_SCOPE" == offline ]]; then
    doctor_skip crisp.api 'Crisp REST API' '本次范围不访问外部 Crisp' external
    doctor_skip webhook.public '公网 Webhook' '本次范围不访问公网入口' external
    doctor_skip provider.inference 'Provider 实际推理' '本次范围不执行可能计费的模型请求' external
    doctor_skip crisp.observations '当前 Crisp 接入观察' '本次范围不评价外部收发事实' filesystem
    return
  fi
  start=$(doctor_now_ms)
  if doctor_crisp_api_probe; then
    doctor_add crisp.api 'Crisp REST API' PASS critical '当前凭据完成只读网站身份校验' external '' "$start"
  elif [[ "$DOCTOR_EXTERNAL_STATUS" == 401 || "$DOCTOR_EXTERNAL_STATUS" == 403 \
    || "$DOCTOR_EXTERNAL_STATUS" == invalid-response ]]; then
    doctor_add crisp.api 'Crisp REST API' FAIL critical "当前已配置凭据校验失败（${DOCTOR_EXTERNAL_STATUS}）" external '核对 Website ID、Token tier 与权限；旧观察不能替代当前认证' "$start"
  elif [[ "$DOCTOR_SCOPE" == full ]]; then
    doctor_add crisp.api 'Crisp REST API' FAIL critical "当前凭据只读校验失败（${DOCTOR_EXTERNAL_STATUS}）" external '核对 Website ID、Token tier、权限与自检总超时' "$start"
  else
    doctor_add crisp.api 'Crisp REST API' WARN warning "当前凭据只读校验未通过（${DOCTOR_EXTERNAL_STATUS}）" external '使用 --full 明确复核，或从 Crisp 接入菜单修正凭据' "$start"
  fi
  start=$(doctor_now_ms)
  mode=$(env_get "${DOCTOR_DEPLOY_DIR}/.env" WEBHOOK_ACCESS_MODE 2>/dev/null || true)
  webhook_url=$(env_get "${DOCTOR_DEPLOY_DIR}/.env" WEBHOOK_PRODUCTION_URL 2>/dev/null || true)
  if [[ "$mode" != managed_https && "$mode" != external_proxy ]] || [[ "$webhook_url" != https://*'/webhook/crisp-webhook' ]]; then
    doctor_add webhook.public '公网 Webhook' FAIL critical '公网接入模式或生产 URL 格式无效' filesystem '从 Crisp 接入菜单重新生成准确生产 URL' "$start"
  elif doctor_webhook_probe; then
    doctor_add webhook.public '公网 Webhook' PASS warning 'DNS/TLS/反向代理到达项目生产 Code 的特有拒绝路径' external '' "$start"
  elif [[ "$DOCTOR_SCOPE" == full ]]; then
    doctor_add webhook.public '公网 Webhook' FAIL critical "公网路径未通过有限探测（${DOCTOR_EXTERNAL_STATUS}）" external '检查 DNS、TLS、已有反代、受管 Caddy 或自检总超时；这不等同真实 Crisp 投递' "$start"
  else
    doctor_add webhook.public '公网 Webhook' WARN warning "公网路径尚未验证（${DOCTOR_EXTERNAL_STATUS}）" external '使用 --full 复核或完成 DNS/反代配置' "$start"
  fi
  doctor_crisp_observation_check
  start=$(doctor_now_ms)
  if [[ "$DOCTOR_SCOPE" != full ]]; then
    doctor_skip provider.inference 'Provider 实际推理' '默认自检不执行可能计费的模型请求；配置与 adapter 已检查' external
  elif doctor_timeout 45 bash "${DOCTOR_DEPLOY_DIR}/scripts/provider.sh" --deploy-dir "$DOCTOR_DEPLOY_DIR" test >/dev/null 2>&1; then
    doctor_add provider.inference 'Provider 实际推理' PASS critical '当前模型通过上游协议与 AnythingLLM 容器最终路径的非空正文验证' external '' "$start"
  else
    doctor_add provider.inference 'Provider 实际推理' FAIL critical '当前模型、协议或最终应用容器路径调用失败' external '从第三方 AI 菜单核对协议、模型、Key 和容器地址' "$start"
  fi
}

doctor_run_checks() {
  doctor_installation_check
  doctor_system_check
  doctor_files_and_config_check
  if [[ "$DOCTOR_SCOPE" == offline ]]; then
    doctor_skip docker.compose 'Docker Compose' '离线范围不访问 Docker' docker
    for service in "${DOCTOR_EXPECTED_SERVICES[@]}"; do doctor_skip "container.${service}" "容器 ${service}" '离线范围未检查' docker; done
    doctor_skip database.authentication 'PostgreSQL 应用认证' '离线范围未检查' docker
    doctor_skip database.n8n_binding 'n8n 数据库凭据接线' '离线范围未检查' docker
    doctor_skip anything.ping 'AnythingLLM 服务' '离线范围未检查' local-api
    doctor_skip anything.workspace 'AnythingLLM 工作区与 Prompt' '离线范围未检查' local-api
    doctor_skip knowledge.catalog '知识库与索引' '离线范围未检查实际索引' local-api
    doctor_skip n8n.health 'n8n 服务' '离线范围未检查' local-api
    doctor_skip n8n.workflow 'n8n 生产工作流' '离线范围未检查' docker
    doctor_skip n8n.runtime 'n8n Code runner' '离线范围未检查' local-api
    doctor_skip provider.adapter 'Provider adapter' '离线范围未检查' docker
    doctor_skip provider.adapter_code_binding 'Provider adapter 程序运行代' '离线范围未检查单文件挂载' docker
    doctor_skip caddy.file_binding 'Caddy 配置运行代' '离线范围未检查单文件挂载' docker
    doctor_skip provider.adapter_binding 'Provider adapter 运行代' '离线范围未检查' docker
    doctor_skip anything.provider_binding 'AnythingLLM Provider 运行代' '离线范围未检查' docker
    doctor_skip n8n.runtime_binding 'n8n AI/Crisp 运行代' '离线范围未检查' docker
  else
    doctor_docker_check
    doctor_file_bindings_check "$(env_get "${DOCTOR_DEPLOY_DIR}/.env" WEBHOOK_ACCESS_MODE 2>/dev/null || true)"
    doctor_db_check
    doctor_anything_check
    doctor_n8n_check
    doctor_adapter_check
  fi
  doctor_materials_check
  doctor_runtime_state_check
  doctor_runtime_scheduler_check
  doctor_logs_check
  doctor_external_check
}

doctor_result_status() {
  jq -rs --arg id "$1" '[.[] | select(.id == $id)][-1].status // "SKIP"' "$DOCTOR_RESULTS"
}

doctor_safe_fix() {
  local launcher_path access_mode service service_status permissions_status dependency_status daemon_status compose_status install_state
  if (( EUID != 0 )); then
    doctor_fix_add fix.authorization '修复授权' FAIL '安全修复需要 root；未执行任何修复'
    return
  fi
  install_state=$(installation_state "$DOCTOR_DEPLOY_DIR")
  if [[ "$install_state" != ready && "$install_state" != local-ready ]]; then
    doctor_fix_add fix.generation-guard '安装代际保护' FAIL "当前状态 ${install_state:-未知} 不是稳定运行代；未补依赖、改权限/入口或启动任何服务"
    return
  fi
  if (( DOCTOR_PREBOOTSTRAP_JQ_FIXED )); then
    doctor_fix_add fix.bootstrap-jq '结构化诊断依赖' PASS '已通过受管依赖引导器补齐 jq，未改动业务配置'
  fi
  dependency_status=$(doctor_result_status system.commands)
  daemon_status=$(doctor_result_status docker.daemon)
  compose_status=$(doctor_result_status docker.compose)
  if [[ "$dependency_status" == PASS && "$daemon_status" == PASS && "$compose_status" == PASS ]]; then
    doctor_fix_add fix.dependencies '依赖与 Docker' SKIP '现有依赖与 Docker 能力检查通过，无需修改'
  elif [[ -x "${DOCTOR_DEPLOY_DIR}/scripts/bootstrap.sh" ]]; then
    if doctor_timeout 180 bash "${DOCTOR_DEPLOY_DIR}/scripts/bootstrap.sh" --all >/dev/null 2>&1; then
      doctor_fix_add fix.dependencies '依赖与 Docker' PASS '已通过受支持的引导器补齐依赖并验证 daemon'
    else
      doctor_fix_add fix.dependencies '依赖与 Docker' FAIL '自动补齐失败；保留原始系统和安装状态'
    fi
  else
    doctor_fix_add fix.dependencies '依赖与 Docker' FAIL '受管 bootstrap 模块缺失，未执行下载或重装'
  fi

  permissions_status=$(doctor_result_status security.permissions)
  if [[ "$permissions_status" == FAIL ]]; then
    if secure_permissions "$DOCTOR_DEPLOY_DIR" >/dev/null 2>&1 \
      && set_runtime_ownership "$DOCTOR_DEPLOY_DIR" >/dev/null 2>&1; then
      doctor_fix_add fix.permissions '受管文件权限' PASS '已恢复项目配置、知识和运行目录的受限权限'
    else
      doctor_fix_add fix.permissions '受管文件权限' FAIL '权限恢复失败；未删除任何数据'
    fi
  else
    doctor_fix_add fix.permissions '受管文件权限' SKIP '权限检查未发现可自动修复问题'
  fi

  launcher_path=/usr/local/bin/crispai
  if [[ -f "${DOCTOR_DEPLOY_DIR}/config/.crispai-launcher" && ! -L "${DOCTOR_DEPLOY_DIR}/config/.crispai-launcher" ]]; then
    IFS= read -r launcher_path < "${DOCTOR_DEPLOY_DIR}/config/.crispai-launcher" || true
  fi
  if [[ "$(doctor_result_status installation.launcher)" != PASS ]]; then
    if [[ -x "${DOCTOR_DEPLOY_DIR}/scripts/launcher.sh" ]] \
      && doctor_timeout 15 bash "${DOCTOR_DEPLOY_DIR}/scripts/launcher.sh" install \
        --deploy-dir "$DOCTOR_DEPLOY_DIR" --command-path "$launcher_path" --non-interactive >/dev/null 2>&1; then
      doctor_fix_add fix.launcher 'crispai 管理入口' PASS '已恢复当前实例拥有的管理入口'
    else
      doctor_fix_add fix.launcher 'crispai 管理入口' FAIL '入口冲突或路径不安全，未覆盖其他程序'
    fi
  else
    doctor_fix_add fix.launcher 'crispai 管理入口' SKIP '入口指向正确，无需修改'
  fi

  if command -v docker >/dev/null 2>&1 && doctor_timeout 10 docker info >/dev/null 2>&1 \
    && doctor_compose_timeout 15 config --quiet >/dev/null 2>&1; then
    access_mode=$(env_get "${DOCTOR_DEPLOY_DIR}/.env" WEBHOOK_ACCESS_MODE 2>/dev/null || true)
    for service in postgres anythingllm n8n provider-adapter; do
      service_status=$(doctor_result_status "container.${service}")
      if [[ "$service_status" == FAIL ]] && grep -Fxq "$service" "$DOCTOR_RESTARTABLE_SERVICES"; then
        if doctor_compose_timeout 45 up -d "$service" >/dev/null 2>&1; then
          doctor_fix_add "fix.service.${service}" "启动 ${service}" PASS '已启动当前实例中停止或缺失的服务'
        else
          doctor_fix_add "fix.service.${service}" "启动 ${service}" FAIL '启动失败；未触碰其他项目容器'
        fi
      elif [[ "$service_status" == FAIL ]]; then
        doctor_fix_add "fix.service.${service}" "启动 ${service}" SKIP '容器正在运行但健康异常；安全修复未重建或重启它'
      fi
    done
    if [[ "$access_mode" == managed_https && "$(doctor_result_status container.caddy)" == FAIL ]] \
      && grep -Fxq caddy "$DOCTOR_RESTARTABLE_SERVICES"; then
      if doctor_compose_timeout 45 --profile managed-https up -d caddy >/dev/null 2>&1; then
        doctor_fix_add fix.service.caddy '启动 caddy' PASS '已启动当前实例受管 HTTPS 服务'
      else
        doctor_fix_add fix.service.caddy '启动 caddy' FAIL '受管 HTTPS 启动失败；未修改外部反向代理'
      fi
    elif [[ "$access_mode" == managed_https && "$(doctor_result_status container.caddy)" == FAIL ]]; then
      doctor_fix_add fix.service.caddy '启动 caddy' SKIP 'Caddy 正在运行但健康异常；安全修复未重建或重启它'
    fi
  else
    doctor_fix_add fix.services '项目服务' FAIL 'Docker 或 Compose 配置仍不可用，未尝试重建服务'
  fi
}

doctor_build_report() {
  local output=$1 version cache temporary managed=false marker
  version=$(sed -n '1p' "${DOCTOR_DEPLOY_DIR}/VERSION" 2>/dev/null || printf unknown)
  marker="${DOCTOR_DEPLOY_DIR}/${INSTALL_MARKER}"
  if [[ -f "$marker" && ! -L "$marker" ]] && [[ "$(sed -n '1p' "$marker" 2>/dev/null || true)" == ai-support ]]; then
    managed=true
  fi
  jq -M -s \
    --arg checked_at "$DOCTOR_STARTED_AT" --arg scope "$DOCTOR_SCOPE" --arg version "$version" \
    --arg deploy_dir "$DOCTOR_DEPLOY_DIR" \
    --argjson pass "$DOCTOR_PASSES" --argjson warn "$DOCTOR_WARNINGS" \
    --argjson fail "$DOCTOR_FAILURES" --argjson skip "$DOCTOR_SKIPS" \
    --argjson before "$DOCTOR_BEFORE_SUMMARY" --argjson managed "$managed" \
    --slurpfile fixes "$DOCTOR_FIX_RESULTS" \
    '{schema_version:1,checked_at:$checked_at,scope:$scope,version:$version,
      installation:{managed:$managed,deploy_dir:$deploy_dir},results:.,
      summary:{pass:$pass,warn:$warn,fail:$fail,skip:$skip},
      fix:{requested:($fixes|length>0),before:$before,actions:$fixes}}' \
    "$DOCTOR_RESULTS" > "$output"
  chmod 0600 "$output"
  cache=$(doctor_cache_file)
  if [[ -d "${DOCTOR_DEPLOY_DIR}/logs" && ! -L "${DOCTOR_DEPLOY_DIR}/logs" \
    && ( ! -e "$cache" || -f "$cache" && ! -L "$cache" ) ]]; then
    temporary=$(mktemp "${DOCTOR_DEPLOY_DIR}/logs/.doctor-last.XXXXXX")
    install -m 0600 -- "$output" "$temporary"
    mv -f -- "$temporary" "$cache"
  fi
  if [[ -f "${DOCTOR_DEPLOY_DIR}/scripts/logs.sh" && ! -L "${DOCTOR_DEPLOY_DIR}/scripts/logs.sh" ]]; then
    doctor_timeout 8 bash "${DOCTOR_DEPLOY_DIR}/scripts/logs.sh" --deploy-dir "$DOCTOR_DEPLOY_DIR" \
      record-doctor --input "$output" >/dev/null 2>&1 || true
  fi
}

DOCTOR_REQUESTED_SCOPE=$DOCTOR_SCOPE
if (( DOCTOR_FIX )); then DOCTOR_SCOPE=local; fi
if (( DOCTOR_JSON == 0 )); then printf '正在执行 CrispAI 组件自检（%s，最长 %s 秒）……\n' "$DOCTOR_REQUESTED_SCOPE" "$DOCTOR_TOTAL_TIMEOUT" >&2; fi
doctor_run_checks
if (( DOCTOR_FIX )); then
  DOCTOR_BEFORE_SUMMARY=$(jq -M -cn --argjson pass "$DOCTOR_PASSES" --argjson warn "$DOCTOR_WARNINGS" \
    --argjson fail "$DOCTOR_FAILURES" --argjson skip "$DOCTOR_SKIPS" '{pass:$pass,warn:$warn,fail:$fail,skip:$skip}')
  if (( 10#$DOCTOR_TOTAL_TIMEOUT < 300 )); then
    DOCTOR_DEADLINE=$((SECONDS + 300))
  else
    DOCTOR_DEADLINE=$((SECONDS + 10#$DOCTOR_TOTAL_TIMEOUT))
  fi
  printf '显式修复计划：仅在稳定运行代补齐受支持依赖、受管权限/入口及已停止的本项目服务；不会修改客服开关、知识或会话状态。\n' >&2
  doctor_safe_fix
  doctor_reset_results
  DOCTOR_SCOPE=$DOCTOR_REQUESTED_SCOPE
  DOCTOR_DEADLINE=$((SECONDS + 10#$DOCTOR_TOTAL_TIMEOUT))
  doctor_run_checks
fi

DOCTOR_REPORT="${DOCTOR_TEMP_ROOT}/report.json"
doctor_build_report "$DOCTOR_REPORT"
if (( DOCTOR_JSON )); then cat "$DOCTOR_REPORT"; else doctor_render_text "$DOCTOR_REPORT"; fi

if (( DOCTOR_FAILURES > 0 )); then exit 1; fi
if (( DOCTOR_WARNINGS > 0 )); then exit 2; fi
exit 0
