#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
TEST_ROOT=$(mktemp -d "${PROJECT_ROOT}/.test-health-wait.XXXXXX")

cleanup() {
  rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT

mkdir -p -- "${TEST_ROOT}/deploy"
cat > "${TEST_ROOT}/deploy/.env" <<'EOF'
N8N_PORT=5678
ANYTHINGLLM_PORT=3001
LOCAL_HEALTH_TIMEOUT_SECONDS=2
LOCAL_HEALTH_INTERVAL_SECONDS=1
EOF

# shellcheck source=scripts/common.sh
source "${PROJECT_ROOT}/scripts/common.sh"

require_command() { :; }
docker_compose() {
  local _deploy_dir=$1
  shift
  if [[ "$*" == "ps --services --filter status=running" ]]; then
    printf '%s\n' postgres anythingllm n8n
  fi
}
curl() { return 1; }

WAIT_STARTED=$SECONDS
if wait_for_local_health "${TEST_ROOT}/deploy" >/dev/null 2>&1; then
  printf '%s\n' '失败：全部探测失败时健康等待不应成功' >&2
  exit 1
fi
WAIT_ELAPSED=$((SECONDS - WAIT_STARTED))
[[ $WAIT_ELAPSED -ge 2 && $WAIT_ELAPSED -le 4 ]] || {
  printf '失败：未遵守 .env 中的总秒数截止时间（实际 %s 秒）\n' "$WAIT_ELAPSED" >&2
  exit 1
}

CURL_COUNT=0
curl() { ((CURL_COUNT += 1)); return 0; }
wait_for_local_health "${TEST_ROOT}/deploy"
[[ $CURL_COUNT -eq 2 ]] || {
  printf '%s\n' '失败：服务就绪后未立即结束健康等待' >&2
  exit 1
}

printf '%s\n' '健康等待专项测试通过'
