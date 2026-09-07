#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
WIZARD="${PROJECT_ROOT}/scripts/wizard.sh"
MOCK_DIR="${SCRIPT_DIR}/mocks"

fail() {
  printf '快速初始化向导测试失败：%s\n' "$1" >&2
  exit 1
}

pass() {
  printf '通过：[UNIT/CONTRACT] %s\n' "$1"
}

for command_name in bash curl find install jq mktemp python3 realpath shellcheck stat; do
  command -v "$command_name" >/dev/null 2>&1 || fail "缺少测试命令：$command_name"
done
[[ -f "$WIZARD" && ! -L "$WIZARD" && -x "$WIZARD" ]] || fail 'wizard.sh 必须是可执行普通文件'

TEST_ROOT=$(mktemp -d "${PROJECT_ROOT}/.test-runtime.wizard.XXXXXX")
cleanup() {
  if [[ "${AI_SUPPORT_TEST_KEEP_TMP:-0}" == 1 ]]; then
    printf '向导调试目录已保留：%s\n' "$TEST_ROOT" >&2
    return
  fi
  if [[ "$TEST_ROOT" == "${PROJECT_ROOT}"/.test-runtime.wizard.* && -d "$TEST_ROOT" ]]; then
    rm -rf -- "$TEST_ROOT"
  fi
}
trap cleanup EXIT

PROMPT_FILE="${TEST_ROOT}/客服 提示.md"
KNOWLEDGE_DIR="${TEST_ROOT}/中文 知识"
mkdir -p -- "$KNOWLEDGE_DIR"
printf '只根据受控知识回答。\n' > "$PROMPT_FILE"
printf '虚构产品编号：DEMO-4827。\n' > "${KNOWLEDGE_DIR}/产品 说明.MD"
printf '虚构排障资料。\n' > "${KNOWLEDGE_DIR}/排障.TXT"

TEST_PROVIDER_SECRET="test only \$provider#=\"\\=value"
TEST_PROVIDER_REPLACEMENT="replacement \$provider#=\"\\=value"
TEST_CRISP_IDENTIFIER='test-only identifier#="\=value'
TEST_CRISP_SECRET="test only \$crisp#=\"\\=value"
export PTY_PROVIDER_SECRET=$TEST_PROVIDER_SECRET
export PTY_PROVIDER_REPLACEMENT=$TEST_PROVIDER_REPLACEMENT
export PTY_CRISP_IDENTIFIER=$TEST_CRISP_IDENTIFIER
export PTY_CRISP_SECRET=$TEST_CRISP_SECRET
export PTY_BASE_URL='https://provider.invalid/proxy/v1/'
export WIZARD_HTTPS_PORTS_MANAGED=1
export MOCK_FORBIDDEN_ARG_FILE="${TEST_ROOT}/forbidden-args.txt"
printf '%s\n' "$TEST_PROVIDER_SECRET" "$TEST_PROVIDER_REPLACEMENT" \
  "$TEST_CRISP_IDENTIFIER" "$TEST_CRISP_SECRET" \
  > "$MOCK_FORBIDDEN_ARG_FILE"

python3 - "$WIZARD" "$TEST_ROOT" <<'PY'
import os
import pathlib
import subprocess
import sys

wizard = sys.argv[1]
root = pathlib.Path(sys.argv[2])
environment = {**os.environ, "LC_ALL": "C.UTF-8"}

def run(script, data, *arguments):
    result = subprocess.run(
        ["bash", "-c", 'set -euo pipefail; source "$1"; ' + script,
         "wizard-boundary", wizard, *arguments],
        input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=environment,
        timeout=15,
    )
    return result.returncode

multiline = 'value=; wizard_read_multiline value "$2"; [[ "$value" == "$3" ]]'
text = "人工客服\n"
if run(multiline, (text + "::END::\n").encode(), "13", text) != 0:
    raise SystemExit("13 字节中文多行边界错误")
if run(multiline, (text + "::END::\n").encode(), "12", text) == 0:
    raise SystemExit("中文多行按字符计数，超过 UTF-8 字节上限仍被接受")

