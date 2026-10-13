#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
ORIGINAL_PATH=$PATH

# 读取生产安装器的实际表达式；合法 false 不应触发 set -e，非法类型仍拒绝。
python3 - "$PROJECT_ROOT/install.sh" <<'PY'
import json
from pathlib import Path
import re
import subprocess
import sys

source = Path(sys.argv[1]).read_text()
match = re.search(r'''AI_SUPPORTS_VISION=\$\(jq -er '([^']+)' "\$WIZARD_RESULT"\)''', source)
if match is None:
    raise SystemExit("缺少交互安装的图片能力读取")
expression = match.group(1)
for value in (True, False, None, "false", 0, [], {}):
    result = subprocess.run(
        ["jq", "-er", expression],
        input=json.dumps({"provider": {"capabilities": {"vision": value}}}).encode(),
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5,
    )
    if type(value) is bool:
        if result.returncode != 0 or result.stdout.strip() != str(value).lower().encode():
            raise SystemExit("合法布尔能力未原样读出")
    elif result.returncode == 0:
        raise SystemExit("图片能力错误类型未拒绝")
print("通过：[UNIT/CONTRACT] 交互安装接受 true/false，拒绝非布尔能力类型")
PY
if [[ "${AI_SUPPORT_INSTALL_VISION_CONTRACT_ONLY:-0}" == 1 ]]; then
  exit 0
fi

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
export MOCK_DOCKER_RAG_DEPLOY="$DEPLOY"
COMMAND="${WORK}/bin/crispai"
POOL_SOURCE="${DEPLOY}/config/provider-pool.yaml"
POOL_APPLIED="${DEPLOY}/config/provider-pool-applied.json"
POOL_READBACK="${DEPLOY}/config/provider-pool-readback.json"

assert_provider_readback_current() {
  local pool_hash revision secret_generation
  [[ -f "$POOL_READBACK" && ! -L "$POOL_READBACK" ]] \
    || fail 'Provider 推理准入回读缺失或不安全'
  pool_hash=$(digest "$POOL_APPLIED")
  revision=$(jq -er '.revision | select(type == "number" and floor == .)' "$POOL_APPLIED") \
    || fail '接口池 revision 无效'
  secret_generation=$(jq -er '.secrets_generation | select(type == "string" and length > 0)' "$POOL_APPLIED") \
    || fail '接口池秘密代次无效'
  jq -e --arg pool_hash "$pool_hash" --argjson revision "$revision" \
    --arg secret_generation "$secret_generation" '
      (keys | sort) == ["pool_sha256","readback_contract_version","revision","schema_version","secrets_generation","verified_at"]
      and .schema_version == 1
      and .readback_contract_version == 1
      and .revision == $revision
      and .secrets_generation == $secret_generation
      and .pool_sha256 == $pool_hash
      and (.verified_at | type == "number")
      and .verified_at > 0
    ' "$POOL_READBACK" >/dev/null \
    || fail 'Provider 推理准入回读未绑定当前接口池、秘密代次和完整文件摘要'
}

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
if grep -Eq '(^| )(pull|up|stop|restart)( |$)' "$MOCK_DOCKER_LOG"; then
  fail '首次 --skip-start 触发了镜像拉取或 Docker/Caddy 运行态变更'
fi
[[ -f "${DEPLOY}/config/provider-pool-applied.json" ]] \
  || fail 'staged 部署缺少有效接口池投影'
cmp -s -- "${PROJECT_ROOT}/config/vision-probe.json" "${DEPLOY}/config/vision-probe.json" \
  || fail 'staged 部署没有复制同版视觉探测资源'
[[ ! -e "$POOL_READBACK" && ! -L "$POOL_READBACK" ]] \
  || fail '首次 --skip-start 在组件启动前错误生成了 Provider 运行回读'
install -m 0600 -- "${DEPLOY}/.env" "${WORK}/staged.env"
provider_before=$(digest "${DEPLOY}/config/provider.yaml")
pool_before=$(digest "${DEPLOY}/config/provider-pool-applied.json")
generation=$(jq -er '.secrets_generation' "${DEPLOY}/config/provider-pool-applied.json") \
  || fail 'staged 接口池缺少秘密代次'
