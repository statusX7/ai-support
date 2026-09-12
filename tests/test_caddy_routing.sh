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
  docker rm -f "$namespace-proxy" "$namespace-upstream" "$namespace-mounted" \
    "$namespace-domain" "$namespace-first" >/dev/null 2>&1 || true
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

# 真实单文件 bind inode 负例：仅 up 不等于原子更新的配置已进入旧容器。
mkdir -p -- "$work/deploy/config"
cp -- "$PROJECT_ROOT/tests/fixtures/caddy-order-v111.conf" "$work/deploy/config/Caddyfile"
cp -- "$PROJECT_ROOT/config/Caddyfile.example" "$work/deploy/config/Caddyfile.example"
# shellcheck disable=SC2016 # Caddy 占位符必须由容器运行时展开。
sed -i 's/{\$WEBHOOK_DOMAIN}/{\$CADDY_TEST_LISTEN}/g' \
  "$work/deploy/config/Caddyfile" "$work/deploy/config/Caddyfile.example"
printf 'WEBHOOK_ACCESS_MODE=managed_https\nWEBHOOK_DOMAIN=old-runtime.example.invalid\nCADDY_TEST_LISTEN=http://:8080\nCOMPOSE_PROFILES=managed-https\n' > "$work/deploy/.env"
cat > "$work/deploy/docker-compose.yml" <<EOF
name: $namespace
services:
  caddy:
    image: $caddy_image
    container_name: $namespace-mounted
    profiles: ["managed-https"]
    environment:
      WEBHOOK_DOMAIN: \${WEBHOOK_DOMAIN}
      CADDY_TEST_LISTEN: \${CADDY_TEST_LISTEN}
    ports: ["127.0.0.1::8080"]
    volumes: ["$work/deploy/config/Caddyfile:/etc/caddy/Caddyfile:ro"]
    networks: [fixture]
networks:
  fixture:
    external: true
    name: $namespace
EOF
# shellcheck source=scripts/common.sh
source "$PROJECT_ROOT/scripts/common.sh"

# 首次安装只提交已生成的安全候选；configure 阶段不能为验证而启动长期
# 运行的受管 Caddy，正式 up 前仍由安装器再次执行实际 validate。
first_deploy="$work/first-configure-deploy"
mkdir -p -- "$first_deploy/config" "$first_deploy/tmp"
install -m 0640 -- "$PROJECT_ROOT/config/Caddyfile.example" \
  "$first_deploy/config/Caddyfile.example"
cat > "$first_deploy/.env" <<EOF
DEPLOY_DIR=$first_deploy
N8N_PORT=5678
CADDY_IMAGE=$caddy_image
EOF
chmod 0600 "$first_deploy/.env"
cat > "$first_deploy/docker-compose.yml" <<EOF
name: ${namespace}-first
services:
  caddy:
    image: \${CADDY_IMAGE}
    container_name: $namespace-first
    profiles: ["managed-https"]
    environment:
      WEBHOOK_DOMAIN: \${WEBHOOK_DOMAIN}
    volumes:
      - type: bind
        source: \${DEPLOY_DIR}/config/Caddyfile
        target: /etc/caddy/Caddyfile
        read_only: true
EOF
configure_webhook_access "$first_deploy" managed_https \
  'https://first.example.invalid/' \
  'https://first.example.invalid/webhook/crisp-webhook' first.example.invalid
[[ "$(env_get "$first_deploy/.env" WEBHOOK_ACCESS_MODE)" == managed_https ]]
[[ -f "$first_deploy/config/Caddyfile" \
  && -f "$first_deploy/config/crispai-nginx.conf" \
  && -f "$first_deploy/config/crispai-caddy.conf" ]]
if docker inspect "$namespace-first" >/dev/null 2>&1; then
  printf '失败：首次 Webhook 候选配置阶段误启动了长期运行的 Caddy。\n' >&2
  exit 1
fi
printf '通过 REAL-LOCAL：首次配置完整提交候选文件但不提前启动受管 Caddy。\n'

