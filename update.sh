#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/bootstrap.sh
source "${SCRIPT_DIR}/scripts/bootstrap.sh"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/scripts/common.sh"
# shellcheck source=scripts/launcher.sh
source "${SCRIPT_DIR}/scripts/launcher.sh"

DEPLOY_REQUEST=""
SOURCE_REQUEST=""
NO_PULL=0
REAPPLY=0
SKIP_START=0
SNAPSHOT_ID=""
SNAPSHOT_SCRIPT=""
ROLLBACK_SCRIPT=""
BACKUP_SCRIPT=""
UPDATE_COMPLETE=0
SERVICES_STOPPED=0
UPDATE_RECOVERY_JOURNAL=""
UPDATE_RECOVERY_TOMBSTONE=""
UPDATE_TOKEN=""
RECOVERY_PHASE=""
RECOVERY_COMPLETION_STATE=""
SNAPSHOT_MANIFEST_SHA256=""
SNAPSHOT_ARCHIVE_SHA256=""
SOURCE_MANIFEST_SHA256=""
SOURCE_CANDIDATE_SHA256=""
PREVIOUS_INSTALLATION_STATE=""
PREVIOUS_MARKER_SOURCE=""
PREVIOUS_MARKER_SHA256=""
PREVIOUS_MARKER_BASE64=""
UPDATE_OWNER_PID=""
UPDATE_OWNER_BOOT_ID=""
UPDATE_OWNER_START_TICKS=""
UPDATE_RECOVERY_CREATED_AT=""
UPDATE_PREFLIGHT_DIR=""
FROZEN_SOURCE_DIR=""
UPDATE_JOURNAL_PUBLISHED=0

