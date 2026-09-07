#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
DOCTOR="${PROJECT_ROOT}/scripts/doctor.sh"
FIXTURE_BIN="${SCRIPT_DIR}/fixtures/doctor"
ORIGINAL_PATH=$PATH
PASSED=0
LAST_RC=0
TEST_WORK_ROOT="${PROJECT_ROOT}/.work/v1.2.0"
mkdir -p -- "$TEST_WORK_ROOT"
TEST_ROOT=$(mktemp -d "${TEST_WORK_ROOT}/doctor-test.XXXXXXXX")
DEPLOY="${TEST_ROOT}/deploy"
OUT="${TEST_ROOT}/stdout.json"
ERR="${TEST_ROOT}/stderr.txt"
FIXTURE_LOG="${TEST_ROOT}/fixture.log"
STOPPED_FILE="${TEST_ROOT}/stopped-services"
DB_PASSWORD_FILE="${TEST_ROOT}/postgres-running-password"
N8N_DB_PASSWORD_FILE="${TEST_ROOT}/n8n-running-password"
RUNTIME_ENV_FILE="${TEST_ROOT}/running-container-env.json"
SYSTEMD_DIR="${TEST_ROOT}/systemd"

cleanup() {
  if [[ "${AI_SUPPORT_TEST_KEEP_TMP:-0}" == 1 ]]; then
    printf '自检专项临时目录已保留：%s\n' "$TEST_ROOT" >&2
    return
  fi
  if [[ "$TEST_ROOT" == "${TEST_WORK_ROOT}"/doctor-test.* && -d "$TEST_ROOT" ]]; then
    rm -rf -- "$TEST_ROOT"
  fi
}
trap cleanup EXIT

fail() { printf '失败：[UNIT/CONTRACT] %s\n' "$1" >&2; exit 1; }
pass() { ((PASSED += 1)); printf '通过：[UNIT/CONTRACT] %s\n' "$1"; }

assert_result() {
  local id=$1 expected=$2 file=${3:-$OUT}
  jq -e --arg id "$id" --arg expected "$expected" \
    'any(.results[]; .id == $id and .status == $expected)' "$file" >/dev/null \
    || fail "${id} 应为 ${expected}"
}

fixture_env() {
  env PATH="${FIXTURE_BIN}:${ORIGINAL_PATH}" \
    DOCTOR_FIXTURE_DEPLOY="$DEPLOY" DOCTOR_FIXTURE_LOG="$FIXTURE_LOG" \
    DOCTOR_FIXTURE_STOPPED_FILE="$STOPPED_FILE" \
    DOCTOR_FIXTURE_DB_PASSWORD_FILE="$DB_PASSWORD_FILE" \
    DOCTOR_FIXTURE_N8N_DB_PASSWORD_FILE="$N8N_DB_PASSWORD_FILE" \
    DOCTOR_FIXTURE_RUNTIME_ENV_FILE="$RUNTIME_ENV_FILE" \
    DOCTOR_FIXTURE_DAEMON_FAIL="${DOCTOR_FIXTURE_DAEMON_FAIL:-0}" \
    DOCTOR_FIXTURE_REMOTE_CONTEXT="${DOCTOR_FIXTURE_REMOTE_CONTEXT:-0}" \
    DOCTOR_FIXTURE_OOM_SERVICE="${DOCTOR_FIXTURE_OOM_SERVICE:-}" \
    DOCTOR_FIXTURE_UNHEALTHY_SERVICE="${DOCTOR_FIXTURE_UNHEALTHY_SERVICE:-}" \
    DOCTOR_FIXTURE_STARTING_SERVICE="${DOCTOR_FIXTURE_STARTING_SERVICE:-}" \
    DOCTOR_FIXTURE_DB_FAIL="${DOCTOR_FIXTURE_DB_FAIL:-0}" \
    DOCTOR_FIXTURE_ANYTHING_PING_FAIL="${DOCTOR_FIXTURE_ANYTHING_PING_FAIL:-0}" \
    DOCTOR_FIXTURE_ANYTHING_AUTH_FAIL="${DOCTOR_FIXTURE_ANYTHING_AUTH_FAIL:-0}" \
    DOCTOR_FIXTURE_EMPTY_WORKSPACE="${DOCTOR_FIXTURE_EMPTY_WORKSPACE:-0}" \
    DOCTOR_FIXTURE_WORKFLOW_FAIL="${DOCTOR_FIXTURE_WORKFLOW_FAIL:-0}" \
    DOCTOR_FIXTURE_N8N_CODE_FAIL="${DOCTOR_FIXTURE_N8N_CODE_FAIL:-0}" \
    DOCTOR_FIXTURE_ADAPTER_FAIL="${DOCTOR_FIXTURE_ADAPTER_FAIL:-0}" \
    DOCTOR_FIXTURE_PROVIDER_FAIL="${DOCTOR_FIXTURE_PROVIDER_FAIL:-0}" \
    DOCTOR_FIXTURE_CRISP_FAIL="${DOCTOR_FIXTURE_CRISP_FAIL:-0}" \
    DOCTOR_FIXTURE_WEBHOOK_FAIL="${DOCTOR_FIXTURE_WEBHOOK_FAIL:-0}" \
    DOCTOR_FIXTURE_DELAY_N8N_SECONDS="${DOCTOR_FIXTURE_DELAY_N8N_SECONDS:-0}" \
    DOCTOR_FIXTURE_DELAY_ANYTHING_SECONDS="${DOCTOR_FIXTURE_DELAY_ANYTHING_SECONDS:-0}" \
    DOCTOR_FIXTURE_DELAY_EXTERNAL_SECONDS="${DOCTOR_FIXTURE_DELAY_EXTERNAL_SECONDS:-0}" \
    DOCTOR_FIXTURE_MATERIALS_MISMATCH="${DOCTOR_FIXTURE_MATERIALS_MISMATCH:-0}" \
    DOCTOR_FIXTURE_STDIN_PROBE="${DOCTOR_FIXTURE_STDIN_PROBE:-0}" \
    CRISPAI_LOGS_SYSTEMD_TEST=1 \
    CRISPAI_LOGS_SYSTEMD_DIR="$SYSTEMD_DIR" \
    "$@"
}

invoke() {
  : > "$OUT"; : > "$ERR"; : > "$FIXTURE_LOG"
  if [[ "${DOCTOR_TEST_PRESERVE_HEARTBEAT:-0}" != 1 ]]; then
    jq -M -n --argjson now "$(date -u '+%s%3N')" \
      '{schema_version:1,started_at:($now - 10),completed_at:$now}' \
      > "${DEPLOY}/data/runtime/scheduler-health.json"
    chmod 0600 "${DEPLOY}/data/runtime/scheduler-health.json"
  fi
  LAST_RC=0
  fixture_env "$DOCTOR" --deploy-dir "$DEPLOY" --json "$@" > "$OUT" 2> "$ERR" || LAST_RC=$?
}

business_hash() {
  (
    cd -- "$DEPLOY"
    find .env config knowledge data/runtime -type f ! -type l ! -name scheduler-health.json -print0 \
      | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum | awk '{print $1}'
  )
}

