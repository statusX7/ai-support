#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
ORIGINAL_PATH=$PATH
WORK=$(mktemp -d "${PROJECT_ROOT}/.test-runtime.install-resume.XXXXXX")

cleanup() {
  if [[ "${AI_SUPPORT_TEST_KEEP_TMP:-0}" == 1 ]]; then
    printf '调试目录已保留：%s\n' "$WORK" >&2
    return
  fi
  if [[ "$WORK" == "${PROJECT_ROOT}"/.test-runtime.install-resume.* && -d "$WORK" ]]; then
    rm -rf -- "$WORK"
  fi
}
trap cleanup EXIT

fail() {
  printf '失败：%s\n' "$1" >&2
  exit 1
}

digest() {
  local value
  value=$(sha256sum -- "$1") || return 1
  printf '%s\n' "${value%% *}"
}

export PATH="${SCRIPT_DIR}/mocks:${ORIGINAL_PATH}"
export MOCK_DOCKER_LOG="${WORK}/docker.log"
export MOCK_ANYTHING_STATE="${WORK}/anythingllm-state.json"
export MOCK_SYSTEMD_STATE="${WORK}/systemd-state"
export MOCK_CHOWN_ROOT="$WORK"
export MOCK_DOCKER_STRICT_CONFIG=1
export CRISPAI_LOGS_SYSTEMD_TEST=1
export CRISPAI_LOGS_SYSTEMD_DIR="${WORK}/systemd"
export CRISP_AI_BOOTSTRAP_TEST_MODE=1
export CRISP_AI_BOOTSTRAP_OS_RELEASE="${WORK}/host/etc/os-release"
export CRISP_AI_BOOTSTRAP_ETC_ROOT="${WORK}/host/etc"
export CRISP_AI_BOOTSTRAP_INIT=unsupported
mkdir -p -- "${WORK}/host/etc/ssl/certs" "${WORK}/bin" \
  "$MOCK_SYSTEMD_STATE" "$CRISPAI_LOGS_SYSTEMD_DIR"
printf '%s\n' 'ID=debian' 'VERSION_ID="12"' 'VERSION_CODENAME=bookworm' \
  > "$CRISP_AI_BOOTSTRAP_OS_RELEASE"
printf '%s\n' 'synthetic CA bundle' > "${WORK}/host/etc/ssl/certs/ca-certificates.crt"
printf '{"documents":[]}\n' > "$MOCK_ANYTHING_STATE"
: > "$MOCK_DOCKER_LOG"

DEPLOY="${WORK}/deploy"
COMMAND="${WORK}/bin/crispai"
env \
  AI_API_BASE_URL=https://provider.invalid \
  AI_API_KEY=synthetic-resume-provider-key \
  AI_MODEL=gpt-vision-test \
  AI_SUPPORTS_VISION=false \
  CRISP_WEBSITE_ID=33333333-3333-4333-8333-333333333333 \
  CRISP_TOKEN_TIER=website \
  CRISP_TOKEN_IDENTIFIER=synthetic-resume-identifier \
  CRISP_TOKEN_KEY=synthetic-resume-crisp-key \
  ANYTHINGLLM_API_KEY=synthetic-resume-anything-key \
  N8N_HOST=resume.example.invalid \
  PUBLIC_WEBHOOK_URL=https://resume.example.invalid/ \
  WEBHOOK_ACCESS_MODE=external_proxy \
  TIMEZONE=UTC \
  "$PROJECT_ROOT/install.sh" --deploy-dir "$DEPLOY" --command-path "$COMMAND" \
    --non-interactive --skip-start > "${WORK}/stage.log" 2>&1

grep -Fxq 'state=staged' "${DEPLOY}/.crisp-ai-installation" \
  || fail '首次 --skip-start 未形成 staged 状态'
if grep -Eq '(^| )(up|stop|restart)( |$)' "$MOCK_DOCKER_LOG"; then
  fail '首次 --skip-start 触发了 Docker/Caddy 运行态变更'
fi
[[ -f "${DEPLOY}/config/provider-pool-applied.json" ]] \
  || fail 'staged 部署缺少有效接口池投影'