secret_before=$(digest "${DEPLOY}/secrets/provider/generations/${generation}.json")
adapter_key_before=$(sed -n 's/^PROVIDER_ADAPTER_KEY=//p' "${DEPLOY}/.env")
[[ -n "$adapter_key_before" ]] || fail 'staged 部署缺少内部 Provider 认证'

# 复用首个真实暂存夹具，定向验证本次新增恢复责任，不跑其余完整旧套件。
if [[ "${AI_SUPPORT_INSTALL_RECOVERY_ONLY:-0}" == 1 ]]; then
  for recovery_state in staged installing; do
    bash -c 'source "$1/scripts/common.sh"; write_installation_marker "$2" "$1" "$(<"$1/VERSION")" "$3"' \
      -- "$PROJECT_ROOT" "$DEPLOY" "$recovery_state"
    install -m 0600 -- "$DEPLOY/.crisp-ai-installation" "$WORK/recovery-before.marker"
    recovery_status=0
    printf '0\n' | "$PROJECT_ROOT/install.sh" --deploy-dir "$DEPLOY" --command-path "$COMMAND" --skip-start \
      > "$WORK/recovery-${recovery_state}.log" 2>&1 || recovery_status=$?
    (( recovery_status != 0 )) || fail '选择取消仍继续安装'
    grep -Fq '1 使用现有配置 / 2 重新配置 / 0 取消' "$WORK/recovery-${recovery_state}.log" \
      || fail '未完成安装没有提供明确的编辑与取消入口'
    cmp -s -- "$WORK/recovery-before.marker" "$DEPLOY/.crisp-ai-installation" \
      || fail '取消改变了安装状态'
    cmp -s -- "$WORK/staged.env" "$DEPLOY/.env" || fail '取消改变了环境'
    [[ "$(digest "$POOL_APPLIED")" == "$pool_before" ]] || fail '取消改变了接口池'
  done
  printf '通过：[UNIT/CONTRACT] staged/installing 两种未完成状态可明确取消，配置、接口池和状态保持。\n'
  printf 'v1.3.0\n' > "$DEPLOY/VERSION"
  bash -c 'source "$1/scripts/common.sh"; write_installation_marker "$2" "$1" v1.3.0 installing' -- "$PROJECT_ROOT" "$DEPLOY"
  recovery_status=0
  "$PROJECT_ROOT/install.sh" --deploy-dir "$DEPLOY" --command-path "$COMMAND" --non-interactive --skip-start \
    > "$WORK/recovery-unconfirmed-version.log" 2>&1 || recovery_status=$?
  (( recovery_status != 0 )) || fail '未明确选择跨版续装就修改旧版本'
  [[ "$(<"$DEPLOY/VERSION")" == v1.3.0 ]] || fail '拒绝跨版前已覆盖旧程序版本'
  "$PROJECT_ROOT/install.sh" --deploy-dir "$DEPLOY" --command-path "$COMMAND" --non-interactive --skip-start --resume-upgrade \
    > "$WORK/recovery-version-applied.log" 2>&1
  [[ "$(<"$DEPLOY/VERSION")" == "$(<"$PROJECT_ROOT/VERSION")" ]] || fail '明确跨版恢复没有复制新程序'
  cmp -s -- "$WORK/staged.env" "$DEPLOY/.env" || fail '明确跨版续装破坏了原环境'
  printf '通过：[UNIT/CONTRACT] 实际安装器拒绝未授权跨版，明确resume-upgrade可恢复未完成实例并保留环境。\n'
  bash -c '
    set -euo pipefail
    source "$1/scripts/common.sh"
    source "$1/scripts/wizard.sh"
    wizard_defaults_from_installation "$2" "$2/tmp/quick-init.json"
    WIZARD_EDIT_CONFIRMED=1
    printf "3\n0\n1200\n65535\n1\n" | quick_init_wizard "$2/tmp/quick-init.json"
  ' -- "$PROJECT_ROOT" "$DEPLOY" > "$WORK/recovery-window.log" 2>&1
  jq -e '.provider.context_window==65535 and .provider.max_output_tokens==1200' \
    "$DEPLOY/tmp/quick-init.json" >/dev/null || fail '返回修改没有保存合法模型窗口'
  grep -Fq '上下文须为' "$WORK/recovery-window.log" || fail '错误容量未被拒绝'
  cmp -s -- "$WORK/staged.env" "$DEPLOY/.env" || fail '尚未确认安装就改动了有效环境'
  printf '通过：[UNIT/CONTRACT] 从已部署配置回填并修改窗口，非法值拒绝，确认前不改变有效配置。\n'
  recovery_status=0
  printf '2\n1\n' | "$PROJECT_ROOT/install.sh" --deploy-dir "$DEPLOY" --command-path "$COMMAND" \
    > "$WORK/recovery-applied.log" 2>&1 || recovery_status=$?
  if (( recovery_status != 2 )); then
    tail -n 60 "$WORK/recovery-applied.log" >&2
    fail "重新配置后应完成本地安装，实际退出 ${recovery_status}"
  fi
  [[ -x "$COMMAND" ]] || fail '恢复后管理命令不存在'
  jq -e '.primary_id as $id | .entries[]|select(.id==$id)|.context_window==65535 and .max_output_tokens==1200' \
    "$POOL_APPLIED" >/dev/null || fail '上下文没有真正进入原主接口'
  bash -c '
    set -euo pipefail
    source "$1/scripts/common.sh"
    [[ "$(env_get "$2/.env" AI_MODEL_TOKEN_LIMIT)" == 65535 ]]
    [[ "$(env_get "$2/.env" PROVIDER_RAG_CONTEXT_WINDOW)" == 64335 ]]
    for key in ANYTHINGLLM_API_KEY N8N_ENCRYPTION_KEY POSTGRES_PASSWORD CRISP_TOKEN_IDENTIFIER CRISP_TOKEN_KEY; do
      [[ "$(env_get "$2/.env" "$key")" == "$(env_get "$3/staged.env" "$key")" ]]
    done
  ' -- "$PROJECT_ROOT" "$DEPLOY" "$WORK" || fail '窗口投影不一致或重配置覆盖了内部凭据'
  assert_provider_readback_current
  printf '通过：[UNIT/CONTRACT] 实际安装入口修改65535，原主接口/环境/RAG回读一致，内部和Crisp凭据保留，管理入口可用。\n'
  # 只注入组件应用故障；真实 Manager.commit 创建恢复记录，恢复时不替换该模块。
  python3 - "$DEPLOY" <<'PY_RECOVERY'