write_binding_state() {
  local env_file="${DEPLOY}/.env" binding_file="${TEST_ROOT}/binding.bin" binding state_key website_secret plugin_secret
  website_secret=$(env_get "$env_file" CRISP_WEBSITE_HOOK_SECRET 2>/dev/null || true)
  plugin_secret=$(env_get "$env_file" CRISP_PLUGIN_SIGNING_SECRET 2>/dev/null || true)
  website_secret=${website_secret:-not-configured}; plugin_secret=${plugin_secret:-not-configured}
  # n8n/runtime.js connectionBinding(): 七个字段用 NUL 分隔，结尾无 NUL。
  {
    printf '%s\0' \
      "$(env_get "$env_file" CRISP_WEBSITE_ID)" \
      "$(env_get "$env_file" CRISP_AUTH_B64)" \
      "$(env_get "$env_file" CRISP_HOOK_MODE)" \
      "$website_secret" \
      "$plugin_secret" \
      "$(env_get "$env_file" PUBLIC_WEBHOOK_URL)"
    printf '%s' "$(env_get "$env_file" CRISP_API_BASE_URL)"
  } > "$binding_file"
  binding=$(sha256sum "$binding_file" | awk '{print $1}')
  state_key=$(printf '%s\0%s' website-doctor-fixture session_doctor_fixture | sha256sum | awk '{print $1}')
  jq -M -n --arg binding "$binding" --argjson now "$(date -u '+%s%3N')" '{
    schema_version:2,website_id:"website-doctor-fixture",session_id:"session_doctor_fixture",
    mode:"human",generation:7,resume_at:null,pause_reason:"operator_message",
    last_human_at:$now,human_event_id:"human-fixture",control_watermark:$now,sequence:3,
    welcome_sent:true,menu_node:null,offers:{},cooldowns:{},jobs:[],outgoing:{},worker:null,
    uncertain_events:[],pending_feedback:null,updated_at:$now,
    observations:{binding:$binding,hook_received_at:($now - 1000),ai_reply_sent_at:$now}
  }' > "${DEPLOY}/data/runtime/session-${state_key}.json"
  chmod 0600 "${DEPLOY}/data/runtime/session-${state_key}.json"
}

