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
WORKSPACE_PROMPT_FILE="${TEST_ROOT}/anything-workspace-prompt.md"
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
    DOCTOR_FIXTURE_WORKSPACE_PROMPT_FILE="$WORKSPACE_PROMPT_FILE" \
    DOCTOR_FIXTURE_DAEMON_FAIL="${DOCTOR_FIXTURE_DAEMON_FAIL:-0}" \
    DOCTOR_FIXTURE_REMOTE_CONTEXT="${DOCTOR_FIXTURE_REMOTE_CONTEXT:-0}" \
    DOCTOR_FIXTURE_OOM_SERVICE="${DOCTOR_FIXTURE_OOM_SERVICE:-}" \
    DOCTOR_FIXTURE_UNHEALTHY_SERVICE="${DOCTOR_FIXTURE_UNHEALTHY_SERVICE:-}" \
    DOCTOR_FIXTURE_STARTING_SERVICE="${DOCTOR_FIXTURE_STARTING_SERVICE:-}" \
    DOCTOR_FIXTURE_DB_FAIL="${DOCTOR_FIXTURE_DB_FAIL:-0}" \
    DOCTOR_FIXTURE_ANYTHING_PING_FAIL="${DOCTOR_FIXTURE_ANYTHING_PING_FAIL:-0}" \
    DOCTOR_FIXTURE_ANYTHING_AUTH_FAIL="${DOCTOR_FIXTURE_ANYTHING_AUTH_FAIL:-0}" \
    DOCTOR_FIXTURE_RAG_CONTEXT="${DOCTOR_FIXTURE_RAG_CONTEXT:-8192}" \
    DOCTOR_FIXTURE_RAG_API_CONTEXT="${DOCTOR_FIXTURE_RAG_API_CONTEXT:-8192}" \
    DOCTOR_FIXTURE_EMPTY_WORKSPACE="${DOCTOR_FIXTURE_EMPTY_WORKSPACE:-0}" \
    DOCTOR_FIXTURE_WORKFLOW_FAIL="${DOCTOR_FIXTURE_WORKFLOW_FAIL:-0}" \
    DOCTOR_FIXTURE_LEXICAL_RUNNING_FILE="${DOCTOR_FIXTURE_LEXICAL_RUNNING_FILE:-${DEPLOY}/n8n/knowledge-lexical.js}" \
    DOCTOR_FIXTURE_N8N_CODE_FAIL="${DOCTOR_FIXTURE_N8N_CODE_FAIL:-0}" \
    DOCTOR_FIXTURE_N8N_ACTIVE_EXECUTIONS="${DOCTOR_FIXTURE_N8N_ACTIVE_EXECUTIONS:-0}" \
    DOCTOR_FIXTURE_N8N_OLDER_TWO_MINUTES="${DOCTOR_FIXTURE_N8N_OLDER_TWO_MINUTES:-0}" \
    DOCTOR_FIXTURE_N8N_OLDER_TEN_MINUTES="${DOCTOR_FIXTURE_N8N_OLDER_TEN_MINUTES:-0}" \
    DOCTOR_FIXTURE_ADAPTER_FAIL="${DOCTOR_FIXTURE_ADAPTER_FAIL:-0}" \
    DOCTOR_FIXTURE_PROVIDER_FAIL="${DOCTOR_FIXTURE_PROVIDER_FAIL:-0}" \
    DOCTOR_FIXTURE_PROVIDER_MODE="${DOCTOR_FIXTURE_PROVIDER_MODE:-}" \
    DOCTOR_FIXTURE_RETRIEVAL_FAIL="${DOCTOR_FIXTURE_RETRIEVAL_FAIL:-0}" \
    DOCTOR_FIXTURE_RETRIEVAL_UNKNOWN="${DOCTOR_FIXTURE_RETRIEVAL_UNKNOWN:-0}" \
    DOCTOR_FIXTURE_ADMIN_INVALID_RESULT="${DOCTOR_FIXTURE_ADMIN_INVALID_RESULT:-0}" \
    DOCTOR_FIXTURE_ADMIN_DELAY_SECONDS="${DOCTOR_FIXTURE_ADMIN_DELAY_SECONDS:-0}" \
    DOCTOR_FIXTURE_ADMIN_EXPECT_BUDGET="${DOCTOR_FIXTURE_ADMIN_EXPECT_BUDGET:-}" \
    DOCTOR_FIXTURE_ADMIN_EXPECT_QUESTION_SHA256="${DOCTOR_FIXTURE_ADMIN_EXPECT_QUESTION_SHA256:-}" \
    DOCTOR_FIXTURE_CRISP_FAIL="${DOCTOR_FIXTURE_CRISP_FAIL:-0}" \
    DOCTOR_FIXTURE_WEBHOOK_FAIL="${DOCTOR_FIXTURE_WEBHOOK_FAIL:-0}" \
    DOCTOR_FIXTURE_DELAY_N8N_SECONDS="${DOCTOR_FIXTURE_DELAY_N8N_SECONDS:-0}" \
    DOCTOR_FIXTURE_DELAY_ANYTHING_SECONDS="${DOCTOR_FIXTURE_DELAY_ANYTHING_SECONDS:-0}" \
    DOCTOR_FIXTURE_DELAY_EXTERNAL_SECONDS="${DOCTOR_FIXTURE_DELAY_EXTERNAL_SECONDS:-0}" \
    DOCTOR_FIXTURE_MATERIALS_MISMATCH="${DOCTOR_FIXTURE_MATERIALS_MISMATCH:-0}" \
    DOCTOR_FIXTURE_WORKSPACE_PROMPT_MISMATCH="${DOCTOR_FIXTURE_WORKSPACE_PROMPT_MISMATCH:-0}" \
    DOCTOR_FIXTURE_ADAPTER_CODE_MISMATCH="${DOCTOR_FIXTURE_ADAPTER_CODE_MISMATCH:-0}" \
    DOCTOR_FIXTURE_CADDY_FILE_MISMATCH="${DOCTOR_FIXTURE_CADDY_FILE_MISMATCH:-0}" \
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

fixture_json_to_yaml() {
  local target=$1 temporary="${1}.yaml-fixture"
  python3 - "$target" > "$temporary" <<'PY'
import json
import pathlib
import sys

import yaml

value = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
sys.stdout.write(yaml.safe_dump(value, allow_unicode=True, sort_keys=False))
PY
  chmod --reference="$target" "$temporary"
  chown --reference="$target" "$temporary" 2>/dev/null || true
  mv -f -- "$temporary" "$target"
}

