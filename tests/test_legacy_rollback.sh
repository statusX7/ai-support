#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
MOCK_DIR="${SCRIPT_DIR}/mocks"
ORIGINAL_PATH=$PATH

fail() {
  printf '失败：[UNIT/CONTRACT] %s\n' "$1" >&2
  exit 1
}

for command_name in git tar jq sha256sum realpath; do
  command -v "$command_name" >/dev/null 2>&1 || fail "缺少测试命令：${command_name}"
done
(( EUID == 0 )) || fail '旧版完整快照回滚测试需要 root，以执行生产回滚入口'
git -C "$PROJECT_ROOT" rev-parse --verify 'v1.1.0^{commit}' >/dev/null 2>&1 \
  || fail '缺少真实 v1.1.0 tag，无法构造旧版快照'

TEST_ROOT=$(mktemp -d "${PROJECT_ROOT}/.legacy-rollback-test.XXXXXX")
cleanup() {
  if [[ "${AI_SUPPORT_TEST_KEEP_TMP:-0}" == 1 ]]; then
    printf '调试目录已保留：%s\n' "$TEST_ROOT" >&2
    return
  fi
  if [[ "$TEST_ROOT" == "${PROJECT_ROOT}"/.legacy-rollback-test.* && -d "$TEST_ROOT" ]]; then
    rm -rf -- "$TEST_ROOT"
  fi
}
trap cleanup EXIT

LEGACY_SOURCE="${TEST_ROOT}/v1.1.0-source"
DEPLOY_DIR="${TEST_ROOT}/deploy"
COMMAND_PATH="${TEST_ROOT}/bin/crispai"
MOCK_DOCKER_LOG="${TEST_ROOT}/docker.log"
MOCK_ANYTHING_STATE="${TEST_ROOT}/anythingllm-state.json"
MOCK_FORBIDDEN_ARG_FILE="${TEST_ROOT}/forbidden-curl-args.txt"
STUB_HOST_FIXTURE="${TEST_ROOT}/host-fixture"
mkdir -p -- "$LEGACY_SOURCE" "${TEST_ROOT}/bin" "${STUB_HOST_FIXTURE}/etc/ssl/certs"

# 由已发布 tag 直接取得旧代程序，不复制当前工作树或手写一个“像旧版”的 fixture。
git -C "$PROJECT_ROOT" archive --format=tar v1.1.0 | tar -xf - -C "$LEGACY_SOURCE"
[[ "$(<"${LEGACY_SOURCE}/VERSION")" == v1.1.0 ]] || fail 'v1.1.0 tag 的 VERSION 不匹配'
[[ ! -e "${LEGACY_SOURCE}/get.sh" && ! -L "${LEGACY_SOURCE}/get.sh" ]] \
  || fail '真实 v1.1.0 tag 不应包含 get.sh'
[[ ! -e "${LEGACY_SOURCE}/scripts/doctor.sh" && ! -L "${LEGACY_SOURCE}/scripts/doctor.sh" ]] \
  || fail '真实 v1.1.0 tag 不应包含 scripts/doctor.sh'

printf '%s\n' 'ID=debian' 'VERSION_ID="12"' 'VERSION_CODENAME=bookworm' \
  > "${STUB_HOST_FIXTURE}/os-release"
printf '%s\n' 'test CA bundle' > "${STUB_HOST_FIXTURE}/etc/ssl/certs/ca-certificates.crt"
printf '{"documents":[]}\n' > "$MOCK_ANYTHING_STATE"
: > "$MOCK_DOCKER_LOG"

TEST_PROVIDER_KEY='test-only-legacy-provider-key'
TEST_CRISP_KEY='test-only-legacy-crisp-key'
TEST_ANYTHING_KEY='test-only-legacy-anything-key'
TEST_CRISP_AUTH=$(printf '%s' "test-only-legacy-identifier:${TEST_CRISP_KEY}" | base64 | tr -d '\n')
printf '%s\n' "$TEST_PROVIDER_KEY" "$TEST_CRISP_KEY" "$TEST_ANYTHING_KEY" "$TEST_CRISP_AUTH" \
  > "$MOCK_FORBIDDEN_ARG_FILE"

export PATH="${MOCK_DIR}:${ORIGINAL_PATH}"
export MOCK_DOCKER_LOG MOCK_ANYTHING_STATE MOCK_FORBIDDEN_ARG_FILE
export CRISP_AI_BOOTSTRAP_TEST_MODE=1
export CRISP_AI_BOOTSTRAP_OS_RELEASE="${STUB_HOST_FIXTURE}/os-release"
export CRISP_AI_BOOTSTRAP_ETC_ROOT="${STUB_HOST_FIXTURE}/etc"
export CRISP_AI_BOOTSTRAP_INIT=unsupported