prepare_fixture() {
  local name secret digest launcher doc_hash version timer_digest materials_stage
  mkdir -p "$DEPLOY"/{config,knowledge/kb_default/sources,data/runtime,data/n8n,data/anythingllm,data/analytics,backups/manual,logs,tmp,n8n,scripts} "$SYSTEMD_DIR"
  for name in VERSION docker-compose.yml get.sh manage.sh install.sh update.sh uninstall.sh; do
    cp -p -- "${PROJECT_ROOT}/${name}" "${DEPLOY}/${name}"
  done
  for name in workflow.json runtime.js runtime-cli.js build-workflow.js web-chat.js; do
    cp -p -- "${PROJECT_ROOT}/n8n/${name}" "${DEPLOY}/n8n/${name}"
  done
  node "${DEPLOY}/n8n/build-workflow.js"
  jq -M '.active=true' "${DEPLOY}/n8n/workflow.json" > "${DEPLOY}/n8n/workflow.json.new"
  mv -f -- "${DEPLOY}/n8n/workflow.json.new" "${DEPLOY}/n8n/workflow.json"
  for name in common.sh doctor.sh healthcheck.sh provider.sh configuration.sh provider-adapter.js launcher.sh bootstrap.sh \
    wizard.sh package-release.sh knowledge.sh migration.sh crisp-settings.sh full-backup.sh archive-guard.py \
    backup.sh restore.sh analytics.sh snapshot.sh rollback.sh menu-ui.sh materials.sh logs.sh log-redact.py; do
    cp -p -- "${PROJECT_ROOT}/scripts/${name}" "${DEPLOY}/scripts/${name}"
  done
  for name in runtime provider keyword menu handoff tags feedback logging; do
    cp -p -- "${PROJECT_ROOT}/config/${name}.yaml.example" "${DEPLOY}/config/${name}.yaml"
  done
  cp -p -- "${PROJECT_ROOT}/config/prompt.md.example" "${DEPLOY}/config/prompt.md"
  cp -p -- "${PROJECT_ROOT}/config/app.yaml" "${DEPLOY}/config/app.yaml"
  cp -p -- "${PROJECT_ROOT}/config/Caddyfile.example" "${DEPLOY}/config/Caddyfile.example"
  jq -M '.applied_revision=.revision' "${DEPLOY}/config/runtime.yaml" > "${DEPLOY}/config/runtime.yaml.new"
  mv -f -- "${DEPLOY}/config/runtime.yaml.new" "${DEPLOY}/config/runtime.yaml"
  jq -M '.provider.base_url="https://provider.example.test/v1" |
    .provider.model="model-doctor-fixture" | .provider.api_mode="responses" |
    .provider.capabilities.responses=true' "${DEPLOY}/config/provider.yaml" > "${DEPLOY}/config/provider.yaml.new"
  mv -f -- "${DEPLOY}/config/provider.yaml.new" "${DEPLOY}/config/provider.yaml"

  cp -p -- "${PROJECT_ROOT}/.env.example" "${DEPLOY}/.env"
  # shellcheck source=scripts/common.sh disable=SC1091
  source "${PROJECT_ROOT}/scripts/common.sh"
  env_set "${DEPLOY}/.env" DEPLOY_DIR "$DEPLOY"
  env_set "${DEPLOY}/.env" N8N_PORT 5678
  env_set "${DEPLOY}/.env" ANYTHINGLLM_PORT 3001
  env_set "${DEPLOY}/.env" WEBHOOK_ACCESS_MODE external_proxy
  env_set "${DEPLOY}/.env" PUBLIC_WEBHOOK_URL 'https://support.example.test/'
  env_set "${DEPLOY}/.env" WEBHOOK_PRODUCTION_URL 'https://support.example.test/webhook/crisp-webhook'
  env_set "${DEPLOY}/.env" AI_API_PROBE_BASE_URL 'https://provider.example.test/v1'
  env_set "${DEPLOY}/.env" AI_API_BASE_URL 'https://provider.example.test/v1'
  env_set "${DEPLOY}/.env" AI_ANYTHINGLLM_BASE_URL 'http://provider-adapter:8787/v1'
  env_set "${DEPLOY}/.env" AI_MODEL 'model-doctor-fixture'
  env_set "${DEPLOY}/.env" AI_API_MODE responses
  env_set "${DEPLOY}/.env" AI_CUSTOM_HEADERS_JSON '{}'
  env_set "${DEPLOY}/.env" ANYTHINGLLM_WORKSPACE crisp-support
  env_set "${DEPLOY}/.env" CRISP_WEBSITE_ID website-doctor-fixture
  env_set "${DEPLOY}/.env" CRISP_TOKEN_TIER website
  env_set "${DEPLOY}/.env" CRISP_HOOK_MODE website
  env_set "${DEPLOY}/.env" CRISP_API_BASE_URL 'https://api.crisp.chat/v1'
  for name in N8N_ENCRYPTION_KEY POSTGRES_PASSWORD ANYTHINGLLM_AUTH_TOKEN ANYTHINGLLM_JWT_SECRET \
    ANYTHINGLLM_SIG_KEY ANYTHINGLLM_SIG_SALT ANYTHINGLLM_API_KEY AI_API_KEY \
    CRISP_TOKEN_IDENTIFIER CRISP_TOKEN_KEY CRISP_AUTH_B64 CRISP_WEBSITE_HOOK_SECRET; do
    secret="doctor-fixture-${name,,}-do-not-print"
    env_set "${DEPLOY}/.env" "$name" "$secret"
  done
  # Website 模式下 Plugin Secret 可以为空；Compose 会以 :-not-configured 展开到容器。
  env_unset "${DEPLOY}/.env" CRISP_PLUGIN_SIGNING_SECRET
  env_set "${DEPLOY}/.env" CRISP_AUTH_B64 "$(printf '%s:%s' \
    "$(env_get "${DEPLOY}/.env" CRISP_TOKEN_IDENTIFIER)" \
    "$(env_get "${DEPLOY}/.env" CRISP_TOKEN_KEY)" | base64 | tr -d '\n')"
  chmod 0600 "${DEPLOY}/.env"
  printf '%s' "$(env_get "${DEPLOY}/.env" POSTGRES_PASSWORD)" > "$DB_PASSWORD_FILE"
  printf '%s' "$(env_get "${DEPLOY}/.env" POSTGRES_PASSWORD)" > "$N8N_DB_PASSWORD_FILE"
  chmod 0600 "$DB_PASSWORD_FILE" "$N8N_DB_PASSWORD_FILE"
  jq -M -n \
    --arg base "$(env_get "${DEPLOY}/.env" AI_API_BASE_URL)" \
    --arg key "$(env_get "${DEPLOY}/.env" AI_API_KEY)" \
    --arg model "$(env_get "${DEPLOY}/.env" AI_MODEL)" \
    --arg mode "$(env_get "${DEPLOY}/.env" AI_API_MODE)" \
    --arg headers "$(env_get "${DEPLOY}/.env" AI_CUSTOM_HEADERS_JSON)" \
    --arg internal "$(env_get "${DEPLOY}/.env" AI_ANYTHINGLLM_BASE_URL)" \
    --arg website "$(env_get "${DEPLOY}/.env" CRISP_WEBSITE_ID)" \
    --arg crisp_base "$(env_get "${DEPLOY}/.env" CRISP_API_BASE_URL)" \
    --arg tier "$(env_get "${DEPLOY}/.env" CRISP_TOKEN_TIER)" \
    --arg auth "$(env_get "${DEPLOY}/.env" CRISP_AUTH_B64)" \
    --arg hook "$(env_get "${DEPLOY}/.env" CRISP_HOOK_MODE)" \
    --arg website_secret "$(env_get "${DEPLOY}/.env" CRISP_WEBSITE_HOOK_SECRET)" \
    --arg plugin_secret 'not-configured' \
    --arg public_url "$(env_get "${DEPLOY}/.env" PUBLIC_WEBHOOK_URL)" \
    --arg anything_key "$(env_get "${DEPLOY}/.env" ANYTHINGLLM_API_KEY)" \
    --arg workspace "$(env_get "${DEPLOY}/.env" ANYTHINGLLM_WORKSPACE)" \
    --arg vision "$(env_get "${DEPLOY}/.env" AI_SUPPORTS_VISION)" \
    '{"provider-adapter":[$base,$key,$model,$mode,$headers],
      anythingllm:[$internal,$key,$model],
      n8n:[$website,$crisp_base,$tier,$auth,$hook,$website_secret,$plugin_secret,$public_url,
        $anything_key,$workspace,$base,$key,$model,$mode,$headers,$vision]}' > "$RUNTIME_ENV_FILE"
  chmod 0600 "$RUNTIME_ENV_FILE"

  printf '虚构知识：雨天测试码为蓝色。\n' > "${DEPLOY}/knowledge/kb_default/sources/doc_1111111111111111.md"
  doc_hash=$(sha256sum "${DEPLOY}/knowledge/kb_default/sources/doc_1111111111111111.md" | awk '{print $1}')
  jq -M -n --arg hash "$doc_hash" '{schema_version:2,revision:1,libraries:[{
    id:"kb_default",name:"默认知识库",enabled:true,revision:1,status:"indexed",last_sync:"fixture",error:null,
    documents:[{id:"doc_1111111111111111",name:"fixture.md",source:"sources/doc_1111111111111111.md",
      projection:"fixture.md",sha256:$hash,index_status:"indexed"}]
  }]}' > "${DEPLOY}/knowledge/catalog.json"
  jq -M -n --arg hash "$doc_hash" '{version:1,files:{"fixture.md":{sha256:$hash,locations:["custom-documents/fixture.json"]}},pending_files:{},garbage_locations:[]}' \
    > "${DEPLOY}/data/knowledge-manifest.json"
  # v1.2 runtime 只读取已验证的生效资料投影。测试夹具从同一生产构建函数生成，
  # 不手写一个可能绕过 schema/哈希约束的假投影。
  chmod 0640 "${DEPLOY}/config/"{runtime,handoff,keyword,menu,tags,feedback}.yaml
  chmod 0600 "${DEPLOY}/config/prompt.md" "${DEPLOY}/knowledge/catalog.json" \
    "${DEPLOY}/knowledge/kb_default/sources/doc_1111111111111111.md"
  materials_stage=$(mktemp -d "${DEPLOY}/tmp/materials-doctor-fixture.XXXXXXXX")
  # shellcheck source=scripts/materials.sh disable=SC1091
  source "${DEPLOY}/scripts/materials.sh"
  materials_prepare_candidate "$DEPLOY" "$materials_stage" 1 applied >/dev/null
  install -m 0640 -- "${materials_stage}/materials-applied.json" "${DEPLOY}/config/materials-applied.json"
  find "$materials_stage" -depth -delete
  printf 'fixture backup\n' > "${DEPLOY}/backups/manual/fixture.txt"
  : > "${DEPLOY}/data/analytics/events.jsonl"

  version=$(<"${DEPLOY}/VERSION")
  printf 'ai-support\nstate=ready\ninstalled_version=%s\n' "$version" > "${DEPLOY}/.crisp-ai-installation"
  chmod 0600 "${DEPLOY}/.crisp-ai-installation"
  launcher="${TEST_ROOT}/crispai"
  digest=$(printf '%s' "$DEPLOY" | sha256sum | awk '{print $1}')
  printf '#!/usr/bin/env bash\n# crispai-launcher: ai-support/v1\n# crispai-target-sha256: %s\nexit 0\n' "$digest" > "$launcher"
  chmod 0755 "$launcher"
  printf '%s\n' "$launcher" > "${DEPLOY}/config/.crispai-launcher"
  chmod 0600 "${DEPLOY}/config/.crispai-launcher"
  timer_digest=$(printf '%s' "$DEPLOY" | sha256sum | awk '{print $1}')
  printf 'ai-support-log-maintenance/v1\ndeploy_sha256=%s\nunit=crispai-log-maintenance-%s\n' \
    "$timer_digest" "${timer_digest:0:16}" > "${DEPLOY}/config/.crispai-log-timer"
  chmod 0600 "${DEPLOY}/config/.crispai-log-timer"
  for name in service timer; do
    printf '# ai-support-log-maintenance/v1\n# deploy-sha256: %s\n' "$timer_digest" \
      > "${SYSTEMD_DIR}/crispai-log-maintenance-${timer_digest:0:16}.${name}"
    chmod 0644 "${SYSTEMD_DIR}/crispai-log-maintenance-${timer_digest:0:16}.${name}"
  done
  chmod 0700 "${DEPLOY}/data/runtime" "${DEPLOY}/tmp"
  chmod 0770 "${DEPLOY}/data/analytics"
  chmod 0660 "${DEPLOY}/data/analytics/events.jsonl"
  chown -R 1000:1000 "${DEPLOY}/data/runtime" "${DEPLOY}/data/n8n" "${DEPLOY}/data/anythingllm"
  chmod 0600 "${DEPLOY}/config/prompt.md"
  : > "$STOPPED_FILE"
  write_binding_state
  jq -M -n --argjson now "$(date -u '+%s%3N')" \
    '{schema_version:1,started_at:($now - 10),completed_at:$now}' \
    > "${DEPLOY}/data/runtime/scheduler-health.json"
  chmod 0600 "${DEPLOY}/data/runtime/scheduler-health.json"
}

prepare_fixture
chmod 0755 "$DOCTOR" "$FIXTURE_BIN/docker" "$FIXTURE_BIN/curl" "$FIXTURE_BIN/systemctl"

before=$(business_hash)
SESSION_FILE=$(find "${DEPLOY}/data/runtime" -maxdepth 1 -type f -name 'session-*.json' -print -quit)
ORIGINAL_WEBSITE_HOOK_SECRET=$(env_get "${DEPLOY}/.env" CRISP_WEBSITE_HOOK_SECRET)
ORIGINAL_DB_PASSWORD=$(env_get "${DEPLOY}/.env" POSTGRES_PASSWORD)