# Caddyfile 未变化也不能只凭文件摘要判运行代一致：容器创建时取得的
# WEBHOOK_DOMAIN 必须与当前 .env 精确一致，否则域名修改会被假判已应用。
domain_deploy="$work/domain-generation-deploy"
mkdir -p -- "$domain_deploy/config"
cat > "$domain_deploy/config/Caddyfile" <<'EOF'
{
  admin off
}
http://:8080 {
  respond 204
}
EOF
chmod 0640 "$domain_deploy/config/Caddyfile"
cat > "$domain_deploy/.env" <<'EOF'
WEBHOOK_ACCESS_MODE=managed_https
WEBHOOK_DOMAIN=old-generation.example.invalid
COMPOSE_PROFILES=managed-https
EOF
chmod 0600 "$domain_deploy/.env"
cat > "$domain_deploy/docker-compose.yml" <<EOF
name: ${namespace}-domain
services:
  caddy:
    image: $caddy_image
    container_name: $namespace-domain
    profiles: ["managed-https"]
    environment:
      WEBHOOK_DOMAIN: \${WEBHOOK_DOMAIN}
    volumes: ["$domain_deploy/config/Caddyfile:/etc/caddy/Caddyfile:ro"]
EOF
docker_compose "$domain_deploy" --profile managed-https up -d caddy >/dev/null
caddy_wait_for_runtime_match "$domain_deploy"
domain_old_container=$(docker inspect --format '{{.Id}}' "$namespace-domain")
env_set "$domain_deploy/.env" WEBHOOK_DOMAIN new-generation.example.invalid
if caddy_runtime_matches_configuration "$domain_deploy"; then
  printf '失败：Caddyfile 相同但容器 WEBHOOK_DOMAIN 仍为旧值时被假判已应用。\n' >&2
  exit 1
fi
reconcile_caddy_runtime "$domain_deploy"
domain_new_container=$(docker inspect --format '{{.Id}}' "$namespace-domain")
[[ "$domain_new_container" != "$domain_old_container" ]] \
  || { printf '失败：WEBHOOK_DOMAIN 代次变化未重建受管 Caddy。\n' >&2; exit 1; }
docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$namespace-domain" \
  | grep -Fxq 'WEBHOOK_DOMAIN=new-generation.example.invalid'
caddy_runtime_matches_configuration "$domain_deploy"
docker rm -f "$namespace-domain" >/dev/null
printf '通过 REAL-LOCAL：同 Caddyfile 的域名代次偏离会被识别，并重建到当前 env。\n'

# 安装文件复制与缺省初始化只能更新模板，不能覆盖管理员已有的实际配置。
preserve_deploy="$work/preserve-deploy"
mkdir -p -- "$preserve_deploy/config"
printf '{\n  admin off\n}\n\ncustom.example.invalid { respond 204 }\n' \
  > "$preserve_deploy/config/Caddyfile"
printf '管理员已有提示词，不得被安装模板覆盖。\n' > "$preserve_deploy/config/prompt.md"
chmod 0640 "$preserve_deploy/config/Caddyfile" "$preserve_deploy/config/prompt.md"
preserved_caddy_sha=$(sha256sum "$preserve_deploy/config/Caddyfile"); preserved_caddy_sha=${preserved_caddy_sha%% *}
preserved_prompt_sha=$(sha256sum "$preserve_deploy/config/prompt.md"); preserved_prompt_sha=${preserved_prompt_sha%% *}
copy_project_files "$PROJECT_ROOT" "$preserve_deploy"
initialize_config_files "$preserve_deploy"
current_caddy_sha=$(sha256sum "$preserve_deploy/config/Caddyfile"); current_caddy_sha=${current_caddy_sha%% *}
current_prompt_sha=$(sha256sum "$preserve_deploy/config/prompt.md"); current_prompt_sha=${current_prompt_sha%% *}
[[ "$current_caddy_sha" == "$preserved_caddy_sha" && "$current_prompt_sha" == "$preserved_prompt_sha" ]] \
  || { printf '失败：安装复制/初始化覆盖了旧有效实际配置。\n' >&2; exit 1; }