import importlib.util, json, pathlib, sys
root = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("pool", root / "scripts/provider-pool.py")
module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
manager = module.Manager(str(root))
value, secret = manager.load(); revision = value["revision"]
value["entries"][0]["context_window"] += 1
def unavailable(_window):
    raise module.PoolError("rag_context_apply_failed", "合成组件故障，仅用于事务恢复测试")
manager.apply_rag_window = unavailable
try:
    manager.commit(value, secret, revision)
except module.PoolError as error:
    assert error.code == "rag_context_restore_failed", error.code
else:
    raise AssertionError("故障注入未进入持久恢复路径")
record = json.loads((root / "config/provider-pool-transaction.json").read_text())
assert record["phase"] == "restore_failed"
PY_RECOVERY
  bash -c 'source "$1/scripts/common.sh"; write_installation_marker "$2" "$1" "$(<"$1/VERSION")" installing' -- "$PROJECT_ROOT" "$DEPLOY"
  recovery_status=0
  "$PROJECT_ROOT/install.sh" --deploy-dir "$DEPLOY" --command-path "$COMMAND" --non-interactive \
    > "$WORK/recovery-residue.log" 2>&1 || recovery_status=$?
  if (( recovery_status != 2 )); then
    tail -n 60 "$WORK/recovery-residue.log" >&2
    fail '安装入口没有从原窗口事务恢复后完成续装'
  fi
  [[ ! -e "$DEPLOY/config/provider-pool-transaction.json" ]] || fail '恢复后事务仍未结算'
  assert_provider_readback_current
  jq -e '.entries[0].context_window==65535' "$POOL_APPLIED" >/dev/null || fail '恢复采用了失败的新候选'
  printf '通过：[UNIT/CONTRACT] 真实失败事务保留原代，原安装入口成套恢复并回读后继续，不清空配置掩盖冲突。\n'
  exit 0
fi

# 使用完整生产校验函数检查原生内部密钥的恢复范围，不替换读取或校验逻辑。
PRESERVED_VALIDATOR=$(sed -n '/^validate_preserved_installation() {$/,/^installation_config_is_reusable() {$/p' \
  "$PROJECT_ROOT/install.sh" | sed '$d')
