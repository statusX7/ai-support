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
  n8n:(.n8n[0:10]+["http://provider-adapter:8787/v1",$key,"true"])
}' "$RUNTIME_ENV_FILE" > "${RUNTIME_ENV_FILE}.new"
mv -- "${RUNTIME_ENV_FILE}.new" "$RUNTIME_ENV_FILE"
revision=$(jq .revision "${DEPLOY}/config/provider-pool-applied.json")
write_health() {
  jq --arg state "$1" \
    '{ok:true,revision,entries:[.entries[]|{id,enabled,health:(if .enabled then $state else "disabled" end)}]}' \
    "${DEPLOY}/config/provider-pool-applied.json" > "${DEPLOY}/tmp/fixture-pool-status.json"
}
write_health unknown
before=$(business_hash)
invoke --local
(( LAST_RC == 2 )) || fail '单主未检测应警告，不假绿、不认定接口故障'
for id in provider.configuration provider.pending provider.secret_permissions provider.adapter provider.router_code_binding provider.envelope_code_binding anything.provider_binding n8n.runtime_binding runtime.feedback; do assert_result "$id" PASS; done
assert_result provider.pool_health WARN
[[ "$before" == "$(business_hash)" ]] || fail '主备默认doctor改动业务资料或会话'
! grep -Eq 'provider\.example\.test|/workspace/.*/chat' "$FIXTURE_LOG" || fail '主备默认doctor执行付费推理'
pass '新主备接线、秘密代次、版本模块、评价停用和默认只读完整检查'

write_health healthy
invoke --local
(( LAST_RC == 0 )) || fail '当前健康证据及全部本地组件正常应退出0'
assert_result provider.pool_health PASS
pass '当前代主接口真实成功证据与未检测状态区分'

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

mv -- "${DEPLOY}/config/provider-pool-applied.json" "${TEST_ROOT}/pool-applied.saved"
env_set "${DEPLOY}/.env" PROVIDER_POOL_REQUIRED false
invoke --local
assert_result provider.configuration FAIL
mv -- "${TEST_ROOT}/pool-applied.saved" "${DEPLOY}/config/provider-pool-applied.json"
env_set "${DEPLOY}/.env" PROVIDER_POOL_REQUIRED true
pass 'v1.2.1缺池不能通过篡改旧兼容flag绕过检查'
printf '主备自检专项完成：%s 组通过。\n' "$PASSED"
