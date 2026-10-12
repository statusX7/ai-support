#!/usr/bin/env bash
set -euo pipefail

# 单独构造生产脚本读的部署资料；Docker/外部API仍是严格fixture，不冒称实机。
export CRISPAI_DOCTOR_FIXTURE_SETUP_ONLY=1
# shellcheck source=tests/test_doctor.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/test_doctor.sh"
unset CRISPAI_DOCTOR_FIXTURE_SETUP_ONLY
for name in provider-router.js provider-envelope.js provider-pool.py menu-display.py menu-provider-ui.sh; do
  cp -p -- "${PROJECT_ROOT}/scripts/$name" "${DEPLOY}/scripts/$name"
done
# 真实旧版 .env 尚无新内部认证；让生产迁移生成，而不是使用模板占位符。
env_unset "${DEPLOY}/.env" PROVIDER_ADAPTER_KEY
python3 "${DEPLOY}/scripts/provider-pool.py" --deploy-dir "$DEPLOY" migrate >/dev/null
python3 - "$DEPLOY" <<'PY'
import copy, json, pathlib, sys
root=pathlib.Path(sys.argv[1]); pool_path=root/'config/provider-pool-applied.json'
pool=json.loads(pool_path.read_text()); secret_path=root/'secrets/provider/generations'/ (pool['secrets_generation']+'.json')
secrets=json.loads(secret_path.read_text())
for index in (1,2):
    entry=copy.deepcopy(pool['entries'][0]); entry.update(id='p_'+str(index)*24, role='backup', order=index, name='合成备用'+str(index), enabled=index==1)
    if index == 1:
        entry.update(context_window=16384, max_output_tokens=4096)
    else:
        entry.update(context_window=1456, max_output_tokens=1200, draft=True)
    pool['entries'].append(entry); secrets['entries'][entry['id']]={'api_key':'doctor-synthetic-backup-'+str(index),'custom_headers':{}}
pool_path.write_text(json.dumps(pool)); secret_path.write_text(json.dumps(secrets))
source=copy.deepcopy(pool); source.pop('secrets_generation'); (root/'config/provider-pool.yaml').write_text(json.dumps(source))
PY
cp -- "${PROJECT_ROOT}/VERSION" "${DEPLOY}/VERSION"
sed -i "s/^installed_version=.*/installed_version=$(<"${DEPLOY}/VERSION")/" "${DEPLOY}/.crisp-ai-installation"
node "${DEPLOY}/n8n/build-workflow.js"
jq '.active=true' "${DEPLOY}/n8n/workflow.json" > "${DEPLOY}/n8n/workflow.json.new"
mv -- "${DEPLOY}/n8n/workflow.json.new" "${DEPLOY}/n8n/workflow.json"

internal=$(env_get "${DEPLOY}/.env" PROVIDER_ADAPTER_KEY)
jq --arg key "$internal" '{
  "provider-adapter":[$key,"true","true","host.docker.internal"],
  anythingllm:["http://provider-adapter:8787/v1",$key],
  n8n:(.n8n[0:10]+["http://provider-adapter:8787/v1",$key,"true","true"])
}' "$RUNTIME_ENV_FILE" > "${RUNTIME_ENV_FILE}.new"
mv -- "${RUNTIME_ENV_FILE}.new" "$RUNTIME_ENV_FILE"
write_readback() {
  local sha
  sha=$(sha256sum "${DEPLOY}/config/provider-pool-applied.json" | awk '{print $1}')
  jq --arg sha "$sha" '{schema_version:1,readback_contract_version:1,revision,
    secrets_generation,pool_sha256:$sha,verified_at:1}' \
    "${DEPLOY}/config/provider-pool-applied.json" > "${DEPLOY}/config/provider-pool-readback.json"
  chmod 0640 "${DEPLOY}/config/provider-pool-readback.json"
  chown 0:1000 "${DEPLOY}/config/provider-pool-readback.json" 2>/dev/null || true
}
write_health() {
  local sha
  sha=$(sha256sum "${DEPLOY}/config/provider-pool-applied.json" | awk '{print $1}')
  jq --arg state "$1" --arg sha "$sha" \
    '{ok:true,readback_contract_version:1,configuration_state:"applied",revision,
      secrets_generation,pool_sha256:$sha,
      entries:[.entries[]|{id,enabled,health:(if .enabled then $state else "disabled" end)}]}' \
    "${DEPLOY}/config/provider-pool-applied.json" > "${DEPLOY}/tmp/fixture-pool-status.json"
}
pool_result_status() {
  local identifier=$1 value
  value=$(jq -M -r --arg id "$identifier" \
    '[.results[] | select(.id == $id)][-1].status // "MISSING"' "$OUT" 2>/dev/null || true)
  case "$value" in
    PASS|WARN|FAIL|SKIP|MISSING) printf '%s' "$value" ;;
    *) printf 'INVALID' ;;
  esac
}
pool_baseline_failure_snapshot() {
  local report_state=empty summary_fail=INVALID summary_warn=INVALID value
  local configured_budget=${pool_rag_context:-INVALID}
  local fixture_budget=${DOCTOR_FIXTURE_RAG_CONTEXT:-INVALID}
  local api_budget=${DOCTOR_FIXTURE_RAG_API_CONTEXT:-INVALID}
  local env_probe_count api_probe_count
  if [[ -s "$OUT" ]]; then
    if jq -e 'type == "object" and (.results | type == "array") and (.summary | type == "object")' \
        "$OUT" >/dev/null 2>&1; then
      report_state=valid
      value=$(jq -M -r '.summary.fail' "$OUT" 2>/dev/null || true)
      [[ "$value" =~ ^[0-9]+$ ]] && summary_fail=$value
      value=$(jq -M -r '.summary.warn' "$OUT" 2>/dev/null || true)
      [[ "$value" =~ ^[0-9]+$ ]] && summary_warn=$value
    else
      report_state=invalid
    fi
  fi
  [[ "$configured_budget" =~ ^[0-9]+$ ]] || configured_budget=INVALID
  [[ "$fixture_budget" =~ ^[0-9]+$ ]] || fixture_budget=INVALID
  [[ "$api_budget" =~ ^[0-9]+$ ]] || api_budget=INVALID
  env_probe_count=$(grep -Fc 'CRISPAI_EXPECTED_RAG_CONTEXT' "$FIXTURE_LOG" || true)
  api_probe_count=$(grep -Ec '^curl http://127\.0\.0\.1:[0-9]+/api/v1/system$' "$FIXTURE_LOG" || true)
  printf 'rc=%s;report=%s;summary.fail=%s;summary.warn=%s;provider.configuration=%s;provider.rag_configuration=%s;anything.rag_context=%s;provider.pool_health=%s;configured_budget=%s;fixture_budget=%s;api_budget=%s;env_probe=%s;api_probe=%s' \
    "$LAST_RC" "$report_state" "$summary_fail" "$summary_warn" \
    "$(pool_result_status provider.configuration)" "$(pool_result_status provider.rag_configuration)" \
    "$(pool_result_status anything.rag_context)" "$(pool_result_status provider.pool_health)" \
    "$configured_budget" "$fixture_budget" "$api_budget" "$env_probe_count" "$api_probe_count"
}
write_readback
write_health unknown
pool_rag_context=$(env_get "${DEPLOY}/.env" PROVIDER_RAG_CONTEXT_WINDOW 2>/dev/null || true)
[[ "$pool_rag_context" == 6992 ]] \
  || fail '主备迁移夹具没有生成扣除候选输出额度后的共同输入预算 6992'
export DOCTOR_FIXTURE_RAG_CONTEXT="$pool_rag_context"
export DOCTOR_FIXTURE_RAG_API_CONTEXT="$pool_rag_context"
if [[ "${CRISPAI_DOCTOR_VISION_ASSET_ONLY:-0}" == 1 ]]; then
  invoke --offline; assert_result installation.files PASS
  mv -- "$DEPLOY/config/vision-probe.json" "$TEST_ROOT/vision-probe.saved"
  invoke --offline; assert_result installation.files FAIL
  pass '当前版缺少实际视觉探测资源时明确安装不完整，不允许用连接通过代替'
  printf 'v1.3.0\n' > "$DEPLOY/VERSION"
  invoke --offline; assert_result installation.files PASS
  mv -- "$TEST_ROOT/vision-probe.saved" "$DEPLOY/config/vision-probe.json"
  cp -- "$PROJECT_ROOT/VERSION" "$DEPLOY/VERSION"
  pass '旧版未提供新视觉资源不被跨版本自检误判缺失；原文件恢复'
  exit 0
fi
before=$(business_hash)
invoke --local
if (( LAST_RC != 2 )); then
  fail "单主未检测应警告，不假绿、不认定接口故障；安全诊断：$(pool_baseline_failure_snapshot)"
fi
for id in provider.configuration provider.pending provider.rag_transaction provider.readback provider.rag_configuration provider.secret_permissions provider.adapter provider.visitor_output_code_binding provider.router_code_binding provider.envelope_code_binding anything.provider_binding anything.rag_context n8n.runtime_binding runtime.feedback runtime.provider_receipts runtime.provider_settlements runtime.provider_retirements; do assert_result "$id" PASS; done
assert_result provider.pool_health WARN
assert_result provider.prompt_capacity PASS
[[ "$before" == "$(business_hash)" ]] || fail '主备默认doctor改动业务资料或会话'
! grep -Eq 'provider\.example\.test|/workspace/.*/chat' "$FIXTURE_LOG" || fail '主备默认doctor执行付费推理'
pass '新主备接线、秘密代次、版本模块、评价停用和默认只读完整检查'

write_health healthy
invoke --local
(( LAST_RC == 0 )) || fail '当前健康证据及全部本地组件正常应退出0'
assert_result provider.pool_health PASS
pass '当前代主接口真实成功证据与未检测状态区分'

# The native Docker/TTY failure is reproduced on TARGET-A separately; this
# fixture covers the production doctor's stdin contract without Docker.
fixture_env python3 - "$PROJECT_ROOT" "$DEPLOY" <<'PY'
import errno
import json
import os
import pty
import select
import signal
import sys
import time

source, deploy = sys.argv[1:]
pid, descriptor = pty.fork()
if pid == 0:
    os.environ['DOCTOR_FIXTURE_CAPACITY_REQUIRE_NON_TTY'] = '1'
    os.execv('/bin/bash', ['bash', source + '/scripts/doctor.sh', '--deploy-dir', deploy, '--local', '--json'])
raw = bytearray()
deadline = time.monotonic() + 45
status = None
while status is None:
    ready, _, _ = select.select([descriptor], [], [], .1)
    if ready:
        try:
            raw.extend(os.read(descriptor, 65536))
        except OSError as error:
            if error.errno != errno.EIO:
                raise
    found, value = os.waitpid(pid, os.WNOHANG)
    if found:
        status = value
    elif time.monotonic() > deadline:
        os.killpg(pid, signal.SIGKILL)
        os.waitpid(pid, 0)
        raise AssertionError('终端自检超时')
os.close(descriptor)
assert os.waitstatus_to_exitcode(status) == 0, '终端自检未正常完成'
report = json.loads(raw.decode())
rows = [row for row in report['results'] if row['id'] == 'provider.prompt_capacity']
assert len(rows) == 1 and rows[0]['status'] == 'PASS', '容量探针继承终端输入或未通过'
PY
pass '真实PTY下的只读容量探针关闭stdin，终端自检不误报故障'

# Minimal capacity regression reuses the existing complete doctor fixture.
cp -p -- "${DEPLOY}/config/materials-applied.json" "${TEST_ROOT}/capacity-materials.saved"
cp -p -- "${DEPLOY}/config/prompt.md" "${TEST_ROOT}/capacity-prompt.saved"
cp -p -- "$WORKSPACE_PROMPT_FILE" "${TEST_ROOT}/capacity-workspace.saved"
capacity_prompt_fixture() {
  python3 - "$DEPLOY" "$WORKSPACE_PROMPT_FILE" "$1" <<'PY'
import hashlib, json, pathlib, sys
root=pathlib.Path(sys.argv[1]); path=root/'config/materials-applied.json'
value=json.loads(path.read_text()); text='合成资料' * int(sys.argv[3])
value['prompt'].update(text=text,bytes=len(text.encode()),sha256=hashlib.sha256(text.encode()).hexdigest())
path.write_text(json.dumps(value)); (root/'config/prompt.md').write_text(text)
pathlib.Path(sys.argv[2]).write_text(text)
PY
  reseal_materials_fixture
}
capacity_prompt_fixture 1500
before=$(business_hash)
invoke --local
assert_result provider.pool_health PASS
assert_result provider.prompt_capacity FAIL
(( LAST_RC == 1 )) || fail '短请求健康不能掩盖完整提示词已超过所有候选窗口'
# The existing 1.1 multiplier rounds 12000 * 1.1 upward to 13201 in JS.
# Include the Router 272 overhead and primary 1200 output reservation.
jq -e '.results[] | select(.id=="provider.prompt_capacity") | .summary | contains("14673")' "$OUT" >/dev/null \
  || fail '容量诊断未使用 Router 中文估算及各自输出预留'
