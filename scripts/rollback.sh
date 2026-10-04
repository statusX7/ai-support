#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"
# 预检必须使用当前可信程序，不能执行快照中附带的脚本来验证快照自身。
# shellcheck source=scripts/configuration.sh
source "${SCRIPT_DIR}/configuration.sh"
# v1.3.0 快照必须由当前可信程序验证资料原文、索引与投影代次；不得执行
# 快照内脚本来证明快照自身安全。
# shellcheck source=scripts/materials.sh
source "${SCRIPT_DIR}/materials.sh"

DEPLOY_REQUEST=""
SNAPSHOT_ID=""
LIST_ONLY=0
SKIP_START=0
SAFETY_SNAPSHOT=1
NO_SAFETY_SNAPSHOT_REQUESTED=0
FAILED_UPDATE_RECOVERY=0
SERVICES_STOPPED=0
MUTATION_STARTED=0
PAUSED_APP_SERVICES=()
UPDATE_RECOVERY_JOURNAL=""
UPDATE_RECOVERY_TOMBSTONE=""
UPDATE_RECOVERY_PRIMARY=""
RECOVERY_TOKEN=""
RECOVERY_PHASE=""
RECOVERY_COMPLETION_STATE=""
RECOVERY_OLD_VERSION=""
RECOVERY_NEW_VERSION=""
RECOVERY_SOURCE_DIR=""
RECOVERY_CANDIDATE_DIR=""
RECOVERY_SOURCE_MANIFEST_SHA256=""
RECOVERY_SOURCE_CANDIDATE_SHA256=""
RECOVERY_SNAPSHOT_MANIFEST_SHA256=""
RECOVERY_SNAPSHOT_ARCHIVE_SHA256=""
RECOVERY_PREVIOUS_STATE=""
RECOVERY_PREVIOUS_SOURCE=""
RECOVERY_PREVIOUS_MARKER_SHA256=""
RECOVERY_PREVIOUS_MARKER_BASE64=""
RECOVERY_OWNER_PID=""
RECOVERY_OWNER_BOOT_ID=""
RECOVERY_OWNER_START_TICKS=""

usage() {
  cat <<'EOF'
用法：rollback.sh --snapshot ID [选项]
      rollback.sh --list [--deploy-dir PATH]

选项：
  --deploy-dir PATH       指定部署目录
  --snapshot ID           指定版本快照
  --list                  查看本机版本历史
  --skip-start            只恢复文件，不操作 Docker
  --no-safety-snapshot    不创建回滚前安全快照
  --failed-update-recovery 仅按同次更新的严格 journal 恢复；内部故障恢复模式
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --deploy-dir)
      (( $# >= 2 )) || die "--deploy-dir 缺少参数"
      DEPLOY_REQUEST=$2
      shift 2
      ;;
    --snapshot)
      (( $# >= 2 )) || die "--snapshot 缺少参数"
      SNAPSHOT_ID=$2
      shift 2
      ;;
    --list)
      LIST_ONLY=1
      shift
      ;;
    --skip-start)
      SKIP_START=1
      shift
      ;;
    --no-safety-snapshot)
      SAFETY_SNAPSHOT=0
      NO_SAFETY_SNAPSHOT_REQUESTED=1
      shift
      ;;
    --failed-update-recovery)
      FAILED_UPDATE_RECOVERY=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *) die "未知选项：$1" ;;
  esac
done

if (( FAILED_UPDATE_RECOVERY )); then
  (( LIST_ONLY == 0 && SKIP_START == 0 && NO_SAFETY_SNAPSHOT_REQUESTED == 0 )) \
    || die 'failed-update-recovery 不能与 --list、--skip-start 或 --no-safety-snapshot 组合'
  RECOVERY_TOKEN=${CRISP_AI_FAILED_UPDATE_TOKEN:-}
  [[ "$RECOVERY_TOKEN" =~ ^[a-f0-9]{64}$ ]] \
    || die 'failed-update-recovery 缺少有效的同次更新 token'
  unset CRISP_AI_FAILED_UPDATE_TOKEN
  SAFETY_SNAPSHOT=0
fi

failed_update_source_candidate_identity() {
  python3 -B - "$1" "$2" "${3:-}" <<'PY'
import hashlib
import os
from pathlib import Path
import stat
import sys

root = Path(sys.argv[1])
version = sys.argv[2]
immutable = len(sys.argv) == 4 and sys.argv[3] == "immutable"
manifest = root / "scripts/release-manifest.txt"
if not root.is_absolute() or root.is_symlink() or not root.is_dir():
    raise SystemExit(1)
root_info = root.stat()
if immutable and (root_info.st_uid != os.geteuid() or root_info.st_mode & 0o222):
    raise SystemExit(1)
try:
    lines = manifest.read_text(encoding="utf-8").splitlines()
except (OSError, UnicodeError):
    raise SystemExit(1)
paths = []
seen = set()
for line in lines:
    if not line or line.startswith("#"):
        continue
    relative = line.replace("@VERSION@", version)
    parts = relative.split("/")
    if (relative.startswith("/") or "\\" in relative or relative != relative.strip()
            or any(ord(character) < 32 for character in relative)
            or any(part in ("", ".", "..") for part in parts)
            or "@VERSION@" in relative or relative in seen):
        raise SystemExit(1)
    seen.add(relative)
    paths.append(relative)
if not paths:
    raise SystemExit(1)
if immutable:
    expected_files = set(paths)
    expected_directories = set()
    for relative in paths:
        parts = relative.split("/")[:-1]
        for index in range(1, len(parts) + 1):
            expected_directories.add("/".join(parts[:index]))
    actual_files = set()
    actual_directories = set()
    for item in root.rglob("*"):
        info = item.lstat()
        relative = item.relative_to(root).as_posix()
        if stat.S_ISLNK(info.st_mode):
            raise SystemExit(1)
        if stat.S_ISDIR(info.st_mode):
            actual_directories.add(relative)
        elif stat.S_ISREG(info.st_mode):
            actual_files.add(relative)
        else:
            raise SystemExit(1)
    if actual_files != expected_files or actual_directories != expected_directories:
        raise SystemExit(1)
digest = hashlib.sha256()
for relative in paths:
    current = root
    for part in relative.split("/"):
        current = current / part
        try:
            info = current.lstat()
        except OSError:
            raise SystemExit(1)
        if stat.S_ISLNK(info.st_mode):
            raise SystemExit(1)
        if immutable and (info.st_uid != os.geteuid() or info.st_mode & 0o222):
            raise SystemExit(1)
        if immutable and stat.S_ISDIR(info.st_mode) and stat.S_IMODE(info.st_mode) != 0o500:
            raise SystemExit(1)
    if not stat.S_ISREG(info.st_mode):
        raise SystemExit(1)
    if immutable and info.st_nlink != 1:
        raise SystemExit(1)
    if immutable and stat.S_IMODE(info.st_mode) != (0o500 if info.st_mode & 0o111 else 0o400):
        raise SystemExit(1)
    file_digest = hashlib.sha256()
    try:
        with current.open("rb") as stream:
            while True:
                chunk = stream.read(1024 * 1024)
                if not chunk:
                    break
                file_digest.update(chunk)
    except OSError:
        raise SystemExit(1)
    executable = b"x" if info.st_mode & 0o111 else b"-"
    digest.update(relative.encode("utf-8") + b"\0" + executable + b":"
                  + file_digest.hexdigest().encode("ascii") + b"\n")
print(digest.hexdigest())
PY
}

failed_update_candidate_valid() {
  [[ "$RECOVERY_CANDIDATE_DIR" == "${DEPLOY_DIR}/backups/update-candidate-${RECOVERY_TOKEN}" \
    && -d "$RECOVERY_CANDIDATE_DIR" && ! -L "$RECOVERY_CANDIDATE_DIR" \
    && "$(stat -c '%a:%u' -- "$RECOVERY_CANDIDATE_DIR" 2>/dev/null || true)" == "500:${EUID}" ]] \
    || return 1
  [[ "$(sha256sum "${RECOVERY_CANDIDATE_DIR}/scripts/release-manifest.txt" | awk '{print $1}')" == "$RECOVERY_SOURCE_MANIFEST_SHA256" ]] \
    || return 1
  [[ "$(failed_update_source_candidate_identity "$RECOVERY_CANDIDATE_DIR" "$RECOVERY_NEW_VERSION" immutable)" \
    == "$RECOVERY_SOURCE_CANDIDATE_SHA256" ]]
}

failed_update_candidate_remove() {
  local partial="${DEPLOY_DIR}/backups/.update-candidate-${RECOVERY_TOKEN}.tmp"
  if [[ ( -e "$RECOVERY_CANDIDATE_DIR" || -L "$RECOVERY_CANDIDATE_DIR" ) \
    && ( -e "$partial" || -L "$partial" ) ]]; then
    return 1
  fi
  if [[ -e "$RECOVERY_CANDIDATE_DIR" || -L "$RECOVERY_CANDIDATE_DIR" ]]; then
    failed_update_candidate_valid || return 1
    failed_update_atomic_noreplace "$RECOVERY_CANDIDATE_DIR" "$partial" || return 1
    sync -f "${DEPLOY_DIR}/backups" || return 1
  fi
  if [[ ! -e "$partial" && ! -L "$partial" ]]; then
    sync -f "${DEPLOY_DIR}/backups" || return 1
    return 0
  fi
  python3 -B - "$partial" <<'PY' || return 1
import os
from pathlib import Path
import stat
import sys

root = Path(sys.argv[1])
euid = os.geteuid()
files = 0
directories = 0
total = 0

def valid_name(relative):
    return (not relative.startswith("/") and "\\" not in relative
            and not any(ord(character) < 32 for character in relative)
            and not any(part in ("", ".", "..") for part in relative.split("/"))
            and len(relative) <= 1024)

try:
    root_info = root.lstat()
    if (not stat.S_ISDIR(root_info.st_mode) or stat.S_ISLNK(root_info.st_mode)
            or root_info.st_uid != euid or stat.S_IMODE(root_info.st_mode) not in (0o500, 0o700)):
        raise ValueError("root")
    for current, names, names_files in os.walk(root, topdown=True, followlinks=False):
        names.sort(); names_files.sort()
        base = Path(current)
        for name in names:
            item = base / name
            info = item.lstat()
            relative = item.relative_to(root).as_posix()
            if (not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode)
                    or info.st_uid != euid or stat.S_IMODE(info.st_mode) not in (0o500, 0o700)
                    or not valid_name(relative)):
                raise ValueError("directory")
            directories += 1
        for name in names_files:
            item = base / name
            info = item.lstat()
            relative = item.relative_to(root).as_posix()
            if (not stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode)
                    or info.st_uid != euid or info.st_nlink != 1
                    or stat.S_IMODE(info.st_mode) not in (0o400, 0o500, 0o600)
                    or not valid_name(relative)):
                raise ValueError("file")
            files += 1
            total += info.st_size
    if files > 10000 or directories > 10000 or total > 2 * 1024 * 1024 * 1024:
        raise ValueError("bounds")

    def remove_tree(directory):
        info = directory.lstat()
        if (not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode)
                or info.st_uid != euid or stat.S_IMODE(info.st_mode) not in (0o500, 0o700)):
            raise ValueError("changed directory")
        os.chmod(directory, 0o700)
        for entry in sorted(os.scandir(directory), key=lambda value: value.name):
            item = Path(entry.path)
            child = item.lstat()
            if stat.S_ISDIR(child.st_mode) and not stat.S_ISLNK(child.st_mode):
                remove_tree(item)
            elif (stat.S_ISREG(child.st_mode) and not stat.S_ISLNK(child.st_mode)
                    and child.st_uid == euid and child.st_nlink == 1
                    and stat.S_IMODE(child.st_mode) in (0o400, 0o500, 0o600)):
                item.unlink()
            else:
                raise ValueError("changed member")
        directory.rmdir()

    remove_tree(root)
except (OSError, ValueError):
    raise SystemExit(1)
PY
  sync -f "${DEPLOY_DIR}/backups" || return 1
  [[ ! -e "$RECOVERY_CANDIDATE_DIR" && ! -L "$RECOVERY_CANDIDATE_DIR" \
    && ! -e "$partial" && ! -L "$partial" ]]
}

failed_update_preflight_cleanup() {
  local preflight="${DEPLOY_DIR}/tmp/update-preflight-${RECOVERY_TOKEN}"
  if [[ ! -e "$preflight" && ! -L "$preflight" ]]; then
    sync -f "${DEPLOY_DIR}/tmp" || return 1
    [[ ! -e "$preflight" && ! -L "$preflight" ]]
    return
  fi
  [[ -d "$preflight" && ! -L "$preflight" \
    && "$(stat -c '%a:%u' -- "$preflight" 2>/dev/null || true)" == "700:${EUID}" ]] \
    || return 1
  [[ -z "$(find "$preflight" -mindepth 1 \
    \( ! -type f -o -links +1 -o ! -user "$EUID" -o ! -perm 0600 -o -perm /0177 \) -print -quit 2>/dev/null)" ]] \
    || return 1
  find "$preflight" -depth -delete || return 1
  sync -f "${DEPLOY_DIR}/tmp" || return 1
  [[ ! -e "$preflight" && ! -L "$preflight" ]]
}

