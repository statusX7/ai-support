#!/usr/bin/env bash
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
work=$(mktemp -d "${PROJECT_ROOT}/.test-runtime.caddy-callers.XXXXXX")

cleanup() {
  [[ "$work" == "${PROJECT_ROOT}"/.test-runtime.caddy-callers.* && -d "$work" && ! -L "$work" ]] \
    && find "$work" -depth -delete
}
trap cleanup EXIT

fail() {
  printf '失败：%s\n' "$*" >&2
  exit 1
}

pass() {
  printf '通过：[UNIT/CONTRACT] %s\n' "$*"
}

fixture_env_get() {
  local env_file=$1 key=$2
  sed -n "s/^${key}=//p" "$env_file" | head -n 1
}

write_caller_common() {
  local target=$1
  mkdir -p -- "$(dirname -- "$target")"
  cat > "$target" <<'MOCK_COMMON'
#!/usr/bin/env bash
# shellcheck source=scripts/common.sh
source "${CADDY_CALLERS_PROJECT_ROOT:?}/scripts/common.sh"

caller_trace() {
  printf '%s\n' "$*" >> "${CADDY_CALLERS_TRACE:?}"
}

acquire_maintenance_lock() {
  caller_trace 'lock'
}

webhook_ports_available() {
  return 0
}

docker_compose_command() {
  caller_trace "compose-command:$*"
  return 0
}

docker_compose() {
  local deploy_dir=$1
  shift
  caller_trace "compose:$*"
  return 0
}

caddy_validate_configuration_file() {
  local deploy_dir=$1 candidate=$2 candidate_env=${3:-${1}/.env}
  local live_mode candidate_mode same_file=false
  live_mode=$(env_get "${deploy_dir}/.env" WEBHOOK_ACCESS_MODE 2>/dev/null || printf missing)
  candidate_mode=$(env_get "$candidate_env" WEBHOOK_ACCESS_MODE 2>/dev/null || printf missing)
  [[ "$candidate_env" == "${deploy_dir}/.env" ]] && same_file=true
  caller_trace "validate:live=${live_mode}:candidate=${candidate_mode}:same=${same_file}:staged=$([[ "$candidate" == "${deploy_dir}/config/Caddyfile" ]] && printf no || printf yes)"
  [[ "${MOCK_CADDY_VALIDATE_FAIL:-0}" != 1 ]]
}

reconcile_caddy_runtime() {
  local deploy_dir=$1 count=0 mode
  [[ -f "${CADDY_CALLERS_RECONCILE_COUNT:?}" ]] \
    && count=$(<"${CADDY_CALLERS_RECONCILE_COUNT}")
  (( count += 1 ))
  printf '%s\n' "$count" > "$CADDY_CALLERS_RECONCILE_COUNT"
  mode=$(env_get "${deploy_dir}/.env" WEBHOOK_ACCESS_MODE 2>/dev/null || printf missing)
  caller_trace "reconcile:${count}:${mode}"
  if [[ "${MOCK_RECONCILE_FAIL_ONCE:-0}" == 1 && $count -eq 1 ]]; then
    printf '合成运行态变更，不得在失败后保留。\n' > "${deploy_dir}/config/Caddyfile"
    return 1
  fi
  [[ "${MOCK_RECONCILE_ALWAYS_FAIL:-0}" != 1 ]]
}

write_webhook_proxy_snippets() {
  local deploy_dir=$1 production
  production=$(env_get "$deploy_dir/.env" WEBHOOK_PRODUCTION_URL 2>/dev/null || printf missing)
  caller_trace "proxy-snippets:${production}"
  printf '# ai-support-managed-proxy\n%s\n' "$production" \
    > "$deploy_dir/config/crispai-nginx.conf"
  printf '# ai-support-managed-proxy\n%s\n' "$production" \
    > "$deploy_dir/config/crispai-caddy.conf"
  chmod 0640 "$deploy_dir/config/crispai-nginx.conf" \
    "$deploy_dir/config/crispai-caddy.conf"
}

wait_for_local_health() {
  caller_trace 'wait-health'
}

import_and_publish_workflow() {
  caller_trace 'workflow-published'
}

crisp_api_check() {
  CRISP_API_STATUS=200
  return 0
}

webhook_access_check() {
  return 0
}

refresh_conversation_fact() {
  set_installation_fact "$1" conversation ready
}

require_docker_runtime() {
  caller_trace 'docker-runtime'
}

migrate_config_files() {
  caller_trace 'migrate-config'
}

set_runtime_ownership() {
  caller_trace 'runtime-ownership'
}

secure_permissions() {
  caller_trace 'secure-permissions'
}

bootstrap_anythingllm_api_key() {
  caller_trace 'anything-key'
}

ensure_anythingllm_workspace() {
  caller_trace 'anything-workspace'
}

knowledge_sync() {
  caller_trace 'knowledge-sync'
}

sync_prompt_to_anythingllm() {
  caller_trace 'prompt-sync'
}

install_log_maintenance() {
  caller_trace 'log-maintenance'
}

record_maintenance_event() {
  caller_trace "maintenance:$2:$3"
}
MOCK_COMMON
  chmod 0600 "$target"
}