install -m 0600 -- "${DEPLOY}/.env" "${WORK}/staged.env"
provider_before=$(digest "${DEPLOY}/config/provider.yaml")
pool_before=$(digest "${DEPLOY}/config/provider-pool-applied.json")
generation=$(jq -er '.secrets_generation' "${DEPLOY}/config/provider-pool-applied.json") \
  || fail 'staged 接口池缺少秘密代次'
secret_before=$(digest "${DEPLOY}/secrets/provider/generations/${generation}.json")
adapter_key_before=$(sed -n 's/^PROVIDER_ADAPTER_KEY=//p' "${DEPLOY}/.env")
[[ -n "$adapter_key_before" ]] || fail 'staged 部署缺少内部 Provider 认证'

resume_status=0
"$PROJECT_ROOT/install.sh" --deploy-dir "$DEPLOY" --command-path "$COMMAND" \
  --non-interactive > "${WORK}/resume.log" 2>&1 || resume_status=$?
(( resume_status == 2 )) \
  || fail "staged 无凭据续装应完成 local-ready，实际退出 ${resume_status}"
grep -Fq '已验证暂存部署的 .env 与实际配置；本次将直接启动并验收，不重新输入凭据' \
  "${WORK}/resume.log" || fail 'staged 续装未明确复用配置'
grep -Fxq 'state=local-ready' "${DEPLOY}/.crisp-ai-installation" \
  || fail 'staged 续装未进入 local-ready'
[[ -x "$COMMAND" ]] || fail 'staged 续装未安装受管命令'
for preserved_key in \
  N8N_ENCRYPTION_KEY POSTGRES_PASSWORD ANYTHINGLLM_AUTH_TOKEN ANYTHINGLLM_JWT_SECRET \
  ANYTHINGLLM_SIG_KEY ANYTHINGLLM_SIG_SALT PROVIDER_ADAPTER_KEY \
  AI_API_BASE_URL AI_API_PROBE_BASE_URL AI_API_KEY AI_MODEL AI_API_MODE \
  ANYTHINGLLM_API_KEY ANYTHINGLLM_WORKSPACE \
  CRISP_WEBSITE_ID CRISP_TOKEN_IDENTIFIER CRISP_TOKEN_KEY CRISP_AUTH_B64 \
  CRISP_WEBSITE_HOOK_SECRET PUBLIC_WEBHOOK_URL WEBHOOK_PRODUCTION_URL; do
  staged_value=$(bash -c 'source "$1/scripts/common.sh"; env_get "$2" "$3"' \
    -- "$PROJECT_ROOT" "${WORK}/staged.env" "$preserved_key")
  resumed_value=$(bash -c 'source "$1/scripts/common.sh"; env_get "$2" "$3"' \
    -- "$PROJECT_ROOT" "${DEPLOY}/.env" "$preserved_key")
  [[ "$resumed_value" == "$staged_value" ]] \
    || fail "staged 续装改变了已保存配置字段：${preserved_key}"
done
[[ "$(digest "${DEPLOY}/config/provider.yaml")" == "$provider_before" ]] \
  || fail 'staged 续装重写了 Provider 兼容投影'
[[ "$(digest "${DEPLOY}/config/provider-pool-applied.json")" == "$pool_before" ]] \
  || fail 'staged 续装改变了接口池代次'
[[ "$(digest "${DEPLOY}/secrets/provider/generations/${generation}.json")" == "$secret_before" ]] \
  || fail 'staged 续装改变了接口池秘密代次'
[[ "$(sed -n 's/^PROVIDER_ADAPTER_KEY=//p' "${DEPLOY}/.env")" == "$adapter_key_before" ]] \
  || fail 'staged 续装重新生成了内部 Provider 认证'
printf '通过：staged 部署无须重传十项配置即可继续启动，配置与秘密代次保持。\n'