[[ "$before" == "$(business_hash)" ]] || fail '容量诊断修改了业务配置或会话'
! grep -Eq 'provider\.example\.test|/workspace/.*/chat' "$FIXTURE_LOG" || fail '容量诊断执行了模型请求'
pass '全池短请求健康但完整提示词超限时明确故障，诊断只读且不推理'
capacity_prompt_fixture 1100
invoke --local
assert_result provider.prompt_capacity WARN
(( LAST_RC == 2 )) || fail '主窗口不足但备用可容纳必须警告，不得误报全池不可用'
pass '候选容量分别核对，保留大窗口备用的可用性'
cp -p -- "${TEST_ROOT}/capacity-materials.saved" "${DEPLOY}/config/materials-applied.json"
cp -p -- "${TEST_ROOT}/capacity-prompt.saved" "${DEPLOY}/config/prompt.md"
cp -p -- "${TEST_ROOT}/capacity-workspace.saved" "$WORKSPACE_PROMPT_FILE"
jq '.prompt.sha256=("0"*64)' "${TEST_ROOT}/capacity-materials.saved" > "${DEPLOY}/config/materials-applied.json"
invoke --local
assert_result provider.prompt_capacity FAIL
(( LAST_RC == 1 )) || fail '无效提示词摘要不能标记容量通过'
cp -p -- "${TEST_ROOT}/capacity-materials.saved" "${DEPLOY}/config/materials-applied.json"
pass '资料摘要无效时不使用未经核验的提示词宣称可用'
invoke --offline
assert_result provider.prompt_capacity SKIP
pass '离线检查不冒充运行容器容量核验'
if [[ "${CRISPAI_DOCTOR_CAPACITY_ONLY:-0}" == 1 ]]; then
  printf '容量定向检查结束；未执行其后的其它主备自检场景。\n'
  exit 0
fi

env_set "${DEPLOY}/.env" PROVIDER_RAG_CONTEXT_WINDOW 8192
invoke --local
assert_result provider.rag_configuration FAIL
assert_result anything.rag_context SKIP
(( LAST_RC == 1 )) || fail '池与知识预算投影不一致必须失败'
env_set "${DEPLOY}/.env" PROVIDER_RAG_CONTEXT_WINDOW 6992
pass '裸最小窗口不能冒充扣除候选输出后的共同输入估算上限'

cp -p -- "${DEPLOY}/config/provider-pool-applied.json" "${TEST_ROOT}/provider-pool-budget.saved"
jq '.entries[1].context_window=4351 | .entries[1].max_output_tokens=4096' \
  "${TEST_ROOT}/provider-pool-budget.saved" > "${DEPLOY}/config/provider-pool-applied.json"
write_readback
write_health healthy
invoke --local
assert_result provider.rag_configuration FAIL
assert_result anything.rag_context SKIP
(( LAST_RC == 1 )) || fail '共同输入估算小于256必须失败关闭'
mv -- "${TEST_ROOT}/provider-pool-budget.saved" "${DEPLOY}/config/provider-pool-applied.json"
write_readback
write_health healthy
pass '异构候选输出预留及共同输入估算下界由doctor独立校验'

DOCTOR_FIXTURE_RAG_CONTEXT=4096 invoke --local
assert_result provider.rag_configuration PASS
assert_result anything.rag_context FAIL
(( LAST_RC == 1 )) || fail 'AnythingLLM仍运行旧预算必须失败'
pass '容器实际上下文预算漂移可定位'

DOCTOR_FIXTURE_RAG_API_CONTEXT=4096 invoke --local
assert_result anything.rag_context FAIL
(( LAST_RC == 1 )) || fail 'API实际知识预算漂移必须失败'
pass '环境正确但API实际预算不同仍然拒绝通过'

DOCTOR_FIXTURE_ANYTHING_AUTH_FAIL=1 invoke --local
assert_result anything.rag_context FAIL
(( LAST_RC == 1 )) || fail '鉴权失败不能凭环境值宣称RAG正常'
pass '知识预算检查必须取得当前鉴权API证据'

printf '%s\n' '{"schema_version":1,"phase":"restore_failed"}' > "${DEPLOY}/config/provider-pool-transaction.json"
jq '.configuration_state="applying"' "${DEPLOY}/tmp/fixture-pool-status.json" > "${TEST_ROOT}/health.new"
mv -- "${TEST_ROOT}/health.new" "${DEPLOY}/tmp/fixture-pool-status.json"
before=$(business_hash)
invoke --local
assert_result provider.rag_transaction FAIL
assert_result provider.adapter FAIL
assert_result provider.pool_health SKIP
[[ "$before" == "$(business_hash)" ]] || fail '自检不能删除事务标记或解除人工'
rm -- "${DEPLOY}/config/provider-pool-transaction.json"
write_health healthy
pass '未完成配置事务明确失败且默认自检不解除保护'
invoke --local
(( LAST_RC == 0 )) || fail '恢复原合成状态后的本次检查应正常，不能沿用旧缓存'

text_status=0
fixture_env "$DOCTOR" --deploy-dir "$DEPLOY" --last > "${TEST_ROOT}/text-last.out" 2> "${TEST_ROOT}/text-last.err" || text_status=$?
(( text_status == 0 )) || fail '普通中文自检缓存显示失败'
grep -Fq '[通过]' "${TEST_ROOT}/text-last.out" || fail '普通自检没有中文结果'
grep -Fq '缓存' "${TEST_ROOT}/text-last.out" || fail '缓存自检未标注来源'
! grep -Eq 'schema_version|revision|jq: error|compile error' "${TEST_ROOT}/text-last.out" "${TEST_ROOT}/text-last.err" || fail '普通自检暴露内部结构或展示解析错误'
pass '普通自检中文渲染真实执行，JSON读取与缓存范围均保持'

jq '.entries[0].vision_health="cooling" | .entries[1].vision_health="healthy"' \
  "${DEPLOY}/tmp/fixture-pool-status.json" > "${TEST_ROOT}/health.new"
mv -- "${TEST_ROOT}/health.new" "${DEPLOY}/tmp/fixture-pool-status.json"
before=$(business_hash)
invoke --local
assert_result provider.pool_health PASS
assert_result provider.pool_vision WARN
(( LAST_RC == 2 )) || fail '图片能力退化必须警告，文字健康不能掩盖'
[[ "$before" == "$(business_hash)" ]] || fail '图片能力自检偷偷改变配置或会话'
write_health healthy
pass '图片专属冷却单列警告，默认只读且不误判文本故障'

jq '.entries[0].health="cooling"' \
  "${DEPLOY}/tmp/fixture-pool-status.json" > "${TEST_ROOT}/health.new"
mv -- "${TEST_ROOT}/health.new" "${DEPLOY}/tmp/fixture-pool-status.json"
invoke --local
assert_result provider.pool_health WARN
(( LAST_RC == 2 )) || fail '主故障且备用正常应降级警告'
pass '主故障备用可用为降级，停用备用不误报故障'
write_health cooling
invoke --local
assert_result provider.pool_health FAIL
(( LAST_RC == 1 )) || fail '全部启用接口冷却必须报告故障'
pass '全池故障不以adapter容器healthy冒充推理正常'

write_health healthy
jq '.revision+=1' "${DEPLOY}/tmp/fixture-pool-status.json" > "${TEST_ROOT}/health.new"
mv -- "${TEST_ROOT}/health.new" "${DEPLOY}/tmp/fixture-pool-status.json"
invoke --local
assert_result provider.adapter FAIL
assert_result provider.pool_health SKIP
write_health healthy
pass '运行时配置代偏离拒绝旧健康事实'

cp -p -- "${DEPLOY}/config/provider-pool-readback.json" "${TEST_ROOT}/pool-readback.saved"
rm -- "${DEPLOY}/config/provider-pool-readback.json"
invoke --local
assert_result provider.readback FAIL
assert_result provider.adapter PASS
(( LAST_RC == 1 )) || fail '缺少运行回读时 runtime 会停止推理，doctor 必须失败'
cp -p -- "${TEST_ROOT}/pool-readback.saved" "${DEPLOY}/config/provider-pool-readback.json"
pass '回读文件缺失与 adapter 当前身份分层报告，不用容器健康假绿'

jq '.pool_sha256=("f"*64)' "${TEST_ROOT}/pool-readback.saved" \
  > "${DEPLOY}/config/provider-pool-readback.json"
invoke --local
assert_result provider.readback FAIL
(( LAST_RC == 1 )) || fail '伪造或旧代回读摘要必须失败'
cp -p -- "${TEST_ROOT}/pool-readback.saved" "${DEPLOY}/config/provider-pool-readback.json"
pass '回读精确绑定当前原始池摘要、revision 和秘密代次'

cp -p -- "${DEPLOY}/tmp/fixture-pool-status.json" "${TEST_ROOT}/pool-status.saved"
jq 'del(.secrets_generation)' "${TEST_ROOT}/pool-status.saved" \
  > "${DEPLOY}/tmp/fixture-pool-status.json"
invoke --local
assert_result provider.readback PASS
assert_result provider.adapter FAIL
assert_result provider.pool_health SKIP
(( LAST_RC == 1 )) || fail 'adapter 缺失完整运行身份不得只比对 revision'
cp -p -- "${TEST_ROOT}/pool-status.saved" "${DEPLOY}/tmp/fixture-pool-status.json"
pass 'adapter 运行身份必须回读秘密代次和原始池摘要'

cp -p -- "${DEPLOY}/config/provider-pool.yaml" "${TEST_ROOT}/pool.saved"
jq '.entries[0].name="尚未应用的名称"' "${TEST_ROOT}/pool.saved" > "${DEPLOY}/config/provider-pool.yaml"
invoke --local
assert_result provider.pending WARN
assert_result provider.configuration PASS
cp -p -- "${TEST_ROOT}/pool.saved" "${DEPLOY}/config/provider-pool.yaml"
pass '直接编辑池仅显示待应用，当前正常出口不受损'

secret_file="${DEPLOY}/secrets/provider/generations/$(jq -r .secrets_generation "${DEPLOY}/config/provider-pool-applied.json").json"
chmod 0644 "$secret_file"
invoke --local
assert_result provider.secret_permissions FAIL
[[ $(stat -c '%a' "$secret_file") == 644 ]] || fail '默认doctor偷偷修复权限'
chmod 0640 "$secret_file"
pass '秘密权限异常准确检测、默认不擅自修改'

SESSION_FILE=$(find "${DEPLOY}/data/runtime" -maxdepth 1 -type f -name 'session-*.json' -print -quit)
cp -p -- "$SESSION_FILE" "${TEST_ROOT}/session.saved"
jq '.pending_feedback={answer_id:"synthetic-old-feedback"}' "${TEST_ROOT}/session.saved" > "$SESSION_FILE"
before=$(business_hash)
invoke --local
assert_result runtime.feedback WARN
[[ "$before" == "$(business_hash)" ]] || fail '只读doctor退役了旧任务或修改人工状态'
cp -p -- "${TEST_ROOT}/session.saved" "$SESSION_FILE"
pass '旧评价残留只读报告，不清人工状态和普通任务'

RESPONSIBILITY_NOW=$(date -u '+%s%3N')
RESPONSIBILITY_OLD=$((RESPONSIBILITY_NOW - 600001))
RESPONSIBILITY_RECENT=$((RESPONSIBILITY_NOW - 240000))
RESPONSIBILITY_EXPIRED=$((RESPONSIBILITY_NOW - 1000))
RESPONSIBILITY_ACTIVE=$((RESPONSIBILITY_NOW + 300000))
RESPONSIBILITY_RUNTIME_REVISION=$(jq -r '.configuration.runtime.revision' \
  "${DEPLOY}/config/materials-applied.json")