write_caller_wizard() {
  local target=$1
  cat > "$target" <<'MOCK_WIZARD'
#!/usr/bin/env bash
# shellcheck source=scripts/wizard.sh
source "${CADDY_CALLERS_PROJECT_ROOT:?}/scripts/wizard.sh"
MOCK_WIZARD
  chmod 0600 "$target"
}

reset_trace() {
  : > "$CADDY_CALLERS_TRACE"
  printf '0\n' > "$CADDY_CALLERS_RECONCILE_COUNT"
}

write_installation_marker_fixture() {
  local deploy=$1
  cat > "${deploy}/.crisp-ai-installation" <<EOF
ai-support
state=ready
source=${PROJECT_ROOT}
installed_version=v1.2.1
fact_dependencies=ready
fact_local_services=ready
fact_app_config=ready
fact_provider=ready
fact_crisp_api=ready
fact_webhook=ready
fact_conversation=ready
EOF
  chmod 0600 "${deploy}/.crisp-ai-installation"
}

write_crisp_env_fixture() {
  local deploy=$1
  cat > "${deploy}/.env" <<'EOF'
CRISP_WEBSITE_ID=synthetic-website-id
CRISP_TOKEN_IDENTIFIER=synthetic-identifier
CRISP_TOKEN_KEY=synthetic-token-key
CRISP_AUTH_B64=c3ludGhldGljLWlkZW50aWZpZXI6c3ludGhldGljLXRva2VuLWtleQ==
CRISP_TOKEN_TIER=website
CRISP_HOOK_MODE=website
CRISP_WEBSITE_HOOK_SECRET=synthetic-hook-secret
WEBHOOK_ACCESS_MODE=external_proxy
PUBLIC_WEBHOOK_URL=https://old.example.invalid/
WEBHOOK_PRODUCTION_URL=https://old.example.invalid/webhook/crisp-webhook
WEBHOOK_DOMAIN=old.example.invalid
N8N_HOST=old.example.invalid
N8N_PROTOCOL=https
N8N_SECURE_COOKIE=true
N8N_PORT=5678
EOF
  chmod 0600 "${deploy}/.env"
}

setup_crisp_fixture() {
  local deploy=$1
  mkdir -p -- "${deploy}/scripts" "${deploy}/config" "${deploy}/tmp" \
    "${deploy}/backups/config-history"
  install -m 0700 -- "${PROJECT_ROOT}/scripts/crisp-settings.sh" \
    "${deploy}/scripts/crisp-settings.sh"
  write_caller_common "${deploy}/scripts/common.sh"
  write_caller_wizard "${deploy}/scripts/wizard.sh"
  write_installation_marker_fixture "$deploy"
  write_crisp_env_fixture "$deploy"
  printf 'v1.2.1\n' > "${deploy}/VERSION"
  printf 'services: {}\n' > "${deploy}/docker-compose.yml"
  printf '旧有效 Caddy 配置。\n' > "${deploy}/config/Caddyfile"
  printf '模板 Caddy 配置。\n' > "${deploy}/config/Caddyfile.example"
  printf '# ai-support-managed-proxy\n旧有效 Nginx 片段。\n' \
    > "${deploy}/config/crispai-nginx.conf"
  printf '# ai-support-managed-proxy\n旧有效 Caddy 片段。\n' \
    > "${deploy}/config/crispai-caddy.conf"
  chmod 0640 "${deploy}/config/Caddyfile" "${deploy}/config/Caddyfile.example" \
    "${deploy}/config/crispai-nginx.conf" "${deploy}/config/crispai-caddy.conf"
}

export CADDY_CALLERS_PROJECT_ROOT="$PROJECT_ROOT"
export CADDY_CALLERS_TRACE="$work/trace"
export CADDY_CALLERS_RECONCILE_COUNT="$work/reconcile-count"
reset_trace

crisp_deploy="$work/crisp-deploy"
setup_crisp_fixture "$crisp_deploy"
candidate="$work/crisp-candidate.json"
printf '%s\n' '{"webhook_input":"support.example.invalid"}' > "$candidate"
chmod 0600 "$candidate"

