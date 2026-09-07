#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
WORK_ROOT="${PROJECT_ROOT}/.work/v1.2.0"
mkdir -p -- "$WORK_ROOT"
WORK=$(mktemp -d "$WORK_ROOT/logs-test.XXXXXXXX")
DEPLOY="$WORK/deploy"
BIN="${SCRIPT_DIR}/fixtures/logs"
SYSTEMD_DIR="$WORK/systemd"
SYSTEMD_STATE="$WORK/systemd-state"
CALLS="$WORK/calls.log"
OUT="$WORK/out"
ERR="$WORK/err"
PASSED=0
LAST_RC=0

cleanup() {
  if [[ "${AI_SUPPORT_TEST_KEEP_TMP:-0}" == 1 ]]; then
    printf '日志专项临时目录已保留：%s\n' "$WORK" >&2
  elif [[ "$WORK" == "$WORK_ROOT"/logs-test.* && -d "$WORK" ]]; then
    find "$WORK" -depth -delete
  fi
}
trap cleanup EXIT

fail() { printf '失败：[UNIT/CONTRACT] %s\n' "$1" >&2; exit 1; }
pass() { ((PASSED += 1)); printf '通过：[UNIT/CONTRACT] %s\n' "$1"; }

fixture_env() {
  env PATH="$BIN:$PATH" \
    LOGS_FIXTURE_CALLS="$CALLS" LOGS_FIXTURE_SYSTEMD_STATE="$SYSTEMD_STATE" \
    LOGS_FIXTURE_MAX_SIZE="${LOGS_FIXTURE_MAX_SIZE:-10m}" \
    LOGS_FIXTURE_MAX_FILES="${LOGS_FIXTURE_MAX_FILES:-5}" \
    LOGS_FIXTURE_HOURS="${LOGS_FIXTURE_HOURS:-168}" \
    LOGS_FIXTURE_SECRET="$SECRET" LOGS_FIXTURE_PATH_SECRET="$PATH_SECRET" \
    LOGS_FIXTURE_UP_FAIL_ONCE="${LOGS_FIXTURE_UP_FAIL_ONCE:-0}" \
    LOGS_FIXTURE_UP_SLEEP="${LOGS_FIXTURE_UP_SLEEP:-0}" \
    LOGS_FIXTURE_UP_COUNT_FILE="${LOGS_FIXTURE_UP_COUNT_FILE:-}" \
    LOGS_FIXTURE_STOP_STUCK="${LOGS_FIXTURE_STOP_STUCK:-0}" \
    LOGS_FIXTURE_FAIL_MARKER="$WORK/up-failed-once" \
    CRISPAI_LOGS_SYSTEMD_TEST=1 CRISPAI_LOGS_SYSTEMD_DIR="$SYSTEMD_DIR" \
    "$@"
}

invoke() {
  : > "$OUT"; : > "$ERR"; : > "$CALLS"; LAST_RC=0
  fixture_env bash "$DEPLOY/scripts/logs.sh" --deploy-dir "$DEPLOY" "$@" > "$OUT" 2> "$ERR" || LAST_RC=$?
}

business_hash() {
  (
    cd -- "$DEPLOY"
    find config/app.yaml config/runtime.yaml config/prompt.md knowledge data/runtime data/analytics backups \
      -type f ! -type l -print0 | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum | awk '{print $1}'
  )
}