step = '''
wizard_init_values
wizard_write_state(){ :; }
wizard_collect_step 8 "$2/unused.json" "$2"
[[ "$WIZARD_PROMPT_MODE" == inline && "$WIZARD_PROMPT_CONTENT" == "$3" ]]
'''
valid = "有效虚构提示"
for label, raw in (("empty", b""), ("blank", " \t\n\u3000".encode()),
                   ("invalid-utf8", b"\xff"), ("nul", b"hello\x00world"),
                   ("too-large", b"a" * 262145)):
    path = root / (label + ".md")
    path.write_bytes(raw)
    if run(step, (str(path) + "\n" + valid + "\n").encode(), str(root), valid) != 0:
        raise SystemExit(f"第 8 项未在确认前拒绝 {label} Prompt 文件")

for label, target in (("linked", root / "客服 提示.md"),
                      ("broken-link", root / "missing.md")):
    link = root / (label + ".md")
    link.symlink_to(target)
    if run(step, (str(link) + "\n" + valid + "\n").encode(), str(root), valid) != 0:
        raise SystemExit(f"第 8 项未拒绝原始 {label} 路径")

parent_link = root / "链接父目录"
parent_link.symlink_to(root, target_is_directory=True)
if run(step, (str(parent_link / "客服 提示.md") + "\n" + valid + "\n").encode(), str(root), valid) != 0:
    raise SystemExit("第 8 项未在确认前拒绝父目录符号链接")

nested = root / "只有 子目录 🙂"
(nested / "下一层").mkdir(parents=True)
(nested / "下一层/中文说明.md").write_text("虚构知识事实。\n", encoding="utf-8")
knowledge_step = '''
wizard_init_values
wizard_write_state(){ :; }
wizard_collect_step 9 "$2/unused.json" "$2"
[[ "$WIZARD_KNOWLEDGE_MODE" == directory && "$WIZARD_KNOWLEDGE_FILES" == 1 ]]
'''
if run(knowledge_step, (str(nested) + "\n").encode(), str(root)) != 0:
    raise SystemExit("第 9 项把只有子目录的有效知识误报为空库")

for bad in (" \t\u3000", "汉" * 87382):
    if run(step, (bad + "\n" + valid + "\n").encode(), str(root), valid) != 0:
        raise SystemExit("第 8 项未拒绝全空白或超过 262144 字节的单行 Prompt")

# 大正文不经过命令参数传递，避免 ARG_MAX 掩盖真实输入边界。
exact = "汉" * 87381 + "A"
exact_step = '''
wizard_init_values
wizard_write_state(){ :; }
wizard_collect_step 8 "$2/unused.json" "$2"
[[ "$WIZARD_PROMPT_MODE" == inline ]]
[[ $(printf '%s' "$WIZARD_PROMPT_CONTENT" | wc -c) == 262144 ]]
'''
if run(exact_step, (exact + "\n").encode(), str(root)) != 0:
    raise SystemExit("恰好 262144 个 UTF-8 字节的单行 Prompt 未被接受")
print("通过：[UNIT/CONTRACT] 向导 UTF-8 字节边界、空白/损坏 Prompt 与原始链接拒绝")
PY

run_pty_case() {
  local scenario=$1
  local output_file=$2
  local transcript=$3
  local count_file=$4
  local test_path=$PATH
  case "$scenario" in
    manual) test_path="${MANUAL_MOCK_DIR}:${MOCK_DIR}:${PATH}" ;;
    auth) test_path="${AUTH_MOCK_DIR}:${MOCK_DIR}:${PATH}" ;;
    search) test_path="${PAGED_MOCK_DIR}:${MOCK_DIR}:${PATH}" ;;
    port_conflict) test_path="${PORT_MOCK_DIR}:${MOCK_DIR}:${PATH}" ;;
    *) test_path="${MOCK_DIR}:${PATH}" ;;
  esac
  env PATH="$test_path" TERM=dumb python3 - \
    "$WIZARD" "$scenario" "$output_file" "$transcript" "$count_file" \
    "$PROMPT_FILE" "$KNOWLEDGE_DIR" <<'PY'