old_env_hash=$(sha256sum -- "$crisp_deploy/.env"); old_env_hash=${old_env_hash%% *}
old_caddy_hash=$(sha256sum -- "$crisp_deploy/config/Caddyfile"); old_caddy_hash=${old_caddy_hash%% *}
old_nginx_hash=$(sha256sum -- "$crisp_deploy/config/crispai-nginx.conf"); old_nginx_hash=${old_nginx_hash%% *}
old_proxy_caddy_hash=$(sha256sum -- "$crisp_deploy/config/crispai-caddy.conf"); old_proxy_caddy_hash=${old_proxy_caddy_hash%% *}
if MOCK_CADDY_VALIDATE_FAIL=1 bash "$crisp_deploy/scripts/crisp-settings.sh" \
  --deploy-dir "$crisp_deploy" apply "$candidate" > "$work/crisp-invalid.log" 2>&1; then
  fail 'Crisp 公网入口接受了未通过 Caddy 校验的候选配置'
fi
[[ "$(sha256sum -- "$crisp_deploy/.env" | cut -d ' ' -f 1)" == "$old_env_hash" ]] \
  || fail 'Caddy 候选预检失败后 Crisp .env 已被覆盖'
[[ "$(sha256sum -- "$crisp_deploy/config/Caddyfile" | cut -d ' ' -f 1)" == "$old_caddy_hash" ]] \
  || fail 'Caddy 候选预检失败后实际 Caddyfile 已被覆盖'
[[ "$(sha256sum -- "$crisp_deploy/config/crispai-nginx.conf" | cut -d ' ' -f 1)" == "$old_nginx_hash" ]] \
  || fail 'Caddy 候选预检失败后 Nginx 片段已被覆盖'
[[ "$(sha256sum -- "$crisp_deploy/config/crispai-caddy.conf" | cut -d ' ' -f 1)" == "$old_proxy_caddy_hash" ]] \
  || fail 'Caddy 候选预检失败后外部 Caddy 片段已被覆盖'
grep -Fxq 'validate:live=external_proxy:candidate=managed_https:same=false:staged=no' \
  "$CADDY_CALLERS_TRACE" || fail 'Crisp 修改未使用独立候选 .env 做 Caddy 预检'
if grep -Eq '^(compose:|reconcile:)' "$CADDY_CALLERS_TRACE"; then
  fail 'Caddy 候选预检失败后仍启动或协调了运行服务'
fi
grep -Fq '原配置与运行服务保持' "$work/crisp-invalid.log" \
  || fail 'Crisp Caddy 候选失败没有清楚说明原配置保持'
pass 'Crisp 公网入口先用候选环境校验 Caddy，失败时零配置/运行态修改'

reset_trace
bash "$crisp_deploy/scripts/crisp-settings.sh" --deploy-dir "$crisp_deploy" \
  apply "$candidate" > "$work/crisp-success.log" 2>&1
[[ "$(fixture_env_get "$crisp_deploy/.env" WEBHOOK_ACCESS_MODE)" == managed_https ]] \
  || fail 'Crisp 公网入口成功后没有保存受管 HTTPS 模式'
[[ "$(fixture_env_get "$crisp_deploy/.env" WEBHOOK_DOMAIN)" == support.example.invalid ]] \
  || fail 'Crisp 公网入口成功后没有回读新域名'
grep -Fxq 'validate:live=external_proxy:candidate=managed_https:same=false:staged=no' \
  "$CADDY_CALLERS_TRACE" || fail 'Crisp 成功路径遗漏候选 Caddy 校验'
grep -Fxq 'reconcile:1:managed_https' "$CADDY_CALLERS_TRACE" \
  || fail 'Crisp 成功保存后没有按新配置协调 Caddy 运行代'
validate_line=$(grep -n '^validate:' "$CADDY_CALLERS_TRACE" | head -n 1 | cut -d : -f 1)
reconcile_line=$(grep -n '^reconcile:' "$CADDY_CALLERS_TRACE" | head -n 1 | cut -d : -f 1)
[[ "$validate_line" -lt "$reconcile_line" ]] \
  || fail 'Crisp Caddy 校验发生在运行态协调之后'
grep -Fxq 'workflow-published' "$CADDY_CALLERS_TRACE" \
  || fail 'Crisp 公网入口成功后没有继续应用生产 workflow'
pass 'Crisp 公网入口保存后按新模式协调 Caddy，并继续完成运行时应用'