RESPONSIBILITY_CONTENT='CASE-M02合成正文不得出现在诊断结果'
RESPONSIBILITY_JOB_ID=$(printf '9%.0s' {1..64})

answer_status() {
  jq -r '[.results[] | select(.id == "runtime.answer_responsibilities")][-1].status // "MISSING"' "$OUT"
}

assert_answer_counts() {
  local expected_status=$1 stalled=$2 pending=$3 silence=$4 invalid_artifacts=${5:-0} unknown=${6:-0}
  local actual_status=MISSING actual_counts actual_unresolved=INVALID actual_invalid=INVALID
  local actual_stalled=INVALID actual_pending=INVALID actual_unknown=INVALID actual_silence=INVALID
  if ! jq -e --arg status "$expected_status" --arg stalled "$stalled" --arg pending "$pending" \
    --arg silence "$silence" --arg invalid_artifacts "$invalid_artifacts" --arg unknown "$unknown" '
      [.results[] | select(.id == "runtime.answer_responsibilities")][-1] as $item |
      $item.status == $status and
      ($item.summary | contains("责任产物损坏 \($invalid_artifacts)")) and
      ($item.summary | contains("长期处理无产物 \($stalled)")) and
      ($item.summary | contains("待处理/处理中 \($pending)")) and
      ($item.summary | contains("未知发送 \($unknown)")) and
      ($item.summary | contains("明确政策静默 \($silence)"))
    ' "$OUT" >/dev/null; then
    actual_status=$(jq -M -r \
      '[.results[] | select(.id == "runtime.answer_responsibilities")][-1].status // "MISSING"' \
      "$OUT" 2>/dev/null || true)
    case "$actual_status" in PASS|WARN|FAIL|SKIP|MISSING) ;; *) actual_status=INVALID ;; esac
    actual_counts=$(jq -M -r '
      def count_after($label):
        try capture($label + " (?<value>[0-9]+)").value catch "INVALID";
      [.results[] | select(.id == "runtime.answer_responsibilities")][-1] as $item |
      $item.summary as $summary |
      [(if ($summary | type) == "string" and ($summary | test("未完成故障 [0-9]+"))
        then ($summary | count_after("未完成故障"))
        elif $item.status == "WARN" or $item.status == "PASS" then "0"
        else "INVALID" end),
       ($summary | count_after("责任产物损坏")),
       ($summary | count_after("长期处理无产物")),
       ($summary | count_after("待处理/处理中")),
       ($summary | count_after("未知发送")),
       ($summary | count_after("明确政策静默"))] | @tsv
    ' "$OUT" 2>/dev/null || printf 'INVALID\tINVALID\tINVALID\tINVALID\tINVALID\tINVALID')
    IFS=$'\t' read -r actual_unresolved actual_invalid actual_stalled actual_pending actual_unknown actual_silence \
      <<< "$actual_counts"
    fail "应答责任 JSON 未按脱敏计数报告长期无产物状态；安全诊断：status=${actual_status};unresolved=${actual_unresolved};invalid=${actual_invalid};stalled=${actual_stalled};pending=${actual_pending};unknown=${actual_unknown};silence=${actual_silence}"
  fi
  jq -e --arg content "$RESPONSIBILITY_CONTENT" --arg job "$RESPONSIBILITY_JOB_ID" '
      [.results[] | select(.id == "runtime.answer_responsibilities")][-1] as $item |
      ($item | tostring) as $serialized |
      (($serialized | contains($content)) or ($serialized | contains($job)) or
        ($serialized | contains("session_doctor_fixture"))) | not
    ' "$OUT" >/dev/null || fail '应答责任 JSON 摘要泄漏了正文、任务或会话身份'
  ! grep -Fq "$RESPONSIBILITY_CONTENT" "$ERR" \
    || fail '应答责任 JSON stderr 泄漏合成正文'
  ! grep -Fq "$RESPONSIBILITY_JOB_ID" "$ERR" \
    || fail '应答责任 JSON stderr 泄漏任务身份'
  ! grep -Fq 'session_doctor_fixture' "$ERR" \
    || fail '应答责任 JSON stderr 泄漏会话身份'
}

assert_answer_text() {
  local label=$1 expected_rc=$2 stalled=$3 pending=$4 silence=$5 suffix=$6
  local text_out="${TEST_ROOT}/answer-${suffix}.out" text_err="${TEST_ROOT}/answer-${suffix}.err" text_rc=0
  fixture_env "$DOCTOR" --deploy-dir "$DEPLOY" --local > "$text_out" 2> "$text_err" || text_rc=$?
  (( text_rc == expected_rc )) || fail "应答责任中文状态退出码错误：${suffix}"
  grep -Fq "[${label}] 应答责任：" "$text_out" || fail "应答责任中文状态标签错误：${suffix}"
  grep -Fq '责任产物损坏 0' "$text_out" || fail "中文摘要含意外责任产物损坏计数：${suffix}"
  grep -Fq "长期处理无产物 ${stalled}" "$text_out" || fail "中文摘要缺少长期无产物脱敏计数：${suffix}"
  grep -Fq "待处理/处理中 ${pending}" "$text_out" || fail "中文摘要缺少待处理脱敏计数：${suffix}"
  grep -Fq '未知发送 0' "$text_out" || fail "中文摘要缺少未知发送脱敏计数：${suffix}"
  grep -Fq "明确政策静默 ${silence}" "$text_out" || fail "中文摘要缺少政策静默脱敏计数：${suffix}"
  ! grep -Fq "$RESPONSIBILITY_CONTENT" "$text_out" "$text_err" \
    || fail '应答责任中文输出泄漏合成正文'
  ! grep -Fq "$RESPONSIBILITY_JOB_ID" "$text_out" "$text_err" \
    || fail '应答责任中文输出泄漏任务身份'
  ! grep -Fq 'session_doctor_fixture' "$text_out" "$text_err" \
    || fail '应答责任中文输出泄漏会话身份'
}

jq --argjson old "$RESPONSIBILITY_OLD" --argjson revision "$RESPONSIBILITY_RUNTIME_REVISION" \
  --arg content "$RESPONSIBILITY_CONTENT" --arg job "$RESPONSIBILITY_JOB_ID" '
    .mode="ai" | .resume_at=null | .pause_reason="" | .last_human_at=0 |
    .human_event_id="" | .control_watermark=0 | .worker=null |
    .outgoing={} | .jobs=[{id:$job,event:"message:send",status:"received",control:false,
      revision:$revision,generation:.generation,response_generation:0,sequence:4,
      received_at:$old,event_time:$old,attempts:1,lease_until:0,
      responsibility_status:"pending",
      data:{session_id:.session_id,from:"user",type:"text",content:$content,fingerprint:90001}}]
  ' "${TEST_ROOT}/session.saved" > "$SESSION_FILE"
before=$(business_hash)
invoke --local
received_status=$(answer_status)
if [[ "$received_status" != FAIL ]]; then
  [[ "$received_status" == WARN ]] \
    || fail "长期 received 无产物责任状态异常：${received_status}"
  fail '预期红：超过十分钟且已处理一次的 received 无产物责任当前仍仅 WARN'
fi
(( LAST_RC == 1 )) || fail '长期 received 无产物责任必须使本地自检退出 1'
assert_answer_counts FAIL 1 1 0
assert_answer_text '故障' 1 1 1 0 received
[[ "$before" == "$(business_hash)" ]] || fail '只读doctor改写了长期 received 原问题责任'
pass '长期 received 且无计划、推理或出站时应答责任明确失败'

jq --argjson old "$RESPONSIBILITY_OLD" --argjson revision "$RESPONSIBILITY_RUNTIME_REVISION" \
  --arg content "$RESPONSIBILITY_CONTENT" --arg job "$RESPONSIBILITY_JOB_ID" '
    .mode="ai" | .resume_at=null | .pause_reason="" | .last_human_at=0 |
    .human_event_id="" | .control_watermark=0 | .worker=null | .outgoing={} |
    .jobs=[{id:$job,event:"message:send",status:"received",control:false,
      revision:$revision,generation:.generation,response_generation:0,sequence:4,
      received_at:$old,event_time:$old,attempts:1,lease_until:0,
      responsibility_status:"pending",plan:null,inference:null,
      provider_result_receipt:null,provider_settlement:null,provider_retirement:null,
      provider_migration_from:null,legacy_v121_pending_origin:null,
      data:{session_id:.session_id,from:"user",type:"text",content:$content,fingerprint:90004}}]
  ' "${TEST_ROOT}/session.saved" > "$SESSION_FILE"
before=$(business_hash)
invoke --local
assert_result runtime.answer_responsibilities FAIL
(( LAST_RC == 1 )) || fail '显式null产物仍应按长期无产物责任失败'
assert_answer_counts FAIL 1 1 0 0
[[ "$before" == "$(business_hash)" ]] || fail '只读doctor改写了显式null长期责任'
pass '显式null不能冒充有效责任产物'

jq --argjson recent "$RESPONSIBILITY_RECENT" --argjson revision "$RESPONSIBILITY_RUNTIME_REVISION" \
  --arg content "$RESPONSIBILITY_CONTENT" --arg job "$RESPONSIBILITY_JOB_ID" '
    .mode="ai" | .resume_at=null | .pause_reason="" | .last_human_at=0 |
    .human_event_id="" | .control_watermark=0 | .worker=null | .outgoing={} |
    .jobs=[{id:$job,event:"message:send",status:"received",control:false,
      revision:$revision,generation:.generation,response_generation:0,sequence:4,
      received_at:$recent,event_time:$recent,attempts:1,lease_until:0,
      responsibility_status:"pending",
      data:{session_id:.session_id,from:"user",type:"text",content:$content,fingerprint:90005}}]
  ' "${TEST_ROOT}/session.saved" > "$SESSION_FILE"
before=$(business_hash)
invoke --local
assert_result runtime.answer_responsibilities WARN
(( LAST_RC == 2 )) || fail '四分钟received责任应保持需关注而非故障'
assert_answer_counts WARN 0 1 0 0
[[ "$before" == "$(business_hash)" ]] || fail '只读doctor改写了短期received责任'
pass '短期received责任保持需关注'