import errno
import os
import pty
import select
import signal
import sys
import time

wizard, scenario, output_file, transcript_file, count_file, prompt_file, knowledge_dir = sys.argv[1:]
provider_secret = os.environ.pop("PTY_PROVIDER_SECRET")
provider_replacement = os.environ.pop("PTY_PROVIDER_REPLACEMENT")
crisp_identifier = os.environ.pop("PTY_CRISP_IDENTIFIER")
crisp_secret = os.environ.pop("PTY_CRISP_SECRET")
base_url = os.environ.pop("PTY_BASE_URL")

normal_steps = [
    ("[1/10] AI API 地址", base_url, False),
    ("[2/10] AI API Key", provider_secret, True),
    ("[3/10] 选择模型", "1", False),
    ("[4/10] Crisp Website ID", "11111111-1111-1111-1111-111111111111", False),
    ("[5/10] Crisp Token Identifier", crisp_identifier, True),
    ("[6/10] Crisp Token Key", crisp_secret, True),
    ("[7/10] 公网域名或现有 HTTPS Webhook 地址", "support.example.invalid", False),
    ("[8/10] 客服提示词", prompt_file, False),
    ("[9/10] 知识库文件或目录", knowledge_dir, False),
    ("1 开始安装 / 2 返回修改 / 0 取消", "1", False),
]
resume_steps = normal_steps[2:]
manual_steps = list(normal_steps)
manual_steps[0] = (normal_steps[0][0], base_url, False)
manual_steps[2] = ("[3/10] 模型列表不可用", "manual-chat-model", False)
auth_steps = normal_steps[:2] + [
    ("请重新输入 AI API Key", provider_replacement, True),
] + normal_steps[2:]
search_steps = normal_steps[:2] + [
    ("[3/10] 选择模型", "n", False),
    ("[3/10] 选择模型", "p", False),
    ("[3/10] 选择模型", "/model-12", False),
    ("[3/10] 选择模型", "12", False),
] + normal_steps[3:]
port_steps = normal_steps[:7] + [
    ("[7/10] 公网域名或现有 HTTPS Webhook 地址", "https://proxy.example.invalid/team/webhook/crisp-webhook", False),
] + normal_steps[7:]
paste_steps = normal_steps[:7] + [
    ("[8/10] 客服提示词", "::PASTE::", False),
    ("正文需要结束符字面量时", '## 中文 🙂\n\n$ # = " \\ 保留。\n\\::END::\n\n::END::', False),
    ("[9/10] 知识库文件或目录", "::LIBRARIES::", False),
    ("知识库名称", "界" * 34, False),
    ("知识库名称", "电脑排障", False),
    ("文件/目录路径", knowledge_dir, False),
    ("知识库名称", "手机排障", False),
    ("文件/目录路径", prompt_file, False),
    ("知识库名称", "订阅与账号", False),
    ("文件/目录路径", "::PASTE::", False),
    ("正文需要结束符字面量时", "# 虚构订阅\n\n测试事实为蓝色。\n::END::", False),
    ("知识库名称", "0", False),
    ("1 开始安装 / 2 返回修改 / 0 取消", "1", False),
]

if scenario == "normal" or scenario == "manual":
    argv = [wizard, "--output", output_file]
    steps = normal_steps if scenario == "normal" else manual_steps
elif scenario == "resume":
    argv = [wizard, "--output", output_file]
    steps = resume_steps
elif scenario == "reuse":
    argv = [wizard, "--output", output_file]
    steps = [("1 使用现有配置 / 2 重新配置 / 0 取消", "1", False)]
elif scenario == "auth":
    argv = [wizard, "--output", output_file]
    steps = auth_steps
elif scenario == "search":
    argv = [wizard, "--output", output_file]
    steps = search_steps
elif scenario == "port_conflict":
    argv = [wizard, "--output", output_file]
    steps = port_steps
elif scenario == "paste":
    argv = [wizard, "--output", output_file]
    steps = paste_steps
else:
    raise SystemExit(f"unknown scenario: {scenario}")

