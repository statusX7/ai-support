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
CURRENT_TEST_VERSION=$(<"${PROJECT_ROOT}/VERSION")
if (( RELEASE_MODE && EXTERNAL_PENDING_MODE )); then
  printf '失败：[STATIC] 发布验收不允许 External Validation Pending\n' >&2
  exit 1
fi
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

# 升级仅允许按真实接口池派生知识输入窗口；其他配置、凭据和注释逐字保留。
assert_update_env_preserved() {
  python3 -B - "$1" "$2" "$3" "$PROJECT_ROOT" <<'PY'
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import stat
import sys

previous, deploy, expected_digest, project = sys.argv[1:]
previous, deploy, project = Path(previous), Path(deploy), Path(project)

def raw(path):
    info = path.lstat()
    if path.is_symlink() or not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or not 0 < info.st_size <= 16777216:
        raise SystemExit('升级配置保留校验：文件身份无效')
    return path.read_bytes()

before, after = raw(previous), raw(deploy / '.env')
if hashlib.sha256(before).hexdigest() != expected_digest:
    raise SystemExit('升级配置保留校验：原始基线已变化')
module_path = project / 'scripts/provider-pool.py'
raw(module_path)
spec = importlib.util.spec_from_file_location('update_env_current_pool', module_path)
pool = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pool)
applied = json.loads(raw(deploy / 'config/provider-pool-applied.json'))
expected = pool.rag_context_window(applied)
field = b'PROVIDER_RAG_CONTEXT_WINDOW='
def split_window(data):
    lines = data.splitlines(keepends=True)
    indices = [index for index, line in enumerate(lines) if line.startswith(field)]
    if len(indices) != 1:
        raise SystemExit('升级配置保留校验：派生字段必须唯一')
    index = indices[0]
    line = lines[index]
    match = re.fullmatch(rb'PROVIDER_RAG_CONTEXT_WINDOW=([0-9]{1,8})\n', line)
    if match is None:
        raise SystemExit('升级配置保留校验：派生字段格式无效')
    return b''.join(lines[:index]), b''.join(lines[index + 1:]), int(match[1])

old_prefix, old_suffix, old_window = split_window(before)
new_prefix, new_suffix, new_window = split_window(after)
if (old_prefix, old_suffix) != (new_prefix, new_suffix):
    raise SystemExit('升级配置保留校验：非派生配置或原始字节被改写')
if new_window != expected:
    raise SystemExit('升级配置保留校验：知识窗口未对应真实接口池')
print(json.dumps({'non_derived_environment_bytes_preserved': True,
                  'derived_window_matches_current_pool': True,
                  'before_window': old_window, 'after_window': new_window,
                  'original_digest_verified': True}, ensure_ascii=False, sort_keys=True))
PY
}

# 真v1.2.1的合法YAML及自定义字段必须保留，不能用默认文案覆盖。
assert_update_configuration_preserved() (
  local previous=$1 current=$2 report_dir=$3 expected_sha256=$4 formatting=${5:-raw}
  [[ "$formatting" == raw || "$formatting" == jq-json ]] || return 1
  [[ -f "$previous" && ! -L "$previous" && -f "$current" && ! -L "$current" ]] || return 1
  [[ "$(sha256sum "$previous" | awk '{print $1}')" == "$expected_sha256" ]] || return 1
  mkdir -m 0700 -- "$report_dir" || return 1
  # 在独立Bash解码，避免模块初始化覆盖测试入口变量。
  if ! bash -s -- "${PROJECT_ROOT}/scripts/configuration.sh" "$previous" "$current" "$report_dir" <<'SH'
set -euo pipefail
source "$1"
configuration_decode_file "$2" "$4/before.json"
configuration_decode_file "$3" "$4/after.json"
SH
  then
    return 1
  fi
  cmp -s -- "${report_dir}/before.json" "${report_dir}/after.json" || return 1
  if ! cmp -s -- "$previous" "$current"; then
    [[ "$formatting" == jq-json ]] || return 1
    # 仅允许既有公共迁移器的同值jq排版，任何字段改动仍在上方被拒绝。
    jq -M '.' "$previous" > "${report_dir}/expected-format.json" || return 1
    cmp -s -- "${report_dir}/expected-format.json" "$current" || return 1
  fi
)

expect_local_ready_install() {
  local status=0
  "$@" || status=$?
  (( status == 2 )) || fail "隔离测试无真实会话，安装应返回 local-ready 状态 2，实际 ${status}"
}

