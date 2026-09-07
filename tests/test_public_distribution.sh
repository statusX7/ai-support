#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
REMOTE_MODE=0
PASSED=0

usage() {
  cat <<'EOF'
用法：tests/test_public_distribution.sh [--local|--remote]

--local   只核对公开分发源码、唯一推荐命令和文档（默认）
--remote  另从无认证环境核对 public、Latest、raw get.sh 和正式资产
EOF
}

case "${1:---local}" in
  --local) ;;
  --remote) REMOTE_MODE=1 ;;
  --help|-h) usage; exit 0 ;;
  *) usage >&2; exit 64 ;;
esac
(( $# <= 1 )) || { usage >&2; exit 64; }

pass() {
  ((PASSED += 1))
  printf '通过：PUBLIC-DISTRIBUTION %s\n' "$1"
}

fail() {
  printf '失败：PUBLIC-DISTRIBUTION %s\n' "$1" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "缺少验收工具：$1"
}

extract_recommended_command() {
  local file=$1
  awk '
    /<!--[[:space:]]*CRISPAI_RECOMMENDED_INSTALL_COMMAND[[:space:]]*-->/ {
      markers += 1
      waiting = 1
      next
    }
    waiting && /^```bash[[:space:]]*$/ { in_code = 1; next }
    in_code && /^```[[:space:]]*$/ { in_code = 0; waiting = 0; next }
    in_code && length($0) {
      commands += 1
      command = $0
    }
    END {
      if (markers != 1 || commands != 1) exit 1
      print command
    }
  ' "$file"
}

VERSION_VALUE=$(<"${PROJECT_ROOT}/VERSION")
[[ "$VERSION_VALUE" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] \
  || fail 'VERSION 不是稳定语义版本'
REPOSITORY=${AI_SUPPORT_PUBLIC_REPOSITORY:-statusX7/ai-support}
[[ "$REPOSITORY" == statusX7/ai-support ]] \
  || fail '公开分发测试只允许目标仓库 statusX7/ai-support'

for file in README.md docs/INSTALL.md "docs/releases/${VERSION_VALUE}.md" \
  "docs/reports/${VERSION_VALUE}-report.md" get.sh scripts/package-release.sh; do
  [[ -f "${PROJECT_ROOT}/${file}" && ! -L "${PROJECT_ROOT}/${file}" ]] \
    || fail "缺少安全普通文件：${file}"
done
[[ -x "${PROJECT_ROOT}/get.sh" ]] || fail 'get.sh 不可执行'
bash -n "${PROJECT_ROOT}/get.sh"
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -x "${PROJECT_ROOT}/get.sh"
fi
grep -Fxq "GET_VERSION=\"${VERSION_VALUE}\"" "${PROJECT_ROOT}/get.sh" \
  || fail 'get.sh 版本与 VERSION 不一致'
grep -Fxq 'REPOSITORY="statusX7/ai-support"' "${PROJECT_ROOT}/get.sh" \
  || fail 'get.sh 目标仓库不正确'
grep -Fq '# crispai-get-end' "${PROJECT_ROOT}/get.sh" \
  || fail 'get.sh 缺少完整下载结束标记'
# 入口启动不得加载邻接模块；同版 --repair 在包下载/校验后才允许复用包内维护锁。
# 该延迟分支另由 test_get.sh 的单文件、坏包、缺模块和入口修复真实执行验证。
if ! awk '
  /^repair_package_launcher\(\) \($/ { repair = 1; next }
  /^\)$/ { repair = 0 }
  /^[[:space:]]*(source|\.)[[:space:]]+/ {
    if (!repair || $0 != "  source \"${package_root}/scripts/common.sh\"") invalid = 1
    count += 1
  }
  END { exit (invalid || count != 1) }
' "${PROJECT_ROOT}/get.sh"; then
  fail '独立 get.sh 在已校验包的延迟修复分支之外加载了邻接模块'
fi
pass '独立 get.sh 的版本、语法、仓库和无相邻模块边界'

TEST_ROOT=$(mktemp -d "${PROJECT_ROOT}/.test-public-distribution.XXXXXX")
cleanup() {
  if [[ "$TEST_ROOT" == "${PROJECT_ROOT}"/.test-public-distribution.* \
    && -d "$TEST_ROOT" && ! -L "$TEST_ROOT" ]]; then
    rm -rf -- "$TEST_ROOT"
  fi
}
trap cleanup EXIT INT TERM
mkdir -p -- "${TEST_ROOT}/bin" "${TEST_ROOT}/empty-home"
for command_name in curl wget apt-get sudo docker; do
  # shellcheck disable=SC2016 # 环境变量由运行时 mock 接收，不在生成阶段展开。
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s" >> "${MOCK_SIDE_EFFECT_LOG:?}"\nexit 99\n' \
    "$command_name" > "${TEST_ROOT}/bin/${command_name}"
  chmod 0700 "${TEST_ROOT}/bin/${command_name}"
done
SIDE_EFFECT_LOG="${TEST_ROOT}/side-effects"
MOCK_SIDE_EFFECT_LOG="$SIDE_EFFECT_LOG" PATH="${TEST_ROOT}/bin:/usr/bin:/bin" \
  "${PROJECT_ROOT}/get.sh" --help >/dev/null
VERSION_OUTPUT=$(MOCK_SIDE_EFFECT_LOG="$SIDE_EFFECT_LOG" \
  PATH="${TEST_ROOT}/bin:/usr/bin:/bin" "${PROJECT_ROOT}/get.sh" --version)
[[ "$VERSION_OUTPUT" == "$VERSION_VALUE" ]] || fail 'get.sh --version 输出错误'
[[ ! -e "$SIDE_EFFECT_LOG" ]] || fail 'get.sh help/version 发生网络、提权或服务副作用'
set +e
MOCK_SIDE_EFFECT_LOG="$SIDE_EFFECT_LOG" PATH="${TEST_ROOT}/bin:/usr/bin:/bin" \
  "${PROJECT_ROOT}/get.sh" --release '../v1.1.1' >"${TEST_ROOT}/invalid.out" \
  2>"${TEST_ROOT}/invalid.err"
INVALID_STATUS=$?
set -e
(( INVALID_STATUS == 64 )) || fail 'get.sh 未以 64 拒绝非法 release'
[[ ! -e "$SIDE_EFFECT_LOG" ]] || fail '非法 release 在拒绝前发生副作用'
pass 'help/version/非法参数在无网络副作用下完成'

README_COMMAND=$(extract_recommended_command "${PROJECT_ROOT}/README.md") \
  || fail 'README 没有唯一、单行的推荐安装命令标记'
INSTALL_COMMAND=$(extract_recommended_command "${PROJECT_ROOT}/docs/INSTALL.md") \
  || fail 'INSTALL 没有唯一、单行的推荐安装命令标记'
RELEASE_COMMAND=$(extract_recommended_command \
  "${PROJECT_ROOT}/docs/releases/${VERSION_VALUE}.md") \
  || fail '版本发布说明没有唯一、单行的推荐安装命令标记'
[[ "$README_COMMAND" == "$INSTALL_COMMAND" \
  && "$README_COMMAND" == "$RELEASE_COMMAND" ]] \
  || fail 'README、INSTALL 与发布说明的推荐命令不完全一致'
[[ "$README_COMMAND" == *'https://raw.githubusercontent.com/statusX7/ai-support/main/get.sh'* \
  && "$README_COMMAND" == *'mktemp'* \
  && "$README_COMMAND" == *'curl -q'* \
  && "$README_COMMAND" == *'# crispai-get-end'* ]] \
  || fail '推荐命令没有安全下载 raw get.sh、随机临时文件或完整性标记检查'
pass '三处唯一推荐安装命令逐字一致'

if grep -Eiq '(^|[[:space:]#])(方法[[:space:]]*[A-Z：:]|浏览器下载|SFTP|上传服务器|上传到服务器)' \
    "${PROJECT_ROOT}/README.md" "${PROJECT_ROOT}/docs/INSTALL.md"; then
  fail '新手主路径仍包含浏览器下载或上传服务器步骤'
fi
if grep -Eq '(^|[[:space:]])(sha256sum --check|tar -xzf|cd ai-support-v[0-9])' \
    "${PROJECT_ROOT}/README.md" "${PROJECT_ROOT}/docs/INSTALL.md"; then
  fail '新手主路径仍要求手工校验、解压或切换目录'
fi
if grep -Eiq '(需要|必须|要求).{0,24}(GitHub 登录|GitHub Token|gh auth|git clone)' \
    "${PROJECT_ROOT}/README.md" "${PROJECT_ROOT}/docs/INSTALL.md"; then
  fail '新手主路径仍把 GitHub 登录、Token 或 clone 作为前置条件'
fi
# shellcheck disable=SC2016 # 反引号是 Markdown 文本，不是命令替换。
grep -Fq '仓库 `statusX7/ai-support` 自 2026-09-06 起保持公开（Public）' \
  "${PROJECT_ROOT}/AGENTS.md" || fail 'AGENTS.md 没有保持公开仓库的现行策略'
pass '活跃新手文档没有手工下载、上传、解压或登录前置'

# 菜单标题以生产渲染模块为唯一来源，逐项核对新手可见文档，防止编号或名称漂移。
# shellcheck source=scripts/menu-ui.sh disable=SC1091
source "${PROJECT_ROOT}/scripts/menu-ui.sh"
(( ${#MENU_TITLES[@]} == 18 && ${#MENU_ICONS[@]} == 18 )) \
  || fail '生产主菜单不是 18 个唯一标题/图标'
for index in "${!MENU_TITLES[@]}"; do
  number=$((index + 1))
  title=${MENU_TITLES[index]}
  grep -Fq "| ${number} | ${title} |" "${PROJECT_ROOT}/docs/MENU.md" \
    || fail "MENU 文档与生产菜单不一致：${number}. ${title}"
done
for required_doc in INSTALL.md MENU.md CRISP.md CONFIG.md TESTING.md \
  TROUBLESHOOTING.md SECURITY.md RELEASE.md; do
  [[ -f "${PROJECT_ROOT}/docs/${required_doc}" \
    && ! -L "${PROJECT_ROOT}/docs/${required_doc}" ]] \
    || fail "公开操作文档缺失或不安全：docs/${required_doc}"
done
grep -Fq 'crispai doctor [--local|--full] [--json] [--fix]' \
  "${PROJECT_ROOT}/scripts/launcher.sh" \
  || fail '受管 crispai 帮助没有列出自检模式'
grep -Fq '1 匿名在线更新至最新正式版' "${PROJECT_ROOT}/docs/MENU.md" \
  || fail '菜单 14 文档没有匿名在线更新入口'
pass '18 项生产菜单、crispai 帮助与公开操作文档逐项一致'

for required in 'get.sh' 'scripts/doctor.sh' 'tests/test_get.sh' \
  'tests/test_doctor.sh' 'tests/test_public_distribution.sh' \
  'tests/test_legacy_rollback.sh'; do
  grep -Fq "$required" "${PROJECT_ROOT}/scripts/package-release.sh" \
    || fail "正式包固定清单没有包含 ${required}"
done
pass '正式包清单包含在线入口、自检和对应验收代码'

if (( REMOTE_MODE == 0 )); then
  printf '公开分发本地验收完成：%d 项通过。远端匿名检查未执行。\n' "$PASSED"
  exit 0
fi

for command_name in curl jq python3 sha256sum cmp; do require_command "$command_name"; done
CURL_BIN=$(command -v curl)

anonymous_download() {
  local url=$1 output=$2
  env -i PATH=/usr/bin:/bin HOME="${TEST_ROOT}/empty-home" \
    "$CURL_BIN" -q --fail --silent --show-error --location \
      --proto '=https' --proto-redir '=https' --tlsv1.2 \
      --retry 2 --retry-delay 1 --connect-timeout 15 --max-time 300 \
      --user-agent 'crispai-public-distribution-test' \
      --output "${output}.part" "$url"
  [[ -s "${output}.part" ]] || fail "匿名下载结果为空：${url}"
  mv -f -- "${output}.part" "$output"
}

API_ROOT="https://api.github.com/repos/${REPOSITORY}"
anonymous_download "$API_ROOT" "${TEST_ROOT}/repository.json"
jq -e --arg repository "$REPOSITORY" \
  '.full_name == $repository and .private == false and .visibility == "public"' \
  "${TEST_ROOT}/repository.json" >/dev/null \
  || fail '匿名 GitHub API 没有确认目标仓库为 public'
pass '匿名 API 确认现有仓库为 public'

anonymous_download "${API_ROOT}/releases/latest" "${TEST_ROOT}/latest.json"
jq -e --arg version "$VERSION_VALUE" \
  '.tag_name == $version and .draft == false and .prerelease == false' \
  "${TEST_ROOT}/latest.json" >/dev/null \
  || fail 'Latest 不是当前非草稿、非预发布版本'
for asset in "ai-support-${VERSION_VALUE}.tar.gz" SHA256SUMS; do
  jq -e --arg name "$asset" \
    '[.assets[] | select(.name == $name)] | length == 1' \
    "${TEST_ROOT}/latest.json" >/dev/null \
    || fail "Latest 缺少唯一资产：${asset}"
done
pass '匿名 Latest 元数据、正式状态和必要资产'

RAW_ROOT="https://raw.githubusercontent.com/${REPOSITORY}"
anonymous_download "${RAW_ROOT}/main/get.sh" "${TEST_ROOT}/get-main.sh"
anonymous_download "${RAW_ROOT}/${VERSION_VALUE}/get.sh" "${TEST_ROOT}/get-tag.sh"
cmp -s "${TEST_ROOT}/get-main.sh" "${TEST_ROOT}/get-tag.sh" \
  || fail 'main/get.sh 与当前稳定 tag 不一致'
cmp -s "${TEST_ROOT}/get-tag.sh" "${PROJECT_ROOT}/get.sh" \
  || fail '公开 tag/get.sh 与本地冻结源码不一致'
[[ "$(tail -n 1 "${TEST_ROOT}/get-main.sh")" == '# crispai-get-end' ]] \
  || fail '匿名 raw get.sh 缺少结束标记'
bash -n "${TEST_ROOT}/get-main.sh"
pass '匿名 raw main/tag get.sh 与冻结源码一致'

anonymous_download "${RAW_ROOT}/main/README.md" "${TEST_ROOT}/README.remote.md"
anonymous_download "${RAW_ROOT}/main/docs/INSTALL.md" "${TEST_ROOT}/INSTALL.remote.md"
REMOTE_README_COMMAND=$(extract_recommended_command "${TEST_ROOT}/README.remote.md") \
  || fail '公开 README 推荐命令结构无效'
REMOTE_INSTALL_COMMAND=$(extract_recommended_command "${TEST_ROOT}/INSTALL.remote.md") \
  || fail '公开 INSTALL 推荐命令结构无效'
REMOTE_RELEASE_BODY=$(jq -r '.body' "${TEST_ROOT}/latest.json")
printf '%s\n' "$REMOTE_RELEASE_BODY" > "${TEST_ROOT}/release.remote.md"
REMOTE_RELEASE_COMMAND=$(extract_recommended_command "${TEST_ROOT}/release.remote.md") \
  || fail '公开 Release 说明推荐命令结构无效'
[[ "$REMOTE_README_COMMAND" == "$README_COMMAND" \
  && "$REMOTE_INSTALL_COMMAND" == "$README_COMMAND" \
  && "$REMOTE_RELEASE_COMMAND" == "$README_COMMAND" ]] \
  || fail '公开 README、INSTALL、Release 与冻结命令不一致'
pass '公开页面三处推荐命令与冻结源码一致'

DOWNLOAD_ROOT="https://github.com/${REPOSITORY}/releases/download/${VERSION_VALUE}"
ARCHIVE_NAME="ai-support-${VERSION_VALUE}.tar.gz"
anonymous_download "${DOWNLOAD_ROOT}/${ARCHIVE_NAME}" "${TEST_ROOT}/${ARCHIVE_NAME}"
anonymous_download "${DOWNLOAD_ROOT}/SHA256SUMS" "${TEST_ROOT}/SHA256SUMS"
CHECKSUM_RECORDS=$(awk -v name="$ARCHIVE_NAME" '
  $0 ~ /^[0-9a-fA-F]{64}  [^[:space:]]+$/ && $2 == name { count += 1 }
  END { print count + 0 }
' "${TEST_ROOT}/SHA256SUMS")
NONEMPTY_RECORDS=$(awk 'NF { count += 1 } END { print count + 0 }' \
  "${TEST_ROOT}/SHA256SUMS")
(( CHECKSUM_RECORDS == 1 && NONEMPTY_RECORDS == 1 )) \
  || fail '远端 SHA256SUMS 不是目标归档的唯一严格记录'
EXPECTED_SHA=$(awk -v name="$ARCHIVE_NAME" '$2 == name { print tolower($1) }' \
  "${TEST_ROOT}/SHA256SUMS")
ACTUAL_SHA=$(sha256sum "${TEST_ROOT}/${ARCHIVE_NAME}")
ACTUAL_SHA=${ACTUAL_SHA%% *}
[[ "$ACTUAL_SHA" == "$EXPECTED_SHA" ]] || fail '匿名下载的正式包 SHA-256 不匹配'
pass '匿名固定 tag 资产严格 SHA-256 校验'

python3 - "${TEST_ROOT}/${ARCHIVE_NAME}" "$VERSION_VALUE" <<'PY'
import pathlib
import re
import sys
import tarfile

archive_path, version = sys.argv[1:]
expected_root = "ai-support-" + version
required = {
    "VERSION", "get.sh", "install.sh", "manage.sh", "update.sh", "uninstall.sh",
    "docker-compose.yml", "scripts/common.sh", "scripts/bootstrap.sh",
    "scripts/doctor.sh", "scripts/healthcheck.sh", "scripts/menu-ui.sh",
    "scripts/rollback.sh", "scripts/archive-guard.py", "scripts/package-release.sh",
    "n8n/workflow.json", "n8n/runtime.js",
    "docs/INSTALL.md", "docs/MENU.md", "docs/CRISP.md",
    "docs/TROUBLESHOOTING.md", "docs/RELEASE.md",
    "docs/releases/" + version + ".md",
    "docs/reports/" + version + "-report.md",
    "tests/test_get.sh", "tests/test_doctor.sh", "tests/test_public_distribution.sh",
    "tests/test_legacy_rollback.sh",
}
seen = set()
regular = set()
total = 0
known_secret = re.compile(
    rb'(?:AKIA|ASIA)[0-9A-Z]{16}|sk-[A-Za-z0-9_-]{20,}|'
    rb'gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,}|'
    rb'xox[baprs]-[A-Za-z0-9-]{10,}|'
    rb'-----BEGIN (?:[A-Z0-9 ]+ )?PRIVATE KEY-----'
)
with tarfile.open(archive_path, "r:gz") as archive:
    members = archive.getmembers()
    if not members or len(members) > 10000:
        raise SystemExit("归档为空或成员过多")
    for member in members:
        name = member.name[:-1] if member.name.endswith("/") else member.name
        if (not name or name.startswith("/") or "\\" in name
                or any(ord(ch) < 32 for ch in name)):
            raise SystemExit("归档路径不安全")
        raw_parts = name.split("/")
        parts = pathlib.PurePosixPath(name).parts
        if (not parts or tuple(raw_parts) != parts or parts[0] != expected_root
                or any(p in ("", ".", "..") for p in raw_parts)):
            raise SystemExit("归档顶层或成员路径错误")
        if name in seen:
            raise SystemExit("归档包含重复成员")
        seen.add(name)
        if not (member.isfile() or member.isdir()):
            raise SystemExit("归档包含链接或特殊文件")
        total += max(member.size, 0)
        if total > 4 * 1024**3:
            raise SystemExit("归档展开容量超过限制")
        if member.isfile():
            regular.add("/".join(parts[1:]))
            stream = archive.extractfile(member)
            if stream is None:
                raise SystemExit("无法读取归档普通文件")
            carry = b""
            while True:
                chunk = stream.read(1024 * 1024)
                if not chunk:
                    break
                sample = carry + chunk
                if known_secret.search(sample):
                    raise SystemExit("归档疑似包含真实密钥模式")
                carry = sample[-256:]
missing = sorted(required - regular)
if missing:
    raise SystemExit("归档缺少必要文件：" + ", ".join(missing))
PY
[[ "$(tar -xOf "${TEST_ROOT}/${ARCHIVE_NAME}" \
  "ai-support-${VERSION_VALUE}/VERSION")" == "$VERSION_VALUE" ]] \
  || fail '正式包内部 VERSION 不一致'
ARCHIVE_MEMBERS=$(tar -tzf "${TEST_ROOT}/${ARCHIVE_NAME}") \
  || fail '无法读取正式包成员清单'
if grep -Eq '(^|/)(\.git|\.work|\.env|data|logs|backups)(/|$)' \
    <<< "$ARCHIVE_MEMBERS"; then
  fail '正式包包含 Git、运行数据、秘密或开发证据目录'
fi
pass '匿名正式包路径、类型、容量、清单、版本和秘密边界'

printf '公开分发完整验收完成：%d 项通过，仓库/下载请求均未使用 GitHub 认证。\n' \
  "$PASSED"