# 重配置必须先完成 Webhook/Caddy 候选检查，再探测或提交 Provider。这里用
# copy_project_files 会保留、但 configure_webhook_access 会拒绝的可写 Caddyfile
# 制造失败；若把 Provider 调整到 Webhook 前，这个负例会观察到新接口代次。
POOL_SOURCE="${DEPLOY}/config/provider-pool.yaml"
POOL_APPLIED="${DEPLOY}/config/provider-pool-applied.json"
PROVIDER_PROJECTION="${DEPLOY}/config/provider.yaml"
PROVIDER_SECRET_DIR="${DEPLOY}/secrets/provider/generations"
PROVIDER_MANAGEMENT_LOG="${WORK}/provider-management.log"
pool_source_before=$(digest "$POOL_SOURCE")
pool_applied_before=$(digest "$POOL_APPLIED")
provider_projection_before=$(digest "$PROVIDER_PROJECTION")
provider_secret_tree_before=$(find "$PROVIDER_SECRET_DIR" -maxdepth 1 -type f -printf '%f\n' \
  | LC_ALL=C sort | sha256sum | cut -d ' ' -f 1)
provider_generation_before=$(jq -er '.secrets_generation' "$POOL_APPLIED") \
  || fail '重配置负例无法读取原接口池秘密代次'
provider_secret_before=$(digest "${PROVIDER_SECRET_DIR}/${provider_generation_before}.json")
ai_env_before=$(sed -n '/^AI_[A-Z0-9_]*=/p' "${DEPLOY}/.env" \
  | LC_ALL=C sort | sha256sum | cut -d ' ' -f 1)
n8n_host_before=$(bash -c 'source "$1/scripts/common.sh"; env_get "$2/.env" N8N_HOST' \
  -- "$PROJECT_ROOT" "$DEPLOY")
facts_before=$(sed -n '/^fact_[a-z_]*=/p' "${DEPLOY}/.crisp-ai-installation" \
  | sha256sum | cut -d ' ' -f 1)

printf 'synthetic unsafe Caddy candidate\n' > "${DEPLOY}/config/Caddyfile"
chmod 0666 "${DEPLOY}/config/Caddyfile"
: > "$PROVIDER_MANAGEMENT_LOG"
reconfigure_status=0
env \
  MOCK_PROVIDER_MANAGEMENT_LOG="$PROVIDER_MANAGEMENT_LOG" \
  AI_API_BASE_URL=https://provider-next.invalid \
  AI_API_KEY=synthetic-next-provider-key \
  AI_MODEL=deepseek-test \
  AI_API_MODE=chat_completions \
  AI_SUPPORTS_VISION=false \
  CRISP_WEBSITE_ID=33333333-3333-4333-8333-333333333333 \
  CRISP_TOKEN_TIER=website \
  CRISP_TOKEN_IDENTIFIER=synthetic-resume-identifier \
  CRISP_TOKEN_KEY=synthetic-resume-crisp-key \
  ANYTHINGLLM_API_KEY=synthetic-resume-anything-key \
  N8N_HOST=next.example.invalid \
  PUBLIC_WEBHOOK_URL=https://next.example.invalid/ \
  WEBHOOK_ACCESS_MODE=external_proxy \
  TIMEZONE=UTC \
  "$PROJECT_ROOT/install.sh" --deploy-dir "$DEPLOY" --command-path "$COMMAND" \
    --non-interactive --reconfigure > "${WORK}/reconfigure-caddy-failure.log" 2>&1 \
    || reconfigure_status=$?
rm -f -- "${DEPLOY}/config/Caddyfile"

(( reconfigure_status != 0 )) || fail '不安全 Caddy 候选被错误接受'
grep -Fq '当前受管 Caddy 配置不安全' "${WORK}/reconfigure-caddy-failure.log" \
  || fail 'Caddy 候选失败原因不明确'
[[ ! -s "$PROVIDER_MANAGEMENT_LOG" ]] \
  || fail 'Caddy 候选失败前调用了 Provider 探针'
[[ "$(digest "$POOL_SOURCE")" == "$pool_source_before" ]] \
  || fail 'Caddy 候选失败前改写了接口池源配置'
[[ "$(digest "$POOL_APPLIED")" == "$pool_applied_before" ]] \
  || fail 'Caddy 候选失败前提交了新接口池代次'
[[ "$(digest "$PROVIDER_PROJECTION")" == "$provider_projection_before" ]] \
  || fail 'Caddy 候选失败前改写了 Provider 兼容投影'
[[ "$(jq -er '.secrets_generation' "$POOL_APPLIED")" == "$provider_generation_before" ]] \
  || fail 'Caddy 候选失败前切换了接口池秘密代次'