prepare_fixture() {
  local name secret digest launcher doc_hash version timer_digest materials_stage
  mkdir -p "$DEPLOY"/{config,knowledge/kb_default/sources,data/runtime,data/n8n,data/anythingllm,data/analytics,backups/manual,logs,tmp,n8n,scripts} "$SYSTEMD_DIR"
  for name in VERSION docker-compose.yml get.sh manage.sh install.sh update.sh uninstall.sh; do
    cp -p -- "${PROJECT_ROOT}/${name}" "${DEPLOY}/${name}"
  done
  printf 'v1.2.0\n' > "${DEPLOY}/VERSION"
  for name in workflow.json runtime.js runtime-cli.js build-workflow.js web-chat.js admin-query.js knowledge-lexical.js; do
    cp -p -- "${PROJECT_ROOT}/n8n/${name}" "${DEPLOY}/n8n/${name}"
  done
  node "${DEPLOY}/n8n/build-workflow.js"
  jq -M '.active=true' "${DEPLOY}/n8n/workflow.json" > "${DEPLOY}/n8n/workflow.json.new"
  mv -f -- "${DEPLOY}/n8n/workflow.json.new" "${DEPLOY}/n8n/workflow.json"
  for name in common.sh doctor.sh healthcheck.sh provider.sh configuration.sh provider-adapter.js launcher.sh bootstrap.sh \
    wizard.sh package-release.sh knowledge.sh migration.sh crisp-settings.sh full-backup.sh archive-guard.py \
    backup.sh restore.sh analytics.sh snapshot.sh rollback.sh menu-ui.sh materials.sh logs.sh log-redact.py \
    knowledge-profile.py knowledge-profile.sh knowledge-component.js knowledge-lexical.py; do
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
  # 本组先保留升级前单接口兼容实例的检查；主备池另做显式迁移及故障注入。
  env_set "${DEPLOY}/.env" PROVIDER_POOL_REQUIRED false
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
  jq -M -n '{schema_version:2,revision:1,documents:[{library_id:"kb_default",library_name:"默认知识库",
    document_id:"doc_1111111111111111",projection:"fixture.md",location:"custom-documents/fixture.json"}]}' \
    > "${DEPLOY}/data/runtime/knowledge-map.json"
  chmod 0600 "${DEPLOY}/data/runtime/knowledge-map.json"
  # 合成的已应用索引代：这里只验证元数据/缓存身份，不把它称为真实 Embedding。
  python3 -B - "$DEPLOY" <<'PY'
import importlib.util
import json
from pathlib import Path
import sys

root = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("doctor_profile_fixture", root / "scripts/knowledge-profile.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
value = module.profile({"engine": "native", "model": "MintplexLabs/multilingual-e5-small",
                        "chunk_size": 400, "chunk_overlap": 20, "component_version": "1.16.1"})
key = module.fingerprint(value)
module.atomic(root / "data/runtime/knowledge-profile.json",
              {"schema_version": 1, "state": "applied", "profile": value, "fingerprint": key}, 0o640)
module.atomic(root / "data/runtime/knowledge-settings.json",
              {"schema_version": 1, "workspace_slug": "crisp-support", "temperature": 0.35, "observed_at": 1}, 0o640)
manifest = module.read(root / "data/knowledge-manifest.json")
manifest["embedding_profile"] = key
for record in manifest["files"].values():
    record["embedding_profile"] = key
    record["cache_bindings"] = []
    for location in record["locations"]:
        module.atomic(root / "data/anythingllm/documents" / location,
                      {"pageContent": "虚构知识：雨天测试码为蓝色。\n"})
        cached = module.cache_path(root, location)
        module.atomic(cached, {"fixture": "synthetic-vector-generation"})
        record["cache_bindings"].append({"location": location, "sha256": module.digest(cached)})
module.atomic(root / "data/knowledge-manifest.json", manifest)
PY
  python3 -B "${DEPLOY}/scripts/knowledge-lexical.py" build --deploy-dir "$DEPLOY" >/dev/null
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
  jq -M -j '.prompt.text' "${materials_stage}/materials-applied.json" > "$WORKSPACE_PROMPT_FILE"
  chmod 0600 "$WORKSPACE_PROMPT_FILE"
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
  chown root:1000 "${DEPLOY}/data/runtime/knowledge-lexical.json"
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
if [[ "${CRISPAI_DOCTOR_FIXTURE_SETUP_ONLY:-0}" == 1 && "${BASH_SOURCE[0]}" != "$0" ]]; then return 0; fi

doctor_knowledge_cases() {
  local original case_name state_hash changed_hash cache_hash
  original=$(mktemp -d "${TEST_ROOT}/knowledge-original.XXXXXXXX")
  cp -p -- "${DEPLOY}/data/runtime/knowledge-profile.json" "$original/profile.json"
  cp -p -- "${DEPLOY}/data/runtime/knowledge-settings.json" "$original/settings.json"
  cp -p -- "${DEPLOY}/data/knowledge-manifest.json" "$original/manifest.json"
  cp -p -- "${DEPLOY}/config/materials-applied.json" "$original/materials.json"
  state_hash=$(business_hash)
  for case_name in applying profile-body profile-hash manifest-profile document-profile cache-binding cache-hash settings-slug settings-temperature settings-hash missing-referenced legacy minilm healthy; do
    python3 -B - "$DEPLOY" "$original" "$case_name" <<'PY'
import hashlib
import importlib.util
import json
from pathlib import Path
import sys

root, saved, case = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
spec = importlib.util.spec_from_file_location("doctor_profile_cases", root / "scripts/knowledge-profile.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
paths = {"profile": "data/runtime/knowledge-profile.json", "settings": "data/runtime/knowledge-settings.json",
         "manifest": "data/knowledge-manifest.json", "materials": "config/materials-applied.json"}
for name, target in paths.items():
    module.atomic(root / target, json.loads((saved / (name + ".json")).read_text()), 0o600 if name == "manifest" else 0o640)
profile = module.read(root / paths["profile"])
manifest = module.read(root / paths["manifest"])
settings = module.read(root / paths["settings"])
materials = module.read(root / paths["materials"])
record = manifest["files"]["fixture.md"]
cache = module.cache_path(root, record["locations"][0])
module.atomic(cache, {"fixture": "synthetic-vector-generation"})
if case == "applying": profile["state"] = "applying"
elif case == "profile-body": profile["profile"]["chunk_size"] += 1
elif case == "manifest-profile": manifest["embedding_profile"] = "f" * 64
elif case == "document-profile": record["embedding_profile"] = "f" * 64
elif case == "cache-binding": record.pop("cache_bindings")
elif case == "cache-hash": module.atomic(cache, {"fixture": "different-vector-generation"})
elif case == "settings-slug": settings["workspace_slug"] = "another-workspace"
elif case == "settings-temperature": settings["temperature"] = True
elif case == "minilm":
    profile["profile"] = module.profile({"engine": "native", "model": "Xenova/all-MiniLM-L6-v2",
                                         "chunk_size": 1000, "chunk_overlap": 20, "component_version": "1.16.1"})
    profile["fingerprint"] = module.fingerprint(profile["profile"])
    manifest["embedding_profile"] = profile["fingerprint"]
    record["embedding_profile"] = profile["fingerprint"]
for name, value in (("profile", profile), ("settings", settings), ("manifest", manifest)):
    module.atomic(root / paths[name], value, 0o600 if name == "manifest" else 0o640)
for name in ("profile", "settings", "manifest"):
    materials["knowledge"][name + "_sha256"] = module.digest(root / paths[name])
if case == "profile-hash": materials["knowledge"]["profile_sha256"] = "f" * 64
elif case == "settings-hash": materials["knowledge"]["settings_sha256"] = "f" * 64
elif case in ("missing-referenced", "legacy"):
    (root / paths["profile"]).unlink()
    if case == "legacy":
        materials["knowledge"]["profile_sha256"] = ""
        manifest.pop("embedding_profile")
        record.pop("embedding_profile")
        record.pop("cache_bindings")
        module.atomic(root / paths["manifest"], manifest)
        materials["knowledge"]["manifest_sha256"] = module.digest(root / paths["manifest"])
module.atomic(root / paths["materials"], materials, 0o640)
PY
    changed_hash=$(business_hash)
    cache_hash=$(find "${DEPLOY}/data/anythingllm/vector-cache" -type f -exec sha256sum {} + | sha256sum | awk '{print $1}')
    invoke --offline
    case "$case_name" in
      legacy|minilm) assert_result knowledge.profile WARN ;;
      settings-*) assert_result knowledge.profile PASS; assert_result knowledge.settings FAIL ;;
      healthy) assert_result knowledge.profile PASS; assert_result knowledge.settings PASS ;;
      *) assert_result knowledge.profile FAIL ;;
    esac
    [[ "$changed_hash" == "$(business_hash)" ]] || fail "知识自检 ${case_name} 改动业务或索引元数据"
    [[ "$cache_hash" == "$(find "${DEPLOY}/data/anythingllm/vector-cache" -type f -exec sha256sum {} + | sha256sum | awk '{print $1}')" ]] \
      || fail "知识自检 ${case_name} 写入向量缓存"
    [[ ! -e "${DEPLOY}/scripts/__pycache__" ]] || fail '知识只读校验在程序目录生成了 Python 缓存'
    ! grep -Eq '^docker |^curl |虚构知识：雨天测试码为蓝色。|synthetic-vector-generation' "$FIXTURE_LOG" "$OUT" "$ERR" \
      || fail "知识自检 ${case_name} 调用网络或输出知识/缓存正文"
  done
  cp -p -- "$original/profile.json" "${DEPLOY}/data/runtime/knowledge-profile.json"
  cp -p -- "$original/settings.json" "${DEPLOY}/data/runtime/knowledge-settings.json"
  cp -p -- "$original/manifest.json" "${DEPLOY}/data/knowledge-manifest.json"
  cp -p -- "$original/materials.json" "${DEPLOY}/config/materials-applied.json"
  [[ "$state_hash" == "$(business_hash)" ]] || fail '知识只读专项未恢复原合成配置'
  pass '知识 profile/settings 14 个只读正负例：应用状态、正文指纹、文档缓存绑定和旧代警告'
}