setup_crisp_fixture "$crisp_deploy"
reset_trace
old_env_hash=$(sha256sum -- "$crisp_deploy/.env"); old_env_hash=${old_env_hash%% *}
old_caddy_hash=$(sha256sum -- "$crisp_deploy/config/Caddyfile"); old_caddy_hash=${old_caddy_hash%% *}
old_nginx_hash=$(sha256sum -- "$crisp_deploy/config/crispai-nginx.conf"); old_nginx_hash=${old_nginx_hash%% *}
old_proxy_caddy_hash=$(sha256sum -- "$crisp_deploy/config/crispai-caddy.conf"); old_proxy_caddy_hash=${old_proxy_caddy_hash%% *}
if MOCK_RECONCILE_FAIL_ONCE=1 bash "$crisp_deploy/scripts/crisp-settings.sh" \
  --deploy-dir "$crisp_deploy" apply "$candidate" > "$work/crisp-runtime-fail.log" 2>&1; then
  fail 'Crisp Caddy 运行态协调失败后仍报告应用成功'
fi
[[ "$(sha256sum -- "$crisp_deploy/.env" | cut -d ' ' -f 1)" == "$old_env_hash" ]] \
  || fail 'Crisp Caddy 运行态协调失败后没有恢复旧 .env'
[[ "$(sha256sum -- "$crisp_deploy/config/Caddyfile" | cut -d ' ' -f 1)" == "$old_caddy_hash" ]] \
  || fail 'Crisp Caddy 运行态协调失败后没有恢复旧 Caddyfile'
[[ "$(sha256sum -- "$crisp_deploy/config/crispai-nginx.conf" | cut -d ' ' -f 1)" == "$old_nginx_hash" ]] \
  || fail 'Crisp Caddy 运行态协调失败后没有恢复旧 Nginx 片段'
[[ "$(sha256sum -- "$crisp_deploy/config/crispai-caddy.conf" | cut -d ' ' -f 1)" == "$old_proxy_caddy_hash" ]] \
  || fail 'Crisp Caddy 运行态协调失败后没有恢复旧外部 Caddy 片段'
grep -Fxq 'reconcile:1:managed_https' "$CADDY_CALLERS_TRACE" \
  || fail 'Crisp 运行态失败夹具没有在新模式触发'
grep -Fxq 'reconcile:2:external_proxy' "$CADDY_CALLERS_TRACE" \
  || fail 'Crisp 运行态失败后没有按旧配置再次协调代理'
grep -Fq '原配置与反向代理运行代已恢复' "$work/crisp-runtime-fail.log" \
  || fail 'Crisp 自动回退成功后没有准确报告恢复结果'
pass 'Crisp Caddy 运行态协调失败会恢复旧 .env、Caddyfile、两份代理片段与运行模式'

setup_restore_fixture() {
  local deploy=$1
  rm -rf -- "$deploy"
  mkdir -p -- "${deploy}/scripts" "${deploy}/config" "${deploy}/tmp" \
    "${deploy}/backups" "${deploy}/data/runtime" "${deploy}/knowledge" "${deploy}/n8n"
  install -m 0700 -- "${PROJECT_ROOT}/scripts/restore.sh" "${deploy}/scripts/restore.sh"
  write_caller_common "${deploy}/scripts/common.sh"
  write_installation_marker_fixture "$deploy"
  cat > "${deploy}/.env" <<'EOF'
WEBHOOK_ACCESS_MODE=managed_https
COMPOSE_PROFILES=managed-https
EOF
  chmod 0600 "${deploy}/.env"
  printf 'services: {}\n' > "${deploy}/docker-compose.yml"
  printf '恢复前 Prompt。\n' > "${deploy}/config/prompt.md"
  printf '恢复前 Caddy。\n' > "${deploy}/config/Caddyfile"
  printf '%s\n' '{"version":1,"files":{},"pending_files":{},"garbage_locations":[]}' \
    > "${deploy}/data/knowledge-manifest.json"
  chmod 0600 "${deploy}/data/knowledge-manifest.json"
}

restore_source="$work/restore-source"
mkdir -p -- "$restore_source/config" "$restore_source/knowledge"
printf '%s\n' '{"format":"ai-support-backup-v1","contains_secrets":false}' \
  > "$restore_source/manifest.json"
printf '恢复包 Prompt。\n' > "$restore_source/config/prompt.md"
printf '恢复包 Caddy。\n' > "$restore_source/config/Caddyfile"
(
  cd -- "$restore_source"
  sha256sum manifest.json config/prompt.md config/Caddyfile > checksums.sha256
)
restore_archive="$work/restore-caddy.tar.gz"
tar -C "$restore_source" -czf "$restore_archive" \
  manifest.json checksums.sha256 config/prompt.md config/Caddyfile knowledge