[[ -n "$PRESERVED_VALIDATOR" ]] || fail '缺少生产保留配置校验'
install -m 0600 -- "${DEPLOY}/.crisp-ai-installation" "${WORK}/staged.marker"
pending_cases=0
assert_pending_key_case() {
  local label=$1 state=$2 key=$3 value=$4 expected=$5 status=0 before after
  install -m 0600 -- "${WORK}/staged.env" "${DEPLOY}/.env"
  bash -c '
    set -euo pipefail
    source "$1/scripts/common.sh"
    if [[ "$3" == ANYTHINGLLM_API_KEY && -z "$4" ]]; then
      # 故障输入只写入隔离夹具；正常 env_set 应继续拒绝空密钥。
      sed -i 's/^ANYTHINGLLM_API_KEY=.*/ANYTHINGLLM_API_KEY=/' "$2/.env"
    else
      env_set "$2/.env" "$3" "$4"
    fi
    write_installation_marker "$2" "$1" "$5" "$6"
  ' -- "$PROJECT_ROOT" "$DEPLOY" "$key" "$value" "$(<"${PROJECT_ROOT}/VERSION")" "$state"
  before=$(sha256sum -- "${DEPLOY}/.env" "${DEPLOY}/.crisp-ai-installation")
  bash -c '
    set -euo pipefail
    source "$1/scripts/common.sh"
    source "$1/scripts/configuration.sh"
    eval "$3"
    validate_preserved_installation "$2"
  ' -- "$PROJECT_ROOT" "$DEPLOY" "$PRESERVED_VALIDATOR" \
    > "${WORK}/pending-${label}.log" 2>&1 || status=$?
  if [[ "$expected" == accepted ]]; then
    (( status == 0 )) || fail "合法保留配置被拒绝：${label}"
  else
    (( status != 0 )) || fail "无效保留配置未拒绝：${label}"
    grep -Fq -- ".env:${key}" "${WORK}/pending-${label}.log" \
      || fail "未按实际无效字段拒绝：${label}"
  fi
  after=$(sha256sum -- "${DEPLOY}/.env" "${DEPLOY}/.crisp-ai-installation")
  [[ "$after" == "$before" ]] || fail "只读恢复校验改写保存配置：${label}"
  pending_cases=$((pending_cases + 1))
}
for pending_state in installing staged; do
  assert_pending_key_case "$pending_state" "$pending_state" \
    ANYTHINGLLM_API_KEY pending-anythingllm-api-key accepted
done
for pending_state in ready local-ready collecting uninstalled-data-kept; do
  assert_pending_key_case "$pending_state" "$pending_state" \
    ANYTHINGLLM_API_KEY pending-anythingllm-api-key rejected
done
assert_pending_key_case empty staged ANYTHINGLLM_API_KEY '' rejected
assert_pending_key_case different-placeholder staged ANYTHINGLLM_API_KEY pending-other-key rejected
assert_pending_key_case provider staged AI_API_KEY pending-provider-key rejected
assert_pending_key_case crisp staged CRISP_TOKEN_KEY pending-crisp-key rejected
assert_pending_key_case saved-key-staged staged ANYTHINGLLM_API_KEY synthetic-resume-anything-key accepted
assert_pending_key_case saved-key-ready ready ANYTHINGLLM_API_KEY synthetic-resume-anything-key accepted
install -m 0600 -- "${WORK}/staged.env" "${DEPLOY}/.env"
install -m 0600 -- "${WORK}/staged.marker" "${DEPLOY}/.crisp-ai-installation"
[[ "$pending_cases" == 12 ]] || fail '内部密钥恢复边界未完整执行'
printf '通过：[UNIT/CONTRACT] 内部待生成密钥仅允许未启动阶段恢复，12项边界及只读配置保持。\n'
if [[ "${AI_SUPPORT_INSTALL_PENDING_CONTRACT_ONLY:-0}" == 1 ]]; then
  exit 0
fi

# 先真实捕获缺省模型投影；该正常初始化只能添加两个元数据字段。
install -m 0600 -- "${DEPLOY}/.env" "${WORK}/pull-before-capture.env"
if grep -Eq '^KNOWLEDGE_(ACTIVE_)?EMBEDDING_MODEL=' "${WORK}/pull-before-capture.env"; then
  fail '模型初始化反例的前提应为尚未捕获的 staged 配置'