[[ "$(digest "${PROVIDER_SECRET_DIR}/${provider_generation_before}.json")" == "$provider_secret_before" ]] \
  || fail 'Caddy 候选失败前改写了当前接口池秘密'
[[ "$(find "$PROVIDER_SECRET_DIR" -maxdepth 1 -type f -printf '%f\n' \
  | LC_ALL=C sort | sha256sum | cut -d ' ' -f 1)" == "$provider_secret_tree_before" ]] \
  || fail 'Caddy 候选失败留下了新的接口池秘密文件'
[[ "$(sed -n '/^AI_[A-Z0-9_]*=/p' "${DEPLOY}/.env" \
  | LC_ALL=C sort | sha256sum | cut -d ' ' -f 1)" == "$ai_env_before" ]] \
  || fail 'Caddy 候选失败前改写了 AI_* 兼容环境投影'
[[ "$(bash -c 'source "$1/scripts/common.sh"; env_get "$2/.env" N8N_HOST' \
  -- "$PROJECT_ROOT" "$DEPLOY")" == "$n8n_host_before" ]] \
  || fail 'Caddy 候选失败前改写了 N8N_HOST'
grep -Fxq 'state=installing' "${DEPLOY}/.crisp-ai-installation" \
  || fail '已复制程序的重配置失败没有保留准确的 installing 状态'
grep -Fxq "installed_version=$(<"${PROJECT_ROOT}/VERSION")" "${DEPLOY}/.crisp-ai-installation" \
  || fail '重配置失败后的安装标记版本不准确'
[[ "$(sed -n '/^fact_[a-z_]*=/p' "${DEPLOY}/.crisp-ai-installation" \
  | sha256sum | cut -d ' ' -f 1)" == "$facts_before" ]] \
  || fail '重配置失败丢失了原组件事实'
printf '通过：Webhook/Caddy 候选失败发生在 Provider 探测和提交前，接口配置保持且状态可恢复。\n'

# 安装器已经复制同版程序时不能把 marker 伪装回旧 ready；准确的 installing
# 状态必须能在不重传 Provider/Crisp 凭据的情况下继续。这里先安全暂存，前文
# 已独立覆盖 staged 随后启动到 local-ready 的完整路径。
continue_status=0
"$PROJECT_ROOT/install.sh" --deploy-dir "$DEPLOY" --command-path "$COMMAND" \
  --non-interactive --skip-start > "${WORK}/reconfigure-failure-continue.log" 2>&1 \
  || continue_status=$?
(( continue_status == 0 )) \
  || fail "重配置失败后的同版无凭据继续应成功暂存，实际退出 ${continue_status}"
grep -Fq '已验证未完成部署的 .env 与实际配置；本次将直接复用并继续，不重新输入凭据' \
  "${WORK}/reconfigure-failure-continue.log" \
  || fail '重配置失败后的继续路径没有明确复用现有配置'
grep -Fxq 'state=staged' "${DEPLOY}/.crisp-ai-installation" \
  || fail '重配置失败后的继续路径未形成可启动 staged 状态'
[[ ! -s "$PROVIDER_MANAGEMENT_LOG" ]] \
  || fail '重配置失败后的同版继续意外探测了 Provider'
[[ "$(digest "$POOL_APPLIED")" == "$pool_applied_before" ]] \
  || fail '重配置失败后的同版继续改变了接口池代次'
[[ "$(bash -c 'source "$1/scripts/common.sh"; env_get "$2/.env" N8N_HOST' \
  -- "$PROJECT_ROOT" "$DEPLOY")" == "$n8n_host_before" ]] \
  || fail '重配置失败后的继续路径改变了原 N8N_HOST'
printf '通过：重配置失败保留 installing，下一次同版运行可无凭据继续为 staged。\n'