# install.sh/update.sh 使用的 legacy --application 门禁必须只验证本地接线，
# 不能在每次安装或回滚健康判断中产生付费模型请求。
: > "$FIXTURE_LOG"
health_rc=0
env PATH="${FIXTURE_BIN}:${ORIGINAL_PATH}" \
  DOCTOR_FIXTURE_DEPLOY="$DEPLOY" DOCTOR_FIXTURE_LOG="$FIXTURE_LOG" \
  DOCTOR_FIXTURE_STOPPED_FILE="$STOPPED_FILE" \
  DOCTOR_FIXTURE_DB_PASSWORD_FILE="$DB_PASSWORD_FILE" \
  DOCTOR_FIXTURE_N8N_DB_PASSWORD_FILE="$N8N_DB_PASSWORD_FILE" \
  DOCTOR_FIXTURE_RUNTIME_ENV_FILE="$RUNTIME_ENV_FILE" \
  CRISPAI_LOGS_SYSTEMD_TEST=1 \
  CRISPAI_LOGS_SYSTEMD_DIR="$SYSTEMD_DIR" \
  "${DEPLOY}/scripts/healthcheck.sh" --deploy-dir "$DEPLOY" --application \
  > "${TEST_ROOT}/health-application.out" 2> "${TEST_ROOT}/health-application.err" || health_rc=$?
(( health_rc == 0 )) || fail "安装/更新 application 健康门禁失败（${health_rc}）"
! grep -Eq 'provider\.example\.test|/chat(/|$)' "$FIXTURE_LOG" \
  || fail '安装/更新 application 健康门禁执行了模型推理'
[[ "$before" == "$(business_hash)" ]] || fail '安装/更新 application 健康门禁改动了业务状态'
pass '安装与更新的 healthcheck --application 不执行付费推理'

cp -p -- "${DEPLOY}/config/.crispai-launcher" "${TEST_ROOT}/launcher-marker.saved"
cp -p -- "${DEPLOY}/.crisp-ai-installation" "${TEST_ROOT}/installation-marker.saved"
mv -- "${DEPLOY}/config/.crispai-launcher" "${TEST_ROOT}/launcher-marker.pending"
sed -i 's/^state=.*/state=installing/' "${DEPLOY}/.crisp-ai-installation"
invoke --local --installation-in-progress
(( LAST_RC == 2 )) || fail '安装中尚未登记自定义入口时不应检查其他实例的默认入口'
assert_result installation.launcher SKIP
pass '安装门禁尚无入口归属记录时不抢查默认路径，创建入口仍交原安装器校验'

printf '#!/usr/bin/env bash\n# crispai-launcher: ai-support/v1\n# crispai-target-sha256: unrelated-instance\nexit 0\n' \
  > "${TEST_ROOT}/foreign-crispai"
chmod 0755 "${TEST_ROOT}/foreign-crispai"
printf '%s\n' "${TEST_ROOT}/foreign-crispai" > "${DEPLOY}/config/.crispai-launcher"
chmod 0600 "${DEPLOY}/config/.crispai-launcher"
invoke --local --installation-in-progress
(( LAST_RC == 1 )) || fail '安装中已有明确入口记录的错误归属仍必须失败'
assert_result installation.launcher FAIL
cp -p -- "${TEST_ROOT}/launcher-marker.saved" "${DEPLOY}/config/.crispai-launcher"
cp -p -- "${TEST_ROOT}/installation-marker.saved" "${DEPLOY}/.crisp-ai-installation"
[[ "$before" == "$(business_hash)" ]] || fail '入口时序检查未恢复原业务状态'
pass '安装中已登记入口指向他人实例仍拒绝，不放宽归属安全校验'

invoke --local
(( LAST_RC == 0 )) || fail "健康 local 自检退出码应为 0，实际 ${LAST_RC}"
jq -e '.scope == "local" and .summary.fail == 0 and .summary.warn == 0' "$OUT" >/dev/null || fail 'local JSON 摘要错误'
jq -e '([.results[].id] | length) == ([.results[].id] | unique | length)' "$OUT" >/dev/null \
  || fail '一次自检存在重复结果或重复组件请求'
jq -e 'all(.results[]; (.state == "checked" or .state == "not_applicable") and
  has("remediation") and (.duration_ms | type == "number" and . >= 0))' "$OUT" >/dev/null \
  || fail '结构化结果缺少状态、修复建议或有效耗时'
assert_result database.authentication PASS
assert_result database.n8n_binding PASS
assert_result anything.workspace PASS
assert_result knowledge.catalog PASS
assert_result n8n.runtime PASS
assert_result provider.adapter PASS
assert_result provider.adapter_binding PASS
assert_result anything.provider_binding PASS
assert_result n8n.runtime_binding PASS
assert_result materials.applied PASS
assert_result materials.runtime_binding PASS
assert_result runtime.scheduler PASS
assert_result crisp.api SKIP
! grep -q 'https://' "$FIXTURE_LOG" || fail 'local 自检访问了外部 URL'
[[ "$before" == "$(business_hash)" ]] || fail 'local 自检改动了配置、知识或会话状态'
pass 'local 自检覆盖组件接线且不访问外部、不扰动业务状态'

# 离线门禁仍必须从受管 Compose 原文静态核对日志与 execution 接线；
# 只跳过运行中容器回读，不能因 `--no-docker` 把合法配置误报为损坏。
invoke --offline
(( LAST_RC == 0 )) || fail "健康 offline 自检退出码应为 0，实际 ${LAST_RC}"
assert_result logs.policy PASS
assert_result logs.capacity SKIP
assert_result logs.n8n_execution SKIP
! grep -q '^docker ' "$FIXTURE_LOG" || fail 'offline 日志自检访问了 Docker'
[[ "$before" == "$(business_hash)" ]] || fail 'offline 自检改动了业务状态'
pass 'offline 静态核对日志/n8n配置，运行容器项明确跳过而不误报故障'

# 可编辑原文不是运行时权威源。它发生变化或损坏时，应保留并证明上一有效
# 投影仍在运行；只有投影本身/运行中挂载偏离才是关键故障。
prompt_saved="${TEST_ROOT}/prompt.saved.md"
cp -p -- "${DEPLOY}/config/prompt.md" "$prompt_saved"
printf '\n尚未应用的虚构编辑。\n' >> "${DEPLOY}/config/prompt.md"
invoke --local
(( LAST_RC == 2 )) || fail '有效原文待应用时应警告而非读取为当前运行配置'
assert_result materials.applied WARN
assert_result materials.runtime_binding PASS
cp -p -- "$prompt_saved" "${DEPLOY}/config/prompt.md"

chmod 0644 "${DEPLOY}/config/prompt.md"
invoke --local
(( LAST_RC == 2 )) || fail '可编辑原文权限损坏但有效投影存在时应警告'
assert_result materials.applied WARN
assert_result materials.runtime_binding PASS
cp -p -- "$prompt_saved" "${DEPLOY}/config/prompt.md"

projection_saved="${TEST_ROOT}/materials-applied.saved.json"
cp -p -- "${DEPLOY}/config/materials-applied.json" "$projection_saved"
jq '.state="applying"' "$projection_saved" > "${DEPLOY}/config/materials-applied.json"
chmod 0640 "${DEPLOY}/config/materials-applied.json"
invoke --local
(( LAST_RC == 1 )) || fail '未完成 applying 投影不得通过运行时健康门禁'
assert_result materials.applied FAIL
assert_result materials.runtime_binding SKIP
cp -p -- "$projection_saved" "${DEPLOY}/config/materials-applied.json"