RESPONSIBILITY_STATE_KEY=${SESSION_FILE##*/session-}
RESPONSIBILITY_STATE_KEY=${RESPONSIBILITY_STATE_KEY%.json}
RESPONSIBILITY_POOL_REVISION=$(jq -r '.revision' "${DEPLOY}/config/provider-pool-applied.json")
RESPONSIBILITY_SECRETS_GENERATION=$(jq -r '.secrets_generation' \
  "${DEPLOY}/config/provider-pool-applied.json")
RESPONSIBILITY_POOL_SHA=$(sha256sum "${DEPLOY}/config/provider-pool-applied.json" | awk '{print $1}')
RESPONSIBILITY_MATERIALS_SHA=$(jq -r '.source_sha256' "${DEPLOY}/config/materials-applied.json")
VALID_OUTGOING_CONTENT_SHA=$(printf '%s' \
  '{"content":"合成已持久计划","type":"text"}' | sha256sum | awk '{print $1}')
RESPONSIBILITY_JOB_C=$(printf 'c%.0s' {1..64})
RESPONSIBILITY_JOB_D=$(printf 'd%.0s' {1..64})
RESPONSIBILITY_JOB_G=$(printf '0%.0s' {1..64})
RESPONSIBILITY_FP_C_HEX=$(printf '%s' \
  "${RESPONSIBILITY_STATE_KEY}|${RESPONSIBILITY_JOB_C}|ai_text" | sha256sum | awk '{print substr($1,1,12)}')
RESPONSIBILITY_FP_D_HEX=$(printf '%s' \
  "${RESPONSIBILITY_STATE_KEY}|${RESPONSIBILITY_JOB_D}|ai_text" | sha256sum | awk '{print substr($1,1,12)}')
RESPONSIBILITY_FP_G_HEX=$(printf '%s' \
  "${RESPONSIBILITY_STATE_KEY}|${RESPONSIBILITY_JOB_G}|ai_text" | sha256sum | awk '{print substr($1,1,12)}')
RESPONSIBILITY_FP_C=$((16#$RESPONSIBILITY_FP_C_HEX))
RESPONSIBILITY_FP_D=$((16#$RESPONSIBILITY_FP_D_HEX))
RESPONSIBILITY_FP_G=$((16#$RESPONSIBILITY_FP_G_HEX))
VALID_PICKER_ID="crispai_$(printf 'a%.0s' {1..32})"
VALID_PICKER_FP_HEX=$(printf '%s' "$VALID_PICKER_ID" | sha256sum | awk '{print substr($1,1,12)}')
VALID_PICKER_FP=$((16#$VALID_PICKER_FP_HEX))
VALID_PROVIDER_PLAN_CANONICAL=$(jq -Scn \
  '{type:"text",purpose:"ai_text",content:"合成已持久计划",outcome:"",sources:[],tags:[]}')
VALID_PROVIDER_PLAN_SHA=$(printf '%s' "$VALID_PROVIDER_PLAN_CANONICAL" \
  | sha256sum | awk '{print $1}')
RESPONSIBILITY_FUTURE=$(( $(date -u '+%s%3N') + 3600000 ))

jq --argjson old "$RESPONSIBILITY_OLD" --argjson revision "$RESPONSIBILITY_RUNTIME_REVISION" \
  --arg content "$RESPONSIBILITY_CONTENT" \
  --argjson pool_revision "$RESPONSIBILITY_POOL_REVISION" \
  --arg secrets_generation "$RESPONSIBILITY_SECRETS_GENERATION" \
  --arg pool_sha "$RESPONSIBILITY_POOL_SHA" --arg materials_sha "$RESPONSIBILITY_MATERIALS_SHA" \
  --arg valid_content_sha "$VALID_OUTGOING_CONTENT_SHA" \
  --argjson fingerprint_c "$RESPONSIBILITY_FP_C" --argjson fingerprint_d "$RESPONSIBILITY_FP_D" \
  --argjson fingerprint_g "$RESPONSIBILITY_FP_G" --argjson future "$RESPONSIBILITY_FUTURE" '
    def base($id; $fingerprint; $generation; $session):
      {id:$id,event:"message:send",status:"received",control:false,
       revision:$revision,generation:$generation,response_generation:0,sequence:4,
       received_at:$old,event_time:$old,attempts:1,lease_until:0,
       responsibility_status:"pending",
       data:{session_id:$session,from:"user",type:"text",content:$content,
         fingerprint:$fingerprint}};
    .mode="ai" | .resume_at=null | .pause_reason="" | .last_human_at=0 |
    .human_event_id="" | .control_watermark=0 | .worker=null |
    .generation as $generation | .session_id as $session |
    .jobs=[
      (base(("1"*64);900061;$generation;$session) | .plan={}),
      (base(("2"*64);900062;$generation;$session) |
        .plan={type:"text",content:"x",purpose:"!!!"}),
      (base(("3"*64);900063;$generation;$session) | .provider_migration_from=false),
      (base(("4"*64);900064;$generation;$session) |
        .inference={provider_receipt_protocol_version:1}),
      (base(("5"*64);900065;$generation;$session) | .provider_result_receipt={}),
      (base(("6"*64);900066;$generation;$session) | .provider_settlement={}),
      (base(("7"*64);900067;$generation;$session) | .provider_retirement={}),
      base(("8"*64);900068;$generation;$session),
      base(("9"*64);900069;$generation;$session),
      base(("a"*64);900070;$generation;$session),
      (base(("b"*64);900071;$generation;$session) |
        .inference={runtime_revision:$revision,pool_revision:$pool_revision,
          secrets_generation:$secrets_generation,pool_sha256:$pool_sha,
          materials_source_sha256:$materials_sha,configuration_binding:("0"*64),
          deadline_at:9999999999999,attempt_generation:1,provider_receipt_protocol_version:1}),
      (base(("c"*64);900072;$generation;$session) |
        .plan={type:"text",content:"合成已持久计划",ordinary:true,purpose:"ai_text"}),
      (base(("d"*64);900073;$generation;$session) |
        .plan={type:"text",content:"合成已持久计划",ordinary:true,purpose:"ai_text"}),
      (base(("e"*64);900074;$generation;$session) |
        .plan={type:"picker",purpose:"menu",ordinary:true,
          content:{id:"bad-picker",text:"请选择",choices:[false]}}),
      (base(("f"*64);900075;$generation;$session) |
        .inference={runtime_revision:$revision,pool_revision:$pool_revision,
          secrets_generation:7,pool_sha256:$pool_sha,
          materials_source_sha256:$materials_sha,configuration_binding:("0"*64),
          deadline_at:9999999999999,attempt_generation:1,provider_receipt_protocol_version:1}),
      (base(("0"*64);900076;$generation;$session) |
        .plan={type:"text",content:"合成已持久计划",ordinary:true,purpose:"ai_text",
          fingerprint:$fingerprint_g}),
      (base(42;900077;$generation;$session) |
        .plan={type:"text",content:"合成已持久计划",ordinary:true,purpose:"ai_text"}),
      (base(("ab"*32);900078;$generation;$session) |
        .plan={type:"text",content:"合成已持久计划",ordinary:true,purpose:"ai_text",
          fingerprint:"-"})
    ] |
    .outgoing={
      "900068":{job_id:("8"*64)},
      "900069":{job_id:("9"*64),status:"queued",
        body:{type:"bogus",content:"x",from:"operator",origin:"chat",fingerprint:900069}},
      "900070":{job_id:("a"*64),status:"queued",
        body:{type:"text",content:{text:"x"},from:"operator",origin:"chat",fingerprint:900070}},
      ($fingerprint_c | tostring):{job_id:("c"*64),status:"rate_limited",
        created_at:$old,attempts:1,generation:$generation,response_generation:0,
        delivery_identity_version:1,purpose:"ai_text",message_type:"text",
        semantic_intent:"answer",content_sha256:("d"*64),attempt_token:("c"*32),
        failure:"crisp_rate_limited",recovery_deferred:true,next_action_at:($old+60000),
        body:{type:"text",content:"合成已持久计划",from:"operator",origin:"chat",
          fingerprint:$fingerprint_c}},
      "999999":{job_id:("d"*64),status:"rejected",
        created_at:$old,attempts:1,generation:$generation,response_generation:0,
        delivery_identity_version:1,purpose:"ai_text",message_type:"text",
        semantic_intent:"answer",content_sha256:$valid_content_sha,attempt_token:("d"*32),
        failure:"crisp_http_400",recovery_deferred:true,next_action_at:($old+300000),
        body:{type:"text",content:"合成已持久计划",from:"operator",origin:"chat",
          fingerprint:$fingerprint_d}},
      "scalar":"broken",
      ($fingerprint_g | tostring):{job_id:("0"*64),status:"sending",
        body:{type:"text",content:"合成已持久计划",from:"operator",origin:"chat",
          fingerprint:$fingerprint_g},created_at:$future,attempts:1,generation:$generation,
        response_generation:0,delivery_identity_version:1,purpose:"ai_text",message_type:"text",
        semantic_intent:"answer",content_sha256:$valid_content_sha,attempt_token:("e"*32)}
    }
  ' "${TEST_ROOT}/session.saved" > "$SESSION_FILE"
before=$(business_hash)
invoke --local
assert_result runtime.answer_responsibilities FAIL
(( LAST_RC == 1 )) || fail '十九类畸形责任产物必须阻断本地自检'
assert_answer_counts FAIL 14 18 0 19 1
[[ "$before" == "$(business_hash)" ]] || fail '只读doctor改写了畸形责任产物集合'
pass '畸形plan、Provider身份、摘要、fingerprint与outgoing均不能冒充有效责任产物'

jq --argjson old "$RESPONSIBILITY_OLD" --argjson revision "$RESPONSIBILITY_RUNTIME_REVISION" \
  --arg content "$RESPONSIBILITY_CONTENT" --arg job "$RESPONSIBILITY_JOB_ID" \
  --arg picker_id "$VALID_PICKER_ID" --argjson picker_fingerprint "$VALID_PICKER_FP" '
    .mode="ai" | .resume_at=null | .pause_reason="" | .last_human_at=0 |
    .human_event_id="" | .control_watermark=0 | .worker=null | .outgoing={} |
    .jobs=[{id:$job,event:"message:send",status:"received",control:false,
      revision:$revision,generation:.generation,response_generation:0,sequence:4,
      received_at:$old,event_time:$old,attempts:1,lease_until:0,
      responsibility_status:"pending",
      plan:{type:"picker",content:{id:$picker_id,text:"暂无可用选项",choices:[]},
        fingerprint:$picker_fingerprint,ordinary:true,purpose:"menu"},
      data:{session_id:.session_id,from:"user",type:"text",content:$content,fingerprint:90007}}]
  ' "${TEST_ROOT}/session.saved" > "$SESSION_FILE"
before=$(business_hash)
invoke --local
assert_result runtime.answer_responsibilities WARN
(( LAST_RC == 2 )) || fail '合法已持久计划应交由现有后续诊断而非无产物故障'
assert_answer_counts WARN 0 1 0 0
[[ "$before" == "$(business_hash)" ]] || fail '只读doctor改写了合法计划责任'
pass '合法空选项picker可排除无产物分类但不冒充已回答'

cp -p -- "$SESSION_FILE" "${TEST_ROOT}/valid-picker.session"
jq --argjson fingerprint "$((VALID_PICKER_FP + 1))" \
  '.jobs[0].plan.fingerprint=$fingerprint' "${TEST_ROOT}/valid-picker.session" > "$SESSION_FILE"
before=$(business_hash)
invoke --local
assert_result runtime.answer_responsibilities FAIL
(( LAST_RC == 1 )) || fail 'picker的id与fingerprint错配必须阻断本地自检'
assert_answer_counts FAIL 0 1 0 1
[[ "$before" == "$(business_hash)" ]] || fail '只读doctor改写了picker身份错配责任'
pass 'picker身份按createOffer生产公式闭合验证'

jq '.jobs=[false]' "${TEST_ROOT}/session.saved" > "$SESSION_FILE"
before=$(business_hash)
invoke --local
assert_result runtime.state FAIL
assert_result runtime.answer_responsibilities WARN
(( LAST_RC == 1 )) || fail 'scalar job成员必须形成结构化会话状态故障'
[[ "$before" == "$(business_hash)" ]] || fail '只读doctor改写了scalar job状态'
pass 'jobs数组非对象成员不会中止doctor或伪造通过'

for nested_case in worker offer plan; do
  case "$nested_case" in
    worker) jq '.worker=[]' "${TEST_ROOT}/session.saved" > "$SESSION_FILE" ;;
    offer) jq '.offers={bad:[]}' "${TEST_ROOT}/session.saved" > "$SESSION_FILE" ;;
    plan) jq '.jobs=[{plan:[]}]' "${TEST_ROOT}/session.saved" > "$SESSION_FILE" ;;
  esac
  before=$(business_hash)
  invoke --local
  assert_result runtime.state FAIL
  assert_result runtime.answer_responsibilities WARN
  (( LAST_RC == 1 )) || fail "嵌套scalar状态必须形成结构化故障：${nested_case}"
  [[ "$before" == "$(business_hash)" ]] || fail "只读doctor改写了嵌套scalar状态：${nested_case}"
done
pass 'worker、offer与plan非对象值均结构化失败而不中止doctor'

jq --argjson old "$RESPONSIBILITY_OLD" --argjson revision "$RESPONSIBILITY_RUNTIME_REVISION" \
  --arg content "$RESPONSIBILITY_CONTENT" --arg job "$RESPONSIBILITY_JOB_ID" '
    .mode="ai" | .resume_at=null | .pause_reason="" | .last_human_at=0 |
    .human_event_id="" | .control_watermark=0 | .worker=null | .outgoing={} |
    .jobs=[{id:$job,event:"message:send",status:"received",control:false,
      revision:$revision,generation:.generation,response_generation:0,sequence:4,
      received_at:$old,event_time:$old,attempts:1,lease_until:0,
      responsibility_status:"unresolved_failure",failure_since:"1x",
      failure_code:"synthetic_unresolved",
      data:{session_id:.session_id,from:"user",type:"text",content:$content,fingerprint:900080}}]
  ' "${TEST_ROOT}/session.saved" > "$SESSION_FILE"
before=$(business_hash)
invoke --local
assert_result runtime.answer_responsibilities FAIL
(( LAST_RC == 1 )) || fail '畸形failure_since必须保留结构化未解决责任故障'
assert_answer_counts FAIL 0 1 0 0
[[ "$before" == "$(business_hash)" ]] || fail '只读doctor改写了畸形failure_since责任'
pass 'failure_since非整数时安全回退received_at而不中止doctor'

jq --argjson old "$RESPONSIBILITY_OLD" --argjson revision "$RESPONSIBILITY_RUNTIME_REVISION" \
  --arg content "$RESPONSIBILITY_CONTENT" '
    def base($id; $fingerprint; $generation; $session):
      {id:$id,event:"message:send",status:"received",control:false,
       revision:$revision,generation:$generation,response_generation:0,sequence:4,
       received_at:$old,event_time:$old,attempts:1,lease_until:0,
       responsibility_status:"pending",
       data:{session_id:$session,from:"user",type:"text",content:$content,
         fingerprint:$fingerprint}};
    .mode="ai" | .resume_at=null | .pause_reason="" | .last_human_at=0 |
    .human_event_id="" | .control_watermark=0 | .worker=null | .outgoing={} |
    .generation as $generation | .session_id as $session |
    .jobs=[
      (base(("1"*64);900081;$generation;$session) |
        .plan={type:"text",content:"",ordinary:true,purpose:"ai_text"}),
      (base(("2"*64);900082;$generation;$session) |
        .plan={type:"internal",content:"x",ordinary:true,purpose:"ai_text"})
    ]
  ' "${TEST_ROOT}/session.saved" > "$SESSION_FILE"
before=$(business_hash)
invoke --local
assert_result runtime.answer_responsibilities FAIL
(( LAST_RC == 1 )) || fail '不可投递plan不得冒充恢复产物'
assert_answer_counts FAIL 2 2 0 2
[[ "$before" == "$(business_hash)" ]] || fail '只读doctor改写了不可投递plan责任'
pass '空text与错误用途internal均不能遮蔽长期无产物责任'

jq --argjson old "$RESPONSIBILITY_OLD" --argjson revision "$RESPONSIBILITY_RUNTIME_REVISION" \
  --arg content "$RESPONSIBILITY_CONTENT" --arg job "$RESPONSIBILITY_JOB_ID" '
    .mode="ai" | .resume_at=null | .pause_reason="" | .last_human_at=0 |
    .human_event_id="" | .control_watermark=0 | .worker=null | .outgoing={} |
    .jobs=[{id:$job,event:"message:send",status:"received",control:false,
      revision:$revision,generation:.generation,response_generation:0,sequence:4,
      received_at:$old,event_time:$old,attempts:1,lease_until:0,
      responsibility_status:"pending",
      plan:{type:"internal",content:"",ordinary:true,purpose:"technical_unresolved",
        safe_error_context:"text",answer_responsibility:"unresolved_failure",
        diagnostic_code:"runtime_unavailable",tags:[]},
      data:{session_id:.session_id,from:"user",type:"text",content:$content,fingerprint:900083}}]
  ' "${TEST_ROOT}/session.saved" > "$SESSION_FILE"
before=$(business_hash)
invoke --local
assert_result runtime.answer_responsibilities WARN
(( LAST_RC == 2 )) || fail '精确technical_unresolved计划应保持可诊断恢复状态'
assert_answer_counts WARN 0 1 0 0
[[ "$before" == "$(business_hash)" ]] || fail '只读doctor改写了技术恢复计划'
pass '精确technical_unresolved生产形状仍可作为恢复产物'

jq --argjson old "$RESPONSIBILITY_OLD" --argjson revision "$RESPONSIBILITY_RUNTIME_REVISION" \
  --arg content "$RESPONSIBILITY_CONTENT" --arg job "$RESPONSIBILITY_JOB_ID" '
    .mode="ai" | .resume_at=null | .pause_reason="" | .last_human_at=0 |
    .human_event_id="" | .control_watermark=0 | .worker=null | .outgoing={} |
    .jobs=[{id:$job,event:"message:send",status:"received",control:false,
      revision:$revision,generation:.generation,response_generation:0,sequence:4,
      received_at:$old,event_time:$old,attempts:1,lease_until:0,
      responsibility_status:"pending",
      provider_settlement:{schema_version:1,state:"settled",plan_sha256:("a"*64),
        response_generation:0,attempts:1,settled_at:$old},
      data:{session_id:.session_id,from:"user",type:"text",content:$content,fingerprint:900084}}]
  ' "${TEST_ROOT}/session.saved" > "$SESSION_FILE"
before=$(business_hash)
invoke --local
assert_result runtime.answer_responsibilities FAIL
(( LAST_RC == 1 )) || fail '缺少plan的完成settlement必须阻断本地自检'
assert_answer_counts FAIL 1 1 0 1
[[ "$before" == "$(business_hash)" ]] || fail '只读doctor改写了planless settlement责任'
pass 'planless settlement不能冒充可恢复答案正文'

jq --argjson old "$RESPONSIBILITY_OLD" --argjson revision "$RESPONSIBILITY_RUNTIME_REVISION" \
  --arg content "$RESPONSIBILITY_CONTENT" --arg job "$RESPONSIBILITY_JOB_ID" \
  --arg plan_sha "$VALID_PROVIDER_PLAN_SHA" '
    .mode="ai" | .resume_at=null | .pause_reason="" | .last_human_at=0 |
    .human_event_id="" | .control_watermark=0 | .worker=null | .outgoing={} |
    .jobs=[{id:$job,event:"message:send",status:"received",control:false,
      revision:$revision,generation:.generation,response_generation:0,sequence:4,
      received_at:$old,event_time:$old,attempts:1,lease_until:0,
      responsibility_status:"pending",
      plan:{type:"text",content:"合成已持久计划",ordinary:true,purpose:"ai_text"},
      provider_settlement:{schema_version:1,state:"settled",plan_sha256:$plan_sha,
        response_generation:0,attempts:1,settled_at:$old},
      data:{session_id:.session_id,from:"user",type:"text",content:$content,fingerprint:900085}}]
  ' "${TEST_ROOT}/session.saved" > "$SESSION_FILE"
before=$(business_hash)
invoke --local
assert_result runtime.answer_responsibilities WARN
(( LAST_RC == 2 )) || fail '同事务plan与完成settlement应保持可恢复状态'
assert_answer_counts WARN 0 1 0 0
[[ "$before" == "$(business_hash)" ]] || fail '只读doctor改写了合法plan与settlement责任'
pass '同事务plan与settlement摘要保持精确绑定'

jq --argjson old "$RESPONSIBILITY_OLD" --argjson revision "$RESPONSIBILITY_RUNTIME_REVISION" \
  --arg content "$RESPONSIBILITY_CONTENT" --arg job "$RESPONSIBILITY_JOB_C" \
  --arg content_sha "$VALID_OUTGOING_CONTENT_SHA" \
  --argjson fingerprint "$RESPONSIBILITY_FP_C" '
    .mode="ai" | .resume_at=null | .pause_reason="" | .last_human_at=0 |
    .human_event_id="" | .control_watermark=0 | .worker=null |
    .jobs=[{id:$job,event:"message:send",status:"received",control:false,
      revision:$revision,generation:.generation,response_generation:0,sequence:4,
      received_at:$old,event_time:$old,attempts:1,lease_until:0,
      responsibility_status:"pending",
      plan:{type:"text",content:"合成已持久计划",ordinary:true,purpose:"ai_text"},
      data:{session_id:.session_id,from:"user",type:"text",content:$content,fingerprint:900086}}] |
    .outgoing={($fingerprint | tostring):{job_id:$job,status:"queued",purpose:true,
      content_sha256:$content_sha,
      body:{type:"text",content:"合成已持久计划",from:"operator",origin:"chat",
        fingerprint:$fingerprint}}}
  ' "${TEST_ROOT}/session.saved" > "$SESSION_FILE"
before=$(business_hash)
invoke --local
assert_result runtime.answer_responsibilities FAIL
(( LAST_RC == 1 )) || fail '无公开生产合同的queued记录必须显式失败关闭'
assert_answer_counts FAIL 0 1 0 1
[[ "$before" == "$(business_hash)" ]] || fail '只读doctor改写了queued畸形身份'
pass 'queued附加错误类型不会中止jq或冒充恢复产物'

jq --argjson old "$RESPONSIBILITY_OLD" --argjson revision "$RESPONSIBILITY_RUNTIME_REVISION" \
  --arg content "$RESPONSIBILITY_CONTENT" --arg job "$RESPONSIBILITY_JOB_ID" '
    .mode="ai" | .resume_at=null | .pause_reason="" | .last_human_at=0 |
    .human_event_id="" | .control_watermark=0 | .worker=null |
    .jobs=[{id:$job,event:"message:send",status:"received",control:false,
      revision:$revision,generation:.generation,response_generation:0,sequence:4,
      received_at:$old,event_time:$old,attempts:1,lease_until:0,
      responsibility_status:"pending",
      plan:{type:"text",content:"合成已持久计划",ordinary:true,purpose:"ai_text"},
      data:{session_id:.session_id,from:"user",type:"text",content:$content,fingerprint:90008}}] |
    .outgoing={"90008":{job_id:$job}}
  ' "${TEST_ROOT}/session.saved" > "$SESSION_FILE"
before=$(business_hash)
invoke --local
assert_result runtime.answer_responsibilities FAIL
(( LAST_RC == 1 )) || fail '合法计划不得遮蔽同责任的畸形outgoing'
assert_answer_counts FAIL 0 1 0 1
[[ "$before" == "$(business_hash)" ]] || fail '只读doctor改写了合法与畸形并存责任'
pass '合法产物不能遮蔽同一责任的畸形产物'

VALID_OUTGOING_NOW=$(date -u '+%s%3N')
VALID_OUTGOING_FINGERPRINT_HEX=$(printf '%s' \
  "${RESPONSIBILITY_STATE_KEY}|${RESPONSIBILITY_JOB_ID}|ai_text|recovery:2" | sha256sum | awk '{print substr($1,1,12)}')
VALID_OUTGOING_FINGERPRINT=$((16#$VALID_OUTGOING_FINGERPRINT_HEX))
jq --argjson old "$RESPONSIBILITY_OLD" --argjson now "$VALID_OUTGOING_NOW" \
  --argjson revision "$RESPONSIBILITY_RUNTIME_REVISION" --arg content "$RESPONSIBILITY_CONTENT" \
  --arg job "$RESPONSIBILITY_JOB_ID" --arg content_sha "$VALID_OUTGOING_CONTENT_SHA" \
  --argjson fingerprint "$VALID_OUTGOING_FINGERPRINT" '
    .mode="ai" | .resume_at=null | .pause_reason="" | .last_human_at=0 |
    .human_event_id="" | .control_watermark=0 | .worker=null |
    .jobs=[{id:$job,event:"message:send",status:"received",control:false,
      revision:$revision,generation:.generation,response_generation:2,sequence:4,
      received_at:$old,event_time:$old,attempts:1,lease_until:0,
      responsibility_status:"pending",
      plan:{type:"text",content:"合成已持久计划",ordinary:true,purpose:"ai_text"},
      data:{session_id:.session_id,from:"user",type:"text",content:$content,fingerprint:90009}}] |
    .outgoing={($fingerprint | tostring):{
      status:"sending",body:{type:"text",content:"合成已持久计划",from:"operator",
        origin:"chat",fingerprint:$fingerprint},created_at:$now,attempts:1,job_id:$job,
      generation:.generation,response_generation:2,delivery_identity_version:1,
      purpose:"ai_text",message_type:"text",semantic_intent:"answer",
      content_sha256:$content_sha,attempt_token:("c"*32)}}
  ' "${TEST_ROOT}/session.saved" > "$SESSION_FILE"
before=$(business_hash)
invoke --local
assert_result runtime.answer_responsibilities WARN
(( LAST_RC == 2 )) || fail '合法当前发送身份应由未知发送诊断而非产物损坏阻断'
assert_answer_counts WARN 0 1 0 0 1
[[ "$before" == "$(business_hash)" ]] || fail '只读doctor改写了合法当前发送身份'
pass '无显式fingerprint的恢复代sending按生产公式保持可诊断待处理'

jq --argjson old "$RESPONSIBILITY_OLD" --argjson expired "$RESPONSIBILITY_EXPIRED" \
  --argjson revision "$RESPONSIBILITY_RUNTIME_REVISION" --arg content "$RESPONSIBILITY_CONTENT" \
  --arg job "$RESPONSIBILITY_JOB_ID" '
    .mode="ai" | .resume_at=null | .pause_reason="" | .last_human_at=0 |
    .human_event_id="" | .control_watermark=0 |
    .outgoing={} | .worker={job:$job,token:"aaaaaaaaaaaaaaaaaaaaaaaa",until:$expired} |
    .jobs=[{id:$job,event:"message:send",status:"processing",control:false,
      revision:$revision,generation:.generation,response_generation:0,sequence:4,
      received_at:$old,event_time:$old,attempts:1,lease_until:$expired,
      execution_token:"aaaaaaaaaaaaaaaaaaaaaaaa",responsibility_status:"pending",
      data:{session_id:.session_id,from:"user",type:"text",content:$content,fingerprint:90002}}]
  ' "${TEST_ROOT}/session.saved" > "$SESSION_FILE"
before=$(business_hash)
invoke --local
assert_result runtime.answer_responsibilities FAIL
(( LAST_RC == 1 )) || fail '租约已过期的长期 processing 无产物责任必须退出 1'
assert_answer_counts FAIL 1 1 0
[[ "$before" == "$(business_hash)" ]] || fail '只读doctor改写了到期 processing 原问题责任'
pass '租约到期的长期 processing 无产物责任明确失败'

jq --argjson old "$RESPONSIBILITY_OLD" --argjson active "$RESPONSIBILITY_ACTIVE" \
  --argjson revision "$RESPONSIBILITY_RUNTIME_REVISION" --arg content "$RESPONSIBILITY_CONTENT" \
  --arg job "$RESPONSIBILITY_JOB_ID" '
    .mode="ai" | .resume_at=null | .pause_reason="" | .last_human_at=0 |
    .human_event_id="" | .control_watermark=0 |
    .outgoing={} | .worker={job:$job,token:"bbbbbbbbbbbbbbbbbbbbbbbb",until:$active} |
    .jobs=[{id:$job,event:"message:send",status:"processing",control:false,
      revision:$revision,generation:.generation,response_generation:0,sequence:4,
      received_at:$old,event_time:$old,attempts:1,lease_until:$active,
      execution_token:"bbbbbbbbbbbbbbbbbbbbbbbb",responsibility_status:"pending",
      data:{session_id:.session_id,from:"user",type:"text",content:$content,fingerprint:90003}}]
  ' "${TEST_ROOT}/session.saved" > "$SESSION_FILE"
before=$(business_hash)
invoke --local
assert_result runtime.answer_responsibilities WARN
(( LAST_RC == 2 )) || fail '仍持有合法活动租约的 processing 责任应警告而非故障'
assert_answer_counts WARN 0 1 0
assert_answer_text '需关注' 2 0 1 0 active
[[ "$before" == "$(business_hash)" ]] || fail '只读doctor改写了活动 processing 原问题责任'
pass '合法活动 processing 租约不被长期无产物规则误报'

jq --argjson old "$RESPONSIBILITY_OLD" --argjson revision "$RESPONSIBILITY_RUNTIME_REVISION" '
    .mode="ai" | .resume_at=null | .pause_reason=null | .human_event_id=null |
    .worker=null | .outgoing={} | .jobs=[
      {id:("7"*64),event:"message:send",status:"cancelled",control:false,
        revision:$revision,generation:.generation,response_generation:0,sequence:4,
        received_at:$old,event_time:$old,attempts:1,lease_until:0,
        responsibility_status:"intentional_silence",responsibility_reason:"human_reply"},
      {id:("8"*64),event:"message:send",status:"cancelled",control:false,
        revision:$revision,generation:.generation,response_generation:0,sequence:5,
        received_at:$old,event_time:$old,attempts:1,lease_until:0,
        responsibility_status:"intentional_silence",responsibility_reason:"global_disabled"}
    ]
  ' "${TEST_ROOT}/session.saved" > "$SESSION_FILE"
before=$(business_hash)
invoke --local
assert_result runtime.answer_responsibilities PASS
(( LAST_RC == 0 )) || fail '人工与总关明确静默不应被长期无产物规则计为故障'
assert_answer_counts PASS 0 0 2
assert_answer_text '通过' 0 0 0 2 silence
[[ "$before" == "$(business_hash)" ]] || fail '只读doctor改写了人工或总关明确静默责任'
cp -p -- "${TEST_ROOT}/session.saved" "$SESSION_FILE"
pass '人工接管与总关明确静默不计入长期无产物责任'

NULL_CONTEXT_SHA=$(printf '%s' null | sha256sum | awk '{print $1}')
jq --arg context_sha "$NULL_CONTEXT_SHA" '.jobs[0].status="received" |
    .jobs[0].responsibility_status="pending" |
    .jobs[0].inference={attempt_generation:1,provider_receipt_protocol_version:1,
      configuration_binding:("a"*64)} |
    .jobs[0].provider_result_receipt={state:"unknown",stage:"answer",attempt_generation:1,
      configuration_binding:("a"*64),request_contract_version:1,request_sha256:("b"*64),
      plan_context_sha256:$context_sha,plan_context:null}' "${TEST_ROOT}/session.saved" > "$SESSION_FILE"
before=$(business_hash)
invoke --local
assert_result runtime.provider_receipts WARN
(( LAST_RC == 2 )) || fail '当前同代推理回执等待收敛必须警告而不是假绿'
[[ "$before" == "$(business_hash)" ]] || fail '只读doctor改写了等待重放的推理回执'

jq --arg context_sha "$NULL_CONTEXT_SHA" '.jobs[0].status="received" |
    .jobs[0].responsibility_status="pending" |
    .jobs[0].inference={attempt_generation:1,provider_receipt_protocol_version:1,
      configuration_binding:("a"*64)} |
    .jobs[0].provider_result_receipt={state:"unknown",stage:"answer",attempt_generation:1,
      configuration_binding:("a"*64),request_contract_version:1,request_sha256:("b"*64),
      plan_context_sha256:$context_sha,plan_context:{tampered:true}}' \
  "${TEST_ROOT}/session.saved" > "$SESSION_FILE"
invoke --local
assert_result runtime.provider_receipts FAIL
(( LAST_RC == 1 )) || fail '回执知识上下文正文与摘要不一致必须阻止自检假绿'

jq --arg context_sha "$NULL_CONTEXT_SHA" '.jobs[0].status="received" |
    .jobs[0].responsibility_status="pending" |
    .jobs[0].inference={attempt_generation:1,provider_receipt_protocol_version:1,
      configuration_binding:("a"*64)} |
    .jobs[0].provider_result_receipt={state:"unknown",stage:"answer",attempt_generation:2,
      configuration_binding:("a"*64),request_contract_version:1,request_sha256:("b"*64),
      plan_context_sha256:$context_sha,plan_context:null}' "${TEST_ROOT}/session.saved" > "$SESSION_FILE"
before=$(business_hash)
invoke --local
assert_result runtime.provider_receipts FAIL
(( LAST_RC == 1 )) || fail '错代推理回执必须阻止自检假绿'
[[ "$before" == "$(business_hash)" ]] || fail '只读doctor删除了错代推理回执或原任务'

jq '.jobs[0].status="received" | .jobs[0].responsibility_status="pending" |
    .jobs[0].inference={attempt_generation:1,provider_receipt_protocol_version:2,
      configuration_binding:("a"*64)} | del(.jobs[0].provider_result_receipt)' \
  "${TEST_ROOT}/session.saved" > "$SESSION_FILE"
invoke --local
assert_result runtime.provider_receipts FAIL
(( LAST_RC == 1 )) || fail '未知回执协议版本不能被当成明确无结果'

POOL_REVISION=$(jq -r '.revision' "${DEPLOY}/config/provider-pool-applied.json")
LEGACY_RUNTIME_REVISION=$RESPONSIBILITY_RUNTIME_REVISION
LEGACY_SECRETS_GENERATION=$(jq -r '.secrets_generation' "${DEPLOY}/config/provider-pool-applied.json")
LEGACY_POOL_SHA=$(sha256sum "${DEPLOY}/config/provider-pool-applied.json" | awk '{print $1}')
LEGACY_MATERIALS_SHA=$(jq -r '.source_sha256' "${DEPLOY}/config/materials-applied.json")
LEGACY_TARGET_JSON=$(jq -cn --argjson runtime "$LEGACY_RUNTIME_REVISION" \
  --argjson pool "$POOL_REVISION" --arg secrets "$LEGACY_SECRETS_GENERATION" \
  --arg pool_sha "$LEGACY_POOL_SHA" --arg materials_sha "$LEGACY_MATERIALS_SHA" \
  '[$runtime,$pool,$secrets,$pool_sha,$materials_sha]')
LEGACY_TARGET_BINDING=$(printf '%s' "$LEGACY_TARGET_JSON" | sha256sum | awk '{print $1}')
jq --argjson pool_revision "$POOL_REVISION" --argjson runtime_revision "$LEGACY_RUNTIME_REVISION" '
    .jobs[0].status="received" | .jobs[0].revision=$runtime_revision |
    .jobs[0].responsibility_status="pending" |
    .jobs[0].inference={pool_revision:$pool_revision,deadline_at:1} |
    del(.jobs[0].provider_result_receipt)' "${TEST_ROOT}/session.saved" > "$SESSION_FILE"
invoke --local
assert_result runtime.provider_receipts WARN
(( LAST_RC == 2 )) || fail 'v1.2.x旧推理信封应等待独占任务迁移而不是假绿或删除'

jq --argjson pool_revision "$POOL_REVISION" --argjson runtime_revision "$LEGACY_RUNTIME_REVISION" '
    .jobs[0].status="received" | .jobs[0].revision=$runtime_revision |
    .jobs[0].responsibility_status="pending" | .jobs[0].deferred_configuration=true |
    .jobs[0].inference={pool_revision:$pool_revision,deadline_at:1} |
    .jobs[0].legacy_v121_pending_origin={schema_version:1,phase:"source_frozen",
      source:{runtime_revision:.jobs[0].revision,pool_revision:$pool_revision,deadline_at:1}} |
    del(.jobs[0].provider_result_receipt,.jobs[0].plan)' \
  "${TEST_ROOT}/session.saved" > "$SESSION_FILE"
invoke --local
assert_result runtime.provider_receipts WARN
(( LAST_RC == 2 )) || fail '配置换代中已冻结的v1.2.1来源应显示等待迁移而不是假绿'

jq '.jobs[0].legacy_v121_pending_origin.source.deadline_at=2' "$SESSION_FILE" > "${SESSION_FILE}.bad"
mv -- "${SESSION_FILE}.bad" "$SESSION_FILE"
invoke --local
assert_result runtime.provider_receipts FAIL
(( LAST_RC == 1 )) || fail 'v1.2.1临时来源与旧推理期限不符必须阻止自检假绿'

jq '.jobs[0].legacy_v121_pending_origin.source.deadline_at=1 |
    .jobs[0].provider_settlement={schema_version:1,state:"deferred"}' \
  "$SESSION_FILE" > "${SESSION_FILE}.bad"
mv -- "${SESSION_FILE}.bad" "$SESSION_FILE"
invoke --local
assert_result runtime.provider_receipts FAIL
(( LAST_RC == 1 )) || fail '混有未知结算的v1.2.1临时来源不得冒充可安全迁移状态'

jq --argjson pool_revision "$POOL_REVISION" --arg secrets "$LEGACY_SECRETS_GENERATION" \
  --arg pool_sha "$LEGACY_POOL_SHA" --arg materials_sha "$LEGACY_MATERIALS_SHA" \
  --arg binding "$LEGACY_TARGET_BINDING" --argjson runtime_revision "$LEGACY_RUNTIME_REVISION" '
    .jobs[0].status="received" | .jobs[0].revision=$runtime_revision |
    .jobs[0].responsibility_status="pending" | .jobs[0].deferred_configuration=true |
    .jobs[0].legacy_v121_pending_origin={schema_version:1,phase:"successor_bound",
      source:{runtime_revision:.jobs[0].revision,pool_revision:$pool_revision,deadline_at:1},
      target:{runtime_revision:.jobs[0].revision,pool_revision:$pool_revision,
        secrets_generation:$secrets,pool_sha256:$pool_sha,materials_source_sha256:$materials_sha},
      target_configuration_binding:$binding} |
    del(.jobs[0].inference,.jobs[0].provider_result_receipt,.jobs[0].provider_settlement,.jobs[0].plan)' \
  "${TEST_ROOT}/session.saved" > "$SESSION_FILE"
before=$(business_hash)
invoke --local
assert_result runtime.provider_receipts WARN
(( LAST_RC == 2 )) || fail '已绑定完整目标代的v1.2.1来源应等待独占任务消费而不是假绿'
[[ "$before" == "$(business_hash)" ]] || fail '只读doctor消费或改写了v1.2.1 successor标记'

jq '.jobs[0].legacy_v121_pending_origin.target_configuration_binding=("f"*64)' \
  "$SESSION_FILE" > "${SESSION_FILE}.bad"
mv -- "${SESSION_FILE}.bad" "$SESSION_FILE"
invoke --local
assert_result runtime.provider_receipts FAIL
(( LAST_RC == 1 )) || fail '格式正确但内容错配的v1.2.1目标绑定必须阻止自检假绿'

for malformed in \
  '"corrupt"' \
  '[]' \
  '{}' \
  '{"pool_revision":1}' \
  '{"pool_revision":1,"deadline_at":1,"extra":true}' \
  '{"attempt_generation":1,"configuration_binding":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}'
do
  jq --argjson inference "$malformed" '.jobs[0].status="received" |
      .jobs[0].responsibility_status="pending" |
      .jobs[0].inference=$inference | del(.jobs[0].provider_result_receipt)' \
    "${TEST_ROOT}/session.saved" > "$SESSION_FILE"
  invoke --local
  assert_result runtime.provider_receipts FAIL
  (( LAST_RC == 1 )) || fail '畸形旧推理信封不能冒充可迁移的v1.2.1状态'
done
cp -p -- "${TEST_ROOT}/session.saved" "$SESSION_FILE"
invoke --local
assert_result runtime.provider_receipts PASS
pass '推理回执同代、错代、上下文篡改、未知协议、畸形状态与精确旧版迁移分层可见且默认只读'

RUNTIME_REVISION=$(jq -r '.revision' "${DEPLOY}/config/materials-applied.json")
SECRETS_GENERATION=$(jq -r '.secrets_generation' "${DEPLOY}/config/provider-pool-applied.json")
POOL_SHA=$(sha256sum "${DEPLOY}/config/provider-pool-applied.json" | awk '{print $1}')
MATERIALS_SHA=$(jq -r '.source_sha256' "${DEPLOY}/config/materials-applied.json")
STATE_KEY=${SESSION_FILE##*/session-}; STATE_KEY=${STATE_KEY%.json}
CONFIGURATION_JSON=$(jq -cn --argjson runtime "$RUNTIME_REVISION" --argjson pool "$POOL_REVISION" \
  --arg secrets "$SECRETS_GENERATION" --arg pool_sha "$POOL_SHA" --arg materials_sha "$MATERIALS_SHA" \
  '[$runtime,$pool,$secrets,$pool_sha,$materials_sha]')
CONFIGURATION_BINDING=$(printf '%s' "$CONFIGURATION_JSON" | sha256sum | awk '{print $1}')
PLAN_CANONICAL=$(jq -Scn '{content:"受控已持久答案",outcome:"knowledge_hit",purpose:"ai_text",
  sources:[],tags:["ai_replied"],type:"text"}')
PLAN_SHA=$(printf '%s' "$PLAN_CANONICAL" | sha256sum | awk '{print $1}')
jq --argjson runtime_revision "$RUNTIME_REVISION" --argjson pool_revision "$POOL_REVISION" \
  --arg secrets_generation "$SECRETS_GENERATION" --arg pool_sha "$POOL_SHA" \
  --arg materials_sha "$MATERIALS_SHA" --arg binding "$CONFIGURATION_BINDING" \
  --arg session_key "$STATE_KEY" --arg plan_sha "$PLAN_SHA" --arg context_sha "$NULL_CONTEXT_SHA" '
    .jobs[0]={id:("c"*64),status:"received",responsibility_status:"pending",generation:.generation,
      revision:$runtime_revision,response_generation:0,
      plan:{type:"text",purpose:"ai_text",content:"受控已持久答案",outcome:"knowledge_hit",
        sources:[],tags:["ai_replied"],ai:true,ordinary:true},
      inference:{runtime_revision:$runtime_revision,pool_revision:$pool_revision,
        secrets_generation:$secrets_generation,pool_sha256:$pool_sha,
        materials_source_sha256:$materials_sha,configuration_binding:$binding,
        deadline_at:9999999999999,attempt_generation:1,provider_receipt_protocol_version:1},
      provider_result_receipt:{state:"available",stage:"answer",attempt_generation:1,
        configuration_binding:$binding,request_contract_version:1,request_sha256:("b"*64),
        plan_context_sha256:$context_sha,plan_context:null},
      provider_settlement:{schema_version:1,state:"deferred",plan_sha256:$plan_sha,
        response_generation:0,attempts:1,first_recorded_at:1,next_action_at:9999999999999,
        envelope:{version:1,scope:"conversation",question_id:("c"*64),session_key:$session_key,
          generation:.generation,runtime_revision:$runtime_revision,pool_revision:$pool_revision,
          secrets_generation:$secrets_generation,pool_sha256:$pool_sha,
          materials_source_sha256:$materials_sha,configuration_binding:$binding,
          deadline_at:9999999999999,stage:"answer",attempt_generation:1,
          request_contract_version:1,request_sha256:("b"*64),plan_context_sha256:$context_sha}}}' \
  "${TEST_ROOT}/session.saved" > "$SESSION_FILE"
cp -p -- "$SESSION_FILE" "${TEST_ROOT}/provider-settlement.valid"
before=$(business_hash)
invoke --local
assert_result runtime.provider_settlements WARN
[[ "$before" == "$(business_hash)" ]] || fail '只读doctor改写了延后的推理结算责任'
jq '.jobs[0].provider_settlement={schema_version:1,state:"deferred",next_action_at:0}' \
  "${TEST_ROOT}/session.saved" > "$SESSION_FILE"
invoke --local
assert_result runtime.provider_settlements FAIL
(( LAST_RC == 1 )) || fail '缺少签名身份的延后结算不能被当成正常等待'
jq '.jobs[0].provider_settlement={schema_version:1,state:"invalid",next_action_at:0}' \
  "${TEST_ROOT}/session.saved" > "$SESSION_FILE"
invoke --local
assert_result runtime.provider_settlements FAIL
(( LAST_RC == 1 )) || fail '推理结算身份损坏必须阻止自检假绿'
jq '.jobs[0].provider_settlement={schema_version:1,state:"corrupt",next_action_at:0}' \
  "${TEST_ROOT}/session.saved" > "$SESSION_FILE"
invoke --local
assert_result runtime.provider_settlements FAIL
(( LAST_RC == 1 )) || fail '未知推理结算状态必须保留责任并阻止自检假绿'
jq '.jobs[0].provider_settlement="corrupt"' \
  "${TEST_ROOT}/session.saved" > "$SESSION_FILE"
invoke --local
assert_result runtime.provider_settlements FAIL
(( LAST_RC == 1 )) || fail '非对象推理结算记录必须被诊断而不能使自检崩溃'
jq '.jobs[0].provider_settlement={schema_version:1,state:"settled",settled_at:0}' \
  "${TEST_ROOT}/session.saved" > "$SESSION_FILE"
invoke --local
assert_result runtime.provider_settlements FAIL
(( LAST_RC == 1 )) || fail '缺少结果身份的伪结算完成状态必须阻止自检假绿'
jq '.jobs[0].provider_settlement={schema_version:1,state:"settled",plan_sha256:("a"*64),response_generation:-1,attempts:0,settled_at:0}' \
  "${TEST_ROOT}/session.saved" > "$SESSION_FILE"
invoke --local
assert_result runtime.provider_settlements FAIL
(( LAST_RC == 1 )) || fail '越界或零次数的伪结算完成状态必须阻止自检假绿'
jq '.jobs[0].provider_settlement={schema_version:1,state:"absent",plan_sha256:("a"*64),response_generation:0.5,attempts:1.5,settled_at:-1}' \
  "${TEST_ROOT}/session.saved" > "$SESSION_FILE"
invoke --local
assert_result runtime.provider_settlements FAIL
(( LAST_RC == 1 )) || fail '小数代次、次数或负完成时间不能伪装为已完成结算'
jq '.jobs[0].provider_settlement={schema_version:1,state:"settled",plan_sha256:("a"*64),response_generation:0,attempts:1,settled_at:0}' \
  "${TEST_ROOT}/session.saved" > "$SESSION_FILE"
invoke --local
assert_result runtime.provider_settlements PASS
jq '.jobs[0].provider_settlement.extra="unknown"' "$SESSION_FILE" > "${SESSION_FILE}.bad"
mv -- "${SESSION_FILE}.bad" "$SESSION_FILE"
invoke --local
assert_result runtime.provider_settlements FAIL
(( LAST_RC == 1 )) || fail '带未知字段的伪结算完成状态必须阻止自检假绿'
jq '.jobs[0].status="received" | .jobs[0].responsibility_status="pending" |
    .jobs[0].response_generation=0 |
    .jobs[0].plan={type:"text",purpose:"ai_text",content:"受控已持久答案",
      outcome:"knowledge_hit",sources:[],tags:["ai_replied"],ai:true,ordinary:true} |
    .jobs[0].provider_settlement={schema_version:1,state:"settled",plan_sha256:("a"*64),
      response_generation:0,attempts:1,settled_at:0}' \
  "${TEST_ROOT}/session.saved" > "$SESSION_FILE"
invoke --local
assert_result runtime.provider_settlements FAIL
(( LAST_RC == 1 )) || fail '完成结算摘要与仍待投递计划不匹配必须阻止自检假绿'
cp -p -- "${TEST_ROOT}/session.saved" "$SESSION_FILE"
pass '推理结果结算、请求回执、计划摘要和配置身份分层报告，默认自检不删责任'

RETIREMENT_ENVELOPE=$(jq -c '.jobs[0].provider_settlement.envelope' \
  "${TEST_ROOT}/provider-settlement.valid")
RETIREMENT_CANONICAL=$(jq -Scn --argjson envelope "$RETIREMENT_ENVELOPE" \
  '{envelope:$envelope,purpose:"conversation_cancelled"}')
RETIREMENT_SHA=$(printf '%s' "$RETIREMENT_CANONICAL" | sha256sum | awk '{print $1}')
jq --argjson envelope "$RETIREMENT_ENVELOPE" --arg identity "$RETIREMENT_SHA" '
    .jobs[0].status="cancelled" |
    .jobs[0].responsibility_status="intentional_silence" |
    .jobs[0].responsibility_reason="human_reply" |
    del(.jobs[0].plan,.jobs[0].provider_settlement) |
    .jobs[0].provider_retirement={schema_version:1,state:"deferred",
      purpose:"conversation_cancelled",envelope:$envelope,identity_sha256:$identity,
      attempts:1,first_recorded_at:1,last_attempt_at:1,next_action_at:9999999999999,
      reason:"retirement_unavailable",lease_until:0,lease_token:""}' \
  "${TEST_ROOT}/provider-settlement.valid" > "$SESSION_FILE"
cp -p -- "$SESSION_FILE" "${TEST_ROOT}/provider-retirement.valid"
before=$(business_hash)
invoke --local
assert_result runtime.provider_retirements WARN
(( LAST_RC == 2 )) || fail '已取消结果的签名退休等待收敛时必须警告'
[[ "$before" == "$(business_hash)" ]] || fail '只读doctor改写了退休身份、人工状态或推理回执'

MISMATCH_RETIREMENT_ENVELOPE=$(jq -c '.jobs[0].provider_retirement.envelope |
  .session_key=("d"*64)' "${TEST_ROOT}/provider-retirement.valid")
MISMATCH_RETIREMENT_CANONICAL=$(jq -Scn --argjson envelope "$MISMATCH_RETIREMENT_ENVELOPE" \
  '{envelope:$envelope,purpose:"conversation_cancelled"}')
MISMATCH_RETIREMENT_SHA=$(printf '%s' "$MISMATCH_RETIREMENT_CANONICAL" | sha256sum | awk '{print $1}')
jq --argjson envelope "$MISMATCH_RETIREMENT_ENVELOPE" --arg identity "$MISMATCH_RETIREMENT_SHA" \
  '.jobs[0].provider_retirement.envelope=$envelope |
   .jobs[0].provider_retirement.identity_sha256=$identity' \
  "${TEST_ROOT}/provider-retirement.valid" > "$SESSION_FILE"
invoke --local
assert_result runtime.provider_retirements FAIL
(( LAST_RC == 1 )) || fail '退休信封session_key与实际会话文件不一致必须失败'

jq 'del(.jobs[0].provider_retirement.lease_token)' \
  "${TEST_ROOT}/provider-retirement.valid" > "$SESSION_FILE"
invoke --local
assert_result runtime.provider_retirements FAIL
(( LAST_RC == 1 )) || fail '退休租约只存在截止时间而缺token必须失败'

jq '.jobs[0].provider_retirement.lease_until="0"' \
  "${TEST_ROOT}/provider-retirement.valid" > "$SESSION_FILE"
invoke --local
assert_result runtime.provider_retirements FAIL
(( LAST_RC == 1 )) || fail '退休租约字段类型错误必须失败'

jq '.jobs[0].provider_retirement.identity_sha256=("f"*64)' \
  "${TEST_ROOT}/provider-retirement.valid" > "$SESSION_FILE"
invoke --local
assert_result runtime.provider_retirements FAIL
(( LAST_RC == 1 )) || fail '格式正确但摘要错配的退休身份必须阻止自检假绿'

jq '.jobs[0].responsibility_reason="unrelated"' \
  "${TEST_ROOT}/provider-retirement.valid" > "$SESSION_FILE"
invoke --local
assert_result runtime.provider_retirements FAIL
(( LAST_RC == 1 )) || fail '未获人工取消授权的退休记录必须阻止自检假绿'

SESSION_GENERATION=$(jq -r '.generation' "${TEST_ROOT}/session.saved")
LEGACY_CLEANUP_DEADLINE=9999999999998
LEGACY_CLEANUP_ENVELOPE=$(jq -cn --arg session_key "$STATE_KEY" \
  --argjson generation "$SESSION_GENERATION" --argjson runtime_revision "$RUNTIME_REVISION" \
  --argjson pool_revision "$POOL_REVISION" --argjson deadline "$LEGACY_CLEANUP_DEADLINE" \
  '{version:1,scope:"conversation",question_id:("e"*64),session_key:$session_key,
    generation:$generation,runtime_revision:$runtime_revision,pool_revision:$pool_revision,
    deadline_at:$deadline,stage:"answer",attempt_generation:1,legacy_v121_cleanup:true}')
LEGACY_CLEANUP_CANONICAL=$(jq -Scn --argjson envelope "$LEGACY_CLEANUP_ENVELOPE" \
  '{envelope:$envelope,purpose:"conversation_cancelled"}')
LEGACY_CLEANUP_SHA=$(printf '%s' "$LEGACY_CLEANUP_CANONICAL" | sha256sum | awk '{print $1}')
jq --argjson envelope "$LEGACY_CLEANUP_ENVELOPE" --arg identity "$LEGACY_CLEANUP_SHA" \
  --argjson runtime_revision "$RUNTIME_REVISION" --argjson pool_revision "$POOL_REVISION" \
  --argjson deadline "$LEGACY_CLEANUP_DEADLINE" '
    .jobs[0]={id:("e"*64),status:"cancelled",responsibility_status:"intentional_silence",
      responsibility_reason:"human_reply",generation:.generation,revision:$runtime_revision,
      inference:{pool_revision:$pool_revision,deadline_at:$deadline},
      legacy_v121_pending_origin:{schema_version:1,phase:"source_frozen",
        source:{runtime_revision:$runtime_revision,pool_revision:$pool_revision,deadline_at:$deadline}},
      provider_retirement:{schema_version:1,state:"pending",purpose:"conversation_cancelled",
        envelope:$envelope,identity_sha256:$identity,attempts:0,first_recorded_at:1,
        next_action_at:0}}' "${TEST_ROOT}/session.saved" > "$SESSION_FILE"
invoke --local
assert_result runtime.provider_retirements WARN
(( LAST_RC == 2 )) || fail 'source_frozen旧缓存的签名cleanup等待必须是可诊断警告'

jq --argjson envelope "$LEGACY_CLEANUP_ENVELOPE" --arg identity "$LEGACY_CLEANUP_SHA" \
  --argjson runtime_revision "$RUNTIME_REVISION" --argjson pool_revision "$POOL_REVISION" \
  --argjson deadline "$LEGACY_CLEANUP_DEADLINE" --arg secrets "$SECRETS_GENERATION" \
  --arg pool_sha "$POOL_SHA" --arg materials_sha "$MATERIALS_SHA" \
  --arg target_binding "$CONFIGURATION_BINDING" '
    .jobs[0]={id:("e"*64),status:"cancelled",responsibility_status:"intentional_silence",
      responsibility_reason:"human_reply",generation:.generation,revision:$runtime_revision,
      legacy_v121_pending_origin:{schema_version:1,phase:"successor_bound",
        source:{runtime_revision:$runtime_revision,pool_revision:$pool_revision,deadline_at:$deadline},
        target:{runtime_revision:$runtime_revision,pool_revision:$pool_revision,
          secrets_generation:$secrets,pool_sha256:$pool_sha,materials_source_sha256:$materials_sha},
        target_configuration_binding:$target_binding},
      provider_retirement:{schema_version:1,state:"pending",purpose:"conversation_cancelled",
        envelope:$envelope,identity_sha256:$identity,attempts:0,first_recorded_at:1,
        next_action_at:0}}' "${TEST_ROOT}/session.saved" > "$SESSION_FILE"
invoke --local
assert_result runtime.provider_retirements WARN
(( LAST_RC == 2 )) || fail 'successor_bound旧缓存的签名cleanup等待必须是可诊断警告'

LEGACY_UNSETTLED_CANONICAL=$(jq -Scn --argjson envelope "$LEGACY_CLEANUP_ENVELOPE" \
  '{envelope:$envelope,purpose:"legacy_unsettled_retired"}')
LEGACY_UNSETTLED_SHA=$(printf '%s' "$LEGACY_UNSETTLED_CANONICAL" | sha256sum | awk '{print $1}')
jq --argjson envelope "$LEGACY_CLEANUP_ENVELOPE" --arg identity "$LEGACY_UNSETTLED_SHA" \
  --argjson runtime_revision "$RUNTIME_REVISION" --argjson pool_revision "$POOL_REVISION" \
  --argjson deadline "$LEGACY_CLEANUP_DEADLINE" '
    .jobs[0]={id:("e"*64),status:"received",responsibility_status:"unresolved_failure",
      failure_code:"legacy_unsettled_plan_migrated",legacy_unsettled_plan_migrated_at:1,
      generation:.generation,revision:$runtime_revision,
      inference:{pool_revision:$pool_revision,deadline_at:$deadline},
      provider_retirement:{schema_version:1,state:"pending",purpose:"legacy_unsettled_retired",
        envelope:$envelope,identity_sha256:$identity,attempts:0,first_recorded_at:1,
        next_action_at:0}}' "${TEST_ROOT}/session.saved" > "$SESSION_FILE"
cp -p -- "$SESSION_FILE" "${TEST_ROOT}/provider-retirement.legacy-unsettled"
invoke --local
assert_result runtime.provider_retirements WARN
assert_result runtime.answer_responsibilities FAIL
(( LAST_RC == 1 )) \
  || fail '旧未结算答案的签名cleanup应警告且未解决应答责任必须保持故障'

jq '.jobs[0].legacy_unsettled_plan_migrated_at=-1' \
  "${TEST_ROOT}/provider-retirement.legacy-unsettled" > "$SESSION_FILE"
invoke --local
assert_result runtime.provider_retirements FAIL
(( LAST_RC == 1 )) || fail '负数旧计划迁移标记不得授权破坏性Provider清理'

jq '.jobs[0].failure_code="unrelated"' \
  "${TEST_ROOT}/provider-retirement.legacy-unsettled" > "$SESSION_FILE"
invoke --local
assert_result runtime.provider_retirements FAIL
(( LAST_RC == 1 )) || fail '错误故障类别不得授权旧未结算答案清理'

jq '.jobs[0].provider_retirement={schema_version:1,state:"retired",
      purpose:"legacy_unsettled_retired",attempts:1,retired_at:1,
      identity_sha256:.jobs[0].provider_retirement.identity_sha256} |
    del(.jobs[0].inference,.jobs[0].provider_result_receipt,.jobs[0].provider_settlement,
      .jobs[0].provider_migration_from,.jobs[0].legacy_v121_pending_origin)' \
  "${TEST_ROOT}/provider-retirement.legacy-unsettled" > "$SESSION_FILE"
invoke --local
assert_result runtime.provider_retirements PASS
cp -p -- "$SESSION_FILE" "${TEST_ROOT}/provider-retirement.legacy-unsettled-finished"

jq '.jobs[0].provider_retirement={schema_version:1,state:"retired",
      purpose:"conversation_cancelled",attempts:1,retired_at:1,identity_sha256:("a"*64)} |
    del(.jobs[0].inference,.jobs[0].provider_result_receipt,.jobs[0].provider_settlement,
      .jobs[0].provider_migration_from,.jobs[0].legacy_v121_pending_origin)' \
  "${TEST_ROOT}/provider-retirement.valid" > "$SESSION_FILE"
invoke --local
assert_result runtime.provider_retirements PASS
cp -p -- "$SESSION_FILE" "${TEST_ROOT}/provider-retirement.finished"

jq '.jobs[0].provider_retirement.purpose="global_disabled"' \
  "${TEST_ROOT}/provider-retirement.finished" > "$SESSION_FILE"
invoke --local
assert_result runtime.provider_retirements FAIL
(( LAST_RC == 1 )) || fail '完成摘要的purpose与当前业务静默原因不符必须失败'

jq '.jobs[0].provider_retirement_failure_code="provider_retirement_identity_unresolved"' \
  "${TEST_ROOT}/provider-retirement.finished" > "$SESSION_FILE"
invoke --local
assert_result runtime.provider_retirements FAIL
(( LAST_RC == 1 )) || fail '孤立的退休失败码不能被完成摘要掩盖'

jq 'del(.jobs[0].provider_retirement) |
    .jobs[0].provider_retirement_failure_code="provider_retirement_identity_unresolved"' \
  "${TEST_ROOT}/provider-retirement.finished" > "$SESSION_FILE"
invoke --local
assert_result runtime.provider_retirements FAIL
(( LAST_RC == 1 )) || fail '只有失败码而没有退休记录时必须明确失败'

jq '.jobs[0].legacy_v121_pending_origin={schema_version:1,phase:"source_frozen",
      source:{runtime_revision:.jobs[0].revision,pool_revision:1,deadline_at:1}}' \
  "${TEST_ROOT}/provider-retirement.finished" > "$SESSION_FILE"
invoke --local
assert_result runtime.provider_retirements FAIL
(( LAST_RC == 1 )) || fail '完成摘要仍携带旧版迁移来源必须失败'

jq '.jobs[0].inference={pool_revision:1}' \
  "${TEST_ROOT}/provider-retirement.finished" > "${SESSION_FILE}.bad"
mv -- "${SESSION_FILE}.bad" "$SESSION_FILE"
invoke --local
assert_result runtime.provider_retirements FAIL
(( LAST_RC == 1 )) || fail '伪退休完成状态仍携带推理身份时必须阻止自检假绿'

jq 'del(.jobs[0].inference) | .jobs[0].provider_retirement.extra=true' \
  "${TEST_ROOT}/provider-retirement.finished" > "${SESSION_FILE}.bad"
mv -- "${SESSION_FILE}.bad" "$SESSION_FILE"
invoke --local
assert_result runtime.provider_retirements FAIL
(( LAST_RC == 1 )) || fail '带未知字段的伪退休完成状态必须阻止自检假绿'
cp -p -- "${TEST_ROOT}/session.saved" "$SESSION_FILE"
pass '人工/总关后的签名退休、授权、摘要、完成联合状态与只读边界可诊断'

mv -- "${DEPLOY}/config/provider-pool-applied.json" "${TEST_ROOT}/pool-applied.saved"
env_set "${DEPLOY}/.env" PROVIDER_POOL_REQUIRED false
invoke --local
assert_result provider.configuration FAIL
mv -- "${TEST_ROOT}/pool-applied.saved" "${DEPLOY}/config/provider-pool-applied.json"
env_set "${DEPLOY}/.env" PROVIDER_POOL_REQUIRED true
pass 'v1.2.1缺池不能通过篡改旧兼容flag绕过检查'
printf '主备自检专项完成：%s 组通过。\n' "$PASSED"
