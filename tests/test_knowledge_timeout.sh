#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
TEST_ROOT=$(mktemp -d "${PROJECT_ROOT}/.test-runtime.knowledge-timeout.XXXXXX")
DEPLOY_DIR="${TEST_ROOT}/deploy"
STATE_DIR="${TEST_ROOT}/state"
MOCK_BIN="${TEST_ROOT}/bin"
LOCATION='custom-documents/slow.md.json'

cleanup() {
  if [[ "${AI_SUPPORT_TEST_KEEP_TMP:-0}" == 1 ]]; then
    printf '调试目录已保留：%s\n' "$TEST_ROOT" >&2
    return
  fi
  if [[ "$TEST_ROOT" == "${PROJECT_ROOT}"/.test-runtime.knowledge-timeout.* && -d "$TEST_ROOT" ]]; then
    rm -rf -- "$TEST_ROOT"
  fi
}
trap cleanup EXIT

fail() {
  printf '失败：%s\n' "$1" >&2
  if [[ -f "${STATE_DIR}/request.log" ]]; then
    printf '%s\n' '--- AnythingLLM 请求时序（不含凭据）---' >&2
    sed -n '1,80p' "${STATE_DIR}/request.log" >&2
  fi
  exit 1
}

for command_name in bash curl jq sha256sum sed install; do
  command -v "$command_name" >/dev/null 2>&1 || fail "缺少测试依赖：${command_name}"
done
[[ -f "${PROJECT_ROOT}/scripts/common.sh" ]] || fail '缺少生产 scripts/common.sh'
[[ -x "${SCRIPT_DIR}/mocks/curl_knowledge_timeout" ]] \
  || fail 'AnythingLLM 超时测试桩不可执行'

mkdir -p -- "$MOCK_BIN" "$STATE_DIR" \
  "${DEPLOY_DIR}/knowledge" "${DEPLOY_DIR}/data" "${DEPLOY_DIR}/tmp"
install -m 0755 -- "${SCRIPT_DIR}/mocks/curl_knowledge_timeout" "${MOCK_BIN}/curl"
printf '%s\n' \
  'ANYTHINGLLM_API_KEY=test-only-anything-key' \
  'ANYTHINGLLM_WORKSPACE=crisp-support' \
  'ANYTHINGLLM_PORT=3001' > "${DEPLOY_DIR}/.env"
chmod 600 "${DEPLOY_DIR}/.env"
printf '# 延迟索引测试\n\n这是首次同步文档。\n' > "${DEPLOY_DIR}/knowledge/slow.md"

sync_status=0
# shellcheck disable=SC2016 # $1/$2 由 bash -c 的位置参数提供。
if env \
  PATH="${MOCK_BIN}:${PATH}" \
  MOCK_ANYTHING_TIMEOUT_STATE="$STATE_DIR" \
  MOCK_ANYTHING_COMMIT_DELAY=1.5 \
  bash -c '
    set -euo pipefail
    source "$1"
    knowledge_sync "$2"
  ' bash "${PROJECT_ROOT}/scripts/common.sh" "$DEPLOY_DIR" \
  > "${STATE_DIR}/sync.stdout" 2> "${STATE_DIR}/sync.stderr"; then
  sync_status=0
else
  sync_status=$?
fi

grep -Fxq 'upload' "${STATE_DIR}/request.log" \
  || fail '生产 knowledge_sync 未调用文档上传接口'
grep -Fxq 'update-accepted' "${STATE_DIR}/request.log" \
  || fail '生产 knowledge_sync 未调用 update-embeddings'

committed=0
for _attempt in {1..50}; do
  if [[ -e "${STATE_DIR}/server-committed" ]]; then
    committed=1
    break
  fi
  sleep 0.1
done
(( committed == 1 )) || fail '测试桩未完成服务端延迟提交，无法验证超时竞态'

if [[ -e "${STATE_DIR}/remove-called" ]]; then
  fail 'update-embeddings 客户端超时后调用了 remove-documents，可能清理服务端仍在处理的文档'
fi

manifest="${DEPLOY_DIR}/data/knowledge-manifest.json"
[[ -f "$manifest" ]] || fail 'knowledge_sync 未生成知识库清单'
jq -e --arg location "$LOCATION" \
  '((.garbage_locations // []) | index($location)) == null' "$manifest" >/dev/null \
  || fail '结果未知的文档被登记为待清理垃圾，下次同步仍可能误删'

if (( sync_status == 0 )); then
  jq -e --arg location "$LOCATION" \
    'any(.files[]?.locations[]?; . == $location)' "$manifest" >/dev/null \
    || fail '同步报告成功，但清单未记录服务端已提交的文档'
fi

printf '通过：update-embeddings 客户端超时且服务端延迟成功时未清理在处理文档\n'