export DOCTOR_FIXTURE_MATERIALS_MISMATCH=1
invoke --local
(( LAST_RC == 1 )) || fail 'n8n 仍挂载旧资料投影时应退出 1'
assert_result materials.applied PASS
assert_result materials.runtime_binding FAIL
unset DOCTOR_FIXTURE_MATERIALS_MISMATCH
[[ "$before" == "$(business_hash)" ]] || fail '资料投影自检没有恢复原业务状态'
pass '资料 doctor 区分原文待应用/损坏、有效投影、applying 与运行代偏离'

# catalog 有启用文档但 manifest 映射和 workspace 同时为空时，两个 location
# 集合都会是 []；必须在集合比较前拒绝缺失的逐文档 hash/location 映射。
manifest_saved="${TEST_ROOT}/knowledge-manifest.saved.json"
cp -p -- "${DEPLOY}/data/knowledge-manifest.json" "$manifest_saved"
jq '.files={}' "$manifest_saved" > "${DEPLOY}/data/knowledge-manifest.json"
export DOCTOR_FIXTURE_EMPTY_WORKSPACE=1
invoke --local
(( LAST_RC == 1 )) || fail '启用文档缺失 manifest 映射且 workspace 为空时应退出 1'
assert_result anything.workspace PASS
assert_result knowledge.catalog FAIL
grep -q '索引映射' "$OUT" || fail '缺失逐文档映射未给出准确故障摘要'

doc_hash=$(jq -M -r '.libraries[] | select(.enabled) | .documents[0].sha256' "${DEPLOY}/knowledge/catalog.json")
jq -M --arg hash "$doc_hash" --argjson now "$(date -u '+%s')" '
  .files={} | .pending_files={"fixture.md":{
    sha256:$hash,locations:["custom-documents/pending-fixture.json"],old_locations:[],started_at:$now
  }}' "$manifest_saved" > "${DEPLOY}/data/knowledge-manifest.json"
invoke --local
(( LAST_RC == 2 )) || fail '同 hash 且有 location 的正常 pending 文档应退出警告 2'
assert_result knowledge.catalog WARN
grep -q '仍在服务端对账' "$OUT" || fail '正常 pending 未给出处理中说明'

jq -M --arg hash "$doc_hash" --argjson now "$(date -u '+%s')" '
  .files={} | .pending_files={"unrelated.md":{
    sha256:$hash,locations:["custom-documents/unrelated.json"],old_locations:[],started_at:$now
  }}' "$manifest_saved" > "${DEPLOY}/data/knowledge-manifest.json"
invoke --local
(( LAST_RC == 1 )) || fail '无关 pending 不得掩盖目标启用文档映射缺失'
assert_result knowledge.catalog FAIL
unset DOCTOR_FIXTURE_EMPTY_WORKSPACE
cp -p -- "$manifest_saved" "${DEPLOY}/data/knowledge-manifest.json"
pass '逐文档区分有效 pending 与缺失映射，无关 pending 不掩盖损坏'

# 在线安装与管理菜单都在真实终端内调用 doctor。docker compose exec -T 仍会
# 转发 stdin；若 timeout 将其放入后台进程组且探针未关闭 stdin，会因 SIGTTIN
# 停住直到 25/15 秒上限。用真实 PTY 和主动读取 stdin 的夹具锁定该问题。
command -v script >/dev/null 2>&1 || fail 'PTY 回归需要 util-linux script'
: > "$OUT"; : > "$ERR"; : > "$FIXTURE_LOG"
printf -v pty_command '%q ' "$DOCTOR" --deploy-dir "$DEPLOY" --local --json --timeout 30
printf -v quoted_out '%q' "$OUT"
printf -v quoted_err '%q' "$ERR"
pty_command+=" >${quoted_out} 2>${quoted_err}"
export DOCTOR_FIXTURE_STDIN_PROBE=1
pty_started=$SECONDS
pty_rc=0
fixture_env script -qefc "$pty_command" /dev/null >/dev/null || pty_rc=$?
pty_elapsed=$((SECONDS-pty_started))
unset DOCTOR_FIXTURE_STDIN_PROBE
(( pty_rc == 0 )) || fail "PTY 中的无输入容器探针被挂起或失败（${pty_rc}）"
# 完整本地 doctor 现在还会校验资料投影；无 PTY 的同一 fixture 通常约 9 秒。
# 20 秒仍显著低于 workflow 25 秒的 SIGTTIN 超时，并继续要求两个探针真实到达。
(( pty_elapsed < 20 )) || fail "PTY 中的容器探针疑似等待 stdin（${pty_elapsed} 秒）"
assert_result n8n.workflow PASS
assert_result provider.adapter PASS
grep -q 'export:workflow' "$FIXTURE_LOG" || fail 'PTY 回归未执行 workflow 导出探针'
grep -q 'provider-adapter:8787/healthz' "$FIXTURE_LOG" || fail 'PTY 回归未执行 adapter 网络探针'
pass 'PTY 安装入口中的 workflow/adapter 探针显式关闭 stdin，不受 SIGTTIN 假故障影响'

# 运行代核对遵循 Compose 对空非当前 Hook Secret 的 :- 默认展开语义。
[[ -z "$(env_get "${DEPLOY}/.env" CRISP_PLUGIN_SIGNING_SECRET 2>/dev/null || true)" ]] \
  || fail 'Website fixture 应保留空的非当前 Plugin Secret'
assert_result n8n.runtime_binding PASS
pass '空的非当前 Hook Secret 与 Compose not-configured 容器展开值一致'

workflow_saved="${TEST_ROOT}/workflow.saved.json"
cp -p -- "${DEPLOY}/n8n/workflow.json" "$workflow_saved"
jq '.meta.runtimeFileSha256="stale-runtime-file-hash"' "${DEPLOY}/n8n/workflow.json" \
  > "${DEPLOY}/n8n/workflow.json.new"
mv -f -- "${DEPLOY}/n8n/workflow.json.new" "${DEPLOY}/n8n/workflow.json"
invoke --local
(( LAST_RC == 1 )) || fail 'workflow 原文件 hash metadata 偏离应退出 1'
assert_result n8n.workflow FAIL
cp -p -- "$workflow_saved" "${DEPLOY}/n8n/workflow.json"
pass 'n8n workflow 同时核对 runtime 原文件 hash、规范化嵌入 hash 与 Code 前缀'

invoke
(( LAST_RC == 0 )) || fail "健康 default 自检退出码应为 0，实际 ${LAST_RC}"
assert_result crisp.api PASS
assert_result webhook.public PASS
assert_result crisp.observations PASS
assert_result provider.inference SKIP
! grep -q 'provider.example.test' "$FIXTURE_LOG" || fail 'default 自检调用了付费 Provider'
[[ "$before" == "$(business_hash)" ]] || fail 'default 自检改动了配置、知识或会话状态'
pass 'default 仅做 Crisp/公网只读检查并使用当前绑定 observation'

# Compose 把缺失/空的非当前 Hook Secret 投影成 not-configured；显式写入同一
# sentinel 不得让已有可信 observation 假失效。
env_set "${DEPLOY}/.env" CRISP_PLUGIN_SIGNING_SECRET not-configured
invoke
(( LAST_RC == 0 )) || fail '显式非当前 Hook sentinel 应与缺失值绑定等价'
assert_result crisp.observations PASS
env_unset "${DEPLOY}/.env" CRISP_PLUGIN_SIGNING_SECRET
pass '缺失/空与显式 not-configured 使用同一 runtime observation 绑定'

export DOCTOR_FIXTURE_CRISP_FAIL=1
invoke
(( LAST_RC == 1 )) || fail '已配置 Crisp 凭据返回 401 时默认自检应明确失败'
assert_result crisp.api FAIL
unset DOCTOR_FIXTURE_CRISP_FAIL
pass '当前 Crisp 401/403 认证故障不会降级成待接入警告或沿用旧绿灯'

