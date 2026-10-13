#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
OUTPUT_REQUEST="${PROJECT_ROOT}/dist"

usage() {
  cat <<'EOF'
用法：scripts/package-release.sh [--output-dir DIR]

从当前干净 Git HEAD 的固定清单生成规范发布包、SHA256SUMS 与 get.sh 审计资产。
归档不读取可变工作树，不包含 .git、.work、真实配置、知识、日志或运行数据。
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --output-dir)
      (( $# >= 2 )) || { printf '错误：--output-dir 缺少参数\n' >&2; exit 1; }
      OUTPUT_REQUEST=$2
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      printf '错误：未知选项：%s\n' "$1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

for command_name in chmod git grep mkdir mktemp mv node python3 realpath rm sha256sum; do
  command -v "$command_name" >/dev/null 2>&1 \
    || { printf '错误：发布打包缺少维护工具：%s\n' "$command_name" >&2; exit 1; }
done

SOURCE_COMMIT=$(git -C "$PROJECT_ROOT" rev-parse --verify 'HEAD^{commit}') \
  || { printf '错误：无法确定发布提交\n' >&2; exit 1; }
if [[ -n "$(git -C "$PROJECT_ROOT" status --porcelain --untracked-files=all)" ]]; then
  printf '错误：正式发布包只能从没有已修改、已暂存或未跟踪文件的提交生成\n' >&2
  exit 1
fi
VERSION_VALUE=$(git -C "$PROJECT_ROOT" show "${SOURCE_COMMIT}:VERSION") \
  || { printf '错误：提交缺少 VERSION\n' >&2; exit 1; }
[[ "$VERSION_VALUE" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] \
  || { printf '错误：VERSION 格式无效\n' >&2; exit 1; }

OUTPUT_LEXICAL=$(realpath -ms -- "$OUTPUT_REQUEST")
OUTPUT_DIR=$(realpath -m -- "$OUTPUT_REQUEST")
[[ "$OUTPUT_LEXICAL" == "$OUTPUT_DIR" ]] \
  || { printf '错误：发布输出目录或其父路径不得使用符号链接\n' >&2; exit 1; }
[[ "$OUTPUT_DIR" != / && "$OUTPUT_DIR" != "$PROJECT_ROOT" ]] \
  || { printf '错误：发布输出目录过宽\n' >&2; exit 1; }
[[ ! -L "$OUTPUT_DIR" ]] || { printf '错误：发布输出目录不得是符号链接\n' >&2; exit 1; }

ARCHIVE_NAME="ai-support-${VERSION_VALUE}.tar.gz"
ARCHIVE_PATH="${OUTPUT_DIR}/${ARCHIVE_NAME}"
CHECKSUM_PATH="${OUTPUT_DIR}/SHA256SUMS"
WORK_DIR=$(mktemp -d "${PROJECT_ROOT}/.release-package.XXXXXX")
MANIFEST_SOURCE="${WORK_DIR}/release-manifest.txt"
LIST_FILE="${WORK_DIR}/files.list"
ARCHIVE_TEMP="${WORK_DIR}/${ARCHIVE_NAME}"
CHECKSUM_TEMP="${WORK_DIR}/SHA256SUMS"
GET_TEMP="${WORK_DIR}/get.sh"

cleanup() {
  if [[ "$WORK_DIR" == "${PROJECT_ROOT}"/.release-package.* && -d "$WORK_DIR" ]]; then
    rm -rf -- "$WORK_DIR"
  fi
}
trap cleanup EXIT INT TERM

git -C "$PROJECT_ROOT" show "${SOURCE_COMMIT}:scripts/release-manifest.txt" > "$MANIFEST_SOURCE" \
  || { printf '错误：发布提交缺少固定清单\n' >&2; exit 1; }
python3 - "$MANIFEST_SOURCE" "$VERSION_VALUE" "$LIST_FILE" <<'PY'
from pathlib import Path
import sys

source, version, output = sys.argv[1:]
paths = []
seen = set()
try:
    lines = Path(source).read_text(encoding="utf-8").splitlines()
except (OSError, UnicodeDecodeError):
    raise SystemExit("错误：发布固定清单不是有效 UTF-8 普通文本")
for source_line in lines:
    if not source_line or source_line.startswith("#"):
        continue
    path = source_line.replace("@VERSION@", version)
    if (path.startswith("/") or "\\" in path or path != path.strip()
            or any(ord(character) < 32 for character in path)
            or any(part in ("", ".", "..") for part in path.split("/"))
            or "@VERSION@" in path or path in seen):
        raise SystemExit("错误：发布固定清单包含重复或不安全路径")
    seen.add(path)
    paths.append(path)
if not paths:
    raise SystemExit("错误：发布固定清单为空")
Path(output).write_bytes(b"".join(path.encode("utf-8") + b"\0" for path in paths))
PY
mapfile -d '' -t RELEASE_FILES < "$LIST_FILE"
(( ${#RELEASE_FILES[@]} > 0 )) \
  || { printf '错误：发布固定清单为空\n' >&2; exit 1; }

# 这组最小自举成员同时供旧测试做静态核对；完整唯一来源仍是 tracked manifest。
REQUIRED_RELEASE_FILES=(
  VERSION get.sh install.sh manage.sh update.sh uninstall.sh docker-compose.yml
  config/app.yaml config/release-policy.json n8n/workflow.json n8n/runtime.js n8n/build-workflow.js n8n/knowledge-lexical.js
  scripts/common.sh scripts/bootstrap.sh scripts/wizard.sh scripts/package-release.sh
  scripts/release-gate.py scripts/release-manifest.txt scripts/publish-release.sh
  scripts/configuration.sh scripts/knowledge.sh scripts/provider.sh scripts/provider-adapter.js scripts/visitor-output.js
  scripts/provider-router.js scripts/provider-envelope.js scripts/provider-pool.py scripts/menu-display.py scripts/menu-provider-ui.sh
  scripts/knowledge-component.js scripts/knowledge-profile.py scripts/knowledge-profile.sh scripts/knowledge-lexical.py
  scripts/launcher.sh scripts/doctor.sh scripts/migration.sh scripts/full-backup.sh scripts/archive-guard.py
  scripts/materials.sh scripts/materials-recovery.py scripts/atomic-config.py scripts/logs.sh scripts/log-redact.py config/logging.yaml.example
  n8n/runtime-cli.js n8n/admin-query.js n8n/web-chat.js config/provider.yaml.example
  tests/run.sh tests/test_get.sh tests/test_doctor.sh tests/test_public_distribution.sh
  tests/test_legacy_rollback.sh tests/test_install_resume.sh tests/test_runtime_missing_reply_p0.js
  tests/test_provider_recovery_contract.js tests/test_runtime_process_fencing.js
  tests/test_runtime_provider_failure_reply.js tests/test_release_gate.py tests/test_release_identity.py
)
for required in "${REQUIRED_RELEASE_FILES[@]}"; do
  grep -zFxq -- "$required" "$LIST_FILE" \
    || { printf '错误：发布固定清单缺少必要文件：%s\n' "$required" >&2; exit 1; }
done

python3 "${PROJECT_ROOT}/scripts/release-gate.py" --verify-source --commit "$SOURCE_COMMIT" \
  >/dev/null || { printf '错误：发布源码版本、工作流或固定清单未通过身份核对\n' >&2; exit 1; }

# 只读取固定提交的 tree/blob；规范化 uid/gid、mtime 和 mode，避免工作树权限或并发编辑污染资产。
python3 - "$PROJECT_ROOT" "$SOURCE_COMMIT" "$VERSION_VALUE" "$LIST_FILE" "$ARCHIVE_TEMP" <<'PY'
from pathlib import Path
import gzip
import io
import subprocess
import sys
import tarfile

root, commit, version, list_name, output = sys.argv[1:]
paths = Path(list_name).read_bytes().split(b"\0")
if paths and paths[-1] == b"":
    paths.pop()
try:
    decoded = [path.decode("utf-8") for path in paths]
except UnicodeDecodeError:
    raise SystemExit("错误：发布清单路径编码无效")

records = subprocess.check_output(
    ["git", "-C", root, "ls-tree", "-r", "-z", "--full-tree", commit],
    stderr=subprocess.DEVNULL,
)
tree = {}
for record in records.split(b"\0"):
    if not record:
        continue
    metadata, raw_path = record.split(b"\t", 1)
    mode, kind, object_id = metadata.decode("ascii").split(" ")
    tree[raw_path.decode("utf-8")] = (mode, kind, object_id)

files = {}
for path in decoded:
    entry = tree.get(path)
    if entry is None or entry[1] != "blob" or entry[0] not in {"100644", "100755"}:
        raise SystemExit("错误：发布清单成员不是提交中的安全普通文件：" + path)
    files[path] = (entry[0], subprocess.check_output(
        ["git", "-C", root, "cat-file", "blob", entry[2]], stderr=subprocess.DEVNULL,
    ))

archive_root = "ai-support-" + version
directories = {archive_root}
for path in files:
    components = path.split("/")[:-1]
    for length in range(1, len(components) + 1):
        directories.add(archive_root + "/" + "/".join(components[:length]))

with open(output, "xb") as raw:
    with gzip.GzipFile(filename="", mode="wb", fileobj=raw, compresslevel=9, mtime=0) as compressed:
        with tarfile.open(fileobj=compressed, mode="w|", format=tarfile.GNU_FORMAT) as archive:
            for directory in sorted(directories, key=lambda item: (item.count("/"), item)):
                info = tarfile.TarInfo(directory)
                info.type = tarfile.DIRTYPE
                info.mode = 0o755
                info.uid = info.gid = 0
                info.uname = info.gname = "root"
                info.mtime = 0
                archive.addfile(info)
            for path in sorted(files):
                mode, contents = files[path]
                info = tarfile.TarInfo(archive_root + "/" + path)
                info.type = tarfile.REGTYPE
                info.mode = 0o755 if mode == "100755" else 0o644
                info.uid = info.gid = 0
                info.uname = info.gname = "root"
                info.mtime = 0
                info.size = len(contents)
                archive.addfile(info, io.BytesIO(contents))
PY
chmod 0644 "$ARCHIVE_TEMP"

python3 "${PROJECT_ROOT}/scripts/release-gate.py" \
  --verify-archive "$ARCHIVE_TEMP" --commit "$SOURCE_COMMIT" >/dev/null \
  || { printf '错误：生成的发布包与固定提交不一致\n' >&2; exit 1; }
(
  cd -- "$WORK_DIR"
  sha256sum "$ARCHIVE_NAME" > SHA256SUMS
)
chmod 0644 "$CHECKSUM_TEMP"
git -C "$PROJECT_ROOT" show "${SOURCE_COMMIT}:get.sh" > "$GET_TEMP"
chmod 0755 "$GET_TEMP"

[[ "$(git -C "$PROJECT_ROOT" rev-parse --verify 'HEAD^{commit}')" == "$SOURCE_COMMIT" \
  && -z "$(git -C "$PROJECT_ROOT" status --porcelain --untracked-files=all)" ]] \
  || { printf '错误：打包期间源码身份发生变化，拒绝提交资产\n' >&2; exit 1; }

mkdir -p -- "$OUTPUT_DIR"
OUTPUT_CREATED=$(realpath -e -- "$OUTPUT_DIR") \
  || { printf '错误：无法核对发布输出目录\n' >&2; exit 1; }
[[ "$OUTPUT_CREATED" == "$OUTPUT_LEXICAL" && -d "$OUTPUT_DIR" && ! -L "$OUTPUT_DIR" ]] \
  || { printf '错误：无法建立安全的发布输出目录\n' >&2; exit 1; }
mv -f -- "$ARCHIVE_TEMP" "$ARCHIVE_PATH"
mv -f -- "$CHECKSUM_TEMP" "$CHECKSUM_PATH"
mv -f -- "$GET_TEMP" "${OUTPUT_DIR}/get.sh"
trap - EXIT INT TERM
rm -rf -- "$WORK_DIR"

printf '来源提交：%s\n' "$SOURCE_COMMIT"
printf '发布包：%s\n' "$ARCHIVE_PATH"
printf '校验文件：%s\n' "$CHECKSUM_PATH"
printf '入口审计资产：%s/get.sh\n' "$OUTPUT_DIR"
