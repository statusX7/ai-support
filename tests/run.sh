#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
MOCK_DIR="${SCRIPT_DIR}/mocks"
ORIGINAL_PATH=$PATH
PASSED=0
SKIPPED=0
RELEASE_MODE=${AI_SUPPORT_RELEASE_TEST:-0}
EXTERNAL_PENDING_MODE=${AI_SUPPORT_EXTERNAL_VALIDATION_PENDING:-0}
TEST_LAYER=STATIC
TEST_SELECTION=all
if (( $# )); then
  [[ $# -eq 1 && $1 == --lifecycle-only && $RELEASE_MODE == 0 ]] || {
    printf '用法：tests/run.sh [--lifecycle-only（仅非发布调试）]\n' >&2; exit 1;
  }
  TEST_SELECTION=lifecycle
  printf '测试选择：仅执行隔离生命周期 UNIT/CONTRACT；不代表全量或发布验收。\n'
fi
declare -A LAYER_PASSED=([STATIC]=0 [UNIT/CONTRACT]=0 [REAL-LOCAL]=0 [EXTERNAL-E2E]=0)
declare -A LAYER_SKIPPED=([STATIC]=0 [UNIT/CONTRACT]=0 [REAL-LOCAL]=0 [EXTERNAL-E2E]=0)

case "$RELEASE_MODE" in
  0|1) ;;
  *) printf '失败：[STATIC] AI_SUPPORT_RELEASE_TEST 只能是 0 或 1\n' >&2; exit 1 ;;
esac
case "$EXTERNAL_PENDING_MODE" in
  0|1) ;;
  *) printf '失败：[STATIC] AI_SUPPORT_EXTERNAL_VALIDATION_PENDING 只能是 0 或 1\n' >&2; exit 1 ;;
esac
if (( EXTERNAL_PENDING_MODE && RELEASE_MODE == 0 )); then
  printf '失败：[STATIC] External Validation Pending 只能与 AI_SUPPORT_RELEASE_TEST=1 同时使用\n' >&2
  exit 1
fi

TEST_ROOT=$(mktemp -d "${PROJECT_ROOT}/.test-runtime.XXXXXX")

cleanup() {
  if [[ "${AI_SUPPORT_TEST_KEEP_TMP:-0}" == 1 ]]; then
    printf '调试目录已保留：%s\n' "$TEST_ROOT" >&2
    return
  fi
  if [[ "$TEST_ROOT" == "${PROJECT_ROOT}"/.test-runtime.* && -d "$TEST_ROOT" ]]; then
    rm -rf -- "$TEST_ROOT"
  fi
}
trap cleanup EXIT

pass() {
  ((PASSED += 1))
  ((LAYER_PASSED[$TEST_LAYER] += 1))
  printf '通过：[%s] %s\n' "$TEST_LAYER" "$1"
}

skip() {
  ((SKIPPED += 1))
  ((LAYER_SKIPPED[$TEST_LAYER] += 1))
  printf '跳过：[%s] %s\n' "$TEST_LAYER" "$1"
}

fail() {
  printf '失败：[%s] %s\n' "$TEST_LAYER" "$1" >&2
  exit 1
}

report_unhandled_error() {
  local status=$?
  local line=$1
  printf '失败：[%s] 未处理的测试命令在第 %s 行退出（状态 %s）\n' \
    "$TEST_LAYER" "$line" "$status" >&2
  return "$status"
}
trap 'report_unhandled_error "$LINENO"' ERR

critical_skip() {
  if (( RELEASE_MODE )); then
    if (( EXTERNAL_PENDING_MODE )) && [[ "$TEST_LAYER" == EXTERNAL-E2E ]]; then
      skip "External Validation Pending：$1"
      return
    fi
    fail "发布模式禁止跳过：$1"
  fi
  skip "$1"
}

assert_file() {
  [[ -f "$1" && ! -L "$1" ]] || fail "缺少安全的普通文件：$1"
}

expect_local_ready_install() {
  local status=0
  "$@" || status=$?
  (( status == 2 )) || fail "隔离测试无真实会话，安装应返回 local-ready 状态 2，实际 ${status}"
}

if [[ "$TEST_SELECTION" == all ]]; then
SHELL_FILES=(
  install.sh manage.sh update.sh uninstall.sh
  scripts/common.sh scripts/healthcheck.sh scripts/backup.sh scripts/restore.sh
  scripts/analytics.sh scripts/snapshot.sh scripts/rollback.sh scripts/bootstrap.sh
  scripts/wizard.sh scripts/package-release.sh
  scripts/configuration.sh scripts/knowledge.sh scripts/provider.sh scripts/migration.sh
  scripts/launcher.sh scripts/menu-ui.sh scripts/crisp-settings.sh scripts/full-backup.sh
  tests/run.sh tests/test_manage_contract.sh tests/test_workflow_contract.sh tests/test_workflow_runtime.sh
  tests/test_static_security.sh tests/test_archive_security.sh tests/test_deployment_integration.sh
  tests/test_external_e2e.sh tests/test_bootstrap.sh tests/test_wizard.sh tests/test_release_package.sh
  tests/test_knowledge_timeout.sh tests/test_health_wait.sh tests/mocks/chown tests/mocks/curl tests/mocks/docker tests/mocks/stat
  tests/mocks/curl_knowledge_timeout
)
for file in "${SHELL_FILES[@]}"; do
  assert_file "${PROJECT_ROOT}/${file}"
  bash -n "${PROJECT_ROOT}/${file}"
done
pass "全部 Bash 脚本语法"

"${SCRIPT_DIR}/test_static_security.sh"
pass "Git 忽略规则与密钥扫描"

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -x "${SHELL_FILES[@]/#/${PROJECT_ROOT}/}"
  pass "shellcheck"
else
  critical_skip "系统未安装 shellcheck"
fi

TEST_LAYER=UNIT/CONTRACT
"${SCRIPT_DIR}/test_bootstrap.sh"
pass "依赖与 Docker 自动引导专项"

"${SCRIPT_DIR}/test_knowledge_timeout.sh"
pass "AnythingLLM 首次索引超时对账与恢复专项"

"${SCRIPT_DIR}/test_health_wait.sh"
pass "安装、更新、恢复与回滚健康等待专项"

if command -v python3 >/dev/null 2>&1 && command -v shellcheck >/dev/null 2>&1; then
  "${SCRIPT_DIR}/test_wizard.sh"
  pass "十项快速初始化向导专项"
else
  critical_skip "缺少 Python 3 或 shellcheck，未执行 PTY 快速初始化向导专项"
fi

TEST_LAYER=STATIC
if ! command -v git >/dev/null 2>&1; then
  critical_skip "缺少 Git，未执行正式源码发布包专项"
elif [[ -n "$(git -C "$PROJECT_ROOT" status --porcelain --untracked-files=all)" ]]; then
  if (( RELEASE_MODE )); then
    fail "发布模式要求先形成干净提交，再执行正式源码发布包专项"
  fi
  skip "当前为集成中的脏工作树；形成首个干净提交后执行正式源码发布包专项"
elif command -v shellcheck >/dev/null 2>&1; then
  "${SCRIPT_DIR}/test_release_package.sh"
  pass "正式源码发布包、入口与密钥边界专项"
else
  critical_skip "缺少 shellcheck，未执行正式源码发布包专项"
fi

jq empty \
  "${PROJECT_ROOT}/n8n/workflow.json" \
  "${PROJECT_ROOT}/config/keyword.yaml.example" \
  "${PROJECT_ROOT}/config/menu.yaml.example" \
  "${PROJECT_ROOT}/config/handoff.yaml.example" \
  "${PROJECT_ROOT}/config/tags.yaml.example" \
  "${PROJECT_ROOT}/config/feedback.yaml.example"