# Webhook 候选已成功提交后，Provider 候选仍可能在真实适配器探针
# 阶段失败。重配置必须将这两个阶段视为同一安装事务，否则新
# Crisp/Webhook 与旧 Provider 会形成混合代。
# 先把隔离实例置为“受管 HTTPS 且 Caddy 正在运行”：新候选改为
# 外部反代时会真正停掉 Caddy，因此能证明失败恢复不只是文件回写。
export MOCK_CADDY_STATE="${WORK}/caddy-state"
printf 'running\n' > "$MOCK_CADDY_STATE"
chmod 0600 "$MOCK_CADDY_STATE"
install -m 0640 -- "${DEPLOY}/config/Caddyfile.example" "${DEPLOY}/config/Caddyfile"
bash -c '
  set -euo pipefail
  source "$1/scripts/common.sh"
  env_set "$2/.env" WEBHOOK_ACCESS_MODE managed_https
  env_set "$2/.env" WEBHOOK_DOMAIN resume.example.invalid
  env_set "$2/.env" COMPOSE_PROFILES managed-https
  write_webhook_proxy_snippets "$2"
' -- "$PROJECT_ROOT" "$DEPLOY"
install_env_before=$(digest "${DEPLOY}/.env")
caddyfile_before=$(digest "${DEPLOY}/config/Caddyfile")
nginx_snippet_before=$(digest "${DEPLOY}/config/crispai-nginx.conf")
caddy_snippet_before=$(digest "${DEPLOY}/config/crispai-caddy.conf")
pool_applied_before_provider_failure=$(digest "$POOL_APPLIED")
: > "$PROVIDER_MANAGEMENT_LOG"
: > "$MOCK_DOCKER_LOG"
provider_failure_status=0
env \
  MOCK_PROVIDER_MANAGEMENT_LOG="$PROVIDER_MANAGEMENT_LOG" \
  MOCK_PROVIDER_FAIL=1 \
  AI_API_BASE_URL=https://provider-rejected.invalid \
  AI_API_KEY=synthetic-rejected-provider-key \
  AI_MODEL=rejected-model \
  AI_API_MODE=responses \
  AI_SUPPORTS_VISION=false \
  CRISP_WEBSITE_ID=44444444-4444-4444-8444-444444444444 \
  CRISP_TOKEN_TIER=website \
  CRISP_TOKEN_IDENTIFIER=synthetic-rejected-crisp-identifier \
  CRISP_TOKEN_KEY=synthetic-rejected-crisp-key \
  ANYTHINGLLM_API_KEY=synthetic-rejected-anything-key \
  N8N_HOST=rejected.example.invalid \
  PUBLIC_WEBHOOK_URL=https://rejected.example.invalid/ \
  WEBHOOK_ACCESS_MODE=external_proxy \
  TIMEZONE=UTC \
  "$PROJECT_ROOT/install.sh" --deploy-dir "$DEPLOY" --command-path "$COMMAND" \
    --non-interactive --reconfigure > "${WORK}/reconfigure-provider-failure.log" 2>&1 \
    || provider_failure_status=$?

(( provider_failure_status != 0 )) || fail 'Provider 候选失败被错误接受'
[[ -s "$PROVIDER_MANAGEMENT_LOG" ]] \
  || fail 'Provider 候选失败负例未到达真实适配器探针'
grep -Fq '新主接口未通过真实适配器验证或运行回读' \
  "${WORK}/reconfigure-provider-failure.log" \
  || fail 'Provider 候选失败原因不明确'
for forbidden in \
  synthetic-rejected-provider-key synthetic-rejected-crisp-identifier \
  synthetic-rejected-crisp-key synthetic-rejected-anything-key; do
  ! grep -Fq -- "$forbidden" "${WORK}/reconfigure-provider-failure.log" \
    || fail 'Provider 失败恢复日志泄漏了候选凭据'
done
[[ "$(digest "${DEPLOY}/.env")" == "$install_env_before" ]] \
  || fail 'Provider 失败后未恢复安装前 .env'
[[ "$(digest "${DEPLOY}/config/Caddyfile")" == "$caddyfile_before" ]] \
  || fail 'Provider 失败后未恢复旧受管 Caddyfile'
[[ "$(digest "${DEPLOY}/config/crispai-nginx.conf")" == "$nginx_snippet_before" ]] \
  || fail 'Provider 失败后未恢复旧 Nginx 反代片段'
[[ "$(digest "${DEPLOY}/config/crispai-caddy.conf")" == "$caddy_snippet_before" ]] \
  || fail 'Provider 失败后未恢复旧 Caddy 反代片段'