doctor_lexical_cases() {
  local original case_name baseline changed_hash source_hash
  original=$(mktemp -d "${TEST_ROOT}/lexical-original.XXXXXXXX")
  cp -p -- "${DEPLOY}/data/runtime/knowledge-lexical.json" "$original/index.json"
  cp -p -- "${DEPLOY}/config/materials-applied.json" "$original/materials.json"
  cp -p -- "${DEPLOY}/data/anythingllm/documents/custom-documents/fixture.json" "$original/source.json"
  baseline=$(business_hash)
  for case_name in lexical-hash lexical-schema lexical-map lexical-source lexical-missing lexical-partial lexical-legacy lexical-healthy; do
    python3 -B - "$DEPLOY" "$original" "$case_name" <<'PY'
import hashlib
import json
from pathlib import Path
import shutil
import sys

root, saved, case = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
target = root / "data/runtime/knowledge-lexical.json"
source = root / "data/anythingllm/documents/custom-documents/fixture.json"
projection = root / "config/materials-applied.json"
for old, new in (("index.json", target), ("source.json", source), ("materials.json", projection)):
    shutil.copy2(saved / old, new)
target.chmod(0o640)
import os
os.chown(target, 0, 1000)
index = json.loads(target.read_text())
materials = json.loads(projection.read_text())
if case == "lexical-schema": index["schema_version"] = 99
elif case == "lexical-map": index["map_sha256"] = "f" * 64
elif case == "lexical-source": source.write_text(json.dumps({"pageContent": "虚构解析源已经发生变化。"}, ensure_ascii=False))
elif case == "lexical-partial":
    index["complete"] = False
    index["passages"] = []
    coverage = index["coverage"]
    coverage.update(indexed_documents=0, indexed_bytes=0, omitted_documents=coverage["source_documents"],
                    omitted_bytes=coverage["source_bytes"], reasons=["index_capacity"])
index.pop("payload_sha256")
index["payload_sha256"] = hashlib.sha256(json.dumps(index, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
target.write_text(json.dumps(index, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n")
materials["knowledge"]["lexical_sha256"] = hashlib.sha256(target.read_bytes()).hexdigest()
if case == "lexical-hash": materials["knowledge"]["lexical_sha256"] = "f" * 64
elif case in ("lexical-missing", "lexical-legacy"):
    target.unlink()
    if case == "lexical-legacy": materials["knowledge"]["lexical_sha256"] = ""
projection.write_text(json.dumps(materials, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n")
PY
    changed_hash=$(business_hash)
    source_hash=$(sha256sum "${DEPLOY}/data/anythingllm/documents/custom-documents/fixture.json" | awk '{print $1}')
    invoke --offline
    case "$case_name" in
      lexical-partial|lexical-legacy) assert_result knowledge.lexical WARN ;;
      lexical-healthy) assert_result knowledge.lexical PASS ;;
      *) assert_result knowledge.lexical FAIL ;;
    esac
    [[ "$changed_hash" == "$(business_hash)" \
      && "$source_hash" == "$(sha256sum "${DEPLOY}/data/anythingllm/documents/custom-documents/fixture.json" | awk '{print $1}')" ]] \
      || fail "词法自检 ${case_name} 改动业务状态、索引或解析源"
    ! grep -Eq '^docker |^curl |虚构知识：雨天测试码为蓝色。|虚构解析源已经发生变化。' "$FIXTURE_LOG" "$OUT" "$ERR" \
      || fail "词法自检 ${case_name} 调用网络或回显知识正文"
  done
  cp -p -- "$original/index.json" "${DEPLOY}/data/runtime/knowledge-lexical.json"
  cp -p -- "$original/materials.json" "${DEPLOY}/config/materials-applied.json"
  cp -p -- "$original/source.json" "${DEPLOY}/data/anythingllm/documents/custom-documents/fixture.json"
  [[ "$baseline" == "$(business_hash)" ]] || fail '词法自检未恢复原合成资料'
  pass '词法 8 个只读正负例：真实索引校验、源/映射/材料绑定及合法部分覆盖警告'
}

doctor_workflow_lexical_cases() {
  local original target
  original=$(mktemp -d "${TEST_ROOT}/workflow-lexical.XXXXXXXX")
  cp -p -- "${DEPLOY}/n8n/workflow.json" "${original}/workflow.json"
  cp -p -- "${DEPLOY}/n8n/knowledge-lexical.js" "${original}/knowledge-lexical.js"
  invoke --local
  assert_result n8n.workflow PASS

  printf '\n// 合成的词法源码新代。\n' >> "${DEPLOY}/n8n/knowledge-lexical.js"
  invoke --local
  assert_result n8n.workflow FAIL
  cp -p -- "${original}/knowledge-lexical.js" "${DEPLOY}/n8n/knowledge-lexical.js"

  printf '\n// 合成的容器旧挂载。\n' >> "${original}/knowledge-lexical.js"
  export DOCTOR_FIXTURE_LEXICAL_RUNNING_FILE="${original}/knowledge-lexical.js"
  invoke --local
  assert_result n8n.workflow FAIL
  unset DOCTOR_FIXTURE_LEXICAL_RUNNING_FILE

  jq '(.nodes[] | select(.name=="处理持久任务") | .parameters.jsCode) |= ("// 合成的偏离内联。\n" + .)' \
    "${DEPLOY}/n8n/workflow.json" > "${original}/changed.json"
  cp -p -- "${original}/changed.json" "${DEPLOY}/n8n/workflow.json"
  invoke --local
  assert_result n8n.workflow FAIL
  cp -p -- "${original}/workflow.json" "${DEPLOY}/n8n/workflow.json"

  for target in n8n/knowledge-lexical.js scripts/knowledge-lexical.py; do
    mv -- "${DEPLOY}/${target}" "${original}/missing-module"
    invoke --offline
    assert_result installation.files FAIL
    mv -- "${original}/missing-module" "${DEPLOY}/${target}"
  done
}

if [[ "${DOCTOR_TEST_FOCUS:-}" == workflow ]]; then
  doctor_workflow_lexical_cases
  pass '工作流实际 Node 校验的 6 个词法内联、挂载与漏件正负例'
  printf '工作流自检聚焦完成：6 个场景，%s 组通过。\n' "$PASSED"
  exit 0
elif [[ "${DOCTOR_TEST_FOCUS:-}" == lexical ]]; then
  doctor_lexical_cases
  printf '词法自检聚焦完成：8 个场景，%s 组通过。\n' "$PASSED"
  exit 0
elif [[ "${DOCTOR_TEST_FOCUS:-}" == knowledge ]]; then
  doctor_knowledge_cases
  doctor_lexical_cases
  printf '知识自检聚焦完成：22 个场景，%s 组通过。\n' "$PASSED"
  exit 0
fi

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
! grep -Eq 'provider\.example\.test|/chat(/|$)|n8n/admin-query\.js' "$FIXTURE_LOG" \
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
assert_result n8n.execution_backlog PASS
assert_result provider.adapter PASS
assert_result provider.adapter_binding PASS
assert_result provider.adapter_code_binding PASS
assert_result anything.provider_binding PASS
assert_result n8n.runtime_binding PASS
assert_result caddy.file_binding SKIP
assert_result materials.applied PASS
assert_result materials.runtime_binding PASS
assert_result runtime.scheduler PASS
assert_result crisp.api SKIP
! grep -q 'https://' "$FIXTURE_LOG" || fail 'local 自检访问了外部 URL'
[[ "$before" == "$(business_hash)" ]] || fail 'local 自检改动了配置、知识或会话状态'

# 生产配置入口接受严格 YAML/JSON。doctor 必须复用同一安全解码器读取私有
# 规范化副本，不能因扩展名内容不是 JSON 而在回滚健康门禁中假失败。
yaml_saved="${TEST_ROOT}/yaml-config-saved"
mkdir -m 0700 "$yaml_saved"
for name in runtime provider keyword menu handoff tags feedback; do
  cp -p -- "${DEPLOY}/config/${name}.yaml" "$yaml_saved/${name}.yaml"
  fixture_json_to_yaml "${DEPLOY}/config/${name}.yaml"
done
invoke --local
(( LAST_RC == 0 || LAST_RC == 2 )) || fail "同语义合法 YAML 被 doctor 误报为故障（${LAST_RC}）"
assert_result config.syntax PASS
assert_result business.settings PASS
assert_result provider.configuration PASS
assert_result materials.applied PASS
assert_result anything.workspace PASS
for name in runtime provider keyword menu handoff tags feedback; do
  cp -p -- "$yaml_saved/${name}.yaml" "${DEPLOY}/config/${name}.yaml"
done

# v1.2 运行时以已应用投影为权威。合法 YAML 草稿可以同时改动
# 客服开关、欢迎语和恢复秒数，但 doctor 必须继续报告旧投影的
# 当前运行值，并将草稿只标记为待应用。
draft_saved="${TEST_ROOT}/business-draft-saved"
mkdir -m 0700 "$draft_saved"
for name in runtime menu handoff; do
  cp -p -- "${DEPLOY}/config/${name}.yaml" "$draft_saved/${name}.yaml"
done
applied_enabled=$(jq -r 'if .configuration.runtime.enabled then "启用" else "停用（管理员设置）" end' \
  "${DEPLOY}/config/materials-applied.json")
applied_welcome=$(jq -r 'if .configuration.menu.welcome.enabled then "启用" else "停用" end' \
  "${DEPLOY}/config/materials-applied.json")
applied_resume=$(jq -r '.configuration.handoff.handoff.resume_after_seconds' \
  "${DEPLOY}/config/materials-applied.json")
jq '.enabled = (.enabled | not)' "${DEPLOY}/config/runtime.yaml" > "${DEPLOY}/config/runtime.yaml.new"
mv -f -- "${DEPLOY}/config/runtime.yaml.new" "${DEPLOY}/config/runtime.yaml"
jq '.welcome.enabled = (.welcome.enabled | not)' "${DEPLOY}/config/menu.yaml" > "${DEPLOY}/config/menu.yaml.new"
mv -f -- "${DEPLOY}/config/menu.yaml.new" "${DEPLOY}/config/menu.yaml"
jq --argjson seconds "$((applied_resume == 604800 ? 604799 : applied_resume + 1))" \
  '.handoff.resume_after_seconds = $seconds' "${DEPLOY}/config/handoff.yaml" > "${DEPLOY}/config/handoff.yaml.new"
mv -f -- "${DEPLOY}/config/handoff.yaml.new" "${DEPLOY}/config/handoff.yaml"
for name in runtime menu handoff; do
  chmod --reference="$draft_saved/${name}.yaml" "${DEPLOY}/config/${name}.yaml"
  fixture_json_to_yaml "${DEPLOY}/config/${name}.yaml"
done
invoke --local
(( LAST_RC == 2 )) || fail '合法但未应用的 YAML 业务草稿应只返回警告 2'
assert_result config.syntax PASS
assert_result materials.applied WARN
assert_result business.settings PASS
jq -e --arg expected "当前生效投影：客服 ${applied_enabled}；欢迎语 ${applied_welcome}；自动恢复 ${applied_resume} 秒" \
  'any(.results[]; .id == "business.settings" and .summary == $expected)' "$OUT" >/dev/null \
  || fail 'business.settings 把可编辑 YAML 草稿冒充当前运行值'
for name in runtime menu handoff; do
  cp -p -- "$draft_saved/${name}.yaml" "${DEPLOY}/config/${name}.yaml"
done

handoff_saved="${TEST_ROOT}/handoff-before-invalid.yaml"
cp -p -- "${DEPLOY}/config/handoff.yaml" "$handoff_saved"
printf 'handoff:\n  resume_after_seconds: 1800\nhandoff:\n  resume_after_seconds: 0\n' \
  > "${DEPLOY}/config/handoff.yaml"
chmod 0640 "${DEPLOY}/config/handoff.yaml"
invoke --local
(( LAST_RC == 1 )) || fail '重复 YAML 键必须由严格解码器拒绝'
assert_result config.syntax FAIL
assert_result business.settings PASS
jq -e 'any(.results[]; .id == "business.settings" and (.summary | startswith("当前生效投影：")))' "$OUT" >/dev/null \
  || fail '可编辑 YAML 损坏时未继续使用已验证生效投影'
! grep -Fq 'resume_after_seconds' "$OUT" "$ERR" || fail 'YAML 错误诊断回显了配置正文'
cp -p -- "$handoff_saved" "${DEPLOY}/config/handoff.yaml"

printf 'handoff: [\n' > "${DEPLOY}/config/handoff.yaml"
chmod 0640 "${DEPLOY}/config/handoff.yaml"
invoke --local
(( LAST_RC == 1 )) || fail '损坏 YAML 必须由严格解码器拒绝'
assert_result config.syntax FAIL
assert_result business.settings PASS
cp -p -- "$handoff_saved" "${DEPLOY}/config/handoff.yaml"
[[ "$before" == "$(business_hash)" ]] || fail 'YAML 正负例未恢复原业务状态'
pass 'local 自检兼容合法 YAML，严格拒绝坏输入，且业务摘要只读生效投影'

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

doctor_knowledge_cases
doctor_lexical_cases

# 可编辑原文不是运行时权威源。它发生变化或损坏时，应保留并证明上一有效
# 投影仍在运行；只有投影本身/运行中挂载偏离才是关键故障。
prompt_saved="${TEST_ROOT}/prompt.saved.md"
cp -p -- "${DEPLOY}/config/prompt.md" "$prompt_saved"
printf '\n尚未应用的虚构编辑。\n' >> "${DEPLOY}/config/prompt.md"
invoke --local
(( LAST_RC == 2 )) || fail '有效原文待应用时应警告而非读取为当前运行配置'
assert_result materials.applied WARN
assert_result materials.runtime_binding PASS
assert_result anything.workspace PASS
cp -p -- "$prompt_saved" "${DEPLOY}/config/prompt.md"

chmod 0644 "${DEPLOY}/config/prompt.md"
invoke --local
(( LAST_RC == 2 )) || fail '可编辑原文权限损坏但有效投影存在时应警告'
assert_result materials.applied WARN
assert_result materials.runtime_binding PASS
assert_result anything.workspace PASS
cp -p -- "$prompt_saved" "${DEPLOY}/config/prompt.md"

projection_saved="${TEST_ROOT}/materials-applied.saved.json"
cp -p -- "${DEPLOY}/config/materials-applied.json" "$projection_saved"
jq '.state="applying"' "$projection_saved" > "${DEPLOY}/config/materials-applied.json"
chmod 0640 "${DEPLOY}/config/materials-applied.json"
invoke --local
(( LAST_RC == 1 )) || fail '未完成 applying 投影不得通过运行时健康门禁'
assert_result materials.applied FAIL
assert_result materials.runtime_binding SKIP
assert_result anything.workspace FAIL
assert_result business.settings FAIL
cp -p -- "$projection_saved" "${DEPLOY}/config/materials-applied.json"

rm -f -- "${DEPLOY}/config/materials-applied.json"
invoke --local
(( LAST_RC == 1 )) || fail 'legacy 无资料投影时整体资料门禁应失败，但工作区仍应按原 Prompt 准确诊断'
assert_result anything.workspace PASS
assert_result materials.applied FAIL
assert_result business.settings PASS
jq -e 'any(.results[]; .id == "business.settings" and (.summary | startswith("可编辑配置（legacy 无生效投影）：")))' "$OUT" >/dev/null \
  || fail 'legacy 无投影时业务摘要未明确标识可编辑配置来源'
cp -p -- "$projection_saved" "${DEPLOY}/config/materials-applied.json"

export DOCTOR_FIXTURE_WORKSPACE_PROMPT_MISMATCH=1
invoke --local
(( LAST_RC == 1 )) || fail 'AnythingLLM 中 Prompt 偏离已应用投影时应退出 1'
assert_result anything.workspace FAIL
assert_result materials.applied PASS
assert_result materials.runtime_binding PASS
unset DOCTOR_FIXTURE_WORKSPACE_PROMPT_MISMATCH

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
(( LAST_RC == 1 )) || fail '已绑定模型代次的 pending 文档必须保持故障，不能提前宣称索引应用完成'
assert_result knowledge.catalog WARN
assert_result knowledge.profile FAIL
assert_result knowledge.lexical PASS
grep -q '仍在服务端对账' "$OUT" || fail '正常 pending 未给出处理中说明'

# 真正无 profile 绑定的旧实例仍保留原有 pending 警告，不借新代文件冒充旧代。
pending_materials_saved="${TEST_ROOT}/pending-materials.saved.json"
pending_profile_saved="${TEST_ROOT}/pending-profile.saved.json"
cp -p -- "${DEPLOY}/config/materials-applied.json" "$pending_materials_saved"
mv -- "${DEPLOY}/data/runtime/knowledge-profile.json" "$pending_profile_saved"
jq 'del(.embedding_profile)' "${DEPLOY}/data/knowledge-manifest.json" > "${TEST_ROOT}/pending-legacy-manifest.json"
# 生产 manifest 是受限运行状态；测试候选也必须保持同一权限，否则
# profile 校验会正确地把 world-readable 文件判为 FAIL，掩盖本例要验证的 legacy WARN。
install -m 0600 -- "${TEST_ROOT}/pending-legacy-manifest.json" "${DEPLOY}/data/knowledge-manifest.json"
jq --arg manifest_hash "$(sha256sum "${DEPLOY}/data/knowledge-manifest.json" | awk '{print $1}')" \
  '.knowledge.profile_sha256="" | .knowledge.manifest_sha256=$manifest_hash' \
  "$pending_materials_saved" > "${DEPLOY}/config/materials-applied.json"
invoke --local
(( LAST_RC == 2 )) || fail '无 profile 绑定旧代的正常 pending 文档应保留警告 2'
assert_result knowledge.catalog WARN
assert_result knowledge.profile WARN
assert_result knowledge.lexical PASS
mv -- "$pending_profile_saved" "${DEPLOY}/data/runtime/knowledge-profile.json"
cp -p -- "$pending_materials_saved" "${DEPLOY}/config/materials-applied.json"

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

SCHEDULER_LOCK="${DEPLOY}/data/runtime/scheduler-scan.lock"
mkdir -m 0700 -- "$SCHEDULER_LOCK"
invoke --local
(( LAST_RC == 1 )) || fail '旧版无所有权扫描空锁应阻断新调度运行'
assert_result runtime.scheduler_lock FAIL
invoke --local --fix
(( LAST_RC == 0 )) || fail '显式安全修复未在停写窗口迁移旧版扫描空锁'
assert_result runtime.scheduler_lock PASS
jq -e 'any(.fix.actions[]; .id == "fix.runtime.scheduler_lock" and .status == "PASS")' "$OUT" >/dev/null \
  || fail '旧版扫描锁修复缺少结构化动作结果'
[[ ! -e "$SCHEDULER_LOCK" && ! -L "$SCHEDULER_LOCK" ]] || fail '旧版扫描空锁仍残留'
grep -Eq ' stop n8n$' "$FIXTURE_LOG" || fail '扫描锁修复未先停止 n8n 写入'
grep -Eq ' up -d n8n$' "$FIXTURE_LOG" || fail '扫描锁修复后未恢复 n8n'

mkdir -m 0700 -- "$SCHEDULER_LOCK"
jq -M -n --arg boot "$(tr -d '\n' < /proc/sys/kernel/random/boot_id)" --arg start '1' \
  '{schema_version:1,token:("a"*32),pid:1,boot_id:$boot,process_start:$start,
    started_at:1,heartbeat_at:1}' > "${SCHEDULER_LOCK}/owner.json"
chmod 0600 "${SCHEDULER_LOCK}/owner.json"
invoke --local --fix
[[ -f "${SCHEDULER_LOCK}/owner.json" ]] || fail 'doctor --fix 错误删除带所有权扫描锁'
rm -f -- "${SCHEDULER_LOCK}/owner.json"; rmdir -- "$SCHEDULER_LOCK"

mkdir -m 0700 -- "$SCHEDULER_LOCK"; printf '保留\n' > "${SCHEDULER_LOCK}/unknown"
! cleanup_legacy_scheduler_scan_lock "$DEPLOY" || fail '清理函数错误接受非空扫描锁'
[[ -f "${SCHEDULER_LOCK}/unknown" ]] || fail '清理函数错误删除非空扫描锁内容'
rm -f -- "${SCHEDULER_LOCK}/unknown"; rmdir -- "$SCHEDULER_LOCK"
mkdir -m 0700 -- "${TEST_ROOT}/scheduler-link-target"; ln -s -- "${TEST_ROOT}/scheduler-link-target" "$SCHEDULER_LOCK"
! cleanup_legacy_scheduler_scan_lock "$DEPLOY" || fail '清理函数错误接受链接扫描锁'
[[ -L "$SCHEDULER_LOCK" ]] || fail '清理函数错误删除扫描锁链接'
unlink -- "$SCHEDULER_LOCK"; rmdir -- "${TEST_ROOT}/scheduler-link-target"
pass '旧版 ownerless 空锁仅由维护锁与 n8n 停写修复，带 owner、非空和链接锁均保留'

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
doctor_workflow_lexical_cases
export DOCTOR_FIXTURE_N8N_CODE_FAIL=1
export DOCTOR_FIXTURE_N8N_ACTIVE_EXECUTIONS=40
export DOCTOR_FIXTURE_N8N_OLDER_TWO_MINUTES=25
export DOCTOR_FIXTURE_N8N_OLDER_TEN_MINUTES=7
invoke --local
(( LAST_RC == 1 )) || fail '通用 401 不能冒充 n8n Code 健康'
assert_result n8n.runtime FAIL
assert_result n8n.execution_backlog FAIL
unset DOCTOR_FIXTURE_N8N_CODE_FAIL
invoke --local
(( LAST_RC == 2 )) || fail 'Code runner 已恢复时历史执行积压应保留警告而非假装全绿或阻断'
assert_result n8n.runtime PASS
assert_result n8n.execution_backlog WARN
unset DOCTOR_FIXTURE_N8N_ACTIVE_EXECUTIONS DOCTOR_FIXTURE_N8N_OLDER_TWO_MINUTES DOCTOR_FIXTURE_N8N_OLDER_TEN_MINUTES
pass 'n8n 执行积压结合生产 Code runner 状态定位调度饥饿，恢复后保留历史告警'
export DOCTOR_FIXTURE_ADAPTER_FAIL=1
invoke --local
(( LAST_RC == 1 )) || fail 'adapter 容器路径故障应退出 1'
assert_result provider.adapter FAIL
unset DOCTOR_FIXTURE_ADAPTER_FAIL

export DOCTOR_FIXTURE_ADAPTER_CODE_MISMATCH=1
invoke --local
(( LAST_RC == 1 )) || fail 'provider-adapter 仍读取旧脚本挂载时应退出 1'
assert_result provider.adapter_code_binding FAIL
unset DOCTOR_FIXTURE_ADAPTER_CODE_MISMATCH

cp -p -- "${DEPLOY}/config/Caddyfile.example" "${DEPLOY}/config/Caddyfile"
env_set "${DEPLOY}/.env" WEBHOOK_ACCESS_MODE managed_https
invoke --local
(( LAST_RC == 0 )) || fail '受管 HTTPS 的 Caddy 当前文件挂载一致时应通过'
assert_result container.caddy PASS
assert_result caddy.file_binding PASS
export DOCTOR_FIXTURE_CADDY_FILE_MISMATCH=1
invoke --local
(( LAST_RC == 1 )) || fail 'Caddy 仍读取旧配置单文件挂载时应退出 1'
assert_result caddy.file_binding FAIL
unset DOCTOR_FIXTURE_CADDY_FILE_MISMATCH
env_set "${DEPLOY}/.env" WEBHOOK_ACCESS_MODE external_proxy
rm -f -- "${DEPLOY}/config/Caddyfile"
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

while IFS='|' read -r mode expected_summary expected_remediation; do
  export DOCTOR_FIXTURE_PROVIDER_MODE=$mode
  invoke --full
  (( LAST_RC == 1 )) || fail "Provider ${mode} 路径应在 full 退出 1"
  assert_result provider.inference FAIL
  jq -e --arg summary "$expected_summary" --arg remediation "$expected_remediation" '
    any(.results[]; .id == "provider.inference" and .status == "FAIL"
      and .summary == $summary and (.remediation | contains($remediation)))
  ' "$OUT" >/dev/null || fail "Provider ${mode} 没有显示对应的安全中文分类"
  ! jq -e 'any(.results[]; .id == "provider.inference"
    and .summary == "当前模型、协议或最终应用容器路径调用失败")' "$OUT" >/dev/null \
    || fail "Provider ${mode} 仍退化为笼统故障提示"
  ! grep -q 'doctor-fixture-ai_api_key-do-not-print' "$OUT" "$ERR" "$FIXTURE_LOG" \
    || fail "Provider ${mode} 诊断输出泄露 Provider Key"
done <<'PROVIDER_DIAGNOSTIC_CASES'
authentication|当前接口鉴权失败|地址与 Key
model|当前模型原名或推理端点不可用|模型、协议及 Base URL
upstream|上游服务或容器网络连接不可用|DNS/TLS
protocol|接口协议、地址路径或请求格式不兼容|Chat Completions / Responses
timeout|实际推理在限定时间内未完成|主备总预算
empty|上游返回空正文、非 JSON 或与所选协议不符|Chat/Responses
error-json|上游返回空正文、非 JSON 或与所选协议不符|Chat/Responses
PROVIDER_DIAGNOSTIC_CASES
unset DOCTOR_FIXTURE_PROVIDER_MODE

export DOCTOR_FIXTURE_RETRIEVAL_FAIL=1
invoke --full
(( LAST_RC == 1 )) || fail '知识检索错误应在 full 退出 1'
assert_result provider.inference FAIL
jq -e 'any(.results[]; .id == "provider.inference" and .status == "FAIL"
  and .summary == "知识检索或启用资料映射未通过"
  and (.remediation | contains("索引")))' "$OUT" >/dev/null \
  || fail '检索错误被笼统归类为 Provider 推理故障'