printf '通过 UNIT/CONTRACT：安装复制与初始化保留管理员已有 Caddy/Prompt 实际配置。\n'

# 首次 up 之前必须拒绝坏配置，且不能创建待修容器。
printf '{ deliberately_invalid_directive }\n' > "$work/invalid-caddy"
install -m 0640 -- "$work/invalid-caddy" "$work/deploy/config/Caddyfile"
if validate_managed_caddy_configuration "$work/deploy" > "$work/first-validate" 2>&1; then
  printf '失败：首次 up 前接受了无效 Caddy 配置。\n' >&2; exit 1
fi
if docker inspect "$namespace-mounted" >/dev/null 2>&1; then
  printf '失败：首次配置预检失败后仍创建了 Caddy 容器。\n' >&2; exit 1
fi
# shellcheck disable=SC2016 # Caddy 占位符必须由容器运行时展开。
sed 's/{\$WEBHOOK_DOMAIN}/{\$CADDY_TEST_LISTEN}/g' \
  "$PROJECT_ROOT/tests/fixtures/caddy-order-v111.conf" > "$work/valid-caddy-generation"
install -m 0640 -- "$work/valid-caddy-generation" "$work/deploy/config/Caddyfile"
validate_managed_caddy_configuration "$work/deploy"
printf '通过 REAL-LOCAL：首次 up 前真实 validate 拒绝坏配置且未创建容器。\n'

docker_compose "$work/deploy" up -d >/dev/null
read_mounted_status() {
  local attempt
  port=$(docker port "$namespace-mounted" 8080/tcp | sed -n 's/^127\.0\.0\.1://p')
  [[ "$port" =~ ^[0-9]+$ ]]
  code=000
  for ((attempt=0; attempt<30; attempt++)); do
    code=$(curl -q -sS --connect-timeout 1 --max-time 2 -X POST -d '{}' \
      -o "$work/response" -w '%{http_code}' "http://127.0.0.1:$port/webhook/crisp-webhook" 2>/dev/null) || true
    [[ "$code" != 000 ]] && break
    sleep 1
  done
}
read_mounted_status
[[ "$code" == 404 ]]
# shellcheck disable=SC2016 # Caddy 占位符必须由容器运行时展开。
sed 's/{\$WEBHOOK_DOMAIN}/{\$CADDY_TEST_LISTEN}/g' \
  "$PROJECT_ROOT/config/Caddyfile.example" > "$work/current-template"
install -m 0640 -- "$work/current-template" "$work/deploy/config/Caddyfile"
docker_compose "$work/deploy" up -d >/dev/null
read_mounted_status
[[ "$code" == 404 ]] || { printf '失败：未复现单文件挂载仍使用旧配置。\n' >&2; exit 1; }
refresh_program_file_mounts "$work/deploy"
read_mounted_status
[[ "$code" == 401 && $(<"$work/response") == '{"accepted":false,"reason":"Webhook 校验失败"}' ]]
expected=$(sha256sum "$work/deploy/config/Caddyfile"); expected=${expected%% *}
actual=$(docker exec "$namespace-mounted" sha256sum /etc/caddy/Caddyfile); actual=${actual%% *}
[[ "$expected" == "$actual" ]]
[[ -f "$work/deploy/config/Caddyfile.last-good" && ! -L "$work/deploy/config/Caddyfile.last-good" ]]
cmp -s -- "$work/deploy/config/Caddyfile" "$work/deploy/config/Caddyfile.last-good"
printf '通过 REAL-LOCAL：复现旧 bind inode，生产刷新函数重建后加载新配置并恢复路由。\n'

original_container=$(docker inspect --format '{{.Id}}' "$namespace-mounted")
refresh_program_file_mounts "$work/deploy"
[[ "$(docker inspect --format '{{.Id}}' "$namespace-mounted")" == "$original_container" ]] \
  || { printf '失败：同配置重入无故重建了 Caddy。\n' >&2; exit 1; }