install_status=0
env \
  AI_API_BASE_URL=https://legacy-provider.invalid \
  AI_API_KEY="$TEST_PROVIDER_KEY" \
  AI_MODEL=gpt-legacy-test \
  AI_SUPPORTS_VISION=false \
  CRISP_WEBSITE_ID=11111111-1111-4111-8111-111111111110 \
  CRISP_TOKEN_TIER=website \
  CRISP_TOKEN_IDENTIFIER=test-only-legacy-identifier \
  CRISP_TOKEN_KEY="$TEST_CRISP_KEY" \
  ANYTHINGLLM_API_KEY="$TEST_ANYTHING_KEY" \
  N8N_HOST=legacy-support.example.invalid \
  PUBLIC_WEBHOOK_URL=https://legacy-support.example.invalid/ \
  TIMEZONE=UTC \
  SNAPSHOT_MIN_FREE_MB=0 \
  "$LEGACY_SOURCE/install.sh" --deploy-dir "$DEPLOY_DIR" \
    --command-path "$COMMAND_PATH" --non-interactive \
    > "${TEST_ROOT}/legacy-install.log" 2>&1 || install_status=$?
(( install_status == 2 )) \
  || fail "v1.1.0 隔离安装未形成预期 local-ready（状态 ${install_status}）"
[[ "$(<"${DEPLOY_DIR}/VERSION")" == v1.1.0 ]] || fail '旧版隔离实例版本错误'

LEGACY_SNAPSHOT_ID=$("${DEPLOY_DIR}/scripts/snapshot.sh" \
  --deploy-dir "$DEPLOY_DIR" --reason legacy-v1.1.0-layout --quiet)
LEGACY_SNAPSHOT_DIR="${DEPLOY_DIR}/backups/versions/${LEGACY_SNAPSHOT_ID}"
LEGACY_ARCHIVE="${LEGACY_SNAPSHOT_DIR}/snapshot.tar.gz"
[[ -f "$LEGACY_ARCHIVE" && ! -L "$LEGACY_ARCHIVE" ]] || fail '真实旧版快照未生成'
LEGACY_LIST=$(tar -tzf "$LEGACY_ARCHIVE")
grep -Fxq 'payload/install.sh' <<< "$LEGACY_LIST" || fail '旧版快照缺少传统安装入口'
grep -Fxq 'payload/manage.sh' <<< "$LEGACY_LIST" || fail '旧版快照缺少传统管理入口'
if grep -Eq '^payload/(get\.sh|scripts/doctor\.sh)$' <<< "$LEGACY_LIST"; then
  fail '旧版快照意外包含 v1.1.1 才有的 get.sh 或 doctor.sh'
fi

# 在同一部署上模拟已完成的 v1.1.1 程序代切换；运行数据与旧快照仍属于同一实例。
bash -c 'set -euo pipefail
  source "$1/scripts/common.sh"
  copy_project_files "$1" "$2"
  initialize_config_files "$2"
  migrate_config_files "$2"
  migrate_runtime_env "$2"
  write_installation_marker "$2" "$1" "$(<"$1/VERSION")" local-ready
' -- "$PROJECT_ROOT" "$DEPLOY_DIR"
bash "${PROJECT_ROOT}/scripts/launcher.sh" install --deploy-dir "$DEPLOY_DIR" \
  --command-path "$COMMAND_PATH" --non-interactive >/dev/null
[[ "$(<"${DEPLOY_DIR}/VERSION")" == v1.1.1 ]] || fail '未形成待回滚的 v1.1.1 程序代'
[[ -f "${DEPLOY_DIR}/get.sh" && ! -L "${DEPLOY_DIR}/get.sh" ]] || fail '升级代缺少 get.sh'
[[ -f "${DEPLOY_DIR}/scripts/doctor.sh" && ! -L "${DEPLOY_DIR}/scripts/doctor.sh" ]] \
  || fail '升级代缺少 doctor.sh'