restore_deploy="$work/restore-deploy"
setup_restore_fixture "$restore_deploy"
reset_trace
restore_prompt_hash=$(sha256sum -- "$restore_deploy/config/prompt.md"); restore_prompt_hash=${restore_prompt_hash%% *}
restore_caddy_hash=$(sha256sum -- "$restore_deploy/config/Caddyfile"); restore_caddy_hash=${restore_caddy_hash%% *}
if MOCK_CADDY_VALIDATE_FAIL=1 bash "$restore_deploy/scripts/restore.sh" \
  --deploy-dir "$restore_deploy" --input "$restore_archive" --no-safety-backup \
  > "$work/restore-invalid.log" 2>&1; then
  fail '恢复流程接受了未通过校验的 Caddyfile'
fi
[[ "$(sha256sum -- "$restore_deploy/config/prompt.md" | cut -d ' ' -f 1)" == "$restore_prompt_hash" ]] \
  || fail '恢复包 Caddy 预检失败前已覆盖 Prompt'
[[ "$(sha256sum -- "$restore_deploy/config/Caddyfile" | cut -d ' ' -f 1)" == "$restore_caddy_hash" ]] \
  || fail '恢复包 Caddy 预检失败前已覆盖实际 Caddyfile'
grep -Eq '^validate:live=managed_https:candidate=managed_https:same=true:staged=yes$' \
  "$CADDY_CALLERS_TRACE" || fail '恢复流程未校验 staging 中的 Caddyfile'
if grep -Eq '^compose:stop ' "$CADDY_CALLERS_TRACE"; then
  fail '恢复包 Caddy 预检失败后仍停止了应用服务'
fi
grep -Fq '尚未停止服务或覆盖现有资料' "$work/restore-invalid.log" \
  || fail '恢复包 Caddy 预检失败没有准确说明零资料修改'
pass '恢复包中的 Caddyfile 在停服和资料覆盖前完成版本校验'

setup_restore_fixture "$restore_deploy"
reset_trace
if MOCK_RECONCILE_ALWAYS_FAIL=1 bash "$restore_deploy/scripts/restore.sh" \
  --deploy-dir "$restore_deploy" --input "$restore_archive" --no-safety-backup \
  > "$work/restore-runtime-fail.log" 2>&1; then
  fail '恢复后 Caddy 运行态协调失败仍返回成功'
fi
grep -Fq '恢复后的反向代理配置或运行代未通过对账；未宣称恢复完成' \
  "$work/restore-runtime-fail.log" \
  || fail '恢复后 Caddy 运行态失败没有准确中止原因'
grep -Fxq 'reconcile:1:managed_https' "$CADDY_CALLERS_TRACE" \
  || fail '恢复覆盖后没有执行 Caddy 运行态对账'
if grep -Eq '^(wait-health|anything-key|anything-workspace|knowledge-sync|prompt-sync|workflow-published|log-maintenance|maintenance:restore:complete)$' \
  "$CADDY_CALLERS_TRACE"; then
  fail 'Caddy 运行态对账失败后仍继续下游应用或记录恢复完成'
fi
grep -Fxq 'compose:up -d n8n anythingllm' "$CADDY_CALLERS_TRACE" \
  || fail 'Caddy 对账失败后没有恢复已停止的应用服务'
[[ "$(<"$restore_deploy/config/Caddyfile")" == '恢复包 Caddy。' ]] \
  || fail '恢复运行态夹具没有到达 Caddyfile 覆盖阶段'
pass '恢复后 Caddy 运行代对账失败会准确中止且不继续宣称完成'

setup_restore_fixture "$restore_deploy"
reset_trace
bash "$restore_deploy/scripts/restore.sh" --deploy-dir "$restore_deploy" \
  --input "$restore_archive" --no-safety-backup > "$work/restore-success.log" 2>&1
grep -Fxq 'maintenance:restore:complete' "$CADDY_CALLERS_TRACE" \
  || fail '合法恢复完成后没有记录维护结果'
grep -Fxq 'reconcile:1:managed_https' "$CADDY_CALLERS_TRACE" \
  || fail '合法恢复没有对账 Caddy 运行代'
grep -Fxq 'workflow-published' "$CADDY_CALLERS_TRACE" \
  || fail '合法恢复没有继续发布 workflow'
grep -Fq '备份恢复完成' "$work/restore-success.log" \
  || fail '合法恢复没有返回完成提示'
pass '合法 Caddy 备份恢复完成运行态对账和后续应用'
