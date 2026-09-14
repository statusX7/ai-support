#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
REPOSITORY="statusX7/ai-support"
ARTIFACTS_REQUEST="${PROJECT_ROOT}/dist"
TARGET_RECEIPT_REQUEST=""
VERIFICATION_REQUEST=""
PUBLISH_VERSION=""
DRY_RUN=0
DOWNLOAD_DIR=""

usage() {
  cat <<'EOF'
用法：scripts/publish-release.sh --publish VERSION --target-receipt FILE [选项]

选项：
  --artifacts DIR       冻结资产目录，默认 ./dist
  --verification FILE   仅向已正式发布的同版本追加严格核对的公开验证附件
  --dry-run             只执行本地同包门禁并展示动作，不创建 tag、不联网、不发布
  --help                显示帮助

只有显式 --publish VERSION 且同提交、同归档 TARGET-A 门禁通过后，正式模式才会
创建 annotated tag、原子推送、建立 draft、回下载核对并发布为 Latest。
EOF
}

die() {
  printf '发布已阻止：%s\n' "$1" >&2
  exit "${2:-1}"
}

cleanup() {
  if [[ -n "$DOWNLOAD_DIR" && "$DOWNLOAD_DIR" == /tmp/crispai-release-verify.* \
    && -d "$DOWNLOAD_DIR" && ! -L "$DOWNLOAD_DIR" ]]; then
    rm -rf -- "$DOWNLOAD_DIR"
  fi
}
trap cleanup EXIT INT TERM