pid, fd = pty.fork()
if pid == 0:
    os.execve(wizard, argv, os.environ.copy())

transcript = bytearray()
cursor = 0

def read_once(timeout):
    ready, _, _ = select.select([fd], [], [], timeout)
    if not ready:
        return False
    try:
        chunk = os.read(fd, 4096)
    except OSError as exc:
        if exc.errno == errno.EIO:
            return False
        raise
    if chunk:
        transcript.extend(chunk)
        return True
    return False

def wait_for(text, timeout=20):
    global cursor
    needle = text.encode("utf-8")
    deadline = time.monotonic() + timeout
    while True:
        location = transcript.find(needle, cursor)
        if location >= 0:
            cursor = location + len(needle)
            return
        if time.monotonic() >= deadline:
            raise TimeoutError(text)
        read_once(0.1)

try:
    for expected, answer, hidden in steps:
        wait_for(expected)
        # 等待 read -s 已关闭终端回显，防止测试转录包含测试密钥。
        time.sleep(0.12 if hidden else 0.03)
        os.write(fd, answer.encode("utf-8") + b"\n")

    deadline = time.monotonic() + 30
    child_status = None
    while time.monotonic() < deadline:
        read_once(0.1)
        done, status = os.waitpid(pid, os.WNOHANG)
        if done == pid:
            child_status = status
            while read_once(0.01):
                pass
            break
    if child_status is None:
        os.kill(pid, signal.SIGTERM)
        os.waitpid(pid, 0)
        raise TimeoutError("wizard exit")
except Exception as exc:
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        os.waitpid(pid, 0)
    except ChildProcessError:
        pass
    with open(transcript_file, "wb") as handle:
        handle.write(transcript)
    print(f"PTY driver failed: {exc}", file=sys.stderr)
    raise SystemExit(98)

with open(transcript_file, "wb") as handle:
    handle.write(transcript)
with open(count_file, "w", encoding="ascii") as handle:
    handle.write(str(sum(answer.count("\n") + 1 for _, answer, _ in steps)))
raise SystemExit(os.waitstatus_to_exitcode(child_status))
PY
}

NORMAL_RESULT="${TEST_ROOT}/normal-result.json"
NORMAL_TRANSCRIPT="${TEST_ROOT}/normal-transcript.log"
NORMAL_COUNT="${TEST_ROOT}/normal-count"
run_pty_case normal "$NORMAL_RESULT" "$NORMAL_TRANSCRIPT" "$NORMAL_COUNT"

[[ "$(<"$NORMAL_COUNT")" == 10 ]] || fail '正常路径不是十次输入'
[[ "$(grep -o '\[[0-9]\+/10\]' "$NORMAL_TRANSCRIPT" | sort -u | wc -l)" == 10 ]] \
  || fail '正常路径没有显示完整的 1/10 至 10/10'
[[ "$(stat -c '%a' "$NORMAL_RESULT")" == 600 ]] || fail '向导结果权限不是 0600'
jq -e '
  .schema_version == 1 and .status == "confirmed" and .next_step == 10 and
  .provider.base_url == "https://provider.invalid/proxy/v1" and
  .provider.model == "deepseek-test" and
  .provider.model_discovery == "models_api" and
  .provider.capabilities.chat_completions == true and
  .provider.capabilities.responses == true and
  .provider.capabilities.vision == true and
  .crisp.website_id == "11111111-1111-1111-1111-111111111111" and
  .crisp.token_tier == "website" and .crisp.hook_mode == "website" and
  .webhook.mode == "domain" and
  .webhook.public_base_url == "https://support.example.invalid/" and
  .webhook.production_url == "https://support.example.invalid/webhook/crisp-webhook" and
  .prompt.mode == "file" and .knowledge.mode == "directory" and
  .knowledge.supported_files == 2
' "$NORMAL_RESULT" >/dev/null || fail '正常路径结构化结果错误'
[[ "$(jq -r '.provider.api_key' "$NORMAL_RESULT")" == "$TEST_PROVIDER_SECRET" ]] \
  || fail '特殊字符 API Key 未原样保存'
