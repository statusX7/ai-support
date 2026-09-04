#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
TEST_ROOT=$(mktemp -d "${PROJECT_ROOT}/.test-runtime.XXXXXX")
MOCK_DIR="${SCRIPT_DIR}/mocks"
ORIGINAL_PATH=$PATH
PASSED=0
SKIPPED=0

cleanup() {
  if [[ "$TEST_ROOT" == "${PROJECT_ROOT}"/.test-runtime.* && -d "$TEST_ROOT" ]]; then
    rm -rf -- "$TEST_ROOT"
  fi
}
trap cleanup EXIT

pass() {
  ((PASSED += 1))
  printf '通过：%s\n' "$1"
}

skip() {
  ((SKIPPED += 1))
  printf '跳过：%s\n' "$1"
}

fail() {
  printf '失败：%s\n' "$1" >&2
  exit 1
}

assert_file() {
  [[ -f "$1" && ! -L "$1" ]] || fail "缺少安全的普通文件：$1"
}

SHELL_FILES=(
  install.sh manage.sh update.sh uninstall.sh
  scripts/common.sh scripts/healthcheck.sh scripts/backup.sh scripts/restore.sh
  scripts/analytics.sh scripts/snapshot.sh scripts/rollback.sh
  tests/run.sh tests/test_workflow_contract.sh tests/test_workflow_runtime.sh
  tests/mocks/curl tests/mocks/docker
)
for file in "${SHELL_FILES[@]}"; do
  assert_file "${PROJECT_ROOT}/${file}"
done
bash -n "${SHELL_FILES[@]/#/${PROJECT_ROOT}/}"
pass "全部 Bash 脚本语法"

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -x "${SHELL_FILES[@]/#/${PROJECT_ROOT}/}"
  pass "shellcheck"
else
  skip "系统未安装 shellcheck"
fi

jq empty \
  "${PROJECT_ROOT}/n8n/workflow.json" \
  "${PROJECT_ROOT}/config/keyword.yaml.example" \
  "${PROJECT_ROOT}/config/menu.yaml.example" \
  "${PROJECT_ROOT}/config/handoff.yaml.example" \
  "${PROJECT_ROOT}/config/tags.yaml.example" \
  "${PROJECT_ROOT}/config/feedback.yaml.example"
[[ "$(<"${PROJECT_ROOT}/VERSION")" == v0.7.0 ]] || fail "VERSION 不是 v0.7.0"
grep -Fq 'version: v0.7.0' "${PROJECT_ROOT}/config/app.yaml" || fail "app.yaml 版本未同步"
pass "版本与 JSON/YAML 格式"

grep -Fq 'no-new-privileges:true' "${PROJECT_ROOT}/docker-compose.yml" || fail "Compose 缺少权限收紧"
grep -Fq '127.0.0.1' "${PROJECT_ROOT}/docker-compose.yml" || fail "Compose 未默认绑定本机"
grep -Fq 'N8N_BLOCK_ENV_ACCESS_IN_NODE: "false"' "${PROJECT_ROOT}/docker-compose.yml" || fail "n8n 无法读取受控环境变量"
grep -Fq 'NODE_FUNCTION_ALLOW_BUILTIN: crypto,fs' "${PROJECT_ROOT}/docker-compose.yml" || fail "n8n 内置模块白名单无效"
grep -Fq "source: \${DEPLOY_DIR:-/opt/crisp-ai}/data/postgres" "${PROJECT_ROOT}/docker-compose.yml" || fail "PostgreSQL 数据未集中保存"
grep -Fq "source: \${DEPLOY_DIR:-/opt/crisp-ai}/data/analytics" "${PROJECT_ROOT}/docker-compose.yml" || fail "匿名统计数据未集中保存"
pass "Docker Compose 静态安全契约"

if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  docker compose \
    --project-directory "$PROJECT_ROOT" \
    --env-file "${PROJECT_ROOT}/.env.example" \
    -f "${PROJECT_ROOT}/docker-compose.yml" \
    config --quiet
  pass "docker compose config"
else
  skip "系统未安装 Docker Compose v2，未执行实际 docker compose config"
fi

"${SCRIPT_DIR}/test_workflow_contract.sh"
pass "Webhook、图片、关键词、菜单、上下文与人工接管契约"

if "${SCRIPT_DIR}/test_workflow_runtime.sh"; then
  pass "n8n Code node 行为"
else
  runtime_status=$?
  if (( runtime_status == 77 )); then
    skip "系统未安装 Node.js，未执行 n8n Code node 行为"
  else
    fail "n8n Code node 行为测试失败"
  fi
fi