prepare() {
  local name
  mkdir -p "$DEPLOY"/{scripts,config,logs/doctor-history,logs/diagnostics,tmp,knowledge,data/runtime,data/analytics,backups} \
    "$SYSTEMD_DIR" "$SYSTEMD_STATE"
  cp -p "$PROJECT_ROOT/scripts/common.sh" "$PROJECT_ROOT/scripts/logs.sh" "$PROJECT_ROOT/scripts/log-redact.py" "$DEPLOY/scripts/"
  cp -p "$PROJECT_ROOT/scripts/bootstrap.sh" "$PROJECT_ROOT/scripts/wizard.sh" "$PROJECT_ROOT/scripts/menu-ui.sh" "$DEPLOY/scripts/"
  cp -p "$PROJECT_ROOT/manage.sh" "$DEPLOY/manage.sh"
  cp -p "$PROJECT_ROOT/config/logging.yaml.example" "$DEPLOY/config/logging.yaml"
  cp -p "$PROJECT_ROOT/config/app.yaml" "$DEPLOY/config/app.yaml"
  cp -p "$PROJECT_ROOT/config/runtime.yaml.example" "$DEPLOY/config/runtime.yaml"
  cp -p "$PROJECT_ROOT/config/prompt.md.example" "$DEPLOY/config/prompt.md"
  cp -p "$PROJECT_ROOT/docker-compose.yml" "$DEPLOY/docker-compose.yml"
  cp -p "$PROJECT_ROOT/VERSION" "$DEPLOY/VERSION"
  printf 'ai-support\nstate=ready\ninstalled_version=%s\n' "$(<"$PROJECT_ROOT/VERSION")" > "$DEPLOY/.crisp-ai-installation"
  cp -p "$PROJECT_ROOT/.env.example" "$DEPLOY/.env"
  # shellcheck source=scripts/common.sh disable=SC1091
  source "$PROJECT_ROOT/scripts/common.sh"
  env_set "$DEPLOY/.env" DEPLOY_DIR "$DEPLOY"
  env_set "$DEPLOY/.env" CRISPAI_LOG_RETENTION_DAYS 7
  env_set "$DEPLOY/.env" CRISPAI_LOG_RETENTION_HOURS 168
  env_set "$DEPLOY/.env" CRISPAI_LOG_MAX_SIZE 10m
  env_set "$DEPLOY/.env" CRISPAI_LOG_MAX_FILES 5
  env_set "$DEPLOY/.env" AI_API_KEY "$SECRET"
  env_set "$DEPLOY/.env" CRISP_AUTH_B64 "$BASIC_SECRET"
  env_set "$DEPLOY/.env" AI_CUSTOM_HEADERS_JSON "{\"X-Demo\":\"$HEADER_SECRET\"}"
  # 非生产 fixture：覆盖 JSON 转义换行的脱敏边界；不会由运行时 source。
  printf 'MULTILINE_SECRET="line-one\\nline-two"\n' >> "$DEPLOY/.env"
  chmod 0600 "$DEPLOY/.env" "$DEPLOY/.crisp-ai-installation"
  printf 'runtime-state\n' > "$DEPLOY/data/runtime/session-fixture.json"
  printf 'analytics-business\n' > "$DEPLOY/data/analytics/events.jsonl"
  printf 'knowledge-source\n' > "$DEPLOY/knowledge/fixture.md"
  printf 'backup\n' > "$DEPLOY/backups/fixture.tar"
  chmod 0600 "$DEPLOY/data/runtime/session-fixture.json" "$DEPLOY/data/analytics/events.jsonl" "$DEPLOY/knowledge/fixture.md" "$DEPLOY/backups/fixture.tar"
  cat > "$DEPLOY/scripts/healthcheck.sh" <<'HEALTH'
#!/usr/bin/env bash
set -euo pipefail
[[ "${LOGS_FIXTURE_HEALTH_FAIL:-0}" != 1 ]]
HEALTH
  chmod 0755 "$DEPLOY/scripts/healthcheck.sh" "$DEPLOY/scripts/logs.sh" "$DEPLOY/scripts/log-redact.py"
  for name in "$BIN"/*; do chmod 0755 "$name"; done
}

SECRET='Sec&$#='"'"'"quoted-value-2026'
HEADER_SECRET='Header&$#='"'"'"quoted-value-2026'
BASIC_SECRET='QmFzaWMtZml4dHVyZS1zZWNyZXQ6cGFzcw=='
PATH_SECRET='abcdefghijklmnop987654'
prepare

before=$(business_hash)
invoke --help
(( LAST_RC == 0 )) || fail '--help 失败'
[[ ! -s "$CALLS" ]] || fail '--help 不应访问 Docker/systemd'
invoke --version
(( LAST_RC == 0 )) || fail '--version 失败'
[[ ! -s "$CALLS" ]] || fail '--version 不应访问 Docker/systemd'
pass 'help/version 不触发组件或配置副作用'

# 初始化必须优先读取现有合法投影；升级旧实例保留 3 份。
find "$DEPLOY/config" -maxdepth 1 -type f -name logging.yaml -delete
env_set "$DEPLOY/.env" CRISPAI_LOG_MAX_FILES 3
invoke initialize --profile upgrade-v1
(( LAST_RC == 0 )) || fail 'upgrade-v1 初始化失败'
jq -e '.max_files==3 and .revision==1 and .applied_revision==1' "$DEPLOY/config/logging.yaml" >/dev/null || fail '旧实例没有保留 3 份容量投影'
env_set "$DEPLOY/.env" CRISPAI_LOG_MAX_FILES 5
find "$DEPLOY/config" -maxdepth 1 -type f -name logging.yaml -delete
invoke initialize --profile new
(( LAST_RC == 0 )) || fail 'new 初始化失败'
jq -e '.max_files==5' "$DEPLOY/config/logging.yaml" >/dev/null || fail '新实例默认份数不是 5'
printf '{"schema_version":999,"private_admin_candidate":"preserve"}\n' > "$DEPLOY/config/logging.yaml"
invalid_hash=$(sha256sum "$DEPLOY/config/logging.yaml" | awk '{print $1}')
invoke initialize --profile new
(( LAST_RC == 1 )) || fail '非法已有 logging.yaml 应拒绝'
[[ "$invalid_hash" == "$(sha256sum "$DEPLOY/config/logging.yaml" | awk '{print $1}')" ]] || fail '非法已有 logging.yaml 被覆盖'
cp -p "$PROJECT_ROOT/config/logging.yaml.example" "$DEPLOY/config/logging.yaml"
pass 'initialize 区分旧3/新5并原样保留非法现有候选'

invoke --json sources
(( LAST_RC == 0 )) || fail 'sources JSON 失败'
jq -e '.schema_version==1 and (.sources|length)==11 and
  ([.sources[].id]|unique|length)==11 and
  all(.sources[]; has("id") and has("name") and has("type") and has("available") and has("mutable") and has("followable"))' "$OUT" >/dev/null || fail 'sources JSON 契约错误'
fixture_env bash "$DEPLOY/manage.sh" --deploy-dir "$DEPLOY" logs --json sources > "$OUT" 2> "$ERR" \
  || fail '生产管理入口 logs --json sources 失败'
jq -e '.schema_version==1 and (.sources|length)==11' "$OUT" >/dev/null \
  || fail '生产 logs JSON 被基础依赖进度污染 stdout'
[[ "$before" == "$(business_hash)" ]] || fail '生产日志来源 CLI 修改了业务资料'
pass '11 个日志来源结构一致，生产管理 CLI 的 JSON 不混入依赖进度'

encoded=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1],safe=""))' "$SECRET")
secret_b64=$(printf '%s' "$SECRET" | base64 | tr -d '\n')
cat > "$WORK/redact-input.txt" <<EOF
Authorization: Bearer unknown-bearer&\$#=value
Authorization: Basic unknown-basic-value
known=$SECRET
encoded=$encoded
base64=$secret_b64
https://user:password@example.test/subscribe/$PATH_SECRET?subscription=unknown-sub-token&ok=yes
line-one
line-two
EOF
python3 "$DEPLOY/scripts/log-redact.py" --env "$DEPLOY/.env" --mode display \
  < "$WORK/redact-input.txt" > "$WORK/redact-output.txt"
for value in "$SECRET" "$encoded" "$secret_b64" "$PATH_SECRET" unknown-sub-token password line-one line-two; do
  ! grep -Fq -- "$value" "$WORK/redact-output.txt" || fail "display 脱敏遗漏敏感变体"
done
grep -Fq '[凭据已脱敏]@example.test' "$WORK/redact-output.txt" || fail 'URL userinfo 未脱敏'
grep -Fq '/subscribe/[已脱敏]' "$WORK/redact-output.txt" || fail 'URL path secret 未脱敏'
cat > "$WORK/pretty.json" <<EOF
{
  "api_key": "$SECRET",
  "authorization": "Bearer unknown-json-token",
  "body": "客户正文",
  "nested": {"website_id": "website-unregistered"}
}
EOF
python3 "$DEPLOY/scripts/log-redact.py" --env "$DEPLOY/.env" --mode export \
  < "$WORK/pretty.json" > "$WORK/pretty-redacted.json"
python3 -c 'import json,sys; json.load(open(sys.argv[1],encoding="utf-8"))' "$WORK/pretty-redacted.json" || fail 'pretty JSON 脱敏后不可解析'
! grep -Eq 'unknown-json-token|客户正文|website-unregistered' "$WORK/pretty-redacted.json" || fail 'pretty JSON 正文/未知秘密泄漏'
pass '脱敏覆盖符号、JSON转义、Base64、URL编码、userinfo/path/query 与 pretty JSON'

invoke event --action 'install&secret' --phase start --code 0
(( LAST_RC == 64 )) || fail 'event 未拒绝非白名单字段'
! grep -Fq "$SECRET" "$OUT" "$ERR" || fail 'event 参数错误泄漏秘密'
invoke event --action install --phase complete --code 0
(( LAST_RC == 0 )) || fail '结构化 event 写入失败'
jq -e 'select(.action=="install" and .phase=="complete" and .code==0) and (keys|sort)==["action","at","code","phase","schema_version","version"]' \
  "$DEPLOY/logs/maintenance.jsonl" >/dev/null || fail 'maintenance 记录包含自由正文或字段错误'
pass '生命周期仅记录固定 action/phase/code，不保存交互正文'

# 大文件采用流式末尾 N 行，不因超过旧 64MiB 阈值静默为空。
python3 - "$DEPLOY/logs/maintenance.jsonl" <<'PY'
import json,sys
with open(sys.argv[1],"a",encoding="utf-8") as out:
    for index in range(12000):
        out.write(json.dumps({"at":"2026-09-07T00:00:00Z","action":"fixture","phase":"line","code":0,"index":index})+"\n")
PY
invoke show maintenance --lines 3
(( LAST_RC == 0 )) || fail 'show maintenance 失败'
[[ "$(wc -l < "$OUT")" == 3 ]] || fail 'show --lines 未限制末尾行数'
grep -Fq '11999' "$OUT" || fail '大日志未读到实际末尾'
pass 'show 对大文件逐行 deque 读取并严格限制末尾行数'

# 已知名称的受管日志也必须是单链接普通文件，不能跟随硬链接读取、轮转或清空。
ln "$DEPLOY/logs/maintenance.jsonl" "$WORK/maintenance-hardlink"
invoke show maintenance --lines 1
(( LAST_RC != 0 )) || fail 'show 跟随了 maintenance 硬链接'
invoke rotate maintenance --apply
(( LAST_RC != 0 )) || fail 'rotate 操作了 maintenance 硬链接'
find "$WORK" -maxdepth 1 -type f -name maintenance-hardlink -delete
pass '查看与轮转拒绝符号/硬链接及特殊文件'

mkdir -p "$DEPLOY/logs/doctor-history" "$DEPLOY/logs/diagnostics"
printf '{}\n' > "$DEPLOY/logs/doctor-history/doctor-20200101.json"
printf 'archive\n' > "$DEPLOY/logs/diagnostics/crispai-diagnostics-20200101.tar.gz"
printf 'do-not-delete\n' > "$DEPLOY/logs/operator-notes.txt"
touch -d '20 days ago' "$DEPLOY/logs/doctor-history/doctor-20200101.json" "$DEPLOY/logs/diagnostics/crispai-diagnostics-20200101.tar.gz" "$DEPLOY/logs/operator-notes.txt"
before_cleanup=$(business_hash)
invoke --json cleanup --days 7 --preview
(( LAST_RC == 0 )) || fail 'cleanup preview 失败'
jq -e '.preview and .expired_files==2' "$OUT" >/dev/null || fail 'cleanup preview 范围错误'
[[ -f "$DEPLOY/logs/doctor-history/doctor-20200101.json" ]] || fail 'preview 执行了删除'
invoke --json cleanup --days 7 --apply
(( LAST_RC == 0 )) || fail 'cleanup apply 失败'
[[ ! -e "$DEPLOY/logs/doctor-history/doctor-20200101.json" && ! -e "$DEPLOY/logs/diagnostics/crispai-diagnostics-20200101.tar.gz" ]] || fail '过期受管历史未删除'
[[ -f "$DEPLOY/logs/operator-notes.txt" ]] || fail '清理越权删除未知文件'
[[ "$before_cleanup" == "$(business_hash)" ]] || fail '清理改变业务/analytics/备份状态'
! grep -Eq 'prune|LogPath|journalctl.*vacuum|rm .*data/' "$CALLS" || fail 'cleanup 调用全局或业务清理'
pass '过期清理预览/应用仅触及受管历史，业务哈希保持'

# rotate 与 cleanup 共用实例级锁；并发操作应串行完成，不破坏 JSONL 或越权清理。
printf '{"at":"2026-09-07T00:00:00Z","action":"fixture","phase":"concurrent","code":0}\n' \
  >> "$DEPLOY/logs/maintenance.jsonl"
printf '{}\n' > "$DEPLOY/logs/doctor-history/doctor-20200103.json"
touch -d '20 days ago' "$DEPLOY/logs/doctor-history/doctor-20200103.json"
fixture_env bash "$DEPLOY/scripts/logs.sh" --deploy-dir "$DEPLOY" rotate maintenance --apply \
  > "$WORK/concurrent-rotate.out" 2> "$WORK/concurrent-rotate.err" & rotate_pid=$!
fixture_env bash "$DEPLOY/scripts/logs.sh" --deploy-dir "$DEPLOY" cleanup --days 7 --apply \
  > "$WORK/concurrent-cleanup.out" 2> "$WORK/concurrent-cleanup.err" & cleanup_pid=$!
rotate_rc=0; cleanup_rc=0
wait "$rotate_pid" || rotate_rc=$?
wait "$cleanup_pid" || cleanup_rc=$?
(( rotate_rc == 0 && cleanup_rc == 0 )) || fail "并发 rotate/cleanup 未串行成功（${rotate_rc}/${cleanup_rc}）"
[[ ! -e "$DEPLOY/logs/doctor-history/doctor-20200103.json" ]] || fail '并发 cleanup 未删除过期受管历史'
python3 - "$DEPLOY/logs/maintenance.jsonl" "$DEPLOY/logs/maintenance.jsonl.1" <<'PY' || fail '并发日志轮转产生损坏 JSONL'
import json, pathlib, sys
for raw_path in sys.argv[1:]:
    path = pathlib.Path(raw_path)
    if not path.exists():
        continue
    for line in path.read_text(encoding="utf-8").splitlines():
        json.loads(line)
PY
pass 'rotate 与 cleanup 并发时由实例锁串行，受管日志保持完整'

invoke clear n8n --apply
(( LAST_RC == 1 )) || fail '容器日志 clear 应拒绝'
! grep -q 'LogPath' "$CALLS" || fail 'clear 读取 Docker LogPath'
invoke clear maintenance --apply
if (( LAST_RC != 0 )) || [[ -s "$DEPLOY/logs/maintenance.jsonl" ]]; then fail 'maintenance 明确清空失败'; fi
! find "$DEPLOY/logs" -maxdepth 1 -name 'maintenance-cleared-*' -print -quit | grep -q . || fail '明确清空产生未受策略管理的副本'
pass '只允许清空可变受管文件，绝不操作 Docker LogPath'

# 与 Docker max-file 对齐：总份数包含当前文件；策略缩小时清理超出编号。
for history in 1 2 3 4 5 6 7; do
  printf '{"history":%s}\n' "$history" > "$DEPLOY/logs/maintenance.jsonl.$history"
  chmod 0600 "$DEPLOY/logs/maintenance.jsonl.$history"
done
printf '{"current":true}\n' > "$DEPLOY/logs/maintenance.jsonl"
invoke rotate maintenance --apply
(( LAST_RC == 0 )) || fail '按总份数轮转 maintenance 失败'
maintenance_copies=$(find "$DEPLOY/logs" -maxdepth 1 -type f -name 'maintenance.jsonl*' | wc -l)
(( maintenance_copies <= 5 )) || fail "max_files=5 后仍有 ${maintenance_copies} 个 maintenance 文件"
[[ ! -e "$DEPLOY/logs/maintenance.jsonl.5" ]] || fail 'maintenance 历史未按含当前总份数裁剪'
pass 'max_files 对 Docker 与 maintenance 均表示包含当前文件的总份数'

invoke timer install
(( LAST_RC == 0 )) || fail 'timer install 失败'
timer_base="crispai-log-maintenance-$(printf '%s' "$DEPLOY" | sha256sum | cut -c1-16)"
[[ -f "$SYSTEMD_DIR/${timer_base}.service" && -f "$SYSTEMD_DIR/${timer_base}.timer" ]] || fail 'timer 单元未创建'
invoke --json timer status
(( LAST_RC == 0 )) || fail 'timer status 失败'
jq -e '.owned and .enabled and .active' "$OUT" >/dev/null || fail 'timer 归属/状态回读失败'
# systemd 明确停止失败且状态仍 active 时，必须保留单元与归属标记。
export LOGS_FIXTURE_STOP_STUCK=1
invoke timer remove
(( LAST_RC == 1 )) || fail 'timer 停止状态未确认时 remove 应失败'
[[ -f "$SYSTEMD_DIR/${timer_base}.service" && -f "$SYSTEMD_DIR/${timer_base}.timer" \
  && -f "$DEPLOY/config/.crispai-log-timer" ]] || fail '停止失败后错误删除 timer 归属资料'
unset LOGS_FIXTURE_STOP_STUCK
# 实际执行一个调度周期的同一生产 cleanup 入口。
printf '{}\n' > "$DEPLOY/logs/doctor-history/doctor-20200102.json"; touch -d '20 days ago' "$DEPLOY/logs/doctor-history/doctor-20200102.json"
invoke --json timer run
if (( LAST_RC != 0 )) || [[ -e "$DEPLOY/logs/doctor-history/doctor-20200102.json" ]]; then fail 'timer run 未完成真实清理周期'; fi
invoke timer remove
(( LAST_RC == 0 )) || fail 'timer remove 失败'
[[ ! -e "$SYSTEMD_DIR/${timer_base}.service" && ! -e "$SYSTEMD_DIR/${timer_base}.timer" ]] || fail 'timer 单元未精确移除'
pass '受管 timer 校验归属，停止失败保留单元，状态确认后精确移除'

# 同名 unit 即使有本项目 marker，也必须属于同一 deploy digest。
printf '# ai-support-log-maintenance/v1\n# deploy-sha256: %064d\n' 0 > "$SYSTEMD_DIR/${timer_base}.service"
printf '# ai-support-log-maintenance/v1\n# deploy-sha256: %064d\n' 0 > "$SYSTEMD_DIR/${timer_base}.timer"
foreign_service_hash=$(sha256sum "$SYSTEMD_DIR/${timer_base}.service" | awk '{print $1}')
invoke timer install
(( LAST_RC == 1 )) || fail 'timer install 覆盖了其他 deploy digest 的同名单元'
[[ "$foreign_service_hash" == "$(sha256sum "$SYSTEMD_DIR/${timer_base}.service" | awk '{print $1}')" ]] \
  || fail 'timer install 修改了其他实例同名单元'
find "$SYSTEMD_DIR" -maxdepth 1 -type f \( -name "${timer_base}.service" -o -name "${timer_base}.timer" \) -delete
pass 'timer install 不覆盖另一实例或错误 digest 的同名单元'

# 配置成功后必须回读；一次受控 up 失败必须恢复原 config/.env。
invoke timer install
export LOGS_FIXTURE_MAX_SIZE=12m LOGS_FIXTURE_MAX_FILES=6 LOGS_FIXTURE_HOURS=216
env_set "$DEPLOY/.env" WEBHOOK_ACCESS_MODE managed_https
invoke --json configure --days 9 --max-size-mib 12 --max-files 6 --apply --timeout 30
(( LAST_RC == 0 )) || fail 'configure 成功路径失败'
grep -Eq 'compose .*--profile managed-https up ' "$CALLS" || fail '受管 HTTPS 的 Caddy 未随日志容量策略重建'
jq -e '.retention_days==9 and .max_size_mib==12 and .max_files==6 and .revision==.applied_revision' "$DEPLOY/config/logging.yaml" >/dev/null || fail 'configure 未原子应用/回读'
successful_config=$(sha256sum "$DEPLOY/config/logging.yaml" | awk '{print $1}')
successful_env=$(sha256sum "$DEPLOY/.env" | awk '{print $1}')
export LOGS_FIXTURE_MAX_SIZE=14m LOGS_FIXTURE_MAX_FILES=7 LOGS_FIXTURE_HOURS=240 LOGS_FIXTURE_UP_FAIL_ONCE=1
find "$WORK" -maxdepth 1 -type f -name up-failed-once -delete
invoke configure --days 10 --max-size-mib 14 --max-files 7 --apply --timeout 30
(( LAST_RC == 1 )) || fail 'configure 故障注入应失败'
[[ "$successful_config" == "$(sha256sum "$DEPLOY/config/logging.yaml" | awk '{print $1}')" ]] || fail 'configure 失败未恢复 logging.yaml'
[[ "$successful_env" == "$(sha256sum "$DEPLOY/.env" | awk '{print $1}')" ]] || fail 'configure 失败未恢复 .env'
[[ "$before" == "$(business_hash)" ]] || fail '策略成功/回滚改变业务状态'
unset LOGS_FIXTURE_UP_FAIL_ONCE
pass '策略保存→重建→回读成功，失败时原子恢复旧配置与运行代'

# 应用期间第一次 INT 进入恢复后，第二次 INT/TERM 不得中断整组恢复。
interrupt_config_hash=$(sha256sum "$DEPLOY/config/logging.yaml" | awk '{print $1}')
interrupt_env_hash=$(sha256sum "$DEPLOY/.env" | awk '{print $1}')
interrupt_count="$WORK/interrupt-up-count"
: > "$interrupt_count"
export LOGS_FIXTURE_UP_SLEEP=2 LOGS_FIXTURE_UP_COUNT_FILE="$interrupt_count"
fixture_env python3 - "$DEPLOY" "$interrupt_count" "$WORK/interrupt.out" "$WORK/interrupt.err" <<'PY'
import os
import pathlib
import signal
import subprocess
import sys
import time

deploy, count_path, out_path, err_path = sys.argv[1:]
with open(out_path, "wb") as out, open(err_path, "wb") as err:
    process = subprocess.Popen([
        "bash", f"{deploy}/scripts/logs.sh", "--deploy-dir", deploy,
        "configure", "--days", "11", "--max-size-mib", "15",
        "--max-files", "8", "--apply", "--timeout", "30",
    ], stdout=out, stderr=err, start_new_session=True)
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        count = pathlib.Path(count_path).read_text(encoding="utf-8").count("up")
        if count >= 1:
            break
        time.sleep(0.05)
    else:
        process.kill()
        raise SystemExit("first compose up was not reached")
    # 模拟终端 Ctrl+C：信号发送给整个前台进程组，而非只发给外层 Bash。
    os.killpg(process.pid, signal.SIGINT)
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        count = pathlib.Path(count_path).read_text(encoding="utf-8").count("up")
        if count >= 2:
            break
        time.sleep(0.05)
    else:
        process.kill()
        raise SystemExit("restore compose up was not reached")
    os.killpg(process.pid, signal.SIGINT)
    try:
        result = process.wait(timeout=8)
    except subprocess.TimeoutExpired:
        process.kill()
        raise SystemExit("interrupted restore did not finish")
    if result != 130:
        raise SystemExit(f"unexpected exit: {result}")
PY
[[ "$interrupt_config_hash" == "$(sha256sum "$DEPLOY/config/logging.yaml" | awk '{print $1}')" ]] \
  || fail '双信号后 logging.yaml 未完整恢复'
[[ "$interrupt_env_hash" == "$(sha256sum "$DEPLOY/.env" | awk '{print $1}')" ]] \
  || fail '双信号后 .env 未完整恢复'
grep -Fq '日志策略应用被中断' "$WORK/interrupt.err" || fail '第一次信号未进入受控中断路径'
[[ "$(grep -c '^up$' "$interrupt_count")" -ge 2 ]] || fail '未执行旧运行代重建'
unset LOGS_FIXTURE_UP_SLEEP LOGS_FIXTURE_UP_COUNT_FILE
pass '应用中断后忽略第二次 INT/TERM，完整恢复配置和受管 HTTPS 容器运行代'

# offline 仍核对 Compose 原文白名单接线，只跳过运行容器回读。
invoke --json audit --no-docker
(( LAST_RC == 0 )) || fail 'offline 日志 audit 误报合法静态配置'
jq -e '.status=="PASS" and .compose.state=="configured" and .compose.validation=="skipped" and
  .runtime.containers.state=="unavailable" and .runtime.n8n.state=="unavailable"' "$OUT" >/dev/null \
  || fail 'offline audit 未区分静态接线与运行时跳过'
! grep -q '^docker ' "$CALLS" || fail 'offline audit 仍访问 Docker'
pass 'offline audit 静态核对日志与n8n隐私接线，运行时读取明确跳过'

export LOGS_FIXTURE_MAX_SIZE=12m LOGS_FIXTURE_MAX_FILES=6 LOGS_FIXTURE_HOURS=216
invoke --json audit
(( LAST_RC == 0 )) || fail '正常 audit 失败'
jq -e '.status=="PASS" and .boundaries.docker_logpath=="never_accessed" and .boundaries.n8n_execution_sql=="never_deleted"' "$OUT" >/dev/null || fail 'audit 结果或边界错误'
! grep -qE 'config --format|LogPath' "$CALLS" || fail 'audit 执行 full compose 展开或 Docker LogPath'
grep -q 'config --quiet' "$CALLS" || fail 'audit 未执行 Compose 无输出校验'
pass 'audit 仅 quiet 校验、静态白名单引用与运行时精确字段对账'

# 受管 Caddy 必须过滤运行时 error logger 的完整 URI；仅关闭 access log 不够。
grep -Fq 'request>uri replace [REDACTED]' "$PROJECT_ROOT/config/Caddyfile.example" \
  || fail '受管 Caddy 缺少运行时 URI 脱敏过滤'
grep -Fq 'request>headers>Authorization delete' "$PROJECT_ROOT/config/Caddyfile.example" \
  || fail '受管 Caddy 缺少认证头过滤'
pass '受管 Caddy 模板对运行时错误 URI 与认证头设置字段级过滤'

archive="$WORK/diagnostic.tar.gz"
invoke export --output "$archive"
if (( LAST_RC != 0 )) || [[ ! -f "$archive" ]]; then fail 'export 失败'; fi
mkdir "$WORK/extracted"; tar -C "$WORK/extracted" -xzf "$archive"
find "$WORK/extracted" -type f -exec chmod 0600 {} +
for value in "$SECRET" "$HEADER_SECRET" "$BASIC_SECRET" "$PATH_SECRET"; do
  ! grep -R -Fq -- "$value" "$WORK/extracted" || fail '诊断包泄漏真实秘密或 URL secret'
done
! find "$WORK/extracted" -type f \( -name .env -o -path '*/runtime/*' -o -path '*/analytics/*' -o -path '*/knowledge/*' \) -print -quit | grep -q . \
  || fail '诊断包包含被禁止的业务/秘密文件'
jq -e '.contains_secrets==false and .contains_prompt_or_knowledge==false and .contains_customer_transcript==false' "$WORK/extracted/manifest.json" >/dev/null || fail '诊断包 manifest 边界缺失'
pass '诊断包仅含脱敏白名单资料，二次秘密扫描通过'

invoke configure --max-files 21 --preview
(( LAST_RC == 64 )) || fail 'max_files 21 应拒绝'
invoke configure --max-files 20 --preview
(( LAST_RC == 0 )) || fail 'max_files 20 应允许'
pass 'max_files 管理边界与菜单统一为 1..20'

printf '日志专项：%s 通过，0 失败。\n' "$PASSED"