[[ "$(jq -r '.crisp.token_identifier' "$NORMAL_RESULT")" == "$TEST_CRISP_IDENTIFIER" ]] \
  || fail '特殊字符 Token Identifier 未原样保存'
[[ "$(jq -r '.crisp.token_key' "$NORMAL_RESULT")" == "$TEST_CRISP_SECRET" ]] \
  || fail '特殊字符 Token Key 未原样保存'
for secret in "$TEST_PROVIDER_SECRET" "$TEST_CRISP_IDENTIFIER" "$TEST_CRISP_SECRET"; do
  ! grep -Fq -- "$secret" "$NORMAL_TRANSCRIPT" || fail 'PTY 转录泄露隐藏凭据'
done
pass '十项 PTY 向导、脱敏摘要、特殊字符与结构化结果'

PASTE_RESULT="${TEST_ROOT}/paste-result.json"
PASTE_TRANSCRIPT="${TEST_ROOT}/paste-transcript.log"
PASTE_COUNT="${TEST_ROOT}/paste-count"
run_pty_case paste "$PASTE_RESULT" "$PASTE_TRANSCRIPT" "$PASTE_COUNT"
jq -e --arg expected $'## 中文 🙂\n\n$ # = " \\ 保留。\n::END::\n\n' '
  .prompt.mode == "inline" and .prompt.content == $expected and .knowledge.mode == "libraries" and
  [.knowledge.libraries[].name] == ["电脑排障","手机排障","订阅与账号"]
' "$PASTE_RESULT" >/dev/null || fail '多行 Prompt 或三个命名库状态保存不正确'
PASTED_SOURCE=$(jq -r '.knowledge.libraries[2].source' "$PASTE_RESULT")
[[ -f "$PASTED_SOURCE" && "$(stat -c '%a' "$PASTED_SOURCE")" == 600 ]] || fail '粘贴知识未受限保存'
[[ "$(<"$PASTE_COUNT")" == 28 ]] || fail "粘贴分支真实输入行数错误：$(<"$PASTE_COUNT")"
grep -Fq '知识库名称须为 1～100 个 UTF-8 字节' "$PASTE_TRANSCRIPT" || fail '超限中文库名未在向导中拒绝并重新输入'
for secret in "$TEST_PROVIDER_SECRET" "$TEST_CRISP_IDENTIFIER" "$TEST_CRISP_SECRET"; do
  ! grep -Fq -- "$secret" "$PASTE_TRANSCRIPT" || fail '粘贴分支回显秘密'
done
pass '十项主步骤中的 Prompt 多行粘贴与三个命名库（含超限库名重试，真实输入 28 行）'

RESPONSES_RESULT="${TEST_ROOT}/responses-only-result.json"
export MOCK_PROVIDER_RESPONSES_ONLY=1
run_pty_case normal "$RESPONSES_RESULT" "${TEST_ROOT}/responses-only.log" "${TEST_ROOT}/responses-only.count"
unset MOCK_PROVIDER_RESPONSES_ONLY
jq -e '.status == "confirmed" and .provider.api_mode == "responses" and .provider.capabilities.responses == true and .provider.capabilities.chat_completions == false' "$RESPONSES_RESULT" >/dev/null \
  || fail 'Responses-only 的真实探测结果未正确保存为 Responses 运行模式'
pass 'Responses-only 协议探测通过，运行模式明确交给受管适配器'

# 已确认配置只需要一次“复用”选择，不重新询问十项。
REUSE_TRANSCRIPT="${TEST_ROOT}/reuse-transcript.log"
REUSE_COUNT="${TEST_ROOT}/reuse-count"
run_pty_case reuse "$NORMAL_RESULT" "$REUSE_TRANSCRIPT" "$REUSE_COUNT"
[[ "$(<"$REUSE_COUNT")" == 1 ]] || fail '已有配置复用路径输入次数错误'
! grep -Fq '[1/10]' "$REUSE_TRANSCRIPT" || fail '复用已有配置仍重复运行十项向导'
jq -e '.status == "confirmed"' "$NORMAL_RESULT" >/dev/null || fail '复用后配置状态损坏'
pass '已有已确认配置直接复用'