failed_update_atomic_noreplace() {
  python3 -B - "$1" "$2" <<'PY'
import ctypes
import errno
import os
import sys

source = os.fsencode(sys.argv[1])
target = os.fsencode(sys.argv[2])
libc = ctypes.CDLL(None, use_errno=True)
function = getattr(libc, "renameat2", None)
if function is None:
    raise SystemExit(1)
function.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
function.restype = ctypes.c_int
if function(-100, source, -100, target, 1) != 0:
    error = ctypes.get_errno()
    raise SystemExit(2 if error == errno.EEXIST else 1)
PY
}

failed_update_load_journal() {
  local canonical current_boot current_start decoded_marker_sha marker_state marker_source marker_version
  local -a values=()
  [[ -f "$UPDATE_RECOVERY_JOURNAL" && ! -L "$UPDATE_RECOVERY_JOURNAL" ]] || return 1
  [[ "$(stat -c '%a:%h:%u' -- "$UPDATE_RECOVERY_JOURNAL" 2>/dev/null || true)" == "600:1:${EUID}" ]] || return 1
  [[ "$(stat -c '%s' -- "$UPDATE_RECOVERY_JOURNAL" 2>/dev/null || true)" =~ ^[1-9][0-9]{0,5}$ ]] || return 1
  canonical=$(jq -cS . "$UPDATE_RECOVERY_JOURNAL" 2>/dev/null) || return 1
  [[ "$(<"$UPDATE_RECOVERY_JOURNAL")" == "$canonical" ]] || return 1
  jq -e '
    . as $journal |
    (keys | sort) == ["completion_state","created_at","kind","new_version","old_version",
      "owner_boot_id","owner_pid","owner_start_ticks","phase","previous_installation_state",
      "previous_marker_base64","previous_marker_sha256","previous_marker_source","schema_version","snapshot_archive_sha256",
      "snapshot_id","snapshot_manifest_sha256","source_candidate_dir","source_candidate_sha256","source_dir",
      "source_manifest_sha256","token"] and
    .schema_version == 1 and .kind == "failed-update-recovery" and
    (.token | type == "string" and test("^[a-f0-9]{64}$")) and
    (.snapshot_id | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")) and
    (.snapshot_manifest_sha256 | type == "string" and test("^[a-f0-9]{64}$")) and
    (.snapshot_archive_sha256 | type == "string" and test("^[a-f0-9]{64}$")) and
    (.old_version | type == "string" and test("^v[0-9]+\\.[0-9]+\\.[0-9]+$")) and
    (.new_version | type == "string" and test("^v[0-9]+\\.[0-9]+\\.[0-9]+$")) and
    (.source_dir | type == "string" and startswith("/") and (explode | all(. >= 32))) and
    (.source_candidate_dir | type == "string" and startswith("/") and (explode | all(. >= 32))) and
    (.source_manifest_sha256 | type == "string" and test("^[a-f0-9]{64}$")) and
    (.source_candidate_sha256 | type == "string" and test("^[a-f0-9]{64}$")) and
    (.previous_installation_state == "ready" or .previous_installation_state == "local-ready") and
    (.previous_marker_source | type == "string" and
      (. == "" or (startswith("/") and (explode | all(. >= 32))))) and
    (.previous_marker_base64 | type == "string" and length > 0 and length <= 65536 and
      test("^[A-Za-z0-9+/]*={0,2}$")) and
    (.previous_marker_sha256 | type == "string" and test("^[a-f0-9]{64}$")) and
    (.owner_pid | type == "number" and floor == . and . > 0 and . <= 2147483647) and
    (.owner_boot_id | type == "string" and test("^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$")) and
    (.owner_start_ticks | type == "string" and test("^[0-9]+$")) and
    (["prepared","recovery_armed","mutation_started","services_stopped","recovering","restored","update_committed"] | index($journal.phase)) != null and
    (if .phase == "restored" or .phase == "update_committed" then
       (.completion_state == "ready" or .completion_state == "local-ready")
     else .completion_state == "" end) and
    (.created_at | type == "number" and floor == . and . > 0 and . <= 9007199254740991)
  ' "$UPDATE_RECOVERY_JOURNAL" >/dev/null 2>&1 || return 1
  mapfile -t values < <(jq -r '[.token,.snapshot_id,.snapshot_manifest_sha256,
    .snapshot_archive_sha256,.old_version,.new_version,.source_dir,.source_candidate_dir,.source_manifest_sha256,
    .source_candidate_sha256,.previous_installation_state,.previous_marker_source,
    .previous_marker_sha256,.previous_marker_base64,(.owner_pid|tostring),.owner_boot_id,.owner_start_ticks,
    .phase,.completion_state][]' "$UPDATE_RECOVERY_JOURNAL")
  (( ${#values[@]} == 19 )) || return 1
  [[ "${values[0]}" == "$RECOVERY_TOKEN" && "${values[1]}" == "$SNAPSHOT_ID" ]] || return 1
  RECOVERY_SNAPSHOT_MANIFEST_SHA256=${values[2]}
  RECOVERY_SNAPSHOT_ARCHIVE_SHA256=${values[3]}
  RECOVERY_OLD_VERSION=${values[4]}
  RECOVERY_NEW_VERSION=${values[5]}
  RECOVERY_SOURCE_DIR=${values[6]}
  RECOVERY_CANDIDATE_DIR=${values[7]}
  RECOVERY_SOURCE_MANIFEST_SHA256=${values[8]}
  RECOVERY_SOURCE_CANDIDATE_SHA256=${values[9]}
  RECOVERY_PREVIOUS_STATE=${values[10]}
  RECOVERY_PREVIOUS_SOURCE=${values[11]}
  RECOVERY_PREVIOUS_MARKER_SHA256=${values[12]}
  RECOVERY_PREVIOUS_MARKER_BASE64=${values[13]}
  RECOVERY_OWNER_PID=${values[14]}
  RECOVERY_OWNER_BOOT_ID=${values[15]}
  RECOVERY_OWNER_START_TICKS=${values[16]}
  RECOVERY_PHASE=${values[17]}
  RECOVERY_COMPLETION_STATE=${values[18]}
  decoded_marker_sha=$(printf '%s' "$RECOVERY_PREVIOUS_MARKER_BASE64" | base64 -d 2>/dev/null \
    | sha256sum | awk '{print $1}') || return 1
  [[ "$decoded_marker_sha" == "$RECOVERY_PREVIOUS_MARKER_SHA256" ]] || return 1
  [[ "$RECOVERY_CANDIDATE_DIR" == "${DEPLOY_DIR}/backups/update-candidate-${RECOVERY_TOKEN}" ]] || return 1
  if [[ -e "$RECOVERY_CANDIDATE_DIR" || -L "$RECOVERY_CANDIDATE_DIR" ]]; then
    failed_update_candidate_valid || return 1
  else
    case "$RECOVERY_PHASE" in
      prepared|recovery_armed|restored|update_committed) ;;
      *) return 1 ;;
    esac
  fi
  current_boot=$(< /proc/sys/kernel/random/boot_id)
  if [[ "$current_boot" == "$RECOVERY_OWNER_BOOT_ID" && -e "/proc/${RECOVERY_OWNER_PID}" ]]; then
    current_start=$(python3 -B - "$RECOVERY_OWNER_PID" <<'PY'
from pathlib import Path
import sys
raw = (Path('/proc') / sys.argv[1] / 'stat').read_text()
print(raw.rsplit(')', 1)[1].split()[19])
PY
) || return 1
    if [[ "$current_start" == "$RECOVERY_OWNER_START_TICKS" ]]; then
      [[ "$PPID" == "$RECOVERY_OWNER_PID" ]] || return 1
    fi
  fi
  [[ "$(stat -c '%a:%h:%u' -- "${DEPLOY_DIR}/${INSTALL_MARKER}" 2>/dev/null || true)" == "600:1:${EUID}" ]] \
    || return 1
  marker_state=$(installation_state "$DEPLOY_DIR")
  marker_source=$(sed -n 's/^source=//p' "${DEPLOY_DIR}/${INSTALL_MARKER}" | head -n 1)
  marker_version=$(sed -n 's/^installed_version=//p' "${DEPLOY_DIR}/${INSTALL_MARKER}" | head -n 1)
  case "$RECOVERY_PHASE" in
    prepared)
      [[ "$(sha256sum "${DEPLOY_DIR}/${INSTALL_MARKER}" | awk '{print $1}')" == "$RECOVERY_PREVIOUS_MARKER_SHA256" ]] \
        || return 1
      ;;
    recovery_armed)
      if [[ "$(sha256sum "${DEPLOY_DIR}/${INSTALL_MARKER}" | awk '{print $1}')" != "$RECOVERY_PREVIOUS_MARKER_SHA256" ]]; then
        [[ "$marker_version" == "$RECOVERY_OLD_VERSION" \
          && "$marker_state" == installing && "$marker_source" == "$RECOVERY_CANDIDATE_DIR" ]] || return 1
      fi
      ;;
    mutation_started|services_stopped)
      [[ "$marker_version" == "$RECOVERY_OLD_VERSION" \
        && "$marker_state" == installing && "$marker_source" == "$RECOVERY_CANDIDATE_DIR" ]] || return 1
      ;;
    recovering)
      [[ "$marker_version" == "$RECOVERY_OLD_VERSION" && "$marker_state" == installing \
        && ( "$marker_source" == "$RECOVERY_CANDIDATE_DIR" || "$marker_source" == "$RECOVERY_PREVIOUS_SOURCE" ) ]] \
        || return 1
      ;;
    restored)
      [[ "$marker_version" == "$RECOVERY_OLD_VERSION" ]] || return 1
      if [[ "$marker_state" == installing ]]; then
        [[ "$marker_source" == "$RECOVERY_CANDIDATE_DIR" || "$marker_source" == "$RECOVERY_PREVIOUS_SOURCE" ]] \
          || return 1
      else
        [[ "$marker_state" == "$RECOVERY_COMPLETION_STATE" \
          && "$marker_source" == "$RECOVERY_PREVIOUS_SOURCE" ]] || return 1
      fi
      ;;
    update_committed)
      if [[ "$marker_state" == installing ]]; then
        [[ "$marker_version" == "$RECOVERY_OLD_VERSION" \
          && "$marker_source" == "$RECOVERY_CANDIDATE_DIR" ]] \
          || return 1
      else
        [[ "$marker_version" == "$RECOVERY_NEW_VERSION" \
          && "$marker_state" == "$RECOVERY_COMPLETION_STATE" \
          && "$marker_source" == "$RECOVERY_SOURCE_DIR" ]] || return 1
      fi
      ;;
  esac
}