! grep -q '^admin-query generation ' "$FIXTURE_LOG" || fail 'full 检索错误后仍调用 Provider'
unset DOCTOR_FIXTURE_RETRIEVAL_FAIL
pass 'full 自检区分鉴权、模型、协议路径、上游、超时、无效响应和检索故障，且不输出原始错误或秘密'

invoke --full
(( LAST_RC == 0 )) || fail "健康 full 自检退出码应为 0，实际 ${LAST_RC}"
assert_result provider.inference PASS
grep -Fq 'exec -T n8n node /opt/crisp-ai/n8n/admin-query.js' "$FIXTURE_LOG" || fail 'full 没有从受控 n8n 管理员入口执行同链检查'
[[ $(grep -c '^admin-query settings-source=applied-projection$' "$FIXTURE_LOG") == 1 \
  && $(grep -c '^admin-query vector-search pure-query=true$' "$FIXTURE_LOG") == 1 \
  && $(grep -c '^admin-query generation path=/responses prompt-complete=true knowledge-complete=true scope=legacy$' "$FIXTURE_LOG") == 1 ]] \
  || fail 'full 必须真实执行管理员 runtime 的已应用温度、纯问题检索与完整 Prompt/片段生成'
! grep -q '^admin-query workspace-read=true$' "$FIXTURE_LOG" || fail '已应用温度不应每问再次读取完整工作区文档'
! grep -Eq '/api/v1/workspace/[^ ]*/chat|CRISPAI_PROVIDER_CONTEXT_V1:|仅作管理员连接检查，请简短回复连接正常。' "$FIXTURE_LOG" \
  || fail 'full 仍使用旧 chat/正文信封，或把问题写入命令日志'
