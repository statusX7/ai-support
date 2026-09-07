#!/usr/bin/env bash
set -euo pipefail
umask 077

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  printf '跳过：需要隔离 Docker daemon 执行真实 Caddy 路由回归。\n' >&2; exit 77;
fi
command -v curl >/dev/null 2>&1 || exit 77
work=$(mktemp -d "$PROJECT_ROOT/.test-caddy.XXXXXX")
namespace="crispai-caddy-regression-${BASHPID}"
caddy_image=${CRISPAI_TEST_CADDY_IMAGE:-caddy:2.10.2-alpine}
node_image=${CRISPAI_TEST_NODE_IMAGE:-docker.n8n.io/n8nio/n8n:2.33.0}
cleanup() {
  docker rm -f "$namespace-proxy" "$namespace-upstream" >/dev/null 2>&1 || true
  docker network rm "$namespace" >/dev/null 2>&1 || true
  [[ "$work" == "$PROJECT_ROOT"/.test-caddy.* && -d "$work" && ! -L "$work" ]] && find "$work" -depth -delete
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
docker network create "$namespace" >/dev/null
docker run -d --name "$namespace-upstream" --network "$namespace" --network-alias n8n \
  --entrypoint node "$node_image" -e 'require("http").createServer((q,s)=>{s.writeHead(401,{"Content-Type":"application/json"});s.end(JSON.stringify({accepted:false,reason:"Webhook 校验失败"}));}).listen(5678,"0.0.0.0")' >/dev/null
# 对固定旧模板作实际负例：不是根据文件里有无 handle 判定成功。
docker run --rm --entrypoint caddy "$caddy_image" version > "$work/version"
for template in tests/fixtures/caddy-order-v111.conf config/Caddyfile.example; do
  docker run -d --name "$namespace-proxy" --network "$namespace" -p 127.0.0.1::8080 \
    -e WEBHOOK_DOMAIN=http://:8080 -v "$PROJECT_ROOT/$template:/etc/caddy/Caddyfile:ro" \
    "$caddy_image" >/dev/null
  port=$(docker port "$namespace-proxy" 8080/tcp | sed -n 's/^127\.0\.0\.1://p')
  [[ "$port" =~ ^[0-9]+$ ]]
  code=000
  for ((attempt=0; attempt<30; attempt++)); do
    code=$(curl -q -sS --connect-timeout 1 --max-time 2 -X POST -d '{}' -o "$work/response" -w '%{http_code}' \
      "http://127.0.0.1:$port/webhook/crisp-webhook" 2>/dev/null) || true
    [[ "$code" != 000 ]] && break
    sleep 1
  done
  if [[ "$template" == tests/fixtures/caddy-order-v111.conf ]]; then
    [[ "$code" == 404 ]] || { printf '失败：未重现旧 Caddy 模板的 404 阻断。\n' >&2; exit 1; }
    docker rm -f "$namespace-proxy" >/dev/null
  fi
done
[[ "$code" == 401 ]] || { printf '失败：合法 Webhook 被反代拦截（HTTP %s）。\n' "$code" >&2; exit 1; }
[[ $(<"$work/response") == '{"accepted":false,"reason":"Webhook 校验失败"}' ]]
for route in crispai-public-config crispai-web-chat; do
  code=$(curl -q -sS --max-time 3 -o "$work/response" -w '%{http_code}' "http://127.0.0.1:$port/webhook/$route")
  [[ "$code" == 401 ]]
done
for route in / /api/v1 /webhook-test/crisp-webhook /webhook/crisp-webhook/unknown; do
  code=$(curl -q -sS --max-time 3 -o "$work/response" -w '%{http_code}' "http://127.0.0.1:$port$route")
  [[ "$code" == 404 ]]
done
printf '通过 REAL-LOCAL：真实 Caddy 三条受管路径到达上游，四条非受管路径保持 404。\n'