# 输入在第三步前结束时必须保留前两步，重跑从第三步继续。
PARTIAL_RESULT="${TEST_ROOT}/partial-result.json"
PARTIAL_LOG="${TEST_ROOT}/partial.log"
set +e
printf '%s\n' 'https://provider.invalid/v1' "$TEST_PROVIDER_SECRET" \
  | env PATH="${MOCK_DIR}:${PATH}" TERM=dumb "$WIZARD" --output "$PARTIAL_RESULT" \
    > "$PARTIAL_LOG" 2>&1
PARTIAL_STATUS=$?
set -e
[[ "$PARTIAL_STATUS" == 2 ]] || fail 'EOF 没有以可恢复状态退出'
jq -e '.status == "collecting" and .next_step == 3' "$PARTIAL_RESULT" >/dev/null \
  || fail 'EOF 没有保存准确的恢复步骤'
[[ "$(jq -r '.provider.api_key' "$PARTIAL_RESULT")" == "$TEST_PROVIDER_SECRET" ]] \
  || fail '恢复状态没有保留已输入 API Key'
RESUME_TRANSCRIPT="${TEST_ROOT}/resume-transcript.log"
RESUME_COUNT="${TEST_ROOT}/resume-count"
run_pty_case resume "$PARTIAL_RESULT" "$RESUME_TRANSCRIPT" "$RESUME_COUNT"
[[ "$(<"$RESUME_COUNT")" == 8 ]] || fail '第三步恢复路径输入次数错误'
grep -Fq '从第 3 步继续' "$RESUME_TRANSCRIPT" || fail '未提示恢复步骤'
! grep -Fq '[1/10]' "$RESUME_TRANSCRIPT" || fail '恢复时错误地重问第一步'
jq -e '.status == "confirmed"' "$PARTIAL_RESULT" >/dev/null || fail '恢复后未确认配置'
pass 'EOF 安全退出与中断续跑'

# /models 不支持时允许在同一个第 3 项直接手动输入，仍必须实际验证 Chat。
MANUAL_MOCK_DIR="${TEST_ROOT}/manual-mock"
mkdir -p -- "$MANUAL_MOCK_DIR"
install -m 0755 /dev/stdin "${MANUAL_MOCK_DIR}/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

output_file=''
write_out=''
url=''
args=("$@")
while (( $# > 0 )); do
  case "$1" in
    --output|-o) output_file=$2; shift 2 ;;
    --write-out|-w) write_out=$2; shift 2 ;;
    http://*|https://*) url=$1; shift ;;
    --config|-K|--data-binary|--header|-H|--connect-timeout|--max-time|--request|-X|--proto|--max-redirs|--retry|--retry-delay|--retry-max-time)
      shift 2
      ;;
    *) shift ;;
  esac
done
if [[ "$url" == */models ]]; then
  [[ -z "$output_file" ]] || printf '%s' '{"error":"models endpoint unavailable"}' > "$output_file"
  [[ -z "$write_out" ]] || printf '404'
  exit 0
fi
exec "${REAL_WIZARD_CURL:?}" "${args[@]}"
SH
export REAL_WIZARD_CURL="${MOCK_DIR}/curl"
PTY_BASE_URL='http://127.0.0.1:18080/v1'
export PTY_BASE_URL
MANUAL_RESULT="${TEST_ROOT}/manual-result.json"
MANUAL_TRANSCRIPT="${TEST_ROOT}/manual-transcript.log"
MANUAL_COUNT="${TEST_ROOT}/manual-count"
run_pty_case manual "$MANUAL_RESULT" "$MANUAL_TRANSCRIPT" "$MANUAL_COUNT"
jq -e '
  .status == "confirmed" and
  .provider.model == "manual-chat-model" and
  .provider.model_discovery == "manual" and
  .provider.models_http_status == "404" and
  .provider.capabilities.chat_completions == true and
  .provider.loopback == true
