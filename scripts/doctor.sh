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

# 配置入口接受严格 YAML/JSON；doctor 只在私有临时目录读取规范化副本，既不
# 改写管理员原文，也不把可编辑候选误当成 shell 内容。
DOCTOR_CONFIGURATION_DECODER_READY=0
if [[ -f "${DOCTOR_DIR}/configuration.sh" && ! -L "${DOCTOR_DIR}/configuration.sh" ]]; then
  # shellcheck source=scripts/configuration.sh disable=SC1091
  source "${DOCTOR_DIR}/configuration.sh"
  DOCTOR_CONFIGURATION_DECODER_READY=1
fi

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
DOCTOR_DB_READY=0
DOCTOR_N8N_READY=0
DOCTOR_ANYTHING_READY=0
DOCTOR_PREBOOTSTRAP_JQ_FIXED=0
DOCTOR_POOL_ENABLED=0
DOCTOR_POOL_READY=0
DOCTOR_PROVIDER_INFERENCE_STATUS=not_checked
DOCTOR_APPLIED_BUSINESS_STATE=invalid
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
    def status_label: {PASS:"通过",WARN:"需关注",FAIL:"故障",SKIP:"未检查"}[.] // .;
    def scope: {local:"本地组件",offline:"离线资料",full:"完整连接与少量模型测试",default:"常规只读"}[.] // .;
    if $cached == 1 then "CrispAI 上次自检（缓存）：\(.checked_at)\n范围：\(.scope|scope)\n"
    else "CrispAI 组件自检 \(.version)\n范围：\(.scope|scope)；检测时间：\(.checked_at)\n" end,
    (.results[] | "[\(.status|status_label)] \(.name)：\(.summary)" +
      (if (.suggestion // "") == "" then "" else "\n  建议：\(.suggestion)" end)),
    (if (.fix.actions // [] | length) > 0 then
      "修复动作：", (.fix.actions[] | "[\(.status|status_label)] \(.name)：\(.summary)")
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

if [[ -d "${DOCTOR_DEPLOY_DIR}/tmp" && ! -L "${DOCTOR_DEPLOY_DIR}/tmp" ]]; then
  # 正常实例把含短期认证配置的诊断临时文件留在受管部署根内；目录损坏时
  # 仍回退到私有系统临时目录，使基础诊断保持可达。
  DOCTOR_TEMP_ROOT=$(mktemp -d "${DOCTOR_DEPLOY_DIR}/tmp/doctor.XXXXXXXX")
else
  DOCTOR_TEMP_ROOT=$(mktemp -d /tmp/crispai-doctor.XXXXXXXX)
fi
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

doctor_config_file() {
  local name=$1
  [[ "$name" =~ ^(runtime|provider|keyword|menu|handoff|tags|feedback|logging)$ ]] || return 1
  printf '%s/config-normalized/%s.json\n' "$DOCTOR_TEMP_ROOT" "$name"
}

doctor_decode_config() {
  local name=$1 output
  (( DOCTOR_CONFIGURATION_DECODER_READY == 1 )) || return 1
  output=$(doctor_config_file "$name") || return 1
  mkdir -p -- "${DOCTOR_TEMP_ROOT}/config-normalized"
  chmod 0700 "${DOCTOR_TEMP_ROOT}/config-normalized"
  # --fix 会在同一进程复查；先删除上轮副本，防止本轮解析失败后误读旧绿灯。
  rm -f -- "$output"
  configuration_decode_file "${DOCTOR_DEPLOY_DIR}/config/${name}.yaml" "$output" \
    >/dev/null 2>&1 || { rm -f -- "$output"; return 1; }
  [[ -f "$output" && ! -L "$output" ]] || return 1
  chmod 0600 "$output"
}

doctor_prepare_applied_business_configs() {
  local source="${DOCTOR_DEPLOY_DIR}/config/materials-applied.json"
  local target_root="${DOCTOR_TEMP_ROOT}/applied-business"
  local projection="${target_root}/materials-applied.json"
  local name

  DOCTOR_APPLIED_BUSINESS_STATE=invalid
  if ! rm -rf -- "$target_root" || [[ -e "$target_root" || -L "$target_root" ]]; then
    return 1
  fi
  if [[ ! -e "$source" && ! -L "$source" ]]; then
    DOCTOR_APPLIED_BUSINESS_STATE=absent
    return 2
  fi
  [[ -f "$source" && ! -L "$source" ]] || return 1
  [[ $(stat -c '%h' -- "$source" 2>/dev/null || printf 0) == 1 ]] || return 1
  [[ $(stat -c '%s' -- "$source" 2>/dev/null || printf 0) -le 16777216 ]] || return 1
  mkdir -m 0700 -- "$target_root"
  if ! install -m 0600 -- "$source" "$projection"; then
    rm -rf -- "$target_root"
    return 1
  fi

  # 在 doctor 私有副本上复用生产投影校验器。该校验器会建立临时目录，
  # 因此不能直接指向 config/，否则只读自检也会短暂写入管理员配置目录。
  # shellcheck disable=SC2016
  if ! doctor_timeout 10 bash -c '
    set -euo pipefail
    source "$1/materials.sh"
    materials_projection_validate "$2"
  ' doctor-materials "$DOCTOR_DIR" "$projection" >/dev/null 2>&1 \
    || ! jq -e '.state == "applied"' "$projection" >/dev/null 2>&1; then
    rm -rf -- "$target_root"
    return 1
  fi

  for name in runtime menu handoff; do
    if ! jq -M ".configuration.${name}" "$projection" > "${target_root}/${name}.json"; then
      rm -rf -- "$target_root"
      return 1
    fi
    if ! chmod 0600 "${target_root}/${name}.json"; then
      rm -rf -- "$target_root"
      return 1
    fi
  done
  DOCTOR_APPLIED_BUSINESS_STATE=ready
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
doctor_anything_read_probe() {
  local port=$1 key=$2 route=$3 response=$4 config status curl_rc=0 escaped_key
  if [[ ! "$port" =~ ^[0-9]{1,5}$ || ! "$route" =~ ^(system|workspace/[A-Za-z0-9_-]{1,128})$ ]] \
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
    "http://127.0.0.1:${port}/api/v1/${route}" 2>/dev/null) || curl_rc=$?
  : > "$config"
  if (( curl_rc == 124 || curl_rc == 137 )); then printf '000\n'; else printf '%s\n' "${status:-000}"; fi
}

doctor_anything_workspace_probe() {
  doctor_anything_read_probe "$1" "$2" "workspace/$3" "$4"
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
  DOCTOR_DB_READY=0
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
  local start relative missing='' invalid='' env_mode runtime_mode secret_count=0 value launcher_path launcher_digest expected_digest backup_count=0 installed_version
  local website tier hook_mode hook_secret identifier token auth expected_auth
  local runtime_config menu_config handoff_config
  local business_runtime_config business_menu_config business_handoff_config business_source business_projection_rc=0
  local -a atomic_artifacts=()
  local -a required=(VERSION docker-compose.yml .env get.sh install.sh manage.sh update.sh uninstall.sh
    n8n/workflow.json n8n/runtime.js n8n/runtime-cli.js n8n/admin-query.js n8n/build-workflow.js n8n/web-chat.js
    config/app.yaml config/Caddyfile.example config/runtime.yaml config/provider.yaml config/prompt.md
    config/keyword.yaml config/menu.yaml config/handoff.yaml config/tags.yaml config/feedback.yaml
    config/logging.yaml
    scripts/common.sh scripts/healthcheck.sh scripts/doctor.sh scripts/bootstrap.sh scripts/wizard.sh
    scripts/package-release.sh scripts/backup.sh scripts/restore.sh scripts/analytics.sh scripts/snapshot.sh
    scripts/rollback.sh scripts/launcher.sh scripts/menu-ui.sh scripts/configuration.sh scripts/provider.sh
    scripts/provider-adapter.js scripts/knowledge.sh scripts/migration.sh scripts/crisp-settings.sh
    scripts/full-backup.sh scripts/archive-guard.py scripts/materials.sh scripts/logs.sh scripts/log-redact.py
    scripts/knowledge-profile.py scripts/knowledge-profile.sh scripts/knowledge-component.js
    scripts/knowledge-lexical.py n8n/knowledge-lexical.js)
  installed_version=$(sed -n '1p' "${DOCTOR_DEPLOY_DIR}/VERSION" 2>/dev/null || true)
  DOCTOR_POOL_ENABLED=0
  if [[ -e "${DOCTOR_DEPLOY_DIR}/config/provider-pool-applied.json" \
    || $(env_get "${DOCTOR_DEPLOY_DIR}/.env" PROVIDER_POOL_REQUIRED 2>/dev/null || true) == true ]] \
    || version_at_least "$(sed -n '1p' "${DOCTOR_DEPLOY_DIR}/VERSION" 2>/dev/null || true)" v1.2.1; then
    DOCTOR_POOL_ENABLED=1
    required+=(scripts/provider-router.js scripts/provider-envelope.js scripts/provider-pool.py scripts/menu-display.py scripts/menu-provider-ui.sh)
  fi
  DOCTOR_VISITOR_OUTPUT_ENABLED=0
  if version_at_least "$installed_version" v1.2.2 \
    || [[ -e "${DOCTOR_DEPLOY_DIR}/scripts/visitor-output.js" \
      || -L "${DOCTOR_DEPLOY_DIR}/scripts/visitor-output.js" ]] \
    || grep -Fq '/scripts/visitor-output.js' "${DOCTOR_DEPLOY_DIR}/docker-compose.yml" 2>/dev/null; then
    DOCTOR_VISITOR_OUTPUT_ENABLED=1
    required+=(scripts/visitor-output.js)
  fi
  if version_at_least "$installed_version" v1.3.0; then
    required+=(scripts/materials-recovery.py scripts/atomic-config.py)
  fi
  start=$(doctor_now_ms)
  for relative in "${required[@]}"; do
    [[ -f "${DOCTOR_DEPLOY_DIR}/${relative}" && ! -L "${DOCTOR_DEPLOY_DIR}/${relative}" ]] || missing+=" ${relative}"
  done
  if [[ -z "$missing" ]]; then
    doctor_add installation.files '生产文件' PASS critical '全部必要生产模块均存在且不是符号链接' filesystem '' "$start"
  else
    doctor_add installation.files '生产文件' FAIL critical "缺失或不安全的生产文件：${missing# }" filesystem '从同版本完整发布包恢复程序文件' "$start"
  fi

  if version_at_least "$installed_version" v1.3.0; then
    start=$(doctor_now_ms)
    shopt -s nullglob
    atomic_artifacts=("${DOCTOR_DEPLOY_DIR}"/.env.source.* "${DOCTOR_DEPLOY_DIR}"/.env.tmp.*)
    shopt -u nullglob
    if [[ -e "${DOCTOR_DEPLOY_DIR}/.env.crispai-atomic.json" \
      || -L "${DOCTOR_DEPLOY_DIR}/.env.crispai-atomic.json" \
      || -e "${DOCTOR_DEPLOY_DIR}/.env.crispai-atomic.next" \
      || -L "${DOCTOR_DEPLOY_DIR}/.env.crispai-atomic.next" ]]; then
      doctor_add config.atomic_transaction '敏感配置提交事务' FAIL critical \
        '发现尚未收口的敏感配置提交事务；当前配置代次不能据此判定完成' filesystem \
        '停止并发配置修改后，从原配置菜单重新保存以执行受控恢复；失败时导出脱敏诊断' "$start"
    elif (( ${#atomic_artifacts[@]} > 0 )); then
      doctor_add config.atomic_transaction '敏感配置提交事务' FAIL critical \
        "发现 ${#atomic_artifacts[@]} 份未归属的受限配置恢复材料；未自动删除" filesystem \
        '不要手工选取或公开这些文件；先导出脱敏诊断并核对当前配置代次' "$start"
    else
      doctor_add config.atomic_transaction '敏感配置提交事务' PASS critical \
        '敏感配置没有未决提交日志或遗留恢复材料' filesystem '' "$start"
    fi
  else
    doctor_skip config.atomic_transaction '敏感配置提交事务' '当前安装版本尚未使用 v1.3.0 原子配置事务' filesystem
  fi

  start=$(doctor_now_ms)
  for relative in runtime provider keyword menu handoff tags feedback logging; do
    doctor_decode_config "$relative" || invalid+=" ${relative}.yaml"
  done
  runtime_config=$(doctor_config_file runtime)
  menu_config=$(doctor_config_file menu)
  handoff_config=$(doctor_config_file handoff)
  if [[ -n "$invalid" ]]; then
    doctor_add config.syntax '配置格式' FAIL critical "无法安全解析的 YAML/JSON 配置：${invalid# }" filesystem '从配置历史恢复后再应用；不要 source 配置文件' "$start"
  elif ! jq -e '.schema_version == 2 and (.enabled | type == "boolean") and (.revision | type == "number") and (.applied_revision | type == "number")' \
      "$runtime_config" >/dev/null 2>&1; then
    doctor_add config.syntax '配置格式' FAIL critical '自动客服配置格式或字段类型无效' filesystem '从配置历史恢复有效配置' "$start"
  elif jq -e '.revision == .applied_revision' "$runtime_config" >/dev/null 2>&1; then
    doctor_add config.syntax '配置格式' PASS critical '配置格式有效，保存值与运行时已应用内容一致' filesystem '' "$start"
  else
    doctor_add config.syntax '配置格式' WARN warning '已保存的配置尚未完成运行时应用' filesystem '使用配置菜单重新同步有效配置' "$start"
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
  if doctor_prepare_applied_business_configs; then
    business_runtime_config="${DOCTOR_TEMP_ROOT}/applied-business/runtime.json"
    business_menu_config="${DOCTOR_TEMP_ROOT}/applied-business/menu.json"
    business_handoff_config="${DOCTOR_TEMP_ROOT}/applied-business/handoff.json"
    business_source='当前生效投影'
  else
    business_projection_rc=$?
    if (( business_projection_rc == 2 )); then
      business_runtime_config=$runtime_config
      business_menu_config=$menu_config
      business_handoff_config=$handoff_config
      business_source='可编辑配置（legacy 无生效投影）'
    else
      business_runtime_config=''
      business_menu_config=''
      business_handoff_config=''
      business_source=''
    fi
  fi
  if [[ -n "$business_runtime_config" && -f "$business_runtime_config" \
      && -f "$business_menu_config" && -f "$business_handoff_config" ]] \
    && jq -e '.enabled | type == "boolean"' "$business_runtime_config" >/dev/null 2>&1 \
    && jq -e '.welcome.enabled | type == "boolean"' "$business_menu_config" >/dev/null 2>&1 \
    && jq -e '.handoff.resume_after_seconds | type == "number" and floor == . and . >= 0 and . <= 604800' \
      "$business_handoff_config" >/dev/null 2>&1; then
    value=$(jq -r 'if .enabled then "启用" else "停用（管理员设置）" end' "$business_runtime_config")
    runtime_mode=$(jq -r 'if .welcome.enabled then "启用" else "停用" end' "$business_menu_config")
    secret_count=$(jq -r '.handoff.resume_after_seconds' "$business_handoff_config")
    doctor_add business.settings '业务开关与恢复' PASS info \
      "${business_source}：客服 ${value}；欢迎语 ${runtime_mode}；自动恢复 ${secret_count} 秒" filesystem '' "$start"
  elif (( business_projection_rc == 1 )); then
    doctor_add business.settings '业务开关与恢复' FAIL critical \
      '生效资料投影不可用；未使用可编辑草稿冒充当前运行值' filesystem \
      '从上一有效投影成套恢复或完成显式资料应用；自检不会改变业务开关' "$start"
  else
    doctor_add business.settings '业务开关与恢复' FAIL critical \
      'legacy 可编辑配置中的业务开关或恢复参数格式无效' filesystem \
      '从配置历史恢复有效值；自检不会自动开启客服或恢复会话' "$start"
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
  if (( DOCTOR_VISITOR_OUTPUT_ENABLED )); then
    doctor_container_file_binding provider.visitor_output_code_binding '访客输出策略运行代' \
      provider-adapter "${DOCTOR_DEPLOY_DIR}/scripts/visitor-output.js" \
      /opt/crisp-ai/scripts/visitor-output.js CRISPAI_EXPECTED_FILE_BINDING_VISITOR_OUTPUT
  else
    doctor_skip provider.visitor_output_code_binding '访客输出策略运行代' \
      '当前程序版本不包含独立访客输出策略模块' docker
  fi
  if (( DOCTOR_POOL_ENABLED )); then
    doctor_container_file_binding provider.router_code_binding '主备路由程序运行代' \
      provider-adapter "${DOCTOR_DEPLOY_DIR}/scripts/provider-router.js" \
      /opt/crisp-ai/scripts/provider-router.js CRISPAI_EXPECTED_FILE_BINDING_ROUTER
    doctor_container_file_binding provider.envelope_code_binding '推理预算认证程序运行代' \
      provider-adapter "${DOCTOR_DEPLOY_DIR}/scripts/provider-envelope.js" \
      /opt/crisp-ai/scripts/provider-envelope.js CRISPAI_EXPECTED_FILE_BINDING_ENVELOPE
  fi
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
    DOCTOR_DB_READY=1
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
    schema = value.get("schema_version")
    prompt = value.get("prompt")
    components = value.get("source_components")
    if type(schema) is not int or schema != 2 or value.get("state") != "applied" \
            or not isinstance(prompt, dict) or set(prompt) != {"text", "sha256", "bytes"} \
            or not isinstance(components, dict):
        raise ValueError("invalid projection")
    text = prompt.get("text")
    if not isinstance(text, str) or not text.strip() or "\x00" in text:
        raise ValueError("invalid prompt")
    encoded = text.encode("utf-8")
    if len(encoded) != prompt.get("bytes"):
        raise ValueError("invalid prompt")
    if len(encoded) > 262_144 or hashlib.sha256(encoded).hexdigest() != prompt.get("sha256") \
            or components.get("prompt") != prompt.get("sha256"):
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
  # files/config 检查已把权威投影复制到 doctor 私有目录，并通过生产
  # materials_projection_validate 完整核验。AnythingLLM 必须从同一次冻结的
  # schema v2 投影读取 Prompt，不能重新读取可能并发变化的原文件，也不能在
  # 权威投影损坏时回退到可编辑草稿。
  projection="${DOCTOR_TEMP_ROOT}/applied-business/materials-applied.json"
  expected_prompt="${DOCTOR_TEMP_ROOT}/anything-expected-prompt"
  # --fix 会在同一进程内复查一次；只删除本次 doctor 私有临时文件，
  # 避免第二轮因 O_EXCL 将有效投影误报为损坏。
  rm -f -- "$expected_prompt"
  case "$DOCTOR_APPLIED_BUSINESS_STATE" in
    ready)
      if [[ -f "$projection" && ! -L "$projection" ]] \
        && doctor_projection_prompt_extract "$projection" "$expected_prompt" >/dev/null 2>&1; then
        prompt_valid=1
      fi
      ;;
    absent)
      prompt_source=legacy
      if doctor_legacy_prompt_extract "${DOCTOR_DEPLOY_DIR}/config/prompt.md" "$expected_prompt" >/dev/null 2>&1; then prompt_valid=1; fi
      ;;
    *)
      # 当前轮次未完成私有投影的清理、复制与完整验证；即使同进程
      # --fix 复查留有上轮文件，也不得消费它或回退到可编辑原文。
      :
      ;;
  esac
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

doctor_knowledge_metadata_check() {
  local start report rc=0 workspace kind status summary name
  start=$(doctor_now_ms)
  report="${DOCTOR_TEMP_ROOT}/knowledge-metadata.json"
  workspace=$(env_get "${DOCTOR_DEPLOY_DIR}/.env" ANYTHINGLLM_WORKSPACE 2>/dev/null || true)
  # 只核验本机元数据和已存在缓存；-B 禁止导入校验器时生成 __pycache__。
  doctor_timeout 15 python3 -B - "$DOCTOR_DEPLOY_DIR" "$workspace" > "$report" 2>/dev/null <<'PY' || rc=$?
import hashlib
import importlib.util
import json
import math
from pathlib import Path
import re
import stat
import sys

root = Path(sys.argv[1])
workspace = sys.argv[2]
hex64 = lambda value: isinstance(value, str) and re.fullmatch(r"[a-f0-9]{64}", value) is not None
result = {name: {"status": "FAIL", "summary": "知识元数据校验未完成；未把当前索引判为可用"} for name in ("profile", "settings")}

def read(relative, maximum=65536, optional=False, protected=True):
    path = root
    for part in relative.split("/"):
        path /= part
        if path.is_symlink():
            raise ValueError
    try:
        info = path.stat()
    except FileNotFoundError:
        if optional:
            return None, None
        raise
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_size > maximum \
            or protected and stat.S_IMODE(info.st_mode) & 0o137:
        raise ValueError
    raw = path.read_bytes()
    return json.loads(raw), hashlib.sha256(raw).hexdigest()

def checked_profile(module, applied):
    expected = applied.get("knowledge", {}).get("profile_sha256", "")
    current, current_hash = read("data/runtime/knowledge-profile.json", optional=True)
    manifest, manifest_hash = read("data/knowledge-manifest.json", 16777216)
    if not isinstance(manifest, dict) or not isinstance(manifest.get("files"), dict):
        raise ValueError
    if (root / "data/runtime/knowledge-migration.json").exists() or (root / "data/runtime/knowledge-migration.json").is_symlink():
        return {"status": "FAIL", "summary": "知识迁移尚未完成或恢复，自动回复必须保持受阻止"}
    if current is None:
        if applied.get("schema_version") == 2 and applied.get("knowledge", {}).get("enabled_document_count") == 0 and expected == "":
            return {"status": "PASS", "summary": "当前没有启用知识文档，不要求知识索引代次文件；未执行模型请求"}
        legacy = expected == "" and not manifest.get("embedding_profile") and all(
            isinstance(item, dict) and not item.get("embedding_profile") and not item.get("cache_bindings")
            for item in manifest["files"].values())
        return {"status": "WARN" if legacy else "FAIL", "summary":
                "旧知识索引尚无已验证模型代次；未声明中文召回质量已确认" if legacy else "知识索引代次文件缺失，但有效资料或文档仍引用该代次"}
    if not isinstance(current, dict) or current.get("schema_version") != 1:
        raise ValueError
    if current.get("state") != "applied":
        return {"status": "FAIL", "summary": "知识索引代次尚未完整应用，自动回复必须保持受阻止"}
    key = current.get("fingerprint")
    value = current.get("profile")
    if not hex64(expected) or current_hash != expected or not hex64(key) or not isinstance(value, dict) \
            or module.fingerprint(value) != key or module.profile(value) != value:
        return {"status": "FAIL", "summary": "知识模型正文、指纹或资料投影文件摘要不一致"}
    if manifest.get("version") != 1 or manifest.get("embedding_profile") != key \
            or manifest.get("pending_files") != {} or manifest.get("garbage_locations") != [] \
            or applied.get("knowledge", {}).get("manifest_sha256") != manifest_hash:
        return {"status": "FAIL", "summary": "知识 manifest 尚未完成对账或不属于当前资料与模型代次"}
    locations_seen = set()
    for item in manifest["files"].values():
        if not isinstance(item, dict) or item.get("embedding_profile") != key:
            raise ValueError
        locations, bindings = item.get("locations"), item.get("cache_bindings")
        if not isinstance(locations, list) or not locations or not all(isinstance(location, str) for location in locations) \
                or len(set(locations)) != len(locations) or locations_seen.intersection(locations) \
                or not isinstance(bindings, list) or len(bindings) != len(locations):
            raise ValueError
        locations_seen.update(locations)
        by_location = {}
        for binding in bindings:
            if not isinstance(binding, dict) or binding.get("location") not in locations \
                    or binding["location"] in by_location or not hex64(binding.get("sha256")):
                raise ValueError
            by_location[binding["location"]] = binding["sha256"]
        if set(by_location) != set(locations):
            raise ValueError
        for location in locations:
            cached = module.cache_path(root, location)
            info = cached.stat()
            if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_size == 0 or module.digest(cached) != by_location[location]:
                raise ValueError
    if value["model"] == "Xenova/all-MiniLM-L6-v2":
        return {"status": "WARN", "summary": "已核对保留的英文 MiniLM 索引代；中文召回能力受限，词法补召回需另行核验"}
    return {"status": "PASS", "summary": "已应用模型正文、指纹、全部文档缓存及资料投影摘要一致；未执行模型请求"}

def checked_settings(applied):
    value, digest = read("data/runtime/knowledge-settings.json", optional=True)
    expected = applied.get("knowledge", {}).get("settings_sha256", "")
    if value is None:
        legacy = expected == "" and not applied.get("knowledge", {}).get("profile_sha256")
        return {"status": "WARN" if legacy else "FAIL", "summary":
                "旧资料尚无已验证知识运行设置，未声明温度配置已对账" if legacy else "当前资料引用的知识运行设置缺失"}
    if not isinstance(value, dict) or value.get("schema_version") != 1 \
            or not re.fullmatch(r"[A-Za-z0-9_-]{1,128}", workspace) or value.get("workspace_slug") != workspace \
            or type(value.get("temperature")) not in (int, float) or not math.isfinite(value["temperature"]) or not 0 <= value["temperature"] <= 2 \
            or type(value.get("observed_at")) is not int or value["observed_at"] < 0 \
            or not hex64(expected) or digest != expected:
        return {"status": "FAIL", "summary": "知识工作区、温度或运行设置文件摘要与当前资料不一致"}
    return {"status": "PASS", "summary": "知识工作区、合法温度与资料投影摘要一致；默认自检未发起检索或推理"}

try:
    applied, _ = read("config/materials-applied.json", 16777216, optional=True)
    if applied is None:
        result = {name: {"status": "WARN", "summary": "旧实例尚无有效资料投影，知识运行代次未确认"} for name in result}
    elif not isinstance(applied, dict) or applied.get("schema_version") != 2 or applied.get("state") != "applied":
        result = {name: {"status": "FAIL", "summary": "资料应用尚未完成，知识运行代次不能判为可用"} for name in result}
    else:
        for name, check in (("settings", lambda: checked_settings(applied)), ("profile", None)):
            try:
                if name == "profile":
                    module_path = root / "scripts/knowledge-profile.py"
                    if module_path.is_symlink() or not module_path.is_file():
                        raise ValueError
                    spec = importlib.util.spec_from_file_location("doctor_knowledge_profile", module_path)
                    module = importlib.util.module_from_spec(spec)
                    spec.loader.exec_module(module)
                    result[name] = checked_profile(module, applied)
                else:
                    result[name] = check()
            except Exception:
                pass
except Exception:
    pass
print(json.dumps(result, ensure_ascii=False))
PY
  if (( rc == 124 || rc == 137 )) || ! doctor_remaining >/dev/null; then
    doctor_deadline_add knowledge.profile '知识模型与索引代次' filesystem "$start"
    doctor_deadline_add knowledge.settings '知识工作区运行设置' filesystem "$start"
    return
  fi
  for kind in profile settings; do
    name='知识模型与索引代次'; [[ "$kind" != settings ]] || name='知识工作区运行设置'
    if (( rc != 0 )) || ! jq -e --arg kind "$kind" '.[$kind] | (.status == "PASS" or .status == "WARN" or .status == "FAIL") and (.summary | type == "string")' "$report" >/dev/null 2>&1; then
      doctor_add "knowledge.${kind}" "$name" FAIL critical '知识只读校验没有返回完整结果' filesystem '完成当前知识资料应用或从受管备份恢复；不要删除原文或重建全部索引来伪造成功' "$start"
    else
      status=$(jq -r --arg kind "$kind" '.[$kind].status' "$report")
      summary=$(jq -r --arg kind "$kind" '.[$kind].summary' "$report")
      doctor_add "knowledge.${kind}" "$name" "$status" critical "$summary" filesystem \
        "$([[ "$status" == PASS ]] || printf '%s' '通过知识资料受管入口完成同步或恢复；默认自检不会改变索引及客服开关')" "$start"
    fi
  done
}

doctor_knowledge_index_digest() {
  doctor_timeout 5 python3 -B - "$DOCTOR_DEPLOY_DIR" <<'PY'
import hashlib
import os
from pathlib import Path
import stat
import sys

path = Path(sys.argv[1])
for part in ("data", "runtime", "knowledge-lexical.json"):
    path /= part
    if path.is_symlink():
        raise SystemExit(1)
descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
try:
    before = os.fstat(descriptor)
    if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1 or before.st_size > 16777216:
        raise SystemExit(1)
    digest = hashlib.sha256()
    total = 0
    while True:
        chunk = os.read(descriptor, 1048576)
        if not chunk:
            break
        total += len(chunk)
        if total > 16777216:
            raise SystemExit(1)
        digest.update(chunk)
    after = os.fstat(descriptor)
    if (before.st_size, before.st_mtime_ns, before.st_ctime_ns) != (after.st_size, after.st_mtime_ns, after.st_ctime_ns):
        raise SystemExit(1)
    print(digest.hexdigest())
finally:
    os.close(descriptor)
PY
}

doctor_knowledge_lexical_check() {
  local start projection expected actual report rc=0 count bytes
  start=$(doctor_now_ms)
  projection="${DOCTOR_DEPLOY_DIR}/config/materials-applied.json"
  report="${DOCTOR_TEMP_ROOT}/knowledge-lexical-verify.json"
  if [[ ! -e "$projection" && ! -L "$projection" ]]; then
    doctor_add knowledge.lexical '知识词法补召回' WARN warning '旧实例尚无已绑定的词法补召回投影，未判为已验证' filesystem '通过受管知识资料应用建立当前启用范围的索引' "$start"
    return
  fi
  if [[ ! -f "$projection" || -L "$projection" ]] \
    || ! jq -e '.schema_version == 2 and .state == "applied"' "$projection" >/dev/null 2>&1; then
    doctor_add knowledge.lexical '知识词法补召回' FAIL critical '资料应用尚未完成，词法索引不能判为可用' filesystem '完成当前受管知识应用或恢复；不要删除原资料' "$start"
    return
  fi
  expected=$(jq -r '.knowledge.lexical_sha256 // ""' "$projection")
  if [[ -z "$expected" ]]; then
    doctor_add knowledge.lexical '知识词法补召回' WARN warning '旧资料投影未绑定词法补召回，未借未引用文件判断检索可用' filesystem '通过受管知识资料应用补齐；默认自检不构建索引' "$start"
    return
  fi
  if [[ ! "$expected" =~ ^[a-f0-9]{64}$ \
    || ! -f "${DOCTOR_DEPLOY_DIR}/scripts/knowledge-lexical.py" || -L "${DOCTOR_DEPLOY_DIR}/scripts/knowledge-lexical.py" ]] \
    || ! actual=$(doctor_knowledge_index_digest 2>/dev/null) || [[ "$actual" != "$expected" ]]; then
    doctor_add knowledge.lexical '知识词法补召回' FAIL critical '词法索引缺失、不安全或文件摘要偏离有效资料' filesystem '重新应用当前启用资料并核对投影；不要手工改写摘要' "$start"
    return
  fi
  doctor_timeout 15 python3 -B "${DOCTOR_DEPLOY_DIR}/scripts/knowledge-lexical.py" verify --deploy-dir "$DOCTOR_DEPLOY_DIR" \
    > "$report" 2>/dev/null || rc=$?
  if (( rc == 124 || rc == 137 )) || ! doctor_remaining >/dev/null; then
    doctor_deadline_add knowledge.lexical '知识词法补召回' filesystem "$start"
  elif (( rc != 0 )) || ! jq -e '.ok == true and .read_only == true and .schema_version == 2
    and (.complete | type == "boolean") and (.coverage | type == "object")
    and all([.coverage.omitted_documents,.coverage.omitted_bytes][]; type == "number" and floor == . and . >= 0)
    and (.map_sha256 | type == "string" and test("^[a-f0-9]{64}$"))' "$report" >/dev/null 2>&1 \
    || ! jq -e --slurpfile checked "$report" --arg expected "$expected" \
      '.state == "applied" and .knowledge.lexical_sha256 == $expected and .knowledge.map_sha256 == $checked[0].map_sha256' "$projection" >/dev/null 2>&1 \
    || [[ "$(doctor_knowledge_index_digest 2>/dev/null || true)" != "$actual" ]]; then
    doctor_add knowledge.lexical '知识词法补召回' FAIL critical '词法 schema、片段、启用映射或实际解析源校验未通过' filesystem '从受管知识入口重新对账对应资料；不能将校验错误冒充无命中' "$start"
  elif jq -e '.complete == true' "$report" >/dev/null; then
    doctor_add knowledge.lexical '知识词法补召回' PASS critical '词法索引、资料摘要、启用映射及完整解析源覆盖一致；未加载模型' filesystem '' "$start"
  else
    count=$(jq -r '.coverage.omitted_documents' "$report")
    bytes=$(jq -r '.coverage.omitted_bytes' "$report")
    doctor_add knowledge.lexical '知识词法补召回' WARN warning \
      "词法索引有效但存在容量遗漏：${count} 份文档、${bytes} 字节尚未覆盖" filesystem \
      '查看资料容量及分段情况；未覆盖内容不能据此认定知识库没有相关事实' "$start"
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
    [ "${N8N_RUNNERS_MAX_CONCURRENCY:-}" = 10 ] || exit 1
    output=$(mktemp /tmp/crispai-doctor-workflow.XXXXXX)
    trap '\''rm -f "$output"'\'' EXIT
    timeout 20 n8n export:workflow --id="$1" --output="$output" >/dev/null 2>&1
    node - "$output" "$1" "$2" "$3" /opt/crisp-ai/n8n/runtime.js /opt/crisp-ai/n8n/knowledge-lexical.js /opt/crisp-ai/scripts/visitor-output.js "$4" "$5" <<'\''NODE'\''
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
const lexicalFile=fs.readFileSync(process.argv[7],"utf8");
const visitorOutputFile=fs.readFileSync(process.argv[8],"utf8");
const lexicalSource=lexicalFile.replace(/^module\.exports[^\n]+\n?$/m,"");
const visitorOutputSource=visitorOutputFile.replace(/^\x27use strict\x27;\n?/m,"")
  .replace(/^module\.exports\s*=\s*\{[\s\S]*?\};\r?\n?/m,"");
const runtimeSource=runtimeFile.replace(/^const \{\s*searchKnowledgeLexical\s*\} = require\('\''\.\/knowledge-lexical\.js'\''\);\r?\n/m,"")
  .replace(/^const \{\s*LEGACY_GENERIC_NON_ANSWERS,\s*visitorFallbackFor,\s*mechanicalFailureAnswer,\s*legacyGenericNonAnswer,\s*sanitizeVisitorText\s*\} = require\('\''\.\.\/scripts\/visitor-output\.js'\''\);\r?\n/m,"")
  .replace(/^if \(typeof module[^\n]+\n?$/m,"");
if (/require\(["'\''](?:\.\/knowledge-lexical\.js|\.\.\/scripts\/visitor-output\.js)["'\'']\)/.test(runtimeSource)) process.exit(1);
const source=(lexicalSource+"\n"+visitorOutputSource+"\n"+runtimeSource)
  .replace(/ai_support_version: '\''v[^'\'']+'\''/g,"ai_support_version: '\''"+process.argv[4]+"'\''");
const sourceHash=crypto.createHash("sha256").update(source).digest("hex");
const fileHash=crypto.createHash("sha256").update(runtimeFile).digest("hex");
const lexicalHash=crypto.createHash("sha256").update(lexicalFile).digest("hex");
const visitorOutputHash=crypto.createHash("sha256").update(visitorOutputFile).digest("hex");
const runtimePrefix=source+"\nconst runtime = createRuntime($env);\n";
const runtimeNodeNames=["校验并持久接收","处理持久任务","扫描持久会话与任务","只读公开显示选项"];
const runtimeNodesMatch=runtimeNodeNames.every(name=>{
  const node=nodes.find(candidate=>candidate.name===name && String(candidate.type).includes("code"));
  return node && String(node.parameters?.jsCode||"").startsWith(runtimePrefix);
});
if (workflow.id!==process.argv[3] || workflow.active!==true || !types.some(type=>type.endsWith(".webhook")) ||
    !schedule || !scanner || !scheduleTargets.includes(scanner.name) || !code.includes("runtime.receive") ||
    !code.includes("runtime.process") || !code.includes("runtime.scan") ||
    workflow.meta?.aiSupportVersion!==process.argv[4] || workflow.meta?.n8nRunnerConcurrency!==10 ||
    workflow.meta?.backgroundProcessingPermits!==8 || workflow.meta?.ordinaryProcessingPermits!==7 || workflow.meta?.runtimeFileSha256!==fileHash ||
    workflow.meta?.runtimeFileSha256!==process.argv[5] || workflow.meta?.runtimeSha256!==sourceHash ||
    workflow.meta?.lexicalFileSha256!==lexicalHash || workflow.meta?.lexicalFileSha256!==process.argv[9] ||
    workflow.meta?.visitorOutputFileSha256!==visitorOutputHash || workflow.meta?.visitorOutputFileSha256!==process.argv[10] ||
    !runtimeNodesMatch) process.exit(1);
process.stdout.write("verified\n");
NODE
  ' sh "$WORKFLOW_ID" "$(sed -n '1p' "${DOCTOR_DEPLOY_DIR}/VERSION")" \
    "$(sha256sum "${DOCTOR_DEPLOY_DIR}/n8n/runtime.js" | cut -d ' ' -f 1)" \
    "$(sha256sum "${DOCTOR_DEPLOY_DIR}/n8n/knowledge-lexical.js" | cut -d ' ' -f 1)" \
    "$(sha256sum "${DOCTOR_DEPLOY_DIR}/scripts/visitor-output.js" | cut -d ' ' -f 1)" \
    < /dev/null > "$workflow_output" 2>/dev/null \
    && grep -Fxq verified "$workflow_output"; then
    doctor_add n8n.workflow 'n8n 生产工作流' PASS critical '目标 workflow 已激活，runner 并发预留、运行时及词法内联代码与当前挂载摘要一致' docker '' "$start"
  else
    if ! doctor_remaining >/dev/null 2>&1; then
      doctor_deadline_add n8n.workflow 'n8n 生产工作流' docker "$start"
      doctor_skip n8n.runtime 'n8n Code runner' '因自检总截止时间已到未检查' local-api
      return
    fi
    doctor_add n8n.workflow 'n8n 生产工作流' FAIL critical '目标 workflow 未激活、runner 并发不是 10、版本偏离或无法导出验证' docker '从受管安装/更新流程重新创建 n8n 并导入发布目标 workflow' "$start"
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

doctor_n8n_execution_backlog_check() {
  local start managed_user managed_db managed_password output rc=0 active older_two older_ten runtime_status
  start=$(doctor_now_ms)
  if (( DOCTOR_DOCKER_READY == 0 )); then
    doctor_skip n8n.execution_backlog 'n8n 生产执行积压' '因 Docker daemon 不可用未检查' docker
    return
  fi
  if (( DOCTOR_DB_READY == 0 )); then
    doctor_skip n8n.execution_backlog 'n8n 生产执行积压' '因数据库应用认证未通过未检查' docker
    return
  fi
  if ! doctor_remaining >/dev/null 2>&1; then
    doctor_deadline_add n8n.execution_backlog 'n8n 生产执行积压' docker "$start"
    return
  fi
  managed_user=$(env_get "${DOCTOR_DEPLOY_DIR}/.env" POSTGRES_USER 2>/dev/null || printf crisp_ai)
  managed_db=$(env_get "${DOCTOR_DEPLOY_DIR}/.env" POSTGRES_DB 2>/dev/null || printf n8n)
  managed_password=$(env_get "${DOCTOR_DEPLOY_DIR}/.env" POSTGRES_PASSWORD 2>/dev/null || true)
  output="${DOCTOR_TEMP_ROOT}/n8n-execution-backlog.txt"
  # 只按本项目固定 workflow 统计状态与年龄，不读取 execution_data、客户消息或节点输入。
  # 数据库密码只经 stdin 进入容器；workflow id 在容器内再次限制为 UUID。
  # shellcheck disable=SC2016
  printf '%s\n%s\n%s\n%s\n' "$managed_user" "$managed_db" "$managed_password" "$WORKFLOW_ID" \
    | doctor_compose_timeout 15 exec -T postgres sh -ec '
        IFS= read -r managed_user
        IFS= read -r managed_db
        IFS= read -r managed_password
        IFS= read -r workflow_id
        case "$workflow_id" in
          ????????-????-????-????-????????????) ;;
          *) exit 64 ;;
        esac
        export PGPASSWORD="$managed_password"
        psql -h postgres -U "$managed_user" -d "$managed_db" -AtF "|" -v ON_ERROR_STOP=1 -c "
          SELECT
            count(*),
            count(*) FILTER (WHERE COALESCE(\"startedAt\", \"createdAt\") < CURRENT_TIMESTAMP - INTERVAL '\''2 minutes'\''),
            count(*) FILTER (WHERE COALESCE(\"startedAt\", \"createdAt\") < CURRENT_TIMESTAMP - INTERVAL '\''10 minutes'\'')
          FROM execution_entity
          WHERE \"workflowId\" = '\''${workflow_id}'\''
            AND \"deletedAt\" IS NULL
            AND status IN ('\''new'\'', '\''running'\'', '\''waiting'\'');"
      ' > "$output" 2>/dev/null || rc=$?
  if (( rc != 0 )) || ! IFS='|' read -r active older_two older_ten < "$output" \
    || [[ ! "$active" =~ ^[0-9]+$ || ! "$older_two" =~ ^[0-9]+$ || ! "$older_ten" =~ ^[0-9]+$ ]]; then
    doctor_add n8n.execution_backlog 'n8n 生产执行积压' WARN warning '无法只读统计生产 workflow 的执行积压，未将未知结果判为正常' docker '检查 n8n 数据库 schema、应用权限及自检时限；不要读取 execution 正文排障' "$start"
    return
  fi
  runtime_status=$(doctor_result_status n8n.runtime)
  if [[ "$runtime_status" == FAIL ]] && (( active >= 20 || older_ten > 0 )); then
    doctor_add n8n.execution_backlog 'n8n 生产执行积压' FAIL critical \
      "生产 Code runner 不可用且有 ${active} 个未终止执行（超过 2 分钟 ${older_two}，超过 10 分钟 ${older_ten}）" docker \
      '检查五秒调度扫描是否重复排队或阻塞；先修 workflow/runtime，不能只因容器 running 判正常' "$start"
  elif (( older_ten > 0 || older_two >= 20 || active > 32 )); then
    doctor_add n8n.execution_backlog 'n8n 生产执行积压' WARN warning \
      "发现 ${active} 个未终止执行（超过 2 分钟 ${older_two}，超过 10 分钟 ${older_ten}）；当前 Code runner ${runtime_status}" docker \
      '观察数量是否继续增长并检查调度心跳；历史异常记录按 n8n 受管保留策略清理，不手写删除业务记录' "$start"
  elif (( active > 16 || older_two > 0 )); then
    doctor_add n8n.execution_backlog 'n8n 生产执行积压' WARN warning \
      "当前有 ${active} 个未终止执行，其中 ${older_two} 个超过 2 分钟；尚未达到明确阻塞门槛" docker \
      '稍后复查 Code runner 和调度心跳；自检不会取消正在处理的任务' "$start"
  else
    doctor_add n8n.execution_backlog 'n8n 生产执行积压' PASS critical \
      "当前未终止执行 ${active} 个，未发现超过 2 分钟的异常积压" docker '' "$start"
  fi
}

doctor_provider_pool_files() {
  local start count desired actual internal aggregate configured valid_files=false
  DOCTOR_POOL_READY=0
  DOCTOR_RAG_CONTEXT_WINDOW=''
  (( DOCTOR_POOL_ENABLED )) || return 0
  start=$(doctor_now_ms)
  if doctor_timeout 6 python3 "${DOCTOR_DIR}/provider-pool.py" --deploy-dir "$DOCTOR_DEPLOY_DIR" list \
    > "${DOCTOR_TEMP_ROOT}/provider-pool.json" 2>/dev/null \
    && jq -e '.ok == true and (.entries | length > 0 and length <= 21)' "${DOCTOR_TEMP_ROOT}/provider-pool.json" >/dev/null 2>&1; then
    internal=$(env_get "${DOCTOR_DEPLOY_DIR}/.env" PROVIDER_ADAPTER_KEY 2>/dev/null || true)
    if ! is_placeholder "$internal" && [[ "$internal" != "$(env_get "${DOCTOR_DEPLOY_DIR}/.env" AI_API_KEY 2>/dev/null || true)" ]]; then
      DOCTOR_POOL_READY=1
      count=$(jq '.entries | length - 1' "${DOCTOR_TEMP_ROOT}/provider-pool.json")
      doctor_add provider.configuration 'AI 主备配置与秘密引用' PASS critical "1 个主接口，${count}/20 个备用；角色、顺序及秘密代次已验证" filesystem '' "$start"
    fi
  fi
  if (( DOCTOR_POOL_READY == 0 )); then
    if ! doctor_remaining >/dev/null 2>&1; then
      doctor_deadline_add provider.configuration 'AI 主备配置与秘密引用' filesystem "$start"
    else
      doctor_add provider.configuration 'AI 主备配置与秘密引用' FAIL critical '接口池有效投影、数量、主角色、秘密代次或内部认证无效' filesystem '从菜单 3 恢复有效接口配置；不要把 Key 写进可分享文件' "$start"
    fi
    return
  fi
  start=$(doctor_now_ms)
  if [[ -e "${DOCTOR_DEPLOY_DIR}/config/provider-pool-transaction.json" \
    || -L "${DOCTOR_DEPLOY_DIR}/config/provider-pool-transaction.json" ]]; then
    doctor_add provider.rag_transaction '主备配置应用事务' FAIL critical '存在尚未完成的接口池应用，推理保持受保护状态；不能沿用旧健康结果' filesystem '若操作已中断，从菜单 3 → 10 → 12 恢复；不要手动删除事务文件' "$start"
  else
    doctor_add provider.rag_transaction '主备配置应用事务' PASS critical '无未完成的接口池应用事务' filesystem '' "$start"
  fi
  start=$(doctor_now_ms)
  if doctor_timeout 5 python3 "${DOCTOR_DIR}/provider-pool.py" --deploy-dir "$DOCTOR_DEPLOY_DIR" readback \
    > "${DOCTOR_TEMP_ROOT}/provider-pool-readback-status.json" 2>/dev/null \
    && jq -e '.ok == true and .state == "verified" and (.revision | type == "number")
      and (.entries | type == "number" and . > 0 and . <= 21)
      and (.verified_at | type == "number" and . > 0)' \
      "${DOCTOR_TEMP_ROOT}/provider-pool-readback-status.json" >/dev/null 2>&1; then
    doctor_add provider.readback '主备推理准入回执' PASS critical '准入回执与当前有效投影、秘密代次及原始文件摘要一致；实时组件身份另见 adapter 检查' filesystem '' "$start"
  elif ! doctor_remaining >/dev/null 2>&1; then
    doctor_deadline_add provider.readback '主备推理准入回执' filesystem "$start"
  else
    doctor_add provider.readback '主备推理准入回执' FAIL critical '当前接口池没有可信的同代准入回执，推理已保持暂停' filesystem '先恢复未完成配置事务，再执行受管 verify-applied；不要手动伪造回读文件' "$start"
  fi
  start=$(doctor_now_ms)
  aggregate=$(jq -er '
    def integer: type == "number" and floor == .;
    if (.entries | type) != "array" or (.entries | length) == 0 or
      any(.entries[]; . as $entry |
        ($entry.enabled | type) != "boolean" or
        (($entry | has("draft")) and ($entry.draft | type) != "boolean") or
        ($entry.enabled == true and $entry.draft == true) or
        ($entry.api_mode != "chat_completions" and $entry.api_mode != "responses") or
        ($entry.capabilities | type) != "object" or
        ($entry.capabilities[$entry.api_mode] | type) != "boolean" or
        (($entry.context_window | integer) | not) or $entry.context_window < 256 or $entry.context_window > 2097152 or
        (($entry.max_output_tokens | integer) | not) or $entry.max_output_tokens < 1 or
        $entry.max_output_tokens >= $entry.context_window)
    then error("invalid provider budget fields")
    else [.entries[] | . as $entry | select(.enabled == true and .draft != true
      and $entry.capabilities[$entry.api_mode] == true) |
      (.context_window - .max_output_tokens)] as $budgets |
      if ($budgets | length) == 0 then error("no capable provider")
      elif ($budgets | min) < 256 then error("provider input budget too small")
      else ($budgets | min) end
    end' \
    "${DOCTOR_TEMP_ROOT}/provider-pool.json" 2>/dev/null || true)
  configured=$(env_get "${DOCTOR_DEPLOY_DIR}/.env" PROVIDER_RAG_CONTEXT_WINDOW 2>/dev/null || true)
  if [[ "$aggregate" =~ ^[1-9][0-9]{2,6}$ && "$configured" == "$aggregate" ]] \
    && (( aggregate >= 256 && aggregate < 2097152 )); then
    DOCTOR_RAG_CONTEXT_WINDOW=$aggregate
    doctor_add provider.rag_configuration '主备知识上下文预算' PASS critical '共同输入估算上限与启用候选及受管环境一致；AnythingLLM仅将它作为保守预处理参数，逐请求仍由Router复核' filesystem '' "$start"
  else
    doctor_add provider.rag_configuration '主备知识上下文预算' FAIL critical '共同输入估算上限、启用候选与知识组件预处理参数不一致或缺失' filesystem '从菜单 3 校验并应用接口配置；不要单独修改容器环境或重建知识索引' "$start"
  fi
  start=$(doctor_now_ms)
  if doctor_timeout 5 python3 "${DOCTOR_DIR}/provider-pool.py" --deploy-dir "$DOCTOR_DEPLOY_DIR" validate-file \
    "${DOCTOR_DEPLOY_DIR}/config/provider-pool.yaml" > /dev/null 2>&1 \
    && configuration_decode_file "${DOCTOR_DEPLOY_DIR}/config/provider-pool.yaml" "${DOCTOR_TEMP_ROOT}/provider-source.json" >/dev/null 2>&1; then
    desired=$(jq -McS '{primary_id,entries,policy}' "${DOCTOR_TEMP_ROOT}/provider-source.json")
    actual=$(jq -McS '{primary_id,entries:(.entries|map(del(.key_status))),policy}' "${DOCTOR_TEMP_ROOT}/provider-pool.json")
    if [[ "$desired" == "$actual" ]]; then
      doctor_add provider.pending '接口池原文应用状态' PASS warning '可编辑原文与当前有效接口池一致' filesystem '' "$start"
    else
      doctor_add provider.pending '接口池原文应用状态' WARN warning '接口池原文存在未应用变更，运行时仍使用上一份有效配置' filesystem '校验后从菜单 16 应用资料或执行 crispai apply' "$start"
    fi
  else
    doctor_add provider.pending '接口池原文应用状态' WARN warning '接口池编辑稿缺失或无效，当前有效池未被该编辑稿覆盖' filesystem '修正 config/provider-pool.yaml 后重新应用' "$start"
  fi
  start=$(doctor_now_ms)
  if doctor_timeout 4 python3 - "$DOCTOR_DEPLOY_DIR" 2>/dev/null <<'PY'
import json, pathlib, stat, sys
root = pathlib.Path(sys.argv[1])
value = json.loads((root / 'config/provider-pool-applied.json').read_text())
paths = [root / 'secrets', root / 'secrets/provider', root / 'secrets/provider/generations',
         root / 'secrets/provider/generations' / (value['secrets_generation'] + '.json')]
for file in paths:
    info = file.lstat()
    if file.is_symlink() or info.st_uid != 0 or info.st_gid != 1000 or stat.S_IMODE(info.st_mode) != (0o750 if file.is_dir() else 0o640):
        sys.exit(1)
PY
  then valid_files=true; fi
  if [[ "$valid_files" == true ]]; then
    doctor_add provider.secret_permissions '接口秘密访问权限' PASS critical '秘密目录及当前代文件仅供受管身份读取，未输出内容' filesystem '' "$start"
  elif ! doctor_remaining >/dev/null 2>&1; then
    doctor_deadline_add provider.secret_permissions '接口秘密访问权限' filesystem "$start"
  else
    doctor_add provider.secret_permissions '接口秘密访问权限' FAIL critical '接口秘密所有权或权限不符合受管边界' filesystem '执行 crispai doctor --fix 修复受管权限；不要设置 777' "$start"
  fi
}

doctor_pool_rag_context_check() {
  local start port key response status output
  start=$(doctor_now_ms)
  if (( DOCTOR_POOL_READY == 0 || DOCTOR_DOCKER_READY == 0 )) \
    || [[ -z "$DOCTOR_RAG_CONTEXT_WINDOW" ]]; then
    doctor_skip anything.rag_context 'AnythingLLM 实际上下文预算' '因有效接口池、预算投影或 Docker 不可验证，本次未检查' docker
    return
  fi
  output="${DOCTOR_TEMP_ROOT}/rag-context-binding.txt"
  if ! printf '%s' "$DOCTOR_RAG_CONTEXT_WINDOW" | doctor_compose_timeout 8 exec -T anythingllm node -e '
    const marker="CRISPAI_EXPECTED_RAG_CONTEXT",fs=require("fs");
    const expected=fs.readFileSync(0,"utf8");
    if(!marker||expected!==process.env.GENERIC_OPEN_AI_MODEL_TOKEN_LIMIT)process.exit(1);
    process.stdout.write("matched\n");
  ' > "$output" 2>/dev/null || ! grep -Fxq matched "$output"; then
    if ! doctor_remaining >/dev/null 2>&1; then
      doctor_deadline_add anything.rag_context 'AnythingLLM 实际上下文预算' docker "$start"
    else
      doctor_add anything.rag_context 'AnythingLLM 实际上下文预算' FAIL critical '运行容器未使用当前主备知识预算' docker '通过菜单 3 重新应用上下文配置；不必重新导入知识' "$start"
    fi
    return
  fi
  port=$(env_get "${DOCTOR_DEPLOY_DIR}/.env" ANYTHINGLLM_PORT 2>/dev/null || printf 3001)
  key=$(env_get "${DOCTOR_DEPLOY_DIR}/.env" ANYTHINGLLM_API_KEY 2>/dev/null || true)
  response="${DOCTOR_TEMP_ROOT}/anything-system.json"
  status=$(doctor_anything_read_probe "$port" "$key" system "$response")
  if [[ "$status" == 2?? ]] && jq -e --arg expected "$DOCTOR_RAG_CONTEXT_WINDOW" \
    '.settings.GenericOpenAiTokenLimit | tostring == $expected' "$response" >/dev/null 2>&1; then
    doctor_add anything.rag_context 'AnythingLLM 实际上下文预算' PASS critical '容器环境与鉴权 API 回读一致；未调用模型，具体问题仍经逐接口预算和 Prompt 完整性检查' local-api '' "$start"
  elif ! doctor_remaining >/dev/null 2>&1; then
    doctor_deadline_add anything.rag_context 'AnythingLLM 实际上下文预算' local-api "$start"
  else
    doctor_add anything.rag_context 'AnythingLLM 实际上下文预算' FAIL critical "应用实际预算未通过鉴权回读（HTTP ${status:-000}）" local-api '检查 AnythingLLM 鉴权与当前配置事务，不把环境值存在当成已生效' "$start"
  fi
  # The system endpoint can include settings unrelated to diagnostics. Keep
  # only the white-listed result, not the raw authenticated response.
  : > "$response"
}

doctor_pool_prompt_capacity_check() {
  local start output values input count fitting maximum required
  start=$(doctor_now_ms)
  if (( DOCTOR_POOL_READY == 0 || DOCTOR_DOCKER_READY == 0 )); then
    doctor_skip provider.prompt_capacity '完整提示词基础容量' '因有效接口池或 Docker 不可验证，本次未检查' docker
    return
  fi
  output="${DOCTOR_TEMP_ROOT}/prompt-capacity.json"
  # Reuse the running Router estimator. This lower bound excludes history,
  # retrieved knowledge and the current question; it is not an inference test.
  if doctor_compose_timeout 5 exec -T provider-adapter node -e '
    const marker="CRISPAI_PROMPT_CAPACITY",fs=require("fs"),crypto=require("crypto");
    const root=process.argv[1],read=name=>JSON.parse(fs.readFileSync(root+name,"utf8"));
    const {estimateTextTokens}=require(root+"/scripts/provider-router.js");
    const applied=read("/config/materials-applied.json"),pool=read("/config/provider-pool-applied.json");
    const prompt=applied.prompt?.text;
    if(!marker||applied.state!=="applied"||applied.schema_version!==2||typeof prompt!=="string"||!prompt.trim()
      ||Buffer.byteLength(prompt)!==applied.prompt.bytes
      ||crypto.createHash("sha256").update(prompt).digest("hex")!==applied.prompt.sha256)process.exit(1);
    const entries=pool.entries.filter(entry=>entry.enabled===true&&entry.draft!==true&&entry.capabilities?.[entry.api_mode]===true);
    if(!entries.length||entries.some(entry=>!Number.isSafeInteger(entry.context_window)||entry.context_window<256
      ||!Number.isSafeInteger(entry.max_output_tokens)||entry.max_output_tokens<1||entry.max_output_tokens>=entry.context_window))process.exit(1);
    const input=256+16+estimateTextTokens(prompt);
    process.stdout.write(JSON.stringify({input,count:entries.length,
      fitting:entries.filter(entry=>input+entry.max_output_tokens<=entry.context_window).length,
      maximum:Math.max(...entries.map(entry=>entry.context_window)),
      required:Math.min(...entries.map(entry=>input+entry.max_output_tokens))}));
  ' /opt/crisp-ai > "$output" 2>/dev/null \
    && values=$(jq -er '[.input,.count,.fitting,.maximum,.required] |
      if all(.[]; type == "number" and floor == . and . >= 0) then @tsv else error("invalid capacity result") end' "$output" 2>/dev/null); then
    read -r input count fitting maximum required <<< "$values"
    if (( fitting == 0 )); then
      doctor_add provider.prompt_capacity '完整提示词基础容量' FAIL critical \
        "完整提示词基础输入估算 ${input}；含输出额度至少需要 ${required}，已启用接口最大窗口 ${maximum}，${fitting}/${count} 个候选可容纳；尚未计入问题、历史和知识，未调用模型" \
        docker '核对中转商实际支持的上下文上限，再从菜单 3 调整并应用；不要截断提示词或绕过容量保护' "$start"
    elif (( fitting < count )); then
      doctor_add provider.prompt_capacity '完整提示词基础容量' WARN warning \
        "基础输入估算 ${input}；仅 ${fitting}/${count} 个启用候选可容纳完整提示词及各自输出额度，部分候选会被跳过；尚未计入问题、历史和知识，未调用模型" \
        docker '核对各接口实际容量；短探针通过不能证明完整客服请求可用' "$start"
    else
      doctor_add provider.prompt_capacity '完整提示词基础容量' PASS critical \
        "基础输入估算 ${input}；${fitting}/${count} 个启用候选可容纳完整提示词及各自输出额度；尚未计入问题、历史和知识，具体请求仍由 Router 复核，未调用模型" docker '' "$start"
    fi
  elif ! doctor_remaining >/dev/null 2>&1; then
    doctor_deadline_add provider.prompt_capacity '完整提示词基础容量' docker "$start"
  else
    doctor_add provider.prompt_capacity '完整提示词基础容量' FAIL critical '未能读取并核验运行容器的完整提示词及候选容量，不能认定客服推理可用' docker \
      '检查资料应用状态、Prompt 摘要及接口池运行代；不要用短连接测试替代' "$start"
  fi
}

doctor_pool_adapter_check() {
  local start output count healthy cooling unknown hook_secret plugin_secret vision_count vision_cooling vision_unknown
  start=$(doctor_now_ms)
  doctor_pool_rag_context_check
  doctor_pool_prompt_capacity_check
  if (( DOCTOR_POOL_READY == 0 || DOCTOR_DOCKER_READY == 0 )); then
    for output in provider.adapter provider.adapter_binding anything.provider_binding n8n.runtime_binding provider.pool_health provider.pool_vision; do
      doctor_skip "$output" '主备接口运行检查' '因接口池或 Docker 上游故障未检查' docker
    done
    return
  fi
  if doctor_container_env_binding provider-adapter \
    'PROVIDER_ADAPTER_KEY,PROVIDER_POOL_REQUIRED,PROVIDER_REQUIRE_ENVELOPE,PROVIDER_HOST_GATEWAY' \
    "${DOCTOR_TEMP_ROOT}/adapter-binding.txt" \
    "$(env_get "${DOCTOR_DEPLOY_DIR}/.env" PROVIDER_ADAPTER_KEY)" true true host.docker.internal; then
    doctor_add provider.adapter_binding '主备 adapter 运行接线' PASS critical '内部认证、强制池模式、问题预算认证及宿主网关接线一致' docker '' "$start"
  elif ! doctor_remaining >/dev/null 2>&1; then
    doctor_deadline_add provider.adapter_binding '主备 adapter 运行接线' docker "$start"
  else
    doctor_add provider.adapter_binding '主备 adapter 运行接线' FAIL critical 'adapter 环境仍为旧代或内部认证偏离' docker '从受管更新流程重新创建本实例 adapter，保留路由及人工状态' "$start"
  fi
  start=$(doctor_now_ms)
  if doctor_container_env_binding anythingllm 'GENERIC_OPEN_AI_BASE_PATH,GENERIC_OPEN_AI_API_KEY' \
    "${DOCTOR_TEMP_ROOT}/anything-binding.txt" http://provider-adapter:8787/v1 \
    "$(env_get "${DOCTOR_DEPLOY_DIR}/.env" PROVIDER_ADAPTER_KEY)"; then
    doctor_add anything.provider_binding 'AnythingLLM 推理接线' PASS critical 'AnythingLLM 只使用内部 adapter 认证；每次实际模型由接口池独立选择' docker '' "$start"
  elif ! doctor_remaining >/dev/null 2>&1; then
    doctor_deadline_add anything.provider_binding 'AnythingLLM 推理接线' docker "$start"
  else
    doctor_add anything.provider_binding 'AnythingLLM 推理接线' FAIL critical 'AnythingLLM 尚未接入当前内部 adapter' docker '使用受管更新修复组件接线，不重建知识索引' "$start"
  fi
  start=$(doctor_now_ms)
  hook_secret=$(env_get "${DOCTOR_DEPLOY_DIR}/.env" CRISP_WEBSITE_HOOK_SECRET 2>/dev/null || true)
  plugin_secret=$(env_get "${DOCTOR_DEPLOY_DIR}/.env" CRISP_PLUGIN_SIGNING_SECRET 2>/dev/null || true)
  if doctor_container_env_binding n8n \
    'CRISP_WEBSITE_ID,CRISP_API_BASE_URL,CRISP_TOKEN_TIER,CRISP_AUTH_B64,CRISP_HOOK_MODE,CRISP_WEBSITE_HOOK_SECRET,CRISP_PLUGIN_SIGNING_SECRET,WEBHOOK_URL,ANYTHINGLLM_API_KEY,ANYTHINGLLM_WORKSPACE,PROVIDER_ADAPTER_URL,PROVIDER_ADAPTER_KEY,PROVIDER_POOL_REQUIRED,PROVIDER_POOL_READBACK_REQUIRED' \
    "${DOCTOR_TEMP_ROOT}/n8n-runtime-binding.txt" \
    "$(env_get "${DOCTOR_DEPLOY_DIR}/.env" CRISP_WEBSITE_ID)" \
    "$(env_get "${DOCTOR_DEPLOY_DIR}/.env" CRISP_API_BASE_URL 2>/dev/null || printf 'https://api.crisp.chat/v1')" \
    "$(env_get "${DOCTOR_DEPLOY_DIR}/.env" CRISP_TOKEN_TIER)" "$(env_get "${DOCTOR_DEPLOY_DIR}/.env" CRISP_AUTH_B64)" \
    "$(env_get "${DOCTOR_DEPLOY_DIR}/.env" CRISP_HOOK_MODE)" "${hook_secret:-not-configured}" "${plugin_secret:-not-configured}" \
    "$(env_get "${DOCTOR_DEPLOY_DIR}/.env" PUBLIC_WEBHOOK_URL)" "$(env_get "${DOCTOR_DEPLOY_DIR}/.env" ANYTHINGLLM_API_KEY)" \
    "$(env_get "${DOCTOR_DEPLOY_DIR}/.env" ANYTHINGLLM_WORKSPACE)" http://provider-adapter:8787/v1 \
    "$(env_get "${DOCTOR_DEPLOY_DIR}/.env" PROVIDER_ADAPTER_KEY)" true true; then
    doctor_add n8n.runtime_binding 'n8n AI/Crisp 运行接线' PASS critical '当前 Crisp/AnythingLLM 认证和共享主备推理入口一致' docker '' "$start"
  elif ! doctor_remaining >/dev/null 2>&1; then
    doctor_deadline_add n8n.runtime_binding 'n8n AI/Crisp 运行接线' docker "$start"
  else
    doctor_add n8n.runtime_binding 'n8n AI/Crisp 运行接线' FAIL critical 'n8n 仍持有旧版或偏离的 Crisp/AI 接线' docker '从受管更新流程修复 n8n，不清空人工会话' "$start"
  fi
  start=$(doctor_now_ms)
  output="${DOCTOR_TEMP_ROOT}/adapter-pool-status.json"
  if doctor_compose_timeout 8 exec -T anythingllm node -e '
    fetch("http://provider-adapter:8787/internal/provider/status",{headers:{authorization:"Bearer "+process.env.GENERIC_OPEN_AI_API_KEY},signal:AbortSignal.timeout(5000)})
      .then(async r=>{const b=await r.json();if(!r.ok||b.ok!==true)throw Error();process.stdout.write(JSON.stringify(b));})
      .catch(()=>{process.exitCode=1;});
  ' < /dev/null > "$output" 2>/dev/null \
    && jq -e --slurpfile expected "${DOCTOR_DEPLOY_DIR}/config/provider-pool-applied.json" \
      --arg pool_sha "$(sha256sum "${DOCTOR_DEPLOY_DIR}/config/provider-pool-applied.json" | awk '{print $1}')" \
      '.ok == true and .readback_contract_version == 1 and .configuration_state == "applied"
       and .revision == $expected[0].revision
       and .secrets_generation == $expected[0].secrets_generation and .pool_sha256 == $pool_sha
       and (.entries | type == "array" and length > 0) and
       ([.entries[]|{id,enabled}]) == ([$expected[0].entries[]|{id,enabled}]) and
       all(.entries[]; (.health == "healthy" or .health == "cooling" or .health == "unknown" or .health == "half_open" or (.enabled == false and .health == "disabled")))' "$output" >/dev/null 2>&1; then
    doctor_add provider.adapter '主备 adapter 实际读取' PASS critical 'AnythingLLM 网络通过内部认证读取当前接口池，配置应用代次一致；未调用模型' docker '' "$start"
    count=$(jq '[.entries[]|select(.enabled)]|length' "$output")
    healthy=$(jq '[.entries[]|select(.enabled and .health=="healthy")]|length' "$output")
    cooling=$(jq '[.entries[]|select(.enabled and .health=="cooling")]|length' "$output")
    unknown=$(jq '[.entries[]|select(.enabled and (.health=="unknown" or .health=="half_open"))]|length' "$output")
    if (( count > 0 && cooling == count )); then
      doctor_add provider.pool_health 'AI 接口可用性' FAIL critical '所有已启用接口目前均在故障冷却中，推理暂不可用' docker '从菜单 3 查看脱敏原因，修正或增加有权限的接口' "$start"
    elif (( cooling > 0 )); then
      doctor_add provider.pool_health 'AI 接口可用性' WARN warning "降级运行：${cooling} 个接口冷却；${healthy} 个有当前健康证据，${unknown} 个待确认" docker '从菜单 3 查看最近切换原因；不要把冷却当成管理员停用' "$start"
    elif (( unknown > 0 )); then
      doctor_add provider.pool_health 'AI 接口可用性' WARN warning "${unknown} 个启用接口尚未检测或恢复待确认；默认自检不会付费轮询" docker '按需显式测试指定接口，或等待正常问题产生当前成功证据' "$start"
    else
      doctor_add provider.pool_health 'AI 接口可用性' PASS warning '已启用接口均有当前配置的文本健康证据；图片能力另列' docker '' "$start"
    fi
    vision_count=$(jq '[.entries[]|select(.enabled and .vision_health != null and .vision_health != "disabled")]|length' "$output")
    vision_cooling=$(jq '[.entries[]|select(.enabled and .vision_health == "cooling")]|length' "$output")
    vision_unknown=$(jq '[.entries[]|select(.enabled and (.vision_health == "unknown" or .vision_health == "half_open"))]|length' "$output")
    if (( vision_cooling > 0 )); then
      doctor_add provider.pool_vision '接口图片能力' WARN warning "${vision_cooling} 个接口图片能力暂时冷却；文字健康与图片能力分别判断，不能丢图冒充成功" docker '从菜单 3 查看视觉候选；只在需要时显式测试图片，默认不调用模型' "$start"
    elif (( vision_unknown > 0 )); then
      doctor_add provider.pool_vision '接口图片能力' WARN warning "${vision_unknown} 个接口尚无当前图片成功证据或恢复待确认；文本成功不等于支持图片" docker '正常图片问题或显式图片测试可产生当前证据，不默认轮询' "$start"
    elif (( vision_count > 0 )); then
      doctor_add provider.pool_vision '接口图片能力' PASS warning '已启用图片候选有当前配置的成功证据' docker '' "$start"
    else
      doctor_skip provider.pool_vision '接口图片能力' '当前没有已启用的图片能力候选或此次未取得图片状态，不能据文本结果推断视觉可用' docker
    fi
  elif ! doctor_remaining >/dev/null 2>&1; then
    doctor_deadline_add provider.adapter '主备 adapter 实际读取' docker "$start"
    doctor_skip provider.pool_health 'AI 接口可用性' '因自检总截止时间已到未检查' docker
    doctor_skip provider.pool_vision '接口图片能力' '因自检总截止时间已到未检查' docker
  else
    doctor_add provider.adapter '主备 adapter 实际读取' FAIL critical '容器网络、认证或 adapter 已应用代次未通过核对' docker '使用菜单 2 检查组件和受限秘密挂载，再从菜单 3 重新应用' "$start"
    doctor_skip provider.pool_health 'AI 接口可用性' '因本地 adapter 不可验证，未推断上游是否健康' docker
    doctor_skip provider.pool_vision '接口图片能力' '因本地 adapter 不可验证，未推断图片能力' docker
  fi
}

doctor_adapter_check() {
  if (( DOCTOR_POOL_ENABLED )); then doctor_pool_adapter_check; return; fi
  local start output mode configured_mode runtime_base configured_base configured_model runtime_model
  local header_json header_names vision configured_vision mode_capability hook_secret plugin_secret remaining provider_config
  start=$(doctor_now_ms)
  provider_config=$(doctor_config_file provider)
  if [[ ! -f "$provider_config" || -L "$provider_config" ]] \
    || ! jq -e '.schema_version == 2 and (.provider.base_url | type == "string" and length > 0) and
      (.provider.model | type == "string" and length > 0) and (.provider.api_mode == "chat_completions" or .provider.api_mode == "responses")' \
      "$provider_config" >/dev/null 2>&1; then
    doctor_add provider.configuration 'Provider 配置接线' FAIL critical '接口配置格式、模型或协议无效' filesystem '从第三方 AI 菜单修复整组配置' "$start"
    doctor_skip provider.adapter 'Provider adapter' '因 Provider 配置无效未检查运行路径' docker
    doctor_skip provider.adapter_binding 'Provider adapter 运行代' '因 Provider 配置无效未核对运行容器环境' docker
    doctor_skip anything.provider_binding 'AnythingLLM Provider 运行代' '因 Provider 配置无效未核对运行容器环境' docker
    doctor_skip n8n.runtime_binding 'n8n AI/Crisp 运行代' '因 Provider 配置无效未核对运行容器环境' docker
    return
  fi
  configured_mode=$(jq -r '.provider.api_mode' "$provider_config")
  configured_base=$(jq -r '.provider.base_url' "$provider_config")
  configured_model=$(jq -r '.provider.model' "$provider_config")
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
  configured_vision=$(jq -r '.provider.capabilities.vision' "$provider_config")
  mode_capability=$(jq -r --arg mode "$configured_mode" '.provider.capabilities[$mode] // false' "$provider_config")
  if [[ "$mode" != "$configured_mode" || "$runtime_base" != http://provider-adapter:8787/v1 \
    || "$(env_get "${DOCTOR_DEPLOY_DIR}/.env" AI_API_BASE_URL 2>/dev/null || true)" != "$configured_base" \
    || "$runtime_model" != "$configured_model" || "$header_names" == invalid \
    || "$vision" != "$configured_vision" || "$mode_capability" != true ]] \
    || ! jq -e --argjson names "$header_names" '((.provider.custom_header_names // []) | sort) == $names' \
      "$provider_config" >/dev/null 2>&1; then
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
  local start now sessions invalid legacy human timed permanent active_workers stale_workers pending_jobs file deadline_reached=0
  local analysis_file analysis_tag analysis_count_rows analysis_invalid_rows
  local state_key state_website state_session expected_state_key
  local feedback_pending=0 feedback_count=0
  local responsibility_pending=0 stalled_no_artifact=0 invalid_responsibility_artifacts=0 unresolved_jobs=0 intentional_silence=0 unknown_deliveries=0
  local provider_settlements=0 invalid_settlements=0 settlement_count invalid_settlement_count
  local provider_retirements=0 invalid_retirements=0 retirement_count invalid_retirement_count
  local provider_receipts=0 invalid_provider_receipts=0 legacy_provider_inferences=0
  local receipt_count invalid_receipt_count legacy_inference_count context_hash_invalid stored_hash encoded_context actual_hash
  local legacy_binding_invalid encoded_legacy_configuration
  local inference_binding_invalid outgoing_identity_invalid outgoing_shape_invalid picker_identity_invalid encoded_wire map_fingerprint body_fingerprint plan_fingerprint job_id purpose response_generation fingerprint_material fingerprint_hex expected_fingerprint picker_id picker_fingerprint picker_hex expected_picker_fingerprint
  local settlement_identity_invalid encoded_plan settlement_generation job_generation encoded_configuration
  local retirement_identity_invalid stored_identity encoded_retirement
  local oldest_unresolved=0 oldest_unknown=0 pending_count stalled_count invalid_artifact_count unresolved_count silence_count unknown_count file_oldest_unresolved file_oldest_unknown
  local stalled_after_ms=600000
  start=$(doctor_now_ms)
  now=$(doctor_now_ms)
  sessions=0; invalid=0; legacy=0; human=0; timed=0; permanent=0; active_workers=0; stale_workers=0; pending_jobs=0
  shopt -s nullglob
  for file in "${DOCTOR_DEPLOY_DIR}"/data/runtime/session-*.json; do
    if ! doctor_remaining >/dev/null; then deadline_reached=1; break; fi
    [[ -f "$file" && ! -L "$file" ]] || { ((invalid += 1)); continue; }
    if ! jq -e '.schema_version == 2 and (.mode == "ai" or .mode == "human") and
      (.website_id | type == "string" and length > 0) and
      (.session_id | type == "string" and length > 0) and
      (.generation | type == "number") and (.jobs | type == "array") and
      all(.jobs[]; if type != "object" then false
        else (.plan == null or (.plan | type) == "object") end) and
      (.offers | type == "object") and all(.offers[]; type == "object") and
      (.worker == null or (.worker | type) == "object")' "$file" >/dev/null 2>&1; then
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
    state_key=${file##*/session-}; state_key=${state_key%.json}
    IFS=$'\t' read -r state_website state_session < <(jq -r '[.website_id,.session_id] | @tsv' "$file")
    expected_state_key=$(printf '%s\0%s' "$state_website" "$state_session" | sha256sum | awk '{print $1}')
    if [[ "$state_key" != "$expected_state_key" ]]; then
      ((invalid += 1))
      continue
    fi
    # 每个文件都使用与本次快照读取相邻的时刻；长时间扫描不能拿函数入口的旧时刻
    # 把并发新写入的合法记录误判为未来数据。
    now=$(doctor_now_ms)
    ((sessions += 1))
    analysis_file="${DOCTOR_TEMP_ROOT}/runtime-state-${state_key}.tsv"
    if ! jq -r --argjson now "$now" --argjson stalled_after_ms "$stalled_after_ms" \
      --arg state_key "$state_key" '
      def nonnegative_safe_integer:
        type == "number" and . >= 0 and . <= 9007199254740991 and floor == .;
      def canonical_value:
        if type == "object" then to_entries | sort_by(.key) |
          map({key:.key,value:(.value | canonical_value)}) | from_entries
        elif type == "array" then map(canonical_value)
        else . end;
      def response_generation:
        if (.response_generation | type) == "number" and .response_generation >= 0 and
          .response_generation <= 1000000 and (.response_generation | floor) == .response_generation
        then .response_generation else 0 end;
      def lowercase_hex($size):
        if type != "string" then false
        else length == $size and test("^[a-f0-9]+$") end;
      def active_owner($state; $job):
        $job.status == "processing" and
        (($job.execution_token | type) == "string") and
        ($job.execution_token | test("^[a-f0-9]{24}$")) and
        ($job.lease_until | nonnegative_safe_integer) and $job.lease_until > $now and
        (($state.worker | type) == "object") and
        $state.worker.job == $job.id and
        $state.worker.token == $job.execution_token and
        ($state.worker.until | nonnegative_safe_integer) and $state.worker.until > $now;
      def provider_settlement_finished:
        type == "object" and
        (keys | sort) == ["attempts","plan_sha256","response_generation","schema_version","settled_at","state"] and
        .schema_version == 1 and
        (.state == "settled" or .state == "absent") and
        (.plan_sha256 | lowercase_hex(64)) and
        (.response_generation | nonnegative_safe_integer) and
        (.attempts | nonnegative_safe_integer) and .attempts >= 1 and
        (.settled_at | nonnegative_safe_integer);
      def provider_retirement_finished:
        type == "object" and
        (keys | sort) == ["attempts","identity_sha256","purpose","retired_at","schema_version","state"] and
        .schema_version == 1 and (.state == "retired" or .state == "absent") and
        (.purpose == "conversation_cancelled" or .purpose == "global_disabled" or
          .purpose == "input_retired" or .purpose == "non_answer_retired" or
          .purpose == "legacy_unsettled_retired") and
        (.identity_sha256 | lowercase_hex(64)) and
        (.attempts | nonnegative_safe_integer) and .attempts >= 1 and
        (.retired_at | nonnegative_safe_integer);
      def provider_retirement_purpose_authorized($purpose):
        . as $job |
        if $purpose == "conversation_cancelled" then
          $job.status == "cancelled" and $job.responsibility_status == "intentional_silence" and
          ($job.responsibility_reason == "human_reply" or
            $job.responsibility_reason == "human_handoff" or
            $job.responsibility_reason == "conversation_state_changed")
        elif $purpose == "global_disabled" then
          $job.status == "cancelled" and $job.responsibility_status == "intentional_silence" and
          $job.responsibility_reason == "global_disabled"
        elif $purpose == "input_retired" then
          ($job.status == "done" or $job.status == "cancelled" or $job.status == "failed") and
          ($job.responsibility_status == "intentional_silence" or
            $job.responsibility_status == "control_handled") and
          ($job.responsibility_reason == "non_visitor_message" or
            $job.responsibility_reason == "before_catchup_bootstrap" or
            $job.responsibility_reason == "before_control_watermark")
        elif $purpose == "legacy_unsettled_retired" then
          ($job.status == "received" or $job.status == "failed") and
          $job.responsibility_status == "unresolved_failure" and
          $job.failure_code == "legacy_unsettled_plan_migrated" and
          ($job.legacy_unsettled_plan_migrated_at | nonnegative_safe_integer)
        else $purpose == "non_answer_retired" and
          ($job.status == "received" or $job.status == "failed") and
          $job.responsibility_status == "unresolved_failure" end;
      def provider_retirement_finished_for:
        . as $job |
        ($job.provider_retirement | provider_retirement_finished) and
        ($job | provider_retirement_purpose_authorized($job.provider_retirement.purpose)) and
        ($job | has("provider_retirement_failure_code") | not) and
        ($job | has("inference") | not) and
        ($job | has("provider_result_receipt") | not) and
        ($job | has("provider_migration_from") | not) and
        ($job | has("legacy_v121_pending_origin") | not) and
        ($job | has("provider_settlement") | not);
      def positive_safe_integer:
        type == "number" and . >= 1 and . <= 9007199254740991 and floor == .;
      def provider_configuration_valid:
        if type != "object" then false
        else (.runtime_revision | nonnegative_safe_integer) and
          (.pool_revision | positive_safe_integer) and
          (.secrets_generation | lowercase_hex(32)) and
          (.pool_sha256 | lowercase_hex(64)) and
          (.materials_source_sha256 | lowercase_hex(64)) end;
      def legacy_v121_inference:
        if type != "object" then false
        else (keys | sort) == ["deadline_at","pool_revision"] and
          (.pool_revision | positive_safe_integer) and
          (.deadline_at | nonnegative_safe_integer) end;
      def legacy_v121_origin:
        if type != "object" then false
        else (keys | sort) == ["deadline_at","pool_revision","runtime_revision"] and
          (.runtime_revision | nonnegative_safe_integer) and
          (.pool_revision | positive_safe_integer) and
          (.deadline_at | nonnegative_safe_integer) end;
      def legacy_v121_source_frozen_valid:
        . as $job |
        ($job.legacy_v121_pending_origin | type) == "object" and
        ($job.legacy_v121_pending_origin | keys | sort) == ["phase","schema_version","source"] and
        $job.legacy_v121_pending_origin.schema_version == 1 and
        $job.legacy_v121_pending_origin.phase == "source_frozen" and
        ($job.legacy_v121_pending_origin.source | legacy_v121_origin) and
        ($job.provider_result_receipt == null) and ($job.provider_settlement == null) and
        ($job.plan == null) and
        ($job.inference | legacy_v121_inference) and
        $job.legacy_v121_pending_origin.source.runtime_revision == $job.revision and
        $job.legacy_v121_pending_origin.source.pool_revision == $job.inference.pool_revision and
        $job.legacy_v121_pending_origin.source.deadline_at == $job.inference.deadline_at;
      def legacy_v121_successor_bound_valid:
        . as $job |
        ($job.legacy_v121_pending_origin | type) == "object" and
        ($job.legacy_v121_pending_origin | keys | sort) ==
          ["phase","schema_version","source","target","target_configuration_binding"] and
        $job.legacy_v121_pending_origin.schema_version == 1 and
        $job.legacy_v121_pending_origin.phase == "successor_bound" and
        ($job.legacy_v121_pending_origin.source | legacy_v121_origin) and
        ($job.legacy_v121_pending_origin.target | provider_configuration_valid) and
        ($job.legacy_v121_pending_origin.target | keys | sort) ==
          ["materials_source_sha256","pool_revision","pool_sha256","runtime_revision","secrets_generation"] and
        ($job.legacy_v121_pending_origin.target_configuration_binding |
          lowercase_hex(64)) and
        $job.legacy_v121_pending_origin.target.runtime_revision == $job.revision and
        ($job | has("inference") | not) and
        ($job.provider_result_receipt == null) and ($job.provider_settlement == null) and
        ($job.plan == null);
      def legacy_v121_pending_valid:
        (. | legacy_v121_source_frozen_valid) or
        (. | legacy_v121_successor_bound_valid);
      def picker_choices_valid:
        if type != "array" then false
        else all(.[];
          if type != "object" then false
          else (keys | sort) == ["label","selected","value"] and
            ((.value | type) == "string") and (.value | length) > 0 and
            ((.label | type) == "string") and (.label | length) > 0 and
            .selected == false end)
        end;
      def visitor_plan_artifact_valid:
        if type != "object" then false
        elif ((.purpose | type) != "string") or
          ((.purpose | test("^[a-z][a-z0-9_]{0,79}$")) | not) then false
        elif has("fingerprint") and
          (((.fingerprint | nonnegative_safe_integer)) | not)
          then false
        elif .type == "text" then
          ((.content | type) == "string") and (.content | length) > 0
        elif .type == "internal" then
          .purpose == "technical_unresolved" and .ordinary == true and
          .content == "" and .answer_responsibility == "unresolved_failure" and
          (.safe_error_context == "text" or .safe_error_context == "image") and
          ((.diagnostic_code | type) == "string") and (.diagnostic_code | length) > 0 and
          ((.tags | type) == "array")
        elif .type == "picker" then
          has("fingerprint") and
          (.purpose == "menu" or .purpose == "handoff_offer") and
          ((.content | type) == "object") and
          ((.content.id | type) == "string") and (.content.id | length) > 0 and
          (.content.id | test("^crispai_[a-f0-9]{32}$")) and
          ((.content.text | type) == "string") and (.content.text | length) > 0 and
          (.content.choices | picker_choices_valid)
        else false end;
      def provider_migration_artifact_valid:
        if type != "object" then false
        else (keys | sort) == ["attempt_generation","materials_source_sha256","pool_revision",
          "pool_sha256","runtime_revision","secrets_generation"] and
          (. | provider_configuration_valid) and
          (.attempt_generation | positive_safe_integer) end;
      def legacy_unpooled_inference:
        if type != "object" then false
        else (keys | sort) == ["deadline_at","pool_revision"] and
          .pool_revision == null and (.deadline_at | nonnegative_safe_integer) end;
      def provider_inference_artifact_valid($job):
        . as $inference |
        if ($inference | legacy_v121_inference) or
          ($inference | legacy_unpooled_inference) then true
        elif ($inference | type) != "object" then false
        elif $inference.pool_revision == null then
          ($inference | keys | sort) == ["attempt_generation","deadline_at",
            "pool_revision","provider_receipt_protocol_version","runtime_revision"] and
          $inference.runtime_revision == $job.revision and
          ($inference.deadline_at | nonnegative_safe_integer) and
          ($inference.attempt_generation | positive_safe_integer) and
          $inference.provider_receipt_protocol_version == 1
        else
          (($inference | keys) - ["legacy_v121_origin"] | sort) ==
            ["attempt_generation","configuration_binding","deadline_at",
              "materials_source_sha256","pool_revision","pool_sha256",
              "provider_receipt_protocol_version","runtime_revision","secrets_generation"] and
          ({runtime_revision:$inference.runtime_revision,pool_revision:$inference.pool_revision,
            secrets_generation:$inference.secrets_generation,pool_sha256:$inference.pool_sha256,
            materials_source_sha256:$inference.materials_source_sha256} |
            provider_configuration_valid) and
          ($inference.configuration_binding | lowercase_hex(64)) and
          $inference.runtime_revision == $job.revision and
          ($inference.deadline_at | nonnegative_safe_integer) and
          ($inference.attempt_generation | positive_safe_integer) and
          $inference.provider_receipt_protocol_version == 1 and
          (if $inference.legacy_v121_origin == null then true
           else ($inference.legacy_v121_origin | legacy_v121_origin) and
             $inference.attempt_generation == 2 end)
        end;
      def outgoing_body_artifact_valid:
        if type != "object" then false
        else .from == "operator" and .origin == "chat" and
          (.fingerprint | nonnegative_safe_integer) and
          (if .type == "text" then (.content | type) == "string"
           elif .type == "picker" then
             ((.content | type) == "object") and .content.required == false and
             ((.content.id | type) == "string") and (.content.id | length) > 0 and
             ((.content.text | type) == "string") and (.content.text | length) > 0 and
             (.content.choices | picker_choices_valid)
           else false end)
        end;
      def outgoing_body_matches_plan($body; $plan):
        ($plan | visitor_plan_artifact_valid) and
        ($plan.type == "text" or $plan.type == "picker") and
        ($body | outgoing_body_artifact_valid) and $body.type == $plan.type and
        (if $plan.type == "text" then $body.content == $plan.content
         else $body.content.id == $plan.content.id and
           $body.content.text == $plan.content.text and
           $body.content.choices == $plan.content.choices and
           $body.content.required == false end) and
        (if $plan.fingerprint == null then true
         else ($body.fingerprint | tostring) == ($plan.fingerprint | tostring) end);
      def outgoing_artifact_valid($record; $job):
        if ($record | type) != "object" then false
        else ($job.id | lowercase_hex(64)) and $record.job_id == $job.id and
          (["queued","sending","unknown","sent","rate_limited","rejected",
            "cancelled","failed"] | index($record.status)) != null and
          (if $record.status == "queued" then false
          else
            ($record.created_at | nonnegative_safe_integer) and
            $record.created_at <= ($now + 60000) and
            ($record.attempts | positive_safe_integer) and
            ($record.generation | nonnegative_safe_integer) and
            $record.generation == $job.generation and
            ($record.response_generation | nonnegative_safe_integer) and
            $record.response_generation == ($job.response_generation // 0) and
            (($record.purpose | type) == "string") and
            ($record.purpose | test("^[a-z][a-z0-9_]{0,79}$")) and
            ($record.message_type == "text" or $record.message_type == "picker") and
            ($record.semantic_intent == "answer" or $record.semantic_intent == "non_answer" or
              $record.semantic_intent == "control") and
            ($record.content_sha256 | lowercase_hex(64)) and
            ($record.attempt_token | lowercase_hex(32)) and
            ($record.delivery_identity_version == 1 or
              $record.receipt_identity_unbound == true) and
            (if (["sending","unknown","rate_limited","rejected"] |
              index($record.status)) != null then
               ($record.body | outgoing_body_artifact_valid) and
               $record.body.type == $record.message_type
             elif $record.status == "sent" then
               (if $record.body == null then ($job.plan | visitor_plan_artifact_valid)
                else (($record.body | outgoing_body_artifact_valid) and
                  $record.body.type == $record.message_type) end)
             else ($job.plan | visitor_plan_artifact_valid) end)
            and (if ($job.plan | visitor_plan_artifact_valid) then
              $record.purpose == $job.plan.purpose and
              $record.message_type == $job.plan.type and
              (if $record.body == null then true
               else outgoing_body_matches_plan($record.body; $job.plan) end)
            else true end)
          end)
        end;
      def aged_pending_responsibility($state; $job):
        $job.control == false and
        ($job.responsibility_status // "pending") == "pending" and
        ($job.status == "received" or
          ($job.status == "processing" and ((active_owner($state; $job)) | not))) and
        ($job.attempts | positive_safe_integer) and
        ($job.received_at | nonnegative_safe_integer) and
        ($now - $job.received_at > $stalled_after_ms);
      def provider_receipt_valid:
        . as $job |
        ($job.inference) as $inference |
        ($job.provider_result_receipt) as $receipt |
        if ($inference | type) != "object" or ($receipt | type) != "object" then false
        else
          $inference.provider_receipt_protocol_version == 1 and
          ($inference.attempt_generation | positive_safe_integer) and
          (if $inference.legacy_v121_origin == null then true
           else ($inference.legacy_v121_origin | legacy_v121_origin) and
             $inference.attempt_generation == 2 end) and
          ($inference.configuration_binding | lowercase_hex(64)) and
          ($receipt.state == "requesting" or $receipt.state == "unknown" or
            $receipt.state == "available" or $receipt.state == "absent") and
          ($receipt.stage == "vision" or $receipt.stage == "answer") and
          ($receipt.attempt_generation | positive_safe_integer) and
          $receipt.attempt_generation == $inference.attempt_generation and
          ($receipt.configuration_binding | lowercase_hex(64)) and
          $receipt.configuration_binding == $inference.configuration_binding and
          $receipt.request_contract_version == 1 and
          ($receipt.request_sha256 | lowercase_hex(64)) and
          ($receipt.plan_context_sha256 | lowercase_hex(64))
        end;
      def provider_settlement_outstanding_valid:
        . as $job |
        ($job.provider_settlement) as $settlement |
        ($settlement.envelope) as $envelope |
        ($job.inference) as $inference |
        ($job.provider_result_receipt) as $receipt |
        if ($settlement | type) != "object" or ($envelope | type) != "object"
          or ($inference | type) != "object" or ($receipt | type) != "object" then false
        else
          $settlement.schema_version == 1 and
          ($settlement.state == "pending" or $settlement.state == "deferred") and
          ($settlement.plan_sha256 | lowercase_hex(64)) and
          ($settlement.response_generation | nonnegative_safe_integer) and
          ($settlement.attempts | nonnegative_safe_integer) and
          (($envelope | keys) - ["version","scope","question_id","session_key","generation",
            "runtime_revision","pool_revision","secrets_generation","pool_sha256",
            "materials_source_sha256","configuration_binding","deadline_at","stage",
            "attempt_generation","request_contract_version","request_sha256",
            "plan_context_sha256","migration_from","transition_reason",
            "legacy_v121_origin"] | length) == 0 and
          $envelope.version == 1 and $envelope.scope == "conversation" and
          $envelope.question_id == $job.id and
          $envelope.session_key == $state_key and
          $envelope.generation == $job.generation and $envelope.stage == "answer" and
          ($envelope.deadline_at | nonnegative_safe_integer) and
          ($envelope.attempt_generation | positive_safe_integer) and
          ({runtime_revision:$envelope.runtime_revision,pool_revision:$envelope.pool_revision,
            secrets_generation:$envelope.secrets_generation,pool_sha256:$envelope.pool_sha256,
            materials_source_sha256:$envelope.materials_source_sha256} | provider_configuration_valid) and
          ($envelope.configuration_binding | lowercase_hex(64)) and
          $envelope.request_contract_version == 1 and
          ($envelope.request_sha256 | lowercase_hex(64)) and
          ($envelope.plan_context_sha256 | lowercase_hex(64)) and
          ($job | provider_receipt_valid) and $receipt.stage == "answer" and
          $envelope.runtime_revision == ($inference.runtime_revision // $job.revision) and
          $envelope.pool_revision == $inference.pool_revision and
          $envelope.secrets_generation == $inference.secrets_generation and
          $envelope.pool_sha256 == $inference.pool_sha256 and
          $envelope.materials_source_sha256 == $inference.materials_source_sha256 and
          $envelope.attempt_generation == $inference.attempt_generation and
          $envelope.configuration_binding == $inference.configuration_binding and
          $envelope.deadline_at == $inference.deadline_at and
          $envelope.request_contract_version == $receipt.request_contract_version and
          $envelope.request_sha256 == $receipt.request_sha256 and
          $envelope.plan_context_sha256 == $receipt.plan_context_sha256 and
          (($envelope.legacy_v121_origin // null) == ($inference.legacy_v121_origin // null)) and
          (if $envelope.migration_from == null then $envelope.transition_reason == null
           else $envelope.transition_reason == "configuration_changed" and
             ($envelope.migration_from | provider_configuration_valid) and
             ($envelope.migration_from.attempt_generation | positive_safe_integer) and
             ((($envelope.migration_from | keys) - ["runtime_revision","pool_revision",
               "secrets_generation","pool_sha256","materials_source_sha256",
               "attempt_generation"] | length) == 0) end) and
          (if $envelope.legacy_v121_origin == null then true
           else ($envelope.legacy_v121_origin | legacy_v121_origin) and
             $envelope.attempt_generation == 2 and $envelope.migration_from == null end)
        end;
      def provider_retirement_outstanding_valid:
        . as $job |
        ($job.provider_retirement) as $retirement |
        ($retirement.envelope) as $envelope |
        ($job.inference) as $inference |
        ($job.provider_result_receipt) as $receipt |
        if ($retirement | type) != "object" or ($envelope | type) != "object" then false
        else
          (($retirement | keys) - ["schema_version","state","purpose","envelope",
            "identity_sha256","attempts","first_recorded_at","next_action_at","reason",
            "last_attempt_at","lease_until","lease_token"] | length) == 0 and
          (["schema_version","state","purpose","envelope","identity_sha256","attempts",
            "first_recorded_at","next_action_at"] - ($retirement | keys) | length) == 0 and
          $retirement.schema_version == 1 and
          ($retirement.state == "pending" or $retirement.state == "deferred") and
          ($retirement.purpose == "conversation_cancelled" or
            $retirement.purpose == "global_disabled" or
            $retirement.purpose == "input_retired" or
            $retirement.purpose == "non_answer_retired" or
            $retirement.purpose == "legacy_unsettled_retired") and
          ($retirement.identity_sha256 | lowercase_hex(64)) and
          ($retirement.attempts | nonnegative_safe_integer) and
          ($retirement.first_recorded_at | nonnegative_safe_integer) and
          ($retirement.next_action_at | nonnegative_safe_integer) and
          (if ($retirement | has("reason")) then
             (($retirement.reason | type) == "string" and ($retirement.reason | length) <= 80)
           else true end) and
          (if ($retirement | has("last_attempt_at")) then
             ($retirement.last_attempt_at | nonnegative_safe_integer)
           else true end) and
          (($retirement | has("lease_until")) == ($retirement | has("lease_token"))) and
          (if ($retirement | has("lease_until")) then
             ($retirement.lease_until | nonnegative_safe_integer) and
             ($retirement.lease_token | type) == "string" and
             ($retirement.lease_token | test("^(|[a-f0-9]{24})$"))
           else true end) and
          ($job | has("provider_settlement") | not) and $job.control != true and
          $envelope.version == 1 and $envelope.scope == "conversation" and
          $envelope.question_id == $job.id and
          $envelope.session_key == $state_key and
          $envelope.generation == $job.generation and
          ($envelope.deadline_at | nonnegative_safe_integer) and
          ($envelope.attempt_generation | positive_safe_integer) and
          ($job | provider_retirement_purpose_authorized($retirement.purpose)) and
          (if $envelope.legacy_v121_cleanup == true then
             ($envelope | keys | sort) == ["attempt_generation","deadline_at","generation",
               "legacy_v121_cleanup","pool_revision","question_id","runtime_revision",
               "scope","session_key","stage","version"] and
             $envelope.stage == "answer" and $envelope.attempt_generation == 1 and
             ($envelope.runtime_revision | nonnegative_safe_integer) and
             ($envelope.pool_revision | positive_safe_integer) and
             ($job | has("plan") | not) and
             ($job | has("provider_result_receipt") | not) and
             ($job | has("provider_migration_from") | not) and
             (if ($job | has("legacy_v121_pending_origin")) then
                ($job | legacy_v121_pending_valid) and
                $envelope.runtime_revision == $job.legacy_v121_pending_origin.source.runtime_revision and
                $envelope.pool_revision == $job.legacy_v121_pending_origin.source.pool_revision and
                $envelope.deadline_at == $job.legacy_v121_pending_origin.source.deadline_at
              else ($job.inference | legacy_v121_inference) and
                $envelope.runtime_revision == $job.revision and
                $envelope.pool_revision == $job.inference.pool_revision and
                $envelope.deadline_at == $job.inference.deadline_at end)
           else
             ($envelope | has("legacy_v121_cleanup") | not) and
             ($inference | type) == "object" and ($receipt | type) == "object" and
             (($envelope | keys) - ["version","scope","question_id","session_key","generation",
               "runtime_revision","pool_revision","secrets_generation","pool_sha256",
               "materials_source_sha256","configuration_binding","deadline_at","stage",
               "attempt_generation","request_contract_version","request_sha256",
               "plan_context_sha256","migration_from","transition_reason",
               "legacy_v121_origin"] | length) == 0 and
             ($envelope.stage == "vision" or $envelope.stage == "answer") and
             ({runtime_revision:$envelope.runtime_revision,pool_revision:$envelope.pool_revision,
               secrets_generation:$envelope.secrets_generation,pool_sha256:$envelope.pool_sha256,
               materials_source_sha256:$envelope.materials_source_sha256} | provider_configuration_valid) and
             ($envelope.configuration_binding | lowercase_hex(64)) and
             $envelope.request_contract_version == 1 and
             ($envelope.request_sha256 | lowercase_hex(64)) and
             ($envelope.plan_context_sha256 | lowercase_hex(64)) and
             ($job | provider_receipt_valid) and
             ($receipt.state == "requesting" or $receipt.state == "unknown" or
               $receipt.state == "available") and $envelope.stage == $receipt.stage and
             $envelope.runtime_revision == ($inference.runtime_revision // $job.revision) and
             $envelope.pool_revision == $inference.pool_revision and
             $envelope.secrets_generation == $inference.secrets_generation and
             $envelope.pool_sha256 == $inference.pool_sha256 and
             $envelope.materials_source_sha256 == $inference.materials_source_sha256 and
             $envelope.attempt_generation == $inference.attempt_generation and
             $envelope.configuration_binding == $inference.configuration_binding and
             $envelope.deadline_at == $inference.deadline_at and
             $envelope.request_contract_version == $receipt.request_contract_version and
             $envelope.request_sha256 == $receipt.request_sha256 and
             $envelope.plan_context_sha256 == $receipt.plan_context_sha256 and
             (($envelope.legacy_v121_origin // null) == ($inference.legacy_v121_origin // null)) and
             (if $envelope.migration_from == null then $envelope.transition_reason == null
              else $envelope.transition_reason == "configuration_changed" and
                ($envelope.migration_from | provider_configuration_valid) and
                ($envelope.migration_from.attempt_generation | positive_safe_integer) and
                ((($envelope.migration_from | keys) - ["runtime_revision","pool_revision",
                  "secrets_generation","pool_sha256","materials_source_sha256",
                  "attempt_generation"] | length) == 0) end) and
             (if $envelope.legacy_v121_origin == null then true
              else ($envelope.legacy_v121_origin | legacy_v121_origin) and
                $envelope.attempt_generation == 2 and $envelope.migration_from == null end)
           end)
        end;
      def provider_settlement_artifact_valid($job):
        ($job.plan | visitor_plan_artifact_valid) and
        (($job.provider_settlement | provider_settlement_finished) or
          ($job | provider_settlement_outstanding_valid));
      def valid_answer_artifact($state; $job):
        ($job.id | lowercase_hex(64)) and (
        ($job.plan | visitor_plan_artifact_valid) or
        ($job.inference | provider_inference_artifact_valid($job)) or
        ($job | provider_receipt_valid) or
        ($job | provider_settlement_artifact_valid($job)) or
        ($job | provider_retirement_finished_for) or
        ($job | provider_retirement_outstanding_valid) or
        ($job.provider_migration_from | provider_migration_artifact_valid) or
        ($job | legacy_v121_pending_valid) or
        ([$state.outgoing[]? | select(outgoing_artifact_valid(.; $job))] | length) > 0);
      def invalid_answer_artifact($state; $job):
        (($job.id | lowercase_hex(64)) | not) or
        (($job.plan != null) and (($job.plan | visitor_plan_artifact_valid) | not)) or
        (($job.inference != null) and
          (($job.inference | provider_inference_artifact_valid($job)) | not)) or
        (($job.provider_result_receipt != null) and (($job | provider_receipt_valid) | not)) or
        (($job.provider_settlement != null) and
          (($job | provider_settlement_artifact_valid($job)) | not)) or
        (($job.provider_retirement != null) and
          ((($job | provider_retirement_finished_for) or
            ($job | provider_retirement_outstanding_valid)) | not)) or
        (($job.provider_migration_from != null) and
          (($job.provider_migration_from | provider_migration_artifact_valid) | not)) or
        (($job.legacy_v121_pending_origin != null) and
          (($job | legacy_v121_pending_valid) | not)) or
        ([$state.outgoing[]? | select(type == "object" and .job_id == $job.id) |
          select((outgoing_artifact_valid(.; $job)) | not)] | length) > 0;
      . as $state |
      (["C",
      (if .mode == "human" then 1 else 0 end),
      (if .mode == "human" and .resume_at != null then 1 else 0 end),
      (if .mode == "human" and .resume_at == null then 1 else 0 end),
      (if .worker != null and (.worker.until // 0) >= $now then 1 else 0 end),
      (if .worker != null and (.worker.until // 0) < ($now - 15000) then 1 else 0 end),
      ([.jobs[] | select(.status == "received" or .status == "processing")] | length),
      ((if .pending_feedback != null then 1 else 0 end) +
       ([.offers[]? | select(([.kind,.purpose,.action,.type] | any(. == "feedback" or (type == "string" and startswith("feedback_")))))]|length) +
       ([.jobs[]? | select(.status != "done" and .status != "cancelled" and .status != "failed") |
          select(.plan.feedback_retired != true) |
          select(.plan.feedback_event != null or ([.plan.kind,.plan.purpose,.plan.action,.plan.type] |
            any(. == "feedback" or (type == "string" and startswith("feedback_")))))]|length)),
      ([.jobs[]? | select((.status == "received" or .status == "processing") and
        ((.responsibility_status // "pending") == "pending" or .responsibility_status == "unresolved_failure"))] | length),
      ([$state.jobs[]? as $job |
        select(aged_pending_responsibility($state; $job)) |
        select((valid_answer_artifact($state; $job)) | not) | 1] | length),
      ([$state.jobs[]? as $job |
        select(aged_pending_responsibility($state; $job)) |
        select(invalid_answer_artifact($state; $job)) | 1] | length),
      ([.jobs[]? | select(.responsibility_status == "unresolved_failure")] | length),
      ([.jobs[]? | select(.responsibility_status == "intentional_silence")] | length),
      ([.outgoing[]? | select(type == "object" and
        (.status == "unknown" or .status == "sending"))] | length),
      ([.jobs[]? | select(.responsibility_status == "unresolved_failure") |
        (if (.failure_since | nonnegative_safe_integer) then .failure_since
         elif (.received_at | nonnegative_safe_integer) then .received_at
         else 0 end)] | min // 0),
      ([.outgoing[]? | select(type == "object" and
        (.status == "unknown" or .status == "sending") and
        (.created_at | nonnegative_safe_integer)) | .created_at] | min // 0),
      ([.jobs[]? | select(.provider_settlement != null) |
        .provider_settlement as $settlement |
        select(($settlement | provider_settlement_finished) | not)] | length),
      ([.jobs[]? | select(.provider_settlement != null) |
        .provider_settlement as $settlement |
        select(if ($settlement | type) != "object" then true
          elif ($settlement.state == "pending" or $settlement.state == "deferred") then
            ((provider_settlement_outstanding_valid) | not)
          else (($settlement | provider_settlement_finished) | not) end)] | length),
      ([.jobs[]? | select(has("provider_retirement")) |
        select((provider_retirement_finished_for) | not)] | length),
      ([.jobs[]? | select(has("provider_retirement") or
          has("provider_retirement_failure_code")) |
        .provider_retirement as $retirement |
        select((has("provider_retirement_failure_code") and
            ((provider_retirement_finished_for) | not)) or
          if ($retirement | type) != "object" then true
          elif ($retirement.state == "pending" or $retirement.state == "deferred") then
            ((provider_retirement_outstanding_valid) | not)
          else ((provider_retirement_finished_for) | not) end)] | length),
      ([.jobs[]? | select(.provider_result_receipt != null)] | length),
      ([.jobs[]? | select(.provider_result_receipt != null) |
        select((provider_receipt_valid) | not)] | length) +
      ([.jobs[]? | select(has("legacy_v121_pending_origin")) |
        select((legacy_v121_pending_valid) | not)] | length) +
      ([.jobs[]? | select(.inference != null and .provider_result_receipt == null) |
        select((.inference | type) != "object" or
          ((.inference | has("provider_receipt_protocol_version")) and
            .inference.provider_receipt_protocol_version != 1) or
          ((.inference | has("provider_receipt_protocol_version") | not) and
            ((.inference | legacy_v121_inference) | not)))] | length),
      ([.jobs[]? | select(.provider_result_receipt == null) |
        select((.inference | legacy_v121_inference) or legacy_v121_pending_valid) |
        select(.status == "received" or .status == "processing" or
          .responsibility_status == "unresolved_failure")] | length)
      ] | @tsv),
      (($state.outgoing | if type == "object" then to_entries[]? else empty end) as $entry |
        ($entry.value) as $record |
        select(($record | type) == "object") |
        ($state.jobs[]? | select(.id == $record.job_id)) as $job |
        select(if ($job.id | type) != "string" then false
          else ($job.id | test("^[a-f0-9]{64}$")) end) |
        select(aged_pending_responsibility($state; $job)) |
        select($record.status != "queued") |
        select(outgoing_artifact_valid($record; $job)) |
        (if (($record.purpose | type) == "string") and
            ($record.purpose | test("^[a-z][a-z0-9_]{0,79}$")) then $record.purpose
         elif (($job.plan | type) == "object") and
           (($job.plan.purpose | type) == "string") and
           ($job.plan.purpose | test("^[a-z][a-z0-9_]{0,79}$")) then $job.plan.purpose
         else "" end) as $resolved_purpose |
        select($resolved_purpose != "") |
        (if ($record.body | type) == "object" then
           {type:$record.body.type,content:$record.body.content}
         elif ($job.plan | type) == "object" and
           ($job.plan.type == "text" or $job.plan.type == "picker") then
           {type:$job.plan.type,
            content:(if $job.plan.type == "picker" and ($job.plan.content | type) == "object"
              then ($job.plan.content + {required:false}) else $job.plan.content end)}
         else null end) as $wire |
        ["O",
         (if ($entry.key | length) == 0 then "-" else ($entry.key | tostring) end),
         (if (($record.body | type) != "object") or
            (($record.body.fingerprint | nonnegative_safe_integer) | not) then "-"
          else ($record.body.fingerprint | tostring) end),
         (if (($job.plan | type) != "object") or
            (($job.plan.fingerprint | nonnegative_safe_integer) | not) then "-"
          else ($job.plan.fingerprint | tostring) end),
         $job.id,
         $resolved_purpose,
         (($job | response_generation) | tostring),
         (if (($record.content_sha256 | type) != "string") or
            ($record.content_sha256 | length) == 0 then "-"
          else $record.content_sha256 end),
         (if $wire == null then "-" else ($wire | canonical_value | tojson | @base64) end)] |
        @tsv)' "$file" > "$analysis_file" 2>/dev/null; then
      ((invalid += 1))
      continue
    fi
    if ! chmod 0600 "$analysis_file"; then
      ((invalid += 1))
      continue
    fi
    analysis_count_rows=$(awk -F '\t' '$1 == "C" {count += 1} END {print count + 0}' "$analysis_file")
    analysis_invalid_rows=$(awk -F '\t' '
      $1 == "C" {
        if (NF != 23) {bad += 1; next}
        for (column = 2; column <= 23; column += 1) if ($column !~ /^[0-9]+$/) bad += 1
        next
      }
      $1 == "O" {if (NF != 9) bad += 1; next}
      {bad += 1}
      END {print bad + 0}
    ' "$analysis_file")
    if [[ "$analysis_count_rows" != 1 || "$analysis_invalid_rows" != 0 ]]; then
      ((invalid += 1))
      continue
    fi
    IFS=$'\t' read -r analysis_tag human_count timed_count permanent_count active_count stale_count job_count feedback_count \
      pending_count stalled_count invalid_artifact_count unresolved_count silence_count unknown_count file_oldest_unresolved file_oldest_unknown \
      settlement_count invalid_settlement_count retirement_count invalid_retirement_count \
      receipt_count invalid_receipt_count legacy_inference_count < "$analysis_file"
    if [[ "$analysis_tag" != C ]]; then
      ((invalid += 1))
      continue
    fi
    human=$((human+human_count)); timed=$((timed+timed_count)); permanent=$((permanent+permanent_count))
    active_workers=$((active_workers+active_count)); stale_workers=$((stale_workers+stale_count)); pending_jobs=$((pending_jobs+job_count))
    feedback_pending=$((feedback_pending+feedback_count))
    responsibility_pending=$((responsibility_pending+pending_count))
    stalled_no_artifact=$((stalled_no_artifact+stalled_count))
    invalid_responsibility_artifacts=$((invalid_responsibility_artifacts+invalid_artifact_count))
    unresolved_jobs=$((unresolved_jobs+unresolved_count))
    intentional_silence=$((intentional_silence+silence_count))
    unknown_deliveries=$((unknown_deliveries+unknown_count))
    provider_settlements=$((provider_settlements+settlement_count))
    invalid_settlements=$((invalid_settlements+invalid_settlement_count))
    provider_retirements=$((provider_retirements+retirement_count))
    invalid_retirements=$((invalid_retirements+invalid_retirement_count))
    provider_receipts=$((provider_receipts+receipt_count))
    invalid_provider_receipts=$((invalid_provider_receipts+invalid_receipt_count))
    legacy_provider_inferences=$((legacy_provider_inferences+legacy_inference_count))
    context_hash_invalid=0
    while IFS=$'\t' read -r stored_hash encoded_context; do
      [[ -n "$stored_hash" && -n "$encoded_context" ]] || continue
      actual_hash=$(printf '%s' "$encoded_context" | base64 -d 2>/dev/null | sha256sum | awk '{print $1}')
      [[ "$actual_hash" == "$stored_hash" ]] || ((context_hash_invalid += 1))
    done < <(jq -r '
      def canonical_value:
        if type == "object" then to_entries | sort_by(.key) |
          map({key:.key,value:(.value | canonical_value)}) | from_entries
        elif type == "array" then map(canonical_value)
        else . end;
      .jobs[]? | select(.provider_result_receipt != null) |
      [(.provider_result_receipt.plan_context_sha256 // ""),
       ((if (.provider_result_receipt | has("plan_context"))
         then .provider_result_receipt.plan_context else null end |
         canonical_value | tojson | @base64))] | @tsv' "$file" 2>/dev/null)
    invalid_provider_receipts=$((invalid_provider_receipts+context_hash_invalid))
    legacy_binding_invalid=0
    while IFS=$'\t' read -r stored_hash encoded_legacy_configuration; do
      [[ -n "$stored_hash" && -n "$encoded_legacy_configuration" ]] || continue
      actual_hash=$(printf '%s' "$encoded_legacy_configuration" | base64 -d 2>/dev/null | sha256sum | awk '{print $1}')
      [[ "$actual_hash" == "$stored_hash" ]] || ((legacy_binding_invalid += 1))
    done < <(jq -r '
      .jobs[]? | select(.legacy_v121_pending_origin.phase == "successor_bound") |
      .legacy_v121_pending_origin as $marker |
      [($marker.target_configuration_binding // ""),
       ([$marker.target.runtime_revision,$marker.target.pool_revision,
         $marker.target.secrets_generation,$marker.target.pool_sha256,
         $marker.target.materials_source_sha256] | tojson | @base64)] | @tsv' \
      "$file" 2>/dev/null)
    invalid_provider_receipts=$((invalid_provider_receipts+legacy_binding_invalid))
    inference_binding_invalid=0
    while IFS=$'\t' read -r stored_hash encoded_configuration; do
      [[ -n "$stored_hash" && -n "$encoded_configuration" ]] || continue
      actual_hash=$(printf '%s' "$encoded_configuration" | base64 -d 2>/dev/null | sha256sum | awk '{print $1}')
      [[ "$actual_hash" == "$stored_hash" ]] || ((inference_binding_invalid += 1))
    done < <(jq -r --argjson now "$now" --argjson stalled_after_ms "$stalled_after_ms" '
      def nonnegative_safe_integer:
        type == "number" and . >= 0 and . <= 9007199254740991 and floor == .;
      def positive_safe_integer:
        type == "number" and . >= 1 and . <= 9007199254740991 and floor == .;
      def active_owner($state; $job):
        $job.status == "processing" and
        (($job.execution_token | type) == "string") and
        ($job.execution_token | test("^[a-f0-9]{24}$")) and
        ($job.lease_until | nonnegative_safe_integer) and $job.lease_until > $now and
        (($state.worker | type) == "object") and
        $state.worker.job == $job.id and $state.worker.token == $job.execution_token and
        ($state.worker.until | nonnegative_safe_integer) and $state.worker.until > $now;
      . as $state | .jobs[]? as $job |
      select($job.control == false and
        ($job.responsibility_status // "pending") == "pending" and
        ($job.status == "received" or
          ($job.status == "processing" and ((active_owner($state; $job)) | not))) and
        ($job.attempts | positive_safe_integer) and
        ($job.received_at | nonnegative_safe_integer) and
        ($now - $job.received_at > $stalled_after_ms)) |
      $job.inference as $inference |
      select(($inference | type) == "object" and
        ($inference.configuration_binding | type) == "string" and
        ($inference.runtime_revision | type) == "number" and
        ($inference.pool_revision | type) == "number" and
        ($inference.secrets_generation | type) == "string" and
        ($inference.pool_sha256 | type) == "string" and
        ($inference.materials_source_sha256 | type) == "string") |
      [($inference.configuration_binding // ""),
       ([$inference.runtime_revision,$inference.pool_revision,
         $inference.secrets_generation,$inference.pool_sha256,
         $inference.materials_source_sha256] | tojson | @base64)] | @tsv' \
      "$file" 2>/dev/null)
    invalid_provider_receipts=$((invalid_provider_receipts+inference_binding_invalid))
    invalid_responsibility_artifacts=$((invalid_responsibility_artifacts+inference_binding_invalid))
    picker_identity_invalid=0
    while IFS=$'\t' read -r picker_id picker_fingerprint; do
      [[ "$picker_id" =~ ^crispai_[a-f0-9]{32}$ && "$picker_fingerprint" =~ ^[0-9]+$ ]] \
        || { ((picker_identity_invalid += 1)); continue; }
      picker_hex=$(printf '%s' "$picker_id" | sha256sum | awk '{print substr($1,1,12)}')
      expected_picker_fingerprint=$((16#$picker_hex))
      [[ "$picker_fingerprint" == "$expected_picker_fingerprint" ]] \
        || ((picker_identity_invalid += 1))
    done < <(jq -r --argjson now "$now" --argjson stalled_after_ms "$stalled_after_ms" '
      def nonnegative_safe_integer:
        type == "number" and . >= 0 and . <= 9007199254740991 and floor == .;
      def positive_safe_integer:
        type == "number" and . >= 1 and . <= 9007199254740991 and floor == .;
      def active_owner($state; $job):
        $job.status == "processing" and
        (($job.execution_token | type) == "string") and
        ($job.execution_token | test("^[a-f0-9]{24}$")) and
        ($job.lease_until | nonnegative_safe_integer) and $job.lease_until > $now and
        (($state.worker | type) == "object") and
        $state.worker.job == $job.id and $state.worker.token == $job.execution_token and
        ($state.worker.until | nonnegative_safe_integer) and $state.worker.until > $now;
      . as $state | .jobs[]? as $job |
      select($job.control == false and
        ($job.responsibility_status // "pending") == "pending" and
        ($job.status == "received" or
          ($job.status == "processing" and ((active_owner($state; $job)) | not))) and
        ($job.attempts | positive_safe_integer) and
        ($job.received_at | nonnegative_safe_integer) and
        ($now - $job.received_at > $stalled_after_ms)) |
      select(($job.plan | type) == "object" and $job.plan.type == "picker" and
        ($job.plan.purpose == "menu" or $job.plan.purpose == "handoff_offer") and
        ($job.plan.content | type) == "object" and
        (($job.plan.content.id | type) == "string") and
        ($job.plan.content.id | test("^crispai_[a-f0-9]{32}$")) and
        ($job.plan.fingerprint | nonnegative_safe_integer)) |
      [$job.plan.content.id, ($job.plan.fingerprint | tostring)] | @tsv' \
      "$file" 2>/dev/null)
    invalid_responsibility_artifacts=$((invalid_responsibility_artifacts+picker_identity_invalid))
    outgoing_shape_invalid=$(jq -r '
      if .outgoing == null then 0
      elif (.outgoing | type) != "object" then 1
      else ([.outgoing[]? | select(type != "object")] | length) end' "$file" 2>/dev/null)
    [[ "$outgoing_shape_invalid" =~ ^[0-9]+$ ]] || outgoing_shape_invalid=1
    invalid_responsibility_artifacts=$((invalid_responsibility_artifacts+outgoing_shape_invalid))
    outgoing_identity_invalid=0
    while IFS=$'\t' read -r analysis_tag map_fingerprint body_fingerprint plan_fingerprint job_id purpose response_generation stored_hash encoded_wire; do
      [[ "$analysis_tag" == O ]] || continue
      [[ "$map_fingerprint" != '-' && "$job_id" != '-' && "$purpose" != '-' ]] \
        || { ((outgoing_identity_invalid += 1)); continue; }
      if [[ "$plan_fingerprint" == '-' ]]; then
        fingerprint_material="${state_key}|${job_id}|${purpose}"
        if [[ "$response_generation" =~ ^[0-9]+$ ]] && (( response_generation > 0 )); then
          fingerprint_material+="|recovery:${response_generation}"
        fi
        fingerprint_hex=$(printf '%s' "$fingerprint_material" | sha256sum | awk '{print substr($1,1,12)}')
        expected_fingerprint=$((16#$fingerprint_hex))
      else
        expected_fingerprint=$plan_fingerprint
      fi
      if [[ "$map_fingerprint" != "$expected_fingerprint" \
        || ( "$body_fingerprint" != '-' && "$body_fingerprint" != "$expected_fingerprint" ) ]]; then
        ((outgoing_identity_invalid += 1))
        continue
      fi
      if [[ "$encoded_wire" != '-' ]]; then
        actual_hash=$(printf '%s' "$encoded_wire" | base64 -d 2>/dev/null | sha256sum | awk '{print $1}')
        [[ -n "$stored_hash" && "$actual_hash" == "$stored_hash" ]] \
          || ((outgoing_identity_invalid += 1))
      fi
    done < "$analysis_file"
    invalid_responsibility_artifacts=$((invalid_responsibility_artifacts+outgoing_identity_invalid))
    settlement_identity_invalid=0
    while IFS=$'\t' read -r stored_hash encoded_plan settlement_generation job_generation; do
      [[ -n "$stored_hash" && -n "$encoded_plan" ]] || continue
      actual_hash=$(printf '%s' "$encoded_plan" | base64 -d 2>/dev/null | sha256sum | awk '{print $1}')
      if [[ "$actual_hash" != "$stored_hash" || "$settlement_generation" != "$job_generation" ]]; then
        ((settlement_identity_invalid += 1))
      fi
    done < <(jq -r '
      def canonical_value:
        if type == "object" then to_entries | sort_by(.key) |
          map({key:.key,value:(.value | canonical_value)}) | from_entries
        elif type == "array" then map(canonical_value)
        else . end;
      def response_generation:
        if (.response_generation | type) == "number" and .response_generation >= 0 and
          .response_generation <= 1000000 and (.response_generation | floor) == .response_generation
        then .response_generation else 0 end;
      .jobs[]? | select(.provider_settlement != null and (.plan | type) == "object") |
      [(.provider_settlement.plan_sha256 // ""),
       ({type:(.plan.type // ""),purpose:(.plan.purpose // ""),content:(.plan.content // ""),
         outcome:(.plan.outcome // ""),sources:(.plan.sources // []),tags:(.plan.tags // [])} |
         canonical_value | tojson | @base64),
       ((.provider_settlement.response_generation // "") | tostring),
       ((response_generation) | tostring)] | @tsv' "$file" 2>/dev/null)
    while IFS=$'\t' read -r stored_hash encoded_configuration; do
      [[ -n "$stored_hash" && -n "$encoded_configuration" ]] || continue
      actual_hash=$(printf '%s' "$encoded_configuration" | base64 -d 2>/dev/null | sha256sum | awk '{print $1}')
      [[ "$actual_hash" == "$stored_hash" ]] || ((settlement_identity_invalid += 1))
    done < <(jq -r '
      .jobs[]? | select(.provider_settlement.state == "pending" or
        .provider_settlement.state == "deferred") |
      .provider_settlement.envelope as $envelope |
      [($envelope.configuration_binding // ""),
       ([$envelope.runtime_revision,$envelope.pool_revision,$envelope.secrets_generation,
         $envelope.pool_sha256,$envelope.materials_source_sha256] | tojson | @base64)] | @tsv' \
      "$file" 2>/dev/null)
    invalid_settlements=$((invalid_settlements+settlement_identity_invalid))
    retirement_identity_invalid=0
    while IFS=$'\t' read -r stored_identity encoded_retirement identity_kind stored_hash encoded_configuration; do
      [[ -n "$stored_identity" && -n "$encoded_retirement" && -n "$identity_kind" ]] || continue
      actual_hash=$(printf '%s' "$encoded_retirement" | base64 -d 2>/dev/null | sha256sum | awk '{print $1}')
      [[ "$actual_hash" == "$stored_identity" ]] || ((retirement_identity_invalid += 1))
      if [[ "$identity_kind" == current ]]; then
        if [[ -z "$stored_hash" || -z "$encoded_configuration" ]]; then
          ((retirement_identity_invalid += 1))
        else
          actual_hash=$(printf '%s' "$encoded_configuration" | base64 -d 2>/dev/null | sha256sum | awk '{print $1}')
          [[ "$actual_hash" == "$stored_hash" ]] || ((retirement_identity_invalid += 1))
        fi
      fi
    done < <(jq -r '
      def canonical_value:
        if type == "object" then to_entries | sort_by(.key) |
          map({key:.key,value:(.value | canonical_value)}) | from_entries
        elif type == "array" then map(canonical_value)
        else . end;
      .jobs[]? | select(.provider_retirement.state == "pending" or
        .provider_retirement.state == "deferred") |
      .provider_retirement as $retirement | $retirement.envelope as $envelope |
      [($retirement.identity_sha256 // ""),
       ({envelope:$envelope,purpose:($retirement.purpose // "")} |
         canonical_value | tojson | @base64),
       (if $envelope.legacy_v121_cleanup == true then "legacy_v121" else "current" end),
       ($envelope.configuration_binding // "-"),
       ([$envelope.runtime_revision,$envelope.pool_revision,$envelope.secrets_generation,
         $envelope.pool_sha256,$envelope.materials_source_sha256] | tojson | @base64)] | @tsv' \
      "$file" 2>/dev/null)
    invalid_retirements=$((invalid_retirements+retirement_identity_invalid))
    if (( file_oldest_unresolved > 0 && (oldest_unresolved == 0 || file_oldest_unresolved < oldest_unresolved) )); then oldest_unresolved=$file_oldest_unresolved; fi
    if (( file_oldest_unknown > 0 && (oldest_unknown == 0 || file_oldest_unknown < oldest_unknown) )); then oldest_unknown=$file_oldest_unknown; fi
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
  if (( deadline_reached || invalid > 0 )); then
    doctor_add runtime.answer_responsibilities '应答责任' WARN critical \
      '会话状态未完整读取，不能断言所有访客问题均已有结果或明确静默原因' filesystem \
      '先修复会话状态读取；自检不会删除、重放或改写客户任务' "$start"
  elif (( stalled_no_artifact > 0 || invalid_responsibility_artifacts > 0 || unresolved_jobs > 0 || (oldest_unknown > 0 && now - oldest_unknown > 300000) )); then
    doctor_add runtime.answer_responsibilities '应答责任' FAIL critical \
      "未完成故障 ${unresolved_jobs}；责任产物损坏 ${invalid_responsibility_artifacts}；长期处理无产物 ${stalled_no_artifact}；待处理/处理中 ${responsibility_pending}；未知发送 ${unknown_deliveries}；明确政策静默 ${intentional_silence}" filesystem \
      '查看最老未完成责任、Provider/Crisp 状态和补偿水位；不要清空任务或解除人工来消除告警' "$start"
  elif (( responsibility_pending > 0 || unknown_deliveries > 0 )); then
    doctor_add runtime.answer_responsibilities '应答责任' WARN critical \
      "责任产物损坏 ${invalid_responsibility_artifacts}；长期处理无产物 ${stalled_no_artifact}；待处理/处理中 ${responsibility_pending}；未知发送 ${unknown_deliveries}；明确政策静默 ${intentional_silence}" filesystem \
      '短时处理属于正常；若持续超过十分钟，请检查调度、Provider 与 Crisp 发送对账' "$start"
  else
    doctor_add runtime.answer_responsibilities '应答责任' PASS critical \
      "当前无未完成故障或未知发送；责任产物损坏 ${invalid_responsibility_artifacts}；长期处理无产物 ${stalled_no_artifact}；待处理/处理中 ${responsibility_pending}；未知发送 ${unknown_deliveries}；明确政策静默 ${intentional_silence}" filesystem '' "$start"
  fi
  if (( deadline_reached || invalid > 0 )); then
    doctor_add runtime.provider_receipts '推理请求回执' WARN critical \
      '会话状态未完整读取，不能断言所有推理请求身份均可安全恢复' filesystem \
      '先修复会话状态读取；自检不会清除推理信封或重新调用模型' "$start"
  elif (( invalid_provider_receipts > 0 )); then
    doctor_add runtime.provider_receipts '推理请求回执' FAIL critical \
      "发现 ${invalid_provider_receipts} 项推理回执身份损坏；当前回执总数 ${provider_receipts}" filesystem \
      '保留原问题和推理信封，检查受限状态备份与当前 runtime；不要删除回执来强制重试' "$start"
  elif (( legacy_provider_inferences > 0 )); then
    doctor_add runtime.provider_receipts '推理请求回执' WARN critical \
      "发现 ${legacy_provider_inferences} 项旧版未跟踪推理信封；将由当前独占任务保留原问题并迁移" filesystem \
      '保持任务扫描运行；迁移前不会把旧信封冒充已确认结果' "$start"
  elif (( provider_receipts > 0 )); then
    doctor_add runtime.provider_receipts '推理请求回执' WARN warning \
      "有 ${provider_receipts} 项当前代推理回执等待重放或收敛；不会并行重新推理" filesystem \
      '检查 adapter 与五秒任务扫描；持续未收敛时查看应答责任故障原因' "$start"
  else
    doctor_add runtime.provider_receipts '推理请求回执' PASS warning \
      '当前没有等待收敛或身份损坏的推理请求回执' filesystem '' "$start"
  fi
  if (( deadline_reached || invalid > 0 )); then
    doctor_add runtime.provider_settlements '推理结果持久结算' WARN critical \
      '会话状态未完整读取，不能断言所有已持久答案均已释放临时推理缓存' filesystem \
      '先修复会话状态读取；自检不会删除推理结果或客户任务' "$start"
  elif (( invalid_settlements > 0 )); then
    doctor_add runtime.provider_settlements '推理结果持久结算' FAIL critical \
      "发现 ${invalid_settlements} 项结算身份损坏；待结算总数 ${provider_settlements}" filesystem \
      '检查当前 runtime 与 adapter 身份；不要删除会话任务或问题缓存来消除告警' "$start"
  elif (( provider_settlements > 0 )); then
    doctor_add runtime.provider_settlements '推理结果持久结算' WARN warning \
      "有 ${provider_settlements} 项已持久答案等待 adapter 确认；不会重新推理或重复发送" filesystem \
      '检查 adapter 与五秒任务扫描；恢复后会用原签名身份继续结算' "$start"
  else
    doctor_add runtime.provider_settlements '推理结果持久结算' PASS warning \
      '当前没有延后的推理结果结算' filesystem '' "$start"
  fi
  if (( deadline_reached || invalid > 0 )); then
    doctor_add runtime.provider_retirements 'Provider 推理缓存清理' WARN critical \
      '会话状态未完整读取，不能断言不可见推理缓存均已安全释放' filesystem \
      '先修复会话状态读取；自检不会删除推理缓存或客户任务' "$start"
  elif (( invalid_retirements > 0 )); then
    doctor_add runtime.provider_retirements 'Provider 推理缓存清理' FAIL critical \
      "发现 ${invalid_retirements} 项清理身份或授权损坏；待清理总数 ${provider_retirements}" filesystem \
      '保留人工/总开关状态与原签名身份，检查当前 runtime 和 adapter；不要手工删除问题缓存' "$start"
  elif (( provider_retirements > 0 )); then
    doctor_add runtime.provider_retirements 'Provider 推理缓存清理' WARN warning \
      "有 ${provider_retirements} 项推理缓存等待 adapter 安全释放；清理事务本身不会调用上游或向访客发送，未解决问题将在清理后按原责任恢复" filesystem \
      '检查 adapter 与五秒任务扫描；人工或总关任务保持静默，其余未解决责任继续正常恢复' "$start"
  else
    doctor_add runtime.provider_retirements 'Provider 推理缓存清理' PASS warning \
      '当前没有延后的 Provider 推理缓存清理事务' filesystem '' "$start"
  fi
  if (( deadline_reached || invalid > 0 )); then
    doctor_add runtime.feedback '自动评价邀请' WARN warning '会话扫描未完整完成，未对未检查的旧评价状态作成功判断' filesystem '修复上述会话检查问题后重试；自检不会删除任何任务' "$start"
  elif (( feedback_pending > 0 )); then
    doctor_add runtime.feedback '自动评价邀请' WARN warning "发现 ${feedback_pending} 项旧评价上下文；新运行时禁止派发，等待正常扫描精确退役" filesystem '检查五秒扫描心跳；保留历史反馈及人工按钮，自检不会清空状态' "$start"
  elif jq -e '.feedback.enabled == false and .feedback.auto_invite == false' "$(doctor_config_file feedback)" >/dev/null 2>&1; then
    doctor_add runtime.feedback '自动评价邀请' PASS warning '自动评价邀请配置已停用，未发现未退役的旧评价上下文' filesystem '' "$start"
  else
    doctor_add runtime.feedback '自动评价邀请' WARN warning '旧反馈配置尚未迁移；当前版本运行时不会据此重新邀请评价' filesystem '通过受管升级或资料应用完成停用迁移；不修改欢迎及人工开关' "$start"
  fi
}

# 普通长任务与控制任务共用跨 Code execution 的后台执行许可，
# 只读自检必须验证许可目录本身；否则坏 slot 会让任务永久回到
# received，而容器/工作流检查仍可能全绿。
# repair=1 只由显式 --fix 在 n8n 停写窗口调用，且只移除结构完整、已经过期的
# 许可；活动许可、不安全成员和无法证明归属的内容一律保留。
doctor_runtime_permits_inspect() {
  local repair=${1:-0}
  doctor_timeout 8 python3 -B - "$DOCTOR_DEPLOY_DIR" "$repair" <<'PY'
import json
import math
import os
from pathlib import Path
import re
import secrets
import stat
import sys
import time

deploy = Path(sys.argv[1])
repair = sys.argv[2] == "1"
runtime_dir = deploy / "data" / "runtime"
permit_root = runtime_dir / "ordinary-processing-permits"
capacity = 8
ordinary_capacity = 7
lease_ms = 60_000
slot_pattern = re.compile(r"^slot-([0-7])$")
stale_pattern = re.compile(r"^\.stale-slot-([0-7])-[a-f0-9]{32}$")
token_pattern = re.compile(r"^[a-f0-9]{32}$")


def finite_number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def restricted_directory(info, expected_uid):
    return (stat.S_ISDIR(info.st_mode) and not stat.S_ISLNK(info.st_mode)
            and stat.S_IMODE(info.st_mode) == 0o700 and info.st_uid == expected_uid)


def restricted_file(info, expected_uid):
    return (stat.S_ISREG(info.st_mode) and not stat.S_ISLNK(info.st_mode)
            and info.st_nlink == 1 and stat.S_IMODE(info.st_mode) == 0o600
            and info.st_uid == expected_uid and info.st_size <= 4096)


def public_stat(info):
    return (info.st_dev, info.st_ino, info.st_mtime_ns, info.st_size)


def snapshot(path, slot, expected_uid):
    try:
        directory = os.lstat(path)
        if not restricted_directory(directory, expected_uid):
            return {"unsafe": True}
        names = sorted(os.listdir(path))
        if len(names) > 2 or any(name not in ("heartbeat.json", "owner.json") for name in names):
            return {"unsafe": True}
        members = {}
        values = {}
        for name in names:
            member_path = path / name
            info = os.lstat(member_path)
            if not restricted_file(info, expected_uid):
                return {"unsafe": True}
            members[name] = public_stat(info)
            with open(member_path, "r", encoding="utf-8") as stream:
                values[name] = json.load(stream)
    except (OSError, UnicodeError, json.JSONDecodeError, ValueError):
        return {"unsafe": True}

    result = {
        "unsafe": False,
        "directory": (directory.st_dev, directory.st_ino, directory.st_mtime_ns),
        "names": names,
        "members": members,
        "partial": len(names) != 2,
    }
    file_activity_expires = (max([directory.st_mtime_ns / 1_000_000]
                                 + [value[2] / 1_000_000 for value in members.values()])
                             + lease_ms)
    if result["partial"]:
        owner = values.get("owner.json")
        heartbeat = values.get("heartbeat.json")
        if owner is not None:
            if not (isinstance(owner, dict) and owner.get("schema_version") == 1
                    and owner.get("slot") == slot and token_pattern.fullmatch(owner.get("token", ""))
                    and owner.get("kind") in ("ordinary", "control")
                    and (slot != 7 or owner.get("kind") == "control")
                    and finite_number(owner.get("acquired_at")) and owner["acquired_at"] > 0
                    and finite_number(owner.get("expires_at"))
                    and owner["expires_at"] >= owner["acquired_at"]):
                return {"unsafe": True}
        if heartbeat is not None:
            if not (isinstance(heartbeat, dict) and heartbeat.get("schema_version") == 1
                    and token_pattern.fullmatch(heartbeat.get("token", ""))):
                return {"unsafe": True}
        result["expires_at"] = max(file_activity_expires,
                                   owner["expires_at"] if owner is not None else 0)
        return result

    owner = values["owner.json"]
    heartbeat = values["heartbeat.json"]
    if not (isinstance(owner, dict) and owner.get("schema_version") == 1
            and owner.get("slot") == slot and token_pattern.fullmatch(owner.get("token", ""))
            and owner.get("kind") in ("ordinary", "control")
            and (slot != 7 or owner.get("kind") == "control")
            and finite_number(owner.get("acquired_at")) and owner["acquired_at"] > 0
            and finite_number(owner.get("expires_at")) and owner["expires_at"] >= owner["acquired_at"]
            and isinstance(heartbeat, dict) and heartbeat.get("schema_version") == 1
            and heartbeat.get("token") == owner["token"]):
        return {"unsafe": True}
    result["token"] = owner["token"]
    result["kind"] = owner["kind"]
    result["expires_at"] = max(owner["expires_at"], members["heartbeat.json"][2] / 1_000_000 + lease_ms)
    return result


def same_snapshot(left, right):
    return (left and right and not left.get("unsafe") and not right.get("unsafe")
            and left["directory"] == right["directory"]
            and left["names"] == right["names"] and left["members"] == right["members"])


def restore_quarantine(quarantine, original):
    try:
        os.lstat(original)
        return False
    except FileNotFoundError:
        pass
    except OSError:
        return False
    try:
        os.rename(quarantine, original)
        return True
    except OSError:
        return False


def delete_snapshot(path, before, slot, expected_uid):
    current = snapshot(path, slot, expected_uid)
    if not same_snapshot(before, current):
        return False
    descriptor = None
    try:
        flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
        descriptor = os.open(path, flags)
        opened = os.fstat(descriptor)
        if (opened.st_dev, opened.st_ino, opened.st_mtime_ns) != current["directory"]:
            return False
        for name in current["names"]:
            info = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
            if public_stat(info) != current["members"][name]:
                return False
        for name in current["names"]:
            os.unlink(name, dir_fd=descriptor)
        os.close(descriptor)
        descriptor = None
        os.rmdir(path)
        return True
    except OSError:
        return False
    finally:
        if descriptor is not None:
            try:
                os.close(descriptor)
            except OSError:
                pass


def inspect():
    report = {"schema_version": 1, "present": False, "capacity": capacity,
              "ordinary_capacity": ordinary_capacity,
              "active": 0, "creating": 0, "expired": 0, "quarantined": 0,
              "ordinary_active": 0, "control_active": 0,
              "unsafe": 0, "reclaimable": 0, "occupied": 0,
              "ordinary_occupied": 0, "saturated": False, "ordinary_saturated": False}
    records = []
    try:
        runtime_info = os.lstat(runtime_dir)
    except OSError:
        report["unsafe"] = 1
        return report, records
    if not stat.S_ISDIR(runtime_info.st_mode) or stat.S_ISLNK(runtime_info.st_mode):
        report["unsafe"] = 1
        return report, records
    expected_uid = runtime_info.st_uid
    try:
        root_info = os.lstat(permit_root)
    except FileNotFoundError:
        return report, records
    except OSError:
        report["unsafe"] = 1
        return report, records
    report["present"] = True
    if not restricted_directory(root_info, expected_uid):
        report["unsafe"] = 1
        return report, records
    try:
        names = sorted(os.listdir(permit_root))
    except OSError:
        report["unsafe"] = 1
        return report, records
    if len(names) > 128:
        report["unsafe"] += 1
    now = time.time() * 1000
    occupied_slots = set()
    for name in names[:129]:
        slot_match = slot_pattern.fullmatch(name)
        stale_match = stale_pattern.fullmatch(name)
        if not slot_match and not stale_match:
            report["unsafe"] += 1
            continue
        slot = int((slot_match or stale_match).group(1))
        is_quarantine = stale_match is not None
        record_path = permit_root / name
        current = snapshot(record_path, slot, expected_uid)
        if current is None or current.get("unsafe"):
            report["unsafe"] += 1
            if not is_quarantine:
                occupied_slots.add(slot)
            continue
        if is_quarantine:
            report["quarantined"] += 1
        else:
            occupied_slots.add(slot)
        expired = current["expires_at"] <= now
        if expired:
            report["expired"] += 1
            report["reclaimable"] += 1
            records.append((record_path, slot, current, is_quarantine))
        elif current["partial"]:
            report["creating"] += 1
        elif not is_quarantine:
            report["active"] += 1
            report[("control_active" if current.get("kind") == "control" else "ordinary_active")] += 1
    report["occupied"] = len(occupied_slots)
    report["ordinary_occupied"] = len([slot for slot in occupied_slots if slot < ordinary_capacity])
    report["saturated"] = len(occupied_slots) >= capacity
    report["ordinary_saturated"] = report["ordinary_occupied"] >= ordinary_capacity
    return report, records


def reclaim(path, slot, before, is_quarantine, expected_uid):
    original = path
    quarantine = path
    if not is_quarantine:
        quarantine = permit_root / (f".stale-slot-{slot}-{secrets.token_hex(16)}")
        try:
            os.rename(path, quarantine)
        except OSError:
            return False
        moved = snapshot(quarantine, slot, expected_uid)
        if not same_snapshot(before, moved) or moved["expires_at"] > time.time() * 1000:
            restore_quarantine(quarantine, original)
            return False
        before = moved
    if delete_snapshot(quarantine, before, slot, expected_uid):
        return True
    if not is_quarantine:
        restore_quarantine(quarantine, original)
    return False


report, records = inspect()
repaired = 0
repair_failed = 0
if repair and report["unsafe"] == 0 and records:
    expected_uid = os.lstat(runtime_dir).st_uid
    for record in records:
        if reclaim(*record, expected_uid):
            repaired += 1
        else:
            repair_failed += 1
    report, _ = inspect()
report["repaired"] = repaired
report["repair_failed"] = repair_failed
print(json.dumps(report, ensure_ascii=False, sort_keys=True, separators=(",", ":")))
PY
}

doctor_runtime_permits_check() {
  local start report rc=0 unsafe active creating expired quarantined occupied
  start=$(doctor_now_ms)
  report="${DOCTOR_TEMP_ROOT}/runtime-processing-permits.json"
  if ! command -v python3 >/dev/null 2>&1; then
    doctor_add runtime.processing_permits '后台任务执行许可' FAIL critical '缺少只读校验所需的 Python 运行环境' host '运行 crispai doctor --fix 补齐受支持依赖' "$start"
    return
  fi
  doctor_runtime_permits_inspect 0 > "$report" 2>/dev/null || rc=$?
  if (( rc != 0 )) || ! jq -e '.schema_version == 1 and .capacity == 8 and .ordinary_capacity == 7 and
      ([.active,.creating,.expired,.quarantined,.ordinary_active,.control_active,.unsafe,.reclaimable,.occupied,.ordinary_occupied] |
        all(type == "number" and . >= 0)) and
      (.saturated | type == "boolean") and (.ordinary_saturated | type == "boolean")' "$report" >/dev/null 2>&1; then
    if (( rc == 124 || rc == 137 )) || ! doctor_remaining >/dev/null 2>&1; then
      doctor_deadline_add runtime.processing_permits '后台任务执行许可' filesystem "$start"
    else
      doctor_add runtime.processing_permits '后台任务执行许可' FAIL critical '无法安全读取后台任务执行许可状态' filesystem '核对运行目录权限和异常成员；不要直接删除未知许可' "$start"
    fi
    return
  fi
  unsafe=$(jq -r '.unsafe' "$report"); active=$(jq -r '.active' "$report")
  creating=$(jq -r '.creating' "$report"); expired=$(jq -r '.expired' "$report")
  quarantined=$(jq -r '.quarantined' "$report"); occupied=$(jq -r '.occupied' "$report")
  if (( unsafe > 0 )); then
    doctor_add runtime.processing_permits '后台任务执行许可' FAIL critical \
      "发现 ${unsafe} 个不安全或不可证明可回收的许可成员；后台任务可能持续延后" filesystem \
      '停止 n8n 后核对目录归属、权限、链接及 JSON；安全修复不会删除未知内容' "$start"
  elif jq -e '.saturated == true or .ordinary_saturated == true' "$report" >/dev/null; then
    doctor_add runtime.processing_permits '后台任务执行许可' WARN warning \
      "后台许可 ${occupied}/8 已占用（活动 ${active}，创建中 ${creating}，过期 ${expired}）；普通任务槽最多 7，Webhook 始终保留 2 个 runner" filesystem \
      '短时满载可等待；若过期许可持续存在，可显式运行 crispai doctor --fix' "$start"
  elif (( expired > 0 || quarantined > 0 || creating > 0 )); then
    doctor_add runtime.processing_permits '后台任务执行许可' WARN warning \
      "后台许可活动 ${active}/8；普通任务最多 7；过期 ${expired}，隔离中 ${quarantined}，创建中 ${creating}" filesystem \
      '短时创建/释放属于正常并发；持续过期可显式运行 crispai doctor --fix' "$start"
  else
    doctor_add runtime.processing_permits '后台任务执行许可' PASS critical \
      "后台许可活动 ${active}/8；普通任务最多 7；目录结构、权限和租约均正常" filesystem '' "$start"
  fi
}

doctor_runtime_scheduler_check() {
  local start file now started completed age lock_state lock_file
  local isolated_count isolated_too_large isolated_invalid_json isolated_invalid_state isolated_io_error
  local recovered_at recovered_age recovered_reason recovered_reason_cn recovered_status recovered_summary
  local catchup_status catchup_checked catchup_watermark catchup_age catchup_lag catchup_pending
  local catchup_recovered catchup_conversations catchup_unresolved catchup_unresolved_since
  local catchup_error catchup_error_cn catchup_summary catchup_budget_used catchup_budget_limit
  local catchup_budget_note
  start=$(doctor_now_ms)
  lock_file="${DOCTOR_DEPLOY_DIR}/data/runtime/scheduler-scan.lock"
  lock_state=$(scheduler_scan_lock_state "$DOCTOR_DEPLOY_DIR")
  case "$lock_state" in
    absent)
      doctor_add runtime.scheduler_lock '会话扫描互斥锁' PASS critical '当前没有重叠扫描锁' filesystem '' "$start"
      ;;
    legacy-ownerless-empty)
      doctor_add runtime.scheduler_lock '会话扫描互斥锁' FAIL critical '发现旧版无所有权空锁；新运行时会拒绝在线删除' filesystem '运行 crispai doctor --fix，在维护锁及 n8n 停写窗口精确迁移' "$start"
      ;;
    owned)
      if [[ "$(stat -c '%a' -- "${lock_file}/owner.json" 2>/dev/null || true)" == 600 ]] \
        && jq -e '.schema_version == 1 and (.token | type == "string" and test("^[a-f0-9]{32}$")) and
          (.pid | type == "number" and . > 0) and (.boot_id | type == "string" and length >= 16) and
          (.process_start | type == "string" and test("^[0-9]+$")) and
          (.started_at | type == "number") and (.heartbeat_at | type == "number")' \
          "${lock_file}/owner.json" >/dev/null 2>&1; then
        doctor_add runtime.scheduler_lock '会话扫描互斥锁' PASS critical '重叠扫描锁包含受管所有权记录' filesystem '' "$start"
      else
        doctor_add runtime.scheduler_lock '会话扫描互斥锁' FAIL critical '扫描锁所有权记录无效或权限不安全' filesystem '停止 n8n 后人工核对；安全修复不会删除非空或无效所有权锁' "$start"
      fi
      ;;
    *)
      doctor_add runtime.scheduler_lock '会话扫描互斥锁' FAIL critical '扫描锁为链接、特殊文件、非空未知目录或权限归属不安全' filesystem '停止 n8n 后人工核对；不要按时间直接删除未知锁' "$start"
      ;;
  esac
  start=$(doctor_now_ms)
  file="${DOCTOR_DEPLOY_DIR}/data/runtime/scheduler-health.json"
  now=$(doctor_now_ms)
  if [[ ! -e "$file" ]]; then
    doctor_add runtime.scheduler '会话恢复扫描心跳' WARN warning '尚无扫描完成记录；新安装可能仍在等待首次五秒扫描' filesystem '稍候重试；若超过一分钟仍缺失，请检查 n8n workflow 与 Code runner' "$start"
    return
  fi
  if [[ ! -f "$file" || -L "$file" ]] \
    || ! jq -e '
      def nonnegative_integer:
        type == "number" and . >= 0 and . <= 9007199254740991 and floor == .;
      .schema_version == 1 and
      (.started_at | type == "number") and
      (.completed_at | type == "number") and
      (
        if has("isolated_sessions") then
          (.isolated_sessions | type == "object") and
          (.isolated_sessions as $isolated |
            (($isolated | keys | sort) == ["count", "reasons"]) and
            ($isolated.count | nonnegative_integer) and
            ($isolated.reasons | type == "object") and
            (($isolated.reasons | keys | sort) as $reason_keys |
              if $reason_keys == ["invalid_json", "invalid_state", "too_large"] then
                ($isolated.reasons.too_large | nonnegative_integer) and
                ($isolated.reasons.invalid_json | nonnegative_integer) and
                ($isolated.reasons.invalid_state | nonnegative_integer) and
                ($isolated.count == ($isolated.reasons.too_large +
                  $isolated.reasons.invalid_json + $isolated.reasons.invalid_state))
              elif $reason_keys == ["invalid_json", "invalid_state", "io_error", "too_large"] then
                ($isolated.reasons.too_large | nonnegative_integer) and
                ($isolated.reasons.invalid_json | nonnegative_integer) and
                ($isolated.reasons.invalid_state | nonnegative_integer) and
                ($isolated.reasons.io_error | nonnegative_integer) and
                ($isolated.count == ($isolated.reasons.too_large +
                  $isolated.reasons.invalid_json + $isolated.reasons.invalid_state +
                  $isolated.reasons.io_error))
              else false end)
          )
        else
          true
        end
      ) and
      (
        if has("health_recovered") then
          .health_recovered == null or
          ((.health_recovered | type == "object") and
            (.health_recovered.at | nonnegative_integer and . > 0 and . <= 9007199254740991) and
            (.health_recovered.reason | type == "string" and
              (. == "too_large" or . == "invalid_json" or . == "invalid_state")))
        else
          true
        end
      ) and
      (
        if has("crisp_rest_catchup") then
          (.crisp_rest_catchup as $catchup |
            ($catchup | type == "object") and
            ((($catchup | keys) - [
              "status", "checked_at", "watermark", "lag_ms", "pending",
              "recovered_messages", "checked_conversations", "unresolved_messages",
              "unresolved_since", "request_budget_used", "request_budget_limit",
              "request_budget_reset_at", "error_code"
            ]) | length == 0) and
            ($catchup.status == "bootstrap" or $catchup.status == "idle" or
              $catchup.status == "ok" or $catchup.status == "warning") and
            ($catchup.checked_at | nonnegative_integer and . <= 9007199254740991) and
            ($catchup.watermark | nonnegative_integer and . <= 9007199254740991) and
            ($catchup.lag_ms == null or ($catchup.lag_ms | nonnegative_integer and . <= 9007199254740991)) and
            ($catchup.pending | type == "boolean") and
            ($catchup.recovered_messages | nonnegative_integer) and
            ($catchup.checked_conversations | nonnegative_integer) and
            ((($catchup | has("unresolved_messages")) | not) or
              ($catchup.unresolved_messages | nonnegative_integer)) and
            ((($catchup | has("unresolved_since")) | not) or
              ($catchup.unresolved_since == null or
                ($catchup.unresolved_since | nonnegative_integer and . <= 9007199254740991))) and
            ((($catchup.unresolved_messages // 0) == 0) or
              (($catchup.unresolved_since // 0) > 0)) and
            ((($catchup | has("request_budget_used")) | not) or
              ($catchup.request_budget_used | nonnegative_integer)) and
            ((($catchup | has("request_budget_limit")) | not) or
              ($catchup.request_budget_limit | nonnegative_integer and . >= 4 and . <= 4000)) and
            ((($catchup | has("request_budget_reset_at")) | not) or
              ($catchup.request_budget_reset_at == null or
                ($catchup.request_budget_reset_at | nonnegative_integer and . > 0 and . <= 9007199254740991))) and
            ((($catchup | has("error_code")) | not) or
              ($catchup.error_code == "authorization_failed" or
               $catchup.error_code == "endpoint_unavailable" or
               $catchup.error_code == "rate_limited" or
               $catchup.error_code == "state_too_large" or
               $catchup.error_code == "state_unsafe" or
               $catchup.error_code == "state_invalid" or
               $catchup.error_code == "local_persistence_failed" or
               $catchup.error_code == "event_time_pending" or
               $catchup.error_code == "message_invalid" or
               $catchup.error_code == "messages_quarantined" or
               $catchup.error_code == "unresolved_capacity" or
               $catchup.error_code == "daily_budget_exhausted" or
               $catchup.error_code == "network_unavailable" or
               $catchup.error_code == "request_failed" or
               $catchup.error_code == "clock_rewound" or
               $catchup.error_code == "endpoint_changed" or
               $catchup.error_code == "credentials_changed" or
               $catchup.error_code == "not_initialized")) and
            (($catchup.status == "warning") or (($catchup | has("error_code")) | not))
          )
        else
          true
        end
      )' "$file" >/dev/null 2>&1; then
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
  if jq -e 'has("crisp_rest_catchup")' "$file" >/dev/null 2>&1; then
    catchup_status=$(jq -r '.crisp_rest_catchup.status' "$file")
    catchup_checked=$(jq -r '.crisp_rest_catchup.checked_at' "$file")
    catchup_watermark=$(jq -r '.crisp_rest_catchup.watermark' "$file")
    catchup_pending=$(jq -r '.crisp_rest_catchup.pending' "$file")
    catchup_recovered=$(jq -r '.crisp_rest_catchup.recovered_messages' "$file")
    catchup_conversations=$(jq -r '.crisp_rest_catchup.checked_conversations' "$file")
    catchup_unresolved=$(jq -r '.crisp_rest_catchup.unresolved_messages // 0' "$file")
    catchup_unresolved_since=$(jq -r '.crisp_rest_catchup.unresolved_since // 0' "$file")
    catchup_budget_used=$(jq -r '.crisp_rest_catchup.request_budget_used // 0' "$file")
    catchup_budget_limit=$(jq -r '.crisp_rest_catchup.request_budget_limit // 0' "$file")
    catchup_budget_note=''
    if (( catchup_budget_limit > 0 )); then
      catchup_budget_note="；本周期补偿 REST 已用 ${catchup_budget_used}/${catchup_budget_limit}，其余站点配额保留给正文、控制与投递对账"
    fi
    catchup_error=$(jq -r '.crisp_rest_catchup.error_code // ""' "$file")
    if (( catchup_watermark > now + 60000 || catchup_checked > now + 60000 )); then
      doctor_add runtime.crisp_rest_catchup 'Crisp 漏收补偿' WARN warning \
        'REST 补偿记录晚于本机时钟，无法可靠判断当前水位' filesystem \
        '先同步系统时钟，再复查 n8n 调度；自检不会补发消息或改变会话状态' "$start"
    else
      if (( catchup_watermark > 0 && catchup_watermark <= now )); then
        catchup_lag=$((now-catchup_watermark))
      else
        catchup_lag=-1
      fi
      if (( catchup_checked > 0 && catchup_checked <= now )); then
        catchup_age=$((now-catchup_checked))
      else
        catchup_age=-1
      fi
      case "$catchup_error" in
        authorization_failed) catchup_error_cn='当前 Crisp REST 凭据或权限校验失败' ;;
        endpoint_unavailable) catchup_error_cn='当前 Crisp REST 端点不可用' ;;
        rate_limited) catchup_error_cn='Crisp REST 当前限流' ;;
        state_too_large) catchup_error_cn='补偿状态超过安全读取上限' ;;
        state_unsafe) catchup_error_cn='补偿状态路径或权限不安全' ;;
        state_invalid) catchup_error_cn='补偿状态内容无效' ;;
        local_persistence_failed) catchup_error_cn='漏收消息尚未在本机可靠持久化，水位已停止推进' ;;
        event_time_pending) catchup_error_cn='漏收消息已持久保存，原始事件时间尚待 Crisp 精确核验，水位已停止推进' ;;
        message_invalid) catchup_error_cn='Crisp 返回的相关消息结构无效，水位已停止推进以避免漏答' ;;
        messages_quarantined) catchup_error_cn='Crisp 返回的相关消息已进入持久待核查责任，其他会话继续补偿' ;;
        unresolved_capacity) catchup_error_cn='Crisp 待核查消息已达到受管容量上限，新水位已停止推进' ;;
        daily_budget_exhausted) catchup_error_cn='本周期 Crisp 补偿 REST 保守预算已用尽，游标与未完成责任均已保留' ;;
        network_unavailable) catchup_error_cn='Crisp REST 网络暂不可达' ;;
        clock_rewound) catchup_error_cn='本机时钟回拨，原补偿水位已保留并等待受控重放' ;;
        endpoint_changed) catchup_error_cn='Crisp REST 地址已变更，原补偿水位已保留并等待新连接续扫' ;;
        credentials_changed) catchup_error_cn='Crisp REST 凭据或权限层级已变更，旧成功事实已失效' ;;
        not_initialized) catchup_error_cn='尚未建立 REST 补偿水位' ;;
        request_failed) catchup_error_cn='Crisp REST 请求返回未识别故障' ;;
        '') catchup_error_cn='最近补偿发现无法安全摄入的消息结构' ;;
      esac
      if [[ "$catchup_status" == bootstrap ]]; then
        doctor_add runtime.crisp_rest_catchup 'Crisp 漏收补偿' WARN warning \
          '已从当前时刻建立 REST 补偿水位；首次启用不会补答历史消息' filesystem \
          '等待下一轮调度；若持续超过一分钟，请检查 n8n Code runner 与 Crisp REST 权限' "$start"
      elif (( catchup_unresolved > 0 )); then
        catchup_summary="存在 ${catchup_unresolved} 条持久待核查消息；扫描头水位不能代表这些责任已经完成"
        if (( catchup_unresolved_since > 0 && catchup_unresolved_since <= now )); then
          catchup_summary+="，最早未完整覆盖范围距今 $((now-catchup_unresolved_since)) 毫秒"
        fi
        doctor_add runtime.crisp_rest_catchup 'Crisp 漏收补偿' FAIL critical \
          "$catchup_summary" filesystem \
          '使用受管诊断核对待查消息；自检不会删除责任、解除人工屏障或把畸形响应当作已处理' "$start"
      elif [[ "$catchup_status" == warning ]]; then
        catchup_summary="${catchup_error_cn}；最近一次补入 ${catchup_recovered} 条通知${catchup_budget_note}"
        if (( catchup_lag >= 0 )); then catchup_summary+="，水位距今 ${catchup_lag} 毫秒"; fi
        doctor_add runtime.crisp_rest_catchup 'Crisp 漏收补偿' WARN warning \
          "$catchup_summary" filesystem \
          '实时 Website Hook 仍是主路径；核对当前 Crisp 权限、网络与 n8n 调度，补偿不会自动回复历史消息' "$start"
      elif [[ "$catchup_pending" == true ]] \
        || (( catchup_lag < 0 || catchup_lag > 600000 || catchup_age < 0 || catchup_age > 600000 )); then
        catchup_summary="REST 补偿正在分段推进或最近结果已过期；最近一次补入 ${catchup_recovered} 条通知"
        if (( catchup_lag >= 0 )); then catchup_summary+="，水位距今 ${catchup_lag} 毫秒"; fi
        doctor_add runtime.crisp_rest_catchup 'Crisp 漏收补偿' WARN warning \
          "$catchup_summary" filesystem \
          '稍候复查；若水位持续超过十分钟，请检查 Crisp REST、n8n 调度及受管状态目录' "$start"
      else
        doctor_add runtime.crisp_rest_catchup 'Crisp 漏收补偿' PASS warning \
          "REST 漏收补偿最近完成（生产周期至少 60 秒、单轮最多 4 次 REST 请求）；水位距今 ${catchup_lag} 毫秒，最近一次检查 ${catchup_conversations} 个会话并补入 ${catchup_recovered} 条通知${catchup_budget_note}" \
          filesystem '' "$start"
      fi
    fi
  fi
  if jq -e 'has("isolated_sessions") and .isolated_sessions.count > 0' "$file" >/dev/null 2>&1; then
    isolated_count=$(jq -r '.isolated_sessions.count' "$file")
    isolated_too_large=$(jq -r '.isolated_sessions.reasons.too_large' "$file")
    isolated_invalid_json=$(jq -r '.isolated_sessions.reasons.invalid_json' "$file")
    isolated_invalid_state=$(jq -r '.isolated_sessions.reasons.invalid_state' "$file")
    isolated_io_error=$(jq -r '.isolated_sessions.reasons.io_error // 0' "$file")
    doctor_add runtime.scheduler_isolation '会话状态隔离' FAIL critical \
      "最近完成的扫描隔离 ${isolated_count} 个异常会话状态（文件过大 ${isolated_too_large}、JSON 无效 ${isolated_invalid_json}、状态无效 ${isolated_invalid_state}、状态 I/O 错误 ${isolated_io_error}）；异常会话未参与处理，其他合法会话继续扫描" \
      filesystem '从受限备份逐一核对并恢复异常状态；自检及 --fix 不会删除状态、解除人工或补发历史消息' "$start"
  fi
  if jq -e 'has("health_recovered") and .health_recovered != null' "$file" >/dev/null 2>&1; then
    recovered_at=$(jq -r '.health_recovered.at' "$file")
    recovered_reason=$(jq -r '.health_recovered.reason' "$file")
    case "$recovered_reason" in
      too_large) recovered_reason_cn='文件超过安全读取上限' ;;
      invalid_json) recovered_reason_cn='JSON 内容无效' ;;
      invalid_state) recovered_reason_cn='心跳结构无效' ;;
    esac
    if (( recovered_at > now + 60000 )); then
      recovered_status=WARN
      recovered_summary="扫描心跳曾因${recovered_reason_cn}被安全重建；恢复记录时间晚于本机时钟，会话状态未被删除"
    else
      if (( recovered_at > now )); then recovered_age=0; else recovered_age=$((now-recovered_at)); fi
      if (( recovered_age <= 86400000 )); then
        recovered_status=WARN
        recovered_summary="最近 24 小时内扫描心跳曾因${recovered_reason_cn}被安全重建；会话状态未被删除，当前扫描活性见上一项"
      else
        recovered_status=PASS
        recovered_summary="历史记录：扫描心跳曾因${recovered_reason_cn}被安全重建，已超过 24 小时；会话状态未被删除，当前扫描活性见上一项"
      fi
    fi
    doctor_add runtime.scheduler_health_recovery '扫描心跳恢复记录' "$recovered_status" warning \
      "$recovered_summary" filesystem '若近期反复出现，请检查运行目录容量、权限及原子写入；自检及 --fix 不会删除会话状态' "$start"
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
    doctor_add logs.policy '运维日志策略' WARN warning '已保存的日志策略尚未完成运行时应用' filesystem '从日志菜单重新应用；不要手工只改 Compose' "$start"
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
  local start report rc=0 state source_valid projection_valid pending expected output binding_rc=0
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
  # status 中的 applied_sha256 是“来源语义摘要”，用于判断原文 pending；
  # 运行容器挂载对账必须使用投影文件本身的逐字节摘要。
  expected=$(sha256sum -- "${DOCTOR_DEPLOY_DIR}/config/materials-applied.json" 2>/dev/null | awk '{print $1}' || true)
  if [[ "$projection_valid" == true && "$state" == applied ]]; then
    if [[ "$source_valid" == true && "$pending" == false ]]; then
      doctor_add materials.applied '资料生效投影' PASS critical \
        '当前生效资料已核验，可编辑原文与其一致' filesystem '' "$start"
    elif [[ "$source_valid" == true ]]; then
      doctor_add materials.applied '资料生效投影' WARN warning \
        '当前生效资料有效；可编辑原文有尚未应用的变更' filesystem \
        '先预览并显式应用资料；运行时仍使用上一有效投影' "$start"
    else
      doctor_add materials.applied '资料生效投影' WARN warning \
        '当前生效资料有效；可编辑原文校验失败' filesystem \
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

doctor_provider_inference_probe() {
  local remaining budget result status=0
  DOCTOR_PROVIDER_INFERENCE_STATUS=unknown
  remaining=$(doctor_remaining) || return 1
  (( remaining > 7 )) || return 1
  budget=$((remaining - 5))
  (( budget <= 20 )) || budget=20
  result=$(mktemp "${DOCTOR_TEMP_ROOT}/provider-inference.XXXXXX") || return 1
  # 一个有独立总预算的合成问题走真实知识问答入口，不向 Crisp 发送消息。
  # shellcheck disable=SC2016
  CRISPAI_DIAGNOSTIC_JSON=1 doctor_timeout "$((budget + 5))" bash -c '
    source "$1/configuration.sh"
    configuration_query "$2" "仅作管理员连接检查，请简短回复连接正常。" "$3"
  ' doctor-inference "$DOCTOR_DIR" "$DOCTOR_DEPLOY_DIR" "$((budget * 1000))" > "$result" 2>/dev/null || status=$?
  if (( status == 0 )); then
    DOCTOR_PROVIDER_INFERENCE_STATUS=success
    rm -f -- "$result"
    return 0
  fi
  DOCTOR_PROVIDER_INFERENCE_STATUS=$(jq -M -er '
    select(.verified == false and (.error.code | type == "string")) | .error.code
  ' "$result" 2>/dev/null || true)
  if [[ -z "$DOCTOR_PROVIDER_INFERENCE_STATUS" ]]; then
    if (( status == 124 || status == 137 )); then DOCTOR_PROVIDER_INFERENCE_STATUS=upstream_timeout
    else DOCTOR_PROVIDER_INFERENCE_STATUS=admin_query_failed; fi
  fi
  rm -f -- "$result"
  return 1
}

doctor_provider_inference_failure() {
  local code=$1
  case "$code" in
    materials_not_ready) DOCTOR_PROVIDER_FAILURE_SUMMARY='当前 Prompt、知识或索引代次尚未完成应用'; DOCTOR_PROVIDER_FAILURE_SUGGESTION='从菜单 16 → 6 应用资料，再核对知识索引状态' ;;
    provider_configuration_invalid|configuration_applying) DOCTOR_PROVIDER_FAILURE_SUMMARY='接口池配置尚未完整应用或仍在恢复'; DOCTOR_PROVIDER_FAILURE_SUGGESTION='从菜单 3 查看应用状态；未完成事务使用主备策略中的恢复入口' ;;
    authentication_failed) DOCTOR_PROVIDER_FAILURE_SUMMARY='当前接口鉴权失败'; DOCTOR_PROVIDER_FAILURE_SUGGESTION='从菜单 3 编辑对应地址与 Key，候选验证成功后再应用' ;;
    model_unavailable) DOCTOR_PROVIDER_FAILURE_SUMMARY='当前模型原名或推理端点不可用'; DOCTOR_PROVIDER_FAILURE_SUGGESTION='从菜单 3 核对该接口模型、协议及 Base URL；模型列表成功不代表推理成功' ;;
    rate_limited) DOCTOR_PROVIDER_FAILURE_SUMMARY='上游返回请求频率限制'; DOCTOR_PROVIDER_FAILURE_SUGGESTION='查看菜单 3 的冷却与备用状态，按 Retry-After 后再验证' ;;
    quota_exhausted) DOCTOR_PROVIDER_FAILURE_SUMMARY='上游返回额度或余额不足'; DOCTOR_PROVIDER_FAILURE_SUGGESTION='处理该授权范围的额度，或配置有独立授权的备用接口' ;;
    upstream_timeout) DOCTOR_PROVIDER_FAILURE_SUMMARY='实际推理在限定时间内未完成'; DOCTOR_PROVIDER_FAILURE_SUGGESTION='检查容器到上游的网络、接口响应时间及主备总预算' ;;
    upstream_unavailable|connection_failed) DOCTOR_PROVIDER_FAILURE_SUMMARY='上游服务或容器网络连接不可用'; DOCTOR_PROVIDER_FAILURE_SUGGESTION='检查 DNS/TLS、上游状态和容器实际地址；宿主可连不等于容器可连' ;;
    protocol_error) DOCTOR_PROVIDER_FAILURE_SUMMARY='接口协议、地址路径或请求格式不兼容'; DOCTOR_PROVIDER_FAILURE_SUGGESTION='从菜单 3 核对该接口的 Chat Completions / Responses 模式、Base URL 前缀及实际推理端点' ;;
    invalid_response) DOCTOR_PROVIDER_FAILURE_SUMMARY='上游返回空正文、非 JSON 或与所选协议不符'; DOCTOR_PROVIDER_FAILURE_SUGGESTION='核对 Chat/Responses 协议及地址路径；不要只依据 /models 判定可用' ;;
    question_result_rejected) DOCTOR_PROVIDER_FAILURE_SUMMARY='旧推理结果未通过当前访客输出规则'; DOCTOR_PROVIDER_FAILURE_SUGGESTION='原问题已保留并进入受控恢复；若持续出现，请检查知识输入与 Provider 原始结果类别' ;;
    retrieval_error|retrieval_invalid|retrieval_unavailable|source_unmapped|source_ambiguous|context_invalid) DOCTOR_PROVIDER_FAILURE_SUMMARY='知识检索或启用资料映射未通过'; DOCTOR_PROVIDER_FAILURE_SUGGESTION='从菜单 5 核对索引与来源，再执行菜单 16 → 6 资料应用' ;;
    context_preparation_incomplete|invalid_input|no_capable_provider) DOCTOR_PROVIDER_FAILURE_SUMMARY='当前接口能力、上下文容量或最终请求结构不兼容'; DOCTOR_PROVIDER_FAILURE_SUGGESTION='核对模型协议/容量/图片能力和已应用 Prompt；未发送不完整请求' ;;
    pool_cooling|pool_exhausted) DOCTOR_PROVIDER_FAILURE_SUMMARY='本题预算内没有接口成功返回'; DOCTOR_PROVIDER_FAILURE_SUGGESTION='从菜单 3 查看近期切换记录，逐项定位鉴权、限流、超时或响应格式' ;;
    question_timeout|question_budget_exhausted) DOCTOR_PROVIDER_FAILURE_SUMMARY='本次推理已达到总时间或调用次数上限'; DOCTOR_PROVIDER_FAILURE_SUGGESTION='查看近期切换记录并修复前序故障；不会继续放大请求' ;;
    question_interrupted) DOCTOR_PROVIDER_FAILURE_SUMMARY='先前推理在 adapter 重启或执行权丢失后已安全终止'; DOCTOR_PROVIDER_FAILURE_SUGGESTION='确认 adapter 已稳定运行后重新执行一次完整自检；旧结果不会继续出站' ;;
    state_changed|question_cancelled) DOCTOR_PROVIDER_FAILURE_SUMMARY='检测期间配置或控制状态发生变化，结果已作废'; DOCTOR_PROVIDER_FAILURE_SUGGESTION='刷新当前状态后重新执行完整自检' ;;
    safety_refusal) DOCTOR_PROVIDER_FAILURE_SUMMARY='模型对合成检查作出安全拒绝'; DOCTOR_PROVIDER_FAILURE_SUGGESTION='这不是连接成功证据，也不会切换接口规避模型安全限制' ;;
    *) DOCTOR_PROVIDER_FAILURE_SUMMARY='实际推理未完成，错误类别未能安全确认'; DOCTOR_PROVIDER_FAILURE_SUGGESTION='依次核对菜单 5 的知识、菜单 3 的接口及菜单 2 的组件结果' ;;
  esac
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
  elif doctor_provider_inference_probe; then
    doctor_add provider.inference 'Provider 实际推理' PASS critical '合成问题通过 AnythingLLM、实际推理入口并返回非空正文；未向客户发消息' external '' "$start"
  else
    doctor_provider_inference_failure "$DOCTOR_PROVIDER_INFERENCE_STATUS"
    doctor_add provider.inference 'Provider 实际推理' FAIL critical "$DOCTOR_PROVIDER_FAILURE_SUMMARY" external "$DOCTOR_PROVIDER_FAILURE_SUGGESTION" "$start"
  fi
}

doctor_run_checks() {
  doctor_installation_check
  doctor_system_check
  doctor_files_and_config_check
  doctor_provider_pool_files
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
    doctor_skip n8n.execution_backlog 'n8n 生产执行积压' '离线范围不访问数据库' docker
    doctor_skip provider.adapter 'Provider adapter' '离线范围未检查' docker
    doctor_skip provider.prompt_capacity '完整提示词基础容量' '离线范围未检查运行容器' docker
    doctor_skip provider.adapter_code_binding 'Provider adapter 程序运行代' '离线范围未检查单文件挂载' docker
    if (( DOCTOR_VISITOR_OUTPUT_ENABLED )); then
      doctor_skip provider.visitor_output_code_binding '访客输出策略运行代' '离线范围未检查单文件挂载' docker
    else
      doctor_skip provider.visitor_output_code_binding '访客输出策略运行代' '当前程序版本不包含独立访客输出策略模块' docker
    fi
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
    doctor_n8n_execution_backlog_check
    doctor_adapter_check
  fi
  doctor_materials_check
  doctor_knowledge_metadata_check
  doctor_knowledge_lexical_check
  doctor_runtime_state_check
  doctor_runtime_permits_check
  doctor_runtime_scheduler_check
  doctor_logs_check
  doctor_external_check
}

doctor_result_status() {
  jq -rs --arg id "$1" '[.[] | select(.id == $id)][-1].status // "SKIP"' "$DOCTOR_RESULTS"
}

doctor_safe_fix() {
  local launcher_path access_mode service service_status permissions_status dependency_status daemon_status compose_status install_state scheduler_state
  local permit_status permit_report permit_reclaimable=0 permit_unsafe=0 permit_active=0 permit_creating=0
  local permit_repair_report permit_repair_rc=0 permit_stopped_n8n=0 permit_restart_rc=0
  if (( EUID != 0 )); then
    doctor_fix_add fix.authorization '修复授权' FAIL '安全修复需要 root；未执行任何修复'
    return
  fi
  install_state=$(installation_state "$DOCTOR_DEPLOY_DIR")
  if [[ "$install_state" != ready && "$install_state" != local-ready ]]; then
    doctor_fix_add fix.generation-guard '安装代际保护' FAIL "当前状态 ${install_state:-未知} 不是稳定运行代；未补依赖、改权限/入口或启动任何服务"
    return
  fi
  acquire_maintenance_lock "$DOCTOR_DEPLOY_DIR"
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
    scheduler_state=$(scheduler_scan_lock_state "$DOCTOR_DEPLOY_DIR")
    if [[ "$scheduler_state" == legacy-ownerless-empty ]]; then
      if doctor_compose_timeout 30 stop n8n >/dev/null 2>&1 \
        && cleanup_legacy_scheduler_scan_lock "$DOCTOR_DEPLOY_DIR" \
        && doctor_compose_timeout 45 up -d n8n >/dev/null 2>&1; then
        doctor_fix_add fix.runtime.scheduler_lock '迁移旧版会话扫描锁' PASS '已在维护锁与 n8n 停写窗口删除本实例无所有权空锁，并恢复 n8n'
      else
        doctor_compose_timeout 45 up -d n8n >/dev/null 2>&1 || true
        doctor_fix_add fix.runtime.scheduler_lock '迁移旧版会话扫描锁' FAIL '未能完成停写、精确空目录删除及服务恢复；非空、链接或带所有权锁未删除'
      fi
    elif [[ "$scheduler_state" == absent || "$scheduler_state" == owned ]]; then
      doctor_fix_add fix.runtime.scheduler_lock '迁移旧版会话扫描锁' SKIP '未发现需要迁移的旧版无所有权空锁'
    else
      doctor_fix_add fix.runtime.scheduler_lock '迁移旧版会话扫描锁' FAIL '锁形态不符合旧版空目录；为保护调度所有权未自动删除'
    fi

    permit_status=$(doctor_result_status runtime.processing_permits)
    permit_report="${DOCTOR_TEMP_ROOT}/runtime-processing-permits.json"
    if [[ -f "$permit_report" && ! -L "$permit_report" ]]; then
      permit_reclaimable=$(jq -r '.reclaimable // 0' "$permit_report" 2>/dev/null || printf 0)
      permit_unsafe=$(jq -r '.unsafe // 1' "$permit_report" 2>/dev/null || printf 1)
      permit_active=$(jq -r '.active // 0' "$permit_report" 2>/dev/null || printf 0)
      permit_creating=$(jq -r '.creating // 0' "$permit_report" 2>/dev/null || printf 0)
    fi
    if [[ "$permit_reclaimable" =~ ^[0-9]+$ && "$permit_active" =~ ^[0-9]+$ \
      && "$permit_creating" =~ ^[0-9]+$ && "$permit_unsafe" == 0 ]] \
      && (( permit_reclaimable > 0 && (permit_active > 0 || permit_creating > 0) )); then
      doctor_fix_add fix.runtime.processing_permits '回收过期后台任务许可' SKIP \
        "仍有 ${permit_active} 个活动许可和 ${permit_creating} 个创建中许可；为避免中断正常客户任务，本次未停止 n8n 或回收过期项"
    elif [[ "$permit_reclaimable" =~ ^[0-9]+$ && "$permit_unsafe" == 0 ]] \
      && (( permit_reclaimable > 0 )); then
      service_status=$(doctor_result_status container.n8n)
      if [[ "$service_status" == PASS || "$service_status" == WARN ]]; then
        if doctor_compose_timeout 30 stop n8n >/dev/null 2>&1; then
          permit_stopped_n8n=1
        else
          permit_repair_rc=1
        fi
      elif [[ "$service_status" != FAIL ]] || ! grep -Fxq n8n "$DOCTOR_RESTARTABLE_SERVICES"; then
        permit_repair_rc=1
      fi
      permit_repair_report="${DOCTOR_TEMP_ROOT}/runtime-processing-permits-repair.json"
      if (( permit_repair_rc == 0 )); then
        doctor_runtime_permits_inspect 1 > "$permit_repair_report" 2>/dev/null || permit_repair_rc=$?
        if (( permit_repair_rc == 0 )) && ! jq -e \
          '.schema_version == 1 and .unsafe == 0 and .expired == 0 and .repair_failed == 0' \
          "$permit_repair_report" >/dev/null 2>&1; then
          permit_repair_rc=1
        fi
      fi
      if (( permit_stopped_n8n )); then
        doctor_compose_timeout 45 up -d n8n >/dev/null 2>&1 || permit_restart_rc=$?
      fi
      if (( permit_repair_rc == 0 && permit_restart_rc == 0 )); then
        doctor_fix_add fix.runtime.processing_permits '回收过期后台任务许可' PASS \
          '已在 n8n 停写窗口精确回收结构完整且明确过期的许可；活动及未知成员未删除'
      else
        doctor_fix_add fix.runtime.processing_permits '回收过期后台任务许可' FAIL \
          '无法完成停写、精确回收或服务恢复；已保留活动、变化中及未知许可'
      fi
    elif [[ "$permit_status" == FAIL ]]; then
      doctor_fix_add fix.runtime.processing_permits '回收过期后台任务许可' FAIL \
        '许可目录包含不安全或不可证明归属的内容；安全修复未删除任何未知成员'
    else
      doctor_fix_add fix.runtime.processing_permits '回收过期后台任务许可' SKIP \
        '未发现结构完整且明确过期的许可；活动许可和合法短时满载保持不变'
    fi

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