PROJECT_VERSION=$(<"${PROJECT_ROOT}/VERSION")
[[ "$PROJECT_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "VERSION 格式无效"
grep -Fq "version: ${PROJECT_VERSION}" "${PROJECT_ROOT}/config/app.yaml" || fail "app.yaml 版本未同步"
grep -Fq "ai_support_version: '${PROJECT_VERSION}'" "${PROJECT_ROOT}/n8n/workflow.json" \
  || fail "n8n workflow 回复版本未同步"
pass "版本与 JSON/YAML 格式"

grep -Fq 'no-new-privileges:true' "${PROJECT_ROOT}/docker-compose.yml" || fail "Compose 缺少权限收紧"
grep -Fq '127.0.0.1' "${PROJECT_ROOT}/docker-compose.yml" || fail "Compose 未默认绑定本机"
grep -Fq 'N8N_BLOCK_ENV_ACCESS_IN_NODE: "false"' "${PROJECT_ROOT}/docker-compose.yml" || fail "n8n 无法读取受控环境变量"
grep -Fq 'NODE_FUNCTION_ALLOW_BUILTIN: crypto,fs' "${PROJECT_ROOT}/docker-compose.yml" || fail "n8n 内置模块白名单无效"
grep -Fq "source: \${DEPLOY_DIR:-/opt/crisp-ai}/data/postgres" "${PROJECT_ROOT}/docker-compose.yml" || fail "PostgreSQL 数据未集中保存"
grep -Fq "source: \${DEPLOY_DIR:-/opt/crisp-ai}/data/analytics" "${PROJECT_ROOT}/docker-compose.yml" || fail "匿名统计数据未集中保存"
grep -Fq 'mintplexlabs/anythingllm:1.16.1' "${PROJECT_ROOT}/docker-compose.yml" \
  || fail "AnythingLLM 默认镜像未固定为 1.16.1"
grep -Fxq 'ANYTHINGLLM_IMAGE=mintplexlabs/anythingllm:1.16.1' "${PROJECT_ROOT}/.env.example" \
  || fail ".env.example 的 AnythingLLM 镜像未同步为 1.16.1"
pass "Docker Compose 静态安全契约"

TEST_LAYER=UNIT/CONTRACT
"${SCRIPT_DIR}/test_manage_contract.sh"
pass "管理菜单 1..18、子菜单与未安装边界"

TEST_LAYER=STATIC
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  docker compose \
    --project-directory "$PROJECT_ROOT" \
    --env-file "${PROJECT_ROOT}/.env.example" \
    -f "${PROJECT_ROOT}/docker-compose.yml" \
    config --quiet
  pass "docker compose config"
else
  critical_skip "系统未安装满足项目能力要求的 Docker Compose 插件，未执行实际 docker compose config"
fi

"${SCRIPT_DIR}/test_workflow_contract.sh"
pass "Webhook、图片、关键词、菜单、上下文与人工接管契约"

TEST_LAYER=UNIT/CONTRACT
if "${SCRIPT_DIR}/test_workflow_runtime.sh"; then
  pass "n8n Code node 行为"
else
  runtime_status=$?
  if (( runtime_status == 77 )); then
    critical_skip "系统未安装 Node.js，未执行 n8n Code node 行为"
  else
    fail "n8n Code node 行为测试失败"
  fi
fi

if command -v node >/dev/null 2>&1; then
  node "${SCRIPT_DIR}/test_configuration_guards.js"
  pass "配置秘密边界、维护锁和 Crisp 响应护栏（内部子项单列，不重复计入总数）"
  node "${SCRIPT_DIR}/test_provider_adapter.js"
  pass "Provider 桥接生产代码协议专项（内部子项单列，不重复计入总数）"
  node "${SCRIPT_DIR}/test_configuration_protocol.js"
  pass "配置与多知识库生产 CLI 协议专项（内部子项单列，不重复计入总数）"
else
  critical_skip "系统未安装开发测试依赖 Node.js，未执行配置护栏和 Provider/配置协议专项"
fi

TEST_LAYER=REAL-LOCAL
if "${SCRIPT_DIR}/test_deployment_integration.sh"; then
  pass "真实部署本地集成检查"
else
  integration_status=$?
  if (( integration_status == 77 )); then
    critical_skip "未执行真实部署本地集成检查"
  else
    fail "真实部署本地集成检查失败"
  fi
fi

TEST_LAYER=EXTERNAL-E2E
if "${SCRIPT_DIR}/test_external_e2e.sh"; then
  pass "Crisp、AnythingLLM 与 Provider 外部端到端验收"
else
  external_status=$?
  if (( external_status == 77 )); then
    critical_skip "未执行 Crisp、AnythingLLM 与 Provider 外部端到端验收"
  else
    fail "Crisp、AnythingLLM 与 Provider 外部端到端验收失败"
  fi
fi

fi
PROJECT_VERSION=$(<"${PROJECT_ROOT}/VERSION")
TEST_LAYER=UNIT/CONTRACT
export PATH="${MOCK_DIR}:${ORIGINAL_PATH}"
export MOCK_DOCKER_LOG="${TEST_ROOT}/docker.log"
export MOCK_ANYTHING_STATE="${TEST_ROOT}/anythingllm-state.json"
STUB_HOST_FIXTURE="${TEST_ROOT}/host-fixture"
mkdir -p -- "${STUB_HOST_FIXTURE}/etc/ssl/certs"
printf '%s\n' 'ID=debian' 'VERSION_ID="12"' 'VERSION_CODENAME=bookworm' \
  > "${STUB_HOST_FIXTURE}/os-release"
printf '%s\n' 'test CA bundle' > "${STUB_HOST_FIXTURE}/etc/ssl/certs/ca-certificates.crt"
export CRISP_AI_BOOTSTRAP_TEST_MODE=1
export CRISP_AI_BOOTSTRAP_OS_RELEASE="${STUB_HOST_FIXTURE}/os-release"
export CRISP_AI_BOOTSTRAP_ETC_ROOT="${STUB_HOST_FIXTURE}/etc"
export CRISP_AI_BOOTSTRAP_INIT=unsupported
: > "$MOCK_DOCKER_LOG"
printf '{"documents":[]}\n' > "$MOCK_ANYTHING_STATE"

DEPLOY_DIR="${TEST_ROOT}/deploy"
mkdir -p -- "${TEST_ROOT}/bin"
FAILURE_DEPLOY_DIR="${TEST_ROOT}/provider-failure"
SOFT_FAILURE_DEPLOY_DIR="${TEST_ROOT}/provider-soft-failure"
RESPONSES_DEPLOY_DIR="${TEST_ROOT}/responses-only"
DOCKER_FAILURE_DEPLOY_DIR="${TEST_ROOT}/docker-failure"
CHAT_MODE_FAILURE_DEPLOY_DIR="${TEST_ROOT}/chat-mode-failure"
PARTIAL_DEPLOY_DIR="${TEST_ROOT}/partial-install"
PLUGIN_DEPLOY_DIR="${TEST_ROOT}/plugin-install"
CRISP_EXTERNAL_FAILURE_DEPLOY_DIR="${TEST_ROOT}/crisp-external-failure"
INSTALL_LOG="${TEST_ROOT}/install.log"
TEST_PROVIDER_KEY='test-only-provider-key'
TEST_CRISP_KEY='test-only-crisp-key'
TEST_ANYTHING_KEY='test-only-anything-key'
TEST_CRISP_AUTH=$(printf '%s' "test-only-identifier:${TEST_CRISP_KEY}" | base64 | tr -d '\n')
export MOCK_FORBIDDEN_ARG_FILE="${TEST_ROOT}/forbidden-curl-args.txt"
printf '%s\n' "$TEST_PROVIDER_KEY" "$TEST_CRISP_KEY" "$TEST_ANYTHING_KEY" "$TEST_CRISP_AUTH" \
  'test-only-failing-provider-key' 'test-only-failing-crisp-key' \
  'test-only-failing-anything-key' 'test-only-plugin-signing-secret' \
  'test-only-plugin-provider-key' 'test-only-plugin-crisp-key' \
  'test-only-plugin-anything-key' \
  'test-only-soft-provider-key' 'test-only-soft-crisp-key' \
  'test-only-soft-anything-key' \
  'test-only-crisp-layer-provider-key' 'test-only-crisp-layer-token-key' \
  'test-only-crisp-layer-anything-key' \
  > "$MOCK_FORBIDDEN_ARG_FILE"

expect_local_ready_install env \
  AI_API_BASE_URL=https://provider.invalid \
  AI_API_KEY="$TEST_PROVIDER_KEY" \
  AI_MODEL=gpt-vision-test \
  AI_SUPPORTS_VISION=true \
  CRISP_WEBSITE_ID=11111111-1111-1111-1111-111111111111 \
  CRISP_TOKEN_TIER=website \
  CRISP_TOKEN_IDENTIFIER=test-only-identifier \
  CRISP_TOKEN_KEY="$TEST_CRISP_KEY" \
  ANYTHINGLLM_API_KEY="$TEST_ANYTHING_KEY" \
  N8N_HOST=support.example.invalid \
  PUBLIC_WEBHOOK_URL=https://support.example.invalid/ \
  TIMEZONE=UTC \
  "${PROJECT_ROOT}/install.sh" \
    --deploy-dir "$DEPLOY_DIR" --command-path "${TEST_ROOT}/bin/crispai" --non-interactive > "$INSTALL_LOG" 2>&1

assert_file "${DEPLOY_DIR}/.crisp-ai-installation"
assert_file "${TEST_ROOT}/bin/crispai"
[[ "$(cd / && "${TEST_ROOT}/bin/crispai" --version)" == "$PROJECT_VERSION" ]] || fail "陌生工作目录无法使用受管命令版本入口"
assert_file "${DEPLOY_DIR}/config/provider.yaml"
[[ "$(<"${DEPLOY_DIR}/VERSION")" == "$PROJECT_VERSION" ]] || fail "安装版本错误"
assert_file "${DEPLOY_DIR}/config/tags.yaml"
assert_file "${DEPLOY_DIR}/config/feedback.yaml"
assert_file "${DEPLOY_DIR}/data/analytics/events.jsonl"
[[ "$(stat -c '%a' "${DEPLOY_DIR}/.env")" == 600 ]] || fail ".env 权限不是 0600"
grep -Fxq 'CRISP_HOOK_MODE=website' "${DEPLOY_DIR}/.env" || fail "Website Hook 模式未保存"
grep -Fxq 'ANYTHINGLLM_CHAT_MODE=chat' "${DEPLOY_DIR}/.env" \
  || fail "AnythingLLM 未固定为保持会话的 chat 模式"
WEBSITE_HOOK_SECRET_VALUE=$(sed -n 's/^CRISP_WEBSITE_HOOK_SECRET=//p' "${DEPLOY_DIR}/.env" | head -n 1)
[[ -n "$WEBSITE_HOOK_SECRET_VALUE" && "$WEBSITE_HOOK_SECRET_VALUE" != replace-with-* ]] \
  || fail "Website Hook URL Secret 未生成"
jq -e '.provider.model == "gpt-vision-test" and .provider.capabilities.responses == true and .provider.capabilities.chat_completions == true and .provider.capabilities.vision == true' "${DEPLOY_DIR}/config/provider.yaml" >/dev/null || fail "Provider 模型与实测能力未准确保存"
[[ "$(sed -n 's/^SNAPSHOT_MIN_FREE_MB=//p' "${DEPLOY_DIR}/.env")" == 1024 ]] || fail "快照预留空间默认值错误"
[[ "$(sed -n 's/^SNAPSHOT_RETENTION_COUNT=//p' "${DEPLOY_DIR}/.env")" == 10 ]] || fail "快照保留数量默认值错误"
for secret_value in "$TEST_PROVIDER_KEY" "$TEST_CRISP_KEY" "$TEST_ANYTHING_KEY"; do
  if grep -Fq "$secret_value" "$INSTALL_LOG"; then
    fail "安装日志泄露 API Key 或 Token"
  fi
done
grep -Fq 'publish:workflow' "$MOCK_DOCKER_LOG" || fail "安装未发布 n8n workflow"
grep -Fq 'info' "$MOCK_DOCKER_LOG" || fail "安装未检查 Docker daemon"
grep -Fxq 'state=local-ready' "${DEPLOY_DIR}/.crisp-ai-installation" \
  || fail "没有真实会话证据时安装不能宣称已开始接待客户"
grep -Fq '本地服务、AnythingLLM 工作区、知识索引和生产 workflow 已完成初始化' \
  "$INSTALL_LOG" || fail "安装未完成新版分层初始化"
grep -Fxq 'fact_crisp_api=ready' "${DEPLOY_DIR}/.crisp-ai-installation" \
  || fail "Crisp API 测试成功未独立记录事实"
grep -Fxq 'fact_conversation=pending' "${DEPLOY_DIR}/.crisp-ai-installation" \
  || fail "安装未明确区分 Crisp 凭据验证与真实会话验收"
pass "安装与 Provider 自动检测"

: > "$MOCK_DOCKER_LOG"
if env \
  MOCK_CRISP_FAIL=1 \
  AI_API_BASE_URL=https://provider.invalid \
  AI_API_KEY=test-only-crisp-layer-provider-key \
  AI_MODEL=gpt-vision-test \
  AI_SUPPORTS_VISION=false \
  CRISP_WEBSITE_ID=66666666-6666-6666-6666-666666666666 \
  CRISP_TOKEN_TIER=website \
  CRISP_TOKEN_IDENTIFIER=test-only-crisp-layer-identifier \
  CRISP_TOKEN_KEY=test-only-crisp-layer-token-key \
  ANYTHINGLLM_API_KEY=test-only-crisp-layer-anything-key \
  N8N_HOST=crisp-layer.example.invalid \
  PUBLIC_WEBHOOK_URL=https://crisp-layer.example.invalid/ \
  TIMEZONE=UTC \
  "${PROJECT_ROOT}/install.sh" \
    --deploy-dir "$CRISP_EXTERNAL_FAILURE_DEPLOY_DIR" --command-path "${TEST_ROOT}/bin/crispai-crisp-failure" --non-interactive \
    > "${TEST_ROOT}/crisp-layer-failure.log" 2>&1; then
  CRISP_LAYER_STATUS=0
else
  CRISP_LAYER_STATUS=$?
fi
(( CRISP_LAYER_STATUS == 2 )) \
  || fail "Crisp 外部 API 失败应以 local-ready 分层状态退出 2，实际为 ${CRISP_LAYER_STATUS}"
grep -Fxq 'state=local-ready' "${CRISP_EXTERNAL_FAILURE_DEPLOY_DIR}/.crisp-ai-installation" \
  || fail "Crisp 外部 API 失败未提交 local-ready"
for expected_fact in \
  fact_dependencies=ready \
  fact_local_services=ready \
  fact_app_config=ready \
  fact_provider=ready \
  fact_crisp_api=failed; do
  grep -Fxq "$expected_fact" "${CRISP_EXTERNAL_FAILURE_DEPLOY_DIR}/.crisp-ai-installation" \
    || fail "local-ready 安装事实缺少：$expected_fact"
done
grep -Fq '本地已就绪，尚未确认真实接待' \
  "${TEST_ROOT}/crisp-layer-failure.log" \
  || fail "Crisp 外部失败没有明确区分本地安装完成状态"
grep -Fq 'publish:workflow' "$MOCK_DOCKER_LOG" \
  || fail "Crisp 外部失败前本地生产 workflow 未完成发布"
for secret_value in \
  test-only-crisp-layer-provider-key \
  test-only-crisp-layer-token-key \
  test-only-crisp-layer-anything-key; do
  if grep -Fq "$secret_value" "${TEST_ROOT}/crisp-layer-failure.log"; then
    fail "Crisp 外部分层失败日志泄露 API Key 或 Token"
  fi
done
CRISP_LAYER_ENV_HASH=$(sha256sum "${CRISP_EXTERNAL_FAILURE_DEPLOY_DIR}/.env" | awk '{print $1}')
expect_local_ready_install "${PROJECT_ROOT}/install.sh" \
  --deploy-dir "$CRISP_EXTERNAL_FAILURE_DEPLOY_DIR" --non-interactive \
  > "${TEST_ROOT}/crisp-layer-retry.log" 2>&1
grep -Fxq 'state=local-ready' "${CRISP_EXTERNAL_FAILURE_DEPLOY_DIR}/.crisp-ai-installation" \
  || fail "仅 Crisp API 恢复不能伪造真实会话 ready"
grep -Fxq 'fact_crisp_api=ready' "${CRISP_EXTERNAL_FAILURE_DEPLOY_DIR}/.crisp-ai-installation" \
  || fail "Crisp API 恢复后对应 fact 未更新"
[[ "$(sha256sum "${CRISP_EXTERNAL_FAILURE_DEPLOY_DIR}/.env" | awk '{print $1}')" == "$CRISP_LAYER_ENV_HASH" ]] \
  || fail "local-ready 重试改写了既有密钥配置"
pass "Crisp 外部失败 local-ready 分层、脱敏与幂等恢复"

if env MOCK_DOCKER_DAEMON_FAIL=1 "${PROJECT_ROOT}/install.sh" \
  --deploy-dir "$DOCKER_FAILURE_DEPLOY_DIR" --non-interactive \
  > "${TEST_ROOT}/docker-daemon-failure.log" 2>&1; then
  fail "Docker daemon 不可连接时安装被错误报告为成功"
fi
grep -Eq 'Docker daemon|Docker 自动安装或真实运行验证失败' \
  "${TEST_ROOT}/docker-daemon-failure.log" \
  || fail "Docker daemon 失败没有清晰提示"
[[ ! -e "${DOCKER_FAILURE_DEPLOY_DIR}/.crisp-ai-installation" ]] \
  || fail "Docker 引导失败后错误提交了安装状态"
pass "Docker daemon 自动引导失败时不提交安装状态"

bash -c '
  set -euo pipefail
  source "$1/scripts/common.sh"
  validate_port 1
  validate_port 65535
  ! validate_port 0
  ! validate_port 65536
  ! validate_port "5678;id"
' -- "$PROJECT_ROOT"
if env ANYTHINGLLM_CHAT_MODE=query "${PROJECT_ROOT}/install.sh" \
  --deploy-dir "$CHAT_MODE_FAILURE_DEPLOY_DIR" --non-interactive --skip-start \
  > "${TEST_ROOT}/chat-mode-failure.log" 2>&1; then
  fail "AnythingLLM 非 chat 模式被安装流程错误接受"
fi
grep -Fq 'ANYTHINGLLM_CHAT_MODE 必须为 chat' "${TEST_ROOT}/chat-mode-failure.log" \
  || fail "AnythingLLM 非 chat 模式没有清晰拒绝原因"
grep -Fxq 'state=installing' "${CHAT_MODE_FAILURE_DEPLOY_DIR}/.crisp-ai-installation" \
  || fail "无效 AnythingLLM 模式后安装 marker 状态错误"
pass "端口边界与 AnythingLLM chat-only 输入校验"

if env \
  AI_API_BASE_URL=https://provider.invalid \
  AI_API_KEY=test-only-partial-provider-key \
  AI_MODEL=gpt-vision-test \
  AI_SUPPORTS_VISION=false \
  CRISP_WEBSITE_ID= \
  CRISP_TOKEN_TIER=website \
  CRISP_TOKEN_IDENTIFIER=test-only-partial-identifier \
  CRISP_TOKEN_KEY=test-only-partial-crisp-key \
  ANYTHINGLLM_API_KEY=test-only-partial-anything-key \
  N8N_HOST=partial.example.invalid \
  PUBLIC_WEBHOOK_URL=https://partial.example.invalid/ \
  TIMEZONE=UTC \
  "${PROJECT_ROOT}/install.sh" \
    --deploy-dir "$PARTIAL_DEPLOY_DIR" --non-interactive --skip-start \
    > "${TEST_ROOT}/partial-install-failure.log" 2>&1; then
  fail "缺少 Crisp Website ID 的安装被错误报告为成功"
fi
env \
  AI_API_BASE_URL=https://provider.invalid \
  AI_API_KEY=test-only-partial-provider-key \
  AI_MODEL=gpt-vision-test \
  AI_SUPPORTS_VISION=false \
  CRISP_WEBSITE_ID=33333333-3333-3333-3333-333333333333 \
  CRISP_TOKEN_TIER=website \
  CRISP_TOKEN_IDENTIFIER=test-only-partial-identifier \
  CRISP_TOKEN_KEY=test-only-partial-crisp-key \
  ANYTHINGLLM_API_KEY=test-only-partial-anything-key \
  N8N_HOST=partial.example.invalid \
  PUBLIC_WEBHOOK_URL=https://partial.example.invalid/ \
  TIMEZONE=UTC \
  "${PROJECT_ROOT}/install.sh" \
    --deploy-dir "$PARTIAL_DEPLOY_DIR" --non-interactive --skip-start \
    > "${TEST_ROOT}/partial-install-retry.log" 2>&1
grep -Fxq 'CRISP_WEBSITE_ID=33333333-3333-3333-3333-333333333333' "${PARTIAL_DEPLOY_DIR}/.env" \
  || fail "中途失败后的普通重试未完成 Crisp 配置"
grep -Fxq "installed_version=${PROJECT_VERSION}" "${PARTIAL_DEPLOY_DIR}/.crisp-ai-installation" \
  || fail "中途失败后的重试未写入最终安装版本"
if grep -Eq '^state=(installing|failed)$' "${PARTIAL_DEPLOY_DIR}/.crisp-ai-installation"; then
  fail "重试成功后安装标记仍处于未完成状态"
fi
pass "安装中途失败后的幂等重试"

if env MOCK_DOCKER_FAIL_IMPORT=1 bash -c \
  "set -euo pipefail; source \"\$1/scripts/common.sh\"; import_and_publish_workflow \"\$1\"" \
  -- "$DEPLOY_DIR" > "${TEST_ROOT}/workflow-import-failure.log" 2>&1; then
  fail "n8n workflow 导入失败被错误报告为成功"
fi
grep -Fq 'n8n workflow 导入失败' "${TEST_ROOT}/workflow-import-failure.log" \
  || fail "n8n workflow 导入失败没有清晰提示"
pass "n8n workflow 导入失败路径"

ENV_HASH_BEFORE=$(sha256sum "${DEPLOY_DIR}/.env" | awk '{print $1}')
"${PROJECT_ROOT}/install.sh" \
  --deploy-dir "$DEPLOY_DIR" --non-interactive --skip-start > "${TEST_ROOT}/repeat-install.log" 2>&1
ENV_HASH_AFTER=$(sha256sum "${DEPLOY_DIR}/.env" | awk '{print $1}')
[[ "$ENV_HASH_BEFORE" == "$ENV_HASH_AFTER" ]] || fail "重复安装改写了现有密钥配置"
pass "重复安装幂等性"

install -m 0600 -- "${DEPLOY_DIR}/.env" "${TEST_ROOT}/before-runtime-provider.env"
install -m 0600 -- "${DEPLOY_DIR}/config/provider.yaml" "${TEST_ROOT}/before-runtime-provider.yaml"
bash -c '
  set -euo pipefail
  source "$1/scripts/common.sh"
  env_set "$2/.env" AI_API_PROBE_BASE_URL http://127.0.0.1:18080/proxy/v1
  env_set "$2/.env" AI_API_BASE_URL http://host.docker.internal:18080/proxy/v1
' -- "$PROJECT_ROOT" "$DEPLOY_DIR"
jq '.provider.base_url="http://host.docker.internal:18080/proxy/v1"' "${DEPLOY_DIR}/config/provider.yaml" > "${TEST_ROOT}/runtime-provider.yaml"
install -m 0640 -- "${TEST_ROOT}/runtime-provider.yaml" "${DEPLOY_DIR}/config/provider.yaml"
RUNTIME_PROVIDER_ENV_HASH=$(sha256sum "${DEPLOY_DIR}/.env" | awk '{print $1}')
sed -i 's/^state=.*/state=installing/' "${DEPLOY_DIR}/.crisp-ai-installation"
rm -f -- "${DEPLOY_DIR}/tmp/quick-init.json"
"${PROJECT_ROOT}/install.sh" \
  --deploy-dir "$DEPLOY_DIR" --non-interactive --skip-start > "${TEST_ROOT}/incomplete-install-retry.log" 2>&1
grep -Fxq 'state=staged' "${DEPLOY_DIR}/.crisp-ai-installation" \
  || fail "完整配置的未完成安装在 --skip-start 下未进入 staged"
[[ "$(sha256sum "${DEPLOY_DIR}/.env" | awk '{print $1}')" == "$RUNTIME_PROVIDER_ENV_HASH" ]] \
  || fail "未完成安装恢复改写了现有密钥配置"
grep -Fq '已验证未完成部署的 .env 与实际配置' "${TEST_ROOT}/incomplete-install-retry.log" \
  || fail "未完成安装没有明确说明已验证并复用实际配置"
pass "未完成安装复用已验证配置及 localhost 容器映射"

install -m 0600 -- "${TEST_ROOT}/before-runtime-provider.env" "${DEPLOY_DIR}/.env"
install -m 0600 -- "${TEST_ROOT}/before-runtime-provider.yaml" "${DEPLOY_DIR}/config/provider.yaml"
sed -i 's/^state=.*/state=ready/' "${DEPLOY_DIR}/.crisp-ai-installation"

"${DEPLOY_DIR}/scripts/healthcheck.sh" --deploy-dir "$DEPLOY_DIR" --offline \
  > "${TEST_ROOT}/health-offline.log" 2>&1
"${DEPLOY_DIR}/scripts/healthcheck.sh" --deploy-dir "$DEPLOY_DIR" \
  > "${TEST_ROOT}/health-online.log" 2>&1
pass "离线与在线健康检查成功路径"

if env MOCK_CRISP_FAIL=1 "${DEPLOY_DIR}/scripts/healthcheck.sh" --deploy-dir "$DEPLOY_DIR" \
  > "${TEST_ROOT}/crisp-failure.log" 2>&1; then
  fail "Crisp API 失败未导致健康检查失败"
fi
grep -Fq 'Crisp REST API 检查失败' "${TEST_ROOT}/crisp-failure.log" || fail "未报告 Crisp API 失败"
if grep -Fq "$TEST_CRISP_KEY" "${TEST_ROOT}/crisp-failure.log"; then
  fail "失败日志泄露 Crisp Token"
fi
pass "Crisp API 失败路径与日志脱敏"

if env \
  MOCK_PROVIDER_FAIL=1 \
  AI_API_BASE_URL=https://provider.invalid \
  AI_API_KEY=test-only-failing-provider-key \
  DEFAULT_AI_MODEL=fallback-test-model \
  AI_SUPPORTS_VISION=false \
  CRISP_WEBSITE_ID=22222222-2222-2222-2222-222222222222 \
  CRISP_TOKEN_TIER=website \
  CRISP_TOKEN_IDENTIFIER=test-only-identifier \
  CRISP_TOKEN_KEY=test-only-failing-crisp-key \
  ANYTHINGLLM_API_KEY=test-only-failing-anything-key \
  N8N_HOST=failure.example.invalid \
  PUBLIC_WEBHOOK_URL=https://failure.example.invalid/ \
  TIMEZONE=UTC \
  "${PROJECT_ROOT}/install.sh" \
    --deploy-dir "$FAILURE_DEPLOY_DIR" --non-interactive --skip-start \
    > "${TEST_ROOT}/provider-failure.log" 2>&1; then
  fail "Provider 实际请求失败时安装被错误报告为成功"
fi
assert_file "${FAILURE_DEPLOY_DIR}/.crisp-ai-installation"
grep -Fxq 'state=installing' "${FAILURE_DEPLOY_DIR}/.crisp-ai-installation" \
  || fail "Provider 失败后安装 marker 未保持 installing"
grep -Fq '所选模型未通过 Chat Completions 或 Responses 的有效正文验证' "${TEST_ROOT}/provider-failure.log" \
  || fail "Provider 失败没有清晰说明实际请求不可用"
for secret_value in \
  test-only-failing-provider-key \
  test-only-failing-crisp-key \
  test-only-failing-anything-key; do
  if grep -Fq "$secret_value" "${TEST_ROOT}/provider-failure.log"; then
    fail "Provider 失败日志泄露 API Key 或 Token"
  fi
done
pass "AI Provider 实际请求失败时中止安装"

if env \
  MOCK_PROVIDER_SOFT_ERROR=1 \
  AI_API_BASE_URL=https://provider.invalid \
  AI_API_KEY=test-only-soft-provider-key \
  AI_MODEL=gpt-vision-test \
  AI_SUPPORTS_VISION=false \
  CRISP_WEBSITE_ID=55555555-5555-5555-5555-555555555555 \
  CRISP_TOKEN_TIER=website \
  CRISP_TOKEN_IDENTIFIER=test-only-soft-identifier \
  CRISP_TOKEN_KEY=test-only-soft-crisp-key \
  ANYTHINGLLM_API_KEY=test-only-soft-anything-key \
  N8N_HOST=soft-failure.example.invalid \
  PUBLIC_WEBHOOK_URL=https://soft-failure.example.invalid/ \
  TIMEZONE=UTC \
  "${PROJECT_ROOT}/install.sh" \
    --deploy-dir "$SOFT_FAILURE_DEPLOY_DIR" --non-interactive --skip-start \
    > "${TEST_ROOT}/provider-soft-failure.log" 2>&1; then
  fail "Provider 返回 HTTP 200 error JSON 时安装被错误报告为成功"
fi
assert_file "${SOFT_FAILURE_DEPLOY_DIR}/.crisp-ai-installation"
grep -Fxq 'state=installing' "${SOFT_FAILURE_DEPLOY_DIR}/.crisp-ai-installation" \
  || fail "Provider HTTP 200 error JSON 后 marker 未保持 installing"
for secret_value in \
  test-only-soft-provider-key \
  test-only-soft-crisp-key \
  test-only-soft-anything-key; do
  if grep -Fq "$secret_value" "${TEST_ROOT}/provider-soft-failure.log"; then
    fail "Provider HTTP 200 error JSON 失败日志泄露 API Key 或 Token"
  fi
done
pass "AI Provider 拒绝 HTTP 200 error JSON"

expect_local_ready_install env MOCK_PROVIDER_RESPONSES_ONLY=1 AI_API_MODE=responses \
  AI_API_BASE_URL=https://provider.invalid AI_API_KEY="$TEST_PROVIDER_KEY" AI_MODEL=gpt-vision-test \
  CRISP_WEBSITE_ID=77777777-7777-7777-7777-777777777777 CRISP_TOKEN_TIER=website \
  CRISP_TOKEN_IDENTIFIER=test-only-identifier CRISP_TOKEN_KEY="$TEST_CRISP_KEY" \
  ANYTHINGLLM_API_KEY="$TEST_ANYTHING_KEY" N8N_HOST=responses.example.invalid \
  PUBLIC_WEBHOOK_URL=https://responses.example.invalid/ TIMEZONE=UTC \
  "${PROJECT_ROOT}/install.sh" --deploy-dir "$RESPONSES_DEPLOY_DIR" \
    --command-path "${TEST_ROOT}/bin/crispai-responses" --non-interactive \
    > "${TEST_ROOT}/responses-only.log" 2>&1
jq -e '.provider.api_mode == "responses" and .provider.capabilities.responses == true and .provider.capabilities.chat_completions == false' \
  "${RESPONSES_DEPLOY_DIR}/config/provider.yaml" >/dev/null || fail "Responses-only 未保存正确真实协议能力"
grep -Fxq 'AI_ANYTHINGLLM_BASE_URL=http://provider-adapter:8787/v1' "${RESPONSES_DEPLOY_DIR}/.env" \
  || fail "Responses-only 未接入内部兼容层"
grep -Fxq 'state=local-ready' "${RESPONSES_DEPLOY_DIR}/.crisp-ai-installation" \
  || fail "Responses-only 协议安装未完成应用初始化"
pass "Responses-only 经受管桥接完成安装链路（模拟 Provider 与 Docker）"

TEST_PLUGIN_SIGNING_SECRET='test-only-plugin-signing-secret'
expect_local_ready_install env \
  AI_API_BASE_URL=https://provider.invalid \
  AI_API_KEY=test-only-plugin-provider-key \
  AI_MODEL=gpt-vision-test \
  AI_SUPPORTS_VISION=false \
  CRISP_WEBSITE_ID=44444444-4444-4444-4444-444444444444 \
  CRISP_TOKEN_TIER=plugin \
  CRISP_HOOK_MODE=plugin \
  CRISP_PLUGIN_SIGNING_SECRET="$TEST_PLUGIN_SIGNING_SECRET" \
  CRISP_TOKEN_IDENTIFIER=test-only-plugin-identifier \
  CRISP_TOKEN_KEY=test-only-plugin-crisp-key \
  ANYTHINGLLM_API_KEY=test-only-plugin-anything-key \
  N8N_HOST=plugin.example.invalid \
  PUBLIC_WEBHOOK_URL=https://plugin.example.invalid/ \
  TIMEZONE=UTC \
  "${PROJECT_ROOT}/install.sh" \
    --deploy-dir "$PLUGIN_DEPLOY_DIR" --command-path "${TEST_ROOT}/bin/crispai-plugin" --non-interactive \
    > "${TEST_ROOT}/plugin-install.log" 2>&1
grep -Fxq 'state=local-ready' "${PLUGIN_DEPLOY_DIR}/.crisp-ai-installation" \
  || fail "Plugin Hook 安装未完成服务验收"
grep -Fxq 'CRISP_HOOK_MODE=plugin' "${PLUGIN_DEPLOY_DIR}/.env" || fail "Plugin Hook 模式未保存"
grep -Fxq "CRISP_PLUGIN_SIGNING_SECRET=${TEST_PLUGIN_SIGNING_SECRET}" "${PLUGIN_DEPLOY_DIR}/.env" \
  || fail "Plugin Hook Signing Secret 未独立保存"
if grep -Fq "$TEST_PLUGIN_SIGNING_SECRET" "${TEST_ROOT}/plugin-install.log"; then
  fail "安装日志泄露 Plugin Hook Signing Secret"
fi
pass "Website URL Secret 与 Plugin Signing Secret 分离"

install -m 0640 "${SCRIPT_DIR}/fixtures/knowledge.md" "${DEPLOY_DIR}/knowledge/test-knowledge.md"
install -m 0640 "${SCRIPT_DIR}/fixtures/knowledge.md" "${DEPLOY_DIR}/knowledge/test-knowledge.txt"
install -m 0640 "${SCRIPT_DIR}/fixtures/knowledge.md" "${DEPLOY_DIR}/knowledge/test-knowledge.pdf"
install -m 0640 "${SCRIPT_DIR}/fixtures/knowledge.md" "${DEPLOY_DIR}/knowledge/test-knowledge.docx"
bash -c "set -euo pipefail; source \"\$1/scripts/common.sh\"; knowledge_sync_legacy \"\$1\"; knowledge_sync_legacy \"\$1\" 1" \
  -- "$DEPLOY_DIR" > "${TEST_ROOT}/knowledge-sync.log" 2>&1
jq -e '.files["test-knowledge.md"].locations | length > 0' \
  "${DEPLOY_DIR}/data/knowledge-manifest.json" >/dev/null || fail "知识文件未写入同步清单"
jq -e '
  (.files | keys | sort) == ["test-knowledge.docx","test-knowledge.md","test-knowledge.pdf","test-knowledge.txt"] and
  ([.files[].locations | length] | all(. > 0))
' "${DEPLOY_DIR}/data/knowledge-manifest.json" >/dev/null || fail "四种知识文件格式未全部写入同步清单"
EXPECTED_SOURCE_LOCATIONS=$(jq -c '[.files[].locations[]] | unique' \
  "${DEPLOY_DIR}/data/knowledge-manifest.json")
rm -f -- "${DEPLOY_DIR}/knowledge/test-knowledge.md" "${DEPLOY_DIR}/knowledge/test-knowledge.txt" \
  "${DEPLOY_DIR}/knowledge/test-knowledge.pdf" "${DEPLOY_DIR}/knowledge/test-knowledge.docx"
if env MOCK_REMOVE_DOCUMENTS_FAIL=1 bash -c \
  "set -euo pipefail; source \"\$1/scripts/common.sh\"; knowledge_sync_legacy \"\$1\"" \
  -- "$DEPLOY_DIR" >> "${TEST_ROOT}/knowledge-sync.log" 2>&1; then
  fail "AnythingLLM 源文档删除失败时知识同步被错误报告为成功"
fi
jq -e '.files | length == 0' "${DEPLOY_DIR}/data/knowledge-manifest.json" >/dev/null || fail "删除知识文件后未清理索引清单"
jq -e --argjson expected "$EXPECTED_SOURCE_LOCATIONS" \
  '(.garbage_locations | sort) == ($expected | sort)' \
  "${DEPLOY_DIR}/data/knowledge-manifest.json" >/dev/null || fail "源文档删除失败后未登记孤立位置"
bash -c "set -euo pipefail; source \"\$1/scripts/common.sh\"; knowledge_sync_legacy \"\$1\"" \
  -- "$DEPLOY_DIR" >> "${TEST_ROOT}/knowledge-sync.log" 2>&1
jq -e '.garbage_locations == []' "${DEPLOY_DIR}/data/knowledge-manifest.json" >/dev/null \
  || fail "后续知识同步未重试清理孤立源文档"
jq -e --argjson expected "$EXPECTED_SOURCE_LOCATIONS" \
  '((.removed_documents // []) | sort) == ($expected | sort)' "$MOCK_ANYTHING_STATE" >/dev/null \
  || fail "AnythingLLM remove-documents 未清理已删除知识源文档"
install -m 0640 "${SCRIPT_DIR}/fixtures/knowledge.md" "${DEPLOY_DIR}/knowledge/test-knowledge.md"
# 上面独立回归仍在生产中使用的 v1.0.1 pending/garbage 算法；以下再从真实旧单库布局走新迁移。
jq -e '.libraries | length == 0' "${DEPLOY_DIR}/knowledge/catalog.json" >/dev/null \
  || fail "旧单库迁移夹具必须从空 catalog 开始，不能删除用户式已有库"
rm -f -- "${DEPLOY_DIR}/knowledge/catalog.json"
bash "${DEPLOY_DIR}/scripts/knowledge.sh" --deploy-dir "$DEPLOY_DIR" sync \
  >> "${TEST_ROOT}/knowledge-sync.log" 2>&1
jq -e '.libraries[0].id == "kb_default" and .libraries[0].documents[0].projection == "test-knowledge.md"' \
  "${DEPLOY_DIR}/knowledge/catalog.json" >/dev/null || fail "旧单库没有迁入命名知识库"
pass "知识旧算法四种扩展名、删除重试与命名库迁移（不验证真实解析）"

printf '%s\n' \
  '{"type":"question","at":"2026-09-04T00:00:00Z"}' \
  '{"type":"question","at":"2026-09-04T00:00:01Z"}' \
  '{"type":"ai_reply","at":"2026-09-04T00:00:02Z"}' \
  '{"type":"ai_reply","at":"2026-09-04T00:00:03Z"}' \
  '{"type":"knowledge_hit","at":"2026-09-04T00:00:04Z"}' \
  '{"type":"knowledge_miss","at":"2026-09-04T00:00:05Z"}' \
  '{"type":"handoff","at":"2026-09-04T00:00:06Z","reason":"user_request"}' \
  '{"type":"feedback","at":"2026-09-04T00:00:07Z","session":"anonymous-a","question":"已解决问题","answer":"回答","feedback":"positive"}' \
  '{"type":"feedback","at":"2026-09-04T00:00:08Z","session":"anonymous-b","question":"失败问题","answer":"回答","feedback":"negative"}' \
  > "${DEPLOY_DIR}/data/analytics/events.jsonl"
ANALYTICS_JSON=$("${DEPLOY_DIR}/scripts/analytics.sh" all --deploy-dir "$DEPLOY_DIR" --json)
jq -e '
  .total_questions == 2 and .ai_replies == 2 and
  .knowledge_hits == 1 and .knowledge_misses == 1 and
  .handoffs == 1 and .hit_rate == 50 and
  .positive_feedback == 1 and .negative_feedback == 1 and
  .positive_rate == 50 and .frequent_failures[0].question == "失败问题"
' <<< "$ANALYTICS_JSON" >/dev/null || fail "知识库或反馈统计错误"
pass "知识库命中、未命中、转人工与用户反馈统计"

ARCHIVE="${DEPLOY_DIR}/backups/test-backup.tar.gz"
ENV_HASH_BEFORE=$(sha256sum "${DEPLOY_DIR}/.env" | awk '{print $1}')
PROMPT_HASH=$(sha256sum "${DEPLOY_DIR}/config/prompt.md" | awk '{print $1}')
"${DEPLOY_DIR}/scripts/backup.sh" --deploy-dir "$DEPLOY_DIR" --output "$ARCHIVE" \
  > "${TEST_ROOT}/backup.log" 2>&1
ARCHIVE_LIST=$(tar -tzf "$ARCHIVE")
if grep -E '(^|/)\.env$' <<< "$ARCHIVE_LIST" >/dev/null; then
  fail "备份包含 .env"
fi
ARCHIVE_CONTENT="${TEST_ROOT}/archive-content.bin"
tar -xOzf "$ARCHIVE" > "$ARCHIVE_CONTENT"
for secret_key in \
  N8N_ENCRYPTION_KEY POSTGRES_PASSWORD ANYTHINGLLM_AUTH_TOKEN ANYTHINGLLM_JWT_SECRET \
  ANYTHINGLLM_SIG_KEY ANYTHINGLLM_SIG_SALT AI_API_KEY ANYTHINGLLM_API_KEY \
  CRISP_TOKEN_KEY CRISP_AUTH_B64 CRISP_WEBHOOK_SECRET CRISP_WEBSITE_HOOK_SECRET \
  CRISP_PLUGIN_SIGNING_SECRET; do
  secret_value=$(sed -n "s/^${secret_key}=//p" "${DEPLOY_DIR}/.env" | head -n 1)
  [[ -n "$secret_value" ]] || continue
  if grep -Fq "$secret_value" "$ARCHIVE_CONTENT"; then
    fail "备份包含 .env 中的敏感值"
  fi
done
tar -xOzf "$ARCHIVE" ./manifest.json | jq -e '.contains_secrets == false' >/dev/null || fail "备份清单未声明排除密钥"
grep -Fq './config/tags.yaml' <<< "$ARCHIVE_LIST" || fail "备份未包含标签配置"
grep -Fq './config/feedback.yaml' <<< "$ARCHIVE_LIST" || fail "备份未包含反馈配置"
printf '临时 Prompt，恢复后应被替换。\n' > "${DEPLOY_DIR}/config/prompt.md"
rm -f -- "${DEPLOY_DIR}/knowledge/test-knowledge.md"
if "${DEPLOY_DIR}/scripts/restore.sh" \
  --deploy-dir "$DEPLOY_DIR" --input "$ARCHIVE" --skip-restart --no-safety-backup \
  > "${TEST_ROOT}/restore-running-refused.log" 2>&1; then
  fail "服务仍运行时 --skip-restart 恢复被错误接受"
fi
grep -Fq '正在运行，不能使用 --skip-restart' "${TEST_ROOT}/restore-running-refused.log" \
  || fail "服务运行中的离线恢复没有清晰拒绝原因"
grep -Fq '临时 Prompt，恢复后应被替换。' "${DEPLOY_DIR}/config/prompt.md" \
  || fail "拒绝运行中恢复前已修改配置"
env MOCK_DOCKER_NO_RUNNING=1 "${DEPLOY_DIR}/scripts/restore.sh" \
  --deploy-dir "$DEPLOY_DIR" --input "$ARCHIVE" --skip-restart --no-safety-backup \
  > "${TEST_ROOT}/restore.log" 2>&1
[[ "$(sha256sum "${DEPLOY_DIR}/config/prompt.md" | awk '{print $1}')" == "$PROMPT_HASH" ]] || fail "Prompt 未恢复"
[[ -f "${DEPLOY_DIR}/knowledge/test-knowledge.md" ]] || fail "知识文件未恢复"
[[ "$(sha256sum "${DEPLOY_DIR}/.env" | awk '{print $1}')" == "$ENV_HASH_BEFORE" ]] || fail "恢复覆盖了 .env"
pass "无密钥备份、运行中拒绝与完整离线恢复"

"${SCRIPT_DIR}/test_archive_security.sh" "$DEPLOY_DIR" "$ARCHIVE"
pass "恢复拒绝未被校验和覆盖的归档文件"

cp -- "${DEPLOY_DIR}/config/provider.yaml" "${TEST_ROOT}/provider.safe.yaml"
printf '\n  api_key: test-only-should-be-rejected\n' >> "${DEPLOY_DIR}/config/provider.yaml"
if "${DEPLOY_DIR}/scripts/backup.sh" --deploy-dir "$DEPLOY_DIR" \
  --output "${DEPLOY_DIR}/backups/unsafe.tar.gz" > "${TEST_ROOT}/unsafe-backup.log" 2>&1; then
  fail "备份未拒绝 provider.yaml 中的密钥字段"
fi
cp -- "${TEST_ROOT}/provider.safe.yaml" "${DEPLOY_DIR}/config/provider.yaml"
pass "备份敏感字段拒绝"

printf 'rollback-state-before\n' > "${DEPLOY_DIR}/data/anythingllm/rollback-state.txt"
FREE_KIB=$(df -Pk -- "${DEPLOY_DIR}/backups/versions" | awk 'NR == 2 { print $4 }')
INSUFFICIENT_RESERVE_MB=$((FREE_KIB / 1024 + 2048))
bash -c 'set -euo pipefail; source "$1/scripts/common.sh"; env_set "$1/.env" SNAPSHOT_MIN_FREE_MB "$2"' \
  -- "$DEPLOY_DIR" "$INSUFFICIENT_RESERVE_MB"
SNAPSHOT_COUNT_BEFORE=$(find "${DEPLOY_DIR}/backups/versions" -mindepth 2 -maxdepth 2 -type f -name manifest.json | wc -l)
if "${DEPLOY_DIR}/scripts/snapshot.sh" --deploy-dir "$DEPLOY_DIR" --reason insufficient-space \
  > "${TEST_ROOT}/snapshot-capacity-failure.log" 2>&1; then
  fail "空间不足时仍创建了版本快照"
fi
grep -Fq '版本快照空间不足' "${TEST_ROOT}/snapshot-capacity-failure.log" || fail "空间不足没有清晰提示"
SNAPSHOT_COUNT_AFTER=$(find "${DEPLOY_DIR}/backups/versions" -mindepth 2 -maxdepth 2 -type f -name manifest.json | wc -l)
[[ "$SNAPSHOT_COUNT_BEFORE" == "$SNAPSHOT_COUNT_AFTER" ]] || fail "容量预检失败后留下了版本快照"
: > "$MOCK_DOCKER_LOG"
printf 'v0.6.9\n' > "${DEPLOY_DIR}/VERSION"
if "${DEPLOY_DIR}/update.sh" --deploy-dir "$DEPLOY_DIR" --source-dir "$PROJECT_ROOT" --no-pull \
  > "${TEST_ROOT}/update-capacity-failure.log" 2>&1; then
  fail "快照空间不足时更新被错误报告为成功"
fi
grep -Fq '版本快照空间不足' "${TEST_ROOT}/update-capacity-failure.log" || fail "更新未报告快照空间不足"
if grep -Eq '(^| )stop( |$)' "$MOCK_DOCKER_LOG"; then
  fail "容量预检失败后仍停止了服务"
fi
printf '%s\n' "$PROJECT_VERSION" > "${DEPLOY_DIR}/VERSION"
bash -c 'set -euo pipefail; source "$1/scripts/common.sh"; env_set "$1/.env" SNAPSHOT_MIN_FREE_MB 0' \
  -- "$DEPLOY_DIR"
"${DEPLOY_DIR}/scripts/snapshot.sh" --deploy-dir "$DEPLOY_DIR" --check-capacity \
  > "${TEST_ROOT}/snapshot-capacity-success.log" 2>&1
grep -Fq '快照容量预检通过' "${TEST_ROOT}/snapshot-capacity-success.log" || fail "容量预检成功未输出依据"
pass "版本快照容量预检"

SNAPSHOT_ID=$("${DEPLOY_DIR}/scripts/snapshot.sh" --deploy-dir "$DEPLOY_DIR" --reason test-manual --quiet)
SNAPSHOT_LIST=$(tar -tzf "${DEPLOY_DIR}/backups/versions/${SNAPSHOT_ID}/snapshot.tar.gz")
grep -Eq '(^|/)\.env$' <<< "$SNAPSHOT_LIST" || fail "本机版本快照缺少内部凭据，无法一致性恢复"
grep -Fq 'payload/data/anythingllm/rollback-state.txt' <<< "$SNAPSHOT_LIST" || fail "版本快照未包含 AnythingLLM 数据"
grep -Fq 'payload/data/postgres/n8n.dump' <<< "$SNAPSHOT_LIST" || fail "版本快照未包含 n8n PostgreSQL 逻辑备份"
jq -e '
  .capacity.min_free_mb == 0 and .capacity.estimated_source_kib > 0 and
  .retention_count == 10 and .contains_database_dump == true and .contains_env == true
' \
  "${DEPLOY_DIR}/backups/versions/${SNAPSHOT_ID}/manifest.json" >/dev/null || fail "快照清单未记录容量与保留策略"
printf 'rollback-state-after\n' > "${DEPLOY_DIR}/data/anythingllm/rollback-state.txt"
printf '临时回滚 Prompt\n' > "${DEPLOY_DIR}/config/prompt.md"
bash -c 'set -euo pipefail; source "$1/scripts/common.sh"; env_set "$1/.env" SNAPSHOT_RETENTION_COUNT 1' \
  -- "$DEPLOY_DIR"
"${DEPLOY_DIR}/scripts/rollback.sh" --deploy-dir "$DEPLOY_DIR" --snapshot "$SNAPSHOT_ID" \
  > "${TEST_ROOT}/rollback.log" 2>&1
grep -Fq 'rollback-state-before' "${DEPLOY_DIR}/data/anythingllm/rollback-state.txt" || fail "AnythingLLM 数据未回滚"
grep -Fq 'pg_restore' "$MOCK_DOCKER_LOG" || fail "回滚未恢复 n8n PostgreSQL 逻辑备份"
grep -Fq -- '--force-recreate anythingllm' "$MOCK_DOCKER_LOG" \
  || fail "回滚交换 AnythingLLM bind mount 后未重建容器"
[[ "$(sha256sum "${DEPLOY_DIR}/config/prompt.md" | awk '{print $1}')" == "$PROMPT_HASH" ]] || fail "配置未随版本快照回滚"
SNAPSHOT_HISTORY=$("${DEPLOY_DIR}/scripts/rollback.sh" --deploy-dir "$DEPLOY_DIR" --list)
grep -Fq "$SNAPSHOT_ID" <<< "$SNAPSHOT_HISTORY" || fail "版本历史未列出快照"
grep -Fq '受保护快照使历史数量暂时超过保留上限' "${TEST_ROOT}/rollback.log" || fail "回滚目标未受保留策略保护"
pass "版本快照、AnythingLLM 数据与受保护手动回滚"

printf '缺失镜像时不得覆盖此配置\n' > "${DEPLOY_DIR}/config/prompt.md"
MISSING_IMAGE_PROMPT_HASH=$(sha256sum "${DEPLOY_DIR}/config/prompt.md" | awk '{print $1}')
: > "$MOCK_DOCKER_LOG"
if env MOCK_DOCKER_MISSING_IMAGE=1 "${DEPLOY_DIR}/scripts/rollback.sh" \
  --deploy-dir "$DEPLOY_DIR" --snapshot "$SNAPSHOT_ID" --no-safety-snapshot \
  > "${TEST_ROOT}/rollback-missing-image.log" 2>&1; then
  fail "缺少历史镜像时回滚被错误报告为成功"
fi
[[ "$(sha256sum "${DEPLOY_DIR}/config/prompt.md" | awk '{print $1}')" == "$MISSING_IMAGE_PROMPT_HASH" ]] \
  || fail "缺少历史镜像的回滚在失败前修改了部署文件"
if grep -Eq '(^| )stop( |$)' "$MOCK_DOCKER_LOG"; then
  fail "缺少历史镜像的回滚在预检完成前停止了服务"
fi
grep -Eq '历史镜像|缺少.*镜像' "${TEST_ROOT}/rollback-missing-image.log" \
  || fail "缺少历史镜像时没有清晰错误"
pass "缺少历史镜像时回滚安全失败"

assert_rollback_mutation_failure() {
  local failure_stage=$1 failure_variable failed_command case_root case_deploy
  local target_id target_hash previous_hash previous_prompt_hash previous_env_hash
  local failure_status=0 safety_id safety_manifest failed_tail stage_payload
  local service manifest forbidden_password
  local target_password='test-only-rollback-$ # = "quoted" \\secret'
  local current_password='test-only-current-rollback-password'
  local -a safety_manifests=()
  case "$failure_stage" in
    pg_restore) failure_variable=MOCK_DOCKER_FAIL_PG_RESTORE; failed_command=pg_restore ;;
    pg_password) failure_variable=MOCK_DOCKER_FAIL_PG_PASSWORD; failed_command=psql ;;
    *) fail "未知回滚失败测试阶段" ;;
  esac
  case_root="${TEST_ROOT}/rollback-failure-${failure_stage}"
  case_deploy="${case_root}/deploy"
  mkdir -p -- "$case_deploy"
  cp -a -- "${DEPLOY_DIR}/." "$case_deploy/"
  cp -- "$MOCK_ANYTHING_STATE" "${case_root}/anythingllm-state.json"
  local MOCK_ANYTHING_STATE="${case_root}/anythingllm-state.json"
  local MOCK_DOCKER_LOG="${case_root}/docker.log"
  local MOCK_DOCKER_SERVICE_STATE="${case_root}/running-services"
  local MOCK_POSTGRES_PASSWORD_DIGEST_FILE="${case_root}/password-digest"
  export MOCK_ANYTHING_STATE MOCK_DOCKER_LOG MOCK_DOCKER_SERVICE_STATE MOCK_POSTGRES_PASSWORD_DIGEST_FILE
  printf 'postgres\nanythingllm\nn8n\nprovider-adapter\n' > "$MOCK_DOCKER_SERVICE_STATE"
  : > "$MOCK_DOCKER_LOG"
  # 每例绑定自己的部署目录与命令入口，不修改原生命周期实例或宿主状态。
  bash -c 'set -euo pipefail; source "$1/scripts/common.sh";
    env_set "$1/.env" DEPLOY_DIR "$1";
    env_set "$1/.env" POSTGRES_PASSWORD "$4";
    env_set "$1/.env" SNAPSHOT_MIN_FREE_MB 0;
    env_set "$1/.env" SNAPSHOT_RETENTION_COUNT 10;
    write_installation_marker "$1" "$2" "$3" local-ready' \
    -- "$case_deploy" "$PROJECT_ROOT" "$PROJECT_VERSION" "$target_password"
  "${case_deploy}/scripts/launcher.sh" install --deploy-dir "$case_deploy" \
    --command-path "${case_root}/crispai" --non-interactive > "${case_root}/launcher.log" 2>&1
  printf '目标快照的 AnythingLLM 数据：%s\n' "$failure_stage" > "${case_deploy}/data/anythingllm/rollback-failure.txt"
  printf '目标快照的 Prompt：%s\n' "$failure_stage" > "${case_deploy}/config/prompt.md"
  target_hash=$(sha256sum "${case_deploy}/data/anythingllm/rollback-failure.txt" | cut -d ' ' -f 1)
  target_id=$("${case_deploy}/scripts/snapshot.sh" --deploy-dir "$case_deploy" \
    --reason "target-${failure_stage}" --quiet)
  printf '回滚前仍须保留的 AnythingLLM 数据：%s\n' "$failure_stage" > "${case_deploy}/data/anythingllm/rollback-failure.txt"
  printf '回滚前仍须保留的 Prompt：%s\n' "$failure_stage" > "${case_deploy}/config/prompt.md"
  bash -c 'set -euo pipefail; source "$1/scripts/common.sh"; env_set "$1/.env" POSTGRES_PASSWORD "$2"' \
    -- "$case_deploy" "$current_password"
  previous_hash=$(sha256sum "${case_deploy}/data/anythingllm/rollback-failure.txt" | cut -d ' ' -f 1)
  previous_prompt_hash=$(sha256sum "${case_deploy}/config/prompt.md" | cut -d ' ' -f 1)
  previous_env_hash=$(sha256sum "${case_deploy}/.env" | cut -d ' ' -f 1)
  : > "$MOCK_DOCKER_LOG"
  env "${failure_variable}=1" "${case_deploy}/scripts/rollback.sh" --deploy-dir "$case_deploy" \
    --snapshot "$target_id" > "${case_root}/failure.log" 2>&1 || failure_status=$?
  (( failure_status != 0 )) || fail "${failure_stage} 失败被错误报告为回滚成功"
  grep -Fq "$failed_command" "$MOCK_DOCKER_LOG" || fail "未实际执行 ${failure_stage} 失败分支"
  failed_tail="${case_root}/failed-tail.log"
  awk -v command="$failed_command" 'index($0,command) { failed=1 } failed { print }' \
    "$MOCK_DOCKER_LOG" > "$failed_tail"
  if grep -Eq '(^| )(up|restart)( |$)' "$failed_tail"; then
    fail "${failure_stage} 失败之后仍重新启动应用，可能运行混合恢复状态"
  fi
  grep -Fxq postgres "$MOCK_DOCKER_SERVICE_STATE" || fail "${failure_stage} 错误停止了 PostgreSQL 恢复服务"
  for service in n8n anythingllm provider-adapter; do
    if grep -Fxq "$service" "$MOCK_DOCKER_SERVICE_STATE"; then
      fail "${failure_stage} 失败后 ${service} 未保持停止"
    fi
  done
  [[ "$(sha256sum "${case_deploy}/data/anythingllm/rollback-failure.txt" | cut -d ' ' -f 1)" == "$target_hash" ]] \
    || fail "${failure_stage} 失败后单边退回或删除了目标 AnythingLLM 数据"
  [[ "$(sha256sum "${case_deploy}/data/.anythingllm-previous-${target_id}/rollback-failure.txt" | cut -d ' ' -f 1)" == "$previous_hash" ]] \
    || fail "${failure_stage} 失败后未保留回滚前 AnythingLLM 数据"
  grep -Fxq 'fact_local_services=failed' "${case_deploy}/.crisp-ai-installation" \
    || fail "${failure_stage} 失败后本地服务事实未标为 failed"
  grep -Fxq 'fact_app_config=failed' "${case_deploy}/.crisp-ai-installation" \
    || fail "${failure_stage} 失败后应用配置事实未标为 failed"
  grep -Fxq 'state=installing' "${case_deploy}/.crisp-ai-installation" \
    || fail "${failure_stage} 失败后错误宣称安装已完成或无法恢复"
  mapfile -t safety_manifests < <(find "${case_deploy}/backups/versions" -mindepth 2 -maxdepth 2 \
    -type f -name manifest.json -print0 | while IFS= read -r -d '' manifest; do
      jq -e --arg reason "pre-rollback-${target_id}" '.reason == $reason and .contains_env == true and .contains_database_dump == true' \
        "$manifest" >/dev/null && printf '%s\n' "$manifest"
    done)
  (( ${#safety_manifests[@]} == 1 )) || fail "${failure_stage} 失败后缺少唯一完整安全快照"
  safety_manifest=${safety_manifests[0]}
  safety_id=$(jq -er '.id' "$safety_manifest")
  assert_file "${case_deploy}/backups/versions/${target_id}/snapshot.tar.gz"
  assert_file "${case_deploy}/backups/versions/${safety_id}/snapshot.tar.gz"
  [[ "$(stat -c '%a' "${case_deploy}/backups/versions/${safety_id}/snapshot.tar.gz")" == 600 ]] \
    || fail "${failure_stage} 安全快照未受限保存"
  [[ "$(tar -xOzf "${case_deploy}/backups/versions/${safety_id}/snapshot.tar.gz" payload/.env | sha256sum | cut -d ' ' -f 1)" == "$previous_env_hash" ]] \
    || fail "${failure_stage} 安全快照未保留回滚前完整凭据"
  stage_payload=$(find "${case_deploy}/tmp" -mindepth 1 -maxdepth 1 -type d -name 'rollback-stage.*' -print -quit)
  [[ -n "$stage_payload" ]] || fail "${failure_stage} 失败后删除了恢复暂存材料"
  assert_file "${stage_payload}/payload/data/postgres/n8n.dump"
  if [[ "$failure_stage" == pg_password ]]; then
    [[ "$(<"$MOCK_POSTGRES_PASSWORD_DIGEST_FILE")" == "$(printf '%s' "$target_password" | sha256sum | cut -d ' ' -f 1)" ]] \
      || fail "密码恢复未从 stdin 原样收到目标快照密码"
  elif grep -Fq '\password' "$MOCK_DOCKER_LOG"; then
    fail "数据库恢复失败后仍尝试改角色密码"
  fi
  for forbidden_password in "$target_password" "$current_password"; do
    if grep -Fq -- "$forbidden_password" "$MOCK_DOCKER_LOG" "${case_root}/failure.log"; then
      fail "${failure_stage} 回滚将明文密码泄露到 argv 或输出"
    fi
  done
  # 真实生产恢复入口从停机的失败事实恢复成套安全快照；不是重置夹具后宣称通过。
  "${case_deploy}/scripts/rollback.sh" --deploy-dir "$case_deploy" --snapshot "$safety_id" \
    --no-safety-snapshot > "${case_root}/recovery.log" 2>&1
  [[ "$(sha256sum "${case_deploy}/data/anythingllm/rollback-failure.txt" | cut -d ' ' -f 1)" == "$previous_hash" \
    && "$(sha256sum "${case_deploy}/config/prompt.md" | cut -d ' ' -f 1)" == "$previous_prompt_hash" \
    && "$(sha256sum "${case_deploy}/.env" | cut -d ' ' -f 1)" == "$previous_env_hash" ]] \
    || fail "${failure_stage} 失败后的成套安全恢复不一致"
  [[ "$(<"$MOCK_POSTGRES_PASSWORD_DIGEST_FILE")" == "$(printf '%s' "$current_password" | sha256sum | cut -d ' ' -f 1)" ]] \
    || fail "${failure_stage} 安全恢复未恢复正确数据库角色密码"
  for service in postgres n8n anythingllm provider-adapter; do
    grep -Fxq "$service" "$MOCK_DOCKER_SERVICE_STATE" || fail "安全恢复后 ${service} 未重新启动"
  done
  grep -Fxq 'state=local-ready' "${case_deploy}/.crisp-ai-installation" \
    || fail "安全恢复后没有真实外部会话却错误报告 ready"
}

for rollback_failure_stage in pg_restore pg_password; do
  assert_rollback_mutation_failure "$rollback_failure_stage"
  pass "${rollback_failure_stage} 故障不启动混合状态、保留双份数据/安全快照且可成套恢复"
done

bash -c 'set -euo pipefail; source "$1/scripts/common.sh"; env_set "$1/.env" SNAPSHOT_RETENTION_COUNT 2' \
  -- "$DEPLOY_DIR"
for reason in retention-a retention-b retention-c; do
  RETAINED_SNAPSHOT_ID=$("${DEPLOY_DIR}/scripts/snapshot.sh" --deploy-dir "$DEPLOY_DIR" --reason "$reason" --quiet)
done
RETAINED_COUNT=$(find "${DEPLOY_DIR}/backups/versions" -mindepth 2 -maxdepth 2 -type f -name manifest.json | wc -l)
[[ "$RETAINED_COUNT" == 2 ]] || fail "版本快照保留数量不是 2"
[[ -d "${DEPLOY_DIR}/backups/versions/${RETAINED_SNAPSHOT_ID}" ]] || fail "保留策略删除了最新版本快照"
pass "版本快照历史保留数量策略"

printf 'v0.6.0\n' > "${DEPLOY_DIR}/VERSION"
printf '%s\n' '{"handoff":{"keywords":["人工","客服","真人"],"resume_keywords":["恢复AI"],"topic_keywords":{"payment":["付款"]},"resume_after_seconds":1800,"on_operator_message":true,"on_low_confidence":true,"on_no_answer":true,"confirmation":"已为您转接人工客服，AI 将暂停回复。","no_answer_message":"知识库暂时没有足够信息，已为您转接人工客服。","low_confidence_message":"当前答案可信度不足，已为您转接人工客服。","failure_message":"当前自动客服暂时不可用，已为您转接人工客服。","low_confidence":{"require_sources":true,"minimum_score":0.25}}}' \
  > "${DEPLOY_DIR}/config/handoff.yaml"
printf '%s\n' '{"tags":{"enabled":true,"ai_resolved":"customer_resolved","knowledge_miss":"knowledge-miss","low_confidence":"low-confidence","human_required":"human-required"}}' \
  > "${DEPLOY_DIR}/config/tags.yaml"
sed -i '/^SNAPSHOT_MIN_FREE_MB=/d; /^SNAPSHOT_RETENTION_COUNT=/d' "${DEPLOY_DIR}/.env"
rm -f -- "${DEPLOY_DIR}/scripts/analytics.sh" "${DEPLOY_DIR}/scripts/snapshot.sh" "${DEPLOY_DIR}/scripts/rollback.sh"
if env MOCK_DOCKER_FAIL_PULL=1 "${DEPLOY_DIR}/update.sh" \
  --deploy-dir "$DEPLOY_DIR" --source-dir "$PROJECT_ROOT" --no-pull \
  > "${TEST_ROOT}/update-rollback.log" 2>&1; then
  fail "镜像拉取失败时更新被错误报告为成功"
fi
[[ "$(<"${DEPLOY_DIR}/VERSION")" == v0.6.0 ]] || fail "更新失败后未恢复旧版本"
grep -Fq '已自动回滚到更新前版本' "${TEST_ROOT}/update-rollback.log" || fail "更新失败未报告自动回滚"
[[ "$(sed -n 's/^SNAPSHOT_MIN_FREE_MB=//p' "${DEPLOY_DIR}/.env")" == 1024 ]] || fail "旧部署未补齐快照预留空间"
[[ "$(sed -n 's/^SNAPSHOT_RETENTION_COUNT=//p' "${DEPLOY_DIR}/.env")" == 10 ]] || fail "旧部署未补齐快照保留数量"
pass "更新失败自动回滚"

ENV_HASH_BEFORE=$(sha256sum "${DEPLOY_DIR}/.env" | awk '{print $1}')
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf "legacy-backup-should-not-run\\n" >&2' \
  'exit 97' > "${DEPLOY_DIR}/scripts/backup.sh"
chmod 0750 "${DEPLOY_DIR}/scripts/backup.sh"
"${DEPLOY_DIR}/update.sh" \
  --deploy-dir "$DEPLOY_DIR" --source-dir "$PROJECT_ROOT" --no-pull \
  > "${TEST_ROOT}/update.log" 2>&1
if grep -Fq 'legacy-backup-should-not-run' "${TEST_ROOT}/update.log"; then
  fail "升级错误调用了旧部署中的备份脚本"
fi
[[ "$(<"${DEPLOY_DIR}/VERSION")" == "$PROJECT_VERSION" ]] || fail "更新后版本错误"
[[ "$(sha256sum "${DEPLOY_DIR}/.env" | awk '{print $1}')" == "$ENV_HASH_BEFORE" ]] || fail "更新改写了 .env"
jq -e '
  .handoff.disable_ai == true and .handoff.notify_user.enabled == true and
  (.handoff.keywords | index("转人工") != null) and
  (.handoff.keywords | index("真人") != null) and
  .handoff.message == "正在为您转接人工客服，请稍候。" and
  (.handoff | has("topic_keywords") | not) and
  (.handoff | has("on_low_confidence") | not) and
  (.handoff.no_answer_message | contains("转接人工") | not)
' "${DEPLOY_DIR}/config/handoff.yaml" >/dev/null || fail "旧人工接管配置未安全迁移"
jq -e '
  .tags.ai_resolved == "customer_resolved" and
  .tags.knowledge_miss == "knowledge_miss" and
  .tags.low_confidence == "low_confidence" and
  .tags.human_required == "human_required"
' "${DEPLOY_DIR}/config/tags.yaml" >/dev/null || fail "旧默认标签未安全迁移"
[[ -n "$(find "${DEPLOY_DIR}/backups" -maxdepth 1 -type f -name 'pre-update-*.tar.gz' -print -quit)" ]] \
  || fail "更新前未创建备份"
[[ -n "$(find "${DEPLOY_DIR}/backups/versions" -mindepth 1 -maxdepth 1 -type d -print -quit)" ]] \
  || fail "更新前未创建版本快照"
pass "更新、备份与配置保留"

mkdir -p -- "${DEPLOY_DIR}/logs"
printf '安全卸载后应保留的日志\n' > "${DEPLOY_DIR}/logs/uninstall-preserve.log"
printf '安全卸载后应保留的数据\n' > "${DEPLOY_DIR}/data/uninstall-preserve.txt"
SAFE_ENV_HASH=$(sha256sum "${DEPLOY_DIR}/.env" | awk '{print $1}')
SAFE_PROMPT_HASH=$(sha256sum "${DEPLOY_DIR}/config/prompt.md" | awk '{print $1}')
SAFE_BACKUP_COUNT_BEFORE=$(find "${DEPLOY_DIR}/backups" -maxdepth 1 -type f \
  -name 'uninstall-backup-*.tar.gz' | wc -l)
: > "$MOCK_DOCKER_LOG"
"${DEPLOY_DIR}/uninstall.sh" --deploy-dir "$DEPLOY_DIR" --yes \
  > "${TEST_ROOT}/uninstall-safe.log" 2>&1
SAFE_BACKUP_COUNT_AFTER=$(find "${DEPLOY_DIR}/backups" -maxdepth 1 -type f \
  -name 'uninstall-backup-*.tar.gz' | wc -l)
(( SAFE_BACKUP_COUNT_AFTER == SAFE_BACKUP_COUNT_BEFORE + 1 )) \
  || fail "默认安全卸载未自动创建唯一备份"
SAFE_UNINSTALL_BACKUP=$(find "${DEPLOY_DIR}/backups" -maxdepth 1 -type f \
  -name 'uninstall-backup-*.tar.gz' -printf '%T@\t%p\n' | sort -n | tail -n 1 | cut -f2-)
[[ -n "$SAFE_UNINSTALL_BACKUP" && "$(stat -c '%a' "$SAFE_UNINSTALL_BACKUP")" == 600 ]] \
  || fail "安全卸载备份缺失或权限不是 0600"
tar -xOzf "$SAFE_UNINSTALL_BACKUP" manifest.json | jq -e '.contains_env == true and .contains_database_dump == true' >/dev/null \
  || fail "安全卸载没有生成包含凭据与数据库的完整本机备份"
tar -xOzf "$SAFE_UNINSTALL_BACKUP" snapshot.tar.gz > "${TEST_ROOT}/safe-uninstall-snapshot.tar.gz"
BACKUP_ENV_HASH=$(tar -xOzf "${TEST_ROOT}/safe-uninstall-snapshot.tar.gz" payload/.env | sha256sum | cut -d ' ' -f 1)
[[ "$BACKUP_ENV_HASH" == "$SAFE_ENV_HASH" ]] || fail "安全卸载完整备份没有准确保留内部凭据"
grep -Eq '(^| )down( |$)' "$MOCK_DOCKER_LOG" || fail "默认安全卸载未执行 Docker Compose down"
[[ -f "${DEPLOY_DIR}/.env" && "$(stat -c '%a' "${DEPLOY_DIR}/.env")" == 600 ]] \
  || fail "安全卸载未以 0600 保留 .env"
[[ "$(sha256sum "${DEPLOY_DIR}/.env" | awk '{print $1}')" == "$SAFE_ENV_HASH" ]] \
  || fail "安全卸载改写了 .env"
[[ "$(sha256sum "${DEPLOY_DIR}/config/prompt.md" | awk '{print $1}')" == "$SAFE_PROMPT_HASH" ]] \
  || fail "安全卸载改写了 Prompt 配置"
[[ -f "${DEPLOY_DIR}/knowledge/test-knowledge.md" ]] || fail "安全卸载删除了知识文件"
[[ -f "${DEPLOY_DIR}/logs/uninstall-preserve.log" ]] || fail "安全卸载删除了日志"
[[ -f "${DEPLOY_DIR}/data/uninstall-preserve.txt" ]] || fail "安全卸载删除了运行数据"
[[ -d "${DEPLOY_DIR}/config" && -d "${DEPLOY_DIR}/knowledge" \
  && -d "${DEPLOY_DIR}/backups" && -d "${DEPLOY_DIR}/logs" && -d "${DEPLOY_DIR}/data" ]] \
  || fail "安全卸载未保留约定目录"
for removed_path in install.sh manage.sh update.sh uninstall.sh docker-compose.yml scripts n8n; do
  [[ ! -e "${DEPLOY_DIR}/${removed_path}" ]] || fail "安全卸载未移除服务程序项：${removed_path}"
done
[[ ! -e "${TEST_ROOT}/bin/crispai" ]] || fail "安全卸载留下指向已移除程序的本实例管理命令"
assert_file "${TEST_ROOT}/bin/crispai-plugin"
grep -Fq 'state=uninstalled-data-kept' "${DEPLOY_DIR}/.crisp-ai-installation" || fail "卸载状态标记错误"
for output_heading in 删除内容 保留内容 恢复方式; do
  grep -Fq "$output_heading" "${TEST_ROOT}/uninstall-safe.log" \
    || fail "安全卸载输出缺少：${output_heading}"
done
pass "默认安全卸载自动备份、停止服务并保留可恢复数据"

install -m 0600 -- "${DEPLOY_DIR}/.env" "${TEST_ROOT}/preserved-env"
sed -i 's/^AI_API_KEY=.*/AI_API_KEY=pending-provider-key/' "${DEPLOY_DIR}/.env"
if "${PROJECT_ROOT}/install.sh" --deploy-dir "$DEPLOY_DIR" --non-interactive \
  > "${TEST_ROOT}/reinstall-invalid-preserved-config.log" 2>&1; then
  fail "安全卸载保留占位凭据时重装未安全中止"
fi
grep -Fq -- '--reconfigure' "${TEST_ROOT}/reinstall-invalid-preserved-config.log" \
  || fail "保留配置无效时未明确要求 --reconfigure"
grep -Fxq 'state=uninstalled-data-kept' "${DEPLOY_DIR}/.crisp-ai-installation" \
  || fail "保留配置验证失败后卸载状态被改写"
[[ ! -e "${DEPLOY_DIR}/install.sh" && ! -e "${DEPLOY_DIR}/docker-compose.yml" ]] \
  || fail "保留配置验证失败后程序文件被提前恢复"
install -m 0600 -- "${TEST_ROOT}/preserved-env" "${DEPLOY_DIR}/.env"
pass "安全卸载保留配置缺失或占位时要求重新配置"

: > "$MOCK_DOCKER_LOG"
expect_local_ready_install "${PROJECT_ROOT}/install.sh" --deploy-dir "$DEPLOY_DIR" --non-interactive \
  > "${TEST_ROOT}/reinstall-after-uninstall.log" 2>&1
[[ -f "${DEPLOY_DIR}/manage.sh" && -f "${DEPLOY_DIR}/docker-compose.yml" \
  && -f "${DEPLOY_DIR}/n8n/workflow.json" ]] || fail "安全卸载后同路径重装未恢复程序"
[[ "$(cd / && "${TEST_ROOT}/bin/crispai" --version)" == "$PROJECT_VERSION" ]] || fail "同路径重装没有恢复本实例 crispai 命令"
grep -Fxq 'state=local-ready' "${DEPLOY_DIR}/.crisp-ai-installation" \
  || fail "安全卸载后同路径重装未返回如实的 local-ready 状态"
[[ "$(sha256sum "${DEPLOY_DIR}/.env" | awk '{print $1}')" == "$SAFE_ENV_HASH" ]] \
  || fail "安全卸载后同路径重装改写了 .env"
[[ "$(sha256sum "${DEPLOY_DIR}/config/prompt.md" | awk '{print $1}')" == "$SAFE_PROMPT_HASH" ]] \
  || fail "安全卸载后同路径重装改写了 Prompt"
[[ -f "${DEPLOY_DIR}/knowledge/test-knowledge.md" \
  && -f "${DEPLOY_DIR}/logs/uninstall-preserve.log" \
  && -f "${DEPLOY_DIR}/data/uninstall-preserve.txt" ]] \
  || fail "安全卸载后同路径重装未保留数据"
grep -Eq '(^| )up( |$)' "$MOCK_DOCKER_LOG" || fail "安全卸载后重装未重新启动服务"
grep -Fq '已验证安全卸载保留的 .env 与实际配置' \
  "${TEST_ROOT}/reinstall-after-uninstall.log" \
  || fail "安全卸载后重装未明确说明已验证并复用保留配置"
pass "安全卸载后同路径重装与数据恢复"

: > "$MOCK_DOCKER_LOG"
if printf '1\n9\n' | "${PLUGIN_DEPLOY_DIR}/uninstall.sh" \
  --deploy-dir "$PLUGIN_DEPLOY_DIR" --purge \
  > "${TEST_ROOT}/uninstall-purge-wrong-confirmation.log" 2>&1; then
  fail "错误数字二次确认仍执行了彻底卸载"
fi
[[ -d "$PLUGIN_DEPLOY_DIR" && -f "${PLUGIN_DEPLOY_DIR}/uninstall.sh" ]] \
  || fail "错误数字二次确认破坏了部署目录"
if grep -Eq '(^| )down( |$)' "$MOCK_DOCKER_LOG"; then
  fail "错误数字二次确认后仍停止了服务"
fi
grep -Fq '第二次确认' "${TEST_ROOT}/uninstall-purge-wrong-confirmation.log" \
  || fail "完整清理未明确要求第二次数字确认"
: > "$MOCK_DOCKER_LOG"
if printf '1\n9\n' | "${PLUGIN_DEPLOY_DIR}/uninstall.sh" \
  --deploy-dir "$PLUGIN_DEPLOY_DIR" --purge --yes \
  > "${TEST_ROOT}/uninstall-purge-yes-confirmation.log" 2>&1; then
  fail "--yes 绕过了数字二次确认"
fi
[[ -d "$PLUGIN_DEPLOY_DIR" && -f "${PLUGIN_DEPLOY_DIR}/uninstall.sh" ]] \
  || fail "--yes 的错误数字确认破坏了部署目录"
grep -Fq '第二次确认' "${TEST_ROOT}/uninstall-purge-yes-confirmation.log" \
  || fail "--yes 场景未要求数字二次确认"

: > "$MOCK_DOCKER_LOG"
if printf '1\n0\n' | "${PLUGIN_DEPLOY_DIR}/uninstall.sh" \
  --deploy-dir "$PLUGIN_DEPLOY_DIR" --purge --numeric-confirm \
  > "${TEST_ROOT}/uninstall-purge-numeric-cancel.log" 2>&1; then
  fail "数字二次确认取消后仍执行了完整清理"
fi
[[ -d "$PLUGIN_DEPLOY_DIR" && -f "${PLUGIN_DEPLOY_DIR}/uninstall.sh" ]] \
  || fail "数字二次确认取消破坏了部署目录"
grep -Fq '已取消完整清理' "${TEST_ROOT}/uninstall-purge-numeric-cancel.log" \
  || fail "数字二次确认没有安全取消或触发了 set -u 错误"
if grep -Eq '(^| )down( |$)' "$MOCK_DOCKER_LOG"; then
  fail "数字二次确认取消后仍停止了服务"
fi
pass "完整清理要求普通确认及不可绕过的数字二次确认"

PURGE_ENV_HASH=$(sha256sum "${PLUGIN_DEPLOY_DIR}/.env" | awk '{print $1}')
PURGE_PROMPT_HASH=$(sha256sum "${PLUGIN_DEPLOY_DIR}/config/prompt.md" | awk '{print $1}')
: > "$MOCK_DOCKER_LOG"
if printf '1\n1\n' | env MOCK_DOCKER_REMAINING_NETWORKS=1 \
  "${PLUGIN_DEPLOY_DIR}/uninstall.sh" --deploy-dir "$PLUGIN_DEPLOY_DIR" --purge \
  > "${TEST_ROOT}/uninstall-network-residual.log" 2>&1; then
  fail "Docker Compose down 返回 0 但网络残留时完整清理被错误报告为成功"
fi
[[ -d "$PLUGIN_DEPLOY_DIR" && -f "${PLUGIN_DEPLOY_DIR}/uninstall.sh" \
  && -f "${PLUGIN_DEPLOY_DIR}/docker-compose.yml" ]] \
  || fail "Compose 网络残留时服务程序被破坏"
[[ "$(sha256sum "${PLUGIN_DEPLOY_DIR}/.env" | awk '{print $1}')" == "$PURGE_ENV_HASH" ]] \
  || fail "Compose 网络残留时 .env 被改写"
[[ "$(sha256sum "${PLUGIN_DEPLOY_DIR}/config/prompt.md" | awk '{print $1}')" == "$PURGE_PROMPT_HASH" ]] \
  || fail "Compose 网络残留时配置被改写"
grep -Eq '(^| )down( |$)' "$MOCK_DOCKER_LOG" \
  || fail "Compose 网络残留路径未实际执行 down"
grep -Eq '^network ls .*com\.docker\.compose\.project=' "$MOCK_DOCKER_LOG" \
  || fail "Compose down 后未核验项目网络"
if grep -Eq '^(container|network) (rm|remove)( |$)' "$MOCK_DOCKER_LOG"; then
  fail "Compose 网络残留时试图强制删除外部容器或网络"
fi
grep -Fq '网络可能被外部容器占用' "${TEST_ROOT}/uninstall-network-residual.log" \
  || fail "Compose 网络残留时未说明可能原因"
grep -Fq '自动备份位于' "${TEST_ROOT}/uninstall-network-residual.log" \
  || fail "Compose 网络残留时未说明自动备份位置"
pass "Compose down 返回 0 但项目网络残留时安全中止"

: > "$MOCK_DOCKER_LOG"
if printf '1\n1\n' | env MOCK_DOCKER_FAIL_DOWN=1 "${PLUGIN_DEPLOY_DIR}/uninstall.sh" \
  --deploy-dir "$PLUGIN_DEPLOY_DIR" --purge \
  > "${TEST_ROOT}/uninstall-down-failure.log" 2>&1; then
  fail "Docker Compose 停止失败时彻底卸载仍被报告为成功"
fi
[[ -d "$PLUGIN_DEPLOY_DIR" && -f "${PLUGIN_DEPLOY_DIR}/uninstall.sh" \
  && -f "${PLUGIN_DEPLOY_DIR}/docker-compose.yml" ]] \
  || fail "Docker Compose 停止失败后服务程序被破坏"
[[ "$(sha256sum "${PLUGIN_DEPLOY_DIR}/.env" | awk '{print $1}')" == "$PURGE_ENV_HASH" ]] \
  || fail "Docker Compose 停止失败后 .env 被改写"
[[ "$(sha256sum "${PLUGIN_DEPLOY_DIR}/config/prompt.md" | awk '{print $1}')" == "$PURGE_PROMPT_HASH" ]] \
  || fail "Docker Compose 停止失败后配置被改写"
grep -Eq '(^| )down( |$)' "$MOCK_DOCKER_LOG" || fail "Docker Compose down 失败路径未实际执行 down"
grep -Eq '停止|Docker|容器' "${TEST_ROOT}/uninstall-down-failure.log" \
  || fail "Docker Compose 停止失败没有清晰提示"
pass "Docker Compose down 失败时完整保留部署"

FINAL_BACKUP_COUNT_BEFORE=$(find "$TEST_ROOT" -maxdepth 1 -type f \
  -name 'crisp-ai-purge-backup-*.tar.gz' | wc -l)
printf '1\n1\n' | "${PLUGIN_DEPLOY_DIR}/uninstall.sh" \
  --deploy-dir "$PLUGIN_DEPLOY_DIR" --purge > "${TEST_ROOT}/uninstall-purge.log" 2>&1
[[ ! -e "$PLUGIN_DEPLOY_DIR" ]] || fail "彻底卸载未删除部署目录"
[[ ! -e "${TEST_ROOT}/bin/crispai-plugin" ]] || fail "完整清理留下本实例管理命令"
assert_file "${TEST_ROOT}/bin/crispai"
FINAL_BACKUP_COUNT_AFTER=$(find "$TEST_ROOT" -maxdepth 1 -type f \
  -name 'crisp-ai-purge-backup-*.tar.gz' | wc -l)
(( FINAL_BACKUP_COUNT_AFTER == FINAL_BACKUP_COUNT_BEFORE + 1 )) \
  || fail "彻底卸载未在部署父目录创建最终备份"
FINAL_UNINSTALL_BACKUP=$(find "$TEST_ROOT" -maxdepth 1 -type f \
  -name 'crisp-ai-purge-backup-*.tar.gz' -printf '%T@\t%p\n' | sort -n | tail -n 1 | cut -f2-)
[[ -n "$FINAL_UNINSTALL_BACKUP" && "$(stat -c '%a' "$FINAL_UNINSTALL_BACKUP")" == 600 ]] \
  || fail "彻底卸载最终备份缺失或权限不是 0600"
tar -xOzf "$FINAL_UNINSTALL_BACKUP" manifest.json | jq -e '.contains_env == true and .contains_database_dump == true' >/dev/null \
  || fail "完整清理外部备份不是可恢复的完整本机备份"
tar -xOzf "$FINAL_UNINSTALL_BACKUP" snapshot.tar.gz > "${TEST_ROOT}/purge-snapshot.tar.gz"
BACKUP_ENV_HASH=$(tar -xOzf "${TEST_ROOT}/purge-snapshot.tar.gz" payload/.env | sha256sum | cut -d ' ' -f 1)
[[ "$BACKUP_ENV_HASH" == "$PURGE_ENV_HASH" ]] || fail "完整清理外部备份未准确保留凭据"
grep -Fq '完整清理完成' "${TEST_ROOT}/uninstall-purge.log" || fail "彻底卸载未说明完成状态"
for output_heading in 删除内容 保留内容 恢复方式; do
  grep -Fq "$output_heading" "${TEST_ROOT}/uninstall-purge.log" \
    || fail "彻底卸载输出缺少：${output_heading}"
done
pass "数字二次确认后的完整卸载与父目录受限完整备份"

printf '\n分层结果：\n'
for layer in STATIC UNIT/CONTRACT REAL-LOCAL EXTERNAL-E2E; do
  printf -- '- %s：通过 %d，跳过 %d\n' \
    "$layer" "${LAYER_PASSED[$layer]}" "${LAYER_SKIPPED[$layer]}"
done
printf '测试完成：通过 %d，跳过 %d，失败 0。\n' "$PASSED" "$SKIPPED"
[[ "$TEST_SELECTION" == all ]] || printf '上述仅为生命周期选定子集；最终发布必须无 --lifecycle-only 重新执行全量测试。\n'
if (( RELEASE_MODE && EXTERNAL_PENDING_MODE )); then
  printf '源码发布验收：通过；External Validation Pending（仅 EXTERNAL-E2E 层允许跳过）。\n'
fi