# local-ready 是外部待接入事实，不应让本地安装/升级健康门禁失败。
sed -i 's/^state=.*/state=local-ready/' "${DEPLOY}/.crisp-ai-installation"
: > "$FIXTURE_LOG"
health_rc=0
env PATH="${FIXTURE_BIN}:${ORIGINAL_PATH}" \
  DOCTOR_FIXTURE_DEPLOY="$DEPLOY" DOCTOR_FIXTURE_LOG="$FIXTURE_LOG" \
  DOCTOR_FIXTURE_STOPPED_FILE="$STOPPED_FILE" \
  DOCTOR_FIXTURE_DB_PASSWORD_FILE="$DB_PASSWORD_FILE" \
  DOCTOR_FIXTURE_N8N_DB_PASSWORD_FILE="$N8N_DB_PASSWORD_FILE" \
  DOCTOR_FIXTURE_RUNTIME_ENV_FILE="$RUNTIME_ENV_FILE" \
  CRISPAI_LOGS_SYSTEMD_TEST=1 \
  CRISPAI_LOGS_SYSTEMD_DIR="$SYSTEMD_DIR" \
  "${DEPLOY}/scripts/healthcheck.sh" --deploy-dir "$DEPLOY" --application \
  > "${TEST_ROOT}/health-local-ready.out" 2> "${TEST_ROOT}/health-local-ready.err" || health_rc=$?
(( health_rc == 0 )) || fail 'local-ready 被安装/升级 application 门禁误判为回滚条件'
invoke --local
(( LAST_RC == 0 )) || fail 'local 自检不应把合法 local-ready 当故障或警告'
invoke
(( LAST_RC == 2 )) || fail 'default 自检应明确报告 local-ready 外部待接入警告'
assert_result installation.marker WARN
sed -i 's/^state=.*/state=ready/' "${DEPLOY}/.crisp-ai-installation"
pass 'local-ready 在本地门禁通过，在联网范围准确返回待接入警告 2'

# 同一历史 observation 在 Hook Secret 成组变化后必须失效，不能沿用旧绿灯；
# 新 Secret 仍满足当前 Website Hook 配置，因此本地配置本身保持有效。
# shellcheck source=scripts/common.sh disable=SC1091
source "${PROJECT_ROOT}/scripts/common.sh"
env_set "${DEPLOY}/.env" CRISP_WEBSITE_HOOK_SECRET 'doctor-fixture-changed-hook-secret-valid'
cp -p -- "$RUNTIME_ENV_FILE" "${TEST_ROOT}/observation-runtime-env.saved"
jq '.n8n[5]="doctor-fixture-changed-hook-secret-valid"' "$RUNTIME_ENV_FILE" \
  > "${RUNTIME_ENV_FILE}.new"
mv -f -- "${RUNTIME_ENV_FILE}.new" "$RUNTIME_ENV_FILE"
chmod 0600 "$RUNTIME_ENV_FILE"
invoke
(( LAST_RC == 2 )) || fail "旧绑定 observation 应产生警告退出码 2，实际 ${LAST_RC}"
assert_result crisp.observations WARN
jq -e '[.results[] | select(.id == "crisp.observations")] | length == 1' "$OUT" >/dev/null || fail 'observation 结果重复'
invoke --last
(( LAST_RC == 2 )) || fail '--last 应保留缓存警告退出码 2'
jq -e '.checked_at and .summary.warn > 0' "$OUT" >/dev/null || fail '--last 未返回有效缓存'
env_set "${DEPLOY}/.env" CRISP_WEBSITE_HOOK_SECRET "$ORIGINAL_WEBSITE_HOOK_SECRET"
cp -p -- "${TEST_ROOT}/observation-runtime-env.saved" "$RUNTIME_ENV_FILE"
pass 'Crisp observation 与当前七字段连接绑定一致，凭据变更后旧事实失效'

# 当前 .env 密码偏离运行中 PostgreSQL 时，不能借容器自身旧 POSTGRES_PASSWORD 假通过；
# 数据库改好而 n8n 仍持旧 env 时，也必须单独定位应用接线偏离。
env_set "${DEPLOY}/.env" POSTGRES_PASSWORD 'doctor-fixture-new-managed-password-do-not-print'
invoke --local
(( LAST_RC == 1 )) || fail '当前 .env 密码与运行数据库偏离应退出 1'
assert_result database.authentication FAIL
printf '%s' 'doctor-fixture-new-managed-password-do-not-print' > "$DB_PASSWORD_FILE"
invoke --local
(( LAST_RC == 1 )) || fail 'n8n 仍使用旧数据库密码应退出 1'
assert_result database.authentication PASS
assert_result database.n8n_binding FAIL
! grep -Fq 'doctor-fixture-new-managed-password-do-not-print' "$OUT" "$ERR" "$FIXTURE_LOG" \
  || fail '数据库诊断输出泄露当前受管密码'
env_set "${DEPLOY}/.env" POSTGRES_PASSWORD "$ORIGINAL_DB_PASSWORD"
printf '%s' "$ORIGINAL_DB_PASSWORD" > "$DB_PASSWORD_FILE"
printf '%s' "$ORIGINAL_DB_PASSWORD" > "$N8N_DB_PASSWORD_FILE"
pass '用当前受管密码经 backend 网络验证 PostgreSQL，并独立核对 n8n 实际凭据接线'

env_set "${DEPLOY}/.env" CRISP_WEBSITE_HOOK_SECRET not-configured
invoke --local
(( LAST_RC == 1 )) || fail '当前 Hook 模式缺少对应 Secret 应退出 1'
assert_result config.crisp_mode FAIL
env_set "${DEPLOY}/.env" CRISP_WEBSITE_HOOK_SECRET "$ORIGINAL_WEBSITE_HOOK_SECRET"
pass '本地自检按 Website/Plugin Hook 模式核对对应 Secret 与 Basic 派生值'

env_set "${DEPLOY}/.env" AI_MODEL 'model-runtime-diverged'
invoke --local
(( LAST_RC == 1 )) || fail 'Provider 模型运行环境偏离受管配置应退出 1'
assert_result provider.configuration FAIL
env_set "${DEPLOY}/.env" AI_MODEL model-doctor-fixture
pass 'Provider 地址、模型、协议、Header 名称和能力字段与运行环境成组对账'

empty_header_provider_saved="${TEST_ROOT}/provider-empty-header.saved.json"
empty_header_runtime_saved="${TEST_ROOT}/runtime-empty-header.saved.json"
cp -p -- "${DEPLOY}/config/provider.yaml" "$empty_header_provider_saved"
cp -p -- "$RUNTIME_ENV_FILE" "$empty_header_runtime_saved"
sed -i 's/^AI_CUSTOM_HEADERS_JSON=.*/AI_CUSTOM_HEADERS_JSON=/' "${DEPLOY}/.env"
jq '.provider.custom_header_names=null' "${DEPLOY}/config/provider.yaml" > "${DEPLOY}/config/provider.yaml.new"
mv -f -- "${DEPLOY}/config/provider.yaml.new" "${DEPLOY}/config/provider.yaml"
jq '."provider-adapter"[4]="" | .n8n[14]=""' "$RUNTIME_ENV_FILE" > "${RUNTIME_ENV_FILE}.new"
mv -f -- "${RUNTIME_ENV_FILE}.new" "$RUNTIME_ENV_FILE"
chmod 0600 "$RUNTIME_ENV_FILE"
invoke --local
(( LAST_RC == 0 )) || fail '旧实例的空自定义 Header 应等价于未配置而保持健康'
assert_result provider.configuration PASS
cp -p -- "$empty_header_provider_saved" "${DEPLOY}/config/provider.yaml"
cp -p -- "$empty_header_runtime_saved" "$RUNTIME_ENV_FILE"
env_set "${DEPLOY}/.env" AI_CUSTOM_HEADERS_JSON '{}'
pass '空 AI_CUSTOM_HEADERS_JSON 与 null Header 名单按无自定义 Header 兼容'