update_source_candidate_identity() {
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

update_frozen_candidate_valid() {
  [[ -n "$FROZEN_SOURCE_DIR" \
    && "$FROZEN_SOURCE_DIR" == "${DEPLOY_DIR}/backups/update-candidate-${UPDATE_TOKEN}" \
    && -d "$FROZEN_SOURCE_DIR" && ! -L "$FROZEN_SOURCE_DIR" \
    && "$(stat -c '%a:%u' -- "$FROZEN_SOURCE_DIR" 2>/dev/null || true)" == "500:${EUID}" ]] \
    || return 1
  [[ "$(sha256sum "${FROZEN_SOURCE_DIR}/scripts/release-manifest.txt" | awk '{print $1}')" == "$SOURCE_MANIFEST_SHA256" ]] \
    || return 1
  [[ "$(update_source_candidate_identity "$FROZEN_SOURCE_DIR" "$NEW_VERSION" immutable)" == "$SOURCE_CANDIDATE_SHA256" ]]
}

update_frozen_candidate_create() {
  local temporary="${DEPLOY_DIR}/backups/.update-candidate-${UPDATE_TOKEN}.tmp"
  [[ ! -e "$temporary" && ! -L "$temporary" \
    && ! -e "$FROZEN_SOURCE_DIR" && ! -L "$FROZEN_SOURCE_DIR" ]] || return 1
  mkdir -m 0700 -- "$temporary" || return 1
  if ! python3 -B - "$SOURCE_DIR" "$temporary" "$NEW_VERSION" <<'PY'
import os
from pathlib import Path
import stat
import sys

source = Path(sys.argv[1])
target = Path(sys.argv[2])
version = sys.argv[3]
try:
    lines = (source / "scripts/release-manifest.txt").read_text(encoding="utf-8").splitlines()
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
            raise ValueError("manifest")
        seen.add(relative)
        paths.append((relative, parts))
    if not paths:
        raise ValueError("manifest")
    for relative, parts in paths:
        current = source
        for part in parts:
            current = current / part
            info = current.lstat()
            if stat.S_ISLNK(info.st_mode):
                raise ValueError("link")
        if not stat.S_ISREG(info.st_mode):
            raise ValueError("type")
        destination = target / relative
        destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        source_fd = os.open(current, os.O_RDONLY | os.O_NOFOLLOW)
        try:
            opened = os.fstat(source_fd)
            if not stat.S_ISREG(opened.st_mode) or opened.st_dev != info.st_dev or opened.st_ino != info.st_ino:
                raise ValueError("changed")
            destination_fd = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            try:
                while True:
                    chunk = os.read(source_fd, 1024 * 1024)
                    if not chunk:
                        break
                    view = memoryview(chunk)
                    while view:
                        written = os.write(destination_fd, view)
                        view = view[written:]
                os.fsync(destination_fd)
                os.fchmod(destination_fd, 0o500 if opened.st_mode & 0o111 else 0o400)
                os.fsync(destination_fd)
            finally:
                os.close(destination_fd)
        finally:
            os.close(source_fd)
    directories = [target, *(item for item in target.rglob("*") if item.is_dir())]
    for directory in sorted(directories, key=lambda item: len(item.parts), reverse=True):
        os.chmod(directory, 0o500)
        descriptor = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
except (OSError, UnicodeError, ValueError):
    raise SystemExit(1)
PY
  then
    find "$temporary" -type d -exec chmod 0700 {} + 2>/dev/null || true
    find "$temporary" -depth -delete 2>/dev/null || true
    return 1
  fi
  [[ "$(sha256sum "${temporary}/scripts/release-manifest.txt" | awk '{print $1}')" == "$SOURCE_MANIFEST_SHA256" \
    && "$(update_source_candidate_identity "$temporary" "$NEW_VERSION" immutable)" == "$SOURCE_CANDIDATE_SHA256" ]] \
    || { find "$temporary" -type d -exec chmod 0700 {} + 2>/dev/null || true; find "$temporary" -depth -delete 2>/dev/null || true; return 1; }
  if ! update_atomic_noreplace "$temporary" "$FROZEN_SOURCE_DIR"; then
    find "$temporary" -type d -exec chmod 0700 {} + 2>/dev/null || true
    find "$temporary" -depth -delete 2>/dev/null || true
    return 1
  fi
  [[ ! -e "$temporary" && ! -L "$temporary" ]] || return 1
  sync -f "$FROZEN_SOURCE_DIR" && sync -f "${DEPLOY_DIR}/backups" \
    && update_frozen_candidate_valid
}

update_frozen_candidate_remove() {
  local partial="${DEPLOY_DIR}/backups/.update-candidate-${UPDATE_TOKEN}.tmp"
  [[ -n "$FROZEN_SOURCE_DIR" ]] || return 0
  if [[ ( -e "$FROZEN_SOURCE_DIR" || -L "$FROZEN_SOURCE_DIR" ) \
    && ( -e "$partial" || -L "$partial" ) ]]; then
    return 1
  fi
  if [[ -e "$FROZEN_SOURCE_DIR" || -L "$FROZEN_SOURCE_DIR" ]]; then
    update_frozen_candidate_valid || return 1
    update_atomic_noreplace "$FROZEN_SOURCE_DIR" "$partial" || return 1
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
  [[ ! -e "$FROZEN_SOURCE_DIR" && ! -L "$FROZEN_SOURCE_DIR" \
    && ! -e "$partial" && ! -L "$partial" ]]
}

update_atomic_noreplace() {
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

update_cleanup_orphans_without_journal() {
  local -a orphans=()
  shopt -s nullglob
  orphans=("${DEPLOY_DIR}/backups"/.update-candidate-*.tmp \
    "${DEPLOY_DIR}/backups"/update-candidate-* \
    "${DEPLOY_DIR}/backups"/update-recovery.json.tmp.*)
  shopt -u nullglob
  (( ${#orphans[@]} )) || return 0
  python3 -B - "${DEPLOY_DIR}/backups" "${orphans[@]}" <<'PY'
import os
from pathlib import Path
import re
import stat
import sys
import ctypes

backups = Path(sys.argv[1])
items = [Path(value) for value in sys.argv[2:]]
euid = os.geteuid()
candidate_temp = re.compile(r"^\.update-candidate-([a-f0-9]{64})\.tmp$")
candidate_final = re.compile(r"^update-candidate-([a-f0-9]{64})$")
journal_temp = re.compile(r"^update-recovery\.json\.tmp\.([a-f0-9]{64})\.[A-Za-z0-9]{6}$")
try:
    if backups.is_symlink() or not backups.is_dir() or backups.stat().st_uid != euid:
        raise ValueError("backups")
    def inspect_tree(root, complete):
        info = root.lstat()
        expected_root_modes = {0o500} if complete else {0o500, 0o700}
        if not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode) \
                or info.st_uid != euid or stat.S_IMODE(info.st_mode) not in expected_root_modes:
            raise ValueError("root")
        files = set()
        directories = set()
        total_bytes = 0
        for current, names, filenames in os.walk(root, topdown=True, followlinks=False):
            names.sort(); filenames.sort()
            base = Path(current)
            for name in names:
                item = base / name
                child = item.lstat()
                relative = item.relative_to(root).as_posix()
                if not stat.S_ISDIR(child.st_mode) or stat.S_ISLNK(child.st_mode) \
                        or child.st_uid != euid or stat.S_IMODE(child.st_mode) not in ({0o500} if complete else {0o500, 0o700}):
                    raise ValueError("directory")
                if relative.startswith("/") or "\\" in relative or any(ord(character) < 32 for character in relative) \
                        or any(part in ("", ".", "..") for part in relative.split("/")) or len(relative) > 1024:
                    raise ValueError("directory name")
                directories.add(relative)
            for name in filenames:
                item = base / name
                child = item.lstat()
                relative = item.relative_to(root).as_posix()
                if not stat.S_ISREG(child.st_mode) or stat.S_ISLNK(child.st_mode) \
                        or child.st_uid != euid or child.st_nlink != 1 \
                        or stat.S_IMODE(child.st_mode) not in ({0o400, 0o500} if complete else {0o400, 0o500, 0o600}):
                    raise ValueError("file")
                if relative.startswith("/") or "\\" in relative or any(ord(character) < 32 for character in relative) \
                        or any(part in ("", ".", "..") for part in relative.split("/")) or len(relative) > 1024:
                    raise ValueError("file name")
                files.add(relative)
                total_bytes += child.st_size
        if len(files) > 10000 or len(directories) > 10000 or total_bytes > 2 * 1024 * 1024 * 1024:
            raise ValueError("bounds")
        if complete:
            version_file = root / "VERSION"
            version = version_file.read_text(encoding="utf-8").strip()
            if not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", version):
                raise ValueError("version")
            expected = set()
            manifest = root / "scripts/release-manifest.txt"
            for line in manifest.read_text(encoding="utf-8").splitlines():
                if not line or line.startswith("#"):
                    continue
                relative = line.replace("@VERSION@", version)
                if relative.startswith("/") or "\\" in relative or relative != relative.strip() \
                        or any(ord(character) < 32 for character in relative) \
                        or any(part in ("", ".", "..") for part in relative.split("/")) \
                        or "@VERSION@" in relative or relative in expected:
                    raise ValueError("manifest")
                expected.add(relative)
            if not expected or "scripts/release-manifest.txt" not in expected:
                raise ValueError("manifest")
            expected_directories = set()
            for value in expected:
                parts = value.split("/")[:-1]
                for index in range(1, len(parts) + 1):
                    expected_directories.add("/".join(parts[:index]))
            if files != expected or directories != expected_directories:
                raise ValueError("complete")

    directories = []
    files = []
    for item in items:
        try:
            if item.parent != backups:
                raise ValueError("parent")
            name = item.name
            match = candidate_temp.fullmatch(name)
            if match:
                inspect_tree(item, False)
                directories.append((item, False, match.group(1)))
                continue
            match = candidate_final.fullmatch(name)
            if match:
                inspect_tree(item, True)
                directories.append((item, True, match.group(1)))
                continue
            match = journal_temp.fullmatch(name)
            if not match:
                raise ValueError("name")
            info = item.lstat()
            if not stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode) \
                    or info.st_uid != euid or info.st_nlink != 1 or stat.S_IMODE(info.st_mode) != 0o600 \
                    or info.st_size < 0 or info.st_size > 999999:
                raise ValueError("journal")
            files.append(item)
        except (OSError, UnicodeError, ValueError):
            raise SystemExit(1)
    cleanup_directories = []
    libc = ctypes.CDLL(None, use_errno=True)
    renameat2 = getattr(libc, "renameat2", None)
    if renameat2 is None:
        raise ValueError("renameat2")
    renameat2.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    renameat2.restype = ctypes.c_int
    for root, complete, token in directories:
        if complete:
            target = backups / f".update-candidate-{token}.tmp"
            if renameat2(-100, os.fsencode(root), -100, os.fsencode(target), 1) != 0:
                raise OSError(ctypes.get_errno(), "candidate cleanup rename")
            cleanup_directories.append(target)
        else:
            cleanup_directories.append(root)
    if directories:
        descriptor = os.open(backups, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
    for item in files:
        item.unlink()
    for root in cleanup_directories:
        for current, names, filenames in os.walk(root, topdown=False, followlinks=False):
            base = Path(current)
            os.chmod(base, 0o700)
            for name in filenames:
                (base / name).unlink()
            if base != root:
                base.rmdir()
        root.rmdir()
    descriptor = os.open(backups, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    if any(item.exists() or item.is_symlink() for item in [*items, *cleanup_directories]):
        raise SystemExit(1)
except (OSError, UnicodeError, ValueError):
    raise SystemExit(1)
PY
}

update_recovery_journal_matches() {
  local phase=$1 canonical
  [[ -f "$UPDATE_RECOVERY_JOURNAL" && ! -L "$UPDATE_RECOVERY_JOURNAL" ]] || return 1
  [[ "$(stat -c '%a:%h:%u' -- "$UPDATE_RECOVERY_JOURNAL" 2>/dev/null || true)" == "600:1:${EUID}" ]] || return 1
  [[ "$(stat -c '%s' -- "$UPDATE_RECOVERY_JOURNAL" 2>/dev/null || true)" =~ ^[1-9][0-9]{0,5}$ ]] || return 1
  canonical=$(jq -cS . "$UPDATE_RECOVERY_JOURNAL" 2>/dev/null) || return 1
  [[ "$(<"$UPDATE_RECOVERY_JOURNAL")" == "$canonical" ]] || return 1
  jq -e \
    --arg token "$UPDATE_TOKEN" --arg snapshot "$SNAPSHOT_ID" \
    --arg manifest_sha "$SNAPSHOT_MANIFEST_SHA256" --arg archive_sha "$SNAPSHOT_ARCHIVE_SHA256" \
    --arg old "$OLD_VERSION" --arg new "$NEW_VERSION" --arg source "$SOURCE_DIR" \
    --arg candidate_dir "$FROZEN_SOURCE_DIR" \
    --arg source_manifest "$SOURCE_MANIFEST_SHA256" --arg source_identity "$SOURCE_CANDIDATE_SHA256" \
    --arg previous_state "$PREVIOUS_INSTALLATION_STATE" --arg previous_source "$PREVIOUS_MARKER_SOURCE" \
    --arg previous_marker_sha "$PREVIOUS_MARKER_SHA256" --arg previous_marker_base64 "$PREVIOUS_MARKER_BASE64" \
    --arg owner_boot "$UPDATE_OWNER_BOOT_ID" \
    --arg owner_start "$UPDATE_OWNER_START_TICKS" --arg phase "$phase" \
    --arg completion "$RECOVERY_COMPLETION_STATE" --argjson owner_pid "$UPDATE_OWNER_PID" \
    --argjson created_at "$UPDATE_RECOVERY_CREATED_AT" '
      . as $journal |
      (keys | sort) == ["completion_state","created_at","kind","new_version","old_version",
        "owner_boot_id","owner_pid","owner_start_ticks","phase","previous_installation_state",
        "previous_marker_base64","previous_marker_sha256","previous_marker_source","schema_version","snapshot_archive_sha256",
        "snapshot_id","snapshot_manifest_sha256","source_candidate_dir","source_candidate_sha256","source_dir",
        "source_manifest_sha256","token"] and
      .schema_version == 1 and .kind == "failed-update-recovery" and .token == $token and
      .snapshot_id == $snapshot and .snapshot_manifest_sha256 == $manifest_sha and
      .snapshot_archive_sha256 == $archive_sha and .old_version == $old and .new_version == $new and
      .source_dir == $source and .source_candidate_dir == $candidate_dir and
      .source_manifest_sha256 == $source_manifest and
      .source_candidate_sha256 == $source_identity and
      .previous_installation_state == $previous_state and .previous_marker_source == $previous_source and
      .previous_marker_sha256 == $previous_marker_sha and
      .previous_marker_base64 == $previous_marker_base64 and .owner_pid == $owner_pid and
      .owner_boot_id == $owner_boot and .owner_start_ticks == $owner_start and
      .phase == $phase and .completion_state == $completion and
      (["prepared","recovery_armed","mutation_started","services_stopped","recovering",
        "restored","update_committed"] | index($journal.phase)) != null and
      (if .phase == "restored" or .phase == "update_committed" then
         (.completion_state == "ready" or .completion_state == "local-ready")
       else .completion_state == "" end) and
      .created_at == $created_at and
      (.created_at | type == "number" and floor == . and . > 0 and . <= 9007199254740991)
    ' "$UPDATE_RECOVERY_JOURNAL" >/dev/null 2>&1
}

update_recovery_write() {
  local phase=$1 completion=${2:-} temporary create=0
  local directory=${UPDATE_RECOVERY_JOURNAL%/*}
  [[ -d "$directory" && ! -L "$directory" ]] || return 1
  [[ "$(stat -c '%u' -- "$directory" 2>/dev/null || true)" == "$EUID" ]] || return 1
  if [[ ! -e "$UPDATE_RECOVERY_JOURNAL" && ! -L "$UPDATE_RECOVERY_JOURNAL" ]]; then
    create=1
  else
    update_recovery_journal_matches "$RECOVERY_PHASE" || return 1
  fi
  temporary=$(mktemp "${UPDATE_RECOVERY_JOURNAL}.tmp.${UPDATE_TOKEN}.XXXXXX") || return 1
  if ! jq -cS -n \
      --arg token "$UPDATE_TOKEN" --arg snapshot "$SNAPSHOT_ID" \
      --arg manifest_sha "$SNAPSHOT_MANIFEST_SHA256" --arg archive_sha "$SNAPSHOT_ARCHIVE_SHA256" \
      --arg old "$OLD_VERSION" --arg new "$NEW_VERSION" --arg source "$SOURCE_DIR" \
      --arg candidate_dir "$FROZEN_SOURCE_DIR" \
      --arg source_manifest "$SOURCE_MANIFEST_SHA256" --arg source_identity "$SOURCE_CANDIDATE_SHA256" \
      --arg previous_state "$PREVIOUS_INSTALLATION_STATE" --arg previous_source "$PREVIOUS_MARKER_SOURCE" \
      --arg previous_marker_sha "$PREVIOUS_MARKER_SHA256" --arg previous_marker_base64 "$PREVIOUS_MARKER_BASE64" \
      --arg owner_boot "$UPDATE_OWNER_BOOT_ID" \
      --arg owner_start "$UPDATE_OWNER_START_TICKS" --arg phase "$phase" --arg completion "$completion" \
      --argjson owner_pid "$UPDATE_OWNER_PID" --argjson created_at "$UPDATE_RECOVERY_CREATED_AT" '
        {schema_version:1,kind:"failed-update-recovery",token:$token,snapshot_id:$snapshot,
         snapshot_manifest_sha256:$manifest_sha,snapshot_archive_sha256:$archive_sha,
         old_version:$old,new_version:$new,source_dir:$source,source_candidate_dir:$candidate_dir,
         source_manifest_sha256:$source_manifest,
         source_candidate_sha256:$source_identity,previous_installation_state:$previous_state,
         previous_marker_source:$previous_source,previous_marker_sha256:$previous_marker_sha,
         previous_marker_base64:$previous_marker_base64,
         owner_pid:$owner_pid,owner_boot_id:$owner_boot,owner_start_ticks:$owner_start,
         phase:$phase,completion_state:$completion,created_at:$created_at}' > "$temporary" \
    || ! chmod 0600 "$temporary" || ! sync -f "$temporary"; then
    rm -f -- "$temporary"
    return 1
  fi
  if (( create )); then
    if ! update_atomic_noreplace "$temporary" "$UPDATE_RECOVERY_JOURNAL"; then
      rm -f -- "$temporary"
      return 1
    fi
    [[ ! -e "$temporary" && ! -L "$temporary" ]] || return 1
    UPDATE_JOURNAL_PUBLISHED=1
  elif ! mv -f -- "$temporary" "$UPDATE_RECOVERY_JOURNAL"; then
    rm -f -- "$temporary"
    return 1
  fi
  RECOVERY_PHASE=$phase
  RECOVERY_COMPLETION_STATE=$completion
  [[ "$(stat -c '%a:%h:%u' -- "$UPDATE_RECOVERY_JOURNAL" 2>/dev/null || true)" == "600:1:${EUID}" ]] \
    && sync -f "$UPDATE_RECOVERY_JOURNAL" && sync -f "$directory" \
    && update_recovery_journal_matches "$phase"
}

update_recovery_remove() {
  local directory=${UPDATE_RECOVERY_JOURNAL%/*} canonical
  local helper="${UPDATE_RECOVERY_TOMBSTONE}.helper" temporary
  local -a helper_temps=()
  update_recovery_journal_matches "$RECOVERY_PHASE" || return 1
  update_preflight_cleanup || return 1
  if [[ "$UPDATE_RECOVERY_JOURNAL" != "$UPDATE_RECOVERY_TOMBSTONE" ]]; then
    [[ ! -e "$UPDATE_RECOVERY_TOMBSTONE" && ! -L "$UPDATE_RECOVERY_TOMBSTONE" ]] || return 1
    update_atomic_noreplace "$UPDATE_RECOVERY_JOURNAL" "$UPDATE_RECOVERY_TOMBSTONE" || return 1
    UPDATE_RECOVERY_JOURNAL=$UPDATE_RECOVERY_TOMBSTONE
    sync -f "$directory" || return 1
  fi
  canonical=$(<"$UPDATE_RECOVERY_JOURNAL") || return 1
  shopt -s nullglob
  helper_temps=("${helper}.tmp."*)
  shopt -u nullglob
  (( ${#helper_temps[@]} == 0 )) || return 1
  if [[ -e "$helper" || -L "$helper" ]]; then
    [[ -f "$helper" && ! -L "$helper" \
      && "$(stat -c '%a:%h:%u' -- "$helper" 2>/dev/null || true)" == "600:1:${EUID}" \
      && "$(stat -c '%s' -- "$helper" 2>/dev/null || true)" =~ ^[1-9][0-9]{0,5}$ \
      && "$(<"$helper")" == "$canonical" ]] || return 1
  else
    temporary=$(mktemp "${helper}.tmp.XXXXXX") || return 1
    if ! printf '%s' "$canonical" > "$temporary" || ! chmod 0600 "$temporary" \
      || ! sync -f "$temporary" || ! update_atomic_noreplace "$temporary" "$helper" \
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

update_preflight_cleanup() {
  [[ -n "$UPDATE_PREFLIGHT_DIR" ]] || return 0
  if [[ ! -e "$UPDATE_PREFLIGHT_DIR" && ! -L "$UPDATE_PREFLIGHT_DIR" ]]; then
    sync -f "${DEPLOY_DIR}/tmp" || return 1
    [[ ! -e "$UPDATE_PREFLIGHT_DIR" && ! -L "$UPDATE_PREFLIGHT_DIR" ]] || return 1
    UPDATE_PREFLIGHT_DIR=""
    return 0
  fi
  [[ "$UPDATE_PREFLIGHT_DIR" == "${DEPLOY_DIR}/tmp/update-preflight-${UPDATE_TOKEN}" \
    && -d "$UPDATE_PREFLIGHT_DIR" && ! -L "$UPDATE_PREFLIGHT_DIR" \
    && "$(stat -c '%a:%u' -- "$UPDATE_PREFLIGHT_DIR" 2>/dev/null || true)" == "700:${EUID}" ]] \
    || return 1
  [[ -z "$(find "$UPDATE_PREFLIGHT_DIR" -mindepth 1 \
    \( ! -type f -o -links +1 -o ! -user "$EUID" -o ! -perm 0600 -o -perm /0177 \) -print -quit 2>/dev/null)" ]] \
    || return 1
  find "$UPDATE_PREFLIGHT_DIR" -depth -delete || return 1
  sync -f "${DEPLOY_DIR}/tmp" || return 1
  [[ ! -e "$UPDATE_PREFLIGHT_DIR" && ! -L "$UPDATE_PREFLIGHT_DIR" ]] || return 1
  UPDATE_PREFLIGHT_DIR=""
}

usage() {
  cat <<'EOF'
用法：./update.sh [选项]

选项：
  --deploy-dir PATH   指定部署目录
  --source-dir PATH   使用已下载的 ai-support 源码目录
  --no-pull           不执行 git pull，仅使用当前源码
  --reapply           显式重新应用同一版本，仍执行完整快照、更新和健康检查
  --skip-start        已禁用；更新必须完成快照、重启与健康检查
  --version           显示版本
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --deploy-dir)
      (( $# >= 2 )) || die "--deploy-dir 缺少参数"
      DEPLOY_REQUEST=$2
      shift 2
      ;;
    --source-dir)
      (( $# >= 2 )) || die "--source-dir 缺少参数"
      SOURCE_REQUEST=$2
      shift 2
      ;;
    --no-pull)
      NO_PULL=1
      shift
      ;;
    --reapply)
      REAPPLY=1
      shift
      ;;
    --skip-start)
      SKIP_START=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --version)
      printf '%s\n' "$(<"${SCRIPT_DIR}/VERSION")"
      exit 0
      ;;
    *) die "未知选项：$1" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "更新需要 root 权限"
bootstrap_prepare_minimal_dependencies \
  || die "更新所需基础依赖自动安装失败；现有部署未改变"
DEPLOY_DIR=$(resolve_deploy_dir "$DEPLOY_REQUEST")
assert_installation "$DEPLOY_DIR"
acquire_maintenance_lock "$DEPLOY_DIR"
require_command realpath
for command_name in base64 jq python3 sha256sum stat sync; do require_command "$command_name"; done
(( SKIP_START == 0 )) || die "为保证 n8n 数据库与 AnythingLLM 数据一致，更新不再支持 --skip-start"
UPDATE_RECOVERY_JOURNAL="${DEPLOY_DIR}/backups/update-recovery.json"
[[ ! -e "$UPDATE_RECOVERY_JOURNAL" && ! -L "$UPDATE_RECOVERY_JOURNAL" ]] \
  || die '检测到未完成的升级恢复责任；必须先按原 journal 完成恢复，不能开始另一轮更新'
shopt -s nullglob
UPDATE_RECOVERY_TOMBSTONES=("${DEPLOY_DIR}"/backups/update-recovery.finalizing-*.json \
  "${DEPLOY_DIR}"/backups/update-recovery.finalizing-*.json.helper \
  "${DEPLOY_DIR}"/backups/update-recovery.finalizing-*.json.helper.tmp.*)
shopt -u nullglob
(( ${#UPDATE_RECOVERY_TOMBSTONES[@]} == 0 )) \
  || die '检测到未完成的升级恢复 tombstone；必须先按原 token 完成收口'
update_cleanup_orphans_without_journal \
  || die '无正式 journal 的升级临时对象不满足严格归属合同；拒绝猜测或删除'

if [[ -n "$SOURCE_REQUEST" ]]; then
  SOURCE_DIR=$(realpath -e -- "$SOURCE_REQUEST")
else
  SOURCE_DIR=$(sed -n 's/^source=//p' "${DEPLOY_DIR}/${INSTALL_MARKER}" | head -n 1)
  if [[ -z "$SOURCE_DIR" || ! -d "$SOURCE_DIR" ]]; then
    die "找不到原始 Git 工作区，请使用 --source-dir 指定已下载的源码"
  fi
  SOURCE_DIR=$(realpath -e -- "$SOURCE_DIR")
fi
[[ -d "$SOURCE_DIR" && ! -L "$SOURCE_DIR" && "$SOURCE_DIR" != *[[:cntrl:]]* ]] \
  || die '升级源码目录类型或名称不安全'
[[ -f "${SOURCE_DIR}/VERSION" && -f "${SOURCE_DIR}/install.sh" && -f "${SOURCE_DIR}/docker-compose.yml" ]] \
  || die "指定目录不是完整的 ai-support 源码"
[[ "$(realpath -m -- "$SOURCE_DIR")" != "$(realpath -m -- "$DEPLOY_DIR")" ]] \
  || die "源码目录不能与部署目录相同；请在独立 Git 工作区中运行 update.sh 并指定 --source-dir"

if (( NO_PULL == 0 )); then
  require_command git
  [[ -d "${SOURCE_DIR}/.git" ]] || die "源码目录不是 Git 工作区；请准备新版本源码并使用 --no-pull"
  [[ -z "$(git -C "$SOURCE_DIR" status --porcelain)" ]] \
    || die "源码工作区存在未提交修改，拒绝自动更新；请先处理修改或使用 --no-pull"
  git -C "$SOURCE_DIR" pull --ff-only
fi

NEW_VERSION=$(<"${SOURCE_DIR}/VERSION")
[[ "$NEW_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "源码 VERSION 格式无效"

OLD_VERSION=$(<"${DEPLOY_DIR}/VERSION")
[[ "$OLD_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "当前 VERSION 格式无效"
PREVIOUS_INSTALLATION_STATE=$(installation_state "$DEPLOY_DIR")
case "$PREVIOUS_INSTALLATION_STATE" in ready|local-ready) ;; *) die '升级前安装状态不是已完成状态' ;; esac
PREVIOUS_MARKER_SOURCE=$(sed -n 's/^source=//p' "${DEPLOY_DIR}/${INSTALL_MARKER}" | head -n 1)
[[ -z "$PREVIOUS_MARKER_SOURCE" || "$PREVIOUS_MARKER_SOURCE" == /* && "$PREVIOUS_MARKER_SOURCE" != *[[:cntrl:]]* ]] \
  || die '升级前安装标记的源码路径无效'
[[ "$(sed -n 's/^installed_version=//p' "${DEPLOY_DIR}/${INSTALL_MARKER}" | head -n 1)" == "$OLD_VERSION" ]] \
  || die '升级前安装标记版本与当前 VERSION 不一致'
[[ "$(stat -c '%a:%h:%u' -- "${DEPLOY_DIR}/${INSTALL_MARKER}" 2>/dev/null || true)" == "600:1:${EUID}" ]] \
  || die '升级前安装标记不是当前管理员拥有的 0600 普通单链接文件'
PREVIOUS_MARKER_SHA256=$(sha256sum "${DEPLOY_DIR}/${INSTALL_MARKER}" | awk '{print $1}')
PREVIOUS_MARKER_BASE64=$(base64 -w 0 -- "${DEPLOY_DIR}/${INSTALL_MARKER}")
[[ -n "$PREVIOUS_MARKER_BASE64" \
  && "$(printf '%s' "$PREVIOUS_MARKER_BASE64" | base64 -d | sha256sum | awk '{print $1}')" == "$PREVIOUS_MARKER_SHA256" ]] \
  || die '无法冻结升级前安装标记原始字节'
SOURCE_MANIFEST_SHA256=$(sha256sum "${SOURCE_DIR}/scripts/release-manifest.txt" | awk '{print $1}')
SOURCE_CANDIDATE_SHA256=$(update_source_candidate_identity "$SOURCE_DIR" "$NEW_VERSION") \
  || die '无法建立升级候选的完整固定清单身份'
[[ "$SOURCE_MANIFEST_SHA256" =~ ^[a-f0-9]{64}$ && "$SOURCE_CANDIDATE_SHA256" =~ ^[a-f0-9]{64}$ ]] \
  || die '升级候选身份无效'
UPDATE_TOKEN=$(random_hex 32)
UPDATE_RECOVERY_TOMBSTONE="${DEPLOY_DIR}/backups/update-recovery.finalizing-${UPDATE_TOKEN}.json"
UPDATE_OWNER_PID=$$
UPDATE_OWNER_BOOT_ID=$(< /proc/sys/kernel/random/boot_id)
UPDATE_OWNER_START_TICKS=$(python3 -B - "$UPDATE_OWNER_PID" <<'PY'
from pathlib import Path
import sys
value = Path('/proc') / sys.argv[1] / 'stat'
raw = value.read_text()
print(raw.rsplit(')', 1)[1].split()[19])
PY
)
UPDATE_RECOVERY_CREATED_AT=$(date +%s%3N)
[[ "$UPDATE_TOKEN" =~ ^[a-f0-9]{64}$ \
  && "$UPDATE_OWNER_BOOT_ID" =~ ^[a-f0-9-]{36}$ \
  && "$UPDATE_OWNER_START_TICKS" =~ ^[0-9]+$ \
  && "$UPDATE_RECOVERY_CREATED_AT" =~ ^[0-9]{13}$ ]] || die '无法建立升级恢复进程身份'
IFS=. read -r NEW_MAJOR NEW_MINOR NEW_PATCH <<< "${NEW_VERSION#v}"
IFS=. read -r OLD_MAJOR OLD_MINOR OLD_PATCH <<< "${OLD_VERSION#v}"
if (( 10#$NEW_MAJOR < 10#$OLD_MAJOR \
  || (10#$NEW_MAJOR == 10#$OLD_MAJOR && 10#$NEW_MINOR < 10#$OLD_MINOR) \
  || (10#$NEW_MAJOR == 10#$OLD_MAJOR && 10#$NEW_MINOR == 10#$OLD_MINOR && 10#$NEW_PATCH <= 10#$OLD_PATCH) )); then
  [[ "$NEW_VERSION" == "$OLD_VERSION" && $REAPPLY == 1 ]] \
    || die "目标版本必须高于当前版本：${OLD_VERSION} -> ${NEW_VERSION}；同版本重新应用须显式使用 --reapply"
fi
for recovery_artifact in \
  "${DEPLOY_DIR}/.env.crispai-atomic.json" \
  "${DEPLOY_DIR}/.env.crispai-atomic.next" \
  "${DEPLOY_DIR}/config/provider-pool-transaction.json" \
  "${DEPLOY_DIR}/data/runtime/knowledge-migration.json" \
  "${DEPLOY_DIR}/backups/config-history/materials.recovery" \
  "${DEPLOY_DIR}/backups/config-history/materials.initialize"; do
  [[ ! -e "$recovery_artifact" && ! -L "$recovery_artifact" ]] \
    || die '当前部署已有未完成配置或资料恢复责任；不能开始另一轮更新'
done
shopt -s nullglob
PRE_UPDATE_ATOMIC_ARTIFACTS=("${DEPLOY_DIR}"/.env.source.* "${DEPLOY_DIR}"/.env.tmp.*)
shopt -u nullglob
(( ${#PRE_UPDATE_ATOMIC_ARTIFACTS[@]} == 0 )) \
  || die '当前部署已有未归属敏感配置临时文件；不能开始另一轮更新'

SNAPSHOT_MIN_FREE_MB_VALUE=$(env_get "${DEPLOY_DIR}/.env" SNAPSHOT_MIN_FREE_MB 2>/dev/null || true)
SNAPSHOT_RETENTION_COUNT_VALUE=$(env_get "${DEPLOY_DIR}/.env" SNAPSHOT_RETENTION_COUNT 2>/dev/null || true)
if [[ -z "$SNAPSHOT_MIN_FREE_MB_VALUE" ]]; then
  env_set "${DEPLOY_DIR}/.env" SNAPSHOT_MIN_FREE_MB 1024
fi
if [[ -z "$SNAPSHOT_RETENTION_COUNT_VALUE" ]]; then
  env_set "${DEPLOY_DIR}/.env" SNAPSHOT_RETENTION_COUNT 10
fi
rollback_on_failure() {
  local status=$? phase
  local -a rollback_args=()
  trap - EXIT
  if (( status != 0 && UPDATE_COMPLETE == 0 )); then
    record_maintenance_event "$DEPLOY_DIR" update failed "$status"
    if [[ -n "$SNAPSHOT_ID" && $UPDATE_JOURNAL_PUBLISHED == 1 \
      && -e "$UPDATE_RECOVERY_JOURNAL" ]]; then
      phase=$(jq -r '.phase // ""' "$UPDATE_RECOVERY_JOURNAL" 2>/dev/null || true)
      RECOVERY_PHASE=$phase
      RECOVERY_COMPLETION_STATE=$(jq -r '.completion_state // ""' "$UPDATE_RECOVERY_JOURNAL" 2>/dev/null || true)
      rollback_args=(--deploy-dir "$DEPLOY_DIR" --snapshot "$SNAPSHOT_ID" --failed-update-recovery)
      if [[ "$phase" == update_committed ]]; then
        warn '新版本已到提交点，正在核验当前健康并收口恢复 journal；不得倒回旧版本'
        if CRISP_AI_FAILED_UPDATE_TOKEN="$UPDATE_TOKEN" "$ROLLBACK_SCRIPT" "${rollback_args[@]}"; then
          warn "更新提交已完成：$NEW_VERSION"
          exit 0
        else
          warn '更新提交已完成但 journal 尚未收口；保留当前新版本和恢复责任，禁止自动降版'
        fi
      elif [[ "$phase" == prepared || "$phase" == recovery_armed ]]; then
        if CRISP_AI_FAILED_UPDATE_TOKEN="$UPDATE_TOKEN" "$ROLLBACK_SCRIPT" "${rollback_args[@]}"; then
          warn '更新在业务代际修改前失败，程序与服务未改变；维护默认值可能已补齐，未执行无谓版本回滚'
          exit "$status"
        else
          warn '更新前恢复授权未能安全收口；journal 已保留，未猜测回滚目标'
        fi
      else
        warn "更新失败，开始按同次更新前快照自动恢复"
        if CRISP_AI_FAILED_UPDATE_TOKEN="$UPDATE_TOKEN" "$ROLLBACK_SCRIPT" "${rollback_args[@]}"; then
          warn "已自动恢复到更新前版本：$OLD_VERSION"
        else
          warn "自动恢复未完成；同次恢复 journal 与版本快照已保留：$SNAPSHOT_ID"
        fi
      fi
    elif (( UPDATE_JOURNAL_PUBLISHED == 1 )); then
      warn '恢复 journal 曾发布但当前名字缺失；保留冻结候选，拒绝按从未发布状态清理'
      if (( SERVICES_STOPPED )); then
        docker_compose "$DEPLOY_DIR" up -d --remove-orphans >/dev/null 2>&1 || true
      fi
    else
      update_preflight_cleanup || warn '候选Compose预检临时目录未能安全清理'
      update_frozen_candidate_remove || warn '冻结候选目录未能安全清理'
      if (( SERVICES_STOPPED )); then
        docker_compose "$DEPLOY_DIR" up -d --remove-orphans >/dev/null 2>&1 || true
      fi
    fi
  fi
  exit "$status"
}
trap rollback_on_failure EXIT

FROZEN_SOURCE_DIR="${DEPLOY_DIR}/backups/update-candidate-${UPDATE_TOKEN}"
update_frozen_candidate_create \
  || die '无法建立同次更新的只读冻结候选；现有部署未修改'
# 后续 common/launcher 中可能调用的辅助程序也只能来自冻结候选。
# shellcheck source=scripts/common.sh
source "${FROZEN_SOURCE_DIR}/scripts/common.sh"
# shellcheck source=scripts/bootstrap.sh
source "${FROZEN_SOURCE_DIR}/scripts/bootstrap.sh"
# shellcheck source=scripts/launcher.sh
source "${FROZEN_SOURCE_DIR}/scripts/launcher.sh"
SNAPSHOT_SCRIPT="${FROZEN_SOURCE_DIR}/scripts/snapshot.sh"
ROLLBACK_SCRIPT="${FROZEN_SOURCE_DIR}/scripts/rollback.sh"
BACKUP_SCRIPT="${FROZEN_SOURCE_DIR}/scripts/backup.sh"
[[ -x "$SNAPSHOT_SCRIPT" && -x "$ROLLBACK_SCRIPT" && -x "$BACKUP_SCRIPT" ]] \
  || die '冻结候选缺少可执行的快照、回滚或备份入口'
"$SNAPSHOT_SCRIPT" --deploy-dir "$DEPLOY_DIR" --check-capacity

bootstrap_prepare_docker_runtime \
  || die "Docker 自动修复失败；现有部署未改变"
require_docker_runtime
docker_compose "$DEPLOY_DIR" config --quiet

SNAPSHOT_ID=$("$SNAPSHOT_SCRIPT" --deploy-dir "$DEPLOY_DIR" --reason "pre-update-${OLD_VERSION}" --quiet)
info "更新前版本快照：$SNAPSHOT_ID"
SNAPSHOT_MANIFEST="${DEPLOY_DIR}/backups/versions/${SNAPSHOT_ID}/manifest.json"
SNAPSHOT_ARCHIVE="${DEPLOY_DIR}/backups/versions/${SNAPSHOT_ID}/snapshot.tar.gz"
[[ -f "$SNAPSHOT_MANIFEST" && ! -L "$SNAPSHOT_MANIFEST" \
  && -f "$SNAPSHOT_ARCHIVE" && ! -L "$SNAPSHOT_ARCHIVE" \
  && "$(stat -c '%a:%h:%u' -- "$SNAPSHOT_MANIFEST")" == "600:1:${EUID}" \
  && "$(stat -c '%a:%h:%u' -- "$SNAPSHOT_ARCHIVE")" == "600:1:${EUID}" ]] \
  || die '更新前版本快照文件身份不安全'
SNAPSHOT_MANIFEST_SHA256=$(sha256sum "$SNAPSHOT_MANIFEST" | awk '{print $1}')
SNAPSHOT_ARCHIVE_SHA256=$(sha256sum "$SNAPSHOT_ARCHIVE" | awk '{print $1}')
jq -e --arg id "$SNAPSHOT_ID" --arg old "$OLD_VERSION" --arg sha "$SNAPSHOT_ARCHIVE_SHA256" '
  .format == "ai-support-snapshot-v3" and .contains_env == true and
  .contains_database_dump == true and .id == $id and .version == $old and
  .archive_sha256 == $sha
' "$SNAPSHOT_MANIFEST" >/dev/null || die '更新前版本快照未与旧版本和归档身份严格绑定'
RECOVERY_PHASE=prepared
RECOVERY_COMPLETION_STATE=""
update_recovery_write "$RECOVERY_PHASE" \
  || die '无法持久记录同次更新前快照恢复责任；现有部署未修改'
BACKUP_FILE="${DEPLOY_DIR}/backups/pre-update-${OLD_VERSION}-$(date -u '+%Y%m%dT%H%M%SZ').tar.gz"
"$BACKUP_SCRIPT" --deploy-dir "$DEPLOY_DIR" --output "$BACKUP_FILE" >/dev/null
info "更新前迁移备份：$BACKUP_FILE"

# 快照先记录旧镜像引用与镜像 ID。新 Compose 可能要求旧 .env 尚无的内部字段；
# 只在受限临时副本上迁移并用于 config/pull，pull 成功前绝不发布到活动 .env。
UPDATE_PREFLIGHT_DIR="${DEPLOY_DIR}/tmp/update-preflight-${UPDATE_TOKEN}"
[[ ! -e "$UPDATE_PREFLIGHT_DIR" && ! -L "$UPDATE_PREFLIGHT_DIR" ]] \
  || die '同次更新的候选Compose临时目录已存在；拒绝复用'
mkdir -m 0700 -- "$UPDATE_PREFLIGHT_DIR"
install -m 0600 -- "${DEPLOY_DIR}/.env" "${UPDATE_PREFLIGHT_DIR}/.env"
migrate_runtime_env "$UPDATE_PREFLIGHT_DIR"
# DEPLOY_DIR 需临时导出给函数内的 docker compose 用于变量插值；参数展开使用的是同一个既有值。
# shellcheck disable=SC2097,SC2098
DEPLOY_DIR="$DEPLOY_DIR" docker_compose_command --project-directory "$DEPLOY_DIR" \
  --env-file "${UPDATE_PREFLIGHT_DIR}/.env" \
  -f "${FROZEN_SOURCE_DIR}/docker-compose.yml" config --quiet
# 镜像拉取在正式停机前完成；网络或 registry 失败不会影响当前运行服务。
# shellcheck disable=SC2097,SC2098
DEPLOY_DIR="$DEPLOY_DIR" docker_compose_command --project-directory "$DEPLOY_DIR" \
  --env-file "${UPDATE_PREFLIGHT_DIR}/.env" \
  -f "${FROZEN_SOURCE_DIR}/docker-compose.yml" pull
update_preflight_cleanup || die '候选Compose预检临时目录未能安全清理；未修改业务代际'
update_frozen_candidate_valid \
  || die '冻结升级候选在预检期间发生变化；现有部署未修改'
update_recovery_write recovery_armed \
  || die '无法在正式修改前持久化恢复授权；现有部署未修改'
write_installation_marker "$DEPLOY_DIR" "$FROZEN_SOURCE_DIR" "$OLD_VERSION" installing
if ! sync -f "${DEPLOY_DIR}/${INSTALL_MARKER}" || ! sync -f "$DEPLOY_DIR"; then
  die '安装标记升级态未能持久化；未继续修改部署'
fi
update_recovery_write mutation_started \
  || die '安装标记已进入升级态但恢复责任未能同步持久化；未继续修改部署'
migrate_runtime_env "$DEPLOY_DIR"
bash "${FROZEN_SOURCE_DIR}/scripts/knowledge-profile.sh" --deploy-dir "$DEPLOY_DIR" capture \
  || die '旧知识模型配置无法安全识别；升级将按原快照恢复'
docker_compose "$DEPLOY_DIR" stop n8n anythingllm
SERVICES_STOPPED=1
update_recovery_write services_stopped \
  || die '停写状态未能同步持久化；升级将按原快照恢复'
SCHEDULER_LOCK_STATE=$(scheduler_scan_lock_state "$DEPLOY_DIR")
case "$SCHEDULER_LOCK_STATE" in
  absent|owned) ;;
  legacy-ownerless-empty)
    cleanup_legacy_scheduler_scan_lock "$DEPLOY_DIR" \
      || die '旧版会话扫描空锁未能在 n8n 停写窗口安全迁移；升级将回滚'
    info '已在 n8n 停写窗口迁移旧版会话扫描空锁'
    ;;
  *) die '会话扫描锁不是可安全迁移的旧版空目录；升级将回滚且不会删除该锁' ;;
esac

copy_project_files "$FROZEN_SOURCE_DIR" "$DEPLOY_DIR"
initialize_config_files "$DEPLOY_DIR"
bash "${DEPLOY_DIR}/scripts/logs.sh" --deploy-dir "$DEPLOY_DIR" initialize
record_maintenance_event "$DEPLOY_DIR" update start
migrate_config_files "$DEPLOY_DIR"
bash "${DEPLOY_DIR}/scripts/configuration.sh" --deploy-dir "$DEPLOY_DIR" migrate
python3 "${DEPLOY_DIR}/scripts/provider-pool.py" --deploy-dir "$DEPLOY_DIR" migrate --defer-runtime >/dev/null \
  || die '主备接口迁移未完成，升级将按原快照恢复'
[[ ! -L "${DEPLOY_DIR}/data/analytics/events.jsonl" ]] || die "统计事件文件不得是符号链接"
touch -- "${DEPLOY_DIR}/data/analytics/events.jsonl"
set_runtime_ownership "$DEPLOY_DIR"
secure_permissions "$DEPLOY_DIR"

if (( SKIP_START == 0 )); then
  docker_compose "$DEPLOY_DIR" config --quiet
  validate_managed_caddy_configuration "$DEPLOY_DIR" || die '升级候选反代配置未通过预检；未启动新服务代'
  docker_compose "$DEPLOY_DIR" up -d --remove-orphans
  refresh_program_file_mounts "$DEPLOY_DIR" || die '升级后的单文件程序挂载未完成刷新'
  wait_for_local_health "$DEPLOY_DIR"
  python3 "${DEPLOY_DIR}/scripts/provider-pool.py" --deploy-dir "$DEPLOY_DIR" verify-applied >/dev/null \
    || die '运行适配器未完整回读主备接口配置；推理保持暂停，升级将按原快照恢复'
  bootstrap_anythingllm_api_key "$DEPLOY_DIR"
  ensure_anythingllm_workspace "$DEPLOY_DIR"
  bash "${DEPLOY_DIR}/scripts/knowledge-profile.sh" --deploy-dir "$DEPLOY_DIR" ensure \
    || die '中文知识检索模型或索引代次迁移未完成；升级将按原快照恢复'
  docker_compose "$DEPLOY_DIR" up -d --force-recreate n8n
  wait_for_local_health "$DEPLOY_DIR"
  if jq -M -e '.schema_version == 2' "${DEPLOY_DIR}/config/materials-applied.json" >/dev/null 2>&1; then
    # 先冻结完整旧有效代，再经既有资料事务同步候选；不能先激活草稿 Prompt。
    bash "${DEPLOY_DIR}/scripts/materials.sh" --deploy-dir "$DEPLOY_DIR" apply-business --sync-knowledge \
      || die '升级后受管资料同步失败'
  else
    # 旧投影仍沿安装/升级的兼容初始化链迁移，不猜造现代有效代。
    sync_prompt_to_anythingllm "$DEPLOY_DIR"
    knowledge_sync "$DEPLOY_DIR" || die "更新后知识库同步失败"
  fi
  import_and_publish_workflow "$DEPLOY_DIR" || die "更新后 workflow 发布失败"
  wait_for_local_health "$DEPLOY_DIR"
  if jq -M -e '.schema_version == 2' "${DEPLOY_DIR}/config/materials-applied.json" >/dev/null 2>&1; then
    # 当前代已由上面的事务提交；initialize 只做同代回读，避免再发布一代。
    bash "${DEPLOY_DIR}/scripts/materials.sh" --deploy-dir "$DEPLOY_DIR" initialize >/dev/null \
      || die '升级后运行时配置回读失败'
  else
    bash "${DEPLOY_DIR}/scripts/configuration.sh" --deploy-dir "$DEPLOY_DIR" mark-applied \
      || die '升级后运行时配置回读失败'
  fi
  install_log_maintenance "$DEPLOY_DIR" || die '升级后日志维护调度回读失败'
  "${DEPLOY_DIR}/scripts/healthcheck.sh" --deploy-dir "$DEPLOY_DIR" \
    --application --installation-in-progress
  set_installation_fact "$DEPLOY_DIR" dependencies ready
  set_installation_fact "$DEPLOY_DIR" local_services ready
  set_installation_fact "$DEPLOY_DIR" app_config ready
  set_installation_fact "$DEPLOY_DIR" provider ready
  if webhook_access_check "$DEPLOY_DIR"; then
    set_installation_fact "$DEPLOY_DIR" webhook ready
  else
    set_installation_fact "$DEPLOY_DIR" webhook pending
    warn "更新后公网 Webhook 尚未通过 DNS/TLS/路由检查（HTTP ${WEBHOOK_ACCESS_STATUS:-000}）"
  fi
  if crisp_api_check "$DEPLOY_DIR"; then
    set_installation_fact "$DEPLOY_DIR" crisp_api ready
  else
    set_installation_fact "$DEPLOY_DIR" crisp_api failed
    warn "更新完成且本地应用已通过检查，但 Crisp API 待修正（HTTP ${CRISP_API_STATUS:-000}）"
  fi
  refresh_conversation_fact "$DEPLOY_DIR" || set_installation_fact "$DEPLOY_DIR" conversation pending
  if [[ "$(installation_fact "$DEPLOY_DIR" crisp_api)" == ready \
    && "$(installation_fact "$DEPLOY_DIR" webhook)" == ready \
    && "$(installation_fact "$DEPLOY_DIR" conversation)" == ready ]]; then
    FINAL_INSTALLATION_STATE=ready
  else
    FINAL_INSTALLATION_STATE=local-ready
    warn '本地升级已完成；外部接入尚待验证，可运行 crispai doctor 继续检查'
  fi
  install_crispai_launcher "$DEPLOY_DIR" 1 || die '升级后无法修复本实例 crispai 管理入口'
  update_recovery_write update_committed "$FINAL_INSTALLATION_STATE" \
    || die '升级已经完成，但恢复 journal 未能提交完成状态；拒绝清除恢复责任'
  write_installation_marker "$DEPLOY_DIR" "$SOURCE_DIR" "$NEW_VERSION" "$FINAL_INSTALLATION_STATE"
  if ! sync -f "${DEPLOY_DIR}/${INSTALL_MARKER}" || ! sync -f "$DEPLOY_DIR"; then
    die '升级提交标记未能持久化；恢复 journal 保持可见'
  fi
  [[ "$(installation_state "$DEPLOY_DIR")" == "$FINAL_INSTALLATION_STATE" \
    && "$(sed -n 's/^installed_version=//p' "${DEPLOY_DIR}/${INSTALL_MARKER}" | head -n 1)" == "$NEW_VERSION" \
    && "$(sed -n 's/^source=//p' "${DEPLOY_DIR}/${INSTALL_MARKER}" | head -n 1)" == "$SOURCE_DIR" ]] \
    || die '升级提交标记未通过新版本、候选来源和完成状态回读'
  update_recovery_remove \
    || die '升级已经完成，但恢复 journal 未能安全清理；恢复责任保持可见'
  SERVICES_STOPPED=0
fi

UPDATE_COMPLETE=1
record_maintenance_event "$DEPLOY_DIR" update complete
update_frozen_candidate_remove \
  || warn '更新事务已提交且恢复责任已收口，但无秘密冻结候选尚未清理；下一次受管更新入口将严格收敛'
trap - EXIT
info "更新完成：${OLD_VERSION} -> ${NEW_VERSION}"
info "如需撤销，请运行：${DEPLOY_DIR}/scripts/rollback.sh --deploy-dir ${DEPLOY_DIR} --snapshot ${SNAPSHOT_ID}"