[[ "$(digest "$POOL_APPLIED")" == "$pool_applied_before_provider_failure" ]] \
  || fail 'Provider 候选失败改变了原接口池投影'
[[ "$(<"$MOCK_CADDY_STATE")" == running ]] \
  || fail 'Provider 失败后未恢复原受管 Caddy 运行状态'
grep -Eq ' stop caddy$' "$MOCK_DOCKER_LOG" \
  || fail 'Webhook 候选未真正执行受管 Caddy 停止路径'
grep -Eq ' rm -f caddy$' "$MOCK_DOCKER_LOG" \
  || fail 'Webhook 候选未真正执行受管 Caddy 移除路径'
grep -Eq ' up -d --no-deps --force-recreate caddy$' "$MOCK_DOCKER_LOG" \
  || fail 'Provider 失败回滚未重建原受管 Caddy 运行代'
[[ -z "$(find "${DEPLOY}/tmp" -mindepth 1 -maxdepth 1 \
  -type d -name 'install-configuration.*' -print -quit)" ]] \
  || fail 'Provider 失败成功回滚后遗留了含凭据的安装事务目录'
printf '通过：Provider 候选在 Webhook 提交后失败时，安装器恢复原环境、反代片段与 Caddy 运行代。\n'

# 失败后 marker 保留 installing，但权威业务配置已回到原代。
# 下一次同版无凭据运行应直接复用并形成 staged，不再探测失败候选。
: > "$PROVIDER_MANAGEMENT_LOG"
provider_failure_continue_status=0
MOCK_PROVIDER_MANAGEMENT_LOG="$PROVIDER_MANAGEMENT_LOG" \
  "$PROJECT_ROOT/install.sh" --deploy-dir "$DEPLOY" --command-path "$COMMAND" \
    --non-interactive --skip-start > "${WORK}/provider-failure-continue.log" 2>&1 \
    || provider_failure_continue_status=$?
(( provider_failure_continue_status == 0 )) \
  || fail "Provider 失败回滚后同版继续应成功暂存，实际退出 ${provider_failure_continue_status}"
grep -Fxq 'state=staged' "${DEPLOY}/.crisp-ai-installation" \
  || fail 'Provider 失败回滚后继续未形成 staged 状态'
[[ ! -s "$PROVIDER_MANAGEMENT_LOG" ]] \
  || fail 'Provider 失败回滚后同版继续又探测了失败候选'
[[ "$(digest "${DEPLOY}/.env")" == "$install_env_before" ]] \
  || fail 'Provider 失败回滚后继续改变了原 .env'
[[ "$(<"$MOCK_CADDY_STATE")" == running ]] \
  || fail 'Provider 失败回滚后继续扰动了受管 Caddy'
printf '通过：Provider 失败回滚后，同版无凭据继续保留原配置与运行状态。\n'

# 交互向导从 collecting 选择“重新开始”后，安装器不会设置
# --reconfigure，但仍会重新应用 Provider/Crisp。该路径也必须进入
# 同一事务，而不是只保护显式 --reconfigure。
bash -c '
  set -euo pipefail
  source "$1/scripts/common.sh"
  write_installation_marker "$2" "$1" "$3" collecting
' -- "$PROJECT_ROOT" "$DEPLOY" "$(<"${PROJECT_ROOT}/VERSION")"
restart_env_before=$(digest "${DEPLOY}/.env")
restart_caddy_before=$(digest "${DEPLOY}/config/Caddyfile")
: > "$PROVIDER_MANAGEMENT_LOG"
restart_failure_status=0
env \
  MOCK_PROVIDER_MANAGEMENT_LOG="$PROVIDER_MANAGEMENT_LOG" \
  MOCK_PROVIDER_FAIL=1 \
  AI_API_BASE_URL=https://restart-rejected.invalid \
  AI_API_KEY=synthetic-restart-rejected-key \
  AI_MODEL=restart-rejected-model \
  AI_API_MODE=chat_completions \
  AI_SUPPORTS_VISION=false \
  CRISP_WEBSITE_ID=55555555-5555-4555-8555-555555555555 \
  CRISP_TOKEN_TIER=website \
  CRISP_TOKEN_IDENTIFIER=synthetic-restart-identifier \
  CRISP_TOKEN_KEY=synthetic-restart-key \
  ANYTHINGLLM_API_KEY=synthetic-restart-anything-key \
  N8N_HOST=restart-rejected.example.invalid \
  PUBLIC_WEBHOOK_URL=https://restart-rejected.example.invalid/ \
  WEBHOOK_ACCESS_MODE=external_proxy \
  TIMEZONE=UTC \
  "$PROJECT_ROOT/install.sh" --deploy-dir "$DEPLOY" --command-path "$COMMAND" \
    --non-interactive > "${WORK}/restart-provider-failure.log" 2>&1 \
    || restart_failure_status=$?