runtime_env_saved="${TEST_ROOT}/running-container-env.saved.json"
cp -p -- "$RUNTIME_ENV_FILE" "$runtime_env_saved"
jq '."provider-adapter"[1]="stale-adapter-key" |
    .anythingllm[1]="stale-anything-key" | .n8n[3]="stale-crisp-auth"' \
  "$RUNTIME_ENV_FILE" > "${RUNTIME_ENV_FILE}.new"
mv -f -- "${RUNTIME_ENV_FILE}.new" "$RUNTIME_ENV_FILE"
chmod 0600 "$RUNTIME_ENV_FILE"
invoke --local
(( LAST_RC == 1 )) || fail '运行中容器仍持旧秘密时应退出 1'
assert_result provider.configuration PASS
assert_result provider.adapter_binding FAIL
assert_result anything.provider_binding FAIL
assert_result n8n.runtime_binding FAIL
assert_result provider.adapter PASS
cp -p -- "$runtime_env_saved" "$RUNTIME_ENV_FILE"
pass '运行容器旧代 Key 与 n8n Crisp 凭据不会被 /healthz 假绿掩盖'

# 无客户消息时仍由独立调度心跳证明扫描活性；停滞不得以“没有流量”掩盖。
jq -M -n --argjson now "$(date -u '+%s%3N')" \
  '{schema_version:1,started_at:($now - 50000),completed_at:($now - 45000)}' \
  > "${DEPLOY}/data/runtime/scheduler-health.json"
export DOCTOR_TEST_PRESERVE_HEARTBEAT=1
invoke --local
(( LAST_RC == 2 )) || fail '30~60 秒的扫描心跳应警告'
assert_result runtime.scheduler WARN
jq -M -n --argjson now "$(date -u '+%s%3N')" \
  '{schema_version:1,started_at:($now - 80000),completed_at:($now - 70000)}' \
  > "${DEPLOY}/data/runtime/scheduler-health.json"
invoke --local
(( LAST_RC == 1 )) || fail '超过 60 秒的扫描心跳应失败'
assert_result runtime.scheduler FAIL
jq -M -n --argjson now "$(date -u '+%s%3N')" \
  '{schema_version:1,started_at:($now - 10),completed_at:$now}' \
  > "${DEPLOY}/data/runtime/scheduler-health.json"
unset DOCTOR_TEST_PRESERVE_HEARTBEAT
pass '独立 scheduler 心跳区分无流量健康、延迟警告和扫描停滞'

state_tmp="${TEST_ROOT}/session-state.tmp"
jq --argjson until "$(( $(date -u '+%s%3N') - 20000 ))" '.worker={token:"fixture",until:$until}' \
  "$SESSION_FILE" > "$state_tmp"
mv -f -- "$state_tmp" "$SESSION_FILE"
invoke --local
(( LAST_RC == 1 )) || fail '过期 worker 租约应退出 1'
assert_result runtime.state FAIL
jq '.worker=null' "$SESSION_FILE" > "$state_tmp"
mv -f -- "$state_tmp" "$SESSION_FILE"
chmod 0600 "$SESSION_FILE"
pass '发现异常滞留 worker，且不自动解除人工模式'

legacy_file="${DEPLOY}/data/runtime/session-$(printf '%s' session_legacy_fixture | sha256sum | awk '{print $1}').json"
jq -M -n '{version:1,aiEnabled:false,aiResumeAt:0,handoffGeneration:4,lastOperatorAt:1,welcomeSent:true,fingerprints:[]}' \
  > "$legacy_file"
chmod 0600 "$legacy_file"
legacy_hash=$(sha256sum "$legacy_file" | awk '{print $1}')
invoke --local
(( LAST_RC == 2 )) || fail '可识别旧人工状态应警告待懒迁移，而非损坏失败'
assert_result runtime.state WARN
[[ "$legacy_hash" == "$(sha256sum "$legacy_file" | awk '{print $1}')" ]] || fail '自检改写了旧人工状态'
grep -q '待对应会话懒迁移' "$OUT" || fail '旧人工状态未给出准确迁移说明'
rm -f -- "$legacy_file"
pass 'v1 旧人工永久状态保留并标记待懒迁移，不误删或恢复 AI'

printf 'n8n\n' > "$STOPPED_FILE"
invoke --local
(( LAST_RC == 1 )) || fail '停止 n8n 应退出 1'
assert_result container.n8n FAIL
: > "$STOPPED_FILE"
export DOCTOR_FIXTURE_UNHEALTHY_SERVICE=anythingllm
invoke --local
(( LAST_RC == 1 )) || fail 'unhealthy 容器应退出 1'
assert_result container.anythingllm FAIL
unset DOCTOR_FIXTURE_UNHEALTHY_SERVICE
export DOCTOR_FIXTURE_OOM_SERVICE=provider-adapter
invoke --local
(( LAST_RC == 1 )) || fail 'OOM 容器应退出 1'
assert_result container.provider-adapter FAIL
unset DOCTOR_FIXTURE_OOM_SERVICE
pass '区分停止、unhealthy 与 OOM，不以 running 假通过'

export DOCTOR_FIXTURE_ANYTHING_AUTH_FAIL=1
invoke --local
(( LAST_RC == 1 )) || fail 'AnythingLLM Key 故障应退出 1'
assert_result anything.workspace FAIL
unset DOCTOR_FIXTURE_ANYTHING_AUTH_FAIL
export DOCTOR_FIXTURE_WORKFLOW_FAIL=1
invoke --local
(( LAST_RC == 1 )) || fail 'workflow 导出/结构故障应退出 1'
assert_result n8n.workflow FAIL
unset DOCTOR_FIXTURE_WORKFLOW_FAIL
export DOCTOR_FIXTURE_N8N_CODE_FAIL=1
invoke --local
(( LAST_RC == 1 )) || fail '通用 401 不能冒充 n8n Code 健康'
assert_result n8n.runtime FAIL
unset DOCTOR_FIXTURE_N8N_CODE_FAIL
export DOCTOR_FIXTURE_ADAPTER_FAIL=1
invoke --local
(( LAST_RC == 1 )) || fail 'adapter 容器路径故障应退出 1'
assert_result provider.adapter FAIL
unset DOCTOR_FIXTURE_ADAPTER_FAIL
pass 'AnythingLLM、workflow、Code runner 与 adapter 故障可独立定位'

export DOCTOR_FIXTURE_REMOTE_CONTEXT=1
invoke --local
(( LAST_RC == 1 )) || fail '远程 Docker context 应退出 1'
assert_result docker.context FAIL
unset DOCTOR_FIXTURE_REMOTE_CONTEXT
pass '远程 daemon 不会被误判为安全本机 bind mount 环境'

export DOCTOR_FIXTURE_DAEMON_FAIL=1
invoke --local
(( LAST_RC == 1 )) || fail 'Docker daemon 故障应退出 1'
assert_result docker.daemon FAIL
assert_result container.postgres SKIP
assert_result database.authentication SKIP
unset DOCTOR_FIXTURE_DAEMON_FAIL
pass 'daemon 故障与下游未检查状态明确分离'

export DOCTOR_FIXTURE_PROVIDER_FAIL=1
invoke --full
(( LAST_RC == 1 )) || fail 'Provider 空/错误路径应在 full 退出 1'
assert_result provider.inference FAIL
! grep -q 'doctor-fixture-ai_api_key-do-not-print' "$OUT" "$ERR" "$FIXTURE_LOG" || fail '诊断输出泄露 Provider Key'
unset DOCTOR_FIXTURE_PROVIDER_FAIL
invoke --full
(( LAST_RC == 0 )) || fail "健康 full 自检退出码应为 0，实际 ${LAST_RC}"
assert_result provider.inference PASS
grep -q 'provider.example.test' "$FIXTURE_LOG" || fail 'full 没有执行受控模型协议检查'
[[ "$before" == "$(business_hash)" ]] || fail 'full 自检改动了配置、知识或会话状态'
pass '只有 full 执行小样本模型请求并校验最终容器路径'