[[ "$before" == "$(business_hash)" ]] || fail 'full 自检改动了配置、知识或会话状态'
pass '只有 full 经实际管理员 runtime 执行纯检索与完整上下文生成，且不修改客户状态'

invoke_query() {
  local question=$1 budget=${2:-0}
  : > "$OUT"; : > "$ERR"; : > "$FIXTURE_LOG"
  LAST_RC=0
  # shellcheck disable=SC2016
  printf '%s' "$question" | fixture_env bash -c '
    set -euo pipefail
    source "$1/configuration.sh"
    question=$(cat)
    configuration_query "$2" "$question" "$3"
  ' doctor-query "${DEPLOY}/scripts" "$DEPLOY" "$budget" > "$OUT" 2> "$ERR" || LAST_RC=$?
}

query='这是虚构的管理员问题：请保留 "引号" 与反斜线 \\，不把问题写入命令参数。'
export DOCTOR_FIXTURE_ADMIN_EXPECT_QUESTION_SHA256
DOCTOR_FIXTURE_ADMIN_EXPECT_QUESTION_SHA256=$(printf '%s' "$query" | sha256sum | awk '{print $1}')
DOCTOR_FIXTURE_ADMIN_EXPECT_BUDGET=0 invoke_query "$query"
(( LAST_RC == 0 )) || fail '管理员默认预算/特殊字符 stdin 传递失败'
jq -e '.answer == "合成协议连接正常" and .sources == ["custom-documents/fixture.json"]
  and .verified == true and .retrieval_state == "knowledge_hit"' "$OUT" >/dev/null \
  || fail '管理员结果未保留 answer/sources/verified 结构'