' "$MANUAL_RESULT" >/dev/null || fail '模型列表失败后的手动模型结果错误'
grep -Fq '不会编造默认模型' "$MANUAL_TRANSCRIPT" || fail '模型列表失败没有明确降级说明'
pass '模型列表失败后的手动选择与 Chat 实际探测'

# 401 必须进入隐藏凭据纠错，不能把鉴权失败伪装成“手动模型即可继续”。
AUTH_MOCK_DIR="${TEST_ROOT}/auth-mock"
AUTH_COUNT_FILE="${TEST_ROOT}/auth-model-count"
mkdir -p -- "$AUTH_MOCK_DIR"
install -m 0755 /dev/stdin "${AUTH_MOCK_DIR}/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

output_file=''
write_out=''
url=''
args=("$@")
while (( $# > 0 )); do
  case "$1" in
    --output|-o) output_file=$2; shift 2 ;;
    --write-out|-w) write_out=$2; shift 2 ;;
    http://*|https://*) url=$1; shift ;;
    --config|-K|--data-binary|--header|-H|--connect-timeout|--max-time|--request|-X|--proto|--max-redirs|--retry|--retry-delay|--retry-max-time)
      shift 2
      ;;
    *) shift ;;
  esac
done
if [[ "$url" == */models && ! -e "${AUTH_COUNT_FILE:?}" ]]; then
  printf '1\n' > "$AUTH_COUNT_FILE"
  [[ -z "$output_file" ]] || printf '%s' '{"error":"unauthorized"}' > "$output_file"
  [[ -z "$write_out" ]] || printf '401'
  exit 0
fi
exec "${REAL_WIZARD_CURL:?}" "${args[@]}"
SH
export AUTH_COUNT_FILE
PTY_BASE_URL='https://provider.invalid/v1'
export PTY_BASE_URL
AUTH_RESULT="${TEST_ROOT}/auth-result.json"
AUTH_TRANSCRIPT="${TEST_ROOT}/auth-transcript.log"
AUTH_INPUT_COUNT="${TEST_ROOT}/auth-input-count"
run_pty_case auth "$AUTH_RESULT" "$AUTH_TRANSCRIPT" "$AUTH_INPUT_COUNT"
[[ "$(<"$AUTH_INPUT_COUNT")" == 11 ]] || fail '401 纠错路径输入次数错误'
[[ "$(jq -r '.provider.api_key' "$AUTH_RESULT")" == "$TEST_PROVIDER_REPLACEMENT" ]] \
  || fail '401 后的新 API Key 未保存'
grep -Fq 'Provider 鉴权失败（HTTP 401）' "$AUTH_TRANSCRIPT" || fail '401 没有明确纠错提示'
! grep -Fq -- "$TEST_PROVIDER_REPLACEMENT" "$AUTH_TRANSCRIPT" || fail '401 纠错输入被回显'
pass 'Provider 401 隐藏凭据纠错'

# 12 个模型验证分页、返回和搜索；序号始终对应稳定排序后的全局编号。
PAGED_MOCK_DIR="${TEST_ROOT}/paged-mock"
mkdir -p -- "$PAGED_MOCK_DIR"
install -m 0755 /dev/stdin "${PAGED_MOCK_DIR}/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

output_file=''
write_out=''
url=''
args=("$@")
while (( $# > 0 )); do
  case "$1" in
    --output|-o) output_file=$2; shift 2 ;;
    --write-out|-w) write_out=$2; shift 2 ;;
    http://*|https://*) url=$1; shift ;;
    --config|-K|--data-binary|--header|-H|--connect-timeout|--max-time|--request|-X|--proto|--max-redirs|--retry|--retry-delay|--retry-max-time)
      shift 2
      ;;
    *) shift ;;
  esac
done
if [[ "$url" == */models ]]; then
  body='{"data":[{"id":"model-12"},{"id":"model-03"},{"id":"model-01"},{"id":"model-11"},{"id":"model-04"},{"id":"model-02"},{"id":"model-10"},{"id":"model-05"},{"id":"model-06"},{"id":"model-07"},{"id":"model-08"},{"id":"model-09"},{"id":"model-12"}]}'
  [[ -z "$output_file" ]] || printf '%s' "$body" > "$output_file"
  [[ -z "$write_out" ]] || printf '200'
  exit 0