printf '通过 REAL-LOCAL：同版同配置重入回读运行代，不制造 Caddy 短停。\n'

# 无效候选必须同时保住旧服务并把宿主文件回滚到已验证代，避免项目重启后才暴雷。
install -m 0640 -- "$work/invalid-caddy" "$work/deploy/config/Caddyfile"
if refresh_program_file_mounts "$work/deploy" > "$work/invalid-result" 2>&1; then
  printf '失败：无效 Caddy 候选未被拒绝。\n' >&2; exit 1
fi
[[ "$(docker inspect --format '{{.Id}}' "$namespace-mounted")" == "$original_container" ]]
cmp -s -- "$work/deploy/config/Caddyfile" "$work/deploy/config/Caddyfile.last-good" \
  || { printf '失败：无效候选后宿主 Caddyfile 没有回滚。\n' >&2; exit 1; }
read_mounted_status
[[ "$code" == 401 ]]
printf '通过 REAL-LOCAL：候选语法错误时旧反代继续服务，宿主文件自动回滚到已验证代。\n'

# 合法改配使用 validate + 受管重建；admin off 下不依赖不可用的热 reload。
cp -- "$PROJECT_ROOT/config/Caddyfile.example" "$work/changed-caddy"
# shellcheck disable=SC2016 # Caddy 占位符必须由容器运行时展开。
sed -i 's/{\$WEBHOOK_DOMAIN}/{\$CADDY_TEST_LISTEN}/g' "$work/changed-caddy"
printf '\n# synthetic-valid-generation-one\n' >> "$work/changed-caddy"
install -m 0640 -- "$work/changed-caddy" "$work/deploy/config/Caddyfile"
refresh_program_file_mounts "$work/deploy"
changed_container=$(docker inspect --format '{{.Id}}' "$namespace-mounted")
[[ "$changed_container" != "$original_container" ]] \
  || { printf '失败：合法新配置未触发 Caddy 运行代切换。\n' >&2; exit 1; }
cmp -s -- "$work/deploy/config/Caddyfile" "$work/deploy/config/Caddyfile.last-good"
read_mounted_status
[[ "$code" == 401 ]]
printf '通过 REAL-LOCAL：合法改配经预检后切换运行代，admin off 生命周期不伪称热 reload。\n'