! grep -Fq "$query" "$FIXTURE_LOG" "$ERR" || fail '管理员问题泄露到日志或命令参数'
DOCTOR_FIXTURE_ADMIN_INVALID_RESULT=1 invoke_query "$query" 1000
[[ "$LAST_RC" == 1 && ! -s "$OUT" ]] || fail '未验证管理员响应不能冒充成功'
grep -Fq 'Provider 返回了空正文、非 JSON 或不符合所选协议的响应' "$ERR" \
  || fail '管理员无效响应没有对应的安全中文说明'
! grep -Fq '当前模型、协议或最终应用容器路径调用失败' "$ERR" \
  || fail '管理员无效响应仍退化为笼统故障说明'
! find "${DEPLOY}/tmp" -maxdepth 1 -name 'configuration-query.*' -print -quit | grep -q . \
  || fail '管理员成功或失败遗留含答案的临时文件'
pass '管理员 stdin 保留原问题，验证输出结构并清理受限临时结果'

for failure in DOCTOR_FIXTURE_RETRIEVAL_FAIL DOCTOR_FIXTURE_RETRIEVAL_UNKNOWN; do
  export "$failure=1"
  invoke_query "$query" 1000
  unset "$failure"
  [[ "$LAST_RC" == 1 && ! -s "$OUT" ]] || fail '坏检索/未映射来源不能作为管理员成功'
  grep -q '^admin-query vector-search pure-query=true$' "$FIXTURE_LOG" || fail '管理员负例未到真实检索协议分支'
  ! grep -q '^admin-query generation ' "$FIXTURE_LOG" || fail '坏检索/未映射来源仍触发模型'