fi
exec "${REAL_WIZARD_CURL:?}" "${args[@]}"
SH
SEARCH_RESULT="${TEST_ROOT}/search-result.json"
SEARCH_TRANSCRIPT="${TEST_ROOT}/search-transcript.log"
SEARCH_COUNT="${TEST_ROOT}/search-count"
run_pty_case search "$SEARCH_RESULT" "$SEARCH_TRANSCRIPT" "$SEARCH_COUNT"
jq -e '.provider.model == "model-12" and .provider.model_discovery == "models_api"' \
  "$SEARCH_RESULT" >/dev/null || fail '分页搜索没有选择目标模型'
grep -Fq '检测到模型（第 2 页）' "$SEARCH_TRANSCRIPT" || fail '模型列表没有下一页'
grep -Fq '12. model-12' "$SEARCH_TRANSCRIPT" || fail '模型搜索结果或稳定编号错误'
pass '模型列表去重、分页与搜索'

# 域名模式发现 80/443 被占用时，不碰现有服务，要求改填完整生产 URL。
PORT_MOCK_DIR="${TEST_ROOT}/port-mock"
mkdir -p -- "$PORT_MOCK_DIR"
install -m 0755 /dev/stdin "${PORT_MOCK_DIR}/ss" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' 'LISTEN 0 4096 0.0.0.0:443 0.0.0.0:*'
SH
WIZARD_HTTPS_PORTS_MANAGED=0
export WIZARD_HTTPS_PORTS_MANAGED
PORT_RESULT="${TEST_ROOT}/port-result.json"
PORT_TRANSCRIPT="${TEST_ROOT}/port-transcript.log"
PORT_COUNT="${TEST_ROOT}/port-count"
run_pty_case port_conflict "$PORT_RESULT" "$PORT_TRANSCRIPT" "$PORT_COUNT"
[[ "$(<"$PORT_COUNT")" == 11 ]] || fail '端口冲突分流输入次数错误'
jq -e '
  .webhook.mode == "existing_url" and
  .webhook.public_base_url == "https://proxy.example.invalid/team/" and
  .webhook.production_url == "https://proxy.example.invalid/team/webhook/crisp-webhook"
' "$PORT_RESULT" >/dev/null || fail '端口冲突后完整 Webhook 地址处理错误'
grep -Fq 'TCP 80 或 443 已被占用' "$PORT_TRANSCRIPT" || fail '端口冲突没有明确提示'
grep -Fq '不会停止或覆盖现有网站' "$PORT_TRANSCRIPT" || fail '端口冲突缺少保护说明'
WIZARD_HTTPS_PORTS_MANAGED=1
export WIZARD_HTTPS_PORTS_MANAGED
pass '80/443 端口冲突进入已有反向代理分支'

# source 不得改变调用者选项；帮助必须在没有 curl/jq 的 PATH 下可用。
bash -c '
  set +e +u
  set +o pipefail
  before=$-
  before_pipe=$(set -o | grep "^pipefail")
  source "$1"
  after=$-
  after_pipe=$(set -o | grep "^pipefail")
  [[ "$before" == "$after" && "$before_pipe" == "$after_pipe" ]]
' -- "$WIZARD" || fail 'source wizard.sh 改变调用者 Shell 选项'
EMPTY_PATH="${TEST_ROOT}/empty-path"
mkdir -p -- "$EMPTY_PATH"
env PATH="$EMPTY_PATH" /bin/bash "$WIZARD" --help > "${TEST_ROOT}/help.log"
grep -Fq '十项中文快速初始化' "${TEST_ROOT}/help.log" || fail '--help 输出无效'
pass 'source 无副作用与无运行依赖的 --help'

bash -n "$WIZARD" "${SCRIPT_DIR}/test_wizard.sh"
shellcheck -x "$WIZARD" "${SCRIPT_DIR}/test_wizard.sh"
pass '向导脚本 Bash 语法与 ShellCheck'

printf '快速初始化向导专项测试：全部通过\n'