while (( $# > 0 )); do
  case "$1" in
    --publish)
      (( $# >= 2 )) || die '--publish 缺少版本' 64
      [[ -z "$PUBLISH_VERSION" ]] || die '--publish 只能指定一次' 64
      PUBLISH_VERSION=$2
      shift 2
      ;;
    --target-receipt)
      (( $# >= 2 )) || die '--target-receipt 缺少文件' 64
      TARGET_RECEIPT_REQUEST=$2
      shift 2
      ;;
    --artifacts)
      (( $# >= 2 )) || die '--artifacts 缺少目录' 64
      ARTIFACTS_REQUEST=$2
      shift 2
      ;;
    --verification)
      (( $# >= 2 )) || die '--verification 缺少文件' 64
      [[ -z "$VERIFICATION_REQUEST" ]] || die '--verification 只能指定一次' 64
      VERIFICATION_REQUEST=$2
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *) die "未知选项：$1" 64 ;;
  esac
done

[[ "$PUBLISH_VERSION" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] \
  || die '必须显式使用 --publish vX.Y.Z' 64
[[ "$PUBLISH_VERSION" == v1.3.0 ]] \
  || die '本轮发布政策只授权 v1.3.0；不会自动选择或发布其他版本' 64
[[ -n "$TARGET_RECEIPT_REQUEST" ]] || die '必须提供 --target-receipt' 64
if (( DRY_RUN )) && [[ -n "$VERIFICATION_REQUEST" ]]; then
  die '--verification 只能用于已正式发布版本，不能与 --dry-run 同时使用' 64
fi
for command_name in git python3 realpath sha256sum; do
  command -v "$command_name" >/dev/null 2>&1 || die "缺少维护工具：${command_name}"
done

ARTIFACTS_LEXICAL=$(realpath -se -- "$ARTIFACTS_REQUEST") \
  || die '冻结资产目录不存在'
ARTIFACTS_DIR=$(realpath -e -- "$ARTIFACTS_REQUEST") \
  || die '冻结资产目录不存在'
TARGET_RECEIPT_LEXICAL=$(realpath -se -- "$TARGET_RECEIPT_REQUEST") \
  || die 'TARGET-A 验收回执不存在'
TARGET_RECEIPT=$(realpath -e -- "$TARGET_RECEIPT_REQUEST") \
  || die 'TARGET-A 验收回执不存在'
[[ "$ARTIFACTS_LEXICAL" == "$ARTIFACTS_DIR" && -d "$ARTIFACTS_DIR" && ! -L "$ARTIFACTS_DIR" ]] \
  || die '冻结资产目录或其父路径不得使用符号链接'
[[ "$TARGET_RECEIPT_LEXICAL" == "$TARGET_RECEIPT" && -f "$TARGET_RECEIPT" && ! -L "$TARGET_RECEIPT" ]] \
  || die 'TARGET-A 验收回执或其父路径不得使用符号链接'

VERSION_VALUE=$(git -C "$PROJECT_ROOT" show 'HEAD:VERSION') || die '无法读取当前提交版本'
[[ "$VERSION_VALUE" == "$PUBLISH_VERSION" ]] \
  || die "确认版本 ${PUBLISH_VERSION} 与当前提交 ${VERSION_VALUE:-未知} 不一致"
SOURCE_COMMIT=$(git -C "$PROJECT_ROOT" rev-parse --verify 'HEAD^{commit}') \
  || die '无法锁定当前提交'
python3 "${PROJECT_ROOT}/scripts/release-gate.py" --verify-source --commit "$SOURCE_COMMIT" \
  >/dev/null || die '当前提交未通过 v1.3.0 唯一版本与源码身份政策'
ARCHIVE_NAME="ai-support-${VERSION_VALUE}.tar.gz"
ARCHIVE_PATH="${ARTIFACTS_DIR}/${ARCHIVE_NAME}"
RELEASE_NOTES="${PROJECT_ROOT}/docs/releases/${VERSION_VALUE}.md"
VERIFICATION_NAME="${VERSION_VALUE}-verification.md"
VERIFICATION_FILE=""
[[ -f "$ARCHIVE_PATH" && ! -L "$ARCHIVE_PATH" ]] || die '冻结归档不存在或不安全'
[[ -f "$RELEASE_NOTES" && ! -L "$RELEASE_NOTES" ]] || die '当前版本发布说明不存在或不安全'
FROZEN_SHA=$(sha256sum "$ARCHIVE_PATH")
FROZEN_SHA=${FROZEN_SHA%% *}

validate_verification_file() {
  local file=$1 release_url="https://github.com/${REPOSITORY}/releases/tag/${VERSION_VALUE}"
  python3 - "$file" "$VERSION_VALUE" "$SOURCE_COMMIT" "$FROZEN_SHA" "$release_url" <<'PY'
import json
import os
from pathlib import Path
import re
import stat
import sys
from urllib.parse import urlsplit

path = Path(sys.argv[1])
version, commit, archive_sha256, release_url = sys.argv[2:]
try:
    expected_info = path.lstat()
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
except OSError:
    raise SystemExit(1)
with os.fdopen(descriptor, "rb") as stream:
    info = os.fstat(stream.fileno())
    if (not stat.S_ISREG(info.st_mode) or info.st_nlink != 1
            or info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) & 0o022
            or not 0 < info.st_size <= 256 * 1024
            or (info.st_dev, info.st_ino) != (expected_info.st_dev, expected_info.st_ino)):
        raise SystemExit(1)
    raw = stream.read(256 * 1024 + 1)
if len(raw) != info.st_size:
    raise SystemExit(1)
if b"\0" in raw or b"\r" in raw or not raw.endswith(b"\n"):
    raise SystemExit(1)
try:
    text = raw.decode("utf-8")
except UnicodeDecodeError:
    raise SystemExit(1)
lines = text.splitlines()
match = re.fullmatch(r"<!-- crispai-verification: (\{.*\}) -->", lines[0] if lines else "")
if not match:
    raise SystemExit(1)

def unique_object(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError("duplicate")
        value[key] = item
    return value

try:
    metadata = json.loads(match.group(1), object_pairs_hook=unique_object)
except (json.JSONDecodeError, ValueError):
    raise SystemExit(1)
expected = {
    "schema_version": 1,
    "version": version,
    "commit": commit,
    "archive_sha256": archive_sha256,
    "release_url": release_url,
}
if metadata != expected or type(metadata.get("schema_version")) is not int:
    raise SystemExit(1)
if len("\n".join(lines[1:]).strip()) < 20:
    raise SystemExit(1)

# 验证附件只应记录公开发布事实。移除唯一允许的身份值后，对剩余正文做
# 保守扫描；这不是通用秘密扫描器，发布者仍须执行完整公开面检查。
scrubbed = text.replace(commit, "<commit>").replace(archive_sha256, "<archive-sha256>") \
    .replace(release_url, "<release-url>")
patterns = (
    r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----",
    r"\b(?:Bearer|Basic)\s+[A-Za-z0-9+/=_-]{8,}",
    r"\b(?:sk-[A-Za-z0-9_-]{12,}|github_pat_[A-Za-z0-9_]{12,}|gh[pousr]_[A-Za-z0-9_]{12,})\b",
    r"(?im)^\s*(?:[-*]\s*)?(?:api[_ -]?key|token(?:[_ -]?(?:key|secret|identifier))?|password|passwd|authorization|cookie|credential|ssh[_ -]?(?:host|port|user))\s*[:=：]\s*\S+",
    r"\bsession_[A-Za-z0-9-]{8,128}\b",
    r"(?i)\btarget-[a-z0-9_-]+\b",
    r"(?im)^\s*(?:[-*]\s*)?target(?:[_ -]?(?:alias|id|identifier|host|name))?\s*[:=：]\s*\S+",
    r"(?im)^\s*(?:[-*]\s*)?(?:host(?:name)?|user(?:name)?|account|login)\s*[:=：]\s*\S+",
    r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}\b",
    r"(?<![0-9])(?:25[0-5]|2[0-4]\d|1?\d?\d)(?:\.(?:25[0-5]|2[0-4]\d|1?\d?\d)){3}(?![0-9])",
    r"(?i)(?<![0-9a-f])(?:[0-9a-f]{0,4}:){2,}[0-9a-f]{0,4}(?![0-9a-f])",
)
if any(re.search(pattern, scrubbed) for pattern in patterns):
    raise SystemExit(1)
urls = re.findall(r"https?://[^\s<>()`\"']+", scrubbed)
for url in urls:
    url = url.rstrip(".,;:!?。，；：！？")
    parsed = urlsplit(url)
    github_path = "/statusX7/ai-support"
    if not (parsed.scheme == "https" and (
            parsed.netloc == "github.com"
            and (parsed.path == github_path or parsed.path.startswith(github_path + "/"))
            or parsed.netloc == "raw.githubusercontent.com"
            and parsed.path.startswith(github_path + "/"))):
        raise SystemExit(1)
PY
}

if [[ -n "$VERIFICATION_REQUEST" ]]; then
  VERIFICATION_LEXICAL=$(realpath -se -- "$VERIFICATION_REQUEST") \
    || die '公开验证附件不存在'
  VERIFICATION_FILE=$(realpath -e -- "$VERIFICATION_REQUEST") \
    || die '公开验证附件不存在'
  [[ "$VERIFICATION_LEXICAL" == "$VERIFICATION_FILE" && -f "$VERIFICATION_FILE" \
    && ! -L "$VERIFICATION_FILE" && "$(basename -- "$VERIFICATION_FILE")" == "$VERIFICATION_NAME" ]] \
    || die "公开验证附件必须是无符号链接路径的 ${VERIFICATION_NAME}"
  validate_verification_file "$VERIFICATION_FILE" \
    || die '公开验证附件的身份、格式或敏感信息检查未通过'
fi

verify_frozen_identity() {
  local current current_sha
  current=$(git -C "$PROJECT_ROOT" rev-parse --verify 'HEAD^{commit}') \
    || die '无法重新读取当前提交'
  [[ "$current" == "$SOURCE_COMMIT" ]] || die '门禁后 HEAD 已变化'
  current_sha=$(sha256sum "$ARCHIVE_PATH")
  current_sha=${current_sha%% *}
  [[ "$current_sha" == "$FROZEN_SHA" ]] || die '门禁后冻结归档已变化'
  python3 "${PROJECT_ROOT}/scripts/release-gate.py" \
    --artifacts "$ARTIFACTS_DIR" --target-receipt "$TARGET_RECEIPT" >/dev/null \
    || die '当前提交、冻结包或 TARGET-A 回执未通过门禁'
}

verify_frozen_identity
LOCAL_TAG_EXISTS=0
LOCAL_TAG_OBJECT=""
inspect_local_tag() {
  LOCAL_TAG_EXISTS=0
  LOCAL_TAG_OBJECT=""
  if ! git -C "$PROJECT_ROOT" show-ref --verify --quiet "refs/tags/${VERSION_VALUE}"; then
    return 0
  fi
  [[ "$(git -C "$PROJECT_ROOT" cat-file -t "refs/tags/${VERSION_VALUE}" 2>/dev/null)" == tag ]] \
    || die "本地 ${VERSION_VALUE} 不是 annotated tag；不会覆盖或复用"
  [[ "$(git -C "$PROJECT_ROOT" rev-parse --verify "${VERSION_VALUE}^{commit}" 2>/dev/null)" == "$SOURCE_COMMIT" ]] \
    || die "本地 tag ${VERSION_VALUE} 未指向本次已验收提交；不会覆盖或复用"
  LOCAL_TAG_OBJECT=$(git -C "$PROJECT_ROOT" rev-parse --verify "refs/tags/${VERSION_VALUE}") \
    || die '无法读取本地 tag 对象'
  LOCAL_TAG_EXISTS=1
}
inspect_local_tag

if (( DRY_RUN )); then
  printf 'Dry-run 通过：%s\n' "$VERSION_VALUE"
  printf '固定提交：%s\n' "$SOURCE_COMMIT"
  printf '固定归档 SHA-256：%s\n' "$FROZEN_SHA"
  printf '%s\n' '未创建 tag、未连接 GitHub、未推送或发布。'
  exit 0
fi

for command_name in awk cp gh mktemp; do
  command -v "$command_name" >/dev/null 2>&1 || die "缺少维护工具：${command_name}"
done
[[ "$(git -C "$PROJECT_ROOT" branch --show-current)" == main ]] \
  || die '正式发布只能从 main 分支执行'
is_expected_origin() {
  case "$1" in
    git@github.com:statusX7/ai-support|git@github.com:statusX7/ai-support.git|\
    ssh://git@github.com/statusX7/ai-support|ssh://git@github.com/statusX7/ai-support.git|\
    https://github.com/statusX7/ai-support|https://github.com/statusX7/ai-support.git) return 0 ;;
    *) return 1 ;;
  esac
}
ORIGIN_URL=$(git -C "$PROJECT_ROOT" remote get-url origin) \
  || die '无法读取 origin'
ORIGIN_PUSH_URL=$(git -C "$PROJECT_ROOT" remote get-url --push origin) \
  || die '无法读取 origin push URL'
if ! is_expected_origin "$ORIGIN_URL" || ! is_expected_origin "$ORIGIN_PUSH_URL"; then
  die 'origin 的读取或推送地址不是预期的 statusX7/ai-support，拒绝推送'
fi
gh auth status --active --hostname github.com >/dev/null 2>&1 \
  || die '当前 GitHub CLI 身份不可用'
REPOSITORY_STATE=$(gh repo view "$REPOSITORY" --json nameWithOwner,isPrivate \
  --jq '.nameWithOwner + " " + (.isPrivate|tostring)') \
  || die '无法核对 GitHub 仓库'
[[ "$REPOSITORY_STATE" == "$REPOSITORY false" ]] \
  || die '目标仓库身份不符或不是 Public'

DOWNLOAD_DIR=$(mktemp -d /tmp/crispai-release-verify.XXXXXXXX)
chmod 0700 "$DOWNLOAD_DIR"

REMOTE_TAG_EXISTS=0
REMOTE_TAG_OBJECT=""
probe_remote_tag() {
  local lines status direct peeled direct_count peeled_count
  set +e
  lines=$(git -C "$PROJECT_ROOT" ls-remote --exit-code --tags origin \
    "refs/tags/${VERSION_VALUE}" "refs/tags/${VERSION_VALUE}^{}" 2>/dev/null)
  status=$?
  set -e
  if (( status == 2 )); then
    REMOTE_TAG_EXISTS=0
    REMOTE_TAG_OBJECT=""
    return 0
  fi
  (( status == 0 )) || die '无法确认远端 tag 是否存在'
  direct=$(awk -v ref="refs/tags/${VERSION_VALUE}" '$2 == ref { print $1 }' <<< "$lines")
  peeled=$(awk -v ref="refs/tags/${VERSION_VALUE}^{}" '$2 == ref { print $1 }' <<< "$lines")
  direct_count=$(awk -v ref="refs/tags/${VERSION_VALUE}" '$2 == ref { count++ } END { print count+0 }' <<< "$lines")
  peeled_count=$(awk -v ref="refs/tags/${VERSION_VALUE}^{}" '$2 == ref { count++ } END { print count+0 }' <<< "$lines")
  [[ "$direct_count" == 1 && "$peeled_count" == 1 && "$peeled" == "$SOURCE_COMMIT" \
    && "$direct" =~ ^[a-f0-9]{40,64}$ ]] \
    || die "远端 tag ${VERSION_VALUE} 不是指向本次提交的唯一 annotated tag；不会覆盖或复用"
  REMOTE_TAG_EXISTS=1
  REMOTE_TAG_OBJECT=$direct
}

verify_remote_main() {
  local lines status commit count
  set +e
  lines=$(git -C "$PROJECT_ROOT" ls-remote --exit-code --heads origin refs/heads/main 2>/dev/null)
  status=$?
  set -e
  (( status == 0 )) || die '无法核对远端 main'
  commit=$(awk '$2 == "refs/heads/main" { print $1 }' <<< "$lines")
  count=$(awk '$2 == "refs/heads/main" { count++ } END { print count+0 }' <<< "$lines")
  [[ "$count" == 1 && "$commit" == "$SOURCE_COMMIT" ]] \
    || die '远端 tag 已存在，但 main 与本次已验收提交不一致；拒绝继续发布'
}

release_state_from_file() {
  local file=$1 allow_partial=${2:-0}
  python3 - "$file" "$VERSION_VALUE" "$ARCHIVE_NAME" "$VERIFICATION_NAME" "$allow_partial" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    record = json.load(stream)
expected = {sys.argv[3], "SHA256SUMS", "get.sh"}
verification = sys.argv[4]
assets = [entry.get("name") for entry in record.get("assets", []) if isinstance(entry, dict)]
asset_set = set(assets)
draft_assets_valid = asset_set.issubset(expected) if sys.argv[5] == "1" else asset_set == expected
published_assets_valid = asset_set in (expected, expected | {verification})
if (record.get("tagName") != sys.argv[2] or type(record.get("isDraft")) is not bool
        or record.get("isPrerelease") is not False or len(assets) != len(asset_set)
        or record["isDraft"] and not draft_assets_valid
        or not record["isDraft"] and not published_assets_valid):
    raise SystemExit(1)
print("draft" if record["isDraft"] else
      "published-verified" if verification in asset_set else "published")
PY
}

RELEASE_STATE=absent
probe_release() {
  local destination=$1 allow_partial=${2:-0} status api_output api_status http_status
  set +e
  gh release view "$VERSION_VALUE" --repo "$REPOSITORY" \
    --json tagName,isDraft,isPrerelease,assets > "$destination" 2>/dev/null
  status=$?
  set -e
  if (( status == 0 )); then
    RELEASE_STATE=$(release_state_from_file "$destination" "$allow_partial") \
      || die '已存在 Release 的版本、状态或资产集合不安全，拒绝复用'
    return 0
  fi
  set +e
  api_output=$(gh api --include "repos/${REPOSITORY}/releases/tags/${VERSION_VALUE}" 2>&1)
  api_status=$?
  set -e
  http_status=$(awk '/^HTTP\/[0-9.]+ [0-9][0-9][0-9]/{code=$2} END{print code}' <<< "$api_output")
  if (( api_status != 0 )) && [[ "$http_status" == 404 ]]; then
    RELEASE_STATE=absent
    return 0
  fi
  die '无法可靠区分 Release 不存在与 GitHub 鉴权、限流或网络故障'
}

probe_remote_tag
probe_release "${DOWNLOAD_DIR}/release-before.json" 1
if [[ "$RELEASE_STATE" != absent && "$REMOTE_TAG_EXISTS" != 1 ]]; then
  die 'Release 已存在但对应远端 annotated tag 缺失；拒绝继续'
fi
INITIAL_RELEASE_STATE=$RELEASE_STATE
if [[ -n "$VERIFICATION_FILE" && "$INITIAL_RELEASE_STATE" != published \
  && "$INITIAL_RELEASE_STATE" != published-verified ]]; then
  die '只有已经正式发布且核心身份核对通过的同版本才能追加公开验证附件'
fi
if [[ -n "$VERIFICATION_FILE" ]]; then
  # 不在校验后直接上传调用方仍可替换的路径；先复制至本进程私有目录，
  # 再按同一规则复核副本，后续比较和上传都只使用该副本。
  VERIFICATION_INPUT_DIR="${DOWNLOAD_DIR}/input"
  mkdir -m 0700 -- "$VERIFICATION_INPUT_DIR"
  VERIFICATION_UPLOAD_FILE="${VERIFICATION_INPUT_DIR}/${VERIFICATION_NAME}"
  cp -- "$VERIFICATION_FILE" "$VERIFICATION_UPLOAD_FILE" \
    || die '无法复制公开验证附件到私有核对目录'
  chmod 0600 -- "$VERIFICATION_UPLOAD_FILE"
  validate_verification_file "$VERIFICATION_UPLOAD_FILE" \
    || die '公开验证附件复制后的身份、格式或敏感信息检查未通过'
  VERIFICATION_FILE=$VERIFICATION_UPLOAD_FILE
fi
if (( REMOTE_TAG_EXISTS )); then
  verify_remote_main
fi
if (( LOCAL_TAG_EXISTS && REMOTE_TAG_EXISTS )) && [[ "$LOCAL_TAG_OBJECT" != "$REMOTE_TAG_OBJECT" ]]; then
  die '本地与远端 annotated tag 对象不一致；拒绝继续'
fi

verify_frozen_identity
if (( ! LOCAL_TAG_EXISTS )); then
  if (( REMOTE_TAG_EXISTS )); then
    git -C "$PROJECT_ROOT" fetch --no-tags origin \
      "refs/tags/${VERSION_VALUE}:refs/tags/${VERSION_VALUE}" \
      || die '远端 tag 已核对但无法安全恢复到本地'
  else
    git -C "$PROJECT_ROOT" tag -a "$VERSION_VALUE" "$SOURCE_COMMIT" \
      -m "${VERSION_VALUE}: verified CrispAI release" \
      || die '创建本地 annotated tag 失败'
  fi
  inspect_local_tag
fi
if (( REMOTE_TAG_EXISTS )) && [[ "$LOCAL_TAG_OBJECT" != "$REMOTE_TAG_OBJECT" ]]; then
  die '恢复后的本地与远端 annotated tag 对象不一致'
fi
verify_frozen_identity
if (( ! REMOTE_TAG_EXISTS )); then
  git -C "$PROJECT_ROOT" push --atomic origin \
    "${SOURCE_COMMIT}:refs/heads/main" "refs/tags/${VERSION_VALUE}:refs/tags/${VERSION_VALUE}" \
    || die 'main 与 tag 原子推送失败；不会创建 Release；同一命令可安全重试'
  probe_remote_tag
  verify_remote_main
  [[ "$REMOTE_TAG_OBJECT" == "$LOCAL_TAG_OBJECT" ]] \
    || die '推送后的远端 annotated tag 对象与本地不一致'
fi
verify_frozen_identity
if [[ "$RELEASE_STATE" == absent ]]; then
  gh release create "$VERSION_VALUE" \
    "$ARCHIVE_PATH" "${ARTIFACTS_DIR}/SHA256SUMS" "${ARTIFACTS_DIR}/get.sh" \
    --repo "$REPOSITORY" --verify-tag --draft \
    --title "$VERSION_VALUE" --notes-file "$RELEASE_NOTES" \
    || die '创建 draft Release 失败；若平台已接收部分状态，可用同一命令安全重试'
  RELEASE_STATE=draft
elif [[ "$RELEASE_STATE" == draft ]]; then
  # 上次失败可能只上传了部分资产。只允许预期的三个名称，并用同一冻结文件
  # 恢复它们；不删除或覆盖非本项目资产。
  verify_frozen_identity
  gh release edit "$VERSION_VALUE" --repo "$REPOSITORY" \
    --title "$VERSION_VALUE" --notes-file "$RELEASE_NOTES" \
    || die '无法恢复已有 draft 的标题或说明；Release 保持 draft'
  gh release upload "$VERSION_VALUE" \
    "$ARCHIVE_PATH" "${ARTIFACTS_DIR}/SHA256SUMS" "${ARTIFACTS_DIR}/get.sh" \
    --repo "$REPOSITORY" --clobber \
    || die '无法恢复已有 draft 的冻结资产；Release 保持 draft'
elif [[ "$RELEASE_STATE" != published && "$RELEASE_STATE" != published-verified ]]; then
  die 'Release 状态无法安全恢复'
fi

probe_release "${DOWNLOAD_DIR}/release-assets.json" 0
[[ "$RELEASE_STATE" == draft || "$RELEASE_STATE" == published \
  || "$RELEASE_STATE" == published-verified ]] \
  || die 'Release 资产上传后状态异常'
gh release download "$VERSION_VALUE" --repo "$REPOSITORY" --dir "$DOWNLOAD_DIR" \
  --pattern "$ARCHIVE_NAME" --pattern SHA256SUMS --pattern get.sh \
  || die '无法回下载 Release 资产；可用同一命令安全重试'
python3 "${PROJECT_ROOT}/scripts/release-gate.py" \
  --artifacts "$DOWNLOAD_DIR" --target-receipt "$TARGET_RECEIPT" >/dev/null \
  || die '回下载资产与已验收提交或归档不一致；draft 不会发布'
probe_remote_tag
[[ "$REMOTE_TAG_EXISTS" == 1 && "$REMOTE_TAG_OBJECT" == "$LOCAL_TAG_OBJECT" ]] \
  || die '发布前远端 tag 已偏离已验收对象；draft 不会发布'
verify_remote_main
probe_release "${DOWNLOAD_DIR}/release-verified.json" 0
verify_frozen_identity
if [[ "$RELEASE_STATE" == draft ]]; then
  gh release edit "$VERSION_VALUE" --repo "$REPOSITORY" \
    --draft=false --prerelease=false --latest \
    || die 'draft 资产已核对，但正式发布失败；可用同一命令复核并继续'
fi
gh release view "$VERSION_VALUE" --repo "$REPOSITORY" \
  --json tagName,isDraft,isPrerelease > "${DOWNLOAD_DIR}/published.json" \
  || die '正式发布后无法读取状态'
python3 - "${DOWNLOAD_DIR}/published.json" "$VERSION_VALUE" <<'PY'
import json
import sys

record = json.load(open(sys.argv[1], encoding="utf-8"))
if (record.get("tagName") != sys.argv[2] or record.get("isDraft") is not False
        or record.get("isPrerelease") is not False):
    raise SystemExit(1)
PY
LATEST_TAG=$(gh api "repos/${REPOSITORY}/releases/latest" --jq '.tag_name') \
  || die '正式发布后无法核对 Latest'
[[ "$LATEST_TAG" == "$VERSION_VALUE" ]] \
  || die '正式发布完成但 Latest 未指向本次版本，请停止交付并核查'

if [[ -n "$VERIFICATION_FILE" ]]; then
  # 该路径只会在本次调用开始时已经是 published 的版本到达。前三项
  # 核心资产、回执、tag、main 和 Latest 已在上面重新核对。
  VERIFICATION_DOWNLOAD_DIR="${DOWNLOAD_DIR}/verification"
  mkdir -m 0700 -- "$VERIFICATION_DOWNLOAD_DIR"
  if [[ "$INITIAL_RELEASE_STATE" == published-verified ]]; then
    gh release download "$VERSION_VALUE" --repo "$REPOSITORY" \
      --dir "$VERIFICATION_DOWNLOAD_DIR" --pattern "$VERIFICATION_NAME" \
      || die '无法回下载已有公开验证附件'
    [[ -f "${VERIFICATION_DOWNLOAD_DIR}/${VERIFICATION_NAME}" \
      && ! -L "${VERIFICATION_DOWNLOAD_DIR}/${VERIFICATION_NAME}" ]] \
      || die '已有公开验证附件缺失或不安全'
    validate_verification_file "${VERIFICATION_DOWNLOAD_DIR}/${VERIFICATION_NAME}" \
      || die '已有公开验证附件格式或身份不一致'
    cmp -s -- "$VERIFICATION_FILE" "${VERIFICATION_DOWNLOAD_DIR}/${VERIFICATION_NAME}" \
      || die '同名公开验证附件内容不同；不会覆盖已发布附件'
  else
    gh release upload "$VERSION_VALUE" "$VERIFICATION_FILE" --repo "$REPOSITORY" \
      || die '上传公开验证附件失败；不会覆盖同名附件，可用相同命令复核'
    probe_release "${DOWNLOAD_DIR}/release-with-verification.json" 0
    [[ "$RELEASE_STATE" == published-verified ]] \
      || die '公开验证附件上传后资产集合不一致'
    gh release download "$VERSION_VALUE" --repo "$REPOSITORY" \
      --dir "$VERIFICATION_DOWNLOAD_DIR" --pattern "$VERIFICATION_NAME" \
      || die '无法回下载刚上传的公开验证附件'
    validate_verification_file "${VERIFICATION_DOWNLOAD_DIR}/${VERIFICATION_NAME}" \
      || die '回下载的公开验证附件格式或身份不一致'
    cmp -s -- "$VERIFICATION_FILE" "${VERIFICATION_DOWNLOAD_DIR}/${VERIFICATION_NAME}" \
      || die '回下载的公开验证附件与本地原件不一致'
  fi
fi

printf '正式发布完成：%s（提交 %s，SHA-256 %s）\n' \
  "$VERSION_VALUE" "$SOURCE_COMMIT" "$FROZEN_SHA"