(( restart_failure_status != 0 )) || fail '重新开始向导的 Provider 失败被错误接受'
[[ -s "$PROVIDER_MANAGEMENT_LOG" ]] \
  || fail '重新开始向导负例未到达 Provider 探针'
[[ "$(digest "${DEPLOY}/.env")" == "$restart_env_before" \
  && "$(digest "${DEPLOY}/config/Caddyfile")" == "$restart_caddy_before" ]] \
  || fail '重新开始向导的 Provider 失败未恢复原接入配置'
[[ "$(<"$MOCK_CADDY_STATE")" == running ]] \
  || fail '重新开始向导的 Provider 失败未恢复 Caddy 运行状态'
[[ -z "$(find "${DEPLOY}/tmp" -mindepth 1 -maxdepth 1 \
  -type d -name 'install-configuration.*' -print -quit)" ]] \
  || fail '重新开始向导失败回滚后遗留安装事务目录'
printf '通过：从 collecting 重新开始时，Provider 失败同样回滚 Webhook/Caddy 整体候选。\n'

assert_reconfigure_skip_rejected() {
  local label=$1 log=$2 env_hash marker_hash pool_hash
  env_hash=$(digest "${DEPLOY}/.env")
  marker_hash=$(digest "${DEPLOY}/.crisp-ai-installation")
  pool_hash=$(digest "${DEPLOY}/config/provider-pool-applied.json")
  : > "$MOCK_DOCKER_LOG"
  if "$PROJECT_ROOT/install.sh" --deploy-dir "$DEPLOY" --command-path "$COMMAND" \
    --non-interactive --skip-start --reconfigure > "$log" 2>&1; then
    fail "${label} 实例错误接受了 --skip-start --reconfigure"
  fi
  grep -Fq -- '已有实例不能同时使用 --reconfigure 与 --skip-start' "$log" \
    || fail "${label} 实例的 --skip-start --reconfigure 拒绝原因不明确"
  [[ ! -s "$MOCK_DOCKER_LOG" ]] \
    || fail "${label} 实例拒绝 --skip-start --reconfigure 前调用了 Docker/Caddy"
  [[ "$(digest "${DEPLOY}/.env")" == "$env_hash" ]] \
    || fail "${label} 实例拒绝 --skip-start --reconfigure 时改写了环境配置"
  [[ "$(digest "${DEPLOY}/.crisp-ai-installation")" == "$marker_hash" ]] \
    || fail "${label} 实例拒绝 --skip-start --reconfigure 时改写了安装状态"
  [[ "$(digest "${DEPLOY}/config/provider-pool-applied.json")" == "$pool_hash" ]] \
    || fail "${label} 实例拒绝 --skip-start --reconfigure 时改变了接口池代次"
}

assert_reconfigure_skip_rejected '外部反代' "${WORK}/external-skip.log"

# 再将隔离实例标为已有受管 HTTPS，确认相同保护覆盖运行中的 Caddy。
# 拒绝必须发生在向导、配置写入和任何 Docker/Caddy 探测之前。
bash -c '
  set -euo pipefail
  source "$1/scripts/common.sh"
  env_set "$2/.env" WEBHOOK_ACCESS_MODE managed_https
  env_set "$2/.env" WEBHOOK_DOMAIN resume.example.invalid
  env_set "$2/.env" COMPOSE_PROFILES managed-https
' -- "$PROJECT_ROOT" "$DEPLOY"
assert_reconfigure_skip_rejected '受管 HTTPS' "${WORK}/managed-skip.log"
printf '通过：已有实例的仅暂存重新配置在任何配置或运行态变更前拒绝，受管 Caddy 不受扰动。\n'