# 模拟切换命令失败：恢复 last-good 后重建旧代，但本次改配仍返回失败，不能假报成功。
mkdir -p -- "$work/mock-bin"
cat > "$work/mock-bin/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${MOCK_FAIL_CADDY_STOP:-0}" == 1 && " $* " == *' stop '* && " $* " == *' caddy '* ]]; then
  if [[ -n "${MOCK_CADDY_STOP_TRACE:-}" ]]; then
    args=("$@")
    env_file=''
    for ((i=0; i<${#args[@]}; i++)); do
      if [[ "${args[i]}" == --env-file && $((i + 1)) -lt ${#args[@]} ]]; then
        env_file=${args[i + 1]}
        break
      fi
    done
    sed -n 's/^WEBHOOK_ACCESS_MODE=//p' "$env_file" > "$MOCK_CADDY_STOP_TRACE"
  fi
  exit 42
fi
if [[ -n "${MOCK_FAIL_CADDY_RM_ONCE:-}" && " $* " == *' rm '* \
  && " $* " == *' caddy '* && ! -e "$MOCK_FAIL_CADDY_RM_ONCE" ]]; then
  : > "$MOCK_FAIL_CADDY_RM_ONCE"
  exit 42
fi
if [[ -n "${MOCK_FAIL_CADDY_UP_ONCE:-}" && " $* " == *' up '* \
  && " $* " == *' --force-recreate '* && " $* " == *' caddy '* \
  && ! -e "$MOCK_FAIL_CADDY_UP_ONCE" ]]; then
  : > "$MOCK_FAIL_CADDY_UP_ONCE"
  exit 42
fi
exec "${REAL_DOCKER:?}" "$@"
SH
cat > "$work/mock-bin/ss" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$work/mock-bin/mv" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
target=${!#}
if [[ -n "${MOCK_FAIL_MV_TARGET:-}" && "$target" == "$MOCK_FAIL_MV_TARGET" \
  && -n "${MOCK_FAIL_MV_ONCE:-}" && ! -e "$MOCK_FAIL_MV_ONCE" ]]; then
  : > "$MOCK_FAIL_MV_ONCE"
  exit 42
fi
exec "${REAL_MV:?}" "$@"
SH
chmod 0755 "$work/mock-bin/docker" "$work/mock-bin/ss" "$work/mock-bin/mv"
REAL_DOCKER=$(command -v docker)
REAL_MV=$(command -v mv)
cat > "$work/configure-driver.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/common.sh
source "${CADDY_TEST_PROJECT_ROOT:?}/scripts/common.sh"
configure_webhook_access "$@"
SH
chmod 0700 "$work/configure-driver.sh"
export REAL_DOCKER REAL_MV
export CADDY_TEST_PROJECT_ROOT="$PROJECT_ROOT"
cp -- "$PROJECT_ROOT/config/Caddyfile.example" "$work/failed-change"
# shellcheck disable=SC2016 # Caddy 占位符必须由容器运行时展开。
sed -i 's/{\$WEBHOOK_DOMAIN}/{\$CADDY_TEST_LISTEN}/g' "$work/failed-change"
printf '\n# synthetic-valid-generation-rejected\n' >> "$work/failed-change"
install -m 0640 -- "$work/failed-change" "$work/deploy/config/Caddyfile"
if PATH="$work/mock-bin:$PATH" MOCK_FAIL_CADDY_UP_ONCE="$work/up-failed-once" \
  refresh_program_file_mounts "$work/deploy" > "$work/failed-change.log" 2>&1; then
  printf '失败：Caddy 切换命令失败后误报成功。\n' >&2; exit 1
fi
cmp -s -- "$work/deploy/config/Caddyfile" "$work/deploy/config/Caddyfile.last-good" \
  || { printf '失败：Caddy 切换失败后未恢复 last-good。\n' >&2; exit 1; }
read_mounted_status
[[ "$code" == 401 ]]
printf '通过 REAL-LOCAL：运行代切换失败会恢复并重建 last-good，同时向调用方保留失败。\n'

# configure_webhook_access 自身必须在 managed_https 内修改域名后立即收敛
# 已运行的旧容器。仅修改 .env 而把对账留给后续调用，会让菜单成功返回时
# 容器仍持有旧 WEBHOOK_DOMAIN。
managed_before=$(docker inspect --format '{{.Id}}' "$namespace-mounted")
env PATH="$work/mock-bin:$PATH" bash "$work/configure-driver.sh" \
  "$work/deploy" managed_https \
  'https://managed-new.example.invalid/' \
  'https://managed-new.example.invalid/webhook/crisp-webhook' \
  managed-new.example.invalid
managed_after=$(docker inspect --format '{{.Id}}' "$namespace-mounted")
[[ "$managed_after" != "$managed_before" ]] \
  || { printf '失败：受管域名变化后 configure 未重建旧 Caddy 运行代。\n' >&2; exit 1; }
docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$namespace-mounted" \
  | grep -Fxq 'WEBHOOK_DOMAIN=managed-new.example.invalid'
caddy_runtime_matches_configuration "$work/deploy" \
  || { printf '失败：受管域名变化后的 Caddy 运行代回读不一致。\n' >&2; exit 1; }
read_mounted_status
[[ "$code" == 401 ]]
printf '通过 REAL-LOCAL：managed→managed 域名修改提交后立即对账旧运行代。\n'

# 项目 stop 后同一入口恢复受管 Caddy；随后重复执行不得再次重建。
docker_compose "$work/deploy" --profile managed-https stop caddy >/dev/null
[[ "$(docker inspect --format '{{.State.Running}}' "$namespace-mounted")" == false ]]
env PATH="$work/mock-bin:$PATH" bash "$work/configure-driver.sh" \
  "$work/deploy" managed_https \
  'https://managed-stopped.example.invalid/' \
  'https://managed-stopped.example.invalid/webhook/crisp-webhook' \
  managed-stopped.example.invalid
[[ "$(docker inspect --format '{{.State.Running}}' "$namespace-mounted")" == false ]] \
  || { printf '失败：原本停止的受管 Caddy 被配置步骤意外启动。\n' >&2; exit 1; }
[[ "$(env_get "$work/deploy/.env" WEBHOOK_DOMAIN)" == managed-stopped.example.invalid ]]
if caddy_runtime_matches_configuration "$work/deploy"; then
  printf '失败：停止的旧 Caddy 被错误标记为当前运行代。\n' >&2; exit 1
fi
printf '通过 REAL-LOCAL：原本停止的 managed→managed 配置只提交候选，不意外启动服务。\n'
reconcile_caddy_runtime "$work/deploy"
recovered_container=$(docker inspect --format '{{.Id}}' "$namespace-mounted")
[[ "$(docker inspect --format '{{.State.Running}}' "$namespace-mounted")" == true ]]
caddy_runtime_matches_configuration "$work/deploy" \
  || { printf '失败：stop 后恢复未通过 Caddy 文件绑定真实回读。\n' >&2; exit 1; }
cmp -s -- "$work/deploy/config/Caddyfile" "$work/deploy/config/Caddyfile.last-good" \
  || { printf '失败：stop 后恢复未记录 Caddy last-good。\n' >&2; exit 1; }
reconcile_caddy_runtime "$work/deploy"
[[ "$(docker inspect --format '{{.Id}}' "$namespace-mounted")" == "$recovered_container" ]]
read_mounted_status
[[ "$code" == 401 ]]
printf '通过 REAL-LOCAL：专项 reconcile 在 stop 后恢复并真实回读 Caddy/last-good，同配置重入保持运行代。\n'

# 模式切换必须先完整生成候选，再原子提交；.env 或任一反代片段提交失败时，
# 原配置、片段及正在运行的 Caddy 都保持，不能留下半套 external_proxy。
env_set "$work/deploy/.env" PUBLIC_WEBHOOK_URL 'https://support.example.invalid/'
env_set "$work/deploy/.env" WEBHOOK_PRODUCTION_URL \
  'https://support.example.invalid/webhook/crisp-webhook'
write_webhook_proxy_snippets "$work/deploy"
old_env_hash=$(sha256sum "$work/deploy/.env"); old_env_hash=${old_env_hash%% *}
old_nginx_hash=$(sha256sum "$work/deploy/config/crispai-nginx.conf"); old_nginx_hash=${old_nginx_hash%% *}
old_proxy_caddy_hash=$(sha256sum "$work/deploy/config/crispai-caddy.conf"); old_proxy_caddy_hash=${old_proxy_caddy_hash%% *}
if env PATH="$work/mock-bin:$PATH" MOCK_FAIL_MV_TARGET="$work/deploy/.env" \
  MOCK_FAIL_MV_ONCE="$work/env-move-failed" bash "$work/configure-driver.sh" \
  "$work/deploy" external_proxy 'https://proxy.example.invalid/team/' \
  'https://proxy.example.invalid/team/webhook/crisp-webhook' proxy.example.invalid; then
  printf '失败：.env 原子提交失败后仍报告外部反代切换成功。\n' >&2; exit 1
fi
[[ "$(sha256sum "$work/deploy/.env" | cut -d ' ' -f 1)" == "$old_env_hash" ]]
[[ "$(sha256sum "$work/deploy/config/crispai-nginx.conf" | cut -d ' ' -f 1)" == "$old_nginx_hash" ]]
[[ "$(sha256sum "$work/deploy/config/crispai-caddy.conf" | cut -d ' ' -f 1)" == "$old_proxy_caddy_hash" ]]
[[ "$(docker inspect --format '{{.State.Running}}' "$namespace-mounted")" == true ]]

if env PATH="$work/mock-bin:$PATH" \
  MOCK_FAIL_MV_TARGET="$work/deploy/config/crispai-caddy.conf" \
  MOCK_FAIL_MV_ONCE="$work/snippet-move-failed" bash "$work/configure-driver.sh" \
  "$work/deploy" external_proxy 'https://proxy.example.invalid/team/' \
  'https://proxy.example.invalid/team/webhook/crisp-webhook' proxy.example.invalid; then
  printf '失败：反代片段提交失败后仍报告外部反代切换成功。\n' >&2; exit 1
fi
[[ "$(sha256sum "$work/deploy/.env" | cut -d ' ' -f 1)" == "$old_env_hash" ]]
[[ "$(sha256sum "$work/deploy/config/crispai-nginx.conf" | cut -d ' ' -f 1)" == "$old_nginx_hash" ]]
[[ "$(sha256sum "$work/deploy/config/crispai-caddy.conf" | cut -d ' ' -f 1)" == "$old_proxy_caddy_hash" ]]
[[ "$(docker inspect --format '{{.State.Running}}' "$namespace-mounted")" == true ]]
printf '通过 REAL-LOCAL：环境或反代片段提交失败均回滚整套文件，且不会先停止受管 Caddy。\n'

# 退出受管模式时，停止动作只能发生在新 env/片段都提交后；停止失败必须
# 回滚三类文件并恢复旧运行代，不能假装已交给外部反代。
if env PATH="$work/mock-bin:$PATH" MOCK_FAIL_CADDY_STOP=1 \
  MOCK_CADDY_STOP_TRACE="$work/stop-mode" bash "$work/configure-driver.sh" "$work/deploy" \
  external_proxy 'https://proxy.example.invalid/team/' \
  'https://proxy.example.invalid/team/webhook/crisp-webhook' proxy.example.invalid; then
  printf '失败：Caddy 停止失败后仍提交 external_proxy。\n' >&2; exit 1
fi
[[ "$(<"$work/stop-mode")" == external_proxy ]]
[[ "$(env_get "$work/deploy/.env" WEBHOOK_ACCESS_MODE)" == managed_https ]]
[[ "$(docker inspect --format '{{.State.Running}}' "$namespace-mounted")" == true ]]
[[ "$(sha256sum "$work/deploy/config/crispai-nginx.conf" | cut -d ' ' -f 1)" == "$old_nginx_hash" ]]
[[ "$(sha256sum "$work/deploy/config/crispai-caddy.conf" | cut -d ' ' -f 1)" == "$old_proxy_caddy_hash" ]]

# 更深一层负例：stop 已真实成功、rm 随后失败时，也必须按旧 env 重新拉起
# 原受管代，而不是把服务留在 stopped。
if env PATH="$work/mock-bin:$PATH" MOCK_FAIL_CADDY_RM_ONCE="$work/rm-failed-once" \
  bash "$work/configure-driver.sh" "$work/deploy" external_proxy \
  'https://proxy.example.invalid/team/' \
  'https://proxy.example.invalid/team/webhook/crisp-webhook' proxy.example.invalid; then
  printf '失败：Caddy 已停但移除失败后仍报告外部反代切换成功。\n' >&2; exit 1
fi
[[ "$(env_get "$work/deploy/.env" WEBHOOK_ACCESS_MODE)" == managed_https ]]
[[ "$(docker inspect --format '{{.State.Running}}' "$namespace-mounted")" == true ]]
[[ "$(sha256sum "$work/deploy/config/crispai-nginx.conf" | cut -d ' ' -f 1)" == "$old_nginx_hash" ]]
[[ "$(sha256sum "$work/deploy/config/crispai-caddy.conf" | cut -d ' ' -f 1)" == "$old_proxy_caddy_hash" ]]
read_mounted_status
[[ "$code" == 401 ]]
printf '通过 REAL-LOCAL：停止后移除失败会恢复旧文件并重新拉起原受管 Caddy 代。\n'

configure_webhook_access "$work/deploy" external_proxy \
  'https://proxy.example.invalid/team/' \
  'https://proxy.example.invalid/team/webhook/crisp-webhook' proxy.example.invalid
[[ "$(env_get "$work/deploy/.env" WEBHOOK_ACCESS_MODE)" == external_proxy ]]
[[ -z "$(env_get "$work/deploy/.env" COMPOSE_PROFILES 2>/dev/null || true)" ]]
if docker inspect "$namespace-mounted" >/dev/null 2>&1; then
  printf '失败：切到外部反代后残留受管 Caddy。\n' >&2; exit 1
fi
[[ "$(docker inspect --format '{{.State.Running}}' "$namespace-upstream")" == true ]]

# 即使 .env 已是 external_proxy，异常遗留的本项目 Caddy 也要在生命周期刷新时收敛；外部容器不动。
docker_compose "$work/deploy" --profile managed-https up -d caddy >/dev/null
[[ "$(docker inspect --format '{{.State.Running}}' "$namespace-mounted")" == true ]]
refresh_program_file_mounts "$work/deploy"
if docker inspect "$namespace-mounted" >/dev/null 2>&1; then
  printf '失败：external_proxy 重入未清理本项目遗留 Caddy。\n' >&2; exit 1
fi
[[ "$(docker inspect --format '{{.State.Running}}' "$namespace-upstream")" == true ]]
printf '通过 REAL-LOCAL：受管/外部模式切换失败不误提交，成功后只收敛本项目 Caddy。\n'

# 从外部模式切回受管模式，重新生成 profile 并恢复服务。
env PATH="$work/mock-bin:$PATH" bash "$work/configure-driver.sh" \
  "$work/deploy" managed_https \
  'https://support.example.invalid/' \
  'https://support.example.invalid/webhook/crisp-webhook' support.example.invalid
[[ "$(env_get "$work/deploy/.env" WEBHOOK_ACCESS_MODE)" == managed_https ]]
[[ "$(env_get "$work/deploy/.env" COMPOSE_PROFILES)" == managed-https ]]
refresh_program_file_mounts "$work/deploy"
read_mounted_status
[[ "$code" == 401 ]]
printf '通过 REAL-LOCAL：外部反代可显式切回受管 Caddy，并重新通过路由回读。\n'

# 未知模式不得以空操作返回成功，也不得停止当前仍正常的本项目 Caddy。
env_set "$work/deploy/.env" WEBHOOK_ACCESS_MODE invalid_mode
if reconcile_caddy_runtime "$work/deploy" >"$work/invalid-mode.stdout" 2>"$work/invalid-mode.stderr"; then
  printf '失败：未知 Webhook 模式被 Caddy 对账当成成功。\n' >&2; exit 1
fi
grep -Fq '接入模式无效' "$work/invalid-mode.stderr"
[[ "$(docker inspect --format '{{.State.Running}}' "$namespace-mounted")" == true ]]
env_set "$work/deploy/.env" WEBHOOK_ACCESS_MODE managed_https
printf '通过 REAL-LOCAL：未知接入模式明确失败且不扰动当前 Caddy。\n'

# 上游失败真实写入 Caddy stderr 时也不能保留 query 或认证头。
docker stop "$namespace-upstream" >/dev/null
code=$(curl -q -sS --max-time 5 -X POST -d '{}' -H 'Authorization: Bearer synthetic-caddy-auth' \
  -o "$work/response" -w '%{http_code}' "http://127.0.0.1:$port/webhook/crisp-webhook?secret=synthetic-caddy-query")
[[ "$code" == 502 ]]
docker logs "$namespace-mounted" > "$work/container.log" 2>&1
if grep -Eq 'synthetic-caddy-(auth|query)' "$work/container.log"; then
  printf '失败：受管 Caddy 错误日志包含合成认证资料。\n' >&2; exit 1
fi
grep -Fq '[REDACTED]' "$work/container.log"
printf '通过 REAL-LOCAL：重建后真实 502 错误日志不含合成 URL Secret 或认证头。\n'