export PATH="${MOCK_DIR}:${ORIGINAL_PATH}"
export MOCK_DOCKER_LOG="${TEST_ROOT}/docker.log"
: > "$MOCK_DOCKER_LOG"

DEPLOY_DIR="${TEST_ROOT}/deploy"
FAILURE_DEPLOY_DIR="${TEST_ROOT}/provider-failure"
DOCKER_FAILURE_DEPLOY_DIR="${TEST_ROOT}/docker-failure"
INSTALL_LOG="${TEST_ROOT}/install.log"
TEST_PROVIDER_KEY='test-only-provider-key'
TEST_CRISP_KEY='test-only-crisp-key'
TEST_ANYTHING_KEY='test-only-anything-key'

env \
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
    --deploy-dir "$DEPLOY_DIR" --non-interactive > "$INSTALL_LOG" 2>&1

assert_file "${DEPLOY_DIR}/.crisp-ai-installation"
assert_file "${DEPLOY_DIR}/config/provider.yaml"
[[ "$(<"${DEPLOY_DIR}/VERSION")" == v0.7.0 ]] || fail "安装版本错误"
assert_file "${DEPLOY_DIR}/config/tags.yaml"
assert_file "${DEPLOY_DIR}/config/feedback.yaml"
assert_file "${DEPLOY_DIR}/data/analytics/events.jsonl"
[[ "$(stat -c '%a' "${DEPLOY_DIR}/.env")" == 600 ]] || fail ".env 权限不是 0600"
grep -Fq 'model: "gpt-vision-test"' "${DEPLOY_DIR}/config/provider.yaml" || fail "未选择检测到的模型"
grep -Fq 'responses: true' "${DEPLOY_DIR}/config/provider.yaml" || fail "未检测 Responses API"
grep -Fq 'chat_completions: true' "${DEPLOY_DIR}/config/provider.yaml" || fail "未检测 Chat Completions API"
grep -Fq 'vision: true' "${DEPLOY_DIR}/config/provider.yaml" || fail "视觉能力未保存"
[[ "$(sed -n 's/^SNAPSHOT_MIN_FREE_MB=//p' "${DEPLOY_DIR}/.env")" == 1024 ]] || fail "快照预留空间默认值错误"
[[ "$(sed -n 's/^SNAPSHOT_RETENTION_COUNT=//p' "${DEPLOY_DIR}/.env")" == 10 ]] || fail "快照保留数量默认值错误"
if grep -Fq "$TEST_PROVIDER_KEY" "$INSTALL_LOG"; then
  fail "安装日志泄露 API Key"
fi
grep -Fq 'publish:workflow' "$MOCK_DOCKER_LOG" || fail "安装未发布 n8n workflow"
grep -Fq 'info' "$MOCK_DOCKER_LOG" || fail "安装未检查 Docker daemon"
grep -Fq '安装与健康检查完成' "$INSTALL_LOG" || fail "安装未完成最终健康检查"
pass "安装与 Provider 自动检测"

if env MOCK_DOCKER_DAEMON_FAIL=1 "${PROJECT_ROOT}/install.sh" \
  --deploy-dir "$DOCKER_FAILURE_DEPLOY_DIR" --non-interactive \
  > "${TEST_ROOT}/docker-daemon-failure.log" 2>&1; then
  fail "Docker daemon 不可连接时安装被错误报告为成功"
fi
grep -Fq '无法连接 Docker daemon' "${TEST_ROOT}/docker-daemon-failure.log" \
  || fail "Docker daemon 失败没有清晰提示"
[[ ! -e "$DOCKER_FAILURE_DEPLOY_DIR" ]] || fail "Docker 预检失败后仍创建了部署目录"
pass "Docker daemon 安装前预检失败路径"

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

env \
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
    > "${TEST_ROOT}/provider-failure.log" 2>&1
grep -Fq 'model: "fallback-test-model"' "${FAILURE_DEPLOY_DIR}/config/provider.yaml" || fail "Provider 失败时未使用默认模型"
grep -Fq 'responses: false' "${FAILURE_DEPLOY_DIR}/config/provider.yaml" || fail "Provider 失败时错误标记 Responses"
grep -Fq 'chat_completions: false' "${FAILURE_DEPLOY_DIR}/config/provider.yaml" || fail "Provider 失败时错误标记 Chat API"
pass "AI Provider 失败回退"