# 缺少传统四入口之一的快照即使校验和自洽，也必须在停止服务前拒绝。
BROKEN_ID="legacy-missing-install-${LEGACY_SNAPSHOT_ID}"
BROKEN_DIR="${DEPLOY_DIR}/backups/versions/${BROKEN_ID}"
BROKEN_STAGE="${TEST_ROOT}/broken-stage"
mkdir -p -- "$BROKEN_DIR" "$BROKEN_STAGE"
tar -xzf "$LEGACY_ARCHIVE" -C "$BROKEN_STAGE"
rm -f -- "${BROKEN_STAGE}/payload/install.sh"
tar -czf "${BROKEN_DIR}/snapshot.tar.gz" -C "$BROKEN_STAGE" payload
BROKEN_SHA=$(sha256sum "${BROKEN_DIR}/snapshot.tar.gz" | awk '{print $1}')
jq --arg id "$BROKEN_ID" --arg sha "$BROKEN_SHA" \
  '.id = $id | .archive_sha256 = $sha | .reason = "legacy-required-entry-negative"' \
  "${LEGACY_SNAPSHOT_DIR}/manifest.json" > "${BROKEN_DIR}/manifest.json"
chmod 600 "${BROKEN_DIR}/snapshot.tar.gz" "${BROKEN_DIR}/manifest.json"
: > "$MOCK_DOCKER_LOG"
broken_status=0
"${DEPLOY_DIR}/scripts/rollback.sh" --deploy-dir "$DEPLOY_DIR" \
  --snapshot "$BROKEN_ID" --no-safety-snapshot \
  > "${TEST_ROOT}/broken-rollback.log" 2>&1 || broken_status=$?
(( broken_status != 0 )) || fail '缺少传统入口的旧快照被错误接受'
grep -Fq '版本快照缺少必要入口：install.sh' "${TEST_ROOT}/broken-rollback.log" \
  || fail '损坏旧快照没有指出缺失的传统入口'
if grep -Eq '(^| )stop( |$)' "$MOCK_DOCKER_LOG"; then
  fail '旧快照必要入口预检失败后仍停止了服务'
fi
[[ "$(<"${DEPLOY_DIR}/VERSION")" == v1.1.1 ]] || fail '预检失败修改了当前版本'
[[ -f "${DEPLOY_DIR}/get.sh" && -f "${DEPLOY_DIR}/scripts/doctor.sh" ]] \
  || fail '预检失败移除了当前代模块'

: > "$MOCK_DOCKER_LOG"
"${DEPLOY_DIR}/scripts/rollback.sh" --deploy-dir "$DEPLOY_DIR" \
  --snapshot "$LEGACY_SNAPSHOT_ID" --no-safety-snapshot \
  > "${TEST_ROOT}/legacy-rollback.log" 2>&1

[[ "$(<"${DEPLOY_DIR}/VERSION")" == v1.1.0 ]] || fail '旧版快照回滚后 VERSION 不正确'
[[ ! -e "${DEPLOY_DIR}/get.sh" && ! -L "${DEPLOY_DIR}/get.sh" ]] \
  || fail '回滚 v1.1.0 后残留新代 get.sh'
[[ ! -e "${DEPLOY_DIR}/scripts/doctor.sh" && ! -L "${DEPLOY_DIR}/scripts/doctor.sh" ]] \
  || fail '回滚 v1.1.0 后残留新代 doctor.sh'
for relative in install.sh manage.sh update.sh uninstall.sh scripts/common.sh scripts/rollback.sh \
  scripts/launcher.sh n8n/runtime.js; do
  cmp -s -- "${LEGACY_SOURCE}/${relative}" "${DEPLOY_DIR}/${relative}" \
    || fail "回滚后文件仍为混合代：${relative}"
done
grep -Fxq 'state=local-ready' "${DEPLOY_DIR}/.crisp-ai-installation" \
  || fail '旧版回滚完成后安装状态不正确'
grep -Fxq 'installed_version=v1.1.0' "${DEPLOY_DIR}/.crisp-ai-installation" \
  || fail '旧版回滚完成后 marker 版本不正确'
grep -Fq '目标快照不含 get.sh，已移除当前版本的受管模块' \
  "${TEST_ROOT}/legacy-rollback.log" || fail '回滚日志未记录 get.sh 降代移除'
grep -Fq '目标快照不含 scripts/doctor.sh，已移除当前版本的受管模块' \
  "${TEST_ROOT}/legacy-rollback.log" || fail '回滚日志未记录 doctor.sh 降代移除'
grep -Fq 'pg_restore' "$MOCK_DOCKER_LOG" || fail '旧版快照未实际执行数据库恢复路径'
grep -Fq -- '--force-recreate anythingllm' "$MOCK_DOCKER_LOG" \
  || fail '旧版快照未实际重建 AnythingLLM bind mount'

LEGACY_COMMIT=$(git -C "$PROJECT_ROOT" rev-parse --short=12 'v1.1.0^{commit}')
printf '通过：[UNIT/CONTRACT] 真实 v1.1.0 快照兼容回滚（tag commit %s）\n' "$LEGACY_COMMIT"
