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
write_readback
write_health unknown
before=$(business_hash)
invoke --local
(( LAST_RC == 2 )) || fail '单主未检测应警告，不假绿、不认定接口故障'
for id in provider.configuration provider.pending provider.rag_transaction provider.readback provider.rag_configuration provider.secret_permissions provider.adapter provider.visitor_output_code_binding provider.router_code_binding provider.envelope_code_binding anything.provider_binding anything.rag_context n8n.runtime_binding runtime.feedback runtime.provider_receipts runtime.provider_settlements runtime.provider_retirements; do assert_result "$id" PASS; done
assert_result provider.pool_health WARN
[[ "$before" == "$(business_hash)" ]] || fail '主备默认doctor改动业务资料或会话'
! grep -Eq 'provider\.example\.test|/workspace/.*/chat' "$FIXTURE_LOG" || fail '主备默认doctor执行付费推理'
pass '新主备接线、秘密代次、版本模块、评价停用和默认只读完整检查'

write_health healthy
invoke --local
(( LAST_RC == 0 )) || fail '当前健康证据及全部本地组件正常应退出0'
assert_result provider.pool_health PASS
pass '当前代主接口真实成功证据与未检测状态区分'

env_set "${DEPLOY}/.env" PROVIDER_RAG_CONTEXT_WINDOW 16384
invoke --local
assert_result provider.rag_configuration FAIL
assert_result anything.rag_context SKIP
(( LAST_RC == 1 )) || fail '池与知识预算投影不一致必须失败'
env_set "${DEPLOY}/.env" PROVIDER_RAG_CONTEXT_WINDOW 8192
pass '接口池预算未投影到知识组件时不能假通过'

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
  local expected_status=$1 stalled=$2 pending=$3 silence=$4
  jq -e --arg status "$expected_status" --arg stalled "$stalled" --arg pending "$pending" \
    --arg silence "$silence" '
      [.results[] | select(.id == "runtime.answer_responsibilities")][-1] as $item |
      $item.status == $status and
      ($item.summary | contains("长期处理无产物 \($stalled)")) and
      ($item.summary | contains("待处理/处理中 \($pending)")) and
      ($item.summary | contains("未知发送 0")) and
      ($item.summary | contains("明确政策静默 \($silence)"))
    ' "$OUT" >/dev/null || fail '应答责任 JSON 未按脱敏计数报告长期无产物状态'
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
LEGACY_RUNTIME_REVISION=$(jq -r '.jobs[0].revision' "${TEST_ROOT}/session.saved")
LEGACY_SECRETS_GENERATION=$(jq -r '.secrets_generation' "${DEPLOY}/config/provider-pool-applied.json")
LEGACY_POOL_SHA=$(sha256sum "${DEPLOY}/config/provider-pool-applied.json" | awk '{print $1}')
LEGACY_MATERIALS_SHA=$(jq -r '.source_sha256' "${DEPLOY}/config/materials-applied.json")
LEGACY_TARGET_JSON=$(jq -cn --argjson runtime "$LEGACY_RUNTIME_REVISION" \
  --argjson pool "$POOL_REVISION" --arg secrets "$LEGACY_SECRETS_GENERATION" \
  --arg pool_sha "$LEGACY_POOL_SHA" --arg materials_sha "$LEGACY_MATERIALS_SHA" \
  '[$runtime,$pool,$secrets,$pool_sha,$materials_sha]')
LEGACY_TARGET_BINDING=$(printf '%s' "$LEGACY_TARGET_JSON" | sha256sum | awk '{print $1}')
jq --argjson pool_revision "$POOL_REVISION" '.jobs[0].status="received" |
    .jobs[0].responsibility_status="pending" |
    .jobs[0].inference={pool_revision:$pool_revision,deadline_at:1} |
    del(.jobs[0].provider_result_receipt)' "${TEST_ROOT}/session.saved" > "$SESSION_FILE"
invoke --local
assert_result runtime.provider_receipts WARN
(( LAST_RC == 2 )) || fail 'v1.2.x旧推理信封应等待独占任务迁移而不是假绿或删除'

jq --argjson pool_revision "$POOL_REVISION" '.jobs[0].status="received" |
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
  --arg binding "$LEGACY_TARGET_BINDING" '.jobs[0].status="received" |
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