install -m 0640 "${SCRIPT_DIR}/fixtures/knowledge.md" "${DEPLOY_DIR}/knowledge/test-knowledge.md"
install -m 0640 "${SCRIPT_DIR}/fixtures/knowledge.md" "${DEPLOY_DIR}/knowledge/test-knowledge.txt"
install -m 0640 "${SCRIPT_DIR}/fixtures/knowledge.md" "${DEPLOY_DIR}/knowledge/test-knowledge.pdf"
install -m 0640 "${SCRIPT_DIR}/fixtures/knowledge.md" "${DEPLOY_DIR}/knowledge/test-knowledge.docx"
bash -c "set -euo pipefail; source \"\$1/scripts/common.sh\"; knowledge_sync \"\$1\"; knowledge_reindex \"\$1\"" \
  -- "$DEPLOY_DIR" > "${TEST_ROOT}/knowledge-sync.log" 2>&1
jq -e '.files["test-knowledge.md"].locations | length > 0' \
  "${DEPLOY_DIR}/data/knowledge-manifest.json" >/dev/null || fail "知识文件未写入同步清单"
jq -e '
  (.files | keys | sort) == ["test-knowledge.docx","test-knowledge.md","test-knowledge.pdf","test-knowledge.txt"] and
  ([.files[].locations | length] | all(. > 0))
' "${DEPLOY_DIR}/data/knowledge-manifest.json" >/dev/null || fail "四种知识文件格式未全部写入同步清单"
rm -f -- "${DEPLOY_DIR}/knowledge/test-knowledge.md" "${DEPLOY_DIR}/knowledge/test-knowledge.txt" \
  "${DEPLOY_DIR}/knowledge/test-knowledge.pdf" "${DEPLOY_DIR}/knowledge/test-knowledge.docx"
bash -c "set -euo pipefail; source \"\$1/scripts/common.sh\"; knowledge_sync \"\$1\"" \
  -- "$DEPLOY_DIR" >> "${TEST_ROOT}/knowledge-sync.log" 2>&1
jq -e '.files | length == 0' "${DEPLOY_DIR}/data/knowledge-manifest.json" >/dev/null || fail "删除知识文件后未清理索引清单"
install -m 0640 "${SCRIPT_DIR}/fixtures/knowledge.md" "${DEPLOY_DIR}/knowledge/test-knowledge.md"
pass "Markdown、TXT、PDF、DOCX 知识库同步入口、重新索引与删除"

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
if tar -tzf "$ARCHIVE" | grep -E '(^|/)\.env$' >/dev/null; then
  fail "备份包含 .env"
fi
if tar -xOzf "$ARCHIVE" | grep -F "$TEST_PROVIDER_KEY" >/dev/null; then
  fail "备份包含 API Key"
fi
tar -xOzf "$ARCHIVE" ./manifest.json | jq -e '.contains_secrets == false' >/dev/null || fail "备份清单未声明排除密钥"
ARCHIVE_LIST=$(tar -tzf "$ARCHIVE")
grep -Fq './config/tags.yaml' <<< "$ARCHIVE_LIST" || fail "备份未包含标签配置"
grep -Fq './config/feedback.yaml' <<< "$ARCHIVE_LIST" || fail "备份未包含反馈配置"
printf '临时 Prompt，恢复后应被替换。\n' > "${DEPLOY_DIR}/config/prompt.md"
rm -f -- "${DEPLOY_DIR}/knowledge/test-knowledge.md"
"${DEPLOY_DIR}/scripts/restore.sh" \
  --deploy-dir "$DEPLOY_DIR" --input "$ARCHIVE" --skip-restart --no-safety-backup \
  > "${TEST_ROOT}/restore.log" 2>&1
[[ "$(sha256sum "${DEPLOY_DIR}/config/prompt.md" | awk '{print $1}')" == "$PROMPT_HASH" ]] || fail "Prompt 未恢复"
[[ -f "${DEPLOY_DIR}/knowledge/test-knowledge.md" ]] || fail "知识文件未恢复"
[[ "$(sha256sum "${DEPLOY_DIR}/.env" | awk '{print $1}')" == "$ENV_HASH_BEFORE" ]] || fail "恢复覆盖了 .env"
pass "无密钥备份与完整恢复"

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
if "${DEPLOY_DIR}/update.sh" --deploy-dir "$DEPLOY_DIR" --source-dir "$PROJECT_ROOT" --no-pull \
  > "${TEST_ROOT}/update-capacity-failure.log" 2>&1; then
  fail "快照空间不足时更新被错误报告为成功"
fi
grep -Fq '版本快照空间不足' "${TEST_ROOT}/update-capacity-failure.log" || fail "更新未报告快照空间不足"
if grep -Eq '(^| )stop( |$)' "$MOCK_DOCKER_LOG"; then
  fail "容量预检失败后仍停止了服务"
fi
bash -c 'set -euo pipefail; source "$1/scripts/common.sh"; env_set "$1/.env" SNAPSHOT_MIN_FREE_MB 0' \
  -- "$DEPLOY_DIR"