fi
bash "${DEPLOY}/scripts/knowledge-profile.sh" --deploy-dir "$DEPLOY" capture \
  > "${WORK}/pull-model-capture.log" 2>&1
[[ "$(sed '/^KNOWLEDGE_\(ACTIVE_\)\{0,1\}EMBEDDING_MODEL=/d' "${DEPLOY}/.env")" \
  == "$(<"${WORK}/pull-before-capture.env")" ]] \
  || fail '模型元数据初始化改变了原有环境字段'
[[ "$(grep -Ec '^KNOWLEDGE_(ACTIVE_)?EMBEDDING_MODEL=' "${DEPLOY}/.env")" == 2 ]] \
  || fail '模型元数据初始化没有仅添加完整的两个字段'
pull_env_before=$(digest "${DEPLOY}/.env")
bash "${DEPLOY}/scripts/knowledge-profile.sh" --deploy-dir "$DEPLOY" capture \
  > "${WORK}/pull-model-capture-repeat.log" 2>&1
[[ "$(digest "${DEPLOY}/.env")" == "$pull_env_before" ]] \
  || fail '模型元数据捕获不幂等'

# 拉取失败必须止于启动前，并通过同一入口保留完整配置继续暂存。
: > "$MOCK_DOCKER_LOG"
pull_failure_status=0
MOCK_DOCKER_FAIL_PULL=1 "$PROJECT_ROOT/install.sh" --deploy-dir "$DEPLOY" --command-path "$COMMAND" \
  --non-interactive > "${WORK}/pull-failure.log" 2>&1 || pull_failure_status=$?
(( pull_failure_status != 0 )) || fail '镜像拉取失败被错误标为安装成功'
grep -Fq '安装所需镜像拉取失败；未启动新服务，安装进度已保留' "${WORK}/pull-failure.log" \
  || fail '镜像拉取失败没有明确说明启动阶段'
grep -Eq ' --parallel 1 pull --policy missing$' "$MOCK_DOCKER_LOG" \
  || fail '安装器没有按缺失镜像策略串行预拉取'
if grep -E '(^| )(up|stop|restart)( |$)' "$MOCK_DOCKER_LOG" \
  | grep -Ev '(^| )(--help|-h)( |$)'; then
  fail '镜像拉取失败后仍然改变了服务运行态'
fi
grep -Fxq 'state=installing' "${DEPLOY}/.crisp-ai-installation" \
  || fail '镜像拉取失败没有保留可恢复 installing'
[[ "$(digest "${DEPLOY}/.env")" == "$pull_env_before" \
  && "$(digest "$POOL_APPLIED")" == "$pool_before" \
  && "$(digest "${DEPLOY}/secrets/provider/generations/${generation}.json")" == "$secret_before" ]] \
  || fail '镜像拉取失败改变了原配置或接口池秘密'
: > "$MOCK_DOCKER_LOG"
"$PROJECT_ROOT/install.sh" --deploy-dir "$DEPLOY" --command-path "$COMMAND" \
  --non-interactive --skip-start > "${WORK}/pull-failure-stage.log" 2>&1
grep -Fxq 'state=staged' "${DEPLOY}/.crisp-ai-installation" \
  || fail '镜像拉取失败后同版无凭据继续未恢复 staged'
! grep -Eq '(^| )(pull|up|stop|restart)( |$)' "$MOCK_DOCKER_LOG" \
  || fail '镜像拉取失败后的仅暂存仍触碰镜像或服务'
[[ "$(digest "${DEPLOY}/.env")" == "$pull_env_before" \
  && "$(digest "$POOL_APPLIED")" == "$pool_before" \
  && "$(digest "${DEPLOY}/secrets/provider/generations/${generation}.json")" == "$secret_before" ]] \
  || fail '镜像拉取失败后继续暂存未保留原配置和秘密'
printf '通过：[UNIT/CONTRACT] 串行预拉取失败不启动服务，未完成安装可保留配置继续。\n'

: > "$MOCK_DOCKER_LOG"
resume_status=0
"$PROJECT_ROOT/install.sh" --deploy-dir "$DEPLOY" --command-path "$COMMAND" \
  --non-interactive > "${WORK}/resume.log" 2>&1 || resume_status=$?