failed_update_set_phase() {
  local phase=$1 completion=${2:-} temporary directory=${UPDATE_RECOVERY_JOURNAL%/*}
  failed_update_load_journal || return 1
  temporary=$(mktemp "${UPDATE_RECOVERY_PRIMARY}.tmp.${RECOVERY_TOKEN}.XXXXXX") || return 1
  if ! jq -cS --arg phase "$phase" --arg completion "$completion" \
      '.phase=$phase | .completion_state=$completion' "$UPDATE_RECOVERY_JOURNAL" > "$temporary" \
    || ! chmod 0600 "$temporary" || ! sync -f "$temporary" \
    || ! mv -f -- "$temporary" "$UPDATE_RECOVERY_JOURNAL" \
    || ! sync -f "$UPDATE_RECOVERY_JOURNAL" || ! sync -f "$directory"; then
    rm -f -- "$temporary"
    return 1
  fi
  RECOVERY_PHASE=$phase
  RECOVERY_COMPLETION_STATE=$completion
}

failed_update_remove_journal() {
  local directory=${UPDATE_RECOVERY_JOURNAL%/*} canonical
  local helper="${UPDATE_RECOVERY_TOMBSTONE}.helper" temporary
  failed_update_load_journal || return 1
  case "$RECOVERY_PHASE" in prepared|recovery_armed|restored|update_committed) ;; *) return 1 ;; esac
  failed_update_preflight_cleanup || return 1
  if [[ "$UPDATE_RECOVERY_JOURNAL" != "$UPDATE_RECOVERY_TOMBSTONE" ]]; then
    [[ ! -e "$UPDATE_RECOVERY_TOMBSTONE" && ! -L "$UPDATE_RECOVERY_TOMBSTONE" ]] || return 1
    failed_update_atomic_noreplace "$UPDATE_RECOVERY_JOURNAL" "$UPDATE_RECOVERY_TOMBSTONE" || return 1
    UPDATE_RECOVERY_JOURNAL=$UPDATE_RECOVERY_TOMBSTONE
    sync -f "$directory" || return 1
  fi
  canonical=$(<"$UPDATE_RECOVERY_JOURNAL") || return 1
  if [[ -e "$helper" || -L "$helper" ]]; then
    [[ -f "$helper" && ! -L "$helper" \
      && "$(stat -c '%a:%h:%u' -- "$helper" 2>/dev/null || true)" == "600:1:${EUID}" \
      && "$(stat -c '%s' -- "$helper" 2>/dev/null || true)" =~ ^[1-9][0-9]{0,5}$ \
      && "$(<"$helper")" == "$canonical" ]] || return 1
  else
    temporary=$(mktemp "${helper}.tmp.XXXXXX") || return 1
    if ! printf '%s' "$canonical" > "$temporary" || ! chmod 0600 "$temporary" \
      || ! sync -f "$temporary" || ! failed_update_atomic_noreplace "$temporary" "$helper" \
      || ! sync -f "$directory"; then
      return 1
    fi
    [[ ! -e "$temporary" && ! -L "$temporary" \
      && -f "$helper" && ! -L "$helper" \
      && "$(stat -c '%a:%h:%u' -- "$helper" 2>/dev/null || true)" == "600:1:${EUID}" \
      && "$(<"$helper")" == "$canonical" ]] || return 1
  fi
  rm -f -- "$UPDATE_RECOVERY_JOURNAL" || return 1
  sync -f "$directory" || return 1
  [[ ! -e "$UPDATE_RECOVERY_TOMBSTONE" && ! -L "$UPDATE_RECOVERY_TOMBSTONE" ]] || return 1
  rm -f -- "$helper" || return 1
  sync -f "$directory" || return 1
  [[ ! -e "$helper" && ! -L "$helper" ]] || return 1
}

DEPLOY_DIR=$(resolve_deploy_dir "$DEPLOY_REQUEST")
assert_managed_installation "$DEPLOY_DIR"
acquire_maintenance_lock "$DEPLOY_DIR"
VERSIONS_DIR="${DEPLOY_DIR}/backups/versions"
[[ -d "$VERSIONS_DIR" && ! -L "$VERSIONS_DIR" ]] || die "版本历史目录缺失或是符号链接"
UPDATE_RECOVERY_PRIMARY="${DEPLOY_DIR}/backups/update-recovery.json"
UPDATE_RECOVERY_JOURNAL=$UPDATE_RECOVERY_PRIMARY

list_snapshots() {
  local found=0 manifest
  printf '%-43s %-10s %-20s %s\n' '快照 ID' '版本' '创建时间' '原因'
  if [[ -d "$VERSIONS_DIR" ]]; then
    while IFS= read -r -d '' manifest; do
      if jq -e '.format == "ai-support-snapshot-v1" or .format == "ai-support-snapshot-v2" or .format == "ai-support-snapshot-v3"' "$manifest" >/dev/null 2>&1; then
        jq -r '[.id,.version,.created_at,.reason] | @tsv' "$manifest" | \
          while IFS=$'\t' read -r id version created reason; do
            printf '%-43s %-10s %-20s %s\n' "$id" "$version" "$created" "$reason"
          done
        found=1
      fi
    done < <(find "$VERSIONS_DIR" -mindepth 2 -maxdepth 2 -type f -name manifest.json -print0 | sort -rz)
  fi
  (( found == 1 )) || printf '%s\n' '（暂无版本快照）'
}

require_command jq
if (( LIST_ONLY )); then
  list_snapshots
  exit 0
fi

[[ "$SNAPSHOT_ID" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || die "版本快照 ID 无效"
[[ $EUID -eq 0 ]] || die "回滚版本需要 root 权限"
require_command tar
require_command sha256sum
if (( FAILED_UPDATE_RECOVERY )); then
  require_command python3
  require_command base64
  require_command stat
  require_command sync
  UPDATE_RECOVERY_TOMBSTONE="${DEPLOY_DIR}/backups/update-recovery.finalizing-${RECOVERY_TOKEN}.json"
  UPDATE_RECOVERY_HELPER="${UPDATE_RECOVERY_TOMBSTONE}.helper"
  shopt -s nullglob
  UPDATE_RECOVERY_HELPER_TEMPS=("${UPDATE_RECOVERY_HELPER}.tmp."*)
  shopt -u nullglob
  (( ${#UPDATE_RECOVERY_HELPER_TEMPS[@]} <= 1 )) \
    || die '同 token 存在多个 journal helper 写入临时文件；拒绝猜测'
  if [[ ( -e "$UPDATE_RECOVERY_PRIMARY" || -L "$UPDATE_RECOVERY_PRIMARY" ) \
    && ( -e "$UPDATE_RECOVERY_TOMBSTONE" || -L "$UPDATE_RECOVERY_TOMBSTONE" ) ]]; then
    die '正式恢复 journal 与同 token tombstone 同时存在；拒绝猜测提交状态'
  fi
  if [[ -e "$UPDATE_RECOVERY_PRIMARY" || -L "$UPDATE_RECOVERY_PRIMARY" ]]; then
    UPDATE_RECOVERY_JOURNAL=$UPDATE_RECOVERY_PRIMARY
  elif [[ -e "$UPDATE_RECOVERY_TOMBSTONE" || -L "$UPDATE_RECOVERY_TOMBSTONE" ]]; then
    UPDATE_RECOVERY_JOURNAL=$UPDATE_RECOVERY_TOMBSTONE
  elif [[ -e "$UPDATE_RECOVERY_HELPER" || -L "$UPDATE_RECOVERY_HELPER" ]]; then
    UPDATE_RECOVERY_JOURNAL=$UPDATE_RECOVERY_HELPER
  else
    die 'failed-update-recovery 缺少正式 journal、同 token tombstone 或完整 helper'
  fi
  failed_update_load_journal \
    || die 'failed-update-recovery journal、token、候选身份或安装标记不匹配；未停止服务或覆盖部署'
  if [[ -e "$UPDATE_RECOVERY_HELPER" || -L "$UPDATE_RECOVERY_HELPER" ]]; then
    [[ -f "$UPDATE_RECOVERY_HELPER" && ! -L "$UPDATE_RECOVERY_HELPER" \
      && "$(stat -c '%a:%h:%u' -- "$UPDATE_RECOVERY_HELPER" 2>/dev/null || true)" == "600:1:${EUID}" \
      && "$(stat -c '%s' -- "$UPDATE_RECOVERY_HELPER" 2>/dev/null || true)" =~ ^[1-9][0-9]{0,5}$ ]] \
      || die 'journal tombstone helper 身份不安全'
    [[ "$UPDATE_RECOVERY_JOURNAL" == "$UPDATE_RECOVERY_HELPER" \
      || "$(<"$UPDATE_RECOVERY_HELPER")" == "$(<"$UPDATE_RECOVERY_JOURNAL")" ]] \
      || die 'journal tombstone helper 与权威 journal 字节不一致；拒绝猜测'
  fi
  for UPDATE_RECOVERY_HELPER_TEMP in "${UPDATE_RECOVERY_HELPER_TEMPS[@]}"; do
    UPDATE_RECOVERY_HELPER_SUFFIX=${UPDATE_RECOVERY_HELPER_TEMP#"${UPDATE_RECOVERY_HELPER}.tmp."}
    [[ "$UPDATE_RECOVERY_HELPER_SUFFIX" =~ ^[A-Za-z0-9]{6}$ \
      && -f "$UPDATE_RECOVERY_HELPER_TEMP" && ! -L "$UPDATE_RECOVERY_HELPER_TEMP" \
      && "$(stat -c '%a:%h:%u' -- "$UPDATE_RECOVERY_HELPER_TEMP" 2>/dev/null || true)" == "600:1:${EUID}" \
      && "$(stat -c '%s' -- "$UPDATE_RECOVERY_HELPER_TEMP" 2>/dev/null || true)" =~ ^[0-9]{1,6}$ ]] \
      || die 'journal helper 写入临时文件身份不安全'
    rm -f -- "$UPDATE_RECOVERY_HELPER_TEMP" \
      || die 'journal helper 写入临时文件未能安全清理'
  done
  if (( ${#UPDATE_RECOVERY_HELPER_TEMPS[@]} )); then
    sync -f "${DEPLOY_DIR}/backups" \
      || die 'journal helper 临时文件清理未持久化'
    for UPDATE_RECOVERY_HELPER_TEMP in "${UPDATE_RECOVERY_HELPER_TEMPS[@]}"; do
      [[ ! -e "$UPDATE_RECOVERY_HELPER_TEMP" && ! -L "$UPDATE_RECOVERY_HELPER_TEMP" ]] \
        || die 'journal helper 临时文件清理后复现'
    done
  fi
  if [[ "$RECOVERY_PHASE" == prepared || "$RECOVERY_PHASE" == recovery_armed ]]; then
    if [[ "$(sha256sum "${DEPLOY_DIR}/${INSTALL_MARKER}" | awk '{print $1}')" != "$RECOVERY_PREVIOUS_MARKER_SHA256" ]]; then
      marker_temporary=$(mktemp "${DEPLOY_DIR}/${INSTALL_MARKER}.tmp.XXXXXX") \
        || die 'pre-mutation 安装标记恢复临时文件创建失败；journal 保持'
      if ! printf '%s' "$RECOVERY_PREVIOUS_MARKER_BASE64" | base64 -d > "$marker_temporary" \
        || ! chmod 0600 "$marker_temporary" || ! sync -f "$marker_temporary" \
        || ! mv -f -- "$marker_temporary" "${DEPLOY_DIR}/${INSTALL_MARKER}" \
        || ! sync -f "${DEPLOY_DIR}/${INSTALL_MARKER}" || ! sync -f "$DEPLOY_DIR"; then
        rm -f -- "$marker_temporary"
        die 'pre-mutation 安装标记未能按冻结原字节恢复；journal 保持'
      fi
    fi
    [[ "$(sha256sum "${DEPLOY_DIR}/${INSTALL_MARKER}" | awk '{print $1}')" == "$RECOVERY_PREVIOUS_MARKER_SHA256" ]] \
      || die 'pre-mutation 安装标记与冻结原字节不一致；journal 保持'
    failed_update_remove_journal \
      || die 'pre-mutation 恢复已核验但临时对象或 journal 未能安全清理'
    failed_update_candidate_remove \
      || warn 'pre-mutation 责任已收口，但无秘密冻结候选尚未清理；下一次受管更新入口将严格收敛'
    info '升级在业务代际修改前中断；已收口同次恢复责任，未执行版本回滚'
    exit 0
  fi
  if [[ "$RECOVERY_PHASE" == update_committed ]]; then
    [[ -f "${DEPLOY_DIR}/VERSION" && ! -L "${DEPLOY_DIR}/VERSION" \
      && "$(<"${DEPLOY_DIR}/VERSION")" == "$RECOVERY_NEW_VERSION" ]] \
      || die 'update_committed journal 与当前 VERSION 不一致；不得倒回旧版本'
    if [[ "$(installation_state "$DEPLOY_DIR")" == installing ]]; then
      write_installation_marker "$DEPLOY_DIR" "$RECOVERY_SOURCE_DIR" \
        "$RECOVERY_NEW_VERSION" "$RECOVERY_COMPLETION_STATE"
    fi
    if ! sync -f "${DEPLOY_DIR}/${INSTALL_MARKER}" || ! sync -f "$DEPLOY_DIR"; then
      die 'update_committed 安装标记未能持久化；journal 保持'
    fi
    [[ -x "${DEPLOY_DIR}/scripts/healthcheck.sh" ]] \
      || die 'update_committed 缺少当前健康检查入口；journal 保持'
    "${DEPLOY_DIR}/scripts/healthcheck.sh" --deploy-dir "$DEPLOY_DIR" --application \
      || die 'update_committed 当前应用健康检查失败；journal 保持且不得倒回旧版本'
    failed_update_remove_journal \
      || die 'update_committed 已核验但 journal 仍无法安全清理'
    record_maintenance_event "$DEPLOY_DIR" update complete
    failed_update_candidate_remove \
      || warn '更新提交已收口，但无秘密冻结候选尚未清理；下一次受管更新入口将严格收敛'
    info "更新提交已收口：${RECOVERY_OLD_VERSION} -> ${RECOVERY_NEW_VERSION}"
    exit 0
  fi
else
  shopt -s nullglob
  UPDATE_RECOVERY_TOMBSTONES=("${DEPLOY_DIR}"/backups/update-recovery.finalizing-*.json \
    "${DEPLOY_DIR}"/backups/update-recovery.finalizing-*.json.helper \
    "${DEPLOY_DIR}"/backups/update-recovery.finalizing-*.json.helper.tmp.*)
  shopt -u nullglob
  if [[ -e "$UPDATE_RECOVERY_PRIMARY" || -L "$UPDATE_RECOVERY_PRIMARY" \
    || ${#UPDATE_RECOVERY_TOMBSTONES[@]} -ne 0 ]]; then
    die '存在未完成的升级失败恢复责任；普通版本回滚不能接管或清除该 journal/tombstone'
  fi
fi

SNAPSHOT_DIR="${VERSIONS_DIR}/${SNAPSHOT_ID}"
MANIFEST="${SNAPSHOT_DIR}/manifest.json"
ARCHIVE="${SNAPSHOT_DIR}/snapshot.tar.gz"
[[ -d "$SNAPSHOT_DIR" && ! -L "$SNAPSHOT_DIR" ]] || die "版本快照不存在：$SNAPSHOT_ID"
[[ -f "$MANIFEST" && ! -L "$MANIFEST" && -f "$ARCHIVE" && ! -L "$ARCHIVE" ]] || die "版本快照不完整"
jq -e --arg id "$SNAPSHOT_ID" '((.format == "ai-support-snapshot-v2" and .contains_env == false) or (.format == "ai-support-snapshot-v3" and .contains_env == true)) and .id == $id and .contains_database_dump == true' "$MANIFEST" >/dev/null \
  || die "版本快照清单无效"
SNAPSHOT_FORMAT=$(jq -r '.format' "$MANIFEST")
(( SKIP_START == 0 )) || die "包含数据库的版本回滚必须操作 Docker，不能使用 --skip-start"
EXPECTED_SHA=$(jq -er '.archive_sha256' "$MANIFEST")
ACTUAL_SHA=$(sha256sum "$ARCHIVE" | awk '{print $1}')
[[ "$EXPECTED_SHA" == "$ACTUAL_SHA" ]] || die "版本快照完整性校验失败"
if (( FAILED_UPDATE_RECOVERY )); then
  [[ "$(sha256sum "$MANIFEST" | awk '{print $1}')" == "$RECOVERY_SNAPSHOT_MANIFEST_SHA256" \
    && "$ACTUAL_SHA" == "$RECOVERY_SNAPSHOT_ARCHIVE_SHA256" ]] \
    || die 'failed-update-recovery 快照清单或归档摘要与 journal 不一致；未修改部署'
  jq -e --arg id "$SNAPSHOT_ID" --arg old "$RECOVERY_OLD_VERSION" \
    '.format == "ai-support-snapshot-v3" and .contains_env == true and
     .contains_database_dump == true and .id == $id and .version == $old' \
    "$MANIFEST" >/dev/null \
    || die 'failed-update-recovery 快照版本或完整格式与 journal 不一致；未修改部署'
fi
for image_key in N8N_IMAGE POSTGRES_IMAGE ANYTHINGLLM_IMAGE; do
  image_value=$(jq -er --arg key "$image_key" '.image_variables[$key] | select(type == "string")' "$MANIFEST")
  [[ "$image_value" =~ ^[A-Za-z0-9][A-Za-z0-9._/@:-]{0,255}$ ]] || die "快照镜像变量无效：$image_key"
done
image_value=$(jq -r '.image_variables.CADDY_IMAGE // "caddy:2.10.2-alpine"' "$MANIFEST")
[[ "$image_value" =~ ^[A-Za-z0-9][A-Za-z0-9._/@:-]{0,255}$ ]] \
  || die "快照镜像变量无效：CADDY_IMAGE"

if (( FAILED_UPDATE_RECOVERY )) && [[ "$RECOVERY_PHASE" == restored ]]; then
  [[ -f "${DEPLOY_DIR}/VERSION" && ! -L "${DEPLOY_DIR}/VERSION" \
    && "$(<"${DEPLOY_DIR}/VERSION")" == "$RECOVERY_OLD_VERSION" ]] \
    || die 'failed-update-recovery 已恢复记录与当前 VERSION 不一致；journal 保持'
  require_docker_runtime
  docker_compose "$DEPLOY_DIR" up -d --remove-orphans
  refresh_program_file_mounts "$DEPLOY_DIR" \
    || die 'failed-update-recovery restored 阶段无法刷新程序挂载；journal 保持'
  wait_for_local_health "$DEPLOY_DIR"
  set_installation_fact "$DEPLOY_DIR" dependencies ready
  set_installation_fact "$DEPLOY_DIR" local_services ready
  set_installation_fact "$DEPLOY_DIR" app_config ready
  set_installation_fact "$DEPLOY_DIR" provider ready
  if [[ "$(installation_state "$DEPLOY_DIR")" == installing ]]; then
    write_installation_marker "$DEPLOY_DIR" "$RECOVERY_PREVIOUS_SOURCE" \
      "$RECOVERY_OLD_VERSION" "$RECOVERY_COMPLETION_STATE"
  fi
  if ! sync -f "${DEPLOY_DIR}/${INSTALL_MARKER}" || ! sync -f "$DEPLOY_DIR"; then
    die 'failed-update-recovery 恢复标记未能持久化；journal 保持'
  fi
  failed_update_remove_journal \
    || die 'failed-update-recovery 已恢复状态无法安全清理 journal'
  record_maintenance_event "$DEPLOY_DIR" rollback complete
  failed_update_candidate_remove \
    || warn '升级失败恢复已收口，但无秘密冻结候选尚未清理；下一次受管更新入口将严格收敛'
  info "升级失败恢复已完成：${SNAPSHOT_ID} -> ${RECOVERY_OLD_VERSION}"
  exit 0
fi

is_allowed_snapshot_path() {
  local path=${1#./}
  path=${path%/}
  [[ -z "$path" ]] && return 0
  case "$path" in
    payload|payload/config|payload/knowledge|payload/n8n|payload/scripts|payload/docs|payload/data|payload/data/anythingllm|payload/data/postgres|payload/data/postgres/n8n.dump|payload/data/knowledge-manifest.json|payload/data/knowledge-projection.json)
      return 0
      ;;
    payload/VERSION|payload/CHANGELOG.md|payload/README.md|payload/LICENSE|payload/AGENTS.md|payload/.env.example|payload/docker-compose.yml|payload/get.sh|payload/install.sh|payload/manage.sh|payload/update.sh|payload/uninstall.sh|payload/n8n/workflow.json)
      return 0
      ;;
    payload/config/app.yaml|payload/config/provider.yaml|payload/config/provider.yaml.example|payload/config/prompt.md|payload/config/prompt.md.example|payload/config/keyword.yaml|payload/config/keyword.yaml.example|payload/config/menu.yaml|payload/config/menu.yaml.example|payload/config/handoff.yaml|payload/config/handoff.yaml.example|payload/config/tags.yaml|payload/config/tags.yaml.example|payload/config/feedback.yaml|payload/config/feedback.yaml.example|payload/config/Caddyfile|payload/config/Caddyfile.example)
      return 0
      ;;
    payload/scripts/common.sh|payload/scripts/healthcheck.sh|payload/scripts/backup.sh|payload/scripts/restore.sh|payload/scripts/analytics.sh|payload/scripts/snapshot.sh|payload/scripts/rollback.sh|payload/scripts/bootstrap.sh|payload/scripts/wizard.sh|payload/scripts/package-release.sh|payload/scripts/doctor.sh)
      return 0
      ;;
    payload/docs/INSTALL.md|payload/docs/ARCHITECTURE.md|payload/docs/CONFIG.md|payload/docs/SECURITY.md|payload/docs/TESTING.md|payload/docs/RELEASE.md)
      return 0
      ;;
    payload/knowledge/*)
      local name=${path#payload/knowledge/}
      [[ "$name" != */* && "$name" != *\\* && "$name" != *$'\n'* && "$name" != *$'\r'* ]] || return 1
      [[ "$name" == "README.md" ]] || is_supported_knowledge_file "$name"
      ;;
    payload/data/anythingllm/*)
      return 0
      ;;
    *) return 1 ;;
  esac
}

knowledge_snapshot_modules_check() {
  local root=$1 module count=0 file
  local -a modules=(scripts/knowledge-component.js scripts/knowledge-profile.py
    scripts/knowledge-profile.sh scripts/knowledge-lexical.py n8n/admin-query.js n8n/knowledge-lexical.js)
  [[ -f "${root}/n8n/runtime.js" && ! -L "${root}/n8n/runtime.js" ]] \
    || die '知识快照缺少安全的 n8n/runtime.js'
  for module in "${modules[@]}"; do
    if [[ -e "${root}/${module}" || -L "${root}/${module}" ]]; then
      [[ -f "${root}/${module}" && ! -L "${root}/${module}" ]] \
        || die "知识快照模块不安全：$module"
      ((count += 1))
    fi
  done
  (( count == 0 || count == ${#modules[@]} )) || die '知识快照模块不完整；不能保存或恢复混合代'
  KNOWLEDGE_SNAPSHOT_HAS_P0=$(( count == ${#modules[@]} ))
  if (( KNOWLEDGE_SNAPSHOT_HAS_P0 )); then
    return 0
  fi
  # 未发布的早期同版本候选可以全无新模块；已声明新能力则不能冒充旧候选。
  file="${root}/n8n/workflow.json"
  if [[ ! -f "$file" || -L "$file" ]] \
    || ! jq -e '(.meta.lexicalFileSha256 // "") == ""' "$file" >/dev/null 2>&1; then
    die '知识快照声明了缺失的词法运行模块'
  fi
  for module in data/runtime/knowledge-profile.json data/runtime/knowledge-lexical.json; do
    [[ ! -e "${root}/${module}" && ! -L "${root}/${module}" ]] \
      || die '知识快照保留新索引代次但缺少对应程序'
  done
  file="${root}/config/materials-applied.json"
  if [[ -e "$file" || -L "$file" ]]; then
    if [[ ! -f "$file" || -L "$file" ]] \
      || ! jq -e '[(.knowledge.profile_sha256 // ""),(.knowledge.lexical_sha256 // "")] | all(. == "")' \
        "$file" >/dev/null 2>&1; then
      die '知识快照投影引用了缺失的模型或词法程序'
    fi
  fi
  return 0
}

require_command python3
python3 "${SCRIPT_DIR}/archive-guard.py" "$ARCHIVE" --kind snapshot || die "版本快照安全校验失败"
while IFS= read -r entry; do
  clean=${entry#./}
  [[ "$clean" != /* && "$clean" != ".." && "$clean" != ../* && "$clean" != */../* && "$clean" != *\\* ]] \
    || die "版本快照包含路径穿越：$entry"
  if [[ "$SNAPSHOT_FORMAT" != ai-support-snapshot-v3 ]]; then
    is_allowed_snapshot_path "$entry" || die "版本快照包含未授权路径：$entry"
  fi
done < <(tar --list --gzip --file "$ARCHIVE")
while IFS= read -r listing; do
  case "${listing:0:1}" in
    -|d) ;;
    *) die "版本快照包含链接或特殊文件" ;;
  esac
done < <(tar --list --verbose --gzip --file "$ARCHIVE")

STAGING=$(mktemp -d "${DEPLOY_DIR}/tmp/rollback-stage.XXXXXX")
cleanup() {
  local status=$?
  trap - EXIT
  if (( status != 0 )); then
    record_maintenance_event "$DEPLOY_DIR" rollback failed "$status"
  fi
  if (( status != 0 && MUTATION_STARTED == 1 )); then
    # 数据库恢复可能已部分提交；不能单独退回一个数据目录后启动混合代际服务。
    docker_compose "$DEPLOY_DIR" stop n8n anythingllm >/dev/null 2>&1 || true
    if docker_compose "$DEPLOY_DIR" config --services 2>/dev/null | grep -Fxq provider-adapter; then
      docker_compose "$DEPLOY_DIR" stop provider-adapter >/dev/null 2>&1 || true
    fi
    set_installation_fact "$DEPLOY_DIR" local_services failed || true
    set_installation_fact "$DEPLOY_DIR" app_config failed || true
    warn "回滚未完成：应用保持停止，未启动混合状态。恢复材料保留于：$STAGING"
    [[ -z "${ANYTHING_PREVIOUS:-}" ]] || warn "回滚前 AnythingLLM 数据保留于：$ANYTHING_PREVIOUS"
    if (( FAILED_UPDATE_RECOVERY )); then
      warn '同次升级恢复 journal 已保留；仅可用其中 token 重新执行 --failed-update-recovery，不得改用普通无安全快照回滚'
    else
      [[ -z "${SAFETY_ID:-}" ]] || warn "可成套恢复安全快照：rollback.sh --deploy-dir $DEPLOY_DIR --snapshot $SAFETY_ID --no-safety-snapshot"
    fi
  else
    rm -rf -- "$STAGING"
    if (( status != 0 && SERVICES_STOPPED == 1 )); then
      warn "回滚尚未修改数据，重新启动原有应用服务"
      docker_compose "$DEPLOY_DIR" up -d "${PAUSED_APP_SERVICES[@]}" >/dev/null 2>&1 || true
    fi
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
tar --extract --gzip --file "$ARCHIVE" --directory "$STAGING" --no-same-owner --no-same-permissions
PAYLOAD="${STAGING}/payload"
[[ ! -e "${PAYLOAD}/data/runtime/knowledge-migration.json" && ! -L "${PAYLOAD}/data/runtime/knowledge-migration.json" ]] \
  || die '快照包含未完成知识迁移；未停止服务或恢复中间索引代'
[[ -f "${PAYLOAD}/VERSION" && -f "${PAYLOAD}/docker-compose.yml" && -f "${PAYLOAD}/n8n/workflow.json" ]] || die "版本快照缺少必要文件"
[[ -s "${PAYLOAD}/data/postgres/n8n.dump" && ! -L "${PAYLOAD}/data/postgres/n8n.dump" ]] || die "版本快照缺少 n8n 数据库备份"
[[ "$(<"${PAYLOAD}/VERSION")" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "快照 VERSION 格式无效"
ROLLBACK_TARGET_VERSION=$(<"${PAYLOAD}/VERSION")
jq empty "${PAYLOAD}/n8n/workflow.json" || die "快照 workflow 无效"
if ! version_at_least "$ROLLBACK_TARGET_VERSION" v1.3.0 \
  && (( SAFETY_SNAPSHOT == 0 && FAILED_UPDATE_RECOVERY == 0 )); then
  die '降到不识别资料双层状态的旧版本时必须先创建安全快照；拒绝 --no-safety-snapshot'
fi
if (( FAILED_UPDATE_RECOVERY )) && [[ "$ROLLBACK_TARGET_VERSION" != "$RECOVERY_OLD_VERSION" ]]; then
  die 'failed-update-recovery 提取载荷版本与 journal 旧版本不一致；未修改部署'
fi

FAILED_UPDATE_QUARANTINE="${DEPLOY_DIR}/backups/.failed-update-${RECOVERY_TOKEN}"
failed_update_quarantine_valid() {
  [[ ! -e "$FAILED_UPDATE_QUARANTINE" && ! -L "$FAILED_UPDATE_QUARANTINE" ]] && return 0
  [[ -d "$FAILED_UPDATE_QUARANTINE" && ! -L "$FAILED_UPDATE_QUARANTINE" \
    && "$(stat -c '%a:%u' -- "$FAILED_UPDATE_QUARANTINE" 2>/dev/null || true)" == "700:${EUID}" ]] \
    || return 1
  [[ -z "$(find "$FAILED_UPDATE_QUARANTINE" -mindepth 1 \! -type f \! -type d -print -quit 2>/dev/null)" ]] \
    || return 1
  while IFS= read -r -d '' item; do
    [[ "$(stat -c '%u' -- "$item" 2>/dev/null || true)" =~ ^(0|1000)$ ]] || return 1
    [[ -d "$item" || "$(stat -c '%h' -- "$item" 2>/dev/null || true)" == 1 ]] || return 1
  done < <(find "$FAILED_UPDATE_QUARANTINE" -mindepth 1 -print0)
}

failed_update_quarantine_transients() {
  local artifact relative destination
  local -a artifacts=(
    "${DEPLOY_DIR}/.env.crispai-atomic.json"
    "${DEPLOY_DIR}/.env.crispai-atomic.next"
    "${DEPLOY_DIR}/config/provider-pool-transaction.json"
    "${DEPLOY_DIR}/data/runtime/knowledge-migration.json"
    "${DEPLOY_DIR}/backups/config-history/materials.recovery"
    "${DEPLOY_DIR}/backups/config-history/materials.initialize"
  )
  shopt -s nullglob
  artifacts+=("${DEPLOY_DIR}"/.env.source.* "${DEPLOY_DIR}"/.env.tmp.*)
  shopt -u nullglob
  failed_update_quarantine_valid || return 1
  for artifact in "${artifacts[@]}"; do
    [[ -e "$artifact" || -L "$artifact" ]] || continue
    [[ ! -L "$artifact" && ( -f "$artifact" || -d "$artifact" ) ]] || return 1
    [[ "$(stat -c '%u' -- "$artifact" 2>/dev/null || true)" =~ ^(0|1000)$ ]] || return 1
    [[ -d "$artifact" || "$(stat -c '%h' -- "$artifact" 2>/dev/null || true)" == 1 ]] || return 1
    relative=${artifact#"${DEPLOY_DIR}/"}
    [[ "$relative" != "$artifact" && "$relative" != /* && "$relative" != *..* \
      && "$relative" != *$'\n'* && "$relative" != *$'\r'* && "$relative" != *$'\t'* ]] || return 1
    destination="${FAILED_UPDATE_QUARANTINE}/${relative}"
    [[ ! -e "$destination" && ! -L "$destination" ]] || return 1
    if [[ ! -e "$FAILED_UPDATE_QUARANTINE" ]]; then
      mkdir -m 0700 -- "$FAILED_UPDATE_QUARANTINE" || return 1
    fi
    mkdir -p -- "${destination%/*}" || return 1
    mv -- "$artifact" "$destination" || return 1
  done
  failed_update_quarantine_valid || return 1
  if [[ -d "$FAILED_UPDATE_QUARANTINE" ]]; then
    sync -f "$FAILED_UPDATE_QUARANTINE" || return 1
  fi
  sync -f "${DEPLOY_DIR}/backups"
}

failed_update_quarantine_remove() {
  failed_update_quarantine_valid || return 1
  [[ ! -e "$FAILED_UPDATE_QUARANTINE" ]] && return 0
  find "$FAILED_UPDATE_QUARANTINE" -depth -delete || return 1
  sync -f "${DEPLOY_DIR}/backups"
}

# 无论是否跳过安全快照，都必须在停止服务或覆盖 .env 前拒绝未决配置事务。
# journal 与 source/candidate 是同一恢复责任，不能由另一代回滚载荷接管或清理。
if (( FAILED_UPDATE_RECOVERY == 0 )); then
  for marker in "${DEPLOY_DIR}/.env.crispai-atomic.json" \
    "${DEPLOY_DIR}/.env.crispai-atomic.next"; do
    [[ ! -e "$marker" && ! -L "$marker" ]] \
      || die '当前敏感配置提交事务尚未收口；不能开始版本回滚'
  done
  shopt -s nullglob
  ATOMIC_CONFIG_ARTIFACTS=("${DEPLOY_DIR}"/.env.source.* "${DEPLOY_DIR}"/.env.tmp.*)
  shopt -u nullglob
  (( ${#ATOMIC_CONFIG_ARTIFACTS[@]} == 0 )) \
    || die '当前敏感配置存在未归属恢复材料；不能开始版本回滚'
  materials_recovery_cleanup_orphans "$DEPLOY_DIR" \
    || die '当前资料恢复遗留临时对象不安全；不能开始版本回滚'
  [[ ! -e "${DEPLOY_DIR}/backups/config-history/materials.recovery" \
    && ! -L "${DEPLOY_DIR}/backups/config-history/materials.recovery" \
    && ! -e "${DEPLOY_DIR}/backups/config-history/materials.initialize" \
    && ! -L "${DEPLOY_DIR}/backups/config-history/materials.initialize" ]] \
    || die '当前资料事务尚未收口；不能用版本回滚丢弃恢复责任'
fi
MATERIALS_DOWNGRADE_BACKUP=""
if ! version_at_least "$ROLLBACK_TARGET_VERSION" v1.3.0 \
  && [[ -e "${DEPLOY_DIR}/backups/config-history/materials.applied.tar.gz" \
    || -L "${DEPLOY_DIR}/backups/config-history/materials.applied.tar.gz" ]]; then
  MATERIALS_DOWNGRADE_BACKUP="${DEPLOY_DIR}/backups/config-history/materials.applied.pre-v1.3.${SNAPSHOT_ID}.tar.gz"
  [[ -f "${DEPLOY_DIR}/backups/config-history/materials.applied.tar.gz" \
    && ! -L "${DEPLOY_DIR}/backups/config-history/materials.applied.tar.gz" ]] \
    || die '降版资料原文包保全路径不安全；未修改部署'
  if [[ -e "$MATERIALS_DOWNGRADE_BACKUP" || -L "$MATERIALS_DOWNGRADE_BACKUP" ]]; then
    # 同次恢复可能已保全新包并发布旧包；只凭 VERSION 不能证明此提交已完成。
    # 保全文件不覆盖，只有当前 canonical 与已校验快照载荷逐字相同时才续做。
    if (( FAILED_UPDATE_RECOVERY )) \
      && [[ "$RECOVERY_PHASE" == recovering \
        && -f "$MATERIALS_DOWNGRADE_BACKUP" && ! -L "$MATERIALS_DOWNGRADE_BACKUP" \
        && "$(stat -c '%a:%h:%u' -- "$MATERIALS_DOWNGRADE_BACKUP" 2>/dev/null || true)" == "600:1:${EUID}" \
        && "$(stat -c '%a:%h:%u' -- "${DEPLOY_DIR}/backups/config-history/materials.applied.tar.gz" 2>/dev/null || true)" == "600:1:${EUID}" \
        && -f "${PAYLOAD}/backups/config-history/materials.applied.tar.gz" \
        && ! -L "${PAYLOAD}/backups/config-history/materials.applied.tar.gz" ]] \
      && cmp -s -- "${DEPLOY_DIR}/backups/config-history/materials.applied.tar.gz" \
        "${PAYLOAD}/backups/config-history/materials.applied.tar.gz"; then
      MATERIALS_DOWNGRADE_BACKUP=""
    else
      die '降版资料原文包保全路径不安全；未修改部署'
    fi
  fi
fi
for name in runtime.yaml keyword.yaml menu.yaml handoff.yaml tags.yaml feedback.yaml; do
  if [[ -f "${PAYLOAD}/config/${name}" ]]; then
    # 兼容旧版本 schema，只做共用严格语法/字节检查；保留原始 YAML 不改写。
    configuration_decode_file "${PAYLOAD}/config/${name}" "${STAGING}/validated-${name}.json" \
      >/dev/null 2>&1 || die "快照配置不是合法的受限 JSON/YAML：$name"
  fi
done
if [[ -f "${PAYLOAD}/config/provider.yaml" ]] && provider_config_has_secret_field "${PAYLOAD}/config/provider.yaml"; then
  die "快照 provider.yaml 包含疑似密钥字段"
fi
if [[ "$SNAPSHOT_FORMAT" == ai-support-snapshot-v3 ]]; then
  [[ -s "${PAYLOAD}/.env" ]] || die "完整快照缺少内部凭据文件"
  restored_database_password=$(env_get "${PAYLOAD}/.env" POSTGRES_PASSWORD)
  if [[ -z "$restored_database_password" ]] || ! validate_env_value "$restored_database_password"; then
    die "快照数据库密码无效；未修改部署"
  fi
  if version_at_least "$(sed -n '1p' "${PAYLOAD}/VERSION")" v1.2.1; then
    for name in config/provider-pool-applied.json config/provider-pool.yaml \
      scripts/provider-adapter.js scripts/provider-router.js scripts/provider-envelope.js \
      scripts/provider-pool.py scripts/provider.sh scripts/configuration.sh \
      scripts/menu-display.py scripts/menu-provider-ui.sh n8n/runtime.js; do
      [[ -f "${PAYLOAD}/${name}" && ! -L "${PAYLOAD}/${name}" ]] || die "主备版本快照缺少必要文件：$name"
    done
    knowledge_snapshot_modules_check "$PAYLOAD"
  fi
  if version_at_least "$(sed -n '1p' "${PAYLOAD}/VERSION")" v1.2.2; then
    [[ -f "${PAYLOAD}/scripts/visitor-output.js" && ! -L "${PAYLOAD}/scripts/visitor-output.js" ]] \
      || die '访客输出策略快照缺少必要文件：scripts/visitor-output.js'
  fi
  if version_at_least "$(sed -n '1p' "${PAYLOAD}/VERSION")" v1.3.0; then
    [[ -f "${PAYLOAD}/scripts/materials-recovery.py" && ! -L "${PAYLOAD}/scripts/materials-recovery.py" ]] \
      || die '资料恢复事务快照缺少必要文件：scripts/materials-recovery.py'
    [[ -f "${PAYLOAD}/scripts/atomic-config.py" && ! -L "${PAYLOAD}/scripts/atomic-config.py" ]] \
      || die '敏感配置原子提交快照缺少必要文件：scripts/atomic-config.py'
    [[ -f "${PAYLOAD}/config/materials-applied.json" \
      && ! -L "${PAYLOAD}/config/materials-applied.json" \
      && -f "${PAYLOAD}/backups/config-history/materials.applied.tar.gz" \
      && ! -L "${PAYLOAD}/backups/config-history/materials.applied.tar.gz" ]] \
      || die 'v1.3.0 快照缺少成套资料投影或规范原文包'
    mkdir -m 0700 -- "${PAYLOAD}/tmp"
    normalize_runtime_control_files "$PAYLOAD" \
      || die 'v1.3.0 快照的知识运行投影权限或文件身份不安全；未修改部署'
    materials_snapshot_validate_generation "$PAYLOAD" \
      "${PAYLOAD}/backups/config-history/materials.applied.tar.gz" \
      "${PAYLOAD}/config/materials-applied.json" \
      || die 'v1.3.0 快照的资料原文、知识索引与投影不同代；未修改部署'
  fi
  if [[ -e "${PAYLOAD}/config/provider-pool-applied.json" ]]; then
    python3 "${SCRIPT_DIR}/provider-pool.py" --deploy-dir "$PAYLOAD" list >/dev/null \
      || die '快照接口池与秘密代次不完整，未修改部署'
    [[ -d "${PAYLOAD}/data/provider-router" && ! -L "${PAYLOAD}/data/provider-router" ]] \
      || die '快照缺少主备路由的持久状态，未修改部署'
  fi
fi

ROOT_FILES=(VERSION CHANGELOG.md README.md LICENSE AGENTS.md .env.example docker-compose.yml)
# v1.1.0 及更早快照只有这四个根目录入口；它们始终是可回滚版本的必需文件。
ROOT_EXECUTABLES=(install.sh manage.sh update.sh uninstall.sh)
CONFIG_FILES=(app.yaml provider.yaml provider.yaml.example prompt.md prompt.md.example keyword.yaml keyword.yaml.example menu.yaml menu.yaml.example handoff.yaml handoff.yaml.example tags.yaml tags.yaml.example feedback.yaml feedback.yaml.example Caddyfile Caddyfile.example)
SCRIPT_FILES=(common.sh healthcheck.sh backup.sh restore.sh analytics.sh snapshot.sh rollback.sh bootstrap.sh wizard.sh package-release.sh)
DOC_FILES=(INSTALL.md ARCHITECTURE.md CONFIG.md SECURITY.md TESTING.md)
OPTIONAL_DOC_FILES=(RELEASE.md)

validate_optional_version_file() {
  local source=$1 destination=$2 label=$3
  if [[ -e "$source" || -L "$source" ]]; then
    [[ -f "$source" && ! -L "$source" ]] || die "快照可选模块不安全：$label"
  fi
  if [[ -e "$destination" || -L "$destination" ]]; then
    [[ -f "$destination" && ! -L "$destination" ]] \
      || die "当前受管模块路径不安全，未开始回滚：$label"
  fi
}

sync_optional_version_file() {
  local source=$1 destination=$2 mode=$3 label=$4
  if [[ -f "$source" && ! -L "$source" ]]; then
    install -m "$mode" -- "$source" "$destination"
  elif [[ -e "$source" || -L "$source" ]]; then
    die "快照可选模块不安全：$label"
  elif [[ -e "$destination" || -L "$destination" ]]; then
    [[ -f "$destination" && ! -L "$destination" ]] \
      || die "当前受管模块路径在回滚期间发生变化：$label"
    rm -f -- "$destination"
    info "目标快照不含 ${label}，已移除当前版本的受管模块"
  fi
}

# 在停止服务前验证后续无条件安装的文件。损坏或跨版本不完整的快照不得让现有实例停机。
for name in "${ROOT_FILES[@]}"; do
  [[ -f "${PAYLOAD}/${name}" && ! -L "${PAYLOAD}/${name}" ]] \
    || die "版本快照缺少必要文件：$name"
done
for name in "${ROOT_EXECUTABLES[@]}"; do
  [[ -f "${PAYLOAD}/${name}" && ! -L "${PAYLOAD}/${name}" ]] \
    || die "版本快照缺少必要入口：$name"
done
for name in "${DOC_FILES[@]}"; do
  [[ -f "${PAYLOAD}/docs/${name}" && ! -L "${PAYLOAD}/docs/${name}" ]] \
    || die "版本快照缺少必要文档：$name"
done
validate_optional_version_file "${PAYLOAD}/get.sh" "${DEPLOY_DIR}/get.sh" get.sh
validate_optional_version_file "${PAYLOAD}/scripts/doctor.sh" "${DEPLOY_DIR}/scripts/doctor.sh" scripts/doctor.sh
validate_optional_version_file "${PAYLOAD}/data/knowledge-projection.json" "${DEPLOY_DIR}/data/knowledge-projection.json" data/knowledge-projection.json
for module in materials.sh materials-recovery.py atomic-config.py logs.sh log-redact.py provider-adapter.js visitor-output.js provider-router.js provider-envelope.js provider-pool.py provider.sh configuration.sh menu-display.py menu-provider-ui.sh \
  knowledge-component.js knowledge-profile.py knowledge-profile.sh knowledge-lexical.py; do
  validate_optional_version_file "${PAYLOAD}/scripts/${module}" "${DEPLOY_DIR}/scripts/${module}" "scripts/${module}"
done
for module in runtime.js admin-query.js knowledge-lexical.js; do
  validate_optional_version_file "${PAYLOAD}/n8n/${module}" "${DEPLOY_DIR}/n8n/${module}" "n8n/${module}"
done

require_docker_runtime
docker_compose "$DEPLOY_DIR" config --quiet

# 在修改任何文件或数据前确认历史镜像仍可用，避免“文件已回滚、镜像未回滚”的混合状态。
while IFS=$'\t' read -r reference image_id; do
  [[ -n "$reference" && -n "$image_id" ]] || continue
  [[ "$reference" =~ ^[A-Za-z0-9][A-Za-z0-9._/@:-]{0,255}$ && "$image_id" =~ ^sha256:[0-9a-f]{64}$ ]] \
    || die "快照包含无效镜像标识"
  docker image inspect "$image_id" >/dev/null 2>&1 \
    || die "本机缺少回滚所需历史镜像：$reference ($image_id)"
done < <(jq -r '.images[]? | [.reference,.id] | @tsv' "$MANIFEST")

failed_update_assert_runtime_rewind_safe() {
  python3 -B - "$DEPLOY_DIR" "$PAYLOAD" <<'PY'
import hashlib
import json
from pathlib import Path
import re
import sys

current = Path(sys.argv[1]) / 'data/runtime'
snapshot = Path(sys.argv[2]) / 'data/runtime'
def load(path, maximum=2097152):
    info = path.lstat()
    if path.is_symlink() or not path.is_file() or info.st_nlink != 1 or info.st_size > maximum:
        raise ValueError('state_file')
    return json.loads(path.read_text(encoding='utf-8'))

def sessions(directory):
    result = {}
    if not directory.exists():
        return result
    if directory.is_symlink() or not directory.is_dir():
        raise ValueError('state_directory')
    files = sorted(directory.glob('session-*.json'))
    if len(files) > 10000:
        raise ValueError('state_count')
    for file in files:
        if not re.fullmatch(r'session-[a-f0-9]{64}\.json', file.name):
            raise ValueError('state_name')
        value = load(file)
        if value.get('schema_version') == 2:
            if hashlib.sha256((value['website_id']+'\0'+value['session_id']).encode()).hexdigest() != file.stem[8:]:
                raise ValueError('state_binding')
            if not isinstance(value.get('jobs'), list) or not isinstance(value.get('outgoing'), dict):
                raise ValueError('state_shape')
        elif not isinstance(value.get('aiEnabled'), bool):
            raise ValueError('state_version')
        result[file.name] = value
    return result

def owned(directory):
    result = {}
    if not directory.exists():
        return result
    files = sorted(directory.glob('owned-*.json'))
    if len(files) > 100000:
        raise ValueError('owned_count')
    for file in files:
        match = re.fullmatch(r'owned-([a-f0-9]{64})-([a-f0-9]{2})\.json', file.name)
        if not match:
            raise ValueError('owned_name')
        value = load(file,1048576)
        values = value.get('fingerprints')
        if value.get('schema_version') != 1 or not isinstance(values,list) or len(values)>50000 or any(not isinstance(item,str) or not re.fullmatch(r'(?:0|[1-9][0-9]{0,15})',item) or int(item)>9007199254740991 for item in values):
            raise ValueError('owned_shape')
        if any(int(item)%256 != int(match[2],16) for item in values):
            raise ValueError('owned_bucket_binding')
        result.setdefault(match[1],set()).update(values)
    return result

try:
    old = sessions(snapshot)
    fresh = sessions(current)
    known_owned = owned(snapshot)
    fresh_owned = owned(current)
    new_jobs = 0
    new_outgoing = 0
    new_human = 0
    for name,state in fresh.items():
        previous = old.get(name,{})
        if state.get('schema_version') != 2:
            if state != previous:
                raise ValueError('legacy_state_changed')
            continue
        key=name[8:-5]
        previous_jobs=previous.get('jobs',[])
        if not isinstance(previous_jobs,list):
            raise ValueError('snapshot_jobs')
        previous_ids={job['id'] for job in previous_jobs if isinstance(job,dict) and isinstance(job.get('id'),str)}
        for job in state['jobs']:
            if not isinstance(job,dict) or not isinstance(job.get('id'),str):
                raise ValueError('job_shape')
            new_jobs += job['id'] not in previous_ids
        previous_outgoing=previous.get('outgoing',{})
        if not isinstance(previous_outgoing,dict):
            raise ValueError('snapshot_outgoing')
        known_owned.setdefault(key,set()).update(str(item) for item in previous_outgoing)
        new_outgoing += len(set(state['outgoing'])-set(previous_outgoing))
        new_human += state.get('last_human_at',0)>previous.get('last_human_at',0)
    new_owned=sum(len(values-known_owned.get(key,set())) for key,values in fresh_owned.items())
    if new_jobs or new_outgoing or new_owned or new_human:
        print('错误：更新后已有新增应答或人工责任，拒绝用旧快照回退运行状态'
              f'（任务 {new_jobs}，出站 {new_outgoing}，自有指纹 {new_owned}，人工事实 {new_human}）；'
              '当前状态与同次恢复材料均保留，不得盲目重发。',file=sys.stderr)
        raise SystemExit(1)
except (OSError,ValueError,KeyError,TypeError):
    print('错误：无法完整核对更新后的应答责任；拒绝回退运行状态，恢复材料保持。',file=sys.stderr)
    raise SystemExit(1)
PY
}

if (( FAILED_UPDATE_RECOVERY )); then
  failed_update_assert_runtime_rewind_safe \
    || die '自动恢复会覆盖更新后已接收或已投递的责任；未修改现有程序、数据库或会话状态'
  failed_update_set_phase recovering \
    || die 'failed-update-recovery 无法在停服前持久化恢复阶段；未修改部署'
  MUTATION_STARTED=1
  failed_update_quarantine_transients \
    || die 'failed-update-recovery 无法安全隔离同次更新产生的临时事务；应用将保持停止'
fi

# 安全快照自身需要对仍在运行的 n8n 做投影/Prompt 回读，并负责在一致性
# 窗口内暂停和恢复应用服务。必须在本回滚停止容器前完成；否则真实 Docker
# 不允许对已停止的 n8n exec，默认回滚会在任何数据修改前确定性失败。
if (( SAFETY_SNAPSHOT )); then
  SAFETY_ID=$("${SCRIPT_DIR}/snapshot.sh" --deploy-dir "$DEPLOY_DIR" \
    --reason "pre-rollback-${SNAPSHOT_ID}" --protect "$SNAPSHOT_ID" --quiet)
  info "回滚前安全快照：$SAFETY_ID"
fi

mapfile -t PAUSED_APP_SERVICES < <(docker_compose "$DEPLOY_DIR" config --services | grep -E '^(n8n|anythingllm|provider-adapter)$')
(( ${#PAUSED_APP_SERVICES[@]} )) || PAUSED_APP_SERVICES=(n8n anythingllm)
docker_compose "$DEPLOY_DIR" stop "${PAUSED_APP_SERVICES[@]}"
SERVICES_STOPPED=1
if (( FAILED_UPDATE_RECOVERY )); then
  failed_update_assert_runtime_rewind_safe \
    || die '暂停期间发现新增应答责任；未回退程序、数据库或会话状态，原恢复材料保持'
fi

MUTATION_STARTED=1
# 新代调度和兼容入口不能悬挂在降代后的旧模块上；完整恢复后由目标版本重建。
remove_log_maintenance "$DEPLOY_DIR" || die '回滚前无法安全停止本实例日志调度'
if [[ -f "${DEPLOY_DIR}/scripts/launcher.sh" && ! -L "${DEPLOY_DIR}/scripts/launcher.sh" ]]; then
  # shellcheck disable=SC2016 # 文件路径走位置参数，不解释配置或正文。
  bash -c 'source "$1"; if declare -F remove_crisp_compat_launcher >/dev/null; then
    launcher=/usr/local/bin/crispai
    if [[ -f "$2/config/.crispai-launcher" && ! -L "$2/config/.crispai-launcher" ]]; then
      IFS= read -r launcher < "$2/config/.crispai-launcher" || exit 1
    fi
    remove_crisp_compat_launcher "$2" "$launcher"
  fi' rollback-launcher "${DEPLOY_DIR}/scripts/launcher.sh" "$DEPLOY_DIR"
fi
record_maintenance_event "$DEPLOY_DIR" rollback start
if (( FAILED_UPDATE_RECOVERY )); then
  MARKER_SOURCE=$RECOVERY_PREVIOUS_SOURCE
  MARKER_VERSION=$RECOVERY_OLD_VERSION
else
  MARKER_SOURCE=$(sed -n 's/^source=//p' "${DEPLOY_DIR}/${INSTALL_MARKER}" | head -n 1)
  MARKER_VERSION=$(<"${DEPLOY_DIR}/VERSION")
fi
write_installation_marker "$DEPLOY_DIR" "$MARKER_SOURCE" "$MARKER_VERSION" installing
if (( FAILED_UPDATE_RECOVERY )); then
  if ! sync -f "${DEPLOY_DIR}/${INSTALL_MARKER}" || ! sync -f "$DEPLOY_DIR"; then
    die 'failed-update-recovery 恢复中标记未能持久化；journal 保持'
  fi
fi
if [[ "$SNAPSHOT_FORMAT" == ai-support-snapshot-v3 ]]; then
  install -m 0600 -- "${PAYLOAD}/.env" "${DEPLOY_DIR}/.env"
fi

for image_key in N8N_IMAGE POSTGRES_IMAGE ANYTHINGLLM_IMAGE; do
  image_value=$(jq -er --arg key "$image_key" '.image_variables[$key]' "$MANIFEST")
  env_set "${DEPLOY_DIR}/.env" "$image_key" "$image_value"
done
image_value=$(jq -r '.image_variables.CADDY_IMAGE // "caddy:2.10.2-alpine"' "$MANIFEST")
env_set "${DEPLOY_DIR}/.env" CADDY_IMAGE "$image_value"

for name in "${ROOT_FILES[@]}"; do
  install -m 0640 -- "${PAYLOAD}/${name}" "${DEPLOY_DIR}/${name}"
done
for name in "${ROOT_EXECUTABLES[@]}"; do
  install -m 0750 -- "${PAYLOAD}/${name}" "${DEPLOY_DIR}/${name}"
done
for name in "${CONFIG_FILES[@]}"; do
  if [[ -f "${PAYLOAD}/config/${name}" ]]; then
    install -m 0640 -- "${PAYLOAD}/config/${name}" "${DEPLOY_DIR}/config/${name}"
  fi
done
for name in "${SCRIPT_FILES[@]}"; do
  if [[ -f "${PAYLOAD}/scripts/${name}" ]]; then
    install -m 0750 -- "${PAYLOAD}/scripts/${name}" "${DEPLOY_DIR}/scripts/${name}"
  fi
done
for name in "${DOC_FILES[@]}"; do
  install -m 0640 -- "${PAYLOAD}/docs/${name}" "${DEPLOY_DIR}/docs/${name}"
done
for name in "${OPTIONAL_DOC_FILES[@]}"; do
  if [[ -f "${PAYLOAD}/docs/${name}" ]]; then
    install -m 0640 -- "${PAYLOAD}/docs/${name}" "${DEPLOY_DIR}/docs/${name}"
  else
    rm -f -- "${DEPLOY_DIR}/docs/${name}"
  fi
done
install -m 0640 -- "${PAYLOAD}/n8n/workflow.json" "${DEPLOY_DIR}/n8n/workflow.json"

if [[ "$SNAPSHOT_FORMAT" == ai-support-snapshot-v3 ]]; then
  # 源文件已经由归档校验器验证为普通文件；补齐新版本的生产模块和文档。
  for directory in config n8n scripts docs; do
    cp -a -- "${PAYLOAD}/${directory}/." "${DEPLOY_DIR}/${directory}/"
  done
  find "${DEPLOY_DIR}/scripts" -type f -name '*.sh' -exec chmod 0750 {} +
fi

# get.sh 与 doctor.sh 从 v1.1.1 起才属于版本载荷。回滚旧快照时必须删除当前代文件，
# 避免旧 manage/common 与新 doctor/get 组成未经验证的混合代；新快照则正常同步。
sync_optional_version_file "${PAYLOAD}/get.sh" "${DEPLOY_DIR}/get.sh" 0750 get.sh
sync_optional_version_file "${PAYLOAD}/scripts/doctor.sh" "${DEPLOY_DIR}/scripts/doctor.sh" 0750 scripts/doctor.sh
for module in materials.sh materials-recovery.py atomic-config.py logs.sh log-redact.py provider-adapter.js visitor-output.js provider-router.js provider-envelope.js provider-pool.py provider.sh configuration.sh menu-display.py menu-provider-ui.sh \
  knowledge-component.js knowledge-profile.py knowledge-profile.sh knowledge-lexical.py; do
  module_mode=0750
  case "$module" in *.js|*.py) module_mode=0640 ;; esac
  sync_optional_version_file "${PAYLOAD}/scripts/${module}" "${DEPLOY_DIR}/scripts/${module}" "$module_mode" "scripts/${module}"
done
for module in runtime.js admin-query.js knowledge-lexical.js; do
  sync_optional_version_file "${PAYLOAD}/n8n/${module}" "${DEPLOY_DIR}/n8n/${module}" 0640 "n8n/${module}"
done

find "${DEPLOY_DIR}/knowledge" -maxdepth 1 -type f ! -name 'README.md' \
  \( -iname '*.md' -o -iname '*.txt' -o -iname '*.pdf' -o -iname '*.docx' \) -delete
while IFS= read -r -d '' file; do
  name=$(basename -- "$file")
  install -m 0640 -- "$file" "${DEPLOY_DIR}/knowledge/${name}"
done < <(find "${PAYLOAD}/knowledge" -maxdepth 1 -type f ! -name 'README.md' -print0 | sort -z)

restore_snapshot_tree() {
  local relative=$1 destination="${DEPLOY_DIR}/$1" source="${PAYLOAD}/$1"
  [[ -d "$source" && ! -L "$source" && -d "$destination" && ! -L "$destination" ]] \
    || die "恢复目录不安全：$relative"
  if [[ "$relative" == data/runtime ]]; then
    # 归档以 --no-same-owner 提取到受限且已校验的暂存树，运行状态因而变成 root 所有。
    # 只修复这份新载荷，不递归修改既有运行树；知识投影随后仍由 root 签发。
    chown -R 1000:1000 "$source" || die '无法恢复会话快照的运行用户所有权'
    normalize_runtime_control_files "$PAYLOAD" \
      || die '会话快照的知识控制投影权限无法恢复；应用保持停止'
  fi
  # 数据目录本身保留 inode；删除范围严格限定于受管实例的这一个已核验子目录。
  find "$destination" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
  cp -a -- "$source/." "$destination/"
}
if [[ "$SNAPSHOT_FORMAT" == ai-support-snapshot-v3 ]]; then
  restore_snapshot_tree config
  restore_snapshot_tree knowledge
  for directory in data/runtime data/n8n; do
    mkdir -p -- "${DEPLOY_DIR}/${directory}"
    [[ ! -d "${PAYLOAD}/${directory}" ]] || restore_snapshot_tree "$directory"
  done
  for directory in secrets data/provider-router; do
    if [[ -d "${PAYLOAD}/${directory}" ]]; then
      mkdir -p -- "${DEPLOY_DIR}/${directory}"
      restore_snapshot_tree "$directory"
    elif [[ -e "${DEPLOY_DIR}/${directory}" || -L "${DEPLOY_DIR}/${directory}" ]]; then
      [[ -d "${DEPLOY_DIR}/${directory}" && ! -L "${DEPLOY_DIR}/${directory}" ]] || die '降版前接口资料目录不安全'
      provider_previous=$(mktemp -d "${DEPLOY_DIR}/backups/provider-pre-rollback.XXXXXXXX")
      chmod 0700 "$provider_previous"
      mv -- "${DEPLOY_DIR}/${directory}" "${provider_previous}/$(basename -- "$directory")"
      info "旧版本不识别的主备秘密或状态已受限保留：$provider_previous"
    fi
  done
fi

if version_at_least "$ROLLBACK_TARGET_VERSION" v1.3.0; then
  [[ -d "${DEPLOY_DIR}/backups/config-history" \
    && ! -L "${DEPLOY_DIR}/backups/config-history" ]] \
    || die '资料历史目录不安全；应用保持停止'
  materials_snapshot_publish "$DEPLOY_DIR" \
    "${PAYLOAD}/backups/config-history/materials.applied.tar.gz" \
    "${DEPLOY_DIR}/backups/config-history/materials.applied.tar.gz" \
    || die '回滚资料规范原文包发布失败；应用保持停止'
elif [[ -n "$MATERIALS_DOWNGRADE_BACKUP" ]]; then
  # 旧版本不理解 canonical 原文包。安全快照之外再受限保全一份，避免活动路径
  # 与旧投影混用；不把它留在旧程序会误识别的固定名称。
  mv -- "${DEPLOY_DIR}/backups/config-history/materials.applied.tar.gz" "$MATERIALS_DOWNGRADE_BACKUP"
  chmod 0600 "$MATERIALS_DOWNGRADE_BACKUP"
  info '新代资料规范原文包已受限保全，旧版本不会将其误作当前投影'
fi
if ! version_at_least "$ROLLBACK_TARGET_VERSION" v1.3.0 \
  && [[ -f "${PAYLOAD}/backups/config-history/materials.applied.tar.gz" ]]; then
  # v1.2.x 的 mark-applied 也依赖自己这一代的原文包，不能只保全新包而丢掉旧包。
  materials_snapshot_publish "$DEPLOY_DIR" \
    "${PAYLOAD}/backups/config-history/materials.applied.tar.gz" \
    "${DEPLOY_DIR}/backups/config-history/materials.applied.tar.gz" \
    || die '旧版资料原文包恢复失败；应用保持停止'
fi

if version_at_least "$ROLLBACK_TARGET_VERSION" v1.3.0; then
  # 快照中的接口池必须由这次恢复后启动的 adapter 重新证明。即使旧格式或
  # 人工保全包意外含有回读文件，也在任何 n8n 启动前精确失效。
  python3 "${DEPLOY_DIR}/scripts/provider-pool.py" --deploy-dir "$DEPLOY_DIR" invalidate-readback >/dev/null \
    || die '回滚前无法失效旧的主备推理准入回执；应用保持停止'
fi

# 只有目标 runtime 已采用 owner.json 所有权协议时才迁移旧空锁。降回旧版本时
# 必须保留目标版本自己的锁语义；新版本则在 n8n 已停止、维护锁仍持有的窗口中
# 仅删除精确的 ownerless 空目录。任何不安全或非空形态均保持应用停止并失败。
if version_at_least "$ROLLBACK_TARGET_VERSION" v1.2.1; then
  SCHEDULER_LOCK_STATE=$(scheduler_scan_lock_state "$DEPLOY_DIR")
  case "$SCHEDULER_LOCK_STATE" in
    absent|owned) ;;
    legacy-ownerless-empty)
      cleanup_legacy_scheduler_scan_lock "$DEPLOY_DIR" \
        || die '旧版会话扫描空锁未能在回滚停写窗口安全迁移；应用保持停止'
      info '已在回滚停写窗口迁移旧版会话扫描空锁'
      ;;
    *) die '目标快照的会话扫描锁不是可安全迁移的旧版空目录；应用保持停止' ;;
  esac
fi

ANYTHING_RESTORE="${DEPLOY_DIR}/data/.anythingllm-restore-${SNAPSHOT_ID}"
ANYTHING_PREVIOUS="${DEPLOY_DIR}/data/.anythingllm-previous-${SNAPSHOT_ID}"
anything_tree_matches_snapshot() {
  python3 -B - "$1" "$2" <<'PY'
import hashlib
import os
from pathlib import Path
import stat
import sys

def tree(root):
    root = Path(root)
    if root.is_symlink() or not root.is_dir():
        raise ValueError("root")
    values = []
    for directory, names, files in os.walk(root, topdown=True, followlinks=False):
        names.sort()
        files.sort()
        base = Path(directory)
        for name in [*names, *files]:
            item = base / name
            info = item.lstat()
            relative = item.relative_to(root).as_posix()
            if stat.S_ISDIR(info.st_mode):
                values.append((relative, "d", ""))
            elif stat.S_ISREG(info.st_mode):
                digest = hashlib.sha256()
                with item.open("rb") as stream:
                    for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                        digest.update(chunk)
                values.append((relative, "f", digest.hexdigest()))
            else:
                raise ValueError("type")
    return values

try:
    valid = tree(sys.argv[1]) == tree(sys.argv[2])
except (OSError, ValueError):
    valid = False
raise SystemExit(0 if valid else 1)
PY
}

anything_restore_directory_reset() {
  [[ -d "$ANYTHING_RESTORE" && ! -L "$ANYTHING_RESTORE" \
    && "$(realpath -m -- "$ANYTHING_RESTORE")" == "$ANYTHING_RESTORE" \
    && "${ANYTHING_RESTORE%/*}" == "${DEPLOY_DIR}/data" ]] || return 1
  case "$(stat -c '%a:%u' -- "$ANYTHING_RESTORE" 2>/dev/null || true)" in
    700:0|700:1000) ;;
    *) return 1 ;;
  esac
  find "$ANYTHING_RESTORE" -mindepth 1 -depth -delete || return 1
  rmdir -- "$ANYTHING_RESTORE" || return 1
  mkdir -m 0700 -- "$ANYTHING_RESTORE" || return 1
}

if (( FAILED_UPDATE_RECOVERY )); then
  [[ -d "${DEPLOY_DIR}/data" && ! -L "${DEPLOY_DIR}/data" ]] \
    || die 'failed-update-recovery 数据根目录不安全'
  if [[ -e "$ANYTHING_PREVIOUS" || -L "$ANYTHING_PREVIOUS" ]]; then
    [[ -d "$ANYTHING_PREVIOUS" && ! -L "$ANYTHING_PREVIOUS" ]] \
      || die 'failed-update-recovery 旧 AnythingLLM 保全目录不安全'
    if [[ ! -e "${DEPLOY_DIR}/data/anythingllm" && ! -L "${DEPLOY_DIR}/data/anythingllm" \
      && -d "$ANYTHING_RESTORE" && ! -L "$ANYTHING_RESTORE" ]]; then
      if ! anything_tree_matches_snapshot "$ANYTHING_RESTORE" "${PAYLOAD}/data/anythingllm"; then
        anything_restore_directory_reset \
          || die 'failed-update-recovery 无法安全重建中断的 AnythingLLM 暂存目录'
        cp -a -- "${PAYLOAD}/data/anythingllm/." "$ANYTHING_RESTORE/"
      fi
      chown -R 1000:1000 "$ANYTHING_RESTORE" 2>/dev/null \
        || die '无法设置 AnythingLLM 恢复数据权限'
      mv -- "$ANYTHING_RESTORE" "${DEPLOY_DIR}/data/anythingllm"
    elif [[ -d "${DEPLOY_DIR}/data/anythingllm" && ! -L "${DEPLOY_DIR}/data/anythingllm" \
      && ! -e "$ANYTHING_RESTORE" && ! -L "$ANYTHING_RESTORE" ]]; then
      anything_tree_matches_snapshot "${DEPLOY_DIR}/data/anythingllm" "${PAYLOAD}/data/anythingllm" \
        || die 'failed-update-recovery 已交换的 AnythingLLM 数据与目标快照不一致'
    else
      die 'failed-update-recovery AnythingLLM 中断状态不属于同次恢复'
    fi
  else
    [[ -d "${DEPLOY_DIR}/data/anythingllm" && ! -L "${DEPLOY_DIR}/data/anythingllm" ]] \
      || die 'failed-update-recovery 当前 AnythingLLM 数据目录不安全'
    if [[ -e "$ANYTHING_RESTORE" || -L "$ANYTHING_RESTORE" ]]; then
      anything_restore_directory_reset \
        || die 'failed-update-recovery 无法安全重建未发布的 AnythingLLM 暂存目录'
    else
      mkdir -m 0700 -- "$ANYTHING_RESTORE"
    fi
    cp -a -- "${PAYLOAD}/data/anythingllm/." "$ANYTHING_RESTORE/"
    chown -R 1000:1000 "$ANYTHING_RESTORE" 2>/dev/null || die "无法设置 AnythingLLM 回滚数据权限"
    mv -- "${DEPLOY_DIR}/data/anythingllm" "$ANYTHING_PREVIOUS"
    mv -- "$ANYTHING_RESTORE" "${DEPLOY_DIR}/data/anythingllm"
  fi
else
  [[ ! -e "$ANYTHING_RESTORE" && ! -e "$ANYTHING_PREVIOUS" ]] || die "回滚暂存目录已存在，请先人工检查"
  mkdir -m 0700 -- "$ANYTHING_RESTORE"
  cp -a -- "${PAYLOAD}/data/anythingllm/." "$ANYTHING_RESTORE/"
  chown -R 1000:1000 "$ANYTHING_RESTORE" 2>/dev/null || die "无法设置 AnythingLLM 回滚数据权限"
  mv -- "${DEPLOY_DIR}/data/anythingllm" "$ANYTHING_PREVIOUS"
  mv -- "$ANYTHING_RESTORE" "${DEPLOY_DIR}/data/anythingllm"
fi
if [[ -f "${PAYLOAD}/data/knowledge-manifest.json" ]]; then
  install -m 0600 -- "${PAYLOAD}/data/knowledge-manifest.json" "${DEPLOY_DIR}/data/knowledge-manifest.json"
fi
sync_optional_version_file "${PAYLOAD}/data/knowledge-projection.json" "${DEPLOY_DIR}/data/knowledge-projection.json" 0600 data/knowledge-projection.json

MARKER_SOURCE=$(sed -n 's/^source=//p' "${DEPLOY_DIR}/${INSTALL_MARKER}" | head -n 1)
write_installation_marker "$DEPLOY_DIR" "$MARKER_SOURCE" "$(<"${DEPLOY_DIR}/VERSION")" installing
mkdir -p -- "${DEPLOY_DIR}/data/n8n" "${DEPLOY_DIR}/data/anythingllm" "${DEPLOY_DIR}/data/runtime"
set_runtime_ownership "$DEPLOY_DIR"
secure_permissions "$DEPLOY_DIR"

while IFS=$'\t' read -r reference image_id; do
  [[ -n "$reference" && -n "$image_id" ]] || continue
  docker image tag "$image_id" "$reference"
done < <(jq -r '.images[]? | [.reference,.id] | @tsv' "$MANIFEST")

# shellcheck disable=SC2016 # 变量必须在 PostgreSQL 容器内展开，避免密钥出现在宿主机 argv。
if ! docker_compose "$DEPLOY_DIR" exec -T postgres sh -c \
  'PGPASSWORD="$POSTGRES_PASSWORD" pg_restore --username="$POSTGRES_USER" --dbname="$POSTGRES_DB" --clean --if-exists --no-owner --no-acl' \
  < "${PAYLOAD}/data/postgres/n8n.dump"; then
  die "n8n 数据库恢复失败；应用保持停止，请使用安全快照成套恢复"
fi

if [[ "$SNAPSHOT_FORMAT" == ai-support-snapshot-v3 ]]; then
  # pg_dump 不包含角色密码；清理后新安装的数据库必须与快照恢复的 .env 对齐。
  # psql 的 \password 在客户端生成密码散列，明文仅走受控 stdin，不进入 argv/SQL 日志。
  # shellcheck disable=SC2016
  if ! printf '%s\n%s\n' "$restored_database_password" "$restored_database_password" \
    | docker_compose "$DEPLOY_DIR" exec -T postgres sh -c \
      'PGPASSWORD="$POSTGRES_PASSWORD" psql -X --username="$POSTGRES_USER" --dbname="$POSTGRES_DB" --set=ON_ERROR_STOP=1 --command="\password"' >/dev/null; then
    unset restored_database_password
    die "数据库角色凭据恢复失败；未宣称回滚完成，请保留安全快照继续修复"
  fi
  unset restored_database_password
fi

docker_compose "$DEPLOY_DIR" config --quiet
validate_managed_caddy_configuration "$DEPLOY_DIR" || die '回滚候选反代配置未通过预检；应用保持停止'
# AnythingLLM 使用 bind mount。目录经 mv 交换后必须重建容器，确保 mount 绑定到恢复后的 inode。
docker_compose "$DEPLOY_DIR" up -d --force-recreate anythingllm
docker_compose "$DEPLOY_DIR" up -d --force-recreate n8n
docker_compose "$DEPLOY_DIR" up -d --remove-orphans
refresh_program_file_mounts "$DEPLOY_DIR" || die '回滚后的单文件程序挂载未完成刷新'
wait_for_local_health "$DEPLOY_DIR"
if version_at_least "$ROLLBACK_TARGET_VERSION" v1.3.0; then
  python3 "${DEPLOY_DIR}/scripts/provider-pool.py" --deploy-dir "$DEPLOY_DIR" verify-applied >/dev/null \
    || die '回滚后的主备接口配置未通过运行组件完整回读；应用保持保护状态'
fi
if ! version_at_least "$ROLLBACK_TARGET_VERSION" v1.3.0; then
  # 旧快照没有同代 canonical 契约，只能沿用旧版的显式同步行为。
  sync_prompt_to_anythingllm "$DEPLOY_DIR"
fi
import_and_publish_workflow "$DEPLOY_DIR"
wait_for_local_health "$DEPLOY_DIR"
if version_at_least "$ROLLBACK_TARGET_VERSION" v1.3.0; then
  # AnythingLLM 数据库、Prompt、知识索引、投影和原文包均来自同一快照。
  # 这里只读回确认，绝不把快照中可能待编辑的资料重新应用并抬升代次。
  materials_applied_external_readback "$DEPLOY_DIR" \
    "${DEPLOY_DIR}/backups/config-history/materials.applied.tar.gz" \
    "${DEPLOY_DIR}/config/materials-applied.json" \
    || die '回滚后的 Prompt、知识索引、投影或规范原文包不同代；应用保持保护状态'
elif [[ -f "${DEPLOY_DIR}/scripts/materials.sh" && ! -L "${DEPLOY_DIR}/scripts/materials.sh" ]]; then
  bash "${DEPLOY_DIR}/scripts/configuration.sh" --deploy-dir "$DEPLOY_DIR" mark-applied \
    || die '回滚后的资料投影与实际应用不一致；未提交完成状态'
fi
install_log_maintenance "$DEPLOY_DIR" || die '回滚后的日志维护调度未通过回读'
# 老快照没有统一 doctor；恢复到新版本时，在提交完成状态前核验实际运行代。
if [[ -f "${DEPLOY_DIR}/scripts/doctor.sh" && ! -L "${DEPLOY_DIR}/scripts/doctor.sh" ]]; then
  bash "${DEPLOY_DIR}/scripts/healthcheck.sh" --deploy-dir "$DEPLOY_DIR" --application --installation-in-progress \
    || die '回滚后的组件或配置接线检查失败；未提交完成状态，请成套恢复安全快照'
fi
set_installation_fact "$DEPLOY_DIR" dependencies ready
set_installation_fact "$DEPLOY_DIR" local_services ready
set_installation_fact "$DEPLOY_DIR" app_config ready
set_installation_fact "$DEPLOY_DIR" provider ready
if webhook_access_check "$DEPLOY_DIR"; then
  set_installation_fact "$DEPLOY_DIR" webhook ready
else
  set_installation_fact "$DEPLOY_DIR" webhook pending
  warn "回滚后公网 Webhook 尚未通过 DNS/TLS/路由检查（HTTP ${WEBHOOK_ACCESS_STATUS:-000}）"
fi
set_installation_fact "$DEPLOY_DIR" conversation pending
if crisp_api_check "$DEPLOY_DIR"; then
  set_installation_fact "$DEPLOY_DIR" crisp_api ready
else
  set_installation_fact "$DEPLOY_DIR" crisp_api failed
  warn "回滚完成且本地应用已通过检查，但 Crisp API 待修正（HTTP ${CRISP_API_STATUS:-000}）"
fi
refresh_conversation_fact "$DEPLOY_DIR" || set_installation_fact "$DEPLOY_DIR" conversation pending
if [[ "$(installation_fact "$DEPLOY_DIR" crisp_api)" == ready \
  && "$(installation_fact "$DEPLOY_DIR" webhook)" == ready \
  && "$(installation_fact "$DEPLOY_DIR" conversation)" == ready ]]; then
  RESTORED_INSTALLATION_STATE=ready
else
  RESTORED_INSTALLATION_STATE=local-ready
  warn '本地回滚已完成；外部接入尚待验证，可运行 crispai doctor 继续检查'
fi
if (( FAILED_UPDATE_RECOVERY )) && [[ "$RECOVERY_PREVIOUS_STATE" == local-ready ]]; then
  RESTORED_INSTALLATION_STATE=local-ready
fi
if [[ -f "${DEPLOY_DIR}/scripts/launcher.sh" ]]; then
  bash "${DEPLOY_DIR}/scripts/launcher.sh" install --deploy-dir "$DEPLOY_DIR" --non-interactive \
    || warn "版本已恢复，但 crispai 入口存在冲突，请从 manage.sh 检查"
fi
rm -rf -- "$ANYTHING_PREVIOUS"
if (( FAILED_UPDATE_RECOVERY )); then
  failed_update_quarantine_remove \
    || die '升级失败恢复已经通过检查，但临时事务隔离区未能安全清理；journal 保持'
  failed_update_set_phase restored "$RESTORED_INSTALLATION_STATE" \
    || die '升级失败恢复已经通过检查，但无法持久提交 restored 阶段；journal 保持'
  write_installation_marker "$DEPLOY_DIR" "$RECOVERY_PREVIOUS_SOURCE" \
    "$RECOVERY_OLD_VERSION" "$RESTORED_INSTALLATION_STATE"
  if ! sync -f "${DEPLOY_DIR}/${INSTALL_MARKER}" || ! sync -f "$DEPLOY_DIR"; then
    die '升级失败恢复完成标记未能持久化；journal 保持'
  fi
  # 旧代已经完整恢复、健康且 marker 已持久化；此后只是收口恢复凭据。
  # journal 删除失败或信号中断不得再把一致的旧代停成无责任状态。
  MUTATION_STARTED=0
  SERVICES_STOPPED=0
  failed_update_remove_journal \
    || die '升级失败恢复已经完成，但 journal 未能安全清理；恢复责任保持可见'
else
  write_installation_marker "$DEPLOY_DIR" "$MARKER_SOURCE" \
    "$(<"${DEPLOY_DIR}/VERSION")" "$RESTORED_INSTALLATION_STATE"
fi
record_maintenance_event "$DEPLOY_DIR" rollback complete
SERVICES_STOPPED=0

trap - EXIT
rm -rf -- "$STAGING"
if (( FAILED_UPDATE_RECOVERY )); then
  failed_update_candidate_remove \
    || warn '升级失败恢复已收口，但无秘密冻结候选尚未清理；下一次受管更新入口将严格收敛'
fi
info "版本回滚完成：${SNAPSHOT_ID} -> $(<"${DEPLOY_DIR}/VERSION")"
if [[ "$SNAPSHOT_FORMAT" == ai-support-snapshot-v3 ]]; then
  warn "内部凭据、全部知识库、会话状态、n8n 与 AnythingLLM 已恢复；匿名统计和版本历史保留"
else
  warn "旧版 v2 快照不含内部凭据与会话控制数据，已保留当前 .env 和会话状态；数据库与 AnythingLLM 已恢复"
fi