"${DEPLOY_DIR}/scripts/snapshot.sh" --deploy-dir "$DEPLOY_DIR" --check-capacity \
  > "${TEST_ROOT}/snapshot-capacity-success.log" 2>&1
grep -Fq '快照容量预检通过' "${TEST_ROOT}/snapshot-capacity-success.log" || fail "容量预检成功未输出依据"
pass "版本快照容量预检"

SNAPSHOT_ID=$("${DEPLOY_DIR}/scripts/snapshot.sh" --deploy-dir "$DEPLOY_DIR" --reason test-manual --quiet)
SNAPSHOT_LIST=$(tar -tzf "${DEPLOY_DIR}/backups/versions/${SNAPSHOT_ID}/snapshot.tar.gz")
if grep -Eq '(^|/)\.env$|data/analytics' <<< "$SNAPSHOT_LIST"; then
  fail "版本快照包含 .env 或匿名统计"
fi
grep -Fq 'payload/data/anythingllm/rollback-state.txt' <<< "$SNAPSHOT_LIST" || fail "版本快照未包含 AnythingLLM 数据"
jq -e '.capacity.min_free_mb == 0 and .capacity.estimated_source_kib > 0 and .retention_count == 10' \
  "${DEPLOY_DIR}/backups/versions/${SNAPSHOT_ID}/manifest.json" >/dev/null || fail "快照清单未记录容量与保留策略"
printf 'rollback-state-after\n' > "${DEPLOY_DIR}/data/anythingllm/rollback-state.txt"
printf '临时回滚 Prompt\n' > "${DEPLOY_DIR}/config/prompt.md"
bash -c 'set -euo pipefail; source "$1/scripts/common.sh"; env_set "$1/.env" SNAPSHOT_RETENTION_COUNT 1' \
  -- "$DEPLOY_DIR"
"${DEPLOY_DIR}/scripts/rollback.sh" --deploy-dir "$DEPLOY_DIR" --snapshot "$SNAPSHOT_ID" \
  --skip-start > "${TEST_ROOT}/rollback.log" 2>&1
grep -Fq 'rollback-state-before' "${DEPLOY_DIR}/data/anythingllm/rollback-state.txt" || fail "AnythingLLM 数据未回滚"
[[ "$(sha256sum "${DEPLOY_DIR}/config/prompt.md" | awk '{print $1}')" == "$PROMPT_HASH" ]] || fail "配置未随版本快照回滚"
SNAPSHOT_HISTORY=$("${DEPLOY_DIR}/scripts/rollback.sh" --deploy-dir "$DEPLOY_DIR" --list)
grep -Fq "$SNAPSHOT_ID" <<< "$SNAPSHOT_HISTORY" || fail "版本历史未列出快照"
grep -Fq '受保护快照使历史数量暂时超过保留上限' "${TEST_ROOT}/rollback.log" || fail "回滚目标未受保留策略保护"
pass "版本快照、AnythingLLM 数据与受保护手动回滚"

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
"${DEPLOY_DIR}/update.sh" \
  --deploy-dir "$DEPLOY_DIR" --source-dir "$PROJECT_ROOT" --no-pull --skip-start \
  > "${TEST_ROOT}/update.log" 2>&1
[[ "$(<"${DEPLOY_DIR}/VERSION")" == v0.7.0 ]] || fail "更新后版本错误"
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

"${DEPLOY_DIR}/uninstall.sh" --deploy-dir "$DEPLOY_DIR" --keep-data --yes \
  > "${TEST_ROOT}/uninstall-keep.log" 2>&1
[[ -f "${DEPLOY_DIR}/.env" && -f "${DEPLOY_DIR}/config/prompt.md" ]] || fail "保留卸载删除了配置"
[[ -d "${DEPLOY_DIR}/data" && -d "${DEPLOY_DIR}/knowledge" ]] || fail "保留卸载删除了数据"
[[ ! -e "${DEPLOY_DIR}/manage.sh" && ! -d "${DEPLOY_DIR}/scripts" ]] || fail "保留卸载未移除程序"
grep -Fq 'state=uninstalled-data-kept' "${DEPLOY_DIR}/.crisp-ai-installation" || fail "卸载状态标记错误"
pass "保留数据卸载"

"${FAILURE_DEPLOY_DIR}/uninstall.sh" \
  --deploy-dir "$FAILURE_DEPLOY_DIR" --purge --no-backup --yes \
  > "${TEST_ROOT}/uninstall-purge.log" 2>&1
[[ ! -e "$FAILURE_DEPLOY_DIR" ]] || fail "彻底卸载未删除部署目录"
pass "彻底卸载"

printf '\n测试完成：通过 %d，跳过 %d，失败 0。\n' "$PASSED" "$SKIPPED"