# 包外旧格式夹具必须是固定发布提交的原字节；不在测试中创建历史 tag。
LEGACY_V111_BACKUP_SHA256=0b45156ad4945e77bd321faa3ccb9ed16dd35eb8fb26579835198e95b02edd15
LEGACY_V111_BACKUP_SOURCE=${CRISPAI_TEST_V111_BACKUP_SCRIPT:-}
if [[ -n "$LEGACY_V111_BACKUP_SOURCE" ]]; then
  [[ "$LEGACY_V111_BACKUP_SOURCE" == /* && -f "$LEGACY_V111_BACKUP_SOURCE"
    && ! -L "$LEGACY_V111_BACKUP_SOURCE" ]] || fail '包外 v1.1.1 备份器不是绝对路径的普通文件'
  [[ "$(sha256sum -- "$LEGACY_V111_BACKUP_SOURCE" | cut -d ' ' -f 1)" == "$LEGACY_V111_BACKUP_SHA256" ]] \
    || fail '包外 v1.1.1 备份器不匹配固定历史发布代码'
else
  git -C "$PROJECT_ROOT" cat-file -e 'v1.1.1:scripts/backup.sh' 2>/dev/null \
    || fail '缺少真实 v1.1.1 备份器；无历史 checkout 时须提供 CRISPAI_TEST_V111_BACKUP_SCRIPT'
fi

if [[ "$TEST_SELECTION" == all ]]; then
SHELL_FILES=(
  get.sh install.sh manage.sh update.sh uninstall.sh
  scripts/common.sh scripts/healthcheck.sh scripts/backup.sh scripts/restore.sh
  scripts/analytics.sh scripts/snapshot.sh scripts/rollback.sh scripts/bootstrap.sh
  scripts/wizard.sh scripts/package-release.sh scripts/publish-release.sh scripts/doctor.sh scripts/materials.sh scripts/logs.sh
  scripts/configuration.sh scripts/knowledge.sh scripts/provider.sh scripts/migration.sh
  scripts/knowledge-profile.sh
  scripts/launcher.sh scripts/menu-ui.sh scripts/menu-provider-ui.sh scripts/crisp-settings.sh scripts/full-backup.sh
  tests/run.sh tests/test_manage_contract.sh tests/test_workflow_contract.sh tests/test_workflow_runtime.sh
  tests/test_static_security.sh tests/test_archive_security.sh tests/test_deployment_integration.sh
  tests/test_external_e2e.sh tests/test_bootstrap.sh tests/test_wizard.sh tests/test_release_package.sh
  tests/test_knowledge_timeout.sh tests/test_health_wait.sh tests/test_get.sh tests/test_install_resume.sh tests/test_doctor.sh tests/test_public_distribution.sh tests/test_legacy_rollback.sh
  tests/test_caddy_routing.sh tests/test_caddy_callers.sh tests/test_logs.sh tests/test_doctor_pool.sh
  tests/test_provider_menu.sh
  tests/test_knowledge_profile_integration.sh
  tests/fixtures/doctor/curl tests/fixtures/doctor/docker tests/fixtures/doctor/df tests/fixtures/doctor/systemctl tests/mocks/chown tests/mocks/curl tests/mocks/docker tests/mocks/stat
  tests/mocks/curl_knowledge_timeout tests/mocks/systemctl
)
for file in "${SHELL_FILES[@]}"; do
  assert_file "${PROJECT_ROOT}/${file}"
  bash -n "${PROJECT_ROOT}/${file}"
done
pass "全部 Bash 脚本语法"

"${SCRIPT_DIR}/test_static_security.sh"
pass "Git 忽略规则与密钥扫描"

if command -v shellcheck >/dev/null 2>&1; then
  # ShellCheck 0.9 递归展开两个大型 doctor 验收夹具时会重复载入同一套生产
  # 模块，在 4 GiB 验收机上形成数 GiB 峰值。所有生产脚本仍逐文件使用 -x
  # 检查；这两个夹具本身改用非递归检查，并忽略仅表示“未跟随外部 source”
  # 的 SC1091。随后动态专项仍会真实执行夹具及其引用的生产代码。
  for file in "${SHELL_FILES[@]}"; do
    case "$file" in
      tests/test_doctor.sh|tests/test_doctor_pool.sh)
        shellcheck -e SC1091 "${PROJECT_ROOT}/${file}"
        ;;
      *)
        shellcheck -x "${PROJECT_ROOT}/${file}"
        ;;
    esac
  done
  pass "shellcheck"
else
  critical_skip "系统未安装 shellcheck"
fi

TEST_LAYER=UNIT/CONTRACT
"${SCRIPT_DIR}/test_bootstrap.sh"
pass "依赖与 Docker 自动引导专项"

"${SCRIPT_DIR}/test_get.sh"
pass "独立在线入口、固定正式版校验与 TTY 专项"

"${SCRIPT_DIR}/test_install_resume.sh"
AI_SUPPORT_INSTALL_RECOVERY_ONLY=1 "${SCRIPT_DIR}/test_install_resume.sh"
pass "首次 Compose 候选、暂存续装与重新配置失败恢复专项"

python3 "${SCRIPT_DIR}/test_launcher.py"
pass "正式 crispai 与受管 crisp 兼容入口及外来命令保护专项"

"${SCRIPT_DIR}/test_doctor.sh"
"${SCRIPT_DIR}/test_doctor_pool.sh"
pass "组件自检、故障注入、只读与显式修复专项"

"${SCRIPT_DIR}/test_logs.sh"
pass "日志保留、轮转、脱敏、受管调度与清理边界专项"

"${SCRIPT_DIR}/test_caddy_callers.sh"
pass "Crisp 公网配置与备份恢复的 Caddy 事务调用专项"

"${SCRIPT_DIR}/test_public_distribution.sh"
pass "公共分发入口与文档契约专项"

python3 "${SCRIPT_DIR}/test_docs_acceptance.py"
pass "新手文档、真实帮助入口与菜单限制独立核对专项"

python3 "${SCRIPT_DIR}/test_release_gate.py"
pass "同包实机回执、源码身份和发布前阻断专项"

python3 "${SCRIPT_DIR}/test_release_identity.py"
pass "固定 Git tree、规范归档与单一发布入口身份专项"

python3 "${SCRIPT_DIR}/test_provider_log_redaction.py"
pass "当前、历史与草稿接口秘密的落盘/跟踪脱敏专项"

"${SCRIPT_DIR}/test_legacy_rollback.sh"
pass "真实 v1.1.0 快照布局回滚与新模块代际收敛专项"

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
PROJECT_VERSION=$CURRENT_TEST_VERSION
[[ "$PROJECT_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "VERSION 格式无效"
grep -Fq "version: ${PROJECT_VERSION}" "${PROJECT_ROOT}/config/app.yaml" || fail "app.yaml 版本未同步"
jq -e --arg version "$PROJECT_VERSION" \
  --arg runtime_hash "$(sha256sum "${PROJECT_ROOT}/n8n/runtime.js" | awk '{print $1}')" \
  '.meta.aiSupportVersion == $version and .meta.runtimeFileSha256 == $runtime_hash
    and .meta.n8nRunnerConcurrency == 10 and .meta.backgroundProcessingPermits == 8
    and .meta.ordinaryProcessingPermits == 7' \
  "${PROJECT_ROOT}/n8n/workflow.json" >/dev/null || fail 'n8n workflow 版本或真实运行模块 hash 未同步'
pass "版本与 JSON/YAML 格式"

grep -Fq 'no-new-privileges:true' "${PROJECT_ROOT}/docker-compose.yml" || fail "Compose 缺少权限收紧"
grep -Fq '127.0.0.1' "${PROJECT_ROOT}/docker-compose.yml" || fail "Compose 未默认绑定本机"
grep -Fq 'N8N_BLOCK_ENV_ACCESS_IN_NODE: "false"' "${PROJECT_ROOT}/docker-compose.yml" || fail "n8n 无法读取受控环境变量"
grep -Fq 'N8N_RUNNERS_MAX_CONCURRENCY: "10"' "${PROJECT_ROOT}/docker-compose.yml" || fail "n8n runner 并发未固定为 10"
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
python3 "${SCRIPT_DIR}/test_rag_context.py"
pass "RAG 上下文预算的受管应用及失败边界（内部子项单列）"
python3 "${SCRIPT_DIR}/test_snapshot_live.py"
pass "在线快照预检的短命锁、容量与严格文件类型边界（内部子项单列）"
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
  node "${SCRIPT_DIR}/test_crisp_auth.js"
  pass "Crisp Website/Plugin 编码、实际请求认证与错误响应专项"
  node "${SCRIPT_DIR}/test_materials_apply.js"
  pass "直接编辑资料的校验、投影、真实协议回读与失败恢复专项"
  node "${SCRIPT_DIR}/test_material_limits.js"
  pass "Prompt、目录、命名知识库与菜单限制的边界和越界专项"
  node "${SCRIPT_DIR}/test_knowledge_context.js"
  node "${SCRIPT_DIR}/test_knowledge_lexical.js"
  node "${SCRIPT_DIR}/test_knowledge_hybrid.js"
  node "${SCRIPT_DIR}/test_knowledge_runtime.js"
  pass "纯问题检索、词法/向量混合补召回、完整知识片段、管理员同链与取消专项（内部子项单列）"
  python3 "${SCRIPT_DIR}/test_knowledge_profile.py"
  "${SCRIPT_DIR}/test_knowledge_profile_integration.sh"
  pass "中文 Embedding 配置代际、原子迁移及失败恢复专项（内部子项单列）"
  node "${SCRIPT_DIR}/test_provider_adapter.js"
  pass "Provider 桥接生产代码协议专项（内部子项单列，不重复计入总数）"
  node "${SCRIPT_DIR}/test_provider_pool.js"
  node "${SCRIPT_DIR}/test_provider_recovery_contract.js"
  node "${SCRIPT_DIR}/test_runtime_process_fencing.js"
  node "${SCRIPT_DIR}/test_runtime_provider_pool.js"
  node "${SCRIPT_DIR}/test_runtime_provider_failure_reply.js"
  "${SCRIPT_DIR}/test_provider_menu.sh"
  pass "主备池生产协议与管理专项（内部子项单列，不重复计入总数）"
  node "${SCRIPT_DIR}/test_runtime_missing_reply_p0.js"
  pass "漏回复状态背压、会话隔离、公平调度与扫描恢复专项（内部子项单列，不重复计入总数）"
  node "${SCRIPT_DIR}/test_feedback_runtime.js"
  pass "取消评价与历史出站恢复专项（内部子项单列，不重复计入总数）"
  node "${SCRIPT_DIR}/test_outgoing_identity.js"
  pass "中性客服显示与持久出站归属隔离专项"
  node "${SCRIPT_DIR}/test_configuration_protocol.js"
  node "${SCRIPT_DIR}/test_provider_lifecycle.js"
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
export MOCK_SYSTEMD_STATE="${TEST_ROOT}/systemd-state"
export MOCK_CHOWN_ROOT="$TEST_ROOT"
export CRISPAI_LOGS_SYSTEMD_TEST=1
export CRISPAI_LOGS_SYSTEMD_DIR="${TEST_ROOT}/systemd"
mkdir -p -- "$MOCK_SYSTEMD_STATE" "$CRISPAI_LOGS_SYSTEMD_DIR"
python3 - "${MOCK_DIR}/chown" "$TEST_ROOT" <<'PY'
import os
from pathlib import Path
import subprocess
import sys

command, parent = sys.argv[1], Path(sys.argv[2])
root = parent / ".test-runtime.permissions"
root.mkdir(mode=0o700)
inside = root / "inside"
inside.mkdir()
item = inside / "普通文件.md"
item.write_text("permission fixture\n", encoding="utf-8")
outside = parent / "permission-outside"
outside.write_text("outside sentinel\n", encoding="utf-8")
original = (outside.read_bytes(), outside.stat().st_uid, outside.stat().st_gid)
environment = dict(os.environ, MOCK_CHOWN_ROOT=str(root))

def invoke(*args, expected, env=environment):
    result = subprocess.run([command, *map(str, args)], env=env, capture_output=True)
    assert result.returncode == expected, (args, result.returncode)

invoke("-R", "root:1000", inside, expected=0)
assert inside.stat().st_gid == 1000 and item.stat().st_gid == 1000
without_scope = dict(environment)
without_scope.pop("MOCK_CHOWN_ROOT")
invoke("root:1000", outside, expected=0, env=without_scope)
invoke("root:1000", outside, expected=1)
invoke("root:1000", root, expected=1)
invoke("root:1000", str(root) + "/../permission-outside", expected=1)
invoke("--reference", outside, item, expected=1)
link = root / "link"
link.symlink_to(outside)
invoke("root:1000", link, expected=1)
link.unlink()
child_link = inside / "link"
child_link.symlink_to(outside)
invoke("-R", "root:1000", inside, expected=1)
child_link.unlink()
os.link(outside, root / "hardlink")
invoke("-R", "root:1000", inside, root / "hardlink", expected=1)
(root / "hardlink").unlink()
os.link(outside, inside / "hardlink")
invoke("-R", "root:1000", inside, expected=1)
(inside / "hardlink").unlink()
control = inside / "control\nmember"
control.write_text("control fixture\n", encoding="utf-8")
invoke("-R", "root:1000", inside, expected=1)
control.unlink()
invoke("root:1000", "--reference", outside, item, expected=1)
os.chown(item, 0, 0)
invoke("root:1000", item, outside, expected=1)
assert item.stat().st_gid == 0, "必须先检查全部目标，再执行真实 chown"
root.chmod(0o755)
invoke("root:1000", item, expected=1)
root.chmod(0o700)
assert (outside.read_bytes(), outside.stat().st_uid, outside.stat().st_gid) == original
PY
pass "生命周期权限夹具仅在受限临时根真实修改属主，拒绝越界、链接与不完整校验"

RUNTIME_PERMISSION_ROOT="${TEST_ROOT}/runtime-control-permissions"
mkdir -p -- "${RUNTIME_PERMISSION_ROOT}"/{config,knowledge,n8n} \
  "${RUNTIME_PERMISSION_ROOT}/data"/{analytics,n8n,anythingllm,runtime}
for protected_projection in knowledge-map.json knowledge-settings.json knowledge-profile.json knowledge-lexical.json; do
  printf '{}\n' > "${RUNTIME_PERMISSION_ROOT}/data/runtime/${protected_projection}"
  chmod 0660 "${RUNTIME_PERMISSION_ROOT}/data/runtime/${protected_projection}"
  /usr/bin/chown 1000:1000 "${RUNTIME_PERMISSION_ROOT}/data/runtime/${protected_projection}"
done
printf '{}\n' > "${RUNTIME_PERMISSION_ROOT}/data/runtime/knowledge-migration.json"
chmod 0660 "${RUNTIME_PERMISSION_ROOT}/data/runtime/knowledge-migration.json"
/usr/bin/chown 1000:1000 "${RUNTIME_PERMISSION_ROOT}/data/runtime/knowledge-migration.json"
bash -c 'set -euo pipefail; source "$1/scripts/common.sh"; set_runtime_ownership "$2"' \
  -- "$PROJECT_ROOT" "$RUNTIME_PERMISSION_ROOT"
for protected_projection in knowledge-map.json knowledge-settings.json knowledge-profile.json knowledge-lexical.json; do
  [[ "$(/usr/bin/stat -c '%u:%g:%a' "${RUNTIME_PERMISSION_ROOT}/data/runtime/${protected_projection}")" == '0:1000:640' ]] \
    || fail "受管知识运行投影没有以新 inode 恢复 root:1000/0640：${protected_projection}"
done
[[ "$(/usr/bin/stat -c '%u:%g:%a' "${RUNTIME_PERMISSION_ROOT}/data/runtime/knowledge-migration.json")" == '0:1000:600' ]] \
  || fail '知识迁移指针被错误放宽，必须保持 root:1000/0600'
pass "运行资料权限原子恢复并保持迁移指针 root-only"

RUNTIME_PERMISSION_OUTSIDE="${RUNTIME_PERMISSION_ROOT}/data/n8n/runtime-control-alias.json"
printf '{"sibling":true}\n' > "$RUNTIME_PERMISSION_OUTSIDE"
chmod 0600 "$RUNTIME_PERMISSION_OUTSIDE"
/usr/bin/chown 0:0 "$RUNTIME_PERMISSION_OUTSIDE"
RUNTIME_PERMISSION_OUTSIDE_STATE=$(/usr/bin/stat -c '%u:%g:%a:%s' "$RUNTIME_PERMISSION_OUTSIDE")
unlink -- "${RUNTIME_PERMISSION_ROOT}/data/runtime/knowledge-map.json"
ln -- "$RUNTIME_PERMISSION_OUTSIDE" "${RUNTIME_PERMISSION_ROOT}/data/runtime/knowledge-map.json"
if bash -c 'set -euo pipefail
  # 此负例必须忠实执行生产 chown；通用测试桩本身也会拒绝硬链接，若继续
  # 使用它，错误的“先递归 chown、后投影预检”顺序同样可能假绿。
  chown() { /usr/bin/chown "$@"; }
  source "$1/scripts/common.sh"
  set_runtime_ownership "$2"
' \
  -- "$PROJECT_ROOT" "$RUNTIME_PERMISSION_ROOT" >/dev/null 2>&1; then
  fail '知识运行投影硬链接被特权权限修复错误接受'
fi
[[ "$(/usr/bin/stat -c '%u:%g:%a:%s' "$RUNTIME_PERMISSION_OUTSIDE")" == "$RUNTIME_PERMISSION_OUTSIDE_STATE" ]] \
  || fail '拒绝知识投影硬链接前递归修改了 AnythingLLM/n8n 同级运行树 inode'
unlink -- "${RUNTIME_PERMISSION_ROOT}/data/runtime/knowledge-map.json"
printf '{}\n' > "${RUNTIME_PERMISSION_ROOT}/data/runtime/knowledge-map.json"
chmod 0640 "${RUNTIME_PERMISSION_ROOT}/data/runtime/knowledge-map.json"
/usr/bin/chown root:1000 "${RUNTIME_PERMISSION_ROOT}/data/runtime/knowledge-map.json"
pass "知识运行投影硬链接在递归权限修复前 fail-closed 且同级运行树 inode 不变"
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
TEST_RESPONSES_ANYTHING_KEY='test-only-responses-anything-key'
TEST_CRISP_AUTH=$(printf '%s' "test-only-identifier:${TEST_CRISP_KEY}" | base64 | tr -d '\n')
export MOCK_FORBIDDEN_ARG_FILE="${TEST_ROOT}/forbidden-curl-args.txt"
printf '%s\n' "$TEST_PROVIDER_KEY" "$TEST_CRISP_KEY" "$TEST_ANYTHING_KEY" \
  "$TEST_RESPONSES_ANYTHING_KEY" "$TEST_CRISP_AUTH" \
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
  MOCK_DOCKER_STRICT_CONFIG=1 \
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
assert_file "${DEPLOY_DIR}/scripts/visitor-output.js"
[[ "$(<"${DEPLOY_DIR}/VERSION")" == "$PROJECT_VERSION" ]] || fail "安装版本错误"
assert_file "${DEPLOY_DIR}/config/tags.yaml"
assert_file "${DEPLOY_DIR}/config/feedback.yaml"
assert_file "${DEPLOY_DIR}/data/analytics/events.jsonl"
[[ "$(stat -c '%a' "${DEPLOY_DIR}/.env")" == 600 ]] || fail ".env 权限不是 0600"
grep -Fxq 'CRISPAI_LOG_MAX_FILES=5' "${DEPLOY_DIR}/.env" || fail '新装日志份数被旧版迁移缺省值覆盖'
jq -e '.max_files == 5' "${DEPLOY_DIR}/config/logging.yaml" >/dev/null || fail '新装日志策略与运行环境不一致'
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

RUNTIME_SETTINGS_FILE="${DEPLOY_DIR}/data/runtime/knowledge-settings.json"
RUNTIME_SETTINGS_HASH=$(sha256sum "$RUNTIME_SETTINGS_FILE" | awk '{print $1}')
RUNTIME_SETTINGS_INODE=$(/usr/bin/stat -c '%i' "$RUNTIME_SETTINGS_FILE")
RUNTIME_SETTINGS_NEXT_TIME=$(( $(jq -r '.observed_at' "$RUNTIME_SETTINGS_FILE") + 10 ))
bash -c 'set -euo pipefail
  source "$1/scripts/common.sh"
  anythingllm_connection "$2"
  settings_next_time=$3
  date() { if [[ $# == 1 && $1 == +%s ]]; then printf "%s\\n" "$settings_next_time"; else command date "$@"; fi; }
  anythingllm_workspace_runtime_settings "$2"
' -- "$PROJECT_ROOT" "$DEPLOY_DIR" "$RUNTIME_SETTINGS_NEXT_TIME"
[[ "$(sha256sum "$RUNTIME_SETTINGS_FILE" | awk '{print $1}')" == "$RUNTIME_SETTINGS_HASH" ]] \
  || fail '工作区同值回读因时间变化破坏了已封印的知识设置摘要'
[[ "$(/usr/bin/stat -c '%i' "$RUNTIME_SETTINGS_FILE")" == "$RUNTIME_SETTINGS_INODE" ]] \
  || fail '工作区同值回读无故替换了受管设置 inode'
RUNTIME_SETTINGS_PROBE_ROOT="${TEST_ROOT}/runtime-settings-readback"
mkdir -p -- "${RUNTIME_SETTINGS_PROBE_ROOT}/tmp" "${RUNTIME_SETTINGS_PROBE_ROOT}/data/runtime"
RUNTIME_SETTINGS_PROBE_FILE="${RUNTIME_SETTINGS_PROBE_ROOT}/data/runtime/knowledge-settings.json"
jq -M '.temperature=0.2 | .observed_at=1' "$RUNTIME_SETTINGS_FILE" > "$RUNTIME_SETTINGS_PROBE_FILE"
chmod 0640 "$RUNTIME_SETTINGS_PROBE_FILE"
/usr/bin/chown 0:1000 "$RUNTIME_SETTINGS_PROBE_FILE"
RUNTIME_SETTINGS_PROBE_HASH=$(sha256sum "$RUNTIME_SETTINGS_PROBE_FILE" | awk '{print $1}')
bash -c 'set -euo pipefail
  source "$1/scripts/common.sh"
  anythingllm_connection "$2"
  anythingllm_workspace_runtime_settings "$3"
' -- "$PROJECT_ROOT" "$DEPLOY_DIR" "$RUNTIME_SETTINGS_PROBE_ROOT"
jq -M -e '.schema_version==1 and .temperature==0.7 and .observed_at>1' "$RUNTIME_SETTINGS_PROBE_FILE" >/dev/null \
  || fail '工作区实际值变化后回读错误保留了旧设置'
[[ "$(sha256sum "$RUNTIME_SETTINGS_PROBE_FILE" | awk '{print $1}')" != "$RUNTIME_SETTINGS_PROBE_HASH" ]] \
  || fail '工作区实际值变化后未发布新设置摘要'
[[ "$(sha256sum "$RUNTIME_SETTINGS_FILE" | awk '{print $1}')" == "$RUNTIME_SETTINGS_HASH" ]] \
  || fail '独立设置回读场景污染了已应用资料代'
pass "工作区同值回读保持摘要与 inode，实际值变化仍发布新设置"

ANYTHING_HELPER="${MOCK_DIR}/anything-cache.py"
ANYTHING_HELPER_CONFIG=$(mktemp "${DEPLOY_DIR}/tmp/helper-security.XXXXXXXX")
printf 'header = "Authorization: Bearer %s"\n' "$TEST_ANYTHING_KEY" > "$ANYTHING_HELPER_CONFIG"
chmod 0600 "$ANYTHING_HELPER_CONFIG"
ANYTHING_HELPER_PORT=$(bash -c 'source "$1/scripts/common.sh"; env_get "$1/.env" ANYTHINGLLM_PORT' \
  -- "$DEPLOY_DIR")
ANYTHING_HELPER_URL="http://127.0.0.1:${ANYTHING_HELPER_PORT}/api/v1/workspace/crisp-support"
if python3 -B "$ANYTHING_HELPER" observe "$MOCK_ANYTHING_STATE" / \
  "$ANYTHING_HELPER_URL" "$ANYTHING_HELPER_CONFIG" >/dev/null 2>&1; then
  fail 'AnythingLLM 缓存夹具错误接受系统根作为写入范围'
fi
ANYTHING_SCOPE_LINK="${PROJECT_ROOT}/.test-runtime.scope-link"
ln -s -- "$TEST_ROOT" "$ANYTHING_SCOPE_LINK"
if python3 -B "$ANYTHING_HELPER" observe "$MOCK_ANYTHING_STATE" "$ANYTHING_SCOPE_LINK" \
  "$ANYTHING_HELPER_URL" "$ANYTHING_HELPER_CONFIG" >/dev/null 2>&1; then
  fail 'AnythingLLM 缓存夹具错误接受链接测试根'
fi
unlink -- "$ANYTHING_SCOPE_LINK"
ANYTHING_WRONG_CONFIG=$(mktemp "${DEPLOY_DIR}/tmp/helper-wrong-key.XXXXXXXX")
printf '%s\n' 'header = "Authorization: Bearer wrong-test-key"' > "$ANYTHING_WRONG_CONFIG"
chmod 0600 "$ANYTHING_WRONG_CONFIG"
if python3 -B "$ANYTHING_HELPER" observe "$MOCK_ANYTHING_STATE" "$TEST_ROOT" \
  "$ANYTHING_HELPER_URL" "$ANYTHING_WRONG_CONFIG" >/dev/null 2>&1; then
  fail 'AnythingLLM 缓存夹具错误接受不匹配的实例密钥'
fi
unlink -- "$ANYTHING_WRONG_CONFIG"
ln -- "$MOCK_ANYTHING_STATE" "${TEST_ROOT}/anythingllm-state-hardlink.json"
if python3 -B "$ANYTHING_HELPER" observe "$MOCK_ANYTHING_STATE" "$TEST_ROOT" \
  "$ANYTHING_HELPER_URL" "$ANYTHING_HELPER_CONFIG" >/dev/null 2>&1; then
  fail 'AnythingLLM 缓存夹具错误接受硬链接共享状态'
fi
unlink -- "${TEST_ROOT}/anythingllm-state-hardlink.json"
unlink -- "$ANYTHING_HELPER_CONFIG"
pass 'AnythingLLM 生命周期缓存夹具拒绝越界范围、祖先链接、错密钥与硬链接状态'

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
for protected_projection in knowledge-map.json knowledge-settings.json knowledge-profile.json knowledge-lexical.json; do
  [[ "$(/usr/bin/stat -c '%u:%g:%a' "${CRISP_EXTERNAL_FAILURE_DEPLOY_DIR}/data/runtime/${protected_projection}")" == '0:1000:640' ]] \
    || fail "重复安装后知识运行投影属主或权限漂移：${protected_projection}"
done
if [[ -e "${CRISP_EXTERNAL_FAILURE_DEPLOY_DIR}/data/runtime/knowledge-migration.json" \
  || -L "${CRISP_EXTERNAL_FAILURE_DEPLOY_DIR}/data/runtime/knowledge-migration.json" ]]; then
  [[ "$(/usr/bin/stat -c '%u:%g:%a' "${CRISP_EXTERNAL_FAILURE_DEPLOY_DIR}/data/runtime/knowledge-migration.json")" == '0:1000:600' ]] \
    || fail '重复安装错误放宽知识迁移指针权限'
fi
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

REPEAT_PROTECTED_FILES=(
  .env
  .crisp-ai-installation
  config/provider.yaml
  config/provider-pool.yaml
  config/provider-pool-applied.json
  config/provider-pool-readback.json
)
REPEAT_PROTECTED_BEFORE=$(
  for relative in "${REPEAT_PROTECTED_FILES[@]}"; do
    [[ -f "${DEPLOY_DIR}/${relative}" && ! -L "${DEPLOY_DIR}/${relative}" ]] \
      || fail "运行中实例的 --skip-start 保护文件缺失或不安全：${relative}"
    printf '%s\t%s\t%s\n' "$relative" \
      "$(stat -c '%i:%s:%y:%z:%a' "${DEPLOY_DIR}/${relative}")" \
      "$(sha256sum "${DEPLOY_DIR}/${relative}" | awk '{print $1}')"
  done
)
: > "$MOCK_DOCKER_LOG"
REPEAT_INSTALL_STATUS=0
"${PROJECT_ROOT}/install.sh" \
  --deploy-dir "$DEPLOY_DIR" --non-interactive --skip-start > "${TEST_ROOT}/repeat-install.log" 2>&1 \
  || REPEAT_INSTALL_STATUS=$?
(( REPEAT_INSTALL_STATUS != 0 )) \
  || fail "运行中实例错误接受了普通 --skip-start"
grep -Fq -- '已运行实例不能使用 --skip-start' "${TEST_ROOT}/repeat-install.log" \
  || fail "运行中实例的普通 --skip-start 拒绝原因不明确"
[[ ! -s "$MOCK_DOCKER_LOG" ]] \
  || fail "运行中实例拒绝普通 --skip-start 前调用了 Docker/Caddy"
REPEAT_PROTECTED_AFTER=$(
  for relative in "${REPEAT_PROTECTED_FILES[@]}"; do
    [[ -f "${DEPLOY_DIR}/${relative}" && ! -L "${DEPLOY_DIR}/${relative}" ]] \
      || fail "普通 --skip-start 拒绝后保护文件缺失或不安全：${relative}"
    printf '%s\t%s\t%s\n' "$relative" \
      "$(stat -c '%i:%s:%y:%z:%a' "${DEPLOY_DIR}/${relative}")" \
      "$(sha256sum "${DEPLOY_DIR}/${relative}" | awk '{print $1}')"
  done
)
[[ "$REPEAT_PROTECTED_AFTER" == "$REPEAT_PROTECTED_BEFORE" ]] \
  || fail "运行中实例拒绝普通 --skip-start 时改写了配置、marker、接口池或回读"
pass "运行中实例普通 --skip-start 在受管写入前拒绝"

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
# 暂存恢复不会签发运行准入回执；必须由原生续装启动并回读，不能手工伪造 ready。
expect_local_ready_install "${PROJECT_ROOT}/install.sh" \
  --deploy-dir "$DEPLOY_DIR" --non-interactive > "${TEST_ROOT}/complete-install-retry.log" 2>&1
grep -Fxq 'state=local-ready' "${DEPLOY_DIR}/.crisp-ai-installation" \
  || fail "暂存续装未完成本地运行与准入回读"

"${DEPLOY_DIR}/scripts/healthcheck.sh" --deploy-dir "$DEPLOY_DIR" --offline \
  > "${TEST_ROOT}/health-offline.log" 2>&1
"${DEPLOY_DIR}/scripts/healthcheck.sh" --deploy-dir "$DEPLOY_DIR" \
  > "${TEST_ROOT}/health-online.log" 2>&1
pass "离线与在线健康检查成功路径"

if env MOCK_CRISP_FAIL=1 "${DEPLOY_DIR}/scripts/healthcheck.sh" --deploy-dir "$DEPLOY_DIR" --full \
  > "${TEST_ROOT}/crisp-failure.log" 2>&1; then
  fail "Crisp API 失败未导致健康检查失败"
fi
grep -Eq '\[FAIL\] Crisp REST API|当前凭据只读校验失败' "${TEST_ROOT}/crisp-failure.log" || fail "未报告 Crisp API 失败"
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
  ANYTHINGLLM_API_KEY="$TEST_RESPONSES_ANYTHING_KEY" N8N_HOST=responses.example.invalid \
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
if grep -Fq "$TEST_RESPONSES_ANYTHING_KEY" "${TEST_ROOT}/responses-only.log"; then
  fail "Responses-only 安装日志泄露 AnythingLLM Key"
fi
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

MAIN_KNOWLEDGE_GENERATION_BEFORE=$(sha256sum "${DEPLOY_DIR}/config/materials-applied.json" \
  "${DEPLOY_DIR}/knowledge/catalog.json" "${DEPLOY_DIR}/data/knowledge-manifest.json" \
  "${DEPLOY_DIR}/data/runtime/knowledge-"{map,settings,profile,lexical}.json)
(
  # 旧算法在独立、尚未封印的布局内回归，不污染当前已应用代及其恢复材料。
  trap - EXIT
  LEGACY_KNOWLEDGE_DEPLOY="${TEST_ROOT}/legacy-knowledge"
  env AI_API_BASE_URL=https://provider.invalid AI_API_KEY="$TEST_PROVIDER_KEY" \
    AI_MODEL=gpt-vision-test AI_SUPPORTS_VISION=false \
    CRISP_WEBSITE_ID=11111111-1111-1111-1111-111111111111 \
    CRISP_TOKEN_TIER=website CRISP_TOKEN_IDENTIFIER=test-only-identifier \
    CRISP_TOKEN_KEY="$TEST_CRISP_KEY" ANYTHINGLLM_API_KEY="$TEST_ANYTHING_KEY" \
    ANYTHINGLLM_PORT=19001 N8N_PORT=19002 N8N_HOST=legacy-knowledge.example.invalid \
    PUBLIC_WEBHOOK_URL=https://legacy-knowledge.example.invalid/ TIMEZONE=UTC \
    "${PROJECT_ROOT}/install.sh" --deploy-dir "$LEGACY_KNOWLEDGE_DEPLOY" \
      --command-path "${TEST_ROOT}/bin/crispai-legacy-knowledge" --non-interactive --skip-start \
      > "${TEST_ROOT}/legacy-knowledge-setup.log" 2>&1
  [[ ! -e "${LEGACY_KNOWLEDGE_DEPLOY}/config/materials-applied.json" ]] \
    || fail "旧布局夹具不应含当前生效投影"
  bash -c 'set -euo pipefail; source "$1/scripts/common.sh"; docker_compose "$1" up -d anythingllm' \
    -- "$LEGACY_KNOWLEDGE_DEPLOY" >> "${TEST_ROOT}/legacy-knowledge-setup.log" 2>&1
install -m 0640 "${SCRIPT_DIR}/fixtures/knowledge.md" "${LEGACY_KNOWLEDGE_DEPLOY}/knowledge/test-knowledge.md"
install -m 0640 "${SCRIPT_DIR}/fixtures/knowledge.md" "${LEGACY_KNOWLEDGE_DEPLOY}/knowledge/test-knowledge.txt"
install -m 0640 "${SCRIPT_DIR}/fixtures/knowledge.md" "${LEGACY_KNOWLEDGE_DEPLOY}/knowledge/test-knowledge.pdf"
install -m 0640 "${SCRIPT_DIR}/fixtures/knowledge.md" "${LEGACY_KNOWLEDGE_DEPLOY}/knowledge/test-knowledge.docx"
bash -c "set -euo pipefail; source \"\$1/scripts/common.sh\"; knowledge_sync_legacy \"\$1\"; knowledge_sync_legacy \"\$1\" 1" \
  -- "$LEGACY_KNOWLEDGE_DEPLOY" > "${TEST_ROOT}/knowledge-sync.log" 2>&1
jq -e '.files["test-knowledge.md"].locations | length > 0' \
  "${LEGACY_KNOWLEDGE_DEPLOY}/data/knowledge-manifest.json" >/dev/null || fail "知识文件未写入同步清单"
jq -e '
  (.files | keys | sort) == ["test-knowledge.docx","test-knowledge.md","test-knowledge.pdf","test-knowledge.txt"] and
  ([.files[].locations | length] | all(. > 0))
' "${LEGACY_KNOWLEDGE_DEPLOY}/data/knowledge-manifest.json" >/dev/null || fail "四种知识文件格式未全部写入同步清单"
EXPECTED_SOURCE_LOCATIONS=$(jq -c '[.files[].locations[]] | unique' \
  "${LEGACY_KNOWLEDGE_DEPLOY}/data/knowledge-manifest.json")
rm -f -- "${LEGACY_KNOWLEDGE_DEPLOY}/knowledge/test-knowledge.md" "${LEGACY_KNOWLEDGE_DEPLOY}/knowledge/test-knowledge.txt" \
  "${LEGACY_KNOWLEDGE_DEPLOY}/knowledge/test-knowledge.pdf" "${LEGACY_KNOWLEDGE_DEPLOY}/knowledge/test-knowledge.docx"
if env MOCK_REMOVE_DOCUMENTS_FAIL=1 bash -c \
  "set -euo pipefail; source \"\$1/scripts/common.sh\"; knowledge_sync_legacy \"\$1\"" \
  -- "$LEGACY_KNOWLEDGE_DEPLOY" >> "${TEST_ROOT}/knowledge-sync.log" 2>&1; then
  fail "AnythingLLM 源文档删除失败时知识同步被错误报告为成功"
fi
jq -e '.files | length == 0' "${LEGACY_KNOWLEDGE_DEPLOY}/data/knowledge-manifest.json" >/dev/null || fail "删除知识文件后未清理索引清单"
jq -e --argjson expected "$EXPECTED_SOURCE_LOCATIONS" \
  '(.garbage_locations | sort) == ($expected | sort)' \
  "${LEGACY_KNOWLEDGE_DEPLOY}/data/knowledge-manifest.json" >/dev/null || fail "源文档删除失败后未登记孤立位置"
bash -c "set -euo pipefail; source \"\$1/scripts/common.sh\"; knowledge_sync_legacy \"\$1\"" \
  -- "$LEGACY_KNOWLEDGE_DEPLOY" >> "${TEST_ROOT}/knowledge-sync.log" 2>&1
jq -e '.garbage_locations == []' "${LEGACY_KNOWLEDGE_DEPLOY}/data/knowledge-manifest.json" >/dev/null \
  || fail "后续知识同步未重试清理孤立源文档"
jq -e --arg deploy "$LEGACY_KNOWLEDGE_DEPLOY" --argjson expected "$EXPECTED_SOURCE_LOCATIONS" '
  ((.rag_instances[$deploy].removed_documents // []) | sort) == ($expected | sort) and
  all(.rag_instances | to_entries[] | select(.key != $deploy);
    ((.value.documents // []) | length) == 0)
' "$MOCK_ANYTHING_STATE" >/dev/null \
  || fail "AnythingLLM remove-documents 未清理已删除知识源文档"
install -m 0640 "${SCRIPT_DIR}/fixtures/knowledge.md" "${LEGACY_KNOWLEDGE_DEPLOY}/knowledge/test-knowledge.md"
# 从未封印的旧单库数据布局走原生续装，不能删除当前已应用实例的 catalog。
[[ ! -e "${LEGACY_KNOWLEDGE_DEPLOY}/knowledge/catalog.json" && ! -L "${LEGACY_KNOWLEDGE_DEPLOY}/knowledge/catalog.json" ]] \
  || fail "旧布局夹具意外带有命名库，未通过删除 catalog 制造迁移"
expect_local_ready_install "${PROJECT_ROOT}/install.sh" \
  --deploy-dir "$LEGACY_KNOWLEDGE_DEPLOY" \
  --command-path "${TEST_ROOT}/bin/crispai-legacy-knowledge" \
  --non-interactive >> "${TEST_ROOT}/knowledge-sync.log" 2>&1
jq -e '.libraries[0].id == "kb_default" and .libraries[0].documents[0].projection == "test-knowledge.md"' \
  "${LEGACY_KNOWLEDGE_DEPLOY}/knowledge/catalog.json" >/dev/null || fail "旧单库没有迁入命名知识库"
)
pass "知识旧算法四种扩展名、删除重试与命名库迁移（不验证真实解析）"
MAIN_KNOWLEDGE_GENERATION_AFTER=$(sha256sum "${DEPLOY_DIR}/config/materials-applied.json" \
  "${DEPLOY_DIR}/knowledge/catalog.json" "${DEPLOY_DIR}/data/knowledge-manifest.json" \
  "${DEPLOY_DIR}/data/runtime/knowledge-"{map,settings,profile,lexical}.json)
[[ "$MAIN_KNOWLEDGE_GENERATION_AFTER" == "$MAIN_KNOWLEDGE_GENERATION_BEFORE" ]] \
  || fail "旧布局回归污染了当前已应用主实例的知识代"
pass "旧布局迁移与当前已应用知识代隔离"

# 缓存篡改与离线恢复需要真实受管文档；空知识代本身是合法正常反例。
python3 -B "${DEPLOY_DIR}/scripts/knowledge-profile.py" --deploy-dir "$DEPLOY_DIR" \
  refresh-bindings --validate-only --require-complete \
  > "${TEST_ROOT}/restore-empty-profile.json"
jq -e '.success == true and .changed == false and .bindings == 0' \
  "${TEST_ROOT}/restore-empty-profile.json" >/dev/null || fail '合法空知识代不应要求不存在的缓存'
"${DEPLOY_DIR}/scripts/knowledge.sh" --deploy-dir "$DEPLOY_DIR" create '恢复验收知识库' \
  > "${TEST_ROOT}/restore-library.json" 2> "${TEST_ROOT}/restore-library.log"
RESTORE_LIBRARY_ID=$(jq -er '.library_id | select(test("^kb_[a-f0-9]{16}$"))' \
  "${TEST_ROOT}/restore-library.json")
"${DEPLOY_DIR}/scripts/knowledge.sh" --deploy-dir "$DEPLOY_DIR" \
  import "$RESTORE_LIBRARY_ID" "${SCRIPT_DIR}/fixtures/knowledge.md" \
  > "${TEST_ROOT}/restore-document.json" 2> "${TEST_ROOT}/restore-document.log"
RESTORE_KNOWLEDGE_PROJECTION=$(jq -er --arg id "$RESTORE_LIBRARY_ID" \
  '.libraries[] | select(.id == $id) | .documents | select(length == 1) | .[0].projection | select(test("^kb_[a-f0-9]{16}_doc_[a-f0-9]{16}\\.md$"))' \
  "${DEPLOY_DIR}/knowledge/catalog.json")
assert_file "${DEPLOY_DIR}/knowledge/${RESTORE_KNOWLEDGE_PROJECTION}"
python3 -B "${DEPLOY_DIR}/scripts/knowledge-profile.py" --deploy-dir "$DEPLOY_DIR" \
  refresh-bindings --validate-only --require-complete \
  > "${TEST_ROOT}/restore-populated-profile.json"
jq -e '.success == true and .changed == false and .bindings == 1' \
  "${TEST_ROOT}/restore-populated-profile.json" >/dev/null || fail '恢复夹具没有通过原生受管缓存完整性校验'

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
tar -xOzf "$ARCHIVE" ./manifest.json | jq -e '.format == "ai-support-business-v2" and .contains_knowledge == true' >/dev/null \
  || fail '默认备份未采用已有的完整多库业务格式'
while IFS= read -r relative; do
  grep -Fxq "./knowledge/${relative}" <<< "$ARCHIVE_LIST" || fail '默认业务备份遗漏命名知识库原文'
done < <(jq -r '.libraries[] | .id as $id | .documents[] | $id + "/" + .source' "${DEPLOY_DIR}/knowledge/catalog.json")
grep -Fq './config/runtime.yaml' <<< "$ARCHIVE_LIST" || fail '默认业务备份遗漏客服总开关配置'
pass '默认业务备份与菜单迁移统一，包含全部命名库原文和总开关'

# 旧离线恢复契约仍用真实已发布 v1.1.1 备份器生成的 v1 包验收；不能让
# 新备份遗漏多库来维持旧夹具，也不能删除原有的离线恢复与安全断言。
RESTORE_EXTENSION_TEMP=$(mktemp "${DEPLOY_DIR}/config/handoff.extension.XXXXXXXX")
jq -M '.handoff.restore_test_extension={preserved:true}' "${DEPLOY_DIR}/config/handoff.yaml" \
  > "$RESTORE_EXTENSION_TEMP"
chmod 0640 "$RESTORE_EXTENSION_TEMP"
mv -f -- "$RESTORE_EXTENSION_TEMP" "${DEPLOY_DIR}/config/handoff.yaml"
RESTORE_EXTENSION_TEMP=$(mktemp "${DEPLOY_DIR}/config/provider.extension.XXXXXXXX")
jq -M '.provider.restore_test_extension={preserved:true}' "${DEPLOY_DIR}/config/provider.yaml" \
  > "$RESTORE_EXTENSION_TEMP"
chmod 0640 "$RESTORE_EXTENSION_TEMP"
mv -f -- "$RESTORE_EXTENSION_TEMP" "${DEPLOY_DIR}/config/provider.yaml"
mkdir -p -- "${TEST_ROOT}/legacy-backup-tools"
if [[ -n "$LEGACY_V111_BACKUP_SOURCE" ]]; then
  install -m 0644 -- "$LEGACY_V111_BACKUP_SOURCE" "${TEST_ROOT}/legacy-backup-tools/backup.sh"
else
  git -C "$PROJECT_ROOT" show 'v1.1.1:scripts/backup.sh' > "${TEST_ROOT}/legacy-backup-tools/backup.sh"
fi
[[ "$(sha256sum "${TEST_ROOT}/legacy-backup-tools/backup.sh" | cut -d ' ' -f 1)" == "$LEGACY_V111_BACKUP_SHA256" ]] \
  || fail '旧格式回归使用的不是已发布 v1.1.1 原备份器'
cp -- "${DEPLOY_DIR}/scripts/common.sh" "${TEST_ROOT}/legacy-backup-tools/common.sh"
ARCHIVE="${DEPLOY_DIR}/backups/legacy-v1-compatibility.tar.gz"
bash "${TEST_ROOT}/legacy-backup-tools/backup.sh" --deploy-dir "$DEPLOY_DIR" --output "$ARCHIVE" \
  > "${TEST_ROOT}/legacy-backup-create.log" 2>&1
tar -xOzf "$ARCHIVE" ./manifest.json | jq -e '.format == "ai-support-backup-v1"' >/dev/null || fail '旧格式夹具不是真实 v1 备份'
printf '临时 Prompt，恢复后应被替换。\n' > "${DEPLOY_DIR}/config/prompt.md"
rm -f -- "${DEPLOY_DIR}/knowledge/${RESTORE_KNOWLEDGE_PROJECTION}"
if "${DEPLOY_DIR}/scripts/restore.sh" \
  --deploy-dir "$DEPLOY_DIR" --input "$ARCHIVE" --skip-restart --no-safety-backup \
  > "${TEST_ROOT}/restore-running-refused.log" 2>&1; then
  fail "服务仍运行时 --skip-restart 恢复被错误接受"
fi
grep -Fq '正在运行，不能使用 --skip-restart' "${TEST_ROOT}/restore-running-refused.log" \
  || fail "服务运行中的离线恢复没有清晰拒绝原因"
grep -Fq '临时 Prompt，恢复后应被替换。' "${DEPLOY_DIR}/config/prompt.md" \
  || fail "拒绝运行中恢复前已修改配置"

# 语法合法但不符合当前 schema 或边界的现代配置必须在候选区失败；
# 不能先覆盖活动配置，再依赖一个并未自动执行的安全备份恢复。
assert_invalid_restore_candidate_rejected() {
  local name=$1 expected=$2 stage="${TEST_ROOT}/restore-invalid-${1}-stage"
  local archive="${DEPLOY_DIR}/backups/legacy-v1-invalid-modern-${1}.tar.gz"
  local log="${TEST_ROOT}/restore-invalid-modern-${1}.log" before status=0
  mkdir -p -- "$stage"
  tar -xzf "$ARCHIVE" -C "$stage"
  case "$name" in
    handoff)
      printf '%s\n' '{"handoff":{"keywords":["人工"],"match_mode":"contains","resume_after_seconds":3600,"disable_ai":true,"notify_user":{"enabled":true}}}' \
        > "${stage}/config/handoff.yaml"
      ;;
    provider)
      printf '%s\n' '{"schema_version":2,"provider":{"type":"openai-compatible","base_url":"https://provider.invalid/v1","api_key_env":"AI_API_KEY","model":"","api_mode":"chat_completions"}}' \
        > "${stage}/config/provider.yaml"
      ;;
    prompt) : > "${stage}/config/prompt.md" ;;
    *) fail '损坏恢复候选夹具名称无效' ;;
  esac
  (
    cd -- "$stage"
    find . -type f ! -name 'checksums.sha256' -print0 | sort -z | xargs -0 sha256sum > checksums.sha256
  )
  tar -czf "$archive" -C "$stage" .
  before=$(find "${DEPLOY_DIR}/config" -maxdepth 1 -type f -print0 \
    | sort -z | xargs -0 sha256sum | sha256sum | cut -d ' ' -f 1)
  : > "$MOCK_DOCKER_LOG"
  env MOCK_DOCKER_NO_RUNNING=1 "${DEPLOY_DIR}/scripts/restore.sh" \
    --deploy-dir "$DEPLOY_DIR" --input "$archive" --skip-restart --no-safety-backup \
    > "$log" 2>&1 || status=$?
  (( status != 0 )) || fail "现代损坏 ${name} 被旧格式恢复错误接受"
  grep -Fq "$expected" "$log" || fail "现代损坏 ${name} 恢复未定位到候选校验"
  grep -Fq '尚未停止服务或覆盖现有资料' "$log" \
    || fail "现代损坏 ${name} 恢复未说明活动状态保持不变"
  [[ "$(find "${DEPLOY_DIR}/config" -maxdepth 1 -type f -print0 \
    | sort -z | xargs -0 sha256sum | sha256sum | cut -d ' ' -f 1)" == "$before" ]] \
    || fail "现代损坏 ${name} 恢复失败前已覆盖活动配置"
  if grep -Eq '(^| )(stop|up)( |$)' "$MOCK_DOCKER_LOG"; then
    fail "现代损坏 ${name} 候选预检失败后仍操作了服务"
  fi
}
assert_invalid_restore_candidate_rejected handoff 'handoff 配置格式或边界无效'
assert_invalid_restore_candidate_rejected provider '恢复包中的 provider 配置未通过候选校验'
assert_invalid_restore_candidate_rejected prompt 'Prompt 必须为 1～262144 个 UTF-8 字节'
pass '旧格式恢复先在候选区迁移并严格校验，现代损坏配置失败零活动修改'

RESTORE_PRECHECK_PROMPT_HASH=$(sha256sum "${DEPLOY_DIR}/config/prompt.md" | cut -d ' ' -f 1)
RESTORE_PRECHECK_MANIFEST_HASH=$(sha256sum "${DEPLOY_DIR}/data/knowledge-manifest.json" | cut -d ' ' -f 1)
assert_legacy_restore_preflight_rejected() {
  local label=$1 log="${TEST_ROOT}/restore-preflight-${1}.log"
  : > "$MOCK_DOCKER_LOG"
  if env MOCK_DOCKER_NO_RUNNING=1 "${DEPLOY_DIR}/scripts/restore.sh" \
    --deploy-dir "$DEPLOY_DIR" --input "$ARCHIVE" --skip-restart --no-safety-backup \
    > "$log" 2>&1; then
    fail "${label} 知识代次仍被旧格式恢复接受"
  fi
  [[ "$(sha256sum "${DEPLOY_DIR}/config/prompt.md" | cut -d ' ' -f 1)" == "$RESTORE_PRECHECK_PROMPT_HASH" ]] \
    || fail "${label} 预检失败前已覆盖 Prompt"
  [[ "$(sha256sum "${DEPLOY_DIR}/data/knowledge-manifest.json" | cut -d ' ' -f 1)" == "$RESTORE_PRECHECK_MANIFEST_HASH" ]] \
    || fail "${label} 预检失败前已覆盖知识 manifest"
  [[ ! -f "${DEPLOY_DIR}/knowledge/${RESTORE_KNOWLEDGE_PROJECTION}" ]] \
    || fail "${label} 预检失败前已恢复知识原文"
  if grep -Eq '(^| )stop( |$)' "$MOCK_DOCKER_LOG"; then
    fail "${label} 知识代次预检失败后仍停止服务"
  fi
}

cp -- "${DEPLOY_DIR}/data/runtime/knowledge-profile.json" "${TEST_ROOT}/restore-profile.safe.json"
PROFILE_TEMP=$(mktemp "${DEPLOY_DIR}/data/runtime/knowledge-profile.json.tmp.XXXXXXXX")
jq '.fingerprint = ("0" * 64)' "${TEST_ROOT}/restore-profile.safe.json" > "$PROFILE_TEMP"
chmod 0640 "$PROFILE_TEMP"
mv -f -- "$PROFILE_TEMP" "${DEPLOY_DIR}/data/runtime/knowledge-profile.json"
assert_legacy_restore_preflight_rejected profile-fingerprint
install -m 0640 -- "${TEST_ROOT}/restore-profile.safe.json" \
  "${DEPLOY_DIR}/data/runtime/knowledge-profile.json"

RESTORE_CACHE=$(find "${DEPLOY_DIR}/data/anythingllm/vector-cache" -maxdepth 1 -type f -links 1 \
  -print -quit)
[[ -n "$RESTORE_CACHE" && -f "$RESTORE_CACHE" && ! -L "$RESTORE_CACHE" ]] \
  || fail '缓存篡改恢复预检缺少受管向量缓存夹具'
cp -- "$RESTORE_CACHE" "${TEST_ROOT}/restore-cache.safe"
printf '{"tampered":true}\n' > "$RESTORE_CACHE"
assert_legacy_restore_preflight_rejected cache-binding
cp -- "${TEST_ROOT}/restore-cache.safe" "$RESTORE_CACHE"

printf '{"schema_version":1,"backup":"/invalid/migration"}\n' \
  > "${DEPLOY_DIR}/data/runtime/knowledge-migration.json"
chmod 0600 "${DEPLOY_DIR}/data/runtime/knowledge-migration.json"
assert_legacy_restore_preflight_rejected migration-pointer
unlink -- "${DEPLOY_DIR}/data/runtime/knowledge-migration.json"
pass '旧格式恢复在修改前拒绝坏 profile、缓存篡改与迁移残留，失败零资料修改'

# 其它实例在前面的正常旧布局场景中可以有资料；只允许当前实例发生变化。
RESTORE_OTHER_INSTANCES_BEFORE=$(jq -M -S -c --arg deploy "$DEPLOY_DIR" \
  '(.rag_instances // {}) | del(.[$deploy])' "$MOCK_ANYTHING_STATE")
RESTORE_EFFECTIVE_GENERATION_BEFORE=$(sha256sum \
  "${DEPLOY_DIR}/config/materials-applied.json" \
  "${DEPLOY_DIR}/backups/config-history/materials.applied.tar.gz" \
  "${DEPLOY_DIR}/data/knowledge-manifest.json" \
  "${DEPLOY_DIR}/data/runtime/knowledge-"{map,settings,profile,lexical}.json)
env MOCK_DOCKER_NO_RUNNING=1 "${DEPLOY_DIR}/scripts/restore.sh" \
  --deploy-dir "$DEPLOY_DIR" --input "$ARCHIVE" --skip-restart --no-safety-backup \
  > "${TEST_ROOT}/restore.log" 2>&1
[[ "$(sha256sum "${DEPLOY_DIR}/config/prompt.md" | awk '{print $1}')" == "$PROMPT_HASH" ]] || fail "Prompt 未恢复"
[[ -f "${DEPLOY_DIR}/knowledge/${RESTORE_KNOWLEDGE_PROJECTION}" ]] || fail "知识文件未恢复"
[[ "$(sha256sum "${DEPLOY_DIR}/.env" | awk '{print $1}')" == "$ENV_HASH_BEFORE" ]] || fail "恢复覆盖了 .env"
jq -e '.handoff.restore_test_extension.preserved == true' "${DEPLOY_DIR}/config/handoff.yaml" >/dev/null \
  || fail 'handoff 现代扩展字段在候选规范化中丢失'
jq -e '.provider.restore_test_extension.preserved == true' "${DEPLOY_DIR}/config/provider.yaml" >/dev/null \
  || fail 'provider 现代扩展字段在候选规范化中丢失'
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

# 旧格式离线恢复只安装原文，不伪造有效代或破坏下一次应用的旧代保全。
RESTORE_EFFECTIVE_GENERATION_AFTER=$(sha256sum \
  "${DEPLOY_DIR}/config/materials-applied.json" \
  "${DEPLOY_DIR}/backups/config-history/materials.applied.tar.gz" \
  "${DEPLOY_DIR}/data/knowledge-manifest.json" \
  "${DEPLOY_DIR}/data/runtime/knowledge-"{map,settings,profile,lexical}.json)
[[ "$RESTORE_EFFECTIVE_GENERATION_AFTER" == "$RESTORE_EFFECTIVE_GENERATION_BEFORE" ]] \
  || fail "离线业务恢复破坏上一有效资料代或知识元数据"
bash -c 'set -euo pipefail; source "$1/scripts/materials.sh"; materials_snapshot_validate_generation "$1" "$1/backups/config-history/materials.applied.tar.gz" "$1/config/materials-applied.json"' \
  -- "$DEPLOY_DIR" > "${TEST_ROOT}/post-offline-generation.log" 2>&1
POST_OFFLINE_STATUS=0
bash "${DEPLOY_DIR}/scripts/materials.sh" --deploy-dir "$DEPLOY_DIR" status \
  > "${TEST_ROOT}/post-offline-status.json" 2> "${TEST_ROOT}/post-offline-status.log" \
  || POST_OFFLINE_STATUS=$?
if (( POST_OFFLINE_STATUS != 2 )) || ! jq -e \
  '.source_valid == true and .projection_valid == true and .state == "applied" and .pending == true' \
  "${TEST_ROOT}/post-offline-status.json" >/dev/null; then
  fail "离线恢复原文未标明待应用，或上一有效投影已失效"
fi
grep -Fq '仅完成旧格式原文离线恢复' "${TEST_ROOT}/restore.log" \
  || fail "离线文件恢复被当成恢复原文已生效"
bash "${DEPLOY_DIR}/scripts/knowledge.sh" --deploy-dir "$DEPLOY_DIR" sync \
  > "${TEST_ROOT}/post-offline-restore-sync.log" 2>&1
jq -en --arg deploy "$DEPLOY_DIR" --argjson previous_others "$RESTORE_OTHER_INSTANCES_BEFORE" \
  --slurpfile catalog "${DEPLOY_DIR}/knowledge/catalog.json" \
  --slurpfile manifest "${DEPLOY_DIR}/data/knowledge-manifest.json" \
  --slurpfile actual "$MOCK_ANYTHING_STATE" '
    all($catalog[0].libraries[] | select(.enabled) | .documents[]; . as $document |
      $manifest[0].files[$document.projection].sha256 == $document.sha256 and
      ($manifest[0].files[$document.projection].locations | length > 0)) and
    ([$manifest[0].files[].locations[]] | unique | sort) ==
      (($actual[0].rag_instances[$deploy].documents // []) | unique | sort) and
    (($actual[0].rag_instances // {}) | del(.[$deploy])) == $previous_others
  ' >/dev/null || fail "离线恢复后正常回滚夹具未完成真实同步接口对账"
bash "${DEPLOY_DIR}/scripts/materials.sh" --deploy-dir "$DEPLOY_DIR" status \
  > "${TEST_ROOT}/post-offline-applied-status.json" 2> "${TEST_ROOT}/post-offline-applied-status.log"
jq -e '.source_valid == true and .projection_valid == true and .state == "applied" and .pending == false' \
  "${TEST_ROOT}/post-offline-applied-status.json" >/dev/null \
  || fail "离线恢复后的原文同步完成却未发布一致的有效资料代"

# 显式缺少受管投影的兼容夹具仍走旧映射失效分支；不删除主夹具的有效代。
LEGACY_NO_PROJECTION_DEPLOY="${TEST_ROOT}/legacy-no-materials"
cp -a -- "$DEPLOY_DIR" "$LEGACY_NO_PROJECTION_DEPLOY"
unlink -- "${LEGACY_NO_PROJECTION_DEPLOY}/config/materials-applied.json"
env MOCK_DOCKER_NO_RUNNING=1 "${PROJECT_ROOT}/scripts/restore.sh" \
  --deploy-dir "$LEGACY_NO_PROJECTION_DEPLOY" --input "$ARCHIVE" --skip-restart --no-safety-backup \
  > "${TEST_ROOT}/legacy-no-materials-restore.log" 2>&1
jq -e --slurpfile profile "${LEGACY_NO_PROJECTION_DEPLOY}/data/runtime/knowledge-profile.json" '
  .files == {} and .pending_files == {} and .garbage_locations == [] and
  .embedding_profile == $profile[0].fingerprint
' "${LEGACY_NO_PROJECTION_DEPLOY}/data/knowledge-manifest.json" >/dev/null \
  || fail "旧无投影兼容恢复未失效旧映射或丢失已验证的 Embedding 代次"
[[ ! -e "${LEGACY_NO_PROJECTION_DEPLOY}/config/materials-applied.json" ]] \
  || fail "旧兼容离线恢复未经回读伪造有效投影"
pass "离线业务恢复后同步并回读索引，再进入正常回滚验收"

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
bash -c 'set -euo pipefail; source "$1/scripts/common.sh"; write_installation_marker "$1" "$2" v0.6.9 local-ready' \
  -- "$DEPLOY_DIR" "$PROJECT_ROOT"
if "${DEPLOY_DIR}/update.sh" --deploy-dir "$DEPLOY_DIR" --source-dir "$PROJECT_ROOT" --no-pull \
  > "${TEST_ROOT}/update-capacity-failure.log" 2>&1; then
  fail "快照空间不足时更新被错误报告为成功"
fi
grep -Fq '版本快照空间不足' "${TEST_ROOT}/update-capacity-failure.log" || fail "更新未报告快照空间不足"
if grep -Eq '(^| )stop( |$)' "$MOCK_DOCKER_LOG"; then
  fail "容量预检失败后仍停止了服务"
fi
printf '%s\n' "$PROJECT_VERSION" > "${DEPLOY_DIR}/VERSION"
bash -c 'set -euo pipefail; source "$1/scripts/common.sh"; write_installation_marker "$1" "$2" "$3" local-ready' \
  -- "$DEPLOY_DIR" "$PROJECT_ROOT" "$PROJECT_VERSION"
bash -c 'set -euo pipefail; source "$1/scripts/common.sh"; env_set "$1/.env" SNAPSHOT_MIN_FREE_MB 0' \
  -- "$DEPLOY_DIR"
"${DEPLOY_DIR}/scripts/snapshot.sh" --deploy-dir "$DEPLOY_DIR" --check-capacity \
  > "${TEST_ROOT}/snapshot-capacity-success.log" 2>&1
grep -Fq '快照容量预检通过' "${TEST_ROOT}/snapshot-capacity-success.log" || fail "容量预检成功未输出依据"
pass "版本快照容量预检"

# 真实文件编辑路径允许标准 YAML；快照必须保留原文且不能只接受 JSON 子集。
python3 - "${DEPLOY_DIR}/config/handoff.yaml" <<'PY'
import json,pathlib,sys,yaml
file=pathlib.Path(sys.argv[1])
value=json.loads(file.read_text(encoding="utf-8"))
file.write_text(yaml.safe_dump(value,allow_unicode=True,sort_keys=False),encoding="utf-8")
PY
if jq empty "${DEPLOY_DIR}/config/handoff.yaml" >/dev/null 2>&1; then
  fail "手编 YAML 回滚夹具仍是 JSON，未覆盖原始故障"
fi
HANDOFF_YAML_HASH=$(sha256sum "${DEPLOY_DIR}/config/handoff.yaml" | cut -d ' ' -f 1)
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
[[ "$(sha256sum "${DEPLOY_DIR}/config/handoff.yaml" | cut -d ' ' -f 1)" == "$HANDOFF_YAML_HASH" ]] \
  || fail "手编 YAML 快照没有原样恢复"
SNAPSHOT_HISTORY=$("${DEPLOY_DIR}/scripts/rollback.sh" --deploy-dir "$DEPLOY_DIR" --list)
grep -Fq "$SNAPSHOT_ID" <<< "$SNAPSHOT_HISTORY" || fail "版本历史未列出快照"
grep -Fq '受保护快照使历史数量暂时超过保留上限' "${TEST_ROOT}/rollback.log" || fail "回滚目标未受保留策略保护"
pass "版本快照、手编 YAML 原文、AnythingLLM 数据与受保护手动回滚"

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
  chmod 0700 "$case_root"
  cp -a -- "${DEPLOY_DIR}/." "$case_deploy/"
  # 本例使用复制的真实夹具状态，但 API 接线只能指向本例；
  # 不携带原部署的同端口/同认证实例，也不从空 Prompt 伪造启动状态。
  python3 - "$MOCK_ANYTHING_STATE" "$DEPLOY_DIR" "$case_deploy" "${case_root}/anythingllm-state.json" <<'PY'
import copy
import json
import os
import pathlib
import sys

state_path, original, cloned, target = sys.argv[1:]
state = json.loads(pathlib.Path(state_path).read_text(encoding="utf-8"))
instance = copy.deepcopy(state["rag_instances"][original])
projection = json.loads((pathlib.Path(cloned) / "config/materials-applied.json").read_text(encoding="utf-8"))
manifest = json.loads((pathlib.Path(cloned) / "data/knowledge-manifest.json").read_text(encoding="utf-8"))
locations = sorted({location for document in manifest["files"].values() for location in document["locations"]})
assert instance["prompt"] == projection["prompt"]["text"]
assert sorted(instance["documents"]) == locations
state["rag_instances"] = {cloned: instance}
os.umask(0o077)
with pathlib.Path(target).open("x", encoding="utf-8") as output:
    output.write(json.dumps(state, ensure_ascii=False, sort_keys=True) + "\n")
PY
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
  # 拷贝的资料归属仍指向原实例；为本例登记独立调度后才注入数据库故障。
  "${case_deploy}/scripts/logs.sh" --deploy-dir "$case_deploy" timer install \
    > "${case_root}/timer.log" 2>&1
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
  grep -Eq " exec -T postgres .* ${failed_command}([[:space:]]|$)" "$MOCK_DOCKER_LOG" \
    || fail "未实际执行 ${failure_stage} 失败分支"
  failed_tail="${case_root}/failed-tail.log"
  awk -v command="$failed_command" '$0 ~ (" exec -T postgres .* " command "([[:space:]]|$)") { failed=1 } failed { print }' \
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

# 升级测试使用真正旧版程序和原生初始化，不只将新程序的 VERSION 改旧。
LEGACY_V121_ARCHIVE=${CRISPAI_TEST_V121_ARCHIVE:-}
LEGACY_V121_ARCHIVE_SHA256=${CRISPAI_TEST_V121_ARCHIVE_SHA256:-}
if [[ -n "$LEGACY_V121_ARCHIVE" && -z "$LEGACY_V121_ARCHIVE_SHA256" ]] \
  || [[ -z "$LEGACY_V121_ARCHIVE" && -n "$LEGACY_V121_ARCHIVE_SHA256" ]]; then
  fail 'CRISPAI_TEST_V121_ARCHIVE 与 CRISPAI_TEST_V121_ARCHIVE_SHA256 必须成对提供'
fi
if [[ -z "$LEGACY_V121_ARCHIVE" ]]; then
  [[ "$(git -C "$PROJECT_ROOT" rev-parse --verify 'v1.2.1^{commit}')" == 4b923d60233f48a37d545d3f345200cfa8161266 ]] \
    || fail '缺少固定真实 v1.2.1 提交；须提供受控源码归档及摘要'
  LEGACY_V121_ARCHIVE="${TEST_ROOT}/v1.2.1-source.tar"
  git -C "$PROJECT_ROOT" archive --format=tar --output "$LEGACY_V121_ARCHIVE" v1.2.1
  chmod 0600 "$LEGACY_V121_ARCHIVE"
  read -r LEGACY_V121_ARCHIVE_SHA256 _ < <(sha256sum -- "$LEGACY_V121_ARCHIVE")
fi
LEGACY_V121_SOURCE="${TEST_ROOT}/v1.2.1-source"
LEGACY_V121_MOCK_DIR="${TEST_ROOT}/legacy-v121-mocks"
mkdir -m 0700 -- "$LEGACY_V121_SOURCE"
python3 "${SCRIPT_DIR}/extract_legacy_source.py" --archive "$LEGACY_V121_ARCHIVE" \
  --sha256 "$LEGACY_V121_ARCHIVE_SHA256" --destination "$LEGACY_V121_SOURCE" \
  --expected-version v1.2.1 || fail '真实 v1.2.1 源码校验或提取失败'
# 旧夹具按自身文件位置定位 SOURCE；原字节复制，不放宽其路径/权限约束。
cp -a -- "${LEGACY_V121_SOURCE}/tests/mocks" "$LEGACY_V121_MOCK_DIR"
# 原版夹具只有全局 Prompt；给原生旧版初始化独立服务状态，避免污染其他实例。
LEGACY_V121_ANYTHING_STATE="${TEST_ROOT}/legacy-v121-anythingllm-state.json"
printf '{"documents":[]}\n' > "$LEGACY_V121_ANYTHING_STATE"
LEGACY_V130_SAVED_DEPLOY="${TEST_ROOT}/before-legacy-v121-deploy"
[[ ! -e "$LEGACY_V130_SAVED_DEPLOY" && ! -L "$LEGACY_V130_SAVED_DEPLOY" ]] \
  || fail '旧版基线的原测试实例保全目标已存在'
mv -- "$DEPLOY_DIR" "$LEGACY_V130_SAVED_DEPLOY"
expect_local_ready_install env \
  PATH="${TEST_ROOT}/bin:${LEGACY_V121_MOCK_DIR}:${ORIGINAL_PATH}" \
  MOCK_ANYTHING_STATE="$LEGACY_V121_ANYTHING_STATE" \
  MOCK_PROJECT_DIR="$DEPLOY_DIR" MOCK_DOCKER_STRICT_CONFIG=1 \
  AI_API_BASE_URL=https://provider.invalid AI_API_KEY="$TEST_PROVIDER_KEY" \
  AI_MODEL=gpt-vision-test AI_SUPPORTS_VISION=true \
  CRISP_WEBSITE_ID=11111111-1111-1111-1111-111111111111 CRISP_TOKEN_TIER=website \
  CRISP_TOKEN_IDENTIFIER=test-only-identifier CRISP_TOKEN_KEY="$TEST_CRISP_KEY" \
  ANYTHINGLLM_API_KEY="$TEST_ANYTHING_KEY" N8N_HOST=support.example.invalid \
  PUBLIC_WEBHOOK_URL=https://support.example.invalid/ TIMEZONE=UTC \
  "${LEGACY_V121_SOURCE}/install.sh" --deploy-dir "$DEPLOY_DIR" \
  --command-path "${TEST_ROOT}/bin/crispai" --non-interactive \
  > "${TEST_ROOT}/legacy-v121-install.log" 2>&1
# 仅移入原测试的业务原文与知识；不复制新代 .env、marker、有效投影或运行回执。
for business_file in runtime.yaml handoff.yaml keyword.yaml menu.yaml tags.yaml feedback.yaml prompt.md logging.yaml; do
  assert_file "${LEGACY_V130_SAVED_DEPLOY}/config/${business_file}"
  cp -a -- "${LEGACY_V130_SAVED_DEPLOY}/config/${business_file}" "${DEPLOY_DIR}/config/${business_file}"
done
cp -a -- "${LEGACY_V130_SAVED_DEPLOY}/knowledge/." "${DEPLOY_DIR}/knowledge/"
env PATH="${TEST_ROOT}/bin:${LEGACY_V121_MOCK_DIR}:${ORIGINAL_PATH}" \
  MOCK_ANYTHING_STATE="$LEGACY_V121_ANYTHING_STATE" \
  MOCK_PROJECT_DIR="$DEPLOY_DIR" "${DEPLOY_DIR}/scripts/materials.sh" --deploy-dir "$DEPLOY_DIR" apply \
  > "${TEST_ROOT}/legacy-v121-business-apply.log" 2>&1
for legacy_program in install.sh update.sh scripts/common.sh scripts/materials.sh n8n/runtime.js; do
  cmp -s -- "${LEGACY_V121_SOURCE}/${legacy_program}" "${DEPLOY_DIR}/${legacy_program}" \
    || fail "旧版基线程序不是固定源码原字节：${legacy_program}"
done
[[ "$(<"${DEPLOY_DIR}/VERSION")" == v1.2.1 ]] || fail '旧版基线 VERSION 不符'
jq -e '.schema_version == 1 and .state == "applied"' "${DEPLOY_DIR}/config/materials-applied.json" \
  >/dev/null || fail '旧版原生初始化或业务应用没有形成 schema1 applied 投影'
assert_file "${DEPLOY_DIR}/backups/config-history/materials.applied.tar.gz"
# 将旧版实际应用的 Prompt 精确绑定回当前实例；其他实例和歧义拒绝合同不变。
python3 - "$MOCK_ANYTHING_STATE" "$LEGACY_V121_ANYTHING_STATE" "$DEPLOY_DIR" "$TEST_ROOT" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import stat
import sys

active, legacy, project, scope = map(Path, sys.argv[1:])
for path in (active, legacy):
    info = path.lstat()
    if path.parent != scope or path.is_symlink() or not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) != 0o600:
        raise SystemExit(1)
original = json.loads(active.read_bytes())
old = json.loads(legacy.read_bytes())
key = str(project)
instances = original['rag_instances']
if not isinstance(instances, dict) or key not in instances or 'prompt' in original:
    raise SystemExit(1)
prompt = old['prompt']
if not isinstance(prompt, str) or len(prompt.encode('utf-8')) > 256 * 1024:
    raise SystemExit(1)
unchanged = {name:value for name,value in instances.items() if name != key}
unchanged_hash = hashlib.sha256(json.dumps(unchanged, sort_keys=True).encode()).hexdigest()
instances[key]['prompt'] = prompt
active.write_text(json.dumps(original, ensure_ascii=False, sort_keys=True) + '\n')
observed = json.loads(active.read_bytes())
if observed['rag_instances'][key]['prompt'] != prompt or 'prompt' in observed or hashlib.sha256(json.dumps({name:value for name,value in observed['rag_instances'].items() if name != key}, sort_keys=True).encode()).hexdigest() != unchanged_hash:
    raise SystemExit(1)
PY
env MOCK_PROJECT_DIR="$DEPLOY_DIR" "${MOCK_DIR}/docker" compose \
  --project-directory "$DEPLOY_DIR" --env-file "${DEPLOY_DIR}/.env" \
  -f "${DEPLOY_DIR}/docker-compose.yml" up -d anythingllm
printf '升级基线：固定真实 v1.2.1 程序、原生 schema1 投影和保留的业务原文。\n'
sed -i '/^SNAPSHOT_MIN_FREE_MB=/d; /^SNAPSHOT_RETENTION_COUNT=/d; /^PROVIDER_ADAPTER_KEY=/d; /^CRISPAI_LOG_RETENTION_HOURS=/d' \
  "${DEPLOY_DIR}/.env"
UPDATE_SERVICE_STATE="${TEST_ROOT}/update-running-services"
printf 'postgres\nanythingllm\nn8n\nprovider-adapter\n' > "$UPDATE_SERVICE_STATE"
export MOCK_DOCKER_SERVICE_STATE="$UPDATE_SERVICE_STATE"

# pull 仍在 marker 或配置变更之前；该阶段失败只清理同次 journal，不做无谓回滚。
if env MOCK_DOCKER_FAIL_PULL=1 MOCK_EXPECT_PREFLIGHT_ENV_KEY=PROVIDER_ADAPTER_KEY \
  MOCK_EXPECT_PREFLIGHT_ENV_KEY_SECONDARY=CRISPAI_LOG_RETENTION_HOURS \
  "${PROJECT_ROOT}/update.sh" \
  --deploy-dir "$DEPLOY_DIR" --source-dir "$PROJECT_ROOT" --no-pull \
  > "${TEST_ROOT}/update-rollback.log" 2>&1; then
  fail "镜像拉取失败时更新被错误报告为成功"
fi
[[ "$(<"${DEPLOY_DIR}/VERSION")" == v1.2.1 ]] || fail "pull失败改写了旧版本"
grep -Fq '程序与服务未改变；维护默认值可能已补齐，未执行无谓版本回滚' "${TEST_ROOT}/update-rollback.log" \
  || fail '业务代际修改前失败未走无回滚分支'
[[ ! -e "${DEPLOY_DIR}/backups/update-recovery.json" \
  && ! -L "${DEPLOY_DIR}/backups/update-recovery.json" ]] \
  || fail '业务代际修改前失败遗留了恢复 journal'
[[ -z "$(find "${DEPLOY_DIR}/tmp" -mindepth 1 -maxdepth 1 -type d -name 'update-preflight-*' -print -quit)" ]] \
  || fail 'pull失败遗留了候选Compose临时环境目录'
! grep -Eq '^(PROVIDER_ADAPTER_KEY|CRISPAI_LOG_RETENTION_HOURS)=' "${DEPLOY_DIR}/.env" \
  || fail 'pull失败把临时迁移的内部Key或缺省值发布到活动环境'
[[ "$(sed -n 's/^SNAPSHOT_MIN_FREE_MB=//p' "${DEPLOY_DIR}/.env")" == 1024 ]] || fail "旧部署未补齐快照预留空间"
[[ "$(sed -n 's/^SNAPSHOT_RETENTION_COUNT=//p' "${DEPLOY_DIR}/.env")" == 10 ]] || fail "旧部署未补齐快照保留数量"
# 这里只重建后续场景的夹具基线；不把测试主动补值冒充为上一个失败更新的行为。
bash -c 'set -euo pipefail; source "$1/scripts/common.sh"; ensure_secret "$1/.env" PROVIDER_ADAPTER_KEY; env_set "$1/.env" CRISPAI_LOG_RETENTION_HOURS 168' \
  -- "$DEPLOY_DIR"
pass "更新在业务代际修改前失败不做无谓回滚"

wait_for_update_gate() {
  local ready=$1 child=$2 deadline=$((SECONDS + 30))
  while [[ ! -f "$ready" ]]; do
    kill -0 "$child" 2>/dev/null || fail '更新在到达硬中断门前提前退出'
    (( SECONDS < deadline )) || fail '更新硬中断门未在预算内到达'
    sleep 0.05
  done
  [[ ! -L "$ready" && "$(stat -c '%a:%h:%u' -- "$ready")" == "600:1:${EUID}" ]] \
    || fail '更新硬中断门身份不安全'
}

copy_release_source_fixture() {
  local destination=$1 release_path
  mkdir -m 0700 -- "$destination"
  while IFS= read -r release_path; do
    [[ -n "$release_path" && "$release_path" != \#* ]] || continue
    release_path=${release_path//@VERSION@/$PROJECT_VERSION}
    mkdir -p -- "${destination}/$(dirname -- "$release_path")"
    cp -a -- "${PROJECT_ROOT}/${release_path}" "${destination}/${release_path}"
  done < "${PROJECT_ROOT}/scripts/release-manifest.txt"
}

assert_next_update_cleans_orphans() {
  local label=$1 invalid_source="${TEST_ROOT}/invalid-update-source"
  shift
  mkdir -p -- "$invalid_source"
  if "${PROJECT_ROOT}/update.sh" --deploy-dir "$DEPLOY_DIR" --source-dir "$invalid_source" --no-pull \
    > "${TEST_ROOT}/${label}-orphan-cleanup.log" 2>&1; then
    fail "${label}孤儿收敛入口错误接受了不完整source"
  fi
  for orphan in "$@"; do
    [[ ! -e "$orphan" && ! -L "$orphan" ]] || fail "${label}下一入口未清理严格归属孤儿：$orphan"
  done
  [[ ! -e "${DEPLOY_DIR}/backups/update-recovery.json" ]] \
    || fail "${label}孤儿收敛错误创建了正式journal"
}

kill_update_group_at_gate() {
  local ready=$1 log=$2 child group own_group status deadline
  shift 2
  setsid env "$@" "${PROJECT_ROOT}/update.sh" \
    --deploy-dir "$DEPLOY_DIR" --source-dir "$PROJECT_ROOT" --no-pull > "$log" 2>&1 &
  child=$!
  wait_for_update_gate "$ready" "$child"
  group=$(ps -o pgid= -p "$child" | tr -d ' ')
  own_group=$(ps -o pgid= -p $$ | tr -d ' ')
  [[ "$group" =~ ^[1-9][0-9]*$ && "$group" == "$child" && "$group" != "$own_group" ]] \
    || fail '拒绝向未经核验的独立更新进程组发送SIGKILL'
  kill -KILL -- "-$group"
  if wait "$child"; then status=0; else status=$?; fi
  (( status == 137 )) || fail "硬中断更新退出码异常：${status}"
  deadline=$((SECONDS + 10))
  while kill -0 -- "-$group" 2>/dev/null; do
    (( SECONDS < deadline )) || fail '硬中断更新进程组未完全退出'
    sleep 0.05
  done
}

resume_pre_mutation_update() {
  local label=$1 journal="${DEPLOY_DIR}/backups/update-recovery.json" token snapshot candidate
  local marker_hash=$2 env_hash=$3 version_hash=$4 services_hash=$5
  token=$(jq -r '.token' "$journal")
  snapshot=$(jq -r '.snapshot_id' "$journal")
  candidate=$(jq -r '.source_candidate_dir' "$journal")
  : > "$MOCK_DOCKER_LOG"
  CRISP_AI_FAILED_UPDATE_TOKEN="$token" "${candidate}/scripts/rollback.sh" \
    --deploy-dir "$DEPLOY_DIR" --snapshot "$snapshot" --failed-update-recovery \
    > "${TEST_ROOT}/update-${label}-resume.log" 2>&1
  [[ ! -e "$journal" && ! -L "$journal" \
    && ! -e "$candidate" && ! -L "$candidate" \
    && "$(sha256sum "${DEPLOY_DIR}/.crisp-ai-installation" | awk '{print $1}')" == "$marker_hash" \
    && "$(sha256sum "${DEPLOY_DIR}/.env" | awk '{print $1}')" == "$env_hash" \
    && "$(sha256sum "${DEPLOY_DIR}/VERSION" | awk '{print $1}')" == "$version_hash" \
    && "$(sort "$UPDATE_SERVICE_STATE" | sha256sum | awk '{print $1}')" == "$services_hash" ]] \
    || fail "${label}硬中断未按原marker收口journal/冻结候选"
  [[ -z "$(find "${DEPLOY_DIR}/tmp" -mindepth 1 -maxdepth 1 -name 'update-preflight-*' -print -quit)" ]] \
    || fail "${label}硬中断后遗留token绑定preflight目录"
  ! grep -Eq '(^| )stop( |$)' "$MOCK_DOCKER_LOG" \
    || fail "${label}pre-mutation收口错误停止业务服务"
  ! grep -Eq '(^| )(pg_restore|pg_dump)( |$)' "$MOCK_DOCKER_LOG" \
    || fail "${label}pre-mutation收口错误读取或恢复版本快照"
}

UPDATE_GATE_BIN="${TEST_ROOT}/update-phase-gate-bin"
UPDATE_REAL_MKTEMP=$(command -v mktemp)
UPDATE_REAL_SYNC=$(command -v sync)
UPDATE_REAL_DF=$(command -v df)
mkdir -m 0700 -- "$UPDATE_GATE_BIN"
# 变量由生成的故障注入 mock 运行时展开，父测试 shell 不得提前展开。
# shellcheck disable=SC2016
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'real=${MOCK_UPDATE_REAL_MKTEMP:?}' \
  'journal=${MOCK_UPDATE_JOURNAL_PATH:?}' \
  'marker=${MOCK_UPDATE_MARKER_PATH:?}' \
  'ready=${MOCK_UPDATE_PHASE_READY:?}' \
  'release=${MOCK_UPDATE_PHASE_RELEASE:?}' \
  'template=${1:-}' \
  'if [[ "${MOCK_UPDATE_PHASE_GATE_KIND:-}" == helper-write && "$template" == "${MOCK_UPDATE_HELPER_TEMPLATE:?}" ]]; then' \
  '  created=$("$real" "$@")' \
  '  [[ ! -e "$ready" && ! -L "$ready" && ! -L "$release" ]] || exit 2' \
  '  : > "$ready"; chmod 0600 "$ready"' \
  '  while [[ ! -f "$release" ]]; do sleep 0.05; done' \
  '  printf '\''%s\n'\'' "$created"' \
  '  exit 0' \
  'fi' \
  'if [[ "${MOCK_UPDATE_PHASE_GATE_KIND:-}" == before-marker && "$template" == "${marker}.tmp.XXXXXX" && -f "$journal" && ! -L "$journal" ]] &&' \
  '  jq -e '\''.phase == "recovery_armed"'\'' "$journal" >/dev/null 2>&1; then' \
  '  [[ ! -e "$ready" && ! -L "$ready" && ! -L "$release" ]] || exit 2' \
  '  : > "$ready"; chmod 0600 "$ready"' \
  '  while [[ ! -f "$release" ]]; do sleep 0.05; done' \
  'fi' \
  'exec "$real" "$@"' > "${UPDATE_GATE_BIN}/mktemp"
chmod 0700 "${UPDATE_GATE_BIN}/mktemp"
# 变量由生成的故障注入 mock 运行时展开，父测试 shell 不得提前展开。
# shellcheck disable=SC2016
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'real=${MOCK_UPDATE_REAL_SYNC:?}' \
  'journal=${MOCK_UPDATE_JOURNAL_PATH:?}' \
  'marker=${MOCK_UPDATE_MARKER_PATH:?}' \
  'ready=${MOCK_UPDATE_PHASE_READY:?}' \
  'release=${MOCK_UPDATE_PHASE_RELEASE:?}' \
  'if (( $# == 2 )) && [[ "${MOCK_UPDATE_PHASE_GATE_KIND:-}" == journal-eexist && "$1" == -f' \
  '  && "$2" == "${journal}.tmp."* && ! -e "$journal" && ! -L "$journal" ]]; then' \
  '  "$real" "$@"' \
  '  printf '\''{"foreign":true}\n'\'' > "$journal"; chmod 0600 "$journal"' \
  '  exit 0' \
  'fi' \
  'if (( $# == 2 )) && [[ "${MOCK_UPDATE_PHASE_GATE_KIND:-}" == journal-temp && "$1" == -f &&' \
  '  "$2" == "${journal}.tmp."* && ! -e "$journal" && ! -L "$journal" ]]; then' \
  '  "$real" "$@"' \
  '  [[ ! -e "$ready" && ! -L "$ready" && ! -L "$release" ]] || exit 2' \
  '  : > "$ready"; chmod 0600 "$ready"' \
  '  while [[ ! -f "$release" ]]; do sleep 0.05; done' \
  '  exit 0' \
  'fi' \
  'if (( $# == 2 )) && [[ "${MOCK_UPDATE_PHASE_GATE_KIND:-}" == after-marker && "$1" == -f && "$2" == "$marker" && -f "$journal" && ! -L "$journal" ]] &&' \
  '  jq -e '\''.phase == "recovery_armed"'\'' "$journal" >/dev/null 2>&1; then' \
  '  [[ ! -e "$ready" && ! -L "$ready" && ! -L "$release" ]] || exit 2' \
  '  : > "$ready"; chmod 0600 "$ready"' \
  '  while [[ ! -f "$release" ]]; do sleep 0.05; done' \
  'fi' \
  'exec "$real" "$@"' > "${UPDATE_GATE_BIN}/sync"
chmod 0700 "${UPDATE_GATE_BIN}/sync"
# 变量由生成的故障注入 mock 运行时展开，父测试 shell 不得提前展开。
# shellcheck disable=SC2016
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'real=${MOCK_UPDATE_REAL_DF:?}' \
  'ready=${MOCK_UPDATE_PHASE_READY:?}' \
  'release=${MOCK_UPDATE_PHASE_RELEASE:?}' \
  'backups=${MOCK_UPDATE_BACKUPS_DIR:?}' \
  'journal=${MOCK_UPDATE_JOURNAL_PATH:?}' \
  'if [[ "${MOCK_UPDATE_PHASE_GATE_KIND:-}" == candidate-published && ! -e "$journal" && ! -L "$journal" ]] &&' \
  '  compgen -G "${backups}/update-candidate-*" >/dev/null; then' \
  '  [[ ! -e "$ready" && ! -L "$ready" && ! -L "$release" ]] || exit 2' \
  '  : > "$ready"; chmod 0600 "$ready"' \
  '  while [[ ! -f "$release" ]]; do sleep 0.05; done' \
  'fi' \
  'exec "$real" "$@"' > "${UPDATE_GATE_BIN}/df"
chmod 0700 "${UPDATE_GATE_BIN}/df"

# journal 尚未正式发布前的三类真实 SIGKILL 必须由下一次受管 update 入口自行收敛。
ORPHAN_COPY_SOURCE="${TEST_ROOT}/orphan-copy-source"
copy_release_source_fixture "$ORPHAN_COPY_SOURCE"
truncate -s 268435456 "${ORPHAN_COPY_SOURCE}/tests/fixtures/logs/systemctl"
ORPHAN_COPY_LOG="${TEST_ROOT}/orphan-copy.log"
setsid "${PROJECT_ROOT}/update.sh" --deploy-dir "$DEPLOY_DIR" --source-dir "$ORPHAN_COPY_SOURCE" --no-pull \
  > "$ORPHAN_COPY_LOG" 2>&1 &
ORPHAN_COPY_CHILD=$!
ORPHAN_DEADLINE=$((SECONDS + 30))
ORPHAN_COPY_PATH=''
while [[ -z "$ORPHAN_COPY_PATH" ]]; do
  kill -0 "$ORPHAN_COPY_CHILD" 2>/dev/null || fail 'candidate复制中断门前update提前退出'
  ORPHAN_COPY_PATH=$(find "${DEPLOY_DIR}/backups" -mindepth 1 -maxdepth 1 -type d \
    -name '.update-candidate-*.tmp' -print -quit)
  (( SECONDS < ORPHAN_DEADLINE )) || fail '未观察到candidate复制临时目录'
  [[ -n "$ORPHAN_COPY_PATH" ]] || sleep 0.01
done
ORPHAN_COPY_GROUP=$(ps -o pgid= -p "$ORPHAN_COPY_CHILD" | tr -d ' ')
ORPHAN_OWN_GROUP=$(ps -o pgid= -p $$ | tr -d ' ')
[[ "$ORPHAN_COPY_GROUP" == "$ORPHAN_COPY_CHILD" && "$ORPHAN_COPY_GROUP" != "$ORPHAN_OWN_GROUP" ]] \
  || fail 'candidate复制中断进程组身份不安全'
kill -KILL -- "-$ORPHAN_COPY_GROUP"
if wait "$ORPHAN_COPY_CHILD"; then ORPHAN_COPY_STATUS=0; else ORPHAN_COPY_STATUS=$?; fi
(( ORPHAN_COPY_STATUS == 137 )) || fail 'candidate复制中断未得到SIGKILL状态'
ORPHAN_DEADLINE=$((SECONDS + 10))
while kill -0 -- "-$ORPHAN_COPY_GROUP" 2>/dev/null; do
  (( SECONDS < ORPHAN_DEADLINE )) || fail 'candidate复制中断进程组未完全退出'
  sleep 0.05
done
assert_next_update_cleans_orphans candidate-copy "$ORPHAN_COPY_PATH"
rm -rf -- "$ORPHAN_COPY_SOURCE"

for orphan_stage in candidate-published journal-temp; do
  ORPHAN_READY="${TEST_ROOT}/${orphan_stage}.ready"
  ORPHAN_RELEASE="${TEST_ROOT}/${orphan_stage}.release"
  ORPHAN_LOG="${TEST_ROOT}/${orphan_stage}.log"
  rm -f -- "$ORPHAN_READY" "$ORPHAN_RELEASE"
  case "$orphan_stage" in
    candidate-published)
      kill_update_group_at_gate "$ORPHAN_READY" "$ORPHAN_LOG" \
        PATH="${UPDATE_GATE_BIN}:${PATH}" MOCK_UPDATE_REAL_DF="$UPDATE_REAL_DF" \
        MOCK_UPDATE_REAL_MKTEMP="$UPDATE_REAL_MKTEMP" MOCK_UPDATE_REAL_SYNC="$UPDATE_REAL_SYNC" \
        MOCK_UPDATE_PHASE_READY="$ORPHAN_READY" MOCK_UPDATE_PHASE_RELEASE="$ORPHAN_RELEASE" \
        MOCK_UPDATE_BACKUPS_DIR="${DEPLOY_DIR}/backups" \
        MOCK_UPDATE_JOURNAL_PATH="${DEPLOY_DIR}/backups/update-recovery.json" \
        MOCK_UPDATE_MARKER_PATH="${DEPLOY_DIR}/.crisp-ai-installation" \
        MOCK_UPDATE_PHASE_GATE_KIND=candidate-published
      ORPHAN_PATH=$(find "${DEPLOY_DIR}/backups" -mindepth 1 -maxdepth 1 -type d \
        -name 'update-candidate-*' -print -quit)
      ;;
    journal-temp)
      kill_update_group_at_gate "$ORPHAN_READY" "$ORPHAN_LOG" \
        PATH="${UPDATE_GATE_BIN}:${PATH}" MOCK_UPDATE_REAL_SYNC="$UPDATE_REAL_SYNC" \
        MOCK_UPDATE_REAL_MKTEMP="$UPDATE_REAL_MKTEMP" \
        MOCK_UPDATE_REAL_DF="$UPDATE_REAL_DF" MOCK_UPDATE_BACKUPS_DIR="${DEPLOY_DIR}/backups" \
        MOCK_UPDATE_JOURNAL_PATH="${DEPLOY_DIR}/backups/update-recovery.json" \
        MOCK_UPDATE_MARKER_PATH="${DEPLOY_DIR}/.crisp-ai-installation" \
        MOCK_UPDATE_PHASE_READY="$ORPHAN_READY" MOCK_UPDATE_PHASE_RELEASE="$ORPHAN_RELEASE" \
        MOCK_UPDATE_PHASE_GATE_KIND=journal-temp
      ORPHAN_PATH=$(find "${DEPLOY_DIR}/backups" -mindepth 1 -maxdepth 1 -type f \
        -name 'update-recovery.json.tmp.*' -print -quit)
      ;;
  esac
  [[ -n "$ORPHAN_PATH" && ! -e "${DEPLOY_DIR}/backups/update-recovery.json" ]] \
    || fail "${orphan_stage}硬中断落点不精确"
  ORPHAN_CANDIDATE=$(find "${DEPLOY_DIR}/backups" -mindepth 1 -maxdepth 1 -type d \
    -name 'update-candidate-*' -print -quit)
  [[ -n "$ORPHAN_CANDIDATE" ]] || fail "${orphan_stage}未保留对应冻结candidate"
  assert_next_update_cleans_orphans "$orphan_stage" "$ORPHAN_PATH" "$ORPHAN_CANDIDATE"
done
pass 'candidate复制/发布及journal-temp三类无journal SIGKILL孤儿由下一入口持久收敛'

EMPTY_JOURNAL_TEMP="${DEPLOY_DIR}/backups/update-recovery.json.tmp.$(printf 'a%.0s' {1..64}).ABC123"
TRUNCATED_JOURNAL_TEMP="${DEPLOY_DIR}/backups/update-recovery.json.tmp.$(printf 'b%.0s' {1..64}).DEF456"
: > "$EMPTY_JOURNAL_TEMP"
printf '{"schema_version":' > "$TRUNCATED_JOURNAL_TEMP"
chmod 0600 "$EMPTY_JOURNAL_TEMP" "$TRUNCATED_JOURNAL_TEMP"
assert_next_update_cleans_orphans partial-journal-temp "$EMPTY_JOURNAL_TEMP" "$TRUNCATED_JOURNAL_TEMP"

# 候选清理中断后可只剩混合0500/0700目录和部分400/600文件；下一入口
# 按partial合同继续，不再要求完整manifest。
INTERRUPTED_CLEANUP_TOKEN=$(printf 'c%.0s' {1..64})
INTERRUPTED_CLEANUP="${DEPLOY_DIR}/backups/.update-candidate-${INTERRUPTED_CLEANUP_TOKEN}.tmp"
mkdir -m 0700 -- "$INTERRUPTED_CLEANUP" "$INTERRUPTED_CLEANUP/remaining"
printf 'partial-cleanup\n' > "$INTERRUPTED_CLEANUP/remaining/member"
chmod 0500 "$INTERRUPTED_CLEANUP/remaining"
chmod 0400 "$INTERRUPTED_CLEANUP/remaining/member"
assert_next_update_cleans_orphans interrupted-candidate-cleanup "$INTERRUPTED_CLEANUP"

UNSAFE_CLEANUP_TOKEN=$(printf 'd%.0s' {1..64})
UNSAFE_CLEANUP="${DEPLOY_DIR}/backups/.update-candidate-${UNSAFE_CLEANUP_TOKEN}.tmp"
mkdir -m 0700 -- "$UNSAFE_CLEANUP"
ln -s -- /etc/passwd "$UNSAFE_CLEANUP/foreign-link"
if "${PROJECT_ROOT}/update.sh" --deploy-dir "$DEPLOY_DIR" --source-dir "${TEST_ROOT}/invalid-update-source" --no-pull \
  > "${TEST_ROOT}/unsafe-candidate-cleanup.log" 2>&1; then
  fail '含链接的candidate partial被错误清理并继续更新'
fi
[[ -L "$UNSAFE_CLEANUP/foreign-link" ]] || fail '不安全candidate partial被猜测删除'
rm -rf -- "$UNSAFE_CLEANUP"
sync -f "${DEPLOY_DIR}/backups"

JOURNAL_EEXIST_READY="${TEST_ROOT}/journal-eexist.ready-unused"
JOURNAL_EEXIST_RELEASE="${TEST_ROOT}/journal-eexist.release-unused"
if env PATH="${UPDATE_GATE_BIN}:${PATH}" MOCK_UPDATE_REAL_SYNC="$UPDATE_REAL_SYNC" \
  MOCK_UPDATE_REAL_MKTEMP="$UPDATE_REAL_MKTEMP" MOCK_UPDATE_REAL_DF="$UPDATE_REAL_DF" \
  MOCK_UPDATE_BACKUPS_DIR="${DEPLOY_DIR}/backups" \
  MOCK_UPDATE_JOURNAL_PATH="${DEPLOY_DIR}/backups/update-recovery.json" \
  MOCK_UPDATE_MARKER_PATH="${DEPLOY_DIR}/.crisp-ai-installation" \
  MOCK_UPDATE_PHASE_READY="$JOURNAL_EEXIST_READY" MOCK_UPDATE_PHASE_RELEASE="$JOURNAL_EEXIST_RELEASE" \
  MOCK_UPDATE_PHASE_GATE_KIND=journal-eexist \
  "${PROJECT_ROOT}/update.sh" --deploy-dir "$DEPLOY_DIR" --source-dir "$PROJECT_ROOT" --no-pull \
  > "${TEST_ROOT}/journal-eexist.log" 2>&1; then
  fail 'renameat2 EEXIST竞态被错误报告为更新成功'
fi
[[ "$(<"${DEPLOY_DIR}/backups/update-recovery.json")" == '{"foreign":true}' ]] \
  || fail 'renameat2 EEXIST覆盖了并发出现的journal目标'
[[ -z "$(find "${DEPLOY_DIR}/backups" -mindepth 1 -maxdepth 1 \
  \( -name 'update-candidate-*' -o -name '.update-candidate-*.tmp' -o -name 'update-recovery.json.tmp.*' \) \
  -print -quit)" ]] || fail 'renameat2 EEXIST失败后遗留了本轮candidate/temp'
rm -f -- "${DEPLOY_DIR}/backups/update-recovery.json"
sync -f "${DEPLOY_DIR}/backups"
pass '空/截断journal temp可受限收敛且renameat2 EEXIST不覆盖并发目标'

for early_phase in prepared recovery-armed-old-marker recovery-armed-installing-marker; do
  EARLY_READY="${TEST_ROOT}/update-${early_phase}.ready"
  EARLY_RELEASE="${TEST_ROOT}/update-${early_phase}.release"
  EARLY_LOG="${TEST_ROOT}/update-${early_phase}.log"
  rm -f -- "$EARLY_READY" "$EARLY_RELEASE"
  EARLY_MARKER_HASH=$(sha256sum "${DEPLOY_DIR}/.crisp-ai-installation" | awk '{print $1}')
  EARLY_ENV_HASH=$(sha256sum "${DEPLOY_DIR}/.env" | awk '{print $1}')
  EARLY_VERSION_HASH=$(sha256sum "${DEPLOY_DIR}/VERSION" | awk '{print $1}')
  EARLY_SERVICES_HASH=$(sort "$UPDATE_SERVICE_STATE" | sha256sum | awk '{print $1}')
  : > "$MOCK_DOCKER_LOG"
  case "$early_phase" in
    prepared)
      kill_update_group_at_gate "$EARLY_READY" "$EARLY_LOG" \
        MOCK_UPDATE_PULL_GATE_READY="$EARLY_READY" MOCK_UPDATE_PULL_GATE_RELEASE="$EARLY_RELEASE"
      [[ "$(jq -r '.phase' "${DEPLOY_DIR}/backups/update-recovery.json")" == prepared ]] \
        || fail 'prepared硬中断没有保留prepared journal'
      [[ "$(stat -c '%a:%h:%u' "${DEPLOY_DIR}/backups/update-recovery.json")" == "600:1:${EUID}" ]] \
        || fail 'prepared硬中断journal不是0600普通单链接文件'
      [[ -z "$(find "${DEPLOY_DIR}/backups" -maxdepth 1 -name 'update-recovery.json.tmp.*' -print -quit)" ]] \
        || fail '原子no-clobber发布后仍有journal临时链接'
      ;;
    recovery-armed-old-marker)
      kill_update_group_at_gate "$EARLY_READY" "$EARLY_LOG" \
        PATH="${UPDATE_GATE_BIN}:${PATH}" MOCK_UPDATE_REAL_MKTEMP="$UPDATE_REAL_MKTEMP" \
        MOCK_UPDATE_REAL_SYNC="$UPDATE_REAL_SYNC" MOCK_UPDATE_JOURNAL_PATH="${DEPLOY_DIR}/backups/update-recovery.json" \
        MOCK_UPDATE_REAL_DF="$UPDATE_REAL_DF" MOCK_UPDATE_BACKUPS_DIR="${DEPLOY_DIR}/backups" \
        MOCK_UPDATE_MARKER_PATH="${DEPLOY_DIR}/.crisp-ai-installation" \
        MOCK_UPDATE_PHASE_READY="$EARLY_READY" MOCK_UPDATE_PHASE_RELEASE="$EARLY_RELEASE" \
        MOCK_UPDATE_PHASE_GATE_KIND=before-marker
      [[ "$(jq -r '.phase' "${DEPLOY_DIR}/backups/update-recovery.json")" == recovery_armed \
        && "$(sha256sum "${DEPLOY_DIR}/.crisp-ai-installation" | awk '{print $1}')" == "$EARLY_MARKER_HASH" ]] \
        || fail 'recovery_armed旧marker硬中断落点不精确'
      ;;
    recovery-armed-installing-marker)
      kill_update_group_at_gate "$EARLY_READY" "$EARLY_LOG" \
        PATH="${UPDATE_GATE_BIN}:${PATH}" MOCK_UPDATE_REAL_MKTEMP="$UPDATE_REAL_MKTEMP" \
        MOCK_UPDATE_REAL_SYNC="$UPDATE_REAL_SYNC" MOCK_UPDATE_JOURNAL_PATH="${DEPLOY_DIR}/backups/update-recovery.json" \
        MOCK_UPDATE_REAL_DF="$UPDATE_REAL_DF" MOCK_UPDATE_BACKUPS_DIR="${DEPLOY_DIR}/backups" \
        MOCK_UPDATE_MARKER_PATH="${DEPLOY_DIR}/.crisp-ai-installation" \
        MOCK_UPDATE_PHASE_READY="$EARLY_READY" MOCK_UPDATE_PHASE_RELEASE="$EARLY_RELEASE" \
        MOCK_UPDATE_PHASE_GATE_KIND=after-marker
      EARLY_CANDIDATE=$(jq -r '.source_candidate_dir' "${DEPLOY_DIR}/backups/update-recovery.json")
      [[ "$(jq -r '.phase' "${DEPLOY_DIR}/backups/update-recovery.json")" == recovery_armed \
        && "$(sed -n 's/^state=//p' "${DEPLOY_DIR}/.crisp-ai-installation" | head -n 1)" == installing \
        && "$(sed -n 's/^installed_version=//p' "${DEPLOY_DIR}/.crisp-ai-installation" | head -n 1)" == v1.2.1 \
        && "$(sed -n 's/^source=//p' "${DEPLOY_DIR}/.crisp-ai-installation" | head -n 1)" == "$EARLY_CANDIDATE" ]] \
        || fail 'recovery_armed installing marker硬中断落点不精确'
      ;;
  esac
  resume_pre_mutation_update "$early_phase" "$EARLY_MARKER_HASH" "$EARLY_ENV_HASH" \
    "$EARLY_VERSION_HASH" "$EARLY_SERVICES_HASH"
done
pass 'prepared/recovery_armed三种SIGKILL落点可按token无业务回滚收口'

UPDATE_TMP_SYNC_BIN="${TEST_ROOT}/update-tmp-sync-bin"
mkdir -m 0700 -- "$UPDATE_TMP_SYNC_BIN"
# 变量由生成的故障注入 mock 运行时展开，父测试 shell 不得提前展开。
# shellcheck disable=SC2016
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'real=${MOCK_UPDATE_REAL_SYNC:?}' \
  'tmp_parent=${MOCK_UPDATE_TMP_PARENT:?}' \
  'journal=${MOCK_UPDATE_JOURNAL_PATH:?}' \
  'pull_done=${MOCK_UPDATE_PULL_COMPLETED_MARKER:?}' \
  'mode=${MOCK_UPDATE_TMP_SYNC_MODE:?}' \
  'preflight=""' \
  'if [[ -f "$journal" && ! -L "$journal" ]]; then' \
  '  token=$(jq -r '\''.token // ""'\'' "$journal" 2>/dev/null || true)' \
  '  [[ "$token" =~ ^[a-f0-9]{64}$ ]] && preflight="${tmp_parent}/update-preflight-${token}"' \
  'fi' \
  'if (( $# == 2 )) && [[ "$1" == -f && "$2" == "$tmp_parent" && -f "$pull_done"' \
  '  && -n "$preflight" && -f "$journal" && ! -L "$journal" && ! -e "$preflight" && ! -L "$preflight" ]] &&' \
  '  jq -e '\''.phase == "prepared"'\'' "$journal" >/dev/null 2>&1; then' \
  '  case "$mode" in' \
  '    fail) exit 1 ;;' \
  '    recreate) "$real" "$@"; mkdir -m 0700 -- "$preflight"; exit 0 ;;' \
  '    *) exit 2 ;;' \
  '  esac' \
  'fi' \
  'exec "$real" "$@"' > "${UPDATE_TMP_SYNC_BIN}/sync"
chmod 0700 "${UPDATE_TMP_SYNC_BIN}/sync"

for tmp_sync_mode in fail recreate; do
  TMP_SYNC_PULL_DONE="${TEST_ROOT}/tmp-sync-${tmp_sync_mode}.pull-done"
  rm -f -- "$TMP_SYNC_PULL_DONE"
  TMP_SYNC_MARKER_HASH=$(sha256sum "${DEPLOY_DIR}/.crisp-ai-installation" | awk '{print $1}')
  TMP_SYNC_ENV_HASH=$(sha256sum "${DEPLOY_DIR}/.env" | awk '{print $1}')
  TMP_SYNC_VERSION_HASH=$(sha256sum "${DEPLOY_DIR}/VERSION" | awk '{print $1}')
  TMP_SYNC_SERVICES_HASH=$(sort "$UPDATE_SERVICE_STATE" | sha256sum | awk '{print $1}')
  if env PATH="${UPDATE_TMP_SYNC_BIN}:${PATH}" MOCK_UPDATE_REAL_SYNC="$UPDATE_REAL_SYNC" \
    MOCK_UPDATE_TMP_PARENT="${DEPLOY_DIR}/tmp" \
    MOCK_UPDATE_JOURNAL_PATH="${DEPLOY_DIR}/backups/update-recovery.json" \
    MOCK_UPDATE_PULL_COMPLETED_MARKER="$TMP_SYNC_PULL_DONE" \
    MOCK_UPDATE_TMP_SYNC_MODE="$tmp_sync_mode" \
    "${PROJECT_ROOT}/update.sh" --deploy-dir "$DEPLOY_DIR" --source-dir "$PROJECT_ROOT" --no-pull \
    > "${TEST_ROOT}/tmp-sync-${tmp_sync_mode}.log" 2>&1; then
    fail "tmp父目录sync-${tmp_sync_mode}故障被错误报告为更新成功"
  fi
  TMP_SYNC_JOURNAL="${DEPLOY_DIR}/backups/update-recovery.json"
  [[ -f "$TMP_SYNC_JOURNAL" && "$(jq -r '.phase' "$TMP_SYNC_JOURNAL")" == prepared ]] \
    || fail "tmp父目录sync-${tmp_sync_mode}故障丢失prepared journal"
  TMP_SYNC_TOKEN=$(jq -r '.token' "$TMP_SYNC_JOURNAL")
  TMP_SYNC_PREFLIGHT="${DEPLOY_DIR}/tmp/update-preflight-${TMP_SYNC_TOKEN}"
  # wrapper 的路径参数在启动前未知；从 journal 得到 token 后，确认真实清理未被假报。
  if [[ "$tmp_sync_mode" == recreate ]]; then
    [[ -d "$TMP_SYNC_PREFLIGHT" && ! -L "$TMP_SYNC_PREFLIGHT" ]] \
      || fail 'tmp父目录sync后路径复现未保留preflight责任'
  else
    [[ ! -e "$TMP_SYNC_PREFLIGHT" && ! -L "$TMP_SYNC_PREFLIGHT" ]] \
      || fail 'tmp父目录持续sync失败时preflight路径形状异常'
  fi
  TMP_SYNC_CANDIDATE=$(jq -r '.source_candidate_dir' "$TMP_SYNC_JOURNAL")
  [[ -d "$TMP_SYNC_CANDIDATE" ]] || fail "tmp父目录sync-${tmp_sync_mode}故障删除了恢复candidate"
  resume_pre_mutation_update "tmp-sync-${tmp_sync_mode}" "$TMP_SYNC_MARKER_HASH" "$TMP_SYNC_ENV_HASH" \
    "$TMP_SYNC_VERSION_HASH" "$TMP_SYNC_SERVICES_HASH"
done
pass 'preflight删除必须经tmp父目录fsync和absence回读，失败/复现均保留并可重入'

UPDATE_BACKUPS_SYNC_BIN="${TEST_ROOT}/update-backups-sync-bin"
mkdir -m 0700 -- "$UPDATE_BACKUPS_SYNC_BIN"
# 变量由生成的故障注入 mock 运行时展开，父测试 shell 不得提前展开。
# shellcheck disable=SC2016
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'real=${MOCK_UPDATE_REAL_SYNC:?}' \
  'mode=${MOCK_UPDATE_BACKUPS_SYNC_MODE:?}' \
  'backups=${MOCK_UPDATE_BACKUPS_DIR:?}' \
  'if [[ "$mode" == rename-fail && $# == 2 && "$1" == -f && "$2" == "$backups" ]] &&' \
  '  compgen -G "${backups}/update-recovery.finalizing-*.json" >/dev/null; then' \
  '  exit 1' \
  'fi' \
  'if [[ "$mode" == unlink-fail ]]; then' \
  '  tombstone=${MOCK_UPDATE_TOMBSTONE_PATH:?}' \
  '  state=${MOCK_UPDATE_BACKUPS_SYNC_STATE:?}' \
  '  if [[ "$mode" == unlink-fail && $# == 2 && "$1" == -f && "$2" == "$backups"' \
  '    && ! -e "$tombstone" && ! -e "$state" ]] &&' \
  '    [[ -f "${tombstone}.helper" && ! -L "${tombstone}.helper" ]]; then' \
  '    : > "$state"; chmod 0600 "$state"; exit 1' \
  '  fi' \
  'fi' \
  'if [[ "$mode" == candidate-cleanup-gate && $# == 2 && "$1" == -f && "$2" == "$backups" ]]; then' \
  '  candidate=${MOCK_UPDATE_CANDIDATE_PATH:?}' \
  '  partial="${backups}/.${candidate##*/}.tmp"' \
  '  ready=${MOCK_UPDATE_PHASE_READY:?}' \
  '  release=${MOCK_UPDATE_PHASE_RELEASE:?}' \
  '  if [[ -d "$partial" && ! -L "$partial" && ! -e "$candidate" && ! -L "$candidate" ]]; then' \
  '    "$real" "$@"' \
  '    [[ ! -e "$ready" && ! -L "$ready" && ! -L "$release" ]] || exit 2' \
  '    : > "$ready"; chmod 0600 "$ready"' \
  '    while [[ ! -f "$release" ]]; do sleep 0.05; done' \
  '    exit 0' \
  '  fi' \
  'fi' \
  'exec "$real" "$@"' > "${UPDATE_BACKUPS_SYNC_BIN}/sync"
chmod 0700 "${UPDATE_BACKUPS_SYNC_BIN}/sync"

TOMBSTONE_CONFIG_FAIL="${TEST_ROOT}/tombstone-config-fail"
: > "$TOMBSTONE_CONFIG_FAIL"
chmod 0600 "$TOMBSTONE_CONFIG_FAIL"
ROLLBACK_COMPLETE_BEFORE_TOMBSTONE=$(jq -s '[.[] | select(.action == "rollback" and .phase == "complete")] | length' \
  "${DEPLOY_DIR}/logs/maintenance.jsonl")
if env PATH="${UPDATE_BACKUPS_SYNC_BIN}:${PATH}" MOCK_UPDATE_REAL_SYNC="$UPDATE_REAL_SYNC" \
  MOCK_UPDATE_BACKUPS_SYNC_MODE=rename-fail MOCK_UPDATE_BACKUPS_DIR="${DEPLOY_DIR}/backups" \
  MOCK_CONFIGURATION_READBACK_FAIL_ONCE_FILE="$TOMBSTONE_CONFIG_FAIL" \
  "${PROJECT_ROOT}/update.sh" --deploy-dir "$DEPLOY_DIR" --source-dir "$PROJECT_ROOT" --no-pull \
  > "${TEST_ROOT}/tombstone-parent-sync.log" 2>&1; then
  fail 'journal改名后backups fsync失败被错误报告为恢复成功'
fi
[[ ! -e "$TOMBSTONE_CONFIG_FAIL" && ! -e "${DEPLOY_DIR}/backups/update-recovery.json" ]] \
  || fail 'tombstone故障场景未命中配置失败或仍保留双journal'
TOMBSTONE_PATH=$(find "${DEPLOY_DIR}/backups" -mindepth 1 -maxdepth 1 -type f \
  -name 'update-recovery.finalizing-*.json' -print -quit)
[[ -n "$TOMBSTONE_PATH" && "$(jq -r '.phase' "$TOMBSTONE_PATH")" == restored ]] \
  || fail 'backups父目录fsync失败未保留严格restored tombstone'
TOMBSTONE_TOKEN=$(jq -r '.token' "$TOMBSTONE_PATH")
TOMBSTONE_SNAPSHOT=$(jq -r '.snapshot_id' "$TOMBSTONE_PATH")
TOMBSTONE_CANDIDATE=$(jq -r '.source_candidate_dir' "$TOMBSTONE_PATH")
[[ -x "${TOMBSTONE_CANDIDATE}/scripts/rollback.sh" ]] \
  || fail 'tombstone保留时丢失可执行恢复candidate'
[[ "$(jq -s '[.[] | select(.action == "rollback" and .phase == "complete")] | length' \
  "${DEPLOY_DIR}/logs/maintenance.jsonl")" == "$ROLLBACK_COMPLETE_BEFORE_TOMBSTONE" ]] \
  || fail 'tombstone尚未持久收口时提前记录rollback complete'

TOMBSTONE_READY="${TEST_ROOT}/tombstone-restore-temp.ready"
TOMBSTONE_RELEASE="${TEST_ROOT}/tombstone-restore-temp.release"
TOMBSTONE_STATE="${TEST_ROOT}/tombstone-restore-temp.state"
setsid env PATH="${UPDATE_BACKUPS_SYNC_BIN}:${UPDATE_GATE_BIN}:${PATH}" \
  MOCK_UPDATE_REAL_SYNC="$UPDATE_REAL_SYNC" MOCK_UPDATE_REAL_MKTEMP="$UPDATE_REAL_MKTEMP" \
  MOCK_UPDATE_BACKUPS_SYNC_MODE=pass MOCK_UPDATE_BACKUPS_DIR="${DEPLOY_DIR}/backups" \
  MOCK_UPDATE_TOMBSTONE_PATH="$TOMBSTONE_PATH" MOCK_UPDATE_BACKUPS_SYNC_STATE="$TOMBSTONE_STATE" \
  MOCK_UPDATE_JOURNAL_PATH="${DEPLOY_DIR}/backups/update-recovery.json" \
  MOCK_UPDATE_MARKER_PATH="${DEPLOY_DIR}/.crisp-ai-installation" \
  MOCK_UPDATE_HELPER_TEMPLATE="${TOMBSTONE_PATH}.helper.tmp.XXXXXX" \
  MOCK_UPDATE_PHASE_READY="$TOMBSTONE_READY" MOCK_UPDATE_PHASE_RELEASE="$TOMBSTONE_RELEASE" \
  MOCK_UPDATE_PHASE_GATE_KIND=helper-write \
  CRISP_AI_FAILED_UPDATE_TOKEN="$TOMBSTONE_TOKEN" "${TOMBSTONE_CANDIDATE}/scripts/rollback.sh" \
  --deploy-dir "$DEPLOY_DIR" --snapshot "$TOMBSTONE_SNAPSHOT" --failed-update-recovery \
  > "${TEST_ROOT}/tombstone-restore-temp.log" 2>&1 &
TOMBSTONE_CHILD=$!
wait_for_update_gate "$TOMBSTONE_READY" "$TOMBSTONE_CHILD"
TOMBSTONE_GROUP=$(ps -o pgid= -p "$TOMBSTONE_CHILD" | tr -d ' ')
TOMBSTONE_OWN_GROUP=$(ps -o pgid= -p $$ | tr -d ' ')
[[ "$TOMBSTONE_GROUP" == "$TOMBSTONE_CHILD" && "$TOMBSTONE_GROUP" != "$TOMBSTONE_OWN_GROUP" ]] \
  || fail 'tombstone restore-temp中断进程组身份不安全'
kill -KILL -- "-$TOMBSTONE_GROUP"
if wait "$TOMBSTONE_CHILD"; then TOMBSTONE_STATUS=0; else TOMBSTONE_STATUS=$?; fi
(( TOMBSTONE_STATUS == 137 )) || fail 'tombstone restore-temp中断未得到SIGKILL状态'
TOMBSTONE_DEADLINE=$((SECONDS + 10))
while kill -0 -- "-$TOMBSTONE_GROUP" 2>/dev/null; do
  (( SECONDS < TOMBSTONE_DEADLINE )) || fail 'tombstone restore-temp中断进程组未完全退出'
  sleep 0.05
done
TOMBSTONE_HELPER="${TOMBSTONE_PATH}.helper"
TOMBSTONE_HELPER_TEMP=$(find "${DEPLOY_DIR}/backups" -mindepth 1 -maxdepth 1 -type f \
  -name "$(basename -- "$TOMBSTONE_HELPER").tmp.*" -print -quit)
[[ -n "$TOMBSTONE_HELPER_TEMP" && -f "$TOMBSTONE_PATH" \
  && "$(stat -c '%s' -- "$TOMBSTONE_HELPER_TEMP")" == 0 \
  && ! -e "$TOMBSTONE_HELPER" && -d "$TOMBSTONE_CANDIDATE" ]] \
  || fail 'helper写入/fsync期间SIGKILL未保留权威tombstone与partial helper'
TOMBSTONE_UNLINK_STATE="${TEST_ROOT}/tombstone-unlink-sync-failed"
if env PATH="${UPDATE_BACKUPS_SYNC_BIN}:${PATH}" MOCK_UPDATE_REAL_SYNC="$UPDATE_REAL_SYNC" \
  MOCK_UPDATE_BACKUPS_SYNC_MODE=unlink-fail MOCK_UPDATE_BACKUPS_DIR="${DEPLOY_DIR}/backups" \
  MOCK_UPDATE_TOMBSTONE_PATH="$TOMBSTONE_PATH" MOCK_UPDATE_BACKUPS_SYNC_STATE="$TOMBSTONE_UNLINK_STATE" \
  MOCK_UPDATE_PHASE_READY="${TEST_ROOT}/unused-tombstone-ready" \
  MOCK_UPDATE_PHASE_RELEASE="${TEST_ROOT}/unused-tombstone-release" \
  CRISP_AI_FAILED_UPDATE_TOKEN="$TOMBSTONE_TOKEN" "${TOMBSTONE_CANDIDATE}/scripts/rollback.sh" \
  --deploy-dir "$DEPLOY_DIR" --snapshot "$TOMBSTONE_SNAPSHOT" --failed-update-recovery \
  > "${TEST_ROOT}/tombstone-unlink-sync-failed.log" 2>&1; then
  fail 'tombstone unlink后父目录fsync失败被错误报告成功'
fi
[[ -f "$TOMBSTONE_UNLINK_STATE" && ! -e "$TOMBSTONE_PATH" \
  && ! -e "$TOMBSTONE_HELPER_TEMP" && -f "$TOMBSTONE_HELPER" \
  && -d "$TOMBSTONE_CANDIDATE" ]] \
  || fail 'tombstone unlink后fsync失败未保留helper-only可重入责任'
[[ "$(jq -s '[.[] | select(.action == "rollback" and .phase == "complete")] | length' \
  "${DEPLOY_DIR}/logs/maintenance.jsonl")" == "$ROLLBACK_COMPLETE_BEFORE_TOMBSTONE" ]] \
  || fail 'tombstone/helper未收口时提前记录rollback complete'
CANDIDATE_CLEANUP_READY="${TEST_ROOT}/candidate-cleanup.ready"
CANDIDATE_CLEANUP_RELEASE="${TEST_ROOT}/candidate-cleanup.release"
setsid env PATH="${UPDATE_BACKUPS_SYNC_BIN}:${PATH}" MOCK_UPDATE_REAL_SYNC="$UPDATE_REAL_SYNC" \
  MOCK_UPDATE_BACKUPS_SYNC_MODE=candidate-cleanup-gate MOCK_UPDATE_BACKUPS_DIR="${DEPLOY_DIR}/backups" \
  MOCK_UPDATE_TOMBSTONE_PATH="$TOMBSTONE_PATH" MOCK_UPDATE_BACKUPS_SYNC_STATE="$TOMBSTONE_UNLINK_STATE" \
  MOCK_UPDATE_CANDIDATE_PATH="$TOMBSTONE_CANDIDATE" \
  MOCK_UPDATE_PHASE_READY="$CANDIDATE_CLEANUP_READY" MOCK_UPDATE_PHASE_RELEASE="$CANDIDATE_CLEANUP_RELEASE" \
  CRISP_AI_FAILED_UPDATE_TOKEN="$TOMBSTONE_TOKEN" "${TOMBSTONE_CANDIDATE}/scripts/rollback.sh" \
  --deploy-dir "$DEPLOY_DIR" --snapshot "$TOMBSTONE_SNAPSHOT" --failed-update-recovery \
  > "${TEST_ROOT}/candidate-cleanup-interrupted.log" 2>&1 &
CANDIDATE_CLEANUP_CHILD=$!
wait_for_update_gate "$CANDIDATE_CLEANUP_READY" "$CANDIDATE_CLEANUP_CHILD"
CANDIDATE_CLEANUP_GROUP=$(ps -o pgid= -p "$CANDIDATE_CLEANUP_CHILD" | tr -d ' ')
[[ "$CANDIDATE_CLEANUP_GROUP" == "$CANDIDATE_CLEANUP_CHILD" \
  && "$CANDIDATE_CLEANUP_GROUP" != "$(ps -o pgid= -p $$ | tr -d ' ')" ]] \
  || fail 'candidate cleanup中断进程组身份不安全'
kill -KILL -- "-$CANDIDATE_CLEANUP_GROUP"
if wait "$CANDIDATE_CLEANUP_CHILD"; then CANDIDATE_CLEANUP_STATUS=0; else CANDIDATE_CLEANUP_STATUS=$?; fi
(( CANDIDATE_CLEANUP_STATUS == 137 )) || fail 'candidate cleanup中断未得到SIGKILL状态'
CANDIDATE_CLEANUP_DEADLINE=$((SECONDS + 10))
while kill -0 -- "-$CANDIDATE_CLEANUP_GROUP" 2>/dev/null; do
  (( SECONDS < CANDIDATE_CLEANUP_DEADLINE )) || fail 'candidate cleanup中断进程组未收口'
  sleep 0.05
done
TOMBSTONE_PARTIAL_CANDIDATE="${DEPLOY_DIR}/backups/.${TOMBSTONE_CANDIDATE##*/}.tmp"
[[ ! -e "$TOMBSTONE_HELPER" && ! -e "$TOMBSTONE_PATH" \
  && ! -e "$TOMBSTONE_CANDIDATE" && -d "$TOMBSTONE_PARTIAL_CANDIDATE" \
  && -x "${TOMBSTONE_PARTIAL_CANDIDATE}/scripts/rollback.sh" ]] \
  || fail 'candidate cleanup硬中断未在恢复责任收口后只留无秘密partial candidate'
[[ "$(jq -s '[.[] | select(.action == "rollback" and .phase == "complete")] | length' \
  "${DEPLOY_DIR}/logs/maintenance.jsonl")" == "$((ROLLBACK_COMPLETE_BEFORE_TOMBSTONE + 1))" ]] \
  || fail 'candidate孤儿清理中断前rollback complete未在journal/helper收口后唯一记录'
assert_next_update_cleans_orphans candidate-cleanup-resume "$TOMBSTONE_PARTIAL_CANDIDATE"
[[ ! -e "$TOMBSTONE_HELPER_TEMP" && ! -e "$TOMBSTONE_HELPER" \
  && ! -e "$TOMBSTONE_PATH" && ! -e "$TOMBSTONE_CANDIDATE" \
  && ! -e "$TOMBSTONE_PARTIAL_CANDIDATE" ]] \
  || fail '下一受管update未收口candidate cleanup中断孤儿'
[[ "$(jq -s '[.[] | select(.action == "rollback" and .phase == "complete")] | length' \
  "${DEPLOY_DIR}/logs/maintenance.jsonl")" == "$((ROLLBACK_COMPLETE_BEFORE_TOMBSTONE + 1))" ]] \
  || fail '孤儿收敛未保持rollback complete恰好一次'
pass 'journal/helper先收口业务责任，candidate清理中断只留可收敛无秘密孤儿'

# 冻结候选形成后，原工作区即使被删除并在同一路径换成另一 inode，也不得再被执行、
# 复制或作为恢复授权；故障恢复必须只依赖 journal 绑定的只读候选。
SOURCE_DRIFT_DIR="${TEST_ROOT}/update-source-drift"
SOURCE_DRIFT_ORIGINAL="${TEST_ROOT}/update-source-drift-original"
SOURCE_DRIFT_SENTINEL="${TEST_ROOT}/mutable-source-was-executed"
mkdir -m 0700 -- "$SOURCE_DRIFT_DIR"
while IFS= read -r release_path; do
  [[ -n "$release_path" && "$release_path" != \#* ]] || continue
  release_path=${release_path//@VERSION@/$PROJECT_VERSION}
  mkdir -p -- "${SOURCE_DRIFT_DIR}/$(dirname -- "$release_path")"
  cp -a -- "${PROJECT_ROOT}/${release_path}" "${SOURCE_DRIFT_DIR}/${release_path}"
done < "${PROJECT_ROOT}/scripts/release-manifest.txt"
SOURCE_DRIFT_READY="${TEST_ROOT}/update-source-drift.ready"
SOURCE_DRIFT_RELEASE="${TEST_ROOT}/update-source-drift.release"
SOURCE_DRIFT_CONFIG_FAIL="${TEST_ROOT}/update-source-drift-config-fail"
: > "$SOURCE_DRIFT_CONFIG_FAIL"
chmod 0600 "$SOURCE_DRIFT_CONFIG_FAIL"
setsid env MOCK_UPDATE_PULL_GATE_READY="$SOURCE_DRIFT_READY" \
  MOCK_UPDATE_PULL_GATE_RELEASE="$SOURCE_DRIFT_RELEASE" \
  MOCK_CONFIGURATION_READBACK_FAIL_ONCE_FILE="$SOURCE_DRIFT_CONFIG_FAIL" \
  "${PROJECT_ROOT}/update.sh" --deploy-dir "$DEPLOY_DIR" --source-dir "$SOURCE_DRIFT_DIR" --no-pull \
  > "${TEST_ROOT}/update-source-drift.log" 2>&1 &
SOURCE_DRIFT_CHILD=$!
wait_for_update_gate "$SOURCE_DRIFT_READY" "$SOURCE_DRIFT_CHILD"
SOURCE_DRIFT_CANDIDATE=$(jq -r '.source_candidate_dir' "${DEPLOY_DIR}/backups/update-recovery.json")
[[ -d "$SOURCE_DRIFT_CANDIDATE" && ! -L "$SOURCE_DRIFT_CANDIDATE" \
  && "$(stat -c '%a:%u' "$SOURCE_DRIFT_CANDIDATE")" == "500:${EUID}" ]] \
  || fail 'source漂移前没有形成token绑定只读候选'
mv -- "$SOURCE_DRIFT_DIR" "$SOURCE_DRIFT_ORIGINAL"
mkdir -m 0700 -- "$SOURCE_DRIFT_DIR"
mkdir -m 0700 -- "${SOURCE_DRIFT_DIR}/scripts"
printf '%s\n' '#!/usr/bin/env bash' ": > '$SOURCE_DRIFT_SENTINEL'" 'exit 99' \
  > "${SOURCE_DRIFT_DIR}/scripts/knowledge-profile.sh"
chmod 0700 "${SOURCE_DRIFT_DIR}/scripts/knowledge-profile.sh"
: > "$SOURCE_DRIFT_RELEASE"
chmod 0600 "$SOURCE_DRIFT_RELEASE"
if wait "$SOURCE_DRIFT_CHILD"; then
  fail 'source冻结后换inode且配置故障被错误报告为更新成功'
fi
[[ ! -e "$SOURCE_DRIFT_SENTINEL" && ! -e "$SOURCE_DRIFT_CONFIG_FAIL" \
  && "$(<"${DEPLOY_DIR}/VERSION")" == v1.2.1 \
  && ! -e "${DEPLOY_DIR}/backups/update-recovery.json" \
  && ! -e "$SOURCE_DRIFT_CANDIDATE" ]] \
  || fail '冻结后source删除/换inode影响了候选执行或同次快照恢复'
rm -rf -- "$SOURCE_DRIFT_DIR" "$SOURCE_DRIFT_ORIGINAL"
pass '冻结source后原路径删除换inode不影响候选执行和失败恢复'

# copy/config 后失败时自动进入同次快照恢复；先让恢复在 pg_restore 中断，
# 验证 journal 保留、伪造调用全部在再次停服前拒绝，再用原 token 幂等续做。
UPDATE_CONFIG_FAIL_ONCE="${TEST_ROOT}/update-configuration-fail-once"
: > "$UPDATE_CONFIG_FAIL_ONCE"
chmod 0600 "$UPDATE_CONFIG_FAIL_ONCE"
if env MOCK_CONFIGURATION_READBACK_FAIL_ONCE_FILE="$UPDATE_CONFIG_FAIL_ONCE" \
  MOCK_DOCKER_FAIL_PG_RESTORE=1 \
  "${PROJECT_ROOT}/update.sh" --deploy-dir "$DEPLOY_DIR" --source-dir "$PROJECT_ROOT" --no-pull \
  > "${TEST_ROOT}/update-recovery-interrupted.log" 2>&1; then
  fail '配置后失败且恢复中断时更新被错误报告为成功'
fi
[[ ! -e "$UPDATE_CONFIG_FAIL_ONCE" ]] \
  || fail '恢复中断场景未在copy发布新VERSION后的配置回读点命中'
UPDATE_RECOVERY_JOURNAL="${DEPLOY_DIR}/backups/update-recovery.json"
[[ -f "$UPDATE_RECOVERY_JOURNAL" && ! -L "$UPDATE_RECOVERY_JOURNAL" \
  && "$(stat -c '%a:%h:%u' "$UPDATE_RECOVERY_JOURNAL")" == "600:1:${EUID}" ]] \
  || fail '恢复中断未保留0600普通单链接journal'
jq -e --arg version "$CURRENT_TEST_VERSION" '.schema_version == 1 and .kind == "failed-update-recovery" and
  .old_version == "v1.2.1" and .new_version == $version and .phase == "recovering" and
  (.token | test("^[a-f0-9]{64}$")) and (.snapshot_manifest_sha256 | test("^[a-f0-9]{64}$")) and
  (.snapshot_archive_sha256 | test("^[a-f0-9]{64}$")) and
  (.source_candidate_sha256 | test("^[a-f0-9]{64}$"))' "$UPDATE_RECOVERY_JOURNAL" >/dev/null \
  || fail '恢复中断journal缺少严格身份'
UPDATE_RECOVERY_TOKEN=$(jq -r '.token' "$UPDATE_RECOVERY_JOURNAL")
UPDATE_RECOVERY_SNAPSHOT=$(jq -r '.snapshot_id' "$UPDATE_RECOVERY_JOURNAL")
UPDATE_RECOVERY_CANDIDATE=$(jq -r '.source_candidate_dir' "$UPDATE_RECOVERY_JOURNAL")
[[ -x "${UPDATE_RECOVERY_CANDIDATE}/scripts/rollback.sh" ]] \
  || fail '恢复中断未保留可重入的冻结rollback入口'
ROLLBACK_COMPLETE_BEFORE=$(jq -s '[.[] | select(.action == "rollback" and .phase == "complete")] | length' \
  "${DEPLOY_DIR}/logs/maintenance.jsonl")

assert_failed_update_recovery_rejected() {
  local label=$1 token=$2 snapshot=$3 log="${TEST_ROOT}/update-recovery-${1}.log"
  : > "$MOCK_DOCKER_LOG"
  if CRISP_AI_FAILED_UPDATE_TOKEN="$token" "${UPDATE_RECOVERY_CANDIDATE}/scripts/rollback.sh" \
    --deploy-dir "$DEPLOY_DIR" --snapshot "$snapshot" --failed-update-recovery > "$log" 2>&1; then
    fail "${label}错误取得升级失败恢复授权"
  fi
  if grep -Eq '(^| )stop( |$)' "$MOCK_DOCKER_LOG"; then
    fail "${label}拒绝后仍停止了服务"
  fi
}

assert_failed_update_recovery_rejected wrong-token "$(printf '0%.0s' {1..64})" "$UPDATE_RECOVERY_SNAPSHOT"
assert_failed_update_recovery_rejected wrong-snapshot "$UPDATE_RECOVERY_TOKEN" "${UPDATE_RECOVERY_SNAPSHOT}-wrong"
chmod 0700 "$UPDATE_RECOVERY_CANDIDATE"
printf 'foreign-member\n' > "${UPDATE_RECOVERY_CANDIDATE}/foreign-member"
chmod 0600 "${UPDATE_RECOVERY_CANDIDATE}/foreign-member"
chmod 0500 "$UPDATE_RECOVERY_CANDIDATE"
sync -f "$UPDATE_RECOVERY_CANDIDATE"
assert_failed_update_recovery_rejected candidate-extra-member "$UPDATE_RECOVERY_TOKEN" "$UPDATE_RECOVERY_SNAPSHOT"
chmod 0700 "$UPDATE_RECOVERY_CANDIDATE"
rm -f -- "${UPDATE_RECOVERY_CANDIDATE}/foreign-member"
chmod 0500 "$UPDATE_RECOVERY_CANDIDATE"
sync -f "$UPDATE_RECOVERY_CANDIDATE"
[[ "$(stat -c '%a' -- "${UPDATE_RECOVERY_CANDIDATE}/VERSION")" == 400 ]] \
  || fail '执行位篡改负例的VERSION基线模式不是0400'
chmod 0500 "${UPDATE_RECOVERY_CANDIDATE}/VERSION"
sync -f "${UPDATE_RECOVERY_CANDIDATE}/VERSION"
assert_failed_update_recovery_rejected candidate-execute-bit "$UPDATE_RECOVERY_TOKEN" "$UPDATE_RECOVERY_SNAPSHOT"
chmod 0400 "${UPDATE_RECOVERY_CANDIDATE}/VERSION"
sync -f "${UPDATE_RECOVERY_CANDIDATE}/VERSION"
ln -- "$UPDATE_RECOVERY_JOURNAL" "${TEST_ROOT}/update-recovery.external-hardlink"
assert_failed_update_recovery_rejected hardlinked-journal "$UPDATE_RECOVERY_TOKEN" "$UPDATE_RECOVERY_SNAPSHOT"
rm -f -- "${TEST_ROOT}/update-recovery.external-hardlink"
install -m 0600 -- "$UPDATE_RECOVERY_JOURNAL" "${TEST_ROOT}/update-recovery.journal.safe"
jq -cS '.snapshot_archive_sha256=("0"*64)' "$UPDATE_RECOVERY_JOURNAL" \
  > "${UPDATE_RECOVERY_JOURNAL}.bad"
chmod 0600 "${UPDATE_RECOVERY_JOURNAL}.bad"
mv -f -- "${UPDATE_RECOVERY_JOURNAL}.bad" "$UPDATE_RECOVERY_JOURNAL"
assert_failed_update_recovery_rejected wrong-sha "$UPDATE_RECOVERY_TOKEN" "$UPDATE_RECOVERY_SNAPSHOT"
install -m 0600 -- "${TEST_ROOT}/update-recovery.journal.safe" "$UPDATE_RECOVERY_JOURNAL"
install -m 0600 -- "${DEPLOY_DIR}/.crisp-ai-installation" "${TEST_ROOT}/update-recovery.marker.safe"
bash -c 'set -euo pipefail; source "$1/scripts/common.sh"; write_installation_marker "$1" "$2" v1.2.1 local-ready' \
  -- "$DEPLOY_DIR" "$PROJECT_ROOT"
assert_failed_update_recovery_rejected non-installing "$UPDATE_RECOVERY_TOKEN" "$UPDATE_RECOVERY_SNAPSHOT"
install -m 0600 -- "${TEST_ROOT}/update-recovery.marker.safe" "${DEPLOY_DIR}/.crisp-ai-installation"

UPDATE_RESTORED_RM_BIN="${TEST_ROOT}/update-restored-rm-bin"
UPDATE_RESTORED_RM_TRIGGER="${TEST_ROOT}/update-restored-rm-fail-once"
UPDATE_RECOVERY_TOMBSTONE_PATH="${DEPLOY_DIR}/backups/update-recovery.finalizing-${UPDATE_RECOVERY_TOKEN}.json"
UPDATE_REAL_RM=$(command -v rm)
mkdir -m 0700 -- "$UPDATE_RESTORED_RM_BIN"
# 变量由生成的故障注入 mock 运行时展开，父测试 shell 不得提前展开。
# shellcheck disable=SC2016
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'target=${MOCK_UPDATE_JOURNAL_PATH:?}' \
  'trigger=${MOCK_UPDATE_RM_FAIL_ONCE_FILE:?}' \
  'real_rm=${MOCK_UPDATE_REAL_RM:?}' \
  'for argument in "$@"; do' \
  '  if [[ "$argument" == "$target" && -f "$trigger" && ! -L "$trigger" ]]; then' \
  "    if jq -e '.phase == \"restored\"' \"\$target\" >/dev/null 2>&1; then" \
  '      "$real_rm" -f -- "$trigger"' \
  '      exit 1' \
  '    fi' \
  '  fi' \
  'done' \
  'exec "$real_rm" "$@"' > "${UPDATE_RESTORED_RM_BIN}/rm"
chmod 0700 "${UPDATE_RESTORED_RM_BIN}/rm"
: > "$UPDATE_RESTORED_RM_TRIGGER"
chmod 0600 "$UPDATE_RESTORED_RM_TRIGGER"
if env PATH="${UPDATE_RESTORED_RM_BIN}:${PATH}" \
  MOCK_UPDATE_JOURNAL_PATH="$UPDATE_RECOVERY_TOMBSTONE_PATH" \
  MOCK_UPDATE_RM_FAIL_ONCE_FILE="$UPDATE_RESTORED_RM_TRIGGER" MOCK_UPDATE_REAL_RM="$UPDATE_REAL_RM" \
  CRISP_AI_FAILED_UPDATE_TOKEN="$UPDATE_RECOVERY_TOKEN" "${UPDATE_RECOVERY_CANDIDATE}/scripts/rollback.sh" \
  --deploy-dir "$DEPLOY_DIR" --snapshot "$UPDATE_RECOVERY_SNAPSHOT" --failed-update-recovery \
  > "${TEST_ROOT}/update-recovery-resumed-first.log" 2>&1; then
  fail 'restored阶段journal清理失败被错误报告为恢复成功'
fi
[[ ! -e "$UPDATE_RESTORED_RM_TRIGGER" \
  && ! -e "$UPDATE_RECOVERY_JOURNAL" \
  && "$(jq -r '.phase' "$UPDATE_RECOVERY_TOMBSTONE_PATH")" == restored ]] \
  || fail 'restored阶段journal清理故障未精确命中并保留恢复责任'
[[ "$(jq -s '[.[] | select(.action == "rollback" and .phase == "complete")] | length' \
  "${DEPLOY_DIR}/logs/maintenance.jsonl")" == "$ROLLBACK_COMPLETE_BEFORE" ]] \
  || fail 'journal尚未清理时提前记录了rollback complete'
CRISP_AI_FAILED_UPDATE_TOKEN="$UPDATE_RECOVERY_TOKEN" "${UPDATE_RECOVERY_CANDIDATE}/scripts/rollback.sh" \
  --deploy-dir "$DEPLOY_DIR" --snapshot "$UPDATE_RECOVERY_SNAPSHOT" --failed-update-recovery \
  > "${TEST_ROOT}/update-recovery-resumed.log" 2>&1
[[ ! -e "$UPDATE_RECOVERY_JOURNAL" && ! -L "$UPDATE_RECOVERY_JOURNAL" ]] \
  || fail '幂等续做恢复完成后仍保留journal'
[[ ! -e "$UPDATE_RECOVERY_TOMBSTONE_PATH" && ! -L "$UPDATE_RECOVERY_TOMBSTONE_PATH" ]] \
  || fail '幂等续做恢复完成后仍保留tombstone'
[[ ! -e "${UPDATE_RECOVERY_TOMBSTONE_PATH}.helper" \
  && -z "$(find "${DEPLOY_DIR}/backups" -mindepth 1 -maxdepth 1 \
    -name "$(basename -- "$UPDATE_RECOVERY_TOMBSTONE_PATH").helper.tmp.*" -print -quit)" ]] \
  || fail '幂等续做恢复完成后仍保留journal helper'
[[ "$(jq -s '[.[] | select(.action == "rollback" and .phase == "complete")] | length' \
  "${DEPLOY_DIR}/logs/maintenance.jsonl")" == "$((ROLLBACK_COMPLETE_BEFORE + 1))" ]] \
  || fail 'journal清理后的rollback complete不是唯一一次'
[[ "$(<"${DEPLOY_DIR}/VERSION")" == v1.2.1 \
  && "$(sed -n 's/^state=//p' "${DEPLOY_DIR}/.crisp-ai-installation" | head -n 1)" == local-ready \
  && "$(sed -n 's/^installed_version=//p' "${DEPLOY_DIR}/.crisp-ai-installation" | head -n 1)" == v1.2.1 \
  && "$(sed -n 's/^fact_local_services=//p' "${DEPLOY_DIR}/.crisp-ai-installation" | head -n 1)" == ready \
  && "$(sed -n 's/^fact_app_config=//p' "${DEPLOY_DIR}/.crisp-ai-installation" | head -n 1)" == ready ]] \
  || fail '幂等续做未恢复旧版本和安装标记'
pass '升级恢复journal拒绝伪造身份且中断后可按同一token幂等续做'

: > "$UPDATE_CONFIG_FAIL_ONCE"
chmod 0600 "$UPDATE_CONFIG_FAIL_ONCE"
if env MOCK_CONFIGURATION_READBACK_FAIL_ONCE_FILE="$UPDATE_CONFIG_FAIL_ONCE" \
  "${PROJECT_ROOT}/update.sh" \
  --deploy-dir "$DEPLOY_DIR" --source-dir "$PROJECT_ROOT" --no-pull \
  > "${TEST_ROOT}/update-recovery-complete.log" 2>&1; then
  fail '配置后故障被错误报告为更新成功'
fi
[[ ! -e "$UPDATE_CONFIG_FAIL_ONCE" ]] \
  || fail '自动恢复场景未在copy发布新VERSION后的配置回读点命中'
grep -Fq '已自动恢复到更新前版本：v1.2.1' "${TEST_ROOT}/update-recovery-complete.log" \
  || fail 'copy/config后故障未完成同次快照自动恢复'
! grep -Fq '回滚前安全快照：' "${TEST_ROOT}/update-recovery-complete.log" \
  || fail 'failed-update-recovery错误创建了混合现场安全快照'
[[ "$(<"${DEPLOY_DIR}/VERSION")" == v1.2.1 \
  && ! -e "$UPDATE_RECOVERY_JOURNAL" && ! -L "$UPDATE_RECOVERY_JOURNAL" ]] \
  || fail 'copy/config后自动恢复未收口旧版本或journal'
[[ -z "$(find "${DEPLOY_DIR}/backups" -mindepth 1 -maxdepth 1 \
  \( -name 'update-candidate-*' -o -name '.update-candidate-*.tmp' \) -print -quit)" ]] \
  || fail 'copy/config后自动恢复遗留了只读冻结候选'
pass 'v1.2.1到当前版在copy/config后失败自动恢复同次完整快照'

ENV_HASH_BEFORE=$(sha256sum "${DEPLOY_DIR}/.env" | awk '{print $1}')
UPDATE_ENV_BASELINE="${TEST_ROOT}/update-env-before.env"
cp -p -- "${DEPLOY_DIR}/.env" "$UPDATE_ENV_BASELINE"
UPDATE_HANDOFF_BASELINE="${TEST_ROOT}/update-handoff-before.yaml"
UPDATE_TAGS_BASELINE="${TEST_ROOT}/update-tags-before.yaml"
cp -p -- "${DEPLOY_DIR}/config/handoff.yaml" "$UPDATE_HANDOFF_BASELINE"
cp -p -- "${DEPLOY_DIR}/config/tags.yaml" "$UPDATE_TAGS_BASELINE"
UPDATE_HANDOFF_HASH_BEFORE=$(sha256sum "$UPDATE_HANDOFF_BASELINE" | awk '{print $1}')
UPDATE_TAGS_HASH_BEFORE=$(sha256sum "$UPDATE_TAGS_BASELINE" | awk '{print $1}')
UPDATE_COMPLETE_BEFORE=$(jq -s '[.[] | select(.action == "update" and .phase == "complete")] | length' \
  "${DEPLOY_DIR}/logs/maintenance.jsonl")
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf "legacy-backup-should-not-run\\n" >&2' \
  'exit 97' > "${DEPLOY_DIR}/scripts/backup.sh"
chmod 0750 "${DEPLOY_DIR}/scripts/backup.sh"
mkdir -m 0700 -- "${DEPLOY_DIR}/data/runtime/scheduler-scan.lock"
printf 'postgres\nanythingllm\nn8n\nprovider-adapter\n' > "$UPDATE_SERVICE_STATE"
UPDATE_RM_BIN="${TEST_ROOT}/update-rm-bin"
UPDATE_RM_TRIGGER="${TEST_ROOT}/update-rm-fail-once"
UPDATE_REAL_RM=$(command -v rm)
mkdir -m 0700 -- "$UPDATE_RM_BIN"
# 变量由生成的故障注入 mock 运行时展开，父测试 shell 不得提前展开。
# shellcheck disable=SC2016
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'directory=${MOCK_UPDATE_JOURNAL_DIR:?}' \
  'trigger=${MOCK_UPDATE_RM_FAIL_ONCE_FILE:?}' \
  'real_rm=${MOCK_UPDATE_REAL_RM:?}' \
  'for argument in "$@"; do' \
  '  if [[ "${argument%/*}" == "$directory" && "${argument##*/}" =~ ^update-recovery\.finalizing-[a-f0-9]{64}\.json$' \
  '    && -f "$argument" && ! -L "$argument" && -f "$trigger" && ! -L "$trigger" ]]; then' \
  "    if jq -e '.phase == \"update_committed\"' \"\$argument\" >/dev/null 2>&1; then" \
  '      "$real_rm" -f -- "$trigger"' \
  '      exit 1' \
  '    fi' \
  '  fi' \
  'done' \
  'exec "$real_rm" "$@"' > "${UPDATE_RM_BIN}/rm"
chmod 0700 "${UPDATE_RM_BIN}/rm"
: > "$UPDATE_RM_TRIGGER"
chmod 0600 "$UPDATE_RM_TRIGGER"
env PATH="${UPDATE_RM_BIN}:${PATH}" \
  MOCK_UPDATE_JOURNAL_DIR="${DEPLOY_DIR}/backups" \
  MOCK_UPDATE_RM_FAIL_ONCE_FILE="$UPDATE_RM_TRIGGER" MOCK_UPDATE_REAL_RM="$UPDATE_REAL_RM" \
  "${PROJECT_ROOT}/update.sh" \
  --deploy-dir "$DEPLOY_DIR" --source-dir "$PROJECT_ROOT" --no-pull \
  > "${TEST_ROOT}/update.log" 2>&1
unset MOCK_DOCKER_SERVICE_STATE
[[ ! -e "$UPDATE_RM_TRIGGER" ]] || fail 'update_committed清理故障没有精确命中一次'
grep -Fq '新版本已到提交点，正在核验当前健康并收口恢复 journal；不得倒回旧版本' \
  "${TEST_ROOT}/update.log" || fail 'update_committed清理失败未进入只收口新版本的finalizer'
grep -Fq "更新提交已完成：${CURRENT_TEST_VERSION}" "${TEST_ROOT}/update.log" \
  || fail 'update_committed finalizer没有返回成功'
! grep -Fq '开始按同次更新前快照自动恢复' "${TEST_ROOT}/update.log" \
  || fail 'update_committed错误倒回旧快照'
[[ ! -e "${DEPLOY_DIR}/backups/update-recovery.json" \
  && ! -L "${DEPLOY_DIR}/backups/update-recovery.json" ]] \
  || fail 'update_committed finalizer成功后仍保留journal'
[[ -z "$(find "${DEPLOY_DIR}/backups" -mindepth 1 -maxdepth 1 \
  -name 'update-recovery.finalizing-*' -print -quit)" ]] \
  || fail 'update_committed finalizer成功后仍保留tombstone'
[[ -z "$(find "${DEPLOY_DIR}/backups" -mindepth 1 -maxdepth 1 \
  \( -name 'update-candidate-*' -o -name '.update-candidate-*.tmp' \) -print -quit)" ]] \
  || fail 'update_committed finalizer成功后仍保留只读冻结候选'
[[ "$(jq -s '[.[] | select(.action == "update" and .phase == "complete")] | length' \
  "${DEPLOY_DIR}/logs/maintenance.jsonl")" == "$((UPDATE_COMPLETE_BEFORE + 1))" ]] \
  || fail 'update_committed journal清理前假记complete或重入后重复记录'
if grep -Fq 'legacy-backup-should-not-run' "${TEST_ROOT}/update.log"; then
  fail "升级错误调用了旧部署中的备份脚本"
fi
[[ "$(<"${DEPLOY_DIR}/VERSION")" == "$PROJECT_VERSION" ]] || fail "更新后版本错误"
[[ "$(sed -n 's/^source=//p' "${DEPLOY_DIR}/.crisp-ai-installation" | head -n 1)" == "$PROJECT_ROOT" ]] \
  || fail 'update_committed finalizer未把安装marker source恢复为原始受管source'
[[ ! -e "${DEPLOY_DIR}/data/runtime/scheduler-scan.lock" \
  && ! -L "${DEPLOY_DIR}/data/runtime/scheduler-scan.lock" ]] \
  || fail '升级未在 n8n 停写窗口迁移旧版无所有权扫描空锁'
grep -Fq '已在 n8n 停写窗口迁移旧版会话扫描空锁' "${TEST_ROOT}/update.log" \
  || fail '升级未报告旧版扫描锁迁移结果'
assert_update_env_preserved "$UPDATE_ENV_BASELINE" "$DEPLOY_DIR" "$ENV_HASH_BEFORE" \
  > "${TEST_ROOT}/update-env-preservation.json" || fail "更新改写了非派生配置或知识窗口未对应接口池"
cmp -s -- "${PROJECT_ROOT}/scripts/visitor-output.js" "${DEPLOY_DIR}/scripts/visitor-output.js" \
  || fail '更新后访客输出策略模块不是当前源码代'
assert_update_configuration_preserved "$UPDATE_HANDOFF_BASELINE" "${DEPLOY_DIR}/config/handoff.yaml" \
  "${TEST_ROOT}/update-handoff-preservation" "$UPDATE_HANDOFF_HASH_BEFORE" \
  || fail '升级改写了合法人工接管原文或配置解码失败'
jq -s -e '
  .[0].handoff.message as $original_message | .[1] |
  .handoff.disable_ai == true and .handoff.notify_user.enabled == true and
  (.handoff.keywords | index("转人工") != null) and
  (.handoff.keywords | index("真人") != null) and
  .handoff.message == $original_message and
  (.handoff | has("topic_keywords") | not) and
  (.handoff | has("on_low_confidence") | not) and
  .handoff.no_answer_message == "" and
  .handoff.low_confidence_message == "" and
  .handoff.failure_message == ""
' "${TEST_ROOT}/update-handoff-preservation/before.json" \
  "${TEST_ROOT}/update-handoff-preservation/after.json" >/dev/null \
  || fail '合法人工接管字段或原有通知未完整保留'
assert_update_configuration_preserved "$UPDATE_TAGS_BASELINE" "${DEPLOY_DIR}/config/tags.yaml" \
  "${TEST_ROOT}/update-tags-preservation" "$UPDATE_TAGS_HASH_BEFORE" jq-json \
  || fail '升级改写了标签字段或不是受管同值排版'
jq -s -e '
  .[0].tags.ai_resolved as $original_resolved_tag | .[1] |
  .tags.ai_resolved == $original_resolved_tag and
  .tags.knowledge_miss == "knowledge_miss" and
  .tags.low_confidence == "low_confidence" and
  .tags.human_required == "human_required"
' "${TEST_ROOT}/update-tags-preservation/before.json" \
  "${TEST_ROOT}/update-tags-preservation/after.json" >/dev/null \
  || fail '原有标签值未完整保留'
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
[[ -f "${DEPLOY_DIR}/knowledge/${RESTORE_KNOWLEDGE_PROJECTION}" ]] || fail "安全卸载删除了知识文件"
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
[[ -f "${DEPLOY_DIR}/knowledge/${RESTORE_KNOWLEDGE_PROJECTION}" \
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