(( resume_status == 2 )) \
  || fail "staged 无凭据续装应完成 local-ready，实际退出 ${resume_status}"
pull_line=$(grep -nE ' --parallel 1 pull --policy missing$' "$MOCK_DOCKER_LOG" | head -n 1 | cut -d: -f1)
up_line=$(grep -nE ' up -d --remove-orphans$' "$MOCK_DOCKER_LOG" | head -n 1 | cut -d: -f1)
if [[ -z "$pull_line" || -z "$up_line" ]] || (( pull_line >= up_line )); then
  fail '成功续装没有先串行预拉取再启动服务'
fi
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
assert_provider_readback_current
printf '通过：staged 部署无须重传十项配置即可继续启动，配置与秘密代次保持。\n'

assert_plain_running_skip_rejected() {
  local expected_state=$1 log=$2 secret_generation before after status=0
  local -a protected=(
    '.env'
    '.crisp-ai-installation'
    'config/provider.yaml'
    'config/provider-pool.yaml'
    'config/provider-pool-applied.json'
    'config/provider-pool-readback.json'
  )
  secret_generation=$(jq -er '.secrets_generation' "$POOL_APPLIED") \
    || fail "${expected_state} 保护检查无法读取秘密代次"
  protected+=("secrets/provider/generations/${secret_generation}.json")
  before=$(
    for relative in "${protected[@]}"; do
      [[ -f "${DEPLOY}/${relative}" && ! -L "${DEPLOY}/${relative}" ]] \
        || fail "${expected_state} 保护文件缺失或不安全：${relative}"
      printf '%s\t%s\t%s\n' "$relative" \
        "$(stat -c '%i:%s:%y:%z:%a' "${DEPLOY}/${relative}")" \
        "$(digest "${DEPLOY}/${relative}")"
    done
  )
  : > "$MOCK_DOCKER_LOG"
  "$PROJECT_ROOT/install.sh" --deploy-dir "$DEPLOY" --command-path "$COMMAND" \
    --non-interactive --skip-start > "$log" 2>&1 || status=$?
  (( status != 0 )) || fail "${expected_state} 运行中实例错误接受了普通 --skip-start"
  grep -Fq -- '已运行实例不能使用 --skip-start' "$log" \
    || fail "${expected_state} 普通 --skip-start 的拒绝原因不明确"
  [[ ! -s "$MOCK_DOCKER_LOG" ]] \
    || fail "${expected_state} 普通 --skip-start 在拒绝前调用了 Docker/Caddy"
  after=$(
    for relative in "${protected[@]}"; do
      [[ -f "${DEPLOY}/${relative}" && ! -L "${DEPLOY}/${relative}" ]] \
        || fail "${expected_state} 拒绝后保护文件缺失或不安全：${relative}"
      printf '%s\t%s\t%s\n' "$relative" \
        "$(stat -c '%i:%s:%y:%z:%a' "${DEPLOY}/${relative}")" \
        "$(digest "${DEPLOY}/${relative}")"
    done
  )
  [[ "$after" == "$before" ]] \
    || fail "${expected_state} 普通 --skip-start 在拒绝前改写了配置、marker、接口池或回读"
  grep -Fxq "state=${expected_state}" "${DEPLOY}/.crisp-ai-installation" \
    || fail "${expected_state} 普通 --skip-start 改变了安装状态"
  assert_provider_readback_current
}

assert_plain_running_skip_rejected local-ready "${WORK}/local-ready-plain-skip.log"
install -m 0600 -- "${DEPLOY}/.crisp-ai-installation" "${WORK}/local-ready.marker"
sed -i 's/^state=.*/state=ready/' "${DEPLOY}/.crisp-ai-installation"
assert_plain_running_skip_rejected ready "${WORK}/ready-plain-skip.log"
install -m 0600 -- "${WORK}/local-ready.marker" "${DEPLOY}/.crisp-ai-installation"
assert_provider_readback_current
printf '通过：ready/local-ready 的普通 --skip-start 在任何受管配置或运行态写入前拒绝。\n'

# 重配置必须先完成 Webhook/Caddy 候选检查，再探测或提交 Provider。这里用
# copy_project_files 会保留、但 configure_webhook_access 会拒绝的可写 Caddyfile
# 制造失败；若把 Provider 调整到 Webhook 前，这个负例会观察到新接口代次。
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
