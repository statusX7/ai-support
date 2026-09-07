#!/usr/bin/env bash
set -euo pipefail

DEPLOY_REQUEST=${AI_SUPPORT_INTEGRATION_DEPLOY_DIR:-}
if [[ -z "$DEPLOY_REQUEST" ]]; then
  printf '跳过：未设置 AI_SUPPORT_INTEGRATION_DEPLOY_DIR，未执行真实部署集成检查。\n' >&2
  exit 77
fi
if ! command -v docker >/dev/null 2>&1 \
  || ! docker compose version >/dev/null 2>&1 \
  || ! docker info >/dev/null 2>&1; then
  printf '跳过：Docker Engine 或满足项目能力要求的 Docker Compose 插件不可用。\n' >&2
  exit 77
fi
command -v realpath >/dev/null 2>&1 || {
  printf '失败：缺少命令 realpath。\n' >&2
  exit 1
}
for required in curl jq mktemp; do
  command -v "$required" >/dev/null 2>&1 || {
    printf '失败：缺少命令 %s。\n' "$required" >&2
    exit 1
  }
done
command -v stat >/dev/null 2>&1 || {
  printf '失败：缺少命令 stat。\n' >&2
  exit 1
}

DEPLOY_DIR=$(realpath -e -- "$DEPLOY_REQUEST")
[[ -d "$DEPLOY_DIR" && ! -L "$DEPLOY_DIR" ]] || {
  printf '失败：真实部署目录无效。\n' >&2
  exit 1
}
[[ -f "${DEPLOY_DIR}/.crisp-ai-installation" && ! -L "${DEPLOY_DIR}/.crisp-ai-installation" ]] || {
  printf '失败：真实部署目录缺少安全的安装标记。\n' >&2
  exit 1
}
[[ "$(sed -n '1p' "${DEPLOY_DIR}/.crisp-ai-installation")" == "ai-support" ]] || {
  printf '失败：真实部署安装标记无效。\n' >&2
  exit 1
}
[[ -f "${DEPLOY_DIR}/.env" && ! -L "${DEPLOY_DIR}/.env" ]] || {
  printf '失败：真实部署缺少安全的 .env。\n' >&2
  exit 1
}
[[ "$(stat -c '%a' "${DEPLOY_DIR}/.env")" == 600 ]] || {
  printf '失败：真实部署 .env 权限不是 0600。\n' >&2
  exit 1
}
for runtime_dir in data/n8n data/anythingllm data/runtime; do
  [[ -d "${DEPLOY_DIR}/${runtime_dir}" && ! -L "${DEPLOY_DIR}/${runtime_dir}" ]] || {
    printf '失败：真实运行目录缺失或是符号链接：%s。\n' "$runtime_dir" >&2
    exit 1
  }
  [[ "$(stat -c '%u:%g' "${DEPLOY_DIR}/${runtime_dir}")" == "1000:1000" ]] || {
    printf '失败：真实运行目录属主错误：%s。\n' "$runtime_dir" >&2
    exit 1
  }
done

# shellcheck source=/dev/null
source "${DEPLOY_DIR}/scripts/common.sh"
assert_installation "$DEPLOY_DIR"
docker_compose "$DEPLOY_DIR" config --quiet
"${DEPLOY_DIR}/scripts/healthcheck.sh" --deploy-dir "$DEPLOY_DIR" --local

RUNNING=$(docker_compose "$DEPLOY_DIR" ps --services --filter status=running)
SERVICES=(postgres anythingllm n8n provider-adapter)
if [[ "$(env_get "${DEPLOY_DIR}/.env" WEBHOOK_ACCESS_MODE 2>/dev/null || true)" == managed_https ]]; then
  SERVICES+=(caddy)
fi
for service in "${SERVICES[@]}"; do
  grep -Fxq "$service" <<< "$RUNNING" || {
    printf '失败：真实容器未运行：%s\n' "$service" >&2
    exit 1
  }
done

# 使用错误 Secret 只验证生产 Webhook 已发布且拒绝伪造，不触发 AI 或 Crisp 回复。
N8N_PORT_VALUE=$(env_get "${DEPLOY_DIR}/.env" N8N_PORT 2>/dev/null || printf '5678')
[[ "$N8N_PORT_VALUE" =~ ^[0-9]{1,5}$ ]] || {
  printf '失败：N8N_PORT 格式无效。\n' >&2
  exit 1
}
PROBE_DIR=$(mktemp -d "${DEPLOY_DIR}/tmp/local-probe.XXXXXX")
chmod 700 "$PROBE_DIR"
cleanup() {
  [[ "$PROBE_DIR" == "${DEPLOY_DIR}/tmp/"local-probe.* && -d "$PROBE_DIR" ]] || return
  rm -f -- "$PROBE_DIR/response.json"
  rmdir -- "$PROBE_DIR"
}
trap cleanup EXIT
WEBHOOK_STATUS=$(curl -q --silent --output "$PROBE_DIR/response.json" --write-out '%{http_code}' \
  --connect-timeout 3 --max-time 15 \
  --request POST --header 'Content-Type: application/json' \
  --data '{"event":"message:send","website_id":"integration-invalid","data":{"session_id":"session_integration1234","from":"user","type":"text","content":"安全探针"}}' \
  "http://127.0.0.1:${N8N_PORT_VALUE}/webhook/crisp-webhook?key=integration-invalid-secret" \
  2>/dev/null || true)
[[ "$WEBHOOK_STATUS" == 401 ]] || {
  printf '失败：生产 Webhook 未发布或未拒绝伪造请求（HTTP %s）。\n' "${WEBHOOK_STATUS:-000}" >&2
  exit 1
}
jq -e 'type == "object" and .accepted == false and .reason == "Webhook 校验失败"' \
  "$PROBE_DIR/response.json" >/dev/null || {
  printf '失败：401 不是本项目生产 Code 的拒绝结构，不能证明工作流可执行。\n' >&2
  exit 1
}

printf '真实部署本地集成检查：通过（不代表 Crisp/Provider 外部端到端验收）\n'