done
[[ "$before" == "$(business_hash)" ]] || fail '管理员检索负例修改客户或配置状态'
pass '管理员检索错误及未知来源准确失败，零模型调用且不降格成知识未命中'

# 这里仅验证生产 runtime 的签名/预算协议，不伪造完整 adapter 或模型验收。
[[ ! -e "${DEPLOY}/config/provider-pool-applied.json" ]] || fail '管理员池协议夹具覆盖了已有配置'
cp -p -- "$RUNTIME_ENV_FILE" "${TEST_ROOT}/admin-runtime-env.saved"
jq -M -n '{schema_version:1,revision:9,primary_id:"p_111111111111111111111111",
  entries:[{id:"p_111111111111111111111111",model:"synthetic-admin-model"}],policy:{question_timeout_ms:1500}}' \
  > "${DEPLOY}/config/provider-pool-applied.json"
jq '.n8n=(.n8n[0:10]+["http://provider-adapter:8787/v1","synthetic-admin-internal-key","true"])' \
  "$RUNTIME_ENV_FILE" > "${RUNTIME_ENV_FILE}.new"
mv -f -- "${RUNTIME_ENV_FILE}.new" "$RUNTIME_ENV_FILE"
DOCTOR_FIXTURE_ADMIN_EXPECT_BUDGET=10000 invoke_query "$query" 10000
(( LAST_RC == 0 )) || fail '管理员新池签名或较小池预算绑定未通过'
grep -q '^admin-query generation .*scope=admin$' "$FIXTURE_LOG" || fail '管理员新池没有验证 admin HMAC 及池/资料代次'
rm -f -- "${DEPLOY}/config/provider-pool-applied.json"
cp -p -- "${TEST_ROOT}/admin-runtime-env.saved" "$RUNTIME_ENV_FILE"
[[ "$before" == "$(business_hash)" ]] || fail '管理员签名协议检查未恢复原夹具'
pass '新池管理员同链使用受签名 admin scope、当前代和不超过池上限的预算'

started=$SECONDS
DOCTOR_FIXTURE_ADMIN_DELAY_SECONDS=10 invoke_query "$query" 1000
elapsed=$((SECONDS-started))
(( LAST_RC == 1 && elapsed >= 5 && elapsed < 9 )) || fail "管理员有界 Compose 超时无效（${elapsed} 秒）"
[[ ! -s "$OUT" ]] || fail '管理员超时返回了假成功'
! find "${DEPLOY}/tmp" -maxdepth 1 -name 'configuration-query.*' -print -quit | grep -q . \
  || fail '管理员超时遗留含答案的临时文件'
invoke_query "$query" 180001
[[ "$LAST_RC" == 1 && ! -s "$FIXTURE_LOG" ]] || fail '超限预算不应调用容器'
unset DOCTOR_FIXTURE_ADMIN_EXPECT_QUESTION_SHA256
pass '管理员总预算加有限回程余量，挂起调用被终止，超限输入零执行'

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