# timeout 必须真正包住 docker_compose Bash function，而不是尝试执行不存在的外部命令。
export DOCTOR_FIXTURE_DELAY_N8N_SECONDS=12
started=$SECONDS
invoke --local --timeout 8
elapsed=$((SECONDS-started))
(( LAST_RC == 1 )) || fail '超时场景应退出 1'
(( elapsed < 12 )) || fail "Compose 函数超时没有生效（${elapsed} 秒）"
jq -e 'any(.results[]; .id == "container.n8n" and .status != "PASS")' "$OUT" >/dev/null \
  || fail '卡住的 n8n Compose 检查被误报为 PASS'
grep -Eq 'compose .* ps .* n8n' "$FIXTURE_LOG" || fail 'Compose 函数超时测试未到达 n8n 状态读取'
unset DOCTOR_FIXTURE_DELAY_N8N_SECONDS
pass 'Compose 函数受真实截止约束，超时项不会误报 PASS'

export DOCTOR_FIXTURE_DELAY_ANYTHING_SECONDS=20
started=$SECONDS
invoke --local --timeout 8
elapsed=$((SECONDS-started))
(( LAST_RC == 1 || LAST_RC == 2 )) || fail 'AnythingLLM 总截止场景应明确失败或警告'
(( elapsed < 12 )) || fail "AnythingLLM 工作区回读越过自检总截止（${elapsed} 秒）"
assert_result anything.workspace FAIL
grep -q '/api/v1/workspace/' "$FIXTURE_LOG" || fail 'AnythingLLM 截止测试未到达实际工作区回读'
unset DOCTOR_FIXTURE_DELAY_ANYTHING_SECONDS
pass 'AnythingLLM Developer API 回读服从统一总截止，超时不得假 PASS'

export DOCTOR_FIXTURE_DELAY_EXTERNAL_SECONDS=20
started=$SECONDS
invoke --timeout 5
elapsed=$((SECONDS-started))
(( LAST_RC == 1 || LAST_RC == 2 )) || fail '外部总截止场景应明确失败或警告'
(( elapsed < 10 )) || fail "外部检查越过自检总截止（${elapsed} 秒）"
jq -e 'any(.results[]; .id == "crisp.api" and .status != "PASS")' "$OUT" >/dev/null \
  || fail '外部超时被误报为 Crisp PASS'
unset DOCTOR_FIXTURE_DELAY_EXTERNAL_SECONDS
pass '外部 Crisp/Webhook 探测服从统一总截止，超时不沿用旧绿灯'

# 未完成/混合安装代绝不允许 doctor --fix 强启容器或改动配置。
sed -i 's/^state=.*/state=staged/' "${DEPLOY}/.crisp-ai-installation"
printf 'provider-adapter\n' > "$STOPPED_FILE"
before_fix=$(business_hash)
invoke --local --fix
(( LAST_RC == 1 )) || fail 'staged 代的显式修复应被代际保护拒绝'
jq -e 'any(.fix.actions[]; .id == "fix.generation-guard" and .status == "FAIL")' "$OUT" >/dev/null \
  || fail 'staged 修复缺少结构化代际保护结果'
grep -Fxq provider-adapter "$STOPPED_FILE" || fail 'staged 修复错误启动了停止服务'
! grep -Eq '(^|[[:space:]])up([[:space:]]|$)' "$FIXTURE_LOG" || fail 'staged 修复调用了 compose up'
[[ "$before_fix" == "$(business_hash)" ]] || fail 'staged 修复改动了业务状态'
sed -i 's/^state=.*/state=ready/' "${DEPLOY}/.crisp-ai-installation"
: > "$STOPPED_FILE"
pass '混合代 --fix 在任何依赖、权限、入口或容器变更前拒绝'

# --fix 只启动本项目停止服务；第二轮 expected services 必须重置，不重复 caddy/结果。
printf 'provider-adapter\n' > "$STOPPED_FILE"
before_fix=$(business_hash)
invoke --local --fix
(( LAST_RC == 0 )) || fail "安全修复后应恢复健康，实际退出 ${LAST_RC}"
jq -e '.fix.requested == true and any(.fix.actions[]; .id == "fix.service.provider-adapter" and .status == "PASS")' "$OUT" >/dev/null \
  || fail '--fix 未记录 provider-adapter 恢复动作'
jq -e '([.results[].id] | length) == ([.results[].id] | unique | length)' "$OUT" >/dev/null \
  || fail '--fix 复查重复追加组件结果'
[[ ! -s "$STOPPED_FILE" ]] || fail '--fix 没有恢复停止的受管服务'
[[ "$before_fix" == "$(business_hash)" ]] || fail '--fix 改动了业务配置、知识或会话状态'
pass '--fix 仅执行安全白名单并在修复后重新检查'

# 缺 jq 时，普通 doctor 仍只报告故障；显式 --fix 才允许调用受管 bootstrap。
bootstrap_saved="${TEST_ROOT}/bootstrap.saved"
cp -p -- "${DEPLOY}/scripts/bootstrap.sh" "$bootstrap_saved"
jq_flag="${TEST_ROOT}/jq-installed"
export jq_flag
printf '#!/usr/bin/env bash\nset -euo pipefail\ntouch -- %q\n' "$jq_flag" > "${DEPLOY}/scripts/bootstrap.sh"
chmod 0755 "${DEPLOY}/scripts/bootstrap.sh"
# shellcheck disable=SC2317 # 该函数导出给 doctor 子进程，当前测试 shell 不直接调用。
command() {
  if [[ "${1:-}" == -v && "${2:-}" == jq && ! -f "$jq_flag" ]]; then return 1; fi
  builtin command "$@"
}
export -f command
invoke --local
(( LAST_RC == 1 )) || fail '缺 jq 的普通只读自检应退出 1'
[[ ! -e "$jq_flag" ]] || fail '普通自检不应自动调用依赖修复'
jq -e '.summary.fail == 1 and .results[0].id == "system.commands"' "$OUT" >/dev/null \
  || fail '缺 jq 的 JSON 降级报告无效'
sed -i 's/^state=.*/state=staged/' "${DEPLOY}/.crisp-ai-installation"
invoke --local --fix
(( LAST_RC == 1 )) || fail 'staged 且缺 jq 时应拒绝 pre-bootstrap'
[[ ! -e "$jq_flag" ]] || fail 'staged 且缺 jq 时错误调用了 bootstrap'
sed -i 's/^state=.*/state=ready/' "${DEPLOY}/.crisp-ai-installation"
invoke --local --fix
unset -f command
cp -p -- "$bootstrap_saved" "${DEPLOY}/scripts/bootstrap.sh"
(( LAST_RC == 0 )) || fail "缺 jq 的显式安全修复未恢复自检（${LAST_RC}）"
[[ -f "$jq_flag" ]] || fail '缺 jq 时没有调用受管 bootstrap'
jq -e 'any(.fix.actions[]; .id == "fix.bootstrap-jq" and .status == "PASS")' "$OUT" >/dev/null \
  || fail '缺 jq 修复没有结构化记录'
unset jq_flag
pass '缺 jq 时仅 doctor --fix 通过受管 bootstrap 安全补齐并记录动作'

LAST_RC=0
"$DOCTOR" --bad-option > "$OUT" 2> "$ERR" || LAST_RC=$?
(( LAST_RC == 64 )) || fail "非法参数退出码应为 64，实际 ${LAST_RC}"
pass '参数错误退出 64，JSON stdout 保持可解析且诊断不回显秘密'

printf '自检专项完成：%s 组通过。\n' "$PASSED"
